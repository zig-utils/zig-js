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

    pub const Snapshot = struct {
        shapes: [4]?*Shape = @splat(null),
        slots: [4]u32 = @splat(0),
        inherited_receiver_shape: ?*Shape = null,
        inherited_receiver_shape_is_null: bool = false,
        inherited_holder_shape: ?*Shape = null,
        inherited_slot: u32 = 0,
    };

    shape: ?*Shape = null,
    slot: u32 = 0,
    secondary_shapes: [3]?*Shape = .{ null, null, null },
    secondary_slots: [3]u32 = .{ 0, 0, 0 },
    next_secondary: u32 = 0,
    /// One advisory one-hop prototype-chain observation. The holder shape is
    /// the presence bit; the separate bool represents a receiver with no own
    /// shape, which is distinct from an empty observation.
    inherited_receiver_shape: ?*Shape = null,
    inherited_receiver_shape_is_null: bool = false,
    inherited_holder_shape: ?*Shape = null,
    inherited_slot: u32 = 0,
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

    /// Copy a stable four-entry shape/slot view for immutable optimized-code
    /// metadata. Parallel readers use the same version bracket as live cache
    /// lookups; contention returns null so compilation can safely omit the
    /// advisory snapshot instead of ever owning a torn pair.
    pub fn snapshotMode(ic: *const InlineCache, parallel: bool) ?Snapshot {
        if (parallel) return ic.loadSnapshot();
        return .{
            .shapes = .{ ic.shape, ic.secondary_shapes[0], ic.secondary_shapes[1], ic.secondary_shapes[2] },
            .slots = .{ ic.slot, ic.secondary_slots[0], ic.secondary_slots[1], ic.secondary_slots[2] },
            .inherited_receiver_shape = ic.inherited_receiver_shape,
            .inherited_receiver_shape_is_null = ic.inherited_receiver_shape_is_null,
            .inherited_holder_shape = ic.inherited_holder_shape,
            .inherited_slot = ic.inherited_slot,
        };
    }

    pub inline fn recordInheritedMode(
        ic: *InlineCache,
        receiver_shape: ?*Shape,
        holder_shape: *Shape,
        slot: u32,
        parallel: bool,
    ) void {
        if (parallel) {
            ic.tryStoreInherited(receiver_shape, holder_shape, slot);
            return;
        }
        ic.inherited_receiver_shape = receiver_shape;
        ic.inherited_receiver_shape_is_null = receiver_shape == null;
        ic.inherited_slot = slot;
        ic.inherited_holder_shape = holder_shape;
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

    fn loadSnapshot(ic: *const InlineCache) ?Snapshot {
        const v1 = ic.version.load(.seq_cst);
        if (v1 & 1 != 0) return null;
        var snapshot = Snapshot{};
        snapshot.shapes[0] = @atomicLoad(?*Shape, &ic.shape, .seq_cst);
        snapshot.slots[0] = @atomicLoad(u32, &ic.slot, .seq_cst);
        inline for (0..ic.secondary_shapes.len) |index| {
            snapshot.shapes[index + 1] = @atomicLoad(?*Shape, &ic.secondary_shapes[index], .seq_cst);
            snapshot.slots[index + 1] = @atomicLoad(u32, &ic.secondary_slots[index], .seq_cst);
        }
        snapshot.inherited_receiver_shape = @atomicLoad(?*Shape, &ic.inherited_receiver_shape, .seq_cst);
        snapshot.inherited_receiver_shape_is_null = @atomicLoad(bool, &ic.inherited_receiver_shape_is_null, .seq_cst);
        snapshot.inherited_holder_shape = @atomicLoad(?*Shape, &ic.inherited_holder_shape, .seq_cst);
        snapshot.inherited_slot = @atomicLoad(u32, &ic.inherited_slot, .seq_cst);
        if (ic.version.load(.seq_cst) != v1) return null;
        return snapshot;
    }

    fn tryStoreInherited(ic: *InlineCache, receiver_shape: ?*Shape, holder_shape: *Shape, slot: u32) void {
        const v = ic.version.load(.seq_cst);
        if (v & 1 != 0) return;
        if (ic.version.cmpxchgStrong(v, v +% 1, .seq_cst, .seq_cst) != null) return;
        @atomicStore(?*Shape, &ic.inherited_receiver_shape, receiver_shape, .seq_cst);
        @atomicStore(bool, &ic.inherited_receiver_shape_is_null, receiver_shape == null, .seq_cst);
        @atomicStore(u32, &ic.inherited_slot, slot, .seq_cst);
        @atomicStore(?*Shape, &ic.inherited_holder_shape, holder_shape, .seq_cst);
        ic.version.store(v +% 2, .seq_cst);
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
    def_var, // a: name index; b: 0 create var if absent, 1 var initializer, 2 internal define, 3 variable-scope function
    def_lex, // operand a: name index, b: 1 let / 2 const / 3 let-TDZ / 4 const-TDZ; pop value, define lexical binding
    init_declarations, // instantiate this chunk's environment declaration plan before evaluation
    copy_annex_b, // a: candidate index; copy the current block binding to the exact variable record if enabled
    bind_pattern, // operand a: pattern index, b: mode (0 var, 1 let, 2 const, 3 assign); pop value, destructure into the pattern
    resolve_binding_ref, // operand a: binding-reference plan; capture ResolveBinding before later observable work
    load_binding_ref, // operand a: plan, b: binding_ref_load_* flags; GetValue through the captured Reference
    clear_binding_ref, // operand a: plan; release a retained Reference on a short-circuit path
    store_binding_ref, // operand a: binding-reference plan; pop value, PutValue through the captured Reference

    // --- locals & upvalues (resolved to frame slots at compile time) ---
    init_local_lexical, // operand a: slot; reset binding to TDZ on scope entry
    load_local, // operand a: slot in the current frame
    load_local_mapped, // operand a: slot whose sloppy parameter may use an arguments-map cell
    load_local_lexical, // operand a: slot; ReferenceError while in TDZ
    store_local, // operand a: slot; assign, leave value on stack
    store_local_mapped, // operand a: slot whose sloppy parameter may use an arguments-map cell
    store_local_lexical, // operand a: slot, b: immutable; checked assignment, leave value
    load_upval, // operand a: parent depth, b: slot
    load_upval_mapped, // operand a: parent depth, b: mapped sloppy-parameter slot
    load_upval_lexical, // operand a: parent depth, b: slot; TDZ-checked
    store_upval, // operand a: parent depth, b: slot; leave value on stack
    store_upval_mapped, // operand a: parent depth, b: mapped sloppy-parameter slot
    store_upval_lexical, // operand a: depth, b: slot | immutable high bit; checked assignment

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
    require_object_coercible, // pop; throw for null/undefined; a: 0 binding-pattern message, 1 property-reference message; b: for a==0, 1+name index of the pattern's first static key (0 = none)
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
    jump_env, // operands a: target PC, b: target activation-local environment depth
    jump_if_false, // pop cond; jump when falsy
    jump_if_true_peek, // peek cond (leave on stack); jump when truthy  [for ||]
    jump_if_false_peek, // peek cond (leave on stack); jump when falsy   [for &&]
    jump_if_nullish_peek, // peek cond; jump when null/undefined         [for ??]
    jump_if_not_nullish_peek, // peek cond; jump when not null/undefined [for ??]

    // --- objects, arrays, members ---
    load_this, // push the current `this`
    load_new_target, // push the current `new.target`
    enter_field_initializers, // enter the lexical class-field initializer context
    exit_field_initializers, // leave the lexical class-field initializer context
    load_super_constructor, // capture GetSuperConstructor before argument effects
    load_import_meta, // push the active declaring module's lazily created import.meta object
    new_object, // push a fresh {}
    new_array, // push a fresh []
    collect_rest_parameter, // operand a: frame slot; create the pending call-tail Array at this exact parameter-entry point
    init_prop, // operand a: name index, b: literal function flags; pop value, define own data prop on object at top, leave object
    init_proto, // pop value; if object/null set it as the [[Prototype]] of object at top (the `__proto__: v` colon form), leave object
    init_prop_computed, // operand a: literal function flags; pop value then canonical key, define own data prop, leave object
    object_rest, // operand a: excluded-key count; pop keys then source, push CopyDataProperties result
    init_spread, // pop source, CopyDataProperties into object at top, leave object
    init_getter, // pop fn, pop key; install getter on object at top, leave object
    init_setter, // pop fn, pop key; install setter on object at top, leave object
    array_append, // pop value, append to the array at top, leave array
    array_spread, // pop iterable, spread its elements into the array now at top, leave array
    get_prop, // operand a: name index; pop object -> push object[name]
    get_private_name, // operand a: raw private-name index; resolve the active PrivateEnvironment, pop object -> push object[#name]
    super_get, // operand a: name index; push super.[name] (home_object.proto[name], receiver = this)
    super_get_index, // pop key; push super[key] (home_object.proto[key], receiver = this)
    check_super_this, // validate the active home object and initialized this binding
    super_base, // operand a: require non-null; push the current home-object prototype (or null)
    super_get_from, // operand a: name index; pop captured base -> push base[name] with receiver = this
    super_get_index_from, // pop key, captured base -> push base[key] with receiver = this
    enter_block, // push a declarative Environment; a: block_environment_* flags
    exit_block, // pop that Environment; a: block_environment_class restores class strictness
    dispose_scope, // DisposeResources for the current Environment Record
    dispose_scope_completion, // DisposeResources for the current scope with the [value, kind] completion on the stack: a throw completion is threaded as the pending error, and a disposal error replaces the record with a throw completion
    dispose_seed_completion, // async DisposeResources, step 1: move a throw completion's value into the scope's pending error and rewrite the record to a normal completion; other completions are left in place
    dispose_record_error, // async DisposeResources: pop a thrown value (a rejected [Symbol.asyncDispose] await, or the sync tail's throw) and fold it into the scope's pending error (SuppressedError chaining)
    enter_with, // pop object; push an object Environment Record (with_object = ToObject(it)) onto vm.env
    exit_with, // pop the innermost with/block environment off vm.env (restore its parent)
    make_regex, // operands a: pattern name index, b: flags name index; push a fresh RegExp object
    register_disposable, // pop the resource and register it for DisposeResources: a = 1 for `await using`; b = how many Environment Records above the current one hold the scope (a `for (using …;;)` head registers beneath its per-iteration lexical record)
    array_append_hole, // append an array-literal elision (a hole that reads as absent) to the array on the stack top
    call_eval, // operand a: argc; a bare `eval(args)` — marks direct-eval so a real eval runs in the current scope
    call_eval_with_this, // operand a: argc; explicit WithBaseObject, direct only for the eval intrinsic
    call_eval_activation, // operands a: argc, b: DirectEvalPlan; expose the live ordinary activation only for the eval intrinsic
    call_eval_activation_with_this, // operands a: argc, b: DirectEvalPlan; explicit WithBaseObject form
    import_call, // operand a: phase name index; pop options, pop specifier -> push import() promise
    get_index, // pop key, pop object -> push object[key]
    set_prop, // operand a: name index; pop value, pop object -> push value (after set)
    set_private_name, // operand a: raw private-name index; resolve the active PrivateEnvironment, pop value/object -> push value
    set_index, // pop value, pop key, pop object -> push value (after set)
    init_class_field, // operand a: encoded name; pop value/object, CreateDataPropertyOrThrow, push value
    init_private_field, // operand a: private name; pop value, PrivateFieldAdd on this, push value
    super_set_from, // operands a: name index, b: strict; pop value/base, [[Set]] with receiver = this, push value
    super_set_index_from, // operand a: strict; pop value/key/base, [[Set]] with receiver = this, push value
    delete_super, // validate the SuperReference and throw its mandatory ReferenceError
    delete_name, // operands a: name index, b: activation-local environment search depth (or delete_name_full_environment_depth)
    delete_prop, // operands a: name index, b: strict; pop object -> push [[Delete]] result
    delete_index, // operand a: strict; pop key, pop object -> push [[Delete]] result
    instance_of, // pop rhs, pop lhs -> push (lhs instanceof rhs)
    private_in, // operand a: resolved private-name index; pop rhs object -> push (#name in rhs)
    private_name_in, // operand a: raw private-name index; resolve the active PrivateEnvironment, pop rhs -> push (#name in rhs)

    // --- functions ---
    make_closure, // operand: fn-template index; push a Function value capturing env
    call, // operand a: argc; stack: callee, arg0..argN-1 -> push result
    call_method, // operand a: name index, b: argc; stack: recv, args... -> push result
    tail_call, // operand a: argc; stack: callee, arg0..argN-1 -> replace current activation
    tail_call_eval, // operand a: argc; direct-eval aware tail-position call
    tail_call_eval_with_this, // operand a: argc; direct-eval-aware tail call with explicit WithBaseObject
    tail_call_eval_activation, // operands a: argc, b: DirectEvalPlan; direct eval over the retiring ordinary activation
    tail_call_eval_activation_with_this, // operands a: argc, b: DirectEvalPlan; explicit WithBaseObject form
    tail_call_method, // operand a: name index, b: argc; stack: recv, args... -> tail call recv.name
    tail_call_with_this, // operand a: argc; stack: func, this, args... -> tail call func with this
    new_call, // operand a: argc; stack: callee, args... -> push constructed object
    super_construct, // operand a: argc; stack: captured super, args... -> bind derived this and push it
    super_construct_spread, // stack: captured super, args array -> bind derived this and push it
    super_construct_default, // operand a: rest-parameter slot; direct-forward without @@iterator
    // Spread-argument variants: the arguments are pre-collected into one array
    // (built with new_array/array_append/array_spread), so the call is variadic.
    call_spread, // stack: callee, args_array -> push result (this = undefined)
    call_eval_spread, // stack: eval candidate, args_array -> push direct/indirect eval result
    call_eval_with_this_spread, // stack: eval candidate, this, args_array -> push direct/indirect eval result
    call_eval_activation_spread, // operand a: DirectEvalPlan; stack: eval candidate, args_array
    call_eval_activation_with_this_spread, // operand a: DirectEvalPlan; stack: eval candidate, this, args_array
    tail_call_eval_activation_spread, // operand a: DirectEvalPlan; tail-position spread direct eval
    tail_call_eval_activation_with_this_spread, // operand a: DirectEvalPlan; explicit WithBaseObject tail-position form
    call_with_this_spread, // stack: callee, this, args_array -> push result
    tail_call_spread, // stack: callee, args_array -> replace current activation
    tail_call_with_this_spread, // stack: callee, this, args_array -> replace current activation
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
    iter_of, // pop iterable -> GetIterator's iterator object; compiled site captures `.next` once
    async_iter_of, // pop iterable -> push its async iterator (Symbol.asyncIterator, else a sync iterator); for `for await`
    enum_keys, // pop value -> push [ToObject target, owned candidate array, cursor]
    enum_next, // peek state -> advance one candidate, push [key, present, has candidate]
    enum_end_completion, // remove enumeration state below a pending [completion value, kind]
    iter_close, // pop iterator; normal-completion IteratorClose (call return() if present, validate result is Object)
    iter_close_completion, // pop iterator; IteratorClose while [completion-value, kind] is beneath it, preserving throw completions
    async_iter_close, // pop async iterator -> push return result and has-return flag; caller awaits/validates when present
    async_iter_close_completion, // async_iter_close while [completion-value, kind] is beneath it, preserving throw completions during GetMethod/Call
    prepare_class_heritage, // pop raw extends value; validate once, push normalized constructor + prototype roots
    prepare_class_private_environment, // operand a: class template; create/publish its per-evaluation PrivateEnvironment after heritage
    scratch_store, // operand a: scratch slot; pop -> activation-local program scratch[a] (#706)
    scratch_load, // operand a: scratch slot; push activation-local program scratch[a]
    eval_class, // operand a: class template index, b: total inferred-name + heritage + computed-name inputs
    template_object, // operand a: template-site AST index; push the cached, frozen GetTemplateObject strings array for that tagged-template site

    throw_op, // pop -> set as the in-flight exception and unwind (error.Throw)
    throw_not_a_reference, // operand a: interp.NotAReference shape; throw the Annex-B ReferenceError for a call-expression assignment target (the call itself was already evaluated and popped)

    // --- exception handling (generator VM) ---
    push_handler, // operand a: catch-block PC (or u32 max = none), b: finally-block PC (or none)
    push_handler_catch, // same targets; catch value stays on stack, but recorded unwind depth excludes it
    push_handler_outer, // same targets; record the parent environment/depth for a captured catch binding
    pop_handler, // discard the topmost handler (on normal exit from a try block)
    push_completion, // operand a: completion kind (0 = normal); push [undefined, kind] for a finally block
    end_finally, // pop a completion [value, kind] left by a finally: rethrow (1) / return (2) / break (3) / continue (4) / fall-through (0)
    abrupt_break, // operands a: break target PC, b: target environment depth (low 16) | handlers to pop (high 16); pops exactly those, running each finally among them, then jumps
    abrupt_continue, // operands a: continue target PC, b: as abrupt_break

    halt, // end program; result is the accumulator
};

/// A single instruction. `a` is the primary operand (const/name/fn index, jump
/// target, or argc); `b` is a secondary operand for operations such as
/// `call_method` (name + argument count) and `delete_prop` (name + strictness).
/// Annex B (sec-runtime-errors-for-function-call-assignment-targets): in
/// sloppy code a call expression is accepted as an assignment target at parse
/// time and rejected when evaluated — the call runs, then a ReferenceError is
/// thrown before the right-hand side (or the loop value) is touched.
/// JavaScriptCore words the error by the syntactic shape; both tiers use this.
pub const NotAReference = enum(u8) {
    assignment,
    prefix_inc,
    prefix_dec,
    postfix_inc,
    postfix_dec,
    for_in,
    for_of,

    pub fn message(self: NotAReference) []const u8 {
        return switch (self) {
            .assignment => "Left side of assignment is not a reference.",
            .prefix_inc => "Prefix ++ operator applied to value that is not a reference.",
            .prefix_dec => "Prefix -- operator applied to value that is not a reference.",
            .postfix_inc => "Postfix ++ operator applied to value that is not a reference.",
            .postfix_dec => "Postfix -- operator applied to value that is not a reference.",
            .for_in => "Left side of for-in statement is not a reference.",
            .for_of => "Left side of for-of statement is not a reference.",
        };
    }

    pub fn update(inc: bool, prefix: bool) NotAReference {
        return if (prefix) (if (inc) .prefix_inc else .prefix_dec) else (if (inc) .postfix_inc else .postfix_dec);
    }
};

pub const Inst = struct {
    op: Op,
    a: u32 = 0,
    b: u32 = 0,
};

/// PropertyDefinitionEvaluation intent belongs to syntax, not the stored
/// callable: copying a method must not change its [[HomeObject]] or name.
pub const literal_function_method: u32 = 1 << 0;
pub const literal_function_anonymous: u32 = 1 << 1;

/// `delete_name` searches the complete Environment chain for name-backed
/// generator/async/program bindings. Any smaller operand bounds the search
/// before a statically resolved non-deletable frame/upvalue binding.
pub const delete_name_full_environment_depth: u32 = std.math.maxInt(u32);

/// Static PutValue fallback used when a bounded ResolveBinding walk reaches the
/// frame boundary without an intervening declarative/`with` Environment Record.
/// The dynamic winner itself lives activation-locally in `vm.Exec`; this plan is
/// immutable chunk metadata and therefore safe to share across invocations.
pub const BindingReferenceFallback = struct {
    op: Op,
    a: u32 = 0,
    b: u32 = 0,
};

pub const BindingReferencePlan = struct {
    name_index: u32,
    /// `delete_name_full_environment_depth` means search the complete lexical
    /// chain and capture either an exact Environment/global-object base or an
    /// unresolvable Reference. Smaller values stop before a statically known
    /// frame/upvalue binding and select `fallback`.
    environment_depth: u32,
    /// A parameter binding can acquire a nearer body VariableEnvironment
    /// binding after sloppy direct eval. When present, ResolveBinding probes
    /// this exact defining frame's lazily materialized variable record after
    /// the ordinary bounded lexical walk, before selecting `fallback`.
    direct_eval_frame_depth: ?u32 = null,
    fallback: BindingReferenceFallback,
};

/// One user-visible binding in a slot-backed ordinary activation. Direct eval
/// consumes these immutable, name-sorted descriptors to expose the *live* frame
/// cell through a Declarative Environment Record; values are deliberately not
/// copied into the plan. Compiler-only NUL-prefixed temporaries never appear.
pub const DirectEvalBinding = struct {
    name: []const u8,
    slot: u32,
    lexical: bool,
    immutable: bool,
    tdz_checked: bool,
    mapped_parameter: bool,
};

pub const block_environment_class: u32 = 1;
pub const block_environment_simple_catch: u32 = 2;

pub const DirectEvalScopeKind = enum {
    parameter,
    variable,
    lexical,
};

/// One declarative scope visible at a direct-eval call site. Parameter and body
/// variable records are distinct persistent views over one activation; lexical
/// records are transient call-site wrappers. Exactly one non-lexical record is
/// the declaration target for the direct eval represented by the plan.
pub const DirectEvalScope = struct {
    bindings: []const DirectEvalBinding,
    kind: DirectEvalScopeKind,
    declaration_target: bool = false,
    /// Annex B.3.5 exempts the declarative record for a lone catch
    /// BindingIdentifier from sloppy eval `var`/function conflicts. This is a
    /// property of the scope record, not of the binding, because destructuring
    /// catch parameters deliberately retain the ordinary conflict rule.
    is_catch_param: bool = false,
    /// Number of defining-frame links from the currently running activation.
    /// Zero addresses the direct-eval caller; one addresses its captured outer
    /// frame, and so on.
    frame_depth: u32,
    /// Runtime records outside this lexical scope but inside its defining
    /// frame. This places frame-backed block/catch cells on the correct side
    /// of captured `with`, loop, and class records instead of flattening them.
    environment_depth: u32 = 0,
};

/// Runtime Environment Records captured between one ordinary activation and
/// its defining parent frame. `child_frame_depth == 0` is the direct-eval
/// caller. The immutable count is validated against each Frame's exact
/// `closure_environment` edge before an interleaved chain can be published.
pub const DirectEvalFrameBoundary = struct {
    child_frame_depth: u32,
    environment_depth: u32,
};

/// Exact static scope stack for one direct-eval call site. Runtime Environment
/// Records (captured loop heads, `with`, disposal scopes) are not flattened into
/// binding snapshots. Boundary counts and lexical-scope depths place captured
/// records without mutating their published parent links. The current frame's
/// active segment is separate from the immutable captured frame boundaries.
pub const DirectEvalPlan = struct {
    scopes: []const DirectEvalScope,
    frame_boundaries: []const DirectEvalFrameBoundary = &.{},
    current_environment_depth: u32 = 0,
};

/// `load_binding_ref` keeps the Reference for a later PutValue when `retain` is
/// set; otherwise it clears the activation slot after GetValue. `with_base`
/// pushes `[base, value]` so identifier calls can preserve WithBaseObject, and
/// `allow_unresolvable` implements typeof's unresolvable-reference exception.
pub const binding_ref_load_retain: u32 = 1 << 0;
pub const binding_ref_load_with_base: u32 = 1 << 1;
pub const binding_ref_load_allow_unresolvable: u32 = 1 << 2;

const OptimizerBinaryProfile = struct {
    lhs_kinds: std.atomic.Value(u8) = .init(0),
    rhs_kinds: std.atomic.Value(u8) = .init(0),
    quick: QuickBinaryState = .{},

    fn observe(self: *OptimizerBinaryProfile, lhs: jit.ProfileValueKind, rhs: jit.ProfileValueKind) void {
        observeKind(&self.lhs_kinds, lhs);
        observeKind(&self.rhs_kinds, rhs);
    }

    fn observeKind(kinds: *std.atomic.Value(u8), kind: jit.ProfileValueKind) void {
        const bit = @as(u8, 1) << @backingInt(kind);
        // The profile is monotonic. Once a worker sees this bit, repeating the
        // read-modify-write cannot add information and only makes every shared
        // execution lane contend on the same byte. A stale load may perform one
        // redundant OR, but atomic ORs still converge without losing a kind.
        if (kinds.load(.monotonic) & bit == 0) _ = kinds.fetchOr(bit, .monotonic);
    }

    fn requiresRuntime(self: *const OptimizerBinaryProfile) bool {
        const number = @as(u8, 1) << @backingInt(jit.ProfileValueKind.number);
        return (self.lhs_kinds.load(.acquire) | self.rhs_kinds.load(.acquire)) & ~number != 0;
    }
};

/// Race-free adaptive state for one binary bytecode. Values below the Number
/// threshold are an observation count; the two terminal tags keep stable
/// Number sites off the optimizer-profile atomics while permanently declining
/// specialization after any dynamic operand appears. The state contains no
/// managed pointer and dies with the owning Chunk arena.
pub const QuickBinaryState = struct {
    raw: std.atomic.Value(u8) = .init(0),

    pub const number_threshold: u8 = 8;
    const number_tag: u8 = 0xfe;
    const generic_tag: u8 = 0xff;

    pub const Mode = enum { observing, number, generic };

    pub fn mode(self: *const QuickBinaryState) Mode {
        // The tag publishes no associated data: atomic modification order alone
        // is sufficient, and the VM's hot read must not impose an acquire fence.
        return switch (self.raw.load(.monotonic)) {
            number_tag => .number,
            generic_tag => .generic,
            else => .observing,
        };
    }

    /// Record one complete Number/Number execution. Returns true only to the
    /// lane that publishes the terminal Number state.
    pub fn observeNumber(self: *QuickBinaryState) bool {
        var observed = self.raw.load(.monotonic);
        while (observed != number_tag and observed != generic_tag) {
            const next: u8 = if (observed + 1 >= number_threshold) number_tag else observed + 1;
            observed = self.raw.cmpxchgWeak(observed, next, .release, .monotonic) orelse
                return next == number_tag;
        }
        return false;
    }

    /// One non-Number observation is enough to make the optimizer require its
    /// runtime operation. Generic is terminal: later numeric executions may
    /// retain the ordinary inline Number path but never republish specialization.
    pub fn observeGeneric(self: *QuickBinaryState) void {
        self.raw.store(generic_tag, .release);
    }

    /// Dequicken a published Number site. Returns true only to the lane that
    /// performs the Number -> generic transition; concurrent misses still run
    /// their own ordinary operation exactly once.
    pub fn dequicken(self: *QuickBinaryState) bool {
        return self.raw.cmpxchgStrong(number_tag, generic_tag, .acq_rel, .acquire) == null;
    }
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
pub const FnTemplateAdmission = enum {
    plain_compiled,
    plain_parameter_prologue,
    plain_unsupported_lowering,
    generator_compiled,
    async_compiled,
};

/// ClassDefinitionEvaluation captures the defining lexical environment for
/// methods and initializers. Only classes referencing real frame slots need a
/// live activation projection; eager heritage/keys remain ordinary bytecode.
pub const ClassTemplate = struct {
    node: *ast.Node,
    capture_environment: ?*const DirectEvalPlan = null,
    /// NamedEvaluation is syntax, not a post-construction property mutation.
    /// A computed name comes from the first rooted activation input instead.
    inferred_name: ?[]const u8 = null,
    name_from_stack: bool = false,
};

pub const FnTemplate = struct {
    /// Suspendable bodies resolve names through Environment Records rather than
    /// upvalue opcodes. Retain the exact defining activation/lexical projection.
    capture_environment: ?*const DirectEvalPlan = null,
    name: []const u8,
    /// Function declaration/expression node used to recover its exact registered
    /// source coordinates even when declaration instantiation is hoisted ahead
    /// of the first statement checkpoint.
    definition_node: *const ast.Node,
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
    /// Whether the defining ordinary-function scope contains direct eval. Such
    /// templates retain their dynamic-environment fallback even when they do
    /// not contain an explicit `arguments` IdentifierReference.
    uses_direct_eval: bool = false,
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
    /// Exact compiler decision for this nested template. A null `chunk` is
    /// therefore causal rather than an unclassified tree-walker fallback.
    admission: FnTemplateAdmission = .plain_unsupported_lowering,
    chunk: ?*Chunk,
    /// Number of frame slots (params + function-scoped declarations) the VM
    /// allocates per call.
    local_count: u32,
};

/// A unit of compiled code: the instruction stream plus its constant, name,
/// and function-template pools. All slices live in the owning arena.
pub const EnvironmentDeclarations = struct {
    pub const Lexical = struct { name: []const u8, immutable: bool };
    pub const AnnexB = struct { name: []const u8, create_binding: bool };
    lexical: []const Lexical = &.{},
    functions: []const []const u8 = &.{},
    variables: []const []const u8 = &.{},
    annex_b: []const AnnexB = &.{},
    is_script: bool = false,
};

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
    /// This chunk is the body of a derived class constructor. Return completion
    /// validates object/undefined results and reads the activation's bound `this`.
    is_derived_constructor: bool = false,
    /// Syntactic parameter index -> activation input slot. Simple/rest
    /// identifiers use their binding slot directly; a destructuring formal uses
    /// a hidden raw-value slot consumed by its bytecode entry prologue. Sloppy
    /// duplicate simple formals may share one binding slot.
    parameter_slots: []const u32 = &.{},
    /// Sorted syntactic indices whose raw input slots feed native array/object
    /// BindingInitialization at chunk entry. Empty keeps simple/rest entry
    /// metadata compact and branch-free.
    destructuring_parameter_indices: []const u32 = &.{},
    /// Sorted syntactic indices whose raw input is replaced at chunk entry only
    /// when it is exactly undefined. The compiler admits recursively safe value,
    /// public-read, call, and construction trees rooted in prior invocation state.
    default_parameter_indices: []const u32 = &.{},
    /// Syntactic index of the final rest formal. Its activation slot is
    /// `parameter_slots[index]`; for a destructuring rest formal this is the
    /// hidden raw-array slot consumed by its bytecode entry prologue. Null means
    /// every formal is positional. Rest mixed with defaults/patterns is created
    /// by `collect_rest_parameter` at the exact left-to-right entry point.
    rest_parameter_index: ?u32 = null,
    /// FunctionDeclarationInstantiation must create an unmapped arguments
    /// exotic for a non-simple formal list. Frozen here so calls never rescan
    /// parameter AST merely to select the arguments-object representation.
    has_non_simple_parameters: bool = false,
    /// Frame slot initialized with this ordinary function's arguments exotic
    /// object. Strict functions use it directly; sloppy simple-parameter
    /// functions additionally route the exact mapped parameter slots below.
    /// Null for program/env-mode chunks, arrows, and functions that cannot
    /// observe `arguments`.
    arguments_slot: ?u32 = null,
    /// Local slot -> arguments index for a sloppy simple parameter that owns a
    /// live [[ParameterMap]]. Unmapped slots contain `maxInt(u32)`. Empty for
    /// strict/unmapped owners and every chunk without a mapped arguments object.
    mapped_parameter_indices: []const u32 = &.{},
    /// Activation-local scratch slots for program chunks (#706). Program runs
    /// have neither a frame nor a private activation Environment, so compiler
    /// temporaries that must survive observable calls — resolved member
    /// references above all — live in an Exec-owned, GC-rooted `Value` array
    /// sized by this count. Function and env-mode chunks leave it at zero.
    scratch_count: u32 = 0,
    /// Immutable names/kinds only. Runtime global eligibility belongs to each
    /// Exec, never the shared chunk; frame-mode functions need no such plan.
    environment_declarations: EnvironmentDeclarations = .{},
    /// Frame slots in chunks whose control flow can observe a lexical TDZ.
    /// Activations initialize these before the first debugger checkpoint;
    /// block-entry opcodes reset them when a lexical scope is re-entered.
    lexical_slots: []const u32 = &.{},
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
    /// Immutable capture plans for identifier References whose environment
    /// resolution must precede iterator/property/default side effects. Each
    /// plan also owns one activation-local `Exec.binding_references` slot.
    binding_reference_plans: std.ArrayListUnmanaged(BindingReferencePlan) = .empty,
    /// Slot-backed Environment views required by ordinary-function direct eval.
    /// Plans contain binding identity/kind only; activation values remain in the
    /// frame so reads, writes, mapped arguments, TDZ, and escaping closures share
    /// one live cell rather than a snapshot.
    direct_eval_plans: std.ArrayListUnmanaged(DirectEvalPlan) = .empty,
    /// Plan whose declaration target is this activation's ParameterEnvironment.
    /// The VM materializes it before initializer bytecode so closures created by
    /// an earlier default share the record with vars introduced by a later eval.
    parameter_direct_eval_plan: ?u32 = null,
    /// Class-expression AST nodes referenced by `eval_class`; the compiler
    /// evaluates and prepares heritage plus any suspendable computed names first,
    /// then the VM delegates construction back to the interpreter while the
    /// activation-local class Environment remains active.
    classes: std.ArrayListUnmanaged(ClassTemplate) = .empty,
    /// Tagged-template AST nodes referenced by `template_object`; the VM asks the
    /// interpreter for the per-site cached+frozen strings object (GetTemplateObject).
    templates: std.ArrayListUnmanaged(*ast.Node) = .empty,
    /// One inline cache per instruction, allocated by `finalize` once the code
    /// stream is complete. Warm across runs of the same chunk.
    ics: []InlineCache = &.{},
    /// Instruction-local operand observations and adjacent byte-sized adaptive
    /// state for arithmetic/comparison sites. Keeping them separate from the
    /// coarse function result profile lets the optimizer retain Number-specialized
    /// lowering while the VM avoids a second instruction-indexed cache lookup.
    optimizer_binary_profiles: []OptimizerBinaryProfile = &.{},
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
        self.optimizer_binary_profiles = try self.arena.alloc(OptimizerBinaryProfile, self.code.items.len);
        @memset(self.optimizer_binary_profiles, .{});
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

    pub fn observeOptimizerBinary(
        self: *Chunk,
        instruction: usize,
        lhs: jit.ProfileValueKind,
        rhs: jit.ProfileValueKind,
    ) void {
        if (instruction < self.optimizer_binary_profiles.len)
            self.optimizer_binary_profiles[instruction].observe(lhs, rhs);
    }

    pub fn optimizerBinaryRequiresRuntime(self: *const Chunk, instruction: usize) bool {
        return instruction < self.optimizer_binary_profiles.len and
            self.optimizer_binary_profiles[instruction].requiresRuntime();
    }

    pub fn quickBinaryState(self: *Chunk, instruction: usize) ?*QuickBinaryState {
        return if (instruction < self.optimizer_binary_profiles.len) &self.optimizer_binary_profiles[instruction].quick else null;
    }

    /// Emit an instruction, returning its index (for later jump back-patching).
    pub fn emit(self: *Chunk, op: Op, a: u32) std.mem.Allocator.Error!usize {
        const idx = self.code.items.len;
        try self.code.append(self.arena, .{ .op = op, .a = a });
        return idx;
    }

    /// Emit an instruction with both operands.
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

    pub fn addBindingReferencePlan(self: *Chunk, plan: BindingReferencePlan) std.mem.Allocator.Error!u32 {
        const idx: u32 = @intCast(self.binding_reference_plans.items.len);
        try self.binding_reference_plans.append(self.arena, plan);
        return idx;
    }

    pub fn addDirectEvalPlan(self: *Chunk, plan: DirectEvalPlan) std.mem.Allocator.Error!u32 {
        const idx: u32 = @intCast(self.direct_eval_plans.items.len);
        try self.direct_eval_plans.append(self.arena, plan);
        return idx;
    }

    pub fn addTemplate(self: *Chunk, node: *ast.Node) std.mem.Allocator.Error!u32 {
        const idx: u32 = @intCast(self.templates.items.len);
        try self.templates.append(self.arena, node);
        return idx;
    }

    pub fn addClass(self: *Chunk, node: *ast.Node, capture_environment: ?*const DirectEvalPlan) std.mem.Allocator.Error!u32 {
        const idx: u32 = @intCast(self.classes.items.len);
        try self.classes.append(self.arena, .{ .node = node, .capture_environment = capture_environment });
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

test "InlineCache snapshots stable polymorphic pairs and rejects an active writer" {
    var shapes: [4]Shape = undefined;
    var cache = InlineCache{};
    for (&shapes, 0..) |*shape, index| cache.recordMode(shape, @intCast(index + 7), false);

    const isolated = cache.snapshotMode(false).?;
    const parallel = cache.snapshotMode(true).?;
    for (&shapes, 0..) |*shape, index| {
        try std.testing.expectEqual(shape, isolated.shapes[index].?);
        try std.testing.expectEqual(@as(u32, @intCast(index + 7)), isolated.slots[index]);
        try std.testing.expectEqual(shape, parallel.shapes[index].?);
        try std.testing.expectEqual(@as(u32, @intCast(index + 7)), parallel.slots[index]);
    }

    cache.version.store(1, .seq_cst);
    try std.testing.expect(cache.snapshotMode(true) == null);
    cache.version.store(2, .seq_cst);
}

test "optimizer binary profiles remain instruction-local and preserve numeric sites" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var chunk = Chunk.init(arena.allocator());
    const numeric = try chunk.emit(.add, 0);
    const dynamic = try chunk.emit(.sub, 0);
    try chunk.finalize();

    try std.testing.expectEqual(@as(usize, 3), @sizeOf(OptimizerBinaryProfile));
    try std.testing.expectEqual(
        @intFromPtr(&chunk.optimizer_binary_profiles[numeric].quick),
        @intFromPtr(chunk.quickBinaryState(numeric).?),
    );
    try std.testing.expect(!chunk.optimizerBinaryRequiresRuntime(numeric));
    try std.testing.expect(!chunk.optimizerBinaryRequiresRuntime(dynamic));
    chunk.observeOptimizerBinary(numeric, .number, .number);
    chunk.observeOptimizerBinary(dynamic, .object, .number);
    try std.testing.expect(!chunk.optimizerBinaryRequiresRuntime(numeric));
    try std.testing.expect(chunk.optimizerBinaryRequiresRuntime(dynamic));
}

test "optimizer binary profile observations merge race-free" {
    var profile = OptimizerBinaryProfile{};
    const kinds = std.meta.tags(jit.ProfileValueKind);
    const Shared = struct {
        profile: *OptimizerBinaryProfile,
        go: std.atomic.Value(bool) = .init(false),

        fn observe(shared: *@This(), kind: jit.ProfileValueKind, inverse: jit.ProfileValueKind) void {
            while (!shared.go.load(.acquire)) std.atomic.spinLoopHint();
            for (0..2_000) |_| shared.profile.observe(kind, inverse);
        }
    };

    var shared = Shared{ .profile = &profile };
    var threads: [kinds.len]std.Thread = undefined;
    for (&threads, kinds, 0..) |*thread, kind, index| {
        const inverse = kinds[kinds.len - index - 1];
        thread.* = try std.Thread.spawn(.{}, Shared.observe, .{ &shared, kind, inverse });
    }
    shared.go.store(true, .release);
    for (&threads) |thread| thread.join();

    const all_kinds = (@as(u8, 1) << @intCast(kinds.len)) - 1;
    try std.testing.expectEqual(all_kinds, profile.lhs_kinds.load(.acquire));
    try std.testing.expectEqual(all_kinds, profile.rhs_kinds.load(.acquire));
}

test "quick binary state is byte-sized and publishes bounded Number observations" {
    try std.testing.expectEqual(@as(usize, 1), @sizeOf(QuickBinaryState));
    var state = QuickBinaryState{};
    try std.testing.expectEqual(QuickBinaryState.Mode.observing, state.mode());
    for (1..QuickBinaryState.number_threshold) |_| {
        try std.testing.expect(!state.observeNumber());
        try std.testing.expectEqual(QuickBinaryState.Mode.observing, state.mode());
    }
    try std.testing.expect(state.observeNumber());
    try std.testing.expectEqual(QuickBinaryState.Mode.number, state.mode());
    try std.testing.expect(state.dequicken());
    try std.testing.expectEqual(QuickBinaryState.Mode.generic, state.mode());
    try std.testing.expect(!state.observeNumber());
    try std.testing.expect(!state.dequicken());
}

test "quick binary generic publication wins concurrent Number observations" {
    const builtin = @import("builtin");
    if (builtin.single_threaded) return error.SkipZigTest;

    const Shared = struct {
        state: QuickBinaryState = .{},
        start: std.atomic.Value(bool) = .init(false),

        fn numbers(self: *@This()) void {
            while (!self.start.load(.acquire)) std.atomic.spinLoopHint();
            for (0..10_000) |_| _ = self.state.observeNumber();
        }

        fn generic(self: *@This()) void {
            while (!self.start.load(.acquire)) std.atomic.spinLoopHint();
            for (0..1_000) |_| self.state.observeGeneric();
        }
    };

    var shared = Shared{};
    const number_lane_a = try std.Thread.spawn(.{}, Shared.numbers, .{&shared});
    const number_lane_b = try std.Thread.spawn(.{}, Shared.numbers, .{&shared});
    const generic_lane = try std.Thread.spawn(.{}, Shared.generic, .{&shared});
    shared.start.store(true, .release);
    number_lane_a.join();
    number_lane_b.join();
    generic_lane.join();
    try std.testing.expectEqual(QuickBinaryState.Mode.generic, shared.state.mode());
}

test "InlineCache observations merge race-free" {
    const builtin = @import("builtin");
    if (builtin.single_threaded) return error.SkipZigTest;

    const Shared = struct {
        profile: OptimizerBinaryProfile = .{},

        fn observe(shared: *@This(), lhs: jit.ProfileValueKind, rhs: jit.ProfileValueKind) void {
            for (0..10_000) |_| shared.profile.observe(lhs, rhs);
        }
    };

    var shared = Shared{};
    const t0 = try std.Thread.spawn(.{}, Shared.observe, .{ &shared, .number, .number });
    const t1 = try std.Thread.spawn(.{}, Shared.observe, .{ &shared, .string, .number });
    const t2 = try std.Thread.spawn(.{}, Shared.observe, .{ &shared, .object, .boolean });
    const t3 = try std.Thread.spawn(.{}, Shared.observe, .{ &shared, .null, .undefined });
    t0.join();
    t1.join();
    t2.join();
    t3.join();
    try std.testing.expect(shared.profile.requiresRuntime());
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
                if (s.ic.snapshotMode(true)) |snapshot| {
                    for (snapshot.shapes, snapshot.slots) |maybe_shape, sl| {
                        if (maybe_shape == s.s0 and sl != 0) s.torn.store(true, .release);
                        if (maybe_shape == s.s1 and sl != 1) s.torn.store(true, .release);
                    }
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
