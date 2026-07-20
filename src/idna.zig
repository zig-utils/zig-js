//! UTS-46 "domain to ASCII" (IDNA) for the WHATWG URL host parser:
//! non-transitional processing, UseSTD3ASCIIRules=false, CheckHyphens=false.
//! Maps via the generated IdnaMappingTable, NFC-normalizes, then Punycode-encodes
//! (RFC 3492) each label that still contains non-ASCII. Returns null on any
//! disallowed code point or a malformed label.
const std = @import("std");
const data = @import("unicode_idna_data.zig");
const unicode_normalize = @import("unicode_normalize.zig");

const Lookup = union(enum) { keep, ignored, disallowed, mapped: []const u21 };

fn lookup(cp: u21) Lookup {
    var lo: usize = 0;
    var hi: usize = data.entries.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        const e = data.entries[mid];
        if (cp < e.lo) {
            hi = mid;
        } else if (cp > e.hi) {
            lo = mid + 1;
        } else return switch (e.action) {
            .mapped => .{ .mapped = data.map_data[e.off .. e.off + e.len] },
            .ignored => .ignored,
            .disallowed => .disallowed,
        };
    }
    return .keep; // not listed → valid, kept as-is
}

// RFC 3492 Bootstring parameters for Punycode.
const base = 36;
const tmin = 1;
const tmax = 26;
const skew = 38;
const damp = 700;
const initial_bias = 72;
const initial_n = 128;

fn digit(d: u32) u8 {
    return if (d < 26) @intCast('a' + d) else @intCast('0' + (d - 26));
}

fn adapt(delta_in: u64, numpoints: u64, firsttime: bool) u64 {
    var delta = if (firsttime) delta_in / damp else delta_in / 2;
    delta += delta / numpoints;
    var k: u64 = 0;
    while (delta > ((base - tmin) * tmax) / 2) : (k += base) delta /= (base - tmin);
    return k + ((base - tmin + 1) * delta) / (delta + skew);
}

/// Punycode-encode a label's code points (RFC 3492), without the `xn--` prefix.
fn punyEncode(arena: std.mem.Allocator, cps: []const u21) !?[]const u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    var n: u64 = initial_n;
    var delta: u64 = 0;
    var bias: u64 = initial_bias;
    var b: usize = 0;
    for (cps) |c| if (c < 0x80) {
        try out.append(arena, @intCast(c));
        b += 1;
    };
    var h = b;
    if (b > 0) try out.append(arena, '-');
    while (h < cps.len) {
        var m: u64 = 0x10FFFF + 1;
        for (cps) |c| if (@as(u64, c) >= n and @as(u64, c) < m) {
            m = c;
        };
        delta += (m - n) * (@as(u64, h) + 1);
        n = m;
        for (cps) |cc| {
            const c: u64 = cc;
            if (c < n) delta += 1;
            if (c == n) {
                var q = delta;
                var k: u64 = base;
                while (true) : (k += base) {
                    const t: u64 = if (k <= bias) tmin else if (k >= bias + tmax) tmax else k - bias;
                    if (q < t) break;
                    try out.append(arena, digit(@intCast(t + (q - t) % (base - t))));
                    q = (q - t) / (base - t);
                }
                try out.append(arena, digit(@intCast(q)));
                bias = adapt(delta, @as(u64, h) + 1, h == b);
                delta = 0;
                h += 1;
            }
        }
        delta += 1;
        n += 1;
    }
    return out.items;
}

fn digitValue(c: u8) ?u32 {
    return switch (c) {
        'a'...'z' => c - 'a',
        'A'...'Z' => c - 'A',
        '0'...'9' => c - '0' + 26,
        else => null,
    };
}

/// Punycode-decode `input` (the text after `xn--`) to code points (RFC 3492), or
/// null on any malformation (bad digit, truncation, or overflow).
fn punyDecode(arena: std.mem.Allocator, input: []const u8) !?[]const u21 {
    var out: std.ArrayListUnmanaged(u21) = .empty;
    var n: u64 = initial_n;
    var bias: u64 = initial_bias;
    // Basic code points: everything before the last hyphen.
    var pos: usize = 0;
    if (std.mem.lastIndexOfScalar(u8, input, '-')) |last| {
        for (input[0..last]) |c| {
            if (c >= 0x80) return null;
            try out.append(arena, c);
        }
        pos = last + 1;
    }
    var i: u64 = 0;
    while (pos < input.len) {
        const oldi = i;
        var w: u64 = 1;
        var k: u64 = base;
        while (true) : (k += base) {
            if (pos >= input.len) return null;
            const d = digitValue(input[pos]) orelse return null;
            pos += 1;
            if (d > (0x7fffffff - i) / w) return null;
            i += d * w;
            const t: u64 = if (k <= bias) tmin else if (k >= bias + tmax) tmax else k - bias;
            if (d < t) break;
            if (w > 0x7fffffff / (base - t)) return null;
            w *= (base - t);
        }
        const out_len = out.items.len + 1;
        bias = adapt(i - oldi, out_len, oldi == 0);
        if (i / out_len > 0x10FFFF - n) return null;
        n += i / out_len;
        i %= out_len;
        if (n > 0x10FFFF or (n >= 0xD800 and n <= 0xDFFF)) return null;
        try out.insert(arena, @intCast(i), @intCast(n));
        i += 1;
    }
    return out.items;
}

/// Validate an `xn--` label: it must be canonical Punycode — decode it, then
/// re-encode and require a case-insensitive round-trip match (node/ICU reject a
/// non-canonical or malformed Punycode label).
fn validXnLabel(arena: std.mem.Allocator, puny: []const u8, is_bidi: bool) !bool {
    const cps = (try punyDecode(arena, puny)) orelse return false;
    if (cps.len == 0) return false;
    if (!validateLabel(cps)) return false;
    if (is_bidi and !checkBidiLabel(cps)) return false;
    const re = (try punyEncode(arena, cps)) orelse return false;
    return std.ascii.eqlIgnoreCase(re, puny);
}

fn isMark(cp: u21) bool {
    var lo: usize = 0;
    var hi: usize = data.mark_ranges.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        const r = data.mark_ranges[mid];
        if (cp < r.lo) hi = mid else if (cp > r.hi) lo = mid + 1 else return true;
    }
    return false;
}

fn isVirama(cp: u21) bool {
    for (data.virama) |v| if (v == cp) return true;
    return false;
}

fn joinType(cp: u21) ?data.JoinType {
    var lo: usize = 0;
    var hi: usize = data.join_ranges.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        const r = data.join_ranges[mid];
        if (cp < r.lo) hi = mid else if (cp > r.hi) lo = mid + 1 else return r.jt;
    }
    return null;
}

/// UTS-46 label validity (the subset the URL host parser needs, CheckHyphens
/// off): a label may not begin with a combining mark, and ZWJ/ZWNJ (CheckJoiners)
/// are only valid in a virama / joining-type context (RFC 5892 A.1/A.2).
fn validateLabel(cps: []const u21) bool {
    if (cps.len == 0) return true;
    if (isMark(cps[0])) return false;
    // Every code point must be "valid"/"deviation" (kept) — a mapped, ignored,
    // or disallowed code point means the label is not in canonical form. This is
    // what rejects a bogus `xn--` label that decodes to disallowed code points.
    for (cps) |cp| switch (lookup(cp)) {
        .keep => {},
        else => return false,
    };
    for (cps, 0..) |cp, i| {
        if (cp == 0x200D) { // ZWJ: only immediately after a virama
            if (i == 0 or !isVirama(cps[i - 1])) return false;
        } else if (cp == 0x200C) { // ZWNJ (CheckJoiners, matching ICU)
            if (i == 0) return false;
            if (isVirama(cps[i - 1])) continue;
            // Before: skip {T,R}, require {L,D}. After: skip {T,L}, require {R,D}.
            // (ICU is looser than strict RFC 5892, which forbids R before.)
            var ok_before = false;
            var b = i - 1;
            while (true) {
                const jt = joinType(cps[b]);
                if (jt != .t and jt != .r) {
                    ok_before = (jt == .l or jt == .d);
                    break;
                }
                if (b == 0) break;
                b -= 1;
            }
            if (!ok_before) return false;
            var ok_after = false;
            var f = i + 1;
            while (f < cps.len) : (f += 1) {
                const jt = joinType(cps[f]);
                if (jt != .t and jt != .l) {
                    ok_after = (jt == .r or jt == .d);
                    break;
                }
            }
            if (!ok_after) return false;
        }
    }
    return true;
}

fn bidiClass(cp: u21) data.BidiClass {
    var lo: usize = 0;
    var hi: usize = data.bidi_ranges.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        const r = data.bidi_ranges[mid];
        if (cp < r.lo) hi = mid else if (cp > r.hi) lo = mid + 1 else return r.bc;
    }
    return .l; // unlisted → L (the default)
}

/// RFC 5893 Bidi Rule: applied to every label of a "bidi domain" (a domain with
/// any R/AL/AN code point). An RTL label (first char R/AL) admits only RTL-safe
/// classes and must end in R/AL/EN/AN; an LTR label (first char L) admits only
/// LTR-safe classes and must end in L/EN; EN and AN can't mix in an RTL label.
fn checkBidiLabel(cps: []const u21) bool {
    if (cps.len == 0) return true;
    // Direction is set by the first STRONG character (matching ICU, which is
    // looser than RFC 5893 rule 1: a leading weak char — EN/AN/ON — does not
    // reject, it just doesn't set direction). No strong char → LTR.
    var rtl = false;
    for (cps) |cp| {
        const bc = bidiClass(cp);
        if (bc == .r or bc == .al) {
            rtl = true;
            break;
        }
        if (bc == .l) break;
    }
    var last = cps.len;
    while (last > 0 and bidiClass(cps[last - 1]) == .nsm) last -= 1;
    if (last == 0) return false;
    const last_bc = bidiClass(cps[last - 1]);
    if (rtl) {
        var has_en = false;
        var has_an = false;
        for (cps) |cp| {
            const bc = bidiClass(cp);
            switch (bc) {
                .r, .al, .an, .en, .es, .cs, .et, .on, .bn, .nsm => {},
                else => return false, // rule 2
            }
            if (bc == .en) has_en = true;
            if (bc == .an) has_an = true;
        }
        if (has_en and has_an) return false; // rule 4
        switch (last_bc) { // rule 3
            .r, .al, .en, .an => {},
            else => return false,
        }
    } else {
        for (cps) |cp| switch (bidiClass(cp)) {
            .l, .en, .es, .cs, .et, .on, .bn, .nsm => {},
            else => return false, // rule 5
        };
        switch (last_bc) { // rule 6
            .l, .en => {},
            else => return false,
        }
    }
    return true;
}

/// WHATWG forbidden domain code point: a forbidden host code point, a C0
/// control, U+007F, or U+0025 (%). The ToASCII result must contain none.
fn isForbiddenDomainCodePoint(c: u8) bool {
    return switch (c) {
        0x00...0x20, 0x7f => true,
        '%', '#', '/', ':', '<', '>', '?', '@', '[', '\\', ']', '^', '|' => true,
        else => false,
    };
}

fn decodeUtf8(bytes: []const u8, i: *usize) ?u21 {
    const len = std.unicode.utf8ByteSequenceLength(bytes[i.*]) catch return null;
    if (i.* + len > bytes.len) return null;
    const cp = std.unicode.utf8Decode(bytes[i.* .. i.* + len]) catch return null;
    i.* += len;
    return cp;
}

/// Convert a Unicode domain to its ASCII (Punycode) form. `input` is UTF-8.
pub fn domainToAscii(arena: std.mem.Allocator, input: []const u8) !?[]const u8 {
    // 1. Map: apply the IdnaMappingTable to every code point.
    var mapped: std.ArrayListUnmanaged(u8) = .empty;
    var i: usize = 0;
    while (i < input.len) {
        const start = i;
        const cp = decodeUtf8(input, &i) orelse return null;
        switch (lookup(cp)) {
            .keep => try mapped.appendSlice(arena, input[start..i]),
            .ignored => {},
            .disallowed => return null,
            .mapped => |targets| {
                for (targets) |t| {
                    var buf: [4]u8 = undefined;
                    const n = std.unicode.utf8Encode(t, &buf) catch return null;
                    try mapped.appendSlice(arena, buf[0..n]);
                }
            },
        }
    }
    // 2. NFC-normalize the mapped string.
    const norm = try unicode_normalize.normalize(arena, mapped.items, .nfc);
    // A "bidi domain" (any R/AL/AN code point) triggers CheckBidi on every label.
    var is_bidi = false;
    {
        var k: usize = 0;
        while (k < norm.len) {
            const cp = decodeUtf8(norm, &k) orelse return null;
            switch (bidiClass(cp)) {
                .r, .al, .an => is_bidi = true,
                else => {},
            }
            if (is_bidi) break;
        }
    }
    // 3. Punycode-encode each label that still has non-ASCII.
    var out: std.ArrayListUnmanaged(u8) = .empty;
    var first = true;
    var it = std.mem.splitScalar(u8, norm, '.');
    while (it.next()) |label| {
        if (!first) try out.append(arena, '.');
        first = false;
        var has_unicode = false;
        for (label) |c| if (c >= 0x80) {
            has_unicode = true;
            break;
        };
        if (!has_unicode) {
            // A pure-ASCII `xn--` label must be canonical Punycode (a bare
            // `xn--` with no payload is invalid).
            if (label.len >= 4 and std.ascii.eqlIgnoreCase(label[0..4], "xn--")) {
                if (!try validXnLabel(arena, label[4..], is_bidi)) return null;
            }
            try out.appendSlice(arena, label);
            continue;
        }
        var cps: std.ArrayListUnmanaged(u21) = .empty;
        var j: usize = 0;
        while (j < label.len) try cps.append(arena, decodeUtf8(label, &j) orelse return null);
        if (!validateLabel(cps.items)) return null;
        if (is_bidi and !checkBidiLabel(cps.items)) return null;
        const enc = (try punyEncode(arena, cps.items)) orelse return null;
        try out.appendSlice(arena, "xn--");
        try out.appendSlice(arena, enc);
    }
    // The ToASCII result must contain no forbidden domain code point.
    for (out.items) |c| if (isForbiddenDomainCodePoint(c)) return null;
    return out.items;
}
