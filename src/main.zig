const std = @import("std");
const vaxis = @import("vaxis");
const Context = @import("Context.zig").Context;
const Positions = @import("services/Positions.zig");
const Config = @import("config/Config.zig");
const Sync = @import("services/Sync.zig");

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
            if (r.device.len > 0) {
                w.print("{d}\t{s}{s}  (p.{d}, on {s})\n", .{ i, prefix, shortenHome(r.path, home), r.page + 1, r.device }) catch break :feed;
            } else {
                w.print("{d}\t{s}{s}  (p.{d})\n", .{ i, prefix, shortenHome(r.path, home), r.page + 1 }) catch break :feed;
            }
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
        if (r.device.len > 0) {
            try stdout.print("  {d:>2}. {s}{s}  (p.{d}, on {s})\n", .{ i, prefix, shortenHome(r.path, home), r.page + 1, r.device });
        } else {
            try stdout.print("  {d:>2}. {s}{s}  (p.{d})\n", .{ i, prefix, shortenHome(r.path, home), r.page + 1 });
        }
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

    if (args.len >= 2 and std.mem.eql(u8, args[1], "state")) return stateCli(init, args[2..], stdout, stderr);

    if (args.len >= 2 and std.mem.eql(u8, args[1], "mcp")) {
        if (args.len == 2) return @import("mcp.zig").run(init);
        return @import("mcp.zig").cli(init, args[2..], stdout, stderr);
    }

    if (args.len > 3 or (args.len >= 2 and (std.mem.eql(u8, args[1], "--help") or std.mem.eql(u8, args[1], "-h")))) {
        try stderr.writeAll("Usage: re <path-to-pdf> <optional-page-number>\n       re                   (pick from recently opened)\n       re mcp               (MCP server over stdio for agents)\n");
        try stderr.flush();
        return;
    }

    var path: [:0]const u8 = undefined;
    var initial_page: ?u16 = null;
    if (args.len == 1) {
        const arena = init.arena.allocator();
        // Other devices' books appear in the picker only once their shards
        // are here; one listing fetches what's missing.
        {
            var config = Config.init(init.gpa, init.io, init.environ_map);
            defer config.deinit();
            if (Sync.storeFromConfig(init.gpa, init.io, init.environ_map, &config)) |store_val| {
                var store = store_val;
                defer store.deinit();
                if (Positions.booksDirFor(arena, init.environ_map)) |books| {
                    const device = Positions.deviceIdFor(arena, init.io, init.environ_map);
                    Sync.pullAll(init.gpa, init.io, &store, books, device) catch |err| {
                        try stderr.print("sync: {s}\n", .{@errorName(err)});
                        try stderr.flush();
                    };
                }
            }
        }
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
        if (recents[idx].device.len > 0) {
            try stderr.print("{s} is not on this machine (last read on {s})\n", .{ recents[idx].path, recents[idx].device });
            try stderr.flush();
            return;
        }
        path = try arena.dupeZ(u8, recents[idx].path);
    } else {
        path = args[1];
        if (args.len == 3) initial_page = std.fmt.parseInt(u16, args[2], 10) catch {
            try stderr.print("re: `{s}` is not a page number (run `re --help` for subcommands)\n", .{args[2]});
            try stderr.flush();
            std.process.exit(2);
        };
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

// `re state export [file]` / `re state import <file|->`: move reading state
// between machines by hand; import merges like sync does.
fn stateCli(init: std.process.Init, args: []const [:0]const u8, stdout: *std.Io.Writer, stderr: *std.Io.Writer) !void {
    const usage =
        \\usage: re state export [file]     write all reading state as JSON (stdout by default)
        \\       re state import <file|->   merge a state export into this machine (`-` = stdin)
        \\
    ;
    var wants_help = args.len == 0;
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) wants_help = true;
    }
    if (wants_help) {
        try stdout.writeAll(usage);
        try stdout.flush();
        return;
    }
    if (std.mem.eql(u8, args[0], "export")) {
        if (args.len >= 2) {
            var file = std.Io.Dir.cwd().createFile(init.io, args[1], .{}) catch |err| {
                try stderr.print("re state export: cannot write {s} ({s})\n", .{ args[1], @errorName(err) });
                try stderr.flush();
                std.process.exit(2);
            };
            defer file.close(init.io);
            var buf: [8192]u8 = undefined;
            var fw = file.writer(init.io, &buf);
            const stats = try Positions.exportAll(init.gpa, init.io, init.environ_map, &fw.interface);
            try fw.interface.flush();
            try stderr.print("exported {d} books ({d} device records) to {s}\n", .{ stats.books, stats.shards, args[1] });
        } else {
            _ = try Positions.exportAll(init.gpa, init.io, init.environ_map, stdout);
            try stdout.flush();
        }
        try stderr.flush();
        return;
    }
    if (std.mem.eql(u8, args[0], "import") and args.len >= 2) {
        const limit: std.Io.Limit = .limited(64 * 1024 * 1024);
        const json = if (std.mem.eql(u8, args[1], "-")) blk: {
            var rbuf: [8192]u8 = undefined;
            var r = std.Io.File.stdin().reader(init.io, &rbuf);
            break :blk try r.interface.allocRemaining(init.gpa, limit);
        } else std.Io.Dir.cwd().readFileAlloc(init.io, args[1], init.gpa, limit) catch |err| {
            try stderr.print("re state import: cannot read {s} ({s})\n", .{ args[1], @errorName(err) });
            try stderr.flush();
            std.process.exit(2);
        };
        defer init.gpa.free(json);
        const stats = Positions.importBundle(init.gpa, init.io, init.environ_map, json) catch |err| {
            try stderr.print("import failed: {s}\n", .{@errorName(err)});
            try stderr.flush();
            return;
        };
        try stderr.print("imported {d} books ({d} device records), merged with local state\n", .{ stats.books, stats.shards });
        try stderr.flush();
        return;
    }
    try stderr.writeAll(usage);
    try stderr.flush();
}
