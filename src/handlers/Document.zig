//! Owns the MuPDF context and document; every MuPDF call goes through here
//! under render_mutex, so it is safe to use from the prerender worker. Holds no
//! view state: `render` is a pure function of the page and its RenderParams.
const Self = @This();
const std = @import("std");
const Config = @import("../config/Config.zig");
const types = @import("./types.zig");
const Markdown = @import("./Markdown.zig");
const Exporter = @import("./Exporter.zig");
const time = @import("../utilities/time.zig");

const c = @import("c");

allocator: std.mem.Allocator,
io: std.Io,
ctx: [*c]c.fz_context,
doc: [*c]c.fz_document,
total_pages: u16,
path: [:0]const u8,
exporter: Exporter,
// Document-stable content box for crop_to_content, computed in aligned space
// (odd pages shifted by stable_box_shift) by sampling text bboxes across the
// document. One box for all pages, so framing stays identical page to page.
// Written only by the main thread (ensureStableBox), read under render_mutex.
stable_box: ?c.fz_rect,
stable_box_done: bool,
stable_box_shift: i32,
sample_bound: c.fz_rect,
// Serializes all mupdf access: fz_context is not thread-safe, and the
// prerender worker renders pages concurrently with the main thread.
render_mutex: std.Io.Mutex,
config: *Config,

pub const SearchHit = struct { page: u16, x0: f32, y0: f32, x1: f32, y1: f32 };
pub const PageBound = struct { x0: f32, y0: f32, x1: f32, y1: f32 };
pub const PageTarget = struct { num: u16, y: f32 };

pub const LinkTarget = union(enum) {
    page: PageTarget,
    uri: []u8, // owned; caller frees with allocator passed to findLinkAtPoint
};

pub const PageLink = struct {
    rect: c.fz_rect,
    target: LinkTarget,
};

pub const OutlineEntry = struct {
    title: []u8,
    depth: u8,
    page: u16,
    y: f32,
};

pub const CropInfo = struct { left: f32, right: f32, top: f32, bottom: f32, auto: bool };

// Manual margins in PDF points, the stable-box crop, and the odd-page shift
// (also PDF points: the crop window is fixed in aligned space and slides over
// the raw page on odd pages).
pub const Crop = struct {
    left: f32 = 0,
    right: f32 = 0,
    top: f32 = 0,
    bottom: f32 = 0,
    to_content: bool = false,
    margin: f32 = 4,
    odd_shift_x: i32 = 0,
};

pub const Scale = union(enum) {
    zoom: f32,
    // Fit inside w x h pixels (grid thumbs).
    fit: struct { w: u32, h: u32 },
};

// Everything a render depends on, by value. The quad slices must stay valid
// for the duration of the call; hits on other pages are ignored.
pub const RenderParams = struct {
    scale: Scale,
    crop: Crop,
    colorize: bool,
    black: i32,
    white: i32,
    search: []const SearchHit = &.{},
    selection: []const SearchHit = &.{},
    highlight: []const SearchHit = &.{},
};

pub const RenderBound = struct { bound: c.fz_rect, ox: f32, oy: f32 };

pub fn init(allocator: std.mem.Allocator, io: std.Io, path: [:0]const u8, config: *Config) !Self {
    if (!std.mem.endsWith(u8, path, ".pdf")) {
        return types.DocumentError.UnsupportedFileFormat;
    }

    const ctx = c.fz_new_context(null, null, c.FZ_STORE_UNLIMITED) orelse {
        std.debug.print("Failed to create mupdf context\n", .{});
        return types.DocumentError.FailedToCreateContext;
    };
    errdefer c.fz_drop_context(ctx);

    c.fz_register_document_handlers(ctx);
    c.fz_set_error_callback(ctx, null, null);
    c.fz_set_warning_callback(ctx, null, null);

    const doc = c.fz_open_document_z(ctx, path.ptr) orelse {
        const err_msg = c.fz_caught_message(ctx);
        std.debug.print("Failed to open document: {s}\n", .{err_msg});
        return types.DocumentError.FailedToOpenDocument;
    };
    errdefer c.fz_drop_document(ctx, doc);

    const page_count = c.fz_count_pages_z(ctx, doc);
    if (page_count <= 0) return types.DocumentError.FailedToOpenDocument;

    return .{
        .allocator = allocator,
        .io = io,
        .ctx = ctx,
        .doc = doc,
        .total_pages = @as(u16, @intCast(page_count)),
        .path = path,
        .exporter = Exporter.init(allocator),
        .stable_box = null,
        .stable_box_done = false,
        .stable_box_shift = 0,
        .sample_bound = c.fz_make_rect(0, 0, 0, 0),
        .render_mutex = .init,
        .config = config,
    };
}

pub fn deinit(self: *Self) void {
    self.exporter.deinit();
    c.fz_drop_document(self.ctx, self.doc);
    c.fz_drop_context(self.ctx);
}

fn lock(self: *Self) void {
    self.render_mutex.lockUncancelable(self.io);
}

fn unlock(self: *Self) void {
    self.render_mutex.unlock(self.io);
}

fn reloadAttempt(self: *Self) !void {
    self.lock();
    defer self.unlock();

    if (self.doc) |doc| {
        c.fz_drop_document(self.ctx, doc);
        self.doc = null;
    }

    const doc = c.fz_open_document_z(self.ctx, self.path.ptr) orelse return types.DocumentError.PageLoadFailed;
    self.doc = doc;

    const page_count = c.fz_count_pages_z(self.ctx, self.doc);
    if (page_count == 0) return types.DocumentError.PageLoadFailed;

    self.total_pages = @as(u16, @intCast(page_count));
    self.stable_box = null;
    self.stable_box_done = false;
}

pub fn reload(self: *Self) !void {
    return self.retry(reloadAttempt, .{self}, types.DocumentError.FailedToOpenDocument);
}

// Re-runs `attempt` while it fails with PageLoadFailed (the file is mid-rewrite)
// until config.general.timeout elapses, then returns `timeout_err`.
pub fn retry(self: *Self, comptime attempt: anytype, args: anytype, comptime timeout_err: anytype) !@typeInfo(@TypeOf(@call(.auto, attempt, args))).error_union.payload {
    const retry_delay = @as(u64, @intFromFloat(self.config.general.retry_delay * @as(f64, std.time.ns_per_s)));
    const timeout = @as(i64, @intFromFloat(self.config.general.timeout * @as(f64, std.time.ms_per_s)));
    const start_time = time.milliTimestamp();

    while (true) {
        if (time.milliTimestamp() - start_time > timeout) {
            std.debug.print("Gave up after {d}s: {t}\n", .{ self.config.general.timeout, timeout_err });
            return timeout_err;
        }
        if (@call(.auto, attempt, args)) |result| {
            return result;
        } else |err| {
            if (err != error.PageLoadFailed) return err;
        }
        time.sleep(retry_delay);
    }
}

// Samples text bboxes across the document and aggregates them with a small
// outlier cut (drops the extreme ~5% per edge), so marginalia or a stray
// clipped block can't widen the box. Falls back to the all-marks bbox on
// pages without text (e.g. scanned books). Main thread only; a no-op once
// computed for this odd_shift_x.
pub fn ensureStableBox(self: *Self, odd_shift_x: i32) void {
    if (self.stable_box_done and self.stable_box_shift == odd_shift_x) return;
    self.lock();
    defer self.unlock();
    self.stable_box_done = true;
    self.stable_box_shift = odd_shift_x;
    self.stable_box = null;
    if (self.doc == null or self.total_pages == 0) return;

    var x0s: [64]f32 = undefined;
    var y0s: [64]f32 = undefined;
    var x1s: [64]f32 = undefined;
    var y1s: [64]f32 = undefined;
    var n: usize = 0;

    // Skip front/back matter (covers, index) on larger documents.
    const skip = self.total_pages / 20;
    const lo: u32 = skip;
    const hi: u32 = self.total_pages - skip;
    const step: u32 = @max(1, (hi - lo) / 48);

    var p: u32 = lo;
    while (p < hi and n < x0s.len) : (p += step) {
        var r: c.fz_rect = undefined;
        var got = c.fz_page_text_bbox_z(self.ctx, self.doc, @intCast(p), &r) != 0;
        if (!got) {
            const page = c.fz_load_page_z(self.ctx, self.doc, @intCast(p)) orelse continue;
            defer c.fz_drop_page(self.ctx, page);
            got = c.fz_page_content_bbox_z(self.ctx, page, &r) != 0;
        }
        if (!got) continue;
        if (n == 0) {
            const page = c.fz_load_page_z(self.ctx, self.doc, @intCast(p)) orelse continue;
            defer c.fz_drop_page(self.ctx, page);
            self.sample_bound = c.fz_bound_page_z(self.ctx, page);
        }
        // Normalize odd pages into aligned space so the box is parity-correct.
        const shift: f32 = if (p % 2 == 1) @floatFromInt(odd_shift_x) else 0;
        x0s[n] = r.x0 + shift;
        y0s[n] = r.y0;
        x1s[n] = r.x1 + shift;
        y1s[n] = r.y1;
        n += 1;
    }
    if (n == 0) return;

    const asc = std.sort.asc(f32);
    std.sort.pdq(f32, x0s[0..n], {}, asc);
    std.sort.pdq(f32, y0s[0..n], {}, asc);
    std.sort.pdq(f32, x1s[0..n], {}, asc);
    std.sort.pdq(f32, y1s[0..n], {}, asc);

    const cut = n / 20;
    const box = c.fz_make_rect(x0s[cut], y0s[cut], x1s[n - 1 - cut], y1s[n - 1 - cut]);
    if (box.x1 > box.x0 and box.y1 > box.y0) self.stable_box = box;
}

// The effective crop as L/R/T/B margins: the manual margins, or the
// stable-box-derived ones when only crop-to-content is active.
pub fn cropInfo(self: *Self, crop: Crop) ?CropInfo {
    if (crop.left != 0 or crop.right != 0 or crop.top != 0 or crop.bottom != 0) {
        return .{ .left = crop.left, .right = crop.right, .top = crop.top, .bottom = crop.bottom, .auto = false };
    }
    if (crop.to_content) {
        self.ensureStableBox(crop.odd_shift_x);
        if (self.stable_box) |sb| {
            const pb = self.sample_bound;
            const m = crop.margin;
            return .{
                .left = @max(0, sb.x0 - m - pb.x0),
                .right = @max(0, pb.x1 - (sb.x1 + m)),
                .top = @max(0, sb.y0 - m - pb.y0),
                .bottom = @max(0, pb.y1 - (sb.y1 + m)),
                .auto = true,
            };
        }
    }
    return null;
}

fn renderBoundLocked(self: *Self, page: [*c]c.fz_page, crop: Crop) RenderBound {
    const page_bound = c.fz_bound_page_z(self.ctx, page);
    var rb = RenderBound{ .bound = page_bound, .ox = 0, .oy = 0 };

    if (crop.left != 0 or crop.right != 0 or crop.top != 0 or crop.bottom != 0) {
        var inset = page_bound;
        inset.x0 += crop.left;
        inset.x1 -= crop.right;
        inset.y0 += crop.top;
        inset.y1 -= crop.bottom;
        if (inset.x1 > inset.x0 and inset.y1 > inset.y0) {
            rb = .{ .bound = inset, .ox = inset.x0, .oy = inset.y0 };
        }
    }

    if (crop.to_content) {
        if (self.stable_box) |sb| {
            const m = crop.margin;
            var cb = sb;
            cb.x0 = @max(rb.bound.x0, cb.x0 - m);
            cb.y0 = @max(rb.bound.y0, cb.y0 - m);
            cb.x1 = @min(rb.bound.x1, cb.x1 + m);
            cb.y1 = @min(rb.bound.y1, cb.y1 + m);
            if (cb.x1 > cb.x0 and cb.y1 > cb.y0) {
                rb = .{ .bound = cb, .ox = cb.x0, .oy = cb.y0 };
            }
        }
    }
    return rb;
}

// The box a render of `page` under `crop` covers, in PDF points.
pub fn renderBound(self: *Self, page_number: u16, crop: Crop) !RenderBound {
    self.lock();
    defer self.unlock();
    if (self.doc == null or page_number >= self.total_pages) return types.DocumentError.PageLoadFailed;
    const page = c.fz_load_page_z(self.ctx, self.doc, @as(c_int, @intCast(page_number))) orelse
        return types.DocumentError.PageLoadFailed;
    defer c.fz_drop_page(self.ctx, page);
    return self.renderBoundLocked(page, crop);
}

fn invertRects(self: *Self, pix: [*c]c.fz_pixmap, page_num: u16, ctm: c.fz_matrix, hits: []const SearchHit) void {
    for (hits) |h| {
        if (h.page != page_num) continue;
        const r = c.fz_transform_rect(c.fz_make_rect(h.x0, h.y0, h.x1, h.y1), ctm);
        c.fz_invert_pixmap_rect(self.ctx, pix, c.fz_irect_from_rect(r));
    }
}

// Blends pixels toward marker yellow. Runs after colorize, so it reads the
// final page colors and works for both normal and inverted modes.
fn tintRects(self: *Self, pix: [*c]c.fz_pixmap, page_num: u16, ctm: c.fz_matrix, hits: []const SearchHit) void {
    if (hits.len == 0) return;
    const w: i32 = c.fz_pixmap_width(self.ctx, pix);
    const h: i32 = c.fz_pixmap_height(self.ctx, pix);
    if (w <= 0 or h <= 0) return;
    const samples = c.fz_pixmap_samples(self.ctx, pix);
    const stride: usize = @intCast(w * 3);
    const target = [3]i32{ 255, 220, 80 };
    for (hits) |hit| {
        if (hit.page != page_num) continue;
        const r = c.fz_transform_rect(c.fz_make_rect(hit.x0, hit.y0, hit.x1, hit.y1), ctm);
        const ir = c.fz_irect_from_rect(r);
        const x0: usize = @intCast(std.math.clamp(ir.x0, 0, w));
        const x1: usize = @intCast(std.math.clamp(ir.x1, 0, w));
        const y0: usize = @intCast(std.math.clamp(ir.y0, 0, h));
        const y1: usize = @intCast(std.math.clamp(ir.y1, 0, h));
        var y = y0;
        while (y < y1) : (y += 1) {
            var p = samples + y * stride + x0 * 3;
            var x = x0;
            while (x < x1) : (x += 1) {
                inline for (0..3) |i| {
                    const old: i32 = p[i];
                    p[i] = @intCast(old + ((target[i] - old) * 77 >> 8));
                }
                p += 3;
            }
        }
    }
}

// Renders with retry while the file is mid-rewrite.
pub fn render(self: *Self, page_number: u16, params: RenderParams) !types.EncodedImage {
    return self.retry(renderOnce, .{ self, page_number, params }, types.DocumentError.FailedToRenderPage);
}

pub fn renderOnce(self: *Self, page_number: u16, params: RenderParams) !types.EncodedImage {
    self.lock();
    defer self.unlock();

    if (self.doc == null or page_number >= self.total_pages) return types.DocumentError.PageLoadFailed;
    const page = c.fz_load_page_z(self.ctx, self.doc, @as(c_int, @intCast(page_number))) orelse
        return types.DocumentError.PageLoadFailed;
    defer c.fz_drop_page(self.ctx, page);

    const rb = self.renderBoundLocked(page, params.crop);
    const w_pdf = rb.bound.x1 - rb.bound.x0;
    const h_pdf = rb.bound.y1 - rb.bound.y0;

    const zoom: f32 = switch (params.scale) {
        .zoom => |z| z,
        .fit => |f| @min(
            @as(f32, @floatFromInt(f.w)) / @max(1.0, w_pdf),
            @as(f32, @floatFromInt(f.h)) / @max(1.0, h_pdf),
        ),
    };

    const full_w = @max(1.0, zoom * w_pdf);
    const full_h = @max(1.0, zoom * h_pdf);

    const bbox = c.fz_make_irect(0, 0, @intFromFloat(full_w), @intFromFloat(full_h));
    const pix = c.fz_new_pixmap_rgb_z(self.ctx, bbox);
    if (pix == null) return types.DocumentError.FailedToRenderPage;
    defer c.fz_drop_pixmap(self.ctx, pix);
    c.fz_clear_pixmap_with_value(self.ctx, pix, 0xFF);

    const shift_pdf: f32 = if (page_number % 2 == 1) @floatFromInt(params.crop.odd_shift_x) else 0;
    const ctm = c.fz_pre_translate(c.fz_scale(zoom, zoom), -rb.ox + shift_pdf, -rb.oy);
    if (c.fz_run_page_into_z(self.ctx, page, ctm, pix) == 0) return types.DocumentError.FailedToRenderPage;
    self.invertRects(pix, page_number, ctm, params.search);
    self.invertRects(pix, page_number, ctm, params.selection);

    if (params.colorize) {
        c.fz_tint_pixmap(self.ctx, pix, params.black, params.white);
    }
    self.tintRects(pix, page_number, ctm, params.highlight);

    const width = @as(usize, @intCast(@abs(bbox.x1)));
    const height = @as(usize, @intCast(@abs(bbox.y1)));
    return self.exporter.encode(self.ctx, pix, width, height, rb.ox, rb.oy);
}

// Writes a copy of the document with the crop + oddx baked into the page
// boxes (lossless; for printing without margins).
pub fn exportCropped(self: *Self, out_path: [:0]const u8, keep_id: bool, crop: Crop) !void {
    const ci = self.cropInfo(crop) orelse CropInfo{ .left = 0, .right = 0, .top = 0, .bottom = 0, .auto = false };
    if (ci.left == 0 and ci.right == 0 and ci.top == 0 and ci.bottom == 0 and crop.odd_shift_x == 0)
        return error.NothingToApply;
    self.lock();
    defer self.unlock();
    if (c.fz_export_cropped_z(self.ctx, self.path.ptr, out_path.ptr, ci.left, ci.right, ci.top, ci.bottom, crop.odd_shift_x, @intFromBool(keep_id)) == 0)
        return error.ExportFailed;
}

// Raw (uncropped) page box in PDF points.
pub fn getPageBound(self: *Self, page_number: u16) PageBound {
    self.lock();
    defer self.unlock();
    const page = c.fz_load_page_z(self.ctx, self.doc, @as(c_int, @intCast(page_number))) orelse
        return .{ .x0 = 0, .y0 = 0, .x1 = 0, .y1 = 0 };
    defer c.fz_drop_page(self.ctx, page);
    const b = c.fz_bound_page_z(self.ctx, page);
    return .{ .x0 = b.x0, .y0 = b.y0, .x1 = b.x1, .y1 = b.y1 };
}

const VisitData = struct {
    self: *Self,
    out: *std.ArrayList(OutlineEntry),
    allocator: std.mem.Allocator,
    failed: bool,
};

fn outlineVisitCb(userdata: ?*anyopaque, title: [*c]const u8, depth: c_int, uri: [*c]const u8) callconv(.c) void {
    const data = @as(*VisitData, @ptrCast(@alignCast(userdata.?)));
    if (data.failed) return;
    const title_len: usize = if (title != null) std.mem.len(title) else 0;
    const uri_len: usize = if (uri != null) std.mem.len(uri) else 0;

    var page: u16 = 0;
    var y: f32 = 0;
    if (uri != null and uri_len > 0) {
        const resolved = c.fz_resolve_link_target_z(data.self.ctx, data.self.doc, uri, &y);
        if (resolved >= 0 and resolved < data.self.total_pages) {
            page = @intCast(resolved);
        }
    }
    const title_src: []const u8 = if (title != null) title[0..title_len] else "";
    const title_dup = data.allocator.dupe(u8, title_src) catch {
        data.failed = true;
        return;
    };
    data.out.append(data.allocator, .{
        .title = title_dup,
        .depth = @intCast(@min(depth, 255)),
        .page = page,
        .y = y,
    }) catch {
        data.allocator.free(title_dup);
        data.failed = true;
    };
}

pub fn loadOutline(self: *Self, allocator: std.mem.Allocator) ![]OutlineEntry {
    self.lock();
    defer self.unlock();

    var out: std.ArrayList(OutlineEntry) = .empty;
    errdefer {
        for (out.items) |e| allocator.free(e.title);
        out.deinit(allocator);
    }
    var data = VisitData{ .self = self, .out = &out, .allocator = allocator, .failed = false };
    c.fz_walk_outline_z(self.ctx, self.doc, &data, outlineVisitCb);
    if (data.failed) return error.OutOfMemory;
    return out.toOwnedSlice(allocator);
}

pub fn loadLinks(self: *Self, allocator: std.mem.Allocator, page_number: u16) ![]PageLink {
    self.lock();
    defer self.unlock();

    var out: std.ArrayList(PageLink) = .empty;
    errdefer {
        for (out.items) |item| switch (item.target) {
            .uri => |u| allocator.free(u),
            .page => {},
        };
        out.deinit(allocator);
    }

    const page = c.fz_load_page_z(self.ctx, self.doc, @as(c_int, @intCast(page_number))) orelse return out.toOwnedSlice(allocator);
    defer c.fz_drop_page(self.ctx, page);

    const links = c.fz_load_links_z(self.ctx, page) orelse return out.toOwnedSlice(allocator);
    defer c.fz_drop_link(self.ctx, links);

    var node: ?*c.fz_link = links;
    while (node) |link| : (node = link.next) {
        if (link.uri == null) continue;
        const uri_zlen = std.mem.len(link.uri);
        const uri_slice = link.uri[0..uri_zlen];

        var dest_y: f32 = 0;
        const target: LinkTarget = if (c.fz_is_external_link(self.ctx, link.uri) != 0) blk: {
            const owned = try allocator.dupe(u8, uri_slice);
            break :blk .{ .uri = owned };
        } else blk: {
            const resolved = c.fz_resolve_link_target_z(self.ctx, self.doc, link.uri, &dest_y);
            if (resolved < 0 or resolved >= self.total_pages) continue;
            break :blk .{ .page = .{ .num = @as(u16, @intCast(resolved)), .y = dest_y } };
        };

        try out.append(allocator, .{ .rect = link.rect, .target = target });
    }
    return out.toOwnedSlice(allocator);
}

pub fn getDocumentKey(self: *Self, allocator: std.mem.Allocator) ![]u8 {
    self.lock();
    defer self.unlock();

    var id_buf: [256]u8 = undefined;
    const id_len = c.fz_pdf_id_hex_z(self.ctx, self.doc, &id_buf, id_buf.len);
    if (id_len > 0) {
        return std.fmt.allocPrint(allocator, "pdf-id:{s}", .{id_buf[0..@as(usize, @intCast(id_len))]});
    }

    if (std.Io.Dir.cwd().readFileAlloc(self.io, self.path, allocator, .limited(1024 * 1024))) |buf| {
        defer allocator.free(buf);
        if (buf.len > 0) {
            var digest: [32]u8 = undefined;
            std.crypto.hash.sha2.Sha256.hash(buf[0..@min(buf.len, 1024 * 1024)], &digest, .{});
            const hex = std.fmt.bytesToHex(digest, .lower);
            return std.fmt.allocPrint(allocator, "sha256-1mb:{s}", .{hex});
        }
    } else |_| {}

    return std.fmt.allocPrint(allocator, "path:{s}", .{self.path});
}

pub fn findLinkAtPoint(
    self: *Self,
    allocator: std.mem.Allocator,
    page_number: u16,
    pdf_x: f32,
    pdf_y: f32,
) ?LinkTarget {
    self.lock();
    defer self.unlock();

    const page = c.fz_load_page_z(self.ctx, self.doc, @as(c_int, @intCast(page_number))) orelse return null;
    defer c.fz_drop_page(self.ctx, page);

    const links = c.fz_load_links_z(self.ctx, page) orelse return null;
    defer c.fz_drop_link(self.ctx, links);

    var node: ?*c.fz_link = links;
    while (node) |link| : (node = link.next) {
        const r = link.rect;
        if (pdf_x < r.x0 or pdf_x > r.x1 or pdf_y < r.y0 or pdf_y > r.y1) continue;
        if (link.uri == null) continue;
        const uri_zlen = std.mem.len(link.uri);
        const uri_slice = link.uri[0..uri_zlen];

        if (c.fz_is_external_link(self.ctx, link.uri) != 0) {
            const owned = allocator.dupe(u8, uri_slice) catch return null;
            return .{ .uri = owned };
        }
        var dest_y: f32 = 0;
        const resolved = c.fz_resolve_link_target_z(self.ctx, self.doc, link.uri, &dest_y);
        if (resolved < 0 or resolved >= self.total_pages) continue;
        return .{ .page = .{ .num = @as(u16, @intCast(resolved)), .y = dest_y } };
    }
    return null;
}

pub fn searchPage(self: *Self, allocator: std.mem.Allocator, page_number: u16, needle: [*:0]const u8, out: *std.ArrayList(SearchHit)) !void {
    self.lock();
    defer self.unlock();

    var quads: [128]c.fz_quad = undefined;
    const n = c.fz_search_page_z(self.ctx, self.doc, @as(c_int, @intCast(page_number)), needle, &quads, quads.len);
    for (quads[0..@intCast(n)]) |q| {
        const r = c.fz_rect_from_quad(q);
        try out.append(allocator, .{ .page = page_number, .x0 = r.x0, .y0 = r.y0, .x1 = r.x1, .y1 = r.y1 });
    }
}

// Snaps (a, b) to characters, fills `out` with the selection's highlight quads,
// and returns the selected text (caller owns).
pub fn selectText(
    self: *Self,
    allocator: std.mem.Allocator,
    page_number: u16,
    ax: f32,
    ay: f32,
    bx: f32,
    by: f32,
    out: *std.ArrayList(SearchHit),
) ![]u8 {
    self.lock();
    defer self.unlock();

    var quads: [256]c.fz_quad = undefined;
    var quad_count: c_int = 0;
    const text_buf = try allocator.alloc(u8, 16384);
    defer allocator.free(text_buf);
    const n = c.fz_selection_z(
        self.ctx,
        self.doc,
        @as(c_int, @intCast(page_number)),
        ax,
        ay,
        bx,
        by,
        &quads,
        quads.len,
        &quad_count,
        text_buf.ptr,
        @intCast(text_buf.len),
    );
    for (quads[0..@intCast(quad_count)]) |q| {
        const r = c.fz_rect_from_quad(q);
        try out.append(allocator, .{ .page = page_number, .x0 = r.x0, .y0 = r.y0, .x1 = r.x1, .y1 = r.y1 });
    }
    return allocator.dupe(u8, text_buf[0..@intCast(n)]);
}

pub fn lineTextAt(self: *Self, allocator: std.mem.Allocator, page_number: u16, x: f32, y: f32) ![]u8 {
    self.lock();
    defer self.unlock();

    var buf: [512]u8 = undefined;
    const n = c.fz_line_text_at_z(self.ctx, self.doc, @as(c_int, @intCast(page_number)), x, y, &buf, buf.len);
    return allocator.dupe(u8, buf[0..@intCast(n)]);
}

fn extractEventBridge(ud: ?*anyopaque, kind: c_int, chars: [*c]const c.fz_char_z, n: c_int, str: [*c]const u8) callconv(.c) void {
    // Markdown.Char and fz_char_z have the same extern layout; pointer-cast across the FFI.
    const md_chars: ?[*]const Markdown.Char = if (chars != null) @ptrCast(chars) else null;
    const md_str: ?[*:0]const u8 = if (str != null) @ptrCast(str) else null;
    Markdown.eventCallback(ud, kind, md_chars, n, md_str);
}

pub fn writePagesText(
    self: *Self,
    start_page: u16,
    end_page: u16,
    path: [:0]const u8,
    scale: f32,
    black: c_int,
    white: c_int,
    on_progress: ?*const fn (?*anyopaque, c_int, c_int) callconv(.c) void,
    progress_userdata: ?*anyopaque,
    page_hook: ?Markdown.PageHook,
    page_hook_ctx: ?*anyopaque,
) !void {
    var file = try std.Io.Dir.createFileAbsolute(self.io, path, .{});
    defer file.close(self.io);
    var buf: [4096]u8 = undefined;
    var fw = file.writer(self.io, &buf);

    try fw.interface.writeAll("<!-- markdownlint-disable -->\n\n");

    var md = Markdown.init(self.allocator, &fw.interface);
    defer md.deinit();
    md.first_page = start_page;
    md.on_page = page_hook;
    md.on_page_ctx = page_hook_ctx;

    self.lock();
    defer self.unlock();

    // Image dir = dirname(path).
    const slash = std.mem.lastIndexOfScalar(u8, path, '/') orelse 0;
    const image_dir = try self.allocator.dupeSentinel(u8, if (slash > 0) path[0..slash] else ".", 0);
    defer self.allocator.free(image_dir);

    const rc = c.fz_extract_pages_z(
        self.ctx,
        self.doc,
        @as(c_int, @intCast(start_page)),
        @as(c_int, @intCast(end_page)),
        scale,
        black,
        white,
        image_dir.ptr,
        extractEventBridge,
        &md,
        on_progress,
        progress_userdata,
    );
    if (rc == 0) return types.DocumentError.FailedToRenderPage;
    try md.finalize();
    try fw.interface.flush();
    if (md.write_failed) return types.DocumentError.FailedToRenderPage;
}
