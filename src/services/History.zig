const Self = @This();
const std = @import("std");
const Config = @import("../config/Config.zig");

allocator: std.mem.Allocator,
io: std.Io,
config: *Config,
items: std.ArrayList([]const u8),
index: isize,
path: []u8,

pub fn init(allocator: std.mem.Allocator, io: std.Io, env: *std.process.Environ.Map, config: *Config) Self {
    var self = Self{
        .allocator = allocator,
        .io = io,
        .config = config,
        .items = .empty,
        .index = -1,
        .path = "",
    };

    if (config.general.history <= 0) return self;

    const home = env.get("HOME") orelse return self;

    if (env.get("XDG_STATE_HOME")) |x| {
        self.path = std.fmt.allocPrint(allocator, "{s}/termre/history", .{x}) catch return self;
    } else self.path = std.fmt.allocPrint(allocator, "{s}/.local/state/termre/history", .{home}) catch return self;

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

    const cwd = std.Io.Dir.cwd();
    if (std.fs.path.dirname(self.path)) |dir| cwd.createDirPath(self.io, dir) catch {};
    var file = cwd.createFile(self.io, self.path, .{}) catch return;
    defer file.close(self.io);

    var buf: [4096]u8 = undefined;
    var fw = file.writer(self.io, &buf);
    const w = &fw.interface;
    for (self.items.items) |cmd| {
        w.writeAll(cmd) catch continue;
        w.writeAll("\n") catch continue;
    }
    w.flush() catch {};
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

    self.index = -1;
}
