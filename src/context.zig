const std = @import("std");
const gc_mod = @import("gc.zig");
const builtin = @import("builtin");
const interp = @import("interpreter.zig");
const ast = @import("ast.zig");
const value = @import("value.zig");
const compiler = @import("compiler.zig");
const vm = @import("vm.zig");
const Shape = @import("shape.zig").Shape;
const Parser = @import("parser.zig").Parser;
const shared_buffer = @import("shared_buffer.zig");
const gil_mod = @import("gil.zig");
const jsthread = @import("jsthread.zig");

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
    /// Cooperative termination for worker contexts: the owning Worker's stop
    /// word, polled at the engines' step checkpoints (src/worker.zig).
    stop_flag: ?*const std.atomic.Value(bool) = null,
    /// Phase 6: the VM lock for shared-Context `Thread` objects (heap-
    /// allocated so its address is stable; null = the context stays
    /// single-thread-affine and pays nothing).
    gil: ?*gil_mod.Gil = null,
    /// Phase 7: the precise tracing GC heap (null = arena engine, today's
    /// default). When set, heap cells allocate through it and are reclaimed by
    /// collection / freed at `destroy`. See docs/threads/P7-gc-design.md.
    gc: ?*GcHeap = null,
    /// The heap's root-tracing binding (wraps this Context); freed in `destroy`.
    gc_binding: ?*GcBinding = null,
    /// C-API `Boxed` handles (`JSValueRef`s) that must survive collection — the
    /// embedder may hold them across calls. Each `box()` registers its `Boxed`
    /// here when the GC is on (`*Boxed` aliases `*Value`, its first field);
    /// `gc.zig`'s `traceRoots` marks them. Off-GC contexts never touch it.
    c_api_handles: std.ArrayListUnmanaged(*anyopaque) = .empty,
    /// `Thread` records spawned in this realm (the records live in the
    /// arena; the list is gpa-backed). `destroy` waits for all of them.
    js_threads: std.ArrayListUnmanaged(*jsthread.ThreadRecord) = .empty,
    /// TDZ sentinel for uninitialized let/const bindings.
    tdz_marker: *value.Object,
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

    /// The engine's precise-GC heap type and its root-tracing binding (issue #1
    /// Phase 7). Held by pointer so addresses are stable; `null` costs nothing
    /// when the GC is off.
    pub const GcHeap = @import("gc.zig").Heap;
    pub const GcBinding = @import("gc.zig").Binding;

    pub fn create(gpa: std.mem.Allocator) !*Context {
        return createWith(gpa, .{});
    }

    pub fn createWith(gpa: std.mem.Allocator, options: Options) !*Context {
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
        try self.env.put("globalThis", .{ .object = global_obj });
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
            if (d == .object) try d.object.setOwn(a, self.root_shape, "global", .{ .object = global_obj });
        }
        if (options.enable_threads) {
            const g = try gpa.create(gil_mod.Gil);
            g.* = .{};
            self.gil = g;
            g.acquire();
            defer g.release();
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
            .this_value = .{ .object = self.global_object },
            .root_shape = self.root_shape,
            .microtasks = &self.microtasks,
            .print_buffer = &self.print_buffer,
            .tdz_marker = self.tdz_marker,
            .sab_retains = &self.sab_retains,
            .async_waiters = &self.async_waiters,
            .stop_flag = self.stop_flag,
            .gil = self.gil,
            .gc = self.gc,
        };
    }

    pub fn destroy(self: *Context) void {
        if (self.gil) |g| {
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
            jsthread.abandonPropAsync(@ptrCast(g));
            self.gpa.destroy(g);
            self.gil = null;
        } else {
            self.assertOwnerThread();
        }
        self.js_threads.deinit(self.gpa);
        self.c_api_handles.deinit(self.gpa);
        self.sab_retains.deinit();
        // Reclaim every GC cell (running finalizers) before the arena and the
        // Context itself go away — GC cells are gpa-backed and disjoint from the
        // arena, so this is independent of `arena_state.deinit()`.
        if (self.gc) |h| {
            h.deinit();
            self.gpa.destroy(h);
            self.gc = null;
        }
        if (self.gc_binding) |b| {
            self.gpa.destroy(b);
            self.gc_binding = null;
        }
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

    /// Lex + parse + run `source`, returning the completion value. On an
    /// uncaught JS exception this returns `error.Throw` and leaves the thrown
    /// value in `self.exception` for the caller (e.g. the C-API boundary).
    ///
    /// Fast path: compile to bytecode and run on the VM. Programs that use
    /// constructs the compiler doesn't lower yet fall back to the tree-walker,
    /// so behavior is identical either way — the VM just handles the hot subset.
    /// Run a precise mark-sweep over the GC heap (Phase 7). **Only sound at a
    /// quiescent point** — no JS executing on this thread, so every live object
    /// is reachable from the `Context` roots `gc.zig`'s binding traces (the
    /// interpreter recursion that would hold live `Value`s as Zig locals has
    /// unwound). Conservatively skipped while threads or a module graph hold
    /// objects the root set does not yet enumerate. No-op when the GC is off.
    pub fn collectGarbage(self: *Context) void {
        const h = self.gc orelse return;
        if (self.js_threads.items.len != 0) return; // thread fns not yet rooted
        if (self.mod_cache != null) return; // module graph not yet rooted
        h.collect();
    }

    pub fn evaluate(self: *Context, source: []const u8) RunError!value.Value {
        if (self.gil) |g| g.acquire();
        defer if (self.gil) |g| g.release();
        self.assertOwnerThread();
        const gc_saved = gc_mod.setActiveHeap(self.gc);
        defer _ = gc_mod.setActiveHeap(gc_saved);
        // Quiescent point: reclaim garbage from prior evaluations on this
        // context before running (nothing is executing yet, so the Context
        // roots are complete).
        self.collectGarbage();
        const a = self.arena();
        const owned_source = try a.dupe(u8, source);
        var parser = try Parser.init(a, owned_source);
        const prog = try parser.parseProgram();
        var machine = self.interpreter();
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

        // Microtask checkpoint: run queued Promise reactions before returning, so
        // settled `.then`/`await` continuations and the async harness's `$DONE`
        // have executed by the time `evaluate` returns. Then the waitAsync
        // tail: block for outstanding async waiters (notify/deadline), resolve
        // them, and drain again until quiescent.
        machine.drainMicrotasks() catch {};
        machine.settleAsyncWaiters();
        // Shell keepalive (threads mode): a pending Thread completion is a
        // pending settlement — the realm stays alive until every spawned
        // thread finishes (each drains its own queue and settles its
        // asyncJoins), then drains whatever those settlements queued here.
        if (self.gil) |g| {
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
        var cache: std.StringHashMapUnmanaged(*Module) = .{};
        const root = try self.loadModule(entry_path, entry_source, host, &cache);
        try self.linkModule(root);
        var machine = self.interpreter();
        machine.strict = true;
        // Expose the graph to runtime dynamic `import()`.
        self.mod_host = host;
        self.mod_cache = &cache;
        machine.dyn_import = dynImportHook;
        machine.dyn_import_ctx = self;
        // Populate any namespace objects after the whole graph has evaluated, so
        // every exported binding holds its final value.
        const outcome = self.evalModule(&machine, root);
        machine.drainMicrotasks() catch {};
        machine.settleAsyncWaiters();
        outcome catch |err| {
            if (err == error.Throw) self.exception = machine.exception;
            return err;
        };
        return .undefined;
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

        const env = try a.create(interp.Environment);
        // A module environment is a variable scope whose parent is the global
        // scope (so globals resolve), but its own declarations stay module-local.
        env.* = .{ .arena = a, .parent = &self.env, .fn_scope = true };

        const m = try a.create(Module);
        m.* = .{ .path = try a.dupe(u8, path), .items = items, .env = env };
        try cache.put(a, m.path, m);

        // Load every dependency and record this module's export map.
        for (items) |item| switch (item.*) {
            .import_decl => |imp| {
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

    /// Record the export names introduced by one `export` declaration.
    fn collectExports(self: *Context, m: *Module, e: *ast.ExportNode) RunError!void {
        const a = self.arena();
        if (e.declaration) |d| {
            try declaredExportNames(self, m, d);
        }
        if (e.default_expr != null) {
            try m.exports.put(a, "default", .{ .local = "*default*" });
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
                try m.exports.put(a, e.star_as, .{ .indirect = .{ .module = dep, .name = "*namespace*" } });
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
        // Link dependencies first.
        var dit = m.deps.valueIterator();
        while (dit.next()) |dep| try self.linkModule(dep.*);

        for (m.items) |item| switch (item.*) {
            .import_decl => |imp| {
                const dep = m.deps.get(imp.specifier).?;
                for (imp.entries) |entry| {
                    if (std.mem.eql(u8, entry.imported, "*")) {
                        try m.env.put(entry.local, .{ .object = try self.namespaceObject(dep) });
                    } else if (resolveExport(dep, entry.imported, 0)) |res| {
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
                    _ = try self.namespaceObject(dep);
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
        const tdz = value.Value{ .object = self.tdz_marker };
        switch (item.*) {
            .var_decl => |v| if (v.kind != .@"var") m.env.put(v.name, tdz) catch {},
            .decl_group => |g| for (g) |s| self.instantiateLexical(m, s),
            .export_decl => |e| if (e.declaration) |d| self.instantiateLexical(m, d),
            else => {},
        }
    }

    /// Evaluate a module (and its not-yet-evaluated dependencies first), running
    /// its top-level items in its own environment with `this === undefined`.
    fn evalModule(self: *Context, machine: *interp.Interpreter, m: *Module) interp.EvalError!void {
        if (m.evaluated) return;
        m.evaluated = true;
        var dit = m.deps.valueIterator();
        while (dit.next()) |dep| try self.evalModule(machine, dep.*);

        const saved_env = machine.env;
        const saved_this = machine.this_value;
        const saved_mod = machine.cur_module;
        machine.env = m.env;
        machine.this_value = .undefined; // module top-level `this` is undefined
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
        out.* = .{ .object = ns };
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
        const fnobj = machine.active_native orelse return .undefined;
        const b: *NsBinding = @ptrCast(@alignCast(fnobj.private_data.?));
        return b.env.get(b.name) orelse .undefined;
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
        const add = struct {
            fn f(aa: std.mem.Allocator, nm: *std.ArrayListUnmanaged([]const u8), ev: *std.ArrayListUnmanaged(*interp.Environment), lo: *std.ArrayListUnmanaged([]const u8), name: []const u8, res: interp.Environment.Alias) !void {
                for (nm.items) |existing| if (std.mem.eql(u8, existing, name)) return; // de-dup
                try nm.append(aa, name);
                try ev.append(aa, res.env);
                try lo.append(aa, res.name);
            }
        }.f;
        var it = module.exports.iterator();
        while (it.next()) |e| {
            if (resolveExport(module, e.key_ptr.*, 0)) |res| try add(a, &names, &envs, &locals, e.key_ptr.*, res);
        }
        for (module.star_sources.items) |src| {
            var sit = src.exports.iterator();
            while (sit.next()) |e| {
                const name = e.key_ptr.*;
                if (std.mem.eql(u8, name, "default")) continue;
                if (resolveExport(src, name, 0)) |res| try add(a, &names, &envs, &locals, name, res);
            }
        }
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
        const modns = try a.create(interp.ModuleNs);
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

test "Date basics" {
    // Components constructor (month is 0-based) + UTC getters.
    try std.testing.expectEqual(@as(f64, 2020), (try evalIn("new Date(2020, 0, 15).getUTCFullYear()")).number);
    try std.testing.expectEqual(@as(f64, 0), (try evalIn("new Date(2020, 0, 15).getUTCMonth()")).number);
    try std.testing.expectEqual(@as(f64, 15), (try evalIn("new Date(2020, 0, 15).getUTCDate()")).number);
    // Epoch round-trips.
    try std.testing.expectEqual(@as(f64, 0), (try evalIn("new Date(0).getTime()")).number);
    try std.testing.expectEqual(@as(f64, 1970), (try evalIn("new Date(0).getUTCFullYear()")).number);
    try expectEvalStr("number", "typeof Date.now()");
    try expectEvalStr("1970-01-01T00:00:00.000Z", "new Date(0).toISOString()");
    try std.testing.expect((try evalIn("typeof new Date() === 'object'")).boolean);
}

test "String generics + .constructor + match/search" {
    // String.prototype method on a non-string this (coerced).
    try expectEvalStr("123", "String.prototype.trim.call(123)");
    try std.testing.expectEqual(@as(f64, 2), (try evalIn("String.prototype.indexOf.call(12345, '3')")).number);
    // .constructor falls back to the kind's global.
    try std.testing.expect((try evalIn("[].constructor === Array")).boolean);
    try std.testing.expect((try evalIn("({}).constructor === Object")).boolean);
    try std.testing.expect((try evalIn("'x'.constructor === String")).boolean);
    try std.testing.expect((try evalIn("(5).constructor === Number")).boolean);
    // search / match.
    try std.testing.expectEqual(@as(f64, 2), (try evalIn("'abcd'.search(/cd/)")).number);
    try std.testing.expect((try evalIn("'hello'.match(/l+/)[0] === 'll'")).boolean);
    try expectEvalStr("abc", "'abc'.normalize()");
}

test "Array.prototype generics on array-likes" {
    try std.testing.expectEqual(@as(f64, 6), (try evalIn(
        \\var o = { length: 3, 0: 1, 1: 2, 2: 3 };
        \\Array.prototype.reduce.call(o, function (a, b) { return a + b; }, 0)
    )).number);
    try std.testing.expectEqual(@as(f64, 1), (try evalIn(
        \\var o = { length: 3, 0: 'a', 1: 'b', 2: 'c' };
        \\Array.prototype.indexOf.call(o, 'b')
    )).number);
    try expectEvalStr("a-b-c",
        \\var o = { length: 3, 0: 'a', 1: 'b', 2: 'c' };
        \\Array.prototype.join.call(o, '-')
    );
    try std.testing.expect((try evalIn(
        \\var o = { length: 2, 0: 10, 1: 20 };
        \\Array.prototype.every.call(o, function (x) { return x >= 10; })
    )).boolean);
}

test "array instances inherit from Array.prototype (incl. holes)" {
    try std.testing.expect((try evalIn("Object.getPrototypeOf([]) === Array.prototype")).boolean);
    try std.testing.expect((try evalIn("[].map === Array.prototype.map")).boolean);
    // A hole reads through the prototype chain (inherited index), so an
    // accessor installed on Array.prototype is seen by index access + iteration.
    try std.testing.expectEqual(@as(f64, 11), (try evalIn(
        \\Object.defineProperty(Array.prototype, "0", { get: function () { return 11; }, configurable: true });
        \\[, , ,][0]
    )).number);
    try std.testing.expect((try evalIn(
        \\Object.defineProperty(Array.prototype, "0", { get: function () { return 11; }, configurable: true });
        \\var r = false; [, , ,].forEach(function (v, i) { if (i === 0) r = (v === 11); }); r
    )).boolean);
    // Ordinary arrays are unaffected: a real hole with no inherited index is undefined.
    try std.testing.expect((try evalIn("[1, , 3][1] === undefined")).boolean);
    try std.testing.expectEqual(@as(f64, 2), (try evalIn("[1, 2, 3][1]")).number);
}

test "Array / Object constructors" {
    try std.testing.expectEqual(@as(f64, 3), (try evalIn("new Array(3).length")).number);
    try std.testing.expectEqual(@as(f64, 2), (try evalIn("Array(1, 2).length")).number);
    try std.testing.expectEqual(@as(f64, 7), (try evalIn("var a = new Array(5, 6, 7); a[2]")).number);
    try expectEvalStr("function", "typeof Array");
    try std.testing.expect((try evalIn("var o = new Object(); typeof o === 'object'")).boolean);
    try std.testing.expect((try evalIn("var x = {}; Object(x) === x")).boolean);
    // Invalid array length throws RangeError.
    try std.testing.expect((try evalIn("var t = false; try { new Array(-1); } catch (e) { t = e.name === 'RangeError'; } t")).boolean);
}

test "destructuring catch parameter" {
    try std.testing.expectEqual(@as(f64, 3), (try evalIn(
        \\var r = 0;
        \\try { throw { a: 1, b: 2 }; } catch ({ a, b }) { r = a + b; }
        \\r
    )).number);
    try std.testing.expectEqual(@as(f64, 30), (try evalIn(
        \\var r = 0;
        \\try { throw [10, 20]; } catch ([x, y]) { r = x + y; }
        \\r
    )).number);
}

test "Array.from with iterables + map fn" {
    try std.testing.expectEqual(@as(f64, 6), (try evalIn(
        \\function* g() { yield 1; yield 2; yield 3; }
        \\Array.from(g()).length + 3
    )).number);
    try std.testing.expectEqual(@as(f64, 12), (try evalIn("Array.from([1,2,3], function(x){return x*2;}).reduce(function(a,b){return a+b;},0)")).number);
    try std.testing.expectEqual(@as(f64, 3), (try evalIn("Array.from('abc').length")).number);
    try std.testing.expectEqual(@as(f64, 2), (try evalIn("Array.from({length: 2}).length")).number);
}

test "spread of iterables (generator, string, user iterator)" {
    try std.testing.expectEqual(@as(f64, 6), (try evalIn(
        \\function* g() { yield 1; yield 2; yield 3; }
        \\var a = [...g()]; a[0] + a[1] + a[2]
    )).number);
    try std.testing.expectEqual(@as(f64, 3), (try evalIn("[...'abc'].length")).number);
    // Spread feeding a call.
    try std.testing.expectEqual(@as(f64, 6), (try evalIn(
        \\function add(a, b, c) { return a + b + c; }
        \\add(...[1, 2, 3])
    )).number);
}

test "Symbol: typeof, identity, description, property keys, iterator" {
    try expectEvalStr("symbol", "typeof Symbol()");
    try std.testing.expect((try evalIn("var s = Symbol(); s === s && Symbol() !== Symbol()")).boolean);
    try expectEvalStr("d", "Symbol('d').description");
    try expectEvalStr("symbol", "typeof Symbol.iterator");
    // Symbol-keyed property: works, but invisible to string enumeration.
    try std.testing.expectEqual(@as(f64, 5), (try evalIn(
        \\var s = Symbol(); var o = { a: 1 }; o[s] = 5;
        \\o[s]
    )).number);
    try std.testing.expectEqual(@as(f64, 1), (try evalIn(
        \\var s = Symbol(); var o = { a: 1 }; o[s] = 5;
        \\Object.keys(o).length
    )).number);
    // User iterator via Symbol.iterator drives for-of.
    try std.testing.expectEqual(@as(f64, 3), (try evalIn(
        \\var obj = {};
        \\obj[Symbol.iterator] = function () {
        \\  var i = 0;
        \\  return { next: function () { return i < 3 ? { value: i++, done: false } : { value: undefined, done: true }; } };
        \\};
        \\var s = 0; for (var x of obj) { s += x; } s
    )).number);
}

test "array literal elision (holes)" {
    try std.testing.expectEqual(@as(f64, 3), (try evalIn("var a = [1, , 3]; a.length")).number);
    try std.testing.expectEqual(@as(f64, 4), (try evalIn("var a = [, , 4]; a[2]")).number);
    // Elision in array destructuring assignment.
    try std.testing.expectEqual(@as(f64, 2), (try evalIn("var a, b; [, a, , b] = [1, 2, 3, 4]; a")).number);
    try std.testing.expectEqual(@as(f64, 4), (try evalIn("var a, b; [, a, , b] = [1, 2, 3, 4]; b")).number);
}

test "new.target" {
    // undefined in a plain call, the constructor under `new`.
    try std.testing.expect((try evalIn(
        \\function F() { return new.target === F; }
        \\F() === false && new F() instanceof F
    )).boolean);
    try std.testing.expectEqual(@as(f64, 1), (try evalIn(
        \\var hit = 0;
        \\function F() { if (new.target) hit = 1; }
        \\new F(); hit
    )).number);
}

test "object spread" {
    try std.testing.expectEqual(@as(f64, 6), (try evalIn(
        \\var base = { a: 1, b: 2 };
        \\var o = { ...base, c: 3 };
        \\o.a + o.b + o.c
    )).number);
    // Later properties override earlier spread ones.
    try std.testing.expectEqual(@as(f64, 9), (try evalIn("var o = { x: 1, ...{ x: 9 } }; o.x")).number);
    // Spreading null/undefined is a no-op.
    try std.testing.expectEqual(@as(f64, 1), (try evalIn("var o = { ...null, ...undefined, a: 1 }; o.a")).number);
}

test "delete operator" {
    try std.testing.expect((try evalIn(
        \\var o = { a: 1, b: 2 };
        \\var ok = delete o.a;
        \\ok && !("a" in o) && o.b === 2
    )).boolean);
    // Non-configurable property can't be deleted.
    try std.testing.expect((try evalIn(
        \\var o = {};
        \\Object.defineProperty(o, "x", { value: 1, configurable: false });
        \\var r = delete o.x;
        \\!r && ("x" in o)
    )).boolean);
    // delete of a non-reference / missing property is true.
    try std.testing.expect((try evalIn("delete 1 && delete {}.nope")).boolean);
}

test "for-of / for-in with destructuring + member targets" {
    try std.testing.expectEqual(@as(f64, 10), (try evalIn(
        \\var s = 0; for (const [a, b] of [[1, 2], [3, 4]]) { s += a + b; } s
    )).number);
    try std.testing.expectEqual(@as(f64, 3), (try evalIn(
        \\var s = 0; for (const { x } of [{ x: 1 }, { x: 2 }]) { s += x; } s
    )).number);
    // Assignment form with a member target.
    try std.testing.expectEqual(@as(f64, 7), (try evalIn(
        \\var o = {}; for (o.k of [5, 6, 7]) {} o.k
    )).number);
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
    )).number);
    try std.testing.expectEqual(@as(f64, 5), (try evalIn(";;; var x = 5;;; x")).number);
    try std.testing.expectEqual(@as(f64, 2), (try evalIn(
        \\class C { [1.1]() { return 2; } static [1.1]() { return 2; } };
        \\var c = new C();
        \\c[1.1]()
    )).number);
}

test "context persists globals across evaluations" {
    const ctx = try Context.create(std.testing.allocator);
    defer ctx.destroy();
    _ = try ctx.evaluate("var counter = 41;");
    const v = try ctx.evaluate("counter = counter + 1;");
    try std.testing.expectEqual(@as(f64, 42), v.number);
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
    )).boolean);
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
    )).boolean);
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
    )).boolean);
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
    )).boolean);
}

test "delete distinguishes var bindings from sloppy global properties" {
    try std.testing.expect((try evalIn(
        \\var declared = {};
        \\undeclared = {};
        \\delete declared === false &&
        \\typeof declared === "object" &&
        \\delete undeclared === true &&
        \\typeof undeclared === "undefined"
    )).boolean);
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
    )).boolean);
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
    )).boolean);
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
    )).boolean);
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
    )).boolean);
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
    )).boolean);
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
    )).boolean);
}

test "RegExp compile mutates before throwing on non-writable lastIndex" {
    try std.testing.expect((try evalIn(
        \\var r = /foo/i;
        \\Object.defineProperty(r, "lastIndex", { value: 42, writable: false });
        \\var threw = false;
        \\try { r.compile("^bar", "m"); } catch (e) { threw = e.name === "TypeError"; }
        \\threw && r.source === "^bar" && r.multiline === true && r.ignoreCase === false &&
        \\r.lastIndex === 42 && r.test("x\nbar") === true
    )).boolean);
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
    )).boolean);
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
    )).boolean);
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
    )).boolean);
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
    )).boolean);
    try std.testing.expect((try evalIn(
        \\var args;
        \\var rx2 = {
        \\  flags: "",
        \\  exec: function() { return { 0: "BC", 1: "B", length: 2, index: 1, groups: { name: "B" } }; }
        \\};
        \\RegExp.prototype[Symbol.replace].call(rx2, "aBC", function() { args = arguments; return "_"; });
        \\args.length === 5 && args[0] === "BC" && args[1] === "B" &&
        \\args[2] === 1 && args[3] === "aBC" && args[4].name === "B"
    )).boolean);
    try std.testing.expect((try evalIn(
        \\var rx3 = {
        \\  flags: "",
        \\  exec: function() { return { 0: "x", length: 1, index: 0, groups: { a: "A" } }; }
        \\};
        \\RegExp.prototype[Symbol.replace].call(rx3, "x", "$<a>$&") === "Ax"
    )).boolean);
    try std.testing.expect((try evalIn(
        \\var rx4 = {
        \\  flags: "",
        \\  exec: function() { return { 0: "", length: 1, index: 0, groups: null }; }
        \\};
        \\try { RegExp.prototype[Symbol.replace].call(rx4, "x", ""); false }
        \\catch (e) { e.name === "TypeError" }
    )).boolean);
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
    )).boolean);
    try std.testing.expect((try evalIn(
        \\var r = /^|\udf06/g;
        \\Object.defineProperty(r, "unicode", { writable: true });
        \\r.unicode = undefined;
        \\r[Symbol.replace]("\ud834\udf06", "XXX") === "XXX\ud834XXX"
    )).boolean);
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
    )).boolean);
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
    )).boolean);
}

test "object literal __proto__ sets ordinary object prototype" {
    try std.testing.expect((try evalIn(
        \\var p = { marker: 1 };
        \\var o = { __proto__: p };
        \\var n = { __proto__: null };
        \\o.marker === 1 && !o.hasOwnProperty("marker") &&
        \\Object.getPrototypeOf(o) === p &&
        \\Object.getPrototypeOf(n) === null
    )).boolean);
}

test "RegExp duplicate named captures use participating group" {
    try std.testing.expect((try evalIn(
        \\var m = /(?:(?:(?<a>x)|(?<a>y))\k<a>){2}/.exec("xxyy");
        \\m[0] === "xxyy" && m[1] === undefined && m[2] === "y" &&
        \\m.groups.a === "y" &&
        \\"xxyy".replace(/(?:(?:(?<a>x)|(?<a>y))\k<a>)/, "2$<a>") === "2xyy"
    )).boolean);
}

test "ShadowRealm uses ordinary globals and caller realm wrappers" {
    try std.testing.expect((try evalIn(
        \\var r = new ShadowRealm();
        \\r.evaluate('Object.getPrototypeOf(globalThis) === Object.prototype') &&
        \\r.evaluate('globalThis.constructor === Object') &&
        \\Object.getPrototypeOf(r.evaluate('() => 1')) === Function.prototype
    )).boolean);
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
    )).boolean);
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
    try std.testing.expectEqualStrings("1234", v.string);
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
    try std.testing.expectEqualStrings("TypeError", v.string);
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
    try std.testing.expectEqualStrings("same", v.string);
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
    try std.testing.expectEqualStrings("ok", v.string);
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
    try std.testing.expectEqualStrings(expected, v.string);
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
    )).boolean);
}

test "function name + length own properties" {
    // `name` and `length` are own, non-enumerable, configurable, non-writable.
    try expectEvalStr("foo", "function foo(a, b) {} foo.name");
    try std.testing.expectEqual(@as(f64, 2), (try evalIn("function foo(a, b) {} foo.length")).number);
    try std.testing.expect((try evalIn(
        \\function foo(a, b) {}
        \\foo.hasOwnProperty("name") && foo.hasOwnProperty("length")
    )).boolean);
    // `length` counts params before the first default / rest.
    try std.testing.expectEqual(@as(f64, 1), (try evalIn("function f(a, b = 1, c) {} f.length")).number);
    try std.testing.expectEqual(@as(f64, 1), (try evalIn("function f(a, ...r) {} f.length")).number);
    // An anonymous function expression *not* in a naming position has the
    // empty name; assigned to a binding it takes that name (NamedEvaluation).
    try expectEvalStr("", "(function (x) {}).name");
    try expectEvalStr("f", "var f = function (x) {}; f.name");
    // Descriptor attributes: { writable:false, enumerable:false, configurable:true }.
    try std.testing.expect((try evalIn(
        \\function f() {}
        \\var d = Object.getOwnPropertyDescriptor(f, "length");
        \\!d.writable && !d.enumerable && d.configurable
    )).boolean);
    // name/length are not enumerable (skipped by Object.keys / for-in).
    try std.testing.expectEqual(@as(f64, 0), (try evalIn("function f(a) {} Object.keys(f).length")).number);
    // Class constructor carries name + constructor arity.
    try expectEvalStr("C", "class C { constructor(a, b) {} } C.name");
    try std.testing.expectEqual(@as(f64, 2), (try evalIn("class C { constructor(a, b) {} } C.length")).number);
    // Bound function: name is "bound <target>", length is reduced by bound args.
    try expectEvalStr("bound f", "function f(a, b, c) {} f.bind(null, 1).name");
    try std.testing.expectEqual(@as(f64, 2), (try evalIn("function f(a, b, c) {} f.bind(null, 1).length")).number);
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
    )).boolean);
}

test "native functions carry name + length own properties" {
    // Built-in methods/globals/constructors report their spec name and arity.
    try expectEvalStr("defineProperty", "Object.defineProperty.name");
    try std.testing.expectEqual(@as(f64, 3), (try evalIn("Object.defineProperty.length")).number);
    try expectEvalStr("push", "Array.prototype.push.name");
    try std.testing.expectEqual(@as(f64, 1), (try evalIn("Array.prototype.push.length")).number);
    try expectEvalStr("parseInt", "parseInt.name");
    try std.testing.expectEqual(@as(f64, 2), (try evalIn("parseInt.length")).number);
    try expectEvalStr("Object", "Object.name");
    // Same name can have a different arity on a different prototype.
    try std.testing.expectEqual(@as(f64, 0), (try evalIn("Object.prototype.toString.length")).number);
    try std.testing.expectEqual(@as(f64, 1), (try evalIn("Number.prototype.toString.length")).number);
    // Own + non-enumerable + non-writable + configurable, like user functions.
    try std.testing.expect((try evalIn(
        \\Object.keys.hasOwnProperty("name") && Object.keys.hasOwnProperty("length")
    )).boolean);
    try std.testing.expect((try evalIn(
        \\var d = Object.getOwnPropertyDescriptor(Math.max, "length");
        \\!d.writable && !d.enumerable && d.configurable
    )).boolean);
    try std.testing.expectEqual(@as(f64, 0), (try evalIn("Object.keys(Math.floor).length")).number);
}

test "typeof on an undeclared identifier is \"undefined\" (no throw)" {
    try expectEvalStr("undefined", "typeof undeclaredXYZ");
    try std.testing.expect((try evalIn("typeof undeclaredXYZ === 'undefined'")).boolean);
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
    )).boolean);
}

test "global undefined is an immutable binding, not a literal token" {
    try std.testing.expect((try evalIn(
        \\undefined = 5;
        \\undefined === void 0
    )).boolean);
    try std.testing.expect((try evalIn(
        \\var newProperty = undefined = 42;
        \\newProperty === 42 && undefined === void 0
    )).boolean);
    try std.testing.expect((try evalIn("delete undefined === false")).boolean);
    try std.testing.expect((try evalIn(
        \\var d = Object.getOwnPropertyDescriptor(globalThis, "undefined");
        \\d.value === void 0 && !d.writable && !d.enumerable && !d.configurable
    )).boolean);
    try std.testing.expect((try evalIn(
        \\(function () { let undefined = 7; return undefined; })() === 7
    )).boolean);
    try std.testing.expect((try evalIn(
        \\(function (undefined) { undefined = 9; return undefined; })(1) === 9
    )).boolean);
    try std.testing.expectError(error.Throw, evalIn("let undefined;"));
}

test "function declarations are hoisted" {
    // Forward references work at program scope and inside function bodies.
    try std.testing.expectEqual(@as(f64, 5), (try evalIn("bar(); function bar() { return 5; }\nbar()")).number);
    try expectEvalStr("function", "typeof foo; function foo() {}");
    try std.testing.expectEqual(@as(f64, 1), (try evalIn("foo.x = 1; function foo() {} foo.x")).number);
    try std.testing.expectEqual(@as(f64, 9), (try evalIn(
        \\function f() { return inner(); function inner() { return 9; } }
        \\f()
    )).number);
    // The hoisted binding is the same function object referenced before its text.
    try std.testing.expect((try evalIn("var g = bar; function bar() {} g === bar")).boolean);
    // A later declaration of the same name wins.
    try std.testing.expectEqual(@as(f64, 2), (try evalIn("function f() { return 1; } function f() { return 2; } f()")).number);
}

test "built-in methods are non-enumerable" {
    // Prototype methods and namespace statics are skipped by Object.keys/for-in.
    try std.testing.expect((try evalIn("Object.keys(Math).indexOf('max') === -1")).boolean);
    try std.testing.expect((try evalIn("Object.keys(JSON).length === 0")).boolean);
    try std.testing.expect((try evalIn("Object.keys(Array.prototype).indexOf('push') === -1")).boolean);
    try std.testing.expect(!(try evalIn("Array.prototype.propertyIsEnumerable('push')")).boolean);
    try std.testing.expect((try evalIn("Object.keys(Object).indexOf('keys') === -1")).boolean);
    // They remain present and callable.
    try std.testing.expectEqual(@as(f64, 3), (try evalIn("Math.max(1, 2, 3)")).number);
    try std.testing.expect((try evalIn("Array.prototype.hasOwnProperty('push')")).boolean);
}

test "built-in prototypes carry constructor; Boolean.prototype exists" {
    // Every built-in prototype links back to its constructor (non-enumerable).
    try std.testing.expect((try evalIn("Object.prototype.constructor === Object")).boolean);
    try std.testing.expect((try evalIn("Array.prototype.constructor === Array")).boolean);
    try std.testing.expect((try evalIn("String.prototype.constructor === String")).boolean);
    try std.testing.expect((try evalIn("Number.prototype.constructor === Number")).boolean);
    try std.testing.expect((try evalIn("Function.prototype.constructor === Function")).boolean);
    try std.testing.expect((try evalIn("Date.prototype.constructor === Date")).boolean);
    try std.testing.expect((try evalIn("Function.prototype.isPrototypeOf(Object)")).boolean);
    try std.testing.expect((try evalIn("Function.prototype.isPrototypeOf(Array)")).boolean);
    try std.testing.expect((try evalIn("Function.prototype.isPrototypeOf(String)")).boolean);
    try std.testing.expect((try evalIn("Function.prototype.isPrototypeOf(Date)")).boolean);
    try std.testing.expect((try evalIn("Function.prototype.isPrototypeOf(RegExp)")).boolean);
    // `constructor` is non-enumerable.
    try std.testing.expect((try evalIn("Object.keys(Array.prototype).indexOf('constructor') === -1")).boolean);
    // Boolean.prototype now exists with constructor + generic toString/valueOf.
    try expectEvalStr("object", "typeof Boolean.prototype");
    try std.testing.expect((try evalIn("Boolean.prototype.constructor === Boolean")).boolean);
    try std.testing.expect((try evalIn("Function.prototype.isPrototypeOf(Boolean)")).boolean);
    try std.testing.expect((try evalIn("Object.prototype.isPrototypeOf(Boolean.prototype)")).boolean);
    try expectEvalStr("true", "Boolean.prototype.toString.call(true)");
    try std.testing.expect(!(try evalIn("Boolean.prototype.valueOf.call(false)")).boolean);
    try std.testing.expect((try evalIn(
        \\var other = $262.createRealm().global;
        \\var C = new other.Function();
        \\C.prototype = null;
        \\Object.getPrototypeOf(Reflect.construct(Boolean, [], C)) === other.Boolean.prototype
    )).boolean);
}

test "Symbol.prototype: toString / valueOf / chain" {
    try expectEvalStr("object", "typeof Symbol.prototype");
    try std.testing.expect((try evalIn("Symbol.prototype.constructor === Symbol")).boolean);
    try expectEvalStr("function", "typeof Symbol.prototype.toString");
    // toString renders the description; valueOf returns the symbol itself.
    try expectEvalStr("Symbol(f)", "Symbol('f').toString()");
    try expectEvalStr("Symbol()", "Symbol().toString()");
    try std.testing.expect((try evalIn("var s = Symbol('q'); s.valueOf() === s")).boolean);
    // Instances are linked to Symbol.prototype; the methods are generic via .call.
    try std.testing.expect((try evalIn("Object.getPrototypeOf(Symbol()) === Symbol.prototype")).boolean);
    try expectEvalStr("Symbol(z)", "Symbol.prototype.toString.call(Symbol('z'))");
    // A non-symbol receiver throws TypeError.
    try std.testing.expect((try evalIn(
        \\var t = false;
        \\try { Symbol.prototype.toString.call({}); } catch (e) { t = e.name === "TypeError"; }
        \\t
    )).boolean);
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
    )).boolean);
    try std.testing.expect((try evalIn(
        \\Object.defineProperty(Symbol.prototype, Symbol.toPrimitive, { configurable: true, value: null });
        \\var result = `${Object(Symbol())}`;
        \\var threw = false;
        \\try { +Object(Symbol()); } catch (e) { threw = e instanceof TypeError; }
        \\var related = false;
        \\try { Object(Symbol()) <= ''; } catch (e) { related = e instanceof TypeError; }
        \\delete Symbol.prototype[Symbol.toPrimitive];
        \\result === 'Symbol()' && threw && related
    )).boolean);
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
    )).boolean);
}

test "Error.prototype.stack accessor" {
    // An accessor on Error.prototype with get/set named "get stack"/"set stack".
    try expectEvalStr("function", "typeof Object.getOwnPropertyDescriptor(Error.prototype, 'stack').get");
    try expectEvalStr("get stack", "Object.getOwnPropertyDescriptor(Error.prototype, 'stack').get.name");
    try expectEvalStr("set stack", "Object.getOwnPropertyDescriptor(Error.prototype, 'stack').set.name");
    // The getter returns a string for an Error receiver, undefined otherwise.
    try expectEvalStr("string", "typeof new Error('x').stack");
    try std.testing.expect((try evalIn("({ __proto__: new Error('y') }).stack === undefined")).boolean);
    // The setter installs an own { writable, enumerable, configurable } data
    // property shadowing the accessor (SetterThatIgnoresPrototypeProperties).
    try std.testing.expect((try evalIn("var e = new Error('x'); e.stack = 'custom'; e.stack === 'custom'")).boolean);
    try std.testing.expect((try evalIn("var e = new Error('x'); e.stack = 's'; Object.getOwnPropertyDescriptor(e, 'stack').enumerable")).boolean);
    // A non-String value throws a TypeError; assigning to %Error.prototype% throws.
    try std.testing.expect((try evalIn("var e = new Error('x'); try { e.stack = 42; false } catch (x) { x instanceof TypeError }")).boolean);
    try std.testing.expect((try evalIn("try { Error.prototype.stack = 's'; false } catch (x) { x instanceof TypeError }")).boolean);
    try std.testing.expect((try evalIn(
        \\var setA = Object.getOwnPropertyDescriptor(Error.prototype, "stack").set;
        \\var realmB = $262.createRealm().global;
        \\try {
        \\  setA.call(realmB.Error.prototype, "x");
        \\  false;
        \\} catch (e) {
        \\  Object.getPrototypeOf(e) === realmB.TypeError.prototype;
        \\}
    )).boolean);
}

test "AggregateError" {
    try expectEvalStr("function", "typeof AggregateError");
    // errors comes from the (iterable) first arg; message is the second.
    try std.testing.expectEqual(@as(f64, 3), (try evalIn("new AggregateError([1, 2, 3]).errors.length")).number);
    try expectEvalStr("boom", "new AggregateError([], 'boom').message");
    try std.testing.expectEqual(@as(f64, 2), (try evalIn("new AggregateError(new Set([1, 2])).errors.length")).number);
    // Prototype chain + name, and the cause option (third arg).
    try std.testing.expect((try evalIn("new AggregateError([]) instanceof Error")).boolean);
    try std.testing.expect((try evalIn("new AggregateError([]) instanceof AggregateError")).boolean);
    try expectEvalStr("AggregateError", "AggregateError.prototype.name");
    try std.testing.expectEqual(@as(f64, 5), (try evalIn("new AggregateError([], 'm', { cause: 5 }).cause")).number);
    // `errors` is a non-enumerable own property.
    try std.testing.expect((try evalIn("new AggregateError([1]).hasOwnProperty('errors') && Object.keys(new AggregateError([1])).indexOf('errors') === -1")).boolean);
    try std.testing.expect((try evalIn(
        \\var proto = {};
        \\function Target() {}
        \\Target.prototype = proto;
        \\Object.getPrototypeOf(Reflect.construct(AggregateError, [[]], Target)) === proto
    )).boolean);
    try std.testing.expect((try evalIn(
        \\var other = $262.createRealm().global;
        \\var Target = new other.Function();
        \\Target.prototype = undefined;
        \\Object.getPrototypeOf(Reflect.construct(AggregateError, [[]], Target)) === other.AggregateError.prototype
    )).boolean);
    try std.testing.expect((try evalIn("try { new AggregateError(); false } catch (e) { e instanceof TypeError }")).boolean);
    try std.testing.expect((try evalIn(
        \\var bad = { [Symbol.iterator]() { return { next() { return undefined; } }; } };
        \\try { new AggregateError(bad); false } catch (e) { e instanceof TypeError }
    )).boolean);
}

test "SuppressedError creates message before error and suppressed" {
    try std.testing.expect((try evalIn(
        \\var e = new SuppressedError({}, {}, { toString: function () { return ""; } });
        \\var keys = Object.getOwnPropertyNames(e);
        \\keys.indexOf("message") !== -1 &&
        \\keys.indexOf("error") === keys.indexOf("message") + 1 &&
        \\keys.indexOf("suppressed") === keys.indexOf("error") + 1
    )).boolean);
}

test "Error cause option (ES2022)" {
    // `new Error(msg, { cause })` installs a non-enumerable own `cause`.
    try std.testing.expectEqual(@as(f64, 42), (try evalIn("new Error('m', { cause: 42 }).cause")).number);
    try std.testing.expect((try evalIn("new TypeError('t', { cause: 'x' }).cause === 'x'")).boolean);
    // Present-but-undefined cause is still an own property; absent options is not.
    try std.testing.expect((try evalIn("new Error('m', { cause: undefined }).hasOwnProperty('cause')")).boolean);
    try std.testing.expect(!(try evalIn("new Error('m').hasOwnProperty('cause')")).boolean);
    try std.testing.expect(!(try evalIn("new Error('m', {}).hasOwnProperty('cause')")).boolean);
    // cause is non-enumerable, writable, configurable.
    try std.testing.expect((try evalIn(
        \\var d = Object.getOwnPropertyDescriptor(new Error('m', { cause: 1 }), 'cause');
        \\!d.enumerable && d.writable && d.configurable
    )).boolean);
}

test "Error prototypes: chain, name/message inheritance, toString" {
    // Each constructor has a real prototype with name/message/constructor.
    try expectEvalStr("object", "typeof Error.prototype");
    try expectEvalStr("Error", "Error.prototype.name");
    try expectEvalStr("", "Error.prototype.message");
    try std.testing.expect((try evalIn("Error.prototype.constructor === Error")).boolean);
    try std.testing.expect((try evalIn("Error.hasOwnProperty('prototype')")).boolean);
    // Prototype chain: TypeError.prototype -> Error.prototype -> Object.prototype.
    try std.testing.expect((try evalIn("Object.getPrototypeOf(new Error()) === Error.prototype")).boolean);
    try std.testing.expect((try evalIn("Object.getPrototypeOf(TypeError.prototype) === Error.prototype")).boolean);
    try std.testing.expect((try evalIn("new TypeError('x') instanceof Error")).boolean);
    // name is inherited; message is own only when supplied.
    try expectEvalStr("Error", "new Error().name");
    try expectEvalStr("TypeError", "new TypeError().name");
    try std.testing.expect((try evalIn("new Error('m').hasOwnProperty('message')")).boolean);
    try std.testing.expect(!(try evalIn("new Error().hasOwnProperty('message')")).boolean);
    try std.testing.expect(!(try evalIn("new Error().hasOwnProperty('name')")).boolean);
    // toString: "name: message", or just one when the other is empty; generic.
    try expectEvalStr("Error: hi", "new Error('hi').toString()");
    try expectEvalStr("TypeError: x", "new TypeError('x').toString()");
    try expectEvalStr("Error", "new Error().toString()");
    try expectEvalStr("E: m", "Error.prototype.toString.call({ name: 'E', message: 'm' })");
}

test "Object.prototype legacy accessor helpers (__define/lookup__)" {
    try std.testing.expectEqual(@as(f64, 42), (try evalIn(
        \\var o = {}; o.__defineGetter__("x", function () { return 42; }); o.x
    )).number);
    try std.testing.expectEqual(@as(f64, 7), (try evalIn(
        \\var o = {}; var v = 0; o.__defineSetter__("y", function (n) { v = n; }); o.y = 7; v
    )).number);
    // __lookupGetter__/__lookupSetter__ return the accessor fn, walking the proto chain.
    try std.testing.expect((try evalIn(
        \\var o = {}; o.__defineGetter__("x", function () { return 1; });
        \\typeof o.__lookupGetter__("x") === "function" && o.__lookupGetter__("x")() === 1
    )).boolean);
    // Missing / data properties have no getter; a non-callable arg throws TypeError.
    try std.testing.expect((try evalIn("({}).__lookupGetter__('nope') === undefined")).boolean);
    try std.testing.expect((try evalIn("({ a: 1 }).__lookupGetter__('a') === undefined")).boolean);
    try std.testing.expect((try evalIn(
        \\var t = false; try { ({}).__defineGetter__("x", 5); } catch (e) { t = e.name === "TypeError"; } t
    )).boolean);
    // Defined accessor is enumerable + configurable.
    try std.testing.expect((try evalIn(
        \\var o = {}; o.__defineGetter__("x", function () {});
        \\var d = Object.getOwnPropertyDescriptor(o, "x"); d.enumerable && d.configurable
    )).boolean);
}

test "large array length is logical (no OOM) + length assignment" {
    // `new Array(huge)` tracks length without materializing 4 billion holes.
    try std.testing.expectEqual(@as(f64, 4294967295), (try evalIn("new Array(4294967295).length")).number);
    try std.testing.expectEqual(@as(f64, 0), (try evalIn("new Array(0).length")).number);
    try std.testing.expectEqual(@as(f64, 3), (try evalIn("new Array(3).length")).number);
    try std.testing.expectEqual(@as(f64, 100), (try evalIn("new Array(100).length")).number);
    // Assigning length truncates (dropping elements) or grows logically.
    try std.testing.expect((try evalIn(
        \\var a = [1, 2, 3]; a.length = 2;
        \\a.length === 2 && a[1] === 2 && a[2] === undefined
    )).boolean);
    try std.testing.expectEqual(@as(f64, 5), (try evalIn("var a = [1, 2, 3]; a.length = 5; a.length")).number);
    // A large index extends the logical length past it.
    try std.testing.expectEqual(@as(f64, 6), (try evalIn("var a = []; a[5] = 1; a.length")).number);
    // Invalid lengths throw RangeError.
    try std.testing.expect((try evalIn(
        \\var t = false; try { [].length = -1; } catch (e) { t = e.name === "RangeError"; } t
    )).boolean);
    try std.testing.expect((try evalIn(
        \\var t = false; try { [].length = 1.5; } catch (e) { t = e.name === "RangeError"; } t
    )).boolean);
}

test "Date setters + string conversions" {
    // Time-component setters honor extra args and roll over out-of-range values.
    try std.testing.expect((try evalIn(
        \\var d = new Date(2016, 6, 1); d.setHours(0, 0, 0, 543);
        \\d.getTime() === new Date(2016, 6, 1, 0, 0, 0, 543).getTime()
    )).boolean);
    try std.testing.expect((try evalIn(
        \\var d = new Date(2016, 6, 1); d.setHours(0, 0, 0, -1);
        \\d.getTime() === new Date(2016, 5, 30, 23, 59, 59, 999).getTime()
    )).boolean);
    // setMonth/setDate roll into adjacent months/years.
    try std.testing.expectEqual(@as(f64, 1971), (try evalIn("var d = new Date(0); d.setMonth(13); d.getUTCFullYear()")).number);
    try std.testing.expectEqual(@as(f64, 1), (try evalIn("var d = new Date(0); d.setDate(32); d.getUTCMonth()")).number);
    // setFullYear revives an invalid date; other setters leave it invalid.
    try std.testing.expectEqual(@as(f64, 2020), (try evalIn("var d = new Date(NaN); d.setFullYear(2020); d.getUTCFullYear()")).number);
    try std.testing.expect(std.math.isNan((try evalIn("var d = new Date(NaN); d.setHours(5); d.getTime()")).number));
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
    )).boolean);
    try std.testing.expect((try evalIn("new Date(NaN).toJSON() === null")).boolean);
}

test "Function constructor builds callable functions from source" {
    // Params + body, called and constructed.
    try std.testing.expectEqual(@as(f64, 7), (try evalIn("Function('a', 'b', 'return a + b')(3, 4)")).number);
    try std.testing.expectEqual(@as(f64, 12), (try evalIn("new Function('a,b', 'return a * b')(3, 4)")).number);
    try std.testing.expectEqual(@as(f64, 42), (try evalIn("Function('return 42')()")).number);
    try std.testing.expect((try evalIn(
        \\var i = 0;
        \\var p = { toString: function() { return "a" + (++i); } };
        \\var f = Function(p, p, p, "return a3 + a2 + a1.length;");
        \\f("x", "", 2) === "21" && i === 3
    )).boolean);
    try std.testing.expect((try evalIn(
        \\var p = { toString: function() { p = 1; return "a"; } };
        \\var body = { toString: function() { throw "body"; } };
        \\try { Function(p, body); false; } catch (e) { e === "body" && p === 1; }
    )).boolean);
    // Spec name + arity of the synthesized function.
    try expectEvalStr("anonymous", "Function('return 1').name");
    try std.testing.expectEqual(@as(f64, 2), (try evalIn("Function('a', 'b', 'return 0').length")).number);
    try expectEvalStr("function", "typeof Function('return 1')");
    // A syntactically invalid body throws SyntaxError.
    try std.testing.expect((try evalIn(
        \\var t = false;
        \\try { Function("return )("); } catch (e) { t = e.name === "SyntaxError"; }
        \\t
    )).boolean);
}

test "String.prototype.split: limit + regex separators" {
    // `limit` truncates the result.
    try expectEvalStr("a|b", "'a,b,c'.split(',', 2).join('|')");
    try std.testing.expectEqual(@as(f64, 0), (try evalIn("'a,b,c'.split(',', 0).length")).number);
    // Regex separators split on each match.
    try expectEvalStr("2016|01|02", "'2016-01-02'.split(/-/).join('|')");
    try expectEvalStr("a|b|c", "'a1b2c'.split(/\\d/).join('|')");
    try expectEvalStr("a|b|c", "'a, b ,c'.split(/\\s*,\\s*/).join('|')");
    // An empty-matching pattern splits between every character.
    try expectEvalStr("a|b|c", "'abc'.split(/(?:)/).join('|')");
    // Capture groups are spliced into the result.
    try expectEvalStr(",t,es,t,", "'test'.split(/(t)/).join(',')");
    // Empty input: [""] unless the pattern matches the empty string (then []).
    try std.testing.expectEqual(@as(f64, 1), (try evalIn("''.split(/x/).length")).number);
    try std.testing.expectEqual(@as(f64, 0), (try evalIn("''.split(/(?:)/).length")).number);
    // String separators (and no separator) still behave.
    try std.testing.expectEqual(@as(f64, 3), (try evalIn("'a,b,c'.split(',').length")).number);
    try std.testing.expectEqual(@as(f64, 1), (try evalIn("'abc'.split().length")).number);
}

test "Object.hasOwn" {
    try std.testing.expect((try evalIn("Object.hasOwn({ a: 1 }, \"a\")")).boolean);
    try std.testing.expect(!(try evalIn("Object.hasOwn({ a: 1 }, \"b\")")).boolean);
    // Own only — inherited properties are excluded.
    try std.testing.expect(!(try evalIn("Object.hasOwn(Object.create({ a: 1 }), \"a\")")).boolean);
    // Array indices, array length, and string indices/length.
    try std.testing.expect((try evalIn("Object.hasOwn([1, 2], 0) && Object.hasOwn([1, 2], \"length\") && !Object.hasOwn([1, 2], 5)")).boolean);
    try std.testing.expect((try evalIn("Object.hasOwn(\"ab\", 0) && Object.hasOwn(\"ab\", \"length\") && !Object.hasOwn(\"ab\", 9)")).boolean);
    // null / undefined throw a TypeError.
    try std.testing.expect((try evalIn(
        \\var t = false;
        \\try { Object.hasOwn(null, "x"); } catch (e) { t = e.name === "TypeError"; }
        \\t
    )).boolean);
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
        try std.testing.expectEqualStrings("TypeError", ctx.exception.?.object.error_name);
    }
    // Compatible redefinitions are still allowed.
    try std.testing.expectEqual(@as(f64, 2), (try evalIn(
        \\var o = {}; Object.defineProperty(o, "p", { value: 1, configurable: true });
        \\Object.defineProperty(o, "p", { value: 2 }); o.p
    )).number);
    try std.testing.expectEqual(@as(f64, 2), (try evalIn(
        \\var o = {}; Object.defineProperty(o, "p", { value: 1, writable: true, configurable: false });
        \\Object.defineProperty(o, "p", { value: 2 }); o.p
    )).number);
}

test "Object.create applies its properties (second) argument" {
    // Data descriptor on the new object.
    try std.testing.expectEqual(@as(f64, 42), (try evalIn(
        \\var o = Object.create({}, { x: { value: 42, enumerable: true } });
        \\o.x
    )).number);
    // Accessor descriptor.
    try std.testing.expectEqual(@as(f64, 7), (try evalIn(
        \\var o = Object.create(null, { a: { get: function () { return 7; }, enumerable: true } });
        \\o.a
    )).number);
    // Descriptor attributes are honored (non-enumerable stays off Object.keys).
    try std.testing.expectEqual(@as(f64, 0), (try evalIn(
        \\var o = Object.create({}, { a: { value: 1, enumerable: false } });
        \\Object.keys(o).length
    )).number);
    // The prototype argument still wires up the chain; omitted props is a no-op.
    try std.testing.expectEqual(@as(f64, 5), (try evalIn(
        \\var p = { v: 5 }; var o = Object.create(p); o.v
    )).number);
    // A non-object descriptor value throws TypeError, like defineProperties.
    try std.testing.expect((try evalIn(
        \\var t = false;
        \\try { Object.create({}, { x: 1 }); } catch (e) { t = e.name === "TypeError"; }
        \\t
    )).boolean);
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
        try std.testing.expect(ctx.exception.?.object.is_error);
        try std.testing.expectEqualStrings("TypeError", ctx.exception.?.object.error_name);
    }
    // The real constructors still build instances.
    try std.testing.expectEqual(@as(f64, 3), (try evalIn("new Array(3).length")).number);
    try std.testing.expectEqual(@as(f64, 0), (try evalIn("new Date(0).getTime()")).number);
    try std.testing.expectEqual(@as(f64, 0), (try evalIn("new Map().size")).number);
    try std.testing.expectEqual(@as(f64, 5), (try evalIn("new Number(5).valueOf()")).number);
    try std.testing.expect((try evalIn("typeof new Object() === 'object'")).boolean);
}

test "Function.prototype: call / apply / bind" {
    try std.testing.expectEqual(@as(f64, 7), (try evalIn(
        \\function add(a, b) { return a + b; }
        \\add.call(null, 3, 4)
    )).number);
    try std.testing.expectEqual(@as(f64, 7), (try evalIn(
        \\function add(a, b) { return a + b; }
        \\add.apply(null, [3, 4])
    )).number);
    // `this` binding via call.
    try std.testing.expectEqual(@as(f64, 42), (try evalIn(
        \\function getX() { return this.x; }
        \\getX.call({ x: 42 })
    )).number);
    // bind fixes `this` and leading args.
    try std.testing.expectEqual(@as(f64, 15), (try evalIn(
        \\function add3(a, b, c) { return a + b + c; }
        \\var f = add3.bind(null, 1, 2);
        \\f(12)
    )).number);
    try std.testing.expectEqual(@as(f64, 100), (try evalIn(
        \\var o = { v: 100, get: function () { return this.v; } };
        \\var g = o.get.bind(o);
        \\g()
    )).number);
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
    try std.testing.expect((try evalIn("typeof ''[Symbol.iterator] === 'function'")).boolean);
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
    try std.testing.expect((try evalIn("var s = Symbol('plain'); var ws = new WeakSet(); ws.add(s); ws.has(s)")).boolean);
    // An object key is fine.
    try std.testing.expect((try evalIn("var k = {}; var wm = new WeakMap(); wm.set(k, 1); wm.get(k) === 1")).boolean);
    try std.testing.expect((try evalIn(
        \\var other = $262.createRealm().global;
        \\var C = new other.Function();
        \\C.prototype = null;
        \\Object.getPrototypeOf(Reflect.construct(WeakMap, [], C)) === other.WeakMap.prototype &&
        \\Object.getPrototypeOf(Reflect.construct(WeakSet, [], C)) === other.WeakSet.prototype
    )).boolean);
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
    try std.testing.expect((try evalIn("(new Object()) instanceof Object")).boolean);
    try std.testing.expectEqual(@as(f64, 3), (try evalIn("new Array(1, 2, 3).length")).number);
}

test "delete of a private member is an early error" {
    try expectParseError("({}).#x");
    try expectParseError("class C { #x = 1; m() { delete this.#x; } }");
    try expectParseError("class C { #x = 1; m() { delete (this.#x); } }"); // parenthesized (covered)
    // Deleting a public property — even of an object reached through a private
    // field — is allowed.
    _ = try evalIn("class C { #x = {}; m() { return delete this.#x.y; } }");
    try std.testing.expect((try evalIn("delete ({ a: 1 }).a")).boolean);
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
    try std.testing.expect((try evalIn("var v = 1; var v = 2; v")).number == 2);
    _ = try evalIn("{ function f() { return 1; } function f() { return 2; } f(); }");
}

test "numeric separators: valid between digits, rejected when misplaced" {
    // Valid: a `_` between two digits of the radix.
    try std.testing.expectEqual(@as(f64, 1000), (try evalIn("1_000")).number);
    try std.testing.expectEqual(@as(f64, 2), (try evalIn("0b1_0")).number);
    try std.testing.expectEqual(@as(f64, 31), (try evalIn("0x1_F")).number);
    try std.testing.expectEqual(@as(f64, 10.01), (try evalIn("1_0.0_1")).number);
    try std.testing.expectEqual(@as(f64, 1e10), (try evalIn("1e1_0")).number);
    // Misplaced separators are early errors.
    for ([_][]const u8{ "_1", "1_", "1__0", "0x_1", "0b1_", "1_.5", "1._5", "1_e3", "1e_3", "0_1", "0_8" }) |bad|
        try expectParseError(bad);
}

test "Math.sumPrecise sums exactly" {
    try std.testing.expectEqual(@as(f64, 6), (try evalIn("Math.sumPrecise([1, 2, 3])")).number);
    // Exact summation survives intermediate overflow + cancellation.
    try std.testing.expectEqual(@as(f64, 0.30000000000000004), (try evalIn(
        \\Math.sumPrecise([1e308, 1e308, 0.1, 0.1, 1e30, 0.1, -1e30, -1e308, -1e308])
    )).number);
    try std.testing.expectEqual(@as(f64, 0), (try evalIn("Math.sumPrecise([1e308, -1e308])")).number);
    // Special values.
    try std.testing.expect(std.math.isNan((try evalIn("Math.sumPrecise([NaN, 1])")).number));
    try std.testing.expect(std.math.isNan((try evalIn("Math.sumPrecise([Infinity, -Infinity])")).number));
    try std.testing.expect((try evalIn("Math.sumPrecise([Infinity, 1])")).number == std.math.inf(f64));
    // Empty is -0; a finite cancellation is +0; all -0 is -0.
    try std.testing.expect((try evalIn("1 / Math.sumPrecise([])")).number == -std.math.inf(f64));
    try std.testing.expect((try evalIn("1 / Math.sumPrecise([0.1, -0.1])")).number == std.math.inf(f64));
    try std.testing.expect((try evalIn("1 / Math.sumPrecise([-0, -0])")).number == -std.math.inf(f64));
    // A non-Number element and a non-iterable argument both throw.
    try std.testing.expectError(error.Throw, evalIn("Math.sumPrecise([1, '2'])"));
    try std.testing.expectError(error.Throw, evalIn("Math.sumPrecise(5)"));
}

test "Math.f16round rounds to binary16" {
    try std.testing.expect((try evalIn("typeof Math.f16round === 'function'")).boolean);
    try std.testing.expectEqual(@as(f64, 1.5), (try evalIn("Math.f16round(1.5)")).number); // exact in f16
    try std.testing.expectEqual(@as(f64, 65504), (try evalIn("Math.f16round(65504)")).number); // max f16
    try std.testing.expect((try evalIn("Math.f16round(65536)")).number == std.math.inf(f64)); // overflows f16
    try std.testing.expect(std.math.isNan((try evalIn("Math.f16round(NaN)")).number));
    try std.testing.expect((try evalIn("Math.f16round(Infinity)")).number == std.math.inf(f64));
    // 1.337 is not representable; rounds to the nearest binary16 value.
    try std.testing.expectEqual(@as(f64, 1.3369140625), (try evalIn("Math.f16round(1.337)")).number);
}

test "Math: signed-zero, pow/hypot edge cases, prototype + toStringTag" {
    // max prefers +0, min prefers -0.
    try std.testing.expect((try evalIn("1 / Math.max(-0, 0)")).number == std.math.inf(f64));
    try std.testing.expect((try evalIn("1 / Math.min(0, -0)")).number == -std.math.inf(f64));
    // round of a value that rounds to zero keeps the operand's sign.
    try std.testing.expect((try evalIn("1 / Math.round(-0.5)")).number == -std.math.inf(f64));
    try std.testing.expect((try evalIn(
        \\var x = -(2 / Number.EPSILON - 1);
        \\Math.round(x) === x
    )).boolean);
    try std.testing.expect((try evalIn(
        \\var calls = 0;
        \\Math.max(NaN, { valueOf: function() { calls++; } });
        \\calls === 1
    )).boolean);
    try std.testing.expect((try evalIn(
        \\var calls = 0;
        \\Math.min(NaN, { valueOf: function() { calls++; } });
        \\calls === 1
    )).boolean);
    // pow: NaN exponent and (±1, ±Infinity) are NaN.
    try std.testing.expect(std.math.isNan((try evalIn("Math.pow(1, NaN)")).number));
    try std.testing.expect(std.math.isNan((try evalIn("Math.pow(-1, Infinity)")).number));
    // hypot: ±Infinity wins over a NaN argument.
    try std.testing.expect((try evalIn("Math.hypot(NaN, Infinity)")).number == std.math.inf(f64));
    // each element is ToNumber-coerced (a Symbol throws).
    try std.testing.expectError(error.Throw, evalIn("Math.max(1, Symbol())"));
    // Math is an ordinary object with the right prototype + tag.
    try std.testing.expect((try evalIn("Object.getPrototypeOf(Math) === Object.prototype")).boolean);
    try expectEvalStr("[object Math]", "Object.prototype.toString.call(Math)");
}

test "Map/Set constructors take any iterable (AddEntriesFromIterable)" {
    // A non-array iterable (here a Set / a string) populates the collection.
    try std.testing.expectEqual(@as(f64, 3), (try evalIn("new Set('abc').size")).number);
    try std.testing.expectEqual(@as(f64, 2), (try evalIn("new Map(new Map([['a',1],['b',2]])).size")).number);
    // A generator of entries works for Map.
    try std.testing.expectEqual(@as(f64, 7), (try evalIn(
        \\function* g() { yield ['x', 3]; yield ['y', 4]; }
        \\var m = new Map(g()); m.get('x') + m.get('y')
    )).number);
    try std.testing.expect((try evalIn(
        \\function Target() {}
        \\Target.prototype = null;
        \\Object.getPrototypeOf(Reflect.construct(Map, [], Target)) === Map.prototype
    )).boolean);
    try std.testing.expect((try evalIn(
        \\var other = $262.createRealm().global;
        \\other.Set.prototype.marker = true;
        \\var s = Reflect.construct(Set, [], other.Set);
        \\Object.getPrototypeOf(s) === other.Set.prototype && s.marker === true
    )).boolean);
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
    )).number);
}

test "Map/Set expose [Symbol.iterator]; Set keys === values" {
    // `Map.prototype[Symbol.iterator]` is the same function as `entries`, and
    // `Set.prototype[Symbol.iterator]`/`keys`/`values` are all the same.
    try std.testing.expect((try evalIn("Map.prototype[Symbol.iterator] === Map.prototype.entries")).boolean);
    try std.testing.expect((try evalIn("Set.prototype[Symbol.iterator] === Set.prototype.values")).boolean);
    try std.testing.expect((try evalIn("Set.prototype.keys === Set.prototype.values")).boolean);
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
    )).number);
    try std.testing.expectEqual(@as(f64, 1), (try evalIn(
        \\var set = new Set(['foo', 'bar']);
        \\var count = 0;
        \\set.forEach(function(value) { if (count === 0) set.delete('bar'); count++; });
        \\count
    )).number);
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
    )).number);
}

test "Map getOrInsertComputed validates callback and canonicalizes keys" {
    try std.testing.expect((try evalIn(
        \\var ok = false;
        \\var map = new Map([[1, 'present']]);
        \\try { map.getOrInsertComputed(1, 1); } catch (e) { ok = e instanceof TypeError; }
        \\ok
    )).boolean);
    try std.testing.expect((try evalIn(
        \\var seen;
        \\var map = new Map();
        \\map.getOrInsertComputed(-0, function(key) { seen = 1 / key; return 'value'; });
        \\seen === Infinity && map.has(+0) && map.has(-0)
    )).boolean);
}

test "oversized BigInt literals preserve identity for keyed collections" {
    try std.testing.expect((try evalIn(
        \\var s = '100000000000000000000000000000000000000000000000000000000000000000000000000000000001';
        \\var n = 100000000000000000000000000000000000000000000000000000000000000000000000000000000001n;
        \\n === BigInt(s) && String(n) === s
    )).boolean);
    try std.testing.expect((try evalIn(
        \\var s = '100000000000000000000000000000000000000000000000000000000000000000000000000000000001';
        \\var n = 100000000000000000000000000000000000000000000000000000000000000000000000000000000001n;
        \\var m = new Map([[n, 'ok']]);
        \\m.get(BigInt(s)) === 'ok' && m.has(n)
    )).boolean);
}

test "BigInt constructor parses oversized radix strings and rejects construction early" {
    try std.testing.expect((try evalIn(
        \\var bits = '1';
        \\for (var i = 0; i < 128; i++) bits += '0';
        \\var decimal = '340282366920938463463374607431768211456';
        \\BigInt('0b' + bits) === BigInt(decimal) && BigInt('0B' + bits) === BigInt(decimal)
    )).boolean);
    try std.testing.expect((try evalIn(
        \\var probed = false;
        \\try { Reflect.construct(function() {}, [], BigInt); probed = true; } catch (e) {}
        \\var touched = false;
        \\var threw = false;
        \\try { new BigInt({ valueOf: function() { touched = true; return 1; } }); }
        \\catch (e) { threw = e instanceof TypeError; }
        \\probed && threw && !touched
    )).boolean);
}

test "Object boxes BigInt primitives through BigInt.prototype" {
    try std.testing.expect((try evalIn(
        \\var boxed = Object(1n);
        \\boxed !== 1n && Object.getPrototypeOf(boxed) === BigInt.prototype
    )).boolean);
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
    )).boolean);
}

test "BigInt.asIntN/asUintN wrap text-backed BigInts" {
    try std.testing.expect((try evalIn(
        \\-0x100000000000000000000000000000000n === BigInt('-340282366920938463463374607431768211456')
    )).boolean);
    try std.testing.expect((try evalIn(
        \\~0x100000000000000000000000000000000n === BigInt('-340282366920938463463374607431768211457')
    )).boolean);
    try std.testing.expect((try evalIn(
        \\BigInt.asUintN(200,
        \\  0xbffffffffffffffffffffffffffffffffffffffffffffffffffn
        \\) === 0x0ffffffffffffffffffffffffffffffffffffffffffffffffffn
    )).boolean);
    try std.testing.expect((try evalIn(
        \\BigInt.asIntN(200,
        \\  0xcffffffffffffffffffffffffffffffffffffffffffffffffffn
        \\) === -1n
    )).boolean);
    try std.testing.expect((try evalIn(
        \\BigInt.asIntN(201,
        \\  0xc89e081df68b65fedb32cffea660e55df9605650a603ad5fc54n
        \\) === 0x89e081df68b65fedb32cffea660e55df9605650a603ad5fc54n
    )).boolean);
}

test "__lookupGetter__/__lookupSetter__ walk the chain, proxy-aware" {
    // Returns the accessor's getter; a data property yields undefined.
    try std.testing.expect((try evalIn("var o = { get x() { return 1; } }; o.__lookupGetter__('x') === Object.getOwnPropertyDescriptor(o, 'x').get")).boolean);
    try std.testing.expect((try evalIn("({ a: 1 }).__lookupGetter__('a')")) == .undefined);
    // Walks the prototype chain to find an inherited accessor.
    try std.testing.expect((try evalIn(
        \\var proto = { get y() { return 2; } };
        \\var o = Object.create(proto);
        \\o.__lookupGetter__('y') === Object.getOwnPropertyDescriptor(proto, 'y').get
    )).boolean);
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
    )).number);
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
    try std.testing.expect((try evalIn("Object.getPrototypeOf({}) === Object.prototype")).boolean);
    try std.testing.expect((try evalIn("({}).__proto__ === Object.prototype")).boolean);
    // Inherited Object.prototype methods resolve through the chain (as values and calls).
    try std.testing.expect((try evalIn("typeof ({}).hasOwnProperty === 'function'")).boolean);
    try std.testing.expect((try evalIn("({ a: 1 }).hasOwnProperty('a')")).boolean);
    try std.testing.expect((try evalIn("'toString' in {}")).boolean);
    try expectEvalStr("[object Object]", "({}).toString()");
    // Object.prototype.valueOf returns the object itself.
    try std.testing.expect((try evalIn("var o = {}; o.valueOf() === o")).boolean);
    // A user toString on the chain still wins.
    try expectEvalStr("hi", "var o = { toString() { return 'hi'; } }; o.toString()");
    // Object.create(null) keeps a null prototype; for-in over {} sees no inherited keys.
    try std.testing.expect((try evalIn("Object.getPrototypeOf(Object.create(null)) === null")).boolean);
    try std.testing.expectEqual(@as(f64, 0), (try evalIn("var n = 0; for (var k in {}) n++; n")).number);
    // Class/function .prototype objects inherit from Object.prototype too.
    try std.testing.expect((try evalIn("function F() {} Object.getPrototypeOf(F.prototype) === Object.prototype")).boolean);
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
    try std.testing.expect((try evalIn("Object.getPrototypeOf(Reflect) === Object.prototype")).boolean);
    try expectEvalStr("Reflect", "Reflect[Symbol.toStringTag]");
    // apply/construct accept an array-like (not just a real Array) argumentsList.
    try std.testing.expectEqual(@as(f64, 2), (try evalIn(
        \\Reflect.apply(function () { return arguments.length; }, null, { length: 2, 0: 'a', 1: 'b' })
    )).number);
    try std.testing.expectEqual(@as(f64, 5), (try evalIn(
        \\function P(a, b) { this.sum = a + b; }
        \\Reflect.construct(P, { length: 2, 0: 2, 1: 3 }).sum
    )).number);
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
    // setPrototypeOf returns a boolean: true on success, false (not a throw) on
    // a non-extensible target.
    try std.testing.expect((try evalIn("Reflect.setPrototypeOf({}, null)")).boolean);
    try std.testing.expect(!(try evalIn(
        \\var o = {}; Object.preventExtensions(o);
        \\Reflect.setPrototypeOf(o, { a: 1 })
    )).boolean);
}

test "NativeError constructors inherit from Error; Error from Function.prototype" {
    // Each NativeError constructor's [[Prototype]] is the Error constructor.
    try std.testing.expect((try evalIn("Object.getPrototypeOf(TypeError) === Error")).boolean);
    try std.testing.expect((try evalIn("Object.getPrototypeOf(RangeError) === Error")).boolean);
    try std.testing.expect((try evalIn("Object.getPrototypeOf(AggregateError) === Error")).boolean);
    // Error itself is a function, so its [[Prototype]] is Function.prototype.
    try std.testing.expect((try evalIn("Object.getPrototypeOf(Error) === Function.prototype")).boolean);
    // The prototype chain was already linked: TypeError.prototype -> Error.prototype.
    try std.testing.expect((try evalIn("Object.getPrototypeOf(TypeError.prototype) === Error.prototype")).boolean);
    // Static inheritance through the constructor chain works.
    try std.testing.expect((try evalIn("typeof TypeError.isError === 'function'")).boolean);
}

test "parseInt skips the full StrWhiteSpace set" {
    // U+2028/U+2029 line separators and non-ASCII spaces are leading whitespace.
    try std.testing.expectEqual(@as(f64, 1), (try evalIn("parseInt('\\u20281')")).number);
    try std.testing.expectEqual(@as(f64, 1), (try evalIn("parseInt('\\u20291')")).number);
    try std.testing.expectEqual(@as(f64, 42), (try evalIn("parseInt('\\u00A0\\u000B42')")).number);
    try std.testing.expectEqual(@as(f64, 255), (try evalIn("parseInt('  0xff')")).number);
}

test "parseFloat: Unicode whitespace, Infinity, and no numeric separators" {
    // Leading StrWhiteSpace (incl. VT/FF/NBSP) is skipped, like `1.1`.
    try std.testing.expectEqual(@as(f64, 1.1), (try evalIn("parseFloat('\\u000B\\u000C\\u00A01.1')")).number);
    // Longest StrDecimalLiteral prefix; trailing junk and `_` separators stop it.
    try std.testing.expectEqual(@as(f64, 3.14), (try evalIn("parseFloat('3.14abc')")).number);
    try std.testing.expectEqual(@as(f64, 1), (try evalIn("parseFloat('1_0')")).number);
    try std.testing.expectEqual(@as(f64, 1e100), (try evalIn("parseFloat('1e+100')")).number);
    // Signed Infinity, and a bare `e` is not part of the number.
    try std.testing.expect(std.math.isInf((try evalIn("parseFloat('-Infinity')")).number));
    try std.testing.expectEqual(@as(f64, 1), (try evalIn("parseFloat('1e')")).number);
    try std.testing.expect(std.math.isNan((try evalIn("parseFloat('.e5')")).number));
    try std.testing.expectEqual(@as(f64, 1), (try evalIn("parseFloat('0.1e1' + String.fromCharCode(0x0130))")).number);
    try std.testing.expectEqual(@as(f64, 0), (try evalIn("parseFloat({ valueOf: function() { return 1; }, toString: function() { return 0; } })")).number);
    try std.testing.expectEqual(@as(f64, 1), (try evalIn("parseFloat({ valueOf: function() { return 1; }, toString: function() { return {}; } })")).number);
    try std.testing.expectError(error.Throw, evalIn("parseFloat({ valueOf: function() { return 1; }, toString: function() { throw 'error'; } })"));
}

test "parseInt radix coercion follows ToInt32" {
    try std.testing.expectEqual(@as(f64, 3), (try evalIn("parseInt('11', 4294967298)")).number);
    try std.testing.expectEqual(@as(f64, 3), (try evalIn("parseInt('11', -4294967294)")).number);
    try std.testing.expect(std.math.isNan((try evalIn("parseInt('0', 1)")).number));
    try std.testing.expect(std.math.isNan((try evalIn("parseInt('0', 37)")).number));
    try std.testing.expectEqual(@as(f64, 1), (try evalIn("parseInt('0x1', 0)")).number);
    try std.testing.expectEqual(@as(f64, 3), (try evalIn("parseInt('11', { valueOf: function() { return 2; }, toString: function() { throw 'error'; } })")).number);
}

test "URI encode/decode handles surrogate pairs" {
    try expectEvalStr("%F0%90%80%80", "encodeURI(String.fromCharCode(0xD800, 0xDC00))");
    try expectEvalStr("%F4%8F%BF%BF", "encodeURIComponent(String.fromCharCode(0xDBFF, 0xDFFF))");
    try std.testing.expect((try evalIn("decodeURI('%F0%90%80%80') === String.fromCharCode(0xD800, 0xDC00)")).boolean);
    try std.testing.expect((try evalIn("decodeURIComponent('%F4%8F%BF%BF') === String.fromCharCode(0xDBFF, 0xDFFF)")).boolean);
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
    )).boolean);
    try std.testing.expect((try evalIn(
        \\var buffer = new ArrayBuffer(8);
        \\var called = false;
        \\var byteOffset = { valueOf: function() { called = true; return 0; } };
        \\var newTarget = function() {}.bind(null);
        \\Object.defineProperty(newTarget, "prototype", { get: function() { $262.detachArrayBuffer(buffer); return DataView.prototype; } });
        \\var ok = false;
        \\try { Reflect.construct(DataView, [buffer, byteOffset], newTarget); } catch (e) { ok = e instanceof TypeError; }
        \\ok && called
    )).boolean);
    try std.testing.expect((try evalIn(
        \\var buffer = new ArrayBuffer(3, { maxByteLength: 3 });
        \\var newTarget = function() {}.bind(null);
        \\Object.defineProperty(newTarget, "prototype", { get: function() { buffer.resize(2); } });
        \\var view = Reflect.construct(DataView, [buffer, 2], newTarget);
        \\view.byteLength === 0
    )).boolean);
    try std.testing.expect((try evalIn(
        \\var buffer = new ArrayBuffer(3, { maxByteLength: 3 });
        \\var newTarget = function() {}.bind(null);
        \\Object.defineProperty(newTarget, "prototype", { get: function() { buffer.resize(2); } });
        \\var ok = false;
        \\try { Reflect.construct(DataView, [buffer, 1, 2], newTarget); } catch (e) { ok = e instanceof RangeError; }
        \\ok
    )).boolean);
}

test "isFinite / isNaN coerce via ToNumber (Symbol throws, strings convert)" {
    // `Let num be ? ToNumber(number)`: strings/booleans convert, a Symbol throws.
    try std.testing.expect((try evalIn("isFinite('0')")).boolean);
    try std.testing.expect(!(try evalIn("isFinite('Infinity')")).boolean);
    try std.testing.expect((try evalIn("isNaN('not a number')")).boolean);
    try std.testing.expect(!(try evalIn("isNaN('42')")).boolean);
    try std.testing.expectError(error.Throw, evalIn("isFinite(Symbol())"));
    try std.testing.expectError(error.Throw, evalIn("isNaN(Symbol())"));
}

test "Number string conversion trims ECMAScript whitespace" {
    try std.testing.expectEqual(@as(f64, 0), (try evalIn("Number('\\u00A0\\u1680\\u2000\\u2028\\u2029\\u202F\\u205F\\u3000')")).number);
    try std.testing.expectEqual(@as(f64, 1234567890), (try evalIn(
        \\Number('\u000B\u00A0\u1680\u20001234567890\u2028\u2029\u202F\u205F\u3000')
    )).number);
    try std.testing.expect((try evalIn(
        \\Number('\u00A0\u2000Infinity\u202F') === Infinity
    )).boolean);
    try std.testing.expect((try evalIn(
        \\Number('\u00A0\u2000-Infinity\u202F') === -Infinity
    )).boolean);
}

test "strict arguments.callee is the %ThrowTypeError% poison pill" {
    // Reading or writing `arguments.callee` in a strict function throws TypeError,
    // and its accessor get is the single shared %ThrowTypeError% intrinsic.
    try std.testing.expect((try evalIn(
        \\function f() { "use strict"; try { arguments.callee; return false; } catch (e) { return e instanceof TypeError; } }
        \\f()
    )).boolean);
    // The same intrinsic backs both `arguments.callee` and `Function.prototype.caller`.
    try std.testing.expect((try evalIn(
        \\var g = function () { "use strict"; return arguments; }();
        \\var callee = Object.getOwnPropertyDescriptor(g, "callee").get;
        \\var caller = Object.getOwnPropertyDescriptor(Function.prototype, "caller").get;
        \\callee === caller
    )).boolean);
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
    )).number);
}

test "function objects inherit from Function.prototype" {
    // A user function links to `Function.prototype`, so instanceof, the
    // prototype identity, and inherited methods all resolve through the chain.
    try std.testing.expect((try evalIn("function f() {} f instanceof Function")).boolean);
    try std.testing.expect((try evalIn("var g = () => {}; g instanceof Function")).boolean);
    try std.testing.expect((try evalIn(
        \\function f() {}
        \\Object.getPrototypeOf(f) === Function.prototype
    )).boolean);
    // The inherited `call` is the same function object reached via the chain.
    try std.testing.expect((try evalIn("function f() {} f.call === Function.prototype.call")).boolean);
}

test "dynamic Function observes NewTarget and constructor realms" {
    try std.testing.expect((try evalIn(
        \\var other = $262.createRealm().global;
        \\var C = new other.Function();
        \\C.prototype = null;
        \\Object.getPrototypeOf(Reflect.construct(Function, [], C)) === other.Function.prototype
    )).boolean);
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
    )).boolean);
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
    )).boolean);
    try std.testing.expect((try evalIn(
        \\async function f() {}
        \\f.prototype === undefined && !f.hasOwnProperty('prototype')
    )).boolean);
}

test "dynamic generator functions validate params and prototype realms" {
    try std.testing.expect((try evalIn(
        \\var GeneratorFunction = Object.getPrototypeOf(function*() {}).constructor;
        \\var ok = false;
        \\try { GeneratorFunction('x = yield', ''); } catch (e) { ok = e instanceof SyntaxError; }
        \\ok
    )).boolean);
    try std.testing.expect((try evalIn(
        \\var AsyncGeneratorFunction = Object.getPrototypeOf(async function*() {}).constructor;
        \\var ok = false;
        \\try { AsyncGeneratorFunction('x = yield', ''); } catch (e) { ok = e instanceof SyntaxError; }
        \\ok
    )).boolean);
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
    )).boolean);
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
    )).boolean);
}

test "Iterator constructor uses NewTarget realm prototype fallback" {
    try std.testing.expect((try evalIn(
        \\var other = $262.createRealm().global;
        \\var C = new other.Function();
        \\C.prototype = null;
        \\Object.getPrototypeOf(Reflect.construct(Iterator, [], C)) === other.Iterator.prototype
    )).boolean);
}

test "Date call remains string-returning through bind" {
    try std.testing.expect((try evalIn("typeof Date(0, 0, 0) === 'string'")).boolean);
    try std.testing.expect((try evalIn("typeof Date.bind(null)(0, 0, 0) === 'string'")).boolean);
}

test "ordinary toPrimitive calls borrowed native toString methods" {
    try std.testing.expectError(error.Throw, evalIn(
        \\String({ toString: Function.prototype.toString })
    ));
    try std.testing.expect((try evalIn(
        \\String(Function.prototype).indexOf("[native code]") >= 0
    )).boolean);
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
    )).boolean);
    // Direct prototype-method access + .call.
    try std.testing.expectEqual(@as(f64, 3), (try evalIn(
        \\Array.prototype.indexOf.call([10, 20, 30], 30) + 1
    )).number);
}

test "property descriptors: defineProperty attrs + getOwnPropertyDescriptor" {
    // defineProperty defaults omitted attrs to false; getOwnPropertyDescriptor reports them.
    try std.testing.expect((try evalIn(
        \\var o = {};
        \\Object.defineProperty(o, "x", { value: 5 });
        \\var d = Object.getOwnPropertyDescriptor(o, "x");
        \\d.value === 5 && d.writable === false && d.enumerable === false && d.configurable === false
    )).boolean);
    // A non-writable property ignores assignment (sloppy mode).
    try std.testing.expectEqual(@as(f64, 5), (try evalIn(
        \\var o = {};
        \\Object.defineProperty(o, "x", { value: 5, writable: false });
        \\o.x = 99;
        \\o.x
    )).number);
    // Non-enumerable property is skipped by Object.keys / for-in but kept by getOwnPropertyNames.
    try std.testing.expect((try evalIn(
        \\var o = { a: 1 };
        \\Object.defineProperty(o, "hidden", { value: 2, enumerable: false });
        \\Object.keys(o).length === 1 && Object.getOwnPropertyNames(o).length === 2 &&
        \\  !o.propertyIsEnumerable("hidden") && o.propertyIsEnumerable("a")
    )).boolean);
    // Plain-assignment properties are writable/enumerable/configurable.
    try std.testing.expect((try evalIn(
        \\var o = { a: 1 };
        \\var d = Object.getOwnPropertyDescriptor(o, "a");
        \\d.writable && d.enumerable && d.configurable
    )).boolean);
}

test "Object.getOwnPropertySymbols rejects nullish inputs" {
    try std.testing.expect((try evalIn(
        \\var count = 0;
        \\try { Object.getOwnPropertySymbols(undefined); } catch (e) { count += e instanceof TypeError ? 1 : 0; }
        \\try { Object.getOwnPropertySymbols(null); } catch (e) { count += e instanceof TypeError ? 1 : 0; }
        \\count === 2 && Object.getOwnPropertySymbols(1).length === 0
    )).boolean);
}

test "global object writes update object-backed global bindings" {
    try std.testing.expect((try evalIn(
        \\var original = Object;
        \\function fakeObject() {}
        \\globalThis.Object = fakeObject;
        \\var ok = Object === fakeObject && globalThis.Object === fakeObject;
        \\globalThis.Object = original;
        \\ok && Object === original
    )).boolean);
}

test "Object.freeze / seal / preventExtensions" {
    // freeze: writes ignored, not extensible, isFrozen true.
    try std.testing.expect((try evalIn(
        \\var o = { a: 1 };
        \\Object.freeze(o);
        \\o.a = 2; o.b = 3;
        \\o.a === 1 && o.b === undefined && Object.isFrozen(o) && !Object.isExtensible(o)
    )).boolean);
    // seal: existing writable, but no new props, isSealed true (not frozen).
    try std.testing.expect((try evalIn(
        \\var o = { a: 1 };
        \\Object.seal(o);
        \\o.a = 9; o.b = 3;
        \\o.a === 9 && o.b === undefined && Object.isSealed(o) && !Object.isFrozen(o)
    )).boolean);
    // preventExtensions: can't add, can still modify.
    try std.testing.expect((try evalIn(
        \\var o = { a: 1 };
        \\Object.preventExtensions(o);
        \\o.b = 3; o.a = 5;
        \\o.a === 5 && o.b === undefined && !Object.isExtensible(o)
    )).boolean);
    // empty frozen object is frozen.
    try std.testing.expect((try evalIn("Object.isFrozen(Object.freeze({}))")).boolean);
}

test "Object.prototype: hasOwnProperty / isPrototypeOf" {
    try std.testing.expect((try evalIn(
        \\var o = { a: 1 }; o.hasOwnProperty("a")
    )).boolean);
    try std.testing.expect(!(try evalIn(
        \\var o = { a: 1 }; o.hasOwnProperty("b")
    )).boolean);
    try std.testing.expect((try evalIn(
        \\var a = [1, 2, 3]; a.hasOwnProperty("length") && a.hasOwnProperty(0) && !a.hasOwnProperty(9)
    )).boolean);
}

test "generators: manual next() yields values then done" {
    try std.testing.expectEqual(@as(f64, 6), (try evalIn(
        \\function* g() { yield 1; yield 2; yield 3; }
        \\var it = g();
        \\var a = it.next().value, b = it.next().value, c = it.next().value;
        \\a + b + c
    )).number);
    // After exhaustion, next().done is true and value undefined.
    try std.testing.expect((try evalIn(
        \\function* g() { yield 1; }
        \\var it = g(); it.next();
        \\it.next().done
    )).boolean);
}

test "generators: for-of drives the generator" {
    try std.testing.expectEqual(@as(f64, 30), (try evalIn(
        \\function* g() { yield 10; yield 20; }
        \\var s = 0; for (var x of g()) { s += x; } s
    )).number);
}

test "generators: next(v) is the value of the resumed yield" {
    try std.testing.expectEqual(@as(f64, 15), (try evalIn(
        \\function* g() { var x = yield 1; yield x + 10; }
        \\var it = g(); it.next(); it.next(5).value
    )).number);
}

test "generators: infinite generator bounded by the consumer" {
    try std.testing.expectEqual(@as(f64, 2), (try evalIn(
        \\function* nat() { var i = 0; while (true) { yield i; i = i + 1; } }
        \\var it = nat(); it.next(); it.next(); it.next().value
    )).number);
}

test "generators: yield* delegates to arrays, strings, and generators" {
    // Delegate to an array.
    try std.testing.expectEqual(@as(f64, 6), (try evalIn(
        \\function* g() { yield* [1, 2, 3]; }
        \\var s = 0; for (var x of g()) { s += x; } s
    )).number);
    // Delegate to another generator, interleaved with own yields.
    try std.testing.expectEqual(@as(f64, 6), (try evalIn(
        \\function* inner() { yield 1; yield 2; }
        \\function* outer() { yield 0; yield* inner(); yield 3; }
        \\var s = 0; for (var x of outer()) { s += x; } s
    )).number);
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
    )).number);
}

test "generators: a return value finishes with done:true" {
    try std.testing.expectEqual(@as(f64, 99), (try evalIn(
        \\function* g() { yield 1; return 99; }
        \\var it = g(); it.next(); it.next().value
    )).number);
}

test "generators: locals persist across yields, closures captured" {
    try std.testing.expectEqual(@as(f64, 3), (try evalIn(
        \\var base = 1;
        \\function* g() { var n = base; yield n; n = n + 1; yield n; }
        \\var it = g(); it.next(); it.next().value + base
    )).number);
}

test "generators: BigInt literal yields feed BigInt typed arrays" {
    try std.testing.expect((try evalIn(
        \\function* g() { yield 7n; yield 42n; }
        \\var ta = new BigInt64Array(g());
        \\ta.length === 2 && ta[0] === 7n && ta[1] === 42n;
    )).boolean);
}

test "identifiers: unicode escapes decode to the canonical name" {
    // \uXXXX in an identifier resolves to the same name written literally.
    try std.testing.expectEqual(@as(f64, 1), (try evalIn("var \\u0061 = 1; a")).number);
    // \u{...} code-point escape form.
    try std.testing.expectEqual(@as(f64, 2), (try evalIn("var \\u{62} = 2; b")).number);
    // Escape in a non-leading position: `fo` is the identifier `fo`.
    try std.testing.expectEqual(@as(f64, 3), (try evalIn("var f\\u006f = 3; fo")).number);
}

test "identifiers: raw non-ASCII Unicode letters" {
    // Greek + a letter-like symbol used as identifiers.
    try std.testing.expectEqual(@as(f64, 7), (try evalIn("var \u{03C0} = 7; \u{03C0}")).number);
    try std.testing.expectEqual(@as(f64, 8), (try evalIn("var caf\u{00E9} = 8; caf\u{00E9}")).number);
}

test "whitespace: vertical tab, form feed, NBSP, and U+2028 separate tokens" {
    try std.testing.expectEqual(@as(f64, 3), (try evalIn("var\u{0B}x\u{0C}=\u{00A0}1\u{2028}x + 2")).number);
}

test "hashbang comment at start of source is ignored" {
    try std.testing.expectEqual(@as(f64, 5), (try evalIn("#!/usr/bin/env node\nvar x = 5; x")).number);
}

test "async: declarations/expressions/arrows/methods parse; never-called is valid" {
    // A never-called async function is fully valid (parses + binds).
    try std.testing.expectEqual(@as(f64, 1), (try evalIn("async function f() { await 1; return 2; } 1")).number);
    // async function expression, async arrow, async method — all parse.
    try std.testing.expectEqual(@as(f64, 1), (try evalIn("var f = async function () { return await g(); }; 1")).number);
    try std.testing.expectEqual(@as(f64, 1), (try evalIn("var f = async (a, b) => await a + b; 1")).number);
    try std.testing.expectEqual(@as(f64, 1), (try evalIn("var f = async x => await x; 1")).number);
    try std.testing.expectEqual(@as(f64, 1), (try evalIn("var o = { async m() { return await 1; } }; 1")).number);
    try std.testing.expectEqual(@as(f64, 1), (try evalIn("class C { async m() { await this.x; } static async s() {} } 1")).number);
    // async generator parses.
    try std.testing.expectEqual(@as(f64, 1), (try evalIn("async function* ag() { yield await 1; } 1")).number);
    try expectEvalStr("[Symbol.asyncIterator]", "async function* g() {} Object.getPrototypeOf(Object.getPrototypeOf(g.prototype))[Symbol.asyncIterator].name");
}

test "async/await: suspendable runtime with spec ordering" {
    // An async function returns a Promise.
    try std.testing.expect((try evalIn("(async function () { return 1; })() instanceof Promise")).boolean);
    // The body runs synchronously up to the first `await` (no await here), so a
    // write before any suspension is observable synchronously.
    try std.testing.expectEqual(@as(f64, 7), (try evalIn(
        \\var x = 0;
        \\async function f() { x = 7; return 1; }
        \\f();
        \\x
    )).number);
    // A continuation *after* an `await` runs in a microtask, so it is NOT visible
    // synchronously (it was, incorrectly, under the old synchronous-settling
    // model). The value is verified end-to-end by the test262 async suite.
    try std.testing.expectEqual(@as(f64, 0), (try evalIn(
        \\var result = 0;
        \\async function f() { result = await Promise.resolve(41) + 1; }
        \\f();
        \\result
    )).number);
    try std.testing.expect((try evalIn("Promise.resolve(1) instanceof Promise")).boolean);
    try std.testing.expect((try evalIn(
        \\var other = $262.createRealm().global;
        \\var C = new other.Function();
        \\C.prototype = null;
        \\Object.getPrototypeOf(Reflect.construct(Promise, [function() {}], C)) === other.Promise.prototype
    )).boolean);
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
    )).number);
}

test "array destructuring over the iterator protocol (generator, Set, string, rest)" {
    // Generator.
    try std.testing.expectEqual(@as(f64, 3), (try evalIn(
        \\function* g() { yield 1; yield 2; }
        \\var [a, b] = g(); a + b
    )).number);
    // Set (iterable, not array).
    try std.testing.expectEqual(@as(f64, 30), (try evalIn(
        \\var [a, b] = new Set([10, 20]); a + b
    )).number);
    // Rest collects the tail of a generator.
    try std.testing.expectEqual(@as(f64, 2), (try evalIn(
        \\function* g() { yield 1; yield 2; yield 3; }
        \\var [first, ...rest] = g(); rest.length
    )).number);
    // Default applies when the iterator runs dry.
    try std.testing.expectEqual(@as(f64, 9), (try evalIn(
        \\function* g() { yield 1; }
        \\var [a, b = 9] = g(); b
    )).number);
    // Destructuring a non-iterable still throws a TypeError.
    try std.testing.expect((try evalIn(
        \\var t = false;
        \\try { var [x] = 5; } catch (e) { t = e instanceof TypeError; }
        \\t
    )).boolean);
}

test "ToPrimitive: own valueOf/toString in arithmetic, string, relational" {
    try std.testing.expectEqual(@as(f64, 11), (try evalIn("var o = { valueOf: function () { return 10; } }; o + 1")).number);
    try std.testing.expectEqual(@as(f64, 20), (try evalIn("var o = { valueOf: function () { return 10; } }; o * 2")).number);
    try expectEvalStr("hi!", "var o = { toString: function () { return 'hi'; } }; o + '!'");
    try expectEvalStr("1,2,3", "'' + [1, 2, 3]");
    try expectEvalStr("[object Object]x", "({}) + 'x'");
    try std.testing.expect((try evalIn("var o = { valueOf: function () { return 5; } }; o < 6")).boolean);
    // A class's prototype valueOf/toString is honored too.
    try std.testing.expectEqual(@as(f64, 6), (try evalIn("class C { valueOf() { return 5; } } new C() + 1")).number);
    try expectEvalStr("C!", "class C { toString() { return 'C'; } } new C() + '!'");
}

test "class methods/accessors/constructor are non-enumerable" {
    // Prototype methods are non-enumerable (Object.keys sees only own enumerable).
    try expectEvalStr("", "class C { m() {} n() {} } Object.keys(C.prototype).join(',')");
    try std.testing.expect((try evalIn(
        \\class C { m() {} }
        \\var d = Object.getOwnPropertyDescriptor(C.prototype, 'm');
        \\!d.enumerable && d.writable && d.configurable
    )).boolean);
    // Accessors too.
    try std.testing.expect((try evalIn(
        \\class C { get x() { return 1; } }
        \\!Object.getOwnPropertyDescriptor(C.prototype, 'x').enumerable
    )).boolean);
    // Static methods.
    try expectEvalStr("", "class C { static s() {} } Object.keys(C).join(',')");
    // `constructor` is non-enumerable.
    try std.testing.expect((try evalIn(
        \\class C {}
        \\!Object.getOwnPropertyDescriptor(C.prototype, 'constructor').enumerable
    )).boolean);
    // Instance fields ARE enumerable.
    try expectEvalStr("f", "class C { f = 1; m() {} } Object.keys(new C()).join(',')");
}

test "Array change-by-copy methods (toReversed/toSorted/toSpliced/with)" {
    // toReversed: new array, original untouched.
    try expectEvalStr("3,2,1", "[1,2,3].toReversed().join(',')");
    try std.testing.expect((try evalIn("var a=[1,2,3]; a.toReversed(); a.join(',') === '1,2,3'")).boolean);
    // toSorted with a comparator.
    try expectEvalStr("1,2,3,10", "[10,2,1,3].toSorted(function(a,b){return a-b;}).join(',')");
    try std.testing.expect((try evalIn("var a=[3,1,2]; a.toSorted(); a.join(',') === '3,1,2'")).boolean);
    // with: replaces one index, returns a new array; negative index; RangeError.
    try expectEvalStr("1,9,3", "[1,2,3].with(1,9).join(',')");
    try expectEvalStr("1,2,9", "[1,2,3].with(-1,9).join(',')");
    try std.testing.expect((try evalIn("var t=false; try{[1,2].with(5,0);}catch(e){t=e instanceof RangeError;} t")).boolean);
    // toSpliced: delete + insert into a copy.
    try expectEvalStr("1,9,9,3", "[1,2,3].toSpliced(1,1,9,9).join(',')");
    try std.testing.expect((try evalIn("var a=[1,2,3]; a.toSpliced(0,2); a.length === 3")).boolean);
}

test "defineProperty descriptor validation (accessor+data mix, non-callable get/set)" {
    // Mixing a data field with an accessor field throws TypeError.
    try std.testing.expect((try evalIn(
        \\var t = false;
        \\try { Object.defineProperty({}, 'p', { value: 1, get: function () {} }); }
        \\catch (e) { t = e instanceof TypeError; } t
    )).boolean);
    // A non-callable getter throws TypeError.
    try std.testing.expect((try evalIn(
        \\var t = false;
        \\try { Object.defineProperty({}, 'p', { get: 5 }); } catch (e) { t = e instanceof TypeError; } t
    )).boolean);
    // get: undefined is a valid accessor descriptor (no throw).
    try std.testing.expect((try evalIn(
        \\Object.defineProperty({}, 'p', { get: undefined }); true
    )).boolean);
}

test "array index property attributes (defineProperty honors writable/enumerable)" {
    // Default array element descriptor is all-true.
    try std.testing.expect((try evalIn(
        \\var a = [10];
        \\var d = Object.getOwnPropertyDescriptor(a, 0);
        \\d.value === 10 && d.writable && d.enumerable && d.configurable
    )).boolean);
    // defineProperty can make an element non-writable; a sloppy write is a no-op.
    try std.testing.expectEqual(@as(f64, 10), (try evalIn(
        \\var a = [10];
        \\Object.defineProperty(a, 0, { writable: false });
        \\a[0] = 99; a[0]
    )).number);
    // The recorded descriptor is reflected.
    try std.testing.expect((try evalIn(
        \\var a = [10];
        \\Object.defineProperty(a, 0, { writable: false, enumerable: false });
        \\var d = Object.getOwnPropertyDescriptor(a, 0);
        \\!d.writable && !d.enumerable
    )).boolean);
    // defineProperty can set a new value on a configurable element.
    try std.testing.expectEqual(@as(f64, 7), (try evalIn(
        \\var a = [1];
        \\Object.defineProperty(a, 0, { value: 7 });
        \\a[0]
    )).number);
    // A non-configurable element cannot be deleted (sloppy: delete returns false).
    try std.testing.expect((try evalIn(
        \\var a = [1];
        \\Object.defineProperty(a, 0, { configurable: false });
        \\var ok = delete a[0];
        \\!ok && a[0] === 1
    )).boolean);
}

test "Object.keys/values/entries enumerate array indices" {
    try expectEvalStr("0,1,2", "Object.keys([10, 20, 30]).join(',')");
    try std.testing.expectEqual(@as(f64, 60), (try evalIn("Object.values([10, 20, 30]).reduce(function(a,b){return a+b;}, 0)")).number);
    try std.testing.expectEqual(@as(f64, 2), (try evalIn("Object.entries([7, 8]).length")).number);
    try expectEvalStr("0,7", "Object.entries([7, 8])[0].join(',')");
    // A non-enumerable index is skipped.
    try expectEvalStr("1", "var a = [10, 20]; Object.defineProperty(a, 0, { enumerable: false }); Object.keys(a).join(',')");
}

test "sloppy-mode property set on a primitive is a no-op; null/undefined throws" {
    // No-op on a primitive: doesn't throw, doesn't store.
    try std.testing.expectEqual(@as(f64, 1), (try evalIn("var n = 5; n.foo = 1; n.foo === undefined ? 1 : 0")).number);
    try std.testing.expectEqual(@as(f64, 1), (try evalIn("'str'.x = 1; 1")).number);
    try std.testing.expectEqual(@as(f64, 1), (try evalIn("true.y = 1; 1")).number);
    // null / undefined still throw a TypeError.
    try std.testing.expect((try evalIn(
        \\var t = false;
        \\try { var o = null; o.x = 1; } catch (e) { t = e instanceof TypeError; }
        \\t
    )).boolean);
    try std.testing.expect((try evalIn(
        \\var t = false;
        \\try { var o; o.x = 1; } catch (e) { t = e instanceof TypeError; }
        \\t
    )).boolean);
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
    try std.testing.expect((try evalIn("Symbol.for('x') === Symbol.for('x')")).boolean);
    // A registry symbol is distinct from a plain Symbol() of the same desc.
    try std.testing.expect((try evalIn("Symbol.for('y') !== Symbol('y')")).boolean);
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
    )).boolean);
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
    )).number);
    // Object-pattern parameter.
    try std.testing.expectEqual(@as(f64, 7), (try evalIn(
        \\function* g({ x, y }) { yield x + y; }
        \\g({ x: 3, y: 4 }).next().value
    )).number);
    // Default parameter (evaluated at generator creation).
    try std.testing.expectEqual(@as(f64, 5), (try evalIn(
        \\function* g(a = 5) { yield a; }
        \\g().next().value
    )).number);
    // Rest parameter.
    try std.testing.expectEqual(@as(f64, 3), (try evalIn(
        \\function* g(first, ...rest) { yield rest.length; }
        \\g(0, 1, 2, 3).next().value
    )).number);
    // Generator method with a destructuring parameter (the class/dstr family).
    try std.testing.expectEqual(@as(f64, 30), (try evalIn(
        \\var o = { *m([a, b]) { yield a + b; } };
        \\o.m([10, 20]).next().value
    )).number);
}

test "Set/Map are iterable: for-of, spread, Array.from, destructuring" {
    // for-of over a Set.
    try std.testing.expectEqual(@as(f64, 6), (try evalIn(
        \\var s = 0; for (var x of new Set([1, 2, 3])) s += x; s
    )).number);
    // Spread a Set into an array.
    try std.testing.expectEqual(@as(f64, 3), (try evalIn("[...new Set([1, 2, 2, 3])].length")).number);
    // Map yields [k, v] pairs; destructure them in a for-of head.
    try std.testing.expectEqual(@as(f64, 33), (try evalIn(
        \\var m = new Map(); m.set('a', 11); m.set('b', 22);
        \\var t = 0; for (var [k, v] of m) t += v; t
    )).number);
    // Array.from over a Set.
    try std.testing.expectEqual(@as(f64, 2), (try evalIn("Array.from(new Set([5, 5, 9])).length")).number);
}

test "eval: direct eval runs in the caller's scope" {
    // Returns the completion value of the program.
    try std.testing.expectEqual(@as(f64, 3), (try evalIn("eval('1 + 2')")).number);
    // Reads a binding from the surrounding scope.
    try std.testing.expectEqual(@as(f64, 42), (try evalIn("var x = 42; eval('x')")).number);
    // Mutates a binding in the surrounding scope.
    try std.testing.expectEqual(@as(f64, 9), (try evalIn("var x = 1; eval('x = 9'); x")).number);
    // Introduces a new binding visible after the eval.
    try std.testing.expectEqual(@as(f64, 7), (try evalIn("eval('var y = 7;'); y")).number);
    // A non-string argument is returned unchanged.
    try std.testing.expectEqual(@as(f64, 5), (try evalIn("eval(5)")).number);
    // A syntax error in the source throws a SyntaxError.
    try std.testing.expect((try evalIn(
        \\var t = false;
        \\try { eval('var ='); } catch (e) { t = e instanceof SyntaxError; }
        \\t
    )).boolean);
    try std.testing.expect((try evalIn(
        \\var t = false, o = {};
        \\try { eval('o.#f'); } catch (e) { t = e instanceof SyntaxError; }
        \\t
    )).boolean);
}

test "async: `async` remains usable as an ordinary identifier" {
    try std.testing.expectEqual(@as(f64, 3), (try evalIn("var async = 1; async + 2")).number);
    // `async` as a property name / shorthand / method name (not a modifier).
    try std.testing.expectEqual(@as(f64, 7), (try evalIn("var o = { async: 7 }; o.async")).number);
    try std.testing.expectEqual(@as(f64, 5), (try evalIn("var o = { async() { return 5; } }; o.async()")).number);
    // `async` called as a function.
    try std.testing.expectEqual(@as(f64, 9), (try evalIn("function async(x) { return x; } async(9)")).number);
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
    )).boolean);
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
    )).boolean);
    try std.testing.expect((try evalIn(
        \\var source = new ArrayBuffer(10, { maxByteLength: 10 });
        \\var start = { valueOf() { source.resize(9); return -7; } };
        \\var end = { valueOf() { source.resize(5); return -4; } };
        \\try {
        \\  source.sliceToImmutable(start, end);
        \\} catch (e) {
        \\  e instanceof RangeError;
        \\}
    )).boolean);
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
    )).boolean);
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
    )).boolean);
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
    )).boolean);
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
    )).boolean);
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
    )).boolean);
    try std.testing.expect((try evalIn(
        \\var target = new BigInt64Array([0n, 0n]);
        \\var receiver = new BigInt64Array([1n]);
        \\Reflect.set(target, 1, { valueOf() { throw new Error("coerce"); } }, receiver) === false &&
        \\target[1] === 0n &&
        \\receiver.hasOwnProperty(1) === false;
    )).boolean);
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
    )).boolean);
}

test "TypedArray constructor copies live source typed array length" {
    try std.testing.expect((try evalIn(
        \\var rab = new ArrayBuffer(16, { maxByteLength: 32 });
        \\var source = new Uint8Array(rab, 4);
        \\new Uint8Array(rab).set([1, 2, 3, 4, 5, 6]);
        \\rab.resize(8);
        \\var copy = new Uint8Array(source);
        \\copy.length === 4 && copy[0] === 5 && copy[1] === 6 && copy[2] === 0 && copy[3] === 0;
    )).boolean);
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
    )).boolean);
}

test "TypedArray toString shares Array.prototype function object" {
    try std.testing.expect((try evalIn(
        \\var proto = Object.getPrototypeOf(Uint8Array.prototype);
        \\var sample = new Uint8Array([1, 2]);
        \\proto.toString === Array.prototype.toString &&
        \\sample.toString() === "1,2";
    )).boolean);
    try std.testing.expect((try evalIn(
        \\var sample = new Uint8Array([1]);
        \\$262.detachArrayBuffer(sample.buffer);
        \\try {
        \\  sample.toString();
        \\} catch (e) {
        \\  e instanceof TypeError;
        \\}
    )).boolean);
}

test "TypedArray default sort orders negative zero before positive zero" {
    try std.testing.expect((try evalIn(
        \\var sample = new Float64Array([1, 0, -0, 2]).sort();
        \\Object.is(sample[0], -0) && Object.is(sample[1], 0) &&
        \\sample[2] === 1 && sample[3] === 2;
    )).boolean);
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
    )).boolean);
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
    )).boolean);
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
    )).boolean);
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
    );
}

test "Thread blocking APIs respect the main can-block gate" {
    const agent = @import("agent.zig");
    const ctx = try Context.createWith(std.testing.allocator, .{ .enable_threads = true });
    defer ctx.destroy();

    const saved_can_block = agent.main_can_block;
    agent.main_can_block = false;
    defer agent.main_can_block = saved_can_block;

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
    try std.testing.expectEqual(@as(f64, 80003), result.number);
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
    try std.testing.expectEqual(@as(f64, 4), r.number); // 1 + 3
}
