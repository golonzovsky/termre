// Background sync of one book's shards with the external store. A worker
// thread pulls the other devices' shards into the local books directory and
// pushes this device's shard (debounced); results are handed back through
// `notify`, called on the worker thread.
const Self = @This();
const std = @import("std");
const Store = @import("Store.zig").Store;
const StoreMod = @import("Store.zig");
const Config = @import("../config/Config.zig");
const time = @import("../utilities/time.zig");
const parseDuration = @import("../utilities/duration.zig").parse;

pub const Result = union(enum) {
    // true when at least one remote shard was new or changed locally.
    pulled: bool,
    pushed,
    err: []const u8,
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
};

allocator: std.mem.Allocator,
io: std.Io,
backends: []Backend,
books_dir: []const u8,
book: []const u8, // directory/object name of the book
device: []const u8,
notify: Notify,
notify_ctx: *anyopaque,

// 0 none, 1 automatic backends only (open), 2 all (`:sync`).
want_pull: std.atomic.Value(u8) = .init(0),
// Bumped per push request; a backend is pending while its seen_seq lags.
push_seq: std.atomic.Value(u32) = .init(0),
push_now: std.atomic.Value(bool) = .init(false),
quit: std.atomic.Value(bool) = .init(false),
done: std.atomic.Value(bool) = .init(false),
err_buf: [160]u8 = undefined,

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
        list.append(ca, .{ .store = store, .mode = Mode.parse(e.mode, is_git), .debounce_ns = debounce_s * std.time.ns_per_s }) catch break;
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

// Fetches every other device's shard for every book (one listing), so a
// fresh device's recent-books picker shows the whole library. Synchronous.
pub fn pullAll(allocator: std.mem.Allocator, io: std.Io, store: *Store, books_dir: []const u8, device: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const entries = try store.list(a, "books/");
    const cwd = std.Io.Dir.cwd();
    for (entries) |e| {
        // books/<book>/<device>.json
        const rel = if (std.mem.startsWith(u8, e.key, "books/")) e.key[6..] else continue;
        const slash = std.mem.indexOfScalar(u8, rel, '/') orelse continue;
        const book = rel[0..slash];
        const name = rel[slash + 1 ..];
        if (!std.mem.endsWith(u8, name, ".json") or std.mem.indexOfScalar(u8, name, '/') != null) continue;
        if (std.mem.eql(u8, name[0 .. name.len - 5], device)) continue;
        const local_path = try std.fmt.allocPrint(a, "{s}/{s}/{s}", .{ books_dir, book, name });
        if (cwd.access(io, local_path, .{})) |_| continue else |_| {}
        const data = (try store.get(a, e.key)) orelse continue;
        try cwd.createDirPath(io, std.fs.path.dirname(local_path).?);
        try writeAtomic(a, io, local_path, data);
    }
}

pub fn destroy(self: *Self) void {
    for (self.backends) |*b| b.store.deinit();
    self.allocator.destroy(self);
}

pub fn allManual(self: *Self) bool {
    for (self.backends) |*b| if (!b.manual()) return false;
    return true;
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
            self.report(self.pushBackend(b));
            b.last_push = time.nowNs();
        }
        if (quitting) break;
        time.sleep(250 * std.time.ns_per_ms);
    }
    self.done.store(true, .release);
}

fn report(self: *Self, r: anyerror!Result) void {
    // After stop() the event loop may be gone; results of the flush are dropped.
    if (self.quit.load(.acquire)) return;
    if (r) |ok| {
        self.notify(self.notify_ctx, ok);
    } else |e| {
        const msg = std.fmt.bufPrint(&self.err_buf, "{s}", .{@errorName(e)}) catch "error";
        self.notify(self.notify_ctx, .{ .err = msg });
    }
}

fn reportBackendError(self: *Self, b: *Backend, e: anyerror) void {
    if (self.quit.load(.acquire)) return;
    const msg = std.fmt.bufPrint(&self.err_buf, "{s}: {s}", .{ b.name(), @errorName(e) }) catch "error";
    self.notify(self.notify_ctx, .{ .err = msg });
}

fn pullBackends(self: *Self, include_manual: bool) void {
    var changed = false;
    for (self.backends) |*b| {
        if (b.manual() and !include_manual) continue;
        if (self.pull(&b.store)) |c| {
            changed = changed or c;
        } else |e| self.reportBackendError(b, e);
    }
    self.report(.{ .pulled = changed });
}

// New or changed shards of the other devices, into the local books dir.
fn pull(self: *Self, store: *Store) !bool {
    var arena = std.heap.ArenaAllocator.init(self.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const prefix = try std.fmt.allocPrint(a, "books/{s}/", .{self.book});
    const entries = try store.list(a, prefix);
    const cwd = std.Io.Dir.cwd();
    const local_dir = try std.fmt.allocPrint(a, "{s}/{s}", .{ self.books_dir, self.book });
    var changed = false;
    for (entries) |e| {
        const name = std.fs.path.basename(e.key);
        if (!std.mem.endsWith(u8, name, ".json")) continue;
        if (std.mem.eql(u8, name[0 .. name.len - 5], self.device)) continue;
        const data = (try store.get(a, e.key)) orelse continue;
        const local_path = try std.fmt.allocPrint(a, "{s}/{s}", .{ local_dir, name });
        if (cwd.readFileAlloc(self.io, local_path, a, .limited(4 * 1024 * 1024)) catch null) |existing| {
            if (std.mem.eql(u8, existing, data)) continue;
        }
        try cwd.createDirPath(self.io, local_dir);
        try writeAtomic(a, self.io, local_path, data);
        changed = true;
    }
    return changed;
}

fn pushBackend(self: *Self, b: *Backend) !Result {
    var arena = std.heap.ArenaAllocator.init(self.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const local_path = try std.fmt.allocPrint(a, "{s}/{s}/{s}.json", .{ self.books_dir, self.book, self.device });
    const data = std.Io.Dir.cwd().readFileAlloc(self.io, local_path, a, .limited(4 * 1024 * 1024)) catch return .pushed;
    const key = try std.fmt.allocPrint(a, "books/{s}/{s}.json", .{ self.book, self.device });
    b.store.put(key, data) catch |e| {
        self.reportBackendError(b, e);
        return error.SyncFailed;
    };
    b.store.flush() catch |e| {
        self.reportBackendError(b, e);
        return error.SyncFailed;
    };
    return .pushed;
}

// Uploads this device's record of every book (`re state sync`).
pub fn pushAll(allocator: std.mem.Allocator, io: std.Io, store: *Store, books_dir: []const u8, device: []const u8) !usize {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cwd = std.Io.Dir.cwd();
    var root = cwd.openDir(io, books_dir, .{ .iterate = true }) catch return 0;
    defer root.close(io);
    var n: usize = 0;
    var it = root.iterate();
    while (it.next(io) catch null) |entry| {
        if (entry.kind != .directory) continue;
        const local_path = try std.fmt.allocPrint(a, "{s}/{s}/{s}.json", .{ books_dir, entry.name, device });
        const data = cwd.readFileAlloc(io, local_path, a, .limited(4 * 1024 * 1024)) catch continue;
        const key = try std.fmt.allocPrint(a, "books/{s}/{s}.json", .{ entry.name, device });
        try store.put(key, data);
        n += 1;
    }
    try store.flush();
    return n;
}

fn writeAtomic(a: std.mem.Allocator, io: std.Io, path: []const u8, data: []const u8) !void {
    const cwd = std.Io.Dir.cwd();
    const tmp = try std.fmt.allocPrint(a, "{s}.tmp", .{path});
    {
        var file = try cwd.createFile(io, tmp, .{});
        defer file.close(io);
        var buf: [4096]u8 = undefined;
        var fw = file.writer(io, &buf);
        try fw.interface.writeAll(data);
        try fw.interface.flush();
    }
    try std.Io.Dir.renameAbsolute(tmp, path, io);
}
