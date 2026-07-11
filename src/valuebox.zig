//! The `Value` ↔ NaN-box bridge — proves the Phase 7 blocker-#7/#8 mechanisms
//! compose into a faithful, complete representation of the engine's real
//! `value.Value` (issue zig-utils/zig-js#1, docs/threads/P7-gil-removal.md).
//!
//! `nanbox.zig` (the 8-byte encoding) and `strcell.zig` (single-pointer string
//! cells + interning) were each proved in isolation before `value.Value` adopted
//! the same one-word layout. This module remains a compatibility/proof bridge:
//! `encode` packs a live `Value` into the standalone `NanBox` codec (interning
//! its string into a `StringCell`), and `decode` recovers it. The tests keep the
//! standalone codec aligned with the engine's real value representation.

const std = @import("std");
const value = @import("value.zig");
const nanbox = @import("nanbox.zig");
const strcell = @import("strcell.zig");

const Value = value.Value;
const NanBox = nanbox.NanBox;

/// Pack a `Value` into one NaN-boxed word. Strings are interned into the table,
/// so equal strings encode to the *same* `StringCell` pointer (the shared-string
/// property NaN-boxing relies on). Object pointers carry through directly.
pub fn encode(intern: *strcell.InternTable, v: Value) std.mem.Allocator.Error!NanBox {
    return switch (v.kind()) {
        .undefined => NanBox.encodeUndefined(),
        .null => NanBox.encodeNull(),
        .boolean => NanBox.encodeBool(v.asBool()),
        .number => NanBox.encodeNumber(v.asNum()),
        .string => NanBox.encodeString(@ptrCast(try intern.intern(v.asStr()))),
        .object => NanBox.encodeObject(@ptrCast(v.asObj())),
    };
}

/// Pack a string *literal* `Value` into one NaN-boxed word **without an
/// allocator**, via a comptime-interned static cell. This is the path for the
/// hundreds of `Value{ .string = "..." }` literal sites that have no allocator
/// in scope; runtime strings use `encode` (which interns through the table).
pub fn encodeLiteral(comptime s: []const u8) NanBox {
    // The static cell is immutable and only ever read back (on decode), so
    // dropping const to fit the opaque payload is sound.
    return NanBox.encodeString(@ptrCast(@constCast(strcell.staticCell(s))));
}

/// Recover a `Value` from its NaN-boxed word. A string decodes by reusing the
/// interned cell pointer directly (stable for the table's lifetime).
pub fn decode(nb: NanBox) Value {
    if (nb.isNumber()) return Value.num(nb.asNumber());
    return switch (nb.tag().?) {
        .undefined => Value.undef(),
        .null => Value.nul(),
        .boolean => Value.boolVal(nb.asBool()),
        .object => Value.obj(@ptrCast(@alignCast(nb.asPointer()))),
        .string => blk: {
            const cell: *strcell.StringCell = @ptrCast(@alignCast(nb.asPointer()));
            break :blk Value.strCell(cell);
        },
    };
}

// ---------------------------------------------------------------------------
// Tests — round-trip every kind through encode→decode and assert semantic
// equality against the real value.Value.
// ---------------------------------------------------------------------------

fn expectRoundTrip(intern: *strcell.InternTable, v: Value) !void {
    const got = decode(try encode(intern, v));
    try std.testing.expectEqual(v.kind(), got.kind());
    switch (v.kind()) {
        .undefined, .null => {},
        .boolean => try std.testing.expectEqual(v.asBool(), got.asBool()),
        .number => {
            if (std.math.isNan(v.asNum())) {
                try std.testing.expect(std.math.isNan(got.asNum()));
            } else {
                try std.testing.expectEqual(v.asNum(), got.asNum());
            }
        },
        .string => try std.testing.expectEqualStrings(v.asStr(), got.asStr()),
        .object => try std.testing.expectEqual(v.asObj(), got.asObj()),
    }
}

test "valuebox: primitives round-trip through the NaN-box bridge" {
    const a = std.testing.allocator;
    var intern = strcell.InternTable.init(a);
    defer intern.deinit();

    try expectRoundTrip(&intern, Value.undef());
    try expectRoundTrip(&intern, Value.nul());
    try expectRoundTrip(&intern, Value.boolVal(true));
    try expectRoundTrip(&intern, Value.boolVal(false));
    const nums = [_]f64{ 0, -0.0, 1, -1, 3.14159, 1e308, -1e-308, std.math.inf(f64), -std.math.inf(f64), std.math.nan(f64), std.math.floatMax(f64) };
    for (nums) |n| try expectRoundTrip(&intern, Value.num(n));
}

test "valuebox: strings round-trip and equal strings share one cell" {
    const a = std.testing.allocator;
    var intern = strcell.InternTable.init(a);
    defer intern.deinit();
    var value_arena = std.heap.ArenaAllocator.init(a);
    defer value_arena.deinit();
    const va = value_arena.allocator();

    const strs = [_][]const u8{ "", "hi", "a longer string with spaces", "ünïcödé ☃", "undefined" };
    for (strs) |s| try expectRoundTrip(&intern, try Value.strAlloc(va, s));

    // The shared-string property: two equal-byte string Values encode to the
    // same StringCell pointer (interning), so NaN-box string identity is byte
    // identity — what a Layer-C shared heap wants.
    var buf = [_]u8{ 'd', 'u', 'p' };
    const n1 = try encode(&intern, Value.str("dup"));
    const n2 = try encode(&intern, try Value.strAlloc(va, &buf));
    try std.testing.expectEqual(n1.asPointer(), n2.asPointer());
    try std.testing.expect(n1.isString());
}

test "valuebox: string literals encode with no allocator and decode equal" {
    // The literal-construction path (no InternTable, no allocator) — what the
    // ~424 `Value{ .string = "..." }` sites become after the swap.
    const nb = encodeLiteral("undefined");
    try std.testing.expect(nb.isString());
    try std.testing.expectEqualStrings("undefined", decode(nb).asStr());
    // Same literal encodes to the same cell pointer (comptime-interned); a
    // runtime intern of equal bytes is byte-equal though a distinct cell.
    try std.testing.expectEqual(encodeLiteral("undefined").asPointer(), nb.asPointer());

    const a = std.testing.allocator;
    var intern = strcell.InternTable.init(a);
    defer intern.deinit();
    const runtime = try encode(&intern, Value.str("undefined"));
    try std.testing.expectEqualStrings(decode(runtime).asStr(), decode(nb).asStr());
}

test "valuebox: object pointers round-trip exactly" {
    const a = std.testing.allocator;
    var intern = strcell.InternTable.init(a);
    defer intern.deinit();

    const o = try a.create(value.Object);
    o.* = .{};
    defer a.destroy(o);
    try expectRoundTrip(&intern, Value.obj(o));

    const nb = try encode(&intern, Value.obj(o));
    try std.testing.expect(nb.isObject() and !nb.isNumber());
    try std.testing.expectEqual(@as(*anyopaque, @ptrCast(o)), nb.asPointer());
}

test "valuebox: distinct kinds never collide after encode" {
    const a = std.testing.allocator;
    var intern = strcell.InternTable.init(a);
    defer intern.deinit();

    // A boolean, the number 1, and a 1-char string must produce three distinct
    // boxed words and decode back to their own kinds.
    const b = try encode(&intern, Value.boolVal(true));
    const n = try encode(&intern, Value.num(1));
    const s = try encode(&intern, Value.str("x"));
    try std.testing.expect(b.bits() != n.bits() and n.bits() != s.bits() and b.bits() != s.bits());
    try std.testing.expectEqual(Value.Kind.boolean, decode(b).kind());
    try std.testing.expectEqual(Value.Kind.number, decode(n).kind());
    try std.testing.expectEqual(Value.Kind.string, decode(s).kind());
}
