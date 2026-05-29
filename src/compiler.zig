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
    /// A `switch` is breakable but not continuable: `break` targets it, but
    /// `continue` skips past it to the nearest enclosing loop.
    is_switch: bool = false,
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
    /// True while lowering a generator body, so `yield` may emit `gen_yield`.
    in_generator: bool = false,
    /// True while lowering an async function body, so `await` may suspend (it
    /// reuses `gen_yield`; the async driver resumes it on promise settlement).
    in_async: bool = false,
    /// Counter for synthesized temp names (`yield*` iterator/result holders).
    tmp_counter: u32 = 0,
    /// >0 while compiling inside a `try` that has a `finally`. Abrupt control
    /// flow (return/break/continue) that would cross the finally isn't lowered
    /// yet, so it falls back rather than skipping the finally.
    finally_depth: u32 = 0,

    /// Compile a whole program into a fresh chunk. The chunk ends with `halt`;
    /// the VM returns its completion accumulator. Program scope is null, so all
    /// top-level bindings are globals.
    pub fn compileProgram(arena: std.mem.Allocator, program: *Node) CompileError!*Chunk {
        const chunk = try arena.create(Chunk);
        chunk.* = Chunk.init(arena);
        var c = Compiler{ .arena = arena, .chunk = chunk, .mode = .program };
        if (program.* != .program) return error.Unsupported;
        try c.compileStmtList(program.program);
        _ = try chunk.emit(.halt, 0);
        try chunk.finalize();
        return chunk;
    }

    /// Compile a `function*` body into its own chunk, run by the suspendable VM
    /// (`vm.genNext`). Unlike `compileFunction`, this uses **env-mode** (no frame
    /// scope): the body's parameters, locals, and free variables all resolve by
    /// name against the generator's `Environment`, bound at call time. That keeps
    /// a generator interoperable with the tree-walked code around it (shared
    /// environment) and lets `yield` suspend mid-expression by snapshotting the
    /// operand stack. Returns `error.Unsupported` for bodies (or parameter forms)
    /// outside the VM's lowered subset, so the generator is reported unsupported
    /// rather than run incorrectly.
    pub fn compileGenerator(arena: std.mem.Allocator, fnode: *const ast.FunctionNode) CompileError!*Chunk {
        // Parameters (including default/rest/destructuring) are bound at runtime
        // by `makeGenerator` into the generator's environment — env-mode name
        // resolution means the body's references resolve there — so the param
        // shape never blocks compilation; only the body must lower.
        if (fnode.is_expr_body) return error.Unsupported; // generators always have a block body
        const chunk = try arena.create(Chunk);
        chunk.* = Chunk.init(arena);
        var c = Compiler{ .arena = arena, .chunk = chunk, .mode = .function, .scope = null, .in_generator = true };
        try c.compileStmt(fnode.body); // body is a block
        _ = try chunk.emit(.ret_undef, 0);
        try chunk.finalize();
        return chunk;
    }

    /// Compile a plain `async function` body for the suspendable VM (env-mode,
    /// like a generator). `await` lowers to a suspend (`gen_yield`); the async
    /// driver promisifies the suspended value, resumes on settlement, and
    /// settles the function's result promise on completion.
    pub fn compileAsync(arena: std.mem.Allocator, fnode: *const ast.FunctionNode) CompileError!*Chunk {
        if (fnode.is_generator) return error.Unsupported; // async generators not lowered yet
        const chunk = try arena.create(Chunk);
        chunk.* = Chunk.init(arena);
        var c = Compiler{ .arena = arena, .chunk = chunk, .mode = .function, .scope = null, .in_async = true };
        if (fnode.is_expr_body) {
            try c.compileExpr(fnode.body);
            _ = try chunk.emit(.ret, 0);
        } else {
            try c.compileStmt(fnode.body);
            _ = try chunk.emit(.ret_undef, 0);
        }
        try chunk.finalize();
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
        // `arguments` inside a function is bound by the tree-walker only.
        if (self.scope != null and std.mem.eql(u8, name, "arguments")) return error.Unsupported;
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

    /// Compile a statement list with function-declaration hoisting: every
    /// `func_decl` is emitted (closure + define) first, so forward references
    /// like `bar(); function bar() {}` resolve, then the remaining statements
    /// run in order (func_decls skipped, so each binds exactly once).
    fn compileStmtList(self: *Compiler, stmts: []*Node) CompileError!void {
        for (stmts) |s| switch (s.*) {
            .func_decl => |fnode| {
                const fi = try self.compileFunction(fnode);
                _ = try self.chunk.emit(.make_closure, fi);
                try self.emitDefine(fnode.name);
            },
            else => {},
        };
        for (stmts) |s| {
            if (s.* == .func_decl) continue;
            try self.compileStmt(s);
        }
    }

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
                if (self.finally_depth > 0) return error.Unsupported; // return across finally → tree-walk
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
            .block => |stmts| try self.compileStmtList(stmts),
            .decl_group => |stmts| try self.compileStmtList(stmts),
            .if_stmt => |s| try self.compileIf(s.cond, s.consequent, s.alternate),
            .while_stmt => |s| try self.compileWhile(s.cond, s.body),
            .do_while_stmt => |s| try self.compileDoWhile(s.body, s.cond),
            .for_stmt => |f| try self.compileFor(f.init, f.cond, f.update, f.body),
            .break_stmt => |label| {
                if (label != null) return error.Unsupported; // labeled break → tree-walk
                if (self.finally_depth > 0) return error.Unsupported; // break across finally → tree-walk
                const loop = self.currentLoop() orelse return error.Unsupported;
                const j = try self.chunk.emit(.jump, 0);
                try loop.breaks.append(self.arena, j);
            },
            .continue_stmt => |label| {
                if (label != null) return error.Unsupported; // labeled continue → tree-walk
                if (self.finally_depth > 0) return error.Unsupported; // continue across finally → tree-walk
                const loop = self.currentContinueLoop() orelse return error.Unsupported;
                const j = try self.chunk.emit(.jump, 0);
                try loop.continues.append(self.arena, j);
            },
            .switch_stmt => |sw| try self.compileSwitch(sw.disc, sw.cases),
            .throw_stmt => |e| {
                try self.compileExpr(e);
                _ = try self.chunk.emit(.throw_op, 0);
            },
            .for_in => |f| {
                // for-of works everywhere it's lowered; for-in is lowered only in
                // generators (via `enum_keys`), else it falls back to the tree-walker.
                if (!f.is_of and !self.in_generator) return error.Unsupported;
                try self.compileForOf(f.decl_kind, f.target, f.iterable, f.body, !f.is_of);
            },
            .try_stmt => |t| try self.compileTry(t),
            else => return error.Unsupported,
        }
    }

    /// `try { B } [catch (e) { C }] [finally { F }]` for the generator VM. A
    /// handler records the catch and/or finally targets; the VM unwinds to it
    /// on a throw. Only an identifier/elided catch binding is lowered.
    fn compileTry(self: *Compiler, t: *const ast.TryNode) CompileError!void {
        if (!self.in_generator) return error.Unsupported;
        if (t.catch_param) |p| {
            if (p.* != .identifier) return error.Unsupported; // destructuring catch → unsupported
        }
        const none = std.math.maxInt(u32);

        if (t.finally_block == null) {
            // try/catch (no finally) — handler with a catch arm only.
            const catch_block = t.catch_block orelse return error.Unsupported;
            const ph = try self.chunk.emitAB(.push_handler, none, none);
            try self.compileStmt(t.block);
            _ = try self.chunk.emit(.pop_handler, 0);
            const skip = try self.chunk.emit(.jump, 0);
            self.chunk.code.items[ph].a = @intCast(self.chunk.here());
            if (t.catch_param) |p| try self.emitDefine(p.identifier) else _ = try self.chunk.emit(.pop, 0);
            try self.compileStmt(catch_block);
            self.chunk.patchToHere(skip);
            return;
        }

        // A finally is present. Abrupt control flow (return/break/continue) that
        // would cross the finally isn't lowered yet, so reject it inside.
        self.finally_depth += 1;
        defer self.finally_depth -= 1;

        const ph = try self.chunk.emitAB(.push_handler, none, none); // catch/finally patched below
        try self.compileStmt(t.block);
        _ = try self.chunk.emit(.pop_handler, 0);
        _ = try self.chunk.emit(.push_completion, 0); // normal completion of the try body
        const to_fin_normal = try self.chunk.emit(.jump, 0);

        var catch_start: ?usize = null;
        var ph2: ?usize = null;
        if (t.catch_block) |cb| {
            catch_start = self.chunk.here();
            // A throw inside the catch must still run the finally.
            ph2 = try self.chunk.emitAB(.push_handler, none, none);
            if (t.catch_param) |p| try self.emitDefine(p.identifier) else _ = try self.chunk.emit(.pop, 0);
            try self.compileStmt(cb);
            _ = try self.chunk.emit(.pop_handler, 0);
            _ = try self.chunk.emit(.push_completion, 0); // normal completion of the catch body
        }

        const fin = self.chunk.here();
        self.chunk.patchTo(to_fin_normal, fin);
        self.chunk.code.items[ph].a = if (catch_start) |cs| @intCast(cs) else none; // throw → catch, else finally
        self.chunk.code.items[ph].b = @intCast(fin);
        if (ph2) |p2| self.chunk.code.items[p2].b = @intCast(fin);
        try self.compileStmt(t.finally_block.?);
        _ = try self.chunk.emit(.end_finally, 0);
    }

    /// `switch (disc) { case t: ... default: ... }` — evaluate the discriminant
    /// once, then a chain of strict-equality tests jumping to each clause body
    /// (fall-through preserved). `break` exits via the switch's break list;
    /// `default` is taken only after every case test fails.
    fn compileSwitch(self: *Compiler, disc: *Node, cases: []const ast.SwitchCase) CompileError!void {
        if (!self.in_generator) return error.Unsupported; // non-generator switch keeps tree-walking
        try self.compileExpr(disc);
        const d = try self.freshTemp();
        try self.emitDefine(d); // d = the discriminant value

        const sw = try self.pushLoop();
        sw.is_switch = true;
        const body_jumps = try self.arena.alloc(usize, cases.len);
        const default_marker = std.math.maxInt(usize);
        for (cases, 0..) |c, i| {
            if (c.@"test") |t| {
                try self.emitLoad(d);
                try self.compileExpr(t);
                _ = try self.chunk.emit(.eq_strict, 0);
                _ = try self.chunk.emit(.not, 0); // jump_if_false jumps when equal
                body_jumps[i] = try self.chunk.emit(.jump_if_false, 0);
            } else {
                body_jumps[i] = default_marker; // the `default:` clause
            }
        }
        // No case matched: jump to the default clause (if any) or past the end.
        const to_default = try self.chunk.emit(.jump, 0);
        var default_target: ?usize = null;
        for (cases, 0..) |c, i| {
            if (body_jumps[i] == default_marker) {
                default_target = self.chunk.here();
            } else {
                self.chunk.patchToHere(body_jumps[i]);
            }
            try self.compileStmtList(c.body);
        }
        const end = self.chunk.here();
        self.chunk.patchTo(to_default, default_target orelse end);
        for (sw.breaks.items) |j| self.chunk.patchTo(j, end);
        self.popLoop();
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

    fn compileDoWhile(self: *Compiler, body: *Node, cond: *Node) CompileError!void {
        const loop = try self.pushLoop();
        const top = self.chunk.here();
        try self.compileStmt(body);
        const cont_at = self.chunk.here(); // `continue` re-tests the condition
        try self.compileExpr(cond);
        const to_end = try self.chunk.emit(.jump_if_false, 0);
        _ = try self.chunk.emit(.jump, @intCast(top));
        self.chunk.patchToHere(to_end);
        for (loop.continues.items) |j| self.chunk.patchTo(j, cont_at);
        for (loop.breaks.items) |j| self.chunk.patchToHere(j);
        self.popLoop();
    }

    fn compileFor(self: *Compiler, init_node: ?*Node, cond: ?*Node, update: ?*Node, body: *Node) CompileError!void {
        if (init_node) |ini| {
            // The init clause is a declaration statement (var_decl, or a group of
            // them for multiple declarators) or a bare expression.
            if (ini.* == .var_decl or ini.* == .block or ini.* == .decl_group) {
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

    /// `for (x of iterable) body` — drive the iterator protocol via `iter_of` +
    /// a `.next()` loop (mirroring `compileYieldStar`). Only a plain identifier
    /// target is lowered; destructuring targets and `for-in` fall back to the
    /// tree-walker. Works inside generators (where `for-of` is common).
    fn compileForOf(self: *Compiler, decl_kind: ?ast.DeclKind, target: *Node, iterable: *Node, body: *Node, keys_first: bool) CompileError!void {
        if (target.* != .identifier) return error.Unsupported; // patterns → tree-walk
        const var_name = target.identifier;
        const it_name = try self.freshTemp();
        const r_name = try self.freshTemp();

        try self.compileExpr(iterable);
        if (keys_first) _ = try self.chunk.emit(.enum_keys, 0); // for-in: iterate the key array
        _ = try self.chunk.emit(.iter_of, 0);
        try self.emitDefine(it_name);

        const loop = try self.pushLoop();
        const top = self.chunk.here();
        // r = it.next()
        try self.emitLoad(it_name);
        _ = try self.chunk.emitAB(.call_method, try self.chunk.addName("next"), 0);
        try self.emitDefine(r_name);
        // if (r.done) break  — `not` then jump_if_false exits exactly when done.
        try self.emitLoad(r_name);
        _ = try self.chunk.emit(.get_prop, try self.chunk.addName("done"));
        _ = try self.chunk.emit(.not, 0);
        const to_end = try self.chunk.emit(.jump_if_false, 0);
        // bind r.value to the loop variable
        try self.emitLoad(r_name);
        _ = try self.chunk.emit(.get_prop, try self.chunk.addName("value"));
        if (decl_kind != null) {
            try self.emitDefine(var_name);
        } else {
            try self.emitStore(var_name);
            _ = try self.chunk.emit(.pop, 0);
        }
        try self.compileStmt(body);
        _ = try self.chunk.emit(.jump, @intCast(top));
        self.chunk.patchToHere(to_end);
        // `continue` re-enters the loop at the top (next .next()).
        for (loop.continues.items) |j| self.chunk.patchTo(j, top);
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
                // `typeof <unresolved global>` must yield "undefined", not throw,
                // so a global-identifier operand loads non-throwingly.
                if (u.op == .typeof and u.operand.* == .identifier and
                    self.resolve(u.operand.identifier) == .global)
                {
                    _ = try self.chunk.emit(.load_var_or_undef, try self.chunk.addName(u.operand.identifier));
                    _ = try self.chunk.emit(.typeof_op, 0);
                    return;
                }
                try self.compileExpr(u.operand);
                _ = try self.chunk.emit(switch (u.op) {
                    .neg => .neg,
                    .pos => .pos,
                    .not => .not,
                    .typeof => .typeof_op,
                    .bit_not => .bit_not,
                    .void_op => .void_op,
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
                    .in_op => .in_op,
                    .bit_and => .bit_and,
                    .bit_or => .bit_or,
                    .bit_xor => .bit_xor,
                    .shl => .shl,
                    .shr => .shr,
                    .ushr => .ushr,
                };
                try self.compileExpr(b.left);
                try self.compileExpr(b.right);
                _ = try self.chunk.emit(op, 0);
            },
            .sequence => |s| {
                try self.compileExpr(s.first);
                _ = try self.chunk.emit(.pop, 0);
                try self.compileExpr(s.second);
            },
            .logical => |l| {
                if (l.op == .nullish) return error.Unsupported; // distinct short-circuit predicate → tree-walk
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
                const spread = hasSpread(c.args);
                if (spread and !self.in_generator) return error.Unsupported; // non-generator spread → tree-walk
                if (c.callee.* == .member and c.callee.member.computed == null) {
                    // `recv.name(args)`: bind `this = recv` at the call site.
                    const m = c.callee.member;
                    try self.compileExpr(m.object);
                    const ni = try self.chunk.addName(m.property);
                    if (spread) {
                        try self.compileArgsArray(c.args);
                        _ = try self.chunk.emit(.call_method_spread, ni);
                    } else {
                        for (c.args) |arg| try self.compileExpr(arg);
                        _ = try self.chunk.emitAB(.call_method, ni, @intCast(c.args.len));
                    }
                } else if (c.callee.* == .member) {
                    return error.Unsupported; // computed method call → fallback
                } else {
                    try self.compileExpr(c.callee);
                    if (spread) {
                        try self.compileArgsArray(c.args);
                        _ = try self.chunk.emit(.call_spread, 0);
                    } else {
                        for (c.args) |arg| try self.compileExpr(arg);
                        _ = try self.chunk.emit(.call, @intCast(c.args.len));
                    }
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
                if (hasSpread(n.args) and !self.in_generator) return error.Unsupported;
                try self.compileExpr(n.callee);
                if (hasSpread(n.args)) {
                    try self.compileArgsArray(n.args);
                    _ = try self.chunk.emit(.new_spread, 0);
                } else {
                    for (n.args) |arg| try self.compileExpr(arg);
                    _ = try self.chunk.emit(.new_call, @intCast(n.args.len));
                }
            },
            .object_lit => |props| {
                _ = try self.chunk.emit(.new_object, 0);
                for (props) |p| {
                    // Spread + accessor properties need the tree-walker.
                    if (p.is_spread or p.accessor != .none) return error.Unsupported;
                    try self.compileExpr(p.value);
                    if (p.key_expr) |ke| {
                        try self.compileExpr(ke);
                        _ = try self.chunk.emit(.init_prop_computed, 0);
                    } else {
                        _ = try self.chunk.emit(.init_prop, try self.chunk.addName(p.key));
                    }
                }
            },
            .array_lit => |elems| {
                _ = try self.chunk.emit(.new_array, 0);
                for (elems) |e| {
                    if (e.* == .elision) return error.Unsupported; // array holes → tree-walk
                    if (e.* == .spread) {
                        if (!self.in_generator) return error.Unsupported; // non-generator spread → tree-walk
                        try self.compileExpr(e.spread);
                        _ = try self.chunk.emit(.array_spread, 0);
                    } else {
                        try self.compileExpr(e);
                        _ = try self.chunk.emit(.array_append, 0);
                    }
                }
            },
            .update => |u| try self.compileUpdate(u.inc, u.prefix, u.target),
            .yield_expr => |y| {
                if (!self.in_generator) return error.Unsupported;
                if (y.delegate) {
                    try self.compileYieldStar(y.argument.?);
                } else {
                    if (y.argument) |arg| try self.compileExpr(arg) else _ = try self.chunk.emit(.load_undefined, 0);
                    _ = try self.chunk.emit(.gen_yield, 0);
                }
            },
            // `await e` suspends like a yield; the async driver promisifies the
            // value and resumes with the settled result (or injects a throw).
            .await_expr => |a| {
                if (!self.in_async) return error.Unsupported;
                try self.compileExpr(a.argument);
                _ = try self.chunk.emit(.gen_yield, 0);
            },
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

    /// `yield* X`: drive `X`'s iterator, yielding each value, then evaluate to
    /// the iterator's final value. Desugared to a bytecode loop over the
    /// iterator obtained via `iter_of` (the iterator protocol). The sent value
    /// is not forwarded into the inner iterator yet (a v1 simplification).
    fn compileYieldStar(self: *Compiler, arg: *Node) CompileError!void {
        const it_name = try self.freshTemp(); // the iterator
        const r_name = try self.freshTemp(); // the last `{value, done}` result

        try self.compileExpr(arg);
        _ = try self.chunk.emit(.iter_of, 0);
        try self.emitDefine(it_name);

        const top = self.chunk.here();
        // r = it.next()
        try self.emitLoad(it_name);
        _ = try self.chunk.emitAB(.call_method, try self.chunk.addName("next"), 0);
        try self.emitDefine(r_name);
        // if (r.done) break  — `not` then jump_if_false exits exactly when done.
        try self.emitLoad(r_name);
        _ = try self.chunk.emit(.get_prop, try self.chunk.addName("done"));
        _ = try self.chunk.emit(.not, 0);
        const to_end = try self.chunk.emit(.jump_if_false, 0);
        // yield r.value (discard the resume-sent value: not forwarded in v1)
        try self.emitLoad(r_name);
        _ = try self.chunk.emit(.get_prop, try self.chunk.addName("value"));
        _ = try self.chunk.emit(.gen_yield, 0);
        _ = try self.chunk.emit(.pop, 0);
        _ = try self.chunk.emit(.jump, @intCast(top));
        self.chunk.patchToHere(to_end);
        // yield* evaluates to the iterator's final value (`r.value`).
        try self.emitLoad(r_name);
        _ = try self.chunk.emit(.get_prop, try self.chunk.addName("value"));
    }

    /// A unique, user-unreferenceable temp name (contains a NUL byte).
    fn freshTemp(self: *Compiler) CompileError![]const u8 {
        const n = self.tmp_counter;
        self.tmp_counter += 1;
        return std.fmt.allocPrint(self.arena, "\x00ys{d}", .{n});
    }

    fn hasSpread(args: []const *Node) bool {
        for (args) |a| if (a.* == .spread) return true;
        return false;
    }

    /// Build a fresh array holding a call/new's argument list, expanding any
    /// `...spread` element — for the variadic `*_spread` call opcodes.
    fn compileArgsArray(self: *Compiler, args: []const *Node) CompileError!void {
        _ = try self.chunk.emit(.new_array, 0);
        for (args) |a| {
            if (a.* == .spread) {
                try self.compileExpr(a.spread);
                _ = try self.chunk.emit(.array_spread, 0);
            } else {
                try self.compileExpr(a);
                _ = try self.chunk.emit(.array_append, 0);
            }
        }
    }

    fn compileFunction(self: *Compiler, fnode: *const ast.FunctionNode) CompileError!u32 {
        // Async functions tree-walk (the Promise runtime isn't lowered yet), so
        // bail here to force the fallback for any program that defines one.
        if (fnode.is_async) return error.Unsupported;
        const sub = try self.arena.create(Chunk);
        sub.* = Chunk.init(self.arena);

        // Build this function's slot namespace: parameters first, then every
        // function-scoped declaration in the body (not descending into nested
        // functions). The scope chains to the enclosing function for upvalues.
        const scope = try self.arena.create(FnScope);
        scope.* = .{ .parent = self.scope };
        for (fnode.params) |p| {
            // Default values and rest params need a runtime prologue the VM
            // doesn't emit yet — fall back to the tree-walker for those.
            if (p.default != null or p.is_rest or p.pattern != null) return error.Unsupported;
            _ = try scope.addLocal(self.arena, p.name);
        }
        if (!fnode.is_expr_body) try collectLocals(self.arena, scope, fnode.body);

        var sub_c = Compiler{ .arena = self.arena, .chunk = sub, .mode = .function, .scope = scope };
        if (fnode.is_expr_body) {
            try sub_c.compileExpr(fnode.body);
            _ = try sub.emit(.ret, 0);
        } else {
            try sub_c.compileStmt(fnode.body); // body is a block
            _ = try sub.emit(.ret_undef, 0);
        }
        try sub.finalize();
        const tmpl = try self.arena.create(bc.FnTemplate);
        tmpl.* = .{
            .name = fnode.name,
            .params = fnode.params,
            .is_expr_body = fnode.is_expr_body,
            .body = fnode.body,
            .source = fnode.source,
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

    /// The nearest loop a `continue` applies to — skipping any enclosing
    /// `switch` (which is breakable but not continuable).
    fn currentContinueLoop(self: *Compiler) ?*Loop {
        var i = self.loops.items.len;
        while (i > 0) {
            i -= 1;
            if (!self.loops.items[i].is_switch) return self.loops.items[i];
        }
        return null;
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
        .decl_group => |stmts| for (stmts) |s| try collectLocals(arena, scope, s),
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
