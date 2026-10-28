//! Main-thread reading view over a Document: current page, zoom, crop, spread,
//! scroll and viewport bookkeeping. Nothing here is touched by the prerender
//! worker; it only gets RenderParams built by `prerenderParams`/`thumbParams`
//! and calls Document.render.
const Self = @This();
const std = @import("std");
const Config = @import("../config/Config.zig");
pub const types = @import("./types.zig");
pub const Document = @import("./Document.zig");
pub const Exporter = @import("./Exporter.zig");
const Utilities = @import("../utilities/Utilities.zig");
const Markdown = @import("./Markdown.zig");

pub const SearchHit = Document.SearchHit;
pub const PageBound = Document.PageBound;
pub const PageTarget = Document.PageTarget;
pub const LinkTarget = Document.LinkTarget;
pub const PageLink = Document.PageLink;
pub const OutlineEntry = Document.OutlineEntry;
pub const CropInfo = Document.CropInfo;
pub const RenderParams = Document.RenderParams;

allocator: std.mem.Allocator,
io: std.Io,
doc: Document,
current_page_number: u16,
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
spread_cols: u8,
crop_to_content: bool,
crop_margin: f32,
// Manual margin crop in PDF points, applied to every page before layout.
crop_left: f32,
crop_right: f32,
crop_top: f32,
crop_bottom: f32,
odd_shift_x: i32,
pending_scroll_pdf_y: ?f32,
pix_scroll_x: i32,
pix_scroll_y: i32,
rendered_w: u32,
last_viewport_w: u32,
last_viewport_h: u32,
fit_scale: f32,
// Owned copies; renders get per-call slices (or per-page copies for the worker).
search_highlights: []const SearchHit,
selection_quads: []const SearchHit,
highlight_quads: []const SearchHit,
config: *Config,

pub fn init(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: [:0]const u8,
    initial_page: ?u16,
    config: *Config,
) !Self {
    var doc = try Document.init(allocator, io, path, config);
    errdefer doc.deinit();

    const current_page_number = if (initial_page) |page| blk: {
        if (page < 1 or page > doc.total_pages) {
            return types.DocumentError.InvalidPageNumber;
        }
        break :blk page - 1;
    } else 0;

    return .{
        .allocator = allocator,
        .io = io,
        .doc = doc,
        .current_page_number = current_page_number,
        .active_zoom = 0,
        .default_zoom = 0,
        .width_mode = false,
        .fit_width = false,
        .spread = false,
        .spread_cols = 2,
        .crop_to_content = false,
        .crop_margin = 4,
        .crop_left = 0,
        .crop_right = 0,
        .crop_top = 0,
        .crop_bottom = 0,
        .odd_shift_x = 0,
        .pending_scroll_pdf_y = null,
        .pix_scroll_x = 0,
        .pix_scroll_y = 0,
        .rendered_w = 0,
        .last_viewport_w = 0,
        .last_viewport_h = 0,
        .fit_scale = 0,
        .search_highlights = &.{},
        .selection_quads = &.{},
        .highlight_quads = &.{},
        .config = config,
    };
}

pub fn deinit(self: *Self) void {
    if (self.search_highlights.len > 0) self.allocator.free(self.search_highlights);
    if (self.selection_quads.len > 0) self.allocator.free(self.selection_quads);
    if (self.highlight_quads.len > 0) self.allocator.free(self.highlight_quads);
    self.doc.deinit();
}

pub fn setTransfer(self: *Self, transfer: types.Transfer, tmp_dir: ?[]const u8) void {
    self.doc.exporter.setTransfer(transfer, tmp_dir);
}

pub fn reloadDocument(self: *Self) !void {
    try self.doc.reload();
    if (self.current_page_number >= self.doc.total_pages) {
        self.current_page_number = self.doc.total_pages - 1;
    }
}

pub fn goToPage(self: *Self, page_num: u16) bool {
    if (page_num >= 1 and page_num <= self.doc.total_pages and page_num != self.current_page_number + 1) {
        self.current_page_number = page_num - 1;
        return true;
    }
    return false;
}

pub fn changePage(self: *Self, delta: i32) bool {
    const new_page = @as(i32, @intCast(self.current_page_number)) + delta;

    if (new_page >= 0 and new_page < self.doc.total_pages) {
        self.current_page_number = @as(u16, @intCast(new_page));
        return true;
    }
    return false;
}

fn calculateZoomLevel(self: *Self, window_width: u32, window_height: u32, w_pdf: f32, h_pdf: f32) void {
    var scale: f32 = 0;
    // Width-fit (spread/width-mode/fit-width) fills the column/window width and
    // scrolls vertically; otherwise fit the whole page.
    if (self.width_mode or self.spread or self.fit_width) {
        scale = @as(f32, @floatFromInt(window_width)) / w_pdf;
    } else {
        scale = @min(
            @as(f32, @floatFromInt(window_width)) / w_pdf,
            @as(f32, @floatFromInt(window_height)) / h_pdf,
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

    self.fit_scale = scale;
    self.active_zoom = @max(self.active_zoom, self.effectiveZoomMin());
}

// zoom_min guards against unusably tiny renders, but must not override a
// window-fit scale — otherwise narrow windows freeze at 72dpi wider than
// the viewport. The floor is "fits the window", however small that is.
pub fn effectiveZoomMin(self: *const Self) f32 {
    const zm = self.config.general.zoom_min;
    return if (self.fit_scale > 0) @min(zm, self.fit_scale) else zm;
}

// The crop settings as a by-value render input; makes sure the stable
// content box exists for crop-to-content.
pub fn crop(self: *Self) Document.Crop {
    if (self.crop_to_content) self.doc.ensureStableBox(self.odd_shift_x);
    return .{
        .left = self.crop_left,
        .right = self.crop_right,
        .top = self.crop_top,
        .bottom = self.crop_bottom,
        .to_content = self.crop_to_content,
        .margin = self.crop_margin,
        .odd_shift_x = self.odd_shift_x,
    };
}

fn params(self: *Self, scale: Document.Scale, search: []const SearchHit, selection: []const SearchHit, highlight: []const SearchHit) RenderParams {
    return .{
        .scale = scale,
        .crop = self.crop(),
        .colorize = self.config.general.colorize,
        .black = self.config.general.black,
        .white = self.config.general.white,
        .search = search,
        .selection = selection,
        .highlight = highlight,
    };
}

// Reading-view render of a page for a window: fits the zoom (fit/width/manual)
// to the page's cropped bound, renders, and records the viewport and rendered
// width for scroll clamping.
pub fn renderPage(self: *Self, page_number: u16, window_width: u32, window_height: u32) !types.EncodedImage {
    const rb = try self.doc.retry(Document.renderBound, .{ &self.doc, page_number, self.crop() }, types.DocumentError.FailedToRenderPage);
    self.calculateZoomLevel(window_width, window_height, rb.bound.x1 - rb.bound.x0, rb.bound.y1 - rb.bound.y0);

    const enc = try self.doc.render(page_number, self.params(.{ .zoom = self.active_zoom }, self.search_highlights, self.selection_quads, self.highlight_quads));

    self.rendered_w = enc.width;
    self.last_viewport_w = window_width;
    self.last_viewport_h = window_height;
    return enc;
}

// Render inputs for a background render of a neighbor page at the current
// zoom. The quad slices are owned copies filtered to `page_number`; free with
// `freeParams`.
pub fn prerenderParams(self: *Self, allocator: std.mem.Allocator, page_number: u16) !RenderParams {
    const search = try pageHits(allocator, self.search_highlights, page_number);
    errdefer allocator.free(search);
    const selection = try pageHits(allocator, self.selection_quads, page_number);
    errdefer allocator.free(selection);
    const highlight = try pageHits(allocator, self.highlight_quads, page_number);
    return self.params(.{ .zoom = self.active_zoom }, search, selection, highlight);
}

// Render inputs for grid thumbnails fitted into max_w x max_h; the highlights
// are an owned copy of all of them (Document.render skips other pages).
pub fn thumbParams(self: *Self, allocator: std.mem.Allocator, max_w: u32, max_h: u32) !RenderParams {
    const highlight = try allocator.dupe(SearchHit, self.highlight_quads);
    return self.params(.{ .fit = .{ .w = max_w, .h = max_h } }, &.{}, &.{}, highlight);
}

pub fn freeParams(allocator: std.mem.Allocator, p: RenderParams) void {
    if (p.search.len > 0) allocator.free(p.search);
    if (p.selection.len > 0) allocator.free(p.selection);
    if (p.highlight.len > 0) allocator.free(p.highlight);
}

fn pageHits(allocator: std.mem.Allocator, hits: []const SearchHit, page_number: u16) ![]const SearchHit {
    var out: std.ArrayList(SearchHit) = .empty;
    errdefer out.deinit(allocator);
    for (hits) |h| {
        if (h.page == page_number) try out.append(allocator, h);
    }
    return out.toOwnedSlice(allocator);
}

// Renders a page scaled to fit max_w/max_h pixels, without touching the
// reading zoom or viewport state — for the grid-mode thumbnails.
pub fn renderThumb(self: *Self, page_number: u16, max_w: u32, max_h: u32) !types.EncodedImage {
    return self.doc.renderOnce(page_number, self.params(.{ .fit = .{ .w = max_w, .h = max_h } }, &.{}, &.{}, self.highlight_quads));
}

fn resetZoomAndScroll(self: *Self) void {
    self.default_zoom = 0;
    self.active_zoom = 0;
    self.pix_scroll_x = 0;
    self.pix_scroll_y = 0;
}

pub fn toggleCropToContent(self: *Self) void {
    self.crop_to_content = !self.crop_to_content;
    self.resetZoomAndScroll();
}

fn maxScrollX(self: *const Self, viewport_w: u32) i32 {
    if (self.rendered_w > viewport_w) return @intCast(self.rendered_w - viewport_w);
    return 0;
}

pub fn clampScrollX(self: *Self, viewport_w: u32) void {
    self.pix_scroll_x = @max(0, @min(self.maxScrollX(viewport_w), self.pix_scroll_x));
}

// Pixmaps grow quadratically with zoom; past this a page is hundreds of MB
// and mupdf's allocation failure would abort the process.
const max_zoom: f32 = 10.0;

pub fn zoomIn(self: *Self) void {
    self.fit_width = false; // manual zoom exits the locked fit
    const old_zoom = self.active_zoom;
    self.active_zoom = @min(self.active_zoom * self.config.general.zoom_step, max_zoom);
    self.rescaleScroll(old_zoom);
}

pub fn zoomOut(self: *Self) void {
    self.fit_width = false;
    const old_zoom = self.active_zoom;
    self.active_zoom /= self.config.general.zoom_step;
    self.rescaleScroll(old_zoom);
}

// Anchors the viewport center: the content under the middle of the screen
// stays put through the zoom (scroll clamping still applies at edges).
fn rescaleScroll(self: *Self, old_zoom: f32) void {
    if (old_zoom == 0 or self.active_zoom == 0) return;
    const ratio = self.active_zoom / old_zoom;
    const half_w: f32 = @as(f32, @floatFromInt(self.last_viewport_w)) / 2.0;
    const half_h: f32 = @as(f32, @floatFromInt(self.last_viewport_h)) / 2.0;
    self.pix_scroll_x = @intFromFloat((@as(f32, @floatFromInt(self.pix_scroll_x)) + half_w) * ratio - half_w);
    self.pix_scroll_y = @intFromFloat((@as(f32, @floatFromInt(self.pix_scroll_y)) + half_h) * ratio - half_h);
}

pub fn setZoom(self: *Self, percent: f32) void {
    self.fit_width = false;
    var dpi = self.config.general.dpi;
    if (self.config.general.detect_dpi) dpi = Utilities.getDPI() orelse dpi;

    self.active_zoom = std.math.clamp(percent * dpi / 7200.0, self.effectiveZoomMin(), max_zoom);
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
    self.width_mode = !self.width_mode;
    self.resetZoomAndScroll();
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
    self.resetZoomAndScroll();
}

pub fn getSpreadColumns(self: *Self) u8 {
    return if (self.spread) @max(self.spread_cols, 2) else 1;
}

// Spread with exactly `n` columns (2..8); the zoom refits to the column width.
pub fn setSpreadColumns(self: *Self, n: u8) void {
    self.spread_cols = std.math.clamp(n, 2, 8);
    self.spread = true;
    self.resetZoomAndScroll();
}

// Current crop as L/R/T/B margins for the status bar: the manual :crop values,
// or the stable-box-derived margins when only `t` is active.
pub fn cropInfo(self: *Self) ?CropInfo {
    return self.doc.cropInfo(self.crop());
}

pub fn exportCropped(self: *Self, out_path: [:0]const u8, keep_id: bool) !void {
    return self.doc.exportCropped(out_path, keep_id, self.crop());
}

pub fn getPageBound(self: *Self, page_number: u16) PageBound {
    return self.doc.getPageBound(page_number);
}

pub fn coverPng(self: *Self, allocator: std.mem.Allocator, max_w: u32, max_h: u32) ![]u8 {
    return self.doc.coverPng(allocator, max_w, max_h);
}

pub fn setMarginCrop(self: *Self, left: f32, right: f32, top: f32, bottom: f32) void {
    self.crop_left = left;
    self.crop_right = right;
    self.crop_top = top;
    self.crop_bottom = bottom;
    self.resetZoomAndScroll();
}

pub fn loadOutline(self: *Self, allocator: std.mem.Allocator) ![]OutlineEntry {
    return self.doc.loadOutline(allocator);
}

pub fn loadLinks(self: *Self, allocator: std.mem.Allocator, page_number: u16) ![]PageLink {
    return self.doc.loadLinks(allocator, page_number);
}

pub fn getDocumentKey(self: *Self, allocator: std.mem.Allocator) ![]u8 {
    return self.doc.getDocumentKey(allocator);
}

pub fn findLinkAtPoint(self: *Self, allocator: std.mem.Allocator, page_number: u16, pdf_x: f32, pdf_y: f32) ?LinkTarget {
    return self.doc.findLinkAtPoint(allocator, page_number, pdf_x, pdf_y);
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
    return self.doc.path;
}

pub fn getTotalPages(self: *Self) u16 {
    return self.doc.total_pages;
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
}

pub fn getOddShiftX(self: *Self) i32 {
    return self.odd_shift_x;
}

pub fn setPendingScrollPdfY(self: *Self, y: f32) void {
    self.pending_scroll_pdf_y = y;
}

pub fn takePendingScrollPdfY(self: *Self) ?f32 {
    const y = self.pending_scroll_pdf_y;
    self.pending_scroll_pdf_y = null;
    return y;
}

pub fn setSearchHighlights(self: *Self, hits: []const SearchHit) void {
    self.setQuads(&self.search_highlights, hits);
}

pub fn setSelectionQuads(self: *Self, hits: []const SearchHit) void {
    self.setQuads(&self.selection_quads, hits);
}

pub fn setHighlightQuads(self: *Self, hits: []const SearchHit) void {
    self.setQuads(&self.highlight_quads, hits);
}

// Owned copy, so callers may keep growing their ArrayList. On OOM the
// previous quads stay in place rather than vanishing.
fn setQuads(self: *Self, dst: *[]const SearchHit, hits: []const SearchHit) void {
    const copy = self.allocator.dupe(SearchHit, hits) catch return;
    if (dst.len > 0) self.allocator.free(dst.*);
    dst.* = copy;
}

pub fn searchPage(self: *Self, allocator: std.mem.Allocator, page_number: u16, needle: [*:0]const u8, out: *std.ArrayList(SearchHit)) !void {
    return self.doc.searchPage(allocator, page_number, needle, out);
}

pub fn selectText(self: *Self, allocator: std.mem.Allocator, page_number: u16, ax: f32, ay: f32, bx: f32, by: f32, out: *std.ArrayList(SearchHit)) ![]u8 {
    return self.doc.selectText(allocator, page_number, ax, ay, bx, by, out);
}

pub fn lineTextAt(self: *Self, allocator: std.mem.Allocator, page_number: u16, x: f32, y: f32) ![]u8 {
    return self.doc.lineTextAt(allocator, page_number, x, y);
}

pub fn writePageText(self: *Self, page_number: u16, path: [:0]const u8) !void {
    return self.writePagesText(page_number, page_number + 1, path, null, null, null, null);
}

pub fn writePagesText(
    self: *Self,
    start_page: u16,
    end_page: u16,
    path: [:0]const u8,
    on_progress: ?*const fn (?*anyopaque, c_int, c_int) callconv(.c) void,
    progress_userdata: ?*anyopaque,
    page_hook: ?Markdown.PageHook,
    page_hook_ctx: ?*anyopaque,
) !void {
    const black: c_int = if (self.config.general.colorize) @intCast(self.config.general.black) else 0x000000;
    const white: c_int = if (self.config.general.colorize) @intCast(self.config.general.white) else 0xffffff;
    const scale: f32 = if (self.active_zoom > 0) self.active_zoom else 4.0;
    return self.doc.writePagesText(start_page, end_page, path, scale, black, white, on_progress, progress_userdata, page_hook, page_hook_ctx);
}
