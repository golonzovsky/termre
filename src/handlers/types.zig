// Types used in document handlers
pub const Transfer = enum { stream, temp_file, shm };

pub const EncodedImage = struct {
    // Payload by kind:
    //   png_bytes — in-memory PNG, streamed base64 over the tty (SSH fallback)
    //   png_path  — temp file holding a PNG (kitty t=t; terminal deletes it)
    //   shm_rgb   — POSIX shared-memory object holding raw packed RGB rows
    //               (kitty t=s,f=24; terminal unlinks it after reading)
    data: []const u8,
    kind: enum { png_bytes, png_path, shm_rgb },
    width: u16,
    height: u16,
    origin_x: f32 = 0,
    origin_y: f32 = 0,
};

pub const DocumentError = error{
    FailedToCreateContext,
    FailedToOpenDocument,
    FailedToRenderPage,
    InvalidPageNumber,
    UnsupportedFileFormat,
};
