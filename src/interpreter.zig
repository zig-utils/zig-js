const std = @import("std");
const ast = @import("ast.zig");
const value = @import("value.zig");

const Node = ast.Node;
const Value = value.Value;

/// `error.Throw` is the carrier for *any* JS exception: the thrown value lives
/// in `Interpreter.exception`. `error.OutOfMemory` is the only genuine host
/// failure. (ReferenceError/TypeError are no longer Zig errors — they are real,
/// catchable JS `Error` objects raised via `error.Throw`.)
pub const EvalError = error{ OutOfMemory, Throw };

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
    params: []const []const u8,
    body: *ast.Node,
    is_expr_body: bool,
    closure: *Environment,
    name: []const u8 = "",
};

/// Non-local control flow the tree-walker propagates up the statement list:
/// `ret` unwinds to the enclosing function, `brk`/`cont` to the enclosing loop.
const Signal = enum { none, ret, brk, cont };

/// Tree-walking evaluator. Evaluating a program/block returns the completion
/// value of the last statement, which is what `JSEvaluateScript` hands back.
pub const Interpreter = struct {
    arena: std.mem.Allocator,
    env: *Environment,
    signal: Signal = .none,
    ret_value: Value = .undefined,
    /// The `this` binding for the currently-executing function (undefined at
    /// top level / in plain calls; the receiver in method calls; the new object
    /// in constructor calls).
    this_value: Value = .undefined,
    /// The in-flight thrown value while `error.Throw` propagates. Read by
    /// `catch` and by the Context/C-API boundary.
    exception: Value = .undefined,

    // ---- exception helpers ------------------------------------------------

    /// Set a string property on an object, duplicating the key into the arena.
    fn setProp(self: *Interpreter, obj: *value.Object, key: []const u8, v: Value) EvalError!void {
        const gop = try obj.properties.getOrPut(self.arena, key);
        if (!gop.found_existing) gop.key_ptr.* = try self.arena.dupe(u8, key);
        gop.value_ptr.* = v;
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
    fn throwError(self: *Interpreter, name: []const u8, message: []const u8) EvalError {
        self.exception = try self.makeError(name, message);
        return error.Throw;
    }

    pub fn eval(self: *Interpreter, node: *const Node) EvalError!Value {
        return switch (node.*) {
            .number => |n| .{ .number = n },
            .string => |s| .{ .string = s },
            .boolean => |b| .{ .boolean = b },
            .null_lit => .null,
            .undefined_lit => .undefined,
            .this_expr => self.this_value,
            .identifier => |name| self.env.get(name) orelse return self.throwError("ReferenceError", name),

            .unary => |u| try self.evalUnary(u.op, u.operand),
            .update => |u| try self.evalUpdate(u.inc, u.prefix, u.target),
            .binary => |b| try self.evalBinary(b.op, b.left, b.right),
            .logical => |l| try self.evalLogical(l.op, l.left, l.right),

            .assign => |a| blk: {
                const v = try self.eval(a.value);
                try self.assignTo(a.target, v);
                break :blk v;
            },

            .function => |fnode| try self.makeFunction(fnode, self.env),

            .call => |c| try self.evalCall(c.callee, c.args),
            .new_expr => |n| try self.evalNew(n.callee, n.args),
            .member => |m| try self.getProperty(try self.eval(m.object), try self.memberKey(m.property, m.computed)),
            .object_lit => |props| try self.evalObjectLit(props),
            .array_lit => |elems| try self.evalArrayLit(elems),

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

            .break_stmt => blk: {
                self.signal = .brk;
                break :blk .undefined;
            },
            .continue_stmt => blk: {
                self.signal = .cont;
                break :blk .undefined;
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

            .while_stmt => |s| try self.evalWhile(s.cond, s.body),
            .for_stmt => |f| try self.evalFor(f.init, f.cond, f.update, f.body),
        };
    }

    fn evalWhile(self: *Interpreter, cond: *Node, body: *Node) EvalError!Value {
        var last: Value = .undefined;
        while ((try self.eval(cond)).toBoolean()) {
            last = try self.eval(body);
            if (self.loopSignal()) |stop| if (stop) break;
        }
        return last;
    }

    fn evalFor(self: *Interpreter, init_node: ?*Node, cond: ?*Node, update: ?*Node, body: *Node) EvalError!Value {
        if (init_node) |ini| _ = try self.eval(ini);
        var last: Value = .undefined;
        while (true) {
            if (cond) |c| {
                if (!(try self.eval(c)).toBoolean()) break;
            }
            last = try self.eval(body);
            if (self.loopSignal()) |stop| if (stop) break;
            if (update) |u| _ = try self.eval(u);
        }
        return last;
    }

    /// Inspect the control-flow signal at a loop boundary. Returns null when
    /// there is nothing pending (`ret` is left set so it keeps unwinding);
    /// returns true to break the loop, false to continue iterating. Consumes
    /// `brk`/`cont`.
    fn loopSignal(self: *Interpreter) ?bool {
        switch (self.signal) {
            .none => return null,
            .ret => return true, // leave the signal set; the function unwinds
            .brk => {
                self.signal = .none;
                return true;
            },
            .cont => {
                self.signal = .none;
                return false;
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
            .closure = closure,
            .name = fnode.name,
        };
        const obj = try self.arena.create(value.Object);
        obj.* = .{ .js_func = @ptrCast(func) };
        return .{ .object = obj };
    }

    fn evalArgs(self: *Interpreter, arg_nodes: []*Node) EvalError![]Value {
        const args = try self.arena.alloc(Value, arg_nodes.len);
        for (arg_nodes, 0..) |an, i| args[i] = try self.eval(an);
        return args;
    }

    fn evalCall(self: *Interpreter, callee_node: *Node, arg_nodes: []*Node) EvalError!Value {
        // Method call `obj.m(...)`: evaluate the receiver once so it can both
        // resolve the method and bind `this`. Array/string builtins (push,
        // pop, ...) that aren't own properties are dispatched here too.
        if (callee_node.* == .member) {
            const m = callee_node.member;
            const recv = try self.eval(m.object);
            const key = try self.memberKey(m.property, m.computed);
            if (try self.builtinMethod(recv, key, arg_nodes)) |result| return result;
            const method = try self.getProperty(recv, key);
            const args = try self.evalArgs(arg_nodes);
            return self.callValueWithThis(method, args, recv);
        }
        const callee = try self.eval(callee_node);
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
        if (obj.native) |nf| return nf(args);
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
        const call_env = try self.arena.create(Environment);
        call_env.* = .{ .arena = self.arena, .parent = func.closure };
        for (func.params, 0..) |p, i| {
            try call_env.put(p, if (i < args.len) args[i] else .undefined);
        }

        const saved_env = self.env;
        const saved_signal = self.signal;
        const saved_ret = self.ret_value;
        const saved_this = self.this_value;
        self.env = call_env;
        self.signal = .none;
        self.this_value = this_val;
        defer {
            self.env = saved_env;
            self.signal = saved_signal;
            self.ret_value = saved_ret;
            self.this_value = saved_this;
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
        if (obj.js_func) |erased| {
            const func: *Function = @ptrCast(@alignCast(erased));
            const this_obj = try self.arena.create(value.Object);
            this_obj.* = .{ .ctor_ref = obj };
            const this_val: Value = .{ .object = this_obj };
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

    fn evalObjectLit(self: *Interpreter, props: []ast.Property) EvalError!Value {
        const obj = try self.arena.create(value.Object);
        obj.* = .{};
        for (props) |p| try self.setProp(obj, p.key, try self.eval(p.value));
        return .{ .object = obj };
    }

    fn evalArrayLit(self: *Interpreter, elems: []*Node) EvalError!Value {
        const obj = try self.arena.create(value.Object);
        obj.* = .{ .is_array = true };
        for (elems) |en| try obj.elements.append(self.arena, try self.eval(en));
        return .{ .object = obj };
    }

    /// `index`-as-string -> array element index, or null if not an integer.
    fn arrayIndex(key: []const u8) ?usize {
        if (key.len == 0) return null;
        for (key) |c| if (!std.ascii.isDigit(c)) return null;
        return std.fmt.parseInt(usize, key, 10) catch null;
    }

    fn getProperty(self: *Interpreter, recv: Value, key: []const u8) EvalError!Value {
        switch (recv) {
            .object => |o| {
                if (o.is_array) {
                    if (std.mem.eql(u8, key, "length"))
                        return .{ .number = @floatFromInt(o.elements.items.len) };
                    if (arrayIndex(key)) |i|
                        return if (i < o.elements.items.len) o.elements.items[i] else .undefined;
                }
                return o.properties.get(key) orelse .undefined;
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

    fn assignTo(self: *Interpreter, target: *Node, v: Value) EvalError!void {
        switch (target.*) {
            .identifier => |name| try self.env.assign(name, v),
            .member => |m| {
                const recv = try self.eval(m.object);
                const key = try self.memberKey(m.property, m.computed);
                if (recv != .object) return self.throwError("TypeError", "cannot set property of non-object");
                const o = recv.object;
                if (o.is_array) {
                    if (arrayIndex(key)) |i| {
                        while (o.elements.items.len <= i) try o.elements.append(self.arena, .undefined);
                        o.elements.items[i] = v;
                        return;
                    }
                }
                try self.setProp(o, key, v);
            },
            else => return self.throwError("ReferenceError", "invalid assignment target"),
        }
    }

    /// Dispatch the small set of builtin methods (`Array.prototype.push/pop`)
    /// that aren't stored as own properties. Returns null when `key` is not a
    /// recognized builtin for `recv`, so the caller falls back to a normal
    /// property lookup + call.
    fn builtinMethod(self: *Interpreter, recv: Value, key: []const u8, arg_nodes: []*Node) EvalError!?Value {
        if (recv != .object or !recv.object.is_array) return null;
        const o = recv.object;
        if (o.properties.get(key) != null) return null; // own property shadows builtin
        if (std.mem.eql(u8, key, "push")) {
            const args = try self.evalArgs(arg_nodes);
            for (args) |a| try o.elements.append(self.arena, a);
            return Value{ .number = @floatFromInt(o.elements.items.len) };
        }
        if (std.mem.eql(u8, key, "pop")) {
            if (o.elements.items.len == 0) return Value.undefined;
            return o.elements.pop() orelse Value.undefined;
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
        };
    }

    fn evalLogical(self: *Interpreter, op: ast.LogicalOp, left: *Node, right: *Node) EvalError!Value {
        const l = try self.eval(left);
        return switch (op) {
            .@"and" => if (l.toBoolean()) try self.eval(right) else l,
            .@"or" => if (l.toBoolean()) l else try self.eval(right),
        };
    }

    fn evalBinary(self: *Interpreter, op: ast.BinaryOp, left_node: *Node, right_node: *Node) EvalError!Value {
        const l = try self.eval(left_node);
        const r = try self.eval(right_node);
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
        };
    }

    /// `x instanceof C`. v1 has a flat construction model: objects created by
    /// `new F()` carry `ctor_ref` pointing at F's object, and builtin error
    /// constructors carry `error_ctor`; this checks those links rather than a
    /// full prototype chain.
    fn instanceOf(self: *Interpreter, l: Value, r: Value) EvalError!bool {
        if (r != .object or !r.object.isCallableObject())
            return self.throwError("TypeError", "Right-hand side of 'instanceof' is not callable");
        if (l != .object) return false;
        const lo = l.object;
        const rc = r.object;
        if (lo.ctor_ref) |cr| if (cr == rc) return true;
        if (rc.error_ctor) |name| {
            if (lo.is_error and (std.mem.eql(u8, lo.error_name, name) or std.mem.eql(u8, name, "Error")))
                return true;
        }
        return false;
    }
};

/// Install the engine's global bindings into `env`: the `Error`-family
/// constructors (as builtin `error_ctor` objects) plus `NaN`/`Infinity`. Called
/// once per Context at creation, before any user code runs.
pub fn installGlobals(env: *Environment) EvalError!void {
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
    try installGlobals(&env);
    var interp = Interpreter{ .arena = arena, .env = &env };
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
