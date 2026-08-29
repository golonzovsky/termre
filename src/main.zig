const std = @import("std");
const vaxis = @import("vaxis");
const Context = @import("Context.zig").Context;
const Positions = @import("services/Positions.zig");

// Must live in the root file to take effect: restores the terminal (exits alt
// screen, disables mouse reporting) before printing a panic trace, so crashes
// don't leave the terminal broken with the trace hidden in the alt screen.
pub const panic = vaxis.panic_handler;

// Types for build.zig.zon
// For now metadata is only used in main.zig, but can move it to types.zig if needed eleswhere
// This wont be necessary once https://github.com/ziglang/zig/pull/22907 is merged

const PackageName = enum { termre };

const DependencyType = struct {
    url: []const u8,
    hash: []const u8,
};

const PathDependencyType = struct {
    path: []const u8,
};

const DependenciesType = struct {
    vaxis: DependencyType,
    fastb64z: DependencyType,
    fzwatch: PathDependencyType,
};

const MetadataType = struct {
    name: PackageName,
    fingerprint: u64,
    version: []const u8,
    minimum_zig_version: []const u8,
    dependencies: DependenciesType,
    paths: []const []const u8,
};

const metadata: MetadataType = @import("metadata");

fn shortenHome(path: []const u8, home: ?[]const u8) []const u8 {
    const h = home orelse return path;
    if (std.mem.startsWith(u8, path, h) and path.len > h.len and path[h.len] == '/') {
        return path[h.len + 1 ..];
    }
    return path;
}

// Lines are fed to fzf as "index<TAB>display"; the index column is hidden
// (--with-nth=2..) and parsed back from the selected line.
fn fzfPick(init: std.process.Init, recents: []const Positions.RecentEntry, home: ?[]const u8) !?usize {
    var child = std.process.spawn(init.io, .{
        .argv = &.{ "fzf", "--delimiter=\t", "--with-nth=2..", "--height=40%", "--reverse", "--prompt=open> " },
        .environ_map = init.environ_map,
        .stdin = .pipe,
        .stdout = .pipe,
    }) catch |err| switch (err) {
        error.FileNotFound => return error.FzfNotFound,
        else => return err,
    };

    feed: {
        var wbuf: [1024]u8 = undefined;
        var fzf_in = child.stdin.?.writer(init.io, &wbuf);
        const w = &fzf_in.interface;
        for (recents, 0..) |r, i| {
            const prefix: []const u8 = if (shortenHome(r.path, home).ptr != r.path.ptr) "~/" else "";
            w.print("{d}\t{s}{s}  (p.{d})\n", .{ i, prefix, shortenHome(r.path, home), r.page + 1 }) catch break :feed;
        }
        w.flush() catch {};
    }
    child.stdin.?.close(init.io);
    child.stdin = null;

    var rbuf: [4096]u8 = undefined;
    var fzf_out = child.stdout.?.reader(init.io, &rbuf);
    const choice: ?usize = blk: {
        const line = fzf_out.interface.takeDelimiterExclusive('\n') catch break :blk null;
        const tab = std.mem.indexOfScalar(u8, line, '\t') orelse break :blk null;
        break :blk std.fmt.parseInt(usize, line[0..tab], 10) catch null;
    };
    _ = child.wait(init.io) catch {};
    return choice;
}

// Numbered-list fallback for when fzf is not installed.
fn promptPick(init: std.process.Init, recents: []const Positions.RecentEntry, home: ?[]const u8, stdout: *std.Io.Writer) !?usize {
    const shown = @min(recents.len, 15);
    try stdout.writeAll("Recent:\n");
    for (recents[0..shown], 1..) |r, i| {
        const prefix: []const u8 = if (shortenHome(r.path, home).ptr != r.path.ptr) "~/" else "";
        try stdout.print("  {d:>2}. {s}{s}  (p.{d})\n", .{ i, prefix, shortenHome(r.path, home), r.page + 1 });
    }
    try stdout.print("open [1-{d}]: ", .{shown});
    try stdout.flush();

    var in_buf: [256]u8 = undefined;
    var stdin_reader = std.Io.File.stdin().reader(init.io, &in_buf);
    const line = stdin_reader.interface.takeDelimiterExclusive('\n') catch return null;
    const trimmed = std.mem.trim(u8, line, &std.ascii.whitespace);
    const choice: usize = if (trimmed.len == 0) 1 else std.fmt.parseInt(usize, trimmed, 10) catch return null;
    if (choice < 1 or choice > shown) return null;
    return choice - 1;
}

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());

    var stdout_buffer: [1024]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(init.io, &stdout_buffer);
    const stdout = &stdout_writer.interface;

    var stderr_buffer: [1024]u8 = undefined;
    var stderr_writer = std.Io.File.stderr().writer(init.io, &stderr_buffer);
    const stderr = &stderr_writer.interface;

    if (args.len == 2 and (std.mem.eql(u8, args[1], "--version") or std.mem.eql(u8, args[1], "-v"))) {
        try stdout.print("termre version {s}\n", .{metadata.version});
        try stdout.flush();
        return;
    }

    if (args.len > 3 or (args.len >= 2 and (std.mem.eql(u8, args[1], "--help") or std.mem.eql(u8, args[1], "-h")))) {
        try stderr.writeAll("Usage: re <path-to-pdf> <optional-page-number>\n       re                   (pick from recently opened)\n");
        try stderr.flush();
        return;
    }

    var path: [:0]const u8 = undefined;
    var initial_page: ?u16 = null;
    if (args.len == 1) {
        const arena = init.arena.allocator();
        const recents = Positions.listRecent(arena, init.io, init.environ_map);
        if (recents.len == 0) {
            try stderr.writeAll("Usage: re <path-to-pdf> <optional-page-number>\n");
            try stderr.flush();
            return;
        }
        const home = init.environ_map.get("HOME");
        const picked = fzfPick(init, recents, home) catch |err| switch (err) {
            error.FzfNotFound => try promptPick(init, recents, home, stdout),
            else => return err,
        };
        const idx = picked orelse return;
        path = try arena.dupeZ(u8, recents[idx].path);
    } else {
        path = args[1];
        if (args.len == 3) initial_page = try std.fmt.parseInt(u16, args[2], 10);
    }

    runApp(init, path, initial_page) catch |err| switch (err) {
        error.NoKittyGraphics => {
            try stderr.writeAll(no_graphics_msg);
            try stderr.flush();
            std.process.exit(1);
        },
        else => return err,
    };
}

// Deinit (which leaves the alt screen) must run before the message prints,
// or the terminal swallows it.
fn runApp(init: std.process.Init, path: [:0]const u8, initial_page: ?u16) !void {
    var app = try Context.init(init.gpa, init.io, init.environ_map, path, initial_page);
    defer app.deinit();
    try app.run();
}

const no_graphics_msg =
    \\re: this terminal did not answer the kitty graphics query, and termre needs the
    \\kitty graphics protocol to draw pages.
    \\
    \\Terminals that support it: Ghostty (any), kitty >= 0.19, WezTerm >= 20220319,
    \\Konsole >= 22.04. Multiplexers: zellij >= 0.45 (inside a supporting terminal),
    \\tmux >= 3.3 with `set -g allow-passthrough on`. Older zellij/tmux and
    \\Terminal.app, iTerm2, Alacritty, foot, VS Code's terminal do not support it.
    \\
;
