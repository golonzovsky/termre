const std = @import("std");
const vaxis = @import("vaxis");
const Context = @import("Context.zig").Context;
const NextBook = @import("Context.zig").NextBook;
const Positions = @import("services/Positions.zig");
const Config = @import("config/Config.zig");
const Sync = @import("services/Sync.zig");
const Paths = @import("services/Paths.zig");
const fs = @import("utilities/fs.zig");

// Must live in the root file to take effect: restores the terminal (exits alt
// screen, disables mouse reporting) before printing a panic trace, so crashes
// don't leave the terminal broken with the trace hidden in the alt screen.
pub const panic = vaxis.panic_handler;

// Dependencies (vaxis, zig-yaml) log at debug level; keep the tty clean.
pub const std_options: std.Options = .{ .log_level = .warn };

const metadata = @import("metadata");

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
    run(init) catch |err| {
        var buf: [256]u8 = undefined;
        var w = std.Io.File.stderr().writer(init.io, &buf);
        switch (err) {
            // PdfHandler already printed MuPDF's reason.
            error.FailedToOpenDocument => {},
            else => w.interface.print("re: {s}\n", .{@errorName(err)}) catch {},
        }
        w.interface.flush() catch {};
        std.process.exit(1);
    };
}

fn run(init: std.process.Init) !void {
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
        try stderr.writeAll(
            \\Usage: re <path-to-pdf | url> [page]   urls (incl. arxiv abs/html) are downloaded once
            \\       re                          pick from recently opened
            \\       re mcp                      MCP server over stdio for agents
            \\       re mcp install claude|codex register it there and install the termre skill
            \\       re mcp config | skill       print the server snippet / the skill for other clients
            \\       re state export [file]      all reading state as JSON (stdout by default)
            \\       re state import <file|->    merge a state export into this machine
            \\       re state sync               pull/push reading state through the Sync backends
            \\       re state purge <book>       remove a book from every backend and this machine
            \\
        );
        try stderr.flush();
        return;
    }

    var path: [:0]const u8 = undefined;
    var initial_page: ?u16 = null;
    if (args.len == 1) {
        const arena = init.arena.allocator();
        var config = Config.init(init.gpa, init.io, init.environ_map);
        defer config.deinit();
        const paths = try Paths.init(arena, init.environ_map, &config);
        // Other devices' books appear in the picker only once their shards
        // are here; one listing fetches what's missing.
        {
            const backends = Sync.backendsFromConfig(init.gpa, init.io, init.environ_map, &config);
            defer for (backends) |*b| b.store.deinit();
            const device = Positions.deviceIdFor(arena, init.io, paths);
            for (backends) |*b| {
                if (b.manual()) continue; // acts only on `re state sync`
                Sync.pullAll(init.gpa, init.io, &b.store, paths.books, device, null) catch |err| {
                    try stderr.print("sync ({s}): {s}\n", .{ b.name(), @errorName(err) });
                    try stderr.flush();
                };
            }
        }
        const recents = Positions.listRecent(arena, init.io, paths);
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
        path = (try resolveBook(init, .{ .key = recents[idx].key, .path = recents[idx].path }, stderr)) orelse return;
    } else {
        path = args[1];
        if (std.mem.startsWith(u8, path, "http://") or std.mem.startsWith(u8, path, "https://")) {
            path = fetchRemote(init, path, stderr) catch |err| {
                try stderr.print("re: cannot download {s} ({s})\n", .{ path, @errorName(err) });
                try stderr.flush();
                std.process.exit(1);
            };
        }
        if (args.len == 3) initial_page = std.fmt.parseInt(u16, args[2], 10) catch {
            try stderr.print("re: `{s}` is not a page number (run `re --help` for subcommands)\n", .{args[2]});
            try stderr.flush();
            std.process.exit(2);
        };
    }

    // The library hands back the next book to open; the reader restarts on it.
    var page = initial_page;
    while (true) {
        const next = runApp(init, path, page) catch |err| switch (err) {
            error.NoKittyGraphics => {
                try stderr.writeAll(no_graphics_msg);
                try stderr.flush();
                std.process.exit(1);
            },
            else => return err,
        };
        const nb = next orelse break;
        defer {
            init.gpa.free(nb.key);
            init.gpa.free(nb.path);
        }
        page = null;
        path = (try resolveBook(init, nb, stderr)) orelse break;
    }
}

// Deinit (which leaves the alt screen) must run before the message prints,
// or the terminal swallows it.
fn runApp(init: std.process.Init, path: [:0]const u8, initial_page: ?u16) !?NextBook {
    var app = try Context.init(init.gpa, init.io, init.environ_map, path, initial_page);
    defer app.deinit();
    try app.run();
    defer app.next_book = null;
    return app.next_book;
}

// A library pick: the local file when it exists, else the PDF downloaded
// from the first sync store that keeps books (into `downloadDir`).
fn resolveBook(init: std.process.Init, book: NextBook, stderr: *std.Io.Writer) !?[:0]const u8 {
    const a = init.arena.allocator();
    const io = init.io;
    const cwd = std.Io.Dir.cwd();
    if (cwd.access(io, book.path, .{})) |_| return try a.dupeSentinel(u8, book.path, 0) else |_| {}

    var config = Config.init(init.gpa, io, init.environ_map);
    defer config.deinit();
    const paths = try Paths.init(a, init.environ_map, &config);
    const base = std.fs.path.basename(book.path);
    const name = if (base.len > 0) base else try std.fmt.allocPrint(a, "{s}.pdf", .{book.key});
    const dest = try std.fmt.allocPrintSentinel(a, "{s}/{s}", .{ paths.downloads, name }, 0);
    if (cwd.access(io, dest, .{})) |_| return dest else |_| {}

    const backends = Sync.backendsFromConfig(init.gpa, io, init.environ_map, &config);
    defer for (backends) |*b| b.store.deinit();
    for (backends) |*b| {
        if (!b.keepsBooks()) continue;
        try stderr.print("downloading {s} from {s}…\n", .{ name, b.name() });
        try stderr.flush();
        const found = Sync.fetchBook(init.gpa, io, &b.store, book.key, dest) catch |err| {
            try stderr.print("{s}: {s}\n", .{ b.name(), @errorName(err) });
            continue;
        };
        if (found) return dest;
    }
    try stderr.print("{s} is not on this machine and no sync store has it\n", .{book.path});
    try stderr.flush();
    return null;
}

const no_graphics_msg =
    \\re: this terminal did not answer the kitty graphics query, and termre needs the
    \\kitty graphics protocol to draw pages.
    \\
    \\Terminals that support it: Ghostty (any), kitty >= 0.19, WezTerm >= 20220319,
    \\Konsole >= 22.04. Multiplexers: Rex, zellij >= 0.45 (inside a supporting terminal),
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
        \\       re state sync              pull other devices' records, push this device's
        \\       re state purge <book>      delete a book's records, PDF and cover from every backend and this machine
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
    const arena = init.arena.allocator();
    var config = Config.init(init.gpa, init.io, init.environ_map);
    defer config.deinit();
    const paths = try Paths.init(arena, init.environ_map, &config);
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
            const stats = try Positions.exportAll(init.gpa, init.io, paths, &fw.interface);
            try fw.interface.flush();
            try stderr.print("exported {d} books ({d} device records) to {s}\n", .{ stats.books, stats.shards, args[1] });
        } else {
            _ = try Positions.exportAll(init.gpa, init.io, paths, stdout);
            try stdout.flush();
        }
        try stderr.flush();
        return;
    }
    if (std.mem.eql(u8, args[0], "purge") and args.len >= 2) {
        const backends = Sync.backendsFromConfig(init.gpa, init.io, init.environ_map, &config);
        defer for (backends) |*b| b.store.deinit();
        var failed = false;
        for (backends) |*b| {
            const n = Sync.purge(init.gpa, &b.store, args[1]) catch |err| {
                try stderr.print("{s}: purge failed ({s})\n", .{ b.name(), @errorName(err) });
                failed = true;
                continue;
            };
            try stderr.print("{s}: removed {d} object{s}\n", .{ b.name(), n, if (n == 1) "" else "s" });
        }
        Positions.deleteBook(init.gpa, init.io, paths, args[1]) catch |err| {
            try stderr.print("local records: {s}\n", .{@errorName(err)});
            failed = true;
        };
        try stderr.flush();
        if (failed) std.process.exit(1);
        return;
    }
    if (std.mem.eql(u8, args[0], "sync")) {
        const backends = Sync.backendsFromConfig(init.gpa, init.io, init.environ_map, &config);
        defer for (backends) |*b| b.store.deinit();
        if (backends.len == 0) {
            try stderr.writeAll("re state sync: no Sync backends configured (see docs/config.md#sync)\n");
            try stderr.flush();
            std.process.exit(2);
        }
        const books = paths.books;
        const device = Positions.deviceIdFor(arena, init.io, paths);
        var failed = false;
        for (backends) |*b| {
            Sync.pullAll(init.gpa, init.io, &b.store, books, device, null) catch |err| {
                try stderr.print("{s}: pull failed ({s})\n", .{ b.name(), @errorName(err) });
                failed = true;
                continue;
            };
            const pushed = Sync.pushAll(init.gpa, init.io, b, books, device) catch |err| {
                try stderr.print("{s}: push failed ({s})\n", .{ b.name(), @errorName(err) });
                failed = true;
                continue;
            };
            try stderr.print("{s}: pulled other devices' records, pushed {d} of this device's\n", .{ b.name(), pushed });
        }
        try stderr.flush();
        if (failed) std.process.exit(1);
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
        const stats = Positions.importBundle(init.gpa, init.io, paths, json) catch |err| {
            try stderr.print("import failed: {s}\n", .{@errorName(err)});
            try stderr.flush();
            std.process.exit(1);
        };
        try stderr.print("imported {d} books ({d} device records), merged with local state\n", .{ stats.books, stats.shards });
        try stderr.flush();
        return;
    }
    try stderr.writeAll(usage);
    try stderr.flush();
}

// Downloads a PDF once into the library dir (`downloadDir`, default
// <stateDir>/downloads) and returns its path. arXiv abs/html links map to
// the PDF; the file is named after the arXiv id or the URL's last segment.
fn fetchRemote(init: std.process.Init, url_in: []const u8, stderr: *std.Io.Writer) ![:0]const u8 {
    const a = init.arena.allocator();
    var url = url_in;
    var name: []const u8 = "";
    if (std.mem.indexOf(u8, url, "arxiv.org/")) |i| {
        const rest = url[i + "arxiv.org/".len ..];
        for ([_][]const u8{ "abs/", "html/", "pdf/" }) |kind| {
            if (std.mem.startsWith(u8, rest, kind)) {
                var id = rest[kind.len..];
                if (std.mem.indexOfAny(u8, id, "?#")) |q| id = id[0..q];
                id = std.mem.trimEnd(u8, id, "/");
                if (std.mem.endsWith(u8, id, ".pdf")) id = id[0 .. id.len - 4];
                url = try std.fmt.allocPrint(a, "https://arxiv.org/pdf/{s}", .{id});
                name = try std.fmt.allocPrint(a, "arxiv-{s}.pdf", .{id});
                break;
            }
        }
    }
    if (name.len == 0) {
        var last = url;
        if (std.mem.indexOfAny(u8, last, "?#")) |q| last = last[0..q];
        last = std.mem.trimEnd(u8, last, "/");
        if (std.mem.lastIndexOfScalar(u8, last, '/')) |s| last = last[s + 1 ..];
        if (last.len == 0 or std.mem.eql(u8, last, "pdf")) last = try std.fmt.allocPrint(a, "{x}", .{std.hash.Wyhash.hash(0, url)});
        name = if (std.mem.endsWith(u8, last, ".pdf")) last else try std.fmt.allocPrint(a, "{s}.pdf", .{last});
    }
    var config = Config.init(init.gpa, init.io, init.environ_map);
    defer config.deinit();
    const dir = (try Paths.init(a, init.environ_map, &config)).downloads;
    const cwd = std.Io.Dir.cwd();
    try cwd.createDirPath(init.io, dir);
    const path = try std.fmt.allocPrintSentinel(a, "{s}/{s}", .{ dir, name }, 0);
    if (cwd.access(init.io, path, .{})) |_| return path else |_| {}

    try stderr.print("downloading {s}\n", .{url});
    try stderr.flush();
    var client: std.http.Client = .{ .allocator = init.gpa, .io = init.io };
    defer client.deinit();
    var body: std.Io.Writer.Allocating = .init(init.gpa);
    defer body.deinit();
    const res = try client.fetch(.{
        .location = .{ .url = url },
        .response_writer = &body.writer,
        .extra_headers = &.{.{ .name = "user-agent", .value = "termre" }},
    });
    if (res.status != .ok) return error.HttpStatus;
    const data = body.writer.buffered();
    if (!std.mem.startsWith(u8, data, "%PDF")) return error.NotAPdf;
    try fs.writeFileAtomic(init.io, path, data);
    try stderr.print("saved to {s}\n", .{path});
    try stderr.flush();
    return path;
}
