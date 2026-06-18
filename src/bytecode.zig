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
const Shape = @import("shape.zig").Shape;

const Value = value.Value;

/// Process-wide switch for the parallel-safe (seqlock) inline-cache protocol.
/// Off by default — the GIL-serialized engine reads/writes the cache fields
/// directly (no atomics). Turned on for the parallel/concurrent contexts (set
/// next to `Environment.binding_locks_enabled`), where bytecode may execute on
/// multiple threads and two threads can race the same instruction's cache over
/// different objects. See `InlineCache.lookupSlot`/`record`.
pub var ic_seqlock_enabled: std.atomic.Value(bool) = .init(false);

/// A monomorphic inline cache for a `get_prop`/`set_prop` site: remembers the
/// last object shape seen there and the slot the property lived at, so a repeat
/// access on the same shape skips the lookup entirely. One per instruction.
pub const InlineCache = struct {
    shape: ?*Shape = null,
    slot: u32 = 0,
    /// Seqlock version for the parallel protocol: even = stable, odd = a writer
    /// is mid-update. Untouched on the default (GIL-serialized) path. Fits in
    /// the struct's existing padding, so the cache stays 16 bytes.
    version: std.atomic.Value(u32) = .init(0),

    /// Return the cached slot iff the cache currently maps `obj_shape`. On the
    /// default path this is the plain `shape == ic.shape` test; under
    /// `ic_seqlock_enabled` it is a seqlock read (`loadHit`) that rejects a
    /// torn or in-progress cache. Null = miss → caller does the real lookup.
    pub fn lookupSlot(ic: *InlineCache, obj_shape: ?*Shape) ?u32 {
        if (ic_seqlock_enabled.load(.monotonic)) return ic.loadHit(obj_shape);
        if (obj_shape != null and obj_shape == ic.shape) return ic.slot;
        return null;
    }

    /// Publish `(sh, slot)` into the cache. Plain field stores on the default
    /// path; a try-claim seqlock write under `ic_seqlock_enabled` (best-effort —
    /// skips on writer contention, so a missed update only costs a future
    /// lookup, never correctness).
    pub fn record(ic: *InlineCache, sh: *Shape, slot: u32) void {
        if (ic_seqlock_enabled.load(.monotonic)) {
            ic.tryStore(sh, slot);
            return;
        }
        ic.shape = sh;
        ic.slot = slot;
    }

    /// Seqlock read: re-read the version around the field loads and reject if a
    /// writer was in progress (odd) or the version moved (torn). When it returns
    /// a slot, `(shape, slot)` came from a single stable cache state and the
    /// shape matched `obj_shape`.
    ///
    /// All operations are `.seq_cst`: on a weakly-ordered target (e.g. arm64)
    /// plain acquire/release is *not* enough — the field loads could sink past
    /// the second version load, so a torn `(shape, slot)` would slip through the
    /// bracket. A single total order over the version + field ops makes the
    /// classic seqlock argument hold. This path is gated to the parallel modes,
    /// so the seq_cst cost never touches the default GIL-serialized engine.
    fn loadHit(ic: *InlineCache, obj_shape: ?*Shape) ?u32 {
        const v1 = ic.version.load(.seq_cst);
        if (v1 & 1 != 0) return null; // a writer holds the cache
        const sh = @atomicLoad(?*Shape, &ic.shape, .seq_cst);
        const sl = @atomicLoad(u32, &ic.slot, .seq_cst);
        if (ic.version.load(.seq_cst) != v1) return null; // torn against a write
        if (sh != null and sh == obj_shape) return sl;
        return null;
    }

    /// Seqlock write: claim the cache by CAS-ing the version even→odd, publish
    /// the pair, then bump it back to even. A writer that cannot claim (another
    /// writer holds it) skips — caching is best-effort. `.seq_cst` throughout so
    /// it shares the single total order the reader relies on.
    fn tryStore(ic: *InlineCache, sh: *Shape, slot: u32) void {
        const v = ic.version.load(.seq_cst);
        if (v & 1 != 0) return; // a writer is already in progress
        if (ic.version.cmpxchgStrong(v, v +% 1, .seq_cst, .seq_cst) != null) return; // lost the claim
        @atomicStore(u32, &ic.slot, slot, .seq_cst);
        @atomicStore(?*Shape, &ic.shape, sh, .seq_cst);
        ic.version.store(v +% 2, .seq_cst); // republish: stable (even)
    }
};

pub const Op = enum(u8) {
    // --- stack / constants ---
    load_const, // operand: const-pool index
    load_bigint, // operand: name-pool index containing canonical BigInt text
    load_undefined,
    load_null,
    load_true,
    load_false,
    pop, // discard top of stack
    dup, // duplicate top of stack
    set_acc, // pop -> completion accumulator (program-level result)

    // --- globals (resolved by name against the Environment) ---
    load_var, // operand a: name index; push value (ReferenceError if unbound)
    load_var_or_undef, // operand a: name index; push value, or undefined if unbound (for `typeof`)
    store_var, // operand a: name index; assign global, leave value on stack
    def_var, // operand a: name index; pop value, define global
    def_lex, // operand a: name index, b: 1 let / 2 const; pop value, define lexical binding
    bind_pattern, // operand a: pattern index, b: mode (0 var, 1 let, 2 const, 3 assign); pop value, destructure into the pattern

    // --- locals & upvalues (resolved to frame slots at compile time) ---
    load_local, // operand a: slot in the current frame
    store_local, // operand a: slot; assign, leave value on stack
    load_upval, // operand a: parent depth, b: slot
    store_upval, // operand a: parent depth, b: slot; leave value on stack

    // --- unary ---
    neg,
    pos,
    not,
    typeof_op,
    bit_not,
    void_op,
    to_string,

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
    in_op,
    bit_and,
    bit_or,
    bit_xor,
    shl,
    shr,
    ushr,

    // --- control flow (operand: instruction index) ---
    jump,
    jump_if_false, // pop cond; jump when falsy
    jump_if_true_peek, // peek cond (leave on stack); jump when truthy  [for ||]
    jump_if_false_peek, // peek cond (leave on stack); jump when falsy   [for &&]

    // --- objects, arrays, members ---
    load_this, // push the current `this`
    new_object, // push a fresh {}
    new_array, // push a fresh []
    init_prop, // operand a: name index; pop value, set on object at top, leave object
    init_prop_computed, // pop key, pop value, set on object at top, leave object
    init_spread, // pop source, CopyDataProperties into object at top, leave object
    init_getter, // pop fn, pop key; install getter on object at top, leave object
    init_setter, // pop fn, pop key; install setter on object at top, leave object
    array_append, // pop value, append to the array at top, leave array
    array_spread, // pop iterable, spread its elements into the array now at top, leave array
    get_prop, // operand a: name index; pop object -> push object[name]
    get_index, // pop key, pop object -> push object[key]
    set_prop, // operand a: name index; pop value, pop object -> push value (after set)
    set_index, // pop value, pop key, pop object -> push value (after set)
    instance_of, // pop rhs, pop lhs -> push (lhs instanceof rhs)

    // --- functions ---
    make_closure, // operand: fn-template index; push a Function value capturing env
    call, // operand a: argc; stack: callee, arg0..argN-1 -> push result
    call_method, // operand a: name index, b: argc; stack: recv, args... -> push result
    new_call, // operand a: argc; stack: callee, args... -> push constructed object
    // Spread-argument variants: the arguments are pre-collected into one array
    // (built with new_array/array_append/array_spread), so the call is variadic.
    call_spread, // stack: callee, args_array -> push result (this = undefined)
    call_method_spread, // operand a: name index; stack: recv, args_array -> push result (this = recv)
    new_spread, // stack: callee, args_array -> push constructed object
    ret, // pop -> return value, end frame
    ret_undef, // return undefined, end frame
    abrupt_return, // pop -> return value, but run any enclosing `finally` first (carrying a "return" completion); used by `yield*` return-delegation so a `finally` around the `yield*` still executes

    // --- generators / iteration ---
    gen_yield, // pop -> yielded value, suspend the frame; resume pushes the sent value
    gen_yield_star, // like gen_yield but at a `yield*` delegation point: resume pushes [value, kind] (kind 0 send / 1 throw / 2 return) so the desugared loop can forward throw()/return() to the inner iterator
    await_op, // pop -> awaited value, suspend (async); the driver resumes with the settled value
    call_with_this, // operand a: argc; stack: func, this, args... -> push func.call(this, args). Used by `yield*` so a method fetched once (GetMethod) is invoked without a second property lookup.
    assert_iter_result, // peek top; throw a TypeError if it is not an Object (the iterator-result-not-object check shared by next/throw/return)
    iter_of, // pop iterable -> push an iterator object (has a `.next()`); for `yield*`
    async_iter_of, // pop iterable -> push its async iterator (Symbol.asyncIterator, else a sync iterator); for `for await`
    enum_keys, // pop object -> push an array of its for-in keys (own enumerable + array indices)
    iter_close, // pop iterator; normal-completion IteratorClose (call return() if present, validate result is Object)

    throw_op, // pop -> set as the in-flight exception and unwind (error.Throw)

    // --- exception handling (generator VM) ---
    push_handler, // operand a: catch-block PC (or u32 max = none), b: finally-block PC (or none)
    pop_handler, // discard the topmost handler (on normal exit from a try block)
    push_completion, // operand a: completion kind (0 = normal); push [undefined, kind] for a finally block
    end_finally, // pop a completion [value, kind] left by a finally: rethrow (1) / return (2) / break (3) / continue (4) / fall-through (0)
    abrupt_break, // operand a: the loop's break target PC (patched like a normal break jump); run enclosing finally(s) first, then jump there
    abrupt_continue, // operand a: the loop's continue target PC; run enclosing finally(s) first, then jump there

    halt, // end program; result is the accumulator
};

/// A single instruction. `a` is the primary operand (const/name/fn index, jump
/// target, or argc); `b` is a secondary operand used only by `call_method`
/// (which needs both a method-name index and an argument count).
pub const Inst = struct {
    op: Op,
    a: u32 = 0,
    b: u32 = 0,
};

/// A compiled function prototype referenced by `make_closure`. Carries the
/// original AST `body` too, so a Function value remains tree-walk-callable
/// (the migration fallback) in addition to VM-callable.
pub const FnTemplate = struct {
    name: []const u8,
    /// A *named function expression's* own name, which binds as an immutable
    /// binding in a fresh scope enclosing the body (so the body can recurse via
    /// its own name and can't rebind it). Empty for declarations and anonymous
    /// or arrow functions — only set when `make_closure` must wrap the closure
    /// in a self-binding environment.
    self_name: []const u8 = "",
    params: []const ast.Param,
    is_expr_body: bool,
    body: *ast.Node,
    /// Exact source text of the function definition, for `Function.prototype.
    /// toString` (empty when the parser didn't capture it).
    source: []const u8 = "",
    is_generator: bool = false,
    is_async: bool = false,
    chunk: *Chunk,
    /// Number of frame slots (params + function-scoped declarations) the VM
    /// allocates per call.
    local_count: u32,
};

/// A unit of compiled code: the instruction stream plus its constant, name,
/// and function-template pools. All slices live in the owning arena.
pub const Chunk = struct {
    arena: std.mem.Allocator,
    code: std.ArrayListUnmanaged(Inst) = .empty,
    consts: std.ArrayListUnmanaged(Value) = .empty,
    names: std.ArrayListUnmanaged([]const u8) = .empty,
    fns: std.ArrayListUnmanaged(*FnTemplate) = .empty,
    /// Destructuring-pattern AST nodes referenced by `bind_pattern` (the VM
    /// reuses the tree-walker's `bindPattern` over the live environment).
    patterns: std.ArrayListUnmanaged(*ast.Node) = .empty,
    /// One inline cache per instruction, allocated by `finalize` once the code
    /// stream is complete. Warm across runs of the same chunk.
    ics: []InlineCache = &.{},

    pub fn init(arena: std.mem.Allocator) Chunk {
        return .{ .arena = arena };
    }

    /// Allocate the inline-cache table. Call once after emitting all code.
    pub fn finalize(self: *Chunk) std.mem.Allocator.Error!void {
        self.ics = try self.arena.alloc(InlineCache, self.code.items.len);
        @memset(self.ics, .{});
    }

    /// Emit an instruction, returning its index (for later jump back-patching).
    pub fn emit(self: *Chunk, op: Op, a: u32) std.mem.Allocator.Error!usize {
        const idx = self.code.items.len;
        try self.code.append(self.arena, .{ .op = op, .a = a });
        return idx;
    }

    /// Emit an instruction with both operands (only `call_method` needs `b`).
    pub fn emitAB(self: *Chunk, op: Op, a: u32, b: u32) std.mem.Allocator.Error!usize {
        const idx = self.code.items.len;
        try self.code.append(self.arena, .{ .op = op, .a = a, .b = b });
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

    pub fn addPattern(self: *Chunk, node: *ast.Node) std.mem.Allocator.Error!u32 {
        const idx: u32 = @intCast(self.patterns.items.len);
        try self.patterns.append(self.arena, node);
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

test "InlineCache seqlock: concurrent writers never tear the (shape, slot) pair" {
    // The hazard the seqlock fixes: two threads racing the *same* instruction's
    // cache over *different* shapes (each holds a different object's
    // `property_lock`, so the per-object locks don't serialize them). With plain
    // field stores the cache can settle into a *stable* inconsistency — shape of
    // A paired with slot of B — and a reader matching shape A would read B's
    // slot. The seqlock guarantees any `(shape, slot)` a reader observes came
    // from a single `record` call, so each shape always reads back its own slot.
    // TSan-clean proves the atomic field accesses are race-free too (the plain
    // path would be a data race here).
    const builtin = @import("builtin");
    if (builtin.single_threaded) return error.SkipZigTest;

    const prev = ic_seqlock_enabled.swap(true, .release);
    defer ic_seqlock_enabled.store(prev, .release);

    // Two distinct *Shape pointers; the cache only compares/stores them (never
    // dereferences), so undefined Shape storage is fine. Shape S0 ⇒ slot 0,
    // S1 ⇒ slot 1: the invariant every reader must observe.
    var s0: Shape = undefined;
    var s1: Shape = undefined;
    var ic = InlineCache{};

    const Shared = struct {
        ic: *InlineCache,
        s0: *Shape,
        s1: *Shape,
        go: std.atomic.Value(bool) = .init(false),
        stop: std.atomic.Value(bool) = .init(false),
        torn: std.atomic.Value(bool) = .init(false), // set if a hit ever mispairs

        fn writer0(s: *@This()) void {
            while (!s.go.load(.acquire)) std.atomic.spinLoopHint();
            while (!s.stop.load(.acquire)) s.ic.record(s.s0, 0);
        }
        fn writer1(s: *@This()) void {
            while (!s.go.load(.acquire)) std.atomic.spinLoopHint();
            while (!s.stop.load(.acquire)) s.ic.record(s.s1, 1);
        }
        fn reader(s: *@This()) void {
            while (!s.go.load(.acquire)) std.atomic.spinLoopHint();
            while (!s.stop.load(.acquire)) {
                if (s.ic.lookupSlot(s.s0)) |sl| {
                    if (sl != 0) s.torn.store(true, .release);
                }
                if (s.ic.lookupSlot(s.s1)) |sl| {
                    if (sl != 1) s.torn.store(true, .release);
                }
            }
        }
    };

    var shared = Shared{ .ic = &ic, .s0 = &s0, .s1 = &s1 };
    const w0 = try std.Thread.spawn(.{}, Shared.writer0, .{&shared});
    const w1 = try std.Thread.spawn(.{}, Shared.writer1, .{&shared});
    const r0 = try std.Thread.spawn(.{}, Shared.reader, .{&shared});
    const r1 = try std.Thread.spawn(.{}, Shared.reader, .{&shared});
    shared.go.store(true, .release);
    // Let the threads contend for a while.
    var spins: usize = 0;
    while (spins < 2_000_000) : (spins += 1) std.atomic.spinLoopHint();
    shared.stop.store(true, .release);
    w0.join();
    w1.join();
    r0.join();
    r1.join();

    try std.testing.expect(!shared.torn.load(.acquire)); // no shape↔slot mispairing
}
