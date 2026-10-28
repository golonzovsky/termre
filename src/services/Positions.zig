// Per-book reading state, one record ("shard") per device:
//   <state>/termre/books/<key>/<device>.json
// A device only ever writes its own shard; loading merges every shard for
// the book: view state is last-writer-wins by `updated_at`, marks and
// highlights are a union with tombstones, so two devices annotating the same
// book never lose each other's work. Remote sync uploads/downloads shards
// into the same directory, which is what makes it conflict-free.
const Self = @This();
const std = @import("std");
const fs = @import("../utilities/fs.zig");
const meta = @import("../utilities/meta.zig");
const Paths = @import("Paths.zig");
const time = @import("../utilities/time.zig");

pub const Position = struct {
    page: u16 = 0,
    scroll_x: i32 = 0,
    scroll_y: i32 = 0,
    zoom: f32 = 0,
    odd_shift_x: i32 = 0,
    colorize: bool = false,
    crop: bool = false,
    hlock: bool = false,
    spread: bool = false,
    spread_cols: u8 = 2,
    fit_width: bool = false,
    crop_left: f32 = 0,
    crop_right: f32 = 0,
    crop_top: f32 = 0,
    crop_bottom: f32 = 0,
    grid_zoom: u16 = 0,
    // False until the reader moves or changes the view in that record's
    // lifetime: an opened-but-untouched record never outranks real progress.
    touched: bool = false,
    // Not view state: this device's path, when the view was last saved, and
    // which device saved it (the one whose view won the merge on load).
    path: []const u8 = "",
    last_opened: i64 = 0,
    device: []const u8 = "",
    // Page count of the document, for progress display.
    pages: u16 = 0,
};

pub const Mark = struct {
    letter: u8,
    page: u16,
    scroll_x: i32,
    scroll_y: i32,
    comment: []const u8 = "",
    updated_at: i64 = 0,
};

pub const Highlight = struct {
    id: u64 = 0,
    page: u16 = 0,
    text: []const u8 = "",
    // x0,y0,x1,y1 groups in raw page coordinates, one per selection quad.
    rects: []const f32 = &.{},
    created_at: i64 = 0,
};

pub const Tombstone = struct {
    kind: enum { mark, highlight },
    letter: u8 = 0,
    id: u64 = 0,
    deleted_at: i64,
};

// A running `re` instance: <state>/open/<pid>.json, refreshed on every
// state save, removed on exit, pruned when the pid is gone.
pub const OpenEntry = struct {
    path: []const u8 = "",
    pid: i32 = 0,
    since: i64 = 0,
    last_activity: i64 = 0,
    // Last text selected with the mouse in that instance.
    selection: []const u8 = "",
    selection_page: u16 = 0,
    selection_at: i64 = 0,
};

pub const RecentEntry = struct {
    // Directory/object name of the book's shards.
    key: []const u8,
    path: []const u8,
    page: u16,
    // 0 when no record knows the page count yet.
    pages: u16,
    done: bool,
    last_opened: i64,
    // Empty when the book has a path on this device; otherwise the device
    // whose path is shown.
    device: []const u8 = "",
};

// Content-derived id: identical selections on two devices merge into one.
pub fn highlightId(page: u16, rects: []const f32) u64 {
    var h = std.hash.Wyhash.init(0x7e5);
    std.hash.autoHash(&h, page);
    for (rects) |r| std.hash.autoHash(&h, @as(u32, @bitCast(r)));
    return h.final();
}

// On-disk shard schema. Field names are the file format.
const View = struct {
    page: u16 = 0,
    scroll_x: i32 = 0,
    scroll_y: i32 = 0,
    zoom: f32 = 0,
    odd_shift_x: i32 = 0,
    colorize: bool = false,
    crop: bool = false,
    hlock: bool = false,
    spread: bool = false,
    spread_cols: u8 = 2,
    fit_width: bool = false,
    crop_left: f32 = 0,
    crop_right: f32 = 0,
    crop_top: f32 = 0,
    crop_bottom: f32 = 0,
    grid_zoom: u16 = 0,
    touched: bool = false,
};

const MarkRec = struct {
    letter: []const u8 = "",
    page: u16 = 0,
    scroll_x: i32 = 0,
    scroll_y: i32 = 0,
    comment: []const u8 = "",
    updated_at: i64 = 0,
};

const TombRec = struct {
    kind: []const u8 = "",
    letter: []const u8 = "",
    id: u64 = 0,
    deleted_at: i64 = 0,
};

pub const Shard = struct {
    v: u32 = 1,
    device: []const u8 = "",
    path: []const u8 = "",
    updated_at: i64 = 0,
    pages: u16 = 0,
    // Library flags, newest wins: done when done_at beats undone_at and
    // reset_at; a reset also outranks every older record's view.
    done_at: i64 = 0,
    undone_at: i64 = 0,
    reset_at: i64 = 0,
    view: View = .{},
    marks: []const MarkRec = &.{},
    highlights: []const Highlight = &.{},
    tombstones: []const TombRec = &.{},
};

const Merged = struct {
    view: ?Position = null,
    marks: []Mark = &.{},
    highlights: []Highlight = &.{},
    tombstones: []Tombstone = &.{},
};

allocator: std.mem.Allocator,
io: std.Io,
paths: Paths,
doc_key: []const u8,
arena: std.heap.ArenaAllocator,
// Holds `merged`; swapped wholesale on reload so re-merges don't accumulate.
book_arena: std.heap.ArenaAllocator,
name: []const u8,
// "" when no writable state dir could be determined.
books_dir: []const u8,
device: []const u8,
merged: Merged,

pub fn init(allocator: std.mem.Allocator, io: std.Io, paths: Paths, doc_key: []const u8) Self {
    var self = Self{
        .allocator = allocator,
        .io = io,
        .paths = paths,
        .doc_key = doc_key,
        .arena = std.heap.ArenaAllocator.init(allocator),
        .book_arena = std.heap.ArenaAllocator.init(allocator),
        .name = "",
        .books_dir = "",
        .device = "",
        .merged = .{},
    };
    const a = self.arena.allocator();
    self.name = safeKey(a, doc_key) catch "";
    self.books_dir = paths.books;
    self.device = deviceId(a, io, paths.state);
    self.merged = self.loadBook(self.book_arena.allocator(), doc_key) catch .{};
    return self;
}

pub fn deinit(self: *Self) void {
    self.book_arena.deinit();
    self.arena.deinit();
}

pub fn deviceName(self: *Self) []const u8 {
    return self.device;
}

pub fn booksDir(self: *Self) []const u8 {
    return self.books_dir;
}

// For callers without a document (the recent-books picker, `re state`).
pub fn deviceIdFor(a: std.mem.Allocator, io: std.Io, paths: Paths) []const u8 {
    return deviceId(a, io, paths.state);
}

// Directory/object name of this document's shards.
pub fn bookName(self: *Self) []const u8 {
    return self.name;
}

// `<books>/<book>/<name>`: a file kept beside the shards (cover.png).
pub fn bookFile(self: *Self, a: std.mem.Allocator, name: []const u8) ![]u8 {
    if (self.books_dir.len == 0) return error.NoStateDir;
    return std.fmt.allocPrint(a, "{s}/{s}/{s}", .{ self.books_dir, self.name, name });
}

pub fn coverFile(a: std.mem.Allocator, paths: Paths, key: []const u8) ![]u8 {
    return std.fmt.allocPrint(a, "{s}/{s}/cover.png", .{ paths.books, key });
}

// Re-merges the shards on disk (after a sync pulled other devices' files).
pub fn reload(self: *Self) void {
    var fresh = std.heap.ArenaAllocator.init(self.allocator);
    const merged = self.loadBook(fresh.allocator(), self.doc_key) catch {
        fresh.deinit();
        return;
    };
    self.book_arena.deinit();
    self.book_arena = fresh;
    self.merged = merged;
}

pub fn getSavedPosition(self: *Self) ?Position {
    return self.merged.view;
}

// Heals state saved by older versions under the document's raw path.
pub fn getSavedPositionForKey(self: *Self, alt_key: []const u8) ?Position {
    if (self.merged.view) |v| return v;
    if (self.books_dir.len == 0) return null;
    const alt = self.loadBook(self.book_arena.allocator(), alt_key) catch return null;
    if (alt.view != null) self.merged = alt;
    return self.merged.view;
}

pub fn loadMarks(self: *Self, allocator: std.mem.Allocator) std.ArrayList(Mark) {
    var out: std.ArrayList(Mark) = .empty;
    for (self.merged.marks) |m| {
        var copy = m;
        copy.comment = allocator.dupe(u8, m.comment) catch "";
        out.append(allocator, copy) catch break;
    }
    return out;
}

pub fn loadHighlights(self: *Self, allocator: std.mem.Allocator) std.ArrayList(Highlight) {
    var out: std.ArrayList(Highlight) = .empty;
    for (self.merged.highlights) |h| {
        const rects = allocator.dupe(f32, h.rects) catch break;
        out.append(allocator, .{
            .id = h.id,
            .page = h.page,
            .text = allocator.dupe(u8, h.text) catch "",
            .rects = rects,
            .created_at = h.created_at,
        }) catch {
            allocator.free(rects);
            break;
        };
    }
    return out;
}

pub fn loadTombstones(self: *Self, allocator: std.mem.Allocator) std.ArrayList(Tombstone) {
    var out: std.ArrayList(Tombstone) = .empty;
    out.appendSlice(allocator, self.merged.tombstones) catch {};
    return out;
}

// Returns the record's view timestamp: now if the view changed, else the
// previous one (so opening a book doesn't make its record "newer"). Fails
// when nothing could be written, so the caller retries next time.
pub fn save(self: *Self, pos: Position, marks: []const Mark, highlights: []const Highlight, tombstones: []const Tombstone) !i64 {
    const now = time.nowRealSeconds();
    if (self.books_dir.len == 0) return error.NoStateDir;
    var arena = std.heap.ArenaAllocator.init(self.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const dir = try self.bookDir(a, self.doc_key);
    const file_path = try std.fmt.allocPrint(a, "{s}/{s}.json", .{ dir, self.device });

    var mine = Shard{
        .device = self.device,
        .path = pos.path,
        .updated_at = now,
        .pages = pos.pages,
        .view = toView(pos),
        .marks = try marksToRecs(a, marks),
        .highlights = try withHighlightIds(a, highlights),
        .tombstones = try tombsToRecs(a, tombstones),
    };
    mine.view.touched = pos.touched or mine.view.page != 0 or mine.view.scroll_y != 0 or mine.view.scroll_x != 0;
    // Another instance on this device may have saved since we loaded; merge
    // rather than overwrite.
    if (readShard(a, self.io, file_path)) |on_disk| {
        const changed = !viewEql(mine.view, on_disk.view);
        if (!changed) mine.updated_at = on_disk.updated_at;
        mine.view.touched = mine.view.touched or on_disk.view.touched or changed;
        const shards: [2]Shard = .{ mine, on_disk };
        const merged = try mergeShards(a, &shards);
        mine.view = toView(merged.view.?);
        mine.updated_at = merged.view.?.last_opened;
        mine.marks = try marksToRecs(a, merged.marks);
        mine.highlights = try withHighlightIds(a, merged.highlights);
        mine.tombstones = try tombsToRecs(a, merged.tombstones);
        if (mine.pages == 0) mine.pages = on_disk.pages;
        mine.done_at = on_disk.done_at;
        mine.undone_at = on_disk.undone_at;
        mine.reset_at = on_disk.reset_at;
    }

    const cwd = std.Io.Dir.cwd();
    try cwd.createDirPath(self.io, dir);
    const json_str = try std.json.Stringify.valueAlloc(a, mine, .{ .whitespace = .indent_2 });
    try fs.writeFileAtomic(self.io, file_path, json_str);
    return mine.updated_at;
}

pub const Presence = struct {
    since: i64,
    last_activity: i64 = 0,
    sel_text: []const u8 = &.{},
    sel_page: u16 = 0,
    sel_at: i64 = 0,
};

pub fn writePresence(self: *Self, path: []const u8, p: Presence) void {
    if (self.books_dir.len == 0) return;
    var arena = std.heap.ArenaAllocator.init(self.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    std.Io.Dir.cwd().createDirPath(self.io, self.paths.open) catch return;
    const file = std.fmt.allocPrint(a, "{s}/{d}.json", .{ self.paths.open, std.c.getpid() }) catch return;
    const entry = OpenEntry{ .path = path, .pid = std.c.getpid(), .since = p.since, .last_activity = p.last_activity, .selection = p.sel_text, .selection_page = p.sel_page, .selection_at = p.sel_at };
    const json_str = std.json.Stringify.valueAlloc(a, entry, .{}) catch return;
    _ = writeAtomic(self.io, file, json_str);
}

pub fn clearPresence(self: *Self) void {
    if (self.books_dir.len == 0) return;
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const file = std.fmt.bufPrint(&buf, "{s}/{d}.json", .{ self.paths.open, std.c.getpid() }) catch return;
    std.Io.Dir.cwd().deleteFile(self.io, file) catch {};
}

// Agent-to-reader command inbox: <state>/open/<pid>.cmd, one command per
// file, consumed by the instance's control thread.
pub fn sendCommand(io: std.Io, paths: Paths, pid: i32, command: []const u8) bool {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = std.fmt.bufPrint(&buf, "{s}/{d}.cmd", .{ paths.open, pid }) catch return false;
    return writeAtomic(io, path, command);
}

// The pending command for this process, if any (the file is removed).
pub fn takeCommand(self: *Self, allocator: std.mem.Allocator) ?[]u8 {
    if (self.books_dir.len == 0) return null;
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = std.fmt.bufPrint(&buf, "{s}/{d}.cmd", .{ self.paths.open, std.c.getpid() }) catch return null;
    const cwd = std.Io.Dir.cwd();
    const content = cwd.readFileAlloc(self.io, path, allocator, .limited(4096)) catch return null;
    cwd.deleteFile(self.io, path) catch {};
    return content;
}

// Live instances; stale files (dead pids) are removed on the way.
pub fn listOpen(allocator: std.mem.Allocator, io: std.Io, paths: Paths) []OpenEntry {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const dir_path = paths.open;
    const cwd = std.Io.Dir.cwd();
    var dir = cwd.openDir(io, dir_path, .{ .iterate = true }) catch return &.{};
    defer dir.close(io);
    var out: std.ArrayList(OpenEntry) = .empty;
    var it = dir.iterate();
    while (it.next(io) catch null) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".json")) continue;
        const file = std.fmt.allocPrint(a, "{s}/{s}", .{ dir_path, entry.name }) catch continue;
        const content = cwd.readFileAlloc(io, file, a, .limited(4096)) catch continue;
        const e = std.json.parseFromSliceLeaky(OpenEntry, a, content, .{ .ignore_unknown_fields = true }) catch continue;
        // pid reuse guard: a reader that hasn't saved in a day isn't one.
        const fresh = time.nowRealSeconds() - e.last_activity < 24 * 3600;
        const alive = fresh and e.pid > 0 and std.c.kill(e.pid, @fromBackingInt(@intCast(0))) == 0;
        if (alive) {
            out.append(allocator, .{
                .path = allocator.dupe(u8, e.path) catch continue,
                .pid = e.pid,
                .since = e.since,
                .last_activity = e.last_activity,
                .selection = allocator.dupe(u8, e.selection) catch "",
                .selection_page = e.selection_page,
                .selection_at = e.selection_at,
            }) catch break;
        } else {
            cwd.deleteFile(io, file) catch {};
        }
    }
    return out.toOwnedSlice(allocator) catch &.{};
}

// Every book with a shard, newest first. Prefers this device's path, then any
// shard whose path exists here, else the newest shard's path tagged with its
// device (the book is not on this machine).
pub fn listRecent(allocator: std.mem.Allocator, io: std.Io, paths: Paths) []RecentEntry {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const books = paths.books;
    const device = deviceId(a, io, paths.state);

    var out: std.ArrayList(RecentEntry) = .empty;
    const cwd = std.Io.Dir.cwd();
    var root = cwd.openDir(io, books, .{ .iterate = true }) catch return &.{};
    defer root.close(io);
    var it = root.iterate();
    while (it.next(io) catch null) |entry| {
        if (entry.kind != .directory) continue;
        const book_dir = std.fmt.allocPrint(a, "{s}/{s}", .{ books, entry.name }) catch continue;
        const shards = readAllShards(a, io, book_dir) catch continue;
        if (shards.len == 0) continue;

        var newest: usize = 0;
        var chosen: ?usize = null;
        var pages: u16 = readPagesFile(a, io, book_dir);
        var done_at: i64 = 0;
        var undone_at: i64 = 0;
        for (shards, 0..) |s, i| {
            if (s.updated_at > shards[newest].updated_at) newest = i;
            if (std.mem.eql(u8, s.device, device) and s.path.len > 0) chosen = i;
            pages = @max(pages, s.pages);
            done_at = @max(done_at, s.done_at);
            undone_at = @max(undone_at, @max(s.undone_at, s.reset_at));
        }
        const merged = mergeShards(a, shards) catch continue;
        if (chosen == null) {
            for (shards, 0..) |s, i| {
                if (s.path.len == 0) continue;
                cwd.access(io, s.path, .{}) catch continue;
                chosen = i;
                break;
            }
        }
        const local = chosen != null;
        const src = shards[chosen orelse newest];
        if (src.path.len == 0) continue;
        out.append(allocator, .{
            .key = allocator.dupe(u8, entry.name) catch break,
            .path = allocator.dupe(u8, src.path) catch break,
            .page = if (merged.view) |v| v.page else 0,
            .pages = pages,
            .done = done_at > undone_at,
            .last_opened = shards[newest].updated_at,
            .device = if (local) "" else allocator.dupe(u8, src.device) catch "",
        }) catch break;
    }

    // Unfinished books first, each group newest first.
    std.sort.pdq(RecentEntry, out.items, {}, struct {
        fn order(_: void, x: RecentEntry, y: RecentEntry) bool {
            if (x.done != y.done) return !x.done;
            return x.last_opened > y.last_opened;
        }
    }.order);
    return out.toOwnedSlice(allocator) catch &.{};
}

// This device's record of a book, loaded or started from `path`.
const Own = struct { shard: Shard, file: []const u8 };

fn ownShard(a: std.mem.Allocator, io: std.Io, paths: Paths, key: []const u8, path: []const u8) !Own {
    const device = deviceId(a, io, paths.state);
    const file = try std.fmt.allocPrint(a, "{s}/{s}/{s}.json", .{ paths.books, key, device });
    const shard = readShard(a, io, file) orelse Shard{ .device = device, .path = path };
    return .{ .shard = shard, .file = file };
}

fn writeOwn(a: std.mem.Allocator, io: std.Io, own: Own) !void {
    try std.Io.Dir.cwd().createDirPath(io, std.fs.path.dirname(own.file).?);
    const json_str = try std.json.Stringify.valueAlloc(a, own.shard, .{ .whitespace = .indent_2 });
    try fs.writeFileAtomic(io, own.file, json_str);
}

pub fn markDone(allocator: std.mem.Allocator, io: std.Io, paths: Paths, key: []const u8, path: []const u8, done: bool) !void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var own = try ownShard(a, io, paths, key, path);
    const now = time.nowRealSeconds();
    if (done) own.shard.done_at = now else own.shard.undone_at = now;
    try writeOwn(a, io, own);
}

// Back to page 1 and not done; marks and highlights stay.
pub fn resetProgress(allocator: std.mem.Allocator, io: std.Io, paths: Paths, key: []const u8, path: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var own = try ownShard(a, io, paths, key, path);
    const now = time.nowRealSeconds();
    own.shard.view.page = 0;
    own.shard.view.scroll_x = 0;
    own.shard.view.scroll_y = 0;
    own.shard.view.touched = false;
    own.shard.reset_at = now;
    own.shard.updated_at = now;
    try writeOwn(a, io, own);
}

// Every local record, the cover and the page count.
pub fn deleteBook(allocator: std.mem.Allocator, io: std.Io, paths: Paths, key: []const u8) !void {
    const dir = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ paths.books, key });
    defer allocator.free(dir);
    try std.Io.Dir.cwd().deleteTree(io, dir);
}

// The page count found by rendering a book's cover: into this device's record
// when it has one (so it syncs), else a local `pages` file beside the cover.
pub fn recordPages(allocator: std.mem.Allocator, io: std.Io, paths: Paths, key: []const u8, pages: u16) !void {
    if (pages == 0) return;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const book_dir = try std.fmt.allocPrint(a, "{s}/{s}", .{ paths.books, key });
    const device = deviceId(a, io, paths.state);
    const shard_path = try std.fmt.allocPrint(a, "{s}/{s}.json", .{ book_dir, device });
    if (readShard(a, io, shard_path)) |on_disk| {
        if (on_disk.pages == pages) return;
        var mine = on_disk;
        mine.pages = pages;
        const json_str = try std.json.Stringify.valueAlloc(a, mine, .{ .whitespace = .indent_2 });
        try fs.writeFileAtomic(io, shard_path, json_str);
        return;
    }
    try std.Io.Dir.cwd().createDirPath(io, book_dir);
    const text = try std.fmt.allocPrint(a, "{d}\n", .{pages});
    try fs.writeFileAtomic(io, try std.fmt.allocPrint(a, "{s}/pages", .{book_dir}), text);
}

fn readPagesFile(a: std.mem.Allocator, io: std.Io, book_dir: []const u8) u16 {
    const path = std.fmt.allocPrint(a, "{s}/pages", .{book_dir}) catch return 0;
    const text = std.Io.Dir.cwd().readFileAlloc(io, path, a, .limited(16)) catch return 0;
    return std.fmt.parseInt(u16, std.mem.trim(u8, text, &std.ascii.whitespace), 10) catch 0;
}

pub fn freeRecent(allocator: std.mem.Allocator, entries: []RecentEntry) void {
    for (entries) |e| {
        allocator.free(e.key);
        allocator.free(e.path);
        if (e.device.len > 0) allocator.free(e.device);
    }
    allocator.free(entries);
}

// ---- export / import (manual transfer without a store) -------------------

const Bundle = struct {
    v: u32 = 1,
    exported_at: i64 = 0,
    exported_by: []const u8 = "",
    books: []const BookBundle = &.{},
};

const BookBundle = struct {
    book: []const u8,
    shards: []const Shard,
};

pub const TransferStats = struct { books: usize = 0, shards: usize = 0 };

// Every shard of every book as one JSON document.
pub fn exportAll(allocator: std.mem.Allocator, io: std.Io, paths: Paths, out: *std.Io.Writer) !TransferStats {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const books = paths.books;
    const device = deviceId(a, io, paths.state);

    var list: std.ArrayList(BookBundle) = .empty;
    var stats = TransferStats{};
    const cwd = std.Io.Dir.cwd();
    var root = cwd.openDir(io, books, .{ .iterate = true }) catch return error.NoStateDir;
    defer root.close(io);
    var it = root.iterate();
    while (it.next(io) catch null) |entry| {
        if (entry.kind != .directory) continue;
        const dir = try std.fmt.allocPrint(a, "{s}/{s}", .{ books, entry.name });
        const shards = try readAllShards(a, io, dir);
        if (shards.len == 0) continue;
        try list.append(a, .{ .book = try a.dupe(u8, entry.name), .shards = shards });
        stats.books += 1;
        stats.shards += shards.len;
    }
    const bundle = Bundle{ .exported_at = time.nowRealSeconds(), .exported_by = device, .books = list.items };
    try std.json.Stringify.value(bundle, .{ .whitespace = .indent_2 }, out);
    try out.writeByte('\n');
    return stats;
}

// Merges a bundle into the local shards: each imported shard is merged with
// the local shard of the same book+device (newest view wins, annotations
// union with tombstones), so importing is idempotent and never loses work.
pub fn importBundle(allocator: std.mem.Allocator, io: std.Io, paths: Paths, json: []const u8) !TransferStats {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const books = paths.books;

    const bundle = try std.json.parseFromSliceLeaky(Bundle, a, json, .{ .ignore_unknown_fields = true });
    const cwd = std.Io.Dir.cwd();
    var stats = TransferStats{};
    for (bundle.books) |bb| {
        if (bb.book.len == 0 or std.mem.indexOfScalar(u8, bb.book, '/') != null) continue;
        const dir = try std.fmt.allocPrint(a, "{s}/{s}", .{ books, bb.book });
        try cwd.createDirPath(io, dir);
        for (bb.shards) |imported| {
            if (imported.device.len == 0 or std.mem.indexOfScalar(u8, imported.device, '/') != null) continue;
            const file = try std.fmt.allocPrint(a, "{s}/{s}.json", .{ dir, imported.device });
            var pair: [2]Shard = .{ imported, imported };
            var n: usize = 1;
            if (readShard(a, io, file)) |local| {
                pair[1] = local;
                n = 2;
            }
            const merged = try mergeShards(a, pair[0..n]);
            const view = merged.view orelse continue;
            // Keep the path this machine knows the book by.
            const path = if (n == 2 and pair[1].path.len > 0) pair[1].path else view.path;
            const out = Shard{
                .device = imported.device,
                .path = path,
                .updated_at = view.last_opened,
                .view = toView(view),
                .marks = try marksToRecs(a, merged.marks),
                .highlights = try withHighlightIds(a, merged.highlights),
                .tombstones = try tombsToRecs(a, merged.tombstones),
            };
            const json_str = try std.json.Stringify.valueAlloc(a, out, .{ .whitespace = .indent_2 });
            if (writeAtomic(io, file, json_str)) stats.shards += 1;
        }
        stats.books += 1;
    }
    return stats;
}

// ---- merge ---------------------------------------------------------------

fn mergeShards(a: std.mem.Allocator, shards: []const Shard) !Merged {
    var out = Merged{};
    if (shards.len == 0) return out;

    // Newest view wins, but an untouched record (a book opened and never
    // moved) never outranks real progress from another record; a reset
    // demotes every older record to untouched.
    var reset_at: i64 = 0;
    for (shards) |s| reset_at = @max(reset_at, s.reset_at);
    var best: usize = 0;
    var best_progress = hasProgress(shards[0].view) and shards[0].updated_at >= reset_at;
    for (shards[1..], 1..) |s, i| {
        const progress = hasProgress(s.view) and s.updated_at >= reset_at;
        if ((progress and !best_progress) or (progress == best_progress and s.updated_at > shards[best].updated_at)) {
            best = i;
            best_progress = progress;
        }
    }
    var pos = fromView(shards[best].view);
    pos.path = shards[best].path;
    pos.last_opened = shards[best].updated_at;
    pos.device = shards[best].device;
    for (shards) |s| pos.pages = @max(pos.pages, s.pages);
    out.view = pos;

    var tombs: std.ArrayList(Tombstone) = .empty;
    for (shards) |s| {
        for (s.tombstones) |t| {
            const rec = Tombstone{
                .kind = if (std.mem.eql(u8, t.kind, "mark")) .mark else .highlight,
                .letter = if (t.letter.len > 0) t.letter[0] else 0,
                .id = t.id,
                .deleted_at = t.deleted_at,
            };
            var found = false;
            for (tombs.items) |*e| {
                if (sameTombKey(e.*, rec)) {
                    found = true;
                    if (rec.deleted_at > e.deleted_at) e.deleted_at = rec.deleted_at;
                    break;
                }
            }
            if (!found) try tombs.append(a, rec);
        }
    }
    out.tombstones = tombs.items;

    var marks: std.ArrayList(Mark) = .empty;
    for (shards) |s| {
        for (s.marks) |m| {
            if (m.letter.len == 0) continue;
            const rec = Mark{
                .letter = m.letter[0],
                .page = m.page,
                .scroll_x = m.scroll_x,
                .scroll_y = m.scroll_y,
                .comment = m.comment,
                .updated_at = m.updated_at,
            };
            var found = false;
            for (marks.items) |*e| {
                if (e.letter == rec.letter) {
                    found = true;
                    if (rec.updated_at > e.updated_at) e.* = rec;
                    break;
                }
            }
            if (!found) try marks.append(a, rec);
        }
    }
    var live_marks: std.ArrayList(Mark) = .empty;
    for (marks.items) |m| {
        if (m.updated_at > deletedAt(tombs.items, .mark, m.letter, 0)) try live_marks.append(a, m);
    }
    out.marks = live_marks.items;

    var hls: std.ArrayList(Highlight) = .empty;
    for (shards) |s| {
        for (s.highlights) |h| {
            if (h.rects.len < 4) continue;
            var rec = h;
            if (rec.id == 0) rec.id = highlightId(h.page, h.rects);
            var found = false;
            for (hls.items) |*e| {
                if (e.id == rec.id) {
                    found = true;
                    if (rec.created_at > e.created_at) e.* = rec;
                    break;
                }
            }
            if (!found) try hls.append(a, rec);
        }
    }
    var live_hls: std.ArrayList(Highlight) = .empty;
    for (hls.items) |h| {
        if (h.created_at > deletedAt(tombs.items, .highlight, 0, h.id)) try live_hls.append(a, h);
    }
    out.highlights = live_hls.items;
    return out;
}

fn hasProgress(v: View) bool {
    return v.touched or v.page != 0 or v.scroll_y != 0 or v.scroll_x != 0;
}

// Equality of what the reader sees; `touched` is bookkeeping, not view.
fn viewEql(x: View, y: View) bool {
    inline for (comptime meta.fields(View)) |f| {
        if (comptime std.mem.eql(u8, f.name, "touched")) continue;
        if (@field(x, f.name) != @field(y, f.name)) return false;
    }
    return true;
}

fn sameTombKey(x: Tombstone, y: Tombstone) bool {
    return x.kind == y.kind and x.letter == y.letter and x.id == y.id;
}

fn deletedAt(tombs: []const Tombstone, kind: @FieldType(Tombstone, "kind"), letter: u8, id: u64) i64 {
    for (tombs) |t| {
        if (t.kind == kind and t.letter == letter and t.id == id) return t.deleted_at;
    }
    return -1;
}

// ---- shard files ---------------------------------------------------------

fn loadBook(self: *Self, a: std.mem.Allocator, key: []const u8) !Merged {
    if (self.books_dir.len == 0) return .{};
    const dir = try self.bookDir(a, key);
    const shards = try readAllShards(a, self.io, dir);
    return mergeShards(a, shards);
}

fn readAllShards(a: std.mem.Allocator, io: std.Io, book_dir: []const u8) ![]Shard {
    var list: std.ArrayList(Shard) = .empty;
    const cwd = std.Io.Dir.cwd();
    var dir = cwd.openDir(io, book_dir, .{ .iterate = true }) catch return list.items;
    defer dir.close(io);
    var it = dir.iterate();
    while (it.next(io) catch null) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".json")) continue;
        const path = try std.fmt.allocPrint(a, "{s}/{s}", .{ book_dir, entry.name });
        if (readShard(a, io, path)) |s| try list.append(a, s);
    }
    return list.items;
}

fn readShard(a: std.mem.Allocator, io: std.Io, path: []const u8) ?Shard {
    const content = std.Io.Dir.cwd().readFileAlloc(io, path, a, .limited(4 * 1024 * 1024)) catch return null;
    return std.json.parseFromSliceLeaky(Shard, a, content, .{ .ignore_unknown_fields = true }) catch null;
}

// True on success. Per-process temp name: two instances may save at once.
fn writeAtomic(io: std.Io, path: []const u8, data: []const u8) bool {
    fs.writeFileAtomic(io, path, data) catch return false;
    return true;
}

fn bookDir(self: *Self, a: std.mem.Allocator, key: []const u8) ![]u8 {
    return std.fmt.allocPrint(a, "{s}/{s}", .{ self.books_dir, try safeKey(a, key) });
}

// Directory/object name for a document key: `pdf-id:<hex>` -> `pdf-id_<hex>`;
// keys that are paths get hashed.
fn safeKey(a: std.mem.Allocator, key: []const u8) ![]u8 {
    if (std.mem.indexOfScalar(u8, key, '/') != null) {
        return std.fmt.allocPrint(a, "path_{x}", .{std.hash.Wyhash.hash(0, key)});
    }
    const out = try a.dupe(u8, key);
    for (out) |*c| {
        if (!std.ascii.isAlphanumeric(c.*) and c.* != '.' and c.* != '-' and c.* != '_') c.* = '_';
    }
    return out;
}

// Stable per-machine name, minted once: `<hostname>-<4 hex>`.
fn deviceId(a: std.mem.Allocator, io: std.Io, state: []const u8) []const u8 {
    const cwd = std.Io.Dir.cwd();
    const path = std.fmt.allocPrint(a, "{s}/device", .{state}) catch return "local";
    if (cwd.readFileAlloc(io, path, a, .limited(256)) catch null) |content| {
        const trimmed = std.mem.trim(u8, content, &std.ascii.whitespace);
        if (trimmed.len > 0) return trimmed;
    }
    var host_buf: [std.posix.HOST_NAME_MAX]u8 = undefined;
    const host_full = std.posix.gethostname(&host_buf) catch "dev";
    const host = host_full[0..(std.mem.indexOfScalar(u8, host_full, '.') orelse host_full.len)];
    const now = time.nowNs();
    const suffix: u16 = @truncate(std.hash.Wyhash.hash(0, std.mem.asBytes(&now)));
    const id = std.fmt.allocPrint(a, "{s}-{x:0>4}", .{ host, suffix }) catch return "local";
    for (id) |*c| {
        if (!std.ascii.isAlphanumeric(c.*) and c.* != '-') c.* = '-';
    }
    cwd.createDirPath(io, state) catch {};
    _ = writeAtomic(io, path, id);
    return id;
}

// ---- conversions ---------------------------------------------------------

fn toView(pos: Position) View {
    var v = View{};
    inline for (comptime meta.fields(View)) |f| @field(v, f.name) = @field(pos, f.name);
    return v;
}

fn fromView(v: View) Position {
    var pos = Position{};
    inline for (comptime meta.fields(View)) |f| @field(pos, f.name) = @field(v, f.name);
    return pos;
}

fn marksToRecs(a: std.mem.Allocator, marks: []const Mark) ![]MarkRec {
    const out = try a.alloc(MarkRec, marks.len);
    for (marks, 0..) |m, i| {
        const letter = try a.alloc(u8, 1);
        letter[0] = m.letter;
        out[i] = .{ .letter = letter, .page = m.page, .scroll_x = m.scroll_x, .scroll_y = m.scroll_y, .comment = m.comment, .updated_at = m.updated_at };
    }
    return out;
}

// Older records carry id 0; the content hash is the identity on disk.
fn withHighlightIds(a: std.mem.Allocator, hls: []const Highlight) ![]Highlight {
    const out = try a.dupe(Highlight, hls);
    for (out) |*h| if (h.id == 0) {
        h.id = highlightId(h.page, h.rects);
    };
    return out;
}

fn tombsToRecs(a: std.mem.Allocator, tombs: []const Tombstone) ![]TombRec {
    const out = try a.alloc(TombRec, tombs.len);
    for (tombs, 0..) |t, i| {
        const letter: []const u8 = if (t.letter != 0) blk: {
            const l = try a.alloc(u8, 1);
            l[0] = t.letter;
            break :blk l;
        } else "";
        out[i] = .{ .kind = if (t.kind == .mark) "mark" else "highlight", .letter = letter, .id = t.id, .deleted_at = t.deleted_at };
    }
    return out;
}

const testing = std.testing;

fn testPaths(a: std.mem.Allocator, state: []const u8) !Paths {
    return .{
        .state = try a.dupe(u8, state),
        .books = try std.fmt.allocPrint(a, "{s}/books", .{state}),
        .open = try std.fmt.allocPrint(a, "{s}/open", .{state}),
        .history = try std.fmt.allocPrint(a, "{s}/history", .{state}),
        .downloads = try std.fmt.allocPrint(a, "{s}/downloads", .{state}),
    };
}

fn testShard(device: []const u8, updated_at: i64, view: View) Shard {
    return .{ .device = device, .path = "/b.pdf", .updated_at = updated_at, .view = view };
}

test "mergeShards: progress beats a newer untouched record, else newest wins" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const idle_newer = [_]Shard{ testShard("laptop", 10, .{ .page = 5, .touched = true }), testShard("desk", 20, .{}) };
    const m = try mergeShards(a, &idle_newer);
    try testing.expectEqual(@as(u16, 5), m.view.?.page);
    try testing.expectEqualStrings("laptop", m.view.?.device);
    try testing.expectEqual(@as(i64, 10), m.view.?.last_opened);
    const both_moved = [_]Shard{ testShard("laptop", 10, .{ .page = 5, .touched = true }), testShard("desk", 20, .{ .page = 9, .touched = true }) };
    try testing.expectEqual(@as(u16, 9), (try mergeShards(a, &both_moved)).view.?.page);
}

test "mergeShards: a reset outranks older progress from any device" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var reset = testShard("desk", 30, .{});
    reset.reset_at = 30;
    const shards = [_]Shard{ testShard("laptop", 10, .{ .page = 5, .touched = true }), reset };
    try testing.expectEqual(@as(u16, 0), (try mergeShards(a, &shards)).view.?.page);
    const read_after = [_]Shard{ reset, testShard("laptop", 40, .{ .page = 7, .touched = true }) };
    try testing.expectEqual(@as(u16, 7), (try mergeShards(a, &read_after)).view.?.page);
}

test "markDone, resetProgress and deleteBook through the library" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = testing.io;
    const ta = testing.allocator;
    const root = try tmp.dir.realPathFileAlloc(io, ".", ta);
    defer ta.free(root);
    const paths = try testPaths(ta, root);
    defer paths.deinit(ta);
    {
        var p = init(ta, io, paths, "pdf-id:a");
        defer p.deinit();
        _ = try p.save(.{ .page = 3, .touched = true, .path = "/books/a.pdf", .pages = 10 }, &.{}, &.{}, &.{});
    }
    {
        var p = init(ta, io, paths, "pdf-id:b");
        defer p.deinit();
        _ = try p.save(.{ .page = 1, .touched = true, .path = "/books/b.pdf", .pages = 10 }, &.{}, &.{}, &.{});
    }
    try markDone(ta, io, paths, "pdf-id_b", "/books/b.pdf", true);
    {
        const recents = listRecent(ta, io, paths);
        defer freeRecent(ta, recents);
        try testing.expectEqual(@as(usize, 2), recents.len);
        try testing.expectEqualStrings("pdf-id_a", recents[0].key);
        try testing.expect(!recents[0].done);
        try testing.expect(recents[1].done);
    }
    try markDone(ta, io, paths, "pdf-id_b", "/books/b.pdf", false);
    try resetProgress(ta, io, paths, "pdf-id_a", "/books/a.pdf");
    {
        const recents = listRecent(ta, io, paths);
        defer freeRecent(ta, recents);
        try testing.expectEqualStrings("pdf-id_a", recents[0].key);
        try testing.expectEqual(@as(u16, 0), recents[0].page);
        try testing.expect(!recents[1].done);
        var p = init(ta, io, paths, "pdf-id:a");
        defer p.deinit();
        try testing.expectEqual(@as(u16, 0), p.getSavedPosition().?.page);
        try testing.expectEqual(@as(u16, 10), p.getSavedPosition().?.pages);
    }
    try deleteBook(ta, io, paths, "pdf-id_b");
    const recents = listRecent(ta, io, paths);
    defer freeRecent(ta, recents);
    try testing.expectEqual(@as(usize, 1), recents.len);
}

test "mergeShards: marks and highlights union; a newer tombstone removes, an older one does not" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const rects = [_]f32{ 1, 2, 3, 4 };
    const laptop = Shard{
        .device = "laptop",
        .updated_at = 10,
        .marks = &.{ .{ .letter = "a", .page = 1, .updated_at = 5 }, .{ .letter = "c", .page = 7, .updated_at = 10 } },
        .highlights = &.{ .{ .page = 1, .rects = &rects, .created_at = 5 }, .{ .id = 42, .page = 2, .rects = &rects, .created_at = 5 } },
        .tombstones = &.{ .{ .kind = "mark", .letter = "b", .deleted_at = 9 }, .{ .kind = "mark", .letter = "c", .deleted_at = 9 }, .{ .kind = "highlight", .id = 42, .deleted_at = 6 } },
    };
    const desk = Shard{
        .device = "desk",
        .updated_at = 20,
        .marks = &.{ .{ .letter = "a", .page = 2, .updated_at = 7 }, .{ .letter = "b", .page = 3, .updated_at = 8 } },
        .highlights = &.{.{ .page = 1, .rects = &rects, .created_at = 6 }},
    };
    const m = try mergeShards(a, &.{ laptop, desk });
    try testing.expectEqual(@as(usize, 2), m.marks.len);
    try testing.expectEqual(@as(u8, 'a'), m.marks[0].letter);
    try testing.expectEqual(@as(u16, 2), m.marks[0].page);
    try testing.expectEqual(@as(u8, 'c'), m.marks[1].letter);
    try testing.expectEqual(@as(usize, 1), m.highlights.len);
    try testing.expectEqual(highlightId(1, &rects), m.highlights[0].id);
    try testing.expectEqual(@as(i64, 6), m.highlights[0].created_at);
    try testing.expectEqual(@as(usize, 3), m.tombstones.len);
}

test "viewEql ignores touched; hasProgress" {
    const v = View{ .page = 3, .zoom = 1.5 };
    var w = v;
    w.touched = true;
    try testing.expect(viewEql(v, w));
    w.zoom = 2;
    try testing.expect(!viewEql(v, w));
    try testing.expect(!hasProgress(.{}));
    try testing.expect(hasProgress(.{ .scroll_y = 1 }));
    try testing.expect(hasProgress(.{ .touched = true }));
}

test "save, load, export and import round-trip through the state dir" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = testing.io;
    const ta = testing.allocator;
    const root = try tmp.dir.realPathFileAlloc(io, ".", ta);
    defer ta.free(root);
    const state1 = try std.fmt.allocPrint(ta, "{s}/one", .{root});
    defer ta.free(state1);
    const state2 = try std.fmt.allocPrint(ta, "{s}/two", .{root});
    defer ta.free(state2);
    const p1 = try testPaths(ta, state1);
    defer p1.deinit(ta);
    const p2 = try testPaths(ta, state2);
    defer p2.deinit(ta);

    const marks = [_]Mark{.{ .letter = 'a', .page = 2, .scroll_x = 0, .scroll_y = 10, .comment = "note", .updated_at = 5 }};
    {
        var p = init(ta, io, p1, "pdf-id:test");
        defer p.deinit();
        try testing.expect(p.getSavedPosition() == null);
        _ = try p.save(.{ .page = 3, .touched = true, .path = "/books/x.pdf", .pages = 120 }, &marks, &.{}, &.{});
    }
    {
        var p = init(ta, io, p1, "pdf-id:test");
        defer p.deinit();
        try testing.expectEqual(@as(u16, 3), p.getSavedPosition().?.page);
        try testing.expectEqual(@as(u16, 120), p.getSavedPosition().?.pages);
        try testing.expectEqualStrings("/books/x.pdf", p.getSavedPosition().?.path);
        const recents = listRecent(ta, io, p1);
        defer freeRecent(ta, recents);
        try testing.expectEqual(@as(usize, 1), recents.len);
        try testing.expectEqualStrings("pdf-id_test", recents[0].key);
        try testing.expectEqual(@as(u16, 120), recents[0].pages);
        var ml = p.loadMarks(ta);
        defer {
            for (ml.items) |m| ta.free(m.comment);
            ml.deinit(ta);
        }
        try testing.expectEqual(@as(usize, 1), ml.items.len);
        try testing.expectEqualStrings("note", ml.items[0].comment);
    }
    var out: std.Io.Writer.Allocating = .init(ta);
    defer out.deinit();
    const exported = try exportAll(ta, io, p1, &out.writer);
    try testing.expectEqual(@as(usize, 1), exported.books);

    const imported = try importBundle(ta, io, p2, out.written());
    try testing.expectEqual(@as(usize, 1), imported.books);
    var q = init(ta, io, p2, "pdf-id:test");
    defer q.deinit();
    try testing.expectEqual(@as(u16, 3), q.getSavedPosition().?.page);
}
