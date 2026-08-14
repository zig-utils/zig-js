const std = @import("std");

pub const ObjectBackingState = struct {
    allocator: std.mem.Allocator,
    stores_live: ?*usize,
};

pub const State = struct {
    object_backing: ?ObjectBackingState = null,
};

threadlocal var active_object_backing: ?ObjectBackingState = null;
threadlocal var trace_sensitive_lock_depth: usize = 0;
threadlocal var allocation_recovery_blocked_depth: usize = 0;

pub fn setActive(state: State) State {
    const prev = State{ .object_backing = active_object_backing };
    active_object_backing = state.object_backing;
    return prev;
}

pub fn activeObjectBacking() ?ObjectBackingState {
    return active_object_backing;
}

/// Track locks that the concurrent/parallel tracer may also acquire while
/// walking object/environment/promise side storage. Allocation-failure recovery
/// must fail closed when the current mutator already holds one of these locks:
/// tracing from that point could self-deadlock or invert the side-store lock
/// order. Normal safepoint collection is unaffected.
pub inline fn enterTraceSensitiveLock() void {
    trace_sensitive_lock_depth += 1;
}

pub inline fn leaveTraceSensitiveLock() void {
    std.debug.assert(trace_sensitive_lock_depth > 0);
    trace_sensitive_lock_depth -= 1;
}

pub inline fn inTraceSensitiveLock() bool {
    return trace_sensitive_lock_depth != 0;
}

/// Track allocator-internal critical sections that allocation-failure recovery
/// could re-enter. The outer allocation path may still catch OOM and recover
/// after these locks are released; this only prevents self-deadlock from a
/// generic allocator callback.
pub inline fn enterAllocationRecoveryBlocked() void {
    allocation_recovery_blocked_depth += 1;
}

pub inline fn leaveAllocationRecoveryBlocked() void {
    std.debug.assert(allocation_recovery_blocked_depth > 0);
    allocation_recovery_blocked_depth -= 1;
}

pub inline fn allocationRecoveryBlocked() bool {
    return allocation_recovery_blocked_depth != 0;
}

// ---------------------------------------------------------------------------
// Incremental-GC write barrier hook (issue #1 Phase 7 / M2).
//
// The Dijkstra insertion barrier lives in the `zig-gc` `Heap`, but the engine's
// reference-store sites are scattered across files that import this low-level
// shim rather than `gc.zig` (which would be a circular import through
// `value.zig`). So `gc.zig` installs a type-erased thunk + heap pointer here at
// `setActiveHeap` time, and store sites call `barrierFrom(owner, cell)` (or the
// conservative child-only `barrier(cell)`). Stores whose static types prove
// both endpoints are exact live payload starts may use `barrierFromManaged` to
// skip the tolerant ownership lookup. Both hooks maintain the nursery
// remembered set and the incremental/full tri-color invariant.
// ---------------------------------------------------------------------------

threadlocal var barrier_heap: ?*anyopaque = null;
const BarrierFn = *const fn (*anyopaque, ?*anyopaque, ?*anyopaque) void;
const WeakBarrierFn = *const fn (*anyopaque, ?*anyopaque) void;
const ManagedBarrierFn = *const fn (*anyopaque, *anyopaque, *anyopaque) void;
threadlocal var barrier_fn: ?BarrierFn = null;
threadlocal var weak_barrier_fn: ?WeakBarrierFn = null;
threadlocal var managed_barrier_fn: ?ManagedBarrierFn = null;
const StableIdentityFn = *const fn (*anyopaque, ?*anyopaque, u64) ?u64;
const StableIdentityEpochFn = *const fn (*anyopaque) u64;
threadlocal var stable_identity_context: ?*anyopaque = null;
threadlocal var stable_identity_fn: ?StableIdentityFn = null;
threadlocal var stable_identity_epoch_fn: ?StableIdentityEpochFn = null;
threadlocal var stable_identity_cached_context: ?*anyopaque = null;
threadlocal var stable_identity_cached_cell: ?*anyopaque = null;
threadlocal var stable_identity_cached_epoch: u64 = 0;
threadlocal var stable_identity_cached_value: u64 = 0;

/// Install (or clear) the active heap's write-barrier thunks for this thread.
/// Returns the previous hook set so nested entry points can restore it.
pub fn setBarrier(heap: ?*anyopaque, f: ?BarrierFn, weak_f: ?WeakBarrierFn, managed_f: ?ManagedBarrierFn) struct { ?*anyopaque, ?BarrierFn, ?WeakBarrierFn, ?ManagedBarrierFn } {
    const prev = .{ barrier_heap, barrier_fn, weak_barrier_fn, managed_barrier_fn };
    barrier_heap = heap;
    barrier_fn = f;
    weak_barrier_fn = weak_f;
    managed_barrier_fn = managed_f;
    return prev;
}

/// Install relocation-stable cell identity lookup beside the active heap.
/// Value-level containers import this acyclic shim rather than `gc.zig`.
pub fn setStableIdentity(context: ?*anyopaque, f: ?StableIdentityFn, epoch_f: ?StableIdentityEpochFn) struct { ?*anyopaque, ?StableIdentityFn, ?StableIdentityEpochFn } {
    const prev = .{ stable_identity_context, stable_identity_fn, stable_identity_epoch_fn };
    stable_identity_context = context;
    stable_identity_fn = f;
    stable_identity_epoch_fn = epoch_f;
    stable_identity_cached_context = null;
    stable_identity_cached_cell = null;
    stable_identity_cached_epoch = 0;
    stable_identity_cached_value = 0;
    return prev;
}

/// Stable identity for a managed cell, or null for arena/static storage.
pub inline fn stableCellIdentity(cell: ?*anyopaque) ?u64 {
    const pointer = cell orelse return null;
    const context = stable_identity_context orelse return null;
    const f = stable_identity_fn orelse return null;
    const epoch_f = stable_identity_epoch_fn orelse return f(context, pointer, 0);
    const epoch = epoch_f(context);
    if (epoch == std.math.maxInt(u64)) return f(context, pointer, epoch);
    if (stable_identity_cached_context == context and
        stable_identity_cached_cell == pointer and
        stable_identity_cached_epoch == epoch)
        return stable_identity_cached_value;
    const identity = f(context, pointer, epoch) orelse return null;
    stable_identity_cached_context = context;
    stable_identity_cached_cell = pointer;
    stable_identity_cached_epoch = epoch;
    stable_identity_cached_value = identity;
    return identity;
}

test "stable identity cache follows the provider reuse epoch" {
    const Provider = struct {
        epoch: u64 = 1,
        identity: u64 = 11,
        calls: usize = 0,

        fn lookup(raw: *anyopaque, _: ?*anyopaque, _: u64) ?u64 {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.calls += 1;
            return self.identity;
        }

        fn currentEpoch(raw: *anyopaque) u64 {
            const self: *@This() = @ptrCast(@alignCast(raw));
            return self.epoch;
        }
    };
    var provider = Provider{};
    var cell: u8 = 0;
    _ = setStableIdentity(&provider, Provider.lookup, Provider.currentEpoch);
    defer _ = setStableIdentity(null, null, null);
    try std.testing.expectEqual(@as(?u64, 11), stableCellIdentity(&cell));
    try std.testing.expectEqual(@as(?u64, 11), stableCellIdentity(&cell));
    try std.testing.expectEqual(@as(usize, 1), provider.calls);
    provider.identity = 12;
    provider.epoch += 1;
    try std.testing.expectEqual(@as(?u64, 12), stableCellIdentity(&cell));
    try std.testing.expectEqual(@as(usize, 2), provider.calls);
    provider.identity = 13;
    provider.epoch = std.math.maxInt(u64);
    try std.testing.expectEqual(@as(?u64, 13), stableCellIdentity(&cell));
    try std.testing.expectEqual(@as(?u64, 13), stableCellIdentity(&cell));
    try std.testing.expectEqual(@as(usize, 4), provider.calls);
}

/// Shade `cell` grey if the active heap is incrementally marking. Safe to call
/// with any pointer (the heap validates it) or with the GC off (no-op).
pub inline fn barrier(cell: ?*anyopaque) void {
    barrierFrom(null, cell);
}

/// Barrier a strong edge stored in `owner`. Supplying the owner lets nursery GC
/// remember a dirty old container instead of conservatively retaining `cell`.
pub inline fn barrierFrom(owner: ?*anyopaque, cell: ?*anyopaque) void {
    if (barrier_fn) |f| {
        if (barrier_heap) |h| f(h, owner, cell);
    }
}

/// Barrier an edge whose endpoints are proven exact live payload starts from
/// the active heap. Returns false when no managed heap is installed so callers
/// can preserve a tolerant or arena-mode fallback.
pub inline fn barrierFromManaged(owner: *anyopaque, cell: *anyopaque) bool {
    const f = managed_barrier_fn orelse return false;
    const h = barrier_heap orelse return false;
    f(h, owner, cell);
    return true;
}

/// Record that an owner's weak/ephemeron storage changed without making the
/// target strong. Minor GC will revisit an old owner and apply normal weak rules.
pub inline fn barrierWeak(owner: ?*anyopaque) void {
    if (weak_barrier_fn) |f| {
        if (barrier_heap) |h| f(h, owner);
    }
}

test "exact managed barrier is opt-in and retains the tolerant fallback" {
    const Provider = struct {
        managed_calls: usize = 0,
        tolerant_calls: usize = 0,

        fn tolerant(raw: *anyopaque, _: ?*anyopaque, _: ?*anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.tolerant_calls += 1;
        }

        fn managed(raw: *anyopaque, _: *anyopaque, _: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.managed_calls += 1;
        }
    };

    var provider = Provider{};
    var owner: u8 = 0;
    var child: u8 = 0;
    const prev = setBarrier(&provider, Provider.tolerant, null, Provider.managed);
    defer _ = setBarrier(prev[0], prev[1], prev[2], prev[3]);

    try std.testing.expect(barrierFromManaged(&owner, &child));
    try std.testing.expectEqual(@as(usize, 1), provider.managed_calls);
    try std.testing.expectEqual(@as(usize, 0), provider.tolerant_calls);

    _ = setBarrier(&provider, Provider.tolerant, null, null);
    try std.testing.expect(!barrierFromManaged(&owner, &child));
    barrierFrom(&owner, &child);
    try std.testing.expectEqual(@as(usize, 1), provider.tolerant_calls);
}
