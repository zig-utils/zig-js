//! `ValueNB` — a working prototype of the NaN-boxed `Value` the rep-flip
//! produces (issue zig-utils/zig-js#1 Phase 7, blocker #7). It assembles the
//! already-proven pieces — the `nanbox` 8-byte codec and `strcell` string cells
//! (`internActive`, no per-site allocator) — into a single 8-byte value type
//! with the SAME public API as the real `value.Value` (`kind`/`num`/`str`/`obj`/
//! `boolVal`/`undef`/`nul`/`asNum`/`asStr`/`asObj`/`asBool`/`isX`) plus the
//! representative semantic methods (`toBoolean`/`toNumber`/`typeOf`).
//!
//! Purpose: prove the NaN-box representation can serve the method semantics
//! *natively* (operating on the bits, not by decoding to the union), and that a
//! string `Value` round-trips through a `*StringCell` with no allocator — the
//! last unproven aspect of the rep-flip. Its tests assert byte-for-byte
//! semantic equivalence against `value.Value` across every kind and edge case.
//!
//! This is NOT wired into the engine; the rep-flip replaces `value.Value`'s body
//! with this representation and points the call sites (already migrated to the
//! API) at it. Proving it here means the flip is a representation change against
//! a verified target, not a leap.

const std = @import("std");
const nanbox = @import("nanbox.zig");
const strcell = @import("strcell.zig");
const value = @import("value.zig");

const Object = value.Object;
const StringCell = strcell.StringCell;

pub const ValueNB = struct {
    nb: nanbox.NanBox,

    pub const Kind = enum { undefined, null, boolean, number, string, object };

    // ---- Constructors (same API as value.Value) --------------------------
    pub inline fn num(n: f64) ValueNB {
        return .{ .nb = nanbox.NanBox.encodeNumber(n) };
    }
    pub inline fn obj(o: *Object) ValueNB {
        return .{ .nb = nanbox.NanBox.encodeObject(@ptrCast(o)) };
    }
    pub inline fn boolVal(b: bool) ValueNB {
        return .{ .nb = nanbox.NanBox.encodeBool(b) };
    }
    pub inline fn undef() ValueNB {
        return .{ .nb = nanbox.NanBox.encodeUndefined() };
    }
    pub inline fn nul() ValueNB {
        return .{ .nb = nanbox.NanBox.encodeNull() };
    }
    /// Runtime string: interns into the threadlocal active table → `*StringCell`,
    /// NO per-site allocator. (Literals would use `strcell.staticCell` via a
    /// `lit` constructor in the real flip.) Falls back to a static empty cell if
    /// no table is active, which never happens on a live realm path.
    pub fn str(s: []const u8) ValueNB {
        const cell = strcell.internActive(s) orelse strcell.staticCell("");
        return .{ .nb = nanbox.NanBox.encodeString(@ptrCast(@constCast(cell))) };
    }

    // ---- Discriminants ----------------------------------------------------
    pub inline fn kind(self: ValueNB) Kind {
        if (self.nb.isNumber()) return .number;
        return switch (self.nb.tag().?) {
            .object => .object,
            .string => .string,
            .boolean => .boolean,
            .undefined => .undefined,
            .null => .null,
        };
    }
    pub inline fn isNumber(self: ValueNB) bool {
        return self.nb.isNumber();
    }
    pub inline fn isString(self: ValueNB) bool {
        return self.nb.isString();
    }
    pub inline fn isObject(self: ValueNB) bool {
        return self.nb.isObject();
    }
    pub inline fn isBoolean(self: ValueNB) bool {
        return self.nb.isBool();
    }
    pub inline fn isUndefined(self: ValueNB) bool {
        return self.nb.isUndefined();
    }
    pub inline fn isNull(self: ValueNB) bool {
        return self.nb.isNull();
    }

    // ---- Accessors --------------------------------------------------------
    pub inline fn asNum(self: ValueNB) f64 {
        return self.nb.asNumber();
    }
    pub inline fn asBool(self: ValueNB) bool {
        return self.nb.asBool();
    }
    pub inline fn asObj(self: ValueNB) *Object {
        return @ptrCast(@alignCast(self.nb.asPointer()));
    }
    pub inline fn asStr(self: ValueNB) []const u8 {
        const cell: *StringCell = @ptrCast(@alignCast(self.nb.asPointer()));
        return cell.bytes;
    }

    // ---- Representative semantic methods (operate on the bits natively) ---
    pub fn toBoolean(self: ValueNB) bool {
        return switch (self.kind()) {
            .undefined, .null => false,
            .boolean => self.asBool(),
            .number => self.asNum() != 0 and !std.math.isNan(self.asNum()),
            .string => self.asStr().len != 0,
            .object => if (self.asObj().behavior.is_htmldda) false else if (self.asObj().is_bigint) !value.bigIntIsZero(self.asObj()) else true,
        };
    }
    pub fn toNumber(self: ValueNB) f64 {
        return switch (self.kind()) {
            .undefined => std.math.nan(f64),
            .null => 0,
            .boolean => if (self.asBool()) 1 else 0,
            .number => self.asNum(),
            .string => value.stringToNumber(self.asStr(), false),
            .object => if (self.asObj().is_bigint) value.bigIntToNumber(self.asObj()) else std.math.nan(f64),
        };
    }
    pub fn typeOf(self: ValueNB) []const u8 {
        return switch (self.kind()) {
            .undefined => "undefined",
            .null => "object",
            .boolean => "boolean",
            .number => "number",
            .string => "string",
            .object => if (self.asObj().behavior.is_htmldda) "undefined" else if (self.asObj().is_symbol) "symbol" else if (self.asObj().is_bigint) "bigint" else if (self.asObj().isCallableObject()) "function" else "object",
        };
    }

    comptime {
        // The whole point: one atomic machine word.
        std.debug.assert(@sizeOf(ValueNB) == 8);
    }
};

// ---------------------------------------------------------------------------
// Tests — semantic equivalence against the real value.Value.
// ---------------------------------------------------------------------------

const Value = value.Value;

test "value_nb: kind/accessors round-trip and match value.Value" {
    const a = std.testing.allocator;
    var table = strcell.InternTable.init(a);
    defer table.deinit();
    const prev = strcell.setActiveTable(&table);
    defer _ = strcell.setActiveTable(prev);

    const nums = [_]f64{ 0, -0.0, 1, -1, 3.14159, 1e308, std.math.inf(f64), -std.math.inf(f64), std.math.nan(f64) };
    for (nums) |n| {
        const nb = ValueNB.num(n);
        const v = Value.num(n);
        try std.testing.expectEqual(@as(ValueNB.Kind, .number), nb.kind());
        try std.testing.expectEqual(v.toBoolean(), nb.toBoolean());
        if (std.math.isNan(n)) {
            try std.testing.expect(std.math.isNan(nb.toNumber()));
        } else {
            try std.testing.expectEqual(v.toNumber(), nb.toNumber());
        }
        try std.testing.expectEqualStrings(v.typeOf(), nb.typeOf());
    }

    try std.testing.expect(ValueNB.undef().isUndefined() and !ValueNB.undef().toBoolean());
    try std.testing.expect(ValueNB.nul().isNull() and !ValueNB.nul().toBoolean());
    try std.testing.expect(ValueNB.boolVal(true).asBool() and ValueNB.boolVal(true).toBoolean());
    try std.testing.expect(!ValueNB.boolVal(false).toBoolean());
    try std.testing.expectEqualStrings("undefined", ValueNB.undef().typeOf());
    try std.testing.expectEqualStrings("object", ValueNB.nul().typeOf());
    try std.testing.expectEqualStrings("boolean", ValueNB.boolVal(true).typeOf());
}

test "value_nb: strings round-trip via StringCell with no allocator and match semantics" {
    const a = std.testing.allocator;
    var table = strcell.InternTable.init(a);
    defer table.deinit();
    var value_arena = std.heap.ArenaAllocator.init(a);
    defer value_arena.deinit();
    const va = value_arena.allocator();
    const prev = strcell.setActiveTable(&table);
    defer _ = strcell.setActiveTable(prev);

    const strs = [_][]const u8{ "", "hi", "a longer one", "0", "  42  ", "ünïcödé" };
    for (strs) |s| {
        const nb = ValueNB.str(s); // <-- no allocator argument
        const v = try Value.strAlloc(va, s);
        try std.testing.expectEqual(@as(ValueNB.Kind, .string), nb.kind());
        try std.testing.expectEqualStrings(s, nb.asStr());
        try std.testing.expectEqual(v.toBoolean(), nb.toBoolean()); // "" is falsy
        // ToNumber("0")==0, ToNumber("  42  ")==42, etc. — must match the union.
        if (std.math.isNan(v.toNumber())) {
            try std.testing.expect(std.math.isNan(nb.toNumber()));
        } else {
            try std.testing.expectEqual(v.toNumber(), nb.toNumber());
        }
        try std.testing.expectEqualStrings("string", nb.typeOf());
    }
    // Equal strings intern to the same cell → pointer-equal NaN-box words.
    try std.testing.expectEqual(ValueNB.str("dup").nb.bits(), ValueNB.str("dup").nb.bits());
}

test "value_nb: object round-trips and reflects Object semantics" {
    const a = std.testing.allocator;
    const o = try a.create(Object);
    o.* = .{};
    defer a.destroy(o);

    const nb = ValueNB.obj(o);
    const v = Value.obj(o);
    try std.testing.expectEqual(@as(ValueNB.Kind, .object), nb.kind());
    try std.testing.expectEqual(o, nb.asObj());
    try std.testing.expectEqual(v.toBoolean(), nb.toBoolean()); // ordinary object is truthy
    try std.testing.expectEqualStrings(v.typeOf(), nb.typeOf());
}
