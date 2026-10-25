const Self = @This();
const std = @import("std");
const vaxis = @import("vaxis");
const Context = @import("../Context.zig").Context;
const Config = @import("../config/Config.zig");
const Selection = @import("../Selection.zig");
const ListView = @import("ListView.zig");
const theme = ListView.theme;

pub const hides_page = true;

context: *Context,
list: ListView,

pub fn init(context: *Context) Self {
    return .{
        .context = context,
        .list = .{},
    };
}

pub fn deinit(_: *Self) void {}

pub fn handleKeyStroke(self: *Self, key: vaxis.Key, km: Config.KeyMap) !void {
    const ctx = self.context;
    const items = ctx.highlights.items;
    if (key.matches(km.highlights_mode.codepoint, km.highlights_mode.mods)) {
        ctx.changeMode(.view);
        return;
    }
    switch (self.list.handleKey(ctx, key, km, items.len)) {
        .close => {
            ctx.changeMode(.view);
            return;
        },
        .moved => return,
        .confirm => {
            const idx = self.list.cursor;
            ctx.changeMode(.view);
            Selection.jumpToHighlight(ctx, idx);
            return;
        },
        .none => {},
    }
    if (key.matches(km.list_delete.codepoint, km.list_delete.mods)) {
        Selection.deleteHighlight(ctx, self.list.cursor);
        if (!self.list.clampAfterRemove(ctx.highlights.items.len)) ctx.changeMode(.view);
        return;
    }
}

pub fn handleMouse(self: *Self, mouse: vaxis.Mouse) void {
    self.list.handleWheel(mouse, self.context.highlights.items.len);
}

pub fn draw(self: *Self, win: vaxis.Window) void {
    const items = self.context.highlights.items;
    const popup = ListView.layout(win, items.len, 120);
    const w = popup.win.width;
    popup.title(" Highlights (Enter: jump, d: delete, Esc: close) ", theme.bg);

    if (items.len == 0) {
        _ = popup.win.print(
            &.{.{ .text = " (no highlights — select text, then H) ", .style = theme.dim }},
            .{ .row_offset = 1, .col_offset = 1 },
        );
        return;
    }

    const a = self.context.frameAlloc();

    var it = popup.rows(&self.list, items.len);
    while (it.next()) |r| {
        const h = items[r.idx];
        const style = if (r.selected) theme.sel else theme.bg;

        const label = std.fmt.allocPrint(a, " p.{d:<4} ", .{h.page + 1}) catch continue;
        _ = popup.win.print(
            &.{.{ .text = label, .style = if (r.selected) theme.sel else theme.accent }},
            .{ .row_offset = r.row, .col_offset = 0 },
        );

        const text_col: u16 = @intCast(@min(label.len, w));
        const avail: usize = w -| text_col;
        if (avail == 0) continue;
        var text = std.mem.trim(u8, h.text, &std.ascii.whitespace);
        if (text.len > avail) text = text[0..avail];
        const flat = std.mem.join(a, " ", blk: {
            var parts: std.ArrayList([]const u8) = .empty;
            var it_lines = std.mem.tokenizeAny(u8, text, "\r\n");
            while (it_lines.next()) |t| parts.append(a, t) catch break;
            break :blk parts.items;
        }) catch text;
        _ = popup.win.print(
            &.{.{ .text = flat, .style = style }},
            .{ .row_offset = r.row, .col_offset = text_col },
        );
    }
}
