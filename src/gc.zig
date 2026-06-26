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
    if (val.isObject()) v.mark(val.asObj());
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
    // Single-word pointer fields. `proto` is the one that a *reachable* object's
    // mutator can rewrite post-creation (a `setPrototypeOf` reparent, which also
    // fires the insertion barrier to shade the new target); under a concurrent
    // mark we read it with a relaxed atomic load to be race-free per the memory
    // model (a plain mov on x86_64/arm64). The reparent sites pair this with an
    // atomic store. `ctor_ref`/`proxy_target`/`proxy_handler` are written only at
    // creation, before the cell is published to the marker (the born-grey
    // hand-off establishes happens-before), so a plain read is safe.
    const concurrent = v.concurrent();
    v.mark(if (concurrent) @atomicLoad(?*Object, &o.proto, .monotonic) else o.proto);
    v.mark(o.ctor_ref);
    v.mark(o.proxy_target);
    v.mark(o.proxy_handler);

    // Growable storage (slots/accessors behind `property_lock`, elements behind
    // `elements_lock`): under a *concurrent* mark (M3) the marker must read it
    // under the same lock the mutator takes, or a concurrent append/realloc
    // tears the slice. Under stop-the-world (M1) / GIL-held incremental (M2)
    // marking the world is quiescent during the read, so we skip the lock.
    if (concurrent) o.lockProperties();
    for (o.slots.items) |slot| markValue(v, slot);
    if (o.accessors) |acc| {
        var it = acc.valueIterator();
        while (it.next()) |a| {
            markValueOpt(v, a.get);
            markValueOpt(v, a.set);
        }
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
        for (o.elements.items) |el| markValue(v, el);
        if (concurrent) o.unlockElements();
    }
    markValueOpt(v, o.prim);
    markWeakObject(v, &o.weak_ref_target); // a stable field address — safe to register
    if (o.is_finalization_registry) {
        markValue(v, o.finalization_callback);
        // Only `held` is a strong edge (mark it by value under the entry-storage
        // lock so a concurrent append can't tear the read). target/token are
        // weak — their liveness is decided by `isLive` at finish, not registered.
        if (concurrent) o.lockElements();
        for (o.finalization_records.items) |*record| markValue(v, record.held);
        if (concurrent) o.unlockElements();
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
    interp.traceNativePrivateData(o, v);
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

/// World-stopped finish pass (afterWeak): drop weak entries whose key died and
/// mark finalization records whose target died as ready. Liveness is read
/// directly from `heap.isLive` (the mark bit) rather than from a pre-registered
/// interior weak slot — so this is correct even when the mark ran concurrently
/// with a mutator that grew `weak_entries`/`finalization_records`. Behaviorally
/// identical to the old markWeak-then-null-then-prune for the stop-the-world and
/// GIL-held paths (a dead key/target is exactly an unmarked managed cell).
pub fn pruneDeadWeakEntries(o: *Object, heap: anytype) bool {
    var cleanup_ready = false;
    if (o.is_weak and (o.is_map or o.is_set)) {
        var i: usize = 0;
        while (i < o.weak_entries.items.len) {
            if (!heap.isLive(o.weak_entries.items[i].key)) {
                _ = o.weak_entries.orderedRemove(i);
            } else {
                i += 1;
            }
        }
    }
    if (o.is_finalization_registry) {
        for (o.finalization_records.items) |*record| {
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
    var ait = e.aliases.valueIterator();
    while (ait.next()) |a| markManaged(v, a.env);
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
    const flags = o.backing_flags;

    if (flags.slots) {
        o.slots.deinit(a);
        o.slots = .empty;
        released += 1;
    }
    if (flags.elements) {
        o.elements.deinit(a);
        o.elements = .empty;
        released += 1;
    }
    if (flags.accessors) {
        if (o.accessors) |acc| {
            var it = acc.keyIterator();
            while (it.next()) |key| a.free(key.*);
            acc.deinit(a);
            a.destroy(acc);
            o.accessors = null;
        }
        released += 1;
    }
    // `private_brands` reuses the "accessors" backing (see Object.addPrivateBrand)
    // but is a separate map pointer the finalizer must also release, or a GC-
    // collected branded object leaks its table + struct. Its keys are borrowed
    // private-name slices (put without copying), so unlike attrs/accessors we do
    // not free the keys.
    if (o.private_brands) |pb| {
        pb.deinit(a);
        a.destroy(pb);
        o.private_brands = null;
        released += 1;
    }
    if (flags.key_order) {
        if (o.key_order) |ord| {
            for (ord.items) |key| a.free(key);
            ord.deinit(a);
            a.destroy(ord);
            o.key_order = null;
        }
        released += 1;
    }
    if (flags.attrs) {
        if (o.attrs) |attrs| {
            var it = attrs.keyIterator();
            while (it.next()) |key| a.free(key.*);
            attrs.deinit(a);
            a.destroy(attrs);
            o.attrs = null;
        }
        released += 1;
    }
    if (flags.holes) {
        if (o.holes) |holes| {
            holes.deinit(a);
            a.destroy(holes);
            o.holes = null;
        }
        released += 1;
    }
    if (flags.weak_entries) {
        o.weak_entries.deinit(a);
        o.weak_entries = .empty;
        released += 1;
    }
    if (flags.finalization_records) {
        o.finalization_records.deinit(a);
        o.finalization_records = .empty;
        released += 1;
    }
    if (flags.typed_array) {
        if (o.typed_array) |ta| {
            a.destroy(ta);
            o.typed_array = null;
        }
        released += 1;
    }
    if (flags.data_view) {
        if (o.data_view) |dv| {
            a.destroy(dv);
            o.data_view = null;
        }
        released += 1;
    }
    if (flags.temporal) {
        if (o.temporal) |t| {
            a.destroy(t);
            o.temporal = null;
        }
        released += 1;
    }
    if (flags.arg_map_names) {
        a.free(o.arg_map_names);
        o.arg_map_names = &.{};
        released += 1;
    }

    o.backing_flags = .{};
    o.backing_allocator = null;
    return released;
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
    p.lockState();
    defer p.unlockState();
    markValue(v, p.value);
    for (p.on_fulfill.items) |r| traceReaction(r, v);
    for (p.on_reject.items) |r| traceReaction(r, v);
}

inline fn traceReaction(r: promise.Reaction, v: anytype) void {
    markValueOpt(v, r.handler);
    markValue(v, r.resolve);
    markValue(v, r.reject);
}

inline fn traceMicrotask(mt: promise.Microtask, v: anytype) void {
    traceReaction(mt.reaction, v);
    markValue(v, mt.argument);
    markValue(v, mt.thenable);
    markValue(v, mt.then_fn);
    if (mt.promise) |p| markManaged(v, p);
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
    }
    if (machine.microtasks) |q| {
        for (q.items) |mt| traceMicrotask(mt, v);
    }
    if (machine.current_microtask) |mt| traceMicrotask(mt, v);
    if (machine.async_waiters) |waiters| {
        for (waiters.items) |aw| markValue(v, aw.promise);
    }
    if (machine.finalization_cleanup_jobs) |jobs| {
        for (jobs.items) |registry| v.mark(registry);
    }
    if (machine.tdz_marker) |o| v.mark(o);
    if (machine.global_object) |o| v.mark(o);
    var sym_it = machine.symbols.valueIterator();
    while (sym_it.next()) |sym| v.mark(sym.*);
    if (machine.import_meta_obj) |o| v.mark(o);
    markValue(v, machine.ret_value);
    markValue(v, machine.this_value);
    markValue(v, machine.exception);
    markValue(v, machine.new_target);
    if (machine.active_native) |o| v.mark(o);
    if (machine.home_object) |o| v.mark(o);
    if (machine.super_ctor) |o| v.mark(o);
    for (machine.with_stack.items) |o| v.mark(o);
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
            if (par == null) if (ctx.gil) |g| {
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
        traceEnv(&ctx.env, v); // the global environment is embedded by value (binding_lock)

        if (par != null) ctx.lockMicrotasks();
        for (ctx.microtasks.items) |mt| traceMicrotask(mt, v);
        if (par != null) ctx.unlockMicrotasks();

        // `async_waiters` + `c_api_handles` + `finalization_cleanup_jobs` share
        // `realm_lock` (taken by their mutators only under parallel_js).
        ctx.realmLock();
        for (ctx.async_waiters.items) |aw| markValue(v, aw.promise);
        for (ctx.finalization_cleanup_jobs.items) |registry| v.mark(registry);
        for (ctx.c_api_handles.items) |h| {
            // each ref is a `*Boxed` ({ value: Value }), so the pointer aliases `*Value`.
            const vp: *const Value = @ptrCast(@alignCast(h.ref));
            markValue(v, vp.*);
        }
        ctx.realmUnlock();

        if (par != null) if (ctx.gil) |g| g.lockApi();
        for (ctx.js_threads.items) |rec| {
            const io = agent.engineIo();
            rec.join_mutex.lockUncancelable(io);
            defer rec.join_mutex.unlock(io);
            markValue(v, rec.result);
            if (rec.js_obj) |o| v.mark(o);
            for (rec.pending_joins.items) |pending| v.mark(pending.promise);
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
                if (machine != collector and !machine.gc_parked.load(.acquire)) continue;
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
        if (ctx.mod_cache) |cache| traceModuleGraph(cache, v);
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
                // The heap running this collection is the Context's own (afterWeak
                // only fires mid-collect), and marks are still valid (pre-sweep).
                const heap = self.context.gc orelse return;
                if (pruneDeadWeakEntries(o, heap)) self.context.queueFinalizationRegistryCleanup(o);
            },
            else => {},
        }
    }

    /// A cell is being reclaimed. Arena-mode `ArrayBufferData` is released with
    /// the arena, but GC-mode buffers own their metadata and non-shared byte
    /// slabs individually. A SharedArrayBuffer wrapper owns one realm retain
    /// that must be released when the wrapper cell dies.
    pub fn finalize(self: *Binding, cell: *anyopaque, kind: Kind) void {
        switch (kind) {
            .object => {
                const o: *Object = @ptrCast(@alignCast(cell));
                const released = finalizeObjectBacking(o, o.backing_allocator orelse self.context.gpa);
                if (released > 0) {
                    _ = @atomicRmw(usize, &self.context.gc_object_backing_stores_live, .Sub, released, .monotonic);
                }
                if (o.array_buffer) |ab| {
                    if (ab.shared) |storage| {
                        const sab_released = self.context.sab_retains.releaseTracked(storage);
                        std.debug.assert(sab_released);
                        if (sab_released) ab.shared = null;
                    } else if (ab.gc_owned and ab.local_data.len > 0) {
                        self.context.gpa.rawFree(ab.local_data, .@"8", @returnAddress());
                        _ = @atomicRmw(usize, &self.context.gc_array_buffer_bytes_live, .Sub, ab.local_data.len, .monotonic);
                        ab.local_data = &.{};
                    }
                    if (ab.gc_owned) {
                        self.context.gpa.destroy(ab);
                        o.array_buffer = null;
                    }
                }
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
                    const count = p.on_fulfill.items.len + p.on_reject.items.len;
                    p.on_fulfill.deinit(self.context.gpa);
                    p.on_reject.deinit(self.context.gpa);
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
    if (h) |raw| {
        const heap: *Heap = @ptrCast(@alignCast(raw));
        _ = gc_runtime.setActive(.{ .object_backing = .{
            .allocator = heap.backing,
            .stores_live = &heap.ctx.context.gc_object_backing_stores_live,
        } });
        _ = gc_runtime.setBarrier(raw, barrierThunk);
    } else {
        _ = gc_runtime.setActive(.{});
        _ = gc_runtime.setBarrier(null, null);
    }
    return prev;
}

/// Type-erased entry the `gc_runtime` shim calls at reference-store sites; the
/// `Heap.writeBarrier` it forwards to is a no-op unless an incremental mark is
/// in progress (M2). See `gc_runtime.barrier`.
fn barrierThunk(raw_heap: *anyopaque, cell: ?*anyopaque) void {
    const heap: *Heap = @ptrCast(@alignCast(raw_heap));
    heap.writeBarrier(cell);
}

/// Insertion write barrier for a stored `Value` (only `.object` carries a cell).
/// Call at every post-creation store of a reference into a live GC cell. A
/// near-no-op outside incremental marking; see docs/threads/P7-gc-design.md.
pub inline fn barrierValue(v: Value) void {
    if (v.isObject()) gc_runtime.barrier(@ptrCast(v.asObj()));
}

/// Insertion write barrier for a stored cell pointer (Object/Environment/…).
pub inline fn barrierCell(cell: ?*anyopaque) void {
    gc_runtime.barrier(cell);
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

    try root.slots.append(a, Value.obj(child));
    child.proto = gp;
    try gp.slots.append(a, Value.obj(root)); // cycle back to the root
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
