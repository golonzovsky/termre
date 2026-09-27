// kubkon/zig-yaml e5cf8ac (0.3.0), sources only: upstream's build.zig pulls in
// a spec-test helper that does not compile on Zig 0.16.
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    _ = b.addModule("yaml", .{
        .root_source_file = b.path("src/lib.zig"),
        .target = target,
        .optimize = optimize,
    });
}
