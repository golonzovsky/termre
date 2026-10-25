// Hands the current page, chapter or outline to $EDITOR as a temp markdown file.
const std = @import("std");
const Context = @import("Context.zig").Context;

fn tempDir(ctx: *Context, comptime kind: []const u8, args: anytype) ![]u8 {
    return std.fmt.allocPrint(ctx.allocator, "/tmp/termre-{d}-" ++ kind, .{std.c.getpid()} ++ args);
}

pub fn openCurrentPageInEditor(ctx: *Context) !void {
    const page = ctx.document_handler.getCurrentPageNumber();
    const dir = try tempDir(ctx, "page{d}", .{page + 1});
    defer ctx.allocator.free(dir);
    const path = try std.fmt.allocPrintSentinel(ctx.allocator, "{s}/page{d}.md", .{ dir, page + 1 }, 0);
    defer ctx.allocator.free(path);

    std.Io.Dir.createDirAbsolute(ctx.io, dir, .default_dir) catch {};
    try ctx.document_handler.writePageText(page, path);
    try spawnEditorAndWait(ctx, path, dir, null);
}

fn currentChapterRange(ctx: *Context, current_page: u16) struct { start: u16, end: u16 } {
    const total = ctx.document_handler.getTotalPages();
    const entries = ctx.outline;
    if (entries.len == 0) return .{ .start = current_page, .end = current_page + 1 };

    var min_depth: u8 = 255;
    for (entries) |e| {
        if (e.depth < min_depth) min_depth = e.depth;
    }

    var start: u16 = 0;
    var end: u16 = total;
    var found = false;
    for (entries, 0..) |e, i| {
        if (e.depth != min_depth) continue;
        if (e.page <= current_page) {
            start = e.page;
            found = true;
            end = total;
            for (entries[i + 1 ..]) |next_e| {
                if (next_e.depth == min_depth) {
                    end = next_e.page;
                    break;
                }
            }
        } else break;
    }
    if (!found) return .{ .start = current_page, .end = current_page + 1 };
    return .{ .start = start, .end = end };
}

fn progressCallback(ud: ?*anyopaque, current: c_int, total: c_int) callconv(.c) void {
    const ctx: *Context = @ptrCast(@alignCast(ud.?));
    ctx.flashProgress(" Rendering chapter {d}/{d} ", .{ current, total });
}

fn extractRangeToEditor(ctx: *Context, dir: []const u8, name: []const u8, start: u16, end: u16) !void {
    const path = try std.fmt.allocPrintSentinel(ctx.allocator, "{s}/{s}", .{ dir, name }, 0);
    defer ctx.allocator.free(path);

    std.Io.Dir.createDirAbsolute(ctx.io, dir, .default_dir) catch {};
    try ctx.document_handler.writePagesText(start, end, path, progressCallback, ctx, null, null);
    ctx.progress_text = null;
    try spawnEditorAndWait(ctx, path, dir, null);
}

pub fn openCurrentChapterInEditor(ctx: *Context) !void {
    const page = ctx.document_handler.getCurrentPageNumber();
    const range = currentChapterRange(ctx, page);
    const dir = try tempDir(ctx, "chap-{d}-{d}", .{ range.start + 1, range.end });
    defer ctx.allocator.free(dir);
    const name = try std.fmt.allocPrint(ctx.allocator, "chap-{d}-{d}.md", .{ range.start + 1, range.end });
    defer ctx.allocator.free(name);

    try extractRangeToEditor(ctx, dir, name, range.start, range.end);
}

pub fn openOutlineInEditor(ctx: *Context, selected_index: ?usize) !void {
    const entries = ctx.outline;
    if (entries.len == 0) return;

    const dir = try tempDir(ctx, "toc", .{});
    defer ctx.allocator.free(dir);
    const path = try std.fmt.allocPrintSentinel(ctx.allocator, "{s}/toc.md", .{dir}, 0);
    defer ctx.allocator.free(path);

    std.Io.Dir.createDirAbsolute(ctx.io, dir, .default_dir) catch {};
    {
        var file = try std.Io.Dir.createFileAbsolute(ctx.io, path, .{});
        defer file.close(ctx.io);
        var buf: [4096]u8 = undefined;
        var fw = file.writer(ctx.io, &buf);
        const w = &fw.interface;
        try w.writeAll("# Table of Contents\n\n");
        for (entries) |e| {
            var k: usize = 0;
            while (k < @as(usize, e.depth) * 2) : (k += 1) try w.writeByte(' ');
            try w.print("- {s}  (p.{d})\n", .{ e.title, e.page + 1 });
        }
        try w.flush();
    }
    const line: ?usize = if (selected_index) |i| i + 3 else null; // header is 2 lines; entries start at line 3
    try spawnEditorAndWait(ctx, path, dir, line);
}

fn spawnEditorAndWait(ctx: *Context, path: [:0]const u8, dir: []const u8, line: ?usize) !void {
    const editor_raw = ctx.env.get("EDITOR") orelse ctx.env.get("VISUAL") orelse "vim";
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(ctx.allocator);
    var it = std.mem.tokenizeAny(u8, editor_raw, &std.ascii.whitespace);
    while (it.next()) |tok| try argv.append(ctx.allocator, tok);

    // Jump vim-family editors to a specific line (e.g. the TOC's selected
    // chapter). `+N` is understood by vi/vim/nvim/nano/emacs; skip it for
    // others (e.g. `code` would treat `+N` as a filename).
    var line_buf: ?[]u8 = null;
    defer if (line_buf) |lb| ctx.allocator.free(lb);
    if (line) |n| {
        if (argv.items.len > 0) {
            const base = std.fs.path.basename(argv.items[0]);
            const is_vi = std.mem.eql(u8, base, "vim") or std.mem.eql(u8, base, "nvim") or
                std.mem.eql(u8, base, "vi") or std.mem.eql(u8, base, "nano") or
                std.mem.eql(u8, base, "emacs") or std.mem.eql(u8, base, "emacsclient");
            if (is_vi) {
                line_buf = try std.fmt.allocPrint(ctx.allocator, "+{d}", .{n});
                try argv.append(ctx.allocator, line_buf.?);
            }
        }
    }
    try argv.append(ctx.allocator, path);

    // Everything fallible is done; now hand the terminal over. Release the
    // tty so the editor can read stdin — otherwise the vaxis input thread
    // keeps consuming keystrokes from underneath the editor.
    var writer = ctx.tty.writer();
    try ctx.vx.setMouseMode(writer, false);
    try ctx.vx.exitAltScreen(writer);
    try writer.flush();
    if (ctx.loop) |loop| loop.stop();

    var child = std.process.spawn(ctx.io, .{
        .argv = argv.items,
        .environ_map = ctx.env,
    }) catch |err| {
        restoreAfterEditor(ctx) catch {};
        ctx.setProgress(std.fmt.bufPrint(&ctx.progress_buf, " cannot run $EDITOR `{s}`: {s} ", .{ editor_raw, @errorName(err) }) catch null);
        return err;
    };
    _ = child.wait(ctx.io) catch {};

    // Clean up the per-extract directory and everything inside it.
    const last_slash = std.mem.lastIndexOfScalar(u8, dir, '/') orelse 0;
    const parent = dir[0..last_slash];
    const leaf = dir[last_slash + 1 ..];
    if (std.Io.Dir.openDirAbsolute(ctx.io, parent, .{})) |opened_parent| {
        var parent_dir = opened_parent;
        defer parent_dir.close(ctx.io);
        parent_dir.deleteTree(ctx.io, leaf) catch {};
    } else |_| {}

    try restoreAfterEditor(ctx);
}

fn restoreAfterEditor(ctx: *Context) !void {
    var writer = ctx.tty.writer();
    if (ctx.loop) |loop| try loop.start();
    try ctx.vx.enterAltScreen(writer);
    // Re-measure: the alt screen was torn down and rebuilt while the editor
    // owned the tty, so screen.width_pix/height_pix are stale. Without this
    // the fit-zoom renders slightly small until the next SIGWINCH. Mirrors
    // the startup query; must run after loop.start() (input thread alive).
    try ctx.vx.queryTerminal(writer, std.Io.Duration.fromSeconds(1));
    try ctx.vx.setMouseMode(writer, true);
    try writer.flush();
    ctx.clearCache();
}
