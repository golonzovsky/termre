// Background sync of one book's shards with the external store. A worker
// thread pulls the other devices' shards into the local books directory and
// pushes this device's shard (debounced); PDFs go up only on request. Results
// are handed back through `notify`, called on the worker thread.
const Self = @This();
const std = @import("std");
const fs = @import("../utilities/fs.zig");
const Store = @import("Store.zig").Store;
const StoreMod = @import("Store.zig");
const Config = @import("../config/Config.zig");
const time = @import("../utilities/time.zig");
const parseDuration = @import("../utilities/duration.zig").parse;

// Objects kept beside the shards under books/<book>/.
pub const book_object = "book.pdf";
pub const cover_object = "cover.png";
const max_book_bytes = 2 * 1024 * 1024 * 1024;
const max_cover_bytes = 16 * 1024 * 1024;

// By value: the worker thread owns no buffer the main thread could read later.
pub const ErrText = struct {
    buf: [120]u8 = undefined,
    len: u8 = 0,

    pub fn text(self: *const ErrText) []const u8 {
        return self.buf[0..self.len];
    }
};

pub const Result = union(enum) {
    // true when at least one remote shard was new or changed locally.
    pulled: bool,
    pushed,
    // A requested PDF is in the named store.
    uploaded: ErrText,
    // A book's PDF and cover are gone from every backend.
    deleted,
    // Every book's shards and covers were fetched (library refresh).
    indexed,
    err: ErrText,
};

pub const Notify = *const fn (ctx: *anyopaque, result: Result) void;

pub const Mode = enum {
    // only `:sync` / `re state sync`
    manual,
    // pull when a book opens, push when it closes
    open_close,
    // open_close plus a debounced push while reading
    periodic,

    pub fn parse(text: []const u8, is_git: bool) Mode {
        if (std.mem.eql(u8, text, "manual")) return .manual;
        if (std.mem.eql(u8, text, "open-close") or std.mem.eql(u8, text, "open_close")) return .open_close;
        if (std.mem.eql(u8, text, "periodic") or std.mem.eql(u8, text, "auto")) return .periodic;
        return if (is_git) .manual else .periodic;
    }
};

pub const Backend = struct {
    store: Store,
    mode: Mode,
    debounce_ns: i64,
    // Worker-only bookkeeping.
    last_push: i64 = 0,
    seen_seq: u32 = 0,

    pub fn name(self: *Backend) []const u8 {
        return self.store.name();
    }

    pub fn manual(self: *Backend) bool {
        return self.mode == .manual;
    }

    // PDFs (books/<book>/book.pdf) go to object/folder stores, never into a
    // git repo.
    pub fn keepsBooks(self: *Backend) bool {
        return self.store != .git;
    }
};

allocator: std.mem.Allocator,
io: std.Io,
backends: []Backend,
books_dir: []const u8,
book: []const u8, // directory/object name of the book
device: []const u8,
notify: Notify,
notify_ctx: *anyopaque,

mu: std.Io.Mutex = .init,
// Requested uploads (requestUpload), owned until the worker takes them.
uploads: std.ArrayList(Upload) = .empty,
// The upload in flight, for the library's badge.
active_upload: ?[]u8 = null,
deletes: std.ArrayList([]u8) = .empty,
// Books whose PDF some backend holds, as of the last index or upload.
stored: std.StringHashMapUnmanaged(void) = .empty,

// 0 none, 1 automatic backends only (open), 2 all (`:sync`).
want_pull: std.atomic.Value(u8) = .init(0),
want_index: std.atomic.Value(bool) = .init(false),
// Bumped per push request; a backend is pending while its seen_seq lags.
push_seq: std.atomic.Value(u32) = .init(0),
push_now: std.atomic.Value(bool) = .init(false),
quit: std.atomic.Value(bool) = .init(false),
done: std.atomic.Value(bool) = .init(false),

const Upload = struct { key: []u8, path: []u8 };

pub fn create(allocator: std.mem.Allocator, io: std.Io, backends: []Backend, books_dir: []const u8, book: []const u8, device: []const u8) !*Self {
    const self = try allocator.create(Self);
    self.* = .{
        .allocator = allocator,
        .io = io,
        .backends = backends,
        .books_dir = books_dir,
        .book = book,
        .device = device,
        .notify = undefined,
        .notify_ctx = undefined,
    };
    return self;
}

// The configured backends (allocated in the config arena); empty when sync
// is off or every entry is misconfigured.
pub fn backendsFromConfig(allocator: std.mem.Allocator, io: std.Io, env: *std.process.Environ.Map, config: *Config) []Backend {
    const ca = config.arena.allocator();
    var list: std.ArrayList(Backend) = .empty;
    for (config.sync) |e| {
        if (!e.enabled) continue;
        const store = storeFor(allocator, io, env, ca, e) orelse continue;
        const is_git = std.mem.eql(u8, e.type, "git");
        const debounce_s: i64 = parseDuration(e.debounce) orelse (if (is_git) 3 * 3600 else 10);
        list.append(ca, .{
            .store = store,
            .mode = Mode.parse(e.mode, is_git),
            .debounce_ns = debounce_s * std.time.ns_per_s,
        }) catch break;
    }
    return list.toOwnedSlice(ca) catch &.{};
}

fn expandHome(ca: std.mem.Allocator, env: *std.process.Environ.Map, path: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, path, "~/")) return path;
    const home = env.get("HOME") orelse return null;
    return std.fmt.allocPrint(ca, "{s}/{s}", .{ home, path[2..] }) catch null;
}

fn storeFor(allocator: std.mem.Allocator, io: std.Io, env: *std.process.Environ.Map, ca: std.mem.Allocator, e: Config.SyncEntry) ?Store {
    if (std.mem.eql(u8, e.type, "dir")) {
        if (e.path.len == 0) return null;
        return .{ .dir = StoreMod.DirStore.init(io, expandHome(ca, env, e.path) orelse return null) };
    }
    if (std.mem.eql(u8, e.type, "git")) {
        if (e.dir.len == 0) return null;
        const dir = expandHome(ca, env, e.dir) orelse return null;
        return .{ .git = StoreMod.GitStore.init(allocator, io, env, std.mem.trimEnd(u8, dir, "/"), e.remote) };
    }
    if (std.mem.eql(u8, e.type, "s3")) {
        if (e.bucket.len == 0) return null;
        const access = if (e.access_key.len > 0) e.access_key else (env.get("AWS_ACCESS_KEY_ID") orelse return null);
        const secret = if (e.secret_key.len > 0) e.secret_key else (env.get("AWS_SECRET_ACCESS_KEY") orelse return null);
        const region = if (e.region.len > 0) e.region else (env.get("AWS_REGION") orelse env.get("AWS_DEFAULT_REGION") orelse "us-east-1");
        const endpoint = if (e.endpoint.len > 0) e.endpoint else (std.fmt.allocPrint(ca, "s3.{s}.amazonaws.com", .{region}) catch return null);
        return .{ .s3 = StoreMod.S3Store.init(allocator, io, .{
            .bucket = e.bucket,
            .region = region,
            .endpoint = endpoint,
            .prefix = e.prefix,
            .access_key = access,
            .secret_key = secret,
            .session_token = env.get("AWS_SESSION_TOKEN") orelse "",
            .now = time.nowRealSeconds,
        }) };
    }
    return null;
}

// Fetches every other device's shard and every missing cover for every book
// (one listing), so a fresh device's library shows the whole collection.
// Synchronous; the PDFs themselves come down on demand (fetchBook). `stored`
// collects the books whose PDF the store holds.
pub fn pullAll(allocator: std.mem.Allocator, io: std.Io, store: *Store, books_dir: []const u8, device: []const u8, stored: ?*std.ArrayList([]u8)) !void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const entries = try store.list(a, "books/");
    const cwd = std.Io.Dir.cwd();
    for (entries) |e| {
        // books/<book>/<device>.json | cover.png | book.pdf
        const rel = if (std.mem.startsWith(u8, e.key, "books/")) e.key[6..] else continue;
        const slash = std.mem.indexOfScalar(u8, rel, '/') orelse continue;
        const book = rel[0..slash];
        const name = rel[slash + 1 ..];
        if (std.mem.indexOfScalar(u8, name, '/') != null) continue;
        if (std.mem.eql(u8, name, book_object)) {
            if (stored) |list| try list.append(allocator, try allocator.dupe(u8, book));
            continue;
        }
        if (!std.mem.eql(u8, name, cover_object)) {
            if (!std.mem.endsWith(u8, name, ".json")) continue;
            if (std.mem.eql(u8, name[0 .. name.len - 5], device)) continue;
        }
        const local_path = try std.fmt.allocPrint(a, "{s}/{s}/{s}", .{ books_dir, book, name });
        if (cwd.access(io, local_path, .{})) |_| continue else |_| {}
        const data = (try store.get(a, e.key)) orelse continue;
        try cwd.createDirPath(io, std.fs.path.dirname(local_path).?);
        try fs.writeFileAtomic(io, local_path, data);
    }
}

// Downloads a book's PDF to `dest`; false when the store does not have it.
pub fn fetchBook(allocator: std.mem.Allocator, io: std.Io, store: *Store, book: []const u8, dest: []const u8) !bool {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const key = try std.fmt.allocPrint(a, "books/{s}/{s}", .{ book, book_object });
    const data = (try store.get(a, key)) orelse return false;
    if (!std.mem.startsWith(u8, data, "%PDF")) return error.NotAPdf;
    try fs.writeFileAtomic(io, dest, data);
    return true;
}

pub fn destroy(self: *Self) void {
    for (self.backends) |*b| b.store.deinit();
    for (self.uploads.items) |u| self.freeUpload(u);
    self.uploads.deinit(self.allocator);
    for (self.deletes.items) |k| self.allocator.free(k);
    self.deletes.deinit(self.allocator);
    var it = self.stored.keyIterator();
    while (it.next()) |k| self.allocator.free(k.*);
    self.stored.deinit(self.allocator);
    self.allocator.destroy(self);
}

pub fn allManual(self: *Self) bool {
    for (self.backends) |*b| if (!b.manual()) return false;
    return true;
}

pub fn keepsBooks(self: *Self) bool {
    for (self.backends) |*b| if (b.keepsBooks()) return true;
    return false;
}

// Queues the PDF at `path` (and its cover, if rendered) for every backend
// that keeps books.
pub fn requestUpload(self: *Self, key: []const u8, path: []const u8) !void {
    const k = try self.allocator.dupe(u8, key);
    errdefer self.allocator.free(k);
    const p = try self.allocator.dupe(u8, path);
    errdefer self.allocator.free(p);
    self.mu.lockUncancelable(self.io);
    defer self.mu.unlock(self.io);
    try self.uploads.append(self.allocator, .{ .key = k, .path = p });
}

// Removes a book's PDF and cover from every backend; the records stay.
pub fn requestDelete(self: *Self, key: []const u8) !void {
    const k = try self.allocator.dupe(u8, key);
    errdefer self.allocator.free(k);
    self.mu.lockUncancelable(self.io);
    defer self.mu.unlock(self.io);
    try self.deletes.append(self.allocator, k);
}

pub fn inStore(self: *Self, key: []const u8) bool {
    self.mu.lockUncancelable(self.io);
    defer self.mu.unlock(self.io);
    return self.stored.contains(key);
}

// Queued or in flight.
pub fn uploading(self: *Self, key: []const u8) bool {
    self.mu.lockUncancelable(self.io);
    defer self.mu.unlock(self.io);
    if (self.active_upload) |k| if (std.mem.eql(u8, k, key)) return true;
    for (self.uploads.items) |u| if (std.mem.eql(u8, u.key, key)) return true;
    return false;
}

fn freeUpload(self: *Self, u: Upload) void {
    self.allocator.free(u.key);
    self.allocator.free(u.path);
}

fn unmarkStored(self: *Self, key: []const u8) void {
    self.mu.lockUncancelable(self.io);
    defer self.mu.unlock(self.io);
    if (self.stored.fetchRemove(key)) |kv| self.allocator.free(kv.key);
}

fn markStored(self: *Self, key: []const u8) void {
    self.mu.lockUncancelable(self.io);
    defer self.mu.unlock(self.io);
    if (self.stored.contains(key)) return;
    const k = self.allocator.dupe(u8, key) catch return;
    self.stored.put(self.allocator, k, {}) catch self.allocator.free(k);
}

pub fn start(self: *Self, notify: Notify, ctx: *anyopaque) !void {
    self.notify = notify;
    self.notify_ctx = ctx;
    if (!self.allManual()) self.want_pull.store(1, .release);
    const thread = try std.Thread.spawn(.{}, worker, .{self});
    thread.detach();
}

pub fn requestPull(self: *Self) void {
    self.want_pull.store(2, .release);
}

// Refresh the whole library index from the automatic backends.
pub fn requestIndex(self: *Self) void {
    self.want_index.store(true, .release);
}

pub fn requestPush(self: *Self, immediate: bool) void {
    _ = self.push_seq.fetchAdd(1, .release);
    if (immediate) self.push_now.store(true, .release);
}

// Asks the worker to flush a pending push and exit; waits at most `max_ns`
// so a dead network can't hang quit. False if the worker is still running:
// the caller must then leak this object rather than free it under the thread.
pub fn stop(self: *Self, max_ns: i64) bool {
    self.quit.store(true, .release);
    const deadline = time.nowNs() + max_ns;
    while (!self.done.load(.acquire) and time.nowNs() < deadline) {
        time.sleep(20 * std.time.ns_per_ms);
    }
    return self.done.load(.acquire);
}

fn worker(self: *Self) void {
    while (true) {
        const quitting = self.quit.load(.acquire);
        const scope = self.want_pull.swap(0, .acq_rel);
        if (scope != 0 and !quitting) self.pullBackends(scope == 2);
        if (self.want_index.swap(false, .acq_rel) and !quitting) self.indexBackends();
        if (!quitting) self.uploadRequested();
        if (!quitting) self.deleteRequested();
        const seq = self.push_seq.load(.acquire);
        const now_flag = self.push_now.swap(false, .acq_rel);
        for (self.backends) |*b| {
            if (b.seen_seq == seq) continue;
            const due = switch (b.mode) {
                .manual => now_flag,
                .open_close => quitting or now_flag,
                .periodic => quitting or now_flag or time.nowNs() - b.last_push >= b.debounce_ns,
            };
            if (!due) continue;
            b.seen_seq = seq;
            if (self.pushBackend(b)) self.report(.pushed) else |e| self.reportBackendError(b, e);
            b.last_push = time.nowNs();
        }
        if (quitting) break;
        time.sleep(250 * std.time.ns_per_ms);
    }
    self.done.store(true, .release);
}

fn report(self: *Self, r: Result) void {
    // After stop() the event loop may be gone; results of the flush are dropped.
    if (self.quit.load(.acquire)) return;
    self.notify(self.notify_ctx, r);
}

fn reportBackendError(self: *Self, b: *Backend, e: anyerror) void {
    var msg: ErrText = .{};
    const reason = switch (b.store) {
        .git => |*g| g.reason(),
        else => "",
    };
    const text = if (reason.len > 0)
        std.fmt.bufPrint(&msg.buf, "{s}: {s} ({s})", .{ b.name(), @errorName(e), reason }) catch &msg.buf
    else
        std.fmt.bufPrint(&msg.buf, "{s}: {s}", .{ b.name(), @errorName(e) }) catch &msg.buf;
    msg.len = @intCast(text.len);
    self.report(.{ .err = msg });
}

fn pullBackends(self: *Self, include_manual: bool) void {
    var changed = false;
    for (self.backends) |*b| {
        if (b.manual() and !include_manual) continue;
        const c = self.pull(b) catch |e| {
            self.reportBackendError(b, e);
            continue;
        };
        changed = changed or c;
    }
    self.report(.{ .pulled = changed });
}

fn indexBackends(self: *Self) void {
    var stored: std.ArrayList([]u8) = .empty;
    defer {
        for (stored.items) |k| self.allocator.free(k);
        stored.deinit(self.allocator);
    }
    for (self.backends) |*b| {
        if (b.manual()) continue;
        pullAll(self.allocator, self.io, &b.store, self.books_dir, self.device, if (b.keepsBooks()) &stored else null) catch |e| self.reportBackendError(b, e);
    }
    for (stored.items) |k| self.markStored(k);
    self.report(.indexed);
}

fn uploadRequested(self: *Self) void {
    while (true) {
        self.mu.lockUncancelable(self.io);
        const next = self.uploads.pop();
        if (next) |u| self.active_upload = u.key;
        self.mu.unlock(self.io);
        const u = next orelse return;
        defer {
            self.mu.lockUncancelable(self.io);
            self.active_upload = null;
            self.mu.unlock(self.io);
            self.freeUpload(u);
        }
        for (self.backends) |*b| {
            if (!b.keepsBooks()) continue;
            if (self.upload(b, u)) {
                self.markStored(u.key);
                var msg: ErrText = .{};
                const name = b.name();
                msg.len = @intCast(@min(name.len, msg.buf.len));
                @memcpy(msg.buf[0..msg.len], name[0..msg.len]);
                self.report(.{ .uploaded = msg });
            } else |e| self.reportBackendError(b, e);
        }
    }
}

fn deleteRequested(self: *Self) void {
    while (true) {
        self.mu.lockUncancelable(self.io);
        const next = self.deletes.pop();
        self.mu.unlock(self.io);
        const key = next orelse return;
        defer self.allocator.free(key);
        self.unmarkStored(key);
        var ok = true;
        for (self.backends) |*b| {
            deleteBook(b, key) catch |e| {
                ok = false;
                self.reportBackendError(b, e);
            };
        }
        if (ok) self.report(.deleted);
    }
}

fn deleteBook(b: *Backend, key: []const u8) !void {
    if (!b.keepsBooks()) return;
    var buf: [1024]u8 = undefined;
    try b.store.delete(try std.fmt.bufPrint(&buf, "books/{s}/{s}", .{ key, book_object }));
    try b.store.delete(try std.fmt.bufPrint(&buf, "books/{s}/{s}", .{ key, cover_object }));
    try b.store.flush();
}

fn upload(self: *Self, b: *Backend, u: Upload) !void {
    var arena = std.heap.ArenaAllocator.init(self.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cwd = std.Io.Dir.cwd();
    const cover = try std.fmt.allocPrint(a, "{s}/{s}/{s}", .{ self.books_dir, u.key, cover_object });
    if (cwd.readFileAlloc(self.io, cover, a, .limited(max_cover_bytes)) catch null) |png| {
        try b.store.put(try std.fmt.allocPrint(a, "books/{s}/{s}", .{ u.key, cover_object }), png);
    }
    const data = try cwd.readFileAlloc(self.io, u.path, a, .limited(max_book_bytes));
    try b.store.put(try std.fmt.allocPrint(a, "books/{s}/{s}", .{ u.key, book_object }), data);
    try b.store.flush();
}

// New or changed shards of the other devices, into the local books dir;
// true when something changed.
fn pull(self: *Self, b: *Backend) !bool {
    var arena = std.heap.ArenaAllocator.init(self.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const prefix = try std.fmt.allocPrint(a, "books/{s}/", .{self.book});
    const entries = try b.store.list(a, prefix);
    const cwd = std.Io.Dir.cwd();
    const local_dir = try std.fmt.allocPrint(a, "{s}/{s}", .{ self.books_dir, self.book });
    var changed = false;
    for (entries) |e| {
        const name = std.fs.path.basename(e.key);
        if (!std.mem.endsWith(u8, name, ".json")) continue;
        if (std.mem.eql(u8, name[0 .. name.len - 5], self.device)) continue;
        const data = (try b.store.get(a, e.key)) orelse continue;
        const local_path = try std.fmt.allocPrint(a, "{s}/{s}", .{ local_dir, name });
        if (cwd.readFileAlloc(self.io, local_path, a, .limited(4 * 1024 * 1024)) catch null) |existing| {
            if (std.mem.eql(u8, existing, data)) continue;
        }
        try cwd.createDirPath(self.io, local_dir);
        try fs.writeFileAtomic(self.io, local_path, data);
        changed = true;
    }
    return changed;
}

fn pushBackend(self: *Self, b: *Backend) !void {
    var arena = std.heap.ArenaAllocator.init(self.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const local_path = try std.fmt.allocPrint(a, "{s}/{s}/{s}.json", .{ self.books_dir, self.book, self.device });
    const data = std.Io.Dir.cwd().readFileAlloc(self.io, local_path, a, .limited(4 * 1024 * 1024)) catch return;
    const key = try std.fmt.allocPrint(a, "books/{s}/{s}.json", .{ self.book, self.device });
    try b.store.put(key, data);
    try b.store.flush();
}

// Uploads this device's record of every book (`re state sync`); returns
// how many went up.
pub fn pushAll(allocator: std.mem.Allocator, io: std.Io, b: *Backend, books_dir: []const u8, device: []const u8) !usize {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cwd = std.Io.Dir.cwd();
    var root = cwd.openDir(io, books_dir, .{ .iterate = true }) catch return 0;
    defer root.close(io);
    var count: usize = 0;
    var it = root.iterate();
    while (it.next(io) catch null) |entry| {
        if (entry.kind != .directory) continue;
        const local_path = try std.fmt.allocPrint(a, "{s}/{s}/{s}.json", .{ books_dir, entry.name, device });
        const data = cwd.readFileAlloc(io, local_path, a, .limited(4 * 1024 * 1024)) catch continue;
        const key = try std.fmt.allocPrint(a, "books/{s}/{s}.json", .{ entry.name, device });
        try b.store.put(key, data);
        count += 1;
    }
    try b.store.flush();
    return count;
}

// Everything under books/<key>/ in one backend (`re state purge`).
pub fn purge(allocator: std.mem.Allocator, store: *Store, key: []const u8) !usize {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const prefix = try std.fmt.allocPrint(a, "books/{s}/", .{key});
    const entries = try store.list(a, prefix);
    for (entries) |e| try store.delete(e.key);
    try store.flush();
    return entries.len;
}
