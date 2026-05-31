const std = @import("std");
const ast = @import("ast.zig");
const value = @import("value.zig");
const bc = @import("bytecode.zig");
const builtins = @import("builtins.zig");
const regex = @import("regex");
const vm = @import("vm.zig");
const promise = @import("promise.zig");
const Compiler = @import("compiler.zig").Compiler;
const Shape = @import("shape.zig").Shape;
const unicode_case = @import("unicode_case.zig");

const Node = ast.Node;
const Value = value.Value;

/// Robustness limits so adversarial input throws a catchable error instead of
/// crashing the process (stack overflow / runaway loop).
pub const max_call_depth: u32 = 1000;
pub const max_steps: u64 = 100_000_000;

/// Coerce a JS number to a length/index, clamping NaN/negative to 0 and huge
/// values to a cap (so `@intFromFloat` never panics; oversized allocations then
/// fail gracefully as OutOfMemory).
pub fn toLen(n: f64) usize {
    if (std.math.isNan(n) or n <= 0) return 0;
    if (n > 4294967295) return 4294967295;
    return @intFromFloat(@trunc(n));
}

/// True for any ECMAScript WhiteSpace or LineTerminator code point — the exact
/// set `String.prototype.trim`/`trimStart`/`trimEnd` strip.
fn isJsTrimCp(cp: u21) bool {
    return switch (cp) {
        0x0009, 0x000A, 0x000B, 0x000C, 0x000D, 0x0020 => true,
        0x00A0, 0x1680 => true,
        0x2000...0x200A => true,
        0x2028, 0x2029, 0x202F, 0x205F, 0x3000, 0xFEFF => true,
        else => false,
    };
}

/// Trim leading and/or trailing ECMAScript WhiteSpace+LineTerminator code points
/// from `s`. UTF-8 aware: a non-ASCII byte at a boundary is decoded so e.g. NBSP
/// (U+00A0) and the ideographic space (U+3000) are stripped, not just ASCII.
fn jsTrim(s: []const u8, trim_start_: bool, trim_end_: bool) []const u8 {
    var lo: usize = 0;
    var hi: usize = s.len;
    if (trim_start_) {
        while (lo < hi) {
            const c = s[lo];
            const cp_len: usize = if (c < 0x80) 1 else (std.unicode.utf8ByteSequenceLength(c) catch break);
            if (lo + cp_len > hi) break;
            const cp: u21 = if (cp_len == 1) @as(u21, c) else (std.unicode.utf8Decode(s[lo .. lo + cp_len]) catch break);
            if (!isJsTrimCp(cp)) break;
            lo += cp_len;
        }
    }
    if (trim_end_) {
        var last_end: usize = lo;
        var i: usize = lo;
        while (i < hi) {
            const c = s[i];
            const cp_len: usize = if (c < 0x80) 1 else (std.unicode.utf8ByteSequenceLength(c) catch {
                last_end = hi;
                break;
            });
            if (i + cp_len > hi) {
                last_end = hi;
                break;
            }
            const cp: u21 = if (cp_len == 1) @as(u21, c) else (std.unicode.utf8Decode(s[i .. i + cp_len]) catch {
                last_end = i + cp_len;
                i += cp_len;
                continue;
            });
            i += cp_len;
            if (!isJsTrimCp(cp)) last_end = i;
        }
        hi = last_end;
    }
    return s[lo..hi];
}

/// `error.Throw` is the carrier for *any* JS exception: the thrown value lives
/// in `Interpreter.exception`. `error.OutOfMemory` is the only genuine host
/// failure. (ReferenceError/TypeError are no longer Zig errors — they are real,
/// catchable JS `Error` objects raised via `error.Throw`.)
pub const EvalError = error{ OutOfMemory, Throw, OptShortCircuit };

/// A lexical scope with a parent chain. Function calls push a fresh scope whose
/// `parent` is the function's closure environment, which gives real closures.
/// Variable names are duplicated into `arena` on first definition so they
/// outlive the source buffer of any single evaluation.
pub const Environment = struct {
    vars: std.StringHashMapUnmanaged(Value) = .{},
    /// Names in `vars` declared `const` — assigning to them is a TypeError.
    consts: std.StringHashMapUnmanaged(void) = .{},
    /// Names that are *non-strict* immutable bindings — a named function
    /// expression's own name. Reassignment throws in strict code but is a silent
    /// no-op in sloppy code (unlike `const`, which always throws).
    fn_names: std.StringHashMapUnmanaged(void) = .{},
    /// Module *indirect bindings* (`import { x } from "m"`): `local` resolves
    /// live to `name` in another module's environment, so a mutation of the
    /// exporter's binding is visible here. Assigning to one is a TypeError.
    aliases: std.StringHashMapUnmanaged(Alias) = .{},
    arena: std.mem.Allocator,
    parent: ?*Environment = null,
    /// True for a function or the global scope (a *variable* environment); false
    /// for a block `{…}` scope. `var`/function declarations hoist to the nearest
    /// variable environment, while `let`/`const`/`class` bind in the block.
    fn_scope: bool = false,
    /// An object Environment Record for a `with (obj) {…}` block: identifier
    /// resolution at this chain position consults `obj`'s properties (honoring
    /// `Symbol.unscopables`). Because it sits in the lexical chain, a binding
    /// declared *inside* the `with` (innermost) shadows it, and it in turn
    /// shadows outer scopes — and a function defined inside the `with` captures
    /// it through its closure.
    with_object: ?*value.Object = null,

    /// Define (or overwrite) a binding in *this* scope (used by let/const).
    pub fn put(self: *Environment, name: []const u8, v: Value) EvalError!void {
        const gop = try self.vars.getOrPut(self.arena, name);
        if (!gop.found_existing) gop.key_ptr.* = try self.arena.dupe(u8, name);
        gop.value_ptr.* = v;
    }

    /// Define a `const` binding in this scope (marks it immutable for `assign`).
    pub fn putConst(self: *Environment, name: []const u8, v: Value) EvalError!void {
        try self.put(name, v);
        const gop = try self.consts.getOrPut(self.arena, name);
        if (!gop.found_existing) gop.key_ptr.* = try self.arena.dupe(u8, name);
    }

    /// Bind a named function expression's own name (immutable, non-strict).
    pub fn putFnName(self: *Environment, name: []const u8, v: Value) EvalError!void {
        try self.put(name, v);
        const gop = try self.fn_names.getOrPut(self.arena, name);
        if (!gop.found_existing) gop.key_ptr.* = try self.arena.dupe(u8, name);
    }

    /// Whether the nearest binding named `name` is a non-strict immutable
    /// (function-expression name) binding. Matches where `assign` would write.
    pub fn isFnName(self: *Environment, name: []const u8) bool {
        var env: ?*Environment = self;
        while (env) |e| {
            if (e.vars.contains(name)) return e.fn_names.contains(name);
            env = e.parent;
        }
        return false;
    }

    /// Whether the nearest binding named `name` is `const` (null if no binding).
    /// Matches where `assign` would write, so shadowing is handled correctly.
    pub fn isConst(self: *Environment, name: []const u8) ?bool {
        var env: ?*Environment = self;
        while (env) |e| {
            if (e.vars.contains(name)) return e.consts.contains(name);
            env = e.parent;
        }
        return null;
    }

    /// The nearest enclosing variable environment (function or global), where
    /// `var`/function declarations live.
    pub fn varScope(self: *Environment) *Environment {
        var e = self;
        while (!e.fn_scope) {
            e = e.parent orelse return e;
        }
        return e;
    }

    /// Assign to the nearest existing binding (used by `=`); if none exists,
    /// create it on the global (root) scope, matching sloppy-mode semantics.
    pub fn assign(self: *Environment, name: []const u8, v: Value) EvalError!void {
        var env: ?*Environment = self;
        while (env) |e| {
            if (e.vars.getPtr(name)) |ptr| {
                ptr.* = v;
                return;
            }
            env = e.parent;
        }
        var root = self;
        while (root.parent) |p| root = p;
        try root.put(name, v);
    }

    /// An indirect (module import) binding: `name` in module environment `env`.
    pub const Alias = struct { env: *Environment, name: []const u8 };

    /// Install an indirect binding `local` → `target.name` (a module import).
    pub fn putAlias(self: *Environment, local: []const u8, target: *Environment, name: []const u8) EvalError!void {
        const gop = try self.aliases.getOrPut(self.arena, local);
        if (!gop.found_existing) gop.key_ptr.* = try self.arena.dupe(u8, local);
        gop.value_ptr.* = .{ .env = target, .name = try self.arena.dupe(u8, name) };
    }

    /// Whether `name` resolves (in the nearest scope that binds it) to a module
    /// import — an immutable indirect binding.
    pub fn isAlias(self: *Environment, name: []const u8) bool {
        var env: ?*Environment = self;
        while (env) |e| {
            if (e.aliases.contains(name)) return true;
            if (e.vars.contains(name)) return false;
            env = e.parent;
        }
        return false;
    }

    /// Look up a binding, walking outward through enclosing scopes. A module
    /// import (`aliases`) resolves live in its exporting module's environment.
    pub fn get(self: *Environment, name: []const u8) ?Value {
        var env: ?*Environment = self;
        while (env) |e| {
            if (e.aliases.get(name)) |a| return a.env.get(a.name);
            if (e.vars.get(name)) |v| return v;
            env = e.parent;
        }
        return null;
    }
};

/// A JS-defined function value: parameter names, body AST, and the environment
/// captured at definition (the closure). Stored type-erased on `Object.js_func`.
pub const Function = struct {
    params: []const ast.Param,
    body: *ast.Node,
    is_expr_body: bool,
    is_arrow: bool = false,
    closure: *Environment,
    name: []const u8 = "",
    /// Exact source text of the function definition, for `Function.prototype.
    /// toString`. Empty when the parser didn't capture it (then toString falls
    /// back to native-function syntax).
    source: []const u8 = "",
    /// Compiled body for the bytecode VM. Set when the function was created by
    /// the VM (`make_closure`); null for tree-walk-created closures, which are
    /// invoked via `callFunction`.
    chunk: ?*bc.Chunk = null,
    /// VM closure capture: the defining function's frame (type-erased `*vm.Frame`),
    /// for resolving upvalues. Null at the top level. The slot count to allocate
    /// for this function's own frame.
    frame: ?*anyopaque = null,
    local_count: u32 = 0,
    /// Class method support: the object on which this method/constructor lives
    /// (its [[HomeObject]]); `super.x` resolves on `home_object.proto`.
    home_object: ?*value.Object = null,
    /// For a derived class constructor: the superclass object, called by `super(...)`.
    super_ctor: ?*value.Object = null,
    /// `function*`: calling this returns a generator object instead of running
    /// the body. `gen_chunk` is the body compiled for the suspendable VM (null if
    /// the body falls outside the VM's lowered subset — then calling it throws).
    is_generator: bool = false,
    gen_chunk: ?*bc.Chunk = null,
    /// `async function` / `async () => …` (and, with `is_generator`, an async
    /// generator). The Promise + microtask runtime is not yet implemented, so
    /// *calling* an async function throws; it parses and binds like any other
    /// function (a never-called async function is fully valid).
    is_async: bool = false,
    /// A plain async function's body compiled for the suspendable VM, where
    /// `await` is a suspend point driven by promise settlement (null if the body
    /// falls outside the VM's lowered subset → the tree-walker handles it).
    async_chunk: ?*bc.Chunk = null,
    /// Strict-mode function (see `ast.FunctionNode.is_strict`). Gates sloppy-only
    /// behaviors — currently `this`-substitution on a null/undefined receiver.
    is_strict: bool = false,
    /// The `with`-scope chain captured at definition (object environment records
    /// enclosing the function). A function called from inside a `with` does NOT
    /// see the caller's `with` object — only the ones lexically enclosing its own
    /// definition — so the call restores this snapshot for the duration.
    with_stack: []*value.Object = &.{},
};

/// Non-local control flow the tree-walker propagates up the statement list:
/// `ret` unwinds to the enclosing function, `brk`/`cont` to the enclosing loop.
const Signal = enum { none, ret, brk, cont };

/// Tree-walking evaluator. Evaluating a program/block returns the completion
/// value of the last statement, which is what `JSEvaluateScript` hands back.
pub const Interpreter = struct {
    arena: std.mem.Allocator,
    env: *Environment,
    /// The Context-owned microtask queue (Promise reactions). Drained after the
    /// main script in `Context.evaluate` and inline by `await`.
    microtasks: ?*std.ArrayListUnmanaged(promise.Microtask) = null,
    /// The native-function object currently being invoked (set around each
    /// native call), so a native can reach its own `private_data` — used by
    /// Promise executor resolve/reject closures.
    active_native: ?*value.Object = null,
    /// Context-owned buffer the global `print` appends to (the async harness's
    /// `$DONE` reports completion through `print`).
    print_buffer: ?*std.ArrayListUnmanaged(u8) = null,
    /// While binding a destructuring declaration, whether it's a `var` (leaves
    /// hoist to the variable scope) vs `let`/`const` (block-scoped).
    binding_hoisted: bool = false,
    /// While binding a declaration, whether it's `const` (so the bound names are
    /// marked immutable and later assignment throws a TypeError).
    binding_const: bool = false,
    /// Sentinel object for a `let`/`const` binding in its temporal dead zone
    /// (hoisted into scope but not yet initialized). Reading it throws.
    tdz_marker: ?*value.Object = null,
    /// The context's global object — the value of `globalThis` and of top-level
    /// `this`. Global `var`/function bindings also surface as its properties, so
    /// `this.x`, `"x" in globalThis`, and reflection over the global all work.
    global_object: ?*value.Object = null,
    /// The Context's empty root shape — the origin of every object's shape
    /// transition chain (see shape.zig).
    root_shape: *Shape,
    /// Symbol objects indexed by their encoded property key (`sym_key`), so the
    /// original Symbol can be recovered from a stored key — used by
    /// Object.getOwnPropertySymbols and the Proxy traps (which must hand the
    /// Symbol, not its encoded string, to the handler). Populated whenever a
    /// Symbol is used as a property key (see `keyOf`).
    symbols: std.StringHashMapUnmanaged(*value.Object) = .{},
    signal: Signal = .none,
    ret_value: Value = .undefined,
    /// The `this` binding for the currently-executing function (undefined at
    /// top level / in plain calls; the receiver in method calls; the new object
    /// in constructor calls).
    this_value: Value = .undefined,
    /// Whether the currently-executing code is strict mode (set from the
    /// program's directive prologue and each function's `is_strict`). Gates
    /// strict runtime errors: assignment to an undeclared binding or a
    /// non-writable/​non-extensible property throws instead of silently failing.
    strict: bool = false,
    /// The in-flight thrown value while `error.Throw` propagates. Read by
    /// `catch` and by the Context/C-API boundary.
    exception: Value = .undefined,
    /// Target label of a pending labeled `break`/`continue` (null = unlabeled).
    signal_label: ?[]const u8 = null,
    /// Label of the enclosing `labeled_stmt`, handed to the loop it wraps.
    current_label: ?[]const u8 = null,
    /// [[HomeObject]] of the executing method (for `super.x`) and the superclass
    /// constructor of the executing derived constructor (for `super(...)`).
    home_object: ?*value.Object = null,
    super_ctor: ?*value.Object = null,
    /// `new.target`: the constructor of the in-flight `new` call (undefined in a
    /// plain call). Inherited lexically by arrow functions.
    new_target: Value = .undefined,
    /// Active `with` scope objects (innermost last); bare identifiers consult
    /// these before the lexical environment.
    with_stack: std.ArrayListUnmanaged(*value.Object) = .empty,
    /// Robustness counters: function call depth and total evaluation steps.
    depth: u32 = 0,
    steps: u64 = 0,

    // ---- exception helpers ------------------------------------------------

    /// Set a named property on an object via its shape (see `Object.setOwn`).
    fn setProp(self: *Interpreter, obj: *value.Object, key: []const u8, v: Value) EvalError!void {
        try obj.setOwn(self.arena, self.root_shape, key, v);
    }

    /// Bind `name` in the current scope; at global scope (no enclosing
    /// function), also surface it as an own property of the global object —
    /// global `var`/function declarations are own properties of `globalThis`
    /// ({ writable, enumerable, !configurable }), so `hasOwnProperty(globalThis,
    /// name)` and reflection see them (the test262 async harness relies on this).
    pub fn globalDefine(self: *Interpreter, name: []const u8, v: Value) EvalError!void {
        const vs = self.env.varScope(); // `var`/function declarations hoist here
        try vs.put(name, v);
        if (vs.parent == null) {
            if (self.global_object) |g| {
                const existed = g.getOwn(name) != null;
                try self.setProp(g, name, v);
                if (!existed) try g.setAttr(self.arena, name, .{ .writable = true, .enumerable = true, .configurable = false });
            }
        }
    }

    /// The TDZ sentinel as a Value.
    fn tdzVal(self: *Interpreter) Value {
        return .{ .object = self.tdz_marker.? };
    }

    /// Whether `v` is the TDZ sentinel (an uninitialized let/const binding).
    fn isTdz(self: *Interpreter, v: Value) bool {
        return v == .object and self.tdz_marker != null and v.object == self.tdz_marker.?;
    }

    /// Pre-bind every identifier in a destructuring pattern to the TDZ sentinel.
    fn tdzBindPattern(self: *Interpreter, target: *Node, tdz: Value) void {
        switch (target.*) {
            .identifier => |name| self.env.put(name, tdz) catch {},
            .obj_pattern => |p| {
                for (p.props) |pr| self.tdzBindPattern(pr.target, tdz);
                if (p.rest) |r| self.env.put(r, tdz) catch {}; // object rest is a name
            },
            .arr_pattern => |p| {
                for (p.elems) |e| if (e.target) |t| self.tdzBindPattern(t, tdz);
                if (p.rest) |r| self.tdzBindPattern(r, tdz);
            },
            else => {},
        }
    }

    /// An own data property of the global object, used as the fallback for a
    /// bare global reference (`this.x = 1` at top level → bare `x`).
    pub fn globalProp(self: *Interpreter, name: []const u8) ?Value {
        const g = self.global_object orelse return null;
        return g.getOwn(name);
    }

    /// ToObject(v): an object is returned as-is, a primitive is boxed into the
    /// matching wrapper (whose prototype is that constructor's `.prototype`), and
    /// null/undefined throw a TypeError. Used by `with` (and anywhere the spec
    /// says "ToObject").
    pub fn toObject(self: *Interpreter, v: Value) EvalError!*value.Object {
        if (v == .object) return v.object;
        if (v == .null or v == .undefined)
            return self.throwError("TypeError", "Cannot convert undefined or null to object");
        const ctor_name: []const u8 = switch (v) {
            .string => "String",
            .number => "Number",
            .boolean => "Boolean",
            else => unreachable,
        };
        const o = try self.arena.create(value.Object);
        o.* = .{ .prim = v };
        if (self.env.get(ctor_name)) |ctor| {
            if (ctor == .object) o.proto = try self.protoObject(ctor.object);
        }
        return o;
    }

    /// Resolve an identifier through the lexical environment chain, consulting
    /// each scope's bindings (live `import` aliases, then `var`/`let`/`const`),
    /// and — at a `with` object Environment Record — that object's properties, in
    /// chain order. Returns the value, or null when unresolved (the caller then
    /// tries the global object and finally throws a ReferenceError).
    fn lookupIdent(self: *Interpreter, name: []const u8) EvalError!?Value {
        var env: ?*Environment = self.env;
        while (env) |e| {
            if (e.aliases.get(name)) |a| return a.env.get(a.name);
            if (e.vars.get(name)) |v| return v;
            if (e.with_object) |wo| {
                if (try self.withHasBinding(wo, name)) return try self.getProperty(.{ .object = wo }, name);
            }
            env = e.parent;
        }
        return null;
    }

    /// Resolve an identifier *for assignment*: a `with` object that provides the
    /// binding takes the write (returns true); otherwise the caller assigns to
    /// the lexical/global binding. Stops at the first scope (binding or `with`)
    /// that owns `name`.
    fn assignWithObject(self: *Interpreter, name: []const u8) EvalError!?*value.Object {
        var env: ?*Environment = self.env;
        while (env) |e| {
            if (e.aliases.get(name) != null or e.vars.get(name) != null) return null; // a real binding owns it
            if (e.with_object) |wo| {
                if (try self.withHasBinding(wo, name)) return wo;
            }
            env = e.parent;
        }
        return null;
    }

    /// Whether a `with` binding object provides a binding for `name`: it has the
    /// property AND `name` is not listed truthy in the object's
    /// `[Symbol.unscopables]` (which hides selected names from `with` scope).
    pub fn withHasBinding(self: *Interpreter, o: *value.Object, name: []const u8) EvalError!bool {
        if (!hasProperty(o, name)) return false;
        const unsc_key = self.wellKnownSymbolKey("unscopables") orelse return true;
        const unsc = try self.getProperty(.{ .object = o }, unsc_key);
        if (unsc == .object) {
            if ((try self.getProperty(unsc, name)).toBoolean()) return false;
        }
        return true;
    }

    /// Build an `Error`-family instance with `name`/`message` properties.
    fn makeError(self: *Interpreter, name: []const u8, message: []const u8) EvalError!Value {
        const obj = try self.arena.create(value.Object);
        obj.* = .{ .is_error = true, .error_name = name };
        // Link to `<name>.prototype` so `name` (and `toString`) are inherited and
        // `instanceof` / `Object.getPrototypeOf` see a real chain.
        if (self.env.get(name)) |ctor_v| {
            if (ctor_v == .object) {
                if (ctor_v.object.getOwn("prototype")) |proto_v| {
                    if (proto_v == .object) obj.proto = proto_v.object;
                }
            }
        }
        // `message` is an own property only when one was supplied (else inherited,
        // = "" from the prototype); `name` is always inherited from the prototype.
        if (message.len > 0) {
            try self.setProp(obj, "message", .{ .string = message });
            try obj.setAttr(self.arena, "message", .{ .enumerable = false, .configurable = true, .writable = true });
        }
        return .{ .object = obj };
    }

    /// Raise a JS exception of the given error class. Always returns
    /// `error.Throw` (or `error.OutOfMemory` if the error object can't be built).
    pub fn throwError(self: *Interpreter, name: []const u8, message: []const u8) EvalError {
        self.exception = try self.makeError(name, message);
        return error.Throw;
    }

    pub fn eval(self: *Interpreter, node: *const Node) EvalError!Value {
        self.steps += 1;
        if (self.steps > max_steps) return self.throwError("RangeError", "evaluation step budget exceeded");
        return switch (node.*) {
            .number => |n| .{ .number = n },
            .bigint_lit => |b| try self.makeBigInt(b),
            .string => |s| .{ .string = s },
            .boolean => |b| .{ .boolean = b },
            .null_lit => .null,
            .undefined_lit => .undefined,
            .elision => .undefined, // only meaningful inside an array literal
            .this_expr => self.this_value,
            .new_target_expr => self.new_target,
            .identifier => |name| blk: {
                // Walk the lexical chain (bindings and `with` objects in chain
                // order), so a `with` object shadows outer scopes but is itself
                // shadowed by any binding more local than it.
                if (try self.lookupIdent(name)) |v| {
                    if (self.isTdz(v)) return self.throwError("ReferenceError", name); // accessed in its TDZ
                    break :blk v;
                }
                // A property added to the global object (e.g. `this.x = 1` at top
                // level) is reachable as a bare global reference.
                if (self.global_object) |g| {
                    if (objectHasOwn(g, name)) break :blk try self.getProperty(.{ .object = g }, name);
                }
                return self.throwError("ReferenceError", name);
            },

            .unary => |u| try self.evalUnary(u.op, u.operand),
            .delete_expr => |target| blk: {
                // `delete obj.prop` / `delete obj[expr]`: remove an own property
                // (honoring [[Configurable]]). `delete <non-reference>` is true.
                if (target.* == .member) {
                    const m = target.member;
                    const obj = try self.eval(m.object);
                    if (obj != .object) break :blk .{ .boolean = true };
                    const key = try self.memberKey(m.property, m.computed);
                    const ok = try self.deleteOwn(obj.object, key);
                    // Strict mode: a failed delete (a non-configurable property)
                    // is a TypeError rather than a `false` result.
                    if (!ok and self.strict) return self.throwError("TypeError", "Cannot delete property");
                    break :blk .{ .boolean = ok };
                }
                // `delete <name>` inside a `with` deletes from the binding object
                // (an object environment record); elsewhere a bare-name delete is
                // a no-op that evaluates to true.
                if (target.* == .identifier) {
                    if (try self.assignWithObject(target.identifier)) |o| {
                        const ok = try self.deleteOwn(o, target.identifier);
                        if (!ok and self.strict) return self.throwError("TypeError", "Cannot delete property");
                        break :blk .{ .boolean = ok };
                    }
                }
                break :blk .{ .boolean = true };
            },
            .update => |u| try self.evalUpdate(u.inc, u.prefix, u.target),
            .binary => |b| try self.evalBinary(b.op, b.left, b.right),
            .logical => |l| try self.evalLogical(l.op, l.left, l.right),
            .sequence => |s| blk: {
                _ = try self.eval(s.first);
                break :blk try self.eval(s.second);
            },

            .assign => |a| blk: {
                const v = try self.eval(a.value);
                // NamedEvaluation: `f = function(){}` names the function "f"
                // (only a bare identifier target, per spec).
                if (a.target.* == .identifier) try self.maybeNameAnon(v, a.value, a.target.identifier);
                try self.assignTo(a.target, v);
                break :blk v;
            },

            .function => |fnode| blk: {
                // A *named* function expression binds its own name as an
                // immutable binding in a fresh scope enclosing the body, so the
                // body can refer to itself (recursion) and can't rebind the name.
                if (fnode.name.len > 0 and !fnode.is_arrow) {
                    const fenv = try self.arena.create(Environment);
                    fenv.* = .{ .arena = self.arena, .parent = self.env };
                    const fv = try self.makeFunction(fnode, fenv);
                    try fenv.putFnName(fnode.name, fv);
                    break :blk fv;
                }
                break :blk try self.makeFunction(fnode, self.env);
            },
            .class_expr => |c| try self.evalClass(c.name, c.superclass, c.members, c.source),

            // `yield` only executes inside a compiled generator body (on the
            // suspendable VM). Reaching it in the tree-walker means a generator
            // body fell outside the VM's lowered subset — report it clearly
            // rather than producing a wrong value.
            .yield_expr => return self.throwError("SyntaxError", "yield is only supported in VM-compiled generator bodies"),

            .await_expr => |a| try self.evalAwait(a.argument),

            .super_call => |sc| blk: {
                const sup = self.super_ctor orelse return self.throwError("SyntaxError", "'super' keyword unexpected here");
                const args = try self.evalArgs(sc);
                // Run the superclass constructor on the current `this`. A built-in
                // super (`class extends Set/Map/Array/...`) returns a fresh exotic
                // object carrying the internal slots; per spec that object becomes
                // the `this` binding, so rebind `this` and record it for construct.
                const sup_ret = try self.callValueWithThis(.{ .object = sup }, args, self.this_value);
                // A built-in super (`class extends Set/Map/Array/Promise/...`)
                // returns a fresh exotic object carrying the internal slots the
                // derived `this` should have. Rather than rebind `this`'s identity
                // (the derived instance already has the right prototype and may be
                // mid-chain), copy the super result's internal state onto the
                // existing `this` in place. A JS super returns undefined (it
                // initialized `this` directly), so nothing to adopt.
                if (self.this_value == .object and sup_ret == .object and sup_ret.object != self.this_value.object)
                    adoptInternalSlots(self.this_value.object, sup_ret.object);
                break :blk .undefined;
            },
            .super_member => |m| blk: {
                const parent = (self.home_object orelse return self.throwError("SyntaxError", "'super' outside a method")).proto orelse break :blk .undefined;
                const key = try self.memberKey(m.property, m.computed);
                break :blk try self.getProperty(.{ .object = parent }, key);
            },

            .call => |c| try self.evalCall(c.callee, c.args, c.optional),
            .tagged_template => |t| try self.evalTaggedTemplate(t.tag, t.cooked, t.raw, t.exprs),
            .new_expr => |n| try self.evalNew(n.callee, n.args),
            .member => |m| blk: {
                const obj = try self.eval(m.object);
                if (m.optional and (obj == .null or obj == .undefined)) return error.OptShortCircuit;
                if (m.computed) |ce| {
                    // Spec order: GetValue of the key expression first (its side
                    // effects run), THEN the null/undefined base check, THEN
                    // ToPropertyKey — so `base[prop()]` with a throwing `prop()`
                    // surfaces that throw, while `null[obj]` is a TypeError before
                    // the key's `toString` is ever called.
                    const kv = try self.eval(ce);
                    if (obj == .null or obj == .undefined)
                        return self.throwError("TypeError", "cannot read property of null or undefined");
                    break :blk try self.getProperty(obj, try self.keyOf(kv));
                }
                break :blk try self.getProperty(obj, m.property);
            },
            .optional_chain => |inner| self.eval(inner) catch |e|
                if (e == error.OptShortCircuit) Value.undefined else return e,
            .object_lit => |props| try self.evalObjectLit(props),
            .array_lit => |elems| try self.evalArrayLit(elems),
            .regex_literal => |r| try self.makeRegex(r.pattern, r.flags),
            // Spreads are consumed by array/argument evaluation, never on their own.
            .spread => return self.throwError("SyntaxError", "unexpected spread element"),
            // Patterns are binding targets, not expressions.
            .obj_pattern, .arr_pattern => return self.throwError("SyntaxError", "unexpected destructuring pattern"),

            .conditional => |c| if ((try self.eval(c.cond)).toBoolean())
                try self.eval(c.consequent)
            else
                try self.eval(c.alternate),

            .var_decl => |d| blk: {
                var v: Value = .undefined;
                if (d.init) |init_node| {
                    v = try self.eval(init_node);
                    try self.maybeNameAnon(v, init_node, d.name); // `var f = function(){}` ⇒ name "f"
                }
                // `var` hoists to the variable scope (and mirrors onto the global
                // object); `let`/`const` bind in the current (possibly block) scope.
                if (d.kind == .@"var")
                    try self.globalDefine(d.name, v)
                else if (d.kind == .@"const")
                    try self.env.putConst(d.name, v)
                else
                    try self.env.put(d.name, v);
                break :blk .undefined;
            },

            .func_decl => |fnode| blk: {
                const fnv = try self.makeFunction(fnode, self.env);
                try self.globalDefine(fnode.name, fnv);
                break :blk .undefined;
            },

            // Module declarations. Import bindings are wired during linking
            // (`Context.linkModule`), so an `import` is a runtime no-op. An
            // `export` evaluates its inner declaration/expression so the local
            // bindings exist; the module's export map (built at link time) reads
            // those bindings live from the module environment.
            .import_decl => .undefined,
            .export_decl => |e| blk: {
                if (e.declaration) |d| break :blk try self.eval(d);
                if (e.default_expr) |dx| {
                    const v = switch (dx.*) {
                        // `export default function/class` — a named or anonymous
                        // declaration whose value binds to the synthetic "*default*"
                        // (and its own name, when present, for self-reference).
                        .func_decl => |fnode| try self.makeFunction(fnode, self.env),
                        .class_expr => |c| try self.evalClass(c.name, c.superclass, c.members, c.source),
                        else => try self.eval(dx),
                    };
                    if (e.default_name.len > 0) {
                        try self.env.put(e.default_name, v);
                    } else if (v == .object) {
                        // `export default function(){}` / `class{}` / arrow / other
                        // anonymous AssignmentExpression: NamedEvaluation names it
                        // "default".
                        try self.maybeNameAnon(v, dx, "default");
                    }
                    try self.env.put("*default*", v);
                    break :blk .undefined;
                }
                break :blk .undefined; // `export { … }` / `export * …`: no runtime effect
            },

            .destructure_decl => |d| blk: {
                const v = try self.eval(d.init);
                const saved = self.binding_hoisted;
                const saved_c = self.binding_const;
                self.binding_hoisted = (d.kind == .@"var");
                self.binding_const = (d.kind == .@"const");
                defer self.binding_hoisted = saved;
                defer self.binding_const = saved_c;
                try self.bindPattern(d.pattern, v, true);
                break :blk .undefined;
            },

            .return_stmt => |maybe| blk: {
                const v: Value = if (maybe) |e| try self.eval(e) else .undefined;
                self.ret_value = v;
                self.signal = .ret;
                break :blk v;
            },

            .throw_stmt => |e| {
                self.exception = try self.eval(e);
                return error.Throw;
            },

            .try_stmt => |t| try self.evalTry(t),

            .break_stmt => |label| blk: {
                self.signal = .brk;
                self.signal_label = label;
                break :blk .undefined;
            },
            .continue_stmt => |label| blk: {
                self.signal = .cont;
                self.signal_label = label;
                break :blk .undefined;
            },
            .labeled_stmt => |l| blk: {
                self.current_label = l.label; // adopted by the loop it wraps
                const result = try self.eval(l.body);
                // A labeled break that reached here (e.g. on a labeled block) is consumed.
                if (self.signal == .brk and labelEq(self.signal_label, l.label)) {
                    self.signal = .none;
                    self.signal_label = null;
                }
                break :blk result;
            },

            .expr_stmt => |e| try self.eval(e),

            .block => |stmts| blk: {
                // A `{…}` block is its own lexical scope: `let`/`const`/`class`
                // and block function declarations live here, `var` hoists past it.
                const block_env = try self.arena.create(Environment);
                block_env.* = .{ .arena = self.arena, .parent = self.env };
                const saved_env = self.env;
                self.env = block_env;
                defer self.env = saved_env;
                break :blk try self.evalStatements(stmts);
            },
            // A multi-declarator group runs in the current scope (no new block).
            .decl_group => |stmts| try self.evalStatements(stmts),
            .program => |stmts| try self.evalStatements(stmts),

            .if_stmt => |s| if ((try self.eval(s.cond)).toBoolean())
                try self.eval(s.consequent)
            else if (s.alternate) |alt|
                try self.eval(alt)
            else
                .undefined,

            .with_stmt => |w| blk: {
                // The binding object is ToObject(expr): a primitive is boxed,
                // null/undefined throw — only those throw, not every non-object.
                const obj = try self.toObject(try self.eval(w.obj));
                // Push an object Environment Record onto the lexical chain. A
                // function defined in the body captures it via its closure, and a
                // binding declared inside the body shadows it — both fall out of
                // the chain position automatically.
                const wenv = try self.arena.create(Environment);
                wenv.* = .{ .arena = self.arena, .parent = self.env, .with_object = obj };
                const saved_env = self.env;
                self.env = wenv;
                defer self.env = saved_env;
                break :blk try self.eval(w.body);
            },
            .while_stmt => |s| try self.evalWhile(s.cond, s.body),
            .do_while_stmt => |s| blk: {
                const my_label = self.takeLabel();
                var last: Value = .undefined;
                while (true) {
                    last = try self.eval(s.body);
                    if (self.loopSignal(my_label)) |stop| if (stop) break;
                    if (!(try self.eval(s.cond)).toBoolean()) break;
                }
                break :blk last;
            },
            .for_stmt => |f| try self.evalFor(f.init, f.cond, f.update, f.body),
            .switch_stmt => |s| try self.evalSwitch(s.disc, s.cases),
            .for_in => |f| try self.evalForInOf(f.decl_kind, f.target, f.iterable, f.body, f.is_of, f.is_await),
        };
    }

    /// `for-of` (values of arrays/strings) and `for-in` (own keys of objects /
    /// indices of arrays). Each iteration binds the loop variable then runs the
    /// body, honoring break/continue/return.
    fn evalForInOf(self: *Interpreter, decl_kind: ?ast.DeclKind, target: *Node, iterable: *Node, body: *Node, is_of: bool, is_await: bool) EvalError!Value {
        const my_label = self.takeLabel();
        // A `let`/`const` loop binding gets a fresh declarative environment per
        // iteration, so a closure created in the head or body captures *that*
        // iteration's binding (`var` is function-scoped, so it doesn't).
        const lexical = decl_kind != null and decl_kind.? != .@"var";
        const outer_env = self.env;
        // Head evaluation: per spec the loop bindings are declared (in their TDZ)
        // in a fresh environment while the iterable expression runs, so a closure
        // captured there sees them uninitialized (`typeof x` throws).
        var iter: Value = undefined;
        if (lexical and self.tdz_marker != null) {
            const head_env = try self.arena.create(Environment);
            head_env.* = .{ .arena = self.arena, .parent = outer_env };
            self.env = head_env;
            self.tdzBindPattern(target, self.tdzVal());
            iter = self.eval(iterable) catch |e| {
                self.env = outer_env;
                return e;
            };
            self.env = outer_env;
        } else {
            iter = try self.eval(iterable);
        }
        var last: Value = .undefined;
        if (is_of) {
            // Generic iterator protocol: obtain the iterator (generators are
            // their own; arrays/strings get an index cursor; a user object's
            // `[Symbol.iterator]()` is honored), then pull `.next()` until done.
            // `for await`: the async iterator (Symbol.asyncIterator, else a sync
            // iterator) and each `next()` result is awaited.
            const iter_obj = if (is_await) try self.asyncIteratorOf(iter) else try self.iteratorOf(iter);
            while (true) {
                const res0 = try self.callMethod(iter_obj, "next", &.{});
                const res = if (is_await) try self.awaitValue(res0) else res0;
                if ((try self.getProperty(res, "done")).toBoolean()) break; // exhausted — no close
                const saved_env = self.env;
                defer self.env = saved_env;
                if (lexical) {
                    const iter_env = try self.arena.create(Environment);
                    iter_env.* = .{ .arena = self.arena, .parent = saved_env };
                    self.env = iter_env;
                }
                try self.bindLoopTarget(decl_kind, target, try self.getProperty(res, "value"));
                // A throw in the body closes the iterator before propagating.
                last = self.eval(body) catch |e| {
                    self.iteratorClose(iter_obj) catch {};
                    return e;
                };
                // `break`/`return` (an abrupt loop exit) also closes the iterator.
                if (self.loopSignal(my_label)) |stop| if (stop) {
                    const ss = self.signal;
                    const sr = self.ret_value;
                    self.signal = .none;
                    self.iteratorClose(iter_obj) catch {};
                    self.signal = ss;
                    self.ret_value = sr;
                    break;
                };
            }
        } else {
            // for-in: enumerate keys (skip null/undefined per spec).
            switch (iter) {
                .object => |o| {
                    // EnumerateObjectProperties: own + inherited enumerable string
                    // keys with prototype-chain shadowing (see forInKeyList).
                    for (try self.forInKeyList(o)) |k| {
                        const saved_env = self.env;
                        defer self.env = saved_env;
                        if (lexical) {
                            const ie = try self.arena.create(Environment);
                            ie.* = .{ .arena = self.arena, .parent = saved_env };
                            self.env = ie;
                        }
                        try self.bindLoopTarget(decl_kind, target, .{ .string = k });
                        last = try self.eval(body);
                        if (self.loopSignal(my_label)) |stop| if (stop) break;
                    }
                },
                .undefined, .null => {}, // iterating null/undefined is a no-op
                else => {},
            }
        }
        return last;
    }

    /// EnumerateObjectProperties: the ordered string keys visited by `for-in`,
    /// walking the prototype chain. A key is emitted once (the first time it is
    /// seen on the chain); a shadowing own property — enumerable or not —
    /// suppresses any same-named property further up. Array dense element indices
    /// (skipping holes) are own enumerable keys outside the shape. Symbol/private
    /// keys are excluded.
    pub fn forInKeyList(self: *Interpreter, start: *value.Object) EvalError![]const []const u8 {
        var out: std.ArrayListUnmanaged([]const u8) = .empty;
        var visited: std.StringHashMapUnmanaged(void) = .empty;
        var cur: ?*value.Object = start;
        while (cur) |o| {
            if (o.is_array) {
                var i: usize = 0;
                while (i < o.elements.items.len) : (i += 1) {
                    if (o.isHole(i)) continue;
                    const key = try std.fmt.allocPrint(self.arena, "{d}", .{i});
                    // Accessor at this index comes from ownKeys below.
                    if (o.getAccessor(key) != null) continue;
                    if (visited.contains(key)) continue;
                    try visited.put(self.arena, key, {});
                    if (o.getAttr(key).enumerable) try out.append(self.arena, key);
                }
            }
            for (try o.ownKeys(self.arena)) |k| {
                if (value.isSymbolKey(k) or value.isPrivateKey(k)) continue;
                if (visited.contains(k)) continue;
                try visited.put(self.arena, k, {});
                if (o.getAttr(k).enumerable) try out.append(self.arena, k);
            }
            cur = o.proto;
        }
        return out.items;
    }

    /// The for-in key list of `v` as a fresh array. Null/undefined (and
    /// primitives) yield an empty array. Used by the generator VM's `enum_keys`
    /// opcode to drive for-in via the for-of machinery.
    pub fn forInKeysArray(self: *Interpreter, v: Value) EvalError!Value {
        const arr = (try self.newArray()).object;
        if (v == .object) {
            for (try self.forInKeyList(v.object)) |k| {
                try arr.elements.append(self.arena, .{ .string = k });
            }
        }
        return .{ .object = arr };
    }

    /// Bind one iteration's value to the loop target: a declaration declares
    /// (identifier or destructuring pattern), an assignment form assigns to an
    /// existing identifier / member / pattern.
    fn bindLoopTarget(self: *Interpreter, decl_kind: ?ast.DeclKind, target: *Node, v: Value) EvalError!void {
        if (decl_kind) |k| {
            const saved = self.binding_const;
            self.binding_const = (k == .@"const");
            defer self.binding_const = saved;
            try self.bindPattern(target, v, true);
        } else try self.assignTo(target, v);
    }

    /// `switch`: evaluate the discriminant, find the first strictly-equal `case`
    /// (or `default`), then run from there with fall-through until a `break`.
    fn evalSwitch(self: *Interpreter, disc_node: *Node, cases: []ast.SwitchCase) EvalError!Value {
        const disc = try self.eval(disc_node);
        var start: ?usize = null;
        for (cases, 0..) |c, i| {
            if (c.@"test") |t| {
                if (value.strictEquals(disc, try self.eval(t))) {
                    start = i;
                    break;
                }
            }
        }
        if (start == null) {
            for (cases, 0..) |c, i| {
                if (c.@"test" == null) {
                    start = i;
                    break;
                }
            }
        }
        var last: Value = .undefined;
        if (start) |si| {
            var i = si;
            outer: while (i < cases.len) : (i += 1) {
                for (cases[i].body) |stmt| {
                    last = try self.eval(stmt);
                    if (self.signal != .none) break :outer;
                }
            }
            // An unlabeled `break` exits the switch; a labeled one targets an
            // enclosing loop and must keep propagating.
            if (self.signal == .brk and self.signal_label == null) self.signal = .none;
        }
        return last;
    }

    fn evalWhile(self: *Interpreter, cond: *Node, body: *Node) EvalError!Value {
        const my_label = self.takeLabel();
        var last: Value = .undefined;
        while ((try self.eval(cond)).toBoolean()) {
            last = try self.eval(body);
            if (self.loopSignal(my_label)) |stop| if (stop) break;
        }
        return last;
    }

    fn evalFor(self: *Interpreter, init_node: ?*Node, cond: ?*Node, update: ?*Node, body: *Node) EvalError!Value {
        const my_label = self.takeLabel();
        // Collect the lexical (`let`/`const`) binding names declared in the init,
        // if any. They get a fresh, value-copied environment each iteration so a
        // closure created in the body captures that iteration's binding.
        var names: std.ArrayListUnmanaged([]const u8) = .empty;
        if (init_node) |ini| collectForLexNames(ini, &names, self.arena);
        const lexical = names.items.len > 0;

        const outer = self.env;
        defer if (lexical) {
            self.env = outer;
        };
        if (init_node) |ini| {
            if (lexical) {
                // The loop's lexical declaration lives in its own environment.
                const loop_env = try self.arena.create(Environment);
                loop_env.* = .{ .arena = self.arena, .parent = outer };
                self.env = loop_env;
            }
            _ = try self.eval(ini);
        }
        // CreatePerIterationEnvironment (initial copy, before the first test).
        if (lexical) self.env = try self.perIterEnv(outer, names.items, self.env);

        var last: Value = .undefined;
        while (true) {
            if (cond) |c| {
                if (!(try self.eval(c)).toBoolean()) break;
            }
            last = try self.eval(body);
            if (self.loopSignal(my_label)) |stop| if (stop) break;
            // CreatePerIterationEnvironment: copy this iteration's bindings into a
            // fresh env, then run the update against it.
            if (lexical) self.env = try self.perIterEnv(outer, names.items, self.env);
            if (update) |u| _ = try self.eval(u);
        }
        return last;
    }

    /// A fresh per-iteration environment for a `for (let …; …; …)` loop: a child
    /// of `outer` holding each lexical binding, value-copied from `prev`.
    fn perIterEnv(self: *Interpreter, outer: *Environment, names: []const []const u8, prev: *Environment) EvalError!*Environment {
        const e = try self.arena.create(Environment);
        e.* = .{ .arena = self.arena, .parent = outer };
        for (names) |n| try e.put(n, prev.get(n) orelse .undefined);
        return e;
    }

    /// Collect the names bound by a `for` loop's lexical (`let`/`const`) init.
    /// Returns nothing for a `var`/expression init (no per-iteration scope).
    fn collectForLexNames(node: *Node, out: *std.ArrayListUnmanaged([]const u8), arena: std.mem.Allocator) void {
        switch (node.*) {
            .var_decl => |d| if (d.kind != .@"var") {
                out.append(arena, d.name) catch {};
            },
            .destructure_decl => |d| if (d.kind != .@"var") {
                collectPatternNames(d.pattern, out, arena);
            },
            .decl_group => |group| for (group) |n| collectForLexNames(n, out, arena),
            else => {},
        }
    }

    /// Append every identifier bound by a destructuring pattern.
    fn collectPatternNames(target: *Node, out: *std.ArrayListUnmanaged([]const u8), arena: std.mem.Allocator) void {
        switch (target.*) {
            .identifier => |name| out.append(arena, name) catch {},
            .obj_pattern => |p| {
                for (p.props) |pr| collectPatternNames(pr.target, out, arena);
                if (p.rest) |r| out.append(arena, r) catch {};
            },
            .arr_pattern => |p| {
                for (p.elems) |e| if (e.target) |t| collectPatternNames(t, out, arena);
                if (p.rest) |r| collectPatternNames(r, out, arena);
            },
            else => {},
        }
    }

    /// Consume the label of the enclosing `labeled_stmt`, if any. A loop calls
    /// this at entry so it knows which labeled break/continue target it, and so
    /// nested loops don't inherit the label.
    fn takeLabel(self: *Interpreter) ?[]const u8 {
        const l = self.current_label;
        self.current_label = null;
        return l;
    }

    /// Inspect the control-flow signal at a loop boundary, given the loop's own
    /// label (`my_label`). Returns null (nothing pending), true (break this
    /// loop), or false (continue). A labeled break/continue aimed at an *outer*
    /// loop breaks this loop but leaves the signal set to keep propagating.
    fn loopSignal(self: *Interpreter, my_label: ?[]const u8) ?bool {
        switch (self.signal) {
            .none => return null,
            .ret => return true, // leave set; the function unwinds
            .brk => {
                if (self.signal_label == null or labelEq(self.signal_label, my_label)) {
                    self.signal = .none;
                    self.signal_label = null;
                    return true;
                }
                return true; // labeled break for an outer loop: exit, keep signal
            },
            .cont => {
                if (self.signal_label == null or labelEq(self.signal_label, my_label)) {
                    self.signal = .none;
                    self.signal_label = null;
                    return false;
                }
                return true; // labeled continue for an outer loop: exit, keep signal
            },
        }
    }

    fn evalUpdate(self: *Interpreter, inc: bool, prefix: bool, target: *Node) EvalError!Value {
        var old_val = try self.eval(target);
        // ToNumeric: an object operand coerces via ToPrimitive(number); a BigInt
        // is incremented/decremented by 1n (not the Number 1), and the result
        // stays a BigInt.
        if (old_val == .object and !old_val.object.is_bigint and !old_val.object.is_symbol)
            old_val = try self.toPrimitive(old_val, .number);
        if (old_val == .object and old_val.object.is_bigint) {
            const b = old_val.object.bigint;
            const updated = try self.makeBigInt(if (inc) b +% 1 else b -% 1);
            try self.assignTo(target, updated);
            return if (prefix) updated else old_val;
        }
        const old = old_val.toNumber();
        const updated = if (inc) old + 1 else old - 1;
        try self.assignTo(target, .{ .number = updated });
        return .{ .number = if (prefix) updated else old };
    }

    /// Pre-declare every `var`-scoped name in `stmts` as `undefined` (hoisting),
    /// so a forward reference reads `undefined` instead of throwing a
    /// ReferenceError. Recurses through nested control-flow statements but stops
    /// at function boundaries (their vars belong to their own scope); existing
    /// bindings (parameters, hoisted functions, earlier vars) are left untouched.
    fn hoistVarNames(self: *Interpreter, stmts: []*Node) EvalError!void {
        for (stmts) |s| try self.hoistVarsIn(s);
    }

    fn hoistVarsIn(self: *Interpreter, node: *Node) EvalError!void {
        switch (node.*) {
            .var_decl => |d| if (d.kind == .@"var") try self.hoistOneVar(d.name),
            .destructure_decl => |d| if (d.kind == .@"var") try self.hoistPatternVars(d.pattern),
            .decl_group => |g| for (g) |gs| try self.hoistVarsIn(gs),
            .block => |b| for (b) |bs| try self.hoistVarsIn(bs),
            .if_stmt => |i| {
                try self.hoistVarsIn(i.consequent);
                if (i.alternate) |alt| try self.hoistVarsIn(alt);
            },
            .while_stmt => |w| try self.hoistVarsIn(w.body),
            .do_while_stmt => |w| try self.hoistVarsIn(w.body),
            .for_stmt => |f| {
                if (f.init) |ini| try self.hoistVarsIn(ini);
                try self.hoistVarsIn(f.body);
            },
            .for_in => |f| {
                if (f.decl_kind) |k| if (k == .@"var") try self.hoistPatternVars(f.target);
                try self.hoistVarsIn(f.body);
            },
            .try_stmt => |t| {
                try self.hoistVarsIn(t.block);
                if (t.catch_block) |c| try self.hoistVarsIn(c);
                if (t.finally_block) |fb| try self.hoistVarsIn(fb);
            },
            .switch_stmt => |sw| for (sw.cases) |c| for (c.body) |cs| try self.hoistVarsIn(cs),
            .labeled_stmt => |l| try self.hoistVarsIn(l.body),
            else => {}, // function decls/exprs and expressions hoist nothing here
        }
    }

    fn hoistOneVar(self: *Interpreter, name: []const u8) EvalError!void {
        const vs = self.env.varScope();
        if (vs.vars.contains(name)) return; // param / hoisted function / earlier var
        try self.globalDefine(name, .undefined);
    }

    fn hoistPatternVars(self: *Interpreter, pat: *Node) EvalError!void {
        switch (pat.*) {
            .identifier => |name| try self.hoistOneVar(name),
            else => {}, // destructuring patterns bind on execution (rare to forward-ref)
        }
    }

    pub fn evalStatements(self: *Interpreter, stmts: []*Node) EvalError!Value {
        // Hoist function declarations to the top of the scope so forward
        // references work (`bar(); function bar() {}`). Each is bound exactly
        // once here; the main loop then skips them, preserving function identity
        // (`var g = bar; function bar() {}` ⇒ `g === bar`).
        for (stmts) |s| switch (s.*) {
            .func_decl => |fnode| try self.globalDefine(fnode.name, try self.makeFunction(fnode, self.env)),
            // `export function f(){}` / `export default function f(){}` hoist `f`
            // just like a bare function declaration so forward references resolve.
            .export_decl => |e| {
                if (e.declaration) |d| {
                    if (d.* == .func_decl) try self.globalDefine(d.func_decl.name, try self.makeFunction(d.func_decl, self.env));
                } else if (e.default_expr) |dx| {
                    if (dx.* == .func_decl) {
                        const fv = try self.makeFunction(dx.func_decl, self.env);
                        if (e.default_name.len > 0) try self.globalDefine(e.default_name, fv);
                        try self.env.put("*default*", fv);
                    }
                }
            },
            else => {},
        };
        // `var` hoisting: once per function/script var-scope, pre-declare every
        // `var` name (in nested control-flow too) as `undefined`. Runs after the
        // function-declaration hoist above (declare-if-absent, so it never
        // clobbers a hoisted function or parameter).
        if (self.env == self.env.varScope()) try self.hoistVarNames(stmts);
        // Temporal dead zone: `let`/`const` (and `class`) declarations are
        // hoisted into this scope as uninitialized bindings; reading one before
        // its declaration runs throws a ReferenceError.
        if (self.tdz_marker) |_| {
            const tdz = self.tdzVal();
            for (stmts) |s| switch (s.*) {
                .var_decl => |d| if (d.kind != .@"var") try self.env.put(d.name, tdz),
                .decl_group => |group| for (group) |gs| switch (gs.*) {
                    .var_decl => |d| if (d.kind != .@"var") try self.env.put(d.name, tdz),
                    else => {},
                },
                .destructure_decl => |d| if (d.kind != .@"var") self.tdzBindPattern(d.pattern, tdz),
                .class_expr => |c| if (c.name.len > 0) try self.env.put(c.name, tdz),
                else => {},
            };
        }
        var last: Value = .undefined;
        for (stmts) |s| {
            if (s.* == .func_decl) continue; // already hoisted above
            // An exported function declaration was hoisted above too (preserving
            // its identity); skip it so it isn't rebuilt with a fresh identity.
            if (s.* == .export_decl) {
                const e = s.export_decl;
                if (e.declaration) |d| {
                    if (d.* == .func_decl) continue;
                } else if (e.default_expr) |dx| {
                    if (dx.* == .func_decl) continue;
                }
            }
            last = try self.eval(s);
            if (self.signal != .none) return last;
        }
        return last;
    }

    fn makeFunction(self: *Interpreter, fnode: *const ast.FunctionNode, closure: *Environment) EvalError!Value {
        const func = try self.arena.create(Function);
        func.* = .{
            .params = fnode.params,
            .body = fnode.body,
            .is_expr_body = fnode.is_expr_body,
            .is_arrow = fnode.is_arrow,
            .closure = closure,
            .name = fnode.name,
            .source = fnode.source,
            .is_generator = fnode.is_generator,
            .is_async = fnode.is_async,
            .is_strict = fnode.is_strict,
        };
        // A `with` block's object Environment Record is part of the lexical chain
        // (`Environment.with_object`), so a function defined inside a `with`
        // captures it automatically through its `closure` — no separate capture.
        // Arrows capture `super` (home object + super constructor) lexically from
        // the enclosing method, just as they capture `this`/`new.target`. A
        // non-arrow gets its home object later (e.g. when installed as a method).
        if (fnode.is_arrow) {
            func.home_object = self.home_object;
            func.super_ctor = self.super_ctor;
        }
        // Compile a generator body up front for the suspendable VM. Bodies
        // outside the VM's lowered subset leave `gen_chunk` null, so calling the
        // generator throws a clear TypeError rather than running incorrectly.
        if (fnode.is_generator) {
            func.gen_chunk = Compiler.compileGenerator(self.arena, fnode) catch |e| switch (e) {
                error.Unsupported => null,
                error.OutOfMemory => return error.OutOfMemory,
            };
        } else if (fnode.is_async) {
            // A plain async function compiles to a suspendable body (await is a
            // suspend point); null on unsupported syntax → tree-walk fallback.
            func.async_chunk = Compiler.compileAsync(self.arena, fnode) catch |e| switch (e) {
                error.Unsupported => null,
                error.OutOfMemory => return error.OutOfMemory,
            };
        }
        const obj = try self.arena.create(value.Object);
        obj.* = .{ .js_func = @ptrCast(func), .proto = self.functionProto() };
        try installFunctionProps(self.arena, self.root_shape, obj, fnode.params, func.name);
        return .{ .object = obj };
    }

    fn funcOf(v: Value) ?*Function {
        if (v == .object) {
            if (v.object.js_func) |e| return @ptrCast(@alignCast(e));
        }
        return null;
    }

    /// `Function.prototype.toString`. A user function returns its exact captured
    /// source; a native, bound, or not-yet-captured function returns the spec's
    /// NativeFunction syntax `function NAME() { [native code] }`.
    fn functionToString(self: *Interpreter, o: *value.Object) EvalError!Value {
        if (funcOf(.{ .object = o })) |func| {
            if (func.source.len > 0) return .{ .string = func.source };
        }
        const nm: []const u8 = if (o.getOwn("name")) |n| (if (n == .string) n.string else "") else "";
        return .{ .string = try std.mem.concat(self.arena, u8, &.{ "function ", nm, "() { [native code] }" }) };
    }

    /// True if `node` is an *anonymous* function/class definition — the
    /// syntactic predicate `IsAnonymousFunctionDefinition` that drives
    /// NamedEvaluation (`var f = function(){}` ⇒ `f.name === "f"`).
    fn isAnonFnDef(node: *Node) bool {
        return switch (node.*) {
            .function => |f| f.name.len == 0,
            // `export default function(){}` parses the body as a `func_decl`; an
            // anonymous one is named "default" by NamedEvaluation.
            .func_decl => |f| f.name.len == 0,
            .class_expr => |c| c.name.len == 0,
            else => false,
        };
    }

    /// NamedEvaluation: when an anonymous function/class produced by `init_node`
    /// is bound to the name `name` (a declaration, assignment, property, or
    /// destructuring default), give the still-unnamed function that name. The
    /// `name` own property is { writable:false, enumerable:false,
    /// configurable:true }, like every function name.
    fn maybeNameAnon(self: *Interpreter, val: Value, init_node: *Node, name: []const u8) EvalError!void {
        if (name.len == 0) return;
        if (!isAnonFnDef(init_node)) return;
        if (val != .object or !val.object.isCallableObject()) return;
        const o = val.object;
        if (o.getOwn("name")) |c| {
            // Already has a meaningful own `name`: a non-empty string, or — for a
            // class with an explicit `static name(){}`/field — a non-string value.
            // Only an empty-string placeholder (a freshly-built anonymous class)
            // is overridable.
            if (c != .string or c.string.len != 0) return;
        }
        try o.setOwn(self.arena, self.root_shape, "name", .{ .string = name });
        try o.setAttr(self.arena, "name", .{ .writable = false, .enumerable = false, .configurable = true });
        if (funcOf(val)) |f| f.name = name; // keep Function.name in sync
    }

    /// Evaluate a `class` to a constructor function value: methods go on its
    /// `.prototype`, static members on the class object itself, and instance
    /// fields are desugared into the constructor (`this.f = init`). With
    /// `extends`, the prototypes are linked and methods get a home object so
    /// `super.x` / `super(...)` resolve. (Accessors are still deferred.)
    fn evalClass(self: *Interpreter, name: []const u8, superclass: ?*Node, members: []ast.ClassMember, source: []const u8) EvalError!Value {
        var super_obj: ?*value.Object = null;
        var super_proto: ?*value.Object = null;
        if (superclass) |sc| {
            const sv = try self.eval(sc);
            if (sv != .object) return self.throwError("TypeError", "class extends value is not a constructor");
            super_obj = sv.object;
            super_proto = try self.protoObject(sv.object);
        }
        return self.buildClass(name, members, super_obj, super_proto, source);
    }

    fn buildClass(self: *Interpreter, name: []const u8, members: []ast.ClassMember, super_obj: ?*value.Object, super_proto: ?*value.Object, source: []const u8) EvalError!Value {
        // Instance field initializers, prepended to the constructor body.
        var field_inits: std.ArrayListUnmanaged(*Node) = .empty;
        for (members) |m| {
            if (!m.is_field or m.is_static) continue;
            const this_node = try self.arena.create(Node);
            this_node.* = .this_expr;
            const member_node = try self.arena.create(Node);
            member_node.* = .{ .member = .{ .object = this_node, .property = m.key, .computed = m.key_expr } };
            const value_node = m.field_init orelse blk: {
                const u = try self.arena.create(Node);
                u.* = .undefined_lit;
                break :blk u;
            };
            const assign_node = try self.arena.create(Node);
            assign_node.* = .{ .assign = .{ .target = member_node, .value = value_node } };
            const stmt = try self.arena.create(Node);
            stmt.* = .{ .expr_stmt = assign_node };
            try field_inits.append(self.arena, stmt);
        }

        // Constructor: explicit (augmented with field inits) or default. For a
        // derived class with no explicit constructor, synthesize
        // `constructor(...args) { super(...args); }`.
        var ctor_node: ?*const ast.FunctionNode = null;
        for (members) |m| {
            if (m.is_ctor) ctor_node = m.func.?.function;
        }
        var default_params: []const ast.Param = &.{};
        var default_super: []*Node = &.{};
        if (ctor_node == null and super_obj != null) {
            const args_id = try self.arena.create(Node);
            args_id.* = .{ .identifier = "args" };
            const spread_node = try self.arena.create(Node);
            spread_node.* = .{ .spread = args_id };
            const super_args = try self.arena.dupe(*Node, &.{spread_node});
            const super_node = try self.arena.create(Node);
            super_node.* = .{ .super_call = super_args };
            const stmt = try self.arena.create(Node);
            stmt.* = .{ .expr_stmt = super_node };
            default_super = try self.arena.dupe(*Node, &.{stmt});
            default_params = try self.arena.dupe(ast.Param, &.{.{ .name = "args", .is_rest = true }});
        }
        const orig: []*Node = if (ctor_node) |cf| cf.body.block else default_super;
        const body_stmts = try std.mem.concat(self.arena, *Node, &.{ field_inits.items, orig });
        const body = try self.arena.create(Node);
        body.* = .{ .block = body_stmts };
        const fnode = try self.arena.create(ast.FunctionNode);
        fnode.* = .{
            .name = name,
            .params = if (ctor_node) |cf| cf.params else default_params,
            .body = body,
            .source = source,
            .is_expr_body = false,
        };
        const class_val = try self.makeFunction(fnode, self.env);
        const class_obj = class_val.object;
        const proto = try self.protoObject(class_obj);
        // A class's `prototype` is non-writable, non-enumerable, non-configurable.
        try class_obj.setAttr(self.arena, "prototype", .{ .writable = false, .enumerable = false, .configurable = false });

        // Link the prototype chains for inheritance.
        if (super_obj) |so| {
            proto.proto = super_proto;
            class_obj.proto = so; // static methods inherit
        }
        // The constructor's home object is the prototype; super(...) targets the superclass.
        if (funcOf(class_val)) |cf| {
            cf.home_object = proto;
            cf.super_ctor = super_obj;
        }

        for (members) |m| {
            // `static { ... }` block: run with `this` = the class object and the
            // class as its home object, so `super.x` resolves on the superclass
            // (the class object's prototype is the parent class for statics).
            if (m.static_block) |block| {
                const saved_this = self.this_value;
                const saved_home = self.home_object;
                self.this_value = class_val;
                self.home_object = class_obj;
                defer {
                    self.this_value = saved_this;
                    self.home_object = saved_home;
                }
                _ = try self.eval(block);
                continue;
            }
            const key = if (m.key_expr) |ke| try self.keyOf(try self.eval(ke)) else m.key;
            if (m.is_field) {
                if (m.is_static) {
                    const v = if (m.field_init) |init_node| try self.eval(init_node) else .undefined;
                    try self.setProp(class_obj, key, v);
                }
                continue;
            }
            if (m.is_ctor) continue;
            const fv = try self.eval(m.func.?);
            const home = if (m.is_static) class_obj else proto;
            if (funcOf(fv)) |mf| {
                mf.home_object = home;
                mf.super_ctor = super_obj;
            }
            switch (m.accessor) {
                .none => try self.setProp(home, key, fv),
                .get => try self.defineAccessor(home, key, fv, null),
                .set => try self.defineAccessor(home, key, null, fv),
            }
            // Class methods/accessors are non-enumerable (writable + configurable),
            // unlike object-literal properties.
            try home.setAttr(self.arena, key, .{ .writable = true, .enumerable = false, .configurable = true });
        }
        try self.setProp(proto, "constructor", class_val);
        try proto.setAttr(self.arena, "constructor", .{ .writable = true, .enumerable = false, .configurable = true });
        return class_val;
    }

    fn evalArgs(self: *Interpreter, arg_nodes: []*Node) EvalError![]Value {
        // Fast path: no spreads → fixed-size slice.
        var has_spread = false;
        for (arg_nodes) |an| {
            if (an.* == .spread) has_spread = true;
        }
        if (!has_spread) {
            const args = try self.arena.alloc(Value, arg_nodes.len);
            for (arg_nodes, 0..) |an, i| args[i] = try self.eval(an);
            return args;
        }
        var list: std.ArrayListUnmanaged(Value) = .empty;
        for (arg_nodes) |an| {
            if (an.* == .spread) {
                try self.spreadInto(&list, try self.eval(an.spread));
            } else {
                try list.append(self.arena, try self.eval(an));
            }
        }
        return list.items;
    }

    /// Expand an iterable into `list` — for `...spread`. Arrays take a fast
    /// path; everything else (strings, generators, Sets/Maps, user objects with
    /// `[Symbol.iterator]`) goes through the iterator protocol.
    pub fn spreadInto(self: *Interpreter, list: *std.ArrayListUnmanaged(Value), v: Value) EvalError!void {
        if (v == .object and v.object.is_array and self.arrayIterIntact()) {
            for (v.object.elements.items) |e| try list.append(self.arena, e);
            return;
        }
        const iter_obj = try self.iteratorOf(v); // throws TypeError if not iterable
        while (true) {
            const res = try self.callMethod(iter_obj, "next", &.{});
            if ((try self.getProperty(res, "done")).toBoolean()) break;
            try list.append(self.arena, try self.getProperty(res, "value"));
        }
    }

    fn evalCall(self: *Interpreter, callee_node: *Node, arg_nodes: []*Node, optional: bool) EvalError!Value {
        // Method call `obj.m(...)`: evaluate the receiver once so it can both
        // resolve the method and bind `this`. Array/string builtins (push,
        // pop, ...) that aren't own properties are dispatched here too.
        if (callee_node.* == .member) {
            const m = callee_node.member;
            const recv = try self.eval(m.object);
            if (m.optional and (recv == .null or recv == .undefined)) return error.OptShortCircuit;
            const key = try self.memberKey(m.property, m.computed);
            // `recv.m?.(...)`: short-circuit if the method itself is nullish.
            if (optional) {
                const method = try self.getProperty(recv, key);
                if (method == .null or method == .undefined) return error.OptShortCircuit;
                return self.callValueWithThis(method, try self.evalArgs(arg_nodes), recv);
            }
            const args = try self.evalArgs(arg_nodes);
            return self.callMethod(recv, key, args);
        }
        // `super.m(args)`: look the method up on the home object's prototype,
        // but invoke it with the current `this`.
        if (callee_node.* == .super_member) {
            const sm = callee_node.super_member;
            const parent = (self.home_object orelse return self.throwError("SyntaxError", "'super' outside a method")).proto orelse
                return self.throwError("TypeError", "no superclass method");
            const key = try self.memberKey(sm.property, sm.computed);
            const method = try self.getProperty(.{ .object = parent }, key);
            const args = try self.evalArgs(arg_nodes);
            return self.callValueWithThis(method, args, self.this_value);
        }
        const callee = try self.eval(callee_node);
        if (optional and (callee == .null or callee == .undefined)) return error.OptShortCircuit;
        const args = try self.evalArgs(arg_nodes);
        return self.callValue(callee, args);
    }

    /// `tag`a${x}b`` → `tag(strings, x)` where `strings` is the frozen cooked
    /// array carrying a frozen `raw` array. The tag's `this` is the member
    /// receiver for `obj.tag`...`` (e.g. `String.raw`...``), else undefined.
    fn evalTaggedTemplate(self: *Interpreter, tag_node: *Node, cooked: [][]const u8, raw: [][]const u8, expr_nodes: []*Node) EvalError!Value {
        // The "strings" template object: an array of the cooked strings with an
        // own `raw` array of the unescaped strings.
        const strings = (try self.newArray()).object;
        for (cooked) |s| try strings.elements.append(self.arena, .{ .string = s });
        const raw_arr = (try self.newArray()).object;
        for (raw) |s| try raw_arr.elements.append(self.arena, .{ .string = s });
        try self.setProp(strings, "raw", .{ .object = raw_arr });

        // Build the argument list: strings, then each substitution value.
        var args: std.ArrayListUnmanaged(Value) = .empty;
        try args.append(self.arena, .{ .object = strings });
        for (expr_nodes) |en| try args.append(self.arena, try self.eval(en));

        // Resolve the tag and its `this` (member receiver, else undefined).
        if (tag_node.* == .member) {
            const m = tag_node.member;
            const recv = try self.eval(m.object);
            const key = try self.memberKey(m.property, m.computed);
            return self.callMethod(recv, key, args.items);
        }
        return self.callValue(try self.eval(tag_node), args.items);
    }

    /// Invoke a callable value with `this = undefined`.
    pub fn callValue(self: *Interpreter, callee: Value, args: []const Value) EvalError!Value {
        return self.callValueWithThis(callee, args, .undefined);
    }

    /// Invoke a callable value with an explicit `this`. Zig-native builtins run
    /// directly; JS functions push a call scope over their closure; builtin
    /// error constructors fabricate an error instance.
    pub fn callValueWithThis(self: *Interpreter, callee: Value, args: []const Value, this_val: Value) EvalError!Value {
        if (callee != .object) return self.throwError("TypeError", "value is not a function");
        const obj = callee.object;
        if (obj.proxy_handler != null or obj.proxy_revoked) {
            const target = obj.proxy_target.?;
            if (try self.proxyTrap(obj, "apply")) |trap| {
                const arr = try self.newArray();
                for (args) |a| try arr.object.elements.append(self.arena, a);
                return self.callValueWithThis(trap, &.{ .{ .object = target }, this_val, arr }, .{ .object = obj.proxy_handler.? });
            }
            return self.callValueWithThis(.{ .object = target }, args, this_val);
        }
        if (obj.bound) |erased| {
            const bf: *BoundFn = @ptrCast(@alignCast(erased));
            return self.callValueWithThis(bf.target, try self.concatArgs(bf.args, args), bf.this);
        }
        if (obj.error_ctor) |name| return self.makeErrorWithArgs(name, args);
        if (obj.native) |nf| {
            // Expose the callee object to the native (it isn't a parameter), so
            // closures-over-data like Promise resolve/reject can find their slot.
            const saved_native = self.active_native;
            self.active_native = obj;
            defer self.active_native = saved_native;
            return nf(@ptrCast(self), this_val, args);
        }
        if (obj.js_func) |erased| {
            const func: *Function = @ptrCast(@alignCast(erased));
            return self.callFunction(func, args, this_val);
        }
        return self.throwError("TypeError", "value is not a function");
    }

    /// A bound function: target + the `this`/leading args fixed by `fn.bind`.
    pub const BoundFn = struct { target: Value, this: Value, args: []const Value };

    /// `fn.bind(this, ...bound)`: a new callable that prepends `bound` to its args.
    /// CreateListFromArrayLike: the argument list for `Function.prototype.apply`
    /// (and Reflect.apply). `undefined`/`null` → empty; a non-object throws; an
    /// object is read by `length` (ToLength) and indices 0..length via [[Get]],
    /// so a real array-like (e.g. `arguments`) works, not only a dense array.
    fn argListFromArrayLike(self: *Interpreter, v: Value) EvalError![]const Value {
        if (v == .undefined or v == .null) return &.{};
        if (v != .object) return self.throwError("TypeError", "CreateListFromArrayLike called on non-object");
        const o = v.object;
        const len = toLen((try self.toPrimitive(try self.getProperty(v, "length"), .number)).toNumber());
        if (len > (1 << 24)) return self.throwError("RangeError", "argument list too large");
        // Dense fast path for a plain array with no accessors.
        if (o.is_array and o.accessors == null and len <= o.elements.items.len) return o.elements.items[0..len];
        const buf = try self.arena.alloc(Value, len);
        for (buf, 0..) |*slot, i| slot.* = try self.getProperty(v, try std.fmt.allocPrint(self.arena, "{d}", .{i}));
        return buf;
    }

    fn makeBound(self: *Interpreter, target: *value.Object, this: Value, bound_args: []const Value) EvalError!Value {
        const bf = try self.arena.create(BoundFn);
        bf.* = .{ .target = .{ .object = target }, .this = this, .args = try self.arena.dupe(Value, bound_args) };
        const obj = try self.arena.create(value.Object);
        obj.* = .{ .bound = @ptrCast(bf) };
        // Per spec: a bound function's `length` is max(0, target.length - args)
        // and its `name` is "bound " + target.name. Both are
        // { writable: false, enumerable: false, configurable: true }.
        const ro_attr: value.PropAttr = .{ .writable = false, .enumerable = false, .configurable = true };
        const tgt_len = (try self.getProperty(.{ .object = target }, "length")).toNumber();
        const bound_len = if (std.math.isNan(tgt_len)) 0 else blk: {
            const n = @as(i64, @intFromFloat(@trunc(tgt_len))) - @as(i64, @intCast(bound_args.len));
            break :blk if (n < 0) @as(i64, 0) else n;
        };
        try obj.setOwn(self.arena, self.root_shape, "length", .{ .number = @floatFromInt(bound_len) });
        try obj.setAttr(self.arena, "length", ro_attr);
        const tgt_name = try self.getProperty(.{ .object = target }, "name");
        const base_name = if (tgt_name == .string) tgt_name.string else "";
        const bound_name = try std.fmt.allocPrint(self.arena, "bound {s}", .{base_name});
        try obj.setOwn(self.arena, self.root_shape, "name", .{ .string = bound_name });
        try obj.setAttr(self.arena, "name", ro_attr);
        return .{ .object = obj };
    }

    /// Concatenate bound args with call args (for invoking a bound function).
    fn concatArgs(self: *Interpreter, a: []const Value, b: []const Value) EvalError![]const Value {
        if (a.len == 0) return b;
        if (b.len == 0) return a;
        const out = try self.arena.alloc(Value, a.len + b.len);
        @memcpy(out[0..a.len], a);
        @memcpy(out[a.len..], b);
        return out;
    }

    fn makeErrorWithArgs(self: *Interpreter, name: []const u8, args: []const Value) EvalError!Value {
        // AggregateError(errors, message, options) shifts message/options by one
        // and carries an own `errors` array built from the first (iterable) arg.
        const aggregate = std.mem.eql(u8, name, "AggregateError");
        const msg_i: usize = if (aggregate) 1 else 0;
        const opt_i: usize = if (aggregate) 2 else 1;

        // The message is ToString'd (via ToPrimitive(string), so an object's
        // toString/valueOf runs); a Symbol message throws a TypeError.
        const msg = if (args.len > msg_i and args[msg_i] != .undefined) blk: {
            const prim = try self.toPrimitive(args[msg_i], .string);
            if (prim == .object and prim.object.is_symbol)
                return self.throwError("TypeError", "Cannot convert a Symbol value to a string");
            break :blk try prim.toString(self.arena);
        } else "";
        const err = try self.makeError(name, msg);

        if (aggregate) {
            // `errors` is a fresh Array built from the (iterable) first argument.
            const errs = if (args.len > 0)
                try builtins.arrayFrom(@ptrCast(self), .undefined, args[0..1])
            else
                try self.newArray();
            try self.setProp(err.object, "errors", errs);
            try err.object.setAttr(self.arena, "errors", .{ .enumerable = false, .configurable = true, .writable = true });
        }

        // ES2022 `cause` option: `new Error(msg, { cause })` installs a
        // non-enumerable `cause` own property when the options object HAS one —
        // a real HasProperty (walks the prototype chain and fires a Proxy `has`
        // trap), then [[Get]] reads the value.
        if (args.len > opt_i and args[opt_i] == .object) {
            if (try self.inOperator(.{ .string = "cause" }, args[opt_i])) {
                const cause = try self.getProperty(args[opt_i], "cause");
                try self.setProp(err.object, "cause", cause);
                try err.object.setAttr(self.arena, "cause", .{ .enumerable = false, .configurable = true, .writable = true });
            }
        }
        return err;
    }

    fn callFunction(self: *Interpreter, func: *Function, args: []const Value, this_val: Value) EvalError!Value {
        return self.callFunctionNT(func, args, this_val, .undefined);
    }

    /// `callFunction` with an explicit `new.target` (set by `construct`; a plain
    /// call passes undefined). Arrow functions inherit the enclosing new.target.
    fn callFunctionNT(self: *Interpreter, func: *Function, args: []const Value, this_val: Value, new_target: Value) EvalError!Value {
        // An async (non-generator) function runs its body synchronously and wraps
        // the completion in a Promise: a normal return resolves it, a throw
        // rejects it. `await` inside drives the microtask queue inline until the
        // awaited promise settles (the synchronous-settling model). Async
        // generators still need the suspendable VM, so they fall through.
        if (func.is_async and !func.is_generator) {
            // A body the VM could lower runs as a suspendable activation driven
            // by promise settlement (spec-correct await ordering). Otherwise fall
            // back to the synchronous-settling tree-walk model below.
            if (func.async_chunk) |_| return vm.runAsync(self, func, args, this_val);
            const result = try promise.newPromise(self);
            const rp: *promise.Promise = @ptrCast(@alignCast(result.promise.?));
            if (self.callPlain(func, args, this_val, new_target)) |rv| {
                try promise.resolve(self, rp, rv);
            } else |err| {
                if (err == error.Throw) {
                    const reason = self.exception;
                    self.exception = .undefined;
                    try promise.reject(self, rp, reason);
                } else return err;
            }
            return .{ .object = result };
        }
        return self.callPlain(func, args, this_val, new_target);
    }

    /// The body of a plain (sync) function call: scope setup, param binding, and
    /// evaluation. Async functions route through `callFunctionNT`, which wraps
    /// this in a Promise.
    fn callPlain(self: *Interpreter, func: *Function, args: []const Value, this_val: Value, new_target: Value) EvalError!Value {
        // Calling a `function*` builds a generator object (its body runs lazily,
        // on the suspendable VM, via `.next()`). Async generators can't yet run
        // their body (need yield+await suspension), but per spec their parameters
        // still bind eagerly on the call — so a computed-key/default side effect
        // (e.g. `async function*({ [thrower()]: x }) {}`) must propagate before we
        // give up. We fall through to the normal scope-setup + bindParams path and
        // return an inert async-generator stub once binding succeeds.
        if (func.is_generator and !func.is_async) return vm.makeGenerator(self, func, args, this_val);
        // An async generator whose body the VM lowered runs as a real async
        // generator; an unlowerable body falls through to the inert stub below.
        if (func.is_generator and func.is_async and func.gen_chunk != null)
            return vm.makeAsyncGenerator(self, func, args, this_val);
        if (self.depth >= max_call_depth) return self.throwError("RangeError", "Maximum call stack size exceeded");
        self.depth += 1;
        defer self.depth -= 1;

        const call_env = try self.arena.create(Environment);
        call_env.* = .{ .arena = self.arena, .parent = func.closure, .fn_scope = true };

        const saved_env = self.env;
        const saved_signal = self.signal;
        const saved_ret = self.ret_value;
        const saved_this = self.this_value;
        const saved_home = self.home_object;
        const saved_super = self.super_ctor;
        const saved_nt = self.new_target;
        const saved_strict = self.strict;
        self.env = call_env;
        self.signal = .none;
        self.strict = func.is_strict;
        // Sloppy-mode this-substitution: a non-strict, non-arrow function called
        // with a null/undefined `this` (`fn()`, `fn.call(undefined)`) sees the
        // global object. Strict functions keep the undefined `this`; arrows
        // inherit `this` lexically, so both are exempt.
        self.this_value = if (!func.is_strict and !func.is_arrow and (this_val == .null or this_val == .undefined))
            (if (self.global_object) |g| Value{ .object = g } else this_val)
        else
            this_val;
        self.home_object = func.home_object;
        self.super_ctor = func.super_ctor;
        self.new_target = if (func.is_arrow) saved_nt else new_target; // arrows inherit lexically
        defer {
            self.env = saved_env;
            self.signal = saved_signal;
            self.ret_value = saved_ret;
            self.this_value = saved_this;
            self.home_object = saved_home;
            self.super_ctor = saved_super;
            self.new_target = saved_nt;
            self.strict = saved_strict;
        }

        // Non-arrow functions get an `arguments` array-like over the call args.
        if (!func.is_arrow) {
            const args_obj = try self.newArray();
            for (args) |av| try args_obj.object.elements.append(self.arena, av);
            try call_env.put("arguments", args_obj);
        }

        // Bind parameters in `call_env` (so a default can reference earlier
        // params).
        try self.bindParams(func.params, args);

        // Async generator: params have now bound (propagating any side-effect
        // throws). We can't run the body yet, so hand back an inert object
        // standing in for the async-generator instance — the sync `*-err` dstr
        // tests only check the binding throw; the body-running tests are
        // async-flagged and skipped.
        if (func.is_async and func.is_generator) return self.newObject();

        if (func.is_expr_body) return self.eval(func.body);
        // Hoist the body's `var` declarations into the function scope (the current
        // `call_env`) before executing it, so a forward reference reads undefined.
        if (func.body.* == .block) try self.hoistVarNames(func.body.block);
        _ = try self.eval(func.body);
        return if (self.signal == .ret) self.ret_value else .undefined;
    }

    /// Bind a function's parameters to `args` in the current environment
    /// (`self.env`): a rest param (`...r`) collects the remaining args into an
    /// array; an absent/undefined arg falls back to the param's default; a
    /// destructuring pattern is bound via `bindPattern`. Shared by ordinary
    /// calls and generators (which bind into the generator's own environment).
    pub fn bindParams(self: *Interpreter, params: []const ast.Param, args: []const Value) EvalError!void {
        for (params, 0..) |p, i| {
            if (p.is_rest) {
                const rest = try self.newArray();
                var j = i;
                while (j < args.len) : (j += 1) try rest.object.elements.append(self.arena, args[j]);
                try self.env.put(p.name, rest);
                break;
            }
            var v: Value = if (i < args.len) args[i] else .undefined;
            if (v == .undefined) {
                if (p.default) |d| {
                    v = try self.eval(d);
                    if (p.pattern == null) try self.maybeNameAnon(v, d, p.name); // `function f(x = () => {})` ⇒ name "x"
                }
            }
            if (p.pattern) |pat| try self.bindPattern(pat, v, true) else try self.env.put(p.name, v);
        }
    }

    /// `new Callee(args)`: builtin error constructors mint an error instance;
    /// JS functions get a fresh `this` object (tagged with `ctor_ref` for
    /// `instanceof`) and may override it by explicitly returning an object.
    fn evalNew(self: *Interpreter, callee_node: *Node, arg_nodes: []*Node) EvalError!Value {
        const callee = try self.eval(callee_node);
        const args = try self.evalArgs(arg_nodes);
        return self.construct(callee, args);
    }

    /// Construct an instance from `callee` with already-evaluated `args`. Shared
    /// by the `new` operator and the C-API `JSObjectCallAsConstructor`.
    /// Copy a built-in super constructor's result (`src`, a fresh exotic object)
    /// onto the derived instance (`dst`) in place, so the instance gains the
    /// internal slots — [[SetData]]/[[MapData]]/array elements/[[PromiseState]]/
    /// wrapper [[…Data]]/etc. — plus any maintained own properties (e.g. a Set's
    /// `size`). `dst`'s prototype (its derived `.prototype`) is preserved; `dst`
    /// is otherwise pristine (a derived constructor cannot touch `this` before
    /// `super()` returns). `src` is discarded, so sharing its arena-backed
    /// stores is safe.
    fn adoptInternalSlots(dst: *value.Object, src: *value.Object) void {
        const keep_proto = dst.proto;
        dst.* = src.*;
        dst.proto = keep_proto;
    }

    pub fn construct(self: *Interpreter, callee: Value, args: []const Value) EvalError!Value {
        if (callee != .object) return self.throwError("TypeError", "value is not a constructor");
        const obj = callee.object;
        if (obj.proxy_handler != null or obj.proxy_revoked) {
            const target = obj.proxy_target.?;
            if (try self.proxyTrap(obj, "construct")) |trap| {
                const arr = try self.newArray();
                for (args) |a| try arr.object.elements.append(self.arena, a);
                return self.callValueWithThis(trap, &.{ .{ .object = target }, arr, callee }, .{ .object = obj.proxy_handler.? });
            }
            return self.construct(.{ .object = target }, args);
        }
        if (obj.bound) |erased| {
            // `new (fn.bind(...))(...)`: construct the target with bound args
            // prepended (the bound `this` is ignored by `new`, per spec).
            const bf: *BoundFn = @ptrCast(@alignCast(erased));
            return self.construct(bf.target, try self.concatArgs(bf.args, args));
        }
        if (obj.error_ctor) |name| return self.makeErrorWithArgs(name, args);
        if (obj.native) |nf| {
            // Most built-ins aren't constructors; only flagged ones are `new`-able.
            if (!obj.native_ctor) return self.throwError("TypeError", "value is not a constructor");
            // Signal [[Construct]] to the native via `new_target` (restored after),
            // so e.g. `new Number(x)` boxes a wrapper object while `Number(x)`
            // returns a primitive.
            const saved_nt = self.new_target;
            self.new_target = callee;
            defer self.new_target = saved_nt;
            return nf(@ptrCast(self), .undefined, args); // native ctor (Array, Map, RegExp, ...)
        }
        if (obj.js_func) |erased| {
            const func: *Function = @ptrCast(@alignCast(erased));
            // Arrow / async / generator functions are not constructors.
            if (func.is_arrow or func.is_async or func.is_generator)
                return self.throwError("TypeError", "value is not a constructor");
            const this_val = try self.newInstance(obj);
            const ret = try self.callFunctionNT(func, args, this_val, callee); // new.target = the constructor
            return if (ret == .object) ret else this_val;
        }
        return self.throwError("TypeError", "value is not a constructor");
    }

    // ---- objects, arrays, members -----------------------------------------

    fn memberKey(self: *Interpreter, static: []const u8, computed: ?*Node) EvalError![]const u8 {
        if (computed) |ce| return self.keyOf(try self.eval(ce));
        return static;
    }

    /// ToPropertyKey: a Symbol key uses its unique internal encoding (so
    /// symbol-keyed properties don't collide with string keys and stay out of
    /// string enumeration); other keys coerce to string.
    /// ToString(v): the spec abstract operation — `ToString(ToPrimitive(v,
    /// string))` for an object (running its `toString`/`valueOf`, propagating any
    /// throw), and a TypeError for a Symbol. Unlike `Value.toString` (a Zig-level
    /// rendering), this observes user methods and rejects Symbols.
    pub fn toStringV(self: *Interpreter, v: Value) EvalError![]const u8 {
        if (v == .object and v.object.is_symbol)
            return self.throwError("TypeError", "Cannot convert a Symbol value to a string");
        if (v == .object) {
            const prim = try self.toPrimitive(v, .string);
            if (prim == .object and prim.object.is_symbol)
                return self.throwError("TypeError", "Cannot convert a Symbol value to a string");
            return prim.toString(self.arena);
        }
        return v.toString(self.arena);
    }

    /// ToNumber(v): runs `[Symbol.toPrimitive]`/`valueOf`/`toString` for an
    /// object (propagating throws), and a TypeError for a Symbol.
    pub fn toNumberV(self: *Interpreter, v: Value) EvalError!f64 {
        if (v == .object and v.object.is_symbol)
            return self.throwError("TypeError", "Cannot convert a Symbol value to a number");
        if (v == .object and v.object.is_bigint)
            return self.throwError("TypeError", "Cannot convert a BigInt value to a number");
        if (v == .object) {
            const prim = try self.toPrimitive(v, .number);
            if (prim == .object and prim.object.is_symbol)
                return self.throwError("TypeError", "Cannot convert a Symbol value to a number");
            if (prim == .object and prim.object.is_bigint)
                return self.throwError("TypeError", "Cannot convert a BigInt value to a number");
            return prim.toNumber();
        }
        return v.toNumber();
    }

    pub fn keyOf(self: *Interpreter, k: Value) EvalError![]const u8 {
        if (k == .object and k.object.is_symbol) return self.registerSymbol(k.object);
        // ToPropertyKey: an object key is first ToPrimitive(key, string) — running
        // its `[Symbol.toPrimitive]`/`toString`/`valueOf` (a TypeError if none
        // yields a primitive) — and a resulting Symbol keeps its key.
        if (k == .object) {
            const prim = try self.toPrimitive(k, .string);
            if (prim == .object and prim.object.is_symbol) return self.registerSymbol(prim.object);
            return prim.toString(self.arena);
        }
        return k.toString(self.arena);
    }

    /// Index a Symbol by its encoded `sym_key` so it can later be recovered (by
    /// getOwnPropertySymbols / proxy traps), then return that key.
    fn registerSymbol(self: *Interpreter, sym: *value.Object) []const u8 {
        self.symbols.put(self.arena, sym.sym_key, sym) catch {};
        return sym.sym_key;
    }

    /// Allocate a fresh plain object. The single creation point so later tiers
    /// (object shapes) have one seam to hook.
    pub fn newObject(self: *Interpreter) EvalError!Value {
        const obj = try self.arena.create(value.Object);
        obj.* = .{};
        return .{ .object = obj };
    }

    /// The `.prototype` object of a constructor, creating it on first use (every
    /// function/class has one; instances proto to it).
    pub fn protoObject(self: *Interpreter, ctor: *value.Object) EvalError!*value.Object {
        if (ctor.getOwn("prototype")) |p| {
            if (p == .object) return p.object;
        }
        const proto = (try self.newObject()).object;
        try self.setProp(ctor, "prototype", .{ .object = proto });
        // `F.prototype.constructor === F` (writable, non-enumerable,
        // configurable), so an instance's `.constructor` resolves through the
        // prototype chain to F — not the `Object` fallback. Matches the lazy
        // materialization in `getProperty`.
        try self.setProp(proto, "constructor", .{ .object = ctor });
        try proto.setAttr(self.arena, "constructor", .{ .writable = true, .enumerable = false, .configurable = true });
        return proto;
    }

    /// Run queued Promise reactions to completion (the event loop's microtask
    /// checkpoint). Each job may enqueue more; the step budget bounds runaways.
    pub fn drainMicrotasks(self: *Interpreter) EvalError!void {
        const q = self.microtasks orelse return;
        var i: usize = 0;
        while (i < q.items.len) : (i += 1) {
            try promise.runJob(self, q.items[i]);
        }
        q.clearRetainingCapacity();
    }

    /// `await expr` (synchronous-settling): if the awaited value is a promise,
    /// drive the microtask queue until it settles, then return its value (or
    /// throw its rejection). A non-promise (or thenable-free value) is returned
    /// as-is. Not spec-faithful on ordering, but correct on values.
    fn evalAwait(self: *Interpreter, arg_node: *Node) EvalError!Value {
        return self.awaitValue(try self.eval(arg_node));
    }

    /// `await v` on an already-evaluated value (synchronous-settling): if `v` is
    /// a promise, drive the microtask queue until it settles, then return its
    /// value (or throw its rejection). A non-promise is returned as-is.
    pub fn awaitValue(self: *Interpreter, v: Value) EvalError!Value {
        const p = promise.promiseOf(v) orelse return v;
        const q = self.microtasks;
        while (p.state == .pending) {
            const queue = q orelse break;
            if (queue.items.len == 0) break; // nothing left to settle it
            const job = queue.orderedRemove(0);
            try promise.runJob(self, job);
        }
        return switch (p.state) {
            .fulfilled => p.value,
            .rejected => blk: {
                self.exception = p.value;
                break :blk error.Throw;
            },
            .pending => .undefined, // never settled synchronously
        };
    }

    /// A BigInt primitive value with the given `i128` magnitude.
    pub fn makeBigInt(self: *Interpreter, v: i128) EvalError!Value {
        const o = try self.arena.create(value.Object);
        o.* = .{ .is_bigint = true, .bigint = v };
        if (self.env.get("BigInt")) |c| {
            if (c == .object) o.proto = try self.protoObject(c.object);
        }
        return .{ .object = o };
    }

    /// ToBigInt(v): a boolean/number(integer)/string/BigInt converts; a
    /// non-integer Number is a RangeError; null/undefined/Symbol a TypeError.
    /// ToBigInt(v) (`number_ok = false`) or the `BigInt(v)` constructor's
    /// NumberToBigInt (`number_ok = true`). The only difference is a Number
    /// argument: ToBigInt rejects it (TypeError), while the constructor converts
    /// an integral Number to the matching BigInt.
    pub fn toBigIntValue(self: *Interpreter, v: Value) EvalError!Value {
        return self.toBigIntValueImpl(v, false);
    }

    pub fn toBigIntValueImpl(self: *Interpreter, v: Value, number_ok: bool) EvalError!Value {
        switch (v) {
            .object => |o| {
                if (o.is_bigint) return v;
                if (o.is_symbol) return self.throwError("TypeError", "Cannot convert a Symbol value to a BigInt");
                const p = try self.toPrimitive(v, .number);
                if (p == .object and !p.object.is_bigint and !p.object.is_symbol) return self.throwError("TypeError", "Cannot convert object to a BigInt");
                return self.toBigIntValueImpl(p, number_ok);
            },
            .boolean => |b| return self.makeBigInt(if (b) 1 else 0),
            .number => |n| {
                if (!number_ok) return self.throwError("TypeError", "Cannot convert a Number to a BigInt; use BigInt()");
                if (std.math.isNan(n) or std.math.isInf(n) or @trunc(n) != n)
                    return self.throwError("RangeError", "The number is not a safe integer");
                return self.makeBigInt(@intFromFloat(n));
            },
            .string => |s| {
                // StringToBigInt: trim whitespace; empty → 0n; otherwise a decimal
                // (optional sign) or a `0x`/`0o`/`0b` literal (no sign).
                const t = std.mem.trim(u8, s, " \t\r\n\x0b\x0c\u{00a0}\u{feff}");
                if (t.len == 0) return self.makeBigInt(0);
                if (t.len > 2 and t[0] == '0' and (t[1] == 'x' or t[1] == 'X')) {
                    return self.makeBigInt(std.fmt.parseInt(i128, t[2..], 16) catch return self.throwError("SyntaxError", "Cannot convert string to a BigInt"));
                }
                if (t.len > 2 and t[0] == '0' and (t[1] == 'o' or t[1] == 'O')) {
                    return self.makeBigInt(std.fmt.parseInt(i128, t[2..], 8) catch return self.throwError("SyntaxError", "Cannot convert string to a BigInt"));
                }
                if (t.len > 2 and t[0] == '0' and (t[1] == 'b' or t[1] == 'B')) {
                    return self.makeBigInt(std.fmt.parseInt(i128, t[2..], 2) catch return self.throwError("SyntaxError", "Cannot convert string to a BigInt"));
                }
                const i = std.fmt.parseInt(i128, t, 10) catch return self.throwError("SyntaxError", "Cannot convert string to a BigInt");
                return self.makeBigInt(i);
            },
            .null, .undefined => return self.throwError("TypeError", "Cannot convert undefined or null to a BigInt"),
        }
    }

    /// Box a primitive into a wrapper object (`new Number/String/Boolean`). Its
    /// prototype is the in-flight constructor's `.prototype`, so methods,
    /// `instanceof`, and `[object Number|String|Boolean]` all resolve correctly.
    pub fn makeWrapper(self: *Interpreter, p: Value) EvalError!Value {
        const o = try self.arena.create(value.Object);
        o.* = .{ .prim = p };
        if (self.new_target == .object) o.proto = try self.protoObject(self.new_target.object);
        return .{ .object = o };
    }

    /// Create an instance for `new ctor(...)`: a fresh object whose prototype is
    /// the constructor's `.prototype`.
    pub fn newInstance(self: *Interpreter, ctor: *value.Object) EvalError!Value {
        const obj = try self.arena.create(value.Object);
        obj.* = .{ .ctor_ref = ctor, .proto = try self.protoObject(ctor) };
        return .{ .object = obj };
    }

    /// Allocate a fresh array object.
    pub fn newArray(self: *Interpreter) EvalError!Value {
        const obj = try self.arena.create(value.Object);
        obj.* = .{ .is_array = true, .proto = self.arrayProto() };
        return .{ .object = obj };
    }

    /// `Array.prototype`, resolved from the live `Array` binding, so array
    /// instances inherit from it (inherited index access, `in`, iteration over
    /// inherited indices). Null only before globals are installed.
    fn arrayProto(self: *Interpreter) ?*value.Object {
        const av = self.env.get("Array") orelse return null;
        if (av != .object) return null;
        const p = av.object.getOwn("prototype") orelse return null;
        return if (p == .object) p.object else null;
    }

    /// `Function.prototype`, the [[Prototype]] of every function object — so
    /// `fn instanceof Function`, `Object.getPrototypeOf(fn)`, and inherited
    /// `call`/`apply`/`bind`/`toString` all resolve through the chain.
    pub fn functionProto(self: *Interpreter) ?*value.Object {
        const fv = self.env.get("Function") orelse return null;
        if (fv != .object) return null;
        const p = fv.object.getOwn("prototype") orelse return null;
        return if (p == .object) p.object else null;
    }

    fn evalObjectLit(self: *Interpreter, props: []ast.Property) EvalError!Value {
        const v = try self.newObject();
        for (props) |p| {
            if (p.is_spread) {
                // `{ ...src }`: copy src's own enumerable properties / array
                // elements (a string spreads its chars by index).
                const src = try self.eval(p.value);
                switch (src) {
                    .object => |so| {
                        if (so.is_array) {
                            for (so.elements.items, 0..) |el, i| {
                                try self.setMember(v, try std.fmt.allocPrint(self.arena, "{d}", .{i}), el);
                            }
                        }
                        for (try so.enumerableKeys(self.arena)) |k| {
                            try self.setMember(v, k, try self.getProperty(src, k));
                        }
                    },
                    .string => |s| for (s, 0..) |ch, i| {
                        try self.setMember(v, try std.fmt.allocPrint(self.arena, "{d}", .{i}), .{ .string = try self.arena.dupe(u8, &.{ch}) });
                    },
                    else => {}, // null/undefined/number/boolean spread → no own enumerable props
                }
                continue;
            }
            const key = if (p.key_expr) |ke| try self.keyOf(try self.eval(ke)) else p.key;
            switch (p.accessor) {
                .none => {
                    const pv = try self.eval(p.value);
                    try self.maybeNameAnon(pv, p.value, key); // `{ x: function(){} }` ⇒ name "x"
                    try self.setProp(v.object, key, pv);
                },
                .get => try self.defineAccessor(v.object, key, try self.eval(p.value), null),
                .set => try self.defineAccessor(v.object, key, null, try self.eval(p.value)),
            }
        }
        return v;
    }

    /// Build a `RegExp` instance with `source`/`flags`/`lastIndex` and the
    /// `global`/`ignoreCase`/`multiline` booleans. Matching (test/exec) is
    /// dispatched in `regexMethod`, backed by zig-regex.
    pub fn makeRegex(self: *Interpreter, pattern: []const u8, flags: []const u8) EvalError!Value {
        const o = (try self.newObject()).object;
        o.is_regex = true;
        // An empty pattern's [[OriginalSource]] is "(?:)" (so `//`, `new RegExp()`,
        // `new RegExp("")` all match the empty string and report that source).
        const source = if (pattern.len == 0) "(?:)" else pattern;
        try self.setProp(o, "source", .{ .string = try self.arena.dupe(u8, source) });
        try self.setProp(o, "flags", .{ .string = try self.arena.dupe(u8, flags) });
        try self.setProp(o, "lastIndex", .{ .number = 0 });
        try self.setProp(o, "global", .{ .boolean = std.mem.indexOfScalar(u8, flags, 'g') != null });
        try self.setProp(o, "ignoreCase", .{ .boolean = std.mem.indexOfScalar(u8, flags, 'i') != null });
        try self.setProp(o, "multiline", .{ .boolean = std.mem.indexOfScalar(u8, flags, 'm') != null });
        try self.setProp(o, "dotAll", .{ .boolean = std.mem.indexOfScalar(u8, flags, 's') != null });
        try self.setProp(o, "sticky", .{ .boolean = std.mem.indexOfScalar(u8, flags, 'y') != null });
        try self.setProp(o, "unicode", .{ .boolean = std.mem.indexOfScalar(u8, flags, 'u') != null });
        try self.setProp(o, "unicodeSets", .{ .boolean = std.mem.indexOfScalar(u8, flags, 'v') != null });
        try self.setProp(o, "hasIndices", .{ .boolean = std.mem.indexOfScalar(u8, flags, 'd') != null });
        return .{ .object = o };
    }

    fn compileRegex(self: *Interpreter, o: *value.Object) EvalError!regex.Regex {
        const src = (o.getOwn("source") orelse Value{ .string = "" }).string;
        const flags = (o.getOwn("flags") orelse Value{ .string = "" }).string;
        const cf = regex.common.CompileFlags{
            .case_insensitive = std.mem.indexOfScalar(u8, flags, 'i') != null,
            .multiline = std.mem.indexOfScalar(u8, flags, 'm') != null,
            // `s` (dotAll): `.` also matches line terminators.
            .dot_all = std.mem.indexOfScalar(u8, flags, 's') != null,
            // `u`/`v` (unicode): pattern is interpreted as Unicode code points
            // (enables `\u{...}` and code-point-aware classes in the engine).
            .unicode = std.mem.indexOfScalar(u8, flags, 'u') != null or std.mem.indexOfScalar(u8, flags, 'v') != null,
        };
        return regex.Regex.compileWithFlags(self.arena, src, cf) catch
            return self.throwError("SyntaxError", "invalid regular expression");
    }

    fn regexMethod(self: *Interpreter, o: *value.Object, name: []const u8, args: []const Value) EvalError!?Value {
        if (eq(name, "test")) {
            const r = (try self.regexMethod(o, "exec", args)).?;
            return Value{ .boolean = r != .null };
        }
        if (eq(name, "exec")) {
            const input = try arg0(args).toString(self.arena);
            const flags = (o.getOwn("flags") orelse Value{ .string = "" }).string;
            const global = std.mem.indexOfScalar(u8, flags, 'g') != null;
            const sticky = std.mem.indexOfScalar(u8, flags, 'y') != null;
            // `lastIndex` is the search start only for global/sticky regexps.
            const li: usize = if (global or sticky)
                toLen((o.getOwn("lastIndex") orelse Value{ .number = 0 }).toNumber())
            else
                0;
            if (li > input.len) {
                if (global or sticky) try self.setProp(o, "lastIndex", .{ .number = 0 });
                return Value.null;
            }
            var re = try self.compileRegex(o);
            const found = re.find(input[li..]) catch null;
            if (found) |m| {
                // Sticky matches must begin exactly at lastIndex.
                if (sticky and m.start != 0) {
                    try self.setProp(o, "lastIndex", .{ .number = 0 });
                    return Value.null;
                }
                const mstart = li + m.start;
                if (global or sticky) try self.setProp(o, "lastIndex", .{ .number = @floatFromInt(li + m.end) });
                const arr = try self.newArray();
                try arr.object.elements.append(self.arena, .{ .string = try self.arena.dupe(u8, m.slice) });
                for (0..m.captures.len) |i| try arr.object.elements.append(self.arena, try self.captureVal(m, i));
                try self.setProp(arr.object, "index", .{ .number = @floatFromInt(mstart) });
                try self.setProp(arr.object, "input", .{ .string = input });
                const groups = try self.regexGroups(&re, m);
                try self.setProp(arr.object, "groups", if (groups) |g| .{ .object = g } else .undefined);
                return arr;
            }
            if (global or sticky) try self.setProp(o, "lastIndex", .{ .number = 0 });
            return Value.null;
        }
        if (eq(name, "toString")) {
            const src = (o.getOwn("source") orelse Value{ .string = "" }).string;
            const flags = (o.getOwn("flags") orelse Value{ .string = "" }).string;
            return Value{ .string = try std.mem.concat(self.arena, u8, &.{ "/", src, "/", flags }) };
        }
        return null;
    }

    const ms_per_day: i64 = 86400000;

    /// Build a `Date` whose time is `t` ms since the Unix epoch.
    pub fn makeDate(self: *Interpreter, t: f64) EvalError!Value {
        const o = (try self.newObject()).object;
        o.is_date = true;
        // Proto from the in-flight constructor's new.target (`new Date`, or a
        // `class extends Date` subclass), else %Date.prototype% — so
        // `Date.prototype.isPrototypeOf(d)` and `d.constructor` resolve. Date
        // methods still dispatch via the `is_date` branch in builtinMethod.
        if (self.new_target == .object and self.new_target.object.getOwn("prototype") != null) {
            if (self.new_target.object.getOwn("prototype").? == .object)
                o.proto = self.new_target.object.getOwn("prototype").?.object;
        } else if (self.env.get("Date")) |ctor| {
            if (ctor == .object) {
                if (ctor.object.getOwn("prototype")) |p| {
                    if (p == .object) o.proto = p.object;
                }
            }
        }
        o.date_ms = t;
        return .{ .object = o };
    }

    /// Civil date (year, month 1-12, day 1-31) from days since the epoch
    /// (Howard Hinnant's algorithm).
    fn civilFromDays(z0: i64) struct { y: i64, m: i64, d: i64 } {
        const z = z0 + 719468;
        const era = @divFloor(if (z >= 0) z else z - 146096, 146097);
        const doe = z - era * 146097;
        const yoe = @divFloor(doe - @divFloor(doe, 1460) + @divFloor(doe, 36524) - @divFloor(doe, 146096), 365);
        const y = yoe + era * 400;
        const doy = doe - (365 * yoe + @divFloor(yoe, 4) - @divFloor(yoe, 100));
        const mp = @divFloor(5 * doy + 2, 153);
        const d = doy - @divFloor(153 * mp + 2, 5) + 1;
        const m = if (mp < 10) mp + 3 else mp - 9;
        return .{ .y = y + @as(i64, if (m <= 2) 1 else 0), .m = m, .d = d };
    }

    /// Clamp a signed component to a non-negative integer for `{d}` formatting
    /// (negative years/fields are out of this engine's rendered range).
    fn dnz(x: i64) u64 {
        return if (x < 0) 0 else @intCast(x);
    }

    /// Days since the epoch for a civil date (inverse of `civilFromDays`).
    fn daysFromCivil(y0: i64, m: i64, d: i64) i64 {
        const y = y0 - @as(i64, if (m <= 2) 1 else 0);
        const era = @divFloor(if (y >= 0) y else y - 399, 400);
        const yoe = y - era * 400;
        const mp = if (m > 2) m - 3 else m + 9;
        const doy = @divFloor(153 * mp + 2, 5) + d - 1;
        const doe = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy;
        return era * 146097 + doe - 719468;
    }

    const day_names = [_][]const u8{ "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat" };
    const month_names = [_][]const u8{ "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" };
    const DateParts = struct { y: i64, mo: i64, d: i64, h: i64, mi: i64, s: i64, ms: i64, wday: i64 };

    /// Decompose a finite epoch-ms time into broken-down (UTC) components.
    fn dateDecompose(t: f64) DateParts {
        const ti: i64 = @intFromFloat(t);
        const days = @divFloor(ti, ms_per_day);
        const tod = @mod(ti, ms_per_day);
        const c = civilFromDays(days);
        return .{
            .y = c.y,                                  .mo = c.m - 1,
            .d = c.d,                                  .h = @divFloor(tod, 3600000),
            .mi = @mod(@divFloor(tod, 60000), 60),     .s = @mod(@divFloor(tod, 1000), 60),
            .ms = @mod(tod, 1000),                     .wday = @mod(days + 4, 7),
        };
    }

    /// Recompose broken-down components into an epoch-ms time, set it on `o`, and
    /// return it — the shared back half of every `Date.prototype.set*`. Out-of-range
    /// fields roll over (e.g. `setHours(0,0,0,-1)`); a non-finite or absurd field, or
    /// a result past the ±8.64e15 ms range (TimeClip), yields NaN.
    fn dateCommit(self: *Interpreter, o: *value.Object, y: f64, mo: f64, d: f64, h: f64, mi: f64, s: f64, ms: f64) EvalError!Value {
        _ = self; // [[DateValue]] now lives in the `date_ms` field, no property write
        const nan = std.math.nan(f64);
        var tf: f64 = nan;
        const fields = [_]f64{ y, mo, d, h, mi, s, ms };
        var ok = true;
        for (fields) |f| {
            if (!std.math.isFinite(f) or @abs(f) > 1e9) ok = false;
        }
        if (ok) {
            var yi: i64 = @intFromFloat(@trunc(y));
            var moi: i64 = @intFromFloat(@trunc(mo));
            yi += @divFloor(moi, 12);
            moi = @mod(moi, 12);
            const days = daysFromCivil(yi, moi + 1, @intFromFloat(@trunc(d)));
            const tod = @as(i64, @intFromFloat(@trunc(h))) * 3600000 + @as(i64, @intFromFloat(@trunc(mi))) * 60000 +
                @as(i64, @intFromFloat(@trunc(s))) * 1000 + @as(i64, @intFromFloat(@trunc(ms)));
            tf = @as(f64, @floatFromInt(days)) * @as(f64, @floatFromInt(ms_per_day)) + @as(f64, @floatFromInt(tod));
            if (@abs(tf) > 8.64e15) tf = nan;
        }
        o.date_ms = tf;
        return Value{ .number = tf };
    }

    /// `Date.prototype` methods (UTC-based; v1 ignores local timezone, so
    /// get*/getUTC* coincide). Time is the internal-slot field `date_ms`.
    fn dateMethod(self: *Interpreter, o: *value.Object, name: []const u8, args: []const Value) EvalError!?Value {
        const t = o.date_ms;
        const nan = std.math.nan(f64);
        if (eq(name, "getTime") or eq(name, "valueOf")) return Value{ .number = t };
        if (eq(name, "setTime")) {
            var nt = try self.toNumberV(arg0(args));
            if (@abs(nt) > 8.64e15) nt = nan;
            o.date_ms = nt;
            return Value{ .number = nt };
        }

        // ---- setters ----------------------------------------------------------
        if (std.mem.startsWith(u8, name, "set")) {
            const fy = eq(name, "setFullYear") or eq(name, "setUTCFullYear");
            // ToNumber each provided argument once, left-to-right (object args
            // invoke valueOf exactly once), BEFORE consulting the stored time —
            // the spec reads [[DateValue]] first (captured in `t` above) but still
            // coerces every argument even when the date is invalid. A Symbol/
            // BigInt argument throws here (toNumberV).
            const a = try self.arena.alloc(Value, args.len);
            for (args, 0..) |av, idx| a[idx] = .{ .number = try self.toNumberV(av) };
            // Non-fullyear setters on an invalid date stay invalid (arguments were
            // still coerced above); setFullYear revives it from a zero base.
            if (std.math.isNan(t) and !fy) return Value{ .number = nan };
            const c = dateDecompose(if (std.math.isNan(t)) 0 else t);
            var y: f64 = @floatFromInt(c.y);
            var mo: f64 = @floatFromInt(c.mo);
            var d: f64 = @floatFromInt(c.d);
            var h: f64 = @floatFromInt(c.h);
            var mi: f64 = @floatFromInt(c.mi);
            var s: f64 = @floatFromInt(c.s);
            var ms: f64 = @floatFromInt(c.ms);
            if (fy) {
                y = arg0(a).toNumber();
                if (a.len > 1) mo = a[1].toNumber();
                if (a.len > 2) d = a[2].toNumber();
                return try self.dateCommit(o, y, mo, d, h, mi, s, ms);
            }
            if (eq(name, "setMonth") or eq(name, "setUTCMonth")) {
                mo = arg0(a).toNumber();
                if (a.len > 1) d = a[1].toNumber();
                return try self.dateCommit(o, y, mo, d, h, mi, s, ms);
            }
            if (eq(name, "setDate") or eq(name, "setUTCDate")) {
                d = arg0(a).toNumber();
                return try self.dateCommit(o, y, mo, d, h, mi, s, ms);
            }
            if (eq(name, "setHours") or eq(name, "setUTCHours")) {
                h = arg0(a).toNumber();
                if (a.len > 1) mi = a[1].toNumber();
                if (a.len > 2) s = a[2].toNumber();
                if (a.len > 3) ms = a[3].toNumber();
                return try self.dateCommit(o, y, mo, d, h, mi, s, ms);
            }
            if (eq(name, "setMinutes") or eq(name, "setUTCMinutes")) {
                mi = arg0(a).toNumber();
                if (a.len > 1) s = a[1].toNumber();
                if (a.len > 2) ms = a[2].toNumber();
                return try self.dateCommit(o, y, mo, d, h, mi, s, ms);
            }
            if (eq(name, "setSeconds") or eq(name, "setUTCSeconds")) {
                s = arg0(a).toNumber();
                if (a.len > 1) ms = a[1].toNumber();
                return try self.dateCommit(o, y, mo, d, h, mi, s, ms);
            }
            if (eq(name, "setMilliseconds") or eq(name, "setUTCMilliseconds")) {
                ms = arg0(a).toNumber();
                return try self.dateCommit(o, y, mo, d, h, mi, s, ms);
            }
        }

        // ---- string conversions ----------------------------------------------
        if (eq(name, "toISOString")) {
            if (std.math.isNan(t)) return self.throwError("RangeError", "Invalid time value");
            return Value{ .string = try self.dateISO(t) };
        }
        if (eq(name, "toJSON")) {
            // The Date-receiver fast path (the generic `dateToJSONFn` native
            // handles a borrowed/non-Date `this`): a non-finite time is null.
            if (!std.math.isFinite(t)) return Value.null;
            return Value{ .string = try self.dateISO(t) };
        }
        if (eq(name, "toUTCString") or eq(name, "toGMTString")) {
            if (std.math.isNan(t)) return Value{ .string = "Invalid Date" };
            const c = dateDecompose(t);
            return Value{ .string = try std.fmt.allocPrint(self.arena, "{s}, {d:0>2} {s} {d:0>4} {d:0>2}:{d:0>2}:{d:0>2} GMT", .{
                day_names[@intCast(c.wday)], dnz(c.d), month_names[@intCast(c.mo)], dnz(c.y), dnz(c.h), dnz(c.mi), dnz(c.s),
            }) };
        }
        if (eq(name, "toDateString") or eq(name, "toString") or eq(name, "toTimeString") or
            eq(name, "toLocaleString") or eq(name, "toLocaleDateString") or eq(name, "toLocaleTimeString"))
        {
            if (std.math.isNan(t)) return Value{ .string = "Invalid Date" };
            const c = dateDecompose(t);
            const date_str = try std.fmt.allocPrint(self.arena, "{s} {s} {d:0>2} {d:0>4}", .{ day_names[@intCast(c.wday)], month_names[@intCast(c.mo)], dnz(c.d), dnz(c.y) });
            const time_str = try std.fmt.allocPrint(self.arena, "{d:0>2}:{d:0>2}:{d:0>2} GMT+0000 (Coordinated Universal Time)", .{ dnz(c.h), dnz(c.mi), dnz(c.s) });
            if (eq(name, "toDateString") or eq(name, "toLocaleDateString")) return Value{ .string = date_str };
            if (eq(name, "toTimeString") or eq(name, "toLocaleTimeString")) return Value{ .string = time_str };
            return Value{ .string = try std.mem.concat(self.arena, u8, &.{ date_str, " ", time_str }) };
        }

        // ---- getters ----------------------------------------------------------
        if (std.math.isNan(t)) return Value{ .number = nan };
        const ti: i64 = @intFromFloat(t);
        const days = @divFloor(ti, ms_per_day);
        const tod = @mod(ti, ms_per_day);
        const c = civilFromDays(days);
        if (eq(name, "getFullYear") or eq(name, "getUTCFullYear")) return Value{ .number = @floatFromInt(c.y) };
        if (eq(name, "getMonth") or eq(name, "getUTCMonth")) return Value{ .number = @floatFromInt(c.m - 1) };
        if (eq(name, "getDate") or eq(name, "getUTCDate")) return Value{ .number = @floatFromInt(c.d) };
        if (eq(name, "getDay") or eq(name, "getUTCDay")) return Value{ .number = @floatFromInt(@mod(days + 4, 7)) };
        if (eq(name, "getHours") or eq(name, "getUTCHours")) return Value{ .number = @floatFromInt(@divFloor(tod, 3600000)) };
        if (eq(name, "getMinutes") or eq(name, "getUTCMinutes")) return Value{ .number = @floatFromInt(@mod(@divFloor(tod, 60000), 60)) };
        if (eq(name, "getSeconds") or eq(name, "getUTCSeconds")) return Value{ .number = @floatFromInt(@mod(@divFloor(tod, 1000), 60)) };
        if (eq(name, "getMilliseconds") or eq(name, "getUTCMilliseconds")) return Value{ .number = @floatFromInt(@mod(tod, 1000)) };
        if (eq(name, "getTimezoneOffset")) return Value{ .number = 0 };
        return null;
    }

    /// ISO 8601 rendering of a finite epoch-ms time (`2020-01-15T00:00:00.000Z`).
    fn dateISO(self: *Interpreter, t: f64) EvalError![]const u8 {
        const c = dateDecompose(t);
        return std.fmt.allocPrint(self.arena, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}.{d:0>3}Z", .{
            dnz(c.y), dnz(c.mo + 1), dnz(c.d), dnz(c.h), dnz(c.mi), dnz(c.s), dnz(c.ms),
        });
    }

    /// Compute a Date's epoch-ms from constructor arguments.
    pub fn dateTimeFromArgs(args: []const Value) f64 {
        if (args.len == 0) return 0; // (a real clock isn't wired; epoch is deterministic)
        if (args.len == 1) return args[0].toNumber();
        const y: i64 = @intFromFloat(@trunc(args[0].toNumber()));
        const mo: i64 = @intFromFloat(@trunc(args[1].toNumber()));
        const d: i64 = if (args.len > 2) @intFromFloat(@trunc(args[2].toNumber())) else 1;
        const h: i64 = if (args.len > 3) @intFromFloat(@trunc(args[3].toNumber())) else 0;
        const mi: i64 = if (args.len > 4) @intFromFloat(@trunc(args[4].toNumber())) else 0;
        const s: i64 = if (args.len > 5) @intFromFloat(@trunc(args[5].toNumber())) else 0;
        const millis: i64 = if (args.len > 6) @intFromFloat(@trunc(args[6].toNumber())) else 0;
        const days = daysFromCivil(y, mo + 1, d);
        return @floatFromInt(days * ms_per_day + h * 3600000 + mi * 60000 + s * 1000 + millis);
    }

    /// Build a `Map`, optionally populated from an iterable of `[k,v]` pairs.
    /// Whether `start`'s [[Prototype]] chain reaches the named constructor's
    /// `.prototype` — used to tell a WeakMap/WeakSet (whose chain includes
    /// %WeakMap.prototype%/%WeakSet.prototype%) from a Map/Set, including
    /// subclasses, since both kinds share the `is_map`/`is_set` storage.
    fn protoReachesCtorProto(self: *Interpreter, ctor_name: []const u8, start: ?*value.Object) bool {
        const cv = self.env.get(ctor_name) orelse return false;
        if (cv != .object) return false;
        const wp = cv.object.getOwn("prototype") orelse return false;
        if (wp != .object) return false;
        var cur = start;
        while (cur) |c| : (cur = c.proto) {
            if (c == wp.object) return true;
        }
        return false;
    }

    pub fn makeMap(self: *Interpreter, init_v: Value) EvalError!Value {
        const o = (try self.newObject()).object;
        o.is_map = true;
        if (self.new_target == .object and self.new_target.object.getOwn("prototype") != null) {
            o.proto = self.new_target.object.getOwn("prototype").?.object;
        } else if (self.env.get("Map")) |ctor| {
            if (ctor == .object) {
                if (ctor.object.getOwn("prototype")) |p| {
                    if (p == .object) o.proto = p.object;
                }
            }
        }
        o.is_weak = self.protoReachesCtorProto("WeakMap", o.proto);
        if (init_v == .object and init_v.object.is_array) {
            for (init_v.object.elements.items) |entry| {
                if (entry == .object and entry.object.is_array) {
                    const items = entry.object.elements.items;
                    _ = try self.mapMethod(o, "set", &.{ if (items.len > 0) items[0] else .undefined, if (items.len > 1) items[1] else .undefined });
                }
            }
        }
        return .{ .object = o };
    }

    /// Build a `Set`, optionally populated from an iterable of values.
    pub fn makeSet(self: *Interpreter, init_v: Value) EvalError!Value {
        const o = (try self.newObject()).object;
        o.is_set = true;
        // Proto from the in-flight constructor (`new Set`/`new WeakSet`), so a
        // WeakSet doesn't inherit Set.prototype; internal results default to Set.
        if (self.new_target == .object and self.new_target.object.getOwn("prototype") != null) {
            o.proto = self.new_target.object.getOwn("prototype").?.object;
        } else if (self.env.get("Set")) |ctor| {
            if (ctor == .object) {
                if (ctor.object.getOwn("prototype")) |p| {
                    if (p == .object) o.proto = p.object;
                }
            }
        }
        o.is_weak = self.protoReachesCtorProto("WeakSet", o.proto);
        if (init_v == .object and init_v.object.is_array) {
            for (init_v.object.elements.items) |v| _ = try self.setMethod(o, "add", &.{v});
        }
        return .{ .object = o };
    }

    fn mapMethod(self: *Interpreter, o: *value.Object, name: []const u8, args: []const Value) EvalError!?Value {
        const self_v = Value{ .object = o };
        if (eq(name, "set")) {
            const k = arg0(args);
            for (o.elements.items) |e| {
                if (value.sameValueZero(e.object.elements.items[0], k)) {
                    e.object.elements.items[1] = arg(args, 1);
                    return self_v;
                }
            }
            const pair = (try self.newArray()).object;
            try pair.elements.append(self.arena, k);
            try pair.elements.append(self.arena, arg(args, 1));
            try o.elements.append(self.arena, .{ .object = pair });
            return self_v;
        }
        if (eq(name, "get")) {
            for (o.elements.items) |e| {
                if (value.sameValueZero(e.object.elements.items[0], arg0(args))) return e.object.elements.items[1];
            }
            return Value.undefined;
        }
        if (eq(name, "has")) {
            for (o.elements.items) |e| {
                if (value.sameValueZero(e.object.elements.items[0], arg0(args))) return Value{ .boolean = true };
            }
            return Value{ .boolean = false };
        }
        if (eq(name, "delete")) {
            for (o.elements.items, 0..) |e, i| {
                if (value.sameValueZero(e.object.elements.items[0], arg0(args))) {
                    _ = o.elements.orderedRemove(i);
                    return Value{ .boolean = true };
                }
            }
            return Value{ .boolean = false };
        }
        if (eq(name, "clear")) {
            o.elements.clearRetainingCapacity();
            return Value.undefined;
        }
        if (eq(name, "forEach")) {
            const cb = arg0(args);
            for (o.elements.items) |e| _ = try self.callValueWithThis(cb, &.{ e.object.elements.items[1], e.object.elements.items[0], self_v }, arg(args, 1));
            return Value.undefined;
        }
        // Upsert proposal: return the existing value for `key`, else insert and
        // return a default (`getOrInsert`) or a computed value (`getOrInsertComputed`).
        if (eq(name, "getOrInsert") or eq(name, "getOrInsertComputed")) {
            const k = arg0(args);
            for (o.elements.items) |e| {
                if (value.sameValueZero(e.object.elements.items[0], k)) return e.object.elements.items[1];
            }
            const v = if (eq(name, "getOrInsertComputed")) blk: {
                const cb = arg(args, 1);
                if (!cb.isCallable()) return self.throwError("TypeError", "Map.prototype.getOrInsertComputed: callback is not a function");
                break :blk try self.callValue(cb, &.{k});
            } else arg(args, 1);
            _ = try self.mapMethod(o, "set", &.{ k, v });
            return v;
        }
        if (eq(name, "keys") or eq(name, "values") or eq(name, "entries")) {
            // Snapshot the current entries into an array and hand back its
            // iterator (keys → key, values → value, entries → [key, value]).
            const arr = (try self.newArray()).object;
            for (o.elements.items) |e| {
                const k = e.object.elements.items[0];
                const v = e.object.elements.items[1];
                const item: Value = if (eq(name, "keys")) k else if (eq(name, "values")) v else blk: {
                    const pair = (try self.newArray()).object;
                    try pair.elements.append(self.arena, k);
                    try pair.elements.append(self.arena, v);
                    break :blk .{ .object = pair };
                };
                try arr.elements.append(self.arena, item);
            }
            return try self.iteratorOf(.{ .object = arr });
        }
        return null;
    }

    fn setMethod(self: *Interpreter, o: *value.Object, name: []const u8, args: []const Value) EvalError!?Value {
        const self_v = Value{ .object = o };
        if (eq(name, "add")) {
            for (o.elements.items) |e| {
                if (value.sameValueZero(e, arg0(args))) return self_v;
            }
            try o.elements.append(self.arena, arg0(args));
            return self_v;
        }
        if (eq(name, "has")) {
            for (o.elements.items) |e| {
                if (value.sameValueZero(e, arg0(args))) return Value{ .boolean = true };
            }
            return Value{ .boolean = false };
        }
        if (eq(name, "delete")) {
            for (o.elements.items, 0..) |e, i| {
                if (value.sameValueZero(e, arg0(args))) {
                    _ = o.elements.orderedRemove(i);
                    return Value{ .boolean = true };
                }
            }
            return Value{ .boolean = false };
        }
        if (eq(name, "clear")) {
            o.elements.clearRetainingCapacity();
            return Value.undefined;
        }
        if (eq(name, "forEach")) {
            const cb = arg0(args);
            for (o.elements.items) |e| _ = try self.callValueWithThis(cb, &.{ e, e, self_v }, arg(args, 1));
            return Value.undefined;
        }
        // ES2024 set-operation methods. They take a set-like argument (the
        // set-record protocol: `size`, `has`, `keys`) and either return a new
        // Set (union/intersection/difference/symmetricDifference) or a boolean.
        const is_setop = eq(name, "union") or eq(name, "intersection") or eq(name, "difference") or
            eq(name, "symmetricDifference") or eq(name, "isSubsetOf") or eq(name, "isSupersetOf") or
            eq(name, "isDisjointFrom");
        if (is_setop) {
            const rec = try self.getSetRecord(arg0(args));
            if (eq(name, "union")) {
                const result = (try self.makeSet(.undefined)).object;
                for (o.elements.items) |e| _ = try self.setMethod(result, "add", &.{e});
                for (try self.collectSetKeys(rec)) |k| _ = try self.setMethod(result, "add", &.{k});
                return .{ .object = result };
            }
            if (eq(name, "intersection")) {
                const result = (try self.makeSet(.undefined)).object;
                for (o.elements.items) |e| {
                    if ((try self.recordHas(rec, e)))
                        _ = try self.setMethod(result, "add", &.{e});
                }
                return .{ .object = result };
            }
            if (eq(name, "difference")) {
                const result = (try self.makeSet(.undefined)).object;
                for (o.elements.items) |e| {
                    if (!(try self.recordHas(rec, e)))
                        _ = try self.setMethod(result, "add", &.{e});
                }
                return .{ .object = result };
            }
            if (eq(name, "symmetricDifference")) {
                const result = (try self.makeSet(.undefined)).object;
                for (o.elements.items) |e| _ = try self.setMethod(result, "add", &.{e});
                for (try self.collectSetKeys(rec)) |k| {
                    if ((try self.setMethod(o, "has", &.{k})).?.boolean)
                        _ = try self.setMethod(result, "delete", &.{k})
                    else
                        _ = try self.setMethod(result, "add", &.{k});
                }
                return .{ .object = result };
            }
            if (eq(name, "isSubsetOf")) {
                for (o.elements.items) |e| {
                    if (!(try self.recordHas(rec, e)))
                        return Value{ .boolean = false };
                }
                return Value{ .boolean = true };
            }
            if (eq(name, "isSupersetOf")) {
                for (try self.collectSetKeys(rec)) |k| {
                    if (!(try self.setMethod(o, "has", &.{k})).?.boolean) return Value{ .boolean = false };
                }
                return Value{ .boolean = true };
            }
            if (eq(name, "isDisjointFrom")) {
                for (o.elements.items) |e| {
                    if ((try self.recordHas(rec, e)))
                        return Value{ .boolean = false };
                }
                return Value{ .boolean = true };
            }
        }
        if (eq(name, "keys") or eq(name, "values") or eq(name, "entries")) {
            // Set keys/values both yield the element; entries yields [v, v].
            const arr = (try self.newArray()).object;
            for (o.elements.items) |e| {
                const item: Value = if (eq(name, "entries")) blk: {
                    const pair = (try self.newArray()).object;
                    try pair.elements.append(self.arena, e);
                    try pair.elements.append(self.arena, e);
                    break :blk .{ .object = pair };
                } else e;
                try arr.elements.append(self.arena, item);
            }
            return try self.iteratorOf(.{ .object = arr });
        }
        return null;
    }

    const SetRecord = struct { obj: *value.Object, has: Value, keys: Value, size: f64, is_set: bool };

    /// GetSetRecord: a set-like argument must be an object with a numeric `size`
    /// and callable `has`/`keys`. A native Set is recognized directly (its
    /// `has`/`keys` are dispatched, not stored properties), so it's served from
    /// its own elements rather than the protocol.
    fn getSetRecord(self: *Interpreter, v: Value) EvalError!SetRecord {
        if (v != .object) return self.throwError("TypeError", "argument is not an object");
        // GetSetRecord: rawSize = Get(obj,"size"); numSize = ToNumber(rawSize)
        // (a Symbol/BigInt size throws a TypeError); NaN throws; intSize < 0 is a
        // RangeError. ToNumber runs before `has`/`keys` are read.
        const size = try self.toNumberV(try self.getProperty(v, "size"));
        if (std.math.isNan(size)) return self.throwError("TypeError", "set-like 'size' is NaN");
        if (@trunc(size) < 0) return self.throwError("RangeError", "set-like 'size' is negative"); // intSize = ToIntegerOrInfinity
        if (v.object.is_set) return .{ .obj = v.object, .has = .undefined, .keys = .undefined, .size = size, .is_set = true };
        const has = try self.getProperty(v, "has");
        if (!has.isCallable()) return self.throwError("TypeError", "set-like 'has' is not callable");
        const keys = try self.getProperty(v, "keys");
        if (!keys.isCallable()) return self.throwError("TypeError", "set-like 'keys' is not callable");
        return .{ .obj = v.object, .has = has, .keys = keys, .size = size, .is_set = false };
    }

    /// Whether the set-like contains `elem` (a native Set scans its elements; a
    /// set-like calls its `has`).
    fn recordHas(self: *Interpreter, rec: SetRecord, elem: Value) EvalError!bool {
        if (rec.is_set) {
            for (rec.obj.elements.items) |e| if (value.sameValueZero(e, elem)) return true;
            return false;
        }
        return (try self.callValueWithThis(rec.has, &.{elem}, .{ .object = rec.obj })).toBoolean();
    }

    /// The set-like's elements (a native Set's `elements`, else its `keys()`).
    fn collectSetKeys(self: *Interpreter, rec: SetRecord) EvalError![]Value {
        if (rec.is_set) return rec.obj.elements.items;
        const iter = try self.callValueWithThis(rec.keys, &.{}, .{ .object = rec.obj });
        var list: std.ArrayListUnmanaged(Value) = .empty;
        while (true) {
            const r = try self.callMethod(iter, "next", &.{});
            if (r != .object) return self.throwError("TypeError", "iterator.next() did not return an object");
            if ((try self.getProperty(r, "done")).toBoolean()) break;
            try list.append(self.arena, try self.getProperty(r, "value"));
        }
        return list.items;
    }

    fn evalArrayLit(self: *Interpreter, elems: []*Node) EvalError!Value {
        const v = try self.newArray();
        for (elems) |en| {
            if (en.* == .spread) {
                try self.spreadInto(&v.object.elements, try self.eval(en.spread));
            } else if (en.* == .elision) {
                // A hole: a slot that reads as absent (skipped by iteration).
                try v.object.markHole(self.arena, v.object.elements.items.len);
                try v.object.elements.append(self.arena, .undefined);
            } else {
                try v.object.elements.append(self.arena, try self.eval(en));
            }
        }
        return v;
    }

    /// `index`-as-string -> array element index, or null if not an integer.
    pub fn arrayIndex(key: []const u8) ?usize {
        if (key.len == 0) return null;
        for (key) |c| if (!std.ascii.isDigit(c)) return null;
        return std.fmt.parseInt(usize, key, 10) catch null;
    }

    // ---- Proxy ------------------------------------------------------------

    /// Fetch trap `name` from a proxy's handler. Returns null when the trap is
    /// absent/undefined (the caller forwards to the target). Throws if the proxy
    /// is revoked or the trap isn't callable.
    fn proxyTrap(self: *Interpreter, o: *value.Object, name: []const u8) EvalError!?Value {
        if (o.proxy_revoked or o.proxy_handler == null)
            return self.throwError("TypeError", "Cannot perform 'get' on a proxy that has been revoked");
        const trap = try self.getProperty(.{ .object = o.proxy_handler.? }, name);
        if (trap == .undefined or trap == .null) return null;
        if (!trap.isCallable()) return self.throwError("TypeError", "proxy trap is not a function");
        return trap;
    }

    /// A property key as a JS value for passing to a trap. (String keys only for
    /// now; symbol-keyed trap arguments aren't reconstructed yet.)
    pub fn keyToValue(self: *Interpreter, key: []const u8) Value {
        // A symbol-encoded key recovers the original Symbol (registered in
        // `keyOf` when it was used as a property key); other keys are strings.
        if (value.isSymbolKey(key)) {
            if (self.symbols.get(key)) |sym| return .{ .object = sym };
        }
        return .{ .string = key };
    }

    /// Guard against unbounded proxy→target→proxy forwarding (which recurses
    /// without a JS call frame, so the normal call-depth limit wouldn't catch it).
    fn proxyDepth(self: *Interpreter) EvalError!void {
        if (self.depth >= max_call_depth) return self.throwError("RangeError", "Maximum call stack size exceeded");
    }

    fn proxyGet(self: *Interpreter, o: *value.Object, key: []const u8, receiver: Value) EvalError!Value {
        try self.proxyDepth();
        self.depth += 1;
        defer self.depth -= 1;
        const target = o.proxy_target.?;
        if (try self.proxyTrap(o, "get")) |trap| {
            return self.callValueWithThis(trap, &.{ .{ .object = target }, self.keyToValue(key), receiver }, .{ .object = o.proxy_handler.? });
        }
        return self.getProperty(.{ .object = target }, key);
    }

    fn proxySet(self: *Interpreter, o: *value.Object, key: []const u8, v: Value, receiver: Value) EvalError!void {
        try self.proxyDepth();
        self.depth += 1;
        defer self.depth -= 1;
        const target = o.proxy_target.?;
        if (try self.proxyTrap(o, "set")) |trap| {
            _ = try self.callValueWithThis(trap, &.{ .{ .object = target }, self.keyToValue(key), v, receiver }, .{ .object = o.proxy_handler.? });
            return;
        }
        return self.setMember(.{ .object = target }, key, v);
    }

    fn proxyHas(self: *Interpreter, o: *value.Object, key: []const u8) EvalError!bool {
        try self.proxyDepth();
        self.depth += 1;
        defer self.depth -= 1;
        const target = o.proxy_target.?;
        if (try self.proxyTrap(o, "has")) |trap| {
            return (try self.callValueWithThis(trap, &.{ .{ .object = target }, self.keyToValue(key) }, .{ .object = o.proxy_handler.? })).toBoolean();
        }
        if (target.proxy_handler != null) return self.proxyHas(target, key);
        return hasProperty(target, key);
    }

    fn proxyDelete(self: *Interpreter, o: *value.Object, key: []const u8) EvalError!bool {
        try self.proxyDepth();
        self.depth += 1;
        defer self.depth -= 1;
        const target = o.proxy_target.?;
        if (try self.proxyTrap(o, "deleteProperty")) |trap| {
            return (try self.callValueWithThis(trap, &.{ .{ .object = target }, self.keyToValue(key) }, .{ .object = o.proxy_handler.? })).toBoolean();
        }
        return self.deleteOwn(target, key);
    }

    /// `ownKeys` trap → an array of keys (string values). Falls back to the
    /// target's own string keys.
    /// An object's [[OwnPropertyKeys]] as encoded key strings — proxy-aware, and
    /// including an array's dense element indices and `length` (which live
    /// outside the shape).
    pub fn objectOwnKeysList(self: *Interpreter, t: *value.Object) EvalError![]const []const u8 {
        if (t.proxy_handler != null or t.proxy_revoked) return self.proxyOwnKeys(t);
        if (t.is_array) {
            var list: std.ArrayListUnmanaged([]const u8) = .empty;
            var i: usize = 0;
            while (i < t.elements.items.len) : (i += 1) {
                if (t.isHole(i)) continue;
                try list.append(self.arena, try std.fmt.allocPrint(self.arena, "{d}", .{i}));
            }
            for (try t.ownKeys(self.arena)) |k| try list.append(self.arena, k);
            try list.append(self.arena, "length");
            return list.items;
        }
        return t.ownKeys(self.arena);
    }

    pub fn proxyOwnKeys(self: *Interpreter, o: *value.Object) EvalError![]const []const u8 {
        try self.proxyDepth();
        self.depth += 1;
        defer self.depth -= 1;
        const target = o.proxy_target.?;
        if (try self.proxyTrap(o, "ownKeys")) |trap| {
            const res = try self.callValueWithThis(trap, &.{.{ .object = target }}, .{ .object = o.proxy_handler.? });
            if (res != .object or !res.object.is_array) return self.throwError("TypeError", "ownKeys trap must return an array");
            // CreateListFromArrayLike(types: String, Symbol): every element must
            // be a String or Symbol.
            for (res.object.elements.items) |k| {
                if (k != .string and !(k == .object and k.object.is_symbol))
                    return self.throwError("TypeError", "ownKeys trap result includes a non-String, non-Symbol key");
            }
            var list: std.ArrayListUnmanaged([]const u8) = .empty;
            for (res.object.elements.items) |k| try list.append(self.arena, try self.keyOf(k));
            // [[OwnPropertyKeys]] invariants: no duplicates; every
            // non-configurable target key must be present; for a non-extensible
            // target the result must be exactly the target's keys.
            var seen: std.StringHashMapUnmanaged(void) = .empty;
            for (list.items) |k| {
                if (seen.contains(k)) return self.throwError("TypeError", "ownKeys trap result contains duplicate keys");
                try seen.put(self.arena, k, {});
            }
            const extensible = target.extensible;
            const tkeys = try self.objectOwnKeysList(target);
            var has_nonconfig = false;
            for (tkeys) |tk| {
                if (objectHasOwn(target, tk) and !target.getAttr(tk).configurable) has_nonconfig = true;
            }
            if (!extensible or has_nonconfig) {
                var unchecked: std.StringHashMapUnmanaged(void) = .empty;
                for (list.items) |k| try unchecked.put(self.arena, k, {});
                // Every non-configurable target key must appear.
                for (tkeys) |tk| {
                    if (!objectHasOwn(target, tk) or target.getAttr(tk).configurable) continue;
                    if (!unchecked.remove(tk)) return self.throwError("TypeError", "ownKeys trap omitted a non-configurable key");
                }
                if (!extensible) {
                    // Non-extensible: the remaining (configurable) target keys must
                    // also appear, and nothing extra may be present.
                    for (tkeys) |tk| {
                        if (!objectHasOwn(target, tk) or !target.getAttr(tk).configurable) continue;
                        if (!unchecked.remove(tk)) return self.throwError("TypeError", "ownKeys trap omitted a key on a non-extensible target");
                    }
                    if (unchecked.count() != 0) return self.throwError("TypeError", "ownKeys trap added a key absent from a non-extensible target");
                }
            }
            return list.items;
        }
        return self.objectOwnKeysList(target);
    }

    pub fn getProperty(self: *Interpreter, recv: Value, key: []const u8) EvalError!Value {
        switch (recv) {
            .object => |o| {
                if (o.proxy_handler != null or o.proxy_revoked) return self.proxyGet(o, key, recv);
                // Legacy `caller`: a *non-strict ordinary* function (not strict,
                // arrow, generator, async, or bound) reads `null` for `.caller`,
                // shadowing the inherited %ThrowTypeError% poison pill — which
                // still fires for strict/bound functions and for `.arguments`.
                if (std.mem.eql(u8, key, "caller") and o.bound == null and o.getOwn(key) == null) {
                    if (funcOf(recv)) |f| {
                        if (!f.is_strict and !f.is_arrow and !f.is_generator and !f.is_async) return .null;
                    }
                }
                // A (non-arrow) function's `.prototype` is an own data property,
                // materialized lazily on first access — every [[Construct]]-able
                // function has one, with a `constructor` back-reference. Without
                // this a plain `Test262Error.prototype.toString = …` (and any
                // `f.prototype.x = …`) read undefined and threw.
                if (std.mem.eql(u8, key, "prototype") and o.js_func != null and o.getOwn("prototype") == null) {
                    if (funcOf(recv)) |f| {
                        if (!f.is_arrow) {
                            const proto = try self.protoObject(o);
                            // `Ctor.prototype` is { writable, !enumerable, !configurable };
                            // its `constructor` back-link is { writable, !enumerable, configurable }.
                            try o.setAttr(self.arena, "prototype", .{ .writable = true, .enumerable = false, .configurable = false });
                            try self.setProp(proto, "constructor", recv);
                            try proto.setAttr(self.arena, "constructor", .{ .writable = true, .enumerable = false, .configurable = true });
                            return .{ .object = proto };
                        }
                    }
                }
                if (o.array_buffer) |ab| {
                    if (std.mem.eql(u8, key, "byteLength")) return .{ .number = @floatFromInt(if (ab.detached) 0 else ab.data.len) };
                }
                if (o.typed_array) |ta| {
                    const detached = ta.buffer.array_buffer.?.detached;
                    if (std.mem.eql(u8, key, "length")) return .{ .number = @floatFromInt(if (detached) 0 else ta.length) };
                    if (std.mem.eql(u8, key, "byteLength")) return .{ .number = @floatFromInt(if (detached) 0 else ta.length * ta.kind.byteSize()) };
                    if (std.mem.eql(u8, key, "byteOffset")) return .{ .number = @floatFromInt(if (detached) 0 else ta.byte_offset) };
                    if (std.mem.eql(u8, key, "buffer")) return .{ .object = ta.buffer };
                    if (std.mem.eql(u8, key, "BYTES_PER_ELEMENT")) return .{ .number = @floatFromInt(ta.kind.byteSize()) };
                    if (arrayIndex(key)) |i| {
                        if (detached or i >= ta.length) return .undefined;
                        return value.taRead(ta, i);
                    }
                    // other keys (methods, constructor, @@toStringTag) fall through.
                }
                if (o.is_array) {
                    if (std.mem.eql(u8, key, "length"))
                        return .{ .number = @floatFromInt(@max(o.elements.items.len, o.array_len)) };
                    // An accessor defined on an index (via defineProperty) wins
                    // over the dense element store, so the getter is invoked.
                    if (arrayIndex(key)) |i| {
                        // A present (non-hole) dense element with no index accessor
                        // is returned directly; a hole falls through to the proto
                        // chain so an inherited index (e.g. `Array.prototype[0]`) is
                        // seen, and an accessor likewise wins over the store.
                        if (o.getAccessor(key) == null and i < o.elements.items.len and !o.isHole(i)) return o.elements.items[i];
                        // else fall through: hole, accessor, or a sparse named property.
                    }
                }
                // A String-wrapper object exposes `length` and indexed chars as
                // own integer-keyed properties (`new String("ab").length === 2`,
                // `[0] === "a"`).
                if (o.prim) |p| {
                    if (p == .string) {
                        if (std.mem.eql(u8, key, "length")) return .{ .number = @floatFromInt(p.string.len) };
                        if (arrayIndex(key)) |i| {
                            if (i < p.string.len) return .{ .string = try self.arena.dupe(u8, p.string[i .. i + 1]) };
                        }
                    }
                }
                // Accessor or data, then walk the prototype chain (a native/bound
                // function with no explicit prototype inherits from
                // %Function.prototype% — so `fn.constructor`, `fn.call` as a
                // value, etc. resolve).
                var cur: ?*value.Object = o;
                while (cur) |c| {
                    if (c.getAccessor(key)) |acc| {
                        // An explicit `get: undefined` is stored as the undefined
                        // value but means "no getter".
                        if (acc.get) |g| {
                            if (g != .undefined) return self.callValueWithThis(g, &.{}, recv);
                        }
                        return .undefined; // accessor with no getter
                    }
                    if (c.getOwn(key)) |v| return v;
                    cur = self.effectiveProto(c);
                }
                // On the global object, an absent own property falls back to the
                // global lexical bindings, so `globalThis.Math`, `this.parseInt`,
                // etc. resolve to the installed globals.
                if (self.global_object != null and o == self.global_object.?) {
                    if (rootEnv(self.env).get(key)) |v| return v;
                }
                // Accessing a private member the object doesn't carry is a brand
                // violation — a TypeError, not `undefined`.
                if (value.isPrivateKey(key)) return self.throwError("TypeError", "Cannot read private member from an object whose class did not declare it");
                // `.constructor` falls back to the kind's global constructor
                // (we don't wire instance prototypes yet).
                if (std.mem.eql(u8, key, "constructor")) {
                    if (self.constructorOf(recv)) |ctor| return ctor;
                }
                return .undefined;
            },
            .string => |s| {
                if (std.mem.eql(u8, key, "length")) return .{ .number = @floatFromInt(s.len) };
                if (arrayIndex(key)) |i| {
                    if (i < s.len) return .{ .string = try self.arena.dupe(u8, s[i .. i + 1]) };
                    return .undefined;
                }
                if (std.mem.eql(u8, key, "constructor")) {
                    if (self.constructorOf(recv)) |ctor| return ctor;
                }
                return .undefined;
            },
            .undefined, .null => return self.throwError("TypeError", "cannot read property of null or undefined"),
            else => {
                if (std.mem.eql(u8, key, "constructor")) {
                    if (self.constructorOf(recv)) |ctor| return ctor;
                }
                return .undefined;
            },
        }
    }

    /// The global constructor for a value's kind (`[].constructor === Array`).
    /// A fallback used when the prototype chain doesn't supply `constructor`
    /// (instance prototypes aren't wired yet).
    fn constructorOf(self: *Interpreter, recv: Value) ?Value {
        const name: []const u8 = switch (recv) {
            .string => "String",
            .number => "Number",
            .boolean => "Boolean",
            .object => |o| if (o.is_array) "Array" else if (o.is_regex) "RegExp" else if (o.is_symbol) "Symbol" else if (o.is_error) (if (o.error_name.len > 0) o.error_name else "Error") else if (o.is_map) "Map" else if (o.is_set) "Set" else if (o.is_date) "Date" else if (o.prim) |p| (switch (p) {
                .number => "Number",
                .string => "String",
                .boolean => "Boolean",
                else => "Object",
            }) else if (o.isCallableObject()) "Function" else "Object",
            else => return null,
        };
        return self.env.get(name);
    }

    // ---- destructuring ----------------------------------------------------

    /// Bind a value to a destructuring target. `declare` selects whether leaf
    /// identifiers are declared in the current scope (`let {a}=…`) or assigned
    /// to an existing binding / member (`({a}=…)` and parameter binding uses
    /// declare).
    /// VM entry for `bind_pattern`: destructure `val` into `target` with the
    /// given mode (0 var, 1 let, 2 const, 3 assignment), reusing `bindPattern`.
    pub fn bindPatternVM(self: *Interpreter, target: *Node, val: Value, mode: u32) EvalError!void {
        const saved_const = self.binding_const;
        const saved_hoist = self.binding_hoisted;
        self.binding_const = (mode == 2);
        self.binding_hoisted = false;
        defer {
            self.binding_const = saved_const;
            self.binding_hoisted = saved_hoist;
        }
        try self.bindPattern(target, val, mode != 3);
    }

    fn bindPattern(self: *Interpreter, target: *Node, val: Value, declare: bool) EvalError!void {
        switch (target.*) {
            .identifier => |name| if (declare)
                (if (self.binding_hoisted)
                    try self.globalDefine(name, val)
                else if (self.binding_const)
                    try self.env.putConst(name, val)
                else
                    try self.env.put(name, val))
            else
                // Assignment-form target: route through `assignTo` so const/TDZ/
                // strict/with checks apply (e.g. `[c] = …` with const `c`).
                try self.assignTo(target, val),
            .member => |m| { // assignment destructuring into obj.prop / arr[i]
                const recv = try self.eval(m.object);
                const key = try self.memberKey(m.property, m.computed);
                try self.setMember(recv, key, val);
            },
            .obj_pattern => |p| try self.destructureObject(p.props, p.rest, val, declare),
            .arr_pattern => |p| try self.destructureArray(p.elems, p.rest, val, declare),
            else => return self.throwError("SyntaxError", "invalid destructuring target"),
        }
    }

    fn destructureObject(self: *Interpreter, props: []ast.ObjPatProp, rest: ?[]const u8, val: Value, declare: bool) EvalError!void {
        if (val == .undefined or val == .null)
            return self.throwError("TypeError", "cannot destructure null or undefined");
        var consumed: std.ArrayListUnmanaged([]const u8) = .empty;
        for (props) |prop| {
            const key = if (prop.key_expr) |ke| try self.keyOf(try self.eval(ke)) else prop.key;
            try consumed.append(self.arena, key);
            var v = try self.getProperty(val, key);
            if (v == .undefined) {
                if (prop.default) |d| {
                    v = try self.eval(d);
                    if (prop.target.* == .identifier) try self.maybeNameAnon(v, d, prop.target.identifier);
                }
            }
            try self.bindPattern(prop.target, v, declare);
        }
        if (rest) |rest_name| {
            const rest_obj = try self.newObject();
            if (val == .object) {
                // Object rest copies only the *enumerable* own properties.
                const keys = try val.object.enumerableKeys(self.arena);
                outer: for (keys) |k| {
                    for (consumed.items) |c| {
                        if (std.mem.eql(u8, c, k)) continue :outer;
                    }
                    // Copy via [[Get]] so an accessor's getter runs (and a data
                    // property's value is read), landing as a plain data prop.
                    try self.setProp(rest_obj.object, k, try self.getProperty(val, k));
                }
            }
            if (declare) try self.env.put(rest_name, rest_obj) else try self.env.assign(rest_name, rest_obj);
        }
    }

    fn destructureArray(self: *Interpreter, elems: []ast.ArrPatElem, rest: ?*Node, val: Value, declare: bool) EvalError!void {
        if (val == .undefined or val == .null)
            return self.throwError("TypeError", "cannot destructure null or undefined");

        // Fast path: a real array (whose `Array.prototype[Symbol.iterator]` is
        // still the native one) or a string — index directly, no iterator object
        // churn. A deleted/overridden array iterator falls to the general path.
        if ((val == .object and val.object.is_array and self.arrayIterIntact()) or val == .string) {
            var idx: usize = 0;
            for (elems) |elem| {
                var v = try self.elementAt(val, idx);
                idx += 1;
                if (elem.target) |t| {
                    if (v == .undefined) {
                        if (elem.default) |d| {
                            v = try self.eval(d);
                            if (t.* == .identifier) try self.maybeNameAnon(v, d, t.identifier);
                        }
                    }
                    try self.bindPattern(t, v, declare);
                }
            }
            if (rest) |rest_target| {
                const rest_arr = try self.newArray();
                const len = iterableLen(val);
                while (idx < len) : (idx += 1) {
                    try rest_arr.object.elements.append(self.arena, try self.elementAt(val, idx));
                }
                try self.bindPattern(rest_target, rest_arr, declare);
            }
            return;
        }

        // General path: drive the iterator protocol, so array destructuring
        // works over generators, Set/Map, the `arguments` object, and any user
        // value with `[Symbol.iterator]`. `iteratorOf` throws the spec's
        // TypeError for a genuinely non-iterable value (e.g. a number or a
        // plain object), so destructuring those still fails the right way.
        const iter_obj = try self.iteratorOf(val);
        var done = false;
        for (elems) |elem| {
            var v: Value = .undefined;
            if (!done) {
                const res = try self.callMethod(iter_obj, "next", &.{});
                if ((try self.getProperty(res, "done")).toBoolean()) done = true else v = try self.getProperty(res, "value");
            }
            if (elem.target) |t| {
                if (v == .undefined) {
                    if (elem.default) |d| v = try self.eval(d);
                }
                try self.bindPattern(t, v, declare);
            }
        }
        if (rest) |rest_target| {
            const rest_arr = try self.newArray();
            while (!done) {
                const res = try self.callMethod(iter_obj, "next", &.{});
                if ((try self.getProperty(res, "done")).toBoolean()) break;
                try rest_arr.object.elements.append(self.arena, try self.getProperty(res, "value"));
            }
            try self.bindPattern(rest_target, rest_arr, declare);
            return; // a rest element always exhausts the iterator (no close)
        }
        // IteratorClose: if destructuring finished before the iterator was
        // exhausted, call its `return()` to let it clean up.
        if (!done) try self.iteratorClose(iter_obj);
    }

    /// IteratorClose: invoke `iterator.return()` if present (generators are
    /// closed through their dispatched `return`). The result is discarded; a
    /// throw propagates (normal-completion close).
    pub fn iteratorClose(self: *Interpreter, iter: Value) EvalError!void {
        if (iter == .object and iter.object.gen != null) {
            _ = try self.callMethod(iter, "return", &.{});
            return;
        }
        const ret = try self.getProperty(iter, "return");
        if (ret.isCallable()) _ = try self.callValueWithThis(ret, &.{}, iter);
    }

    /// Element `i` of an array/string for array destructuring (undefined if out
    /// of range). Non-iterable values raise a TypeError.
    fn elementAt(self: *Interpreter, val: Value, i: usize) EvalError!Value {
        switch (val) {
            .object => |o| {
                if (!o.is_array) return self.throwError("TypeError", "value is not iterable");
                return if (i < o.elements.items.len) o.elements.items[i] else .undefined;
            },
            .string => |s| {
                if (i >= s.len) return .undefined;
                return .{ .string = try self.arena.dupe(u8, s[i .. i + 1]) };
            },
            else => return self.throwError("TypeError", "value is not iterable"),
        }
    }

    fn iterableLen(val: Value) usize {
        return switch (val) {
            .object => |o| if (o.is_array) o.elements.items.len else 0,
            .string => |s| s.len,
            else => 0,
        };
    }

    /// Assign to a named variable with the same immutability checks `assignTo`
    /// applies, for the bytecode VM's `store_var` (which would otherwise bypass
    /// them): a `const` reassignment throws; a function-expression name throws in
    /// strict code and is a no-op in sloppy code.
    pub fn assignVarVM(self: *Interpreter, name: []const u8, v: Value) EvalError!void {
        if (self.env.isAlias(name)) return self.throwError("TypeError", "Assignment to constant variable.");
        if (self.env.isConst(name)) |c| {
            if (c) return self.throwError("TypeError", "Assignment to constant variable.");
        }
        if (self.env.isFnName(name)) {
            if (self.strict) return self.throwError("TypeError", "Assignment to constant variable.");
            return;
        }
        try self.env.assign(name, v);
    }

    fn assignTo(self: *Interpreter, target: *Node, v: Value) EvalError!void {
        switch (target.*) {
            .identifier => |name| {
                // A `with` object that provides this name (and isn't shadowed by a
                // closer binding) takes the write (honoring `[Symbol.unscopables]`).
                if (try self.assignWithObject(name)) |o| return self.setMember(.{ .object = o }, name, v);
                // Assigning to a binding still in its TDZ is a ReferenceError.
                if (self.env.get(name)) |cur| {
                    if (self.isTdz(cur)) return self.throwError("ReferenceError", name);
                }
                // An imported binding is immutable (a module indirect binding):
                // assigning to it is a TypeError.
                if (self.env.isAlias(name)) return self.throwError("TypeError", "Assignment to constant variable.");
                // Assigning to a `const` binding is a TypeError.
                if (self.env.isConst(name)) |c| {
                    if (c) return self.throwError("TypeError", "Assignment to constant variable.");
                }
                // A named function expression's own name is immutable: throw in
                // strict code, silently ignore in sloppy code.
                if (self.env.isFnName(name)) {
                    if (self.strict) return self.throwError("TypeError", "Assignment to constant variable.");
                    return;
                }
                // Strict mode forbids creating a global by assigning to an
                // undeclared binding (sloppy mode silently creates one).
                if (self.strict and self.env.get(name) == null and self.globalProp(name) == null)
                    return self.throwError("ReferenceError", name);
                try self.env.assign(name, v);
            },
            .member => |m| {
                const recv = try self.eval(m.object);
                if (m.computed) |ce| {
                    // Same spec order as a member read: key expression first, then
                    // the null/undefined base check, then ToPropertyKey.
                    const kv = try self.eval(ce);
                    if (recv == .null or recv == .undefined)
                        return self.throwError("TypeError", "cannot set property of null or undefined");
                    return self.setMember(recv, try self.keyOf(kv), v);
                }
                try self.setMember(recv, m.property, v);
            },
            // Assignment destructuring: `[a, b] = x` / `({a} = o)`.
            .obj_pattern, .arr_pattern => try self.bindPattern(target, v, false),
            else => return self.throwError("ReferenceError", "invalid assignment target"),
        }
    }

    /// Assign `recv[key] = v`. Arrays route integer keys to the dense element
    /// store (growing with holes); everything else is a named property. Shared
    /// by the tree-walker and the VM.
    pub fn setMember(self: *Interpreter, recv: Value, key: []const u8, v: Value) EvalError!void {
        if (recv != .object) {
            // Setting a property on null/undefined always throws; on any other
            // primitive (number/string/boolean) sloppy mode is a silent no-op
            // while strict mode throws a TypeError.
            if (recv == .null or recv == .undefined)
                return self.throwError("TypeError", "Cannot set property of null or undefined");
            return if (self.strict) self.throwError("TypeError", "Cannot create property on a primitive") else {};
        }
        const o = recv.object;
        if (o.proxy_handler != null or o.proxy_revoked) return self.proxySet(o, key, v, recv);
        if (o.typed_array) |ta| {
            // An integer-keyed write coerces the value to a number and stores it
            // in the buffer; out-of-bounds / detached writes are silently ignored
            // (a canonical numeric index never falls through to a named property).
            if (arrayIndex(key)) |i| {
                const num = (try self.toNumberV(v));
                if (!ta.buffer.array_buffer.?.detached and i < ta.length) value.taWrite(ta, i, num);
                return;
            }
            // non-index keys fall through to ordinary [[Set]].
        }
        if (o.is_array) {
            if (std.mem.eql(u8, key, "length")) {
                // ArraySetLength: newLen = ToUint32(value); if it differs from
                // ToNumber(value) the length isn't a valid array index → RangeError.
                // Both coercions run through the throwing ToNumber so a boolean,
                // string, or `new Number(1)`/`new String("1")` wrapper is honored
                // (`x.length = true` → 1, `x.length = new Number(1)` → 1).
                const n = try self.toNumberV(v);
                const u = value.Value.uint32FromF64(n);
                if (@as(f64, @floatFromInt(u)) != n) return self.throwError("RangeError", "Invalid array length");
                // ArraySetLength: a non-writable `length` rejects the assignment
                // (the RangeError above still precedes this) — sloppy silently,
                // strict throws.
                if (o.attrs != null and !o.getAttr("length").writable)
                    return if (self.strict) self.throwError("TypeError", "Cannot assign to read only property 'length'") else {};
                if (u < o.elements.items.len) {
                    o.elements.shrinkRetainingCapacity(u);
                    o.array_len = 0; // physical length is now exactly `u`
                } else {
                    o.array_len = u; // grow logically; don't materialize holes
                }
                return;
            }
            // An accessor defined on an index routes the write to its setter
            // (handled by the prototype-chain setter walk below), not the store.
            if (arrayIndex(key) != null and o.getAccessor(key) != null) {
                // fall through to the setter walk
            } else if (arrayIndex(key) != null and arrayProtoAccessor(o, key) and
                !(arrayIndex(key).? < o.elements.items.len and !o.isHole(arrayIndex(key).?)))
            {
                // The index isn't an own present element and an inherited accessor
                // (e.g. `Array.prototype[0]`) intercepts the write — OrdinarySet
                // routes to its setter; fall through to the setter walk.
            } else if (arrayIndex(key)) |i| {
                // A per-index descriptor (recorded in `attrs`) may mark the
                // element non-writable: sloppy ignores the write, strict throws.
                if (o.attrs != null and !o.getAttr(key).writable)
                    return if (self.strict) self.throwError("TypeError", "Cannot assign to read only property") else {};
                if (i < o.elements.items.len) {
                    o.elements.items[i] = v;
                    o.clearHole(i); // an assignment fills a hole
                    return;
                }
                // Grow densely only for near-contiguous, bounded indices; large
                // or gappy indices become sparse named properties (no giant alloc).
                const dense_cap: usize = 1 << 24;
                if (i < dense_cap and i <= o.elements.items.len + 1024) {
                    const gap_start = o.elements.items.len;
                    while (o.elements.items.len <= i) try o.elements.append(self.arena, .undefined);
                    o.elements.items[i] = v;
                    o.clearHole(i);
                    // Indices skipped over by a sparse assignment are holes.
                    var g = gap_start;
                    while (g < i) : (g += 1) try o.markHole(self.arena, g);
                    return;
                }
                // A large/gappy index becomes a sparse named property; the array's
                // logical length still extends past it (`a[1e9]=x` → length 1e9+1).
                o.array_len = @max(o.array_len, i + 1);
                // fall through: store as a named (sparse) property
            }
        }
        // A setter anywhere on the prototype chain intercepts the assignment.
        var cur: ?*value.Object = o;
        while (cur) |c| {
            if (c.getAccessor(key)) |acc| {
                if (acc.set) |s| {
                    // An explicit `set: undefined` means "no setter".
                    if (s != .undefined) {
                        _ = try self.callValueWithThis(s, &.{v}, recv);
                        return;
                    }
                }
                // Accessor with no setter: sloppy ignores, strict throws.
                return if (self.strict) self.throwError("TypeError", "Cannot set property which has only a getter") else {};
            }
            cur = c.proto;
        }
        // [[Set]] attribute checks: sloppy silently ignores rejection, strict throws.
        if (o.getOwn(key)) |_| {
            if (!o.getAttr(key).writable)
                return if (self.strict) self.throwError("TypeError", "Cannot assign to read only property") else {};
        } else if (!o.extensible) {
            return if (self.strict) self.throwError("TypeError", "Cannot add property, object is not extensible") else {};
        }
        try self.setProp(o, key, v);
    }

    /// `delete obj[key]`: remove an own property, returning whether the object
    /// no longer has it. Non-configurable own properties can't be deleted
    /// (returns false); a missing property "deletes" successfully (true).
    pub fn deleteOwn(self: *Interpreter, o: *value.Object, key: []const u8) EvalError!bool {
        if (o.proxy_handler != null or o.proxy_revoked) return self.proxyDelete(o, key);
        // Accessor property.
        if (o.accessors) |m| {
            if (m.getPtr(key) != null) {
                if (!o.getAttr(key).configurable) return false;
                _ = m.remove(key);
                // An accessor on an array index leaves a hole behind.
                if (o.is_array) {
                    if (arrayIndex(key)) |i| if (i < o.elements.items.len) try o.markHole(self.arena, i);
                }
                return true;
            }
        }
        // Dense array element → leave a hole (reads as absent), length unchanged.
        // A per-index descriptor may mark it non-configurable (delete fails).
        if (o.is_array) {
            if (arrayIndex(key)) |i| {
                if (i < o.elements.items.len) {
                    if (o.attrs != null and !o.getAttr(key).configurable) return false;
                    o.elements.items[i] = .undefined;
                    try o.markHole(self.arena, i);
                    return true;
                }
            }
        }
        // Named data property: nothing to do if absent; reject if non-configurable.
        if (o.getOwn(key) == null) return true;
        if (!o.getAttr(key).configurable) return false;
        // Rebuild shape+slots without `key` (delete is rare; correctness over speed).
        const keys = try o.ownKeys(self.arena);
        const Entry = struct { k: []const u8, v: Value, a: value.PropAttr };
        var saved: std.ArrayListUnmanaged(Entry) = .empty;
        for (keys) |k| {
            if (std.mem.eql(u8, k, key)) continue;
            // Accessor-only keys have no data slot (they live in `o.accessors`,
            // which this shape/slots rebuild leaves untouched) — skip them rather
            // than unwrapping a null slot.
            const v = o.getOwn(k) orelse continue;
            try saved.append(self.arena, .{ .k = k, .v = v, .a = o.getAttr(k) });
        }
        o.shape = self.root_shape;
        o.slots = .empty;
        for (saved.items) |e| {
            try o.setOwn(self.arena, self.root_shape, e.k, e.v);
            try o.setAttr(self.arena, e.k, e.a);
        }
        return true;
    }

    /// Define an accessor (get/set) on an object via its `setAccessor`.
    fn defineAccessor(self: *Interpreter, obj: *value.Object, name: []const u8, get: ?Value, set: ?Value) EvalError!void {
        try obj.setAccessor(self.arena, name, get, set);
    }

    /// Call `recv[name](args)` with `this = recv`. Dispatches the builtin
    /// methods that aren't stored as own properties first. Shared by the
    /// tree-walker's `evalCall` and the VM's `call_method`.
    pub fn callMethod(self: *Interpreter, recv: Value, name: []const u8, args: []const Value) EvalError!Value {
        // A real (possibly user-reassigned) method property found on the receiver
        // or its prototype chain takes precedence over the engine's native
        // fast-path, so an override like `Date.prototype.toString =
        // Object.prototype.toString` is honored. The brand fast-paths
        // (dateMethod / arrayMethod / mapMethod / …) remain the implementation of
        // the unshadowed intrinsics and the fallback for method names that aren't
        // installed as real own properties (synthesized push/getDay/etc.).
        const method = try self.getProperty(recv, name);
        if (method == .object and method.object.isCallableObject())
            return self.callValueWithThis(method, args, recv);
        if (try self.builtinMethod(recv, name, args)) |result| return result;
        return self.callValueWithThis(method, args, recv);
    }

    /// Obtain an iterator (an object with a `.next()` returning `{value, done}`)
    /// for `v` — the iterator-protocol entry point used by `yield*` (and, later,
    /// spread / `Array.from` / VM `for-of`). Generators are their own iterator;
    /// an object that already has a `next` method is returned as-is; arrays and
    /// strings are wrapped in an index cursor.
    pub fn iteratorOf(self: *Interpreter, v: Value) EvalError!Value {
        switch (v) {
            .object => |o| {
                if (o.gen != null) return v;
                // A user-defined `[Symbol.iterator]()` method takes precedence.
                if (self.symbolIteratorKey()) |ik| {
                    if (hasProperty(o, ik)) {
                        const itfn = try self.getProperty(v, ik);
                        if (itfn == .object and itfn.object.isCallableObject())
                            return try self.callValueWithThis(itfn, &.{}, v);
                    }
                }
                // An array honors a deleted/overridden `Array.prototype[Symbol.iterator]`.
                if (o.is_array) {
                    switch (self.arrayIterState()) {
                        .intact => return self.makeCursorIterator(v),
                        .deleted => return self.throwError("TypeError", "value is not iterable"),
                        .custom => |m| {
                            if (!m.isCallable()) return self.throwError("TypeError", "value is not iterable");
                            return try self.callValueWithThis(m, &.{}, v);
                        },
                    }
                }
                if (hasProperty(o, "next")) return v; // already an iterator (manual or generator-like)
                // Sets (element = value) and Maps (element = [k,v] pair) iterate
                // their dense `elements` store via an index cursor.
                if (o.is_set or o.is_map) return self.makeCursorIterator(v);
                return self.throwError("TypeError", "value is not iterable");
            },
            .string => return self.makeCursorIterator(v),
            else => return self.throwError("TypeError", "value is not iterable"),
        }
    }

    /// Whether `v` is iterable: a string, array, generator, or an object with a
    /// `[Symbol.iterator]` method. (Used by `Array.from` to choose the iterator
    /// path vs the array-like/length path.)
    pub fn isIterable(self: *Interpreter, v: Value) bool {
        switch (v) {
            .string => return true,
            .object => |o| {
                if (o.is_array or o.is_set or o.is_map or o.gen != null) return true;
                if (hasProperty(o, "next")) return true; // a manual iterator object
                if (self.symbolIteratorKey()) |ik| return hasProperty(o, ik);
                return false;
            },
            else => return false,
        }
    }

    /// The internal key of the well-known `Symbol.iterator` (from the `Symbol`
    /// global), for resolving `obj[Symbol.iterator]`.
    fn symbolIteratorKey(self: *Interpreter) ?[]const u8 {
        const sym = self.env.get("Symbol") orelse return null;
        if (sym != .object) return null;
        const it = sym.object.getOwn("iterator") orelse return null;
        if (it != .object or !it.object.is_symbol) return null;
        return it.object.sym_key;
    }

    fn symbolAsyncIteratorKey(self: *Interpreter) ?[]const u8 {
        const sym = self.env.get("Symbol") orelse return null;
        if (sym != .object) return null;
        const it = sym.object.getOwn("asyncIterator") orelse return null;
        if (it != .object or !it.object.is_symbol) return null;
        return it.object.sym_key;
    }

    /// The internal property key of a well-known `Symbol.<name>` (e.g. `species`).
    pub fn wellKnownSymbolKey(self: *Interpreter, name: []const u8) ?[]const u8 {
        const sym = self.env.get("Symbol") orelse return null;
        if (sym != .object) return null;
        const it = sym.object.getOwn(name) orelse return null;
        if (it != .object or !it.object.is_symbol) return null;
        return it.object.sym_key;
    }

    /// SpeciesConstructor(O, defaultConstructor): `O.constructor[Symbol.species]`,
    /// falling back to the default when `constructor` or its species slot is
    /// undefined/null; a non-constructor species throws a TypeError.
    pub fn speciesConstructor(self: *Interpreter, o: Value, default_ctor: Value) EvalError!Value {
        const ctor = try self.getProperty(o, "constructor");
        if (ctor == .undefined) return default_ctor;
        if (ctor != .object) return self.throwError("TypeError", "constructor is not an object");
        const skey = self.wellKnownSymbolKey("species") orelse return default_ctor;
        const s = try self.getProperty(ctor, skey);
        if (s == .undefined or s == .null) return default_ctor;
        if (!isConstructorValue(s)) return self.throwError("TypeError", "Symbol.species is not a constructor");
        return s;
    }

    /// ArraySpeciesCreate(originalArray, length): the result array a method like
    /// `map`/`filter`/`slice` produces. The default is a plain Array, but
    /// `originalArray.constructor[Symbol.species]` can redirect it: a null/
    /// undefined species (or the intrinsic Array) gives a plain array, a
    /// non-constructor species throws a TypeError, and any other constructor is
    /// `new`-ed with the length (its abrupt completion propagates).
    pub fn arraySpeciesCreate(self: *Interpreter, original: Value, len: usize) EvalError!Value {
        if (original != .object or !original.object.is_array) return self.newArray();
        const c = try self.getProperty(original, "constructor");
        var ctor: Value = c;
        if (c == .object) {
            const skey = self.wellKnownSymbolKey("species") orelse return self.newArray();
            const s = try self.getProperty(c, skey);
            if (s == .null or s == .undefined) return self.newArray();
            ctor = s;
        } else if (c == .undefined) {
            return self.newArray();
        }
        // The intrinsic Array constructor → a plain array (fast path, matching
        // `new Array(len)` then filling in 0..len).
        if (self.env.get("Array")) |arr| {
            if (ctor == .object and arr == .object and ctor.object == arr.object) return self.newArray();
        }
        if (!isConstructorValue(ctor)) return self.throwError("TypeError", "Array species is not a constructor");
        return self.construct(ctor, &.{.{ .number = @floatFromInt(len) }});
    }

    /// Create a zero-filled `ArrayBuffer` object of `len` bytes.
    pub fn makeArrayBuffer(self: *Interpreter, len: usize) EvalError!*value.Object {
        const o = (try self.newObject()).object;
        const data = try self.arena.alloc(u8, len);
        @memset(data, 0);
        const ab = try self.arena.create(value.ArrayBufferData);
        ab.* = .{ .data = data };
        o.array_buffer = ab;
        if (self.env.get("ArrayBuffer")) |c| {
            if (c == .object) o.proto = try self.protoObject(c.object);
        }
        return o;
    }

    /// Construct a typed array of `kind` from the constructor arguments: a
    /// length, an `(buffer, byteOffset?, length?)` view, or a copy of a typed
    /// array / array-like / iterable.
    pub fn makeTypedArray(self: *Interpreter, kind: value.TAKind, args: []const Value) EvalError!Value {
        const size = kind.byteSize();
        const a0 = if (args.len > 0) args[0] else Value.undefined;
        const o = (try self.newObject()).object;
        // Prototype from the in-flight new.target, else the kind's constructor.
        if (self.new_target == .object) {
            o.proto = try self.protoObject(self.new_target.object);
        } else if (self.env.get(kind.ctorName())) |c| {
            if (c == .object) o.proto = try self.protoObject(c.object);
        }
        const ta = try self.arena.create(value.TypedArrayData);
        o.typed_array = ta;

        if (a0 == .object and a0.object.array_buffer != null) {
            // new TA(buffer, byteOffset?, length?)
            const buffer = a0.object;
            const buflen = buffer.array_buffer.?.data.len;
            const bo_f = if (args.len > 1) try self.toNumberV(args[1]) else 0;
            const byte_offset: usize = @intFromFloat(@trunc(@max(0, bo_f)));
            if (byte_offset % size != 0 or byte_offset > buflen) return self.throwError("RangeError", "invalid typed array offset");
            var length: usize = undefined;
            if (args.len > 2 and args[2] != .undefined) {
                length = @intFromFloat(@trunc(@max(0, try self.toNumberV(args[2]))));
            } else {
                if ((buflen - byte_offset) % size != 0) return self.throwError("RangeError", "byte length not a multiple of element size");
                length = (buflen - byte_offset) / size;
            }
            if (byte_offset + length * size > buflen) return self.throwError("RangeError", "invalid typed array length");
            ta.* = .{ .buffer = buffer, .byte_offset = byte_offset, .length = length, .kind = kind };
            return .{ .object = o };
        }
        if (a0 == .object and a0.object.typed_array != null) {
            // new TA(typedArray): copy elements (converting numeric types).
            const src = a0.object.typed_array.?;
            const length = src.length;
            ta.* = .{ .buffer = try self.makeArrayBuffer(length * size), .byte_offset = 0, .length = length, .kind = kind };
            var i: usize = 0;
            while (i < length) : (i += 1) value.taWrite(ta, i, value.taRead(src, i).number);
            return .{ .object = o };
        }
        if (a0 == .object) {
            // new TA(arrayLike | iterable): collect the values, then copy.
            const list = try self.iterableOrArrayLikeToList(a0);
            ta.* = .{ .buffer = try self.makeArrayBuffer(list.len * size), .byte_offset = 0, .length = list.len, .kind = kind };
            var i: usize = 0;
            while (i < list.len) : (i += 1) value.taWrite(ta, i, try self.toNumberV(list[i]));
            return .{ .object = o };
        }
        // new TA(length)
        const len_f = if (a0 == .undefined) 0 else try self.toNumberV(a0);
        if (len_f < 0 or @trunc(len_f) != len_f) return self.throwError("RangeError", "invalid typed array length");
        const length: usize = @intFromFloat(len_f);
        ta.* = .{ .buffer = try self.makeArrayBuffer(length * size), .byte_offset = 0, .length = length, .kind = kind };
        return .{ .object = o };
    }

    /// Collect an iterable's values (via `Symbol.iterator`) or an array-like's
    /// `0..length` elements into a freshly-allocated slice.
    fn iterableOrArrayLikeToList(self: *Interpreter, v: Value) EvalError![]Value {
        var out: std.ArrayListUnmanaged(Value) = .empty;
        const itk = self.symbolIteratorKey();
        if (v == .object and itk != null and hasProperty(v.object, itk.?)) {
            const it = try self.iteratorOf(v);
            while (true) {
                const r = try self.callMethod(it, "next", &.{});
                if ((try self.getProperty(r, "done")).toBoolean()) break;
                try out.append(self.arena, try self.getProperty(r, "value"));
            }
            return out.items;
        }
        // Array-like: read 0..ToLength(length).
        const len = toLen((try self.toNumberV(try self.getProperty(v, "length"))));
        var i: usize = 0;
        while (i < len) : (i += 1) {
            var kb: [24]u8 = undefined;
            const k = std.fmt.bufPrint(&kb, "{d}", .{i}) catch unreachable;
            try out.append(self.arena, try self.getProperty(v, k));
        }
        return out.items;
    }

    /// Append `v` as the next element of a method's result (an array uses its
    /// dense store; a custom species object gets a `[[Set]]` at `idx`).
    fn arrayResultPush(self: *Interpreter, result: Value, idx: usize, v: Value) EvalError!void {
        if (result == .object and result.object.is_array) {
            try result.object.elements.append(self.arena, v);
        } else {
            var kb: [24]u8 = undefined;
            const k = std.fmt.bufPrint(&kb, "{d}", .{idx}) catch return;
            try self.setMember(result, k, v);
        }
    }

    /// The async iterator for `for await`: `obj[Symbol.asyncIterator]()` if
    /// present, else the sync iterator (whose `{value,done}` results `await`
    /// trivially resolves).
    pub fn asyncIteratorOf(self: *Interpreter, v: Value) EvalError!Value {
        if (self.symbolAsyncIteratorKey()) |ik| {
            if (v == .object and hasProperty(v.object, ik)) {
                const m = try self.getProperty(v, ik);
                // GetMethod: undefined/null → method absent (fall back to sync);
                // present but not callable → TypeError.
                if (m != .undefined and m != .null) {
                    if (m == .object and m.object.isCallableObject())
                        return try self.callValueWithThis(m, &.{}, v);
                    return self.throwError("TypeError", "[Symbol.asyncIterator] is not a function");
                }
            }
        }
        return self.iteratorOf(v);
    }

    /// Wrap an array/string in an iterator object: `__src` + `__i` own properties
    /// plus a shared native `next` that reads/advances them.
    fn makeCursorIterator(self: *Interpreter, src: Value) EvalError!Value {
        const it = try self.arena.create(value.Object);
        it.* = .{};
        try self.setProp(it, "__src", src);
        try self.setProp(it, "__i", .{ .number = 0 });
        try setNative(self.arena, self.root_shape, it, "next", 0, cursorIterNext);
        return .{ .object = it };
    }

    /// `Array.prototype` (the global), for consulting/observing its
    /// `[Symbol.iterator]` slot. Arrays don't carry a `proto` pointer, so this
    /// resolves it through the `Array` global instead.
    fn arrayProtoObj(self: *Interpreter) ?*value.Object {
        const av = self.env.get("Array") orelse return null;
        if (av != .object) return null;
        const p = av.object.getOwn("prototype") orelse return null;
        return if (p == .object) p.object else null;
    }

    /// The current `Array.prototype[Symbol.iterator]` slot: `.intact` (still the
    /// native array-values iterator → fast index cursor is valid), `.deleted`
    /// (no iterator → not iterable), or `.custom` (a user replacement to call).
    const ArrayIter = union(enum) { intact, deleted, custom: Value };
    fn arrayIterState(self: *Interpreter) ArrayIter {
        const ap = self.arrayProtoObj() orelse return .intact;
        const ik = self.symbolIteratorKey() orelse return .intact;
        const slot = ap.getOwn(ik) orelse return .deleted;
        if (slot == .object and slot.object.native == arrayValuesIterFn) return .intact;
        return .{ .custom = slot };
    }

    /// Whether `Array.prototype[Symbol.iterator]` is still the native iterator,
    /// so the array index fast paths are valid.
    fn arrayIterIntact(self: *Interpreter) bool {
        return switch (self.arrayIterState()) {
            .intact => true,
            else => false,
        };
    }

    /// Dispatch `Array.prototype` / `String.prototype` methods (which aren't
    /// stored as own properties). Returns null when `name` isn't a recognized
    /// builtin for `recv`, so the caller falls back to a property lookup + call.
    pub fn builtinMethod(self: *Interpreter, recv: Value, name: []const u8, args: []const Value) EvalError!?Value {
        switch (recv) {
            .object => |o| {
                if (o.gen != null) {
                    const sent: Value = if (args.len > 0) args[0] else .undefined;
                    if (eq(name, "next")) return try vm.genNext(self, o, sent);
                    if (eq(name, "return")) return try vm.genReturn(self, o, sent);
                    if (eq(name, "throw")) return try vm.genThrow(self, o, sent);
                }
                // Universal prototype methods (Function.prototype +
                // Object.prototype), checked before the array/regex/map/set
                // builtins so they reach every object kind. Own properties of
                // the same name shadow them.
                if (o.getOwn(name) == null) {
                    if (o.isCallableObject()) {
                        if (eq(name, "call")) {
                            const t: Value = if (args.len > 0) args[0] else .undefined;
                            return try self.callValueWithThis(recv, if (args.len > 1) args[1..] else &.{}, t);
                        }
                        if (eq(name, "apply")) {
                            const t: Value = if (args.len > 0) args[0] else .undefined;
                            const list = try self.argListFromArrayLike(if (args.len > 1) args[1] else .undefined);
                            return try self.callValueWithThis(recv, list, t);
                        }
                        if (eq(name, "bind")) {
                            return try self.makeBound(o, if (args.len > 0) args[0] else .undefined, if (args.len > 1) args[1..] else &.{});
                        }
                        if (eq(name, "toString")) return try self.functionToString(o);
                    }
                    if (eq(name, "hasOwnProperty")) {
                        const k = if (args.len > 0) try self.keyOf(args[0]) else "undefined";
                        return Value{ .boolean = objectHasOwn(o, k) };
                    }
                    if (eq(name, "propertyIsEnumerable")) {
                        const k = if (args.len > 0) try self.keyOf(args[0]) else "undefined";
                        // Own + enumerable per its attributes; array `length` is
                        // the notable non-enumerable.
                        const enumerable = objectHasOwn(o, k) and o.getAttr(k).enumerable and
                            !(o.is_array and std.mem.eql(u8, k, "length"));
                        return Value{ .boolean = enumerable };
                    }
                    if (eq(name, "isPrototypeOf")) {
                        var cur: ?*value.Object = if (args.len > 0 and args[0] == .object) args[0].object.proto else null;
                        while (cur) |c| {
                            if (c == o) return Value{ .boolean = true };
                            cur = c.proto;
                        }
                        return Value{ .boolean = false };
                    }
                    // Annex-B legacy accessor helpers.
                    if (eq(name, "__defineGetter__") or eq(name, "__defineSetter__")) {
                        const f = arg(args, 1);
                        if (!f.isCallable()) return self.throwError("TypeError", "Object.prototype.__define[GS]etter__: Expecting function");
                        // ToPropertyKey(P): a Symbol key is honored and a thrown
                        // valueOf/toString propagates.
                        const key = try self.keyOf(arg0(args));
                        if (eq(name, "__defineGetter__"))
                            try o.setAccessor(self.arena, key, f, null)
                        else
                            try o.setAccessor(self.arena, key, null, f);
                        try o.setAttr(self.arena, key, .{ .enumerable = true, .configurable = true });
                        return Value.undefined;
                    }
                    if (eq(name, "__lookupGetter__") or eq(name, "__lookupSetter__")) {
                        const key = try self.keyOf(arg0(args));
                        const want_get = eq(name, "__lookupGetter__");
                        var cur: ?*value.Object = o;
                        while (cur) |c| {
                            if (c.getAccessor(key)) |acc| return (if (want_get) acc.get else acc.set) orelse Value.undefined;
                            if (c.getOwn(key) != null) return Value.undefined; // shadowed by a data prop
                            cur = c.proto;
                        }
                        return Value.undefined;
                    }
                    // Error.prototype.toString — before the generic Array `toString`
                    // (join) fallback below would wrongly intercept error objects.
                    if (o.is_error and eq(name, "toString")) return try errorToStringFn(@ptrCast(self), recv, args);
                    if (o.is_symbol and eq(name, "toString")) return try symbolToStringFn(@ptrCast(self), recv, args);
                    if (o.is_symbol and eq(name, "valueOf")) return recv;
                }
                if (o.is_regex) return try self.regexMethod(o, name, args);
                if (o.is_date) return try self.dateMethod(o, name, args);
                if (o.is_map) return try self.mapMethod(o, name, args);
                if (o.is_set) return try self.setMethod(o, name, args);
                // A typed array's own methods take precedence over the Array-like
                // coercion path (slice/indexOf/map/… are shared names).
                if (o.typed_array != null and o.getOwn(name) == null) {
                    if (try typedArrayMethod(self, o, name, args)) |r| return r;
                }
                // A String wrapper object (`new String("…")`): its String.prototype
                // methods take precedence over the generic Array-like coercion for
                // names both share (slice/indexOf/lastIndexOf/includes/concat/at).
                if (o.prim != null and o.prim.? == .string and o.getOwn(name) == null) {
                    if (try self.stringMethod(o.prim.?.string, name, args)) |r| return r;
                }
                if (o.is_array and o.getOwn(name) == null) return try self.arrayMethod(o, name, args);
                // Generic Array.prototype methods on an array-like `this`
                // (`Array.prototype.map.call(obj, …)`).
                if (o.getOwn(name) == null and isArrayGeneric(name)) {
                    if (try self.arrayMethod(o, name, args)) |r| return r;
                }
                // Generic String.prototype methods coerce `this` to string
                // (`String.prototype.split.call(obj)`).
                if (o.getOwn(name) == null and isStringGeneric(name)) {
                    return try self.stringMethod(try self.toStringV(recv), name, args);
                }
                // `Object.prototype.toString` ("[object Tag]") for a plain object.
                // Plain objects don't proto-chain to Object.prototype, so the
                // universal Object.prototype methods are provided here — but a
                // `toString` defined on the prototype chain (e.g. a class method)
                // wins, so defer to it when present.
                if (o.getOwn(name) == null and eq(name, "toString")) {
                    var p = o.proto;
                    const proto_defined = while (p) |pp| : (p = pp.proto) {
                        if (pp.getOwn(name) != null) break true;
                    } else false;
                    if (!proto_defined) return try objectProtoToStringFn(@ptrCast(self), recv, args);
                }
                // A primitive-wrapper object (`new Number/String/Boolean`)
                // delegates unmatched methods to its boxed primitive, so
                // `(new Number(5)).valueOf()`, `.toFixed(2)`, `.charAt(0)`, … work.
                if (o.prim) |p| {
                    if (o.getOwn(name) == null) {
                        if (try self.builtinMethod(p, name, args)) |r| return r;
                    }
                }
            },
            .string => |s| return try self.stringMethod(s, name, args),
            .number => |n| {
                if (try self.numberMethod(n, name, args)) |r| return r;
                if (isStringGeneric(name)) return try self.stringMethod(try recv.toString(self.arena), name, args);
            },
            .boolean => |b| {
                if (try self.booleanMethod(b, name, args)) |r| return r;
                if (isStringGeneric(name)) return try self.stringMethod(try recv.toString(self.arena), name, args);
            },
            else => {},
        }
        return null;
    }

    /// String.prototype methods that coerce `this` to a string (so e.g.
    /// `String.prototype.trim.call(42)` works). Excludes toString/valueOf.
    fn isStringGeneric(name: []const u8) bool {
        const names = [_][]const u8{
            "charAt",      "charCodeAt", "codePointAt", "indexOf",  "lastIndexOf", "includes",
            "startsWith",  "endsWith",   "slice",       "substring", "substr",     "toUpperCase",
            "toLowerCase", "trim",       "trimStart",   "trimEnd",  "repeat",      "concat",
            "split",       "at",         "padStart",    "padEnd",   "replace",     "replaceAll",
            "localeCompare", "normalize", "search",     "match",     "toLocaleUpperCase", "toLocaleLowerCase",
            "matchAll",
        };
        for (names) |n| if (eq(name, n)) return true;
        return false;
    }

    /// Generic read-only Array.prototype methods that work on any array-like
    /// `this` (e.g. `Array.prototype.map.call(arrayLikeObj, fn)`). Mutators stay
    /// real-array-only.
    /// Methods that ArraySpeciesCreate (or otherwise ArrayCreate) a result whose
    /// length comes from the source `length` — so a length above 2^32-1 is a
    /// RangeError. Read-only / in-place methods don't create such a result.
    fn arrayCreatesResult(name: []const u8) bool {
        const names = [_][]const u8{
            "map",        "filter",   "slice",     "concat",     "splice",
            "flat",       "flatMap",  "with",      "toReversed", "toSorted",
            "toSpliced",
        };
        for (names) |n| if (eq(name, n)) return true;
        return false;
    }

    fn isArrayGeneric(name: []const u8) bool {
        const names = [_][]const u8{
            "join",      "indexOf", "lastIndexOf", "includes", "slice", "concat", "map",  "filter",
            "forEach",   "reduce",  "reduceRight", "some",     "every", "find",   "findIndex", "findLast",
            "findLastIndex", "at",  "flat",        "flatMap",  "keys",  "values", "entries",
            "toReversed",    "toSorted", "toSpliced", "with",
            // fill/copyWithin operate purely through [[Get]]/[[Set]] over the
            // receiver, so they work on an array-like `this` (and read its
            // `length` via ToLength, throwing for a Symbol/BigInt length).
            "fill",          "copyWithin",
        };
        // NB: `toString` is intentionally NOT generic here — a plain object's
        // `.toString()` must reach `Object.prototype.toString` (the `[object
        // Tag]` native), not join an array-like into "". Real arrays still join
        // via the `is_array` branch in `builtinMethod`.
        for (names) |n| if (eq(name, n)) return true;
        return false;
    }

    /// Whether array/array-like index `i` is present (own dense non-hole, own
    /// sparse named, or inherited) — the HasProperty the iteration methods use to
    /// skip holes.
    fn arrIndexPresent(self: *Interpreter, o: *value.Object, i: usize) bool {
        // Dense fast path: a real (non-hole) in-range element of a plain array
        // is definitely present — no per-index string allocation. A *hole*
        // falls through, because an index property inherited from the prototype
        // chain can still make it present (HasProperty walks the chain).
        if (o.is_array and o.accessors == null and i < o.elements.items.len and !o.isHole(i))
            return true;
        const ks = std.fmt.allocPrint(self.arena, "{d}", .{i}) catch return false;
        return objectHasOwn(o, ks) or hasProperty(o, ks);
    }

    /// `o[i]` via [[Get]] (so an accessor index runs its getter, and inherited
    /// indices resolve) — used by the iteration methods.
    fn arrIndexGet(self: *Interpreter, o: *value.Object, i: usize) EvalError!Value {
        // Dense fast path mirrors `arrIndexPresent`; a hole goes through [[Get]]
        // so an inherited index (accessor or value) on the prototype resolves.
        if (o.is_array and o.accessors == null and i < o.elements.items.len and !o.isHole(i))
            return o.elements.items[i];
        const ks = try std.fmt.allocPrint(self.arena, "{d}", .{i});
        return self.getProperty(.{ .object = o }, ks);
    }

    /// Spread one concat-spreadable source into `dst`, preserving holes: a real
    /// Array uses its sparse `length`, an array-like reads ToLength(.length).
    /// A pathological 2**53-style length throws (instead of OOM-crashing).
    fn concatSpreadInto(self: *Interpreter, dst: *value.Object, src: *value.Object) EvalError!void {
        const slen: usize = if (src.is_array) @max(src.elements.items.len, src.array_len) else blk: {
            const ln = toLen((try self.toPrimitive(try self.getProperty(.{ .object = src }, "length"), .number)).toNumber());
            if (ln > (1 << 22)) return self.throwError("TypeError", "Invalid array length");
            break :blk ln;
        };
        var j: usize = 0;
        while (j < slen) : (j += 1) {
            const base = dst.elements.items.len;
            if (self.arrIndexPresent(src, j)) {
                try dst.elements.append(self.arena, try self.arrIndexGet(src, j));
            } else {
                try dst.elements.append(self.arena, .undefined);
                try dst.markHole(self.arena, base);
            }
        }
    }

    /// Process one concat operand: spread it when concat-spreadable (per the
    /// `Symbol.isConcatSpreadable` override, else only real Arrays), else append
    /// whole. `ck` is the cached `Symbol.isConcatSpreadable` property key.
    fn concatProcessOne(self: *Interpreter, dst: *value.Object, v: Value, ck: ?[]const u8) EvalError!void {
        if (v != .object) {
            try dst.elements.append(self.arena, v);
            return;
        }
        var spread: bool = v.object.is_array;
        if (ck) |k| {
            const flag = try self.getProperty(v, k);
            if (flag != .undefined) spread = flag.toBoolean();
        }
        if (spread) {
            try self.concatSpreadInto(dst, v.object);
        } else {
            try dst.elements.append(self.arena, v);
        }
    }

    /// ToIntegerOrInfinity-based start index for the forward searches
    /// (indexOf/includes): a negative `fromIndex` counts from the end, `+∞`
    /// (or any value ≥ len) yields `len` (no iterations), NaN/undefined → 0.
    fn fromIndexForward(self: *Interpreter, v: Value, len: usize) EvalError!usize {
        const n = try self.toNumberV(v);
        if (std.math.isNan(n)) return 0;
        const flen: f64 = @floatFromInt(len);
        const fl = @trunc(n);
        if (fl >= flen) return len;
        if (fl < 0) {
            const from_end = flen + fl;
            return if (from_end < 0) 0 else @intFromFloat(from_end);
        }
        return @intFromFloat(fl);
    }

    /// The real array's *sparse* own integer-index keys lying in `[lo, hi)`,
    /// returned in ascending order. These are indices stored as named
    /// properties (past the dense `elements` store, e.g. `a[2**31]=x`), so the
    /// search methods can visit them without walking the whole logical length.
    fn arrSparseIndices(self: *Interpreter, o: *value.Object, lo: usize, hi: usize) EvalError![]usize {
        var list: std.ArrayListUnmanaged(usize) = .empty;
        const keys = try o.ownKeys(self.arena);
        for (keys) |k| {
            if (arrayIndex(k)) |idx| {
                if (idx >= lo and idx < hi) try list.append(self.arena, idx);
            }
        }
        std.mem.sort(usize, list.items, {}, std.sort.asc(usize));
        return list.items;
    }

    /// Whether a real array's `length` is writable — `Set(O, "length", …, true)`
    /// (the final step of pop/push/shift/unshift/splice) throws when it is not.
    fn arrayLenWritable(o: *value.Object) bool {
        return !(o.attrs != null and !o.getAttr("length").writable);
    }

    /// Whether some object on `o`'s *prototype* chain defines an accessor at the
    /// (array-index) key — so an assignment to a hole/out-of-range index routes
    /// to that inherited setter (OrdinarySet) instead of the dense store.
    fn arrayProtoAccessor(o: *value.Object, key: []const u8) bool {
        var cur: ?*value.Object = o.proto;
        while (cur) |c| {
            if (c.getAccessor(key) != null) return true;
            cur = c.proto;
        }
        return false;
    }

    /// `Set(O, ToString(i), v, true)` — the throwing element store used by
    /// push/unshift: fires an inherited index setter and rejects a non-extensible
    /// / non-writable slot (forcing strict so the rejection throws). User setters
    /// keep their own strictness.
    fn arraySetIndexThrowing(self: *Interpreter, o: *value.Object, i: usize, v: Value) EvalError!void {
        const idx = try std.fmt.allocPrint(self.arena, "{d}", .{i});
        const saved = self.strict;
        self.strict = true;
        defer self.strict = saved;
        return self.setMember(.{ .object = o }, idx, v);
    }

    /// `Set(O, "length", newLen, true)` for a grow (push/unshift): a real array
    /// with non-writable `length` throws; otherwise the logical length advances.
    /// An array-like routes through [[Set]].
    fn arraySetLengthThrowing(self: *Interpreter, o: *value.Object, old_len: usize, new_len: usize) EvalError!void {
        if (o.is_array) {
            if (new_len != old_len and !arrayLenWritable(o)) return self.throwError("TypeError", "Cannot assign to read only property 'length'");
            if (new_len > o.elements.items.len and new_len > o.array_len) o.array_len = @intCast(new_len);
            return;
        }
        try self.setMember(.{ .object = o }, "length", .{ .number = @floatFromInt(new_len) });
    }

    /// Whether the array's element at dense index `i` carries an explicit
    /// non-configurable attribute (only possible after `seal`/`freeze` or a
    /// `defineProperty`) — so deleting it (pop/shift) must throw.
    fn arrayElemNonConfigurable(o: *value.Object, i: usize) bool {
        if (o.attrs == null) return false;
        var kb: [24]u8 = undefined;
        const k = std.fmt.bufPrint(&kb, "{d}", .{i}) catch return false;
        return !o.getAttr(k).configurable;
    }

    fn arrayMethod(self: *Interpreter, o: *value.Object, name: []const u8, args: []const Value) EvalError!?Value {
        // Real arrays use the dense element store directly; an array-like `this`
        // (via `.call`) materializes its `length`/indexed properties into a
        // temporary slice so the read-only methods below work unchanged.
        const items: []Value = if (o.is_array) o.elements.items else blk: {
            // ToLength(ToNumber(obj.length)) — `toNumberV` runs valueOf/toString
            // and throws a TypeError for a Symbol/BigInt `length`.
            const lenf = try self.toNumberV(try self.getProperty(.{ .object = o }, "length"));
            // Result-creating methods ArraySpeciesCreate a result of ToLength(len);
            // ArrayCreate rejects a length above 2^32-1 with a RangeError (this
            // precedes the OOM guard, which silently bails for the read-only
            // methods that would otherwise iterate a pathological length). Check
            // the unclamped ToLength, since `toLen` caps at 2^32-1.
            const real_len: f64 = if (std.math.isNan(lenf) or lenf <= 0) 0 else @min(@trunc(lenf), 9007199254740991.0);
            if (real_len > 4294967295 and arrayCreatesResult(name))
                return self.throwError("RangeError", "Invalid array length");
            const len = toLen(lenf);
            if (len > (1 << 22)) return null; // guard against pathological array-like lengths (OOM)
            const buf = try self.arena.alloc(Value, len);
            for (buf, 0..) |*slot, i| {
                slot.* = try self.getProperty(.{ .object = o }, try std.fmt.allocPrint(self.arena, "{d}", .{i}));
            }
            break :blk buf;
        };
        // The optional `thisArg` (2nd argument) bound as `this` inside the
        // callback of map/filter/forEach/some/every/find*/flatMap. reduce/
        // reduceRight take an initial value here instead and ignore it.
        const cb_this = arg(args, 1);
        // The callback-driven methods require a callable first argument, checked
        // up front (so `[].map(undefined)` throws even on an empty array).
        const cb_methods = [_][]const u8{
            "forEach", "map",      "filter",        "some",  "every",
            "find",    "findIndex", "findLast",     "findLastIndex",
            "reduce",  "reduceRight", "flatMap",
        };
        for (cb_methods) |m| {
            if (eq(name, m) and !arg0(args).isCallable())
                return self.throwError("TypeError", "Array.prototype callback is not a function");
        }
        // The logical length for index iteration: a real array's includes any
        // sparse tail (`array_len`); an array-like uses its materialized slice.
        const ilen: usize = if (o.is_array) @max(o.elements.items.len, o.array_len) else items.len;
        if (eq(name, "push")) {
            const len = ilen;
            // Set(O, ToString(len+k), E, true) for each argument (fires an
            // inherited index setter; a non-extensible array throws), then
            // Set(O, "length", newLen, true).
            var k: usize = 0;
            while (k < args.len) : (k += 1) {
                try self.arraySetIndexThrowing(o, len + k, args[k]);
            }
            const new_len = len + args.len;
            try self.arraySetLengthThrowing(o, len, new_len);
            return Value{ .number = @floatFromInt(new_len) };
        }
        if (eq(name, "pop")) {
            if (ilen == 0) {
                if (!o.is_array) try self.setMember(.{ .object = o }, "length", .{ .number = 0 });
                return Value.undefined;
            }
            const last = ilen - 1;
            const idx = try std.fmt.allocPrint(self.arena, "{d}", .{last});
            // [[Get]] the last element first (fires an inherited accessor when the
            // slot is a hole — that is how the spec's order is observed).
            const element = try self.getProperty(.{ .object = o }, idx);
            if (o.is_array) {
                if (arrayElemNonConfigurable(o, last)) return self.throwError("TypeError", "Cannot delete a non-configurable array element");
                if (!arrayLenWritable(o)) return self.throwError("TypeError", "Cannot assign to read only property 'length'");
                if (last < o.elements.items.len) o.elements.shrinkRetainingCapacity(last);
                o.array_len = @intCast(last);
                return element;
            }
            if (!try self.deleteOwn(o, idx)) return self.throwError("TypeError", "Cannot delete property");
            try self.setMember(.{ .object = o }, "length", .{ .number = @floatFromInt(last) });
            return element;
        }
        if (eq(name, "shift")) {
            if (ilen == 0) {
                if (!o.is_array) try self.setMember(.{ .object = o }, "length", .{ .number = 0 });
                return Value.undefined;
            }
            const first = try self.getProperty(.{ .object = o }, "0"); // fires accessor on a hole
            if (o.is_array) {
                if (arrayElemNonConfigurable(o, 0)) return self.throwError("TypeError", "Cannot delete a non-configurable array element");
                if (!arrayLenWritable(o)) return self.throwError("TypeError", "Cannot assign to read only property 'length'");
                if (o.elements.items.len > 0) _ = o.elements.orderedRemove(0);
                o.array_len = if (ilen > 0) @intCast(ilen - 1) else 0;
                return first;
            }
            // Array-like: move each element down, delete the tail, set length.
            var k: usize = 1;
            while (k < ilen) : (k += 1) {
                const from = try std.fmt.allocPrint(self.arena, "{d}", .{k});
                const to = try std.fmt.allocPrint(self.arena, "{d}", .{k - 1});
                if (self.arrIndexPresent(o, k)) try self.setMember(.{ .object = o }, to, try self.getProperty(.{ .object = o }, from)) else _ = try self.deleteOwn(o, to);
            }
            _ = try self.deleteOwn(o, try std.fmt.allocPrint(self.arena, "{d}", .{ilen - 1}));
            try self.setMember(.{ .object = o }, "length", .{ .number = @floatFromInt(ilen - 1) });
            return first;
        }
        if (eq(name, "unshift")) {
            const len = ilen;
            if (args.len > 0) {
                // Shift each existing element up by argCount (high to low, via
                // [[Get]]/[[Set]]/[[Delete]] so holes move and inherited accessors
                // fire), then place the new arguments at the front, then Set
                // length — the spec protocol, also fed by a real array's dense
                // store through setMember/getProperty.
                var k: usize = len;
                while (k > 0) : (k -= 1) {
                    const to = k - 1 + args.len;
                    if (self.arrIndexPresent(o, k - 1))
                        try self.arraySetIndexThrowing(o, to, try self.arrIndexGet(o, k - 1))
                    else
                        _ = try self.deleteOwn(o, try std.fmt.allocPrint(self.arena, "{d}", .{to}));
                }
                for (args, 0..) |a, j| try self.arraySetIndexThrowing(o, j, a);
                try self.arraySetLengthThrowing(o, len, len + args.len);
            }
            return Value{ .number = @floatFromInt(len + args.len) };
        }
        if (eq(name, "indexOf")) {
            const target = arg0(args);
            if (ilen == 0) return Value{ .number = -1 };
            // `fromIndex` (2nd arg): a clamped start index. Beyond it (e.g.
            // +Infinity on a 2**32-length array) means no iterations — which is
            // also what keeps a huge sparse array from being walked element by
            // element.
            const k = if (args.len > 1) try self.fromIndexForward(args[1], ilen) else 0;
            // Dense scan: indexOf skips holes (HasProperty check).
            const dense_hi = @min(o.elements.items.len, ilen);
            var i = k;
            while (i < dense_hi) : (i += 1) {
                if (self.arrIndexPresent(o, i) and value.strictEquals(try self.arrIndexGet(o, i), target))
                    return Value{ .number = @floatFromInt(i) };
            }
            // Sparse scan: named integer-index properties in ascending order, so
            // the first (lowest) match wins — without touching the hole tail.
            const sparse = try self.arrSparseIndices(o, @max(k, dense_hi), ilen);
            for (sparse) |idx| {
                if (value.strictEquals(try self.arrIndexGet(o, idx), target))
                    return Value{ .number = @floatFromInt(idx) };
            }
            return Value{ .number = -1 };
        }
        if (eq(name, "includes")) {
            const target = arg0(args);
            if (ilen == 0) return Value{ .boolean = false };
            const k = if (args.len > 1) try self.fromIndexForward(args[1], ilen) else 0;
            // includes treats holes as `undefined` and uses SameValueZero (so
            // NaN matches NaN). Dense scan visits every in-range index.
            const dense_hi = @min(o.elements.items.len, ilen);
            var i = k;
            while (i < dense_hi) : (i += 1) {
                if (value.sameValueZero(try self.arrIndexGet(o, i), target)) return Value{ .boolean = true };
            }
            // Tail [max(k,dense_hi), ilen): named sparse indices checked
            // directly; the remaining indices are pure holes reading as
            // undefined, so a `target` of undefined matches if any such hole
            // exists (rather than iterating billions of them).
            const tail_lo = @max(k, dense_hi);
            const sparse = try self.arrSparseIndices(o, tail_lo, ilen);
            for (sparse) |idx| {
                if (value.sameValueZero(try self.arrIndexGet(o, idx), target)) return Value{ .boolean = true };
            }
            if (target == .undefined and (ilen - tail_lo) > sparse.len) return Value{ .boolean = true };
            return Value{ .boolean = false };
        }
        if (eq(name, "join")) {
            const sep = if (args.len > 0 and args[0] != .undefined) try args[0].toString(self.arena) else ",";
            var buf: std.ArrayListUnmanaged(u8) = .empty;
            // Walk the logical length: a hole reads as `undefined` (via [[Get]])
            // and — like `undefined`/`null` — renders as the empty string.
            var i: usize = 0;
            while (i < ilen) : (i += 1) {
                if (i != 0) try buf.appendSlice(self.arena, sep);
                switch (try self.arrIndexGet(o, i)) {
                    .undefined, .null => {},
                    else => |el| try buf.appendSlice(self.arena, try el.toString(self.arena)),
                }
            }
            return Value{ .string = try buf.toOwnedSlice(self.arena) };
        }
        if (eq(name, "slice")) {
            const start = try relIndex(self, arg0(args), ilen, 0);
            const end = try relIndex(self, arg(args, 1), ilen, @floatFromInt(ilen));
            const count = if (end > start) end - start else 0;
            const result = try self.arraySpeciesCreate(.{ .object = o }, count);
            const ra = result.object.is_array;
            var i = start;
            var k: usize = 0; // result index, for hole preservation
            while (i < end) : (i += 1) {
                if (self.arrIndexPresent(o, i)) {
                    if (ra) try result.object.elements.append(self.arena, try self.arrIndexGet(o, i)) else try self.arrayResultPush(result, k, try self.arrIndexGet(o, i));
                } else if (ra) { // slice preserves holes (only on a real array result)
                    try result.object.elements.append(self.arena, .undefined);
                    try result.object.markHole(self.arena, k);
                }
                k += 1;
            }
            return result;
        }
        if (eq(name, "concat")) {
            const result = try self.arraySpeciesCreate(.{ .object = o }, 0);
            const ck = self.wellKnownSymbolKey("isConcatSpreadable");
            try self.concatProcessOne(result.object, .{ .object = o }, ck);
            for (args) |a| try self.concatProcessOne(result.object, a, ck);
            return result;
        }
        if (eq(name, "reverse")) {
            std.mem.reverse(Value, o.elements.items);
            return Value{ .object = o };
        }
        // ES2023 "change array by copy": return a new array, leaving `this`
        // untouched. They read `items` so they also work generically on an
        // array-like `this` (via `.call`).
        if (eq(name, "toReversed")) {
            const result = try self.newArray();
            var i = items.len;
            while (i > 0) : (i -= 1) try result.object.elements.append(self.arena, items[i - 1]);
            return result;
        }
        if (eq(name, "toSorted")) {
            const cmp = arg0(args);
            const result = try self.newArray();
            try result.object.elements.appendSlice(self.arena, items);
            const ri = result.object.elements.items;
            var i: usize = 1;
            while (i < ri.len) : (i += 1) {
                const key = ri[i];
                var j = i;
                while (j > 0 and (try self.sortCompare(ri[j - 1], key, cmp)) > 0) : (j -= 1) ri[j] = ri[j - 1];
                ri[j] = key;
            }
            return result;
        }
        if (eq(name, "with")) {
            const len = items.len;
            const raw = arg0(args).toNumber();
            const rel: f64 = if (std.math.isNan(raw)) 0 else @trunc(raw);
            const actual: f64 = if (rel < 0) @as(f64, @floatFromInt(len)) + rel else rel;
            if (actual < 0 or actual >= @as(f64, @floatFromInt(len))) return self.throwError("RangeError", "Invalid index");
            const result = try self.newArray();
            try result.object.elements.appendSlice(self.arena, items);
            result.object.elements.items[@intFromFloat(actual)] = arg(args, 1);
            return result;
        }
        if (eq(name, "toSpliced")) {
            const len = items.len;
            const start = try relIndex(self, arg0(args), len, 0);
            const del: usize = if (args.len <= 1) len - start else blk: {
                const d = arg(args, 1).toNumber();
                if (std.math.isNan(d) or d <= 0) break :blk 0;
                const du: usize = if (d > @as(f64, @floatFromInt(len))) len else @intFromFloat(@trunc(d));
                break :blk if (start + du > len) len - start else du;
            };
            const result = try self.newArray();
            const ra = result.object;
            var i: usize = 0;
            while (i < start) : (i += 1) try ra.elements.append(self.arena, items[i]);
            if (args.len > 2) for (args[2..]) |v| try ra.elements.append(self.arena, v);
            i = start + del;
            while (i < len) : (i += 1) try ra.elements.append(self.arena, items[i]);
            return result;
        }
        if (eq(name, "map")) {
            const cb = arg0(args);
            const result = try self.arraySpeciesCreate(.{ .object = o }, ilen);
            const ra = result.object.is_array;
            var i: usize = 0;
            while (i < ilen) : (i += 1) {
                if (!self.arrIndexPresent(o, i)) {
                    if (ra) {
                        try result.object.elements.append(self.arena, .undefined);
                        try result.object.markHole(self.arena, i); // map preserves holes
                    }
                    continue;
                }
                const el = try self.arrIndexGet(o, i);
                const r = try self.callValueWithThis(cb, &.{ el, .{ .number = @floatFromInt(i) }, .{ .object = o } }, cb_this);
                if (ra) try result.object.elements.append(self.arena, r) else try self.arrayResultPush(result, i, r);
            }
            return result;
        }
        if (eq(name, "filter")) {
            const cb = arg0(args);
            const result = try self.arraySpeciesCreate(.{ .object = o }, 0);
            const ra = result.object.is_array;
            var i: usize = 0;
            var ridx: usize = 0;
            while (i < ilen) : (i += 1) {
                if (!self.arrIndexPresent(o, i)) continue; // skip holes
                const el = try self.arrIndexGet(o, i);
                if ((try self.callValueWithThis(cb, &.{ el, .{ .number = @floatFromInt(i) }, .{ .object = o } }, cb_this)).toBoolean()) {
                    if (ra) try result.object.elements.append(self.arena, el) else try self.arrayResultPush(result, ridx, el);
                    ridx += 1;
                }
            }
            return result;
        }
        if (eq(name, "forEach")) {
            const cb = arg0(args);
            var i: usize = 0;
            while (i < ilen) : (i += 1) {
                if (!self.arrIndexPresent(o, i)) continue; // skip holes
                const el = try self.arrIndexGet(o, i);
                _ = try self.callValueWithThis(cb, &.{ el, .{ .number = @floatFromInt(i) }, .{ .object = o } }, cb_this);
            }
            return Value.undefined;
        }
        if (eq(name, "some")) {
            const cb = arg0(args);
            var i: usize = 0;
            while (i < ilen) : (i += 1) {
                if (!self.arrIndexPresent(o, i)) continue;
                const el = try self.arrIndexGet(o, i);
                if ((try self.callValueWithThis(cb, &.{ el, .{ .number = @floatFromInt(i) }, .{ .object = o } }, cb_this)).toBoolean())
                    return Value{ .boolean = true };
            }
            return Value{ .boolean = false };
        }
        if (eq(name, "every")) {
            const cb = arg0(args);
            var i: usize = 0;
            while (i < ilen) : (i += 1) {
                if (!self.arrIndexPresent(o, i)) continue;
                const el = try self.arrIndexGet(o, i);
                if (!(try self.callValueWithThis(cb, &.{ el, .{ .number = @floatFromInt(i) }, .{ .object = o } }, cb_this)).toBoolean())
                    return Value{ .boolean = false };
            }
            return Value{ .boolean = true };
        }
        if (eq(name, "find")) {
            const cb = arg0(args);
            var i: usize = 0;
            while (i < ilen) : (i += 1) {
                // `find` visits holes (value undefined), unlike forEach/map.
                const el = try self.arrIndexGet(o, i);
                if ((try self.callValueWithThis(cb, &.{ el, .{ .number = @floatFromInt(i) }, .{ .object = o } }, cb_this)).toBoolean()) return el;
            }
            return Value.undefined;
        }
        if (eq(name, "reduce")) {
            const cb = arg0(args);
            var acc: Value = undefined;
            var i: usize = 0;
            if (args.len >= 2) {
                acc = args[1];
            } else {
                // Seed with the first *present* element; empty (all-hole) → throw.
                while (i < ilen and !self.arrIndexPresent(o, i)) i += 1;
                if (i >= ilen) return self.throwError("TypeError", "Reduce of empty array with no initial value");
                acc = try self.arrIndexGet(o, i);
                i += 1;
            }
            while (i < ilen) : (i += 1) {
                if (!self.arrIndexPresent(o, i)) continue; // skip holes
                const el = try self.arrIndexGet(o, i);
                acc = try self.callValue(cb, &.{ acc, el, .{ .number = @floatFromInt(i) }, .{ .object = o } });
            }
            return acc;
        }
        if (eq(name, "reduceRight")) {
            const cb = arg0(args);
            var acc: Value = undefined;
            var i: usize = ilen;
            if (args.len >= 2) {
                acc = args[1];
            } else {
                while (i > 0 and !self.arrIndexPresent(o, i - 1)) i -= 1;
                if (i == 0) return self.throwError("TypeError", "Reduce of empty array with no initial value");
                i -= 1;
                acc = try self.arrIndexGet(o, i);
            }
            while (i > 0) {
                i -= 1;
                if (!self.arrIndexPresent(o, i)) continue;
                const el = try self.arrIndexGet(o, i);
                acc = try self.callValue(cb, &.{ acc, el, .{ .number = @floatFromInt(i) }, .{ .object = o } });
            }
            return acc;
        }
        if (eq(name, "at")) {
            const fl = @trunc(arg0(args).toNumber());
            const idx: i64 = if (fl < 0) @as(i64, @intCast(ilen)) + @as(i64, @intFromFloat(fl)) else @intFromFloat(fl);
            if (idx < 0 or idx >= ilen) return Value.undefined;
            return try self.arrIndexGet(o, @intCast(idx)); // a hole reads as undefined
        }
        if (eq(name, "lastIndexOf")) {
            const target = arg0(args);
            if (ilen == 0) return Value{ .number = -1 };
            // `fromIndex` (2nd arg): the highest index to search, default len-1.
            // Negative counts from the end; below 0 means no search.
            var start: usize = ilen - 1;
            if (args.len > 1) {
                const n = args[1].toNumber();
                const fl = if (std.math.isNan(n)) 0 else @trunc(n);
                if (fl < 0) {
                    const s = @as(f64, @floatFromInt(ilen)) + fl;
                    if (s < 0) return Value{ .number = -1 };
                    start = @intFromFloat(s);
                } else {
                    const flen_1: f64 = @floatFromInt(ilen - 1);
                    start = if (fl > flen_1) ilen - 1 else @intFromFloat(fl);
                }
            }
            const dense_hi = @min(o.elements.items.len, ilen);
            // Sparse indices (above the dense store) are the highest, so search
            // them first, descending — the first match is the answer.
            const sparse = try self.arrSparseIndices(o, dense_hi, start + 1);
            var si = sparse.len;
            while (si > 0) {
                si -= 1;
                if (value.strictEquals(try self.arrIndexGet(o, sparse[si]), target))
                    return Value{ .number = @floatFromInt(sparse[si]) };
            }
            // Dense scan descending; lastIndexOf skips holes.
            var i = @min(start + 1, dense_hi);
            while (i > 0) {
                i -= 1;
                if (self.arrIndexPresent(o, i) and value.strictEquals(try self.arrIndexGet(o, i), target))
                    return Value{ .number = @floatFromInt(i) };
            }
            return Value{ .number = -1 };
        }
        if (eq(name, "findIndex")) {
            const cb = arg0(args);
            var i: usize = 0;
            while (i < ilen) : (i += 1) { // findIndex visits holes (value undefined)
                const el = try self.arrIndexGet(o, i);
                if ((try self.callValueWithThis(cb, &.{ el, .{ .number = @floatFromInt(i) }, .{ .object = o } }, cb_this)).toBoolean())
                    return Value{ .number = @floatFromInt(i) };
            }
            return Value{ .number = -1 };
        }
        if (eq(name, "fill")) {
            const v = arg0(args);
            const start = try relIndex(self, arg(args, 1), ilen, 0);
            const end = try relIndex(self, arg(args, 2), ilen, @floatFromInt(ilen));
            // fill writes through [[Set]] over the full length, so it also fills
            // holes (and creates indexed properties on an array-like `this`).
            var i = start;
            while (i < end) : (i += 1) {
                try self.setMember(.{ .object = o }, try std.fmt.allocPrint(self.arena, "{d}", .{i}), v);
            }
            return Value{ .object = o };
        }
        if (eq(name, "flat")) {
            const depth: f64 = if (args.len > 0 and args[0] != .undefined) arg0(args).toNumber() else 1;
            const result = try self.newArray();
            try self.flattenInto(result.object, o, depth);
            return result;
        }
        if (eq(name, "sort")) {
            const cmp = arg0(args);
            if (cmp != .undefined and !cmp.isCallable())
                return self.throwError("TypeError", "Array.prototype.sort comparator is not a function");
            // Gather the *present* elements (holes excluded), sort them — with
            // `undefined` ordered last and never passed to the comparator — then
            // write them back, leaving holes at the tail.
            var present: std.ArrayListUnmanaged(Value) = .empty;
            var i: usize = 0;
            while (i < ilen) : (i += 1) {
                if (self.arrIndexPresent(o, i)) try present.append(self.arena, try self.arrIndexGet(o, i));
            }
            const ps = present.items;
            var a_i: usize = 1;
            while (a_i < ps.len) : (a_i += 1) { // insertion sort (comparator may throw)
                const key = ps[a_i];
                var j = a_i;
                while (j > 0 and (try self.sortCompareSpec(ps[j - 1], key, cmp)) > 0) : (j -= 1) ps[j] = ps[j - 1];
                ps[j] = key;
            }
            if (o.is_array) {
                // Drop any sparse named-index props (their values are in `ps`).
                for (try o.ownKeys(self.arena)) |k| if (value.canonicalIndex(k) != null) {
                    _ = try self.deleteOwn(o, k);
                };
                o.elements.clearRetainingCapacity();
                try o.elements.appendSlice(self.arena, ps);
                if (o.holes) |h| h.clearRetainingCapacity();
                o.array_len = ilen; // indices past the sorted run read as holes
            } else {
                var k: usize = 0;
                while (k < ilen) : (k += 1) {
                    const ks = try std.fmt.allocPrint(self.arena, "{d}", .{k});
                    if (k < ps.len) try self.setMember(.{ .object = o }, ks, ps[k]) else _ = try self.deleteOwn(o, ks);
                }
            }
            return Value{ .object = o };
        }
        if (eq(name, "splice")) {
            const len = items.len;
            const start = try relIndex(self, arg0(args), len, 0);
            const del: usize = if (args.len <= 1) len - start else blk: {
                const d = arg(args, 1).toNumber();
                if (std.math.isNan(d) or d <= 0) break :blk 0;
                const du: usize = if (d > @as(f64, @floatFromInt(len))) len else @intFromFloat(@trunc(d));
                break :blk if (start + du > len) len - start else du;
            };
            const removed = try self.arraySpeciesCreate(.{ .object = o }, del);
            const rra = removed.object.is_array;
            var i: usize = 0;
            while (i < del) : (i += 1) {
                if (rra) try removed.object.elements.append(self.arena, items[start + i]) else try self.arrayResultPush(removed, i, items[start + i]);
            }
            i = 0;
            while (i < del) : (i += 1) _ = o.elements.orderedRemove(start);
            const inserts: []const Value = if (args.len > 2) args[2..] else &.{};
            var j: usize = inserts.len;
            while (j > 0) : (j -= 1) try o.elements.insert(self.arena, start, inserts[j - 1]);
            return removed;
        }
        if (eq(name, "copyWithin")) {
            const len = ilen;
            const target = try relIndex(self, arg0(args), len, 0);
            const start = try relIndex(self, arg(args, 1), len, 0);
            const end = try relIndex(self, arg(args, 2), len, @floatFromInt(len));
            var count = @min(if (end > start) end - start else 0, len - target);
            // Copy through [[Get]]/[[Set]] over the full length; a hole at the
            // source deletes the target (so holes move correctly). Walk backward
            // when the ranges overlap with target after source.
            var from = start;
            var to = target;
            var backward = false;
            if (from < to and to < from + count) {
                backward = true;
                from += count - 1;
                to += count - 1;
            }
            while (count > 0) : (count -= 1) {
                const tk = try std.fmt.allocPrint(self.arena, "{d}", .{to});
                if (self.arrIndexPresent(o, from))
                    try self.setMember(.{ .object = o }, tk, try self.arrIndexGet(o, from))
                else
                    _ = try self.deleteOwn(o, tk);
                if (backward) {
                    from -= 1;
                    to -= 1;
                } else {
                    from += 1;
                    to += 1;
                }
            }
            return Value{ .object = o };
        }
        if (eq(name, "flatMap")) {
            const cb = arg0(args);
            const result = try self.newArray();
            var i: usize = 0;
            while (i < ilen) : (i += 1) {
                if (!self.arrIndexPresent(o, i)) continue; // skip holes
                const el = try self.arrIndexGet(o, i);
                const m = try self.callValueWithThis(cb, &.{ el, .{ .number = @floatFromInt(i) }, .{ .object = o } }, cb_this);
                if (m == .object and m.object.is_array) {
                    for (m.object.elements.items) |e2| try result.object.elements.append(self.arena, e2);
                } else try result.object.elements.append(self.arena, m);
            }
            return result;
        }
        if (eq(name, "findLast") or eq(name, "findLastIndex")) {
            const want_index = eq(name, "findLastIndex");
            const cb = arg0(args);
            var i: usize = ilen;
            while (i > 0) {
                i -= 1;
                const el = try self.arrIndexGet(o, i); // visits holes (undefined)
                if ((try self.callValueWithThis(cb, &.{ el, .{ .number = @floatFromInt(i) }, .{ .object = o } }, cb_this)).toBoolean())
                    return if (want_index) Value{ .number = @floatFromInt(i) } else el;
            }
            return if (want_index) Value{ .number = -1 } else .undefined;
        }
        if (eq(name, "values")) return try self.iteratorOf(.{ .object = o });
        if (eq(name, "keys")) {
            // The Array Iterator yields every index 0..length, holes included.
            const arr = try self.newArray();
            for (0..ilen) |i| try arr.object.elements.append(self.arena, .{ .number = @floatFromInt(i) });
            return try self.iteratorOf(arr);
        }
        if (eq(name, "entries")) {
            const arr = try self.newArray();
            var i: usize = 0;
            while (i < ilen) : (i += 1) {
                const pair = try self.newArray();
                try pair.object.elements.append(self.arena, .{ .number = @floatFromInt(i) });
                try pair.object.elements.append(self.arena, try self.arrIndexGet(o, i)); // hole -> undefined
                try arr.object.elements.append(self.arena, pair);
            }
            return try self.iteratorOf(arr);
        }
        if (eq(name, "toString")) {
            // Array.prototype.toString delegates to join with ",".
            return try self.arrayMethod(o, "join", &.{});
        }
        return null;
    }

    /// FlattenIntoArray: walk `src`'s logical length, *skipping holes*
    /// (HasProperty) and recursing into nested arrays up to `depth`. The result
    /// is packed — flat does not preserve holes.
    fn flattenInto(self: *Interpreter, dst: *value.Object, src: *value.Object, depth: f64) EvalError!void {
        const len: usize = if (src.is_array) @max(src.elements.items.len, src.array_len) else blk: {
            const lv = try self.toPrimitive(try self.getProperty(.{ .object = src }, "length"), .number);
            break :blk toLen(lv.toNumber());
        };
        var i: usize = 0;
        while (i < len) : (i += 1) {
            if (!self.arrIndexPresent(src, i)) continue; // flat skips holes
            const el = try self.arrIndexGet(src, i);
            if (depth > 0 and el == .object and el.object.is_array) {
                try self.flattenInto(dst, el.object, depth - 1);
            } else {
                try dst.elements.append(self.arena, el);
            }
        }
    }

    /// SortCompare: `undefined` always sorts after everything else and is never
    /// handed to the comparator; otherwise defer to `sortCompare`.
    fn sortCompareSpec(self: *Interpreter, a: Value, b: Value, cmp: Value) EvalError!f64 {
        const a_u = a == .undefined;
        const b_u = b == .undefined;
        if (a_u or b_u) return if (a_u and b_u) 0 else if (a_u) 1 else -1;
        return self.sortCompare(a, b, cmp);
    }

    /// Comparator for Array.prototype.sort: >0 if `a` sorts after `b`.
    fn sortCompare(self: *Interpreter, a: Value, b: Value, cmp: Value) EvalError!f64 {
        if (cmp == .object and cmp.object.isCallableObject()) {
            const r = try self.callValue(cmp, &.{ a, b });
            const n = r.toNumber();
            return if (std.math.isNan(n)) 0 else n;
        }
        const as = try a.toString(self.arena);
        const bs = try b.toString(self.arena);
        return switch (std.mem.order(u8, as, bs)) {
            .lt => -1,
            .eq => 0,
            .gt => 1,
        };
    }

    fn numberMethod(self: *Interpreter, n: f64, name: []const u8, args: []const Value) EvalError!?Value {
        if (eq(name, "valueOf")) return Value{ .number = n };
        // toLocaleString ignores any radix argument (no Intl data → default form).
        if (eq(name, "toLocaleString")) return Value{ .string = try value.numberToString(self.arena, n) };
        if (eq(name, "toString")) {
            var radix: usize = 10;
            if (args.len > 0 and args[0] != .undefined) {
                const r = @trunc(try self.toNumberV(args[0]));
                if (std.math.isNan(r) or r < 2 or r > 36)
                    return self.throwError("RangeError", "toString() radix must be an integer between 2 and 36");
                radix = @intFromFloat(r);
            }
            if (radix == 10) return Value{ .string = try value.numberToString(self.arena, n) };
            if (std.math.isNan(n)) return Value{ .string = "NaN" };
            if (std.math.isInf(n)) return Value{ .string = if (n < 0) "-Infinity" else "Infinity" };
            return Value{ .string = try numberToRadix(self.arena, n, radix) };
        }
        if (eq(name, "toFixed")) {
            // ToIntegerOrInfinity(fractionDigits) runs first (can throw TypeError
            // on a Symbol/BigInt or a throwing valueOf) — BEFORE the range check
            // and the not-finite return, per spec step order.
            const f = try self.toNumberV(arg0(args));
            const fi = if (std.math.isNan(f)) @as(f64, 0) else @trunc(f);
            if (fi < 0 or fi > 100)
                return self.throwError("RangeError", "toFixed() digits must be between 0 and 100");
            if (std.math.isNan(n) or std.math.isInf(n))
                return Value{ .string = try value.numberToString(self.arena, n) };
            return Value{ .string = try toFixed(self.arena, n, @intFromFloat(fi)) };
        }
        if (eq(name, "toExponential")) {
            const has_arg = args.len > 0 and args[0] != .undefined;
            // Coerce the argument first (observable + can throw), then handle a
            // non-finite receiver.
            const f = try self.toNumberV(arg0(args));
            if (std.math.isNan(n)) return Value{ .string = "NaN" };
            if (std.math.isInf(n)) return Value{ .string = if (n < 0) "-Infinity" else "Infinity" };
            var frac: ?usize = null;
            if (has_arg) {
                const fi = if (std.math.isNan(f)) @as(f64, 0) else @trunc(f);
                if (fi < 0 or fi > 100) return self.throwError("RangeError", "toExponential() argument must be between 0 and 100");
                frac = @intFromFloat(fi);
            }
            return Value{ .string = try toExponentialStr(self.arena, n, frac) };
        }
        if (eq(name, "toPrecision")) {
            // `precision === undefined` returns ToString(x) without coercion;
            // otherwise ToIntegerOrInfinity(precision) runs before the not-finite
            // return.
            if (args.len == 0 or args[0] == .undefined) return Value{ .string = try value.numberToString(self.arena, n) };
            const p = try self.toNumberV(args[0]);
            if (std.math.isNan(n)) return Value{ .string = "NaN" };
            if (std.math.isInf(n)) return Value{ .string = if (n < 0) "-Infinity" else "Infinity" };
            const pf = if (std.math.isNan(p)) @as(f64, 0) else @trunc(p);
            if (pf < 1 or pf > 100) return self.throwError("RangeError", "toPrecision() argument must be between 1 and 100");
            return Value{ .string = try toPrecisionStr(self.arena, n, @intFromFloat(pf)) };
        }
        return null;
    }

    fn booleanMethod(self: *Interpreter, b: bool, name: []const u8, args: []const Value) EvalError!?Value {
        _ = self;
        _ = args;
        if (eq(name, "valueOf")) return Value{ .boolean = b };
        if (eq(name, "toString")) return Value{ .string = if (b) "true" else "false" };
        return null;
    }

    /// The well-known Symbol whose method backs a String regex-protocol method
    /// (`replaceAll` shares `Symbol.replace`), or null for a plain method.
    fn stringProtocolSymbol(_: *Interpreter, name: []const u8) ?[]const u8 {
        if (eq(name, "split")) return "split";
        if (eq(name, "match")) return "match";
        if (eq(name, "matchAll")) return "matchAll";
        if (eq(name, "search")) return "search";
        if (eq(name, "replace") or eq(name, "replaceAll")) return "replace";
        return null;
    }

    /// IsRegExp(v): true if `v` is an object whose `[Symbol.match]` is truthy
    /// (or, when that property is absent, has a [[RegExpMatcher]] — `is_regex`).
    fn isRegExp(self: *Interpreter, v: Value) EvalError!bool {
        if (v != .object) return false;
        if (self.wellKnownSymbolKey("match")) |mkey| {
            const m = try self.getProperty(v, mkey);
            if (m != .undefined) return m.toBoolean();
        }
        return v.object.is_regex;
    }

    /// ToIntegerOrInfinity(v) clamped into `[0, len]` — the position argument of
    /// `includes`/`startsWith`/`endsWith` (a Symbol/BigInt throws via toNumberV).
    fn clampPos(self: *Interpreter, v: Value, len: usize) EvalError!usize {
        const n = try self.toNumberV(v);
        if (std.math.isNan(n) or n <= 0) return 0;
        const flen: f64 = @floatFromInt(len);
        if (n >= flen) return len;
        return @intFromFloat(@trunc(n));
    }

    fn stringMethod(self: *Interpreter, s: []const u8, name: []const u8, args: []const Value) EvalError!?Value {
        if (eq(name, "valueOf") or eq(name, "toString")) return Value{ .string = s };
        // Well-known Symbol method protocol: `split`/`match`/`matchAll`/`search`/
        // `replace`/`replaceAll` first check their first argument for the matching
        // `Symbol.*` method and, if it is callable, delegate to it (with `this` =
        // that argument and the string as the first parameter). RegExp instances
        // keep the engine's native regex path (they carry no such own symbol).
        if (self.stringProtocolSymbol(name)) |sym| {
            const sep = arg0(args);
            if (sep == .object and !sep.object.is_regex and !sep.object.is_symbol) {
                if (self.wellKnownSymbolKey(sym)) |key| {
                    const method = try self.getProperty(sep, key);
                    if (method == .object and method.object.isCallableObject()) {
                        var argv: std.ArrayListUnmanaged(Value) = .empty;
                        try argv.append(self.arena, .{ .string = s });
                        if (args.len > 1) try argv.appendSlice(self.arena, args[1..]);
                        return try self.callValueWithThis(method, argv.items, sep);
                    }
                }
            }
        }
        if (eq(name, "charAt")) {
            const i = try relIndex(self, arg0(args), s.len, 0);
            return if (i < s.len) Value{ .string = try self.arena.dupe(u8, s[i .. i + 1]) } else Value{ .string = "" };
        }
        if (eq(name, "charCodeAt")) {
            const i = toLen(try self.toNumberV(arg0(args)));
            return if (i < s.len) Value{ .number = @floatFromInt(s[i]) } else Value{ .number = std.math.nan(f64) };
        }
        if (eq(name, "indexOf")) {
            // ToString(searchString) precedes ToInteger(position), and each runs
            // the argument's valueOf/toString (so an abrupt completion in either
            // propagates in spec order).
            const sub = try self.toStringV(arg0(args));
            const start = try self.clampPos(arg(args, 1), s.len);
            return Value{ .number = if (std.mem.indexOfPos(u8, s, start, sub)) |idx| @floatFromInt(idx) else -1 };
        }
        if (eq(name, "includes")) {
            if (try self.isRegExp(arg0(args))) return self.throwError("TypeError", "First argument to String.prototype.includes must not be a regular expression");
            const sub = try self.toStringV(arg0(args));
            const pos = try self.clampPos(arg(args, 1), s.len);
            return Value{ .boolean = std.mem.indexOf(u8, s[pos..], sub) != null };
        }
        if (eq(name, "startsWith")) {
            if (try self.isRegExp(arg0(args))) return self.throwError("TypeError", "First argument to String.prototype.startsWith must not be a regular expression");
            const sub = try self.toStringV(arg0(args));
            const pos = try self.clampPos(arg(args, 1), s.len);
            return Value{ .boolean = std.mem.startsWith(u8, s[pos..], sub) };
        }
        if (eq(name, "endsWith")) {
            if (try self.isRegExp(arg0(args))) return self.throwError("TypeError", "First argument to String.prototype.endsWith must not be a regular expression");
            const sub = try self.toStringV(arg0(args));
            // `endPosition` defaults to the string length; the match ends there.
            const end_pos = if (args.len > 1 and args[1] != .undefined) try self.clampPos(args[1], s.len) else s.len;
            return Value{ .boolean = std.mem.endsWith(u8, s[0..end_pos], sub) };
        }
        if (eq(name, "slice")) {
            const start = try relIndex(self, arg0(args), s.len, 0);
            const end = try relIndex(self, arg(args, 1), s.len, @floatFromInt(s.len));
            return Value{ .string = if (start < end) try self.arena.dupe(u8, s[start..end]) else "" };
        }
        if (eq(name, "substring")) {
            var a0 = try relIndex(self, arg0(args), s.len, 0);
            var b0 = try relIndex(self, arg(args, 1), s.len, @floatFromInt(s.len));
            if (a0 > b0) {
                const t = a0;
                a0 = b0;
                b0 = t;
            }
            return Value{ .string = try self.arena.dupe(u8, s[a0..b0]) };
        }
        if (eq(name, "toUpperCase") or eq(name, "toLocaleUpperCase")) {
            // toLocaleUpperCase delegates to the locale-independent full Unicode
            // mapping here (the engine has no ICU data); for the default locale
            // they agree.
            return Value{ .string = try unicode_case.toUpper(self.arena, s) };
        }
        if (eq(name, "toLowerCase") or eq(name, "toLocaleLowerCase")) {
            return Value{ .string = try unicode_case.toLower(self.arena, s) };
        }
        if (eq(name, "trim")) return Value{ .string = jsTrim(s, true, true) };
        if (eq(name, "repeat")) {
            const rn = try self.toNumberV(arg0(args));
            if (rn < 0 or std.math.isInf(rn)) return self.throwError("RangeError", "Invalid count value");
            const n = toLen(rn);
            var buf: std.ArrayListUnmanaged(u8) = .empty;
            var i: usize = 0;
            while (i < n) : (i += 1) try buf.appendSlice(self.arena, s);
            return Value{ .string = try buf.toOwnedSlice(self.arena) };
        }
        if (eq(name, "concat")) {
            var buf: std.ArrayListUnmanaged(u8) = .empty;
            try buf.appendSlice(self.arena, s);
            for (args) |a| try buf.appendSlice(self.arena, try self.toStringV(a));
            return Value{ .string = try buf.toOwnedSlice(self.arena) };
        }
        if (eq(name, "split")) {
            const result = try self.newArray();
            const out = &result.object.elements;
            // `limit` (ToUint32; absent → effectively unbounded). limit 0 → [].
            const lim: usize = if (args.len > 1 and args[1] != .undefined) args[1].toUint32() else std.math.maxInt(u32);
            if (lim == 0) return result;
            // No separator → the whole string as the sole element.
            if (args.len == 0 or args[0] == .undefined) {
                try out.append(self.arena, .{ .string = try self.arena.dupe(u8, s) });
                return result;
            }
            // Regex separator: split on each match, inserting capture groups, per
            // the String.prototype.split(@@split) algorithm.
            if (args[0] == .object and args[0].object.is_regex) {
                var re = try self.compileRegex(args[0].object);
                if (s.len == 0) {
                    // Empty input: [""] unless the pattern matches the empty string.
                    if ((re.find(s) catch null) == null) try out.append(self.arena, .{ .string = s });
                    return result;
                }
                var p: usize = 0; // end of the previous piece
                var q: usize = 0; // scan cursor
                while (q < s.len) {
                    const m = re.find(s[q..]) catch null orelse break;
                    const m_start = q + m.start;
                    const m_end = q + m.end;
                    if (m_end == p) { // empty match flush against the last split — skip
                        q = m_start + 1;
                        continue;
                    }
                    try out.append(self.arena, .{ .string = try self.arena.dupe(u8, s[p..m_start]) });
                    if (out.items.len >= lim) return result;
                    for (0..m.captures.len) |ci| {
                        try out.append(self.arena, try self.captureVal(m, ci));
                        if (out.items.len >= lim) return result;
                    }
                    p = m_end;
                    q = if (m_end > m_start) m_end else m_end + 1;
                }
                try out.append(self.arena, .{ .string = try self.arena.dupe(u8, s[p..]) });
                return result;
            }
            const sep = try args[0].toString(self.arena);
            if (sep.len == 0) {
                for (s) |c| {
                    if (out.items.len >= lim) return result;
                    try out.append(self.arena, .{ .string = try self.arena.dupe(u8, &.{c}) });
                }
                return result;
            }
            var it = std.mem.splitSequence(u8, s, sep);
            while (it.next()) |part| {
                if (out.items.len >= lim) return result;
                try out.append(self.arena, .{ .string = try self.arena.dupe(u8, part) });
            }
            return result;
        }
        if (eq(name, "at")) {
            const fl = @trunc(try self.toNumberV(arg0(args)));
            const idx: i64 = if (fl < 0) @as(i64, @intCast(s.len)) + @as(i64, @intFromFloat(fl)) else @intFromFloat(fl);
            if (idx < 0 or idx >= s.len) return Value.undefined;
            return Value{ .string = try self.arena.dupe(u8, s[@intCast(idx) .. @as(usize, @intCast(idx)) + 1]) };
        }
        if (eq(name, "trimStart")) return Value{ .string = jsTrim(s, true, false) };
        if (eq(name, "trimEnd")) return Value{ .string = jsTrim(s, false, true) };
        if (eq(name, "padStart") or eq(name, "padEnd")) {
            const target = toLen(try self.toNumberV(arg0(args)));
            if (s.len >= target) return Value{ .string = try self.arena.dupe(u8, s) };
            const pad = if (args.len > 1 and args[1] != .undefined) try self.toStringV(args[1]) else " ";
            if (pad.len == 0) return Value{ .string = try self.arena.dupe(u8, s) };
            var buf: std.ArrayListUnmanaged(u8) = .empty;
            const fill_len = target - s.len;
            if (eq(name, "padEnd")) try buf.appendSlice(self.arena, s);
            var k: usize = 0;
            while (k < fill_len) : (k += 1) try buf.append(self.arena, pad[k % pad.len]);
            if (eq(name, "padStart")) try buf.appendSlice(self.arena, s);
            return Value{ .string = try buf.toOwnedSlice(self.arena) };
        }
        if (eq(name, "replace") or eq(name, "replaceAll")) {
            const all = eq(name, "replaceAll");
            const repl_val = arg(args, 1);
            const is_func = repl_val.isCallable();
            const template: []const u8 = if (is_func) "" else try repl_val.toString(self.arena);
            const a = self.arena;
            var buf: std.ArrayListUnmanaged(u8) = .empty;

            // Regex pattern: replace each match (all matches when global/replaceAll),
            // expanding `$` substitutions or invoking a function replacer.
            if (arg0(args) == .object and arg0(args).object.is_regex) {
                const ro = arg0(args).object;
                const g = all or ((ro.getOwn("global") orelse Value{ .boolean = false }).boolean);
                var re = try self.compileRegex(ro);
                var last: usize = 0; // end of the last copied region
                var search: usize = 0; // absolute scan cursor
                while (search <= s.len) {
                    const m = re.find(s[search..]) catch null orelse break;
                    const mstart = search + m.start;
                    const mend = search + m.end;
                    try buf.appendSlice(a, s[last..mstart]);
                    if (is_func) {
                        var call_args: std.ArrayListUnmanaged(Value) = .empty;
                        try call_args.append(a, .{ .string = try a.dupe(u8, m.slice) });
                        for (0..m.captures.len) |i| try call_args.append(a, try self.captureVal(m, i));
                        try call_args.append(a, .{ .number = @floatFromInt(mstart) });
                        try call_args.append(a, .{ .string = s });
                        const r = try self.callValue(repl_val, call_args.items);
                        try buf.appendSlice(a, try r.toString(a));
                    } else {
                        const groups = try self.regexGroups(&re, m);
                        try self.getSubstitution(&buf, template, m.slice, s, mstart, m.captures, groups);
                    }
                    last = mend;
                    search = if (mend > mstart) mend else mend + 1; // step past an empty match
                    if (!g) break;
                }
                try buf.appendSlice(a, s[last..]);
                return Value{ .string = try buf.toOwnedSlice(a) };
            }

            // String pattern: replace the first occurrence (or all for replaceAll).
            const pat = try arg0(args).toString(a);
            var from: usize = 0;
            while (from <= s.len) { // `from` stays in-bounds so the search never reads past the end
                const idx = std.mem.indexOfPos(u8, s, from, pat) orelse break;
                try buf.appendSlice(a, s[from..idx]);
                if (is_func) {
                    const r = try self.callValue(repl_val, &.{ .{ .string = pat }, .{ .number = @floatFromInt(idx) }, .{ .string = s } });
                    try buf.appendSlice(a, try r.toString(a));
                } else {
                    try self.getSubstitution(&buf, template, pat, s, idx, &.{}, null);
                }
                from = idx + pat.len;
                if (pat.len == 0) { // empty pattern: copy one char and step past it
                    if (from < s.len) try buf.append(a, s[from]);
                    from += 1;
                }
                if (!all) break;
            }
            if (from <= s.len) try buf.appendSlice(a, s[from..]);
            return Value{ .string = try buf.toOwnedSlice(a) };
        }
        if (eq(name, "codePointAt")) {
            const i = toLen(try self.toNumberV(arg0(args)));
            return if (i < s.len) Value{ .number = @floatFromInt(s[i]) } else Value.undefined;
        }
        if (eq(name, "lastIndexOf")) {
            // ToString(searchString) then ToNumber(position): a NaN position
            // (incl. the default `undefined`) searches the whole string; otherwise
            // the match must start at or before the clamped position.
            const sub = try self.toStringV(arg0(args));
            const np = try self.toNumberV(arg(args, 1));
            const limit: usize = if (std.math.isNan(np)) s.len else if (np <= 0)
                0
            else if (np >= @as(f64, @floatFromInt(s.len))) s.len else @intFromFloat(@trunc(np));
            if (sub.len == 0) return Value{ .number = @floatFromInt(@min(limit, s.len)) };
            // A match starting at k (k ≤ limit) occupies s[k .. k+sub.len); the
            // largest such k is the last occurrence within s[0 .. limit+sub.len].
            const hi = @min(limit + sub.len, s.len);
            return Value{ .number = if (std.mem.lastIndexOf(u8, s[0..hi], sub)) |idx| @floatFromInt(idx) else -1 };
        }
        if (eq(name, "substr")) {
            // `substr(start, length)`: start may count from the end.
            const start = try relIndex(self, arg0(args), s.len, 0);
            const remaining = s.len - start;
            const len: usize = if (args.len > 1 and arg(args, 1) != .undefined) blk: {
                const l = arg(args, 1).toNumber();
                if (std.math.isNan(l) or l <= 0) break :blk 0;
                const lu: usize = @intFromFloat(@trunc(l));
                break :blk @min(lu, remaining);
            } else remaining;
            return Value{ .string = try self.arena.dupe(u8, s[start .. start + len]) };
        }
        if (eq(name, "localeCompare")) {
            const other = try arg0(args).toString(self.arena);
            return Value{ .number = switch (std.mem.order(u8, s, other)) {
                .lt => -1,
                .eq => 0,
                .gt => 1,
            } };
        }
        if (eq(name, "normalize")) {
            // v1: ASCII-only engine, so normalization is the identity.
            return Value{ .string = try self.arena.dupe(u8, s) };
        }
        if (eq(name, "search")) {
            const re_obj = try self.toRegexObject(arg0(args));
            var re = try self.compileRegex(re_obj);
            if (re.find(s) catch null) |m| return Value{ .number = @floatFromInt(m.start) };
            return Value{ .number = -1 };
        }
        if (eq(name, "match")) {
            const re_obj = try self.toRegexObject(arg0(args));
            const global = (re_obj.getOwn("global") orelse Value{ .boolean = false }).toBoolean();
            var re = try self.compileRegex(re_obj);
            if (global) {
                // Global match: an array of all matched substrings (or null).
                const arr = try self.newArray();
                var rest = s;
                while (re.find(rest) catch null) |m| {
                    try arr.object.elements.append(self.arena, .{ .string = try self.arena.dupe(u8, m.slice) });
                    if (m.end <= m.start) break; // avoid an infinite loop on empty matches
                    rest = rest[m.end..];
                }
                return if (arr.object.elements.items.len == 0) Value.null else arr;
            }
            // Non-global: defer to RegExp.prototype.exec (full result shape).
            return (try self.regexMethod(re_obj, "exec", &.{.{ .string = s }})).?;
        }
        if (eq(name, "matchAll")) {
            const re_obj = try self.toRegexObject(arg0(args));
            // Snapshot every match (each as an exec-style result) and return an
            // iterator over them. A global/sticky exec advances lastIndex; use a
            // fresh regex so the caller's object isn't mutated.
            const flags = (re_obj.getOwn("flags") orelse Value{ .string = "" }).string;
            const has_g = std.mem.indexOfScalar(u8, flags, 'g') != null;
            const gflags = if (has_g) flags else try std.mem.concat(self.arena, u8, &.{ flags, "g" });
            const iter_re = (try self.makeRegex((re_obj.getOwn("source") orelse Value{ .string = "" }).string, gflags)).object;
            const results = try self.newArray();
            while (true) {
                const r = (try self.regexMethod(iter_re, "exec", &.{.{ .string = s }})).?;
                if (r == .null) break;
                try results.object.elements.append(self.arena, r);
                // Guard against an empty match stalling lastIndex.
                if (r.object.elements.items.len > 0 and r.object.elements.items[0].string.len == 0) {
                    const li = toLen((iter_re.getOwn("lastIndex") orelse Value{ .number = 0 }).toNumber());
                    try self.setProp(iter_re, "lastIndex", .{ .number = @floatFromInt(li + 1) });
                }
            }
            return try self.iteratorOf(results);
        }
        return null;
    }

    /// Coerce a value to a RegExp object: a regex stays as-is; anything else
    /// becomes `new RegExp(String(v))`.
    fn toRegexObject(self: *Interpreter, v: Value) EvalError!*value.Object {
        if (v == .object and v.object.is_regex) return v.object;
        const pat = if (v == .undefined) "" else try v.toString(self.arena);
        return (try self.makeRegex(pat, "")).object;
    }

    /// A capture group's value: `undefined` when the group did not participate
    /// in the match (an unmatched optional), else its matched substring.
    fn captureVal(self: *Interpreter, m: regex.Match, i: usize) EvalError!Value {
        if (i < m.captures_present.len and !m.captures_present[i]) return .undefined;
        return .{ .string = try self.arena.dupe(u8, m.captures[i]) };
    }

    /// The `groups` object for a match — `{ name: capture }` for each named
    /// group — or null when the pattern has no named groups (then `groups` is
    /// `undefined`).
    fn regexGroups(self: *Interpreter, re: *regex.Regex, m: regex.Match) EvalError!?*value.Object {
        if (re.named_captures.count() == 0) return null;
        const o = (try self.newObject()).object;
        var it = re.named_captures.iterator();
        while (it.next()) |e| {
            const idx = e.value_ptr.*; // 1-based capture index
            const v: Value = if (idx >= 1 and idx <= m.captures.len)
                try self.captureVal(m, idx - 1)
            else
                .undefined;
            try self.setProp(o, e.key_ptr.*, v);
        }
        return o;
    }

    /// GetSubstitution: append `template` to `buf`, expanding the `$` forms —
    /// `$$`, `$&` (matched), `` $` `` (prefix), `$'` (suffix), `$n`/`$nn`
    /// (capture groups, 1-based), and `$<name>` (named groups).
    fn getSubstitution(
        self: *Interpreter,
        buf: *std.ArrayListUnmanaged(u8),
        template: []const u8,
        matched: []const u8,
        str: []const u8,
        position: usize,
        captures: []const []const u8,
        groups: ?*value.Object,
    ) EvalError!void {
        const a = self.arena;
        var i: usize = 0;
        while (i < template.len) : (i += 1) {
            if (template[i] != '$' or i + 1 >= template.len) {
                try buf.append(a, template[i]);
                continue;
            }
            switch (template[i + 1]) {
                '$' => {
                    try buf.append(a, '$');
                    i += 1;
                },
                '&' => {
                    try buf.appendSlice(a, matched);
                    i += 1;
                },
                '`' => {
                    try buf.appendSlice(a, str[0..position]);
                    i += 1;
                },
                '\'' => {
                    const end = position + matched.len;
                    try buf.appendSlice(a, if (end <= str.len) str[end..] else "");
                    i += 1;
                },
                '<' => {
                    // `$<name>` — only when the pattern had named groups.
                    if (groups == null) {
                        try buf.append(a, '$');
                        continue;
                    }
                    const close = std.mem.indexOfScalarPos(u8, template, i + 2, '>') orelse {
                        try buf.append(a, '$');
                        continue;
                    };
                    const gv = groups.?.getOwn(template[i + 2 .. close]) orelse Value.undefined;
                    if (gv == .string) try buf.appendSlice(a, gv.string);
                    i = close;
                },
                '0'...'9' => {
                    var idx: usize = template[i + 1] - '0';
                    var consumed: usize = 1;
                    if (i + 2 < template.len and template[i + 2] >= '0' and template[i + 2] <= '9') {
                        const two = idx * 10 + (template[i + 2] - '0');
                        if (two >= 1 and two <= captures.len) {
                            idx = two;
                            consumed = 2;
                        }
                    }
                    if (idx >= 1 and idx <= captures.len) {
                        try buf.appendSlice(a, captures[idx - 1]);
                        i += consumed;
                    } else {
                        try buf.append(a, '$'); // not a valid group reference → literal `$`
                    }
                },
                else => try buf.append(a, '$'),
            }
        }
    }

    // ---- try / catch / finally --------------------------------------------

    fn evalTry(self: *Interpreter, t: *ast.TryNode) EvalError!Value {
        var result: Value = .undefined;
        if (self.eval(t.block)) |v| {
            result = v;
        } else |err| {
            if (err == error.Throw and t.catch_block != null) {
                const exc = self.exception;
                self.exception = .undefined;
                const catch_env = try self.arena.create(Environment);
                catch_env.* = .{ .arena = self.arena, .parent = self.env };
                const saved = self.env;
                self.env = catch_env;
                // Bind the catch target (identifier or destructuring pattern)
                // into the catch scope.
                if (t.catch_param) |p| try self.bindPattern(p, exc, true);
                const catch_result = self.eval(t.catch_block.?);
                self.env = saved;
                if (catch_result) |v| {
                    result = v;
                } else |cerr| {
                    if (t.finally_block) |fb| _ = try self.eval(fb);
                    return cerr;
                }
            } else {
                // No catch (or a non-JS host error): run finally, then rethrow.
                if (t.finally_block) |fb| _ = try self.eval(fb);
                return err;
            }
        }
        if (t.finally_block) |fb| _ = try self.eval(fb);
        return result;
    }

    fn evalUnary(self: *Interpreter, op: ast.UnaryOp, operand: *Node) EvalError!Value {
        // `typeof <unresolved identifier>` is "undefined" rather than a thrown
        // ReferenceError — the one context where an unbound name doesn't throw.
        if (op == .typeof and operand.* == .identifier and self.env.get(operand.identifier) == null)
            return .{ .string = "undefined" };
        const v = try self.eval(operand);
        // BigInt unary: `-`/`~` stay BigInt; unary `+` is a TypeError; `typeof`/
        // `!`/`void` work as for any value.
        if (v == .object and v.object.is_bigint and (op == .neg or op == .pos or op == .bit_not)) {
            return switch (op) {
                .neg => try self.makeBigInt(-%v.object.bigint),
                .bit_not => try self.makeBigInt(~v.object.bigint),
                .pos => self.throwError("TypeError", "Cannot convert a BigInt value to a number"),
                else => unreachable,
            };
        }
        return switch (op) {
            .neg => .{ .number = -(try self.toNumberV(v)) },
            .pos => .{ .number = try self.toNumberV(v) },
            .not => .{ .boolean = !v.toBoolean() },
            .typeof => .{ .string = v.typeOf() },
            .bit_not => .{ .number = @floatFromInt(~v.toInt32()) },
            .void_op => .undefined,
        };
    }

    fn evalLogical(self: *Interpreter, op: ast.LogicalOp, left: *Node, right: *Node) EvalError!Value {
        const l = try self.eval(left);
        return switch (op) {
            .@"and" => if (l.toBoolean()) try self.eval(right) else l,
            .@"or" => if (l.toBoolean()) l else try self.eval(right),
            .nullish => if (l == .null or l == .undefined) try self.eval(right) else l,
        };
    }

    fn evalBinary(self: *Interpreter, op: ast.BinaryOp, left_node: *Node, right_node: *Node) EvalError!Value {
        const l = try self.eval(left_node);
        const r = try self.eval(right_node);
        return self.applyBinary(op, l, r);
    }

    /// Apply a binary operator to two already-evaluated operands. Shared by the
    /// tree-walker and the bytecode VM.
    /// ToPrimitive: coerce a value to a primitive. Non-objects pass through; a
    /// Symbol is returned as-is. For an object, try `valueOf` then `toString`
    /// (order flipped for a string hint) via `callMethod` — so the universal
    /// `valueOf`/`toString` apply even to proto-less plain objects — and the
    /// first primitive result wins.
    pub fn toPrimitive(self: *Interpreter, v: Value, hint: enum { default, number, string }) EvalError!Value {
        if (v != .object or v.object.is_symbol or v.object.is_bigint) return v;
        const o = v.object;
        // GetMethod(v, @@toPrimitive): if present, it alone decides — it is called
        // with the hint string and must return a non-object (an object result is
        // the "Cannot convert" TypeError); a non-callable @@toPrimitive throws.
        if (self.wellKnownSymbolKey("toPrimitive")) |tpkey| {
            const exotic = try self.getProperty(v, tpkey);
            if (exotic != .undefined and exotic != .null) {
                if (!exotic.isCallable()) return self.throwError("TypeError", "@@toPrimitive value is not callable");
                const hint_str: []const u8 = switch (hint) {
                    .string => "string",
                    .number => "number",
                    .default => "default",
                };
                const res = try self.callValueWithThis(exotic, &.{.{ .string = hint_str }}, v);
                if (res != .object or res.object.is_symbol or res.object.is_bigint) return res;
                return self.throwError("TypeError", "Cannot convert object to primitive value");
            }
        }
        // Honor a *user-defined* valueOf/toString (a JS function found on the
        // object or its prototype chain — e.g. `{ valueOf() {…} }` or a class
        // method) in the hint's order; the first primitive result wins. The
        // engine's built-in `valueOf`/`toString` (native prototype thunks) are
        // skipped here — falling through to the built-in coercion below — which
        // also avoids looping back through method dispatch.
        const names: [2][]const u8 = if (hint == .string) .{ "toString", "valueOf" } else .{ "valueOf", "toString" };
        var user_tried: u8 = 0;
        for (names) |m| {
            // OrdinaryToPrimitive resolves each method via `Get(O, name)`, so an
            // *accessor* `valueOf`/`toString` getter is run (and its abrupt
            // completion must propagate — `{ get valueOf() { throw } }`). A data
            // property that is a JS function is the method directly; the engine's
            // native prototype thunks / non-callable shadows are left to the
            // built-in coercion below (calling them would loop through dispatch).
            var method: ?Value = null;
            var cur: ?*value.Object = o;
            while (cur) |c| : (cur = c.proto) {
                if (c.getAccessor(m)) |acc| {
                    if (acc.get) |g| {
                        if (g != .undefined) method = try self.callValueWithThis(g, &.{}, v);
                    }
                    break;
                }
                if (c.getOwn(m)) |fv| {
                    if (fv == .object and fv.object.js_func != null) method = fv;
                    break; // native thunk or non-callable shadow → built-in coercion
                }
            }
            if (method) |fnv| {
                if (fnv.isCallable()) {
                    user_tried += 1;
                    const res = try self.callValueWithThis(fnv, &.{}, v);
                    // A BigInt or Symbol result is a primitive (it is represented
                    // as an object internally), so it ends ToPrimitive too.
                    if (res != .object or res.object.is_bigint or res.object.is_symbol) return res;
                }
            }
        }
        // Both `toString` and `valueOf` were user-defined and each returned an
        // object — there's no built-in to fall back to, so this is the spec's
        // "Cannot convert object to primitive value" TypeError.
        if (user_tried == 2) return self.throwError("TypeError", "Cannot convert object to primitive value");
        // A callable object with no user-defined valueOf/toString stringifies via
        // Function.prototype.toString (its source text / native syntax). `valueOf`
        // returns the object itself, so `toString` always wins regardless of hint.
        if (o.isCallableObject()) return try self.functionToString(o);
        // A primitive-wrapper object (`new Number/String/Boolean`) with no user
        // override unwraps to its boxed primitive — except for a string hint,
        // where it stringifies (so `new Number(5) + 1 === 6` but `String hint`
        // gives "5").
        if (o.prim) |p| {
            if (hint == .string) return .{ .string = try p.toString(self.arena) };
            return p;
        }
        // The built-in "[object …]" / array-join / Date / error fallback is the
        // result of the *built-in* `toString`; it is only reachable when
        // `toString` still resolves to that built-in. If it is shadowed — by a
        // non-callable own value (`toString: undefined`) or by a user method
        // (which, having been tried in the loop above, must have returned an
        // object, since we're at the fallback) — there is no primitive and no
        // built-in to fall back to: the spec's "Cannot convert object to
        // primitive value" TypeError.
        const own_ts = o.getOwn("toString");
        const ts_shadowed = (own_ts != null and !own_ts.?.isCallable()) or userMethodOf(o, "toString") != null;
        if (ts_shadowed) return self.throwError("TypeError", "Cannot convert object to primitive value");
        return .{ .string = try v.toString(self.arena) };
    }

    /// A *user-defined* `name` method on `o`'s own properties or prototype chain
    /// — a JS function (`js_func`), not one of the engine's native built-in
    /// prototype thunks (calling those would loop back through dispatch). The
    /// nearest definition shadows: if it's a native thunk we stop and report
    /// none, so ToPrimitive uses the built-in coercion instead.
    fn userMethodOf(o: *value.Object, name: []const u8) ?Value {
        var cur: ?*value.Object = o;
        while (cur) |c| : (cur = c.proto) {
            if (c.getOwn(name)) |fv| {
                return if (fv == .object and fv.object.js_func != null) fv else null;
            }
        }
        return null;
    }

    pub fn applyBinary(self: *Interpreter, op_in: ast.BinaryOp, l_in: Value, r_in: Value) EvalError!Value {
        const op = op_in;
        var l = l_in;
        var r = r_in;
        // Coerce object operands to primitives first (ToPrimitive). `+` uses the
        // "default" hint; the other arithmetic / relational / bitwise ops use
        // "number". Equality and instanceof/in handle objects themselves.
        switch (op) {
            .add => {
                l = try self.toPrimitive(l, .default);
                r = try self.toPrimitive(r, .default);
            },
            .sub, .mul, .div, .mod, .pow, .lt, .le, .gt, .ge, .bit_and, .bit_or, .bit_xor, .shl, .shr, .ushr => {
                l = try self.toPrimitive(l, .number);
                r = try self.toPrimitive(r, .number);
            },
            .eq, .neq => {
                // Abstract equality (IsLooselyEqual): when one operand is an
                // ordinary object and the other is a primitive, the object is
                // ToPrimitive'd (default hint) and the comparison retried — so
                // `Object("1") == "1"` and `{valueOf(){return 1}} == 1` hold. Two
                // objects compare by identity, and an object vs null/undefined is
                // always unequal, so neither is coerced. A BigInt/Symbol value is
                // boxed as an object here but counts as a primitive operand.
                const l_obj = l == .object and !l.object.is_bigint and !l.object.is_symbol;
                const r_obj = r == .object and !r.object.is_bigint and !r.object.is_symbol;
                if (l_obj and !r_obj and r != .undefined and r != .null) l = try self.toPrimitive(l, .default);
                if (r_obj and !l_obj and l != .undefined and l != .null) r = try self.toPrimitive(r, .default);
            },
            else => {},
        }
        // BigInt operands. Arithmetic/bitwise require both to be BigInt (mixing
        // with a Number is a TypeError); relational ops compare mathematically;
        // `+` with a string still concatenates.
        const l_big = l == .object and l.object.is_bigint;
        const r_big = r == .object and r.object.is_bigint;
        if (l_big or r_big) {
            switch (op) {
                .add => if (l == .string or r == .string) {} else return self.bigIntBinary(op, l, r, l_big, r_big),
                .sub, .mul, .div, .mod, .pow, .bit_and, .bit_or, .bit_xor, .shl, .shr => return self.bigIntBinary(op, l, r, l_big, r_big),
                .ushr => return self.throwError("TypeError", "BigInts have no unsigned right shift, use >> instead"),
                .lt => return .{ .boolean = bigCmp(l, r) < 0 },
                .le => return .{ .boolean = bigCmp(l, r) <= 0 },
                .gt => return .{ .boolean = bigCmp(l, r) > 0 },
                .ge => return .{ .boolean = bigCmp(l, r) >= 0 },
                else => {},
            }
        }
        return switch (op) {
            .add => blk: {
                // String concatenation if either operand is a string.
                if (l == .string or r == .string) {
                    const ls = try l.toString(self.arena);
                    const rs = try r.toString(self.arena);
                    break :blk .{ .string = try std.mem.concat(self.arena, u8, &.{ ls, rs }) };
                }
                break :blk .{ .number = l.toNumber() + r.toNumber() };
            },
            .sub => .{ .number = l.toNumber() - r.toNumber() },
            .mul => .{ .number = l.toNumber() * r.toNumber() },
            .div => .{ .number = l.toNumber() / r.toNumber() },
            .mod => .{ .number = @mod(l.toNumber(), r.toNumber()) },
            .pow => .{ .number = std.math.pow(f64, l.toNumber(), r.toNumber()) },
            .lt => .{ .boolean = try lessThan(l, r) },
            .le => .{ .boolean = !(try lessThan(r, l)) and !relationalNaN(l, r) },
            .gt => .{ .boolean = try lessThan(r, l) },
            .ge => .{ .boolean = !(try lessThan(l, r)) and !relationalNaN(l, r) },
            .eq => .{ .boolean = value.looseEquals(l, r) },
            .neq => .{ .boolean = !value.looseEquals(l, r) },
            .eq_strict => .{ .boolean = value.strictEquals(l, r) },
            .neq_strict => .{ .boolean = !value.strictEquals(l, r) },
            .instanceof => .{ .boolean = try self.instanceOf(l, r) },
            .in_op => .{ .boolean = try self.inOperator(l, r) },
            .bit_and => .{ .number = @floatFromInt(l.toInt32() & r.toInt32()) },
            .bit_or => .{ .number = @floatFromInt(l.toInt32() | r.toInt32()) },
            .bit_xor => .{ .number = @floatFromInt(l.toInt32() ^ r.toInt32()) },
            .shl => blk: {
                const sh: u5 = @intCast(r.toUint32() & 31);
                break :blk .{ .number = @floatFromInt(@as(i32, @bitCast(l.toUint32() << sh))) };
            },
            .shr => blk: {
                const sh: u5 = @intCast(r.toUint32() & 31);
                break :blk .{ .number = @floatFromInt(l.toInt32() >> sh) };
            },
            .ushr => blk: {
                const sh: u5 = @intCast(r.toUint32() & 31);
                break :blk .{ .number = @floatFromInt(l.toUint32() >> sh) };
            },
        };
    }

    /// A BigInt binary op (both operands must be BigInt — mixing is a TypeError).
    fn bigIntBinary(self: *Interpreter, op: ast.BinaryOp, l: Value, r: Value, l_big: bool, r_big: bool) EvalError!Value {
        if (!l_big or !r_big) return self.throwError("TypeError", "Cannot mix BigInt and other types, use explicit conversions");
        const a = l.object.bigint;
        const b = r.object.bigint;
        const res: i128 = switch (op) {
            .add => a +% b,
            .sub => a -% b,
            .mul => a *% b,
            .div => if (b == 0) return self.throwError("RangeError", "Division by zero") else @divTrunc(a, b),
            .mod => if (b == 0) return self.throwError("RangeError", "Division by zero") else @rem(a, b),
            .pow => blk: {
                if (b < 0) return self.throwError("RangeError", "Exponent must be non-negative");
                var acc: i128 = 1;
                var e = b;
                while (e > 0) : (e -= 1) acc *%= a;
                break :blk acc;
            },
            .bit_and => a & b,
            .bit_or => a | b,
            .bit_xor => a ^ b,
            .shl => if (b >= 128 or b <= -128) 0 else if (b >= 0) a << @intCast(b) else a >> @intCast(-b),
            .shr => if (b >= 128 or b <= -128) (if (a < 0) -1 else 0) else if (b >= 0) a >> @intCast(b) else a << @intCast(-b),
            else => 0,
        };
        return self.makeBigInt(res);
    }

    /// Mathematical comparison of two BigInt/Number operands (for `< <= > >=`),
    /// returning negative/zero/positive. (Lossy for BigInts beyond 2^53.)
    fn bigCmp(l: Value, r: Value) f64 {
        const lf: f64 = if (l == .object and l.object.is_bigint) @floatFromInt(l.object.bigint) else l.toNumber();
        const rf: f64 = if (r == .object and r.object.is_bigint) @floatFromInt(r.object.bigint) else r.toNumber();
        return lf - rf;
    }

    /// `x instanceof C`. v1 has a flat construction model: objects created by
    /// `new F()` carry `ctor_ref` pointing at F's object, and builtin error
    /// constructors carry `error_ctor`; this checks those links rather than a
    /// full prototype chain.
    /// `key in obj`: true if `obj` has the (own, since we lack a prototype
    /// chain) property or array index named by `key`.
    pub fn inOperator(self: *Interpreter, l: Value, r: Value) EvalError!bool {
        if (r != .object) return self.throwError("TypeError", "cannot use 'in' on a non-object");
        const o = r.object;
        const key = try self.keyOf(l);
        if (o.proxy_handler != null or o.proxy_revoked) return self.proxyHas(o, key);
        if (hasProperty(o, key)) return true;
        if (o.is_array) {
            if (std.mem.eql(u8, key, "length")) return true;
            if (arrayIndex(key)) |i| return i < o.elements.items.len and !o.isHole(i);
        }
        // The global object carries the installed globals as properties.
        if (self.global_object != null and o == self.global_object.? and rootEnv(self.env).get(key) != null) return true;
        return false;
    }

    pub fn instanceOf(self: *Interpreter, l: Value, r: Value) EvalError!bool {
        if (r != .object or !r.object.isCallableObject())
            return self.throwError("TypeError", "Right-hand side of 'instanceof' is not callable");
        return self.ordinaryHasInstance(r.object, l);
    }

    /// OrdinaryHasInstance(C=`rc`, O=`l`): is `rc.prototype` in `l`'s prototype
    /// chain? Plus the engine's constructor-identity shortcuts. Assumes `rc` is
    /// already known callable (false otherwise).
    /// An object's effective [[Prototype]]: its `proto`, or — for a callable
    /// (native/bound) function that was never given one — %Function.prototype%,
    /// which every function inherits.
    pub fn effectiveProto(self: *Interpreter, o: *value.Object) ?*value.Object {
        if (o.proto) |p| return p;
        if (o.native != null or o.js_func != null or o.bound != null) return self.functionProto();
        return null;
    }

    pub fn ordinaryHasInstance(self: *Interpreter, rc: *value.Object, l: Value) EvalError!bool {
        if (!rc.isCallableObject()) return false;
        if (l != .object) return false;
        const lo = l.object;
        if (rc.getOwn("prototype")) |p| {
            if (p == .object) {
                var cur: ?*value.Object = self.effectiveProto(lo);
                while (cur) |c| {
                    if (c == p.object) return true;
                    cur = self.effectiveProto(c);
                }
            }
        }
        if (lo.ctor_ref) |cr| if (cr == rc) return true;
        if (rc.error_ctor) |name| {
            if (lo.is_error and (std.mem.eql(u8, lo.error_name, name) or std.mem.eql(u8, name, "Error")))
                return true;
        }
        return false;
    }
};

/// `Function.prototype[Symbol.hasInstance](O)` — OrdinaryHasInstance with the
/// bound function `this` as the constructor (false when `this` isn't callable).
fn functionHasInstanceFn(ctx: *anyopaque, this: Value, args: []const Value) value.HostError!Value {
    const self: *Interpreter = @ptrCast(@alignCast(ctx));
    if (this != .object) return .{ .boolean = false };
    return .{ .boolean = try self.ordinaryHasInstance(this.object, if (args.len > 0) args[0] else .undefined) };
}

/// The global `eval`. Direct eval: the program text is parsed and run in the
/// *current* lexical environment (`self.env` at the call site — natives don't
/// push a scope), so `eval("var x = 1")` and `eval("x")` see and mutate the
/// caller's bindings, and function declarations introduced by the eval are
/// visible after it. A non-string argument is returned unchanged (per spec).
/// (Indirect eval's "run in the global scope" distinction isn't modeled yet —
/// every eval runs where it's called; this is faithful for the common direct
/// case and only differs for the rarer `(0, eval)(...)` form.)
fn evalFn(ctx: *anyopaque, this: Value, args: []const Value) value.HostError!Value {
    _ = this;
    const self: *Interpreter = @ptrCast(@alignCast(ctx));
    if (args.len == 0) return .undefined;
    if (args[0] != .string) return args[0]; // eval of a non-string is the identity
    const src = args[0].string;
    var parser = Parser.init(self.arena, src) catch return self.throwError("SyntaxError", "eval: invalid source");
    // A direct eval (this engine runs eval code in the caller's scope) inherits
    // the caller's strict mode, so the eval'd code's early errors — `var eval`,
    // `eval = …`, `with`, duplicate params, … — are enforced under strict.
    if (self.strict) parser.strict = true;
    const prog = parser.parseProgram() catch return self.throwError("SyntaxError", "eval: parse error");
    return self.eval(prog);
}

// --- Promise built-ins ----------------------------------------------------

/// `new Promise(executor)` — create a pending promise and synchronously call
/// `executor(resolve, reject)`. The resolve/reject closures carry the promise
/// in their `private_data`; an executor that throws rejects the promise.
fn promiseConstructorFn(ctx: *anyopaque, this: Value, args: []const Value) value.HostError!Value {
    _ = this;
    const self: *Interpreter = @ptrCast(@alignCast(ctx));
    // `Promise(...)` without `new` is a TypeError (only [[Construct]] sets new.target).
    if (self.new_target == .undefined) return self.throwError("TypeError", "Promise constructor cannot be invoked without 'new'");
    const executor = if (args.len > 0) args[0] else .undefined;
    if (!executor.isCallable()) return self.throwError("TypeError", "Promise resolver is not a function");
    const pobj = try promise.newPromise(self);
    const pp = pobj.promise.?;
    const res_fn = try self.arena.create(value.Object);
    res_fn.* = .{ .native = promiseResolveClosure, .private_data = pp };
    const rej_fn = try self.arena.create(value.Object);
    rej_fn.* = .{ .native = promiseRejectClosure, .private_data = pp };
    // The resolve/reject functions are anonymous, length 1 (spec).
    try installNativeProps(self.arena, self.root_shape, res_fn, "", 1);
    try installNativeProps(self.arena, self.root_shape, rej_fn, "", 1);
    if (self.callValueWithThis(executor, &.{ .{ .object = res_fn }, .{ .object = rej_fn } }, .undefined)) |_| {} else |err| {
        if (err == error.Throw) {
            const reason = self.exception;
            self.exception = .undefined;
            try promise.reject(self, @ptrCast(@alignCast(pp)), reason);
        } else return err;
    }
    return .{ .object = pobj };
}

fn promiseResolveClosure(ctx: *anyopaque, this: Value, args: []const Value) value.HostError!Value {
    _ = this;
    const self: *Interpreter = @ptrCast(@alignCast(ctx));
    const fnobj = self.active_native orelse return .undefined;
    try promise.resolve(self, @ptrCast(@alignCast(fnobj.private_data.?)), if (args.len > 0) args[0] else .undefined);
    return .undefined;
}

fn promiseRejectClosure(ctx: *anyopaque, this: Value, args: []const Value) value.HostError!Value {
    _ = this;
    const self: *Interpreter = @ptrCast(@alignCast(ctx));
    const fnobj = self.active_native orelse return .undefined;
    try promise.reject(self, @ptrCast(@alignCast(fnobj.private_data.?)), if (args.len > 0) args[0] else .undefined);
    return .undefined;
}

/// `Promise.prototype.then` — the result promise is built from
/// `SpeciesConstructor(this, %Promise%)`, so a subclass's `.then` yields a
/// subclass instance. The fast path (intrinsic species) skips the capability.
fn promiseThenImpl(self: *Interpreter, this: Value, on_f: Value, on_r: Value) value.HostError!Value {
    const p = promise.promiseOf(this) orelse return self.throwError("TypeError", "Promise.prototype.then called on a non-Promise");
    const default_ctor = self.env.get("Promise") orelse .undefined;
    const c = try self.speciesConstructor(this, default_ctor);
    // Intrinsic Promise → cheap native capability; a subclass/custom → its own.
    if (c == .object and default_ctor == .object and c.object == default_ctor.object)
        return promise.then(self, p, on_f, on_r);
    const cap = try newPromiseCapability(self, c);
    try promise.performThen(self, p, on_f, on_r, cap.resolve, cap.reject);
    return cap.promise;
}

/// A getter (or method) that simply returns its receiver — `get [@@species]() {
/// return this; }`.
fn returnThisFn(ctx: *anyopaque, this: Value, args: []const Value) value.HostError!Value {
    _ = ctx;
    _ = args;
    return this;
}

fn promiseThenFn(ctx: *anyopaque, this: Value, args: []const Value) value.HostError!Value {
    const self: *Interpreter = @ptrCast(@alignCast(ctx));
    return promiseThenImpl(self, this, if (args.len > 0) args[0] else .undefined, if (args.len > 1) args[1] else .undefined);
}

fn promiseCatchFn(ctx: *anyopaque, this: Value, args: []const Value) value.HostError!Value {
    const self: *Interpreter = @ptrCast(@alignCast(ctx));
    // `catch(f)` is `then(undefined, f)` — including its species behavior.
    return promiseThenImpl(self, this, .undefined, if (args.len > 0) args[0] else .undefined);
}

/// Captured state for a `finally` reaction (`then`/`catch` side) and its inner
/// value-restoring thunk.
const FinallyData = struct { on_finally: Value, captured: Value = .undefined, is_catch: bool };

/// `thenFinally`/`catchFinally`: run `onFinally()`, then — once its result
/// settles — re-yield the original value (or re-throw the original reason),
/// so `finally` is transparent to the settled completion.
fn finallyReactionFn(ctx: *anyopaque, this: Value, args: []const Value) value.HostError!Value {
    _ = this;
    const self: *Interpreter = @ptrCast(@alignCast(ctx));
    const fnobj = self.active_native orelse return .undefined;
    const d: *FinallyData = @ptrCast(@alignCast(fnobj.private_data.?));
    const incoming = if (args.len > 0) args[0] else .undefined;
    const result = try self.callValue(d.on_finally, &.{}); // may throw → propagates (rejects)
    const wrapped = try promiseResolveValue(self, result);
    const wp = promise.promiseOf(wrapped).?;
    // After onFinally's result settles, a thunk that ignores its argument and
    // reinstates the original completion.
    const thunk = try self.arena.create(value.Object);
    const td = try self.arena.create(FinallyData);
    td.* = .{ .on_finally = .undefined, .captured = incoming, .is_catch = d.is_catch };
    thunk.* = .{ .native = finallyThunkFn, .private_data = @ptrCast(td) };
    return promise.then(self, wp, .{ .object = thunk }, .undefined);
}

fn finallyThunkFn(ctx: *anyopaque, this: Value, args: []const Value) value.HostError!Value {
    _ = this;
    _ = args;
    const self: *Interpreter = @ptrCast(@alignCast(ctx));
    const fnobj = self.active_native orelse return .undefined;
    const d: *FinallyData = @ptrCast(@alignCast(fnobj.private_data.?));
    if (d.is_catch) {
        self.exception = d.captured; // re-throw the original rejection reason
        return error.Throw;
    }
    return d.captured; // re-yield the original fulfillment value
}

fn promiseFinallyFn(ctx: *anyopaque, this: Value, args: []const Value) value.HostError!Value {
    const self: *Interpreter = @ptrCast(@alignCast(ctx));
    const p = promise.promiseOf(this) orelse return self.throwError("TypeError", "Promise.prototype.finally called on a non-Promise");
    const cb = if (args.len > 0) args[0] else .undefined;
    // A non-callable `onFinally` is used directly for both reactions (spec).
    if (!cb.isCallable()) return promise.then(self, p, cb, cb);
    const onf = try self.arena.create(value.Object);
    const ond = try self.arena.create(FinallyData);
    ond.* = .{ .on_finally = cb, .is_catch = false };
    onf.* = .{ .native = finallyReactionFn, .private_data = @ptrCast(ond) };
    try installNativeProps(self.arena, self.root_shape, onf, "", 1);
    const onr = try self.arena.create(value.Object);
    const ord = try self.arena.create(FinallyData);
    ord.* = .{ .on_finally = cb, .is_catch = true };
    onr.* = .{ .native = finallyReactionFn, .private_data = @ptrCast(ord) };
    try installNativeProps(self.arena, self.root_shape, onr, "", 1);
    return promise.then(self, p, .{ .object = onf }, .{ .object = onr });
}

/// Internal `PromiseResolve(%Promise%, v)`: `v` itself if already a native
/// promise, else a fresh native promise fulfilled with `v` (adopting a
/// thenable). Used by the combinators/`finally` where the constructor is always
/// the intrinsic `Promise` — no observable `this` or capability involved.
fn promiseResolveValue(self: *Interpreter, v: Value) EvalError!Value {
    if (promise.promiseOf(v) != null) return v;
    const pobj = try promise.newPromise(self);
    try promise.resolve(self, @ptrCast(@alignCast(pobj.promise.?)), v);
    return .{ .object = pobj };
}

/// `Promise.resolve(v)` — uses `this` as the constructor `C`: returns `v`
/// unchanged when it is a promise whose `constructor` is `C`, otherwise builds
/// `C`'s capability and resolves it with `v` (so a subclass's `resolve` yields a
/// subclass instance).
fn promiseResolveStaticFn(ctx: *anyopaque, this: Value, args: []const Value) value.HostError!Value {
    const self: *Interpreter = @ptrCast(@alignCast(ctx));
    if (this != .object) return self.throwError("TypeError", "Promise.resolve called on a non-object");
    const v = if (args.len > 0) args[0] else .undefined;
    if (promise.promiseOf(v) != null) {
        const ctor = try self.getProperty(v, "constructor");
        if (ctor == .object and ctor.object == this.object) return v;
    }
    const cap = try newPromiseCapability(self, this);
    _ = try self.callValue(cap.resolve, &.{v});
    return cap.promise;
}

/// `Promise.reject(e)` — builds `this`'s capability and rejects it with `e`.
fn promiseRejectStaticFn(ctx: *anyopaque, this: Value, args: []const Value) value.HostError!Value {
    const self: *Interpreter = @ptrCast(@alignCast(ctx));
    const cap = try newPromiseCapability(self, this);
    _ = try self.callValue(cap.reject, &.{if (args.len > 0) args[0] else .undefined});
    return cap.promise;
}

/// `Object.groupBy(items, callback)` — group `items` into a null-prototype
/// object keyed by `callback(value, index)` (coerced to a property key), each
/// bucket an array of the values in iteration order.
fn objectGroupByFn(ctx: *anyopaque, this: Value, args: []const Value) value.HostError!Value {
    _ = this;
    const self: *Interpreter = @ptrCast(@alignCast(ctx));
    const cb = if (args.len > 1) args[1] else .undefined;
    if (!cb.isCallable()) return self.throwError("TypeError", "Object.groupBy: callback is not a function");
    const elems = try collectIterable(self, if (args.len > 0) args[0] else .undefined);
    const obj = (try self.newObject()).object;
    obj.proto = null; // groupBy result has a null prototype
    for (elems, 0..) |el, i| {
        const kv = try self.callValue(cb, &.{ el, .{ .number = @floatFromInt(i) } });
        const key = if (kv == .object and kv.object.is_symbol) kv.object.sym_key else try kv.toString(self.arena);
        if (obj.getOwn(key)) |bucket| {
            try bucket.object.elements.append(self.arena, el);
        } else {
            const arr = try self.newArray();
            try arr.object.elements.append(self.arena, el);
            try self.setProp(obj, key, arr);
        }
    }
    return .{ .object = obj };
}

/// `Map.groupBy(items, callback)` — like Object.groupBy but the result is a Map
/// keyed by the (SameValueZero) callback result, each value an array.
fn mapGroupByFn(ctx: *anyopaque, this: Value, args: []const Value) value.HostError!Value {
    _ = this;
    const self: *Interpreter = @ptrCast(@alignCast(ctx));
    const cb = if (args.len > 1) args[1] else .undefined;
    if (!cb.isCallable()) return self.throwError("TypeError", "Map.groupBy: callback is not a function");
    const elems = try collectIterable(self, if (args.len > 0) args[0] else .undefined);
    const map = (try self.makeMap(.undefined)).object;
    for (elems, 0..) |el, i| {
        const key = try self.callValue(cb, &.{ el, .{ .number = @floatFromInt(i) } });
        if ((try self.mapMethod(map, "has", &.{key})).?.boolean) {
            const bucket = (try self.mapMethod(map, "get", &.{key})).?;
            try bucket.object.elements.append(self.arena, el);
        } else {
            const arr = try self.newArray();
            try arr.object.elements.append(self.arena, el);
            _ = try self.mapMethod(map, "set", &.{ key, arr });
        }
    }
    return .{ .object = map };
}

/// Collect an iterable's elements into a slice: arrays use their dense store
/// directly; anything else is driven through the iterator protocol.
fn collectIterable(self: *Interpreter, v: Value) EvalError![]Value {
    if (v == .object and v.object.is_array) return v.object.elements.items;
    const iter = try self.iteratorOf(v);
    var list: std.ArrayListUnmanaged(Value) = .empty;
    while (true) {
        const r = try self.callMethod(iter, "next", &.{});
        if (r != .object) return self.throwError("TypeError", "iterator.next() did not return an object");
        if ((try self.getProperty(r, "done")).toBoolean()) break;
        try list.append(self.arena, try self.getProperty(r, "value"));
    }
    return list.items;
}

/// One element's settle reaction for `Promise.all`/`allSettled`/`any`: record
/// the outcome at its index and, when the last input settles, settle the
/// combined promise.
fn combineElemFn(ctx: *anyopaque, this: Value, args: []const Value) value.HostError!Value {
    _ = this;
    const self: *Interpreter = @ptrCast(@alignCast(ctx));
    const fnobj = self.active_native orelse return .undefined;
    const e: *promise.Elem = @ptrCast(@alignCast(fnobj.private_data.?));
    // [[AlreadyCalled]]: a resolve/reject element function settles its element at
    // most once; subsequent calls are no-ops.
    if (e.already.*) return .undefined;
    e.already.* = true;
    const c = e.combine;
    const val = if (args.len > 0) args[0] else .undefined;
    switch (c.kind) {
        .all => {
            if (e.is_reject) {
                _ = try self.callValue(c.reject, &.{val}); // first rejection wins
                return .undefined;
            }
            c.values.elements.items[e.index] = val;
        },
        .all_settled => {
            const o = (try self.newObject()).object;
            if (e.is_reject) {
                try self.setProp(o, "status", .{ .string = "rejected" });
                try self.setProp(o, "reason", val);
            } else {
                try self.setProp(o, "status", .{ .string = "fulfilled" });
                try self.setProp(o, "value", val);
            }
            c.values.elements.items[e.index] = .{ .object = o };
        },
        .any => {
            if (!e.is_reject) {
                _ = try self.callValue(c.resolve, &.{val}); // first fulfillment wins
                return .undefined;
            }
            c.values.elements.items[e.index] = val; // collect the error
        },
    }
    c.remaining -= 1;
    if (c.remaining == 0) try combineSettle(self, c);
    return .undefined;
}

/// Settle a combinator once its `remaining` count reaches zero: `all`/
/// `allSettled` fulfill with the values array; `any` rejects with an
/// AggregateError carrying the collected rejection reasons.
fn combineSettle(self: *Interpreter, c: *promise.Combine) value.HostError!void {
    if (c.kind == .any) {
        const agg = try self.makeErrorWithArgs("AggregateError", &.{.{ .object = c.values }});
        _ = try self.callValue(c.reject, &.{agg});
    } else _ = try self.callValue(c.resolve, &.{.{ .object = c.values }});
}

/// IteratorStep + IteratorValue: advance `iter`, returning the next value or
/// null when exhausted. A protocol violation (non-object result) throws.
fn iterStep(self: *Interpreter, iter: Value) EvalError!?Value {
    const r = try self.callMethod(iter, "next", &.{});
    if (r != .object) return self.throwError("TypeError", "iterator.next() did not return an object");
    if ((try self.getProperty(r, "done")).toBoolean()) return null;
    return try self.getProperty(r, "value");
}

/// Shared setup for `Promise.all`/`allSettled`/`any`: build the combined promise
/// and wire a per-element reaction onto each input (coerced via the source's
/// `then`). An empty input settles immediately.
/// A `PromiseCapability` record: the constructed promise plus the resolve/reject
/// functions its executor handed out. Settling the combined promise goes through
/// these functions, so a subclass constructor's promise is the actual result.
const Capability = struct { promise: Value, resolve: Value, reject: Value };

/// Captures the (resolve, reject) pair the executor is invoked with.
const CapCapture = struct { resolve: Value = .undefined, reject: Value = .undefined };

fn capabilityExecutorFn(ctx: *anyopaque, this: Value, args: []const Value) value.HostError!Value {
    _ = this;
    const self: *Interpreter = @ptrCast(@alignCast(ctx));
    const fnobj = self.active_native orelse return .undefined;
    const cap: *CapCapture = @ptrCast(@alignCast(fnobj.private_data.?));
    // GetCapabilitiesExecutor: the executor may be invoked only once — if
    // [[Resolve]] or [[Reject]] is already set, a second call throws.
    if (cap.resolve != .undefined or cap.reject != .undefined)
        return self.throwError("TypeError", "Promise capability executor already invoked");
    cap.resolve = if (args.len > 0) args[0] else .undefined;
    cap.reject = if (args.len > 1) args[1] else .undefined;
    return .undefined;
}

/// `NewPromiseCapability(C)`: construct `new C(executor)`, capturing the resolve
/// and reject functions. Both must be callable. Works for the native `Promise`
/// and for any subclass/custom constructor that forwards to a Promise executor.
fn newPromiseCapability(self: *Interpreter, c: Value) EvalError!Capability {
    if (!isConstructorValue(c)) return self.throwError("TypeError", "NewPromiseCapability called on a non-constructor");
    const capture = try self.arena.create(CapCapture);
    capture.* = .{};
    const executor = try self.arena.create(value.Object);
    executor.* = .{ .native = capabilityExecutorFn, .private_data = @ptrCast(capture) };
    try installNativeProps(self.arena, self.root_shape, executor, "", 2);
    const p = try self.construct(c, &.{.{ .object = executor }});
    if (!capture.resolve.isCallable() or !capture.reject.isCallable())
        return self.throwError("TypeError", "Promise capability resolve/reject is not callable");
    return .{ .promise = p, .resolve = capture.resolve, .reject = capture.reject };
}

/// `GetPromiseResolve(C)` — `Get(C, "resolve")`, which must be callable. The
/// combinators call this once per element (observably, so a replaced
/// `Promise.resolve` is honored), passing `C` as the receiver.
fn getPromiseResolve(self: *Interpreter, c: Value) EvalError!Value {
    const r = try self.getProperty(c, "resolve");
    if (!r.isCallable()) return self.throwError("TypeError", "Promise resolve is not a function");
    return r;
}

/// Resolve one combinator element through the constructor's `resolve` (spec:
/// `Call(promiseResolve, C, « nextValue »)`), yielding a promise to attach to.
fn elementPromise(self: *Interpreter, promise_resolve: Value, c: Value, el: Value) EvalError!*promise.Promise {
    const p = try self.callValueWithThis(promise_resolve, &.{el}, c);
    if (promise.promiseOf(p)) |pp| return pp;
    // A non-promise `resolve` result is adopted into a fresh native promise.
    const wrapped = try promiseResolveValue(self, p);
    return promise.promiseOf(wrapped).?;
}

fn setupCombinator(self: *Interpreter, this: Value, iterable: Value, kind: @TypeOf(@as(promise.Combine, undefined).kind)) value.HostError!Value {
    // NewPromiseCapability(C): C (the `this` value) must be a constructor. This
    // throws synchronously (it is before the IfAbruptRejectPromise region).
    const cap = try newPromiseCapability(self, this);
    // GetPromiseResolve + GetIterator are abrupt-rejected: a failure rejects the
    // returned promise (IfAbruptRejectPromise) rather than throwing out of the call.
    const promise_resolve = getPromiseResolve(self, this) catch |err| return rejectAbrupt(self, cap, err);
    const iter = self.iteratorOf(iterable) catch |err| return rejectAbrupt(self, cap, err);

    const values = (try self.newArray()).object;
    const combine = try self.arena.create(promise.Combine);
    // `remaining` starts at 1 for the loop itself, so a synchronously-settling
    // input can't fire the final settle before the iteration completes; it is
    // decremented once the iterator is exhausted (PerformPromiseAll pattern).
    combine.* = .{ .resolve = cap.resolve, .reject = cap.reject, .values = values, .remaining = 1, .kind = kind };
    var index: usize = 0;
    while (true) {
        // IteratorStep/IteratorValue errors leave the iterator done → reject
        // without closing it.
        const maybe = iterStep(self, iter) catch |err| return rejectAbrupt(self, cap, err);
        const el = maybe orelse break;
        try values.elements.append(self.arena, .undefined);
        combine.remaining += 1;
        // `nextPromise = Call(promiseResolve, C, «el»)` — an abrupt completion
        // here closes the (still-open) iterator before rejecting.
        const next = self.callValueWithThis(promise_resolve, &.{el}, this) catch |err| return closeAndReject(self, cap, iter, err);
        // One [[AlreadyCalled]] record shared by this element's resolve & reject
        // functions — the element settles at most once.
        const already = try self.arena.create(bool);
        already.* = false;
        const f = try self.arena.create(value.Object);
        const fe = try self.arena.create(promise.Elem);
        fe.* = .{ .combine = combine, .index = index, .is_reject = false, .already = already };
        f.* = .{ .native = combineElemFn, .private_data = @ptrCast(fe) };
        try installNativeProps(self.arena, self.root_shape, f, "", 1); // anonymous, length 1
        const r = try self.arena.create(value.Object);
        const re = try self.arena.create(promise.Elem);
        re.* = .{ .combine = combine, .index = index, .is_reject = true, .already = already };
        r.* = .{ .native = combineElemFn, .private_data = @ptrCast(re) };
        try installNativeProps(self.arena, self.root_shape, r, "", 1);
        // Invoke(nextPromise, "then", «resolveElement, rejectElement»): for a
        // native promise this is the native `then`; for a thenable it runs its
        // own `then` (which may settle synchronously).
        _ = self.callMethod(next, "then", &.{ .{ .object = f }, .{ .object = r } }) catch |err| return closeAndReject(self, cap, iter, err);
        index += 1;
    }
    combine.remaining -= 1; // the loop's own count
    if (combine.remaining == 0) try combineSettle(self, combine);
    return cap.promise;
}

/// IfAbruptRejectPromise: a thrown completion rejects the capability and returns
/// its promise; any non-throw (host) error propagates unchanged.
fn rejectAbrupt(self: *Interpreter, cap: Capability, err: value.HostError) value.HostError!Value {
    if (err != error.Throw) return err;
    const reason = self.exception;
    self.exception = .undefined;
    _ = try self.callValue(cap.reject, &.{reason});
    return cap.promise;
}

/// Abrupt completion mid-iteration: close the still-open iterator (its own
/// errors are swallowed — the original completion wins) and reject the result.
fn closeAndReject(self: *Interpreter, cap: Capability, iter: Value, err: value.HostError) value.HostError!Value {
    if (err != error.Throw) return err;
    const reason = self.exception;
    self.exception = .undefined;
    self.iteratorClose(iter) catch {};
    self.exception = .undefined;
    _ = try self.callValue(cap.reject, &.{reason});
    return cap.promise;
}

fn promiseAllFn(ctx: *anyopaque, this: Value, args: []const Value) value.HostError!Value {
    const self: *Interpreter = @ptrCast(@alignCast(ctx));
    return setupCombinator(self, this, if (args.len > 0) args[0] else .undefined, .all);
}

fn promiseAllSettledFn(ctx: *anyopaque, this: Value, args: []const Value) value.HostError!Value {
    const self: *Interpreter = @ptrCast(@alignCast(ctx));
    return setupCombinator(self, this, if (args.len > 0) args[0] else .undefined, .all_settled);
}

fn promiseAnyFn(ctx: *anyopaque, this: Value, args: []const Value) value.HostError!Value {
    const self: *Interpreter = @ptrCast(@alignCast(ctx));
    return setupCombinator(self, this, if (args.len > 0) args[0] else .undefined, .any);
}

/// `Promise.race(iterable)` — settle with the first input to settle.
fn promiseRaceFn(ctx: *anyopaque, this: Value, args: []const Value) value.HostError!Value {
    const self: *Interpreter = @ptrCast(@alignCast(ctx));
    const cap = try newPromiseCapability(self, this);
    const promise_resolve = getPromiseResolve(self, this) catch |err| return rejectAbrupt(self, cap, err);
    const iter = self.iteratorOf(if (args.len > 0) args[0] else .undefined) catch |err| return rejectAbrupt(self, cap, err);
    while (true) {
        const maybe = iterStep(self, iter) catch |err| return rejectAbrupt(self, cap, err);
        const el = maybe orelse break;
        const pp = elementPromise(self, promise_resolve, this, el) catch |err| return closeAndReject(self, cap, iter, err);
        // The capability's resolve/reject settle the result; the first input to
        // fire wins (later settlements are no-ops on an already-settled promise).
        _ = try promise.then(self, pp, cap.resolve, cap.reject);
    }
    return cap.promise;
}

/// `print(...)` — appends a space-joined line to the Context's print buffer
/// (used by the test262 async harness's `$DONE`).
fn printFn(ctx: *anyopaque, this: Value, args: []const Value) value.HostError!Value {
    _ = this;
    const self: *Interpreter = @ptrCast(@alignCast(ctx));
    const buf = self.print_buffer orelse return .undefined;
    for (args, 0..) |a, i| {
        if (i != 0) try buf.append(self.arena, ' ');
        try buf.appendSlice(self.arena, try a.toString(self.arena));
    }
    try buf.append(self.arena, '\n');
    return .undefined;
}

/// `Object.prototype.toString` → `"[object Tag]"`. The tag comes from the
/// object's kind (Array/Function/Error/Date/RegExp/Boolean/Number/String, else
/// "Object"), but an own/inherited `Symbol.toStringTag` *string* overrides it
/// (per spec). Distinct from the kind-specific `toString`s (e.g.
/// `[1,2].toString()` still joins) — this is the one on `Object.prototype`.
/// `Object.prototype.toLocaleString()` — by default just invokes `this.toString()`.
fn objectProtoToLocaleStringFn(ctx: *anyopaque, this: Value, args: []const Value) value.HostError!Value {
    _ = args;
    const self: *Interpreter = @ptrCast(@alignCast(ctx));
    return self.callMethod(this, "toString", &.{});
}

/// Getter for `Object.prototype.__proto__` — `[[GetPrototypeOf]]` of ToObject(this).
fn protoGetterFn(ctx: *anyopaque, this: Value, args: []const Value) value.HostError!Value {
    _ = args;
    const self: *Interpreter = @ptrCast(@alignCast(ctx));
    return switch (this) {
        .object => |o| if (o.proto) |p| .{ .object = p } else .null,
        .undefined, .null => self.throwError("TypeError", "Cannot convert undefined or null to object"),
        else => .null, // primitives box to a wrapper whose proto we don't track here
    };
}

/// Setter for `Object.prototype.__proto__` — sets the prototype to an object or
/// null; any other value is silently ignored (per spec).
fn protoSetterFn(ctx: *anyopaque, this: Value, args: []const Value) value.HostError!Value {
    _ = ctx;
    if (this != .object) return .undefined;
    const v = if (args.len > 0) args[0] else .undefined;
    if (v == .object) this.object.proto = v.object else if (v == .null) this.object.proto = null;
    return .undefined;
}

fn objectProtoToStringFn(ctx: *anyopaque, this: Value, args: []const Value) value.HostError!Value {
    _ = args;
    const self: *Interpreter = @ptrCast(@alignCast(ctx));
    const builtin_tag: []const u8 = switch (this) {
        .undefined => return .{ .string = "[object Undefined]" },
        .null => return .{ .string = "[object Null]" },
        .number => "Number",
        .boolean => "Boolean",
        .string => "String",
        .object => |o| if (o.is_array) "Array" else if (o.is_error) "Error" else if (o.is_date) "Date" else if (o.is_regex) "RegExp" else if (o.prim) |p| (switch (p) {
            .number => "Number",
            .string => "String",
            .boolean => "Boolean",
            else => "Object",
        }) else if (o.isCallableObject()) "Function" else "Object",
    };
    // `Symbol.toStringTag` (a string) wins over the builtin tag.
    var tag = builtin_tag;
    if (this == .object) {
        if (symbolToStringTagKey(self)) |tk| {
            const tv = try self.getProperty(this, tk);
            if (tv == .string) tag = tv.string;
        }
    }
    return .{ .string = try std.mem.concat(self.arena, u8, &.{ "[object ", tag, "]" }) };
}

/// Internal key of the well-known `Symbol.toStringTag`, for `@@toStringTag`.
fn symbolToStringTagKey(self: *Interpreter) ?[]const u8 {
    const sym = self.env.get("Symbol") orelse return null;
    if (sym != .object) return null;
    const tt = sym.object.getOwn("toStringTag") orelse return null;
    if (tt != .object or !tt.object.is_symbol) return null;
    return tt.object.sym_key;
}

/// `Error.isError(v)` — true iff `v` is an object with [[ErrorData]], looking
/// through a Proxy to its target (and false for a revoked proxy).
fn errorIsErrorFn(ctx: *anyopaque, this: Value, args: []const Value) value.HostError!Value {
    _ = ctx;
    _ = this;
    const v = if (args.len > 0) args[0] else .undefined;
    if (v != .object) return .{ .boolean = false };
    var o = v.object;
    while (o.proxy_handler != null) {
        if (o.proxy_target) |t| o = t else break;
    }
    return .{ .boolean = o.is_error };
}

/// `Error.prototype.toString`: `"name: message"`, or just one when the other is
/// empty. Generic — reads `name`/`message` off `this` (so the prototype chain and
/// `.call(errorLike)` both work).
fn errorToStringFn(ctx: *anyopaque, this: Value, args: []const Value) value.HostError!Value {
    _ = args;
    const self: *Interpreter = @ptrCast(@alignCast(ctx));
    if (this != .object) return self.throwError("TypeError", "Error.prototype.toString called on non-object");
    const name_v = try self.getProperty(this, "name");
    const name = if (name_v == .undefined) "Error" else try name_v.toString(self.arena);
    const msg_v = try self.getProperty(this, "message");
    const msg = if (msg_v == .undefined) "" else try msg_v.toString(self.arena);
    if (name.len == 0) return .{ .string = msg };
    if (msg.len == 0) return .{ .string = name };
    return .{ .string = try std.mem.concat(self.arena, u8, &.{ name, ": ", msg }) };
}

/// `Error.prototype.stack` getter (V8-style): a string for a receiver that has
/// `[[ErrorData]]` (an Error instance), otherwise undefined. The trace content
/// is implementation-defined; we return `"name: message"`.
fn errorStackGet(ctx: *anyopaque, this: Value, args: []const Value) value.HostError!Value {
    _ = args;
    _ = ctx;
    if (this != .object or !this.object.is_error) return .undefined;
    // Implementation-defined trace string. Read the class name directly off
    // `[[ErrorData]]` rather than via [[Get]], so a hostile/recursive receiver
    // (proxy traps, getters) can't re-enter and blow the stack.
    const name = this.object.error_name;
    return .{ .string = if (name.len == 0) "Error" else name };
}

/// `Error.prototype.stack` setter — SetterThatIgnoresPrototypeProperties(this,
/// %Error.prototype%, "stack", v): a TypeError if `this` is not an Object or `v`
/// is not a String, a TypeError if `this` is the home object (%Error.prototype%),
/// otherwise an own { writable, enumerable, configurable } data property `stack`
/// is created on the receiver (any object, no [[ErrorData]] check), shadowing the
/// accessor. The home pointer is the setter's `private_data`.
fn errorStackSet(ctx: *anyopaque, this: Value, args: []const Value) value.HostError!Value {
    const self: *Interpreter = @ptrCast(@alignCast(ctx));
    if (this != .object)
        return self.throwError("TypeError", "Error.prototype.stack setter called on a non-object");
    const v = if (args.len > 0) args[0] else .undefined;
    if (v != .string)
        return self.throwError("TypeError", "Error.prototype.stack setter requires a string value");
    // Assignment to the home object itself (%Error.prototype%) throws, mirroring
    // a write to a non-writable own data property in strict mode.
    if (self.active_native) |nat| {
        if (nat.private_data) |hd| {
            const home: *value.Object = @ptrCast(@alignCast(hd));
            if (this.object == home)
                return self.throwError("TypeError", "Error.prototype.stack setter called on %Error.prototype%");
        }
    }
    const o = this.object;
    // Define an *own* data property directly (CreateDataProperty), NOT via
    // [[Set]] — going through setProp would re-find this very setter on the
    // prototype and recurse infinitely. A fresh property is writable/enumerable/
    // configurable; an existing own one just takes the new value.
    const had_own = o.getOwn("stack") != null;
    try o.setOwn(self.arena, self.root_shape, "stack", v);
    if (!had_own)
        try o.setAttr(self.arena, "stack", .{ .enumerable = true, .configurable = true, .writable = true });
    return .undefined;
}

/// Give `proto` a `constructor` own property pointing back to `ctor`
/// (non-enumerable, writable, configurable — the spec default for built-ins).
fn setConstructor(a: std.mem.Allocator, rs: *Shape, proto: *value.Object, ctor: *value.Object) EvalError!void {
    try proto.setOwn(a, rs, "constructor", .{ .object = ctor });
    try proto.setAttr(a, "constructor", .{ .enumerable = false, .configurable = true, .writable = true });
}

/// `Boolean.prototype.toString` / `valueOf` for a primitive boolean `this`.
fn booleanProtoFn(comptime to_string: bool) value.NativeFn {
    return struct {
        fn call(ctx: *anyopaque, this: Value, args: []const Value) value.HostError!Value {
            _ = args;
            const self: *Interpreter = @ptrCast(@alignCast(ctx));
            const b: bool = switch (this) {
                .boolean => |x| x,
                // A Boolean wrapper object (`new Boolean(x)`) unwraps to its boxed value.
                .object => |o| if (o.prim != null and o.prim.? == .boolean) o.prim.?.boolean else return self.throwError("TypeError", "Boolean.prototype method requires that 'this' be a Boolean"),
                else => return self.throwError("TypeError", "Boolean.prototype method requires that 'this' be a Boolean"),
            };
            return if (to_string) .{ .string = if (b) "true" else "false" } else .{ .boolean = b };
        }
    }.call;
}

/// `Symbol.prototype.toString` → `"Symbol(description)"`. Requires a Symbol `this`.
fn symbolToStringFn(ctx: *anyopaque, this: Value, args: []const Value) value.HostError!Value {
    _ = args;
    const self: *Interpreter = @ptrCast(@alignCast(ctx));
    const sym = try thisSymbol(self, this, "Symbol.prototype.toString");
    const ds = sym.sym_desc orelse "";
    return .{ .string = try std.mem.concat(self.arena, u8, &.{ "Symbol(", ds, ")" }) };
}

/// `Symbol.prototype.valueOf` → the Symbol itself. Requires a Symbol `this`.
fn symbolValueOfFn(ctx: *anyopaque, this: Value, args: []const Value) value.HostError!Value {
    _ = args;
    const self: *Interpreter = @ptrCast(@alignCast(ctx));
    _ = try thisSymbol(self, this, "Symbol.prototype.valueOf");
    return symbolThisValue(this);
}

/// `get Symbol.prototype.description` → the symbol's `[[Description]]` (a string
/// or `undefined`). Accepts a Symbol or a boxed Symbol wrapper as `this`.
fn symbolDescriptionGetFn(ctx: *anyopaque, this: Value, args: []const Value) value.HostError!Value {
    _ = args;
    const self: *Interpreter = @ptrCast(@alignCast(ctx));
    const sym = try thisSymbol(self, this, "Symbol.prototype.description");
    return if (sym.sym_desc) |d| .{ .string = d } else .undefined;
}

/// `Symbol.prototype[@@toPrimitive]` → the symbol itself (any hint). Lets
/// `String(sym)`/`` `${sym}` `` route through it (and still throw on string
/// coercion via the normal ToString path, not here).
fn symbolToPrimitiveFn(ctx: *anyopaque, this: Value, args: []const Value) value.HostError!Value {
    _ = args;
    const self: *Interpreter = @ptrCast(@alignCast(ctx));
    _ = try thisSymbol(self, this, "Symbol.prototype[Symbol.toPrimitive]");
    return symbolThisValue(this);
}

/// The underlying Symbol value of `this` — the symbol itself, or the boxed
/// symbol of an `Object(sym)` wrapper.
fn symbolThisValue(this: Value) Value {
    if (this == .object) {
        if (this.object.is_symbol) return this;
        if (this.object.prim) |p| return p;
    }
    return this;
}

/// Brand-check helper: returns the Symbol object backing `this` (unwrapping an
/// `Object(sym)` wrapper), else throws a TypeError naming `method`.
fn thisSymbol(self: *Interpreter, this: Value, method: []const u8) EvalError!*value.Object {
    if (this == .object) {
        if (this.object.is_symbol) return this.object;
        if (this.object.prim) |p| {
            if (p == .object and p.object.is_symbol) return p.object;
        }
    }
    return self.throwError("TypeError", try std.fmt.allocPrint(self.arena, "{s} requires that 'this' be a Symbol", .{method}));
}

// ---- Proxy / Reflect natives ----------------------------------------------

fn proxyConstructorFn(ctx: *anyopaque, this: Value, args: []const Value) value.HostError!Value {
    _ = this;
    const self: *Interpreter = @ptrCast(@alignCast(ctx));
    if (self.new_target == .undefined)
        return self.throwError("TypeError", "Constructor Proxy requires 'new'");
    const target = if (args.len > 0) args[0] else .undefined;
    const handler = if (args.len > 1) args[1] else .undefined;
    if (target != .object or handler != .object)
        return self.throwError("TypeError", "Cannot create proxy with a non-object as target or handler");
    const o = try self.arena.create(value.Object);
    o.* = .{ .proxy_target = target.object, .proxy_handler = handler.object };
    return .{ .object = o };
}

/// `Proxy.revocable(target, handler)` → `{ proxy, revoke }`.
fn proxyRevocableFn(ctx: *anyopaque, this: Value, args: []const Value) value.HostError!Value {
    _ = this;
    const self: *Interpreter = @ptrCast(@alignCast(ctx));
    const saved_nt = self.new_target;
    self.new_target = .undefined; // proxyConstructorFn requires new; emulate it
    defer self.new_target = saved_nt;
    const target = if (args.len > 0) args[0] else .undefined;
    const handler = if (args.len > 1) args[1] else .undefined;
    if (target != .object or handler != .object)
        return self.throwError("TypeError", "Cannot create proxy with a non-object as target or handler");
    const p = try self.arena.create(value.Object);
    p.* = .{ .proxy_target = target.object, .proxy_handler = handler.object };
    const revoke = try self.arena.create(value.Object);
    revoke.* = .{ .native = proxyRevokeFn, .private_data = @ptrCast(p) };
    const result = (try self.newObject()).object;
    try self.setProp(result, "proxy", .{ .object = p });
    try self.setProp(result, "revoke", .{ .object = revoke });
    return .{ .object = result };
}

fn proxyRevokeFn(ctx: *anyopaque, this: Value, args: []const Value) value.HostError!Value {
    _ = this;
    _ = args;
    const self: *Interpreter = @ptrCast(@alignCast(ctx));
    if (self.active_native) |nf| {
        if (nf.private_data) |pd| {
            const p: *value.Object = @ptrCast(@alignCast(pd));
            p.proxy_revoked = true;
            p.proxy_target = null;
            p.proxy_handler = null;
        }
    }
    return .undefined;
}

fn reflectGetFn(ctx: *anyopaque, this: Value, args: []const Value) value.HostError!Value {
    _ = this;
    const self: *Interpreter = @ptrCast(@alignCast(ctx));
    const target = if (args.len > 0) args[0] else .undefined;
    if (target != .object) return self.throwError("TypeError", "Reflect.get called on non-object");
    return self.getProperty(target, try self.keyOf(if (args.len > 1) args[1] else .undefined));
}

fn reflectSetFn(ctx: *anyopaque, this: Value, args: []const Value) value.HostError!Value {
    _ = this;
    const self: *Interpreter = @ptrCast(@alignCast(ctx));
    const target = if (args.len > 0) args[0] else .undefined;
    if (target != .object) return self.throwError("TypeError", "Reflect.set called on non-object");
    try self.setMember(target, try self.keyOf(if (args.len > 1) args[1] else .undefined), if (args.len > 2) args[2] else .undefined);
    return .{ .boolean = true };
}

fn reflectHasFn(ctx: *anyopaque, this: Value, args: []const Value) value.HostError!Value {
    _ = this;
    const self: *Interpreter = @ptrCast(@alignCast(ctx));
    const target = if (args.len > 0) args[0] else .undefined;
    if (target != .object) return self.throwError("TypeError", "Reflect.has called on non-object");
    return .{ .boolean = try self.inOperator(if (args.len > 1) args[1] else .undefined, target) };
}

fn reflectDeleteFn(ctx: *anyopaque, this: Value, args: []const Value) value.HostError!Value {
    _ = this;
    const self: *Interpreter = @ptrCast(@alignCast(ctx));
    const target = if (args.len > 0) args[0] else .undefined;
    if (target != .object) return self.throwError("TypeError", "Reflect.deleteProperty called on non-object");
    return .{ .boolean = try self.deleteOwn(target.object, try self.keyOf(if (args.len > 1) args[1] else .undefined)) };
}

fn reflectOwnKeysFn(ctx: *anyopaque, this: Value, args: []const Value) value.HostError!Value {
    _ = this;
    const self: *Interpreter = @ptrCast(@alignCast(ctx));
    const target = if (args.len > 0) args[0] else .undefined;
    if (target != .object) return self.throwError("TypeError", "Reflect.ownKeys called on non-object");
    const keys = if (target.object.proxy_handler != null) try self.proxyOwnKeys(target.object) else try target.object.ownKeys(self.arena);
    const arr = try self.newArray();
    for (keys) |k| try arr.object.elements.append(self.arena, self.keyToValue(k));
    return arr;
}

fn reflectGetProtoFn(ctx: *anyopaque, this: Value, args: []const Value) value.HostError!Value {
    _ = this;
    const self: *Interpreter = @ptrCast(@alignCast(ctx));
    const target = if (args.len > 0) args[0] else .undefined;
    if (target != .object) return self.throwError("TypeError", "Reflect.getPrototypeOf called on non-object");
    return if (target.object.proto) |p| .{ .object = p } else .null;
}

fn reflectApplyFn(ctx: *anyopaque, this: Value, args: []const Value) value.HostError!Value {
    _ = this;
    const self: *Interpreter = @ptrCast(@alignCast(ctx));
    const target = if (args.len > 0) args[0] else .undefined;
    const this_arg = if (args.len > 1) args[1] else .undefined;
    const list: []const Value = if (args.len > 2 and args[2] == .object and args[2].object.is_array) args[2].object.elements.items else &.{};
    return self.callValueWithThis(target, list, this_arg);
}

fn reflectConstructFn(ctx: *anyopaque, this: Value, args: []const Value) value.HostError!Value {
    _ = this;
    const self: *Interpreter = @ptrCast(@alignCast(ctx));
    const target = if (args.len > 0) args[0] else .undefined;
    if (!isConstructorValue(target)) return self.throwError("TypeError", "Reflect.construct target is not a constructor");
    // A new.target (3rd arg) must itself be a constructor — this is what the
    // `isConstructor` harness probes via `Reflect.construct(fn, [], target)`.
    if (args.len > 2 and !isConstructorValue(args[2]))
        return self.throwError("TypeError", "Reflect.construct newTarget is not a constructor");
    const list: []const Value = if (args.len > 1 and args[1] == .object and args[1].object.is_array) args[1].object.elements.items else &.{};
    return self.construct(target, list);
}

/// Best-effort [[Construct]]-ability test: a native flagged `native_ctor`, an
/// error constructor, a non-arrow/non-generator/non-async JS function, a bound
/// function over a constructor, or a proxy whose target is a constructor.
fn isConstructorValue(v: Value) bool {
    if (v != .object) return false;
    const o = v.object;
    if (o.proxy_handler != null) return if (o.proxy_target) |t| isConstructorValue(.{ .object = t }) else false;
    if (o.bound) |erased| {
        const bf: *Interpreter.BoundFn = @ptrCast(@alignCast(erased));
        return isConstructorValue(bf.target);
    }
    if (o.error_ctor != null) return true;
    if (o.native != null) return o.native_ctor;
    if (o.js_func) |erased| {
        const f: *Function = @ptrCast(@alignCast(erased));
        return !f.is_arrow and !f.is_async and !f.is_generator;
    }
    return false;
}

/// Install the engine's global bindings into `env`: the `Error`-family
/// constructors, `NaN`/`Infinity`/`undefined`, the `Math` and `Object`/`Array`
/// namespaces, and the common global functions. `root_shape` backs the property
/// stores of the namespace objects. Called once per Context, before user code.
fn eq(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

/// Mirror a global environment's bindings onto its global object as own
/// properties (matching `Context.create`), so `globalThis.X` / reflection work.
pub fn mirrorGlobalsOnto(env: *Environment, gobj: *value.Object, rs: *Shape) EvalError!void {
    var it = env.vars.iterator();
    while (it.next()) |e| {
        const name = e.key_ptr.*;
        if (gobj.getOwn(name) != null) continue;
        try gobj.setOwn(env.arena, rs, name, e.value_ptr.*);
        const frozen = eq(name, "undefined") or eq(name, "NaN") or eq(name, "Infinity");
        try gobj.setAttr(env.arena, name, if (frozen)
            .{ .writable = false, .enumerable = false, .configurable = false }
        else
            .{ .writable = true, .enumerable = false, .configurable = true });
    }
}

/// `$262.gc()` — a no-op (the engine uses an arena, no explicit GC).
fn host262GcFn(ctx: *anyopaque, this: Value, args: []const Value) value.HostError!Value {
    _ = ctx;
    _ = this;
    _ = args;
    return .undefined;
}

/// `$262.detachArrayBuffer(buffer)` — detach an ArrayBuffer's backing store.
fn host262DetachFn(ctx: *anyopaque, this: Value, args: []const Value) value.HostError!Value {
    _ = this;
    _ = ctx;
    const v = if (args.len > 0) args[0] else Value.undefined;
    if (v == .object) if (v.object.array_buffer) |ab| {
        ab.detached = true;
    };
    return .undefined;
}

/// `$262.evalScript(src)` / a realm's evalScript — parse + evaluate `src` as a
/// global script in the realm captured in this native's `private_data`.
fn host262EvalScriptFn(ctx: *anyopaque, this: Value, args: []const Value) value.HostError!Value {
    _ = this;
    const self: *Interpreter = @ptrCast(@alignCast(ctx));
    const fnobj = self.active_native orelse return .undefined;
    const genv: *Environment = @ptrCast(@alignCast(fnobj.private_data orelse return .undefined));
    if (args.len == 0 or args[0] != .string) return if (args.len > 0) args[0] else .undefined;
    var parser = Parser.init(self.arena, args[0].string) catch return self.throwError("SyntaxError", "evalScript: invalid source");
    const prog = parser.parseProgram() catch return self.throwError("SyntaxError", "evalScript: parse error");
    const gobj: ?*value.Object = if (genv.get("globalThis")) |g| (if (g == .object) g.object else null) else null;
    const s_env = self.env;
    const s_this = self.this_value;
    const s_glob = self.global_object;
    self.env = genv;
    if (gobj) |go| {
        self.this_value = .{ .object = go };
        self.global_object = go;
    }
    defer {
        self.env = s_env;
        self.this_value = s_this;
        self.global_object = s_glob;
    }
    return self.eval(prog);
}

/// `$262.createRealm()` — a fresh realm (its own global environment, intrinsics,
/// and global object), returned as `{ global, evalScript }`.
fn host262CreateRealmFn(ctx: *anyopaque, this: Value, args: []const Value) value.HostError!Value {
    _ = this;
    _ = args;
    const self: *Interpreter = @ptrCast(@alignCast(ctx));
    const a = self.arena;
    const genv = try a.create(Environment);
    genv.* = .{ .arena = a, .fn_scope = true };
    const gobj = try a.create(value.Object);
    gobj.* = .{};
    // Share the creating realm's well-known symbols with the new realm.
    const parent_symbol: ?*value.Object = if (self.env.get("Symbol")) |sv| (if (sv == .object) sv.object else null) else null;
    try installGlobalsInner(genv, self.root_shape, parent_symbol);
    try genv.put("globalThis", .{ .object = gobj });
    try mirrorGlobalsOnto(genv, gobj, self.root_shape);
    // Point the new realm's own `$262.global` at its global object.
    if (genv.get("$262")) |d| {
        if (d == .object) try self.setProp(d.object, "global", .{ .object = gobj });
    }
    // The realm record handed back to the caller (in the caller's realm).
    const realm = (try self.newObject()).object;
    try self.setProp(realm, "global", .{ .object = gobj });
    const es = try a.create(value.Object);
    es.* = .{ .native = host262EvalScriptFn, .private_data = @ptrCast(genv) };
    try installNativeProps(a, self.root_shape, es, "evalScript", 1);
    try self.setProp(realm, "evalScript", .{ .object = es });
    return .{ .object = realm };
}

/// Install the test262 `$262` host object into `env` (its `global` is wired up
/// by the caller once the realm's global object exists).
pub fn install262(env: *Environment, rs: *Shape, object_proto: *value.Object) EvalError!void {
    const a = env.arena;
    const d = try a.create(value.Object);
    d.* = .{ .proto = object_proto };
    try setNative(a, rs, d, "gc", 0, host262GcFn);
    try setNative(a, rs, d, "detachArrayBuffer", 1, host262DetachFn);
    try setNative(a, rs, d, "createRealm", 0, host262CreateRealmFn);
    const es = try a.create(value.Object);
    es.* = .{ .native = host262EvalScriptFn, .private_data = @ptrCast(env) };
    try installNativeProps(a, rs, es, "evalScript", 1);
    try d.setOwn(a, rs, "evalScript", .{ .object = es });
    try env.put("$262", .{ .object = d });
}

/// Render an `i128` in `radix` (2..36).
fn formatBigIntRadix(arena: std.mem.Allocator, val: i128, radix: u8) error{OutOfMemory}![]const u8 {
    if (val == 0) return "0";
    var buf: [200]u8 = undefined;
    var i: usize = buf.len;
    const neg = val < 0;
    // Magnitude in u128 (bitcast handles i128 minInt without overflow on negate).
    var v: u128 = if (neg) @as(u128, @bitCast(-%val)) else @intCast(val);
    const digits = "0123456789abcdefghijklmnopqrstuvwxyz";
    while (v > 0) {
        i -= 1;
        buf[i] = digits[@intCast(v % radix)];
        v /= radix;
    }
    if (neg) {
        i -= 1;
        buf[i] = '-';
    }
    return arena.dupe(u8, buf[i..]);
}

/// `BigInt(value)` — NumberToBigInt for an integral Number, else ToBigInt; not a
/// constructor. ToPrimitive(number) is applied to an object argument first
/// (handled inside `toBigIntValueImpl`).
fn bigIntFn(ctx: *anyopaque, this: Value, args: []const Value) value.HostError!Value {
    _ = this;
    const self: *Interpreter = @ptrCast(@alignCast(ctx));
    if (self.new_target != .undefined) return self.throwError("TypeError", "BigInt is not a constructor");
    return self.toBigIntValueImpl(if (args.len > 0) args[0] else .undefined, true);
}

fn bigIntToLocaleStringFn(ctx: *anyopaque, this: Value, args: []const Value) value.HostError!Value {
    _ = args;
    const self: *Interpreter = @ptrCast(@alignCast(ctx));
    const big: i128 = if (this == .object and this.object.is_bigint) this.object.bigint else if (this == .object and this.object.prim != null and this.object.prim.? == .object and this.object.prim.?.object.is_bigint) this.object.prim.?.object.bigint else return self.throwError("TypeError", "BigInt.prototype.toLocaleString requires that 'this' be a BigInt");
    return .{ .string = try formatBigIntRadix(self.arena, big, 10) };
}

/// `BigInt.prototype.toString(radix)` — the BigInt rendered in `radix` (2..36).
fn bigIntToStringFn(ctx: *anyopaque, this: Value, args: []const Value) value.HostError!Value {
    const self: *Interpreter = @ptrCast(@alignCast(ctx));
    const big: i128 = if (this == .object and this.object.is_bigint) this.object.bigint else if (this == .object and this.object.prim != null and this.object.prim.? == .object and this.object.prim.?.object.is_bigint) this.object.prim.?.object.bigint else return self.throwError("TypeError", "BigInt.prototype.toString requires that 'this' be a BigInt");
    const radix: u8 = if (args.len > 0 and args[0] != .undefined) @intFromFloat(@trunc(try self.toNumberV(args[0]))) else 10;
    if (radix < 2 or radix > 36) return self.throwError("RangeError", "toString() radix must be between 2 and 36");
    return .{ .string = try formatBigIntRadix(self.arena, big, radix) };
}

fn bigIntValueOfFn(ctx: *anyopaque, this: Value, args: []const Value) value.HostError!Value {
    _ = args;
    const self: *Interpreter = @ptrCast(@alignCast(ctx));
    if (this == .object and this.object.is_bigint) return this;
    // A BigInt wrapper object (`Object(1n)`) unwraps to its boxed BigInt.
    if (this == .object and this.object.prim != null and this.object.prim.? == .object and this.object.prim.?.object.is_bigint) return this.object.prim.?;
    return self.throwError("TypeError", "BigInt.prototype.valueOf requires that 'this' be a BigInt");
}

/// `BigInt.asIntN(bits, x)` / `asUintN(bits, x)` — wrap into a 2's-complement
/// signed / unsigned `bits`-bit integer.
fn bigIntAsIntNFn(comptime signed: bool) value.NativeFn {
    return struct {
        fn call(ctx: *anyopaque, this: Value, args: []const Value) value.HostError!Value {
            _ = this;
            const self: *Interpreter = @ptrCast(@alignCast(ctx));
            // ToIndex(bits) first (the Number coercion runs valueOf and rejects a
            // Symbol/BigInt), then ToBigInt(x) (which rejects a Number) — matching
            // the spec's step order.
            const bits_f = if (args.len > 0) try self.toNumberV(args[0]) else 0;
            const bits_int = if (std.math.isNan(bits_f)) 0 else @trunc(bits_f);
            if (bits_int < 0 or bits_int > 9007199254740991.0) return self.throwError("RangeError", "BigInt.asIntN bit count is out of range");
            const bits_count: u64 = @intFromFloat(bits_int);
            const xv = try self.toBigIntValueImpl(if (args.len > 1) args[1] else .undefined, false);
            const x = xv.object.bigint;
            if (bits_count == 0) return self.makeBigInt(if (signed) 0 else 0);
            // For a field at least as wide as the i128 storage, a signed result is
            // x unchanged and a non-negative unsigned result is x unchanged (a
            // negative value in a ≥128-bit unsigned field exceeds i128 and isn't
            // modeled).
            if (bits_count >= 128) return self.makeBigInt(x);
            const bits: u7 = @intCast(bits_count);
            const mask: u128 = (@as(u128, 1) << bits) - 1;
            var m: u128 = @as(u128, @bitCast(x)) & mask; // low `bits` bits = x mod 2^bits
            if (signed and (m & (@as(u128, 1) << (bits - 1))) != 0) {
                m |= ~mask; // sign-extend the high bits → a negative i128
            }
            return self.makeBigInt(@bitCast(m));
        }
    }.call;
}

// ===== DataView =====================================================

/// ToIndex(v): ToIntegerOrInfinity, then RangeError outside [0, 2^53-1]. The
/// Number coercion runs valueOf/toString (so a Symbol/BigInt throws), matching
/// the spec's argument-coercion order.
fn toIndexArg(self: *Interpreter, v: Value) EvalError!u64 {
    if (v == .undefined) return 0;
    const n = try self.toNumberV(v);
    const i = if (std.math.isNan(n)) 0 else @trunc(n);
    if (i < 0 or i > 9007199254740991.0) return self.throwError("RangeError", "index out of range");
    return @intFromFloat(i);
}

const DVType = struct { name: []const u8, bytes: u8, signed: bool, float: bool, big: bool };
const dv_types = [_]DVType{
    .{ .name = "Int8", .bytes = 1, .signed = true, .float = false, .big = false },
    .{ .name = "Uint8", .bytes = 1, .signed = false, .float = false, .big = false },
    .{ .name = "Int16", .bytes = 2, .signed = true, .float = false, .big = false },
    .{ .name = "Uint16", .bytes = 2, .signed = false, .float = false, .big = false },
    .{ .name = "Int32", .bytes = 4, .signed = true, .float = false, .big = false },
    .{ .name = "Uint32", .bytes = 4, .signed = false, .float = false, .big = false },
    .{ .name = "Float32", .bytes = 4, .signed = true, .float = true, .big = false },
    .{ .name = "Float64", .bytes = 8, .signed = true, .float = true, .big = false },
    .{ .name = "BigInt64", .bytes = 8, .signed = true, .float = false, .big = true },
    .{ .name = "BigUint64", .bytes = 8, .signed = false, .float = false, .big = true },
};

/// `new DataView(buffer, byteOffset?, byteLength?)`.
fn dataViewConstructorFn(ctx: *anyopaque, this: Value, args: []const Value) value.HostError!Value {
    _ = this;
    const self: *Interpreter = @ptrCast(@alignCast(ctx));
    if (self.new_target == .undefined) return self.throwError("TypeError", "Constructor DataView requires 'new'");
    const buf_v = if (args.len > 0) args[0] else .undefined;
    if (buf_v != .object or buf_v.object.array_buffer == null) return self.throwError("TypeError", "First argument to DataView must be an ArrayBuffer");
    const ab = buf_v.object.array_buffer.?;
    const offset = try toIndexArg(self, if (args.len > 1) args[1] else .undefined);
    if (ab.detached) return self.throwError("TypeError", "ArrayBuffer is detached");
    const buf_len = ab.data.len;
    if (offset > buf_len) return self.throwError("RangeError", "Start offset is outside the bounds of the buffer");
    var view_len: usize = buf_len - @as(usize, @intCast(offset));
    if (args.len > 2 and args[2] != .undefined) {
        const vl = try toIndexArg(self, args[2]);
        if (@as(u64, @intCast(offset)) + vl > buf_len) return self.throwError("RangeError", "Invalid DataView length");
        view_len = @intCast(vl);
    }
    // The detached re-check after ToIndex coercions is spec'd (a side-effecting
    // length argument could detach the buffer).
    if (ab.detached) return self.throwError("TypeError", "ArrayBuffer is detached");
    const o = (try self.newObject()).object;
    if (self.new_target == .object and self.new_target.object.getOwn("prototype") != null and self.new_target.object.getOwn("prototype").? == .object) {
        o.proto = self.new_target.object.getOwn("prototype").?.object;
    } else if (self.env.get("DataView")) |c| {
        if (c == .object) o.proto = try self.protoObject(c.object);
    }
    const dv = try self.arena.create(value.DataViewData);
    dv.* = .{ .buffer = buf_v.object, .byte_offset = @intCast(offset), .byte_length = view_len };
    o.data_view = dv;
    return .{ .object = o };
}

/// A `DataView.prototype.get<Type>(byteOffset, littleEndian)` accessor.
fn dataViewGetFn(comptime t: DVType) value.NativeFn {
    return struct {
        fn call(ctx: *anyopaque, this: Value, args: []const Value) value.HostError!Value {
            const self: *Interpreter = @ptrCast(@alignCast(ctx));
            if (this != .object or this.object.data_view == null) return self.throwError("TypeError", "DataView.prototype.get" ++ t.name ++ " requires a DataView receiver");
            const dv = this.object.data_view.?;
            const get_index = try toIndexArg(self, if (args.len > 0) args[0] else .undefined);
            const little = if (args.len > 1) args[1].toBoolean() else false;
            const ab = dv.buffer.array_buffer.?;
            if (ab.detached) return self.throwError("TypeError", "ArrayBuffer is detached");
            if (get_index + t.bytes > dv.byte_length) return self.throwError("RangeError", "Offset is outside the bounds of the DataView");
            const off = dv.byte_offset + @as(usize, @intCast(get_index));
            const endian: std.builtin.Endian = if (little) .little else .big;
            const UInt = switch (t.bytes) {
                1 => u8,
                2 => u16,
                4 => u32,
                else => u64,
            };
            const raw = std.mem.readInt(UInt, ab.data[off..][0..t.bytes], endian);
            if (t.big) {
                if (t.signed) return self.makeBigInt(@as(i64, @bitCast(@as(u64, raw))));
                return self.makeBigInt(@as(i128, @as(u64, raw)));
            }
            if (t.float) {
                if (t.bytes == 4) return .{ .number = @floatCast(@as(f32, @bitCast(@as(u32, raw)))) };
                return .{ .number = @bitCast(@as(u64, raw)) };
            }
            if (t.signed) {
                const SInt = switch (t.bytes) {
                    1 => i8,
                    2 => i16,
                    4 => i32,
                    else => i64,
                };
                return .{ .number = @floatFromInt(@as(SInt, @bitCast(raw))) };
            }
            return .{ .number = @floatFromInt(raw) };
        }
    }.call;
}

/// A `DataView.prototype.set<Type>(byteOffset, value, littleEndian)` mutator.
fn dataViewSetFn(comptime t: DVType) value.NativeFn {
    return struct {
        fn call(ctx: *anyopaque, this: Value, args: []const Value) value.HostError!Value {
            const self: *Interpreter = @ptrCast(@alignCast(ctx));
            if (this != .object or this.object.data_view == null) return self.throwError("TypeError", "DataView.prototype.set" ++ t.name ++ " requires a DataView receiver");
            const dv = this.object.data_view.?;
            const get_index = try toIndexArg(self, if (args.len > 0) args[0] else .undefined);
            const val = if (args.len > 1) args[1] else .undefined;
            // Coerce the value (ToBigInt for the Big types, else ToNumber) before
            // the bounds/detach check, per SetViewValue.
            var num: f64 = 0;
            var big: i128 = 0;
            if (t.big) {
                const bv = try self.toBigIntValueImpl(val, false);
                big = bv.object.bigint;
            } else {
                num = try self.toNumberV(val);
            }
            const little = if (args.len > 2) args[2].toBoolean() else false;
            const ab = dv.buffer.array_buffer.?;
            if (ab.detached) return self.throwError("TypeError", "ArrayBuffer is detached");
            if (get_index + t.bytes > dv.byte_length) return self.throwError("RangeError", "Offset is outside the bounds of the DataView");
            const off = dv.byte_offset + @as(usize, @intCast(get_index));
            const endian: std.builtin.Endian = if (little) .little else .big;
            const UInt = switch (t.bytes) {
                1 => u8,
                2 => u16,
                4 => u32,
                else => u64,
            };
            var raw: UInt = undefined;
            if (t.big) {
                raw = @truncate(@as(u128, @bitCast(big))); // low `bytes*8` bits (two's complement)
            } else if (t.float) {
                if (t.bytes == 4) {
                    raw = @bitCast(@as(f32, @floatCast(num)));
                } else {
                    raw = @bitCast(num);
                }
            } else {
                raw = numToRaw(UInt, num);
            }
            std.mem.writeInt(UInt, ab.data[off..][0..t.bytes], raw, endian);
            return .undefined;
        }
    }.call;
}

/// ToIntXX/ToUintXX truncation for a DataView integer store (NaN/±Inf → 0, wrap
/// modulo 2^bits), returning the raw unsigned bit pattern.
fn numToRaw(comptime UInt: type, num: f64) UInt {
    if (std.math.isNan(num) or std.math.isInf(num)) return 0;
    const bits = @bitSizeOf(UInt);
    const two_pow: f64 = std.math.pow(f64, 2, @floatFromInt(bits));
    var m = @mod(@trunc(num), two_pow);
    if (m < 0) m += two_pow;
    return @intFromFloat(m);
}

fn dataViewBufferGetter(ctx: *anyopaque, this: Value, args: []const Value) value.HostError!Value {
    _ = args;
    const self: *Interpreter = @ptrCast(@alignCast(ctx));
    if (this != .object or this.object.data_view == null) return self.throwError("TypeError", "DataView.prototype.buffer requires a DataView receiver");
    return .{ .object = this.object.data_view.?.buffer };
}

fn dataViewByteLengthGetter(ctx: *anyopaque, this: Value, args: []const Value) value.HostError!Value {
    _ = args;
    const self: *Interpreter = @ptrCast(@alignCast(ctx));
    if (this != .object or this.object.data_view == null) return self.throwError("TypeError", "DataView.prototype.byteLength requires a DataView receiver");
    const dv = this.object.data_view.?;
    if (dv.buffer.array_buffer.?.detached) return self.throwError("TypeError", "ArrayBuffer is detached");
    return .{ .number = @floatFromInt(dv.byte_length) };
}

fn dataViewByteOffsetGetter(ctx: *anyopaque, this: Value, args: []const Value) value.HostError!Value {
    _ = args;
    const self: *Interpreter = @ptrCast(@alignCast(ctx));
    if (this != .object or this.object.data_view == null) return self.throwError("TypeError", "DataView.prototype.byteOffset requires a DataView receiver");
    const dv = this.object.data_view.?;
    if (dv.buffer.array_buffer.?.detached) return self.throwError("TypeError", "ArrayBuffer is detached");
    return .{ .number = @floatFromInt(dv.byte_offset) };
}

/// Install `DataView` (constructor + prototype get/set accessors and methods).
fn installDataView(env: *Environment, rs: *Shape, object_proto: *value.Object) EvalError!void {
    const a = env.arena;
    const proto = try a.create(value.Object);
    proto.* = .{ .proto = object_proto };
    inline for (dv_types) |t| {
        try setNative(a, rs, proto, "get" ++ t.name, 1, dataViewGetFn(t));
        try setNative(a, rs, proto, "set" ++ t.name, 2, dataViewSetFn(t));
    }
    try setNativeGetter(a, rs, proto, "buffer", dataViewBufferGetter);
    try setNativeGetter(a, rs, proto, "byteLength", dataViewByteLengthGetter);
    try setNativeGetter(a, rs, proto, "byteOffset", dataViewByteOffsetGetter);
    // DataView.prototype[Symbol.toStringTag] = "DataView" {configurable}.
    if (env.get("Symbol")) |sym| if (sym == .object) {
        if (sym.object.getOwn("toStringTag")) |tt| if (tt == .object and tt.object.is_symbol) {
            try proto.setOwn(a, rs, tt.object.sym_key, .{ .string = "DataView" });
            try proto.setAttr(a, tt.object.sym_key, .{ .writable = false, .enumerable = false, .configurable = true });
        };
    };
    const ctor = try a.create(value.Object);
    ctor.* = .{ .native = dataViewConstructorFn, .native_ctor = true };
    try installNativeProps(a, rs, ctor, "DataView", 1);
    try ctor.setOwn(a, rs, "prototype", .{ .object = proto });
    try ctor.setAttr(a, "prototype", .{ .writable = false, .enumerable = false, .configurable = false });
    try setConstructor(a, rs, proto, ctor);
    try env.put("DataView", .{ .object = ctor });
}

/// Normalize a relative index (negative counts from the end) into [0, len].
/// The argument is coerced via ToIntegerOrInfinity (`toNumberV`), so a Symbol
/// or BigInt — or an object whose `valueOf` throws — propagates a TypeError.
fn relIndex(self: *Interpreter, v: Value, len: usize, default: f64) EvalError!usize {
    const n = if (v == .undefined) default else try self.toNumberV(v);
    if (std.math.isNan(n)) return 0;
    const fl = @trunc(n);
    if (fl < 0) {
        const from_end = @as(f64, @floatFromInt(len)) + fl;
        return if (from_end < 0) 0 else @intFromFloat(from_end);
    }
    const flen: f64 = @floatFromInt(len);
    return if (fl > flen) len else @intFromFloat(fl);
}

/// `ArrayBuffer.prototype.slice(begin, end)` — a copy of the byte range.
fn arrayBufferSliceFn(ctx: *anyopaque, this: Value, args: []const Value) value.HostError!Value {
    const self: *Interpreter = @ptrCast(@alignCast(ctx));
    if (this != .object or this.object.array_buffer == null) return self.throwError("TypeError", "ArrayBuffer.prototype.slice called on a non-ArrayBuffer");
    const ab = this.object.array_buffer.?;
    if (ab.detached) return self.throwError("TypeError", "ArrayBuffer is detached");
    const blen = ab.data.len;
    const start = try relIndex(self, if (args.len > 0) args[0] else .undefined, blen, 0);
    const end = try relIndex(self, if (args.len > 1) args[1] else .undefined, blen, @floatFromInt(blen));
    const count = if (end > start) end - start else 0;
    const out = try self.makeArrayBuffer(count);
    @memcpy(out.array_buffer.?.data[0..count], ab.data[start .. start + count]);
    return .{ .object = out };
}

/// Build a fresh typed array of `kind` with `len` zero-initialized elements.
fn newTypedArray(self: *Interpreter, kind: value.TAKind, len: usize) EvalError!*value.Object {
    const o = (try self.newObject()).object;
    const ta = try self.arena.create(value.TypedArrayData);
    ta.* = .{ .buffer = try self.makeArrayBuffer(len * kind.byteSize()), .byte_offset = 0, .length = len, .kind = kind };
    o.typed_array = ta;
    if (self.env.get(kind.ctorName())) |c| {
        if (c == .object) o.proto = try self.protoObject(c.object);
    }
    return o;
}

/// %TypedArray%.prototype methods. The receiver is a typed array; element reads
/// go through the buffer (`taRead`), writes coerce via ToNumber + `taWrite`.
fn typedArrayMethod(self: *Interpreter, o: *value.Object, name: []const u8, args: []const Value) EvalError!?Value {
    const ta = o.typed_array.?;
    const len = if (ta.buffer.array_buffer.?.detached) 0 else ta.length;
    const recv = Value{ .object = o };
    const cb_this: Value = if (args.len > 1) args[1] else .undefined;
    if (eq(name, "at")) {
        var idx = if (args.len > 0) @as(i64, @intFromFloat(@trunc((try self.toNumberV(args[0]))))) else 0;
        if (idx < 0) idx += @as(i64, @intCast(len));
        if (idx < 0 or idx >= len) return Value.undefined;
        return value.taRead(ta, @intCast(idx));
    }
    if (eq(name, "join")) {
        const sep = if (args.len > 0 and args[0] != .undefined) try self.toStringV(args[0]) else ",";
        var buf: std.ArrayListUnmanaged(u8) = .empty;
        var i: usize = 0;
        while (i < len) : (i += 1) {
            if (i > 0) try buf.appendSlice(self.arena, sep);
            try buf.appendSlice(self.arena, try value.numberToString(self.arena, value.taRead(ta, i).number));
        }
        return Value{ .string = try buf.toOwnedSlice(self.arena) };
    }
    if (eq(name, "forEach")) {
        const cb = if (args.len > 0) args[0] else Value.undefined;
        var i: usize = 0;
        while (i < len) : (i += 1) _ = try self.callValueWithThis(cb, &.{ value.taRead(ta, i), .{ .number = @floatFromInt(i) }, recv }, cb_this);
        return Value.undefined;
    }
    if (eq(name, "map")) {
        const cb = if (args.len > 0) args[0] else Value.undefined;
        const result = try newTypedArray(self, ta.kind, len);
        var i: usize = 0;
        while (i < len) : (i += 1) {
            const r = try self.callValueWithThis(cb, &.{ value.taRead(ta, i), .{ .number = @floatFromInt(i) }, recv }, cb_this);
            value.taWrite(result.typed_array.?, i, try self.toNumberV(r));
        }
        return .{ .object = result };
    }
    if (eq(name, "filter")) {
        const cb = if (args.len > 0) args[0] else Value.undefined;
        var kept: std.ArrayListUnmanaged(f64) = .empty;
        var i: usize = 0;
        while (i < len) : (i += 1) {
            const el = value.taRead(ta, i);
            if ((try self.callValueWithThis(cb, &.{ el, .{ .number = @floatFromInt(i) }, recv }, cb_this)).toBoolean())
                try kept.append(self.arena, el.number);
        }
        const result = try newTypedArray(self, ta.kind, kept.items.len);
        for (kept.items, 0..) |x, k| value.taWrite(result.typed_array.?, k, x);
        return .{ .object = result };
    }
    if (eq(name, "some") or eq(name, "every")) {
        const every = eq(name, "every");
        const cb = if (args.len > 0) args[0] else Value.undefined;
        var i: usize = 0;
        while (i < len) : (i += 1) {
            const t = (try self.callValueWithThis(cb, &.{ value.taRead(ta, i), .{ .number = @floatFromInt(i) }, recv }, cb_this)).toBoolean();
            if (every and !t) return Value{ .boolean = false };
            if (!every and t) return Value{ .boolean = true };
        }
        return Value{ .boolean = every };
    }
    if (eq(name, "find") or eq(name, "findIndex")) {
        const want_idx = eq(name, "findIndex");
        const cb = if (args.len > 0) args[0] else Value.undefined;
        var i: usize = 0;
        while (i < len) : (i += 1) {
            const el = value.taRead(ta, i);
            if ((try self.callValueWithThis(cb, &.{ el, .{ .number = @floatFromInt(i) }, recv }, cb_this)).toBoolean())
                return if (want_idx) Value{ .number = @floatFromInt(i) } else el;
        }
        return if (want_idx) Value{ .number = -1 } else Value.undefined;
    }
    if (eq(name, "reduce")) {
        const cb = if (args.len > 0) args[0] else Value.undefined;
        var acc: Value = undefined;
        var i: usize = 0;
        if (args.len > 1) {
            acc = args[1];
        } else {
            if (len == 0) return self.throwError("TypeError", "Reduce of empty array with no initial value");
            acc = value.taRead(ta, 0);
            i = 1;
        }
        while (i < len) : (i += 1) acc = try self.callValueWithThis(cb, &.{ acc, value.taRead(ta, i), .{ .number = @floatFromInt(i) }, recv }, .undefined);
        return acc;
    }
    if (eq(name, "indexOf") or eq(name, "lastIndexOf") or eq(name, "includes")) {
        const target = if (args.len > 0) try self.toNumberV(args[0]) else std.math.nan(f64);
        const incl = eq(name, "includes");
        var i: usize = 0;
        while (i < len) : (i += 1) {
            const e = value.taRead(ta, i).number;
            if (e == target or (incl and std.math.isNan(e) and std.math.isNan(target)))
                return if (incl) Value{ .boolean = true } else Value{ .number = @floatFromInt(i) };
        }
        return if (incl) Value{ .boolean = false } else Value{ .number = -1 };
    }
    if (eq(name, "fill")) {
        const v = if (args.len > 0) try self.toNumberV(args[0]) else std.math.nan(f64);
        const start = try relIndex(self, if (args.len > 1) args[1] else .undefined, len, 0);
        const end = try relIndex(self, if (args.len > 2) args[2] else .undefined, len, @floatFromInt(len));
        var i = start;
        while (i < end) : (i += 1) value.taWrite(ta, i, v);
        return recv;
    }
    if (eq(name, "reverse")) {
        var i: usize = 0;
        while (i < len / 2) : (i += 1) {
            const tmp = value.taRead(ta, i).number;
            value.taWrite(ta, i, value.taRead(ta, len - 1 - i).number);
            value.taWrite(ta, len - 1 - i, tmp);
        }
        return recv;
    }
    if (eq(name, "slice") or eq(name, "subarray")) {
        const start = try relIndex(self, if (args.len > 0) args[0] else .undefined, len, 0);
        const end = try relIndex(self, if (args.len > 1) args[1] else .undefined, len, @floatFromInt(len));
        const count = if (end > start) end - start else 0;
        if (eq(name, "subarray")) {
            // A view onto the same buffer (no copy).
            const o2 = (try self.newObject()).object;
            const ta2 = try self.arena.create(value.TypedArrayData);
            ta2.* = .{ .buffer = ta.buffer, .byte_offset = ta.byte_offset + start * ta.kind.byteSize(), .length = count, .kind = ta.kind };
            o2.typed_array = ta2;
            o2.proto = o.proto;
            return .{ .object = o2 };
        }
        const result = try newTypedArray(self, ta.kind, count);
        var i: usize = 0;
        while (i < count) : (i += 1) value.taWrite(result.typed_array.?, i, value.taRead(ta, start + i).number);
        return .{ .object = result };
    }
    if (eq(name, "set")) {
        const src = if (args.len > 0) args[0] else Value.undefined;
        const offset: usize = if (args.len > 1) @intFromFloat(@trunc(@max(0, try self.toNumberV(args[1])))) else 0;
        if (src == .object and src.object.typed_array != null) {
            const s = src.object.typed_array.?;
            if (offset + s.length > len) return self.throwError("RangeError", "offset is out of bounds");
            var i: usize = 0;
            while (i < s.length) : (i += 1) value.taWrite(ta, offset + i, value.taRead(s, i).number);
        } else if (src == .object) {
            const list = try self.iterableOrArrayLikeToList(src);
            if (offset + list.len > len) return self.throwError("RangeError", "offset is out of bounds");
            for (list, 0..) |x, i| value.taWrite(ta, offset + i, try self.toNumberV(x));
        }
        return Value.undefined;
    }
    if (eq(name, "toString")) {
        return try typedArrayMethod(self, o, "join", &.{});
    }
    if (eq(name, "keys") or eq(name, "values") or eq(name, "entries")) {
        // Materialize a plain array and return its iterator (good enough for
        // for-of / spread over a typed array).
        const arr = (try self.newArray()).object;
        var i: usize = 0;
        while (i < len) : (i += 1) {
            if (eq(name, "keys")) {
                try arr.elements.append(self.arena, .{ .number = @floatFromInt(i) });
            } else if (eq(name, "values")) {
                try arr.elements.append(self.arena, value.taRead(ta, i));
            } else {
                const pair = (try self.newArray()).object;
                try pair.elements.append(self.arena, .{ .number = @floatFromInt(i) });
                try pair.elements.append(self.arena, value.taRead(ta, i));
                try arr.elements.append(self.arena, .{ .object = pair });
            }
        }
        return try self.iteratorOf(.{ .object = arr });
    }
    return null;
}

/// A %TypedArray%.prototype method thunk: brand-checks `this` is a typed array,
/// then dispatches to `typedArrayMethod`.
fn taProtoMethod(comptime name: []const u8) value.NativeFn {
    return struct {
        fn call(ctx: *anyopaque, this: Value, args: []const Value) value.HostError!Value {
            const self: *Interpreter = @ptrCast(@alignCast(ctx));
            if (this != .object or this.object.typed_array == null)
                return self.throwError("TypeError", "TypedArray.prototype method called on a non-TypedArray");
            return (try typedArrayMethod(self, this.object, name, args)) orelse .undefined;
        }
    }.call;
}

/// `new ArrayBuffer(byteLength)`.
fn arrayBufferConstructorFn(ctx: *anyopaque, this: Value, args: []const Value) value.HostError!Value {
    _ = this;
    const self: *Interpreter = @ptrCast(@alignCast(ctx));
    if (self.new_target == .undefined) return self.throwError("TypeError", "Constructor ArrayBuffer requires 'new'");
    const len_f = if (args.len > 0) try self.toNumberV(args[0]) else 0;
    if (len_f < 0 or @trunc(len_f) != len_f or len_f > 0x7fffffff) return self.throwError("RangeError", "Invalid ArrayBuffer length");
    return .{ .object = try self.makeArrayBuffer(@intFromFloat(len_f)) };
}

/// `ArrayBuffer.isView(v)` — true for a typed-array (or DataView) view.
fn arrayBufferIsViewFn(ctx: *anyopaque, this: Value, args: []const Value) value.HostError!Value {
    _ = ctx;
    _ = this;
    const v = if (args.len > 0) args[0] else Value.undefined;
    return .{ .boolean = v == .object and v.object.typed_array != null };
}

/// A typed-array constructor for `kind` (`new Int8Array(...)`, …).
fn typedArrayCtorFn(comptime kind: value.TAKind) value.NativeFn {
    return struct {
        fn call(ctx: *anyopaque, this: Value, args: []const Value) value.HostError!Value {
            _ = this;
            const self: *Interpreter = @ptrCast(@alignCast(ctx));
            if (self.new_target == .undefined) return self.throwError("TypeError", "Constructor TypedArray requires 'new'");
            return self.makeTypedArray(kind, args);
        }
    }.call;
}

pub fn installGlobals(env: *Environment, root_shape: *Shape) EvalError!void {
    return installGlobalsInner(env, root_shape, null);
}

/// `parent_symbol`, when non-null (a `$262.createRealm()` child realm), is the
/// creating realm's `Symbol` object: the well-known symbols are *shared* across
/// realms, so the child reuses those same symbol objects (identity holds across
/// realms) and keys all its `@@`-methods under them.
pub fn installGlobalsInner(env: *Environment, root_shape: *Shape, parent_symbol: ?*value.Object) EvalError!void {
    const a = env.arena;
    const error_names = [_][]const u8{
        "Error",       "TypeError", "RangeError", "ReferenceError",
        "SyntaxError", "EvalError",  "URIError",   "AggregateError",
    };
    for (error_names) |name| {
        const o = try a.create(value.Object);
        o.* = .{ .error_ctor = name };
        // AggregateError(errors, message) has arity 2; the others (message) 1.
        try installNativeProps(a, root_shape, o, name, if (std.mem.eql(u8, name, "AggregateError")) 2 else 1);
        try env.put(name, .{ .object = o });
    }
    try env.put("NaN", .{ .number = std.math.nan(f64) });
    try env.put("Infinity", .{ .number = std.math.inf(f64) });
    try env.put("undefined", .undefined);

    // Global functions.
    try defineGlobalFn(env, root_shape, "eval", 1, evalFn);
    try defineGlobalFn(env, root_shape, "parseInt", 2, builtins.parseIntFn);
    try defineGlobalFn(env, root_shape, "parseFloat", 1, builtins.parseFloatFn);
    try defineGlobalFn(env, root_shape, "isNaN", 1, builtins.isNaNFn);
    try defineGlobalFn(env, root_shape, "isFinite", 1, builtins.isFiniteFn);
    try defineGlobalFnC(env, root_shape, "RegExp", 2, true, builtins.regExpFn);
    try defineGlobalFnC(env, root_shape, "Map", 0, true, builtins.mapFn);
    if (env.get("Map")) |m| {
        if (m == .object) try setNative(a, root_shape, m.object, "groupBy", 2, mapGroupByFn);
    }
    try installMapProto(env, root_shape);
    try defineGlobalFnC(env, root_shape, "Set", 0, true, builtins.setFn);
    try installSetProto(env, root_shape);
    try defineGlobalFnC(env, root_shape, "WeakMap", 0, true, builtins.mapFn);
    try defineGlobalFnC(env, root_shape, "WeakSet", 0, true, builtins.setFn);
    // WeakMap/WeakSet instances reuse the Map/Set internals (is_map/is_set), but
    // their prototypes are distinct and carry only the weak subset as real own
    // methods (so `typeof WeakMap.prototype.set === "function"`, `.call`, and
    // reflection work). No clear/forEach/iterators on the weak collections.
    if (env.get("WeakMap")) |wm| if (wm == .object) {
        if (wm.object.getOwn("prototype")) |pv| if (pv == .object) {
            inline for (.{ .{ "set", 2 }, .{ "get", 1 }, .{ "has", 1 }, .{ "delete", 1 }, .{ "getOrInsert", 2 }, .{ "getOrInsertComputed", 2 } }) |s|
                try setNative(a, root_shape, pv.object, s[0], s[1], mapProtoMethod(s[0], true));
        };
    };
    if (env.get("WeakSet")) |ws| if (ws == .object) {
        if (ws.object.getOwn("prototype")) |pv| if (pv == .object) {
            inline for (.{ .{ "add", 1 }, .{ "has", 1 }, .{ "delete", 1 } }) |s|
                try setNative(a, root_shape, pv.object, s[0], s[1], setProtoMethod(s[0], true));
        };
    };
    try defineGlobalFnC(env, root_shape, "Boolean", 1, true, builtins.booleanFn);
    try defineGlobalFn(env, root_shape, "print", 1, printFn);

    // Promise — constructor, prototype (then/catch/finally), and statics.
    const promise_proto = try a.create(value.Object);
    promise_proto.* = .{};
    try setNative(a, root_shape, promise_proto, "then", 2, promiseThenFn);
    try setNative(a, root_shape, promise_proto, "catch", 1, promiseCatchFn);
    try setNative(a, root_shape, promise_proto, "finally", 1, promiseFinallyFn);
    const promise_ns = try a.create(value.Object);
    promise_ns.* = .{ .native = promiseConstructorFn, .native_ctor = true };
    try installNativeProps(a, root_shape, promise_ns, "Promise", 1);
    try setNative(a, root_shape, promise_ns, "resolve", 1, promiseResolveStaticFn);
    try setNative(a, root_shape, promise_ns, "reject", 1, promiseRejectStaticFn);
    try setNative(a, root_shape, promise_ns, "all", 1, promiseAllFn);
    try setNative(a, root_shape, promise_ns, "allSettled", 1, promiseAllSettledFn);
    try setNative(a, root_shape, promise_ns, "any", 1, promiseAnyFn);
    try setNative(a, root_shape, promise_ns, "race", 1, promiseRaceFn);
    try promise_ns.setOwn(a, root_shape, "prototype", .{ .object = promise_proto });
    try promise_ns.setAttr(a, "prototype", .{ .writable = false, .enumerable = false, .configurable = false });
    try setConstructor(a, root_shape, promise_proto, promise_ns);
    try env.put("Promise", .{ .object = promise_ns });

    // String — callable, with statics.
    const string_ns = try a.create(value.Object);
    string_ns.* = .{ .native = builtins.stringFn, .native_ctor = true };
    try installNativeProps(a, root_shape, string_ns, "String", 1);
    try setNative(a, root_shape, string_ns, "fromCharCode", 1, builtins.stringFromCharCode);
    try setNative(a, root_shape, string_ns, "fromCodePoint", 1, builtins.stringFromCodePoint);
    try setNative(a, root_shape, string_ns, "raw", 1, builtins.stringRaw);
    try env.put("String", .{ .object = string_ns });

    // Number — callable, with statics and constants.
    const number_ns = try a.create(value.Object);
    number_ns.* = .{ .native = builtins.numberFn, .native_ctor = true };
    try installNativeProps(a, root_shape, number_ns, "Number", 1);
    try setNative(a, root_shape, number_ns, "isInteger", 1, builtins.numberIsInteger);
    try setNative(a, root_shape, number_ns, "isSafeInteger", 1, builtins.numberIsSafeInteger);
    try setNative(a, root_shape, number_ns, "isNaN", 1, builtins.numberIsNaN);
    try setNative(a, root_shape, number_ns, "isFinite", 1, builtins.numberIsFinite);
    try setNative(a, root_shape, number_ns, "parseFloat", 1, builtins.parseFloatFn);
    try setNative(a, root_shape, number_ns, "parseInt", 2, builtins.parseIntFn);
    try number_ns.setOwn(a, root_shape, "MAX_SAFE_INTEGER", .{ .number = 9007199254740991 });
    try number_ns.setOwn(a, root_shape, "MIN_SAFE_INTEGER", .{ .number = -9007199254740991 });
    try number_ns.setOwn(a, root_shape, "MAX_VALUE", .{ .number = std.math.floatMax(f64) });
    try number_ns.setOwn(a, root_shape, "MIN_VALUE", .{ .number = std.math.floatMin(f64) });
    try number_ns.setOwn(a, root_shape, "EPSILON", .{ .number = std.math.floatEps(f64) });
    try number_ns.setOwn(a, root_shape, "POSITIVE_INFINITY", .{ .number = std.math.inf(f64) });
    try number_ns.setOwn(a, root_shape, "NEGATIVE_INFINITY", .{ .number = -std.math.inf(f64) });
    try number_ns.setOwn(a, root_shape, "NaN", .{ .number = std.math.nan(f64) });
    // The Number constants are { !writable, !enumerable, !configurable }.
    const frozen_attr: value.PropAttr = .{ .writable = false, .enumerable = false, .configurable = false };
    for ([_][]const u8{ "MAX_SAFE_INTEGER", "MIN_SAFE_INTEGER", "MAX_VALUE", "MIN_VALUE", "EPSILON", "POSITIVE_INFINITY", "NEGATIVE_INFINITY", "NaN" }) |n|
        try number_ns.setAttr(a, n, frozen_attr);
    try env.put("Number", .{ .object = number_ns });

    // JSON namespace.
    const json_ns = try a.create(value.Object);
    json_ns.* = .{};
    try setNative(a, root_shape, json_ns, "stringify", 3, builtins.jsonStringify);
    try setNative(a, root_shape, json_ns, "parse", 2, builtins.jsonParse);
    try env.put("JSON", .{ .object = json_ns });

    // Math namespace.
    const math_obj = try a.create(value.Object);
    math_obj.* = .{};
    try setNative(a, root_shape, math_obj, "floor", 1, builtins.mathFloor);
    try setNative(a, root_shape, math_obj, "ceil", 1, builtins.mathCeil);
    try setNative(a, root_shape, math_obj, "round", 1, builtins.mathRound);
    try setNative(a, root_shape, math_obj, "trunc", 1, builtins.mathTrunc);
    try setNative(a, root_shape, math_obj, "abs", 1, builtins.mathAbs);
    try setNative(a, root_shape, math_obj, "sqrt", 1, builtins.mathSqrt);
    try setNative(a, root_shape, math_obj, "sign", 1, builtins.mathSign);
    try setNative(a, root_shape, math_obj, "pow", 2, builtins.mathPow);
    try setNative(a, root_shape, math_obj, "max", 2, builtins.mathMax);
    try setNative(a, root_shape, math_obj, "min", 2, builtins.mathMin);
    try setNative(a, root_shape, math_obj, "sin", 1, builtins.unaryMath(builtins.mfns.sin));
    try setNative(a, root_shape, math_obj, "cos", 1, builtins.unaryMath(builtins.mfns.cos));
    try setNative(a, root_shape, math_obj, "tan", 1, builtins.unaryMath(builtins.mfns.tan));
    try setNative(a, root_shape, math_obj, "asin", 1, builtins.unaryMath(builtins.mfns.asin));
    try setNative(a, root_shape, math_obj, "acos", 1, builtins.unaryMath(builtins.mfns.acos));
    try setNative(a, root_shape, math_obj, "atan", 1, builtins.unaryMath(builtins.mfns.atan));
    try setNative(a, root_shape, math_obj, "sinh", 1, builtins.unaryMath(builtins.mfns.sinh));
    try setNative(a, root_shape, math_obj, "cosh", 1, builtins.unaryMath(builtins.mfns.cosh));
    try setNative(a, root_shape, math_obj, "tanh", 1, builtins.unaryMath(builtins.mfns.tanh));
    try setNative(a, root_shape, math_obj, "asinh", 1, builtins.unaryMath(builtins.mfns.asinh));
    try setNative(a, root_shape, math_obj, "acosh", 1, builtins.unaryMath(builtins.mfns.acosh));
    try setNative(a, root_shape, math_obj, "atanh", 1, builtins.unaryMath(builtins.mfns.atanh));
    try setNative(a, root_shape, math_obj, "exp", 1, builtins.unaryMath(builtins.mfns.exp));
    try setNative(a, root_shape, math_obj, "expm1", 1, builtins.unaryMath(builtins.mfns.expm1));
    try setNative(a, root_shape, math_obj, "log", 1, builtins.unaryMath(builtins.mfns.log));
    try setNative(a, root_shape, math_obj, "log2", 1, builtins.unaryMath(builtins.mfns.log2));
    try setNative(a, root_shape, math_obj, "log10", 1, builtins.unaryMath(builtins.mfns.log10));
    try setNative(a, root_shape, math_obj, "log1p", 1, builtins.unaryMath(builtins.mfns.log1p));
    try setNative(a, root_shape, math_obj, "cbrt", 1, builtins.unaryMath(builtins.mfns.cbrt));
    try setNative(a, root_shape, math_obj, "fround", 1, builtins.unaryMath(builtins.mfns.fround));
    try setNative(a, root_shape, math_obj, "atan2", 2, builtins.mathAtan2);
    try setNative(a, root_shape, math_obj, "hypot", 2, builtins.mathHypot);
    try setNative(a, root_shape, math_obj, "clz32", 1, builtins.mathClz32);
    try setNative(a, root_shape, math_obj, "imul", 2, builtins.mathImul);
    try setNative(a, root_shape, math_obj, "random", 0, builtins.mathRandom);
    try math_obj.setOwn(a, root_shape, "PI", .{ .number = std.math.pi });
    try math_obj.setOwn(a, root_shape, "E", .{ .number = std.math.e });
    try math_obj.setOwn(a, root_shape, "LN2", .{ .number = std.math.ln2 });
    try math_obj.setOwn(a, root_shape, "LN10", .{ .number = @log(@as(f64, 10)) });
    try math_obj.setOwn(a, root_shape, "LOG2E", .{ .number = std.math.log2e });
    try math_obj.setOwn(a, root_shape, "LOG10E", .{ .number = std.math.log10e });
    try math_obj.setOwn(a, root_shape, "SQRT2", .{ .number = std.math.sqrt2 });
    try math_obj.setOwn(a, root_shape, "SQRT1_2", .{ .number = 1.0 / std.math.sqrt2 });
    // The Math constants are { !writable, !enumerable, !configurable }.
    for ([_][]const u8{ "PI", "E", "LN2", "LN10", "LOG2E", "LOG10E", "SQRT2", "SQRT1_2" }) |n|
        try math_obj.setAttr(a, n, .{ .writable = false, .enumerable = false, .configurable = false });
    try env.put("Math", .{ .object = math_obj });

    // Object namespace.
    const object_ns = try a.create(value.Object);
    object_ns.* = .{ .native = builtins.objectConstructor, .native_ctor = true };
    try installNativeProps(a, root_shape, object_ns, "Object", 1);
    try setNative(a, root_shape, object_ns, "keys", 1, builtins.objectKeys);
    try setNative(a, root_shape, object_ns, "values", 1, builtins.objectValues);
    try setNative(a, root_shape, object_ns, "assign", 2, builtins.objectAssign);
    try setNative(a, root_shape, object_ns, "create", 2, builtins.objectCreate);
    try setNative(a, root_shape, object_ns, "getPrototypeOf", 1, builtins.objectGetPrototypeOf);
    try setNative(a, root_shape, object_ns, "defineProperty", 3, builtins.objectDefineProperty);
    try setNative(a, root_shape, object_ns, "defineProperties", 2, builtins.objectDefineProperties);
    try setNative(a, root_shape, object_ns, "getOwnPropertyDescriptor", 2, builtins.objectGetOwnPropertyDescriptor);
    try setNative(a, root_shape, object_ns, "getOwnPropertyDescriptors", 1, builtins.objectGetOwnPropertyDescriptors);
    try setNative(a, root_shape, object_ns, "getOwnPropertyNames", 1, builtins.objectGetOwnPropertyNames);
    try setNative(a, root_shape, object_ns, "getOwnPropertySymbols", 1, builtins.objectGetOwnPropertySymbols);
    try setNative(a, root_shape, object_ns, "is", 2, builtins.objectIs);
    try setNative(a, root_shape, object_ns, "setPrototypeOf", 2, builtins.objectSetPrototypeOf);
    try setNative(a, root_shape, object_ns, "preventExtensions", 1, builtins.objectPreventExtensions);
    try setNative(a, root_shape, object_ns, "isExtensible", 1, builtins.objectIsExtensible);
    try setNative(a, root_shape, object_ns, "seal", 1, builtins.objectSeal);
    try setNative(a, root_shape, object_ns, "isSealed", 1, builtins.objectIsSealed);
    try setNative(a, root_shape, object_ns, "freeze", 1, builtins.objectFreeze);
    try setNative(a, root_shape, object_ns, "isFrozen", 1, builtins.objectIsFrozen);
    try setNative(a, root_shape, object_ns, "entries", 1, builtins.objectEntries);
    try setNative(a, root_shape, object_ns, "fromEntries", 1, builtins.objectFromEntries);
    try setNative(a, root_shape, object_ns, "groupBy", 2, objectGroupByFn);
    try setNative(a, root_shape, object_ns, "hasOwn", 2, builtins.objectHasOwn);
    try env.put("Object", .{ .object = object_ns });

    // Array namespace (callable constructor + isArray/of/from).
    const array_ns = try a.create(value.Object);
    array_ns.* = .{ .native = builtins.arrayConstructor, .native_ctor = true };
    try installNativeProps(a, root_shape, array_ns, "Array", 1);
    try setNative(a, root_shape, array_ns, "isArray", 1, builtins.arrayIsArray);
    try setNative(a, root_shape, array_ns, "of", 0, builtins.arrayOf);
    try setNative(a, root_shape, array_ns, "from", 1, builtins.arrayFrom);
    try env.put("Array", .{ .object = array_ns });

    // ---- Real prototype objects ----------------------------------------
    // Each holds its methods as properties (thunks routing to `builtinMethod`),
    // hung off the matching global constructor's `.prototype`. This makes
    // `Array.prototype.join`, `Object.prototype.hasOwnProperty`, and crucially
    // `Function.prototype.call.bind(...)` resolve — the patterns test262's
    // propertyHelper/verifyProperty (and many built-ins tests) depend on.
    const object_proto = try a.create(value.Object);
    object_proto.* = .{};
    try setProtoMethods(a, root_shape, object_proto, .{
        .{ "hasOwnProperty", 1 },        .{ "propertyIsEnumerable", 1 }, .{ "isPrototypeOf", 1 },
        .{ "valueOf", 0 },
        .{ "__defineGetter__", 2 },      .{ "__defineSetter__", 2 },
        .{ "__lookupGetter__", 1 },      .{ "__lookupSetter__", 1 },
    });
    // `Object.prototype.toString` is the dedicated `[object Tag]` native (not the
    // kind-dispatched `toString`, so `Object.prototype.toString.call([])` gives
    // "[object Array]" while `[].toString()` still joins).
    try setNative(a, root_shape, object_proto, "toLocaleString", 0, objectProtoToLocaleStringFn);
    try setNative(a, root_shape, object_proto, "toString", 0, objectProtoToStringFn);
    // `Object.prototype.__proto__` accessor (the legacy prototype get/set).
    {
        const getter = try a.create(value.Object);
        getter.* = .{ .native = protoGetterFn };
        try installFunctionProps(a, root_shape, getter, &.{}, "get __proto__");
        const setter = try a.create(value.Object);
        setter.* = .{ .native = protoSetterFn };
        try installFunctionProps(a, root_shape, setter, &.{}, "set __proto__");
        try object_proto.setAccessor(a, "__proto__", .{ .object = getter }, .{ .object = setter });
        try object_proto.setAttr(a, "__proto__", .{ .enumerable = false, .configurable = true });
    }
    try object_ns.setOwn(a, root_shape, "prototype", .{ .object = object_proto });
    try object_ns.setAttr(a, "prototype", .{ .writable = false, .enumerable = false, .configurable = false });

    // Error prototypes: `Error.prototype` carries name/message/constructor/toString
    // and protos to Object.prototype; each subclass (`TypeError.prototype`, …)
    // protos to `Error.prototype`. Instances are linked in `makeError`.
    const ro: value.PropAttr = .{ .enumerable = false, .configurable = true, .writable = true };
    const error_proto = try a.create(value.Object);
    error_proto.* = .{ .proto = object_proto };
    for (error_names) |ename| {
        const ctor_v = env.get(ename) orelse continue;
        const ctor = ctor_v.object;
        const is_base = std.mem.eql(u8, ename, "Error");
        const proto = if (is_base) error_proto else blk: {
            const p = try a.create(value.Object);
            p.* = .{ .proto = error_proto };
            break :blk p;
        };
        try proto.setOwn(a, root_shape, "name", .{ .string = ename });
        try proto.setAttr(a, "name", ro);
        try proto.setOwn(a, root_shape, "message", .{ .string = "" });
        try proto.setAttr(a, "message", ro);
        try proto.setOwn(a, root_shape, "constructor", ctor_v);
        try proto.setAttr(a, "constructor", ro);
        if (is_base) {
            try setNative(a, root_shape, proto, "toString", 0, errorToStringFn);
            // `Error.prototype.stack` is a V8-style accessor (get brand-checks an
            // Error receiver; set installs an own data property), inherited by all
            // error subclasses.
            const stack_get = try a.create(value.Object);
            stack_get.* = .{ .native = errorStackGet };
            try installNativeProps(a, root_shape, stack_get, "get stack", 0);
            const stack_set = try a.create(value.Object);
            // private_data = the home object (%Error.prototype%) for the
            // SetterThatIgnoresPrototypeProperties same-as-home TypeError check.
            stack_set.* = .{ .native = errorStackSet, .private_data = @ptrCast(proto) };
            try installNativeProps(a, root_shape, stack_set, "set stack", 1);
            try proto.setAccessor(a, "stack", .{ .object = stack_get }, .{ .object = stack_set });
            try proto.setAttr(a, "stack", .{ .enumerable = false, .configurable = true });
            // ES2025 `Error.isError(v)` — a brand check for [[ErrorData]] (seeing
            // through a Proxy to its target), independent of the prototype chain.
            try setNative(a, root_shape, ctor, "isError", 1, errorIsErrorFn);
        }
        try ctor.setOwn(a, root_shape, "prototype", .{ .object = proto });
        try ctor.setAttr(a, "prototype", .{ .enumerable = false, .configurable = false, .writable = false });
    }

    const func_proto = try a.create(value.Object);
    // Function.prototype is a callable (noop) object, and its call/apply/bind/
    // toString brand-check that `this` is callable (TypeError otherwise).
    func_proto.* = .{ .proto = object_proto, .native = funcProtoNoop };
    inline for (.{
        .{ "call", 1 }, .{ "apply", 2 }, .{ "bind", 1 }, .{ "toString", 0 },
    }) |s| try setNative(a, root_shape, func_proto, s[0], s[1], funcProtoMethod(s[0]));
    // `Function.prototype` is itself callable-shaped, with own `length` 0 and
    // `name` "" — both { !writable, !enumerable, configurable }.
    try func_proto.setOwn(a, root_shape, "length", .{ .number = 0 });
    try func_proto.setAttr(a, "length", .{ .writable = false, .enumerable = false, .configurable = true });
    try func_proto.setOwn(a, root_shape, "name", .{ .string = "" });
    try func_proto.setAttr(a, "name", .{ .writable = false, .enumerable = false, .configurable = true });
    // The %ThrowTypeError% poison-pill: `Function.prototype.caller` and
    // `.arguments` are accessor properties whose get AND set are the single
    // shared %ThrowTypeError% intrinsic ({ !enumerable, !configurable }). Reading
    // or writing `fn.caller`/`fn.arguments` on a strict function walks the proto
    // chain to here and throws (the "restricted properties").
    {
        const tte = try a.create(value.Object);
        tte.* = .{ .native = throwTypeErrorFn };
        try installFunctionProps(a, root_shape, tte, &.{}, "");
        // %ThrowTypeError% is itself frozen: length/name non-writable & non-configurable.
        try tte.setAttr(a, "length", .{ .writable = false, .enumerable = false, .configurable = false });
        try tte.setAttr(a, "name", .{ .writable = false, .enumerable = false, .configurable = false });
        for ([_][]const u8{ "caller", "arguments" }) |pname| {
            try func_proto.setAccessor(a, pname, .{ .object = tte }, .{ .object = tte });
            try func_proto.setAttr(a, pname, .{ .enumerable = false, .configurable = true });
        }
    }
    const function_ns = try a.create(value.Object);
    function_ns.* = .{ .native = builtins.functionConstructor, .native_ctor = true, .proto = func_proto };
    try installNativeProps(a, root_shape, function_ns, "Function", 1);
    try function_ns.setOwn(a, root_shape, "prototype", .{ .object = func_proto });
    try function_ns.setAttr(a, "prototype", .{ .writable = false, .enumerable = false, .configurable = false });
    try setConstructor(a, root_shape, func_proto, function_ns);
    try env.put("Function", .{ .object = function_ns });

    // Boolean.prototype (Boolean wrapper objects aren't modeled, but the prototype
    // and its `constructor`/`toString`/`valueOf` are still observable).
    if (env.get("Boolean")) |bv| {
        if (bv == .object) {
            const boolean_proto = try a.create(value.Object);
            // Boolean.prototype is a Boolean Exotic Object with [[BooleanData]]
            // = false, so brand-checked methods (`Boolean.prototype.toString()`,
            // `valueOf()`) accept it as a Boolean and don't throw.
            boolean_proto.* = .{ .proto = object_proto, .prim = .{ .boolean = false } };
            try setNative(a, root_shape, boolean_proto, "toString", 0, booleanProtoFn(true));
            try setNative(a, root_shape, boolean_proto, "valueOf", 0, booleanProtoFn(false));
            try setConstructor(a, root_shape, boolean_proto, bv.object);
            try bv.object.setOwn(a, root_shape, "prototype", .{ .object = boolean_proto });
            try bv.object.setAttr(a, "prototype", .{ .enumerable = false, .configurable = false, .writable = false });
        }
    }

    const array_proto = try a.create(value.Object);
    array_proto.* = .{ .proto = object_proto };
    try setArrayProtoMethods(a, root_shape, array_proto, .{
        .{ "join", 1 },       .{ "push", 1 },         .{ "pop", 0 },        .{ "shift", 0 },
        .{ "unshift", 1 },    .{ "slice", 2 },        .{ "splice", 2 },     .{ "concat", 1 },
        .{ "reverse", 0 },    .{ "indexOf", 1 },      .{ "lastIndexOf", 1 }, .{ "includes", 1 },
        .{ "map", 1 },        .{ "filter", 1 },       .{ "forEach", 1 },    .{ "reduce", 1 },
        .{ "reduceRight", 1 }, .{ "some", 1 },        .{ "every", 1 },      .{ "find", 1 },
        .{ "findIndex", 1 },  .{ "findLast", 1 },     .{ "findLastIndex", 1 }, .{ "fill", 1 },
        .{ "flat", 0 },       .{ "flatMap", 1 },      .{ "sort", 1 },       .{ "keys", 0 },
        .{ "values", 0 },     .{ "entries", 0 },      .{ "copyWithin", 2 }, .{ "at", 1 },
        .{ "toString", 0 },   .{ "toReversed", 0 },   .{ "toSorted", 1 },   .{ "toSpliced", 2 },
        .{ "with", 2 },
    });
    try array_ns.setOwn(a, root_shape, "prototype", .{ .object = array_proto });
    try array_ns.setAttr(a, "prototype", .{ .writable = false, .enumerable = false, .configurable = false });
    try setConstructor(a, root_shape, array_proto, array_ns);

    const string_proto = try a.create(value.Object);
    // String.prototype is a String Exotic Object with [[StringData]] = "",
    // so brand-checked methods accept it as a String (e.g. `String.prototype.
    // toString()` returns "" rather than throwing).
    string_proto.* = .{ .proto = object_proto, .prim = .{ .string = "" } };
    // Generic String.prototype methods coerce `this` via ToString through a
    // String-specific thunk (so `String.prototype.m.call(x)` uses String `m`,
    // propagates `toString`/`valueOf` throws, and rejects Symbol/null/undefined).
    inline for (.{
        .{ "charAt", 1 },        .{ "charCodeAt", 1 },  .{ "codePointAt", 1 }, .{ "indexOf", 1 },
        .{ "lastIndexOf", 1 },   .{ "includes", 1 },    .{ "startsWith", 1 },  .{ "endsWith", 1 },
        .{ "slice", 2 },         .{ "substring", 2 },   .{ "substr", 2 },      .{ "toUpperCase", 0 },
        .{ "toLowerCase", 0 },   .{ "trim", 0 },        .{ "trimStart", 0 },   .{ "trimEnd", 0 },
        .{ "repeat", 1 },        .{ "concat", 1 },      .{ "split", 2 },       .{ "at", 1 },
        .{ "padStart", 1 },      .{ "padEnd", 1 },      .{ "replace", 2 },     .{ "replaceAll", 2 },
        .{ "localeCompare", 1 }, .{ "toLocaleUpperCase", 0 }, .{ "toLocaleLowerCase", 0 },
        .{ "match", 1 },         .{ "matchAll", 1 },    .{ "search", 1 },      .{ "normalize", 0 },
    }) |s| try setNative(a, root_shape, string_proto, s[0], s[1], stringProtoMethod(s[0]));
    // `toString`/`valueOf` brand-check (a String primitive or wrapper), not ToString.
    try setNative(a, root_shape, string_proto, "toString", 0, stringValueMethod);
    try setNative(a, root_shape, string_proto, "valueOf", 0, stringValueMethod);
    try string_ns.setOwn(a, root_shape, "prototype", .{ .object = string_proto });
    try string_ns.setAttr(a, "prototype", .{ .writable = false, .enumerable = false, .configurable = false });
    try setConstructor(a, root_shape, string_proto, string_ns);

    const number_proto = try a.create(value.Object);
    // Number.prototype is a Number Exotic Object with [[NumberData]] = +0, so
    // brand-checked methods (`Number.prototype.toString(radix)`, `valueOf()`,
    // `toFixed(...)`) accept it as a Number and return "0"/0 rather than throw.
    number_proto.* = .{ .proto = object_proto, .prim = .{ .number = 0 } };
    inline for (.{
        .{ "toString", 1 },     .{ "toFixed", 1 },        .{ "valueOf", 0 }, .{ "toLocaleString", 0 },
        .{ "toExponential", 1 }, .{ "toPrecision", 1 },
    }) |s| try setNative(a, root_shape, number_proto, s[0], s[1], numberProtoMethod(s[0]));
    try number_ns.setOwn(a, root_shape, "prototype", .{ .object = number_proto });
    try number_ns.setAttr(a, "prototype", .{ .writable = false, .enumerable = false, .configurable = false });
    try setConstructor(a, root_shape, number_proto, number_ns);

    // Symbol — callable (returns a fresh symbol) with the well-known symbols.
    const symbol_ns = try a.create(value.Object);
    symbol_ns.* = .{ .native = symbolFn };
    try installNativeProps(a, root_shape, symbol_ns, "Symbol", 0);
    // Symbol.prototype: toString/valueOf/constructor, protoing to Object.prototype.
    const symbol_proto = try a.create(value.Object);
    symbol_proto.* = .{ .proto = object_proto };
    try setNative(a, root_shape, symbol_proto, "toString", 0, symbolToStringFn);
    try setNative(a, root_shape, symbol_proto, "valueOf", 0, symbolValueOfFn);
    try symbol_proto.setOwn(a, root_shape, "constructor", .{ .object = symbol_ns });
    try symbol_proto.setAttr(a, "constructor", .{ .enumerable = false, .configurable = true, .writable = true });
    // `Symbol.prototype.description` — a configurable getter-only accessor.
    {
        const get = try a.create(value.Object);
        get.* = .{ .native = symbolDescriptionGetFn };
        try installNativeProps(a, root_shape, get, "get description", 0);
        try symbol_proto.setAccessor(a, "description", .{ .object = get }, null);
        try symbol_proto.setAttr(a, "description", .{ .enumerable = false, .configurable = true });
    }
    try symbol_ns.setOwn(a, root_shape, "prototype", .{ .object = symbol_proto });
    try symbol_ns.setAttr(a, "prototype", .{ .enumerable = false, .configurable = false, .writable = false });
    try setNative(a, root_shape, symbol_ns, "for", 1, symbolForFn);
    try setNative(a, root_shape, symbol_ns, "keyFor", 1, symbolKeyForFn);
    // Well-known symbols are own props of `Symbol` with attributes
    // {writable:false, enumerable:false, configurable:false}.
    inline for (.{ "iterator", "asyncIterator", "hasInstance", "isConcatSpreadable", "match", "matchAll", "replace", "search", "species", "split", "toPrimitive", "toStringTag", "unscopables", "dispose", "asyncDispose" }) |name| {
        // Reuse the creating realm's symbol (shared across realms) when present,
        // else mint a fresh one. Sharing means `realmA.Symbol.iterator ===
        // realmB.Symbol.iterator` and every `@@`-keyed built-in method in this
        // realm is keyed under the same symbol.
        const sym: Value = if (parent_symbol != null and parent_symbol.?.getOwn(name) != null)
            parent_symbol.?.getOwn(name).?
        else
            try makeSymbolObj(a, root_shape, "Symbol." ++ name, symbol_proto);
        try symbol_ns.setOwn(a, root_shape, name, sym);
        try symbol_ns.setAttr(a, name, .{ .writable = false, .enumerable = false, .configurable = false });
    }
    // Symbol.prototype[@@toPrimitive] (a method) and [@@toStringTag] ("Symbol").
    if (symbol_ns.getOwn("toPrimitive")) |tp| if (tp == .object) {
        const fnobj = try a.create(value.Object);
        fnobj.* = .{ .native = symbolToPrimitiveFn };
        try installNativeProps(a, root_shape, fnobj, "[Symbol.toPrimitive]", 1);
        try symbol_proto.setOwn(a, root_shape, tp.object.sym_key, .{ .object = fnobj });
        try symbol_proto.setAttr(a, tp.object.sym_key, .{ .writable = false, .enumerable = false, .configurable = true });
    };
    if (symbol_ns.getOwn("toStringTag")) |tst| if (tst == .object) {
        try symbol_proto.setOwn(a, root_shape, tst.object.sym_key, .{ .string = "Symbol" });
        try symbol_proto.setAttr(a, tst.object.sym_key, .{ .writable = false, .enumerable = false, .configurable = true });
    };
    try env.put("Symbol", .{ .object = symbol_ns });

    // Function.prototype[Symbol.hasInstance] — a {!w,!e,!c} method backing the
    // ordinary `instanceof` (installed now that the well-known symbol exists).
    if (symbol_ns.getOwn("hasInstance")) |hi| if (hi == .object) {
        if (func_proto.getOwn(hi.object.sym_key) == null) {
            const m = try a.create(value.Object);
            m.* = .{ .native = functionHasInstanceFn };
            try installNativeProps(a, root_shape, m, "[Symbol.hasInstance]", 1);
            try func_proto.setOwn(a, root_shape, hi.object.sym_key, .{ .object = m });
            try func_proto.setAttr(a, hi.object.sym_key, .{ .writable = false, .enumerable = false, .configurable = false });
        }
    };

    // `Constructor[Symbol.species]` — a getter returning the receiver, so a
    // subclass's SpeciesConstructor is the subclass itself. Installed on every
    // constructor the spec gives a species slot, now that the well-known symbol
    // and the constructors all exist. {enumerable:false, configurable:true}.
    if (symbol_ns.getOwn("species")) |sp| if (sp == .object) {
        const skey = sp.object.sym_key;
        inline for (.{ "Promise", "Array", "Map", "Set", "RegExp", "ArrayBuffer" }) |ctor_name| {
            if (env.get(ctor_name)) |cv| if (cv == .object) {
                const getter = try a.create(value.Object);
                getter.* = .{ .native = returnThisFn };
                try installNativeProps(a, root_shape, getter, "get [Symbol.species]", 0);
                try cv.object.setAccessor(a, skey, .{ .object = getter }, null);
                try cv.object.setAttr(a, skey, .{ .enumerable = false, .configurable = true });
            };
        }
    };

    // Proxy (constructor) + Proxy.revocable.
    const proxy_ns = try a.create(value.Object);
    proxy_ns.* = .{ .native = proxyConstructorFn, .native_ctor = true };
    try installNativeProps(a, root_shape, proxy_ns, "Proxy", 2);
    try setNative(a, root_shape, proxy_ns, "revocable", 2, proxyRevocableFn);
    try env.put("Proxy", .{ .object = proxy_ns });

    // Reflect — the static reflection namespace.
    const reflect_ns = try a.create(value.Object);
    reflect_ns.* = .{};
    try setNative(a, root_shape, reflect_ns, "get", 2, reflectGetFn);
    try setNative(a, root_shape, reflect_ns, "set", 3, reflectSetFn);
    try setNative(a, root_shape, reflect_ns, "has", 2, reflectHasFn);
    try setNative(a, root_shape, reflect_ns, "deleteProperty", 2, reflectDeleteFn);
    try setNative(a, root_shape, reflect_ns, "ownKeys", 1, reflectOwnKeysFn);
    try setNative(a, root_shape, reflect_ns, "getPrototypeOf", 1, reflectGetProtoFn);
    try setNative(a, root_shape, reflect_ns, "setPrototypeOf", 2, builtins.objectSetPrototypeOf);
    try setNative(a, root_shape, reflect_ns, "apply", 3, reflectApplyFn);
    try setNative(a, root_shape, reflect_ns, "construct", 2, reflectConstructFn);
    try setNative(a, root_shape, reflect_ns, "defineProperty", 3, builtins.objectDefineProperty);
    try setNative(a, root_shape, reflect_ns, "getOwnPropertyDescriptor", 2, builtins.objectGetOwnPropertyDescriptor);
    try setNative(a, root_shape, reflect_ns, "isExtensible", 1, builtins.objectIsExtensible);
    try setNative(a, root_shape, reflect_ns, "preventExtensions", 1, builtins.objectPreventExtensions);
    try env.put("Reflect", .{ .object = reflect_ns });

    // `Array.prototype[Symbol.iterator]` as a real, deletable/overridable own
    // property (the native array-values iterator). The iteration paths consult
    // this slot, so `delete`/reassigning it changes how arrays destructure /
    // spread / `for-of`. (Symbol must already exist, hence after its setup.)
    if (symbol_ns.getOwn("iterator")) |it_sym| {
        if (it_sym == .object and it_sym.object.is_symbol) {
            const it_fn = try a.create(value.Object);
            it_fn.* = .{ .native = arrayValuesIterFn };
            try installFunctionProps(a, root_shape, it_fn, &.{}, "[Symbol.iterator]");
            try array_proto.setOwn(a, root_shape, it_sym.object.sym_key, .{ .object = it_fn });
            try array_proto.setAttr(a, it_sym.object.sym_key, .{ .writable = true, .enumerable = false, .configurable = true });
        }
    }

    // Date — callable + constructable, with Date.now and a prototype.
    const date_ns = try a.create(value.Object);
    date_ns.* = .{ .native = dateConstructor, .native_ctor = true };
    try installNativeProps(a, root_shape, date_ns, "Date", 7);
    try setNative(a, root_shape, date_ns, "now", 0, dateNow);
    try setNative(a, root_shape, date_ns, "UTC", 7, dateUTCFn);
    const date_proto = try a.create(value.Object);
    date_proto.* = .{ .proto = object_proto };
    try setDateProtoMethods(a, root_shape, date_proto, .{
        .{ "getTime", 0 },      .{ "valueOf", 0 },      .{ "setTime", 1 },      .{ "toISOString", 0 },
        .{ "toUTCString", 0 },  .{ "getFullYear", 0 },  .{ "getUTCFullYear", 0 },
        .{ "getMonth", 0 },     .{ "getUTCMonth", 0 },  .{ "getDate", 0 },      .{ "getUTCDate", 0 },
        .{ "getDay", 0 },       .{ "getUTCDay", 0 },    .{ "getHours", 0 },     .{ "getUTCHours", 0 },
        .{ "getMinutes", 0 },   .{ "getUTCMinutes", 0 }, .{ "getSeconds", 0 },  .{ "getUTCSeconds", 0 },
        .{ "getMilliseconds", 0 }, .{ "getUTCMilliseconds", 0 }, .{ "getTimezoneOffset", 0 },
        .{ "setFullYear", 3 },  .{ "setUTCFullYear", 3 }, .{ "setMonth", 2 },   .{ "setUTCMonth", 2 },
        .{ "setDate", 1 },      .{ "setUTCDate", 1 },   .{ "setHours", 4 },     .{ "setUTCHours", 4 },
        .{ "setMinutes", 3 },   .{ "setUTCMinutes", 3 }, .{ "setSeconds", 2 },  .{ "setUTCSeconds", 2 },
        .{ "setMilliseconds", 1 }, .{ "setUTCMilliseconds", 1 },
        .{ "toString", 0 },     .{ "toDateString", 0 }, .{ "toTimeString", 0 }, .{ "toGMTString", 0 },
        .{ "toLocaleString", 0 }, .{ "toLocaleDateString", 0 }, .{ "toLocaleTimeString", 0 },
    });
    // Date.prototype.toJSON is intentionally *generic* (works on any object),
    // not brand-checked: ToObject(this), ToPrimitive(number); a non-finite value
    // returns null, otherwise Invoke(O, "toISOString").
    try setNative(a, root_shape, date_proto, "toJSON", 1, dateToJSONFn);
    try date_ns.setOwn(a, root_shape, "prototype", .{ .object = date_proto });
    try date_ns.setAttr(a, "prototype", .{ .writable = false, .enumerable = false, .configurable = false });
    try setConstructor(a, root_shape, date_proto, date_ns);
    try env.put("Date", .{ .object = date_ns });

    // ArrayBuffer + typed arrays last, after Object.prototype exists.
    try installTypedArrays(env, root_shape);

    // BigInt (a callable, non-constructor) + its prototype/statics.
    {
        const bi_proto = try a.create(value.Object);
        bi_proto.* = .{ .proto = object_proto };
        try setNative(a, root_shape, bi_proto, "toString", 0, bigIntToStringFn);
        try setNative(a, root_shape, bi_proto, "valueOf", 0, bigIntValueOfFn);
        try setNative(a, root_shape, bi_proto, "toLocaleString", 0, bigIntToLocaleStringFn);
        // BigInt.prototype[Symbol.toStringTag] = "BigInt" (so
        // `Object.prototype.toString.call(1n)` → "[object BigInt]").
        if (env.get("Symbol")) |sym| if (sym == .object) {
            if (sym.object.getOwn("toStringTag")) |tt| if (tt == .object and tt.object.is_symbol) {
                try bi_proto.setOwn(a, root_shape, tt.object.sym_key, .{ .string = "BigInt" });
                try bi_proto.setAttr(a, tt.object.sym_key, .{ .writable = false, .enumerable = false, .configurable = true });
            };
        };
        const bi_ns = try a.create(value.Object);
        bi_ns.* = .{ .native = bigIntFn };
        try installNativeProps(a, root_shape, bi_ns, "BigInt", 1);
        try setNative(a, root_shape, bi_ns, "asIntN", 2, bigIntAsIntNFn(true));
        try setNative(a, root_shape, bi_ns, "asUintN", 2, bigIntAsIntNFn(false));
        try bi_ns.setOwn(a, root_shape, "prototype", .{ .object = bi_proto });
        try bi_ns.setAttr(a, "prototype", .{ .writable = false, .enumerable = false, .configurable = false });
        try setConstructor(a, root_shape, bi_proto, bi_ns);
        try env.put("BigInt", .{ .object = bi_ns });
    }

    // The test262 `$262` host object (its `global` is set by the realm owner).
    try install262(env, root_shape, object_proto);
}

/// `next()` for a `makeCursorIterator` object: yields successive elements of the
/// captured array/string, then `{ done: true }`.
/// `Array.prototype[Symbol.iterator]` / `Array.prototype.values`: returns a
/// fresh index cursor over `this`. Installed as a real own property so it can be
/// deleted or replaced; the iteration paths recognize this exact native to take
/// their fast index path.
fn arrayValuesIterFn(ctx: *anyopaque, this: Value, args: []const Value) value.HostError!Value {
    _ = args;
    const self: *Interpreter = @ptrCast(@alignCast(ctx));
    return self.makeCursorIterator(this);
}

fn cursorIterNext(ctx: *anyopaque, this: Value, args: []const Value) value.HostError!Value {
    _ = args;
    const self: *Interpreter = @ptrCast(@alignCast(ctx));
    if (this != .object) return self.throwError("TypeError", "next called on non-object");
    const o = this.object;
    const src = o.getOwn("__src") orelse Value.undefined;
    const i = toLen((o.getOwn("__i") orelse Value{ .number = 0 }).number);
    var done = true;
    var val: Value = .undefined;
    switch (src) {
        .object => |so| if (so.is_array) {
            // Arrays iterate the *logical* length, reading via [[Get]] so a hole
            // (or the sparse tail) yields `undefined` and accessor indices run.
            if (i < @max(so.elements.items.len, so.array_len)) {
                val = try self.arrIndexGet(so, i);
                done = false;
            }
        } else if ((so.is_set or so.is_map) and i < so.elements.items.len) {
            // Sets yield each element; Maps yield each stored `[k,v]` pair.
            val = so.elements.items[i];
            done = false;
        },
        .string => |s| if (i < s.len) {
            val = .{ .string = try self.arena.dupe(u8, s[i .. i + 1]) };
            done = false;
        },
        else => {},
    }
    if (!done) try self.setProp(o, "__i", .{ .number = @floatFromInt(i + 1) });
    const res = try self.newObject();
    try self.setMember(res, "value", val);
    try self.setMember(res, "done", .{ .boolean = done });
    return res;
}

/// Install the `length` and `name` own properties on a function object, per the
/// spec: both are `{ writable: false, enumerable: false, configurable: true }`.
/// `length` is the count of parameters before the first one that has a default
/// value or is a rest (`...`) parameter; `name` is the function's name ("" for an
/// anonymous function expression). test262's propertyHelper + countless
/// `fn.name`/`fn.length` assertions depend on these existing as own properties.
pub fn installFunctionProps(
    arena: std.mem.Allocator,
    root_shape: *Shape,
    obj: *value.Object,
    params: []const ast.Param,
    name: []const u8,
) EvalError!void {
    var len: usize = 0;
    for (params) |p| {
        if (p.is_rest or p.default != null) break;
        len += 1;
    }
    const ro_attr: value.PropAttr = .{ .writable = false, .enumerable = false, .configurable = true };
    try obj.setOwn(arena, root_shape, "length", .{ .number = @floatFromInt(len) });
    try obj.setAttr(arena, "length", ro_attr);
    try obj.setOwn(arena, root_shape, "name", .{ .string = name });
    try obj.setAttr(arena, "name", ro_attr);
}

/// Install the `name` and `length` own properties on a *native* (built-in)
/// function object, per the spec: both are
/// `{ writable: false, enumerable: false, configurable: true }`. `name` is the
/// property the function is reached through; `length` is its spec arity. Mirrors
/// `installFunctionProps` for user functions — test262's propertyHelper checks
/// `name.js` / `length.js` for essentially every built-in method.
fn installNativeProps(a: std.mem.Allocator, rs: *Shape, obj: *value.Object, name: []const u8, len: usize) EvalError!void {
    const ro_attr: value.PropAttr = .{ .writable = false, .enumerable = false, .configurable = true };
    try obj.setOwn(a, rs, "length", .{ .number = @floatFromInt(len) });
    try obj.setAttr(a, "length", ro_attr);
    try obj.setOwn(a, rs, "name", .{ .string = name });
    try obj.setAttr(a, "name", ro_attr);
}

fn defineGlobalFn(env: *Environment, rs: *Shape, name: []const u8, len: usize, f: value.NativeFn) EvalError!void {
    try defineGlobalFnC(env, rs, name, len, false, f);
}

fn defineGlobalFnC(env: *Environment, rs: *Shape, name: []const u8, len: usize, is_ctor: bool, f: value.NativeFn) EvalError!void {
    const o = try env.arena.create(value.Object);
    o.* = .{ .native = f, .native_ctor = is_ctor };
    try installNativeProps(env.arena, rs, o, name, len);
    // A constructor's `.prototype` is an own, non-writable/-enumerable/
    // -configurable data property (so `getOwnPropertyDescriptor(C, "prototype")`
    // and reflection see it). Methods still dispatch via `builtinMethod`, and
    // `instanceof` keeps working through its `ctor_ref`/`error_ctor` fallbacks.
    if (is_ctor) {
        const proto = try env.arena.create(value.Object);
        proto.* = .{};
        try setConstructor(env.arena, rs, proto, o);
        try o.setOwn(env.arena, rs, "prototype", .{ .object = proto });
        try o.setAttr(env.arena, "prototype", .{ .writable = false, .enumerable = false, .configurable = false });
    }
    try env.put(name, .{ .object = o });
}

fn setNative(a: std.mem.Allocator, root_shape: *Shape, obj: *value.Object, name: []const u8, len: usize, f: value.NativeFn) EvalError!void {
    const m = try a.create(value.Object);
    m.* = .{ .native = f };
    try installNativeProps(a, root_shape, m, name, len);
    try obj.setOwn(a, root_shape, name, .{ .object = m });
    // Built-in methods/statics are non-enumerable (writable + configurable), per
    // spec — so `Object.keys`/`for-in` skip them and verifyProperty is satisfied.
    try obj.setAttr(a, name, .{ .enumerable = false, .configurable = true, .writable = true });
}

/// A prototype-object method: a native thunk that routes to the existing
/// `builtinMethod` dispatch using `this`. Lets `X.prototype.method` be a real
/// property whose value is callable (and `.call`/`.bind` work on it via the
/// universal callable dispatch) — what test262's propertyHelper relies on.
fn protoMethod(comptime name: []const u8) value.NativeFn {
    return struct {
        fn call(ctx: *anyopaque, this: Value, args: []const Value) value.HostError!Value {
            const self: *Interpreter = @ptrCast(@alignCast(ctx));
            // Every Object/Array/String prototype method routed here begins with
            // RequireObjectCoercible/ToObject(this), so a null or undefined
            // receiver is a TypeError (e.g. `Array.prototype.map.call(undefined)`).
            // `Object.prototype.toString` — the one method that tolerates them —
            // is installed separately, not through here.
            if (this == .null or this == .undefined)
                return self.throwError("TypeError", "Cannot convert undefined or null to object");
            return (try self.builtinMethod(this, name, args)) orelse .undefined;
        }
    }.call;
}

/// Install a set of prototype methods, each given as a `.{ name, arity }` tuple
/// so the spec `length` is carried onto every method (the same name can have a
/// different arity on different prototypes — e.g. `toString`).
fn setProtoMethods(a: std.mem.Allocator, rs: *Shape, proto: *value.Object, comptime specs: anytype) EvalError!void {
    inline for (specs) |s| try setNative(a, rs, proto, s[0], s[1], protoMethod(s[0]));
}

/// Install Array.prototype methods that dispatch straight to `arrayMethod` after
/// ToObject(this). Going direct (rather than through `builtinMethod`'s
/// name-keyed dispatch) makes a *borrowed* generic method work — e.g. `obj.slice
/// = Array.prototype.slice; obj.slice(0, 3)` — where `obj` has an own property of
/// that name (which would otherwise suppress the array-generic path).
fn setArrayProtoMethods(a: std.mem.Allocator, rs: *Shape, proto: *value.Object, comptime specs: anytype) EvalError!void {
    inline for (specs) |s| try setNative(a, rs, proto, s[0], s[1], arrayProtoMethod(s[0]));
}

fn arrayProtoMethod(comptime name: []const u8) value.NativeFn {
    return struct {
        fn call(ctx: *anyopaque, this: Value, args: []const Value) value.HostError!Value {
            const self: *Interpreter = @ptrCast(@alignCast(ctx));
            if (this == .null or this == .undefined)
                return self.throwError("TypeError", "Array.prototype." ++ name ++ " called on null or undefined");
            const o = try self.toObject(this);
            if (try self.arrayMethod(o, name, args)) |r| return r;
            // `toString`/`toLocaleString` aren't in `arrayMethod`; fall back to the
            // generic dispatcher (which reaches Object.prototype.toString etc.).
            return (try self.builtinMethod(.{ .object = o }, name, args)) orelse .undefined;
        }
    }.call;
}

/// `Function.prototype` is itself a built-in function that ignores its arguments
/// and returns undefined (so `typeof Function.prototype === "function"`).
fn funcProtoNoop(ctx: *anyopaque, this: Value, args: []const Value) value.HostError!Value {
    _ = ctx;
    _ = this;
    _ = args;
    return .undefined;
}

/// The `%ThrowTypeError%` intrinsic — the shared poison-pill backing the
/// `caller`/`arguments` accessors on `Function.prototype` (and the strict /
/// bound restricted properties). Always throws a TypeError.
fn throwTypeErrorFn(ctx: *anyopaque, this: Value, args: []const Value) value.HostError!Value {
    _ = this;
    _ = args;
    const self: *Interpreter = @ptrCast(@alignCast(ctx));
    return self.throwError("TypeError", "'caller', 'callee', and 'arguments' properties may not be accessed on strict mode functions or the arguments objects for calls to them");
}

/// A generic `String.prototype` method: RequireObjectCoercible(this) then
/// `ToString(this)` (running user `toString`/`valueOf`, propagating throws, and
/// rejecting Symbols), then dispatch to `stringMethod`. Installing these as a
/// String-specific thunk (rather than the name-ambiguous `protoMethod`) means
/// `String.prototype.slice.call(obj)` uses *String* slice, not Array slice.
fn stringProtoMethod(comptime name: []const u8) value.NativeFn {
    return struct {
        fn call(ctx: *anyopaque, this: Value, args: []const Value) value.HostError!Value {
            const self: *Interpreter = @ptrCast(@alignCast(ctx));
            if (this == .null or this == .undefined)
                return self.throwError("TypeError", "String.prototype." ++ name ++ " called on null or undefined");
            const s = try self.toStringV(this);
            return (try self.stringMethod(s, name, args)) orelse .undefined;
        }
    }.call;
}

/// `String.prototype.toString`/`valueOf`: a brand check — the receiver must be a
/// String primitive or a String wrapper (else a TypeError), returning the
/// underlying string (these do NOT ToString an arbitrary `this`).
fn stringValueMethod(ctx: *anyopaque, this: Value, args: []const Value) value.HostError!Value {
    _ = args;
    const self: *Interpreter = @ptrCast(@alignCast(ctx));
    const s: []const u8 = switch (this) {
        .string => |str| str,
        .object => |o| if (o.prim != null and o.prim.? == .string) o.prim.?.string else return self.throwError("TypeError", "String.prototype.toString/valueOf called on a non-String"),
        else => return self.throwError("TypeError", "String.prototype.toString/valueOf called on a non-String"),
    };
    return .{ .string = s };
}

/// A `Function.prototype` method (`call`/`apply`/`bind`/`toString`) that first
/// requires `this` to be callable (a TypeError otherwise — `IsCallable`), then
/// dispatches to the shared `builtinMethod`.
fn funcProtoMethod(comptime name: []const u8) value.NativeFn {
    return struct {
        fn call(ctx: *anyopaque, this: Value, args: []const Value) value.HostError!Value {
            const self: *Interpreter = @ptrCast(@alignCast(ctx));
            if (!(this == .object and this.object.isCallableObject()))
                return self.throwError("TypeError", "Function.prototype." ++ name ++ " requires that 'this' be callable");
            return (try self.builtinMethod(this, name, args)) orelse .undefined;
        }
    }.call;
}

/// A `Date.prototype` method that brand-checks `this` (a TypeError otherwise),
/// then dispatches to `dateMethod`.
fn dateProtoMethod(comptime name: []const u8) value.NativeFn {
    return struct {
        fn call(ctx: *anyopaque, this: Value, args: []const Value) value.HostError!Value {
            const self: *Interpreter = @ptrCast(@alignCast(ctx));
            if (this != .object or !this.object.is_date)
                return self.throwError("TypeError", "Date.prototype method called on a non-Date");
            return (try self.dateMethod(this.object, name, args)) orelse .undefined;
        }
    }.call;
}

fn setDateProtoMethods(a: std.mem.Allocator, rs: *Shape, proto: *value.Object, comptime specs: anytype) EvalError!void {
    inline for (specs) |s| try setNative(a, rs, proto, s[0], s[1], dateProtoMethod(s[0]));
}

/// `Date.prototype.toJSON(key)` — generic (no [[DateValue]] brand check):
/// ToObject(this), ToPrimitive(O, number); a non-finite primitive returns null,
/// otherwise `Invoke(O, "toISOString")` (which need not be the built-in).
fn dateToJSONFn(ctx: *anyopaque, this: Value, args: []const Value) value.HostError!Value {
    _ = args;
    const self: *Interpreter = @ptrCast(@alignCast(ctx));
    const o = try self.toObject(this); // null/undefined throw
    // ToPrimitive(O, number); a non-finite *Number* result returns null. For a
    // Date the numeric primitive is its [[DateValue]] (the engine's `toPrimitive`
    // skips the native valueOf, so read it directly); other objects observe
    // their own valueOf/toString.
    if (o.is_date) {
        if (!std.math.isFinite(o.date_ms)) return .null;
    } else {
        const tv = try self.toPrimitive(.{ .object = o }, .number);
        if (tv == .number and !std.math.isFinite(tv.number)) return .null;
    }
    const iso = try self.getProperty(.{ .object = o }, "toISOString");
    if (!iso.isCallable()) return self.throwError("TypeError", "toISOString is not callable");
    return self.callValueWithThis(iso, &.{}, .{ .object = o });
}

/// A `Set.prototype` method that brand-checks `this` then dispatches to
/// `setMethod` — making the methods real own properties of `Set.prototype` (so
/// reflection and `Set.prototype.m.call(...)` work) on top of the existing
/// instance dispatch.
fn setProtoMethod(comptime name: []const u8, comptime weak: bool) value.NativeFn {
    return struct {
        fn call(ctx: *anyopaque, this: Value, args: []const Value) value.HostError!Value {
            const self: *Interpreter = @ptrCast(@alignCast(ctx));
            // A WeakSet shares `is_set` with a Set, so the brand check also
            // requires the weakness to match (a Set method rejects a WeakSet and
            // vice versa).
            if (this != .object or !this.object.is_set or this.object.is_weak != weak)
                return self.throwError("TypeError", if (weak) "WeakSet.prototype method called on an incompatible receiver" else "Set.prototype method called on a non-Set");
            return (try self.setMethod(this.object, name, args)) orelse .undefined;
        }
    }.call;
}

/// A `Number.prototype` method: extracts the number from `this` (a number
/// primitive or a Number wrapper), throws TypeError otherwise, then dispatches
/// to `numberMethod`. Makes the methods real own properties (reflection) and
/// brand-checks the receiver.
fn numberProtoMethod(comptime name: []const u8) value.NativeFn {
    return struct {
        fn call(ctx: *anyopaque, this: Value, args: []const Value) value.HostError!Value {
            const self: *Interpreter = @ptrCast(@alignCast(ctx));
            const n: f64 = switch (this) {
                .number => |x| x,
                .object => |o| if (o.prim != null and o.prim.? == .number) o.prim.?.number else return self.throwError("TypeError", "Number.prototype method called on a non-Number"),
                else => return self.throwError("TypeError", "Number.prototype method called on a non-Number"),
            };
            return (try self.numberMethod(n, name, args)) orelse .undefined;
        }
    }.call;
}

/// A brand-checked `Map.prototype` method dispatching to `mapMethod`.
fn mapProtoMethod(comptime name: []const u8, comptime weak: bool) value.NativeFn {
    return struct {
        fn call(ctx: *anyopaque, this: Value, args: []const Value) value.HostError!Value {
            const self: *Interpreter = @ptrCast(@alignCast(ctx));
            // A WeakMap shares `is_map` with a Map, so the brand check also
            // requires the weakness to match (a Map method rejects a WeakMap and
            // vice versa).
            if (this != .object or !this.object.is_map or this.object.is_weak != weak)
                return self.throwError("TypeError", if (weak) "WeakMap.prototype method called on an incompatible receiver" else "Map.prototype method called on a non-Map");
            return (try self.mapMethod(this.object, name, args)) orelse .undefined;
        }
    }.call;
}

/// `Map.prototype.size` / `Set.prototype.size` — an accessor getter (not an own
/// data property of instances) returning the live entry count; brand-checked so
/// it rejects a WeakMap/WeakSet or any non-collection receiver.
fn collectionSizeGetter(comptime is_set_kind: bool) value.NativeFn {
    return struct {
        fn call(ctx: *anyopaque, this: Value, args: []const Value) value.HostError!Value {
            _ = args;
            const self: *Interpreter = @ptrCast(@alignCast(ctx));
            const ok = this == .object and !this.object.is_weak and
                (if (is_set_kind) this.object.is_set else this.object.is_map);
            if (!ok) return self.throwError("TypeError", if (is_set_kind) "Set.prototype.size getter called on a non-Set" else "Map.prototype.size getter called on a non-Map");
            return .{ .number = @floatFromInt(this.object.elements.items.len) };
        }
    }.call;
}

/// Install an accessor property `prop` on `obj` whose getter is the native `f`
/// (a function named "get <prop>" with length 0, per spec), non-enumerable and
/// configurable.
fn setNativeGetter(a: std.mem.Allocator, rs: *Shape, obj: *value.Object, comptime prop: []const u8, f: value.NativeFn) EvalError!void {
    const g = try a.create(value.Object);
    g.* = .{ .native = f };
    try installNativeProps(a, rs, g, "get " ++ prop, 0);
    try obj.setAccessor(a, prop, .{ .object = g }, null);
    try obj.setAttr(a, prop, .{ .enumerable = false, .configurable = true });
}

/// Install `ArrayBuffer` and the typed-array constructors (`Int8Array` …
/// `Float64Array`), sharing one `%TypedArray%.prototype` for the methods.
fn installTypedArrays(env: *Environment, rs: *Shape) EvalError!void {
    const a = env.arena;
    const obj_ctor = env.get("Object") orelse return;
    if (obj_ctor != .object) return;
    const op = obj_ctor.object.getOwn("prototype") orelse return;
    if (op != .object) return;
    const object_proto = op.object;

    // ArrayBuffer.
    const ab_proto = try a.create(value.Object);
    ab_proto.* = .{ .proto = object_proto };
    try setNative(a, rs, ab_proto, "slice", 2, arrayBufferSliceFn);
    const ab_ctor = try a.create(value.Object);
    ab_ctor.* = .{ .native = arrayBufferConstructorFn, .native_ctor = true };
    try installNativeProps(a, rs, ab_ctor, "ArrayBuffer", 1);
    try setNative(a, rs, ab_ctor, "isView", 1, arrayBufferIsViewFn);
    try ab_ctor.setOwn(a, rs, "prototype", .{ .object = ab_proto });
    try ab_ctor.setAttr(a, "prototype", .{ .writable = false, .enumerable = false, .configurable = false });
    try setConstructor(a, rs, ab_proto, ab_ctor);
    try env.put("ArrayBuffer", .{ .object = ab_ctor });

    // %TypedArray%.prototype — shared methods for every view kind.
    const ta_proto = try a.create(value.Object);
    ta_proto.* = .{ .proto = object_proto };
    inline for (.{
        .{ "at", 1 },      .{ "join", 1 },    .{ "forEach", 1 }, .{ "map", 1 },
        .{ "filter", 1 },  .{ "some", 1 },    .{ "every", 1 },   .{ "find", 1 },
        .{ "findIndex", 1 }, .{ "reduce", 1 }, .{ "indexOf", 1 }, .{ "lastIndexOf", 1 },
        .{ "includes", 1 }, .{ "fill", 1 },   .{ "reverse", 0 }, .{ "slice", 2 },
        .{ "subarray", 2 }, .{ "set", 1 },    .{ "toString", 0 }, .{ "keys", 0 },
        .{ "values", 0 },   .{ "entries", 0 },
    }) |s| try setNative(a, rs, ta_proto, s[0], s[1], taProtoMethod(s[0]));

    inline for (.{
        value.TAKind.i8,  value.TAKind.u8,  value.TAKind.u8c,
        value.TAKind.i16, value.TAKind.u16, value.TAKind.i32,
        value.TAKind.u32, value.TAKind.f32, value.TAKind.f64,
    }) |kind| {
        const proto = try a.create(value.Object);
        proto.* = .{ .proto = ta_proto };
        try proto.setOwn(a, rs, "BYTES_PER_ELEMENT", .{ .number = @floatFromInt(kind.byteSize()) });
        try proto.setAttr(a, "BYTES_PER_ELEMENT", .{ .writable = false, .enumerable = false, .configurable = false });
        const ctor = try a.create(value.Object);
        ctor.* = .{ .native = typedArrayCtorFn(kind), .native_ctor = true };
        try installNativeProps(a, rs, ctor, kind.ctorName(), 3);
        try ctor.setOwn(a, rs, "BYTES_PER_ELEMENT", .{ .number = @floatFromInt(kind.byteSize()) });
        try ctor.setAttr(a, "BYTES_PER_ELEMENT", .{ .writable = false, .enumerable = false, .configurable = false });
        try ctor.setOwn(a, rs, "prototype", .{ .object = proto });
        try ctor.setAttr(a, "prototype", .{ .writable = false, .enumerable = false, .configurable = false });
        try setConstructor(a, rs, proto, ctor);
        try env.put(kind.ctorName(), .{ .object = ctor });
    }

    try installDataView(env, rs, object_proto);
}

fn installMapProto(env: *Environment, rs: *Shape) EvalError!void {
    const a = env.arena;
    const ctor = env.get("Map") orelse return;
    if (ctor != .object) return;
    const proto_v = ctor.object.getOwn("prototype") orelse return;
    if (proto_v != .object) return;
    const p = proto_v.object;
    const specs = .{
        .{ "set", 2 },     .{ "get", 1 },     .{ "has", 1 },      .{ "delete", 1 },
        .{ "clear", 0 },   .{ "forEach", 1 }, .{ "keys", 0 },     .{ "values", 0 },
        .{ "entries", 0 }, .{ "getOrInsert", 2 }, .{ "getOrInsertComputed", 2 },
    };
    inline for (specs) |s| try setNative(a, rs, p, s[0], s[1], mapProtoMethod(s[0], false));
    try setNativeGetter(a, rs, p, "size", collectionSizeGetter(false));
}

/// Install the Set.prototype methods (real, brand-checked own properties) on
/// the prototype of the `Set` constructor in `env`.
fn installSetProto(env: *Environment, rs: *Shape) EvalError!void {
    const a = env.arena;
    const ctor = env.get("Set") orelse return;
    if (ctor != .object) return;
    const proto_v = ctor.object.getOwn("prototype") orelse return;
    if (proto_v != .object) return;
    const p = proto_v.object;
    const specs = .{
        .{ "add", 1 },       .{ "has", 1 },          .{ "delete", 1 },     .{ "clear", 0 },
        .{ "forEach", 1 },   .{ "values", 0 },       .{ "keys", 0 },       .{ "entries", 0 },
        .{ "union", 1 },     .{ "intersection", 1 }, .{ "difference", 1 }, .{ "symmetricDifference", 1 },
        .{ "isSubsetOf", 1 }, .{ "isSupersetOf", 1 }, .{ "isDisjointFrom", 1 },
    };
    inline for (specs) |s| try setNative(a, rs, p, s[0], s[1], setProtoMethod(s[0], false));
    try setNativeGetter(a, rs, p, "size", collectionSizeGetter(true));
}

/// Monotonic id for unique Symbol property-key encodings (single-threaded;
/// test262 workers are separate processes).
var symbol_counter: usize = 0;

/// Create a Symbol object: a tagged object with a unique `sym_key` (a NUL-led
/// string that can't collide with user property names) and a `description`.
fn makeSymbolObj(a: std.mem.Allocator, rs: *Shape, desc: ?[]const u8, proto: ?*value.Object) EvalError!Value {
    _ = rs;
    const o = try a.create(value.Object);
    o.* = .{ .is_symbol = true, .proto = proto, .sym_desc = desc };
    symbol_counter += 1;
    o.sym_key = try std.fmt.allocPrint(a, "\x00s{d}", .{symbol_counter});
    return .{ .object = o };
}

/// `Symbol.prototype`, resolved from the live `Symbol` binding (for linking
/// runtime-created symbols to it). Null only before globals are installed.
fn symbolProto(self: *Interpreter) ?*value.Object {
    const sym = self.env.get("Symbol") orelse return null;
    if (sym != .object) return null;
    const p = sym.object.getOwn("prototype") orelse return null;
    return if (p == .object) p.object else null;
}

/// `Date(...)` / `new Date(...)` → a Date object for the computed time.
fn dateConstructor(ctx: *anyopaque, this: Value, args: []const Value) value.HostError!Value {
    _ = this;
    const self: *Interpreter = @ptrCast(@alignCast(ctx));
    if (args.len >= 2) {
        // Multi-component form: ToNumber each component once (invoking valueOf),
        // with years 0–99 mapped to 1900–1999.
        const buf = try self.arena.alloc(Value, args.len);
        for (args, 0..) |av, i| buf[i] = .{ .number = (try self.toPrimitive(av, .number)).toNumber() };
        const yi = @trunc(buf[0].number);
        if (yi >= 0 and yi <= 99) buf[0] = .{ .number = yi + 1900 };
        return self.makeDate(Interpreter.dateTimeFromArgs(buf));
    }
    if (args.len == 1) {
        // `new Date(dateObject)` copies its time value; otherwise ToPrimitive
        // (a string would be parsed — not yet — else ToNumber).
        if (args[0] == .object and args[0].object.is_date)
            return self.makeDate(args[0].object.date_ms);
        const prim = try self.toPrimitive(args[0], .default);
        if (prim == .string) return self.makeDate(Interpreter.dateTimeFromArgs(&.{prim}));
        return self.makeDate(prim.toNumber());
    }
    return self.makeDate(0);
}

/// `Date.UTC(year [, month, day, hours, min, sec, ms])` — the time value for
/// the given UTC date components (NaN if any component is NaN; years 0–99 map
/// to 1900–1999).
fn dateUTCFn(ctx: *anyopaque, this: Value, args: []const Value) value.HostError!Value {
    _ = ctx;
    _ = this;
    if (args.len == 0) return .{ .number = std.math.nan(f64) };
    const n = @min(args.len, 7);
    var buf: [7]Value = undefined;
    for (0..n) |i| {
        const num = args[i].toNumber();
        if (std.math.isNan(num)) return .{ .number = std.math.nan(f64) };
        buf[i] = .{ .number = num };
    }
    // Years 0–99 are offset to 1900–1999.
    const yi = @trunc(buf[0].number);
    if (yi >= 0 and yi <= 99) buf[0] = .{ .number = yi + 1900 };
    var len = n;
    if (len == 1) {
        buf[1] = .{ .number = 0 };
        len = 2;
    }
    return .{ .number = Interpreter.dateTimeFromArgs(buf[0..len]) };
}

/// `Date.now()` — v1 uses a deterministic epoch (no wall clock wired).
fn dateNow(ctx: *anyopaque, this: Value, args: []const Value) value.HostError!Value {
    _ = ctx;
    _ = this;
    _ = args;
    return .{ .number = 0 };
}

/// `Symbol([description])` — returns a fresh unique symbol (not constructable).
fn symbolFn(ctx: *anyopaque, this: Value, args: []const Value) value.HostError!Value {
    _ = this;
    const self: *Interpreter = @ptrCast(@alignCast(ctx));
    // `description` is ToString'd (via ToPrimitive with the string hint, so a
    // `{toString}`/`{valueOf}` object is honored); `undefined` means none.
    const desc: ?[]const u8 = if (args.len > 0 and args[0] != .undefined)
        try (try self.toPrimitive(args[0], .string)).toString(self.arena)
    else
        null;
    return makeSymbolObj(self.arena, self.root_shape, desc, symbolProto(self));
}

/// The cross-realm GlobalSymbolRegistry, kept as a hidden object on the `Symbol`
/// constructor (key → symbol). The Context's `Symbol` binding persists across
/// `evaluate` calls, so the registry does too. NUL-prefixed so it never shows
/// up in enumeration.
fn symbolRegistry(self: *Interpreter) EvalError!?*value.Object {
    const sym = self.env.get("Symbol") orelse return null;
    if (sym != .object) return null;
    if (sym.object.getOwn("\x00registry")) |r| {
        if (r == .object) return r.object;
    }
    const reg = (try self.newObject()).object;
    try sym.object.setOwn(self.arena, self.root_shape, "\x00registry", .{ .object = reg });
    return reg;
}

/// `Symbol.for(key)` — return the registered symbol for the string `key`,
/// creating and registering it on first use so equal keys yield the *same*
/// symbol. The registration key is stashed on the symbol (hidden) for `keyFor`.
fn symbolForFn(ctx: *anyopaque, this: Value, args: []const Value) value.HostError!Value {
    _ = this;
    const self: *Interpreter = @ptrCast(@alignCast(ctx));
    const key = if (args.len > 0) try args[0].toString(self.arena) else "undefined";
    const reg = (try symbolRegistry(self)) orelse return self.throwError("TypeError", "Symbol registry unavailable");
    if (reg.getOwn(key)) |existing| return existing;
    const sym = try makeSymbolObj(self.arena, self.root_shape, key, symbolProto(self));
    try sym.object.setOwn(self.arena, self.root_shape, "\x00forKey", .{ .string = key });
    try reg.setOwn(self.arena, self.root_shape, key, sym);
    return sym;
}

/// `Symbol.keyFor(sym)` — the registry key a symbol was registered under via
/// `Symbol.for`, or undefined if it isn't a registered symbol.
fn symbolKeyForFn(ctx: *anyopaque, this: Value, args: []const Value) value.HostError!Value {
    _ = this;
    const self: *Interpreter = @ptrCast(@alignCast(ctx));
    if (args.len == 0 or args[0] != .object or !args[0].object.is_symbol)
        return self.throwError("TypeError", "Symbol.keyFor requires a symbol argument");
    return args[0].object.getOwn("\x00forKey") orelse .undefined;
}

/// Abstract Relational Comparison (subset): string<string is lexicographic,
/// everything else compares as numbers.
fn lessThan(a: Value, b: Value) EvalError!bool {
    if (a == .string and b == .string) {
        return std.mem.order(u8, a.string, b.string) == .lt;
    }
    const x = a.toNumber();
    const y = b.toNumber();
    if (std.math.isNan(x) or std.math.isNan(y)) return false;
    return x < y;
}

/// Does `o` (own or via its prototype chain) have a data or accessor property
/// named `name`? Used by `with`-scope identifier resolution.
/// The root (global) lexical environment — where the installed globals and
/// top-level `var`/function bindings live.
fn rootEnv(env: *Environment) *Environment {
    var root = env;
    while (root.parent) |p| root = p;
    return root;
}

pub fn hasProperty(o: *value.Object, name: []const u8) bool {
    var cur: ?*value.Object = o;
    while (cur) |c| {
        if (c.getOwn(name) != null or c.getAccessor(name) != null) return true;
        cur = c.proto;
    }
    return false;
}

/// Does `o` have `name` as an *own* property (data, accessor, array index, or
/// array `length`)? Backs `hasOwnProperty` / `propertyIsEnumerable` / `Object.hasOwn`.
pub fn objectHasOwn(o: *value.Object, name: []const u8) bool {
    // Private members (`#x`) are internal slots, invisible to all reflection.
    if (value.isPrivateKey(name)) return false;
    if (o.getOwn(name) != null or o.getAccessor(name) != null) return true;
    if (o.is_array) {
        if (std.mem.eql(u8, name, "length")) return true;
        if (Interpreter.arrayIndex(name)) |i| return i < o.elements.items.len and !o.isHole(i);
    }
    return false;
}

fn arg0(args: []const Value) Value {
    return if (args.len > 0) args[0] else .undefined;
}

/// Integer `n` formatted in `radix` (2–36), e.g. `(255).toString(16)` → "ff".
/// `n.toString(radix)` for radix ≠ 10 — converts both the integer and (up to a
/// bounded number of digits) the fractional part of a finite number. Works in
/// f64 throughout so it isn't limited to u64-range integers.
fn numberToRadix(arena: std.mem.Allocator, n: f64, radix: usize) ![]const u8 {
    if (n == 0) return "0";
    const digits = "0123456789abcdefghijklmnopqrstuvwxyz";
    const rf: f64 = @floatFromInt(radix);
    const neg = n < 0;
    var int_part = @floor(@abs(n));
    var frac = @abs(n) - int_part;
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    if (neg) try buf.append(arena, '-');
    // Integer part (built least-significant-digit first, then reversed).
    var int_digits: std.ArrayListUnmanaged(u8) = .empty;
    if (int_part == 0) {
        try int_digits.append(arena, '0');
    } else while (int_part >= 1) {
        const d = @mod(int_part, rf);
        try int_digits.append(arena, digits[@intFromFloat(d)]);
        int_part = @floor(int_part / rf);
    }
    std.mem.reverse(u8, int_digits.items);
    try buf.appendSlice(arena, int_digits.items);
    // Fractional part, bounded so an inexact binary fraction terminates.
    if (frac > 0) {
        try buf.append(arena, '.');
        var count: usize = 0;
        while (frac > 0 and count < 52) : (count += 1) {
            frac *= rf;
            const d = @floor(frac);
            try buf.append(arena, digits[@intFromFloat(d)]);
            frac -= d;
        }
    }
    return buf.items;
}

/// `n.toFixed(d)` — fixed-point with `d` decimals (d ≤ 18; no exponent forms).
/// Falls back to the default number string when the scaled value would overflow.
fn toFixed(arena: std.mem.Allocator, n: f64, d: usize) ![]const u8 {
    if (std.math.isNan(n)) return "NaN";
    if (std.math.isInf(n)) return if (n < 0) "-Infinity" else "Infinity";
    const neg = n < 0;
    const scale = std.math.pow(f64, 10, @floatFromInt(d));
    const scaled_f = @round(@abs(n) * scale);
    if (scaled_f >= 18446744073709551615.0) return value.numberToString(arena, n); // too big for fixed-point
    const scaled: u64 = @intFromFloat(scaled_f);
    const scale_u: u64 = @intFromFloat(scale);
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    if (neg) try buf.append(arena, '-');
    try buf.print(arena, "{d}", .{scaled / scale_u});
    if (d > 0) {
        try buf.print(arena, ".{d:0>[1]}", .{ scaled % scale_u, d });
    }
    return buf.items;
}

/// Reformat Zig's scientific output (`1.234e1`, `-9.99e-40`) to JS form, where
/// the exponent always carries a sign (`1.234e+1`, `-9.99e-40`).
fn jsExpFix(arena: std.mem.Allocator, s: []const u8) ![]const u8 {
    const ei = std.mem.indexOfScalar(u8, s, 'e') orelse return arena.dupe(u8, s);
    const mant = s[0..ei];
    const exp = s[ei + 1 ..];
    const sign: []const u8 = if (exp.len > 0 and exp[0] == '-') "" else "+";
    return std.fmt.allocPrint(arena, "{s}e{s}{s}", .{ mant, sign, exp });
}

/// `Number.prototype.toExponential` — scientific notation with `frac` fraction
/// digits (or shortest when null), exponent always signed.
fn toExponentialStr(arena: std.mem.Allocator, n: f64, frac: ?usize) ![]const u8 {
    var buf: [512]u8 = undefined;
    const s = std.fmt.float.render(&buf, n, .{ .mode = .scientific, .precision = frac }) catch return error.OutOfMemory;
    return jsExpFix(arena, s);
}

/// `Number.prototype.toPrecision` — `p` significant digits, choosing fixed or
/// exponential notation per spec (exponential when the decimal exponent is
/// < -6 or >= p).
fn toPrecisionStr(arena: std.mem.Allocator, n: f64, p: usize) ![]const u8 {
    if (n == 0) {
        if (p == 1) return "0";
        var z: std.ArrayListUnmanaged(u8) = .empty;
        try z.appendSlice(arena, "0.");
        try z.appendNTimes(arena, '0', p - 1);
        return z.items;
    }
    const neg = n < 0;
    var buf: [512]u8 = undefined;
    // Scientific with p-1 fraction digits yields exactly p significant digits.
    const s = std.fmt.float.render(&buf, @abs(n), .{ .mode = .scientific, .precision = p - 1 }) catch return error.OutOfMemory;
    // Parse "d.ddd...eX": collect the significant digits and the decimal exponent.
    const ei = std.mem.indexOfScalar(u8, s, 'e').?;
    var digits: std.ArrayListUnmanaged(u8) = .empty;
    for (s[0..ei]) |c| if (c != '.') try digits.append(arena, c);
    const exp = std.fmt.parseInt(i32, s[ei + 1 ..], 10) catch 0;
    const nd: i32 = @intCast(digits.items.len);

    var out: std.ArrayListUnmanaged(u8) = .empty;
    if (neg) try out.append(arena, '-');
    if (exp < -6 or exp >= @as(i32, @intCast(p))) {
        // Exponential form: d.ddd e±X
        try out.append(arena, digits.items[0]);
        if (digits.items.len > 1) {
            try out.append(arena, '.');
            try out.appendSlice(arena, digits.items[1..]);
        }
        try out.appendSlice(arena, try jsExpFix(arena, try std.fmt.allocPrint(arena, "e{d}", .{exp})));
    } else if (exp >= 0) {
        const ip: usize = @intCast(exp + 1); // digits before the decimal point
        if (ip >= digits.items.len) {
            try out.appendSlice(arena, digits.items);
            try out.appendNTimes(arena, '0', ip - digits.items.len);
        } else {
            try out.appendSlice(arena, digits.items[0..ip]);
            try out.append(arena, '.');
            try out.appendSlice(arena, digits.items[ip..]);
        }
    } else {
        // exp in [-6, -1]: 0.00…digits
        try out.appendSlice(arena, "0.");
        try out.appendNTimes(arena, '0', @intCast(-exp - 1));
        try out.appendSlice(arena, digits.items);
    }
    _ = nd;
    return out.items;
}

fn arg(args: []const Value, i: usize) Value {
    return if (i < args.len) args[i] else .undefined;
}

fn labelEq(a: ?[]const u8, b: ?[]const u8) bool {
    if (a == null or b == null) return false;
    return std.mem.eql(u8, a.?, b.?);
}

fn relationalNaN(a: Value, b: Value) bool {
    if (a == .string and b == .string) return false;
    return std.math.isNan(a.toNumber()) or std.math.isNan(b.toNumber());
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const Parser = @import("parser.zig").Parser;

fn evalSource(arena: std.mem.Allocator, src: []const u8) !Value {
    var parser = try Parser.init(arena, src);
    const prog = try parser.parseProgram();
    var env = Environment{ .arena = arena };
    const root_shape = try Shape.createRoot(arena);
    try installGlobals(&env, root_shape);
    var interp = Interpreter{ .arena = arena, .env = &env, .root_shape = root_shape };
    return interp.eval(prog);
}

test "interpreter evaluates arithmetic with precedence" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const v = try evalSource(arena.allocator(), "1 + 2 * 3");
    try std.testing.expectEqual(@as(f64, 7), v.number);
}

test "interpreter concatenates strings" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const v = try evalSource(arena.allocator(), "'a' + 'b' + 1");
    try std.testing.expectEqualStrings("ab1", v.string);
}

test "interpreter handles variables, if, and while" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const v = try evalSource(arena.allocator(),
        \\let x = 0;
        \\let i = 1;
        \\while (i <= 5) { x = x + i; i = i + 1; }
        \\x
    );
    try std.testing.expectEqual(@as(f64, 15), v.number);
}

test "interpreter comparisons and logical ops" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expect((try evalSource(arena.allocator(), "3 > 2 && 2 >= 2")).boolean);
    try std.testing.expect((try evalSource(arena.allocator(), "1 === 1 && 1 !== 2")).boolean);
    try std.testing.expect(!(try evalSource(arena.allocator(), "1 == '2'")).boolean);
    try std.testing.expect((try evalSource(arena.allocator(), "1 == '1'")).boolean);
    try std.testing.expect((try evalSource(arena.allocator(), "typeof 'x' === 'string'")).boolean);
}

test "interpreter ternary" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const v = try evalSource(arena.allocator(), "true ? 10 : 20");
    try std.testing.expectEqual(@as(f64, 10), v.number);
}

test "interpreter function declaration and call" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const v = try evalSource(arena.allocator(),
        \\function add(a, b) { return a + b; }
        \\add(40, 2)
    );
    try std.testing.expectEqual(@as(f64, 42), v.number);
}

test "interpreter recursion (factorial)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const v = try evalSource(arena.allocator(),
        \\function fact(n) { return n <= 1 ? 1 : n * fact(n - 1); }
        \\fact(5)
    );
    try std.testing.expectEqual(@as(f64, 120), v.number);
}

test "interpreter closures capture environment" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const v = try evalSource(arena.allocator(),
        \\function makeAdder(x) { return function (y) { return x + y; }; }
        \\let add10 = makeAdder(10);
        \\add10(5)
    );
    try std.testing.expectEqual(@as(f64, 15), v.number);
}

test "interpreter arrow functions" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqual(@as(f64, 25), (try evalSource(arena.allocator(),
        \\let sq = x => x * x;
        \\sq(5)
    )).number);
    try std.testing.expectEqual(@as(f64, 7), (try evalSource(arena.allocator(),
        \\let add = (a, b) => a + b;
        \\add(3, 4)
    )).number);
}

test "interpreter higher-order with closure counter" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const v = try evalSource(arena.allocator(),
        \\function counter() {
        \\  let n = 0;
        \\  return function () { n = n + 1; return n; };
        \\}
        \\let c = counter();
        \\c(); c(); c()
    );
    try std.testing.expectEqual(@as(f64, 3), v.number);
}

test "interpreter object literal + member access" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqual(@as(f64, 3), (try evalSource(a, "let o = { x: 1, y: 2 }; o.x + o.y")).number);
    try std.testing.expectEqual(@as(f64, 9), (try evalSource(a, "let o = {}; o.a = 4; o['b'] = 5; o.a + o['b']")).number);
}

test "interpreter array literal, index, length, push/pop" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqual(@as(f64, 30), (try evalSource(a, "let xs = [10, 20, 30]; xs[2]")).number);
    try std.testing.expectEqual(@as(f64, 3), (try evalSource(a, "let xs = [1, 2, 3]; xs.length")).number);
    try std.testing.expectEqual(@as(f64, 4), (try evalSource(a, "let xs = [1]; xs.push(2); xs.push(3); xs.push(4); xs.length")).number);
    try std.testing.expectEqual(@as(f64, 9), (try evalSource(a, "let xs = [7, 9]; xs.pop()")).number);
    try std.testing.expectEqualStrings("a,b,c", (try evalSource(a, "'' + ['a','b','c']")).string);
}

test "interpreter string length and indexing" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqual(@as(f64, 5), (try evalSource(a, "'hello'.length")).number);
    try std.testing.expectEqualStrings("e", (try evalSource(a, "'hello'[1]")).string);
}

test "interpreter throw / try / catch / finally" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // catch binds the thrown value
    try std.testing.expectEqual(@as(f64, 42), (try evalSource(a,
        \\let r = 0;
        \\try { throw 42; } catch (e) { r = e; }
        \\r
    )).number);
    // finally always runs
    try std.testing.expectEqual(@as(f64, 3), (try evalSource(a,
        \\let r = 0;
        \\try { r = 1; } catch (e) { r = 2; } finally { r = 3; }
        \\r
    )).number);
    // an uncaught throw propagates as error.Throw
    try std.testing.expectError(error.Throw, evalSource(a, "throw 'boom';"));
}

test "interpreter catches engine-raised TypeError/ReferenceError" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // calling a non-function throws a catchable TypeError
    try std.testing.expectEqualStrings("TypeError", (try evalSource(a,
        \\let n = "";
        \\try { let x = 5; x(); } catch (e) { n = e.name; }
        \\n
    )).string);
    // referencing an undefined name throws a catchable ReferenceError
    try std.testing.expectEqualStrings("ReferenceError", (try evalSource(a,
        \\let n = "";
        \\try { missing; } catch (e) { n = e.name; }
        \\n
    )).string);
}

test "interpreter new + constructor + this + instanceof" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqual(@as(f64, 7), (try evalSource(a,
        \\function Point(x, y) { this.x = x; this.y = y; }
        \\let p = new Point(3, 4);
        \\p.x + p.y
    )).number);
    try std.testing.expect((try evalSource(a,
        \\function Point(x) { this.x = x; }
        \\let p = new Point(1);
        \\p instanceof Point
    )).boolean);
}

test "interpreter built-in Error constructors" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings("oops", (try evalSource(a, "let e = new Error('oops'); e.message")).string);
    try std.testing.expectEqualStrings("TypeError", (try evalSource(a, "let e = new TypeError('bad'); e.name")).string);
    try std.testing.expect((try evalSource(a, "(new RangeError('x')) instanceof Error")).boolean);
    try std.testing.expect((try evalSource(a,
        \\let caught = false;
        \\try { throw new TypeError('nope'); } catch (e) { caught = e instanceof TypeError; }
        \\caught
    )).boolean);
}

test "interpreter method call binds this" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const v = try evalSource(arena.allocator(),
        \\let o = { n: 10, getN: function () { return this.n; } };
        \\o.getN()
    );
    try std.testing.expectEqual(@as(f64, 10), v.number);
}

test "interpreter for loop + ++ + compound assignment" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqual(@as(f64, 45), (try evalSource(a,
        \\let sum = 0;
        \\for (let i = 0; i < 10; i++) { sum += i; }
        \\sum
    )).number);
    // postfix vs prefix
    try std.testing.expectEqual(@as(f64, 5), (try evalSource(a, "let x = 5; let y = x++; y")).number);
    try std.testing.expectEqual(@as(f64, 6), (try evalSource(a, "let x = 5; let y = ++x; y")).number);
}

test "interpreter compound assignments, nullish, and in" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqual(@as(f64, 12), (try evalSource(a, "let x = 3; x **= 2; x + 3")).number);
    try std.testing.expectEqual(@as(f64, 1), (try evalSource(a, "let x = 5; x &= 3; x")).number);
    try std.testing.expectEqual(@as(f64, 7), (try evalSource(a, "let x = 5; x |= 2; x")).number);
    try std.testing.expectEqual(@as(f64, 40), (try evalSource(a, "let x = 5; x <<= 3; x")).number);
    // nullish coalescing
    try std.testing.expectEqual(@as(f64, 5), (try evalSource(a, "null ?? 5")).number);
    try std.testing.expectEqual(@as(f64, 0), (try evalSource(a, "0 ?? 5")).number); // 0 is not null/undefined
    // in operator
    try std.testing.expect((try evalSource(a, "'a' in { a: 1 }")).boolean);
    try std.testing.expect(!(try evalSource(a, "'z' in { a: 1 }")).boolean);
    try std.testing.expect((try evalSource(a, "0 in [10, 20]")).boolean);
}

test "interpreter bitwise and shift operators" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqual(@as(f64, 1), (try evalSource(a, "5 & 3")).number);
    try std.testing.expectEqual(@as(f64, 7), (try evalSource(a, "5 | 2")).number);
    try std.testing.expectEqual(@as(f64, 6), (try evalSource(a, "5 ^ 3")).number);
    try std.testing.expectEqual(@as(f64, -6), (try evalSource(a, "~5")).number);
    try std.testing.expectEqual(@as(f64, 40), (try evalSource(a, "5 << 3")).number);
    try std.testing.expectEqual(@as(f64, -3), (try evalSource(a, "-5 >> 1")).number);
    try std.testing.expectEqual(@as(f64, 2147483645), (try evalSource(a, "-5 >>> 1")).number);
    // precedence: | looser than &, both looser than ==
    try std.testing.expectEqual(@as(f64, 7), (try evalSource(a, "1 | 2 & 3 | 4")).number);
}

test "interpreter Array.sort/at/fill/flat and String.replace/pad/at" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings("1,2,3", (try evalSource(a, "'' + [3, 1, 2].sort()")).string);
    try std.testing.expectEqualStrings("1,2,3,10", (try evalSource(a, "'' + [10, 1, 3, 2].sort(function (x, y) { return x - y; })")).string);
    try std.testing.expectEqual(@as(f64, 3), (try evalSource(a, "[1, 2, 3].at(-1)")).number);
    try std.testing.expectEqualStrings("9,9,9", (try evalSource(a, "'' + [0, 0, 0].fill(9)")).string);
    try std.testing.expectEqualStrings("1,2,3,4", (try evalSource(a, "'' + [1, [2, [3]], 4].flat(2)")).string);
    // String.replace (string + regex), replaceAll, pad, at
    try std.testing.expectEqualStrings("a-b-c", (try evalSource(a, "'a b c'.replaceAll(' ', '-')")).string);
    try std.testing.expectEqualStrings("aXc", (try evalSource(a, "'abc'.replace(/b/, 'X')")).string);
    try std.testing.expectEqualStrings("X-X", (try evalSource(a, "'a-a'.replace(/a/g, 'X')")).string);
    try std.testing.expectEqualStrings("007", (try evalSource(a, "'7'.padStart(3, '0')")).string);
    try std.testing.expectEqualStrings("c", (try evalSource(a, "'abc'.at(-1)")).string);
    try std.testing.expectEqualStrings("hi", (try evalSource(a, "'  hi'.trimStart()")).string);
}

test "interpreter Array.prototype methods" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings("1-2-3", (try evalSource(a, "[1, 2, 3].join('-')")).string);
    try std.testing.expectEqual(@as(f64, 1), (try evalSource(a, "[10, 20, 30].indexOf(20)")).number);
    try std.testing.expect((try evalSource(a, "[1, 2, 3].includes(2)")).boolean);
    try std.testing.expectEqualStrings("2,4,6", (try evalSource(a, "'' + [1, 2, 3].map(function (x) { return x * 2; })")).string);
    try std.testing.expectEqualStrings("2,4", (try evalSource(a, "'' + [1, 2, 3, 4].filter(function (x) { return x % 2 === 0; })")).string);
    try std.testing.expectEqual(@as(f64, 10), (try evalSource(a, "[1, 2, 3, 4].reduce(function (a, b) { return a + b; }, 0)")).number);
    try std.testing.expectEqual(@as(f64, 6), (try evalSource(a, "let s = 0; [1, 2, 3].forEach(function (x) { s = s + x; }); s")).number);
    try std.testing.expect((try evalSource(a, "[1, 2, 3].some(function (x) { return x > 2; })")).boolean);
    try std.testing.expect((try evalSource(a, "[2, 4, 6].every(function (x) { return x % 2 === 0; })")).boolean);
    try std.testing.expectEqualStrings("2,3", (try evalSource(a, "'' + [1, 2, 3].slice(1)")).string);
    try std.testing.expectEqualStrings("1,2,3,4", (try evalSource(a, "'' + [1, 2].concat([3, 4])")).string);
}

test "interpreter String.prototype methods" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings("ELLO", (try evalSource(a, "'hello'.slice(1).toUpperCase()")).string);
    try std.testing.expectEqual(@as(f64, 2), (try evalSource(a, "'hello'.indexOf('l')")).number);
    try std.testing.expect((try evalSource(a, "'hello world'.includes('world')")).boolean);
    try std.testing.expect((try evalSource(a, "'hello'.startsWith('he')")).boolean);
    try std.testing.expectEqualStrings("ell", (try evalSource(a, "'hello'.substring(1, 4)")).string);
    try std.testing.expectEqualStrings("abab", (try evalSource(a, "'ab'.repeat(2)")).string);
    try std.testing.expectEqualStrings("a,b,c", (try evalSource(a, "'' + 'a-b-c'.split('-')")).string);
    try std.testing.expectEqualStrings("hi", (try evalSource(a, "'  hi  '.trim()")).string);
}

test "interpreter numeric literals (separators, binary/octal) and optional chaining" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // numeric separators + radix prefixes
    try std.testing.expectEqual(@as(f64, 1000000), (try evalSource(a, "1_000_000")).number);
    try std.testing.expectEqual(@as(f64, 255), (try evalSource(a, "0b1111_1111")).number);
    try std.testing.expectEqual(@as(f64, 511), (try evalSource(a, "0o777")).number);
    try std.testing.expectEqual(@as(f64, 3000), (try evalSource(a, "3_000")).number);
    // optional chaining
    try std.testing.expect((try evalSource(a, "let o = { a: { b: 5 } }; o.a?.b === 5")).boolean);
    try std.testing.expect((try evalSource(a, "let o = {}; o.x?.y === undefined")).boolean);
    try std.testing.expect((try evalSource(a, "let o = null; o?.a?.b === undefined")).boolean);
    // optional call
    try std.testing.expect((try evalSource(a, "let o = { f: function () { return 7; } }; o.f?.() === 7")).boolean);
    try std.testing.expect((try evalSource(a, "let o = {}; o.missing?.() === undefined")).boolean);
    // optional method short-circuits the whole chain
    try std.testing.expect((try evalSource(a, "let o = null; o?.a.b.c === undefined")).boolean);
}

test "interpreter arguments object and Array/Object statics" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // arguments object
    try std.testing.expectEqual(@as(f64, 6), (try evalSource(a, "function sum() { let s = 0; for (let i = 0; i < arguments.length; i++) { s += arguments[i]; } return s; } sum(1, 2, 3)")).number);
    // arrows have no own arguments (inherit) — here referencing arguments at top level is fine
    try std.testing.expectEqual(@as(f64, 3), (try evalSource(a, "function f() { return arguments.length; } f(7, 8, 9)")).number);
    // Array.of / from
    try std.testing.expectEqualStrings("1,2,3", (try evalSource(a, "'' + Array.of(1, 2, 3)")).string);
    try std.testing.expectEqualStrings("a,b,c", (try evalSource(a, "'' + Array.from('abc')")).string);
    // Object.entries / fromEntries
    try std.testing.expectEqual(@as(f64, 2), (try evalSource(a, "Object.entries({ a: 1, b: 2 }).length")).number);
    try std.testing.expectEqual(@as(f64, 5), (try evalSource(a, "let o = Object.fromEntries([['x', 5]]); o.x")).number);
}

test "interpreter Map and Set" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqual(@as(f64, 5), (try evalSource(a, "let m = new Map(); m.set('a', 5); m.get('a')")).number);
    try std.testing.expectEqual(@as(f64, 2), (try evalSource(a, "let m = new Map(); m.set('a', 1); m.set('b', 2); m.size")).number);
    try std.testing.expect((try evalSource(a, "let m = new Map(); m.set('k', 1); m.has('k')")).boolean);
    try std.testing.expectEqual(@as(f64, 1), (try evalSource(a, "let m = new Map([['a', 1], ['b', 2]]); m.delete('b'); m.size")).number);
    try std.testing.expectEqual(@as(f64, 3), (try evalSource(a, "let s = new Set([1, 2, 2, 3, 3]); s.size")).number);
    try std.testing.expect((try evalSource(a, "let s = new Set(); s.add(7); s.has(7)")).boolean);
    try std.testing.expectEqual(@as(f64, 6), (try evalSource(a, "let s = new Set([1, 2, 3]); let t = 0; s.forEach(function (v) { t += v; }); t")).number);
}

test "interpreter regex literals (zig-regex backed)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expect((try evalSource(a, "/ab+c/.test('xabbbcx')")).boolean);
    try std.testing.expect(!(try evalSource(a, "/^\\d+$/.test('12a')")).boolean);
    try std.testing.expectEqualStrings("g", (try evalSource(a, "/foo/g.flags")).string);
    try std.testing.expectEqualStrings("a.c", (try evalSource(a, "/a.c/.source")).string);
    // case-insensitive flag honored via zig-regex
    try std.testing.expect((try evalSource(a, "/abc/i.test('ABC')")).boolean);
    // exec returns the match with index
    try std.testing.expectEqual(@as(f64, 1), (try evalSource(a, "let m = /b/.exec('abc'); m.index")).number);
    // RegExp constructor
    try std.testing.expect((try evalSource(a, "new RegExp('a+').test('baaa')")).boolean);
    // division still lexes correctly after a value
    try std.testing.expectEqual(@as(f64, 4), (try evalSource(a, "let x = 8; x / 2")).number);
}

test "interpreter JSON, Object, Number builtins" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings("{\"a\":1,\"b\":[2,3]}", (try evalSource(a, "JSON.stringify({ a: 1, b: [2, 3] })")).string);
    try std.testing.expectEqualStrings("[1,\"x\",true,null]", (try evalSource(a, "JSON.stringify([1, 'x', true, null])")).string);
    try std.testing.expectEqual(@as(f64, 3), (try evalSource(a, "let o = JSON.parse('{\"n\": 3}'); o.n")).number);
    try std.testing.expectEqual(@as(f64, 6), (try evalSource(a, "let v = JSON.parse('[1,2,3]'); v[0] + v[1] + v[2]")).number);
    // Object.create + getPrototypeOf
    try std.testing.expectEqual(@as(f64, 7), (try evalSource(a, "let p = { x: 7 }; let o = Object.create(p); o.x")).number);
    // Object.defineProperty (data + accessor)
    try std.testing.expectEqual(@as(f64, 5), (try evalSource(a, "let o = {}; Object.defineProperty(o, 'k', { value: 5 }); o.k")).number);
    try std.testing.expectEqual(@as(f64, 9), (try evalSource(a, "let o = { _v: 9 }; Object.defineProperty(o, 'v', { get: function () { return this._v; } }); o.v")).number);
    // Number statics
    try std.testing.expect((try evalSource(a, "Number.isInteger(5)")).boolean);
    try std.testing.expect(!(try evalSource(a, "Number.isInteger(5.5)")).boolean);
    try std.testing.expect((try evalSource(a, "Number.isNaN(NaN)")).boolean);
    try std.testing.expectEqualStrings("AB", (try evalSource(a, "String.fromCharCode(65, 66)")).string);
}

test "interpreter builtins: Math, Object, Array, globals" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqual(@as(f64, 3), (try evalSource(a, "Math.floor(3.7)")).number);
    try std.testing.expectEqual(@as(f64, 4), (try evalSource(a, "Math.round(3.5)")).number);
    try std.testing.expectEqual(@as(f64, 8), (try evalSource(a, "Math.pow(2, 3)")).number);
    try std.testing.expectEqual(@as(f64, 9), (try evalSource(a, "Math.max(1, 9, 4)")).number);
    try std.testing.expectEqual(@as(f64, 5), (try evalSource(a, "Math.abs(-5)")).number);
    try std.testing.expectEqual(@as(f64, 42), (try evalSource(a, "parseInt('42px')")).number);
    try std.testing.expectEqual(@as(f64, 255), (try evalSource(a, "parseInt('0xff')")).number);
    try std.testing.expectEqual(@as(f64, 3.14), (try evalSource(a, "parseFloat('3.14abc')")).number);
    try std.testing.expect((try evalSource(a, "isNaN(NaN)")).boolean);
    try std.testing.expectEqualStrings("42", (try evalSource(a, "String(42)")).string);
    try std.testing.expectEqual(@as(f64, 3), (try evalSource(a, "Number('3')")).number);
    try std.testing.expect((try evalSource(a, "Array.isArray([1, 2])")).boolean);
    try std.testing.expect(!(try evalSource(a, "Array.isArray({})")).boolean);
    // Object.keys / values
    try std.testing.expectEqualStrings("a,b", (try evalSource(a, "'' + Object.keys({ a: 1, b: 2 })")).string);
    try std.testing.expectEqual(@as(f64, 3), (try evalSource(a, "let v = Object.values({ a: 1, b: 2 }); v[0] + v[1]")).number);
    // Object.assign
    try std.testing.expectEqual(@as(f64, 3), (try evalSource(a, "let t = Object.assign({ a: 1 }, { b: 2 }); t.a + t.b")).number);
}

test "interpreter classes (methods, static, instanceof, computed)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // constructor + instance method via prototype
    try std.testing.expectEqual(@as(f64, 7), (try evalSource(a,
        \\class Point {
        \\  constructor(x, y) { this.x = x; this.y = y; }
        \\  sum() { return this.x + this.y; }
        \\}
        \\let p = new Point(3, 4);
        \\p.sum()
    )).number);
    // instanceof via prototype chain
    try std.testing.expect((try evalSource(a,
        \\class C { constructor() { this.v = 1; } }
        \\(new C()) instanceof C
    )).boolean);
    // static method
    try std.testing.expectEqual(@as(f64, 9), (try evalSource(a,
        \\class M { static sq(n) { return n * n; } }
        \\M.sq(3)
    )).number);
    // class expression + computed method name
    try std.testing.expectEqual(@as(f64, 42), (try evalSource(a,
        \\let k = 'go';
        \\let C = class { [k]() { return 42; } };
        \\(new C()).go()
    )).number);
    // instance fields + static field
    try std.testing.expectEqual(@as(f64, 8), (try evalSource(a,
        \\class F { x = 5; y; constructor() { this.y = 3; } total() { return this.x + this.y; } }
        \\(new F()).total()
    )).number);
    try std.testing.expectEqual(@as(f64, 99), (try evalSource(a,
        \\class S { static count = 99; }
        \\S.count
    )).number);
    // method calling another method through `this`
    try std.testing.expectEqual(@as(f64, 20), (try evalSource(a,
        \\class Box {
        \\  constructor(n) { this.n = n; }
        \\  dbl() { return this.n * 2; }
        \\  quad() { return this.dbl() * 2; }
        \\}
        \\(new Box(5)).quad()
    )).number);
}

test "interpreter number/boolean primitive methods" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings("255", (try evalSource(a, "(255).toString()")).string);
    try std.testing.expectEqualStrings("ff", (try evalSource(a, "(255).toString(16)")).string);
    try std.testing.expectEqualStrings("1010", (try evalSource(a, "(10).toString(2)")).string);
    try std.testing.expectEqualStrings("3.14", (try evalSource(a, "(3.14159).toFixed(2)")).string);
    try std.testing.expectEqualStrings("5.00", (try evalSource(a, "(5).toFixed(2)")).string);
    try std.testing.expectEqual(@as(f64, 7), (try evalSource(a, "(7).valueOf()")).number);
    try std.testing.expectEqualStrings("true", (try evalSource(a, "true.toString()")).string);
}

test "interpreter with statement" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // reads resolve against the with object
    try std.testing.expectEqual(@as(f64, 7), (try evalSource(a,
        \\let r = 0;
        \\with ({ x: 3, y: 4 }) { r = x + y; }
        \\r
    )).number);
    // writes to a name on the with object update the object
    try std.testing.expectEqual(@as(f64, 9), (try evalSource(a,
        \\let o = { v: 1 };
        \\with (o) { v = 9; }
        \\o.v
    )).number);
    // names not on the object fall through to the outer scope
    try std.testing.expectEqual(@as(f64, 5), (try evalSource(a,
        \\let outer = 5;
        \\with ({ x: 1 }) { x = outer; }
        \\outer
    )).number);
}

test "interpreter logical assignment operators" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqual(@as(f64, 5), (try evalSource(a, "let x = 0; x ||= 5; x")).number);
    try std.testing.expectEqual(@as(f64, 1), (try evalSource(a, "let x = 1; x ||= 5; x")).number);
    try std.testing.expectEqual(@as(f64, 9), (try evalSource(a, "let x = 2; x &&= 9; x")).number);
    try std.testing.expectEqual(@as(f64, 0), (try evalSource(a, "let x = 0; x &&= 9; x")).number);
    try std.testing.expectEqual(@as(f64, 7), (try evalSource(a, "let x = null; x ??= 7; x")).number);
    try std.testing.expectEqual(@as(f64, 3), (try evalSource(a, "let x = 3; x ??= 7; x")).number);
}

test "interpreter class private fields/methods and static blocks" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // private field + private method
    try std.testing.expectEqual(@as(f64, 30), (try evalSource(a,
        \\class Counter {
        \\  #count = 0;
        \\  #step() { return 10; }
        \\  bump() { this.#count = this.#count + this.#step(); return this.#count; }
        \\}
        \\let c = new Counter();
        \\c.bump(); c.bump(); c.bump()
    )).number);
    // static initialization block
    try std.testing.expectEqual(@as(f64, 42), (try evalSource(a,
        \\class C { static x; static { this.x = 42; } }
        \\C.x
    )).number);
}

test "interpreter getters and setters" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // object literal getter/setter
    try std.testing.expectEqual(@as(f64, 42), (try evalSource(a,
        \\let o = { _v: 0, get v() { return this._v; }, set v(x) { this._v = x * 2; } };
        \\o.v = 21;
        \\o.v
    )).number);
    // class getter via prototype
    try std.testing.expectEqual(@as(f64, 25), (try evalSource(a,
        \\class Sq { constructor(n) { this.n = n; } get area() { return this.n * this.n; } }
        \\(new Sq(5)).area
    )).number);
    // class setter
    try std.testing.expectEqual(@as(f64, 6), (try evalSource(a,
        \\class C { set half(x) { this.stored = x / 2; } }
        \\let c = new C(); c.half = 12; c.stored
    )).number);
}

test "interpreter class extends and super" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // super() in constructor + inherited method
    try std.testing.expectEqual(@as(f64, 30), (try evalSource(a,
        \\class Animal { constructor(n) { this.legs = n; } legCount() { return this.legs; } }
        \\class Dog extends Animal { constructor() { super(4); } }
        \\let d = new Dog();
        \\d.legCount() * 7 + 2
    )).number);
    // super.method() calls the parent's version
    try std.testing.expectEqual(@as(f64, 11), (try evalSource(a,
        \\class A { val() { return 10; } }
        \\class B extends A { val() { return super.val() + 1; } }
        \\(new B()).val()
    )).number);
    // instanceof across the chain
    try std.testing.expect((try evalSource(a,
        \\class A {}
        \\class B extends A {}
        \\let b = new B();
        \\b instanceof B && b instanceof A
    )).boolean);
    // default derived constructor forwards args
    try std.testing.expectEqual(@as(f64, 42), (try evalSource(a,
        \\class Base { constructor(x) { this.x = x; } }
        \\class Sub extends Base {}
        \\(new Sub(42)).x
    )).number);
    // inherited static method
    try std.testing.expectEqual(@as(f64, 16), (try evalSource(a,
        \\class P { static sq(n) { return n * n; } }
        \\class C extends P {}
        \\C.sq(4)
    )).number);
}

test "interpreter assignment and parameter destructuring" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // assignment destructuring (array)
    try std.testing.expectEqual(@as(f64, 12), (try evalSource(a, "let x = 0, y = 0; [x, y] = [10, 2]; x + y")).number);
    // assignment destructuring (object) — needs parens at statement start
    try std.testing.expectEqual(@as(f64, 3), (try evalSource(a, "let a2 = 0, b2 = 0; ({ a: a2, b: b2 } = { a: 1, b: 2 }); a2 + b2")).number);
    // destructuring into a member target
    try std.testing.expectEqual(@as(f64, 9), (try evalSource(a, "let o = {}; [o.x] = [9]; o.x")).number);
    // parameter destructuring
    try std.testing.expectEqual(@as(f64, 7), (try evalSource(a, "function f({ x, y }) { return x + y; } f({ x: 3, y: 4 })")).number);
    try std.testing.expectEqual(@as(f64, 30), (try evalSource(a, "function g([a3, b3]) { return a3 * b3; } g([5, 6])")).number);
    // parameter default + destructuring
    try std.testing.expectEqual(@as(f64, 5), (try evalSource(a, "function h({ n = 5 }) { return n; } h({})")).number);
}

test "interpreter destructuring declarations" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // object pattern
    try std.testing.expectEqual(@as(f64, 3), (try evalSource(a, "let { a, b } = { a: 1, b: 2 }; a + b")).number);
    // object pattern with rename + default
    try std.testing.expectEqual(@as(f64, 12), (try evalSource(a, "let { a: x, c = 10 } = { a: 2 }; x + c")).number);
    // array pattern with hole and rest
    try std.testing.expectEqualStrings("1|3,4", (try evalSource(a, "let [first, , ...rest] = [1, 2, 3, 4]; first + '|' + rest")).string);
    // nested pattern
    try std.testing.expectEqual(@as(f64, 7), (try evalSource(a, "let { p: { x, y } } = { p: { x: 3, y: 4 } }; x + y")).number);
    // object rest collects the remaining own properties
    try std.testing.expectEqual(@as(f64, 5), (try evalSource(a, "let { a, ...others } = { a: 1, b: 2, c: 3 }; others.b + others.c")).number);
}

test "interpreter spread in arrays and calls" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // spread in an array literal
    try std.testing.expectEqualStrings("1,2,3,4", (try evalSource(a, "let xs = [2, 3]; '' + [1, ...xs, 4]")).string);
    // spread a string into an array
    try std.testing.expectEqualStrings("a,b,c", (try evalSource(a, "'' + [...'abc']")).string);
    // spread args into a call
    try std.testing.expectEqual(@as(f64, 6), (try evalSource(a,
        \\function add(a, b, c) { return a + b + c; }
        \\let args = [1, 2, 3];
        \\add(...args)
    )).number);
    // mixed fixed + spread args
    try std.testing.expectEqual(@as(f64, 10), (try evalSource(a,
        \\function add(a, b, c, d) { return a + b + c + d; }
        \\add(1, ...[2, 3], 4)
    )).number);
}

test "interpreter default and rest parameters" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // default used when arg missing/undefined
    try std.testing.expectEqual(@as(f64, 5), (try evalSource(a, "function f(a, b = 3) { return a + b; } f(2)")).number);
    try std.testing.expectEqual(@as(f64, 6), (try evalSource(a, "function f(a, b = 3) { return a + b; } f(2, 4)")).number);
    // default can reference an earlier parameter
    try std.testing.expectEqual(@as(f64, 4), (try evalSource(a, "function f(a, b = a * 2) { return b; } f(2)")).number);
    // rest collects remaining args into an array
    try std.testing.expectEqual(@as(f64, 3), (try evalSource(a, "function f(a, ...rest) { return rest.length; } f(1, 2, 3, 4)")).number);
    try std.testing.expectEqual(@as(f64, 30), (try evalSource(a,
        \\function sum(...xs) { let s = 0; for (let v of xs) { s = s + v; } return s; }
        \\sum(10, 20)
    )).number);
}

test "interpreter object method shorthand and computed keys" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // method shorthand binds this
    try std.testing.expectEqual(@as(f64, 10), (try evalSource(a,
        \\let o = { n: 10, get() { return this.n; } };
        \\o.get()
    )).number);
    // computed key
    try std.testing.expectEqual(@as(f64, 5), (try evalSource(a,
        \\let k = 'x';
        \\let o = { [k]: 5 };
        \\o.x
    )).number);
    // computed key from an expression
    try std.testing.expectEqualStrings("ok", (try evalSource(a,
        \\let o = { ['a' + 'b']: 'ok' };
        \\o.ab
    )).string);
}

test "interpreter labeled break and continue" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // labeled break exits the outer loop
    try std.testing.expectEqual(@as(f64, 23), (try evalSource(a,
        \\let hits = 0, found = 0;
        \\outer: for (let i = 0; i < 5; i++) {
        \\  for (let j = 0; j < 5; j++) {
        \\    hits = hits + 1;
        \\    if (i === 2 && j === 3) { found = i * 10 + j; break outer; }
        \\  }
        \\}
        \\found
    )).number);
    // labeled continue continues the outer loop
    try std.testing.expectEqual(@as(f64, 5), (try evalSource(a,
        \\let count = 0;
        \\outer: for (let i = 0; i < 5; i++) {
        \\  for (let j = 0; j < 5; j++) {
        \\    if (j === 1) { continue outer; }
        \\  }
        \\  count = count + 100; // never reached
        \\}
        \\let n = 0;
        \\outer2: for (let i = 0; i < 5; i++) { n = n + 1; continue outer2; }
        \\n
    )).number);
}

test "interpreter do-while and comma operator" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqual(@as(f64, 15), (try evalSource(a,
        \\let s = 0, i = 1;
        \\do { s = s + i; i = i + 1; } while (i <= 5);
        \\s
    )).number);
    // do-while body always runs at least once
    try std.testing.expectEqual(@as(f64, 1), (try evalSource(a,
        \\let n = 0;
        \\do { n = n + 1; } while (false);
        \\n
    )).number);
    // comma operator yields the last value
    try std.testing.expectEqual(@as(f64, 3), (try evalSource(a, "(1, 2, 3)")).number);
    try std.testing.expectEqual(@as(f64, 5), (try evalSource(a, "let x = 0; x = (x = 2, x + 3); x")).number);
}

test "interpreter for-of and for-in" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // for-of over an array
    try std.testing.expectEqual(@as(f64, 60), (try evalSource(a,
        \\let s = 0;
        \\for (let v of [10, 20, 30]) { s = s + v; }
        \\s
    )).number);
    // for-of over a string (concatenate chars)
    try std.testing.expectEqualStrings("abc", (try evalSource(a,
        \\let r = '';
        \\for (let c of 'abc') { r = r + c; }
        \\r
    )).string);
    // for-in over object keys
    try std.testing.expectEqualStrings("a,b,c", (try evalSource(a,
        \\let o = { a: 1, b: 2, c: 3 };
        \\let r = [];
        \\for (let k in o) { r.push(k); }
        \\'' + r
    )).string);
    // break inside for-of
    try std.testing.expectEqual(@as(f64, 3), (try evalSource(a,
        \\let n = 0;
        \\for (let v of [1, 2, 3, 4, 5]) { if (v === 3) { break; } n = v; }
        \\n + 1
    )).number);
}

test "interpreter template literals" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings("hello world", (try evalSource(a, "`hello world`")).string);
    try std.testing.expectEqualStrings("1 + 2 = 3", (try evalSource(a, "let x = 1, y = 2; `${x} + ${y} = ${x + y}`")).string);
    try std.testing.expectEqualStrings("a\nb", (try evalSource(a, "`a\\nb`")).string);
    // nested braces inside the substitution
    try std.testing.expectEqualStrings("v=7", (try evalSource(a, "let o = { n: 7 }; `v=${o.n}`")).string);
    // empty + leading substitution still yields a string
    try std.testing.expectEqualStrings("42", (try evalSource(a, "`${42}`")).string);
}

test "interpreter switch (match, fall-through, default, break)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqual(@as(f64, 20), (try evalSource(a,
        \\let r = 0;
        \\switch (2) { case 1: r = 10; break; case 2: r = 20; break; default: r = 99; }
        \\r
    )).number);
    // default when no case matches
    try std.testing.expectEqual(@as(f64, 99), (try evalSource(a,
        \\let r = 0;
        \\switch (7) { case 1: r = 10; break; default: r = 99; }
        \\r
    )).number);
    // fall-through (no break) accumulates
    try std.testing.expectEqual(@as(f64, 3), (try evalSource(a,
        \\let r = 0;
        \\switch (1) { case 1: r = r + 1; case 2: r = r + 2; break; case 3: r = r + 99; }
        \\r
    )).number);
}

test "interpreter multiple declarators and void" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqual(@as(f64, 6), (try evalSource(a, "let x = 1, y = 2, z = 3; x + y + z")).number);
    try std.testing.expect((try evalSource(a, "void 5 === undefined")).boolean);
}

test "interpreter break / continue" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // break stops at 5
    try std.testing.expectEqual(@as(f64, 5), (try evalSource(a,
        \\let n = 0;
        \\for (let i = 0; i < 100; i++) { if (i === 5) { break; } n = i; }
        \\n + 1
    )).number);
    // continue skips even numbers -> sum of odds 1..9 = 25
    try std.testing.expectEqual(@as(f64, 25), (try evalSource(a,
        \\let sum = 0;
        \\for (let i = 0; i < 10; i++) { if (i % 2 === 0) { continue; } sum += i; }
        \\sum
    )).number);
}
