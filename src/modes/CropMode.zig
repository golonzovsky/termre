const Self = @This();
const std = @import("std");
const vaxis = @import("vaxis");
const Context = @import("../Context.zig").Context;
const PagePoint = @import("../Context.zig").PagePoint;
const Config = @import("../config/Config.zig");
const PdfHandler = @import("../handlers/PdfHandler.zig");

pub const occupies_bottom_row = true;
pub const page_behind_text = true;
pub const suppress_autosave = true;

const Side = enum { left, right, top, bottom, offset };
const min_gap: f32 = 24; // pt kept between opposite crop lines

context: *Context,
left: f32,
right: f32,
top: f32,
bottom: f32,
prev: [4]f32, // L R T B at entry, restored on cancel
prev_oddx: i32,
prev_auto: bool,
applied: bool,
// Pending offset. Crop mode renders pages unshifted (the handler is held at
// 0) and presents oddx as the movable ┆ line / border placement instead.
// The ┆ rides at page center minus oddx so slider and border move together
// with room to drag both ways; the drag is relative (no snap on press),
// anchored by grab_dx.
oddx: i32,
grab_dx: f32,
// Reading position at entry (page + viewport top in PDF points, so it
// survives the zoom refits that crop changes trigger); restored on any exit.
entry_page: u16,
entry_pdf_y: f32,
drag: ?Side,
// Raw page boxes are immutable while the mode is open; cached so draw and
// mouse events don't take the render mutex per call.
bound_cache: [8]?struct { page: u16, b: PdfHandler.PageBound },
bound_next: usize,
// Backs the status-bar text between frames; screen cells slice into it.
status_buf: [160]u8,

pub fn init(context: *Context) Self {
    const dh = &context.document_handler;
    var self = Self{
        .context = context,
        .left = 0,
        .right = 0,
        .top = 0,
        .bottom = 0,
        .prev = .{ dh.crop_left, dh.crop_right, dh.crop_top, dh.crop_bottom },
        .prev_oddx = dh.getOddShiftX(),
        .prev_auto = dh.getCropToContent(),
        .applied = false,
        .oddx = dh.getOddShiftX(),
        .grab_dx = 0,
        .entry_page = dh.getCurrentPageNumber(),
        .entry_pdf_y = 0,
        .drag = null,
        .bound_cache = @splat(null),
        .bound_next = 0,
        .status_buf = undefined,
    };
    const entry_zoom = dh.getActiveZoom();
    if (context.visible_pages_len > 0 and entry_zoom > 0) {
        const p0 = context.visible_pages[0];
        self.entry_page = p0.page_num;
        self.entry_pdf_y = @as(f32, @floatFromInt(p0.clip_y)) / entry_zoom + p0.origin_y;
    }
    // Seed the lines from the effective crop (manual margins or the
    // content-crop equivalent), then display the full page while adjusting.
    if (dh.cropInfo()) |ci| {
        self.left = ci.left;
        self.right = ci.right;
        self.top = ci.top;
        self.bottom = ci.bottom;
    }
    if (self.hadCrop()) {
        if (self.prev_auto) dh.toggleCropToContent();
        dh.setMarginCrop(0, 0, 0, 0);
        context.clearCache();
    }
    if (self.prev_oddx != 0) {
        dh.setOddShiftX(0);
    }
    return self;
}

// Whether a crop (manual or auto) was active at entry — init cleared it for
// the preview, so deinit/apply must reinstate document state either way.
fn hadCrop(self: *const Self) bool {
    return self.prev_auto or self.prev[0] != 0 or self.prev[1] != 0 or self.prev[2] != 0 or self.prev[3] != 0;
}

fn pageBound(self: *Self, page: u16) PdfHandler.PageBound {
    for (self.bound_cache) |slot| {
        if (slot) |s| if (s.page == page) return s.b;
    }
    const b = self.context.document_handler.getPageBound(page);
    self.bound_cache[self.bound_next % self.bound_cache.len] = .{ .page = page, .b = b };
    self.bound_next += 1;
    return b;
}

pub fn deinit(self: *Self) void {
    const dh = &self.context.document_handler;
    if (!self.applied) {
        if (self.hadCrop()) {
            dh.setMarginCrop(self.prev[0], self.prev[1], self.prev[2], self.prev[3]);
            if (self.prev_auto) dh.toggleCropToContent();
            self.context.clearCache();
        }
        if (dh.getOddShiftX() != self.prev_oddx) {
            dh.setOddShiftX(self.prev_oddx);
        }
    }
    // Scrolling inside the preview is never kept: return to where reading was.
    dh.setScrollX(0);
    self.context.gotoPagePdfY(self.entry_page, self.entry_pdf_y);
}

fn apply(self: *Self) void {
    const dh = &self.context.document_handler;
    self.applied = true;
    dh.setOddShiftX(self.oddx);
    const unchanged = !self.prev_auto and self.oddx == self.prev_oddx and
        self.left == self.prev[0] and self.right == self.prev[1] and
        self.top == self.prev[2] and self.bottom == self.prev[3];
    if (!unchanged or self.hadCrop()) {
        dh.setMarginCrop(self.left, self.right, self.top, self.bottom);
        self.context.clearCache();
    }
    self.context.changeMode(.view);
}

pub fn handleKeyStroke(self: *Self, key: vaxis.Key, km: Config.KeyMap) !void {
    if (key.matches(km.exit_command_mode.codepoint, km.exit_command_mode.mods)) {
        self.context.changeMode(.view);
        return;
    }
    if (key.matches('r', .{})) {
        self.left = 0;
        self.right = 0;
        self.top = 0;
        self.bottom = 0;
        self.oddx = 0;
        return;
    }
    if (key.matches(km.zoom_in.codepoint, km.zoom_in.mods)) {
        self.context.document_handler.zoomIn();
        return;
    }
    if (key.matches(km.zoom_out.codepoint, km.zoom_out.mods)) {
        self.context.document_handler.zoomOut();
        return;
    }
    if (key.matches(km.execute_command.codepoint, km.execute_command.mods) or
        key.matches(km.crop_mode.codepoint, km.crop_mode.mods))
    {
        self.apply();
    }
}

pub fn handleMouse(self: *Self, mouse: vaxis.Mouse) void {
    const ctx = self.context;
    switch (mouse.type) {
        .press => switch (mouse.button) {
            .wheel_up => if (mouse.mods.ctrl or mouse.mods.alt) {
                ctx.document_handler.zoomIn();
            } else ctx.document_handler.scrollY(ctx.config.general.scroll_step / 4.0),
            .wheel_down => if (mouse.mods.ctrl or mouse.mods.alt) {
                ctx.document_handler.zoomOut();
            } else ctx.document_handler.scrollY(-ctx.config.general.scroll_step / 4.0),
            .left => {
                const pt = ctx.pdfPointAt(mouse) orelse return;
                const b = self.pageBound(pt.page);
                self.drag = self.nearestSide(pt, b);
                if (self.drag == Side.offset) self.grab_dx = pt.x - self.sliderX(b);
                self.moveTo(pt, b);
            },
            else => {},
        },
        .drag => {
            if (mouse.button != .left or self.drag == null) return;
            const pt = ctx.pdfPointAt(mouse) orelse return;
            self.moveTo(pt, self.pageBound(pt.page));
        },
        .release => self.drag = null,
        else => {},
    }
}

// The crop window is fixed in aligned space — odd pages slide under it by
// oddx (see pageRenderBound/renderPage) — so all x math uses aligned coords.
// pdfPointAt already removed the handler's current render shift, so aligning
// means adding the pending offset regardless of view.
fn alignedX(self: *Self, pt: PagePoint) f32 {
    if (pt.page % 2 == 1) return pt.x + @as(f32, @floatFromInt(self.oddx));
    return pt.x;
}

fn nearestSide(self: *Self, pt: PagePoint, b: PdfHandler.PageBound) Side {
    const ax = self.alignedX(pt);
    var side: Side = .left;
    var best = @abs(ax - (b.x0 + self.left));
    const dr = @abs((b.x1 - self.right) - ax);
    if (dr < best) {
        side = .right;
        best = dr;
    }
    const dt = @abs(pt.y - (b.y0 + self.top));
    if (dt < best) {
        side = .top;
        best = dt;
    }
    const db = @abs((b.y1 - self.bottom) - pt.y);
    if (db < best) {
        side = .bottom;
        best = db;
    }
    // Odd pages also carry the ┆ window slider (drawn clamped into the
    // page); crop lines win ties so a zero offset at the page edge stays
    // grabbable as the left crop line.
    if (pt.page % 2 == 1) {
        if (@abs(pt.x - self.sliderX(b)) < best) side = .offset;
    }
    return side;
}

// Where the ┆ is drawn: page center displaced by the window offset, so it
// tracks the border 1:1 and always has page room to drag in both directions
// (oddx is clamped to ±w/2).
fn sliderX(self: *Self, b: PdfHandler.PageBound) f32 {
    const s: f32 = @floatFromInt(self.oddx);
    return std.math.clamp(b.x0 + (b.x1 - b.x0) / 2 - s, b.x0, @max(b.x0, b.x1 - 1));
}

fn moveTo(self: *Self, pt: PagePoint, b: PdfHandler.PageBound) void {
    const w = b.x1 - b.x0;
    const h = b.y1 - b.y0;
    const ax = self.alignedX(pt);
    switch (self.drag orelse return) {
        .left => self.left = std.math.clamp(ax - b.x0, 0, @max(0, w - self.right - min_gap)),
        .right => self.right = std.math.clamp(b.x1 - ax, 0, @max(0, w - self.left - min_gap)),
        .top => self.top = std.math.clamp(pt.y - b.y0, 0, @max(0, h - self.bottom - min_gap)),
        .bottom => self.bottom = std.math.clamp(b.y1 - pt.y, 0, @max(0, h - self.top - min_gap)),
        // Relative drag: slider and border both follow the pointer; the
        // offset is the negative window displacement. Overlay only; the
        // handler stays at 0 until apply.
        .offset => self.oddx = @intFromFloat(@round(std.math.clamp(b.x0 + w / 2 + self.grab_dx - pt.x, -w / 2, w / 2))),
    }
}

pub fn draw(self: *Self, win: vaxis.Window) void {
    const ctx = self.context;
    const dh = &ctx.document_handler;
    const zoom = dh.getActiveZoom();
    if (zoom == 0) return;
    const ppc: f32 = @floatFromInt(ctx.last_pix_per_col);
    const ppr: f32 = @floatFromInt(ctx.last_pix_per_row);

    const dim: vaxis.Cell = .{ .char = .{ .grapheme = "░", .width = 1 }, .style = .{ .fg = .{ .index = 8 } } };
    const line_style: vaxis.Cell.Style = .{ .fg = .{ .index = 3 }, .bold = true };
    const drag_style: vaxis.Cell.Style = .{ .fg = .{ .index = 11 }, .bold = true };
    const offset_style: vaxis.Cell.Style = if (self.drag == Side.offset)
        .{ .fg = .{ .index = 14 }, .bold = true }
    else
        .{ .fg = .{ .index = 6 } };

    const s: f32 = @floatFromInt(self.oddx);

    for (ctx.visible_pages[0..ctx.visible_pages_len]) |p| {
        const b = self.pageBound(p.page_num);
        if (b.x1 <= b.x0 or b.y1 <= b.y0) continue;
        const odd = p.page_num % 2 == 1;

        // Pages render unshifted in crop mode, so on odd pages the
        // aligned-space crop window lands at -s: the border shows exactly
        // where the cut falls on the raw page.
        const bs: f32 = if (odd) -s else 0;
        const lx = p.vpX(b.x0 + self.left + bs, zoom);
        const rx = p.vpX(b.x1 - self.right + bs, zoom);
        const ty = p.vpY(b.y0 + self.top, zoom);
        const by = p.vpY(b.y1 - self.bottom, zoom);

        // Right/bottom use the last pixel inside the crop, so a zero margin
        // lands on the page's edge cell instead of one past it.
        const col_l: i32 = @intFromFloat(@floor(lx / ppc));
        const col_r: i32 = @intFromFloat(@floor((rx - 1) / ppc));
        const row_t: i32 = @intFromFloat(@floor(ty / ppr));
        const row_b: i32 = @intFromFloat(@floor((by - 1) / ppr));

        const oddx_col: ?i32 = if (odd)
            @intFromFloat(@floor(p.vpX(self.sliderX(b), zoom) / ppc))
        else
            null;

        const c0: i32 = @intCast(p.vp_x_left / ctx.last_pix_per_col);
        const c1: i32 = @intCast((p.vp_x_right - 1) / ctx.last_pix_per_col);
        const r0: i32 = @intCast(p.vp_y_top / ctx.last_pix_per_row);
        const r1: i32 = @intCast((p.vp_y_bot - 1) / ctx.last_pix_per_row);

        var row: i32 = r0;
        while (row <= r1) : (row += 1) {
            var col: i32 = c0;
            while (col <= c1) : (col += 1) {
                const on_h = (row == row_t or row == row_b) and col >= col_l and col <= col_r;
                const on_v = (col == col_l or col == col_r) and row >= row_t and row <= row_b;
                var cell: ?vaxis.Cell = null;
                if (on_h or on_v) {
                    const g: []const u8 = if (on_h and on_v)
                        (if (row == row_t)
                            (if (col == col_l) "┌" else "┐")
                        else
                            (if (col == col_l) "└" else "┘"))
                    else if (on_h) "─" else "│";
                    var st = line_style;
                    if (self.drag) |d| {
                        const active = switch (d) {
                            .top => on_h and row == row_t,
                            .bottom => on_h and row == row_b,
                            .left => on_v and col == col_l,
                            .right => on_v and col == col_r,
                            .offset => false,
                        };
                        if (active) st = drag_style;
                    }
                    cell = .{ .char = .{ .grapheme = g, .width = 1 }, .style = st };
                } else if (oddx_col != null and col == oddx_col.?) {
                    cell = .{ .char = .{ .grapheme = "┆", .width = 1 }, .style = offset_style };
                } else if (col < col_l or col > col_r or row < row_t or row > row_b) {
                    cell = dim;
                }
                if (cell) |cl| {
                    if (row >= 0 and col >= 0 and row < win.height and col < win.width) {
                        const ucol: u16 = @intCast(col);
                        const urow: u16 = @intCast(row);
                        var out = cl;
                        // The kitty placement lives in one anchor cell (the
                        // page's top-left); overwriting it would hide the page.
                        if (win.readCell(ucol, urow)) |existing| out.image = existing.image;
                        win.writeCell(ucol, urow, out);
                    }
                }
            }
        }
    }

    self.drawStatus(win);
}

// Crop mode owns the bottom row: the normal status items read handler state,
// which is deliberately zeroed while cropping, so show the pending values.
fn drawStatus(self: *Self, win: vaxis.Window) void {
    const style = self.context.config.status_bar.style;
    const bar = win.child(.{ .x_off = 0, .y_off = win.height -| 1, .width = win.width, .height = 1 });
    bar.fill(.{ .char = .{ .grapheme = " ", .width = 1 }, .style = style });
    const text = std.fmt.bufPrint(
        &self.status_buf,
        " crop {d:.0} {d:.0} {d:.0} {d:.0} (TRBL) · oddx {d} · drag lines / ┆ · r reset · enter apply · esc cancel ",
        .{ self.top, self.right, self.bottom, self.left, self.oddx },
    ) catch return;
    _ = bar.print(&.{.{ .text = text, .style = style }}, .{ .col_offset = 0, .wrap = .none });
}
