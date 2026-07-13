//! Minimal AArch64 emitter used by the baseline JIT.

const std = @import("std");

pub const Assembler = struct {
    buffer: []u8,
    offset: usize = 0,

    pub fn init(buffer: []u8) Assembler {
        return .{ .buffer = buffer };
    }

    pub fn bytes(self: *const Assembler) []const u8 {
        return self.buffer[0..self.offset];
    }

    fn emit32(self: *Assembler, instruction: u32) error{NoSpace}!void {
        if (self.buffer.len - self.offset < 4) return error.NoSpace;
        std.mem.writeInt(u32, self.buffer[self.offset..][0..4], instruction, .little);
        self.offset += 4;
    }

    pub fn movImmediate64(self: *Assembler, rd: u5, value: u64) error{NoSpace}!void {
        const low: u16 = @truncate(value);
        try self.emit32(0xd280_0000 | (@as(u32, low) << 5) | rd);
        inline for (1..4) |halfword| {
            const shift: u6 = @intCast(halfword * 16);
            const part: u16 = @truncate(value >> shift);
            try self.emit32(0xf280_0000 | (@as(u32, halfword) << 21) | (@as(u32, part) << 5) | rd);
        }
    }

    pub fn movImmediate32(self: *Assembler, rd: u5, value: u16) error{NoSpace}!void {
        try self.emit32(0x5280_0000 | (@as(u32, value) << 5) | rd);
    }

    /// `str xt, [xn, #byte_offset]`, using AArch64's unsigned scaled form.
    pub fn store64(self: *Assembler, xt: u5, xn: u5, byte_offset: u15) error{ NoSpace, InvalidOffset }!void {
        if ((byte_offset & 7) != 0) return error.InvalidOffset;
        const scaled = byte_offset / 8;
        if (scaled > 0xfff) return error.InvalidOffset;
        try self.emit32(0xf900_0000 | (@as(u32, scaled) << 10) | (@as(u32, xn) << 5) | xt);
    }

    pub fn ret(self: *Assembler) error{NoSpace}!void {
        try self.emit32(0xd65f_03c0);
    }
};

test "AArch64 immediate and return encodings" {
    var storage: [24]u8 = undefined;
    var assembler = Assembler.init(&storage);
    try assembler.movImmediate64(1, 0x1122_3344_5566_7788);
    try assembler.movImmediate32(0, 3);
    try assembler.ret();

    const expected = [_]u32{
        0xd28e_f101,
        0xf2aa_acc1,
        0xf2c6_6881,
        0xf2e2_2441,
        0x5280_0060,
        0xd65f_03c0,
    };
    for (expected, 0..) |instruction, index| {
        try std.testing.expectEqual(instruction, std.mem.readInt(u32, assembler.bytes()[index * 4 ..][0..4], .little));
    }
}
