// Per-book reading state, one record ("shard") per device:
//   <state>/termre/books/<key>/<device>.json
// A device only ever writes its own shard; loading merges every shard for
// the book: view state is last-writer-wins by `updated_at`, marks and
// highlights are a union with tombstones, so two devices annotating the same
// book never lose each other's work. Remote sync uploads/downloads shards
// into the same directory, which is what makes it conflict-free.
const Self = @This();
const std = @import("std");
const Config = @import("../config/Config.zig");
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
    fit_width: bool = false,
    crop_left: f32 = 0,
    crop_right: f32 = 0,
    crop_top: f32 = 0,
    crop_bottom: f32 = 0,
    grid_zoom: u16 = 0,
    // Not view state: this device's path, when the view was last saved, and
    // which device saved it (the one whose view won the merge on load).
    path: []const u8 = "",
    last_opened: i64 = 0,
    device: []const u8 = "",
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

pub const RecentEntry = struct {
    path: []const u8,
    page: u16,
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
    fit_width: bool = false,
    crop_left: f32 = 0,
    crop_right: f32 = 0,
    crop_top: f32 = 0,
    crop_bottom: f32 = 0,
    grid_zoom: u16 = 0,
};

const MarkRec = struct {
    letter: []const u8 = "",
    page: u16 = 0,
    scroll_x: i32 = 0,
    scroll_y: i32 = 0,
    comment: []const u8 = "",
    updated_at: i64 = 0,
};

const HlRec = struct {
    id: u64 = 0,
    page: u16 = 0,
    text: []const u8 = "",
    rects: []const f32 = &.{},
    created_at: i64 = 0,
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
    view: View = .{},
    marks: []const MarkRec = &.{},
    highlights: []const HlRec = &.{},
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
config: *Config,
doc_key: []const u8,
arena: std.heap.ArenaAllocator,
// "" when no writable state dir could be determined.
books_dir: []const u8,
device: []const u8,
merged: Merged,

pub fn init(allocator: std.mem.Allocator, io: std.Io, env: *std.process.Environ.Map, config: *Config, doc_key: []const u8) Self {
    var self = Self{
        .allocator = allocator,
        .io = io,
        .config = config,
        .doc_key = doc_key,
        .arena = std.heap.ArenaAllocator.init(allocator),
        .books_dir = "",
        .device = "",
        .merged = .{},
    };
    const a = self.arena.allocator();
    const state = stateDir(a, env) orelse return self;
    self.books_dir = std.fmt.allocPrint(a, "{s}/books", .{state}) catch return self;
    self.device = deviceId(a, io, state);
    migrateLegacy(a, io, env, state, self.books_dir, self.device);
    self.merged = self.loadBook(doc_key) catch .{};
    return self;
}

pub fn deinit(self: *Self) void {
    self.arena.deinit();
}

pub fn deviceName(self: *Self) []const u8 {
    return self.device;
}

pub fn booksDir(self: *Self) []const u8 {
    return self.books_dir;
}

// For callers without a document (the recent-books picker).
pub fn booksDirFor(a: std.mem.Allocator, env: *std.process.Environ.Map) ?[]u8 {
    const state = stateDir(a, env) orelse return null;
    return std.fmt.allocPrint(a, "{s}/books", .{state}) catch null;
}

pub fn deviceIdFor(a: std.mem.Allocator, io: std.Io, env: *std.process.Environ.Map) []const u8 {
    const state = stateDir(a, env) orelse return "local";
    return deviceId(a, io, state);
}

// Directory/object name of this document's shards.
pub fn bookName(self: *Self) []const u8 {
    return safeKey(self.arena.allocator(), self.doc_key) catch "";
}

// Re-merges the shards on disk (after a sync pulled other devices' files).
pub fn reload(self: *Self) void {
    self.merged = self.loadBook(self.doc_key) catch return;
}

pub fn getSavedPosition(self: *Self) ?Position {
    return self.merged.view;
}

// Heals state saved by older versions under the document's raw path.
pub fn getSavedPositionForKey(self: *Self, alt_key: []const u8) ?Position {
    if (self.merged.view) |v| return v;
    if (self.books_dir.len == 0) return null;
    const alt = self.loadBook(alt_key) catch return null;
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

pub fn save(self: *Self, pos: Position, marks: []const Mark, highlights: []const Highlight, tombstones: []const Tombstone) void {
    if (self.books_dir.len == 0) return;
    var arena = std.heap.ArenaAllocator.init(self.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const dir = self.bookDir(a, self.doc_key) catch return;
    const file_path = std.fmt.allocPrint(a, "{s}/{s}.json", .{ dir, self.device }) catch return;

    var mine = Shard{
        .device = self.device,
        .path = pos.path,
        .updated_at = time.nowRealSeconds(),
        .view = toView(pos),
        .marks = marksToRecs(a, marks) catch return,
        .highlights = hlToRecs(a, highlights) catch return,
        .tombstones = tombsToRecs(a, tombstones) catch return,
    };
    // Another instance on this device may have saved since we loaded; merge
    // rather than overwrite. Our view is newest, so it wins by timestamp.
    var shards: [2]Shard = .{ mine, mine };
    var n: usize = 1;
    if (readShard(a, self.io, file_path)) |on_disk| {
        shards[1] = on_disk;
        n = 2;
    }
    if (n == 2) {
        const merged = mergeShards(a, shards[0..n]) catch return;
        mine.marks = marksToRecs(a, merged.marks) catch return;
        mine.highlights = hlToRecs(a, merged.highlights) catch return;
        mine.tombstones = tombsToRecs(a, merged.tombstones) catch return;
    }

    const cwd = std.Io.Dir.cwd();
    cwd.createDirPath(self.io, dir) catch return;
    const json_str = std.json.Stringify.valueAlloc(a, mine, .{ .whitespace = .indent_2 }) catch return;
    writeAtomic(a, self.io, file_path, json_str);
}

// Every book with a shard, newest first. Prefers this device's path, then any
// shard whose path exists here, else the newest shard's path tagged with its
// device (the book is not on this machine).
pub fn listRecent(allocator: std.mem.Allocator, io: std.Io, env: *std.process.Environ.Map) []RecentEntry {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const state = stateDir(a, env) orelse return &.{};
    const books = std.fmt.allocPrint(a, "{s}/books", .{state}) catch return &.{};
    const device = deviceId(a, io, state);
    migrateLegacy(a, io, env, state, books, device);

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
        for (shards, 0..) |s, i| {
            if (s.updated_at > shards[newest].updated_at) newest = i;
            if (std.mem.eql(u8, s.device, device) and s.path.len > 0) chosen = i;
        }
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
            .path = allocator.dupe(u8, src.path) catch break,
            .page = shards[newest].view.page,
            .last_opened = shards[newest].updated_at,
            .device = if (local) "" else allocator.dupe(u8, src.device) catch "",
        }) catch break;
    }

    std.sort.pdq(RecentEntry, out.items, {}, struct {
        fn newerFirst(_: void, x: RecentEntry, y: RecentEntry) bool {
            return x.last_opened > y.last_opened;
        }
    }.newerFirst);
    return out.toOwnedSlice(allocator) catch &.{};
}

// ---- merge ---------------------------------------------------------------

fn mergeShards(a: std.mem.Allocator, shards: []const Shard) !Merged {
    var out = Merged{};
    if (shards.len == 0) return out;

    var best: usize = 0;
    for (shards, 0..) |s, i| {
        if (s.updated_at > shards[best].updated_at) best = i;
    }
    var pos = fromView(shards[best].view);
    pos.path = shards[best].path;
    pos.last_opened = shards[best].updated_at;
    pos.device = shards[best].device;
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
            const rec = Highlight{
                .id = if (h.id != 0) h.id else highlightId(h.page, h.rects),
                .page = h.page,
                .text = h.text,
                .rects = h.rects,
                .created_at = h.created_at,
            };
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

fn loadBook(self: *Self, key: []const u8) !Merged {
    if (self.books_dir.len == 0) return .{};
    const a = self.arena.allocator();
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

fn writeAtomic(a: std.mem.Allocator, io: std.Io, path: []const u8, data: []const u8) void {
    const cwd = std.Io.Dir.cwd();
    const tmp_path = std.fmt.allocPrint(a, "{s}.tmp", .{path}) catch return;
    {
        var file = cwd.createFile(io, tmp_path, .{}) catch return;
        defer file.close(io);
        var buf: [4096]u8 = undefined;
        var fw = file.writer(io, &buf);
        fw.interface.writeAll(data) catch return;
        fw.interface.flush() catch return;
    }
    std.Io.Dir.renameAbsolute(tmp_path, path, io) catch return;
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

fn stateDir(a: std.mem.Allocator, env: *std.process.Environ.Map) ?[]u8 {
    if (env.get("XDG_STATE_HOME")) |x| {
        return std.fmt.allocPrint(a, "{s}/termre", .{x}) catch null;
    }
    const home = env.get("HOME") orelse return null;
    return std.fmt.allocPrint(a, "{s}/.local/state/termre", .{home}) catch null;
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
    writeAtomic(a, io, path, id);
    return id;
}

// ---- conversions ---------------------------------------------------------

fn toView(pos: Position) View {
    var v = View{};
    inline for (std.meta.fields(View)) |f| @field(v, f.name) = @field(pos, f.name);
    return v;
}

fn fromView(v: View) Position {
    var pos = Position{};
    inline for (std.meta.fields(View)) |f| @field(pos, f.name) = @field(v, f.name);
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

fn hlToRecs(a: std.mem.Allocator, hls: []const Highlight) ![]HlRec {
    const out = try a.alloc(HlRec, hls.len);
    for (hls, 0..) |h, i| {
        out[i] = .{ .id = if (h.id != 0) h.id else highlightId(h.page, h.rects), .page = h.page, .text = h.text, .rects = h.rects, .created_at = h.created_at };
    }
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

// ---- legacy positions.json -----------------------------------------------

// One-shot: the first run with no books/ directory converts every entry of
// positions.json (termre, else fancy-cat) into this device's shards. The old
// file is left in place for older binaries.
fn migrateLegacy(a: std.mem.Allocator, io: std.Io, env: *std.process.Environ.Map, state: []const u8, books: []const u8, device: []const u8) void {
    const cwd = std.Io.Dir.cwd();
    if (cwd.access(io, books, .{})) |_| return else |_| {}
    cwd.createDirPath(io, books) catch return;

    const primary = std.fmt.allocPrint(a, "{s}/positions.json", .{state}) catch return;
    var content: ?[]u8 = cwd.readFileAlloc(io, primary, a, .limited(4 * 1024 * 1024)) catch null;
    if (content == null) {
        const legacy: ?[]u8 = if (env.get("XDG_STATE_HOME")) |x|
            std.fmt.allocPrint(a, "{s}/fancy-cat/positions.json", .{x}) catch null
        else if (env.get("HOME")) |h|
            std.fmt.allocPrint(a, "{s}/.local/state/fancy-cat/positions.json", .{h}) catch null
        else
            null;
        if (legacy) |lp| content = cwd.readFileAlloc(io, lp, a, .limited(4 * 1024 * 1024)) catch null;
    }
    const raw = content orelse return;
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, a, raw, .{}) catch return;
    if (parsed != .object) return;

    var it = parsed.object.iterator();
    while (it.next()) |kv| {
        if (kv.value_ptr.* != .object) continue;
        const obj = kv.value_ptr.object;
        var pos = Position{};
        inline for (std.meta.fields(View)) |f| {
            @field(pos, f.name) = jsonGet(f.type, obj, f.name, @field(pos, f.name));
        }
        const stamp = jsonGet(i64, obj, "last_opened", 0);
        const shard = Shard{
            .device = device,
            .path = jsonGet([]const u8, obj, "path", ""),
            .updated_at = if (stamp > 0) stamp else time.nowRealSeconds(),
            .view = toView(pos),
            .marks = legacyMarks(a, obj, stamp) catch &.{},
            .highlights = legacyHighlights(a, obj, stamp) catch &.{},
        };
        const dir = std.fmt.allocPrint(a, "{s}/{s}", .{ books, safeKey(a, kv.key_ptr.*) catch continue }) catch continue;
        cwd.createDirPath(io, dir) catch continue;
        const path = std.fmt.allocPrint(a, "{s}/{s}.json", .{ dir, device }) catch continue;
        const json_str = std.json.Stringify.valueAlloc(a, shard, .{ .whitespace = .indent_2 }) catch continue;
        writeAtomic(a, io, path, json_str);
    }
}

fn legacyMarks(a: std.mem.Allocator, obj: std.json.ObjectMap, stamp: i64) ![]MarkRec {
    var out: std.ArrayList(MarkRec) = .empty;
    const arr = obj.get("marks") orelse return out.items;
    if (arr != .array) return out.items;
    for (arr.array.items) |item| {
        if (item != .object) continue;
        const letter = jsonGet([]const u8, item.object, "letter", "");
        if (letter.len == 0) continue;
        try out.append(a, .{
            .letter = letter[0..1],
            .page = jsonGet(u16, item.object, "page", 0),
            .scroll_x = jsonGet(i32, item.object, "scroll_x", 0),
            .scroll_y = jsonGet(i32, item.object, "scroll_y", 0),
            .comment = jsonGet([]const u8, item.object, "comment", ""),
            .updated_at = stamp,
        });
    }
    return out.items;
}

fn legacyHighlights(a: std.mem.Allocator, obj: std.json.ObjectMap, stamp: i64) ![]HlRec {
    var out: std.ArrayList(HlRec) = .empty;
    const arr = obj.get("highlights") orelse return out.items;
    if (arr != .array) return out.items;
    for (arr.array.items) |item| {
        if (item != .object) continue;
        const rects_v = item.object.get("rects") orelse continue;
        if (rects_v != .array) continue;
        const n = rects_v.array.items.len - (rects_v.array.items.len % 4);
        if (n == 0) continue;
        const rects = try a.alloc(f32, n);
        for (rects_v.array.items[0..n], 0..) |rv, i| {
            rects[i] = switch (rv) {
                .float => |f| @floatCast(f),
                .integer => |iv| @floatFromInt(iv),
                else => 0,
            };
        }
        const page = jsonGet(u16, item.object, "page", 0);
        try out.append(a, .{
            .id = highlightId(page, rects),
            .page = page,
            .text = jsonGet([]const u8, item.object, "text", ""),
            .rects = rects,
            .created_at = stamp,
        });
    }
    return out.items;
}

fn jsonGet(comptime T: type, obj: std.json.ObjectMap, name: []const u8, fallback: T) T {
    const v = obj.get(name) orelse return fallback;
    return switch (@typeInfo(T)) {
        .int => if (v == .integer) (std.math.cast(T, v.integer) orelse fallback) else fallback,
        .float => switch (v) {
            .float => |f| @floatCast(f),
            .integer => |i| @floatFromInt(i),
            else => fallback,
        },
        .bool => if (v == .bool) v.bool else fallback,
        .pointer => if (v == .string) v.string else fallback,
        else => @compileError("unsupported field type for jsonGet"),
    };
}
