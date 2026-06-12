//! Unicode case mapping for String.prototype.to{Upper,Lower}Case.
//!
//! ECMAScript defines these via the Unicode `SpecialCasing.txt` full mappings
//! (locale-independent) layered on the simple 1:1 mappings from
//! `UnicodeData.txt`. The tables in `unicode_case_data.zig` are generated
//! directly from those files (see tools/gen_case.sh), so coverage is the full
//! Unicode range. The only conditional mapping ECMAScript keeps is Final_Sigma,
//! which we evaluate from surrounding context here; all other conditional
//! (locale-specific) SpecialCasing entries are intentionally excluded.

const std = @import("std");
const data = @import("unicode_case_data.zig");

pub const Codepoint = u21;

/// Up to three codepoints (the longest full upper mapping is 3, e.g. ﬃ→FFI).
pub const Mapped = struct {
    cps: [3]Codepoint = .{ 0, 0, 0 },
    len: u8 = 0,
};

/// Binary search a sorted `Pair` table; returns the mapping or null.
fn lookupPair(table: []const data.Pair, cp: Codepoint) ?Codepoint {
    var lo: usize = 0;
    var hi: usize = table.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        const e = table[mid];
        if (cp < e.cp) {
            hi = mid;
        } else if (cp > e.cp) {
            lo = mid + 1;
        } else return e.to;
    }
    return null;
}

/// Binary search a sorted `Full` table; returns the entry or null.
fn lookupFull(table: []const data.Full, cp: Codepoint) ?data.Full {
    var lo: usize = 0;
    var hi: usize = table.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        const e = table[mid];
        if (cp < e.cp) {
            hi = mid;
        } else if (cp > e.cp) {
            lo = mid + 1;
        } else return e;
    }
    return null;
}

/// Simple (1:1) uppercase mapping. Returns cp unchanged when uncased.
pub fn simpleUpper(cp: Codepoint) Codepoint {
    return lookupPair(&data.simple_upper, cp) orelse cp;
}

/// Simple (1:1) lowercase mapping. Returns cp unchanged when uncased.
pub fn simpleLower(cp: Codepoint) Codepoint {
    return lookupPair(&data.simple_lower, cp) orelse cp;
}

fn toMapped(f: data.Full) Mapped {
    return .{ .cps = .{ f.a, f.b, f.c }, .len = f.len };
}

/// Full (1:N) uppercase mapping; falls back to the simple mapping.
fn fullUpper(cp: Codepoint) Mapped {
    if (lookupFull(&data.full_upper, cp)) |f| return toMapped(f);
    return .{ .cps = .{ simpleUpper(cp), 0, 0 }, .len = 1 };
}

/// Cased property — used by the Final_Sigma context scan. UnicodeData encodes
/// it via the simple mappings: a character with an upper or lower mapping is
/// cased, as is one that is itself the target of a mapping (already upper/lower).
fn isCased(cp: Codepoint) bool {
    return switch (cp) {
        'A'...'Z', 'a'...'z' => true,
        0xAA, 0xB5, 0xBA => true,
        0xC0...0xD6, 0xD8...0xF6, 0xF8...0x1FF => true,
        0x200...0x24F => true, // Latin Extended-A/B
        0x250...0x2AF => true, // IPA Extensions (Ll)
        0x370...0x3FF => true, // Greek
        0x400...0x52F => true, // Cyrillic
        0x531...0x556, 0x561...0x587 => true, // Armenian
        0x10A0...0x10FF => true, // Georgian
        0x1E00...0x1FFF => true, // Latin/Greek Extended Additional
        0x2C00...0x2D2F => true, // Glagolitic / Georgian Supplement
        0xFB00...0xFB17 => true, // Latin/Armenian ligatures
        0xFF21...0xFF3A, 0xFF41...0xFF5A => true, // fullwidth Latin
        0x1D400...0x1D7CB => true, // mathematical alphanumeric symbols
        else => false,
    };
}

/// Combining marks / MidLetter chars are transparent to the Final_Sigma scan.
fn isCaseIgnorable(cp: Codepoint) bool {
    return switch (cp) {
        0x27, 0x2E, 0x2019, 0xB7, 0x387 => true, // MidLetter apostrophes / middots / full stop
        0x2D, 0xAD, 0x55A, 0x58A, 0x180E => true,
        0x300...0x36F => true, // combining diacritical marks
        0x2B0...0x2FF => true, // spacing modifier letters (incl. 0x2BC ʼ)
        0x483...0x489 => true, // Cyrillic combining marks
        0x591...0x5BD, 0x5BF, 0x5C1, 0x5C2 => true, // Hebrew points
        0x1D165...0x1D169, 0x1D16D...0x1D172, 0x1D242...0x1D244 => true, // musical combining marks
        0x1AB0...0x1AFF, 0x1DC0...0x1DFF => true, // combining marks extended
        0x2000...0x200F => true, // spaces/format (treated transparent)
        0xFE20...0xFE2F => true, // combining half marks
        else => false,
    };
}

const Case = enum { upper, lower };

/// Map `s` (UTF-8) to upper/lowercase, allocating the result on `alloc`.
fn mapAlloc(alloc: std.mem.Allocator, s: []const u8, comptime which: Case) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(alloc);
    var buf: [4]u8 = undefined;

    var i: usize = 0;
    while (i < s.len) {
        const seq = std.unicode.utf8ByteSequenceLength(s[i]) catch {
            try out.append(alloc, s[i]);
            i += 1;
            continue;
        };
        if (i + seq > s.len) {
            try out.append(alloc, s[i]);
            i += 1;
            continue;
        }
        const cp = std.unicode.utf8Decode(s[i .. i + seq]) catch {
            try out.append(alloc, s[i]);
            i += 1;
            continue;
        };

        switch (which) {
            .upper => {
                const m = fullUpper(cp);
                for (m.cps[0..m.len]) |mc| {
                    const n = std.unicode.utf8Encode(@intCast(mc), &buf) catch 0;
                    try out.appendSlice(alloc, buf[0..n]);
                }
            },
            .lower => {
                if (cp == 0x3A3) {
                    // Σ: Final_Sigma is the only conditional lower mapping kept.
                    const mc = finalSigma(s, i, i + seq);
                    const n = std.unicode.utf8Encode(@intCast(mc), &buf) catch 0;
                    try out.appendSlice(alloc, buf[0..n]);
                } else if (lookupFull(&data.full_lower, cp)) |f| {
                    const seq3 = [_]Codepoint{ f.a, f.b, f.c };
                    for (seq3[0..f.len]) |mc| {
                        const n = std.unicode.utf8Encode(@intCast(mc), &buf) catch 0;
                        try out.appendSlice(alloc, buf[0..n]);
                    }
                } else {
                    const n = std.unicode.utf8Encode(@intCast(simpleLower(cp)), &buf) catch 0;
                    try out.appendSlice(alloc, buf[0..n]);
                }
            },
        }
        i += seq;
    }
    return out.toOwnedSlice(alloc);
}

/// Final_Sigma: Σ lowercases to ς (U+03C2) when preceded by a cased letter and
/// not followed by one (case-ignorable chars are transparent); else σ (U+03C3).
fn finalSigma(s: []const u8, start: usize, after: usize) Codepoint {
    var before_cased = false;
    var j = start;
    while (j > 0) {
        const cp = prevCp(s, &j) orelse break;
        if (isCaseIgnorable(cp)) continue;
        before_cased = isCased(cp);
        break;
    }
    if (!before_cased) return 0x3C3; // σ — not preceded by a cased letter

    var k = after;
    while (k < s.len) {
        const seq = std.unicode.utf8ByteSequenceLength(s[k]) catch break;
        if (k + seq > s.len) break;
        const cp = std.unicode.utf8Decode(s[k .. k + seq]) catch break;
        k += seq;
        if (isCaseIgnorable(cp)) continue;
        if (isCased(cp)) return 0x3C3; // σ — followed by a cased letter
        break;
    }
    return 0x3C2; // ς — final position
}

/// Decode the codepoint ending just before `*j`, moving `*j` to its start.
fn prevCp(s: []const u8, j: *usize) ?Codepoint {
    var p = j.*;
    if (p == 0) return null;
    p -= 1;
    while (p > 0 and (s[p] & 0xC0) == 0x80) p -= 1;
    const seq = std.unicode.utf8ByteSequenceLength(s[p]) catch {
        j.* = p;
        return null;
    };
    const cp = std.unicode.utf8Decode(s[p .. p + seq]) catch {
        j.* = p;
        return null;
    };
    j.* = p;
    return cp;
}

pub fn toUpper(alloc: std.mem.Allocator, s: []const u8) ![]u8 {
    return mapAlloc(alloc, s, .upper);
}

pub fn toLower(alloc: std.mem.Allocator, s: []const u8) ![]u8 {
    return mapAlloc(alloc, s, .lower);
}

test "ascii" {
    const a = std.testing.allocator;
    const u = try toUpper(a, "hello");
    defer a.free(u);
    try std.testing.expectEqualStrings("HELLO", u);
    const l = try toLower(a, "HeLLo");
    defer a.free(l);
    try std.testing.expectEqualStrings("hello", l);
}

test "latin-1" {
    const a = std.testing.allocator;
    const u = try toUpper(a, "àbÿ");
    defer a.free(u);
    try std.testing.expectEqualStrings("ÀBŸ", u);
}

test "sharp s and ligatures expand" {
    const a = std.testing.allocator;
    const u = try toUpper(a, "straße ﬁ");
    defer a.free(u);
    try std.testing.expectEqualStrings("STRASSE FI", u);
}

test "ffi ligature" {
    const a = std.testing.allocator;
    const u = try toUpper(a, "\u{FB03}");
    defer a.free(u);
    try std.testing.expectEqualStrings("FFI", u);
}

test "final sigma" {
    const a = std.testing.allocator;
    const l = try toLower(a, "ΟΔΟΣ"); // Σ at end → ς
    defer a.free(l);
    try std.testing.expectEqualStrings("οδος", l);
    const l2 = try toLower(a, "ΣΟ"); // Σ at start → σ
    defer a.free(l2);
    try std.testing.expectEqualStrings("σο", l2);
}

test "final sigma case-ignorable context" {
    const a = std.testing.allocator;
    const l = try toLower(a, "A\u{180E}\u{03A3}");
    defer a.free(l);
    try std.testing.expectEqualStrings("a\u{180E}\u{03C2}", l);

    const l2 = try toLower(a, "\u{1D4A2}\u{03A3}");
    defer a.free(l2);
    try std.testing.expectEqualStrings("\u{1D4A2}\u{03C2}", l2);

    const l3 = try toLower(a, "A.\u{03A3}");
    defer a.free(l3);
    try std.testing.expectEqualStrings("a.\u{03C2}", l3);
}

test "greek extended full upper" {
    const a = std.testing.allocator;
    // U+0390 → U+0399 U+0308 U+0301
    const u = try toUpper(a, "\u{0390}");
    defer a.free(u);
    try std.testing.expectEqualStrings("\u{0399}\u{0308}\u{0301}", u);
}

test "dotted capital I lowercases to two cps" {
    const a = std.testing.allocator;
    const l = try toLower(a, "\u{0130}");
    defer a.free(l);
    try std.testing.expectEqualStrings("\u{0069}\u{0307}", l);
}

test "greek and cyrillic simple" {
    const a = std.testing.allocator;
    const u = try toUpper(a, "αβ привет");
    defer a.free(u);
    try std.testing.expectEqualStrings("ΑΒ ПРИВЕТ", u);
}
