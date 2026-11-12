const std = @import("std");

// Writes a pid-suffixed sibling and renames it over the target, so readers
// never see a torn file and two processes don't truncate each other's temp.
pub fn writeFileAtomic(io: std.Io, path: []const u8, data: []const u8) !void {
    var tmp_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp = try std.fmt.bufPrint(&tmp_buf, "{s}.{d}.tmp", .{ path, std.c.getpid() });
    const cwd = std.Io.Dir.cwd();
    if (std.fs.path.dirname(path)) |d| try cwd.createDirPath(io, d);
    errdefer cwd.deleteFile(io, tmp) catch {};
    {
        var file = try cwd.createFile(io, tmp, .{});
        defer file.close(io);
        var buf: [8192]u8 = undefined;
        var fw = file.writer(io, &buf);
        try fw.interface.writeAll(data);
        try fw.interface.flush();
    }
    try cwd.rename(tmp, cwd, path, io);
}

// A single directory entry name: safe to join under a parent directory.
pub fn isPathComponent(name: []const u8) bool {
    if (name.len == 0 or std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) return false;
    return std.mem.indexOfAny(u8, name, "/\\\x00") == null;
}

test "isPathComponent rejects empty, dot names and separators" {
    const testing = std.testing;
    try testing.expect(isPathComponent("pdf-id_abc"));
    try testing.expect(isPathComponent("..hidden"));
    for ([_][]const u8{ "", ".", "..", "a/b", "/", "../x", "a\\b" }) |bad| try testing.expect(!isPathComponent(bad));
}

test "writeFileAtomic: replaces the target, leaves no temp file, works in a nested dir" {
    const testing = std.testing;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const io = testing.io;
    const root = try tmp.dir.realPathFileAlloc(io, ".", testing.allocator);
    defer testing.allocator.free(root);
    const path = try std.fmt.allocPrint(testing.allocator, "{s}/a/b/file.json", .{root});
    defer testing.allocator.free(path);

    try writeFileAtomic(io, path, "one");
    try writeFileAtomic(io, path, "two");
    const got = try std.Io.Dir.cwd().readFileAlloc(io, path, testing.allocator, .limited(64));
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("two", got);

    var dir = try tmp.dir.openDir(io, "a/b", .{ .iterate = true });
    defer dir.close(io);
    var it = dir.iterate();
    var n: usize = 0;
    while (try it.next(io)) |_| n += 1;
    try testing.expectEqual(@as(usize, 1), n);
}
