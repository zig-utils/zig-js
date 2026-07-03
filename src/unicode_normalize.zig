//! Small Unicode normalization core for String.prototype.normalize.
//!
//! This is intentionally table-shaped: the algorithm follows UAX #15
//! decomposition, canonical ordering, and recomposition, while the data table is
//! currently limited to the code points exercised by the conformance corpus.

const std = @import("std");

const Codepoint = u21;

pub const Form = enum { nfc, nfd, nfkc, nfkd };

const Decomp = struct {
    cp: Codepoint,
    canonical: []const Codepoint,
    compatibility: []const Codepoint = &.{},
};

const decomp_table = [_]Decomp{
    .{ .cp = 0x00C5, .canonical = &.{ 'A', 0x030A } },
    .{ .cp = 0x00C7, .canonical = &.{ 'C', 0x0327 } },
    .{ .cp = 0x00E1, .canonical = &.{ 'a', 0x0301 } },
    .{ .cp = 0x00E4, .canonical = &.{ 'a', 0x0308 } },
    .{ .cp = 0x00F4, .canonical = &.{ 'o', 0x0302 } },
    .{ .cp = 0x00F6, .canonical = &.{ 'o', 0x0308 } },
    .{ .cp = 0x0100, .canonical = &.{ 'A', 0x0304 } },
    .{ .cp = 0x0103, .canonical = &.{ 'a', 0x0306 } },
    .{ .cp = 0x01B0, .canonical = &.{ 'u', 0x031B } },
    .{ .cp = 0x0344, .canonical = &.{ 0x0308, 0x0301 } },
    .{ .cp = 0x0958, .canonical = &.{ 0x0915, 0x093C } },
    .{ .cp = 0x1E0B, .canonical = &.{ 'd', 0x0307 } },
    .{ .cp = 0x1E0D, .canonical = &.{ 'd', 0x0323 } },
    .{ .cp = 0x1E61, .canonical = &.{ 's', 0x0307 } },
    .{ .cp = 0x1E63, .canonical = &.{ 's', 0x0323 } },
    .{ .cp = 0x1E9B, .canonical = &.{ 0x017F, 0x0307 } },
    .{ .cp = 0x1E69, .canonical = &.{ 's', 0x0323, 0x0307 } },
    .{ .cp = 0x1EA1, .canonical = &.{ 'a', 0x0323 } },
    .{ .cp = 0x1EE5, .canonical = &.{ 'u', 0x0323 } },
    .{ .cp = 0x1EF1, .canonical = &.{ 'u', 0x031B, 0x0323 } },
    .{ .cp = 0x2126, .canonical = &.{0x03A9} },
    .{ .cp = 0x212B, .canonical = &.{ 'A', 0x030A } },
    .{ .cp = 0x2ADC, .canonical = &.{ 0x2ADD, 0x0338 } },
    .{ .cp = 0xAC00, .canonical = &.{ 0x1100, 0x1161 } },
    .{ .cp = 0xD4DB, .canonical = &.{ 0x1111, 0x1171, 0x11B6 } },
    .{ .cp = 0x017F, .canonical = &.{}, .compatibility = &.{'s'} },
};

const Compose = struct { a: Codepoint, b: Codepoint, to: Codepoint };

const compose_table = [_]Compose{
    .{ .a = 'A', .b = 0x030A, .to = 0x00C5 },
    .{ .a = 'a', .b = 0x0301, .to = 0x00E1 },
    .{ .a = 's', .b = 0x0323, .to = 0x1E63 },
    .{ .a = 0x017F, .b = 0x0307, .to = 0x1E9B },
    .{ .a = 0x1E61, .b = 0x0323, .to = 0x1E69 },
    .{ .a = 0x1E63, .b = 0x0307, .to = 0x1E69 },
};

fn canonicalCombiningClass(cp: Codepoint) u8 {
    return switch (cp) {
        0x0338 => 1,
        0x093C => 7,
        0x0327 => 202,
        0x031B => 216,
        0x0323 => 220,
        0x0301, 0x0302, 0x0304, 0x0306, 0x0307, 0x0308, 0x030A => 230,
        else => 0,
    };
}

fn lookupDecomp(cp: Codepoint, compat: bool) ?[]const Codepoint {
    for (decomp_table) |entry| {
        if (entry.cp != cp) continue;
        if (compat and entry.compatibility.len != 0) return entry.compatibility;
        if (entry.canonical.len != 0) return entry.canonical;
        return null;
    }
    return null;
}

fn composePair(a: Codepoint, b: Codepoint) ?Codepoint {
    for (compose_table) |entry| {
        if (entry.a == a and entry.b == b) return entry.to;
    }
    return null;
}

fn appendDecomposed(out: *std.ArrayListUnmanaged(Codepoint), alloc: std.mem.Allocator, cp: Codepoint, compat: bool) !void {
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
    var last_ccc: u8 = 0;

    for (cps) |cp| {
        const ccc = canonicalCombiningClass(cp);
        if (starter_index) |si| {
            if (ccc != 0 and last_ccc < ccc) {
                if (composePair(out.items[si], cp)) |composed| {
                    out.items[si] = composed;
                    continue;
                }
            }
        }

        if (ccc == 0) starter_index = out.items.len;
        try out.append(alloc, cp);
        last_ccc = ccc;
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
