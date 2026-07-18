//! WebAssembly GC opcode surface pinned by
//! docs/.data/wasm-gc-binary-inventory.json.

const std = @import("std");

pub const Immediate = enum {
    none,
    type_index,
    type_field,
    type_count,
    two_indices,
    heap_type,
    cast_branch,
};

pub const Op = enum(u8) {
    struct_new = 0x00,
    struct_new_default = 0x01,
    struct_get = 0x02,
    struct_get_s = 0x03,
    struct_get_u = 0x04,
    struct_set = 0x05,
    array_new = 0x06,
    array_new_default = 0x07,
    array_new_fixed = 0x08,
    array_new_data = 0x09,
    array_new_elem = 0x0A,
    array_get = 0x0B,
    array_get_s = 0x0C,
    array_get_u = 0x0D,
    array_set = 0x0E,
    array_len = 0x0F,
    array_fill = 0x10,
    array_copy = 0x11,
    array_init_data = 0x12,
    array_init_elem = 0x13,
    ref_test = 0x14,
    ref_test_null = 0x15,
    ref_cast = 0x16,
    ref_cast_null = 0x17,
    br_on_cast = 0x18,
    br_on_cast_fail = 0x19,
    any_convert_extern = 0x1A,
    extern_convert_any = 0x1B,
    ref_i31 = 0x1C,
    i31_get_s = 0x1D,
    i31_get_u = 0x1E,

    pub fn fromSubopcode(value: u32) ?Op {
        if (value > 0xFF) return null;
        return std.enums.fromInt(Op, @as(u8, @intCast(value)));
    }

    pub fn immediate(self: Op) Immediate {
        return switch (self) {
            .struct_new,
            .struct_new_default,
            .array_new,
            .array_new_default,
            .array_get,
            .array_get_s,
            .array_get_u,
            .array_set,
            .array_fill,
            => .type_index,
            .struct_get, .struct_get_s, .struct_get_u, .struct_set => .type_field,
            .array_new_fixed => .type_count,
            .array_new_data,
            .array_new_elem,
            .array_copy,
            .array_init_data,
            .array_init_elem,
            => .two_indices,
            .ref_test, .ref_test_null, .ref_cast, .ref_cast_null => .heap_type,
            .br_on_cast, .br_on_cast_fail => .cast_branch,
            .array_len,
            .any_convert_extern,
            .extern_convert_any,
            .ref_i31,
            .i31_get_s,
            .i31_get_u,
            => .none,
        };
    }
};

test "wasm.gc opcode inventory is contiguous and complete" {
    inline for (0..31) |subopcode|
        try std.testing.expectEqual(@as(u8, subopcode), @intFromEnum(Op.fromSubopcode(subopcode).?));
    try std.testing.expect(Op.fromSubopcode(31) == null);
    try std.testing.expect(Op.fromSubopcode(std.math.maxInt(u32)) == null);
}
