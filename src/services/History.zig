const Self = @This();
const std = @import("std");
const fs = @import("../utilities/fs.zig");
const Config = @import("../config/Config.zig");
const Paths = @import("Paths.zig");

allocator: std.mem.Allocator,
io: std.Io,
config: *Config,
items: std.ArrayList([]const u8),
path: []u8,

pub fn init(allocator: std.mem.Allocator, io: std.Io, paths: Paths, config: *Config) Self {
    var self = Self{
        .allocator = allocator,
        .io = io,
        .config = config,
        .items = .empty,
        .path = "",
    };

    if (config.general.history <= 0) return self;
    self.path = allocator.dupe(u8, paths.history) catch return self;

    const cwd = std.Io.Dir.cwd();
    const content = cwd.readFileAlloc(io, self.path, allocator, .limited(1024 * 1024)) catch return self;
    defer allocator.free(content);

    var line = std.mem.tokenizeScalar(u8, content, '\n');
    while (line.next()) |cmd| {
        const cmd_copy = allocator.dupe(u8, cmd) catch continue;
        self.items.append(allocator, cmd_copy) catch {
            allocator.free(cmd_copy);
            continue;
        };
    }

    return self;
}

pub fn deinit(self: *Self) void {
    if (self.config.general.history <= 0) return;

    defer {
        for (self.items.items) |entry| self.allocator.free(entry);
        self.items.deinit(self.allocator);
        if (self.path.len > 0) self.allocator.free(self.path);
    }

    if (self.path.len == 0) return;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(self.allocator);
    for (self.items.items) |cmd| {
        out.appendSlice(self.allocator, cmd) catch return;
        out.append(self.allocator, '\n') catch return;
    }
    fs.writeFileAtomic(self.io, self.path, out.items) catch {};
}

pub fn addToHistory(self: *Self, cmd: []const u8) void {
    if (self.config.general.history <= 0) return;

    for (self.items.items, 0..) |existing_cmd, i| {
        if (std.mem.eql(u8, existing_cmd, cmd)) {
            self.allocator.free(self.items.orderedRemove(i));
            break;
        }
    }

    const cmd_copy = self.allocator.dupe(u8, cmd) catch return;
    self.items.append(self.allocator, cmd_copy) catch {
        self.allocator.free(cmd_copy);
        return;
    };

    const max: usize = self.config.general.history;
    while (self.items.items.len > max) {
        const removed = self.items.orderedRemove(0);
        self.allocator.free(removed);
    }
}
