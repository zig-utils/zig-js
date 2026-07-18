//! WebAssembly threads opcode surface pinned by
//! docs/.data/wasm-atomic-opcodes.json.

const std = @import("std");

pub const Immediate = enum { memarg, fence };

pub const Shape = enum {
    notify,
    wait32,
    wait64,
    fence,
    load_i32,
    load_i64,
    store_i32,
    store_i64,
    rmw_i32,
    rmw_i64,
    cmpxchg_i32,
    cmpxchg_i64,
};

pub const Op = enum(u8) {
    memory_atomic_notify = 0x00,
    memory_atomic_wait32 = 0x01,
    memory_atomic_wait64 = 0x02,
    memory_atomic_fence = 0x03,

    i32_atomic_load = 0x10,
    i64_atomic_load = 0x11,
    i32_atomic_load8_u = 0x12,
    i32_atomic_load16_u = 0x13,
    i64_atomic_load8_u = 0x14,
    i64_atomic_load16_u = 0x15,
    i64_atomic_load32_u = 0x16,
    i32_atomic_store = 0x17,
    i64_atomic_store = 0x18,
    i32_atomic_store8 = 0x19,
    i32_atomic_store16 = 0x1A,
    i64_atomic_store8 = 0x1B,
    i64_atomic_store16 = 0x1C,
    i64_atomic_store32 = 0x1D,

    i32_atomic_rmw_add = 0x1E,
    i64_atomic_rmw_add = 0x1F,
    i32_atomic_rmw8_add_u = 0x20,
    i32_atomic_rmw16_add_u = 0x21,
    i64_atomic_rmw8_add_u = 0x22,
    i64_atomic_rmw16_add_u = 0x23,
    i64_atomic_rmw32_add_u = 0x24,
    i32_atomic_rmw_sub = 0x25,
    i64_atomic_rmw_sub = 0x26,
    i32_atomic_rmw8_sub_u = 0x27,
    i32_atomic_rmw16_sub_u = 0x28,
    i64_atomic_rmw8_sub_u = 0x29,
    i64_atomic_rmw16_sub_u = 0x2A,
    i64_atomic_rmw32_sub_u = 0x2B,
    i32_atomic_rmw_and = 0x2C,
    i64_atomic_rmw_and = 0x2D,
    i32_atomic_rmw8_and_u = 0x2E,
    i32_atomic_rmw16_and_u = 0x2F,
    i64_atomic_rmw8_and_u = 0x30,
    i64_atomic_rmw16_and_u = 0x31,
    i64_atomic_rmw32_and_u = 0x32,
    i32_atomic_rmw_or = 0x33,
    i64_atomic_rmw_or = 0x34,
    i32_atomic_rmw8_or_u = 0x35,
    i32_atomic_rmw16_or_u = 0x36,
    i64_atomic_rmw8_or_u = 0x37,
    i64_atomic_rmw16_or_u = 0x38,
    i64_atomic_rmw32_or_u = 0x39,
    i32_atomic_rmw_xor = 0x3A,
    i64_atomic_rmw_xor = 0x3B,
    i32_atomic_rmw8_xor_u = 0x3C,
    i32_atomic_rmw16_xor_u = 0x3D,
    i64_atomic_rmw8_xor_u = 0x3E,
    i64_atomic_rmw16_xor_u = 0x3F,
    i64_atomic_rmw32_xor_u = 0x40,
    i32_atomic_rmw_xchg = 0x41,
    i64_atomic_rmw_xchg = 0x42,
    i32_atomic_rmw8_xchg_u = 0x43,
    i32_atomic_rmw16_xchg_u = 0x44,
    i64_atomic_rmw8_xchg_u = 0x45,
    i64_atomic_rmw16_xchg_u = 0x46,
    i64_atomic_rmw32_xchg_u = 0x47,
    i32_atomic_rmw_cmpxchg = 0x48,
    i64_atomic_rmw_cmpxchg = 0x49,
    i32_atomic_rmw8_cmpxchg_u = 0x4A,
    i32_atomic_rmw16_cmpxchg_u = 0x4B,
    i64_atomic_rmw8_cmpxchg_u = 0x4C,
    i64_atomic_rmw16_cmpxchg_u = 0x4D,
    i64_atomic_rmw32_cmpxchg_u = 0x4E,

    pub fn fromSubopcode(value: u32) ?Op {
        if (value > 0xFF) return null;
        return std.enums.fromInt(Op, @as(u8, @intCast(value)));
    }

    pub fn immediate(self: Op) Immediate {
        return if (self == .memory_atomic_fence) .fence else .memarg;
    }

    /// Natural alignment as the memarg log2 byte width.
    pub fn naturalAlignment(self: Op) ?u32 {
        return switch (self) {
            .memory_atomic_fence => null,
            .memory_atomic_notify,
            .memory_atomic_wait32,
            .i32_atomic_load,
            .i32_atomic_store,
            .i32_atomic_rmw_add,
            .i32_atomic_rmw_sub,
            .i32_atomic_rmw_and,
            .i32_atomic_rmw_or,
            .i32_atomic_rmw_xor,
            .i32_atomic_rmw_xchg,
            .i32_atomic_rmw_cmpxchg,
            .i64_atomic_load32_u,
            .i64_atomic_store32,
            .i64_atomic_rmw32_add_u,
            .i64_atomic_rmw32_sub_u,
            .i64_atomic_rmw32_and_u,
            .i64_atomic_rmw32_or_u,
            .i64_atomic_rmw32_xor_u,
            .i64_atomic_rmw32_xchg_u,
            .i64_atomic_rmw32_cmpxchg_u,
            => 2,
            .memory_atomic_wait64,
            .i64_atomic_load,
            .i64_atomic_store,
            .i64_atomic_rmw_add,
            .i64_atomic_rmw_sub,
            .i64_atomic_rmw_and,
            .i64_atomic_rmw_or,
            .i64_atomic_rmw_xor,
            .i64_atomic_rmw_xchg,
            .i64_atomic_rmw_cmpxchg,
            => 3,
            .i32_atomic_load16_u,
            .i32_atomic_store16,
            .i32_atomic_rmw16_add_u,
            .i32_atomic_rmw16_sub_u,
            .i32_atomic_rmw16_and_u,
            .i32_atomic_rmw16_or_u,
            .i32_atomic_rmw16_xor_u,
            .i32_atomic_rmw16_xchg_u,
            .i32_atomic_rmw16_cmpxchg_u,
            .i64_atomic_load16_u,
            .i64_atomic_store16,
            .i64_atomic_rmw16_add_u,
            .i64_atomic_rmw16_sub_u,
            .i64_atomic_rmw16_and_u,
            .i64_atomic_rmw16_or_u,
            .i64_atomic_rmw16_xor_u,
            .i64_atomic_rmw16_xchg_u,
            .i64_atomic_rmw16_cmpxchg_u,
            => 1,
            else => 0,
        };
    }

    pub fn shape(self: Op) Shape {
        return switch (self) {
            .memory_atomic_notify => .notify,
            .memory_atomic_wait32 => .wait32,
            .memory_atomic_wait64 => .wait64,
            .memory_atomic_fence => .fence,
            .i32_atomic_load, .i32_atomic_load8_u, .i32_atomic_load16_u => .load_i32,
            .i64_atomic_load, .i64_atomic_load8_u, .i64_atomic_load16_u, .i64_atomic_load32_u => .load_i64,
            .i32_atomic_store, .i32_atomic_store8, .i32_atomic_store16 => .store_i32,
            .i64_atomic_store, .i64_atomic_store8, .i64_atomic_store16, .i64_atomic_store32 => .store_i64,
            .i32_atomic_rmw_cmpxchg, .i32_atomic_rmw8_cmpxchg_u, .i32_atomic_rmw16_cmpxchg_u => .cmpxchg_i32,
            .i64_atomic_rmw_cmpxchg, .i64_atomic_rmw8_cmpxchg_u, .i64_atomic_rmw16_cmpxchg_u, .i64_atomic_rmw32_cmpxchg_u => .cmpxchg_i64,
            else => blk: {
                const position = (@intFromEnum(self) - 0x1E) % 7;
                break :blk if (position == 0 or position == 2 or position == 3)
                    .rmw_i32
                else
                    .rmw_i64;
            },
        };
    }
};

test "atomic opcode inventory has exact reserved gap" {
    try std.testing.expectEqual(@as(?Op, null), Op.fromSubopcode(0x04));
    try std.testing.expectEqual(@as(?Op, null), Op.fromSubopcode(0x0F));
    try std.testing.expectEqual(Op.i64_atomic_rmw32_cmpxchg_u, Op.fromSubopcode(0x4E).?);
    try std.testing.expectEqual(@as(?Op, null), Op.fromSubopcode(0x4F));
}
