// `zig build test`: the modules that compile without MuPDF.
test {
    _ = @import("services/Positions.zig");
    _ = @import("services/Sync.zig");
    _ = @import("services/S3Store.zig");
    _ = @import("services/History.zig");
    _ = @import("config/Config.zig");
    _ = @import("utilities/duration.zig");
    _ = @import("utilities/time.zig");
    _ = @import("utilities/fs.zig");
}
