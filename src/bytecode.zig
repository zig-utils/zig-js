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
const jit = @import("jit.zig");
const Shape = @import("shape.zig").Shape;

const Value = value.Value;

/// Process-wide switch for the parallel-safe (seqlock) inline-cache protocol.
/// Off by default — the GIL-serialized engine reads/writes the cache fields
/// directly (no atomics). Turned on for the parallel/concurrent contexts (set
/// next to `Environment.binding_locks_enabled`), where bytecode may execute on
/// multiple threads and two threads can race the same instruction's cache over
/// different objects. See `InlineCache.lookupSlot`/`record`.
pub var ic_seqlock_enabled: std.atomic.Value(bool) = .init(false);

/// A small polymorphic inline cache for a `get_prop`/`set_prop` site. The first
/// observed shape stays in the primary entry (preserving the one-compare
/// monomorphic hot path); three secondary entries cover common polymorphic
/// sites without allocating a side table. One cache lives beside every
/// instruction, and a fifth distinct shape replaces secondary entries in
/// round-robin order.
pub const InlineCache = struct {
    pub const LiteralTransition = struct {
        shape: *Shape,
        slot: u32,
    };

    shape: ?*Shape = null,
    slot: u32 = 0,
    secondary_shapes: [3]?*Shape = .{ null, null, null },
    secondary_slots: [3]u32 = .{ 0, 0, 0 },
    next_secondary: u32 = 0,
    /// Seqlock version for the parallel protocol: even = stable, odd = a writer
    /// is mid-update. Untouched on the default (GIL-serialized) path.
    version: std.atomic.Value(u32) = .init(0),

    /// Return the cached slot iff the cache currently maps `obj_shape`. On the
    /// default path this is the plain `shape == ic.shape` test; under
    /// `ic_seqlock_enabled` it is a seqlock read (`loadHit`) that rejects a
    /// torn or in-progress cache. Null = miss → caller does the real lookup.
    pub fn lookupSlot(ic: *InlineCache, obj_shape: ?*Shape) ?u32 {
        return ic.lookupSlotMode(obj_shape, ic_seqlock_enabled.load(.monotonic));
    }

    /// Same lookup with the process-wide mode already hoisted by the VM. A
    /// chunk cannot switch from isolated to shared execution while it runs, so
    /// paying an atomic flag load at every property opcode is unnecessary.
    pub inline fn lookupSlotMode(ic: *InlineCache, obj_shape: ?*Shape, parallel: bool) ?u32 {
        if (parallel) return ic.loadHit(obj_shape);
        if (obj_shape != null and obj_shape == ic.shape) return ic.slot;
        inline for (0..ic.secondary_shapes.len) |index|
            if (obj_shape != null and obj_shape == ic.secondary_shapes[index]) return ic.secondary_slots[index];
        return null;
    }

    /// `init_prop` stores the immutable child shape instead of the predecessor:
    /// the child's parent is therefore the exact guard for a warm literal-site
    /// transition, while the paired slot is the append destination. The same
    /// four-entry storage remains available for chunks reused across realms.
    pub inline fn lookupLiteralTransitionMode(ic: *InlineCache, parent: *Shape, parallel: bool) ?LiteralTransition {
        if (parallel) return ic.loadLiteralTransition(parent);
        if (ic.shape) |child| {
            if (child.parent == parent) return .{ .shape = child, .slot = ic.slot };
        }
        inline for (0..ic.secondary_shapes.len) |index| {
            if (ic.secondary_shapes[index]) |child| {
                if (child.parent == parent) return .{ .shape = child, .slot = ic.secondary_slots[index] };
            }
        }
        return null;
    }

    /// Publish `(sh, slot)` into the cache. Plain field stores on the default
    /// path; a try-claim seqlock write under `ic_seqlock_enabled` (best-effort —
    /// skips on writer contention, so a missed update only costs a future
    /// lookup, never correctness).
    pub fn record(ic: *InlineCache, sh: *Shape, slot: u32) void {
        ic.recordMode(sh, slot, ic_seqlock_enabled.load(.monotonic));
    }

    /// Same update with the process-wide mode already hoisted by the VM.
    pub inline fn recordMode(ic: *InlineCache, sh: *Shape, slot: u32, parallel: bool) void {
        if (parallel) {
            ic.tryStore(sh, slot);
            return;
        }
        ic.store(sh, slot);
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
    /// classic seqlock argument hold. This path is gated to parallel modes, so
    /// the seq_cst cost never touches single-threaded or `.gil = true` execution.
    fn loadHit(ic: *InlineCache, obj_shape: ?*Shape) ?u32 {
        const v1 = ic.version.load(.seq_cst);
        if (v1 & 1 != 0) return null; // a writer holds the cache
        const sh = @atomicLoad(?*Shape, &ic.shape, .seq_cst);
        const sl = @atomicLoad(u32, &ic.slot, .seq_cst);
        var hit = if (sh != null and sh == obj_shape) sl else null;
        inline for (0..ic.secondary_shapes.len) |index| {
            const secondary_shape = @atomicLoad(?*Shape, &ic.secondary_shapes[index], .seq_cst);
            const secondary_slot = @atomicLoad(u32, &ic.secondary_slots[index], .seq_cst);
            if (hit == null and secondary_shape != null and secondary_shape == obj_shape) hit = secondary_slot;
        }
        if (ic.version.load(.seq_cst) != v1) return null; // torn against a write
        return hit;
    }

    fn loadLiteralTransition(ic: *InlineCache, parent: *Shape) ?LiteralTransition {
        const v1 = ic.version.load(.seq_cst);
        if (v1 & 1 != 0) return null;
        const primary_shape = @atomicLoad(?*Shape, &ic.shape, .seq_cst);
        const primary_slot = @atomicLoad(u32, &ic.slot, .seq_cst);
        var hit: ?LiteralTransition = if (primary_shape != null and primary_shape.?.parent == parent)
            .{ .shape = primary_shape.?, .slot = primary_slot }
        else
            null;
        inline for (0..ic.secondary_shapes.len) |index| {
            const child = @atomicLoad(?*Shape, &ic.secondary_shapes[index], .seq_cst);
            const slot = @atomicLoad(u32, &ic.secondary_slots[index], .seq_cst);
            if (hit == null and child != null and child.?.parent == parent)
                hit = .{ .shape = child.?, .slot = slot };
        }
        if (ic.version.load(.seq_cst) != v1) return null;
        return hit;
    }

    fn store(ic: *InlineCache, sh: *Shape, slot: u32) void {
        if (ic.shape == null or ic.shape == sh) {
            ic.slot = slot;
            ic.shape = sh;
            return;
        }
        for (&ic.secondary_shapes, &ic.secondary_slots) |*cached_shape, *cached_slot| {
            if (cached_shape.* == sh) {
                cached_slot.* = slot;
                return;
            }
        }
        for (&ic.secondary_shapes, &ic.secondary_slots) |*cached_shape, *cached_slot| {
            if (cached_shape.* == null) {
                cached_slot.* = slot;
                cached_shape.* = sh;
                return;
            }
        }
        const index = ic.next_secondary % ic.secondary_shapes.len;
        ic.next_secondary +%= 1;
        ic.secondary_slots[index] = slot;
        ic.secondary_shapes[index] = sh;
    }

    /// Seqlock write: claim the cache by CAS-ing the version even→odd, publish
    /// the pair, then bump it back to even. A writer that cannot claim (another
    /// writer holds it) skips — caching is best-effort. `.seq_cst` throughout so
    /// it shares the single total order the reader relies on.
    fn tryStore(ic: *InlineCache, sh: *Shape, slot: u32) void {
        const v = ic.version.load(.seq_cst);
        if (v & 1 != 0) return; // a writer is already in progress
        if (ic.version.cmpxchgStrong(v, v +% 1, .seq_cst, .seq_cst) != null) return; // lost the claim
        const primary_shape = @atomicLoad(?*Shape, &ic.shape, .seq_cst);
        if (primary_shape == null or primary_shape == sh) {
            @atomicStore(u32, &ic.slot, slot, .seq_cst);
            @atomicStore(?*Shape, &ic.shape, sh, .seq_cst);
            ic.version.store(v +% 2, .seq_cst);
            return;
        }
        inline for (0..ic.secondary_shapes.len) |index| {
            if (@atomicLoad(?*Shape, &ic.secondary_shapes[index], .seq_cst) == sh) {
                @atomicStore(u32, &ic.secondary_slots[index], slot, .seq_cst);
                ic.version.store(v +% 2, .seq_cst);
                return;
            }
        }
        inline for (0..ic.secondary_shapes.len) |index| {
            if (@atomicLoad(?*Shape, &ic.secondary_shapes[index], .seq_cst) == null) {
                @atomicStore(u32, &ic.secondary_slots[index], slot, .seq_cst);
                @atomicStore(?*Shape, &ic.secondary_shapes[index], sh, .seq_cst);
                ic.version.store(v +% 2, .seq_cst);
                return;
            }
        }
        const next = @atomicLoad(u32, &ic.next_secondary, .seq_cst);
        const index = next % ic.secondary_shapes.len;
        @atomicStore(u32, &ic.next_secondary, next +% 1, .seq_cst);
        @atomicStore(u32, &ic.secondary_slots[index], slot, .seq_cst);
        @atomicStore(?*Shape, &ic.secondary_shapes[index], sh, .seq_cst);
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
    nop, // explicit statement boundary with no stack effect (`debugger;`)
    pop, // discard top of stack
    dup, // duplicate top of stack
    swap, // swap the top two stack values
    set_acc, // pop -> completion accumulator (program-level result)

    // --- globals (resolved by name against the Environment) ---
    load_var, // operand a: name index; push value (ReferenceError if unbound)
    load_var_or_undef, // operand a: name index; push value, or undefined if unbound (for `typeof`)
    store_var, // operand a: name index; assign global, leave value on stack
    def_var, // operand a: name index, b: 0 bare `var x;`, 1 `var x = init`, 2 force define/function/internal temp; pop value, define global
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
    to_numeric, // ToNumeric(pop) -> Number or BigInt (the postfix `x++` old value)
    inc, // ToNumeric(pop) then +1 of the matching numeric type
    dec, // ToNumeric(pop) then -1 of the matching numeric type
    to_property_key, // ToPropertyKey(pop) -> the property-key string (runs toString once)
    name_anon, // NamedEvaluation: name the top-of-stack anonymous function (operand a: name)

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
    jump_if_nullish_peek, // peek cond; jump when null/undefined         [for ??]
    jump_if_not_nullish_peek, // peek cond; jump when not null/undefined [for ??]

    // --- objects, arrays, members ---
    load_this, // push the current `this`
    load_new_target, // push the current `new.target`
    new_object, // push a fresh {}
    new_array, // push a fresh []
    init_prop, // operand a: name index; pop value, define own data prop on object at top, leave object
    init_proto, // pop value; if object/null set it as the [[Prototype]] of object at top (the `__proto__: v` colon form), leave object
    init_prop_computed, // pop key, pop value, set on object at top, leave object
    init_spread, // pop source, CopyDataProperties into object at top, leave object
    init_getter, // pop fn, pop key; install getter on object at top, leave object
    init_setter, // pop fn, pop key; install setter on object at top, leave object
    array_append, // pop value, append to the array at top, leave array
    array_spread, // pop iterable, spread its elements into the array now at top, leave array
    get_prop, // operand a: name index; pop object -> push object[name]
    super_get, // operand a: name index; push super.[name] (home_object.proto[name], receiver = this)
    super_get_index, // pop key; push super[key] (home_object.proto[key], receiver = this)
    enter_block, // push a declarative block Environment Record onto vm.env
    exit_block, // pop the innermost block/with environment off vm.env
    dispose_scope, // DisposeResources for the current Environment Record
    enter_with, // pop object; push an object Environment Record (with_object = ToObject(it)) onto vm.env
    exit_with, // pop the innermost with/block environment off vm.env (restore its parent)
    make_regex, // operands a: pattern name index, b: flags name index; push a fresh RegExp object
    register_disposable, // operand a: 0 = `using`, 1 = `await using`; pop value, register it for DisposeResources at body exit
    array_append_hole, // append an array-literal elision (a hole that reads as absent) to the array on the stack top
    call_eval, // operand a: argc; a bare `eval(args)` — marks direct-eval so a real eval runs in the current scope
    import_call, // operand a: phase name index; pop options, pop specifier -> push import() promise
    get_index, // pop key, pop object -> push object[key]
    set_prop, // operand a: name index; pop value, pop object -> push value (after set)
    set_index, // pop value, pop key, pop object -> push value (after set)
    instance_of, // pop rhs, pop lhs -> push (lhs instanceof rhs)
    private_in, // operand a: private-name index; pop rhs object -> push (#name in rhs)

    // --- functions ---
    make_closure, // operand: fn-template index; push a Function value capturing env
    call, // operand a: argc; stack: callee, arg0..argN-1 -> push result
    call_method, // operand a: name index, b: argc; stack: recv, args... -> push result
    tail_call, // operand a: argc; stack: callee, arg0..argN-1 -> replace current activation
    tail_call_eval, // operand a: argc; direct-eval aware tail-position call
    tail_call_method, // operand a: name index, b: argc; stack: recv, args... -> tail call recv.name
    tail_call_with_this, // operand a: argc; stack: func, this, args... -> tail call func with this
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
    iter_close_completion, // pop iterator; IteratorClose while [completion-value, kind] is beneath it, preserving throw completions
    async_iter_close, // pop async iterator -> push return result and has-return flag; caller awaits/validates when present
    async_iter_close_completion, // async_iter_close while [completion-value, kind] is beneath it, preserving throw completions during GetMethod/Call
    eval_class, // operand a: class AST index, b: computed-name count; pop raw computed-name values, evaluate the class
    template_object, // operand a: template-site AST index; push the cached, frozen GetTemplateObject strings array for that tagged-template site

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

pub const quick_call_loop_candidate: u8 = 1 << 0;
pub const quick_array_loop_candidate: u8 = 1 << 1;

fn mayStartQuickArrayLoop(code: []const Inst, start: usize) bool {
    const packed_sum = start + 3 < code.len and
        code[start + 1].op == .load_local and
        code[start + 2].op == .get_prop and
        code[start + 3].op == .lt;
    const packed_push = start + 7 < code.len and
        (code[start + 1].op == .load_const or code[start + 1].op == .load_local) and
        code[start + 2].op == .lt and
        code[start + 3].op == .jump_if_false and
        code[start + 4].op == .load_local and
        code[start + 5].op == .dup and
        code[start + 6].op == .get_prop and
        code[start + 7].op == .swap;
    const polymorphic_property = start + 8 < code.len and
        (code[start + 1].op == .load_const or code[start + 1].op == .load_local) and
        code[start + 2].op == .lt and
        code[start + 3].op == .jump_if_false and
        code[start + 4].op == .load_local and
        code[start + 5].op == .load_local and
        code[start + 6].op == .load_const and
        code[start + 7].op == .bit_and and
        code[start + 8].op == .get_index;
    const object_allocation = start + 11 < code.len and
        (code[start + 1].op == .load_const or code[start + 1].op == .load_local) and
        code[start + 2].op == .lt and
        code[start + 3].op == .jump_if_false and
        code[start + 4].op == .load_local and
        code[start + 5].op == .load_const and
        code[start + 6].op == .bit_and and
        code[start + 7].op == .store_local and
        code[start + 8].op == .pop and
        code[start + 9].op == .load_local and
        code[start + 10].op == .load_local and
        code[start + 11].op == .get_index;
    return packed_sum or packed_push or polymorphic_property or object_allocation;
}

fn mayStartQuickCallLoop(code: []const Inst, start: usize) bool {
    if (start + 7 >= code.len or
        (code[start + 1].op != .load_const and code[start + 1].op != .load_local) or
        code[start + 2].op != .lt or
        code[start + 3].op != .jump_if_false)
        return false;
    const direct =
        (code[start + 4].op == .load_var or code[start + 4].op == .load_local) and
        code[start + 5].op == .load_local and
        code[start + 6].op == .load_local and
        code[start + 7].op == .call;
    const method = start + 10 < code.len and
        code[start + 4].op == .load_local and
        code[start + 5].op == .dup and
        code[start + 6].op == .get_prop and
        code[start + 7].op == .swap and
        code[start + 8].op == .load_local and
        code[start + 9].op == .load_local and
        code[start + 10].op == .call_with_this;
    const closure = start + 9 < code.len and
        code[start + 4].op == .make_closure and
        code[start + 5].op == .store_local and
        code[start + 6].op == .pop and
        code[start + 7].op == .load_local and
        code[start + 8].op == .load_local and
        code[start + 9].op == .call;
    return direct or method or closure;
}

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
    /// Whether the source can observe its `arguments` object. Numeric leaf-call
    /// inlining requires false; arguments-using functions retain full call setup.
    uses_arguments: bool = true,
    is_generator: bool = false,
    is_async: bool = false,
    /// An arrow function: it captures `this`/`new.target`/`super`/the
    /// field-initializer context lexically at closure creation (see makeClosure).
    is_arrow: bool = false,
    /// Concise method syntax (`m(){}` / `*m(){}`), which gets a [[HomeObject]].
    is_method: bool = false,
    /// Strict-mode function (own `"use strict"` prologue or lexically inherited).
    /// Threaded to the closure so the VM's this-binding matches the tree-walker:
    /// a sloppy bare call substitutes the global `this`, a strict one keeps undefined.
    is_strict: bool = false,
    chunk: ?*Chunk,
    /// Number of frame slots (params + function-scoped declarations) the VM
    /// allocates per call.
    local_count: u32,
};

/// A unit of compiled code: the instruction stream plus its constant, name,
/// and function-template pools. All slices live in the owning arena.
pub const Chunk = struct {
    const DebugSite = struct { instruction: usize, node: *const ast.Node };

    arena: std.mem.Allocator,
    /// Frame layout owned by this chunk. Program and environment-mode chunks
    /// leave both at zero; plain function chunks record parameters first,
    /// followed by every function-scoped local. Native tiers use this metadata
    /// to validate slot operands and entry guards without depending on a
    /// `Function` object's private layout.
    param_count: u32 = 0,
    local_count: u32 = 0,
    /// Stable source names for frame slots. Empty for program/env-mode chunks.
    /// The VM consults this only while an inspector hook is active.
    debug_local_names: []const []const u8 = &.{},
    code: std.ArrayListUnmanaged(Inst) = .empty,
    consts: std.ArrayListUnmanaged(Value) = .empty,
    names: std.ArrayListUnmanaged([]const u8) = .empty,
    fns: std.ArrayListUnmanaged(*FnTemplate) = .empty,
    /// Optional statement-boundary metadata. Chunks retain it eagerly so late
    /// debugger attachment works; a null hook keeps dispatch disabled.
    debug_sites: std.ArrayListUnmanaged(DebugSite) = .empty,
    debug_nodes: []?*const ast.Node = &.{},
    /// Destructuring-pattern AST nodes referenced by `bind_pattern` (the VM
    /// reuses the tree-walker's `bindPattern` over the live environment).
    patterns: std.ArrayListUnmanaged(*ast.Node) = .empty,
    /// Class-expression AST nodes referenced by `eval_class`; the compiler
    /// evaluates any suspendable computed names first, then the VM delegates the
    /// actual class construction back to the interpreter.
    classes: std.ArrayListUnmanaged(*ast.Node) = .empty,
    /// Tagged-template AST nodes referenced by `template_object`; the VM asks the
    /// interpreter for the per-site cached+frozen strings object (GetTemplateObject).
    templates: std.ArrayListUnmanaged(*ast.Node) = .empty,
    /// One inline cache per instruction, allocated by `finalize` once the code
    /// stream is complete. Warm across runs of the same chunk.
    ics: []InlineCache = &.{},
    /// Lazily allocated VM-owned quick-trace plans, indexed by their first
    /// bytecode. Kept type-erased here to avoid a bytecode → VM import cycle.
    /// Isolated execution publishes a plan only after fully decoding it and may
    /// cache its monomorphic slots; parallel mode does not consume this table.
    quick_property_plans: []?*anyopaque = &.{},
    /// Lazily decoded multi-property counted-loop kernels. The slot table is
    /// allocated with bytecode for atomic shared-mode plan publication. Kept
    /// separate from single-assignment plans because a guarded kernel miss must
    /// still be able to consult the ordinary plan at the same first instruction.
    quick_property_kernel_plans: []?*anyopaque = &.{},
    /// Lazily decoded packed-array loop plans, indexed by loop-head bytecode.
    /// The slot table is allocated with the bytecode so shared execution can
    /// atomically publish a fully decoded plan without racing lazy table setup.
    /// Unsupported structural shapes are cached too.
    quick_array_plans: []?*anyopaque = &.{},
    /// Lazily decoded counted loops whose body is one monomorphic numeric leaf
    /// call. The VM owns the plan type; slots are indexed by loop-head bytecode.
    quick_call_plans: []?*anyopaque = &.{},
    /// Immutable structural hints for loop quickeners, indexed by bytecode.
    /// Finalization pays the bounded lookahead once so ordinary load-local
    /// dispatch does not repeatedly rescan the same instruction stream.
    quick_loop_candidates: []u8 = &.{},
    /// Isolated-mode live-slot caches for global `load_var` sites. Entries are
    /// type-erased to avoid importing interpreter/value types here and are
    /// guarded by their exact closure environment, global object, and shape.
    quick_global_bindings: []?*anyopaque = &.{},
    /// Lazily decoded pure numeric self-recurrence plan for this function
    /// chunk. The VM owns the type and caches an explicit unsupported plan too.
    quick_recurrence_plan: ?*anyopaque = null,
    /// Lazily decoded straight-line numeric leaf expression for guarded call
    /// inlining. Kept per callee chunk so rebinding a call site naturally
    /// selects or rejects the replacement function's own plan.
    quick_leaf_plan: ?*anyopaque = null,
    /// Hotness and race-safe baseline native-tier publication state.
    tier: jit.Tier = .{},
    /// Advisory observations and publication state for the distinct optimizing
    /// tier. The optimizer may consume snapshots, but generated code must guard
    /// every resulting assumption and preserve baseline/interpreter fallback.
    optimizer_profile: jit.OptimizerProfile = .{},
    optimizer_tier: jit.OptimizerTier = .{},

    pub fn init(arena: std.mem.Allocator) Chunk {
        return .{ .arena = arena };
    }

    /// Allocate the inline-cache table. Call once after emitting all code.
    pub fn finalize(self: *Chunk) std.mem.Allocator.Error!void {
        self.ics = try self.arena.alloc(InlineCache, self.code.items.len);
        @memset(self.ics, .{});
        self.quick_property_kernel_plans = try self.arena.alloc(?*anyopaque, self.code.items.len);
        @memset(self.quick_property_kernel_plans, null);
        self.quick_array_plans = try self.arena.alloc(?*anyopaque, self.code.items.len);
        @memset(self.quick_array_plans, null);
        self.quick_call_plans = try self.arena.alloc(?*anyopaque, self.code.items.len);
        @memset(self.quick_call_plans, null);
        self.quick_loop_candidates = try self.arena.alloc(u8, self.code.items.len);
        for (self.quick_loop_candidates, 0..) |*candidate, instruction| {
            var mask: u8 = 0;
            if (mayStartQuickCallLoop(self.code.items, instruction)) mask |= quick_call_loop_candidate;
            if (mayStartQuickArrayLoop(self.code.items, instruction)) mask |= quick_array_loop_candidate;
            candidate.* = mask;
        }
        if (self.debug_sites.items.len > 0) {
            self.debug_nodes = try self.arena.alloc(?*const ast.Node, self.code.items.len);
            @memset(self.debug_nodes, null);
            // Later/nested statements at the same first instruction are the
            // more precise boundary (e.g. a block and its first child).
            for (self.debug_sites.items) |site| self.debug_nodes[site.instruction] = site.node;
        }
    }

    pub fn markDebugStatement(self: *Chunk, node: *const ast.Node) std.mem.Allocator.Error!void {
        try self.debug_sites.append(self.arena, .{ .instruction = self.code.items.len, .node = node });
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

    pub fn addTemplate(self: *Chunk, node: *ast.Node) std.mem.Allocator.Error!u32 {
        const idx: u32 = @intCast(self.templates.items.len);
        try self.templates.append(self.arena, node);
        return idx;
    }

    pub fn addClass(self: *Chunk, node: *ast.Node) std.mem.Allocator.Error!u32 {
        const idx: u32 = @intCast(self.classes.items.len);
        try self.classes.append(self.arena, node);
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

test "InlineCache retains four polymorphic shape-slot pairs" {
    var shapes: [5]Shape = undefined;
    var ic = InlineCache{};
    for (shapes[0..4], 0..) |*shape, index| ic.recordMode(shape, @intCast(index), false);
    for (shapes[0..4], 0..) |*shape, index|
        try std.testing.expectEqual(@as(?u32, @intCast(index)), ic.lookupSlotMode(shape, false));

    // A fifth shape retains the primary monomorphic entry and evicts exactly
    // one secondary entry. The replacement itself must immediately hit.
    ic.recordMode(&shapes[4], 4, false);
    try std.testing.expectEqual(@as(?u32, 0), ic.lookupSlotMode(&shapes[0], false));
    try std.testing.expectEqual(@as(?u32, 4), ic.lookupSlotMode(&shapes[4], false));
    var retained_secondary: usize = 0;
    for (shapes[1..4]) |*shape| if (ic.lookupSlotMode(shape, false) != null) {
        retained_secondary += 1;
    };
    try std.testing.expectEqual(@as(usize, 2), retained_secondary);
}

test "InlineCache seqlock: concurrent writers never tear shape-slot pairs" {
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
