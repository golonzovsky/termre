//! Background page prerenderer. A single worker thread renders neighbor pages
//! (mupdf + base64 — the expensive part) so page crossings hit the cache.
//! The kitty transmit must stay on the main thread: finished results are
//! parked here and the main loop claims them on the `prerender_ready` event.
const Self = @This();
const std = @import("std");
const Cache = @import("../Cache.zig");
const types = @import("../handlers/types.zig");
const Context = @import("../Context.zig").Context;

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

// Render-ahead window: up to this many neighbor pages (e.g. +1..+3, -1..-3)
// are prerendered per request. render_mutex serializes the actual renders, so
// the worker just churns through them in priority order in the background.
pub const slots = 6;

context: *Context,
thread: ?std.Thread,
mutex: std.Io.Mutex,
cond: std.Io.Condition,
quit: bool,
req_pages: [slots]?u16,
req_w: u32,
req_h: u32,
has_req: bool,
results: [slots]?*Result,
thumb_reqs: [thumb_slots]?u16,
thumb_w: u32,
thumb_h: u32,
has_thumb_req: bool,
thumb_results: [thumb_slots]?*ThumbResult,

pub fn init() Self {
    return .{
        .context = undefined,
        .thread = null,
        .mutex = .init,
        .cond = .init,
        .quit = false,
        .req_pages = .{null} ** slots,
        .req_w = 0,
        .req_h = 0,
        .has_req = false,
        .results = .{null} ** slots,
        .thumb_reqs = .{null} ** thumb_slots,
        .thumb_w = 0,
        .thumb_h = 0,
        .has_thumb_req = false,
        .thumb_results = .{null} ** thumb_slots,
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
    for (&self.results) |*slot| {
        if (slot.*) |r| {
            self.freeResult(r);
            slot.* = null;
        }
    }
    for (&self.thumb_results) |*slot| {
        if (slot.*) |r| {
            self.freeThumb(r);
            slot.* = null;
        }
    }
}

fn freeResult(self: *Self, r: *Result) void {
    const a = self.context.allocator;
    // Never transmitted: the terminal won't clean up its backing store.
    self.context.deleteEncoded(r.image);
    a.free(r.image.data);
    a.destroy(r);
}

fn freeThumb(self: *Self, r: *ThumbResult) void {
    const a = self.context.allocator;
    self.context.deleteEncoded(r.image);
    a.free(r.image.data);
    a.destroy(r);
}

// Latest request wins; pending older requests are coalesced away.
pub fn request(self: *Self, pages: [slots]?u16, w: u32, h: u32) void {
    if (self.thread == null) return;
    const io = self.context.io;
    self.mutex.lockUncancelable(io);
    defer self.mutex.unlock(io);
    self.req_pages = pages;
    self.req_w = w;
    self.req_h = h;
    self.has_req = true;
    self.cond.signal(io);
}

pub fn requestThumbs(self: *Self, pages: [thumb_slots]?u16, w: u32, h: u32) bool {
    if (self.thread == null) return false;
    const io = self.context.io;
    self.mutex.lockUncancelable(io);
    defer self.mutex.unlock(io);
    self.thumb_reqs = pages;
    self.thumb_w = w;
    self.thumb_h = h;
    self.has_thumb_req = true;
    self.cond.signal(io);
    return true;
}

pub fn claimThumbs(self: *Self) [thumb_slots]?*ThumbResult {
    const io = self.context.io;
    self.mutex.lockUncancelable(io);
    defer self.mutex.unlock(io);
    const out = self.thumb_results;
    self.thumb_results = .{null} ** thumb_slots;
    return out;
}

// Hands finished renders to the caller, which takes ownership.
pub fn claim(self: *Self) [slots]?*Result {
    const io = self.context.io;
    self.mutex.lockUncancelable(io);
    defer self.mutex.unlock(io);
    const out = self.results;
    self.results = .{null} ** slots;
    return out;
}

// Caller holds the mutex. Parks into the first free slot, or evicts the oldest
// (slot 0) and shifts down when full, so the newest result is always kept.
fn park(self: *Self, result: *Result) void {
    for (&self.results) |*slot| {
        if (slot.* == null) {
            slot.* = result;
            return;
        }
    }
    self.freeResult(self.results[0].?);
    var i: usize = 0;
    while (i + 1 < slots) : (i += 1) self.results[i] = self.results[i + 1];
    self.results[slots - 1] = result;
}

fn run(self: *Self) void {
    const io = self.context.io;
    while (true) {
        self.mutex.lockUncancelable(io);
        while (!self.quit and !self.has_req and !self.has_thumb_req) self.cond.waitUncancelable(io, &self.mutex);
        if (self.quit) {
            self.mutex.unlock(io);
            return;
        }
        const pages = if (self.has_req) self.req_pages else .{null} ** slots;
        const w = self.req_w;
        const h = self.req_h;
        self.has_req = false;
        const thumbs = if (self.has_thumb_req) self.thumb_reqs else .{null} ** thumb_slots;
        const tw = self.thumb_w;
        const th = self.thumb_h;
        self.has_thumb_req = false;
        self.mutex.unlock(io);

        for (pages) |maybe_page| {
            const page = maybe_page orelse continue;
            const encoded = self.context.document_handler.renderPage(page, w, h) catch continue;
            const key = self.context.cacheKeyFor(page);
            const result = self.context.allocator.create(Result) catch {
                self.context.deleteEncoded(encoded);
                self.context.allocator.free(encoded.data);
                continue;
            };
            result.* = .{ .key = key, .image = encoded };

            self.mutex.lockUncancelable(io);
            if (self.quit) {
                self.mutex.unlock(io);
                self.freeResult(result);
                return;
            }
            self.park(result);
            self.mutex.unlock(io);

            if (self.context.loop) |loop| loop.postEvent(.prerender_ready) catch {};
        }

        for (thumbs) |maybe_page| {
            const page = maybe_page orelse continue;
            const encoded = self.context.document_handler.renderThumb(page, tw, th) catch continue;
            const result = self.context.allocator.create(ThumbResult) catch {
                self.context.deleteEncoded(encoded);
                self.context.allocator.free(encoded.data);
                continue;
            };
            result.* = .{ .page = page, .max_w = tw, .image = encoded };

            self.mutex.lockUncancelable(io);
            if (self.quit) {
                self.mutex.unlock(io);
                self.freeThumb(result);
                return;
            }
            for (&self.thumb_results) |*slot| {
                if (slot.* == null) {
                    slot.* = result;
                    break;
                }
            } else {
                self.freeThumb(self.thumb_results[0].?);
                var i: usize = 0;
                while (i + 1 < thumb_slots) : (i += 1) self.thumb_results[i] = self.thumb_results[i + 1];
                self.thumb_results[thumb_slots - 1] = result;
            }
            self.mutex.unlock(io);

            if (self.context.loop) |loop| loop.postEvent(.prerender_ready) catch {};
        }
    }
}
