const std = @import("std");

// Writes a pid-suffixed sibling and renames it over the target, so readers
// never see a torn file and two processes don't truncate each other's temp.
pub fn writeFileAtomic(io: std.Io, path: []const u8, data: []const u8) !void {
    var tmp_buf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp = try std.fmt.bufPrint(&tmp_buf, "{s}.{d}.tmp", .{ path, std.c.getpid() });
    const cwd = std.Io.Dir.cwd();
    if (std.fs.path.dirname(path)) |d| try cwd.createDirPath(io, d);
    {
        var file = try cwd.createFile(io, tmp, .{});
        defer file.close(io);
        var buf: [8192]u8 = undefined;
        var fw = file.writer(io, &buf);
        try fw.interface.writeAll(data);
        try fw.interface.flush();
    }
    try std.Io.Dir.renameAbsolute(tmp, path, io);
}
