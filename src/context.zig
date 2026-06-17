const std = @import("std");
const gc_mod = @import("gc.zig");
const builtin = @import("builtin");
const interp = @import("interpreter.zig");
const ast = @import("ast.zig");
const value = @import("value.zig");
const strcell = @import("strcell.zig");
const Value = value.Value;
const compiler = @import("compiler.zig");
const vm = @import("vm.zig");
const Shape = @import("shape.zig").Shape;
const Parser = @import("parser.zig").Parser;
const shared_buffer = @import("shared_buffer.zig");
const gil_mod = @import("gil.zig");
const jsthread = @import("jsthread.zig");
const stack_scan = @import("stack_scan.zig");

pub const RunError = interp.EvalError || @import("parser.zig").ParseError;

/// An isolated engine instance — the homegrown analogue of a JSC
/// `JSGlobalContextRef`. Owns an arena for all interpreter-lived allocations
/// (AST, strings, objects, boxed values) and a persistent global environment
/// so variables survive across `evaluate` calls, like a real global context.
pub const Context = struct {
    gpa: std.mem.Allocator,
    arena_state: *std.heap.ArenaAllocator,
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
    };

    /// Test/conformance-only creation knobs. These model harness flags such as
    /// `[[CanBlock]]` and the PR-249 max thread count without making them part
    /// of the stable embedder options surface.
    pub const TestingOptions = struct {
        enable_threads: bool = false,
        enable_gc: bool = false,
        /// Host-defined `[[CanBlock]]` for this VM. When false, blocking APIs
        /// throw if they would have to park; non-blocking fast paths and async
        /// APIs still work.
        main_can_block: bool = true,
        /// Test cap for live shared-realm `Thread` objects.
        max_js_threads: ?u32 = null,
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
        return createWithTestingOptions(gpa, .{
            .enable_threads = options.enable_threads,
            .enable_gc = options.enable_gc,
        });
    }

    pub fn createWithTestingOptions(gpa: std.mem.Allocator, options: TestingOptions) !*Context {
        const arena_state = try gpa.create(std.heap.ArenaAllocator);
        arena_state.* = std.heap.ArenaAllocator.init(gpa);
        errdefer {
            arena_state.deinit();
            gpa.destroy(arena_state);
        }
        const a = arena_state.allocator();

        const self = try gpa.create(Context);
        self.* = .{
            .gpa = gpa,
            .arena_state = arena_state,
            .owner_thread = std.Thread.getCurrentId(),
            .sab_retains = .{ .gpa = gpa },
            .env = .{ .arena = a, .fn_scope = true }, // global is a variable scope
            .global_object = undefined, // set below, once the heap exists
            .root_shape = try Shape.createRoot(a),
            .tdz_marker = undefined, // set below
            .main_can_block = options.main_can_block,
            .max_js_threads = options.max_js_threads,
        };
        if (options.enable_gc) {
            // GC cells are gpa-backed (the collector frees them individually);
            // the binding wraps this Context, whose roots it traces.
            const bind = try gpa.create(GcBinding);
            bind.* = .{ .context = self };
            const h = try gpa.create(GcHeap);
            h.* = GcHeap.init(gpa, bind);
            self.gc = h;
            self.gc_binding = bind;
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
            .print_buffer = &self.print_buffer,
            .tdz_marker = self.tdz_marker,
            .sab_retains = &self.sab_retains,
            .async_waiters = &self.async_waiters,
            .finalization_cleanup_jobs = &self.finalization_cleanup_jobs,
            .stop_flag = self.stop_flag orelse &self.teardown_stop,
            .main_can_block = self.main_can_block,
            .gil = self.gil,
            .gc = self.gc,
            .gc_backing = if (self.gc != null) self.gpa else null,
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
            g.acquire();
            for (self.js_threads.items) |rec| {
                while (!rec.done) g.wait(&rec.done_cond);
            }
            g.release();
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
        if (self.gc) |h| {
            h.deinit();
            self.gpa.destroy(h);
            self.gc = null;
        }
        if (self.gc_binding) |b| {
            self.gpa.destroy(b);
            self.gc_binding = null;
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
        return self.arena_state.allocator();
    }

    fn serviceRequestedGcCheckpoint(ctx: *anyopaque) void {
        const self: *Context = @ptrCast(@alignCast(ctx));
        self.collectRequestedGarbage();
    }

    fn hasRunningJsThreads(self: *const Context) bool {
        for (self.js_threads.items) |rec| {
            if (!rec.done) return true;
        }
        return false;
    }

    pub fn pushActiveInterpreter(self: *Context, machine: *interp.Interpreter) !void {
        try self.active_interpreters.append(self.gpa, machine);
    }

    pub fn popActiveInterpreter(self: *Context, machine: *interp.Interpreter) void {
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
        if (self.hasRunningJsThreads()) {
            const g = self.gil orelse return;
            if (!g.holds() or !stack_scan.supported or !g.allOthersParked()) return;
            self.gc_scan_native_stack = true;
            defer self.gc_scan_native_stack = false;
            h.collect();
            self.gc_requested = false;
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

    fn collectMidScript(raw_ctx: *anyopaque) void {
        const self: *Context = @ptrCast(@alignCast(raw_ctx));
        const h = self.gc orelse return;
        if (!stack_scan.supported) return;
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
        if (h.marking) {
            // Drain a bounded slice of the grey set; when it empties, close the
            // cycle (re-scan roots under the GIL, then sweep).
            if (h.markStep(mark_budget)) h.finishMarking();
        } else if (h.bytes_live >= h.threshold_bytes) {
            // Begin an incremental cycle: snapshot roots, then let the mutator
            // run between safepoints with the barrier shading its stores.
            h.startMarking();
        }
    }

    pub fn queueFinalizationRegistryCleanup(self: *Context, registry: *value.Object) void {
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
        if (self.gil) |g| g.acquire();
        defer if (self.gil) |g| g.release();
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
        // Quiescent point: reclaim garbage from prior evaluations on this
        // context before running (nothing is executing yet, so the Context
        // roots are complete).
        self.collectGarbage();
        self.collectRequestedGarbage();
        const a = self.arena();
        const owned_source = try a.dupe(u8, source);
        var parser = try Parser.init(a, owned_source);
        const prog = try parser.parseProgram();
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
            machine.drainMicrotasks() catch {};
            machine.settleAsyncWaiters();
            machine.drainFinalizationCleanupJobs() catch {};
            machine.drainMicrotasks() catch {};
            machine.settleAsyncWaiters();
            if (top_level_failed) self.teardown_stop.store(false, .release);
        }

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
        linked: bool = false,
        evaluated: bool = false,
    };

    /// Load, link, and evaluate a module graph rooted at `entry_path`. The
    /// completion is the entry module having run; an uncaught throw leaves the
    /// reason in `self.exception` and returns `error.Throw`.
    pub fn evaluateModule(self: *Context, entry_path: []const u8, entry_source: []const u8, host: ModuleHost) RunError!value.Value {
        if (self.gil) |g| g.acquire();
        defer if (self.gil) |g| g.release();
        self.assertOwnerThread();
        const gc_saved = gc_mod.setActiveHeap(self.gc);
        defer _ = gc_mod.setActiveHeap(gc_saved);
        const sa_saved = strcell.setActiveArena(self.arena());
        defer _ = strcell.setActiveArena(sa_saved);
        // See `evaluate`: register the native-stack scan boundary for mid-script
        // collection during module execution.
        const ss_saved = stack_scan.enter(@frameAddress());
        defer stack_scan.leave(ss_saved);
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
                    _ = try self.loadDep(m, imp.specifier, host, cache);
            },
            .export_decl => |e| {
                if (e.from.len > 0) _ = try self.loadDep(m, e.from, host, cache);
                try self.collectExports(m, e);
            },
            else => {},
        };
        return m;
    }

    /// Resolve `specifier` against module `m`, load it, and record it in `m.deps`.
    fn loadDep(self: *Context, m: *Module, specifier: []const u8, host: ModuleHost, cache: *std.StringHashMapUnmanaged(*Module)) RunError!*Module {
        if (m.deps.get(specifier)) |d| return d;
        var dep_path: []const u8 = "";
        const dep_src = host.load(host.ctx, m.path, specifier, &dep_path) orelse
            return self.moduleError("Cannot resolve module specifier");
        const dep = try self.loadModule(dep_path, dep_src, host, cache);
        try m.deps.put(self.arena(), specifier, dep);
        return dep;
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

    /// Resolve an export `name` of `module` to a concrete `(env, local)` binding,
    /// chasing re-exports and `export *` sources. Returns null if not found.
    fn resolveExport(module: *Module, name: []const u8, depth: u32) ?interp.Environment.Alias {
        if (depth > 64) return null;
        if (module.exports.get(name)) |kind| switch (kind) {
            .local => |local| return .{ .env = module.env, .name = local },
            .indirect => |ind| {
                if (std.mem.eql(u8, ind.name, "*namespace*")) return null; // namespace handled separately
                return resolveExport(ind.module, ind.name, depth + 1);
            },
        };
        // `export *` sources: a name not directly exported may come from one.
        for (module.star_sources.items) |src| {
            if (resolveExport(src, name, depth + 1)) |r| return r;
        }
        return null;
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

        for (m.items) |item| switch (item.*) {
            .import_decl => |imp| {
                const dep = if (m.deps.get(imp.specifier)) |d| d else null;
                for (imp.entries) |entry| {
                    if (isSourceImport(entry)) {
                        try m.env.putConst(entry.local, Value.obj(try self.newModuleSourceObject()));
                    } else if (std.mem.eql(u8, entry.imported, "*")) {
                        try m.env.putConst(entry.local, Value.obj(try self.namespaceObject(dep.?)));
                    } else if (resolveExport(dep.?, entry.imported, 0)) |res| {
                        try m.env.putAlias(entry.local, res.env, res.name);
                    } else {
                        return self.moduleError("does not provide an export");
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
        if (m.evaluated) return;
        m.evaluated = true;
        for (m.items) |item| switch (item.*) {
            .import_decl => |imp| {
                const source_only = imp.entries.len == 1 and isSourceImport(imp.entries[0]);
                if (!source_only or !isHostModuleSourceSpecifier(imp.specifier))
                    try self.evalModule(machine, m.deps.get(imp.specifier).?);
            },
            .export_decl => |e| if (e.from.len > 0) try self.evalModule(machine, m.deps.get(e.from).?),
            else => {},
        };

        const saved_env = machine.env;
        const saved_this = machine.this_value;
        const saved_mod = machine.cur_module;
        machine.env = m.env;
        machine.this_value = Value.undef(); // module top-level `this` is undefined
        machine.cur_module = m.path; // referrer for runtime import()
        defer {
            machine.env = saved_env;
            machine.this_value = saved_this;
            machine.cur_module = saved_mod;
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

    /// Runtime `import(specifier)` driver (wired into the interpreter as
    /// `dyn_import`): resolve the specifier relative to `referrer`, then load,
    /// link, and evaluate the target module, writing its namespace into `out`.
    /// Returns false (leaving the reason in `machine.exception`) on any failure,
    /// so the caller rejects the dynamic-import promise.
    fn dynImportHook(ctx: *anyopaque, machine: *interp.Interpreter, referrer: []const u8, specifier: []const u8, out: *value.Value) bool {
        const self: *Context = @ptrCast(@alignCast(ctx));
        const host = self.mod_host orelse return self.dynImportFail(machine, "dynamic import is not available");
        const cache = self.mod_cache orelse return self.dynImportFail(machine, "dynamic import is not available");
        var dep_path: []const u8 = "";
        const src = host.load(host.ctx, referrer, specifier, &dep_path) orelse
            return self.dynImportFail(machine, "Cannot resolve module specifier");
        const dep = self.loadModule(dep_path, src, host, cache) catch return self.surfaceFail(machine);
        self.linkModule(dep) catch return self.surfaceFail(machine);
        self.evalModule(machine, dep) catch return self.surfaceFail(machine);
        const ns = self.namespaceObject(dep) catch return self.surfaceFail(machine);
        self.fillNamespace(machine, dep, ns) catch return self.surfaceFail(machine);
        out.* = Value.obj(ns);
        return true;
    }

    fn dynImportFail(self: *Context, machine: *interp.Interpreter, msg: []const u8) bool {
        _ = self;
        machine.throwError("TypeError", msg) catch {};
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
            if (resolveExport(module, e.key_ptr.*, 0)) |res| try add(a, &names, &envs, &locals, &ambiguous, e.key_ptr.*, res);
        }
        for (module.star_sources.items) |src| {
            var sit = src.exports.iterator();
            while (sit.next()) |e| {
                const name = e.key_ptr.*;
                if (std.mem.eql(u8, name, "default")) continue;
                if (module.exports.contains(name)) continue;
                if (resolveExport(src, name, 0)) |res| try add(a, &names, &envs, &locals, &ambiguous, name, res);
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

test "generators: BigInt literal yields feed BigInt typed arrays" {
    try std.testing.expect((try evalIn(
        \\function* g() { yield 7n; yield 42n; }
        \\var ta = new BigInt64Array(g());
        \\ta.length === 2 && ta[0] === 7n && ta[1] === 42n;
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

test "enable_gc: shell gc request is deferred to the next quiescent entry" {
    const ctx = try Context.createWith(std.testing.allocator, .{ .enable_gc = true });
    defer ctx.destroy();

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
    try std.testing.expect(ctx.gc_requested);
    const collections_before = ctx.gc.?.collections;

    _ = try ctx.evaluate("0");
    try std.testing.expect(!ctx.gc_requested);
    try std.testing.expect(ctx.gc.?.collections > collections_before);
}

test "$vm exposes only supported shell hooks" {
    const threaded = try Context.createWith(std.testing.allocator, .{
        .enable_threads = true,
        .enable_gc = true,
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
    try std.testing.expect(threaded.gc_requested);

    const gc_ctx = try Context.createWith(std.testing.allocator, .{ .enable_gc = true });
    defer gc_ctx.destroy();
    _ = try gc_ctx.evaluate(
        \\if ($vm.useThreadGIL() !== false) throw new Error("non-thread GIL state");
        \\globalThis.ref = new WeakRef({ tag: 41 });
        \\$vm.gc();
        \\if (globalThis.ref.deref().tag !== 41) throw new Error("gc ran mid-stack");
    );
    try std.testing.expect(gc_ctx.gc_requested);
    const before = gc_ctx.gc.?.collections;
    _ = try gc_ctx.evaluate("0");
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
