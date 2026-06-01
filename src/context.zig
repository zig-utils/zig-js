const std = @import("std");
const interp = @import("interpreter.zig");
const ast = @import("ast.zig");
const value = @import("value.zig");
const compiler = @import("compiler.zig");
const vm = @import("vm.zig");
const Shape = @import("shape.zig").Shape;
const Parser = @import("parser.zig").Parser;

pub const RunError = interp.EvalError || @import("parser.zig").ParseError;

/// An isolated engine instance — the homegrown analogue of a JSC
/// `JSGlobalContextRef`. Owns an arena for all interpreter-lived allocations
/// (AST, strings, objects, boxed values) and a persistent global environment
/// so variables survive across `evaluate` calls, like a real global context.
pub const Context = struct {
    gpa: std.mem.Allocator,
    arena_state: *std.heap.ArenaAllocator,
    env: interp.Environment,
    global_object: *value.Object,
    /// The empty root shape every object in this context transitions from.
    root_shape: *Shape,
    exception: ?value.Value = null,
    /// The microtask queue (Promise reactions) and the `print` output buffer —
    /// persistent across `evaluate` calls, shared with each `Interpreter`.
    microtasks: std.ArrayListUnmanaged(@import("promise.zig").Microtask) = .empty,
    print_buffer: std.ArrayListUnmanaged(u8) = .empty,
    /// TDZ sentinel for uninitialized let/const bindings.
    tdz_marker: *value.Object,

    pub fn create(gpa: std.mem.Allocator) !*Context {
        const arena_state = try gpa.create(std.heap.ArenaAllocator);
        arena_state.* = std.heap.ArenaAllocator.init(gpa);
        errdefer {
            arena_state.deinit();
            gpa.destroy(arena_state);
        }
        const a = arena_state.allocator();

        const global_obj = try a.create(value.Object);
        global_obj.* = .{};

        // A unique sentinel object marking a `let`/`const` binding in its
        // temporal dead zone (declared but not yet initialized).
        const tdz = try a.create(value.Object);
        tdz.* = .{};

        const self = try gpa.create(Context);
        self.* = .{
            .gpa = gpa,
            .arena_state = arena_state,
            .env = .{ .arena = a, .fn_scope = true }, // global is a variable scope
            .global_object = global_obj,
            .root_shape = try Shape.createRoot(a),
            .tdz_marker = tdz,
        };
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
        };
    }

    pub fn destroy(self: *Context) void {
        self.arena_state.deinit();
        self.gpa.destroy(self.arena_state);
        self.gpa.destroy(self);
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
    pub fn evaluate(self: *Context, source: []const u8) RunError!value.Value {
        const a = self.arena();
        var parser = try Parser.init(a, source);
        const prog = try parser.parseProgram();
        var machine = self.interpreter();
        // Top-level strictness from the program's directive prologue (the parser
        // leaves `strict` set if it saw a leading `"use strict"`).
        machine.strict = parser.strict;
        self.exception = null;

        const outcome: interp.EvalError!value.Value = if (compiler.Compiler.compileProgram(a, prog)) |chunk|
            vm.run(&machine, chunk, null)
        else |err| switch (err) {
            error.Unsupported => machine.eval(prog), // construct the VM can't lower
            error.OutOfMemory => return error.OutOfMemory,
        };

        // Microtask checkpoint: run queued Promise reactions before returning, so
        // settled `.then`/`await` continuations and the async harness's `$DONE`
        // have executed by the time `evaluate` returns.
        machine.drainMicrotasks() catch {};

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
        var cache: std.StringHashMapUnmanaged(*Module) = .{};
        const root = try self.loadModule(entry_path, entry_source, host, &cache);
        try self.linkModule(root);
        var machine = self.interpreter();
        machine.strict = true;
        // Populate any namespace objects after the whole graph has evaluated, so
        // every exported binding holds its final value.
        const outcome = self.evalModule(&machine, root);
        machine.drainMicrotasks() catch {};
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

        var parser = try Parser.init(a, source);
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
        machine.env = m.env;
        machine.this_value = .undefined; // module top-level `this` is undefined
        defer {
            machine.env = saved_env;
            machine.this_value = saved_this;
        }
        _ = try machine.evalStatements(m.items);
        // Now that bindings hold their final values, populate the namespace
        // object's own properties (a snapshot of the live bindings).
        if (m.ns) |ns| try self.fillNamespace(machine, m, ns);
    }

    /// Build (or return) the namespace exotic object for `module`. Created empty
    /// at link time and filled after the module evaluates.
    fn namespaceObject(self: *Context, module: *Module) RunError!*value.Object {
        if (module.ns) |ns| return ns;
        const a = self.arena();
        const ns = try a.create(value.Object);
        ns.* = .{};
        module.ns = ns;
        return ns;
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
        var it = module.exports.iterator();
        while (it.next()) |e| try self.installNsBinding(ns, module, e.key_ptr.*);
        // Names reachable via `export * from` (default excluded).
        for (module.star_sources.items) |src| {
            var sit = src.exports.iterator();
            while (sit.next()) |e| {
                const name = e.key_ptr.*;
                if (std.mem.eql(u8, name, "default")) continue;
                if (ns.getAccessor(name) != null or ns.getOwn(name) != null) continue;
                try self.installNsBinding(ns, src, name);
            }
        }
        // `[Symbol.toStringTag]` is "Module" — keyed by the well-known symbol's
        // internal key so `ns[Symbol.toStringTag]` (not a string "@@toStringTag")
        // resolves; { !writable, !enumerable, !configurable }.
        const tag_key = machine.wellKnownSymbolKey("toStringTag") orelse "@@toStringTag";
        try ns.setOwn(a, self.root_shape, tag_key, .{ .string = "Module" });
        try ns.setAttr(a, tag_key, .{ .writable = false, .enumerable = false, .configurable = false });
    }

    fn installNsBinding(self: *Context, ns: *value.Object, module: *Module, name: []const u8) interp.EvalError!void {
        const res = resolveExport(module, name, 0) orelse return;
        const a = self.arena();
        const binding = try a.create(NsBinding);
        binding.* = .{ .env = res.env, .name = res.name };
        const getter = try a.create(value.Object);
        getter.* = .{ .native = nsGetter, .private_data = binding };
        try ns.setAccessor(a, name, .{ .object = getter }, null);
        try ns.setAttr(a, name, .{ .enumerable = true, .configurable = false });
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

/// Evaluate `src` in a fresh context and return its completion value. Only safe
/// for by-value results (numbers/booleans); a returned `.string` points into the
/// context arena, so use `expectEvalStr` for those (it compares before teardown).
fn evalIn(src: []const u8) !value.Value {
    const ctx = try Context.create(std.testing.allocator);
    defer ctx.destroy();
    return ctx.evaluate(src);
}

/// Evaluate `src` and assert its string completion value, while the context (and
/// thus the string's backing arena) is still alive.
fn expectEvalStr(expected: []const u8, src: []const u8) !void {
    const ctx = try Context.create(std.testing.allocator);
    defer ctx.destroy();
    const v = try ctx.evaluate(src);
    try std.testing.expectEqualStrings(expected, v.string);
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
    try std.testing.expect((try evalIn("Array.prototype.constructor === Array")).boolean);
    try std.testing.expect((try evalIn("String.prototype.constructor === String")).boolean);
    try std.testing.expect((try evalIn("Number.prototype.constructor === Number")).boolean);
    try std.testing.expect((try evalIn("Function.prototype.constructor === Function")).boolean);
    try std.testing.expect((try evalIn("Date.prototype.constructor === Date")).boolean);
    // `constructor` is non-enumerable.
    try std.testing.expect((try evalIn("Object.keys(Array.prototype).indexOf('constructor') === -1")).boolean);
    // Boolean.prototype now exists with constructor + generic toString/valueOf.
    try expectEvalStr("object", "typeof Boolean.prototype");
    try std.testing.expect((try evalIn("Boolean.prototype.constructor === Boolean")).boolean);
    try expectEvalStr("true", "Boolean.prototype.toString.call(true)");
    try std.testing.expect(!(try evalIn("Boolean.prototype.valueOf.call(false)")).boolean);
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
}

test "async: `async` remains usable as an ordinary identifier" {
    try std.testing.expectEqual(@as(f64, 3), (try evalIn("var async = 1; async + 2")).number);
    // `async` as a property name / shorthand / method name (not a modifier).
    try std.testing.expectEqual(@as(f64, 7), (try evalIn("var o = { async: 7 }; o.async")).number);
    try std.testing.expectEqual(@as(f64, 5), (try evalIn("var o = { async() { return 5; } }; o.async()")).number);
    // `async` called as a function.
    try std.testing.expectEqual(@as(f64, 9), (try evalIn("function async(x) { return x; } async(9)")).number);
}
