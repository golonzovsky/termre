const Self = @This();
const std = @import("std");
const vaxis = @import("vaxis");
const Context = @import("../Context.zig").Context;
const Config = @import("../config/Config.zig");
const CommandMode = @import("CommandMode.zig");

pub const occupies_bottom_row = true;
const TextInput = vaxis.widgets.TextInput;

context: *Context,
text_input: TextInput,

pub fn init(context: *Context) Self {
    return .{
        .context = context,
        .text_input = TextInput.init(context.allocator),
    };
}

pub fn deinit(self: *Self) void {
    CommandMode.closeTextInput(self.context, &self.text_input);
}

pub fn handleKeyStroke(self: *Self, key: vaxis.Key, km: Config.KeyMap) !void {
    if (key.matches(km.exit_command_mode.codepoint, km.exit_command_mode.mods) or
        (key.matches(vaxis.Key.backspace, .{}) and self.text_input.buf.realLength() == 0))
    {
        self.context.changeMode(.view);
        return;
    }

    if (key.matches(km.execute_command.codepoint, km.execute_command.mods)) {
        const ctx = self.context;
        const text = try self.text_input.buf.toOwnedSlice();
        defer ctx.allocator.free(text);
        const needle = std.mem.trim(u8, text, &std.ascii.whitespace);

        // changeMode deinits this mode, so only touch `ctx` from here on.
        ctx.changeMode(.view);
        if (needle.len == 0) {
            ctx.clearSearch();
        } else {
            ctx.runSearch(needle) catch {};
        }
        return;
    }

    try self.text_input.update(.{ .key_press = key });
}

pub fn drawSearchBar(self: *Self, win: vaxis.Window) void {
    const search_bar = win.child(.{
        .x_off = 0,
        .y_off = win.height -| 1,
        .width = win.width,
        .height = 1,
    });
    _ = search_bar.print(&.{.{ .text = "/" }}, .{ .col_offset = 0 });

    self.text_input.draw(search_bar.child(.{ .x_off = 1 }));
}
