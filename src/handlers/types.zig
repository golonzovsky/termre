// Types used in document handlers
pub const Transfer = enum { stream, temp_file, shm, direct_rgb };

pub const EncodedImage = struct {
    // Payload by kind:
    //   png_bytes — in-memory PNG, streamed base64 over the tty (SSH fallback)
    //   png_path  — temp file holding a PNG (kitty t=t; terminal deletes it)
    //   shm_rgb   — POSIX shared-memory object holding raw packed RGB rows
    //               (kitty t=s,f=24; terminal unlinks it after reading)
    data: []const u8,
    //   rgbz_bytes — strips of zlib-deflated packed RGB (kitty f=24,o=z) as
    //                a run of [u32 LE len][zlib], band_h rows each (last
    //                one shorter); sent on demand, see Context.ensureResident
    kind: enum { png_bytes, png_path, shm_rgb, rgbz_bytes },
    band_h: u16 = 0,
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

// Rex keeps ~3.33M pixels (10,000,000 raw RGB bytes) of images per terminal
// and silently evicts the oldest beyond that, so pages are cut into strips
// this big and only the strips in view are kept resident, under this budget.
pub const direct_rgb_strip_px: usize = 300_000;
pub const direct_rgb_budget_px: usize = 2_600_000;
