// The library: every book with a reading record as a grid of covers with
// title and progress. Enter reopens the reader on the chosen book (fetched
// from a sync store when it is not on this machine); `/` filters the titles;
// `u` puts the book's PDF in the store.
const Self = @This();
const std = @import("std");
const vaxis = @import("vaxis");
const Context = @import("../Context.zig").Context;
const Config = @import("../config/Config.zig");
const Positions = @import("../services/Positions.zig");
const ListView = @import("ListView.zig");
const theme = ListView.theme;
const time = @import("../utilities/time.zig");

pub const hides_page = true;

const card_w_min: u16 = 16;
const card_w_max: u16 = 64;
// Portrait pages; the real ratio comes from the PNG once transmitted.
const cover_aspect: f32 = 1.4;
const grid_top: u16 = 2;
// cover, title, progress, last read, gap
const card_extra_rows: u16 = 4;

context: *Context,
books: []Positions.RecentEntry,
// Indices into `books` that pass the filter, in list order; the cursor
// addresses these.
shown: std.ArrayList(usize),
filter: std.ArrayList(u8),
// After `/`: keys edit the filter.
typing: bool,
help: bool,
// `d`/`D` wait for `y`.
confirm: enum { none, forget, delete_store },
cursor: usize,
top_row: usize,
// Keys scroll the cursor into view; the wheel pans the grid on its own.
follow: bool,
// Index -> transmitted cover; null when the book has no cover file.
covers: std.AutoHashMap(usize, ?vaxis.Image),
// Geometry from the last draw.
card_w: u16,
cols: u16,
card_h: u16,
cover_rows: u16,
rows_visible: u16,
origin_x: i32,
origin_y: i32,

pub fn init(context: *Context) Self {
    var self = Self{
        .context = context,
        .books = &.{},
        .shown = .empty,
        .filter = .empty,
        .typing = false,
        .help = false,
        .confirm = .none,
        .cursor = 0,
        .top_row = 0,
        .follow = true,
        .covers = std.AutoHashMap(usize, ?vaxis.Image).init(context.allocator),
        .card_w = context.library_card_w,
        .cols = 1,
        .card_h = 1,
        .cover_rows = 1,
        .rows_visible = 1,
        .origin_x = 0,
        .origin_y = 0,
    };
    self.reload(context.positions.bookName());
    context.requestLibraryIndex();
    context.ensureCovers(self.books);
    return self;
}

pub fn deinit(self: *Self) void {
    self.dumpCovers();
    self.covers.deinit();
    self.shown.deinit(self.context.allocator);
    self.filter.deinit(self.context.allocator);
    Positions.freeRecent(self.context.allocator, self.books);
}

fn dumpCovers(self: *Self) void {
    var it = self.covers.valueIterator();
    while (it.next()) |maybe| {
        if (maybe.*) |img| self.context.discardAfterFrame(.{ .image = img, .origin_x = 0, .origin_y = 0 });
    }
    self.covers.clearRetainingCapacity();
}

// Re-reads the records, keeping the cursor on `key` when it is still listed.
fn reload(self: *Self, key: []const u8) void {
    const ctx = self.context;
    Positions.freeRecent(ctx.allocator, self.books);
    self.dumpCovers();
    self.books = Positions.listRecent(ctx.allocator, ctx.io, ctx.paths);
    self.applyFilter(key);
}

// Rebuilds `shown` from the filter; the cursor stays on `key` when it is
// still shown.
fn applyFilter(self: *Self, key: []const u8) void {
    const a = self.context.allocator;
    self.shown.clearRetainingCapacity();
    self.cursor = 0;
    for (self.books, 0..) |b, i| {
        if (!matches(std.fs.path.stem(std.fs.path.basename(b.path)), self.filter.items)) continue;
        if (std.mem.eql(u8, b.key, key)) self.cursor = self.shown.items.len;
        self.shown.append(a, i) catch break;
    }
}

// Every whitespace-separated word of the filter occurs in the title,
// ignoring case.
fn matches(title: []const u8, filter: []const u8) bool {
    var words = std.mem.tokenizeAny(u8, filter, " \t");
    while (words.next()) |w| {
        if (!containsIgnoreCase(title, w)) return false;
    }
    return true;
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len > haystack.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (std.ascii.startsWithIgnoreCase(haystack[i..], needle)) return true;
    }
    return false;
}

fn selectedKey(self: *Self) []const u8 {
    if (self.cursor >= self.shown.items.len) return "";
    return self.books[self.shown.items[self.cursor]].key;
}

fn refilter(self: *Self) void {
    var buf: [256]u8 = undefined;
    const key = self.selectedKey();
    const n = @min(key.len, buf.len);
    @memcpy(buf[0..n], key[0..n]);
    self.applyFilter(buf[0..n]);
    self.follow = true;
}

// Other devices' records arrived.
pub fn refresh(self: *Self) void {
    var buf: [256]u8 = undefined;
    const key = self.selectedKey();
    const n = @min(key.len, buf.len);
    @memcpy(buf[0..n], key[0..n]);
    self.reload(buf[0..n]);
    self.context.ensureCovers(self.books);
}

// The cover worker wrote a cover or a page count. Same books in the same
// order: keep the transmitted covers and retry only the missing ones.
pub fn coversChanged(self: *Self) void {
    const ctx = self.context;
    const fresh = Positions.listRecent(ctx.allocator, ctx.io, ctx.paths);
    var same = fresh.len == self.books.len;
    if (same) for (fresh, self.books) |x, y| {
        if (!std.mem.eql(u8, x.key, y.key)) same = false;
    };
    if (!same) {
        Positions.freeRecent(ctx.allocator, fresh);
        self.refresh();
        return;
    }
    Positions.freeRecent(ctx.allocator, self.books);
    self.books = fresh;
    self.refilter();
    var missing: std.ArrayList(usize) = .empty;
    defer missing.deinit(ctx.allocator);
    var it = self.covers.iterator();
    while (it.next()) |e| {
        if (e.value_ptr.* == null) missing.append(ctx.allocator, e.key_ptr.*) catch break;
    }
    for (missing.items) |k| _ = self.covers.remove(k);
}

fn coverCols(self: *Self) u16 {
    return self.card_w - 4;
}

fn zoom(self: *Self, delta: i32) void {
    const w: i32 = std.math.clamp(@as(i32, self.card_w) + delta, card_w_min, card_w_max);
    self.card_w = @intCast(w);
    self.context.setLibraryCardWidth(self.card_w);
    self.follow = true;
}

fn moveCursor(self: *Self, delta: i32) void {
    if (self.shown.items.len == 0) return;
    const max: i32 = @intCast(self.shown.items.len - 1);
    self.cursor = @intCast(std.math.clamp(@as(i32, @intCast(self.cursor)) + delta, 0, max));
    self.follow = true;
}

fn selected(self: *Self) ?Positions.RecentEntry {
    if (self.cursor >= self.shown.items.len) return null;
    return self.books[self.shown.items[self.cursor]];
}

fn open(self: *Self) void {
    const b = self.selected() orelse return;
    if (std.mem.eql(u8, b.key, self.context.positions.bookName())) {
        self.context.changeMode(.view);
        return;
    }
    self.context.openBook(b.key, b.path);
}

fn upload(self: *Self) void {
    const b = self.selected() orelse return;
    if (b.device.len > 0) {
        self.context.setProgress(" not on this machine: nothing to upload ");
        return;
    }
    self.context.uploadBook(b.key, b.path);
}

fn toggleDone(self: *Self) void {
    const b = self.selected() orelse return;
    const ctx = self.context;
    Positions.markDone(ctx.allocator, ctx.io, ctx.paths, b.key, b.path, !b.done) catch |e| {
        ctx.setProgress(std.fmt.bufPrint(&ctx.progress_buf, " failed: {s} ", .{@errorName(e)}) catch null);
        return;
    };
    ctx.setProgress(if (b.done) " not done " else " done ");
    self.refresh();
}

fn resetProgress(self: *Self) void {
    const b = self.selected() orelse return;
    const ctx = self.context;
    if (std.mem.eql(u8, b.key, ctx.positions.bookName())) {
        ctx.setProgress(" this book is open: reset it from the reader (gg) ");
        return;
    }
    Positions.resetProgress(ctx.allocator, ctx.io, ctx.paths, b.key, b.path) catch |e| {
        ctx.setProgress(std.fmt.bufPrint(&ctx.progress_buf, " failed: {s} ", .{@errorName(e)}) catch null);
        return;
    };
    ctx.setProgress(" progress reset to page 1 ");
    self.refresh();
}

fn ask(self: *Self, what: @TypeOf(self.confirm)) void {
    const b = self.selected() orelse return;
    const ctx = self.context;
    const title = std.fs.path.stem(std.fs.path.basename(b.path));
    if (what == .forget and std.mem.eql(u8, b.key, ctx.positions.bookName())) {
        ctx.setProgress(" this book is open: close it first ");
        return;
    }
    if (what == .delete_store and !ctx.bookInStore(b.key)) {
        ctx.setProgress(" not in the sync store ");
        return;
    }
    self.confirm = what;
    ctx.setProgress(switch (what) {
        .forget => std.fmt.bufPrint(&ctx.progress_buf, " forget \"{s}\" on this device (records, cover, downloaded copy)? y/N ", .{title}) catch null,
        else => std.fmt.bufPrint(&ctx.progress_buf, " remove \"{s}\" PDF from the sync store? y/N ", .{title}) catch null,
    });
}

fn answer(self: *Self, key: vaxis.Key) void {
    const what = self.confirm;
    self.confirm = .none;
    if (!key.matches('y', .{})) {
        self.context.setProgress(" cancelled ");
        return;
    }
    const b = self.selected() orelse return;
    switch (what) {
        .forget => {
            self.context.forgetBook(b.key, b.path);
            self.refresh();
        },
        .delete_store => self.context.deleteFromStore(b.key),
        .none => {},
    }
}

fn typeKey(self: *Self, key: vaxis.Key, km: Config.KeyMap) bool {
    const a = self.context.allocator;
    if (key.matches(km.exit_command_mode.codepoint, km.exit_command_mode.mods)) {
        self.typing = false;
        self.filter.clearRetainingCapacity();
        self.refilter();
        return true;
    }
    if (key.matches(vaxis.Key.backspace, .{})) {
        while (self.filter.pop()) |c| {
            if (c & 0xC0 != 0x80) break;
        }
        self.refilter();
        return true;
    }
    if (key.matches(km.list_select.codepoint, km.list_select.mods)) {
        self.typing = false;
        return true;
    }
    const text = key.text orelse return false;
    if (key.mods.ctrl or key.mods.alt or key.mods.super) return false;
    self.filter.appendSlice(a, text) catch return true;
    self.refilter();
    return true;
}

pub fn handleKeyStroke(self: *Self, key: vaxis.Key, km: Config.KeyMap) !void {
    if (self.help) {
        self.help = false;
        if (key.matches(km.exit_command_mode.codepoint, km.exit_command_mode.mods) or key.matches('?', .{}) or key.matches('?', .{ .shift = true })) return;
    }
    if (self.confirm != .none) return self.answer(key);
    if (self.typing and self.typeKey(key, km)) return;
    if (key.matches(km.exit_command_mode.codepoint, km.exit_command_mode.mods)) {
        if (self.filter.items.len > 0) {
            self.filter.clearRetainingCapacity();
            self.refilter();
            return;
        }
        self.context.changeMode(.view);
        return;
    }
    if (!self.typing) {
        if (key.matches(km.library_mode.codepoint, km.library_mode.mods)) {
            self.context.changeMode(.view);
            return;
        }
        if (key.matches(km.search.codepoint, km.search.mods)) {
            self.typing = true;
            return;
        }
        if (key.matches(km.zoom_in.codepoint, km.zoom_in.mods)) return self.zoom(4);
        if (key.matches(km.zoom_out.codepoint, km.zoom_out.mods)) return self.zoom(-4);
        if (key.matches('u', .{})) return self.upload();
        if (key.matches('x', .{})) return self.toggleDone();
        if (key.matches('r', .{})) return self.resetProgress();
        if (key.matches('d', .{})) return self.ask(.forget);
        if (key.matches('D', .{ .shift = true }) or key.matches('D', .{})) return self.ask(.delete_store);
        if (key.matches('?', .{}) or key.matches('?', .{ .shift = true })) {
            self.help = true;
            return;
        }
    }
    const cols: i32 = @intCast(self.cols);
    if (key.matches(vaxis.Key.up, .{}) or key.matches(km.scroll_up.codepoint, km.scroll_up.mods)) return self.moveCursor(-cols);
    if (key.matches(vaxis.Key.down, .{}) or key.matches(km.scroll_down.codepoint, km.scroll_down.mods)) return self.moveCursor(cols);
    if (key.matches(vaxis.Key.left, .{}) or key.matches(km.scroll_left.codepoint, km.scroll_left.mods)) return self.moveCursor(-1);
    if (key.matches(vaxis.Key.right, .{}) or key.matches(km.scroll_right.codepoint, km.scroll_right.mods)) return self.moveCursor(1);
    if (key.matches(km.scroll_half_down.codepoint, km.scroll_half_down.mods)) return self.moveCursor(cols * @as(i32, self.rows_visible));
    if (key.matches(km.scroll_half_up.codepoint, km.scroll_half_up.mods)) return self.moveCursor(-cols * @as(i32, self.rows_visible));
    if (key.matches(km.list_top.codepoint, km.list_top.mods)) return self.moveCursor(-@as(i32, @intCast(self.cursor)));
    if (key.matches(km.list_bottom.codepoint, km.list_bottom.mods)) return self.moveCursor(@intCast(self.shown.items.len));
    if (key.matches(km.list_select.codepoint, km.list_select.mods)) self.open();
}

pub fn handleMouse(self: *Self, mouse: vaxis.Mouse) void {
    if (mouse.type != .press) return;
    switch (mouse.button) {
        .wheel_up => {
            self.top_row -|= 1;
            self.follow = false;
        },
        .wheel_down => {
            self.top_row += 1;
            self.follow = false;
        },
        .left => if (self.cardAt(mouse.col, mouse.row)) |i| {
            self.cursor = i;
            self.open();
        },
        else => {},
    }
}

fn cardAt(self: *Self, col: i32, row: i32) ?usize {
    const x = col - self.origin_x;
    const y = row - self.origin_y;
    if (x < 0 or y < 0) return null;
    const c: usize = @intCast(@divTrunc(x, self.card_w));
    const r: usize = @intCast(@divTrunc(y, self.card_h));
    if (c >= self.cols or r >= self.rows_visible) return null;
    const idx = (self.top_row + r) * self.cols + c;
    return if (idx < self.shown.items.len) idx else null;
}

pub fn draw(self: *Self, win: vaxis.Window) void {
    const ctx = self.context;
    if (win.width < 12 or win.height < 8) return;
    const p = ListView.layout(win, win.height, win.width);
    const popup = p.win;
    const a = ctx.frameAlloc();

    const n = self.shown.items.len;
    const title = if (self.typing or self.filter.items.len > 0)
        std.fmt.allocPrint(a, " Library — {d}/{d} book{s}  /{s}{s} ", .{ n, self.books.len, if (self.books.len == 1) "" else "s", self.filter.items, if (self.typing) "▏" else "" }) catch " Library "
    else
        std.fmt.allocPrint(a, " Library — {d} book{s}  Enter open · / filter · ? keys · Esc ", .{ n, if (n == 1) "" else "s" }) catch " Library ";
    p.title(title, theme.head);
    if (n == 0) {
        const msg: []const u8 = if (self.books.len == 0) " (no books yet) " else " (no title matches) ";
        _ = popup.print(&.{.{ .text = msg, .style = theme.dim }}, .{ .row_offset = 2, .col_offset = 1, .wrap = .none });
        return;
    }

    const ppc: u32 = @max(1, ctx.last_pix_per_col);
    const ppr: u32 = @max(1, ctx.last_pix_per_row);
    const inner_w: u16 = popup.width -| 2;
    self.cols = @max(1, inner_w / self.card_w);
    const x_margin: u16 = 1 + (inner_w -| self.cols * self.card_w) / 2;
    const grid_h: u16 = popup.height -| grid_top;
    const cover_px_w: f32 = @floatFromInt(@as(u32, self.coverCols()) * ppc);
    const want_rows: u32 = @intFromFloat(@ceil(cover_px_w * cover_aspect / @as(f32, @floatFromInt(ppr))));
    self.cover_rows = @intCast(std.math.clamp(want_rows, 3, @as(u32, @max(grid_h, card_extra_rows + 3)) - card_extra_rows));
    self.card_h = self.cover_rows + card_extra_rows;
    self.rows_visible = @max(1, grid_h / self.card_h);
    const total_rows: usize = (n + self.cols - 1) / self.cols;
    if (self.follow) {
        const cur_row = self.cursor / self.cols;
        if (cur_row < self.top_row) self.top_row = cur_row;
        if (cur_row >= self.top_row + self.rows_visible) self.top_row = cur_row + 1 - self.rows_visible;
    }
    self.top_row = @min(self.top_row, total_rows -| self.rows_visible);
    self.origin_x = @as(i32, popup.x_off) + x_margin;
    self.origin_y = @as(i32, popup.y_off) + grid_top;

    const now = time.nowRealSeconds();
    var r: u16 = 0;
    while (r < self.rows_visible) : (r += 1) {
        var c: u16 = 0;
        while (c < self.cols) : (c += 1) {
            const i = (self.top_row + r) * self.cols + c;
            if (i >= n) break;
            self.drawCard(popup, a, i, x_margin + c * self.card_w, grid_top + r * self.card_h, ppc, ppr, now);
        }
    }
    if (self.help) self.drawHelp(popup);
}

const help_lines = [_][]const u8{
    " Enter / click   open the book (downloads it when it is only in the store) ",
    " h j k l         move          Ctrl-d / Ctrl-u  page          g / G  first / last ",
    " i / o           bigger / smaller cards ",
    " /               filter titles as you type; Enter keeps the filter, Esc clears it ",
    " u               upload the PDF and cover to the sync store ",
    " D               remove the PDF from the sync store (records stay) ",
    " x               mark done / not done ",
    " r               reset progress to page 1 (marks and highlights stay) ",
    " d               forget on this device: records, cover, downloaded copy ",
    " b / Esc         close ",
};

const help_bg = vaxis.Cell.Style{
    .bg = .{ .rgb = .{ 48, 48, 66 } },
    .fg = .{ .rgb = .{ 230, 230, 230 } },
};

const Rect = struct {
    x: u16,
    y: u16,
    w: u16,
    h: u16,

    fn overlaps(r: Rect, x: u16, y: u16, w: u16, h: u16) bool {
        return x < r.x + r.w and x + w > r.x and y < r.y + r.h and y + h > r.y;
    }
};

fn helpRect(self: *Self, popup: vaxis.Window) Rect {
    _ = self;
    var w: u16 = 0;
    for (help_lines) |l| w = @max(w, @as(u16, @intCast(std.unicode.utf8CountCodepoints(l) catch l.len)));
    w = @min(w + 2, popup.width);
    const h: u16 = @min(help_lines.len + 2, popup.height);
    return .{ .x = (popup.width -| w) / 2, .y = (popup.height -| h) / 2, .w = w, .h = h };
}

fn drawHelp(self: *Self, popup: vaxis.Window) void {
    const r = self.helpRect(popup);
    const w = r.w;
    const h = r.h;
    const box = popup.child(.{ .x_off = r.x, .y_off = r.y, .width = w, .height = h });
    box.fill(.{ .char = .{ .grapheme = " ", .width = 1 }, .style = help_bg });
    _ = box.print(&.{.{ .text = " Library keys ", .style = theme.head }}, .{ .row_offset = 0, .col_offset = 1, .wrap = .none });
    for (help_lines, 0..) |l, i| {
        if (i + 1 >= h) break;
        _ = box.print(&.{.{ .text = l, .style = help_bg }}, .{ .row_offset = @intCast(i + 1), .col_offset = 1, .wrap = .none });
    }
}

// `slot` indexes `shown`.
fn drawCard(self: *Self, popup: vaxis.Window, a: std.mem.Allocator, slot: usize, x0: u16, y0: u16, ppc: u32, ppr: u32, now: i64) void {
    const i = self.shown.items[slot];
    const b = self.books[i];
    const is_cursor = slot == self.cursor;
    const remote = b.device.len > 0;
    const cover_x: u16 = x0 + 2;

    // The terminal paints images over text, so a cover under the help box
    // is left out for that frame (placements are redone every frame).
    const under_help = self.help and self.helpRect(popup).overlaps(cover_x, y0, self.coverCols(), self.cover_rows);
    if (if (under_help) null else self.coverFor(i)) |img| {
        const box_w: f32 = @floatFromInt(@as(u32, self.coverCols()) * ppc);
        const box_h: f32 = @floatFromInt(@as(u32, self.cover_rows) * ppr);
        const img_w: f32 = @floatFromInt(img.width);
        const img_h: f32 = @floatFromInt(img.height);
        const scale = @min(box_w / img_w, box_h / img_h);
        const w_cells: u16 = @intCast(std.math.clamp(@as(u32, @intFromFloat(@ceil(img_w * scale / @as(f32, @floatFromInt(ppc))))), 1, self.coverCols()));
        const rows: u16 = @intCast(std.math.clamp(@as(u32, @intFromFloat(@ceil(img_h * scale / @as(f32, @floatFromInt(ppr))))), 1, self.cover_rows));
        const child = popup.child(.{
            .x_off = cover_x + (self.coverCols() - w_cells) / 2,
            .y_off = y0 + (self.cover_rows - rows),
            .width = w_cells,
            .height = rows,
        });
        img.draw(child, .{ .size = .{ .cols = w_cells, .rows = rows } }) catch {};
    } else if (!under_help) {
        const label: []const u8 = if (remote) "no cover yet" else "no cover";
        _ = popup.print(&.{.{ .text = label, .style = theme.dim }}, .{
            .row_offset = y0 + self.cover_rows / 2,
            .col_offset = cover_x + (self.coverCols() -| @as(u16, @intCast(label.len))) / 2,
            .wrap = .none,
        });
    }

    const text_w: usize = self.card_w - 2;
    const title = fit(a, std.fs.path.stem(std.fs.path.basename(b.path)), text_w, is_cursor);
    const title_style = if (is_cursor) theme.sel else if (remote) theme.dim else theme.bg;
    _ = popup.print(&.{.{ .text = title, .style = title_style }}, .{ .row_offset = y0 + self.cover_rows, .col_offset = x0 + 1, .wrap = .none });

    const py: u16 = y0 + self.cover_rows + 1;
    const nums = if (b.done)
        "done"
    else if (b.pages > 0)
        std.fmt.allocPrint(a, "{d}/{d}", .{ b.page + 1, b.pages }) catch ""
    else
        std.fmt.allocPrint(a, "p.{d}", .{b.page + 1}) catch "";
    const bar_w: usize = text_w -| (nums.len + 1);
    if ((b.done or b.pages > 0) and bar_w >= 4) {
        const filled: usize = if (b.done) bar_w else @min(bar_w, (bar_w * (@as(usize, b.page) + 1) + b.pages / 2) / b.pages);
        _ = popup.print(&.{
            .{ .text = repeat(a, "━", filled), .style = theme.accent },
            .{ .text = repeat(a, "╌", bar_w - filled), .style = theme.dim },
            .{ .text = " ", .style = theme.bg },
            .{ .text = nums, .style = theme.bg },
        }, .{ .row_offset = py, .col_offset = x0 + 1, .wrap = .none });
    } else {
        _ = popup.print(&.{.{ .text = nums, .style = theme.bg }}, .{ .row_offset = py, .col_offset = x0 + 1, .wrap = .none });
    }

    // Last read on the left; on the right where the PDF is: local file,
    // uploaded, or only on another device (dimmed card).
    const in_store = self.context.bookInStore(b.key);
    const when = if (remote)
        std.fmt.allocPrint(a, "{s} · {s}", .{ ago(a, now - b.last_opened), b.device }) catch ""
    else
        ago(a, now - b.last_opened);
    const uploading = !remote and !in_store and self.context.uploadPending(b.key);
    const badge: []const u8 = if (uploading) "uploading…" else if (remote) (if (in_store) "in store" else "not here") else if (in_store) "uploaded" else "local";
    const badge_style = if (uploading or in_store) theme.accent else theme.dim;
    const badge_w = std.unicode.utf8CountCodepoints(badge) catch badge.len;
    const when_w = text_w -| (badge_w + 1);
    _ = popup.print(&.{.{ .text = fit(a, when, when_w, false), .style = theme.dim }}, .{ .row_offset = py + 1, .col_offset = x0 + 1, .wrap = .none });
    _ = popup.print(&.{.{ .text = badge, .style = badge_style }}, .{ .row_offset = py + 1, .col_offset = x0 + 1 + @as(u16, @intCast(text_w - badge_w)), .wrap = .none });
}

fn coverFor(self: *Self, i: usize) ?vaxis.Image {
    if (self.covers.get(i)) |c| return c;
    const img = self.loadCover(i);
    self.covers.put(i, img) catch {
        if (img) |im| self.context.discardAfterFrame(.{ .image = im, .origin_x = 0, .origin_y = 0 });
        return null;
    };
    return img;
}

// Transmits the book's cover.png as-is (f=100); the terminal scales it into
// the card.
fn loadCover(self: *Self, i: usize) ?vaxis.Image {
    const ctx = self.context;
    const a = ctx.frameAlloc();
    const path = Positions.coverFile(a, ctx.paths, self.books[i].key) catch return null;
    const png = std.Io.Dir.cwd().readFileAlloc(ctx.io, path, a, .limited(16 * 1024 * 1024)) catch return null;
    if (png.len < 24 or !std.mem.startsWith(u8, png, "\x89PNG\r\n\x1a\n")) return null;
    const w = std.mem.readInt(u32, png[16..20], .big);
    const h = std.mem.readInt(u32, png[20..24], .big);
    if (w == 0 or h == 0 or w > std.math.maxInt(u16) or h > std.math.maxInt(u16)) return null;
    const b64 = a.alloc(u8, std.base64.standard.Encoder.calcSize(png.len)) catch return null;
    const encoded = std.base64.standard.Encoder.encode(b64, png);
    return ctx.vx.transmitPreEncodedImage(ctx.tty.writer(), encoded, @intCast(w), @intCast(h), .png) catch null;
}

// At most `w` codepoints, "…" when cut; space-padded to `w` when `pad`.
fn fit(a: std.mem.Allocator, s: []const u8, w: usize, pad: bool) []const u8 {
    const view = std.unicode.Utf8View.init(s) catch return s[0..@min(s.len, w)];
    const total = std.unicode.utf8CountCodepoints(s) catch s.len;
    var out: std.ArrayList(u8) = .empty;
    var it = view.iterator();
    var n: usize = 0;
    const keep = if (total > w) w -| 1 else total;
    while (n < keep) : (n += 1) out.appendSlice(a, it.nextCodepointSlice() orelse break) catch break;
    if (total > w) {
        out.appendSlice(a, "…") catch {};
        n += 1;
    }
    if (pad) while (n < w) : (n += 1) out.append(a, ' ') catch break;
    return out.items;
}

fn repeat(a: std.mem.Allocator, glyph: []const u8, n: usize) []const u8 {
    const out = a.alloc(u8, glyph.len * n) catch return "";
    for (0..n) |i| @memcpy(out[i * glyph.len .. (i + 1) * glyph.len], glyph);
    return out;
}

fn ago(a: std.mem.Allocator, secs: i64) []const u8 {
    const s = @max(0, secs);
    if (s < 60) return "just now";
    if (s < 3600) return std.fmt.allocPrint(a, "{d}m ago", .{@divTrunc(s, 60)}) catch "";
    if (s < 86400) return std.fmt.allocPrint(a, "{d}h ago", .{@divTrunc(s, 3600)}) catch "";
    return std.fmt.allocPrint(a, "{d}d ago", .{@divTrunc(s, 86400)}) catch "";
}
