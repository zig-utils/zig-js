const std = @import("std");

/// Opt-in object-lock counters used by the local thread contention profiler.
/// Kept separate from `jsthread.zig` so `value.zig` can instrument Object lock
/// helpers without introducing an import cycle.
pub const ObjectLockStats = struct {
    object_backing_lock_acquires: u64 = 0,
    object_backing_lock_contentions: u64 = 0,
    object_backing_lock_spins: u64 = 0,
    object_property_lock_acquires: u64 = 0,
    object_property_lock_contentions: u64 = 0,
    object_property_lock_spins: u64 = 0,
    object_element_lock_acquires: u64 = 0,
    object_element_lock_contentions: u64 = 0,
    object_element_lock_spins: u64 = 0,
};

const ObjectLockCounters = struct {
    object_backing_lock_acquires: std.atomic.Value(u64) = .init(0),
    object_backing_lock_contentions: std.atomic.Value(u64) = .init(0),
    object_backing_lock_spins: std.atomic.Value(u64) = .init(0),
    object_property_lock_acquires: std.atomic.Value(u64) = .init(0),
    object_property_lock_contentions: std.atomic.Value(u64) = .init(0),
    object_property_lock_spins: std.atomic.Value(u64) = .init(0),
    object_element_lock_acquires: std.atomic.Value(u64) = .init(0),
    object_element_lock_contentions: std.atomic.Value(u64) = .init(0),
    object_element_lock_spins: std.atomic.Value(u64) = .init(0),
};

var counters: ObjectLockCounters = .{};
var enabled: std.atomic.Value(bool) = .init(false);

pub fn reset() void {
    enabled.store(false, .release);
    counters.object_backing_lock_acquires.store(0, .release);
    counters.object_backing_lock_contentions.store(0, .release);
    counters.object_backing_lock_spins.store(0, .release);
    counters.object_property_lock_acquires.store(0, .release);
    counters.object_property_lock_contentions.store(0, .release);
    counters.object_property_lock_spins.store(0, .release);
    counters.object_element_lock_acquires.store(0, .release);
    counters.object_element_lock_contentions.store(0, .release);
    counters.object_element_lock_spins.store(0, .release);
    enabled.store(true, .release);
}

pub fn disable() void {
    enabled.store(false, .release);
}

pub fn snapshot() ObjectLockStats {
    return .{
        .object_backing_lock_acquires = counters.object_backing_lock_acquires.load(.acquire),
        .object_backing_lock_contentions = counters.object_backing_lock_contentions.load(.acquire),
        .object_backing_lock_spins = counters.object_backing_lock_spins.load(.acquire),
        .object_property_lock_acquires = counters.object_property_lock_acquires.load(.acquire),
        .object_property_lock_contentions = counters.object_property_lock_contentions.load(.acquire),
        .object_property_lock_spins = counters.object_property_lock_spins.load(.acquire),
        .object_element_lock_acquires = counters.object_element_lock_acquires.load(.acquire),
        .object_element_lock_contentions = counters.object_element_lock_contentions.load(.acquire),
        .object_element_lock_spins = counters.object_element_lock_spins.load(.acquire),
    };
}

inline fn bump(comptime field: []const u8) void {
    if (!enabled.load(.monotonic)) return;
    _ = @field(counters, field).fetchAdd(1, .monotonic);
}

inline fn add(comptime field: []const u8, count: u64) void {
    if (count == 0 or !enabled.load(.monotonic)) return;
    _ = @field(counters, field).fetchAdd(count, .monotonic);
}

pub inline fn recordBackingLockAcquire(spins: usize) void {
    bump("object_backing_lock_acquires");
    if (spins > 0) {
        bump("object_backing_lock_contentions");
        add("object_backing_lock_spins", @intCast(spins));
    }
}

pub inline fn recordPropertyLockAcquire(spins: usize) void {
    bump("object_property_lock_acquires");
    if (spins > 0) {
        bump("object_property_lock_contentions");
        add("object_property_lock_spins", @intCast(spins));
    }
}

pub inline fn recordElementLockAcquire(spins: usize) void {
    bump("object_element_lock_acquires");
    if (spins > 0) {
        bump("object_element_lock_contentions");
        add("object_element_lock_spins", @intCast(spins));
    }
}
