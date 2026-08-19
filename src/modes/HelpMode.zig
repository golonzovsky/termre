const Self = @This();
const std = @import("std");
const vaxis = @import("vaxis");
const Context = @import("../Context.zig").Context;
const Config = @import("../config/Config.zig");
const CommandMode = @import("CommandMode.zig");

pub const hides_page = true;

context: *Context,
draw_arena: std.heap.ArenaAllocator,

const Line = struct {
    header: bool = false,
    keys: []const u8 = "",
    label: []const u8 = "",
};

// Generated from CommandMode's dispatch table, so the help can't go stale.
const cmd_lines = blk: {
    var lines: [CommandMode.commands.len + 1]Line = undefined;
    lines[0] = .{ .header = true, .label = "Commands  (:)" };
    for (CommandMode.commands, 0..) |entry, i| {
        lines[i + 1] = .{ .keys = entry[1], .label = entry[2] };
    }
    break :blk lines;
};

pub fn init(context: *Context) Self {
    return .{
        .context = context,
        .draw_arena = std.heap.ArenaAllocator.init(context.allocator),
    };
}

pub fn deinit(self: *Self) void {
    self.draw_arena.deinit();
}

pub fn handleKeyStroke(self: *Self, key: vaxis.Key, km: Config.KeyMap) !void {
    _ = key;
    _ = km;
    self.context.changeMode(.view);
}

fn fmtKey(a: std.mem.Allocator, key: vaxis.Key) []const u8 {
    var buf: [16]u8 = undefined;
    var i: usize = 0;
    const put = struct {
        fn f(b: []u8, idx: usize, s: []const u8) usize {
            const n = @min(s.len, b.len - idx);
            @memcpy(b[idx .. idx + n], s[0..n]);
            return idx + n;
        }
    }.f;
    if (key.mods.ctrl) i = put(&buf, i, "C-");
    if (key.mods.alt) i = put(&buf, i, "M-");
    if (key.mods.super) i = put(&buf, i, "D-");

    const named: ?[]const u8 = switch (key.codepoint) {
        vaxis.Key.tab => "Tab",
        vaxis.Key.enter => "Enter",
        vaxis.Key.escape => "Esc",
        vaxis.Key.space => "Space",
        vaxis.Key.backspace => "Bksp",
        vaxis.Key.up => "Up",
        vaxis.Key.down => "Down",
        vaxis.Key.left => "Left",
        vaxis.Key.right => "Right",
        else => null,
    };
    if (named) |n| {
        i = put(&buf, i, n);
    } else {
        var cp: [4]u8 = undefined;
        const len = std.unicode.utf8Encode(key.codepoint, &cp) catch 0;
        i = put(&buf, i, cp[0..len]);
    }
    return a.dupe(u8, buf[0..i]) catch "";
}

fn buildKeyLines(self: *Self, a: std.mem.Allocator) []const Line {
    const km = self.context.config.key_map;
    var lines: std.ArrayList(Line) = .empty;
    const add = struct {
        fn f(alloc: std.mem.Allocator, list: *std.ArrayList(Line), line: Line) void {
            list.append(alloc, line) catch {};
        }
    }.f;
    const two = struct {
        fn f(alloc: std.mem.Allocator, x: []const u8, y: []const u8) []const u8 {
            return std.fmt.allocPrint(alloc, "{s} {s}", .{ x, y }) catch x;
        }
    }.f;

    add(a, &lines, .{ .header = true, .label = "Navigation" });
    add(a, &lines, .{ .keys = two(a, fmtKey(a, km.prev), fmtKey(a, km.next)), .label = "prev / next page" });
    add(a, &lines, .{ .keys = std.fmt.allocPrint(a, "{s} {s} {s} {s}", .{ fmtKey(a, km.scroll_left), fmtKey(a, km.scroll_down), fmtKey(a, km.scroll_up), fmtKey(a, km.scroll_right) }) catch "", .label = "scroll" });
    add(a, &lines, .{ .keys = two(a, fmtKey(a, km.scroll_half_down), fmtKey(a, km.scroll_half_up)), .label = "half-page down / up" });
    add(a, &lines, .{ .keys = two(a, fmtKey(a, km.jump_back), fmtKey(a, km.jump_forward)), .label = "jump back / forward" });

    add(a, &lines, .{ .header = true, .label = "View" });
    add(a, &lines, .{ .keys = two(a, fmtKey(a, km.zoom_in), fmtKey(a, km.zoom_out)), .label = "zoom in / out" });
    add(a, &lines, .{ .keys = fmtKey(a, km.width_mode), .label = "fit width (once)" });
    add(a, &lines, .{ .keys = fmtKey(a, km.fit_width), .label = "fit width (lock)" });
    add(a, &lines, .{ .keys = fmtKey(a, km.crop_to_content), .label = "crop to content" });
    add(a, &lines, .{ .keys = fmtKey(a, km.crop_mode), .label = "crop interactively" });
    add(a, &lines, .{ .keys = fmtKey(a, km.toggle_spread), .label = "2-column spread" });
    add(a, &lines, .{ .keys = fmtKey(a, km.full_screen), .label = "toggle status bar" });
    add(a, &lines, .{ .keys = fmtKey(a, km.colorize), .label = "toggle invert" });

    add(a, &lines, .{ .header = true, .label = "Search" });
    add(a, &lines, .{ .keys = fmtKey(a, km.search), .label = "search document" });
    add(a, &lines, .{ .keys = two(a, fmtKey(a, km.search_next), fmtKey(a, km.search_prev)), .label = "next / prev match" });
    add(a, &lines, .{ .keys = fmtKey(a, km.search_list), .label = "match list" });
    add(a, &lines, .{ .keys = fmtKey(a, km.exit_command_mode), .label = "clear highlights" });

    add(a, &lines, .{ .header = true, .label = "Mouse" });
    add(a, &lines, .{ .keys = "drag", .label = "select text, copy" });
    add(a, &lines, .{ .keys = "click", .label = "follow link" });
    add(a, &lines, .{ .keys = "wheel", .label = "scroll, C-: zoom" });

    add(a, &lines, .{ .header = true, .label = "Highlights" });
    add(a, &lines, .{ .keys = fmtKey(a, km.add_highlight), .label = "highlight selection" });
    add(a, &lines, .{ .keys = fmtKey(a, km.highlights_mode), .label = "highlights list" });

    add(a, &lines, .{ .header = true, .label = "Marks & contents" });
    add(a, &lines, .{ .keys = fmtKey(a, km.set_mark), .label = "set mark (a-z)" });
    add(a, &lines, .{ .keys = fmtKey(a, km.jump_mark), .label = "jump to mark (a-z)" });
    add(a, &lines, .{ .keys = fmtKey(a, km.marks_mode), .label = "marks list" });
    add(a, &lines, .{ .keys = fmtKey(a, km.toc_mode), .label = "table of contents" });
    add(a, &lines, .{ .keys = fmtKey(a, km.grid_mode), .label = "page grid" });

    add(a, &lines, .{ .header = true, .label = "Editor & links" });
    add(a, &lines, .{ .keys = fmtKey(a, km.open_in_editor), .label = "page in $EDITOR" });
    add(a, &lines, .{ .keys = fmtKey(a, km.open_chapter_in_editor), .label = "chapter in $EDITOR" });
    add(a, &lines, .{ .keys = fmtKey(a, km.hint_mode), .label = "follow link (hints)" });

    add(a, &lines, .{ .header = true, .label = "General" });
    add(a, &lines, .{ .keys = fmtKey(a, km.enter_command_mode), .label = "command mode" });
    add(a, &lines, .{ .keys = fmtKey(a, km.show_help), .label = "this help" });
    add(a, &lines, .{ .keys = fmtKey(a, km.quit), .label = "quit" });

    return lines.items;
}

// Widths derived from the table so new commands can't outgrow the layout.
const cmd_key_w: u16 = blk: {
    var m: usize = 0;
    for (cmd_lines) |l| m = @max(m, l.keys.len);
    break :blk @intCast(m + 2);
};
const cmd_label_w: u16 = blk: {
    var m: usize = 0;
    for (cmd_lines) |l| m = @max(m, l.label.len);
    break :blk @intCast(m);
};

fn drawColumn(popup: vaxis.Window, lines: []const Line, base_x: u16, key_w: u16, max_h: u16, bg: vaxis.Cell.Style, head: vaxis.Cell.Style, key_style: vaxis.Cell.Style) void {
    for (lines, 0..) |line, i| {
        const row: u16 = @intCast(i + 2);
        if (row >= max_h) break;
        if (line.header) {
            _ = popup.print(&.{.{ .text = line.label, .style = head }}, .{ .row_offset = row, .col_offset = base_x, .wrap = .none });
        } else {
            _ = popup.print(&.{.{ .text = line.keys, .style = key_style }}, .{ .row_offset = row, .col_offset = base_x + 1, .wrap = .none });
            _ = popup.print(&.{.{ .text = line.label, .style = bg }}, .{ .row_offset = row, .col_offset = base_x + key_w, .wrap = .none });
        }
    }
}

pub fn draw(self: *Self, win: vaxis.Window) void {
    _ = self.draw_arena.reset(.retain_capacity);
    const a = self.draw_arena.allocator();
    const key_lines = self.buildKeyLines(a);

    const right_base: u16 = 37;
    const w: u16 = @min(@as(u16, win.width -| 4), right_base + cmd_key_w + cmd_label_w + 1);
    const content_h: u16 = @intCast(@max(key_lines.len, cmd_lines.len) + 3);
    const max_h: u16 = @min(content_h, @as(u16, @intCast(@as(usize, win.height) -| 2)));
    const x_off = (win.width -| w) / 2;
    const y_off = (win.height -| max_h) / 2;

    const bg = vaxis.Cell.Style{
        .bg = .{ .rgb = .{ 30, 30, 40 } },
        .fg = .{ .rgb = .{ 230, 230, 230 } },
    };
    const head = vaxis.Cell.Style{
        .bg = .{ .rgb = .{ 30, 30, 40 } },
        .fg = .{ .rgb = .{ 130, 170, 255 } },
        .bold = true,
    };
    const key_style = vaxis.Cell.Style{
        .bg = .{ .rgb = .{ 30, 30, 40 } },
        .fg = .{ .rgb = .{ 230, 200, 110 } },
        .bold = true,
    };

    const popup = win.child(.{ .x_off = x_off, .y_off = y_off, .width = w, .height = max_h });
    popup.fill(.{ .char = .{ .grapheme = " ", .width = 1 }, .style = bg });

    _ = popup.print(
        &.{.{ .text = " Help — any key to close ", .style = head }},
        .{ .row_offset = 0, .col_offset = 1, .wrap = .none },
    );

    drawColumn(popup, key_lines, 1, 9, max_h, bg, head, key_style);
    if (w > right_base + 8) drawColumn(popup, &cmd_lines, right_base, cmd_key_w, max_h, bg, head, key_style);
}
