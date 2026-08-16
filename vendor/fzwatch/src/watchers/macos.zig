const std = @import("std");
const interfaces = @import("interfaces.zig");

// Manual FFI declarations — the CoreServices / FSEvents headers in modern macOS SDKs
// use Objective-C block syntax that Zig's translate-c can't parse, so we declare the
// symbols we need directly.
const c = struct {
    pub const Boolean = u8;
    pub const CFIndex = c_long;
    pub const CFAllocatorRef = ?*anyopaque;
    pub const CFTypeRef = ?*const anyopaque;
    pub const CFStringRef = ?*const anyopaque;
    pub const CFArrayRef = ?*const anyopaque;
    pub const CFArrayCallBacks = extern struct {
        version: CFIndex,
        retain: ?*const anyopaque = null,
        release: ?*const anyopaque = null,
        copyDescription: ?*const anyopaque = null,
        equal: ?*const anyopaque = null,
    };
    pub const CFStringEncoding = u32;
    pub const kCFStringEncodingUTF8: CFStringEncoding = 0x08000100;

    pub const CFRunLoopRef = ?*anyopaque;
    pub const CFRunLoopMode = CFStringRef;
    pub const CFTimeInterval = f64;
    pub const CFAbsoluteTime = f64;

    pub const FSEventStreamRef = ?*anyopaque;
    pub const ConstFSEventStreamRef = ?*const anyopaque;
    pub const FSEventStreamEventId = u64;
    pub const FSEventStreamEventFlags = u32;
    pub const FSEventStreamCreateFlags = u32;
    pub const kFSEventStreamEventIdSinceNow: FSEventStreamEventId = std.math.maxInt(u64);
    pub const kFSEventStreamCreateFlagFileEvents: FSEventStreamCreateFlags = 0x10;
    pub const kFSEventStreamEventFlagItemModified: FSEventStreamEventFlags = 0x00001000;

    pub const FSEventStreamCallback = *const fn (
        stream: ConstFSEventStreamRef,
        info: ?*anyopaque,
        numEvents: usize,
        eventPaths: ?*anyopaque,
        eventFlags: [*c]const FSEventStreamEventFlags,
        eventIds: [*c]const FSEventStreamEventId,
    ) callconv(.c) void;

    pub const FSEventStreamContext = extern struct {
        version: CFIndex,
        info: ?*anyopaque,
        retain: ?*const anyopaque,
        release: ?*const anyopaque,
        copyDescription: ?*const anyopaque,
    };

    pub extern "c" const kCFTypeArrayCallBacks: CFArrayCallBacks;
    pub extern "c" const kCFRunLoopDefaultMode: CFRunLoopMode;

    pub extern "c" fn CFStringCreateWithBytes(
        alloc: CFAllocatorRef,
        bytes: [*]const u8,
        numBytes: CFIndex,
        encoding: CFStringEncoding,
        isExternal: Boolean,
    ) CFStringRef;
    pub extern "c" fn CFStringCompare(a: CFStringRef, b: CFStringRef, opts: u32) c_int;
    pub extern "c" fn CFRelease(ref: CFTypeRef) void;
    pub extern "c" fn CFArrayCreate(
        alloc: CFAllocatorRef,
        values: [*c]?*const anyopaque,
        count: CFIndex,
        cbs: *const CFArrayCallBacks,
    ) CFArrayRef;

    pub extern "c" fn CFRunLoopGetCurrent() CFRunLoopRef;
    pub extern "c" fn CFRunLoopRunInMode(mode: CFRunLoopMode, seconds: CFTimeInterval, retVal: Boolean) c_int;

    pub extern "c" fn FSEventStreamCreate(
        alloc: CFAllocatorRef,
        cb: FSEventStreamCallback,
        ctx: *FSEventStreamContext,
        paths: CFArrayRef,
        sinceWhen: FSEventStreamEventId,
        latency: CFTimeInterval,
        flags: FSEventStreamCreateFlags,
    ) FSEventStreamRef;
    pub extern "c" fn FSEventStreamScheduleWithRunLoop(stream: FSEventStreamRef, runLoop: CFRunLoopRef, mode: CFRunLoopMode) void;
    pub extern "c" fn FSEventStreamStart(stream: FSEventStreamRef) Boolean;
    pub extern "c" fn FSEventStreamStop(stream: FSEventStreamRef) void;
    pub extern "c" fn FSEventStreamInvalidate(stream: FSEventStreamRef) void;
    pub extern "c" fn FSEventStreamRelease(stream: FSEventStreamRef) void;
};

pub const MacosWatcher = struct {
    allocator: std.mem.Allocator,
    files: std.ArrayList(c.CFStringRef),
    stream: c.FSEventStreamRef,
    callback: ?*const interfaces.Callback,
    running: bool,
    context: ?*anyopaque,

    pub fn init(allocator: std.mem.Allocator) !MacosWatcher {
        return MacosWatcher{
            .allocator = allocator,
            .files = std.ArrayList(c.CFStringRef).empty,
            .stream = null,
            .callback = null,
            .running = false,
            .context = null,
        };
    }

    pub fn deinit(self: *MacosWatcher) void {
        if (self.stream != null) self.stop();
        for (self.files.items) |file| {
            c.CFRelease(file);
        }
        self.files.deinit(self.allocator);
    }

    pub fn addFile(self: *MacosWatcher, path: []const u8) !void {
        const file = c.CFStringCreateWithBytes(
            null,
            path.ptr,
            @as(c.CFIndex, @intCast(path.len)),
            c.kCFStringEncodingUTF8,
            0,
        );

        try self.files.append(self.allocator, file);
    }

    pub fn removeFile(self: *MacosWatcher, path: []const u8) !void {
        const target = c.CFStringCreateWithBytes(
            null,
            path.ptr,
            @as(c.CFIndex, @intCast(path.len)),
            c.kCFStringEncodingUTF8,
            0,
        );
        defer c.CFRelease(target);

        for (self.files.items, 0..) |file, index| {
            if (c.CFStringCompare(file, target, 0) == 0) {
                c.CFRelease(file);
                _ = self.files.orderedRemove(self.allocator, index);
                break;
            }
        }
    }

    pub fn setCallback(self: *MacosWatcher, callback: interfaces.Callback, context: ?*anyopaque) void {
        self.callback = callback;
        self.context = context;
    }

    fn fsEventsCallback(
        stream: c.ConstFSEventStreamRef,
        info: ?*anyopaque,
        numEvents: usize,
        eventPaths: ?*anyopaque,
        eventFlags: [*c]const c.FSEventStreamEventFlags,
        eventIds: [*c]const c.FSEventStreamEventId,
    ) callconv(.c) void {
        _ = stream;
        _ = eventPaths;
        _ = eventIds;

        const self = @as(*MacosWatcher, @ptrCast(@alignCast(info.?)));

        var i: usize = 0;
        while (i < numEvents) : (i += 1) {
            const flags = eventFlags[i];
            if (flags & c.kFSEventStreamEventFlagItemModified != 0) {
                self.callback.?(self.context, .modified);
            }
        }
    }

    pub fn start(self: *MacosWatcher, opts: interfaces.Opts) !void {
        if (self.files.items.len == 0) return error.NoFilesToWatch;

        const files = c.CFArrayCreate(
            null,
            @as([*c]?*const anyopaque, @ptrCast(self.files.items.ptr)),
            @as(c.CFIndex, @intCast(self.files.items.len)),
            &c.kCFTypeArrayCallBacks,
        );
        defer c.CFRelease(files);

        var context = c.FSEventStreamContext{
            .version = 0,
            .info = self,
            .retain = null,
            .release = null,
            .copyDescription = null,
        };

        self.stream = c.FSEventStreamCreate(
            null,
            fsEventsCallback,
            &context,
            files,
            c.kFSEventStreamEventIdSinceNow,
            opts.latency,
            c.kFSEventStreamCreateFlagFileEvents,
        );

        if (self.stream == null) return error.StreamCreateFailed;

        c.FSEventStreamScheduleWithRunLoop(
            self.stream.?,
            c.CFRunLoopGetCurrent(),
            c.kCFRunLoopDefaultMode,
        );

        if (c.FSEventStreamStart(self.stream.?) == 0) {
            self.stop();
            return error.StreamStartFailed;
        }

        self.running = true;

        while (self.running) {
            _ = c.CFRunLoopRunInMode(c.kCFRunLoopDefaultMode, opts.latency, 0);
        }
    }

    pub fn stop(self: *MacosWatcher) void {
        self.running = false;
        if (self.stream) |stream| {
            c.FSEventStreamStop(stream);
            c.FSEventStreamInvalidate(stream);
            c.FSEventStreamRelease(stream);
            self.stream = null;
        }
    }
};
