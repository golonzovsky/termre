const Self = @This();
const std = @import("std");
const vaxis = @import("vaxis");
const Context = @import("../Context.zig").Context;
const Config = @import("../config/Config.zig");
const Prerenderer = @import("../services/Prerenderer.zig");
const time = @import("../utilities/time.zig");

pub const hides_page = true;

context: *Context,
selected: u16,
// Virtual scroll offset of the whole grid, in terminal cell rows; thumbs at
// the view edges draw partially via clip regions, so scrolling is per-cell.
scroll_cells: u16,
// Grid zoom: desired cell width in terminal cells (i/o adjust it).
target_cell_w: u16,
// Session cache page → transmitted image; dumped into stale_images whenever
// thumb size or page rendering (colorize/crop) changes, and on exit.
thumbs: std.AutoHashMap(u16, vaxis.Image),
// Labels printed each frame live here until the next draw.
draw_arena: std.heap.ArenaAllocator,
// Geometry from the last layout(); valid after the first draw.
cols: u16,
cell_w: u16,
cell_h: u16,
thumb_rows: u16,
thumb_max_w: u32,
grid_h: u16,
needs_snap: bool,
last_thumb_w: u32,

pub fn init(context: *Context) Self {
    return .{
        .context = context,
        .selected = context.document_handler.getCurrentPageNumber(),
        .scroll_cells = 0,
        .target_cell_w = context.grid_cell_w,
        .thumbs = std.AutoHashMap(u16, vaxis.Image).init(context.allocator),
        .draw_arena = std.heap.ArenaAllocator.init(context.allocator),
        .cols = 1,
        .cell_w = 24,
        .cell_h = 2,
        .thumb_rows = 1,
        .thumb_max_w = 1,
        .grid_h = 1,
        .needs_snap = true,
        .last_thumb_w = 0,
    };
}

fn dumpThumbs(self: *Self) void {
    var it = self.thumbs.valueIterator();
    while (it.next()) |img| {
        self.context.stale_images.append(self.context.allocator, .{
            .image = img.*,
            .origin_x = 0,
            .origin_y = 0,
        }) catch {};
    }
    self.thumbs.clearRetainingCapacity();
}

pub fn deinit(self: *Self) void {
    self.dumpThumbs();
    self.thumbs.deinit();
    self.draw_arena.deinit();
}

fn totalRows(self: *Self) u32 {
    const total: u32 = self.context.document_handler.getTotalPages();
    return (total + self.cols - 1) / self.cols;
}

fn maxScroll(self: *Self) u16 {
    const virt: u32 = self.totalRows() * self.cell_h;
    return @intCast(virt -| self.grid_h);
}

fn jump(self: *Self) void {
    const ctx = self.context;
    ctx.pushJump();
    ctx.document_handler.setCurrentPage(self.selected);
    ctx.document_handler.setScrollY(0);
    ctx.document_handler.setScrollX(0);
    ctx.resetCurrentPage();
    ctx.changeMode(.view);
}

fn panBy(self: *Self, delta: i32) void {
    const target = std.math.clamp(@as(i32, self.scroll_cells) + delta, 0, @as(i32, self.maxScroll()));
    self.scroll_cells = @intCast(target);
}

// C-d/C-u: view and cursor move together by a screenful, so the cursor
// keeps its relative screen position and the motion is symmetric.
fn screenJump(self: *Self, dir: i32) void {
    const rows_jump: i32 = @intCast(@max(1, self.grid_h / self.cell_h));
    const total: i32 = @intCast(self.context.document_handler.getTotalPages());
    self.selected = @intCast(std.math.clamp(
        @as(i32, self.selected) + dir * rows_jump * @as(i32, self.cols),
        0,
        total - 1,
    ));
    const target = std.math.clamp(
        @as(i32, self.scroll_cells) + dir * rows_jump * @as(i32, self.cell_h),
        0,
        @as(i32, self.maxScroll()),
    );
    if (target != self.scroll_cells) self.animateScrollTo(@intCast(target));
    // Edge clamps can desync the pair; snap the cursor back into view.
    self.ensureVisible(false);
}

fn moveSelected(self: *Self, delta: i32) void {
    const total: i32 = @intCast(self.context.document_handler.getTotalPages());
    self.selected = @intCast(std.math.clamp(@as(i32, self.selected) + delta, 0, total - 1));
    self.ensureVisible(true);
}

// Scrolls just enough to fully show the selected row; eased when animate.
fn ensureVisible(self: *Self, animate: bool) void {
    const top: u32 = (@as(u32, self.selected) / self.cols) * self.cell_h;
    var target: u16 = self.scroll_cells;
    if (top < target) {
        target = @intCast(top);
    } else if (top + self.cell_h > @as(u32, target) + self.grid_h) {
        target = @intCast(top + self.cell_h - self.grid_h);
    }
    target = @min(target, self.maxScroll());
    if (target == self.scroll_cells) return;
    if (!animate) {
        self.scroll_cells = target;
        return;
    }
    self.animateScrollTo(target);
}

fn animateScrollTo(self: *Self, target: u16) void {
    const frames: usize = 10;
    const frame_ns: u64 = 11 * std.time.ns_per_ms;
    const start: f32 = @floatFromInt(self.scroll_cells);
    const delta: f32 = @as(f32, @floatFromInt(target)) - start;
    var i: usize = 1;
    while (i <= frames) : (i += 1) {
        const t = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(frames));
        const eased = 1.0 - std.math.pow(f32, 1.0 - t, 3.0);
        const next: u16 = @intFromFloat(@round(start + delta * eased));
        if (next == self.scroll_cells) continue;
        self.scroll_cells = next;
        self.context.renderFrame() catch return;
        if (i < frames) time.sleep(frame_ns);
    }
}

fn zoomGrid(self: *Self, delta: i32) void {
    const new_w: u16 = @intCast(std.math.clamp(@as(i32, self.target_cell_w) + delta, 12, 64));
    if (new_w == self.target_cell_w) return;
    self.target_cell_w = new_w;
    self.context.grid_cell_w = new_w;
    self.dumpThumbs();
    self.needs_snap = true;
}

// Thumbs bake colorize/crop into the raster; re-render after such toggles.
fn refreshThumbs(self: *Self) void {
    self.dumpThumbs();
    self.context.reload_page = true;
}

pub fn handleKeyStroke(self: *Self, key: vaxis.Key, km: Config.KeyMap) !void {
    if (key.matches(km.exit_command_mode.codepoint, km.exit_command_mode.mods) or
        key.matches(km.grid_mode.codepoint, km.grid_mode.mods))
    {
        self.context.changeMode(.view);
        return;
    }
    // All keys move the cursor (kept visible via eased follow-scroll);
    // harmless because only Enter/click changes the active page. The wheel
    // pans the view without touching the cursor.
    if (key.matches(vaxis.Key.up, .{}) or key.matches('k', .{})) return self.moveSelected(-@as(i32, self.cols));
    if (key.matches(vaxis.Key.down, .{}) or key.matches('j', .{})) return self.moveSelected(@as(i32, self.cols));
    if (key.matches(vaxis.Key.left, .{}) or key.matches('h', .{})) return self.moveSelected(-1);
    if (key.matches(vaxis.Key.right, .{}) or key.matches('l', .{})) return self.moveSelected(1);
    if (key.matches(km.next.codepoint, km.next.mods)) return self.moveSelected(1);
    if (key.matches(km.prev.codepoint, km.prev.mods)) return self.moveSelected(-1);
    if (key.matches(km.scroll_half_down.codepoint, km.scroll_half_down.mods)) return self.screenJump(1);
    if (key.matches(km.scroll_half_up.codepoint, km.scroll_half_up.mods)) return self.screenJump(-1);
    if (key.matches('G', .{})) {
        self.selected = self.context.document_handler.getTotalPages() - 1;
        self.ensureVisible(true);
        return;
    }
    if (key.matches(km.zoom_in.codepoint, km.zoom_in.mods)) return self.zoomGrid(4);
    if (key.matches(km.zoom_out.codepoint, km.zoom_out.mods)) return self.zoomGrid(-4);
    if (key.matches(km.colorize.codepoint, km.colorize.mods)) {
        self.context.document_handler.toggleColor();
        self.context.clearCache();
        return self.refreshThumbs();
    }
    if (key.matches(km.crop_to_content.codepoint, km.crop_to_content.mods)) {
        self.context.document_handler.toggleCropToContent();
        return self.refreshThumbs();
    }
    if (key.matches(km.full_screen.codepoint, km.full_screen.mods)) {
        self.context.toggleFullScreen();
        return;
    }
    if (key.matches(vaxis.Key.enter, .{})) self.jump();
}

pub fn handleMouse(self: *Self, mouse: vaxis.Mouse) void {
    const zoom_mod = mouse.mods.ctrl or mouse.mods.alt;
    switch (mouse.type) {
        .press => switch (mouse.button) {
            .wheel_up => if (zoom_mod) self.zoomGrid(4) else {
                self.scroll_cells -|= 3;
            },
            .wheel_down => if (zoom_mod) self.zoomGrid(-4) else {
                self.scroll_cells = @min(self.scroll_cells + 3, self.maxScroll());
            },
            .left => {
                if (mouse.col < 0 or mouse.row < 0) return;
                const cell_col = @min(@as(u16, @intCast(mouse.col)) / self.cell_w, self.cols - 1);
                const virt_row: u32 = (@as(u32, @intCast(mouse.row)) + self.scroll_cells) / self.cell_h;
                const page: u32 = virt_row * self.cols + cell_col;
                if (page < self.context.document_handler.getTotalPages()) {
                    self.selected = @intCast(page);
                    self.jump();
                }
            },
            else => {},
        },
        else => {},
    }
}

fn layout(self: *Self, win: vaxis.Window) void {
    const ctx = self.context;
    self.grid_h = win.height -| @as(u16, if (ctx.config.status_bar.enabled) 1 else 0);

    const b = ctx.document_handler.getPageBound(self.selected);
    const aspect: f32 = if (b.x1 > b.x0 and b.y1 > b.y0) (b.y1 - b.y0) / (b.x1 - b.x0) else 1.3;
    const ppr_f: f32 = @floatFromInt(ctx.last_pix_per_row);

    // Start from the grid-zoom target, then add columns until enough thumb
    // ROWS fit: on narrow/vertical windows full-width cells give page-sized
    // thumbs and a two-page overview. The row floor scales with height (tall
    // window -> more rows); an explicit grid zoom (i/o) relaxes it to a
    // degenerate-grid guard — the user asked for big thumbs.
    const min_rows: u32 = if (self.target_cell_w == 24)
        std.math.clamp(@as(u32, self.grid_h) / 18, 2, 5)
    else
        1;
    var cols: u16 = @intCast(std.math.clamp(win.width / self.target_cell_w, 1, 12));
    while (true) {
        const cell_w: u16 = win.width / cols;
        const thumb_w_px: f32 = @floatFromInt(@as(u32, cell_w) * ctx.last_pix_per_col);
        const rows_u: u32 = std.math.clamp(
            @as(u32, @intFromFloat(thumb_w_px * aspect / ppr_f)),
            2,
            @as(u32, self.grid_h -| 1),
        );
        const cell_h: u16 = @intCast(rows_u + 1); // label row is the gutter
        const vis: u32 = @max(1, self.grid_h / cell_h);
        const enough = vis >= min_rows and @as(u32, cols) * vis >= 2;
        if (enough or cols >= 12 or cell_w <= 9) {
            self.cols = cols;
            self.cell_w = cell_w;
            self.thumb_rows = @intCast(rows_u);
            self.cell_h = cell_h;
            break;
        }
        cols += 1;
    }
    self.thumb_max_w = @as(u32, self.cell_w) * ctx.last_pix_per_col;
    // Any size change (resize, zoom, this column pump) invalidates thumbs.
    if (self.thumb_max_w != self.last_thumb_w) {
        self.last_thumb_w = self.thumb_max_w;
        self.dumpThumbs();
    }
}

pub fn draw(self: *Self, win: vaxis.Window) void {
    const ctx = self.context;
    const total: u32 = ctx.document_handler.getTotalPages();
    if (win.width == 0 or win.height < 4 or total == 0) return;
    const ppc: u32 = ctx.last_pix_per_col;
    const ppr: u32 = ctx.last_pix_per_row;

    self.layout(win);
    self.scroll_cells = @min(self.scroll_cells, self.maxScroll());
    if (self.needs_snap) {
        self.needs_snap = false;
        self.ensureVisible(false);
    }

    _ = self.draw_arena.reset(.retain_capacity);
    const a = self.draw_arena.allocator();
    const label_style = vaxis.Cell.Style{ .fg = .{ .rgb = .{ 180, 180, 180 } } };
    const sel_style = vaxis.Cell.Style{ .fg = .{ .rgb = .{ 255, 215, 0 } }, .bold = true, .reverse = true };

    const first_row: u32 = self.scroll_cells / self.cell_h;
    const last_row: u32 = (@as(u32, self.scroll_cells) + self.grid_h + self.cell_h - 1) / self.cell_h;
    var want: [Prerenderer.thumb_slots]?u16 = .{null} ** Prerenderer.thumb_slots;
    var want_n: usize = 0;

    var row: u32 = first_row;
    while (row < last_row) : (row += 1) {
        var col: u16 = 0;
        while (col < self.cols) : (col += 1) {
            const page: u32 = row * self.cols + col;
            if (page >= total) break;
            const p: u16 = @intCast(page);

            const img: ?vaxis.Image = self.thumbs.get(p);
            if (img == null and want_n < want.len) {
                want[want_n] = p;
                want_n += 1;
            }

            const x0: u16 = col * self.cell_w;
            // Screen cell y of this grid cell's top; may be negative or
            // beyond grid_h — clip the thumb to the visible span.
            const sy: i32 = @as(i32, @intCast(row * self.cell_h)) - self.scroll_cells;

            if (img) |image| {
                const w_cells: u16 = @intCast(@max(1, std.math.divCeil(u32, image.width, ppc) catch 1));
                const img_rows: u16 = @intCast(@max(1, std.math.divCeil(u32, image.height, ppr) catch 1));
                const vis_from: i32 = @max(0, sy);
                const vis_to: i32 = @min(@as(i32, @intCast(self.grid_h)), sy + @as(i32, img_rows));
                if (vis_to > vis_from) {
                    const cut_top: u32 = @intCast(vis_from - sy);
                    const rows_vis: u16 = @intCast(vis_to - vis_from);
                    const clip_y: u32 = cut_top * ppr;
                    if (clip_y < image.height) {
                        const clip_h: u32 = @min(image.height - clip_y, @as(u32, rows_vis) * ppr);
                        const x_off: u16 = if (self.cell_w > w_cells) (self.cell_w - w_cells) / 2 else 0;
                        const child = win.child(.{
                            .x_off = x0 + x_off,
                            .y_off = @intCast(vis_from),
                            .width = @min(w_cells, self.cell_w),
                            .height = rows_vis,
                        });
                        image.draw(child, .{
                            .clip_region = .{
                                .x = 0,
                                .y = @intCast(clip_y),
                                .width = @intCast(image.width),
                                .height = @intCast(clip_h),
                            },
                            .size = .{ .cols = @min(w_cells, self.cell_w), .rows = rows_vis },
                        }) catch {};
                    }
                }
            }

            const label_y: i32 = sy + @as(i32, self.thumb_rows);
            if (label_y >= 0 and label_y < self.grid_h) {
                const label = std.fmt.allocPrint(a, " {d} ", .{page + 1}) catch continue;
                const lx: u16 = x0 + (self.cell_w -| @as(u16, @intCast(label.len))) / 2;
                _ = win.print(
                    &.{.{ .text = label, .style = if (p == self.selected) sel_style else label_style }},
                    .{ .row_offset = @intCast(label_y), .col_offset = lx, .wrap = .none },
                );
            }
        }
    }

    if (want_n > 0) {
        const max_h: u32 = @as(u32, self.thumb_rows) * ppr;
        if (!ctx.requestThumbs(want, self.thumb_max_w, max_h)) {
            // No background worker (cache disabled): render synchronously.
            for (want[0..want_n]) |maybe| {
                const p2 = maybe orelse continue;
                if (ctx.thumbImage(p2, self.thumb_max_w, max_h)) |image| {
                    self.thumbs.put(p2, image) catch {};
                } else |_| {}
            }
        }
    }
}

// Called by Context when a background thumb arrives; reject stale sizes and
// duplicates so their backing store gets discarded instead of leaked.
pub fn wantsThumb(self: *Self, page: u16, max_w: u32) bool {
    return max_w == self.thumb_max_w and !self.thumbs.contains(page);
}

pub fn putThumb(self: *Self, page: u16, img: vaxis.Image) void {
    self.thumbs.put(page, img) catch {
        self.context.stale_images.append(self.context.allocator, .{
            .image = img,
            .origin_x = 0,
            .origin_y = 0,
        }) catch {};
    };
}
