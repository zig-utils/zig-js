//! The zig-js *binding* for the `zig-gc` precise tracing collector (issue #1
//! Phase 7; design in docs/threads/P7-gc-design.md). The collector
//! (`../zig-gc`) owns the mechanism; this file is the policy: how to enumerate
//! roots, how to trace each engine cell kind, and what to do when a cell dies.
//!
//! **Status: M1 — opt-in quiescent collection.** `Context.Options.enable_gc`
//! routes heap cells through `zig-gc`, and `Context.collectGarbage()` runs a
//! precise mark-sweep at quiescent points. Arbitrary mid-script collection and
//! some remaining side-storage migrations are still future work.
//!
//! Tracing surface and root set are derived from a full audit of the heap; see
//! the cell-kind table in P7-gc-design.md. Cells whose references all live in
//! `value.zig` (Object's own slots/proto/accessors) are traced here directly;
//! the type-erased side-cells (`js_func`→Function, `gen`→Generator, …) are cast
//! back to their concrete types and traced by the helpers below.

const std = @import("std");
const builtin = @import("builtin");
const gc = @import("gc");
const value = @import("value.zig");
const interp = @import("interpreter.zig");
const promise = @import("promise.zig");
const vm = @import("vm.zig");
const ContextMod = @import("context.zig");
const jsthread = @import("jsthread.zig");
const gc_runtime = @import("gc_runtime.zig");
const stack_scan = @import("stack_scan.zig");
const agent = @import("agent.zig");
const strcell = @import("strcell.zig");

const Value = value.Value;
const Object = value.Object;
const Shape = @import("shape.zig").Shape;
const Environment = interp.Environment;
const StringCell = strcell.StringCell;

var object_batch_cells_for_testing: std.atomic.Value(u64) = .init(0);

pub fn objectBatchCellsForTesting() u64 {
    return object_batch_cells_for_testing.load(.monotonic);
}

/// The engine's GC cell taxonomy. Each `Heap.create(T, kind)` tags its cell so
/// `trace`/`finalize` dispatch without RTTI. AST nodes, bytecode chunks, and
/// `Shape`s are immutable and arena-permanent — they are *not* GC cells and
/// never appear here.
pub const CellKind = enum {
    object,
    string,
    environment,
    function,
    bound_fn,
    promise,
    generator,
    iter_helper,
    module_ns,
};

/// Mark a `Value` if it carries a heap reference. Objects always use the heap
/// in GC mode. Strings carry immutable ownership metadata because static,
/// arena, and intern-table cells intentionally coexist with managed cells.
pub inline fn markValue(v: anytype, val: Value) void {
    if (val.isObject()) {
        v.mark(val.asObj());
    } else if (val.isString()) {
        const cell = val.asStringCell();
        if (cell.isGcManaged()) v.mark(@constCast(cell));
    }
}

inline fn markValueOpt(v: anytype, val: ?Value) void {
    if (val) |x| markValue(v, x);
}

inline fn markWeakObject(v: anytype, slot: *?*Object) void {
    v.markWeak(@ptrCast(slot));
}

inline fn markManaged(v: anytype, cell: anytype) void {
    const Cell = @TypeOf(cell.*);
    if (Cell == interp.Environment) {
        if (cell.gc_managed) v.mark(cell);
        return;
    }
    if (Cell == promise.Promise) {
        if (cell.gc_owned) v.mark(cell);
        return;
    }
    @compileError("markManaged requires explicit ownership metadata for " ++ @typeName(Cell));
}

inline fn hasObjectBacking(flags: value.ObjectBackingFlags) bool {
    return flags.storage_state or
        flags.cold or
        flags.slots or
        flags.elements_state or
        flags.elements or
        flags.accessors or
        flags.key_order or
        flags.attrs or
        flags.holes or
        flags.weak_entries or
        flags.finalization_records or
        flags.typed_array or
        flags.data_view or
        flags.temporal or
        flags.arg_map_names or
        flags.arg_map_severed;
}

// ---- Per-kind tracers (public so a test binding can reuse them) -----------

/// Trace every strong reference out of an `Object`. WeakRef and WeakMap/WeakSet
/// keys are registered as weak edges so collection clears them when the target
/// is otherwise unreachable.
pub fn traceObject(o: *Object, v: anytype) void {
    // Single-word pointer fields. `proto` is the one that a *reachable* object's
    // mutator can rewrite post-creation (a `setPrototypeOf` reparent, which also
    // fires the insertion barrier to shade the new target); under a concurrent
    // mark we read it with a relaxed atomic load to be race-free per the memory
    // model (a plain mov on x86_64/arm64). The reparent sites pair this with an
    // atomic store. The construction link and proxy sidecar edges are written only at
    // creation, before the cell is published to the marker (the born-grey
    // hand-off establishes happens-before), so their payload reads are safe.
    // The cold pointer itself can also be installed lazily on an already-live
    // object, so snapshot it and all rare GC edges under `backing_lock`.
    const concurrent = v.concurrent();
    v.mark(if (concurrent) @atomicLoad(?*Object, &o.proto, .monotonic) else o.proto);
    const cold = o.traceColdSnapshot(concurrent);
    v.mark(cold.ctor_ref);
    v.mark(cold.proxy_target);
    v.mark(cold.proxy_handler);

    // Growable storage (slots/accessors behind `property_lock`, elements behind
    // `elements_lock`): under a *concurrent* mark (M3) the marker must read it
    // under the same lock the mutator takes, or a concurrent append/realloc
    // tears the slice. Under stop-the-world (M1) / GIL-held incremental (M2)
    // marking the world is quiescent during the read, so we skip the lock.
    if (concurrent) o.lockProperties();
    for (o.slotsItems()) |slot| markValue(v, slot);
    if (o.accessorsMap()) |acc| {
        var it = acc.valueIterator();
        while (it.next()) |a| {
            markValueOpt(v, a.get);
            markValueOpt(v, a.set);
            v.mark(a.descriptor_cell);
        }
    }
    if (o.cApiObjectOwner()) |owner| {
        var it = owner.custom_accessor_cells.valueIterator();
        while (it.next()) |cell| v.mark(cell.*);
    }
    if (concurrent) o.unlockProperties();

    if (o.is_weak and (o.is_map or o.is_set)) {
        // Weak collections register no interior weak slots here — keys are weak
        // (their liveness is read by `isLive` in the world-stopped finish pass,
        // `pruneDeadWeakEntries`) and values are ephemeron edges marked in
        // `traceObjectEphemeron` (also at finish). So `weak_entries` is never
        // read during the (possibly concurrent) mark — nothing tears against a
        // mutator append, and no `&entry.key` can dangle when the buffer grows.
    } else {
        if (concurrent) o.lockElements();
        for (o.elementsItems()) |el| markValue(v, el);
        if (concurrent) o.unlockElements();
    }
    markValueOpt(v, cold.boxed_primitive);
    markValueOpt(v, cold.getter_setter_getter);
    markValueOpt(v, cold.getter_setter_setter);
    if (cold.weak_ref_target_slot) |slot| markWeakObject(v, slot); // stable cold-slot address
    if (o.behavior.is_finalization_registry) {
        if (cold.cold) |state| {
            markValue(v, state.finalization_callback);
            // Only `held` is a strong edge (mark it by value under the entry-storage
            // lock so a concurrent append can't tear the read). target/token are
            // weak — their liveness is decided by `isLive` at finish, not registered.
            if (concurrent) o.lockElements();
            if (state.finalization_records) |records|
                for (records.items) |*record| markValue(v, record.held);
            if (concurrent) o.unlockElements();
        }
    }

    // Type-erased side-cells.
    if (cold.js_function) |p| v.mark(@as(*interp.Function, @ptrCast(@alignCast(p))));
    if (cold.bound_function) |p| v.mark(@as(*interp.Interpreter.BoundFn, @ptrCast(@alignCast(p))));
    if (cold.promise_data) |p| v.mark(@as(*promise.Promise, @ptrCast(@alignCast(p))));
    if (cold.generator) |p| v.mark(@as(*vm.Generator, @ptrCast(@alignCast(p))));
    if (cold.iterator_helper) |p| v.mark(@as(*value.IterHelper, @ptrCast(@alignCast(p))));
    if (cold.module_ns) |p| v.mark(@as(*interp.ModuleNs, @ptrCast(@alignCast(p))));
    if (cold.arg_map_env) |p| v.mark(@as(*interp.Environment, @ptrCast(@alignCast(p))));
    promise.traceNativePrivateData(o, v);
    interp.traceNativePrivateData(o, v);
    jsthread.traceNativePrivateData(o, v);
    vm.traceNativePrivateData(o, v);
    // The viewed ArrayBuffer object keeps a TypedArray/DataView's storage alive.
    if (cold.typed_array) |ta| v.mark(ta.buffer);
    if (cold.data_view) |dv| v.mark(dv.buffer);
    // WebAssembly JS API rare-state edges (issue #141): the JS wrapper objects
    // keep their linked Module/exports/buffer/owner objects alive. The native
    // payload memory is registry-owned; live exception and GC-reference
    // wrappers trace the JavaScript values reachable through that memory.
    v.mark(cold.wasm.module_obj);
    for (cold.wasm.import_vals) |import_val| markValue(v, import_val);
    for (cold.wasm.table_refs) |*ref| markValue(v, .{ .bits = @constCast(ref).load(.acquire) });
    for (cold.wasm.global_refs) |ref| markValue(v, .{ .bits = ref.load(.acquire) });
    if (cold.wasm.global_ref) |ref| markValue(v, .{ .bits = ref.load(.acquire) });
    if (cold.wasm.exception) |exception| traceWasmException(v, exception);
    v.mark(cold.wasm.exports_obj);
    v.mark(cold.wasm.buffer_obj);
    v.mark(cold.wasm.owner_obj);
    if (cold.wasm.gc_ref) |reference| {
        const Marker = struct {
            fn mark(raw: *anyopaque, child: Value) void {
                const visitor: @TypeOf(v) = @ptrCast(@alignCast(raw));
                markValue(visitor, child);
            }
        };
        reference.trace(reference, @ptrCast(v), Marker.mark);
    }
    if (cold.wasm.gc_trace) |trace| if (cold.wasm.gc_trace_context) |trace_context| {
        const Marker = struct {
            fn mark(raw: *anyopaque, child: Value) void {
                const visitor: @TypeOf(v) = @ptrCast(@alignCast(raw));
                markValue(visitor, child);
            }
        };
        trace(trace_context, @ptrCast(v), Marker.mark);
    };
}

fn traceWasmException(v: anytype, exception: *const value.WasmException) void {
    const Marker = struct {
        fn mark(raw: *anyopaque, child: Value) void {
            const visitor: @TypeOf(v) = @ptrCast(@alignCast(raw));
            markValue(visitor, child);
        }
    };
    for (exception.payload) |slot| switch (slot) {
        .externref, .hostref => |root| markValue(v, root),
        .gcref => |reference| if (reference) |root| root.trace(root, @ptrCast(v), Marker.mark),
        .externalized_gcref => |root| root.trace(root, @ptrCast(v), Marker.mark),
        .exnref => |nested| if (nested) |child| traceWasmException(v, child),
        .numeric, .vector, .funcref, .i31ref, .externalized_i31 => {},
    };
}

pub fn traceObjectEphemeron(o: *Object, v: anytype) void {
    if (!(o.is_weak and o.is_map)) return;
    const cold = o.coldState() orelse return;
    for (cold.weak_entries.items) |entry| {
        if (v.isMarked(entry.key)) markValue(v, entry.value);
    }
}

/// World-stopped finish pass (afterWeak): drop weak entries whose key died and
/// mark finalization records whose target died as ready. Liveness is read
/// directly from `heap.isLive` (the mark bit) rather than from a pre-registered
/// interior weak slot — so this is correct even when the mark ran concurrently
/// with a mutator that grew `weak_entries`/`finalization_records`. Behaviorally
/// identical to the old markWeak-then-null-then-prune for the stop-the-world and
/// GIL-held paths (a dead key/target is exactly an unmarked managed cell).
pub fn pruneDeadWeakEntries(o: *Object, heap: anytype) bool {
    if (!(o.is_weak and (o.is_map or o.is_set)) and !o.behavior.is_finalization_registry) return false;
    o.lockElements();
    defer o.unlockElements();

    var cleanup_ready = false;
    if (o.is_weak and (o.is_map or o.is_set)) {
        const cold = o.coldState() orelse return false;
        var i: usize = 0;
        while (i < cold.weak_entries.items.len) {
            if (!heap.isLive(cold.weak_entries.items[i].key)) {
                o.weakEntrySwapRemoveAtUnlocked(i);
            } else {
                i += 1;
            }
        }
    }
    if (o.behavior.is_finalization_registry) {
        const cold = o.coldState() orelse return cleanup_ready;
        const records = cold.finalization_records orelse return cleanup_ready;
        for (records.items) |*record| {
            // Once a record is ready, its target may have been swept in an
            // earlier cycle; never ask the heap about that stale pointer again.
            if (!record.ready and !heap.isLive(record.target)) {
                record.ready = true;
                cleanup_ready = true;
            }
            // A dead unregister token can never match a future unregister; drop it.
            if (record.token != null and !heap.isLive(record.token)) record.token = null;
        }
    }
    return cleanup_ready;
}

pub fn traceEnv(e: *Environment, v: anytype) void {
    // `vars`/`disposables`/`aliases` are mutated by binding writes; under a
    // concurrent mark read them under the same `binding_lock` those writers take
    // (or a `put` rehash / append could tear the iteration). `parent`/`with_object`
    // are set at env creation and never rewritten, so they need no lock.
    const concurrent = v.concurrent();
    if (concurrent) e.lockBindings();
    var vit = e.vars.valueIterator();
    while (vit.next()) |val| markValue(v, val.*);
    for (e.disposables.items) |d| {
        markValue(v, d.value);
        markValue(v, d.method);
    }
    if (e.dispose_pending) |pending| markValue(v, pending);
    var ait = e.aliases.valueIterator();
    while (ait.next()) |a| markManaged(v, a.env);
    if (e.object_proto_intrinsic) |o| v.mark(o);
    if (concurrent) e.unlockBindings();
    if (e.parent) |p| markManaged(v, p);
    if (e.with_object) |o| v.mark(o);
}

fn finalizeEnv(e: *Environment) void {
    const a = e.bindings_allocator orelse return;
    var vit = e.vars.keyIterator();
    while (vit.next()) |key| e.freeBindingName(key.*);
    e.vars.deinit(a);
    e.vars = .{};

    var cit = e.consts.keyIterator();
    while (cit.next()) |key| e.freeBindingName(key.*);
    e.consts.deinit(a);
    e.consts = .{};

    var fit = e.fn_names.keyIterator();
    while (fit.next()) |key| e.freeBindingName(key.*);
    e.fn_names.deinit(a);
    e.fn_names = .{};

    var dit = e.deletable.keyIterator();
    while (dit.next()) |key| e.freeBindingName(key.*);
    e.deletable.deinit(a);
    e.deletable = .{};

    var ait = e.aliases.iterator();
    while (ait.next()) |entry| {
        e.freeBindingName(entry.key_ptr.*);
        e.freeBindingName(entry.value_ptr.name);
    }
    e.aliases.deinit(a);
    e.aliases = .{};

    e.disposables.deinit(a);
    e.disposables = .empty;
}

fn finalizeObjectBacking(o: *Object, a: std.mem.Allocator) usize {
    var released: usize = 0;
    const storage = o.storageState().?;
    const flags = storage.backing_flags;

    if (flags.slots) {
        const state = o.slotsState().?;
        state.list.deinit(a);
        a.destroy(state);
        storage.slots.store(null, .release);
        released += 1;
    }
    if (flags.elements) {
        o.elementsState().?.list.deinit(a);
        o.elementsState().?.list = .empty;
        released += 1;
    }
    if (flags.elements_state) {
        a.destroy(o.elementsState().?);
        storage.elements.store(null, .release);
        released += 1;
    }
    if (flags.accessors) {
        if (o.accessorsMap()) |acc| {
            var it = acc.keyIterator();
            while (it.next()) |key| a.free(key.*);
            acc.deinit(a);
            a.destroy(acc);
            o.coldState().?.accessors.store(null, .monotonic);
        }
        released += 1;
    }
    // `private_brands` reuses the "accessors" backing (see Object.addPrivateBrand)
    // but is a separate map pointer the finalizer must also release, or a GC-
    // collected branded object leaks its table + struct. Its keys are borrowed
    // private-name slices (put without copying), so unlike attrs/accessors we do
    // not free the keys.
    if (o.privateBrands()) |pb| {
        pb.deinit(a);
        a.destroy(pb);
        o.clearPrivateBrands();
    }
    if (flags.key_order) {
        if (o.keyOrder()) |ord| {
            for (ord.items) |key| a.free(key);
            ord.deinit(a);
            a.destroy(ord);
            o.coldState().?.key_order.store(null, .monotonic);
        }
        released += 1;
    }
    if (flags.attrs) {
        if (o.attrsMap()) |attrs| {
            var it = attrs.keyIterator();
            while (it.next()) |key| a.free(key.*);
            attrs.deinit(a);
            a.destroy(attrs);
            o.coldState().?.attrs = null;
        }
        released += 1;
    }
    if (flags.holes) {
        if (o.holesMap()) |holes| {
            holes.deinit(a);
            a.destroy(holes);
            o.clearHolesMap();
        }
        released += 1;
    }
    if (flags.weak_entries) {
        const cold = o.coldState().?;
        cold.weak_entries.deinit(a);
        cold.weak_entries = .empty;
        cold.weak_index.deinit(a);
        cold.weak_index = .empty;
        released += 1;
    }
    if (flags.finalization_records) {
        if (o.coldState().?.finalization_records) |records| {
            records.deinit(a);
            a.destroy(records);
            o.coldState().?.finalization_records = null;
        }
        released += 1;
    }
    if (flags.typed_array) {
        if (o.typedArray()) |ta| {
            a.destroy(ta);
            o.clearTypedArray();
        }
        released += 1;
    }
    if (flags.data_view) {
        if (o.dataView()) |dv| {
            a.destroy(dv);
            o.clearDataView();
        }
        released += 1;
    }
    if (flags.temporal) {
        if (o.temporalData()) |t| {
            a.destroy(t);
            o.clearTemporalData();
        }
        released += 1;
    }
    if (flags.arg_map_names) {
        a.free(o.coldState().?.arg_map_names);
        o.coldState().?.arg_map_names = &.{};
        released += 1;
    }
    if (flags.arg_map_severed) {
        a.free(o.coldState().?.arg_map_severed);
        o.coldState().?.arg_map_severed = &.{};
        released += 1;
    }
    if (flags.cold) {
        a.destroy(o.coldState().?);
        storage.cold.store(null, .release);
        released += 1;
    }

    if (flags.storage_state) {
        o.storage.store(null, .release);
        storage.owner_allocator.destroy(storage);
        released += 1;
    }
    return released;
}

pub fn traceFunction(f: *interp.Function, v: anytype) void {
    markManaged(v, f.closure);
    v.mark(f.home_object);
    v.mark(f.super_ctor);
    v.mark(f.obj);
    if (f.import_meta_slot) |slot| if (slot.obj) |o| v.mark(o);
    markValue(v, f.arrow_this);
    // `params`/`body`/`source`/`chunk` are immutable arena/AST — not cells.
}

pub fn traceBoundFn(b: *interp.Interpreter.BoundFn, v: anytype) void {
    markValue(v, b.target);
    markValue(v, b.this);
    for (b.args) |a| markValue(v, a);
}

pub fn tracePromise(p: *promise.Promise, v: anytype) void {
    p.lockState();
    defer p.unlockState();
    markValue(v, p.value);
    if (p.wrapper) |wrapper| v.mark(wrapper);
    if (p.awaiting_async_activation) |activation|
        v.mark(@as(*vm.Generator, @ptrCast(@alignCast(activation))));
    if (p.async_forward_to) |forward| markManaged(v, forward);
    if (p.on_fulfill_inline) |r| traceReaction(r, v);
    if (p.on_reject_inline) |r| traceReaction(r, v);
    for (p.on_fulfill.items) |r| traceReaction(r, v);
    for (p.on_reject.items) |r| traceReaction(r, v);
}

inline fn traceReaction(r: promise.Reaction, v: anytype) void {
    markValueOpt(v, r.handler);
    markValueOpt(v, r.extra_argument);
    if (r.retained_async_activation) |activation|
        v.mark(@as(*vm.Generator, @ptrCast(@alignCast(activation))));
    if (r.detached) return;
    if (r.result) |result| {
        markManaged(v, result);
    } else {
        markValue(v, r.resolve);
        markValue(v, r.reject);
    }
}

inline fn traceMicrotask(mt: promise.Microtask, v: anytype) void {
    switch (mt.kind) {
        .reaction => {
            traceReaction(mt.reaction, v);
            markValue(v, mt.argument);
        },
        .thenable => {
            markValue(v, mt.thenable);
            markValue(v, mt.then_fn);
            if (mt.promise) |p| markManaged(v, p);
        },
        .callback => markValue(v, mt.callback),
        .native_callback => {},
        .job => {
            markValue(v, mt.job);
            markValue(v, mt.job_first);
            markValue(v, mt.job_second);
        },
        .next_tick => {
            markValue(v, mt.job);
            for (mt.job_args) |argument| markValue(v, argument);
        },
    }
}

pub fn traceGenerator(g: *vm.Generator, v: anytype) void {
    v.mark(g.env);
    for (g.exec.stack.items) |s| markValue(v, s);
    markValue(v, g.exec.acc);
    markValue(v, g.this_value);
    v.mark(g.home_object);
    v.mark(g.super_ctor);
    v.mark(g.result);
    if (g.async_parent_promise) |parent| markManaged(v, parent);
    for (g.pendingRequests()) |req| {
        markValue(v, req.value);
        v.mark(req.result);
    }
}

fn finalizeGenerator(g: *vm.Generator, a: std.mem.Allocator, live: *usize) void {
    const flags = g.backing_flags;
    var released: usize = 0;
    if (flags.stack) {
        g.exec.stack.deinit(a);
        g.exec.stack = .empty;
        released += 1;
    }
    if (flags.handlers) {
        g.exec.handlers.deinit(a);
        g.exec.handlers = .empty;
        released += 1;
    }
    if (flags.requests) {
        g.requests.deinit(a);
        g.requests = .empty;
        g.requests_head = 0;
        released += 1;
    }
    if (released > 0) {
        _ = @atomicRmw(usize, live, .Sub, released, .monotonic);
    }
    g.backing_flags = .{};
    g.backing_allocator = null;
    g.backing_stores_live = null;
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
        if (m.deferred_ns) |ns| v.mark(ns);
        if (m.import_meta_slot.obj) |o| v.mark(o);
        if (m.eval_error) |err| markValue(v, err);
        if (m.completion_promise) |completion| markManaged(v, completion);
        for (m.dynamic_waiters.items) |waiter| {
            markManaged(v, waiter.capability);
            v.mark(waiter.namespace);
        }
    }
}

pub fn traceInterpreterRoots(machine: *interp.Interpreter, v: anytype) void {
    markManaged(v, machine.env);
    traceEnv(machine.env, v);
    // Active VM operand stacks: arena-backed, so their live `Value`s are
    // invisible to both the precise object graph and the conservative native
    // stack scan. The VM flushes `acc`/`ip` into each `Exec` at the safepoint
    // before collecting, so these reads are current.
    for (machine.gc_execs.items) |exec| {
        for (exec.stack.items) |s| markValue(v, s);
        markValue(v, exec.acc);
        // The activation's frame slots (and its captured-frame parent chain for
        // upvalues) are arena-backed locals — invisible to both the precise
        // object graph and the native-stack scan, exactly like the operand stack
        // above. Without tracing them an object live only through a VM local is
        // swept mid-collection (a use-after-free that surfaces as a garbage
        // `restricted_to` ⇒ spurious ConcurrentAccessError).
        //
        // Once a closure captures a frame it is marked `escaped`, and the VM
        // serializes its slots with `slot_lock` (see `store_local`/`load_upval`).
        // A cross-thread closure makes this parent-chain walk reach a *running*
        // peer's live escaped frame, so under a concurrent/parallel trace the
        // read must take that same lock or it races the mutator's slot store.
        // Gated on `v.concurrent()` + `escaped`: a stop-the-world trace (no
        // mutator running) and never-captured frames (the vast majority) lock
        // nothing.
        const lock_slots = v.concurrent();
        var fr: ?*vm.Frame = exec.frame;
        while (fr) |f| : (fr = f.parent) {
            const held = f.lockSlots(lock_slots);
            for (f.slots) |slot| markValue(v, slot);
            f.unlockSlots(held);
        }
    }
    for (machine.gc_wasm_roots.items) |roots| traceWasmExecutionRoots(roots, v);
    if (machine.microtasks) |q| {
        machine.lockMicrotasks();
        for (q.pendingItems()) |mt| traceMicrotask(mt, v);
        machine.unlockMicrotasks();
    }
    if (machine.next_ticks) |q| {
        machine.lockJobQueue(q);
        for (q.pendingItems()) |mt| traceMicrotask(mt, v);
        machine.unlockJobQueue(q);
    }
    if (machine.current_microtask) |mt| traceMicrotask(mt, v);
    for (machine.current_microtask_batch) |mt| traceMicrotask(mt, v);
    for (machine.current_hold_jobs) |job| jsthread.traceHoldJobRoot(job, v);
    if (machine.async_waiters) |waiters| {
        machine.lockRealm();
        defer machine.unlockRealm();
        for (waiters.items) |aw| markValue(v, aw.promise);
    }
    // NOTE: the shared realm `finalization_cleanup_jobs` is intentionally NOT
    // traced here. Unlike the per-thread lists above, every interpreter's
    // `finalization_cleanup_jobs` aliases the one Context-owned queue, which the
    // collector already traces under `realm_lock` in `Binding.traceRoots` at
    // begin + every `concurrentMarkRound` re-scan + finish. Reading it here (off
    // the collector thread, at a mutator's publish safepoint) took no lock and
    // raced `drainFinalizationCleanupJobs`'s clear — a crash the parallel marker
    // only reaches once collections actually converge. See `Binding.traceRoots`.
    for (machine.gc_env_roots.items) |env| {
        markManaged(v, env);
        traceEnv(env, v);
    }
    for (machine.gc_temp_roots.items) |root| markValue(v, root);
    for (machine.gc_object_reserve.items) |object| v.mark(object);
    var literal_it = machine.string_literal_cache.valueIterator();
    while (literal_it.next()) |literal| markValue(v, literal.*);
    var template_it = machine.template_cache.valueIterator();
    while (template_it.next()) |template| markValue(v, template.*);
    if (machine.tdz_marker) |o| v.mark(o);
    if (machine.global_object) |o| v.mark(o);
    var sym_it = machine.symbols.valueIterator();
    while (sym_it.next()) |sym| v.mark(sym.*);
    if (machine.import_meta_slot) |slot| {
        if (slot.obj) |o| v.mark(o);
    } else if (machine.import_meta_obj) |o| v.mark(o);
    markValue(v, machine.ret_value);
    markValue(v, machine.this_value);
    markValue(v, machine.exception);
    markValue(v, machine.new_target);
    if (machine.active_native) |o| v.mark(o);
    if (machine.active_function) |o| v.mark(o);
    var call_frame = machine.active_call_frame;
    while (call_frame) |fr| : (call_frame = fr.caller) {
        v.mark(fr.func_obj);
        if (fr.arguments) |args| markValue(v, args);
    }
    // Inspector frames point at the real lexical environments and `this`
    // values used by suspended execution. Keep every caller scope alive during
    // the synchronous paused callback, including closure calls whose caller
    // environment is not in the callee's lexical parent chain.
    var debug_frame = machine.debug_call_frame;
    while (debug_frame) |fr| : (debug_frame = fr.caller) {
        markManaged(v, fr.environment);
        traceEnv(fr.environment, v);
        markValue(v, fr.this_value);
    }
    if (machine.debug_top_level_environment) |env| {
        markManaged(v, env);
        traceEnv(env, v);
    }
    if (machine.home_object) |o| v.mark(o);
    if (machine.super_ctor) |o| v.mark(o);
    for (machine.with_stack.items) |o| v.mark(o);
}

fn traceWasmSlot(slot: value.WasmSlot, v: anytype) void {
    switch (slot) {
        .externref, .hostref => |root| markValue(v, root),
        .exnref => |exception| if (exception) |ex|
            for (ex.externrefs) |root| markValue(v, root),
        .gcref => |reference| if (reference) |root| {
            const Marker = struct {
                fn mark(raw: *anyopaque, child: Value) void {
                    const visitor: @TypeOf(v) = @ptrCast(@alignCast(raw));
                    markValue(visitor, child);
                }
            };
            root.trace(root, @ptrCast(v), Marker.mark);
        },
        .externalized_gcref => |root| root.trace(root, @ptrCast(v), struct {
            fn mark(raw: *anyopaque, child: Value) void {
                const visitor: @TypeOf(v) = @ptrCast(@alignCast(raw));
                markValue(visitor, child);
            }
        }.mark),
        .numeric, .vector, .funcref, .i31ref, .externalized_i31 => {},
    }
}

fn traceWasmExecutionRoots(roots: *const value.WasmExecutionRoots, v: anytype) void {
    for (roots.stack) |slot| traceWasmSlot(slot, v);
    for (roots.locals) |slot| traceWasmSlot(slot, v);
    for (roots.exceptions) |exception|
        for (exception.externrefs) |root| markValue(v, root);
}

/// A `Visitor`-shaped adapter that routes every root it is handed through the
/// insertion write barrier (`gc_runtime.barrier` → the active heap's
/// `writeBarrier`) instead of the marker-private `mark_stack`. This is how a
/// *running* mutator publishes its own roots into a concurrent parallel mark
/// (issue #1 M3): the barrier shades each cell grey and hands it to the marker
/// through the lock-guarded `barrier_buf`, which is the only mutator→marker
/// channel that is safe to touch off the collector thread. Marking is idempotent
/// (a re-shaded cell's CAS just fails), so publishing already-marked roots is
/// cheap. The transitive trace is the marker's job — this only greys the cells
/// the interpreter holds *directly*.
const RootPublishVisitor = struct {
    pub fn mark(_: *RootPublishVisitor, cell: ?*anyopaque) void {
        gc_runtime.barrier(cell);
    }
    // Roots are strong; weak edges are reconciled by the marker at the
    // world-stopped finish, so a publishing mutator must not shade them.
    pub fn markWeak(_: *RootPublishVisitor, _: *?*anyopaque) void {}
    pub fn markWeakAtomic(_: *RootPublishVisitor, _: *std.atomic.Value(?*anyopaque)) void {}
    // The interpreter root set is precise; no conservative words to publish.
    pub fn markConservativeWord(_: *RootPublishVisitor, _: usize) void {}
    pub fn markConservativeWords(_: *RootPublishVisitor, _: [*]const usize, _: usize) void {}
    pub fn deferToFinish(_: *RootPublishVisitor, _: *anyopaque) void {}
    // Always true: publication only happens during a concurrent mark, and this
    // makes `traceEnv` read binding tables under `binding_lock` for the HB edge.
    pub fn concurrent(_: *RootPublishVisitor) bool {
        return true;
    }
    // `barrier` validates the cell itself (magic check), so accept any pointer.
    pub fn isManaged(_: *RootPublishVisitor, cell: ?*anyopaque) bool {
        return cell != null;
    }
    pub fn isMarked(_: *RootPublishVisitor, _: ?*anyopaque) bool {
        return false;
    }
};

/// Publish a running interpreter's precise roots into the active concurrent
/// marker, **from the thread that owns `machine`, at a GC safepoint** (between
/// bytecodes, holding no per-structure lock). Each root cell is shaded through
/// the insertion barrier (`barrier_buf`), so the collector thread can keep
/// draining without ever reading this thread's live VM/native stack. Only the
/// owner can scan its own running stack soundly — this is the per-mutator side
/// of the parallel-GC root handshake (`src/root_handshake.zig`).
pub fn publishInterpreterRoots(machine: *interp.Interpreter) void {
    var pv = RootPublishVisitor{};
    traceInterpreterRoots(machine, &pv);
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

    pub fn recoverAllocationFailure(self: *Binding) bool {
        return self.context.collectForAllocationFailure(currentInterpreter());
    }

    /// Optional zig-gc fast membership hook. The reusable cell backing can
    /// validate an allocation-start address without touching candidate memory;
    /// zig-gc still checks live header magic and retains its hash/list fallback
    /// for delegated allocations and bindings without this hook.
    pub fn ownsCellAllocation(self: *Binding, allocation: *anyopaque) bool {
        const backing = self.context.gc_cell_backing orelse return false;
        return backing.ownsCellAllocation(allocation);
    }

    /// Publish owned-slot classification only after zig-gc has initialized the
    /// complete header. The backing's bucket lock supplies the release/acquire
    /// edge to conservative classifiers on peer threads.
    pub fn publishCellAllocation(self: *Binding, allocation: *anyopaque, total: usize) void {
        const backing = self.context.gc_cell_backing orelse unreachable;
        backing.publishCellAllocation(allocation, total);
    }

    /// Amortize publication synchronization for the VM's same-size object
    /// allocation batches while preserving the same header-before-bit order.
    pub fn publishCellAllocationBatch(self: *Binding, payloads: []*anyopaque, total: usize, payload_offset: usize) void {
        const backing = self.context.gc_cell_backing orelse unreachable;
        backing.publishCellAllocationBatch(payloads, total, payload_offset);
    }

    /// Withdraw classification before zig-gc clears/finalizes/reuses a header.
    pub fn unpublishCellAllocation(self: *Binding, allocation: *anyopaque, total: usize) void {
        const backing = self.context.gc_cell_backing orelse unreachable;
        backing.unpublishCellAllocation(allocation, total);
    }

    /// A successful eligible-size allocation necessarily came from the cell
    /// slab: this backing fails rather than delegating when slab growth OOMs.
    pub fn usesOwnedCellStorage(_: *Binding, total: usize) bool {
        return ContextMod.GcCellBacking.usesCellSlab(total);
    }

    /// Optional zig-gc batch-backing hook. Same-kind cell batches share one
    /// size-class lock while their slabs remain private; zig-gc still owns all
    /// header initialization and metadata publication.
    pub fn allocateCellBatch(self: *Binding, total: usize, out: []*anyopaque) usize {
        const backing = self.context.gc_cell_backing orelse return 0;
        return backing.allocateCellBatch(total, out);
    }

    /// Optional zig-gc sweep hook. Dead cells are already finalized and
    /// unlinked; return a bounded same-size run under one backing lock.
    pub fn freeCellStorageBatch(self: *Binding, total: usize, allocations: []*anyopaque) void {
        const backing = self.context.gc_cell_backing orelse unreachable;
        backing.freeCellStorageBatch(total, allocations);
    }

    /// Optional zig-gc weak-pass gate. Runtime constructors publish the
    /// Context's monotonic bit before weak semantic state becomes observable.
    pub fn hasWeakWork(self: *Binding) bool {
        return self.context.gc_weak_work.load(.acquire);
    }

    pub fn classifyConservativeInterior(self: *Binding, address: usize) gc.InteriorOwnership {
        const backing = self.context.gc_cell_backing orelse return .outside;
        return backing.classifyConservativeInterior(address);
    }

    pub fn allCellsUseOwnedStorage(_: *Binding) bool {
        return true;
    }

    /// Persistent roots reachable from the realm plus registered active
    /// Interpreter execution roots at quiescent checkpoints.
    pub fn traceRoots(self: *Binding, v: anytype) void {
        const ctx = self.context;
        // Mid-script collection: conservatively root the collecting thread's
        // live native stack + spilled callee-saved registers, which hold the
        // tree-walker's `Value` locals and the VM's transient accumulator. Only
        // enabled (`gc_scan_native_stack`) for a guarded mid-script collect;
        // quiescent collection keeps it off and stays precise. See
        // `stack_scan.zig` and docs/threads/P7-gc-design.md.
        const par: ?*interp.Interpreter = ctx.gc_par_collector.load(.acquire);
        if (ctx.gc_scan_native_stack) {
            _ = stack_scan.scan(v);
            // Plus every parked peer thread's published range (the multi-thread
            // safepoint protocol): their stacks are frozen. Skipped under a
            // *parallel* collection: there, a parked peer is traced precisely via
            // `gc_parked` (below), and its park record's `beginPark`/`endPark`
            // flip too fast to scan race-free without the GIL it doesn't hold.
            if (par == null and ctx.gc_scan_parked_stacks) if (ctx.gil) |g| {
                const me = stack_scan.parkRecord();
                for (g.park_records.items) |rec| {
                    if (rec == me) continue;
                    if (stack_scan.isParked(rec)) stack_scan.scanRecord(rec, v);
                }
            };
        }
        // Under a *parallel* collection (`par` set, the elected collector
        // interpreter) we read each shared realm list under the same lock its
        // mutators take, and trace only the collector's own interpreter + parked
        // peers precisely — running peers self-publish their roots through the
        // insertion barrier (see `Context.driveParallelCollection`).
        v.mark(ctx.global_object);
        v.mark(ctx.tdz_marker);
        for (ctx.c_api_builtin_constructors) |constructor| markValue(v, constructor);
        if (ctx.reserved_thread_oom_error) |err| markValue(v, err);
        if (ctx.private_pending_exception_root) |err| markValue(v, err);
        traceEnv(&ctx.env, v); // the global environment is embedded by value (binding_lock)

        if (par != null) ctx.lockMicrotasks();
        for (ctx.microtasks.pendingItems()) |mt| traceMicrotask(mt, v);
        if (par != null) ctx.unlockMicrotasks();
        if (par != null) ctx.next_ticks.acquire();
        for (ctx.next_ticks.pendingItems()) |mt| traceMicrotask(mt, v);
        if (par != null) ctx.next_ticks.release();

        // `async_waiters` + `c_api_handles` + `finalization_cleanup_jobs` share
        // `realm_lock` (taken by their mutators only under parallel_js).
        ctx.realmLock();
        for (ctx.unhandled_rejections.items) |rejected| markManaged(v, rejected);
        for (ctx.handled_rejections.items) |handled| markManaged(v, handled);
        traceModuleGraph(&ctx.module_registry, v);
        if (ctx.mod_cache) |cache|
            if (cache != &ctx.module_registry) traceModuleGraph(cache, v);
        for (ctx.async_waiters.items) |aw| markValue(v, aw.promise);
        for (ctx.finalization_cleanup_jobs.items) |registry| v.mark(registry);
        for (ctx.c_api_class_prototypes.items) |prototype| v.mark(prototype.object);
        for (ctx.c_api_handles.items) |h| {
            // each ref is a `*Boxed` ({ value: Value }), so the pointer aliases `*Value`.
            const vp: *const Value = @ptrCast(@alignCast(h.ref));
            markValue(v, vp.*);
        }
        for (ctx.private_strong_roots.items) |root| markValue(v, root.value);
        for (ctx.private_weak_roots.items) |root| v.markWeakAtomic(&root.target);
        ctx.realmUnlock();

        if (ctx.gil) |g| jsthread.traceGilTaskRoots(g, v);

        if (par != null) if (ctx.gil) |g| g.lockApi();
        for (ctx.js_threads.items) |rec| {
            const io = agent.engineIo();
            rec.join_mutex.lockUncancelable(io);
            defer rec.join_mutex.unlock(io);
            markValue(v, rec.result);
            if (rec.js_obj) |o| v.mark(o);
            for (rec.pending_joins.items) |pending| v.mark(pending.promise);
            for (rec.settling_joins.items) |pending| v.mark(pending.promise);
        }
        if (par != null) if (ctx.gil) |g| g.unlockApi();

        ctx.lockActiveInterpreters();
        for (ctx.active_interpreters.items) |machine| {
            // In a parallel collection, trace directly only interpreters whose
            // VM stack is *stable*: the collector's own (at its safepoint) and any
            // peer blocked in native park code (`gc_parked` — frozen, not running
            // JS). A *running* peer's stack changes underfoot, so it publishes its
            // own roots through the barrier at a safepoint instead.
            if (par) |collector| {
                if (machine != collector) {
                    // Fast path: a running peer self-publishes; never read its
                    // live stack. The unlocked load is a hint — re-checked below.
                    if (!machine.gc_parked.load(.acquire)) continue;
                    // Looks parked. Pin the frozen state under `gc_root_lock` and
                    // re-check: the owner clears `gc_parked` under the same lock
                    // before it resumes, so if it still reads `true` here the peer
                    // cannot wake and mutate its operand stack / frame slots until
                    // we release. Without this pin the direct read races the
                    // owner's `store_local`/operand-stack writes on wake — the data
                    // race behind the red TSan gate. See `Interpreter.gc_root_lock`.
                    machine.lockGcRoots();
                    defer machine.unlockGcRoots();
                    if (!machine.gc_parked.load(.acquire)) continue; // raced to running
                    traceInterpreterRoots(machine, v);
                    continue;
                }
            }
            traceInterpreterRoots(machine, v);
        }
        ctx.unlockActiveInterpreters();

        if (ctx.gil) |g| {
            g.lockPropWaiters();
            defer g.unlockPropWaiters();
            for (g.prop_async.items) |raw| {
                const t: *jsthread.PropAsyncTicket = @ptrCast(@alignCast(raw));
                v.mark(t.obj);
                v.mark(t.promise);
            }
        }
        // `ctx.exception` is the host/join hand-off slot — redundant with each
        // active interpreter's own `exception` (traced above) and mutated by
        // peers without a lock, so skip it under a parallel collection.
        if (par == null) markValue(v, ctx.exception orelse Value.undef());
    }

    pub fn trace(cell: *anyopaque, kind: Kind, v: anytype) void {
        // `generator` and `iter_helper` have mutable storage that is too
        // entangled to read safely while the mutator runs (a running generator's
        // `exec` is the live VM stack; an iterator helper's `inner`/`padding`
        // update around JS callbacks and `inner` is a 16-byte `?Value`). Under a
        // concurrent mark, defer their tracing to the world-stopped finish (the
        // cell is already marked, so it survives; its edges are found at finish).
        // Object/Environment/Promise are synchronized for concurrent tracing
        // directly (per-structure locks / atomic slots), so they trace inline.
        if (v.concurrent() and (kind == .generator or kind == .iter_helper)) {
            v.deferToFinish(cell);
            return;
        }
        switch (kind) {
            .object => traceObject(@ptrCast(@alignCast(cell)), v),
            .string => {},
            .environment => traceEnv(@ptrCast(@alignCast(cell)), v),
            .function => traceFunction(@ptrCast(@alignCast(cell)), v),
            .bound_fn => traceBoundFn(@ptrCast(@alignCast(cell)), v),
            .promise => tracePromise(@ptrCast(@alignCast(cell)), v),
            .generator => traceGenerator(@ptrCast(@alignCast(cell)), v),
            .iter_helper => traceIterHelper(@ptrCast(@alignCast(cell)), v),
            .module_ns => traceModuleNs(@ptrCast(@alignCast(cell)), v),
        }
    }

    /// Object and Environment mutations are funneled through owner-aware
    /// barriers. Mutable type-erased side cells have a wider set of lifecycle
    /// writes, so quiescent minor GC conservatively rescans those old kinds.
    /// Function reference fields are the exception: closure/home/super/object
    /// links are fully initialized before the function is published and never
    /// rewritten afterward, so promoting the function and its edges together is
    /// sufficient and avoids retracing every old builtin closure each cycle.
    pub fn traceOldOnMinor(kind: Kind) bool {
        return kind != .object and kind != .string and kind != .environment and kind != .function;
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
                // The heap running this collection is the Context's own (afterWeak
                // only fires mid-collect), and marks are still valid (pre-sweep).
                const heap = self.context.gc orelse return;
                if (pruneDeadWeakEntries(o, heap)) self.context.queueFinalizationRegistryCleanup(o);
            },
            else => {},
        }
    }

    pub fn afterWeakRoots(self: *Binding) void {
        self.context.runPrivateWeakFinalizers();
    }

    /// Drain embedder callbacks only after zig-gc has completed sweep, released
    /// its allocation lock, and restored allocation publication. Cell
    /// finalizers themselves merely enqueue stable Context-owned records.
    pub fn afterSweep(self: *Binding) void {
        self.context.runDeferredPostSweepCallbacks();
    }

    /// A cell is being reclaimed. Arena-mode `ArrayBufferData` is released with
    /// the arena, but GC-mode buffers own their metadata and non-shared byte
    /// slabs individually. A SharedArrayBuffer wrapper owns one realm retain
    /// that must be released when the wrapper cell dies.
    pub fn finalize(self: *Binding, cell: *anyopaque, kind: Kind) void {
        if (self.context.gc_finalizer_stats_out) |stats| stats.addKind(kind);
        switch (kind) {
            .object => {
                const o: *Object = @ptrCast(@alignCast(cell));
                if (o.cApiObjectOwner()) |owner| self.context.queueCApiObjectFinish(owner);
                if (o.wasmGcReference()) |state| {
                    if (state.root) |root| if (state.release) |release| release(root, o);
                    state.root = null;
                    state.reference = null;
                }
                if (o.wasmException()) |state| {
                    if (state.exception) |exception|
                        _ = exception.wrapper.cmpxchgStrong(o, null, .acq_rel, .acquire);
                    state.exception = null;
                }
                // Buffer metadata now lives in the cold sidecar. Release it
                // before finalizeObjectBacking destroys that sidecar.
                if (o.arrayBuffer()) |ab| {
                    if (self.context.gc_finalizer_stats_out) |stats| {
                        stats.array_buffers += 1;
                        if (ab.shared != null) stats.shared_array_buffers += 1;
                    }
                    if (ab.native_handle.swap(null, .acq_rel)) |handle| handle.releaseWrapper();
                    if (ab.shared) |storage| {
                        const sab_released = self.context.sab_retains.releaseTracked(storage);
                        std.debug.assert(sab_released);
                        if (sab_released) ab.shared = null;
                    } else if (ab.external_owner) |owner| {
                        self.context.queueExternalOwnerRelease(owner);
                        ab.external_owner = null;
                    } else if (ab.gc_owned and ab.local_data.len > 0) {
                        self.context.gpa.rawFree(ab.local_data, .@"8", @returnAddress());
                        _ = @atomicRmw(usize, &self.context.gc_array_buffer_bytes_live, .Sub, ab.local_data.len, .monotonic);
                        ab.local_data = &.{};
                    }
                    if (ab.gc_owned) {
                        self.context.gpa.destroy(ab);
                        o.clearArrayBuffer();
                    }
                }
                const backing_flags = o.backingFlagsSnapshot();
                if (hasObjectBacking(backing_flags) or o.privateBrands() != null) {
                    const released = finalizeObjectBacking(o, o.backingAllocatorIfActive() orelse self.context.gpa);
                    if (released > 0) {
                        if (self.context.gc_finalizer_stats_out) |stats| stats.object_backing_releases += released;
                        _ = @atomicRmw(usize, &self.context.gc_object_backing_stores_live, .Sub, released, .monotonic);
                    }
                }
            },
            .string => {
                const string: *StringCell = @ptrCast(@alignCast(cell));
                if (string.externalOwner()) |owner| {
                    self.context.queueExternalStringRelease(owner);
                    string.setExternalOwner(null);
                }
                if (string.bytes.len > 0) self.context.gpa.free(@constCast(string.bytes));
                _ = @atomicRmw(usize, &self.context.gc_string_bytes_live, .Sub, string.bytes.len, .monotonic);
                string.bytes = &.{};
                string.setGcManaged(false);
            },
            .environment => finalizeEnv(@ptrCast(@alignCast(cell))),
            .generator => finalizeGenerator(
                @ptrCast(@alignCast(cell)),
                self.context.gpa,
                &self.context.gc_generator_backing_stores_live,
            ),
            .promise => {
                const p: *promise.Promise = @ptrCast(@alignCast(cell));
                if (p.gc_owned) {
                    const count = p.on_fulfill.items.len + p.on_reject.items.len +
                        @intFromBool(p.on_fulfill_inline != null) + @intFromBool(p.on_reject_inline != null);
                    if (self.context.gc_finalizer_stats_out) |stats| stats.promise_reactions += count;
                    p.on_fulfill.deinit(self.context.gpa);
                    p.on_reject.deinit(self.context.gpa);
                    p.on_fulfill_inline = null;
                    p.on_reject_inline = null;
                    p.on_fulfill = .empty;
                    p.on_reject = .empty;
                    if (count > 0) {
                        _ = @atomicRmw(usize, &self.context.gc_promise_reactions_live, .Sub, count, .monotonic);
                    }
                }
            },
            else => {},
        }
    }
};

/// The engine's GC heap type. `Context` holds one behind `enable_gc`.
pub const Heap = gc.Heap(Binding);

test "Object fits the 128-byte GC slab and cold sidecar fits 256 bytes" {
    // The raw payload can differ across target ABIs even when the allocator
    // selects the same slab. Keep the production invariant target-independent.
    try std.testing.expect(@sizeOf(Object) <= 128);
    // Auto-layout may reorder the cold fields as unrelated test imports make
    // more code reachable. The invariant is its GC allocation class, not one
    // compiler-specific raw byte count.
    try std.testing.expect(@sizeOf(value.ObjectColdState) <= 224);
    try std.testing.expectEqual(@as(usize, 128), Heap.cellAllocationBytes(Object));
    try std.testing.expect(Heap.cellAllocationBytes(value.ObjectColdState) <= 256);
}

fn managedCellType(comptime kind: CellKind) type {
    return switch (kind) {
        .object => Object,
        .string => StringCell,
        .environment => Environment,
        .function => interp.Function,
        .bound_fn => interp.Interpreter.BoundFn,
        .promise => promise.Promise,
        .generator => vm.Generator,
        .iter_helper => value.IterHelper,
        .module_ns => interp.ModuleNs,
    };
}

comptime {
    if (Heap.cellAllocationBytes(Object) > 512)
        @compileError("Object payload no longer fits the 512-byte GC slab");
    for (@typeInfo(CellKind).@"enum".field_values) |raw_kind| {
        const Cell = managedCellType(@enumFromInt(raw_kind));
        if (!ContextMod.GcCellBacking.usesCellSlab(Heap.cellAllocationBytes(Cell)))
            @compileError("GC cell exceeds owned slab storage: " ++ @typeName(Cell));
    }
}

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
        o.initInlineSlots();
        return o;
    }
    const o = try arena.create(Object);
    o.* = .{};
    o.initInlineSlots();
    return o;
}

/// Allocate and default-initialize a same-kind prefix for callers that can
/// consume several objects before their next safepoint. GC-backed heaps
/// publish the prefix under one metadata lock; arena mode preserves the same
/// short-prefix/OOM ordering by returning prior successful allocations before
/// retrying the failed position on the next call.
pub fn allocObjectBatch(heap_erased: ?*anyopaque, arena: std.mem.Allocator, out: []*Object) std.mem.Allocator.Error!usize {
    if (out.len == 0) return 0;
    if (heap_erased) |h| {
        const heap: *Heap = @ptrCast(@alignCast(h));
        const count = try heap.createBatch(Object, .object, out);
        for (out[0..count]) |o| {
            o.* = .{};
            o.initInlineSlots();
        }
        if (builtin.is_test) _ = object_batch_cells_for_testing.fetchAdd(count, .monotonic);
        return count;
    }

    var count: usize = 0;
    while (count < out.len) {
        const o = arena.create(Object) catch |err| {
            if (count == 0) return err;
            break;
        };
        o.* = .{};
        o.initInlineSlots();
        out[count] = o;
        count += 1;
    }
    return count;
}

/// The GC heap whose cells the *current thread* allocates into, or null for the
/// arena. Each shared-realm thread sets it to the same context heap on entry;
/// it is set/restored at the realm's allocation entry points — `createWith`
/// for intrinsics, `evaluate`/`evaluateModule` for execution. This lets every
/// scattered `*.create(value.Object)` site funnel through `allocObj(arena)`
/// without threading the heap pointer through hundreds of signatures.
threadlocal var active_heap: ?*anyopaque = null;
threadlocal var active_interpreter: ?*interp.Interpreter = null;

/// Install `h` as this thread's active heap, returning the previous value (so
/// nested entry points can restore it). Pass null for the arena engine.
pub fn setActiveHeap(h: ?*anyopaque) ?*anyopaque {
    const prev = active_heap;
    active_heap = h;
    if (h) |raw| {
        const heap: *Heap = @ptrCast(@alignCast(raw));
        _ = strcell.setActiveManagedFactory(.{
            .context = raw,
            .create = allocManagedString,
            .create_owned = allocManagedStringOwned,
        });
        // Non-cell object side stores do not need the GC cell slab classifier in
        // single-mutator GC mode. True-parallel JS keeps the synchronized wrapper
        // because the embedder's allocator may not be thread-safe.
        const backing_allocator = if (heap.ctx.context.parallel_js) heap.backing else heap.ctx.context.gpa;
        _ = gc_runtime.setActive(.{ .object_backing = .{
            .allocator = backing_allocator,
            .stores_live = &heap.ctx.context.gc_object_backing_stores_live,
        } });
        _ = gc_runtime.setBarrier(raw, barrierThunk, weakBarrierThunk);
    } else {
        _ = strcell.setActiveManagedFactory(null);
        _ = gc_runtime.setActive(.{});
        _ = gc_runtime.setBarrier(null, null, null);
    }
    return prev;
}

fn finishManagedString(heap: *Heap, bytes: []u8) std.mem.Allocator.Error!*StringCell {
    errdefer heap.ctx.context.gpa.free(bytes);
    const cell = try heap.create(StringCell, .string);
    cell.* = .{ .bytes = bytes, .hash = strcell.hashBytes(bytes) };
    cell.setGcManaged(true);
    _ = @atomicRmw(usize, &heap.ctx.context.gc_string_bytes_live, .Add, bytes.len, .monotonic);
    return cell;
}

fn allocManagedString(
    raw: *anyopaque,
    _: std.mem.Allocator,
    source: []const u8,
) std.mem.Allocator.Error!*StringCell {
    const heap: *Heap = @ptrCast(@alignCast(raw));
    const bytes = try strcell.canonicalizeSurrogates(heap.ctx.context.gpa, source);
    return finishManagedString(heap, bytes);
}

fn allocManagedStringOwned(
    raw: *anyopaque,
    source_allocator: std.mem.Allocator,
    source: []u8,
) std.mem.Allocator.Error!*StringCell {
    const heap: *Heap = @ptrCast(@alignCast(raw));
    const target_allocator = heap.ctx.context.gpa;
    if (source_allocator.ptr == target_allocator.ptr and
        source_allocator.vtable == target_allocator.vtable and
        std.mem.indexOfScalar(u8, source, 0xED) == null)
    {
        return finishManagedString(heap, source);
    }
    defer source_allocator.free(source);
    const bytes = try strcell.canonicalizeSurrogates(target_allocator, source);
    return finishManagedString(heap, bytes);
}

/// Whether the current thread's cell-allocation funnels target the GC heap.
/// Callers use this immediately after allocation to persist exact ownership on
/// cell types that can also be embedded in a Context or allocated by an arena.
pub inline fn allocationsAreManaged() bool {
    return active_heap != null;
}

/// Install the interpreter currently executing JS on this thread. Allocation
/// failure recovery uses this only as an internal safepoint-owned capability:
/// if no interpreter is active, GC cell OOM recovery remains fail-closed.
pub fn setActiveInterpreter(machine: ?*interp.Interpreter) ?*interp.Interpreter {
    const prev = active_interpreter;
    active_interpreter = machine;
    return prev;
}

pub fn currentInterpreter() ?*interp.Interpreter {
    return active_interpreter;
}

/// Type-erased entry the `gc_runtime` shim calls at reference-store sites. The
/// heap maintains both the nursery remembered set and the incremental/full mark
/// invariant; see `gc_runtime.barrierFrom`.
fn barrierThunk(raw_heap: *anyopaque, owner: ?*anyopaque, cell: ?*anyopaque) void {
    const heap: *Heap = @ptrCast(@alignCast(raw_heap));
    heap.writeBarrierFrom(owner, cell);
}

fn weakBarrierThunk(raw_heap: *anyopaque, owner: ?*anyopaque) void {
    const heap: *Heap = @ptrCast(@alignCast(raw_heap));
    heap.writeBarrierWeak(owner);
}

/// Insertion write barrier for a stored `Value`. Objects and heap-managed
/// runtime strings carry cells; static/arena/interned strings are filtered.
/// Call at every post-creation store of a reference into a live GC cell.
pub inline fn barrierValue(v: Value) void {
    if (v.isObject()) {
        gc_runtime.barrier(@ptrCast(v.asObj()));
    } else if (v.isString()) {
        const cell = v.asStringCell();
        if (cell.isGcManaged()) gc_runtime.barrier(@constCast(cell));
    }
}

pub inline fn barrierValueFrom(owner: ?*anyopaque, v: Value) void {
    if (v.isObject()) {
        gc_runtime.barrierFrom(owner, @ptrCast(v.asObj()));
    } else if (v.isString()) {
        const cell = v.asStringCell();
        if (cell.isGcManaged()) gc_runtime.barrierFrom(owner, @constCast(cell));
    }
}

/// Insertion write barrier for a stored cell pointer (Object/Environment/…).
pub inline fn barrierCell(cell: ?*anyopaque) void {
    gc_runtime.barrier(cell);
}

pub inline fn barrierCellFrom(owner: ?*anyopaque, cell: ?*anyopaque) void {
    gc_runtime.barrierFrom(owner, cell);
}

/// Barrier an edge whose owner and child are known exact live payloads from the
/// active heap. Returns false in arena mode so callers can retain their generic
/// store path. The strict zig-gc entry avoids classifying either pointer through
/// the tolerant live-payload index.
pub inline fn barrierExactManagedCellFrom(owner: *anyopaque, cell: *anyopaque) bool {
    const raw = active_heap orelse return false;
    const heap: *Heap = @ptrCast(@alignCast(raw));
    heap.writeBarrierFromManaged(owner, cell);
    return true;
}

pub inline fn barrierWeak(owner: ?*anyopaque) void {
    gc_runtime.barrierWeak(owner);
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
        o.initInlineSlots();
        return o;
    }
    const o = try arena.create(Object);
    o.* = .{};
    o.initInlineSlots();
    return o;
}

/// Per-side-cell allocation funnels — same thread-local-active-heap rule as
/// `allocObj`, each tagged with its own `CellKind` so `trace`/`finalize`
/// dispatch correctly. These make the *cell* heap uniform (every heap object a
/// GC cell), the prerequisite for sound quiescent-point collection. Known
/// runtime side buffers owned by these cells are now either traced as ordinary
/// fields or recorded as GC-owned backing stores and released by finalizers.
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
    const g = try allocCell(vm.Generator, .generator, arena);
    initGeneratorBacking(g);
    return g;
}

pub fn initGeneratorBacking(g: *vm.Generator) void {
    if (active_heap) |h| {
        const heap: *Heap = @ptrCast(@alignCast(h));
        g.backing_allocator = heap.ctx.context.gpa;
        g.backing_stores_live = &heap.ctx.context.gc_generator_backing_stores_live;
    }
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
        if (o.slotsState()) |state| {
            state.list.deinit(self.gpa);
            self.gpa.destroy(state);
        }
        if (o.elementsState()) |state| {
            state.list.deinit(self.gpa);
            self.gpa.destroy(state);
        }
        if (o.accessorsMap()) |acc| {
            acc.deinit(self.gpa);
            self.gpa.destroy(acc);
        }
        if (o.coldState()) |cold| self.gpa.destroy(cold);
        if (o.storageState()) |storage| self.gpa.destroy(storage);
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

    var occupied_shape = Shape{
        .parent = null,
        .name = "edge",
        .slot = 0,
        .count = 1,
        .arena = a,
    };
    root.shape = &occupied_shape;
    root.inline_slots[0] = Value.obj(child);
    child.proto = gp;
    gp.shape = &occupied_shape;
    gp.inline_slots[0] = Value.obj(root); // cycle back to the root
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
    try map.put(a, "x", .{ .get = Value.obj(acc_target), .set = null });
    const holder_cold = try holder.ensureCold(a);
    holder_cold.accessors.store(map, .monotonic);
    try eng.roots.append(a, holder);

    heap.collect();
    // root-set {root,child,gp,holder,acc_target} all live; nothing new dies.
    try std.testing.expectEqual(@as(usize, 5), heap.live_cells);

    // Drop every root → everything is garbage; finalize frees each cell's memory.
    eng.roots.clearRetainingCapacity();
    heap.collect();
    try std.testing.expectEqual(@as(usize, 0), heap.live_cells);
}

test "gc pruneDeadWeakEntries removes dead weak keys with unordered tail removal" {
    const a = std.testing.allocator;
    var live_key: u8 = 1;
    var dead_key_a: u8 = 2;
    var dead_key_b: u8 = 3;

    var cold = value.ObjectColdState{};
    var storage = value.ObjectStorageState{ .owner_allocator = a };
    storage.cold.store(&cold, .monotonic);
    var o = Object{ .is_weak = true, .is_map = true, .storage = .init(&storage) };
    defer cold.weak_entries.deinit(a);
    try cold.weak_entries.append(a, .{ .key = @ptrCast(&dead_key_a), .value = Value.num(10) });
    try cold.weak_entries.append(a, .{ .key = @ptrCast(&dead_key_b), .value = Value.num(20) });
    try cold.weak_entries.append(a, .{ .key = @ptrCast(&live_key), .value = Value.num(30) });

    const FakeHeap = struct {
        live: ?*anyopaque,
        pub fn isLive(self: *const @This(), ptr: ?*anyopaque) bool {
            return ptr != null and ptr == self.live;
        }
    };
    const heap = FakeHeap{ .live = @ptrCast(&live_key) };

    try std.testing.expect(!pruneDeadWeakEntries(&o, &heap));
    try std.testing.expectEqual(@as(usize, 1), cold.weak_entries.items.len);
    try std.testing.expectEqual(@intFromPtr(&live_key), @intFromPtr(cold.weak_entries.items[0].key.?));
}

test "gc traces only the active microtask variant" {
    const Recorder = struct {
        marked: [8]?*anyopaque = .{ null, null, null, null, null, null, null, null },
        len: usize = 0,

        pub fn mark(self: *@This(), cell: ?*anyopaque) void {
            const p = cell orelse return;
            self.marked[self.len] = p;
            self.len += 1;
        }

        fn contains(self: *const @This(), cell: *anyopaque) bool {
            for (self.marked[0..self.len]) |marked| {
                if (marked == cell) return true;
            }
            return false;
        }
    };

    var reaction_handler = Object{};
    var reaction_argument = Object{};
    var thenable = Object{};
    var then_fn = Object{};
    var inactive_argument = Object{};
    var reaction_result = promise.Promise{ .gc_owned = true };
    var thenable_result = promise.Promise{ .gc_owned = true };
    var inactive_result = promise.Promise{ .gc_owned = true };

    var reaction_marks = Recorder{};
    traceMicrotask(.{
        .kind = .reaction,
        .reaction = .{ .handler = Value.obj(&reaction_handler), .result = &reaction_result },
        .argument = Value.obj(&reaction_argument),
        .fulfilled = true,
        .thenable = Value.obj(&thenable),
        .then_fn = Value.obj(&then_fn),
        .promise = &inactive_result,
    }, &reaction_marks);
    try std.testing.expect(reaction_marks.contains(&reaction_handler));
    try std.testing.expect(reaction_marks.contains(&reaction_argument));
    try std.testing.expect(reaction_marks.contains(&reaction_result));
    try std.testing.expect(!reaction_marks.contains(&thenable));
    try std.testing.expect(!reaction_marks.contains(&then_fn));
    try std.testing.expect(!reaction_marks.contains(&inactive_result));

    var thenable_marks = Recorder{};
    traceMicrotask(.{
        .kind = .thenable,
        .reaction = .{ .handler = Value.obj(&reaction_handler), .result = &inactive_result },
        .argument = Value.obj(&inactive_argument),
        .fulfilled = true,
        .thenable = Value.obj(&thenable),
        .then_fn = Value.obj(&then_fn),
        .promise = &thenable_result,
    }, &thenable_marks);
    try std.testing.expect(thenable_marks.contains(&thenable));
    try std.testing.expect(thenable_marks.contains(&then_fn));
    try std.testing.expect(thenable_marks.contains(&thenable_result));
    try std.testing.expect(!thenable_marks.contains(&reaction_handler));
    try std.testing.expect(!thenable_marks.contains(&inactive_argument));
    try std.testing.expect(!thenable_marks.contains(&inactive_result));

    var next_tick_callback = Object{};
    var next_tick_first = Object{};
    var next_tick_second = Object{};
    const next_tick_args = [_]Value{ Value.obj(&next_tick_first), Value.obj(&next_tick_second) };
    var next_tick_marks = Recorder{};
    traceMicrotask(.{
        .kind = .next_tick,
        .reaction = undefined,
        .argument = Value.obj(&inactive_argument),
        .fulfilled = true,
        .job = Value.obj(&next_tick_callback),
        .job_args = &next_tick_args,
    }, &next_tick_marks);
    try std.testing.expect(next_tick_marks.contains(&next_tick_callback));
    try std.testing.expect(next_tick_marks.contains(&next_tick_first));
    try std.testing.expect(next_tick_marks.contains(&next_tick_second));
    try std.testing.expect(!next_tick_marks.contains(&inactive_argument));
}

test "gc traces direct and exception-payload WebAssembly roots" {
    const Recorder = struct {
        marked: [7]?*anyopaque = .{ null, null, null, null, null, null, null },
        len: usize = 0,

        pub fn mark(self: *@This(), cell: ?*anyopaque) void {
            const ptr = cell orelse return;
            self.marked[self.len] = ptr;
            self.len += 1;
        }

        fn contains(self: *const @This(), cell: *anyopaque) bool {
            for (self.marked[0..self.len]) |marked|
                if (marked == cell) return true;
            return false;
        }
    };

    var stack_ref = Object{};
    var local_ref = Object{};
    var numeric_only = Object{};
    var funcref_only = Object{};
    var nested_ref = Object{};
    var pending_ref = Object{};
    var aggregate_ref = Object{};
    var host_ref = Object{};
    var dummy_tag: u8 = 0;
    var dummy_owner: u8 = 0;
    const AggregateTrace = struct {
        fn trace(reference: *value.WasmGcRef, raw: *anyopaque, mark: value.WasmGcMarkValueFn) void {
            const child: *Object = @ptrCast(@alignCast(reference.context));
            mark(raw, Value.obj(child));
        }
    };
    var aggregate_header: value.WasmGcRef = .{
        .context = @ptrCast(&aggregate_ref),
        .trace = AggregateTrace.trace,
    };
    const nested_payload = [_]value.WasmSlot{.{ .externref = Value.obj(&nested_ref) }};
    var nested_exception: value.WasmException = .{
        .tag = @ptrCast(&dummy_tag),
        .payload = &nested_payload,
        .externrefs = &.{Value.obj(&nested_ref)},
        .owner = @ptrCast(&dummy_owner),
    };
    const pending_payload = [_]value.WasmSlot{.{ .externref = Value.obj(&pending_ref) }};
    var pending_exception: value.WasmException = .{
        .tag = @ptrCast(&dummy_tag),
        .payload = &pending_payload,
        .externrefs = &.{Value.obj(&pending_ref)},
        .owner = @ptrCast(&dummy_owner),
    };
    const stack = [_]value.WasmSlot{
        .{ .numeric = @intFromPtr(&numeric_only) },
        .{ .funcref = @ptrCast(&funcref_only) },
        .{ .externref = Value.obj(&stack_ref) },
        .{ .exnref = &nested_exception },
        .{ .gcref = &aggregate_header },
        .{ .hostref = Value.obj(&host_ref) },
        .{ .externalized_gcref = &aggregate_header },
    };
    const locals = [_]value.WasmSlot{.{ .externref = Value.obj(&local_ref) }};
    const roots: value.WasmExecutionRoots = .{
        .stack = &stack,
        .locals = &locals,
        .exceptions = &.{&pending_exception},
    };
    var recorder: Recorder = .{};
    traceWasmExecutionRoots(&roots, &recorder);
    try std.testing.expect(recorder.contains(&stack_ref));
    try std.testing.expect(recorder.contains(&local_ref));
    try std.testing.expect(recorder.contains(&nested_ref));
    try std.testing.expect(recorder.contains(&pending_ref));
    try std.testing.expect(recorder.contains(&aggregate_ref));
    try std.testing.expect(recorder.contains(&host_ref));
    try std.testing.expect(!recorder.contains(&numeric_only));
    try std.testing.expect(!recorder.contains(&funcref_only));
}
