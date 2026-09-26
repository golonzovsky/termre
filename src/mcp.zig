// `re mcp`: a Model Context Protocol server over stdio, so an agent can read
// a book alongside you — outline, page ranges as markdown, full-text search,
// and your reading state (position, marks, highlights). Read-only.
const std = @import("std");
const Config = @import("config/Config.zig");
const PdfHandler = @import("handlers/PdfHandler.zig");
const Positions = @import("services/Positions.zig");

const protocol_version = "2024-11-05";
// Workflow guidance for agents (Agent Skills format); installed next to the
// MCP registration and printable with `re mcp skill`.
const skill_md = @embedFile("skill/termre/SKILL.md");
const max_result_bytes = 512 * 1024;

const Book = struct {
    path: [:0]u8,
    handler: PdfHandler,
    outline: []const PdfHandler.OutlineEntry,
};

const Server = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    env: *std.process.Environ.Map,
    config: *Config,
    version: []const u8,
    tmp_dir: []const u8,
    book: ?Book = null,
    // Set per call when `book` was defaulted while other books are open.
    default_note: []const u8 = "",
    // Each extraction gets its own directory: the extractor restarts image numbering.
    req_seq: u32 = 0,

    fn closeBook(self: *Server) void {
        if (self.book) |*b| {
            for (b.outline) |e| self.gpa.free(e.title);
            self.gpa.free(b.outline);
            b.handler.deinit();
            self.gpa.free(b.path);
            self.book = null;
        }
    }

    // `spec` is an absolute path, `~/...`, or a case-insensitive substring of a
    // recent book's path.
    fn openBook(self: *Server, a: std.mem.Allocator, spec: []const u8) !*Book {
        var s = std.mem.trim(u8, spec, &std.ascii.whitespace);
        if (s.len == 0) return error.BookRequired;
        if (std.mem.startsWith(u8, s, "~/")) {
            s = try std.fmt.allocPrint(a, "{s}/{s}", .{ self.env.get("HOME") orelse "", s[2..] });
        }
        var path: []const u8 = s;
        if (s[0] != '/') {
            path = "";
            const recents = Positions.listRecent(a, self.io, self.env);
            for (recents) |r| {
                if (r.device.len == 0 and std.ascii.indexOfIgnoreCase(r.path, s) != null) {
                    path = r.path;
                    break;
                }
            }
            if (path.len == 0) return error.BookNotFound;
        }
        if (self.book) |*b| {
            if (std.mem.eql(u8, b.path, path)) return b;
            self.closeBook();
        }
        const owned = try self.gpa.dupeZ(u8, path);
        errdefer self.gpa.free(owned);
        var handler = try PdfHandler.init(self.gpa, self.io, owned, null, self.config);
        errdefer handler.deinit();
        const outline = handler.loadOutline(self.gpa) catch &.{};
        self.book = .{ .path = owned, .handler = handler, .outline = outline };
        return &self.book.?;
    }
};

// `re mcp install claude|codex` delegates to the agent's own registration
// command; `re mcp config` prints the snippet for any other MCP client.
pub fn cli(init: std.process.Init, args: []const [:0]const u8, stdout: *std.Io.Writer, stderr: *std.Io.Writer) !void {
    const sub = args[0];
    if (std.mem.eql(u8, sub, "config")) {
        try stdout.writeAll(
            \\{
            \\  "mcpServers": {
            \\    "termre": { "command": "re", "args": ["mcp"] }
            \\  }
            \\}
            \\
        );
        try stdout.flush();
        return;
    }
    if (std.mem.eql(u8, sub, "skill")) {
        try stdout.writeAll(skill_md);
        try stdout.flush();
        return;
    }
    if (std.mem.eql(u8, sub, "install") and args.len == 2) {
        const client = args[1];
        const argv: []const []const u8 = if (std.mem.eql(u8, client, "claude"))
            &.{ "claude", "mcp", "add", "--scope", "user", "termre", "--", "re", "mcp" }
        else if (std.mem.eql(u8, client, "codex"))
            &.{ "codex", "mcp", "add", "termre", "--", "re", "mcp" }
        else {
            try stderr.writeAll("re mcp install: expected `claude` or `codex`\n");
            try stderr.flush();
            return;
        };
        // Both clients discover skills at ~/.<client>/skills/<name>/SKILL.md.
        if (init.environ_map.get("HOME")) |home| {
            var buf: [std.fs.max_path_bytes]u8 = undefined;
            const dir = try std.fmt.bufPrint(&buf, "{s}/.{s}/skills/termre", .{ home, client });
            const cwd = std.Io.Dir.cwd();
            if (cwd.createDirPath(init.io, dir)) |_| {
                var pbuf: [std.fs.max_path_bytes]u8 = undefined;
                const path = try std.fmt.bufPrint(&pbuf, "{s}/SKILL.md", .{dir});
                const existed = if (cwd.access(init.io, path, .{})) |_| true else |_| false;
                if (cwd.createFile(init.io, path, .{})) |file| {
                    defer file.close(init.io);
                    var wbuf: [4096]u8 = undefined;
                    var fw = file.writer(init.io, &wbuf);
                    fw.interface.writeAll(skill_md) catch {};
                    fw.interface.flush() catch {};
                    try stdout.print("skill {s}: {s}\n", .{ if (existed) "updated" else "installed", path });
                    try stdout.flush();
                } else |err| try stderr.print("skill not installed ({s}); `re mcp skill` prints it\n", .{@errorName(err)});
            } else |err| try stderr.print("skill not installed ({s}); `re mcp skill` prints it\n", .{@errorName(err)});
            try stderr.flush();
        }
        // Already registered? Then don't let the client print a scary error.
        const probe: []const []const u8 = &.{ argv[0], "mcp", "get", "termre" };
        if (std.process.spawn(init.io, .{ .argv = probe, .environ_map = init.environ_map, .stdout = .ignore, .stderr = .ignore })) |p| {
            var probe_child = p;
            const term = probe_child.wait(init.io) catch null;
            if (term != null and term.? == .exited and term.?.exited == 0) {
                try stdout.print("MCP server termre already registered with {s}\n", .{client});
                try stdout.flush();
                return;
            }
        } else |_| {}
        var child = std.process.spawn(init.io, .{ .argv = argv, .environ_map = init.environ_map }) catch |err| {
            try stderr.print("re mcp install: cannot run `{s}` ({s}); is it on PATH? Alternatively add this to its MCP config:\n", .{ argv[0], @errorName(err) });
            try stderr.flush();
            return cli(init, &.{"config"}, stdout, stderr);
        };
        _ = try child.wait(init.io);
        return;
    }
    try stderr.writeAll("usage: re mcp [install claude|codex | config | skill]\n");
    try stderr.flush();
}

pub fn run(init: std.process.Init) !void {
    const gpa = init.gpa;
    var config = Config.init(gpa, init.io, init.environ_map);
    defer config.deinit();
    config.general.colorize = false; // agents want plain text and light diagrams

    const tmp_dir = try std.fmt.allocPrint(gpa, "{s}/termre-mcp-{d}", .{
        std.mem.trimEnd(u8, init.environ_map.get("TMPDIR") orelse "/tmp", "/"),
        std.c.getpid(),
    });
    defer gpa.free(tmp_dir);
    std.Io.Dir.cwd().createDirPath(init.io, tmp_dir) catch {};

    var server = Server{
        .gpa = gpa,
        .io = init.io,
        .env = init.environ_map,
        .config = &config,
        .version = @import("metadata").version,
        .tmp_dir = tmp_dir,
    };
    defer server.closeBook();

    var in_buf: [1 << 16]u8 = undefined;
    var stdin_reader = std.Io.File.stdin().reader(init.io, &in_buf);
    var out_buf: [1 << 16]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(init.io, &out_buf);
    const out = &stdout_writer.interface;

    var line_buf: std.ArrayList(u8) = .empty;
    defer line_buf.deinit(gpa);
    while (try readLine(&stdin_reader.interface, &line_buf, gpa)) |line| {
        if (std.mem.trim(u8, line, &std.ascii.whitespace).len == 0) continue;
        var arena = std.heap.ArenaAllocator.init(gpa);
        defer arena.deinit();
        handle(&server, arena.allocator(), line, out) catch |err| {
            std.debug.print("termre mcp: {s}\n", .{@errorName(err)});
        };
        try out.flush();
    }
}

// Byte-wise so a pipe that stays open never blocks on filling the buffer
// (the delimiter helpers read ahead greedily). null at EOF.
fn readLine(r: *std.Io.Reader, buf: *std.ArrayList(u8), a: std.mem.Allocator) !?[]u8 {
    buf.clearRetainingCapacity();
    while (true) {
        const b = r.takeByte() catch |err| switch (err) {
            error.EndOfStream => return if (buf.items.len == 0) null else buf.items,
            else => return err,
        };
        if (b == '\n') return buf.items;
        try buf.append(a, b);
    }
}

// ---- JSON-RPC ---------------------------------------------------------------

fn handle(self: *Server, a: std.mem.Allocator, line: []const u8, out: *std.Io.Writer) !void {
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, a, line, .{}) catch {
        return writeError(out, .null, -32700, "parse error");
    };
    if (parsed != .object) return writeError(out, .null, -32600, "invalid request");
    const obj = parsed.object;
    const method_v = obj.get("method") orelse return writeError(out, .null, -32600, "missing method");
    if (method_v != .string) return writeError(out, .null, -32600, "invalid method");
    const method = method_v.string;
    const id: std.json.Value = obj.get("id") orelse .null;
    const is_notification = obj.get("id") == null;
    const params: ?std.json.ObjectMap = if (obj.get("params")) |p| (if (p == .object) p.object else null) else null;

    if (std.mem.eql(u8, method, "initialize")) {
        var s = beginResult(out, id) catch return;
        try s.beginObject();
        try s.objectField("protocolVersion");
        try s.write(protocol_version);
        try s.objectField("capabilities");
        try s.beginObject();
        try s.objectField("tools");
        try s.beginObject();
        try s.endObject();
        try s.endObject();
        try s.objectField("serverInfo");
        try s.beginObject();
        try s.objectField("name");
        try s.write("termre");
        try s.objectField("version");
        try s.write(self.version);
        try s.endObject();
        try s.endObject();
        return endResult(&s, out);
    }
    if (is_notification) return; // notifications/initialized, cancelled, ...
    if (std.mem.eql(u8, method, "ping")) {
        var s = try beginResult(out, id);
        try s.beginObject();
        try s.endObject();
        return endResult(&s, out);
    }
    if (std.mem.eql(u8, method, "tools/list")) {
        var s = try beginResult(out, id);
        try writeToolList(&s);
        return endResult(&s, out);
    }
    if (std.mem.eql(u8, method, "tools/call")) {
        const p = params orelse return writeError(out, id, -32602, "missing params");
        const name_v = p.get("name") orelse return writeError(out, id, -32602, "missing tool name");
        if (name_v != .string) return writeError(out, id, -32602, "invalid tool name");
        const args: std.json.ObjectMap = if (p.get("arguments")) |v| (if (v == .object) v.object else std.json.ObjectMap.empty) else std.json.ObjectMap.empty;
        var is_error = false;
        const text = callTool(self, a, name_v.string, args) catch |err| blk: {
            is_error = true;
            break :blk try std.fmt.allocPrint(a, "error: {s}", .{@errorName(err)});
        };
        var s = try beginResult(out, id);
        try s.beginObject();
        try s.objectField("content");
        try s.beginArray();
        try s.beginObject();
        try s.objectField("type");
        try s.write("text");
        try s.objectField("text");
        try s.write(text);
        try s.endObject();
        try s.endArray();
        try s.objectField("isError");
        try s.write(is_error);
        try s.endObject();
        return endResult(&s, out);
    }
    return writeError(out, id, -32601, "method not found");
}

fn beginResult(out: *std.Io.Writer, id: std.json.Value) !std.json.Stringify {
    var s: std.json.Stringify = .{ .writer = out };
    try s.beginObject();
    try s.objectField("jsonrpc");
    try s.write("2.0");
    try s.objectField("id");
    try s.write(id);
    try s.objectField("result");
    return s;
}

fn endResult(s: *std.json.Stringify, out: *std.Io.Writer) !void {
    try s.endObject();
    try out.writeByte('\n');
}

fn writeError(out: *std.Io.Writer, id: std.json.Value, code: i32, msg: []const u8) !void {
    var s: std.json.Stringify = .{ .writer = out };
    try s.beginObject();
    try s.objectField("jsonrpc");
    try s.write("2.0");
    try s.objectField("id");
    try s.write(id);
    try s.objectField("error");
    try s.beginObject();
    try s.objectField("code");
    try s.write(code);
    try s.objectField("message");
    try s.write(msg);
    try s.endObject();
    try s.endObject();
    try out.writeByte('\n');
}

// ---- tools --------------------------------------------------------------------

const Tool = struct {
    name: []const u8,
    description: []const u8,
    // (name, type, description, required)
    params: []const struct { []const u8, []const u8, []const u8, bool },
};

const book_param = .{ "book", "string", "Absolute path, ~/path, or a substring of a recent book's path (e.g. \"Inference\")", true };
const book_param_opt = .{ "book", "string", "Like `book` elsewhere; omit for the book currently being read (most recently active open instance)", false };

const tools = [_]Tool{
    .{ .name = "list_books", .description = "Recently read books with current page; ones read on another device are tagged.", .params = &.{} },
    .{ .name = "get_outline", .description = "Table of contents with page numbers.", .params = &.{book_param} },
    .{ .name = "get_pages", .description = "Pages [from, to] (1-based, inclusive) as markdown. Each page is preceded by an `<!-- page N -->` marker; diagrams are written as PNG files.", .params = &.{ book_param, .{ "from", "integer", "First page (1-based)", true }, .{ "to", "integer", "Last page (1-based, inclusive)", true } } },
    .{ .name = "get_chapter", .description = "A whole top-level chapter as markdown: the one containing `page`, or the first outline entry whose title contains `title`.", .params = &.{ book_param, .{ "page", "integer", "A page inside the chapter (1-based)", false }, .{ "title", "string", "Substring of the chapter title", false } } },
    .{ .name = "search", .description = "Full-text search; returns page numbers with the matching line.", .params = &.{ book_param, .{ "query", "string", "Text to find", true }, .{ "limit", "integer", "Max hits (default 20)", false } } },
    .{ .name = "reading_state", .description = "Where the reader is: current page and chapter, whether it is open now, the last text selected with the mouse, marks and highlights (with text). Omit `book` for the book being read right now.", .params = &.{book_param_opt} },
    .{ .name = "current_page", .description = "The page the reader is on right now — its markdown, plus the current mouse selection and highlights on that page. Omit `book` for the book being read right now.", .params = &.{book_param_opt} },
    .{ .name = "select_text", .description = "Select a passage in the running reader — ONLY when the user explicitly asks for it. `text` must occur verbatim on `page` (take it from search or get_pages). It is shown selected and scrolled into view; the user can highlight it with H and return with Ctrl-O. Nothing is copied to the clipboard. Same targeting rules as goto_page.", .params = &.{ book_param_opt, .{ "page", "integer", "Page the text is on (1-based)", true }, .{ "text", "string", "Exact text to select (a few words to a sentence)", true }, .{ "pid", "integer", "Instance to use, from list_books", false } } },
    .{ .name = "goto_page", .description = "Move the running reader to a page (1-based) — ONLY when the user explicitly asks to be taken there; otherwise cite p.N. They can return with Ctrl-O. Needs the book to be open in termre. Omit `book` for the book being read right now; pass `pid` (from list_books) when the same book is open in several splits.", .params = &.{ book_param_opt, .{ "page", "integer", "Page to show (1-based)", true }, .{ "pid", "integer", "Instance to move, from list_books", false } } },
};

fn writeToolList(s: *std.json.Stringify) !void {
    try s.beginObject();
    try s.objectField("tools");
    try s.beginArray();
    for (tools) |t| {
        try s.beginObject();
        try s.objectField("name");
        try s.write(t.name);
        try s.objectField("description");
        try s.write(t.description);
        try s.objectField("inputSchema");
        try s.beginObject();
        try s.objectField("type");
        try s.write("object");
        try s.objectField("properties");
        try s.beginObject();
        for (t.params) |p| {
            try s.objectField(p[0]);
            try s.beginObject();
            try s.objectField("type");
            try s.write(p[1]);
            try s.objectField("description");
            try s.write(p[2]);
            try s.endObject();
        }
        try s.endObject();
        try s.objectField("required");
        try s.beginArray();
        for (t.params) |p| {
            if (p[3]) try s.write(p[0]);
        }
        try s.endArray();
        try s.endObject();
        try s.endObject();
    }
    try s.endArray();
    try s.endObject();
}

fn argStr(args: std.json.ObjectMap, name: []const u8) ?[]const u8 {
    const v = args.get(name) orelse return null;
    return if (v == .string) v.string else null;
}

fn argInt(args: std.json.ObjectMap, name: []const u8) ?i64 {
    const v = args.get(name) orelse return null;
    return switch (v) {
        .integer => |i| i,
        .float => |f| @intFromFloat(f),
        .string => |str| std.fmt.parseInt(i64, str, 10) catch null,
        else => null,
    };
}

fn callTool(self: *Server, a: std.mem.Allocator, name: []const u8, args: std.json.ObjectMap) ![]const u8 {
    if (std.mem.eql(u8, name, "list_books")) return listBooks(self, a);
    var spec = argStr(args, "book") orelse "";
    self.default_note = "";
    if (std.mem.trim(u8, spec, &std.ascii.whitespace).len == 0) {
        switch (try resolveDefaultBook(self, a)) {
            .path => |p| spec = p,
            .ambiguous => |text| return text,
        }
    }
    const book = try self.openBook(a, spec);
    if (std.mem.eql(u8, name, "get_outline")) return outlineText(a, book);
    if (std.mem.eql(u8, name, "get_pages")) {
        const total: i64 = book.handler.getTotalPages();
        const from = std.math.clamp(argInt(args, "from") orelse 1, 1, total);
        const to = std.math.clamp(argInt(args, "to") orelse from, from, total);
        return pagesMarkdown(self, a, book, @intCast(from - 1), @intCast(to), null);
    }
    if (std.mem.eql(u8, name, "get_chapter")) return chapterMarkdown(self, a, book, args);
    if (std.mem.eql(u8, name, "search")) return searchText(self, a, book, args);
    if (std.mem.eql(u8, name, "reading_state")) return readingState(self, a, book);
    if (std.mem.eql(u8, name, "current_page")) return currentPage(self, a, book);
    if (std.mem.eql(u8, name, "goto_page")) return gotoPage(self, a, book, args);
    if (std.mem.eql(u8, name, "select_text")) return selectText(self, a, book, args);
    return error.UnknownTool;
}

fn instanceFor(self: *Server, a: std.mem.Allocator, book: *Book, want_pid: ?i64) !Positions.OpenEntry {
    const open = Positions.listOpen(a, self.io, self.env);
    var target: ?Positions.OpenEntry = null;
    for (open) |o| {
        if (!std.mem.eql(u8, o.path, book.path)) continue;
        if (want_pid) |wp| {
            if (o.pid == wp) target = o;
        } else if (target == null or o.last_activity > target.?.last_activity) target = o;
    }
    return target orelse error.BookNotOpenInTermre;
}

fn selectText(self: *Server, a: std.mem.Allocator, book: *Book, args: std.json.ObjectMap) ![]const u8 {
    const total: i64 = book.handler.getTotalPages();
    const page = argInt(args, "page") orelse return error.PageRequired;
    if (page < 1 or page > total) return error.PageOutOfRange;
    const text = std.mem.trim(u8, argStr(args, "text") orelse "", &std.ascii.whitespace);
    if (text.len == 0) return error.TextRequired;
    // Check here so the reader never shows "not found".
    var hits: std.ArrayList(PdfHandler.SearchHit) = .empty;
    try book.handler.searchPage(a, @intCast(page - 1), try a.dupeZ(u8, text), &hits);
    if (hits.items.len == 0) return error.TextNotFoundOnPage;
    const t = try instanceFor(self, a, book, argInt(args, "pid"));
    const cmd = try std.fmt.allocPrint(a, "select {d} {s}", .{ page, text });
    if (!Positions.sendCommand(self.gpa, self.io, self.env, t.pid, cmd)) return error.CommandNotDelivered;
    return std.fmt.allocPrint(a, "{s}selected on p.{d} of {s} (instance {d}); the reader shows it inverted — H highlights it, Ctrl-O goes back", .{ self.default_note, page, std.fs.path.basename(book.path), t.pid });
}

fn gotoPage(self: *Server, a: std.mem.Allocator, book: *Book, args: std.json.ObjectMap) ![]const u8 {
    const total: i64 = book.handler.getTotalPages();
    const page = argInt(args, "page") orelse return error.PageRequired;
    if (page < 1 or page > total) return error.PageOutOfRange;
    const t = try instanceFor(self, a, book, argInt(args, "pid"));
    const cmd = try std.fmt.allocPrint(a, "goto {d}", .{page});
    if (!Positions.sendCommand(self.gpa, self.io, self.env, t.pid, cmd)) return error.CommandNotDelivered;
    return std.fmt.allocPrint(a, "{s}moved {s} (instance {d}) to p.{d}; the reader can go back with Ctrl-O", .{ self.default_note, std.fs.path.basename(book.path), t.pid, page });
}

const DefaultBook = union(enum) { path: []const u8, ambiguous: []const u8 };

// With `book` omitted: the single active instance (moved in the last 10
// minutes), or the only open one. Several candidates -> ask rather than guess.
fn resolveDefaultBook(self: *Server, a: std.mem.Allocator) !DefaultBook {
    const open = Positions.listOpen(a, self.io, self.env);
    if (open.len == 0) return error.NoBookOpen;
    const now = nowSeconds();
    var active: ?Positions.OpenEntry = null;
    var active_count: usize = 0;
    for (open) |o| {
        if (now - o.last_activity < 600) {
            active_count += 1;
            active = o;
        }
    }
    const chosen: ?Positions.OpenEntry = if (active_count == 1) active else if (open.len == 1) open[0] else null;
    if (chosen) |c| {
        if (open.len > 1) {
            var note: std.Io.Writer.Allocating = .init(a);
            try note.writer.print("(no `book` given: using the active one; also open: ", .{});
            var first = true;
            for (open) |o| {
                if (std.mem.eql(u8, o.path, c.path)) continue;
                if (!first) try note.writer.writeAll(", ");
                first = false;
                try note.writer.print("{s}", .{std.fs.path.basename(o.path)});
            }
            try note.writer.writeAll(")\n");
            self.default_note = note.writer.buffered();
        }
        return .{ .path = c.path };
    }
    var out: std.Io.Writer.Allocating = .init(a);
    try out.writer.writeAll("Several books are open; pass `book` to pick one:\n");
    for (open) |o| {
        try out.writer.print("  {s}  — {s} {s} ago\n", .{ o.path, if (now - o.last_activity < 600) "active, moved" else "idle for", ago(a, now - o.last_activity) });
    }
    return .{ .ambiguous = out.writer.buffered() };
}

fn presenceFor(self: *Server, a: std.mem.Allocator, path: []const u8) ?Positions.OpenEntry {
    const open = Positions.listOpen(a, self.io, self.env);
    var best: ?Positions.OpenEntry = null;
    for (open) |o| {
        if (!std.mem.eql(u8, o.path, path)) continue;
        if (best == null or o.last_activity > best.?.last_activity) best = o;
    }
    return best;
}

fn writeSelection(w: *std.Io.Writer, a: std.mem.Allocator, o: Positions.OpenEntry) !void {
    if (o.selection.len == 0) return;
    try w.print("selected text (p.{d}, {s} ago):\n{s}\n", .{ o.selection_page + 1, ago(a, nowSeconds() - o.selection_at), o.selection });
}

fn currentPage(self: *Server, a: std.mem.Allocator, book: *Book) ![]const u8 {
    const key = try book.handler.getDocumentKey(a);
    var positions = Positions.init(self.gpa, self.io, self.env, self.config, key);
    defer positions.deinit();
    const pos = positions.getSavedPosition() orelse return error.NeverOpened;
    const total = book.handler.getTotalPages();
    const page: u16 = @min(pos.page, total -| 1);
    var out: std.Io.Writer.Allocating = .init(a);
    const w = &out.writer;
    var chapter: []const u8 = "";
    for (book.outline) |e| {
        if (e.page > page) break;
        chapter = e.title;
    }
    try w.writeAll(self.default_note);
    try w.print("{s} — page {d} of {d}", .{ std.fs.path.basename(book.path), page + 1, total });
    if (chapter.len > 0) try w.print(" — {s}", .{chapter});
    try w.writeAll("\n");
    if (presenceFor(self, a, book.path)) |o| {
        try w.print("open now, {s}\n", .{if (nowSeconds() - o.last_activity < 600) "active" else "idle"});
        try writeSelection(w, a, o);
    }
    var hls = positions.loadHighlights(a);
    defer hls.deinit(a);
    var any = false;
    for (hls.items) |h| {
        if (h.page != page) continue;
        if (!any) try w.writeAll("highlights on this page:\n");
        any = true;
        try w.print("  {s}\n", .{h.text});
    }
    try w.writeAll("\n");
    try w.writeAll(try pagesMarkdown(self, a, book, page, page + 1, null));
    return w.buffered();
}

// Open instances first (most recently active on top), then the rest of the
// recents. "active" = the reader moved in the last 10 minutes.
fn listBooks(self: *Server, a: std.mem.Allocator) ![]const u8 {
    const recents = Positions.listRecent(a, self.io, self.env);
    const open = Positions.listOpen(a, self.io, self.env);
    const now_s = nowSeconds();
    var out: std.Io.Writer.Allocating = .init(a);
    const w = &out.writer;

    std.sort.pdq(Positions.OpenEntry, open, {}, struct {
        fn newer(_: void, x: Positions.OpenEntry, y: Positions.OpenEntry) bool {
            return x.last_activity > y.last_activity;
        }
    }.newer);
    if (open.len > 0) try w.writeAll("open now:\n");
    for (open) |o| {
        var page: ?u16 = null;
        for (recents) |r| {
            if (std.mem.eql(u8, r.path, o.path)) page = r.page;
        }
        const idle = now_s - o.last_activity;
        try w.print("  {s}  [instance {d}]", .{ o.path, o.pid });
        if (page) |pg| try w.print("  (p.{d})", .{pg + 1});
        if (idle < 600) {
            try w.print("  — ACTIVE, moved {s} ago\n", .{ago(a, idle)});
        } else {
            try w.print("  — idle for {s} (open since {s})\n", .{ ago(a, idle), ago(a, now_s - o.since) });
        }
    }

    if (recents.len > 0) try w.writeAll(if (open.len > 0) "other recent books:\n" else "recent books:\n");
    for (recents) |r| {
        var is_open = false;
        for (open) |o| {
            if (std.mem.eql(u8, o.path, r.path)) is_open = true;
        }
        if (is_open) continue;
        if (r.device.len > 0) {
            try w.print("  {s}  (p.{d}, last read {s} ago on {s} — not on this machine)\n", .{ r.path, r.page + 1, ago(a, now_s - r.last_opened), r.device });
        } else {
            try w.print("  {s}  (p.{d}, last read {s} ago)\n", .{ r.path, r.page + 1, ago(a, now_s - r.last_opened) });
        }
    }
    if (recents.len == 0 and open.len == 0) try w.writeAll("no books read yet\n");
    return w.buffered();
}

fn nowSeconds() i64 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(.REALTIME, &ts);
    return @intCast(ts.sec);
}

fn ago(a: std.mem.Allocator, secs: i64) []const u8 {
    const s = @max(0, secs);
    return (if (s < 60) std.fmt.allocPrint(a, "{d}s", .{s}) else if (s < 3600) std.fmt.allocPrint(a, "{d}m", .{@divTrunc(s, 60)}) else if (s < 86400) std.fmt.allocPrint(a, "{d}h", .{@divTrunc(s, 3600)}) else std.fmt.allocPrint(a, "{d}d", .{@divTrunc(s, 86400)})) catch "?";
}

fn outlineText(a: std.mem.Allocator, book: *Book) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(a);
    const w = &out.writer;
    try w.print("{s} — {d} pages\n", .{ std.fs.path.basename(book.path), book.handler.getTotalPages() });
    if (book.outline.len == 0) try w.writeAll("(no outline in this PDF)\n");
    for (book.outline) |e| {
        try w.splatByteAll(' ', @as(usize, e.depth) * 2);
        try w.print("{s} (p.{d})\n", .{ e.title, e.page + 1 });
    }
    return w.buffered();
}

const HookCtx = struct { book: *Book, heading: ?[]const u8 };

fn pageHook(ctx: *anyopaque, page: u16, w: *std.Io.Writer) anyerror!void {
    const h: *HookCtx = @ptrCast(@alignCast(ctx));
    for (h.book.outline) |e| {
        if (e.page != page) continue;
        try w.splatByteAll('#', @min(@as(usize, e.depth) + 2, 6));
        try w.print(" {s}\n\n", .{e.title});
    }
    try w.print("<!-- page {d} -->\n\n", .{page + 1});
}

// Pages [start, end) via the same extractor as `:markdown`, through a temp file.
fn pagesMarkdown(self: *Server, a: std.mem.Allocator, book: *Book, start: u16, end: u16, heading: ?[]const u8) ![]const u8 {
    self.req_seq += 1;
    const dir = try std.fmt.allocPrint(a, "{s}/{d}", .{ self.tmp_dir, self.req_seq });
    try std.Io.Dir.cwd().createDirPath(self.io, dir);
    const path = try std.fmt.allocPrintSentinel(a, "{s}/pages-{d}-{d}.md", .{ dir, start + 1, end }, 0);
    var hook = HookCtx{ .book = book, .heading = heading };
    try book.handler.writePagesText(start, end, path, null, null, pageHook, &hook);
    const md = try std.Io.Dir.cwd().readFileAlloc(self.io, path, a, .limited(max_result_bytes));
    var out: std.Io.Writer.Allocating = .init(a);
    const w = &out.writer;
    if (heading) |h| try w.print("# {s}\n\n", .{h});
    try w.print("<!-- {s}, pages {d}-{d} of {d}; diagram PNGs in {s} -->\n\n", .{ std.fs.path.basename(book.path), start + 1, end, book.handler.getTotalPages(), dir });
    try w.writeAll(md);
    return w.buffered();
}

fn chapterMarkdown(self: *Server, a: std.mem.Allocator, book: *Book, args: std.json.ObjectMap) ![]const u8 {
    const total = book.handler.getTotalPages();
    const entries = book.outline;
    if (entries.len == 0) return error.NoOutline;
    var min_depth: u8 = 255;
    for (entries) |e| min_depth = @min(min_depth, e.depth);

    var chosen: ?usize = null;
    if (argStr(args, "title")) |needle| {
        for (entries, 0..) |e, i| {
            if (std.ascii.indexOfIgnoreCase(e.title, needle) != null) {
                chosen = i;
                break;
            }
        }
        if (chosen == null) return error.ChapterNotFound;
    } else {
        const page: u16 = @intCast(std.math.clamp((argInt(args, "page") orelse 1) - 1, 0, @as(i64, total) - 1));
        for (entries, 0..) |e, i| {
            if (e.depth != min_depth) continue;
            if (e.page <= page) chosen = i else break;
        }
        if (chosen == null) return error.ChapterNotFound;
    }
    const idx = chosen.?;
    const start = entries[idx].page;
    var end: u16 = total;
    for (entries[idx + 1 ..]) |next| {
        if (next.depth <= entries[idx].depth) {
            end = next.page;
            break;
        }
    }
    if (end <= start) end = start + 1;
    return pagesMarkdown(self, a, book, start, end, entries[idx].title);
}

fn searchText(self: *Server, a: std.mem.Allocator, book: *Book, args: std.json.ObjectMap) ![]const u8 {
    _ = self;
    const query = argStr(args, "query") orelse return error.QueryRequired;
    const limit: usize = @intCast(std.math.clamp(argInt(args, "limit") orelse 20, 1, 200));
    const needle = try a.dupeZ(u8, query);
    var out: std.Io.Writer.Allocating = .init(a);
    const w = &out.writer;
    var hits: std.ArrayList(PdfHandler.SearchHit) = .empty;
    var count: usize = 0;
    var page: u16 = 0;
    const total = book.handler.getTotalPages();
    while (page < total and count < limit) : (page += 1) {
        hits.clearRetainingCapacity();
        book.handler.searchPage(a, page, needle, &hits) catch continue;
        var last_line: []const u8 = "";
        for (hits.items) |h| {
            if (count >= limit) break;
            const line = book.handler.lineTextAt(a, page, h.x0, (h.y0 + h.y1) / 2) catch "";
            if (line.len > 0 and std.mem.eql(u8, line, last_line)) continue;
            last_line = line;
            try w.print("p.{d}: {s}\n", .{ page + 1, std.mem.trim(u8, line, &std.ascii.whitespace) });
            count += 1;
        }
    }
    if (count == 0) try w.print("no matches for \"{s}\"\n", .{query});
    return w.buffered();
}

fn readingState(self: *Server, a: std.mem.Allocator, book: *Book) ![]const u8 {
    const key = try book.handler.getDocumentKey(a);
    var positions = Positions.init(self.gpa, self.io, self.env, self.config, key);
    defer positions.deinit();
    var out: std.Io.Writer.Allocating = .init(a);
    const w = &out.writer;
    try w.writeAll(self.default_note);
    try w.print("{s} — {d} pages\n", .{ std.fs.path.basename(book.path), book.handler.getTotalPages() });
    if (presenceFor(self, a, book.path)) |o| {
        const idle = nowSeconds() - o.last_activity;
        try w.print("open in termre now — {s}\n", .{if (idle < 600) "active" else "idle"});
        try writeSelection(w, a, o);
    }
    if (positions.getSavedPosition()) |pos| {
        var chapter: []const u8 = "";
        for (book.outline) |e| {
            if (e.page > pos.page) break;
            chapter = e.title;
        }
        try w.print("current page: {d}", .{pos.page + 1});
        if (chapter.len > 0) try w.print(" — {s}", .{chapter});
        try w.print("\nlast read: {s} on {s}\n", .{ dateString(pos.last_opened), pos.device });
    } else {
        try w.writeAll("never opened in termre\n");
    }
    var marks = positions.loadMarks(a);
    defer marks.deinit(a);
    if (marks.items.len > 0) try w.writeAll("marks:\n");
    for (marks.items) |m| {
        if (m.comment.len > 0) {
            try w.print("  '{c}  p.{d}  {s}\n", .{ m.letter, m.page + 1, m.comment });
        } else {
            try w.print("  '{c}  p.{d}\n", .{ m.letter, m.page + 1 });
        }
    }
    var hls = positions.loadHighlights(a);
    defer hls.deinit(a);
    if (hls.items.len > 0) try w.writeAll("highlights:\n");
    for (hls.items) |h| try w.print("  p.{d}: {s}\n", .{ h.page + 1, h.text });
    return w.buffered();
}

fn dateString(secs: i64) [10]u8 {
    const es = std.time.epoch.EpochSeconds{ .secs = @intCast(@max(0, secs)) };
    const yd = es.getEpochDay().calculateYearDay();
    const md = yd.calculateMonthDay();
    var out: [10]u8 = undefined;
    _ = std.fmt.bufPrint(&out, "{d:0>4}-{d:0>2}-{d:0>2}", .{ yd.year, md.month.numeric(), @as(u32, md.day_index) + 1 }) catch unreachable;
    return out;
}
