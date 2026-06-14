//! The zig-js *binding* for the `zig-gc` precise tracing collector (issue #1
//! Phase 7; design in docs/threads/P7-gc-design.md). The collector
//! (`../zig-gc`) owns the mechanism; this file is the policy: how to enumerate
//! roots, how to trace each engine cell kind, and what to do when a cell dies.
//!
//! **Status: M1 — opt-in quiescent collection.** `Context.Options.enable_gc`
//! routes heap cells through `zig-gc`, and `Context.collectGarbage()` runs a
//! precise mark-sweep at quiescent points. Arbitrary mid-script collection and
//! full sub-allocation reclamation are still future work.
//!
//! Tracing surface and root set are derived from a full audit of the heap; see
//! the cell-kind table in P7-gc-design.md. Cells whose references all live in
//! `value.zig` (Object's own slots/proto/accessors) are traced here directly;
//! the type-erased side-cells (`js_func`→Function, `gen`→Generator, …) are cast
//! back to their concrete types and traced by the helpers below.

const std = @import("std");
const gc = @import("gc");
const value = @import("value.zig");
const interp = @import("interpreter.zig");
const promise = @import("promise.zig");
const vm = @import("vm.zig");
const ContextMod = @import("context.zig");
const jsthread = @import("jsthread.zig");

const Value = value.Value;
const Object = value.Object;
const Environment = interp.Environment;

/// The engine's GC cell taxonomy. Each `Heap.create(T, kind)` tags its cell so
/// `trace`/`finalize` dispatch without RTTI. AST nodes, bytecode chunks, and
/// `Shape`s are immutable and arena-permanent — they are *not* GC cells and
/// never appear here.
pub const CellKind = enum {
    object,
    environment,
    function,
    bound_fn,
    promise,
    generator,
    iter_helper,
    module_ns,
};

/// Mark a `Value` if it carries a heap reference (only `.object` does — every
/// other variant is an immediate or a primitive).
inline fn markValue(v: anytype, val: Value) void {
    if (val == .object) v.mark(val.object);
}

inline fn markValueOpt(v: anytype, val: ?Value) void {
    if (val) |x| markValue(v, x);
}

inline fn markWeakObject(v: anytype, slot: *?*Object) void {
    v.markWeak(@ptrCast(slot));
}

inline fn markManaged(v: anytype, cell: anytype) void {
    if (v.isManaged(cell)) v.mark(cell);
}

// ---- Per-kind tracers (public so a test binding can reuse them) -----------

/// Trace every strong reference out of an `Object`. WeakRef and WeakMap/WeakSet
/// keys are registered as weak edges so collection clears them when the target
/// is otherwise unreachable.
pub fn traceObject(o: *Object, v: anytype) void {
    v.mark(o.proto);
    v.mark(o.ctor_ref);
    v.mark(o.proxy_target);
    v.mark(o.proxy_handler);
    for (o.slots.items) |slot| markValue(v, slot);
    if (o.is_weak and (o.is_map or o.is_set)) {
        for (o.weak_entries.items) |*entry| v.markWeak(&entry.key);
    } else {
        for (o.elements.items) |el| markValue(v, el);
    }
    if (o.accessors) |acc| {
        var it = acc.valueIterator();
        while (it.next()) |a| {
            markValueOpt(v, a.get);
            markValueOpt(v, a.set);
        }
    }
    markValueOpt(v, o.prim);
    markWeakObject(v, &o.weak_ref_target);
    if (o.is_finalization_registry) {
        markValue(v, o.finalization_callback);
        for (o.finalization_records.items) |*record| {
            v.markWeak(&record.target);
            if (record.token != null) v.markWeak(&record.token);
            markValue(v, record.held);
        }
    }

    // Type-erased side-cells.
    if (o.js_func) |p| v.mark(p); // *Function (kind .function)
    if (o.bound) |p| v.mark(p); // *Interpreter.BoundFn (kind .bound_fn)
    if (o.promise) |p| v.mark(p); // *promise.Promise (kind .promise)
    if (o.gen) |p| v.mark(p); // *vm.Generator (kind .generator)
    if (o.iter_helper) |p| v.mark(p); // (kind .iter_helper)
    if (o.module_ns) |p| v.mark(p); // *ModuleNs (kind .module_ns)
    if (o.arg_map_env) |p| v.mark(p); // *Environment (kind .environment)
    promise.traceNativePrivateData(o, v);
    vm.traceNativePrivateData(o, v);
    // The viewed ArrayBuffer object keeps a TypedArray/DataView's storage alive.
    if (o.typed_array) |ta| v.mark(ta.buffer);
    if (o.data_view) |dv| v.mark(dv.buffer);
}

pub fn traceObjectEphemeron(o: *Object, v: anytype) void {
    if (!(o.is_weak and o.is_map)) return;
    for (o.weak_entries.items) |entry| {
        if (v.isMarked(entry.key)) markValue(v, entry.value);
    }
}

pub fn pruneDeadWeakEntries(o: *Object) bool {
    var cleanup_ready = false;
    if (o.is_weak and (o.is_map or o.is_set)) {
        var i: usize = 0;
        while (i < o.weak_entries.items.len) {
            if (o.weak_entries.items[i].key == null) {
                _ = o.weak_entries.orderedRemove(i);
            } else {
                i += 1;
            }
        }
    }
    if (o.is_finalization_registry) {
        for (o.finalization_records.items) |*record| {
            if (record.target == null and !record.ready) {
                record.ready = true;
                cleanup_ready = true;
            }
        }
    }
    return cleanup_ready;
}

pub fn traceEnv(e: *Environment, v: anytype) void {
    var vit = e.vars.valueIterator();
    while (vit.next()) |val| markValue(v, val.*);
    for (e.disposables.items) |d| {
        markValue(v, d.value);
        markValue(v, d.method);
    }
    var ait = e.aliases.valueIterator();
    while (ait.next()) |a| markManaged(v, a.env);
    if (e.parent) |p| markManaged(v, p);
    if (e.with_object) |o| v.mark(o);
}

pub fn traceFunction(f: *interp.Function, v: anytype) void {
    markManaged(v, f.closure);
    v.mark(f.home_object);
    v.mark(f.super_ctor);
    v.mark(f.obj);
    markValue(v, f.arrow_this);
    // `params`/`body`/`source`/`chunk` are immutable arena/AST — not cells.
}

pub fn traceBoundFn(b: *interp.Interpreter.BoundFn, v: anytype) void {
    markValue(v, b.target);
    markValue(v, b.this);
    for (b.args) |a| markValue(v, a);
}

pub fn tracePromise(p: *promise.Promise, v: anytype) void {
    markValue(v, p.value);
    for (p.on_fulfill.items) |r| traceReaction(r, v);
    for (p.on_reject.items) |r| traceReaction(r, v);
}

inline fn traceReaction(r: promise.Reaction, v: anytype) void {
    markValueOpt(v, r.handler);
    markValue(v, r.resolve);
    markValue(v, r.reject);
}

pub fn traceGenerator(g: *vm.Generator, v: anytype) void {
    v.mark(g.env);
    for (g.exec.stack.items) |s| markValue(v, s);
    markValue(v, g.exec.acc);
    markValue(v, g.this_value);
    v.mark(g.home_object);
    v.mark(g.super_ctor);
    v.mark(g.result);
    for (g.requests.items) |req| {
        markValue(v, req.value);
        v.mark(req.result);
    }
}

pub fn traceIterHelper(h: *value.IterHelper, v: anytype) void {
    markValue(v, h.src);
    markValue(v, h.next_method);
    markValue(v, h.func);
    markValueOpt(v, h.inner);
    markValue(v, h.inner_next);
    markValue(v, h.padding);
}

pub fn traceModuleNs(m: *interp.ModuleNs, v: anytype) void {
    for (m.envs) |e| v.mark(e);
}

pub fn traceModuleGraph(cache: *std.StringHashMapUnmanaged(*ContextMod.Context.Module), v: anytype) void {
    var it = cache.valueIterator();
    while (it.next()) |mp| {
        const m = mp.*;
        v.mark(m.env);
        if (m.ns) |ns| v.mark(ns);
    }
}

// ---- The binding the collector instantiates over -------------------------

/// A tiny stateful binding the collector instantiates over: it just wraps the
/// `*Context` whose roots it traces, so the heap's `ctx: *Binding` indirects to
/// the realm. (Keeping the collector's `Binding`-is-the-ctx contract unchanged
/// means no edit to the shared `zig-gc` library.) Trace logic is the free
/// functions above; root/finalize read `self.context`.
pub const Binding = struct {
    context: *ContextMod.Context,

    pub const Kind = CellKind;

    /// Persistent roots reachable from the realm. NOTE: M1 must additionally
    /// trace the *live* `Interpreter` execution state (value stack, `this`,
    /// `ret_value`, `exception`, `new_target`, `home_object`, `super_ctor`,
    /// `with_stack`, `active_native`, `symbols`, `import_meta_obj`) at the
    /// safepoint where collection runs — see P7-gc-design.md and
    /// `traceInterpreterRoots`. With collection only at teardown, the
    /// persistent set suffices.
    pub fn traceRoots(self: *Binding, v: anytype) void {
        const ctx = self.context;
        v.mark(ctx.global_object);
        v.mark(ctx.tdz_marker);
        traceEnv(&ctx.env, v); // the global environment is embedded by value
        for (ctx.microtasks.items) |mt| {
            traceReaction(mt.reaction, v);
            markValue(v, mt.argument);
            markValue(v, mt.thenable);
            markValue(v, mt.then_fn);
            if (mt.promise) |p| v.mark(p);
        }
        for (ctx.async_waiters.items) |aw| markValue(v, aw.promise);
        for (ctx.finalization_cleanup_jobs.items) |registry| v.mark(registry);
        for (ctx.js_threads.items) |rec| {
            markValue(v, rec.result);
            if (rec.js_obj) |o| v.mark(o);
            for (rec.pending_joins.items) |p| v.mark(p);
        }
        if (ctx.gil) |g| {
            for (g.prop_async.items) |raw| {
                const t: *jsthread.PropAsyncTicket = @ptrCast(@alignCast(raw));
                v.mark(t.obj);
                v.mark(t.promise);
            }
        }
        if (ctx.mod_cache) |cache| traceModuleGraph(cache, v);
        markValue(v, ctx.exception orelse .undefined);
        // C-API handles: each entry is a `*Boxed` ({ value: Value }), so the
        // pointer aliases `*Value`. The embedder may hold these `JSValueRef`s.
        for (ctx.c_api_handles.items) |h| {
            const vp: *const Value = @ptrCast(@alignCast(h));
            markValue(v, vp.*);
        }
    }

    pub fn trace(cell: *anyopaque, kind: Kind, v: anytype) void {
        switch (kind) {
            .object => traceObject(@ptrCast(@alignCast(cell)), v),
            .environment => traceEnv(@ptrCast(@alignCast(cell)), v),
            .function => traceFunction(@ptrCast(@alignCast(cell)), v),
            .bound_fn => traceBoundFn(@ptrCast(@alignCast(cell)), v),
            .promise => tracePromise(@ptrCast(@alignCast(cell)), v),
            .generator => traceGenerator(@ptrCast(@alignCast(cell)), v),
            .iter_helper => traceIterHelper(@ptrCast(@alignCast(cell)), v),
            .module_ns => traceModuleNs(@ptrCast(@alignCast(cell)), v),
        }
    }

    pub fn traceEphemeron(self: *Binding, cell: *anyopaque, kind: Kind, v: anytype) void {
        _ = self;
        switch (kind) {
            .object => traceObjectEphemeron(@ptrCast(@alignCast(cell)), v),
            else => {},
        }
    }

    pub fn afterWeak(self: *Binding, cell: *anyopaque, kind: Kind) void {
        switch (kind) {
            .object => {
                const o: *Object = @ptrCast(@alignCast(cell));
                if (pruneDeadWeakEntries(o)) self.context.queueFinalizationRegistryCleanup(o);
            },
            else => {},
        }
    }

    /// A cell is being reclaimed. A non-shared `ArrayBufferData`'s bytes are
    /// arena-owned (freed with the arena), but a SharedArrayBuffer wrapper must
    /// release its `SharedBufferStorage` retain here. No GC-owned buffers exist
    /// until those allocation sites migrate, so this is currently a no-op.
    pub fn finalize(self: *Binding, cell: *anyopaque, kind: Kind) void {
        _ = self;
        _ = cell;
        _ = kind;
    }
};

/// The engine's GC heap type. `Context` holds one behind `enable_gc`.
pub const Heap = gc.Heap(Binding);

/// Allocate an `Object` cell through the GC heap when present (tagged
/// `.object`), else from the arena — today's engine. `heap_erased` is
/// `Context.gc` passed type-erased so `interpreter.zig` need not name the Heap
/// type (keeping the gc↔interpreter import edge to plain functions). The
/// returned payload is default-initialized so pointer slots are safe even for
/// allocation sites that fill fields incrementally.
pub fn allocObject(heap_erased: ?*anyopaque, arena: std.mem.Allocator) std.mem.Allocator.Error!*Object {
    if (heap_erased) |h| {
        const heap: *Heap = @ptrCast(@alignCast(h));
        const o = try heap.create(Object, .object);
        o.* = .{};
        return o;
    }
    const o = try arena.create(Object);
    o.* = .{};
    return o;
}

/// The GC heap whose cells the *current thread* allocates into, or null for the
/// arena. Per-thread (a shared-Context GIL thread sets it to the same heap on
/// entry), set/restored at the realm's allocation entry points — `createWith`
/// for intrinsics, `evaluate`/`evaluateModule` for execution. This lets every
/// scattered `*.create(value.Object)` site funnel through `allocObj(arena)`
/// without threading the heap pointer through hundreds of signatures.
threadlocal var active_heap: ?*anyopaque = null;

/// Install `h` as this thread's active heap, returning the previous value (so
/// nested entry points can restore it). Pass null for the arena engine.
pub fn setActiveHeap(h: ?*anyopaque) ?*anyopaque {
    const prev = active_heap;
    active_heap = h;
    return prev;
}

/// Allocate an `Object` cell from the thread's active GC heap (tagged
/// `.object`), or `arena` when the GC is off. The dominant allocation funnel:
/// the migrated `*.create(value.Object)` sites call this with the allocator
/// they already had in scope as the fallback.
pub fn allocObj(arena: std.mem.Allocator) std.mem.Allocator.Error!*Object {
    if (active_heap) |h| {
        const heap: *Heap = @ptrCast(@alignCast(h));
        const o = try heap.create(Object, .object);
        o.* = .{};
        return o;
    }
    const o = try arena.create(Object);
    o.* = .{};
    return o;
}

/// Per-side-cell allocation funnels — same thread-local-active-heap rule as
/// `allocObj`, each tagged with its own `CellKind` so `trace`/`finalize`
/// dispatch correctly. These make the *cell* heap uniform (every heap object a
/// GC cell), the prerequisite for sound mid-run collection. (Cell
/// sub-allocations — `Environment.vars`, `Object.slots`, … — stay arena for
/// now; they are never passed to `mark`, so they pose no tracing hazard, only a
/// reclaim-at-teardown vs reclaim-on-collect difference handled later.)
fn allocCell(comptime T: type, kind: CellKind, arena: std.mem.Allocator) std.mem.Allocator.Error!*T {
    if (active_heap) |h| {
        const heap: *Heap = @ptrCast(@alignCast(h));
        return heap.create(T, kind);
    }
    return arena.create(T);
}

pub fn allocEnv(arena: std.mem.Allocator) std.mem.Allocator.Error!*Environment {
    return allocCell(Environment, .environment, arena);
}
pub fn allocFunction(arena: std.mem.Allocator) std.mem.Allocator.Error!*interp.Function {
    return allocCell(interp.Function, .function, arena);
}
pub fn allocPromise(arena: std.mem.Allocator) std.mem.Allocator.Error!*promise.Promise {
    return allocCell(promise.Promise, .promise, arena);
}
pub fn allocGenerator(arena: std.mem.Allocator) std.mem.Allocator.Error!*vm.Generator {
    return allocCell(vm.Generator, .generator, arena);
}
pub fn allocBoundFn(arena: std.mem.Allocator) std.mem.Allocator.Error!*interp.Interpreter.BoundFn {
    return allocCell(interp.Interpreter.BoundFn, .bound_fn, arena);
}
pub fn allocIterHelper(arena: std.mem.Allocator) std.mem.Allocator.Error!*value.IterHelper {
    return allocCell(value.IterHelper, .iter_helper, arena);
}
pub fn allocModuleNs(arena: std.mem.Allocator) std.mem.Allocator.Error!*interp.ModuleNs {
    return allocCell(interp.ModuleNs, .module_ns, arena);
}

// ---------------------------------------------------------------------------
// Test — validate the real `traceObject` logic against real `value.Object`s,
// driven by a minimal test binding (roots are a list, not a Context). Proves
// the binding traces proto/slots/accessors and reclaims cycles + garbage.
// ---------------------------------------------------------------------------

const TestEngine = struct {
    pub const Kind = CellKind;
    gpa: std.mem.Allocator,
    roots: std.ArrayListUnmanaged(*Object) = .empty,

    pub fn traceRoots(self: *TestEngine, v: anytype) void {
        for (self.roots.items) |o| v.mark(o);
    }
    pub fn trace(cell: *anyopaque, kind: @This().Kind, v: anytype) void {
        // The test only builds .object cells; reuse the production tracer.
        std.debug.assert(kind == .object);
        traceObject(@ptrCast(@alignCast(cell)), v);
    }
    /// A dying Object owns its slots/elements/accessors backing memory (the GC
    /// frees only the cell itself), so finalize releases them — the same
    /// responsibility M1's real finalize carries for non-arena sub-allocations.
    pub fn finalize(self: *TestEngine, cell: *anyopaque, kind: @This().Kind) void {
        std.debug.assert(kind == .object);
        const o: *Object = @ptrCast(@alignCast(cell));
        o.slots.deinit(self.gpa);
        o.elements.deinit(self.gpa);
        if (o.accessors) |acc| {
            acc.deinit(self.gpa);
            self.gpa.destroy(acc);
        }
    }
};

test "gc binding: real Object graph — proto/slots/accessors survive, garbage swept" {
    const a = std.testing.allocator;
    var eng = TestEngine{ .gpa = a };
    defer eng.roots.deinit(a);

    var heap = gc.Heap(TestEngine).init(a, &eng);
    defer heap.deinit(); // finalizes every survivor (freeing its slots/accessors)

    // root --slot--> child --proto--> gp ; gp --slot--> root (cycle).
    const root = try heap.create(Object, .object);
    root.* = .{};
    const child = try heap.create(Object, .object);
    child.* = .{};
    const gp = try heap.create(Object, .object);
    gp.* = .{};
    const garbage = try heap.create(Object, .object);
    garbage.* = .{};

    try root.slots.append(a, .{ .object = child });
    child.proto = gp;
    try gp.slots.append(a, .{ .object = root }); // cycle back to the root
    // `garbage` is unreferenced.
    try eng.roots.append(a, root);
    try std.testing.expectEqual(@as(usize, 4), heap.live_cells);

    heap.collect();
    // root, child, gp reachable; garbage collected (finalize freed its memory).
    try std.testing.expectEqual(@as(usize, 3), heap.live_cells);

    // Accessor edges are traced too: attach one to a fresh rooted object.
    const holder = try heap.create(Object, .object);
    holder.* = .{};
    const acc_target = try heap.create(Object, .object);
    acc_target.* = .{};
    const map = try a.create(std.StringHashMapUnmanaged(value.Accessor));
    map.* = .{};
    try map.put(a, "x", .{ .get = .{ .object = acc_target }, .set = null });
    holder.accessors = map;
    try eng.roots.append(a, holder);

    heap.collect();
    // root-set {root,child,gp,holder,acc_target} all live; nothing new dies.
    try std.testing.expectEqual(@as(usize, 5), heap.live_cells);

    // Drop every root → everything is garbage; finalize frees each cell's memory.
    eng.roots.clearRetainingCapacity();
    heap.collect();
    try std.testing.expectEqual(@as(usize, 0), heap.live_cells);
}
