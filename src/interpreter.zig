const std = @import("std");
const ast = @import("ast.zig");
const value = @import("value.zig");
const bc = @import("bytecode.zig");
const builtins = @import("builtins.zig");
const regex = @import("regex");
const vm = @import("vm.zig");
const Compiler = @import("compiler.zig").Compiler;
const Shape = @import("shape.zig").Shape;

const Node = ast.Node;
const Value = value.Value;

/// Robustness limits so adversarial input throws a catchable error instead of
/// crashing the process (stack overflow / runaway loop).
pub const max_call_depth: u32 = 2000;
pub const max_steps: u64 = 100_000_000;

/// Coerce a JS number to a length/index, clamping NaN/negative to 0 and huge
/// values to a cap (so `@intFromFloat` never panics; oversized allocations then
/// fail gracefully as OutOfMemory).
pub fn toLen(n: f64) usize {
    if (std.math.isNan(n) or n <= 0) return 0;
    if (n > 4294967295) return 4294967295;
    return @intFromFloat(@trunc(n));
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
    arena: std.mem.Allocator,
    parent: ?*Environment = null,

    /// Define (or overwrite) a binding in *this* scope (used by var/let/const).
    pub fn put(self: *Environment, name: []const u8, v: Value) EvalError!void {
        const gop = try self.vars.getOrPut(self.arena, name);
        if (!gop.found_existing) gop.key_ptr.* = try self.arena.dupe(u8, name);
        gop.value_ptr.* = v;
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

    /// Look up a binding, walking outward through enclosing scopes.
    pub fn get(self: *Environment, name: []const u8) ?Value {
        var env: ?*Environment = self;
        while (env) |e| {
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
};

/// Non-local control flow the tree-walker propagates up the statement list:
/// `ret` unwinds to the enclosing function, `brk`/`cont` to the enclosing loop.
const Signal = enum { none, ret, brk, cont };

/// Tree-walking evaluator. Evaluating a program/block returns the completion
/// value of the last statement, which is what `JSEvaluateScript` hands back.
pub const Interpreter = struct {
    arena: std.mem.Allocator,
    env: *Environment,
    /// The Context's empty root shape — the origin of every object's shape
    /// transition chain (see shape.zig).
    root_shape: *Shape,
    signal: Signal = .none,
    ret_value: Value = .undefined,
    /// The `this` binding for the currently-executing function (undefined at
    /// top level / in plain calls; the receiver in method calls; the new object
    /// in constructor calls).
    this_value: Value = .undefined,
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

    /// Build an `Error`-family instance with `name`/`message` properties.
    fn makeError(self: *Interpreter, name: []const u8, message: []const u8) EvalError!Value {
        const obj = try self.arena.create(value.Object);
        obj.* = .{ .is_error = true, .error_name = name };
        try self.setProp(obj, "name", .{ .string = name });
        try self.setProp(obj, "message", .{ .string = message });
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
            .string => |s| .{ .string = s },
            .boolean => |b| .{ .boolean = b },
            .null_lit => .null,
            .undefined_lit => .undefined,
            .this_expr => self.this_value,
            .identifier => |name| blk: {
                // `with` scope objects take precedence over the lexical env.
                if (self.with_stack.items.len > 0) {
                    var i = self.with_stack.items.len;
                    while (i > 0) : (i -= 1) {
                        const o = self.with_stack.items[i - 1];
                        if (hasProperty(o, name)) break :blk try self.getProperty(.{ .object = o }, name);
                    }
                }
                break :blk self.env.get(name) orelse return self.throwError("ReferenceError", name);
            },

            .unary => |u| try self.evalUnary(u.op, u.operand),
            .update => |u| try self.evalUpdate(u.inc, u.prefix, u.target),
            .binary => |b| try self.evalBinary(b.op, b.left, b.right),
            .logical => |l| try self.evalLogical(l.op, l.left, l.right),
            .sequence => |s| blk: {
                _ = try self.eval(s.first);
                break :blk try self.eval(s.second);
            },

            .assign => |a| blk: {
                const v = try self.eval(a.value);
                try self.assignTo(a.target, v);
                break :blk v;
            },

            .function => |fnode| try self.makeFunction(fnode, self.env),
            .class_expr => |c| try self.evalClass(c.name, c.superclass, c.members),

            // `yield` only executes inside a compiled generator body (on the
            // suspendable VM). Reaching it in the tree-walker means a generator
            // body fell outside the VM's lowered subset — report it clearly
            // rather than producing a wrong value.
            .yield_expr => return self.throwError("SyntaxError", "yield is only supported in VM-compiled generator bodies"),

            .super_call => |sc| blk: {
                const sup = self.super_ctor orelse return self.throwError("SyntaxError", "'super' keyword unexpected here");
                const args = try self.evalArgs(sc);
                // Run the superclass constructor on the current `this`.
                _ = try self.callValueWithThis(.{ .object = sup }, args, self.this_value);
                break :blk .undefined;
            },
            .super_member => |m| blk: {
                const parent = (self.home_object orelse return self.throwError("SyntaxError", "'super' outside a method")).proto orelse break :blk .undefined;
                const key = try self.memberKey(m.property, m.computed);
                break :blk try self.getProperty(.{ .object = parent }, key);
            },

            .call => |c| try self.evalCall(c.callee, c.args, c.optional),
            .new_expr => |n| try self.evalNew(n.callee, n.args),
            .member => |m| blk: {
                const obj = try self.eval(m.object);
                if (m.optional and (obj == .null or obj == .undefined)) return error.OptShortCircuit;
                break :blk try self.getProperty(obj, try self.memberKey(m.property, m.computed));
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
                const v: Value = if (d.init) |init_node| try self.eval(init_node) else .undefined;
                try self.env.put(d.name, v);
                break :blk .undefined;
            },

            .func_decl => |fnode| blk: {
                const fnv = try self.makeFunction(fnode, self.env);
                try self.env.put(fnode.name, fnv);
                break :blk .undefined;
            },

            .destructure_decl => |d| blk: {
                const v = try self.eval(d.init);
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

            .block => |stmts| try self.evalStatements(stmts),
            .program => |stmts| try self.evalStatements(stmts),

            .if_stmt => |s| if ((try self.eval(s.cond)).toBoolean())
                try self.eval(s.consequent)
            else if (s.alternate) |alt|
                try self.eval(alt)
            else
                .undefined,

            .with_stmt => |w| blk: {
                const obj = try self.eval(w.obj);
                if (obj != .object) return self.throwError("TypeError", "with(non-object)");
                try self.with_stack.append(self.arena, obj.object);
                const result = self.eval(w.body);
                _ = self.with_stack.pop();
                break :blk try result;
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
            .for_in => |f| try self.evalForInOf(f.decl_kind, f.name, f.iterable, f.body, f.is_of),
        };
    }

    /// `for-of` (values of arrays/strings) and `for-in` (own keys of objects /
    /// indices of arrays). Each iteration binds the loop variable then runs the
    /// body, honoring break/continue/return.
    fn evalForInOf(self: *Interpreter, decl_kind: ?ast.DeclKind, name: []const u8, iterable: *Node, body: *Node, is_of: bool) EvalError!Value {
        const my_label = self.takeLabel();
        const iter = try self.eval(iterable);
        var last: Value = .undefined;
        if (is_of) {
            switch (iter) {
                .object => |o| {
                    if (o.gen != null) {
                        // Drive the generator: `for (x of gen)` pulls `.next()`
                        // until `{ done: true }`.
                        while (true) {
                            const res = try vm.genNext(self, o, .undefined);
                            if ((try self.getProperty(res, "done")).toBoolean()) break;
                            try self.bindLoopVar(decl_kind, name, try self.getProperty(res, "value"));
                            last = try self.eval(body);
                            if (self.loopSignal(my_label)) |stop| if (stop) break;
                        }
                    } else if (o.is_array) {
                        var i: usize = 0;
                        while (i < o.elements.items.len) : (i += 1) {
                            try self.bindLoopVar(decl_kind, name, o.elements.items[i]);
                            last = try self.eval(body);
                            if (self.loopSignal(my_label)) |stop| if (stop) break;
                        }
                    } else return self.throwError("TypeError", "value is not iterable");
                },
                .string => |s| {
                    for (s) |ch| {
                        const one = try self.arena.dupe(u8, &.{ch});
                        try self.bindLoopVar(decl_kind, name, .{ .string = one });
                        last = try self.eval(body);
                        if (self.loopSignal(my_label)) |stop| if (stop) break;
                    }
                },
                else => return self.throwError("TypeError", "value is not iterable"),
            }
        } else {
            // for-in: enumerate keys (skip null/undefined per spec).
            switch (iter) {
                .object => |o| {
                    if (o.is_array) {
                        var i: usize = 0;
                        while (i < o.elements.items.len) : (i += 1) {
                            const key = try std.fmt.allocPrint(self.arena, "{d}", .{i});
                            try self.bindLoopVar(decl_kind, name, .{ .string = key });
                            last = try self.eval(body);
                            if (self.loopSignal(my_label)) |stop| if (stop) break;
                        }
                    } else {
                        const keys = try o.ownKeys(self.arena);
                        for (keys) |k| {
                            try self.bindLoopVar(decl_kind, name, .{ .string = k });
                            last = try self.eval(body);
                            if (self.loopSignal(my_label)) |stop| if (stop) break;
                        }
                    }
                },
                .undefined, .null => {}, // iterating null/undefined is a no-op
                else => {},
            }
        }
        return last;
    }

    fn bindLoopVar(self: *Interpreter, decl_kind: ?ast.DeclKind, name: []const u8, v: Value) EvalError!void {
        if (decl_kind != null) try self.env.put(name, v) else try self.env.assign(name, v);
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
        if (init_node) |ini| _ = try self.eval(ini);
        var last: Value = .undefined;
        while (true) {
            if (cond) |c| {
                if (!(try self.eval(c)).toBoolean()) break;
            }
            last = try self.eval(body);
            if (self.loopSignal(my_label)) |stop| if (stop) break;
            if (update) |u| _ = try self.eval(u);
        }
        return last;
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
        const old = (try self.eval(target)).toNumber();
        const updated = if (inc) old + 1 else old - 1;
        try self.assignTo(target, .{ .number = updated });
        return .{ .number = if (prefix) updated else old };
    }

    fn evalStatements(self: *Interpreter, stmts: []*Node) EvalError!Value {
        var last: Value = .undefined;
        for (stmts) |s| {
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
            .is_generator = fnode.is_generator,
        };
        // Compile a generator body up front for the suspendable VM. Bodies
        // outside the VM's lowered subset leave `gen_chunk` null, so calling the
        // generator throws a clear TypeError rather than running incorrectly.
        if (fnode.is_generator) {
            func.gen_chunk = Compiler.compileGenerator(self.arena, fnode) catch |e| switch (e) {
                error.Unsupported => null,
                error.OutOfMemory => return error.OutOfMemory,
            };
        }
        const obj = try self.arena.create(value.Object);
        obj.* = .{ .js_func = @ptrCast(func) };
        return .{ .object = obj };
    }

    fn funcOf(v: Value) ?*Function {
        if (v == .object) {
            if (v.object.js_func) |e| return @ptrCast(@alignCast(e));
        }
        return null;
    }

    /// Evaluate a `class` to a constructor function value: methods go on its
    /// `.prototype`, static members on the class object itself, and instance
    /// fields are desugared into the constructor (`this.f = init`). With
    /// `extends`, the prototypes are linked and methods get a home object so
    /// `super.x` / `super(...)` resolve. (Accessors are still deferred.)
    fn evalClass(self: *Interpreter, name: []const u8, superclass: ?*Node, members: []ast.ClassMember) EvalError!Value {
        var super_obj: ?*value.Object = null;
        var super_proto: ?*value.Object = null;
        if (superclass) |sc| {
            const sv = try self.eval(sc);
            if (sv != .object) return self.throwError("TypeError", "class extends value is not a constructor");
            super_obj = sv.object;
            super_proto = try self.protoObject(sv.object);
        }
        return self.buildClass(name, members, super_obj, super_proto);
    }

    fn buildClass(self: *Interpreter, name: []const u8, members: []ast.ClassMember, super_obj: ?*value.Object, super_proto: ?*value.Object) EvalError!Value {
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
            .is_expr_body = false,
        };
        const class_val = try self.makeFunction(fnode, self.env);
        const class_obj = class_val.object;
        const proto = try self.protoObject(class_obj);

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
            // `static { ... }` block: run with `this` = the class object.
            if (m.static_block) |block| {
                const saved_this = self.this_value;
                self.this_value = class_val;
                _ = self.eval(block) catch |e| {
                    self.this_value = saved_this;
                    return e;
                };
                self.this_value = saved_this;
                continue;
            }
            const key = if (m.key_expr) |ke| try (try self.eval(ke)).toString(self.arena) else m.key;
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
        }
        try self.setProp(proto, "constructor", class_val);
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

    /// Expand an iterable (array or string) into `list` — for `...spread`.
    fn spreadInto(self: *Interpreter, list: *std.ArrayListUnmanaged(Value), v: Value) EvalError!void {
        switch (v) {
            .object => |o| {
                if (!o.is_array) return self.throwError("TypeError", "spread value is not iterable");
                for (o.elements.items) |e| try list.append(self.arena, e);
            },
            .string => |s| {
                for (s) |ch| try list.append(self.arena, .{ .string = try self.arena.dupe(u8, &.{ch}) });
            },
            else => return self.throwError("TypeError", "spread value is not iterable"),
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
        if (obj.error_ctor) |name| return self.makeErrorWithArgs(name, args);
        if (obj.native) |nf| return nf(@ptrCast(self), this_val, args);
        if (obj.js_func) |erased| {
            const func: *Function = @ptrCast(@alignCast(erased));
            return self.callFunction(func, args, this_val);
        }
        return self.throwError("TypeError", "value is not a function");
    }

    fn makeErrorWithArgs(self: *Interpreter, name: []const u8, args: []const Value) EvalError!Value {
        const msg = if (args.len > 0 and args[0] != .undefined) try args[0].toString(self.arena) else "";
        return self.makeError(name, msg);
    }

    fn callFunction(self: *Interpreter, func: *Function, args: []const Value, this_val: Value) EvalError!Value {
        // Calling a `function*` builds a generator object (its body runs lazily,
        // on the suspendable VM, via `.next()`).
        if (func.is_generator) return vm.makeGenerator(self, func, args, this_val);
        if (self.depth >= max_call_depth) return self.throwError("RangeError", "Maximum call stack size exceeded");
        self.depth += 1;
        defer self.depth -= 1;

        const call_env = try self.arena.create(Environment);
        call_env.* = .{ .arena = self.arena, .parent = func.closure };

        const saved_env = self.env;
        const saved_signal = self.signal;
        const saved_ret = self.ret_value;
        const saved_this = self.this_value;
        const saved_home = self.home_object;
        const saved_super = self.super_ctor;
        self.env = call_env;
        self.signal = .none;
        self.this_value = this_val;
        self.home_object = func.home_object;
        self.super_ctor = func.super_ctor;
        defer {
            self.env = saved_env;
            self.signal = saved_signal;
            self.ret_value = saved_ret;
            self.this_value = saved_this;
            self.home_object = saved_home;
            self.super_ctor = saved_super;
        }

        // Non-arrow functions get an `arguments` array-like over the call args.
        if (!func.is_arrow) {
            const args_obj = try self.newArray();
            for (args) |av| try args_obj.object.elements.append(self.arena, av);
            try call_env.put("arguments", args_obj);
        }

        // Bind parameters in `call_env` (so a default can reference earlier
        // params). A rest parameter collects the remaining args into an array.
        for (func.params, 0..) |p, i| {
            if (p.is_rest) {
                const rest = try self.newArray();
                var j = i;
                while (j < args.len) : (j += 1) try rest.object.elements.append(self.arena, args[j]);
                try call_env.put(p.name, rest);
                break;
            }
            var v: Value = if (i < args.len) args[i] else .undefined;
            if (v == .undefined) {
                if (p.default) |d| v = try self.eval(d);
            }
            if (p.pattern) |pat| try self.bindPattern(pat, v, true) else try call_env.put(p.name, v);
        }

        if (func.is_expr_body) return self.eval(func.body);
        _ = try self.eval(func.body);
        return if (self.signal == .ret) self.ret_value else .undefined;
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
    pub fn construct(self: *Interpreter, callee: Value, args: []const Value) EvalError!Value {
        if (callee != .object) return self.throwError("TypeError", "value is not a constructor");
        const obj = callee.object;
        if (obj.error_ctor) |name| return self.makeErrorWithArgs(name, args);
        if (obj.native) |nf| return nf(@ptrCast(self), .undefined, args); // native ctor (RegExp, ...)
        if (obj.js_func) |erased| {
            const func: *Function = @ptrCast(@alignCast(erased));
            const this_val = try self.newInstance(obj);
            const ret = try self.callFunction(func, args, this_val);
            return if (ret == .object) ret else this_val;
        }
        return self.throwError("TypeError", "value is not a constructor");
    }

    // ---- objects, arrays, members -----------------------------------------

    fn memberKey(self: *Interpreter, static: []const u8, computed: ?*Node) EvalError![]const u8 {
        if (computed) |ce| return (try self.eval(ce)).toString(self.arena);
        return static;
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
        return proto;
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
        obj.* = .{ .is_array = true };
        return .{ .object = obj };
    }

    fn evalObjectLit(self: *Interpreter, props: []ast.Property) EvalError!Value {
        const v = try self.newObject();
        for (props) |p| {
            const key = if (p.key_expr) |ke| try (try self.eval(ke)).toString(self.arena) else p.key;
            switch (p.accessor) {
                .none => try self.setProp(v.object, key, try self.eval(p.value)),
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
        try self.setProp(o, "source", .{ .string = try self.arena.dupe(u8, pattern) });
        try self.setProp(o, "flags", .{ .string = try self.arena.dupe(u8, flags) });
        try self.setProp(o, "lastIndex", .{ .number = 0 });
        try self.setProp(o, "global", .{ .boolean = std.mem.indexOfScalar(u8, flags, 'g') != null });
        try self.setProp(o, "ignoreCase", .{ .boolean = std.mem.indexOfScalar(u8, flags, 'i') != null });
        try self.setProp(o, "multiline", .{ .boolean = std.mem.indexOfScalar(u8, flags, 'm') != null });
        return .{ .object = o };
    }

    fn compileRegex(self: *Interpreter, o: *value.Object) EvalError!regex.Regex {
        const src = (o.getOwn("source") orelse Value{ .string = "" }).string;
        const flags = (o.getOwn("flags") orelse Value{ .string = "" }).string;
        const cf = regex.common.CompileFlags{
            .case_insensitive = std.mem.indexOfScalar(u8, flags, 'i') != null,
            .multiline = std.mem.indexOfScalar(u8, flags, 'm') != null,
        };
        return regex.Regex.compileWithFlags(self.arena, src, cf) catch
            return self.throwError("SyntaxError", "invalid regular expression");
    }

    fn regexMethod(self: *Interpreter, o: *value.Object, name: []const u8, args: []const Value) EvalError!?Value {
        if (eq(name, "test")) {
            const input = try arg0(args).toString(self.arena);
            var re = try self.compileRegex(o);
            return Value{ .boolean = re.isMatch(input) catch false };
        }
        if (eq(name, "exec")) {
            const input = try arg0(args).toString(self.arena);
            var re = try self.compileRegex(o);
            const found = re.find(input) catch null;
            if (found) |m| {
                const arr = try self.newArray();
                try arr.object.elements.append(self.arena, .{ .string = try self.arena.dupe(u8, m.slice) });
                for (m.captures) |c| try arr.object.elements.append(self.arena, .{ .string = try self.arena.dupe(u8, c) });
                try self.setProp(arr.object, "index", .{ .number = @floatFromInt(m.start) });
                try self.setProp(arr.object, "input", .{ .string = input });
                return arr;
            }
            return Value.null;
        }
        if (eq(name, "toString")) {
            const src = (o.getOwn("source") orelse Value{ .string = "" }).string;
            const flags = (o.getOwn("flags") orelse Value{ .string = "" }).string;
            return Value{ .string = try std.mem.concat(self.arena, u8, &.{ "/", src, "/", flags }) };
        }
        return null;
    }

    /// Build a `Map`, optionally populated from an iterable of `[k,v]` pairs.
    pub fn makeMap(self: *Interpreter, init_v: Value) EvalError!Value {
        const o = (try self.newObject()).object;
        o.is_map = true;
        try self.setProp(o, "size", .{ .number = 0 });
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
        try self.setProp(o, "size", .{ .number = 0 });
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
                if (value.strictEquals(e.object.elements.items[0], k)) {
                    e.object.elements.items[1] = arg(args, 1);
                    return self_v;
                }
            }
            const pair = (try self.newArray()).object;
            try pair.elements.append(self.arena, k);
            try pair.elements.append(self.arena, arg(args, 1));
            try o.elements.append(self.arena, .{ .object = pair });
            try self.setProp(o, "size", .{ .number = @floatFromInt(o.elements.items.len) });
            return self_v;
        }
        if (eq(name, "get")) {
            for (o.elements.items) |e| {
                if (value.strictEquals(e.object.elements.items[0], arg0(args))) return e.object.elements.items[1];
            }
            return Value.undefined;
        }
        if (eq(name, "has")) {
            for (o.elements.items) |e| {
                if (value.strictEquals(e.object.elements.items[0], arg0(args))) return Value{ .boolean = true };
            }
            return Value{ .boolean = false };
        }
        if (eq(name, "delete")) {
            for (o.elements.items, 0..) |e, i| {
                if (value.strictEquals(e.object.elements.items[0], arg0(args))) {
                    _ = o.elements.orderedRemove(i);
                    try self.setProp(o, "size", .{ .number = @floatFromInt(o.elements.items.len) });
                    return Value{ .boolean = true };
                }
            }
            return Value{ .boolean = false };
        }
        if (eq(name, "clear")) {
            o.elements.clearRetainingCapacity();
            try self.setProp(o, "size", .{ .number = 0 });
            return Value.undefined;
        }
        if (eq(name, "forEach")) {
            const cb = arg0(args);
            for (o.elements.items) |e| _ = try self.callValue(cb, &.{ e.object.elements.items[1], e.object.elements.items[0], self_v });
            return Value.undefined;
        }
        return null;
    }

    fn setMethod(self: *Interpreter, o: *value.Object, name: []const u8, args: []const Value) EvalError!?Value {
        const self_v = Value{ .object = o };
        if (eq(name, "add")) {
            for (o.elements.items) |e| {
                if (value.strictEquals(e, arg0(args))) return self_v;
            }
            try o.elements.append(self.arena, arg0(args));
            try self.setProp(o, "size", .{ .number = @floatFromInt(o.elements.items.len) });
            return self_v;
        }
        if (eq(name, "has")) {
            for (o.elements.items) |e| {
                if (value.strictEquals(e, arg0(args))) return Value{ .boolean = true };
            }
            return Value{ .boolean = false };
        }
        if (eq(name, "delete")) {
            for (o.elements.items, 0..) |e, i| {
                if (value.strictEquals(e, arg0(args))) {
                    _ = o.elements.orderedRemove(i);
                    try self.setProp(o, "size", .{ .number = @floatFromInt(o.elements.items.len) });
                    return Value{ .boolean = true };
                }
            }
            return Value{ .boolean = false };
        }
        if (eq(name, "clear")) {
            o.elements.clearRetainingCapacity();
            try self.setProp(o, "size", .{ .number = 0 });
            return Value.undefined;
        }
        if (eq(name, "forEach")) {
            const cb = arg0(args);
            for (o.elements.items) |e| _ = try self.callValue(cb, &.{ e, e, self_v });
            return Value.undefined;
        }
        return null;
    }

    fn evalArrayLit(self: *Interpreter, elems: []*Node) EvalError!Value {
        const v = try self.newArray();
        for (elems) |en| {
            if (en.* == .spread) {
                try self.spreadInto(&v.object.elements, try self.eval(en.spread));
            } else {
                try v.object.elements.append(self.arena, try self.eval(en));
            }
        }
        return v;
    }

    /// `index`-as-string -> array element index, or null if not an integer.
    fn arrayIndex(key: []const u8) ?usize {
        if (key.len == 0) return null;
        for (key) |c| if (!std.ascii.isDigit(c)) return null;
        return std.fmt.parseInt(usize, key, 10) catch null;
    }

    pub fn getProperty(self: *Interpreter, recv: Value, key: []const u8) EvalError!Value {
        switch (recv) {
            .object => |o| {
                if (o.is_array) {
                    if (std.mem.eql(u8, key, "length"))
                        return .{ .number = @floatFromInt(o.elements.items.len) };
                    if (arrayIndex(key)) |i| {
                        if (i < o.elements.items.len) return o.elements.items[i];
                        // else fall through: may be a sparse named property.
                    }
                }
                // Accessor or data, then walk the prototype chain.
                var cur: ?*value.Object = o;
                while (cur) |c| {
                    if (c.getAccessor(key)) |acc| {
                        if (acc.get) |g| return self.callValueWithThis(g, &.{}, recv);
                        return .undefined; // accessor with no getter
                    }
                    if (c.getOwn(key)) |v| return v;
                    cur = c.proto;
                }
                return .undefined;
            },
            .string => |s| {
                if (std.mem.eql(u8, key, "length")) return .{ .number = @floatFromInt(s.len) };
                if (arrayIndex(key)) |i| {
                    if (i < s.len) return .{ .string = try self.arena.dupe(u8, s[i .. i + 1]) };
                    return .undefined;
                }
                return .undefined;
            },
            .undefined, .null => return self.throwError("TypeError", "cannot read property of null or undefined"),
            else => return .undefined,
        }
    }

    // ---- destructuring ----------------------------------------------------

    /// Bind a value to a destructuring target. `declare` selects whether leaf
    /// identifiers are declared in the current scope (`let {a}=…`) or assigned
    /// to an existing binding / member (`({a}=…)` and parameter binding uses
    /// declare).
    fn bindPattern(self: *Interpreter, target: *Node, val: Value, declare: bool) EvalError!void {
        switch (target.*) {
            .identifier => |name| if (declare) try self.env.put(name, val) else try self.env.assign(name, val),
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
            const key = if (prop.key_expr) |ke| try (try self.eval(ke)).toString(self.arena) else prop.key;
            try consumed.append(self.arena, key);
            var v = try self.getProperty(val, key);
            if (v == .undefined) {
                if (prop.default) |d| v = try self.eval(d);
            }
            try self.bindPattern(prop.target, v, declare);
        }
        if (rest) |rest_name| {
            const rest_obj = try self.newObject();
            if (val == .object) {
                const keys = try val.object.ownKeys(self.arena);
                outer: for (keys) |k| {
                    for (consumed.items) |c| {
                        if (std.mem.eql(u8, c, k)) continue :outer;
                    }
                    try self.setProp(rest_obj.object, k, val.object.getOwn(k) orelse .undefined);
                }
            }
            if (declare) try self.env.put(rest_name, rest_obj) else try self.env.assign(rest_name, rest_obj);
        }
    }

    fn destructureArray(self: *Interpreter, elems: []ast.ArrPatElem, rest: ?*Node, val: Value, declare: bool) EvalError!void {
        if (val == .undefined or val == .null)
            return self.throwError("TypeError", "cannot destructure null or undefined");
        var idx: usize = 0;
        for (elems) |elem| {
            var v = try self.elementAt(val, idx);
            idx += 1;
            if (elem.target) |t| {
                if (v == .undefined) {
                    if (elem.default) |d| v = try self.eval(d);
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

    fn assignTo(self: *Interpreter, target: *Node, v: Value) EvalError!void {
        switch (target.*) {
            .identifier => |name| {
                // Assigning a name found on a `with` object writes to that object.
                if (self.with_stack.items.len > 0) {
                    var i = self.with_stack.items.len;
                    while (i > 0) : (i -= 1) {
                        const o = self.with_stack.items[i - 1];
                        if (hasProperty(o, name)) return self.setMember(.{ .object = o }, name, v);
                    }
                }
                try self.env.assign(name, v);
            },
            .member => |m| {
                const recv = try self.eval(m.object);
                const key = try self.memberKey(m.property, m.computed);
                try self.setMember(recv, key, v);
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
        if (recv != .object) return self.throwError("TypeError", "cannot set property of non-object");
        const o = recv.object;
        if (o.is_array) {
            if (arrayIndex(key)) |i| {
                if (i < o.elements.items.len) {
                    o.elements.items[i] = v;
                    return;
                }
                // Grow densely only for near-contiguous, bounded indices; large
                // or gappy indices become sparse named properties (no giant alloc).
                const dense_cap: usize = 1 << 24;
                if (i < dense_cap and i <= o.elements.items.len + 1024) {
                    while (o.elements.items.len <= i) try o.elements.append(self.arena, .undefined);
                    o.elements.items[i] = v;
                    return;
                }
                // fall through: store as a named (sparse) property
            }
        }
        // A setter anywhere on the prototype chain intercepts the assignment.
        var cur: ?*value.Object = o;
        while (cur) |c| {
            if (c.getAccessor(key)) |acc| {
                if (acc.set) |s| _ = try self.callValueWithThis(s, &.{v}, recv);
                return; // setter-less accessor: ignore (sloppy mode)
            }
            cur = c.proto;
        }
        try self.setProp(o, key, v);
    }

    /// Define an accessor (get/set) on an object via its `setAccessor`.
    fn defineAccessor(self: *Interpreter, obj: *value.Object, name: []const u8, get: ?Value, set: ?Value) EvalError!void {
        try obj.setAccessor(self.arena, name, get, set);
    }

    /// Call `recv[name](args)` with `this = recv`. Dispatches the builtin
    /// methods that aren't stored as own properties first. Shared by the
    /// tree-walker's `evalCall` and the VM's `call_method`.
    pub fn callMethod(self: *Interpreter, recv: Value, name: []const u8, args: []const Value) EvalError!Value {
        if (try self.builtinMethod(recv, name, args)) |result| return result;
        const method = try self.getProperty(recv, name);
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
                if (hasProperty(o, "next")) return v; // already an iterator (manual or generator-like)
                if (o.is_array) return self.makeCursorIterator(v);
                return self.throwError("TypeError", "value is not iterable");
            },
            .string => return self.makeCursorIterator(v),
            else => return self.throwError("TypeError", "value is not iterable"),
        }
    }

    /// Wrap an array/string in an iterator object: `__src` + `__i` own properties
    /// plus a shared native `next` that reads/advances them.
    fn makeCursorIterator(self: *Interpreter, src: Value) EvalError!Value {
        const it = try self.arena.create(value.Object);
        it.* = .{};
        try self.setProp(it, "__src", src);
        try self.setProp(it, "__i", .{ .number = 0 });
        try setNative(self.arena, self.root_shape, it, "next", cursorIterNext);
        return .{ .object = it };
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
                if (o.is_regex) return try self.regexMethod(o, name, args);
                if (o.is_map) return try self.mapMethod(o, name, args);
                if (o.is_set) return try self.setMethod(o, name, args);
                if (o.is_array and o.getOwn(name) == null) return try self.arrayMethod(o, name, args);
            },
            .string => |s| return try self.stringMethod(s, name, args),
            .number => |n| return try self.numberMethod(n, name, args),
            .boolean => |b| return try self.booleanMethod(b, name, args),
            else => {},
        }
        return null;
    }

    fn eq(a: []const u8, b: []const u8) bool {
        return std.mem.eql(u8, a, b);
    }

    /// Normalize a relative index (negative counts from the end) into [0, len].
    fn relIndex(v: Value, len: usize, default: f64) usize {
        const n = if (v == .undefined) default else v.toNumber();
        if (std.math.isNan(n)) return 0;
        const fl = @trunc(n);
        if (fl < 0) {
            const from_end = @as(f64, @floatFromInt(len)) + fl;
            return if (from_end < 0) 0 else @intFromFloat(from_end);
        }
        const flen: f64 = @floatFromInt(len);
        return if (fl > flen) len else @intFromFloat(fl);
    }

    fn arrayMethod(self: *Interpreter, o: *value.Object, name: []const u8, args: []const Value) EvalError!?Value {
        const items = o.elements.items;
        if (eq(name, "push")) {
            for (args) |a| try o.elements.append(self.arena, a);
            return Value{ .number = @floatFromInt(o.elements.items.len) };
        }
        if (eq(name, "pop")) return if (items.len == 0) Value.undefined else (o.elements.pop() orelse Value.undefined);
        if (eq(name, "shift")) {
            if (items.len == 0) return Value.undefined;
            const first = items[0];
            _ = o.elements.orderedRemove(0);
            return first;
        }
        if (eq(name, "unshift")) {
            var i: usize = args.len;
            while (i > 0) : (i -= 1) try o.elements.insert(self.arena, 0, args[i - 1]);
            return Value{ .number = @floatFromInt(o.elements.items.len) };
        }
        if (eq(name, "indexOf")) {
            const target = arg0(args);
            for (items, 0..) |el, i| if (value.strictEquals(el, target)) return Value{ .number = @floatFromInt(i) };
            return Value{ .number = -1 };
        }
        if (eq(name, "includes")) {
            const target = arg0(args);
            for (items) |el| if (value.strictEquals(el, target)) return Value{ .boolean = true };
            return Value{ .boolean = false };
        }
        if (eq(name, "join")) {
            const sep = if (args.len > 0 and args[0] != .undefined) try args[0].toString(self.arena) else ",";
            var buf: std.ArrayListUnmanaged(u8) = .empty;
            for (items, 0..) |el, i| {
                if (i != 0) try buf.appendSlice(self.arena, sep);
                switch (el) {
                    .undefined, .null => {},
                    else => try buf.appendSlice(self.arena, try el.toString(self.arena)),
                }
            }
            return Value{ .string = try buf.toOwnedSlice(self.arena) };
        }
        if (eq(name, "slice")) {
            const start = relIndex(arg0(args), items.len, 0);
            const end = relIndex(arg(args, 1), items.len, @floatFromInt(items.len));
            const result = try self.newArray();
            var i = start;
            while (i < end and i < items.len) : (i += 1) try result.object.elements.append(self.arena, items[i]);
            return result;
        }
        if (eq(name, "concat")) {
            const result = try self.newArray();
            for (items) |el| try result.object.elements.append(self.arena, el);
            for (args) |a| {
                if (a == .object and a.object.is_array) {
                    for (a.object.elements.items) |el| try result.object.elements.append(self.arena, el);
                } else try result.object.elements.append(self.arena, a);
            }
            return result;
        }
        if (eq(name, "reverse")) {
            std.mem.reverse(Value, o.elements.items);
            return Value{ .object = o };
        }
        if (eq(name, "map")) {
            const cb = arg0(args);
            const result = try self.newArray();
            for (items, 0..) |el, i| {
                const r = try self.callValue(cb, &.{ el, .{ .number = @floatFromInt(i) }, .{ .object = o } });
                try result.object.elements.append(self.arena, r);
            }
            return result;
        }
        if (eq(name, "filter")) {
            const cb = arg0(args);
            const result = try self.newArray();
            for (items, 0..) |el, i| {
                if ((try self.callValue(cb, &.{ el, .{ .number = @floatFromInt(i) }, .{ .object = o } })).toBoolean())
                    try result.object.elements.append(self.arena, el);
            }
            return result;
        }
        if (eq(name, "forEach")) {
            const cb = arg0(args);
            for (items, 0..) |el, i| _ = try self.callValue(cb, &.{ el, .{ .number = @floatFromInt(i) }, .{ .object = o } });
            return Value.undefined;
        }
        if (eq(name, "some")) {
            const cb = arg0(args);
            for (items, 0..) |el, i| {
                if ((try self.callValue(cb, &.{ el, .{ .number = @floatFromInt(i) }, .{ .object = o } })).toBoolean())
                    return Value{ .boolean = true };
            }
            return Value{ .boolean = false };
        }
        if (eq(name, "every")) {
            const cb = arg0(args);
            for (items, 0..) |el, i| {
                if (!(try self.callValue(cb, &.{ el, .{ .number = @floatFromInt(i) }, .{ .object = o } })).toBoolean())
                    return Value{ .boolean = false };
            }
            return Value{ .boolean = true };
        }
        if (eq(name, "find")) {
            const cb = arg0(args);
            for (items, 0..) |el, i| {
                if ((try self.callValue(cb, &.{ el, .{ .number = @floatFromInt(i) }, .{ .object = o } })).toBoolean()) return el;
            }
            return Value.undefined;
        }
        if (eq(name, "reduce")) {
            const cb = arg0(args);
            var acc: Value = undefined;
            var start: usize = 0;
            if (args.len >= 2) {
                acc = args[1];
            } else {
                if (items.len == 0) return self.throwError("TypeError", "Reduce of empty array with no initial value");
                acc = items[0];
                start = 1;
            }
            var i = start;
            while (i < items.len) : (i += 1) {
                acc = try self.callValue(cb, &.{ acc, items[i], .{ .number = @floatFromInt(i) }, .{ .object = o } });
            }
            return acc;
        }
        if (eq(name, "at")) {
            const fl = @trunc(arg0(args).toNumber());
            const idx: i64 = if (fl < 0) @as(i64, @intCast(items.len)) + @as(i64, @intFromFloat(fl)) else @intFromFloat(fl);
            if (idx < 0 or idx >= items.len) return Value.undefined;
            return items[@intCast(idx)];
        }
        if (eq(name, "lastIndexOf")) {
            const target = arg0(args);
            var i = items.len;
            while (i > 0) {
                i -= 1;
                if (value.strictEquals(items[i], target)) return Value{ .number = @floatFromInt(i) };
            }
            return Value{ .number = -1 };
        }
        if (eq(name, "findIndex")) {
            const cb = arg0(args);
            for (items, 0..) |el, i| {
                if ((try self.callValue(cb, &.{ el, .{ .number = @floatFromInt(i) }, .{ .object = o } })).toBoolean())
                    return Value{ .number = @floatFromInt(i) };
            }
            return Value{ .number = -1 };
        }
        if (eq(name, "fill")) {
            const v = arg0(args);
            const start = relIndex(arg(args, 1), items.len, 0);
            const end = relIndex(arg(args, 2), items.len, @floatFromInt(items.len));
            var i = start;
            while (i < end and i < items.len) : (i += 1) items[i] = v;
            return Value{ .object = o };
        }
        if (eq(name, "flat")) {
            const depth: f64 = if (args.len > 0 and args[0] != .undefined) arg0(args).toNumber() else 1;
            const result = try self.newArray();
            try self.flattenInto(result.object, items, depth);
            return result;
        }
        if (eq(name, "sort")) {
            const cmp = arg0(args);
            // Insertion sort so the comparator (which may throw) is `try`-able.
            var i: usize = 1;
            while (i < items.len) : (i += 1) {
                const key = items[i];
                var j = i;
                while (j > 0 and (try self.sortCompare(items[j - 1], key, cmp)) > 0) : (j -= 1) {
                    items[j] = items[j - 1];
                }
                items[j] = key;
            }
            return Value{ .object = o };
        }
        return null;
    }

    fn flattenInto(self: *Interpreter, dst: *value.Object, items: []const Value, depth: f64) EvalError!void {
        for (items) |el| {
            if (depth > 0 and el == .object and el.object.is_array) {
                try self.flattenInto(dst, el.object.elements.items, depth - 1);
            } else {
                try dst.elements.append(self.arena, el);
            }
        }
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
        if (eq(name, "toString") or eq(name, "toLocaleString")) {
            var radix: usize = 10;
            if (args.len > 0 and args[0] != .undefined) {
                const r = args[0].toNumber();
                if (r >= 2 and r <= 36) radix = @intFromFloat(r);
            }
            if (radix != 10 and @floor(n) == n and !std.math.isNan(n) and !std.math.isInf(n)) {
                return Value{ .string = try intToRadix(self.arena, n, radix) };
            }
            return Value{ .string = try value.numberToString(self.arena, n) };
        }
        if (eq(name, "toFixed")) {
            return Value{ .string = try toFixed(self.arena, n, @min(toLen(arg0(args).toNumber()), 18)) };
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

    fn stringMethod(self: *Interpreter, s: []const u8, name: []const u8, args: []const Value) EvalError!?Value {
        if (eq(name, "valueOf") or eq(name, "toString")) return Value{ .string = s };
        if (eq(name, "charAt")) {
            const i = relIndex(arg0(args), s.len, 0);
            return if (i < s.len) Value{ .string = try self.arena.dupe(u8, s[i .. i + 1]) } else Value{ .string = "" };
        }
        if (eq(name, "charCodeAt")) {
            const i = toLen(arg0(args).toNumber());
            return if (i < s.len) Value{ .number = @floatFromInt(s[i]) } else Value{ .number = std.math.nan(f64) };
        }
        if (eq(name, "indexOf")) {
            const sub = try arg0(args).toString(self.arena);
            return Value{ .number = if (std.mem.indexOf(u8, s, sub)) |idx| @floatFromInt(idx) else -1 };
        }
        if (eq(name, "includes")) {
            const sub = try arg0(args).toString(self.arena);
            return Value{ .boolean = std.mem.indexOf(u8, s, sub) != null };
        }
        if (eq(name, "startsWith")) {
            const sub = try arg0(args).toString(self.arena);
            return Value{ .boolean = std.mem.startsWith(u8, s, sub) };
        }
        if (eq(name, "endsWith")) {
            const sub = try arg0(args).toString(self.arena);
            return Value{ .boolean = std.mem.endsWith(u8, s, sub) };
        }
        if (eq(name, "slice")) {
            const start = relIndex(arg0(args), s.len, 0);
            const end = relIndex(arg(args, 1), s.len, @floatFromInt(s.len));
            return Value{ .string = if (start < end) try self.arena.dupe(u8, s[start..end]) else "" };
        }
        if (eq(name, "substring")) {
            var a0 = relIndex(arg0(args), s.len, 0);
            var b0 = relIndex(arg(args, 1), s.len, @floatFromInt(s.len));
            if (a0 > b0) {
                const t = a0;
                a0 = b0;
                b0 = t;
            }
            return Value{ .string = try self.arena.dupe(u8, s[a0..b0]) };
        }
        if (eq(name, "toUpperCase")) {
            const out = try self.arena.dupe(u8, s);
            for (out) |*c| c.* = std.ascii.toUpper(c.*);
            return Value{ .string = out };
        }
        if (eq(name, "toLowerCase")) {
            const out = try self.arena.dupe(u8, s);
            for (out) |*c| c.* = std.ascii.toLower(c.*);
            return Value{ .string = out };
        }
        if (eq(name, "trim")) return Value{ .string = std.mem.trim(u8, s, " \t\r\n") };
        if (eq(name, "repeat")) {
            const rn = arg0(args).toNumber();
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
            for (args) |a| try buf.appendSlice(self.arena, try a.toString(self.arena));
            return Value{ .string = try buf.toOwnedSlice(self.arena) };
        }
        if (eq(name, "split")) {
            const result = try self.newArray();
            if (args.len == 0 or args[0] == .undefined) {
                try result.object.elements.append(self.arena, .{ .string = try self.arena.dupe(u8, s) });
                return result;
            }
            const sep = try args[0].toString(self.arena);
            if (sep.len == 0) {
                for (s) |c| try result.object.elements.append(self.arena, .{ .string = try self.arena.dupe(u8, &.{c}) });
                return result;
            }
            var it = std.mem.splitSequence(u8, s, sep);
            while (it.next()) |part| try result.object.elements.append(self.arena, .{ .string = try self.arena.dupe(u8, part) });
            return result;
        }
        if (eq(name, "at")) {
            const fl = @trunc(arg0(args).toNumber());
            const idx: i64 = if (fl < 0) @as(i64, @intCast(s.len)) + @as(i64, @intFromFloat(fl)) else @intFromFloat(fl);
            if (idx < 0 or idx >= s.len) return Value.undefined;
            return Value{ .string = try self.arena.dupe(u8, s[@intCast(idx) .. @as(usize, @intCast(idx)) + 1]) };
        }
        if (eq(name, "trimStart")) {
            var a: usize = 0;
            while (a < s.len and (s[a] == ' ' or s[a] == '\t' or s[a] == '\r' or s[a] == '\n')) a += 1;
            return Value{ .string = s[a..] };
        }
        if (eq(name, "trimEnd")) {
            var e: usize = s.len;
            while (e > 0 and (s[e - 1] == ' ' or s[e - 1] == '\t' or s[e - 1] == '\r' or s[e - 1] == '\n')) e -= 1;
            return Value{ .string = s[0..e] };
        }
        if (eq(name, "padStart") or eq(name, "padEnd")) {
            const target = toLen(arg0(args).toNumber());
            if (s.len >= target) return Value{ .string = try self.arena.dupe(u8, s) };
            const pad = if (args.len > 1 and args[1] != .undefined) try args[1].toString(self.arena) else " ";
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
            const repl = try arg(args, 1).toString(self.arena);
            // Regex pattern: use zig-regex; honor the `g` flag (and replaceAll).
            if (arg0(args) == .object and arg0(args).object.is_regex) {
                const ro = arg0(args).object;
                const g = all or ((ro.getOwn("global") orelse Value{ .boolean = false }).boolean);
                var re = try self.compileRegex(ro);
                var buf: std.ArrayListUnmanaged(u8) = .empty;
                var rest = s;
                while (re.find(rest) catch null) |m| {
                    try buf.appendSlice(self.arena, rest[0..m.start]);
                    try buf.appendSlice(self.arena, repl);
                    const adv = if (m.end > m.start) m.end else m.start + 1;
                    if (adv > rest.len) break;
                    if (m.end == m.start and m.start < rest.len) try buf.append(self.arena, rest[m.start]);
                    rest = rest[adv..];
                    if (!g) break;
                }
                try buf.appendSlice(self.arena, rest);
                return Value{ .string = try buf.toOwnedSlice(self.arena) };
            }
            const pat = try arg0(args).toString(self.arena);
            if (pat.len == 0) return Value{ .string = try self.arena.dupe(u8, s) };
            var buf: std.ArrayListUnmanaged(u8) = .empty;
            var rest = s;
            while (std.mem.indexOf(u8, rest, pat)) |idx| {
                try buf.appendSlice(self.arena, rest[0..idx]);
                try buf.appendSlice(self.arena, repl);
                rest = rest[idx + pat.len ..];
                if (!all) break;
            }
            try buf.appendSlice(self.arena, rest);
            return Value{ .string = try buf.toOwnedSlice(self.arena) };
        }
        return null;
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
                if (t.catch_param) |p| try catch_env.put(p, exc);
                const saved = self.env;
                self.env = catch_env;
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
        const v = try self.eval(operand);
        return switch (op) {
            .neg => .{ .number = -v.toNumber() },
            .pos => .{ .number = v.toNumber() },
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
    pub fn applyBinary(self: *Interpreter, op: ast.BinaryOp, l: Value, r: Value) EvalError!Value {
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

    /// `x instanceof C`. v1 has a flat construction model: objects created by
    /// `new F()` carry `ctor_ref` pointing at F's object, and builtin error
    /// constructors carry `error_ctor`; this checks those links rather than a
    /// full prototype chain.
    /// `key in obj`: true if `obj` has the (own, since we lack a prototype
    /// chain) property or array index named by `key`.
    pub fn inOperator(self: *Interpreter, l: Value, r: Value) EvalError!bool {
        if (r != .object) return self.throwError("TypeError", "cannot use 'in' on a non-object");
        const o = r.object;
        const key = try l.toString(self.arena);
        if (o.getOwn(key) != null) return true;
        if (o.is_array) {
            if (std.mem.eql(u8, key, "length")) return true;
            if (arrayIndex(key)) |i| return i < o.elements.items.len;
        }
        return false;
    }

    pub fn instanceOf(self: *Interpreter, l: Value, r: Value) EvalError!bool {
        if (r != .object or !r.object.isCallableObject())
            return self.throwError("TypeError", "Right-hand side of 'instanceof' is not callable");
        if (l != .object) return false;
        const lo = l.object;
        const rc = r.object;
        // Prototype-chain check: is `rc.prototype` anywhere in `lo`'s proto chain?
        if (rc.getOwn("prototype")) |p| {
            if (p == .object) {
                var cur: ?*value.Object = lo.proto;
                while (cur) |c| {
                    if (c == p.object) return true;
                    cur = c.proto;
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

/// Install the engine's global bindings into `env`: the `Error`-family
/// constructors, `NaN`/`Infinity`/`undefined`, the `Math` and `Object`/`Array`
/// namespaces, and the common global functions. `root_shape` backs the property
/// stores of the namespace objects. Called once per Context, before user code.
pub fn installGlobals(env: *Environment, root_shape: *Shape) EvalError!void {
    const a = env.arena;
    const error_names = [_][]const u8{
        "Error",      "TypeError",  "RangeError", "ReferenceError",
        "SyntaxError", "EvalError", "URIError",
    };
    for (error_names) |name| {
        const o = try a.create(value.Object);
        o.* = .{ .error_ctor = name };
        try env.put(name, .{ .object = o });
    }
    try env.put("NaN", .{ .number = std.math.nan(f64) });
    try env.put("Infinity", .{ .number = std.math.inf(f64) });
    try env.put("undefined", .undefined);

    // Global functions.
    try defineGlobalFn(env, "parseInt", builtins.parseIntFn);
    try defineGlobalFn(env, "parseFloat", builtins.parseFloatFn);
    try defineGlobalFn(env, "isNaN", builtins.isNaNFn);
    try defineGlobalFn(env, "isFinite", builtins.isFiniteFn);
    try defineGlobalFn(env, "RegExp", builtins.regExpFn);
    try defineGlobalFn(env, "Map", builtins.mapFn);
    try defineGlobalFn(env, "Set", builtins.setFn);
    try defineGlobalFn(env, "WeakMap", builtins.mapFn);
    try defineGlobalFn(env, "WeakSet", builtins.setFn);
    try defineGlobalFn(env, "Boolean", builtins.booleanFn);

    // String — callable, with statics.
    const string_ns = try a.create(value.Object);
    string_ns.* = .{ .native = builtins.stringFn };
    try setNative(a, root_shape, string_ns, "fromCharCode", builtins.stringFromCharCode);
    try env.put("String", .{ .object = string_ns });

    // Number — callable, with statics and constants.
    const number_ns = try a.create(value.Object);
    number_ns.* = .{ .native = builtins.numberFn };
    try setNative(a, root_shape, number_ns, "isInteger", builtins.numberIsInteger);
    try setNative(a, root_shape, number_ns, "isSafeInteger", builtins.numberIsSafeInteger);
    try setNative(a, root_shape, number_ns, "isNaN", builtins.numberIsNaN);
    try setNative(a, root_shape, number_ns, "isFinite", builtins.numberIsFinite);
    try setNative(a, root_shape, number_ns, "parseFloat", builtins.parseFloatFn);
    try setNative(a, root_shape, number_ns, "parseInt", builtins.parseIntFn);
    try number_ns.setOwn(a, root_shape, "MAX_SAFE_INTEGER", .{ .number = 9007199254740991 });
    try number_ns.setOwn(a, root_shape, "MIN_SAFE_INTEGER", .{ .number = -9007199254740991 });
    try number_ns.setOwn(a, root_shape, "MAX_VALUE", .{ .number = std.math.floatMax(f64) });
    try number_ns.setOwn(a, root_shape, "MIN_VALUE", .{ .number = std.math.floatMin(f64) });
    try number_ns.setOwn(a, root_shape, "EPSILON", .{ .number = std.math.floatEps(f64) });
    try number_ns.setOwn(a, root_shape, "POSITIVE_INFINITY", .{ .number = std.math.inf(f64) });
    try number_ns.setOwn(a, root_shape, "NEGATIVE_INFINITY", .{ .number = -std.math.inf(f64) });
    try number_ns.setOwn(a, root_shape, "NaN", .{ .number = std.math.nan(f64) });
    try env.put("Number", .{ .object = number_ns });

    // JSON namespace.
    const json_ns = try a.create(value.Object);
    json_ns.* = .{};
    try setNative(a, root_shape, json_ns, "stringify", builtins.jsonStringify);
    try setNative(a, root_shape, json_ns, "parse", builtins.jsonParse);
    try env.put("JSON", .{ .object = json_ns });

    // Math namespace.
    const math_obj = try a.create(value.Object);
    math_obj.* = .{};
    try setNative(a, root_shape, math_obj, "floor", builtins.mathFloor);
    try setNative(a, root_shape, math_obj, "ceil", builtins.mathCeil);
    try setNative(a, root_shape, math_obj, "round", builtins.mathRound);
    try setNative(a, root_shape, math_obj, "trunc", builtins.mathTrunc);
    try setNative(a, root_shape, math_obj, "abs", builtins.mathAbs);
    try setNative(a, root_shape, math_obj, "sqrt", builtins.mathSqrt);
    try setNative(a, root_shape, math_obj, "sign", builtins.mathSign);
    try setNative(a, root_shape, math_obj, "pow", builtins.mathPow);
    try setNative(a, root_shape, math_obj, "max", builtins.mathMax);
    try setNative(a, root_shape, math_obj, "min", builtins.mathMin);
    try math_obj.setOwn(a, root_shape, "PI", .{ .number = std.math.pi });
    try env.put("Math", .{ .object = math_obj });

    // Object namespace.
    const object_ns = try a.create(value.Object);
    object_ns.* = .{};
    try setNative(a, root_shape, object_ns, "keys", builtins.objectKeys);
    try setNative(a, root_shape, object_ns, "values", builtins.objectValues);
    try setNative(a, root_shape, object_ns, "assign", builtins.objectAssign);
    try setNative(a, root_shape, object_ns, "freeze", builtins.identity1);
    try setNative(a, root_shape, object_ns, "create", builtins.objectCreate);
    try setNative(a, root_shape, object_ns, "getPrototypeOf", builtins.objectGetPrototypeOf);
    try setNative(a, root_shape, object_ns, "defineProperty", builtins.objectDefineProperty);
    try setNative(a, root_shape, object_ns, "getOwnPropertyNames", builtins.objectGetOwnPropertyNames);
    try setNative(a, root_shape, object_ns, "entries", builtins.objectEntries);
    try setNative(a, root_shape, object_ns, "fromEntries", builtins.objectFromEntries);
    try env.put("Object", .{ .object = object_ns });

    // Array namespace (isArray/of/from; prototype methods stay on arrays).
    const array_ns = try a.create(value.Object);
    array_ns.* = .{};
    try setNative(a, root_shape, array_ns, "isArray", builtins.arrayIsArray);
    try setNative(a, root_shape, array_ns, "of", builtins.arrayOf);
    try setNative(a, root_shape, array_ns, "from", builtins.arrayFrom);
    try env.put("Array", .{ .object = array_ns });
}

/// `next()` for a `makeCursorIterator` object: yields successive elements of the
/// captured array/string, then `{ done: true }`.
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
        .object => |so| if (so.is_array and i < so.elements.items.len) {
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

fn defineGlobalFn(env: *Environment, name: []const u8, f: value.NativeFn) EvalError!void {
    const o = try env.arena.create(value.Object);
    o.* = .{ .native = f };
    try env.put(name, .{ .object = o });
}

fn setNative(a: std.mem.Allocator, root_shape: *Shape, obj: *value.Object, name: []const u8, f: value.NativeFn) EvalError!void {
    const m = try a.create(value.Object);
    m.* = .{ .native = f };
    try obj.setOwn(a, root_shape, name, .{ .object = m });
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
fn hasProperty(o: *value.Object, name: []const u8) bool {
    var cur: ?*value.Object = o;
    while (cur) |c| {
        if (c.getOwn(name) != null or c.getAccessor(name) != null) return true;
        cur = c.proto;
    }
    return false;
}

fn arg0(args: []const Value) Value {
    return if (args.len > 0) args[0] else .undefined;
}

/// Integer `n` formatted in `radix` (2–36), e.g. `(255).toString(16)` → "ff".
fn intToRadix(arena: std.mem.Allocator, n: f64, radix: usize) ![]const u8 {
    if (n == 0) return "0";
    const digits = "0123456789abcdefghijklmnopqrstuvwxyz";
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    const neg = n < 0;
    const an = @abs(n);
    var v: u64 = if (an > 18446744073709551615.0) std.math.maxInt(u64) else @intFromFloat(an);
    while (v > 0) {
        try buf.append(arena, digits[@intCast(v % radix)]);
        v /= radix;
    }
    if (neg) try buf.append(arena, '-');
    std.mem.reverse(u8, buf.items);
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
