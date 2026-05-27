const std = @import("std");
const ast = @import("ast.zig");
const value = @import("value.zig");
const bc = @import("bytecode.zig");
const Shape = @import("shape.zig").Shape;

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
    /// Compiled body for the bytecode VM. Set when the function was created by
    /// the VM (`make_closure`); null for tree-walk-created closures, which are
    /// invoked via `callFunction`.
    chunk: ?*bc.Chunk = null,
    /// VM closure capture: the defining function's frame (type-erased `*vm.Frame`),
    /// for resolving upvalues. Null at the top level. The slot count to allocate
    /// for this function's own frame.
    frame: ?*anyopaque = null,
    local_count: u32 = 0,
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
            .switch_stmt => |s| try self.evalSwitch(s.disc, s.cases),
            .for_in => |f| try self.evalForInOf(f.decl_kind, f.name, f.iterable, f.body, f.is_of),
        };
    }

    /// `for-of` (values of arrays/strings) and `for-in` (own keys of objects /
    /// indices of arrays). Each iteration binds the loop variable then runs the
    /// body, honoring break/continue/return.
    fn evalForInOf(self: *Interpreter, decl_kind: ?ast.DeclKind, name: []const u8, iterable: *Node, body: *Node, is_of: bool) EvalError!Value {
        const iter = try self.eval(iterable);
        var last: Value = .undefined;
        if (is_of) {
            switch (iter) {
                .object => |o| {
                    if (!o.is_array) return self.throwError("TypeError", "value is not iterable");
                    var i: usize = 0;
                    while (i < o.elements.items.len) : (i += 1) {
                        try self.bindLoopVar(decl_kind, name, o.elements.items[i]);
                        last = try self.eval(body);
                        if (self.loopSignal()) |stop| if (stop) break;
                    }
                },
                .string => |s| {
                    for (s) |ch| {
                        const one = try self.arena.dupe(u8, &.{ch});
                        try self.bindLoopVar(decl_kind, name, .{ .string = one });
                        last = try self.eval(body);
                        if (self.loopSignal()) |stop| if (stop) break;
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
                            if (self.loopSignal()) |stop| if (stop) break;
                        }
                    } else {
                        const keys = try o.ownKeys(self.arena);
                        for (keys) |k| {
                            try self.bindLoopVar(decl_kind, name, .{ .string = k });
                            last = try self.eval(body);
                            if (self.loopSignal()) |stop| if (stop) break;
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
            if (self.signal == .brk) self.signal = .none; // `break` exits the switch
        }
        return last;
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
            const args = try self.evalArgs(arg_nodes);
            return self.callMethod(recv, key, args);
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

    /// Allocate a fresh plain object. The single creation point so later tiers
    /// (object shapes) have one seam to hook.
    pub fn newObject(self: *Interpreter) EvalError!Value {
        const obj = try self.arena.create(value.Object);
        obj.* = .{};
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
        for (props) |p| try self.setProp(v.object, p.key, try self.eval(p.value));
        return v;
    }

    fn evalArrayLit(self: *Interpreter, elems: []*Node) EvalError!Value {
        const v = try self.newArray();
        for (elems) |en| try v.object.elements.append(self.arena, try self.eval(en));
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
                    if (arrayIndex(key)) |i|
                        return if (i < o.elements.items.len) o.elements.items[i] else .undefined;
                }
                return o.getOwn(key) orelse .undefined;
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
                try self.setMember(recv, key, v);
            },
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
                while (o.elements.items.len <= i) try o.elements.append(self.arena, .undefined);
                o.elements.items[i] = v;
                return;
            }
        }
        try self.setProp(o, key, v);
    }

    /// Call `recv[name](args)` with `this = recv`. Dispatches the builtin
    /// methods that aren't stored as own properties first. Shared by the
    /// tree-walker's `evalCall` and the VM's `call_method`.
    pub fn callMethod(self: *Interpreter, recv: Value, name: []const u8, args: []const Value) EvalError!Value {
        if (try self.arrayBuiltin(recv, name, args)) |result| return result;
        const method = try self.getProperty(recv, name);
        return self.callValueWithThis(method, args, recv);
    }

    /// Dispatch the small set of builtin methods (`Array.prototype.push/pop`)
    /// that aren't stored as own properties. Returns null when `name` is not a
    /// recognized builtin for `recv`, so the caller falls back to a property
    /// lookup + call.
    pub fn arrayBuiltin(self: *Interpreter, recv: Value, name: []const u8, args: []const Value) EvalError!?Value {
        if (recv != .object or !recv.object.is_array) return null;
        const o = recv.object;
        if (o.getOwn(name) != null) return null; // own property shadows builtin
        if (std.mem.eql(u8, name, "push")) {
            for (args) |a| try o.elements.append(self.arena, a);
            return Value{ .number = @floatFromInt(o.elements.items.len) };
        }
        if (std.mem.eql(u8, name, "pop")) {
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
            .bit_not => .{ .number = @floatFromInt(~v.toInt32()) },
            .void_op => .undefined,
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
    pub fn instanceOf(self: *Interpreter, l: Value, r: Value) EvalError!bool {
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
    var interp = Interpreter{ .arena = arena, .env = &env, .root_shape = try Shape.createRoot(arena) };
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
