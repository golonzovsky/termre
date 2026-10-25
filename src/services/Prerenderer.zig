//! Background page prerenderer. A single worker thread renders neighbor pages
//! (mupdf + encode — the expensive part) so page crossings hit the cache.
//! The main thread builds each job (cache key + RenderParams) from its view
//! state; the worker touches only Document.render. The kitty transmit must
//! stay on the main thread: finished results are parked here and the main
//! loop claims them on the `prerender_ready` event.
const Self = @This();
const std = @import("std");
const Cache = @import("../Cache.zig");
const PdfHandler = @import("../handlers/PdfHandler.zig");
const Exporter = PdfHandler.Exporter;
const types = PdfHandler.types;
const Context = @import("../Context.zig").Context;

// Quad slices in `params` are owned by the job (see PdfHandler.freeParams).
pub const Job = struct {
    key: Cache.Key,
    params: PdfHandler.RenderParams,
};

pub const Result = struct {
    key: Cache.Key,
    image: types.EncodedImage,
};

// Grid-mode thumbnails rendered off-thread; max_w identifies the grid zoom
// the render was for, so stale sizes get discarded on arrival.
pub const ThumbResult = struct {
    page: u16,
    max_w: u32,
    image: types.EncodedImage,
};

pub const thumb_slots = 24;

// Fixed-capacity handoff from the worker to the main thread. Caller holds the
// mutex for park/claim.
fn Mailbox(comptime T: type, comptime n: usize) type {
    return struct {
        slots: [n]?*T = @splat(null),

        // Parks into the first free slot, or evicts the oldest (slot 0) and
        // shifts down when full, so the newest result is always kept.
        fn park(self: *@This(), owner: *Self, result: *T) void {
            for (&self.slots) |*slot| {
                if (slot.* == null) {
                    slot.* = result;
                    return;
                }
            }
            owner.freeResult(self.slots[0].?);
            var i: usize = 0;
            while (i + 1 < n) : (i += 1) self.slots[i] = self.slots[i + 1];
            self.slots[n - 1] = result;
        }

        // Hands parked results to the caller, which takes ownership.
        fn claim(self: *@This()) [n]?*T {
            defer self.slots = @splat(null);
            return self.slots;
        }

        fn freeAll(self: *@This(), owner: *Self) void {
            for (self.claim()) |slot| if (slot) |r| owner.freeResult(r);
        }
    };
}

// Render-ahead window: up to this many neighbor pages (e.g. +1..+3, -1..-3)
// are prerendered per request. render_mutex serializes the actual renders, so
// the worker just churns through them in priority order in the background.
pub const slots = 6;

context: *Context,
thread: ?std.Thread,
mutex: std.Io.Mutex,
cond: std.Io.Condition,
quit: bool,
req_jobs: [slots]?Job,
has_req: bool,
results: Mailbox(Result, slots),
thumb_reqs: [thumb_slots]?u16,
thumb_params: ?PdfHandler.RenderParams,
has_thumb_req: bool,
thumb_results: Mailbox(ThumbResult, thumb_slots),

pub fn init() Self {
    return .{
        .context = undefined,
        .thread = null,
        .mutex = .init,
        .cond = .init,
        .quit = false,
        .req_jobs = @splat(null),
        .has_req = false,
        .results = .{},
        .thumb_reqs = @splat(null),
        .thumb_params = null,
        .has_thumb_req = false,
        .thumb_results = .{},
    };
}

pub fn start(self: *Self) !void {
    if (self.thread != null) return;
    self.thread = try std.Thread.spawn(.{}, run, .{self});
}

pub fn stop(self: *Self) void {
    if (self.thread == null) return;
    const io = self.context.io;
    {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        self.quit = true;
        self.cond.signal(io);
    }
    self.thread.?.join();
    self.thread = null;
}

pub fn deinit(self: *Self) void {
    self.stop();
    self.results.freeAll(self);
    self.thumb_results.freeAll(self);
    self.freeJobs(&self.req_jobs);
    self.freeThumbParams();
}

fn freeJobs(self: *Self, jobs: *[slots]?Job) void {
    for (jobs) |*slot| {
        if (slot.*) |j| PdfHandler.freeParams(self.context.allocator, j.params);
        slot.* = null;
    }
}

fn freeThumbParams(self: *Self) void {
    if (self.thumb_params) |p| PdfHandler.freeParams(self.context.allocator, p);
    self.thumb_params = null;
}

fn freeResult(self: *Self, r: anytype) void {
    const a = self.context.allocator;
    // Never transmitted: the terminal won't clean up its backing store.
    Exporter.delete(self.context.io, r.image);
    a.free(r.image.data);
    a.destroy(r);
}

// Latest request wins; pending older requests are coalesced away. Takes
// ownership of the jobs' params.
pub fn request(self: *Self, jobs: [slots]?Job) void {
    var incoming = jobs;
    if (self.thread == null) {
        self.freeJobs(&incoming);
        return;
    }
    const io = self.context.io;
    self.mutex.lockUncancelable(io);
    defer self.mutex.unlock(io);
    self.freeJobs(&self.req_jobs);
    self.req_jobs = incoming;
    self.has_req = true;
    self.cond.signal(io);
}

pub fn requestThumbs(self: *Self, pages: [thumb_slots]?u16, w: u32, h: u32) bool {
    if (self.thread == null) return false;
    const params = self.context.document_handler.thumbParams(self.context.allocator, w, h) catch return false;
    const io = self.context.io;
    self.mutex.lockUncancelable(io);
    defer self.mutex.unlock(io);
    self.freeThumbParams();
    self.thumb_reqs = pages;
    self.thumb_params = params;
    self.has_thumb_req = true;
    self.cond.signal(io);
    return true;
}

pub fn claimThumbs(self: *Self) [thumb_slots]?*ThumbResult {
    const io = self.context.io;
    self.mutex.lockUncancelable(io);
    defer self.mutex.unlock(io);
    return self.thumb_results.claim();
}

pub fn claim(self: *Self) [slots]?*Result {
    const io = self.context.io;
    self.mutex.lockUncancelable(io);
    defer self.mutex.unlock(io);
    return self.results.claim();
}

fn run(self: *Self) void {
    const io = self.context.io;
    const doc = &self.context.document_handler.doc;
    while (true) {
        self.mutex.lockUncancelable(io);
        while (!self.quit and !self.has_req and !self.has_thumb_req) self.cond.waitUncancelable(io, &self.mutex);
        if (self.quit) {
            self.mutex.unlock(io);
            return;
        }
        var jobs: [slots]?Job = @splat(null);
        if (self.has_req) {
            jobs = self.req_jobs;
            self.req_jobs = @splat(null);
        }
        self.has_req = false;
        var thumbs: [thumb_slots]?u16 = @splat(null);
        var thumb_params: ?PdfHandler.RenderParams = null;
        if (self.has_thumb_req) {
            thumbs = self.thumb_reqs;
            thumb_params = self.thumb_params;
            self.thumb_params = null;
        }
        self.has_thumb_req = false;
        self.mutex.unlock(io);
        defer self.freeJobs(&jobs);
        defer if (thumb_params) |p| PdfHandler.freeParams(self.context.allocator, p);

        for (jobs) |maybe_job| {
            const job = maybe_job orelse continue;
            const encoded = doc.render(job.key.page, job.params) catch continue;
            const result = self.context.allocator.create(Result) catch {
                Exporter.delete(io, encoded);
                self.context.allocator.free(encoded.data);
                continue;
            };
            result.* = .{ .key = job.key, .image = encoded };

            self.mutex.lockUncancelable(io);
            if (self.quit) {
                self.mutex.unlock(io);
                self.freeResult(result);
                return;
            }
            self.results.park(self, result);
            // A newer request arrived mid-batch: drop the rest of this one.
            const superseded = self.has_req;
            self.mutex.unlock(io);

            if (self.context.loop) |loop| loop.postEvent(.prerender_ready) catch {};
            if (superseded) break;
        }

        const tp = thumb_params orelse continue;
        for (thumbs) |maybe_page| {
            const page = maybe_page orelse continue;
            const encoded = doc.renderOnce(page, tp) catch continue;
            const result = self.context.allocator.create(ThumbResult) catch {
                Exporter.delete(io, encoded);
                self.context.allocator.free(encoded.data);
                continue;
            };
            result.* = .{ .page = page, .max_w = tp.scale.fit.w, .image = encoded };

            self.mutex.lockUncancelable(io);
            if (self.quit) {
                self.mutex.unlock(io);
                self.freeResult(result);
                return;
            }
            self.thumb_results.park(self, result);
            self.mutex.unlock(io);

            if (self.context.loop) |loop| loop.postEvent(.prerender_ready) catch {};
        }
    }
}
