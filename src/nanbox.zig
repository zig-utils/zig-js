//! NaN-boxed `Value` codec — the 8-byte value representation that gates Phase 7
//! blocker #7 (issue zig-utils/zig-js#1, docs/threads/P7-gil-removal.md).
//!
//! The engine's `Value` is today a ~24-byte tagged union (`value.zig`). A slot
//! that wide cannot be read or written as one atomic machine word, so a reader
//! tears against a concurrent writer once the GIL is gone (M3). NaN-boxing packs
//! every value into a single `u64`, making a slot one atomic word — the design
//! input the audit calls for *before* any ungil bring-up.
//!
//! This module is the **codec only**: encode/decode for every value kind, with
//! exhaustive round-trip tests. Nothing in the engine imports it yet — swapping
//! `Value` over is a separate, de-risked step (and depends on strings becoming a
//! single-pointer cell, since a `[]const u8` slice is two words). Proving the
//! encoding in isolation here is the same discipline used for the GC mechanism:
//! get the hard, error-prone core provably correct first.
//!
//! ## Encoding (64-bit, ≤48-bit pointers — x86-64 / arm64 user space)
//!
//! A `f64` reinterpreted as `u64` spans the whole range. Boxed (non-number)
//! values live in the **negative quiet-NaN** region, which hardware never
//! produces for ordinary results:
//!
//! ```
//! boxed iff (bits & BOX_MASK) == BOX_MASK,  BOX_MASK = 0xFFF8_0000_0000_0000
//! ```
//!
//! That region is `sign=1, exp=0x7FF (all ones), top mantissa bit=1` — a
//! negative quiet NaN. CPUs emit the *positive* canonical qNaN
//! (`0x7FF8_0000_0000_0000`) for NaN results, and `encodeNumber` canonicalizes
//! any NaN input to that positive form, so no real `f64` ever lands in the boxed
//! region. Everything that is not boxed is therefore a number.
//!
//! Within a boxed word: bits 50..48 are a 3-bit `Tag`, bits 47..0 are a 48-bit
//! payload (a pointer, or a boolean bit). Tag 0 is intentionally unused, so the
//! bare `BOX_MASK` pattern decodes to nothing valid.

const std = @import("std");

/// Boxed-value marker: negative quiet-NaN prefix (sign + exp=0x7FF + qNaN bit).
pub const BOX_MASK: u64 = 0xFFF8_0000_0000_0000;
/// Canonical NaN we emit for every NaN number — positive qNaN, *not* boxed.
pub const CANON_NAN: u64 = 0x7FF8_0000_0000_0000;

const TAG_SHIFT: u6 = 48;
const TAG_MASK_BITS: u64 = 0x7; // 3 bits
const PAYLOAD_MASK: u64 = 0x0000_FFFF_FFFF_FFFF; // low 48 bits

/// The boxed value kinds. Numbers are *not* tagged (any non-boxed word is a
/// number), so they have no entry here. Tag 0 is reserved/unused.
pub const Tag = enum(u3) {
    object = 1,
    string = 2,
    boolean = 3,
    undefined = 4,
    null = 5,
};

/// A NaN-boxed value: one machine word.
pub const NanBox = enum(u64) {
    _,

    pub inline fn bits(self: NanBox) u64 {
        return @intFromEnum(self);
    }

    inline fn from(b: u64) NanBox {
        return @enumFromInt(b);
    }

    inline fn boxed(t: Tag, payload: u64) NanBox {
        std.debug.assert(payload & ~PAYLOAD_MASK == 0); // payload fits in 48 bits
        return from(BOX_MASK | (@as(u64, @intFromEnum(t)) << TAG_SHIFT) | payload);
    }

    // ---- Constructors -----------------------------------------------------

    /// Encode an `f64`. NaN inputs canonicalize to a single non-boxed pattern,
    /// so a number is never mistaken for a boxed value.
    pub fn encodeNumber(n: f64) NanBox {
        if (std.math.isNan(n)) return from(CANON_NAN);
        return from(@bitCast(n));
    }

    pub fn encodeUndefined() NanBox {
        return boxed(.undefined, 0);
    }

    pub fn encodeNull() NanBox {
        return boxed(.null, 0);
    }

    pub fn encodeBool(b: bool) NanBox {
        return boxed(.boolean, @intFromBool(b));
    }

    /// Encode an opaque cell pointer (object). The pointer must fit in 48 bits
    /// (true for x86-64 / arm64 user-space heap allocations).
    pub fn encodeObject(ptr: *anyopaque) NanBox {
        return boxed(.object, @intFromPtr(ptr));
    }

    /// Encode a string *cell* pointer. (A NaN-boxed string is necessarily a
    /// single pointer to a {ptr,len} cell, not an inline slice — the string-cell
    /// migration the engine integration depends on.)
    pub fn encodeString(ptr: *anyopaque) NanBox {
        return boxed(.string, @intFromPtr(ptr));
    }

    // ---- Discriminators ---------------------------------------------------

    pub inline fn isNumber(self: NanBox) bool {
        return (self.bits() & BOX_MASK) != BOX_MASK;
    }

    inline fn rawTag(self: NanBox) u3 {
        return @truncate(self.bits() >> TAG_SHIFT);
    }

    /// The boxed tag, or null if this is a number (or the unused tag 0).
    pub fn tag(self: NanBox) ?Tag {
        if (self.isNumber()) return null;
        return switch (self.rawTag()) {
            @intFromEnum(Tag.object) => .object,
            @intFromEnum(Tag.string) => .string,
            @intFromEnum(Tag.boolean) => .boolean,
            @intFromEnum(Tag.undefined) => .undefined,
            @intFromEnum(Tag.null) => .null,
            else => null,
        };
    }

    pub inline fn isObject(self: NanBox) bool {
        return !self.isNumber() and self.rawTag() == @intFromEnum(Tag.object);
    }
    pub inline fn isString(self: NanBox) bool {
        return !self.isNumber() and self.rawTag() == @intFromEnum(Tag.string);
    }
    pub inline fn isBool(self: NanBox) bool {
        return !self.isNumber() and self.rawTag() == @intFromEnum(Tag.boolean);
    }
    pub inline fn isUndefined(self: NanBox) bool {
        return !self.isNumber() and self.rawTag() == @intFromEnum(Tag.undefined);
    }
    pub inline fn isNull(self: NanBox) bool {
        return !self.isNumber() and self.rawTag() == @intFromEnum(Tag.null);
    }

    // ---- Accessors (caller checks the kind first) -------------------------

    pub inline fn asNumber(self: NanBox) f64 {
        std.debug.assert(self.isNumber());
        return @bitCast(self.bits());
    }

    pub inline fn asBool(self: NanBox) bool {
        std.debug.assert(self.isBool());
        return (self.bits() & PAYLOAD_MASK) != 0;
    }

    pub inline fn asPointer(self: NanBox) *anyopaque {
        std.debug.assert(self.isObject() or self.isString());
        return @ptrFromInt(self.bits() & PAYLOAD_MASK);
    }
};

// ---------------------------------------------------------------------------
// Tests — the codec must round-trip every kind, and crucially must classify
// *every* f64 (including all the NaN/Inf/denormal edge cases) as a number, so a
// computed value can never be mistaken for a boxed pointer.
// ---------------------------------------------------------------------------

test "nanbox: singletons and booleans round-trip and are distinct" {
    const u = NanBox.encodeUndefined();
    const n = NanBox.encodeNull();
    const t = NanBox.encodeBool(true);
    const f = NanBox.encodeBool(false);

    try std.testing.expect(u.isUndefined() and !u.isNull() and !u.isNumber());
    try std.testing.expect(n.isNull() and !n.isUndefined());
    try std.testing.expect(t.isBool() and t.asBool() == true);
    try std.testing.expect(f.isBool() and f.asBool() == false);
    try std.testing.expect(u.bits() != n.bits() and t.bits() != f.bits());
    try std.testing.expectEqual(Tag.undefined, u.tag().?);
    try std.testing.expectEqual(Tag.boolean, t.tag().?);
}

test "nanbox: pointers round-trip for object and string tags" {
    var a: u64 = 0xCAFE;
    var b: u64 = 0x1234;
    const pa: *anyopaque = @ptrCast(&a);
    const pb: *anyopaque = @ptrCast(&b);

    const o = NanBox.encodeObject(pa);
    const s = NanBox.encodeString(pb);
    try std.testing.expect(o.isObject() and !o.isString() and !o.isNumber());
    try std.testing.expect(s.isString() and !s.isObject());
    try std.testing.expectEqual(pa, o.asPointer());
    try std.testing.expectEqual(pb, s.asPointer());
    // Same pointer under different tags encodes differently but decodes equal.
    const o2 = NanBox.encodeObject(pb);
    try std.testing.expect(o2.bits() != s.bits());
    try std.testing.expectEqual(s.asPointer(), o2.asPointer());
}

test "nanbox: ordinary numbers round-trip exactly" {
    const cases = [_]f64{
        0.0,                  -0.0,                1.0,             -1.0,
        3.14159265358979,     -2.718281828,        1e308,           -1e308,
        1e-308,               4503599627370496.0,  -9007199254740991.0,
        std.math.floatMin(f64), std.math.floatMax(f64),
    };
    for (cases) |n| {
        const v = NanBox.encodeNumber(n);
        try std.testing.expect(v.isNumber());
        try std.testing.expect(!v.isObject() and !v.isBool() and !v.isUndefined());
        try std.testing.expectEqual(n, v.asNumber());
    }
    // Signed-zero bit pattern is preserved (1/-0 == -inf must stay derivable).
    try std.testing.expectEqual(@as(u64, 0x8000_0000_0000_0000), NanBox.encodeNumber(-0.0).bits());
}

test "nanbox: infinities are numbers and round-trip" {
    const pinf = NanBox.encodeNumber(std.math.inf(f64));
    const ninf = NanBox.encodeNumber(-std.math.inf(f64));
    try std.testing.expect(pinf.isNumber() and ninf.isNumber());
    try std.testing.expect(std.math.isPositiveInf(pinf.asNumber()));
    try std.testing.expect(std.math.isNegativeInf(ninf.asNumber()));
}

test "nanbox: every NaN canonicalizes to a number, never a boxed value" {
    // A grab-bag of NaN bit patterns (quiet, signaling, both signs, payloads)
    // — each must classify as a number, not collide with the boxed region.
    const nan_bits = [_]u64{
        0x7FF8_0000_0000_0000, // +qNaN canonical
        0xFFF8_0000_0000_0000, // -qNaN (== BOX_MASK! the critical collision case)
        0x7FF0_0000_0000_0001, // +sNaN
        0xFFF0_0000_0000_0001, // -sNaN
        0x7FFF_FFFF_FFFF_FFFF, // +qNaN max payload
        0xFFFF_FFFF_FFFF_FFFF, // -qNaN max payload
        0x7FFA_AAAA_AAAA_AAAA,
        0xFFFC_5555_5555_5555,
    };
    for (nan_bits) |nb| {
        const raw: f64 = @bitCast(nb);
        try std.testing.expect(std.math.isNan(raw)); // sanity: these are NaNs
        const v = NanBox.encodeNumber(raw);
        try std.testing.expect(v.isNumber()); // never misread as boxed
        try std.testing.expect(v.tag() == null);
        try std.testing.expect(std.math.isNan(v.asNumber())); // still a NaN
        try std.testing.expectEqual(CANON_NAN, v.bits()); // canonicalized
    }
}

test "nanbox: a pointer sweep never aliases a number" {
    // Walk a range of plausible 48-bit-aligned heap addresses; each boxed
    // pointer must classify as boxed (not a number) and decode exactly.
    var addr: u64 = 0x1000;
    while (addr < 0x0000_8000_0000_0000) : (addr = (addr << 1) | 0x8) {
        if (addr & ~PAYLOAD_MASK != 0) break;
        const p: *anyopaque = @ptrFromInt(addr);
        const o = NanBox.encodeObject(p);
        try std.testing.expect(!o.isNumber());
        try std.testing.expect(o.isObject());
        try std.testing.expectEqual(addr, @intFromPtr(o.asPointer()));
    }
}

test "nanbox: fits in one 64-bit word (the whole point)" {
    try std.testing.expectEqual(@as(usize, 8), @sizeOf(NanBox));
    try std.testing.expectEqual(@as(usize, 8), @sizeOf(u64));
}
