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

// ---------------------------------------------------------------------------
// Incremental-GC write barrier hook (issue #1 Phase 7 / M2).
//
// The Dijkstra insertion barrier lives in the `zig-gc` `Heap`, but the engine's
// reference-store sites are scattered across files that import this low-level
// shim rather than `gc.zig` (which would be a circular import through
// `value.zig`). So `gc.zig` installs a type-erased thunk + heap pointer here at
// `setActiveHeap` time, and store sites call `barrierFrom(owner, cell)` (or the
// conservative child-only `barrier(cell)`). The same hook maintains the nursery
// remembered set and the incremental/full tri-color invariant.
// ---------------------------------------------------------------------------

threadlocal var barrier_heap: ?*anyopaque = null;
const BarrierFn = *const fn (*anyopaque, ?*anyopaque, ?*anyopaque) void;
const WeakBarrierFn = *const fn (*anyopaque, ?*anyopaque) void;
threadlocal var barrier_fn: ?BarrierFn = null;
threadlocal var weak_barrier_fn: ?WeakBarrierFn = null;

/// Install (or clear) the active heap's write-barrier thunk for this thread.
/// Returns the previous (heap, fn) so nested entry points can restore it.
pub fn setBarrier(heap: ?*anyopaque, f: ?BarrierFn, weak_f: ?WeakBarrierFn) struct { ?*anyopaque, ?BarrierFn, ?WeakBarrierFn } {
    const prev = .{ barrier_heap, barrier_fn, weak_barrier_fn };
    barrier_heap = heap;
    barrier_fn = f;
    weak_barrier_fn = weak_f;
    return prev;
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

/// Record that an owner's weak/ephemeron storage changed without making the
/// target strong. Minor GC will revisit an old owner and apply normal weak rules.
pub inline fn barrierWeak(owner: ?*anyopaque) void {
    if (weak_barrier_fn) |f| {
        if (barrier_heap) |h| f(h, owner);
    }
}
