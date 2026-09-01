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
//! `evaluate` calls, like a real global object). Lexical slots carry explicit
//! TDZ/immutability checks; compile-time lexical scopes assign distinct slots to
//! same-named block bindings in the shared activation frame, while captured loop
//! heads use per-iteration declarative environments.

const std = @import("std");
const ast = @import("ast.zig");
const annex_b = @import("annex_b.zig");
const bc = @import("bytecode.zig");
const agent = @import("agent.zig");

const Node = ast.Node;
const Chunk = bc.Chunk;
const value_mod = @import("value.zig");
const Value = value_mod.Value;

pub const CompileError = error{ Unsupported, OutOfMemory };

const SecureStringHashContext = struct {
    seed: u64,

    pub fn hash(context: @This(), value: []const u8) u64 {
        return std.hash.Wyhash.hash(context.seed, value);
    }

    pub fn eql(_: @This(), left: []const u8, right: []const u8) bool {
        return std.mem.eql(u8, left, right);
    }
};

/// Compiler plans use AST node identity, never structural equality. Hash the
/// exact arena address with the compilation secret instead of depending on
/// predictable allocator placement or ASLR for collision resistance.
const SecureIdentityHashContext = struct {
    seed: u64,

    pub fn hash(context: @This(), identity: usize) u64 {
        return std.hash.Wyhash.hash(context.seed, std.mem.asBytes(&identity));
    }

    pub fn eql(_: @This(), left: usize, right: usize) bool {
        return left == right;
    }
};

/// One lazy secret belongs to a complete compilation, including every nested
/// function and admission prepass. Compiler maps never escape into a Chunk, so
/// the state can remain stack-owned by the public compilation entry point.
const CompileHashState = struct {
    context: ?SecureStringHashContext = null,

    fn candidate(state: *@This()) std.mem.Allocator.Error!SecureStringHashContext {
        if (state.context) |context| return context;
        var seed_bytes: [@sizeOf(u64)]u8 = undefined;
        agent.engineIo().randomSecure(&seed_bytes) catch return error.OutOfMemory;
        return .{ .seed = std.mem.readInt(u64, &seed_bytes, .little) };
    }
};

fn SecureStringMapUnmanaged(comptime MapValue: type) type {
    const Index = std.HashMapUnmanaged(
        []const u8,
        MapValue,
        SecureStringHashContext,
        std.hash_map.default_max_load_percentage,
    );

    return struct {
        const Self = @This();

        index: Index = .empty,
        state: *CompileHashState,

        fn publish(self: *Self, context: SecureStringHashContext) void {
            if (self.state.context == null) self.state.context = context;
        }

        fn put(self: *Self, allocator: std.mem.Allocator, key: []const u8, value: MapValue) std.mem.Allocator.Error!void {
            const context = try self.state.candidate();
            try self.index.putContext(allocator, key, value, context);
            self.publish(context);
        }

        fn getOrPut(self: *Self, allocator: std.mem.Allocator, key: []const u8) std.mem.Allocator.Error!Index.GetOrPutResult {
            const context = try self.state.candidate();
            const result = try self.index.getOrPutContext(allocator, key, context);
            self.publish(context);
            return result;
        }

        fn get(self: *const Self, key: []const u8) ?MapValue {
            const context = self.state.context orelse return null;
            return self.index.getContext(key, context);
        }

        fn getPtr(self: *Self, key: []const u8) ?*MapValue {
            const context = self.state.context orelse return null;
            return self.index.getPtrContext(key, context);
        }

        fn contains(self: *const Self, key: []const u8) bool {
            const context = self.state.context orelse return false;
            return self.index.containsContext(key, context);
        }

        fn count(self: *const Self) usize {
            return self.index.count();
        }

        fn iterator(self: *const Self) Index.Iterator {
            return self.index.iterator();
        }

        fn keyIterator(self: *const Self) Index.KeyIterator {
            return self.index.keyIterator();
        }
    };
}

fn SecureIdentityMapUnmanaged(comptime MapValue: type) type {
    const Index = std.HashMapUnmanaged(
        usize,
        MapValue,
        SecureIdentityHashContext,
        std.hash_map.default_max_load_percentage,
    );

    return struct {
        const Self = @This();

        index: Index = .empty,

        fn put(
            self: *Self,
            allocator: std.mem.Allocator,
            state: *CompileHashState,
            identity: usize,
            value: MapValue,
        ) std.mem.Allocator.Error!void {
            const root_context = try state.candidate();
            const context = SecureIdentityHashContext{ .seed = root_context.seed };
            try self.index.putContext(allocator, identity, value, context);
            // A failed first insertion publishes neither capacity nor the
            // compilation-wide seed, so admission can retry from a clean root.
            if (state.context == null) state.context = root_context;
        }

        fn get(self: *const Self, state: *const CompileHashState, identity: usize) ?MapValue {
            const root_context = state.context orelse return null;
            return self.index.getContext(identity, .{ .seed = root_context.seed });
        }

        fn contains(self: *const Self, state: *const CompileHashState, identity: usize) bool {
            const root_context = state.context orelse return false;
            return self.index.containsContext(identity, .{ .seed = root_context.seed });
        }

        fn count(self: *const Self) usize {
            return self.index.count();
        }
    };
}

/// Whether the result of a top-level expression statement becomes the program's
/// completion value (`program`) or is discarded (`function`).
const Mode = enum { program, function };

/// One compiler-owned temporary whose storage belongs to one execution.
/// Functions use frame/activation bindings; program chunks have no frame and
/// therefore use Exec-owned scratch slots (#706).
const ActivationTemp = union(enum) {
    named: []const u8,
    environment_var: []const u8,
    scratch: u32,
};

const Loop = struct {
    breaks: std.ArrayListUnmanaged(usize) = .empty,
    continues: std.ArrayListUnmanaged(usize) = .empty,
    label: ?[]const u8 = null,
    /// A labeled non-loop statement is breakable but not continuable.
    is_loop: bool = true,
    /// A `switch` is breakable but not continuable: `break` targets it, but
    /// `continue` skips past it to the nearest enclosing loop.
    is_switch: bool = false,
    /// A label wrapper directly labels an iteration statement (possibly through
    /// more labels), so `continue label` resolves to that statement's loop.
    labels_iteration: bool = false,
    /// The `finally_depth` in effect where this loop/switch was entered. A
    /// `break`/`continue` targeting it needs an `abrupt_*` unwind only when it
    /// CROSSES a finally — i.e. the current finally_depth is deeper than this one.
    /// A loop that lives entirely inside a finally (same depth) breaks with a
    /// plain jump, so it does not disturb that finally's in-flight completion.
    finally_depth: u32 = 0,
    /// Activation-local environment depth at the target. A jump from a deeper
    /// repeated-body/block environment unwinds to this depth before resuming.
    environment_depth: u32 = 0,
    /// Runtime handler-stack depth at the target: how many `push_handler`s are
    /// live when control is at the loop/label/switch. A `break`/`continue` pops
    /// exactly `current - this` handlers — running the finally of each that has
    /// one — and no more, so it never enters the target's own for-in/for-of
    /// close handler or a try/finally that lexically encloses the target.
    handler_depth: u32 = 0,
    /// `active_finally` at the target. A break/continue issued from inside
    /// `current - this` finally bodies leaves that many [value, kind] completion
    /// records on the operand stack, which it discards before jumping.
    active_finally: u32 = 0,
};

const SlotBinding = struct {
    slot: u32,
    lexical: bool = false,
    immutable: bool = false,
    tdz_checked: bool = false,
    /// Sloppy simple-parameter binding whose storage is shared with one live
    /// arguments [[ParameterMap]] entry. Dedicated bytecodes keep the ordinary
    /// frame-slot hot path branch-free.
    mapped_parameter: bool = false,
    /// Captured loop-head lexicals live in a real declarative Environment
    /// Record so CreatePerIterationEnvironment can give closures fresh cells.
    /// They still participate in static name resolution, but emit name-based
    /// environment operations instead of frame-slot operations.
    environment: bool = false,
    /// This cell belongs to the outer ParameterEnvironment of a function with
    /// parameter expressions. A later body direct eval may create a nearer
    /// same-named binding, so body references retain an exact dynamic probe.
    parameter_with_eval_boundary: bool = false,
    /// Runtime records outside this lexical slot must not shadow it. This is
    /// the owning scope's boundary, not the depth at a later reference site.
    lexical_environment_depth: u32 = 0,
};

/// A function's local namespace: name → frame slot. Lexical bindings retain
/// their TDZ/immutability kind so identifier loads and assignments select the
/// checked opcodes; declarations themselves still use the unchecked store that
/// performs InitializeBinding.
const FnScope = struct {
    parent: ?*FnScope,
    function_body: ?*const Node = null,
    /// Exact declaration identity -> the distinct Annex B variable slot.
    /// This plan is compiler-owned and immutable before bytecode publication.
    annex_b_variables: SecureIdentityMapUnmanaged(u32) = .{},
    /// Which record of `parent` was visible when this function was created.
    /// A closure created by a parameter initializer must never resolve or
    /// materialize the parent's not-yet-created body VariableEnvironment.
    parent_binding_phase: FunctionBindingPhase = .body,
    hash_state: *CompileHashState,
    /// Runtime Environment Records between this frame and its parent frame at
    /// closure creation. Frame slots are not present in `vm.env`, so dynamic
    /// name resolution must stop at this boundary before falling back to an
    /// enclosing non-deletable slot.
    parent_environment_depth: u32 = 0,
    /// Complete runtime Environment segment captured between this frame and
    /// its defining parent frame for direct eval. Unlike name-resolution's
    /// `parent_environment_depth`, this includes a named function expression's
    /// immutable self-name record, which also sits outside the frame slots.
    parent_direct_eval_environment_depth: u32 = 0,
    /// Object Environment Records between this frame and its parent frame at
    /// closure creation. Kept separate from declarative environments so
    /// ordinary no-`with` slot accesses retain their direct bytecodes.
    parent_with_depth: u32 = 0,
    /// Non-null only when parameter expressions require a distinct outer
    /// ParameterEnvironment. `names` remains the inner body variable record.
    parameter_names: ?*SecureStringMapUnmanaged(SlotBinding) = null,
    body_direct_eval_boundary: bool = false,
    /// Sloppy direct eval can add bindings after a deferred class is created.
    /// Its defining view must retain this record even when no current slot
    /// name appears in the class body.
    may_extend_environment: bool = false,
    names: SecureStringMapUnmanaged(SlotBinding),
    lexical_scopes: std.ArrayListUnmanaged(*SecureStringMapUnmanaged(SlotBinding)) = .empty,
    /// Parallel to `lexical_scopes`: true only for the scope introduced by a
    /// lone catch BindingIdentifier. Direct eval needs the Environment Record
    /// identity to apply Annex B.3.5 without weakening destructuring catches.
    lexical_scope_is_catch_param: std.ArrayListUnmanaged(bool) = .empty,
    lexical_scope_environment_depth: std.ArrayListUnmanaged(u32) = .empty,
    slot_names: std.ArrayListUnmanaged([]const u8) = .empty,
    count: u32 = 0,
    lexical_slots: std.ArrayListUnmanaged(u32) = .empty,
    tdz_checks: bool = false,

    fn addLocal(self: *FnScope, arena: std.mem.Allocator, name: []const u8, lexical: bool, immutable: bool) CompileError!u32 {
        if (self.names.get(name)) |binding| return binding.slot;
        return self.addBinding(arena, &self.names, name, lexical, immutable, false);
    }

    fn addParameter(self: *FnScope, arena: std.mem.Allocator, name: []const u8) CompileError!u32 {
        const parameters = self.parameter_names orelse return self.addLocal(arena, name, false, false);
        if (parameters.get(name)) |binding| return binding.slot;
        const slot = try self.addBinding(arena, parameters, name, false, false, false);
        const binding = parameters.getPtr(name).?;
        binding.parameter_with_eval_boundary = self.body_direct_eval_boundary;
        // FunctionDeclarationInstantiation creates every formal binding before
        // evaluating the first initializer, but initializes them left-to-right.
        // Reuse the checked-slot machinery so a default that reaches a later
        // formal observes its exact TDZ rather than its raw call argument.
        binding.tdz_checked = true;
        try self.lexical_slots.append(arena, slot);
        return slot;
    }

    fn addBinding(self: *FnScope, arena: std.mem.Allocator, bindings: *SecureStringMapUnmanaged(SlotBinding), name: []const u8, lexical: bool, immutable: bool, parameter_with_eval_boundary: bool) CompileError!u32 {
        const slot = self.count;
        const tdz_checked = lexical and self.tdz_checks;
        try bindings.put(arena, name, .{
            .slot = slot,
            .lexical = lexical,
            .immutable = immutable,
            .tdz_checked = tdz_checked,
            .parameter_with_eval_boundary = parameter_with_eval_boundary,
            .lexical_environment_depth = if (lexical and self.lexical_scope_environment_depth.items.len != 0)
                self.lexical_scope_environment_depth.items[self.lexical_scope_environment_depth.items.len - 1]
            else
                0,
        });
        if (tdz_checked) try self.lexical_slots.append(arena, slot);
        try self.slot_names.append(arena, name);
        self.count += 1;
        return slot;
    }

    fn pushLexicalScope(self: *FnScope, arena: std.mem.Allocator) CompileError!void {
        return self.pushLexicalScopeAtDepth(arena, 0);
    }

    fn pushLexicalScopeAtDepth(self: *FnScope, arena: std.mem.Allocator, environment_depth: u32) CompileError!void {
        const bindings = try arena.create(SecureStringMapUnmanaged(SlotBinding));
        bindings.* = .{ .state = self.hash_state };
        try self.lexical_scopes.append(arena, bindings);
        try self.lexical_scope_is_catch_param.append(arena, false);
        try self.lexical_scope_environment_depth.append(arena, environment_depth);
    }

    fn popLexicalScope(self: *FnScope) void {
        _ = self.lexical_scopes.pop();
        _ = self.lexical_scope_is_catch_param.pop();
        _ = self.lexical_scope_environment_depth.pop();
    }

    fn markCurrentLexicalScopeCatchParameter(self: *FnScope) void {
        std.debug.assert(self.lexical_scope_is_catch_param.items.len == self.lexical_scopes.items.len);
        std.debug.assert(self.lexical_scope_is_catch_param.items.len != 0);
        self.lexical_scope_is_catch_param.items[self.lexical_scope_is_catch_param.items.len - 1] = true;
    }

    fn currentLexicalScope(self: *FnScope) *SecureStringMapUnmanaged(SlotBinding) {
        std.debug.assert(self.lexical_scopes.items.len != 0);
        return self.lexical_scopes.items[self.lexical_scopes.items.len - 1];
    }

    fn addLexical(self: *FnScope, arena: std.mem.Allocator, name: []const u8, immutable: bool) CompileError!u32 {
        const bindings = self.currentLexicalScope();
        if (bindings.get(name)) |binding| return binding.slot;
        return self.addBinding(arena, bindings, name, true, immutable, false);
    }

    fn addLexicalChecked(self: *FnScope, arena: std.mem.Allocator, name: []const u8, immutable: bool) CompileError!u32 {
        const bindings = self.currentLexicalScope();
        const slot = try self.addLexical(arena, name, immutable);
        const binding = bindings.getPtr(name).?;
        if (!binding.tdz_checked) {
            binding.tdz_checked = true;
            try self.lexical_slots.append(arena, slot);
        }
        return slot;
    }

    fn addEnvironmentLexical(self: *FnScope, arena: std.mem.Allocator, name: []const u8, immutable: bool) CompileError!void {
        const bindings = self.currentLexicalScope();
        if (bindings.contains(name)) return;
        try bindings.put(arena, name, .{
            .slot = 0,
            .lexical = true,
            .immutable = immutable,
            .tdz_checked = true,
            .environment = true,
        });
    }

    fn get(self: *const FnScope, name: []const u8) ?SlotBinding {
        var index = self.lexical_scopes.items.len;
        while (index > 0) {
            index -= 1;
            if (self.lexical_scopes.items[index].get(name)) |binding| return binding;
        }
        if (self.names.get(name)) |binding| return binding;
        if (self.parameter_names) |parameters| return parameters.get(name);
        return null;
    }

    fn getParameter(self: *const FnScope, name: []const u8) ?SlotBinding {
        if (self.parameter_names) |parameters| return parameters.get(name);
        return self.names.get(name);
    }
};

fn retainDebugLocalNames(arena: std.mem.Allocator, chunk: *Chunk, scope: *const FnScope) CompileError!void {
    chunk.debug_local_names = try arena.dupe([]const u8, scope.slot_names.items);
}

fn isUserVisibleBindingName(name: []const u8) bool {
    return name.len == 0 or name[0] != 0;
}

fn directEvalBindings(
    arena: std.mem.Allocator,
    bindings: *const SecureStringMapUnmanaged(SlotBinding),
) CompileError![]const bc.DirectEvalBinding {
    var visible_count: usize = 0;
    var count_it = bindings.iterator();
    while (count_it.next()) |entry|
        visible_count += @intFromBool(
            isUserVisibleBindingName(entry.key_ptr.*) and !entry.value_ptr.environment,
        );

    const retained = try arena.alloc(bc.DirectEvalBinding, visible_count);
    var retained_index: usize = 0;
    var it = bindings.iterator();
    while (it.next()) |entry| {
        const name = entry.key_ptr.*;
        const binding = entry.value_ptr.*;
        // Captured runtime cells are supplied by their original Environment,
        // not by the placeholder slot used for static name classification.
        if (!isUserVisibleBindingName(name) or binding.environment) continue;
        retained[retained_index] = .{
            .name = name,
            .slot = binding.slot,
            .lexical = binding.lexical,
            .immutable = binding.immutable,
            .tdz_checked = binding.tdz_checked,
            .mapped_parameter = binding.mapped_parameter,
        };
        retained_index += 1;
    }
    std.mem.sort(bc.DirectEvalBinding, retained, {}, struct {
        fn lessThan(_: void, left: bc.DirectEvalBinding, right: bc.DirectEvalBinding) bool {
            const order = std.mem.order(u8, left.name, right.name);
            return order == .lt or (order == .eq and left.slot < right.slot);
        }
    }.lessThan);
    return retained;
}

fn directEvalFrameBindingCount(bindings: *const SecureStringMapUnmanaged(SlotBinding)) usize {
    var count: usize = 0;
    var it = bindings.iterator();
    while (it.next()) |entry|
        count += @intFromBool(
            isUserVisibleBindingName(entry.key_ptr.*) and !entry.value_ptr.environment,
        );
    return count;
}

/// Freeze the active slot-backed scope stack without copying activation values.
/// The current declaration target is retained even when empty; functions with
/// parameter expressions additionally retain their outer parameter record.
/// Empty lexical scopes are semantically inert and omitted. Runtime Environment
/// Records are retained only as exact segment counts; materialization recovers
/// captured identities from Frame closure edges and the current segment from
/// the activation's live runtime chain.
fn buildDirectEvalPlan(
    arena: std.mem.Allocator,
    scope: *const FnScope,
    current_target: bc.DirectEvalScopeKind,
    current_environment_depth: u32,
) CompileError!bc.DirectEvalPlan {
    if (current_target == .parameter and scope.parameter_names == null) return error.Unsupported;
    var frame_count: usize = 0;
    var scope_count: usize = 0;
    var cursor: ?*const FnScope = scope;
    var cursor_phase: FunctionBindingPhase = if (current_target == .parameter) .parameters else .body;
    while (cursor) |frame_scope| : (cursor = frame_scope.parent) {
        frame_count += 1;
        if (cursor_phase == .parameters) {
            if (frame_scope.parameter_names == null) return error.Unsupported;
            scope_count += 1;
        } else {
            scope_count += 1;
            scope_count += @intFromBool(frame_scope.parameter_names != null);
            for (frame_scope.lexical_scopes.items) |lexical|
                scope_count += @intFromBool(directEvalFrameBindingCount(lexical) != 0);
        }
        cursor_phase = frame_scope.parent_binding_phase;
    }

    const scopes = try arena.alloc(bc.DirectEvalScope, scope_count);
    const frame_boundaries = try arena.alloc(bc.DirectEvalFrameBoundary, frame_count - 1);
    const FrameScope = struct { scope: *const FnScope, phase: FunctionBindingPhase };
    const frames = try arena.alloc(FrameScope, frame_count);
    cursor = scope;
    cursor_phase = if (current_target == .parameter) .parameters else .body;
    var current_depth: usize = 0;
    while (cursor) |frame_scope| : (cursor = frame_scope.parent) {
        frames[frame_count - current_depth - 1] = .{ .scope = frame_scope, .phase = cursor_phase };
        if (frame_scope.parent != null) {
            frame_boundaries[current_depth] = .{
                .child_frame_depth = @intCast(current_depth),
                .environment_depth = frame_scope.parent_direct_eval_environment_depth,
            };
        }
        current_depth += 1;
        cursor_phase = frame_scope.parent_binding_phase;
    }

    var scope_index: usize = 0;
    for (frames, 0..) |frame, outer_index| {
        const frame_scope = frame.scope;
        const frame_depth: u32 = @intCast(frame_count - outer_index - 1);
        if (frame_scope.parameter_names) |parameters| {
            scopes[scope_index] = .{
                .bindings = try directEvalBindings(arena, parameters),
                .kind = .parameter,
                .declaration_target = frame_depth == 0 and current_target == .parameter,
                .frame_depth = frame_depth,
            };
            scope_index += 1;
        }
        if (frame.phase == .body) {
            scopes[scope_index] = .{
                .bindings = try directEvalBindings(arena, &frame_scope.names),
                .kind = .variable,
                .declaration_target = frame_depth == 0 and current_target == .variable,
                .frame_depth = frame_depth,
            };
            scope_index += 1;
            for (
                frame_scope.lexical_scopes.items,
                frame_scope.lexical_scope_is_catch_param.items,
                frame_scope.lexical_scope_environment_depth.items,
            ) |lexical, is_catch_param, environment_depth| {
                if (directEvalFrameBindingCount(lexical) == 0) continue;
                scopes[scope_index] = .{
                    .bindings = try directEvalBindings(arena, lexical),
                    .kind = .lexical,
                    .is_catch_param = is_catch_param,
                    .frame_depth = frame_depth,
                    .environment_depth = environment_depth,
                };
                scope_index += 1;
            }
        }
    }
    return .{
        .scopes = scopes,
        .frame_boundaries = frame_boundaries,
        .current_environment_depth = current_environment_depth,
    };
}

/// Every ordinary function that can observe its own arguments object receives
/// one activation-local slot. Nested arrows resolve that owner slot like any
/// other upvalue; arrows never manufacture an arguments binding themselves.
fn addArgumentsSlot(
    arena: std.mem.Allocator,
    scope: *FnScope,
    fnode: *const ast.FunctionNode,
) CompileError!?u32 {
    if (fnode.is_arrow or (!fnode.uses_arguments and !fnode.uses_direct_eval)) return null;
    // FunctionDeclarationInstantiation suppresses the implicit object when a
    // formal already owns the `arguments` binding.
    if (parametersBindName(fnode, "arguments")) return null;
    return try scope.addParameter(arena, "arguments");
}

fn patternBindsName(pattern: *const ast.Node, name: []const u8) bool {
    return switch (pattern.*) {
        .identifier => |binding| std.mem.eql(u8, binding, name),
        .obj_pattern => |object| blk: {
            for (object.props) |property| if (patternBindsName(property.target, name)) break :blk true;
            if (object.rest) |rest| if (patternBindsName(rest, name)) break :blk true;
            break :blk false;
        },
        .arr_pattern => |array| blk: {
            for (array.elems) |element| if (element.target) |target|
                if (patternBindsName(target, name)) break :blk true;
            if (array.rest) |rest| if (patternBindsName(rest, name)) break :blk true;
            break :blk false;
        },
        else => false,
    };
}

fn parametersBindName(fnode: *const ast.FunctionNode, name: []const u8) bool {
    for (fnode.params) |parameter| {
        if (parameter.pattern) |pattern| {
            if (patternBindsName(pattern, name)) return true;
        } else if (std.mem.eql(u8, parameter.name, name)) return true;
    }
    return false;
}

const PlainParameterLayout = struct {
    slots: []const u32,
    destructuring_indices: []const u32,
    default_indices: []const u32,
    input_names: []const ?[]const u8,
    rest_index: ?u32,

    fn hasNonSimple(self: *const PlainParameterLayout) bool {
        return self.rest_index != null or self.destructuring_indices.len != 0 or self.default_indices.len != 0;
    }

    fn hasDeferredRest(self: *const PlainParameterLayout) bool {
        return self.rest_index != null and
            (self.destructuring_indices.len != 0 or self.default_indices.len != 0);
    }
};

fn configurePlainParameters(
    arena: std.mem.Allocator,
    scope: *FnScope,
    fnode: *const ast.FunctionNode,
) CompileError!PlainParameterLayout {
    scope.may_extend_environment = !fnode.is_strict and fnode.uses_direct_eval;
    var has_parameter_expressions = false;
    for (fnode.params) |parameter| {
        if (parameter.default != null) has_parameter_expressions = true;
        if (parameter.pattern) |pattern| {
            has_parameter_expressions = has_parameter_expressions or patternHasEvaluationExpressions(pattern);
        }
    }
    if (has_parameter_expressions) {
        const parameters = try arena.create(SecureStringMapUnmanaged(SlotBinding));
        parameters.* = .{ .state = scope.hash_state };
        scope.parameter_names = parameters;
        scope.body_direct_eval_boundary = fnode.uses_direct_eval_in_body;
    }

    const parameter_slots = try arena.alloc(u32, fnode.params.len);
    const input_names = try arena.alloc(?[]const u8, fnode.params.len);
    @memset(input_names, null);
    var pattern_indices: std.ArrayListUnmanaged(u32) = .empty;
    var default_indices: std.ArrayListUnmanaged(u32) = .empty;
    var rest_index: ?u32 = null;

    const BindingCollector = struct {
        scope: *FnScope,
        fn add(collector: *@This(), binding_arena: std.mem.Allocator, name: []const u8) CompileError!void {
            _ = try collector.scope.addParameter(binding_arena, name);
        }
    };
    for (fnode.params, 0..) |parameter, index| {
        if (parameter.default != null) try default_indices.append(arena, @intCast(index));
        if (parameter.pattern) |pattern| {
            var collector = BindingCollector{ .scope = scope };
            try collectPatternBindingNames(arena, pattern, &collector);
            try pattern_indices.append(arena, @intCast(index));
        } else {
            _ = try scope.addParameter(arena, parameter.name);
        }
        if (parameter.is_rest) {
            if (index + 1 != fnode.params.len) return error.Unsupported;
            rest_index = @intCast(index);
        }
    }
    // Keep visible formal cells contiguous. Hidden raw inputs follow them and
    // are excluded from direct-eval plans, preserving both cache locality for
    // ordinary body reads and exact ParameterEnvironment observability.
    for (fnode.params, 0..) |parameter, index| {
        if (has_parameter_expressions or parameter.pattern != null) {
            const input_name = try std.fmt.allocPrint(arena, "\x00param{d}", .{index});
            input_names[index] = input_name;
            parameter_slots[index] = if (scope.parameter_names) |parameters|
                try scope.addBinding(arena, parameters, input_name, false, false, false)
            else
                try scope.addLocal(arena, input_name, false, false);
        } else {
            parameter_slots[index] = (scope.parameter_names orelse &scope.names).get(parameter.name).?.slot;
        }
    }
    return .{
        .slots = parameter_slots,
        .destructuring_indices = pattern_indices.items,
        .default_indices = default_indices.items,
        .input_names = input_names,
        .rest_index = rest_index,
    };
}

/// Mark each distinct sloppy simple formal and freeze its rightmost arguments
/// index. ECMA-262 CreateMappedArgumentsObject scans formals right-to-left: an
/// earlier duplicate remains an ordinary arguments element and only the last
/// occurrence aliases the single parameter binding.
fn functionSupportsLegacyArguments(fnode: *const ast.FunctionNode) bool {
    return !fnode.is_strict and !fnode.is_arrow and !fnode.is_generator and
        !fnode.is_async and !fnode.is_method;
}

fn configureMappedParameters(
    arena: std.mem.Allocator,
    scope: *FnScope,
    fnode: *const ast.FunctionNode,
    arguments_observable: bool,
    emit_mapped_access: bool,
) CompileError![]const u32 {
    if (fnode.is_arrow or fnode.is_strict or !arguments_observable or fnode.params.len == 0) return &.{};
    // ECMA-262 creates an unmapped arguments object for every non-simple
    // parameter list. Rest/default/pattern formals therefore never publish
    // frame-slot aliases, even when the surrounding function is sloppy.
    for (fnode.params) |param|
        if (param.default != null or param.is_rest or param.pattern != null) return &.{};

    const unmapped = std.math.maxInt(u32);
    const indices = try arena.alloc(u32, scope.count);
    @memset(indices, unmapped);
    var seen: SecureStringMapUnmanaged(void) = .{ .state = scope.hash_state };
    var index = fnode.params.len;
    while (index > 0) {
        index -= 1;
        const param = fnode.params[index];
        std.debug.assert(param.default == null and !param.is_rest and param.pattern == null);
        if (seen.contains(param.name)) continue;
        try seen.put(arena, param.name, {});
        const binding = scope.names.getPtr(param.name) orelse return error.Unsupported;
        binding.mapped_parameter = emit_mapped_access;
        indices[binding.slot] = @intCast(index);
    }
    return indices;
}

/// Expression lowering may append compiler temporaries after parameter bindings
/// have been marked. Extend the immutable slot map to the final frame width so
/// VM validation covers every slot while ordinary non-mapped bytecodes remain
/// branch-free.
fn finalizeMappedParameterIndices(
    arena: std.mem.Allocator,
    scope: *const FnScope,
    initial: []const u32,
) CompileError![]const u32 {
    if (initial.len == 0 or initial.len == scope.count) return initial;
    std.debug.assert(initial.len < scope.count);
    const indices = try arena.alloc(u32, scope.count);
    @memset(indices, std.math.maxInt(u32));
    @memcpy(indices[0..initial.len], initial);
    return indices;
}

/// Whether a node embeds a `yield` reachable without crossing a function
/// boundary. Loop-head assignment patterns use this to require resumable native
/// lowering instead of the Environment-only `bind_pattern` path.
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
            if (p.rest) |rest| if (nodeHasYield(rest)) break :blk true;
            break :blk false;
        },
        else => false,
    };
}

/// Whether a loop `body` declares a block-scoped (`let`/`const`) binding that a
/// closure in the body captures — which needs a fresh per-iteration binding the
/// VM's single flat frame slot can't provide (all iterations' closures would
/// share the last value). Descends into blocks/if/try/switch/labeled but NOT into
/// nested functions or nested loops (which manage their own body bindings).
/// Captured declarations can use a declarative environment at the block that
/// owns them. Nested loops establish their own repeated-body root.
fn repeatedBodyCapturesSupported(node: *const ast.Node, captures: *const RepeatedBodyCaptures) bool {
    return switch (node.*) {
        .var_decl => true,
        .decl_group => |declarations| blk: {
            for (declarations) |declaration|
                if (!repeatedBodyCapturesSupported(declaration, captures)) break :blk false;
            break :blk true;
        },
        .destructure_decl => |declaration| blk: {
            const captured = declaration.kind != .@"var" and captures.patternCaptured(declaration.pattern);
            break :blk !captured or patternSupportsEnvironmentNode(declaration.pattern);
        },
        .block => |statements| blk: {
            for (statements) |statement| if (!repeatedBodyCapturesSupported(statement, captures)) break :blk false;
            break :blk true;
        },
        .if_stmt => |statement| repeatedBodyCapturesSupported(statement.consequent, captures) and
            (if (statement.alternate) |alternate| repeatedBodyCapturesSupported(alternate, captures) else true),
        .labeled_stmt => |statement| repeatedBodyCapturesSupported(statement.body, captures),
        .try_stmt => |statement| blk: {
            const captured_catch = if (statement.catch_param) |catch_param| captures.catchPatternCaptured(catch_param) else false;
            if (captured_catch and !patternSupportsEnvironmentNode(statement.catch_param.?)) break :blk false;
            break :blk repeatedBodyCapturesSupported(statement.block, captures) and
                (if (statement.catch_block) |catch_block| repeatedBodyCapturesSupported(catch_block, captures) else true) and
                (if (statement.finally_block) |finally_block| repeatedBodyCapturesSupported(finally_block, captures) else true);
        },
        .switch_stmt => |statement| blk: {
            for (statement.cases) |case| for (case.body) |case_statement|
                if (!repeatedBodyCapturesSupported(case_statement, captures)) break :blk false;
            break :blk true;
        },
        // Nested iteration statements compile their own body with a new root.
        .while_stmt, .do_while_stmt, .for_stmt, .for_in => true,
        else => true,
    };
}

fn patternSupportsEnvironmentNode(pattern: *const ast.Node) bool {
    return switch (pattern.*) {
        .identifier => true,
        .obj_pattern => |object| blk: {
            for (object.props) |property| if (!patternSupportsEnvironmentNode(property.target)) break :blk false;
            if (object.rest) |rest| if (!patternSupportsEnvironmentNode(rest)) break :blk false;
            break :blk true;
        },
        .arr_pattern => |array| blk: {
            for (array.elems) |element| if (element.target) |target|
                if (!patternSupportsEnvironmentNode(target)) break :blk false;
            if (array.rest) |rest| if (!patternSupportsEnvironmentNode(rest)) break :blk false;
            break :blk true;
        },
        else => false,
    };
}

const CapturedBindingReferences = struct {
    names: *const SecureStringMapUnmanaged(void),
};

/// Set-valued capture classification must visit the complete AST even after the
/// first match. Returning false after recording prevents the generic exhaustive
/// walk from short-circuiting while pre-reserved storage keeps matching infallible.
const RecordingCapturedBindingReferences = struct {
    names: *SecureStringMapUnmanaged(bool),
    captured_count: *usize,
};

const LoopBindingNames = struct {
    single: ?[]const u8 = null,
    multiple: SecureStringMapUnmanaged(void),

    fn init(hash_state: *CompileHashState) LoopBindingNames {
        return .{ .multiple = .{ .state = hash_state } };
    }

    fn add(self: *LoopBindingNames, arena: std.mem.Allocator, name: []const u8) CompileError!void {
        if (self.multiple.count() != 0) {
            try self.multiple.put(arena, name, {});
            return;
        }
        if (self.single) |existing| {
            if (std.mem.eql(u8, existing, name)) return;
            try self.multiple.put(arena, existing, {});
            try self.multiple.put(arena, name, {});
            return;
        }
        self.single = name;
    }

    fn referencedByIn(self: *const LoopBindingNames, node: *const ast.Node, in_fn: bool) bool {
        if (self.multiple.count() == 0)
            return if (self.single) |name| nameRefInClosure(node, name, in_fn) else false;
        return nameRefInClosure(node, CapturedBindingReferences{ .names = &self.multiple }, in_fn);
    }

    fn referencedBy(self: *const LoopBindingNames, node: *const ast.Node) bool {
        return self.referencedByIn(node, false);
    }
};

const RepeatedBodyNameCaptures = struct {
    single: ?[]const u8 = null,
    single_captured: bool = false,
    multiple: SecureStringMapUnmanaged(bool),
    captured_count: usize = 0,

    fn init(hash_state: *CompileHashState) RepeatedBodyNameCaptures {
        return .{ .multiple = .{ .state = hash_state } };
    }

    fn add(self: *RepeatedBodyNameCaptures, arena: std.mem.Allocator, name: []const u8) CompileError!void {
        if (self.multiple.count() != 0) {
            try self.multiple.put(arena, name, false);
            return;
        }
        if (self.single) |existing| {
            if (std.mem.eql(u8, existing, name)) return;
            try self.multiple.put(arena, existing, false);
            try self.multiple.put(arena, name, false);
            return;
        }
        self.single = name;
    }

    fn classify(self: *RepeatedBodyNameCaptures, node: *const ast.Node) void {
        if (self.multiple.count() == 0) {
            self.single_captured = if (self.single) |name| nameRefInClosure(node, name, false) else false;
            return;
        }
        _ = nameRefInClosure(node, RecordingCapturedBindingReferences{
            .names = &self.multiple,
            .captured_count = &self.captured_count,
        }, false);
    }

    fn captures(self: *const RepeatedBodyNameCaptures, name: []const u8) bool {
        if (self.multiple.count() == 0)
            return self.single_captured and self.single != null and std.mem.eql(u8, self.single.?, name);
        return self.multiple.get(name) orelse false;
    }

    fn any(self: *const RepeatedBodyNameCaptures) bool {
        return self.single_captured or self.captured_count != 0;
    }
};

const RepeatedBodyCaptures = struct {
    bindings: RepeatedBodyNameCaptures,
    captured_catch_patterns: SecureIdentityMapUnmanaged(void) = .{},

    fn init(arena: std.mem.Allocator, hash_state: *CompileHashState, root: *const ast.Node) CompileError!RepeatedBodyCaptures {
        var captures: RepeatedBodyCaptures = .{
            .bindings = RepeatedBodyNameCaptures.init(hash_state),
        };
        try collectRepeatedBodyBindings(arena, root, &captures);
        captures.bindings.classify(root);
        return captures;
    }

    fn nameCaptured(self: *const RepeatedBodyCaptures, name: []const u8) bool {
        return self.bindings.captures(name);
    }

    fn patternCaptured(self: *const RepeatedBodyCaptures, pattern: *const ast.Node) bool {
        return switch (pattern.*) {
            .identifier => |name| self.nameCaptured(name),
            .obj_pattern => |object| blk: {
                for (object.props) |property| if (self.patternCaptured(property.target)) break :blk true;
                if (object.rest) |rest| if (self.patternCaptured(rest)) break :blk true;
                break :blk false;
            },
            .arr_pattern => |array| blk: {
                for (array.elems) |element| if (element.target) |target|
                    if (self.patternCaptured(target)) break :blk true;
                if (array.rest) |rest| if (self.patternCaptured(rest)) break :blk true;
                break :blk false;
            },
            else => false,
        };
    }

    fn catchPatternCaptured(self: *const RepeatedBodyCaptures, pattern: *const ast.Node) bool {
        return self.captured_catch_patterns.contains(self.bindings.multiple.state, @intFromPtr(pattern));
    }

    fn any(self: *const RepeatedBodyCaptures) bool {
        return self.bindings.any() or self.captured_catch_patterns.count() != 0;
    }
};

fn collectPatternBindingNames(arena: std.mem.Allocator, pattern: *const ast.Node, names: anytype) CompileError!void {
    switch (pattern.*) {
        .identifier => |name| try names.add(arena, name),
        .obj_pattern => |object| {
            for (object.props) |property| try collectPatternBindingNames(arena, property.target, names);
            if (object.rest) |rest| try collectPatternBindingNames(arena, rest, names);
        },
        .arr_pattern => |array| {
            for (array.elems) |element| if (element.target) |target|
                try collectPatternBindingNames(arena, target, names);
            if (array.rest) |rest| try collectPatternBindingNames(arena, rest, names);
        },
        else => {},
    }
}

fn collectLoopBindingNames(arena: std.mem.Allocator, node: *const ast.Node, names: *LoopBindingNames) CompileError!void {
    switch (node.*) {
        .var_decl => |declaration| if (declaration.kind != .@"var") try names.add(arena, declaration.name),
        .destructure_decl => |declaration| if (declaration.kind != .@"var")
            try collectPatternBindingNames(arena, declaration.pattern, names),
        .decl_group => |declarations| for (declarations) |declaration|
            try collectLoopBindingNames(arena, declaration, names),
        else => {},
    }
}

fn forLoopCapturesLexical(arena: std.mem.Allocator, hash_state: *CompileHashState, init_node: *const ast.Node, cond: ?*const ast.Node, update: ?*const ast.Node, body: *const ast.Node) CompileError!bool {
    var names = LoopBindingNames.init(hash_state);
    try collectLoopBindingNames(arena, init_node, &names);
    return names.referencedBy(init_node) or
        (if (cond) |condition| names.referencedBy(condition) else false) or
        (if (update) |increment| names.referencedBy(increment) else false) or
        names.referencedBy(body);
}

fn patternHasEvaluationExpressions(pattern: *const ast.Node) bool {
    return switch (pattern.*) {
        .identifier => false,
        .obj_pattern => |object| blk: {
            for (object.props) |property| {
                if (property.key_expr != null or property.default != null or patternHasEvaluationExpressions(property.target)) break :blk true;
            }
            if (object.rest) |rest| if (patternHasEvaluationExpressions(rest)) break :blk true;
            break :blk false;
        },
        .arr_pattern => |array| blk: {
            for (array.elems) |element| {
                if (element.default != null) break :blk true;
                if (element.target) |target| if (patternHasEvaluationExpressions(target)) break :blk true;
            }
            if (array.rest) |rest| if (patternHasEvaluationExpressions(rest)) break :blk true;
            break :blk false;
        },
        else => true,
    };
}

fn forOfCapturesLexical(arena: std.mem.Allocator, hash_state: *CompileHashState, target: *const ast.Node, var_init: ?*const ast.Node, iterable: *const ast.Node, body: *const ast.Node) CompileError!bool {
    var names = LoopBindingNames.init(hash_state);
    try collectPatternBindingNames(arena, target, &names);
    return names.referencedBy(target) or
        (if (var_init) |initializer| names.referencedBy(initializer) else false) or
        names.referencedBy(iterable) or names.referencedBy(body);
}

/// Collect declarations owned by one repeated-body root. Nested loops establish
/// their own root; nested functions contain references but not declarations owned
/// by this iteration. Catch parameters have their own lexical scope, so each is
/// classified once against only its catch block and cached by pattern identity.
fn collectRepeatedBodyBindings(arena: std.mem.Allocator, node: *const ast.Node, captures: *RepeatedBodyCaptures) CompileError!void {
    switch (node.*) {
        .func_decl => |function| try captures.bindings.add(arena, function.name),
        .var_decl => |declaration| if (declaration.kind != .@"var")
            try captures.bindings.add(arena, declaration.name),
        .destructure_decl => |declaration| if (declaration.kind != .@"var")
            try collectPatternBindingNames(arena, declaration.pattern, &captures.bindings),
        .decl_group => |declarations| for (declarations) |declaration|
            try collectRepeatedBodyBindings(arena, declaration, captures),
        .block => |statements| for (statements) |statement|
            try collectRepeatedBodyBindings(arena, statement, captures),
        .if_stmt => |statement| {
            try collectRepeatedBodyBindings(arena, statement.consequent, captures);
            if (statement.alternate) |alternate| try collectRepeatedBodyBindings(arena, alternate, captures);
        },
        .labeled_stmt => |statement| try collectRepeatedBodyBindings(arena, statement.body, captures),
        .with_stmt => |statement| try collectRepeatedBodyBindings(arena, statement.body, captures),
        .try_stmt => |statement| {
            try collectRepeatedBodyBindings(arena, statement.block, captures);
            if (statement.catch_block) |catch_block| {
                if (statement.catch_param) |catch_param| {
                    var catch_captures = RepeatedBodyNameCaptures.init(captures.bindings.multiple.state);
                    try collectPatternBindingNames(arena, catch_param, &catch_captures);
                    catch_captures.classify(catch_block);
                    if (catch_captures.any()) try captures.captured_catch_patterns.put(arena, captures.bindings.multiple.state, @intFromPtr(catch_param), {});
                }
                try collectRepeatedBodyBindings(arena, catch_block, captures);
            }
            if (statement.finally_block) |finally_block|
                try collectRepeatedBodyBindings(arena, finally_block, captures);
        },
        .switch_stmt => |statement| for (statement.cases) |case| for (case.body) |case_statement|
            try collectRepeatedBodyBindings(arena, case_statement, captures),
        // Nested iteration statements own their declarations. Their references
        // still participate when the exhaustive root traversal runs below.
        .while_stmt, .do_while_stmt, .for_stmt, .for_in, .function => {},
        else => {},
    }
}

/// Exhaustive identifier-reference walk shared by exact-name capture queries and
/// the set-valued pending-TDZ query. `in_fn` tracks whether the current subtree
/// already sits (transitively) inside a function boundary: loop-capture callers
/// ignore plain body reads, while TDZ callers begin inside the current function.
/// Unlike `nodeHasYield` this descends INTO nested functions. The switch has no
/// `else`, so a new node kind cannot silently become a capture or TDZ false
/// negative. It deliberately ignores shadowing and treats deferred class bodies
/// as closures: over-matching selects checked bytecode or the correct-but-slower
/// tree-walker, never a wrong lowering.
const PendingLexicalReferences = struct {
    bindings: *const SecureStringMapUnmanaged(Compiler.ShadowBind),
    declared: *const SecureStringMapUnmanaged(void),
};

fn identifierReferenceMatches(query: anytype, identifier: []const u8) bool {
    return if (comptime @TypeOf(query) == PendingLexicalReferences) pending: {
        const binding = query.bindings.get(identifier) orelse break :pending false;
        break :pending binding.lexical and !query.declared.contains(identifier);
    } else if (comptime @TypeOf(query) == CapturedBindingReferences)
        query.names.contains(identifier)
    else if (comptime @TypeOf(query) == RecordingCapturedBindingReferences) recording: {
        if (query.names.getPtr(identifier)) |captured| if (!captured.*) {
            captured.* = true;
            query.captured_count.* += 1;
        };
        break :recording false;
    } else std.mem.eql(u8, identifier, query);
}

fn directEvalReferenceMatches(query: anytype) bool {
    if (comptime @TypeOf(query) == RecordingCapturedBindingReferences) {
        if (query.captured_count.* == query.names.count()) return false;
        var bindings = query.names.iterator();
        while (bindings.next()) |entry| entry.value_ptr.* = true;
        query.captured_count.* = query.names.count();
        return false;
    } else if (comptime @TypeOf(query) == CapturedBindingReferences) {
        return query.names.count() != 0;
    } else if (comptime @TypeOf(query) == PendingLexicalReferences) {
        var bindings = query.bindings.iterator();
        while (bindings.next()) |entry|
            if (entry.value_ptr.lexical and !query.declared.contains(entry.key_ptr.*)) return true;
        return false;
    } else return true;
}

fn nameRefInClosure(node: *const ast.Node, name: anytype, in_fn: bool) bool {
    return switch (node.*) {
        .identifier => |id| in_fn and identifierReferenceMatches(name, id),

        .number, .bigint_lit, .string, .boolean, .null_lit, .undefined_lit, .elision, .this_expr, .new_target_expr, .regex_literal, .import_meta, .import_decl, .break_stmt, .continue_stmt, .debugger_stmt => false,

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
            // PerformEval can create a closure over any visible binding. A
            // repeated scope must retain fresh cells even when the source text
            // contains no statically visible function or identifier reference.
            if (!c.optional and c.callee.* == .identifier and
                std.mem.eql(u8, c.callee.identifier, "eval") and directEvalReferenceMatches(name))
                break :blk true;
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
        .field_init_value => |v| nameRefInClosure(v.expression, name, in_fn),
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
fn fnCaptures(fnode: *const ast.FunctionNode, name: anytype) bool {
    for (fnode.params) |p| {
        if (p.default) |d| if (nameRefInClosure(d, name, true)) return true;
        if (p.pattern) |pat| if (nameRefInClosure(pat, name, true)) return true;
    }
    return nameRefInClosure(fnode.body, name, true);
}

/// Disposal scopes still need resource cleanup on every abrupt completion;
/// environment-depth unwind alone is insufficient. Conservatively reject any
/// possible escape until that cleanup is represented in bytecode. Nested
/// functions have independent control flow and do not escape the current scope.
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

fn labeledStatementTargetsIteration(node: *const ast.Node) bool {
    return switch (node.*) {
        .while_stmt, .do_while_stmt, .for_stmt, .for_in => true,
        .labeled_stmt => |statement| labeledStatementTargetsIteration(statement.body),
        else => false,
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

/// Whether deferred class member bodies reference any frame-slot name. Computed keys are
/// deliberately excluded: they execute eagerly as VM operations, so closures
/// created there capture frame slots normally. Methods, field initializers, and
/// static blocks execute later through `eval_class` and can only resolve names
/// available through its Environment chain.
fn classDeferredBodiesCaptureNames(members: []const ast.ClassMember, names: *const LoopBindingNames) bool {
    for (members) |m| {
        if (m.func) |func| if (names.referencedByIn(func, true)) return true;
        if (m.field_init) |init| if (names.referencedByIn(init, true)) return true;
        if (m.static_block) |block| if (names.referencedByIn(block, true)) return true;
    }
    return false;
}

/// Global-only classes need no activation projection. A deferred member that
/// can observe a real current/enclosing frame binding needs an exact live view.
fn classDeferredBodiesCaptureFrame(arena: std.mem.Allocator, scope: *const FnScope, members: []const ast.ClassMember, class_name: []const u8) CompileError!bool {
    var frame_names = LoopBindingNames.init(scope.hash_state);
    var current: ?*const FnScope = scope;
    while (current) |frame_scope| : (current = frame_scope.parent) {
        if (frame_scope.may_extend_environment) return true;
        var names = frame_scope.names.keyIterator();
        while (names.next()) |name| {
            // Deferred class elements resolve the class's own name through the
            // class Environment, even when an outer frame slot has the same
            // spelling. That binding is therefore not a frame capture.
            if (class_name.len == 0 or !std.mem.eql(u8, name.*, class_name))
                try frame_names.add(arena, name.*);
        }
        if (frame_scope.parameter_names) |parameters| {
            var parameter_names = parameters.keyIterator();
            while (parameter_names.next()) |name| {
                if (class_name.len == 0 or !std.mem.eql(u8, name.*, class_name))
                    try frame_names.add(arena, name.*);
            }
        }
        for (frame_scope.lexical_scopes.items) |bindings| {
            var lexical = bindings.iterator();
            while (lexical.next()) |entry| {
                // Environment-backed bindings are exactly what eval_class can
                // capture through its live Environment chain. Only a real frame
                // slot remains unavailable to deferred class member evaluation.
                if (!entry.value_ptr.environment and
                    (class_name.len == 0 or !std.mem.eql(u8, entry.key_ptr.*, class_name)))
                    try frame_names.add(arena, entry.key_ptr.*);
            }
        }
    }
    return classDeferredBodiesCaptureNames(members, &frame_names);
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
        .block => |stmts| stmtListHasDisposableDecl(stmts),
        .decl_group => |stmts| stmtListHasDisposableDecl(stmts),
        else => false,
    };
}

fn stmtListHasDisposableDecl(stmts: []*Node) bool {
    for (stmts) |s| if (stmtHasDisposableDecl(s)) return true;
    return false;
}

fn stmtContainsDisposableDeclDeep(node: *const ast.Node) bool {
    return switch (node.*) {
        .var_decl => |d| d.dispose != 0,
        .block, .decl_group, .program => |stmts| stmtListContainsDisposableDeclDeep(stmts),
        .if_stmt => |s| stmtContainsDisposableDeclDeep(s.consequent) or
            (if (s.alternate) |alt| stmtContainsDisposableDeclDeep(alt) else false),
        .while_stmt => |s| stmtContainsDisposableDeclDeep(s.body),
        .do_while_stmt => |s| stmtContainsDisposableDeclDeep(s.body),
        .for_stmt => |s| (if (s.init) |init| stmtContainsDisposableDeclDeep(init) else false) or
            stmtContainsDisposableDeclDeep(s.body),
        .for_in => |s| s.dispose != 0 or
            (if (s.var_init) |init| stmtContainsDisposableDeclDeep(init) else false) or
            stmtContainsDisposableDeclDeep(s.body),
        .switch_stmt => |s| blk: {
            for (s.cases) |case| if (stmtListContainsDisposableDeclDeep(case.body)) break :blk true;
            break :blk false;
        },
        .try_stmt => |t| stmtContainsDisposableDeclDeep(t.block) or
            (if (t.catch_block) |c| stmtContainsDisposableDeclDeep(c) else false) or
            (if (t.finally_block) |f| stmtContainsDisposableDeclDeep(f) else false),
        .labeled_stmt => |s| stmtContainsDisposableDeclDeep(s.body),
        .with_stmt => |s| stmtContainsDisposableDeclDeep(s.body),
        else => false,
    };
}

fn stmtListContainsDisposableDeclDeep(stmts: []*Node) bool {
    for (stmts) |s| if (stmtContainsDisposableDeclDeep(s)) return true;
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
    local: SlotBinding, // slot in the current frame
    upval: struct { depth: u32, environment_depth: u32, binding: SlotBinding }, // an enclosing function's frame
    environment: SlotBinding, // statically known declarative Environment binding
    global, // by name, against the Environment
};

const FunctionBindingPhase = enum {
    body,
    parameters,
};

pub const Compiler = struct {
    arena: std.mem.Allocator,
    chunk: *Chunk,
    mode: Mode,
    hash_state: *CompileHashState,
    scope: ?*FnScope = null,
    environment_function_body: ?*const Node = null,
    environment_annex_b: SecureIdentityMapUnmanaged(u32) = .{},
    /// Parameter initializers resolve only through the outer parameter record;
    /// ordinary body code resolves body vars first and then parameters.
    function_binding_phase: FunctionBindingPhase = .body,
    loops: std.ArrayListUnmanaged(*Loop) = .empty,
    /// True while lowering a generator body, so `yield` may emit `gen_yield`.
    in_generator: bool = false,
    /// True while lowering an async function body, so `await` may suspend (it
    /// reuses `gen_yield`; the async driver resumes it on promise settlement).
    in_async: bool = false,
    /// Counter for synthesized activation-temp names (destructuring, `yield*`,
    /// and resolved references that must survive recursion or suspension).
    tmp_counter: u32 = 0,
    /// >0 while compiling inside a `try` that has a `finally`. A `return`/`break`/
    /// `continue` crossing it is lowered as `abrupt_*` so the finally still runs.
    finally_depth: u32 = 0,
    /// Number of `push_handler`s emitted minus `pop_handler`s along the
    /// current lexical path — the runtime handler-stack depth at this point of
    /// straight-line code. A catch or finally body runs with its own try's
    /// handler already popped, which the structured emission mirrors.
    handler_depth: u32 = 0,
    /// How many Environment Records above the current one a `using`
    /// declaration registers its resource in. Zero everywhere except while a
    /// `for` head runs under a captured lexical head environment, whose record
    /// the per-iteration copies replace: the resource must live in the loop's
    /// own scope beneath it (ForStatement's loopEnv), which is disposed once
    /// when the loop completes.
    disposable_register_depth: u32 = 0,
    /// How many `finally` BLOCKS we are currently compiling the body of (nested).
    /// A `return` in a finally body does not cross THAT finally (it is already
    /// running), only enclosing ones — so a return is a tail-call candidate when
    /// `finally_depth == active_finally` (every counted finally is one we are
    /// inside the body of, none pending). Kept separate from `finally_depth` so
    /// break/continue abrupt-vs-plain accounting (which compares against a loop's
    /// captured `finally_depth`) is unaffected.
    active_finally: u32 = 0,
    /// Number of runtime declarative/with environments emitted above this
    /// activation's entry environment.
    environment_depth: u32 = 0,
    /// Number of Object Environment Records among `environment_depth`.
    /// Nested function scopes retain the parent contribution separately.
    with_depth: u32 = 0,
    /// The single classification for the repeated loop body currently being
    /// lowered. Nested blocks reuse its exact captured-name and catch-pattern
    /// results instead of walking the root once per lexical declaration.
    repeated_body_captures: ?*const RepeatedBodyCaptures = null,
    /// >0 while compiling the body of a `try` whose catch handler is still live on
    /// the VM handler stack (the no-finally case). A call in tail position there
    /// must NOT be a tail call: the handler has to survive the call so a throw from
    /// the callee is caught, but the tail-pop would discard it. Suppresses TCO in
    /// compileTailExpr. (The finally case keeps the handler live via abrupt_return.)
    try_depth: u32 = 0,
    /// True while compiling a STRICT function body. Proper tail calls
    /// (PrepareForTailCall) are a strict-mode-only guarantee, so compileTailExpr
    /// only reuses the frame when this is set. A sloppy tail call must grow the
    /// stack like any call and eventually throw RangeError (matching the
    /// tree-walker) rather than looping forever on `function f(){ return f(); }`.
    is_strict: bool = false,
    /// Class instance initializer expressions are compiled into a constructor
    /// prefix with environment-only name resolution and lexical field semantics.
    in_field_initializer: bool = false,
    /// Derived-constructor activation context. Lexical arrows inherit the
    /// initializer slice so `() => super()` runs the enclosing class elements.
    is_derived_constructor: bool = false,
    is_default_constructor: bool = false,
    derived_instance_initializers: []const *ast.Node = &.{},
    /// Emit per-statement VM checkpoints for debugger-enabled suspendable code.
    debug_checkpoints: bool = false,
    /// Highest #706 scratch slot handed out by this compiler. Program chunks
    /// publish it on their Chunk so each execution allocates an Exec-owned,
    /// GC-rooted scratch array of exactly that size.
    scratch_count: u32 = 0,

    /// Compile a whole program into a fresh chunk. The chunk ends with `halt`;
    /// the VM returns its completion accumulator. Program scope is null, so all
    /// top-level bindings are globals.
    pub const ProgramRejection = enum {
        invalid_root,
        unsupported_lowering,
    };

    pub const ProgramAdmission = union(enum) {
        compiled: *Chunk,
        rejected: ProgramRejection,
    };

    pub fn admitProgram(arena: std.mem.Allocator, program: *Node) error{OutOfMemory}!ProgramAdmission {
        var rejection: ?ProgramRejection = null;
        const chunk = compileProgramInner(arena, program, &rejection) catch |err| switch (err) {
            error.Unsupported => return .{ .rejected = rejection orelse .unsupported_lowering },
            error.OutOfMemory => return error.OutOfMemory,
        };
        return .{ .compiled = chunk };
    }

    pub fn compileProgram(arena: std.mem.Allocator, program: *Node) CompileError!*Chunk {
        return switch (try admitProgram(arena, program)) {
            .compiled => |chunk| chunk,
            .rejected => error.Unsupported,
        };
    }

    fn programIsStrict(statements: []*Node) bool {
        for (statements) |statement| {
            if (statement.* != .expr_stmt or statement.expr_stmt.* != .string) return false;
            if (std.mem.eql(u8, statement.expr_stmt.string, "use strict")) return true;
        }
        return false;
    }

    fn compileProgramInner(arena: std.mem.Allocator, program: *Node, rejection: *?ProgramRejection) CompileError!*Chunk {
        const chunk = try arena.create(Chunk);
        chunk.* = Chunk.init(arena);
        var hash_state: CompileHashState = .{};
        // Keep latent source-node checkpoints in every chunk. With no debugger
        // hook the VM performs no checkpoint work; retaining the metadata lets a
        // later attachment inspect already-compiled functions without rebuilding
        // their frame/upvalue layout.
        var c = Compiler{ .arena = arena, .chunk = chunk, .mode = .program, .hash_state = &hash_state, .debug_checkpoints = true };
        if (program.* != .program) {
            rejection.* = .invalid_root;
            return error.Unsupported;
        }
        // The parser's program-level strict flag is represented by the leading
        // Directive Prologue in this AST. Carry it into effectful bytecodes so
        // strict DeletePropertyOrThrow behavior does not depend on the caller's
        // mutable interpreter mode.
        c.is_strict = programIsStrict(program.program);
        try c.planEnvironmentDeclarations(program.program, &.{}, false);
        try c.compileEnvironmentBody(program.program);
        _ = try chunk.emit(.halt, 0);
        chunk.scratch_count = c.scratch_count;
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
    pub const GeneratorRejection = enum {
        expression_body,
        unsupported_lowering,
    };

    pub const GeneratorAdmission = union(enum) {
        compiled: *Chunk,
        rejected: GeneratorRejection,
    };

    pub fn admitGenerator(arena: std.mem.Allocator, fnode: *const ast.FunctionNode, debug_checkpoints: bool) error{OutOfMemory}!GeneratorAdmission {
        var rejection: ?GeneratorRejection = null;
        var hash_state: CompileHashState = .{};
        const chunk = compileGeneratorInner(arena, fnode, debug_checkpoints, &hash_state, &rejection) catch |err| switch (err) {
            error.Unsupported => return .{ .rejected = rejection orelse .unsupported_lowering },
            error.OutOfMemory => return error.OutOfMemory,
        };
        return .{ .compiled = chunk };
    }

    pub fn compileGenerator(arena: std.mem.Allocator, fnode: *const ast.FunctionNode, debug_checkpoints: bool) CompileError!*Chunk {
        return switch (try admitGenerator(arena, fnode, debug_checkpoints)) {
            .compiled => |chunk| chunk,
            .rejected => error.Unsupported,
        };
    }

    fn compileGeneratorInner(arena: std.mem.Allocator, fnode: *const ast.FunctionNode, debug_checkpoints: bool, hash_state: *CompileHashState, rejection: *?GeneratorRejection) CompileError!*Chunk {
        // Parameters (including default/rest/destructuring) are bound at runtime
        // by `makeGenerator` into the generator's environment — env-mode name
        // resolution means the body's references resolve there — so the param
        // shape never blocks compilation; only the body must lower.
        if (fnode.is_expr_body) {
            rejection.* = .expression_body;
            return error.Unsupported; // generators always have a block body
        }
        const chunk = try arena.create(Chunk);
        chunk.* = Chunk.init(arena);
        // An async generator body may also `await` (in_async enables await_op).
        var c = Compiler{ .arena = arena, .chunk = chunk, .mode = .function, .hash_state = hash_state, .scope = null, .in_generator = true, .in_async = fnode.is_async, .is_strict = fnode.is_strict, .debug_checkpoints = debug_checkpoints };
        c.environment_function_body = fnode.body;
        try c.planEnvironmentDeclarations(fnode.body.block, fnode.params, !fnode.is_arrow);
        try c.compileStmt(fnode.body); // body is a block
        _ = try chunk.emit(.ret_undef, 0);
        try chunk.finalize();
        return chunk;
    }

    /// Compile a plain `async function` body for the suspendable VM (env-mode,
    /// like a generator). `await` lowers to a suspend (`gen_yield`); the async
    /// driver promisifies the suspended value, resumes on settlement, and
    /// settles the function's result promise on completion.
    pub const AsyncRejection = enum {
        async_generator,
        unsupported_lowering,
    };

    pub const AsyncAdmission = union(enum) {
        compiled: *Chunk,
        rejected: AsyncRejection,
    };

    pub fn admitAsync(arena: std.mem.Allocator, fnode: *const ast.FunctionNode, debug_checkpoints: bool) error{OutOfMemory}!AsyncAdmission {
        var rejection: ?AsyncRejection = null;
        var hash_state: CompileHashState = .{};
        const chunk = compileAsyncInner(arena, fnode, debug_checkpoints, &hash_state, &rejection) catch |err| switch (err) {
            error.Unsupported => return .{ .rejected = rejection orelse .unsupported_lowering },
            error.OutOfMemory => return error.OutOfMemory,
        };
        return .{ .compiled = chunk };
    }

    pub fn compileAsync(arena: std.mem.Allocator, fnode: *const ast.FunctionNode, debug_checkpoints: bool) CompileError!*Chunk {
        return switch (try admitAsync(arena, fnode, debug_checkpoints)) {
            .compiled => |chunk| chunk,
            .rejected => error.Unsupported,
        };
    }

    fn compileAsyncInner(arena: std.mem.Allocator, fnode: *const ast.FunctionNode, debug_checkpoints: bool, hash_state: *CompileHashState, rejection: *?AsyncRejection) CompileError!*Chunk {
        if (fnode.is_generator) {
            rejection.* = .async_generator;
            return error.Unsupported; // async generators not lowered yet
        }
        const chunk = try arena.create(Chunk);
        chunk.* = Chunk.init(arena);
        var c = Compiler{ .arena = arena, .chunk = chunk, .mode = .function, .hash_state = hash_state, .scope = null, .in_async = true, .is_strict = fnode.is_strict, .debug_checkpoints = debug_checkpoints };
        if (fnode.is_expr_body) {
            try c.compileExpr(fnode.body);
            _ = try chunk.emit(.ret, 0);
        } else {
            c.environment_function_body = fnode.body;
            try c.planEnvironmentDeclarations(fnode.body.block, fnode.params, !fnode.is_arrow);
            try c.compileStmt(fnode.body);
            _ = try chunk.emit(.ret_undef, 0);
        }
        try chunk.finalize();
        return chunk;
    }

    const ShadowBind = struct { count: u32 = 0, lexical: bool = false };

    fn shadowAdd(arena: std.mem.Allocator, m: *SecureStringMapUnmanaged(ShadowBind), name: []const u8, lexical: bool) CompileError!void {
        if (name.len == 0) return;
        const gop = try m.getOrPut(arena, name);
        if (!gop.found_existing) gop.value_ptr.* = .{};
        gop.value_ptr.count += 1;
        if (lexical) gop.value_ptr.lexical = true;
    }

    fn shadowScanPattern(arena: std.mem.Allocator, m: *SecureStringMapUnmanaged(ShadowBind), pattern: *Node, lexical: bool) CompileError!void {
        switch (pattern.*) {
            .identifier => |name| try shadowAdd(arena, m, name, lexical),
            .obj_pattern => |p| {
                for (p.props) |prop| try shadowScanPattern(arena, m, prop.target, lexical);
                if (p.rest) |rest| try shadowScanPattern(arena, m, rest, lexical);
            },
            .arr_pattern => |p| {
                for (p.elems) |elem| if (elem.target) |t| try shadowScanPattern(arena, m, t, lexical);
                if (p.rest) |rest| try shadowScanPattern(arena, m, rest, lexical);
            },
            else => {},
        }
    }

    fn shadowScanStmt(arena: std.mem.Allocator, m: *SecureStringMapUnmanaged(ShadowBind), node: *Node) CompileError!void {
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

    const FunctionBindingInventory = struct {
        bindings: SecureStringMapUnmanaged(ShadowBind),
        has_lexical: bool = false,
        has_shadowing: bool = false,
    };

    /// Build the spelling-based binding inventory once for both shadow and TDZ
    /// classification. Distinct lexical bindings still receive distinct slots;
    /// repeated spellings conservatively enable checks for every lexical slot.
    fn functionBindingInventory(arena: std.mem.Allocator, hash_state: *CompileHashState, fnode: *const ast.FunctionNode) CompileError!FunctionBindingInventory {
        var inventory: FunctionBindingInventory = .{ .bindings = .{ .state = hash_state } };
        for (fnode.params) |param| try shadowAdd(arena, &inventory.bindings, param.name, false);
        if (!fnode.is_expr_body) try shadowScanStmt(arena, &inventory.bindings, fnode.body);
        var bindings = inventory.bindings.iterator();
        while (bindings.next()) |entry| if (entry.value_ptr.lexical) {
            inventory.has_lexical = true;
            if (entry.value_ptr.count >= 2) {
                inventory.has_shadowing = true;
                break;
            }
        };
        return inventory;
    }

    fn tdzDeclarePattern(arena: std.mem.Allocator, declared: *SecureStringMapUnmanaged(void), pattern: *Node) CompileError!void {
        switch (pattern.*) {
            .identifier => |name| try declared.put(arena, name, {}),
            .obj_pattern => |p| {
                for (p.props) |prop| try tdzDeclarePattern(arena, declared, prop.target);
                if (p.rest) |rest| try tdzDeclarePattern(arena, declared, rest);
            },
            .arr_pattern => |p| {
                for (p.elems) |elem| if (elem.target) |t| try tdzDeclarePattern(arena, declared, t);
                if (p.rest) |rest| try tdzDeclarePattern(arena, declared, rest);
            },
            else => {},
        }
    }

    /// Binding positions do not read their identifiers, but computed property
    /// names and defaults execute before BindingInitialization completes. Walk
    /// only those evaluation regions so `let [x = x] = []` and a reference to a
    /// later lexical binding select TDZ-checked frame bytecodes without treating
    /// every declared name as a false-positive read.
    fn tdzPatternRefsPending(pattern: *Node, m: *const SecureStringMapUnmanaged(ShadowBind), declared: *const SecureStringMapUnmanaged(void)) bool {
        return switch (pattern.*) {
            .identifier => false,
            .obj_pattern => |object| blk: {
                for (object.props) |property| {
                    if (property.key_expr) |key| if (tdzRefsPending(key, m, declared)) break :blk true;
                    if (property.default) |default| if (tdzRefsPending(default, m, declared)) break :blk true;
                    if (tdzPatternRefsPending(property.target, m, declared)) break :blk true;
                }
                if (object.rest) |rest| if (tdzPatternRefsPending(rest, m, declared)) break :blk true;
                break :blk false;
            },
            .arr_pattern => |array| blk: {
                for (array.elems) |element| {
                    if (element.default) |default| if (tdzRefsPending(default, m, declared)) break :blk true;
                    if (element.target) |target| if (tdzPatternRefsPending(target, m, declared)) break :blk true;
                }
                if (array.rest) |rest| if (tdzPatternRefsPending(rest, m, declared)) break :blk true;
                break :blk false;
            },
            else => false,
        };
    }

    fn tdzRefsPending(node: *Node, m: *const SecureStringMapUnmanaged(ShadowBind), declared: *const SecureStringMapUnmanaged(void)) bool {
        // The query is the disjunction the old per-binding scans implemented:
        // visit each identifier once, then test exact pending-lexical membership.
        // Keeping the shared exhaustive walker means new AST node kinds still
        // fail compilation until both capture and TDZ classification handle them.
        return nameRefInClosure(node, PendingLexicalReferences{
            .bindings = m,
            .declared = declared,
        }, true);
    }

    fn tdzScanStmt(arena: std.mem.Allocator, node: *Node, m: *const SecureStringMapUnmanaged(ShadowBind), declared: *SecureStringMapUnmanaged(void)) CompileError!bool {
        switch (node.*) {
            .var_decl => |d| {
                if (d.init) |init| if (tdzRefsPending(init, m, declared)) return true;
                if (d.kind != .@"var") try declared.put(arena, d.name, {});
            },
            .destructure_decl => |d| {
                if (tdzRefsPending(d.init, m, declared)) return true;
                if (d.kind != .@"var" and tdzPatternRefsPending(d.pattern, m, declared)) return true;
                if (d.kind != .@"var") try tdzDeclarePattern(arena, declared, d.pattern);
            },
            .expr_stmt => |expr| return tdzRefsPending(expr, m, declared),
            .return_stmt => |maybe| if (maybe) |expr| return tdzRefsPending(expr, m, declared),
            .throw_stmt => |expr| return tdzRefsPending(expr, m, declared),
            .if_stmt => |stmt| {
                if (tdzRefsPending(stmt.cond, m, declared)) return true;
                if (try tdzScanStmt(arena, stmt.consequent, m, declared)) return true;
                if (stmt.alternate) |alternate| if (try tdzScanStmt(arena, alternate, m, declared)) return true;
            },
            .while_stmt => |stmt| {
                if (tdzRefsPending(stmt.cond, m, declared)) return true;
                return tdzScanStmt(arena, stmt.body, m, declared);
            },
            .do_while_stmt => |stmt| {
                if (try tdzScanStmt(arena, stmt.body, m, declared)) return true;
                return tdzRefsPending(stmt.cond, m, declared);
            },
            .for_stmt => |stmt| {
                if (stmt.init) |init| if (try tdzScanStmt(arena, init, m, declared)) return true;
                if (stmt.cond) |cond| if (tdzRefsPending(cond, m, declared)) return true;
                if (stmt.update) |update| if (tdzRefsPending(update, m, declared)) return true;
                return tdzScanStmt(arena, stmt.body, m, declared);
            },
            .for_in => |stmt| {
                if (tdzRefsPending(stmt.iterable, m, declared)) return true;
                if (stmt.decl_kind) |kind| if (kind != .@"var") try tdzDeclarePattern(arena, declared, stmt.target);
                return tdzScanStmt(arena, stmt.body, m, declared);
            },
            .block => |stmts| for (stmts) |stmt| {
                if (try tdzScanStmt(arena, stmt, m, declared)) return true;
            },
            .decl_group => |stmts| for (stmts) |stmt| {
                if (try tdzScanStmt(arena, stmt, m, declared)) return true;
            },
            .switch_stmt => |stmt| {
                if (tdzRefsPending(stmt.disc, m, declared)) return true;
                for (stmt.cases) |case| {
                    if (case.@"test") |test_node| if (tdzRefsPending(test_node, m, declared)) return true;
                    for (case.body) |body_stmt| if (try tdzScanStmt(arena, body_stmt, m, declared)) return true;
                }
            },
            .labeled_stmt => |stmt| return tdzScanStmt(arena, stmt.body, m, declared),
            .try_stmt => |stmt| {
                if (try tdzScanStmt(arena, stmt.block, m, declared)) return true;
                if (stmt.catch_param) |param| try tdzDeclarePattern(arena, declared, param);
                if (stmt.catch_block) |catch_block| if (try tdzScanStmt(arena, catch_block, m, declared)) return true;
                if (stmt.finally_block) |finally_block| if (try tdzScanStmt(arena, finally_block, m, declared)) return true;
            },
            .func_decl => |function_node| if (tdzRefsPending(function_node.body, m, declared)) return true,
            else => return tdzRefsPending(node, m, declared),
        }
        return false;
    }

    /// Classify functions that need runtime TDZ checks. The conservative scan is
    /// retained as a code-shape decision: only these chunks receive checked
    /// lexical opcodes, so ordinary initialized `let` loops keep their existing
    /// native-tier and quickening eligibility.
    fn functionHasTdzHazard(
        arena: std.mem.Allocator,
        fnode: *const ast.FunctionNode,
        bindings: *const SecureStringMapUnmanaged(ShadowBind),
    ) CompileError!bool {
        if (fnode.is_expr_body) return false;
        var declared: SecureStringMapUnmanaged(void) = .{ .state = bindings.state };
        return tdzScanStmt(arena, fnode.body, bindings, &declared);
    }

    fn functionNeedsTdzChecks(arena: std.mem.Allocator, hash_state: *CompileHashState, fnode: *const ast.FunctionNode) CompileError!bool {
        const binding_inventory = try functionBindingInventory(arena, hash_state, fnode);
        if (binding_inventory.has_shadowing) return true;
        // With no lexical binding, no identifier can require a TDZ check. The
        // exhaustive inventory proves that negative without a second AST walk.
        if (!binding_inventory.has_lexical) return false;
        // A direct eval string is opaque to the static pending-reference walk:
        // it can name any lexical binding before that binding's declaration is
        // evaluated. FunctionDeclarationInstantiation still creates every such
        // binding uninitialized, so expose TDZ-marked activation slots to the
        // materialized direct-eval Environment from the first instruction.
        if (fnode.uses_direct_eval) return true;
        return functionHasTdzHazard(arena, fnode, &binding_inventory.bindings);
    }

    pub const PlainFunctionCode = struct {
        chunk: *Chunk,
        local_count: u32,
    };

    /// Stable audit reasons for plain functions that do not receive bytecode.
    /// Keep these semantic rather than AST-node-specific: profiles and admission
    /// inventories persist the tag names across compiler implementation changes.
    pub const PlainFunctionRejection = enum {
        generator_or_async,
        // Retired: every `using` / `await using` shape now lowers. Kept so the
        // persisted attribution key stays stable (it reports 0).
        function_scope_disposal,
        block_nested_function_declaration,
        lexical_shadowing,
        temporal_dead_zone,
        parameter_prologue,
        unsupported_lowering,
    };

    pub const PlainFunctionAdmission = union(enum) {
        compiled: PlainFunctionCode,
        rejected: PlainFunctionRejection,
    };

    /// Classify a plain function without collapsing every semantic barrier into
    /// `error.Unsupported`. The legacy compile API below deliberately retains its
    /// error contract while tier inventories consume this stable result.
    pub fn admitPlainFunction(arena: std.mem.Allocator, fnode: *const ast.FunctionNode) error{OutOfMemory}!PlainFunctionAdmission {
        var rejection: ?PlainFunctionRejection = null;
        var hash_state: CompileHashState = .{};
        const compiled = compilePlainFunctionInner(arena, fnode, &hash_state, &rejection) catch |err| switch (err) {
            error.Unsupported => return .{ .rejected = rejection orelse .unsupported_lowering },
            error.OutOfMemory => return error.OutOfMemory,
        };
        return .{ .compiled = compiled };
    }

    pub fn compilePlainFunction(arena: std.mem.Allocator, fnode: *const ast.FunctionNode) CompileError!PlainFunctionCode {
        return switch (try admitPlainFunction(arena, fnode)) {
            .compiled => |compiled| compiled,
            .rejected => error.Unsupported,
        };
    }

    fn rejectPlainFunction(rejection: *?PlainFunctionRejection, reason: PlainFunctionRejection) CompileError {
        rejection.* = reason;
        return error.Unsupported;
    }

    fn compilePlainParameterEntries(
        self: *Compiler,
        fnode: *const ast.FunctionNode,
        layout: *const PlainParameterLayout,
    ) CompileError!void {
        const saved_phase = self.function_binding_phase;
        self.function_binding_phase = .parameters;
        defer self.function_binding_phase = saved_phase;
        for (fnode.params, 0..) |parameter, index| {
            const input_name = layout.input_names[index] orelse parameter.name;
            if (parameter.is_rest and layout.hasDeferredRest())
                _ = try self.chunk.emit(.collect_rest_parameter, layout.slots[index]);
            if (parameter.default) |default| {
                // IteratorBindingInitialization selects an Initializer only for
                // exact undefined, never for null or another falsy primitive.
                try self.emitLoad(input_name);
                _ = try self.chunk.emit(.load_undefined, 0);
                _ = try self.chunk.emit(.eq_strict, 0);
                const provided = try self.chunk.emit(.jump_if_false, 0);
                try self.compileNamedExpr(default, if (parameter.pattern == null) parameter.name else null);
                try self.emitStore(input_name);
                _ = try self.chunk.emit(.pop, 0);
                self.chunk.patchToHere(provided);
            }
            if (parameter.pattern) |pattern| {
                try self.compilePattern(
                    pattern,
                    .{ .named = layout.input_names[index].? },
                    .var_declaration,
                );
            } else if (layout.input_names[index] != null) {
                // The raw call input is distinct from every visible binding in
                // a parameter-expression list. Initialize the formal only after
                // its own default completes, preserving later-formal TDZs.
                try self.emitLoad(input_name);
                const parameters = self.scope.?.parameter_names orelse return error.Unsupported;
                const binding = parameters.get(parameter.name) orelse return error.Unsupported;
                _ = try self.chunk.emit(.store_local, binding.slot);
                _ = try self.chunk.emit(.pop, 0);
            }
        }
    }

    fn emitParameterBodyCopies(self: *Compiler) CompileError!void {
        const scope = self.scope orelse return;
        const parameters = scope.parameter_names orelse return;
        const Copy = struct { parameter_slot: u32, body_slot: u32 };
        var copies: std.ArrayListUnmanaged(Copy) = .empty;
        var body_it = scope.names.iterator();
        while (body_it.next()) |body_entry| {
            const parameter = parameters.get(body_entry.key_ptr.*) orelse continue;
            try copies.append(self.arena, .{
                .parameter_slot = parameter.slot,
                .body_slot = body_entry.value_ptr.slot,
            });
        }
        std.mem.sort(Copy, copies.items, {}, struct {
            fn lessThan(_: void, left: Copy, right: Copy) bool {
                return left.body_slot < right.body_slot;
            }
        }.lessThan);
        for (copies.items) |copy| {
            _ = try self.chunk.emit(.load_local, copy.parameter_slot);
            _ = try self.chunk.emit(.store_local, copy.body_slot);
            _ = try self.chunk.emit(.pop, 0);
        }
    }

    fn compileClassInitializers(self: *Compiler, initializers: []const *ast.Node) CompileError!void {
        if (initializers.len == 0) return;
        const saved_scope = self.scope;
        const saved_field_initializer = self.in_field_initializer;
        self.scope = null;
        self.in_field_initializer = true;
        defer {
            self.scope = saved_scope;
            self.in_field_initializer = saved_field_initializer;
        }

        _ = try self.chunk.emit(.enter_field_initializers, 0);
        for (initializers) |initializer| try self.compileStmt(initializer);
        _ = try self.chunk.emit(.exit_field_initializers, 0);
    }

    fn compilePlainFunctionInner(arena: std.mem.Allocator, fnode: *const ast.FunctionNode, hash_state: *CompileHashState, rejection: *?PlainFunctionRejection) CompileError!PlainFunctionCode {
        if (fnode.is_generator or fnode.is_async)
            return rejectPlainFunction(rejection, .generator_or_async);
        // Shadowed lexicals receive distinct slots below. Conservatively check
        // every lexical in such a function until the TDZ scan itself is keyed by
        // binding identity rather than spelling.
        const tdz_checks = try functionNeedsTdzChecks(arena, hash_state, fnode);
        const scope = try arena.create(FnScope);
        scope.* = .{ .parent = null, .hash_state = hash_state, .names = .{ .state = hash_state }, .tdz_checks = tdz_checks };
        const parameter_layout = configurePlainParameters(arena, scope, fnode) catch |err| switch (err) {
            error.Unsupported => return rejectPlainFunction(rejection, .parameter_prologue),
            error.OutOfMemory => return error.OutOfMemory,
        };
        const arguments_slot = try addArgumentsSlot(arena, scope, fnode);
        try planFunctionDeclarations(arena, scope, fnode, arguments_slot != null);
        const mapped_parameter_indices = try configureMappedParameters(
            arena,
            scope,
            fnode,
            arguments_slot != null or functionSupportsLegacyArguments(fnode),
            arguments_slot != null,
        );

        const chunk = try arena.create(Chunk);
        chunk.* = Chunk.init(arena);
        chunk.param_count = @intCast(fnode.params.len);
        chunk.parameter_slots = parameter_layout.slots;
        chunk.destructuring_parameter_indices = parameter_layout.destructuring_indices;
        chunk.default_parameter_indices = parameter_layout.default_indices;
        chunk.rest_parameter_index = parameter_layout.rest_index;
        chunk.has_non_simple_parameters = parameter_layout.hasNonSimple();
        chunk.arguments_slot = arguments_slot;
        chunk.mapped_parameter_indices = mapped_parameter_indices;
        chunk.is_derived_constructor = fnode.is_derived_class_constructor;
        var c = Compiler{
            .arena = arena,
            .chunk = chunk,
            .mode = .function,
            .hash_state = hash_state,
            .scope = scope,
            .is_strict = fnode.is_strict,
            .is_derived_constructor = fnode.is_derived_class_constructor,
            .is_default_constructor = fnode.is_default_class_constructor,
            .derived_instance_initializers = if (fnode.is_derived_class_constructor) fnode.class_instance_initializers else &.{},
            .debug_checkpoints = true,
        };
        if (!fnode.is_derived_class_constructor) try c.compileClassInitializers(fnode.class_instance_initializers);
        // FunctionDeclarationInstantiation uses the same expression and pattern
        // semantics as body evaluation, under the parameter binding phase. Let
        // canonical lowering decide eligibility, preserving the causal audit
        // reason rather than maintaining a second syntax whitelist.
        c.compilePlainParameterEntries(fnode, &parameter_layout) catch |err| switch (err) {
            error.Unsupported => return rejectPlainFunction(rejection, .parameter_prologue),
            error.OutOfMemory => return error.OutOfMemory,
        };
        try c.emitParameterBodyCopies();
        if (fnode.is_expr_body) {
            try c.compileTailExpr(fnode.body);
        } else {
            try c.compileStmt(fnode.body);
            _ = try chunk.emit(.ret_undef, 0);
        }
        chunk.local_count = scope.count;
        chunk.mapped_parameter_indices = try finalizeMappedParameterIndices(arena, scope, mapped_parameter_indices);
        chunk.lexical_slots = scope.lexical_slots.items;
        try retainDebugLocalNames(arena, chunk, scope);
        try chunk.finalize();
        return .{ .chunk = chunk, .local_count = scope.count };
    }

    // ---- name resolution --------------------------------------------------

    fn resolve(self: *Compiler, name: []const u8) Resolved {
        var depth: u32 = 0;
        var environment_depth: u32 = 0;
        var scope = self.scope;
        var phase = self.function_binding_phase;
        while (scope) |sc| {
            const binding = if (phase == .parameters)
                sc.getParameter(name)
            else
                sc.get(name);
            if (binding) |resolved_binding| {
                if (resolved_binding.environment) return .{ .environment = resolved_binding };
                return if (depth == 0) .{ .local = resolved_binding } else .{ .upval = .{
                    .depth = depth,
                    .environment_depth = environment_depth - resolved_binding.lexical_environment_depth,
                    .binding = resolved_binding,
                } };
            }
            environment_depth += sc.parent_environment_depth;
            depth += 1;
            phase = sc.parent_binding_phase;
            scope = sc.parent;
        }
        return .global;
    }

    /// Count only the `with` records that can intervene before the statically
    /// resolved binding boundary. Declarative block/class environments are
    /// already represented by `resolve`; treating them as dynamic would add
    /// Reference slots to ordinary no-`with` code and block native fast paths.
    fn withDepthToResolution(self: *Compiler, name: []const u8) u32 {
        var depth = self.with_depth;
        var scope = self.scope;
        var phase = self.function_binding_phase;
        while (scope) |sc| {
            const binding = if (phase == .parameters)
                sc.getParameter(name)
            else
                sc.get(name);
            if (binding != null) return depth;
            depth += sc.parent_with_depth;
            phase = sc.parent_binding_phase;
            scope = sc.parent;
        }
        return depth;
    }

    /// Emit a load of `name` to the appropriate location (local / upvalue / global).
    fn emitLoad(self: *Compiler, name: []const u8) CompileError!void {
        if (try self.dynamicBindingReferencePlan(name)) |reference| {
            try self.emitLoadBindingReference(reference, false, false, false);
            return;
        }
        switch (self.resolve(name)) {
            .local => |binding| _ = try self.chunk.emit(if (binding.mapped_parameter) .load_local_mapped else if (binding.tdz_checked) .load_local_lexical else .load_local, binding.slot),
            .upval => |u| _ = try self.chunk.emitAB(if (u.binding.mapped_parameter) .load_upval_mapped else if (u.binding.tdz_checked) .load_upval_lexical else .load_upval, u.depth, u.binding.slot),
            .environment, .global => _ = try self.chunk.emit(.load_var, try self.chunk.addName(name)),
        }
    }

    /// Emit a store to `name` (assignment); leaves the value on the stack.
    fn emitStore(self: *Compiler, name: []const u8) CompileError!void {
        switch (self.resolve(name)) {
            .local => |binding| _ = if (binding.mapped_parameter)
                try self.chunk.emit(.store_local_mapped, binding.slot)
            else
                try self.chunk.emitAB(if (binding.tdz_checked or binding.immutable) .store_local_lexical else .store_local, binding.slot, @intFromBool(binding.immutable)),
            .upval => |u| _ = if (u.binding.mapped_parameter)
                try self.chunk.emitAB(.store_upval_mapped, u.depth, u.binding.slot)
            else
                try self.chunk.emitAB(if (u.binding.tdz_checked or u.binding.immutable) .store_upval_lexical else .store_upval, u.depth, u.binding.slot | (if (u.binding.immutable) @as(u32, 1) << 31 else 0)),
            .environment, .global => _ = try self.chunk.emit(.store_var, try self.chunk.addName(name)),
        }
    }

    fn bindingReferencePlan(self: *Compiler, name: []const u8) CompileError!?u32 {
        const resolved = self.resolve(name);
        const direct_eval_frame_depth: ?u32 = switch (resolved) {
            .local => |binding| if (binding.parameter_with_eval_boundary) 0 else null,
            // A parameter that acquires a nearer body binding names the frame
            // that DEFINES it; a name shadowed by this function's own sloppy
            // direct eval lands in THIS activation, hence depth 0.
            .upval => |upvalue| if (upvalue.binding.parameter_with_eval_boundary)
                upvalue.depth
            else if (self.scope != null and self.scope.?.may_extend_environment)
                0
            else
                null,
            .environment, .global => null,
        };
        const fallback: bc.BindingReferenceFallback = switch (resolved) {
            .local => |binding| .{
                .op = if (binding.mapped_parameter)
                    .store_local_mapped
                else if (binding.tdz_checked or binding.immutable)
                    .store_local_lexical
                else
                    .store_local,
                .a = binding.slot,
                .b = @intFromBool(binding.immutable),
            },
            .upval => |upvalue| .{
                .op = if (upvalue.binding.mapped_parameter)
                    .store_upval_mapped
                else if (upvalue.binding.tdz_checked or upvalue.binding.immutable)
                    .store_upval_lexical
                else
                    .store_upval,
                .a = upvalue.depth,
                .b = upvalue.binding.slot | (if (upvalue.binding.immutable) @as(u32, 1) << 31 else 0),
            },
            // A full Environment walk never selects its static fallback: it
            // captures an exact Environment/global-object/unresolvable base.
            .environment, .global => .{ .op = .store_var },
        };
        const environment_depth: u32 = switch (resolved) {
            .local => |binding| self.environment_depth - binding.lexical_environment_depth,
            .upval => |upvalue| self.environment_depth + upvalue.environment_depth,
            .environment, .global => bc.delete_name_full_environment_depth,
        };
        // With no intervening Environment Record, a frame/upvalue Reference is
        // already immutable compile-time state and needs no activation slot.
        if (environment_depth == 0 and direct_eval_frame_depth == null) switch (resolved) {
            .local, .upval => return null,
            .environment, .global => {},
        };
        const name_index = try self.chunk.addName(name);
        const index = try self.chunk.addBindingReferencePlan(.{
            .name_index = name_index,
            .environment_depth = environment_depth,
            .direct_eval_frame_depth = direct_eval_frame_depth,
            .fallback = fallback,
        });
        _ = try self.chunk.emit(.resolve_binding_ref, index);
        return index;
    }

    fn emitStoreBindingReference(self: *Compiler, index: u32) CompileError!void {
        _ = try self.chunk.emit(.store_binding_ref, index);
    }

    fn emitStoreBindingReferenceLeavingValue(self: *Compiler, index: u32) CompileError!void {
        _ = try self.chunk.emit(.dup, 0);
        try self.emitStoreBindingReference(index);
    }

    fn emitLoadBindingReference(
        self: *Compiler,
        index: u32,
        retain: bool,
        with_base: bool,
        allow_unresolvable: bool,
    ) CompileError!void {
        const flags = (if (retain) bc.binding_ref_load_retain else 0) |
            (if (with_base) bc.binding_ref_load_with_base else 0) |
            (if (allow_unresolvable) bc.binding_ref_load_allow_unresolvable else 0);
        _ = try self.chunk.emitAB(.load_binding_ref, index, flags);
    }

    fn emitClearBindingReference(self: *Compiler, index: u32) CompileError!void {
        _ = try self.chunk.emit(.clear_binding_ref, index);
    }

    /// A sloppy direct eval in this function's own body can create a `var` that
    /// shadows a binding this read would otherwise resolve in an ENCLOSING
    /// frame. The new binding lands in this activation's lazily materialized
    /// direct-eval variable record, which a statically resolved upvalue load
    /// never consults — so `var z = 1; (function(){ eval("var z = 7;"); return z; })()`
    /// read the outer 1 instead of the eval-created 7. Such reads take a
    /// binding reference whose `direct_eval_frame_depth` is this frame.
    fn readMayObserveOwnDirectEvalVar(self: *Compiler, resolved: anytype) bool {
        const scope = self.scope orelse return false;
        if (!scope.may_extend_environment) return false;
        return resolved == .upval;
    }

    fn dynamicBindingReferencePlan(self: *Compiler, name: []const u8) CompileError!?u32 {
        const resolved = self.resolve(name);
        const has_direct_eval_boundary = switch (resolved) {
            .local => |binding| binding.parameter_with_eval_boundary,
            .upval => |upvalue| upvalue.binding.parameter_with_eval_boundary,
            .environment, .global => false,
        };
        if (self.withDepthToResolution(name) == 0 and
            !has_direct_eval_boundary and
            !self.readMayObserveOwnDirectEvalVar(resolved)) return null;
        return try self.bindingReferencePlan(name);
    }

    /// Assignment creates its Reference before evaluating the RHS. Slot-backed
    /// no-`with` targets are immutable compile-time References; name-backed
    /// Environment/global targets require an activation-owned snapshot even
    /// without `with` so strict unresolvable and deletion/creation ordering is
    /// not delayed until PutValue.
    fn assignmentBindingReferencePlan(self: *Compiler, name: []const u8) CompileError!?u32 {
        if (self.withDepthToResolution(name) != 0) return try self.bindingReferencePlan(name);
        return switch (self.resolve(name)) {
            .local => |binding| if (binding.parameter_with_eval_boundary) try self.bindingReferencePlan(name) else null,
            .upval => |upvalue| if (upvalue.binding.parameter_with_eval_boundary) try self.bindingReferencePlan(name) else null,
            .environment, .global => try self.bindingReferencePlan(name),
        };
    }

    /// Emit a definition of `name` (var/let/const/function decl) with its value
    /// already on the stack; consumes the value.
    fn emitDefine(self: *Compiler, name: []const u8) CompileError!void {
        try self.emitDefineForce(name);
    }

    fn emitDefineForce(self: *Compiler, name: []const u8) CompileError!void {
        switch (self.resolve(name)) {
            .local => |binding| {
                _ = try self.chunk.emit(if (binding.mapped_parameter) .store_local_mapped else .store_local, binding.slot);
                _ = try self.chunk.emit(.pop, 0);
            },
            .upval => |u| {
                _ = try self.chunk.emitAB(if (u.binding.mapped_parameter) .store_upval_mapped else .store_upval, u.depth, u.binding.slot);
                _ = try self.chunk.emit(.pop, 0);
            },
            .environment => |binding| _ = try self.chunk.emitAB(.def_lex, try self.chunk.addName(name), if (binding.immutable) 2 else 1),
            .global => _ = try self.chunk.emitAB(.def_var, try self.chunk.addName(name), 2),
        }
    }

    /// `has_init` marks a `var x = init` (vs a bare `var x;`): only the
    /// initializer form may have its write redirected to a `with` object that
    /// provides `x` (ResolveBinding before PutValue) — a bare declaration never
    /// touches the `with` object.
    fn emitDefineKind(self: *Compiler, name: []const u8, kind: ast.DeclKind, has_init: bool) CompileError!void {
        switch (self.resolve(name)) {
            .local => |binding| {
                _ = try self.chunk.emit(if (binding.mapped_parameter) .store_local_mapped else .store_local, binding.slot);
                _ = try self.chunk.emit(.pop, 0);
            },
            .upval => |u| {
                _ = try self.chunk.emitAB(if (u.binding.mapped_parameter) .store_upval_mapped else .store_upval, u.depth, u.binding.slot);
                _ = try self.chunk.emit(.pop, 0);
            },
            .environment => |binding| _ = try self.chunk.emitAB(.def_lex, try self.chunk.addName(name), if (binding.immutable) 2 else 1),
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

    /// DeclarativeEnvironmentRecord creation happens before a block's first
    /// statement. Frame-mode bytecode models that by resetting every directly
    /// declared lexical slot to the realm's unique TDZ marker on each entry.
    /// The opcode is internal bookkeeping; the declaration's ordinary store is
    /// InitializeBinding, while later identifier assignments use checked stores.
    fn emitLexicalInitializer(self: *Compiler, name: []const u8) CompileError!void {
        if (self.scope == null) return;
        switch (self.resolve(name)) {
            .local => |binding| {
                if (!binding.tdz_checked) return;
                _ = try self.chunk.emit(.init_local_lexical, binding.slot);
            },
            .environment => {}, // its Environment Record is predeclared below
            else => return error.Unsupported,
        }
    }

    fn emitLexicalInitializersForNode(self: *Compiler, node: *Node) CompileError!void {
        switch (node.*) {
            .var_decl => |d| if (d.kind != .@"var") try self.emitLexicalInitializer(d.name),
            .destructure_decl => |d| if (d.kind != .@"var") try self.emitLexicalInitializersForPattern(d.pattern),
            .decl_group => |decls| for (decls) |decl| try self.emitLexicalInitializersForNode(decl),
            else => {},
        }
    }

    fn emitLexicalInitializersForList(self: *Compiler, stmts: []*Node) CompileError!void {
        if (self.scope == null) return;
        for (stmts) |stmt| try self.emitLexicalInitializersForNode(stmt);
    }

    fn predeclareLexicalNode(self: *Compiler, node: *Node) CompileError!void {
        const scope = self.scope orelse return;
        if (annex_b.functionDeclaration(node)) |declaration| {
            _ = try scope.addLexical(self.arena, declaration.func_decl.name, false);
            return;
        }
        switch (node.*) {
            .var_decl => |decl| {
                if (decl.kind != .@"var")
                    _ = try scope.addLexical(self.arena, decl.name, decl.kind == .@"const");
            },
            .destructure_decl => |decl| if (decl.kind != .@"var")
                try self.predeclareLexicalPattern(decl.pattern, decl.kind == .@"const"),
            .decl_group => |decls| for (decls) |decl| try self.predeclareLexicalNode(decl),
            else => {},
        }
    }

    fn predeclareLexicalList(self: *Compiler, stmts: []*Node) CompileError!void {
        if (self.scope == null) return;
        for (stmts) |stmt| try self.predeclareLexicalNode(stmt);
    }

    fn predeclareRepeatedBodyNode(self: *Compiler, node: *Node, captures: *const RepeatedBodyCaptures) CompileError!void {
        const scope = self.scope orelse return;
        if (annex_b.functionDeclaration(node)) |declaration| {
            const name = declaration.func_decl.name;
            if (captures.nameCaptured(name))
                try scope.addEnvironmentLexical(self.arena, name, false)
            else
                _ = try scope.addLexical(self.arena, name, false);
            return;
        }
        switch (node.*) {
            .var_decl => |declaration| {
                if (declaration.kind == .@"var") return;
                if (captures.nameCaptured(declaration.name))
                    try scope.addEnvironmentLexical(self.arena, declaration.name, declaration.kind == .@"const")
                else
                    _ = try scope.addLexical(self.arena, declaration.name, declaration.kind == .@"const");
            },
            .decl_group => |declarations| for (declarations) |declaration|
                try self.predeclareRepeatedBodyNode(declaration, captures),
            .destructure_decl => |declaration| {
                if (declaration.kind == .@"var") return;
                if (captures.patternCaptured(declaration.pattern))
                    try self.markEnvironmentLexicalPattern(declaration.pattern, declaration.kind == .@"const")
                else
                    try self.predeclareLexicalPattern(declaration.pattern, declaration.kind == .@"const");
            },
            else => {},
        }
    }

    fn predeclareRepeatedBodyList(self: *Compiler, stmts: []*Node, captures: *const RepeatedBodyCaptures) CompileError!void {
        for (stmts) |statement| try self.predeclareRepeatedBodyNode(statement, captures);
    }

    fn emitDeclareRepeatedBodyNode(self: *Compiler, node: *const Node, captures: *const RepeatedBodyCaptures) CompileError!void {
        switch (node.*) {
            .func_decl => |function| if (captures.nameCaptured(function.name))
                try self.emitDeclareEnvironmentLexicalName(function.name, false),
            .labeled_stmt => |statement| if (annex_b.functionDeclaration(statement.body) != null)
                try self.emitDeclareRepeatedBodyNode(statement.body, captures),
            .var_decl => |declaration| if (declaration.kind != .@"var" and captures.nameCaptured(declaration.name))
                try self.emitDeclareEnvironmentLexicalName(declaration.name, declaration.kind == .@"const"),
            .destructure_decl => |declaration| if (declaration.kind != .@"var" and captures.patternCaptured(declaration.pattern))
                try self.emitDeclareEnvironmentLexicalPattern(declaration.pattern, declaration.kind == .@"const"),
            .decl_group => |declarations| for (declarations) |declaration|
                try self.emitDeclareRepeatedBodyNode(declaration, captures),
            else => {},
        }
    }

    fn emitDeclareRepeatedBodyList(self: *Compiler, stmts: []*Node, captures: *const RepeatedBodyCaptures) CompileError!void {
        for (stmts) |statement| try self.emitDeclareRepeatedBodyNode(statement, captures);
    }

    fn repeatedBodyNodeNeedsEnvironment(node: *const Node, captures: *const RepeatedBodyCaptures) bool {
        return switch (node.*) {
            .func_decl => |function| captures.nameCaptured(function.name),
            .labeled_stmt => |statement| annex_b.functionDeclaration(statement.body) != null and
                repeatedBodyNodeNeedsEnvironment(statement.body, captures),
            .var_decl => |declaration| declaration.kind != .@"var" and captures.nameCaptured(declaration.name),
            .destructure_decl => |declaration| declaration.kind != .@"var" and captures.patternCaptured(declaration.pattern),
            .decl_group => |declarations| blk: {
                for (declarations) |declaration| if (repeatedBodyNodeNeedsEnvironment(declaration, captures)) break :blk true;
                break :blk false;
            },
            else => false,
        };
    }

    fn repeatedBodyListNeedsEnvironment(stmts: []*Node, captures: *const RepeatedBodyCaptures) bool {
        for (stmts) |statement| if (repeatedBodyNodeNeedsEnvironment(statement, captures)) return true;
        return false;
    }

    fn loopHeadSupportsEnvironment(node: *const Node) bool {
        return switch (node.*) {
            .var_decl => |decl| decl.kind != .@"var",
            .destructure_decl => |decl| decl.kind != .@"var" and patternSupportsEnvironment(decl.pattern),
            .decl_group => |decls| blk: {
                if (decls.len == 0) break :blk false;
                for (decls) |decl| if (!loopHeadSupportsEnvironment(decl)) break :blk false;
                break :blk true;
            },
            else => false,
        };
    }

    fn patternSupportsEnvironment(pattern: *const Node) bool {
        return patternSupportsEnvironmentNode(pattern);
    }

    fn markEnvironmentLexicalPattern(self: *Compiler, pattern: *const Node, immutable: bool) CompileError!void {
        const scope = self.scope orelse return;
        switch (pattern.*) {
            .identifier => |name| try scope.addEnvironmentLexical(self.arena, name, immutable),
            .obj_pattern => |object| {
                for (object.props) |property| try self.markEnvironmentLexicalPattern(property.target, immutable);
                if (object.rest) |rest| try self.markEnvironmentLexicalPattern(rest, immutable);
            },
            .arr_pattern => |array| {
                for (array.elems) |element| if (element.target) |target|
                    try self.markEnvironmentLexicalPattern(target, immutable);
                if (array.rest) |rest| try self.markEnvironmentLexicalPattern(rest, immutable);
            },
            else => return error.Unsupported,
        }
    }

    fn predeclareCheckedLexicalPattern(self: *Compiler, pattern: *const Node, immutable: bool) CompileError!void {
        const scope = self.scope orelse return error.Unsupported;
        switch (pattern.*) {
            .identifier => |name| _ = try scope.addLexicalChecked(self.arena, name, immutable),
            .obj_pattern => |object| {
                for (object.props) |property| try self.predeclareCheckedLexicalPattern(property.target, immutable);
                if (object.rest) |rest| try self.predeclareCheckedLexicalPattern(rest, immutable);
            },
            .arr_pattern => |array| {
                for (array.elems) |element| if (element.target) |target|
                    try self.predeclareCheckedLexicalPattern(target, immutable);
                if (array.rest) |rest| try self.predeclareCheckedLexicalPattern(rest, immutable);
            },
            else => return error.Unsupported,
        }
    }

    fn predeclareLexicalPattern(self: *Compiler, pattern: *const Node, immutable: bool) CompileError!void {
        const scope = self.scope orelse return error.Unsupported;
        switch (pattern.*) {
            .identifier => |name| _ = try scope.addLexical(self.arena, name, immutable),
            .obj_pattern => |object| {
                for (object.props) |property| try self.predeclareLexicalPattern(property.target, immutable);
                if (object.rest) |rest| try self.predeclareLexicalPattern(rest, immutable);
            },
            .arr_pattern => |array| {
                for (array.elems) |element| if (element.target) |target|
                    try self.predeclareLexicalPattern(target, immutable);
                if (array.rest) |rest| try self.predeclareLexicalPattern(rest, immutable);
            },
            else => return error.Unsupported,
        }
    }

    fn emitLexicalInitializersForPattern(self: *Compiler, pattern: *const Node) CompileError!void {
        switch (pattern.*) {
            .identifier => |name| try self.emitLexicalInitializer(name),
            .obj_pattern => |object| {
                for (object.props) |property| try self.emitLexicalInitializersForPattern(property.target);
                if (object.rest) |rest| try self.emitLexicalInitializersForPattern(rest);
            },
            .arr_pattern => |array| {
                for (array.elems) |element| if (element.target) |target|
                    try self.emitLexicalInitializersForPattern(target);
                if (array.rest) |rest| try self.emitLexicalInitializersForPattern(rest);
            },
            else => return error.Unsupported,
        }
    }

    fn markEnvironmentLexicalNode(self: *Compiler, node: *const Node) CompileError!void {
        const scope = self.scope orelse return;
        switch (node.*) {
            .var_decl => |decl| {
                if (decl.kind == .@"var") return error.Unsupported;
                try scope.addEnvironmentLexical(self.arena, decl.name, decl.kind == .@"const");
            },
            .destructure_decl => |decl| {
                if (decl.kind == .@"var") return error.Unsupported;
                try self.markEnvironmentLexicalPattern(decl.pattern, decl.kind == .@"const");
            },
            .decl_group => |decls| for (decls) |decl| try self.markEnvironmentLexicalNode(decl),
            else => return error.Unsupported,
        }
    }

    fn emitDeclareEnvironmentLexicalPattern(self: *Compiler, pattern: *const Node, immutable: bool) CompileError!void {
        switch (pattern.*) {
            .identifier => |name| try self.emitDeclareEnvironmentLexicalName(name, immutable),
            .obj_pattern => |object| {
                for (object.props) |property| try self.emitDeclareEnvironmentLexicalPattern(property.target, immutable);
                if (object.rest) |rest| try self.emitDeclareEnvironmentLexicalPattern(rest, immutable);
            },
            .arr_pattern => |array| {
                for (array.elems) |element| if (element.target) |target|
                    try self.emitDeclareEnvironmentLexicalPattern(target, immutable);
                if (array.rest) |rest| try self.emitDeclareEnvironmentLexicalPattern(rest, immutable);
            },
            else => return error.Unsupported,
        }
    }

    /// Create the loop-head DeclarativeEnvironmentRecord with every binding in
    /// its TDZ before any initializer/RHS evaluation. def_lex modes 3/4 consume
    /// the placeholder and install the realm TDZ marker as let/const.
    fn emitDeclareEnvironmentLexicalNode(self: *Compiler, node: *const Node) CompileError!void {
        switch (node.*) {
            .var_decl => |decl| {
                if (decl.kind == .@"var") return error.Unsupported;
                _ = try self.chunk.emit(.load_undefined, 0);
                _ = try self.chunk.emitAB(.def_lex, try self.chunk.addName(decl.name), if (decl.kind == .@"const") 4 else 3);
            },
            .destructure_decl => |decl| {
                if (decl.kind == .@"var") return error.Unsupported;
                try self.emitDeclareEnvironmentLexicalPattern(decl.pattern, decl.kind == .@"const");
            },
            .decl_group => |decls| for (decls) |decl| try self.emitDeclareEnvironmentLexicalNode(decl),
            else => return error.Unsupported,
        }
    }

    fn emitLoadEnvironmentLexicalPattern(self: *Compiler, pattern: *const Node) CompileError!void {
        switch (pattern.*) {
            .identifier => |name| _ = try self.chunk.emit(.load_var, try self.chunk.addName(name)),
            .obj_pattern => |object| {
                for (object.props) |property| try self.emitLoadEnvironmentLexicalPattern(property.target);
                if (object.rest) |rest| try self.emitLoadEnvironmentLexicalPattern(rest);
            },
            .arr_pattern => |array| {
                for (array.elems) |element| if (element.target) |target|
                    try self.emitLoadEnvironmentLexicalPattern(target);
                if (array.rest) |rest| try self.emitLoadEnvironmentLexicalPattern(rest);
            },
            else => return error.Unsupported,
        }
    }

    fn emitLoadEnvironmentLexicalNode(self: *Compiler, node: *const Node) CompileError!void {
        switch (node.*) {
            .var_decl => |decl| {
                if (decl.kind == .@"var") return error.Unsupported;
                _ = try self.chunk.emit(.load_var, try self.chunk.addName(decl.name));
            },
            .destructure_decl => |decl| {
                if (decl.kind == .@"var") return error.Unsupported;
                try self.emitLoadEnvironmentLexicalPattern(decl.pattern);
            },
            .decl_group => |decls| for (decls) |decl| try self.emitLoadEnvironmentLexicalNode(decl),
            else => return error.Unsupported,
        }
    }

    fn emitDefineEnvironmentLexicalPatternReverse(self: *Compiler, pattern: *const Node, immutable: bool) CompileError!void {
        switch (pattern.*) {
            .identifier => |name| _ = try self.chunk.emitAB(.def_lex, try self.chunk.addName(name), if (immutable) 2 else 1),
            .obj_pattern => |object| {
                if (object.rest) |rest| try self.emitDefineEnvironmentLexicalPatternReverse(rest, immutable);
                var index = object.props.len;
                while (index > 0) {
                    index -= 1;
                    try self.emitDefineEnvironmentLexicalPatternReverse(object.props[index].target, immutable);
                }
            },
            .arr_pattern => |array| {
                if (array.rest) |rest| try self.emitDefineEnvironmentLexicalPatternReverse(rest, immutable);
                var index = array.elems.len;
                while (index > 0) {
                    index -= 1;
                    if (array.elems[index].target) |target|
                        try self.emitDefineEnvironmentLexicalPatternReverse(target, immutable);
                }
            },
            else => return error.Unsupported,
        }
    }

    fn emitDefineEnvironmentLexicalNodeReverse(self: *Compiler, node: *const Node) CompileError!void {
        switch (node.*) {
            .var_decl => |decl| {
                if (decl.kind == .@"var") return error.Unsupported;
                _ = try self.chunk.emitAB(.def_lex, try self.chunk.addName(decl.name), if (decl.kind == .@"const") 2 else 1);
            },
            .destructure_decl => |decl| {
                if (decl.kind == .@"var") return error.Unsupported;
                try self.emitDefineEnvironmentLexicalPatternReverse(decl.pattern, decl.kind == .@"const");
            },
            .decl_group => |decls| {
                var index = decls.len;
                while (index > 0) {
                    index -= 1;
                    try self.emitDefineEnvironmentLexicalNodeReverse(decls[index]);
                }
            },
            else => return error.Unsupported,
        }
    }

    fn emitEnterEnvironmentLexicalNode(self: *Compiler, node: *const Node) CompileError!void {
        try self.emitEnterEnvironment();
        try self.emitDeclareEnvironmentLexicalNode(node);
    }

    fn emitDeclareEnvironmentLexicalName(self: *Compiler, name: []const u8, immutable: bool) CompileError!void {
        _ = try self.chunk.emit(.load_undefined, 0);
        _ = try self.chunk.emitAB(.def_lex, try self.chunk.addName(name), if (immutable) 4 else 3);
    }

    fn emitFreshEnvironmentLexicalName(self: *Compiler, name: []const u8, immutable: bool) CompileError!void {
        try self.emitExitEnvironment();
        try self.emitEnterEnvironment();
        try self.emitDeclareEnvironmentLexicalName(name, immutable);
    }

    fn emitFreshEnvironmentLexicalPattern(self: *Compiler, pattern: *const Node, immutable: bool) CompileError!void {
        try self.emitExitEnvironment();
        try self.emitEnterEnvironment();
        try self.emitDeclareEnvironmentLexicalPattern(pattern, immutable);
    }

    fn patternUsesEnvironment(self: *Compiler, pattern: *const Node) bool {
        return switch (pattern.*) {
            .identifier => |name| switch (self.resolve(name)) {
                .environment => true,
                else => false,
            },
            .obj_pattern => |object| blk: {
                for (object.props) |property| if (!self.patternUsesEnvironment(property.target)) break :blk false;
                if (object.rest) |rest| if (!self.patternUsesEnvironment(rest)) break :blk false;
                break :blk true;
            },
            .arr_pattern => |array| blk: {
                for (array.elems) |element| if (element.target) |target|
                    if (!self.patternUsesEnvironment(target)) break :blk false;
                if (array.rest) |rest| if (!self.patternUsesEnvironment(rest)) break :blk false;
                break :blk true;
            },
            else => false,
        };
    }

    /// CreatePerIterationEnvironment for a classic for-head: snapshot the old
    /// bindings on the operand stack, replace the current Environment Record by
    /// a fresh child of the same outer environment, then initialize the fresh
    /// bindings in reverse stack order.
    fn emitRenewEnvironmentLexicalNode(self: *Compiler, node: *const Node) CompileError!void {
        try self.emitLoadEnvironmentLexicalNode(node);
        try self.emitExitEnvironment();
        try self.emitEnterEnvironment();
        try self.emitDefineEnvironmentLexicalNodeReverse(node);
    }

    fn nodeDeclaresLexical(node: *const Node) bool {
        return switch (node.*) {
            .var_decl => |decl| decl.kind != .@"var",
            .destructure_decl => |decl| decl.kind != .@"var",
            .decl_group => |decls| for (decls) |decl| {
                if (nodeDeclaresLexical(decl)) break true;
            } else false,
            else => false,
        };
    }

    fn pushLexicalScope(self: *Compiler) CompileError!void {
        if (self.scope) |scope| try scope.pushLexicalScopeAtDepth(self.arena, self.environment_depth);
    }

    fn popLexicalScope(self: *Compiler) void {
        if (self.scope) |scope| scope.popLexicalScope();
    }

    fn emitEnterEnvironment(self: *Compiler) CompileError!void {
        try self.emitEnterEnvironmentFlags(0);
    }

    fn emitEnterEnvironmentFlags(self: *Compiler, flags: u32) CompileError!void {
        _ = try self.chunk.emit(.enter_block, flags);
        self.environment_depth += 1;
    }

    fn emitExitEnvironment(self: *Compiler) CompileError!void {
        std.debug.assert(self.environment_depth > 0);
        _ = try self.chunk.emit(.exit_block, 0);
        self.environment_depth -= 1;
    }

    fn emitEnterClassEnvironment(self: *Compiler) CompileError!void {
        try self.emitEnterEnvironmentFlags(bc.block_environment_class);
    }

    fn emitExitClassEnvironment(self: *Compiler) CompileError!void {
        std.debug.assert(self.environment_depth > 0);
        _ = try self.chunk.emit(.exit_block, bc.block_environment_class);
        self.environment_depth -= 1;
    }

    // ---- statements -------------------------------------------------------

    fn planEnvironmentDeclarations(self: *Compiler, stmts: []*Node, params: []const ast.Param, arguments_needed: bool) CompileError!void {
        std.debug.assert(self.scope == null);
        var variables = FnScope{ .parent = null, .hash_state = self.hash_state, .names = .{ .state = self.hash_state } };
        for (stmts) |statement| try collectFunctionLocals(self.arena, &variables, statement);
        var functions: std.ArrayListUnmanaged([]const u8) = .empty;
        var function_names = SecureStringMapUnmanaged(void){ .state = self.hash_state };
        var lexical: std.ArrayListUnmanaged(bc.EnvironmentDeclarations.Lexical) = .empty;
        for (stmts) |statement| {
            if (annex_b.functionDeclaration(statement)) |declaration| {
                const name = declaration.func_decl.name;
                if (!function_names.contains(name)) try functions.append(self.arena, name);
                try function_names.put(self.arena, name, {});
            } else try self.collectEnvironmentLexical(statement, &lexical);
        }
        const Collector = struct {
            compiler: *Compiler,
            variables: *const FnScope,
            functions: *const SecureStringMapUnmanaged(void),
            names: std.ArrayListUnmanaged(bc.EnvironmentDeclarations.AnnexB) = .empty,

            pub fn add(collector: *@This(), declaration: *Node, name: []const u8) CompileError!void {
                const index = std.math.cast(u32, collector.names.items.len) orelse return error.Unsupported;
                try collector.names.append(collector.compiler.arena, .{
                    .name = name,
                    .create_binding = !collector.variables.names.contains(name) and !collector.functions.contains(name),
                });
                try collector.compiler.environment_annex_b.put(collector.compiler.arena, collector.compiler.hash_state, @intFromPtr(declaration), index);
            }
        };
        var collector = Collector{ .compiler = self, .variables = &variables, .functions = &function_names };
        if (!self.is_strict)
            try annex_b.collect(CompileError, self.arena, stmts, 0, params, arguments_needed, &collector);
        self.chunk.environment_declarations = .{
            .lexical = lexical.items,
            .functions = functions.items,
            .variables = variables.slot_names.items,
            .annex_b = collector.names.items,
            .is_script = self.mode == .program,
        };
        if (lexical.items.len != 0 or functions.items.len != 0 or variables.count != 0 or collector.names.items.len != 0)
            _ = try self.chunk.emit(.init_declarations, 0);
    }

    fn collectEnvironmentLexical(self: *Compiler, node: *Node, out: *std.ArrayListUnmanaged(bc.EnvironmentDeclarations.Lexical)) CompileError!void {
        switch (node.*) {
            .var_decl => |declaration| if (declaration.kind != .@"var")
                try out.append(self.arena, .{ .name = declaration.name, .immutable = declaration.kind == .@"const" }),
            .destructure_decl => |declaration| if (declaration.kind != .@"var") {
                const Collector = struct {
                    out: *std.ArrayListUnmanaged(bc.EnvironmentDeclarations.Lexical),
                    immutable: bool,
                    fn add(collector: *@This(), arena: std.mem.Allocator, name: []const u8) CompileError!void {
                        try collector.out.append(arena, .{ .name = name, .immutable = collector.immutable });
                    }
                };
                var collector = Collector{ .out = out, .immutable = declaration.kind == .@"const" };
                try collectPatternBindingNames(self.arena, declaration.pattern, &collector);
            },
            .decl_group => |group| for (group) |declaration| try self.collectEnvironmentLexical(declaration, out),
            .class_expr => |class| if (class.name.len != 0)
                try out.append(self.arena, .{ .name = class.name, .immutable = false }),
            else => {},
        }
    }

    fn emitEnvironmentLexicals(self: *Compiler, stmts: []*Node) CompileError!void {
        var lexical: std.ArrayListUnmanaged(bc.EnvironmentDeclarations.Lexical) = .empty;
        for (stmts) |statement| try self.collectEnvironmentLexical(statement, &lexical);
        for (lexical.items) |binding| try self.emitDeclareEnvironmentLexicalName(binding.name, binding.immutable);
    }

    fn environmentBlockNeedsRecord(stmts: []*Node) bool {
        for (stmts) |statement| {
            if (annex_b.functionDeclaration(statement) != null or nodeDeclaresLexical(statement) or statement.* == .class_expr) return true;
        }
        return false;
    }

    fn compileEnvironmentBody(self: *Compiler, stmts: []*Node) CompileError!void {
        try self.emitHoistedFunctions(stmts, true);
        for (self.chunk.environment_declarations.variables) |name| {
            _ = try self.chunk.emit(.load_undefined, 0);
            _ = try self.chunk.emitAB(.def_var, try self.chunk.addName(name), 0);
        }
        try self.compileHoistedStmtList(stmts);
    }

    /// BlockDeclarationInstantiation runs before source-order evaluation. A
    /// switch uses this for the entire CaseBlock before testing any clause.
    fn emitHoistedFunctions(self: *Compiler, stmts: []*Node, variable_scope: bool) CompileError!void {
        var last_declarations = SecureStringMapUnmanaged(usize){ .state = self.hash_state };
        if (variable_scope) for (stmts, 0..) |statement, index| {
            if (annex_b.functionDeclaration(statement)) |declaration|
                try last_declarations.put(self.arena, declaration.func_decl.name, index);
        };
        for (stmts, 0..) |statement, index| if (annex_b.functionDeclaration(statement)) |declaration| {
            const function = declaration.func_decl;
            // Variable-scope instantiation selects only the last declaration
            // per name, preserving its source position (observable key order).
            if (variable_scope and last_declarations.get(function.name).? != index) continue;
            const fi = try self.compileFunction(declaration, function, false);
            _ = try self.chunk.emit(.make_closure, fi);
            if (self.scope == null)
                _ = try self.chunk.emitAB(if (variable_scope) .def_var else .def_lex, try self.chunk.addName(function.name), if (variable_scope) 3 else 1)
            else
                try self.emitDefineForce(function.name);
        };
    }

    fn emitAnnexBUpdate(self: *Compiler, declaration: *Node) CompileError!void {
        const scope = self.scope orelse {
            if (self.environment_annex_b.get(self.hash_state, @intFromPtr(declaration))) |index|
                _ = try self.chunk.emit(.copy_annex_b, index);
            return;
        };
        const variable_slot = scope.annex_b_variables.get(scope.hash_state, @intFromPtr(declaration)) orelse return;
        // B.3.2: GetBindingValue from this block's lexical record, then
        // SetMutableBinding on the function's VariableEnvironment directly.
        // Neither operation is ResolveBinding through an outer with object.
        const name = declaration.func_decl.name;
        const binding = scope.currentLexicalScope().get(name) orelse return error.Unsupported;
        if (binding.environment)
            _ = try self.chunk.emit(.load_var, try self.chunk.addName(name))
        else
            _ = try self.chunk.emit(.load_local, binding.slot);
        _ = try self.chunk.emit(.store_local, variable_slot);
        _ = try self.chunk.emit(.pop, 0);
    }

    fn compileHoistedStmtList(self: *Compiler, stmts: []*Node) CompileError!void {
        for (stmts) |s| {
            if (annex_b.functionDeclaration(s)) |declaration| {
                try self.emitAnnexBUpdate(declaration);
                continue;
            }
            try self.compileStmt(s);
        }
    }

    fn compileStmtList(self: *Compiler, stmts: []*Node) CompileError!void {
        try self.emitHoistedFunctions(stmts, false);
        try self.compileHoistedStmtList(stmts);
    }

    fn compileNamedExpr(self: *Compiler, node: *Node, name: ?[]const u8) CompileError!void {
        if (name) |inferred_name| {
            if (node.* == .class_expr and node.class_expr.name.len == 0)
                return self.compileClass(node, inferred_name, false);
        }
        try self.compileExpr(node);
        if (name) |inferred_name| try self.emitNamedEval(node, inferred_name);
    }

    /// Function NamedEvaluation has no intervening user effects. Class names
    /// instead enter ClassDefinitionEvaluation through compileNamedExpr.
    fn emitNamedEval(self: *Compiler, value_node: *const Node, name: []const u8) CompileError!void {
        const anon = switch (value_node.*) {
            .function => |f| f.name.len == 0,
            .func_decl => |f| f.name.len == 0,
            else => false,
        };
        if (anon) _ = try self.chunk.emit(.name_anon, try self.chunk.addName(name));
    }

    fn literalFunctionFlags(node: *const Node) u32 {
        if (node.* != .function) return 0;
        const function = node.function;
        return (if (function.is_method) bc.literal_function_method else @as(u32, 0)) |
            (if (function.name.len == 0) bc.literal_function_anonymous else @as(u32, 0));
    }

    fn compileStmt(self: *Compiler, node: *Node) CompileError!void {
        if (self.debug_checkpoints) try self.chunk.markDebugStatement(node);
        switch (node.*) {
            .var_decl => |d| {
                // FunctionDeclarationInstantiation already created every
                // function-scoped `var` as undefined (or as the existing
                // parameter value). A declaration without an initializer has
                // no runtime assignment and must not erase that parameter.
                if (d.kind == .@"var" and d.init == null) return;
                // BindingIdentifier evaluation creates the Reference before the
                // initializer. Only an activation-local Environment Record can
                // shadow this function's hoisted `var`, so ordinary declarations
                // retain their direct frame/global path.
                const binding_reference = if (d.kind == .@"var" and d.init != null and (self.scope == null or self.environment_depth != 0))
                    try self.bindingReferencePlan(d.name)
                else
                    null;
                if (d.init) |init_node| {
                    try self.compileNamedExpr(init_node, d.name);
                } else {
                    _ = try self.chunk.emit(.load_undefined, 0);
                }
                // `using x = v;` / `await using x = v;`: keep a copy of the resource
                // to register for DisposeResources at the variable scope's exit.
                if (d.dispose != 0) _ = try self.chunk.emit(.dup, 0);
                if (binding_reference) |reference|
                    try self.emitStoreBindingReference(reference)
                else
                    try self.emitDefineKind(d.name, d.kind, d.init != null);
                // A `for (using x = …;;)` head registers into the loop's resource
                // scope beneath its lexical head environment (see compileFor).
                if (d.dispose != 0) _ = try self.chunk.emitAB(.register_disposable, if (d.dispose == 2) 1 else 0, self.disposable_register_depth);
            },
            .destructure_decl => |d| {
                const environment_pattern = d.kind != .@"var" and
                    (self.scope == null or self.patternUsesEnvironment(d.pattern));
                try self.compileExpr(d.init);
                const src = try self.freshActivationTemp();
                try self.emitDefineActivationTemp(src);
                const mode: PatternMode = if (environment_pattern)
                    .{ .environment_lexical = d.kind == .@"const" }
                else if (d.kind == .@"var")
                    .var_declaration
                else
                    .lexical;
                // A var pattern inside a lexical block still targets the
                // variable record. Native Reference plans preserve that target
                // across getters/defaults and suspension in either storage mode.
                try self.compilePattern(d.pattern, src, mode);
            },
            .func_decl => |fnode| {
                // A bare Annex B IfStatement declaration has an implicit block.
                // Only the entered branch initializes its lexical/legacy pair.
                try self.pushLexicalScope();
                defer self.popLexicalScope();
                const captured_environment = self.scope == null or if (self.repeated_body_captures) |captures|
                    repeatedBodyNodeNeedsEnvironment(node, captures)
                else
                    false;
                if (self.repeated_body_captures) |captures|
                    try self.predeclareRepeatedBodyNode(node, captures)
                else
                    try self.predeclareLexicalNode(node);
                if (captured_environment) {
                    try self.emitEnterEnvironment();
                    if (self.scope != null) try self.emitDeclareRepeatedBodyNode(node, self.repeated_body_captures.?);
                }
                const fi = try self.compileFunction(node, fnode, false);
                _ = try self.chunk.emit(.make_closure, fi);
                if (self.scope == null)
                    _ = try self.chunk.emitAB(.def_lex, try self.chunk.addName(fnode.name), 1)
                else
                    try self.emitDefineForce(fnode.name);
                try self.emitAnnexBUpdate(node);
                if (captured_environment) try self.emitExitEnvironment();
            },
            .return_stmt => |maybe| {
                // A `return` that crosses a PENDING finally (one not currently
                // executing) must run it first: `abrupt_return` unwinds the
                // handler stack, runs each finally carrying a return completion,
                // and returns once they finish — a bare `ret` would skip it. A
                // return directly in a finally BODY crosses only enclosing
                // finallys, so `finally_depth > active_finally` is the real
                // "pending finally to run" test (not `finally_depth > 0`).
                if (self.finally_depth > self.active_finally) {
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
                // A function-body string ExpressionStatement is discarded.
                // Keep the two-instruction checkpoint/step shape for statement
                // hooks, but do not retain the `"use strict"` StringCell as a
                // movable constant: that otherwise makes every dynamically
                // strict call body ineligible for the native optimizer even
                // though the directive has no runtime value in function mode.
                if (self.mode == .function and e.* == .string and std.mem.eql(u8, e.string, "use strict"))
                    _ = try self.chunk.emit(.load_undefined, 0)
                else
                    try self.compileExpr(e);
                // TryStatement evaluation keeps the try/catch completion when a
                // finally completes normally; the finally body's own statement
                // values are discarded. `active_finally` is compile-time region
                // state, so no runtime completion scratch is introduced here.
                _ = try self.chunk.emit(if (self.mode == .program and self.active_finally == 0) .set_acc else .pop, 0);
            },
            .private_field_def => |field| {
                if (!self.in_field_initializer) return error.Unsupported;
                try self.compileExpr(field.value);
                _ = try self.chunk.emit(.init_private_field, try self.chunk.addName(field.name));
                _ = try self.chunk.emit(.pop, 0);
            },
            .debugger_stmt => _ = try self.chunk.emit(.nop, 0),
            .block => |stmts| {
                if (node == self.environment_function_body) {
                    try self.compileEnvironmentBody(stmts);
                    return;
                }
                try self.pushLexicalScope();
                defer self.popLexicalScope();
                const repeated_captures = self.repeated_body_captures;
                const captured_environment = if (self.scope == null)
                    environmentBlockNeedsRecord(stmts)
                else if (repeated_captures) |captures|
                    repeatedBodyListNeedsEnvironment(stmts, captures)
                else
                    false;
                const function_body = if (self.scope) |scope| node == scope.function_body else false;
                for (stmts) |statement| {
                    if (function_body and annex_b.functionDeclaration(statement) != null) continue;
                    if (repeated_captures) |captures|
                        try self.predeclareRepeatedBodyNode(statement, captures)
                    else
                        try self.predeclareLexicalNode(statement);
                }
                // A block with `using` declarations owns a declarative Environment
                // Record for its resources in both env mode and frame mode (a
                // frame-mode block's own lexicals stay in slots; the record only
                // carries what `register_disposable` appends).
                const disposable_scope = stmtListHasDisposableDecl(stmts);
                const await_using_count = if (disposable_scope and self.in_async) stmtListAwaitUsingDeclCount(stmts) else 0;
                if (disposable_scope) try self.emitEnterEnvironment();
                if (captured_environment and !disposable_scope) {
                    try self.emitEnterEnvironment();
                }
                if (self.scope == null) {
                    try self.emitEnvironmentLexicals(stmts);
                } else if (captured_environment) try self.emitDeclareRepeatedBodyList(stmts, repeated_captures.?);
                try self.emitLexicalInitializersForList(stmts);
                // DisposeResources runs on EVERY exit of the block — normal,
                // break/continue/return, or throw — with the block's completion
                // threaded through so a disposal error can wrap it in a
                // SuppressedError. That is a finally: the body runs under a
                // handler whose finally region disposes and then re-dispatches
                // the pending completion, and `finally_depth` is raised so
                // break/continue/return inside lower as `abrupt_*` and unwind
                // through it.
                const none = std.math.maxInt(u32);
                var dispose_handler: ?usize = null;
                if (disposable_scope) {
                    dispose_handler = try self.emitPushHandler(.push_handler, none, none);
                    self.finally_depth += 1;
                }
                try self.compileStmtList(stmts);
                if (dispose_handler) |handler| {
                    self.finally_depth -= 1;
                    try self.emitPopHandler();
                    _ = try self.chunk.emit(.push_completion, 0);
                    self.chunk.code.items[handler].b = @intCast(self.chunk.here());
                    if (await_using_count == 0) {
                        _ = try self.chunk.emit(.dispose_scope_completion, 0);
                    } else {
                        try self.emitAsyncDisposeRegion(await_using_count);
                    }
                    _ = try self.chunk.emit(.end_finally, 0);
                }
                if (captured_environment and !disposable_scope) try self.emitExitEnvironment();
                if (disposable_scope) try self.emitExitEnvironment();
            },
            .decl_group => |stmts| try self.compileStmtList(stmts),
            .if_stmt => |s| try self.compileIf(s.cond, s.consequent, s.alternate),
            .while_stmt => |s| try self.compileWhile(s.cond, s.body),
            .do_while_stmt => |s| try self.compileDoWhile(s.body, s.cond),
            .for_stmt => |f| try self.compileFor(f.init, f.cond, f.update, f.body),
            .break_stmt, .continue_stmt => |label| {
                const is_break = node.* == .break_stmt;
                const loop = (if (is_break) self.currentBreakTarget(label) else self.currentContinueTarget(label)) orelse
                    return error.Unsupported;
                // Every handler pushed since the target was entered belongs to a
                // construct this jump exits, so it is popped, and each one that
                // carries a finally runs first: `abrupt_*` unwinds exactly that
                // many handlers, then jumps to the (patched) target. The bound is
                // what keeps it out of the target's own for-in/for-of close
                // handler and out of a try/finally that lexically encloses the
                // target. With no handler to pop, a direct jump suffices; one
                // crossing a repeated-body environment unwinds to the target's
                // activation-local environment depth first.
                try self.emitDiscardActiveFinallyRecords(loop);
                const to_pop = self.handler_depth - loop.handler_depth;
                const op: bc.Op = if (to_pop > 0)
                    (if (is_break) .abrupt_break else .abrupt_continue)
                else if (self.environment_depth > loop.environment_depth)
                    .jump_env
                else
                    .jump;
                const operand = if (to_pop > 0) try self.abruptJumpOperand(loop) else loop.environment_depth;
                const j = try self.chunk.emitAB(op, 0, operand);
                try (if (is_break) &loop.breaks else &loop.continues).append(self.arena, j);
            },
            .switch_stmt => |sw| try self.compileSwitch(sw.disc, sw.cases),
            .throw_stmt => |e| {
                try self.compileExpr(e);
                _ = try self.chunk.emit(.throw_op, 0);
            },
            .for_in => |f| {
                if ((f.is_await or f.dispose == 2) and !self.in_async) return error.Unsupported;
                try self.compileForOf(f.decl_kind, f.target, f.var_init, f.iterable, f.body, !f.is_of, f.is_await, f.dispose);
            },
            .try_stmt => |t| try self.compileTry(t),
            .labeled_stmt => |l| {
                const target = try self.pushLabel(l.label, labeledStatementTargetsIteration(l.body));
                try self.compileStmt(l.body);
                for (target.breaks.items) |j| self.chunk.patchToHere(j);
                self.popLoop();
            },
            .with_stmt => |w| {
                // ECMA-262 WithStatement restores the outer environment for
                // every completion. Jumps carry their target environment depth,
                // handlers retain the exact unwind prefix, and function exit
                // restores the caller's activation.
                try self.compileExpr(w.obj);
                _ = try self.chunk.emit(.enter_with, 0);
                self.environment_depth += 1;
                self.with_depth += 1;
                try self.compileStmt(w.body);
                _ = try self.chunk.emit(.exit_with, 0);
                self.with_depth -= 1;
                self.environment_depth -= 1;
            },
            else => return error.Unsupported,
        }
    }

    fn catchPatternUsesEnvironment(self: *Compiler, pattern: *Node, catch_block: *Node) bool {
        if (self.scope == null) return true;
        _ = catch_block;
        return if (self.repeated_body_captures) |captures| captures.catchPatternCaptured(pattern) else false;
    }

    /// Create every catch-pattern binding before BindingInitialization begins.
    /// Captured bindings need a real Environment Record so repeated catches give
    /// closures fresh cells; uncaptured function-local bindings stay in checked
    /// frame slots and are reset to TDZ on every entry.
    fn prepareCatchPattern(self: *Compiler, pattern: *Node, catch_block: *Node) CompileError!bool {
        const environment = self.catchPatternUsesEnvironment(pattern, catch_block);
        if (environment) {
            try self.markEnvironmentLexicalPattern(pattern, false);
            // Annex B.3.5 exempts only a simple catch BindingIdentifier from
            // sloppy eval declaration conflicts, including captured catches.
            try self.emitEnterEnvironmentFlags(if (pattern.* == .identifier) bc.block_environment_simple_catch else 0);
            // A lone identifier is initialized immediately from the incoming
            // exception and cannot observe its own pre-initialization state.
            // Destructuring defaults/computed keys can observe sibling TDZs, so
            // only patterns need the predeclared marker-backed bindings.
            if (pattern.* != .identifier)
                try self.emitDeclareEnvironmentLexicalPattern(pattern, false);
        } else if (pattern.* == .identifier) {
            // A simple catch binding has no initializer expression that can
            // observe another binding in the catch scope, so it needs no TDZ
            // sentinel in a function-local frame slot.
            const scope = self.scope.?;
            _ = try scope.addLexical(self.arena, pattern.identifier, false);
            scope.markCurrentLexicalScopeCatchParameter();
        } else {
            try self.predeclareCheckedLexicalPattern(pattern, false);
            try self.emitLexicalInitializersForPattern(pattern);
        }
        return environment;
    }

    /// Consume the catch value on top of the operand stack and initialize a
    /// destructuring catch parameter from it in spec evaluation order.
    fn compileCatchPattern(self: *Compiler, pattern: *Node, environment: bool) CompileError!void {
        const source = try self.freshActivationTemp();
        try self.emitDefineActivationTemp(source);
        const mode: PatternMode = if (environment) .{ .environment_lexical = false } else .lexical;
        if (pattern.* == .identifier)
            try self.compilePatternTarget(pattern, source, mode)
        else
            try self.compilePattern(pattern, source, mode);
    }

    /// `try { B } [catch (binding) { C }] [finally { F }]` for the generator
    /// VM. A handler records the catch and/or finally targets; the VM unwinds to
    /// it on a throw. Catch BindingInitialization is emitted as ordinary
    /// bytecode, including defaults, computed keys, nested patterns and rest.
    fn compileTry(self: *Compiler, t: *const ast.TryNode) CompileError!void {
        const none = std.math.maxInt(u32);

        if (t.finally_block == null) {
            // try/catch (no finally) — handler with a catch arm only.
            const catch_block = t.catch_block orelse return error.Unsupported;
            const ph = try self.emitPushHandler(.push_handler, none, none);
            self.try_depth += 1;
            try self.compileStmt(t.block);
            self.try_depth -= 1;
            try self.emitPopHandler();
            const skip = try self.chunk.emit(.jump, 0);
            self.chunk.code.items[ph].a = @intCast(self.chunk.here());
            {
                try self.pushLexicalScope();
                defer self.popLexicalScope();
                if (t.catch_param) |p| {
                    const environment = try self.prepareCatchPattern(p, catch_block);
                    try self.compileCatchPattern(p, environment);
                    try self.compileStmt(catch_block);
                    if (environment) try self.emitExitEnvironment();
                } else {
                    _ = try self.chunk.emit(.pop, 0);
                    try self.compileStmt(catch_block);
                }
            }
            self.chunk.patchToHere(skip);
            return;
        }

        // A finally is present. Abrupt control flow carries both its eventual
        // target PC and target lexical-environment depth through the handler.
        self.finally_depth += 1;
        defer self.finally_depth -= 1;

        const ph = try self.emitPushHandler(.push_handler, none, none); // catch/finally patched below
        try self.compileStmt(t.block);
        try self.emitPopHandler();
        _ = try self.chunk.emit(.push_completion, 0); // normal completion of the try body
        const to_fin_normal = try self.chunk.emit(.jump, 0);

        var catch_start: ?usize = null;
        var ph2: ?usize = null;
        if (t.catch_block) |cb| {
            try self.pushLexicalScope();
            defer self.popLexicalScope();
            catch_start = self.chunk.here();
            var catch_environment = false;
            if (t.catch_param) |p| {
                // BindingInitialization may allocate or call user code and throw.
                // Install the finally-only handler first. The catch-specific form
                // records the depth below the incoming exception, which the
                // binding consumes, so every abrupt completion resumes the
                // finally with a clean operand stack.
                ph2 = try self.emitPushHandler(.push_handler_catch, none, none);
                catch_environment = try self.prepareCatchPattern(p, cb);
                try self.compileCatchPattern(p, catch_environment);
                try self.compileStmt(cb);
                try self.emitPopHandler();
                if (catch_environment) try self.emitExitEnvironment();
            } else {
                _ = try self.chunk.emit(.pop, 0);
                ph2 = try self.emitPushHandler(.push_handler, none, none);
                try self.compileStmt(cb);
                try self.emitPopHandler();
            }
            _ = try self.chunk.emit(.push_completion, 0); // normal completion of the catch body
        }

        const fin = self.chunk.here();
        self.chunk.patchTo(to_fin_normal, fin);
        self.chunk.code.items[ph].a = if (catch_start) |cs| @intCast(cs) else none; // throw → catch, else finally
        self.chunk.code.items[ph].b = @intCast(fin);
        if (ph2) |p2| self.chunk.code.items[p2].b = @intCast(fin);
        // We are now compiling the finally BODY: mark it active (see
        // `active_finally`) so a tail `return f()` directly in the finally is a
        // proper tail call (test262 tco-finally / tco-catch-finally) rather than
        // an abrupt_return that grows the native stack — WITHOUT lowering
        // `finally_depth`, which break/continue inside the finally still need for
        // correct abrupt-vs-plain lowering against enclosing loops.
        self.active_finally += 1;
        {
            defer self.active_finally -= 1;
            try self.compileStmt(t.finally_block.?);
        }
        _ = try self.chunk.emit(.end_finally, 0);
    }

    /// `switch (disc) { case t: ... default: ... }` — evaluate the discriminant
    /// once, then a chain of strict-equality tests jumping to each clause body
    /// (fall-through preserved). `break` exits via the switch's break list;
    /// `default` is taken only after every case test fails.
    fn compileSwitch(self: *Compiler, disc: *Node, cases: []const ast.SwitchCase) CompileError!void {
        try self.compileExpr(disc);
        const d = try self.freshActivationTemp();
        try self.emitDefineActivationTemp(d);

        try self.pushLexicalScope();
        defer self.popLexicalScope();
        const repeated_captures = self.repeated_body_captures;
        var captured_environment = false;
        for (cases) |case| {
            if (self.scope == null) {
                captured_environment = captured_environment or environmentBlockNeedsRecord(case.body);
                continue;
            }
            if (repeated_captures) |captures| {
                try self.predeclareRepeatedBodyList(case.body, captures);
                captured_environment = captured_environment or repeatedBodyListNeedsEnvironment(case.body, captures);
            } else try self.predeclareLexicalList(case.body);
        }

        // The whole CaseBlock is one lexical scope. Its bindings enter the TDZ
        // after discriminant evaluation but before any case-test evaluation.
        if (captured_environment) {
            try self.emitEnterEnvironment();
            for (cases) |case| {
                if (self.scope == null)
                    try self.emitEnvironmentLexicals(case.body)
                else
                    try self.emitDeclareRepeatedBodyList(case.body, repeated_captures.?);
            }
        }
        if (self.scope != null) for (cases) |case| try self.emitLexicalInitializersForList(case.body);
        // Instantiate the whole CaseBlock, including clauses that never execute.
        for (cases) |case| try self.emitHoistedFunctions(case.body, false);

        const sw = try self.pushLoop();
        sw.is_switch = true;
        const body_jumps = try self.arena.alloc(usize, cases.len);
        const default_marker = std.math.maxInt(usize);
        for (cases, 0..) |c, i| {
            if (c.@"test") |t| {
                try self.emitLoadActivationTemp(d);
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
            try self.compileHoistedStmtList(c.body);
        }
        const end = self.chunk.here();
        self.chunk.patchTo(to_default, default_target orelse end);
        for (sw.breaks.items) |j| self.chunk.patchTo(j, end);
        self.popLoop();
        if (captured_environment) try self.emitExitEnvironment();
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

    fn compileRepeatedBody(self: *Compiler, body: *Node) CompileError!void {
        if (self.scope == null) return self.compileStmt(body);
        var captures = try RepeatedBodyCaptures.init(self.arena, self.hash_state, body);
        if (!captures.any()) return self.compileStmt(body);
        if (!repeatedBodyCapturesSupported(body, &captures)) return error.Unsupported;
        const saved_captures = self.repeated_body_captures;
        self.repeated_body_captures = &captures;
        defer self.repeated_body_captures = saved_captures;
        try self.compileStmt(body);
    }

    fn compileWhile(self: *Compiler, cond: *Node, body: *Node) CompileError!void {
        const loop = try self.pushLoop();
        const cond_at = self.chunk.here();
        try self.compileExpr(cond);
        const to_end = try self.chunk.emit(.jump_if_false, 0);
        try self.compileRepeatedBody(body);
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
        try self.compileRepeatedBody(body);
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
        // A captured lexical head uses a real declarative Environment Record:
        // closures capture that record, and the update edge replaces it with a
        // value-copied record per CreatePerIterationEnvironment. Uncaptured heads
        // retain O(1) frame slots. Environment-backed patterns lower their
        // defaults and computed keys as bytecode in the active binding scope.
        // `for (using x = …;;)`: ForLoopEvaluation disposes loopEnv's resources
        // once, after ForBodyEvaluation, with the loop's completion — a finally
        // around the whole statement. The per-iteration copies replace the
        // lexical head record, so the resource is registered one record down,
        // in a scope entered before the head. An `await using` head disposes
        // through the awaiting region instead; it only parses in an async body,
        // so a non-async activation seeing one is a context the compiler does
        // not model and tree-walks.
        const head_await_using_count = if (init_node) |ini| stmtAwaitUsingDeclCount(ini) else 0;
        if (head_await_using_count != 0 and !self.in_async) return error.Unsupported;
        const head_using = if (init_node) |ini| stmtHasDisposableDecl(ini) else false;
        const none = std.math.maxInt(u32);
        var head_dispose_handler: ?usize = null;
        if (head_using) {
            try self.emitEnterEnvironment();
            head_dispose_handler = try self.emitPushHandler(.push_handler, none, none);
            self.finally_depth += 1;
        }
        const captured_head = if (init_node) |ini|
            if (self.scope == null) nodeDeclaresLexical(ini) else try forLoopCapturesLexical(self.arena, self.hash_state, ini, cond, update, body)
        else
            false;
        if (captured_head and !loopHeadSupportsEnvironment(init_node.?))
            return error.Unsupported;
        const lexical_scope = if (init_node) |init| nodeDeclaresLexical(init) else false;
        if (lexical_scope) {
            try self.pushLexicalScope();
            if (captured_head)
                try self.markEnvironmentLexicalNode(init_node.?)
            else
                try self.predeclareLexicalNode(init_node.?);
        }
        defer if (lexical_scope) self.popLexicalScope();
        if (captured_head) try self.emitEnterEnvironmentLexicalNode(init_node.?);
        if (init_node) |ini| {
            if (!captured_head) try self.emitLexicalInitializersForNode(ini);
            // The init clause is a declaration statement (var_decl, or a group of
            // them for multiple declarators) or a bare expression.
            if (ini.* == .var_decl or ini.* == .destructure_decl or ini.* == .block or ini.* == .decl_group) {
                const saved_register_depth = self.disposable_register_depth;
                self.disposable_register_depth = if (head_using and captured_head) 1 else 0;
                defer self.disposable_register_depth = saved_register_depth;
                try self.compileStmt(ini);
            } else {
                try self.compileExpr(ini);
                _ = try self.chunk.emit(.pop, 0);
            }
        }
        // ForBodyEvaluation step 2: CreatePerIterationEnvironment runs ONCE
        // before the first test, not only on the update edge (step 3.e). Without
        // it a closure built in the head — `for (let x = 'outside', _ = f = () =>
        // x; ...)` — captures the same record the body then assigns into, so it
        // observed 'inside'. The tree walker has always taken this initial copy.
        if (captured_head) try self.emitRenewEnvironmentLexicalNode(init_node.?);
        const loop = try self.pushLoop();
        const cond_at = self.chunk.here();
        var to_end: ?usize = null;
        if (cond) |c| {
            try self.compileExpr(c);
            to_end = try self.chunk.emit(.jump_if_false, 0);
        }
        try self.compileRepeatedBody(body);
        const update_at = self.chunk.here();
        if (captured_head) try self.emitRenewEnvironmentLexicalNode(init_node.?);
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
        if (captured_head) try self.emitExitEnvironment();
        if (head_dispose_handler) |handler| {
            self.finally_depth -= 1;
            try self.emitPopHandler();
            _ = try self.chunk.emit(.push_completion, 0);
            self.chunk.code.items[handler].b = @intCast(self.chunk.here());
            if (head_await_using_count == 0) {
                _ = try self.chunk.emit(.dispose_scope_completion, 0);
            } else {
                try self.emitAsyncDisposeRegion(head_await_using_count);
            }
            _ = try self.chunk.emit(.end_finally, 0);
            try self.emitExitEnvironment();
        }
    }

    /// Bind the current loop value (on the stack) to a loop target — an
    /// identifier (fast path) or a destructuring pattern / member target (via
    /// `bind_pattern`, reusing the tree-walker's destructuring). `for-in` uses
    /// an engine-owned candidate array that is never exposed to user iterators.
    fn compileLoopBind(self: *Compiler, decl_kind: ?ast.DeclKind, target: *Node, force_environment: bool, native_pattern: bool, shape: bc.NotAReference) CompileError!void {
        if (decl_kind == null and target.* == .call) {
            // The iteration value has already been produced (and, for for-of,
            // the close-protected region entered), matching the tree walker's
            // order: value first, then the target reference, then the throw.
            _ = try self.chunk.emit(.pop, 0);
            return self.emitCallTargetRejection(target, shape, false);
        }
        if (target.* == .identifier) {
            // ForIn/OfBodyEvaluation step 6.d: a `var` ForBinding is resolved
            // like an assignment — ResolveBinding then PutValue — so it writes
            // whatever binding `x` names at the loop, not the hoisted `var`
            // itself. The two differ inside `catch (x) { for (var x in o) … }`
            // (Annex B.3.4 permits the redeclaration): the catch parameter is
            // nearer and receives the keys, which a `def_var` on the variable
            // scope silently bypassed. let/const still initialize their fresh
            // per-iteration binding.
            if (decl_kind == null or decl_kind.? == .@"var") {
                try self.emitStore(target.identifier);
                _ = try self.chunk.emit(.pop, 0);
            } else if (force_environment) {
                _ = try self.chunk.emitAB(.def_lex, try self.chunk.addName(target.identifier), if (decl_kind.? == .@"const") 2 else 1);
            } else try self.emitDefine(target.identifier);
            return;
        }
        if (native_pattern and decl_kind == null and (target.* == .member or target.* == .super_member)) {
            // Assignment targets are evaluated after the next iteration value
            // has been selected. Preserve that value in activation-local storage
            // while resolving the one-shot base/key Reference.
            const value_name = try self.freshActivationTemp();
            try self.emitDefineActivationTemp(value_name);
            const reference = (try self.preEvalPatternAssignmentRef(target, .assignment_native)) orelse return error.Unsupported;
            try self.storePatternAssignmentRef(target, reference, value_name);
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
            const src = try self.freshActivationTemp();
            try self.emitDefineActivationTemp(src); // consume the loop value from the stack
            try self.compileAssignPattern(target, src);
            return;
        }
        if (force_environment and (native_pattern or patternHasEvaluationExpressions(target)) and (target.* == .arr_pattern or target.* == .obj_pattern)) {
            const src = try self.freshActivationTemp();
            try self.emitDefineActivationTemp(src);
            try self.compilePattern(target, src, .{ .environment_lexical = decl_kind.? == .@"const" });
            return;
        }
        if (native_pattern and (target.* == .arr_pattern or target.* == .obj_pattern)) {
            const value_name = try self.freshActivationTemp();
            try self.emitDefineActivationTemp(value_name);
            if (decl_kind) |kind| if (kind != .@"var")
                try self.emitLexicalInitializersForPattern(target);
            const mode: PatternMode = if (decl_kind) |kind|
                if (kind == .@"var") .var_declaration else .lexical
            else
                .assignment_native;
            try self.compilePattern(target, value_name, mode);
            return;
        }
        // `bind_pattern` destructures into the live environment. That is the
        // binding scope in env-mode and for a captured head whose static names
        // were deliberately mapped to the active per-iteration environment. An
        // ordinary slot-allocated pattern still falls back to the tree-walker.
        if (self.scope != null and !force_environment) return error.Unsupported;
        const pi = try self.chunk.addPattern(target);
        const mode: u32 = if (decl_kind) |k| switch (k) {
            .@"var" => 0,
            .let => 1,
            .@"const" => 2,
        } else 3;
        _ = try self.chunk.emitAB(.bind_pattern, pi, mode);
    }

    fn compileForOf(self: *Compiler, decl_kind: ?ast.DeclKind, target: *Node, var_init: ?*Node, iterable: *Node, body: *Node, keys_first: bool, await_each: bool, head_dispose: u8) CompileError!void {
        // 0: plain head; 1: `for (using x of …)`; 2: `for (await using x of …)`.
        const head_using = head_dispose != 0;
        // A captured simple lexical target uses a fresh declarative Environment
        // Record for every iterator result. That is the ForIn/OfBodyEvaluation
        // binding cell the closure captures; an uncaptured identifier stays in a
        // frame slot. Environment-backed patterns lower defaults and computed
        // keys directly, so every iterator result initializes the fresh record.
        const captured_binding = if (decl_kind) |kind|
            kind != .@"var" and try forOfCapturesLexical(self.arena, self.hash_state, target, var_init, iterable, body)
        else
            false;
        const program_lexical_binding = self.scope == null and if (decl_kind) |kind| kind != .@"var" else false;
        // `for (using x of …)` registers each iteration's resource in that
        // iteration's own Environment Record, so the head always gets one.
        const environment_binding = captured_binding or program_lexical_binding or head_using;
        if (environment_binding and !patternSupportsEnvironment(target)) return error.Unsupported;
        const lexical_scope = self.scope != null and if (decl_kind) |kind|
            kind != .@"var" and (target.* == .identifier or target.* == .arr_pattern or target.* == .obj_pattern)
        else
            false;
        if (lexical_scope) {
            try self.pushLexicalScope();
            if (captured_binding) {
                if (target.* == .identifier)
                    try self.scope.?.addEnvironmentLexical(self.arena, target.identifier, decl_kind.? == .@"const")
                else
                    try self.markEnvironmentLexicalPattern(target, decl_kind.? == .@"const");
            } else if (target.* == .arr_pattern or target.* == .obj_pattern) {
                try self.predeclareCheckedLexicalPattern(target, decl_kind.? == .@"const");
            } else {
                _ = try self.scope.?.addLexical(self.arena, target.identifier, decl_kind.? == .@"const");
            }
        }
        defer if (lexical_scope) self.popLexicalScope();
        const iterator_temp = try self.freshProtocolTemp();
        const result_temp = try self.freshProtocolTemp();

        // ForIn/OfHeadEvaluation creates lexical head bindings before evaluating
        // the RHS, so `for (let x of x)` observes x's TDZ rather than an outer x.
        if (environment_binding) {
            try self.emitEnterEnvironment();
            if (target.* == .identifier)
                try self.emitDeclareEnvironmentLexicalName(target.identifier, decl_kind.? == .@"const")
            else
                try self.emitDeclareEnvironmentLexicalPattern(target, decl_kind.? == .@"const");
        } else if (decl_kind) |kind| if (kind != .@"var") {
            if (target.* == .identifier)
                try self.emitLexicalInitializer(target.identifier)
            else if (target.* == .arr_pattern or target.* == .obj_pattern)
                try self.emitLexicalInitializersForPattern(target);
        };

        if (var_init) |ini| {
            try self.compileExpr(ini);
            try self.compileLoopBind(decl_kind, target, environment_binding, keys_first, .assignment);
        }
        try self.compileExpr(iterable);
        if (keys_first) {
            try self.compileForInKeys(decl_kind, target, body, environment_binding);
            return;
        }
        // for-await uses the async-iterator protocol (Symbol.asyncIterator, else
        // a wrapped sync iterator) and awaits each `next()` result.
        _ = try self.chunk.emit(if (await_each) .async_iter_of else .iter_of, 0);
        try self.emitDefineActivationTemp(iterator_temp);
        // GetIterator reads the iterator's `next` method exactly ONCE (it becomes
        // the Iterator Record's [[NextMethod]]); cache it so a `next` accessor is
        // not re-read each iteration.
        const next_temp = try self.freshProtocolTemp();
        try self.emitLoadActivationTemp(iterator_temp);
        _ = try self.chunk.emit(.get_prop, try self.chunk.addName("next"));
        try self.emitDefineActivationTemp(next_temp);

        const done_temp = try self.freshProtocolTemp();
        // This flag tracks whether an abrupt completion must close the iterator.
        // It becomes false only after IteratorValue succeeds: throws from
        // `next()`, `done`, or `value` precede the close-protected binding/body
        // region in ForIn/OfBodyEvaluation and do not perform IteratorClose.
        _ = try self.chunk.emit(.load_true, 0);
        try self.emitDefineActivationTemp(done_temp);

        const none = std.math.maxInt(u32);
        const ph = try self.emitPushHandler(.push_handler, none, none);
        // A `return` (or a labeled break/continue) crossing this for-of must run
        // IteratorClose — the handler's finally_pc. Route it through abrupt_return
        // like a finally by raising finally_depth. Bump BEFORE pushLoop so the loop
        // records the raised depth: a plain `break`/`continue` targeting THIS loop
        // stays a plain jump (it has its own explicit close block), while a return
        // or an outer-targeted break unwinds to the close handler.
        self.finally_depth += 1;
        const loop = try self.pushLoop();
        const top = self.chunk.here();
        // r = it.next()  (for-await: r = await it.next()) — the cached `next`,
        // invoked with this=it via call_with_this (no second property lookup).
        try self.emitLoadActivationTemp(next_temp);
        try self.emitLoadActivationTemp(iterator_temp);
        _ = try self.chunk.emitAB(.call_with_this, 0, 0);
        if (await_each) _ = try self.chunk.emit(.await_op, 0); // await the next() result
        _ = try self.chunk.emit(.assert_iter_result, 0); // IteratorNext: result must be an Object
        try self.emitDefineActivationTemp(result_temp);
        // if (r.done) break  — `not` then jump_if_false exits exactly when done.
        try self.emitLoadActivationTemp(result_temp);
        _ = try self.chunk.emit(.get_prop, try self.chunk.addName("done"));
        _ = try self.chunk.emit(.not, 0);
        const to_end = try self.chunk.emit(.jump_if_false, 0);
        // IteratorValue itself is outside IteratorClose. Leave its value on the
        // operand stack, then arm the close handler for environment creation,
        // target binding, and body evaluation.
        try self.emitLoadActivationTemp(result_temp);
        _ = try self.chunk.emit(.get_prop, try self.chunk.addName("value"));
        _ = try self.chunk.emit(.load_false, 0);
        try self.emitStoreActivationTempDiscard(done_temp);
        if (environment_binding) {
            if (target.* == .identifier)
                try self.emitFreshEnvironmentLexicalName(target.identifier, decl_kind.? == .@"const")
            else
                try self.emitFreshEnvironmentLexicalPattern(target, decl_kind.? == .@"const");
        }
        // Bind the already-read value to the loop target. Abrupt target
        // resolution/destructuring is inside the close-protected region.
        // A member/super assignment target lowers natively too (the one-shot
        // base/key Reference after the iteration value, then the put): a
        // slot-allocated function body has no environment for `bind_pattern`
        // to write through, so the fallback path used to reject it.
        const native_pattern = target.* == .arr_pattern or target.* == .obj_pattern or
            (decl_kind == null and (target.* == .member or target.* == .super_member));
        if (head_using) _ = try self.chunk.emit(.dup, 0);
        try self.compileLoopBind(decl_kind, target, environment_binding, native_pattern, .for_of);
        // `for (using x of …)`: the bound value is this iteration's resource,
        // disposed at the END of the iteration — before the next `next()` — and
        // on any abrupt exit of the body, before IteratorClose. That is a
        // finally around the body: its handler is pushed after the iteration
        // environment exists, so an unwind restores exactly that record before
        // disposing, and it is popped before the close handler runs.
        var iteration_dispose_handler: ?usize = null;
        if (head_using) {
            _ = try self.chunk.emitAB(.register_disposable, if (head_dispose == 2) 1 else 0, 0);
            iteration_dispose_handler = try self.emitPushHandler(.push_handler, none, none);
            self.finally_depth += 1;
        }
        try self.compileRepeatedBody(body);
        if (iteration_dispose_handler) |handler| {
            self.finally_depth -= 1;
            try self.emitPopHandler();
            _ = try self.chunk.emit(.push_completion, 0);
            self.chunk.code.items[handler].b = @intCast(self.chunk.here());
            // One resource per iteration; an `await using` head awaits it.
            if (head_dispose == 2) {
                try self.emitAsyncDisposeRegion(1);
            } else {
                _ = try self.chunk.emit(.dispose_scope_completion, 0);
            }
            _ = try self.chunk.emit(.end_finally, 0);
        }
        const continue_target = self.chunk.here();
        _ = try self.chunk.emit(.load_true, 0);
        try self.emitStoreActivationTempDiscard(done_temp);
        _ = try self.chunk.emit(.jump, @intCast(top));
        // `continue` re-enters the loop at the top (next .next()) without
        // closing; clear the active-close flag first.
        for (loop.continues.items) |j| self.chunk.patchTo(j, continue_target);
        // Normal completion (the iterator reported `done`): it is already
        // exhausted, so it is NOT closed — control just exits the loop.
        self.chunk.patchToHere(to_end);
        _ = try self.chunk.emit(.load_true, 0);
        try self.emitStoreActivationTempDiscard(done_temp);
        // `break` is an abrupt completion, so it must run IteratorClose (which
        // throws if `return` is present-but-non-callable or returns a non-object).
        // The normal-done path above jumps over this close block.
        if (loop.breaks.items.len > 0) {
            const skip_close = try self.chunk.emit(.jump, 0);
            for (loop.breaks.items) |j| self.chunk.patchToHere(j);
            // The explicit normal-completion close owns this break. Disarm the
            // enclosing abrupt handler before calling `return`: if IteratorClose
            // itself throws (including for a primitive result), unwinding must
            // not call the same iterator's `return` a second time.
            _ = try self.chunk.emit(.load_true, 0);
            try self.emitStoreActivationTempDiscard(done_temp);
            try self.emitLoadActivationTemp(iterator_temp);
            if (await_each) try self.emitAsyncIteratorClose(false) else _ = try self.chunk.emit(.iter_close, 0);
            self.chunk.patchToHere(skip_close);
        }
        self.popLoop();
        self.finally_depth -= 1;
        try self.emitPopHandler();

        const after_finally = try self.chunk.emit(.jump, 0);
        self.chunk.code.items[ph].b = @intCast(self.chunk.here());
        try self.emitLoadActivationTemp(done_temp);
        _ = try self.chunk.emit(.not, 0);
        const skip_close = try self.chunk.emit(.jump_if_false, 0);
        try self.emitLoadActivationTemp(iterator_temp);
        if (await_each) try self.emitAsyncIteratorClose(true) else _ = try self.chunk.emit(.iter_close_completion, 0);
        self.chunk.patchToHere(skip_close);
        _ = try self.chunk.emit(.end_finally, 0);
        self.chunk.patchToHere(after_finally);
        if (environment_binding) try self.emitExitEnvironment();
    }

    /// Drive `for-in` without routing the engine-owned key snapshot through
    /// `%ArrayIteratorPrototype%`. The target, candidate array, and cursor remain
    /// as a three-word GC-scanned operand-stack state; this gives program chunks
    /// activation isolation without synthesized globals or #706 scratch. Each
    /// `enum_next` dispatch advances one candidate and performs its live presence
    /// check, preserving watchdog/debugger/GC/GIL polls for large snapshots.
    fn compileForInKeys(self: *Compiler, decl_kind: ?ast.DeclKind, target: *Node, body: *Node, environment_binding: bool) CompileError!void {
        _ = try self.chunk.emit(.enum_keys, 0);
        const none = std.math.maxInt(u32);
        const handler = try self.emitPushHandler(.push_handler, none, none);
        self.finally_depth += 1;
        const loop = try self.pushLoop();
        const top = self.chunk.here();

        _ = try self.chunk.emit(.enum_next, 0);
        const exhausted = try self.chunk.emit(.jump_if_false, 0);
        const missing = try self.chunk.emit(.jump_if_false, 0);

        if (environment_binding) {
            if (target.* == .identifier)
                try self.emitFreshEnvironmentLexicalName(target.identifier, decl_kind.? == .@"const")
            else
                try self.emitFreshEnvironmentLexicalPattern(target, decl_kind.? == .@"const");
        }
        try self.compileLoopBind(decl_kind, target, environment_binding, true, .for_in);
        try self.compileRepeatedBody(body);

        const continue_target = self.chunk.here();
        _ = try self.chunk.emit(.jump, @intCast(top));
        for (loop.continues.items) |jump| self.chunk.patchTo(jump, continue_target);

        // A deleted candidate leaves its key above the three-word state. Drop
        // it and dispatch the next candidate; exhaustion additionally leaves
        // the false `present` flag that preceded `has candidate`.
        self.chunk.patchToHere(missing);
        _ = try self.chunk.emit(.pop, 0);
        _ = try self.chunk.emit(.jump, @intCast(top));
        self.chunk.patchToHere(exhausted);
        _ = try self.chunk.emit(.pop, 0);
        _ = try self.chunk.emit(.pop, 0);

        const cleanup = self.chunk.here();
        for (loop.breaks.items) |jump| self.chunk.patchTo(jump, cleanup);
        self.popLoop();
        self.finally_depth -= 1;
        try self.emitPopHandler();
        for (0..3) |_| _ = try self.chunk.emit(.pop, 0);

        const after_finally = try self.chunk.emit(.jump, 0);
        self.chunk.code.items[handler].b = @intCast(self.chunk.here());
        _ = try self.chunk.emit(.enum_end_completion, 0);
        _ = try self.chunk.emit(.end_finally, 0);
        self.chunk.patchToHere(after_finally);
        if (environment_binding) try self.emitExitEnvironment();
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

    // ---- activation-local destructuring assignment -------------------------

    /// `pattern = value` as an expression. Evaluates `value`, leaves it on the
    /// stack as the result, and destructures it into `pattern`.
    fn compileDestructuringAssign(self: *Compiler, pattern: *Node, value: *Node) CompileError!void {
        try self.compileExpr(value); // [v]
        const src = try self.freshActivationTemp();
        _ = try self.chunk.emit(.dup, 0); // [v, v]
        try self.emitDefineActivationTemp(src); // [v]   (define consumes one copy)
        try self.compileAssignPattern(pattern, src);
        // `src` (the rhs value) remains on the stack as the expression result.
    }

    const PatternMode = union(enum) {
        assignment_native,
        var_declaration,
        lexical,
        environment_lexical: bool,
    };

    fn patternModeIsAssignment(mode: PatternMode) bool {
        return mode == .assignment_native;
    }

    fn compileAssignPattern(self: *Compiler, pattern: *Node, src: ActivationTemp) CompileError!void {
        // A compiled assignment must write the exact statically resolved
        // frame/upvalue/global target. `bind_pattern` delegates to the
        // tree-walker Environment chain and therefore cannot represent a plain
        // function's frame slots. Keep the complete pattern in bytecode in
        // every mode; ActivationTemp selects frame, Environment, or program
        // scratch storage without changing the evaluation algorithm.
        try self.compilePattern(pattern, src, .assignment_native);
    }

    fn compilePattern(self: *Compiler, pattern: *Node, src: ActivationTemp, mode: PatternMode) CompileError!void {
        switch (pattern.*) {
            .arr_pattern => |p| try self.compileArrayPattern(p.elems, p.rest, src, mode),
            .obj_pattern => |p| try self.compileObjectPattern(p.props, p.rest, src, mode),
            else => return error.Unsupported,
        }
    }

    /// Assign the value held in temp `val` to a destructuring target — an
    /// identifier, a member reference (whose base/key were already evaluated
    /// into `ref`), or a nested pattern.
    fn compilePatternTarget(self: *Compiler, target: *Node, val: ActivationTemp, mode: PatternMode) CompileError!void {
        switch (target.*) {
            .identifier => |name| {
                try self.emitLoadActivationTemp(val);
                switch (mode) {
                    .lexical => try self.emitDefineForce(name),
                    .var_declaration => try self.emitDefineKind(name, .@"var", true),
                    .environment_lexical => |immutable| {
                        _ = try self.chunk.emitAB(.def_lex, try self.chunk.addName(name), if (immutable) 2 else 1);
                    },
                    .assignment_native => {
                        try self.emitStore(name);
                        _ = try self.chunk.emit(.pop, 0);
                    },
                }
            },
            .arr_pattern, .obj_pattern => {
                // Nested binding and assignment patterns stay in the current
                // activation so defaults, computed keys, and statically
                // resolved targets share the enclosing bytecode state.
                try self.compilePattern(target, val, mode);
            },
            else => return error.Unsupported, // member handled separately (ordered ref eval)
        }
    }

    fn emitPatternDefault(self: *Compiler, default: *Node, target: *Node, val: ActivationTemp) CompileError!void {
        try self.compileNamedExpr(default, if (target.* == .identifier) target.identifier else null);
        try self.emitStoreActivationTempDiscard(val);
    }

    /// Pre-evaluate a member/super target's base (and computed key) into fresh
    /// temps BEFORE the iterator advances or object-rest copying begins. Returns
    /// null for identifier targets, which use the existing name-store path.
    const MemberRef = struct { obj: ActivationTemp, key: ?ActivationTemp };

    const PatternAssignmentRef = union(enum) {
        binding: u32,
        member: MemberRef,
        super: CompiledSuperRef,
    };

    fn isUnresolvedPrivateName(name: []const u8) bool {
        return value_mod.isRawPrivateName(name) and !value_mod.isPrivateKey(name);
    }

    /// Runtime class construction normally rewrites `#name` to its unique
    /// storage key before compiling a deferred body. Eager computed class names
    /// retain the raw spelling and use dedicated bytecodes that resolve the
    /// active per-evaluation PrivateEnvironment at execution time.
    fn addMemberName(self: *Compiler, name: []const u8) CompileError!u32 {
        if (isUnresolvedPrivateName(name)) return error.Unsupported;
        return self.chunk.addName(try value_mod.encodeStringKey(self.arena, name));
    }

    fn emitGetMemberName(self: *Compiler, name: []const u8) CompileError!void {
        const unresolved = isUnresolvedPrivateName(name);
        _ = try self.chunk.emit(
            if (unresolved) .get_private_name else .get_prop,
            if (unresolved) try self.chunk.addName(name) else try self.addMemberName(name),
        );
    }

    fn emitSetMemberName(self: *Compiler, name: []const u8) CompileError!void {
        const unresolved = isUnresolvedPrivateName(name);
        _ = try self.chunk.emit(
            if (unresolved) .set_private_name else .set_prop,
            if (unresolved) try self.chunk.addName(name) else try self.addMemberName(name),
        );
    }
    fn preEvalPatternAssignmentRef(self: *Compiler, target: ?*Node, mode: PatternMode) CompileError!?PatternAssignmentRef {
        const t = target orelse return null;
        switch (t.*) {
            .identifier => |name| switch (mode) {
                .assignment_native, .var_declaration => if (try self.bindingReferencePlan(name)) |reference|
                    return .{ .binding = reference },
                .lexical, .environment_lexical => {},
            },
            .member => |m| {
                if (!patternModeIsAssignment(mode)) return null;
                const obj_tmp = try self.freshActivationTemp();
                try self.compileExpr(m.object);
                try self.emitDefineActivationTemp(obj_tmp);
                var key_tmp: ?ActivationTemp = null;
                if (m.computed) |ce| {
                    const kt = try self.freshActivationTemp();
                    try self.compileExpr(ce);
                    try self.emitDefineActivationTemp(kt);
                    key_tmp = kt;
                }
                return .{ .member = .{ .obj = obj_tmp, .key = key_tmp } };
            },
            .super_member => if (patternModeIsAssignment(mode))
                return .{ .super = try self.compileSuperRef(t, false, false) },
            else => return null,
        }
        return null;
    }

    /// Store `val` through an already-evaluated member or super Reference.
    fn storePatternAssignmentRef(self: *Compiler, target: *Node, ref: PatternAssignmentRef, val: ActivationTemp) CompileError!void {
        switch (ref) {
            .binding => |reference| {
                try self.emitLoadActivationTemp(val);
                try self.emitStoreBindingReference(reference);
                return;
            },
            .member => |member_ref| {
                const m = target.member;
                try self.emitLoadActivationTemp(member_ref.obj); // [obj]
                if (member_ref.key) |kt| {
                    try self.emitLoadActivationTemp(kt); // [obj, key]
                    try self.emitLoadActivationTemp(val); // [obj, key, val]
                    _ = try self.chunk.emit(.set_index, 0);
                } else {
                    try self.emitLoadActivationTemp(val); // [obj, val]
                    try self.emitSetMemberName(m.property);
                }
            },
            .super => |super_ref| {
                try self.emitLoadSuperRefBase(super_ref);
                try self.emitLoadActivationTemp(val);
                try self.emitSetSuperRef(super_ref);
            },
        }
        _ = try self.chunk.emit(.pop, 0); // discard the set result
    }

    /// `[ e0, e1, ... ] = src` (assignment form). Drives the
    /// iterator protocol, applies defaults (which may yield), and runs
    /// IteratorClose when destructuring stops before exhausting the iterator —
    /// on a normal early stop AND on an abrupt completion (a `yield` resumed
    /// with `.return()`/`.throw()` mid-destructure), via a finally handler.
    fn compileArrayPattern(self: *Compiler, elems: []const ast.ArrPatElem, rest: ?*Node, src: ActivationTemp, mode: PatternMode) CompileError!void {
        const none = std.math.maxInt(u32);
        try self.emitLoadActivationTemp(src);
        _ = try self.chunk.emit(.iter_of, 0);
        const it = try self.freshActivationTemp();
        try self.emitDefineActivationTemp(it);
        // GetIterator caches [[NextMethod]] once. Reading `iterator.next` on
        // every element would repeat an observable getter and could call a
        // different method after user code mutates the iterator.
        const next_method = try self.freshActivationTemp();
        try self.emitLoadActivationTemp(it);
        _ = try self.chunk.emit(.get_prop, try self.chunk.addName("next"));
        try self.emitDefineActivationTemp(next_method);
        const done = try self.freshActivationTemp();
        _ = try self.chunk.emit(.load_false, 0);
        try self.emitDefineActivationTemp(done);

        // Wrap the element/rest processing in a finally handler so any abrupt
        // completion (return/throw injected at an embedded yield) still closes
        // the iterator before propagating.
        const ph = try self.emitPushHandler(.push_handler, none, none);
        try self.compileArrayPatternBody(elems, rest, it, next_method, done, mode);
        try self.emitPopHandler();
        _ = try self.chunk.emit(.push_completion, 0); // normal completion
        // The normal path falls straight into the finally body (which the abrupt
        // path also jumps to via finally_pc); `end_finally` then resumes the
        // pushed completion — fall through on normal, re-propagate on abrupt.
        self.chunk.code.items[ph].b = @intCast(self.chunk.here());
        try self.emitLoadActivationTemp(done);
        _ = try self.chunk.emit(.not, 0);
        const skip = try self.chunk.emit(.jump_if_false, 0);
        try self.emitLoadActivationTemp(it);
        // The pending [value, kind] completion remains below the iterator.
        // IteratorClose preserves an existing throw even when `return` itself
        // throws, while a close failure replaces a normal completion.
        _ = try self.chunk.emit(.iter_close_completion, 0);
        self.chunk.patchToHere(skip);
        _ = try self.chunk.emit(.end_finally, 0);
    }

    fn compileArrayPatternBody(self: *Compiler, elems: []const ast.ArrPatElem, rest: ?*Node, it: ActivationTemp, next_method: ActivationTemp, done: ActivationTemp, mode: PatternMode) CompileError!void {
        for (elems) |elem| {
            // Spec order: evaluate the target reference first, then step the
            // iterator. Member/super targets carry an observable reference eval.
            const ref = try self.preEvalPatternAssignmentRef(elem.target, mode);
            // ev = undefined; if (!done) { r = it.next(); if (r.done) done = true else ev = r.value }
            const ev = try self.freshActivationTemp();
            _ = try self.chunk.emit(.load_undefined, 0);
            try self.emitDefineActivationTemp(ev);
            try self.emitLoadActivationTemp(done);
            _ = try self.chunk.emit(.not, 0);
            const skip_step = try self.chunk.emit(.jump_if_false, 0); // skip when done
            {
                const r = try self.freshActivationTemp();
                // IteratorStepValue marks the iterator record done before
                // propagating an abrupt IteratorNext / IteratorComplete /
                // IteratorValue completion. Set the flag before those calls,
                // then clear it only after a value is obtained successfully;
                // the enclosing finally must not IteratorClose after a step
                // operation itself throws.
                _ = try self.chunk.emit(.load_true, 0);
                try self.emitStoreActivationTempDiscard(done);
                try self.emitLoadActivationTemp(next_method);
                try self.emitLoadActivationTemp(it);
                _ = try self.chunk.emit(.call_with_this, 0);
                try self.emitDefineActivationTemp(r);
                try self.emitLoadActivationTemp(r);
                _ = try self.chunk.emit(.assert_iter_result, 0);
                _ = try self.chunk.emit(.pop, 0);
                try self.emitLoadActivationTemp(r);
                _ = try self.chunk.emit(.get_prop, try self.chunk.addName("done"));
                const not_done = try self.chunk.emit(.jump_if_false, 0);
                _ = try self.chunk.emit(.load_true, 0);
                try self.emitStoreActivationTempDiscard(done);
                const after = try self.chunk.emit(.jump, 0);
                self.chunk.patchToHere(not_done);
                try self.emitLoadActivationTemp(r);
                _ = try self.chunk.emit(.get_prop, try self.chunk.addName("value"));
                try self.emitStoreActivationTempDiscard(ev);
                _ = try self.chunk.emit(.load_false, 0);
                try self.emitStoreActivationTempDiscard(done);
                self.chunk.patchToHere(after);
            }
            self.chunk.patchToHere(skip_step);
            // default: if (ev === undefined) ev = <default>   (may yield)
            if (elem.default) |d| {
                try self.emitLoadActivationTemp(ev);
                _ = try self.chunk.emit(.load_undefined, 0);
                _ = try self.chunk.emit(.eq_strict, 0);
                const has_val = try self.chunk.emit(.jump_if_false, 0);
                if (elem.target) |target|
                    try self.emitPatternDefault(d, target, ev)
                else {
                    try self.compileExpr(d);
                    _ = try self.chunk.emit(.pop, 0);
                }
                self.chunk.patchToHere(has_val);
            }
            // assign ev to the target
            if (elem.target) |t| {
                if (ref) |reference|
                    try self.storePatternAssignmentRef(t, reference, ev)
                else
                    try self.compilePatternTarget(t, ev, mode);
            }
        }

        if (rest) |rest_target| {
            // Spec order: evaluate the rest target reference (may yield) BEFORE
            // collecting the remaining elements.
            const rref = try self.preEvalPatternAssignmentRef(rest_target, mode);
            // rest = []; while (!done) { r = it.next(); if (r.done) { done=true; break } rest.push(r.value) }
            const ra = try self.freshActivationTemp();
            _ = try self.chunk.emit(.new_array, 0);
            try self.emitDefineActivationTemp(ra);
            const top = self.chunk.here();
            try self.emitLoadActivationTemp(done);
            _ = try self.chunk.emit(.not, 0);
            const to_end = try self.chunk.emit(.jump_if_false, 0); // exit when done
            const r = try self.freshActivationTemp();
            _ = try self.chunk.emit(.load_true, 0);
            try self.emitStoreActivationTempDiscard(done);
            try self.emitLoadActivationTemp(next_method);
            try self.emitLoadActivationTemp(it);
            _ = try self.chunk.emit(.call_with_this, 0);
            try self.emitDefineActivationTemp(r);
            try self.emitLoadActivationTemp(r);
            _ = try self.chunk.emit(.assert_iter_result, 0);
            _ = try self.chunk.emit(.pop, 0);
            try self.emitLoadActivationTemp(r);
            _ = try self.chunk.emit(.get_prop, try self.chunk.addName("done"));
            const not_done = try self.chunk.emit(.jump_if_false, 0);
            _ = try self.chunk.emit(.load_true, 0);
            try self.emitStoreActivationTempDiscard(done);
            const to_end2 = try self.chunk.emit(.jump, 0);
            self.chunk.patchToHere(not_done);
            const rest_value = try self.freshActivationTemp();
            try self.emitLoadActivationTemp(r);
            _ = try self.chunk.emit(.get_prop, try self.chunk.addName("value"));
            try self.emitDefineActivationTemp(rest_value);
            _ = try self.chunk.emit(.load_false, 0);
            try self.emitStoreActivationTempDiscard(done);
            try self.emitLoadActivationTemp(ra);
            try self.emitLoadActivationTemp(rest_value);
            _ = try self.chunk.emit(.array_append, 0);
            _ = try self.chunk.emit(.pop, 0); // drop the array left by array_append
            _ = try self.chunk.emit(.jump, @intCast(top));
            self.chunk.patchToHere(to_end);
            self.chunk.patchToHere(to_end2);
            if (rref) |reference|
                try self.storePatternAssignmentRef(rest_target, reference, ra)
            else
                try self.compilePatternTarget(rest_target, ra, mode);
        }
        // The enclosing finally handler performs IteratorClose when `!done`.
    }

    /// `{ k0: t0 = d0, ... } = src` (assignment form).
    fn compileObjectPattern(self: *Compiler, props: []const ast.ObjPatProp, rest: ?*ast.Node, src: ActivationTemp, mode: PatternMode) CompileError!void {
        try self.emitLoadActivationTemp(src);
        // Name the first statically-known key so the null/undefined failure can
        // report it, exactly as the tree-walker does. A computed first key, an
        // empty pattern, and a rest-only pattern all report without a name.
        const coercible_name: u32 = if (props.len != 0 and props[0].key_expr == null)
            1 + try self.chunk.addName(props[0].key)
        else
            0;
        _ = try self.chunk.emitAB(.require_object_coercible, 0, coercible_name);
        var excluded: std.ArrayListUnmanaged(ActivationTemp) = .empty;
        for (props) |prop| {
            // PropertyName (may be computed and yield), then the target reference.
            const key = try self.freshActivationTemp();
            if (prop.key_expr) |ke| {
                try self.compileExpr(ke);
                _ = try self.chunk.emit(.to_property_key, 0);
                try self.emitDefineActivationTemp(key);
            } else {
                const ci = try self.chunk.addConst(try Value.strAlloc(self.arena, try value_mod.encodeStringKey(self.arena, prop.key)));
                _ = try self.chunk.emit(.load_const, ci);
                try self.emitDefineActivationTemp(key);
            }
            try excluded.append(self.arena, key);

            const ref = try self.preEvalPatternAssignmentRef(prop.target, mode);
            const ev = try self.freshActivationTemp();
            // ev = src[key]
            try self.emitLoadActivationTemp(src);
            if (prop.key_expr != null) {
                try self.emitLoadActivationTemp(key);
                _ = try self.chunk.emit(.get_index, 0);
            } else {
                _ = try self.chunk.emit(.get_prop, try self.chunk.addName(try value_mod.encodeStringKey(self.arena, prop.key)));
            }
            try self.emitDefineActivationTemp(ev);
            // default
            if (prop.default) |d| {
                try self.emitLoadActivationTemp(ev);
                _ = try self.chunk.emit(.load_undefined, 0);
                _ = try self.chunk.emit(.eq_strict, 0);
                const has_val = try self.chunk.emit(.jump_if_false, 0);
                try self.emitPatternDefault(d, prop.target, ev);
                self.chunk.patchToHere(has_val);
            }
            if (ref) |reference|
                try self.storePatternAssignmentRef(prop.target, reference, ev)
            else
                try self.compilePatternTarget(prop.target, ev, mode);
        }
        if (rest) |rest_target| {
            // RestDestructuringAssignmentEvaluation evaluates the assignment
            // target before CopyDataProperties, but performs PutValue after the
            // copy. Preserve the raw computed key across that interval so its
            // expression runs before source getters while ToPropertyKey remains
            // deferred to the eventual store. The activation-owned temps also
            // precisely root the base/key across getter calls and moving GC.
            const rest_ref = try self.preEvalPatternAssignmentRef(rest_target, mode);
            try self.emitLoadActivationTemp(src);
            for (excluded.items) |key| try self.emitLoadActivationTemp(key);
            _ = try self.chunk.emit(.object_rest, @intCast(excluded.items.len));
            const rest_value = try self.freshActivationTemp();
            try self.emitDefineActivationTemp(rest_value);
            if (rest_ref) |ref|
                try self.storePatternAssignmentRef(rest_target, ref, rest_value)
            else
                try self.compilePatternTarget(rest_target, rest_value, mode);
        }
    }

    // ---- expressions ------------------------------------------------------

    fn compileTailExpr(self: *Compiler, node: *Node) CompileError!void {
        // A live catch handler (still on the VM handler stack) must survive the
        // call, so nothing here is in tail position: evaluate normally and return
        // rather than emitting a tail call that would discard the handler and let a
        // throw from the callee escape the enclosing catch. (The finally case is
        // already routed through abrupt_return by return_stmt.)
        //
        // Proper tail calls are also a strict-mode-only guarantee (PrepareForTailCall
        // is not performed in sloppy mode), so a sloppy tail position grows the stack
        // like any call and eventually throws RangeError — reusing the frame would
        // turn `function f(){ return f(); }` into an infinite loop instead.
        if (self.is_derived_constructor or self.try_depth > 0 or !self.is_strict) {
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
            .optional_chain => |inner| try self.compileOptionalChain(inner, true),
            .tagged_template => |t| try self.compileTaggedTemplate(node, t.tag, t.exprs, true),
            else => {
                try self.compileExpr(node);
                _ = try self.chunk.emit(.ret, 0);
            },
        }
    }

    /// Emit `[WithBaseObject-or-undefined, callee]` for an identifier whose
    /// static target can be preceded by a `with` record. The Reference is
    /// resolved and consumed once; argument evaluation then keeps both Values
    /// precisely rooted on the operand stack.
    fn emitDynamicIdentifierCallee(self: *Compiler, callee: *Node) CompileError!bool {
        if (callee.* != .identifier) return false;
        const reference = try self.dynamicBindingReferencePlan(callee.identifier) orelse return false;
        try self.emitLoadBindingReference(reference, false, true, false);
        return true;
    }

    fn compileTailCall(self: *Compiler, c: anytype) CompileError!void {
        const spread = hasSpread(c.args);
        if (c.callee.* == .super_member) {
            try self.compileSuperCall(c, true);
            return;
        }
        if (c.callee.* == .member and c.callee.member.computed == null) {
            // Fetch the method (RequireObjectCoercible on the receiver) BEFORE the
            // args, per spec order, then tail-call with this = recv.
            const m = c.callee.member;
            try self.compileExpr(m.object);
            _ = try self.chunk.emit(.dup, 0);
            try self.emitGetMemberName(m.property);
            _ = try self.chunk.emit(.swap, 0);
            if (spread) {
                try self.compileArgsArray(c.args);
                _ = try self.chunk.emit(.tail_call_with_this_spread, 0);
            } else {
                for (c.args) |arg| try self.compileExpr(arg);
                _ = try self.chunk.emit(.tail_call_with_this, @intCast(c.args.len));
            }
            return;
        }
        if (c.callee.* == .member) {
            const m = c.callee.member;
            if (m.optional or m.computed == null) return error.Unsupported;
            try self.compileExpr(m.object);
            _ = try self.chunk.emit(.dup, 0);
            try self.compileExpr(m.computed.?);
            _ = try self.chunk.emit(.get_index, 0);
            _ = try self.chunk.emit(.swap, 0);
            if (spread) {
                try self.compileArgsArray(c.args);
                _ = try self.chunk.emit(.tail_call_with_this_spread, 0);
            } else {
                for (c.args) |arg| try self.compileExpr(arg);
                _ = try self.chunk.emit(.tail_call_with_this, @intCast(c.args.len));
            }
            return;
        }
        if (c.callee.* == .optional_chain and c.callee.optional_chain.* == .member) {
            try self.compileParenthesizedOptionalMemberReference(c.callee.optional_chain.member);
            _ = try self.chunk.emit(.swap, 0);
            if (spread) {
                try self.compileArgsArray(c.args);
                _ = try self.chunk.emit(.tail_call_with_this_spread, 0);
            } else {
                for (c.args) |arg| try self.compileExpr(arg);
                _ = try self.chunk.emit(.tail_call_with_this, @intCast(c.args.len));
            }
            return;
        }
        const is_eval = c.callee.* == .identifier and std.mem.eql(u8, c.callee.identifier, "eval");
        const eval_plan: ?u32 = if (self.scope != null and is_eval)
            try self.addCurrentDirectEvalPlan()
        else
            null;
        if (try self.emitDynamicIdentifierCallee(c.callee)) {
            _ = try self.chunk.emit(.swap, 0); // [callee, WithBaseObject]
            if (spread) {
                if (is_eval and eval_plan == null) return error.Unsupported;
                try self.compileArgsArray(c.args);
                _ = try self.chunk.emit(
                    if (eval_plan != null) .tail_call_eval_activation_with_this_spread else .tail_call_with_this_spread,
                    eval_plan orelse 0,
                );
            } else {
                for (c.args) |arg| try self.compileExpr(arg);
                if (eval_plan) |plan_index|
                    _ = try self.chunk.emitAB(.tail_call_eval_activation_with_this, @intCast(c.args.len), plan_index)
                else
                    _ = try self.chunk.emit(
                        if (is_eval) .tail_call_eval_with_this else .tail_call_with_this,
                        @intCast(c.args.len),
                    );
            }
            return;
        }
        try self.compileExpr(c.callee);
        if (spread) {
            if (is_eval and eval_plan == null) return error.Unsupported;
            try self.compileArgsArray(c.args);
            _ = try self.chunk.emit(
                if (eval_plan != null) .tail_call_eval_activation_spread else .tail_call_spread,
                eval_plan orelse 0,
            );
            return;
        }
        for (c.args) |arg| try self.compileExpr(arg);
        if (eval_plan) |plan_index|
            _ = try self.chunk.emitAB(.tail_call_eval_activation, @intCast(c.args.len), plan_index)
        else
            _ = try self.chunk.emit(if (is_eval) .tail_call_eval else .tail_call, @intCast(c.args.len));
    }

    const OptionalExit = struct {
        instruction: usize,
        /// Operands owned by this chain at the optional point. Values below
        /// these belong to the surrounding expression and must survive the
        /// short circuit unchanged.
        cleanup: u8,
    };

    fn emitOptionalExit(
        self: *Compiler,
        exits: *std.ArrayListUnmanaged(OptionalExit),
        cleanup: u8,
    ) CompileError!void {
        const instruction = try self.chunk.emit(.jump_if_nullish_peek, 0);
        try exits.append(self.arena, .{ .instruction = instruction, .cleanup = cleanup });
    }

    /// Complete an optional-chain control-flow region. The fallthrough path
    /// already has `result_arity` operands; every nullish exit discards only the
    /// values owned by the chain and synthesizes the same result shape. This is
    /// compile-time jump patching over the ordinary operand stack, not runtime
    /// exception/scratch state.
    fn finishOptionalRegion(
        self: *Compiler,
        exits: []const OptionalExit,
        result_arity: u8,
    ) CompileError!void {
        if (exits.len == 0) return;

        const skip_cleanup = try self.chunk.emit(.jump, 0);
        var targets: [3]?usize = .{ null, null, null };
        var joins: [3]?usize = .{ null, null, null };
        for (exits) |exit| {
            std.debug.assert(exit.cleanup > 0 and exit.cleanup < targets.len);
            if (targets[exit.cleanup] != null) continue;
            targets[exit.cleanup] = self.chunk.here();
            for (0..exit.cleanup) |_| _ = try self.chunk.emit(.pop, 0);
            for (0..result_arity) |_| _ = try self.chunk.emit(.load_undefined, 0);
            joins[exit.cleanup] = try self.chunk.emit(.jump, 0);
        }
        self.chunk.patchToHere(skip_cleanup);
        for (exits) |exit| self.chunk.patchTo(exit.instruction, targets[exit.cleanup].?);
        for (joins) |join| if (join) |instruction| self.chunk.patchToHere(instruction);
    }

    /// A nullish optional property reference is considered successfully
    /// deleted. Keep this distinct from ordinary optional-chain value lowering,
    /// whose short path synthesizes `undefined`.
    fn finishOptionalDeleteRegion(self: *Compiler, exits: []const OptionalExit) CompileError!void {
        if (exits.len == 0) return;

        const skip_cleanup = try self.chunk.emit(.jump, 0);
        var targets: [3]?usize = .{ null, null, null };
        var joins: [3]?usize = .{ null, null, null };
        for (exits) |exit| {
            std.debug.assert(exit.cleanup > 0 and exit.cleanup < targets.len);
            if (targets[exit.cleanup] != null) continue;
            targets[exit.cleanup] = self.chunk.here();
            for (0..exit.cleanup) |_| _ = try self.chunk.emit(.pop, 0);
            _ = try self.chunk.emit(.load_true, 0);
            joins[exit.cleanup] = try self.chunk.emit(.jump, 0);
        }
        self.chunk.patchToHere(skip_cleanup);
        for (exits) |exit| self.chunk.patchTo(exit.instruction, targets[exit.cleanup].?);
        for (joins) |join| if (join) |instruction| self.chunk.patchToHere(instruction);
    }

    fn compileDeleteMember(self: *Compiler, member: anytype, optional_chain: bool) CompileError!void {
        var exits: std.ArrayListUnmanaged(OptionalExit) = .empty;
        if (optional_chain) {
            try self.compileOptionalValue(member.object, &exits);
            if (member.optional) try self.emitOptionalExit(&exits, 1);
        } else {
            try self.compileExpr(member.object);
        }
        if (member.computed) |key| {
            try self.compileExpr(key);
            _ = try self.chunk.emit(.delete_index, @intFromBool(self.is_strict));
        } else {
            _ = try self.chunk.emitAB(.delete_prop, try self.addMemberName(member.property), @intFromBool(self.is_strict));
        }
        if (optional_chain) try self.finishOptionalDeleteRegion(exits.items);
    }

    fn compileDelete(self: *Compiler, target: *Node) CompileError!void {
        switch (target.*) {
            .member => |member| try self.compileDeleteMember(member, false),
            .optional_chain => |inner| if (inner.* == .member)
                try self.compileDeleteMember(inner.member, true)
            else {
                // A non-reference is evaluated exactly once for side effects;
                // the Delete Operator result is unconditionally true.
                try self.compileExpr(target);
                _ = try self.chunk.emit(.pop, 0);
                _ = try self.chunk.emit(.load_true, 0);
            },
            .super_member => |member| {
                // Delete of a SuperReference always throws, but reference
                // construction performs GetThisBinding before evaluating a
                // computed key. The key is never coerced with ToPropertyKey.
                if (member.computed) |key| {
                    _ = try self.chunk.emit(.check_super_this, 0);
                    try self.compileExpr(key);
                    _ = try self.chunk.emit(.pop, 0);
                }
                _ = try self.chunk.emit(.delete_super, 0);
            },
            .identifier => |name| {
                switch (self.resolve(name)) {
                    // A frame slot is a declarative binding and cannot be deleted.
                    // Activation-local block/with records may still shadow it, so
                    // search exactly those records before taking the false fallback.
                    .local => |binding| {
                        const environment_depth = self.environment_depth - binding.lexical_environment_depth;
                        if (environment_depth == 0)
                            _ = try self.chunk.emit(.load_false, 0)
                        else
                            _ = try self.chunk.emitAB(.delete_name, try self.chunk.addName(name), environment_depth);
                    },
                    .upval => |upvalue| {
                        const environment_depth = self.environment_depth + upvalue.environment_depth;
                        if (environment_depth == 0)
                            _ = try self.chunk.emit(.load_false, 0)
                        else
                            _ = try self.chunk.emitAB(.delete_name, try self.chunk.addName(name), environment_depth);
                    },
                    // Environment-backed suspendable locals and globals need full
                    // ResolveBinding/DeleteBinding semantics at execution time.
                    .environment, .global => _ = try self.chunk.emitAB(
                        .delete_name,
                        try self.chunk.addName(name),
                        bc.delete_name_full_environment_depth,
                    ),
                }
            },
            else => {
                try self.compileExpr(target);
                _ = try self.chunk.emit(.pop, 0);
                _ = try self.chunk.emit(.load_true, 0);
            },
        }
    }

    fn finishOptionalTailRegion(self: *Compiler, exits: []const OptionalExit) CompileError!void {
        var targets: [3]?usize = .{ null, null, null };
        for (exits) |exit| {
            std.debug.assert(exit.cleanup > 0 and exit.cleanup < targets.len);
            if (targets[exit.cleanup] != null) continue;
            targets[exit.cleanup] = self.chunk.here();
            for (0..exit.cleanup) |_| _ = try self.chunk.emit(.pop, 0);
            _ = try self.chunk.emit(.ret_undef, 0);
        }
        for (exits) |exit| self.chunk.patchTo(exit.instruction, targets[exit.cleanup].?);
    }

    fn compileOptionalChain(self: *Compiler, inner: *Node, is_tail: bool) CompileError!void {
        var exits: std.ArrayListUnmanaged(OptionalExit) = .empty;
        if (is_tail and inner.* == .call) {
            try self.compileOptionalCall(inner.call, &exits, true);
            try self.finishOptionalTailRegion(exits.items);
            return;
        }

        try self.compileOptionalValue(inner, &exits);
        if (is_tail) {
            _ = try self.chunk.emit(.ret, 0);
            try self.finishOptionalTailRegion(exits.items);
        } else {
            try self.finishOptionalRegion(exits.items, 1);
        }
    }

    /// Lower one node on an unparenthesized optional-chain spine. Recursive
    /// calls are limited to member bases and call callees: computed keys and
    /// arguments are ordinary nested expressions, and a nested optional_chain
    /// wrapper therefore correctly terminates the outer chain at parentheses.
    fn compileOptionalValue(
        self: *Compiler,
        node: *Node,
        exits: *std.ArrayListUnmanaged(OptionalExit),
    ) CompileError!void {
        switch (node.*) {
            .member => |member| {
                try self.compileOptionalValue(member.object, exits);
                if (member.optional) try self.emitOptionalExit(exits, 1);
                if (member.computed) |key| {
                    try self.compileExpr(key);
                    _ = try self.chunk.emit(.get_index, 0);
                } else {
                    try self.emitGetMemberName(member.property);
                }
            },
            .call => |call| try self.compileOptionalCall(call, exits, false),
            else => try self.compileExpr(node),
        }
    }

    /// Leave `[receiver, method]` on the operand stack. The member's base is
    /// checked before a computed key only for `?.[`; ordinary computed access
    /// retains its existing key-expression-before-RequireObjectCoercible order.
    fn compileOptionalMemberReference(
        self: *Compiler,
        member: anytype,
        exits: *std.ArrayListUnmanaged(OptionalExit),
    ) CompileError!void {
        try self.compileOptionalValue(member.object, exits);
        if (member.optional) try self.emitOptionalExit(exits, 1);
        _ = try self.chunk.emit(.dup, 0);
        if (member.computed) |key| {
            try self.compileExpr(key);
            _ = try self.chunk.emit(.get_index, 0);
        } else {
            try self.emitGetMemberName(member.property);
        }
    }

    /// Parentheses terminate short-circuit propagation but preserve a member
    /// Reference for call `this` binding. Normalize the inner chain to two
    /// operands so `(base?.method)()` still calls with `this = base`, while a
    /// nullish base becomes an ordinary call of undefined (and therefore throws)
    /// unless the outer call is itself optional.
    fn compileParenthesizedOptionalMemberReference(
        self: *Compiler,
        member: anytype,
    ) CompileError!void {
        var inner_exits: std.ArrayListUnmanaged(OptionalExit) = .empty;
        try self.compileOptionalMemberReference(member, &inner_exits);
        try self.finishOptionalRegion(inner_exits.items, 2);
    }

    fn compileOptionalSuperReference(self: *Compiler, member: anytype) CompileError!void {
        // GetThisBinding precedes the computed key and the super lookup. Retain
        // that exact receiver below the method so an optional call can inspect
        // the method before argument evaluation and then bind the original this.
        _ = try self.chunk.emit(.load_this, 0);
        if (member.computed) |key| {
            try self.compileExpr(key);
            _ = try self.chunk.emit(.super_get_index, 0);
        } else {
            _ = try self.chunk.emit(.super_get, try self.chunk.addName(try value_mod.encodeStringKey(self.arena, member.property)));
        }
    }

    fn compileOptionalCall(
        self: *Compiler,
        call: anytype,
        exits: *std.ArrayListUnmanaged(OptionalExit),
        is_tail: bool,
    ) CompileError!void {
        const spread = hasSpread(call.args);

        var has_receiver = false;
        var identifier_eval_with_base = false;
        if (call.callee.* == .member) {
            try self.compileOptionalMemberReference(call.callee.member, exits);
            has_receiver = true;
        } else if (call.callee.* == .optional_chain and call.callee.optional_chain.* == .member) {
            try self.compileParenthesizedOptionalMemberReference(call.callee.optional_chain.member);
            has_receiver = true;
        } else if (call.callee.* == .super_member) {
            try self.compileOptionalSuperReference(call.callee.super_member);
            has_receiver = true;
        } else if (try self.emitDynamicIdentifierCallee(call.callee)) {
            has_receiver = true;
            identifier_eval_with_base = !call.optional and
                std.mem.eql(u8, call.callee.identifier, "eval");
        } else {
            try self.compileOptionalValue(call.callee, exits);
        }

        if (call.optional) try self.emitOptionalExit(exits, if (has_receiver) 2 else 1);
        if (has_receiver) _ = try self.chunk.emit(.swap, 0); // [method, receiver]
        const eval_plan: ?u32 = if (identifier_eval_with_base and self.scope != null)
            try self.addCurrentDirectEvalPlan()
        else
            null;

        if (spread) {
            if (is_tail and identifier_eval_with_base and eval_plan == null) return error.Unsupported;
            try self.compileArgsArray(call.args);
            _ = try self.chunk.emit(
                if (eval_plan != null)
                    if (is_tail) .tail_call_eval_activation_with_this_spread else .call_eval_activation_with_this_spread
                else if (identifier_eval_with_base)
                    .call_eval_with_this_spread
                else if (has_receiver)
                    if (is_tail) .tail_call_with_this_spread else .call_with_this_spread
                else if (is_tail)
                    .tail_call_spread
                else
                    .call_spread,
                eval_plan orelse 0,
            );
            return;
        }

        for (call.args) |arg| try self.compileExpr(arg);
        if (eval_plan) |plan_index|
            _ = try self.chunk.emitAB(
                if (is_tail) .tail_call_eval_activation_with_this else .call_eval_activation_with_this,
                @intCast(call.args.len),
                plan_index,
            )
        else
            _ = try self.chunk.emit(
                if (identifier_eval_with_base)
                    if (is_tail) .tail_call_eval_with_this else .call_eval_with_this
                else if (has_receiver)
                    if (is_tail) .tail_call_with_this else .call_with_this
                else if (is_tail)
                    .tail_call
                else
                    .call,
                @intCast(call.args.len),
            );
    }

    fn compileSuperCall(self: *Compiler, call: anytype, is_tail: bool) CompileError!void {
        const member = call.callee.super_member;
        // SuperProperty obtains the current this binding before evaluating a
        // computed key. Retain that exact receiver below the lookup result so
        // inherited getters and the eventual call both observe it.
        _ = try self.chunk.emit(.load_this, 0);
        if (member.computed) |key| {
            try self.compileExpr(key);
            _ = try self.chunk.emit(.super_get_index, 0);
        } else {
            _ = try self.chunk.emit(.super_get, try self.chunk.addName(try value_mod.encodeStringKey(self.arena, member.property)));
        }
        _ = try self.chunk.emit(.swap, 0); // [method, this]
        if (hasSpread(call.args)) {
            try self.compileArgsArray(call.args);
            _ = try self.chunk.emit(if (is_tail) .tail_call_with_this_spread else .call_with_this_spread, 0);
            return;
        }
        for (call.args) |arg| try self.compileExpr(arg);
        _ = try self.chunk.emit(if (is_tail) .tail_call_with_this else .call_with_this, @intCast(call.args.len));
    }

    /// `tag`a${x}b`` → `tag(strings, x)`. The `template_object` opcode pushes the
    /// per-site cached+frozen GetTemplateObject strings array (shared with the
    /// tree-walker via the interpreter's `template_cache`, keyed by this AST
    /// node), so tiering no longer rebuilds/uncaches it — and a tail tagged
    /// template becomes a proper tail call (test262 tagged-template/tco-*).
    fn compileTaggedTemplate(self: *Compiler, site: *Node, tag: *Node, exprs: []*Node, is_tail: bool) CompileError!void {
        const ti = try self.chunk.addTemplate(site);
        const argc: u32 = @intCast(1 + exprs.len); // strings object + each substitution
        if (tag.* == .member and tag.member.computed == null and !tag.member.optional) {
            // `obj.tag`...`` → this = obj. Fetch the tag (RequireObjectCoercible +
            // any getter) BEFORE the arguments, per spec order.
            const m = tag.member;
            try self.compileExpr(m.object);
            _ = try self.chunk.emit(.dup, 0);
            try self.emitGetMemberName(m.property);
            _ = try self.chunk.emit(.swap, 0); // [method, recv]
            _ = try self.chunk.emit(.template_object, ti);
            for (exprs) |e| try self.compileExpr(e);
            _ = try self.chunk.emit(if (is_tail) .tail_call_with_this else .call_with_this, argc);
            return;
        }
        if (tag.* == .member) {
            const m = tag.member;
            if (m.optional or m.computed == null) return error.Unsupported;
            // MemberExpression evaluation completes before GetTemplateObject or
            // any substitution. Keep one receiver below the computed lookup so
            // the eventual tag call observes the original base as `this`.
            try self.compileExpr(m.object);
            _ = try self.chunk.emit(.dup, 0);
            try self.compileExpr(m.computed.?);
            _ = try self.chunk.emit(.get_index, 0);
            _ = try self.chunk.emit(.swap, 0); // [method, recv]
            _ = try self.chunk.emit(.template_object, ti);
            for (exprs) |e| try self.compileExpr(e);
            _ = try self.chunk.emit(if (is_tail) .tail_call_with_this else .call_with_this, argc);
            return;
        }
        if (tag.* == .super_member) {
            // A super property Reference reads through the home object's parent
            // but calls with the current this binding, never the super base.
            const m = tag.super_member;
            _ = try self.chunk.emit(.load_this, 0);
            if (m.computed) |key| {
                try self.compileExpr(key);
                _ = try self.chunk.emit(.super_get_index, 0);
            } else {
                _ = try self.chunk.emit(.super_get, try self.chunk.addName(try value_mod.encodeStringKey(self.arena, m.property)));
            }
            _ = try self.chunk.emit(.swap, 0); // [tag, this]
            _ = try self.chunk.emit(.template_object, ti);
            for (exprs) |e| try self.compileExpr(e);
            _ = try self.chunk.emit(if (is_tail) .tail_call_with_this else .call_with_this, argc);
            return;
        }
        if (try self.emitDynamicIdentifierCallee(tag)) {
            _ = try self.chunk.emit(.swap, 0); // [tag, WithBaseObject]
            _ = try self.chunk.emit(.template_object, ti);
            for (exprs) |e| try self.compileExpr(e);
            _ = try self.chunk.emit(if (is_tail) .tail_call_with_this else .call_with_this, argc);
            return;
        }
        // Plain tag (identifier / call / …): this = undefined.
        try self.compileExpr(tag);
        _ = try self.chunk.emit(.template_object, ti);
        for (exprs) |e| try self.compileExpr(e);
        _ = try self.chunk.emit(if (is_tail) .tail_call else .call, argc);
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
                const ci = try self.chunk.addConst(try Value.strAlloc(self.arena, s));
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
                if (u.op == .typeof and u.operand.* == .identifier) {
                    if (try self.dynamicBindingReferencePlan(u.operand.identifier)) |reference| {
                        try self.emitLoadBindingReference(reference, false, false, true);
                        _ = try self.chunk.emit(.typeof_op, 0);
                        return;
                    }
                }
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
            .delete_expr => |target| try self.compileDelete(target),
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
                if (b.op == .in_op and b.left.* == .identifier and value_mod.isRawPrivateName(b.left.identifier)) {
                    try self.compileExpr(b.right);
                    _ = try self.chunk.emit(
                        if (isUnresolvedPrivateName(b.left.identifier)) .private_name_in else .private_in,
                        try self.chunk.addName(b.left.identifier),
                    );
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
                try self.compileExpr(l.left);
                const peek: bc.Op = switch (l.op) {
                    .@"and" => .jump_if_false_peek,
                    .@"or" => .jump_if_true_peek,
                    // ECMA-262 CoalesceExpression evaluates the RHS only when
                    // the left value is null or undefined; falsy values remain
                    // on the stack as the expression result.
                    .nullish => .jump_if_not_nullish_peek,
                };
                const short = try self.chunk.emit(peek, 0);
                _ = try self.chunk.emit(.pop, 0);
                try self.compileExpr(l.right);
                self.chunk.patchToHere(short);
            },
            .assign => |a| if (self.in_field_initializer and a.value.* == .field_init_value and a.target.* == .member) {
                const member = a.target.member;
                if (member.computed != null) return error.Unsupported;
                try self.compileExpr(member.object);
                try self.compileExpr(a.value);
                _ = try self.chunk.emit(.init_class_field, try self.chunk.addName(member.property));
            } else switch (a.target.*) {
                .identifier => |name| {
                    const reference = try self.assignmentBindingReferencePlan(name);
                    // NamedEvaluation names `x = function(){}` (a bare, unparenthesized
                    // identifier target); `(x) = …` is not an IdentifierRef.
                    try self.compileNamedExpr(a.value, if (!a.target_parenthesized) name else null);
                    if (reference) |binding|
                        try self.emitStoreBindingReferenceLeavingValue(binding)
                    else
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
                        try self.emitSetMemberName(m.property);
                    }
                },
                .super_member => try self.compileSuperAssign(a),
                .call => try self.emitCallTargetRejection(a.target, .assignment, true),
                // Destructuring assignment `[a,b] = v` / `{x} = v`. Keep the
                // complete operation in bytecode: frame-mode functions must
                // write their statically resolved slots, while resumable and
                // program chunks use Environment or scratch-backed activation
                // temps. The shared native lowering also preserves suspension
                // in defaults and computed keys.
                .arr_pattern, .obj_pattern => {
                    try self.compileDestructuringAssign(a.target, a.value);
                },
                else => return error.Unsupported,
            },
            // Logical assignment on a member target must resolve the reference
            // once across the read, short-circuit, and possible write.
            .logical_assign => |a| switch (a.target.*) {
                .identifier => try self.compileIdentifierLogicalAssign(a),
                .member => try self.compileMemberLogicalAssign(a),
                .super_member => try self.compileSuperLogicalAssign(a),
                else => return error.Unsupported,
            },
            .op_assign => |oa| switch (oa.target.*) {
                // Identifier target: load the old value, apply the op, store back.
                // #732 owns the broader dynamic-`with` Reference path for
                // ordinary reads/compound/update/call expressions; #731 keeps
                // its activation-owned lowering scoped to destructuring and
                // simple `var` initialization.
                .identifier => |name| {
                    const reference = try self.assignmentBindingReferencePlan(name);
                    if (reference) |binding|
                        try self.emitLoadBindingReference(binding, true, false, false)
                    else
                        try self.emitLoad(name);
                    try self.compileExpr(oa.value);
                    _ = try self.chunk.emit(try compoundAssignmentOp(oa.op), 0);
                    if (reference) |binding|
                        try self.emitStoreBindingReferenceLeavingValue(binding)
                    else
                        try self.emitStore(name);
                },
                .member => try self.compileMemberCompoundAssign(oa),
                .super_member => try self.compileSuperCompoundAssign(oa),
                .call => try self.emitCallTargetRejection(oa.target, .assignment, true),
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
                const fi = try self.compileFunction(node, fnode, true);
                _ = try self.chunk.emit(.make_closure, fi);
            },
            .class_expr => try self.compileClass(node, null, false),
            .call => |c| {
                const spread = hasSpread(c.args);
                if (spread and c.optional) return error.Unsupported;
                if (c.callee.* == .super_member) {
                    try self.compileSuperCall(c, false);
                } else if (c.callee.* == .member and c.callee.member.computed == null) {
                    // `recv.name(args)`: bind `this = recv` at the call site.
                    const m = c.callee.member;
                    if (spread) {
                        if (m.optional) return error.Unsupported;
                        try self.compileExpr(m.object);
                        _ = try self.chunk.emit(.dup, 0);
                        try self.emitGetMemberName(m.property);
                        _ = try self.chunk.emit(.swap, 0);
                        try self.compileArgsArray(c.args);
                        _ = try self.chunk.emit(.call_with_this_spread, 0);
                    } else {
                        // Fetch the method (RequireObjectCoercible on the receiver +
                        // any getter) BEFORE the arguments, per spec order, then call
                        // with this = recv. Mirrors the computed-member path so a
                        // nullish receiver throws before an argument is evaluated.
                        try self.compileExpr(m.object);
                        _ = try self.chunk.emit(.dup, 0);
                        try self.emitGetMemberName(m.property);
                        _ = try self.chunk.emit(.swap, 0);
                        for (c.args) |arg| try self.compileExpr(arg);
                        _ = try self.chunk.emit(.call_with_this, @intCast(c.args.len));
                    }
                } else if (c.callee.* == .member) {
                    const m = c.callee.member;
                    if (m.optional or m.computed == null) return error.Unsupported;
                    try self.compileExpr(m.object);
                    _ = try self.chunk.emit(.dup, 0);
                    try self.compileExpr(m.computed.?);
                    _ = try self.chunk.emit(.get_index, 0);
                    _ = try self.chunk.emit(.swap, 0);
                    if (spread) {
                        try self.compileArgsArray(c.args);
                        _ = try self.chunk.emit(.call_with_this_spread, 0);
                    } else {
                        for (c.args) |arg| try self.compileExpr(arg);
                        _ = try self.chunk.emit(.call_with_this, @intCast(c.args.len));
                    }
                } else if (c.callee.* == .optional_chain and c.callee.optional_chain.* == .member) {
                    try self.compileParenthesizedOptionalMemberReference(c.callee.optional_chain.member);
                    _ = try self.chunk.emit(.swap, 0);
                    if (spread) {
                        try self.compileArgsArray(c.args);
                        _ = try self.chunk.emit(.call_with_this_spread, 0);
                    } else {
                        for (c.args) |arg| try self.compileExpr(arg);
                        _ = try self.chunk.emit(.call_with_this, @intCast(c.args.len));
                    }
                } else {
                    const is_eval = c.callee.* == .identifier and std.mem.eql(u8, c.callee.identifier, "eval");
                    const eval_plan: ?u32 = if (self.scope != null and is_eval)
                        try self.addCurrentDirectEvalPlan()
                    else
                        null;
                    if (try self.emitDynamicIdentifierCallee(c.callee)) {
                        _ = try self.chunk.emit(.swap, 0); // [callee, WithBaseObject]
                        if (spread) {
                            try self.compileArgsArray(c.args);
                            _ = try self.chunk.emit(
                                if (eval_plan != null)
                                    .call_eval_activation_with_this_spread
                                else if (is_eval)
                                    .call_eval_with_this_spread
                                else
                                    .call_with_this_spread,
                                eval_plan orelse 0,
                            );
                        } else {
                            for (c.args) |arg| try self.compileExpr(arg);
                            if (eval_plan) |plan_index|
                                _ = try self.chunk.emitAB(.call_eval_activation_with_this, @intCast(c.args.len), plan_index)
                            else
                                _ = try self.chunk.emit(
                                    if (is_eval) .call_eval_with_this else .call_with_this,
                                    @intCast(c.args.len),
                                );
                        }
                        return;
                    }
                    try self.compileExpr(c.callee);
                    if (spread) {
                        try self.compileArgsArray(c.args);
                        _ = try self.chunk.emit(
                            if (eval_plan != null)
                                .call_eval_activation_spread
                            else if (is_eval)
                                .call_eval_spread
                            else
                                .call_spread,
                            eval_plan orelse 0,
                        );
                    } else {
                        for (c.args) |arg| try self.compileExpr(arg);
                        if (eval_plan) |plan_index|
                            _ = try self.chunk.emitAB(.call_eval_activation, @intCast(c.args.len), plan_index)
                        else
                            // A bare `eval(...)` in an env-mode body is a candidate
                            // direct eval if the callee is the eval intrinsic.
                            _ = try self.chunk.emit(if (is_eval) .call_eval else .call, @intCast(c.args.len));
                    }
                }
            },
            .optional_chain => |inner| try self.compileOptionalChain(inner, false),
            .this_expr => _ = try self.chunk.emit(.load_this, 0),
            .new_target_expr => _ = try self.chunk.emit(if (self.in_field_initializer) .load_undefined else .load_new_target, 0),
            .import_meta => _ = try self.chunk.emit(.load_import_meta, 0),
            .member => |m| {
                try self.compileExpr(m.object);
                if (m.computed) |ce| {
                    try self.compileExpr(ce);
                    _ = try self.chunk.emit(.get_index, 0);
                } else {
                    try self.emitGetMemberName(m.property);
                }
            },
            .super_member => |m| {
                // `super.x` / `super[e]` read: GetSuperBase + [[Get]] with `this`
                // receiver, via the super_get opcodes (home_object is live in the
                // generator frame). The call form is handled in the `.call` arm.
                if (m.computed) |ce| {
                    // MakeSuperPropertyReference performs GetThisBinding before
                    // evaluating the computed key. In a derived constructor,
                    // `super[super()]` must therefore reject the uninitialized
                    // outer receiver without executing the inner SuperCall.
                    _ = try self.chunk.emit(.check_super_this, 0);
                    try self.compileExpr(ce);
                    _ = try self.chunk.emit(.super_get_index, 0);
                } else {
                    _ = try self.chunk.emit(.super_get, try self.chunk.addName(try value_mod.encodeStringKey(self.arena, m.property)));
                }
            },
            .super_call => |args| {
                _ = try self.chunk.emit(.load_super_constructor, 0);
                if (self.is_default_constructor) {
                    const rest_slot = self.chunk.rest_parameter_index orelse return error.Unsupported;
                    if (rest_slot >= self.chunk.parameter_slots.len) return error.Unsupported;
                    _ = try self.chunk.emit(.super_construct_default, self.chunk.parameter_slots[rest_slot]);
                } else if (hasSpread(args)) {
                    try self.compileArgsArray(args);
                    _ = try self.chunk.emit(.super_construct_spread, 0);
                } else {
                    for (args) |arg| try self.compileExpr(arg);
                    _ = try self.chunk.emit(.super_construct, @intCast(args.len));
                }
                try self.compileClassInitializers(self.derived_instance_initializers);
            },
            .new_expr => |n| {
                try self.compileExpr(n.callee);
                if (hasSpread(n.args)) {
                    try self.compileArgsArray(n.args);
                    _ = try self.chunk.emit(.new_spread, 0);
                } else {
                    for (n.args) |arg| try self.compileExpr(arg);
                    _ = try self.chunk.emit(.new_call, @intCast(n.args.len));
                }
            },
            .field_init_value => |value| {
                if (!self.in_field_initializer) return error.Unsupported;
                try self.compileNamedExpr(value.expression, value.name);
            },
            .object_lit => |props| {
                _ = try self.chunk.emit(.new_object, 0);
                for (props) |p| {
                    // Object spread lowers everywhere (`init_spread` is the same
                    // CopyDataProperties helper the tree-walker uses), so a nested
                    // non-generator function that spreads (`*g(){ yield {...(()=>({...x}))()} }`)
                    // no longer bails the whole generator. Accessors share the
                    // same DefineProperty path in every bytecode mode.
                    if (p.is_spread or p.accessor != .none) {
                        if (p.is_spread) {
                            try self.compileExpr(p.value); // CopyDataProperties source
                            _ = try self.chunk.emit(.init_spread, 0);
                            continue;
                        }
                        // Getter/setter: push key, push the function, install.
                        if (p.key_expr) |ke| {
                            try self.compileExpr(ke);
                            _ = try self.chunk.emit(.to_property_key, 0);
                        } else {
                            const ci = try self.chunk.addConst(try Value.strAlloc(self.arena, p.key));
                            _ = try self.chunk.emit(.load_const, ci);
                        }
                        const gi = try self.compileFunction(p.value, p.value.function, false);
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
                        if (p.value.* == .class_expr and p.value.class_expr.name.len == 0) {
                            // Retain the canonical property key as an ordinary
                            // activation input across suspended heritage/keys.
                            _ = try self.chunk.emit(.dup, 0);
                            try self.compileClass(p.value, null, true);
                        } else try self.compileExpr(p.value);
                        _ = try self.chunk.emit(.init_prop_computed, literalFunctionFlags(p.value));
                    } else {
                        try self.compileNamedExpr(p.value, if (p.proto_setter) null else p.key);
                        if (p.proto_setter) {
                            _ = try self.chunk.emit(.init_proto, 0); // `__proto__: v` colon form
                        } else {
                            _ = try self.chunk.emitAB(.init_prop, try self.chunk.addName(try value_mod.encodeStringKey(self.arena, p.key)), literalFunctionFlags(p.value) & bc.literal_function_method);
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
                        try self.compileExpr(e.spread);
                        _ = try self.chunk.emit(.array_spread, 0);
                    } else {
                        try self.compileExpr(e);
                        _ = try self.chunk.emit(.array_append, 0);
                    }
                }
            },
            .update => |u| try self.compileUpdate(u.inc, u.prefix, u.target),
            .tagged_template => |t| try self.compileTaggedTemplate(node, t.tag, t.exprs, false),
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

    /// Prefix yields the new numeric value; postfix yields the old numeric value.
    fn compileUpdate(self: *Compiler, inc: bool, prefix: bool, target: *Node) CompileError!void {
        switch (target.*) {
            .identifier => |name| {
                // `++`/`--` are ToNumeric(old) ± 1, not `old + 1`: a raw `.add`
                // would string-concatenate a string operand and TypeError a
                // BigInt. The inc/dec opcodes add 1 of the numeric operand type.
                const step: bc.Op = if (inc) .inc else .dec;
                const reference = try self.assignmentBindingReferencePlan(name);
                if (prefix) {
                    if (reference) |binding|
                        try self.emitLoadBindingReference(binding, true, false, false)
                    else
                        try self.emitLoad(name);
                    _ = try self.chunk.emit(step, 0);
                    if (reference) |binding|
                        try self.emitStoreBindingReferenceLeavingValue(binding)
                    else
                        try self.emitStore(name); // leaves the new value
                } else {
                    if (reference) |binding|
                        try self.emitLoadBindingReference(binding, true, false, false)
                    else
                        try self.emitLoad(name);
                    _ = try self.chunk.emit(.to_numeric, 0); // postfix result is the numeric old value
                    _ = try self.chunk.emit(.dup, 0); // keep the numeric old value
                    _ = try self.chunk.emit(step, 0);
                    if (reference) |binding|
                        try self.emitStoreBindingReference(binding)
                    else {
                        try self.emitStore(name);
                        _ = try self.chunk.emit(.pop, 0); // discard the new value, leave the old
                    }
                }
            },
            .member => try self.compileMemberUpdate(inc, prefix, target),
            .super_member => try self.compileSuperUpdate(inc, prefix, target),
            .call => try self.emitCallTargetRejection(target, bc.NotAReference.update(inc, prefix), true),
            else => return error.Unsupported,
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
        const it = try self.freshProtocolTemp(); // the iterator
        const r = try self.freshProtocolTemp(); // the last `{value, done}` result
        const recv_v = try self.freshProtocolTemp(); // value carried by the resume
        const recv_k = try self.freshProtocolTemp(); // resume kind: 0 next / 1 throw / 2 return
        const next_m = try self.freshProtocolTemp(); // the iterator's captured `next` method
        const m = try self.freshProtocolTemp(); // a GetMethod(it, throw|return) result
        const ch = self.chunk;
        const done_n = try ch.addName("done");
        const value_n = try ch.addName("value");

        // it = GetIterator(arg); recv_v = undefined; recv_k = 0 (start with `next`).
        try self.compileExpr(arg);
        _ = try ch.emit(if (async_d) .async_iter_of else .iter_of, 0);
        try self.emitDefineActivationTemp(it);
        try self.emitLoadActivationTemp(it);
        _ = try ch.emit(.get_prop, try ch.addName("next"));
        try self.emitDefineActivationTemp(next_m);
        _ = try ch.emit(.load_undefined, 0);
        try self.emitDefineActivationTemp(recv_v);
        _ = try ch.emit(.load_const, try ch.addConst(Value.num(0)));
        try self.emitDefineActivationTemp(recv_k);

        const top = ch.here();
        // if (recv_k == 0) fall through to the `next` branch, else jump to throw/return.
        try self.emitLoadActivationTemp(recv_k);
        _ = try ch.emit(.load_const, try ch.addConst(Value.num(0)));
        _ = try ch.emit(.eq_strict, 0);
        const to_nonnext = try ch.emit(.jump_if_false, 0);

        // --- next branch: r = next.call(it, recv_v) ---
        try self.emitLoadActivationTemp(next_m);
        try self.emitLoadActivationTemp(it);
        try self.emitLoadActivationTemp(recv_v);
        _ = try ch.emitAB(.call_with_this, 1, 0);
        if (async_d) _ = try ch.emit(.await_op, 0);
        try self.emitDefineActivationTemp(r);
        const to_join_a = try ch.emit(.jump, 0); // -> normal/throw join

        // --- recv_k == 1 ? throw branch : return branch ---
        ch.patchToHere(to_nonnext);
        try self.emitLoadActivationTemp(recv_k);
        _ = try ch.emit(.load_const, try ch.addConst(Value.num(1)));
        _ = try ch.emit(.eq_strict, 0);
        const to_return = try ch.emit(.jump_if_false, 0);

        // --- throw branch ---
        // m = GetMethod(it, "throw")
        try self.emitLoadActivationTemp(it);
        _ = try ch.emit(.get_prop, try ch.addName("throw"));
        try self.emitDefineActivationTemp(m);
        const to_has_throw = try self.emitJumpIfNotStrictlyNullish(m);
        // No `throw` method: IteratorClose(it) (call `return` if present, ignoring
        // its result) then throw a TypeError. Closing first lets the inner
        // iterator release resources, matching the spec.
        try self.emitLoadActivationTemp(it);
        _ = try ch.emit(.get_prop, try ch.addName("return"));
        try self.emitDefineActivationTemp(m);
        const to_skip_close = try self.emitJumpIfNotStrictlyNullish(m);
        const to_after_close = try ch.emit(.jump, 0); // return absent: skip the call
        ch.patchToHere(to_skip_close);
        try self.emitLoadActivationTemp(m); // func
        try self.emitLoadActivationTemp(it); // this
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
        try self.emitLoadActivationTemp(m);
        try self.emitLoadActivationTemp(it);
        try self.emitLoadActivationTemp(recv_v);
        _ = try ch.emitAB(.call_with_this, 1, 0);
        if (async_d) _ = try ch.emit(.await_op, 0);
        try self.emitDefineActivationTemp(r);
        const to_join_b = try ch.emit(.jump, 0); // -> normal/throw join

        // --- return branch ---
        ch.patchToHere(to_return);
        // m = GetMethod(it, "return")
        try self.emitLoadActivationTemp(it);
        _ = try ch.emit(.get_prop, try ch.addName("return"));
        try self.emitDefineActivationTemp(m);
        const to_has_return = try self.emitJumpIfNotStrictlyNullish(m);
        // No `return` method: the delegating generator itself returns recv_v
        // (Await it first in an async generator), running any enclosing finally.
        try self.emitLoadActivationTemp(recv_v);
        if (async_d) _ = try ch.emit(.await_op, 0);
        _ = try ch.emit(.abrupt_return, 0);
        // has a `return` method: r = m.call(it, recv_v)
        ch.patchToHere(to_has_return);
        try self.emitLoadActivationTemp(m);
        try self.emitLoadActivationTemp(it);
        try self.emitLoadActivationTemp(recv_v);
        _ = try ch.emitAB(.call_with_this, 1, 0);
        if (async_d) _ = try ch.emit(.await_op, 0);
        try self.emitDefineActivationTemp(r);
        try self.emitLoadActivationTemp(r);
        _ = try ch.emit(.assert_iter_result, 0);
        _ = try ch.emit(.pop, 0);
        // if (r.done) the delegating generator returns r.value; else yield it.
        try self.emitLoadActivationTemp(r);
        _ = try ch.emit(.get_prop, done_n);
        const to_return_yield = try ch.emit(.jump_if_false, 0);
        try self.emitLoadActivationTemp(r);
        _ = try ch.emit(.get_prop, value_n);
        _ = try ch.emit(.abrupt_return, 0);

        // --- normal/throw join: validate r, branch on done ---
        ch.patchToHere(to_join_a);
        ch.patchToHere(to_join_b);
        try self.emitLoadActivationTemp(r);
        _ = try ch.emit(.assert_iter_result, 0);
        _ = try ch.emit(.pop, 0);
        try self.emitLoadActivationTemp(r);
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
            try self.emitLoadActivationTemp(r);
            _ = try ch.emit(.get_prop, value_n);
        } else {
            try self.emitLoadActivationTemp(r); // yield the inner result object as-is
        }
        _ = try ch.emit(.gen_yield_star, 0); // resume pushes [value, kind] (kind on top)
        try self.emitStoreActivationTempDiscard(recv_k);
        try self.emitStoreActivationTempDiscard(recv_v);
        if (async_d) {
            // AsyncGeneratorYield resumes through
            // AsyncGeneratorUnwrapYieldResumption, which awaits the completion
            // value before yield* forwards it to next/throw/return handling.
            try self.emitLoadActivationTemp(recv_v);
            _ = try ch.emit(.await_op, 0);
            try self.emitStoreActivationTempDiscard(recv_v);
        }
        _ = try ch.emit(.jump, @intCast(top));

        // yield* evaluates to the final `r.value` when the inner iterator is done.
        ch.patchToHere(to_end);
        try self.emitLoadActivationTemp(r);
        _ = try ch.emit(.get_prop, value_n);
    }

    fn emitJumpIfNotStrictlyNullish(self: *Compiler, temp: ActivationTemp) CompileError!usize {
        const ch = self.chunk;

        try self.emitLoadActivationTemp(temp);
        _ = try ch.emit(.load_undefined, 0);
        _ = try ch.emit(.eq_strict, 0);
        const to_check_null = try ch.emit(.jump_if_false, 0);
        const to_absent = try ch.emit(.jump, 0);

        ch.patchToHere(to_check_null);
        try self.emitLoadActivationTemp(temp);
        _ = try ch.emit(.load_null, 0);
        _ = try ch.emit(.eq_strict, 0);
        const to_present = try ch.emit(.jump_if_false, 0);

        ch.patchToHere(to_absent);
        return to_present;
    }

    const CompiledMemberRef = struct {
        object: ActivationTemp,
        key: ?ActivationTemp,
        property: []const u8,
    };

    const CompiledSuperRef = struct {
        base: ActivationTemp,
        key: ?ActivationTemp,
        property: []const u8,
    };

    /// Resolve a SuperReference once. Computed references perform
    /// GetThisBinding before evaluating the key, capture GetSuperBase after the
    /// key expression, and optionally defer ToPropertyKey until PutValue (plain
    /// assignment). Activation-owned temps preserve both facts across a
    /// getter/RHS suspension without re-reading the mutable home prototype.
    fn compileSuperRef(
        self: *Compiler,
        target: *Node,
        require_base: bool,
        coerce_key: bool,
    ) CompileError!CompiledSuperRef {
        if (self.mode == .program or target.* != .super_member)
            return error.Unsupported;
        const member = target.super_member;

        var key: ?ActivationTemp = null;
        if (member.computed) |key_expr| {
            _ = try self.chunk.emit(.check_super_this, 0);
            try self.compileExpr(key_expr);
            if (!coerce_key) {
                const key_temp = try self.freshActivationTemp();
                try self.emitDefineActivationTemp(key_temp);
                key = key_temp;
            }
        }

        _ = try self.chunk.emit(.super_base, @intFromBool(require_base));
        const base = try self.freshActivationTemp();
        try self.emitDefineActivationTemp(base);

        if (member.computed != null and coerce_key) {
            _ = try self.chunk.emit(.to_property_key, 0);
            const key_temp = try self.freshActivationTemp();
            try self.emitDefineActivationTemp(key_temp);
            key = key_temp;
        }
        return .{ .base = base, .key = key, .property = member.property };
    }

    fn emitLoadSuperRefBase(self: *Compiler, ref: CompiledSuperRef) CompileError!void {
        try self.emitLoadActivationTemp(ref.base);
        if (ref.key) |key| try self.emitLoadActivationTemp(key);
    }

    fn emitGetSuperRef(self: *Compiler, ref: CompiledSuperRef) CompileError!void {
        try self.emitLoadSuperRefBase(ref);
        _ = try self.chunk.emit(
            if (ref.key != null) .super_get_index_from else .super_get_from,
            if (ref.key != null) 0 else try self.addMemberName(ref.property),
        );
    }

    fn emitSetSuperRef(self: *Compiler, ref: CompiledSuperRef) CompileError!void {
        _ = try self.chunk.emitAB(
            if (ref.key != null) .super_set_index_from else .super_set_from,
            if (ref.key != null) @intFromBool(self.is_strict) else try self.addMemberName(ref.property),
            if (ref.key != null) 0 else @intFromBool(self.is_strict),
        );
    }

    fn compileSuperAssign(self: *Compiler, assignment: anytype) CompileError!void {
        // Assignment evaluates the SuperReference before the RHS but defers a
        // computed ToPropertyKey until PutValue. Capture the raw key and base,
        // then preserve the RHS while that one key coercion runs.
        const ref = try self.compileSuperRef(assignment.target, false, false);
        try self.compileExpr(assignment.value);
        const result = try self.freshActivationTemp();
        try self.emitDefineActivationTemp(result);
        try self.emitLoadSuperRefBase(ref);
        try self.emitLoadActivationTemp(result);
        try self.emitSetSuperRef(ref);
    }

    fn compileIdentifierLogicalAssign(self: *Compiler, assignment: anytype) CompileError!void {
        const name = assignment.target.identifier;
        const reference = try self.assignmentBindingReferencePlan(name);
        if (reference) |binding|
            try self.emitLoadBindingReference(binding, true, false, false)
        else
            try self.emitLoad(name);
        const short = try self.chunk.emit(switch (assignment.op) {
            .@"and" => .jump_if_false_peek,
            .@"or" => .jump_if_true_peek,
            .nullish => .jump_if_not_nullish_peek,
        }, 0);

        _ = try self.chunk.emit(.pop, 0);
        try self.compileExpr(assignment.value);
        if (reference) |binding|
            try self.emitStoreBindingReferenceLeavingValue(binding)
        else
            try self.emitStore(name);

        if (reference) |binding| {
            const to_end = try self.chunk.emit(.jump, 0);
            self.chunk.patchToHere(short);
            try self.emitClearBindingReference(binding);
            self.chunk.patchToHere(to_end);
        } else {
            self.chunk.patchToHere(short);
        }
    }

    fn compileSuperLogicalAssign(self: *Compiler, assignment: anytype) CompileError!void {
        const ref = try self.compileSuperRef(assignment.target, true, true);
        try self.emitGetSuperRef(ref);
        const short = try self.chunk.emit(switch (assignment.op) {
            .@"and" => .jump_if_false_peek,
            .@"or" => .jump_if_true_peek,
            .nullish => .jump_if_not_nullish_peek,
        }, 0);

        _ = try self.chunk.emit(.pop, 0);
        try self.compileExpr(assignment.value);
        const result = try self.freshActivationTemp();
        try self.emitDefineActivationTemp(result);
        try self.emitLoadSuperRefBase(ref);
        try self.emitLoadActivationTemp(result);
        try self.emitSetSuperRef(ref);
        self.chunk.patchToHere(short);
    }

    fn compileSuperCompoundAssign(self: *Compiler, assignment: anytype) CompileError!void {
        const ref = try self.compileSuperRef(assignment.target, true, true);
        try self.emitGetSuperRef(ref);
        try self.compileExpr(assignment.value);
        _ = try self.chunk.emit(try compoundAssignmentOp(assignment.op), 0);

        const result = try self.freshActivationTemp();
        try self.emitDefineActivationTemp(result);
        try self.emitLoadSuperRefBase(ref);
        try self.emitLoadActivationTemp(result);
        try self.emitSetSuperRef(ref);
    }

    fn compileMemberRef(self: *Compiler, target: *Node) CompileError!CompiledMemberRef {
        // Optional-chain targets keep their explicit unsupported admission: a
        // deleted/absent base must short-circuit the whole assignment instead
        // of throwing from RequireObjectCoercible, which this Reference shape
        // does not model yet.
        if (target.* != .member or target.member.optional)
            return error.Unsupported;
        const member = target.member;

        // Evaluate the Reference once. Frame-mode temps are real activation
        // slots so recursion cannot overwrite them; environment-mode temps live
        // in the generator/async activation and survive suspension; program
        // chunks hold theirs in #706 activation-local Exec scratch.
        const object = try self.freshActivationTemp();
        try self.compileExpr(member.object);
        try self.emitDefineActivationTemp(object);

        var key: ?ActivationTemp = null;
        if (member.computed) |key_expr| {
            // PropertyAccessors evaluates the key expression before checking
            // the base, but RequireObjectCoercible precedes observable
            // ToPropertyKey. Store the resulting key string so GetValue and
            // PutValue cannot invoke user coercion twice.
            try self.compileExpr(key_expr);
            try self.emitLoadActivationTemp(object);
            _ = try self.chunk.emit(.require_object_coercible, 1);
            _ = try self.chunk.emit(.to_property_key, 0);
            const key_temp = try self.freshActivationTemp();
            try self.emitDefineActivationTemp(key_temp);
            key = key_temp;
        }
        return .{ .object = object, .key = key, .property = member.property };
    }

    fn emitLoadMemberRefBase(self: *Compiler, ref: CompiledMemberRef) CompileError!void {
        try self.emitLoadActivationTemp(ref.object);
        if (ref.key) |key| try self.emitLoadActivationTemp(key);
    }

    fn emitGetMemberRef(self: *Compiler, ref: CompiledMemberRef) CompileError!void {
        try self.emitLoadMemberRefBase(ref);
        if (ref.key != null)
            _ = try self.chunk.emit(.get_index, 0)
        else
            try self.emitGetMemberName(ref.property);
    }

    fn emitSetMemberRef(self: *Compiler, ref: CompiledMemberRef) CompileError!void {
        if (ref.key != null)
            _ = try self.chunk.emit(.set_index, 0)
        else
            try self.emitSetMemberName(ref.property);
    }

    fn compileMemberLogicalAssign(self: *Compiler, assignment: anytype) CompileError!void {
        const ref = try self.compileMemberRef(assignment.target);

        try self.emitGetMemberRef(ref);
        const short = try self.chunk.emit(switch (assignment.op) {
            .@"and" => .jump_if_false_peek,
            .@"or" => .jump_if_true_peek,
            .nullish => .jump_if_not_nullish_peek,
        }, 0);

        _ = try self.chunk.emit(.pop, 0);
        try self.emitLoadMemberRefBase(ref);
        // The suspendable VM snapshots its operand stack, so keeping the
        // resolved base/key below the RHS also roots the exact Reference across
        // yield/await without another environment lookup or allocation.
        try self.compileExpr(assignment.value);
        try self.emitSetMemberRef(ref);
        self.chunk.patchToHere(short);
    }

    fn compileMemberCompoundAssign(self: *Compiler, assignment: anytype) CompileError!void {
        // ECMA-262 Assignment Operators: Runtime Semantics: Evaluation resolves
        // lref and performs GetValue before evaluating the RHS, then applies the
        // binary operation before PutValue on that same Reference.
        const ref = try self.compileMemberRef(assignment.target);
        try self.emitGetMemberRef(ref);
        // Binary evaluation retains the pre-RHS old value on the suspendable
        // operand stack, matching GetValue before the RHS and rooting it across
        // yield/await.
        try self.compileExpr(assignment.value);
        _ = try self.chunk.emit(try compoundAssignmentOp(assignment.op), 0);

        const result = try self.freshActivationTemp();
        try self.emitDefineActivationTemp(result);
        try self.emitLoadMemberRefBase(ref);
        try self.emitLoadActivationTemp(result);
        try self.emitSetMemberRef(ref);
    }

    fn compileMemberUpdate(self: *Compiler, inc: bool, prefix: bool, target: *Node) CompileError!void {
        // ECMA-262 Update Expressions resolves lhs once, then performs GetValue,
        // ToNumeric, the numeric-type-specific ±1, and PutValue in that order.
        const ref = try self.compileMemberRef(target);
        try self.emitGetMemberRef(ref);
        _ = try self.chunk.emit(.to_numeric, 0);

        var old: ?ActivationTemp = null;
        if (!prefix) {
            const old_temp = try self.freshActivationTemp();
            try self.emitDefineActivationTemp(old_temp);
            try self.emitLoadActivationTemp(old_temp);
            old = old_temp;
        }
        _ = try self.chunk.emit(if (inc) .inc else .dec, 0);
        const updated = try self.freshActivationTemp();
        try self.emitDefineActivationTemp(updated);

        try self.emitLoadMemberRefBase(ref);
        try self.emitLoadActivationTemp(updated);
        try self.emitSetMemberRef(ref);
        if (!prefix) {
            _ = try self.chunk.emit(.pop, 0);
            try self.emitLoadActivationTemp(old.?);
        }
    }

    fn compileSuperUpdate(self: *Compiler, inc: bool, prefix: bool, target: *Node) CompileError!void {
        const ref = try self.compileSuperRef(target, true, true);
        try self.emitGetSuperRef(ref);
        _ = try self.chunk.emit(.to_numeric, 0);

        var old: ?ActivationTemp = null;
        if (!prefix) {
            const old_temp = try self.freshActivationTemp();
            try self.emitDefineActivationTemp(old_temp);
            try self.emitLoadActivationTemp(old_temp);
            old = old_temp;
        }
        _ = try self.chunk.emit(if (inc) .inc else .dec, 0);
        const updated = try self.freshActivationTemp();
        try self.emitDefineActivationTemp(updated);

        try self.emitLoadSuperRefBase(ref);
        try self.emitLoadActivationTemp(updated);
        try self.emitSetSuperRef(ref);
        if (!prefix) {
            _ = try self.chunk.emit(.pop, 0);
            try self.emitLoadActivationTemp(old.?);
        }
    }

    fn compoundAssignmentOp(op: ast.BinaryOp) CompileError!bc.Op {
        return switch (op) {
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
            else => error.Unsupported,
        };
    }

    /// A unique, user-unreferenceable temp name (contains a NUL byte).
    fn freshTemp(self: *Compiler) CompileError![]const u8 {
        const n = self.tmp_counter;
        self.tmp_counter += 1;
        return std.fmt.allocPrint(self.arena, "\x00ys{d}", .{n});
    }

    fn freshActivationTemp(self: *Compiler) CompileError!ActivationTemp {
        // Program chunks have neither a frame nor a private activation
        // Environment (#706): a synthesized name would resolve against the
        // shared global environment, so nested or parallel evaluations of the
        // same program could collide on it. Bounded Exec-owned scratch slots
        // keep these temporaries activation-local instead.
        if (self.mode == .program) {
            const index = self.scratch_count;
            self.scratch_count += 1;
            return .{ .scratch = index };
        }
        const name = try self.freshTemp();
        if (self.scope) |scope| _ = if (self.function_binding_phase == .parameters)
            try scope.addParameter(self.arena, name)
        else
            try scope.addLocal(self.arena, name, false, false);
        return .{ .named = name };
    }

    fn freshProtocolTemp(self: *Compiler) CompileError!ActivationTemp {
        // Generator/async bytecode replaces its current lexical Environment at
        // loop boundaries. Protocol state spans those replacements and
        // suspension, so anchor it in the suspendable activation's private
        // variable Environment. Ordinary functions use frame locals and
        // programs use Exec scratch through the general helper.
        if (self.mode == .function and self.scope == null)
            return .{ .environment_var = try self.freshTemp() };
        return self.freshActivationTemp();
    }

    fn emitDefineActivationTemp(self: *Compiler, temp: ActivationTemp) CompileError!void {
        switch (temp) {
            .named => |name| return self.emitDefineActivationTempNamed(name),
            .environment_var => |name| return self.emitDefine(name),
            .scratch => |index| _ = try self.chunk.emit(.scratch_store, index),
        }
    }

    fn emitDefineActivationTempNamed(self: *Compiler, name: []const u8) CompileError!void {
        if (self.scope != null) return self.emitDefine(name);
        // Env-mode generator/async functions have no frame slots. Keep compiler
        // state in their private activation Environment instead of `def_var`.
        _ = try self.chunk.emitAB(.def_lex, try self.chunk.addName(name), 1);
    }

    fn emitLoadActivationTemp(self: *Compiler, temp: ActivationTemp) CompileError!void {
        switch (temp) {
            .named, .environment_var => |name| return self.emitLoad(name),
            .scratch => |index| _ = try self.chunk.emit(.scratch_load, index),
        }
    }

    fn emitStoreActivationTempDiscard(self: *Compiler, temp: ActivationTemp) CompileError!void {
        switch (temp) {
            .named, .environment_var => |name| {
                try self.emitStore(name);
                _ = try self.chunk.emit(.pop, 0);
            },
            .scratch => |index| _ = try self.chunk.emit(.scratch_store, index),
        }
    }

    fn hasSpread(args: []const *Node) bool {
        for (args) |a| if (a.* == .spread) return true;
        return false;
    }

    fn compileClass(self: *Compiler, node: *Node, inferred_name: ?[]const u8, name_from_stack: bool) CompileError!void {
        const c = node.class_expr;
        const captures_frame = if (self.scope) |scope|
            try classDeferredBodiesCaptureFrame(self.arena, scope, c.members, c.name)
        else
            false;

        // ClassDefinitionEvaluation creates its lexical Environment before
        // evaluating heritage, with an explicit class binding already in TDZ.
        try self.pushLexicalScope();
        defer self.popLexicalScope();
        if (c.name.len > 0) if (self.scope) |scope|
            try scope.addEnvironmentLexical(self.arena, c.name, true);
        try self.emitEnterClassEnvironment();
        if (c.name.len > 0) try self.emitDeclareEnvironmentLexicalName(c.name, true);

        const saved_strict = self.is_strict;
        self.is_strict = true;
        defer self.is_strict = saved_strict;
        var input_count: u32 = @intFromBool(name_from_stack);
        if (c.superclass) |superclass| {
            try self.compileExpr(superclass);
            _ = try self.chunk.emit(.prepare_class_heritage, 0);
            input_count += 2;
        }
        const capture_environment = if (captures_frame) capture: {
            const plan = try self.arena.create(bc.DirectEvalPlan);
            plan.* = try buildDirectEvalPlan(
                self.arena,
                self.scope.?,
                if (self.function_binding_phase == .parameters) .parameter else .variable,
                self.environment_depth,
            );
            break :capture plan;
        } else null;
        const class_index = try self.chunk.addClass(node, capture_environment);
        self.chunk.classes.items[class_index].inferred_name = inferred_name;
        self.chunk.classes.items[class_index].name_from_stack = name_from_stack;
        // ClassDefinitionEvaluation creates a fresh PrivateEnvironment only
        // when PrivateBoundIdentifiers is non-empty, after heritage validation.
        // Computed names and construction then share that one identity.
        if (classHasPrivateBoundNames(c.members))
            _ = try self.chunk.emit(.prepare_class_private_environment, class_index);
        const computed_count = try self.compileClassComputedKeys(c.members);
        input_count = std.math.add(u32, input_count, computed_count) catch return error.OutOfMemory;
        _ = try self.chunk.emitAB(.eval_class, class_index, input_count);
        try self.emitExitClassEnvironment();
    }

    fn compileClassComputedKeys(self: *Compiler, members: []const ast.ClassMember) CompileError!u32 {
        var count: u32 = 0;
        for (members) |m| {
            if (m.static_block != null) continue;
            if (m.key_expr) |ke| {
                try self.compileExpr(ke);
                // ClassElementName evaluation includes ToPropertyKey. Its user
                // effects (or abrupt completion) precede the next element name,
                // even when that later expression suspends the activation.
                _ = try self.chunk.emit(.to_property_key, 0);
                count += 1;
            }
        }
        return count;
    }

    fn classHasPrivateBoundNames(members: []const ast.ClassMember) bool {
        for (members) |member|
            if (member.key_expr == null and value_mod.isRawPrivateName(member.key)) return true;
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

    fn addCurrentDirectEvalPlan(self: *Compiler) CompileError!u32 {
        const scope = self.scope orelse return error.Unsupported;
        if (self.function_binding_phase == .parameters)
            if (self.chunk.parameter_direct_eval_plan) |plan_index| return plan_index;
        const plan = try buildDirectEvalPlan(
            self.arena,
            scope,
            if (self.function_binding_phase == .parameters) .parameter else .variable,
            self.environment_depth,
        );
        const plan_index = try self.chunk.addDirectEvalPlan(plan);
        if (self.function_binding_phase == .parameters)
            self.chunk.parameter_direct_eval_plan = plan_index;
        return plan_index;
    }

    fn compileFunction(
        self: *Compiler,
        definition_node: *const Node,
        fnode: *const ast.FunctionNode,
        named_expr: bool,
    ) CompileError!u32 {
        // InstantiateGeneratorFunctionObject / InstantiateAsyncFunctionObject
        // capture the current lexical environment. Env-mode bodies need live
        // views of defining frame slots, with the same binding identity and
        // runtime-record ordering as direct eval (never copied local values).
        const capture_environment = if ((fnode.is_generator or fnode.is_async) and self.scope != null) blk: {
            const plan = try self.arena.create(bc.DirectEvalPlan);
            plan.* = try buildDirectEvalPlan(
                self.arena,
                self.scope.?,
                if (self.function_binding_phase == .parameters) .parameter else .variable,
                self.environment_depth,
            );
            break :blk plan;
        } else null;
        // A `using` in the body's statement lists lowers as a resource scope
        // (see the `.block` arm); only a `for`/`for-of` HEAD `using` still keeps
        // a frame-mode body on the tree walker, as in compilePlainFunctionInner.
        // Build this function's slot namespace: parameters first, then every
        // function-scoped declaration in the body (not descending into nested
        // functions). The scope chains to the enclosing function for upvalues.
        const scope = try self.arena.create(FnScope);
        const self_environment_depth: u32 = @intFromBool(named_expr and fnode.has_name_binding and !fnode.is_arrow);
        const parent_direct_eval_environment_depth = std.math.add(
            u32,
            self.environment_depth,
            self_environment_depth,
        ) catch return error.Unsupported;
        const tdz_checks = !fnode.is_generator and try functionNeedsTdzChecks(self.arena, self.hash_state, fnode);
        scope.* = .{
            .parent = self.scope,
            .parent_binding_phase = self.function_binding_phase,
            .hash_state = self.hash_state,
            .names = .{ .state = self.hash_state },
            .parent_environment_depth = self.environment_depth,
            .parent_direct_eval_environment_depth = parent_direct_eval_environment_depth,
            .parent_with_depth = self.with_depth,
            .tdz_checks = tdz_checks,
        };

        var template_admission: bc.FnTemplateAdmission = undefined;
        const sub: ?*Chunk = if (fnode.is_generator) blk: {
            var rejection: ?GeneratorRejection = null;
            const compiled = try compileGeneratorInner(self.arena, fnode, self.debug_checkpoints, self.hash_state, &rejection);
            template_admission = .generator_compiled;
            break :blk compiled;
        } else if (fnode.is_async) blk: {
            var rejection: ?AsyncRejection = null;
            const compiled = try compileAsyncInner(self.arena, fnode, self.debug_checkpoints, self.hash_state, &rejection);
            template_admission = .async_compiled;
            break :blk compiled;
        } else blk: {
            const compiled = try self.arena.create(Chunk);
            compiled.* = Chunk.init(self.arena);
            const parameter_layout = configurePlainParameters(self.arena, scope, fnode) catch |err| switch (err) {
                error.Unsupported => {
                    if (self.scope == null) {
                        template_admission = .plain_parameter_prologue;
                        break :blk null;
                    }
                    return error.Unsupported;
                },
                error.OutOfMemory => return error.OutOfMemory,
            };
            const arguments_slot = try addArgumentsSlot(self.arena, scope, fnode);
            try planFunctionDeclarations(self.arena, scope, fnode, arguments_slot != null);
            const mapped_parameter_indices = try configureMappedParameters(
                self.arena,
                scope,
                fnode,
                arguments_slot != null or functionSupportsLegacyArguments(fnode),
                arguments_slot != null,
            );

            compiled.param_count = @intCast(fnode.params.len);
            compiled.parameter_slots = parameter_layout.slots;
            compiled.destructuring_parameter_indices = parameter_layout.destructuring_indices;
            compiled.default_parameter_indices = parameter_layout.default_indices;
            compiled.rest_parameter_index = parameter_layout.rest_index;
            compiled.has_non_simple_parameters = parameter_layout.hasNonSimple();
            compiled.arguments_slot = arguments_slot;
            compiled.mapped_parameter_indices = mapped_parameter_indices;

            var sub_c = Compiler{
                .arena = self.arena,
                .chunk = compiled,
                .mode = .function,
                .hash_state = self.hash_state,
                .scope = scope,
                .is_strict = fnode.is_strict,
                .is_derived_constructor = false,
                .derived_instance_initializers = if (fnode.is_arrow) self.derived_instance_initializers else &.{},
                .debug_checkpoints = self.debug_checkpoints,
            };
            sub_c.compilePlainParameterEntries(fnode, &parameter_layout) catch |err| switch (err) {
                error.Unsupported => {
                    if (self.scope == null) {
                        template_admission = .plain_parameter_prologue;
                        break :blk null;
                    }
                    return error.Unsupported;
                },
                error.OutOfMemory => return error.OutOfMemory,
            };
            try sub_c.emitParameterBodyCopies();
            if (fnode.is_expr_body) {
                sub_c.compileExpr(fnode.body) catch |e| switch (e) {
                    error.Unsupported => {
                        if (self.scope == null) {
                            template_admission = .plain_unsupported_lowering;
                            break :blk null;
                        }
                        return error.Unsupported;
                    },
                    error.OutOfMemory => return error.OutOfMemory,
                };
                _ = try compiled.emit(.ret, 0);
            } else {
                sub_c.compileStmt(fnode.body) catch |e| switch (e) {
                    error.Unsupported => {
                        if (self.scope == null) {
                            template_admission = .plain_unsupported_lowering;
                            break :blk null;
                        }
                        return error.Unsupported;
                    },
                    error.OutOfMemory => return error.OutOfMemory,
                }; // body is a block
                _ = try compiled.emit(.ret_undef, 0);
            }
            compiled.local_count = scope.count;
            compiled.mapped_parameter_indices = try finalizeMappedParameterIndices(self.arena, scope, mapped_parameter_indices);
            compiled.lexical_slots = scope.lexical_slots.items;
            try retainDebugLocalNames(self.arena, compiled, scope);
            try compiled.finalize();
            template_admission = .plain_compiled;
            break :blk compiled;
        };
        if (fnode.is_generator or fnode.is_async) {
            for (fnode.params) |p| _ = try scope.addLocal(self.arena, p.name, false, false);
        }
        const tmpl = try self.arena.create(bc.FnTemplate);
        tmpl.* = .{
            .capture_environment = capture_environment,
            .name = fnode.name,
            .definition_node = definition_node,
            // A *named function expression* (not a declaration, not an inferred
            // name, not a method, not an arrow) self-binds its own name in an
            // enclosing immutable scope — recorded here so `make_closure` wraps
            // the closure env.
            .self_name = if (named_expr and fnode.has_name_binding and !fnode.is_arrow) fnode.name else "",
            .params = fnode.params,
            .is_expr_body = fnode.is_expr_body,
            .body = fnode.body,
            .source = fnode.source,
            .uses_arguments = fnode.uses_arguments,
            .uses_direct_eval = fnode.uses_direct_eval,
            .is_generator = fnode.is_generator,
            .is_async = fnode.is_async,
            .is_arrow = fnode.is_arrow,
            .is_method = fnode.is_method,
            .is_strict = fnode.is_strict,
            .admission = template_admission,
            .chunk = sub,
            .local_count = scope.count,
        };
        return self.chunk.addFn(tmpl);
    }

    // ---- loop bookkeeping -------------------------------------------------

    /// The finally region of a scope holding `await using` resources. Async
    /// DisposeResources awaits each [Symbol.asyncDispose] result in turn, so it
    /// cannot run inside one opcode: a throw completion is parked as the
    /// scope's pending error, then each of the `count` async resources is
    /// stepped and awaited under its own catch so a rejection folds into the
    /// SuppressedError chain instead of escaping, and the synchronous tail
    /// throws whatever accumulated. `dispose_scope 1` itself only throws once
    /// the scope is empty, which the same catch collects.
    fn emitAsyncDisposeRegion(self: *Compiler, count: usize) CompileError!void {
        const none = std.math.maxInt(u32);
        _ = try self.chunk.emit(.dispose_seed_completion, 0);
        var i: usize = 0;
        while (i < count) : (i += 1) {
            const guard = try self.emitPushHandler(.push_handler, none, none);
            // [awaitable, needs_await]: await only when a resource actually
            // produced something to await, so an `await using` whose declaration
            // never executed does not add a microtask turn.
            _ = try self.chunk.emit(.dispose_scope, 1);
            const no_await = try self.chunk.emit(.jump_if_false, 0);
            _ = try self.chunk.emit(.await_op, 0);
            self.chunk.patchToHere(no_await);
            _ = try self.chunk.emit(.pop, 0);
            try self.emitPopHandler();
            const done = try self.chunk.emit(.jump, 0);
            self.chunk.code.items[guard].a = @intCast(self.chunk.here());
            _ = try self.chunk.emit(.dispose_record_error, 0);
            self.chunk.patchToHere(done);
        }
        _ = try self.chunk.emit(.dispose_scope, 0);
    }

    /// Every handler push/pop goes through these so `handler_depth` mirrors the
    /// runtime handler stack. `push_handler_catch` records the depth below the
    /// incoming exception; it is still one handler.
    fn emitPushHandler(self: *Compiler, op: bc.Op, catch_pc: u32, finally_pc: u32) CompileError!usize {
        const at = try self.chunk.emitAB(op, catch_pc, finally_pc);
        self.handler_depth += 1;
        return at;
    }

    fn emitPopHandler(self: *Compiler) CompileError!void {
        std.debug.assert(self.handler_depth > 0);
        _ = try self.chunk.emit(.pop_handler, 0);
        self.handler_depth -= 1;
    }

    /// The operand of an `abrupt_break`/`abrupt_continue`: the target's
    /// environment depth in the low half and the number of handlers to pop in
    /// the high half. Both are activation-local nesting counts, far below the
    /// split; a program that somehow exceeds it tree-walks instead.
    fn abruptJumpOperand(self: *Compiler, loop: *const Loop) CompileError!u32 {
        const to_pop = self.handler_depth - loop.handler_depth;
        if (to_pop > std.math.maxInt(u16) or loop.environment_depth > std.math.maxInt(u16)) return error.Unsupported;
        return loop.environment_depth | (to_pop << 16);
    }

    /// A break/continue issued from inside a finally body overrides that
    /// finally's in-flight completion. Each such body between the site and the
    /// target left a two-word [value, kind] record on the operand stack that
    /// `end_finally` will now never consume; drop them so the target sees the
    /// operand stack it expects (a for-in's three-word state, for instance).
    fn emitDiscardActiveFinallyRecords(self: *Compiler, loop: *const Loop) CompileError!void {
        var remaining = self.active_finally - loop.active_finally;
        while (remaining > 0) : (remaining -= 1) {
            _ = try self.chunk.emit(.pop, 0);
            _ = try self.chunk.emit(.pop, 0);
        }
    }

    /// Annex B: a call expression in assignment-target position is evaluated
    /// for its effects, then rejected. The call's value is dropped and the
    /// ReferenceError carries the shape's wording; the trailing `load_undefined`
    /// is unreachable and only keeps an expression's stack shape regular.
    fn emitCallTargetRejection(self: *Compiler, call: *Node, shape: bc.NotAReference, as_expression: bool) CompileError!void {
        try self.compileExpr(call);
        _ = try self.chunk.emit(.pop, 0);
        _ = try self.chunk.emit(.throw_not_a_reference, @intFromEnum(shape));
        if (as_expression) _ = try self.chunk.emit(.load_undefined, 0);
    }

    fn pushLoop(self: *Compiler) CompileError!*Loop {
        const loop = try self.arena.create(Loop);
        loop.* = .{
            .finally_depth = self.finally_depth,
            .environment_depth = self.environment_depth,
            .handler_depth = self.handler_depth,
            .active_finally = self.active_finally,
        };
        try self.loops.append(self.arena, loop);
        return loop;
    }

    fn pushLabel(self: *Compiler, label: []const u8, labels_iteration: bool) CompileError!*Loop {
        const target = try self.arena.create(Loop);
        target.* = .{
            .label = label,
            .is_loop = false,
            .labels_iteration = labels_iteration,
            .finally_depth = self.finally_depth,
            .environment_depth = self.environment_depth,
            .handler_depth = self.handler_depth,
            .active_finally = self.active_finally,
        };
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
            } else if (target.is_loop) {
                // An unlabeled `break` targets the innermost iteration statement or
                // switch (both carry is_loop), NOT an enclosing labeled block/stmt
                // wrapper (is_loop == false) — those are only labeled-break targets.
                return target;
            }
        }
        return null;
    }

    /// Resolve an unlabeled continue to the nearest iteration statement. A
    /// labeled continue first finds the label wrapper, verifies that it labels
    /// an iteration statement, then selects that statement's loop through any
    /// intervening label wrappers.
    fn currentContinueTarget(self: *Compiler, label: ?[]const u8) ?*Loop {
        if (label) |needle| {
            var label_index = self.loops.items.len;
            while (label_index > 0) {
                label_index -= 1;
                const target = self.loops.items[label_index];
                if (target.label) |have| if (std.mem.eql(u8, have, needle)) {
                    if (!target.labels_iteration) return null;
                    var loop_index = label_index + 1;
                    while (loop_index < self.loops.items.len) : (loop_index += 1) {
                        const loop = self.loops.items[loop_index];
                        if (loop.is_loop and !loop.is_switch) return loop;
                    }
                    return null;
                };
            }
            return null;
        }

        var i = self.loops.items.len;
        while (i > 0) {
            i -= 1;
            if (self.loops.items[i].is_loop and !self.loops.items[i].is_switch) return self.loops.items[i];
        }
        return null;
    }
};

/// Hoist only function-scoped declarations. Lexical declarations are allocated
/// when their exact block/loop/switch/catch scope is entered during compilation,
/// so same-spelled bindings receive distinct activation slots.
fn planFunctionDeclarations(arena: std.mem.Allocator, scope: *FnScope, function: *const ast.FunctionNode, arguments_object_needed: bool) CompileError!void {
    if (function.is_expr_body) return;
    scope.function_body = function.body;
    const statements = switch (function.body.*) {
        .block => |statements| statements,
        else => return error.Unsupported,
    };
    // FunctionDeclarationInstantiation: only declarations directly in the body
    // own ordinary variable slots. Block functions get separate lexical cells.
    try collectFunctionLocals(arena, scope, function.body);
    if (!function.is_strict and functionHasBlockNestedFuncDecl(function)) {
        const Collector = struct {
            arena: std.mem.Allocator,
            scope: *FnScope,

            pub fn add(self: *@This(), declaration: *Node, name: []const u8) CompileError!void {
                const slot = try self.scope.addLocal(self.arena, name, false, false);
                try self.scope.annex_b_variables.put(self.arena, self.scope.hash_state, @intFromPtr(declaration), slot);
            }
        };
        var collector = Collector{ .arena = arena, .scope = scope };
        try annex_b.collect(CompileError, arena, statements, 0, function.params, arguments_object_needed, &collector);
    }
}

fn collectFunctionLocals(arena: std.mem.Allocator, scope: *FnScope, node: *Node) CompileError!void {
    switch (node.*) {
        .var_decl => |d| {
            if (d.kind == .@"var") _ = try scope.addLocal(arena, d.name, false, false);
        },
        .destructure_decl => |d| if (d.kind == .@"var") {
            var collector = FunctionLocalBindingCollector{ .scope = scope };
            try collectPatternBindingNames(arena, d.pattern, &collector);
        },
        .func_decl => {},
        .block => |stmts| for (stmts) |s| {
            if (node == scope.function_body) if (annex_b.functionDeclaration(s)) |declaration| {
                _ = try scope.addLocal(arena, declaration.func_decl.name, false, false);
                continue;
            };
            try collectFunctionLocals(arena, scope, s);
        },
        .decl_group => |stmts| for (stmts) |s| try collectFunctionLocals(arena, scope, s),
        .if_stmt => |s| {
            try collectFunctionLocals(arena, scope, s.consequent);
            if (s.alternate) |alt| try collectFunctionLocals(arena, scope, alt);
        },
        .while_stmt => |s| try collectFunctionLocals(arena, scope, s.body),
        .do_while_stmt => |s| try collectFunctionLocals(arena, scope, s.body),
        .for_stmt => |f| {
            if (f.init) |ini| try collectFunctionLocals(arena, scope, ini);
            try collectFunctionLocals(arena, scope, f.body);
        },
        .for_in => |f| {
            if (f.decl_kind) |kind| {
                if (kind == .@"var") {
                    var collector = FunctionLocalBindingCollector{ .scope = scope };
                    try collectPatternBindingNames(arena, f.target, &collector);
                }
            }
            try collectFunctionLocals(arena, scope, f.body);
        },
        .switch_stmt => |s| for (s.cases) |c| for (c.body) |st| try collectFunctionLocals(arena, scope, st),
        .labeled_stmt => |s| try collectFunctionLocals(arena, scope, s.body),
        .with_stmt => |s| try collectFunctionLocals(arena, scope, s.body),
        .try_stmt => |t| {
            try collectFunctionLocals(arena, scope, t.block);
            if (t.catch_block) |cb| try collectFunctionLocals(arena, scope, cb);
            if (t.finally_block) |fb| try collectFunctionLocals(arena, scope, fb);
        },
        // Expressions (incl. nested function/arrow literals) declare no names in
        // this function's scope. `var` inside these statement forms is hoisted to
        // the function scope, matching the tree-walker's hoistVarsIn.
        else => {},
    }
}

const FunctionLocalBindingCollector = struct {
    scope: *FnScope,

    fn add(self: *FunctionLocalBindingCollector, arena: std.mem.Allocator, name: []const u8) CompileError!void {
        _ = try self.scope.addLocal(arena, name, false, false);
    }
};

fn expectChunkLayoutEqual(left: *const Chunk, right: *const Chunk) !void {
    try std.testing.expectEqual(left.param_count, right.param_count);
    try std.testing.expectEqual(left.local_count, right.local_count);
    try std.testing.expectEqualSlices(u32, left.parameter_slots, right.parameter_slots);
    try std.testing.expectEqualSlices(u32, left.destructuring_parameter_indices, right.destructuring_parameter_indices);
    try std.testing.expectEqualSlices(u32, left.default_parameter_indices, right.default_parameter_indices);
    try std.testing.expectEqual(left.rest_parameter_index, right.rest_parameter_index);
    try std.testing.expectEqual(left.arguments_slot, right.arguments_slot);
    try std.testing.expectEqualSlices(u32, left.mapped_parameter_indices, right.mapped_parameter_indices);
    try std.testing.expectEqualSlices(u32, left.lexical_slots, right.lexical_slots);
    try std.testing.expectEqual(left.code.items.len, right.code.items.len);
    for (left.code.items, right.code.items) |left_instruction, right_instruction| {
        try std.testing.expectEqual(left_instruction.op, right_instruction.op);
        try std.testing.expectEqual(left_instruction.a, right_instruction.a);
        try std.testing.expectEqual(left_instruction.b, right_instruction.b);
    }
    try std.testing.expectEqual(left.names.items.len, right.names.items.len);
    for (left.names.items, right.names.items) |left_name, right_name|
        try std.testing.expectEqualStrings(left_name, right_name);
    try std.testing.expectEqual(left.fns.items.len, right.fns.items.len);
    for (left.fns.items, right.fns.items) |left_template, right_template| {
        try std.testing.expectEqualStrings(left_template.name, right_template.name);
        try std.testing.expectEqual(left_template.admission, right_template.admission);
        try std.testing.expectEqual(left_template.local_count, right_template.local_count);
        try std.testing.expectEqual(left_template.chunk != null, right_template.chunk != null);
        if (left_template.chunk) |left_nested|
            try expectChunkLayoutEqual(left_nested, right_template.chunk.?);
    }
}

test "compiler binding indexes share one lazy failure-atomic secure context" {
    var unavailable = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    var failed_state: CompileHashState = .{};
    var failed = SecureStringMapUnmanaged(void){ .state = &failed_state };
    try std.testing.expectError(error.OutOfMemory, failed.put(unavailable.allocator(), "first", {}));
    try std.testing.expect(failed_state.context == null);
    try std.testing.expectEqual(@as(usize, 0), failed.count());
    try std.testing.expectEqual(@as(usize, 0), failed.index.capacity());

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var lazy_state: CompileHashState = .{};
    var names = LoopBindingNames.init(&lazy_state);
    try names.add(arena.allocator(), "only");
    try names.add(arena.allocator(), "only");
    try std.testing.expect(lazy_state.context == null);
    try names.add(arena.allocator(), "second");
    try std.testing.expect(lazy_state.context != null);
    try std.testing.expectEqual(@as(usize, 2), names.multiple.count());

    var sibling = SecureStringMapUnmanaged(void){ .state = &lazy_state };
    try sibling.put(arena.allocator(), "third", {});
    try std.testing.expectEqual(lazy_state.context.?.seed, sibling.state.context.?.seed);
}

test "compiler AST identity indexes are keyed lazy and failure atomic" {
    var empty_state: CompileHashState = .{};
    var empty: SecureIdentityMapUnmanaged(u32) = .{};
    try std.testing.expectEqual(@as(?u32, null), empty.get(&empty_state, 0x101));
    try std.testing.expect(!empty.contains(&empty_state, 0x101));
    try std.testing.expect(empty_state.context == null);

    var unavailable = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    try std.testing.expectError(error.OutOfMemory, empty.put(unavailable.allocator(), &empty_state, 0x101, 7));
    try std.testing.expect(empty_state.context == null);
    try std.testing.expectEqual(@as(usize, 0), empty.count());
    try std.testing.expectEqual(@as(usize, 0), empty.index.capacity());

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    try empty.put(allocator, &empty_state, 0x101, 7);
    try std.testing.expect(empty_state.context != null);
    try std.testing.expectEqual(@as(?u32, 7), empty.get(&empty_state, 0x101));

    const target_mask: u64 = 1023;
    var collision_identities: [32]usize = undefined;
    var collision_count: usize = 0;
    var candidate: usize = 1;
    while (collision_count < collision_identities.len) : (candidate += 1) {
        if ((SecureIdentityHashContext{ .seed = 0 }).hash(candidate) & target_mask != 0) continue;
        collision_identities[collision_count] = candidate;
        collision_count += 1;
    }

    var keyed_state = CompileHashState{ .context = .{ .seed = 0x4153_545f_4944_454e } };
    var keyed: SecureIdentityMapUnmanaged(u32) = .{};
    var keyed_buckets: [target_mask + 1]bool = @splat(false);
    var distinct_keyed_buckets: usize = 0;
    for (collision_identities, 0..) |identity, index| {
        try std.testing.expectEqual(@as(u64, 0), (SecureIdentityHashContext{ .seed = 0 }).hash(identity) & target_mask);
        const bucket = (SecureIdentityHashContext{ .seed = keyed_state.context.?.seed }).hash(identity) & target_mask;
        if (!keyed_buckets[bucket]) {
            keyed_buckets[bucket] = true;
            distinct_keyed_buckets += 1;
        }
        try keyed.put(allocator, &keyed_state, identity, @intCast(index));
    }
    try std.testing.expect(distinct_keyed_buckets >= 24);
    try std.testing.expectEqual(collision_identities.len, keyed.count());
    for (collision_identities, 0..) |identity, index|
        try std.testing.expectEqual(@as(?u32, @intCast(index)), keyed.get(&keyed_state, identity));
}

test "compiler direct eval plan retains ordered live binding identity" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var hash_state: CompileHashState = .{};
    var scope = FnScope{
        .parent = null,
        .hash_state = &hash_state,
        .names = .{ .state = &hash_state },
        .tdz_checks = true,
    };
    const parameter_slot = try scope.addLocal(allocator, "parameter", false, false);
    const variable_slot = try scope.addLocal(allocator, "variable", false, false);
    _ = try scope.addLocal(allocator, "\x00activation-temp", false, false);
    scope.names.getPtr("parameter").?.mapped_parameter = true;

    try scope.pushLexicalScope(allocator);
    const outer_slot = try scope.addLexicalChecked(allocator, "value", false);
    _ = try scope.addLexicalChecked(allocator, "capturedRuntime", false);
    scope.lexical_scopes.items[scope.lexical_scopes.items.len - 1].getPtr("capturedRuntime").?.environment = true;
    try scope.pushLexicalScope(allocator);
    const inner_slot = try scope.addLexicalChecked(allocator, "value", true);

    const plan = try buildDirectEvalPlan(allocator, &scope, .variable, 0);
    try std.testing.expectEqual(@as(usize, 3), plan.scopes.len);

    const function_scope = plan.scopes[0];
    try std.testing.expectEqual(bc.DirectEvalScopeKind.variable, function_scope.kind);
    try std.testing.expect(function_scope.declaration_target);
    try std.testing.expectEqual(@as(u32, 0), function_scope.frame_depth);
    try std.testing.expectEqual(@as(usize, 2), function_scope.bindings.len);
    try std.testing.expectEqualStrings("parameter", function_scope.bindings[0].name);
    try std.testing.expectEqual(parameter_slot, function_scope.bindings[0].slot);
    try std.testing.expect(function_scope.bindings[0].mapped_parameter);
    try std.testing.expectEqualStrings("variable", function_scope.bindings[1].name);
    try std.testing.expectEqual(variable_slot, function_scope.bindings[1].slot);

    const outer = plan.scopes[1];
    try std.testing.expectEqual(bc.DirectEvalScopeKind.lexical, outer.kind);
    try std.testing.expectEqual(@as(u32, 0), outer.frame_depth);
    try std.testing.expectEqual(@as(usize, 1), outer.bindings.len);
    try std.testing.expectEqualStrings("value", outer.bindings[0].name);
    try std.testing.expectEqual(outer_slot, outer.bindings[0].slot);
    try std.testing.expect(outer.bindings[0].lexical);
    try std.testing.expect(outer.bindings[0].tdz_checked);
    try std.testing.expect(!outer.bindings[0].immutable);

    const inner = plan.scopes[2];
    try std.testing.expectEqual(bc.DirectEvalScopeKind.lexical, inner.kind);
    try std.testing.expectEqual(@as(u32, 0), inner.frame_depth);
    try std.testing.expectEqual(@as(usize, 1), inner.bindings.len);
    try std.testing.expectEqualStrings("value", inner.bindings[0].name);
    try std.testing.expectEqual(inner_slot, inner.bindings[0].slot);
    try std.testing.expect(inner.bindings[0].lexical);
    try std.testing.expect(inner.bindings[0].tdz_checked);
    try std.testing.expect(inner.bindings[0].immutable);
}

test "compiler direct eval plan preserves defining-frame and runtime-environment depths" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var hash_state: CompileHashState = .{};
    var outer = FnScope{
        .parent = null,
        .hash_state = &hash_state,
        .names = .{ .state = &hash_state },
        .tdz_checks = true,
    };
    _ = try outer.addLocal(allocator, "outerVariable", false, false);
    try outer.pushLexicalScope(allocator);
    _ = try outer.addLexicalChecked(allocator, "outerLexical", false);

    var inner = FnScope{
        .parent = &outer,
        .hash_state = &hash_state,
        .names = .{ .state = &hash_state },
        .tdz_checks = true,
    };
    _ = try inner.addLocal(allocator, "innerVariable", false, false);

    const plan = try buildDirectEvalPlan(allocator, &inner, .variable, 0);
    try std.testing.expectEqual(@as(usize, 3), plan.scopes.len);
    try std.testing.expectEqualStrings("outerVariable", plan.scopes[0].bindings[0].name);
    try std.testing.expectEqual(bc.DirectEvalScopeKind.variable, plan.scopes[0].kind);
    try std.testing.expectEqual(@as(u32, 1), plan.scopes[0].frame_depth);
    try std.testing.expectEqualStrings("outerLexical", plan.scopes[1].bindings[0].name);
    try std.testing.expectEqual(bc.DirectEvalScopeKind.lexical, plan.scopes[1].kind);
    try std.testing.expectEqual(@as(u32, 1), plan.scopes[1].frame_depth);
    try std.testing.expectEqual(@as(u32, 0), plan.scopes[1].environment_depth);
    try std.testing.expectEqualStrings("innerVariable", plan.scopes[2].bindings[0].name);
    try std.testing.expectEqual(bc.DirectEvalScopeKind.variable, plan.scopes[2].kind);
    try std.testing.expect(plan.scopes[2].declaration_target);
    try std.testing.expectEqual(@as(u32, 0), plan.scopes[2].frame_depth);
    try std.testing.expectEqual(@as(usize, 1), plan.frame_boundaries.len);
    try std.testing.expectEqual(@as(u32, 0), plan.frame_boundaries[0].child_frame_depth);
    try std.testing.expectEqual(@as(u32, 0), plan.frame_boundaries[0].environment_depth);

    inner.parent_environment_depth = 1;
    inner.parent_direct_eval_environment_depth = 1;
    outer.lexical_scope_environment_depth.items[0] = 1;
    const interleaved = try buildDirectEvalPlan(allocator, &inner, .variable, 2);
    try std.testing.expectEqual(@as(u32, 1), interleaved.scopes[1].environment_depth);
    try std.testing.expectEqual(@as(usize, 1), interleaved.frame_boundaries.len);
    try std.testing.expectEqual(@as(u32, 0), interleaved.frame_boundaries[0].child_frame_depth);
    try std.testing.expectEqual(@as(u32, 1), interleaved.frame_boundaries[0].environment_depth);
    try std.testing.expectEqual(@as(u32, 2), interleaved.current_environment_depth);
}

test "compiler threads activation plans through fixed spread and tail eval calls" {
    const cases = [_]struct {
        source: []const u8,
        tail: bool,
        expected: bc.Op,
        plan_in_b: bool,
    }{
        .{ .source = "eval('local')", .tail = false, .expected = .call_eval_activation, .plan_in_b = true },
        .{ .source = "eval(...args)", .tail = false, .expected = .call_eval_activation_spread, .plan_in_b = false },
        .{ .source = "eval('local')", .tail = true, .expected = .tail_call_eval_activation, .plan_in_b = true },
        .{ .source = "eval(...args)", .tail = true, .expected = .tail_call_eval_activation_spread, .plan_in_b = false },
    };

    for (cases) |case| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const allocator = arena.allocator();
        var parser = try @import("parser.zig").Parser.init(allocator, case.source);
        const program = try parser.parseProgram();
        const expression = program.program[0].expr_stmt;

        var hash_state: CompileHashState = .{};
        var scope = FnScope{
            .parent = null,
            .hash_state = &hash_state,
            .names = .{ .state = &hash_state },
        };
        _ = try scope.addLocal(allocator, "local", false, false);
        _ = try scope.addLocal(allocator, "args", false, false);
        var chunk = bc.Chunk.init(allocator);
        var compiler = Compiler{
            .arena = allocator,
            .chunk = &chunk,
            .mode = .function,
            .hash_state = &hash_state,
            .scope = &scope,
            .is_strict = true,
        };
        if (case.tail)
            try compiler.compileTailExpr(expression)
        else
            try compiler.compileExpr(expression);

        try std.testing.expectEqual(@as(usize, 1), chunk.direct_eval_plans.items.len);
        const instruction = chunk.code.items[chunk.code.items.len - 1];
        try std.testing.expectEqual(case.expected, instruction.op);
        try std.testing.expectEqual(@as(u32, 0), if (case.plan_in_b) instruction.b else instruction.a);
        try std.testing.expectEqual(@as(usize, 2), chunk.direct_eval_plans.items[0].scopes[0].bindings.len);
    }
}

test "compiler keyed placement disperses a deterministic default collision family" {
    const target_mask: u64 = 1023;
    const collision_count = 32;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var names: std.ArrayListUnmanaged([]const u8) = .empty;
    var suffix: usize = 0;
    while (names.items.len != collision_count) : (suffix += 1) {
        const name = try std.fmt.allocPrint(allocator, "collision{d}", .{suffix});
        if ((std.hash.Wyhash.hash(0, name) & target_mask) == 0)
            try names.append(allocator, name);
    }

    var keyed_state = CompileHashState{ .context = .{ .seed = 0x434f_4d50_494c_4552 } };
    var keyed = SecureStringMapUnmanaged(void){ .state = &keyed_state };
    var occupied: [target_mask + 1]bool = @splat(false);
    var occupied_count: usize = 0;
    for (names.items) |name| {
        try std.testing.expectEqual(@as(u64, 0), std.hash.Wyhash.hash(0, name) & target_mask);
        const bucket = std.hash.Wyhash.hash(keyed_state.context.?.seed, name) & target_mask;
        if (!occupied[bucket]) {
            occupied[bucket] = true;
            occupied_count += 1;
        }
        try keyed.put(allocator, name, {});
    }
    try std.testing.expect(occupied_count > collision_count / 2);
    for (names.items) |name| try std.testing.expect(keyed.contains(name));
}

test "compiler hash seeds preserve frame and nested chunk layout" {
    var ast_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ast_arena.deinit();
    var parser = try @import("parser.zig").Parser.init(
        ast_arena.allocator(),
        "function target(first, second, first) { var ordinary = first; let lexical = ordinary; function nested(value) { let inner = lexical; return inner + value; } { function legacy() { return lexical; } } for (let index = 0; index < 1; index++) { try { throw [index]; } catch ([caught]) { (() => caught); } } class Box { method() { return 1; } } return nested(second) + legacy(); }",
    );
    const program = try parser.parseProgram();
    const function = program.program[0].func_decl;

    var first_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer first_arena.deinit();
    var first_state = CompileHashState{ .context = .{ .seed = 0x4649_5253_545f_4b45 } };
    var first_rejection: ?Compiler.PlainFunctionRejection = null;
    const first = try Compiler.compilePlainFunctionInner(first_arena.allocator(), function, &first_state, &first_rejection);

    var second_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer second_arena.deinit();
    var second_state = CompileHashState{ .context = .{ .seed = 0x5345_434f_4e44_4b45 } };
    var second_rejection: ?Compiler.PlainFunctionRejection = null;
    const second = try Compiler.compilePlainFunctionInner(second_arena.allocator(), function, &second_state, &second_rejection);

    try std.testing.expectEqual(first.local_count, second.local_count);
    try expectChunkLayoutEqual(first.chunk, second.chunk);
}

/// Fault replay must observe the same allocation points on every attempt.
/// Arena backing-buffer resize can succeed in one address-space layout and
/// fail in another, bypassing an injected alloc failure. Refuse resize/remap
/// only in this fixture, so every arena growth exercises the alloc path.
const CompilerAllocationReplay = struct {
    backing: std.mem.Allocator,

    fn allocator(self: *@This()) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{
            .alloc = allocate,
            .resize = std.mem.Allocator.noResize,
            .remap = std.mem.Allocator.noRemap,
            .free = release,
        } };
    }

    fn allocate(raw: *anyopaque, len: usize, alignment: std.mem.Alignment, return_address: usize) ?[*]u8 {
        const self: *@This() = @ptrCast(@alignCast(raw));
        return self.backing.rawAlloc(len, alignment, return_address);
    }

    fn release(raw: *anyopaque, memory: []u8, alignment: std.mem.Alignment, return_address: usize) void {
        const self: *@This() = @ptrCast(@alignCast(raw));
        self.backing.rawFree(memory, alignment, return_address);
    }
};

fn exerciseCompilerBindingAllocationFailures(allocator: std.mem.Allocator) !void {
    var ast_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ast_arena.deinit();
    var parser = try @import("parser.zig").Parser.init(
        ast_arena.allocator(),
        "function target(first, second) { let lexical = first; { let shadow = second; lexical += shadow; } return lexical; }",
    );
    const program = try parser.parseProgram();

    var replay = CompilerAllocationReplay{ .backing = allocator };
    var compile_arena = std.heap.ArenaAllocator.init(replay.allocator());
    defer compile_arena.deinit();
    switch (try Compiler.admitPlainFunction(compile_arena.allocator(), program.program[0].func_decl)) {
        .compiled => |compiled| try std.testing.expect(compiled.chunk.code.items.len != 0),
        .rejected => return error.TestUnexpectedResult,
    }
}

test "compiler binding publication survives every allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseCompilerBindingAllocationFailures,
        .{},
    );
}

fn exerciseBlockFunctionAllocationFailures(allocator: std.mem.Allocator) !void {
    var ast_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ast_arena.deinit();
    var parser = try @import("parser.zig").Parser.init(ast_arena.allocator(),
        \\function target(parameter) {
        \\  label: function body() { return 1; }
        \\  { function parameter() {} }
        \\  var reads = [];
        \\  with ({ value: 1 }) {
        \\    for (let i = 0; i < 3; i++) {
        \\      switch (i) {
        \\        case 0: function local() { return local.value + i; }
        \\        default: local.value = value; reads.push(local);
        \\      }
        \\    }
        \\  }
        \\  return reads;
        \\}
    );
    const program = try parser.parseProgram();
    var replay = CompilerAllocationReplay{ .backing = allocator };
    var compile_arena = std.heap.ArenaAllocator.init(replay.allocator());
    defer compile_arena.deinit();
    switch (try Compiler.admitPlainFunction(compile_arena.allocator(), program.program[0].func_decl)) {
        .compiled => |compiled| try std.testing.expect(compiled.chunk.code.items.len != 0),
        .rejected => return error.TestUnexpectedResult,
    }
}

test "block functions compiler planning propagates allocation failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, exerciseBlockFunctionAllocationFailures, .{});
}

fn exerciseEnvironmentDeclarationAllocationFailures(allocator: std.mem.Allocator) !void {
    var ast_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ast_arena.deinit();
    var parser = try @import("parser.zig").Parser.init(ast_arena.allocator(),
        \\var top; let { lexical } = {};
        \\{ function top() { return top; } }
        \\function* generator(parameter) {
        \\  yield typeof legacy;
        \\  switch (yield 1) { case 1: function legacy() { return legacy; } yield legacy; }
        \\  { function parameter() {} }
        \\}
        \\async function asynchronous() { { function local() { return local; } await 0; return local; } }
    );
    const program = try parser.parseProgram();
    var replay = CompilerAllocationReplay{ .backing = allocator };
    var compile_arena = std.heap.ArenaAllocator.init(replay.allocator());
    defer compile_arena.deinit();
    const chunk = try Compiler.compileProgram(compile_arena.allocator(), program);
    try std.testing.expect(chunk.environment_declarations.is_script);
    try std.testing.expectEqual(@as(usize, 1), chunk.environment_declarations.annex_b.len);
}

test "environment declarations compiler planning propagates allocation failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, exerciseEnvironmentDeclarationAllocationFailures, .{});
}

fn exerciseSuspendableCaptureAllocationFailures(allocator: std.mem.Allocator) !void {
    var ast_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ast_arena.deinit();
    var parser = try @import("parser.zig").Parser.init(ast_arena.allocator(),
        \\function outer(value = 1, read = function* () { yield value; }) {
        \\  let cell = value;
        \\  return function middle(extra) {
        \\    with ({ runtime: 2 }) {
        \\      let local = 3;
        \\      return [read, function* () { yield cell + extra + runtime + local; },
        \\        async function () { return await cell; }, async function* () { yield cell; }];
        \\    }
        \\  };
        \\}
    );
    const program = try parser.parseProgram();
    var replay = CompilerAllocationReplay{ .backing = allocator };
    var compile_arena = std.heap.ArenaAllocator.init(replay.allocator());
    defer compile_arena.deinit();
    const compiled = try Compiler.compilePlainFunction(compile_arena.allocator(), program.program[0].func_decl);
    try std.testing.expect(compiled.chunk.fns.items[0].capture_environment != null);
    try std.testing.expect(compiled.chunk.parameter_direct_eval_plan == null);
}

test "nested suspendable compiler capture planning propagates allocation failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, exerciseSuspendableCaptureAllocationFailures, .{});
}

fn exerciseParameterReferenceAllocationFailures(allocator: std.mem.Allocator) !void {
    var ast_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ast_arena.deinit();
    var parser = try @import("parser.zig").Parser.init(
        ast_arena.allocator(),
        "function outer(seed) { let held = seed; return function(value = held, { [key]: next = value }, read = () => next) { return read; }; }",
    );
    const program = try parser.parseProgram();
    var replay = CompilerAllocationReplay{ .backing = allocator };
    var compile_arena = std.heap.ArenaAllocator.init(replay.allocator());
    defer compile_arena.deinit();
    const compiled = try Compiler.compilePlainFunction(compile_arena.allocator(), program.program[0].func_decl);
    try std.testing.expect(compiled.chunk.fns.items[0].chunk != null);
}

test "parameter references compiler planning propagates allocation failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, exerciseParameterReferenceAllocationFailures, .{});
}

fn exerciseParameterAssignmentAllocationFailures(allocator: std.mem.Allocator) !void {
    var ast_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ast_arena.deinit();
    var parser = try @import("parser.zig").Parser.init(
        ast_arena.allocator(),
        "function outer(box) { let held = 1; with (box) { return function(value = held += side(), next = box[key()]++, last = held ||= next) { return () => value + last; }; } }",
    );
    const program = try parser.parseProgram();
    var replay = CompilerAllocationReplay{ .backing = allocator };
    var compile_arena = std.heap.ArenaAllocator.init(replay.allocator());
    defer compile_arena.deinit();
    const compiled = try Compiler.compilePlainFunction(compile_arena.allocator(), program.program[0].func_decl);
    try std.testing.expect(compiled.chunk.fns.items[0].chunk != null);
}

test "parameter assignments compiler planning propagates allocation failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, exerciseParameterAssignmentAllocationFailures, .{});
}

test "compiler preserves a first-statement debugger checkpoint" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var diagnostic: ?@import("parser.zig").SourceLocation = null;
    var parser = try @import("parser.zig").Parser.initWithDiagnostic(
        arena.allocator(),
        "debugger; 1;",
        &diagnostic,
    );
    const program = try parser.parseProgram();
    const chunk = try Compiler.compileProgram(arena.allocator(), program);
    try std.testing.expect(chunk.code.items.len >= 2);
    try std.testing.expectEqual(bc.Op.nop, chunk.code.items[0].op);
    try std.testing.expect(chunk.debug_nodes[0] != null);
    try std.testing.expect(chunk.debug_nodes[0].?.* == .debugger_stmt);
}

test "compiler checks hoisted function closure over later lexical TDZ" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var parser = try @import("parser.zig").Parser.init(
        arena.allocator(),
        "function outer(){ function f(){ return x; } f(); let x; }",
    );
    const program = try parser.parseProgram();
    const outer = program.program[0].func_decl;

    const compiled = try Compiler.compilePlainFunction(arena.allocator(), outer);
    var saw_init = false;
    var saw_captured_check = false;
    for (compiled.chunk.code.items) |inst| {
        if (inst.op == .init_local_lexical) saw_init = true;
    }
    for (compiled.chunk.fns.items) |template| if (template.chunk) |chunk| {
        for (chunk.code.items) |inst| {
            if (inst.op == .load_upval_lexical) saw_captured_check = true;
        }
    };
    try std.testing.expect(saw_init);
    try std.testing.expect(saw_captured_check);
}

test "compiler pending lexical query preserves TDZ classifications" {
    const cases = [_]struct { source: []const u8, hazardous: bool }{
        .{ .source = "function f(){ let value = 1; return value; }", .hazardous = false },
        .{ .source = "function f(){ unrelated; let value = 1; }", .hazardous = false },
        .{ .source = "function f(){ value; let value = 1; }", .hazardous = true },
        .{ .source = "function f(){ let value = value; }", .hazardous = true },
        .{ .source = "function f(){ let [value] = []; }", .hazardous = false },
        .{ .source = "function f(){ let [value = value] = []; }", .hazardous = true },
        .{ .source = "function f(){ let [value = later] = []; let later = 1; }", .hazardous = true },
        .{ .source = "function f(){ let earlier = 1; let [value = earlier] = []; }", .hazardous = false },
        .{ .source = "function f(){ let { [later]: value } = {}; let later = 1; }", .hazardous = true },
        .{ .source = "function f(){ function read(){ return value; } let value = 1; }", .hazardous = true },
        .{ .source = "function f(){ class Box { field = value; } let value = 1; }", .hazardous = true },
        .{ .source = "function f(){ class Box { static field = value; } let value = 1; }", .hazardous = true },
        .{ .source = "function f(){ let value = 1; class Box { field = value; } }", .hazardous = false },
    };
    for (cases) |case| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var parser = try @import("parser.zig").Parser.init(arena.allocator(), case.source);
        const program = try parser.parseProgram();
        var hash_state = CompileHashState{ .context = .{ .seed = 0x5444_5a5f_5445_5354 } };
        const binding_inventory = try Compiler.functionBindingInventory(arena.allocator(), &hash_state, program.program[0].func_decl);
        try std.testing.expectEqual(
            case.hazardous,
            try Compiler.functionHasTdzHazard(
                arena.allocator(),
                program.program[0].func_decl,
                &binding_inventory.bindings,
            ),
        );
    }
}

test "compiler plain function binding inventory preserves lexical and shadow classifications" {
    const cases = [_]struct { source: []const u8, has_lexical: bool, has_shadowing: bool }{
        .{ .source = "function f(parameter){ var local; }", .has_lexical = false, .has_shadowing = false },
        .{ .source = "function f(){ let local; }", .has_lexical = true, .has_shadowing = false },
        .{ .source = "function f(){ let [first, second] = []; }", .has_lexical = true, .has_shadowing = false },
        .{ .source = "function f(){ { let local; } { let local; } }", .has_lexical = true, .has_shadowing = true },
        .{ .source = "function f(parameter){ { let parameter; } }", .has_lexical = true, .has_shadowing = true },
        .{ .source = "function f(){ try {} catch (caught) {} }", .has_lexical = true, .has_shadowing = false },
    };
    for (cases) |case| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var parser = try @import("parser.zig").Parser.init(arena.allocator(), case.source);
        const program = try parser.parseProgram();
        var hash_state = CompileHashState{ .context = .{ .seed = 0x4249_4e44_5445_5354 } };
        const inventory = try Compiler.functionBindingInventory(arena.allocator(), &hash_state, program.program[0].func_decl);
        try std.testing.expectEqual(case.has_lexical, inventory.has_lexical);
        try std.testing.expectEqual(case.has_shadowing, inventory.has_shadowing);
    }
}

test "compiler loop binding query preserves capture classifications" {
    const cases = [_]struct { source: []const u8, captured: bool }{
        .{ .source = "function f(){ for (let first = 0; false;) {} }", .captured = false },
        .{ .source = "function f(){ for (let first = 0, last = 1; false;) { (function(){ return unrelated; }); } }", .captured = false },
        .{ .source = "function f(){ for (let first = 0, last = 1; false;) { (function(){ return first; }); } }", .captured = true },
        .{ .source = "function f(){ for (let first = 0, last = 1; false;) { (function(){ return last; }); } }", .captured = true },
        .{ .source = "function f(){ for (let first = function(){ return last; }, last = 1; false;) {} }", .captured = true },
        .{ .source = "function f(){ for (let value = 0; (function(){ return value; });) {} }", .captured = true },
        .{ .source = "function f(){ for (let value = 0; false; (function(){ return value; })) {} }", .captured = true },
        .{ .source = "function f(){ for (let [value, read = function(){ return value; }] = []; false;) {} }", .captured = true },
        .{ .source = "function f(){ for (let value = 0; false;) { class Box { field = value; } } }", .captured = true },
        .{ .source = "function f(){ for (let value of []) { value; } }", .captured = false },
        .{ .source = "function f(){ for (let value of [function(){ return value; }]) {} }", .captured = true },
        .{ .source = "function f(){ for (let [first, last] of []) { (function(){ return last; }); } }", .captured = true },
        .{ .source = "function f(){ for (let value of []) { for (;;) { (function(){ return value; }); } } }", .captured = true },
        // Shadowing remains deliberately conservative, matching the previous
        // exact-name scans until the classifier owns full lexical resolution.
        .{ .source = "function f(){ for (let value of []) { (function(value){ return value; }); } }", .captured = true },
    };
    for (cases) |case| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var parser = try @import("parser.zig").Parser.init(arena.allocator(), case.source);
        const program = try parser.parseProgram();
        const body = program.program[0].func_decl.body.block[0];
        var hash_state = CompileHashState{ .context = .{ .seed = 0x4c4f_4f50_5445_5354 } };
        const captured = switch (body.*) {
            .for_stmt => |loop| try forLoopCapturesLexical(arena.allocator(), &hash_state, loop.init.?, loop.cond, loop.update, loop.body),
            .for_in => |loop| try forOfCapturesLexical(arena.allocator(), &hash_state, loop.target, loop.var_init, loop.iterable, loop.body),
            else => return error.TestUnexpectedResult,
        };
        try std.testing.expectEqual(case.captured, captured);
    }
}

test "compiler repeated body query preserves capture classifications" {
    const cases = [_]struct {
        source: []const u8,
        first: bool = false,
        last: bool = false,
        catch_binding: bool = false,
        any: bool,
    }{
        .{ .source = "function f(){ while(false){ let first=0; let last=1; } }", .any = false },
        .{ .source = "function f(){ while(false){ let first=0; let last=1; eval(source); } }", .first = true, .last = true, .any = true },
        .{ .source = "function f(){ while(false){ let first=0; let last=1; eval?.(source); } }", .any = false },
        .{ .source = "function f(){ while(false){ let first=0; let last=1; (0, eval)(source); } }", .any = false },
        .{ .source = "function f(){ while(false){ let first=0; let last=1; (function(){ return unrelated; }); } }", .any = false },
        .{ .source = "function f(){ while(false){ let first=0; let last=1; (function(){ return first; }); } }", .first = true, .any = true },
        .{ .source = "function f(){ while(false){ let first=0; let last=1; (function(){ return last; }); } }", .last = true, .any = true },
        .{ .source = "function f(){ while(false){ let [first,last]=[]; (function(){ return last; }); } }", .last = true, .any = true },
        .{ .source = "function f(){ while(false){ if(false){ let first=0; (function(){ return first; }); } } }", .first = true, .any = true },
        .{ .source = "function f(){ while(false){ switch(0){ case 0: let last=1; (function(){ return last; }); } } }", .last = true, .any = true },
        .{ .source = "function f(){ while(false){ try{ let first=0; (function(){ return first; }); }finally{} } }", .first = true, .any = true },
        .{ .source = "function f(){ while(false){ try{}catch([first,last]){ (function(){ return last; }); } } }", .catch_binding = true, .any = true },
        .{ .source = "function f(){ while(false){ while(false){ let first=0; (function(){ return first; }); } } }", .any = false },
        .{ .source = "function f(){ while(false){ let first=0; while(false){ (function(){ return first; }); } } }", .first = true, .any = true },
        .{ .source = "function f(){ while(false){ let last=1; class Box{ field=last; } } }", .last = true, .any = true },
    };
    for (cases) |case| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var parser = try @import("parser.zig").Parser.init(arena.allocator(), case.source);
        const program = try parser.parseProgram();
        const statement = program.program[0].func_decl.body.block[0];
        if (statement.* != .while_stmt) return error.TestUnexpectedResult;
        const body = statement.while_stmt.body;
        var hash_state = CompileHashState{ .context = .{ .seed = 0x424f_4459_5445_5354 } };
        const captures = try RepeatedBodyCaptures.init(arena.allocator(), &hash_state, body);
        try std.testing.expectEqual(case.first, captures.nameCaptured("first"));
        try std.testing.expectEqual(case.last, captures.nameCaptured("last"));
        try std.testing.expectEqual(case.any, captures.any());
        if (case.catch_binding) {
            if (body.* != .block or body.block.len != 1 or body.block[0].* != .try_stmt)
                return error.TestUnexpectedResult;
            try std.testing.expect(captures.catchPatternCaptured(body.block[0].try_stmt.catch_param.?));
        }
    }
}

fn exerciseRepeatedBodyIdentityAllocationFailures(allocator: std.mem.Allocator) !void {
    var ast_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ast_arena.deinit();
    var parser = try @import("parser.zig").Parser.init(
        ast_arena.allocator(),
        "function f(){ while(false){ try{}catch([first,last]){ (function(){ return last; }); } } }",
    );
    const program = try parser.parseProgram();
    const statement = program.program[0].func_decl.body.block[0];
    if (statement.* != .while_stmt) return error.TestUnexpectedResult;
    const body = statement.while_stmt.body;

    var replay = CompilerAllocationReplay{ .backing = allocator };
    var compile_arena = std.heap.ArenaAllocator.init(replay.allocator());
    defer compile_arena.deinit();
    var hash_state = CompileHashState{ .context = .{ .seed = 0x4341_5443_485f_4f4f } };
    const captures = try RepeatedBodyCaptures.init(compile_arena.allocator(), &hash_state, body);
    if (body.* != .block or body.block.len != 1 or body.block[0].* != .try_stmt)
        return error.TestUnexpectedResult;
    try std.testing.expect(captures.catchPatternCaptured(body.block[0].try_stmt.catch_param.?));
}

test "compiler repeated catch identity planning survives every allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseRepeatedBodyIdentityAllocationFailures,
        .{},
    );
}

test "canonical parameter lowering unwinds every compiler allocation failure" {
    const Probe = struct {
        fn run(backing: std.mem.Allocator) !void {
            var arena = std.heap.ArenaAllocator.init(backing);
            defer arena.deinit();
            var parser = try @import("parser.zig").Parser.init(arena.allocator(),
                \\function make(seed, holder={value:seed}, [first,...rest]=[holder,...[]],
                \\              Box=class{field=first;read(){return holder.value;}},
                \\              pattern=/x/g, value=new Box(...[]),
                \\              read=value?.read?.(), changed=({value:seed}=holder)) {
                \\  return [value,pattern,read,changed];
                \\}
            );
            const program = try parser.parseProgram();
            const compiled = switch (try Compiler.admitPlainFunction(arena.allocator(), program.program[0].func_decl)) {
                .compiled => |compiled| compiled,
                .rejected => return error.TestUnexpectedResult,
            };
            try std.testing.expectEqual(@as(usize, 7), compiled.chunk.default_parameter_indices.len);
            try std.testing.expectEqual(@as(usize, 1), compiled.chunk.destructuring_parameter_indices.len);
            try std.testing.expectEqual(@as(usize, 1), compiled.chunk.classes.items.len);
            try std.testing.expect(compiled.chunk.classes.items[0].capture_environment != null);
            try std.testing.expect(compiled.chunk.has_non_simple_parameters);
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Probe.run, .{});
}

fn exerciseLiteralFunctionMetadata(backing: std.mem.Allocator) !void {
    var ast_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ast_arena.deinit();
    var parser = try @import("parser.zig").Parser.init(ast_arena.allocator(),
        \\function build(key, original) {
        \\  return { fixed(){}, copy:original.read, [key](){},
        \\    [key]:function(){}, [key]:original.read, [key]:function named(){},
        \\    get [key](){}, set [key](value){} };
        \\}
    );
    const program = try parser.parseProgram();
    var replay = CompilerAllocationReplay{ .backing = backing };
    var arena = std.heap.ArenaAllocator.init(replay.allocator());
    defer arena.deinit();
    const compiled = try Compiler.compilePlainFunction(arena.allocator(), program.program[0].func_decl);
    var computed: usize = 0;
    var fixed: usize = 0;
    var accessors: usize = 0;
    const expected = [_]u32{ bc.literal_function_method | bc.literal_function_anonymous, bc.literal_function_anonymous, 0, 0 };
    for (compiled.chunk.code.items, 0..) |inst, index| switch (inst.op) {
        .init_prop => {
            const name = compiled.chunk.names.items[inst.a];
            try std.testing.expectEqual(if (std.mem.eql(u8, name, "fixed")) bc.literal_function_method else @as(u32, 0), inst.b);
            fixed += 1;
        },
        .init_prop_computed => {
            try std.testing.expect(computed < expected.len);
            try std.testing.expectEqual(expected[computed], inst.a);
            computed += 1;
        },
        .init_getter, .init_setter => {
            try std.testing.expect(index >= 2);
            try std.testing.expectEqual(bc.Op.make_closure, compiled.chunk.code.items[index - 1].op);
            try std.testing.expectEqual(bc.Op.to_property_key, compiled.chunk.code.items[index - 2].op);
            accessors += 1;
        },
        else => {},
    };
    try std.testing.expectEqual(@as(usize, 2), fixed);
    try std.testing.expectEqual(expected.len, computed);
    try std.testing.expectEqual(@as(usize, 2), accessors);
}

test "literal function metadata preserves syntax through compiler allocation failures" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, exerciseLiteralFunctionMetadata, .{});
}

test "compiler reports stable plain-function admission reasons" {
    const cases = [_]struct {
        source: []const u8,
        expected: Compiler.PlainFunctionRejection,
    }{
        .{ .source = "function* f(){}", .expected = .generator_or_async },
    };

    for (cases) |case| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var parser = try @import("parser.zig").Parser.init(arena.allocator(), case.source);
        const program = try parser.parseProgram();
        const admission = try Compiler.admitPlainFunction(arena.allocator(), program.program[0].func_decl);
        switch (admission) {
            .compiled => return error.TestUnexpectedResult,
            .rejected => |reason| try std.testing.expectEqual(case.expected, reason),
        }
    }

    const admitted_parameter_prologues = [_][]const u8{
        "function f(first, value = first?.value){}",
        "function f(first, value = first?.()){}",
        "function f(first, args, value = first(...args)){}",
        "function f(first, args, value = new first(...args)){}",
        "function f(value = /x/){}",
        "function f(value = {}){}",
        "function f(value = []){}",
        "function f(value = class {}){}",
        "function f(value = (holder.value = {})){}",
        "function f(value = (outer += side?.())){}",
        "function f(value = delete holder.value){}",
        "function f([value] = []){}",
        "function f(value = ++outer){}",
        "function f(value = outer--){}",
        "function f(value = outer += 2){}",
        "function f(value = outer ||= 2){}",
        "function f(value = outer &&= 2){}",
        "function f(value = outer ??= 2){}",
        "function f(value = holder.value = 2){}",
        "function f(value = holder[key()] *= 2){}",
        "function f(value = ++holder.value){}",
        "function f(value = holder[key()]--){}",
        "function f({ [key += 'x']: value = ++outer }){}",
        "function f(value = outer){}",
        "function f(value = undefined){}",
        "function f(value = holder.value){}",
        "function f(first, value = first[outer]){}",
        "function f(first, value = first(outer)){}",
        "function f(first, value = new first(outer)){}",
        "function f(value = value + 1){}",
        "function f(value = later + 1, later){}",
        "function f(value = function(){ using resource = source; }){}",
        "function f(arguments = arguments){}",
        "function f(first, value = first + outer){}",
        "function f(value = side()){}",
        "function f(value = (1, outer)){}",
        "function f(value = false || outer){}",
        "function f(value = false ? 1 : outer){}",
        "function f({ [key]: value }){}",
        "function f(value = 1, ...tail){}",
        "function f([value = 1]){}",
        "function f([value], ...tail){}",
        "function f(...[value = 1]){}",
        "function f(key, { [key]: value = 1 }, ...tail){}",
    };
    for (admitted_parameter_prologues) |source| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var parser = try @import("parser.zig").Parser.init(arena.allocator(), source);
        const program = try parser.parseProgram();
        switch (try Compiler.admitPlainFunction(arena.allocator(), program.program[0].func_decl)) {
            .compiled => {},
            .rejected => return error.TestUnexpectedResult,
        }
    }

    var direct_eval_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer direct_eval_arena.deinit();
    var direct_eval_parser = try @import("parser.zig").Parser.init(
        direct_eval_arena.allocator(),
        "function f(value){ \"use strict\"; return eval('value'); }",
    );
    const direct_eval_program = try direct_eval_parser.parseProgram();
    const direct_eval = switch (try Compiler.admitPlainFunction(
        direct_eval_arena.allocator(),
        direct_eval_program.program[0].func_decl,
    )) {
        .compiled => |compiled| compiled.chunk,
        .rejected => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqual(@as(usize, 1), direct_eval.direct_eval_plans.items.len);
    var saw_activation_eval = false;
    for (direct_eval.code.items) |instruction|
        saw_activation_eval = saw_activation_eval or instruction.op == .tail_call_eval_activation;
    try std.testing.expect(saw_activation_eval);

    var inherited_arguments_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer inherited_arguments_arena.deinit();
    var inherited_arguments_parser = try @import("parser.zig").Parser.init(
        inherited_arguments_arena.allocator(),
        "(value = arguments) => value",
    );
    const inherited_arguments_program = try inherited_arguments_parser.parseProgram();
    const arrow_expression = inherited_arguments_program.program[0].expr_stmt;
    if (arrow_expression.* != .function or !arrow_expression.function.is_arrow)
        return error.TestUnexpectedResult;
    const inherited_arguments_admission = try Compiler.admitPlainFunction(inherited_arguments_arena.allocator(), arrow_expression.function);
    switch (inherited_arguments_admission) {
        .compiled => {},
        .rejected => return error.TestUnexpectedResult,
    }

    var private_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer private_arena.deinit();
    var private_parser = try @import("parser.zig").Parser.init(
        private_arena.allocator(),
        "class PrivateBox { #method() {} method(first, value = first.#method()) {} }",
    );
    const private_program = try private_parser.parseProgram();
    const private_declaration = private_program.program[0];
    if (private_declaration.* != .var_decl or private_declaration.var_decl.init == null)
        return error.TestUnexpectedResult;
    const private_class = private_declaration.var_decl.init.?;
    if (private_class.* != .class_expr or private_class.class_expr.members.len != 2)
        return error.TestUnexpectedResult;
    const private_method = private_class.class_expr.members[1].func orelse return error.TestUnexpectedResult;
    const private_chunk = switch (try Compiler.admitPlainFunction(private_arena.allocator(), private_method.function)) {
        .compiled => |compiled| compiled.chunk,
        .rejected => return error.TestUnexpectedResult,
    };
    var private_reads: usize = 0;
    for (private_chunk.code.items) |instruction|
        private_reads += @intFromBool(instruction.op == .get_private_name);
    try std.testing.expectEqual(@as(usize, 1), private_reads);

    var super_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer super_arena.deinit();
    var super_parser = try @import("parser.zig").Parser.init(
        super_arena.allocator(),
        "class Derived extends Base { method(value = super.method()) {} }",
    );
    const super_program = try super_parser.parseProgram();
    const super_declaration = super_program.program[0];
    if (super_declaration.* != .var_decl or super_declaration.var_decl.init == null)
        return error.TestUnexpectedResult;
    const super_class = super_declaration.var_decl.init.?;
    if (super_class.* != .class_expr or super_class.class_expr.members.len != 1)
        return error.TestUnexpectedResult;
    const super_method = super_class.class_expr.members[0].func orelse return error.TestUnexpectedResult;
    switch (try Compiler.admitPlainFunction(super_arena.allocator(), super_method.function)) {
        .compiled => {},
        .rejected => return error.TestUnexpectedResult,
    }

    var private_new_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer private_new_arena.deinit();
    var private_new_parser = try @import("parser.zig").Parser.init(
        private_new_arena.allocator(),
        "class PrivateConstruct { #Ctor; method(first, value = new (first.#Ctor)()) {} }",
    );
    const private_new_program = try private_new_parser.parseProgram();
    const private_new_declaration = private_new_program.program[0];
    if (private_new_declaration.* != .var_decl or private_new_declaration.var_decl.init == null)
        return error.TestUnexpectedResult;
    const private_new_class = private_new_declaration.var_decl.init.?;
    if (private_new_class.* != .class_expr or private_new_class.class_expr.members.len != 2)
        return error.TestUnexpectedResult;
    const private_new_method = private_new_class.class_expr.members[1].func orelse return error.TestUnexpectedResult;
    const private_new_chunk = switch (try Compiler.admitPlainFunction(private_new_arena.allocator(), private_new_method.function)) {
        .compiled => |compiled| compiled.chunk,
        .rejected => return error.TestUnexpectedResult,
    };
    var private_new_reads: usize = 0;
    for (private_new_chunk.code.items) |instruction|
        private_new_reads += @intFromBool(instruction.op == .get_private_name);
    try std.testing.expectEqual(@as(usize, 1), private_new_reads);

    var super_new_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer super_new_arena.deinit();
    var super_new_parser = try @import("parser.zig").Parser.init(
        super_new_arena.allocator(),
        "class DerivedConstruct extends Base { method(value = new super.Ctor()) {} }",
    );
    const super_new_program = try super_new_parser.parseProgram();
    const super_new_declaration = super_new_program.program[0];
    if (super_new_declaration.* != .var_decl or super_new_declaration.var_decl.init == null)
        return error.TestUnexpectedResult;
    const super_new_class = super_new_declaration.var_decl.init.?;
    if (super_new_class.* != .class_expr or super_new_class.class_expr.members.len != 1)
        return error.TestUnexpectedResult;
    const super_new_method = super_new_class.class_expr.members[0].func orelse return error.TestUnexpectedResult;
    switch (try Compiler.admitPlainFunction(super_new_arena.allocator(), super_new_method.function)) {
        .compiled => {},
        .rejected => return error.TestUnexpectedResult,
    }

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parser = try @import("parser.zig").Parser.init(arena.allocator(), "function f(holder, value){ holder.value += value; return holder.value + 1; }");
    const program = try parser.parseProgram();
    const admission = try Compiler.admitPlainFunction(arena.allocator(), program.program[0].func_decl);
    switch (admission) {
        .compiled => |compiled| try std.testing.expect(compiled.chunk.code.items.len != 0),
        .rejected => return error.TestUnexpectedResult,
    }

    var rest_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer rest_arena.deinit();
    var rest_parser = try @import("parser.zig").Parser.init(
        rest_arena.allocator(),
        "function restFrame(head, ...tail) { return head + tail.length; }",
    );
    const rest_program = try rest_parser.parseProgram();
    const rest_admission = try Compiler.admitPlainFunction(rest_arena.allocator(), rest_program.program[0].func_decl);
    switch (rest_admission) {
        .compiled => |compiled| {
            try std.testing.expectEqual(@as(u32, 2), compiled.chunk.param_count);
            try std.testing.expectEqual(@as(usize, 2), compiled.chunk.parameter_slots.len);
            try std.testing.expectEqual(@as(?u32, 1), compiled.chunk.rest_parameter_index);
            try std.testing.expect(compiled.chunk.has_non_simple_parameters);
            try std.testing.expectEqual(@as(usize, 0), compiled.chunk.default_parameter_indices.len);
            try std.testing.expectEqual(@as(u32, 1), compiled.chunk.parameter_slots[1]);
            try std.testing.expectEqual(@as(usize, 0), compiled.chunk.mapped_parameter_indices.len);
        },
        .rejected => return error.TestUnexpectedResult,
    }

    var default_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer default_arena.deinit();
    var default_parser = try @import("parser.zig").Parser.init(
        default_arena.allocator(),
        "function literalDefaults(number = 1, big = 9007199254740993n, text = 'ok', flag = false, nil = null, [letter] = 'z') { return number; }",
    );
    const default_program = try default_parser.parseProgram();
    const default_admission = try Compiler.admitPlainFunction(default_arena.allocator(), default_program.program[0].func_decl);
    switch (default_admission) {
        .compiled => |compiled| {
            try std.testing.expectEqual(@as(u32, 6), compiled.chunk.param_count);
            try std.testing.expectEqualSlices(u32, &.{ 6, 7, 8, 9, 10, 11 }, compiled.chunk.parameter_slots);
            try std.testing.expectEqualSlices(u32, &.{5}, compiled.chunk.destructuring_parameter_indices);
            try std.testing.expectEqualSlices(u32, &.{ 0, 1, 2, 3, 4, 5 }, compiled.chunk.default_parameter_indices);
            try std.testing.expectEqual(@as(?u32, null), compiled.chunk.rest_parameter_index);
            try std.testing.expect(compiled.chunk.has_non_simple_parameters);
            try std.testing.expectEqual(@as(usize, 0), compiled.chunk.mapped_parameter_indices.len);
            try std.testing.expectEqualStrings("number", compiled.chunk.debug_local_names[0]);
            try std.testing.expectEqualStrings("big", compiled.chunk.debug_local_names[1]);
            try std.testing.expectEqualStrings("text", compiled.chunk.debug_local_names[2]);
            try std.testing.expectEqualStrings("flag", compiled.chunk.debug_local_names[3]);
            try std.testing.expectEqualStrings("nil", compiled.chunk.debug_local_names[4]);
            try std.testing.expectEqualStrings("letter", compiled.chunk.debug_local_names[5]);
            for (compiled.chunk.debug_local_names[6..12], 0..) |name, index|
                try std.testing.expectEqualStrings(try std.fmt.allocPrint(default_arena.allocator(), "\x00param{d}", .{index}), name);
            for (compiled.chunk.code.items) |instruction| if (instruction.op == .bind_pattern)
                return error.TestUnexpectedResult;
        },
        .rejected => return error.TestUnexpectedResult,
    }

    var expression_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer expression_arena.deinit();
    var expression_parser = try @import("parser.zig").Parser.init(
        expression_arena.allocator(),
        "function closedDefaults(signed = -1, sum = 1 + 2, logical = (false && (1n / 0n)) || 4, choice = false ? (1n / 0n) : 6, sequence = (7, 8), voided = void 0, shifted = 8 >> 1, comparison = 1 < 2, bitwise = 6 & 3, big = -9n) { return signed; }",
    );
    const expression_program = try expression_parser.parseProgram();
    const expression_admission = try Compiler.admitPlainFunction(expression_arena.allocator(), expression_program.program[0].func_decl);
    switch (expression_admission) {
        .compiled => |compiled| {
            try std.testing.expectEqual(@as(u32, 10), compiled.chunk.param_count);
            try std.testing.expectEqualSlices(u32, &.{ 10, 11, 12, 13, 14, 15, 16, 17, 18, 19 }, compiled.chunk.parameter_slots);
            try std.testing.expectEqualSlices(u32, &.{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9 }, compiled.chunk.default_parameter_indices);
            try std.testing.expectEqual(@as(usize, 0), compiled.chunk.destructuring_parameter_indices.len);
            try std.testing.expectEqual(@as(?u32, null), compiled.chunk.rest_parameter_index);
            try std.testing.expect(compiled.chunk.has_non_simple_parameters);
            try std.testing.expectEqual(@as(usize, 0), compiled.chunk.mapped_parameter_indices.len);
            for (compiled.chunk.code.items) |instruction| if (instruction.op == .bind_pattern)
                return error.TestUnexpectedResult;
        },
        .rejected => return error.TestUnexpectedResult,
    }

    var invocation_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer invocation_arena.deinit();
    var invocation_parser = try @import("parser.zig").Parser.init(
        invocation_arena.allocator(),
        "function invocationDefaults(receiver = this, target = new.target, args = arguments) { return receiver; }",
    );
    const invocation_program = try invocation_parser.parseProgram();
    const invocation_admission = try Compiler.admitPlainFunction(invocation_arena.allocator(), invocation_program.program[0].func_decl);
    switch (invocation_admission) {
        .compiled => |compiled| {
            try std.testing.expectEqual(@as(u32, 3), compiled.chunk.param_count);
            try std.testing.expectEqualSlices(u32, &.{ 3, 4, 5 }, compiled.chunk.parameter_slots);
            try std.testing.expectEqualSlices(u32, &.{ 0, 1, 2 }, compiled.chunk.default_parameter_indices);
            try std.testing.expect(compiled.chunk.has_non_simple_parameters);
            try std.testing.expect(compiled.chunk.arguments_slot != null);
            try std.testing.expectEqual(@as(usize, 0), compiled.chunk.mapped_parameter_indices.len);
        },
        .rejected => return error.TestUnexpectedResult,
    }

    var earlier_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer earlier_arena.deinit();
    var earlier_parser = try @import("parser.zig").Parser.init(
        earlier_arena.allocator(),
        "function earlierDefaults(first, second = first, third = second, [fourth], fifth = fourth, { sixth }, seventh = sixth, arguments, eighth = arguments) { return eighth; }",
    );
    const earlier_program = try earlier_parser.parseProgram();
    const earlier_admission = try Compiler.admitPlainFunction(earlier_arena.allocator(), earlier_program.program[0].func_decl);
    switch (earlier_admission) {
        .compiled => |compiled| {
            try std.testing.expectEqual(@as(u32, 9), compiled.chunk.param_count);
            try std.testing.expectEqualSlices(u32, &.{ 1, 2, 4, 6, 8 }, compiled.chunk.default_parameter_indices);
            try std.testing.expectEqualSlices(u32, &.{ 3, 5 }, compiled.chunk.destructuring_parameter_indices);
            try std.testing.expect(compiled.chunk.has_non_simple_parameters);
            try std.testing.expectEqual(@as(?u32, null), compiled.chunk.arguments_slot);
            try std.testing.expectEqual(@as(usize, 0), compiled.chunk.mapped_parameter_indices.len);
        },
        .rejected => return error.TestUnexpectedResult,
    }

    var composed_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer composed_arena.deinit();
    var composed_parser = try @import("parser.zig").Parser.init(
        composed_arena.allocator(),
        "function composedDefaults(first, neg = -first, sum = first + 2, logical = first || 3, choice = first ? first : 4, sequence = (first, 5), receiver = this === this, target = new.target ? 1 : 2, own = arguments === arguments) { return sum; }",
    );
    const composed_program = try composed_parser.parseProgram();
    const composed_admission = try Compiler.admitPlainFunction(composed_arena.allocator(), composed_program.program[0].func_decl);
    switch (composed_admission) {
        .compiled => |compiled| {
            try std.testing.expectEqual(@as(u32, 9), compiled.chunk.param_count);
            try std.testing.expectEqualSlices(u32, &.{ 1, 2, 3, 4, 5, 6, 7, 8 }, compiled.chunk.default_parameter_indices);
            try std.testing.expect(compiled.chunk.has_non_simple_parameters);
            try std.testing.expect(compiled.chunk.arguments_slot != null);
            try std.testing.expectEqual(@as(usize, 0), compiled.chunk.mapped_parameter_indices.len);
        },
        .rejected => return error.TestUnexpectedResult,
    }

    var member_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer member_arena.deinit();
    var member_parser = try @import("parser.zig").Parser.init(
        member_arena.allocator(),
        "function memberDefaults(first, key, named = first.value, computed = first[key], nested = first.child.value, receiver = this.value, target = new.target.name, own = arguments.length, primitive = 'abc'.length) { return named; }",
    );
    const member_program = try member_parser.parseProgram();
    const member_admission = try Compiler.admitPlainFunction(member_arena.allocator(), member_program.program[0].func_decl);
    switch (member_admission) {
        .compiled => |compiled| {
            try std.testing.expectEqual(@as(u32, 9), compiled.chunk.param_count);
            try std.testing.expectEqualSlices(u32, &.{ 2, 3, 4, 5, 6, 7, 8 }, compiled.chunk.default_parameter_indices);
            try std.testing.expect(compiled.chunk.has_non_simple_parameters);
            try std.testing.expect(compiled.chunk.arguments_slot != null);
            try std.testing.expectEqual(@as(usize, 0), compiled.chunk.mapped_parameter_indices.len);
            var named_reads: usize = 0;
            var computed_reads: usize = 0;
            for (compiled.chunk.code.items) |instruction| switch (instruction.op) {
                .get_prop => named_reads += 1,
                .get_index => computed_reads += 1,
                else => {},
            };
            try std.testing.expectEqual(@as(usize, 7), named_reads);
            try std.testing.expectEqual(@as(usize, 1), computed_reads);
        },
        .rejected => return error.TestUnexpectedResult,
    }

    var call_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer call_arena.deinit();
    var call_parser = try @import("parser.zig").Parser.init(
        call_arena.allocator(),
        "function callDefaults(callee, receiver, key, direct = callee(2), named = receiver.method(3), computed = receiver[key](4), nested = receiver.child.method(5), argument = callee(receiver.value)) { return direct; }",
    );
    const call_program = try call_parser.parseProgram();
    const call_admission = try Compiler.admitPlainFunction(call_arena.allocator(), call_program.program[0].func_decl);
    switch (call_admission) {
        .compiled => |compiled| {
            try std.testing.expectEqual(@as(u32, 8), compiled.chunk.param_count);
            try std.testing.expectEqualSlices(u32, &.{ 3, 4, 5, 6, 7 }, compiled.chunk.default_parameter_indices);
            try std.testing.expect(compiled.chunk.has_non_simple_parameters);
            try std.testing.expectEqual(@as(usize, 0), compiled.chunk.mapped_parameter_indices.len);
            var value_calls: usize = 0;
            var receiver_calls: usize = 0;
            for (compiled.chunk.code.items) |instruction| switch (instruction.op) {
                .call => value_calls += 1,
                .call_with_this => receiver_calls += 1,
                else => {},
            };
            try std.testing.expectEqual(@as(usize, 2), value_calls);
            try std.testing.expectEqual(@as(usize, 3), receiver_calls);
        },
        .rejected => return error.TestUnexpectedResult,
    }

    var construction_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer construction_arena.deinit();
    var construction_parser = try @import("parser.zig").Parser.init(
        construction_arena.allocator(),
        "function constructionDefaults(Ctor, holder, key, direct = new Ctor(2), named = new holder.Ctor(3), computed = new holder[key](4), nested = new holder.child.Ctor(5), argument = new Ctor(holder.value)) { return direct; }",
    );
    const construction_program = try construction_parser.parseProgram();
    const construction_admission = try Compiler.admitPlainFunction(construction_arena.allocator(), construction_program.program[0].func_decl);
    switch (construction_admission) {
        .compiled => |compiled| {
            try std.testing.expectEqual(@as(u32, 8), compiled.chunk.param_count);
            try std.testing.expectEqualSlices(u32, &.{ 3, 4, 5, 6, 7 }, compiled.chunk.default_parameter_indices);
            try std.testing.expect(compiled.chunk.has_non_simple_parameters);
            try std.testing.expectEqual(@as(usize, 0), compiled.chunk.mapped_parameter_indices.len);
            var constructions: usize = 0;
            for (compiled.chunk.code.items) |instruction| {
                if (instruction.op == .new_call) constructions += 1;
            }
            try std.testing.expectEqual(@as(usize, 5), constructions);
        },
        .rejected => return error.TestUnexpectedResult,
    }

    var pattern_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer pattern_arena.deinit();
    var pattern_parser = try @import("parser.zig").Parser.init(
        pattern_arena.allocator(),
        "function destructured([first, { value }, ...tail], { keep, ...rest }) { return first + value + tail.length + keep + Object.keys(rest).length; }",
    );
    const pattern_program = try pattern_parser.parseProgram();
    const pattern_admission = try Compiler.admitPlainFunction(pattern_arena.allocator(), pattern_program.program[0].func_decl);
    switch (pattern_admission) {
        .compiled => |compiled| {
            try std.testing.expectEqual(@as(u32, 2), compiled.chunk.param_count);
            try std.testing.expectEqualSlices(u32, &.{ 5, 6 }, compiled.chunk.parameter_slots);
            try std.testing.expectEqualSlices(u32, &.{ 0, 1 }, compiled.chunk.destructuring_parameter_indices);
            try std.testing.expectEqual(@as(usize, 0), compiled.chunk.default_parameter_indices.len);
            try std.testing.expectEqualStrings("first", compiled.chunk.debug_local_names[0]);
            try std.testing.expectEqualStrings("value", compiled.chunk.debug_local_names[1]);
            try std.testing.expectEqualStrings("tail", compiled.chunk.debug_local_names[2]);
            try std.testing.expectEqualStrings("keep", compiled.chunk.debug_local_names[3]);
            try std.testing.expectEqualStrings("rest", compiled.chunk.debug_local_names[4]);
            try std.testing.expectEqualStrings("\x00param0", compiled.chunk.debug_local_names[5]);
            try std.testing.expectEqualStrings("\x00param1", compiled.chunk.debug_local_names[6]);
            try std.testing.expectEqual(@as(?u32, null), compiled.chunk.rest_parameter_index);
            try std.testing.expect(compiled.chunk.has_non_simple_parameters);
            try std.testing.expectEqual(@as(usize, 0), compiled.chunk.mapped_parameter_indices.len);
            var saw_iterator = false;
            var saw_object_rest = false;
            var saw_frame_store = false;
            for (compiled.chunk.code.items) |instruction| switch (instruction.op) {
                .bind_pattern => return error.TestUnexpectedResult,
                .iter_of => saw_iterator = true,
                .object_rest => saw_object_rest = true,
                .store_local => saw_frame_store = true,
                else => {},
            };
            try std.testing.expect(saw_iterator and saw_object_rest and saw_frame_store);
        },
        .rejected => return error.TestUnexpectedResult,
    }

    var shadow_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer shadow_arena.deinit();
    var shadow_parser = try @import("parser.zig").Parser.init(
        shadow_arena.allocator(),
        "function f(value){ { let value = 1; } { const value = 2; } return value; }",
    );
    const shadow_program = try shadow_parser.parseProgram();
    const shadow_compiled = try Compiler.compilePlainFunction(shadow_arena.allocator(), shadow_program.program[0].func_decl);
    try std.testing.expectEqual(@as(u32, 3), shadow_compiled.local_count);
    try std.testing.expectEqual(@as(usize, 2), shadow_compiled.chunk.lexical_slots.len);
    for (shadow_compiled.chunk.debug_local_names) |name| try std.testing.expectEqualStrings("value", name);

    var tdz_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer tdz_arena.deinit();
    var tdz_parser = try @import("parser.zig").Parser.init(
        tdz_arena.allocator(),
        "function f(){ function read(){ return value; } read(); let value = 1; value = 2; const fixed = 3; fixed = 4; }",
    );
    const tdz_program = try tdz_parser.parseProgram();
    const tdz_admission = try Compiler.admitPlainFunction(tdz_arena.allocator(), tdz_program.program[0].func_decl);
    const tdz_chunk = switch (tdz_admission) {
        .compiled => |compiled| compiled.chunk,
        .rejected => return error.TestUnexpectedResult,
    };
    var saw_init = false;
    var saw_checked_local_store = false;
    for (tdz_chunk.code.items) |inst| {
        if (inst.op == .init_local_lexical) saw_init = true;
        if (inst.op == .store_local_lexical) saw_checked_local_store = true;
    }
    try std.testing.expect(saw_init);
    try std.testing.expect(saw_checked_local_store);

    var hot_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer hot_arena.deinit();
    var hot_parser = try @import("parser.zig").Parser.init(
        hot_arena.allocator(),
        "function hot(limit){ let total = 0; for (let i = 0; i < limit; i = i + 1) total = total + i; return total; }",
    );
    const hot_program = try hot_parser.parseProgram();
    const hot_compiled = try Compiler.compilePlainFunction(hot_arena.allocator(), hot_program.program[0].func_decl);
    for (hot_compiled.chunk.code.items) |inst| switch (inst.op) {
        .init_local_lexical, .load_local_lexical, .load_upval_lexical, .store_local_lexical, .store_upval_lexical => return error.TestUnexpectedResult,
        else => {},
    };
}

test "compiler exposes direct eval lexical bindings in their TDZ" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parser = try @import("parser.zig").Parser.init(
        arena.allocator(),
        "function f(){ eval('later'); let later = 1; }",
    );
    const program = try parser.parseProgram();
    const compiled = switch (try Compiler.admitPlainFunction(arena.allocator(), program.program[0].func_decl)) {
        .compiled => |code| code,
        .rejected => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqual(@as(usize, 1), compiled.chunk.lexical_slots.len);
    try std.testing.expectEqual(@as(usize, 1), compiled.chunk.direct_eval_plans.items.len);
    const plan = compiled.chunk.direct_eval_plans.items[0];
    var found_later = false;
    for (plan.scopes) |scope| for (scope.bindings) |binding| {
        if (!std.mem.eql(u8, binding.name, "later")) continue;
        found_later = true;
        try std.testing.expect(binding.lexical);
        try std.testing.expect(binding.tdz_checked);
        try std.testing.expectEqual(compiled.chunk.lexical_slots[0], binding.slot);
    };
    try std.testing.expect(found_later);
}

test "compiler identifies only simple catch records for direct eval Annex B semantics" {
    const cases = [_]struct { source: []const u8, catch_name: []const u8, exempt: bool }{
        .{
            .source = "function f(){ try { throw 1; } catch (caught) { eval('var caught;'); } }",
            .catch_name = "caught",
            .exempt = true,
        },
        .{
            .source = "function f(){ try { throw { value: 1 }; } catch ({ value }) { eval('var value;'); } }",
            .catch_name = "value",
            .exempt = false,
        },
    };
    for (cases) |case| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var parser = try @import("parser.zig").Parser.init(arena.allocator(), case.source);
        const program = try parser.parseProgram();
        const compiled = switch (try Compiler.admitPlainFunction(arena.allocator(), program.program[0].func_decl)) {
            .compiled => |code| code,
            .rejected => return error.TestUnexpectedResult,
        };
        try std.testing.expectEqual(@as(usize, 1), compiled.chunk.direct_eval_plans.items.len);
        var found = false;
        for (compiled.chunk.direct_eval_plans.items[0].scopes) |scope| {
            if (scope.bindings.len != 1 or !std.mem.eql(u8, scope.bindings[0].name, case.catch_name)) continue;
            found = true;
            try std.testing.expectEqual(case.exempt, scope.is_catch_param);
        }
        try std.testing.expect(found);
    }
}

test "compiler admits direct eval for expression-free non-simple parameter lists" {
    const admitted = [_][]const u8{
        "function f(head, ...tail){ return eval('head + tail[0]'); }",
        "function f({ left, right }, [third]){ return eval('left + right + third'); }",
    };
    for (admitted) |source| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var parser = try @import("parser.zig").Parser.init(arena.allocator(), source);
        const program = try parser.parseProgram();
        const compiled = switch (try Compiler.admitPlainFunction(arena.allocator(), program.program[0].func_decl)) {
            .compiled => |code| code,
            .rejected => return error.TestUnexpectedResult,
        };
        try std.testing.expect(compiled.chunk.has_non_simple_parameters);
        try std.testing.expectEqual(@as(usize, 1), compiled.chunk.direct_eval_plans.items.len);
    }

    var body_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer body_arena.deinit();
    var body_parser = try @import("parser.zig").Parser.init(
        body_arena.allocator(),
        "function f(value = 1){ eval('var value = 9'); return value; }",
    );
    const body_program = try body_parser.parseProgram();
    const body_compiled = switch (try Compiler.admitPlainFunction(body_arena.allocator(), body_program.program[0].func_decl)) {
        .compiled => |compiled| compiled,
        .rejected => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqual(@as(usize, 1), body_compiled.chunk.direct_eval_plans.items.len);
    const body_plan = body_compiled.chunk.direct_eval_plans.items[0];
    try std.testing.expectEqual(@as(usize, 2), body_plan.scopes.len);
    try std.testing.expectEqual(bc.DirectEvalScopeKind.parameter, body_plan.scopes[0].kind);
    try std.testing.expect(!body_plan.scopes[0].declaration_target);
    try std.testing.expectEqual(bc.DirectEvalScopeKind.variable, body_plan.scopes[1].kind);
    try std.testing.expect(body_plan.scopes[1].declaration_target);
    var saw_dynamic_parameter_read = false;
    for (body_compiled.chunk.binding_reference_plans.items) |reference| {
        if (reference.direct_eval_frame_depth == 0) saw_dynamic_parameter_read = true;
    }
    try std.testing.expect(saw_dynamic_parameter_read);

    var parameter_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer parameter_arena.deinit();
    var parameter_parser = try @import("parser.zig").Parser.init(
        parameter_arena.allocator(),
        "function f(value = eval('1')){ return value; }",
    );
    const parameter_program = try parameter_parser.parseProgram();
    const parameter_compiled = switch (try Compiler.admitPlainFunction(parameter_arena.allocator(), parameter_program.program[0].func_decl)) {
        .compiled => |compiled| compiled,
        .rejected => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqual(@as(?u32, 0), parameter_compiled.chunk.parameter_direct_eval_plan);
    try std.testing.expectEqual(@as(usize, 1), parameter_compiled.chunk.direct_eval_plans.items.len);
    const parameter_plan = parameter_compiled.chunk.direct_eval_plans.items[0];
    try std.testing.expectEqual(@as(usize, 1), parameter_plan.scopes.len);
    try std.testing.expectEqual(bc.DirectEvalScopeKind.parameter, parameter_plan.scopes[0].kind);
    try std.testing.expect(parameter_plan.scopes[0].declaration_target);

    var both_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer both_arena.deinit();
    var both_parser = try @import("parser.zig").Parser.init(
        both_arena.allocator(),
        "function f(value = eval('1')){ return eval('value'); }",
    );
    const both_program = try both_parser.parseProgram();
    const both_compiled = switch (try Compiler.admitPlainFunction(both_arena.allocator(), both_program.program[0].func_decl)) {
        .compiled => |compiled| compiled,
        .rejected => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqual(@as(?u32, 0), both_compiled.chunk.parameter_direct_eval_plan);
    try std.testing.expectEqual(@as(usize, 2), both_compiled.chunk.direct_eval_plans.items.len);
    try std.testing.expectEqual(bc.DirectEvalScopeKind.parameter, both_compiled.chunk.direct_eval_plans.items[0].scopes[0].kind);
    const both_body_plan = both_compiled.chunk.direct_eval_plans.items[1];
    try std.testing.expectEqual(@as(usize, 2), both_body_plan.scopes.len);
    try std.testing.expectEqual(bc.DirectEvalScopeKind.parameter, both_body_plan.scopes[0].kind);
    try std.testing.expectEqual(bc.DirectEvalScopeKind.variable, both_body_plan.scopes[1].kind);
    try std.testing.expect(both_body_plan.scopes[1].declaration_target);

    var nested_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer nested_arena.deinit();
    var nested_parser = try @import("parser.zig").Parser.init(
        nested_arena.allocator(),
        "function f(value = (() => eval(\"'ok'\"))()){ var bodyOnly = 1; return value; }",
    );
    const nested_program = try nested_parser.parseProgram();
    const nested_compiled = switch (try Compiler.admitPlainFunction(nested_arena.allocator(), nested_program.program[0].func_decl)) {
        .compiled => |compiled| compiled,
        .rejected => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqual(@as(?u32, null), nested_compiled.chunk.parameter_direct_eval_plan);
    try std.testing.expectEqual(@as(usize, 1), nested_compiled.chunk.fns.items.len);
    const arrow_chunk = nested_compiled.chunk.fns.items[0].chunk orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 1), arrow_chunk.direct_eval_plans.items.len);
    const arrow_plan = arrow_chunk.direct_eval_plans.items[0];
    try std.testing.expectEqual(@as(usize, 2), arrow_plan.scopes.len);
    try std.testing.expectEqual(bc.DirectEvalScopeKind.parameter, arrow_plan.scopes[0].kind);
    try std.testing.expectEqual(@as(u32, 1), arrow_plan.scopes[0].frame_depth);
    try std.testing.expectEqual(bc.DirectEvalScopeKind.variable, arrow_plan.scopes[1].kind);
    try std.testing.expectEqual(@as(u32, 0), arrow_plan.scopes[1].frame_depth);
    try std.testing.expect(arrow_plan.scopes[1].declaration_target);
    for (arrow_plan.scopes) |plan_scope|
        for (plan_scope.bindings) |binding|
            try std.testing.expect(!std.mem.eql(u8, binding.name, "bodyOnly"));
}

test "compiler emits mixed destructuring rest at its ordered parameter entry" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parser = try @import("parser.zig").Parser.init(
        arena.allocator(),
        "function f(first = 1, ...[tail = (eval('var x = 2'), function(){ return x; })]) { return tail; }",
    );
    const program = try parser.parseProgram();
    const compiled = switch (try Compiler.admitPlainFunction(arena.allocator(), program.program[0].func_decl)) {
        .compiled => |code| code,
        .rejected => return error.TestUnexpectedResult,
    };

    try std.testing.expectEqual(@as(?u32, 1), compiled.chunk.rest_parameter_index);
    try std.testing.expectEqualSlices(u32, &.{0}, compiled.chunk.default_parameter_indices);
    try std.testing.expectEqualSlices(u32, &.{1}, compiled.chunk.destructuring_parameter_indices);
    try std.testing.expect(compiled.chunk.parameter_direct_eval_plan != null);
    var collect_index: ?usize = null;
    var iterator_index: ?usize = null;
    for (compiled.chunk.code.items, 0..) |instruction, index| switch (instruction.op) {
        .collect_rest_parameter => {
            try std.testing.expectEqual(compiled.chunk.parameter_slots[1], instruction.a);
            collect_index = index;
        },
        .iter_of => if (iterator_index == null) {
            iterator_index = index;
        },
        else => {},
    };
    try std.testing.expect(collect_index != null and iterator_index != null);
    try std.testing.expect(collect_index.? < iterator_index.?);

    const root = try Compiler.compileProgram(arena.allocator(), program);
    var template: ?*bc.FnTemplate = null;
    for (root.fns.items) |candidate| {
        if (std.mem.eql(u8, candidate.name, "f")) template = candidate;
    }
    const function_template = template orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(bc.FnTemplateAdmission.plain_compiled, function_template.admission);
    try std.testing.expect(function_template.chunk != null);
}

test "compiler admits direct eval methods and derived constructors" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parser = try @import("parser.zig").Parser.init(
        arena.allocator(),
        "class Base { method(value) { return value; } } class Derived extends Base { constructor(value) { eval('super(value)'); } method(value) { return eval('super.method(value)'); } }",
    );
    const program = try parser.parseProgram();
    const declaration = program.program[1];
    if (declaration.* != .var_decl or declaration.var_decl.init == null)
        return error.TestUnexpectedResult;
    const class = declaration.var_decl.init.?;
    if (class.* != .class_expr or class.class_expr.members.len != 2)
        return error.TestUnexpectedResult;

    for (class.class_expr.members, 0..) |member, index| {
        var function = (member.func orelse return error.TestUnexpectedResult).function.*;
        // Class evaluation synthesizes this flag on the executable constructor
        // node after resolving heritage; the parser member alone cannot know it.
        if (index == 0) function.is_derived_class_constructor = true;
        const compiled = switch (try Compiler.admitPlainFunction(arena.allocator(), &function)) {
            .compiled => |code| code,
            .rejected => return error.TestUnexpectedResult,
        };
        try std.testing.expectEqual(@as(usize, 1), compiled.chunk.direct_eval_plans.items.len);
        try std.testing.expectEqual(index == 0, compiled.chunk.is_derived_constructor);
    }
}

test "compiler plans live deferred class captures only for real frame references" {
    const admitted = [_][]const u8{
        "function f(seed){ class Box { constructor(value){ this.value = value; } read(){ return this.value; } } return new Box(seed).read(); }",
        "function f(seed){ class Box { [seed](){ return 7; } } return Box; }",
        "function f(){ while(false){ let seed=1; class Box { read(){ return seed; } } } return 7; }",
    };
    for (admitted) |source| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var parser = try @import("parser.zig").Parser.init(arena.allocator(), source);
        const program = try parser.parseProgram();
        switch (try Compiler.admitPlainFunction(arena.allocator(), program.program[0].func_decl)) {
            .compiled => |compiled| {
                try std.testing.expect(compiled.chunk.code.items.len != 0);
                for (compiled.chunk.classes.items) |template|
                    try std.testing.expect(template.capture_environment == null);
            },
            .rejected => return error.TestUnexpectedResult,
        }
    }

    const captured = [_][]const u8{
        "function f(seed){ class Box { read(){ return seed; } } return new Box().read(); }",
        "function f(seed){ class Box { field=seed; } return Box; }",
        "function f(seed){ class Box { static { seed; } } return Box; }",
    };
    for (captured) |source| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var parser = try @import("parser.zig").Parser.init(arena.allocator(), source);
        const program = try parser.parseProgram();
        switch (try Compiler.admitPlainFunction(arena.allocator(), program.program[0].func_decl)) {
            .compiled => |compiled| {
                try std.testing.expectEqual(@as(usize, 1), compiled.chunk.classes.items.len);
                const plan = compiled.chunk.classes.items[0].capture_environment.?;
                try std.testing.expectEqual(@as(u32, 1), plan.current_environment_depth);
                try std.testing.expectEqual(@as(usize, 0), plan.frame_boundaries.len);
                var seed_count: usize = 0;
                for (plan.scopes) |scope| for (scope.bindings) |binding| {
                    if (std.mem.eql(u8, binding.name, "seed")) {
                        seed_count += 1;
                        try std.testing.expectEqual(@as(u32, 0), scope.frame_depth);
                        try std.testing.expectEqual(@as(u32, 0), binding.slot);
                    }
                };
                try std.testing.expectEqual(@as(usize, 1), seed_count);
            },
            .rejected => return error.TestUnexpectedResult,
        }
    }

    var private_key_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer private_key_arena.deinit();
    var private_key_parser = try @import("parser.zig").Parser.init(
        private_key_arena.allocator(),
        "function f(){ class Box { #value; [globalThis.#value] = 1; } }",
    );
    const private_key_program = try private_key_parser.parseProgram();
    switch (try Compiler.admitPlainFunction(private_key_arena.allocator(), private_key_program.program[0].func_decl)) {
        .compiled => |compiled| {
            var prepares: usize = 0;
            var private_reads: usize = 0;
            for (compiled.chunk.code.items) |instruction| switch (instruction.op) {
                .prepare_class_private_environment => prepares += 1,
                .get_private_name => private_reads += 1,
                else => {},
            };
            try std.testing.expectEqual(@as(usize, 1), prepares);
            try std.testing.expectEqual(@as(usize, 1), private_reads);
        },
        .rejected => return error.TestUnexpectedResult,
    }
}

test "compiler deferred class capture plans unwind every allocation failure" {
    const Probe = struct {
        fn run(backing: std.mem.Allocator) !void {
            var arena = std.heap.ArenaAllocator.init(backing);
            defer arena.deinit();
            var parser = try @import("parser.zig").Parser.init(arena.allocator(),
                \\function outer(seed) {
                \\  let kept = seed;
                \\  return function inner(step) {
                \\    with ({tag: step}) {
                \\      let near = step;
                \\      return class Box {
                \\        field = kept;
                \\        static { seed += 1; }
                \\        read() { return seed + kept + near + tag; }
                \\      };
                \\    }
                \\  };
                \\}
            );
            const program = try parser.parseProgram();
            switch (try Compiler.admitPlainFunction(arena.allocator(), program.program[0].func_decl)) {
                .compiled => |compiled| {
                    const nested = compiled.chunk.fns.items[0].chunk.?;
                    const plan = nested.classes.items[0].capture_environment.?;
                    try std.testing.expectEqual(@as(usize, 1), plan.frame_boundaries.len);
                    try std.testing.expectEqual(@as(u32, 2), plan.current_environment_depth);
                },
                .rejected => return error.TestUnexpectedResult,
            }
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Probe.run, .{});
}

test "class key conversion lowering survives compiler allocation failures" {
    const Probe = struct {
        fn run(backing: std.mem.Allocator) !void {
            var ast_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
            defer ast_arena.deinit();
            var parser = try @import("parser.zig").Parser.init(ast_arena.allocator(), "function make(first,second){return class{[first()](){}[second()](){}};}");
            const program = try parser.parseProgram();
            var replay = CompilerAllocationReplay{ .backing = backing };
            var arena = std.heap.ArenaAllocator.init(replay.allocator());
            defer arena.deinit();
            const compiled = try Compiler.compilePlainFunction(arena.allocator(), program.program[0].func_decl);
            var conversions: usize = 0;
            for (compiled.chunk.code.items, 0..) |instruction, index| {
                if (instruction.op != .to_property_key) continue;
                conversions += 1;
                try std.testing.expect(index > 0);
                try std.testing.expectEqual(bc.Op.call, compiled.chunk.code.items[index - 1].op);
            }
            try std.testing.expectEqual(@as(usize, 2), conversions);
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Probe.run, .{});
}

test "class naming carries immutable inputs through compiler allocation failures" {
    const Probe = struct {
        fn run(backing: std.mem.Allocator) !void {
            var arena = std.heap.ArenaAllocator.init(backing);
            defer arena.deinit();
            const allocator = arena.allocator();
            var parser = try @import("parser.zig").Parser.init(allocator, "function named(C=class{static seen=this.name;}){return C;} function computed(k,Base){return {[k]:class extends Base{[k](){}static seen=this.name;}};} function* suspended(k){return {[k]:class extends (yield Object){[yield k](){}static seen=this.name;}};}");
            const program = try parser.parseProgram();
            for (program.program, 0..) |statement, index| {
                const function = statement.func_decl;
                const chunk = if (function.is_generator)
                    try Compiler.compileGenerator(allocator, function, false)
                else
                    (try Compiler.compilePlainFunction(allocator, function)).chunk;
                try std.testing.expectEqual(@as(usize, 1), chunk.classes.items.len);
                const template = chunk.classes.items[0];
                try std.testing.expectEqual(index != 0, template.name_from_stack);
                if (index == 0) try std.testing.expectEqualStrings("C", template.inferred_name.?);
                var class_instructions: usize = 0;
                for (chunk.code.items) |instruction| {
                    if (instruction.op == .eval_class) {
                        class_instructions += 1;
                        try std.testing.expectEqual(@as(u32, if (index == 0) 0 else 4), instruction.b);
                    }
                    try std.testing.expect(instruction.op != .name_anon);
                }
                try std.testing.expectEqual(@as(usize, 1), class_instructions);
            }
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Probe.run, .{});
}

test "compiler lowers prepared class heritage across bytecode tiers" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parser = try @import("parser.zig").Parser.init(
        arena.allocator(),
        "var ProgramClass = class ProgramNamed extends ProgramBase {}; function plain(Base){ return class Named extends Base { [key()](){} }; } function shadow(Named){ return class Named extends Named { static self(){ return Named; } }; } function* generated(Base){ return class Generated extends (yield Base) { [yield \"key\"](){} }; } async function awaited(Base){ return class Awaited extends (await Base) { [await key()](){} }; } async function* asyncGenerated(Base){ return class AsyncGenerated extends (yield Base) {}; }",
    );
    const program = try parser.parseProgram();
    try std.testing.expectEqual(@as(usize, 6), program.program.len);

    const program_chunk = switch (try Compiler.admitProgram(arena.allocator(), program)) {
        .compiled => |chunk| chunk,
        .rejected => return error.TestUnexpectedResult,
    };
    var program_prepares: usize = 0;
    for (program_chunk.code.items) |instruction| {
        if (instruction.op == .prepare_class_heritage) {
            program_prepares += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 1), program_prepares);

    const plain = switch (try Compiler.admitPlainFunction(arena.allocator(), program.program[1].func_decl)) {
        .compiled => |compiled| compiled.chunk,
        .rejected => return error.TestUnexpectedResult,
    };
    const shadow = switch (try Compiler.admitPlainFunction(arena.allocator(), program.program[2].func_decl)) {
        .compiled => |compiled| compiled.chunk,
        .rejected => return error.TestUnexpectedResult,
    };
    const generated = switch (try Compiler.admitGenerator(arena.allocator(), program.program[3].func_decl, true)) {
        .compiled => |chunk| chunk,
        .rejected => return error.TestUnexpectedResult,
    };
    const awaited = switch (try Compiler.admitAsync(arena.allocator(), program.program[4].func_decl, true)) {
        .compiled => |chunk| chunk,
        .rejected => return error.TestUnexpectedResult,
    };
    const async_generated = switch (try Compiler.admitGenerator(arena.allocator(), program.program[5].func_decl, true)) {
        .compiled => |chunk| chunk,
        .rejected => return error.TestUnexpectedResult,
    };

    for ([_]*Chunk{ program_chunk, plain, shadow, generated, awaited, async_generated }) |chunk| {
        var class_phase: u8 = 0;
        for (chunk.code.items) |instruction| switch (instruction.op) {
            .enter_block => if (instruction.a != 0) {
                try std.testing.expectEqual(@as(u8, 0), class_phase);
                class_phase = 1;
            },
            .prepare_class_heritage => {
                try std.testing.expectEqual(@as(u8, 1), class_phase);
                class_phase = 2;
            },
            .eval_class => {
                try std.testing.expectEqual(@as(u8, 2), class_phase);
                try std.testing.expect(instruction.b >= 2);
                class_phase = 3;
            },
            .exit_block => if (instruction.a != 0) {
                try std.testing.expectEqual(@as(u8, 3), class_phase);
                class_phase = 4;
            },
            else => {},
        };
        try std.testing.expectEqual(@as(u8, 4), class_phase);
    }

    // The inner class binding, not the same-spelled parameter, resolves while
    // heritage is evaluated and therefore observes the class TDZ at runtime.
    var shadow_loads_environment = false;
    for (shadow.code.items) |instruction| if (instruction.op == .load_var) {
        if (std.mem.eql(u8, shadow.names.items[instruction.a], "Named")) shadow_loads_environment = true;
    };
    try std.testing.expect(shadow_loads_environment);
}

test "compiler admits captured super assignments and updates" {
    const cases = [_]struct { source: []const u8, set_op: bc.Op }{
        .{ .source = "class Derived extends Base { method(){ return super.value = 1; } }", .set_op = .super_set_from },
        .{ .source = "class Derived extends Base { method(){ return super[key()] = 1; } }", .set_op = .super_set_index_from },
        .{ .source = "class Derived extends Base { method(){ return super.value ??= 1; } }", .set_op = .super_set_from },
        .{ .source = "class Derived extends Base { method(){ return super.value &&= 1; } }", .set_op = .super_set_from },
        .{ .source = "class Derived extends Base { method(){ return super.value ||= 1; } }", .set_op = .super_set_from },
        .{ .source = "class Derived extends Base { method(){ return super[key()] += 1; } }", .set_op = .super_set_index_from },
        .{ .source = "class Derived extends Base { method(){ return super.value -= 1; } }", .set_op = .super_set_from },
        .{ .source = "class Derived extends Base { method(){ return super.value *= 1; } }", .set_op = .super_set_from },
        .{ .source = "class Derived extends Base { method(){ return super.value /= 1; } }", .set_op = .super_set_from },
        .{ .source = "class Derived extends Base { method(){ return super.value %= 1; } }", .set_op = .super_set_from },
        .{ .source = "class Derived extends Base { method(){ return super.value **= 1; } }", .set_op = .super_set_from },
        .{ .source = "class Derived extends Base { method(){ return super.value &= 1; } }", .set_op = .super_set_from },
        .{ .source = "class Derived extends Base { method(){ return super.value |= 1; } }", .set_op = .super_set_from },
        .{ .source = "class Derived extends Base { method(){ return super.value ^= 1; } }", .set_op = .super_set_from },
        .{ .source = "class Derived extends Base { method(){ return super.value <<= 1; } }", .set_op = .super_set_from },
        .{ .source = "class Derived extends Base { method(){ return super.value >>= 1; } }", .set_op = .super_set_from },
        .{ .source = "class Derived extends Base { method(){ return super.value >>>= 1; } }", .set_op = .super_set_from },
        .{ .source = "class Derived extends Base { method(){ return super.value++; } }", .set_op = .super_set_from },
    };
    for (cases) |case| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var parser = try @import("parser.zig").Parser.init(arena.allocator(), case.source);
        const program = try parser.parseProgram();
        const declaration = program.program[0];
        if (declaration.* != .var_decl or declaration.var_decl.init == null)
            return error.TestUnexpectedResult;
        const class = declaration.var_decl.init.?;
        if (class.* != .class_expr or class.class_expr.members.len != 1 or class.class_expr.members[0].func == null)
            return error.TestUnexpectedResult;
        const method = class.class_expr.members[0].func.?;
        if (method.* != .function) return error.TestUnexpectedResult;
        switch (try Compiler.admitPlainFunction(arena.allocator(), method.function)) {
            .compiled => |compiled| {
                var saw_set = false;
                for (compiled.chunk.code.items) |instruction|
                    saw_set = saw_set or instruction.op == case.set_op;
                try std.testing.expect(saw_set);
            },
            .rejected => return error.TestUnexpectedResult,
        }
    }
}

test "compiler admits computed and super tagged template references" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parser = try @import("parser.zig").Parser.init(
        arena.allocator(),
        "function tagged(holder, key, value){ \"use strict\"; return holder[key]`a${value}b`; }",
    );
    const program = try parser.parseProgram();
    const plain = switch (try Compiler.admitPlainFunction(arena.allocator(), program.program[0].func_decl)) {
        .compiled => |compiled| compiled.chunk,
        .rejected => return error.TestUnexpectedResult,
    };
    var saw_tail_member = false;
    for (plain.code.items) |inst| if (inst.op == .tail_call_with_this) {
        saw_tail_member = true;
    };
    try std.testing.expect(saw_tail_member);

    var class_parser = try @import("parser.zig").Parser.init(
        arena.allocator(),
        "class Derived extends Base { method(value){ \"use strict\"; return super.tag`a${value}b`; } *generated(){ return super[yield \"key\"]`g${yield \"value\"}z`; } async awaited(){ return super[await Promise.resolve(\"tag\")]`p${await Promise.resolve(1)}q`; } }",
    );
    const class_program = try class_parser.parseProgram();
    const declaration = class_program.program[0];
    if (declaration.* != .var_decl or declaration.var_decl.init == null)
        return error.TestUnexpectedResult;
    const class = declaration.var_decl.init.?;
    if (class.* != .class_expr or class.class_expr.members.len != 3)
        return error.TestUnexpectedResult;

    const method = class.class_expr.members[0].func orelse return error.TestUnexpectedResult;
    const method_chunk = switch (try Compiler.admitPlainFunction(arena.allocator(), method.function)) {
        .compiled => |compiled| compiled.chunk,
        .rejected => return error.TestUnexpectedResult,
    };
    var saw_tail_super = false;
    for (method_chunk.code.items) |inst| if (inst.op == .tail_call_with_this) {
        saw_tail_super = true;
    };
    try std.testing.expect(saw_tail_super);

    const generated = class.class_expr.members[1].func orelse return error.TestUnexpectedResult;
    switch (try Compiler.admitGenerator(arena.allocator(), generated.function, true)) {
        .compiled => |chunk| try std.testing.expect(chunk.code.items.len != 0),
        .rejected => return error.TestUnexpectedResult,
    }
    const awaited = class.class_expr.members[2].func orelse return error.TestUnexpectedResult;
    switch (try Compiler.admitAsync(arena.allocator(), awaited.function, true)) {
        .compiled => |chunk| try std.testing.expect(chunk.code.items.len != 0),
        .rejected => return error.TestUnexpectedResult,
    }
}

test "compiler lowers super calls in tail and receiver-aware spread positions" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parser = try @import("parser.zig").Parser.init(
        arena.allocator(),
        "class Derived extends Base { named(value){ return super.method(value); } computed(key, value){ return super[key](value); } *spread(args){ var value = super[\"method\"](...args); yield value; } *suspended(){ var value = super[yield \"key\"](yield \"argument\"); return value; } tailSpread(args){ return super.method(...args); } tailSpreadComputed(key, args){ return super[key](...args); } }",
    );
    const program = try parser.parseProgram();
    const declaration = program.program[0];
    if (declaration.* != .var_decl or declaration.var_decl.init == null)
        return error.TestUnexpectedResult;
    const class = declaration.var_decl.init.?;
    if (class.* != .class_expr or class.class_expr.members.len != 6)
        return error.TestUnexpectedResult;

    for (class.class_expr.members[0..2]) |member| {
        const method = member.func orelse return error.TestUnexpectedResult;
        const chunk = switch (try Compiler.admitPlainFunction(arena.allocator(), method.function)) {
            .compiled => |compiled| compiled.chunk,
            .rejected => return error.TestUnexpectedResult,
        };
        var saw_super_tail = false;
        for (chunk.code.items) |inst| if (inst.op == .tail_call_with_this) {
            saw_super_tail = true;
        };
        try std.testing.expect(saw_super_tail);
    }

    const spread = class.class_expr.members[2].func orelse return error.TestUnexpectedResult;
    const spread_chunk = switch (try Compiler.admitGenerator(arena.allocator(), spread.function, true)) {
        .compiled => |chunk| chunk,
        .rejected => return error.TestUnexpectedResult,
    };
    var saw_receiver_spread = false;
    for (spread_chunk.code.items) |inst| if (inst.op == .call_with_this_spread) {
        saw_receiver_spread = true;
    };
    try std.testing.expect(saw_receiver_spread);

    const suspended = class.class_expr.members[3].func orelse return error.TestUnexpectedResult;
    switch (try Compiler.admitGenerator(arena.allocator(), suspended.function, true)) {
        .compiled => |chunk| try std.testing.expect(chunk.code.items.len != 0),
        .rejected => return error.TestUnexpectedResult,
    }

    for (class.class_expr.members[4..6]) |member| {
        const tail_spread = member.func orelse return error.TestUnexpectedResult;
        switch (try Compiler.admitPlainFunction(arena.allocator(), tail_spread.function)) {
            .compiled => |compiled| {
                var saw_tail_spread = false;
                for (compiled.chunk.code.items) |inst| if (inst.op == .tail_call_with_this_spread) {
                    saw_tail_spread = true;
                };
                try std.testing.expect(saw_tail_spread);
            },
            .rejected => return error.TestUnexpectedResult,
        }
    }
}

test "compiler lowers ordinary spread calls and constructors across tiers" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parser = try @import("parser.zig").Parser.init(
        arena.allocator(),
        "function plain(fn, holder, key, args){ var direct = fn(0, ...args, 3); var named = holder.method(...args); var computed = holder[key](...args); var constructed = new fn(...args); return direct + named + computed + constructed.value; } async function awaited(fn, holder, key, args){ var direct = fn(...await Promise.resolve(args)); var computed = holder[await Promise.resolve(key)](...args); var constructed = new fn(...args); return direct + computed + constructed.value; } function tail(args){ \"use strict\"; return tail(...args); } function evalBarrier(args){ var value = eval(...args); return value; } function optional(holder, args){ var value = holder.method?.(...args); return value; } class Derived extends Base { spread(args){ var value = super.method(...args); return value; } async awaited(args){ var value = super[await Promise.resolve(\"method\")](...args); return value; } }",
    );
    const program = try parser.parseProgram();
    if (program.program.len != 6) return error.TestUnexpectedResult;

    const plain = switch (try Compiler.admitPlainFunction(arena.allocator(), program.program[0].func_decl)) {
        .compiled => |compiled| compiled.chunk,
        .rejected => return error.TestUnexpectedResult,
    };
    var calls: usize = 0;
    var receiver_calls: usize = 0;
    var constructors: usize = 0;
    for (plain.code.items) |inst| switch (inst.op) {
        .call_spread => calls += 1,
        .call_with_this_spread => receiver_calls += 1,
        .new_spread => constructors += 1,
        else => {},
    };
    try std.testing.expectEqual(@as(usize, 1), calls);
    try std.testing.expectEqual(@as(usize, 2), receiver_calls);
    try std.testing.expectEqual(@as(usize, 1), constructors);

    const awaited = switch (try Compiler.admitAsync(arena.allocator(), program.program[1].func_decl, true)) {
        .compiled => |chunk| chunk,
        .rejected => return error.TestUnexpectedResult,
    };
    calls = 0;
    receiver_calls = 0;
    constructors = 0;
    for (awaited.code.items) |inst| switch (inst.op) {
        .call_spread => calls += 1,
        .call_with_this_spread => receiver_calls += 1,
        .new_spread => constructors += 1,
        else => {},
    };
    try std.testing.expectEqual(@as(usize, 1), calls);
    try std.testing.expectEqual(@as(usize, 1), receiver_calls);
    try std.testing.expectEqual(@as(usize, 1), constructors);

    const tail = switch (try Compiler.admitPlainFunction(arena.allocator(), program.program[2].func_decl)) {
        .compiled => |compiled| compiled.chunk,
        .rejected => return error.TestUnexpectedResult,
    };
    var saw_tail_spread = false;
    for (tail.code.items) |inst| if (inst.op == .tail_call_spread) {
        saw_tail_spread = true;
    };
    try std.testing.expect(saw_tail_spread);

    const eval_barrier = switch (try Compiler.admitPlainFunction(arena.allocator(), program.program[3].func_decl)) {
        .compiled => |compiled| compiled.chunk,
        .rejected => return error.TestUnexpectedResult,
    };
    var saw_eval_activation_spread = false;
    for (eval_barrier.code.items) |instruction|
        saw_eval_activation_spread = saw_eval_activation_spread or instruction.op == .call_eval_activation_spread;
    try std.testing.expect(saw_eval_activation_spread);

    const optional = switch (try Compiler.admitPlainFunction(arena.allocator(), program.program[4].func_decl)) {
        .compiled => |compiled| compiled.chunk,
        .rejected => return error.TestUnexpectedResult,
    };
    var saw_optional_receiver_spread = false;
    for (optional.code.items) |inst| if (inst.op == .call_with_this_spread) {
        saw_optional_receiver_spread = true;
    };
    try std.testing.expect(saw_optional_receiver_spread);

    const declaration = program.program[5];
    if (declaration.* != .var_decl or declaration.var_decl.init == null)
        return error.TestUnexpectedResult;
    const class = declaration.var_decl.init.?;
    if (class.* != .class_expr or class.class_expr.members.len != 2)
        return error.TestUnexpectedResult;
    const super_plain = class.class_expr.members[0].func orelse return error.TestUnexpectedResult;
    const super_plain_chunk = switch (try Compiler.admitPlainFunction(arena.allocator(), super_plain.function)) {
        .compiled => |compiled| compiled.chunk,
        .rejected => return error.TestUnexpectedResult,
    };
    var saw_plain_super_spread = false;
    for (super_plain_chunk.code.items) |inst| if (inst.op == .call_with_this_spread) {
        saw_plain_super_spread = true;
    };
    try std.testing.expect(saw_plain_super_spread);
    const super_async = class.class_expr.members[1].func orelse return error.TestUnexpectedResult;
    const super_async_chunk = switch (try Compiler.admitAsync(arena.allocator(), super_async.function, true)) {
        .compiled => |chunk| chunk,
        .rejected => return error.TestUnexpectedResult,
    };
    var saw_async_super_spread = false;
    for (super_async_chunk.code.items) |inst| if (inst.op == .call_with_this_spread) {
        saw_async_super_spread = true;
    };
    try std.testing.expect(saw_async_super_spread);

    var program_parser = try @import("parser.zig").Parser.init(
        arena.allocator(),
        "var spreadProgramResult = spreadProgramFn(1, ...spreadProgramArgs, 3); var spreadProgramConstructed = new spreadProgramFn(...spreadProgramArgs); var spreadProgramEval = eval(...spreadProgramEvalArgs);",
    );
    const spread_program = try program_parser.parseProgram();
    const program_chunk = switch (try Compiler.admitProgram(arena.allocator(), spread_program)) {
        .compiled => |chunk| chunk,
        .rejected => return error.TestUnexpectedResult,
    };
    var saw_program_call = false;
    var saw_program_eval = false;
    var saw_program_constructor = false;
    for (program_chunk.code.items) |inst| switch (inst.op) {
        .call_spread => saw_program_call = true,
        .call_eval_spread => saw_program_eval = true,
        .new_spread => saw_program_constructor = true,
        else => {},
    };
    try std.testing.expect(saw_program_call and saw_program_eval and saw_program_constructor);
}

test "compiler lowers proper tail calls with spread arguments across tiers" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parser = try @import("parser.zig").Parser.init(
        arena.allocator(),
        "function direct(fn, args){ \"use strict\"; return fn(0, ...args, 3); } function named(holder, args){ \"use strict\"; return holder.method(...args); } function computed(holder, key, args){ \"use strict\"; return holder[key](...args); } function optional(holder, args){ \"use strict\"; return holder?.method?.(...args); } function parenthesized(holder, args){ \"use strict\"; return (holder?.method)(...args); } function optionalEval(args){ \"use strict\"; return eval?.(...args); } function evalSpreadBarrier(args){ \"use strict\"; var local = 1; return eval(...args); } function evalFixedBarrier(){ \"use strict\"; var local = 1; return eval(\"local\"); } function* generated(fn, args){ \"use strict\"; yield 0; return fn(...args); } function* generatedEval(args){ \"use strict\"; yield 0; return eval(...args); } async function awaited(fn, args){ \"use strict\"; await 0; return fn(...args); } async function* asyncGenerated(fn, args){ \"use strict\"; yield 0; return fn(...args); } function sloppy(fn, args){ return fn(...args); }",
    );
    const program = try parser.parseProgram();
    try std.testing.expectEqual(@as(usize, 13), program.program.len);

    for (program.program[0..6], 0..) |declaration, index| {
        const chunk = switch (try Compiler.admitPlainFunction(arena.allocator(), declaration.func_decl)) {
            .compiled => |compiled| compiled.chunk,
            .rejected => return error.TestUnexpectedResult,
        };
        const expected: bc.Op = if (index == 0 or index == 5) .tail_call_spread else .tail_call_with_this_spread;
        var saw_expected = false;
        for (chunk.code.items) |inst| if (inst.op == expected) {
            saw_expected = true;
        };
        try std.testing.expect(saw_expected);
    }

    // Activation-aware tail opcodes retain the retiring frame for direct eval;
    // fixed and spread forms therefore remain proper-tail-call eligible.
    for (program.program[6..8], 0..) |declaration, index| {
        const chunk = switch (try Compiler.admitPlainFunction(arena.allocator(), declaration.func_decl)) {
            .compiled => |compiled| compiled.chunk,
            .rejected => return error.TestUnexpectedResult,
        };
        const expected: bc.Op = if (index == 0) .tail_call_eval_activation_spread else .tail_call_eval_activation;
        var saw_expected = false;
        for (chunk.code.items) |instruction|
            saw_expected = saw_expected or instruction.op == expected;
        try std.testing.expect(saw_expected);
    }

    const generated = switch (try Compiler.admitGenerator(arena.allocator(), program.program[8].func_decl, true)) {
        .compiled => |chunk| chunk,
        .rejected => return error.TestUnexpectedResult,
    };
    const generated_eval = switch (try Compiler.admitGenerator(arena.allocator(), program.program[9].func_decl, true)) {
        .compiled => |chunk| chunk,
        .rejected => return error.TestUnexpectedResult,
    };
    const awaited = switch (try Compiler.admitAsync(arena.allocator(), program.program[10].func_decl, true)) {
        .compiled => |chunk| chunk,
        .rejected => return error.TestUnexpectedResult,
    };
    const async_generated = switch (try Compiler.admitGenerator(arena.allocator(), program.program[11].func_decl, true)) {
        .compiled => |chunk| chunk,
        .rejected => return error.TestUnexpectedResult,
    };
    var concise_parser = try @import("parser.zig").Parser.init(
        arena.allocator(),
        "var concise = async (fn, args) => fn(...args);",
    );
    const concise_program = try concise_parser.parseModule();
    const concise_node = concise_program.program[0].var_decl.init orelse return error.TestUnexpectedResult;
    if (concise_node.* != .function) return error.TestUnexpectedResult;
    try std.testing.expect(concise_node.function.is_strict and concise_node.function.is_expr_body);
    const concise = switch (try Compiler.admitAsync(arena.allocator(), concise_node.function, true)) {
        .compiled => |chunk| chunk,
        .rejected => return error.TestUnexpectedResult,
    };
    // ECMA-262 §15.10.1 IsInTailPosition, steps 4-7, excludes generator,
    // async-function, async-generator, and async concise bodies. Their return
    // wrappers keep ordinary spread operations even for a strict
    // return-position call.
    for ([_]*Chunk{ generated, awaited, async_generated, concise }) |chunk| {
        var saw_ordinary_spread = false;
        for (chunk.code.items) |inst| switch (inst.op) {
            .call_spread => saw_ordinary_spread = true,
            .tail_call_spread => return error.TestUnexpectedResult,
            else => {},
        };
        try std.testing.expect(saw_ordinary_spread);
    }
    var saw_eval_spread = false;
    for (generated_eval.code.items) |inst| switch (inst.op) {
        .call_eval_spread => saw_eval_spread = true,
        .tail_call_spread => return error.TestUnexpectedResult,
        else => {},
    };
    try std.testing.expect(saw_eval_spread);

    const sloppy = switch (try Compiler.admitPlainFunction(arena.allocator(), program.program[12].func_decl)) {
        .compiled => |compiled| compiled.chunk,
        .rejected => return error.TestUnexpectedResult,
    };
    var saw_ordinary_spread = false;
    var saw_return = false;
    for (sloppy.code.items) |inst| switch (inst.op) {
        .call_spread => saw_ordinary_spread = true,
        .ret => saw_return = true,
        .tail_call_spread => return error.TestUnexpectedResult,
        else => {},
    };
    try std.testing.expect(saw_ordinary_spread and saw_return);
}

test "compiler lowers optional chains across bytecode tiers" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parser = try @import("parser.zig").Parser.init(
        arena.allocator(),
        "function plain(holder, key, args){ var read = holder?.[key]?.value; var called = holder?.method?.(...args); return read ?? called; } function tail(holder){ \"use strict\"; return holder?.method?.(); } function tailSpread(holder, args){ \"use strict\"; return holder?.method?.(...args); } function* generated(holder){ return holder?.[yield \"key\"]?.(yield \"argument\")?.value; } async function awaited(holder){ return holder?.[await Promise.resolve(\"method\")]?.(await Promise.resolve(1))?.value; }",
    );
    const program = try parser.parseProgram();
    if (program.program.len != 5) return error.TestUnexpectedResult;

    const plain = switch (try Compiler.admitPlainFunction(arena.allocator(), program.program[0].func_decl)) {
        .compiled => |compiled| compiled.chunk,
        .rejected => return error.TestUnexpectedResult,
    };
    var nullish_exits: usize = 0;
    var receiver_spreads: usize = 0;
    for (plain.code.items) |inst| switch (inst.op) {
        .jump_if_nullish_peek => nullish_exits += 1,
        .call_with_this_spread => receiver_spreads += 1,
        else => {},
    };
    try std.testing.expectEqual(@as(usize, 4), nullish_exits);
    try std.testing.expectEqual(@as(usize, 1), receiver_spreads);

    const tail = switch (try Compiler.admitPlainFunction(arena.allocator(), program.program[1].func_decl)) {
        .compiled => |compiled| compiled.chunk,
        .rejected => return error.TestUnexpectedResult,
    };
    var saw_tail_call = false;
    var saw_short_return = false;
    for (tail.code.items) |inst| switch (inst.op) {
        .tail_call_with_this => saw_tail_call = true,
        .ret_undef => saw_short_return = true,
        else => {},
    };
    try std.testing.expect(saw_tail_call and saw_short_return);

    switch (try Compiler.admitPlainFunction(arena.allocator(), program.program[2].func_decl)) {
        .compiled => |compiled| {
            var saw_tail_spread = false;
            var saw_optional_short_return = false;
            for (compiled.chunk.code.items) |inst| switch (inst.op) {
                .tail_call_with_this_spread => saw_tail_spread = true,
                .ret_undef => saw_optional_short_return = true,
                else => {},
            };
            try std.testing.expect(saw_tail_spread and saw_optional_short_return);
        },
        .rejected => return error.TestUnexpectedResult,
    }
    switch (try Compiler.admitGenerator(arena.allocator(), program.program[3].func_decl, true)) {
        .compiled => |chunk| try std.testing.expect(chunk.code.items.len != 0),
        .rejected => return error.TestUnexpectedResult,
    }
    switch (try Compiler.admitAsync(arena.allocator(), program.program[4].func_decl, true)) {
        .compiled => |chunk| try std.testing.expect(chunk.code.items.len != 0),
        .rejected => return error.TestUnexpectedResult,
    }

    var program_parser = try @import("parser.zig").Parser.init(
        arena.allocator(),
        "var optionalProgram = optionalProgramHolder?.method?.(1)?.value;",
    );
    const optional_program = try program_parser.parseProgram();
    switch (try Compiler.admitProgram(arena.allocator(), optional_program)) {
        .compiled => |chunk| try std.testing.expect(chunk.code.items.len != 0),
        .rejected => return error.TestUnexpectedResult,
    }
}

test "compiler lowers owned for-in enumeration across bytecode tiers" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parser = try @import("parser.zig").Parser.init(
        arena.allocator(),
        "function plain(object, holder){ var out = ''; for (var key in object) out += key; for (holder.key in object) break; for (const [first] in object) out += first; return out; } function* generated(object){ for (let key in object) yield key; } async function awaited(object){ var out = ''; for (const key in object) { await 0; out += key; } return out; }",
    );
    const program = try parser.parseProgram();
    try std.testing.expectEqual(@as(usize, 3), program.program.len);

    const plain = switch (try Compiler.admitPlainFunction(arena.allocator(), program.program[0].func_decl)) {
        .compiled => |compiled| compiled.chunk,
        .rejected => return error.TestUnexpectedResult,
    };
    const generated = switch (try Compiler.admitGenerator(arena.allocator(), program.program[1].func_decl, true)) {
        .compiled => |chunk| chunk,
        .rejected => return error.TestUnexpectedResult,
    };
    const awaited = switch (try Compiler.admitAsync(arena.allocator(), program.program[2].func_decl, true)) {
        .compiled => |chunk| chunk,
        .rejected => return error.TestUnexpectedResult,
    };
    for ([_]*Chunk{ plain, generated, awaited }) |chunk| {
        var snapshots: usize = 0;
        var live_checks: usize = 0;
        for (chunk.code.items) |instruction| switch (instruction.op) {
            .enum_keys => snapshots += 1,
            .enum_next => live_checks += 1,
            else => {},
        };
        try std.testing.expect(snapshots > 0);
        try std.testing.expectEqual(snapshots, live_checks);
    }

    var program_parser = try @import("parser.zig").Parser.init(
        arena.allocator(),
        "var forInProgram = '', holder = {}; for (var key in forInProgramObject) forInProgram += key; for (const [first] in forInProgramObject) forInProgram += first; for (holder.key in forInProgramObject) break;",
    );
    const program_node = try program_parser.parseProgram();
    const program_chunk = switch (try Compiler.admitProgram(arena.allocator(), program_node)) {
        .compiled => |chunk| chunk,
        .rejected => return error.TestUnexpectedResult,
    };
    var saw_program_snapshot = false;
    var saw_program_live_check = false;
    for (program_chunk.code.items) |instruction| switch (instruction.op) {
        .enum_keys => saw_program_snapshot = true,
        .enum_next => saw_program_live_check = true,
        else => {},
    };
    try std.testing.expect(saw_program_snapshot and saw_program_live_check);
    try std.testing.expect(program_chunk.scratch_count > 0);
}

test "compiler lowers property deletion across bytecode tiers" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parser = try @import("parser.zig").Parser.init(
        arena.allocator(),
        "function plain(holder, key){ var named = delete holder.value; var computed = delete holder[key]; var optional = delete holder?.[key]?.value; var terminated = delete (holder?.value).nested; var nonref = delete sideEffect(); return named && computed && optional && terminated && nonref; } function* generated(holder){ \"use strict\"; return delete holder?.[yield \"key\"]; } async function awaited(holder){ \"use strict\"; return delete holder?.[await getKey()]; } function binding(name){ return delete name; } class Derived extends Base { method(){ return delete super.value; } computed(){ return delete super[yieldKey()]; } }",
    );
    const program = try parser.parseProgram();
    if (program.program.len != 5) return error.TestUnexpectedResult;

    const plain = switch (try Compiler.admitPlainFunction(arena.allocator(), program.program[0].func_decl)) {
        .compiled => |compiled| compiled.chunk,
        .rejected => return error.TestUnexpectedResult,
    };
    var named_deletes: usize = 0;
    var computed_deletes: usize = 0;
    var optional_exits: usize = 0;
    for (plain.code.items) |inst| switch (inst.op) {
        .delete_prop => named_deletes += 1,
        .delete_index => computed_deletes += 1,
        .jump_if_nullish_peek => optional_exits += 1,
        else => {},
    };
    try std.testing.expectEqual(@as(usize, 3), named_deletes);
    try std.testing.expectEqual(@as(usize, 1), computed_deletes);
    try std.testing.expect(optional_exits >= 2);

    const generated = switch (try Compiler.admitGenerator(arena.allocator(), program.program[1].func_decl, true)) {
        .compiled => |chunk| chunk,
        .rejected => return error.TestUnexpectedResult,
    };
    var saw_generator_delete = false;
    for (generated.code.items) |inst| if (inst.op == .delete_index) {
        saw_generator_delete = true;
        try std.testing.expectEqual(@as(u32, 1), inst.a);
    };
    try std.testing.expect(saw_generator_delete);

    const awaited = switch (try Compiler.admitAsync(arena.allocator(), program.program[2].func_decl, true)) {
        .compiled => |chunk| chunk,
        .rejected => return error.TestUnexpectedResult,
    };
    var saw_async_delete = false;
    for (awaited.code.items) |inst| if (inst.op == .delete_index) {
        saw_async_delete = true;
        try std.testing.expectEqual(@as(u32, 1), inst.a);
    };
    try std.testing.expect(saw_async_delete);

    const binding = switch (try Compiler.admitPlainFunction(arena.allocator(), program.program[3].func_decl)) {
        .compiled => |compiled| compiled.chunk,
        .rejected => return error.TestUnexpectedResult,
    };
    var saw_local_false = false;
    for (binding.code.items) |inst| switch (inst.op) {
        .load_false => saw_local_false = true,
        .delete_name => return error.TestUnexpectedResult,
        else => {},
    };
    try std.testing.expect(saw_local_false);
    const declaration = program.program[4];
    if (declaration.* != .var_decl or declaration.var_decl.init == null)
        return error.TestUnexpectedResult;
    const class = declaration.var_decl.init.?;
    if (class.* != .class_expr or class.class_expr.members.len != 2)
        return error.TestUnexpectedResult;
    for (class.class_expr.members) |member| {
        const method = member.func orelse return error.TestUnexpectedResult;
        switch (try Compiler.admitPlainFunction(arena.allocator(), method.function)) {
            .compiled => |compiled| {
                var saw_super_delete = false;
                for (compiled.chunk.code.items) |inst| {
                    if (inst.op == .delete_super) saw_super_delete = true;
                }
                try std.testing.expect(saw_super_delete);
            },
            .rejected => return error.TestUnexpectedResult,
        }
    }

    var program_parser = try @import("parser.zig").Parser.init(
        arena.allocator(),
        "\"use strict\"; var deleteProgramHolder = { value: 1 }; var deleteProgramResult = delete deleteProgramHolder.value;",
    );
    const delete_program = try program_parser.parseProgram();
    switch (try Compiler.admitProgram(arena.allocator(), delete_program)) {
        .compiled => |chunk| {
            var saw_program_delete = false;
            for (chunk.code.items) |inst| if (inst.op == .delete_prop) {
                saw_program_delete = true;
                try std.testing.expectEqual(@as(u32, 1), inst.b);
            };
            try std.testing.expect(saw_program_delete);
        },
        .rejected => return error.TestUnexpectedResult,
    }
}

test "compiler gives arguments owners precise frame slots" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parser = try @import("parser.zig").Parser.init(
        arena.allocator(),
        "function own(value){ \"use strict\"; return arguments[0] + arguments.length; } function outer(value){ \"use strict\"; var ownLength = arguments.length; var arrow = () => arguments[0]; function inner(other){ \"use strict\"; return arguments[0]; } return ownLength + arrow() + inner(value); } var holder = { method(value){ \"use strict\"; return arguments[0]; } }; function Constructor(value){ \"use strict\"; this.value = arguments[0]; } function sloppy(value){ value = arguments[0] + 1; arguments[0] = value + 1; return value + arguments[0]; } function legacyOnly(value){ return value + 1; } function sloppyOuter(value){ var arrow = () => { value = value + 1; return value + arguments[0]; }; return arrow(); } function parameterArguments(arguments){ arguments = arguments + 1; return arguments; } function evalOwner(){ \"use strict\"; return eval(\"arguments[0]\"); } function evalReference(){ \"use strict\"; return eval; }",
    );
    const program = try parser.parseProgram();
    const chunk = switch (try Compiler.admitProgram(arena.allocator(), program)) {
        .compiled => |compiled| compiled,
        .rejected => return error.TestUnexpectedResult,
    };

    const Helper = struct {
        fn named(owner: *Chunk, name: []const u8) ?*bc.FnTemplate {
            for (owner.fns.items) |template| if (std.mem.eql(u8, template.name, name)) return template;
            return null;
        }

        fn expectOwnArguments(template: *bc.FnTemplate) !u32 {
            const compiled = template.chunk orelse return error.TestUnexpectedResult;
            const slot = compiled.arguments_slot orelse return error.TestUnexpectedResult;
            try std.testing.expectEqual(compiled.param_count, slot);
            try std.testing.expect(slot < compiled.local_count);
            try std.testing.expectEqualStrings("arguments", compiled.debug_local_names[slot]);
            var saw_load = false;
            for (compiled.code.items) |instruction| {
                if (instruction.op == .load_local and instruction.a == slot) saw_load = true;
            }
            try std.testing.expect(saw_load);
            return slot;
        }
    };

    _ = try Helper.expectOwnArguments(Helper.named(chunk, "own") orelse return error.TestUnexpectedResult);
    _ = try Helper.expectOwnArguments(Helper.named(chunk, "method") orelse return error.TestUnexpectedResult);
    _ = try Helper.expectOwnArguments(Helper.named(chunk, "Constructor") orelse return error.TestUnexpectedResult);

    const outer_template = Helper.named(chunk, "outer") orelse return error.TestUnexpectedResult;
    const outer_slot = try Helper.expectOwnArguments(outer_template);
    const outer_chunk = outer_template.chunk.?;
    const inner_template = Helper.named(outer_chunk, "inner") orelse return error.TestUnexpectedResult;
    _ = try Helper.expectOwnArguments(inner_template);

    var arrow_template: ?*bc.FnTemplate = null;
    for (outer_chunk.fns.items) |template| if (template.is_arrow) {
        arrow_template = template;
        break;
    };
    const arrow_chunk = (arrow_template orelse return error.TestUnexpectedResult).chunk orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(?u32, null), arrow_chunk.arguments_slot);
    var saw_outer_arguments = false;
    for (arrow_chunk.code.items) |instruction| {
        if (instruction.op == .load_upval and instruction.a == 1 and instruction.b == outer_slot)
            saw_outer_arguments = true;
    }
    try std.testing.expect(saw_outer_arguments);

    const sloppy = Helper.named(chunk, "sloppy") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(bc.FnTemplateAdmission.plain_compiled, sloppy.admission);
    const sloppy_chunk = sloppy.chunk orelse return error.TestUnexpectedResult;
    const sloppy_arguments_slot = sloppy_chunk.arguments_slot orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(sloppy_chunk.local_count, sloppy_chunk.mapped_parameter_indices.len);
    try std.testing.expectEqual(@as(u32, 0), sloppy_chunk.mapped_parameter_indices[0]);
    try std.testing.expectEqual(std.math.maxInt(u32), sloppy_chunk.mapped_parameter_indices[sloppy_arguments_slot]);
    var saw_mapped_load = false;
    var saw_mapped_store = false;
    for (sloppy_chunk.code.items) |instruction| switch (instruction.op) {
        .load_local_mapped => saw_mapped_load = true,
        .store_local_mapped => saw_mapped_store = true,
        else => {},
    };
    try std.testing.expect(saw_mapped_load and saw_mapped_store);

    // Annex B may materialize this function's arguments through
    // `legacyOnly.arguments` in a nested observer even though its own body does
    // not mention `arguments`. Retain the map metadata without making every
    // ordinary parameter access pay the eager mapped-object opcode cost.
    const legacy_only = Helper.named(chunk, "legacyOnly") orelse return error.TestUnexpectedResult;
    const legacy_only_chunk = legacy_only.chunk orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(?u32, null), legacy_only_chunk.arguments_slot);
    try std.testing.expectEqual(legacy_only_chunk.local_count, legacy_only_chunk.mapped_parameter_indices.len);
    try std.testing.expectEqual(@as(u32, 0), legacy_only_chunk.mapped_parameter_indices[0]);
    var saw_plain_parameter_load = false;
    for (legacy_only_chunk.code.items) |instruction| switch (instruction.op) {
        .load_local => saw_plain_parameter_load = saw_plain_parameter_load or instruction.a == 0,
        .load_local_mapped, .store_local_mapped => return error.TestUnexpectedResult,
        else => {},
    };
    try std.testing.expect(saw_plain_parameter_load);

    const sloppy_outer = Helper.named(chunk, "sloppyOuter") orelse return error.TestUnexpectedResult;
    const sloppy_outer_chunk = sloppy_outer.chunk orelse return error.TestUnexpectedResult;
    var sloppy_arrow: ?*bc.FnTemplate = null;
    for (sloppy_outer_chunk.fns.items) |template| if (template.is_arrow) {
        sloppy_arrow = template;
        break;
    };
    const sloppy_arrow_chunk = (sloppy_arrow orelse return error.TestUnexpectedResult).chunk orelse return error.TestUnexpectedResult;
    var saw_mapped_upvalue_load = false;
    var saw_mapped_upvalue_store = false;
    for (sloppy_arrow_chunk.code.items) |instruction| switch (instruction.op) {
        .load_upval_mapped => saw_mapped_upvalue_load = true,
        .store_upval_mapped => saw_mapped_upvalue_store = true,
        else => {},
    };
    try std.testing.expect(saw_mapped_upvalue_load and saw_mapped_upvalue_store);

    const parameter_arguments = Helper.named(chunk, "parameterArguments") orelse return error.TestUnexpectedResult;
    const parameter_arguments_chunk = parameter_arguments.chunk orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(?u32, null), parameter_arguments_chunk.arguments_slot);
    try std.testing.expectEqual(parameter_arguments_chunk.local_count, parameter_arguments_chunk.mapped_parameter_indices.len);
    try std.testing.expectEqual(@as(u32, 0), parameter_arguments_chunk.mapped_parameter_indices[0]);
    for (parameter_arguments_chunk.code.items) |instruction|
        if (instruction.op == .load_local_mapped or instruction.op == .store_local_mapped)
            return error.TestUnexpectedResult;

    const eval_owner = Helper.named(chunk, "evalOwner") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(bc.FnTemplateAdmission.plain_compiled, eval_owner.admission);
    try std.testing.expect(eval_owner.uses_direct_eval);
    try std.testing.expect(!eval_owner.uses_arguments);
    const eval_owner_chunk = eval_owner.chunk orelse return error.TestUnexpectedResult;
    const eval_arguments_slot = eval_owner_chunk.arguments_slot orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(eval_owner_chunk.param_count, eval_arguments_slot);
    try std.testing.expectEqualStrings("arguments", eval_owner_chunk.debug_local_names[eval_arguments_slot]);
    try std.testing.expectEqual(@as(usize, 1), eval_owner_chunk.direct_eval_plans.items.len);
    var saw_eval_activation = false;
    for (eval_owner_chunk.code.items) |instruction|
        saw_eval_activation = saw_eval_activation or instruction.op == .tail_call_eval_activation;
    try std.testing.expect(saw_eval_activation);

    const eval_reference = Helper.named(chunk, "evalReference") orelse return error.TestUnexpectedResult;
    try std.testing.expect(!eval_reference.uses_direct_eval);
    try std.testing.expect(!eval_reference.uses_arguments);
    try std.testing.expectEqual(@as(?u32, null), eval_reference.chunk.?.arguments_slot);
}

test "compiler bounds identifier deletion before frame bindings" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parser = try @import("parser.zig").Parser.init(
        arena.allocator(),
        "function* generated(name){ yield 0; return delete name; } async function awaited(name){ await 0; return delete name; } function outer(name, holder){ var nested; with (holder) { nested = function(){ return delete name; }; } return nested; } function deepOuter(name, first){ var middle; with (first) { middle = function(second){ var nested; with (second) { nested = function(){ return delete name; }; } return nested; }; } return middle; } delete missingGlobalName;",
    );
    const program = try parser.parseProgram();
    try std.testing.expectEqual(@as(usize, 5), program.program.len);

    const generated = switch (try Compiler.admitGenerator(arena.allocator(), program.program[0].func_decl, true)) {
        .compiled => |chunk| chunk,
        .rejected => return error.TestUnexpectedResult,
    };
    const awaited = switch (try Compiler.admitAsync(arena.allocator(), program.program[1].func_decl, true)) {
        .compiled => |chunk| chunk,
        .rejected => return error.TestUnexpectedResult,
    };
    for ([_]*Chunk{ generated, awaited }) |chunk| {
        var saw_full_delete = false;
        for (chunk.code.items) |inst| if (inst.op == .delete_name) {
            saw_full_delete = true;
            try std.testing.expectEqual(bc.delete_name_full_environment_depth, inst.b);
        };
        try std.testing.expect(saw_full_delete);
    }

    const outer = switch (try Compiler.admitPlainFunction(arena.allocator(), program.program[2].func_decl)) {
        .compiled => |compiled| compiled.chunk,
        .rejected => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqual(@as(usize, 1), outer.fns.items.len);
    const nested = outer.fns.items[0].chunk orelse return error.TestUnexpectedResult;
    var saw_bounded_delete = false;
    for (nested.code.items) |inst| if (inst.op == .delete_name) {
        saw_bounded_delete = true;
        try std.testing.expectEqual(@as(u32, 1), inst.b);
    };
    try std.testing.expect(saw_bounded_delete);

    const deep_outer = switch (try Compiler.admitPlainFunction(arena.allocator(), program.program[3].func_decl)) {
        .compiled => |compiled| compiled.chunk,
        .rejected => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqual(@as(usize, 1), deep_outer.fns.items.len);
    const middle = deep_outer.fns.items[0].chunk orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 1), middle.fns.items.len);
    const deep_nested = middle.fns.items[0].chunk orelse return error.TestUnexpectedResult;
    var saw_deep_bounded_delete = false;
    for (deep_nested.code.items) |inst| if (inst.op == .delete_name) {
        saw_deep_bounded_delete = true;
        try std.testing.expectEqual(@as(u32, 2), inst.b);
    };
    try std.testing.expect(saw_deep_bounded_delete);

    const compiled_program = switch (try Compiler.admitProgram(arena.allocator(), program)) {
        .compiled => |chunk| chunk,
        .rejected => return error.TestUnexpectedResult,
    };
    var saw_program_delete = false;
    for (compiled_program.code.items) |inst| if (inst.op == .delete_name) {
        saw_program_delete = true;
        try std.testing.expectEqual(bc.delete_name_full_environment_depth, inst.b);
    };
    try std.testing.expect(saw_program_delete);

    var arguments_parser = try @import("parser.zig").Parser.init(
        arena.allocator(),
        "function plainArguments(){ return delete arguments; }",
    );
    const arguments_program = try arguments_parser.parseProgram();
    switch (try Compiler.admitPlainFunction(arena.allocator(), arguments_program.program[0].func_decl)) {
        .compiled => |compiled| {
            var saw_local_false = false;
            for (compiled.chunk.code.items) |inst| switch (inst.op) {
                .load_false => saw_local_false = true,
                .delete_name => return error.TestUnexpectedResult,
                else => {},
            };
            try std.testing.expect(saw_local_false);
        },
        .rejected => return error.TestUnexpectedResult,
    }
}

test "compiler lowers with identifier references without perturbing direct slots" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parser = try @import("parser.zig").Parser.init(
        arena.allocator(),
        "function direct(fn, value){ var local = value; local = local + 1; local += 2; local &&= 3; local++; var called = fn(); return local + called; } function dynamic(fn, object){ var local = 1, result; with (object) { result = local + fn(); local += 1; local ||= 2; local++; } return result + local; } function outer(object){ var local = 1, nested; with (object) { nested = function(){ return local; }; } return nested; }",
    );
    const program = try parser.parseProgram();
    try std.testing.expectEqual(@as(usize, 3), program.program.len);

    const direct = switch (try Compiler.admitPlainFunction(arena.allocator(), program.program[0].func_decl)) {
        .compiled => |compiled| compiled.chunk,
        .rejected => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqual(@as(usize, 0), direct.binding_reference_plans.items.len);
    for (direct.code.items) |instruction| switch (instruction.op) {
        .resolve_binding_ref, .load_binding_ref, .clear_binding_ref, .store_binding_ref => return error.TestUnexpectedResult,
        else => {},
    };

    const dynamic = switch (try Compiler.admitPlainFunction(arena.allocator(), program.program[1].func_decl)) {
        .compiled => |compiled| compiled.chunk,
        .rejected => return error.TestUnexpectedResult,
    };
    try std.testing.expect(dynamic.binding_reference_plans.items.len > 0);
    var saw_resolve = false;
    var saw_load = false;
    var saw_clear = false;
    var saw_store = false;
    var saw_call_with_this = false;
    for (dynamic.code.items) |instruction| switch (instruction.op) {
        .resolve_binding_ref => saw_resolve = true,
        .load_binding_ref => saw_load = true,
        .clear_binding_ref => saw_clear = true,
        .store_binding_ref => saw_store = true,
        .call_with_this => saw_call_with_this = true,
        else => {},
    };
    try std.testing.expect(saw_resolve);
    try std.testing.expect(saw_load);
    try std.testing.expect(saw_clear);
    try std.testing.expect(saw_store);
    try std.testing.expect(saw_call_with_this);

    const outer = switch (try Compiler.admitPlainFunction(arena.allocator(), program.program[2].func_decl)) {
        .compiled => |compiled| compiled.chunk,
        .rejected => return error.TestUnexpectedResult,
    };
    const nested = outer.fns.items[0].chunk orelse return error.TestUnexpectedResult;
    try std.testing.expect(nested.binding_reference_plans.items.len > 0);
    for (nested.binding_reference_plans.items) |plan|
        try std.testing.expectEqual(@as(u32, 1), plan.environment_depth);
}

test "compiler lowers import.meta across module function tiers" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parser = try @import("parser.zig").Parser.init(
        arena.allocator(),
        "export function plain(){ return import.meta; } export function* generated(){ yield import.meta; return import.meta; } export async function awaited(){ await 0; return import.meta; }",
    );
    const program = try parser.parseModule();
    try std.testing.expectEqual(@as(usize, 3), program.program.len);

    const functions = try arena.allocator().alloc(*const ast.FunctionNode, program.program.len);
    for (program.program, functions) |item, *function| {
        if (item.* != .export_decl) return error.TestUnexpectedResult;
        const declaration = item.export_decl.declaration orelse return error.TestUnexpectedResult;
        if (declaration.* != .func_decl) return error.TestUnexpectedResult;
        function.* = declaration.func_decl;
    }

    const plain = switch (try Compiler.admitPlainFunction(arena.allocator(), functions[0])) {
        .compiled => |compiled| compiled.chunk,
        .rejected => return error.TestUnexpectedResult,
    };
    const generated = switch (try Compiler.admitGenerator(arena.allocator(), functions[1], true)) {
        .compiled => |chunk| chunk,
        .rejected => return error.TestUnexpectedResult,
    };
    const awaited = switch (try Compiler.admitAsync(arena.allocator(), functions[2], true)) {
        .compiled => |chunk| chunk,
        .rejected => return error.TestUnexpectedResult,
    };

    for ([_]*Chunk{ plain, generated, awaited }) |chunk| {
        var import_meta_loads: usize = 0;
        for (chunk.code.items) |instruction|
            if (instruction.op == .load_import_meta) {
                import_meta_loads += 1;
            };
        try std.testing.expect(import_meta_loads > 0);
    }
}

test "compiler lowers plain-function destructuring assignments without bind_pattern" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parser = try @import("parser.zig").Parser.init(
        arena.allocator(),
        "function assign(source, holder){ let first, nested, tail, result; result = ([first, { value: nested = 3, ...holder.rest }, ...tail] = source); return result === source ? first + nested + tail.length : -1; }",
    );
    const program = try parser.parseProgram();
    const compiled = switch (try Compiler.admitPlainFunction(arena.allocator(), program.program[0].func_decl)) {
        .compiled => |result| result,
        .rejected => return error.TestUnexpectedResult,
    };

    var saw_iterator = false;
    var saw_object_rest = false;
    var saw_frame_store = false;
    for (compiled.chunk.code.items) |instruction| switch (instruction.op) {
        .bind_pattern => return error.TestUnexpectedResult,
        .iter_of => saw_iterator = true,
        .object_rest => saw_object_rest = true,
        .store_local, .store_local_lexical => saw_frame_store = true,
        else => {},
    };
    try std.testing.expect(saw_iterator);
    try std.testing.expect(saw_object_rest);
    try std.testing.expect(saw_frame_store);

    var closure_parser = try @import("parser.zig").Parser.init(
        arena.allocator(),
        "function outer(source){ let captured; function assign(){ ([captured, globalTarget] = source); } return assign; }",
    );
    const closure_program = try closure_parser.parseProgram();
    const closure_compiled = switch (try Compiler.admitPlainFunction(arena.allocator(), closure_program.program[0].func_decl)) {
        .compiled => |result| result,
        .rejected => return error.TestUnexpectedResult,
    };
    var saw_upvalue_store = false;
    var saw_global_store = false;
    for (closure_compiled.chunk.fns.items) |template| if (template.chunk) |chunk| {
        for (chunk.code.items) |instruction| switch (instruction.op) {
            .bind_pattern => return error.TestUnexpectedResult,
            .store_upval, .store_upval_lexical => saw_upvalue_store = true,
            .store_var, .store_binding_ref => saw_global_store = true,
            else => {},
        };
    };
    try std.testing.expect(saw_upvalue_store);
    try std.testing.expect(saw_global_store);

    var with_parser = try @import("parser.zig").Parser.init(
        arena.allocator(),
        "function assign(source, object){ with (object) { ([value] = source); } }",
    );
    const with_program = try with_parser.parseProgram();
    switch (try Compiler.admitPlainFunction(arena.allocator(), with_program.program[0].func_decl)) {
        .compiled => |result| {
            try std.testing.expect(result.chunk.binding_reference_plans.items.len > 0);
            var saw_resolve = false;
            var saw_store = false;
            for (result.chunk.code.items) |instruction| switch (instruction.op) {
                .resolve_binding_ref => saw_resolve = true,
                .store_binding_ref => saw_store = true,
                .bind_pattern => return error.TestUnexpectedResult,
                else => {},
            };
            try std.testing.expect(saw_resolve and saw_store);
        },
        .rejected => return error.TestUnexpectedResult,
    }
}

test "compiler lowers plain-function destructuring declarations without bind_pattern" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parser = try @import("parser.zig").Parser.init(
        arena.allocator(),
        "function declare(source){ var [first, { value: nested = 3, ...rest }, ...tail] = source; { let { extra: lexical = fixed } = rest; const [fixed] = tail; return first + nested + lexical + fixed; } }",
    );
    const program = try parser.parseProgram();
    const compiled = switch (try Compiler.admitPlainFunction(arena.allocator(), program.program[0].func_decl)) {
        .compiled => |result| result,
        .rejected => return error.TestUnexpectedResult,
    };

    var saw_iterator = false;
    var saw_object_rest = false;
    var saw_frame_store = false;
    var saw_lexical_init = false;
    for (compiled.chunk.code.items) |instruction| switch (instruction.op) {
        .bind_pattern => return error.TestUnexpectedResult,
        .iter_of => saw_iterator = true,
        .object_rest => saw_object_rest = true,
        .store_local, .store_local_lexical, .store_local_mapped => saw_frame_store = true,
        .init_local_lexical => saw_lexical_init = true,
        else => {},
    };
    try std.testing.expect(saw_iterator);
    try std.testing.expect(saw_object_rest);
    try std.testing.expect(saw_frame_store);
    try std.testing.expect(saw_lexical_init);

    var loop_parser = try @import("parser.zig").Parser.init(
        arena.allocator(),
        "function loop(values){ for (var [first, second] of values) {} return first + second; }",
    );
    const loop_program = try loop_parser.parseProgram();
    const loop_compiled = switch (try Compiler.admitPlainFunction(arena.allocator(), loop_program.program[0].func_decl)) {
        .compiled => |result| result,
        .rejected => return error.TestUnexpectedResult,
    };
    try std.testing.expect(loop_compiled.local_count >= 3);
    for (loop_compiled.chunk.code.items) |instruction|
        if (instruction.op == .bind_pattern) return error.TestUnexpectedResult;

    var with_parser = try @import("parser.zig").Parser.init(
        arena.allocator(),
        "function declare(source, object){ with (object) { var [value] = source; } }",
    );
    const with_program = try with_parser.parseProgram();
    switch (try Compiler.admitPlainFunction(arena.allocator(), with_program.program[0].func_decl)) {
        .compiled => |result| {
            try std.testing.expect(result.chunk.binding_reference_plans.items.len > 0);
            var saw_resolve = false;
            var saw_store = false;
            for (result.chunk.code.items) |instruction| switch (instruction.op) {
                .resolve_binding_ref => saw_resolve = true,
                .store_binding_ref => saw_store = true,
                .bind_pattern => return error.TestUnexpectedResult,
                else => {},
            };
            try std.testing.expect(saw_resolve and saw_store);
        },
        .rejected => return error.TestUnexpectedResult,
    }
}

test "compiler keeps for-of protocol state in activation-owned slots" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var parser = try @import("parser.zig").Parser.init(
        arena.allocator(),
        "function consume(values){ let total=0; for (const value of values) total += value; return total; }",
    );
    const program = try parser.parseProgram();
    const compiled = switch (try Compiler.admitPlainFunction(arena.allocator(), program.program[0].func_decl)) {
        .compiled => |code| code,
        .rejected => return error.TestUnexpectedResult,
    };

    var saw_iterator = false;
    var local_loads: usize = 0;
    var local_stores: usize = 0;
    for (compiled.chunk.code.items) |instruction| switch (instruction.op) {
        .iter_of => saw_iterator = true,
        .load_local, .load_local_lexical => local_loads += 1,
        .store_local, .store_local_lexical => local_stores += 1,
        .load_var, .store_var, .def_var, .def_lex => {
            const name = compiled.chunk.names.items[instruction.a];
            try std.testing.expect(!std.mem.startsWith(u8, name, "\x00ys"));
        },
        else => {},
    };
    try std.testing.expect(saw_iterator);
    try std.testing.expect(local_loads > 0 and local_stores > 0);
    // parameter + total + loop binding + iterator/next/result/close state.
    try std.testing.expect(compiled.chunk.local_count >= 7);
}

test "compiler reports stable program admission reasons" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var invalid_parser = try @import("parser.zig").Parser.init(arena.allocator(), "1;");
    const invalid_program = try invalid_parser.parseProgram();
    switch (try Compiler.admitProgram(arena.allocator(), invalid_program.program[0])) {
        .compiled => return error.TestUnexpectedResult,
        .rejected => |reason| try std.testing.expectEqual(Compiler.ProgramRejection.invalid_root, reason),
    }

    // Member references at top level lower through #706 activation-local
    // scratch: every admitted program using them must declare scratch slots
    // and move temporaries through the dedicated opcodes.
    const scratch_sources = [_][]const u8{
        "var holder = { value: 1 }; holder.value += 1;",
        "var holder = {}; holder.value++;",
        "var holder = { key: 2 }; holder[holder.key] ??= 3;",
        "for (const value of [1, 2]) { value; }",
    };
    for (scratch_sources) |source| {
        var scratch_parser = try @import("parser.zig").Parser.init(arena.allocator(), source);
        const scratch_program = try scratch_parser.parseProgram();
        const chunk = switch (try Compiler.admitProgram(arena.allocator(), scratch_program)) {
            .compiled => |compiled| compiled,
            .rejected => return error.TestUnexpectedResult,
        };
        try std.testing.expect(chunk.scratch_count > 0);
        var stores: usize = 0;
        var loads: usize = 0;
        for (chunk.code.items) |instruction| switch (instruction.op) {
            .scratch_store => stores += 1,
            .scratch_load => loads += 1,
            else => {},
        };
        try std.testing.expect(stores > 0 and loads > 0);
    }

    // Explicit disposal is admitted only with both registration and
    // completion-preserving cleanup in the published bytecode.
    var disposal_parser = try @import("parser.zig").Parser.init(arena.allocator(), "for (using x of []) break;");
    const disposal_program = try disposal_parser.parseProgram();
    const disposal_chunk = switch (try Compiler.admitProgram(arena.allocator(), disposal_program)) {
        .compiled => |chunk| chunk,
        .rejected => return error.TestUnexpectedResult,
    };
    var registers_disposable = false;
    var disposes_completion = false;
    for (disposal_chunk.code.items) |instruction| switch (instruction.op) {
        .register_disposable => registers_disposable = true,
        .dispose_scope_completion => disposes_completion = true,
        else => {},
    };
    try std.testing.expect(registers_disposable and disposes_completion);

    var compiled_parser = try @import("parser.zig").Parser.init(arena.allocator(), "null ?? 1;");
    const compiled_program = try compiled_parser.parseProgram();
    switch (try Compiler.admitProgram(arena.allocator(), compiled_program)) {
        .compiled => |chunk| try std.testing.expect(chunk.code.items.len != 0),
        .rejected => return error.TestUnexpectedResult,
    }
}

test "compiler reports stable generator admission reasons" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var invalid_parser = try @import("parser.zig").Parser.init(arena.allocator(), "function* invalid(){}");
    const invalid_program = try invalid_parser.parseProgram();
    const invalid = invalid_program.program[0].func_decl;
    invalid.is_expr_body = true;
    switch (try Compiler.admitGenerator(arena.allocator(), invalid, true)) {
        .compiled => return error.TestUnexpectedResult,
        .rejected => |reason| try std.testing.expectEqual(Compiler.GeneratorRejection.expression_body, reason),
    }

    var disposal_parser = try @import("parser.zig").Parser.init(arena.allocator(), "function* disposal(){ for (using x of []) break; }");
    const disposal_program = try disposal_parser.parseProgram();
    const disposal_chunk = switch (try Compiler.admitGenerator(arena.allocator(), disposal_program.program[0].func_decl, true)) {
        .compiled => |chunk| chunk,
        .rejected => return error.TestUnexpectedResult,
    };
    var registers_disposable = false;
    var disposes_completion = false;
    for (disposal_chunk.code.items) |instruction| switch (instruction.op) {
        .register_disposable => registers_disposable = true,
        .dispose_scope_completion => disposes_completion = true,
        else => {},
    };
    try std.testing.expect(registers_disposable and disposes_completion);

    var compiled_parser = try @import("parser.zig").Parser.init(arena.allocator(), "function* compiled(){ var holder = { value: 1 }; return holder[yield \"key\"]++; }");
    const compiled_program = try compiled_parser.parseProgram();
    switch (try Compiler.admitGenerator(arena.allocator(), compiled_program.program[0].func_decl, true)) {
        .compiled => |chunk| try std.testing.expect(chunk.code.items.len != 0),
        .rejected => return error.TestUnexpectedResult,
    }
}

test "compiler reports stable async admission reasons" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var generator_parser = try @import("parser.zig").Parser.init(arena.allocator(), "async function* invalid(){}");
    const generator_program = try generator_parser.parseProgram();
    switch (try Compiler.admitAsync(arena.allocator(), generator_program.program[0].func_decl, true)) {
        .compiled => return error.TestUnexpectedResult,
        .rejected => |reason| try std.testing.expectEqual(Compiler.AsyncRejection.async_generator, reason),
    }

    var disposal_parser = try @import("parser.zig").Parser.init(arena.allocator(), "async function disposal(){ for (using x of []) break; }");
    const disposal_program = try disposal_parser.parseProgram();
    const disposal_chunk = switch (try Compiler.admitAsync(arena.allocator(), disposal_program.program[0].func_decl, true)) {
        .compiled => |chunk| chunk,
        .rejected => return error.TestUnexpectedResult,
    };
    var registers_disposable = false;
    var disposes_completion = false;
    for (disposal_chunk.code.items) |instruction| switch (instruction.op) {
        .register_disposable => registers_disposable = true,
        .dispose_scope_completion => disposes_completion = true,
        else => {},
    };
    try std.testing.expect(registers_disposable and disposes_completion);

    var compiled_parser = try @import("parser.zig").Parser.init(arena.allocator(), "async function compiled(){ var holder = { value: 1 }; return ++holder[await Promise.resolve(\"value\")]; }");
    const compiled_program = try compiled_parser.parseProgram();
    switch (try Compiler.admitAsync(arena.allocator(), compiled_program.program[0].func_decl, true)) {
        .compiled => |chunk| try std.testing.expect(chunk.code.items.len != 0),
        .rejected => return error.TestUnexpectedResult,
    }
}
