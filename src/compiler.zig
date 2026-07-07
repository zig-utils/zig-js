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
const value_mod = @import("value.zig");
const Value = value_mod.Value;

pub const CompileError = error{ Unsupported, OutOfMemory };

/// Whether the result of a top-level expression statement becomes the program's
/// completion value (`program`) or is discarded (`function`).
const Mode = enum { program, function };

const Loop = struct {
    breaks: std.ArrayListUnmanaged(usize) = .empty,
    continues: std.ArrayListUnmanaged(usize) = .empty,
    label: ?[]const u8 = null,
    /// A labeled non-loop statement is breakable but not continuable.
    is_loop: bool = true,
    /// A `switch` is breakable but not continuable: `break` targets it, but
    /// `continue` skips past it to the nearest enclosing loop.
    is_switch: bool = false,
    /// The `finally_depth` in effect where this loop/switch was entered. A
    /// `break`/`continue` targeting it needs an `abrupt_*` unwind only when it
    /// CROSSES a finally — i.e. the current finally_depth is deeper than this one.
    /// A loop that lives entirely inside a finally (same depth) breaks with a
    /// plain jump, so it does not disturb that finally's in-flight completion.
    finally_depth: u32 = 0,
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
        .logical_assign => |a| nodeHasYield(a.target) or nodeHasYield(a.value),
        .conditional => |c| nodeHasYield(c.cond) or nodeHasYield(c.consequent) or nodeHasYield(c.alternate),
        .await_expr => |a| nodeHasYield(a.argument),
        .import_call => |ic| nodeHasYield(ic.specifier) or (ic.options != null and nodeHasYield(ic.options.?)),
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

/// Does a `let`/`const` for-loop's `body` capture one of the loop's per-iteration
/// binding names inside a nested closure? Such loops need a fresh binding created
/// per iteration (CreatePerIterationEnvironment); the frame-slot VM lowering in
/// `compileFor` reuses ONE slot across iterations, so every captured closure would
/// see the final value (`var` semantics). When this returns true `compileFor`
/// bails to the tree-walker, which binds per iteration correctly. `var` loops, and
/// lexical loops whose closures never reference a loop name, keep the fast VM path.
fn forLoopCapturesLexical(init_node: *const ast.Node, body: *const ast.Node) bool {
    return switch (init_node.*) {
        .var_decl => |d| d.kind != .@"var" and nameRefInClosure(body, d.name, false),
        .destructure_decl => |d| d.kind != .@"var" and patternNameCaptured(d.pattern, body),
        // `let a = 0, b = 0` — a group of declarators; any captured name bails.
        .decl_group => |group| blk: {
            for (group) |n| if (forLoopCapturesLexical(n, body)) break :blk true;
            break :blk false;
        },
        else => false,
    };
}

/// Are any of the binding identifiers in a destructuring loop head (`for (let
/// [a, b] = …)`) captured by a closure in `body`?
fn patternNameCaptured(pat: *const ast.Node, body: *const ast.Node) bool {
    return switch (pat.*) {
        .identifier => |nm| nameRefInClosure(body, nm, false),
        .obj_pattern => |p| blk: {
            for (p.props) |pp| if (patternNameCaptured(pp.target, body)) break :blk true;
            if (p.rest) |r| if (patternNameCaptured(r, body)) break :blk true;
            break :blk false;
        },
        .arr_pattern => |p| blk: {
            for (p.elems) |e| if (e.target) |t| if (patternNameCaptured(t, body)) break :blk true;
            if (p.rest) |r| if (patternNameCaptured(r, body)) break :blk true;
            break :blk false;
        },
        else => false,
    };
}

/// Recursion core for `forLoopCapturesLexical`: is there an identifier reference
/// to `name` inside a nested function/arrow within `node`? `in_fn` tracks whether
/// the current subtree already sits (transitively) inside a function boundary —
/// only references there capture the loop variable, so a plain `body` read that is
/// NOT inside a closure does not force a bail. Unlike `nodeHasYield` this descends
/// INTO nested functions. The switch is exhaustive (no `else`) so a newly added
/// node kind can't silently become a false negative that reinstates the bug.
/// Deliberately ignores shadowing (an inner binding also named `name`) and treats
/// deferred class bodies as closures: over-matching only forces the correct-but-
/// slower tree-walker path, never a wrong VM lowering.
fn nameRefInClosure(node: *const ast.Node, name: []const u8, in_fn: bool) bool {
    return switch (node.*) {
        .identifier => |id| in_fn and std.mem.eql(u8, id, name),

        .number, .bigint_lit, .string, .boolean, .null_lit, .undefined_lit, .elision, .this_expr, .new_target_expr, .regex_literal, .import_meta, .import_decl, .break_stmt, .continue_stmt => false,

        // A nested function/arrow (expression or declaration): everything it (and
        // any deeper closure) references is captured — descend with `in_fn = true`.
        .function, .func_decl => |fnode| fnCaptures(fnode, name),

        .unary => |u| nameRefInClosure(u.operand, name, in_fn),
        .delete_expr => |d| nameRefInClosure(d, name, in_fn),
        .update => |u| nameRefInClosure(u.target, name, in_fn),
        .binary => |b| nameRefInClosure(b.left, name, in_fn) or nameRefInClosure(b.right, name, in_fn),
        .logical => |b| nameRefInClosure(b.left, name, in_fn) or nameRefInClosure(b.right, name, in_fn),
        .sequence => |s| nameRefInClosure(s.first, name, in_fn) or nameRefInClosure(s.second, name, in_fn),
        .assign => |a| nameRefInClosure(a.target, name, in_fn) or nameRefInClosure(a.value, name, in_fn),
        .op_assign => |a| nameRefInClosure(a.target, name, in_fn) or nameRefInClosure(a.value, name, in_fn),
        .logical_assign => |a| nameRefInClosure(a.target, name, in_fn) or nameRefInClosure(a.value, name, in_fn),
        .conditional => |c| nameRefInClosure(c.cond, name, in_fn) or nameRefInClosure(c.consequent, name, in_fn) or nameRefInClosure(c.alternate, name, in_fn),
        .yield_expr => |y| y.argument != null and nameRefInClosure(y.argument.?, name, in_fn),
        .await_expr => |a| nameRefInClosure(a.argument, name, in_fn),
        .class_expr => |c| blk: {
            // The superclass and computed member keys evaluate eagerly (current
            // `in_fn`); method bodies, field initializers, and static blocks run
            // deferred and so capture (`in_fn = true`).
            if (c.superclass) |sc| if (nameRefInClosure(sc, name, in_fn)) break :blk true;
            for (c.members) |m| {
                if (m.key_expr) |ke| if (nameRefInClosure(ke, name, in_fn)) break :blk true;
                if (m.func) |f| if (nameRefInClosure(f, name, in_fn)) break :blk true;
                if (m.field_init) |fi| if (nameRefInClosure(fi, name, true)) break :blk true;
                if (m.static_block) |sb| if (nameRefInClosure(sb, name, true)) break :blk true;
            }
            break :blk false;
        },
        .super_call => |args| blk: {
            for (args) |a| if (nameRefInClosure(a, name, in_fn)) break :blk true;
            break :blk false;
        },
        .super_member => |m| m.computed != null and nameRefInClosure(m.computed.?, name, in_fn),
        .call => |c| blk: {
            if (nameRefInClosure(c.callee, name, in_fn)) break :blk true;
            for (c.args) |a| if (nameRefInClosure(a, name, in_fn)) break :blk true;
            break :blk false;
        },
        .new_expr => |c| blk: {
            if (nameRefInClosure(c.callee, name, in_fn)) break :blk true;
            for (c.args) |a| if (nameRefInClosure(a, name, in_fn)) break :blk true;
            break :blk false;
        },
        .tagged_template => |t| blk: {
            if (nameRefInClosure(t.tag, name, in_fn)) break :blk true;
            for (t.exprs) |e| if (nameRefInClosure(e, name, in_fn)) break :blk true;
            break :blk false;
        },
        .member => |m| nameRefInClosure(m.object, name, in_fn) or (m.computed != null and nameRefInClosure(m.computed.?, name, in_fn)),
        .optional_chain => |c| nameRefInClosure(c, name, in_fn),
        .field_init_value => |v| nameRefInClosure(v, name, in_fn),
        .private_field_def => |p| nameRefInClosure(p.value, name, in_fn),
        .object_lit => |props| blk: {
            for (props) |p| {
                if (p.key_expr) |ke| if (nameRefInClosure(ke, name, in_fn)) break :blk true;
                if (nameRefInClosure(p.value, name, in_fn)) break :blk true;
            }
            break :blk false;
        },
        .array_lit => |elems| blk: {
            for (elems) |e| if (nameRefInClosure(e, name, in_fn)) break :blk true;
            break :blk false;
        },
        .spread => |s| nameRefInClosure(s, name, in_fn),
        .obj_pattern => |p| blk: {
            for (p.props) |pp| {
                if (pp.key_expr) |ke| if (nameRefInClosure(ke, name, in_fn)) break :blk true;
                if (nameRefInClosure(pp.target, name, in_fn)) break :blk true;
                if (pp.default) |d| if (nameRefInClosure(d, name, in_fn)) break :blk true;
            }
            if (p.rest) |r| if (nameRefInClosure(r, name, in_fn)) break :blk true;
            break :blk false;
        },
        .arr_pattern => |p| blk: {
            for (p.elems) |e| {
                if (e.target) |t| if (nameRefInClosure(t, name, in_fn)) break :blk true;
                if (e.default) |d| if (nameRefInClosure(d, name, in_fn)) break :blk true;
            }
            if (p.rest) |r| if (nameRefInClosure(r, name, in_fn)) break :blk true;
            break :blk false;
        },
        .var_decl => |d| d.init != null and nameRefInClosure(d.init.?, name, in_fn),
        .destructure_decl => |d| nameRefInClosure(d.pattern, name, in_fn) or nameRefInClosure(d.init, name, in_fn),
        .return_stmt => |r| r != null and nameRefInClosure(r.?, name, in_fn),
        .throw_stmt => |t| nameRefInClosure(t, name, in_fn),
        .try_stmt => |t| blk: {
            if (nameRefInClosure(t.block, name, in_fn)) break :blk true;
            if (t.catch_param) |cp| if (nameRefInClosure(cp, name, in_fn)) break :blk true;
            if (t.catch_block) |cb| if (nameRefInClosure(cb, name, in_fn)) break :blk true;
            if (t.finally_block) |fb| if (nameRefInClosure(fb, name, in_fn)) break :blk true;
            break :blk false;
        },
        .labeled_stmt => |l| nameRefInClosure(l.body, name, in_fn),
        .expr_stmt => |e| nameRefInClosure(e, name, in_fn),
        .block => |stmts| blk: {
            for (stmts) |s| if (nameRefInClosure(s, name, in_fn)) break :blk true;
            break :blk false;
        },
        .decl_group => |stmts| blk: {
            for (stmts) |s| if (nameRefInClosure(s, name, in_fn)) break :blk true;
            break :blk false;
        },
        .program => |stmts| blk: {
            for (stmts) |s| if (nameRefInClosure(s, name, in_fn)) break :blk true;
            break :blk false;
        },
        .if_stmt => |i| nameRefInClosure(i.cond, name, in_fn) or nameRefInClosure(i.consequent, name, in_fn) or (i.alternate != null and nameRefInClosure(i.alternate.?, name, in_fn)),
        .while_stmt => |s| nameRefInClosure(s.cond, name, in_fn) or nameRefInClosure(s.body, name, in_fn),
        .do_while_stmt => |s| nameRefInClosure(s.body, name, in_fn) or nameRefInClosure(s.cond, name, in_fn),
        .for_stmt => |f| blk: {
            if (f.init) |ini| if (nameRefInClosure(ini, name, in_fn)) break :blk true;
            if (f.cond) |c| if (nameRefInClosure(c, name, in_fn)) break :blk true;
            if (f.update) |u| if (nameRefInClosure(u, name, in_fn)) break :blk true;
            break :blk nameRefInClosure(f.body, name, in_fn);
        },
        .for_in => |f| blk: {
            if (nameRefInClosure(f.target, name, in_fn)) break :blk true;
            if (f.var_init) |vi| if (nameRefInClosure(vi, name, in_fn)) break :blk true;
            if (nameRefInClosure(f.iterable, name, in_fn)) break :blk true;
            break :blk nameRefInClosure(f.body, name, in_fn);
        },
        .switch_stmt => |sw| blk: {
            if (nameRefInClosure(sw.disc, name, in_fn)) break :blk true;
            for (sw.cases) |c| {
                if (c.@"test") |t| if (nameRefInClosure(t, name, in_fn)) break :blk true;
                for (c.body) |s| if (nameRefInClosure(s, name, in_fn)) break :blk true;
            }
            break :blk false;
        },
        .with_stmt => |w| nameRefInClosure(w.obj, name, in_fn) or nameRefInClosure(w.body, name, in_fn),
        .export_decl => |e| blk: {
            if (e.declaration) |d| if (nameRefInClosure(d, name, in_fn)) break :blk true;
            if (e.default_expr) |d| if (nameRefInClosure(d, name, in_fn)) break :blk true;
            break :blk false;
        },
        .import_call => |ic| nameRefInClosure(ic.specifier, name, in_fn) or (ic.options != null and nameRefInClosure(ic.options.?, name, in_fn)),
    };
}

/// A nested function/arrow captures `name` if its body — or any parameter default
/// or destructuring-pattern parameter (which execute in the function's own scope)
/// — references it. Always searched with `in_fn = true`.
fn fnCaptures(fnode: *const ast.FunctionNode, name: []const u8) bool {
    for (fnode.params) |p| {
        if (p.default) |d| if (nameRefInClosure(d, name, true)) return true;
        if (p.pattern) |pat| if (nameRefInClosure(pat, name, true)) return true;
    }
    return nameRefInClosure(fnode.body, name, true);
}

/// Conservatively, does a statement subtree contain a construct that could leave a
/// `with` block ABRUPTLY (skipping the matching `exit_with`, which would leave the
/// VM's environment pointing at the popped with-record)? `with` bodies that might
/// `yield`/`return`/`throw`/`break`/`continue` are kept on the tree-walker. Stops at
/// nested function boundaries (their control flow is self-contained). Overly strict
/// (a `break` for an inner loop inside the `with` also bails), but always safe.
fn stmtCanEscapeAbruptly(node: *const ast.Node) bool {
    return switch (node.*) {
        .yield_expr, .return_stmt, .throw_stmt, .break_stmt, .continue_stmt => true,
        .function => false,
        .block => |b| blk: {
            for (b) |s| if (stmtCanEscapeAbruptly(s)) break :blk true;
            break :blk false;
        },
        .if_stmt => |i| stmtCanEscapeAbruptly(i.consequent) or (i.alternate != null and stmtCanEscapeAbruptly(i.alternate.?)),
        .while_stmt => |s| stmtCanEscapeAbruptly(s.body),
        .do_while_stmt => |s| stmtCanEscapeAbruptly(s.body),
        .for_stmt => |f| stmtCanEscapeAbruptly(f.body),
        .for_in => |f| stmtCanEscapeAbruptly(f.body),
        .with_stmt => |w| stmtCanEscapeAbruptly(w.body),
        .labeled_stmt => |l| stmtCanEscapeAbruptly(l.body),
        .try_stmt => |t| stmtCanEscapeAbruptly(t.block) or
            (t.catch_block != null and stmtCanEscapeAbruptly(t.catch_block.?)) or
            (t.finally_block != null and stmtCanEscapeAbruptly(t.finally_block.?)),
        .switch_stmt => |sw| blk: {
            for (sw.cases) |c| for (c.body) |s| if (stmtCanEscapeAbruptly(s)) break :blk true;
            break :blk false;
        },
        // An expression statement may embed a `yield` (e.g. `x = yield`).
        else => nodeHasYield(node),
    };
}

fn stmtContainsFuncDecl(node: *const ast.Node) bool {
    return switch (node.*) {
        .func_decl => true,
        .function => false,
        .block => |b| blk: {
            for (b) |s| if (stmtContainsFuncDecl(s)) break :blk true;
            break :blk false;
        },
        .if_stmt => |i| stmtContainsFuncDecl(i.consequent) or (i.alternate != null and stmtContainsFuncDecl(i.alternate.?)),
        .while_stmt => |s| stmtContainsFuncDecl(s.body),
        .do_while_stmt => |s| stmtContainsFuncDecl(s.body),
        .for_stmt => |f| stmtContainsFuncDecl(f.body),
        .for_in => |f| stmtContainsFuncDecl(f.body),
        .with_stmt => |w| stmtContainsFuncDecl(w.body),
        .labeled_stmt => |l| stmtContainsFuncDecl(l.body),
        .try_stmt => |t| stmtContainsFuncDecl(t.block) or
            (t.catch_block != null and stmtContainsFuncDecl(t.catch_block.?)) or
            (t.finally_block != null and stmtContainsFuncDecl(t.finally_block.?)),
        .switch_stmt => |sw| blk: {
            for (sw.cases) |c| for (c.body) |s| if (stmtContainsFuncDecl(s)) break :blk true;
            break :blk false;
        },
        else => false,
    };
}

fn stmtListContainsNestedFuncDecl(stmts: []*Node) bool {
    for (stmts) |s| switch (s.*) {
        .func_decl => {},
        else => if (stmtContainsFuncDecl(s)) return true,
    };
    return false;
}

fn functionHasBlockNestedFuncDecl(fnode: *const ast.FunctionNode) bool {
    if (fnode.is_expr_body) return false;
    return switch (fnode.body.*) {
        .block => |stmts| stmtListContainsNestedFuncDecl(stmts),
        else => stmtContainsFuncDecl(fnode.body),
    };
}

fn stmtHasDisposableDecl(node: *const ast.Node) bool {
    return switch (node.*) {
        .var_decl => |d| d.dispose != 0,
        .decl_group => |stmts| stmtListHasDisposableDecl(stmts),
        else => false,
    };
}

fn stmtListHasDisposableDecl(stmts: []*Node) bool {
    for (stmts) |s| if (stmtHasDisposableDecl(s)) return true;
    return false;
}

fn stmtHasAwaitUsingDecl(node: *const ast.Node) bool {
    return switch (node.*) {
        .var_decl => |d| d.dispose == 2,
        .decl_group => |stmts| stmtListHasAwaitUsingDecl(stmts),
        else => false,
    };
}

fn stmtListHasAwaitUsingDecl(stmts: []*Node) bool {
    for (stmts) |s| if (stmtHasAwaitUsingDecl(s)) return true;
    return false;
}

fn stmtAwaitUsingDeclCount(node: *const ast.Node) usize {
    return switch (node.*) {
        .var_decl => |d| if (d.dispose == 2) 1 else 0,
        .decl_group => |stmts| stmtListAwaitUsingDeclCount(stmts),
        else => 0,
    };
}

fn stmtListAwaitUsingDeclCount(stmts: []*Node) usize {
    var count: usize = 0;
    for (stmts) |s| count += stmtAwaitUsingDeclCount(s);
    return count;
}

fn stmtListCanEscapeAbruptly(stmts: []*Node) bool {
    for (stmts) |s| if (stmtCanEscapeAbruptly(s)) return true;
    return false;
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
    /// >0 while compiling inside a `try` that has a `finally`. A `return`/`break`/
    /// `continue` crossing it is lowered as `abrupt_*` so the finally still runs.
    finally_depth: u32 = 0,
    /// >0 while compiling the body of a `try` whose catch handler is still live on
    /// the VM handler stack (the no-finally case). A call in tail position there
    /// must NOT be a tail call: the handler has to survive the call so a throw from
    /// the callee is caught, but the tail-pop would discard it. Suppresses TCO in
    /// compileTailExpr. (The finally case keeps the handler live via abrupt_return.)
    try_depth: u32 = 0,

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

    const ShadowBind = struct { count: u32 = 0, lexical: bool = false };

    fn shadowAdd(arena: std.mem.Allocator, m: *std.StringHashMapUnmanaged(ShadowBind), name: []const u8, lexical: bool) CompileError!void {
        if (name.len == 0) return;
        const gop = try m.getOrPut(arena, name);
        if (!gop.found_existing) gop.value_ptr.* = .{};
        gop.value_ptr.count += 1;
        if (lexical) gop.value_ptr.lexical = true;
    }

    fn shadowScanPattern(arena: std.mem.Allocator, m: *std.StringHashMapUnmanaged(ShadowBind), pattern: *Node, lexical: bool) CompileError!void {
        switch (pattern.*) {
            .identifier => |name| try shadowAdd(arena, m, name, lexical),
            .obj_pattern => |p| {
                for (p.props) |prop| try shadowScanPattern(arena, m, prop.target, lexical);
                if (p.rest) |r| if (r.* == .identifier) try shadowAdd(arena, m, r.identifier, lexical);
            },
            .arr_pattern => |p| {
                for (p.elems) |elem| if (elem.target) |t| try shadowScanPattern(arena, m, t, lexical);
                if (p.rest) |rest| try shadowScanPattern(arena, m, rest, lexical);
            },
            else => {},
        }
    }

    fn shadowScanStmt(arena: std.mem.Allocator, m: *std.StringHashMapUnmanaged(ShadowBind), node: *Node) CompileError!void {
        switch (node.*) {
            .var_decl => |d| try shadowAdd(arena, m, d.name, d.kind != .@"var"),
            .destructure_decl => |d| try shadowScanPattern(arena, m, d.pattern, d.kind != .@"var"),
            .func_decl => |f| try shadowAdd(arena, m, f.name, false), // nested fn has its own scope; don't descend
            .block => |stmts| for (stmts) |s| try shadowScanStmt(arena, m, s),
            .decl_group => |stmts| for (stmts) |s| try shadowScanStmt(arena, m, s),
            .if_stmt => |s| {
                try shadowScanStmt(arena, m, s.consequent);
                if (s.alternate) |a| try shadowScanStmt(arena, m, a);
            },
            .while_stmt => |s| try shadowScanStmt(arena, m, s.body),
            .do_while_stmt => |s| try shadowScanStmt(arena, m, s.body),
            .for_stmt => |f| {
                if (f.init) |i| try shadowScanStmt(arena, m, i);
                try shadowScanStmt(arena, m, f.body);
            },
            .for_in => |f| {
                if (f.decl_kind) |k| try shadowScanPattern(arena, m, f.target, k != .@"var");
                try shadowScanStmt(arena, m, f.body);
            },
            .switch_stmt => |s| for (s.cases) |c| for (c.body) |st| try shadowScanStmt(arena, m, st),
            .labeled_stmt => |s| try shadowScanStmt(arena, m, s.body),
            .try_stmt => |t| {
                try shadowScanStmt(arena, m, t.block);
                if (t.catch_param) |p| try shadowScanPattern(arena, m, p, true); // catch binding is lexical
                if (t.catch_block) |cb| try shadowScanStmt(arena, m, cb);
                if (t.finally_block) |fb| try shadowScanStmt(arena, m, fb);
            },
            else => {},
        }
    }

    /// The VM's `FnScope` keys locals by name across ALL block scopes (flat,
    /// block-transparent slots), so two DIFFERENT bindings that share a name —
    /// nested `let` shadowing, a catch param shadowing an outer binding, a `let`
    /// shadowing a `var`/param — would collapse onto one slot and clobber each
    /// other (and there is no TDZ). Detect any name introduced by a lexical
    /// binding that also appears as another binding, and keep such a function on
    /// the tree-walker, which scopes blocks correctly. Conservative: also bails
    /// harmless same-name sibling blocks, which only forgoes tiering.
    fn functionHasShadowableLexical(arena: std.mem.Allocator, fnode: *const ast.FunctionNode) CompileError!bool {
        var m: std.StringHashMapUnmanaged(ShadowBind) = .empty;
        for (fnode.params) |p| try shadowAdd(arena, &m, p.name, false);
        if (!fnode.is_expr_body) try shadowScanStmt(arena, &m, fnode.body);
        var it = m.iterator();
        while (it.next()) |e| if (e.value_ptr.lexical and e.value_ptr.count >= 2) return true;
        return false;
    }

    fn tdzDeclarePattern(arena: std.mem.Allocator, declared: *std.StringHashMapUnmanaged(void), pattern: *Node) CompileError!void {
        switch (pattern.*) {
            .identifier => |name| try declared.put(arena, name, {}),
            .obj_pattern => |p| {
                for (p.props) |prop| try tdzDeclarePattern(arena, declared, prop.target);
                if (p.rest) |r| if (r.* == .identifier) try declared.put(arena, r.identifier, {});
            },
            .arr_pattern => |p| {
                for (p.elems) |elem| if (elem.target) |t| try tdzDeclarePattern(arena, declared, t);
                if (p.rest) |rest| try tdzDeclarePattern(arena, declared, rest);
            },
            else => {},
        }
    }

    /// Does `node` reference (as an identifier) any lexical name from `m` that has
    /// not been declared yet? Such a read would hit the Temporal Dead Zone.
    fn tdzRefsPending(node: *Node, m: *const std.StringHashMapUnmanaged(ShadowBind), declared: *const std.StringHashMapUnmanaged(void)) bool {
        var it = m.iterator();
        while (it.next()) |e| {
            if (!e.value_ptr.lexical) continue;
            if (declared.contains(e.key_ptr.*)) continue;
            if (nameRefInClosure(node, e.key_ptr.*, true)) return true;
        }
        return false;
    }

    /// Walk statements in source order, growing `declared` as each lexical binding
    /// is reached, and report a read of a still-undeclared lexical (a TDZ hazard).
    fn tdzScanStmt(arena: std.mem.Allocator, node: *Node, m: *const std.StringHashMapUnmanaged(ShadowBind), declared: *std.StringHashMapUnmanaged(void)) CompileError!bool {
        switch (node.*) {
            .var_decl => |d| {
                if (d.init) |init| if (tdzRefsPending(init, m, declared)) return true;
                if (d.kind != .@"var") try declared.put(arena, d.name, {});
            },
            .destructure_decl => |d| {
                if (tdzRefsPending(d.init, m, declared)) return true;
                if (d.kind != .@"var") try tdzDeclarePattern(arena, declared, d.pattern);
            },
            .expr_stmt => |e| return tdzRefsPending(e, m, declared),
            .return_stmt => |mb| {
                if (mb) |e| return tdzRefsPending(e, m, declared);
            },
            .throw_stmt => |e| return tdzRefsPending(e, m, declared),
            .if_stmt => |s| {
                if (tdzRefsPending(s.cond, m, declared)) return true;
                if (try tdzScanStmt(arena, s.consequent, m, declared)) return true;
                if (s.alternate) |a| if (try tdzScanStmt(arena, a, m, declared)) return true;
            },
            .while_stmt => |s| {
                if (tdzRefsPending(s.cond, m, declared)) return true;
                return tdzScanStmt(arena, s.body, m, declared);
            },
            .do_while_stmt => |s| {
                if (try tdzScanStmt(arena, s.body, m, declared)) return true;
                return tdzRefsPending(s.cond, m, declared);
            },
            .for_stmt => |f| {
                if (f.init) |i| if (try tdzScanStmt(arena, i, m, declared)) return true;
                if (f.cond) |c| if (tdzRefsPending(c, m, declared)) return true;
                if (f.update) |u| if (tdzRefsPending(u, m, declared)) return true;
                return tdzScanStmt(arena, f.body, m, declared);
            },
            .for_in => |f| {
                if (tdzRefsPending(f.iterable, m, declared)) return true;
                if (f.decl_kind) |k| if (k != .@"var") try tdzDeclarePattern(arena, declared, f.target);
                return tdzScanStmt(arena, f.body, m, declared);
            },
            .block => |stmts| for (stmts) |s| {
                if (try tdzScanStmt(arena, s, m, declared)) return true;
            },
            .decl_group => |stmts| for (stmts) |s| {
                if (try tdzScanStmt(arena, s, m, declared)) return true;
            },
            .switch_stmt => |sw| {
                if (tdzRefsPending(sw.disc, m, declared)) return true;
                for (sw.cases) |c| {
                    if (c.@"test") |t| if (tdzRefsPending(t, m, declared)) return true;
                    for (c.body) |st| if (try tdzScanStmt(arena, st, m, declared)) return true;
                }
            },
            .labeled_stmt => |s| return tdzScanStmt(arena, s.body, m, declared),
            .try_stmt => |t| {
                if (try tdzScanStmt(arena, t.block, m, declared)) return true;
                if (t.catch_param) |p| try tdzDeclarePattern(arena, declared, p);
                if (t.catch_block) |cb| if (try tdzScanStmt(arena, cb, m, declared)) return true;
                if (t.finally_block) |fb| if (try tdzScanStmt(arena, fb, m, declared)) return true;
            },
            .func_decl => {}, // hoisted; not a read site here
            else => return tdzRefsPending(node, m, declared), // unknown node: sound fallback
        }
        return false;
    }

    /// The VM has no Temporal Dead Zone: an uninitialized `let`/`const` slot reads
    /// as `undefined` instead of throwing ReferenceError. Detecting a read of a
    /// lexical before its declaration would need a per-load check on the hot path,
    /// so instead keep any function that could hit its TDZ on the tree-walker,
    /// which enforces it. Runs after the shadowing check, so lexical names are
    /// unique here. Conservative (a captured forward reference also bails).
    fn functionHasTdzHazard(arena: std.mem.Allocator, fnode: *const ast.FunctionNode) CompileError!bool {
        if (fnode.is_expr_body) return false;
        var m: std.StringHashMapUnmanaged(ShadowBind) = .empty;
        for (fnode.params) |p| try shadowAdd(arena, &m, p.name, false);
        try shadowScanStmt(arena, &m, fnode.body);
        // With no lexical bindings collected, tdzRefsPending never fires.
        var declared: std.StringHashMapUnmanaged(void) = .empty;
        return tdzScanStmt(arena, fnode.body, &m, &declared);
    }

    pub const PlainFunctionCode = struct {
        chunk: *Chunk,
        local_count: u32,
    };

    pub fn compilePlainFunction(arena: std.mem.Allocator, fnode: *const ast.FunctionNode) CompileError!PlainFunctionCode {
        if (fnode.is_generator or fnode.is_async) return error.Unsupported;
        if (fnode.is_strict and functionHasBlockNestedFuncDecl(fnode)) return error.Unsupported;
        // The flat slot model can't represent a lexical binding shadowing another
        // same-named binding; keep those on the tree-walker (correct block scopes).
        if (try functionHasShadowableLexical(arena, fnode)) return error.Unsupported;
        // The VM has no TDZ; keep functions that could read a lexical before its
        // declaration on the tree-walker, which throws ReferenceError.
        if (try functionHasTdzHazard(arena, fnode)) return error.Unsupported;
        const scope = try arena.create(FnScope);
        scope.* = .{ .parent = null };
        for (fnode.params) |p| {
            if (p.default != null or p.is_rest or p.pattern != null) return error.Unsupported;
            _ = try scope.addLocal(arena, p.name);
        }
        if (!fnode.is_expr_body) try collectLocals(arena, scope, fnode.body);

        const chunk = try arena.create(Chunk);
        chunk.* = Chunk.init(arena);
        var c = Compiler{ .arena = arena, .chunk = chunk, .mode = .function, .scope = scope };
        if (fnode.is_expr_body) {
            try c.compileTailExpr(fnode.body);
        } else {
            try c.compileStmt(fnode.body);
            _ = try chunk.emit(.ret_undef, 0);
        }
        try chunk.finalize();
        return .{ .chunk = chunk, .local_count = scope.count };
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
        try self.emitDefineForce(name);
    }

    fn emitDefineForce(self: *Compiler, name: []const u8) CompileError!void {
        switch (self.resolve(name)) {
            .local => |slot| {
                _ = try self.chunk.emit(.store_local, slot);
                _ = try self.chunk.emit(.pop, 0);
            },
            .upval => |u| {
                _ = try self.chunk.emitAB(.store_upval, u.depth, u.slot);
                _ = try self.chunk.emit(.pop, 0);
            },
            .global => _ = try self.chunk.emitAB(.def_var, try self.chunk.addName(name), 2),
        }
    }

    /// `has_init` marks a `var x = init` (vs a bare `var x;`): only the
    /// initializer form may have its write redirected to a `with` object that
    /// provides `x` (ResolveBinding before PutValue) — a bare declaration never
    /// touches the `with` object.
    fn emitDefineKind(self: *Compiler, name: []const u8, kind: ast.DeclKind, has_init: bool) CompileError!void {
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
                // In env-mode (program / generator / async body) a `let`/`const`
                // binds in the current lexical environment via `def_lex` (tracking
                // const-ness and keeping it distinct from the variable scope's
                // `var`s); a `var` hoists to the variable scope via `def_var`.
                if (kind != .@"var")
                    _ = try self.chunk.emitAB(.def_lex, ni, if (kind == .@"const") 2 else 1)
                else
                    // Only a real `var x = init` (b == 1) may redirect to a `with`
                    // object; a non-program `let`/`const` reaching this branch is a
                    // fresh lexical binding and must never touch the `with` object.
                    _ = try self.chunk.emitAB(.def_var, ni, if (has_init and kind == .@"var") 1 else 0);
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
                try self.emitDefineForce(fnode.name);
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
                // `using x = v;` / `await using x = v;`: keep a copy of the resource
                // to register for DisposeResources at the variable scope's exit.
                if (d.dispose != 0) _ = try self.chunk.emit(.dup, 0);
                try self.emitDefineKind(d.name, d.kind, d.init != null);
                if (d.dispose != 0) _ = try self.chunk.emit(.register_disposable, if (d.dispose == 2) 1 else 0);
            },
            .destructure_decl => |d| {
                if (self.scope != null) return error.Unsupported;
                if (nodeHasYield(d.pattern)) {
                    if (d.kind != .@"var") return error.Unsupported;
                    try self.emitPatternVarDecls(d.pattern);
                    try self.compileDestructuringAssign(d.pattern, d.init);
                    _ = try self.chunk.emit(.pop, 0);
                    return;
                }
                try self.compileExpr(d.init);
                const pi = try self.chunk.addPattern(d.pattern);
                const mode: u32 = switch (d.kind) {
                    .@"var" => 0,
                    .let => 1,
                    .@"const" => 2,
                };
                _ = try self.chunk.emitAB(.bind_pattern, pi, mode);
            },
            .func_decl => |fnode| {
                const fi = try self.compileFunction(fnode, false);
                _ = try self.chunk.emit(.make_closure, fi);
                try self.emitDefineForce(fnode.name);
            },
            .return_stmt => |maybe| {
                // A `return` lexically inside a `try`/`catch`/`finally` must run
                // the enclosing finally block(s) first: `abrupt_return` unwinds
                // the handler stack, runs each finally carrying a return
                // completion, and returns once they finish. This applies to plain
                // functions too (a return in a `finally`-guarded try is not a tail
                // call), not only generators — a bare `ret` would skip the finally.
                if (self.finally_depth > 0) {
                    if (maybe) |e| {
                        try self.compileExpr(e);
                        if (self.in_generator and self.in_async) _ = try self.chunk.emit(.await_op, 0);
                    } else {
                        _ = try self.chunk.emit(.load_undefined, 0);
                    }
                    _ = try self.chunk.emit(.abrupt_return, 0);
                } else if (maybe) |e| {
                    if (!self.in_generator and !self.in_async) {
                        try self.compileTailExpr(e);
                    } else {
                        try self.compileExpr(e);
                        if (self.in_generator and self.in_async) _ = try self.chunk.emit(.await_op, 0);
                        _ = try self.chunk.emit(.ret, 0);
                    }
                } else {
                    _ = try self.chunk.emit(.ret_undef, 0);
                }
            },
            .expr_stmt => |e| {
                try self.compileExpr(e);
                _ = try self.chunk.emit(if (self.mode == .program) .set_acc else .pop, 0);
            },
            .block => |stmts| {
                const disposable_scope = self.scope == null and stmtListHasDisposableDecl(stmts);
                if (disposable_scope) {
                    // This first VM block-disposal slice handles normal completion.
                    // Abrupt exits stay on the tree-walker until they can unwind
                    // block resources like `finally`.
                    if (stmtListCanEscapeAbruptly(stmts)) return error.Unsupported;
                    _ = try self.chunk.emit(.enter_block, 0);
                }
                try self.compileStmtList(stmts);
                if (disposable_scope) {
                    const await_using_count = if (self.in_async) stmtListAwaitUsingDeclCount(stmts) else 0;
                    if (await_using_count == 0) {
                        _ = try self.chunk.emit(.dispose_scope, 0);
                    } else {
                        var i: usize = 0;
                        while (i < await_using_count) : (i += 1) {
                            _ = try self.chunk.emit(.dispose_scope, 1);
                            _ = try self.chunk.emit(.await_op, 0);
                            _ = try self.chunk.emit(.pop, 0);
                        }
                        _ = try self.chunk.emit(.dispose_scope, 0);
                    }
                    _ = try self.chunk.emit(.exit_block, 0);
                }
            },
            .decl_group => |stmts| try self.compileStmtList(stmts),
            .if_stmt => |s| try self.compileIf(s.cond, s.consequent, s.alternate),
            .while_stmt => |s| try self.compileWhile(s.cond, s.body),
            .do_while_stmt => |s| try self.compileDoWhile(s.body, s.cond),
            .for_stmt => |f| try self.compileFor(f.init, f.cond, f.update, f.body),
            .break_stmt => |label| {
                const loop = self.currentBreakTarget(label) orelse return error.Unsupported;
                // Across a finally, the finally must run before the jump:
                // `abrupt_break` unwinds the handler stack running each enclosing
                // finally, then jumps to the (patched) break target.
                const j = try self.chunk.emit(if (self.finally_depth > loop.finally_depth) .abrupt_break else .jump, 0);
                try loop.breaks.append(self.arena, j);
            },
            .continue_stmt => |label| {
                if (label != null) return error.Unsupported; // labeled continue → tree-walk
                const loop = self.currentContinueLoop() orelse return error.Unsupported;
                const j = try self.chunk.emit(if (self.finally_depth > loop.finally_depth) .abrupt_continue else .jump, 0);
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
                if (f.dispose != 0) return error.Unsupported; // `for (using x of …)` disposal → tree-walk
                try self.compileForOf(f.decl_kind, f.target, f.var_init, f.iterable, f.body, !f.is_of, f.is_await);
            },
            .try_stmt => |t| try self.compileTry(t),
            .labeled_stmt => |l| {
                const target = try self.pushLabel(l.label);
                try self.compileStmt(l.body);
                for (target.breaks.items) |j| self.chunk.patchToHere(j);
                self.popLoop();
            },
            .with_stmt => |w| {
                // `with (obj) body`: push an object Environment Record, run the body,
                // pop it. Only safe when the body can't leave abruptly (which would
                // skip exit_with) — otherwise keep the whole generator on the
                // tree-walker. Annex B block function declarations inside `with`
                // also need tree-walker source-order legacy binding updates.
                // The object expression itself may `yield` (evaluated before the push).
                if (stmtCanEscapeAbruptly(w.body) or stmtContainsFuncDecl(w.body)) return error.Unsupported;
                try self.compileExpr(w.obj);
                _ = try self.chunk.emit(.enter_with, 0);
                try self.compileStmt(w.body);
                _ = try self.chunk.emit(.exit_with, 0);
            },
            else => return error.Unsupported,
        }
    }

    /// `try { B } [catch (e) { C }] [finally { F }]` for the generator VM. A
    /// handler records the catch and/or finally targets; the VM unwinds to it
    /// on a throw. Only an identifier/elided catch binding is lowered.
    fn compileTry(self: *Compiler, t: *const ast.TryNode) CompileError!void {
        if (t.catch_param) |p| {
            if (p.* != .identifier) return error.Unsupported; // destructuring catch → unsupported
        }
        const none = std.math.maxInt(u32);

        if (t.finally_block == null) {
            // try/catch (no finally) — handler with a catch arm only.
            const catch_block = t.catch_block orelse return error.Unsupported;
            const ph = try self.chunk.emitAB(.push_handler, none, none);
            self.try_depth += 1;
            try self.compileStmt(t.block);
            self.try_depth -= 1;
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
        // A `let`/`const` loop variable captured by a body closure needs a fresh
        // per-iteration binding (CreatePerIterationEnvironment). The frame-slot
        // lowering below reuses one slot, so bail such loops to the tree-walker,
        // which binds per iteration. Uncaptured lexical (and all `var`) loops keep
        // the fast VM path.
        if (init_node) |ini| if (forLoopCapturesLexical(ini, body)) return error.Unsupported;
        const disposable_scope = self.scope == null and init_node != null and stmtHasDisposableDecl(init_node.?);
        if (disposable_scope) {
            if (stmtCanEscapeAbruptly(body)) return error.Unsupported;
            _ = try self.chunk.emit(.enter_block, 0);
        }
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
        if (disposable_scope) {
            _ = try self.chunk.emit(.dispose_scope, 0);
            if (self.in_async and init_node != null and stmtHasAwaitUsingDecl(init_node.?)) {
                _ = try self.chunk.emit(.load_undefined, 0);
                _ = try self.chunk.emit(.await_op, 0);
                _ = try self.chunk.emit(.pop, 0);
            }
            _ = try self.chunk.emit(.exit_block, 0);
        }
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
        // An ASSIGNMENT target that embeds a `yield`/`await` (`for ([ x = yield ]
        // of …)`) must be lowered to bytecode so the suspend point is real — route
        // it through the yield-aware destructuring path instead of `bind_pattern`
        // (which defers to the tree-walker and can't suspend). The loop value is on
        // the stack; move it into a temp first. Patterns WITHOUT yield/await keep
        // using `bind_pattern`, which handles object-rest / fn-name NamedEvaluation /
        // iterator-close that the assignment lowering bails on.
        if (decl_kind == null and (target.* == .arr_pattern or target.* == .obj_pattern) and nodeHasYield(target)) {
            const src = try self.freshTemp();
            try self.emitDefine(src); // consume the loop value from the stack
            try self.compileAssignPattern(target, src);
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

    fn compileForOf(self: *Compiler, decl_kind: ?ast.DeclKind, target: *Node, var_init: ?*Node, iterable: *Node, body: *Node, keys_first: bool, await_each: bool) CompileError!void {
        // A `let`/`const` loop binding captured by a body closure needs a fresh
        // per-iteration binding (ForIn/OfBodyEvaluation, like `compileFor`); the
        // single loop-target slot bound below is reused across iterations, so bail
        // to the tree-walker (which binds per iteration). Only when a fallback
        // exists — a generator body can't tree-walk, so its (rare) captured for-of
        // keeps the pre-existing behavior rather than failing to compile at all.
        if (!self.in_generator) if (decl_kind) |k| if (k != .@"var") {
            if (patternNameCaptured(target, body)) return error.Unsupported;
        };
        const it_name = try self.freshTemp();
        const r_name = try self.freshTemp();

        if (var_init) |ini| {
            try self.compileExpr(ini);
            try self.compileLoopBind(decl_kind, target);
        }
        try self.compileExpr(iterable);
        if (keys_first) _ = try self.chunk.emit(.enum_keys, 0); // for-in: iterate the key array
        // for-await uses the async-iterator protocol (Symbol.asyncIterator, else
        // a wrapped sync iterator) and awaits each `next()` result.
        _ = try self.chunk.emit(if (await_each) .async_iter_of else .iter_of, 0);
        try self.emitDefine(it_name);
        // GetIterator reads the iterator's `next` method exactly ONCE (it becomes
        // the Iterator Record's [[NextMethod]]); cache it so a `next` accessor is
        // not re-read each iteration.
        const next_name = try self.freshTemp();
        try self.emitLoad(it_name);
        _ = try self.chunk.emit(.get_prop, try self.chunk.addName("next"));
        try self.emitDefine(next_name);

        const done_name = try self.freshTemp();
        // This flag tracks whether an abrupt completion must close the iterator.
        // It becomes false only after a successful `{ done:false }` result; a
        // throw from `next()`/`await next()` itself does not perform IteratorClose.
        _ = try self.chunk.emit(.load_true, 0);
        try self.emitDefine(done_name);

        const none = std.math.maxInt(u32);
        const ph = try self.chunk.emitAB(.push_handler, none, none);
        const loop = try self.pushLoop();
        const top = self.chunk.here();
        // r = it.next()  (for-await: r = await it.next()) — the cached `next`,
        // invoked with this=it via call_with_this (no second property lookup).
        try self.emitLoad(next_name);
        try self.emitLoad(it_name);
        _ = try self.chunk.emitAB(.call_with_this, 0, 0);
        if (await_each) _ = try self.chunk.emit(.await_op, 0); // await the next() result
        if (!keys_first) _ = try self.chunk.emit(.assert_iter_result, 0); // IteratorNext: result must be an Object
        try self.emitDefine(r_name);
        // if (r.done) break  — `not` then jump_if_false exits exactly when done.
        try self.emitLoad(r_name);
        _ = try self.chunk.emit(.get_prop, try self.chunk.addName("done"));
        _ = try self.chunk.emit(.not, 0);
        const to_end = try self.chunk.emit(.jump_if_false, 0);
        _ = try self.chunk.emit(.load_false, 0);
        try self.emitStore(done_name);
        _ = try self.chunk.emit(.pop, 0);
        // bind r.value to the loop target (identifier or destructuring pattern)
        try self.emitLoad(r_name);
        _ = try self.chunk.emit(.get_prop, try self.chunk.addName("value"));
        try self.compileLoopBind(decl_kind, target);
        try self.compileStmt(body);
        const continue_target = self.chunk.here();
        _ = try self.chunk.emit(.load_true, 0);
        try self.emitStore(done_name);
        _ = try self.chunk.emit(.pop, 0);
        _ = try self.chunk.emit(.jump, @intCast(top));
        // `continue` re-enters the loop at the top (next .next()) without
        // closing; clear the active-close flag first.
        for (loop.continues.items) |j| self.chunk.patchTo(j, continue_target);
        // Normal completion (the iterator reported `done`): it is already
        // exhausted, so it is NOT closed — control just exits the loop.
        self.chunk.patchToHere(to_end);
        _ = try self.chunk.emit(.load_true, 0);
        try self.emitStore(done_name);
        _ = try self.chunk.emit(.pop, 0);
        // `break` is an abrupt completion, so it must run IteratorClose (which
        // throws if `return` is present-but-non-callable or returns a non-object).
        // The normal-done path above jumps over this close block.
        if (loop.breaks.items.len > 0) {
            const skip_close = try self.chunk.emit(.jump, 0);
            for (loop.breaks.items) |j| self.chunk.patchToHere(j);
            try self.emitLoad(it_name);
            if (await_each) try self.emitAsyncIteratorClose(false) else _ = try self.chunk.emit(.iter_close, 0);
            self.chunk.patchToHere(skip_close);
        }
        self.popLoop();
        _ = try self.chunk.emit(.pop_handler, 0);

        const after_finally = try self.chunk.emit(.jump, 0);
        self.chunk.code.items[ph].b = @intCast(self.chunk.here());
        try self.emitLoad(done_name);
        _ = try self.chunk.emit(.not, 0);
        const skip_close = try self.chunk.emit(.jump_if_false, 0);
        try self.emitLoad(it_name);
        if (await_each) try self.emitAsyncIteratorClose(true) else _ = try self.chunk.emit(.iter_close_completion, 0);
        self.chunk.patchToHere(skip_close);
        _ = try self.chunk.emit(.end_finally, 0);
        self.chunk.patchToHere(after_finally);
    }

    fn emitAsyncIteratorClose(self: *Compiler, completion_aware: bool) CompileError!void {
        _ = try self.chunk.emit(if (completion_aware) .async_iter_close_completion else .async_iter_close, 0);
        const absent = try self.chunk.emit(.jump_if_false, 0);
        _ = try self.chunk.emit(.await_op, 0);
        _ = try self.chunk.emit(.assert_iter_result, 0);
        _ = try self.chunk.emit(.pop, 0);
        const after = try self.chunk.emit(.jump, 0);
        self.chunk.patchToHere(absent);
        _ = try self.chunk.emit(.pop, 0);
        self.chunk.patchToHere(after);
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

    fn emitPatternVarDecls(self: *Compiler, pattern: *Node) CompileError!void {
        switch (pattern.*) {
            .identifier => |name| {
                _ = try self.chunk.emit(.load_undefined, 0);
                try self.emitDefineKind(name, .@"var", false);
            },
            .arr_pattern => |p| {
                for (p.elems) |elem| if (elem.target) |target| try self.emitPatternVarDecls(target);
                if (p.rest) |rest| try self.emitPatternVarDecls(rest);
            },
            .obj_pattern => |p| {
                for (p.props) |prop| try self.emitPatternVarDecls(prop.target);
                if (p.rest) |rest| try self.emitPatternVarDecls(rest);
            },
            else => {},
        }
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
                _ = try self.chunk.emit(.assert_iter_result, 0);
                _ = try self.chunk.emit(.pop, 0);
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
            _ = try self.chunk.emit(.assert_iter_result, 0);
            _ = try self.chunk.emit(.pop, 0);
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
    fn compileObjectAssign(self: *Compiler, props: []const ast.ObjPatProp, rest: ?*ast.Node, src: []const u8) CompileError!void {
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

    fn compileTailExpr(self: *Compiler, node: *Node) CompileError!void {
        // A live catch handler (still on the VM handler stack) must survive the
        // call, so nothing here is in tail position: evaluate normally and return
        // rather than emitting a tail call that would discard the handler and let a
        // throw from the callee escape the enclosing catch. (The finally case is
        // already routed through abrupt_return by return_stmt.)
        if (self.try_depth > 0) {
            try self.compileExpr(node);
            _ = try self.chunk.emit(.ret, 0);
            return;
        }
        switch (node.*) {
            .call => |c| {
                try self.compileTailCall(c);
            },
            .sequence => |s| {
                try self.compileExpr(s.first);
                _ = try self.chunk.emit(.pop, 0);
                try self.compileTailExpr(s.second);
            },
            .logical => |l| {
                try self.compileExpr(l.left);
                switch (l.op) {
                    .@"and" => {
                        const short = try self.chunk.emit(.jump_if_false_peek, 0);
                        _ = try self.chunk.emit(.pop, 0);
                        try self.compileTailExpr(l.right);
                        self.chunk.patchToHere(short);
                        _ = try self.chunk.emit(.ret, 0);
                    },
                    .@"or" => {
                        const short = try self.chunk.emit(.jump_if_true_peek, 0);
                        _ = try self.chunk.emit(.pop, 0);
                        try self.compileTailExpr(l.right);
                        self.chunk.patchToHere(short);
                        _ = try self.chunk.emit(.ret, 0);
                    },
                    .nullish => {
                        const short = try self.chunk.emit(.jump_if_not_nullish_peek, 0);
                        _ = try self.chunk.emit(.pop, 0);
                        try self.compileTailExpr(l.right);
                        self.chunk.patchToHere(short);
                        _ = try self.chunk.emit(.ret, 0);
                    },
                }
            },
            .conditional => |c| {
                try self.compileExpr(c.cond);
                const to_else = try self.chunk.emit(.jump_if_false, 0);
                try self.compileTailExpr(c.consequent);
                self.chunk.patchToHere(to_else);
                try self.compileTailExpr(c.alternate);
            },
            .tagged_template => |t| try self.compileTailTaggedTemplate(t.tag, t.cooked, t.raw, t.exprs),
            else => {
                try self.compileExpr(node);
                _ = try self.chunk.emit(.ret, 0);
            },
        }
    }

    fn compileTailCall(self: *Compiler, c: anytype) CompileError!void {
        const spread = hasSpread(c.args);
        if (spread) return error.Unsupported;
        if (c.callee.* == .member and c.callee.member.computed == null) {
            // Fetch the method (RequireObjectCoercible on the receiver) BEFORE the
            // args, per spec order, then tail-call with this = recv.
            const m = c.callee.member;
            const ni = try self.chunk.addName(m.property);
            const recv = try self.freshTemp();
            try self.compileExpr(m.object);
            try self.emitDefine(recv);
            try self.emitLoad(recv);
            _ = try self.chunk.emit(.get_prop, ni);
            try self.emitLoad(recv);
            for (c.args) |arg| try self.compileExpr(arg);
            _ = try self.chunk.emit(.tail_call_with_this, @intCast(c.args.len));
            return;
        }
        if (c.callee.* == .member) {
            const m = c.callee.member;
            if (m.optional or m.computed == null) return error.Unsupported;
            const recv = try self.freshTemp();
            try self.compileExpr(m.object);
            try self.emitDefine(recv);
            try self.emitLoad(recv);
            try self.compileExpr(m.computed.?);
            _ = try self.chunk.emit(.get_index, 0);
            try self.emitLoad(recv);
            for (c.args) |arg| try self.compileExpr(arg);
            _ = try self.chunk.emit(.tail_call_with_this, @intCast(c.args.len));
            return;
        }
        if (c.callee.* == .super_member) return error.Unsupported;
        const is_eval = c.callee.* == .identifier and std.mem.eql(u8, c.callee.identifier, "eval");
        try self.compileExpr(c.callee);
        for (c.args) |arg| try self.compileExpr(arg);
        _ = try self.chunk.emit(if (is_eval) .tail_call_eval else .tail_call, @intCast(c.args.len));
    }

    fn compileTailTaggedTemplate(self: *Compiler, tag: *Node, cooked: []?[]const u8, raw: [][]const u8, exprs: []*Node) CompileError!void {
        if (tag.* == .member) return error.Unsupported;
        try self.compileExpr(tag);
        try self.compileTemplateStrings(cooked, raw);
        for (exprs) |e| try self.compileExpr(e);
        _ = try self.chunk.emit(.tail_call, @intCast(exprs.len + 1));
    }

    fn compileTemplateStrings(self: *Compiler, cooked: []?[]const u8, raw: [][]const u8) CompileError!void {
        _ = try self.chunk.emit(.new_array, 0);
        for (cooked) |part| {
            const ci = try self.chunk.addConst(if (part) |s| Value.str(s) else Value.undef());
            _ = try self.chunk.emit(.load_const, ci);
            _ = try self.chunk.emit(.array_append, 0);
        }
        _ = try self.chunk.emit(.dup, 0);
        _ = try self.chunk.emit(.new_array, 0);
        for (raw) |part| {
            const ci = try self.chunk.addConst(Value.str(part));
            _ = try self.chunk.emit(.load_const, ci);
            _ = try self.chunk.emit(.array_append, 0);
        }
        _ = try self.chunk.emit(.set_prop, try self.chunk.addName("raw"));
        _ = try self.chunk.emit(.pop, 0);
    }

    fn compileExpr(self: *Compiler, node: *Node) CompileError!void {
        switch (node.*) {
            .number => |n| {
                const ci = try self.chunk.addConst(Value.num(n));
                _ = try self.chunk.emit(.load_const, ci);
            },
            .bigint_lit => |b| {
                const text = b.text orelse try std.fmt.allocPrint(self.arena, "{d}", .{b.value});
                _ = try self.chunk.emit(.load_bigint, try self.chunk.addName(text));
            },
            .string => |s| {
                const ci = try self.chunk.addConst(Value.str(s));
                _ = try self.chunk.emit(.load_const, ci);
            },
            .boolean => |b| _ = try self.chunk.emit(if (b) .load_true else .load_false, 0),
            .null_lit => _ = try self.chunk.emit(.load_null, 0),
            .undefined_lit => _ = try self.chunk.emit(.load_undefined, 0),
            .regex_literal => |r| {
                // A fresh RegExp per evaluation (so `yield /abc/i` works); pattern
                // and flags are stored as names and rebuilt at runtime.
                _ = try self.chunk.emitAB(.make_regex, try self.chunk.addName(r.pattern), try self.chunk.addName(r.flags));
            },
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
                if (b.op == .in_op and b.left.* == .identifier and value_mod.isPrivateKey(b.left.identifier)) {
                    try self.compileExpr(b.right);
                    _ = try self.chunk.emit(.private_in, try self.chunk.addName(b.left.identifier));
                    return;
                }
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
            // Logical assignment on a member target must resolve the reference
            // once; the tree-walker handles that, so defer to it.
            .logical_assign => return error.Unsupported,
            .op_assign => |oa| switch (oa.target.*) {
                // Identifier target: load the old value, apply the op, store back.
                // (No `with` here — a function using `with` already falls back to
                // the tree-walker, which resolves the reference once.)
                .identifier => |name| {
                    const op: bc.Op = switch (oa.op) {
                        .add => .add,
                        .sub => .sub,
                        .mul => .mul,
                        .div => .div,
                        .mod => .mod,
                        .pow => .pow,
                        .bit_and => .bit_and,
                        .bit_or => .bit_or,
                        .bit_xor => .bit_xor,
                        .shl => .shl,
                        .shr => .shr,
                        .ushr => .ushr,
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
            .class_expr => |c| {
                // Generator bodies may suspend while evaluating computed class
                // element names. Lower those key expressions in source order, then
                // let the VM delegate class construction to the shared interpreter.
                if (c.superclass != null) return error.Unsupported;
                const computed_count = try self.compileClassComputedKeys(c.members);
                _ = try self.chunk.emitAB(.eval_class, try self.chunk.addClass(node), computed_count);
            },
            .call => |c| {
                const spread = hasSpread(c.args);
                if (spread and !self.in_generator) return error.Unsupported; // non-generator spread → tree-walk
                if (c.callee.* == .super_member and !spread) {
                    // `super.m(args)`: resolve `m` on the super base, then invoke it
                    // with `this` = the current `this` (NOT the super base) via
                    // call_with_this. (`yield super.m()` in a generator method.)
                    const sm = c.callee.super_member;
                    if (sm.computed) |ce| {
                        try self.compileExpr(ce);
                        _ = try self.chunk.emit(.super_get_index, 0);
                    } else {
                        _ = try self.chunk.emit(.super_get, try self.chunk.addName(sm.property));
                    }
                    _ = try self.chunk.emit(.load_this, 0);
                    for (c.args) |arg| try self.compileExpr(arg);
                    _ = try self.chunk.emit(.call_with_this, @intCast(c.args.len));
                } else if (c.callee.* == .member and c.callee.member.computed == null) {
                    // `recv.name(args)`: bind `this = recv` at the call site.
                    const m = c.callee.member;
                    const ni = try self.chunk.addName(m.property);
                    if (spread) {
                        try self.compileExpr(m.object);
                        try self.compileArgsArray(c.args);
                        _ = try self.chunk.emit(.call_method_spread, ni);
                    } else {
                        // Fetch the method (RequireObjectCoercible on the receiver +
                        // any getter) BEFORE the arguments, per spec order, then call
                        // with this = recv. Mirrors the computed-member path so a
                        // nullish receiver throws before an argument is evaluated.
                        const recv = try self.freshTemp();
                        try self.compileExpr(m.object);
                        try self.emitDefine(recv);
                        try self.emitLoad(recv);
                        _ = try self.chunk.emit(.get_prop, ni);
                        try self.emitLoad(recv);
                        for (c.args) |arg| try self.compileExpr(arg);
                        _ = try self.chunk.emit(.call_with_this, @intCast(c.args.len));
                    }
                } else if (c.callee.* == .member) {
                    if (spread) return error.Unsupported;
                    const m = c.callee.member;
                    if (m.optional or m.computed == null) return error.Unsupported;
                    const recv = try self.freshTemp();
                    try self.compileExpr(m.object);
                    try self.emitDefine(recv);
                    try self.emitLoad(recv);
                    try self.compileExpr(m.computed.?);
                    _ = try self.chunk.emit(.get_index, 0);
                    try self.emitLoad(recv);
                    for (c.args) |arg| try self.compileExpr(arg);
                    _ = try self.chunk.emit(.call_with_this, @intCast(c.args.len));
                } else {
                    // A direct `eval(...)` inside a slot-based function must see the
                    // function's locals (and correct `this`/private names), which
                    // live in the environment only on the tree-walker — so bail to
                    // it. Generators/top level (scope == null, env-mode) are fine.
                    const is_eval = c.callee.* == .identifier and std.mem.eql(u8, c.callee.identifier, "eval");
                    if (self.scope != null and is_eval)
                        return error.Unsupported;
                    try self.compileExpr(c.callee);
                    if (spread) {
                        try self.compileArgsArray(c.args);
                        _ = try self.chunk.emit(.call_spread, 0);
                    } else {
                        for (c.args) |arg| try self.compileExpr(arg);
                        // A bare `eval(...)` in an env-mode body is a candidate direct
                        // eval (runs in this scope if the callee is the eval intrinsic).
                        _ = try self.chunk.emit(if (is_eval) .call_eval else .call, @intCast(c.args.len));
                    }
                }
            },
            .this_expr => _ = try self.chunk.emit(.load_this, 0),
            .new_target_expr => _ = try self.chunk.emit(.load_new_target, 0),
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
            .super_member => |m| {
                // `super.x` / `super[e]` read: GetSuperBase + [[Get]] with `this`
                // receiver, via the super_get opcodes (home_object is live in the
                // generator frame). The call form is handled in the `.call` arm.
                if (m.computed) |ce| {
                    try self.compileExpr(ce);
                    _ = try self.chunk.emit(.super_get_index, 0);
                } else {
                    _ = try self.chunk.emit(.super_get, try self.chunk.addName(m.property));
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
                    // Object spread lowers everywhere (`init_spread` is the same
                    // CopyDataProperties helper the tree-walker uses), so a nested
                    // non-generator function that spreads (`*g(){ yield {...(()=>({...x}))()} }`)
                    // no longer bails the whole generator. Accessor (get/set) props
                    // are still lowered only inside a generator (where lowering is
                    // mandatory); plain code keeps the tree-walker's fuller path.
                    if (p.is_spread or p.accessor != .none) {
                        if (p.is_spread) {
                            try self.compileExpr(p.value); // CopyDataProperties source
                            _ = try self.chunk.emit(.init_spread, 0);
                            continue;
                        }
                        if (!self.in_generator) return error.Unsupported;
                        // Getter/setter: push key, push the function, install.
                        if (p.key_expr) |ke| {
                            try self.compileExpr(ke);
                        } else {
                            const ci = try self.chunk.addConst(Value.str(p.key));
                            _ = try self.chunk.emit(.load_const, ci);
                        }
                        const gi = try self.compileFunction(p.value.function, false);
                        _ = try self.chunk.emit(.make_closure, gi);
                        _ = try self.chunk.emit(if (p.accessor == .get) .init_getter else .init_setter, 0);
                        continue;
                    }
                    if (p.key_expr) |ke| {
                        // Computed key: evaluate the key and run ToPropertyKey (its
                        // toString/valueOf) BEFORE the value, per the spec's
                        // PropertyDefinitionEvaluation order.
                        try self.compileExpr(ke);
                        _ = try self.chunk.emit(.to_property_key, 0);
                        try self.compileExpr(p.value);
                        _ = try self.chunk.emit(.init_prop_computed, 0);
                    } else {
                        try self.compileExpr(p.value);
                        if (p.proto_setter) {
                            _ = try self.chunk.emit(.init_proto, 0); // `__proto__: v` colon form
                        } else {
                            _ = try self.chunk.emit(.init_prop, try self.chunk.addName(p.key));
                        }
                    }
                }
            },
            .array_lit => |elems| {
                _ = try self.chunk.emit(.new_array, 0);
                for (elems) |e| {
                    if (e.* == .elision) {
                        _ = try self.chunk.emit(.array_append_hole, 0); // `[,]` — a hole
                        continue;
                    }
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
            .import_call => |ic| {
                try self.compileExpr(ic.specifier);
                if (ic.options) |options|
                    try self.compileExpr(options)
                else
                    _ = try self.chunk.emit(.load_undefined, 0);
                _ = try self.chunk.emit(.import_call, try self.chunk.addName(ic.phase));
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
        // `++`/`--` are ToNumeric(old) ± 1, not `old + 1`: a raw `.add` with a
        // Number 1 would string-concatenate a string operand and TypeError a
        // BigInt. The inc/dec opcodes ToNumeric first and add 1 of the operand's
        // own numeric type (Number or BigInt).
        const step: bc.Op = if (inc) .inc else .dec;
        if (prefix) {
            try self.emitLoad(name);
            _ = try self.chunk.emit(step, 0);
            try self.emitStore(name); // leaves the new value
        } else {
            try self.emitLoad(name);
            _ = try self.chunk.emit(.to_numeric, 0); // postfix result is the numeric old value
            _ = try self.chunk.emit(.dup, 0); // keep the numeric old value
            _ = try self.chunk.emit(step, 0);
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
        const next_m = try self.freshTemp(); // the iterator's captured `next` method
        const m = try self.freshTemp(); // a GetMethod(it, throw|return) result
        const ch = self.chunk;
        const done_n = try ch.addName("done");
        const value_n = try ch.addName("value");

        // it = GetIterator(arg); recv_v = undefined; recv_k = 0 (start with `next`).
        try self.compileExpr(arg);
        _ = try ch.emit(if (async_d) .async_iter_of else .iter_of, 0);
        try self.emitDefine(it);
        try self.emitLoad(it);
        _ = try ch.emit(.get_prop, try ch.addName("next"));
        try self.emitDefine(next_m);
        _ = try ch.emit(.load_undefined, 0);
        try self.emitDefine(recv_v);
        _ = try ch.emit(.load_const, try ch.addConst(Value.num(0)));
        try self.emitDefine(recv_k);

        const top = ch.here();
        // if (recv_k == 0) fall through to the `next` branch, else jump to throw/return.
        try self.emitLoad(recv_k);
        _ = try ch.emit(.load_const, try ch.addConst(Value.num(0)));
        _ = try ch.emit(.eq_strict, 0);
        const to_nonnext = try ch.emit(.jump_if_false, 0);

        // --- next branch: r = next.call(it, recv_v) ---
        try self.emitLoad(next_m);
        try self.emitLoad(it);
        try self.emitLoad(recv_v);
        _ = try ch.emitAB(.call_with_this, 1, 0);
        if (async_d) _ = try ch.emit(.await_op, 0);
        try self.emitDefine(r);
        const to_join_a = try ch.emit(.jump, 0); // -> normal/throw join

        // --- recv_k == 1 ? throw branch : return branch ---
        ch.patchToHere(to_nonnext);
        try self.emitLoad(recv_k);
        _ = try ch.emit(.load_const, try ch.addConst(Value.num(1)));
        _ = try ch.emit(.eq_strict, 0);
        const to_return = try ch.emit(.jump_if_false, 0);

        // --- throw branch ---
        // m = GetMethod(it, "throw")
        try self.emitLoad(it);
        _ = try ch.emit(.get_prop, try ch.addName("throw"));
        try self.emitDefine(m);
        const to_has_throw = try self.emitJumpIfNotStrictlyNullish(m);
        // No `throw` method: IteratorClose(it) (call `return` if present, ignoring
        // its result) then throw a TypeError. Closing first lets the inner
        // iterator release resources, matching the spec.
        try self.emitLoad(it);
        _ = try ch.emit(.get_prop, try ch.addName("return"));
        try self.emitDefine(m);
        const to_skip_close = try self.emitJumpIfNotStrictlyNullish(m);
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
        _ = try ch.emit(.load_const, try ch.addConst(Value.str("The iterator does not provide a 'throw' method")));
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
        const to_has_return = try self.emitJumpIfNotStrictlyNullish(m);
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
        // to the consumer untouched. An *async* generator yields IteratorValue
        // directly here; AsyncFromSyncIteratorContinuation already unwraps sync
        // iterator values, while a real async iterator's yielded promise value
        // must not be unwrapped.
        ch.patchToHere(to_yield);
        ch.patchToHere(to_return_yield);
        if (async_d) {
            try self.emitLoad(r);
            _ = try ch.emit(.get_prop, value_n);
        } else {
            try self.emitLoad(r); // yield the inner result object as-is
        }
        _ = try ch.emit(.gen_yield_star, 0); // resume pushes [value, kind] (kind on top)
        try self.emitStore(recv_k);
        _ = try ch.emit(.pop, 0);
        try self.emitStore(recv_v);
        _ = try ch.emit(.pop, 0);
        if (async_d) {
            // AsyncGeneratorYield resumes through
            // AsyncGeneratorUnwrapYieldResumption, which awaits the completion
            // value before yield* forwards it to next/throw/return handling.
            try self.emitLoad(recv_v);
            _ = try ch.emit(.await_op, 0);
            try self.emitStore(recv_v);
            _ = try ch.emit(.pop, 0);
        }
        _ = try ch.emit(.jump, @intCast(top));

        // yield* evaluates to the final `r.value` when the inner iterator is done.
        ch.patchToHere(to_end);
        try self.emitLoad(r);
        _ = try ch.emit(.get_prop, value_n);
    }

    fn emitJumpIfNotStrictlyNullish(self: *Compiler, name: []const u8) CompileError!usize {
        const ch = self.chunk;

        try self.emitLoad(name);
        _ = try ch.emit(.load_undefined, 0);
        _ = try ch.emit(.eq_strict, 0);
        const to_check_null = try ch.emit(.jump_if_false, 0);
        const to_absent = try ch.emit(.jump, 0);

        ch.patchToHere(to_check_null);
        try self.emitLoad(name);
        _ = try ch.emit(.load_null, 0);
        _ = try ch.emit(.eq_strict, 0);
        const to_present = try ch.emit(.jump_if_false, 0);

        ch.patchToHere(to_absent);
        return to_present;
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

    fn compileClassComputedKeys(self: *Compiler, members: []const ast.ClassMember) CompileError!u32 {
        var count: u32 = 0;
        for (members) |m| {
            if (m.static_block != null) continue;
            if (m.key_expr) |ke| {
                try self.compileExpr(ke);
                count += 1;
            }
        }
        return count;
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
        // A nested generator runs env-mode and captures the enclosing scope BY
        // NAME (load_var). If the enclosing function is frame-mode (tiered), its
        // locals live in frame slots the generator's environment chain can't see,
        // so the capture would read a stale/global value. Force the enclosing
        // function to the tree-walker, where those locals live in the Environment.
        // (An env-mode enclosing scope — self.scope == null — captures correctly.)
        if (fnode.is_generator and self.scope != null) return error.Unsupported;
        if (!fnode.is_generator and fnode.is_strict and functionHasBlockNestedFuncDecl(fnode)) return error.Unsupported;
        // Build this function's slot namespace: parameters first, then every
        // function-scoped declaration in the body (not descending into nested
        // functions). The scope chains to the enclosing function for upvalues.
        const scope = try self.arena.create(FnScope);
        scope.* = .{ .parent = self.scope };

        const sub: ?*Chunk = if (fnode.is_generator) blk: {
            break :blk try Compiler.compileGenerator(self.arena, fnode);
        } else blk: {
            const compiled = try self.arena.create(Chunk);
            compiled.* = Chunk.init(self.arena);
            for (fnode.params) |p| {
                // Default values and rest params need a runtime prologue the VM
                // doesn't emit yet. Generator-body env-mode closures can fall
                // back to the tree-walker because their names live in Environment
                // records; top-level programs must still fall back wholesale so
                // unsupported statement forms stay on the tree-walker.
                if (p.default != null or p.is_rest or p.pattern != null) {
                    if (self.in_generator and self.scope == null) break :blk null;
                    return error.Unsupported;
                }
                _ = try scope.addLocal(self.arena, p.name);
            }
            if (!fnode.is_expr_body) try collectLocals(self.arena, scope, fnode.body);

            var sub_c = Compiler{ .arena = self.arena, .chunk = compiled, .mode = .function, .scope = scope };
            if (fnode.is_expr_body) {
                sub_c.compileExpr(fnode.body) catch |e| switch (e) {
                    error.Unsupported => {
                        if (self.in_generator and self.scope == null) break :blk null;
                        return error.Unsupported;
                    },
                    error.OutOfMemory => return error.OutOfMemory,
                };
                _ = try compiled.emit(.ret, 0);
            } else {
                sub_c.compileStmt(fnode.body) catch |e| switch (e) {
                    error.Unsupported => {
                        if (self.in_generator and self.scope == null) break :blk null;
                        return error.Unsupported;
                    },
                    error.OutOfMemory => return error.OutOfMemory,
                }; // body is a block
                _ = try compiled.emit(.ret_undef, 0);
            }
            try compiled.finalize();
            break :blk compiled;
        };
        if (fnode.is_generator) {
            for (fnode.params) |p| _ = try scope.addLocal(self.arena, p.name);
        }
        const tmpl = try self.arena.create(bc.FnTemplate);
        tmpl.* = .{
            .name = fnode.name,
            // A *named function expression* (not a declaration, not an inferred
            // name, not a method, not an arrow) self-binds its own name in an
            // enclosing immutable scope — recorded here so `make_closure` wraps
            // the closure env.
            .self_name = if (named_expr and fnode.has_name_binding and !fnode.is_arrow) fnode.name else "",
            .params = fnode.params,
            .is_expr_body = fnode.is_expr_body,
            .body = fnode.body,
            .source = fnode.source,
            .is_generator = fnode.is_generator,
            .is_async = fnode.is_async,
            .is_arrow = fnode.is_arrow,
            .is_method = fnode.is_method,
            .is_strict = fnode.is_strict,
            .chunk = sub,
            .local_count = scope.count,
        };
        return self.chunk.addFn(tmpl);
    }

    // ---- loop bookkeeping -------------------------------------------------

    fn pushLoop(self: *Compiler) CompileError!*Loop {
        const loop = try self.arena.create(Loop);
        loop.* = .{ .finally_depth = self.finally_depth };
        try self.loops.append(self.arena, loop);
        return loop;
    }

    fn pushLabel(self: *Compiler, label: []const u8) CompileError!*Loop {
        const target = try self.arena.create(Loop);
        target.* = .{ .label = label, .is_loop = false, .finally_depth = self.finally_depth };
        try self.loops.append(self.arena, target);
        return target;
    }

    fn popLoop(self: *Compiler) void {
        _ = self.loops.pop();
    }

    fn currentBreakTarget(self: *Compiler, label: ?[]const u8) ?*Loop {
        var i = self.loops.items.len;
        while (i > 0) {
            i -= 1;
            const target = self.loops.items[i];
            if (label) |needle| {
                if (target.label) |have| if (std.mem.eql(u8, have, needle)) return target;
            } else {
                return target;
            }
        }
        return null;
    }

    /// The nearest loop a `continue` applies to — skipping any enclosing
    /// `switch` (which is breakable but not continuable).
    fn currentContinueLoop(self: *Compiler) ?*Loop {
        var i = self.loops.items.len;
        while (i > 0) {
            i -= 1;
            if (self.loops.items[i].is_loop and !self.loops.items[i].is_switch) return self.loops.items[i];
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
        .do_while_stmt => |s| try collectLocals(arena, scope, s.body),
        .for_stmt => |f| {
            if (f.init) |ini| try collectLocals(arena, scope, ini);
            try collectLocals(arena, scope, f.body);
        },
        .for_in => |f| {
            // `for (var x of/in …)` hoists x as a function-scoped local (a
            // destructuring `var` target bails to the tree-walker elsewhere).
            if (f.decl_kind) |k| {
                if (k == .@"var" and f.target.* == .identifier)
                    _ = try scope.addLocal(arena, f.target.identifier);
            }
            try collectLocals(arena, scope, f.body);
        },
        .switch_stmt => |s| for (s.cases) |c| for (c.body) |st| try collectLocals(arena, scope, st),
        .labeled_stmt => |s| try collectLocals(arena, scope, s.body),
        .try_stmt => |t| {
            try collectLocals(arena, scope, t.block);
            if (t.catch_block) |cb| try collectLocals(arena, scope, cb);
            if (t.finally_block) |fb| try collectLocals(arena, scope, fb);
        },
        // Expressions (incl. nested function/arrow literals) declare no names in
        // this function's scope. `var` inside these statement forms is hoisted to
        // the function scope, matching the tree-walker's hoistVarsIn.
        else => {},
    }
}
