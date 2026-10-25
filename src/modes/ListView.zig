// Cursor/scroll state and the shared popup chrome of the list modes
// (marks, highlights, search list, TOC, help). Per-row rendering and the
// action keys stay in each mode.
const Self = @This();
const std = @import("std");
const vaxis = @import("vaxis");
const Context = @import("../Context.zig").Context;
const Config = @import("../config/Config.zig");

cursor: usize = 0,
top: usize = 0,

pub const Action = enum { none, moved, confirm, close };

pub const theme = struct {
    pub const bg = vaxis.Cell.Style{
        .bg = .{ .rgb = .{ 30, 30, 40 } },
        .fg = .{ .rgb = .{ 230, 230, 230 } },
    };
    pub const sel = vaxis.Cell.Style{
        .bg = .{ .rgb = .{ 220, 20, 60 } },
        .fg = .{ .rgb = .{ 255, 255, 255 } },
        .bold = true,
    };
    pub const dim = vaxis.Cell.Style{
        .bg = .{ .rgb = .{ 30, 30, 40 } },
        .fg = .{ .rgb = .{ 150, 150, 160 } },
    };
    pub const accent = vaxis.Cell.Style{
        .bg = .{ .rgb = .{ 30, 30, 40 } },
        .fg = .{ .rgb = .{ 230, 200, 110 } },
    };
    pub const accent_bold = vaxis.Cell.Style{
        .bg = .{ .rgb = .{ 30, 30, 40 } },
        .fg = .{ .rgb = .{ 230, 200, 110 } },
        .bold = true,
    };
    pub const head = vaxis.Cell.Style{
        .bg = .{ .rgb = .{ 30, 30, 40 } },
        .fg = .{ .rgb = .{ 130, 170, 255 } },
        .bold = true,
    };
};

// Callers handle their own toggle key first; `len == 0` closes on any key.
pub fn handleKey(self: *Self, ctx: *Context, key: vaxis.Key, km: Config.KeyMap, len: usize) Action {
    if (key.matches(km.exit_command_mode.codepoint, km.exit_command_mode.mods) or len == 0) return .close;
    if (key.matches(vaxis.Key.up, .{}) or key.matches(km.scroll_up.codepoint, km.scroll_up.mods)) {
        if (self.cursor > 0) self.cursor -= 1;
        return .moved;
    }
    if (key.matches(vaxis.Key.down, .{}) or key.matches(km.scroll_down.codepoint, km.scroll_down.mods)) {
        if (self.cursor + 1 < len) self.cursor += 1;
        return .moved;
    }
    if (ctx.handleListHalfPage(key, &self.cursor, len)) return .moved;
    if (key.matches(km.list_top.codepoint, km.list_top.mods)) {
        self.cursor = 0;
        return .moved;
    }
    if (key.matches(km.list_bottom.codepoint, km.list_bottom.mods)) {
        self.cursor = len - 1;
        return .moved;
    }
    if (key.matches(km.list_select.codepoint, km.list_select.mods)) return .confirm;
    return .none;
}

pub fn handleWheel(self: *Self, mouse: vaxis.Mouse, len: usize) void {
    if (mouse.type != .press or len == 0) return;
    switch (mouse.button) {
        .wheel_up => if (self.cursor > 0) {
            self.cursor -= 1;
        },
        .wheel_down => if (self.cursor + 1 < len) {
            self.cursor += 1;
        },
        else => {},
    }
}

// False when the list emptied (caller closes).
pub fn clampAfterRemove(self: *Self, len: usize) bool {
    if (len == 0) return false;
    if (self.cursor >= len) self.cursor = len - 1;
    return true;
}

pub fn scrollToCursor(self: *Self, list_h: usize) void {
    if (self.cursor < self.top) self.top = self.cursor;
    if (self.cursor >= self.top + list_h) self.top = self.cursor + 1 - list_h;
}

pub const Row = struct { row: u16, idx: usize, selected: bool };

pub const Rows = struct {
    top: usize,
    cursor: usize,
    len: usize,
    list_h: usize,
    first_row: u16,
    i: usize = 0,

    pub fn next(it: *Rows) ?Row {
        if (it.i >= it.list_h or it.top + it.i >= it.len) return null;
        const idx = it.top + it.i;
        const row: u16 = @intCast(it.first_row + it.i);
        it.i += 1;
        return .{ .row = row, .idx = idx, .selected = idx == it.cursor };
    }
};

pub fn rows(self: *const Self, len: usize, list_h: usize, first_row: u16) Rows {
    return .{ .top = self.top, .cursor = self.cursor, .len = len, .list_h = list_h, .first_row = first_row };
}

pub const Popup = struct {
    win: vaxis.Window,
    list_h: usize,

    pub fn title(p: Popup, text: []const u8, style: vaxis.Cell.Style) void {
        _ = p.win.print(&.{.{ .text = text, .style = style }}, .{ .row_offset = 0, .col_offset = 1, .wrap = .none });
    }

    pub fn rows(p: Popup, view: *Self, len: usize) Rows {
        view.scrollToCursor(p.list_h);
        return view.rows(len, p.list_h, 1);
    }
};

// Centered, filled popup sized for `content_rows` under a title row (min 3 tall).
pub fn layout(win: vaxis.Window, content_rows: usize, max_w: u16) Popup {
    const row_count: u16 = @intCast(@min(@max(@as(usize, 3), content_rows + 2), 1000));
    const h: u16 = @min(row_count, @as(u16, @intCast(@as(usize, win.height) -| 2)));
    const w: u16 = @min(@as(u16, win.width -| 4), max_w);
    const popup = win.child(.{ .x_off = (win.width -| w) / 2, .y_off = (win.height -| h) / 2, .width = w, .height = h });
    popup.fill(.{ .char = .{ .grapheme = " ", .width = 1 }, .style = theme.bg });
    return .{ .win = popup, .list_h = h -| 1 };
}
