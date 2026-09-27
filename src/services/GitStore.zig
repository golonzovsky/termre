// A folder inside a git repository as the store (e.g. `~/dotfiles/termre`).
// Only that folder is ever staged or committed; pull uses rebase+autostash so
// unrelated work in the repo is left alone. Manual: nothing runs until the
// user asks (`:sync`, `re state sync`).
const Self = @This();
const std = @import("std");
const Entry = @import("Store.zig").Entry;
const DirStore = @import("DirStore.zig");

allocator: std.mem.Allocator,
io: std.Io,
env: *std.process.Environ.Map,
dir: []const u8,
remote: []const u8,
files: DirStore,
dirty: bool = false,

pub fn init(allocator: std.mem.Allocator, io: std.Io, env: *std.process.Environ.Map, dir: []const u8, remote: []const u8) Self {
    return .{ .allocator = allocator, .io = io, .env = env, .dir = dir, .remote = remote, .files = DirStore.init(io, dir) };
}

pub fn deinit(_: *Self) void {}

pub fn manual(_: *Self) bool {
    return true;
}

// A listing is what every pull starts with: bring the repo up to date first.
pub fn list(self: *Self, a: std.mem.Allocator, prefix: []const u8) ![]Entry {
    try self.ensureRepo();
    // A fresh (empty) repo has nothing to pull from yet.
    if (self.hasUpstream()) {
        try self.git(&.{ "pull", "--quiet", "--rebase", "--autostash" }, error.GitPullFailed);
    }
    return self.files.list(a, prefix);
}

pub fn get(self: *Self, a: std.mem.Allocator, key: []const u8) !?[]u8 {
    return self.files.get(a, key);
}

pub fn put(self: *Self, key: []const u8, data: []const u8) !void {
    try self.ensureRepo();
    try self.files.put(key, data);
    self.dirty = true;
}

// Commit everything written since the last flush (only under our folder)
// and push if the repo has a remote.
pub fn flush(self: *Self) !void {
    if (!self.dirty) return;
    self.dirty = false;
    try self.git(&.{ "add", "-A", "--", "." }, error.GitAddFailed);
    // Nothing staged under our folder -> commit would fail; check first.
    if (self.gitOk(&.{ "diff", "--cached", "--quiet", "--", "." })) return;
    try self.git(&.{ "commit", "--quiet", "-m", "termre: reading state", "--", "." }, error.GitCommitFailed);
    // -u so the first push of a fresh clone sets the upstream.
    if (self.hasRemote()) try self.git(&.{ "push", "--quiet", "-u", "origin", "HEAD" }, error.GitPushFailed);
}

// The folder must be inside a repository. Missing folder: created when its
// parent already is a work tree (a new folder in dotfiles), else cloned
// from `remote` (a dedicated state repo).
fn ensureRepo(self: *Self) !void {
    const cwd = std.Io.Dir.cwd();
    if (cwd.access(self.io, self.dir, .{})) |_| {
        if (!self.gitOk(&.{ "rev-parse", "--is-inside-work-tree" })) return error.GitNotARepo;
        return;
    } else |_| {}
    if (std.fs.path.dirname(self.dir)) |parent| {
        if (cwd.access(self.io, parent, .{})) |_| {
            if (self.gitOkIn(parent, &.{ "rev-parse", "--is-inside-work-tree" })) {
                try cwd.createDirPath(self.io, self.dir);
                return;
            }
        } else |_| {}
    }
    if (self.remote.len == 0) return error.GitDirMissing;
    if (std.fs.path.dirname(self.dir)) |parent| cwd.createDirPath(self.io, parent) catch {};
    var child = std.process.spawn(self.io, .{
        .argv = &.{ "git", "clone", "--quiet", self.remote, self.dir },
        .environ_map = self.env,
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    }) catch return error.GitNotFound;
    const term = child.wait(self.io) catch return error.GitCloneFailed;
    if (term != .exited or term.exited != 0) return error.GitCloneFailed;
}

fn hasRemote(self: *Self) bool {
    return self.gitOk(&.{ "config", "--get", "remote.origin.url" });
}

fn hasUpstream(self: *Self) bool {
    return self.gitOk(&.{ "rev-parse", "--abbrev-ref", "@{upstream}" });
}

fn git(self: *Self, args: []const []const u8, fail: anyerror) !void {
    if (!self.gitOk(args)) return fail;
}

// Runs git inside our folder; true on exit 0.
fn gitOk(self: *Self, args: []const []const u8) bool {
    return self.gitOkIn(self.dir, args);
}

fn gitOkIn(self: *Self, dir: []const u8, args: []const []const u8) bool {
    var argv: [16][]const u8 = undefined;
    argv[0] = "git";
    if (args.len + 1 > argv.len) return false;
    for (args, 0..) |arg, i| argv[i + 1] = arg;
    var child = std.process.spawn(self.io, .{
        .argv = argv[0 .. args.len + 1],
        .environ_map = self.env,
        .cwd = .{ .path = dir },
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    }) catch return false;
    const term = child.wait(self.io) catch return false;
    return term == .exited and term.exited == 0;
}
