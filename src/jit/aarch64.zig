//! Minimal AArch64 emitter used by the baseline JIT.

const std = @import("std");

pub const Condition = enum(u4) {
    eq = 0,
    ne = 1,
    hs = 2,
    lo = 3,
    mi = 4,
    pl = 5,
    vs = 6,
    vc = 7,
    hi = 8,
    ls = 9,
    ge = 10,
    lt = 11,
    gt = 12,
    le = 13,

    fn inverted(self: Condition) Condition {
        return @enumFromInt(@intFromEnum(self) ^ 1);
    }
};

pub const FloatOp = enum { add, sub, mul, div };

pub const Assembler = struct {
    buffer: []u8,
    offset: usize = 0,

    pub fn init(buffer: []u8) Assembler {
        return .{ .buffer = buffer };
    }

    pub fn bytes(self: *const Assembler) []const u8 {
        return self.buffer[0..self.offset];
    }

    pub fn position(self: *const Assembler) usize {
        return self.offset;
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

    pub fn moveRegister64(self: *Assembler, rd: u5, rn: u5) error{NoSpace}!void {
        try self.emit32(0xaa00_03e0 | (@as(u32, rn) << 16) | rd);
    }

    pub fn addImmediate64(self: *Assembler, rd: u5, rn: u5, value: u12) error{NoSpace}!void {
        try self.emit32(0x9100_0000 | (@as(u32, value) << 10) | (@as(u32, rn) << 5) | rd);
    }

    pub fn addRegister64(self: *Assembler, rd: u5, rn: u5, rm: u5) error{NoSpace}!void {
        try self.emit32(0x8b00_0000 | (@as(u32, rm) << 16) | (@as(u32, rn) << 5) | rd);
    }

    pub fn subtractImmediateSetFlags64(self: *Assembler, rd: u5, rn: u5, value: u12) error{NoSpace}!void {
        try self.emit32(0xf100_0000 | (@as(u32, value) << 10) | (@as(u32, rn) << 5) | rd);
    }

    pub fn compareRegister64(self: *Assembler, rn: u5, rm: u5) error{NoSpace}!void {
        try self.emit32(0xeb00_001f | (@as(u32, rm) << 16) | (@as(u32, rn) << 5));
    }

    pub fn pushPair(self: *Assembler, first: u5, second: u5) error{NoSpace}!void {
        try self.emit32(0xa9bf_0000 | (@as(u32, second) << 10) | (31 << 5) | first);
    }

    pub fn popPair(self: *Assembler, first: u5, second: u5) error{NoSpace}!void {
        try self.emit32(0xa8c1_0000 | (@as(u32, second) << 10) | (31 << 5) | first);
    }

    /// `ldr xt, [xn, #byte_offset]`, using AArch64's unsigned scaled form.
    pub fn load64(self: *Assembler, xt: u5, xn: u5, byte_offset: u15) error{ NoSpace, InvalidOffset }!void {
        if ((byte_offset & 7) != 0) return error.InvalidOffset;
        const scaled = byte_offset / 8;
        if (scaled > 0xfff) return error.InvalidOffset;
        try self.emit32(0xf940_0000 | (@as(u32, scaled) << 10) | (@as(u32, xn) << 5) | xt);
    }

    /// `str xt, [xn, #byte_offset]`, using AArch64's unsigned scaled form.
    pub fn store64(self: *Assembler, xt: u5, xn: u5, byte_offset: u15) error{ NoSpace, InvalidOffset }!void {
        if ((byte_offset & 7) != 0) return error.InvalidOffset;
        const scaled = byte_offset / 8;
        if (scaled > 0xfff) return error.InvalidOffset;
        try self.emit32(0xf900_0000 | (@as(u32, scaled) << 10) | (@as(u32, xn) << 5) | xt);
    }

    pub fn moveFloatFromRegister64(self: *Assembler, fd: u5, rn: u5) error{NoSpace}!void {
        try self.emit32(0x9e67_0000 | (@as(u32, rn) << 5) | fd);
    }

    pub fn moveRegisterFromFloat64(self: *Assembler, rd: u5, fn_: u5) error{NoSpace}!void {
        try self.emit32(0x9e66_0000 | (@as(u32, fn_) << 5) | rd);
    }

    pub fn floatBinary64(self: *Assembler, op: FloatOp, fd: u5, fn_: u5, fm: u5) error{NoSpace}!void {
        const base: u32 = switch (op) {
            .add => 0x1e60_2800,
            .sub => 0x1e60_3800,
            .mul => 0x1e60_0800,
            .div => 0x1e60_1800,
        };
        try self.emit32(base | (@as(u32, fm) << 16) | (@as(u32, fn_) << 5) | fd);
    }

    pub fn compareFloat64(self: *Assembler, fn_: u5, fm: u5) error{NoSpace}!void {
        try self.emit32(0x1e60_2000 | (@as(u32, fm) << 16) | (@as(u32, fn_) << 5));
    }

    pub fn convertFloat64ToUnsigned32(self: *Assembler, rd: u5, fn_: u5) error{NoSpace}!void {
        try self.emit32(0x1e79_0000 | (@as(u32, fn_) << 5) | rd);
    }

    pub fn convertUnsigned32ToFloat64(self: *Assembler, fd: u5, rn: u5) error{NoSpace}!void {
        try self.emit32(0x1e63_0000 | (@as(u32, rn) << 5) | fd);
    }

    pub fn divideUnsigned32(self: *Assembler, rd: u5, rn: u5, rm: u5) error{NoSpace}!void {
        try self.emit32(0x1ac0_0800 | (@as(u32, rm) << 16) | (@as(u32, rn) << 5) | rd);
    }

    pub fn multiplySubtract32(self: *Assembler, rd: u5, rn: u5, rm: u5, ra: u5) error{NoSpace}!void {
        try self.emit32(0x1b00_8000 | (@as(u32, rm) << 16) | (@as(u32, ra) << 10) | (@as(u32, rn) << 5) | rd);
    }

    pub fn conditionalSet32(self: *Assembler, rd: u5, condition: Condition) error{NoSpace}!void {
        try self.emit32(0x1a9f_07e0 | (@as(u32, @intFromEnum(condition.inverted())) << 12) | rd);
    }

    pub fn branchLinkRegister(self: *Assembler, rn: u5) error{NoSpace}!void {
        try self.emit32(0xd63f_0000 | (@as(u32, rn) << 5));
    }

    pub fn branchPlaceholder(self: *Assembler) error{NoSpace}!usize {
        const at = self.offset;
        try self.emit32(0x1400_0000);
        return at;
    }

    pub fn branchConditionPlaceholder(self: *Assembler, condition: Condition) error{NoSpace}!usize {
        const at = self.offset;
        try self.emit32(0x5400_0000 | @as(u32, @intFromEnum(condition)));
        return at;
    }

    pub fn branchNotZero32Placeholder(self: *Assembler, rt: u5) error{NoSpace}!usize {
        const at = self.offset;
        try self.emit32(0x3500_0000 | @as(u32, rt));
        return at;
    }

    pub fn branchZero32Placeholder(self: *Assembler, rt: u5) error{NoSpace}!usize {
        const at = self.offset;
        try self.emit32(0x3400_0000 | @as(u32, rt));
        return at;
    }

    pub fn testBitZeroPlaceholder(self: *Assembler, rt: u5, bit: u6) error{NoSpace}!usize {
        const at = self.offset;
        const b5: u32 = @as(u32, bit >> 5) << 31;
        const b40: u32 = @as(u32, bit & 0x1f) << 19;
        try self.emit32(0x3600_0000 | b5 | b40 | @as(u32, rt));
        return at;
    }

    pub fn patchBranch(self: *Assembler, at: usize, target: usize) error{ InvalidBranch, BranchOutOfRange }!void {
        const displacement = try branchDisplacement(at, target, 26);
        const current = readInstruction(self.buffer, at) catch return error.InvalidBranch;
        if ((current & 0xfc00_0000) != 0x1400_0000) return error.InvalidBranch;
        writeInstruction(self.buffer, at, (current & 0xfc00_0000) | (@as(u32, @bitCast(@as(i32, @intCast(displacement)))) & 0x03ff_ffff)) catch return error.InvalidBranch;
    }

    pub fn patchConditionBranch(self: *Assembler, at: usize, target: usize) error{ InvalidBranch, BranchOutOfRange }!void {
        const displacement = try branchDisplacement(at, target, 19);
        const current = readInstruction(self.buffer, at) catch return error.InvalidBranch;
        if ((current & 0xff00_0010) != 0x5400_0000) return error.InvalidBranch;
        const encoded = @as(u32, @bitCast(@as(i32, @intCast(displacement)))) & 0x7ffff;
        writeInstruction(self.buffer, at, (current & 0xff00_001f) | (encoded << 5)) catch return error.InvalidBranch;
    }

    pub fn patchCompareBranch(self: *Assembler, at: usize, target: usize) error{ InvalidBranch, BranchOutOfRange }!void {
        const displacement = try branchDisplacement(at, target, 19);
        const current = readInstruction(self.buffer, at) catch return error.InvalidBranch;
        const opcode = current & 0x7e00_0000;
        if (opcode != 0x3400_0000) return error.InvalidBranch;
        const encoded = @as(u32, @bitCast(@as(i32, @intCast(displacement)))) & 0x7ffff;
        writeInstruction(self.buffer, at, (current & 0xff00_001f) | (encoded << 5)) catch return error.InvalidBranch;
    }

    pub fn patchTestBranch(self: *Assembler, at: usize, target: usize) error{ InvalidBranch, BranchOutOfRange }!void {
        const displacement = try branchDisplacement(at, target, 14);
        const current = readInstruction(self.buffer, at) catch return error.InvalidBranch;
        if ((current & 0x7f00_0000) != 0x3600_0000) return error.InvalidBranch;
        const encoded = @as(u32, @bitCast(@as(i32, @intCast(displacement)))) & 0x3fff;
        writeInstruction(self.buffer, at, (current & 0xfff8_001f) | (encoded << 5)) catch return error.InvalidBranch;
    }

    pub fn ret(self: *Assembler) error{NoSpace}!void {
        try self.emit32(0xd65f_03c0);
    }
};

fn readInstruction(buffer: []const u8, at: usize) error{InvalidBranch}!u32 {
    if ((at & 3) != 0 or at + 4 > buffer.len) return error.InvalidBranch;
    return std.mem.readInt(u32, buffer[at..][0..4], .little);
}

fn writeInstruction(buffer: []u8, at: usize, instruction: u32) error{InvalidBranch}!void {
    if ((at & 3) != 0 or at + 4 > buffer.len) return error.InvalidBranch;
    std.mem.writeInt(u32, buffer[at..][0..4], instruction, .little);
}

fn branchDisplacement(at: usize, target: usize, comptime bits: u6) error{ InvalidBranch, BranchOutOfRange }!i64 {
    if ((at & 3) != 0 or (target & 3) != 0) return error.InvalidBranch;
    const delta = @as(i64, @intCast(target)) - @as(i64, @intCast(at));
    const words = @divExact(delta, 4);
    const min = -(@as(i64, 1) << (bits - 1));
    const max = (@as(i64, 1) << (bits - 1)) - 1;
    if (words < min or words > max) return error.BranchOutOfRange;
    return words;
}

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

test "AArch64 numeric tier instruction encodings" {
    var storage: [96]u8 = undefined;
    var assembler = Assembler.init(&storage);
    try assembler.pushPair(19, 20);
    try assembler.popPair(19, 20);
    try assembler.moveRegister64(21, 0);
    try assembler.load64(22, 21, 16);
    try assembler.store64(22, 21, 24);
    try assembler.addImmediate64(19, 19, 1);
    try assembler.addRegister64(9, 10, 11);
    try assembler.subtractImmediateSetFlags64(25, 25, 1);
    try assembler.compareRegister64(19, 23);
    try assembler.branchLinkRegister(16);
    try assembler.moveFloatFromRegister64(0, 9);
    try assembler.moveRegisterFromFloat64(9, 0);
    try assembler.floatBinary64(.add, 2, 0, 1);
    try assembler.floatBinary64(.sub, 2, 0, 1);
    try assembler.floatBinary64(.mul, 2, 0, 1);
    try assembler.floatBinary64(.div, 2, 0, 1);
    try assembler.compareFloat64(0, 1);
    try assembler.conditionalSet32(9, .lt);

    const cond = try assembler.branchConditionPlaceholder(.eq);
    const compare = try assembler.branchNotZero32Placeholder(0);
    const bit = try assembler.testBitZeroPlaceholder(9, 0);
    const direct = try assembler.branchPlaceholder();
    const target = assembler.position();
    try assembler.ret();
    try assembler.patchConditionBranch(cond, target);
    try assembler.patchCompareBranch(compare, target);
    try assembler.patchTestBranch(bit, target);
    try assembler.patchBranch(direct, target);

    const expected = [_]u32{
        0xa9bf_53f3, 0xa8c1_53f3, 0xaa00_03f5, 0xf940_0ab6,
        0xf900_0eb6, 0x9100_0673, 0x8b0b_0149, 0xf100_0739,
        0xeb17_027f, 0xd63f_0200, 0x9e67_0120, 0x9e66_0009,
        0x1e61_2802, 0x1e61_3802, 0x1e61_0802, 0x1e61_1802,
        0x1e61_2000, 0x1a9f_a7e9, 0x5400_0080, 0x3500_0060,
        0x3600_0049, 0x1400_0001, 0xd65f_03c0,
    };
    try std.testing.expectEqual(expected.len * 4, assembler.bytes().len);
    for (expected, 0..) |instruction, index| {
        try std.testing.expectEqual(instruction, std.mem.readInt(u32, assembler.bytes()[index * 4 ..][0..4], .little));
    }
}

test "AArch64 guarded unsigned remainder encodings" {
    var storage: [56]u8 = undefined;
    var assembler = Assembler.init(&storage);
    try assembler.convertFloat64ToUnsigned32(9, 0);
    try assembler.convertUnsigned32ToFloat64(2, 9);
    try assembler.compareFloat64(0, 2);
    const lhs_fractional = try assembler.branchConditionPlaceholder(.ne);
    const lhs_zero = try assembler.branchZero32Placeholder(9);
    try assembler.convertFloat64ToUnsigned32(10, 1);
    try assembler.convertUnsigned32ToFloat64(2, 10);
    try assembler.compareFloat64(1, 2);
    const rhs_fractional = try assembler.branchConditionPlaceholder(.ne);
    const rhs_zero = try assembler.branchZero32Placeholder(10);
    try assembler.divideUnsigned32(11, 9, 10);
    try assembler.multiplySubtract32(9, 11, 10, 9);
    try assembler.convertUnsigned32ToFloat64(0, 9);
    const slow = assembler.position();
    try assembler.ret();
    try assembler.patchConditionBranch(lhs_fractional, slow);
    try assembler.patchCompareBranch(lhs_zero, slow);
    try assembler.patchConditionBranch(rhs_fractional, slow);
    try assembler.patchCompareBranch(rhs_zero, slow);

    const expected = [_]u32{
        0x1e79_0009, 0x1e63_0122, 0x1e62_2000, 0x5400_0141,
        0x3400_0129, 0x1e79_002a, 0x1e63_0142, 0x1e62_2020,
        0x5400_00a1, 0x3400_008a, 0x1aca_092b, 0x1b0a_a569,
        0x1e63_0120, 0xd65f_03c0,
    };
    for (expected, 0..) |instruction, index| {
        try std.testing.expectEqual(instruction, std.mem.readInt(u32, assembler.bytes()[index * 4 ..][0..4], .little));
    }
}
