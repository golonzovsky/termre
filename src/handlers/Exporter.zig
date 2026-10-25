//! Hands a finished pixmap to the terminal transfer in use: raw RGB in a POSIX
//! shared-memory object (kitty t=s, no PNG at all), a PNG temp file (t=t), or
//! in-memory PNG bytes (the SSH fallback). Called under Document.render_mutex.
const Self = @This();
const std = @import("std");
const types = @import("./types.zig");
const time = @import("../utilities/time.zig");
const c = @import("c");

allocator: std.mem.Allocator,
transfer: types.Transfer,
png_dir: ?[]const u8,
png_seq: u32,
session_tag: u32,

pub fn init(allocator: std.mem.Allocator) Self {
    return .{
        .allocator = allocator,
        .transfer = .stream,
        .png_dir = null,
        .png_seq = 0,
        .session_tag = @truncate(@as(u64, @bitCast(time.nowRealSeconds()))),
    };
}

pub fn deinit(self: *Self) void {
    if (self.png_dir) |d| self.allocator.free(d);
}

pub fn setTransfer(self: *Self, transfer: types.Transfer, tmp_dir: ?[]const u8) void {
    self.transfer = transfer;
    if (tmp_dir) |dir| self.png_dir = self.allocator.dupe(u8, dir) catch null;
}

pub fn encode(self: *Self, ctx: [*c]c.fz_context, pix: [*c]c.fz_pixmap, width: usize, height: usize, ox: f32, oy: f32) !types.EncodedImage {
    // Raw RGB in shared memory skips PNG encode and decode entirely; the
    // PNG paths compress 10-40x for text pages, which matters for the
    // temp-file and especially the streamed SSH fallback.
    if (self.transfer == .shm) {
        self.png_seq +%= 1;
        var name_buf: [32]u8 = undefined; // macOS shm names cap at 31 chars
        const name = std.fmt.bufPrintSentinel(&name_buf, "/tre{x}-{x}", .{ self.session_tag, self.png_seq }, 0) catch
            return types.DocumentError.FailedToRenderPage;
        if (c.fz_pixmap_to_shm_z(ctx, pix, name.ptr) != 0) {
            return types.EncodedImage{
                .data = try self.allocator.dupe(u8, name),
                .kind = .shm_rgb,
                .width = @as(u16, @intCast(width)),
                .height = @as(u16, @intCast(height)),
                .origin_x = ox,
                .origin_y = oy,
            };
        }
        // shm failed (exhausted or unsupported): fall through to streamed PNG.
    }

    if (self.transfer == .temp_file) {
        if (self.png_dir) |dir| {
            self.png_seq +%= 1;
            const path = try std.fmt.allocPrint(
                self.allocator,
                "{s}/tty-graphics-protocol-termre-{d}-{d}.png",
                .{ dir, self.session_tag, self.png_seq },
            );
            errdefer self.allocator.free(path);
            var pathz_buf: [1024]u8 = undefined;
            const pathz = std.fmt.bufPrintSentinel(&pathz_buf, "{s}", .{path}, 0) catch return types.DocumentError.FailedToRenderPage;
            if (c.fz_save_pixmap_png_z(ctx, pix, pathz.ptr) == 0) {
                return types.DocumentError.FailedToRenderPage;
            }
            return types.EncodedImage{
                .data = path,
                .kind = .png_path,
                .width = @as(u16, @intCast(width)),
                .height = @as(u16, @intCast(height)),
                .origin_x = ox,
                .origin_y = oy,
            };
        }
    }

    var png_len: usize = 0;
    const png_ptr = c.fz_pixmap_png_z(ctx, pix, &png_len) orelse
        return types.DocumentError.FailedToRenderPage;
    defer std.c.free(png_ptr);
    const data = try self.allocator.dupe(u8, png_ptr[0..png_len]);

    return types.EncodedImage{
        .data = data,
        .kind = .png_bytes,
        .width = @as(u16, @intCast(width)),
        .height = @as(u16, @intCast(height)),
        .origin_x = ox,
        .origin_y = oy,
    };
}

// Removes the backing file or shm object of a render the terminal never read
// (it would otherwise clean up after itself).
pub fn delete(io: std.Io, enc: types.EncodedImage) void {
    switch (enc.kind) {
        .png_path => std.Io.Dir.cwd().deleteFile(io, enc.data) catch {},
        .shm_rgb => {
            var name_buf: [64]u8 = undefined;
            const name = std.fmt.bufPrintSentinel(&name_buf, "{s}", .{enc.data}, 0) catch return;
            _ = std.c.shm_unlink(name.ptr);
        },
        .png_bytes => {},
    }
}
