const Self = @This();
const std = @import("std");
const Config = @import("../config/Config.zig");

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
    // For the recent-files list; not restored as view state.
    path: []const u8 = "",
    last_opened: i64 = 0,
};

pub const Mark = struct {
    letter: u8,
    page: u16,
    scroll_x: i32,
    scroll_y: i32,
    comment: []const u8 = "",
};

pub const Highlight = struct {
    page: u16 = 0,
    text: []const u8 = "",
    // x0,y0,x1,y1 groups in raw page coordinates, one per selection quad.
    rects: []const f32 = &.{},
};

allocator: std.mem.Allocator,
io: std.Io,
config: *Config,
doc_path: []const u8,
file_path: []u8,
all: std.json.Parsed(std.json.Value),
have_data: bool,

pub fn init(allocator: std.mem.Allocator, io: std.Io, env: *std.process.Environ.Map, config: *Config, doc_path: []const u8) Self {
    var self = Self{
        .allocator = allocator,
        .io = io,
        .config = config,
        .doc_path = doc_path,
        .file_path = "",
        .all = undefined,
        .have_data = false,
    };

    self.file_path = statePath(allocator, env) orelse return self;

    const content = readStateFile(allocator, io, env, self.file_path) orelse return self;
    defer allocator.free(content);

    self.all = std.json.parseFromSlice(std.json.Value, allocator, content, .{}) catch return self;
    if (self.all.value != .object) {
        self.all.deinit();
        return self;
    }
    self.have_data = true;
    return self;
}

pub fn deinit(self: *Self) void {
    if (self.have_data) self.all.deinit();
    if (self.file_path.len > 0) self.allocator.free(self.file_path);
}

fn statePath(allocator: std.mem.Allocator, env: *std.process.Environ.Map) ?[]u8 {
    if (env.get("XDG_STATE_HOME")) |x| {
        return std.fmt.allocPrint(allocator, "{s}/termre/positions.json", .{x}) catch null;
    }
    const home = env.get("HOME") orelse return null;
    return std.fmt.allocPrint(allocator, "{s}/.local/state/termre/positions.json", .{home}) catch null;
}

// Pre-rename location; read-only fallback so existing books keep their state.
fn legacyStatePath(allocator: std.mem.Allocator, env: *std.process.Environ.Map) ?[]u8 {
    if (env.get("XDG_STATE_HOME")) |x| {
        return std.fmt.allocPrint(allocator, "{s}/fancy-cat/positions.json", .{x}) catch null;
    }
    const home = env.get("HOME") orelse return null;
    return std.fmt.allocPrint(allocator, "{s}/.local/state/fancy-cat/positions.json", .{home}) catch null;
}

// Contents of the state file, trying the current path then the legacy one.
fn readStateFile(allocator: std.mem.Allocator, io: std.Io, env: *std.process.Environ.Map, primary: []const u8) ?[]u8 {
    const cwd = std.Io.Dir.cwd();
    if (cwd.readFileAlloc(io, primary, allocator, .limited(1024 * 1024))) |content| {
        return content;
    } else |_| {}
    const legacy = legacyStatePath(allocator, env) orelse return null;
    defer allocator.free(legacy);
    return cwd.readFileAlloc(io, legacy, allocator, .limited(1024 * 1024)) catch null;
}

pub const RecentEntry = struct {
    path: []const u8,
    page: u16,
    last_opened: i64,
};

// Entries from positions.json that carry a path, newest first, deduped by path.
pub fn listRecent(allocator: std.mem.Allocator, io: std.Io, env: *std.process.Environ.Map) []RecentEntry {
    const path = statePath(allocator, env) orelse return &.{};
    defer allocator.free(path);
    const content = readStateFile(allocator, io, env, path) orelse return &.{};
    defer allocator.free(content);
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, content, .{}) catch return &.{};
    defer parsed.deinit();
    if (parsed.value != .object) return &.{};

    var out: std.ArrayList(RecentEntry) = .empty;
    var it = parsed.value.object.iterator();
    while (it.next()) |kv| {
        if (kv.value_ptr.* != .object) continue;
        const obj = kv.value_ptr.object;
        const doc_path = jsonGet([]const u8, obj, "path", "");
        if (doc_path.len == 0) continue;
        const entry = RecentEntry{
            .path = allocator.dupe(u8, doc_path) catch continue,
            .page = jsonGet(u16, obj, "page", 0),
            .last_opened = jsonGet(i64, obj, "last_opened", 0),
        };
        var merged = false;
        for (out.items) |*e| {
            if (std.mem.eql(u8, e.path, entry.path)) {
                merged = true;
                if (entry.last_opened > e.last_opened) {
                    allocator.free(e.path);
                    e.* = entry;
                } else {
                    allocator.free(entry.path);
                }
                break;
            }
        }
        if (!merged) out.append(allocator, entry) catch {
            allocator.free(entry.path);
            break;
        };
    }

    std.sort.pdq(RecentEntry, out.items, {}, struct {
        fn newerFirst(_: void, a: RecentEntry, b: RecentEntry) bool {
            return a.last_opened > b.last_opened;
        }
    }.newerFirst);
    return out.toOwnedSlice(allocator) catch &.{};
}

pub fn getSavedPosition(self: *Self) ?Position {
    return self.lookupKey(self.doc_path);
}

// Tries the canonical doc key first, then an alternate (e.g. the document's
// raw path) — heals positions saved by an older version that keyed by path
// before PDF-id keying existed. The next save rewrites under the canonical key.
pub fn getSavedPositionForKey(self: *Self, alt_key: []const u8) ?Position {
    return self.lookupKey(self.doc_path) orelse self.lookupKey(alt_key);
}

// Reads one struct field's value out of a JSON object, keeping `fallback` on
// miss or type mismatch. Strings are slices into the parsed JSON tree.
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

fn jsonValue(comptime T: type, v: T) std.json.Value {
    return switch (@typeInfo(T)) {
        .int => .{ .integer = @as(i64, v) },
        .float => .{ .float = v },
        .bool => .{ .bool = v },
        .pointer => .{ .string = v },
        else => @compileError("unsupported field type for jsonValue"),
    };
}

fn lookupKey(self: *Self, key: []const u8) ?Position {
    if (!self.have_data) return null;
    const entry = self.all.value.object.get(key) orelse return null;
    if (entry != .object) return null;

    var pos = Position{};
    inline for (std.meta.fields(Position)) |f| {
        @field(pos, f.name) = jsonGet(f.type, entry.object, f.name, @field(pos, f.name));
    }
    return pos;
}

pub fn loadMarks(self: *Self, allocator: std.mem.Allocator) std.ArrayList(Mark) {
    var out: std.ArrayList(Mark) = .empty;
    if (!self.have_data) return out;
    const entry = self.all.value.object.get(self.doc_path) orelse return out;
    if (entry != .object) return out;
    const arr = entry.object.get("marks") orelse return out;
    if (arr != .array) return out;
    for (arr.array.items) |item| {
        if (item != .object) continue;
        const letter_str = jsonGet([]const u8, item.object, "letter", "");
        if (letter_str.len == 0) continue;
        out.append(allocator, .{
            .letter = letter_str[0],
            .page = jsonGet(u16, item.object, "page", 0),
            .scroll_x = jsonGet(i32, item.object, "scroll_x", 0),
            .scroll_y = jsonGet(i32, item.object, "scroll_y", 0),
            .comment = allocator.dupe(u8, jsonGet([]const u8, item.object, "comment", "")) catch "",
        }) catch break;
    }
    return out;
}

pub fn loadHighlights(self: *Self, allocator: std.mem.Allocator) std.ArrayList(Highlight) {
    var out: std.ArrayList(Highlight) = .empty;
    if (!self.have_data) return out;
    const entry = self.all.value.object.get(self.doc_path) orelse return out;
    if (entry != .object) return out;
    const arr = entry.object.get("highlights") orelse return out;
    if (arr != .array) return out;
    for (arr.array.items) |item| {
        if (item != .object) continue;
        const rects_v = item.object.get("rects") orelse continue;
        if (rects_v != .array) continue;
        const n = rects_v.array.items.len - (rects_v.array.items.len % 4);
        if (n == 0) continue;
        const rects = allocator.alloc(f32, n) catch break;
        var ok = true;
        for (rects_v.array.items[0..n], 0..) |rv, i| {
            rects[i] = switch (rv) {
                .float => |f| @floatCast(f),
                .integer => |iv| @floatFromInt(iv),
                else => blk: {
                    ok = false;
                    break :blk 0;
                },
            };
        }
        if (!ok) {
            allocator.free(rects);
            continue;
        }
        out.append(allocator, .{
            .page = jsonGet(u16, item.object, "page", 0),
            .text = allocator.dupe(u8, jsonGet([]const u8, item.object, "text", "")) catch "",
            .rects = rects,
        }) catch {
            allocator.free(rects);
            break;
        };
    }
    return out;
}

pub fn save(self: *Self, pos: Position, marks: []const Mark, highlights: []const Highlight) void {
    if (self.file_path.len == 0) return;

    const cwd = std.Io.Dir.cwd();
    if (std.fs.path.dirname(self.file_path)) |dir| cwd.createDirPath(self.io, dir) catch {};

    var arena = std.heap.ArenaAllocator.init(self.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Merge with the file as it is NOW, not the init-time snapshot: other
    // instances may have saved entries since this one started, and rewriting
    // from the snapshot would erase their books from the recent list.
    var root = std.json.ObjectMap.empty;
    if (cwd.readFileAlloc(self.io, self.file_path, a, .limited(1024 * 1024)) catch null) |content| {
        const val = std.json.parseFromSliceLeaky(std.json.Value, a, content, .{}) catch std.json.Value.null;
        if (val == .object) {
            var it = val.object.iterator();
            while (it.next()) |kv| {
                if (std.mem.eql(u8, kv.key_ptr.*, self.doc_path)) continue;
                // Drop this doc's legacy path-keyed entry; it lives under the
                // canonical key from here on.
                if (pos.path.len > 0 and std.mem.eql(u8, kv.key_ptr.*, pos.path)) continue;
                root.put(a, kv.key_ptr.*, kv.value_ptr.*) catch return;
            }
        }
    }

    var entry = std.json.ObjectMap.empty;
    inline for (std.meta.fields(Position)) |f| {
        entry.put(a, f.name, jsonValue(f.type, @field(pos, f.name))) catch return;
    }

    if (marks.len > 0) {
        var arr = std.json.Array.init(a);
        for (marks) |m| {
            var obj = std.json.ObjectMap.empty;
            const letter_str = a.alloc(u8, 1) catch return;
            letter_str[0] = m.letter;
            obj.put(a, "letter", .{ .string = letter_str }) catch return;
            obj.put(a, "page", .{ .integer = @as(i64, m.page) }) catch return;
            obj.put(a, "scroll_x", .{ .integer = @as(i64, m.scroll_x) }) catch return;
            obj.put(a, "scroll_y", .{ .integer = @as(i64, m.scroll_y) }) catch return;
            obj.put(a, "comment", .{ .string = m.comment }) catch return;
            arr.append(.{ .object = obj }) catch return;
        }
        entry.put(a, "marks", .{ .array = arr }) catch return;
    }

    if (highlights.len > 0) {
        var harr = std.json.Array.init(a);
        for (highlights) |h| {
            var obj = std.json.ObjectMap.empty;
            obj.put(a, "page", .{ .integer = @as(i64, h.page) }) catch return;
            obj.put(a, "text", .{ .string = h.text }) catch return;
            var rarr = std.json.Array.init(a);
            for (h.rects) |v| rarr.append(.{ .float = v }) catch return;
            obj.put(a, "rects", .{ .array = rarr }) catch return;
            harr.append(.{ .object = obj }) catch return;
        }
        entry.put(a, "highlights", .{ .array = harr }) catch return;
    }

    root.put(a, self.doc_path, .{ .object = entry }) catch return;

    const json_str = std.json.Stringify.valueAlloc(a, std.json.Value{ .object = root }, .{ .whitespace = .indent_2 }) catch return;

    // Write to a temp file then atomically rename, so a kill mid-write (or a
    // frequent in-loop save) can never leave a truncated positions.json.
    const tmp_path = std.fmt.allocPrint(a, "{s}.tmp", .{self.file_path}) catch return;
    {
        var file = cwd.createFile(self.io, tmp_path, .{}) catch return;
        defer file.close(self.io);
        var buf: [4096]u8 = undefined;
        var fw = file.writer(self.io, &buf);
        fw.interface.writeAll(json_str) catch return;
        fw.interface.flush() catch return;
    }
    std.Io.Dir.renameAbsolute(tmp_path, self.file_path, self.io) catch return;
}
