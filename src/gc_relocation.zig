//! Typed pointer-rewrite contract for moving GC (issue #333).
//!
//! This module deliberately does not move cells. It makes every future move go
//! through explicit strong, weak, atomic, tagged-Value, or interior operations
//! and records the stable logical identity carried across an address change.

const std = @import("std");
const gc = @import("gc.zig");
const value = @import("value.zig");
const strcell = @import("strcell.zig");

pub const CellKind = gc.CellKind;
pub const Value = value.Value;

/// Address-independent identity assigned by a relocation plan. It is never
/// observable as JavaScript data; host identity tables will key by this value
/// while a compaction is active instead of treating a payload address as the
/// identity itself.
pub const StableCellId = enum(u64) {
    _,

    pub fn init(raw: u64) StableCellId {
        std.debug.assert(raw != 0);
        return @enumFromInt(raw);
    }
};

pub const ForwardingState = enum {
    planned,
    copied,
    rewritten,
};

/// Failure-atomic compaction first builds these records without touching the
/// old heap. The stable ID and old address remain valid until the rewrite phase
/// commits; #334 will own allocation, copy, rollback, and publication.
pub const ForwardingRecord = struct {
    id: StableCellId,
    kind: CellKind,
    old_payload: *anyopaque,
    new_payload: *anyopaque,
    state: ForwardingState = .planned,
};

pub const EdgeKind = enum {
    strong,
    weak,
};

pub const ResolveFn = *const fn (
    context: *anyopaque,
    old_payload: *anyopaque,
    edge: EdgeKind,
) ?*anyopaque;

/// Rewrites slots only while all relevant mutators are stopped. A missing
/// strong destination is a broken relocation plan and traps; a missing weak
/// destination clears the slot. Atomic weak slots use CAS so an embedder clear
/// cannot race the rewrite once #336 permits concurrent/native boundaries.
pub const Relocator = struct {
    context: *anyopaque,
    resolve_fn: ResolveFn,

    fn resolve(self: *const Relocator, old: *anyopaque, edge: EdgeKind) ?*anyopaque {
        return self.resolve_fn(self.context, old, edge);
    }

    pub fn rewriteRequired(self: *const Relocator, comptime T: type, slot: **T) void {
        const old: *anyopaque = @ptrCast(slot.*);
        const new = self.resolve(old, .strong) orelse
            std.debug.panic("moving GC omitted a required {s} edge at 0x{x}", .{ @typeName(T), @intFromPtr(old) });
        slot.* = @ptrCast(@alignCast(new));
    }

    pub fn rewriteOptional(self: *const Relocator, comptime T: type, slot: *?*T) void {
        const old_typed = slot.* orelse return;
        const old: *anyopaque = @ptrCast(old_typed);
        const new = self.resolve(old, .strong) orelse
            std.debug.panic("moving GC omitted an optional {s} edge at 0x{x}", .{ @typeName(T), @intFromPtr(old) });
        slot.* = @ptrCast(@alignCast(new));
    }

    pub fn rewriteWeak(self: *const Relocator, comptime T: type, slot: *?*T) void {
        const old_typed = slot.* orelse return;
        const old: *anyopaque = @ptrCast(old_typed);
        slot.* = if (self.resolve(old, .weak)) |new|
            @ptrCast(@alignCast(new))
        else
            null;
    }

    pub fn rewriteStrongAtomic(self: *const Relocator, slot: *std.atomic.Value(?*anyopaque)) void {
        var old = slot.load(.acquire);
        while (old) |payload| {
            const new = self.resolve(payload, .strong) orelse
                std.debug.panic("moving GC omitted an atomic strong edge at 0x{x}", .{@intFromPtr(payload)});
            if (slot.cmpxchgWeak(old, new, .acq_rel, .acquire)) |observed| {
                old = observed;
                continue;
            }
            return;
        }
    }

    pub fn rewriteWeakAtomic(self: *const Relocator, slot: *std.atomic.Value(?*anyopaque)) void {
        var old = slot.load(.acquire);
        while (old) |payload| {
            const new = self.resolve(payload, .weak);
            if (slot.cmpxchgWeak(old, new, .acq_rel, .acquire)) |observed| {
                old = observed;
                continue;
            }
            return;
        }
    }

    pub fn rewriteAtomicValue(self: *const Relocator, slot: *std.atomic.Value(u64)) void {
        var old_bits = slot.load(.acquire);
        while (true) {
            var rewritten = Value.fromRawBits(old_bits);
            self.rewriteValue(&rewritten);
            const new_bits = rewritten.rawBits();
            if (new_bits == old_bits) return;
            if (slot.cmpxchgWeak(old_bits, new_bits, .acq_rel, .acquire)) |observed| {
                old_bits = observed;
                continue;
            }
            return;
        }
    }

    /// Rewrite only managed tagged payloads. Static/arena/interned strings are
    /// explicitly outside the moving heap and remain byte-for-byte unchanged.
    pub fn rewriteValue(self: *const Relocator, slot: *Value) void {
        if (slot.isObject()) {
            var object = slot.asObj();
            self.rewriteRequired(value.Object, &object);
            slot.* = Value.obj(object);
            return;
        }
        if (slot.isString()) {
            const old = slot.asStringCell();
            if (!old.isGcManaged()) return;
            var cell = @constCast(old);
            self.rewriteRequired(@TypeOf(cell.*), &cell);
            slot.* = Value.strCell(cell);
        }
    }

    /// Preserve an interior projection's byte offset while relocating its base.
    /// Conservative roots cannot use this operation because they do not carry a
    /// proven base; the inventory pins cells discovered by conservative scan.
    pub fn rewriteInterior(self: *const Relocator, old_base: *anyopaque, address: *usize) void {
        const base_address = @intFromPtr(old_base);
        std.debug.assert(address.* >= base_address);
        const offset = address.* - base_address;
        const new_base = self.resolve(old_base, .strong) orelse
            std.debug.panic("moving GC omitted an interior base at 0x{x}", .{base_address});
        address.* = @intFromPtr(new_base) + offset;
    }
};

test "gc relocation contract rewrites strong weak atomic Value and interior edges" {
    var old_object_storage: [@sizeOf(value.Object)]u8 align(@alignOf(value.Object)) = undefined;
    var new_object_storage: [@sizeOf(value.Object)]u8 align(@alignOf(value.Object)) = undefined;
    var old_string_storage: [@sizeOf(strcell.StringCell)]u8 align(@alignOf(strcell.StringCell)) = undefined;
    var new_string_storage: [@sizeOf(strcell.StringCell)]u8 align(@alignOf(strcell.StringCell)) = undefined;
    const old_object: *value.Object = @ptrCast(&old_object_storage);
    const new_object: *value.Object = @ptrCast(&new_object_storage);
    const old_string: *strcell.StringCell = @ptrCast(&old_string_storage);
    const new_string: *strcell.StringCell = @ptrCast(&new_string_storage);
    old_string.* = .{ .bytes = "old", .hash = 1 };
    old_string.setGcManaged(true);
    new_string.* = .{ .bytes = "old", .hash = 1 };
    new_string.setGcManaged(true);

    const Map = struct {
        old_object: *value.Object,
        new_object: *value.Object,
        old_string: *strcell.StringCell,
        new_string: *strcell.StringCell,

        fn resolve(raw: *anyopaque, old: *anyopaque, edge: EdgeKind) ?*anyopaque {
            const self: *@This() = @ptrCast(@alignCast(raw));
            if (old == @as(*anyopaque, @ptrCast(self.old_object))) return @ptrCast(self.new_object);
            if (old == @as(*anyopaque, @ptrCast(self.old_string))) return @ptrCast(self.new_string);
            if (edge == .weak) return null;
            return null;
        }
    };
    var map = Map{
        .old_object = old_object,
        .new_object = new_object,
        .old_string = old_string,
        .new_string = new_string,
    };
    const relocator = Relocator{ .context = &map, .resolve_fn = Map.resolve };

    var required = old_object;
    relocator.rewriteRequired(value.Object, &required);
    try std.testing.expectEqual(new_object, required);

    var tagged_object = Value.obj(old_object);
    relocator.rewriteValue(&tagged_object);
    try std.testing.expectEqual(new_object, tagged_object.asObj());

    var tagged_string = Value.strCell(old_string);
    relocator.rewriteValue(&tagged_string);
    try std.testing.expectEqual(new_string, tagged_string.asStringCell());

    var weak: ?*value.Object = @ptrFromInt(@intFromPtr(old_object) + @alignOf(value.Object));
    relocator.rewriteWeak(value.Object, &weak);
    try std.testing.expectEqual(@as(?*value.Object, null), weak);

    var atomic_weak: std.atomic.Value(?*anyopaque) = .init(@ptrFromInt(@intFromPtr(old_object) + @alignOf(value.Object)));
    relocator.rewriteWeakAtomic(&atomic_weak);
    try std.testing.expectEqual(@as(?*anyopaque, null), atomic_weak.load(.acquire));

    var atomic_strong: std.atomic.Value(?*anyopaque) = .init(old_object);
    relocator.rewriteStrongAtomic(&atomic_strong);
    try std.testing.expectEqual(@as(?*anyopaque, new_object), atomic_strong.load(.acquire));

    var atomic_value: std.atomic.Value(u64) = .init(Value.obj(old_object).rawBits());
    relocator.rewriteAtomicValue(&atomic_value);
    try std.testing.expectEqual(new_object, Value.fromRawBits(atomic_value.load(.acquire)).asObj());

    var interior = @intFromPtr(old_object) + 7;
    relocator.rewriteInterior(old_object, &interior);
    try std.testing.expectEqual(@intFromPtr(new_object) + 7, interior);
}

test "gc relocation forwarding records preserve logical identity across address changes" {
    var old: u64 = 1;
    var new: u64 = 2;
    var record = ForwardingRecord{
        .id = .init(7),
        .kind = .object,
        .old_payload = &old,
        .new_payload = &new,
    };
    try std.testing.expectEqual(@as(u64, 7), @intFromEnum(record.id));
    try std.testing.expect(record.old_payload != record.new_payload);
    record.state = .copied;
    try std.testing.expectEqual(ForwardingState.copied, record.state);
    try std.testing.expectEqual(@as(u64, 7), @intFromEnum(record.id));
}
