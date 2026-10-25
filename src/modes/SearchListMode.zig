const Self = @This();
const std = @import("std");
const vaxis = @import("vaxis");
const Context = @import("../Context.zig").Context;
const Config = @import("../config/Config.zig");
const CommandMode = @import("CommandMode.zig");
const ListView = @import("ListView.zig");
const theme = ListView.theme;

pub const hides_page = true;

context: *Context,
list: ListView,
// Non-null while the finder is collecting a query (no active search yet).
input: ?vaxis.widgets.TextInput,
no_matches: bool,
// Hit-line text is extracted lazily for visible rows only and kept for the
// mode's lifetime; "" is cached too so misses aren't re-extracted every draw.
lines: std.AutoHashMap(usize, []const u8),
arena: std.heap.ArenaAllocator,

pub fn init(context: *Context) Self {
    return .{
        .context = context,
        .list = .{ .cursor = context.search_index },
        .input = if (context.search_hits.items.len == 0)
            vaxis.widgets.TextInput.init(context.allocator)
        else
            null,
        .no_matches = false,
        .lines = std.AutoHashMap(usize, []const u8).init(context.allocator),
        .arena = std.heap.ArenaAllocator.init(context.allocator),
    };
}

pub fn deinit(self: *Self) void {
    if (self.input) |*ti| CommandMode.closeTextInput(self.context, ti);
    self.lines.deinit();
    self.arena.deinit();
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
                CommandMode.closeTextInput(ctx, ti);
                self.input = null;
                self.list = .{ .cursor = ctx.search_index };
            } else {
                self.no_matches = true;
            }
            return;
        }
        try ti.update(.{ .key_press = key });
        return;
    }

    const hits = ctx.search_hits.items;
    if (key.matches(km.search_list.codepoint, km.search_list.mods)) {
        ctx.changeMode(.view);
        return;
    }
    switch (self.list.handleKey(ctx, key, km, hits.len)) {
        .close => ctx.changeMode(.view),
        .confirm => {
            const idx = self.list.cursor;
            ctx.search_index = idx;
            ctx.changeMode(.view);
            ctx.gotoHit(idx);
        },
        .moved, .none => {},
    }
}

pub fn handleMouse(self: *Self, mouse: vaxis.Mouse) void {
    self.list.handleWheel(mouse, self.context.search_hits.items.len);
}

pub fn draw(self: *Self, win: vaxis.Window) void {
    const input_bg = theme.bg;
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

    const popup = ListView.layout(win, hits.len, 120);
    const w = popup.win.width;

    const a = self.context.frameAlloc();

    const title = std.fmt.allocPrint(
        a,
        " {d} matches for \"{s}\" (Enter: jump, Esc: close) ",
        .{ hits.len, needle },
    ) catch " Search matches ";
    popup.title(title, theme.bg);

    if (hits.len == 0) {
        _ = popup.win.print(
            &.{.{ .text = " (no matches) ", .style = theme.dim }},
            .{ .row_offset = 1, .col_offset = 1 },
        );
        return;
    }

    var it = popup.rows(&self.list, hits.len);
    while (it.next()) |r| {
        const idx = r.idx;
        const row = r.row;
        const h = hits[idx];
        const style = if (r.selected) theme.sel else theme.bg;

        const label = std.fmt.allocPrint(a, " p.{d:<4} ", .{h.page + 1}) catch continue;
        _ = popup.win.print(
            &.{.{ .text = label, .style = if (r.selected) theme.sel else theme.dim }},
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

        if (match_pos != null and match_pos.? + needle.len <= line.len and !r.selected) {
            const pos = match_pos.?;
            _ = popup.win.print(&.{
                .{ .text = line[0..pos], .style = style },
                .{ .text = line[pos .. pos + needle.len], .style = theme.accent_bold },
                .{ .text = line[pos + needle.len ..], .style = style },
            }, .{ .row_offset = row, .col_offset = text_col });
        } else {
            _ = popup.win.print(
                &.{.{ .text = line, .style = style }},
                .{ .row_offset = row, .col_offset = text_col },
            );
        }
    }
}
