const Self = @This();
const std = @import("std");
const vaxis = @import("vaxis");
const Context = @import("../Context.zig").Context;
const Config = @import("../config/Config.zig");
const PdfHandler = @import("../handlers/PdfHandler.zig");

pub const hides_page = true;

context: *Context,
entries: []const PdfHandler.OutlineEntry,
visible: std.ArrayList(usize),
expanded: std.AutoHashMap(usize, void),
cursor: usize,
top: usize,
manual_top: bool = false,
draw_arena: std.heap.ArenaAllocator,

pub fn init(context: *Context) Self {
    const entries: []const PdfHandler.OutlineEntry =
        context.document_handler.loadOutline(context.allocator) catch &.{};

    var self = Self{
        .context = context,
        .entries = entries,
        .visible = .empty,
        .expanded = std.AutoHashMap(usize, void).init(context.allocator),
        .cursor = 0,
        .top = 0,
        .draw_arena = std.heap.ArenaAllocator.init(context.allocator),
    };

    self.autoExpandToCurrentPage();
    self.rebuildVisible() catch {};
    self.setCursorNearCurrentPage();
    return self;
}

pub fn deinit(self: *Self) void {
    self.draw_arena.deinit();
    self.visible.deinit(self.context.allocator);
    self.expanded.deinit();
    const a = self.context.allocator;
    if (self.entries.len > 0) {
        for (self.entries) |e| a.free(e.title);
        a.free(self.entries);
    }
}

fn hasChildren(self: *const Self, idx: usize) bool {
    if (idx + 1 >= self.entries.len) return false;
    return self.entries[idx + 1].depth > self.entries[idx].depth;
}

fn autoExpandToCurrentPage(self: *Self) void {
    const cur_page = self.context.document_handler.getCurrentPageNumber();
    var i: usize = 0;
    while (i < self.entries.len) : (i += 1) {
        const e = self.entries[i];
        if (e.page > cur_page) break;
        // Expand each non-leaf ancestor along the way (depth strictly increases)
        if (self.hasChildren(i)) self.expanded.put(i, {}) catch {};
    }
}

fn rebuildVisible(self: *Self) !void {
    self.visible.clearRetainingCapacity();
    var depth_open: [33]bool = @splat(false);
    for (self.entries, 0..) |e, i| {
        const d: usize = @min(e.depth, 32);
        var ok = true;
        var k: usize = 0;
        while (k < d) : (k += 1) {
            if (!depth_open[k]) {
                ok = false;
                break;
            }
        }
        if (ok) try self.visible.append(self.context.allocator, i);
        depth_open[d] = ok and self.expanded.contains(i);
        if (d + 1 < depth_open.len) {
            var j = d + 1;
            while (j < depth_open.len) : (j += 1) depth_open[j] = false;
        }
    }
}

fn setCursorNearCurrentPage(self: *Self) void {
    const cur_page = self.context.document_handler.getCurrentPageNumber();
    self.cursor = 0;
    for (self.visible.items, 0..) |entry_idx, vi| {
        if (self.entries[entry_idx].page > cur_page) break;
        self.cursor = vi;
    }
}

pub fn handleKeyStroke(self: *Self, key: vaxis.Key, km: Config.KeyMap) !void {
    // Any key resumes cursor-follows-view auto-scroll (wheel-only sticks).
    self.manual_top = false;
    if (key.matches(km.exit_command_mode.codepoint, km.exit_command_mode.mods) or
        key.matches(km.toc_mode.codepoint, km.toc_mode.mods))
    {
        self.context.changeMode(.view);
        return;
    }
    if (self.visible.items.len == 0) {
        self.context.changeMode(.view);
        return;
    }
    if (key.matches(vaxis.Key.up, .{}) or key.matches('k', .{})) {
        if (self.cursor > 0) self.cursor -= 1;
        return;
    }
    if (key.matches(vaxis.Key.down, .{}) or key.matches('j', .{})) {
        if (self.cursor + 1 < self.visible.items.len) self.cursor += 1;
        return;
    }
    if (self.context.handleListHalfPage(key, &self.cursor, self.visible.items.len)) return;
    if (key.matches('L', .{})) {
        self.expandOneLevel();
        return;
    }
    if (key.matches('H', .{})) {
        self.collapseOneLevel();
        return;
    }
    if (key.matches('g', .{})) {
        self.cursor = 0;
        return;
    }
    if (key.matches('G', .{})) {
        self.cursor = self.visible.items.len - 1;
        return;
    }
    if (key.matches(vaxis.Key.right, .{}) or key.matches('l', .{})) {
        self.expandCurrent();
        return;
    }
    if (key.matches(vaxis.Key.left, .{}) or key.matches('h', .{})) {
        self.collapseCurrent();
        return;
    }
    if (key.matches(vaxis.Key.space, .{})) {
        self.toggleCurrent();
        return;
    }
    if (key.matches(km.open_in_editor.codepoint, km.open_in_editor.mods)) {
        self.context.openOutlineInEditor(self.currentEntryIdx()) catch {};
        return;
    }
    if (key.matches(vaxis.Key.enter, .{})) {
        const e = self.entries[self.visible.items[self.cursor]];
        self.context.changeMode(.view);
        self.context.followLink(.{ .page = .{ .num = e.page, .y = e.y } });
        return;
    }
}

pub fn handleMouse(self: *Self, mouse: vaxis.Mouse) void {
    if (mouse.type != .press) return;
    if (self.visible.items.len == 0) return;
    const step: usize = 3;
    switch (mouse.button) {
        .wheel_up => {
            self.top -|= step;
            self.manual_top = true;
        },
        .wheel_down => {
            const max_top = self.visible.items.len -| 1;
            self.top = @min(self.top + step, max_top);
            self.manual_top = true;
        },
        else => {},
    }
}

fn expandCurrent(self: *Self) void {
    if (self.cursor >= self.visible.items.len) return;
    const idx = self.visible.items[self.cursor];
    if (!self.hasChildren(idx)) return;
    if (self.expanded.contains(idx)) return;
    self.expanded.put(idx, {}) catch return;
    self.rebuildVisible() catch {};
    self.refindCursor(idx);
}

fn currentEntryIdx(self: *Self) ?usize {
    if (self.cursor < self.visible.items.len) return self.visible.items[self.cursor];
    return null;
}

// Pre-order outline: the parent is the nearest preceding shallower entry.
fn parentOf(self: *Self, idx: usize) ?usize {
    const d = self.entries[idx].depth;
    if (d == 0) return null;
    var k = idx;
    while (k > 0) {
        k -= 1;
        if (self.entries[k].depth < d) return k;
    }
    return null;
}

fn visibleIndexOf(self: *Self, entry_idx: usize) ?usize {
    for (self.visible.items, 0..) |v, i| {
        if (v == entry_idx) return i;
    }
    return null;
}

fn collapseCurrent(self: *Self) void {
    var idx = self.currentEntryIdx() orelse return;
    // If current is not expanded, collapse parent and move cursor to it
    if (!self.expanded.contains(idx)) {
        idx = self.parentOf(idx) orelse return;
    }
    _ = self.expanded.remove(idx);
    self.rebuildVisible() catch {};
    self.refindCursor(idx);
}

// vim zr: every visible collapsed branch opens one level.
fn expandOneLevel(self: *Self) void {
    const cur = self.currentEntryIdx();
    var changed = false;
    for (self.visible.items) |idx| {
        if (self.hasChildren(idx) and !self.expanded.contains(idx)) {
            self.expanded.put(idx, {}) catch continue;
            changed = true;
        }
    }
    if (!changed) return;
    self.rebuildVisible() catch {};
    if (cur) |idx| self.refindCursor(idx);
}

// vim zm: the deepest currently-expanded level folds shut.
fn collapseOneLevel(self: *Self) void {
    const cur = self.currentEntryIdx();
    var dmax: ?u8 = null;
    for (self.visible.items) |idx| {
        if (!self.expanded.contains(idx)) continue;
        const d = self.entries[idx].depth;
        if (dmax == null or d > dmax.?) dmax = d;
    }
    const target = dmax orelse return;
    for (self.visible.items) |idx| {
        if (self.expanded.contains(idx) and self.entries[idx].depth == target) {
            _ = self.expanded.remove(idx);
        }
    }
    self.rebuildVisible() catch {};
    if (cur) |idx| self.refindCursorOrAncestor(idx);
}

// Like refindCursor, but when the entry got hidden by a fold, lands on its
// nearest still-visible ancestor (pre-order outline: nearest preceding
// shallower entry is the parent).
fn refindCursorOrAncestor(self: *Self, entry_idx: usize) void {
    var idx = entry_idx;
    while (self.visibleIndexOf(idx) == null) {
        idx = self.parentOf(idx) orelse break;
    }
    self.refindCursor(idx);
}

fn toggleCurrent(self: *Self) void {
    if (self.cursor >= self.visible.items.len) return;
    const idx = self.visible.items[self.cursor];
    if (!self.hasChildren(idx)) return;
    if (self.expanded.contains(idx)) {
        _ = self.expanded.remove(idx);
    } else {
        self.expanded.put(idx, {}) catch return;
    }
    self.rebuildVisible() catch {};
    self.refindCursor(idx);
}

fn refindCursor(self: *Self, entry_idx: usize) void {
    if (self.visibleIndexOf(entry_idx)) |i| {
        self.cursor = i;
        return;
    }
    if (self.visible.items.len > 0 and self.cursor >= self.visible.items.len) {
        self.cursor = self.visible.items.len - 1;
    }
}

pub fn draw(self: *Self, win: vaxis.Window) void {
    const title_style = vaxis.Cell.Style{ .fg = .{ .rgb = .{ 100, 200, 255 } }, .bold = true };
    const row_style = vaxis.Cell.Style{ .fg = .{ .rgb = .{ 230, 230, 230 } } };
    const sel_style = vaxis.Cell.Style{ .fg = .{ .rgb = .{ 255, 215, 0 } }, .bold = true };

    const w: u16 = if (win.width > 8) win.width - 4 else win.width;
    const h: u16 = if (win.height > 4) win.height - 2 else win.height;
    const x_off: u16 = (win.width -| w) / 2;
    const y_off: u16 = (win.height -| h) / 2;

    const popup = win.child(.{ .x_off = x_off, .y_off = y_off, .width = w, .height = h });

    _ = popup.print(
        &.{.{ .text = " Table of Contents (Enter: jump, h/l: fold, H/L: fold level, e: editor, Esc: close) ", .style = title_style }},
        .{ .row_offset = 0, .col_offset = 0, .wrap = .none },
    );

    if (self.visible.items.len == 0) {
        _ = popup.print(
            &.{.{ .text = " (no outline in this document) ", .style = row_style }},
            .{ .row_offset = 2, .col_offset = 0 },
        );
        return;
    }

    const list_h: usize = if (h > 2) @intCast(h - 2) else 0;
    if (list_h == 0) return;

    if (!self.manual_top) {
        if (self.cursor < self.top) self.top = self.cursor;
        if (self.cursor >= self.top + list_h) self.top = self.cursor + 1 - list_h;
    }

    _ = self.draw_arena.reset(.retain_capacity);
    const a = self.draw_arena.allocator();

    var i: usize = 0;
    while (i < list_h and self.top + i < self.visible.items.len) : (i += 1) {
        const vi = self.top + i;
        const entry_idx = self.visible.items[vi];
        const e = self.entries[entry_idx];
        const style = if (vi == self.cursor) sel_style else row_style;
        const prefix_n: usize = @as(usize, e.depth) * 2;
        const prefix = a.alloc(u8, prefix_n) catch continue;
        @memset(prefix, ' ');
        const marker: []const u8 = if (self.hasChildren(entry_idx))
            (if (self.expanded.contains(entry_idx)) "\u{25BE} " else "\u{25B8} ")
        else
            "  ";
        const line = std.fmt.allocPrint(a, "{s}{s}{s}  (p.{d})", .{ prefix, marker, e.title, e.page + 1 }) catch continue;
        const row: u16 = @intCast(2 + i);
        _ = popup.print(
            &.{.{ .text = line, .style = style }},
            .{ .row_offset = row, .col_offset = 1, .wrap = .none },
        );
    }
}
