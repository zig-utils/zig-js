//! WHATWG gb18030 TextDecoder decoder (1/2/4-byte, incl. the 4-byte range map).
//! Appends UTF-8 to `out`; an invalid sequence appends U+FFFD, or returns
//! error.DecodeInvalid in fatal mode.
//!
//! Only gb18030 is implemented here. node/ICU follows WHATWG for gb18030 (so we
//! match it byte-for-byte), but its big5/euc-kr/shift_jis/euc-jp/gbk decoders use
//! legacy ICU converter tables that deviate from the WHATWG indexes by thousands
//! of entries (e.g. big5 PUA remaps) — matching those would mean shipping ICU's
//! tables, so they stay unsupported (RangeError) rather than subtly wrong.
const std = @import("std");
const data = @import("encoding_multibyte_data.zig");

pub const Error = error{ OutOfMemory, DecodeInvalid };

fn emit(arena: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), cp: u21) Error!void {
    var b: [4]u8 = undefined;
    const n = std.unicode.utf8Encode(cp, &b) catch {
        try out.appendSlice(arena, "\u{FFFD}");
        return;
    };
    try out.appendSlice(arena, b[0..n]);
}

fn err(arena: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), fatal: bool) Error!void {
    if (fatal) return error.DecodeInvalid;
    try out.appendSlice(arena, "\u{FFFD}");
}

pub fn isMultibyte(name: []const u8) bool {
    return std.mem.eql(u8, name, "gb18030");
}

pub fn decode(
    arena: std.mem.Allocator,
    out: *std.ArrayListUnmanaged(u8),
    name: []const u8,
    bytes: []const u8,
    fatal: bool,
) Error!void {
    std.debug.assert(std.mem.eql(u8, name, "gb18030"));
    return decodeGb18030(arena, out, bytes, fatal);
}

fn gb18030RangeCp(ptr: usize) ?u21 {
    if ((ptr > 39419 and ptr < 189000) or ptr > 1237575) return null;
    if (ptr == 7457) return 0xE7C7;
    var best: data.Gb18030Range = .{ .ptr = 0, .cp = 0 };
    for (data.gb18030_ranges) |r| {
        if (r.ptr <= ptr) best = r else break;
    }
    return @intCast(best.cp + (ptr - best.ptr));
}

fn decodeGb18030(arena: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), bytes: []const u8, fatal: bool) Error!void {
    var first: u16 = 0;
    var second: u16 = 0;
    var third: u16 = 0;
    var i: usize = 0;
    while (i < bytes.len) {
        const b = bytes[i];
        if (third != 0) {
            if (b < 0x30 or b > 0x39) {
                first = 0;
                second = 0;
                third = 0;
                try err(arena, out, fatal);
                i -= 2; // prepend « second, third, byte » → reprocess from `second`
                continue;
            }
            const ptr: usize = (@as(usize, first - 0x81) * 10 * 126 * 10) +
                (@as(usize, second - 0x30) * 10 * 126) +
                (@as(usize, third - 0x81) * 10) + (b - 0x30);
            first = 0;
            second = 0;
            third = 0;
            if (gb18030RangeCp(ptr)) |cp| {
                try emit(arena, out, cp);
            } else try err(arena, out, fatal);
            i += 1;
            continue;
        }
        if (second != 0) {
            if (b >= 0x81 and b <= 0xFE) {
                third = b;
                i += 1;
                continue;
            }
            first = 0;
            second = 0;
            try err(arena, out, fatal);
            i -= 1; // prepend « second, byte » → reprocess from `second`
            continue;
        }
        if (first != 0) {
            if (b >= 0x30 and b <= 0x39) {
                second = b;
                i += 1;
                continue;
            }
            const L = first;
            first = 0;
            const offset: u16 = if (b < 0x7F) 0x40 else 0x41;
            if ((b >= 0x40 and b <= 0x7E) or (b >= 0x80 and b <= 0xFE)) {
                const ptr: usize = @as(usize, L - 0x81) * 190 + (b - offset);
                if (ptr < data.gb18030.len and data.gb18030[ptr] != 0) {
                    try emit(arena, out, data.gb18030[ptr]);
                    i += 1;
                    continue;
                }
            }
            try err(arena, out, fatal);
            if (b <= 0x7F) continue;
            i += 1;
            continue;
        }
        if (b <= 0x7F) {
            try emit(arena, out, b);
        } else if (b == 0x80) {
            try emit(arena, out, 0x20AC); // gb18030 0x80 → EURO SIGN (matches node/ICU)
        } else if (b >= 0x81 and b <= 0xFE) {
            first = b;
        } else try err(arena, out, fatal);
        i += 1;
    }
    if (first != 0 or second != 0 or third != 0) try err(arena, out, fatal);
}
