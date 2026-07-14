//! Unicode normalization core for String.prototype.normalize (NFC/NFD/NFKC/NFKD).
//!
//! Follows UAX #15: canonical/compatibility decomposition, canonical ordering,
//! then (for the composing forms) canonical composition. Hangul syllables are
//! (de)composed algorithmically; every other mapping, the combining classes, and
//! the primary-composite set come from the generated `unicode_normalize_data.zig`
//! table (built from the UCD by tools/gen_norm.py).

const std = @import("std");
const data = @import("unicode_normalize_data.zig");

const Codepoint = u21;

pub const Form = enum { nfc, nfd, nfkc, nfkd };

// Hangul jamo/syllable constants (Unicode 3.12): algorithmic (de)composition.
const s_base: Codepoint = 0xAC00;
const l_base: Codepoint = 0x1100;
const v_base: Codepoint = 0x1161;
const t_base: Codepoint = 0x11A7;
const l_count: Codepoint = 19;
const v_count: Codepoint = 21;
const t_count: Codepoint = 28;
const n_count: Codepoint = v_count * t_count; // 588
const s_count: Codepoint = l_count * n_count; // 11172

fn canonicalCombiningClass(cp: Codepoint) u8 {
    var lo: usize = 0;
    var hi: usize = data.ccc_table.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        const e = data.ccc_table[mid];
        if (e.cp == cp) return e.cc;
        if (e.cp < cp) lo = mid + 1 else hi = mid;
    }
    return 0;
}

fn lookupDecompIn(table: []const data.Decomp, cp: Codepoint) ?[]const Codepoint {
    var lo: usize = 0;
    var hi: usize = table.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        const e = table[mid];
        if (e.cp == cp) return e.d;
        if (e.cp < cp) lo = mid + 1 else hi = mid;
    }
    return null;
}

fn lookupDecomp(cp: Codepoint, compat: bool) ?[]const Codepoint {
    if (lookupDecompIn(&data.canon_decomp, cp)) |d| return d;
    if (compat) return lookupDecompIn(&data.compat_decomp, cp);
    return null;
}

fn composePair(a: Codepoint, b: Codepoint) ?Codepoint {
    // Hangul L + V → LV syllable.
    if (a >= l_base and a < l_base + l_count and b >= v_base and b < v_base + v_count) {
        return s_base + ((a - l_base) * v_count + (b - v_base)) * t_count;
    }
    // Hangul LV + T → LVT syllable.
    if (a >= s_base and a < s_base + s_count and (a - s_base) % t_count == 0 and b > t_base and b < t_base + t_count) {
        return a + (b - t_base);
    }
    // Table of primary composites, sorted by (a, b).
    var lo: usize = 0;
    var hi: usize = data.compose_table.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        const e = data.compose_table[mid];
        if (e.a == a and e.b == b) return e.to;
        if (e.a < a or (e.a == a and e.b < b)) lo = mid + 1 else hi = mid;
    }
    return null;
}

fn appendDecomposed(out: *std.ArrayListUnmanaged(Codepoint), alloc: std.mem.Allocator, cp: Codepoint, compat: bool) !void {
    // Hangul syllables decompose algorithmically into L, V (, T) jamo.
    if (cp >= s_base and cp < s_base + s_count) {
        const si = cp - s_base;
        try out.append(alloc, l_base + si / n_count);
        try out.append(alloc, v_base + (si % n_count) / t_count);
        const t = si % t_count;
        if (t != 0) try out.append(alloc, t_base + t);
        return;
    }
    if (lookupDecomp(cp, compat)) |mapping| {
        for (mapping) |mapped| try appendDecomposed(out, alloc, mapped, compat);
    } else {
        try out.append(alloc, cp);
    }
}

fn reorderCanonical(cps: []Codepoint) void {
    var i: usize = 1;
    while (i < cps.len) : (i += 1) {
        const ccc = canonicalCombiningClass(cps[i]);
        if (ccc == 0) continue;
        var j = i;
        while (j > 0) : (j -= 1) {
            const prev_ccc = canonicalCombiningClass(cps[j - 1]);
            if (prev_ccc == 0 or prev_ccc <= ccc) break;
            const tmp = cps[j - 1];
            cps[j - 1] = cps[j];
            cps[j] = tmp;
        }
    }
}

fn compose(out: *std.ArrayListUnmanaged(Codepoint), alloc: std.mem.Allocator, cps: []const Codepoint) !void {
    var starter_index: ?usize = null;
    // Combining class of the last character appended after the active starter
    // (0 = nothing yet). Because `cps` is already canonically ordered, this is the
    // max ccc among the in-between characters, so a candidate is "not blocked"
    // exactly when prev_ccc is 0 or strictly less than the candidate's ccc.
    var prev_ccc: u8 = 0;

    for (cps) |cp| {
        const ccc = canonicalCombiningClass(cp);
        if (starter_index) |si| {
            if (prev_ccc == 0 or prev_ccc < ccc) {
                if (composePair(out.items[si], cp)) |composed| {
                    out.items[si] = composed;
                    continue; // starter absorbed the character; prev_ccc unchanged
                }
            }
        }
        try out.append(alloc, cp);
        if (ccc == 0) {
            starter_index = out.items.len - 1;
            prev_ccc = 0;
        } else {
            prev_ccc = ccc;
        }
    }
}

fn appendUtf8(out: *std.ArrayListUnmanaged(u8), alloc: std.mem.Allocator, cp: Codepoint) !void {
    var buf: [4]u8 = undefined;
    const n = std.unicode.utf8Encode(cp, &buf) catch return;
    try out.appendSlice(alloc, buf[0..n]);
}

pub fn normalize(alloc: std.mem.Allocator, s: []const u8, form: Form) ![]u8 {
    const compat = form == .nfkc or form == .nfkd;
    const do_compose = form == .nfc or form == .nfkc;

    var decomposed: std.ArrayListUnmanaged(Codepoint) = .empty;
    defer decomposed.deinit(alloc);

    var i: usize = 0;
    while (i < s.len) {
        const seq = std.unicode.utf8ByteSequenceLength(s[i]) catch {
            try decomposed.append(alloc, s[i]);
            i += 1;
            continue;
        };
        if (i + seq > s.len) {
            try decomposed.append(alloc, s[i]);
            i += 1;
            continue;
        }
        const cp = std.unicode.utf8Decode(s[i .. i + seq]) catch {
            try decomposed.append(alloc, s[i]);
            i += 1;
            continue;
        };
        try appendDecomposed(&decomposed, alloc, cp, compat);
        i += seq;
    }

    reorderCanonical(decomposed.items);

    var normalized: std.ArrayListUnmanaged(Codepoint) = .empty;
    defer normalized.deinit(alloc);
    if (do_compose) {
        try compose(&normalized, alloc, decomposed.items);
    } else {
        try normalized.appendSlice(alloc, decomposed.items);
    }

    var bytes: std.ArrayListUnmanaged(u8) = .empty;
    errdefer bytes.deinit(alloc);
    for (normalized.items) |cp| try appendUtf8(&bytes, alloc, cp);
    return bytes.toOwnedSlice(alloc);
}

test "normalizes test262 sample forms" {
    const a = std.testing.allocator;

    const s = "\u{1E9B}\u{0323}";
    const nfd = try normalize(a, s, .nfd);
    defer a.free(nfd);
    try std.testing.expectEqualStrings("\u{017F}\u{0323}\u{0307}", nfd);

    const nfkc = try normalize(a, s, .nfkc);
    defer a.free(nfkc);
    try std.testing.expectEqualStrings("\u{1E69}", nfkc);

    const s2 = "\u{00C5}\u{2ADC}\u{0958}\u{2126}\u{0344}";
    const nfc = try normalize(a, s2, .nfc);
    defer a.free(nfc);
    try std.testing.expectEqualStrings("\u{00C5}\u{2ADD}\u{0338}\u{0915}\u{093C}\u{03A9}\u{0308}\u{0301}", nfc);
}

test "nfd canonical equivalence samples" {
    const a = std.testing.allocator;

    const l = try normalize(a, "o\u{0308}", .nfd);
    defer a.free(l);
    const r = try normalize(a, "\u{00F6}", .nfd);
    defer a.free(r);
    try std.testing.expectEqualStrings(l, r);

    const h1 = try normalize(a, "\u{1111}\u{1171}\u{11B6}", .nfd);
    defer a.free(h1);
    const h2 = try normalize(a, "\u{D4DB}", .nfd);
    defer a.free(h2);
    try std.testing.expectEqualStrings(h1, h2);

    const u_left = try normalize(a, "\u{1EF1}", .nfd);
    defer a.free(u_left);
    const u_right = try normalize(a, "u\u{0323}\u{031B}", .nfd);
    defer a.free(u_right);
    try std.testing.expectEqualStrings(u_left, u_right);
}
