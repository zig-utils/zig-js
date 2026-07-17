//! JSC64 `EncodedJSValue` boundary for revision-pinned Home/Bun private shims.
//!
//! This is intentionally distinct from `value.Value`: zig-js owns its internal
//! NaN-box layout, while consumers may inspect JavaScriptCore words inline.

const std = @import("std");

pub const NUMBER_TAG: u64 = 0xfffe_0000_0000_0000;
pub const OTHER_TAG: u64 = 0x2;
pub const BOOL_TAG: u64 = 0x4;
pub const UNDEFINED_TAG: u64 = 0x8;
pub const DOUBLE_ENCODE_OFFSET: u64 = 1 << 49;
pub const NOT_CELL_MASK: u64 = NUMBER_TAG | OTHER_TAG;
pub const EMPTY_BITS: u64 = 0;
pub const NULL_BITS: u64 = OTHER_TAG;
pub const DELETED_BITS: u64 = 0x4;
pub const FALSE_BITS: u64 = OTHER_TAG | BOOL_TAG;
pub const TRUE_BITS: u64 = OTHER_TAG | BOOL_TAG | 1;
pub const UNDEFINED_BITS: u64 = OTHER_TAG | UNDEFINED_TAG;

pub const ConversionError = error{
    CellRequiresHandle,
    EmptyValue,
    DeletedValue,
    InvalidEncoding,
    InvalidCellPointer,
};

pub const EncodedValue = enum(i64) {
    empty = @bitCast(EMPTY_BITS),
    null = @bitCast(NULL_BITS),
    deleted = @bitCast(DELETED_BITS),
    false = @bitCast(FALSE_BITS),
    true = @bitCast(TRUE_BITS),
    undefined = @bitCast(UNDEFINED_BITS),
    _,

    pub inline fn rawBits(self: EncodedValue) u64 {
        return @bitCast(@intFromEnum(self));
    }

    pub inline fn fromRawBits(bits: u64) EncodedValue {
        return @enumFromInt(@as(i64, @bitCast(bits)));
    }

    pub inline fn fromInt32(value: i32) EncodedValue {
        return fromRawBits(NUMBER_TAG | @as(u32, @bitCast(value)));
    }

    pub inline fn asInt32(self: EncodedValue) i32 {
        std.debug.assert(self.isInt32());
        return @bitCast(@as(u32, @truncate(self.rawBits())));
    }

    pub inline fn fromDouble(value: f64) EncodedValue {
        return fromRawBits(@as(u64, @bitCast(value)) +% DOUBLE_ENCODE_OFFSET);
    }

    pub inline fn asDouble(self: EncodedValue) f64 {
        std.debug.assert(self.isDouble());
        return @bitCast(self.rawBits() -% DOUBLE_ENCODE_OFFSET);
    }

    pub fn fromCellAddress(address: usize) ConversionError!EncodedValue {
        if (address == 0 or address & 0x7 != 0) return error.InvalidCellPointer;
        const encoded = fromRawBits(address);
        if (!encoded.isCell()) return error.InvalidCellPointer;
        return encoded;
    }

    pub inline fn fromCell(pointer: *anyopaque) ConversionError!EncodedValue {
        return fromCellAddress(@intFromPtr(pointer));
    }

    pub fn asCellAddress(self: EncodedValue) ConversionError!usize {
        if (!self.isCell()) return error.InvalidEncoding;
        return @intCast(self.rawBits());
    }

    pub inline fn isInt32(self: EncodedValue) bool {
        return self.rawBits() & NUMBER_TAG == NUMBER_TAG;
    }

    pub inline fn isNumber(self: EncodedValue) bool {
        return self.rawBits() & NUMBER_TAG != 0;
    }

    pub inline fn isDouble(self: EncodedValue) bool {
        return self.isNumber() and !self.isInt32();
    }

    pub inline fn isCell(self: EncodedValue) bool {
        if (self == .empty or self == .deleted) return false;
        return self.rawBits() & NOT_CELL_MASK == 0;
    }

    pub inline fn isImmediate(self: EncodedValue) bool {
        return switch (self) {
            .null, .false, .true, .undefined => true,
            else => false,
        };
    }

    pub fn fromInternalPrimitive(value: anytype) ConversionError!EncodedValue {
        return switch (value.kind()) {
            .undefined => .undefined,
            .null => .null,
            .boolean => if (value.asBool()) .true else .false,
            .number => fromDouble(value.asNum()),
            .string, .object => error.CellRequiresHandle,
        };
    }

    pub fn toInternalPrimitive(self: EncodedValue, comptime InternalValue: type) ConversionError!InternalValue {
        if (self.isInt32()) return InternalValue.num(@floatFromInt(self.asInt32()));
        if (self.isDouble()) return InternalValue.num(self.asDouble());
        return switch (self) {
            .undefined => InternalValue.undef(),
            .null => InternalValue.nul(),
            .false => InternalValue.boolVal(false),
            .true => InternalValue.boolVal(true),
            .empty => error.EmptyValue,
            .deleted => error.DeletedValue,
            else => if (self.isCell()) error.CellRequiresHandle else error.InvalidEncoding,
        };
    }
};

test "pinned JSC64 constants and layout" {
    try std.testing.expectEqual(@as(usize, 8), @sizeOf(EncodedValue));
    try std.testing.expectEqual(@as(usize, 8), @alignOf(EncodedValue));
    try std.testing.expectEqual(@as(u64, 0xa), EncodedValue.undefined.rawBits());
    try std.testing.expectEqual(@as(u64, 0x2), EncodedValue.null.rawBits());
    try std.testing.expectEqual(@as(u64, 0x6), EncodedValue.false.rawBits());
    try std.testing.expectEqual(@as(u64, 0x7), EncodedValue.true.rawBits());
}

test "pinned JSC64 numbers preserve exact payloads" {
    const ints = [_]i32{ std.math.minInt(i32), -1, 0, 1, std.math.maxInt(i32) };
    for (ints) |value| {
        const encoded = EncodedValue.fromInt32(value);
        try std.testing.expect(encoded.isInt32());
        try std.testing.expectEqual(value, encoded.asInt32());
        try std.testing.expect(!encoded.isCell());
    }
    const double_bits = [_]u64{
        @bitCast(@as(f64, 0.0)),
        @bitCast(@as(f64, -0.0)),
        @bitCast(@as(f64, 1.5)),
        @bitCast(std.math.inf(f64)),
        @bitCast(-std.math.inf(f64)),
        0x7ff8_0000_0000_0001,
        0xfff8_0000_0000_0042,
    };
    for (double_bits) |bits| {
        const encoded = EncodedValue.fromDouble(@bitCast(bits));
        try std.testing.expect(encoded.isDouble());
        try std.testing.expectEqual(bits, @as(u64, @bitCast(encoded.asDouble())));
        try std.testing.expect(!encoded.isCell());
    }
}

test "pinned JSC64 cell validation rejects non-cells" {
    const cell = try EncodedValue.fromCellAddress(0x1000);
    try std.testing.expect(cell.isCell());
    try std.testing.expectEqual(@as(usize, 0x1000), try cell.asCellAddress());
    try std.testing.expectError(error.InvalidCellPointer, EncodedValue.fromCellAddress(0));
    try std.testing.expectError(error.InvalidCellPointer, EncodedValue.fromCellAddress(0x1003));
    try std.testing.expectError(error.InvalidEncoding, EncodedValue.true.asCellAddress());
    try std.testing.expectError(error.InvalidEncoding, EncodedValue.fromInt32(1).asCellAddress());
}
