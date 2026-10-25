// `:export`, `:override` and `:markdown`: writing the book out as PDF or markdown.
const std = @import("std");
const Context = @import("Context.zig").Context;

// `:export [path]` — cropped/aligned copy of the PDF for printing.
pub fn exportCropped(ctx: *Context, arg: []const u8) void {
    var path_buf: [1024]u8 = undefined;
    const out: [:0]const u8 = blk: {
        if (arg.len > 0) break :blk std.fmt.bufPrintSentinel(&path_buf, "{s}", .{arg}, 0) catch {
            ctx.progress_text = " export: path too long ";
            return;
        };
        const dir = std.fs.path.dirname(ctx.doc_abs_path) orelse ".";
        const stem = std.fs.path.stem(ctx.doc_abs_path);
        break :blk std.fmt.bufPrintSentinel(&path_buf, "{s}/{s}-cropped.pdf", .{ dir, stem }, 0) catch {
            ctx.progress_text = " export: path too long ";
            return;
        };
    };
    ctx.document_handler.exportCropped(out, false) catch |err| {
        ctx.progress_text = switch (err) {
            error.NothingToApply => " export: no crop or oddx set ",
            else => " export failed ",
        };
        return;
    };
    const msg = std.fmt.bufPrint(&ctx.progress_buf, " exported {s} ", .{out}) catch " exported ";
    ctx.progress_text = msg;
}

// `:override` — bake the crop + oddx into the file itself (same /ID, so
// saved state stays attached), then reset that state: the next open lands
// on the same page but relies on the document's own boxes.
pub fn overrideCropped(ctx: *Context) void {
    var tmp_buf: [1024]u8 = undefined;
    const tmp = std.fmt.bufPrintSentinel(&tmp_buf, "{s}.override.tmp", .{ctx.doc_abs_path}, 0) catch {
        ctx.progress_text = " override: path too long ";
        return;
    };
    const page = ctx.document_handler.getCurrentPageNumber();
    // The save reads the source lazily, so it must go to a temp file and
    // rename over the original rather than write in place.
    ctx.document_handler.exportCropped(tmp, true) catch |err| {
        ctx.progress_text = switch (err) {
            error.NothingToApply => " override: no crop or oddx set ",
            else => " override failed ",
        };
        return;
    };
    std.Io.Dir.renameAbsolute(tmp, ctx.doc_abs_path, ctx.io) catch {
        ctx.progress_text = " override: rename failed ";
        return;
    };
    // The file carries the geometry now; drop it from the session state.
    if (ctx.document_handler.getCropToContent()) ctx.document_handler.toggleCropToContent();
    ctx.document_handler.setMarginCrop(0, 0, 0, 0);
    ctx.document_handler.setOddShiftX(0);
    ctx.document_handler.reloadDocument() catch {};
    ctx.freeOutline();
    ctx.outline = ctx.document_handler.loadOutline(ctx.allocator) catch &.{};
    ctx.clearCache();
    ctx.document_handler.setCurrentPage(page);
    ctx.saveState();
    ctx.progress_text = " crop baked into file; saved state reset ";
}

fn exportProgressCallback(ud: ?*anyopaque, current: c_int, total: c_int) callconv(.c) void {
    const ctx: *Context = @ptrCast(@alignCast(ud.?));
    ctx.flashProgress(" Exporting page {d}/{d} ", .{ current, total });
}

// Chapter headings from the outline plus an invisible page marker, so an
// agent reading the export can cite pages that map back to `:N` here.
fn markdownPageHook(ud: *anyopaque, page: u16, w: *std.Io.Writer) anyerror!void {
    const ctx: *Context = @ptrCast(@alignCast(ud));
    if (page == 0) {
        try w.print("# {s}\n\nSource: `{s}` — {d} pages, exported by termre. `<!-- page N -->` markers precede each page.\n\n", .{
            std.fs.path.stem(ctx.doc_abs_path),
            ctx.doc_abs_path,
            ctx.document_handler.getTotalPages(),
        });
    }
    for (ctx.outline) |e| {
        if (e.page != page) continue;
        const level: usize = @min(@as(usize, e.depth) + 2, 6);
        try w.splatByteAll('#', level);
        try w.print(" {s}\n\n", .{e.title});
    }
    try w.print("<!-- page {d} -->\n\n", .{page + 1});
}

// `:markdown [path]` — the whole book as one markdown file with images
// beside it. Default: <book dir>/<stem>-md/<stem>.md; a path ending in
// .md is the file, anything else is the directory (relative to the book).
pub fn exportMarkdown(ctx: *Context, arg: []const u8) void {
    const stem = std.fs.path.stem(ctx.doc_abs_path);
    const book_dir = std.fs.path.dirname(ctx.doc_abs_path) orelse "/";
    var arena = std.heap.ArenaAllocator.init(ctx.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var target = std.mem.trim(u8, arg, &std.ascii.whitespace);
    if (std.mem.startsWith(u8, target, "~/")) {
        if (ctx.env.get("HOME")) |home| target = std.fmt.allocPrint(a, "{s}/{s}", .{ home, target[2..] }) catch return;
    }
    if (target.len > 0 and target[0] != '/') target = std.fmt.allocPrint(a, "{s}/{s}", .{ book_dir, target }) catch return;

    var dir: []const u8 = undefined;
    var file: [:0]const u8 = undefined;
    if (target.len == 0) {
        dir = std.fmt.allocPrint(a, "{s}/{s}-md", .{ book_dir, stem }) catch return;
        file = std.fmt.allocPrintSentinel(a, "{s}/{s}.md", .{ dir, stem }, 0) catch return;
    } else if (std.mem.endsWith(u8, target, ".md")) {
        dir = std.fs.path.dirname(target) orelse "/";
        file = a.dupeSentinel(u8, target, 0) catch return;
    } else {
        dir = std.mem.trimEnd(u8, target, "/");
        file = std.fmt.allocPrintSentinel(a, "{s}/{s}.md", .{ dir, stem }, 0) catch return;
    }
    std.Io.Dir.cwd().createDirPath(ctx.io, dir) catch {
        ctx.progress_text = std.fmt.bufPrint(&ctx.progress_buf, " cannot create {s} ", .{dir}) catch null;
        return;
    };
    const total = ctx.document_handler.getTotalPages();
    ctx.document_handler.writePagesText(0, total, file, exportProgressCallback, ctx, markdownPageHook, ctx) catch |err| {
        ctx.progress_text = std.fmt.bufPrint(&ctx.progress_buf, " export failed: {s} ", .{@errorName(err)}) catch null;
        return;
    };
    ctx.progress_text = std.fmt.bufPrint(&ctx.progress_buf, " exported {d} pages: {s} ", .{ total, file }) catch null;
}
