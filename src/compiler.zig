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

/// Whether a node embeds a `yield` reachable without crossing a function
/// boundary — used to decide whether a destructuring assignment must be lowered
/// to bytecode (yield present) or can defer to the tree-walker via `bind_pattern`.
fn nodeHasYield(node: *const ast.Node) bool {
    return switch (node.*) {
        .yield_expr => true,
        .function => false, // a nested function/arrow is its own yield scope
        .unary => |u| nodeHasYield(u.operand),
        .delete_expr => |d| nodeHasYield(d),
        .update => |u| nodeHasYield(u.target),
        .binary => |b| nodeHasYield(b.left) or nodeHasYield(b.right),
        .logical => |b| nodeHasYield(b.left) or nodeHasYield(b.right),
        .sequence => |s| nodeHasYield(s.first) or nodeHasYield(s.second),
        .assign => |a| nodeHasYield(a.target) or nodeHasYield(a.value),
        .op_assign => |a| nodeHasYield(a.target) or nodeHasYield(a.value),
        .conditional => |c| nodeHasYield(c.cond) or nodeHasYield(c.consequent) or nodeHasYield(c.alternate),
        .await_expr => |a| nodeHasYield(a.argument),
        .optional_chain => |c| nodeHasYield(c),
        .spread => |s| nodeHasYield(s),
        .member => |m| nodeHasYield(m.object) or (m.computed != null and nodeHasYield(m.computed.?)),
        .super_member => |m| (m.computed != null and nodeHasYield(m.computed.?)),
        .call => |c| blk: {
            if (nodeHasYield(c.callee)) break :blk true;
            for (c.args) |a| if (nodeHasYield(a)) break :blk true;
            break :blk false;
        },
        .new_expr => |c| blk: {
            if (nodeHasYield(c.callee)) break :blk true;
            for (c.args) |a| if (nodeHasYield(a)) break :blk true;
            break :blk false;
        },
        .tagged_template => |t| blk: {
            if (nodeHasYield(t.tag)) break :blk true;
            for (t.exprs) |e| if (nodeHasYield(e)) break :blk true;
            break :blk false;
        },
        .array_lit => |elems| blk: {
            for (elems) |e| if (nodeHasYield(e)) break :blk true;
            break :blk false;
        },
        .object_lit => |props| blk: {
            for (props) |p| {
                if (p.key_expr) |ke| if (nodeHasYield(ke)) break :blk true;
                if (nodeHasYield(p.value)) break :blk true;
            }
            break :blk false;
        },
        .arr_pattern => |p| blk: {
            for (p.elems) |e| {
                if (e.target) |t| if (nodeHasYield(t)) break :blk true;
                if (e.default) |d| if (nodeHasYield(d)) break :blk true;
            }
            if (p.rest) |r| if (nodeHasYield(r)) break :blk true;
            break :blk false;
        },
        .obj_pattern => |p| blk: {
            for (p.props) |pp| {
                if (pp.key_expr) |ke| if (nodeHasYield(ke)) break :blk true;
                if (pp.default) |d| if (nodeHasYield(d)) break :blk true;
                if (nodeHasYield(pp.target)) break :blk true;
            }
            break :blk false;
        },
        else => false,
    };
}

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
        // An async generator body may also `await` (in_async enables await_op).
        var c = Compiler{ .arena = arena, .chunk = chunk, .mode = .function, .scope = null, .in_generator = true, .in_async = fnode.is_async };
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
        try self.emitDefineKind(name, .@"var");
    }

    fn emitDefineKind(self: *Compiler, name: []const u8, kind: ast.DeclKind) CompileError!void {
        switch (self.resolve(name)) {
            .local => |slot| {
                _ = try self.chunk.emit(.store_local, slot);
                _ = try self.chunk.emit(.pop, 0);
            },
            .upval => |u| {
                _ = try self.chunk.emitAB(.store_upval, u.depth, u.slot);
                _ = try self.chunk.emit(.pop, 0);
            },
            .global => {
                const ni = try self.chunk.addName(name);
                if (self.mode == .program and kind != .@"var")
                    _ = try self.chunk.emitAB(.def_lex, ni, if (kind == .@"const") 2 else 1)
                else
                    _ = try self.chunk.emit(.def_var, ni);
            },
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
                const fi = try self.compileFunction(fnode, false);
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
                try self.emitDefineKind(d.name, d.kind);
            },
            .func_decl => |fnode| {
                const fi = try self.compileFunction(fnode, false);
                _ = try self.chunk.emit(.make_closure, fi);
                try self.emitDefine(fnode.name);
            },
            .return_stmt => |maybe| {
                // A `return` lexically inside a `try`/`catch`/`finally` must run
                // the enclosing finally block(s) first: `abrupt_return` unwinds
                // the handler stack, runs each finally carrying a return
                // completion, and returns once they finish (only reachable inside
                // a generator, since compileTry is generator-only).
                if (self.finally_depth > 0) {
                    if (maybe) |e| try self.compileExpr(e) else _ = try self.chunk.emit(.load_undefined, 0);
                    _ = try self.chunk.emit(.abrupt_return, 0);
                } else if (maybe) |e| {
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
                const loop = self.currentLoop() orelse return error.Unsupported;
                // Across a finally, the finally must run before the jump:
                // `abrupt_break` unwinds the handler stack running each enclosing
                // finally, then jumps to the (patched) break target.
                const j = try self.chunk.emit(if (self.finally_depth > 0) .abrupt_break else .jump, 0);
                try loop.breaks.append(self.arena, j);
            },
            .continue_stmt => |label| {
                if (label != null) return error.Unsupported; // labeled continue → tree-walk
                const loop = self.currentContinueLoop() orelse return error.Unsupported;
                const j = try self.chunk.emit(if (self.finally_depth > 0) .abrupt_continue else .jump, 0);
                try loop.continues.append(self.arena, j);
            },
            .switch_stmt => |sw| try self.compileSwitch(sw.disc, sw.cases),
            .throw_stmt => |e| {
                try self.compileExpr(e);
                _ = try self.chunk.emit(.throw_op, 0);
            },
            .for_in => |f| {
                // for-of works everywhere it's lowered; for-in is lowered only in
                // generators (via `enum_keys`); for-await only in async bodies.
                if (!f.is_of and !self.in_generator) return error.Unsupported;
                if (f.is_await and !self.in_async) return error.Unsupported;
                try self.compileForOf(f.decl_kind, f.target, f.iterable, f.body, !f.is_of, f.is_await);
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
    /// Bind the current loop value (on the stack) to a loop target — an
    /// identifier (fast path) or a destructuring pattern / member target (via
    /// `bind_pattern`, reusing the tree-walker's destructuring).
    fn compileLoopBind(self: *Compiler, decl_kind: ?ast.DeclKind, target: *Node) CompileError!void {
        if (target.* == .identifier) {
            if (decl_kind != null) {
                try self.emitDefine(target.identifier);
            } else {
                try self.emitStore(target.identifier);
                _ = try self.chunk.emit(.pop, 0);
            }
            return;
        }
        // `bind_pattern` destructures into the live environment, which is the
        // binding scope only in env-mode (generators/async). A slot-allocated
        // (frame-mode) function keeps falling back to the tree-walker.
        if (self.scope != null) return error.Unsupported;
        const pi = try self.chunk.addPattern(target);
        const mode: u32 = if (decl_kind) |k| switch (k) {
            .@"var" => 0,
            .let => 1,
            .@"const" => 2,
        } else 3;
        _ = try self.chunk.emitAB(.bind_pattern, pi, mode);
    }

    fn compileForOf(self: *Compiler, decl_kind: ?ast.DeclKind, target: *Node, iterable: *Node, body: *Node, keys_first: bool, await_each: bool) CompileError!void {
        const it_name = try self.freshTemp();
        const r_name = try self.freshTemp();

        try self.compileExpr(iterable);
        if (keys_first) _ = try self.chunk.emit(.enum_keys, 0); // for-in: iterate the key array
        // for-await uses the async-iterator protocol (Symbol.asyncIterator, else
        // a wrapped sync iterator) and awaits each `next()` result.
        _ = try self.chunk.emit(if (await_each) .async_iter_of else .iter_of, 0);
        try self.emitDefine(it_name);

        const loop = try self.pushLoop();
        const top = self.chunk.here();
        // r = it.next()  (for-await: r = await it.next())
        try self.emitLoad(it_name);
        _ = try self.chunk.emitAB(.call_method, try self.chunk.addName("next"), 0);
        if (await_each) _ = try self.chunk.emit(.await_op, 0); // await the next() result
        try self.emitDefine(r_name);
        // if (r.done) break  — `not` then jump_if_false exits exactly when done.
        try self.emitLoad(r_name);
        _ = try self.chunk.emit(.get_prop, try self.chunk.addName("done"));
        _ = try self.chunk.emit(.not, 0);
        const to_end = try self.chunk.emit(.jump_if_false, 0);
        // bind r.value to the loop target (identifier or destructuring pattern)
        try self.emitLoad(r_name);
        _ = try self.chunk.emit(.get_prop, try self.chunk.addName("value"));
        try self.compileLoopBind(decl_kind, target);
        try self.compileStmt(body);
        _ = try self.chunk.emit(.jump, @intCast(top));
        self.chunk.patchToHere(to_end);
        // `continue` re-enters the loop at the top (next .next()).
        for (loop.continues.items) |j| self.chunk.patchTo(j, top);
        for (loop.breaks.items) |j| self.chunk.patchToHere(j);
        self.popLoop();
    }

    // ---- destructuring assignment (generator, yield-aware) ----------------

    /// `pattern = value` as an expression. Evaluates `value`, leaves it on the
    /// stack as the result, and destructures it into `pattern`.
    fn compileDestructuringAssign(self: *Compiler, pattern: *Node, value: *Node) CompileError!void {
        try self.compileExpr(value); // [v]
        const src = try self.freshTemp();
        _ = try self.chunk.emit(.dup, 0); // [v, v]
        try self.emitDefine(src); // [v]   (define consumes one copy)
        try self.compileAssignPattern(pattern, src);
        // `src` (the rhs value) remains on the stack as the expression result.
    }

    fn compileAssignPattern(self: *Compiler, pattern: *Node, src: []const u8) CompileError!void {
        switch (pattern.*) {
            .arr_pattern => |p| try self.compileArrayAssign(p.elems, p.rest, src),
            .obj_pattern => |p| try self.compileObjectAssign(p.props, p.rest, src),
            else => return error.Unsupported,
        }
    }

    /// Assign the value held in temp `val` to a destructuring target — an
    /// identifier, a member reference (whose base/key were already evaluated
    /// into `ref`), or a nested pattern.
    fn compileAssignToTarget(self: *Compiler, target: *Node, val: []const u8) CompileError!void {
        switch (target.*) {
            .identifier => |name| {
                try self.emitLoad(val);
                try self.emitStore(name);
                _ = try self.chunk.emit(.pop, 0);
            },
            .arr_pattern, .obj_pattern => {
                // A yield-free nested pattern reuses the tree-walker (handles
                // RequireObjectCoercible and every edge case); a yield-bearing
                // one recurses into bytecode.
                if (nodeHasYield(target)) {
                    try self.compileAssignPattern(target, val);
                } else {
                    try self.emitLoad(val);
                    const pi = try self.chunk.addPattern(target);
                    _ = try self.chunk.emitAB(.bind_pattern, pi, 3);
                }
            },
            else => return error.Unsupported, // member handled separately (ordered ref eval)
        }
    }

    /// Pre-evaluate a member target's base (and computed key) into fresh temps,
    /// BEFORE the iterator advances (the spec evaluates the reference first).
    /// Returns the temp names, or null when `target` is not a member.
    const MemberRef = struct { obj: []const u8, key: ?[]const u8 };
    fn preEvalMemberRef(self: *Compiler, target: ?*Node) CompileError!?MemberRef {
        const t = target orelse return null;
        if (t.* != .member) return null;
        const m = t.member;
        const obj_tmp = try self.freshTemp();
        try self.compileExpr(m.object);
        try self.emitDefine(obj_tmp);
        var key_tmp: ?[]const u8 = null;
        if (m.computed) |ce| {
            const kt = try self.freshTemp();
            try self.compileExpr(ce);
            try self.emitDefine(kt);
            key_tmp = kt;
        }
        return .{ .obj = obj_tmp, .key = key_tmp };
    }

    /// Store the value in temp `val` through an already-evaluated member ref.
    fn storeMemberRef(self: *Compiler, target: *Node, ref: MemberRef, val: []const u8) CompileError!void {
        const m = target.member;
        try self.emitLoad(ref.obj); // [obj]
        if (ref.key) |kt| {
            try self.emitLoad(kt); // [obj, key]
            try self.emitLoad(val); // [obj, key, val]
            _ = try self.chunk.emit(.set_index, 0);
        } else {
            try self.emitLoad(val); // [obj, val]
            _ = try self.chunk.emit(.set_prop, try self.chunk.addName(m.property));
        }
        _ = try self.chunk.emit(.pop, 0); // discard the set result
    }

    /// `[ e0, e1, ... ] = src` (assignment form, in a generator). Drives the
    /// iterator protocol, applies defaults (which may yield), and runs
    /// IteratorClose when destructuring stops before exhausting the iterator —
    /// on a normal early stop AND on an abrupt completion (a `yield` resumed
    /// with `.return()`/`.throw()` mid-destructure), via a finally handler.
    fn compileArrayAssign(self: *Compiler, elems: []const ast.ArrPatElem, rest: ?*Node, src: []const u8) CompileError!void {
        const none = std.math.maxInt(u32);
        try self.emitLoad(src);
        _ = try self.chunk.emit(.iter_of, 0);
        const it = try self.freshTemp();
        try self.emitDefine(it);
        const done = try self.freshTemp();
        _ = try self.chunk.emit(.load_false, 0);
        try self.emitDefine(done);

        // Wrap the element/rest processing in a finally handler so any abrupt
        // completion (return/throw injected at an embedded yield) still closes
        // the iterator before propagating.
        const ph = try self.chunk.emitAB(.push_handler, none, none);
        try self.compileArrayAssignBody(elems, rest, it, done);
        _ = try self.chunk.emit(.pop_handler, 0);
        _ = try self.chunk.emit(.push_completion, 0); // normal completion
        // The normal path falls straight into the finally body (which the abrupt
        // path also jumps to via finally_pc); `end_finally` then resumes the
        // pushed completion — fall through on normal, re-propagate on abrupt.
        self.chunk.code.items[ph].b = @intCast(self.chunk.here());
        try self.emitLoad(done);
        _ = try self.chunk.emit(.not, 0);
        const skip = try self.chunk.emit(.jump_if_false, 0);
        try self.emitLoad(it);
        _ = try self.chunk.emit(.iter_close, 0);
        self.chunk.patchToHere(skip);
        _ = try self.chunk.emit(.end_finally, 0);
    }

    fn compileArrayAssignBody(self: *Compiler, elems: []const ast.ArrPatElem, rest: ?*Node, it: []const u8, done: []const u8) CompileError!void {
        for (elems) |elem| {
            // Spec order: evaluate the target reference first, then step the
            // iterator. Only member targets carry an observable reference eval.
            const ref = try self.preEvalMemberRef(elem.target);
            // ev = undefined; if (!done) { r = it.next(); if (r.done) done = true else ev = r.value }
            const ev = try self.freshTemp();
            _ = try self.chunk.emit(.load_undefined, 0);
            try self.emitDefine(ev);
            try self.emitLoad(done);
            _ = try self.chunk.emit(.not, 0);
            const skip_step = try self.chunk.emit(.jump_if_false, 0); // skip when done
            {
                const r = try self.freshTemp();
                try self.emitLoad(it);
                _ = try self.chunk.emitAB(.call_method, try self.chunk.addName("next"), 0);
                try self.emitDefine(r);
                try self.emitLoad(r);
                _ = try self.chunk.emit(.get_prop, try self.chunk.addName("done"));
                const not_done = try self.chunk.emit(.jump_if_false, 0);
                _ = try self.chunk.emit(.load_true, 0);
                try self.emitStore(done);
                _ = try self.chunk.emit(.pop, 0);
                const after = try self.chunk.emit(.jump, 0);
                self.chunk.patchToHere(not_done);
                try self.emitLoad(r);
                _ = try self.chunk.emit(.get_prop, try self.chunk.addName("value"));
                try self.emitStore(ev);
                _ = try self.chunk.emit(.pop, 0);
                self.chunk.patchToHere(after);
            }
            self.chunk.patchToHere(skip_step);
            // default: if (ev === undefined) ev = <default>   (may yield)
            if (elem.default) |d| {
                try self.emitLoad(ev);
                _ = try self.chunk.emit(.load_undefined, 0);
                _ = try self.chunk.emit(.eq_strict, 0);
                const has_val = try self.chunk.emit(.jump_if_false, 0);
                try self.compileExpr(d);
                try self.emitStore(ev);
                _ = try self.chunk.emit(.pop, 0);
                self.chunk.patchToHere(has_val);
            }
            // assign ev to the target
            if (elem.target) |t| {
                if (t.* == .member) {
                    try self.storeMemberRef(t, ref.?, ev);
                } else {
                    try self.compileAssignToTarget(t, ev);
                }
            }
        }

        if (rest) |rest_target| {
            // Spec order: evaluate the rest target reference (may yield) BEFORE
            // collecting the remaining elements.
            const rref = try self.preEvalMemberRef(rest_target);
            // rest = []; while (!done) { r = it.next(); if (r.done) { done=true; break } rest.push(r.value) }
            const ra = try self.freshTemp();
            _ = try self.chunk.emit(.new_array, 0);
            try self.emitDefine(ra);
            const top = self.chunk.here();
            try self.emitLoad(done);
            _ = try self.chunk.emit(.not, 0);
            const to_end = try self.chunk.emit(.jump_if_false, 0); // exit when done
            const r = try self.freshTemp();
            try self.emitLoad(it);
            _ = try self.chunk.emitAB(.call_method, try self.chunk.addName("next"), 0);
            try self.emitDefine(r);
            try self.emitLoad(r);
            _ = try self.chunk.emit(.get_prop, try self.chunk.addName("done"));
            const not_done = try self.chunk.emit(.jump_if_false, 0);
            _ = try self.chunk.emit(.load_true, 0);
            try self.emitStore(done);
            _ = try self.chunk.emit(.pop, 0);
            const to_end2 = try self.chunk.emit(.jump, 0);
            self.chunk.patchToHere(not_done);
            try self.emitLoad(ra);
            try self.emitLoad(r);
            _ = try self.chunk.emit(.get_prop, try self.chunk.addName("value"));
            _ = try self.chunk.emit(.array_append, 0);
            _ = try self.chunk.emit(.pop, 0); // drop the array left by array_append
            _ = try self.chunk.emit(.jump, @intCast(top));
            self.chunk.patchToHere(to_end);
            self.chunk.patchToHere(to_end2);
            if (rest_target.* == .member)
                try self.storeMemberRef(rest_target, rref.?, ra)
            else
                try self.compileAssignToTarget(rest_target, ra);
        }
        // The enclosing finally handler performs IteratorClose when `!done`.
    }

    /// `{ k0: t0 = d0, ... } = src` (assignment form, in a generator).
    fn compileObjectAssign(self: *Compiler, props: []const ast.ObjPatProp, rest: ?[]const u8, src: []const u8) CompileError!void {
        if (rest != null) return error.Unsupported; // object rest in a yield pattern → tree-walk fallback
        for (props) |prop| {
            // PropertyName (may be computed and yield), then the target reference.
            const ref = try self.preEvalMemberRef(prop.target);
            const ev = try self.freshTemp();
            // ev = src[key]
            try self.emitLoad(src);
            if (prop.key_expr) |ke| {
                try self.compileExpr(ke);
                _ = try self.chunk.emit(.get_index, 0);
            } else {
                _ = try self.chunk.emit(.get_prop, try self.chunk.addName(prop.key));
            }
            try self.emitDefine(ev);
            // default
            if (prop.default) |d| {
                try self.emitLoad(ev);
                _ = try self.chunk.emit(.load_undefined, 0);
                _ = try self.chunk.emit(.eq_strict, 0);
                const has_val = try self.chunk.emit(.jump_if_false, 0);
                try self.compileExpr(d);
                try self.emitStore(ev);
                _ = try self.chunk.emit(.pop, 0);
                self.chunk.patchToHere(has_val);
            }
            if (prop.target.* == .member)
                try self.storeMemberRef(prop.target, ref.?, ev)
            else
                try self.compileAssignToTarget(prop.target, ev);
        }
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
                    .to_string => .to_string,
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
                // Destructuring assignment `[a,b] = v` / `{x} = v`. A pattern with
                // no `yield` reuses the tree-walker via `bind_pattern` (proven,
                // handles every edge case); a pattern that DOES embed `yield`
                // (only reachable in a generator) is lowered to bytecode so the
                // yield can suspend mid-destructure.
                .arr_pattern, .obj_pattern => {
                    if (self.scope != null) return error.Unsupported; // env-mode only
                    if (nodeHasYield(a.target)) {
                        try self.compileDestructuringAssign(a.target, a.value);
                    } else {
                        try self.compileExpr(a.value);
                        _ = try self.chunk.emit(.dup, 0); // leave the rhs as the result
                        const pi = try self.chunk.addPattern(a.target);
                        _ = try self.chunk.emitAB(.bind_pattern, pi, 3);
                    }
                },
                else => return error.Unsupported,
            },
            .op_assign => |oa| switch (oa.target.*) {
                // Identifier target: load the old value, apply the op, store back.
                // (No `with` here — a function using `with` already falls back to
                // the tree-walker, which resolves the reference once.)
                .identifier => |name| {
                    const op: bc.Op = switch (oa.op) {
                        .add => .add,        .sub => .sub,       .mul => .mul,
                        .div => .div,        .mod => .mod,       .pow => .pow,
                        .bit_and => .bit_and, .bit_or => .bit_or, .bit_xor => .bit_xor,
                        .shl => .shl,        .shr => .shr,       .ushr => .ushr,
                        else => return error.Unsupported,
                    };
                    try self.emitLoad(name);
                    try self.compileExpr(oa.value);
                    _ = try self.chunk.emit(op, 0);
                    try self.emitStore(name);
                },
                // Member/super targets resolve the base once — defer to the
                // tree-walker (correct reference semantics, member case is rarer).
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
                const fi = try self.compileFunction(fnode, true);
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
                    // Spread + accessor properties are lowered only inside
                    // generators (where lowering is mandatory); plain code keeps
                    // tree-walking, which has the fuller/faster path.
                    if (p.is_spread or p.accessor != .none) {
                        if (!self.in_generator) return error.Unsupported;
                        if (p.is_spread) {
                            try self.compileExpr(p.value); // CopyDataProperties source
                            _ = try self.chunk.emit(.init_spread, 0);
                            continue;
                        }
                        // Getter/setter: push key, push the function, install.
                        if (p.key_expr) |ke| {
                            try self.compileExpr(ke);
                        } else {
                            const ci = try self.chunk.addConst(.{ .string = p.key });
                            _ = try self.chunk.emit(.load_const, ci);
                        }
                        const gi = try self.compileFunction(p.value.function, false);
                        _ = try self.chunk.emit(.make_closure, gi);
                        _ = try self.chunk.emit(if (p.accessor == .get) .init_getter else .init_setter, 0);
                        continue;
                    }
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
                    // AsyncGeneratorYield first `Await`s the operand, so e.g.
                    // `yield Promise.reject(e)` rejects the pending `next()`.
                    if (self.in_async) _ = try self.chunk.emit(.await_op, 0);
                    _ = try self.chunk.emit(.gen_yield, 0);
                }
            },
            // `await e` suspends like a yield; the async driver promisifies the
            // value and resumes with the settled result (or injects a throw).
            .await_expr => |a| {
                if (!self.in_async) return error.Unsupported;
                try self.compileExpr(a.argument);
                _ = try self.chunk.emit(.await_op, 0);
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

    /// `yield* X`: delegate to `X`'s iterator per the spec's YieldStar algorithm
    /// (14.4.14 runtime semantics). The desugared loop dispatches on *how the
    /// delegating generator was resumed* — a `gen_yield_star` suspend pushes a
    /// `[value, kind]` pair on resume so the loop can forward `.throw(e)` to the
    /// inner `throw` method and `.return(v)` to the inner `return` method, not
    /// just relay `.next(v)`.
    ///
    /// Pseudocode (kind: 0 = next, 1 = throw, 2 = return):
    ///     it = GetIterator(X); recv_v = undefined; recv_k = 0
    ///     loop:
    ///       if recv_k == 0:  r = it.next(recv_v)
    ///       elif recv_k == 1:
    ///         m = GetMethod(it, "throw")
    ///         if m == undefined: IteratorClose(it); throw TypeError
    ///         r = m.call(it, recv_v)
    ///       else: // recv_k == 2
    ///         m = GetMethod(it, "return")
    ///         if m == undefined: return recv_v        // generator returns
    ///         r = m.call(it, recv_v)
    ///         if r.done: return r.value               // generator returns
    ///         goto yield
    ///       // (next / throw join)
    ///       if not IsObject(r): throw TypeError
    ///       if r.done: break with value r.value
    ///       yield: [recv_v, recv_k] = yield* r.value
    ///     // value of the whole expression:
    ///     r.value
    fn compileYieldStar(self: *Compiler, arg: *Node) CompileError!void {
        const async_d = self.in_async; // delegate to an async iterator?
        const it = try self.freshTemp(); // the iterator
        const r = try self.freshTemp(); // the last `{value, done}` result
        const recv_v = try self.freshTemp(); // value carried by the resume
        const recv_k = try self.freshTemp(); // resume kind: 0 next / 1 throw / 2 return
        const m = try self.freshTemp(); // a GetMethod(it, throw|return) result
        const ch = self.chunk;
        const done_n = try ch.addName("done");
        const value_n = try ch.addName("value");

        // it = GetIterator(arg); recv_v = undefined; recv_k = 0 (start with `next`).
        try self.compileExpr(arg);
        _ = try ch.emit(if (async_d) .async_iter_of else .iter_of, 0);
        try self.emitDefine(it);
        _ = try ch.emit(.load_undefined, 0);
        try self.emitDefine(recv_v);
        _ = try ch.emit(.load_const, try ch.addConst(.{ .number = 0 }));
        try self.emitDefine(recv_k);

        const top = ch.here();
        // if (recv_k == 0) fall through to the `next` branch, else jump to throw/return.
        try self.emitLoad(recv_k);
        _ = try ch.emit(.load_const, try ch.addConst(.{ .number = 0 }));
        _ = try ch.emit(.eq_strict, 0);
        const to_nonnext = try ch.emit(.jump_if_false, 0);

        // --- next branch: r = it.next(recv_v) ---
        try self.emitLoad(it);
        try self.emitLoad(recv_v);
        _ = try ch.emitAB(.call_method, try ch.addName("next"), 1);
        if (async_d) _ = try ch.emit(.await_op, 0);
        try self.emitDefine(r);
        const to_join_a = try ch.emit(.jump, 0); // -> normal/throw join

        // --- recv_k == 1 ? throw branch : return branch ---
        ch.patchToHere(to_nonnext);
        try self.emitLoad(recv_k);
        _ = try ch.emit(.load_const, try ch.addConst(.{ .number = 1 }));
        _ = try ch.emit(.eq_strict, 0);
        const to_return = try ch.emit(.jump_if_false, 0);

        // --- throw branch ---
        // m = GetMethod(it, "throw")
        try self.emitLoad(it);
        _ = try ch.emit(.get_prop, try ch.addName("throw"));
        try self.emitDefine(m);
        try self.emitLoad(m);
        _ = try ch.emit(.load_null, 0);
        _ = try ch.emit(.eq, 0); // m == null  (true for undefined/null: GetMethod absent)
        const to_has_throw = try ch.emit(.jump_if_false, 0);
        // No `throw` method: IteratorClose(it) (call `return` if present, ignoring
        // its result) then throw a TypeError. Closing first lets the inner
        // iterator release resources, matching the spec.
        try self.emitLoad(it);
        _ = try ch.emit(.get_prop, try ch.addName("return"));
        try self.emitDefine(m);
        try self.emitLoad(m);
        _ = try ch.emit(.load_null, 0);
        _ = try ch.emit(.eq, 0);
        const to_skip_close = try ch.emit(.jump_if_false, 0);
        const to_after_close = try ch.emit(.jump, 0); // return absent: skip the call
        ch.patchToHere(to_skip_close);
        try self.emitLoad(m); // func
        try self.emitLoad(it); // this
        _ = try ch.emitAB(.call_with_this, 0, 0); // it.return()
        if (async_d) _ = try ch.emit(.await_op, 0);
        _ = try ch.emit(.pop, 0); // ignore the close result
        ch.patchToHere(to_after_close);
        // throw new TypeError(...)
        _ = try ch.emit(.load_var, try ch.addName("TypeError"));
        _ = try ch.emit(.load_const, try ch.addConst(.{ .string = "The iterator does not provide a 'throw' method" }));
        _ = try ch.emit(.new_call, 1);
        _ = try ch.emit(.throw_op, 0);
        // has a `throw` method: r = m.call(it, recv_v)
        ch.patchToHere(to_has_throw);
        try self.emitLoad(m);
        try self.emitLoad(it);
        try self.emitLoad(recv_v);
        _ = try ch.emitAB(.call_with_this, 1, 0);
        if (async_d) _ = try ch.emit(.await_op, 0);
        try self.emitDefine(r);
        const to_join_b = try ch.emit(.jump, 0); // -> normal/throw join

        // --- return branch ---
        ch.patchToHere(to_return);
        // m = GetMethod(it, "return")
        try self.emitLoad(it);
        _ = try ch.emit(.get_prop, try ch.addName("return"));
        try self.emitDefine(m);
        try self.emitLoad(m);
        _ = try ch.emit(.load_null, 0);
        _ = try ch.emit(.eq, 0);
        const to_has_return = try ch.emit(.jump_if_false, 0);
        // No `return` method: the delegating generator itself returns recv_v
        // (Await it first in an async generator), running any enclosing finally.
        try self.emitLoad(recv_v);
        if (async_d) _ = try ch.emit(.await_op, 0);
        _ = try ch.emit(.abrupt_return, 0);
        // has a `return` method: r = m.call(it, recv_v)
        ch.patchToHere(to_has_return);
        try self.emitLoad(m);
        try self.emitLoad(it);
        try self.emitLoad(recv_v);
        _ = try ch.emitAB(.call_with_this, 1, 0);
        if (async_d) _ = try ch.emit(.await_op, 0);
        try self.emitDefine(r);
        try self.emitLoad(r);
        _ = try ch.emit(.assert_iter_result, 0);
        _ = try ch.emit(.pop, 0);
        // if (r.done) the delegating generator returns r.value; else yield it.
        try self.emitLoad(r);
        _ = try ch.emit(.get_prop, done_n);
        const to_return_yield = try ch.emit(.jump_if_false, 0);
        try self.emitLoad(r);
        _ = try ch.emit(.get_prop, value_n);
        _ = try ch.emit(.abrupt_return, 0);

        // --- normal/throw join: validate r, branch on done ---
        ch.patchToHere(to_join_a);
        ch.patchToHere(to_join_b);
        try self.emitLoad(r);
        _ = try ch.emit(.assert_iter_result, 0);
        _ = try ch.emit(.pop, 0);
        try self.emitLoad(r);
        _ = try ch.emit(.get_prop, done_n);
        const to_yield = try ch.emit(.jump_if_false, 0);
        const to_end = try ch.emit(.jump, 0); // done -> the whole expression's value

        // --- yield, then resume with [recv_v, recv_k] and loop ---
        // A *sync* generator's `yield*` yields the inner result object itself
        // (`GeneratorYield(innerResult)`), so its own `value`/`done` pass through
        // to the consumer untouched. An *async* generator instead yields
        // `Await(IteratorValue(innerResult))` (`AsyncGeneratorYield`), which the
        // async driver re-wraps into a fresh `{ value, done:false }`.
        ch.patchToHere(to_yield);
        ch.patchToHere(to_return_yield);
        if (async_d) {
            try self.emitLoad(r);
            _ = try ch.emit(.get_prop, value_n);
            _ = try ch.emit(.await_op, 0); // AsyncGeneratorYield awaits before yielding
        } else {
            try self.emitLoad(r); // yield the inner result object as-is
        }
        _ = try ch.emit(.gen_yield_star, 0); // resume pushes [value, kind] (kind on top)
        try self.emitStore(recv_k);
        _ = try ch.emit(.pop, 0);
        try self.emitStore(recv_v);
        _ = try ch.emit(.pop, 0);
        _ = try ch.emit(.jump, @intCast(top));

        // yield* evaluates to the final `r.value` when the inner iterator is done.
        ch.patchToHere(to_end);
        try self.emitLoad(r);
        _ = try ch.emit(.get_prop, value_n);
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

    fn compileFunction(self: *Compiler, fnode: *const ast.FunctionNode, named_expr: bool) CompileError!u32 {
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
            // A *named function expression* (not a declaration, not anonymous,
            // not an arrow) self-binds its own name in an enclosing immutable
            // scope — recorded here so `make_closure` wraps the closure env.
            .self_name = if (named_expr and !fnode.is_arrow) fnode.name else "",
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
