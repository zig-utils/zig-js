//! Bytecode for zig-js's tier-1 VM.
//!
//! A compact, stack-based instruction set that the `compiler` lowers the AST
//! into and the `vm` executes. This is the first step off the tree-walker:
//! evaluation becomes a flat instruction stream (no per-node recursion or
//! function-pointer dispatch), which is the foundation the later perf tiers —
//! slot-allocated locals, NaN-boxed values, inline caches, a JIT — build on.
//!
//! Variables still resolve through the shared `Environment`, so scoping and
//! closures keep the exact semantics the tree-walker already proves against
//! test262; turning name lookups into register/slot indexes is a deliberate
//! tier-2 follow-up, not part of this first cut.

const std = @import("std");
const ast = @import("ast.zig");
const value = @import("value.zig");

const Value = value.Value;

pub const Op = enum(u8) {
    // --- stack / constants ---
    load_const, // operand: const-pool index
    load_undefined,
    load_null,
    load_true,
    load_false,
    pop, // discard top of stack
    dup, // duplicate top of stack
    set_acc, // pop -> completion accumulator (program-level result)

    // --- variables (resolved against the Environment chain) ---
    load_var, // operand: name index; push value (ReferenceError if unbound)
    store_var, // operand: name index; assign nearest binding, leave value on stack
    def_var, // operand: name index; pop value, define in current scope

    // --- unary ---
    neg,
    pos,
    not,
    typeof_op,

    // --- binary (pop rhs, pop lhs, push result) ---
    add,
    sub,
    mul,
    div,
    mod,
    pow,
    lt,
    le,
    gt,
    ge,
    eq,
    neq,
    eq_strict,
    neq_strict,

    // --- control flow (operand: instruction index) ---
    jump,
    jump_if_false, // pop cond; jump when falsy
    jump_if_true_peek, // peek cond (leave on stack); jump when truthy  [for ||]
    jump_if_false_peek, // peek cond (leave on stack); jump when falsy   [for &&]

    // --- functions ---
    make_closure, // operand: fn-template index; push a Function value capturing env
    call, // operand: argc; stack: callee, arg0..argN-1 -> push result
    ret, // pop -> return value, end frame
    ret_undef, // return undefined, end frame

    halt, // end program; result is the accumulator
};

pub const Inst = struct {
    op: Op,
    a: u32 = 0,
};

/// A compiled function prototype referenced by `make_closure`. Carries the
/// original AST `body` too, so a Function value remains tree-walk-callable
/// (the migration fallback) in addition to VM-callable.
pub const FnTemplate = struct {
    name: []const u8,
    params: []const []const u8,
    is_expr_body: bool,
    body: *ast.Node,
    chunk: *Chunk,
};

/// A unit of compiled code: the instruction stream plus its constant, name,
/// and function-template pools. All slices live in the owning arena.
pub const Chunk = struct {
    arena: std.mem.Allocator,
    code: std.ArrayListUnmanaged(Inst) = .empty,
    consts: std.ArrayListUnmanaged(Value) = .empty,
    names: std.ArrayListUnmanaged([]const u8) = .empty,
    fns: std.ArrayListUnmanaged(*FnTemplate) = .empty,

    pub fn init(arena: std.mem.Allocator) Chunk {
        return .{ .arena = arena };
    }

    /// Emit an instruction, returning its index (for later jump back-patching).
    pub fn emit(self: *Chunk, op: Op, a: u32) std.mem.Allocator.Error!usize {
        const idx = self.code.items.len;
        try self.code.append(self.arena, .{ .op = op, .a = a });
        return idx;
    }

    pub fn addConst(self: *Chunk, v: Value) std.mem.Allocator.Error!u32 {
        const idx: u32 = @intCast(self.consts.items.len);
        try self.consts.append(self.arena, v);
        return idx;
    }

    pub fn addName(self: *Chunk, name: []const u8) std.mem.Allocator.Error!u32 {
        const idx: u32 = @intCast(self.names.items.len);
        try self.names.append(self.arena, name);
        return idx;
    }

    pub fn addFn(self: *Chunk, tmpl: *FnTemplate) std.mem.Allocator.Error!u32 {
        const idx: u32 = @intCast(self.fns.items.len);
        try self.fns.append(self.arena, tmpl);
        return idx;
    }

    /// Point the jump at `inst_idx` to the current end of the code stream.
    pub fn patchToHere(self: *Chunk, inst_idx: usize) void {
        self.code.items[inst_idx].a = @intCast(self.code.items.len);
    }

    pub fn patchTo(self: *Chunk, inst_idx: usize, target: usize) void {
        self.code.items[inst_idx].a = @intCast(target);
    }

    pub fn here(self: *Chunk) usize {
        return self.code.items.len;
    }
};
