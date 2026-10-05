const Self = @This();
const std = @import("std");
const vaxis = @import("vaxis");
const Context = @import("../Context.zig").Context;
const Config = @import("../config/Config.zig");

pub const hides_page = true;

context: *Context,
cursor: usize,
top: usize,
// Non-null while the finder is collecting a query (no active search yet).
input: ?vaxis.widgets.TextInput,
no_matches: bool,
// Hit-line text is extracted lazily for visible rows only and kept for the
// mode's lifetime; "" is cached too so misses aren't re-extracted every draw.
lines: std.AutoHashMap(usize, []const u8),
arena: std.heap.ArenaAllocator,
draw_arena: std.heap.ArenaAllocator,

pub fn init(context: *Context) Self {
    return .{
        .context = context,
        .cursor = context.search_index,
        .top = 0,
        .input = if (context.search_hits.items.len == 0)
            vaxis.widgets.TextInput.init(context.allocator)
        else
            null,
        .no_matches = false,
        .lines = std.AutoHashMap(usize, []const u8).init(context.allocator),
        .arena = std.heap.ArenaAllocator.init(context.allocator),
        .draw_arena = std.heap.ArenaAllocator.init(context.allocator),
    };
}

pub fn deinit(self: *Self) void {
    if (self.input) |*ti| {
        self.context.vx.window().hideCursor();
        ti.deinit();
    }
    self.lines.deinit();
    self.arena.deinit();
    self.draw_arena.deinit();
}

fn lineFor(self: *Self, idx: usize) []const u8 {
    if (self.lines.get(idx)) |t| return t;
    const h = self.context.search_hits.items[idx];
    const cx = (h.x0 + h.x1) / 2;
    const cy = (h.y0 + h.y1) / 2;
    const raw = self.context.document_handler.lineTextAt(self.arena.allocator(), h.page, cx, cy) catch "";
    const text = std.mem.trim(u8, raw, &std.ascii.whitespace);
    self.lines.put(idx, text) catch {};
    return text;
}

pub fn handleKeyStroke(self: *Self, key: vaxis.Key, km: Config.KeyMap) !void {
    const ctx = self.context;

    if (self.input) |*ti| {
        if (key.matches(km.exit_command_mode.codepoint, km.exit_command_mode.mods)) {
            ctx.changeMode(.view);
            return;
        }
        if (key.matches(km.execute_command.codepoint, km.execute_command.mods)) {
            const text = try ti.buf.toOwnedSlice();
            defer ctx.allocator.free(text);
            const needle = std.mem.trim(u8, text, &std.ascii.whitespace);
            if (needle.len == 0) {
                ctx.changeMode(.view);
                return;
            }
            // toOwnedSlice freed the buffer that the popup's on-screen input
            // cells still reference; repaint the popup before runSearch's
            // progress flashes render the screen.
            self.draw(ctx.vx.window());
            ctx.runSearch(needle) catch {};
            if (ctx.search_hits.items.len > 0) {
                ctx.vx.window().hideCursor();
                ti.deinit();
                self.input = null;
                self.cursor = ctx.search_index;
                self.top = 0;
            } else {
                self.no_matches = true;
            }
            return;
        }
        try ti.update(.{ .key_press = key });
        return;
    }

    const hits = ctx.search_hits.items;
    if (key.matches(km.exit_command_mode.codepoint, km.exit_command_mode.mods) or
        key.matches(km.search_list.codepoint, km.search_list.mods) or
        hits.len == 0)
    {
        ctx.changeMode(.view);
        return;
    }
    if (key.matches(vaxis.Key.up, .{}) or key.matches('k', .{})) {
        if (self.cursor > 0) self.cursor -= 1;
        return;
    }
    if (key.matches(vaxis.Key.down, .{}) or key.matches('j', .{})) {
        if (self.cursor + 1 < hits.len) self.cursor += 1;
        return;
    }
    if (ctx.handleListHalfPage(key, &self.cursor, hits.len)) return;
    if (key.matches('g', .{})) {
        self.cursor = 0;
        return;
    }
    if (key.matches('G', .{})) {
        self.cursor = hits.len - 1;
        return;
    }
    if (key.matches(vaxis.Key.enter, .{})) {
        const idx = self.cursor;
        ctx.search_index = idx;
        ctx.changeMode(.view);
        ctx.gotoHit(idx);
        return;
    }
}

pub fn handleMouse(self: *Self, mouse: vaxis.Mouse) void {
    if (mouse.type != .press) return;
    const len = self.context.search_hits.items.len;
    if (len == 0) return;
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

pub fn draw(self: *Self, win: vaxis.Window) void {
    const input_bg = vaxis.Cell.Style{
        .bg = .{ .rgb = .{ 30, 30, 40 } },
        .fg = .{ .rgb = .{ 230, 230, 230 } },
    };
    if (self.input) |*ti| {
        const w: u16 = @min(@as(u16, win.width -| 4), 60);
        const x_off = (win.width -| w) / 2;
        const y_off = (win.height -| 3) / 2;
        const popup = win.child(.{ .x_off = x_off, .y_off = y_off, .width = w, .height = 3 });
        popup.fill(.{ .char = .{ .grapheme = " ", .width = 1 }, .style = input_bg });
        const title: []const u8 = if (self.no_matches)
            " Search — no matches (Esc: close) "
        else
            " Search document (Enter: run, Esc: close) ";
        _ = popup.print(&.{.{ .text = title, .style = input_bg }}, .{ .row_offset = 0, .col_offset = 1 });
        _ = popup.print(&.{.{ .text = "/", .style = input_bg }}, .{ .row_offset = 1, .col_offset = 1 });
        ti.draw(popup.child(.{ .x_off = 2, .y_off = 1, .width = w -| 3, .height = 1 }));
        return;
    }

    const hits = self.context.search_hits.items;
    const needle = self.context.search_needle;

    const row_count: u16 = @intCast(@min(@max(@as(usize, 3), hits.len + 2), 1000));
    const max_h: u16 = @min(row_count, @as(u16, @intCast(@as(usize, win.height) -| 2)));
    const w: u16 = @min(@as(u16, win.width -| 4), 120);
    const x_off = (win.width -| w) / 2;
    const y_off = (win.height -| max_h) / 2;

    const bg = vaxis.Cell.Style{
        .bg = .{ .rgb = .{ 30, 30, 40 } },
        .fg = .{ .rgb = .{ 230, 230, 230 } },
    };
    const sel = vaxis.Cell.Style{
        .bg = .{ .rgb = .{ 220, 20, 60 } },
        .fg = .{ .rgb = .{ 255, 255, 255 } },
        .bold = true,
    };
    const dim = vaxis.Cell.Style{
        .bg = .{ .rgb = .{ 30, 30, 40 } },
        .fg = .{ .rgb = .{ 150, 150, 160 } },
    };
    const match_style = vaxis.Cell.Style{
        .bg = .{ .rgb = .{ 30, 30, 40 } },
        .fg = .{ .rgb = .{ 230, 200, 110 } },
        .bold = true,
    };

    const popup = win.child(.{ .x_off = x_off, .y_off = y_off, .width = w, .height = max_h });
    popup.fill(.{ .char = .{ .grapheme = " ", .width = 1 }, .style = bg });

    _ = self.draw_arena.reset(.retain_capacity);
    const a = self.draw_arena.allocator();

    const title = std.fmt.allocPrint(
        a,
        " {d} matches for \"{s}\" (Enter: jump, Esc: close) ",
        .{ hits.len, needle },
    ) catch " Search matches ";
    _ = popup.print(&.{.{ .text = title, .style = bg }}, .{ .row_offset = 0, .col_offset = 1 });

    if (hits.len == 0) {
        _ = popup.print(
            &.{.{ .text = " (no matches) ", .style = dim }},
            .{ .row_offset = 1, .col_offset = 1 },
        );
        return;
    }

    const list_h: usize = if (max_h > 1) max_h - 1 else 0;
    if (list_h == 0) return;
    if (self.cursor < self.top) self.top = self.cursor;
    if (self.cursor >= self.top + list_h) self.top = self.cursor + 1 - list_h;

    var i: usize = 0;
    while (i < list_h and self.top + i < hits.len) : (i += 1) {
        const idx = self.top + i;
        const h = hits[idx];
        const row: u16 = @intCast(i + 1);
        const style = if (idx == self.cursor) sel else bg;

        const label = std.fmt.allocPrint(a, " p.{d:<4} ", .{h.page + 1}) catch continue;
        _ = popup.print(
            &.{.{ .text = label, .style = if (idx == self.cursor) sel else dim }},
            .{ .row_offset = row, .col_offset = 0 },
        );

        var line = self.lineFor(idx);
        const text_col: u16 = @intCast(@min(label.len, w));
        const avail: usize = w -| text_col;
        if (avail == 0) continue;

        // Keep the match visible when the line is wider than the popup.
        var match_pos = std.ascii.findIgnoreCase(line, needle);
        if (match_pos) |pos| {
            if (pos + needle.len > avail) {
                const shift = pos + needle.len - avail;
                line = line[@min(shift, line.len)..];
                match_pos = std.ascii.findIgnoreCase(line, needle);
            }
        }
        if (line.len > avail) line = line[0..avail];

        if (match_pos != null and match_pos.? + needle.len <= line.len and idx != self.cursor) {
            const pos = match_pos.?;
            _ = popup.print(&.{
                .{ .text = line[0..pos], .style = style },
                .{ .text = line[pos .. pos + needle.len], .style = match_style },
                .{ .text = line[pos + needle.len ..], .style = style },
            }, .{ .row_offset = row, .col_offset = text_col });
        } else {
            _ = popup.print(
                &.{.{ .text = line, .style = style }},
                .{ .row_offset = row, .col_offset = text_col },
            );
        }
    }
}
