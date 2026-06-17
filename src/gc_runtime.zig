const std = @import("std");

pub const ObjectBackingState = struct {
    allocator: std.mem.Allocator,
    stores_live: ?*usize,
};

pub const State = struct {
    object_backing: ?ObjectBackingState = null,
};

threadlocal var active_object_backing: ?ObjectBackingState = null;

pub fn setActive(state: State) State {
    const prev = State{ .object_backing = active_object_backing };
    active_object_backing = state.object_backing;
    return prev;
}

pub fn activeObjectBacking() ?ObjectBackingState {
    return active_object_backing;
}

// ---------------------------------------------------------------------------
// Incremental-GC write barrier hook (issue #1 Phase 7 / M2).
//
// The Dijkstra insertion barrier lives in the `zig-gc` `Heap`, but the engine's
// reference-store sites are scattered across files that import this low-level
// shim rather than `gc.zig` (which would be a circular import through
// `value.zig`). So `gc.zig` installs a type-erased thunk + heap pointer here at
// `setActiveHeap` time, and the store sites call `barrier(cell)`. The thunk is
// a near-no-op when the heap is not incrementally marking (one bool load inside
// `Heap.writeBarrier`); `barrier_fn == null` (GC off) is one null check.
// ---------------------------------------------------------------------------

threadlocal var barrier_heap: ?*anyopaque = null;
threadlocal var barrier_fn: ?*const fn (*anyopaque, ?*anyopaque) void = null;

/// Install (or clear) the active heap's write-barrier thunk for this thread.
/// Returns the previous (heap, fn) so nested entry points can restore it.
pub fn setBarrier(heap: ?*anyopaque, f: ?*const fn (*anyopaque, ?*anyopaque) void) struct { ?*anyopaque, ?*const fn (*anyopaque, ?*anyopaque) void } {
    const prev = .{ barrier_heap, barrier_fn };
    barrier_heap = heap;
    barrier_fn = f;
    return prev;
}

/// Shade `cell` grey if the active heap is incrementally marking. Safe to call
/// with any pointer (the heap validates it) or with the GC off (no-op).
pub inline fn barrier(cell: ?*anyopaque) void {
    if (barrier_fn) |f| {
        if (barrier_heap) |h| f(h, cell);
    }
}
