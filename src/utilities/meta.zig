// Zig 0.17 split struct type info into parallel name/type slices; this
// restores the old per-field view for `inline for`.
pub const Field = struct { name: [:0]const u8, type: type };

pub fn fields(comptime T: type) [@typeInfo(T).@"struct".field_names.len]Field {
    comptime {
        const info = @typeInfo(T).@"struct";
        var out: [info.field_names.len]Field = undefined;
        for (info.field_names, info.field_types, 0..) |n, t, i| out[i] = .{ .name = n, .type = t };
        return out;
    }
}
