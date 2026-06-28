const std = @import("std");
const io_compat = @import("io_compat.zig");
const gc_mod = @import("gc.zig");
const builtin = @import("builtin");
const interp = @import("interpreter.zig");
const ast = @import("ast.zig");
const value = @import("value.zig");
const strcell = @import("strcell.zig");
const Value = value.Value;
const compiler = @import("compiler.zig");
const vm = @import("vm.zig");
const builtins = @import("builtins.zig");
const Shape = @import("shape.zig").Shape;
const Parser = @import("parser.zig").Parser;
const shared_buffer = @import("shared_buffer.zig");
const gil_mod = @import("gil.zig");
const jsthread = @import("jsthread.zig");
const stack_scan = @import("stack_scan.zig");
const agent = @import("agent.zig");

pub const RunError = interp.EvalError || @import("parser.zig").ParseError;

/// A mutex-guarded wrapper over the per-context arena allocator. Shapes,
/// interned strings, AST nodes, and Environment binding tables are all
/// arena-allocated, and `std.heap.ArenaAllocator` is not thread-safe — so once
/// the GIL is gone and multiple JS threads allocate at once, the arena's free
/// list would corrupt (issue #1 blocker #1). This serializes every arena
/// alloc/resize/remap/free behind a brief atomic spinlock. Installed only when
/// `enable_threads` (a single-thread context keeps the raw arena, no lock); the
/// GIL still serializes today, so this is uncontended now and the readiness for
/// GIL removal that it provides costs nothing on the single-thread path.
pub const LockedArena = struct {
    inner: std.mem.Allocator,
    lock: std.atomic.Value(u32) = .init(0),

    inline fn acquire(self: *LockedArena) void {
        while (self.lock.cmpxchgWeak(0, 1, .acquire, .monotonic) != null) std.atomic.spinLoopHint();
    }
    inline fn unlock(self: *LockedArena) void {
        self.lock.store(0, .release);
    }

    fn allocFn(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *LockedArena = @ptrCast(@alignCast(ctx));
        self.acquire();
        defer self.unlock();
        return self.inner.vtable.alloc(self.inner.ptr, len, alignment, ret_addr);
    }
    fn resizeFn(ctx: *anyopaque, mem: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *LockedArena = @ptrCast(@alignCast(ctx));
        self.acquire();
        defer self.unlock();
        return self.inner.vtable.resize(self.inner.ptr, mem, alignment, new_len, ret_addr);
    }
    fn remapFn(ctx: *anyopaque, mem: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const self: *LockedArena = @ptrCast(@alignCast(ctx));
        self.acquire();
        defer self.unlock();
        return self.inner.vtable.remap(self.inner.ptr, mem, alignment, new_len, ret_addr);
    }
    fn freeFn(ctx: *anyopaque, mem: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const self: *LockedArena = @ptrCast(@alignCast(ctx));
        self.acquire();
        defer self.unlock();
        self.inner.vtable.free(self.inner.ptr, mem, alignment, ret_addr);
    }

    const vtable: std.mem.Allocator.VTable = .{
        .alloc = allocFn,
        .resize = resizeFn,
        .remap = remapFn,
        .free = freeFn,
    };

    pub fn allocator(self: *LockedArena) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &vtable };
    }
};

/// An isolated engine instance — the homegrown analogue of a JSC
/// Enable (or disable) the process-wide parallel/concurrent synchronization
/// protocols as ONE unit, so they can never drift: Environment binding locks,
/// Object element/backing locks + the `bytes()` seqlock, and the bytecode inline-
/// cache seqlock. They share a single trigger (`concurrent_gc or parallel_gc`)
/// and must always agree — routing every flip through here is the single source
/// of truth (the default engine leaves all three a relaxed-load no-op).
pub fn setParallelSyncEnabled(on: bool) void {
    interp.Environment.binding_locks_enabled.store(on, .release);
    value.Object.element_locks_enabled.store(on, .release);
    @import("bytecode.zig").ic_seqlock_enabled.store(on, .release);
}

/// `JSGlobalContextRef`. Owns an arena for all interpreter-lived allocations
/// (AST, strings, objects, boxed values) and a persistent global environment
/// so variables survive across `evaluate` calls, like a real global context.
pub const Context = struct {
    gpa: std.mem.Allocator,
    arena_state: *std.heap.ArenaAllocator,
    /// Thread-safe wrapper over `arena_state` installed when `enable_threads`
    /// (null otherwise → raw arena). Makes parallel shape/string/AST/binding
    /// allocation safe once the GIL is gone (#1). See `LockedArena`.
    locked_arena: ?*LockedArena = null,
    /// Thread-safe wrapper over `gpa` used as the GC heap's cell backing under
    /// `parallel_gc`, so multiple mutators can allocate cells concurrently. Freed
    /// after `gc.deinit()` in `destroy`. Null unless `parallel_gc`.
    gc_backing_lock: ?*LockedArena = null,
    /// A Context is single-thread-affine: every mutating entry point (evaluate,
    /// evaluateModule, the C API) must run on the thread that created it. The
    /// arena, environments, shapes, and microtask queue are unsynchronized by
    /// design; cross-thread sharing happens only through SharedArrayBuffer
    /// storage (see docs/threads/bindings.md). Debug builds enforce this.
    owner_thread: std.Thread.Id,
    env: interp.Environment,
    global_object: *value.Object,
    /// The empty root shape every object in this context transitions from.
    root_shape: *Shape,
    exception: ?value.Value = null,
    /// The microtask queue (Promise reactions) and the `print` output buffer —
    /// persistent across `evaluate` calls, shared with each `Interpreter`.
    microtasks: std.ArrayListUnmanaged(@import("promise.zig").Microtask) = .empty,
    /// Serializes microtask-queue content mutation (enqueue/dequeue) when the
    /// execution-path GIL is dropped (`parallel_js`). Under the GIL exactly one
    /// thread touches the queue at a time, so the interpreter's `microtask_lock`
    /// pointer stays null and the enqueue/drain paths are a single relaxed null
    /// check. Without it, a thread settling an `asyncJoin` promise enqueues a
    /// reaction into the joiner's queue while the joiner drains it — a data race
    /// that loses the reaction (the Layer-C "microtask queue" blocker).
    microtask_lock: std.atomic.Mutex = .unlocked,
    print_buffer: std.ArrayListUnmanaged(u8) = .empty,
    /// SharedArrayBuffer storage references this realm holds (one per SAB
    /// wrapper created here). Released in `destroy` — shared bytes live in
    /// process-wide refcounted storage, not the arena (see shared_buffer.zig).
    sab_retains: shared_buffer.RetainList,
    /// Outstanding `Atomics.waitAsync` promises (entries live in the arena;
    /// the list's address is the realm's waiter-table owner token). Settled by
    /// the drain tail in `evaluate`/`evaluateModule`.
    async_waiters: std.ArrayListUnmanaged(interp.AsyncWaiterEntry) = .empty,
    /// FinalizationRegistry cleanup jobs made ready by a quiescent GC cycle.
    /// The collector only enqueues registries; callbacks run later from the
    /// normal interpreter checkpoint, outside the collector.
    finalization_cleanup_jobs: std.ArrayListUnmanaged(*value.Object) = .empty,
    /// A JS-visible shell `gc()` call requests collection, but the precise M1
    /// collector is only sound at quiescent points. The request is serviced at
    /// the next evaluate/evaluateModule entry rather than inside live Zig
    /// interpreter recursion.
    gc_requested: bool = false,
    /// Set only for the duration of a guarded mid-script collection so the GC
    /// binding (`gc.zig` `traceRoots`) conservatively scans the collecting
    /// thread's live native stack + spilled registers. Quiescent collection
    /// leaves it false and stays precise (so exact-reclamation tests are
    /// unaffected). See `collectMidScript` and `stack_scan.zig`.
    gc_scan_native_stack: bool = false,
    /// Realm-wide serial for class private-name storage keys. Private names are
    /// per-class brands, so two unrelated classes declaring `#x` must not alias
    /// even if both outlive separate evaluate calls.
    private_name_serial: u64 = 0,
    /// Cooperative termination for worker contexts: the owning Worker's stop
    /// word, polled at the engines' step checkpoints (src/worker.zig).
    stop_flag: ?*const std.atomic.Value(bool) = null,
    /// Internal teardown stop word for shared-realm `Thread`s. `destroy()`
    /// sets this before waiting so unjoined parked/running threads unwind
    /// instead of keeping context teardown blocked forever after an abrupt
    /// main-thread completion.
    teardown_stop: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    /// Host policy for whether this shared VM may block in synchronous waits.
    /// Used by PR-249 and test262 `[[CanBlock]]` coverage.
    main_can_block: bool = true,
    /// Test-only Layer-C bring-up: run shared-realm `Thread` JS without holding
    /// the context GIL. This is deliberately excluded from public Options.
    parallel_js: bool = false,
    /// Optional cap on live shared-realm `Thread`s. Null means only the
    /// intrinsic id-space limit applies.
    max_js_threads: ?u32 = null,
    /// Phase 6: the VM lock for shared-Context `Thread` objects (heap-
    /// allocated so its address is stable; null = the context stays
    /// single-thread-affine and pays nothing).
    gil: ?*gil_mod.Gil = null,
    /// Phase 7: the precise tracing GC heap (null = arena engine, today's
    /// default). When set, heap cells allocate through it and are reclaimed by
    /// collection / freed at `destroy`. See docs/threads/P7-gc-design.md.
    gc: ?*GcHeap = null,
    /// Internal verification/accounting for GC-owned non-shared ArrayBuffer
    /// byte slabs. This is not an embedder API; it lets tests prove collection
    /// frees backing storage before context teardown.
    gc_array_buffer_bytes_live: usize = 0,
    /// Internal verification/accounting for GC-owned Promise reaction entries.
    /// Not an embedder API; tests use it to prove settlement/finalization frees
    /// reaction-list backing before teardown.
    gc_promise_reactions_live: usize = 0,
    /// Internal verification/accounting for GC-owned Environment binding-name
    /// strings. Not an embedder API; tests use it to prove environment
    /// finalization releases duplicated binding names before teardown.
    gc_environment_name_bytes_live: usize = 0,
    /// Internal verification/accounting for GC-owned Object backing stores
    /// (named property slots, accessors, key order, attrs, holes). Not an
    /// embedder API; tests use it to prove object finalization reclaims
    /// side-storage before teardown.
    gc_object_backing_stores_live: usize = 0,
    /// Internal verification/accounting for GC-owned Generator execution
    /// buffers. Not an embedder API; tests use it to prove generator
    /// finalization reclaims stack/handler/request buffers before teardown.
    gc_generator_backing_stores_live: usize = 0,
    /// The heap's root-tracing binding (wraps this Context); freed in `destroy`.
    gc_binding: ?*GcBinding = null,
    /// Phase 7 / M3: drive `collectMidScript` as a *concurrent* mark (a dedicated
    /// marker thread runs while the mutator continues between safepoints).
    /// Opt-in, single-mutator. `gc_marker` is the per-cycle marker thread; joined
    /// at the finish safepoint. `gc_marker_stop` tells it to stop and return.
    gc_concurrent: bool = false,
    gc_marker: ?std.Thread = null,
    gc_marker_stop: std.atomic.Value(bool) = .init(false),
    /// Phase 7 / M3: mid-script collection under *parallel* mutators (no GIL).
    /// Opt-in (`parallel_midscript_gc`, requires `parallel_js`). The driver is
    /// abort-safe: it sweeps only on confirmed root-handshake stability and
    /// otherwise clears marking without freeing anything, so it can never
    /// deadlock (no mutator blocks for it) or use-after-free (no sweep without
    /// convergence). See `driveParallelCollection` and docs/threads/P7-gil-removal.md.
    gc_par_enabled: bool = false,
    /// Single-collector election: the first interpreter to CAS this from null to
    /// its own pointer at a safepoint drives the cycle; the others publish their
    /// roots and resume. Doubles as "a parallel collection is in progress" and as
    /// the one interpreter `traceRoots` may read directly (the collector is at
    /// its own safepoint; peers self-publish via the barrier).
    gc_par_collector: std.atomic.Value(?*interp.Interpreter) = .init(null),
    /// Root-publication generation the collector currently wants (0 = none). A
    /// peer at a safepoint (or about to park) whose `gc_published_gen` is behind
    /// this publishes its precise roots through the insertion barrier and catches
    /// up. Bumped once per begin/finish root scan.
    gc_par_request: std.atomic.Value(u64) = .init(0),
    /// Count of mid-script parallel collections that reached a *finishing* sweep
    /// (not aborted). Tests assert this is non-zero to prove the collector
    /// actually reclaimed while peers ran, rather than always falling back to
    /// quiescent collection.
    gc_par_collections: std.atomic.Value(u64) = .init(0),
    /// Guards the low-frequency realm-root lists that have no other lock —
    /// `async_waiters`, `c_api_handles`, `finalization_cleanup_jobs` — so the
    /// mid-script parallel collector can read them while peers mutate. Taken by
    /// both the writers and the collector **only under `parallel_js`** (a null
    /// `realm_lock_p` in GIL mode keeps those paths byte-identical). A brief mutex.
    realm_lock: std.atomic.Mutex = .unlocked,
    /// C-API `Boxed` handles (`JSValueRef`s) protected by the embedder.
    /// `JSValueProtect` registers a wrapper here when the GC is on (`*Boxed`
    /// aliases `*Value`, its first field); `gc.zig`'s `traceRoots` marks them
    /// until matching `JSValueUnprotect` calls remove the entry.
    c_api_handles: std.ArrayListUnmanaged(CApiHandle) = .empty,
    /// `Thread` records spawned in this realm (the records live in the
    /// arena; the list is gpa-backed). `destroy` waits for all of them.
    js_threads: std.ArrayListUnmanaged(*jsthread.ThreadRecord) = .empty,
    /// Interpreters currently executing or draining host checkpoints in this
    /// realm. GC-mode collections trace these explicit execution roots at
    /// quiescent checkpoints; arbitrary native/Zig stack scanning is still a
    /// separate Layer-C requirement.
    active_interpreters: std.ArrayListUnmanaged(*interp.Interpreter) = .empty,
    /// Serializes `active_interpreters` push/pop + the GC's iteration of it, so
    /// parallel mutators registering/unregistering interpreters don't race each
    /// other or a collector. Uncontended under the GIL; needed once threads run
    /// JS without it. A brief atomic spinlock.
    active_interp_lock: std.atomic.Value(u32) = .init(0),
    /// TDZ sentinel for uninitialized let/const bindings.
    tdz_marker: *value.Object,
    /// Test262 host module source for `import source x from "<module source>"`.
    module_source_object: ?*value.Object = null,
    /// Active module graph state during `evaluateModule`, so runtime `import()`
    /// (dynamic import) can resolve+load+evaluate further modules on demand.
    mod_host: ?ModuleHost = null,
    mod_cache: ?*std.StringHashMapUnmanaged(*Module) = null,
    /// Referrer path for runtime `import()` issued from top-level *script* code
    /// (a `flags:[module]`-free test). When `mod_host` is set, `evaluate` wires
    /// the dynamic-import hook using this as the importing script's path, so
    /// `import('./x.js')` resolves relative to the script's directory.
    script_referrer: []const u8 = "",

    pub const Options = struct {
        /// Install the `Thread` API and the GIL: spawned threads share this
        /// Context's realm, serialized by one VM lock (issue #1 Phase 6,
        /// docs/threads/P6-thread-api.md).
        enable_threads: bool = false,
        /// Allocate heap cells through the precise tracing GC instead of the
        /// arena (issue #1 Phase 7, docs/threads/P7-gc-design.md). M1 work in
        /// progress: OFF is today's arena engine (byte-identical); ON routes
        /// cell allocation through `Context.gc` and frees them at teardown via
        /// the collector. Mid-run collection is gated separately until the
        /// whole allocation surface is migrated.
        enable_gc: bool = false,
        /// Phase 7 / M3 (opt-in, requires `enable_gc`): mark on a dedicated
        /// thread *concurrently* with the mutator at safepoints. Single-mutator
        /// only (no `enable_threads`); default off. See docs/threads/P7-gc-design.md.
        concurrent_gc: bool = false,
        /// Serialize spawned `Thread`s behind the per-context GIL instead of the
        /// DEFAULT true-parallel execution (issue #1 Layer C). Only meaningful with
        /// `enable_threads`. Default off → threads run concurrently (no GIL), which
        /// implies the GC-managed, thread-safe cell path; its correctness is gated
        /// by the whole-corpus no-GIL ThreadSanitizer CI (zero engine-state races)
        /// plus the serial-perf gate (see P7-gil-removal.md). Set this for the old
        /// GIL-serialized semantics (e.g. strict determinism, or to keep a
        /// thread-using context on the arena allocator). A context with no
        /// `enable_threads` is single-threaded either way and pays nothing.
        gil: bool = false,
    };

    /// Test/conformance-only creation knobs. These model harness flags such as
    /// `[[CanBlock]]` and the PR-249 max thread count without making them part
    /// of the stable embedder options surface.
    pub const TestingOptions = struct {
        enable_threads: bool = false,
        enable_gc: bool = false,
        concurrent_gc: bool = false,
        /// Experimental (GIL-removal bring-up, requires `enable_gc`): make GC cell
        /// allocation thread-safe so multiple mutators can `create` concurrently —
        /// the heap's cell backing is wrapped in a thread-safe lock and
        /// `Heap.setParallel(true)` serializes its bookkeeping. Validates the
        /// parallel-allocation/mutation path ahead of the GIL actually dropping.
        parallel_gc: bool = false,
        /// Host-defined `[[CanBlock]]` for this VM. When false, blocking APIs
        /// throw if they would have to park; non-blocking fast paths and async
        /// APIs still work.
        main_can_block: bool = true,
        /// Test cap for live shared-realm `Thread` objects.
        max_js_threads: ?u32 = null,
        /// Experimental GIL-removal vertical slice (test-only): requires
        /// `enable_threads`, `enable_gc`, and `parallel_gc`. JS execution does
        /// not hold the context GIL; legacy blocking/result bookkeeping still
        /// takes it briefly.
        parallel_js: bool = false,
        /// Experimental (requires `parallel_js`): enable the abort-safe mid-script
        /// parallel collector so a long-running parallel workload can reclaim
        /// garbage at safepoints without a quiescent point. Off by default —
        /// quiescent collection already covers correctness; this is a pause-time
        /// optimization under test.
        parallel_midscript_gc: bool = false,
    };

    /// The engine's precise-GC heap type and its root-tracing binding (issue #1
    /// Phase 7). Held by pointer so addresses are stable; `null` costs nothing
    /// when the GC is off.
    pub const GcHeap = @import("gc.zig").Heap;
    pub const GcBinding = @import("gc.zig").Binding;
    pub const CApiHandle = struct {
        ref: *anyopaque,
        count: usize,
    };

    pub fn create(gpa: std.mem.Allocator) !*Context {
        return createWith(gpa, .{});
    }

    pub fn createWith(gpa: std.mem.Allocator, options: Options) !*Context {
        // Threads run TRUE-parallel (no GIL) by default; `gil` opts back into the
        // serialized path. Parallel execution implies GC-managed, thread-safe cells
        // (enable_gc + parallel_gc). A non-threaded context is single-threaded
        // either way, so it stays on whatever allocator it asked for and pays none
        // of the parallel sync cost.
        const want_parallel = options.enable_threads and !options.gil;
        return createWithTestingOptions(gpa, .{
            .enable_threads = options.enable_threads,
            .enable_gc = options.enable_gc or want_parallel,
            .concurrent_gc = options.concurrent_gc,
            .parallel_gc = want_parallel,
            .parallel_js = want_parallel,
        });
    }

    pub fn createWithTestingOptions(gpa: std.mem.Allocator, options: TestingOptions) !*Context {
        // Validate option dependencies before allocating anything, so the error
        // path leaks nothing.
        if (options.parallel_js and !(options.enable_threads and options.enable_gc and options.parallel_gc))
            return error.InvalidThreadTestingOptions;
        if (options.parallel_midscript_gc and !options.parallel_js)
            return error.InvalidThreadTestingOptions;
        const arena_state = try gpa.create(std.heap.ArenaAllocator);
        arena_state.* = std.heap.ArenaAllocator.init(gpa);
        errdefer {
            arena_state.deinit();
            gpa.destroy(arena_state);
        }
        // When threads (or the parallel-GC bring-up) are enabled, every
        // arena-allocated structure — shapes, strings, AST, binding tables —
        // must allocate through a thread-safe wrapper, because the raw
        // `ArenaAllocator` corrupts under parallel allocation (#1). Crucially the
        // wrapper must be installed *before* `a` is captured here: `root_shape`,
        // the global `env`, and every later create-time alloc bind this `a`, and
        // `Shape.transition` reuses the root shape's captured allocator — so a
        // wrapper installed later would leave shape transitions on the raw arena.
        var locked_arena: ?*LockedArena = null;
        const a = if (options.enable_threads or options.parallel_gc) blk: {
            const la = try gpa.create(LockedArena);
            la.* = .{ .inner = arena_state.allocator() };
            locked_arena = la;
            break :blk la.allocator();
        } else arena_state.allocator();

        const self = try gpa.create(Context);
        self.* = .{
            .gpa = gpa,
            .arena_state = arena_state,
            .locked_arena = locked_arena,
            .owner_thread = std.Thread.getCurrentId(),
            .sab_retains = .{ .gpa = gpa },
            .env = .{ .arena = a, .fn_scope = true }, // global is a variable scope
            .global_object = undefined, // set below, once the heap exists
            .root_shape = try Shape.createRoot(a),
            .tdz_marker = undefined, // set below
            .main_can_block = options.main_can_block,
            .max_js_threads = options.max_js_threads,
            .parallel_js = options.parallel_js,
        };
        self.gc_par_enabled = options.parallel_midscript_gc;
        if (options.enable_gc) {
            // GC cells are gpa-backed (the collector frees them individually);
            // the binding wraps this Context, whose roots it traces.
            const bind = try gpa.create(GcBinding);
            bind.* = .{ .context = self };
            const h = try gpa.create(GcHeap);
            // Under parallel_gc the cell backing must be thread-safe (multiple
            // mutators allocate at once): wrap gpa in a lock and route every cell
            // slab alloc/free through it, consistently for the heap's lifetime.
            var cell_backing = gpa;
            if (options.parallel_gc) {
                const bl = try gpa.create(LockedArena);
                bl.* = .{ .inner = gpa };
                self.gc_backing_lock = bl;
                cell_backing = bl.allocator();
            }
            h.* = GcHeap.init(cell_backing, bind);
            if (options.parallel_gc) h.setParallel(true);
            // GC scratch (`mark_stack`/`barrier_buf`) is touched by both a
            // concurrent marker thread and the mutator under M3, so it must use
            // a thread-safe allocator distinct from the (mutator-only) cell
            // backing. The page allocator is process-global and thread-safe; for
            // M1/M2 this only changes where the pointer stacks live, not
            // behavior. Set before any allocation so deinit frees with the same
            // allocator. See zig-gc `Heap.setAuxAllocator`.
            h.setAuxAllocator(std.heap.page_allocator);
            self.gc = h;
            self.gc_binding = bind;
            // Single-mutator only for now: concurrent marking + no peer mutators.
            self.gc_concurrent = options.concurrent_gc and !options.enable_threads;
            // Turn on the parallel/concurrent synchronization protocols process-
            // wide as one unit, so they can never drift: needed only when the
            // marker runs concurrently (concurrent_gc) or mutators run in parallel
            // (parallel_gc). The default engine leaves them no-ops (relaxed loads).
            if (options.concurrent_gc or options.parallel_gc) setParallelSyncEnabled(true);
        }
        // Route all cell allocation (the global object + TDZ sentinel,
        // installGlobals, and the mirror loop below) through the GC when
        // enabled; restore on return so a nested createWith on this thread is
        // unaffected. Creating the heap first means even these roots are GC
        // cells (required once mid-run collection marks from them).
        const gc_saved = gc_mod.setActiveHeap(self.gc);
        defer _ = gc_mod.setActiveHeap(gc_saved);
        const sa_saved = strcell.setActiveArena(self.arena());
        defer _ = strcell.setActiveArena(sa_saved);

        const global_obj = try gc_mod.allocObj(a);
        global_obj.* = .{};
        self.global_object = global_obj;
        // A unique sentinel object marking a `let`/`const` binding in its
        // temporal dead zone (declared but not yet initialized).
        const tdz = try gc_mod.allocObj(a);
        tdz.* = .{};
        self.tdz_marker = tdz;

        try interp.installGlobals(&self.env, self.root_shape);
        // `globalThis` names the global object itself.
        try self.env.put("globalThis", Value.obj(global_obj));
        if (self.env.get("Object")) |object_ctor| {
            if (object_ctor.isObject()) {
                if (object_ctor.asObj().getOwn("prototype")) |object_proto| {
                    if (object_proto.isObject()) global_obj.proto = object_proto.asObj();
                }
            }
        }
        // Mirror the installed globals onto the global object as real own
        // properties (with spec attributes), so `Object.getOwnPropertyDescriptor
        // (globalThis, "Math")`, `Object.keys`, `hasOwnProperty`, etc. see them.
        // `undefined`/`NaN`/`Infinity` are non-writable/-enumerable/-configurable;
        // the rest are writable, non-enumerable, configurable.
        var it = self.env.vars.iterator();
        while (it.next()) |e| {
            const name = e.key_ptr.*;
            try global_obj.setOwn(a, self.root_shape, name, e.value_ptr.*);
            const frozen = std.mem.eql(u8, name, "undefined") or
                std.mem.eql(u8, name, "NaN") or std.mem.eql(u8, name, "Infinity");
            try global_obj.setAttr(a, name, if (frozen)
                .{ .writable = false, .enumerable = false, .configurable = false }
            else
                .{ .writable = true, .enumerable = false, .configurable = true });
        }
        // `$262.global` is this realm's global object.
        if (self.env.get("$262")) |d| {
            if (d.isObject()) try d.asObj().setOwn(a, self.root_shape, "global", Value.obj(global_obj));
        }
        if (options.enable_threads) {
            // `locked_arena` (the thread-safe arena, #1) was installed before any
            // create-time allocation above, so shapes/env/etc. already use it.
            const g = try gpa.create(gil_mod.Gil);
            g.* = .{};
            g.park_alloc = gpa;
            self.gil = g;
            g.acquire();
            defer g.release();
            // Register the main thread's park record (this thread). A spawned
            // thread that becomes the collector roots the main thread's parked
            // stack through it (e.g. while main waits in the keepalive loop).
            g.registerPark(stack_scan.parkRecord());
            try jsthread.installThreadAPI(self);
        }
        return self;
    }

    /// An interpreter bound to this context's arena, globals, and shape tree.
    /// Top-level `this` is the global object (so `this`/`globalThis` are real
    /// objects and reflection over the global works).
    pub fn interpreter(self: *Context) interp.Interpreter {
        return .{
            .arena = self.arena(),
            .env = &self.env,
            .global_object = self.global_object,
            .this_value = Value.obj(self.global_object),
            .root_shape = self.root_shape,
            .microtasks = &self.microtasks,
            // Only engage the microtask lock when the execution-path GIL is
            // dropped; the default GIL-serialized engine leaves it null (no
            // overhead). Every interpreter (main + each spawned `Thread`, which
            // also come from `interpreter()`) thus shares one lock for the
            // realm's queue.
            .microtask_lock = if (self.parallel_js) &self.microtask_lock else null,
            .print_buffer = &self.print_buffer,
            .tdz_marker = self.tdz_marker,
            .sab_retains = &self.sab_retains,
            .async_waiters = &self.async_waiters,
            .finalization_cleanup_jobs = &self.finalization_cleanup_jobs,
            .stop_flag = self.stop_flag orelse &self.teardown_stop,
            .main_can_block = self.main_can_block,
            .use_thread_gil = self.gil != null and !self.parallel_js,
            .gil = self.gil,
            .gc = self.gc,
            .gc_backing = if (self.gc) |h| h.backing else null,
            .gc_array_buffer_bytes_live = if (self.gc != null) &self.gc_array_buffer_bytes_live else null,
            .gc_promise_reactions_live = if (self.gc != null) &self.gc_promise_reactions_live else null,
            .gc_environment_name_bytes_live = if (self.gc != null) &self.gc_environment_name_bytes_live else null,
            .gc_requested = &self.gc_requested,
            .gc_checkpoint_ctx = self,
            .gc_checkpoint_fn = serviceRequestedGcCheckpoint,
            // Mid-script collection hook: wired only when the GC is on, so the
            // arena engine pays nothing (the VM/tree-walker skip on a null fn).
            .gc_safepoint_ctx = if (self.gc != null) self else null,
            .gc_safepoint_fn = if (self.gc != null) collectMidScript else null,
            .private_name_serial = &self.private_name_serial,
        };
    }

    pub fn destroy(self: *Context) void {
        if (self.gil) |g| {
            self.teardown_stop.store(true, .release);
            // Spawned threads need the lock to finish: park until each is
            // done, then OS-join the handles.
            if (self.parallel_js) {
                const io = agent.engineIo();
                for (self.js_threads.items) |rec| {
                    rec.join_mutex.lockUncancelable(io);
                    while (!rec.exited) rec.done_cond.wait(io, &rec.join_mutex) catch {};
                    rec.join_mutex.unlock(io);
                }
            } else {
                g.acquire();
                for (self.js_threads.items) |rec| {
                    while (!rec.done) g.wait(&rec.done_cond);
                }
                g.release();
            }
            for (self.js_threads.items) |rec| {
                if (rec.thread) |t| t.join();
            }
            jsthread.abandonPropAsync(g);
            g.unregisterPark(stack_scan.parkRecord());
            g.park_records.deinit(self.gpa);
            self.gpa.destroy(g);
            self.gil = null;
        } else {
            self.assertOwnerThread();
        }
        self.js_threads.deinit(self.gpa);
        self.active_interpreters.deinit(self.gpa);
        self.finalization_cleanup_jobs.deinit(self.gpa);
        self.c_api_handles.deinit(self.gpa);
        // Reclaim every GC cell (running finalizers) before the arena and the
        // Context itself go away — GC cells are gpa-backed and disjoint from the
        // arena. Keep `sab_retains` alive until after finalizers run: live
        // SharedArrayBuffer wrapper cells release their tracked storage refs
        // there when GC is enabled.
        self.finishConcurrentGCIfActive(); // join any marker before heap teardown
        if (self.gc) |h| {
            h.deinit(); // frees cells via heap.backing (the gc_backing_lock wrapper under parallel_gc)
            self.gpa.destroy(h);
            self.gc = null;
        }
        if (self.gc_backing_lock) |bl| {
            self.gpa.destroy(bl); // safe now: heap.deinit() is done using it
            self.gc_backing_lock = null;
        }
        if (self.gc_binding) |b| {
            self.gpa.destroy(b);
            self.gc_binding = null;
        }
        if (self.locked_arena) |la| {
            self.gpa.destroy(la);
            self.locked_arena = null;
        }
        self.sab_retains.deinit();
        self.arena_state.deinit();
        self.gpa.destroy(self.arena_state);
        self.gpa.destroy(self);
    }

    /// Whether the calling thread is the one that created this context.
    pub fn isOwnerThread(self: *const Context) bool {
        return std.Thread.getCurrentId() == self.owner_thread;
    }

    /// Debug-only affinity check: panics with a clear message when a Context
    /// is touched from the wrong thread. For an `enable_threads` context the
    /// invariant is GIL ownership (any thread, exactly one at a time);
    /// otherwise it is creator-thread affinity. Compiles to nothing in
    /// release modes, so the single-threaded hot path pays zero cost.
    pub fn assertOwnerThread(self: *const Context) void {
        if (comptime builtin.mode == .Debug) {
            if (self.gil) |g| {
                if (self.parallel_js) return;
                if (!g.holds()) std.debug.panic(
                    "Context (enable_threads) used without holding the GIL (docs/threads/P6-thread-api.md)",
                    .{},
                );
            } else if (!self.isOwnerThread()) std.debug.panic(
                "Context is single-thread-affine: used from thread {d}, owned by thread {d} (docs/threads/bindings.md)",
                .{ std.Thread.getCurrentId(), self.owner_thread },
            );
        }
    }

    pub fn arena(self: *Context) std.mem.Allocator {
        if (self.locked_arena) |la| return la.allocator();
        return self.arena_state.allocator();
    }

    fn serviceRequestedGcCheckpoint(ctx: *anyopaque) void {
        const self: *Context = @ptrCast(@alignCast(ctx));
        self.collectRequestedGarbage();
    }

    fn hasRunningJsThreads(self: *const Context) bool {
        const io = agent.engineIo();
        for (self.js_threads.items) |rec| {
            rec.join_mutex.lockUncancelable(io);
            const exited = rec.exited;
            rec.join_mutex.unlock(io);
            if (!exited) return true;
        }
        return false;
    }

    pub fn lockActiveInterpreters(self: *Context) void {
        while (self.active_interp_lock.cmpxchgWeak(0, 1, .acquire, .monotonic) != null) std.atomic.spinLoopHint();
    }
    pub fn unlockActiveInterpreters(self: *Context) void {
        self.active_interp_lock.store(0, .release);
    }

    /// Lock `realm_lock` only under `parallel_js` (a no-op in GIL mode, so those
    /// realm-list mutations stay byte-identical there). Guards `async_waiters`,
    /// `c_api_handles`, and `finalization_cleanup_jobs` against the mid-script
    /// parallel collector's reads.
    fn spinLockMutex(m: *std.atomic.Mutex) void {
        var spins: usize = 0;
        while (!m.tryLock()) : (spins += 1) {
            if ((spins & 0xff) == 0) std.Thread.yield() catch {} else std.atomic.spinLoopHint();
        }
    }
    pub fn realmLock(self: *Context) void {
        if (self.parallel_js) spinLockMutex(&self.realm_lock);
    }
    pub fn realmUnlock(self: *Context) void {
        if (self.parallel_js) self.realm_lock.unlock();
    }

    /// Lock the realm microtask queue (`microtasks`). Peers take this via the
    /// interpreter's `microtask_lock` pointer under parallel_js; the collector
    /// takes it directly while tracing the queue.
    pub fn lockMicrotasks(self: *Context) void {
        spinLockMutex(&self.microtask_lock);
    }
    pub fn unlockMicrotasks(self: *Context) void {
        self.microtask_lock.unlock();
    }

    pub fn pushActiveInterpreter(self: *Context, machine: *interp.Interpreter) !void {
        self.lockActiveInterpreters();
        defer self.unlockActiveInterpreters();
        try self.active_interpreters.append(self.gpa, machine);
    }

    pub fn popActiveInterpreter(self: *Context, machine: *interp.Interpreter) void {
        self.lockActiveInterpreters();
        defer self.unlockActiveInterpreters();
        var i: usize = self.active_interpreters.items.len;
        while (i > 0) {
            i -= 1;
            if (self.active_interpreters.items[i] == machine) {
                _ = self.active_interpreters.orderedRemove(i);
                return;
            }
        }
    }

    /// Run a precise mark-sweep over the GC heap (Phase 7). Single-threaded, this
    /// is precise: persistent Context roots plus registered active Interpreter
    /// state. With spawned threads it is sound only when this thread holds the
    /// GIL and every peer is parked-and-published, in which case it additionally
    /// conservatively roots this thread's and every parked peer's native stack
    /// (the multi-thread safepoint protocol, `stack_scan.zig`); otherwise it
    /// skips, because a peer may hold an unscanned native-stack root. No-op when
    /// the GC is off.
    pub fn collectGarbage(self: *Context) void {
        const h = self.gc orelse return;
        self.finishConcurrentGCIfActive(); // close any in-flight concurrent mark first
        if (self.hasRunningJsThreads()) {
            return;
        }
        h.collect();
        self.gc_requested = false;
    }

    fn collectRequestedGarbage(self: *Context) void {
        if (!self.gc_requested) return;
        self.collectGarbage();
    }

    /// Heap-growth-triggered collection at an engine step checkpoint, while the
    /// native stack holds live `Value`s. Sound because the GC binding adds two
    /// extra root sources: registered active VM `Exec` operand stacks (precise,
    /// for every active interpreter including parked threads') and a conservative
    /// scan of native stacks + spilled registers (`stack_scan.zig`) — the
    /// collecting thread's own, plus every *parked* peer thread's published
    /// range. No-op unless the GC is on and the conservative scan is available.
    ///
    /// With threads, collection only proceeds when every other registered thread
    /// is parked-and-published (`allOthersParked`); otherwise some peer released
    /// the GIL without publishing a scan range (or is mid startup), so we abort
    /// rather than risk missing a live native-stack root. The collector holds
    /// the GIL throughout, so parked peers cannot run and their stacks stay
    /// frozen during the scan.
    /// Per-`markStep` cell budget for incremental marking (M2): bounds the pause
    /// per safepoint while still draining faster than the mutator allocates
    /// between safepoints, so a cycle converges in a few steps.
    const mark_budget: usize = 4096;

    /// Marker-thread body for concurrent marking (M3): drain grey work + fold in
    /// the mutator's barrier hand-off until the mutator sets `gc_marker_stop`.
    /// Never scans the native stack, never traces a cell born this cycle (those
    /// are deferred to finish), and allocates only on the thread-safe `aux`.
    fn gcMarkerLoop(self: *Context) void {
        const h = self.gc orelse return;
        while (!self.gc_marker_stop.load(.acquire)) {
            if (h.concurrentMarkRound()) std.atomic.spinLoopHint();
        }
    }

    /// Stop+join the marker and close any in-flight concurrent cycle
    /// (world-stopped: fold born cells, re-scan roots, sweep). Called at the
    /// finish safepoint and every quiescent boundary so a marker never outlives it.
    fn finishConcurrentGCIfActive(self: *Context) void {
        const h = self.gc orelse return;
        if (self.gc_marker) |t| {
            self.gc_marker_stop.store(true, .release);
            t.join();
            self.gc_marker = null;
        }
        if (h.concurrent.load(.acquire)) {
            self.gc_scan_native_stack = true;
            defer self.gc_scan_native_stack = false;
            h.finishConcurrentMark();
        }
    }

    fn collectMidScript(raw_ctx: *anyopaque, raw_machine: *anyopaque) void {
        const self: *Context = @ptrCast(@alignCast(raw_ctx));
        const machine: *interp.Interpreter = @ptrCast(@alignCast(raw_machine));
        const h = self.gc orelse return;
        if (!stack_scan.supported) return;
        // Parallel mid-script collection (opt-in: `parallel_midscript_gc`). Runs
        // even though `gil != null` because `parallel_js` drops the *execution*
        // GIL. Abort-safe; see `serviceParallelGc`.
        if (self.gc_par_enabled and h.parallel) {
            self.serviceParallelGc(h, machine);
            return;
        }
        if (self.gil != null) return;
        // Parallel-mutator mode (parallel_gc): mid-script collection is not yet
        // safe with multiple mutators running without the GIL — it needs the
        // world-stop/safepoint protocol generalized to parallel threads (a later
        // step of the execution-path GIL drop). Until then, collection in this
        // mode is explicit/quiescent only (`collectGarbage`); skip the safepoint
        // collector so parallel execution never races a marker.
        if (h.parallel) return;
        // M3 concurrent driver (single-mutator, opt-in): begin a concurrent mark
        // at one safepoint and close it at the next, a dedicated marker thread
        // tracing during the window while the mutator runs. Stores feed the marker
        // via the insertion barrier; cells born this cycle are deferred (traced at
        // finish, so the marker never sees a half-built cell); begin/finish
        // snapshot the native stack at the safepoint, and finish re-scans roots.
        if (self.gc_concurrent) {
            if (h.concurrent.load(.acquire)) {
                self.finishConcurrentGCIfActive();
            } else if (h.bytes_live >= h.threshold_bytes) {
                self.gc_scan_native_stack = true;
                h.beginConcurrentMark();
                self.gc_scan_native_stack = false;
                self.gc_marker_stop.store(false, .release);
                self.gc_marker = std.Thread.spawn(.{}, gcMarkerLoop, .{self}) catch blk: {
                    self.gc_scan_native_stack = true;
                    h.finishConcurrentMark();
                    self.gc_scan_native_stack = false;
                    break :blk null;
                };
            }
            return;
        }
        // Only advance marking while every peer is parked-and-published: the
        // start/finish root scans then see complete roots (own + parked peers'
        // native stacks), and the collector holds the GIL so those stacks are
        // frozen. Heap stores by peers between steps are caught by the global
        // insertion write barrier; mid-cycle allocations are born grey.
        if (self.gil) |g| {
            if (!g.allOthersParked()) return;
        }
        self.gc_scan_native_stack = true;
        defer self.gc_scan_native_stack = false;
        if (h.marking.load(.acquire)) {
            // Drain a bounded slice of the grey set; when it empties, close the
            // cycle (re-scan roots under the GIL, then sweep).
            if (h.markStep(mark_budget)) h.finishMarking();
        } else if (h.bytes_live >= h.threshold_bytes) {
            // Begin an incremental cycle: snapshot roots, then let the mutator
            // run between safepoints with the barrier shading its stores.
            h.startMarking();
        }
    }

    // ---- Mid-script parallel collector (issue #1 M3) ----------------------
    //
    // Every interpreter (the host + each spawned `Thread`) reaches this from its
    // safepoint (~every 1024 steps). The first to win the `gc_par_collector`
    // election drives a concurrent mark; the rest publish their precise roots
    // through the insertion barrier and resume — no mutator ever blocks for the
    // collector. The driver is *abort-safe*: it sweeps only after a root
    // handshake confirms every peer has published and the heap is stable, and
    // otherwise discards the mark without freeing anything (falling back to the
    // next quiescent `collectGarbage`). So it can neither deadlock nor
    // use-after-free. See docs/threads/P7-gil-removal.md.

    fn serviceParallelGc(self: *Context, h: *GcHeap, machine: *interp.Interpreter) void {
        if (self.gc_par_collector.load(.acquire)) |c| {
            // A collection is in progress; if we aren't the collector, publish
            // our roots for the requested generation and resume.
            if (c != machine) self.publishParallelRoots(machine);
            return;
        }
        // No collection running. Start one only under heap pressure.
        if (!h.shouldCollect()) return;
        // Elect a single collector; losers publish and resume.
        if (self.gc_par_collector.cmpxchgStrong(null, machine, .acq_rel, .acquire) != null) {
            self.publishParallelRoots(machine);
            return;
        }
        defer self.gc_par_collector.store(null, .release);
        self.driveParallelCollection(h, machine);
        // NOTE: `gc_par_request` is monotonic and is NOT reset here. Each cycle's
        // first generation (a fresh `fetchAdd`) is strictly greater than any
        // interpreter's `gc_published_gen`, so every peer republishes for the new
        // cycle rather than a stale high `published_gen` falsely satisfying a low
        // new generation (which would skip republication of post-whiten roots —
        // a use-after-free). Peers only publish at all while a collector is
        // elected (`gc_par_collector != null`), so a non-zero idle request is inert.
    }

    /// Peer/loser path: if the collector has an open request this interpreter
    /// hasn't served, shade its precise roots into the marker's hand-off buffer
    /// and record the generation. Called from a safepoint (or the park path),
    /// where the interpreter holds no per-structure lock.
    fn publishParallelRoots(self: *Context, machine: *interp.Interpreter) void {
        const req = self.gc_par_request.load(.acquire);
        if (req == 0) return;
        if (machine.gc_published_gen.load(.acquire) >= req) return;
        gc_mod.publishInterpreterRoots(machine);
        machine.gc_published_gen.store(req, .release);
    }

    /// True once every active peer interpreter (all but the collector) has
    /// published generation `gen`. A peer that has exited is gone from the list;
    /// a peer that parked published via the park path. Never blocks a peer.
    fn allParallelPublished(self: *Context, gen: u64, me: *interp.Interpreter) bool {
        self.lockActiveInterpreters();
        defer self.unlockActiveInterpreters();
        for (self.active_interpreters.items) |m| {
            if (m == me) continue;
            // A parked peer is frozen and traced directly by the collector, so it
            // need not publish; only running peers must reach the generation.
            if (m.gc_parked.load(.acquire)) continue;
            if (m.gc_published_gen.load(.acquire) < gen) return false;
        }
        return true;
    }

    fn driveParallelCollection(self: *Context, h: *GcHeap, machine: *interp.Interpreter) void {
        // BEGIN: whiten + arm the barrier under alloc_lock, then trace the
        // collector-safe roots — realm roots (lock-guarded), this collector's own
        // interpreter + native stack, and parked peers' frozen stacks. Running
        // peers self-publish via the handshake (traceRoots reads gc_par_collector
        // to skip them). gc_par_collector is already set to `machine`.
        self.gc_scan_native_stack = true;
        h.beginConcurrentMarkParallel();
        self.gc_scan_native_stack = false;

        const max_rounds: u32 = 32;
        // Per-round bound on how many mark-and-poll iterations to spend waiting
        // for every running peer to publish before giving up and aborting. Each
        // iteration drains marker work, so this is not pure spinning; a peer
        // reaches its safepoint within ~1024 JS steps. The loop also yields the
        // CPU periodically so peers can run to their safepoints (important when
        // threads outnumber cores, and under TSan's ~10× slowdown).
        const wait_budget: u64 = 50_000;
        var prev_born: usize = h.bornPendingLen();
        var round: u32 = 0;
        while (round < max_rounds) : (round += 1) {
            // Open a fresh root-publication generation; peers catch up at their
            // safepoints. Mark concurrently while we wait (the collector is also
            // the marker here — no separate marker thread).
            const gen = self.gc_par_request.fetchAdd(1, .acq_rel) + 1;
            var waited: u64 = 0;
            while (!self.allParallelPublished(gen, machine)) {
                self.gc_scan_native_stack = true;
                _ = h.concurrentMarkRound();
                self.gc_scan_native_stack = false;
                waited += 1;
                if (waited >= wait_budget) {
                    self.gc_scan_native_stack = true;
                    h.abortConcurrentMarkParallel();
                    self.gc_scan_native_stack = false;
                    return;
                }
                // Yield so peers get scheduled to reach their safepoints and
                // publish, rather than starving them by busy-spinning.
                if ((waited & 0x3ff) == 0) std.Thread.yield() catch {} else std.atomic.spinLoopHint();
            }
            // Everyone published this generation. Drain to local quiescence.
            self.gc_scan_native_stack = true;
            while (!h.concurrentMarkRound()) {}
            self.gc_scan_native_stack = false;

            // On any one-round lull (born-cell set unchanged → peers not
            // mid-allocation, so born payloads are initialized) with nothing
            // deferred (a running peer's generator can't be traced soundly),
            // ATTEMPT to finish. `finishConcurrentMarkParallel` is itself
            // self-checking: it sweeps only if no peer allocated during the
            // finish, otherwise it returns false (having done useful marking) and
            // we simply keep going. So being aggressive here is safe and lets the
            // collector converge as soon as it catches a genuine lull.
            const born = h.bornPendingLen();
            if (born == prev_born and h.deferredPendingLen() == 0) {
                self.gc_scan_native_stack = true;
                const swept = h.finishConcurrentMarkParallel();
                self.gc_scan_native_stack = false;
                if (swept) {
                    _ = self.gc_par_collections.fetchAdd(1, .monotonic);
                    return;
                }
                // Allocation happened during the finish — its born fold already
                // ran, so refresh the baseline and keep marking.
            }
            prev_born = h.bornPendingLen();
        }
        // Couldn't converge within the round budget (heavy continuous allocation
        // or a deferred generator) — abort and let quiescent collection reclaim.
        self.gc_scan_native_stack = true;
        h.abortConcurrentMarkParallel();
        self.gc_scan_native_stack = false;
    }

    pub fn queueFinalizationRegistryCleanup(self: *Context, registry: *value.Object) void {
        // Read by the mid-script parallel collector; guard under `realm_lock`
        // (a no-op outside parallel_js).
        self.realmLock();
        defer self.realmUnlock();
        for (self.finalization_cleanup_jobs.items) |queued| {
            if (queued == registry) return;
        }
        self.finalization_cleanup_jobs.append(self.gpa, registry) catch {};
    }

    /// Lex + parse + run `source`, returning the completion value. On an
    /// uncaught JS exception this returns `error.Throw` and leaves the thrown
    /// value in `self.exception` for the caller (e.g. the C-API boundary).
    ///
    /// Fast path: compile to bytecode and run on the VM. Programs that use
    /// constructs the compiler doesn't lower yet fall back to the tree-walker,
    /// so behavior is identical either way — the VM just handles the hot subset.
    pub fn evaluate(self: *Context, source: []const u8) RunError!value.Value {
        if (self.gil) |g| if (!self.parallel_js) g.acquire();
        defer if (self.gil) |g| if (!self.parallel_js) g.release();
        self.assertOwnerThread();
        const gc_saved = gc_mod.setActiveHeap(self.gc);
        defer _ = gc_mod.setActiveHeap(gc_saved);
        const sa_saved = strcell.setActiveArena(self.arena());
        defer _ = strcell.setActiveArena(sa_saved);
        // Register this frame as the high boundary of the live native stack so a
        // mid-script collection can conservatively root the interpreter's
        // `Value` locals below it (`stack_scan.zig`). Cheap; matters only when
        // the GC is on.
        const ss_saved = stack_scan.enter(@frameAddress());
        defer stack_scan.leave(ss_saved);
        // Close any concurrent mark before returning (runs first at exit, LIFO,
        // so the stack boundary above is still valid for its re-scan).
        defer self.finishConcurrentGCIfActive();
        // Quiescent point: reclaim garbage from prior evaluations on this
        // context before running (nothing is executing yet, so the Context
        // roots are complete).
        self.collectGarbage();
        self.collectRequestedGarbage();
        const a = self.arena();
        const owned_source = try a.dupe(u8, source);
        var parser = try Parser.init(a, owned_source);
        const prog = try parser.parseProgram();
        // Global (Script) code has no `super` binding, so a top-level SuperCall or
        // SuperProperty — including inside a top-level arrow — is an early
        // SyntaxError. (Direct/indirect `eval` runs its own context-aware scan
        // via the interpreter, so this entry is genuine global code only.) The
        // scan descends into arrows but stops at nested functions/classes/methods.
        if (prog.* == .program) try parser.scanEvalContext(prog.program, true, true);
        var machine = self.interpreter();
        try self.pushActiveInterpreter(&machine);
        defer self.popActiveInterpreter(&machine);
        // Top-level strictness from the program's directive prologue (the parser
        // leaves `strict` set if it saw a leading `"use strict"`).
        machine.strict = parser.strict;
        self.exception = null;
        // Top-level-script dynamic `import()`: when a module host is installed,
        // resolve specifiers relative to the script's referrer path.
        if (self.mod_host != null) {
            machine.dyn_import = dynImportHook;
            machine.dyn_import_ctx = self;
            machine.defer_trigger = deferTriggerHook;
            machine.defer_trigger_ctx = self;
            machine.cur_module = self.script_referrer;
        }

        const outcome: interp.EvalError!value.Value = if (compiler.Compiler.compileProgram(a, prog)) |chunk|
            vm.run(&machine, chunk, null)
        else |err| switch (err) {
            error.Unsupported => machine.eval(prog), // construct the VM can't lower
            error.OutOfMemory => return error.OutOfMemory,
        };
        const top_level_failed = if (outcome) |_| false else |_| true;

        // Microtask checkpoint: run queued Promise reactions before returning, so
        // settled `.then`/`await` continuations and the async harness's `$DONE`
        // have executed by the time `evaluate` returns. Then the waitAsync
        // tail: block for outstanding async waiters (notify/deadline), resolve
        // them, and drain again until quiescent.
        machine.drainMicrotasks() catch {};
        machine.settleAsyncWaiters();
        machine.drainFinalizationCleanupJobs() catch {};
        machine.drainMicrotasks() catch {};
        machine.settleAsyncWaiters();
        // Shell keepalive (threads mode): a pending Thread completion is a
        // pending settlement — the realm stays alive until every spawned
        // thread finishes (each drains its own queue and settles its
        // asyncJoins), then drains whatever those settlements queued here.
        if (self.gil) |g| {
            if (top_level_failed) self.teardown_stop.store(true, .release);
            var i: usize = 0;
            while (i < self.js_threads.items.len) : (i += 1) {
                const rec = self.js_threads.items[i];
                if (self.parallel_js) {
                    const io = agent.engineIo();
                    rec.join_mutex.lockUncancelable(io);
                    while (!rec.done) {
                        // Parked keepalive still serves run-loop tasks: a waiting
                        // thread may need a grant delivery pumped to finish.
                        rec.join_mutex.unlock(io);
                        jsthread.pumpTasks(&machine);
                        rec.join_mutex.lockUncancelable(io);
                        if (rec.done) break;
                        stack_scan.beginPark();
                        io_compat.conditionWaitTimeout(&rec.done_cond, io, &rec.join_mutex, .{ .duration = .{
                            .raw = .fromMilliseconds(5),
                            .clock = .awake,
                        } }) catch {};
                        stack_scan.endPark();
                    }
                    rec.join_mutex.unlock(io);
                } else {
                    while (!rec.done) {
                        // Parked keepalive still serves run-loop tasks: a waiting
                        // thread may need a grant delivery pumped to finish.
                        jsthread.pumpTasks(&machine);
                        if (rec.done) break;
                        g.waitTimeout(&rec.done_cond, .{ .duration = .{
                            .raw = .fromMilliseconds(5),
                            .clock = .awake,
                        } }) catch {};
                    }
                }
            }
            machine.drainMicrotasks() catch {};
            machine.settleAsyncWaiters();
            machine.drainFinalizationCleanupJobs() catch {};
            machine.drainMicrotasks() catch {};
            machine.settleAsyncWaiters();
            if (top_level_failed) self.teardown_stop.store(false, .release);
        }
        self.collectRequestedGarbage();

        return outcome catch |err| {
            if (err == error.Throw) self.exception = machine.exception;
            return err;
        };
    }

    // ----------------------------------------------------------------------
    // ES Modules: load a module graph, link it (wiring `import` bindings to the
    // exporting module's live bindings), then evaluate every module once in
    // dependency order. The *host* resolves a specifier to a canonical path and
    // its source text (the engine itself does no file I/O).
    // ----------------------------------------------------------------------

    /// How the host resolves a module specifier: given the importing module's
    /// canonical path and the specifier string, return the imported module's
    /// source text and write its canonical path into `out_path` (the dedup key),
    /// or null when it cannot be found.
    pub const ModuleHost = struct {
        ctx: *anyopaque,
        load: *const fn (ctx: *anyopaque, referrer: []const u8, specifier: []const u8, out_path: *[]const u8) ?[]const u8,
    };

    const ExportKind = union(enum) {
        local: []const u8, // a binding name in this module's environment
        indirect: struct { module: *Module, name: []const u8 }, // re-export
    };

    fn isSourceImport(entry: ast.ImportEntry) bool {
        return std.mem.eql(u8, entry.imported, "source");
    }

    fn isHostModuleSourceSpecifier(specifier: []const u8) bool {
        return std.mem.eql(u8, specifier, "<module source>");
    }

    pub const Module = struct {
        path: []const u8,
        items: []*ast.Node,
        env: *interp.Environment,
        deps: std.StringHashMapUnmanaged(*Module) = .{}, // specifier -> module
        exports: std.StringHashMapUnmanaged(ExportKind) = .{}, // exported name -> binding
        star_sources: std.ArrayListUnmanaged(*Module) = .empty, // `export * from`
        ns: ?*value.Object = null, // the namespace exotic object, if requested
        deferred_ns: ?*value.Object = null, // the `import defer` namespace, if requested (distinct, cached)
        import_meta_slot: interp.ImportMetaSlot = .{},
        linked: bool = false,
        eval_started: bool = false, // [[Status]] reached ~evaluating~
        evaluated: bool = false, // [[Status]] reached ~evaluated~ (completed, even if it threw)
        eval_error: ?Value = null, // cached evaluation error for repeated Evaluate()
        // A synthetic module (`import x from "m" with { type: "json"|"text" }`):
        // its raw source, turned into the sole `default` export at evaluation
        // time per `syn_type` ("json" → JSON.parse, "text" → the string itself).
        // Null for an ordinary JS module (`items` holds its AST instead).
        syn_source: ?[]const u8 = null,
        syn_type: []const u8 = "",
    };

    fn isSyntheticModuleType(module_type: []const u8) bool {
        return std.mem.eql(u8, module_type, "json") or
            std.mem.eql(u8, module_type, "text") or
            std.mem.eql(u8, module_type, "bytes");
    }

    fn syntheticModuleCacheKey(self: *Context, path: []const u8, syn_type: []const u8) RunError![]const u8 {
        return try std.fmt.allocPrint(self.arena(), "{s}\x00{s}", .{ path, syn_type });
    }

    /// Load, link, and evaluate a module graph rooted at `entry_path`. The
    /// completion is the entry module having run; an uncaught throw leaves the
    /// reason in `self.exception` and returns `error.Throw`.
    pub fn evaluateModule(self: *Context, entry_path: []const u8, entry_source: []const u8, host: ModuleHost) RunError!value.Value {
        if (self.gil) |g| if (!self.parallel_js) g.acquire();
        defer if (self.gil) |g| if (!self.parallel_js) g.release();
        self.assertOwnerThread();
        const gc_saved = gc_mod.setActiveHeap(self.gc);
        defer _ = gc_mod.setActiveHeap(gc_saved);
        const sa_saved = strcell.setActiveArena(self.arena());
        defer _ = strcell.setActiveArena(sa_saved);
        // See `evaluate`: register the native-stack scan boundary for mid-script
        // collection during module execution.
        const ss_saved = stack_scan.enter(@frameAddress());
        defer stack_scan.leave(ss_saved);
        defer self.finishConcurrentGCIfActive(); // close any concurrent mark (see evaluate)
        // Quiescent point before module execution; a prior shell `gc()` request
        // can be serviced before the live module graph is installed.
        self.collectRequestedGarbage();
        var cache: std.StringHashMapUnmanaged(*Module) = .{};
        const root = try self.loadModule(entry_path, entry_source, host, &cache);
        try self.linkModule(root);
        var machine = self.interpreter();
        try self.pushActiveInterpreter(&machine);
        defer self.popActiveInterpreter(&machine);
        machine.strict = true;
        // Expose the graph to runtime dynamic `import()`.
        self.mod_host = host;
        self.mod_cache = &cache;
        defer {
            self.mod_cache = null;
            self.mod_host = null;
        }
        machine.dyn_import = dynImportHook;
        machine.dyn_import_ctx = self;
        machine.defer_trigger = deferTriggerHook;
        machine.defer_trigger_ctx = self;
        // Populate any namespace objects after the whole graph has evaluated, so
        // every exported binding holds its final value.
        const outcome = self.evalModule(&machine, root);
        machine.drainMicrotasks() catch {};
        machine.settleAsyncWaiters();
        machine.drainFinalizationCleanupJobs() catch {};
        machine.drainMicrotasks() catch {};
        machine.settleAsyncWaiters();
        outcome catch |err| {
            if (err == error.Throw) self.exception = machine.exception;
            return err;
        };
        return Value.undef();
    }

    /// Recursively load and parse a module and its dependencies into `cache`
    /// (keyed by canonical path), collecting each module's imports and exports.
    fn loadModule(self: *Context, path: []const u8, source: []const u8, host: ModuleHost, cache: *std.StringHashMapUnmanaged(*Module)) RunError!*Module {
        if (cache.get(path)) |m| return m;
        const a = self.arena();

        const owned_source = try a.dupe(u8, source);
        var parser = try Parser.init(a, owned_source);
        const prog = try parser.parseModule();
        const items = prog.program;

        const env = try gc_mod.allocEnv(a);
        // A module environment is a variable scope whose parent is the global
        // scope (so globals resolve), but its own declarations stay module-local.
        env.* = .{
            .arena = a,
            .bindings_allocator = if (self.gc != null) self.gpa else null,
            .gc_name_bytes_live = if (self.gc != null) &self.gc_environment_name_bytes_live else null,
            .parent = &self.env,
            .fn_scope = true,
        };

        const m = try a.create(Module);
        m.* = .{ .path = try a.dupe(u8, path), .items = items, .env = env };
        try cache.put(a, m.path, m);

        // Load every dependency and record this module's export map.
        for (items) |item| switch (item.*) {
            .import_decl => |imp| {
                const source_only = imp.entries.len == 1 and isSourceImport(imp.entries[0]);
                if (!source_only)
                    _ = try self.loadDep(m, imp.specifier, imp.attr_type, host, cache);
            },
            .export_decl => |e| {
                if (e.from.len > 0) _ = try self.loadDep(m, e.from, "", host, cache);
                try self.collectExports(m, e);
            },
            else => {},
        };
        return m;
    }

    /// Resolve `specifier` against module `m`, load it, and record it in `m.deps`.
    /// `module_type` is the `type` import attribute ("json" → a synthetic JSON
    /// module; "" → an ordinary JS module).
    fn loadDep(self: *Context, m: *Module, specifier: []const u8, module_type: []const u8, host: ModuleHost, cache: *std.StringHashMapUnmanaged(*Module)) RunError!*Module {
        if (m.deps.get(specifier)) |d| return d;
        var dep_path: []const u8 = "";
        const dep_src = host.load(host.ctx, m.path, specifier, &dep_path) orelse
            return self.moduleError("Cannot resolve module specifier");
        const dep = if (isSyntheticModuleType(module_type))
            try self.loadSyntheticModule(dep_path, dep_src, module_type, cache)
        else
            try self.loadModule(dep_path, dep_src, host, cache);
        try m.deps.put(self.arena(), specifier, dep);
        return dep;
    }

    /// Build a synthetic module (JSON, text, or bytes): no JS body, a single
    /// `default` export materialized at evaluation time from the raw source.
    fn loadSyntheticModule(self: *Context, path: []const u8, source: []const u8, syn_type: []const u8, cache: *std.StringHashMapUnmanaged(*Module)) RunError!*Module {
        const a = self.arena();
        const cache_key = try self.syntheticModuleCacheKey(path, syn_type);
        if (cache.get(cache_key)) |m| return m;
        const env = try gc_mod.allocEnv(a);
        env.* = .{
            .arena = a,
            .bindings_allocator = if (self.gc != null) self.gpa else null,
            .gc_name_bytes_live = if (self.gc != null) &self.gc_environment_name_bytes_live else null,
            .parent = &self.env,
            .fn_scope = true,
        };
        const m = try a.create(Module);
        m.* = .{ .path = cache_key, .items = &.{}, .env = env, .syn_source = try a.dupe(u8, source), .syn_type = syn_type };
        try m.exports.put(a, "default", .{ .local = "*default*" });
        try cache.put(a, m.path, m);
        return m;
    }

    fn newModuleSourceObject(self: *Context) RunError!*value.Object {
        if (self.module_source_object) |cached| return cached;
        const a = self.arena();
        const obj = try gc_mod.allocObj(a);
        obj.* = .{};
        if (self.env.get("$262")) |host| if (host.isObject()) {
            if (host.asObj().getOwn("AbstractModuleSource")) |ctor| if (ctor.isObject()) {
                if (ctor.asObj().getOwn("prototype")) |proto| if (proto.isObject()) {
                    obj.proto = proto.asObj();
                };
            };
        };
        self.module_source_object = obj;
        return obj;
    }

    /// Record the export names introduced by one `export` declaration.
    fn collectExports(self: *Context, m: *Module, e: *ast.ExportNode) RunError!void {
        const a = self.arena();
        if (e.declaration) |d| {
            try declaredExportNames(self, m, d);
        }
        if (e.default_expr != null) {
            const local = if (e.default_name.len > 0) e.default_name else "*default*";
            try m.exports.put(a, "default", .{ .local = local });
        }
        for (e.entries) |entry| {
            if (e.from.len == 0) {
                try m.exports.put(a, entry.exported, .{ .local = entry.local });
            } else {
                const dep = m.deps.get(e.from).?;
                try m.exports.put(a, entry.exported, .{ .indirect = .{ .module = dep, .name = entry.imported } });
            }
        }
        if (e.star) {
            const dep = m.deps.get(e.from).?;
            if (e.star_as.len > 0) {
                // `export * as ns from "m"` — a namespace re-export.
                try m.exports.put(a, e.star_as, .{ .local = e.star_as });
            } else {
                try m.star_sources.append(a, dep); // `export * from "m"`
            }
        }
    }

    /// Add the names bound by an exported declaration as local exports.
    fn declaredExportNames(self: *Context, m: *Module, d: *ast.Node) RunError!void {
        const a = self.arena();
        switch (d.*) {
            .func_decl => |f| try m.exports.put(a, f.name, .{ .local = f.name }),
            .var_decl => |v| try m.exports.put(a, v.name, .{ .local = v.name }),
            .decl_group => |group| for (group) |g| try declaredExportNames(self, m, g),
            else => {},
        }
    }

    fn moduleError(self: *Context, msg: []const u8) RunError {
        var machine = self.interpreter();
        machine.throwError("SyntaxError", msg) catch {};
        self.exception = machine.exception; // surface to the caller (load/link run outside evalModule)
        return error.Throw;
    }

    fn moduleTypeError(self: *Context, msg: []const u8) RunError {
        var machine = self.interpreter();
        machine.throwError("TypeError", msg) catch {};
        self.exception = machine.exception;
        return error.Throw;
    }

    const ExportResolution = union(enum) {
        not_found,
        found: interp.Environment.Alias,
        ambiguous,
    };

    fn sameExportResolution(a: interp.Environment.Alias, b: interp.Environment.Alias) bool {
        return a.env == b.env and std.mem.eql(u8, a.name, b.name);
    }

    /// Resolve an export `name` of `module`, chasing re-exports and `export *`
    /// sources. Distinguishes the spec's "ambiguous" result from "not found",
    /// because indirect exports/imports must reject both while namespace objects
    /// merely omit ambiguous star names.
    fn resolveExport(module: *Module, name: []const u8, depth: u32) ExportResolution {
        if (depth > 64) return .not_found;
        if (module.exports.get(name)) |kind| switch (kind) {
            .local => |local| return .{ .found = .{ .env = module.env, .name = local } },
            .indirect => |ind| {
                if (std.mem.eql(u8, ind.name, "*namespace*")) return .not_found; // namespace handled separately
                return resolveExport(ind.module, ind.name, depth + 1);
            },
        };
        // `export *` sources: a name not directly exported may come from one.
        var star_resolution: ?interp.Environment.Alias = null;
        for (module.star_sources.items) |src| {
            switch (resolveExport(src, name, depth + 1)) {
                .not_found => {},
                .ambiguous => return .ambiguous,
                .found => |r| {
                    if (star_resolution) |existing| {
                        if (!sameExportResolution(existing, r)) return .ambiguous;
                    } else {
                        star_resolution = r;
                    }
                },
            }
        }
        return if (star_resolution) |r| .{ .found = r } else .not_found;
    }

    /// Link a module: load-order recursion that wires every `import` binding in
    /// the module's environment to the exporting module's live binding (or a
    /// namespace object). Idempotent and cycle-safe via the `linked` flag.
    fn linkModule(self: *Context, m: *Module) RunError!void {
        if (m.linked) return;
        m.linked = true;
        // Source-phase imports do not instantiate the target as an ordinary
        // module. Reject unsupported host source records before dependency
        // linking so their host-defined failure is not masked by unrelated
        // linking errors in sibling imports.
        for (m.items) |item| switch (item.*) {
            .import_decl => |imp| for (imp.entries) |entry| {
                if (isSourceImport(entry) and !isHostModuleSourceSpecifier(imp.specifier))
                    return self.moduleTypeError("source phase import is not available");
            },
            else => {},
        };
        // Link dependencies first.
        var dit = m.deps.valueIterator();
        while (dit.next()) |dep| try self.linkModule(dep.*);

        var eit = m.exports.iterator();
        while (eit.next()) |entry| switch (entry.value_ptr.*) {
            .local => {},
            .indirect => |ind| {
                if (std.mem.eql(u8, ind.name, "*namespace*")) continue;
                switch (resolveExport(ind.module, ind.name, 0)) {
                    .found => {},
                    .not_found, .ambiguous => return self.moduleError("does not provide an export"),
                }
            },
        };

        for (m.items) |item| switch (item.*) {
            .import_decl => |imp| {
                const dep = if (m.deps.get(imp.specifier)) |d| d else null;
                for (imp.entries) |entry| {
                    if (isSourceImport(entry)) {
                        try m.env.putConst(entry.local, Value.obj(try self.newModuleSourceObject()));
                    } else if (std.mem.eql(u8, entry.imported, "*")) {
                        const nsobj = if (imp.deferred) try self.deferredNamespaceObject(dep.?) else try self.namespaceObject(dep.?);
                        try m.env.putConst(entry.local, Value.obj(nsobj));
                    } else {
                        switch (resolveExport(dep.?, entry.imported, 0)) {
                            .found => |res| try m.env.putAlias(entry.local, res.env, res.name),
                            .not_found, .ambiguous => return self.moduleError("does not provide an export"),
                        }
                    }
                }
            },
            .export_decl => |e| {
                // `export * as ns from "m"` needs a namespace object for `m`.
                if (e.star and e.star_as.len > 0) {
                    const dep = m.deps.get(e.from).?;
                    try m.env.put(e.star_as, Value.obj(try self.namespaceObject(dep)));
                }
            },
            else => {},
        };

        // ModuleDeclarationInstantiation (lexical part): top-level let/const/class
        // bindings exist in the module environment in their TDZ before any code
        // runs, so observing them through the namespace (e.g. a circular or self
        // import) throws a ReferenceError until they are initialized.
        for (m.items) |item| self.instantiateLexical(m, item);
        // A synthetic module's sole `default` binding is in TDZ until its
        // evaluation materializes it (so observing it before then is a
        // ReferenceError).
        if (m.syn_source != null) m.env.put("*default*", Value.obj(self.tdz_marker)) catch {};
    }

    /// Pre-declare a statement's top-level lexical (`let`/`const`) bindings as
    /// TDZ sentinels in the module environment.
    fn instantiateLexical(self: *Context, m: *Module, item: *ast.Node) void {
        const tdz = Value.obj(self.tdz_marker);
        switch (item.*) {
            .var_decl => |v| if (v.kind != .@"var") m.env.put(v.name, tdz) catch {},
            .decl_group => |g| for (g) |s| self.instantiateLexical(m, s),
            .export_decl => |e| {
                if (e.declaration) |d| self.instantiateLexical(m, d);
                if (e.default_expr) |dx| switch (dx.*) {
                    .class_expr => {
                        m.env.put("*default*", tdz) catch {};
                        if (e.default_name.len > 0) m.env.put(e.default_name, tdz) catch {};
                    },
                    else => m.env.put("*default*", tdz) catch {},
                };
            },
            else => {},
        }
    }

    /// Evaluate a module (and its not-yet-evaluated dependencies first), running
    /// its top-level items in its own environment with `this === undefined`.
    fn evalModule(self: *Context, machine: *interp.Interpreter, m: *Module) interp.EvalError!void {
        if (m.evaluated) {
            if (m.eval_error) |err| {
                machine.exception = err;
                self.exception = err;
                return error.Throw;
            }
            return;
        }
        if (m.eval_started) return;
        m.eval_started = true;
        defer m.evaluated = true; // reaches ~evaluated~ on completion, even on a throw
        self.evalModuleBody(machine, m) catch |err| {
            if (err == error.Throw) {
                m.eval_error = machine.exception;
                self.exception = machine.exception;
            }
            return err;
        };
    }

    fn evalModuleBody(self: *Context, machine: *interp.Interpreter, m: *Module) interp.EvalError!void {
        if (m.syn_source) |src| {
            // The synthetic module's `default` export: JSON.parse(source) for a
            // JSON module, the raw source string for text, or an immutable
            // Uint8Array view for bytes.
            const def = if (std.mem.eql(u8, m.syn_type, "json"))
                try builtins.jsonParse(machine, Value.undef(), &.{Value.str(src)})
            else if (std.mem.eql(u8, m.syn_type, "bytes"))
                Value.obj(try machine.makeImmutableUint8ArrayFromBytes(src))
            else
                Value.str(src);
            try m.env.put("*default*", def);
            return;
        }
        for (m.items) |item| switch (item.*) {
            .import_decl => |imp| {
                const source_only = imp.entries.len == 1 and isSourceImport(imp.entries[0]);
                // A deferred import (`import defer`) is NOT eagerly evaluated; its
                // evaluation is triggered lazily on first namespace access.
                if ((!source_only or !isHostModuleSourceSpecifier(imp.specifier)) and !imp.deferred)
                    try self.evalModule(machine, m.deps.get(imp.specifier).?);
            },
            .export_decl => |e| if (e.from.len > 0) try self.evalModule(machine, m.deps.get(e.from).?),
            else => {},
        };

        const saved_env = machine.env;
        const saved_this = machine.this_value;
        const saved_mod = machine.cur_module;
        const saved_import_meta_slot = machine.import_meta_slot;
        const saved_import_meta_obj = machine.import_meta_obj;
        machine.env = m.env;
        machine.this_value = Value.undef(); // module top-level `this` is undefined
        machine.cur_module = m.path; // referrer for runtime import()
        machine.import_meta_slot = &m.import_meta_slot;
        machine.import_meta_obj = m.import_meta_slot.obj;
        defer {
            machine.env = saved_env;
            machine.this_value = saved_this;
            machine.cur_module = saved_mod;
            machine.import_meta_slot = saved_import_meta_slot;
            machine.import_meta_obj = saved_import_meta_obj;
        }
        _ = try machine.evalStatements(m.items);
    }

    /// Build (or return) the namespace exotic object for `module`. Created empty
    /// at link time and filled after the module evaluates.
    fn namespaceObject(self: *Context, module: *Module) RunError!*value.Object {
        if (module.ns) |ns| return ns;
        const a = self.arena();
        const ns = try gc_mod.allocObj(a);
        ns.* = .{};
        module.ns = ns;
        // Build the live Module Namespace exotic data now (at link time): the
        // bindings are read lazily on access, so this is valid before the module
        // has evaluated (and the namespace may be observed during evaluation).
        var machine = self.interpreter();
        try self.fillNamespace(&machine, module, ns);
        return ns;
    }

    /// Build (or return) the *deferred* namespace exotic object for `module`
    /// (`import defer * as ns`): a distinct, cached object whose string-keyed
    /// accesses lazily trigger `module`'s evaluation (via `defer_trigger`).
    fn deferredNamespaceObject(self: *Context, module: *Module) RunError!*value.Object {
        if (module.deferred_ns) |ns| return ns;
        const a = self.arena();
        const ns = try gc_mod.allocObj(a);
        ns.* = .{};
        module.deferred_ns = ns;
        var machine = self.interpreter();
        try self.fillNamespace(&machine, module, ns);
        const modns: *interp.ModuleNs = @ptrCast(@alignCast(ns.module_ns.?));
        modns.deferred = true;
        modns.defer_module = module;
        return ns;
    }

    /// `defer_trigger` hook: evaluate the `import defer` module on first
    /// string-keyed access of its deferred namespace (idempotent via `evaluated`).
    fn deferTriggerHook(ctx: *anyopaque, machine: *interp.Interpreter, module: *anyopaque) interp.EvalError!void {
        const self: *Context = @ptrCast(@alignCast(ctx));
        const m: *Module = @ptrCast(@alignCast(module));
        // EnsureDeferredNamespaceEvaluation / ReadyForSyncExecution: a module that
        // is already evaluating (its own deferred namespace observed mid-evaluation,
        // directly or via a dependency) cannot trigger its own evaluation — a
        // TypeError, rather than re-entering or reading a half-initialized binding.
        if (m.eval_started and !m.evaluated)
            return machine.throwError("TypeError", "Cannot trigger evaluation of a module that is already evaluating");
        try self.evalModule(machine, m);
    }

    /// Runtime `import(specifier)` driver (wired into the interpreter as
    /// `dyn_import`): resolve the specifier relative to `referrer`, then load,
    /// link, and evaluate the target module, writing its namespace into `out`.
    /// Returns false (leaving the reason in `machine.exception`) on any failure,
    /// so the caller rejects the dynamic-import promise.
    fn dynImportHook(ctx: *anyopaque, machine: *interp.Interpreter, referrer: []const u8, specifier: []const u8, phase: []const u8, module_type: []const u8, out: *value.Value) bool {
        const self: *Context = @ptrCast(@alignCast(ctx));
        if (std.mem.eql(u8, phase, "source"))
            return self.dynImportFailKind(machine, "SyntaxError", "source phase dynamic import is not available");
        const host = self.mod_host orelse return self.dynImportFail(machine, "dynamic import is not available");
        const cache = self.mod_cache orelse return self.dynImportFail(machine, "dynamic import is not available");
        var dep_path: []const u8 = "";
        const src = host.load(host.ctx, referrer, specifier, &dep_path) orelse
            return self.dynImportFail(machine, "Cannot resolve module specifier");
        const dep = if (isSyntheticModuleType(module_type))
            self.loadSyntheticModule(dep_path, src, module_type, cache) catch return self.surfaceFail(machine)
        else
            self.loadModule(dep_path, src, host, cache) catch return self.surfaceFail(machine);
        self.linkModule(dep) catch return self.surfaceFail(machine);
        // `import.defer(x)`: resolve the promise with the deferred namespace
        // without evaluating — evaluation is triggered lazily on first access.
        if (std.mem.eql(u8, phase, "defer")) {
            const dns = self.deferredNamespaceObject(dep) catch return self.surfaceFail(machine);
            out.* = Value.obj(dns);
            return true;
        }
        self.evalModule(machine, dep) catch return self.surfaceFail(machine);
        const ns = self.namespaceObject(dep) catch return self.surfaceFail(machine);
        self.fillNamespace(machine, dep, ns) catch return self.surfaceFail(machine);
        out.* = Value.obj(ns);
        return true;
    }

    fn dynImportFail(self: *Context, machine: *interp.Interpreter, msg: []const u8) bool {
        return self.dynImportFailKind(machine, "TypeError", msg);
    }

    fn dynImportFailKind(self: *Context, machine: *interp.Interpreter, kind: []const u8, msg: []const u8) bool {
        _ = self;
        machine.throwError(kind, msg) catch {};
        return false;
    }

    /// A load/link/eval step already threw; surface its reason for rejection.
    fn surfaceFail(self: *Context, machine: *interp.Interpreter) bool {
        if (self.exception) |ex| machine.exception = ex;
        return false;
    }

    /// A module namespace binding behind a live accessor: reads `name` in module
    /// environment `env` on each property access (so mutations of the exporting
    /// binding are observed through the namespace, per spec).
    const NsBinding = struct { env: *interp.Environment, name: []const u8 };

    fn nsGetter(ctx: *anyopaque, this: value.Value, args: []const value.Value) value.HostError!value.Value {
        _ = this;
        _ = args;
        const machine: *interp.Interpreter = @ptrCast(@alignCast(ctx));
        const fnobj = machine.active_native orelse return Value.undef();
        const b: *NsBinding = @ptrCast(@alignCast(fnobj.private_data.?));
        return b.env.get(b.name) orelse Value.undef();
    }

    /// Wire a module's exported bindings onto its namespace object as live
    /// accessor properties. The namespace exposes every export name (plus those
    /// reachable through `export *`), with `@@toStringTag` "Module".
    fn fillNamespace(self: *Context, machine: *interp.Interpreter, module: *Module, ns: *value.Object) interp.EvalError!void {
        const a = self.arena();
        // Collect every resolvable export name (own exports + `export *` sources,
        // default excluded from `*`), with its live binding.
        var names: std.ArrayListUnmanaged([]const u8) = .empty;
        var envs: std.ArrayListUnmanaged(*interp.Environment) = .empty;
        var locals: std.ArrayListUnmanaged([]const u8) = .empty;
        var ambiguous: std.ArrayListUnmanaged([]const u8) = .empty;
        const add = struct {
            fn contains(list: []const []const u8, name: []const u8) bool {
                for (list) |existing| if (std.mem.eql(u8, existing, name)) return true;
                return false;
            }

            fn sameObjectBinding(env: *interp.Environment, local: []const u8, res: interp.Environment.Alias) bool {
                const left = env.get(local) orelse return false;
                const right = res.env.get(res.name) orelse return false;
                return left.isObject() and right.isObject() and left.asObj() == right.asObj();
            }

            fn f(
                aa: std.mem.Allocator,
                nm: *std.ArrayListUnmanaged([]const u8),
                ev: *std.ArrayListUnmanaged(*interp.Environment),
                lo: *std.ArrayListUnmanaged([]const u8),
                amb: *std.ArrayListUnmanaged([]const u8),
                name: []const u8,
                res: interp.Environment.Alias,
            ) !void {
                if (contains(amb.items, name)) return;
                for (nm.items, 0..) |existing, i| {
                    if (!std.mem.eql(u8, existing, name)) continue;
                    if ((ev.items[i] == res.env and std.mem.eql(u8, lo.items[i], res.name)) or
                        sameObjectBinding(ev.items[i], lo.items[i], res))
                        return;
                    try amb.append(aa, name);
                    return;
                }
                try nm.append(aa, name);
                try ev.append(aa, res.env);
                try lo.append(aa, res.name);
            }
        }.f;
        var it = module.exports.iterator();
        while (it.next()) |e| {
            switch (resolveExport(module, e.key_ptr.*, 0)) {
                .found => |res| try add(a, &names, &envs, &locals, &ambiguous, e.key_ptr.*, res),
                .not_found, .ambiguous => {},
            }
        }
        for (module.star_sources.items) |src| {
            var sit = src.exports.iterator();
            while (sit.next()) |e| {
                const name = e.key_ptr.*;
                if (std.mem.eql(u8, name, "default")) continue;
                if (module.exports.contains(name)) continue;
                switch (resolveExport(src, name, 0)) {
                    .found => |res| try add(a, &names, &envs, &locals, &ambiguous, name, res),
                    .not_found, .ambiguous => {},
                }
            }
        }
        var write_i: usize = 0;
        for (names.items, 0..) |name, read_i| {
            var is_ambiguous = false;
            for (ambiguous.items) |ambiguous_name| {
                if (std.mem.eql(u8, ambiguous_name, name)) {
                    is_ambiguous = true;
                    break;
                }
            }
            if (is_ambiguous) continue;
            names.items[write_i] = name;
            envs.items[write_i] = envs.items[read_i];
            locals.items[write_i] = locals.items[read_i];
            write_i += 1;
        }
        names.items.len = write_i;
        envs.items.len = write_i;
        locals.items.len = write_i;
        // [[OwnPropertyKeys]] returns the string names sorted by code unit.
        const N = names.items.len;
        var order = try a.alloc(usize, N);
        for (0..N) |i| order[i] = i;
        std.sort.block(usize, order, names.items, struct {
            fn lt(ctx: []const []const u8, x: usize, y: usize) bool {
                return std.mem.lessThan(u8, ctx[x], ctx[y]);
            }
        }.lt);
        const sorted_names = try a.alloc([]const u8, N);
        const sorted_envs = try a.alloc(*interp.Environment, N);
        const sorted_locals = try a.alloc([]const u8, N);
        for (order, 0..) |src_i, dst_i| {
            sorted_names[dst_i] = names.items[src_i];
            sorted_envs[dst_i] = envs.items[src_i];
            sorted_locals[dst_i] = locals.items[src_i];
        }
        const modns = try gc_mod.allocModuleNs(a);
        modns.* = .{
            .names = sorted_names,
            .envs = sorted_envs,
            .locals = sorted_locals,
            .tag_key = machine.wellKnownSymbolKey("toStringTag") orelse "@@toStringTag",
        };
        ns.module_ns = @ptrCast(modns);
        ns.proto = null; // a module namespace has a null [[Prototype]]
        ns.extensible = false;
    }
};

const ModuleFixture = struct {
    path: []const u8,
    source: []const u8,
};

fn evaluateModuleWithFixtures(source: []const u8, fixtures: []const ModuleFixture) !void {
    const ctx = try Context.create(std.testing.allocator);
    defer ctx.destroy();

    try evaluateModuleWithFixturesInContext(ctx, source, fixtures);
}

fn evaluateModuleWithFixturesInContext(ctx: *Context, source: []const u8, fixtures: []const ModuleFixture) !void {
    const Host = struct {
        source: []const u8,
        fixtures: []const ModuleFixture,

        fn load(ctx_ptr: *anyopaque, _: []const u8, specifier: []const u8, out_path: *[]const u8) ?[]const u8 {
            const self: *@This() = @ptrCast(@alignCast(ctx_ptr));
            const path = if (std.mem.startsWith(u8, specifier, "./")) specifier[2..] else specifier;
            if (std.mem.eql(u8, path, "entry.js")) {
                out_path.* = "entry.js";
                return self.source;
            }
            for (self.fixtures) |fixture| {
                if (std.mem.eql(u8, path, fixture.path)) {
                    out_path.* = fixture.path;
                    return fixture.source;
                }
            }
            return null;
        }
    };

    var host_state = Host{ .source = source, .fixtures = fixtures };
    const mh = Context.ModuleHost{ .ctx = &host_state, .load = Host.load };
    _ = try ctx.evaluateModule("entry.js", source, mh);
}

fn evaluateSelfModule(source: []const u8) !void {
    try evaluateModuleWithFixtures(source, &.{});
}

test "modules initialize default and var exports for self imports" {
    try evaluateSelfModule(
        \\try {
        \\  typeof C;
        \\  throw new Error("missing default class TDZ");
        \\} catch (e) {
        \\  if (!(e instanceof ReferenceError)) throw e;
        \\}
        \\import C from "./entry.js";
        \\export default class {};
    );

    try evaluateSelfModule(
        \\import f from "./entry.js";
        \\if (f() !== 23) throw new Error("bad default function value");
        \\if (f.name !== "default") throw new Error("bad default function name");
        \\export default function() { return 23; }
    );

    try evaluateSelfModule(
        \\import { test262 as imp } from "./entry.js";
        \\if (test262 !== undefined) throw new Error("exported var was not hoisted");
        \\if (imp !== undefined) throw new Error("imported var was not hoisted");
        \\export var test262 = 23;
        \\if (test262 !== 23 || imp !== 23) throw new Error("exported var did not update");
    );
}

test "modules expose namespace re-exports and evaluate dependencies in source order" {
    try evaluateModuleWithFixtures(
        \\import * as ns from "./entry.js";
        \\export * as "All" from "./dep.js";
        \\if (ns.All["not-id"] !== globalThis.mark) throw new Error("missing namespace re-export");
    , &.{
        .{ .path = "dep.js", .source = "export { mark as \"not-id\" }; function mark() {} globalThis.mark = mark;" },
    });

    try evaluateModuleWithFixtures(
        \\if (globalThis.order !== "123") throw new Error(globalThis.order);
        \\import "./one.js";
        \\export {} from "./two.js";
        \\import "./three.js";
    , &.{
        .{ .path = "one.js", .source = "globalThis.order = '1';" },
        .{ .path = "two.js", .source = "globalThis.order += '2';" },
        .{ .path = "three.js", .source = "globalThis.order += '3';" },
    });

    try evaluateModuleWithFixtures(
        \\import val from "./dep.js";
        \\if (val() !== 1) throw new Error("bad call");
        \\if (val !== 2) throw new Error("default binding did not update");
    , &.{
        .{ .path = "dep.js", .source = "export default function fn() { fn = 2; return 1; }" },
    });
}

test "modules keep import.meta distinct per declaring module" {
    try evaluateModuleWithFixtures(
        \\import { meta as depMeta, getMeta } from "./dep.js";
        \\if (import.meta === depMeta) throw new Error("shared imported import.meta");
        \\if (import.meta === getMeta()) throw new Error("shared called import.meta");
        \\if (depMeta !== getMeta()) throw new Error("fixture import.meta was not stable");
    , &.{
        .{ .path = "dep.js", .source =
        \\export var meta = import.meta;
        \\export function getMeta() { return import.meta; }
        },
    });
}

test "modules bind source-phase imports as module source objects" {
    try evaluateModuleWithFixtures(
        \\import source direct from "<module source>";
        \\import { x } from "./reexport.js";
        \\import * as ns from "./reexport.js";
        \\if (!(direct instanceof $262.AbstractModuleSource)) throw new Error("bad direct source import");
        \\if (!(x instanceof $262.AbstractModuleSource)) throw new Error("bad named source re-export");
        \\if (!(ns.x instanceof $262.AbstractModuleSource)) throw new Error("bad namespace source re-export");
    , &.{
        .{ .path = "reexport.js", .source = "import source x from '<module source>'; export { x };" },
    });
}

test "modules create immutable namespace import bindings" {
    try evaluateSelfModule(
        \\import * as ns from "./entry.js";
        \\var original = ns;
        \\try {
        \\  ns = null;
        \\  throw new Error("namespace import assignment did not throw");
        \\} catch (e) {
        \\  if (!(e instanceof TypeError)) throw e;
        \\}
        \\if (ns !== original) throw new Error("namespace import binding changed");
        \\export var value = 1;
    );
}

test "modules keep self-imported default expressions in TDZ" {
    try evaluateModuleWithFixtures(
        \\try {
        \\  typeof dflt;
        \\  throw new Error("missing default TDZ");
        \\} catch (e) {
        \\  if (!(e instanceof ReferenceError)) throw e;
        \\}
        \\import dflt from "./entry.js";
        \\export default (function() {});
    , &.{});
}

test "modules initialize parenthesized named default class expressions" {
    try evaluateSelfModule(
        \\export default (class cName { valueOf() { return 45; } });
        \\import C from "./entry.js";
        \\if (new C().valueOf() !== 45) throw new Error("bad default class value");
        \\if (C.name !== "cName") throw new Error(C.name);
    );
}

test "modules omit ambiguous star exports from namespace objects" {
    try evaluateModuleWithFixtures(
        \\import * as ns from "./barrel.js";
        \\if (!("first" in ns)) throw new Error("missing first");
        \\if (!("second" in ns)) throw new Error("missing second");
        \\if ("both" in ns) throw new Error("ambiguous export was exposed");
    , &.{
        .{ .path = "barrel.js", .source = "export * from './one.js'; export * from './two.js';" },
        .{ .path = "one.js", .source = "export var first = 1; export var both = 1;" },
        .{ .path = "two.js", .source = "export var second = 2; export var both = 2;" },
    });
}

test "modules namespace exotica observe TDZ and integrity semantics" {
    try evaluateSelfModule(
        \\import * as ns from "./entry.js";
        \\try {
        \\  Object.keys(ns);
        \\  throw new Error("missing namespace TDZ");
        \\} catch (e) {
        \\  if (!(e instanceof ReferenceError)) throw e;
        \\}
        \\export default 0;
    );

    try evaluateSelfModule(
        \\import * as ns from "./entry.js";
        \\export var local1;
        \\var local2;
        \\export { local2 as renamed };
        \\export { local1 as indirect } from "./entry.js";
        \\if (!Reflect.defineProperty(ns, "indirect",
        \\    { writable: true, enumerable: true, configurable: false })) {
        \\  throw new Error("namespace no-op define failed");
        \\}
        \\try {
        \\  Object.freeze(ns);
        \\  throw new Error("namespace freeze should fail");
        \\} catch (e) {
        \\  if (!(e instanceof TypeError)) throw e;
        \\}
        \\if (Object.isFrozen(ns)) throw new Error("namespace reported frozen");
    );

    try evaluateSelfModule(
        \\import * as ns from "./entry.js";
        \\class A { constructor() { return ns; } }
        \\class B extends A { constructor() { super(); super.foo = 14; } }
        \\try {
        \\  new B();
        \\  throw new Error("missing namespace receiver TDZ");
        \\} catch (e) {
        \\  if (!(e instanceof ReferenceError)) throw e;
        \\}
        \\export let foo = 42;
    );

    try evaluateSelfModule(
        \\import * as ns from "./entry.js";
        \\var setterValue;
        \\class A {
        \\  constructor() { return ns; }
        \\  set foo(v) { setterValue = v; }
        \\}
        \\class B extends A { constructor() { super(); super.foo = 14; } }
        \\new B();
        \\if (setterValue !== 14) throw new Error("super setter not called");
        \\export let foo = 42;
    );
}

test "modules keep typed synthetic module cache entries distinct" {
    try evaluateSelfModule(
        \\import value from "./entry.js" with { type: "text" };
        \\if (typeof value !== "string") throw new Error("bad text self import");
    );
}

test "modules import bytes as immutable Uint8Array" {
    const raw = [_]u8{ 0, 65, 255 };
    try evaluateModuleWithFixtures(
        \\import bytes from "./blob.bin" with { type: "bytes" };
        \\if (!(bytes instanceof Uint8Array)) throw new Error("not a Uint8Array");
        \\if (!(bytes.buffer instanceof ArrayBuffer)) throw new Error("not an ArrayBuffer");
        \\if (bytes.length !== 3 || bytes[0] !== 0 || bytes[1] !== 65 || bytes[2] !== 255) {
        \\  throw new Error("bad bytes");
        \\}
        \\if (bytes.buffer.byteLength !== 3 || bytes.buffer.immutable !== true) throw new Error("buffer not immutable");
        \\try {
        \\  bytes.buffer.transfer();
        \\  throw new Error("immutable transfer did not throw");
        \\} catch (e) {
        \\  if (!(e instanceof TypeError)) throw e;
        \\}
    , &.{.{ .path = "blob.bin", .source = raw[0..] }});
}

test "Date basics" {
    // Components constructor (month is 0-based) + UTC getters.
    try std.testing.expectEqual(@as(f64, 2020), (try evalIn("new Date(2020, 0, 15).getUTCFullYear()")).asNum());
    try std.testing.expectEqual(@as(f64, 0), (try evalIn("new Date(2020, 0, 15).getUTCMonth()")).asNum());
    try std.testing.expectEqual(@as(f64, 15), (try evalIn("new Date(2020, 0, 15).getUTCDate()")).asNum());
    // Epoch round-trips.
    try std.testing.expectEqual(@as(f64, 0), (try evalIn("new Date(0).getTime()")).asNum());
    try std.testing.expectEqual(@as(f64, 1970), (try evalIn("new Date(0).getUTCFullYear()")).asNum());
    try expectEvalStr("number", "typeof Date.now()");
    try expectEvalStr("1970-01-01T00:00:00.000Z", "new Date(0).toISOString()");
    try std.testing.expect((try evalIn("typeof new Date() === 'object'")).asBool());
}

test "Date.now progresses for host timers" {
    const ctx = try Context.create(std.testing.allocator);
    defer ctx.destroy();

    _ = try ctx.evaluate(
        \\var start = Date.now();
        \\setTimeout(function() {
        \\  globalThis.dateNowProgressed = Date.now() >= start;
        \\}, 1);
    );
    try std.testing.expect((try ctx.evaluate("dateNowProgressed")).asBool());
}

test "String generics + .constructor + match/search" {
    // String.prototype method on a non-string this (coerced).
    try expectEvalStr("123", "String.prototype.trim.call(123)");
    try std.testing.expectEqual(@as(f64, 2), (try evalIn("String.prototype.indexOf.call(12345, '3')")).asNum());
    // .constructor falls back to the kind's global.
    try std.testing.expect((try evalIn("[].constructor === Array")).asBool());
    try std.testing.expect((try evalIn("({}).constructor === Object")).asBool());
    try std.testing.expect((try evalIn("'x'.constructor === String")).asBool());
    try std.testing.expect((try evalIn("(5).constructor === Number")).asBool());
    // search / match.
    try std.testing.expectEqual(@as(f64, 2), (try evalIn("'abcd'.search(/cd/)")).asNum());
    try std.testing.expect((try evalIn("'hello'.match(/l+/)[0] === 'll'")).asBool());
    try expectEvalStr("abc", "'abc'.normalize()");
}

test "Array.prototype generics on array-likes" {
    try std.testing.expectEqual(@as(f64, 6), (try evalIn(
        \\var o = { length: 3, 0: 1, 1: 2, 2: 3 };
        \\Array.prototype.reduce.call(o, function (a, b) { return a + b; }, 0)
    )).asNum());
    try std.testing.expectEqual(@as(f64, 1), (try evalIn(
        \\var o = { length: 3, 0: 'a', 1: 'b', 2: 'c' };
        \\Array.prototype.indexOf.call(o, 'b')
    )).asNum());
    try expectEvalStr("a-b-c",
        \\var o = { length: 3, 0: 'a', 1: 'b', 2: 'c' };
        \\Array.prototype.join.call(o, '-')
    );
    try std.testing.expect((try evalIn(
        \\var o = { length: 2, 0: 10, 1: 20 };
        \\Array.prototype.every.call(o, function (x) { return x >= 10; })
    )).asBool());
    try std.testing.expect((try evalIn(
        \\var hit = false;
        \\var p = new Proxy({ length: 1, 0: 42 }, {
        \\  has: function () { hit = true; throw new Error("has"); }
        \\});
        \\try { Array.prototype.copyWithin.call(p, 0, 0); false; }
        \\catch (e) { hit && e.message === "has"; }
    )).asBool());
    try std.testing.expect((try evalIn(
        \\function StopReverse() {}
        \\var o = { length: 2 ** 53 + 2 };
        \\Object.defineProperty(o, "9007199254740990", {
        \\  get: function () { throw new StopReverse(); }
        \\});
        \\try { Array.prototype.reverse.call(o); false; }
        \\catch (e) { e instanceof StopReverse; }
    )).asBool());
    try std.testing.expect((try evalIn(
        \\function StopUnshift() {}
        \\var o = { length: 2 ** 53 - 2 };
        \\Object.defineProperty(o, "9007199254740986", {
        \\  get: function () { throw new StopUnshift(); }
        \\});
        \\o["9007199254740987"] = "hi";
        \\try { Array.prototype.unshift.call(o, null); false; }
        \\catch (e) { e instanceof StopUnshift && o["9007199254740988"] === "hi"; }
    )).asBool());
    try std.testing.expectEqual(@as(f64, 9007199254740991), (try evalIn(
        \\var o = { length: Infinity };
        \\Array.prototype.unshift.call(o);
        \\o.length
    )).asNum());
    try expectEvalStr("hi,there",
        \\var o = { length: 2 ** 53 + 2 };
        \\o["9007199254740989"] = "hi";
        \\o["9007199254740990"] = "there";
        \\Array.prototype.slice.call(o, -2).join(",")
    );
    try expectEvalStr("RangeError|0",
        \\var array = [];
        \\var callCount = 0;
        \\var proxy = new Proxy(array, {
        \\  get: function(_, name) {
        \\    if (name === "length") return Math.pow(2, 32);
        \\    return array[name];
        \\  },
        \\  set: function() {
        \\    callCount += 1;
        \\    return true;
        \\  }
        \\});
        \\try {
        \\  Array.prototype.splice.call(proxy, 0);
        \\  "no throw";
        \\} catch (e) {
        \\  e.name + "|" + callCount;
        \\}
    );
    try expectEvalStr("TypeError",
        \\var A = function(_length) {
        \\  this.length = 0;
        \\  Object.preventExtensions(this);
        \\};
        \\var arr = [1];
        \\arr.constructor = {};
        \\arr.constructor[Symbol.species] = A;
        \\try {
        \\  arr.splice(0);
        \\  "no throw";
        \\} catch (e) {
        \\  e.name;
        \\}
    );
    try std.testing.expect((try evalIn(
        \\Array.prototype[1] = 17;
        \\var a = [3];
        \\a.length = 2;
        \\var first = a.shift();
        \\delete Array.prototype[1];
        \\first === 3 && a[0] === 17 && a[1] === undefined
    )).asBool());
    try std.testing.expect((try evalIn(
        \\try { Array.prototype.shift.call(Object.defineProperty({}, "length", { writable: false })); false; }
        \\catch (e) { e instanceof TypeError; }
    )).asBool());
}

test "array instances inherit from Array.prototype (incl. holes)" {
    try std.testing.expect((try evalIn("Object.getPrototypeOf([]) === Array.prototype")).asBool());
    try std.testing.expect((try evalIn("[].map === Array.prototype.map")).asBool());
    // A hole reads through the prototype chain (inherited index), so an
    // accessor installed on Array.prototype is seen by index access + iteration.
    try std.testing.expectEqual(@as(f64, 11), (try evalIn(
        \\Object.defineProperty(Array.prototype, "0", { get: function () { return 11; }, configurable: true });
        \\[, , ,][0]
    )).asNum());
    try std.testing.expect((try evalIn(
        \\Object.defineProperty(Array.prototype, "0", { get: function () { return 11; }, configurable: true });
        \\var r = false; [, , ,].forEach(function (v, i) { if (i === 0) r = (v === 11); }); r
    )).asBool());
    // Ordinary arrays are unaffected: a real hole with no inherited index is undefined.
    try std.testing.expect((try evalIn("[1, , 3][1] === undefined")).asBool());
    try std.testing.expectEqual(@as(f64, 2), (try evalIn("[1, 2, 3][1]")).asNum());
    try std.testing.expect((try evalIn(
        \\var hit = 0;
        \\try {
        \\  Object.defineProperty(Array.prototype, "0", { set: function (v) { hit = v; }, configurable: true });
        \\  var a = [];
        \\  a[0] = 7;
        \\  hit === 7 && a.length === 0 && !Object.prototype.hasOwnProperty.call(a, "0");
        \\} finally {
        \\  delete Array.prototype[0];
        \\}
    )).asBool());
    try expectEvalStr("0|false|1",
        \\try {
        \\  Object.defineProperty(Array.prototype, "0", { value: 1, writable: false, configurable: true });
        \\  var a = [];
        \\  a[0] = 7;
        \\  a.length + "|" + Object.prototype.hasOwnProperty.call(a, "0") + "|" + a[0];
        \\} finally {
        \\  delete Array.prototype[0];
        \\}
    );
    try expectEvalStr("seed|1|true|local",
        \\var proto = ["seed"];
        \\var a = [];
        \\Object.setPrototypeOf(a, proto);
        \\var before = a[0];
        \\a[0] = "local";
        \\before + "|" + a.length + "|" + Object.prototype.hasOwnProperty.call(a, "0") + "|" + a[0];
    );
}

test "Array / Object constructors" {
    try std.testing.expectEqual(@as(f64, 3), (try evalIn("new Array(3).length")).asNum());
    try std.testing.expectEqual(@as(f64, 2), (try evalIn("Array(1, 2).length")).asNum());
    try std.testing.expectEqual(@as(f64, 7), (try evalIn("var a = new Array(5, 6, 7); a[2]")).asNum());
    try expectEvalStr("function", "typeof Array");
    try std.testing.expect((try evalIn("var o = new Object(); typeof o === 'object'")).asBool());
    try std.testing.expect((try evalIn("var x = {}; Object(x) === x")).asBool());
    // Invalid array length throws RangeError.
    try std.testing.expect((try evalIn("var t = false; try { new Array(-1); } catch (e) { t = e.name === 'RangeError'; } t")).asBool());
}

test "destructuring catch parameter" {
    try std.testing.expectEqual(@as(f64, 3), (try evalIn(
        \\var r = 0;
        \\try { throw { a: 1, b: 2 }; } catch ({ a, b }) { r = a + b; }
        \\r
    )).asNum());
    try std.testing.expectEqual(@as(f64, 30), (try evalIn(
        \\var r = 0;
        \\try { throw [10, 20]; } catch ([x, y]) { r = x + y; }
        \\r
    )).asNum());
}

test "Array.from with iterables + map fn" {
    try std.testing.expectEqual(@as(f64, 6), (try evalIn(
        \\function* g() { yield 1; yield 2; yield 3; }
        \\Array.from(g()).length + 3
    )).asNum());
    try std.testing.expectEqual(@as(f64, 12), (try evalIn("Array.from([1,2,3], function(x){return x*2;}).reduce(function(a,b){return a+b;},0)")).asNum());
    try std.testing.expectEqual(@as(f64, 3), (try evalIn("Array.from('abc').length")).asNum());
    try std.testing.expectEqual(@as(f64, 2), (try evalIn("Array.from({length: 2}).length")).asNum());
}

test "spread of iterables (generator, string, user iterator)" {
    try std.testing.expectEqual(@as(f64, 6), (try evalIn(
        \\function* g() { yield 1; yield 2; yield 3; }
        \\var a = [...g()]; a[0] + a[1] + a[2]
    )).asNum());
    try std.testing.expectEqual(@as(f64, 3), (try evalIn("[...'abc'].length")).asNum());
    // Spread feeding a call.
    try std.testing.expectEqual(@as(f64, 6), (try evalIn(
        \\function add(a, b, c) { return a + b + c; }
        \\add(...[1, 2, 3])
    )).asNum());
}

test "Symbol: typeof, identity, description, property keys, iterator" {
    try expectEvalStr("symbol", "typeof Symbol()");
    try std.testing.expect((try evalIn("var s = Symbol(); s === s && Symbol() !== Symbol()")).asBool());
    try expectEvalStr("d", "Symbol('d').description");
    try expectEvalStr("symbol", "typeof Symbol.iterator");
    // Symbol-keyed property: works, but invisible to string enumeration.
    try std.testing.expectEqual(@as(f64, 5), (try evalIn(
        \\var s = Symbol(); var o = { a: 1 }; o[s] = 5;
        \\o[s]
    )).asNum());
    try std.testing.expectEqual(@as(f64, 1), (try evalIn(
        \\var s = Symbol(); var o = { a: 1 }; o[s] = 5;
        \\Object.keys(o).length
    )).asNum());
    // User iterator via Symbol.iterator drives for-of.
    try std.testing.expectEqual(@as(f64, 3), (try evalIn(
        \\var obj = {};
        \\obj[Symbol.iterator] = function () {
        \\  var i = 0;
        \\  return { next: function () { return i < 3 ? { value: i++, done: false } : { value: undefined, done: true }; } };
        \\};
        \\var s = 0; for (var x of obj) { s += x; } s
    )).asNum());
}

test "array literal elision (holes)" {
    try std.testing.expectEqual(@as(f64, 3), (try evalIn("var a = [1, , 3]; a.length")).asNum());
    try std.testing.expectEqual(@as(f64, 4), (try evalIn("var a = [, , 4]; a[2]")).asNum());
    // Elision in array destructuring assignment.
    try std.testing.expectEqual(@as(f64, 2), (try evalIn("var a, b; [, a, , b] = [1, 2, 3, 4]; a")).asNum());
    try std.testing.expectEqual(@as(f64, 4), (try evalIn("var a, b; [, a, , b] = [1, 2, 3, 4]; b")).asNum());
}

test "new.target" {
    // undefined in a plain call, the constructor under `new`.
    try std.testing.expect((try evalIn(
        \\function F() { return new.target === F; }
        \\F() === false && new F() instanceof F
    )).asBool());
    try std.testing.expectEqual(@as(f64, 1), (try evalIn(
        \\var hit = 0;
        \\function F() { if (new.target) hit = 1; }
        \\new F(); hit
    )).asNum());
}

test "object spread" {
    try std.testing.expectEqual(@as(f64, 6), (try evalIn(
        \\var base = { a: 1, b: 2 };
        \\var o = { ...base, c: 3 };
        \\o.a + o.b + o.c
    )).asNum());
    // Later properties override earlier spread ones.
    try std.testing.expectEqual(@as(f64, 9), (try evalIn("var o = { x: 1, ...{ x: 9 } }; o.x")).asNum());
    // Spreading null/undefined is a no-op.
    try std.testing.expectEqual(@as(f64, 1), (try evalIn("var o = { ...null, ...undefined, a: 1 }; o.a")).asNum());
    try std.testing.expect((try evalIn(
        \\var sym = Symbol("foo");
        \\var src = {};
        \\src[sym] = 7;
        \\var out = { ...src, a: 1 };
        \\out[sym] === 7 && Object.keys(out).join(",") === "a" && Reflect.ownKeys(out)[1] === sym
    )).asBool());
    try std.testing.expect((try evalIn(
        \\var calls = [];
        \\var sym = Symbol("foo");
        \\var src = { get z() { calls.push("z"); }, get a() { calls.push("a"); } };
        \\Object.defineProperty(src, 1, { get: function() { calls.push("1"); }, enumerable: true });
        \\Object.defineProperty(src, sym, { get: function() { calls.push("sym"); }, enumerable: true });
        \\var out = { ...src };
        \\calls.join(",") === "1,z,a,sym" && out[sym] === undefined
    )).asBool());
}

test "delete operator" {
    try std.testing.expect((try evalIn(
        \\var o = { a: 1, b: 2 };
        \\var ok = delete o.a;
        \\ok && !("a" in o) && o.b === 2
    )).asBool());
    // Non-configurable property can't be deleted.
    try std.testing.expect((try evalIn(
        \\var o = {};
        \\Object.defineProperty(o, "x", { value: 1, configurable: false });
        \\var r = delete o.x;
        \\!r && ("x" in o)
    )).asBool());
    // delete of a non-reference / missing property is true.
    try std.testing.expect((try evalIn("delete 1 && delete {}.nope")).asBool());
}

test "for-of / for-in with destructuring + member targets" {
    try std.testing.expectEqual(@as(f64, 10), (try evalIn(
        \\var s = 0; for (const [a, b] of [[1, 2], [3, 4]]) { s += a + b; } s
    )).asNum());
    try std.testing.expectEqual(@as(f64, 3), (try evalIn(
        \\var s = 0; for (const { x } of [{ x: 1 }, { x: 2 }]) { s += x; } s
    )).asNum());
    // Assignment form with a member target.
    try std.testing.expectEqual(@as(f64, 7), (try evalIn(
        \\var o = {}; for (o.k of [5, 6, 7]) {} o.k
    )).asNum());
    // Plain identifier (regression) + for-in still work.
    try expectEvalStr("ab",
        \\var r = ""; for (var k in { a: 1, b: 2 }) { r += k; } r
    );
}

test "empty statements + class-declaration sequencing" {
    // A `;` after a class declaration (and stray `;`) no longer breaks the
    // following statements.
    try std.testing.expectEqual(@as(f64, 2), (try evalIn(
        \\class C { m() { return 2; } };
        \\var c = new C();
        \\c.m()
    )).asNum());
    try std.testing.expectEqual(@as(f64, 5), (try evalIn(";;; var x = 5;;; x")).asNum());
    try std.testing.expectEqual(@as(f64, 2), (try evalIn(
        \\class C { [1.1]() { return 2; } static [1.1]() { return 2; } };
        \\var c = new C();
        \\c[1.1]()
    )).asNum());
}

test "context persists globals across evaluations" {
    const ctx = try Context.create(std.testing.allocator);
    defer ctx.destroy();
    _ = try ctx.evaluate("var counter = 41;");
    const v = try ctx.evaluate("counter = counter + 1;");
    try std.testing.expectEqual(@as(f64, 42), v.asNum());
    try std.testing.expect((try ctx.evaluate("Object.getPrototypeOf(globalThis).isPrototypeOf(globalThis)")).asBool());
}

test "direct eval keeps lexical declarations local but hoists var" {
    const ctx = try Context.create(std.testing.allocator);
    defer ctx.destroy();

    try std.testing.expect((try ctx.evaluate(
        \\let outside = 23;
        \\eval('let outside;');
        \\eval('"use strict"; let strictOnly = 3;');
        \\eval('var visible = 5;');
        \\typeof strictOnly === 'undefined' && visible === 5 && outside === 23
    )).asBool());
}

test "primitive property assignment observes inherited proxy setters" {
    try std.testing.expect((try evalIn(
        \\var numberCount = 0, stringCount = 0, booleanCount = 0, symbolCount = 0;
        \\Object.setPrototypeOf(Number.prototype, new Proxy({}, { set: function() { numberCount += 1; return true; } }));
        \\0..test262 = null;
        \\Object.setPrototypeOf(String.prototype, new Proxy({}, { set: function() { stringCount += 1; return true; } }));
        \\"".test262 = null;
        \\Object.setPrototypeOf(Boolean.prototype, new Proxy({}, { set: function() { booleanCount += 1; return true; } }));
        \\true.test262 = null;
        \\Object.setPrototypeOf(Symbol.prototype, new Proxy({}, { set: function() { symbolCount += 1; return true; } }));
        \\Symbol().test262 = null;
        \\numberCount === 1 && stringCount === 1 && booleanCount === 1 && symbolCount === 1
    )).asBool());
}

test "primitive property retrieval walks wrapper prototypes" {
    try std.testing.expect((try evalIn(
        \\Number.prototype.test262 = "number prototype";
        \\String.prototype.test262 = "string prototype";
        \\Boolean.prototype.test262 = "boolean prototype";
        \\Symbol.prototype.test262 = "symbol prototype";
        \\1..test262 === "number prototype" &&
        \\"".test262 === "string prototype" &&
        \\true.test262 === "boolean prototype" &&
        \\Symbol().test262 === "symbol prototype"
    )).asBool());
}

test "indirect eval uses the callee realm global" {
    try std.testing.expect((try evalIn(
        \\var other = $262.createRealm().global;
        \\other.Number.prototype.test262 = "number prototype";
        \\other.value = 1;
        \\var numberOk = other.eval("value.test262") === "number prototype";
        \\other.Symbol.prototype.test262 = "symbol prototype";
        \\other.value = Symbol();
        \\numberOk && other.eval("value.test262") === "symbol prototype"
    )).asBool());
}

test "delete distinguishes var bindings from sloppy global properties" {
    try std.testing.expect((try evalIn(
        \\var declared = {};
        \\undeclared = {};
        \\delete declared === false &&
        \\typeof declared === "object" &&
        \\delete undeclared === true &&
        \\typeof undeclared === "undefined"
    )).asBool());
}

test "RegExp.escape escapes pattern text" {
    try expectEvalStr("\\x61bc", "RegExp.escape('abc')");
    try expectEvalStr("\\x61\\.b\\/c\\x2dd", "RegExp.escape('a.b/c-d')");
    try expectEvalStr("\\n\\x20\\xa0\\u2028", "RegExp.escape('\\n \\u00a0\\u2028')");
    try expectEvalStr("\x00", "RegExp.escape('\\0')");
    try expectEvalStr("\\ud800", "RegExp.escape('\\ud800')");
    try expectEvalStr("\u{10000}", "RegExp.escape('\\ud800\\udc00')");
    try std.testing.expect((try evalIn(
        \\try { RegExp.escape(123); false } catch (e) { e.name === "TypeError" }
    )).asBool());
}

test "RegExp source and toString escape line terminators canonically" {
    try std.testing.expect((try evalIn(
        \\function same(re, source) {
        \\  return re.source === source &&
        \\    eval("/" + re.source + "/").source === source &&
        \\    re.toString() === "/" + source + "/";
        \\}
        \\same(/\\n/, "\\\\n") &&
        \\same(RegExp("\\n"), "\\n") &&
        \\same(RegExp("\\\n"), "\\n") &&
        \\same(RegExp("/"), "\\/") &&
        \\same(RegExp("\\/"), "\\/") &&
        \\same(/[/]/, "[/]") &&
        \\same(/[\/]/, "[\\/]")
    )).asBool());
}

test "RegExp flags and toString use generic canonical accessors" {
    try std.testing.expect((try evalIn(
        \\/foo/igym.flags === "gimy" &&
        \\/foo/igym.toString() === "/foo/gimy" &&
        \\Object.getOwnPropertyDescriptor(RegExp.prototype, "flags").get.call({ sticky: 1, unicode: 1, global: 0 }) === "uy" &&
        \\Object.getOwnPropertyDescriptor(RegExp.prototype, "flags").get.call({ __proto__: { multiline: true } }) === "m" &&
        \\RegExp.prototype.toString.call({ source: "foo", flags: "bar" }) === "/foo/bar" &&
        \\(function(get) {
        \\  var symbolThrows = false;
        \\  try { get.call(Symbol()); } catch (e) { symbolThrows = e.name === "TypeError"; }
        \\  var bigintThrows = false;
        \\  try { get.call(4n); } catch (e) { bigintThrows = e.name === "TypeError"; }
        \\  return symbolThrows && bigintThrows;
        \\})(Object.getOwnPropertyDescriptor(RegExp.prototype, "flags").get)
    )).asBool());
}

test "RegExp accessors use their own realm prototype" {
    try std.testing.expect((try evalIn(
        \\var other = $262.createRealm().global;
        \\var mainProto = RegExp.prototype;
        \\var otherProto = other.RegExp.prototype;
        \\var mainUnicode = Object.getOwnPropertyDescriptor(mainProto, "unicode").get;
        \\var otherUnicode = Object.getOwnPropertyDescriptor(otherProto, "unicode").get;
        \\var mainSource = Object.getOwnPropertyDescriptor(mainProto, "source").get;
        \\var otherSource = Object.getOwnPropertyDescriptor(otherProto, "source").get;
        \\var ownDefaults = mainUnicode.call(mainProto) === undefined &&
        \\  otherUnicode.call(otherProto) === undefined &&
        \\  mainSource.call(mainProto) === "(?:)" &&
        \\  otherSource.call(otherProto) === "(?:)";
        \\var mainThrow = false;
        \\try { mainUnicode.call(otherProto); } catch (e) { mainThrow = e.constructor === TypeError; }
        \\var otherThrow = false;
        \\try { otherUnicode.call(mainProto); } catch (e) { otherThrow = e.constructor === other.TypeError; }
        \\ownDefaults && mainThrow && otherThrow
    )).asBool());
}

test "RegExp exec coerces and preserves lastIndex per spec" {
    try std.testing.expect((try evalIn(
        \\var called = 0;
        \\var r = /./;
        \\r.lastIndex = { valueOf: function() { called += 1; return 0; } };
        \\r.exec(".");
        \\r.lastIndex = { toString: function() { called += 1; return "0"; } };
        \\r.exec(".");
        \\r.lastIndex = { valueOf: function() { called += 1; return 0; }, toString: function() { called -= 10; } };
        \\r.exec(".");
        \\called === 3 && typeof r.lastIndex === "object"
    )).asBool());
}

test "RegExp lastIndex writes throw when non-writable" {
    try std.testing.expect((try evalIn(
        \\var r = /0/g;
        \\Object.freeze(r);
        \\var testThrow = false;
        \\try { r.test("abc000"); } catch (e) { testThrow = e.name === "TypeError"; }
        \\var execThrow = false;
        \\try { r.exec("abc000"); } catch (e) { execThrow = e.name === "TypeError"; }
        \\testThrow && execThrow && r.lastIndex === 0
    )).asBool());
}

test "RegExp compile mutates before throwing on non-writable lastIndex" {
    try std.testing.expect((try evalIn(
        \\var r = /foo/i;
        \\Object.defineProperty(r, "lastIndex", { value: 42, writable: false });
        \\var threw = false;
        \\try { r.compile("^bar", "m"); } catch (e) { threw = e.name === "TypeError"; }
        \\threw && r.source === "^bar" && r.multiline === true && r.ignoreCase === false &&
        \\r.lastIndex === 42 && r.test("x\nbar") === true
    )).asBool());
}

test "RegExp generic exec dispatch validates protocol results" {
    try std.testing.expect((try evalIn(
        \\var obj = { exec: function(s) { return function(){}; } };
        \\var testOk = RegExp.prototype.test.call(obj, "") === true;
        \\var re = /a/;
        \\re.exec = null;
        \\var regexpFallback = RegExp.prototype[Symbol.match].call(re, "foo") === null;
        \\var nonCallableThrow = false;
        \\try { RegExp.prototype[Symbol.match].call({ exec: null }, "foo"); }
        \\catch (e) { nonCallableThrow = e.name === "TypeError"; }
        \\var ret = {};
        \\var objectReturn = RegExp.prototype[Symbol.match].call({
        \\  get global() { return false; },
        \\  exec: function(s) { return ret; }
        \\}, "foo") === ret;
        \\var primitiveThrow = false;
        \\try {
        \\  RegExp.prototype[Symbol.match].call({
        \\    get global() { return false; },
        \\    exec: function(s) { return 1; }
        \\  }, "foo");
        \\} catch (e) { primitiveThrow = e.name === "TypeError"; }
        \\var symbolThrow = false;
        \\try {
        \\  RegExp.prototype[Symbol.match].call({
        \\    get global() { return false; },
        \\    exec: function(s) { return Symbol.iterator; }
        \\  }, "foo");
        \\} catch (e) { symbolThrow = e.name === "TypeError"; }
        \\testOk && regexpFallback && nonCallableThrow && objectReturn && primitiveThrow && symbolThrow
    )).asBool());
}

test "RegExp search uses generic exec and restores lastIndex" {
    try std.testing.expect((try evalIn(
        \\var log = "";
        \\var old = {};
        \\var li = old;
        \\var rx = {
        \\  get lastIndex() { log += "get:lastIndex,"; return li; },
        \\  set lastIndex(v) { li = v; log += v === 0 ? "set:zero," : "set:old,"; },
        \\  get exec() {
        \\    log += "get:exec,";
        \\    return function(s) { log += "call:exec,"; return { index: 3 }; };
        \\  }
        \\};
        \\var hit = RegExp.prototype[Symbol.search].call(rx, "abcdef") === 3;
        \\var nonObjectThrow = false;
        \\try { RegExp.prototype[Symbol.search].call(Symbol.iterator, "x"); }
        \\catch (e) { nonObjectThrow = e.name === "TypeError"; }
        \\hit && nonObjectThrow &&
        \\log === "get:lastIndex,set:zero,get:exec,call:exec,get:lastIndex,set:old,"
    )).asBool());
}

test "RegExp match reads flags and observes lastIndex recompilation" {
    try std.testing.expect((try evalIn(
        \\var log = "";
        \\var rx = {
        \\  get flags() { log += "flags,"; return "g"; },
        \\  set lastIndex(v) { log += "set:" + v + ","; },
        \\  get exec() {
        \\    return function(s) { return n++ === 0 ? ["x"] : null; };
        \\  }
        \\};
        \\var n = 0;
        \\var matched = RegExp.prototype[Symbol.match].call(rx, "x")[0] === "x";
        \\var r = /a/;
        \\r.lastIndex = { valueOf: function() { r.compile("a", "g"); return 0; } };
        \\r[Symbol.match]("a");
        \\matched && log === "flags,set:0," && r.lastIndex === 1
    )).asBool());
}

test "RegExp replace uses generic exec and UTF-16 positions" {
    try std.testing.expect((try evalIn(
        \\var n = 0;
        \\var log = "";
        \\var target = "---\uD83D\uDC38";
        \\var rx = {
        \\  get flags() { log += "flags,"; return "gu"; },
        \\  unicode: true,
        \\  get lastIndex() { return [, 3, 4][n]; },
        \\  set lastIndex(v) {
        \\    log += "set:" + v + ",";
        \\    if (v !== [0, 5, 5][n]) throw new Error("bad lastIndex");
        \\  },
        \\  get exec() {
        \\    return function(s) {
        \\      if (s !== target) throw new Error("bad target");
        \\      return n++ < 2 ? { 0: "", length: 1, index: 0, groups: undefined } : null;
        \\    };
        \\  }
        \\};
        \\RegExp.prototype[Symbol.replace].call(rx, target, "_");
        \\log === "flags,set:0,set:5,set:5,"
    )).asBool());
    try std.testing.expect((try evalIn(
        \\var args;
        \\var rx2 = {
        \\  flags: "",
        \\  exec: function() { return { 0: "BC", 1: "B", length: 2, index: 1, groups: { name: "B" } }; }
        \\};
        \\RegExp.prototype[Symbol.replace].call(rx2, "aBC", function() { args = arguments; return "_"; });
        \\args.length === 5 && args[0] === "BC" && args[1] === "B" &&
        \\args[2] === 1 && args[3] === "aBC" && args[4].name === "B"
    )).asBool());
    try std.testing.expect((try evalIn(
        \\var rx3 = {
        \\  flags: "",
        \\  exec: function() { return { 0: "x", length: 1, index: 0, groups: { a: "A" } }; }
        \\};
        \\RegExp.prototype[Symbol.replace].call(rx3, "x", "$<a>$&") === "Ax"
    )).asBool());
    try std.testing.expect((try evalIn(
        \\var rx4 = {
        \\  flags: "",
        \\  exec: function() { return { 0: "", length: 1, index: 0, groups: null }; }
        \\};
        \\try { RegExp.prototype[Symbol.replace].call(rx4, "x", ""); false }
        \\catch (e) { e.name === "TypeError" }
    )).asBool());
    try std.testing.expect((try evalIn(
        \\var rx5 = /./g;
        \\var called = false;
        \\rx5.exec = function() {
        \\  if (called) return null;
        \\  rx5.lastIndex = { valueOf: function() { return Math.pow(2, 54); } };
        \\  called = true;
        \\  return { 0: "", length: 1, index: 0 };
        \\};
        \\rx5[Symbol.replace]("", "") === "" &&
        \\  rx5.lastIndex === Math.pow(2, 53)
    )).asBool());
    try std.testing.expect((try evalIn(
        \\var r = /^|\udf06/g;
        \\Object.defineProperty(r, "unicode", { writable: true });
        \\r.unicode = undefined;
        \\r[Symbol.replace]("\ud834\udf06", "XXX") === "XXX\ud834XXX"
    )).asBool());
}

test "RegExp builtin exec exposes UTF-16 positions" {
    try std.testing.expect((try evalIn(
        \\var s = "\ud834\udf06";
        \\var trueUnicode = /^|\udf06/ug[Symbol.replace](s, "X") === "X\ud834\udf06";
        \\var rx = /./dgu;
        \\var m = rx.exec(s);
        \\trueUnicode &&
        \\  rx.lastIndex === 2 &&
        \\  m.index === 0 &&
        \\  m.indices[0][0] === 0 &&
        \\  m.indices[0][1] === 2
    )).asBool());
}

test "JSON stringify preserves proxy array shape" {
    try expectEvalStr("[\"a\",\"b\"]", "JSON.stringify(new Proxy(['a', 'b'], {}))");
}

test "RegExp constructor honors IsRegExp and flags rules" {
    try std.testing.expect((try evalIn(
        \\var re = /foo/my;
        \\var same = RegExp(re) === re;
        \\re.constructor = function() {};
        \\var copied = RegExp(re);
        \\var obj = { [Symbol.match]: true, source: "bar", flags: "i" };
        \\var fromLike = RegExp(obj).toString() === "/bar/i";
        \\obj.constructor = RegExp;
        \\var returnedLike = RegExp(obj) === obj;
        \\var compileOk = /a/.compile(/b/my).flags === "my";
        \\var compileThrow = false;
        \\try { /a/.compile(/b/my, "g"); } catch (e) { compileThrow = e.name === "TypeError"; }
        \\same && copied !== re && copied.toString() === "/foo/my" &&
        \\fromLike && returnedLike && compileOk && compileThrow
    )).asBool());
}

test "object literal __proto__ sets ordinary object prototype" {
    try std.testing.expect((try evalIn(
        \\var p = { marker: 1 };
        \\var o = { __proto__: p };
        \\var n = { __proto__: null };
        \\o.marker === 1 && !o.hasOwnProperty("marker") &&
        \\Object.getPrototypeOf(o) === p &&
        \\Object.getPrototypeOf(n) === null
    )).asBool());
}

test "RegExp duplicate named captures use participating group" {
    try std.testing.expect((try evalIn(
        \\var m = /(?:(?:(?<a>x)|(?<a>y))\k<a>){2}/.exec("xxyy");
        \\m[0] === "xxyy" && m[1] === undefined && m[2] === "y" &&
        \\m.groups.a === "y" &&
        \\"xxyy".replace(/(?:(?:(?<a>x)|(?<a>y))\k<a>)/, "2$<a>") === "2xyy"
    )).asBool());
}

test "ShadowRealm uses ordinary globals and caller realm wrappers" {
    try std.testing.expect((try evalIn(
        \\var r = new ShadowRealm();
        \\r.evaluate('Object.getPrototypeOf(globalThis) === Object.prototype') &&
        \\r.evaluate('globalThis.constructor === Object') &&
        \\Object.getPrototypeOf(r.evaluate('() => 1')) === Function.prototype
    )).asBool());
}

test "ShadowRealm evaluate wraps child abrupt completions" {
    try expectEvalStr("SyntaxError|TypeError|TypeError|TypeError|TypeError|TypeError",
        \\var r = new ShadowRealm();
        \\function caught(src) {
        \\  try { r.evaluate(src); return "none"; }
        \\  catch (e) { return e.name; }
        \\}
        \\[
        \\  caught("..."),
        \\  caught("throw 42"),
        \\  caught("throw new ReferenceError('aaa')"),
        \\  caught("throw new TypeError('aaa')"),
        \\  caught("eval('...')"),
        \\  caught("'use strict'; eval('var public = 1;')")
        \\].join("|")
    );
}

test "ShadowRealm constructor metadata" {
    try std.testing.expect((try evalIn(
        \\var d = Object.getOwnPropertyDescriptor(ShadowRealm, "name");
        \\var before = ShadowRealm.name;
        \\ShadowRealm.name = "unlikelyValue";
        \\var still = ShadowRealm.name === before;
        \\var deleted = delete ShadowRealm.name;
        \\d.value === "ShadowRealm" && d.enumerable === false &&
        \\d.writable === false && d.configurable === true &&
        \\still && deleted && !Object.hasOwn(ShadowRealm, "name")
    )).asBool());
}

test "ShadowRealm wrapped function length descriptors" {
    try expectEvalStr("2|0|Infinity|0|0",
        \\var r = new ShadowRealm();
        \\function len(src) {
        \\  var wrapped = r.evaluate(src);
        \\  var d = Object.getOwnPropertyDescriptor(wrapped, "length");
        \\  return d.value + ":" + d.enumerable + ":" + d.writable + ":" + d.configurable;
        \\}
        \\[
        \\  len("function fn(foo, bar) {} fn;"),
        \\  len("function fn() {} delete fn.length; fn;"),
        \\  len("function fn() {} Object.defineProperty(fn, 'length', { get: () => Infinity, configurable: true }); fn;"),
        \\  len("function fn() {} Object.defineProperty(fn, 'length', { get: () => -Infinity, configurable: true }); fn;"),
        \\  len("function fn() {} Object.defineProperty(fn, 'length', { get: () => -1, configurable: true }); fn;")
        \\].map(function (x) { return x.split(":")[0]; }).join("|")
    );
}

test "ShadowRealm symbol values use caller realm wrappers" {
    try expectEvalStr("11111111",
        \\var r = new ShadowRealm();
        \\var s = r.evaluate('Symbol("foobar")');
        \\var shadowX = r.evaluate('Symbol.for("my symbol name")');
        \\var myX = Symbol.for("my symbol name");
        \\var desc = Object.getOwnPropertyDescriptor(Symbol.prototype, "description").get;
        \\[
        \\  typeof s === "symbol",
        \\  s.constructor === Symbol,
        \\  Object.getPrototypeOf(s) === Symbol.prototype,
        \\  Symbol.prototype.toString.call(s) === "Symbol(foobar)",
        \\  shadowX === myX,
        \\  Symbol.keyFor(shadowX) === "my symbol name",
        \\  Symbol.keyFor(s) === undefined,
        \\  desc.call(s) === "foobar"
        \\].map(function (x) { return x ? "1" : "0"; }).join("")
    );
}

test "Promise.resolve queues thenable jobs" {
    const ctx = try Context.create(std.testing.allocator);
    defer ctx.destroy();
    _ = try ctx.evaluate(
        \\var seq = [];
        \\var thenable = {
        \\  then: function (resolve) {
        \\    seq.push(3);
        \\    resolve("ok");
        \\  }
        \\};
        \\seq.push(1);
        \\var p = Promise.resolve(thenable);
        \\seq.push(2);
        \\p.then(function () { seq.push(4); });
    );
    const v = try ctx.evaluate("seq.join('')");
    try std.testing.expectEqualStrings("1234", v.asStr());
}

test "Promise resolving function rejects self resolution" {
    const ctx = try Context.create(std.testing.allocator);
    defer ctx.destroy();
    _ = try ctx.evaluate(
        \\var resolveP;
        \\var p = new Promise(function (resolve) { resolveP = resolve; });
        \\resolveP(p);
        \\var result = "pending";
        \\p.then(function () { result = "fulfilled"; }, function (err) { result = err.name; });
    );
    const v = try ctx.evaluate("result");
    try std.testing.expectEqualStrings("TypeError", v.asStr());
}

test "Promise.resolve rejects poisoned then getter" {
    const ctx = try Context.create(std.testing.allocator);
    defer ctx.destroy();
    _ = try ctx.evaluate(
        \\var err = new Error("poison");
        \\var poisoned = {};
        \\Object.defineProperty(poisoned, "then", { get: function () { throw err; } });
        \\var result = "pending";
        \\Promise.resolve(poisoned).then(function () { result = "fulfilled"; }, function (reason) {
        \\  result = reason === err ? "same" : "other";
        \\});
    );
    const v = try ctx.evaluate("result");
    try std.testing.expectEqualStrings("same", v.asStr());
}

test "Promise thenable job ignores throw after resolve" {
    const ctx = try Context.create(std.testing.allocator);
    defer ctx.destroy();
    _ = try ctx.evaluate(
        \\var result = "pending";
        \\var inner = { then: function (resolve) { resolve("ok"); } };
        \\var outer = { then: function (resolve) { resolve(inner); throw new Error("ignored"); } };
        \\Promise.resolve(outer).then(function (value) { result = value; }, function () { result = "rejected"; });
    );
    const v = try ctx.evaluate("result");
    try std.testing.expectEqualStrings("ok", v.asStr());
}

test "Promise keyed combinators preserve enumerable own keys" {
    const ctx = try Context.create(std.testing.allocator);
    defer ctx.destroy();
    _ = try ctx.evaluate(
        \\var sym = Symbol("s");
        \\var input = { first: Promise.resolve(1) };
        \\input[sym] = Promise.resolve(2);
        \\Object.defineProperty(input, "hidden", { value: Promise.resolve(3), enumerable: false });
        \\var all = "pending";
        \\Promise.allKeyed(input).then(function (result) {
        \\  all = [
        \\    Object.getPrototypeOf(result) === null,
        \\    Reflect.ownKeys(result)[0] === "first",
        \\    Reflect.ownKeys(result)[1] === sym,
        \\    result.first === 1,
        \\    result[sym] === 2,
        \\    Object.prototype.hasOwnProperty.call(result, "hidden") === false
        \\  ].join("|");
        \\});
        \\var settled = "pending";
        \\Promise.allSettledKeyed({
        \\  a: Promise.resolve("ok"),
        \\  b: Promise.reject("bad")
        \\}).then(function (result) {
        \\  settled = result.a.status + ":" + result.a.value + "|" + result.b.status + ":" + result.b.reason;
        \\});
    );
    try std.testing.expectEqualStrings("true|true|true|true|true|true", (try ctx.evaluate("all")).asStr());
    try std.testing.expectEqualStrings("fulfilled:ok|rejected:bad", (try ctx.evaluate("settled")).asStr());
}

test "Array.fromAsync awaits thenable elements" {
    const ctx = try Context.create(std.testing.allocator);
    defer ctx.destroy();
    _ = try ctx.evaluate(
        \\var count = 0;
        \\var value = "";
        \\var rejected = false;
        \\Array.fromAsync({ length: 1, 0: { then: function (resolve) {
        \\  count += 1;
        \\  resolve("ok");
        \\} } }).then(function (a) { value = count + ":" + a[0]; });
        \\var err = new Error("boom");
        \\Array.fromAsync({ length: 1, 0: { then: function () { throw err; } } })
        \\  .then(undefined, function (reason) { rejected = reason === err; });
    );
    const v = try ctx.evaluate("value + ':' + rejected");
    try std.testing.expectEqualStrings("1:ok:true", v.asStr());
}

/// Evaluate `src` in a fresh context and return its completion value. Only safe
/// for by-value results (numbers/booleans); a returned `.string` points into the
/// context arena, so use `expectEvalStr` for those (it compares before teardown).
fn evalIn(src: []const u8) !value.Value {
    const ctx = try Context.create(std.testing.allocator);
    defer ctx.destroy();
    return ctx.evaluate(src);
}

/// Assert `src` is rejected at parse time (an early error / SyntaxError) — the
/// evaluation returns an error rather than a value.
fn expectParseError(src: []const u8) !void {
    const ctx = try Context.create(std.testing.allocator);
    defer ctx.destroy();
    if (ctx.evaluate(src)) |_| return error.ExpectedParseError else |_| {}
}

/// Evaluate `src` and assert its string completion value, while the context (and
/// thus the string's backing arena) is still alive.
fn expectEvalStr(expected: []const u8, src: []const u8) !void {
    const ctx = try Context.create(std.testing.allocator);
    defer ctx.destroy();
    const v = try ctx.evaluate(src);
    try std.testing.expectEqualStrings(expected, v.asStr());
}

test "$262.AbstractModuleSource host intrinsic surface" {
    try std.testing.expect((try evalIn(
        \\var C = $262.AbstractModuleSource;
        \\var ctorProtoDesc = Object.getOwnPropertyDescriptor(C, "prototype");
        \\var ctorDesc = Object.getOwnPropertyDescriptor(C.prototype, "constructor");
        \\var tagDesc = Object.getOwnPropertyDescriptor(C.prototype, Symbol.toStringTag);
        \\var threw = false;
        \\try { new C(); } catch (e) { threw = e instanceof TypeError; }
        \\typeof C === "function" &&
        \\Object.getPrototypeOf(C) === Function.prototype &&
        \\Object.getPrototypeOf(C.prototype) === Object.prototype &&
        \\C.name === "AbstractModuleSource" &&
        \\C.length === 0 &&
        \\ctorProtoDesc.value === C.prototype &&
        \\ctorProtoDesc.writable === false &&
        \\ctorProtoDesc.enumerable === false &&
        \\ctorProtoDesc.configurable === false &&
        \\ctorDesc.value === C &&
        \\ctorDesc.writable === true &&
        \\ctorDesc.enumerable === false &&
        \\ctorDesc.configurable === true &&
        \\typeof tagDesc.get === "function" &&
        \\tagDesc.set === undefined &&
        \\tagDesc.enumerable === false &&
        \\tagDesc.configurable === true &&
        \\C.prototype[Symbol.toStringTag] === undefined &&
        \\tagDesc.get.call(262) === undefined &&
        \\tagDesc.get.call(C.prototype) === undefined &&
        \\threw
    )).asBool());
}

test "function name + length own properties" {
    // `name` and `length` are own, non-enumerable, configurable, non-writable.
    try expectEvalStr("foo", "function foo(a, b) {} foo.name");
    try std.testing.expectEqual(@as(f64, 2), (try evalIn("function foo(a, b) {} foo.length")).asNum());
    try std.testing.expect((try evalIn(
        \\function foo(a, b) {}
        \\foo.hasOwnProperty("name") && foo.hasOwnProperty("length")
    )).asBool());
    // `length` counts params before the first default / rest.
    try std.testing.expectEqual(@as(f64, 1), (try evalIn("function f(a, b = 1, c) {} f.length")).asNum());
    try std.testing.expectEqual(@as(f64, 1), (try evalIn("function f(a, ...r) {} f.length")).asNum());
    // An anonymous function expression *not* in a naming position has the
    // empty name; assigned to a binding it takes that name (NamedEvaluation).
    try expectEvalStr("", "(function (x) {}).name");
    try expectEvalStr("f", "var f = function (x) {}; f.name");
    // Descriptor attributes: { writable:false, enumerable:false, configurable:true }.
    try std.testing.expect((try evalIn(
        \\function f() {}
        \\var d = Object.getOwnPropertyDescriptor(f, "length");
        \\!d.writable && !d.enumerable && d.configurable
    )).asBool());
    // name/length are not enumerable (skipped by Object.keys / for-in).
    try std.testing.expectEqual(@as(f64, 0), (try evalIn("function f(a) {} Object.keys(f).length")).asNum());
    // Class constructor carries name + constructor arity.
    try expectEvalStr("C", "class C { constructor(a, b) {} } C.name");
    try std.testing.expectEqual(@as(f64, 2), (try evalIn("class C { constructor(a, b) {} } C.length")).asNum());
    // Bound function: name is "bound <target>", length is reduced by bound args.
    try expectEvalStr("bound f", "function f(a, b, c) {} f.bind(null, 1).name");
    try std.testing.expectEqual(@as(f64, 2), (try evalIn("function f(a, b, c) {} f.bind(null, 1).length")).asNum());
}

test "function declarations survive later bare var declarations" {
    try expectEvalStr("function",
        \\var f;
        \\function f() {}
        \\typeof f
    );
    try expectEvalStr("second",
        \\function f() { return "first"; }
        \\function f() { return "second"; }
        \\f()
    );
}

test "sloppy function calls bind this through the callee realm" {
    try std.testing.expect((try evalIn(
        \\var touchedNumber = Function("this.touched = true; return this;").call(1);
        \\var touchedString = Function("this.touched = true; return this;").apply("", []);
        \\var strictThis = Function('"use strict"; return this;').call(1);
        \\var other = $262.createRealm().global;
        \\var f = new other.Function("return this;");
        \\var otherNumber = f.call(1);
        \\touchedNumber.touched === true &&
        \\touchedNumber.constructor === Number &&
        \\touchedString.touched === true &&
        \\touchedString.constructor === String &&
        \\strictThis === 1 &&
        \\f() === other &&
        \\f.call(null) === other &&
        \\otherNumber.constructor === other.Number &&
        \\otherNumber instanceof other.Number
    )).asBool());
}

test "native functions carry name + length own properties" {
    // Built-in methods/globals/constructors report their spec name and arity.
    try expectEvalStr("defineProperty", "Object.defineProperty.name");
    try std.testing.expectEqual(@as(f64, 3), (try evalIn("Object.defineProperty.length")).asNum());
    try expectEvalStr("push", "Array.prototype.push.name");
    try std.testing.expectEqual(@as(f64, 1), (try evalIn("Array.prototype.push.length")).asNum());
    try expectEvalStr("parseInt", "parseInt.name");
    try std.testing.expectEqual(@as(f64, 2), (try evalIn("parseInt.length")).asNum());
    try expectEvalStr("Object", "Object.name");
    // Same name can have a different arity on a different prototype.
    try std.testing.expectEqual(@as(f64, 0), (try evalIn("Object.prototype.toString.length")).asNum());
    try std.testing.expectEqual(@as(f64, 1), (try evalIn("Number.prototype.toString.length")).asNum());
    // Own + non-enumerable + non-writable + configurable, like user functions.
    try std.testing.expect((try evalIn(
        \\Object.keys.hasOwnProperty("name") && Object.keys.hasOwnProperty("length")
    )).asBool());
    try std.testing.expect((try evalIn(
        \\var d = Object.getOwnPropertyDescriptor(Math.max, "length");
        \\!d.writable && !d.enumerable && d.configurable
    )).asBool());
    try std.testing.expectEqual(@as(f64, 0), (try evalIn("Object.keys(Math.floor).length")).asNum());
}

test "typeof on an undeclared identifier is \"undefined\" (no throw)" {
    try expectEvalStr("undefined", "typeof undeclaredXYZ");
    try std.testing.expect((try evalIn("typeof undeclaredXYZ === 'undefined'")).asBool());
    try expectEvalStr("undefined", "function f() { return typeof zzz; } f()");
    // A declared-but-undefined var is still "undefined".
    try expectEvalStr("undefined", "var y; typeof y");
    // typeof of a bound value is unaffected.
    try expectEvalStr("object", "typeof Math");
    // Actually *using* (not typeof-ing) an undeclared name still throws ReferenceError.
    try std.testing.expect((try evalIn(
        \\var t = "";
        \\try { undeclaredABC; } catch (e) { t = e.name; }
        \\t === "ReferenceError"
    )).asBool());
}

test "global undefined is an immutable binding, not a literal token" {
    try std.testing.expect((try evalIn(
        \\undefined = 5;
        \\undefined === void 0
    )).asBool());
    try std.testing.expect((try evalIn(
        \\var newProperty = undefined = 42;
        \\newProperty === 42 && undefined === void 0
    )).asBool());
    try std.testing.expect((try evalIn("delete undefined === false")).asBool());
    try std.testing.expect((try evalIn(
        \\var d = Object.getOwnPropertyDescriptor(globalThis, "undefined");
        \\d.value === void 0 && !d.writable && !d.enumerable && !d.configurable
    )).asBool());
    try std.testing.expect((try evalIn(
        \\(function () { let undefined = 7; return undefined; })() === 7
    )).asBool());
    try std.testing.expect((try evalIn(
        \\(function (undefined) { undefined = 9; return undefined; })(1) === 9
    )).asBool());
    try std.testing.expectError(error.Throw, evalIn("let undefined;"));
}

test "function declarations are hoisted" {
    // Forward references work at program scope and inside function bodies.
    try std.testing.expectEqual(@as(f64, 5), (try evalIn("bar(); function bar() { return 5; }\nbar()")).asNum());
    try expectEvalStr("function", "typeof foo; function foo() {}");
    try std.testing.expectEqual(@as(f64, 1), (try evalIn("foo.x = 1; function foo() {} foo.x")).asNum());
    try std.testing.expectEqual(@as(f64, 9), (try evalIn(
        \\function f() { return inner(); function inner() { return 9; } }
        \\f()
    )).asNum());
    // The hoisted binding is the same function object referenced before its text.
    try std.testing.expect((try evalIn("var g = bar; function bar() {} g === bar")).asBool());
    // A later declaration of the same name wins.
    try std.testing.expectEqual(@as(f64, 2), (try evalIn("function f() { return 1; } function f() { return 2; } f()")).asNum());
}

test "built-in methods are non-enumerable" {
    // Prototype methods and namespace statics are skipped by Object.keys/for-in.
    try std.testing.expect((try evalIn("Object.keys(Math).indexOf('max') === -1")).asBool());
    try std.testing.expect((try evalIn("Object.keys(JSON).length === 0")).asBool());
    try std.testing.expect((try evalIn("Object.keys(Array.prototype).indexOf('push') === -1")).asBool());
    try std.testing.expect(!(try evalIn("Array.prototype.propertyIsEnumerable('push')")).asBool());
    try std.testing.expect((try evalIn("Object.keys(Object).indexOf('keys') === -1")).asBool());
    // They remain present and callable.
    try std.testing.expectEqual(@as(f64, 3), (try evalIn("Math.max(1, 2, 3)")).asNum());
    try std.testing.expect((try evalIn("Array.prototype.hasOwnProperty('push')")).asBool());
}

test "built-in prototypes carry constructor; Boolean.prototype exists" {
    // Every built-in prototype links back to its constructor (non-enumerable).
    try std.testing.expect((try evalIn("Object.prototype.constructor === Object")).asBool());
    try std.testing.expect((try evalIn("Array.prototype.constructor === Array")).asBool());
    try std.testing.expect((try evalIn("String.prototype.constructor === String")).asBool());
    try std.testing.expect((try evalIn("Number.prototype.constructor === Number")).asBool());
    try std.testing.expect((try evalIn("Function.prototype.constructor === Function")).asBool());
    try std.testing.expect((try evalIn("Date.prototype.constructor === Date")).asBool());
    try std.testing.expect((try evalIn("Function.prototype.isPrototypeOf(Object)")).asBool());
    try std.testing.expect((try evalIn("Function.prototype.isPrototypeOf(Array)")).asBool());
    try std.testing.expect((try evalIn("Function.prototype.isPrototypeOf(String)")).asBool());
    try std.testing.expect((try evalIn("Function.prototype.isPrototypeOf(Date)")).asBool());
    try std.testing.expect((try evalIn("Function.prototype.isPrototypeOf(RegExp)")).asBool());
    // `constructor` is non-enumerable.
    try std.testing.expect((try evalIn("Object.keys(Array.prototype).indexOf('constructor') === -1")).asBool());
    // Boolean.prototype now exists with constructor + generic toString/valueOf.
    try expectEvalStr("object", "typeof Boolean.prototype");
    try std.testing.expect((try evalIn("Boolean.prototype.constructor === Boolean")).asBool());
    try std.testing.expect((try evalIn("Function.prototype.isPrototypeOf(Boolean)")).asBool());
    try std.testing.expect((try evalIn("Object.prototype.isPrototypeOf(Boolean.prototype)")).asBool());
    try expectEvalStr("true", "Boolean.prototype.toString.call(true)");
    try std.testing.expect(!(try evalIn("Boolean.prototype.valueOf.call(false)")).asBool());
    try std.testing.expect((try evalIn(
        \\var other = $262.createRealm().global;
        \\var C = new other.Function();
        \\C.prototype = null;
        \\Object.getPrototypeOf(Reflect.construct(Boolean, [], C)) === other.Boolean.prototype
    )).asBool());
}

test "Symbol.prototype: toString / valueOf / chain" {
    try expectEvalStr("object", "typeof Symbol.prototype");
    try std.testing.expect((try evalIn("Symbol.prototype.constructor === Symbol")).asBool());
    try expectEvalStr("function", "typeof Symbol.prototype.toString");
    // toString renders the description; valueOf returns the symbol itself.
    try expectEvalStr("Symbol(f)", "Symbol('f').toString()");
    try expectEvalStr("Symbol()", "Symbol().toString()");
    try std.testing.expect((try evalIn("var s = Symbol('q'); s.valueOf() === s")).asBool());
    // Instances are linked to Symbol.prototype; the methods are generic via .call.
    try std.testing.expect((try evalIn("Object.getPrototypeOf(Symbol()) === Symbol.prototype")).asBool());
    try expectEvalStr("Symbol(z)", "Symbol.prototype.toString.call(Symbol('z'))");
    // A non-symbol receiver throws TypeError.
    try std.testing.expect((try evalIn(
        \\var t = false;
        \\try { Symbol.prototype.toString.call({}); } catch (e) { t = e.name === "TypeError"; }
        \\t
    )).asBool());
}

test "Symbol constructor probes and ordinary wrapper coercion" {
    try std.testing.expect((try evalIn(
        \\var probed = false;
        \\try { Reflect.construct(function() {}, [], Symbol); probed = true; } catch (e) {}
        \\var touched = false;
        \\var threw = false;
        \\try { new Symbol({ toString: function() { touched = true; return 'x'; } }); }
        \\catch (e) { threw = e instanceof TypeError; }
        \\probed && threw && !touched
    )).asBool());
    try std.testing.expect((try evalIn(
        \\Object.defineProperty(Symbol.prototype, Symbol.toPrimitive, { configurable: true, value: null });
        \\var result = `${Object(Symbol())}`;
        \\var threw = false;
        \\try { +Object(Symbol()); } catch (e) { threw = e instanceof TypeError; }
        \\var related = false;
        \\try { Object(Symbol()) <= ''; } catch (e) { related = e instanceof TypeError; }
        \\delete Symbol.prototype[Symbol.toPrimitive];
        \\result === 'Symbol()' && threw && related
    )).asBool());
    try std.testing.expect((try evalIn(
        \\delete Symbol.prototype[Symbol.toPrimitive];
        \\var gets = 0;
        \\var valueOfFunction = function() { gets += 100; return 123; };
        \\Object.defineProperty(Symbol.prototype, 'valueOf', {
        \\  configurable: true,
        \\  get: function() { gets++; return valueOfFunction; }
        \\});
        \\var str = ''.concat(Object(Symbol()));
        \\str === 'Symbol()' && gets === 0
    )).asBool());
}

test "Error.prototype.stack accessor" {
    // An accessor on Error.prototype with get/set named "get stack"/"set stack".
    try expectEvalStr("function", "typeof Object.getOwnPropertyDescriptor(Error.prototype, 'stack').get");
    try expectEvalStr("get stack", "Object.getOwnPropertyDescriptor(Error.prototype, 'stack').get.name");
    try expectEvalStr("set stack", "Object.getOwnPropertyDescriptor(Error.prototype, 'stack').set.name");
    // The getter returns a string for an Error receiver, undefined otherwise.
    try expectEvalStr("string", "typeof new Error('x').stack");
    try std.testing.expect((try evalIn("({ __proto__: new Error('y') }).stack === undefined")).asBool());
    // The setter installs an own { writable, enumerable, configurable } data
    // property shadowing the accessor (SetterThatIgnoresPrototypeProperties).
    try std.testing.expect((try evalIn("var e = new Error('x'); e.stack = 'custom'; e.stack === 'custom'")).asBool());
    try std.testing.expect((try evalIn("var e = new Error('x'); e.stack = 's'; Object.getOwnPropertyDescriptor(e, 'stack').enumerable")).asBool());
    // A non-String value throws a TypeError; assigning to %Error.prototype% throws.
    try std.testing.expect((try evalIn("var e = new Error('x'); try { e.stack = 42; false } catch (x) { x instanceof TypeError }")).asBool());
    try std.testing.expect((try evalIn("try { Error.prototype.stack = 's'; false } catch (x) { x instanceof TypeError }")).asBool());
    try std.testing.expect((try evalIn(
        \\var setA = Object.getOwnPropertyDescriptor(Error.prototype, "stack").set;
        \\var realmB = $262.createRealm().global;
        \\try {
        \\  setA.call(realmB.Error.prototype, "x");
        \\  false;
        \\} catch (e) {
        \\  Object.getPrototypeOf(e) === realmB.TypeError.prototype;
        \\}
    )).asBool());
}

test "AggregateError" {
    try expectEvalStr("function", "typeof AggregateError");
    // errors comes from the (iterable) first arg; message is the second.
    try std.testing.expectEqual(@as(f64, 3), (try evalIn("new AggregateError([1, 2, 3]).errors.length")).asNum());
    try expectEvalStr("boom", "new AggregateError([], 'boom').message");
    try std.testing.expectEqual(@as(f64, 2), (try evalIn("new AggregateError(new Set([1, 2])).errors.length")).asNum());
    // Prototype chain + name, and the cause option (third arg).
    try std.testing.expect((try evalIn("new AggregateError([]) instanceof Error")).asBool());
    try std.testing.expect((try evalIn("new AggregateError([]) instanceof AggregateError")).asBool());
    try expectEvalStr("AggregateError", "AggregateError.prototype.name");
    try std.testing.expectEqual(@as(f64, 5), (try evalIn("new AggregateError([], 'm', { cause: 5 }).cause")).asNum());
    // `errors` is a non-enumerable own property.
    try std.testing.expect((try evalIn("new AggregateError([1]).hasOwnProperty('errors') && Object.keys(new AggregateError([1])).indexOf('errors') === -1")).asBool());
    try std.testing.expect((try evalIn(
        \\var proto = {};
        \\function Target() {}
        \\Target.prototype = proto;
        \\Object.getPrototypeOf(Reflect.construct(AggregateError, [[]], Target)) === proto
    )).asBool());
    try std.testing.expect((try evalIn(
        \\var other = $262.createRealm().global;
        \\var Target = new other.Function();
        \\Target.prototype = undefined;
        \\Object.getPrototypeOf(Reflect.construct(AggregateError, [[]], Target)) === other.AggregateError.prototype
    )).asBool());
    try std.testing.expect((try evalIn("try { new AggregateError(); false } catch (e) { e instanceof TypeError }")).asBool());
    try std.testing.expect((try evalIn(
        \\var bad = { [Symbol.iterator]() { return { next() { return undefined; } }; } };
        \\try { new AggregateError(bad); false } catch (e) { e instanceof TypeError }
    )).asBool());
}

test "SuppressedError creates message before error and suppressed" {
    try std.testing.expect((try evalIn(
        \\var e = new SuppressedError({}, {}, { toString: function () { return ""; } });
        \\var keys = Object.getOwnPropertyNames(e);
        \\keys.indexOf("message") !== -1 &&
        \\keys.indexOf("error") === keys.indexOf("message") + 1 &&
        \\keys.indexOf("suppressed") === keys.indexOf("error") + 1
    )).asBool());
}

test "Error cause option (ES2022)" {
    // `new Error(msg, { cause })` installs a non-enumerable own `cause`.
    try std.testing.expectEqual(@as(f64, 42), (try evalIn("new Error('m', { cause: 42 }).cause")).asNum());
    try std.testing.expect((try evalIn("new TypeError('t', { cause: 'x' }).cause === 'x'")).asBool());
    // Present-but-undefined cause is still an own property; absent options is not.
    try std.testing.expect((try evalIn("new Error('m', { cause: undefined }).hasOwnProperty('cause')")).asBool());
    try std.testing.expect(!(try evalIn("new Error('m').hasOwnProperty('cause')")).asBool());
    try std.testing.expect(!(try evalIn("new Error('m', {}).hasOwnProperty('cause')")).asBool());
    // cause is non-enumerable, writable, configurable.
    try std.testing.expect((try evalIn(
        \\var d = Object.getOwnPropertyDescriptor(new Error('m', { cause: 1 }), 'cause');
        \\!d.enumerable && d.writable && d.configurable
    )).asBool());
}

test "Error prototypes: chain, name/message inheritance, toString" {
    // Each constructor has a real prototype with name/message/constructor.
    try expectEvalStr("object", "typeof Error.prototype");
    try expectEvalStr("Error", "Error.prototype.name");
    try expectEvalStr("", "Error.prototype.message");
    try std.testing.expect((try evalIn("Error.prototype.constructor === Error")).asBool());
    try std.testing.expect((try evalIn("Error.hasOwnProperty('prototype')")).asBool());
    // Prototype chain: TypeError.prototype -> Error.prototype -> Object.prototype.
    try std.testing.expect((try evalIn("Object.getPrototypeOf(new Error()) === Error.prototype")).asBool());
    try std.testing.expect((try evalIn("Object.getPrototypeOf(TypeError.prototype) === Error.prototype")).asBool());
    try std.testing.expect((try evalIn("new TypeError('x') instanceof Error")).asBool());
    // name is inherited; message is own only when supplied.
    try expectEvalStr("Error", "new Error().name");
    try expectEvalStr("TypeError", "new TypeError().name");
    try std.testing.expect((try evalIn("new Error('m').hasOwnProperty('message')")).asBool());
    try std.testing.expect(!(try evalIn("new Error().hasOwnProperty('message')")).asBool());
    try std.testing.expect(!(try evalIn("new Error().hasOwnProperty('name')")).asBool());
    // toString: "name: message", or just one when the other is empty; generic.
    try expectEvalStr("Error: hi", "new Error('hi').toString()");
    try expectEvalStr("TypeError: x", "new TypeError('x').toString()");
    try expectEvalStr("Error", "new Error().toString()");
    try expectEvalStr("E: m", "Error.prototype.toString.call({ name: 'E', message: 'm' })");
}

test "Object.prototype legacy accessor helpers (__define/lookup__)" {
    try std.testing.expectEqual(@as(f64, 42), (try evalIn(
        \\var o = {}; o.__defineGetter__("x", function () { return 42; }); o.x
    )).asNum());
    try std.testing.expectEqual(@as(f64, 7), (try evalIn(
        \\var o = {}; var v = 0; o.__defineSetter__("y", function (n) { v = n; }); o.y = 7; v
    )).asNum());
    // __lookupGetter__/__lookupSetter__ return the accessor fn, walking the proto chain.
    try std.testing.expect((try evalIn(
        \\var o = {}; o.__defineGetter__("x", function () { return 1; });
        \\typeof o.__lookupGetter__("x") === "function" && o.__lookupGetter__("x")() === 1
    )).asBool());
    // Missing / data properties have no getter; a non-callable arg throws TypeError.
    try std.testing.expect((try evalIn("({}).__lookupGetter__('nope') === undefined")).asBool());
    try std.testing.expect((try evalIn("({ a: 1 }).__lookupGetter__('a') === undefined")).asBool());
    try std.testing.expect((try evalIn(
        \\var t = false; try { ({}).__defineGetter__("x", 5); } catch (e) { t = e.name === "TypeError"; } t
    )).asBool());
    // Defined accessor is enumerable + configurable.
    try std.testing.expect((try evalIn(
        \\var o = {}; o.__defineGetter__("x", function () {});
        \\var d = Object.getOwnPropertyDescriptor(o, "x"); d.enumerable && d.configurable
    )).asBool());
}

test "large array length is logical (no OOM) + length assignment" {
    // `new Array(huge)` tracks length without materializing 4 billion holes.
    try std.testing.expectEqual(@as(f64, 4294967295), (try evalIn("new Array(4294967295).length")).asNum());
    try std.testing.expectEqual(@as(f64, 0), (try evalIn("new Array(0).length")).asNum());
    try std.testing.expectEqual(@as(f64, 3), (try evalIn("new Array(3).length")).asNum());
    try std.testing.expectEqual(@as(f64, 100), (try evalIn("new Array(100).length")).asNum());
    // Assigning length truncates (dropping elements) or grows logically.
    try std.testing.expect((try evalIn(
        \\var a = [1, 2, 3]; a.length = 2;
        \\a.length === 2 && a[1] === 2 && a[2] === undefined
    )).asBool());
    try std.testing.expectEqual(@as(f64, 5), (try evalIn("var a = [1, 2, 3]; a.length = 5; a.length")).asNum());
    // A large index extends the logical length past it.
    try std.testing.expectEqual(@as(f64, 6), (try evalIn("var a = []; a[5] = 1; a.length")).asNum());
    // Invalid lengths throw RangeError.
    try std.testing.expect((try evalIn(
        \\var t = false; try { [].length = -1; } catch (e) { t = e.name === "RangeError"; } t
    )).asBool());
    try std.testing.expect((try evalIn(
        \\var t = false; try { [].length = 1.5; } catch (e) { t = e.name === "RangeError"; } t
    )).asBool());
}

test "Date setters + string conversions" {
    // Time-component setters honor extra args and roll over out-of-range values.
    try std.testing.expect((try evalIn(
        \\var d = new Date(2016, 6, 1); d.setHours(0, 0, 0, 543);
        \\d.getTime() === new Date(2016, 6, 1, 0, 0, 0, 543).getTime()
    )).asBool());
    try std.testing.expect((try evalIn(
        \\var d = new Date(2016, 6, 1); d.setHours(0, 0, 0, -1);
        \\d.getTime() === new Date(2016, 5, 30, 23, 59, 59, 999).getTime()
    )).asBool());
    // setMonth/setDate roll into adjacent months/years.
    try std.testing.expectEqual(@as(f64, 1971), (try evalIn("var d = new Date(0); d.setMonth(13); d.getUTCFullYear()")).asNum());
    try std.testing.expectEqual(@as(f64, 1), (try evalIn("var d = new Date(0); d.setDate(32); d.getUTCMonth()")).asNum());
    // setFullYear revives an invalid date; other setters leave it invalid.
    try std.testing.expectEqual(@as(f64, 2020), (try evalIn("var d = new Date(NaN); d.setFullYear(2020); d.getUTCFullYear()")).asNum());
    try std.testing.expect(std.math.isNan((try evalIn("var d = new Date(NaN); d.setHours(5); d.getTime()")).asNum()));
    // String conversions.
    try expectEvalStr("Thu, 01 Jan 1970 00:00:00 GMT", "new Date(0).toUTCString()");
    try expectEvalStr("Thu Jan 01 1970 00:00:00 GMT+0000 (Coordinated Universal Time)", "new Date(0).toString()");
    try expectEvalStr("Thu Jan 01 1970", "new Date(0).toDateString()");
    try expectEvalStr("00:00:00 GMT+0000 (Coordinated Universal Time)", "new Date(0).toTimeString()");
    // toISOString throws RangeError on an invalid date; toJSON returns null.
    try std.testing.expect((try evalIn(
        \\var t = false;
        \\try { new Date(NaN).toISOString(); } catch (e) { t = e.name === "RangeError"; }
        \\t
    )).asBool());
    try std.testing.expect((try evalIn("new Date(NaN).toJSON() === null")).asBool());
}

test "Function constructor builds callable functions from source" {
    // Params + body, called and constructed.
    try std.testing.expectEqual(@as(f64, 7), (try evalIn("Function('a', 'b', 'return a + b')(3, 4)")).asNum());
    try std.testing.expectEqual(@as(f64, 12), (try evalIn("new Function('a,b', 'return a * b')(3, 4)")).asNum());
    try std.testing.expectEqual(@as(f64, 42), (try evalIn("Function('return 42')()")).asNum());
    try std.testing.expect((try evalIn(
        \\var i = 0;
        \\var p = { toString: function() { return "a" + (++i); } };
        \\var f = Function(p, p, p, "return a3 + a2 + a1.length;");
        \\f("x", "", 2) === "21" && i === 3
    )).asBool());
    try std.testing.expect((try evalIn(
        \\var p = { toString: function() { p = 1; return "a"; } };
        \\var body = { toString: function() { throw "body"; } };
        \\try { Function(p, body); false; } catch (e) { e === "body" && p === 1; }
    )).asBool());
    // Spec name + arity of the synthesized function.
    try expectEvalStr("anonymous", "Function('return 1').name");
    try std.testing.expectEqual(@as(f64, 2), (try evalIn("Function('a', 'b', 'return 0').length")).asNum());
    try expectEvalStr("function", "typeof Function('return 1')");
    // A syntactically invalid body throws SyntaxError.
    try std.testing.expect((try evalIn(
        \\var t = false;
        \\try { Function("return )("); } catch (e) { t = e.name === "SyntaxError"; }
        \\t
    )).asBool());
}

test "String.prototype.split: limit + regex separators" {
    // `limit` truncates the result.
    try expectEvalStr("a|b", "'a,b,c'.split(',', 2).join('|')");
    try std.testing.expectEqual(@as(f64, 0), (try evalIn("'a,b,c'.split(',', 0).length")).asNum());
    // Regex separators split on each match.
    try expectEvalStr("2016|01|02", "'2016-01-02'.split(/-/).join('|')");
    try expectEvalStr("a|b|c", "'a1b2c'.split(/\\d/).join('|')");
    try expectEvalStr("a|b|c", "'a, b ,c'.split(/\\s*,\\s*/).join('|')");
    // An empty-matching pattern splits between every character.
    try expectEvalStr("a|b|c", "'abc'.split(/(?:)/).join('|')");
    // Capture groups are spliced into the result.
    try expectEvalStr(",t,es,t,", "'test'.split(/(t)/).join(',')");
    // Empty input: [""] unless the pattern matches the empty string (then []).
    try std.testing.expectEqual(@as(f64, 1), (try evalIn("''.split(/x/).length")).asNum());
    try std.testing.expectEqual(@as(f64, 0), (try evalIn("''.split(/(?:)/).length")).asNum());
    // String separators (and no separator) still behave.
    try std.testing.expectEqual(@as(f64, 3), (try evalIn("'a,b,c'.split(',').length")).asNum());
    try std.testing.expectEqual(@as(f64, 1), (try evalIn("'abc'.split().length")).asNum());
}

test "Object.hasOwn" {
    try std.testing.expect((try evalIn("Object.hasOwn({ a: 1 }, \"a\")")).asBool());
    try std.testing.expect(!(try evalIn("Object.hasOwn({ a: 1 }, \"b\")")).asBool());
    // Own only — inherited properties are excluded.
    try std.testing.expect(!(try evalIn("Object.hasOwn(Object.create({ a: 1 }), \"a\")")).asBool());
    // Array indices, array length, and string indices/length.
    try std.testing.expect((try evalIn("Object.hasOwn([1, 2], 0) && Object.hasOwn([1, 2], \"length\") && !Object.hasOwn([1, 2], 5)")).asBool());
    try std.testing.expect((try evalIn("Object.hasOwn(\"ab\", 0) && Object.hasOwn(\"ab\", \"length\") && !Object.hasOwn(\"ab\", 9)")).asBool());
    // null / undefined throw a TypeError.
    try std.testing.expect((try evalIn(
        \\var t = false;
        \\try { Object.hasOwn(null, "x"); } catch (e) { t = e.name === "TypeError"; }
        \\t
    )).asBool());
    // Object.hasOwn performs ToObject before ToPropertyKey.
    try std.testing.expect((try evalIn(
        \\var touched = false;
        \\var key = { get toString() { touched = true; throw new Error("key"); } };
        \\var ok = false;
        \\try { Object.hasOwn(null, key); } catch (e) { ok = e instanceof TypeError && !touched; }
        \\ok
    )).asBool());
}

test "defineProperty rejects incompatible redefinition of non-configurable props" {
    // A non-configurable property can't be made configurable, re-typed, or (when
    // non-writable) have its value/writability changed — each throws TypeError.
    const cases = [_][]const u8{
        \\var o = {}; Object.defineProperty(o, "p", { value: 1, configurable: false });
        \\Object.defineProperty(o, "p", { value: 2 });
        ,
        \\var o = {}; Object.defineProperty(o, "p", { value: 1, configurable: false });
        \\Object.defineProperty(o, "p", { configurable: true });
        ,
        \\var o = {}; Object.defineProperty(o, "p", { value: 1, configurable: false });
        \\Object.defineProperty(o, "p", { enumerable: true });
        ,
        \\var a = []; Object.defineProperty(a, "0", { value: -0 });
        \\Object.defineProperties(a, { "0": { value: 0 } });
        ,
        \\var o = Object.freeze({}); Object.defineProperty(o, "x", { value: 1 });
    };
    for (cases) |src| {
        const ctx = try Context.create(std.testing.allocator);
        defer ctx.destroy();
        try std.testing.expectError(error.Throw, ctx.evaluate(src));
        try std.testing.expectEqualStrings("TypeError", ctx.exception.?.asObj().error_name);
    }
    // Compatible redefinitions are still allowed.
    try std.testing.expectEqual(@as(f64, 2), (try evalIn(
        \\var o = {}; Object.defineProperty(o, "p", { value: 1, configurable: true });
        \\Object.defineProperty(o, "p", { value: 2 }); o.p
    )).asNum());
    try std.testing.expectEqual(@as(f64, 2), (try evalIn(
        \\var o = {}; Object.defineProperty(o, "p", { value: 1, writable: true, configurable: false });
        \\Object.defineProperty(o, "p", { value: 2 }); o.p
    )).asNum());
}

test "Object.create applies its properties (second) argument" {
    // Data descriptor on the new object.
    try std.testing.expectEqual(@as(f64, 42), (try evalIn(
        \\var o = Object.create({}, { x: { value: 42, enumerable: true } });
        \\o.x
    )).asNum());
    // Accessor descriptor.
    try std.testing.expectEqual(@as(f64, 7), (try evalIn(
        \\var o = Object.create(null, { a: { get: function () { return 7; }, enumerable: true } });
        \\o.a
    )).asNum());
    // Descriptor attributes are honored (non-enumerable stays off Object.keys).
    try std.testing.expectEqual(@as(f64, 0), (try evalIn(
        \\var o = Object.create({}, { a: { value: 1, enumerable: false } });
        \\Object.keys(o).length
    )).asNum());
    // The prototype argument still wires up the chain; omitted props is a no-op.
    try std.testing.expectEqual(@as(f64, 5), (try evalIn(
        \\var p = { v: 5 }; var o = Object.create(p); o.v
    )).asNum());
    // A non-object descriptor value throws TypeError, like defineProperties.
    try std.testing.expect((try evalIn(
        \\var t = false;
        \\try { Object.create({}, { x: 1 }); } catch (e) { t = e.name === "TypeError"; }
        \\t
    )).asBool());
}

test "new on a non-constructor built-in throws TypeError" {
    // Methods, statics, globals and Symbol are not constructors.
    for ([_][]const u8{
        "new Object.keys({})",
        "new Math.max(1)",
        "new parseInt('1')",
        "new Array.from([])",
        "new Symbol()",
        "new [].push",
    }) |src| {
        const ctx = try Context.create(std.testing.allocator);
        defer ctx.destroy();
        try std.testing.expectError(error.Throw, ctx.evaluate(src));
        try std.testing.expect(ctx.exception.?.asObj().is_error);
        try std.testing.expectEqualStrings("TypeError", ctx.exception.?.asObj().error_name);
    }
    // The real constructors still build instances.
    try std.testing.expectEqual(@as(f64, 3), (try evalIn("new Array(3).length")).asNum());
    try std.testing.expectEqual(@as(f64, 0), (try evalIn("new Date(0).getTime()")).asNum());
    try std.testing.expectEqual(@as(f64, 0), (try evalIn("new Map().size")).asNum());
    try std.testing.expectEqual(@as(f64, 5), (try evalIn("new Number(5).valueOf()")).asNum());
    try std.testing.expect((try evalIn("typeof new Object() === 'object'")).asBool());
}

test "Function.prototype: call / apply / bind" {
    try std.testing.expectEqual(@as(f64, 7), (try evalIn(
        \\function add(a, b) { return a + b; }
        \\add.call(null, 3, 4)
    )).asNum());
    try std.testing.expectEqual(@as(f64, 7), (try evalIn(
        \\function add(a, b) { return a + b; }
        \\add.apply(null, [3, 4])
    )).asNum());
    // `this` binding via call.
    try std.testing.expectEqual(@as(f64, 42), (try evalIn(
        \\function getX() { return this.x; }
        \\getX.call({ x: 42 })
    )).asNum());
    // bind fixes `this` and leading args.
    try std.testing.expectEqual(@as(f64, 15), (try evalIn(
        \\function add3(a, b, c) { return a + b + c; }
        \\var f = add3.bind(null, 1, 2);
        \\f(12)
    )).asNum());
    try std.testing.expectEqual(@as(f64, 100), (try evalIn(
        \\var o = { v: 100, get: function () { return this.v; } };
        \\var g = o.get.bind(o);
        \\g()
    )).asNum());
}

test "Function.prototype.toString returns source (decl/expr) or native syntax" {
    // A function declaration toStrings to its exact source, comments and all.
    try expectEvalStr("function /* a */ f /* b */ ( /* c */ x /* d */ ) /* e */ { return x; }",
        \\function /* a */ f /* b */ ( /* c */ x /* d */ ) /* e */ { return x; }
        \\f.toString()
    );
    // A function expression keeps the leading `function` keyword and name.
    try expectEvalStr("function g(a,b){return a+b}",
        \\var g = function g(a,b){return a+b};
        \\g.toString()
    );
    // A generator expression includes the `*`.
    try expectEvalStr("function* gen() { yield 1; }",
        \\var gen = function* gen() { yield 1; };
        \\gen.toString()
    );
    // A native function uses the NativeFunction syntax.
    try expectEvalStr("function valueOf() { [native code] }", "Object.prototype.valueOf.toString()");
    // String coercion (`"" + fn`) goes through ToPrimitive, which must also use
    // Function.prototype.toString — not the generic "[object Object]".
    try expectEvalStr("function h() { return 1; }",
        \\function h() { return 1; }
        \\"" + h
    );
    // Arrow functions: concise and block bodies, including a leading `async`.
    try expectEvalStr("x => x + 1", "var a = x => x + 1; a.toString()");
    try expectEvalStr("(a, b) => { return a + b; }", "var a = (a, b) => { return a + b; }; a.toString()");
    try expectEvalStr("async x => x", "var a = async x => x; a.toString()");
    // Object-literal methods, getters, setters keep their exact definition source.
    try expectEvalStr("m(a, b) { return a + b; }",
        \\var o = { m(a, b) { return a + b; } };
        \\o.m.toString()
    );
    try expectEvalStr("get x() { return 1; }",
        \\var o = { get x() { return 1; } };
        \\Object.getOwnPropertyDescriptor(o, "x").get.toString()
    );
    // Class methods exclude the `static` keyword (it's not part of the method's
    // source text); the method body source is what toString returns.
    try expectEvalStr("sm() { return 2; }",
        \\class C { static sm() { return 2; } }
        \\C.sm.toString()
    );
    // A class's own toString is its exact source (`class … { … }`), including an
    // `extends` heritage clause.
    try expectEvalStr("class A { m() {} }",
        \\class A { m() {} }
        \\A.toString()
    );
    try expectEvalStr("class B extends A { constructor() { super(); } }",
        \\class A {}
        \\class B extends A { constructor() { super(); } }
        \\B.toString()
    );
}

test "String.prototype[Symbol.iterator] yields a String Iterator" {
    try std.testing.expect((try evalIn("typeof ''[Symbol.iterator] === 'function'")).asBool());
    try expectEvalStr("a,b,c", "[...'abc'].join(',')");
    try expectEvalStr("a", "var it = 'ab'[Symbol.iterator](); it.next().value");
    // RequireObjectCoercible: a null/undefined receiver throws.
    try std.testing.expectError(error.Throw, evalIn("String.prototype[Symbol.iterator].call(undefined)"));
}

test "iterator next() brand-checks its receiver" {
    // A real iterator works; calling next with an incompatible receiver throws.
    try std.testing.expectError(error.Throw, evalIn("[][Symbol.iterator]().next.call({})"));
    try std.testing.expectError(error.Throw, evalIn("new Map().entries().next.call(new Set())"));
    // Object.create(iterator) only *inherits* the internal slots — next throws.
    try std.testing.expectError(error.Throw, evalIn(
        \\var it = new Set([1]).values();
        \\Object.create(it).next()
    ));
    // The legitimate iterator still iterates.
    try expectEvalStr("1", "var it = new Set([1, 2]).values(); String(it.next().value)");
}

test "WeakMap/WeakSet reject non-weakly-holdable keys; collection toStringTag" {
    // A primitive key/value cannot be held weakly — it throws.
    try std.testing.expectError(error.Throw, evalIn("new WeakMap().set(5, 1)"));
    try std.testing.expectError(error.Throw, evalIn("new WeakSet().add('x')"));
    try std.testing.expectError(error.Throw, evalIn("new WeakSet().add(Symbol.for('registered'))"));
    try std.testing.expect((try evalIn("var s = Symbol('plain'); var ws = new WeakSet(); ws.add(s); ws.has(s)")).asBool());
    // An object key is fine.
    try std.testing.expect((try evalIn("var k = {}; var wm = new WeakMap(); wm.set(k, 1); wm.get(k) === 1")).asBool());
    try std.testing.expect((try evalIn(
        \\var other = $262.createRealm().global;
        \\var C = new other.Function();
        \\C.prototype = null;
        \\Object.getPrototypeOf(Reflect.construct(WeakMap, [], C)) === other.WeakMap.prototype &&
        \\Object.getPrototypeOf(Reflect.construct(WeakSet, [], C)) === other.WeakSet.prototype
    )).asBool());
    // Symbol.toStringTag on the collection prototypes.
    try expectEvalStr("Map", "Map.prototype[Symbol.toStringTag]");
    try expectEvalStr("Set", "Set.prototype[Symbol.toStringTag]");
    try expectEvalStr("WeakMap", "WeakMap.prototype[Symbol.toStringTag]");
    try expectEvalStr("WeakSet", "WeakSet.prototype[Symbol.toStringTag]");
}

test "reserved words may not be binding identifiers" {
    try expectParseError("var if = 1;");
    try expectParseError("var return = 2;");
    try expectParseError("let class = 1;");
    try expectParseError("const while = 1;");
    try expectParseError("var enum = 1;");
    try expectParseError("var \\u0069\\u0066 = 1;"); // `var if` spelled with \u escapes
    // Contextual keywords ARE valid binding names in sloppy mode (must parse).
    _ = try evalIn("var let = 1;");
    _ = try evalIn("var yield = 2;");
    _ = try evalIn("var async = 3;");
    _ = try evalIn("var of = 4, get = 5, set = 6, as = 7, from = 8;");
}

test "destructuring assignment: a rest element must be last" {
    try expectParseError("0, [...x, y] = [];");
    try expectParseError("0, [...x, ...y] = [];");
    try expectParseError("0, ({ ...r, b } = {});");
    // Valid: the rest element IS last.
    _ = try evalIn("var a, b; 0, [a, ...b] = [1, 2, 3];");
    _ = try evalIn("var a, r; 0, ({ a, ...r } = { a: 1, c: 2 });");
}

test "new import(...) is an early error" {
    try expectParseError("new import('x')");
    try expectParseError("do { new import(''); } while (false)");
    try expectParseError("new import('x').then");
    // Ordinary `new` still works (import.meta, which is `.import_meta`, is untouched).
    try std.testing.expect((try evalIn("(new Object()) instanceof Object")).asBool());
    try std.testing.expectEqual(@as(f64, 3), (try evalIn("new Array(1, 2, 3).length")).asNum());
}

test "dynamic import expression evaluation abrupt completions throw synchronously" {
    try expectEvalStr("1:0:1:0",
        \\var specBefore = 0, specAfter = 0, optionsBefore = 0, optionsAfter = 0;
        \\var obj = { get err() { throw new Error("specifier"); } };
        \\function boom() { throw new Error("options"); }
        \\try {
        \\  specBefore += 1, import(obj.err), specAfter += 1;
        \\} catch (e) {
        \\  if (e.message !== "specifier") throw e;
        \\}
        \\try {
        \\  optionsBefore += 1, import("", boom()), optionsAfter += 1;
        \\} catch (e) {
        \\  if (e.message !== "options") throw e;
        \\}
        \\specBefore + ":" + specAfter + ":" + optionsBefore + ":" + optionsAfter
    );
}

test "dynamic import options can suspend in generator bodies" {
    try expectEvalStr("true:595:1:0",
        \\var beforeCount = 0, afterCount = 0;
        \\var iter = (function*() {
        \\  beforeCount += 1, import("", yield), afterCount += 1;
        \\}());
        \\iter.next();
        \\var result = iter.return(595);
        \\result.done + ":" + result.value + ":" + beforeCount + ":" + afterCount
    );
}

test "dynamic import returns the intrinsic Promise" {
    const ctx = try Context.create(std.testing.allocator);
    defer ctx.destroy();

    try evaluateModuleWithFixturesInContext(ctx,
        \\const originalPromise = Promise;
        \\globalThis.Promise = function() { throw new Error("global Promise called"); };
        \\const p = import("./dep.js");
        \\globalThis.dynamicImportPromiseCheck =
        \\  p.constructor === originalPromise &&
        \\  Object.getPrototypeOf(p) === originalPromise.prototype &&
        \\  p.then === originalPromise.prototype.then &&
        \\  p.catch === originalPromise.prototype.catch &&
        \\  p.finally === originalPromise.prototype.finally &&
        \\  !Object.prototype.hasOwnProperty.call(p, "then") &&
        \\  !Object.prototype.hasOwnProperty.call(p, "catch") &&
        \\  !Object.prototype.hasOwnProperty.call(p, "finally");
    , &.{.{ .path = "dep.js", .source = "export const value = 1;" }});

    try std.testing.expect((try ctx.evaluate("dynamicImportPromiseCheck")).asBool());
}

test "dynamic import namespace primitive conversion uses exported methods" {
    const ctx = try Context.create(std.testing.allocator);
    defer ctx.destroy();

    try evaluateModuleWithFixturesInContext(ctx,
        \\globalThis.dynamicImportPrimitiveCheck = "";
        \\import("./to-string.js").then(function(ns) {
        \\  globalThis.dynamicImportPrimitiveCheck += String(ns) + ":" + Number(ns) + ";";
        \\});
        \\import("./value-of.js").then(function(ns) {
        \\  globalThis.dynamicImportPrimitiveCheck += Number(ns) + ":" + String(ns) + ";";
        \\});
    , &.{
        .{ .path = "to-string.js", .source = "export function toString() { return '1612'; }" },
        .{ .path = "value-of.js", .source = "export function valueOf() { return 42; }" },
    });

    try std.testing.expectEqualStrings("1612:1612;42:42;", (try ctx.evaluate("dynamicImportPrimitiveCheck")).asStr());
}

test "dynamic import source phase rejects source text modules" {
    const ctx = try Context.create(std.testing.allocator);
    defer ctx.destroy();

    try evaluateModuleWithFixturesInContext(ctx,
        \\globalThis.dynamicImportSourcePhaseCheck = "";
        \\import.source("./dep.js").catch(function(error) {
        \\  globalThis.dynamicImportSourcePhaseCheck = error.name;
        \\});
    , &.{.{ .path = "dep.js", .source = "export const value = 1;" }});

    try std.testing.expectEqualStrings("SyntaxError", (try ctx.evaluate("dynamicImportSourcePhaseCheck")).asStr());
}

test "dynamic import rejects invalid indirect exports" {
    const ctx = try Context.create(std.testing.allocator);
    defer ctx.destroy();

    try evaluateModuleWithFixturesInContext(ctx,
        \\globalThis.dynamicImportBadIndirect = "";
        \\import("./ambiguous-export.js").catch(function(error) {
        \\  globalThis.dynamicImportBadIndirect += error.name + ":ambiguous;";
        \\});
        \\import("./circular-1.js").catch(function(error) {
        \\  globalThis.dynamicImportBadIndirect += error.name + ":circular;";
        \\});
    , &.{
        .{ .path = "ambiguous-export.js", .source = "export { x } from './ambiguous.js';" },
        .{ .path = "ambiguous.js", .source = "export * from './one.js'; export * from './two.js';" },
        .{ .path = "one.js", .source = "export var x;" },
        .{ .path = "two.js", .source = "export var x;" },
        .{ .path = "circular-1.js", .source = "export { x } from './circular-2.js';" },
        .{ .path = "circular-2.js", .source = "export { x } from './circular-1.js';" },
    });

    try std.testing.expectEqualStrings("SyntaxError:ambiguous;SyntaxError:circular;", (try ctx.evaluate("dynamicImportBadIndirect")).asStr());
}

test "dynamic import rejects repeated imports of an errored module" {
    const ctx = try Context.create(std.testing.allocator);
    defer ctx.destroy();

    try evaluateModuleWithFixturesInContext(ctx,
        \\globalThis.dynamicImportErroredModule = "";
        \\import("./bad.js").then(
        \\  function() { globalThis.dynamicImportErroredModule += "fulfilled:first;"; },
        \\  function(error) {
        \\    globalThis.dynamicImportErroredModule += error.message + ":first;";
        \\    return import("./bad.js").then(
        \\      function() { globalThis.dynamicImportErroredModule += "fulfilled:second;"; },
        \\      function(error) { globalThis.dynamicImportErroredModule += error.message + ":second;"; }
        \\    );
        \\  }
        \\);
    , &.{
        .{ .path = "bad.js", .source = "throw new Error('boom');" },
    });

    try std.testing.expectEqualStrings("boom:first;boom:second;", (try ctx.evaluate("dynamicImportErroredModule")).asStr());
}

test "delete of a private member is an early error" {
    try expectParseError("({}).#x");
    try expectParseError("class C { #x = 1; m() { delete this.#x; } }");
    try expectParseError("class C { #x = 1; m() { delete (this.#x); } }"); // parenthesized (covered)
    // Deleting a public property — even of an object reached through a private
    // field — is allowed.
    _ = try evalIn("class C { #x = {}; m() { return delete this.#x.y; } }");
    try std.testing.expect((try evalIn("delete ({ a: 1 }).a")).asBool());
}

test "duplicate lexical declarations are early errors" {
    // Same-scope let/const/class duplicates, and async/generator-function dups.
    try expectParseError("{ let x; let x; }");
    try expectParseError("{ let x; const x; }");
    try expectParseError("{ class C {} let C; }");
    try expectParseError("{ async function f() {} async function f() {} }");
    try expectParseError("{ function* g() {} let g; }");
    try expectParseError("switch (0) { case 1: let y; break; default: let y; }");
    // Valid (must NOT be rejected): shadowing in a nested/sibling scope, var
    // redeclaration, and — per Annex B — two *plain* function declarations in a
    // sloppy block.
    _ = try evalIn("let x = 1; { let x = 2; } x");
    _ = try evalIn("{ let a = 1; } { let a = 2; }");
    try std.testing.expect((try evalIn("var v = 1; var v = 2; v")).asNum() == 2);
    _ = try evalIn("{ function f() { return 1; } function f() { return 2; } f(); }");
}

test "numeric separators: valid between digits, rejected when misplaced" {
    // Valid: a `_` between two digits of the radix.
    try std.testing.expectEqual(@as(f64, 1000), (try evalIn("1_000")).asNum());
    try std.testing.expectEqual(@as(f64, 2), (try evalIn("0b1_0")).asNum());
    try std.testing.expectEqual(@as(f64, 31), (try evalIn("0x1_F")).asNum());
    try std.testing.expectEqual(@as(f64, 10.01), (try evalIn("1_0.0_1")).asNum());
    try std.testing.expectEqual(@as(f64, 1e10), (try evalIn("1e1_0")).asNum());
    // Misplaced separators are early errors.
    for ([_][]const u8{ "_1", "1_", "1__0", "0x_1", "0b1_", "1_.5", "1._5", "1_e3", "1e_3", "0_1", "0_8" }) |bad|
        try expectParseError(bad);
}

test "Math.sumPrecise sums exactly" {
    try std.testing.expectEqual(@as(f64, 6), (try evalIn("Math.sumPrecise([1, 2, 3])")).asNum());
    // Exact summation survives intermediate overflow + cancellation.
    try std.testing.expectEqual(@as(f64, 0.30000000000000004), (try evalIn(
        \\Math.sumPrecise([1e308, 1e308, 0.1, 0.1, 1e30, 0.1, -1e30, -1e308, -1e308])
    )).asNum());
    try std.testing.expectEqual(@as(f64, 0), (try evalIn("Math.sumPrecise([1e308, -1e308])")).asNum());
    // Special values.
    try std.testing.expect(std.math.isNan((try evalIn("Math.sumPrecise([NaN, 1])")).asNum()));
    try std.testing.expect(std.math.isNan((try evalIn("Math.sumPrecise([Infinity, -Infinity])")).asNum()));
    try std.testing.expect((try evalIn("Math.sumPrecise([Infinity, 1])")).asNum() == std.math.inf(f64));
    // Empty is -0; a finite cancellation is +0; all -0 is -0.
    try std.testing.expect((try evalIn("1 / Math.sumPrecise([])")).asNum() == -std.math.inf(f64));
    try std.testing.expect((try evalIn("1 / Math.sumPrecise([0.1, -0.1])")).asNum() == std.math.inf(f64));
    try std.testing.expect((try evalIn("1 / Math.sumPrecise([-0, -0])")).asNum() == -std.math.inf(f64));
    // A non-Number element and a non-iterable argument both throw.
    try std.testing.expectError(error.Throw, evalIn("Math.sumPrecise([1, '2'])"));
    try std.testing.expectError(error.Throw, evalIn("Math.sumPrecise(5)"));
}

test "Math.f16round rounds to binary16" {
    try std.testing.expect((try evalIn("typeof Math.f16round === 'function'")).asBool());
    try std.testing.expectEqual(@as(f64, 1.5), (try evalIn("Math.f16round(1.5)")).asNum()); // exact in f16
    try std.testing.expectEqual(@as(f64, 65504), (try evalIn("Math.f16round(65504)")).asNum()); // max f16
    try std.testing.expect((try evalIn("Math.f16round(65536)")).asNum() == std.math.inf(f64)); // overflows f16
    try std.testing.expect(std.math.isNan((try evalIn("Math.f16round(NaN)")).asNum()));
    try std.testing.expect((try evalIn("Math.f16round(Infinity)")).asNum() == std.math.inf(f64));
    // 1.337 is not representable; rounds to the nearest binary16 value.
    try std.testing.expectEqual(@as(f64, 1.3369140625), (try evalIn("Math.f16round(1.337)")).asNum());
}

test "Math: signed-zero, pow/hypot edge cases, prototype + toStringTag" {
    // max prefers +0, min prefers -0.
    try std.testing.expect((try evalIn("1 / Math.max(-0, 0)")).asNum() == std.math.inf(f64));
    try std.testing.expect((try evalIn("1 / Math.min(0, -0)")).asNum() == -std.math.inf(f64));
    // round of a value that rounds to zero keeps the operand's sign.
    try std.testing.expect((try evalIn("1 / Math.round(-0.5)")).asNum() == -std.math.inf(f64));
    try std.testing.expect((try evalIn(
        \\var x = -(2 / Number.EPSILON - 1);
        \\Math.round(x) === x
    )).asBool());
    try std.testing.expect((try evalIn(
        \\var calls = 0;
        \\Math.max(NaN, { valueOf: function() { calls++; } });
        \\calls === 1
    )).asBool());
    try std.testing.expect((try evalIn(
        \\var calls = 0;
        \\Math.min(NaN, { valueOf: function() { calls++; } });
        \\calls === 1
    )).asBool());
    // pow: NaN exponent and (±1, ±Infinity) are NaN.
    try std.testing.expect(std.math.isNan((try evalIn("Math.pow(1, NaN)")).asNum()));
    try std.testing.expect(std.math.isNan((try evalIn("Math.pow(-1, Infinity)")).asNum()));
    // hypot: ±Infinity wins over a NaN argument.
    try std.testing.expect((try evalIn("Math.hypot(NaN, Infinity)")).asNum() == std.math.inf(f64));
    // each element is ToNumber-coerced (a Symbol throws).
    try std.testing.expectError(error.Throw, evalIn("Math.max(1, Symbol())"));
    // Math is an ordinary object with the right prototype + tag.
    try std.testing.expect((try evalIn("Object.getPrototypeOf(Math) === Object.prototype")).asBool());
    try expectEvalStr("[object Math]", "Object.prototype.toString.call(Math)");
}

test "Map/Set constructors take any iterable (AddEntriesFromIterable)" {
    // A non-array iterable (here a Set / a string) populates the collection.
    try std.testing.expectEqual(@as(f64, 3), (try evalIn("new Set('abc').size")).asNum());
    try std.testing.expectEqual(@as(f64, 2), (try evalIn("new Map(new Map([['a',1],['b',2]])).size")).asNum());
    // A generator of entries works for Map.
    try std.testing.expectEqual(@as(f64, 7), (try evalIn(
        \\function* g() { yield ['x', 3]; yield ['y', 4]; }
        \\var m = new Map(g()); m.get('x') + m.get('y')
    )).asNum());
    try std.testing.expect((try evalIn(
        \\function Target() {}
        \\Target.prototype = null;
        \\Object.getPrototypeOf(Reflect.construct(Map, [], Target)) === Map.prototype
    )).asBool());
    try std.testing.expect((try evalIn(
        \\var other = $262.createRealm().global;
        \\other.Set.prototype.marker = true;
        \\var s = Reflect.construct(Set, [], other.Set);
        \\Object.getPrototypeOf(s) === other.Set.prototype && s.marker === true
    )).asBool());
    // A non-object Map entry, a non-iterable argument, and a non-callable adder
    // each throw a TypeError.
    try std.testing.expectError(error.Throw, evalIn("new Map([1, 2])"));
    try std.testing.expectError(error.Throw, evalIn("new Map({})"));
    try std.testing.expectError(error.Throw, evalIn(
        \\var nextItem = Symbol('a');
        \\var iterable = {};
        \\iterable[Symbol.iterator] = function() {
        \\  return { next: function() { return { value: nextItem, done: false }; }, return: function() {} };
        \\};
        \\new Map(iterable);
    ));
    // The instance's own (possibly overridden) `set` is the adder.
    try std.testing.expectEqual(@as(f64, 1), (try evalIn(
        \\var calls = 0;
        \\class M extends Map { set(k, v) { calls++; return super.set(k, v); } }
        \\new M([['a', 1]]); calls
    )).asNum());
}

test "Map/Set expose [Symbol.iterator]; Set keys === values" {
    // `Map.prototype[Symbol.iterator]` is the same function as `entries`, and
    // `Set.prototype[Symbol.iterator]`/`keys`/`values` are all the same.
    try std.testing.expect((try evalIn("Map.prototype[Symbol.iterator] === Map.prototype.entries")).asBool());
    try std.testing.expect((try evalIn("Set.prototype[Symbol.iterator] === Set.prototype.values")).asBool());
    try std.testing.expect((try evalIn("Set.prototype.keys === Set.prototype.values")).asBool());
    // for-of and spread over a Map/Set go through the property iterator.
    try expectEvalStr("a,1|b,2",
        \\var m = new Map([['a', 1], ['b', 2]]);
        \\var out = []; for (var e of m) out.push(e[0] + ',' + e[1]); out.join('|')
    );
    try expectEvalStr("1,2,3", "[...new Set([1, 2, 3])].join(',')");
}

test "Map/Set forEach tolerate deletion during iteration" {
    try std.testing.expectEqual(@as(f64, 1), (try evalIn(
        \\var map = new Map();
        \\map.set('foo', 0);
        \\map.set('bar', 1);
        \\var count = 0;
        \\map.forEach(function(value, key) { if (count === 0) map.delete('bar'); count++; });
        \\count
    )).asNum());
    try std.testing.expectEqual(@as(f64, 1), (try evalIn(
        \\var set = new Set(['foo', 'bar']);
        \\var count = 0;
        \\set.forEach(function(value) { if (count === 0) set.delete('bar'); count++; });
        \\count
    )).asNum());
    try expectEvalStr("1,2,3,1|3|2,3,1",
        \\var set = new Set([1, 2, 3]);
        \\var out = [];
        \\set.forEach(function(value) {
        \\  out.push(value);
        \\  if (value === 2) set.delete(1);
        \\  if (value === 3) set.add(1);
        \\});
        \\out.join(',') + '|' + set.size + '|' + Array.from(set).join(',')
    );
    try expectEvalStr("foo:0|bar:1|foo:baz",
        \\var map = new Map([['foo', 0], ['bar', 1]]);
        \\var out = [];
        \\map.forEach(function(value, key) {
        \\  out.push(key + ':' + value);
        \\  if (key === 'foo' && value === 0) {
        \\    map.delete('foo');
        \\    map.set('foo', 'baz');
        \\  }
        \\});
        \\out.join('|')
    );
    try std.testing.expectEqual(@as(f64, 2), (try evalIn(
        \\var map = new Map([['foo', 0], ['bar', 1]]);
        \\map.delete('foo');
        \\map.set('foo', 'baz');
        \\map.size
    )).asNum());
}

test "Map getOrInsertComputed validates callback and canonicalizes keys" {
    try std.testing.expect((try evalIn(
        \\var ok = false;
        \\var map = new Map([[1, 'present']]);
        \\try { map.getOrInsertComputed(1, 1); } catch (e) { ok = e instanceof TypeError; }
        \\ok
    )).asBool());
    try std.testing.expect((try evalIn(
        \\var seen;
        \\var map = new Map();
        \\map.getOrInsertComputed(-0, function(key) { seen = 1 / key; return 'value'; });
        \\seen === Infinity && map.has(+0) && map.has(-0)
    )).asBool());
}

test "oversized BigInt literals preserve identity for keyed collections" {
    try std.testing.expect((try evalIn(
        \\var s = '100000000000000000000000000000000000000000000000000000000000000000000000000000000001';
        \\var n = 100000000000000000000000000000000000000000000000000000000000000000000000000000000001n;
        \\n === BigInt(s) && String(n) === s
    )).asBool());
    try std.testing.expect((try evalIn(
        \\var s = '100000000000000000000000000000000000000000000000000000000000000000000000000000000001';
        \\var n = 100000000000000000000000000000000000000000000000000000000000000000000000000000000001n;
        \\var m = new Map([[n, 'ok']]);
        \\m.get(BigInt(s)) === 'ok' && m.has(n)
    )).asBool());
}

test "BigInt constructor parses oversized radix strings and rejects construction early" {
    try std.testing.expect((try evalIn(
        \\var bits = '1';
        \\for (var i = 0; i < 128; i++) bits += '0';
        \\var decimal = '340282366920938463463374607431768211456';
        \\BigInt('0b' + bits) === BigInt(decimal) && BigInt('0B' + bits) === BigInt(decimal)
    )).asBool());
    try std.testing.expect((try evalIn(
        \\var probed = false;
        \\try { Reflect.construct(function() {}, [], BigInt); probed = true; } catch (e) {}
        \\var touched = false;
        \\var threw = false;
        \\try { new BigInt({ valueOf: function() { touched = true; return 1; } }); }
        \\catch (e) { threw = e instanceof TypeError; }
        \\probed && threw && !touched
    )).asBool());
}

test "Object boxes BigInt primitives through BigInt.prototype" {
    try std.testing.expect((try evalIn(
        \\var boxed = Object(1n);
        \\boxed !== 1n && Object.getPrototypeOf(boxed) === BigInt.prototype
    )).asBool());
    try std.testing.expect((try evalIn(
        \\var original = BigInt.prototype.toString;
        \\var gets = 0;
        \\var calls = 0;
        \\Object.defineProperty(BigInt.prototype, 'toString', {
        \\  configurable: true,
        \\  get: function() {
        \\    gets++;
        \\    return function() { calls++; return original.call(this) + 'foo'; };
        \\  }
        \\});
        \\var out = `${Object(1n)}`;
        \\delete BigInt.prototype.toString;
        \\Object.defineProperty(BigInt.prototype, 'toString', { configurable: true, writable: true, value: original });
        \\out === '1foo' && gets === 1 && calls === 1
    )).asBool());
}

test "BigInt.asIntN/asUintN wrap text-backed BigInts" {
    try std.testing.expect((try evalIn(
        \\-0x100000000000000000000000000000000n === BigInt('-340282366920938463463374607431768211456')
    )).asBool());
    try std.testing.expect((try evalIn(
        \\~0x100000000000000000000000000000000n === BigInt('-340282366920938463463374607431768211457')
    )).asBool());
    try std.testing.expect((try evalIn(
        \\BigInt.asUintN(200,
        \\  0xbffffffffffffffffffffffffffffffffffffffffffffffffffn
        \\) === 0x0ffffffffffffffffffffffffffffffffffffffffffffffffffn
    )).asBool());
    try std.testing.expect((try evalIn(
        \\BigInt.asIntN(200,
        \\  0xcffffffffffffffffffffffffffffffffffffffffffffffffffn
        \\) === -1n
    )).asBool());
    try std.testing.expect((try evalIn(
        \\BigInt.asIntN(201,
        \\  0xc89e081df68b65fedb32cffea660e55df9605650a603ad5fc54n
        \\) === 0x89e081df68b65fedb32cffea660e55df9605650a603ad5fc54n
    )).asBool());
}

test "__lookupGetter__/__lookupSetter__ walk the chain, proxy-aware" {
    // Returns the accessor's getter; a data property yields undefined.
    try std.testing.expect((try evalIn("var o = { get x() { return 1; } }; o.__lookupGetter__('x') === Object.getOwnPropertyDescriptor(o, 'x').get")).asBool());
    try std.testing.expect((try evalIn("({ a: 1 }).__lookupGetter__('a')")).isUndefined());
    // Walks the prototype chain to find an inherited accessor.
    try std.testing.expect((try evalIn(
        \\var proto = { get y() { return 2; } };
        \\var o = Object.create(proto);
        \\o.__lookupGetter__('y') === Object.getOwnPropertyDescriptor(proto, 'y').get
    )).asBool());
    // A throwing [[GetOwnProperty]] trap propagates.
    try std.testing.expectError(error.Throw, evalIn(
        \\var p = new Proxy({}, { getOwnPropertyDescriptor() { throw new TypeError('x'); } });
        \\p.__lookupGetter__('z');
    ));
}

test "__defineGetter__/__defineSetter__ honor DefinePropertyOrThrow" {
    // Success: installs an accessor.
    try std.testing.expectEqual(@as(f64, 5), (try evalIn(
        \\var o = {}; o.__defineGetter__('x', function () { return 5; }); o.x
    )).asNum());
    // Redefining a non-configurable property throws.
    try std.testing.expectError(error.Throw, evalIn(
        \\var o = Object.defineProperty({}, 'a', { value: 1, configurable: false });
        \\o.__defineGetter__('a', function () {});
    ));
    // Defining a new property on a non-extensible object throws.
    try std.testing.expectError(error.Throw, evalIn(
        \\var o = Object.preventExtensions({});
        \\o.__defineSetter__('b', function () {});
    ));
    // A non-callable getter throws.
    try std.testing.expectError(error.Throw, evalIn("({}).__defineGetter__('a', 42)"));
}

test "plain objects inherit from Object.prototype" {
    // The [[Prototype]] of a plain object / object literal is Object.prototype.
    try std.testing.expect((try evalIn("Object.getPrototypeOf({}) === Object.prototype")).asBool());
    try std.testing.expect((try evalIn("({}).__proto__ === Object.prototype")).asBool());
    // Inherited Object.prototype methods resolve through the chain (as values and calls).
    try std.testing.expect((try evalIn("typeof ({}).hasOwnProperty === 'function'")).asBool());
    try std.testing.expect((try evalIn("({ a: 1 }).hasOwnProperty('a')")).asBool());
    try std.testing.expect((try evalIn("'toString' in {}")).asBool());
    try expectEvalStr("[object Object]", "({}).toString()");
    // Object.prototype.valueOf returns the object itself.
    try std.testing.expect((try evalIn("var o = {}; o.valueOf() === o")).asBool());
    try std.testing.expect((try evalIn(
        \\var subject = {};
        \\var set = Object.getOwnPropertyDescriptor(Object.prototype, "__proto__").set;
        \\set.call(subject, Symbol());
        \\Object.getPrototypeOf(subject) === Object.prototype
    )).asBool());
    try std.testing.expectError(error.Throw, evalIn(
        \\var get = Object.getOwnPropertyDescriptor(Object.prototype, "__proto__").get;
        \\get.call(new Proxy({}, { getPrototypeOf() { throw new Error("boom"); } }));
    ));
    try std.testing.expectError(error.Throw, evalIn("Object.setPrototypeOf(Object.prototype, {})"));
    try std.testing.expect(!(try evalIn("Reflect.setPrototypeOf(Object.prototype, {})")).asBool());
    // A user toString on the chain still wins.
    try expectEvalStr("hi", "var o = { toString() { return 'hi'; } }; o.toString()");
    // Object.create(null) keeps a null prototype; for-in over {} sees no inherited keys.
    try std.testing.expect((try evalIn("Object.getPrototypeOf(Object.create(null)) === null")).asBool());
    try std.testing.expectEqual(@as(f64, 0), (try evalIn("var n = 0; for (var k in {}) n++; n")).asNum());
    // Class/function .prototype objects inherit from Object.prototype too.
    try std.testing.expect((try evalIn("function F() {} Object.getPrototypeOf(F.prototype) === Object.prototype")).asBool());
}

test "Symbol() and Symbol.for() ToString their argument" {
    // A `{toString}` object is honored as the description / registry key.
    try expectEvalStr("k", "Symbol({ toString() { return 'k'; } }).description");
    try expectEvalStr("test262", "Symbol.for({ toString() { return 'test262'; } }).description");
    // A Symbol description / key is a TypeError, and a throwing toString propagates.
    try std.testing.expectError(error.Throw, evalIn("Symbol(Symbol())"));
    try std.testing.expectError(error.Throw, evalIn("Symbol.for({ toString() { throw new TypeError('x'); } })"));
}

test "string concatenation rejects Symbols through ToString" {
    try std.testing.expectError(error.Throw, evalIn("'x' + Symbol.iterator"));
    try std.testing.expectError(error.Throw, evalIn("Symbol.iterator + 'x'"));
    try expectEvalStr("x1", "'x' + 1n");
}

test "Reflect: prototype, toStringTag, array-like argumentsList" {
    try std.testing.expect((try evalIn("Object.getPrototypeOf(Reflect) === Object.prototype")).asBool());
    try expectEvalStr("Reflect", "Reflect[Symbol.toStringTag]");
    // apply/construct accept an array-like (not just a real Array) argumentsList.
    try std.testing.expectEqual(@as(f64, 2), (try evalIn(
        \\Reflect.apply(function () { return arguments.length; }, null, { length: 2, 0: 'a', 1: 'b' })
    )).asNum());
    try std.testing.expectEqual(@as(f64, 5), (try evalIn(
        \\function P(a, b) { this.sum = a + b; }
        \\Reflect.construct(P, { length: 2, 0: 2, 1: 3 }).sum
    )).asNum());
    // apply on a non-callable target throws; a throwing length getter propagates.
    try std.testing.expectError(error.Throw, evalIn("Reflect.apply({}, null, [])"));
    try std.testing.expectError(error.Throw, evalIn("Reflect.apply(function(){}, null, { get length() { throw new TypeError('x'); } })"));
}

test "Reflect.* require a real Object target (Symbol/primitive throws)" {
    // A Symbol is internally object-tagged, but Reflect.* must reject it.
    try std.testing.expectError(error.Throw, evalIn("Reflect.get(Symbol(), 'x')"));
    try std.testing.expectError(error.Throw, evalIn("Reflect.ownKeys(Symbol())"));
    try std.testing.expectError(error.Throw, evalIn("Reflect.isExtensible(1)"));
    try std.testing.expectError(error.Throw, evalIn("Reflect.getOwnPropertyDescriptor(1, 'x')"));
    try std.testing.expectError(error.Throw, evalIn("Reflect.preventExtensions('s')"));
    try std.testing.expectError(error.Throw, evalIn("Reflect.setPrototypeOf(Symbol(), null)"));
    try std.testing.expectError(error.Throw, evalIn("Object.setPrototypeOf({}, Symbol())"));
    // setPrototypeOf returns a boolean: true on success, false (not a throw) on
    // a non-extensible target.
    try std.testing.expect((try evalIn("Reflect.setPrototypeOf({}, null)")).asBool());
    try std.testing.expect(!(try evalIn(
        \\var o = {}; Object.preventExtensions(o);
        \\Reflect.setPrototypeOf(o, { a: 1 })
    )).asBool());
}

test "NativeError constructors inherit from Error; Error from Function.prototype" {
    // Each NativeError constructor's [[Prototype]] is the Error constructor.
    try std.testing.expect((try evalIn("Object.getPrototypeOf(TypeError) === Error")).asBool());
    try std.testing.expect((try evalIn("Object.getPrototypeOf(RangeError) === Error")).asBool());
    try std.testing.expect((try evalIn("Object.getPrototypeOf(AggregateError) === Error")).asBool());
    // Error itself is a function, so its [[Prototype]] is Function.prototype.
    try std.testing.expect((try evalIn("Object.getPrototypeOf(Error) === Function.prototype")).asBool());
    // The prototype chain was already linked: TypeError.prototype -> Error.prototype.
    try std.testing.expect((try evalIn("Object.getPrototypeOf(TypeError.prototype) === Error.prototype")).asBool());
    // Static inheritance through the constructor chain works.
    try std.testing.expect((try evalIn("typeof TypeError.isError === 'function'")).asBool());
}

test "parseInt skips the full StrWhiteSpace set" {
    // U+2028/U+2029 line separators and non-ASCII spaces are leading whitespace.
    try std.testing.expectEqual(@as(f64, 1), (try evalIn("parseInt('\\u20281')")).asNum());
    try std.testing.expectEqual(@as(f64, 1), (try evalIn("parseInt('\\u20291')")).asNum());
    try std.testing.expectEqual(@as(f64, 42), (try evalIn("parseInt('\\u00A0\\u000B42')")).asNum());
    try std.testing.expectEqual(@as(f64, 255), (try evalIn("parseInt('  0xff')")).asNum());
}

test "parseFloat: Unicode whitespace, Infinity, and no numeric separators" {
    // Leading StrWhiteSpace (incl. VT/FF/NBSP) is skipped, like `1.1`.
    try std.testing.expectEqual(@as(f64, 1.1), (try evalIn("parseFloat('\\u000B\\u000C\\u00A01.1')")).asNum());
    // Longest StrDecimalLiteral prefix; trailing junk and `_` separators stop it.
    try std.testing.expectEqual(@as(f64, 3.14), (try evalIn("parseFloat('3.14abc')")).asNum());
    try std.testing.expectEqual(@as(f64, 1), (try evalIn("parseFloat('1_0')")).asNum());
    try std.testing.expectEqual(@as(f64, 1e100), (try evalIn("parseFloat('1e+100')")).asNum());
    // Signed Infinity, and a bare `e` is not part of the number.
    try std.testing.expect(std.math.isInf((try evalIn("parseFloat('-Infinity')")).asNum()));
    try std.testing.expectEqual(@as(f64, 1), (try evalIn("parseFloat('1e')")).asNum());
    try std.testing.expect(std.math.isNan((try evalIn("parseFloat('.e5')")).asNum()));
    try std.testing.expectEqual(@as(f64, 1), (try evalIn("parseFloat('0.1e1' + String.fromCharCode(0x0130))")).asNum());
    try std.testing.expectEqual(@as(f64, 0), (try evalIn("parseFloat({ valueOf: function() { return 1; }, toString: function() { return 0; } })")).asNum());
    try std.testing.expectEqual(@as(f64, 1), (try evalIn("parseFloat({ valueOf: function() { return 1; }, toString: function() { return {}; } })")).asNum());
    try std.testing.expectError(error.Throw, evalIn("parseFloat({ valueOf: function() { return 1; }, toString: function() { throw 'error'; } })"));
}

test "parseInt radix coercion follows ToInt32" {
    try std.testing.expectEqual(@as(f64, 3), (try evalIn("parseInt('11', 4294967298)")).asNum());
    try std.testing.expectEqual(@as(f64, 3), (try evalIn("parseInt('11', -4294967294)")).asNum());
    try std.testing.expect(std.math.isNan((try evalIn("parseInt('0', 1)")).asNum()));
    try std.testing.expect(std.math.isNan((try evalIn("parseInt('0', 37)")).asNum()));
    try std.testing.expectEqual(@as(f64, 1), (try evalIn("parseInt('0x1', 0)")).asNum());
    try std.testing.expectEqual(@as(f64, 3), (try evalIn("parseInt('11', { valueOf: function() { return 2; }, toString: function() { throw 'error'; } })")).asNum());
}

test "URI encode/decode handles surrogate pairs" {
    try expectEvalStr("%F0%90%80%80", "encodeURI(String.fromCharCode(0xD800, 0xDC00))");
    try expectEvalStr("%F4%8F%BF%BF", "encodeURIComponent(String.fromCharCode(0xDBFF, 0xDFFF))");
    try std.testing.expect((try evalIn("decodeURI('%F0%90%80%80') === String.fromCharCode(0xD800, 0xDC00)")).asBool());
    try std.testing.expect((try evalIn("decodeURIComponent('%F4%8F%BF%BF') === String.fromCharCode(0xDBFF, 0xDFFF)")).asBool());
    try std.testing.expectError(error.Throw, evalIn("encodeURI(String.fromCharCode(0xD800))"));
    try std.testing.expectError(error.Throw, evalIn("encodeURIComponent(String.fromCharCode(0xDC00))"));
}

test "DataView constructor observes NewTarget prototype side effects" {
    try std.testing.expect((try evalIn(
        \\var other = $262.createRealm().global;
        \\var C = new other.Function();
        \\C.prototype = null;
        \\var view = Reflect.construct(DataView, [new ArrayBuffer(0), 0], C);
        \\Object.getPrototypeOf(view) === other.DataView.prototype
    )).asBool());
    try std.testing.expect((try evalIn(
        \\var buffer = new ArrayBuffer(8);
        \\var called = false;
        \\var byteOffset = { valueOf: function() { called = true; return 0; } };
        \\var newTarget = function() {}.bind(null);
        \\Object.defineProperty(newTarget, "prototype", { get: function() { $262.detachArrayBuffer(buffer); return DataView.prototype; } });
        \\var ok = false;
        \\try { Reflect.construct(DataView, [buffer, byteOffset], newTarget); } catch (e) { ok = e instanceof TypeError; }
        \\ok && called
    )).asBool());
    try std.testing.expect((try evalIn(
        \\var buffer = new ArrayBuffer(3, { maxByteLength: 3 });
        \\var newTarget = function() {}.bind(null);
        \\Object.defineProperty(newTarget, "prototype", { get: function() { buffer.resize(2); } });
        \\var view = Reflect.construct(DataView, [buffer, 2], newTarget);
        \\view.byteLength === 0
    )).asBool());
    try std.testing.expect((try evalIn(
        \\var buffer = new ArrayBuffer(3, { maxByteLength: 3 });
        \\var newTarget = function() {}.bind(null);
        \\Object.defineProperty(newTarget, "prototype", { get: function() { buffer.resize(2); } });
        \\var ok = false;
        \\try { Reflect.construct(DataView, [buffer, 1, 2], newTarget); } catch (e) { ok = e instanceof RangeError; }
        \\ok
    )).asBool());
}

test "isFinite / isNaN coerce via ToNumber (Symbol throws, strings convert)" {
    // `Let num be ? ToNumber(number)`: strings/booleans convert, a Symbol throws.
    try std.testing.expect((try evalIn("isFinite('0')")).asBool());
    try std.testing.expect(!(try evalIn("isFinite('Infinity')")).asBool());
    try std.testing.expect((try evalIn("isNaN('not a number')")).asBool());
    try std.testing.expect(!(try evalIn("isNaN('42')")).asBool());
    try std.testing.expectError(error.Throw, evalIn("isFinite(Symbol())"));
    try std.testing.expectError(error.Throw, evalIn("isNaN(Symbol())"));
}

test "Number string conversion trims ECMAScript whitespace" {
    try std.testing.expectEqual(@as(f64, 0), (try evalIn("Number('\\u00A0\\u1680\\u2000\\u2028\\u2029\\u202F\\u205F\\u3000')")).asNum());
    try std.testing.expectEqual(@as(f64, 1234567890), (try evalIn(
        \\Number('\u000B\u00A0\u1680\u20001234567890\u2028\u2029\u202F\u205F\u3000')
    )).asNum());
    try std.testing.expect((try evalIn(
        \\Number('\u00A0\u2000Infinity\u202F') === Infinity
    )).asBool());
    try std.testing.expect((try evalIn(
        \\Number('\u00A0\u2000-Infinity\u202F') === -Infinity
    )).asBool());
}

test "strict arguments.callee is the %ThrowTypeError% poison pill" {
    // Reading or writing `arguments.callee` in a strict function throws TypeError,
    // and its accessor get is the single shared %ThrowTypeError% intrinsic.
    try std.testing.expect((try evalIn(
        \\function f() { "use strict"; try { arguments.callee; return false; } catch (e) { return e instanceof TypeError; } }
        \\f()
    )).asBool());
    // The same intrinsic backs both `arguments.callee` and `Function.prototype.caller`.
    try std.testing.expect((try evalIn(
        \\var g = function () { "use strict"; return arguments; }();
        \\var callee = Object.getOwnPropertyDescriptor(g, "callee").get;
        \\var caller = Object.getOwnPropertyDescriptor(Function.prototype, "caller").get;
        \\callee === caller
    )).asBool());
}

test "Number/Boolean/String prototypes are Exotic Objects with their primitive" {
    // Per spec, `Number.prototype` has [[NumberData]] = +0, `Boolean.prototype`
    // has [[BooleanData]] = false, `String.prototype` has [[StringData]] = "" —
    // so the brand-checked methods accept the prototype itself as the boxed value.
    try expectEvalStr("0", "Number.prototype.toString()");
    try expectEvalStr("0", "Number.prototype.toString(2)");
    try expectEvalStr("false", "Boolean.prototype.toString()");
    // Object.prototype.toString uses the primitive to determine the tag.
    try expectEvalStr("[object Number]", "Object.prototype.toString.call(Number.prototype)");
    try expectEvalStr("[object String]", "Object.prototype.toString.call(String.prototype)");
}

test "String.prototype.trim strips the full WhiteSpace + LineTerminator set" {
    // VT (0x0B), FF (0x0C), NBSP (0x00A0), and the ideographic space (U+3000)
    // are all spec WhiteSpace, and U+2028/U+2029 are LineTerminators — all stripped.
    try expectEvalStr("abc", "'\\x0B\\x0C\\u00A0abc\\u3000 '.trim()");
    try expectEvalStr("abc", "'\\u2028\\u2029abc\\u00A0'.trim()");
    // trimStart leaves trailing whitespace untouched; trimEnd leaves the leading.
    try expectEvalStr("abc ", "'\\u00A0\\u3000abc '.trimStart()");
    try expectEvalStr("abc", "'abc\\u00A0\\u3000\\u2028'.trimEnd()");
}

test "Array.prototype.concat honors Symbol.isConcatSpreadable" {
    // A real array spreads; a plain object is appended whole.
    try expectEvalStr("1,2,3,4", "[1, 2].concat([3, 4]).join(',')");
    try expectEvalStr("1", "[].concat({ length: 2, 0: 'a' }).length.toString()");
    // An array-like with isConcatSpreadable = true is spread by ToLength(length).
    try expectEvalStr("a,b", "var o = { length: 2, 0: 'a', 1: 'b' }; o[Symbol.isConcatSpreadable] = true; [].concat(o).join(',')");
    try expectEvalStr("6:1:2:3:false:false:false",
        \\var args = (function(a, b, c) { "use strict"; return arguments; })(1, 2, 3);
        \\args[Symbol.isConcatSpreadable] = true;
        \\Object.defineProperty(args, "length", { value: 6 });
        \\var out = [].concat(args);
        \\out.length + ":" + out[0] + ":" + out[1] + ":" + out[2] + ":" + (3 in out) + ":" + (4 in out) + ":" + (5 in out)
    );
    // An array with isConcatSpreadable = false is appended as a single element.
    try std.testing.expectEqual(@as(f64, 1), (try evalIn(
        \\var a = [1, 2, 3]; a[Symbol.isConcatSpreadable] = false;
        \\[].concat(a).length
    )).asNum());
}

test "function objects inherit from Function.prototype" {
    // A user function links to `Function.prototype`, so instanceof, the
    // prototype identity, and inherited methods all resolve through the chain.
    try std.testing.expect((try evalIn("function f() {} f instanceof Function")).asBool());
    try std.testing.expect((try evalIn("var g = () => {}; g instanceof Function")).asBool());
    try std.testing.expect((try evalIn(
        \\function f() {}
        \\Object.getPrototypeOf(f) === Function.prototype
    )).asBool());
    // The inherited `call` is the same function object reached via the chain.
    try std.testing.expect((try evalIn("function f() {} f.call === Function.prototype.call")).asBool());
}

test "dynamic Function observes NewTarget and constructor realms" {
    try std.testing.expect((try evalIn(
        \\var other = $262.createRealm().global;
        \\var C = new other.Function();
        \\C.prototype = null;
        \\Object.getPrototypeOf(Reflect.construct(Function, [], C)) === other.Function.prototype
    )).asBool());
    try std.testing.expect((try evalIn(
        \\var realmA = $262.createRealm().global;
        \\realmA.calls = 0;
        \\var realmB = $262.createRealm().global;
        \\var newTarget = new realmB.Function();
        \\newTarget.prototype = null;
        \\var fn = Reflect.construct(realmA.Function, ["calls += 1;"], newTarget);
        \\Object.getPrototypeOf(fn) === realmB.Function.prototype &&
        \\Object.getPrototypeOf(fn.prototype) === realmA.Object.prototype &&
        \\new fn() instanceof realmA.Object &&
        \\realmA.calls === 1
    )).asBool());
}

test "dynamic AsyncFunction uses NewTarget realm prototype fallback" {
    try std.testing.expect((try evalIn(
        \\var AsyncFunction = Object.getPrototypeOf(async function() {}).constructor;
        \\var other = $262.createRealm().global;
        \\var OtherAsyncFunction = Object.getPrototypeOf(other.eval('(0, async function() {})')).constructor;
        \\var newTarget = new other.Function();
        \\newTarget.prototype = null;
        \\var ok = Object.getPrototypeOf(Reflect.construct(AsyncFunction, [], newTarget)) === OtherAsyncFunction.prototype;
        \\newTarget.prototype = undefined;
        \\ok = ok && Object.getPrototypeOf(Reflect.construct(AsyncFunction, [], newTarget)) === OtherAsyncFunction.prototype;
        \\newTarget.prototype = true;
        \\ok = ok && Object.getPrototypeOf(Reflect.construct(AsyncFunction, [], newTarget)) === OtherAsyncFunction.prototype;
        \\newTarget.prototype = '';
        \\ok = ok && Object.getPrototypeOf(Reflect.construct(AsyncFunction, [], newTarget)) === OtherAsyncFunction.prototype;
        \\newTarget.prototype = Symbol();
        \\ok = ok && Object.getPrototypeOf(Reflect.construct(AsyncFunction, [], newTarget)) === OtherAsyncFunction.prototype;
        \\newTarget.prototype = 1;
        \\ok && Object.getPrototypeOf(Reflect.construct(AsyncFunction, [], newTarget)) === OtherAsyncFunction.prototype
    )).asBool());
    try std.testing.expect((try evalIn(
        \\async function f() {}
        \\f.prototype === undefined && !f.hasOwnProperty('prototype')
    )).asBool());
}

test "dynamic generator functions validate params and prototype realms" {
    try std.testing.expect((try evalIn(
        \\var GeneratorFunction = Object.getPrototypeOf(function*() {}).constructor;
        \\var ok = false;
        \\try { GeneratorFunction('x = yield', ''); } catch (e) { ok = e instanceof SyntaxError; }
        \\ok
    )).asBool());
    try std.testing.expect((try evalIn(
        \\var AsyncGeneratorFunction = Object.getPrototypeOf(async function*() {}).constructor;
        \\var ok = false;
        \\try { AsyncGeneratorFunction('x = yield', ''); } catch (e) { ok = e instanceof SyntaxError; }
        \\ok
    )).asBool());
    try std.testing.expect((try evalIn(
        \\var realmA = $262.createRealm().global;
        \\realmA.calls = 0;
        \\var realmB = $262.createRealm().global;
        \\var GeneratorFunction = realmA.eval('(function* () {})').constructor;
        \\var aGeneratorPrototype = Object.getPrototypeOf(realmA.eval('(function* () {})').prototype);
        \\var bGeneratorFunction = realmB.eval('(function* () {})').constructor;
        \\var newTarget = new realmB.Function();
        \\newTarget.prototype = null;
        \\var fn = Reflect.construct(GeneratorFunction, ['calls += 1;'], newTarget);
        \\var gen = fn();
        \\gen.next();
        \\Object.getPrototypeOf(fn) === bGeneratorFunction.prototype &&
        \\Object.getPrototypeOf(fn.prototype) === aGeneratorPrototype &&
        \\gen instanceof realmA.Object &&
        \\realmA.calls === 1
    )).asBool());
    try std.testing.expect((try evalIn(
        \\var realmA = $262.createRealm().global;
        \\realmA.calls = 0;
        \\var realmB = $262.createRealm().global;
        \\var AsyncGeneratorFunction = realmA.eval('(async function* () {})').constructor;
        \\var aAsyncGeneratorPrototype = Object.getPrototypeOf(realmA.eval('(async function* () {})').prototype);
        \\var bAsyncGeneratorFunction = realmB.eval('(async function* () {})').constructor;
        \\var newTarget = new realmB.Function();
        \\newTarget.prototype = null;
        \\var fn = Reflect.construct(AsyncGeneratorFunction, ['calls += 1;'], newTarget);
        \\var gen = fn();
        \\gen.next();
        \\Object.getPrototypeOf(fn) === bAsyncGeneratorFunction.prototype &&
        \\Object.getPrototypeOf(fn.prototype) === aAsyncGeneratorPrototype &&
        \\gen instanceof realmA.Object &&
        \\realmA.calls === 1
    )).asBool());
}

test "Iterator constructor uses NewTarget realm prototype fallback" {
    try std.testing.expect((try evalIn(
        \\var other = $262.createRealm().global;
        \\var C = new other.Function();
        \\C.prototype = null;
        \\Object.getPrototypeOf(Reflect.construct(Iterator, [], C)) === other.Iterator.prototype
    )).asBool());
}

test "Date call remains string-returning through bind" {
    try std.testing.expect((try evalIn("typeof Date(0, 0, 0) === 'string'")).asBool());
    try std.testing.expect((try evalIn("typeof Date.bind(null)(0, 0, 0) === 'string'")).asBool());
}

test "ordinary toPrimitive calls borrowed native toString methods" {
    try std.testing.expectError(error.Throw, evalIn(
        \\String({ toString: Function.prototype.toString })
    ));
    try std.testing.expect((try evalIn(
        \\String(Function.prototype).indexOf("[native code]") >= 0
    )).asBool());
}

test "prototype objects: Function.prototype.call.bind + X.prototype methods" {
    // The propertyHelper pattern: borrow a prototype method via call.bind.
    try expectEvalStr("1-2-3",
        \\var __join = Function.prototype.call.bind(Array.prototype.join);
        \\__join([1, 2, 3], "-")
    );
    try std.testing.expect((try evalIn(
        \\var __hasOwn = Function.prototype.call.bind(Object.prototype.hasOwnProperty);
        \\__hasOwn({ a: 1 }, "a") && !__hasOwn({ a: 1 }, "b")
    )).asBool());
    // Direct prototype-method access + .call.
    try std.testing.expectEqual(@as(f64, 3), (try evalIn(
        \\Array.prototype.indexOf.call([10, 20, 30], 30) + 1
    )).asNum());
}

test "property descriptors: defineProperty attrs + getOwnPropertyDescriptor" {
    // defineProperty defaults omitted attrs to false; getOwnPropertyDescriptor reports them.
    try std.testing.expect((try evalIn(
        \\var o = {};
        \\Object.defineProperty(o, "x", { value: 5 });
        \\var d = Object.getOwnPropertyDescriptor(o, "x");
        \\d.value === 5 && d.writable === false && d.enumerable === false && d.configurable === false
    )).asBool());
    // A non-writable property ignores assignment (sloppy mode).
    try std.testing.expectEqual(@as(f64, 5), (try evalIn(
        \\var o = {};
        \\Object.defineProperty(o, "x", { value: 5, writable: false });
        \\o.x = 99;
        \\o.x
    )).asNum());
    // Non-enumerable property is skipped by Object.keys / for-in but kept by getOwnPropertyNames.
    try std.testing.expect((try evalIn(
        \\var o = { a: 1 };
        \\Object.defineProperty(o, "hidden", { value: 2, enumerable: false });
        \\Object.keys(o).length === 1 && Object.getOwnPropertyNames(o).length === 2 &&
        \\  !o.propertyIsEnumerable("hidden") && o.propertyIsEnumerable("a")
    )).asBool());
    // Plain-assignment properties are writable/enumerable/configurable.
    try std.testing.expect((try evalIn(
        \\var o = { a: 1 };
        \\var d = Object.getOwnPropertyDescriptor(o, "a");
        \\d.writable && d.enumerable && d.configurable
    )).asBool());
}

test "Object.getOwnPropertySymbols rejects nullish inputs" {
    try std.testing.expect((try evalIn(
        \\var count = 0;
        \\try { Object.getOwnPropertySymbols(undefined); } catch (e) { count += e instanceof TypeError ? 1 : 0; }
        \\try { Object.getOwnPropertySymbols(null); } catch (e) { count += e instanceof TypeError ? 1 : 0; }
        \\count === 2 && Object.getOwnPropertySymbols(1).length === 0
    )).asBool());
}

test "global object writes update object-backed global bindings" {
    try std.testing.expect((try evalIn(
        \\var original = Object;
        \\function fakeObject() {}
        \\globalThis.Object = fakeObject;
        \\var ok = Object === fakeObject && globalThis.Object === fakeObject;
        \\globalThis.Object = original;
        \\ok && Object === original
    )).asBool());
}

test "Object.freeze / seal / preventExtensions" {
    // freeze: writes ignored, not extensible, isFrozen true.
    try std.testing.expect((try evalIn(
        \\var o = { a: 1 };
        \\Object.freeze(o);
        \\o.a = 2; o.b = 3;
        \\o.a === 1 && o.b === undefined && Object.isFrozen(o) && !Object.isExtensible(o)
    )).asBool());
    // seal: existing writable, but no new props, isSealed true (not frozen).
    try std.testing.expect((try evalIn(
        \\var o = { a: 1 };
        \\Object.seal(o);
        \\o.a = 9; o.b = 3;
        \\o.a === 9 && o.b === undefined && Object.isSealed(o) && !Object.isFrozen(o)
    )).asBool());
    // preventExtensions: can't add, can still modify.
    try std.testing.expect((try evalIn(
        \\var o = { a: 1 };
        \\Object.preventExtensions(o);
        \\o.b = 3; o.a = 5;
        \\o.a === 5 && o.b === undefined && !Object.isExtensible(o)
    )).asBool());
    // empty frozen object is frozen.
    try std.testing.expect((try evalIn("Object.isFrozen(Object.freeze({}))")).asBool());
}

test "Object.prototype: hasOwnProperty / isPrototypeOf" {
    try std.testing.expect((try evalIn(
        \\var o = { a: 1 }; o.hasOwnProperty("a")
    )).asBool());
    try std.testing.expect(!(try evalIn(
        \\var o = { a: 1 }; o.hasOwnProperty("b")
    )).asBool());
    try std.testing.expect((try evalIn(
        \\var a = [1, 2, 3]; a.hasOwnProperty("length") && a.hasOwnProperty(0) && !a.hasOwnProperty(9)
    )).asBool());
    try std.testing.expect((try evalIn(
        \\var hint = "";
        \\var key = { toString() { hint = "string"; throw new Error("key"); } };
        \\try { Object.prototype.hasOwnProperty.call(null, key); } catch (e) {}
        \\hint === "string"
    )).asBool());
    try std.testing.expect(!(try evalIn("Object.prototype.isPrototypeOf.call(null, false)")).asBool());
    try std.testing.expect(!(try evalIn("Object.prototype.isPrototypeOf.call(null, Symbol())")).asBool());
    try std.testing.expect((try evalIn(
        \\var proto = [];
        \\var proxy = new Proxy({}, { getPrototypeOf() { return proto; } });
        \\proto.isPrototypeOf(proxy)
    )).asBool());
    try std.testing.expect((try evalIn("typeof Object.prototype.valueOf.call(false) === 'object'")).asBool());
}

test "generators: manual next() yields values then done" {
    try std.testing.expectEqual(@as(f64, 6), (try evalIn(
        \\function* g() { yield 1; yield 2; yield 3; }
        \\var it = g();
        \\var a = it.next().value, b = it.next().value, c = it.next().value;
        \\a + b + c
    )).asNum());
    // After exhaustion, next().done is true and value undefined.
    try std.testing.expect((try evalIn(
        \\function* g() { yield 1; }
        \\var it = g(); it.next();
        \\it.next().done
    )).asBool());
}

test "generators: for-of drives the generator" {
    try std.testing.expectEqual(@as(f64, 30), (try evalIn(
        \\function* g() { yield 10; yield 20; }
        \\var s = 0; for (var x of g()) { s += x; } s
    )).asNum());
}

test "generators: next(v) is the value of the resumed yield" {
    try std.testing.expectEqual(@as(f64, 15), (try evalIn(
        \\function* g() { var x = yield 1; yield x + 10; }
        \\var it = g(); it.next(); it.next(5).value
    )).asNum());
}

test "generators: infinite generator bounded by the consumer" {
    try std.testing.expectEqual(@as(f64, 2), (try evalIn(
        \\function* nat() { var i = 0; while (true) { yield i; i = i + 1; } }
        \\var it = nat(); it.next(); it.next(); it.next().value
    )).asNum());
}

test "generators: yield* delegates to arrays, strings, and generators" {
    // Delegate to an array.
    try std.testing.expectEqual(@as(f64, 6), (try evalIn(
        \\function* g() { yield* [1, 2, 3]; }
        \\var s = 0; for (var x of g()) { s += x; } s
    )).asNum());
    // Delegate to another generator, interleaved with own yields.
    try std.testing.expectEqual(@as(f64, 6), (try evalIn(
        \\function* inner() { yield 1; yield 2; }
        \\function* outer() { yield 0; yield* inner(); yield 3; }
        \\var s = 0; for (var x of outer()) { s += x; } s
    )).asNum());
    // Delegate to a string (yields each character).
    try expectEvalStr("ab",
        \\function* g() { yield* "ab"; }
        \\var it = g(); it.next().value + it.next().value
    );
    // `yield*` evaluates to the delegated generator's return value.
    try std.testing.expectEqual(@as(f64, 99), (try evalIn(
        \\function* inner() { yield 1; return 99; }
        \\function* outer() { var r = yield* inner(); yield r; }
        \\var it = outer(); it.next(); it.next().value
    )).asNum());
    // `yield*` uses GetIterator, so primitive delegates can inherit @@iterator.
    try expectEvalStr("true,false",
        \\var obj = { hit: true };
        \\Boolean.prototype[Symbol.iterator] = function* () { yield this.valueOf(); };
        \\function* g() {
        \\  yield * 'hit' in obj;
        \\  yield * 'miss' in obj;
        \\}
        \\var it = g();
        \\String(it.next().value) + "," + String(it.next().value)
    );
    // GetIterator captures the delegate iterator's `next` method once.
    try expectEvalStr("first,second:1",
        \\var gets = 0;
        \\var iter = {
        \\  get next() {
        \\    gets++;
        \\    var n = 0;
        \\    return function(v) {
        \\      n++;
        \\      return n === 1 ? { value: "first", done: false } : { value: "second", done: true };
        \\    };
        \\  }
        \\};
        \\var obj = { [Symbol.iterator]() { return iter; } };
        \\function* g() { return yield* obj; }
        \\var it = g();
        \\it.next().value + "," + it.next("sent").value + ":" + gets
    );
}

test "generators: sloppy arguments object maps to parameters" {
    try expectEvalStr("32,23,42",
        \\function* g(a, b, c, d) {
        \\  arguments[0] = 32;
        \\  yield a;
        \\  a = 23;
        \\  yield arguments[0];
        \\  b = 42;
        \\  yield arguments[1];
        \\}
        \\var it = g(23, 17, 42, 0);
        \\it.next().value + "," + it.next().value + "," + it.next().value
    );
}

test "generators: a return value finishes with done:true" {
    try std.testing.expectEqual(@as(f64, 99), (try evalIn(
        \\function* g() { yield 1; return 99; }
        \\var it = g(); it.next(); it.next().value
    )).asNum());
}

test "generators: locals persist across yields, closures captured" {
    try std.testing.expectEqual(@as(f64, 3), (try evalIn(
        \\var base = 1;
        \\function* g() { var n = base; yield n; n = n + 1; yield n; }
        \\var it = g(); it.next(); it.next().value + base
    )).asNum());
}

test "generators: class computed names can yield" {
    try expectEvalStr("method,static,field,staticField,get:set",
        \\var saved;
        \\function* g() {
        \\  class C {
        \\    [yield "m"]() { return "method"; }
        \\    static [yield "sm"]() { return "static"; }
        \\    [yield "f"] = "field";
        \\    static [yield "sf"] = "staticField";
        \\    get [yield "g"]() { return "get"; }
        \\    set [yield "s"](v) { saved = v; }
        \\  }
        \\  var c = new C();
        \\  c[yield "s"] = "set";
        \\  return c[yield "m"]() + "," + C[yield "sm"]() + "," + c[yield "f"] + "," + C[yield "sf"] + "," + c[yield "g"] + ":" + saved;
        \\}
        \\var it = g();
        \\var r;
        \\while (!(r = it.next(r && r.value)).done) {}
        \\r.value
    );
}

test "generators and async functions: private-in RHS can suspend" {
    try std.testing.expect((try evalIn(
        \\class C {
        \\  #x;
        \\  static *g() { return #x in (yield); }
        \\}
        \\var it = C.g();
        \\it.next();
        \\var it2 = C.g();
        \\it2.next();
        \\it.next(new C()).value === true && it2.next({}).value === false
    )).asBool());
    {
        const ctx = try Context.create(std.testing.allocator);
        defer ctx.destroy();
        _ = try ctx.evaluate(
            \\var out = "";
            \\class C {
            \\  #x;
            \\  static async has(value) { return #x in await value; }
            \\}
            \\C.has(new C()).then(function(v) {
            \\  out += v ? "yes" : "no";
            \\  return C.has({});
            \\}).then(function(v) {
            \\  out += v ? ":yes" : ":no";
            \\});
        );
        try std.testing.expectEqualStrings("yes:no", (try ctx.evaluate("out")).asStr());
    }
}

test "for-await: Await observes PromiseResolve constructor lookups" {
    {
        const ctx = try Context.create(std.testing.allocator);
        defer ctx.destroy();
        _ = try ctx.evaluate(
            \\var log = [];
            \\Object.defineProperty(Promise.prototype, "constructor", {
            \\  get() { log.push("constructor"); return Promise; },
            \\  configurable: true
            \\});
            \\function toAsyncIterator(iterable) {
            \\  return {
            \\    [Symbol.asyncIterator]() {
            \\      var iter = iterable[Symbol.iterator]();
            \\      return { next() { return Promise.resolve(iter.next()); } };
            \\    }
            \\  };
            \\}
            \\async function f() {
            \\  var p = Promise.resolve(0);
            \\  log.push("pre");
            \\  for await (var x of toAsyncIterator([p])) log.push("loop");
            \\  log.push("post");
            \\}
            \\f();
        );
        try std.testing.expectEqualStrings("pre,constructor,loop,constructor,post", (try ctx.evaluate("log.join(',')")).asStr());
    }
    {
        const ctx = try Context.create(std.testing.allocator);
        defer ctx.destroy();
        _ = try ctx.evaluate(
            \\var log = [];
            \\Object.defineProperty(Promise.prototype, "constructor", {
            \\  get() { log.push("constructor"); return Promise; },
            \\  configurable: true
            \\});
            \\async function f() {
            \\  var p = Promise.resolve(0);
            \\  log.push("pre");
            \\  for await (var x of [p]) log.push("loop");
            \\  log.push("post");
            \\}
            \\f();
        );
        try std.testing.expectEqualStrings("pre,constructor,constructor,loop,constructor,post", (try ctx.evaluate("log.join(',')")).asStr());
    }
}

test "generators: BigInt literal yields feed BigInt typed arrays" {
    try std.testing.expect((try evalIn(
        \\function* g() { yield 7n; yield 42n; }
        \\var ta = new BigInt64Array(g());
        \\ta.length === 2 && ta[0] === 7n && ta[1] === 42n;
    )).asBool());
}

test "generators: generator methods expose GeneratorPrototype-backed prototype" {
    try std.testing.expect((try evalIn(
        \\var GeneratorPrototype = Object.getPrototypeOf(function* () {}).prototype;
        \\var method = { *method() {} }.method;
        \\Object.getPrototypeOf(method.prototype) === GeneratorPrototype &&
        \\Object.getOwnPropertyDescriptor(method, "prototype").writable === true &&
        \\Object.getOwnPropertyDescriptor(method, "prototype").enumerable === false &&
        \\Object.getOwnPropertyDescriptor(method, "prototype").configurable === false
    )).asBool());
}

test "identifiers: unicode escapes decode to the canonical name" {
    // \uXXXX in an identifier resolves to the same name written literally.
    try std.testing.expectEqual(@as(f64, 1), (try evalIn("var \\u0061 = 1; a")).asNum());
    // \u{...} code-point escape form.
    try std.testing.expectEqual(@as(f64, 2), (try evalIn("var \\u{62} = 2; b")).asNum());
    // Escape in a non-leading position: `fo` is the identifier `fo`.
    try std.testing.expectEqual(@as(f64, 3), (try evalIn("var f\\u006f = 3; fo")).asNum());
}

test "identifiers: raw non-ASCII Unicode letters" {
    // Greek + a letter-like symbol used as identifiers.
    try std.testing.expectEqual(@as(f64, 7), (try evalIn("var \u{03C0} = 7; \u{03C0}")).asNum());
    try std.testing.expectEqual(@as(f64, 8), (try evalIn("var caf\u{00E9} = 8; caf\u{00E9}")).asNum());
}

test "whitespace: vertical tab, form feed, NBSP, and U+2028 separate tokens" {
    try std.testing.expectEqual(@as(f64, 3), (try evalIn("var\u{0B}x\u{0C}=\u{00A0}1\u{2028}x + 2")).asNum());
}

test "hashbang comment at start of source is ignored" {
    try std.testing.expectEqual(@as(f64, 5), (try evalIn("#!/usr/bin/env node\nvar x = 5; x")).asNum());
}

test "async: declarations/expressions/arrows/methods parse; never-called is valid" {
    // A never-called async function is fully valid (parses + binds).
    try std.testing.expectEqual(@as(f64, 1), (try evalIn("async function f() { await 1; return 2; } 1")).asNum());
    // async function expression, async arrow, async method — all parse.
    try std.testing.expectEqual(@as(f64, 1), (try evalIn("var f = async function () { return await g(); }; 1")).asNum());
    try std.testing.expectEqual(@as(f64, 1), (try evalIn("var f = async (a, b) => await a + b; 1")).asNum());
    try std.testing.expectEqual(@as(f64, 1), (try evalIn("var f = async x => await x; 1")).asNum());
    try std.testing.expectEqual(@as(f64, 1), (try evalIn("var o = { async m() { return await 1; } }; 1")).asNum());
    try std.testing.expectEqual(@as(f64, 1), (try evalIn("class C { async m() { await this.x; } static async s() {} } 1")).asNum());
    // async generator parses.
    try std.testing.expectEqual(@as(f64, 1), (try evalIn("async function* ag() { yield await 1; } 1")).asNum());
    try expectEvalStr("[Symbol.asyncIterator]", "async function* g() {} Object.getPrototypeOf(Object.getPrototypeOf(g.prototype))[Symbol.asyncIterator].name");
}

test "async/await: suspendable runtime with spec ordering" {
    // An async function returns a Promise.
    try std.testing.expect((try evalIn("(async function () { return 1; })() instanceof Promise")).asBool());
    // The body runs synchronously up to the first `await` (no await here), so a
    // write before any suspension is observable synchronously.
    try std.testing.expectEqual(@as(f64, 7), (try evalIn(
        \\var x = 0;
        \\async function f() { x = 7; return 1; }
        \\f();
        \\x
    )).asNum());
    // A continuation *after* an `await` runs in a microtask, so it is NOT visible
    // synchronously (it was, incorrectly, under the old synchronous-settling
    // model). The value is verified end-to-end by the test262 async suite.
    try std.testing.expectEqual(@as(f64, 0), (try evalIn(
        \\var result = 0;
        \\async function f() { result = await Promise.resolve(41) + 1; }
        \\f();
        \\result
    )).asNum());
    {
        const ctx = try Context.create(std.testing.allocator);
        defer ctx.destroy();
        _ = try ctx.evaluate(
            \\var result = "";
            \\var sup = { method() { return "sup"; } };
            \\var child = { async method(x = super.method()) { result = await x; } };
            \\Object.setPrototypeOf(child, sup);
            \\child.method();
        );
        try std.testing.expectEqualStrings("sup", (try ctx.evaluate("result")).asStr());
    }
    {
        const ctx = try Context.create(std.testing.allocator);
        defer ctx.destroy();
        _ = try ctx.evaluate(
            \\var result = false;
            \\var obj = {
            \\  async method(x) {
            \\    let a = arguments;
            \\    return async () => a === arguments;
            \\  }
            \\};
            \\obj.method(1).then(function(retFn) {
            \\  return retFn();
            \\}).then(function(value) {
            \\  result = value;
            \\});
        );
        try std.testing.expect((try ctx.evaluate("result")).asBool());
    }
    {
        const ctx = try Context.create(std.testing.allocator);
        defer ctx.destroy();
        _ = try ctx.evaluate(
            \\var result = "";
            \\async function f(a) {
            \\  arguments[0] = 2;
            \\  result += a;
            \\  a = 3;
            \\  result += ":" + arguments[0];
            \\}
            \\f(1);
        );
        try std.testing.expectEqualStrings("2:3", (try ctx.evaluate("result")).asStr());
    }
    try std.testing.expect((try evalIn("Promise.resolve(1) instanceof Promise")).asBool());
    try std.testing.expect((try evalIn(
        \\var other = $262.createRealm().global;
        \\var C = new other.Function();
        \\C.prototype = null;
        \\Object.getPrototypeOf(Reflect.construct(Promise, [function() {}], C)) === other.Promise.prototype
    )).asBool());
    try std.testing.expectEqual(@as(f64, 1), (try evalIn(
        \\var promise = new Promise(function() {});
        \\var returnCount = 0;
        \\var iter = {};
        \\iter[Symbol.iterator] = function() {
        \\  return {
        \\    next: function() { return { done: false, value: promise }; },
        \\    return: function() { returnCount += 1; return {}; }
        \\  };
        \\};
        \\promise.then = function() { throw new Test262Error(); };
        \\Promise.race(iter);
        \\returnCount
    )).asNum());
    {
        const ctx = try Context.create(std.testing.allocator);
        defer ctx.destroy();
        _ = try ctx.evaluate(
            \\var result = "";
            \\var e1 = new Error("one");
            \\var e2 = new Error("two");
            \\var e3 = new Error("three");
            \\async function onlyDisposeFails() {
            \\  await using _ = { async [Symbol.asyncDispose]() { throw e1; } };
            \\}
            \\async function bodyAndDisposeFail() {
            \\  await using _1 = { async [Symbol.asyncDispose]() { throw e1; } };
            \\  await using _2 = { [Symbol.dispose]() { throw e2; } };
            \\  throw e3;
            \\}
            \\async function main() {
            \\  try { await onlyDisposeFails(); } catch (e) { result += e === e1; }
            \\  try { await bodyAndDisposeFail(); } catch (e) {
            \\    result += "|" + [
            \\      e instanceof SuppressedError,
            \\      e.error === e1,
            \\      e.suppressed instanceof SuppressedError,
            \\      e.suppressed.error === e2,
            \\      e.suppressed.suppressed === e3
            \\    ].join(",");
            \\  }
            \\}
            \\main();
        );
        try std.testing.expectEqualStrings("true|true,true,true,true,true", (try ctx.evaluate("result")).asStr());
    }
    {
        const ctx = try Context.create(std.testing.allocator);
        defer ctx.destroy();
        _ = try ctx.evaluate(
            \\var result = "";
            \\var sameTurn = true;
            \\async function f() {
            \\  {
            \\    result += sameTurn ? "pre" : "bad";
            \\    await using _ = null;
            \\    result += sameTurn ? ":body" : ":bad";
            \\  }
            \\  result += sameTurn ? ":bad" : ":after";
            \\}
            \\f();
            \\sameTurn = false;
        );
        try std.testing.expectEqualStrings("pre:body:after", (try ctx.evaluate("result")).asStr());
    }
    {
        const ctx = try Context.create(std.testing.allocator);
        defer ctx.destroy();
        _ = try ctx.evaluate(
            \\var result = "";
            \\var outer = { [Symbol.dispose]() { result += "O"; } };
            \\var inner = { [Symbol.dispose]() { result += "I"; } };
            \\async function f() {
            \\  {
            \\    await using x = outer;
            \\    var i = 0;
            \\    for (await using x = inner; i < 1; i++) {
            \\      result += x === inner ? "inner" : "bad";
            \\    }
            \\    result += x === outer ? "outer" : "bad";
            \\  }
            \\}
            \\f();
        );
        try std.testing.expectEqualStrings("innerIouterO", (try ctx.evaluate("result")).asStr());
    }
}

test "async generators: yield* captures sync iterator next once" {
    const ctx = try Context.create(std.testing.allocator);
    defer ctx.destroy();
    _ = try ctx.evaluate(
        \\var out = "";
        \\var gets = 0;
        \\var sync = {
        \\  get next() {
        \\    gets++;
        \\    var n = 0;
        \\    return function(v) {
        \\      n++;
        \\      return n === 1 ? { value: "first", done: false } : { value: "done", done: true };
        \\    };
        \\  }
        \\};
        \\var obj = {
        \\  get [Symbol.asyncIterator]() { return null; },
        \\  [Symbol.iterator]() { return sync; }
        \\};
        \\async function* g() { return yield* obj; }
        \\var it = g();
        \\it.next().then(function(v) {
        \\  out += v.value + ":" + v.done;
        \\  return it.next("sent");
        \\}).then(function(v) {
        \\  out += "|" + v.value + ":" + v.done + ":" + gets;
        \\});
    );
    try std.testing.expectEqualStrings("first:false|done:true:1", (try ctx.evaluate("out")).asStr());
}

test "async generators: yield* awaits return resume value before delegate return lookup" {
    const ctx = try Context.create(std.testing.allocator);
    defer ctx.destroy();
    _ = try ctx.evaluate(
        \\var actual = [];
        \\var asyncIter = {
        \\  [Symbol.asyncIterator]() {
        \\    return this;
        \\  },
        \\  next() {
        \\    return { done: false };
        \\  },
        \\  get return() {
        \\    actual.push("get return");
        \\  }
        \\};
        \\async function* g() {
        \\  actual.push("start");
        \\  yield* asyncIter;
        \\}
        \\Promise.resolve()
        \\  .then(function() { actual.push("tick 1"); })
        \\  .then(function() { actual.push("tick 2"); })
        \\  .then(function() { actual.push("tick 3"); });
        \\var it = g();
        \\it.next();
        \\it.return({
        \\  get then() {
        \\    actual.push("get then");
        \\  }
        \\});
    );
    try std.testing.expectEqualStrings(
        "start|tick 1|get then|tick 2|get return|get then|tick 3",
        (try ctx.evaluate("actual.join('|')")).asStr(),
    );
}

test "class static block rejects arguments in nested computed class names" {
    try expectParseError(
        \\class C {
        \\  static {
        \\    (class { [arguments]() {} });
        \\  }
        \\}
    );
}

test "array destructuring over the iterator protocol (generator, Set, string, rest)" {
    // Generator.
    try std.testing.expectEqual(@as(f64, 3), (try evalIn(
        \\function* g() { yield 1; yield 2; }
        \\var [a, b] = g(); a + b
    )).asNum());
    // Set (iterable, not array).
    try std.testing.expectEqual(@as(f64, 30), (try evalIn(
        \\var [a, b] = new Set([10, 20]); a + b
    )).asNum());
    // Rest collects the tail of a generator.
    try std.testing.expectEqual(@as(f64, 2), (try evalIn(
        \\function* g() { yield 1; yield 2; yield 3; }
        \\var [first, ...rest] = g(); rest.length
    )).asNum());
    // Default applies when the iterator runs dry.
    try std.testing.expectEqual(@as(f64, 9), (try evalIn(
        \\function* g() { yield 1; }
        \\var [a, b = 9] = g(); b
    )).asNum());
    // Destructuring a non-iterable still throws a TypeError.
    try std.testing.expect((try evalIn(
        \\var t = false;
        \\try { var [x] = 5; } catch (e) { t = e instanceof TypeError; }
        \\t
    )).asBool());
}

test "ToPrimitive: own valueOf/toString in arithmetic, string, relational" {
    try std.testing.expectEqual(@as(f64, 11), (try evalIn("var o = { valueOf: function () { return 10; } }; o + 1")).asNum());
    try std.testing.expectEqual(@as(f64, 20), (try evalIn("var o = { valueOf: function () { return 10; } }; o * 2")).asNum());
    try expectEvalStr("hi!", "var o = { toString: function () { return 'hi'; } }; o + '!'");
    try expectEvalStr("1,2,3", "'' + [1, 2, 3]");
    try expectEvalStr("[object Object]x", "({}) + 'x'");
    try std.testing.expect((try evalIn("var o = { valueOf: function () { return 5; } }; o < 6")).asBool());
    // A class's prototype valueOf/toString is honored too.
    try std.testing.expectEqual(@as(f64, 6), (try evalIn("class C { valueOf() { return 5; } } new C() + 1")).asNum());
    try expectEvalStr("C!", "class C { toString() { return 'C'; } } new C() + '!'");
}

test "class methods/accessors/constructor are non-enumerable" {
    // Prototype methods are non-enumerable (Object.keys sees only own enumerable).
    try expectEvalStr("", "class C { m() {} n() {} } Object.keys(C.prototype).join(',')");
    try std.testing.expect((try evalIn(
        \\class C { m() {} }
        \\var d = Object.getOwnPropertyDescriptor(C.prototype, 'm');
        \\!d.enumerable && d.writable && d.configurable
    )).asBool());
    // Accessors too.
    try std.testing.expect((try evalIn(
        \\class C { get x() { return 1; } }
        \\!Object.getOwnPropertyDescriptor(C.prototype, 'x').enumerable
    )).asBool());
    // Static methods.
    try expectEvalStr("", "class C { static s() {} } Object.keys(C).join(',')");
    // `constructor` is non-enumerable.
    try std.testing.expect((try evalIn(
        \\class C {}
        \\!Object.getOwnPropertyDescriptor(C.prototype, 'constructor').enumerable
    )).asBool());
    // Instance fields ARE enumerable.
    try expectEvalStr("f", "class C { f = 1; m() {} } Object.keys(new C()).join(',')");
}

test "Array change-by-copy methods (toReversed/toSorted/toSpliced/with)" {
    // toReversed: new array, original untouched.
    try expectEvalStr("3,2,1", "[1,2,3].toReversed().join(',')");
    try std.testing.expect((try evalIn("var a=[1,2,3]; a.toReversed(); a.join(',') === '1,2,3'")).asBool());
    // toSorted with a comparator.
    try expectEvalStr("1,2,3,10", "[10,2,1,3].toSorted(function(a,b){return a-b;}).join(',')");
    try std.testing.expect((try evalIn("var a=[3,1,2]; a.toSorted(); a.join(',') === '3,1,2'")).asBool());
    // with: replaces one index, returns a new array; negative index; RangeError.
    try expectEvalStr("1,9,3", "[1,2,3].with(1,9).join(',')");
    try expectEvalStr("1,2,9", "[1,2,3].with(-1,9).join(',')");
    try std.testing.expect((try evalIn("var t=false; try{[1,2].with(5,0);}catch(e){t=e instanceof RangeError;} t")).asBool());
    // toSpliced: delete + insert into a copy.
    try expectEvalStr("1,9,9,3", "[1,2,3].toSpliced(1,1,9,9).join(',')");
    try std.testing.expect((try evalIn("var a=[1,2,3]; a.toSpliced(0,2); a.length === 3")).asBool());
}

test "defineProperty descriptor validation (accessor+data mix, non-callable get/set)" {
    // Mixing a data field with an accessor field throws TypeError.
    try std.testing.expect((try evalIn(
        \\var t = false;
        \\try { Object.defineProperty({}, 'p', { value: 1, get: function () {} }); }
        \\catch (e) { t = e instanceof TypeError; } t
    )).asBool());
    // A non-callable getter throws TypeError.
    try std.testing.expect((try evalIn(
        \\var t = false;
        \\try { Object.defineProperty({}, 'p', { get: 5 }); } catch (e) { t = e instanceof TypeError; } t
    )).asBool());
    // get: undefined is a valid accessor descriptor (no throw).
    try std.testing.expect((try evalIn(
        \\Object.defineProperty({}, 'p', { get: undefined }); true
    )).asBool());
}

test "array index property attributes (defineProperty honors writable/enumerable)" {
    // Default array element descriptor is all-true.
    try std.testing.expect((try evalIn(
        \\var a = [10];
        \\var d = Object.getOwnPropertyDescriptor(a, 0);
        \\d.value === 10 && d.writable && d.enumerable && d.configurable
    )).asBool());
    // defineProperty can make an element non-writable; a sloppy write is a no-op.
    try std.testing.expectEqual(@as(f64, 10), (try evalIn(
        \\var a = [10];
        \\Object.defineProperty(a, 0, { writable: false });
        \\a[0] = 99; a[0]
    )).asNum());
    // The recorded descriptor is reflected.
    try std.testing.expect((try evalIn(
        \\var a = [10];
        \\Object.defineProperty(a, 0, { writable: false, enumerable: false });
        \\var d = Object.getOwnPropertyDescriptor(a, 0);
        \\!d.writable && !d.enumerable
    )).asBool());
    // defineProperty can set a new value on a configurable element.
    try std.testing.expectEqual(@as(f64, 7), (try evalIn(
        \\var a = [1];
        \\Object.defineProperty(a, 0, { value: 7 });
        \\a[0]
    )).asNum());
    // A non-configurable element cannot be deleted (sloppy: delete returns false).
    try std.testing.expect((try evalIn(
        \\var a = [1];
        \\Object.defineProperty(a, 0, { configurable: false });
        \\var ok = delete a[0];
        \\!ok && a[0] === 1
    )).asBool());
}

test "array length defineProperty invariants" {
    try std.testing.expect((try evalIn(
        \\var a = [];
        \\Object.defineProperty(a, "length", { writable: false });
        \\try { Object.defineProperty(a, "length", { writable: true }); false; }
        \\catch (e) { e instanceof TypeError && Object.getOwnPropertyDescriptor(a, "length").writable === false; }
    )).asBool());
    try std.testing.expect((try evalIn(
        \\var a = [1, 2, 3];
        \\Object.defineProperty(a, "length", { writable: false });
        \\try { Object.defineProperty(a, "3", { value: "abc" }); false; }
        \\catch (e) { e instanceof TypeError && !a.hasOwnProperty("3") && a.length === 3; }
    )).asBool());
    try std.testing.expect((try evalIn(
        \\var a = [1, 2, 3];
        \\Object.defineProperty(a, "length", { writable: false });
        \\try { Object.defineProperties(a, { "4": { value: "abc" } }); false; }
        \\catch (e) { e instanceof TypeError && !a.hasOwnProperty("4") && a.length === 3; }
    )).asBool());
    try std.testing.expect((try evalIn(
        \\var a = [1, 2, 3];
        \\Object.defineProperty(a, "length", { writable: false });
        \\Reflect.defineProperty(a, "3", { value: "abc" }) === false &&
        \\!a.hasOwnProperty("3") && a.length === 3
    )).asBool());
}

test "Object defineProperties uses ToObject and proxy ownKeys" {
    try std.testing.expect((try evalIn(
        \\var threw = false;
        \\try { Object.create({}, "hello"); } catch (e) { threw = e instanceof TypeError; }
        \\threw
    )).asBool());
    try std.testing.expect((try evalIn(
        \\var target = {};
        \\target.foo = 2;
        \\target[0] = 3;
        \\var seen = [];
        \\var proxy = new Proxy(target, {
        \\  getOwnPropertyDescriptor: function(_target, key) { seen.push(key); }
        \\});
        \\Object.defineProperties({}, proxy);
        \\seen.length === 2 && seen[0] === "0" && seen[1] === "foo"
    )).asBool());
}

test "deleted Object.prototype.toString is not synthesized" {
    try std.testing.expect((try evalIn(
        \\var f = Object.prototype.toString;
        \\var deleted = delete Object.prototype.toString;
        \\var threw = false;
        \\try { Object.prototype.toString(); } catch (e) { threw = e instanceof TypeError; }
        \\Object.defineProperty(Object.prototype, "toString", { value: f, writable: true, configurable: true });
        \\deleted && threw
    )).asBool());
}

test "Object.keys/values/entries enumerate array indices" {
    try expectEvalStr("0,1,2", "Object.keys([10, 20, 30]).join(',')");
    try std.testing.expectEqual(@as(f64, 60), (try evalIn("Object.values([10, 20, 30]).reduce(function(a,b){return a+b;}, 0)")).asNum());
    try std.testing.expectEqual(@as(f64, 2), (try evalIn("Object.entries([7, 8]).length")).asNum());
    try expectEvalStr("0,7", "Object.entries([7, 8])[0].join(',')");
    // A non-enumerable index is skipped.
    try expectEvalStr("1", "var a = [10, 20]; Object.defineProperty(a, 0, { enumerable: false }); Object.keys(a).join(',')");
}

test "Array.isArray follows proxies and recognizes Array.prototype" {
    try std.testing.expect((try evalIn("Array.isArray(Array.prototype)")).asBool());
    try std.testing.expect((try evalIn(
        \\var objectProxy = new Proxy({}, {});
        \\var arrayProxy = new Proxy([], {});
        \\var arrayProxyProxy = new Proxy(arrayProxy, {});
        \\Array.isArray(objectProxy) === false &&
        \\Array.isArray(arrayProxy) === true &&
        \\Array.isArray(arrayProxyProxy) === true
    )).asBool());
    try std.testing.expect((try evalIn(
        \\var handle = Proxy.revocable([], {});
        \\handle.revoke();
        \\try { Array.isArray(handle.proxy); false; } catch (e) { e instanceof TypeError; }
    )).asBool());
}

test "Array.prototype Symbol.iterator aliases values and rejects nullish this" {
    try std.testing.expect((try evalIn("Array.prototype[Symbol.iterator] === Array.prototype.values")).asBool());
    try std.testing.expect((try evalIn(
        \\var it = Array.prototype[Symbol.iterator];
        \\try { it(); false; } catch (e) { e instanceof TypeError; }
    )).asBool());
}

test "array mutators throw when final length set hits non-writable length" {
    try std.testing.expect((try evalIn(
        \\function throwsWith(method, setup) {
        \\  var a = [];
        \\  setup(a);
        \\  try { a[method](); return false; } catch (e) { return e instanceof TypeError && a.length === 0; }
        \\}
        \\throwsWith("pop", function(a) { Object.defineProperty(a, "length", { writable: false }); }) &&
        \\throwsWith("shift", function(a) { Object.defineProperty(a, "length", { writable: false }); }) &&
        \\throwsWith("push", function(a) { Object.defineProperty(a, "length", { writable: false }); }) &&
        \\throwsWith("unshift", function(a) { Object.defineProperty(a, "length", { writable: false }); }) &&
        \\throwsWith("pop", Object.freeze) &&
        \\throwsWith("shift", Object.freeze)
    )).asBool());
}

test "sloppy-mode property set on a primitive is a no-op; null/undefined throws" {
    // No-op on a primitive: doesn't throw, doesn't store.
    try std.testing.expectEqual(@as(f64, 1), (try evalIn("var n = 5; n.foo = 1; n.foo === undefined ? 1 : 0")).asNum());
    try std.testing.expectEqual(@as(f64, 1), (try evalIn("'str'.x = 1; 1")).asNum());
    try std.testing.expectEqual(@as(f64, 1), (try evalIn("true.y = 1; 1")).asNum());
    // null / undefined still throw a TypeError.
    try std.testing.expect((try evalIn(
        \\var t = false;
        \\try { var o = null; o.x = 1; } catch (e) { t = e instanceof TypeError; }
        \\t
    )).asBool());
    try std.testing.expect((try evalIn(
        \\var t = false;
        \\try { var o; o.x = 1; } catch (e) { t = e instanceof TypeError; }
        \\t
    )).asBool());
}

test "Object.prototype.toString tags ([object X]) + Symbol.toStringTag" {
    try expectEvalStr("[object Object]", "Object.prototype.toString.call({})");
    try expectEvalStr("[object Array]", "Object.prototype.toString.call([])");
    try expectEvalStr("[object Function]", "Object.prototype.toString.call(function () {})");
    try expectEvalStr("[object Error]", "Object.prototype.toString.call(new Error())");
    try expectEvalStr("[object Date]", "Object.prototype.toString.call(new Date())");
    try expectEvalStr("[object Number]", "Object.prototype.toString.call(5)");
    try expectEvalStr("[object Boolean]", "Object.prototype.toString.call(true)");
    try expectEvalStr("[object Undefined]", "Object.prototype.toString.call(undefined)");
    try expectEvalStr("[object Null]", "Object.prototype.toString.call(null)");
    // Symbol.toStringTag (string) overrides the builtin tag.
    try expectEvalStr("[object Custom]", "Object.prototype.toString.call({ [Symbol.toStringTag]: 'Custom' })");
    // The kind-specific toString is unaffected: arrays still join.
    try expectEvalStr("1,2,3", "[1, 2, 3].toString()");
    try expectEvalStr("[object Object]", "({}).toString()");
}

test "Symbol.for / Symbol.keyFor (global symbol registry)" {
    // Same key returns the same (===) registered symbol.
    try std.testing.expect((try evalIn("Symbol.for('x') === Symbol.for('x')")).asBool());
    // A registry symbol is distinct from a plain Symbol() of the same desc.
    try std.testing.expect((try evalIn("Symbol.for('y') !== Symbol('y')")).asBool());
    // keyFor returns the registration key.
    try expectEvalStr("z", "Symbol.keyFor(Symbol.for('z'))");
    // keyFor on an unregistered symbol is undefined.
    try expectEvalStr("undefined", "typeof Symbol.keyFor(Symbol('q'))");
    // The registry symbol's description is the key.
    try expectEvalStr("k", "Symbol.for('k').description");
    // keyFor on a non-symbol throws a TypeError.
    try std.testing.expect((try evalIn(
        \\var t = false;
        \\try { Symbol.keyFor('not a symbol'); } catch (e) { t = e instanceof TypeError; }
        \\t
    )).asBool());
}

test "NamedEvaluation: anonymous function/class takes its binding name" {
    // Variable declaration.
    try expectEvalStr("f", "var f = function () {}; f.name");
    try expectEvalStr("g", "var g = () => {}; g.name");
    try expectEvalStr("C", "var C = class {}; C.name");
    // Assignment to an identifier.
    try expectEvalStr("h", "var h; h = function () {}; h.name");
    // Object property.
    try expectEvalStr("m", "var o = { m: function () {} }; o.m.name");
    // Destructuring default.
    try expectEvalStr("d", "var { d = function () {} } = {}; d.name");
    try expectEvalStr("e", "var [e = () => {}] = []; e.name");
    // Parameter default.
    try expectEvalStr("p", "function fn(p = function () {}) { return p.name; } fn()");
    // A *named* function expression keeps its own name (not the binding's).
    try expectEvalStr("real", "var x = function real() {}; x.name");
    // A non-anonymous RHS (identifier) is unaffected.
    try expectEvalStr("real", "function real() {} var y = real; y.name");
}

test "generators with destructuring / default / rest parameters" {
    // Array-pattern parameter.
    try std.testing.expectEqual(@as(f64, 3), (try evalIn(
        \\function* g([a, b]) { yield a + b; }
        \\g([1, 2]).next().value
    )).asNum());
    // Object-pattern parameter.
    try std.testing.expectEqual(@as(f64, 7), (try evalIn(
        \\function* g({ x, y }) { yield x + y; }
        \\g({ x: 3, y: 4 }).next().value
    )).asNum());
    // Default parameter (evaluated at generator creation).
    try std.testing.expectEqual(@as(f64, 5), (try evalIn(
        \\function* g(a = 5) { yield a; }
        \\g().next().value
    )).asNum());
    // Rest parameter.
    try std.testing.expectEqual(@as(f64, 3), (try evalIn(
        \\function* g(first, ...rest) { yield rest.length; }
        \\g(0, 1, 2, 3).next().value
    )).asNum());
    // Generator method with a destructuring parameter (the class/dstr family).
    try std.testing.expectEqual(@as(f64, 30), (try evalIn(
        \\var o = { *m([a, b]) { yield a + b; } };
        \\o.m([10, 20]).next().value
    )).asNum());
    // Generator method defaults evaluate with the method's super binding.
    try std.testing.expect((try evalIn(
        \\var o = { *m(a = super.toString) { yield a; } };
        \\o.toString = null;
        \\o.m().next().value === Object.prototype.toString
    )).asBool());
}

test "generators: yield is an identifier in nested sloppy function parameter defaults" {
    try std.testing.expectEqual(@as(f64, 23), (try evalIn(
        \\var yield = 23;
        \\var paramValue;
        \\function* g() {
        \\  function f(x = yield) {
        \\    paramValue = x;
        \\  }
        \\  f();
        \\}
        \\g().next();
        \\paramValue
    )).asNum());
}

test "Set/Map are iterable: for-of, spread, Array.from, destructuring" {
    // for-of over a Set.
    try std.testing.expectEqual(@as(f64, 6), (try evalIn(
        \\var s = 0; for (var x of new Set([1, 2, 3])) s += x; s
    )).asNum());
    // Spread a Set into an array.
    try std.testing.expectEqual(@as(f64, 3), (try evalIn("[...new Set([1, 2, 2, 3])].length")).asNum());
    // Map yields [k, v] pairs; destructure them in a for-of head.
    try std.testing.expectEqual(@as(f64, 33), (try evalIn(
        \\var m = new Map(); m.set('a', 11); m.set('b', 22);
        \\var t = 0; for (var [k, v] of m) t += v; t
    )).asNum());
    // Array.from over a Set.
    try std.testing.expectEqual(@as(f64, 2), (try evalIn("Array.from(new Set([5, 5, 9])).length")).asNum());
}

test "eval: direct eval runs in the caller's scope" {
    // Returns the completion value of the program.
    try std.testing.expectEqual(@as(f64, 3), (try evalIn("eval('1 + 2')")).asNum());
    // Reads a binding from the surrounding scope.
    try std.testing.expectEqual(@as(f64, 42), (try evalIn("var x = 42; eval('x')")).asNum());
    // Mutates a binding in the surrounding scope.
    try std.testing.expectEqual(@as(f64, 9), (try evalIn("var x = 1; eval('x = 9'); x")).asNum());
    // Introduces a new binding visible after the eval.
    try std.testing.expectEqual(@as(f64, 7), (try evalIn("eval('var y = 7;'); y")).asNum());
    // A non-string argument is returned unchanged.
    try std.testing.expectEqual(@as(f64, 5), (try evalIn("eval(5)")).asNum());
    // A syntax error in the source throws a SyntaxError.
    try std.testing.expect((try evalIn(
        \\var t = false;
        \\try { eval('var ='); } catch (e) { t = e instanceof SyntaxError; }
        \\t
    )).asBool());
    try std.testing.expect((try evalIn(
        \\var t = false, o = {};
        \\try { eval('o.#f'); } catch (e) { t = e instanceof SyntaxError; }
        \\t
    )).asBool());
}

test "async: `async` remains usable as an ordinary identifier" {
    try std.testing.expectEqual(@as(f64, 3), (try evalIn("var async = 1; async + 2")).asNum());
    // `async` as a property name / shorthand / method name (not a modifier).
    try std.testing.expectEqual(@as(f64, 7), (try evalIn("var o = { async: 7 }; o.async")).asNum());
    try std.testing.expectEqual(@as(f64, 5), (try evalIn("var o = { async() { return 5; } }; o.async()")).asNum());
    // `async` called as a function.
    try std.testing.expectEqual(@as(f64, 9), (try evalIn("function async(x) { return x; } async(9)")).asNum());
}

test "Context is thread-affine: owner recognized, foreign thread rejected" {
    const ctx = try Context.create(std.testing.allocator);
    defer ctx.destroy();
    try std.testing.expect(ctx.isOwnerThread());

    const Probe = struct {
        fn run(c: *Context, saw_owner: *bool) void {
            saw_owner.* = c.isOwnerThread();
        }
    };
    var saw_owner = true;
    const t = try std.Thread.spawn(.{}, Probe.run, .{ ctx, &saw_owner });
    t.join();
    try std.testing.expect(!saw_owner);
}

test "real agents: broadcast rendezvous, blocking wait, notify, report" {
    const ctx = try Context.create(std.testing.allocator);
    defer ctx.destroy();
    // Join the agent threads before this test returns — group teardown
    // otherwise waits for the NEXT $262 install, letting an agent outlive
    // the test (a determinism hole TSan flagged against the test runner).
    defer @import("agent.zig").reset();
    _ = try ctx.evaluate(
        \\const sab = new SharedArrayBuffer(8);
        \\const view = new Int32Array(sab);
        \\$262.agent.start(`
        \\  $262.agent.receiveBroadcast(function(sab) {
        \\    const v = new Int32Array(sab);
        \\    $262.agent.report("waited: " + Atomics.wait(v, 0, 0, 5000));
        \\    $262.agent.leaving();
        \\  });
        \\`);
        \\$262.agent.broadcast(sab);
        \\// The agent acked the broadcast; wake it once it parks in wait().
        \\while (Atomics.notify(view, 0, 1) === 0) $262.agent.sleep(1);
        \\let r = null;
        \\while ((r = $262.agent.getReport()) === null) $262.agent.sleep(1);
        \\if (r !== "waited: ok") throw new Error("agent reported: " + r);
    );
}

test "SharedArrayBuffer resolves newTarget prototype before data allocation" {
    try std.testing.expect((try evalIn(
        \\function MarkerError() {}
        \\var newTarget = function() {}.bind(null);
        \\Object.defineProperty(newTarget, "prototype", {
        \\  get: function() { throw new MarkerError(); }
        \\});
        \\try {
        \\  Reflect.construct(SharedArrayBuffer, [7 * 1125899906842624], newTarget);
        \\} catch (e) {
        \\  e instanceof MarkerError;
        \\}
    )).asBool());
}

test "ArrayBuffer immutable methods preserve spec ordering" {
    try std.testing.expect((try evalIn(
        \\var ab = (new ArrayBuffer(4)).transferToImmutable();
        \\var calls = [];
        \\try {
        \\  ab.transfer({ valueOf() { calls.push("newLength.valueOf"); return 1; } });
        \\} catch (e) {
        \\  if (!(e instanceof TypeError)) throw e;
        \\}
        \\calls.length === 1 && calls[0] === "newLength.valueOf";
    )).asBool());
    try std.testing.expect((try evalIn(
        \\var source = new ArrayBuffer(10, { maxByteLength: 10 });
        \\var start = { valueOf() { source.resize(9); return -7; } };
        \\var end = { valueOf() { source.resize(5); return -4; } };
        \\try {
        \\  source.sliceToImmutable(start, end);
        \\} catch (e) {
        \\  e instanceof RangeError;
        \\}
    )).asBool());
}

test "ArrayBuffer slice rejects immutable species result" {
    try std.testing.expect((try evalIn(
        \\var calls = [];
        \\var source = new ArrayBuffer(8);
        \\source.constructor = {
        \\  [Symbol.species]: function(length) {
        \\    calls.push(length);
        \\    return source.sliceToImmutable();
        \\  }
        \\};
        \\try {
        \\  source.slice(1, 2);
        \\} catch (e) {
        \\  e instanceof TypeError && calls.length === 1 && calls[0] === 1;
        \\}
    )).asBool());
}

test "ArrayBuffer byteLength copied onto SharedArrayBuffer keeps brand check" {
    try std.testing.expect((try evalIn(
        \\var byteLength = Object.getOwnPropertyDescriptor(ArrayBuffer.prototype, "byteLength");
        \\var sab = new SharedArrayBuffer(4);
        \\Object.defineProperties(sab, { byteLength });
        \\try {
        \\  sab.byteLength;
        \\} catch (e) {
        \\  e instanceof TypeError;
        \\}
    )).asBool());
}

test "TypedArray from/of reject immutable constructor result before writes" {
    try std.testing.expect((try evalIn(
        \\var calls = [];
        \\function immutable(len) {
        \\  calls.push("construct(" + len + ")");
        \\  return new Uint8Array((new ArrayBuffer(len)).transferToImmutable());
        \\}
        \\var item = { valueOf() { calls.push("item.valueOf"); return 1; } };
        \\try {
        \\  Uint8Array.of.call(immutable, item);
        \\} catch (e) {
        \\  if (!(e instanceof TypeError)) throw e;
        \\}
        \\calls.join("|") === "construct(1)";
    )).asBool());
    try std.testing.expect((try evalIn(
        \\var calls = [];
        \\function immutable(len) {
        \\  calls.push("construct(" + len + ")");
        \\  return new Uint8Array((new ArrayBuffer(len)).transferToImmutable());
        \\}
        \\var source = {
        \\  get length() { calls.push("length"); return 1; },
        \\  get 0() { calls.push("get 0"); return 7; }
        \\};
        \\Object.defineProperty(source, Symbol.iterator, {
        \\  get: function() { calls.push("iterator"); return undefined; }
        \\});
        \\try {
        \\  Uint8Array.from.call(immutable, source);
        \\} catch (e) {
        \\  if (!(e instanceof TypeError)) throw e;
        \\}
        \\calls.join("|") === "iterator|length|construct(1)";
    )).asBool());
}

test "TypedArray Reflect.set honors ordinary receiver failures" {
    try std.testing.expect((try evalIn(
        \\var target = new Uint8Array([0]);
        \\var valueOfCalls = 0;
        \\var value = { valueOf() { valueOfCalls++; return 9; } };
        \\var receiver = {
        \\  get 0() { return 1; },
        \\  set 0(v) { throw new Error("setter should not run"); }
        \\};
        \\Reflect.set(target, 0, value, receiver) === false &&
        \\target[0] === 0 &&
        \\receiver[0] === 1 &&
        \\valueOfCalls === 0;
    )).asBool());
    try std.testing.expect((try evalIn(
        \\var target = new BigInt64Array([0n, 0n]);
        \\var receiver = new BigInt64Array([1n]);
        \\Reflect.set(target, 1, { valueOf() { throw new Error("coerce"); } }, receiver) === false &&
        \\target[1] === 0n &&
        \\receiver.hasOwnProperty(1) === false;
    )).asBool());
}

test "TypedArray constructor processes arguments before prototype allocation" {
    try std.testing.expect((try evalIn(
        \\function Marker() {}
        \\var newTarget = function() {}.bind(null);
        \\Object.defineProperty(newTarget, "prototype", {
        \\  get() { throw new Marker(); }
        \\});
        \\try {
        \\  Reflect.construct(Uint8Array, [Symbol()], newTarget);
        \\} catch (e) {
        \\  e instanceof TypeError;
        \\}
    )).asBool());
}

test "TypedArray constructor copies live source typed array length" {
    try std.testing.expect((try evalIn(
        \\var rab = new ArrayBuffer(16, { maxByteLength: 32 });
        \\var source = new Uint8Array(rab, 4);
        \\new Uint8Array(rab).set([1, 2, 3, 4, 5, 6]);
        \\rab.resize(8);
        \\var copy = new Uint8Array(source);
        \\copy.length === 4 && copy[0] === 5 && copy[1] === 6 && copy[2] === 0 && copy[3] === 0;
    )).asBool());
}

test "TypedArray subarray omits species length for length-tracking views" {
    try std.testing.expect((try evalIn(
        \\var rab = new ArrayBuffer(16, { maxByteLength: 32 });
        \\var sample = new Uint8Array(rab);
        \\var seen;
        \\sample.constructor = {
        \\  [Symbol.species]: function(buffer, offset, length) {
        \\    seen = arguments;
        \\    return new Uint8Array(buffer, offset, length);
        \\  }
        \\};
        \\var result = sample.subarray(1);
        \\seen.length === 2 &&
        \\seen[0] === rab &&
        \\seen[1] === 1 &&
        \\result.length === 15 &&
        \\(rab.resize(8), true) &&
        \\result.length === 7;
    )).asBool());
}

test "TypedArray toString shares Array.prototype function object" {
    try std.testing.expect((try evalIn(
        \\var proto = Object.getPrototypeOf(Uint8Array.prototype);
        \\var sample = new Uint8Array([1, 2]);
        \\proto.toString === Array.prototype.toString &&
        \\sample.toString() === "1,2";
    )).asBool());
    try std.testing.expect((try evalIn(
        \\var sample = new Uint8Array([1]);
        \\$262.detachArrayBuffer(sample.buffer);
        \\try {
        \\  sample.toString();
        \\} catch (e) {
        \\  e instanceof TypeError;
        \\}
    )).asBool());
}

test "TypedArray default sort orders negative zero before positive zero" {
    try std.testing.expect((try evalIn(
        \\var sample = new Float64Array([1, 0, -0, 2]).sort();
        \\Object.is(sample[0], -0) && Object.is(sample[1], 0) &&
        \\sample[2] === 1 && sample[3] === 2;
    )).asBool());
}

test "TypedArray sort skips writeback when comparator shrinks fixed view out of bounds" {
    try std.testing.expect((try evalIn(
        \\var rab = new ArrayBuffer(4, { maxByteLength: 8 });
        \\var fixed = new Uint8Array(rab, 0, 4);
        \\var full = new Uint8Array(rab);
        \\full.set([10, 9, 8, 7]);
        \\fixed.sort(function(a, b) {
        \\  rab.resize(2);
        \\  return a - b;
        \\});
        \\full.length === 2 && full[0] === 10 && full[1] === 9;
    )).asBool());
}

test "TypedArray toLocaleString uses empty strings after shrink" {
    try std.testing.expect((try evalIn(
        \\var old = Number.prototype.toLocaleString;
        \\var rab = new ArrayBuffer(4, { maxByteLength: 8 });
        \\var fixed = new Uint8Array(rab, 0, 4);
        \\var calls = 0;
        \\Number.prototype.toLocaleString = function() {
        \\  calls++;
        \\  if (calls === 2) rab.resize(2);
        \\  return old.call(this);
        \\};
        \\try {
        \\  fixed.toLocaleString() === "0,0,,";
        \\} finally {
        \\  Number.prototype.toLocaleString = old;
        \\}
    )).asBool());
}

test "TypedArray set skips writes after source getters shrink target" {
    try std.testing.expect((try evalIn(
        \\var rab = new ArrayBuffer(4, { maxByteLength: 8 });
        \\var fixed = new Uint8Array(rab, 0, 4);
        \\var full = new Uint8Array(rab);
        \\full.set([0, 2, 4, 6]);
        \\var source = new Proxy({ length: 4 }, {
        \\  get(target, prop) {
        \\    if (prop === "length") return 4;
        \\    if (prop === "1") rab.resize(3);
        \\    return 1;
        \\  }
        \\});
        \\fixed.set(source);
        \\full.length === 3 && full[0] === 1 && full[1] === 2 && full[2] === 4;
    )).asBool());
}

test "Atomics.waitAsync: not-equal sync, timeout, and cross-agent notify settle" {
    const ctx = try Context.create(std.testing.allocator);
    defer ctx.destroy();
    defer @import("agent.zig").reset();
    _ = try ctx.evaluate(
        \\const sab = new SharedArrayBuffer(8);
        \\const view = new Int32Array(sab);
        \\const r1 = Atomics.waitAsync(view, 0, 99);
        \\if (r1.async !== false || r1.value !== "not-equal") throw new Error("r1: " + r1.value);
        \\globalThis.__timedOut = false;
        \\const r2 = Atomics.waitAsync(view, 0, 0, 50);
        \\if (r2.async !== true) throw new Error("r2 not async");
        \\r2.value.then(v => { globalThis.__timedOut = (v === "timed-out"); });
        \\const r3 = Atomics.waitAsync(view, 1, 0);
        \\if (r3.async !== true) throw new Error("r3 not async");
        \\globalThis.__ok = false;
        \\r3.value.then(v => { globalThis.__ok = (v === "ok"); });
        \\$262.agent.start(`
        \\  $262.agent.receiveBroadcast(function(sab) {
        \\    const v = new Int32Array(sab);
        \\    $262.agent.sleep(10);
        \\    Atomics.notify(v, 1, 1);
        \\    $262.agent.leaving();
        \\  });
        \\`);
        \\$262.agent.broadcast(sab);
    );
    // evaluate's drain tail settled both promises before returning.
    _ = try ctx.evaluate(
        \\if (!globalThis.__timedOut) throw new Error("timeout waiter not settled");
        \\if (!globalThis.__ok) throw new Error("notified waiter not settled");
    );
}

test "structuredClone: identity, cycles, types, SAB sharing, transfer" {
    const ctx = try Context.create(std.testing.allocator);
    defer ctx.destroy();
    _ = try ctx.evaluate(
        \\// cycles + identity
        \\const shared = { n: 1 };
        \\const root = { a: shared, b: shared, list: [1, , 3] };
        \\root.self = root;
        \\const c = structuredClone(root);
        \\if (c === root) throw new Error("not a copy");
        \\if (c.a !== c.b) throw new Error("identity lost");
        \\if (c.self !== c) throw new Error("cycle lost");
        \\c.a.n = 2;
        \\if (root.a.n !== 1) throw new Error("not deep");
        \\if (c.list.length !== 3 || 1 in c.list) throw new Error("holes lost");
        \\// types
        \\const m = new Map([[1, "one"]]); const s = new Set(["x"]);
        \\const t = structuredClone({ m, s, d: new Date(123), r: /ab+c/gi,
        \\  big: 123456789012345678901234567890n, w: new Number(7),
        \\  e: new TypeError("boom") });
        \\if (!(t.m instanceof Map) || t.m.get(1) !== "one") throw new Error("Map");
        \\if (!(t.s instanceof Set) || !t.s.has("x")) throw new Error("Set");
        \\if (!(t.d instanceof Date) || t.d.getTime() !== 123) throw new Error("Date");
        \\if (!(t.r instanceof RegExp) || t.r.source !== "ab+c" || t.r.flags !== "gi") throw new Error("RegExp");
        \\if (t.big !== 123456789012345678901234567890n) throw new Error("BigInt");
        \\if (!(t.w instanceof Number) || t.w.valueOf() !== 7) throw new Error("wrapper");
        \\if (!(t.e instanceof TypeError) || t.e.message !== "boom") throw new Error("Error clone");
        \\// typed arrays + buffers
        \\const ta = new Uint8Array([1, 2, 3]);
        \\const ct = structuredClone(ta);
        \\ct[0] = 9;
        \\if (ta[0] !== 1 || ct[1] !== 2) throw new Error("TA not copied");
        \\// SAB shares storage
        \\const sab = new SharedArrayBuffer(8);
        \\const cs = structuredClone(sab);
        \\new Int32Array(cs)[0] = 42;
        \\if (new Int32Array(sab)[0] !== 42) throw new Error("SAB not shared");
        \\// transfer moves + detaches
        \\const ab = new Uint8Array([5, 6]).buffer;
        \\const moved = structuredClone(ab, { transfer: [ab] });
        \\if (new Uint8Array(moved)[0] !== 5) throw new Error("transfer bytes");
        \\if (ab.byteLength !== 0 || !ab.detached) throw new Error("source not detached");
        \\// DataCloneError
        \\let threw = false;
        \\try { structuredClone(function () {}); } catch (e) { threw = e instanceof TypeError; }
        \\if (!threw) throw new Error("function clone did not throw");
    );
}

test "Thread API (enable_threads): shared realm, identity, exceptions, ids" {
    const ctx = try Context.createWith(std.testing.allocator, .{ .enable_threads = true });
    defer ctx.destroy();
    _ = try ctx.evaluate(
        \\// one realm: results keep identity across the join
        \\const obj = { marker: 1 };
        \\if (new Thread(() => obj).join() !== obj) throw new Error("object identity");
        \\if (new Thread(() => 42).join() !== 42) throw new Error("number");
        \\if (!Object.is(new Thread(() => -0).join(), -0)) throw new Error("-0");
        \\const nan = new Thread(() => NaN).join();
        \\if (nan === nan) throw new Error("NaN");
        \\const sym = Symbol("p");
        \\if (new Thread(() => sym).join() !== sym) throw new Error("symbol");
        \\// fn is [[Call]]ed with this === undefined
        \\if (new Thread(function () { "use strict"; return this; }).join() !== undefined)
        \\  throw new Error("strict this");
        \\// one heap: the thread mutates, main observes (no clone, no copy)
        \\const box = { n: 0 };
        \\new Thread((b) => { b.n = 7; }, box).join();
        \\if (box.n !== 7) throw new Error("shared heap");
        \\// join rethrows the actual exception object
        \\const err = new TypeError("boom");
        \\let caught = null;
        \\try { new Thread(() => { throw err; }).join(); } catch (e) { caught = e; }
        \\if (caught !== err) throw new Error("exception identity");
        \\// ctor errors
        \\let threw = false;
        \\try { Thread(() => {}); } catch (e) { threw = e instanceof TypeError; }
        \\if (!threw) throw new Error("call without new must throw");
        \\threw = false;
        \\try { new Thread(42); } catch (e) { threw = e instanceof TypeError; }
        \\if (!threw) throw new Error("non-callable must throw");
        \\// ids and Thread.current
        \\if (Thread.current.id !== 0) throw new Error("main id is 0");
        \\const t = new Thread(() => Thread.current.id);
        \\const tid = t.join();
        \\if (tid !== t.id || tid === 0) throw new Error("Thread.current inside the thread");
        \\// the thread's own microtask queue drains before join settles
        \\let micro = false;
        \\new Thread(() => { Promise.resolve().then(() => { micro = true; }); }).join();
        \\if (!micro) throw new Error("thread microtasks must drain");
        \\// cancellation via a shared boolean (the PR-249 headline pattern)
        \\const ctl = { stop: false };
        \\const spin = new Thread((c) => { while (!c.stop) {} return "done"; }, ctl);
        \\ctl.stop = true;
        \\if (spin.join() !== "done") throw new Error("spinner");
    );
}

test "Thread API (enable_threads): abrupt top-level failure terminates parked unjoined threads" {
    const ctx = try Context.createWith(std.testing.allocator, .{ .enable_threads = true });
    try std.testing.expectError(error.Throw, ctx.evaluate(
        \\const gate = { go: 0 };
        \\globalThis.__parked = new Thread(() => {
        \\  while (Atomics.load(gate, "go") === 0)
        \\    Atomics.wait(gate, "go", 0, 10000);
        \\  return 1;
        \\});
        \\throw new Error("main failed before releasing parked thread");
    ));
    ctx.destroy();
}

test "Lock/Condition/ThreadLocal: mailbox handshake, mutual exclusion, TLS" {
    const ctx = try Context.createWith(std.testing.allocator, .{ .enable_threads = true });
    defer ctx.destroy();
    _ = try ctx.evaluate(
        \\// Mutual exclusion: read-modify-write under the lock never loses an
        \\// update even though the GIL can yield between the read and the write.
        \\const lock = new Lock();
        \\const acc = { n: 0 };
        \\const ts = [];
        \\for (let i = 0; i < 4; i++) ts.push(new Thread(() => {
        \\  for (let j = 0; j < 500; j++) lock.hold(() => { acc.n = acc.n + 1; });
        \\}));
        \\ts.forEach(t => t.join());
        \\if (acc.n !== 2000) throw new Error("lost update: " + acc.n);
        \\// hold releases on throw (finally-equivalent)
        \\let threw = false;
        \\try { lock.hold(() => { throw new Error("x"); }); } catch (e) { threw = true; }
        \\if (!threw) throw new Error("hold must propagate");
        \\lock.hold(() => {}); // and the lock is reacquirable
        \\// The PR-249 mailbox: a condition-variable handshake with a JS object
        \\const mlock = new Lock(), mcond = new Condition();
        \\const mailbox = { ready: false, payload: null };
        \\const consumer = new Thread(() => {
        \\  let got;
        \\  mlock.hold(() => {
        \\    while (!mailbox.ready) mcond.wait(mlock);
        \\    got = mailbox.payload;
        \\  });
        \\  return got.text;
        \\});
        \\mlock.hold(() => { mailbox.payload = { text: "hello" }; mailbox.ready = true; mcond.notify(); });
        \\if (consumer.join() !== "hello") throw new Error("mailbox");
        \\// ThreadLocal: per-thread values, main's untouched
        \\const tls = new ThreadLocal();
        \\tls.value = "main";
        \\const seen = new Thread(() => { const before = tls.value; tls.value = "worker"; return [before, tls.value]; }).join();
        \\if (seen[0] !== undefined || seen[1] !== "worker") throw new Error("tls worker view");
        \\if (tls.value !== "main") throw new Error("tls main view");
    );
}

test "enable_gc + threads: collection roots a parked peer thread's reachable state" {
    // Phase 7 multi-thread safepoint protocol: a spawned thread builds an object
    // reachable only from its own JS state, then parks (TA-mode `Atomics.wait`,
    // which drops the GIL and publishes a conservative scan range). The main
    // thread forces collections while the peer is parked, then wakes it; the
    // peer re-derives a checksum over the same object. If the parked peer's
    // reachable state weren't rooted across collection, the object would be
    // swept and the checksum would mismatch. Also a crash/leak gate (testing
    // allocator) for the parked-scan machinery under a real spawned thread.
    if (!stack_scan.supported) return error.SkipZigTest;
    const ctx = try Context.createWith(std.testing.allocator, .{ .enable_threads = true, .enable_gc = true });
    defer ctx.destroy();
    _ = try ctx.evaluate(
        \\// Property-mode Atomics on a plain shared-realm object (the corpus park
        \\// primitive: it drops the GIL while parked, unlike TA-mode wait which
        \\// is gated to the main agent).
        \\const gate = { wake: 0, parked: 0 };
        \\const t = new Thread(() => {
        \\  try {
        \\    let sum = 0;
        \\    const secret = { tag: "alive", payload: [] };
        \\    for (let i = 0; i < 64; i++) { const v = (i * 2654435761) % 1000003; secret.payload.push(v); sum += v; }
        \\    Atomics.store(gate, "parked", 1);     // announce we are about to park
        \\    Atomics.notify(gate, "parked");
        \\    Atomics.wait(gate, "wake", 0);        // park: drops the GIL, publishes scan range
        \\    let after = 0;
        \\    for (let i = 0; i < 64; i++) after += secret.payload[i];
        \\    if (after !== sum || secret.tag !== "alive") return "CORRUPT:" + after + "/" + sum;
        \\    return "ok";
        \\  } catch (e) { return "THREW:" + e.name + ":" + e.message; }
        \\});
        \\// Busy-wait yields the GIL at the step checkpoints, letting the peer run
        \\// and park; then force collections while it is parked.
        \\while (Atomics.load(gate, "parked") === 0) {}
        \\for (let k = 0; k < 8; k++) gc();
        \\Atomics.store(gate, "wake", 1);
        \\Atomics.notify(gate, "wake");
        \\const r = t.join();
        \\if (r !== "ok") throw new Error("parked peer: " + r);
    );
}

test "Thread API preserves per-class private brands across shared realm threads" {
    const ctx = try Context.createWith(std.testing.allocator, .{ .enable_threads = true });
    defer ctx.destroy();
    _ = try ctx.evaluate(
        \\class A {
        \\  #x = "a";
        \\  static read(o) { return o.#x; }
        \\  static has(o) { return #x in o; }
        \\}
        \\class B {
        \\  #x = "b";
        \\  static read(o) { return o.#x; }
        \\  static has(o) { return #x in o; }
        \\}
        \\const a = new A();
        \\const b = new B();
        \\if (A.read(a) !== "a" || B.read(b) !== "b") throw new Error("own private read");
        \\if (!A.has(a) || A.has(b) || B.has(a) || !B.has(b)) throw new Error("brand check");
        \\const reports = [
        \\  new Thread(() => A.read(a)).join(),
        \\  new Thread(() => B.read(b)).join(),
        \\  new Thread(() => { try { A.read(b); return "no-throw"; } catch (e) { return e.name; } }).join(),
        \\];
        \\if (reports.join(",") !== "a,b,TypeError") throw new Error("cross-thread private brand: " + reports.join(","));
    );
}

test "Atomics.Mutex and Atomics.Condition share the shared-realm sync constructors" {
    const ctx = try Context.createWith(std.testing.allocator, .{ .enable_threads = true });
    defer ctx.destroy();
    _ = try ctx.evaluate(
        \\if (Atomics.Mutex !== Lock) throw new Error("Mutex constructor identity");
        \\if (Atomics.Condition !== Condition) throw new Error("Condition constructor identity");
        \\const lock = new Atomics.Mutex();
        \\const cond = new Atomics.Condition();
        \\if (!(lock instanceof Lock)) throw new Error("mutex instanceof");
        \\if (!(cond instanceof Condition)) throw new Error("condition instanceof");
        \\const box = { ready: false, value: 0 };
        \\const waiter = new Thread(() => {
        \\  let out = 0;
        \\  lock.hold(() => {
        \\    while (!box.ready) cond.wait(lock);
        \\    out = box.value;
        \\  });
        \\  return out;
        \\});
        \\lock.hold(() => {
        \\  box.value = 8;
        \\  box.ready = true;
        \\  cond.notify();
        \\});
        \\if (waiter.join() !== 8) throw new Error("alias condition");
    );
}

test "Atomics.Mutex and Atomics.Condition proposal-style static APIs" {
    const ctx = try Context.createWith(std.testing.allocator, .{ .enable_threads = true });
    defer ctx.destroy();
    _ = try ctx.evaluate(
        \\if (typeof Atomics.Mutex.lock !== "function") throw new Error("missing Mutex.lock");
        \\if (typeof Atomics.Mutex.lockIfAvailable !== "function") throw new Error("missing Mutex.lockIfAvailable");
        \\if (typeof Atomics.Mutex.UnlockToken !== "function") throw new Error("missing UnlockToken");
        \\if (typeof Atomics.Condition.wait !== "function") throw new Error("missing Condition.wait");
        \\if (typeof Atomics.Condition.waitFor !== "function") throw new Error("missing Condition.waitFor");
        \\if (typeof Atomics.Condition.notify !== "function") throw new Error("missing Condition.notify");
        \\const mutex = new Atomics.Mutex();
        \\let token = Atomics.Mutex.lock(mutex);
        \\if (!(token instanceof Atomics.Mutex.UnlockToken)) throw new Error("token brand");
        \\if (!token.locked || !mutex.locked) throw new Error("token did not hold mutex");
        \\if (Atomics.Mutex.lockIfAvailable(mutex, 0) !== null) throw new Error("contended lockIfAvailable");
        \\let threw = false;
        \\try { Atomics.Mutex.lock(mutex); } catch (e) { threw = e instanceof TypeError; }
        \\if (!threw) throw new Error("recursive Mutex.lock must throw");
        \\if (token.unlock() !== true || token.locked || mutex.locked) throw new Error("unlock");
        \\if (token.unlock() !== false) throw new Error("double unlock is false");
        \\threw = false;
        \\try { Atomics.Mutex.lock(mutex, {}); } catch (e) { threw = e instanceof TypeError; }
        \\if (!threw) throw new Error("bad lock token must throw");
        \\let probe = Atomics.Mutex.lockIfAvailable(mutex, 0);
        \\if (probe === null) throw new Error("bad lock token leaked the mutex");
        \\probe.unlock();
        \\const reused = new Atomics.Mutex.UnlockToken();
        \\const reusedResult = Atomics.Mutex.lockIfAvailable(mutex, 0, reused);
        \\if (reusedResult !== reused || !reused.locked) throw new Error("reused token");
        \\if (Atomics.Mutex.lockIfAvailable(mutex, 0, reused) !== null) throw new Error("contended lockIfAvailable");
        \\if (!reused.locked || !mutex.locked) throw new Error("contended lockIfAvailable changed owner");
        \\reused[Symbol.dispose]();
        \\if (reused.locked || mutex.locked) throw new Error("dispose unlock");
        \\threw = false;
        \\try { Atomics.Mutex.lockIfAvailable(mutex, 0, {}); } catch (e) { threw = e instanceof TypeError; }
        \\if (!threw) throw new Error("bad lockIfAvailable token must throw");
        \\probe = Atomics.Mutex.lockIfAvailable(mutex, 0);
        \\if (probe === null) throw new Error("bad lockIfAvailable token leaked the mutex");
        \\probe.unlock();
        \\threw = false;
        \\try { Atomics.Mutex.lock(new Atomics.Condition()); } catch (e) { threw = e instanceof TypeError; }
        \\if (!threw) throw new Error("wrong Mutex receiver");
        \\
        \\const cond = new Atomics.Condition();
        \\const gate = { state: 0 };
        \\const box = { ready: false, value: 0 };
        \\const worker = new Thread(() => {
        \\  const workerToken = Atomics.Mutex.lock(mutex);
        \\  Atomics.store(gate, "state", 1);
        \\  Atomics.notify(gate, "state");
        \\  while (!box.ready) Atomics.Condition.wait(cond, workerToken);
        \\  const out = box.value;
        \\  workerToken.unlock();
        \\  return out;
        \\});
        \\while (Atomics.load(gate, "state") !== 1) Atomics.wait(gate, "state", 0, 10);
        \\token = Atomics.Mutex.lock(mutex);
        \\box.value = 77;
        \\box.ready = true;
        \\if (Atomics.Condition.notify(cond, 1) !== 1) throw new Error("static notify count");
        \\token.unlock();
        \\if (worker.join() !== 77) throw new Error("static wait/notify");
        \\
        \\token = Atomics.Mutex.lock(mutex);
        \\let predicateCalls = 0;
        \\const timed = Atomics.Condition.waitFor(cond, token, 0, () => {
        \\  predicateCalls++;
        \\  return false;
        \\});
        \\if (timed !== false || predicateCalls !== 1 || !token.locked) throw new Error("waitFor timeout");
        \\token.unlock();
    );
}

test "Atomics on plain properties: semantics, exact counter, wait/notify" {
    const ctx = try Context.createWith(std.testing.allocator, .{ .enable_threads = true });
    defer ctx.destroy();
    _ = try ctx.evaluate(
        \\const o = { x: 1 };
        \\if (Atomics.load(o, "x") !== 1) throw new Error("load");
        \\// the property path does NOT coerce values
        \\if (Atomics.store(o, "x", 7.9) !== 7.9 || o.x !== 7.9) throw new Error("store uncoerced");
        \\// store creates fresh properties with default attributes
        \\Atomics.store(o, "fresh", "v");
        \\const d = Object.getOwnPropertyDescriptor(o, "fresh");
        \\if (!d.writable || !d.enumerable || !d.configurable) throw new Error("fresh attrs");
        \\// any value round-trips by identity
        \\const ref = { deep: true };
        \\Atomics.store(o, "obj", ref);
        \\if (Atomics.load(o, "obj") !== ref) throw new Error("identity");
        \\// absent / RMW-on-absent / non-extensible all throw TypeError
        \\let te = 0;
        \\try { Atomics.load(o, "absent"); } catch (e) { if (e instanceof TypeError) te++; }
        \\try { Atomics.add(o, "absent", 1); } catch (e) { if (e instanceof TypeError) te++; }
        \\const ne = {}; Object.preventExtensions(ne);
        \\try { Atomics.store(ne, "k", 1); } catch (e) { if (e instanceof TypeError) te++; }
        \\if (te !== 3) throw new Error("error cases: " + te);
        \\// compareExchange is SameValueZero (NaN CAS loops work)
        \\Atomics.store(o, "n", NaN);
        \\const oldn = Atomics.compareExchange(o, "n", NaN, 5);
        \\if (!Number.isNaN(oldn) || o.n !== 5) throw new Error("SVZ CAS");
        \\// exchange swaps any value
        \\if (Atomics.exchange(o, "obj", null) !== ref || o.obj !== null) throw new Error("exchange");
        \\// the PR's parallel-counter pattern: exact without any Lock
        \\const c = { n: 0 };
        \\const ts = [];
        \\for (let i = 0; i < 4; i++) ts.push(new Thread(() => {
        \\  for (let j = 0; j < 500; j++) Atomics.add(c, "n", 1);
        \\}));
        \\ts.forEach(t => t.join());
        \\if (c.n !== 2000) throw new Error("lost update: " + c.n);
        \\// wait/notify on a property: park a thread, wake it
        \\const gate = { state: 0 };
        \\const waiter = new Thread(() => Atomics.wait(gate, "state", 0, 5000));
        \\while (Atomics.notify(gate, "state", 1) === 0) {} // yields until parked
        \\if (waiter.join() !== "ok") throw new Error("wait/notify");
        \\if (Atomics.wait(gate, "state", 999, 0) !== "not-equal") throw new Error("not-equal");
        \\if (Atomics.wait(gate, "state", 0, 1) !== "timed-out") throw new Error("timed-out");
        \\if (Atomics.notify(gate, "absent") !== 0) throw new Error("notify absent is 0");
        \\// finite waitAsync timers keep the shell alive until they settle
        \\const asyncGate = { state: 0 };
        \\const asyncWait = Atomics.waitAsync(asyncGate, "state", 0, 2);
        \\if (asyncWait.async !== true || !(asyncWait.value instanceof Promise)) throw new Error("waitAsync shape");
        \\let settled = false;
        \\asyncWait.value.then(() => { settled = true; });
        \\if (settled) throw new Error("waitAsync settled synchronously");
        \\globalThis.__waitAsyncOutcome = "pending";
        \\async function checkWaitAsync() {
        \\  const outcome = await asyncWait.value;
        \\  globalThis.__waitAsyncOutcome = outcome;
        \\}
        \\checkWaitAsync();
    );
    _ = try ctx.evaluate(
        \\if (globalThis.__waitAsyncOutcome !== "timed-out")
        \\  throw new Error("waitAsync timeout: " + globalThis.__waitAsyncOutcome);
    );
}

test "parallel: re-entrant getter + shared mutation across threads does not deadlock" {
    // Robustness (#5): a getter re-reads its own object's properties (a deadlock
    // if any per-object lock were held across the JS callback), while 6 threads
    // hammer the same shared object's data + accessor properties in parallel.
    // The test COMPLETING (no hang) is the no-deadlock proof; the result is racy
    // (unsynchronized shared mutation is legal) but must stay a valid integer.
    const ctx = try Context.createWith(std.testing.allocator, .{ .enable_threads = true });
    defer ctx.destroy();
    const v = try ctx.evaluate(
        \\var shared = { a: 1, b: 2 };
        \\Object.defineProperty(shared, 'sum', { get() { return this.a + this.b; } });
        \\function work() { let acc = 0; for (let i = 0; i < 3000; i++) { acc += shared.sum; shared.a = (shared.a + 1) % 7; } return acc | 0; }
        \\let ts = []; for (let i = 0; i < 6; i++) ts.push(new Thread(work));
        \\let total = 0; for (const t of ts) total += t.join();
        \\(total | 0)
    );
    try std.testing.expect(v.isNumber());
    try std.testing.expect(!std.math.isNan(v.asNum()));
}

test "parallel: shared closure read across threads via the real Thread entry resolves upvalues" {
    // Regression (concurrent-JS fuzzer find): a spawned `Thread` runs its body
    // through `callValueWithThis` — the TREE-WALKER entry — whereas the main
    // thread enters via the VM. A VM-lowered closure resolves a captured parent
    // local as a frame upvalue (`load_upval`); the tree-walker's `callPlain`
    // instead resolves names through the lexical Environment chain, where that
    // frame slot does not exist — so entering such a closure from a thread
    // raised a spurious `ReferenceError`. The fix dispatches plain chunk
    // functions to the VM from the tree-walker entry too. The earlier upvalue
    // test missed this because it called `vm.run` directly (VM entry), never the
    // `new Thread(fn)` → `callValueWithThis` path this exercises.
    const ctx = try Context.createWith(std.testing.allocator, .{ .enable_threads = true });
    defer ctx.destroy();
    const v = try ctx.evaluate(
        \\var box = (function(){ var n = 41; return { peek(){ return n; } }; })();
        \\function work() { let acc = 0; for (let i = 0; i < 2000; i++) acc += box.peek(); return acc | 0; }
        \\let ts = []; for (let i = 0; i < 4; i++) ts.push(new Thread(work));
        \\let total = 0; for (const t of ts) total += t.join();
        \\(total | 0)
    );
    // Deterministic: 4 threads × 2000 reads × 41 = 328000. The read is pure
    // (no mutation), so there is no race — only the entry-path resolution.
    try std.testing.expectEqual(@as(f64, 4 * 2000 * 41), v.asNum());
}

test "tree-walker entry into a VM closure resolves frame upvalues (native callback)" {
    // The same entry-path bug single-threaded: a native (`Array.prototype.map`)
    // invokes a VM-lowered callback through `callValueWithThis`, the tree-walker
    // entry. The callback reads a captured upvalue (`base`), which only the VM's
    // activation frame holds — so the pre-fix tree-walk of the body could not
    // resolve it. No threads involved; this guards the general dispatch fix.
    const ctx = try Context.createWith(std.testing.allocator, .{});
    defer ctx.destroy();
    const v = try ctx.evaluate(
        \\function make() { var base = 10; return { cb(x) { return x + base; } }; }
        \\var o = make();
        \\[1, 2, 3].map(o.cb).join(",");
    );
    try std.testing.expect(v.isString());
    try std.testing.expectEqualStrings("11,12,13", v.asStr());
}

test "deleting a data property from an object that has accessors does not use-after-free" {
    // Regression (broadened concurrent fuzzer, but single-threaded): when an object
    // carries an accessor, `deleteNamedDataOwn` rebuilds its key order through
    // `replaceKeyOrderUnlocked`, which used to free the old key_order *before*
    // copying the surviving key names - and those names alias the freed storage, so
    // the copy read freed memory (a segfault under churn). The fix copies first,
    // then frees. Many delete+re-add cycles on an accessor-bearing object must stay
    // correct and not crash.
    const ctx = try Context.createWith(std.testing.allocator, .{});
    defer ctx.destroy();
    const v = try ctx.evaluate(
        \\var o = { c: 0 };
        \\var gs = 0;
        \\Object.defineProperty(o, 'gs', { get(){ return gs; }, set(x){ gs = x; }, configurable: true });
        \\o.k0 = 1; o.k1 = 2;
        \\for (var i = 0; i < 20000; i++) { delete o.c; o.c = i; o['k' + (i & 3)] = i; o.gs = i; }
        \\o.c + ":" + o.gs + ":" + o.k3;
    );
    try std.testing.expect(v.isString());
    try std.testing.expectEqualStrings("19999:19999:19999", v.asStr()); // i=19999: c, gs, and k3 (19999&3==3)
}

test "Context threads run parallel by default; gil option opts into serialized mode" {
    // Default: enable_threads => true-parallel (no GIL), GC-managed cells.
    {
        const ctx = try Context.createWith(std.testing.allocator, .{ .enable_threads = true });
        defer ctx.destroy();
        const v = try ctx.evaluate("let s = 0; for (let i = 0; i < 100; i++) s += i; s");
        try std.testing.expectEqual(@as(f64, 4950), v.asNum());
        try std.testing.expect(ctx.parallel_js); // parallel is the default
    }
    // Opt-out: gil => the serialized (GIL) path.
    {
        const ctx = try Context.createWith(std.testing.allocator, .{ .enable_threads = true, .gil = true });
        defer ctx.destroy();
        const v = try ctx.evaluate("1 + 2");
        try std.testing.expectEqual(@as(f64, 3), v.asNum());
        try std.testing.expect(!ctx.parallel_js); // GIL serializes instead
    }
    // No threads => single-threaded, neither path engaged.
    {
        const ctx = try Context.createWith(std.testing.allocator, .{});
        defer ctx.destroy();
        try std.testing.expect(!ctx.parallel_js);
    }
}

test "Thread blocking APIs respect the main can-block gate" {
    const ctx = try Context.createWithTestingOptions(std.testing.allocator, .{
        .enable_threads = true,
        .main_can_block = false,
    });
    defer ctx.destroy();

    _ = try ctx.evaluate(
        \\function expectTypeError(fn, msg) {
        \\  try { fn(); } catch (e) {
        \\    if (e instanceof TypeError && e.message === msg) return;
        \\    throw e;
        \\  }
        \\  throw new Error("missing TypeError: " + msg);
        \\}
        \\const lockA = new Lock();
        \\if (lockA.hold(() => "ok") !== "ok") throw new Error("uncontended hold");
        \\lockA.asyncHold();
        \\if (!lockA.locked) throw new Error("asyncHold did not grant synchronously");
        \\expectTypeError(() => lockA.hold(() => 0), "Lock.prototype.hold cannot block the current thread");
        \\
        \\const lockB = new Lock();
        \\const condB = new Condition();
        \\lockB.hold(() => {
        \\  expectTypeError(() => condB.wait(lockB), "Condition.prototype.wait cannot block the current thread");
        \\});
        \\if (lockB.locked) throw new Error("gated wait leaked lock hold");
        \\if (condB.notify() !== 0) throw new Error("gated wait enqueued waiter");
        \\
        \\const o = { k: 0 };
        \\if (Atomics.wait(o, "k", 1) !== "not-equal") throw new Error("wait fast path");
        \\expectTypeError(() => Atomics.wait(o, "k", 0), "Atomics.wait cannot be called from the current thread.");
        \\
        \\const t = new Thread(() => 7);
        \\expectTypeError(() => t.join(), "Thread.prototype.join cannot block the current thread");
    );
}

test "enable_gc: object-heavy program runs and tears down clean (no leaks)" {
    // The Phase-7 M1 foundation: with the GC on, `newObject` allocates cells
    // through the collector instead of the arena. Collection is teardown-only
    // for now, so behavior matches the arena engine; this asserts correctness
    // and — under the testing allocator — that `destroy` reclaims every GC cell
    // (the heap's `deinit` frees them) with no leak.
    const ctx = try Context.createWith(std.testing.allocator, .{ .enable_gc = true });
    defer ctx.destroy();
    try std.testing.expect(ctx.gc != null);

    const result = try ctx.evaluate(
        \\let acc = 0;
        \\for (let i = 0; i < 200; i++) {
        \\  const o = { a: i, b: { c: i * 2 }, arr: [i, i + 1, i + 2] };
        \\  acc += o.a + o.b.c + o.arr[2];
        \\}
        \\const obj = Object.assign({}, { x: 1 }, { y: 2 });
        \\acc + obj.x + obj.y;
    );
    // sum_{i=0..199}(i + 2i + (i+2)) = sum(4i+2) = 80000, plus obj.x+obj.y = 3.
    try std.testing.expectEqual(@as(f64, 80003), result.asNum());
}

test "enable_gc: collectGarbage reclaims unreachable objects, keeps reachable" {
    const ctx = try Context.createWith(std.testing.allocator, .{ .enable_gc = true });
    defer ctx.destroy();

    // Create a large throwaway graph (unreachable after the statement) plus one
    // object retained on globalThis.
    _ = try ctx.evaluate(
        \\globalThis.keep = { kept: 1, nested: { deep: [1, 2, 3] } };
        \\for (let i = 0; i < 500; i++) { const tmp = { a: i, b: [i, i + 1, i + 2] }; }
        \\0
    );
    const before = ctx.gc.?.live_cells;

    // Quiescent collection (no JS running): the 500 temporaries and their arrays
    // are unreachable from the Context roots and are reclaimed; the retained
    // graph survives.
    ctx.collectGarbage();
    const after = ctx.gc.?.live_cells;
    try std.testing.expect(after < before); // real reclamation happened
    try std.testing.expect(ctx.gc.?.collections >= 1);

    // The retained object is intact and usable after collection.
    const r = try ctx.evaluate("globalThis.keep.kept + globalThis.keep.nested.deep[2]");
    try std.testing.expectEqual(@as(f64, 4), r.asNum()); // 1 + 3
}

test "enable_gc: mid-script collection reclaims garbage during a running loop (bounded heap)" {
    // Phase 7 / M1 item (a): the GC collects *while JS runs* (at the engine step
    // checkpoints), not just at quiescent points. A long loop allocating
    // throwaway objects would grow the heap without bound if collection only ran
    // at entry; the safepoint collector keeps it bounded. Crucially, this also
    // proves the new roots are sound: the live operand-stack `Value`s (registered
    // active VM `Exec`) and the loop's bindings are never wrongly freed, so the
    // arithmetic result is exact.
    const ctx = try Context.createWith(std.testing.allocator, .{ .enable_gc = true });
    defer ctx.destroy();

    const result = try ctx.evaluate(
        \\let acc = 0;
        \\for (let i = 0; i < 50000; i++) {
        \\  const o = { a: i, b: { c: i }, arr: [i, i, i] };
        \\  acc += o.b.c + o.arr[1];
        \\}
        \\acc;
    );
    // sum_{i=0..49999}(i + i) = 2 * (49999*50000/2) = 2499950000.
    try std.testing.expectEqual(@as(f64, 2499950000), result.asNum());
    // Collection ran repeatedly mid-loop — far more than the single quiescent
    // collect at the top of `evaluate`.
    try std.testing.expect(ctx.gc.?.collections > 2);
    // The heap stayed bounded: nothing like the ~150k object graphs a leak would
    // accumulate over 50k iterations survived.
    try std.testing.expect(ctx.gc.?.live_cells < 20000);
}

test "enable_gc concurrent (M3): the production driver marks on a thread while JS runs" {
    // Phase 7 / M3: with `concurrent_gc`, `collectMidScript` marks on a dedicated
    // thread *concurrently* with the mutator between safepoints. Same workload
    // and exact-result/bounded-heap assertions as the M2 mid-script test, now
    // driven concurrently end-to-end: the mutator allocates objects and per-
    // iteration `let` environments (objects' storage and envs' `vars` are read by
    // the marker under their per-structure locks; cells born this cycle are
    // deferred to the world-stopped finish), its stores feed the marker via the
    // insertion barrier, and finish re-scans the native stack. So live values are
    // never wrongly freed, the arithmetic is exact, and it is TSan-clean.
    if (builtin.single_threaded) return error.SkipZigTest;
    const ctx = try Context.createWith(std.testing.allocator, .{ .enable_gc = true, .concurrent_gc = true });
    defer ctx.destroy();
    try std.testing.expect(ctx.gc_concurrent);

    // 4,000 iterations (each allocating several cells + a per-iter `let` env) is
    // enough to cross the heap-growth threshold many times — driving multiple
    // begin→marker→finish concurrent cycles — while staying feasible under TSan
    // instrumentation (~15× slowdown).
    const result = try ctx.evaluate(
        \\let acc = 0;
        \\for (let i = 0; i < 4000; i++) {
        \\  const o = { a: i, b: { c: i }, arr: [i, i, i] };
        \\  acc += o.b.c + o.arr[1];
        \\}
        \\acc;
    );
    // sum_{i=0..3999}(i + i) = (3999*4000) = 15,996,000.
    try std.testing.expectEqual(@as(f64, 15996000), result.asNum());
    try std.testing.expect(ctx.gc.?.collections > 2); // multiple concurrent cycles closed
    try std.testing.expect(ctx.gc.?.live_cells < 20000); // heap stayed bounded
    try std.testing.expect(ctx.gc_marker == null); // no marker outlived the run
    try std.testing.expect(!ctx.gc.?.concurrent.load(.acquire));

    // A retained graph built + repeatedly assigned (env writes) under concurrent
    // marking is intact afterward.
    const r = try ctx.evaluate(
        \\globalThis.keep = { sum: 0 };
        \\for (let i = 0; i < 4000; i++) { globalThis.keep.sum += 1; const junk = { i }; }
        \\globalThis.keep.sum;
    );
    try std.testing.expectEqual(@as(f64, 4000), r.asNum());
}

test "enable_gc concurrent (M3): generators and iterator helpers are safe under concurrent marking" {
    // The deferred-trace path: a *running* generator's `exec` is the live VM
    // stack and an iterator helper's fields update around JS callbacks, so the
    // marker can't read them mid-cycle — `gc.zig` defers tracing those cell kinds
    // to the world-stopped finish (the cell is still marked, so it survives; its
    // edges are found when the mutator is quiescent). This workload runs many
    // generators and Iterator-helper chains while the concurrent marker traces,
    // proving the deferral keeps their reachable state alive and is race-free.
    if (builtin.single_threaded) return error.SkipZigTest;
    const ctx = try Context.createWith(std.testing.allocator, .{ .enable_gc = true, .concurrent_gc = true });
    defer ctx.destroy();

    const result = try ctx.evaluate(
        \\function* range(n) { for (let i = 0; i < n; i++) yield i; }
        \\let total = 0;
        \\for (let r = 0; r < 400; r++) {
        \\  // A suspended-and-resumed generator (its exec is live during resume).
        \\  let g = range(20), s = 0;
        \\  for (const x of g) s += x;
        \\  // An iterator-helper chain (map/filter/take — inner state updated
        \\  // around the callbacks the marker must not race).
        \\  const h = range(50).map(x => x * 2).filter(x => x % 3 === 0).take(5);
        \\  for (const y of h) s += y;
        \\  total += s;
        \\}
        \\total;
    );
    // Per round r: sum_{i=0..19} i = 190; helper picks first 5 of {0,6,12,18,...}
    // = 0+6+12+18+24 = 60. So s = 250 per round, × 400 = 100000.
    try std.testing.expectEqual(@as(f64, 100000), result.asNum());
    try std.testing.expect(ctx.gc.?.collections > 2); // concurrent cycles ran mid-workload
    try std.testing.expect(ctx.gc_marker == null);
    try std.testing.expect(!ctx.gc.?.concurrent.load(.acquire));
}

test "enable_gc concurrent (M3): mixed-workload stress amplifier stays correct + race-free" {
    // M3 stress amplifier: hammer the concurrent driver with every cell kind at
    // once — plain objects, arrays (dense + push), Map/Set, WeakMap/WeakSet
    // (keyed by live objects), Promises, closures capturing per-iteration `let`
    // environments, generators, and iterator-helper chains — so a single
    // collection cycle traces objects (locked), environments (binding_lock),
    // promises (Promise.lock), weak collections (isMarked clearing), and
    // generators/iterator-helpers (deferred) concurrently with the mutator
    // building and mutating all of them. Exact final tallies prove nothing live
    // was wrongly freed; TSan-clean proves no path races the marker.
    if (builtin.single_threaded) return error.SkipZigTest;
    const ctx = try Context.createWith(std.testing.allocator, .{ .enable_gc = true, .concurrent_gc = true });
    defer ctx.destroy();

    const result = try ctx.evaluate(
        \\function* gen(n) { for (let i = 0; i < n; i++) yield i; }
        \\const keys = [];
        \\for (let i = 0; i < 64; i++) keys.push({ id: i }); // live weak keys
        \\const wm = new WeakMap(), ws = new WeakSet();
        \\const arr = [], m = new Map(), s = new Set();
        \\const closures = [];
        \\let acc = 0;
        \\for (let r = 0; r < 300; r++) {
        \\  const o = { r, nested: { v: r }, list: [r, r + 1, r + 2] };
        \\  arr.push(o);
        \\  if (arr.length > 50) arr.shift();          // bounded churn
        \\  m.set('k' + (r % 32), o);
        \\  s.add(r % 48);
        \\  const k = keys[r % keys.length];
        \\  wm.set(k, o); ws.add(k);
        \\  // closure captures this iteration's `let r` and `o` (env binding writes)
        \\  let local = r; closures.push(() => local + o.nested.v);
        \\  if (closures.length > 20) closures.shift();
        \\  let g = gen(10), gs = 0; for (const x of g) gs += x;       // generator
        \\  const h = gen(30).map(x => x + 1).filter(x => x % 2 === 0).take(4);
        \\  for (const y of h) gs += y;                                // iter-helper
        \\  acc += gs;
        \\  Promise.resolve(o).then(() => {});                        // promise + reaction
        \\}
        \\// Verify the live structures survived intact.
        \\let sum = 0;
        \\for (const f of closures) sum += f();
        \\for (const k of keys) { if (wm.has(k)) sum += wm.get(k).r; }
        \\acc * 100000 + m.size * 1000 + s.size * 10 + (sum > 0 ? 1 : 0);
    );
    // gen(10): sum 0..9 = 45; helper: first 4 evens of {x+1 | x in 0..29} =
    // {1..30} evens = 2,4,6,8 = 20. gs = 65/round × 300 = 19500.
    // m.size = 32 (keys k0..k31), s.size = 48 (0..47). sum > 0.
    try std.testing.expectEqual(@as(f64, 19500 * 100000 + 32 * 1000 + 48 * 10 + 1), result.asNum());
    try std.testing.expect(ctx.gc.?.collections > 2);
    try std.testing.expect(ctx.gc_marker == null);
    try std.testing.expect(!ctx.gc.?.concurrent.load(.acquire));
}

test "LockedArena: concurrent allocation from many threads is race-free (GIL-removal prereq #1)" {
    // Blocker #1 for GIL removal: shapes/strings/AST/binding tables are
    // arena-allocated, and `ArenaAllocator` is not thread-safe. `LockedArena`
    // serializes arena access so parallel JS threads can allocate once the GIL
    // is gone. Hammer it directly from 8 threads (bypassing the GIL, as the
    // post-GIL engine would) and confirm every allocation is valid and distinct.
    if (builtin.single_threaded) return error.SkipZigTest;
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var la = LockedArena{ .inner = arena_state.allocator() };
    const a = la.allocator();

    const threads = 8;
    const per = 1000;
    const Worker = struct {
        alloc: std.mem.Allocator,
        ok: std.atomic.Value(u32) = .init(0),
        fn run(s: *@This()) void {
            var i: usize = 0;
            while (i < per) : (i += 1) {
                // Mixed sizes + writes, like real shape/string/binding allocs.
                const buf = s.alloc.alloc(u8, 8 + (i % 56)) catch return;
                @memset(buf, @intCast(i & 0xff));
                // Verify our own write survived (a torn arena would corrupt it).
                if (buf[0] == @as(u8, @intCast(i & 0xff)) and buf[buf.len - 1] == @as(u8, @intCast(i & 0xff)))
                    _ = s.ok.fetchAdd(1, .monotonic);
            }
        }
    };
    var w = Worker{ .alloc = a };
    var pool: [threads]std.Thread = undefined;
    for (&pool) |*t| t.* = try std.Thread.spawn(.{}, Worker.run, .{&w});
    for (&pool) |*t| t.join();

    // Every one of the threads*per allocations succeeded and read back intact.
    try std.testing.expectEqual(@as(u32, threads * per), w.ok.load(.monotonic));
}

test "parallel_gc (M3 GIL-removal bring-up): mutators create+shape+mutate disjoint objects in parallel" {
    // The payoff of the GIL-removal prerequisites composed: with thread-safe cell
    // allocation (setParallel), thread-safe arena (LockedArena → shapes/strings),
    // atomic backing counters, and the per-structure object/shape locks, multiple
    // mutators run real object operations *in parallel with no GIL* — allocating
    // cells, transitioning shapes (shared root, converging under transition_lock),
    // and writing slots (per-object property_lock). Each thread owns a disjoint
    // set of objects; afterward every object is intact and correctly shaped.
    // This is the first true parallel-JS-heap-mutation demonstration. TSan-clean.
    if (builtin.single_threaded) return error.SkipZigTest;
    const ctx = try Context.createWithTestingOptions(std.testing.allocator, .{ .enable_gc = true, .parallel_gc = true });
    defer ctx.destroy();

    const nthreads = 4;
    const per = 1000;
    const Worker = struct {
        ctx: *Context,
        objs: []*value.Object,
        ok: std.atomic.Value(u32) = .init(0),
        fn run(s: *@This()) void {
            // Allocate into the shared heap/arena from this thread: set the
            // threadlocal active heap + intern arena. No GIL — the thread-safe
            // arena/backing + per-structure locks are what make it safe.
            const sh = gc_mod.setActiveHeap(s.ctx.gc);
            defer _ = gc_mod.setActiveHeap(sh);
            const sa = strcell.setActiveArena(s.ctx.arena());
            defer _ = strcell.setActiveArena(sa);
            const a = s.ctx.arena();
            for (s.objs, 0..) |*slot, i| {
                const o = gc_mod.allocObj(a) catch return;
                o.* = .{};
                // Two property adds → shape transitions on the shared root shape
                // (serialized + converged by transition_lock), slots under this
                // object's property_lock.
                o.setOwn(a, s.ctx.root_shape, "v", Value.num(@floatFromInt(i))) catch return;
                o.setOwn(a, s.ctx.root_shape, "t", Value.num(1)) catch return;
                slot.* = o;
                if (o.getOwn("v")) |gv| {
                    if (gv.asNum() == @as(f64, @floatFromInt(i))) _ = s.ok.fetchAdd(1, .monotonic);
                }
            }
        }
    };
    var storage: [nthreads][per]*value.Object = undefined;
    var workers: [nthreads]Worker = undefined;
    for (&workers, 0..) |*w, t| w.* = .{ .ctx = ctx, .objs = storage[t][0..] };
    var pool: [nthreads]std.Thread = undefined;
    for (&pool, 0..) |*th, t| th.* = try std.Thread.spawn(.{}, Worker.run, .{&workers[t]});
    for (&pool) |*th| th.join();

    var total_ok: u32 = 0;
    for (&workers) |*w| total_ok += w.ok.load(.monotonic);
    try std.testing.expectEqual(@as(u32, nthreads * per), total_ok);
    // Every object across all threads is intact and correctly shaped.
    for (&storage) |*arr| {
        for (arr, 0..) |o, i| {
            const gv = o.getOwn("v") orelse return error.TestUnexpectedResult;
            try std.testing.expectEqual(@as(f64, @floatFromInt(i)), gv.asNum());
            const gt = o.getOwn("t") orelse return error.TestUnexpectedResult;
            try std.testing.expectEqual(@as(f64, 1), gt.asNum());
        }
    }
}

test "parallel_gc (M3 GIL-removal bring-up): parse+compile+VM-execute disjoint scripts in parallel, no GIL" {
    // Parallel JS *execution* (not just heap mutation): each thread parses,
    // compiles, and runs its own pure-computation script — local vars, a loop,
    // local object allocation, no globalThis writes — on its own Interpreter,
    // truly in parallel with no GIL. Exercises the parser/compiler/VM and the
    // shared heap/arena/shapes + active_interpreters lock under real parallelism.
    // Mid-script GC is off in parallel_gc mode (the safepoint protocol for
    // parallel collection is a later step), so this isolates execution safety.
    if (builtin.single_threaded) return error.SkipZigTest;
    const ctx = try Context.createWithTestingOptions(std.testing.allocator, .{ .enable_gc = true, .parallel_gc = true });
    defer ctx.destroy();

    const nthreads = 4;
    const Worker = struct {
        ctx: *Context,
        result: std.atomic.Value(i64) = .init(-1),
        fn run(s: *@This()) void {
            const sh = gc_mod.setActiveHeap(s.ctx.gc);
            defer _ = gc_mod.setActiveHeap(sh);
            const sa = strcell.setActiveArena(s.ctx.arena());
            defer _ = strcell.setActiveArena(sa);
            const a = s.ctx.arena();
            const src = "(function(){ let s = 0; for (let i = 0; i < 2000; i++) { const o = { x: i }; s += o.x; } return s; })()";
            const owned = a.dupe(u8, src) catch return;
            var parser = Parser.init(a, owned) catch return;
            const prog = parser.parseProgram() catch return;
            var machine = s.ctx.interpreter();
            s.ctx.pushActiveInterpreter(&machine) catch return; // exercises active_interp_lock
            defer s.ctx.popActiveInterpreter(&machine);
            const outcome: interp.EvalError!value.Value = if (compiler.Compiler.compileProgram(a, prog)) |chunk|
                vm.run(&machine, chunk, null)
            else |_|
                machine.eval(prog);
            if (outcome) |val| {
                if (val.isNumber()) s.result.store(@intFromFloat(val.asNum()), .monotonic);
            } else |_| {}
        }
    };
    var workers: [nthreads]Worker = undefined;
    for (&workers) |*w| w.* = .{ .ctx = ctx };
    var pool: [nthreads]std.Thread = undefined;
    for (&pool, 0..) |*th, t| th.* = try std.Thread.spawn(.{}, Worker.run, .{&workers[t]});
    for (&pool) |*th| th.join();
    // sum_{i=0..1999} i = 1999000 — each thread computed it independently, in parallel.
    for (&workers) |*w| try std.testing.expectEqual(@as(i64, 1999000), w.result.load(.monotonic));
}

test "parallel_gc (M3 GIL-removal bring-up): one shared chunk over a shared object, in parallel, no GIL" {
    // The strongest execution case: all threads run the **same compiled chunk**
    // (so they share its inline caches) over the **same globalThis-rooted object**
    // (so they share its `property_lock` and shape), truly in parallel with no
    // GIL. Each iteration does a `get_prop`+`set_prop` on `shared.counter`
    // (exercises the IC write/record path + the insertion barrier under
    // contention — lost updates are fine, JS without Atomics) and a `get_prop`
    // on `shared.base` (a property never written — its reads must NEVER tear, so
    // every thread's `base`-sum is exact). This drives the seqlock inline caches,
    // `property_lock`, and `binding_lock` (the global `shared` lookup) all at
    // once under real parallel bytecode. TSan-clean is the proof.
    if (builtin.single_threaded) return error.SkipZigTest;
    const ctx = try Context.createWithTestingOptions(std.testing.allocator, .{ .enable_gc = true, .parallel_gc = true });
    defer ctx.destroy();

    const sh0 = gc_mod.setActiveHeap(ctx.gc);
    defer _ = gc_mod.setActiveHeap(sh0);
    const sa0 = strcell.setActiveArena(ctx.arena());
    defer _ = strcell.setActiveArena(sa0);
    const a = ctx.arena();

    // A shared object rooted on globalThis: fixed shape {counter, base}.
    const shared = try gc_mod.allocObj(a);
    shared.* = .{};
    try shared.setOwn(a, ctx.root_shape, "counter", Value.num(0));
    try shared.setOwn(a, ctx.root_shape, "base", Value.num(100));
    try ctx.global_object.setOwn(ctx.gpa, ctx.root_shape, "shared", Value.obj(shared));

    // Compile ONCE on this thread; every worker runs this same chunk (shared ICs).
    const iters = 1000;
    const src =
        \\(function(){
        \\  let sum = 0;
        \\  for (let i = 0; i < 1000; i++) {
        \\    shared.counter = shared.counter + 1; // set_prop + get_prop (contended)
        \\    sum += shared.base;                  // get_prop of a never-written prop
        \\  }
        \\  return sum;
        \\})()
    ;
    const owned = try a.dupe(u8, src);
    var parser = try Parser.init(a, owned);
    const prog = try parser.parseProgram();
    const chunk = compiler.Compiler.compileProgram(a, prog) catch return error.TestUnexpectedResult;

    const nthreads = 4;
    const Worker = struct {
        ctx: *Context,
        chunk: *@import("bytecode.zig").Chunk,
        result: std.atomic.Value(i64) = .init(-1),
        fn run(s: *@This()) void {
            const sh = gc_mod.setActiveHeap(s.ctx.gc);
            defer _ = gc_mod.setActiveHeap(sh);
            const sa = strcell.setActiveArena(s.ctx.arena());
            defer _ = strcell.setActiveArena(sa);
            var machine = s.ctx.interpreter();
            s.ctx.pushActiveInterpreter(&machine) catch return;
            defer s.ctx.popActiveInterpreter(&machine);
            if (vm.run(&machine, s.chunk, null)) |val| {
                if (val.isNumber()) s.result.store(@intFromFloat(val.asNum()), .monotonic);
            } else |_| {}
        }
    };
    var workers: [nthreads]Worker = undefined;
    for (&workers) |*w| w.* = .{ .ctx = ctx, .chunk = chunk };
    var pool: [nthreads]std.Thread = undefined;
    for (&pool, 0..) |*th, t| th.* = try std.Thread.spawn(.{}, Worker.run, .{&workers[t]});
    for (&pool) |*th| th.join();

    // Every thread summed `shared.base` (== 100, never written) exactly `iters`
    // times: a torn read through the shared IC would corrupt this. Exact for all.
    for (&workers) |*w| try std.testing.expectEqual(@as(i64, iters * 100), w.result.load(.monotonic));
    // `counter` raced (no Atomics) so its value is nondeterministic, but it must
    // be a valid in-range number — never torn/garbage — and writes happened.
    const counter = shared.getOwn("counter") orelse return error.TestUnexpectedResult;
    try std.testing.expect(counter.isNumber());
    try std.testing.expect(counter.asNum() >= 1 and counter.asNum() <= nthreads * iters);
}

test "parallel_gc (M3 GIL-removal bring-up): rich builtin-heavy workload in parallel, no GIL" {
    // Broadens parallel-execution coverage past arithmetic/loops onto the shared
    // realm machinery the simpler bring-up tests miss: function calls + closures,
    // Array.prototype methods (push/map/reduce/filter), String concat, Math,
    // object literals + property reads. Each thread parses + compiles (parallel
    // arena allocation through LockedArena) and runs its OWN script, so results
    // are deterministic, but they all hammer the SAME realm intrinsics and
    // prototype chains in parallel with no GIL. TSan-clean here is what surfaces
    // residual shared-state hazards (lazy prototype/method installation, realm
    // caches) that small workloads don't reach.
    if (builtin.single_threaded) return error.SkipZigTest;
    const ctx = try Context.createWithTestingOptions(std.testing.allocator, .{ .enable_gc = true, .parallel_gc = true });
    defer ctx.destroy();

    const nthreads = 4;
    const Worker = struct {
        ctx: *Context,
        result: std.atomic.Value(i64) = .init(-1),
        fn run(s: *@This()) void {
            const sh = gc_mod.setActiveHeap(s.ctx.gc);
            defer _ = gc_mod.setActiveHeap(sh);
            const sa = strcell.setActiveArena(s.ctx.arena());
            defer _ = strcell.setActiveArena(sa);
            const a = s.ctx.arena();
            // reduce of (2i+1 for i in 0..199) = 200^2 = 40000; filter/map/closures
            // and the builtins along the way all run against shared intrinsics.
            const src =
                \\(function(){
                \\  let arr = [];
                \\  for (let i = 0; i < 200; i++) arr.push(i);
                \\  let mapped = arr.map(function(x){ return 2 * x + 1; });
                \\  let evens = mapped.filter(function(x){ return x % 2 === 1; });
                \\  let sum = evens.reduce(function(acc, x){ return acc + x; }, 0);
                \\  let label = "sum=" + sum + "/" + Math.max(1, 2);
                \\  let o = { total: sum, tag: label, root: Math.sqrt(sum) };
                \\  return o.total;
                \\})()
            ;
            const owned = a.dupe(u8, src) catch return;
            var parser = Parser.init(a, owned) catch return;
            const prog = parser.parseProgram() catch return;
            var machine = s.ctx.interpreter();
            s.ctx.pushActiveInterpreter(&machine) catch return;
            defer s.ctx.popActiveInterpreter(&machine);
            const outcome: interp.EvalError!value.Value = if (compiler.Compiler.compileProgram(a, prog)) |chunk|
                vm.run(&machine, chunk, null)
            else |_|
                machine.eval(prog);
            if (outcome) |val| {
                if (val.isNumber()) s.result.store(@intFromFloat(val.asNum()), .monotonic);
            } else |_| {}
        }
    };
    var workers: [nthreads]Worker = undefined;
    for (&workers) |*w| w.* = .{ .ctx = ctx };
    var pool: [nthreads]std.Thread = undefined;
    for (&pool, 0..) |*th, t| th.* = try std.Thread.spawn(.{}, Worker.run, .{&workers[t]});
    for (&pool) |*th| th.join();
    // All 200 mapped values 2i+1 are odd, so the filter keeps them all and the
    // reduce gives 200^2 = 40000 — each thread computed it independently.
    for (&workers) |*w| try std.testing.expectEqual(@as(i64, 40000), w.result.load(.monotonic));
}

test "parallel_gc (M3 GIL-removal bring-up): concurrent lazy .prototype install yields one identity" {
    // A function's `.prototype` is materialized lazily on first `new`/`.prototype`
    // access (`Interpreter.protoObject`) — a check-then-act over shared object
    // storage. With the GIL dropped, N threads racing that first access on the
    // SAME constructor could each install a distinct prototype, breaking
    // `F.prototype === F.prototype`. The double-checked lock (`Gil.lazy_init_lock`)
    // must make exactly one install win and all threads observe it. `enable_threads`
    // gives the realm a Gil (the lock's home); the workers call `protoObject`
    // directly with no GIL held, modelling the dropped-GIL future. A go-barrier
    // makes them all hit the un-materialized state together. TSan-clean.
    if (builtin.single_threaded) return error.SkipZigTest;
    const ctx = try Context.createWithTestingOptions(std.testing.allocator, .{ .enable_gc = true, .parallel_gc = true, .enable_threads = true });
    defer ctx.destroy();
    _ = ctx.gil orelse return error.TestUnexpectedResult; // the lock needs a Gil

    const sh0 = gc_mod.setActiveHeap(ctx.gc);
    defer _ = gc_mod.setActiveHeap(sh0);
    const sa0 = strcell.setActiveArena(ctx.arena());
    defer _ = strcell.setActiveArena(sa0);

    // A bare object standing in for a constructor: no `prototype` slot yet, so the
    // first `protoObject` call must materialize one.
    const ctor = try gc_mod.allocObj(ctx.arena());
    ctor.* = .{};

    const nthreads = 8;
    const Worker = struct {
        ctx: *Context,
        ctor: *value.Object,
        go: *std.atomic.Value(bool),
        result: std.atomic.Value(?*value.Object) = .init(null),
        fn run(s: *@This()) void {
            const sh = gc_mod.setActiveHeap(s.ctx.gc);
            defer _ = gc_mod.setActiveHeap(sh);
            const sa = strcell.setActiveArena(s.ctx.arena());
            defer _ = strcell.setActiveArena(sa);
            var machine = s.ctx.interpreter();
            s.ctx.pushActiveInterpreter(&machine) catch return;
            defer s.ctx.popActiveInterpreter(&machine);
            while (!s.go.load(.acquire)) std.atomic.spinLoopHint();
            const p = machine.protoObject(s.ctor) catch return;
            s.result.store(p, .release);
        }
    };
    var go = std.atomic.Value(bool).init(false);
    var workers: [nthreads]Worker = undefined;
    for (&workers) |*w| w.* = .{ .ctx = ctx, .ctor = ctor, .go = &go };
    var pool: [nthreads]std.Thread = undefined;
    for (&pool, 0..) |*th, t| th.* = try std.Thread.spawn(.{}, Worker.run, .{&workers[t]});
    go.store(true, .release);
    for (&pool) |*th| th.join();

    // Exactly one prototype was installed, and every thread observed that same
    // object — no duplicate install slipped through the check-then-act.
    const canonical = (ctor.getOwn("prototype") orelse return error.TestUnexpectedResult).asObj();
    for (&workers) |*w| {
        const got = w.result.load(.acquire) orelse return error.TestUnexpectedResult;
        try std.testing.expectEqual(canonical, got);
    }
    // The installed prototype links back: F.prototype.constructor === F.
    const back = (canonical.getOwn("constructor") orelse return error.TestUnexpectedResult);
    try std.testing.expect(back.isObject() and back.asObj() == ctor);
}

test "parallel_gc (M3 GIL-removal bring-up): concurrent first .prototype access via real bytecode is consistent" {
    // End-to-end version of the lazy-`.prototype` fix through the *full* getProperty
    // path (not just `protoObject`): a function `Foo` is defined on globalThis with
    // its `.prototype` left unmaterialized, then N threads each run real bytecode
    // that first-touches `Foo.prototype`, reads `.prototype.constructor`, and
    // constructs an instance — all racing the one-time lazy install with no GIL.
    // Every thread must see `Foo.prototype.constructor === Foo`, `new Foo()
    // instanceof Foo`, and `Foo.length === 2`. A duplicate install (or torn
    // attr/constructor tweak) would break the identity. TSan-clean.
    if (builtin.single_threaded) return error.SkipZigTest;
    const ctx = try Context.createWithTestingOptions(std.testing.allocator, .{ .enable_gc = true, .parallel_gc = true, .enable_threads = true });
    defer ctx.destroy();
    _ = ctx.gil orelse return error.TestUnexpectedResult;

    // Define the shared function WITHOUT touching `.prototype`, so the first
    // access happens concurrently on the worker threads below.
    _ = try ctx.evaluate("function Foo(a, b) { this.tag = 1; }");

    const nthreads = 8;
    const Worker = struct {
        ctx: *Context,
        go: *std.atomic.Value(bool),
        result: std.atomic.Value(i64) = .init(-999),
        fn run(s: *@This()) void {
            const sh = gc_mod.setActiveHeap(s.ctx.gc);
            defer _ = gc_mod.setActiveHeap(sh);
            const sa = strcell.setActiveArena(s.ctx.arena());
            defer _ = strcell.setActiveArena(sa);
            const a = s.ctx.arena();
            const src =
                \\(function(){
                \\  var p = Foo.prototype;                 // race the lazy install
                \\  var okCtor = (p.constructor === Foo) ? 1 : 0;
                \\  var inst = new Foo();                  // uses Foo.prototype
                \\  var okInst = (inst instanceof Foo) ? 1 : 0;
                \\  return okCtor * 100 + okInst * 10 + Foo.length; // expect 110 + 2 = 112
                \\})()
            ;
            const owned = a.dupe(u8, src) catch return;
            var parser = Parser.init(a, owned) catch return;
            const prog = parser.parseProgram() catch return;
            var machine = s.ctx.interpreter();
            s.ctx.pushActiveInterpreter(&machine) catch return;
            defer s.ctx.popActiveInterpreter(&machine);
            while (!s.go.load(.acquire)) std.atomic.spinLoopHint();
            const outcome: interp.EvalError!value.Value = if (compiler.Compiler.compileProgram(a, prog)) |chunk|
                vm.run(&machine, chunk, null)
            else |_|
                machine.eval(prog);
            if (outcome) |val| {
                if (val.isNumber()) s.result.store(@intFromFloat(val.asNum()), .monotonic);
            } else |_| {}
        }
    };
    var go = std.atomic.Value(bool).init(false);
    var workers: [nthreads]Worker = undefined;
    for (&workers) |*w| w.* = .{ .ctx = ctx, .go = &go };
    var pool: [nthreads]std.Thread = undefined;
    for (&pool, 0..) |*th, t| th.* = try std.Thread.spawn(.{}, Worker.run, .{&workers[t]});
    go.store(true, .release);
    for (&pool) |*th| th.join();

    // 110 (constructor identity + instanceof) + Foo.length(2) = 112, for every thread.
    for (&workers) |*w| try std.testing.expectEqual(@as(i64, 112), w.result.load(.monotonic));
}

test "parallel_gc (M3 GIL-removal bring-up): contended Map.set on a shared Map via real bytecode" {
    // A distinct shared subsystem under real parallel bytecode: N threads each
    // insert a disjoint block of keys into ONE shared `Map` via `m.set(k, v)`,
    // contending the Map's `elements_lock` (which funnels insertion + table
    // rehash). The global `m` lookup goes through `binding_lock`, the method
    // dispatch + entry storage through `elements_lock`. After join the map must
    // hold exactly N*M entries with the right values — no insert lost or torn,
    // no rehash corruption. TSan-clean proves the Map insertion/rehash funnel is
    // race-free under parallel mutation.
    if (builtin.single_threaded) return error.SkipZigTest;
    const ctx = try Context.createWithTestingOptions(std.testing.allocator, .{ .enable_gc = true, .parallel_gc = true, .enable_threads = true });
    defer ctx.destroy();

    _ = try ctx.evaluate("globalThis.m = new Map();");

    const nthreads = 4;
    const per = 250;
    const Worker = struct {
        ctx: *Context,
        base: usize,
        ok: std.atomic.Value(bool) = .init(false),
        fn run(s: *@This()) void {
            const sh = gc_mod.setActiveHeap(s.ctx.gc);
            defer _ = gc_mod.setActiveHeap(sh);
            const sa = strcell.setActiveArena(s.ctx.arena());
            defer _ = strcell.setActiveArena(sa);
            const a = s.ctx.arena();
            // Each thread writes its own [base, base+per) block; values = key*2.
            var buf: [128]u8 = undefined;
            const src = std.fmt.bufPrint(&buf,
                \\(function(){{ for (var i = {d}; i < {d}; i++) m.set(i, i * 2); return true; }})()
            , .{ s.base, s.base + per }) catch return;
            const owned = a.dupe(u8, src) catch return;
            var parser = Parser.init(a, owned) catch return;
            const prog = parser.parseProgram() catch return;
            var machine = s.ctx.interpreter();
            s.ctx.pushActiveInterpreter(&machine) catch return;
            defer s.ctx.popActiveInterpreter(&machine);
            const outcome: interp.EvalError!value.Value = if (compiler.Compiler.compileProgram(a, prog)) |chunk|
                vm.run(&machine, chunk, null)
            else |_|
                machine.eval(prog);
            if (outcome) |val| s.ok.store(val.isBoolean() and val.asBool(), .release) else |_| {}
        }
    };
    var workers: [nthreads]Worker = undefined;
    for (&workers, 0..) |*w, t| w.* = .{ .ctx = ctx, .base = t * per };
    var pool: [nthreads]std.Thread = undefined;
    for (&pool, 0..) |*th, t| th.* = try std.Thread.spawn(.{}, Worker.run, .{&workers[t]});
    for (&pool) |*th| th.join();

    for (&workers) |*w| try std.testing.expect(w.ok.load(.acquire));
    // Exactly N*M entries, each key k mapping to k*2 — verified through the
    // engine on the main thread (quiescent).
    const size = try ctx.evaluate("m.size");
    try std.testing.expectEqual(@as(f64, nthreads * per), size.asNum());
    const allok = try ctx.evaluate(
        \\(function(){
        \\  for (var k = 0; k < 1000; k++) { if (m.get(k) !== k * 2) return false; }
        \\  return m.size === 1000;
        \\})()
    );
    try std.testing.expect(allok.isBoolean() and allok.asBool());
}

test "parallel_gc (M3 GIL-removal bring-up): shared closure upvalue mutated in parallel stays consistent" {
    // The upvalue path: a closure captures a parent function's local (`n`), and
    // that ONE closure is shared across threads, so every `bump()` reads+writes
    // the same captured binding through `store_upval`/`load_upval` against the
    // shared closure environment. N threads hammer it in parallel with no GIL.
    // `n++` is a read-modify-write so the final value races (lost updates are
    // legal without Atomics), but every observed value must be a valid integer
    // in range — never torn/garbage — and the run must be TSan-clean: the proof
    // that `Environment.binding_lock` serializes upvalue reads/writes + table
    // growth under real parallel bytecode.
    if (builtin.single_threaded) return error.SkipZigTest;
    const ctx = try Context.createWithTestingOptions(std.testing.allocator, .{ .enable_gc = true, .parallel_gc = true, .enable_threads = true });
    defer ctx.destroy();

    // `shared.bump` closes over the local `n` of `makeCounter`'s activation.
    _ = try ctx.evaluate(
        \\globalThis.shared = (function makeCounter(){
        \\  var n = 0;
        \\  return { bump: function(){ n = n + 1; return n; } };
        \\})();
    );

    const nthreads = 4;
    const per = 1000;
    const Worker = struct {
        ctx: *Context,
        bad: std.atomic.Value(bool) = .init(false), // a bump ever returned out of range
        fn run(s: *@This()) void {
            const sh = gc_mod.setActiveHeap(s.ctx.gc);
            defer _ = gc_mod.setActiveHeap(sh);
            const sa = strcell.setActiveArena(s.ctx.arena());
            defer _ = strcell.setActiveArena(sa);
            const a = s.ctx.arena();
            // Each call returns the post-increment value of the shared upvalue;
            // it must always be an integer in (0, nthreads*per].
            const src =
                \\(function(){
                \\  var worst = 0;
                \\  for (var i = 0; i < 1000; i++) {
                \\    var v = shared.bump();
                \\    if (typeof v !== "number" || v < 1 || v > 4000 || (v | 0) !== v) worst = -1;
                \\  }
                \\  return worst;
                \\})()
            ;
            const owned = a.dupe(u8, src) catch return;
            var parser = Parser.init(a, owned) catch return;
            const prog = parser.parseProgram() catch return;
            var machine = s.ctx.interpreter();
            s.ctx.pushActiveInterpreter(&machine) catch return;
            defer s.ctx.popActiveInterpreter(&machine);
            const outcome: interp.EvalError!value.Value = if (compiler.Compiler.compileProgram(a, prog)) |chunk|
                vm.run(&machine, chunk, null)
            else |_|
                machine.eval(prog);
            if (outcome) |val| {
                if (val.isNumber() and val.asNum() < 0) s.bad.store(true, .release);
            } else |_| s.bad.store(true, .release);
        }
    };
    var workers: [nthreads]Worker = undefined;
    for (&workers) |*w| w.* = .{ .ctx = ctx };
    var pool: [nthreads]std.Thread = undefined;
    for (&pool, 0..) |*th, t| th.* = try std.Thread.spawn(.{}, Worker.run, .{&workers[t]});
    for (&pool) |*th| th.join();

    for (&workers) |*w| try std.testing.expect(!w.bad.load(.acquire)); // every bump in range
    // The final upvalue is some valid count in (0, N*M] (lost updates allowed).
    const final = try ctx.evaluate("shared.bump()");
    try std.testing.expect(final.isNumber());
    try std.testing.expect(final.asNum() >= 1 and final.asNum() <= nthreads * per + 1);
}

test "parallel_gc (M3 GIL-removal bring-up): contended parallel appends to a shared array lose nothing" {
    // Beyond disjoint work: N threads mutate the *same* object in parallel,
    // contending the per-structure lock. Each appends a distinct block of
    // numbers to one shared array (`appendElement` → `elements_lock` + insertion
    // barrier + thread-safe object backing). If the lock correctly serializes the
    // mutators, the array ends with exactly N*M elements and their sum is exact —
    // no append is lost or torn. TSan-clean proves the contended path is race-free.
    if (builtin.single_threaded) return error.SkipZigTest;
    const ctx = try Context.createWithTestingOptions(std.testing.allocator, .{ .enable_gc = true, .parallel_gc = true });
    defer ctx.destroy();

    const sh0 = gc_mod.setActiveHeap(ctx.gc);
    defer _ = gc_mod.setActiveHeap(sh0);
    const sa0 = strcell.setActiveArena(ctx.arena());
    defer _ = strcell.setActiveArena(sa0);

    const shared = try gc_mod.allocObj(ctx.arena());
    shared.* = .{ .is_array = true };

    const nthreads = 4;
    const per = 1000;
    const Worker = struct {
        ctx: *Context,
        arr: *value.Object,
        base: usize,
        fn run(s: *@This()) void {
            const sh = gc_mod.setActiveHeap(s.ctx.gc);
            defer _ = gc_mod.setActiveHeap(sh);
            const sa = strcell.setActiveArena(s.ctx.arena());
            defer _ = strcell.setActiveArena(sa);
            const a = s.ctx.arena();
            var i: usize = 0;
            while (i < per) : (i += 1) {
                s.arr.appendElement(a, Value.num(@floatFromInt(s.base + i))) catch return;
            }
        }
    };
    var workers: [nthreads]Worker = undefined;
    for (&workers, 0..) |*w, t| w.* = .{ .ctx = ctx, .arr = shared, .base = t * per };
    var pool: [nthreads]std.Thread = undefined;
    for (&pool, 0..) |*th, t| th.* = try std.Thread.spawn(.{}, Worker.run, .{&workers[t]});
    for (&pool) |*th| th.join();

    // No append lost: exactly N*M elements, and the multiset of values is
    // {0 .. N*M-1} (checked by exact sum, since each thread wrote a distinct block).
    try std.testing.expectEqual(@as(usize, nthreads * per), shared.elementsLen());
    var sum: f64 = 0;
    for (shared.elements.items) |el| sum += el.asNum();
    const n: f64 = @floatFromInt(nthreads * per);
    try std.testing.expectEqual(n * (n - 1) / 2, sum); // sum_{0..N*M-1}
}

test "parallel_gc (M3 GIL-removal bring-up): contended parallel property adds + shape growth on a shared object" {
    // The strongest contended case: N threads add distinct *named* properties to
    // the *same* object in parallel — contending `property_lock` AND growing the
    // shared object's shape chain (each add is a `Shape.transition`, serialized +
    // converged under `transition_lock`, allocating through the thread-safe
    // arena). After join the object must carry all N*M properties with correct
    // values — no slot/shape update lost or torn. TSan-clean.
    if (builtin.single_threaded) return error.SkipZigTest;
    const ctx = try Context.createWithTestingOptions(std.testing.allocator, .{ .enable_gc = true, .parallel_gc = true });
    defer ctx.destroy();

    const sh0 = gc_mod.setActiveHeap(ctx.gc);
    defer _ = gc_mod.setActiveHeap(sh0);
    const sa0 = strcell.setActiveArena(ctx.arena());
    defer _ = strcell.setActiveArena(sa0);

    const shared = try gc_mod.allocObj(ctx.arena());
    shared.* = .{};

    const nthreads = 4;
    const per = 500;
    const Worker = struct {
        ctx: *Context,
        obj: *value.Object,
        base: usize,
        fn run(s: *@This()) void {
            const sh = gc_mod.setActiveHeap(s.ctx.gc);
            defer _ = gc_mod.setActiveHeap(sh);
            const sa = strcell.setActiveArena(s.ctx.arena());
            defer _ = strcell.setActiveArena(sa);
            const a = s.ctx.arena();
            var buf: [24]u8 = undefined;
            var i: usize = 0;
            while (i < per) : (i += 1) {
                const key = std.fmt.bufPrint(&buf, "k{d}", .{s.base + i}) catch return;
                s.obj.setOwn(a, s.ctx.root_shape, key, Value.num(@floatFromInt(s.base + i))) catch return;
            }
        }
    };
    var workers: [nthreads]Worker = undefined;
    for (&workers, 0..) |*w, t| w.* = .{ .ctx = ctx, .obj = shared, .base = t * per };
    var pool: [nthreads]std.Thread = undefined;
    for (&pool, 0..) |*th, t| th.* = try std.Thread.spawn(.{}, Worker.run, .{&workers[t]});
    for (&pool) |*th| th.join();

    // Every one of the N*M distinct properties is present with the right value.
    var buf: [24]u8 = undefined;
    var k: usize = 0;
    while (k < nthreads * per) : (k += 1) {
        const key = try std.fmt.bufPrint(&buf, "k{d}", .{k});
        const got = shared.getOwn(key) orelse return error.TestUnexpectedResult;
        try std.testing.expectEqual(@as(f64, @floatFromInt(k)), got.asNum());
    }
}

test "parallel_gc (M3 GIL-removal bring-up): concurrent reader + writer on a shared global env is race-free" {
    // The reader-vs-writer case: one thread defines bindings on the shared global
    // env (`put` → `binding_lock`, rehashing the table) while another thread
    // repeatedly reads them (`get`). Now that `get` reads each scope's binding
    // tables under the same `binding_lock` the writer takes, the read can't tear
    // against, or read a freed table from, a concurrent rehash. The reader sees
    // each binding as either absent or its correct value — never garbage —
    // and the run is TSan-clean.
    if (builtin.single_threaded) return error.SkipZigTest;
    const ctx = try Context.createWithTestingOptions(std.testing.allocator, .{ .enable_gc = true, .parallel_gc = true });
    defer ctx.destroy();

    const sh0 = gc_mod.setActiveHeap(ctx.gc);
    defer _ = gc_mod.setActiveHeap(sh0);
    const sa0 = strcell.setActiveArena(ctx.arena());
    defer _ = strcell.setActiveArena(sa0);

    const n = 1000;
    const Shared = struct {
        ctx: *Context,
        done: std.atomic.Value(bool) = .init(false),
        bad: std.atomic.Value(bool) = .init(false), // set if a read ever sees a wrong value

        fn writer(s: *@This()) void {
            const sh = gc_mod.setActiveHeap(s.ctx.gc);
            defer _ = gc_mod.setActiveHeap(sh);
            const sa = strcell.setActiveArena(s.ctx.arena());
            defer _ = strcell.setActiveArena(sa);
            var buf: [24]u8 = undefined;
            var i: usize = 0;
            while (i < n) : (i += 1) {
                const name = std.fmt.bufPrint(&buf, "g{d}", .{i}) catch break;
                s.ctx.env.put(name, Value.num(@floatFromInt(i))) catch break;
            }
            s.done.store(true, .release);
        }
        fn reader(s: *@This()) void {
            const sh = gc_mod.setActiveHeap(s.ctx.gc);
            defer _ = gc_mod.setActiveHeap(sh);
            const sa = strcell.setActiveArena(s.ctx.arena());
            defer _ = strcell.setActiveArena(sa);
            var buf: [24]u8 = undefined;
            // Keep reading until the writer is done (and one full pass after).
            while (true) {
                const fin = s.done.load(.acquire);
                var i: usize = 0;
                while (i < n) : (i += 1) {
                    const name = std.fmt.bufPrint(&buf, "g{d}", .{i}) catch break;
                    if (s.ctx.env.get(name)) |v| {
                        // Present → must be the exact value the writer stored.
                        if (v.asNum() != @as(f64, @floatFromInt(i))) s.bad.store(true, .release);
                    }
                }
                if (fin) break;
                std.atomic.spinLoopHint();
            }
        }
    };
    var shared = Shared{ .ctx = ctx };
    const wt = try std.Thread.spawn(.{}, Shared.writer, .{&shared});
    const rt = try std.Thread.spawn(.{}, Shared.reader, .{&shared});
    wt.join();
    rt.join();

    try std.testing.expect(!shared.bad.load(.acquire)); // no torn/garbage read
    // After both finish, every binding is present and correct.
    var buf: [24]u8 = undefined;
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const name = try std.fmt.bufPrint(&buf, "g{d}", .{i});
        const v = ctx.env.get(name) orelse return error.TestUnexpectedResult;
        try std.testing.expectEqual(@as(f64, @floatFromInt(i)), v.asNum());
    }
}

test "parallel_gc (M3 GIL-removal bring-up): quiescent collection after a parallel build keeps the live graph, reclaims the garbage" {
    // The complete parallel-GC model, end-to-end: N threads concurrently build a
    // *rooted* shared object graph (each appends `id`-bearing objects to one array
    // hung off `globalThis`, contending `elements_lock` + the insertion barrier)
    // while also churning out throwaway garbage. Threads join — bringing the heap
    // to quiescence — and only THEN does a collection run (`collectGarbage`).
    //
    // This is the model that holds today without the (deferred) mid-script STW
    // barrier: mutate fully in parallel, collect at a quiescent point. The
    // collector must (a) keep every object reachable from the rooted array alive
    // and intact, and (b) actually reclaim the per-thread garbage. TSan-clean
    // proves the parallel build that feeds the collector is itself race-free.
    if (builtin.single_threaded) return error.SkipZigTest;
    const ctx = try Context.createWithTestingOptions(std.testing.allocator, .{ .enable_gc = true, .parallel_gc = true });
    defer ctx.destroy();

    const sh0 = gc_mod.setActiveHeap(ctx.gc);
    defer _ = gc_mod.setActiveHeap(sh0);
    const sa0 = strcell.setActiveArena(ctx.arena());
    defer _ = strcell.setActiveArena(sa0);

    // The shared array is rooted: hung off the (root-traced) global object, so the
    // graph reachable through it must survive collection.
    const shared = try gc_mod.allocObj(ctx.arena());
    shared.* = .{ .is_array = true };
    try ctx.global_object.setOwn(ctx.gpa, ctx.root_shape, "live", Value.obj(shared));

    const nthreads = 4;
    const per = 1000;
    const Worker = struct {
        ctx: *Context,
        arr: *value.Object,
        base: usize,
        fn run(s: *@This()) void {
            const sh = gc_mod.setActiveHeap(s.ctx.gc);
            defer _ = gc_mod.setActiveHeap(sh);
            const sa = strcell.setActiveArena(s.ctx.arena());
            defer _ = strcell.setActiveArena(sa);
            const a = s.ctx.arena();
            var i: usize = 0;
            while (i < per) : (i += 1) {
                // Live: an id-bearing object appended to the rooted array.
                const o = gc_mod.allocObj(a) catch return;
                o.* = .{};
                o.setOwn(a, s.ctx.root_shape, "id", Value.num(@floatFromInt(s.base + i))) catch return;
                s.arr.appendElement(a, Value.obj(o)) catch return;
                // Garbage: an unreachable object created and immediately dropped.
                const g = gc_mod.allocObj(a) catch return;
                g.* = .{};
                g.setOwn(a, s.ctx.root_shape, "junk", Value.num(@floatFromInt(s.base + i))) catch return;
            }
        }
    };
    var workers: [nthreads]Worker = undefined;
    for (&workers, 0..) |*w, t| w.* = .{ .ctx = ctx, .arr = shared, .base = t * per };
    var pool: [nthreads]std.Thread = undefined;
    for (&pool, 0..) |*th, t| th.* = try std.Thread.spawn(.{}, Worker.run, .{&workers[t]});
    for (&pool) |*th| th.join();

    // Quiescent collection: every thread has joined, the heap is at rest.
    ctx.collectGarbage();
    try std.testing.expect(ctx.gc.?.collections >= 1);

    // The live graph is intact: exactly N*M elements, each a surviving id-bearing
    // object whose property reads back correctly (the multiset of ids is
    // {0 .. N*M-1}, checked by exact sum).
    try std.testing.expectEqual(@as(usize, nthreads * per), shared.elementsLen());
    var sum: f64 = 0;
    for (shared.elements.items) |el| {
        try std.testing.expect(el.isObject());
        const got = el.asObj().getOwn("id") orelse return error.TestUnexpectedResult;
        sum += got.asNum();
    }
    const n: f64 = @floatFromInt(nthreads * per);
    try std.testing.expectEqual(n * (n - 1) / 2, sum); // sum_{0..N*M-1}
}

test "parallel_gc (M3 GIL-removal bring-up): GlobalSymbolRegistry get-or-create is atomic" {
    // The GlobalSymbolRegistry (`Symbol.for`) is a check-then-act over shared
    // object storage: look the key up, and only register a fresh symbol if
    // absent. Without serialization, two threads calling `Symbol.for(k)` could
    // both miss the lookup and register *distinct* symbols for the same key —
    // breaking `Symbol.for(k) === Symbol.for(k)`. `Gil.symbol_registry_lock`
    // (taken by `symbolForFn`/`symbolRegistry`) makes the whole get-or-create
    // atomic. This drives that exact critical section concurrently over a shared
    // registry object: every thread must agree on one symbol identity per key,
    // and the registry must hold exactly one entry per key. TSan-clean.
    if (builtin.single_threaded) return error.SkipZigTest;
    const ctx = try Context.createWithTestingOptions(std.testing.allocator, .{ .enable_gc = true, .parallel_gc = true, .enable_threads = true });
    defer ctx.destroy();
    const g = ctx.gil orelse return error.TestUnexpectedResult;

    const sh0 = gc_mod.setActiveHeap(ctx.gc);
    defer _ = gc_mod.setActiveHeap(sh0);
    const sa0 = strcell.setActiveArena(ctx.arena());
    defer _ = strcell.setActiveArena(sa0);

    const reg = try gc_mod.allocObj(ctx.arena());
    reg.* = .{};

    const nthreads = 4;
    const nkeys = 16;
    const Worker = struct {
        ctx: *Context,
        gil: *@import("gil.zig").Gil,
        reg: *value.Object,
        seen: [nkeys]?*value.Object = undefined,
        fn run(s: *@This()) void {
            const sh = gc_mod.setActiveHeap(s.ctx.gc);
            defer _ = gc_mod.setActiveHeap(sh);
            const sa = strcell.setActiveArena(s.ctx.arena());
            defer _ = strcell.setActiveArena(sa);
            for (&s.seen) |*p| p.* = null;
            const a = s.ctx.arena();
            // Several passes so threads heavily overlap on the same keys.
            var pass: usize = 0;
            while (pass < 64) : (pass += 1) {
                var k: usize = 0;
                while (k < nkeys) : (k += 1) {
                    var buf: [8]u8 = undefined;
                    const key = std.fmt.bufPrint(&buf, "s{d}", .{k}) catch return;
                    // The exact `symbolForFn` critical section: atomic get-or-create.
                    s.gil.lockSymbolRegistry();
                    const sym = if (s.reg.getOwn(key)) |existing| existing.asObj() else blk: {
                        const o = gc_mod.allocObj(a) catch {
                            s.gil.unlockSymbolRegistry();
                            return;
                        };
                        o.* = .{ .is_symbol = true };
                        s.reg.setOwn(a, s.ctx.root_shape, key, Value.obj(o)) catch {
                            s.gil.unlockSymbolRegistry();
                            return;
                        };
                        break :blk o;
                    };
                    s.gil.unlockSymbolRegistry();
                    // Identity must be stable for this key across all passes/threads.
                    if (s.seen[k]) |prev| {
                        if (prev != sym) return; // leaves a null/ mismatch the assert catches
                    } else s.seen[k] = sym;
                }
            }
        }
    };
    var workers: [nthreads]Worker = undefined;
    for (&workers) |*w| w.* = .{ .ctx = ctx, .gil = g, .reg = reg };
    var pool: [nthreads]std.Thread = undefined;
    for (&pool, 0..) |*th, t| th.* = try std.Thread.spawn(.{}, Worker.run, .{&workers[t]});
    for (&pool) |*th| th.join();

    // Every key resolved to exactly one symbol object, and all threads agree.
    var k: usize = 0;
    while (k < nkeys) : (k += 1) {
        var buf: [8]u8 = undefined;
        const key = try std.fmt.bufPrint(&buf, "s{d}", .{k});
        const canonical = (reg.getOwn(key) orelse return error.TestUnexpectedResult).asObj();
        for (workers) |w| {
            const got = w.seen[k] orelse return error.TestUnexpectedResult;
            try std.testing.expectEqual(canonical, got); // single shared identity
        }
    }
}

test "parallel_js (M3 GIL-removal slice): real Thread contends Atomics.Mutex with no context GIL" {
    // Vertical slice of the execution-path GIL drop: the public shared-realm
    // Thread entrypoint runs JS without holding the context GIL, and multiple
    // JS threads contend the production Atomics.Mutex/Lock record. The mutex's
    // own std.Io.Mutex+Condition must serialize the critical section; the shared
    // object update is ordinary JS, so without the mutex exactness is not
    // guaranteed. TSan-clean here proves the production sync path no longer
    // depends on the GIL for mutual exclusion.
    if (builtin.single_threaded) return error.SkipZigTest;
    const ctx = try Context.createWithTestingOptions(std.testing.allocator, .{
        .enable_threads = true,
        .enable_gc = true,
        .parallel_gc = true,
        .parallel_js = true,
    });
    defer ctx.destroy();

    const result = try ctx.evaluate(
        \\if ($vm.useThreadGIL() !== false) throw new Error("parallel_js did not drop the thread GIL");
        \\const mutex = new Atomics.Mutex();
        \\const shared = { n: 0 };
        \\const threads = [];
        \\for (let t = 0; t < 4; t++) {
        \\  threads.push(new Thread(() => {
        \\    if ($vm.useThreadGIL() !== false) throw new Error("worker still holds the thread GIL");
        \\    for (let i = 0; i < 500; i++) {
        \\      const token = Atomics.Mutex.lock(mutex);
        \\      shared.n = shared.n + 1;
        \\      token.unlock();
        \\    }
        \\    return true;
        \\  }));
        \\}
        \\for (const t of threads) {
        \\  if (t.join() !== true) throw new Error("bad worker result");
        \\}
        \\shared.n;
    );
    try std.testing.expectEqual(@as(f64, 2000), result.asNum());
}

test "parallel_js (M3): mid-script parallel collector reclaims garbage while threads run, no GIL" {
    // The mid-script parallel GC driver end to end: real JS `Thread`s allocate
    // and retain object graphs with no execution GIL while a collector elected
    // among them marks + sweeps at safepoints. Each thread keeps a private array
    // of retained objects (interpreter roots, published through the insertion
    // barrier at safepoints) and churns garbage in bursts separated by
    // non-allocating compute lulls — the lulls let the born-cell set quiesce so
    // the collector can reach a stable, abort-safe finish and sweep WHILE peers
    // still run. The retained graph must survive every collection (a swept-live
    // bug would corrupt the per-round records and fail the oracle), the run must
    // complete (no deadlock — peers never block for the collector), and at least
    // one parallel collection must actually finish. TSan-clean.
    if (builtin.single_threaded) return error.SkipZigTest;
    const ctx = try Context.createWithTestingOptions(std.testing.allocator, .{
        .enable_threads = true,
        .enable_gc = true,
        .parallel_gc = true,
        .parallel_js = true,
        .parallel_midscript_gc = true,
    });
    defer ctx.destroy();

    // Wrapped in an IIFE so re-evaluating (the retry below) doesn't redeclare a
    // top-level `const`. Each worker keeps a private array of retained objects
    // (interpreter roots, published through the insertion barrier at safepoints)
    // and churns garbage in bursts separated by non-allocating compute lulls.
    const src =
        \\(() => {
        \\  const N = 3;
        \\  const threads = [];
        \\  for (let t = 0; t < N; t++) {
        \\    threads.push(new Thread(() => {
        \\      const keep = [];
        \\      for (let round = 0; round < 6; round++) {
        \\        let last = null;
        \\        for (let i = 0; i < 500; i++) last = { a: i, b: { c: i }, d: [i, i + 1] };
        \\        keep.push({ round: round, tag: last.a });
        \\        let s = 0;
        \\        for (let j = 0; j < 6000; j++) s = (s + j) & 0x3fffffff;
        \\        if (s < 0) keep.push({ never: true });
        \\      }
        \\      // Oracle: the retained graph is intact (no live object was swept).
        \\      if (keep.length !== 6) return -1;
        \\      let sum = 0;
        \\      for (let kk = 0; kk < keep.length; kk++) {
        \\        if (keep[kk].round !== kk || keep[kk].tag !== 499) return -2;
        \\        sum += keep[kk].round;
        \\      }
        \\      return sum === 15 ? 1 : -3;
        \\    }));
        \\  }
        \\  let ok = 0;
        \\  for (const t of threads) { if (t.join() === 1) ok++; }
        \\  return ok;
        \\})();
    ;
    // Retry the workload until the elected collector reaches at least one
    // *finishing* parallel sweep (convergence depends on catching a quiescent
    // window, so it's retried for determinism). Correctness — every thread's
    // retained graph survived every collection, with no deadlock — is asserted on
    // EVERY attempt; a swept-live bug would corrupt the per-round records (a
    // negative oracle) or crash, failing immediately.
    var attempt: usize = 0;
    while (attempt < 10) : (attempt += 1) {
        const result = try ctx.evaluate(src);
        try std.testing.expectEqual(@as(f64, 3), result.asNum());
        if (ctx.gc_par_collections.load(.monotonic) > 0) break;
    }
    try std.testing.expect(ctx.gc_par_collections.load(.monotonic) > 0);
}

test "parallel_gc soak: sustained parallel allocation reclaims across rounds, no leak/UAF" {
    // GC-maturity (#2): a *sustained-load soak*. Each outer round spawns 4 GIL-free
    // workers that build and discard heavy object graphs in parallel, then join.
    // Reclamation happens at the quiescent point each round (the `evaluate` entry
    // collect + post-join collection): mid-script collection is intentionally
    // gated off *while* threads run, so this exercises the realistic current
    // model — long parallel bursts that reclaim between bursts. Oracles: (1)
    // correctness — every worker re-verifies its retained records each round, so a
    // wrongly-swept live cell (UAF) flips the result negative; (2) no leak across
    // rounds — after many rounds the live set is bounded, proving the prior
    // rounds' multi-thread garbage was reclaimed, not accumulated. Completing is
    // the no-deadlock proof. This is the leak/UAF soak the production-readiness
    // doc flagged as the remaining GC item, run under real parallel bytecode.
    if (builtin.single_threaded) return error.SkipZigTest;
    // Skip under ThreadSanitizer: the soak's oracle is heap-boundedness (leak/UAF)
    // asserted in Zig, not race detection — and its sustained allocation volume is
    // impractical at TSan's ~10–15× slowdown. The parallel race paths are covered
    // by the `tsan-parallel-js` / `tsan-threadfuzz` gates instead.
    if (builtin.sanitize_thread) return error.SkipZigTest;
    const ctx = try Context.createWithTestingOptions(std.testing.allocator, .{ .enable_gc = true, .parallel_gc = true, .enable_threads = true });
    defer ctx.destroy();

    const round_src =
        \\(function(){
        \\  function burst() {
        \\    var keep = [];
        \\    for (var r = 0; r < 30; r++) {
        \\      var last = null;
        \\      for (var i = 0; i < 300; i++) last = { a: i, b: { c: i }, d: [i, i + 1, i + 2] };
        \\      keep.push({ r: r, tag: last.a });
        \\      for (var k = 0; k < keep.length; k++) if (keep[k].r !== k || keep[k].tag !== 299) return -1;
        \\    }
        \\    return keep.length === 30 ? 1 : -2;
        \\  }
        \\  var ts = [];
        \\  for (var t = 0; t < 4; t++) ts.push(new Thread(burst));
        \\  var ok = 0;
        \\  for (const th of ts) if (th.join() === 1) ok++;
        \\  return ok;
        \\})()
    ;
    var peak_live: usize = 0;
    var round: usize = 0;
    while (round < 6) : (round += 1) {
        const v = try ctx.evaluate(round_src);
        try std.testing.expectEqual(@as(f64, 4), v.asNum()); // all 4 workers intact this round
        ctx.collectGarbage(); // quiescent collect (no threads running here)
        peak_live = @max(peak_live, ctx.gc.?.live_cells);
    }
    // No leak: across 8 rounds × 4 threads × 50 bursts × 400 graphs, a heap that
    // never reclaimed cross-round garbage would hold millions of cells. The live
    // set after the final quiescent collect must be a tiny fraction of that.
    try std.testing.expect(ctx.gc.?.live_cells < 50000);
    // And reclamation actually ran (quiescent collects each round).
    try std.testing.expect(ctx.gc.?.collections >= 6);
}

test "parallel_js (M3 GIL-removal slice): Lock.asyncHold grants serialize without context GIL" {
    // Async grants touch the same LockRecord state as sync lock/unlock, but
    // delivery happens through the realm task queue. This keeps several
    // no-GIL JS workers registering jobs while task pumps deliver and release
    // those jobs on whichever thread observes them.
    if (builtin.single_threaded) return error.SkipZigTest;
    const ctx = try Context.createWithTestingOptions(std.testing.allocator, .{
        .enable_threads = true,
        .enable_gc = true,
        .parallel_gc = true,
        .parallel_js = true,
    });
    defer ctx.destroy();

    const result = try ctx.evaluate(
        \\const lock = new Lock();
        \\const shared = { n: 0 };
        \\const threads = [];
        \\for (let t = 0; t < 4; t++) {
        \\  threads.push(new Thread(() => {
        \\    if ($vm.useThreadGIL() !== false) throw new Error("worker still holds the thread GIL");
        \\    for (let i = 0; i < 50; i++) {
        \\      lock.asyncHold(() => {
        \\        const next = shared.n + 1;
        \\        shared.n = next;
        \\        return next;
        \\      });
        \\    }
        \\    return true;
        \\  }));
        \\}
        \\for (const t of threads) {
        \\  if (t.join() !== true) throw new Error("bad worker result");
        \\}
        \\shared.n;
    );
    try std.testing.expectEqual(@as(f64, 200), result.asNum());
}

test "parallel_js (M3 GIL-removal slice): property Atomics waiters notify without context GIL" {
    // Property-mode Atomics wait/notify owns an independent waiter-table mutex.
    // With the execution-path GIL dropped, several real JS threads park on the
    // same ordinary-object property while the main thread repeatedly notifies
    // until every waiter has been counted.
    if (builtin.single_threaded) return error.SkipZigTest;
    const ctx = try Context.createWithTestingOptions(std.testing.allocator, .{
        .enable_threads = true,
        .enable_gc = true,
        .parallel_gc = true,
        .parallel_js = true,
    });
    defer ctx.destroy();

    const result = try ctx.evaluate(
        \\const cell = { lane: 0, sleep: 0 };
        \\const threads = [];
        \\for (let i = 0; i < 4; i++) {
        \\  threads.push(new Thread(() => {
        \\    if ($vm.useThreadGIL() !== false) throw new Error("worker still holds the thread GIL");
        \\    return Atomics.wait(cell, "lane", 0, 5000);
        \\  }));
        \\}
        \\let woken = 0;
        \\const deadline = Date.now() + 5000;
        \\while (woken < threads.length) {
        \\  woken += Atomics.notify(cell, "lane", threads.length - woken);
        \\  if (woken < threads.length) {
        \\    if (Date.now() > deadline) throw new Error("property waiters never parked");
        \\    Atomics.wait(cell, "sleep", 0, 1);
        \\  }
        \\}
        \\let ok = 0;
        \\for (const t of threads) {
        \\  const r = t.join();
        \\  if (r !== "ok") throw new Error("bad wait result: " + r);
        \\  ok++;
        \\}
        \\ok;
    );
    try std.testing.expectEqual(@as(f64, 4), result.asNum());
}

test "parallel_js (M3 GIL-removal slice): Condition waiters notify without context GIL" {
    // Condition waiter queues now have their own mutex. This exercises real
    // shared-realm workers parking in Condition.wait while the main thread
    // notifies under the associated Lock, with the execution-path GIL dropped.
    if (builtin.single_threaded) return error.SkipZigTest;
    const ctx = try Context.createWithTestingOptions(std.testing.allocator, .{
        .enable_threads = true,
        .enable_gc = true,
        .parallel_gc = true,
        .parallel_js = true,
    });
    defer ctx.destroy();

    const result = try ctx.evaluate(
        \\const lock = new Lock();
        \\const cond = new Condition();
        \\const box = { ready: 0, go: false, done: 0 };
        \\const threads = [];
        \\for (let i = 0; i < 4; i++) {
        \\  threads.push(new Thread(() => {
        \\    if ($vm.useThreadGIL() !== false) throw new Error("worker still holds the thread GIL");
        \\    lock.hold(() => {
        \\      Atomics.store(box, "ready", Atomics.load(box, "ready") + 1);
        \\      Atomics.notify(box, "ready");
        \\      while (!box.go) cond.wait(lock);
        \\      box.done = box.done + 1;
        \\    });
        \\    return "ok";
        \\  }));
        \\}
        \\while (Atomics.load(box, "ready") < threads.length) {
        \\  Atomics.wait(box, "ready", Atomics.load(box, "ready"), 100);
        \\}
        \\let woke = 0;
        \\lock.hold(() => {
        \\  box.go = true;
        \\  woke = cond.notifyAll();
        \\});
        \\if (woke !== threads.length) throw new Error("notifyAll count: " + woke);
        \\for (const t of threads) {
        \\  const r = t.join();
        \\  if (r !== "ok") throw new Error("bad worker result: " + r);
        \\}
        \\box.done;
    );
    try std.testing.expectEqual(@as(f64, 4), result.asNum());
}

test "enable_gc incremental: long-lived collections mutated under marking stay intact" {
    // Phase 7 / M2 end-to-end: with incremental marking driven at the engine
    // safepoints (collectMidScript), a long-lived structure that keeps growing
    // — array `push`, `Map.set`, `Set.add` — is repeatedly traced black and then
    // mutated. Every such store must shade the new element via the insertion
    // write barrier, or it would be swept while live. Heavy garbage churn forces
    // many incremental cycles in between. Exact final sizes + spot-checked values
    // prove no live element was ever wrongly freed.
    const ctx = try Context.createWith(std.testing.allocator, .{ .enable_gc = true });
    defer ctx.destroy();

    _ = try ctx.evaluate(
        \\const keep = { arr: [], map: new Map(), set: new Set() };
        \\for (let i = 0; i < 20000; i++) {
        \\  const garbage = { a: i, b: [i, i, i], c: { nested: i } }; // churn
        \\  keep.arr.push({ id: i });   // push into the (already-marked) array
        \\  keep.map.set(i, { id: i }); // entry into the (already-marked) map
        \\  keep.set.add(i);            // key into the (already-marked) set
        \\  void garbage;
        \\}
        \\if (keep.arr.length !== 20000) throw new Error("arr len " + keep.arr.length);
        \\if (keep.map.size !== 20000) throw new Error("map size " + keep.map.size);
        \\if (keep.set.size !== 20000) throw new Error("set size " + keep.set.size);
        \\if (keep.arr[12345].id !== 12345) throw new Error("arr[12345] corrupted");
        \\if (keep.map.get(9999).id !== 9999) throw new Error("map.get(9999) corrupted");
        \\if (!keep.set.has(7777)) throw new Error("set.has(7777) lost");
    );
    // Collection ran during the loop (the structure exceeded the heap threshold
    // repeatedly), exercising the barriers.
    try std.testing.expect(ctx.gc.?.collections >= 1);
}

test "enable_gc incremental: insertion write barrier keeps a reparented object alive" {
    // Phase 7 / M2: drive a collection through the incremental phases
    // (startMarking / markStep / finishMarking) with a real mutation in between,
    // and prove the engine's `Object.setOwn` store funnel fires the insertion
    // write barrier. The classic incremental hazard: a reachable-but-unmarked
    // object is reparented behind an already-marked object and dropped from its
    // original (still-white) holder; without the barrier it would be swept while
    // live. Born-grey allocation + finish-time root re-scan + this barrier make
    // it survive.
    const ctx = try Context.createWith(std.testing.allocator, .{ .enable_gc = true });
    defer ctx.destroy();
    ctx.collectGarbage(); // stabilize the post-intrinsics baseline

    const gc_saved = gc_mod.setActiveHeap(ctx.gc);
    defer _ = gc_mod.setActiveHeap(gc_saved);
    const heap = ctx.gc.?;
    const a = ctx.arena();

    // `holder` is rooted (own property of globalThis); `donor`/`child` are not
    // reachable from any root yet — they are white when marking starts.
    const holder = try gc_mod.allocObj(a);
    holder.* = .{};
    try ctx.global_object.setOwn(ctx.gpa, ctx.root_shape, "holder", Value.obj(holder));
    const donor = try gc_mod.allocObj(a);
    donor.* = .{};
    const child = try gc_mod.allocObj(a);
    child.* = .{};
    try child.setOwn(ctx.gpa, ctx.root_shape, "tag", Value.num(777));
    try donor.setOwn(ctx.gpa, ctx.root_shape, "child", Value.obj(child));

    // Snapshot roots and fully drain: globalThis → holder go black; donor and
    // child stay white (donor is unreachable from any root).
    heap.startMarking();
    _ = heap.markStep(0);

    // Mutator hides `child` behind the already-black `holder` (the barrier fires
    // inside setOwn) and lets `donor` fall away.
    try holder.setOwn(ctx.gpa, ctx.root_shape, "adopted", Value.obj(child));
    try donor.setOwn(ctx.gpa, ctx.root_shape, "child", Value.undef());

    heap.finishMarking();

    // `child` survived via the barrier and is intact; `donor` (unreachable) was
    // swept.
    const adopted = holder.getOwn("adopted") orelse return error.TestUnexpectedResult;
    try std.testing.expect(adopted.isObject());
    const tag = adopted.asObj().getOwn("tag") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(f64, 777), tag.asNum());
}

test "enable_gc concurrent (M3): a marker thread races a mutator appending into a rooted array" {
    // Phase 7 / M3, the GC half: prove the collector can mark *concurrently with
    // a live mutator* against real engine `Object` graphs — the WebKit-Riptide
    // model adapted to one GIL-serialized mutator plus a dedicated marker thread.
    // The mutator appends previously-white objects into a rooted array while the
    // marker thread is tracing; each append fires the engine's insertion write
    // barrier (handing the new cell to the marker) and the marker reads the
    // array's element storage under the same `elements_lock` the mutator takes,
    // so the only shared access is race-free. Without the barrier the appended
    // cells would be swept; without the lock/atomics the read would tear (this is
    // exactly what the `gc.zig` `traceObject` concurrent path and the `aux`
    // thread-safe scratch allocator exist to make sound — validated TSan-clean).
    if (builtin.single_threaded) return error.SkipZigTest;
    const ctx = try Context.createWith(std.testing.allocator, .{ .enable_gc = true });
    defer ctx.destroy();
    ctx.collectGarbage(); // stabilize the post-intrinsics baseline

    const gc_saved = gc_mod.setActiveHeap(ctx.gc); // arms the mutator's barrier
    defer _ = gc_mod.setActiveHeap(gc_saved);
    const heap = ctx.gc.?;
    const a = ctx.arena();

    // A rooted array (own property of globalThis) the mutator will fill.
    const holder = try gc_mod.allocObj(a);
    holder.* = .{ .is_array = true };
    try ctx.global_object.setOwn(ctx.gpa, ctx.root_shape, "holder", Value.obj(holder));

    // A pool of objects reachable from no root yet (white at mark start), each
    // tagged so we can prove it survived *intact*, not merely un-swept.
    const pool_n = 1500;
    var pool: [pool_n]*value.Object = undefined;
    for (&pool, 0..) |*slot, i| {
        const child = try gc_mod.allocObj(a);
        child.* = .{};
        try child.setOwn(ctx.gpa, ctx.root_shape, "id", Value.num(@floatFromInt(i)));
        slot.* = child;
    }
    // A guaranteed-garbage object: tagged, but never linked to any root and never
    // touched by the barrier — it must be reclaimed.
    const garbage = try gc_mod.allocObj(a);
    garbage.* = .{};
    const live_before = heap.live_cells;

    // Snapshot roots with the world stopped (single-threaded here — only globalThis
    // → holder is reachable; the pool and garbage are white), then go concurrent.
    // Precise roots only: the pool lives in a native local we deliberately do not
    // scan, so survival must come from the barrier + finish-time root rescan.
    heap.beginConcurrentMark();

    const Shared = struct {
        heap: *Context.GcHeap,
        done: std.atomic.Value(bool) = .init(false),
        fn markLoop(s: *@This()) void {
            while (true) {
                const quiescent = s.heap.concurrentMarkRound();
                if (s.done.load(.acquire) and quiescent) break;
                std.atomic.spinLoopHint();
            }
        }
    };
    var shared = Shared{ .heap = heap };
    const marker = try std.Thread.spawn(.{}, Shared.markLoop, .{&shared});

    // Mutator: append every white child into the rooted array. `appendElement`
    // holds `elements_lock` and fires the insertion barrier, exactly the engine
    // funnel — concurrent with the marker reading `holder.elements` under the
    // same lock.
    for (pool) |child| try holder.appendElement(a, Value.obj(child));
    shared.done.store(true, .release);
    marker.join();

    // World stopped again: re-scan roots (catches anything the barrier missed via
    // holder → elements) and sweep.
    heap.finishConcurrentMark();

    // Every child survived and is intact, and the array holds them all in order.
    try std.testing.expectEqual(@as(usize, pool_n), holder.elementsLen());
    for (pool, 0..) |child, i| {
        const id = child.getOwn("id") orelse return error.TestUnexpectedResult;
        try std.testing.expectEqual(@as(f64, @floatFromInt(i)), id.asNum());
    }
    // The unreferenced garbage was reclaimed — proof the concurrent mark didn't
    // simply retain everything.
    try std.testing.expect(heap.live_cells <= live_before + pool_n);
    std.mem.doNotOptimizeAway(&garbage);
}

test "enable_gc concurrent (M3): a WeakMap survives a marker racing a mutator that inserts entries" {
    // Weak-collection counterpart of the array test, validating isMarked-based
    // weak clearing: a marker thread runs while the mutator inserts 1,000
    // WeakMap entries through `weakEntrySet` (which grows `weak_entries`). The
    // marker never reads `weak_entries` during the cycle (keys are resolved by
    // `isLive` at finish, values by the ephemeron pass), so the growing buffer
    // races nothing and no interior `&entry.key` can dangle. Keys are kept
    // strongly reachable via a rooted array, so every entry (and its ephemeron
    // value) survives. This crashed before isMarked-based clearing (a realloc'd
    // weak slot dangled); it must be TSan-clean now.
    if (builtin.single_threaded) return error.SkipZigTest;
    const ctx = try Context.createWith(std.testing.allocator, .{ .enable_gc = true });
    defer ctx.destroy();
    ctx.collectGarbage();

    const gc_saved = gc_mod.setActiveHeap(ctx.gc);
    defer _ = gc_mod.setActiveHeap(gc_saved);
    const heap = ctx.gc.?;
    const a = ctx.arena();

    const wm = try gc_mod.allocObj(a);
    wm.* = .{ .is_weak = true, .is_map = true };
    try ctx.global_object.setOwn(ctx.gpa, ctx.root_shape, "wm", Value.obj(wm));
    const keep = try gc_mod.allocObj(a); // strongly holds the (otherwise weak) keys
    keep.* = .{ .is_array = true };
    try ctx.global_object.setOwn(ctx.gpa, ctx.root_shape, "keep", Value.obj(keep));

    const n = 1000;
    var keys: [n]*value.Object = undefined;
    var vals: [n]*value.Object = undefined;
    for (0..n) |i| {
        const k = try gc_mod.allocObj(a);
        k.* = .{};
        const vv = try gc_mod.allocObj(a);
        vv.* = .{};
        try vv.setOwn(ctx.gpa, ctx.root_shape, "id", Value.num(@floatFromInt(i)));
        try keep.appendElement(a, Value.obj(k));
        keys[i] = k;
        vals[i] = vv;
    }

    heap.beginConcurrentMark();
    const Shared = struct {
        heap: *Context.GcHeap,
        done: std.atomic.Value(bool) = .init(false),
        fn loop(s: *@This()) void {
            while (true) {
                const q = s.heap.concurrentMarkRound();
                if (s.done.load(.acquire) and q) break;
                std.atomic.spinLoopHint();
            }
        }
    };
    var shared = Shared{ .heap = heap };
    const marker = try std.Thread.spawn(.{}, Shared.loop, .{&shared});
    for (0..n) |i| try wm.weakEntrySet(a, @ptrCast(keys[i]), Value.obj(vals[i]));
    shared.done.store(true, .release);
    marker.join();
    heap.finishConcurrentMark();

    // Every entry present; each ephemeron value (live key) survived intact.
    try std.testing.expectEqual(@as(usize, n), wm.weak_entries.items.len);
    for (0..n) |i| {
        const got = wm.weakEntryGet(@ptrCast(keys[i])) orelse return error.TestUnexpectedResult;
        const id = got.asObj().getOwn("id") orelse return error.TestUnexpectedResult;
        try std.testing.expectEqual(@as(f64, @floatFromInt(i)), id.asNum());
    }
}

test "enable_gc: conservative native-stack scan keeps a stack-only value alive" {
    // The safety-critical direction of mid-script collection: a `Value` held
    // only as a native Zig local (the tree-walker's case) must survive a
    // collection that runs while the stack is live. The collecting thread arms
    // `gc_scan_native_stack`, so `gc.zig`'s `traceRoots` conservatively scans the
    // stack + spilled registers and marks the cell this local points at.
    if (!stack_scan.supported) return error.SkipZigTest;
    const ctx = try Context.createWith(std.testing.allocator, .{ .enable_gc = true });
    defer ctx.destroy();

    const ss = stack_scan.enter(@frameAddress());
    defer stack_scan.leave(ss);
    const gc_saved = gc_mod.setActiveHeap(ctx.gc);
    defer _ = gc_mod.setActiveHeap(gc_saved);

    // Reachable ONLY through this local — no JS root, no Context root.
    const orphan = try gc_mod.allocObj(ctx.arena());
    try orphan.setOwn(ctx.gpa, ctx.root_shape, "marker", Value.num(12345));

    // Collect with the native-stack scan armed, exactly as `collectMidScript`
    // does. A precise-only collection would sweep `orphan`; the conservative
    // scan must keep it.
    ctx.gc_scan_native_stack = true;
    ctx.gc.?.collect();
    ctx.gc_scan_native_stack = false;
    std.mem.doNotOptimizeAway(&orphan);

    // Survived and intact.
    const got = orphan.getOwn("marker") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(f64, 12345), got.asNum());

    // Control: with the scan off (the quiescent path), the now-unreferenced
    // orphan is unreachable and reclaimed — confirming it only survived above
    // because of the stack scan, not some other root.
    const live_before = ctx.gc.?.live_cells;
    std.mem.doNotOptimizeAway(&orphan); // last legitimate use; dead hereafter
    ctx.collectGarbage();
    try std.testing.expect(ctx.gc.?.live_cells < live_before);
}

test "enable_gc: active module cache roots module environments during collection" {
    const ctx = try Context.createWith(std.testing.allocator, .{ .enable_gc = true });
    defer ctx.destroy();
    ctx.collectGarbage(); // stabilize the post-intrinsics baseline

    const a = ctx.arena();
    const gc_saved = gc_mod.setActiveHeap(ctx.gc);
    defer _ = gc_mod.setActiveHeap(gc_saved);

    const env = try gc_mod.allocEnv(a);
    env.* = .{ .arena = a, .parent = &ctx.env, .fn_scope = true };

    const kept = try gc_mod.allocObj(a);
    kept.* = .{};
    try env.put("kept", Value.obj(kept));

    const garbage = try gc_mod.allocObj(a);
    garbage.* = .{};

    const m = try a.create(Context.Module);
    m.* = .{ .path = "module-root", .items = &.{}, .env = env };

    var cache: std.StringHashMapUnmanaged(*Context.Module) = .{};
    try cache.put(a, m.path, m);
    ctx.mod_cache = &cache;
    defer ctx.mod_cache = null;

    const before = ctx.gc.?.live_cells;
    ctx.collectGarbage();
    const after = ctx.gc.?.live_cells;
    try std.testing.expectEqual(before - 1, after);

    ctx.mod_cache = null;
    ctx.collectGarbage();
    try std.testing.expect(ctx.gc.?.live_cells < after);
}

test "enable_gc: evaluateModule clears transient module cache so later GC can run" {
    const ctx = try Context.createWith(std.testing.allocator, .{ .enable_gc = true });
    defer ctx.destroy();

    const Host = struct {
        fn load(_: *anyopaque, _: []const u8, _: []const u8, _: *[]const u8) ?[]const u8 {
            return null;
        }
    };
    var dummy: u8 = 0;
    const mh = Context.ModuleHost{ .ctx = &dummy, .load = Host.load };
    _ = try ctx.evaluateModule("entry.js", "export const value = { tag: 1 };", mh);
    try std.testing.expect(ctx.mod_cache == null);
    try std.testing.expect(ctx.mod_host == null);

    const before = ctx.gc.?.collections;
    ctx.collectGarbage();
    try std.testing.expect(ctx.gc.?.collections > before);
}

test "enable_gc: active module interpreter roots import.meta during requested microtask GC" {
    const ctx = try Context.createWith(std.testing.allocator, .{ .enable_gc = true });
    defer ctx.destroy();

    const Host = struct {
        fn load(_: *anyopaque, _: []const u8, _: []const u8, _: *[]const u8) ?[]const u8 {
            return null;
        }
    };
    var dummy: u8 = 0;
    const mh = Context.ModuleHost{ .ctx = &dummy, .load = Host.load };

    _ = try ctx.evaluateModule("entry.js",
        \\globalThis.ref = new WeakRef(import.meta);
        \\Promise.resolve().then(function () {
        \\  gc();
        \\  Promise.resolve().then(function () {
        \\    globalThis.aliveAfterGc = globalThis.ref.deref() !== undefined;
        \\  });
        \\});
        \\export const value = 1;
    , mh);

    const alive = try ctx.evaluate("globalThis.aliveAfterGc === true");
    try std.testing.expectEqual(true, alive.asBool());

    ctx.collectGarbage();
    const cleared = try ctx.evaluate("globalThis.ref.deref() === undefined");
    try std.testing.expectEqual(true, cleared.asBool());
}

test "enable_gc: WeakRef target clears when only weakly reachable" {
    const ctx = try Context.createWith(std.testing.allocator, .{ .enable_gc = true });
    defer ctx.destroy();

    _ = try ctx.evaluate(
        \\globalThis.ref = new WeakRef({ tag: 7 });
        \\0
    );
    ctx.collectGarbage();

    const r = try ctx.evaluate("globalThis.ref.deref() === undefined");
    try std.testing.expectEqual(true, r.asBool());
}

test "enable_gc: shell gc request runs at the evaluate-tail quiescent point" {
    const ctx = try Context.createWith(std.testing.allocator, .{ .enable_gc = true });
    defer ctx.destroy();

    const collections_before = ctx.gc.?.collections;
    _ = try ctx.evaluate(
        \\globalThis.ref = undefined;
        \\{
        \\  let target = { tag: 17 };
        \\  globalThis.ref = new WeakRef(target);
        \\  gc();
        \\  if (globalThis.ref.deref().tag !== 17) throw new Error("gc collected during live stack");
        \\}
        \\0
    );
    try std.testing.expect(!ctx.gc_requested);
    try std.testing.expect(ctx.gc.?.collections > collections_before);
}

test "$vm exposes only supported shell hooks" {
    const threaded = try Context.createWith(std.testing.allocator, .{
        .enable_threads = true,
        .enable_gc = true,
        .gil = true, // this hook check asserts the GIL-serialized mode specifically
    });
    defer threaded.destroy();

    _ = try threaded.evaluate(
        \\if (typeof $vm !== "object") throw new Error("missing $vm");
        \\if (typeof $vm.gc !== "function") throw new Error("missing $vm.gc");
        \\if (typeof $vm.edenGC !== "function") throw new Error("missing $vm.edenGC");
        \\if (typeof $vm.ensureArrayStorage !== "function") throw new Error("missing $vm.ensureArrayStorage");
        \\if (typeof $vm.indexingMode !== "function") throw new Error("missing $vm.indexingMode");
        \\if (typeof $vm.noInline !== "function") throw new Error("missing $vm.noInline");
        \\if (typeof $vm.useThreadGIL !== "function") throw new Error("missing $vm.useThreadGIL");
        \\if ($vm.useThreadGIL() !== true) throw new Error("thread GIL state");
        \\let storageProbe = [1, 2, 3];
        \\if (!$vm.indexingMode(storageProbe).includes("CopyOnWrite")) throw new Error("array indexing mode");
        \\if ($vm.ensureArrayStorage(storageProbe) !== storageProbe) throw new Error("ensureArrayStorage identity");
        \\if (!$vm.indexingMode(storageProbe).includes("ArrayStorage")) throw new Error("array storage mode");
        \\try { $vm.ensureArrayStorage({}); throw new Error("expected ensureArrayStorage TypeError"); }
        \\catch (e) { if (!(e instanceof TypeError)) throw e; }
        \\if ($vm.noInline(42) !== 42) throw new Error("noInline identity");
        \\if ("sharedHeapTest" in $vm) throw new Error("sharedHeapTest is not supported");
        \\if ("toCacheableDictionary" in $vm) throw new Error("dictionary hook is not supported");
        \\globalThis.ref = new WeakRef({ tag: 31 });
        \\$vm.gc();
        \\$vm.edenGC();
        \\if (globalThis.ref.deref().tag !== 31) throw new Error("gc ran mid-stack");
    );
    try std.testing.expect(!threaded.gc_requested);

    const gc_ctx = try Context.createWith(std.testing.allocator, .{ .enable_gc = true });
    defer gc_ctx.destroy();
    const before = gc_ctx.gc.?.collections;
    _ = try gc_ctx.evaluate(
        \\if ($vm.useThreadGIL() !== false) throw new Error("non-thread GIL state");
        \\globalThis.ref = new WeakRef({ tag: 41 });
        \\$vm.gc();
        \\if (globalThis.ref.deref().tag !== 41) throw new Error("gc ran mid-stack");
    );
    try std.testing.expect(!gc_ctx.gc_requested);
    try std.testing.expect(gc_ctx.gc.?.collections > before);
}

test "enable_gc: requested GC runs between microtasks after joined threads" {
    const ctx = try Context.createWith(std.testing.allocator, .{
        .enable_threads = true,
        .enable_gc = true,
    });
    defer ctx.destroy();

    const before = ctx.gc.?.collections;
    _ = try ctx.evaluate(
        \\const t = new Thread(() => "done");
        \\if (t.join() !== "done") throw new Error("thread did not join");
        \\globalThis.__microtaskGcCollected = false;
        \\Promise.resolve()
        \\  .then(() => {
        \\    let target = { tag: 91 };
        \\    globalThis.__microtaskGcRef = new WeakRef(target);
        \\    target = null;
        \\    gc();
        \\  })
        \\  .then(() => {
        \\    globalThis.__microtaskGcCollected =
        \\      globalThis.__microtaskGcRef.deref() === undefined;
        \\  });
        \\0
    );
    try std.testing.expect(!ctx.gc_requested);
    try std.testing.expect(ctx.gc.?.collections > before);
    const collected = try ctx.evaluate("globalThis.__microtaskGcCollected");
    try std.testing.expect(collected.isBoolean() and collected.asBool());
}

test "enable_gc: WeakRef keeps target while strongly reachable" {
    const ctx = try Context.createWith(std.testing.allocator, .{ .enable_gc = true });
    defer ctx.destroy();

    _ = try ctx.evaluate(
        \\globalThis.keep = { tag: 9 };
        \\globalThis.ref = new WeakRef(globalThis.keep);
        \\0
    );
    ctx.collectGarbage();
    const alive = try ctx.evaluate("globalThis.ref.deref().tag");
    try std.testing.expectEqual(@as(f64, 9), alive.asNum());

    _ = try ctx.evaluate("globalThis.keep = undefined; 0");
    ctx.collectGarbage();
    const cleared = try ctx.evaluate("globalThis.ref.deref() === undefined");
    try std.testing.expectEqual(true, cleared.asBool());
}

test "enable_gc: SharedArrayBuffer retain releases when wrapper is collected" {
    const ctx = try Context.createWith(std.testing.allocator, .{ .enable_gc = true });
    defer ctx.destroy();

    _ = try ctx.evaluate(
        \\globalThis.keep = new SharedArrayBuffer(16);
        \\globalThis.ref = new WeakRef(globalThis.keep);
        \\0
    );
    try std.testing.expectEqual(@as(usize, 1), ctx.sab_retains.items.items.len);

    ctx.collectGarbage();
    try std.testing.expectEqual(@as(usize, 1), ctx.sab_retains.items.items.len);
    const alive = try ctx.evaluate("globalThis.ref.deref().byteLength");
    try std.testing.expectEqual(@as(f64, 16), alive.asNum());

    _ = try ctx.evaluate("globalThis.keep = undefined; 0");
    ctx.collectGarbage();
    try std.testing.expectEqual(@as(usize, 0), ctx.sab_retains.items.items.len);
    const cleared = try ctx.evaluate("globalThis.ref.deref() === undefined");
    try std.testing.expectEqual(true, cleared.asBool());
}

test "enable_gc: ArrayBuffer bytes release when wrapper is collected" {
    const ctx = try Context.createWith(std.testing.allocator, .{ .enable_gc = true });
    defer ctx.destroy();

    const baseline = ctx.gc_array_buffer_bytes_live;
    _ = try ctx.evaluate(
        \\globalThis.keep = new ArrayBuffer(64);
        \\globalThis.ref = new WeakRef(globalThis.keep);
        \\0
    );
    try std.testing.expectEqual(baseline + 64, ctx.gc_array_buffer_bytes_live);

    ctx.collectGarbage();
    try std.testing.expectEqual(baseline + 64, ctx.gc_array_buffer_bytes_live);
    const alive = try ctx.evaluate("globalThis.ref.deref().byteLength");
    try std.testing.expectEqual(@as(f64, 64), alive.asNum());

    _ = try ctx.evaluate("globalThis.keep = undefined; 0");
    ctx.collectGarbage();
    try std.testing.expectEqual(baseline, ctx.gc_array_buffer_bytes_live);
    const cleared = try ctx.evaluate("globalThis.ref.deref() === undefined");
    try std.testing.expectEqual(true, cleared.asBool());
}

test "enable_gc: ArrayBuffer resize releases old backing bytes" {
    const ctx = try Context.createWith(std.testing.allocator, .{ .enable_gc = true });
    defer ctx.destroy();

    const baseline = ctx.gc_array_buffer_bytes_live;
    _ = try ctx.evaluate(
        \\globalThis.keep = new ArrayBuffer(16, { maxByteLength: 64 });
        \\0
    );
    try std.testing.expectEqual(baseline + 16, ctx.gc_array_buffer_bytes_live);

    _ = try ctx.evaluate("globalThis.keep.resize(32); globalThis.keep.byteLength");
    try std.testing.expectEqual(baseline + 32, ctx.gc_array_buffer_bytes_live);

    _ = try ctx.evaluate("globalThis.keep.resize(8); globalThis.keep.byteLength");
    try std.testing.expectEqual(baseline + 8, ctx.gc_array_buffer_bytes_live);

    _ = try ctx.evaluate("globalThis.keep = undefined; 0");
    ctx.collectGarbage();
    try std.testing.expectEqual(baseline, ctx.gc_array_buffer_bytes_live);
}

test "enable_gc: pending Promise reaction lists release when collected" {
    const ctx = try Context.createWith(std.testing.allocator, .{ .enable_gc = true });
    defer ctx.destroy();

    const baseline = ctx.gc_promise_reactions_live;
    _ = try ctx.evaluate(
        \\globalThis.keep = new Promise(() => {});
        \\globalThis.ref = new WeakRef(globalThis.keep);
        \\for (let i = 0; i < 20; i++) globalThis.keep.then(() => i, () => i);
        \\0
    );
    try std.testing.expect(ctx.gc_promise_reactions_live > baseline);

    ctx.collectGarbage();
    try std.testing.expect(ctx.gc_promise_reactions_live > baseline);
    const alive = try ctx.evaluate("globalThis.ref.deref() !== undefined");
    try std.testing.expectEqual(true, alive.asBool());

    _ = try ctx.evaluate("globalThis.keep = undefined; 0");
    ctx.collectGarbage();
    try std.testing.expectEqual(baseline, ctx.gc_promise_reactions_live);
    const cleared = try ctx.evaluate("globalThis.ref.deref() === undefined");
    try std.testing.expectEqual(true, cleared.asBool());
}

test "enable_gc: settling Promise releases reaction lists" {
    const ctx = try Context.createWith(std.testing.allocator, .{ .enable_gc = true });
    defer ctx.destroy();

    const baseline = ctx.gc_promise_reactions_live;
    _ = try ctx.evaluate(
        \\let resolve;
        \\const p = new Promise((r) => { resolve = r; });
        \\for (let i = 0; i < 20; i++) p.then(() => i, () => i);
        \\resolve(1);
        \\0
    );
    try std.testing.expectEqual(baseline, ctx.gc_promise_reactions_live);
}

test "enable_gc: Environment binding names release when closure environment is collected" {
    const ctx = try Context.createWith(std.testing.allocator, .{ .enable_gc = true });
    defer ctx.destroy();

    const baseline = ctx.gc_environment_name_bytes_live;
    _ = try ctx.evaluate(
        \\with ({}) {
        \\  let longLexicalBindingNameForGcEnvironment = { tag: 7 };
        \\  const anotherCapturedConstBinding = 2;
        \\  globalThis.keep = function () {
        \\    return longLexicalBindingNameForGcEnvironment.tag + anotherCapturedConstBinding;
        \\  };
        \\}
        \\globalThis.ref = new WeakRef(globalThis.keep);
        \\0
    );
    try std.testing.expect(ctx.gc_environment_name_bytes_live > baseline);

    ctx.collectGarbage();
    try std.testing.expect(ctx.gc_environment_name_bytes_live > baseline);
    const alive = try ctx.evaluate("globalThis.keep()");
    try std.testing.expectEqual(@as(f64, 9), alive.asNum());

    _ = try ctx.evaluate("globalThis.keep = undefined; 0");
    ctx.collectGarbage();
    try std.testing.expectEqual(baseline, ctx.gc_environment_name_bytes_live);
    const cleared = try ctx.evaluate("globalThis.ref.deref() === undefined");
    try std.testing.expectEqual(true, cleared.asBool());
}

test "enable_gc: Object named-property backing stores release when collected" {
    const ctx = try Context.createWith(std.testing.allocator, .{ .enable_gc = true });
    defer ctx.destroy();

    ctx.collectGarbage(); // stabilize post-intrinsics backing-store baseline
    const baseline = ctx.gc_object_backing_stores_live;
    _ = try ctx.evaluate(
        \\(() => {
        \\  const o = {};
        \\  for (let i = 0; i < 40; i++) o["prop" + i] = i;
        \\  Object.defineProperty(o, "accessor", {
        \\    get: function () { return this.prop1 + 10; },
        \\    configurable: true,
        \\    enumerable: true
        \\  });
        \\  Object.defineProperty(o, "locked", {
        \\    value: 123,
        \\    writable: false,
        \\    configurable: true,
        \\    enumerable: false
        \\  });
        \\  const arr = [1, 2, 3, 4];
        \\  delete arr[1];
        \\  o.arr = arr;
        \\  delete o.prop3;
        \\  globalThis.keep = o;
        \\  globalThis.ref = new WeakRef(o);
        \\})();
        \\0
    );
    try std.testing.expect(ctx.gc_object_backing_stores_live > baseline);

    ctx.collectGarbage();
    try std.testing.expect(ctx.gc_object_backing_stores_live > baseline);
    const alive = try ctx.evaluate("globalThis.keep.accessor + globalThis.keep.locked + (1 in globalThis.keep.arr ? 1000 : 0)");
    try std.testing.expectEqual(@as(f64, 134), alive.asNum());

    _ = try ctx.evaluate("globalThis.keep = undefined; 0");
    ctx.collectGarbage();
    const cleared = try ctx.evaluate("globalThis.ref.deref() === undefined");
    try std.testing.expectEqual(true, cleared.asBool());

    _ = try ctx.evaluate("globalThis.ref = undefined; 0");
    ctx.collectGarbage();
    ctx.collectGarbage();
    try std.testing.expectEqual(baseline, ctx.gc_object_backing_stores_live);
}

test "enable_gc parallel_gc: Object accessor backing stores release when collected" {
    const ctx = try Context.createWithTestingOptions(std.testing.allocator, .{ .enable_gc = true, .parallel_gc = true });
    defer ctx.destroy();

    ctx.collectGarbage(); // stabilize post-intrinsics backing-store baseline
    const baseline = ctx.gc_object_backing_stores_live;
    _ = try ctx.evaluate(
        \\(() => {
        \\  const keep = [];
        \\  for (let i = 0; i < 128; i++) {
        \\    const o = {};
        \\    Object.defineProperty(o, "x", {
        \\      get: function () { return i; },
        \\      configurable: true,
        \\      enumerable: true
        \\    });
        \\    Object.defineProperty(o, "y", {
        \\      set: function (v) { this.z = v; },
        \\      configurable: true
        \\    });
        \\    keep.push(o);
        \\  }
        \\  const churn = {};
        \\  for (let i = 0; i < 128; i++) {
        \\    delete churn.m;
        \\    Object.defineProperty(churn, "m", {
        \\      get: function () { return 42; },
        \\      configurable: true
        \\    });
        \\  }
        \\  keep.push(churn);
        \\  globalThis.keep = keep;
        \\})();
        \\0
    );
    try std.testing.expect(ctx.gc_object_backing_stores_live > baseline);

    _ = try ctx.evaluate("globalThis.keep = undefined; 0");
    ctx.collectGarbage();
    ctx.collectGarbage();
    try std.testing.expectEqual(baseline, ctx.gc_object_backing_stores_live);
}

test "enable_gc: weak collection and finalization record backing stores release when collected" {
    const ctx = try Context.createWith(std.testing.allocator, .{ .enable_gc = true });
    defer ctx.destroy();

    ctx.collectGarbage(); // stabilize post-intrinsics backing-store baseline
    const baseline = ctx.gc_object_backing_stores_live;
    _ = try ctx.evaluate(
        \\(() => {
        \\  const wm = new WeakMap();
        \\  const ws = new WeakSet();
        \\  const fr = new FinalizationRegistry(() => {});
        \\  const targets = [];
        \\  for (let i = 0; i < 24; i++) {
        \\    const key = { key: i };
        \\    const value = { value: i };
        \\    wm.set(key, value);
        \\    ws.add(key);
        \\    fr.register(key, "held-" + i, key);
        \\    targets.push(key, value);
        \\  }
        \\  globalThis.keep = { wm, ws, fr, targets };
        \\  globalThis.ref = new WeakRef(globalThis.keep);
        \\})();
        \\0
    );
    try std.testing.expect(ctx.gc_object_backing_stores_live > baseline);

    ctx.collectGarbage();
    try std.testing.expect(ctx.gc_object_backing_stores_live > baseline);
    const alive = try ctx.evaluate(
        \\globalThis.keep.wm.has(globalThis.keep.targets[0]) &&
        \\globalThis.keep.ws.has(globalThis.keep.targets[0])
    );
    try std.testing.expectEqual(true, alive.asBool());

    _ = try ctx.evaluate("globalThis.keep = undefined; 0");
    ctx.collectGarbage();
    const cleared = try ctx.evaluate("globalThis.ref.deref() === undefined");
    try std.testing.expectEqual(true, cleared.asBool());

    _ = try ctx.evaluate("globalThis.ref = undefined; 0");
    ctx.collectGarbage();
    try std.testing.expectEqual(baseline, ctx.gc_object_backing_stores_live);
}

test "enable_gc: dense Object elements release when collected" {
    const ctx = try Context.createWith(std.testing.allocator, .{ .enable_gc = true });
    defer ctx.destroy();

    ctx.collectGarbage(); // stabilize post-intrinsics backing-store baseline
    const baseline = ctx.gc_object_backing_stores_live;
    _ = try ctx.evaluate(
        \\(() => {
        \\  const arr = [];
        \\  for (let i = 0; i < 80; i++) arr.push({ index: i });
        \\  const map = new Map();
        \\  const set = new Set();
        \\  for (let i = 0; i < 30; i++) {
        \\    const key = { key: i };
        \\    const value = { value: i };
        \\    map.set(key, value);
        \\    set.add(value);
        \\  }
        \\  globalThis.keep = { arr, map, set };
        \\  globalThis.ref = new WeakRef(globalThis.keep);
        \\})();
        \\0
    );
    try std.testing.expect(ctx.gc_object_backing_stores_live > baseline);

    ctx.collectGarbage();
    try std.testing.expect(ctx.gc_object_backing_stores_live > baseline);
    const alive = try ctx.evaluate("globalThis.keep.arr[79].index + globalThis.keep.map.size + globalThis.keep.set.size");
    try std.testing.expectEqual(@as(f64, 139), alive.asNum());

    _ = try ctx.evaluate("globalThis.keep = undefined; 0");
    ctx.collectGarbage();
    const cleared = try ctx.evaluate("globalThis.ref.deref() === undefined");
    try std.testing.expectEqual(true, cleared.asBool());

    _ = try ctx.evaluate("globalThis.ref = undefined; 0");
    ctx.collectGarbage();
    try std.testing.expectEqual(baseline, ctx.gc_object_backing_stores_live);
}

test "enable_gc: typed-array and DataView metadata release when collected" {
    const ctx = try Context.createWith(std.testing.allocator, .{ .enable_gc = true });
    defer ctx.destroy();

    ctx.collectGarbage(); // stabilize post-intrinsics backing-store baseline
    const baseline = ctx.gc_object_backing_stores_live;
    _ = try ctx.evaluate(
        \\(() => {
        \\  const buffer = new ArrayBuffer(16, { maxByteLength: 32 });
        \\  const ta = new Uint16Array(buffer, 0, 4);
        \\  ta[0] = 513;
        \\  const sub = ta.subarray(1, 3);
        \\  const dv = new DataView(buffer);
        \\  dv.setUint8(4, 77);
        \\  const clone = structuredClone({ ta, dv });
        \\  globalThis.keep = { ta, sub, dv, clone };
        \\  globalThis.ref = new WeakRef(globalThis.keep);
        \\})();
        \\0
    );
    try std.testing.expect(ctx.gc_object_backing_stores_live > baseline);

    ctx.collectGarbage();
    try std.testing.expect(ctx.gc_object_backing_stores_live > baseline);
    const alive = try ctx.evaluate(
        \\globalThis.keep.ta[0] +
        \\globalThis.keep.sub.length +
        \\globalThis.keep.dv.getUint8(4) +
        \\globalThis.keep.clone.ta.length +
        \\globalThis.keep.clone.dv.getUint8(4)
    );
    try std.testing.expectEqual(@as(f64, 673), alive.asNum());

    _ = try ctx.evaluate("globalThis.keep = undefined; 0");
    ctx.collectGarbage();
    const cleared = try ctx.evaluate("globalThis.ref.deref() === undefined");
    try std.testing.expectEqual(true, cleared.asBool());

    _ = try ctx.evaluate("globalThis.ref = undefined; 0");
    ctx.collectGarbage();
    try std.testing.expectEqual(baseline, ctx.gc_object_backing_stores_live);
}

test "enable_gc: Temporal metadata releases when collected" {
    const ctx = try Context.createWith(std.testing.allocator, .{ .enable_gc = true });
    defer ctx.destroy();

    ctx.collectGarbage(); // stabilize post-intrinsics backing-store baseline
    const baseline = ctx.gc_object_backing_stores_live;
    _ = try ctx.evaluate(
        \\(() => {
        \\  const date = new Temporal.PlainDate(2024, 6, 15);
        \\  const duration = new Temporal.Duration(1, 2, 0, 3, 4, 5);
        \\  globalThis.keep = { date, duration };
        \\  globalThis.ref = new WeakRef(globalThis.keep);
        \\})();
        \\0
    );
    try std.testing.expect(ctx.gc_object_backing_stores_live > baseline);

    ctx.collectGarbage();
    try std.testing.expect(ctx.gc_object_backing_stores_live > baseline);
    const alive = try ctx.evaluate(
        \\globalThis.keep.date.year +
        \\globalThis.keep.date.month +
        \\globalThis.keep.date.day +
        \\globalThis.keep.duration.years +
        \\globalThis.keep.duration.months +
        \\globalThis.keep.duration.days +
        \\globalThis.keep.duration.hours +
        \\globalThis.keep.duration.minutes
    );
    try std.testing.expectEqual(@as(f64, 2060), alive.asNum());

    _ = try ctx.evaluate("globalThis.keep = undefined; 0");
    ctx.collectGarbage();
    const cleared = try ctx.evaluate("globalThis.ref.deref() === undefined");
    try std.testing.expectEqual(true, cleared.asBool());

    _ = try ctx.evaluate("globalThis.ref = undefined; 0");
    ctx.collectGarbage();
    try std.testing.expectEqual(baseline, ctx.gc_object_backing_stores_live);
}

test "enable_gc: mapped arguments parameter-map names release when collected" {
    const ctx = try Context.createWith(std.testing.allocator, .{ .enable_gc = true });
    defer ctx.destroy();

    ctx.collectGarbage(); // stabilize post-intrinsics backing-store baseline
    const baseline = ctx.gc_object_backing_stores_live;
    _ = try ctx.evaluate(
        \\function f(a, b) {
        \\  globalThis.keep = arguments;
        \\  globalThis.read = function () { return a + b; };
        \\  globalThis.ref = new WeakRef(arguments);
        \\}
        \\f(3, 4);
        \\0
    );
    try std.testing.expect(ctx.gc_object_backing_stores_live > baseline);

    ctx.collectGarbage();
    try std.testing.expect(ctx.gc_object_backing_stores_live > baseline);
    const alive = try ctx.evaluate("globalThis.keep[0] = 10; globalThis.read()");
    try std.testing.expectEqual(@as(f64, 14), alive.asNum());

    _ = try ctx.evaluate("globalThis.keep = undefined; globalThis.read = undefined; globalThis.f = undefined; 0");
    ctx.collectGarbage();
    const cleared = try ctx.evaluate("globalThis.ref.deref() === undefined");
    try std.testing.expectEqual(true, cleared.asBool());

    _ = try ctx.evaluate("globalThis.ref = undefined; 0");
    ctx.collectGarbage();
    try std.testing.expectEqual(baseline, ctx.gc_object_backing_stores_live);
}

test "enable_gc: suspended generator execution buffers release when collected" {
    const ctx = try Context.createWith(std.testing.allocator, .{ .enable_gc = true });
    defer ctx.destroy();

    ctx.collectGarbage(); // stabilize post-intrinsics backing-store baseline
    const baseline = ctx.gc_generator_backing_stores_live;
    _ = try ctx.evaluate(
        \\(() => {
        \\  function* g() {
        \\    try {
        \\      const left = 40;
        \\      const sent = yield left + 2;
        \\      yield sent + 1;
        \\    } finally {
        \\      globalThis.generatorFinallyRan = true;
        \\    }
        \\  }
        \\  const it = g();
        \\  const first = it.next();
        \\  if (first.value !== 42 || first.done) throw new Error("bad first yield");
        \\  globalThis.keep = it;
        \\  globalThis.ref = new WeakRef(it);
        \\})();
        \\0
    );
    try std.testing.expect(ctx.gc_generator_backing_stores_live > baseline);

    ctx.collectGarbage();
    try std.testing.expect(ctx.gc_generator_backing_stores_live > baseline);
    const alive = try ctx.evaluate("globalThis.keep.next(5).value");
    try std.testing.expectEqual(@as(f64, 6), alive.asNum());

    _ = try ctx.evaluate("globalThis.keep = undefined; 0");
    ctx.collectGarbage();
    const cleared = try ctx.evaluate("globalThis.ref.deref() === undefined");
    try std.testing.expectEqual(true, cleared.asBool());

    _ = try ctx.evaluate("globalThis.ref = undefined; 0");
    ctx.collectGarbage();
    try std.testing.expectEqual(baseline, ctx.gc_generator_backing_stores_live);
}

test "enable_gc: async generator request buffers release when collected" {
    const ctx = try Context.createWith(std.testing.allocator, .{ .enable_gc = true });
    defer ctx.destroy();

    ctx.collectGarbage(); // stabilize post-intrinsics backing-store baseline
    const baseline = ctx.gc_generator_backing_stores_live;
    _ = try ctx.evaluate(
        \\(() => {
        \\  async function* ag() {
        \\    await new Promise(() => {});
        \\    yield 1;
        \\  }
        \\  const it = ag();
        \\  const p1 = it.next();
        \\  const p2 = it.next();
        \\  const p3 = it.return(7);
        \\  globalThis.keep = { it, p1, p2, p3 };
        \\  globalThis.ref = new WeakRef(it);
        \\})();
        \\0
    );
    try std.testing.expect(ctx.gc_generator_backing_stores_live > baseline);

    ctx.collectGarbage();
    try std.testing.expect(ctx.gc_generator_backing_stores_live > baseline);
    const alive = try ctx.evaluate("typeof globalThis.keep.p1.then === 'function' && typeof globalThis.keep.p2.then === 'function' && typeof globalThis.keep.p3.then === 'function'");
    try std.testing.expectEqual(true, alive.asBool());

    _ = try ctx.evaluate("globalThis.keep = undefined; 0");
    ctx.collectGarbage();
    const cleared = try ctx.evaluate("globalThis.ref.deref() === undefined");
    try std.testing.expectEqual(true, cleared.asBool());

    _ = try ctx.evaluate("globalThis.ref = undefined; 0");
    ctx.collectGarbage();
    try std.testing.expectEqual(baseline, ctx.gc_generator_backing_stores_live);
}

test "enable_gc: WeakMap value is live only while weak key is live" {
    const ctx = try Context.createWith(std.testing.allocator, .{ .enable_gc = true });
    defer ctx.destroy();

    _ = try ctx.evaluate(
        \\globalThis.key = {};
        \\globalThis.valueRef = new WeakRef({ tag: 11 });
        \\globalThis.wm = new WeakMap();
        \\globalThis.wm.set(globalThis.key, globalThis.valueRef.deref());
        \\0
    );
    ctx.collectGarbage();
    const alive = try ctx.evaluate("globalThis.valueRef.deref().tag");
    try std.testing.expectEqual(@as(f64, 11), alive.asNum());

    _ = try ctx.evaluate("globalThis.key = undefined; 0");
    ctx.collectGarbage();
    const cleared = try ctx.evaluate("globalThis.valueRef.deref() === undefined");
    try std.testing.expectEqual(true, cleared.asBool());
}

test "enable_gc: WeakSet does not keep value alive" {
    const ctx = try Context.createWith(std.testing.allocator, .{ .enable_gc = true });
    defer ctx.destroy();

    _ = try ctx.evaluate(
        \\globalThis.valueRef = new WeakRef({ tag: 12 });
        \\globalThis.ws = new WeakSet();
        \\globalThis.ws.add(globalThis.valueRef.deref());
        \\0
    );
    ctx.collectGarbage();
    const cleared = try ctx.evaluate("globalThis.valueRef.deref() === undefined");
    try std.testing.expectEqual(true, cleared.asBool());
}

test "enable_gc: FinalizationRegistry cleanupSome delivers collected holdings" {
    const ctx = try Context.createWith(std.testing.allocator, .{ .enable_gc = true });
    defer ctx.destroy();

    _ = try ctx.evaluate(
        \\globalThis.cleanup = [];
        \\globalThis.registry = new FinalizationRegistry((held) => cleanup.push(held.tag));
        \\globalThis.targetRef = new WeakRef({ id: 1 });
        \\registry.register(targetRef.deref(), { tag: 21 });
        \\0
    );
    ctx.collectGarbage();
    const delivered = try ctx.evaluate(
        \\if (globalThis.cleanup.length !== 0) throw new Error("cleanup ran too early");
        \\registry.cleanupSome();
        \\globalThis.cleanup.join(",");
    );
    try std.testing.expectEqualStrings("21", delivered.asStr());

    const target_cleared = try ctx.evaluate("globalThis.targetRef.deref() === undefined");
    try std.testing.expectEqual(true, target_cleared.asBool());
}

test "enable_gc: FinalizationRegistry cleanup callback runs as a host cleanup job" {
    const ctx = try Context.createWith(std.testing.allocator, .{ .enable_gc = true });
    defer ctx.destroy();

    _ = try ctx.evaluate(
        \\globalThis.cleanup = [];
        \\globalThis.registry = new FinalizationRegistry((held) => {
        \\  cleanup.push(held);
        \\  Promise.resolve().then(() => cleanup.push("microtask"));
        \\});
        \\let target = {};
        \\registry.register(target, "auto");
        \\target = undefined;
        \\0
    );
    ctx.collectGarbage();
    _ = try ctx.evaluate("0");
    const delivered = try ctx.evaluate("globalThis.cleanup.join(',')");
    try std.testing.expectEqualStrings("auto,microtask", delivered.asStr());
}

test "enable_gc: FinalizationRegistry unregister prevents cleanup delivery" {
    const ctx = try Context.createWith(std.testing.allocator, .{ .enable_gc = true });
    defer ctx.destroy();

    _ = try ctx.evaluate(
        \\globalThis.cleanup = [];
        \\globalThis.registry = new FinalizationRegistry((held) => cleanup.push(held));
        \\globalThis.token = {};
        \\let target = {};
        \\registry.register(target, "gone", token);
        \\registry.unregister(token);
        \\target = undefined;
        \\0
    );
    ctx.collectGarbage();
    const r = try ctx.evaluate(
        \\registry.cleanupSome();
        \\globalThis.cleanup.length;
    );
    try std.testing.expectEqual(@as(f64, 0), r.asNum());
}
