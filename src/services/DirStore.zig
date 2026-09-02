// A plain directory as the store: anything that syncs a folder (Syncthing,
// iCloud/Dropbox, rsync, an SSHFS mount) becomes a backend, and it is what
// the sync engine is tested against.
const Self = @This();
const std = @import("std");
const Entry = @import("Store.zig").Entry;

io: std.Io,
root: []const u8,

pub fn init(io: std.Io, root: []const u8) Self {
    return .{ .io = io, .root = root };
}

pub fn deinit(_: *Self) void {}

// Recursive, like an object-store listing.
pub fn list(self: *Self, a: std.mem.Allocator, prefix: []const u8) ![]Entry {
    var out: std.ArrayList(Entry) = .empty;
    try self.listInto(a, &out, prefix);
    return out.toOwnedSlice(a);
}

fn listInto(self: *Self, a: std.mem.Allocator, out: *std.ArrayList(Entry), prefix: []const u8) !void {
    const dir_path = try std.fmt.allocPrint(a, "{s}/{s}", .{ self.root, prefix });
    var dir = std.Io.Dir.cwd().openDir(self.io, dir_path, .{ .iterate = true }) catch return;
    defer dir.close(self.io);
    var it = dir.iterate();
    while (it.next(self.io) catch null) |entry| {
        const key = try std.fmt.allocPrint(a, "{s}{s}", .{ prefix, entry.name });
        switch (entry.kind) {
            .file => try out.append(a, .{ .key = key }),
            .directory => try self.listInto(a, out, try std.fmt.allocPrint(a, "{s}/", .{key})),
            else => {},
        }
    }
}

pub fn get(self: *Self, a: std.mem.Allocator, key: []const u8) !?[]u8 {
    const path = try std.fmt.allocPrint(a, "{s}/{s}", .{ self.root, key });
    defer a.free(path);
    return std.Io.Dir.cwd().readFileAlloc(self.io, path, a, .limited(4 * 1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => null,
        else => err,
    };
}

pub fn put(self: *Self, key: []const u8, data: []const u8) !void {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    var buf2: [std.fs.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(&buf, "{s}/{s}", .{ self.root, key });
    const tmp = try std.fmt.bufPrint(&buf2, "{s}.tmp", .{path});
    const cwd = std.Io.Dir.cwd();
    if (std.fs.path.dirname(path)) |d| try cwd.createDirPath(self.io, d);
    {
        var file = try cwd.createFile(self.io, tmp, .{});
        defer file.close(self.io);
        var wbuf: [4096]u8 = undefined;
        var fw = file.writer(self.io, &wbuf);
        try fw.interface.writeAll(data);
        try fw.interface.flush();
    }
    try std.Io.Dir.renameAbsolute(tmp, path, self.io);
}
