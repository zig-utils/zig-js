//! AST → bytecode compiler for the tier-1 VM.
//!
//! Lowers the subset of the AST the VM executes directly. Anything outside that
//! subset (objects, member access, `new`, `throw`/`try`, `++`/`--`, member
//! assignment, `instanceof`, `this`) returns `error.Unsupported`, which the
//! Context treats as a signal to run the whole program on the tree-walker
//! instead. That keeps conformance flat while the VM's coverage grows — the
//! compiler is widened one node at a time, never the semantics.

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

pub const Compiler = struct {
    arena: std.mem.Allocator,
    chunk: *Chunk,
    mode: Mode,
    loops: std.ArrayListUnmanaged(*Loop) = .empty,

    /// Compile a whole program into a fresh chunk. The chunk ends with `halt`;
    /// the VM returns its completion accumulator.
    pub fn compileProgram(arena: std.mem.Allocator, program: *Node) CompileError!*Chunk {
        const chunk = try arena.create(Chunk);
        chunk.* = Chunk.init(arena);
        var c = Compiler{ .arena = arena, .chunk = chunk, .mode = .program };
        if (program.* != .program) return error.Unsupported;
        for (program.program) |stmt| try c.compileStmt(stmt);
        _ = try chunk.emit(.halt, 0);
        return chunk;
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
                const ni = try self.chunk.addName(d.name);
                _ = try self.chunk.emit(.def_var, ni);
            },
            .func_decl => |fnode| {
                const fi = try self.compileFunction(fnode);
                _ = try self.chunk.emit(.make_closure, fi);
                const ni = try self.chunk.addName(fnode.name);
                _ = try self.chunk.emit(.def_var, ni);
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
            .identifier => |name| {
                const ni = try self.chunk.addName(name);
                _ = try self.chunk.emit(.load_var, ni);
            },
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
                    .instanceof => return error.Unsupported,
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
            .assign => |a| {
                if (a.target.* != .identifier) return error.Unsupported; // member assign → fallback
                try self.compileExpr(a.value);
                const ni = try self.chunk.addName(a.target.identifier);
                _ = try self.chunk.emit(.store_var, ni);
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
                // Method calls (callee is a member) need `this` binding → fallback.
                if (c.callee.* == .member) return error.Unsupported;
                try self.compileExpr(c.callee);
                for (c.args) |arg| try self.compileExpr(arg);
                _ = try self.chunk.emit(.call, @intCast(c.args.len));
            },
            // this / update / member / new / object & array literals → fallback.
            else => return error.Unsupported,
        }
    }

    fn compileFunction(self: *Compiler, fnode: *const ast.FunctionNode) CompileError!u32 {
        const sub = try self.arena.create(Chunk);
        sub.* = Chunk.init(self.arena);
        var sub_c = Compiler{ .arena = self.arena, .chunk = sub, .mode = .function };
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
