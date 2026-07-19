//! Compact decoder tables generated from Home's revision-pinned WebKit fork.
//!
//! Source revision: 7ed99c02e50034f869d0db6d487115bb44332fe4
//! Generator: tools/generate-text-codec-tables.py
//! Packed SHA-256: dfed3a7d3da43b7b003a7241dd6a911d5a4da4c64a00df86aba41e1a15d215ae

const data = @embedFile("data/text_codec_indexes.bin");

const single_offset = 8;
const jis0208_offset = single_offset + 10 * 128 * 2;
const jis0212_offset = jis0208_offset + 11104 * 2;
const big5_offset = jis0212_offset + 7211 * 2;
const euc_kr_offset = big5_offset + 19782 * 4;
const gb18030_offset = euc_kr_offset + 23750 * 2;
const gb18030_ranges_offset = gb18030_offset + 23940 * 2;
const expected_size = gb18030_ranges_offset + 207 * 8;

comptime {
    if (data.len != expected_size) @compileError("pinned TextCodec table size drifted");
    if (!std.mem.eql(u8, data[0..8], "ZJTC0001")) @compileError("pinned TextCodec table header drifted");
}

const std = @import("std");

fn readU16(offset: usize) u16 {
    return @as(u16, data[offset]) | (@as(u16, data[offset + 1]) << 8);
}

fn readU32(offset: usize) u32 {
    return @as(u32, data[offset]) |
        (@as(u32, data[offset + 1]) << 8) |
        (@as(u32, data[offset + 2]) << 16) |
        (@as(u32, data[offset + 3]) << 24);
}

pub fn singleByte(table: u4, byte: u8) u21 {
    std.debug.assert(table < 10 and byte >= 0x80);
    return readU16(single_offset + (@as(usize, table) * 128 + byte - 0x80) * 2);
}

pub fn jis0208(pointer: u16) ?u21 {
    if (pointer >= 11104) return null;
    const code_point = readU16(jis0208_offset + @as(usize, pointer) * 2);
    return if (code_point == 0) null else code_point;
}

pub fn jis0212(pointer: u16) ?u21 {
    if (pointer >= 7211) return null;
    const code_point = readU16(jis0212_offset + @as(usize, pointer) * 2);
    return if (code_point == 0) null else code_point;
}

pub fn big5(pointer: u16) ?u21 {
    if (pointer >= 19782) return null;
    const code_point = readU32(big5_offset + @as(usize, pointer) * 4);
    return if (code_point == 0) null else @intCast(code_point);
}

pub fn eucKr(pointer: u16) ?u21 {
    if (pointer >= 23750) return null;
    const code_point = readU16(euc_kr_offset + @as(usize, pointer) * 2);
    return if (code_point == 0) null else code_point;
}

pub fn gb18030(pointer: u16) u21 {
    std.debug.assert(pointer < 23940);
    return readU16(gb18030_offset + @as(usize, pointer) * 2);
}

pub fn gb18030RangeCodePoint(pointer: u32) ?u21 {
    if ((pointer > 39419 and pointer < 189000) or pointer > 1237575) return null;
    if (pointer == 7457) return 0xe7c7;

    var low: usize = 0;
    var high: usize = 207;
    while (low < high) {
        const middle = low + (high - low) / 2;
        const range_pointer = readU32(gb18030_ranges_offset + middle * 8);
        if (range_pointer <= pointer)
            low = middle + 1
        else
            high = middle;
    }
    if (low == 0) return null;
    const offset = gb18030_ranges_offset + (low - 1) * 8;
    const pointer_offset = readU32(offset);
    const code_point_offset = readU32(offset + 4);
    const code_point = code_point_offset + (pointer - pointer_offset);
    return if (code_point <= 0x10ffff) @intCast(code_point) else null;
}

test "pinned TextCodec indexes expose exact representative entries" {
    try std.testing.expectEqual(@as(?u21, 0x3042), jis0208(283));
    try std.testing.expectEqual(@as(?u21, 0x43f0), big5(942));
    try std.testing.expectEqual(@as(?u21, 0xac02), eucKr(0));
    try std.testing.expectEqual(@as(u21, 0x4e02), gb18030(0));
    try std.testing.expectEqual(@as(?u21, 0x80), gb18030RangeCodePoint(0));
    try std.testing.expectEqual(@as(?u21, 0xe7c7), gb18030RangeCodePoint(7457));
}
