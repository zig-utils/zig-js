//! AST → bytecode compiler for the tier-1 VM.
//!
//! Lowers the subset of the AST the VM executes directly. Anything outside that
//! subset (`throw`/`try`, computed method calls, member `++`/`--`) returns
//! `error.Unsupported`, which the Context treats as a signal to run the whole
//! program on the tree-walker instead. That keeps conformance flat while the
//! VM's coverage grows — the compiler is widened one node at a time, never the
//! semantics.
//!
//! Variable resolution happens here, at compile time: a function's parameters
//! and (function-scoped) declarations are assigned frame **slot** indices,
//! captured names become `(depth, slot)` **upvalues**, and anything not found in
//! an enclosing function is a **global** resolved by name against the
//! Environment. Top-level program variables are globals (they persist across
//! `evaluate` calls, like a real global object). This mirrors the tree-walker's
//! block-transparent scoping exactly.

const std = @import("std");
const ast = @import("ast.zig");
const bc = @import("bytecode.zig");

const Node = ast.Node;
const Chunk = bc.Chunk;

pub const CompileError = error{ Unsupported, OutOfMemory };

/// Whether the result of a top-level expression statement becomes the program's
/// completion value (`program`) or is discarded (`function`).
const Mode = enum { program, function };

const Loop = struct {
    breaks: std.ArrayListUnmanaged(usize) = .empty,
    continues: std.ArrayListUnmanaged(usize) = .empty,
};

/// A function's local namespace: name → frame slot. Built once, up front, from
/// the parameters and the function-scoped declarations (var/let/const/function),
/// matching the engine's block-transparent scoping.
const FnScope = struct {
    parent: ?*FnScope,
    names: std.StringHashMapUnmanaged(u32) = .{},
    count: u32 = 0,

    fn addLocal(self: *FnScope, arena: std.mem.Allocator, name: []const u8) CompileError!u32 {
        if (self.names.get(name)) |slot| return slot;
        const slot = self.count;
        try self.names.put(arena, name, slot);
        self.count += 1;
        return slot;
    }
};

/// Where a referenced name lives.
const Resolved = union(enum) {
    local: u32, // slot in the current frame
    upval: struct { depth: u32, slot: u32 }, // an enclosing function's frame
    global, // by name, against the Environment
};

pub const Compiler = struct {
    arena: std.mem.Allocator,
    chunk: *Chunk,
    mode: Mode,
    scope: ?*FnScope = null,
    loops: std.ArrayListUnmanaged(*Loop) = .empty,

    /// Compile a whole program into a fresh chunk. The chunk ends with `halt`;
    /// the VM returns its completion accumulator. Program scope is null, so all
    /// top-level bindings are globals.
    pub fn compileProgram(arena: std.mem.Allocator, program: *Node) CompileError!*Chunk {
        const chunk = try arena.create(Chunk);
        chunk.* = Chunk.init(arena);
        var c = Compiler{ .arena = arena, .chunk = chunk, .mode = .program };
        if (program.* != .program) return error.Unsupported;
        for (program.program) |stmt| try c.compileStmt(stmt);
        _ = try chunk.emit(.halt, 0);
        return chunk;
    }

    // ---- name resolution --------------------------------------------------

    fn resolve(self: *Compiler, name: []const u8) Resolved {
        var depth: u32 = 0;
        var scope = self.scope;
        while (scope) |sc| {
            if (sc.names.get(name)) |slot| {
                return if (depth == 0) .{ .local = slot } else .{ .upval = .{ .depth = depth, .slot = slot } };
            }
            depth += 1;
            scope = sc.parent;
        }
        return .global;
    }

    /// Emit a load of `name` to the appropriate location (local / upvalue / global).
    fn emitLoad(self: *Compiler, name: []const u8) CompileError!void {
        switch (self.resolve(name)) {
            .local => |slot| _ = try self.chunk.emit(.load_local, slot),
            .upval => |u| _ = try self.chunk.emitAB(.load_upval, u.depth, u.slot),
            .global => _ = try self.chunk.emit(.load_var, try self.chunk.addName(name)),
        }
    }

    /// Emit a store to `name` (assignment); leaves the value on the stack.
    fn emitStore(self: *Compiler, name: []const u8) CompileError!void {
        switch (self.resolve(name)) {
            .local => |slot| _ = try self.chunk.emit(.store_local, slot),
            .upval => |u| _ = try self.chunk.emitAB(.store_upval, u.depth, u.slot),
            .global => _ = try self.chunk.emit(.store_var, try self.chunk.addName(name)),
        }
    }

    /// Emit a definition of `name` (var/let/const/function decl) with its value
    /// already on the stack; consumes the value.
    fn emitDefine(self: *Compiler, name: []const u8) CompileError!void {
        switch (self.resolve(name)) {
            .local => |slot| {
                _ = try self.chunk.emit(.store_local, slot);
                _ = try self.chunk.emit(.pop, 0);
            },
            .upval => |u| {
                _ = try self.chunk.emitAB(.store_upval, u.depth, u.slot);
                _ = try self.chunk.emit(.pop, 0);
            },
            .global => _ = try self.chunk.emit(.def_var, try self.chunk.addName(name)),
        }
    }

    // ---- statements -------------------------------------------------------

    fn compileStmt(self: *Compiler, node: *Node) CompileError!void {
        switch (node.*) {
            .var_decl => |d| {
                if (d.init) |init_node| {
                    try self.compileExpr(init_node);
                } else {
                    _ = try self.chunk.emit(.load_undefined, 0);
                }
                try self.emitDefine(d.name);
            },
            .func_decl => |fnode| {
                const fi = try self.compileFunction(fnode);
                _ = try self.chunk.emit(.make_closure, fi);
                try self.emitDefine(fnode.name);
            },
            .return_stmt => |maybe| {
                if (maybe) |e| {
                    try self.compileExpr(e);
                    _ = try self.chunk.emit(.ret, 0);
                } else {
                    _ = try self.chunk.emit(.ret_undef, 0);
                }
            },
            .expr_stmt => |e| {
                try self.compileExpr(e);
                _ = try self.chunk.emit(if (self.mode == .program) .set_acc else .pop, 0);
            },
            .block => |stmts| {
                for (stmts) |s| try self.compileStmt(s);
            },
            .if_stmt => |s| try self.compileIf(s.cond, s.consequent, s.alternate),
            .while_stmt => |s| try self.compileWhile(s.cond, s.body),
            .for_stmt => |f| try self.compileFor(f.init, f.cond, f.update, f.body),
            .break_stmt => {
                const loop = self.currentLoop() orelse return error.Unsupported;
                const j = try self.chunk.emit(.jump, 0);
                try loop.breaks.append(self.arena, j);
            },
            .continue_stmt => {
                const loop = self.currentLoop() orelse return error.Unsupported;
                const j = try self.chunk.emit(.jump, 0);
                try loop.continues.append(self.arena, j);
            },
            // throw / try are not lowered yet → whole-program fallback.
            else => return error.Unsupported,
        }
    }

    fn compileIf(self: *Compiler, cond: *Node, consequent: *Node, alternate: ?*Node) CompileError!void {
        try self.compileExpr(cond);
        const to_else = try self.chunk.emit(.jump_if_false, 0);
        try self.compileStmt(consequent);
        if (alternate) |alt| {
            const to_end = try self.chunk.emit(.jump, 0);
            self.chunk.patchToHere(to_else);
            try self.compileStmt(alt);
            self.chunk.patchToHere(to_end);
        } else {
            self.chunk.patchToHere(to_else);
        }
    }

    fn compileWhile(self: *Compiler, cond: *Node, body: *Node) CompileError!void {
        const loop = try self.pushLoop();
        const cond_at = self.chunk.here();
        try self.compileExpr(cond);
        const to_end = try self.chunk.emit(.jump_if_false, 0);
        try self.compileStmt(body);
        _ = try self.chunk.emit(.jump, @intCast(cond_at));
        self.chunk.patchToHere(to_end);
        // `continue` re-tests the condition.
        for (loop.continues.items) |j| self.chunk.patchTo(j, cond_at);
        for (loop.breaks.items) |j| self.chunk.patchToHere(j);
        self.popLoop();
    }

    fn compileFor(self: *Compiler, init_node: ?*Node, cond: ?*Node, update: ?*Node, body: *Node) CompileError!void {
        if (init_node) |ini| {
            // The init clause is a var_decl statement or a bare expression.
            if (ini.* == .var_decl) {
                try self.compileStmt(ini);
            } else {
                try self.compileExpr(ini);
                _ = try self.chunk.emit(.pop, 0);
            }
        }
        const loop = try self.pushLoop();
        const cond_at = self.chunk.here();
        var to_end: ?usize = null;
        if (cond) |c| {
            try self.compileExpr(c);
            to_end = try self.chunk.emit(.jump_if_false, 0);
        }
        try self.compileStmt(body);
        const update_at = self.chunk.here();
        if (update) |u| {
            try self.compileExpr(u);
            _ = try self.chunk.emit(.pop, 0);
        }
        _ = try self.chunk.emit(.jump, @intCast(cond_at));
        if (to_end) |t| self.chunk.patchToHere(t);
        // `continue` runs the update clause, then re-tests.
        for (loop.continues.items) |j| self.chunk.patchTo(j, update_at);
        for (loop.breaks.items) |j| self.chunk.patchToHere(j);
        self.popLoop();
    }

    // ---- expressions ------------------------------------------------------

    fn compileExpr(self: *Compiler, node: *Node) CompileError!void {
        switch (node.*) {
            .number => |n| {
                const ci = try self.chunk.addConst(.{ .number = n });
                _ = try self.chunk.emit(.load_const, ci);
            },
            .string => |s| {
                const ci = try self.chunk.addConst(.{ .string = s });
                _ = try self.chunk.emit(.load_const, ci);
            },
            .boolean => |b| _ = try self.chunk.emit(if (b) .load_true else .load_false, 0),
            .null_lit => _ = try self.chunk.emit(.load_null, 0),
            .undefined_lit => _ = try self.chunk.emit(.load_undefined, 0),
            .identifier => |name| try self.emitLoad(name),
            .unary => |u| {
                try self.compileExpr(u.operand);
                _ = try self.chunk.emit(switch (u.op) {
                    .neg => .neg,
                    .pos => .pos,
                    .not => .not,
                    .typeof => .typeof_op,
                }, 0);
            },
            .binary => |b| {
                const op: bc.Op = switch (b.op) {
                    .add => .add,
                    .sub => .sub,
                    .mul => .mul,
                    .div => .div,
                    .mod => .mod,
                    .pow => .pow,
                    .lt => .lt,
                    .le => .le,
                    .gt => .gt,
                    .ge => .ge,
                    .eq => .eq,
                    .neq => .neq,
                    .eq_strict => .eq_strict,
                    .neq_strict => .neq_strict,
                    .instanceof => .instance_of,
                };
                try self.compileExpr(b.left);
                try self.compileExpr(b.right);
                _ = try self.chunk.emit(op, 0);
            },
            .logical => |l| {
                try self.compileExpr(l.left);
                const peek: bc.Op = if (l.op == .@"and") .jump_if_false_peek else .jump_if_true_peek;
                const short = try self.chunk.emit(peek, 0);
                _ = try self.chunk.emit(.pop, 0);
                try self.compileExpr(l.right);
                self.chunk.patchToHere(short);
            },
            .assign => |a| switch (a.target.*) {
                .identifier => |name| {
                    try self.compileExpr(a.value);
                    try self.emitStore(name);
                },
                .member => |m| {
                    try self.compileExpr(m.object);
                    if (m.computed) |ce| {
                        try self.compileExpr(ce);
                        try self.compileExpr(a.value);
                        _ = try self.chunk.emit(.set_index, 0);
                    } else {
                        try self.compileExpr(a.value);
                        const ni = try self.chunk.addName(m.property);
                        _ = try self.chunk.emit(.set_prop, ni);
                    }
                },
                else => return error.Unsupported,
            },
            .conditional => |c| {
                try self.compileExpr(c.cond);
                const to_else = try self.chunk.emit(.jump_if_false, 0);
                try self.compileExpr(c.consequent);
                const to_end = try self.chunk.emit(.jump, 0);
                self.chunk.patchToHere(to_else);
                try self.compileExpr(c.alternate);
                self.chunk.patchToHere(to_end);
            },
            .function => |fnode| {
                const fi = try self.compileFunction(fnode);
                _ = try self.chunk.emit(.make_closure, fi);
            },
            .call => |c| {
                if (c.callee.* == .member and c.callee.member.computed == null) {
                    // `recv.name(args)`: bind `this = recv` at the call_method site.
                    const m = c.callee.member;
                    try self.compileExpr(m.object);
                    for (c.args) |arg| try self.compileExpr(arg);
                    const ni = try self.chunk.addName(m.property);
                    _ = try self.chunk.emitAB(.call_method, ni, @intCast(c.args.len));
                } else if (c.callee.* == .member) {
                    return error.Unsupported; // computed method call → fallback
                } else {
                    try self.compileExpr(c.callee);
                    for (c.args) |arg| try self.compileExpr(arg);
                    _ = try self.chunk.emit(.call, @intCast(c.args.len));
                }
            },
            .this_expr => _ = try self.chunk.emit(.load_this, 0),
            .member => |m| {
                try self.compileExpr(m.object);
                if (m.computed) |ce| {
                    try self.compileExpr(ce);
                    _ = try self.chunk.emit(.get_index, 0);
                } else {
                    const ni = try self.chunk.addName(m.property);
                    _ = try self.chunk.emit(.get_prop, ni);
                }
            },
            .new_expr => |n| {
                try self.compileExpr(n.callee);
                for (n.args) |arg| try self.compileExpr(arg);
                _ = try self.chunk.emit(.new_call, @intCast(n.args.len));
            },
            .object_lit => |props| {
                _ = try self.chunk.emit(.new_object, 0);
                for (props) |p| {
                    try self.compileExpr(p.value);
                    const ni = try self.chunk.addName(p.key);
                    _ = try self.chunk.emit(.init_prop, ni);
                }
            },
            .array_lit => |elems| {
                _ = try self.chunk.emit(.new_array, 0);
                for (elems) |e| {
                    try self.compileExpr(e);
                    _ = try self.chunk.emit(.array_append, 0);
                }
            },
            .update => |u| try self.compileUpdate(u.inc, u.prefix, u.target),
            // Statement-only nodes never appear in expression position.
            else => return error.Unsupported,
        }
    }

    /// `++x` / `x++` on an identifier (member targets fall back). Prefix yields
    /// the new value, postfix the old.
    fn compileUpdate(self: *Compiler, inc: bool, prefix: bool, target: *Node) CompileError!void {
        if (target.* != .identifier) return error.Unsupported;
        const name = target.identifier;
        const one = try self.chunk.addConst(.{ .number = 1 });
        const delta: bc.Op = if (inc) .add else .sub;
        if (prefix) {
            try self.emitLoad(name);
            _ = try self.chunk.emit(.load_const, one);
            _ = try self.chunk.emit(delta, 0);
            try self.emitStore(name); // leaves the new value
        } else {
            try self.emitLoad(name);
            _ = try self.chunk.emit(.dup, 0); // keep the old value
            _ = try self.chunk.emit(.load_const, one);
            _ = try self.chunk.emit(delta, 0);
            try self.emitStore(name);
            _ = try self.chunk.emit(.pop, 0); // discard the new value, leave the old
        }
    }

    fn compileFunction(self: *Compiler, fnode: *const ast.FunctionNode) CompileError!u32 {
        const sub = try self.arena.create(Chunk);
        sub.* = Chunk.init(self.arena);

        // Build this function's slot namespace: parameters first, then every
        // function-scoped declaration in the body (not descending into nested
        // functions). The scope chains to the enclosing function for upvalues.
        const scope = try self.arena.create(FnScope);
        scope.* = .{ .parent = self.scope };
        for (fnode.params) |p| _ = try scope.addLocal(self.arena, p);
        if (!fnode.is_expr_body) try collectLocals(self.arena, scope, fnode.body);

        var sub_c = Compiler{ .arena = self.arena, .chunk = sub, .mode = .function, .scope = scope };
        if (fnode.is_expr_body) {
            try sub_c.compileExpr(fnode.body);
            _ = try sub.emit(.ret, 0);
        } else {
            try sub_c.compileStmt(fnode.body); // body is a block
            _ = try sub.emit(.ret_undef, 0);
        }
        const tmpl = try self.arena.create(bc.FnTemplate);
        tmpl.* = .{
            .name = fnode.name,
            .params = fnode.params,
            .is_expr_body = fnode.is_expr_body,
            .body = fnode.body,
            .chunk = sub,
            .local_count = scope.count,
        };
        return self.chunk.addFn(tmpl);
    }

    // ---- loop bookkeeping -------------------------------------------------

    fn pushLoop(self: *Compiler) CompileError!*Loop {
        const loop = try self.arena.create(Loop);
        loop.* = .{};
        try self.loops.append(self.arena, loop);
        return loop;
    }

    fn popLoop(self: *Compiler) void {
        _ = self.loops.pop();
    }

    fn currentLoop(self: *Compiler) ?*Loop {
        if (self.loops.items.len == 0) return null;
        return self.loops.items[self.loops.items.len - 1];
    }
};

/// Collect a function's slot-allocated declarations: every `var`/`let`/`const`
/// and nested `function` name reachable in the body, *without* descending into
/// nested function/arrow bodies (those names belong to those functions). Blocks
/// are transparent — matching the engine's function-level scoping — so a name
/// gets one slot regardless of how deeply it's nested in `if`/`for`/`while`.
fn collectLocals(arena: std.mem.Allocator, scope: *FnScope, node: *Node) CompileError!void {
    switch (node.*) {
        .var_decl => |d| _ = try scope.addLocal(arena, d.name),
        .func_decl => |f| _ = try scope.addLocal(arena, f.name),
        .block => |stmts| for (stmts) |s| try collectLocals(arena, scope, s),
        .if_stmt => |s| {
            try collectLocals(arena, scope, s.consequent);
            if (s.alternate) |alt| try collectLocals(arena, scope, alt);
        },
        .while_stmt => |s| try collectLocals(arena, scope, s.body),
        .for_stmt => |f| {
            if (f.init) |ini| try collectLocals(arena, scope, ini);
            try collectLocals(arena, scope, f.body);
        },
        // Expressions (incl. nested function/arrow literals) declare no names in
        // this function's scope.
        else => {},
    }
}
