const Self = @This();
const std = @import("std");
const fastb64z = @import("fastb64z");
const Config = @import("../config/Config.zig");
pub const types = @import("./types.zig");
const Utilities = @import("../utilities/Utilities.zig");
const Markdown = @import("./Markdown.zig");

const time = @import("../utilities/time.zig");

const c = @cImport({
    @cInclude("fitz-z.h");
    @cInclude("mupdf/fitz.h");
    @cInclude("mupdf/pdf.h");
});

allocator: std.mem.Allocator,
io: std.Io,
ctx: [*c]c.fz_context,
doc: [*c]c.fz_document,
total_pages: u16,
current_page_number: u16,
path: [:0]const u8,
active_zoom: f32,
default_zoom: f32,
width_mode: bool,
// Locked fit-to-width: every render recomputes zoom so the cropped page width
// exactly fills the window (or the column width in spread = two pages). Tracks
// window resize and crop changes; cleared by a manual zoom (i/o, :N%).
fit_width: bool,
// Two-column continuous flow: the right column continues the strip where
// the left column's bottom ends, so pages may straddle the column break.
spread: bool,
crop_to_content: bool,
crop_margin: f32,
// Manual margin crop in PDF points, applied to every page before layout.
crop_left: f32,
crop_right: f32,
crop_top: f32,
crop_bottom: f32,
// Document-stable content box for crop_to_content, computed lazily by
// sampling text bboxes across the document. One box for all pages, so
// framing stays identical page to page.
stable_box: ?c.fz_rect,
stable_box_done: bool,
sample_bound: c.fz_rect,
odd_shift_x: i32,
pending_scroll_pdf_y: ?f32,
pix_scroll_x: i32,
pix_scroll_y: i32,
rendered_w: u32,
last_viewport_w: u32,
search_highlights: []const SearchHit,
selection_quads: []const SearchHit,
highlight_quads: []const SearchHit,
// How renders reach the terminal: shm = raw RGB in a POSIX shared-memory
// object (no PNG encode/decode at all), temp_file = PNG in png_dir (kitty
// t=t), stream = in-memory PNG bytes (the SSH fallback).
transfer: types.Transfer,
png_dir: ?[]const u8,
png_seq: u32,
session_tag: u32,
// Serializes all mupdf access: fz_context is not thread-safe, and the
// prerender worker renders pages concurrently with the main thread.
render_mutex: std.Io.Mutex,
config: *Config,

pub fn init(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: [:0]const u8,
    initial_page: ?u16,
    config: *Config,
) !Self {
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

    const total_pages = @as(u16, @intCast(c.fz_count_pages(ctx, doc)));

    const current_page_number = if (initial_page) |page| blk: {
        if (page < 1 or page > total_pages) {
            return types.DocumentError.InvalidPageNumber;
        }
        break :blk page - 1;
    } else 0;

    return .{
        .allocator = allocator,
        .io = io,
        .ctx = ctx,
        .doc = doc,
        .total_pages = total_pages,
        .current_page_number = current_page_number,
        .path = path,
        .active_zoom = 0,
        .default_zoom = 0,
        .width_mode = false,
        .fit_width = false,
        .spread = false,
        .crop_to_content = false,
        .crop_margin = 4,
        .crop_left = 0,
        .crop_right = 0,
        .crop_top = 0,
        .crop_bottom = 0,
        .stable_box = null,
        .stable_box_done = false,
        .sample_bound = c.fz_make_rect(0, 0, 0, 0),
        .odd_shift_x = 0,
        .pending_scroll_pdf_y = null,
        .pix_scroll_x = 0,
        .pix_scroll_y = 0,
        .rendered_w = 0,
        .last_viewport_w = 0,
        .search_highlights = &.{},
        .selection_quads = &.{},
        .highlight_quads = &.{},
        .transfer = .stream,
        .png_dir = null,
        .png_seq = 0,
        .session_tag = @truncate(@as(u64, @bitCast(time.nowRealSeconds()))),
        .render_mutex = .init,
        .config = config,
    };
}

pub fn setTransfer(self: *Self, transfer: types.Transfer, tmp_dir: ?[]const u8) void {
    self.transfer = transfer;
    if (tmp_dir) |dir| self.png_dir = self.allocator.dupe(u8, dir) catch null;
}

pub fn deinit(self: *Self) void {
    if (self.png_dir) |d| self.allocator.free(d);
    if (self.search_highlights.len > 0) self.allocator.free(self.search_highlights);
    if (self.selection_quads.len > 0) self.allocator.free(self.selection_quads);
    if (self.highlight_quads.len > 0) self.allocator.free(self.highlight_quads);
    c.fz_drop_document(self.ctx, self.doc);
    c.fz_drop_context(self.ctx);
}

fn reloadAttempt(self: *Self) bool {
    self.render_mutex.lockUncancelable(self.io);
    defer self.render_mutex.unlock(self.io);

    if (self.doc) |doc| {
        c.fz_drop_document(self.ctx, doc);
        self.doc = null;
    }

    const doc = c.fz_open_document_z(self.ctx, self.path.ptr) orelse return false;
    self.doc = doc;

    const page_count = c.fz_count_pages_z(self.ctx, self.doc);
    if (page_count == 0) return false;

    self.total_pages = @as(u16, @intCast(page_count));
    if (self.current_page_number >= self.total_pages) {
        self.current_page_number = self.total_pages - 1;
    }
    self.stable_box = null;
    self.stable_box_done = false;
    return true;
}

pub fn reloadDocument(self: *Self) !void {
    const retry_delay = @as(u64, @intFromFloat(self.config.general.retry_delay * @as(f64, std.time.ns_per_s)));
    const timeout = @as(i64, @intFromFloat(self.config.general.timeout * @as(f64, std.time.ms_per_s)));
    const start_time = time.milliTimestamp();

    while (true) {
        const now = time.milliTimestamp();
        if (now - start_time > timeout) {
            std.debug.print("Failed to reload document\n", .{});
            return types.DocumentError.FailedToOpenDocument;
        }
        if (self.reloadAttempt()) return;
        time.sleep(retry_delay);
    }
}

pub fn goToPage(self: *Self, page_num: u16) bool {
    if (page_num >= 1 and page_num <= self.total_pages and page_num != self.current_page_number + 1) {
        self.current_page_number = page_num - 1;
        return true;
    }
    return false;
}

pub fn changePage(self: *Self, delta: i32) bool {
    const new_page = @as(i32, @intCast(self.current_page_number)) + delta;

    if (new_page >= 0 and new_page < self.total_pages) {
        self.current_page_number = @as(u16, @intCast(new_page));
        return true;
    }
    return false;
}

fn calculateZoomLevel(self: *Self, window_width: u32, window_height: u32, bound: c.fz_rect) void {
    var scale: f32 = 0;
    // Width-fit (spread/width-mode/fit-width) fills the column/window width and
    // scrolls vertically; otherwise fit the whole page.
    if (self.width_mode or self.spread or self.fit_width) {
        scale = @as(f32, @floatFromInt(window_width)) / bound.x1;
    } else {
        scale = @min(
            @as(f32, @floatFromInt(window_width)) / bound.x1,
            @as(f32, @floatFromInt(window_height)) / bound.y1,
        );
    }

    if (self.fit_width) {
        // Locked: always track the current window/crop, ignoring saved/manual zoom.
        self.default_zoom = scale * self.config.general.size;
        self.active_zoom = self.default_zoom;
    } else {
        // initial zoom
        if (self.default_zoom == 0) {
            self.default_zoom = scale * self.config.general.size;
        }
        if (self.active_zoom == 0) {
            self.active_zoom = self.default_zoom;
        }
    }

    self.active_zoom = @max(self.active_zoom, self.config.general.zoom_min);
}

const RenderBound = struct { bound: c.fz_rect, ox: f32, oy: f32 };

// Samples text bboxes across the document and aggregates them with a small
// outlier cut (drops the extreme ~5% per edge), so marginalia or a stray
// clipped block can't widen the box. Falls back to the all-marks bbox on
// pages without text (e.g. scanned books).
fn computeStableBox(self: *Self) void {
    self.stable_box_done = true;
    if (self.total_pages == 0) return;

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
            self.sample_bound = c.fz_bound_page(self.ctx, page);
        }
        // Normalize odd pages into aligned space so the box is parity-correct.
        const shift: f32 = if (p % 2 == 1) @floatFromInt(self.odd_shift_x) else 0;
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

fn pageRenderBound(self: *Self, page: [*c]c.fz_page) RenderBound {
    const page_bound = c.fz_bound_page(self.ctx, page);
    var rb = RenderBound{ .bound = page_bound, .ox = 0, .oy = 0 };

    if (self.crop_left != 0 or self.crop_right != 0 or self.crop_top != 0 or self.crop_bottom != 0) {
        var inset = page_bound;
        inset.x0 += self.crop_left;
        inset.x1 -= self.crop_right;
        inset.y0 += self.crop_top;
        inset.y1 -= self.crop_bottom;
        if (inset.x1 > inset.x0 and inset.y1 > inset.y0) {
            rb = .{ .bound = inset, .ox = inset.x0, .oy = inset.y0 };
        }
    }

    if (self.crop_to_content) {
        if (!self.stable_box_done) self.computeStableBox();
        if (self.stable_box) |sb| {
            const m = self.crop_margin;
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

fn runPageInto(self: *Self, page: [*c]c.fz_page, ctm: c.fz_matrix, pix: [*c]c.fz_pixmap) void {
    const dev = c.fz_new_draw_device(self.ctx, ctm, pix);
    defer c.fz_drop_device(self.ctx, dev);
    c.fz_run_page(self.ctx, page, dev, c.fz_identity, null);
    c.fz_close_device(self.ctx, dev);
}

fn invertRects(self: *Self, pix: [*c]c.fz_pixmap, page_num: u16, ctm: c.fz_matrix, hits: []const SearchHit) void {
    for (hits) |h| {
        if (h.page != page_num) continue;
        const r = c.fz_transform_rect(c.fz_make_rect(h.x0, h.y0, h.x1, h.y1), ctm);
        c.fz_invert_pixmap_rect(self.ctx, pix, c.fz_irect_from_rect(r));
    }
}

fn highlightHits(self: *Self, pix: [*c]c.fz_pixmap, page_num: u16, ctm: c.fz_matrix) void {
    self.invertRects(pix, page_num, ctm, self.search_highlights);
    self.invertRects(pix, page_num, ctm, self.selection_quads);
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

pub fn renderPage(
    self: *Self,
    page_number: u16,
    window_width: u32,
    window_height: u32,
) !types.EncodedImage {
    const retry_delay = @as(u64, @intFromFloat(self.config.general.retry_delay * @as(f64, std.time.ns_per_s)));
    const timeout = @as(i64, @intFromFloat(self.config.general.timeout * @as(f64, std.time.ms_per_s)));
    const start_time = time.milliTimestamp();

    while (true) {
        const now = time.milliTimestamp();
        if (now - start_time > timeout) {
            std.debug.print("Failed to render page\n", .{});
            return types.DocumentError.FailedToRenderPage;
        }
        if (self.renderAttempt(page_number, window_width, window_height)) |encoded| {
            return encoded;
        } else |err| {
            if (err != error.PageLoadFailed) return err;
        }
        time.sleep(retry_delay);
    }
}

fn renderAttempt(
    self: *Self,
    page_number: u16,
    window_width: u32,
    window_height: u32,
) !types.EncodedImage {
    self.render_mutex.lockUncancelable(self.io);
    defer self.render_mutex.unlock(self.io);

    if (self.doc == null or page_number >= self.total_pages) return error.PageLoadFailed;
    const page = c.fz_load_page_z(self.ctx, self.doc, @as(c_int, @intCast(page_number))) orelse
        return error.PageLoadFailed;
    defer c.fz_drop_page(self.ctx, page);

    const rb = self.pageRenderBound(page);
    const render_w_pdf = rb.bound.x1 - rb.bound.x0;
    const render_h_pdf = rb.bound.y1 - rb.bound.y0;

    self.calculateZoomLevel(window_width, window_height, c.fz_make_rect(0, 0, render_w_pdf, render_h_pdf));

    const full_w = @max(1.0, self.active_zoom * render_w_pdf);
    const full_h = @max(1.0, self.active_zoom * render_h_pdf);

    const bbox = c.fz_make_irect(0, 0, @intFromFloat(full_w), @intFromFloat(full_h));
    const pix = c.fz_new_pixmap_with_bbox(self.ctx, c.fz_device_rgb(self.ctx), bbox, null, 0);
    defer c.fz_drop_pixmap(self.ctx, pix);
    c.fz_clear_pixmap_with_value(self.ctx, pix, 0xFF);

    const scale = c.fz_scale(self.active_zoom, self.active_zoom);
    // odd_shift_x is in PDF points; the crop window is fixed in aligned
    // space and slides over the raw page on odd pages (crop post-offset).
    const shift_pdf: f32 = if (page_number % 2 == 1)
        @as(f32, @floatFromInt(self.odd_shift_x))
    else
        0;
    const ctm = c.fz_pre_translate(scale, -rb.ox + shift_pdf, -rb.oy);
    self.runPageInto(page, ctm, pix);
    self.highlightHits(pix, page_number, ctm);

    if (self.config.general.colorize) {
        c.fz_tint_pixmap(self.ctx, pix, self.config.general.black, self.config.general.white);
    }
    self.tintRects(pix, page_number, ctm, self.highlight_quads);

    const width = @as(usize, @intCast(@abs(bbox.x1)));
    const height = @as(usize, @intCast(@abs(bbox.y1)));

    self.rendered_w = @intCast(width);
    self.last_viewport_w = window_width;

    return self.exportPixmap(pix, width, height, rb.ox, rb.oy);
}

// Hands a finished pixmap to the configured transfer: shm raw RGB, PNG temp
// file, or in-memory PNG. Caller holds render_mutex.
fn exportPixmap(self: *Self, pix: [*c]c.fz_pixmap, width: usize, height: usize, ox: f32, oy: f32) !types.EncodedImage {
    // Raw RGB in shared memory skips PNG encode and decode entirely; the
    // PNG paths compress 10-40x for text pages, which matters for the
    // temp-file and especially the streamed SSH fallback.
    if (self.transfer == .shm) {
        self.png_seq +%= 1;
        var name_buf: [32]u8 = undefined; // macOS shm names cap at 31 chars
        const name = std.fmt.bufPrintZ(&name_buf, "/tre{x}-{x}", .{ self.session_tag, self.png_seq }) catch
            return types.DocumentError.FailedToRenderPage;
        if (c.fz_pixmap_to_shm_z(self.ctx, pix, name.ptr) != 0) {
            return types.EncodedImage{
                .data = try self.allocator.dupe(u8, name),
                .kind = .shm_rgb,
                .width = @as(u16, @intCast(width)),
                .height = @as(u16, @intCast(height)),
                .origin_x = ox,
                .origin_y = oy,
            };
        }
        // shm failed (exhausted or unsupported): fall through to streamed PNG.
    }

    if (self.transfer == .temp_file) {
        if (self.png_dir) |dir| {
            self.png_seq +%= 1;
            const path = try std.fmt.allocPrint(
                self.allocator,
                "{s}/tty-graphics-protocol-termre-{d}-{d}.png",
                .{ dir, self.session_tag, self.png_seq },
            );
            errdefer self.allocator.free(path);
            var pathz_buf: [1024]u8 = undefined;
            const pathz = std.fmt.bufPrintZ(&pathz_buf, "{s}", .{path}) catch return types.DocumentError.FailedToRenderPage;
            if (c.fz_save_pixmap_png_z(self.ctx, pix, pathz.ptr) == 0) {
                return types.DocumentError.FailedToRenderPage;
            }
            return types.EncodedImage{
                .data = path,
                .kind = .png_path,
                .width = @as(u16, @intCast(width)),
                .height = @as(u16, @intCast(height)),
                .origin_x = ox,
                .origin_y = oy,
            };
        }
    }

    var png_len: usize = 0;
    const png_ptr = c.fz_pixmap_png_z(self.ctx, pix, &png_len) orelse
        return types.DocumentError.FailedToRenderPage;
    defer std.c.free(png_ptr);
    const data = try self.allocator.dupe(u8, png_ptr[0..png_len]);

    return types.EncodedImage{
        .data = data,
        .kind = .png_bytes,
        .width = @as(u16, @intCast(width)),
        .height = @as(u16, @intCast(height)),
        .origin_x = ox,
        .origin_y = oy,
    };
}

// Renders a page scaled to fit max_w/max_h pixels, without touching the
// reading zoom or viewport state — for the grid-mode thumbnails.
pub fn renderThumb(self: *Self, page_number: u16, max_w: u32, max_h: u32) !types.EncodedImage {
    self.render_mutex.lockUncancelable(self.io);
    defer self.render_mutex.unlock(self.io);

    if (self.doc == null or page_number >= self.total_pages) return error.PageLoadFailed;
    const page = c.fz_load_page_z(self.ctx, self.doc, @as(c_int, @intCast(page_number))) orelse
        return error.PageLoadFailed;
    defer c.fz_drop_page(self.ctx, page);

    const rb = self.pageRenderBound(page);
    const w_pdf = @max(1.0, rb.bound.x1 - rb.bound.x0);
    const h_pdf = @max(1.0, rb.bound.y1 - rb.bound.y0);
    const zoom = @min(@as(f32, @floatFromInt(max_w)) / w_pdf, @as(f32, @floatFromInt(max_h)) / h_pdf);

    const full_w = @max(1.0, zoom * w_pdf);
    const full_h = @max(1.0, zoom * h_pdf);
    const bbox = c.fz_make_irect(0, 0, @intFromFloat(full_w), @intFromFloat(full_h));
    const pix = c.fz_new_pixmap_with_bbox(self.ctx, c.fz_device_rgb(self.ctx), bbox, null, 0);
    defer c.fz_drop_pixmap(self.ctx, pix);
    c.fz_clear_pixmap_with_value(self.ctx, pix, 0xFF);

    const shift_pdf: f32 = if (page_number % 2 == 1)
        @as(f32, @floatFromInt(self.odd_shift_x))
    else
        0;
    const ctm = c.fz_pre_translate(c.fz_scale(zoom, zoom), -rb.ox + shift_pdf, -rb.oy);
    self.runPageInto(page, ctm, pix);
    if (self.config.general.colorize) {
        c.fz_tint_pixmap(self.ctx, pix, self.config.general.black, self.config.general.white);
    }

    const width = @as(usize, @intCast(@abs(bbox.x1)));
    const height = @as(usize, @intCast(@abs(bbox.y1)));
    return self.exportPixmap(pix, width, height, rb.ox, rb.oy);
}

pub fn toggleCropToContent(self: *Self) void {
    self.crop_to_content = !self.crop_to_content;
    self.default_zoom = 0;
    self.active_zoom = 0;
    self.pix_scroll_x = 0;
    self.pix_scroll_y = 0;
}

fn maxScrollX(self: *const Self, viewport_w: u32) i32 {
    if (self.rendered_w > viewport_w) return @intCast(self.rendered_w - viewport_w);
    return 0;
}

pub fn clampScrollX(self: *Self, viewport_w: u32) void {
    self.pix_scroll_x = @max(0, @min(self.maxScrollX(viewport_w), self.pix_scroll_x));
}

pub fn zoomIn(self: *Self) void {
    self.fit_width = false; // manual zoom exits the locked fit
    const old_zoom = self.active_zoom;
    self.active_zoom *= self.config.general.zoom_step;
    self.rescaleScroll(old_zoom);
}

pub fn zoomOut(self: *Self) void {
    self.fit_width = false;
    const old_zoom = self.active_zoom;
    self.active_zoom /= self.config.general.zoom_step;
    self.rescaleScroll(old_zoom);
}

fn rescaleScroll(self: *Self, old_zoom: f32) void {
    if (old_zoom == 0 or self.active_zoom == 0) return;
    const ratio = self.active_zoom / old_zoom;
    self.pix_scroll_x = @intFromFloat(@as(f32, @floatFromInt(self.pix_scroll_x)) * ratio);
    self.pix_scroll_y = @intFromFloat(@as(f32, @floatFromInt(self.pix_scroll_y)) * ratio);
}

pub fn setZoom(self: *Self, percent: f32) void {
    self.fit_width = false;
    var dpi = self.config.general.dpi;
    if (self.config.general.detect_dpi) dpi = Utilities.getDPI() orelse dpi;

    self.active_zoom = @max(percent * dpi / 7200.0, self.config.general.zoom_min);
}

pub fn toggleColor(self: *Self) void {
    self.config.general.colorize = !self.config.general.colorize;
}

pub fn offsetScroll(self: *Self, dx: f32, dy: f32) void {
    // dx > 0 reveals right; dy > 0 reveals top (pix_scroll_y decreases).
    self.pix_scroll_x += @intFromFloat(dx);
    self.pix_scroll_y -= @intFromFloat(dy);
    self.clampScrollX(self.last_viewport_w);
}

pub fn resetDefaultZoom(self: *Self) void {
    self.default_zoom = 0;
}

pub fn toggleWidthMode(self: *Self) void {
    self.default_zoom = 0;
    self.active_zoom = 0;
    self.width_mode = !self.width_mode;
    self.pix_scroll_x = 0;
    self.pix_scroll_y = 0;
}

pub fn getFitWidth(self: *Self) bool {
    return self.fit_width;
}

pub fn setFitWidth(self: *Self, on: bool) void {
    self.fit_width = on;
    if (on) {
        // Force a fresh fit on the next render.
        self.default_zoom = 0;
        self.active_zoom = 0;
        self.pix_scroll_x = 0;
    }
}

pub fn toggleFitWidth(self: *Self) void {
    self.setFitWidth(!self.fit_width);
}

pub fn getSpread(self: *Self) bool {
    return self.spread;
}

pub fn toggleSpread(self: *Self) void {
    self.spread = !self.spread;
    self.default_zoom = 0;
    self.active_zoom = 0;
    self.pix_scroll_x = 0;
    self.pix_scroll_y = 0;
}

pub const CropInfo = struct { left: f32, right: f32, top: f32, bottom: f32, auto: bool };

// Current crop as L/R/T/B margins for the status bar: the manual :crop values,
// or the stable-box-derived margins when only `t` is active.
pub fn cropInfo(self: *Self) ?CropInfo {
    if (self.crop_left != 0 or self.crop_right != 0 or self.crop_top != 0 or self.crop_bottom != 0) {
        return .{ .left = self.crop_left, .right = self.crop_right, .top = self.crop_top, .bottom = self.crop_bottom, .auto = false };
    }
    if (self.crop_to_content) {
        if (self.stable_box) |sb| {
            const pb = self.sample_bound;
            const m = self.crop_margin;
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

// Writes a copy of the document with the effective crop + oddx baked into the
// page boxes (lossless; for printing without margins).
pub fn exportCropped(self: *Self, out_path: [:0]const u8, keep_id: bool) !void {
    const ci = self.cropInfo() orelse CropInfo{ .left = 0, .right = 0, .top = 0, .bottom = 0, .auto = false };
    if (ci.left == 0 and ci.right == 0 and ci.top == 0 and ci.bottom == 0 and self.odd_shift_x == 0)
        return error.NothingToApply;
    self.render_mutex.lockUncancelable(self.io);
    defer self.render_mutex.unlock(self.io);
    if (c.fz_export_cropped_z(self.ctx, self.path.ptr, out_path.ptr, ci.left, ci.right, ci.top, ci.bottom, self.odd_shift_x, @intFromBool(keep_id)) == 0)
        return error.ExportFailed;
}

pub const PageBound = struct { x0: f32, y0: f32, x1: f32, y1: f32 };

// Raw (uncropped) page box in PDF points.
pub fn getPageBound(self: *Self, page_number: u16) PageBound {
    self.render_mutex.lockUncancelable(self.io);
    defer self.render_mutex.unlock(self.io);
    const page = c.fz_load_page_z(self.ctx, self.doc, @as(c_int, @intCast(page_number))) orelse
        return .{ .x0 = 0, .y0 = 0, .x1 = 0, .y1 = 0 };
    defer c.fz_drop_page(self.ctx, page);
    const b = c.fz_bound_page(self.ctx, page);
    return .{ .x0 = b.x0, .y0 = b.y0, .x1 = b.x1, .y1 = b.y1 };
}

pub fn setMarginCrop(self: *Self, left: f32, right: f32, top: f32, bottom: f32) void {
    self.crop_left = left;
    self.crop_right = right;
    self.crop_top = top;
    self.crop_bottom = bottom;
    self.default_zoom = 0;
    self.active_zoom = 0;
    self.pix_scroll_x = 0;
    self.pix_scroll_y = 0;
}

pub const SearchHit = struct { page: u16, x0: f32, y0: f32, x1: f32, y1: f32 };

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
    self.render_mutex.lockUncancelable(self.io);
    defer self.render_mutex.unlock(self.io);

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
    self.render_mutex.lockUncancelable(self.io);
    defer self.render_mutex.unlock(self.io);

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
    self.render_mutex.lockUncancelable(self.io);
    defer self.render_mutex.unlock(self.io);

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
    self.render_mutex.lockUncancelable(self.io);
    defer self.render_mutex.unlock(self.io);

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

pub fn getWidthMode(self: *Self) bool {
    return self.width_mode;
}

pub fn getCropToContent(self: *Self) bool {
    return self.crop_to_content;
}

pub fn getCurrentPageNumber(self: *Self) u16 {
    return self.current_page_number;
}

pub fn setCurrentPage(self: *Self, page: u16) void {
    self.current_page_number = page;
}

pub fn getPath(self: *Self) []const u8 {
    return self.path;
}

pub fn getTotalPages(self: *Self) u16 {
    return self.total_pages;
}

pub fn getActiveZoom(self: *Self) f32 {
    return self.active_zoom;
}

pub fn setActiveZoom(self: *Self, zoom: f32) void {
    self.active_zoom = zoom;
}

pub fn getScrollX(self: *Self) i32 {
    return self.pix_scroll_x;
}

pub fn getScrollY(self: *Self) i32 {
    return self.pix_scroll_y;
}

pub fn setScrollX(self: *Self, x: i32) void {
    self.pix_scroll_x = x;
}

pub fn setScrollY(self: *Self, y: i32) void {
    self.pix_scroll_y = y;
}

pub fn scrollY(self: *Self, dy: f32) void {
    self.pix_scroll_y -= @intFromFloat(dy);
}

pub fn setOddShiftX(self: *Self, x: i32) void {
    self.odd_shift_x = x;
    // The stable content box is computed in aligned space, so it depends on this.
    self.stable_box = null;
    self.stable_box_done = false;
}

pub fn getOddShiftX(self: *Self) i32 {
    return self.odd_shift_x;
}

pub fn setPendingScrollPdfY(self: *Self, y: f32) void {
    self.pending_scroll_pdf_y = y;
}

// Takes an owned copy under the render mutex: the prerender worker iterates
// these slices mid-render, so they must not alias caller ArrayList memory
// that reallocates on growth.
pub fn setSearchHighlights(self: *Self, hits: []const SearchHit) void {
    self.render_mutex.lockUncancelable(self.io);
    defer self.render_mutex.unlock(self.io);
    if (self.search_highlights.len > 0) self.allocator.free(self.search_highlights);
    self.search_highlights = self.allocator.dupe(SearchHit, hits) catch &.{};
}

pub fn searchPage(self: *Self, allocator: std.mem.Allocator, page_number: u16, needle: [*:0]const u8, out: *std.ArrayList(SearchHit)) !void {
    self.render_mutex.lockUncancelable(self.io);
    defer self.render_mutex.unlock(self.io);

    var quads: [128]c.fz_quad = undefined;
    const n = c.fz_search_page_z(self.ctx, self.doc, @as(c_int, @intCast(page_number)), needle, &quads, quads.len);
    for (quads[0..@intCast(n)]) |q| {
        const r = c.fz_rect_from_quad(q);
        try out.append(allocator, .{ .page = page_number, .x0 = r.x0, .y0 = r.y0, .x1 = r.x1, .y1 = r.y1 });
    }
}

pub fn setSelectionQuads(self: *Self, hits: []const SearchHit) void {
    self.render_mutex.lockUncancelable(self.io);
    defer self.render_mutex.unlock(self.io);
    if (self.selection_quads.len > 0) self.allocator.free(self.selection_quads);
    self.selection_quads = self.allocator.dupe(SearchHit, hits) catch &.{};
}

pub fn setHighlightQuads(self: *Self, hits: []const SearchHit) void {
    self.render_mutex.lockUncancelable(self.io);
    defer self.render_mutex.unlock(self.io);
    if (self.highlight_quads.len > 0) self.allocator.free(self.highlight_quads);
    self.highlight_quads = self.allocator.dupe(SearchHit, hits) catch &.{};
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
    self.render_mutex.lockUncancelable(self.io);
    defer self.render_mutex.unlock(self.io);

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
    self.render_mutex.lockUncancelable(self.io);
    defer self.render_mutex.unlock(self.io);

    var buf: [512]u8 = undefined;
    const n = c.fz_line_text_at_z(self.ctx, self.doc, @as(c_int, @intCast(page_number)), x, y, &buf, buf.len);
    return allocator.dupe(u8, buf[0..@intCast(n)]);
}

pub fn takePendingScrollPdfY(self: *Self) ?f32 {
    const y = self.pending_scroll_pdf_y;
    self.pending_scroll_pdf_y = null;
    return y;
}

fn extractEventBridge(ud: ?*anyopaque, kind: c_int, chars: [*c]const c.fz_char_z, n: c_int, str: [*c]const u8) callconv(.c) void {
    // Markdown.Char and fz_char_z have the same extern layout; pointer-cast across the FFI.
    const md_chars: ?[*]const Markdown.Char = if (chars != null) @ptrCast(chars) else null;
    const md_str: ?[*:0]const u8 = if (str != null) @ptrCast(str) else null;
    Markdown.eventCallback(ud, kind, md_chars, n, md_str);
}

pub fn writePageText(self: *Self, page_number: u16, path: [:0]const u8) !void {
    return self.writePagesText(page_number, page_number + 1, path, null, null);
}

pub fn writePagesText(
    self: *Self,
    start_page: u16,
    end_page: u16,
    path: [:0]const u8,
    on_progress: ?*const fn (?*anyopaque, c_int, c_int) callconv(.c) void,
    progress_userdata: ?*anyopaque,
) !void {
    const black: c_int = if (self.config.general.colorize) @intCast(self.config.general.black) else 0x000000;
    const white: c_int = if (self.config.general.colorize) @intCast(self.config.general.white) else 0xffffff;
    const scale: f32 = if (self.active_zoom > 0) self.active_zoom else 4.0;

    var file = try std.Io.Dir.createFileAbsolute(self.io, path, .{});
    defer file.close(self.io);
    var buf: [4096]u8 = undefined;
    var fw = file.writer(self.io, &buf);

    try fw.interface.writeAll("<!-- markdownlint-disable -->\n\n");

    var md = Markdown.init(self.allocator, &fw.interface);
    defer md.deinit();

    self.render_mutex.lockUncancelable(self.io);
    defer self.render_mutex.unlock(self.io);

    // Image dir = dirname(path).
    const slash = std.mem.lastIndexOfScalar(u8, path, '/') orelse 0;
    const image_dir = try self.allocator.dupeZ(u8, if (slash > 0) path[0..slash] else ".");
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
