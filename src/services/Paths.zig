// Where termre keeps its files, resolved once per process from the
// environment and config instead of re-deriving $XDG_STATE_HOME at every use.
const Self = @This();
const std = @import("std");
const Config = @import("../config/Config.zig");

state: []const u8,
books: []const u8,
open: []const u8,
history: []const u8,
downloads: []const u8,

pub fn init(a: std.mem.Allocator, env: *std.process.Environ.Map, config: *const Config) !Self {
    const home = env.get("HOME");
    const state = (try expand(a, home, config.state_dir)) orelse
        if (env.get("XDG_STATE_HOME")) |x| try std.fmt.allocPrint(a, "{s}/termre", .{x}) else if (home) |h| try std.fmt.allocPrint(a, "{s}/.local/state/termre", .{h}) else return error.NoStateDir;
    return .{
        .state = state,
        .books = try std.fmt.allocPrint(a, "{s}/books", .{state}),
        .open = try std.fmt.allocPrint(a, "{s}/open", .{state}),
        .history = try std.fmt.allocPrint(a, "{s}/history", .{state}),
        .downloads = (try expand(a, home, config.download_dir)) orelse try std.fmt.allocPrint(a, "{s}/downloads", .{state}),
    };
}

pub fn deinit(self: Self, a: std.mem.Allocator) void {
    a.free(self.state);
    a.free(self.books);
    a.free(self.open);
    a.free(self.history);
    a.free(self.downloads);
}

// A configured directory, with `~/` expanded; null when unset.
fn expand(a: std.mem.Allocator, home: ?[]const u8, dir: []const u8) !?[]const u8 {
    const d = std.mem.trimEnd(u8, dir, "/");
    if (d.len == 0) return null;
    if (std.mem.startsWith(u8, d, "~/")) return try std.fmt.allocPrint(a, "{s}/{s}", .{ home orelse return error.NoHome, d[2..] });
    return try a.dupe(u8, d);
}
