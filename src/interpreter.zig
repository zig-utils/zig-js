const std = @import("std");
const ast = @import("ast.zig");
const value = @import("value.zig");

const Node = ast.Node;
const Value = value.Value;

pub const EvalError = error{ OutOfMemory, ReferenceError, TypeError, NotImplemented };

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

/// Non-local control flow the tree-walker propagates up the statement list.
const Signal = enum { none, ret };

/// Tree-walking evaluator. Evaluating a program/block returns the completion
/// value of the last statement, which is what `JSEvaluateScript` hands back.
pub const Interpreter = struct {
    arena: std.mem.Allocator,
    env: *Environment,
    signal: Signal = .none,
    ret_value: Value = .undefined,

    pub fn eval(self: *Interpreter, node: *const Node) EvalError!Value {
        return switch (node.*) {
            .number => |n| .{ .number = n },
            .string => |s| .{ .string = s },
            .boolean => |b| .{ .boolean = b },
            .null_lit => .null,
            .undefined_lit => .undefined,
            .identifier => |name| self.env.get(name) orelse EvalError.ReferenceError,

            .unary => |u| try self.evalUnary(u.op, u.operand),
            .binary => |b| try self.evalBinary(b.op, b.left, b.right),
            .logical => |l| try self.evalLogical(l.op, l.left, l.right),

            .assign => |a| blk: {
                const v = try self.eval(a.value);
                try self.env.assign(a.name, v);
                break :blk v;
            },

            .function => |fnode| try self.makeFunction(fnode, self.env),

            .call => |c| try self.evalCall(c.callee, c.args),

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

            .expr_stmt => |e| try self.eval(e),

            .block => |stmts| try self.evalStatements(stmts),
            .program => |stmts| try self.evalStatements(stmts),

            .if_stmt => |s| if ((try self.eval(s.cond)).toBoolean())
                try self.eval(s.consequent)
            else if (s.alternate) |alt|
                try self.eval(alt)
            else
                .undefined,

            .while_stmt => |s| blk: {
                var last: Value = .undefined;
                while ((try self.eval(s.cond)).toBoolean()) {
                    last = try self.eval(s.body);
                    if (self.signal != .none) break;
                }
                break :blk last;
            },
        };
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

    fn evalCall(self: *Interpreter, callee_node: *Node, arg_nodes: []*Node) EvalError!Value {
        const callee = try self.eval(callee_node);
        const args = try self.arena.alloc(Value, arg_nodes.len);
        for (arg_nodes, 0..) |an, i| args[i] = try self.eval(an);
        return self.callValue(callee, args);
    }

    /// Invoke a callable value with already-evaluated arguments. Native builtins
    /// run directly; JS functions push a call scope over their closure.
    pub fn callValue(self: *Interpreter, callee: Value, args: []const Value) EvalError!Value {
        if (callee != .object) return EvalError.TypeError;
        const obj = callee.object;
        if (obj.native) |nf| return nf(args);
        if (obj.js_func) |erased| {
            const func: *Function = @ptrCast(@alignCast(erased));
            return self.callFunction(func, args);
        }
        // C-ABI host callbacks need value boxing (a C-API concern), not callable here.
        return EvalError.TypeError;
    }

    fn callFunction(self: *Interpreter, func: *Function, args: []const Value) EvalError!Value {
        const call_env = try self.arena.create(Environment);
        call_env.* = .{ .arena = self.arena, .parent = func.closure };
        for (func.params, 0..) |p, i| {
            try call_env.put(p, if (i < args.len) args[i] else .undefined);
        }

        const saved_env = self.env;
        const saved_signal = self.signal;
        const saved_ret = self.ret_value;
        self.env = call_env;
        self.signal = .none;
        defer {
            self.env = saved_env;
            self.signal = saved_signal;
            self.ret_value = saved_ret;
        }

        if (func.is_expr_body) return self.eval(func.body);
        _ = try self.eval(func.body);
        return if (self.signal == .ret) self.ret_value else .undefined;
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
        };
    }
};

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
