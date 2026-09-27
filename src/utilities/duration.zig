const std = @import("std");

// "10s", "5m", "3h", "1d" -> seconds; null when empty or malformed.
pub fn parse(text: []const u8) ?i64 {
    const t = std.mem.trim(u8, text, &std.ascii.whitespace);
    if (t.len < 2) return null;
    const mult: i64 = switch (t[t.len - 1]) {
        's' => 1,
        'm' => 60,
        'h' => 3600,
        'd' => 86400,
        else => return null,
    };
    const n = std.fmt.parseInt(i64, t[0 .. t.len - 1], 10) catch return null;
    return if (n > 0) n * mult else null;
}

test "parse" {
    try std.testing.expectEqual(@as(?i64, 10), parse("10s"));
    try std.testing.expectEqual(@as(?i64, 10800), parse("3h"));
    try std.testing.expectEqual(@as(?i64, null), parse(""));
    try std.testing.expectEqual(@as(?i64, null), parse("10"));
}
