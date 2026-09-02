// External object store for reading-state shards. Keys are relative paths
// like `books/<key>/<device>.json`. Adding a backend = one file + one case.
const std = @import("std");

pub const DirStore = @import("DirStore.zig");
pub const S3Store = @import("S3Store.zig");

pub const Entry = struct {
    key: []const u8,
};

pub const Store = union(enum) {
    dir: DirStore,
    s3: S3Store,

    // Keys under `prefix` (which ends with '/'), allocated with `a`.
    pub fn list(self: *Store, a: std.mem.Allocator, prefix: []const u8) ![]Entry {
        switch (self.*) {
            inline else => |*s| return s.list(a, prefix),
        }
    }

    // null when the key does not exist.
    pub fn get(self: *Store, a: std.mem.Allocator, key: []const u8) !?[]u8 {
        switch (self.*) {
            inline else => |*s| return s.get(a, key),
        }
    }

    pub fn put(self: *Store, key: []const u8, data: []const u8) !void {
        switch (self.*) {
            inline else => |*s| return s.put(key, data),
        }
    }

    pub fn deinit(self: *Store) void {
        switch (self.*) {
            inline else => |*s| s.deinit(),
        }
    }

    pub fn name(self: *Store) []const u8 {
        return @tagName(self.*);
    }
};
