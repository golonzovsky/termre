const Self = @This();
const std = @import("std");
const vaxis = @import("vaxis");
const Context = @import("../Context.zig").Context;
const Config = @import("../config/Config.zig");
const PdfHandler = @import("../handlers/PdfHandler.zig");
const ListView = @import("ListView.zig");
const theme = ListView.theme;

pub const hides_page = true;

context: *Context,
list: ListView,
outline: []const PdfHandler.OutlineEntry,

pub fn init(context: *Context) Self {
    const outline: []const PdfHandler.OutlineEntry =
        context.document_handler.loadOutline(context.allocator) catch &.{};
    return .{
        .context = context,
        .list = .{},
        .outline = outline,
    };
}

pub fn deinit(self: *Self) void {
    if (self.outline.len > 0) {
        for (self.outline) |e| self.context.allocator.free(e.title);
        self.context.allocator.free(self.outline);
    }
}

fn sectionFor(self: *const Self, page: u16) []const u8 {
    var title: []const u8 = "";
    for (self.outline) |e| {
        if (e.page > page) break;
        title = e.title;
    }
    return title;
}

pub fn handleKeyStroke(self: *Self, key: vaxis.Key, km: Config.KeyMap) !void {
    const ctx = self.context;
    const marks = ctx.marks.items;
    if (key.matches(km.marks_mode.codepoint, km.marks_mode.mods)) {
        ctx.changeMode(.view);
        return;
    }
    switch (self.list.handleKey(ctx, key, km, marks.len)) {
        .close => {
            ctx.changeMode(.view);
            return;
        },
        .moved => return,
        .confirm => {
            const m = marks[self.list.cursor];
            ctx.changeMode(.view);
            ctx.jumpToMark(m.letter);
            return;
        },
        .none => {},
    }
    if (key.matches(km.list_delete.codepoint, km.list_delete.mods)) {
        ctx.deleteMark(marks[self.list.cursor].letter);
        if (!self.list.clampAfterRemove(ctx.marks.items.len)) ctx.changeMode(.view);
        return;
    }
    if (key.matches(km.list_edit.codepoint, km.list_edit.mods)) {
        const m = marks[self.list.cursor];
        var buf: [256]u8 = undefined;
        const prefilled = std.fmt.bufPrint(&buf, "mark {c} {s}", .{ m.letter, m.comment }) catch return;
        ctx.enterCommandWithText(prefilled);
        return;
    }
    if (key.codepoint >= 'a' and key.codepoint <= 'z') {
        const letter: u8 = @intCast(key.codepoint);
        for (marks) |m| {
            if (m.letter == letter) {
                ctx.changeMode(.view);
                ctx.jumpToMark(letter);
                return;
            }
        }
    }
}

pub fn handleMouse(self: *Self, mouse: vaxis.Mouse) void {
    self.list.handleWheel(mouse, self.context.marks.items.len);
}

pub fn draw(self: *Self, win: vaxis.Window) void {
    const marks = self.context.marks.items;
    const popup = ListView.layout(win, marks.len, 120);
    const w = popup.win.width;
    popup.title(" Marks (Enter: jump, r: rename, d: delete, Esc: close) ", theme.bg);

    const a = self.context.frameAlloc();

    var it = popup.rows(&self.list, marks.len);
    while (it.next()) |r| {
        const m = marks[r.idx];
        const style = if (r.selected) theme.sel else theme.bg;
        const section = self.sectionFor(m.page);
        const label = std.fmt.allocPrint(a, " {c}  p.{d:<4}  ", .{ m.letter, m.page + 1 }) catch continue;
        _ = popup.win.print(
            &.{.{ .text = label, .style = style }},
            .{ .row_offset = r.row, .col_offset = 0 },
        );

        const main_col: u16 = @intCast(@min(label.len, w));
        if (m.comment.len > 0) {
            _ = popup.win.print(
                &.{.{ .text = m.comment, .style = style }},
                .{ .row_offset = r.row, .col_offset = main_col, .wrap = .none },
            );
            if (section.len > 0) {
                const sep = std.fmt.allocPrint(a, "  - {s}", .{section}) catch section;
                _ = popup.win.print(
                    &.{.{ .text = sep, .style = if (r.selected) theme.sel else theme.dim }},
                    .{ .row_offset = r.row, .col_offset = @intCast(@min(@as(usize, main_col) + m.comment.len, w)), .wrap = .none },
                );
            }
        } else if (section.len > 0) {
            _ = popup.win.print(
                &.{.{ .text = section, .style = if (r.selected) theme.sel else theme.dim }},
                .{ .row_offset = r.row, .col_offset = main_col, .wrap = .none },
            );
        }
    }
}
