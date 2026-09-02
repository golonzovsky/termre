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

pub const Result = union(enum) {
    // true when at least one remote shard was new or changed locally.
    pulled: bool,
    pushed,
    err: []const u8,
};

pub const Notify = *const fn (ctx: *anyopaque, result: Result) void;

allocator: std.mem.Allocator,
io: std.Io,
store: Store,
books_dir: []const u8,
book: []const u8, // directory/object name of the book
device: []const u8,
debounce_ns: i64,
notify: Notify,
notify_ctx: *anyopaque,

want_pull: std.atomic.Value(bool) = .init(false),
want_push: std.atomic.Value(bool) = .init(false),
push_now: std.atomic.Value(bool) = .init(false),
quit: std.atomic.Value(bool) = .init(false),
done: std.atomic.Value(bool) = .init(false),
err_buf: [160]u8 = undefined,

pub fn create(allocator: std.mem.Allocator, io: std.Io, store: Store, books_dir: []const u8, book: []const u8, device: []const u8, debounce_s: u16) !*Self {
    const self = try allocator.create(Self);
    self.* = .{
        .allocator = allocator,
        .io = io,
        .store = store,
        .books_dir = books_dir,
        .book = book,
        .device = device,
        .debounce_ns = @as(i64, debounce_s) * std.time.ns_per_s,
        .notify = undefined,
        .notify_ctx = undefined,
    };
    return self;
}

// The external store from config, or null when sync is off/misconfigured.
pub fn storeFromConfig(allocator: std.mem.Allocator, io: std.Io, env: *std.process.Environ.Map, config: *Config) ?Store {
    const s = config.sync;
    const ca = config.arena.allocator();
    if (std.mem.eql(u8, s.backend, "dir")) {
        if (s.dir_path.len == 0) return null;
        var root = s.dir_path;
        if (std.mem.startsWith(u8, root, "~/")) {
            const home = env.get("HOME") orelse return null;
            root = std.fmt.allocPrint(ca, "{s}/{s}", .{ home, root[2..] }) catch return null;
        }
        return .{ .dir = StoreMod.DirStore.init(io, root) };
    }
    if (std.mem.eql(u8, s.backend, "s3")) {
        if (s.s3_bucket.len == 0) return null;
        const access = if (s.s3_access_key.len > 0) s.s3_access_key else (env.get("AWS_ACCESS_KEY_ID") orelse return null);
        const secret = if (s.s3_secret_key.len > 0) s.s3_secret_key else (env.get("AWS_SECRET_ACCESS_KEY") orelse return null);
        const region = if (s.s3_region.len > 0) s.s3_region else (env.get("AWS_REGION") orelse env.get("AWS_DEFAULT_REGION") orelse "us-east-1");
        const endpoint = if (s.s3_endpoint.len > 0) s.s3_endpoint else (std.fmt.allocPrint(ca, "s3.{s}.amazonaws.com", .{region}) catch return null);
        return .{ .s3 = StoreMod.S3Store.init(allocator, io, .{
            .bucket = s.s3_bucket,
            .region = region,
            .endpoint = endpoint,
            .prefix = s.s3_prefix,
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
    self.store.deinit();
    self.allocator.destroy(self);
}

pub fn start(self: *Self, notify: Notify, ctx: *anyopaque) !void {
    self.notify = notify;
    self.notify_ctx = ctx;
    self.want_pull.store(true, .release);
    const thread = try std.Thread.spawn(.{}, worker, .{self});
    thread.detach();
}

pub fn requestPull(self: *Self) void {
    self.want_pull.store(true, .release);
}

pub fn requestPush(self: *Self, immediate: bool) void {
    self.want_push.store(true, .release);
    if (immediate) self.push_now.store(true, .release);
}

// Asks the worker to flush a pending push and exit; waits at most `max_ns`
// so a dead network can't hang quit.
pub fn stop(self: *Self, max_ns: i64) void {
    self.quit.store(true, .release);
    const deadline = time.nowNs() + max_ns;
    while (!self.done.load(.acquire) and time.nowNs() < deadline) {
        time.sleep(20 * std.time.ns_per_ms);
    }
}

fn worker(self: *Self) void {
    var last_push: i64 = 0;
    while (true) {
        const quitting = self.quit.load(.acquire);
        if (self.want_pull.swap(false, .acq_rel) and !quitting) {
            self.report(self.pull());
        }
        if (self.want_push.load(.acquire)) {
            const due = quitting or self.push_now.load(.acquire) or time.nowNs() - last_push >= self.debounce_ns;
            if (due) {
                self.want_push.store(false, .release);
                self.push_now.store(false, .release);
                self.report(self.push());
                last_push = time.nowNs();
            }
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

fn pull(self: *Self) !Result {
    var arena = std.heap.ArenaAllocator.init(self.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const prefix = try std.fmt.allocPrint(a, "books/{s}/", .{self.book});
    const entries = try self.store.list(a, prefix);
    const cwd = std.Io.Dir.cwd();
    const local_dir = try std.fmt.allocPrint(a, "{s}/{s}", .{ self.books_dir, self.book });
    var changed = false;
    for (entries) |e| {
        const name = std.fs.path.basename(e.key);
        if (!std.mem.endsWith(u8, name, ".json")) continue;
        if (std.mem.eql(u8, name[0 .. name.len - 5], self.device)) continue;
        const data = (try self.store.get(a, e.key)) orelse continue;
        const local_path = try std.fmt.allocPrint(a, "{s}/{s}", .{ local_dir, name });
        if (cwd.readFileAlloc(self.io, local_path, a, .limited(4 * 1024 * 1024)) catch null) |existing| {
            if (std.mem.eql(u8, existing, data)) continue;
        }
        try cwd.createDirPath(self.io, local_dir);
        try writeAtomic(a, self.io, local_path, data);
        changed = true;
    }
    return .{ .pulled = changed };
}

fn push(self: *Self) !Result {
    var arena = std.heap.ArenaAllocator.init(self.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const local_path = try std.fmt.allocPrint(a, "{s}/{s}/{s}.json", .{ self.books_dir, self.book, self.device });
    const data = std.Io.Dir.cwd().readFileAlloc(self.io, local_path, a, .limited(4 * 1024 * 1024)) catch return .pushed;
    const key = try std.fmt.allocPrint(a, "books/{s}/{s}.json", .{ self.book, self.device });
    try self.store.put(key, data);
    return .pushed;
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
