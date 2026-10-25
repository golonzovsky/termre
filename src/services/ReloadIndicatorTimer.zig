const Self = @This();
const std = @import("std");
const vaxis = @import("vaxis");
const Config = @import("../config/Config.zig");
const Event = @import("../Context.zig").Event;
const time = @import("../utilities/time.zig");

should_quit: std.atomic.Value(bool),
pending: std.atomic.Value(bool),
last_change_ns: std.atomic.Value(i64),
thread: ?std.Thread,
loop: ?*vaxis.Loop(Event),
reload_indicator_duration_ns: u64,
config: *Config,

pub fn init(config: *Config) Self {
    return .{
        .should_quit = .init(false),
        .pending = .init(false),
        .last_change_ns = .init(0),
        .thread = null,
        .loop = null,
        .reload_indicator_duration_ns = 0,
        .config = config,
    };
}

pub fn deinit(self: *Self) void {
    self.should_quit.store(true, .release);
    if (self.thread) |thread| {
        thread.join();
        self.thread = null;
    }
}

pub fn start(self: *Self, loop: ?*vaxis.Loop(Event)) !void {
    self.reload_indicator_duration_ns = @as(u64, @intFromFloat(@as(f32, self.config.file_monitor.reload_indicator_duration) * std.time.ns_per_s));
    self.loop = loop;
    self.last_change_ns.store(time.nowNs(), .release);

    if (self.thread == null) {
        self.thread = try std.Thread.spawn(.{}, run, .{self});
    }
}

fn run(self: *Self) void {
    const check_interval_ns: u64 = @max(self.reload_indicator_duration_ns / 4, std.time.ns_per_ms * 100);
    while (!self.should_quit.load(.acquire)) {
        time.sleep(check_interval_ns);
        if (!self.pending.load(.acquire)) continue;
        const elapsed = time.nowNs() - self.last_change_ns.load(.acquire);
        if (elapsed >= @as(i64, @intCast(self.reload_indicator_duration_ns))) {
            if (self.loop) |loop| loop.postEvent(.reload_done) catch {};
            self.pending.store(false, .release);
        }
    }
}

pub fn notifyChange(self: *Self) void {
    self.last_change_ns.store(time.nowNs(), .release);
    self.pending.store(true, .release);
}
