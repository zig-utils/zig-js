//! Portable optimizer lowering plus the first executable backend.
//!
//! `lower` consumes optimizer SSA, not bytecode, and produces a small virtual-
//! register program. Backends consume that program. The first AArch64 backend
//! handles straight-line Number parameters/constants, arithmetic, comparisons,
//! and primitive returns; unsupported control/effects reject before publication.

const std = @import("std");
const builtin = @import("builtin");
const bc = @import("../bytecode.zig");
const jit = @import("../jit.zig");
const optimizer = @import("optimizer.zig");
const aarch64 = @import("aarch64.zig");
const Value = @import("../value.zig").Value;
const moving_safepoint_backedge_interval: u32 = 32;

pub const OperationKind = enum {
    copy,
    argument,
    constant,
    add,
    sub,
    mul,
    div,
    lt,
    le,
    gt,
    ge,
    eq,
    neq,
    runtime_operation,
};

pub const Operation = struct {
    kind: OperationKind,
    destination: u8,
    block: u32,
    lhs: u8 = 0,
    rhs: u8 = 0,
    immediate: u64 = 0,
};

const CopyPair = struct {
    destination: u8,
    source: u8,
};

pub const BranchSelection = struct {
    condition: u8,
    false_result: u8,
    true_result: u8,
    false_block: u32,
    true_block: u32,
};

pub const SideExitBranch = struct {
    condition: u8,
    entry_deopt_index: ?u16 = null,
    false_deopt_index: u16,
    true_deopt_index: u16,
    false_steps: u12,
    true_steps: u12,
    backedge_steps: u12 = 0,
    loop_prefix_steps: u12 = 0,
    true_block: ?u32 = null,
};

pub const SideExit = struct {
    deopt_index: u16,
    steps: u12,
};

pub const LoopBranch = struct {
    entry_block: u32,
    condition: u8,
    false_block: u32,
    true_block: u32,
    /// Shared join, or null when both arms independently backedge.
    merge_block: ?u32,
    /// Emit the shared join in each selected arm. False when the join is the
    /// next branch entry and therefore executes once after the machine join.
    emit_merge: bool,
    terminal: bool,
    false_steps: u12,
    true_steps: u12,
};

pub const LoopExitGuard = struct {
    entry_block: u32,
    condition: u8,
    exit_block: u32,
    exit_from: u32,
    exit_on_true: bool,
    exit_deopt_index: u16 = 0,
    exit_steps: u12,
};

pub const LoopLatchGuard = struct {
    entry_block: u32,
    condition: u8,
    latch_block: u32,
    latch_from: u32,
    operations_block: u32,
    backedge_on_true: bool,
    backedge_steps: u12,
};

pub const LoopRegionTargetKind = enum(u8) { block, header, exit };

pub const LoopRegionTarget = struct {
    kind: LoopRegionTargetKind,
    block: u32,
    operations_block: u32 = optimizer.Block.none,
    deopt_index: u16 = 0,
    moving_safepoint: bool = false,
    safepoint_deopt_index: u16 = 0,
};

pub const LoopRegionBlock = struct {
    block: u32,
    condition: u8 = 0,
    successor_count: u8,
    steps: u12,
    entry_deopt_index: u16 = 0,
    successors: [2]LoopRegionTarget = @splat(.{ .kind = .block, .block = optimizer.Block.none }),
};

pub const Program = struct {
    allocator: std.mem.Allocator,
    operations: []Operation,
    result: u8,
    branch: ?BranchSelection,
    side_exit: ?SideExit,
    side_exit_branch: ?SideExitBranch,
    loop_exit_guards: []LoopExitGuard = &.{},
    loop_latch_guards: []LoopLatchGuard = &.{},
    loop_branches: []LoopBranch = &.{},
    loop_region_blocks: []LoopRegionBlock = &.{},
    loop_region_entry_operations_block: u32 = optimizer.Block.none,
    loop_region_header_steps: u12 = 0,
    loop_region_dynamic_checks: bool = false,
    scratch_slots: u8,
    frame_slots: u32,
    required_numeric_slots: u64,
    bytecode_steps: u32,
    deopt_points: []jit.DeoptPoint,
    deopt_values: []jit.RecoveryValue,
    deopt_handlers: []jit.RecoveryHandler,
    stack_maps: []jit.StackMap,
    native_operations: []jit.NativeOperationDescriptor = &.{},
    native_exceptional_targets: []jit.NativeExceptionalTarget = &.{},
    native_operation_names: []?[]const u8 = &.{},
    osr: ?*jit.OsrMetadata = null,
    execution_block: u32 = 0,
    entry_enabled: bool = true,
    observe_loop_backedges: bool = false,
    deterministic_path: bool = false,

    pub fn deinit(self: *Program) void {
        self.allocator.free(self.operations);
        self.allocator.free(self.deopt_points);
        self.allocator.free(self.deopt_values);
        self.allocator.free(self.deopt_handlers);
        self.allocator.free(self.stack_maps);
        if (self.native_operations.len != 0) self.allocator.free(self.native_operations);
        if (self.native_exceptional_targets.len != 0) self.allocator.free(self.native_exceptional_targets);
        if (self.native_operation_names.len != 0) self.allocator.free(self.native_operation_names);
        if (self.loop_exit_guards.len != 0) self.allocator.free(self.loop_exit_guards);
        if (self.loop_latch_guards.len != 0) self.allocator.free(self.loop_latch_guards);
        if (self.loop_branches.len != 0) self.allocator.free(self.loop_branches);
        if (self.loop_region_blocks.len != 0) self.allocator.free(self.loop_region_blocks);
        if (self.osr) |metadata| metadata.destroy();
        self.* = undefined;
    }
};

/// Build the exact interpreter-to-SSA import contract for every reachable loop
/// header. This is deliberately separate from executable lowering so an
/// unsupported backend can reject publication without losing OSR state.
pub fn buildOsrMetadata(plan: *const optimizer.Plan, allocator: std.mem.Allocator) !*jit.OsrMetadata {
    const graph = &plan.graph;
    var entries: std.ArrayListUnmanaged(jit.OsrEntry) = .empty;
    defer entries.deinit(allocator);
    var imports: std.ArrayListUnmanaged(jit.OsrImport) = .empty;
    defer imports.deinit(allocator);

    for (plan.blocks) |header| {
        var has_backedge = false;
        for (graph.edges) |edge| if (edge.to == header.id and edge.from != optimizer.Block.none) {
            const predecessor = plan.blocks[edge.from];
            if (predecessor.start >= header.start) {
                has_backedge = true;
                break;
            }
        };
        if (!has_backedge) continue;

        const state = blockEntryState(graph.frame_states, header.id) orelse return error.UnsupportedChunk;
        const first_import: u32 = @intCast(imports.items.len);
        const first: usize = state.first_value;
        const count: usize = state.local_count + state.stack_count;
        if (first > graph.frame_state_values.len or count > graph.frame_state_values.len - first)
            return error.UnsupportedChunk;
        for (graph.frame_state_values[first .. first + count], 0..) |value, index| {
            if (value >= graph.nodes.len) return error.UnsupportedChunk;
            const node = graph.nodes[value];
            if (node.kind != .block_argument or node.block != header.id or value >= jit.numeric_scratch_capacity)
                return error.UnsupportedChunk;
            try imports.append(allocator, .{
                .source = if (index < state.local_count) .frame_slot else .stack_slot,
                .source_index = @intCast(if (index < state.local_count) index else index - state.local_count),
                .destination = @intCast(value),
            });
        }
        try entries.append(allocator, .{
            .entry_ip = state.origin,
            .first_import = first_import,
            .local_count = std.math.cast(u16, state.local_count) orelse return error.UnsupportedChunk,
            .stack_count = std.math.cast(u16, state.stack_count) orelse return error.UnsupportedChunk,
            .accumulator_bits = Value.undef().rawBits(),
        });
    }
    return jit.OsrMetadata.create(allocator, entries.items, imports.items);
}

fn selectLoopOsrMetadata(
    plan: *const optimizer.Plan,
    allocator: std.mem.Allocator,
    outermost: bool,
) !*jit.OsrMetadata {
    const available = try buildOsrMetadata(plan, allocator);
    defer available.destroy();
    if (available.entries.len == 0) return error.UnsupportedChunk;

    // One artifact owns one native loop region. Prefer the last bytecode loop
    // header, which is the innermost header for ordinary structured nesting,
    // and publish only that exact entry. Other backedges miss the table and
    // remain in bytecode instead of entering a region compiled for a different
    // header.
    const selected = available.entries[if (outermost) 0 else available.entries.len - 1];
    const selected_first: usize = selected.first_import;
    const selected_count: usize = @as(usize, selected.local_count) + selected.stack_count;
    if (selected_first > available.imports.len or selected_count > available.imports.len - selected_first)
        return error.UnsupportedChunk;
    const selected_entry = jit.OsrEntry{
        .entry_ip = selected.entry_ip,
        .first_import = 0,
        .local_count = selected.local_count,
        .stack_count = selected.stack_count,
        .handler_count = selected.handler_count,
        .accumulator_bits = selected.accumulator_bits,
    };
    return jit.OsrMetadata.create(
        allocator,
        &.{selected_entry},
        available.imports[selected_first .. selected_first + selected_count],
    );
}

const ValueType = enum { number, boolean, other };

fn stageNativeOperationDescriptors(
    chunk: *const bc.Chunk,
    plan: *const optimizer.Plan,
    graph: *const optimizer.ValueGraph,
    aliases: [jit.numeric_scratch_capacity]optimizer.ValueId,
    allocator: std.mem.Allocator,
    operations: *std.ArrayListUnmanaged(Operation),
    scratch_slots: *usize,
) ![]jit.NativeOperationDescriptor {
    var descriptors: std.ArrayListUnmanaged(jit.NativeOperationDescriptor) = .empty;
    errdefer descriptors.deinit(allocator);
    var previous_runtime_steps: u32 = 0;
    for (graph.frame_states, 0..) |state, state_index| {
        if (state.kind != .call and state.kind != .effect) continue;
        if (state.origin >= chunk.code.items.len) return error.UnsupportedChunk;
        const inst = chunk.code.items[state.origin];
        const input_count = optimizer.nativeOperationInputCount(inst) orelse return error.UnsupportedChunk;
        if (input_count > state.stack_count) return error.UnsupportedChunk;
        const stack_start: usize = state.first_value + state.local_count;
        const source_start = stack_start + state.stack_count - input_count;
        var exceptional_target: u16 = jit.NativeOperationDescriptor.none;
        for (graph.exceptional_targets, 0..) |target, index| {
            if (target.block == state.block and target.origin == state.origin) {
                if (exceptional_target != jit.NativeOperationDescriptor.none) return error.UnsupportedChunk;
                exceptional_target = std.math.cast(u16, index) orelse return error.UnsupportedChunk;
            }
        }
        var runtime_operation: ?*Operation = null;
        for (operations.items) |*operation| {
            if (operation.kind != .runtime_operation or operation.block != state.block or
                operation.immediate != state.origin) continue;
            if (runtime_operation != null) return error.UnsupportedChunk;
            runtime_operation = operation;
        }
        const first_input: usize = if (runtime_operation) |operation| runtime: {
            if (inst.op == .to_numeric or inst.op == .neg or inst.op == .pos or inst.op == .not or
                inst.op == .typeof_op or inst.op == .inc or inst.op == .dec or inst.op == .bit_not or
                inst.op == .to_string or inst.op == .to_property_key or inst.op == .get_prop or
                inst.op == .private_in)
            {
                if (input_count != 1) return error.UnsupportedChunk;
                const source = try resolveAlias(graph.frame_state_values[source_start], aliases);
                if (source != operation.lhs) return error.UnsupportedChunk;
                break :runtime source;
            }
            if ((inst.op == .get_index or inst.op == .set_prop or inst.op == .pow or
                inst.op == .bit_and or inst.op == .bit_or or inst.op == .bit_xor or
                inst.op == .shl or inst.op == .shr or inst.op == .ushr or inst.op == .in_op or
                inst.op == .instance_of) and input_count == 2) break :runtime operation.lhs;
            if (inst.op == .set_index and input_count == 3) break :runtime operation.lhs;
            if (inst.op == .call or inst.op == .call_with_this or inst.op == .new_call) {
                const receiver_words: u32 = if (inst.op == .call_with_this) 2 else 1;
                const expected = std.math.add(u32, inst.a, receiver_words) catch return error.UnsupportedChunk;
                if (input_count == expected) break :runtime operation.lhs;
            }
            return error.UnsupportedChunk;
        } else staged: {
            if (scratch_slots.* + input_count > jit.numeric_scratch_capacity) return error.UnsupportedChunk;
            const first = scratch_slots.*;
            for (0..input_count) |input| {
                const source = try resolveAlias(graph.frame_state_values[source_start + input], aliases);
                try operations.append(allocator, .{
                    .kind = .copy,
                    .destination = @intCast(scratch_slots.*),
                    .block = state.block,
                    .lhs = @intCast(source),
                });
                scratch_slots.* += 1;
            }
            break :staged first;
        };
        var step_delta: u16 = 0;
        if (runtime_operation != null) {
            const block = plan.blocks[state.block];
            const absolute_steps = try deterministicPrefixSteps(
                plan,
                state.block,
                state.origin - block.start + 1,
            );
            if (absolute_steps <= previous_runtime_steps) return error.UnsupportedChunk;
            step_delta = std.math.cast(u16, absolute_steps - previous_runtime_steps) orelse
                return error.UnsupportedChunk;
            previous_runtime_steps = absolute_steps;
        }
        const descriptor_index = std.math.cast(u32, descriptors.items.len) orelse return error.UnsupportedChunk;
        try descriptors.append(allocator, .{
            .bytecode_op = std.math.cast(u16, @backingInt(inst.op)) orelse return error.UnsupportedChunk,
            .first_input = @intCast(first_input),
            .input_count = @intCast(input_count),
            .exceptional_target = exceptional_target,
            .deopt_index = std.math.cast(u16, state_index) orelse return error.UnsupportedChunk,
            .step_delta = step_delta,
            .origin = state.origin,
        });
        if (runtime_operation) |operation| operation.immediate = descriptor_index;
    }
    return descriptors.toOwnedSlice(allocator);
}

fn lowerNativeExceptionalTargets(
    plan: *const optimizer.Plan,
    allocator: std.mem.Allocator,
) ![]jit.NativeExceptionalTarget {
    const graph = &plan.graph;
    const targets = try allocator.alloc(jit.NativeExceptionalTarget, graph.exceptional_targets.len);
    errdefer allocator.free(targets);
    for (graph.exceptional_targets, targets) |target, *lowered| {
        if (target.target >= plan.blocks.len or target.unwind_stack_depth > std.math.maxInt(u16) or
            target.target_stack_depth > std.math.maxInt(u16) or target.handler_count > std.math.maxInt(u16) or
            target.first_handler > graph.handler_states.len or
            target.handler_count > graph.handler_states.len - target.first_handler)
            return error.UnsupportedChunk;
        lowered.* = .{
            .target_ip = plan.blocks[target.target].start,
            .first_handler = target.first_handler,
            .unwind_stack_depth = @intCast(target.unwind_stack_depth),
            .target_stack_depth = @intCast(target.target_stack_depth),
            .handler_count = @intCast(target.handler_count),
            .kind = switch (target.kind) {
                .catch_ => .catch_,
                .finally_ => .finally_,
                .normal => return error.UnsupportedChunk,
            },
        };
    }
    return targets;
}

fn deterministicPathSteps(
    plan: *const optimizer.Plan,
    target_block: u32,
    target_steps: u32,
) error{UnsupportedChunk}!u32 {
    return deterministicSteps(plan, target_block, target_steps, false);
}

fn deterministicPrefixSteps(
    plan: *const optimizer.Plan,
    target_block: u32,
    target_steps: u32,
) error{UnsupportedChunk}!u32 {
    return deterministicSteps(plan, target_block, target_steps, true);
}

fn deterministicSteps(
    plan: *const optimizer.Plan,
    target_block: u32,
    target_steps: u32,
    allow_target_successors: bool,
) error{UnsupportedChunk}!u32 {
    const graph = &plan.graph;
    var entry_count: usize = 0;
    for (graph.edges) |edge| if (edge.from == optimizer.Block.none and edge.to == 0) {
        entry_count += 1;
    };
    if (entry_count != 1 or target_block >= plan.blocks.len or target_steps > plan.blocks[target_block].instruction_count)
        return error.UnsupportedChunk;

    var current: u32 = 0;
    var traversed: usize = 0;
    var steps: u32 = 0;
    while (traversed <= plan.blocks.len) : (traversed += 1) {
        // A runtime operation in the common prefix owns a deterministic step
        // count even when control branches after it. Only predecessors must be
        // single-path; successors are irrelevant until the operation returns.
        if (current == target_block and allow_target_successors)
            return std.math.add(u32, steps, target_steps) catch error.UnsupportedChunk;
        var outgoing: ?optimizer.Edge = null;
        for (graph.edges) |edge| if (edge.from == current) {
            if (outgoing != null) return error.UnsupportedChunk;
            outgoing = edge;
        };
        if (current == target_block) {
            if (outgoing != null or traversed + 1 != graph.edges.len) return error.UnsupportedChunk;
            return std.math.add(u32, steps, target_steps) catch error.UnsupportedChunk;
        }
        steps = std.math.add(u32, steps, plan.blocks[current].instruction_count) catch
            return error.UnsupportedChunk;
        const edge = outgoing orelse return error.UnsupportedChunk;
        if (edge.to >= plan.blocks.len) return error.UnsupportedChunk;
        current = edge.to;
    }
    return error.UnsupportedChunk;
}

fn frameStateHasRuntimeValue(graph: *const optimizer.ValueGraph, state: optimizer.FrameState) bool {
    if (state.kind != .effect and state.kind != .call) return false;
    for (graph.nodes) |node| if ((node.kind == .to_numeric or node.kind == .neg or node.kind == .pos or
        node.kind == .not or node.kind == .typeof_op or node.kind == .inc or node.kind == .dec or
        node.kind == .bit_not or node.kind == .to_string or node.kind == .to_property_key or
        node.kind == .get_prop or node.kind == .get_index or node.kind == .pow or
        node.kind == .bit_and or node.kind == .bit_or or node.kind == .bit_xor or
        node.kind == .shl or node.kind == .shr or node.kind == .ushr or
        node.kind == .set_prop or node.kind == .set_index or node.kind == .in_op or
        node.kind == .instance_of or node.kind == .private_in or node.kind == .call or
        node.kind == .call_with_this or node.kind == .construct) and node.block == state.block and
        node.origin == state.origin)
    {
        return true;
    };
    return false;
}

pub fn lower(chunk: *const bc.Chunk, plan: *const optimizer.Plan, allocator: std.mem.Allocator) !Program {
    const graph = &plan.graph;
    if (graph.nodes.len == 0 or graph.nodes.len > jit.numeric_scratch_capacity or chunk.local_count > 64 or
        graph.branches.len > 1)
        return error.UnsupportedChunk;
    var scratch_slots = graph.nodes.len;

    var aliases: [jit.numeric_scratch_capacity]optimizer.ValueId = @splat(optimizer.ValueNode.none);
    var types: [jit.numeric_scratch_capacity]ValueType = @splat(.other);
    for (graph.nodes, 0..) |node, node_index| if (node.kind == .block_argument) {
        var ordinal: usize = 0;
        for (graph.nodes[0..node_index]) |previous| if (previous.kind == .block_argument and previous.block == node.block) {
            ordinal += 1;
        };
        var incoming: ?optimizer.Edge = null;
        for (graph.edges) |edge| if (edge.to == node.block) {
            if (incoming != null) return error.UnsupportedChunk;
            incoming = edge;
        };
        const edge = incoming orelse return error.UnsupportedChunk;
        if (ordinal >= edge.argument_count) return error.UnsupportedChunk;
        aliases[node.id] = graph.edge_arguments[edge.first_argument + ordinal];
    };

    var operations: std.ArrayListUnmanaged(Operation) = .empty;
    errdefer operations.deinit(allocator);
    var required_numeric_slots: u64 = 0;
    var numeric_inputs: [jit.numeric_scratch_capacity]bool = @splat(false);
    for (graph.nodes) |node| switch (node.kind) {
        .add, .sub, .mul, .div, .mod, .lt, .le, .gt, .ge, .eq, .neq, .eq_strict, .neq_strict => {
            numeric_inputs[try resolveAlias(node.lhs, aliases)] = true;
            numeric_inputs[try resolveAlias(node.rhs, aliases)] = true;
        },
        else => {},
    };
    for (graph.nodes) |node| switch (node.kind) {
        .block_argument => {},
        .argument => {
            if (node.immediate >= chunk.param_count or node.immediate >= 64) return error.UnsupportedChunk;
            if (numeric_inputs[node.id]) required_numeric_slots |= @as(u64, 1) << @intCast(node.immediate);
            types[node.id] = if (numeric_inputs[node.id]) .number else .other;
            try operations.append(allocator, .{
                .kind = .argument,
                .destination = @intCast(node.id),
                .block = node.block,
                .immediate = node.immediate,
            });
        },
        .constant => {
            const constant = Value.fromRawBits(node.immediate);
            types[node.id] = if (constant.isNumber()) .number else if (constant.isBoolean()) .boolean else .other;
            try operations.append(allocator, .{
                .kind = .constant,
                .destination = @intCast(node.id),
                .block = node.block,
                .immediate = node.immediate,
            });
        },
        .undefined => {
            types[node.id] = .other;
            try operations.append(allocator, .{
                .kind = .constant,
                .destination = @intCast(node.id),
                .block = node.block,
                .immediate = Value.undef().rawBits(),
            });
        },
        .null => {
            types[node.id] = .other;
            try operations.append(allocator, .{
                .kind = .constant,
                .destination = @intCast(node.id),
                .block = node.block,
                .immediate = Value.nul().rawBits(),
            });
        },
        .true, .false => {
            types[node.id] = .boolean;
            try operations.append(allocator, .{
                .kind = .constant,
                .destination = @intCast(node.id),
                .block = node.block,
                .immediate = Value.boolVal(node.kind == .true).rawBits(),
            });
        },
        .add, .sub, .mul, .div, .lt, .le, .gt, .ge, .eq, .neq, .eq_strict, .neq_strict => {
            const lhs = try resolveAlias(node.lhs, aliases);
            const rhs = try resolveAlias(node.rhs, aliases);
            // The architecture-neutral graph must conservatively mark
            // parameter operations effectful because it has no type guards.
            // This lowering installs Number guards for every live argument,
            // making these primitive operations side-effect free.
            if (types[lhs] != .number or types[rhs] != .number) return error.UnsupportedChunk;
            const kind: OperationKind = switch (node.kind) {
                .add => .add,
                .sub => .sub,
                .mul => .mul,
                .div => .div,
                .lt => .lt,
                .le => .le,
                .gt => .gt,
                .ge => .ge,
                .eq, .eq_strict => .eq,
                .neq, .neq_strict => .neq,
                else => unreachable,
            };
            types[node.id] = switch (kind) {
                .lt, .le, .gt, .ge, .eq, .neq => .boolean,
                else => .number,
            };
            try operations.append(allocator, .{
                .kind = kind,
                .destination = @intCast(node.id),
                .block = node.block,
                .lhs = @intCast(lhs),
                .rhs = @intCast(rhs),
            });
        },
        .to_numeric, .neg, .pos, .not, .typeof_op, .inc, .dec, .bit_not, .to_string, .to_property_key, .get_prop, .private_in => {
            const input = try resolveAlias(node.lhs, aliases);
            types[node.id] = if (node.kind == .not or node.kind == .private_in)
                .boolean
            else if (node.kind == .pos)
                .number
            else
                .other;
            try operations.append(allocator, .{
                .kind = .runtime_operation,
                .destination = @intCast(node.id),
                .block = node.block,
                .lhs = @intCast(input),
                .immediate = node.origin,
            });
        },
        .get_index, .set_prop, .set_index, .pow, .bit_and, .bit_or, .bit_xor, .shl, .shr, .ushr, .in_op, .instance_of => {
            const input_count: usize = if (node.kind == .set_index) 3 else 2;
            if (scratch_slots + input_count > jit.numeric_scratch_capacity) return error.UnsupportedChunk;
            const first_input = scratch_slots;
            const inputs = [_]optimizer.ValueId{ node.lhs, node.rhs, node.third };
            for (inputs[0..input_count]) |input| {
                const source = try resolveAlias(input, aliases);
                try operations.append(allocator, .{
                    .kind = .copy,
                    .destination = @intCast(scratch_slots),
                    .block = node.block,
                    .lhs = @intCast(source),
                });
                scratch_slots += 1;
            }
            types[node.id] = if (node.kind == .in_op or node.kind == .instance_of) .boolean else .other;
            try operations.append(allocator, .{
                .kind = .runtime_operation,
                .destination = @intCast(node.id),
                .block = node.block,
                .lhs = @intCast(first_input),
                .immediate = node.origin,
            });
        },
        .call, .call_with_this, .construct => {
            var state: ?optimizer.FrameState = null;
            for (graph.frame_states) |candidate| if (candidate.kind == .call and
                candidate.block == node.block and candidate.origin == node.origin)
            {
                if (state != null) return error.UnsupportedChunk;
                state = candidate;
            };
            const call_state = state orelse return error.UnsupportedChunk;
            const argument_count = std.math.cast(u32, node.immediate) orelse return error.UnsupportedChunk;
            const receiver_words: u32 = if (node.kind == .call_with_this) 2 else 1;
            const input_count = std.math.add(u32, argument_count, receiver_words) catch return error.UnsupportedChunk;
            if (input_count > call_state.stack_count or
                scratch_slots + input_count > jit.numeric_scratch_capacity)
                return error.UnsupportedChunk;
            const first_input = scratch_slots;
            const stack_start: usize = call_state.first_value + call_state.local_count;
            const source_start = stack_start + call_state.stack_count - input_count;
            for (0..input_count) |input| {
                const source = try resolveAlias(graph.frame_state_values[source_start + input], aliases);
                try operations.append(allocator, .{
                    .kind = .copy,
                    .destination = @intCast(scratch_slots),
                    .block = node.block,
                    .lhs = @intCast(source),
                });
                scratch_slots += 1;
            }
            types[node.id] = .other;
            try operations.append(allocator, .{
                .kind = .runtime_operation,
                .destination = @intCast(node.id),
                .block = node.block,
                .lhs = @intCast(first_input),
                .immediate = node.origin,
            });
        },
        .mod => return error.UnsupportedChunk,
    };

    var result: optimizer.ValueId = 0;
    var branch_selection: ?BranchSelection = null;
    var side_exit: ?SideExit = null;
    var side_exit_branch: ?SideExitBranch = null;
    var bytecode_steps: u32 = 0;
    var deterministic_path = false;
    if (graph.branches.len == 0) {
        if (graph.returns.len == 1) {
            result = try resolveAlias(graph.returns[0].value, aliases);
            const return_block = plan.blocks[graph.returns[0].block];
            bytecode_steps = try deterministicPathSteps(
                plan,
                graph.returns[0].block,
                graph.returns[0].origin - return_block.start + 1,
            );
            deterministic_path = true;
        } else if (graph.returns.len == 0) {
            var throw_index: ?u16 = null;
            for (graph.frame_states, 0..) |state, index| if ((state.kind == .throw_ or state.kind == .abrupt_return or state.kind == .abrupt_jump or state.kind == .call or state.kind == .effect) and
                !frameStateHasRuntimeValue(graph, state))
            {
                const block = plan.blocks[state.block];
                const steps = deterministicPathSteps(plan, state.block, state.origin - block.start) catch continue;
                if (throw_index != null) return error.UnsupportedChunk;
                throw_index = std.math.cast(u16, index) orelse return error.UnsupportedChunk;
                bytecode_steps = steps;
            };
            for (graph.frame_states, 0..) |state, index| if (state.kind == .finally_dispatch) {
                const block = plan.blocks[state.block];
                const steps = deterministicPathSteps(plan, state.block, state.origin - block.start) catch continue;
                if (throw_index != null) return error.UnsupportedChunk;
                throw_index = std.math.cast(u16, index) orelse return error.UnsupportedChunk;
                bytecode_steps = steps;
            };
            side_exit = .{
                .deopt_index = throw_index orelse return error.UnsupportedChunk,
                .steps = std.math.cast(u12, bytecode_steps) orelse return error.UnsupportedChunk,
            };
            deterministic_path = graph.edges.len > 1;
        } else return error.UnsupportedChunk;
    } else {
        const branch = graph.branches[0];
        if (branch.block != 0 or graph.edges.len != 3 or graph.returns.len != 2 or
            branch.false_block == branch.true_block or branch.false_block >= plan.blocks.len or
            branch.true_block >= plan.blocks.len or plan.blocks[branch.false_block].successor_count != 0 or
            plan.blocks[branch.true_block].successor_count != 0)
            return error.UnsupportedChunk;
        var saw_entry = false;
        var saw_false = false;
        var saw_true = false;
        for (graph.edges) |edge| {
            if (edge.from == optimizer.Block.none and edge.to == 0) saw_entry = true else if (edge.from == 0 and edge.to == branch.false_block) saw_false = true else if (edge.from == 0 and edge.to == branch.true_block) saw_true = true else return error.UnsupportedChunk;
        }
        if (!saw_entry or !saw_false or !saw_true) return error.UnsupportedChunk;
        const false_return = returnForBlock(graph.returns, branch.false_block) orelse return error.UnsupportedChunk;
        const true_return = returnForBlock(graph.returns, branch.true_block) orelse return error.UnsupportedChunk;
        const condition = try resolveAlias(branch.condition, aliases);
        if (types[condition] != .boolean) return error.UnsupportedChunk;
        const false_result = try resolveAlias(false_return.value, aliases);
        const true_result = try resolveAlias(true_return.value, aliases);
        const false_steps = plan.blocks[0].instruction_count + plan.blocks[branch.false_block].instruction_count;
        const true_steps = plan.blocks[0].instruction_count + plan.blocks[branch.true_block].instruction_count;
        if (false_steps == true_steps) {
            bytecode_steps = false_steps;
            branch_selection = .{
                .condition = @intCast(condition),
                .false_result = @intCast(false_result),
                .true_result = @intCast(true_result),
                .false_block = branch.false_block,
                .true_block = branch.true_block,
            };
        } else {
            bytecode_steps = plan.blocks[0].instruction_count;
            side_exit_branch = .{
                .condition = @intCast(condition),
                .false_deopt_index = try blockEntryStateIndex(graph.frame_states, branch.false_block),
                .true_deopt_index = try blockEntryStateIndex(graph.frame_states, branch.true_block),
                .false_steps = @intCast(plan.blocks[0].instruction_count),
                .true_steps = @intCast(plan.blocks[0].instruction_count),
            };
        }
    }
    var deopt_points: std.ArrayListUnmanaged(jit.DeoptPoint) = .empty;
    errdefer deopt_points.deinit(allocator);
    var deopt_values: std.ArrayListUnmanaged(jit.RecoveryValue) = .empty;
    errdefer deopt_values.deinit(allocator);
    for (graph.frame_states) |state| {
        const first_value: u32 = @intCast(deopt_values.items.len);
        const first: usize = state.first_value;
        const count: usize = state.local_count + state.stack_count;
        for (graph.frame_state_values[first .. first + count]) |value| {
            const resolved = try resolveAlias(value, aliases);
            const node = graph.nodes[resolved];
            try deopt_values.append(allocator, if (node.kind == .argument and !numeric_inputs[resolved])
                .{ .source = .frame_slot, .index = @intCast(node.immediate) }
            else
                .{ .source = .scratch_slot, .index = @intCast(resolved) });
        }
        const first_handler: usize = state.first_handler;
        const handler_count: usize = state.handler_count;
        if (first_handler > graph.handler_states.len or handler_count > graph.handler_states.len - first_handler)
            return error.UnsupportedChunk;
        try deopt_points.append(allocator, .{
            .kind = switch (state.kind) {
                .block_entry => .block_entry,
                .branch => .branch,
                .return_ => .return_,
                .throw_ => .throw_,
                .finally_dispatch => .finally_dispatch,
                .abrupt_return => .abrupt_return,
                .abrupt_jump => .abrupt_jump,
                .call => .call,
                .effect => .effect,
            },
            .exit_ip = state.origin,
            .first_value = first_value,
            .local_count = @intCast(state.local_count),
            .stack_count = @intCast(state.stack_count),
            .first_handler = state.first_handler,
            .handler_count = std.math.cast(u16, state.handler_count) orelse return error.UnsupportedChunk,
            .accumulator = .{ .source = .constant, .bits = Value.undef().rawBits() },
        });
    }
    const native_operations = try stageNativeOperationDescriptors(
        chunk,
        plan,
        graph,
        aliases,
        allocator,
        &operations,
        &scratch_slots,
    );
    errdefer if (native_operations.len != 0) allocator.free(native_operations);
    const native_operation_names = try allocator.alloc(?[]const u8, native_operations.len);
    errdefer if (native_operation_names.len != 0) allocator.free(native_operation_names);
    for (native_operations, 0..) |descriptor, index| {
        if (descriptor.origin >= chunk.code.items.len) return error.UnsupportedChunk;
        const inst = chunk.code.items[descriptor.origin];
        native_operation_names[index] = if (inst.op == .get_prop or inst.op == .set_prop or inst.op == .private_in) name: {
            if (inst.a >= chunk.names.items.len) return error.UnsupportedChunk;
            break :name chunk.names.items[inst.a];
        } else null;
    }
    const native_exceptional_targets = try lowerNativeExceptionalTargets(plan, allocator);
    errdefer if (native_exceptional_targets.len != 0) allocator.free(native_exceptional_targets);
    const owned_operations = try operations.toOwnedSlice(allocator);
    errdefer allocator.free(owned_operations);
    const owned_deopt_points = try deopt_points.toOwnedSlice(allocator);
    errdefer allocator.free(owned_deopt_points);
    const owned_deopt_values = try deopt_values.toOwnedSlice(allocator);
    errdefer allocator.free(owned_deopt_values);
    const owned_deopt_handlers = try ownRecoveryHandlers(allocator, graph.handler_states);
    errdefer allocator.free(owned_deopt_handlers);
    const stack_maps = try recoveryStackMaps(allocator, owned_deopt_points, owned_deopt_values);
    errdefer allocator.free(stack_maps);
    for (native_operations) |descriptor| {
        if (descriptor.step_delta == 0) continue;
        if (descriptor.deopt_index >= stack_maps.len) return error.UnsupportedChunk;
        const point = owned_deopt_points[descriptor.deopt_index];
        const first: usize = point.first_value;
        const count: usize = point.local_count + point.stack_count;
        if (first > owned_deopt_values.len or count > owned_deopt_values.len - first)
            return error.UnsupportedChunk;
        for (owned_deopt_values[first .. first + count]) |recovery| if (recovery.source == .scratch_slot) {
            stack_maps[descriptor.deopt_index].scratch_pointer_slots |= @as(u64, 1) <<
                (std.math.cast(u6, recovery.index) orelse return error.UnsupportedChunk);
        };
        if (point.accumulator.source == .scratch_slot)
            stack_maps[descriptor.deopt_index].scratch_pointer_slots |= @as(u64, 1) <<
                (std.math.cast(u6, point.accumulator.index) orelse return error.UnsupportedChunk);
        const end = @as(usize, descriptor.first_input) + descriptor.input_count;
        if (end > jit.numeric_scratch_capacity) return error.UnsupportedChunk;
        for (descriptor.first_input..end) |slot| stack_maps[descriptor.deopt_index].scratch_pointer_slots |=
            @as(u64, 1) << (std.math.cast(u6, slot) orelse return error.UnsupportedChunk);
    }
    return .{
        .allocator = allocator,
        .operations = owned_operations,
        .result = @intCast(result),
        .branch = branch_selection,
        .side_exit = side_exit,
        .side_exit_branch = side_exit_branch,
        .scratch_slots = @intCast(scratch_slots),
        .frame_slots = chunk.local_count,
        .required_numeric_slots = required_numeric_slots,
        .bytecode_steps = bytecode_steps,
        .deopt_points = owned_deopt_points,
        .deopt_values = owned_deopt_values,
        .deopt_handlers = owned_deopt_handlers,
        .stack_maps = stack_maps,
        .native_operations = native_operations,
        .native_exceptional_targets = native_exceptional_targets,
        .native_operation_names = native_operation_names,
        .deterministic_path = deterministic_path,
    };
}

const LoopExitArm = struct {
    block: u32,
    direct: bool,
};

fn branchForBlock(branches: []const optimizer.BranchValue, block: u32) ?optimizer.BranchValue {
    var found: ?optimizer.BranchValue = null;
    for (branches) |branch| if (branch.block == block) {
        if (found != null) return null;
        found = branch;
    };
    return found;
}

fn loopExitArm(
    plan: *const optimizer.Plan,
    branches: []const optimizer.BranchValue,
    outer_exit: u32,
    target: u32,
) ?LoopExitArm {
    if (target == outer_exit) return .{ .block = target, .direct = true };
    if (target >= plan.blocks.len) return null;
    for (branches) |branch| if (branch.block == target) return null;
    const block = plan.blocks[target];
    if (block.successor_count != 1 or block.successors[0] != outer_exit) return null;
    return .{ .block = target, .direct = false };
}

fn loopBackedgeArm(
    plan: *const optimizer.Plan,
    branches: []const optimizer.BranchValue,
    header: u32,
    target: u32,
) ?LoopExitArm {
    if (target == header) return .{ .block = target, .direct = true };
    if (target >= plan.blocks.len) return null;
    for (branches) |branch| if (branch.block == target) return null;
    const block = plan.blocks[target];
    if (block.successor_count != 1 or block.successors[0] != header) return null;
    return .{ .block = target, .direct = false };
}

fn lowerLoopOsr(chunk: *const bc.Chunk, plan: *const optimizer.Plan, allocator: std.mem.Allocator) !Program {
    const graph = &plan.graph;
    if (graph.nodes.len == 0 or graph.nodes.len > jit.numeric_scratch_capacity or chunk.local_count > 64 or
        graph.branches.len == 0)
        return error.UnsupportedChunk;

    const osr = try selectLoopOsrMetadata(plan, allocator, false);
    errdefer osr.destroy();
    const entry = osr.entries[0];
    if (entry.stack_count != 0) return error.UnsupportedChunk;
    var header_block: ?u32 = null;
    for (plan.blocks) |block| if (block.start == entry.entry_ip) {
        if (header_block != null) return error.UnsupportedChunk;
        header_block = block.id;
    };
    const header = header_block orelse return error.UnsupportedChunk;
    var outer_branch: ?optimizer.BranchValue = null;
    for (graph.branches) |candidate| {
        if (candidate.block == header) {
            if (outer_branch != null) return error.UnsupportedChunk;
            outer_branch = candidate;
        }
    }
    const branch = outer_branch orelse return error.UnsupportedChunk;
    if (branch.block != header or branch.false_block == branch.true_block) return error.UnsupportedChunk;

    var body: ?u32 = null;
    var exit_guards: std.ArrayListUnmanaged(LoopExitGuard) = .empty;
    defer exit_guards.deinit(allocator);
    var latch_guards: std.ArrayListUnmanaged(LoopLatchGuard) = .empty;
    defer latch_guards.deinit(allocator);
    var loop_branches: std.ArrayListUnmanaged(LoopBranch) = .empty;
    defer loop_branches.deinit(allocator);
    var latch: u32 = undefined;
    var true_steps: u32 = undefined;
    var backedge_steps: u32 = undefined;
    var guarded_backedge_steps: u32 = 0;
    var tail_block = branch.true_block;
    var tail_prefix_steps = plan.blocks[header].instruction_count;

    // Recognize a reducible chain of conditional exits. Each guard has exactly
    // one arm into the outer exit (directly or through a tiny arm block) and
    // one arm that advances to the next guard, a branch tail, or a backedge.
    if (branchForBlock(graph.branches, branch.true_block) != null) chain: {
        while (exit_guards.items.len < graph.branches.len) {
            const guard_branch = branchForBlock(graph.branches, tail_block) orelse break;
            if (guard_branch.false_block == guard_branch.true_block or
                guard_branch.false_block >= plan.blocks.len or guard_branch.true_block >= plan.blocks.len)
                break;
            const false_exit = loopExitArm(plan, graph.branches, branch.false_block, guard_branch.false_block);
            const true_exit = loopExitArm(plan, graph.branches, branch.false_block, guard_branch.true_block);
            if ((false_exit == null) == (true_exit == null)) break;
            const exit = false_exit orelse true_exit.?;
            const exit_on_true = true_exit != null;
            const continue_block = if (exit_on_true) guard_branch.false_block else guard_branch.true_block;
            tail_prefix_steps = std.math.add(u32, tail_prefix_steps, plan.blocks[tail_block].instruction_count) catch break;
            const exit_steps = if (exit.direct)
                tail_prefix_steps
            else
                std.math.add(u32, tail_prefix_steps, plan.blocks[exit.block].instruction_count) catch break;
            exit_guards.append(allocator, .{
                .entry_block = tail_block,
                .condition = std.math.cast(u8, guard_branch.condition) orelse break,
                .exit_block = exit.block,
                .exit_from = if (exit.direct) tail_block else exit.block,
                .exit_on_true = exit_on_true,
                .exit_steps = std.math.cast(u12, exit_steps) orelse break,
            }) catch return error.OutOfMemory;
            tail_block = continue_block;
        }
        if (exit_guards.items.len == 0 or tail_block >= plan.blocks.len) {
            exit_guards.clearRetainingCapacity();
            tail_block = branch.true_block;
            tail_prefix_steps = plan.blocks[header].instruction_count;
            break :chain;
        }
        if (plan.blocks[tail_block].successor_count == 1 and plan.blocks[tail_block].successors[0] == header) {
            body = tail_block;
            latch = tail_block;
            true_steps = std.math.add(u32, tail_prefix_steps, plan.blocks[tail_block].instruction_count) catch
                return error.UnsupportedChunk;
            backedge_steps = true_steps;
        } else if (branchForBlock(graph.branches, tail_block) == null) {
            exit_guards.clearRetainingCapacity();
            tail_block = branch.true_block;
            tail_prefix_steps = plan.blocks[header].instruction_count;
        }
    }

    // Consume a chain of conditional continues before the shared tail. Each
    // guard owns one exact backedge arm and leaves the other arm available for
    // another guard, a shared branch region, or the final straight latch.
    if (body == null and branchForBlock(graph.branches, tail_block) != null) {
        while (latch_guards.items.len < graph.branches.len) {
            const guard_branch = branchForBlock(graph.branches, tail_block) orelse break;
            if (guard_branch.false_block == guard_branch.true_block or
                guard_branch.false_block >= plan.blocks.len or guard_branch.true_block >= plan.blocks.len)
                break;
            const false_latch = loopBackedgeArm(plan, graph.branches, header, guard_branch.false_block);
            const true_latch = loopBackedgeArm(plan, graph.branches, header, guard_branch.true_block);
            if ((false_latch == null) == (true_latch == null)) break;
            const backedge = false_latch orelse true_latch.?;
            const backedge_on_true = true_latch != null;
            const continue_block = if (backedge_on_true) guard_branch.false_block else guard_branch.true_block;
            tail_prefix_steps = std.math.add(u32, tail_prefix_steps, plan.blocks[tail_block].instruction_count) catch
                return error.UnsupportedChunk;
            const latch_steps = if (backedge.direct)
                tail_prefix_steps
            else
                std.math.add(u32, tail_prefix_steps, plan.blocks[backedge.block].instruction_count) catch
                    return error.UnsupportedChunk;
            const synthetic_block = std.math.add(
                u32,
                std.math.cast(u32, plan.blocks.len) orelse return error.UnsupportedChunk,
                std.math.cast(u32, latch_guards.items.len) orelse return error.UnsupportedChunk,
            ) catch return error.UnsupportedChunk;
            try latch_guards.append(allocator, .{
                .entry_block = tail_block,
                .condition = std.math.cast(u8, guard_branch.condition) orelse return error.UnsupportedChunk,
                .latch_block = backedge.block,
                .latch_from = if (backedge.direct) tail_block else backedge.block,
                .operations_block = if (backedge.direct) synthetic_block else backedge.block,
                .backedge_on_true = backedge_on_true,
                .backedge_steps = std.math.cast(u12, latch_steps) orelse return error.UnsupportedChunk,
            });
            guarded_backedge_steps = @max(guarded_backedge_steps, latch_steps);
            tail_block = continue_block;
            if (tail_block >= plan.blocks.len) return error.UnsupportedChunk;
            if (plan.blocks[tail_block].successor_count == 1 and plan.blocks[tail_block].successors[0] == header) {
                body = tail_block;
                latch = tail_block;
                backedge_steps = std.math.add(u32, tail_prefix_steps, plan.blocks[tail_block].instruction_count) catch
                    return error.UnsupportedChunk;
                true_steps = @max(guarded_backedge_steps, backedge_steps);
                break;
            }
            if (branchForBlock(graph.branches, tail_block) == null) return error.UnsupportedChunk;
        }
    }

    if (body == null and branchForBlock(graph.branches, tail_block) != null) {
        var current = tail_block;
        var total_steps = tail_prefix_steps;
        var terminal = false;
        while (loop_branches.items.len < graph.branches.len) {
            const nested = branchForBlock(graph.branches, current) orelse return error.UnsupportedChunk;
            if (nested.false_block == nested.true_block or nested.false_block >= plan.blocks.len or
                nested.true_block >= plan.blocks.len)
                return error.UnsupportedChunk;
            const false_arm = plan.blocks[nested.false_block];
            const true_arm = plan.blocks[nested.true_block];
            if (false_arm.successor_count != 1 or true_arm.successor_count != 1)
                return error.UnsupportedChunk;
            const false_successor = false_arm.successors[0];
            const true_successor = true_arm.successors[0];
            var merge: ?u32 = null;
            var emit_merge = false;
            var next: ?u32 = null;
            if (false_successor == header and true_successor == header) {
                terminal = true;
                latch = nested.true_block;
            } else if (false_successor == true_successor and false_successor != header) {
                merge = false_successor;
                if (merge.? >= plan.blocks.len) return error.UnsupportedChunk;
                if (branchForBlock(graph.branches, merge.?)) |_| {
                    next = merge.?;
                } else {
                    const merge_plan = plan.blocks[merge.?];
                    if (merge_plan.successor_count != 1) return error.UnsupportedChunk;
                    emit_merge = true;
                    if (merge_plan.successors[0] == header) {
                        terminal = true;
                        latch = merge.?;
                    } else if (branchForBlock(graph.branches, merge_plan.successors[0]) != null) {
                        next = merge_plan.successors[0];
                    } else return error.UnsupportedChunk;
                }
            } else return error.UnsupportedChunk;

            const common_steps = plan.blocks[nested.block].instruction_count;
            var false_steps = std.math.add(u32, common_steps, false_arm.instruction_count) catch
                return error.UnsupportedChunk;
            var nested_true_steps = std.math.add(u32, common_steps, true_arm.instruction_count) catch
                return error.UnsupportedChunk;
            if (emit_merge) {
                false_steps = std.math.add(u32, false_steps, plan.blocks[merge.?].instruction_count) catch
                    return error.UnsupportedChunk;
                nested_true_steps = std.math.add(u32, nested_true_steps, plan.blocks[merge.?].instruction_count) catch
                    return error.UnsupportedChunk;
            }
            try loop_branches.append(allocator, .{
                .entry_block = nested.block,
                .condition = std.math.cast(u8, nested.condition) orelse return error.UnsupportedChunk,
                .false_block = nested.false_block,
                .true_block = nested.true_block,
                .merge_block = merge,
                .emit_merge = emit_merge,
                .terminal = terminal,
                .false_steps = std.math.cast(u12, false_steps) orelse return error.UnsupportedChunk,
                .true_steps = std.math.cast(u12, nested_true_steps) orelse return error.UnsupportedChunk,
            });
            total_steps = std.math.add(u32, total_steps, @max(false_steps, nested_true_steps)) catch
                return error.UnsupportedChunk;
            if (terminal) {
                true_steps = @max(guarded_backedge_steps, total_steps);
                backedge_steps = total_steps;
                break;
            }
            current = next orelse return error.UnsupportedChunk;
        }
        if (!terminal) return error.UnsupportedChunk;
    } else if (body == null) {
        if (exit_guards.items.len != 0) return error.UnsupportedChunk;
        const straight_body = branch.true_block;
        if (straight_body >= plan.blocks.len or plan.blocks[straight_body].successor_count != 1 or
            plan.blocks[straight_body].successors[0] != header)
            return error.UnsupportedChunk;
        body = straight_body;
        latch = straight_body;
        true_steps = try sumInstructionCounts(plan, &.{ header, straight_body });
        backedge_steps = true_steps;
    }

    var types: [jit.numeric_scratch_capacity]ValueType = @splat(.other);
    var initialized: [jit.numeric_scratch_capacity]bool = @splat(false);
    const required_numeric = try numericRequirements(graph);
    var scratch_slots = graph.nodes.len;
    var operations: std.ArrayListUnmanaged(Operation) = .empty;
    errdefer operations.deinit(allocator);
    try appendPrimitiveLeaves(graph, allocator, &operations, &types, &initialized);
    try appendBlockOperations(graph, header, true, allocator, &operations, &types, &initialized, &required_numeric);
    if (types[branch.condition] != .boolean) return error.UnsupportedChunk;
    var path_from: ?u32 = header;
    for (exit_guards.items) |guard| {
        try appendEdgeCopies(graph, path_from.?, guard.entry_block, guard.entry_block, allocator, &operations, &types, &initialized, &required_numeric, &scratch_slots);
        try appendBlockOperations(graph, guard.entry_block, false, allocator, &operations, &types, &initialized, &required_numeric);
        if (types[guard.condition] != .boolean) return error.UnsupportedChunk;
        if (guard.exit_from != guard.entry_block) {
            try appendEdgeCopies(graph, guard.entry_block, guard.exit_block, guard.exit_block, allocator, &operations, &types, &initialized, &required_numeric, &scratch_slots);
            try appendBlockOperations(graph, guard.exit_block, false, allocator, &operations, &types, &initialized, &required_numeric);
        }
        path_from = guard.entry_block;
    }
    for (latch_guards.items) |guard| {
        try appendEdgeCopies(graph, path_from.?, guard.entry_block, guard.entry_block, allocator, &operations, &types, &initialized, &required_numeric, &scratch_slots);
        try appendBlockOperations(graph, guard.entry_block, false, allocator, &operations, &types, &initialized, &required_numeric);
        if (types[guard.condition] != .boolean) return error.UnsupportedChunk;
        try appendEdgeCopies(graph, guard.entry_block, guard.latch_block, guard.operations_block, allocator, &operations, &types, &initialized, &required_numeric, &scratch_slots);
        if (guard.latch_from != guard.entry_block) {
            try appendBlockOperations(graph, guard.latch_block, false, allocator, &operations, &types, &initialized, &required_numeric);
            try appendEdgeCopies(graph, guard.latch_block, header, guard.operations_block, allocator, &operations, &types, &initialized, &required_numeric, &scratch_slots);
        }
        path_from = guard.entry_block;
    }
    for (loop_branches.items) |segment| {
        if (path_from) |from|
            try appendEdgeCopies(graph, from, segment.entry_block, segment.entry_block, allocator, &operations, &types, &initialized, &required_numeric, &scratch_slots);
        try appendBlockOperations(graph, segment.entry_block, false, allocator, &operations, &types, &initialized, &required_numeric);
        if (types[segment.condition] != .boolean) return error.UnsupportedChunk;

        const true_target = segment.merge_block orelse header;
        try appendEdgeCopies(graph, segment.entry_block, segment.true_block, segment.true_block, allocator, &operations, &types, &initialized, &required_numeric, &scratch_slots);
        try appendBlockOperations(graph, segment.true_block, false, allocator, &operations, &types, &initialized, &required_numeric);
        try appendEdgeCopies(graph, segment.true_block, true_target, segment.true_block, allocator, &operations, &types, &initialized, &required_numeric, &scratch_slots);

        const false_target = segment.merge_block orelse header;
        try appendEdgeCopies(graph, segment.entry_block, segment.false_block, segment.false_block, allocator, &operations, &types, &initialized, &required_numeric, &scratch_slots);
        try appendBlockOperations(graph, segment.false_block, false, allocator, &operations, &types, &initialized, &required_numeric);
        try appendEdgeCopies(graph, segment.false_block, false_target, segment.false_block, allocator, &operations, &types, &initialized, &required_numeric, &scratch_slots);

        if (segment.merge_block) |merge_block| {
            if (segment.emit_merge) {
                try appendBlockOperations(graph, merge_block, false, allocator, &operations, &types, &initialized, &required_numeric);
                if (segment.terminal) {
                    try appendEdgeCopies(graph, merge_block, header, merge_block, allocator, &operations, &types, &initialized, &required_numeric, &scratch_slots);
                    path_from = null;
                } else {
                    path_from = merge_block;
                }
            } else {
                path_from = null;
            }
        } else {
            path_from = null;
        }
    }
    if (loop_branches.items.len == 0) {
        const straight_body = body.?;
        try appendEdgeCopies(graph, path_from.?, straight_body, straight_body, allocator, &operations, &types, &initialized, &required_numeric, &scratch_slots);
        try appendBlockOperations(graph, straight_body, false, allocator, &operations, &types, &initialized, &required_numeric);
        try appendEdgeCopies(graph, straight_body, header, straight_body, allocator, &operations, &types, &initialized, &required_numeric, &scratch_slots);
    }

    var deopt_points: std.ArrayListUnmanaged(jit.DeoptPoint) = .empty;
    errdefer deopt_points.deinit(allocator);
    var deopt_values: std.ArrayListUnmanaged(jit.RecoveryValue) = .empty;
    errdefer deopt_values.deinit(allocator);
    const entry_index = try appendBlockEntryDeopt(graph, &initialized, header, allocator, &deopt_points, &deopt_values);
    const false_index = try appendEdgeDeopt(graph, &initialized, header, branch.false_block, allocator, &deopt_points, &deopt_values);
    const true_index = try appendEdgeDeopt(graph, &initialized, latch, header, allocator, &deopt_points, &deopt_values);
    for (exit_guards.items) |*guard| {
        guard.exit_deopt_index = try appendEdgeDeopt(
            graph,
            &initialized,
            guard.exit_from,
            branch.false_block,
            allocator,
            &deopt_points,
            &deopt_values,
        );
    }

    const owned_operations = try operations.toOwnedSlice(allocator);
    errdefer allocator.free(owned_operations);
    const owned_deopt_points = try deopt_points.toOwnedSlice(allocator);
    errdefer allocator.free(owned_deopt_points);
    const owned_deopt_values = try deopt_values.toOwnedSlice(allocator);
    errdefer allocator.free(owned_deopt_values);
    const owned_deopt_handlers = try ownRecoveryHandlers(allocator, graph.handler_states);
    errdefer allocator.free(owned_deopt_handlers);
    const stack_maps = try typedRecoveryStackMaps(allocator, owned_deopt_points, owned_deopt_values, &types);
    errdefer allocator.free(stack_maps);
    const owned_exit_guards = try exit_guards.toOwnedSlice(allocator);
    errdefer if (owned_exit_guards.len != 0) allocator.free(owned_exit_guards);
    const owned_latch_guards = try latch_guards.toOwnedSlice(allocator);
    errdefer if (owned_latch_guards.len != 0) allocator.free(owned_latch_guards);
    const owned_loop_branches = try loop_branches.toOwnedSlice(allocator);
    errdefer if (owned_loop_branches.len != 0) allocator.free(owned_loop_branches);
    var local_mask: u64 = 0;
    for (osr.imports[entry.first_import .. entry.first_import + entry.local_count]) |import| {
        if (import.source != .frame_slot or import.source_index >= 64 or import.destination >= required_numeric.len)
            return error.UnsupportedChunk;
        if (required_numeric[import.destination]) local_mask |= @as(u64, 1) << @intCast(import.source_index);
    }
    const exit_steps = std.math.cast(u12, plan.blocks[header].instruction_count) orelse return error.UnsupportedChunk;
    const iteration_steps = std.math.cast(u12, true_steps) orelse return error.UnsupportedChunk;
    return .{
        .allocator = allocator,
        .operations = owned_operations,
        .result = 0,
        .branch = null,
        .side_exit = null,
        .side_exit_branch = .{
            .condition = @intCast(branch.condition),
            .entry_deopt_index = entry_index,
            .false_deopt_index = false_index,
            .true_deopt_index = true_index,
            .false_steps = exit_steps,
            .true_steps = iteration_steps,
            .backedge_steps = std.math.cast(u12, backedge_steps) orelse return error.UnsupportedChunk,
            .loop_prefix_steps = std.math.cast(u12, tail_prefix_steps) orelse return error.UnsupportedChunk,
            .true_block = body,
        },
        .loop_exit_guards = owned_exit_guards,
        .loop_latch_guards = owned_latch_guards,
        .loop_branches = owned_loop_branches,
        .scratch_slots = @intCast(scratch_slots),
        .frame_slots = chunk.local_count,
        .required_numeric_slots = local_mask,
        .bytecode_steps = true_steps,
        .deopt_points = owned_deopt_points,
        .deopt_values = owned_deopt_values,
        .deopt_handlers = owned_deopt_handlers,
        .stack_maps = stack_maps,
        .osr = osr,
        .execution_block = header,
        .entry_enabled = false,
    };
}

const RegionEdgeOperations = struct {
    from: u32,
    to: u32,
    operations_block: u32,
};

const RegionExitDeopt = struct {
    from: u32,
    deopt_index: u16,
};

const RegionBlockDeopt = struct {
    block: u32,
    deopt_index: u16,
};

fn regionEdgeOperations(edges: []const RegionEdgeOperations, from: u32, to: u32) ?u32 {
    var found: ?u32 = null;
    for (edges) |edge| if (edge.from == from and edge.to == to) {
        if (found != null) return null;
        found = edge.operations_block;
    };
    return found;
}

fn regionExitDeopt(exits: []const RegionExitDeopt, from: u32) ?u16 {
    var found: ?u16 = null;
    for (exits) |exit| if (exit.from == from) {
        if (found != null) return null;
        found = exit.deopt_index;
    };
    return found;
}

fn regionBlockDeopt(entries: []const RegionBlockDeopt, block: u32) ?u16 {
    var found: ?u16 = null;
    for (entries) |entry| if (entry.block == block) {
        if (found != null) return null;
        found = entry.deopt_index;
    };
    return found;
}

const LoopRegionMode = enum { dag, fused };

fn regionBackedge(plan: *const optimizer.Plan, from: u32, to: u32) bool {
    if (from >= plan.blocks.len or to >= plan.blocks.len or from == to) return false;
    return plan.blocks[from].start >= plan.blocks[to].start;
}

fn lowerRegionOsr(
    chunk: *const bc.Chunk,
    plan: *const optimizer.Plan,
    allocator: std.mem.Allocator,
    mode: LoopRegionMode,
) !Program {
    const graph = &plan.graph;
    if (graph.nodes.len == 0 or graph.nodes.len > jit.numeric_scratch_capacity or chunk.local_count > 64 or
        graph.branches.len == 0 or plan.blocks.len == 0)
        return error.UnsupportedChunk;

    const osr = try selectLoopOsrMetadata(plan, allocator, mode == .fused);
    errdefer osr.destroy();
    if (osr.entries.len != 1 or osr.entries[0].stack_count != 0) return error.UnsupportedChunk;
    const entry = osr.entries[0];

    var header: ?u32 = null;
    for (plan.blocks) |block| if (block.start == entry.entry_ip) {
        if (header != null) return error.UnsupportedChunk;
        header = block.id;
    };
    const header_block = header orelse return error.UnsupportedChunk;
    const outer = branchForBlock(graph.branches, header_block) orelse return error.UnsupportedChunk;
    if (outer.false_block == outer.true_block or outer.false_block >= plan.blocks.len or
        outer.true_block >= plan.blocks.len)
        return error.UnsupportedChunk;
    const outer_exit = outer.false_block;
    const region_entry = outer.true_block;
    if (region_entry == header_block or region_entry == outer_exit) return error.UnsupportedChunk;

    const reachable = try allocator.alloc(bool, plan.blocks.len);
    defer allocator.free(reachable);
    @memset(reachable, false);
    var discover: std.ArrayListUnmanaged(u32) = .empty;
    defer discover.deinit(allocator);
    try discover.append(allocator, region_entry);
    reachable[region_entry] = true;
    var discover_index: usize = 0;
    while (discover_index < discover.items.len) : (discover_index += 1) {
        const block_id = discover.items[discover_index];
        if (block_id >= plan.blocks.len) return error.UnsupportedChunk;
        const block = plan.blocks[block_id];
        if (block.successor_count == 0 or block.successor_count > 2) return error.UnsupportedChunk;
        if (block.successor_count == 2) {
            const conditional = branchForBlock(graph.branches, block_id) orelse return error.UnsupportedChunk;
            if (conditional.false_block == conditional.true_block) return error.UnsupportedChunk;
        } else if (branchForBlock(graph.branches, block_id) != null) {
            return error.UnsupportedChunk;
        }
        for (block.successors[0..block.successor_count]) |successor| {
            if (successor == header_block or successor == outer_exit) continue;
            if (successor >= plan.blocks.len) return error.UnsupportedChunk;
            if (!reachable[successor]) {
                reachable[successor] = true;
                try discover.append(allocator, successor);
            }
        }
    }

    // A selected region has one external entry from its header. Any other
    // predecessor would be a second entry and therefore irreducible here.
    for (graph.edges) |edge| {
        if (edge.to >= reachable.len or !reachable[edge.to]) continue;
        if (edge.from == header_block) {
            if (edge.to != region_entry) return error.UnsupportedChunk;
        } else if (edge.from >= reachable.len or !reachable[edge.from]) {
            return error.UnsupportedChunk;
        }
    }

    // Every removed internal backedge must target a dominator. Test that no
    // path from the region entry can reach the source while avoiding the
    // proposed header; accepting such an edge would turn a multi-entry SCC
    // into a falsely structured loop.
    if (mode == .fused) {
        const dominance_seen = try allocator.alloc(bool, plan.blocks.len);
        defer allocator.free(dominance_seen);
        var dominance_stack: std.ArrayListUnmanaged(u32) = .empty;
        defer dominance_stack.deinit(allocator);
        for (discover.items) |source| {
            const source_block = plan.blocks[source];
            for (source_block.successors[0..source_block.successor_count]) |target| {
                if (target >= reachable.len or !reachable[target] or !regionBackedge(plan, source, target) or
                    target == region_entry)
                    continue;
                @memset(dominance_seen, false);
                dominance_stack.clearRetainingCapacity();
                dominance_seen[region_entry] = true;
                try dominance_stack.append(allocator, region_entry);
                var dominance_index: usize = 0;
                while (dominance_index < dominance_stack.items.len) : (dominance_index += 1) {
                    const current = dominance_stack.items[dominance_index];
                    if (current == source) return error.UnsupportedChunk;
                    const current_block = plan.blocks[current];
                    for (current_block.successors[0..current_block.successor_count]) |successor| {
                        if (successor == target or successor >= reachable.len or !reachable[successor] or
                            dominance_seen[successor])
                            continue;
                        dominance_seen[successor] = true;
                        try dominance_stack.append(allocator, successor);
                    }
                }
            }
        }
    }

    const indegree = try allocator.alloc(u32, plan.blocks.len);
    defer allocator.free(indegree);
    @memset(indegree, 0);
    var region_count: usize = 0;
    var has_internal_backedge = false;
    for (reachable, 0..) |is_reachable, block_index| {
        if (!is_reachable) continue;
        region_count += 1;
        const block = plan.blocks[block_index];
        for (block.successors[0..block.successor_count]) |successor| {
            if (successor < reachable.len and reachable[successor]) {
                if (mode == .fused and regionBackedge(plan, @intCast(block_index), successor)) {
                    has_internal_backedge = true;
                    continue;
                }
                indegree[successor] = std.math.add(u32, indegree[successor], 1) catch
                    return error.UnsupportedChunk;
            }
        }
    }
    if (mode == .fused and !has_internal_backedge) return error.UnsupportedChunk;
    if (indegree[region_entry] != 0) return error.UnsupportedChunk;
    var topo: std.ArrayListUnmanaged(u32) = .empty;
    defer topo.deinit(allocator);
    try topo.append(allocator, region_entry);
    var topo_index: usize = 0;
    while (topo_index < topo.items.len) : (topo_index += 1) {
        const block_id = topo.items[topo_index];
        const block = plan.blocks[block_id];
        for (block.successors[0..block.successor_count]) |successor| {
            if (successor >= reachable.len or !reachable[successor]) continue;
            if (mode == .fused and regionBackedge(plan, block_id, successor)) continue;
            if (indegree[successor] == 0) return error.UnsupportedChunk;
            indegree[successor] -= 1;
            if (indegree[successor] == 0) try topo.append(allocator, successor);
        }
    }
    if (topo.items.len != region_count) return error.UnsupportedChunk;

    const longest = try allocator.alloc(u32, plan.blocks.len);
    defer allocator.free(longest);
    @memset(longest, 0);
    var reverse_index = topo.items.len;
    while (reverse_index != 0) {
        reverse_index -= 1;
        const block_id = topo.items[reverse_index];
        const block = plan.blocks[block_id];
        var longest_tail: u32 = 0;
        for (block.successors[0..block.successor_count]) |successor| {
            if (successor < reachable.len and reachable[successor] and
                !(mode == .fused and regionBackedge(plan, block_id, successor)))
                longest_tail = @max(longest_tail, longest[successor]);
        }
        longest[block_id] = std.math.add(u32, block.instruction_count, longest_tail) catch
            return error.UnsupportedChunk;
    }
    const maximum_steps = std.math.add(
        u32,
        plan.blocks[header_block].instruction_count,
        longest[region_entry],
    ) catch return error.UnsupportedChunk;

    var types: [jit.numeric_scratch_capacity]ValueType = @splat(.other);
    var initialized: [jit.numeric_scratch_capacity]bool = @splat(false);
    const required_numeric = try numericRequirements(graph);
    var scratch_slots = graph.nodes.len;
    var operations: std.ArrayListUnmanaged(Operation) = .empty;
    errdefer operations.deinit(allocator);
    var edge_operations: std.ArrayListUnmanaged(RegionEdgeOperations) = .empty;
    defer edge_operations.deinit(allocator);
    var next_synthetic_block = std.math.cast(u32, plan.blocks.len) orelse return error.UnsupportedChunk;

    try appendPrimitiveLeaves(graph, allocator, &operations, &types, &initialized);
    try appendBlockOperations(graph, header_block, true, allocator, &operations, &types, &initialized, &required_numeric);
    if (types[outer.condition] != .boolean) return error.UnsupportedChunk;

    const entry_operations_block = next_synthetic_block;
    next_synthetic_block = std.math.add(u32, next_synthetic_block, 1) catch return error.UnsupportedChunk;
    try edge_operations.append(allocator, .{
        .from = header_block,
        .to = region_entry,
        .operations_block = entry_operations_block,
    });
    try appendEdgeCopies(graph, header_block, region_entry, entry_operations_block, allocator, &operations, &types, &initialized, &required_numeric, &scratch_slots);

    for (topo.items) |block_id| {
        for (graph.edges) |edge| {
            if (edge.to != block_id or edge.from == header_block) continue;
            if (edge.from >= reachable.len or !reachable[edge.from]) return error.UnsupportedChunk;
            if (mode == .fused and regionBackedge(plan, edge.from, edge.to)) continue;
            const operations_block = next_synthetic_block;
            next_synthetic_block = std.math.add(u32, next_synthetic_block, 1) catch
                return error.UnsupportedChunk;
            try edge_operations.append(allocator, .{
                .from = edge.from,
                .to = edge.to,
                .operations_block = operations_block,
            });
            try appendEdgeCopies(graph, edge.from, edge.to, operations_block, allocator, &operations, &types, &initialized, &required_numeric, &scratch_slots);
        }
        try appendBlockOperations(graph, block_id, false, allocator, &operations, &types, &initialized, &required_numeric);
        if (plan.blocks[block_id].successor_count == 2) {
            const conditional = branchForBlock(graph.branches, block_id) orelse return error.UnsupportedChunk;
            if (types[conditional.condition] != .boolean) return error.UnsupportedChunk;
        }
    }

    var first_backedge: ?u32 = null;
    for (topo.items) |block_id| {
        const block = plan.blocks[block_id];
        for (block.successors[0..block.successor_count]) |successor| {
            const is_outer_backedge = successor == header_block;
            const is_internal_backedge = mode == .fused and successor < reachable.len and reachable[successor] and
                regionBackedge(plan, block_id, successor);
            if (!is_outer_backedge and !is_internal_backedge) continue;
            if (is_outer_backedge and first_backedge == null) first_backedge = block_id;
            const operations_block = next_synthetic_block;
            next_synthetic_block = std.math.add(u32, next_synthetic_block, 1) catch
                return error.UnsupportedChunk;
            try edge_operations.append(allocator, .{
                .from = block_id,
                .to = successor,
                .operations_block = operations_block,
            });
            try appendEdgeCopies(graph, block_id, successor, operations_block, allocator, &operations, &types, &initialized, &required_numeric, &scratch_slots);
        }
    }
    const recovery_backedge = first_backedge orelse return error.UnsupportedChunk;

    var deopt_points: std.ArrayListUnmanaged(jit.DeoptPoint) = .empty;
    errdefer deopt_points.deinit(allocator);
    var deopt_values: std.ArrayListUnmanaged(jit.RecoveryValue) = .empty;
    errdefer deopt_values.deinit(allocator);
    var exit_deopts: std.ArrayListUnmanaged(RegionExitDeopt) = .empty;
    defer exit_deopts.deinit(allocator);
    var block_deopts: std.ArrayListUnmanaged(RegionBlockDeopt) = .empty;
    defer block_deopts.deinit(allocator);
    const entry_index = try appendBlockEntryDeopt(graph, &initialized, header_block, allocator, &deopt_points, &deopt_values);
    const false_index = try appendEdgeDeopt(graph, &initialized, header_block, outer_exit, allocator, &deopt_points, &deopt_values);
    const true_index = try appendEdgeDeopt(graph, &initialized, recovery_backedge, header_block, allocator, &deopt_points, &deopt_values);
    if (mode == .fused) for (topo.items) |block_id| {
        try block_deopts.append(allocator, .{
            .block = block_id,
            .deopt_index = try appendBlockEntryDeopt(
                graph,
                &initialized,
                block_id,
                allocator,
                &deopt_points,
                &deopt_values,
            ),
        });
    };
    for (topo.items) |block_id| {
        const block = plan.blocks[block_id];
        for (block.successors[0..block.successor_count]) |successor| if (successor == outer_exit) {
            try exit_deopts.append(allocator, .{
                .from = block_id,
                .deopt_index = try appendEdgeDeopt(graph, &initialized, block_id, outer_exit, allocator, &deopt_points, &deopt_values),
            });
        };
    }

    var region_blocks: std.ArrayListUnmanaged(LoopRegionBlock) = .empty;
    defer region_blocks.deinit(allocator);
    for (topo.items) |block_id| {
        const block = plan.blocks[block_id];
        var lowered = LoopRegionBlock{
            .block = block_id,
            .successor_count = block.successor_count,
            .steps = std.math.cast(u12, block.instruction_count) orelse return error.UnsupportedChunk,
            .entry_deopt_index = if (mode == .fused)
                regionBlockDeopt(block_deopts.items, block_id) orelse return error.UnsupportedChunk
            else
                entry_index,
        };
        var targets: [2]u32 = undefined;
        if (block.successor_count == 2) {
            const conditional = branchForBlock(graph.branches, block_id) orelse return error.UnsupportedChunk;
            lowered.condition = std.math.cast(u8, conditional.condition) orelse return error.UnsupportedChunk;
            targets[0] = conditional.false_block;
            targets[1] = conditional.true_block;
        } else {
            targets[0] = block.successors[0];
        }
        for (targets[0..block.successor_count], 0..) |target, target_index| {
            lowered.successors[target_index] = if (target == header_block)
                .{
                    .kind = .header,
                    .block = target,
                    .operations_block = regionEdgeOperations(edge_operations.items, block_id, target) orelse
                        return error.UnsupportedChunk,
                }
            else if (target == outer_exit)
                .{
                    .kind = .exit,
                    .block = target,
                    .deopt_index = regionExitDeopt(exit_deopts.items, block_id) orelse
                        return error.UnsupportedChunk,
                }
            else if (target < reachable.len and reachable[target]) lowered_target: {
                const is_backedge = mode == .fused and regionBackedge(plan, block_id, target);
                break :lowered_target .{
                    .kind = .block,
                    .block = target,
                    .operations_block = regionEdgeOperations(edge_operations.items, block_id, target) orelse
                        return error.UnsupportedChunk,
                    .moving_safepoint = is_backedge,
                    .safepoint_deopt_index = if (is_backedge)
                        regionBlockDeopt(block_deopts.items, target) orelse return error.UnsupportedChunk
                    else
                        0,
                };
            } else return error.UnsupportedChunk;
        }
        try region_blocks.append(allocator, lowered);
    }

    const owned_operations = try operations.toOwnedSlice(allocator);
    errdefer allocator.free(owned_operations);
    const owned_deopt_points = try deopt_points.toOwnedSlice(allocator);
    errdefer allocator.free(owned_deopt_points);
    const owned_deopt_values = try deopt_values.toOwnedSlice(allocator);
    errdefer allocator.free(owned_deopt_values);
    const owned_deopt_handlers = try ownRecoveryHandlers(allocator, graph.handler_states);
    errdefer allocator.free(owned_deopt_handlers);
    const stack_maps = try typedRecoveryStackMaps(allocator, owned_deopt_points, owned_deopt_values, &types);
    errdefer allocator.free(stack_maps);
    const owned_region_blocks = try region_blocks.toOwnedSlice(allocator);
    errdefer allocator.free(owned_region_blocks);

    var local_mask: u64 = 0;
    for (osr.imports[entry.first_import .. entry.first_import + entry.local_count]) |import| {
        if (import.source != .frame_slot or import.source_index >= 64 or import.destination >= required_numeric.len)
            return error.UnsupportedChunk;
        if (required_numeric[import.destination]) local_mask |= @as(u64, 1) << @intCast(import.source_index);
    }
    const header_steps = std.math.cast(u12, plan.blocks[header_block].instruction_count) orelse
        return error.UnsupportedChunk;
    const iteration_steps = std.math.cast(u12, maximum_steps) orelse return error.UnsupportedChunk;
    return .{
        .allocator = allocator,
        .operations = owned_operations,
        .result = 0,
        .branch = null,
        .side_exit = null,
        .side_exit_branch = .{
            .condition = @intCast(outer.condition),
            .entry_deopt_index = entry_index,
            .false_deopt_index = false_index,
            .true_deopt_index = true_index,
            .false_steps = header_steps,
            .true_steps = iteration_steps,
            .backedge_steps = iteration_steps,
        },
        .loop_region_blocks = owned_region_blocks,
        .loop_region_entry_operations_block = entry_operations_block,
        .loop_region_header_steps = header_steps,
        .loop_region_dynamic_checks = mode == .fused,
        .scratch_slots = @intCast(scratch_slots),
        .frame_slots = chunk.local_count,
        .required_numeric_slots = local_mask,
        .bytecode_steps = maximum_steps,
        .deopt_points = owned_deopt_points,
        .deopt_values = owned_deopt_values,
        .deopt_handlers = owned_deopt_handlers,
        .stack_maps = stack_maps,
        .osr = osr,
        .execution_block = header_block,
        .entry_enabled = false,
    };
}

fn lowerGeneralLoopOsr(chunk: *const bc.Chunk, plan: *const optimizer.Plan, allocator: std.mem.Allocator) !Program {
    return lowerRegionOsr(chunk, plan, allocator, .dag);
}

fn lowerFusedLoopOsr(chunk: *const bc.Chunk, plan: *const optimizer.Plan, allocator: std.mem.Allocator) !Program {
    return lowerRegionOsr(chunk, plan, allocator, .fused);
}

fn sumInstructionCounts(plan: *const optimizer.Plan, blocks: []const u32) error{UnsupportedChunk}!u32 {
    var total: u32 = 0;
    for (blocks) |block| {
        if (block >= plan.blocks.len) return error.UnsupportedChunk;
        total = std.math.add(u32, total, plan.blocks[block].instruction_count) catch return error.UnsupportedChunk;
    }
    return total;
}

fn primitiveStackMaps(allocator: std.mem.Allocator, deopt_count: usize) ![]jit.StackMap {
    const maps = try allocator.alloc(jit.StackMap, deopt_count);
    for (maps, 0..) |*map, index| map.* = .{
        .deopt_index = std.math.cast(u16, index) orelse {
            allocator.free(maps);
            return error.UnsupportedChunk;
        },
    };
    return maps;
}

fn recoveryStackMaps(
    allocator: std.mem.Allocator,
    points: []const jit.DeoptPoint,
    values: []const jit.RecoveryValue,
) ![]jit.StackMap {
    const maps = try primitiveStackMaps(allocator, points.len);
    errdefer allocator.free(maps);
    for (points, maps) |point, *map| {
        const first: usize = point.first_value;
        const count: usize = point.local_count + point.stack_count;
        if (first > values.len or count > values.len - first) return error.UnsupportedChunk;
        for (values[first .. first + count]) |recovery| switch (recovery.source) {
            .frame_slot => map.frame_pointer_slots |= @as(u64, 1) <<
                (std.math.cast(u6, recovery.index) orelse return error.UnsupportedChunk),
            .scratch_slot, .constant => {},
        };
        if (point.accumulator.source == .frame_slot)
            map.frame_pointer_slots |= @as(u64, 1) <<
                (std.math.cast(u6, point.accumulator.index) orelse return error.UnsupportedChunk);
    }
    return maps;
}

fn typedRecoveryStackMaps(
    allocator: std.mem.Allocator,
    points: []const jit.DeoptPoint,
    values: []const jit.RecoveryValue,
    types: *const [jit.numeric_scratch_capacity]ValueType,
) ![]jit.StackMap {
    const maps = try primitiveStackMaps(allocator, points.len);
    errdefer allocator.free(maps);
    for (points, maps) |point, *map| {
        const first: usize = point.first_value;
        const count: usize = point.local_count + point.stack_count;
        if (first > values.len or count > values.len - first) return error.UnsupportedChunk;
        for (values[first .. first + count]) |recovery| switch (recovery.source) {
            .frame_slot => map.frame_pointer_slots |= @as(u64, 1) <<
                (std.math.cast(u6, recovery.index) orelse return error.UnsupportedChunk),
            .scratch_slot => {
                if (recovery.index >= types.len) return error.UnsupportedChunk;
                if (types[recovery.index] == .other) map.scratch_pointer_slots |= @as(u64, 1) <<
                    (std.math.cast(u6, recovery.index) orelse return error.UnsupportedChunk);
            },
            .constant => {},
        };
        switch (point.accumulator.source) {
            .frame_slot => map.frame_pointer_slots |= @as(u64, 1) <<
                (std.math.cast(u6, point.accumulator.index) orelse return error.UnsupportedChunk),
            .scratch_slot => {
                if (point.accumulator.index >= types.len) return error.UnsupportedChunk;
                if (types[point.accumulator.index] == .other) map.scratch_pointer_slots |= @as(u64, 1) <<
                    (std.math.cast(u6, point.accumulator.index) orelse return error.UnsupportedChunk);
            },
            .constant => {},
        }
    }
    return maps;
}

fn ownRecoveryHandlers(allocator: std.mem.Allocator, handlers: []const optimizer.HandlerState) ![]jit.RecoveryHandler {
    const owned = try allocator.alloc(jit.RecoveryHandler, handlers.len);
    errdefer allocator.free(owned);
    for (handlers, owned) |handler, *recovery| recovery.* = .{
        .catch_ip = handler.catch_ip,
        .finally_ip = handler.finally_ip,
        .stack_depth = std.math.cast(u16, handler.stack_depth) orelse return error.UnsupportedChunk,
    };
    return owned;
}

fn appendPrimitiveLeaves(
    graph: *const optimizer.ValueGraph,
    allocator: std.mem.Allocator,
    operations: *std.ArrayListUnmanaged(Operation),
    types: *[jit.numeric_scratch_capacity]ValueType,
    initialized: *[jit.numeric_scratch_capacity]bool,
) !void {
    for (graph.nodes) |node| switch (node.kind) {
        .constant => {
            const constant = Value.fromRawBits(node.immediate);
            types[node.id] = if (constant.isNumber()) .number else if (constant.isBoolean()) .boolean else .other;
            try operations.append(allocator, .{
                .kind = .constant,
                .destination = @intCast(node.id),
                .block = optimizer.Block.none,
                .immediate = node.immediate,
            });
            initialized[node.id] = true;
        },
        .true, .false => {
            types[node.id] = .boolean;
            try operations.append(allocator, .{
                .kind = .constant,
                .destination = @intCast(node.id),
                .block = optimizer.Block.none,
                .immediate = Value.boolVal(node.kind == .true).rawBits(),
            });
            initialized[node.id] = true;
        },
        else => {},
    };
}

fn numericRequirements(graph: *const optimizer.ValueGraph) error{UnsupportedChunk}![jit.numeric_scratch_capacity]bool {
    var required: [jit.numeric_scratch_capacity]bool = @splat(false);
    for (graph.nodes) |node| switch (node.kind) {
        .add, .sub, .mul, .div, .lt, .le, .gt, .ge, .eq, .neq, .eq_strict, .neq_strict => {
            if (node.lhs >= required.len or node.rhs >= required.len) return error.UnsupportedChunk;
            required[node.lhs] = true;
            required[node.rhs] = true;
        },
        else => {},
    };

    // Numeric phi inputs require their matching source on every predecessor.
    // Iterate to a fixed point so loop-carried chains reach the OSR import.
    var changed = true;
    while (changed) {
        changed = false;
        for (graph.nodes, 0..) |node, node_index| {
            if (node.kind != .block_argument or !required[node.id]) continue;
            var ordinal: usize = 0;
            for (graph.nodes[0..node_index]) |previous|
                if (previous.kind == .block_argument and previous.block == node.block) {
                    ordinal += 1;
                };
            for (graph.edges) |edge| {
                if (edge.to != node.block or ordinal >= edge.argument_count) continue;
                const source = graph.edge_arguments[edge.first_argument + ordinal];
                if (source >= required.len) return error.UnsupportedChunk;
                if (!required[source]) {
                    required[source] = true;
                    changed = true;
                }
            }
        }
    }
    return required;
}

fn appendEdgeCopies(
    graph: *const optimizer.ValueGraph,
    from: u32,
    to: u32,
    operation_block: u32,
    allocator: std.mem.Allocator,
    operations: *std.ArrayListUnmanaged(Operation),
    types: *[jit.numeric_scratch_capacity]ValueType,
    initialized: *[jit.numeric_scratch_capacity]bool,
    required_numeric: *const [jit.numeric_scratch_capacity]bool,
    scratch_slots: *usize,
) !void {
    var found: ?optimizer.Edge = null;
    for (graph.edges) |edge| if (edge.from == from and edge.to == to) {
        if (found != null) return error.UnsupportedChunk;
        found = edge;
    };
    const edge = found orelse return error.UnsupportedChunk;
    var copies: [jit.numeric_scratch_capacity]CopyPair = undefined;
    var source_types: [jit.numeric_scratch_capacity]ValueType = undefined;
    var copy_count: usize = 0;
    for (graph.nodes) |node| if (node.kind == .block_argument and node.block == to) {
        if (copy_count >= edge.argument_count) return error.UnsupportedChunk;
        const source = graph.edge_arguments[edge.first_argument + copy_count];
        if (source >= initialized.len or !initialized[source]) return error.UnsupportedChunk;
        if (required_numeric[node.id] and types[source] != .number) return error.UnsupportedChunk;
        copies[copy_count] = .{
            .destination = @intCast(node.id),
            .source = @intCast(source),
        };
        source_types[copy_count] = types[source];
        copy_count += 1;
    };
    if (copy_count != edge.argument_count) return error.UnsupportedChunk;

    // Validate the complete incoming state before mutating type/initialization
    // state, then schedule the assignment with true parallel-copy semantics.
    // One-slot-per-SSA lowering makes current graphs acyclic, while the cycle
    // breaker keeps this boundary correct when scratch slots are coalesced.
    try appendParallelCopies(allocator, operations, operation_block, copies[0..copy_count], scratch_slots);
    for (copies[0..copy_count], source_types[0..copy_count]) |copy, source_type| {
        const destination = copy.destination;
        const incoming_type: ValueType = if (required_numeric[destination]) .number else source_type;
        if (initialized[destination] and types[destination] != incoming_type) {
            if (required_numeric[destination]) return error.UnsupportedChunk;
            types[destination] = .other;
        } else {
            types[destination] = incoming_type;
        }
        initialized[destination] = true;
    }
}

fn appendParallelCopies(
    allocator: std.mem.Allocator,
    operations: *std.ArrayListUnmanaged(Operation),
    operation_block: u32,
    copies: []const CopyPair,
    scratch_slots: *usize,
) !void {
    var pending: [jit.numeric_scratch_capacity]CopyPair = undefined;
    var pending_count: usize = 0;
    for (copies) |copy| {
        if (copy.destination >= jit.numeric_scratch_capacity or copy.source >= jit.numeric_scratch_capacity)
            return error.UnsupportedChunk;
        if (copy.destination == copy.source) continue;
        if (pending_count == pending.len) return error.UnsupportedChunk;
        for (pending[0..pending_count]) |existing| if (existing.destination == copy.destination)
            return error.UnsupportedChunk;
        pending[pending_count] = copy;
        pending_count += 1;
    }

    var temporary_slot: ?u8 = null;
    while (pending_count != 0) {
        var ready: ?usize = null;
        for (pending[0..pending_count], 0..) |copy, index| {
            var destination_is_live_source = false;
            for (pending[0..pending_count]) |other| if (other.source == copy.destination) {
                destination_is_live_source = true;
                break;
            };
            if (!destination_is_live_source) {
                ready = index;
                break;
            }
        }

        if (ready) |index| {
            const copy = pending[index];
            try operations.append(allocator, .{
                .kind = .copy,
                .destination = copy.destination,
                .block = operation_block,
                .lhs = copy.source,
            });
            for (index + 1..pending_count) |next| pending[next - 1] = pending[next];
            pending_count -= 1;
            continue;
        }

        const saved_destination = pending[0].destination;
        const temporary = temporary_slot orelse temporary: {
            if (scratch_slots.* >= jit.numeric_scratch_capacity) return error.UnsupportedChunk;
            const slot: u8 = @intCast(scratch_slots.*);
            scratch_slots.* += 1;
            temporary_slot = slot;
            break :temporary slot;
        };
        try operations.append(allocator, .{
            .kind = .copy,
            .destination = temporary,
            .block = operation_block,
            .lhs = saved_destination,
        });
        for (pending[0..pending_count]) |*copy| {
            if (copy.source == saved_destination) copy.source = temporary;
        }
    }
}

fn appendBlockOperations(
    graph: *const optimizer.ValueGraph,
    block: u32,
    imports_block_arguments: bool,
    allocator: std.mem.Allocator,
    operations: *std.ArrayListUnmanaged(Operation),
    types: *[jit.numeric_scratch_capacity]ValueType,
    initialized: *[jit.numeric_scratch_capacity]bool,
    required_numeric: *const [jit.numeric_scratch_capacity]bool,
) !void {
    for (graph.nodes) |node| {
        if (node.block != block) continue;
        switch (node.kind) {
            .block_argument => {
                if (!initialized[node.id] and !imports_block_arguments) return error.UnsupportedChunk;
                const expected: ValueType = if (required_numeric[node.id]) .number else .other;
                if (initialized[node.id] and required_numeric[node.id] and types[node.id] != .number)
                    return error.UnsupportedChunk;
                if (!initialized[node.id] or expected == .other) types[node.id] = expected;
                initialized[node.id] = true;
            },
            .constant, .true, .false => {}, // emitted once before control flow
            .add, .sub, .mul, .div, .lt, .le, .gt, .ge, .eq, .neq, .eq_strict, .neq_strict => {
                if (node.lhs >= graph.nodes.len or node.rhs >= graph.nodes.len or
                    types[node.lhs] != .number or types[node.rhs] != .number)
                    return error.UnsupportedChunk;
                const kind: OperationKind = switch (node.kind) {
                    .add => .add,
                    .sub => .sub,
                    .mul => .mul,
                    .div => .div,
                    .lt => .lt,
                    .le => .le,
                    .gt => .gt,
                    .ge => .ge,
                    .eq, .eq_strict => .eq,
                    .neq, .neq_strict => .neq,
                    else => unreachable,
                };
                types[node.id] = switch (kind) {
                    .lt, .le, .gt, .ge, .eq, .neq => .boolean,
                    else => .number,
                };
                try operations.append(allocator, .{
                    .kind = kind,
                    .destination = @intCast(node.id),
                    .block = block,
                    .lhs = @intCast(node.lhs),
                    .rhs = @intCast(node.rhs),
                });
                initialized[node.id] = true;
            },
            else => return error.UnsupportedChunk,
        }
    }
}

fn appendEdgeDeopt(
    graph: *const optimizer.ValueGraph,
    initialized: []const bool,
    from: u32,
    to: u32,
    allocator: std.mem.Allocator,
    points: *std.ArrayListUnmanaged(jit.DeoptPoint),
    values: *std.ArrayListUnmanaged(jit.RecoveryValue),
) !u16 {
    var found: ?optimizer.EdgeState = null;
    for (graph.edge_states) |state| if (state.from == from and state.to == to) {
        if (found != null) return error.UnsupportedChunk;
        found = state;
    };
    const state = found orelse return error.UnsupportedChunk;
    const index = std.math.cast(u16, points.items.len) orelse return error.UnsupportedChunk;
    const first_value: u32 = @intCast(values.items.len);
    const first: usize = state.first_value;
    const count: usize = state.local_count + state.stack_count;
    if (first > graph.edge_arguments.len or count > graph.edge_arguments.len - first) return error.UnsupportedChunk;
    const first_handler: usize = state.first_handler;
    const handler_count: usize = state.handler_count;
    if (first_handler > graph.handler_states.len or handler_count > graph.handler_states.len - first_handler)
        return error.UnsupportedChunk;
    for (graph.edge_arguments[first .. first + count]) |value| {
        if (value >= initialized.len or !initialized[value]) return error.UnsupportedChunk;
        try values.append(allocator, .{ .source = .scratch_slot, .index = @intCast(value) });
    }
    try points.append(allocator, .{
        .kind = .edge,
        .exit_ip = state.origin,
        .first_value = first_value,
        .local_count = std.math.cast(u16, state.local_count) orelse return error.UnsupportedChunk,
        .stack_count = std.math.cast(u16, state.stack_count) orelse return error.UnsupportedChunk,
        .first_handler = state.first_handler,
        .handler_count = std.math.cast(u16, state.handler_count) orelse return error.UnsupportedChunk,
        .accumulator = .{ .source = .constant, .bits = Value.undef().rawBits() },
    });
    return index;
}

fn appendBlockEntryDeopt(
    graph: *const optimizer.ValueGraph,
    initialized: []const bool,
    block: u32,
    allocator: std.mem.Allocator,
    points: *std.ArrayListUnmanaged(jit.DeoptPoint),
    values: *std.ArrayListUnmanaged(jit.RecoveryValue),
) !u16 {
    const state = blockEntryState(graph.frame_states, block) orelse return error.UnsupportedChunk;
    const index = std.math.cast(u16, points.items.len) orelse return error.UnsupportedChunk;
    const first_value: u32 = @intCast(values.items.len);
    const first: usize = state.first_value;
    const count: usize = state.local_count + state.stack_count;
    if (first > graph.frame_state_values.len or count > graph.frame_state_values.len - first)
        return error.UnsupportedChunk;
    const first_handler: usize = state.first_handler;
    const handler_count: usize = state.handler_count;
    if (first_handler > graph.handler_states.len or handler_count > graph.handler_states.len - first_handler)
        return error.UnsupportedChunk;
    for (graph.frame_state_values[first .. first + count]) |value| {
        if (value >= initialized.len or !initialized[value]) return error.UnsupportedChunk;
        try values.append(allocator, .{ .source = .scratch_slot, .index = @intCast(value) });
    }
    try points.append(allocator, .{
        .kind = .block_entry,
        .exit_ip = state.origin,
        .first_value = first_value,
        .local_count = std.math.cast(u16, state.local_count) orelse return error.UnsupportedChunk,
        .stack_count = std.math.cast(u16, state.stack_count) orelse return error.UnsupportedChunk,
        .first_handler = state.first_handler,
        .handler_count = std.math.cast(u16, state.handler_count) orelse return error.UnsupportedChunk,
        .accumulator = .{ .source = .constant, .bits = Value.undef().rawBits() },
    });
    return index;
}

fn blockEntryStateIndex(states: []const optimizer.FrameState, block: u32) error{UnsupportedChunk}!u16 {
    for (states, 0..) |state, index| if (state.kind == .block_entry and state.block == block)
        return std.math.cast(u16, index) orelse error.UnsupportedChunk;
    return error.UnsupportedChunk;
}

fn blockEntryState(states: []const optimizer.FrameState, block: u32) ?optimizer.FrameState {
    for (states) |state| if (state.kind == .block_entry and state.block == block) return state;
    return null;
}

fn returnForBlock(returns: []const optimizer.ReturnValue, block: u32) ?optimizer.ReturnValue {
    var found: ?optimizer.ReturnValue = null;
    for (returns) |ret| if (ret.block == block) {
        if (found != null) return null;
        found = ret;
    };
    return found;
}

fn resolveAlias(initial: optimizer.ValueId, aliases: [jit.numeric_scratch_capacity]optimizer.ValueId) error{UnsupportedChunk}!optimizer.ValueId {
    var current = initial;
    for (0..jit.numeric_scratch_capacity) |_| {
        if (current >= aliases.len) return error.UnsupportedChunk;
        if (aliases[current] == optimizer.ValueNode.none) return current;
        current = aliases[current];
    }
    return error.UnsupportedChunk;
}

pub fn compile(chunk: *const bc.Chunk) !jit.CompiledCode {
    var plan = try optimizer.build(chunk, std.heap.page_allocator);
    defer plan.deinit();
    var program = lower(chunk, &plan, std.heap.page_allocator) catch |err| switch (err) {
        error.UnsupportedChunk => lowerFusedLoopOsr(chunk, &plan, std.heap.page_allocator) catch |fused_err| switch (fused_err) {
            error.UnsupportedChunk => lowerLoopOsr(chunk, &plan, std.heap.page_allocator) catch |loop_err| switch (loop_err) {
                error.UnsupportedChunk => try lowerGeneralLoopOsr(chunk, &plan, std.heap.page_allocator),
                else => return loop_err,
            },
            else => return fused_err,
        },
        else => return err,
    };
    defer program.deinit();
    return compileAarch64(&program);
}

const LoopRegionPatch = struct {
    at: usize,
    target_block: u32,
};

fn emitLoopRegionTarget(
    assembler: *aarch64.Assembler,
    program: *const Program,
    target: LoopRegionTarget,
    loop_top: usize,
    entry_deopt_index: u16,
    patches: *std.ArrayListUnmanaged(LoopRegionPatch),
) !void {
    switch (target.kind) {
        .block => {
            try emitBlockOperations(assembler, program, target.operations_block);
            if (target.moving_safepoint) {
                try emitMovingSafepointPoll(
                    assembler,
                    target.safepoint_deopt_index,
                    program.deopt_points[target.safepoint_deopt_index].exit_ip,
                );
                if (program.observe_loop_backedges) try emitBackedgeObserver(assembler);
            }
            try patches.append(std.heap.page_allocator, .{
                .at = try assembler.branchPlaceholder(),
                .target_block = target.block,
            });
        },
        .header => {
            try emitBlockOperations(assembler, program, target.operations_block);
            try emitMovingSafepointPoll(
                assembler,
                entry_deopt_index,
                program.deopt_points[entry_deopt_index].exit_ip,
            );
            if (program.observe_loop_backedges) try emitBackedgeObserver(assembler);
            const backedge = try assembler.branchPlaceholder();
            try assembler.patchBranch(backedge, loop_top);
        },
        .exit => try emitSideExit(
            assembler,
            target.deopt_index,
            program.deopt_points[target.deopt_index].exit_ip,
        ),
    }
}

fn compileAarch64(program: *const Program) !jit.CompiledCode {
    if (!jit.supported or builtin.cpu.arch != .aarch64) return error.UnsupportedTarget;
    var memory = try jit.CodeMemory.init(
        @as(usize, program.operations.len) * 64 + @as(usize, program.loop_region_blocks.len) * 256 + 2048,
    );
    errdefer memory.deinit();
    var assembler = aarch64.Assembler.init(memory.writableBytes());
    try assembler.moveRegister64(12, 0); // stable NativeFrame
    try assembler.load64(13, 12, frameOffset("slots"));
    try assembler.load64(14, 12, frameOffset("scratch"));
    try emitInvalidationPoll(&assembler);

    for (program.operations) |operation| if (operation.block == optimizer.Block.none)
        try emitOperation(&assembler, program, operation);
    if (program.side_exit) |side_exit| {
        for (program.operations) |operation| if ((program.deterministic_path and operation.block != optimizer.Block.none) or
            (!program.deterministic_path and operation.block == program.execution_block))
            try emitOperation(&assembler, program, operation);
        const runtime_steps = try runtimeOperationSteps(program);
        if (runtime_steps > side_exit.steps) return error.UnsupportedChunk;
        const remaining_steps: u12 = @intCast(side_exit.steps - runtime_steps);
        if (remaining_steps != 0) try emitStepIncrement(&assembler, remaining_steps);
        try emitSideExit(&assembler, side_exit.deopt_index, program.deopt_points[side_exit.deopt_index].exit_ip);
    } else if (program.side_exit_branch) |branch| if (branch.entry_deopt_index) |entry_deopt_index| {
        try assembler.load64(15, 12, frameOffset("steps_until_checkpoint"));
        try assembler.load64(16, 12, frameOffset("steps_until_budget"));
        try assembler.movImmediate32(8, moving_safepoint_backedge_interval);
        const loop_top = assembler.position();
        const invalidated = try emitInvalidationSideExitPoll(&assembler);
        try assembler.compareImmediate64(15, branch.true_steps);
        const checkpoint_exit = try assembler.branchConditionPlaceholder(.ls);
        try assembler.compareImmediate64(16, branch.true_steps);
        const budget_exit = try assembler.branchConditionPlaceholder(.lo);
        for (program.operations) |operation| if (operation.block == program.execution_block)
            try emitOperation(&assembler, program, operation);
        if (program.loop_region_blocks.len != 0) {
            try emitStepIncrement(&assembler, program.loop_region_header_steps);
            try assembler.subtractImmediate64(15, 15, program.loop_region_header_steps);
            try assembler.subtractImmediate64(16, 16, program.loop_region_header_steps);
        }
        try assembler.load64(9, 14, try slotOffset(branch.condition));
        try assembler.movImmediate64(10, Value.boolVal(false).rawBits());
        try assembler.compareRegister64(9, 10);
        const false_jump = try assembler.branchConditionPlaceholder(.eq);
        if (program.loop_region_blocks.len != 0) {
            var patches: std.ArrayListUnmanaged(LoopRegionPatch) = .empty;
            defer patches.deinit(std.heap.page_allocator);
            const block_positions = try std.heap.page_allocator.alloc(usize, program.loop_region_blocks.len);
            defer std.heap.page_allocator.free(block_positions);

            try emitBlockOperations(&assembler, program, program.loop_region_entry_operations_block);
            for (program.loop_region_blocks, 0..) |region, region_index| {
                block_positions[region_index] = assembler.position();
                var region_invalidated: ?usize = null;
                var region_checkpoint: ?usize = null;
                var region_budget: ?usize = null;
                if (program.loop_region_dynamic_checks) {
                    region_invalidated = try emitInvalidationSideExitPoll(&assembler);
                    try assembler.compareImmediate64(15, region.steps);
                    region_checkpoint = try assembler.branchConditionPlaceholder(.ls);
                    try assembler.compareImmediate64(16, region.steps);
                    region_budget = try assembler.branchConditionPlaceholder(.lo);
                }
                try emitBlockOperations(&assembler, program, region.block);
                if (region.steps != 0) {
                    try emitStepIncrement(&assembler, region.steps);
                    try assembler.subtractImmediate64(15, 15, region.steps);
                    try assembler.subtractImmediate64(16, 16, region.steps);
                }
                if (region.successor_count == 1) {
                    try emitLoopRegionTarget(
                        &assembler,
                        program,
                        region.successors[0],
                        loop_top,
                        entry_deopt_index,
                        &patches,
                    );
                } else {
                    try assembler.load64(9, 14, try slotOffset(region.condition));
                    try assembler.movImmediate64(10, Value.boolVal(false).rawBits());
                    try assembler.compareRegister64(9, 10);
                    const false_edge = try assembler.branchConditionPlaceholder(.eq);
                    try emitLoopRegionTarget(
                        &assembler,
                        program,
                        region.successors[1],
                        loop_top,
                        entry_deopt_index,
                        &patches,
                    );
                    try assembler.patchConditionBranch(false_edge, assembler.position());
                    try emitLoopRegionTarget(
                        &assembler,
                        program,
                        region.successors[0],
                        loop_top,
                        entry_deopt_index,
                        &patches,
                    );
                }
                if (program.loop_region_dynamic_checks) {
                    const region_poll_exit = assembler.position();
                    try assembler.patchConditionBranch(region_invalidated.?, region_poll_exit);
                    try assembler.patchConditionBranch(region_checkpoint.?, region_poll_exit);
                    try assembler.patchConditionBranch(region_budget.?, region_poll_exit);
                    try emitSideExit(
                        &assembler,
                        region.entry_deopt_index,
                        program.deopt_points[region.entry_deopt_index].exit_ip,
                    );
                }
            }
            for (patches.items) |patch| {
                var target_position: ?usize = null;
                for (program.loop_region_blocks, block_positions) |region, position| {
                    if (region.block != patch.target_block) continue;
                    if (target_position != null) return error.UnsupportedChunk;
                    target_position = position;
                }
                try assembler.patchBranch(patch.at, target_position orelse return error.UnsupportedChunk);
            }
        } else {
            for (program.loop_exit_guards) |guard| {
                try emitBlockOperations(&assembler, program, guard.entry_block);
                try assembler.load64(9, 14, try slotOffset(guard.condition));
                try assembler.movImmediate64(10, Value.boolVal(false).rawBits());
                try assembler.compareRegister64(9, 10);
                const continue_jump = try assembler.branchConditionPlaceholder(
                    if (guard.exit_on_true) .eq else .ne,
                );
                if (guard.exit_from != guard.entry_block)
                    try emitBlockOperations(&assembler, program, guard.exit_block);
                try emitStepIncrement(&assembler, guard.exit_steps);
                try emitSideExit(
                    &assembler,
                    guard.exit_deopt_index,
                    program.deopt_points[guard.exit_deopt_index].exit_ip,
                );
                try assembler.patchConditionBranch(continue_jump, assembler.position());
            }
            for (program.loop_latch_guards) |guard| {
                try emitBlockOperations(&assembler, program, guard.entry_block);
                try assembler.load64(9, 14, try slotOffset(guard.condition));
                try assembler.movImmediate64(10, Value.boolVal(false).rawBits());
                try assembler.compareRegister64(9, 10);
                const continue_jump = try assembler.branchConditionPlaceholder(
                    if (guard.backedge_on_true) .eq else .ne,
                );
                try emitBlockOperations(&assembler, program, guard.operations_block);
                try emitStepIncrement(&assembler, guard.backedge_steps);
                try assembler.subtractImmediate64(15, 15, guard.backedge_steps);
                try assembler.subtractImmediate64(16, 16, guard.backedge_steps);
                try emitMovingSafepointPoll(&assembler, entry_deopt_index, program.deopt_points[entry_deopt_index].exit_ip);
                if (program.observe_loop_backedges) try emitBackedgeObserver(&assembler);
                const guarded_backedge = try assembler.branchPlaceholder();
                try assembler.patchBranch(guarded_backedge, loop_top);
                try assembler.patchConditionBranch(continue_jump, assembler.position());
            }
            if (program.loop_branches.len != 0) {
                try emitStepIncrement(&assembler, branch.loop_prefix_steps);
                try assembler.subtractImmediate64(15, 15, branch.loop_prefix_steps);
                try assembler.subtractImmediate64(16, 16, branch.loop_prefix_steps);
                for (program.loop_branches) |segment| {
                    try emitBlockOperations(&assembler, program, segment.entry_block);
                    try assembler.load64(9, 14, try slotOffset(segment.condition));
                    try assembler.movImmediate64(10, Value.boolVal(false).rawBits());
                    try assembler.compareRegister64(9, 10);
                    const segment_false_jump = try assembler.branchConditionPlaceholder(.eq);

                    try emitBlockOperations(&assembler, program, segment.true_block);
                    if (segment.emit_merge) if (segment.merge_block) |merge_block|
                        try emitBlockOperations(&assembler, program, merge_block);
                    try emitStepIncrement(&assembler, segment.true_steps);
                    try assembler.subtractImmediate64(15, 15, segment.true_steps);
                    try assembler.subtractImmediate64(16, 16, segment.true_steps);
                    const true_join = try assembler.branchPlaceholder();

                    try assembler.patchConditionBranch(segment_false_jump, assembler.position());
                    try emitBlockOperations(&assembler, program, segment.false_block);
                    if (segment.emit_merge) if (segment.merge_block) |merge_block|
                        try emitBlockOperations(&assembler, program, merge_block);
                    try emitStepIncrement(&assembler, segment.false_steps);
                    try assembler.subtractImmediate64(15, 15, segment.false_steps);
                    try assembler.subtractImmediate64(16, 16, segment.false_steps);
                    try assembler.patchBranch(true_join, assembler.position());
                }
                try emitMovingSafepointPoll(&assembler, entry_deopt_index, program.deopt_points[entry_deopt_index].exit_ip);
                if (program.observe_loop_backedges) try emitBackedgeObserver(&assembler);
                const backedge = try assembler.branchPlaceholder();
                try assembler.patchBranch(backedge, loop_top);
            } else {
                try emitBlockOperations(&assembler, program, branch.true_block.?);
                try emitStepIncrement(&assembler, branch.backedge_steps);
                try assembler.subtractImmediate64(15, 15, branch.backedge_steps);
                try assembler.subtractImmediate64(16, 16, branch.backedge_steps);
                try emitMovingSafepointPoll(&assembler, entry_deopt_index, program.deopt_points[entry_deopt_index].exit_ip);
                if (program.observe_loop_backedges) try emitBackedgeObserver(&assembler);
                const backedge = try assembler.branchPlaceholder();
                try assembler.patchBranch(backedge, loop_top);
            }
        }

        try assembler.patchConditionBranch(false_jump, assembler.position());
        if (program.loop_region_blocks.len == 0) try emitStepIncrement(&assembler, branch.false_steps);
        try emitSideExit(&assembler, branch.false_deopt_index, program.deopt_points[branch.false_deopt_index].exit_ip);

        const poll_exit = assembler.position();
        try assembler.patchConditionBranch(invalidated, poll_exit);
        try assembler.patchConditionBranch(checkpoint_exit, poll_exit);
        try assembler.patchConditionBranch(budget_exit, poll_exit);
        try emitSideExit(&assembler, entry_deopt_index, program.deopt_points[entry_deopt_index].exit_ip);
    } else {
        for (program.operations) |operation| if (operation.block == program.execution_block)
            try emitOperation(&assembler, program, operation);
        try assembler.load64(9, 14, try slotOffset(branch.condition));
        try assembler.movImmediate64(10, Value.boolVal(false).rawBits());
        try assembler.compareRegister64(9, 10);
        const false_jump = try assembler.branchConditionPlaceholder(.eq);
        if (branch.true_block) |block| for (program.operations) |operation|
            if (operation.block == block) try emitOperation(&assembler, program, operation);
        try emitStepIncrement(&assembler, branch.true_steps);
        try emitSideExit(&assembler, branch.true_deopt_index, program.deopt_points[branch.true_deopt_index].exit_ip);
        try assembler.patchConditionBranch(false_jump, assembler.position());
        try emitStepIncrement(&assembler, branch.false_steps);
        try emitSideExit(&assembler, branch.false_deopt_index, program.deopt_points[branch.false_deopt_index].exit_ip);
    } else if (program.branch) |branch| {
        for (program.operations) |operation| if (operation.block == program.execution_block)
            try emitOperation(&assembler, program, operation);
        try assembler.load64(9, 14, try slotOffset(branch.condition));
        try assembler.movImmediate64(10, Value.boolVal(false).rawBits());
        try assembler.compareRegister64(9, 10);
        const false_jump = try assembler.branchConditionPlaceholder(.eq);
        try emitBlockOperations(&assembler, program, branch.true_block);
        try assembler.load64(9, 14, try slotOffset(branch.true_result));
        const done = try assembler.branchPlaceholder();
        try assembler.patchConditionBranch(false_jump, assembler.position());
        try emitBlockOperations(&assembler, program, branch.false_block);
        try assembler.load64(9, 14, try slotOffset(branch.false_result));
        try assembler.patchBranch(done, assembler.position());
    } else {
        for (program.operations) |operation| if ((program.deterministic_path and operation.block != optimizer.Block.none) or
            (!program.deterministic_path and operation.block == program.execution_block))
            try emitOperation(&assembler, program, operation);
        try assembler.load64(9, 14, try slotOffset(program.result));
    }
    if (program.side_exit == null and program.side_exit_branch == null) {
        try assembler.store64(9, 12, frameOffset("result_bits"));
        const runtime_steps = try runtimeOperationSteps(program);
        if (runtime_steps > program.bytecode_steps) return error.UnsupportedChunk;
        const suffix_steps = std.math.cast(u12, program.bytecode_steps - runtime_steps) orelse
            return error.UnsupportedChunk;
        if (program.native_operations.len != 0 and suffix_steps != 0)
            try emitStepIncrement(&assembler, suffix_steps);
        try assembler.movImmediate32(0, @backingInt(jit.ExitStatus.complete));
        try assembler.ret();
    }
    try memory.publish(assembler.bytes().len);
    const deopt = try jit.DeoptMetadata.create(
        std.heap.page_allocator,
        program.deopt_points,
        program.deopt_values,
        program.deopt_handlers,
    );
    errdefer deopt.destroy();
    const stack_maps = try jit.StackMapMetadata.create(std.heap.page_allocator, program.stack_maps);
    errdefer stack_maps.destroy();
    const native_operations = if (program.native_operations.len != 0)
        try jit.NativeOperationMetadata.createWithNames(
            std.heap.page_allocator,
            program.native_operations,
            program.native_exceptional_targets,
            program.native_operation_names,
        )
    else
        null;
    errdefer if (native_operations) |metadata| metadata.destroy();
    const osr = if (program.osr) |metadata|
        try jit.OsrMetadata.create(std.heap.page_allocator, metadata.entries, metadata.imports)
    else
        null;
    errdefer if (osr) |metadata| metadata.destroy();

    return .{
        .memory = memory,
        .entry = @ptrCast(@alignCast(memory.executableBytes().ptr)),
        .kind = .optimizer,
        .bytecode_steps = program.bytecode_steps,
        .frame_slots = program.frame_slots,
        .required_numeric_slots = program.required_numeric_slots,
        .max_stack_depth = program.scratch_slots,
        .deopt = deopt,
        .stack_maps = stack_maps,
        .native_operations = native_operations,
        .osr = osr,
        .entry_enabled = program.entry_enabled,
        .manages_steps = program.side_exit != null or program.side_exit_branch != null or
            program.native_operations.len != 0,
        .has_side_exits = program.side_exit != null or program.side_exit_branch != null or
            programHasExceptionalOperations(program),
    };
}

fn programHasExceptionalOperations(program: *const Program) bool {
    for (program.native_operations) |descriptor|
        if (descriptor.exceptional_target != jit.NativeOperationDescriptor.none) return true;
    return false;
}

fn runtimeOperationSteps(program: *const Program) !u32 {
    var steps: u32 = 0;
    for (program.operations) |operation| if (operation.kind == .runtime_operation) {
        if (operation.immediate >= program.native_operations.len) return error.UnsupportedChunk;
        steps = std.math.add(
            u32,
            steps,
            program.native_operations[operation.immediate].step_delta,
        ) catch return error.UnsupportedChunk;
    };
    return steps;
}

fn emitBlockOperations(assembler: *aarch64.Assembler, program: *const Program, block: u32) !void {
    for (program.operations) |operation| if (operation.block == block)
        try emitOperation(assembler, program, operation);
}

fn emitOperation(assembler: *aarch64.Assembler, program: *const Program, operation: Operation) !void {
    switch (operation.kind) {
        .copy => {
            try assembler.load64(9, 14, try slotOffset(operation.lhs));
            try assembler.store64(9, 14, try slotOffset(operation.destination));
        },
        .argument => {
            try assembler.load64(9, 13, try slotOffset(operation.immediate));
            try assembler.store64(9, 14, try slotOffset(operation.destination));
        },
        .constant => {
            try assembler.movImmediate64(9, operation.immediate);
            try assembler.store64(9, 14, try slotOffset(operation.destination));
        },
        .add, .sub, .mul, .div => {
            try loadNumericOperands(assembler, operation);
            try assembler.floatBinary64(switch (operation.kind) {
                .add => .add,
                .sub => .sub,
                .mul => .mul,
                .div => .div,
                else => unreachable,
            }, 0, 0, 1);
            try emitCanonicalNumber(assembler, 9, 0);
            try assembler.store64(9, 14, try slotOffset(operation.destination));
        },
        .lt, .le, .gt, .ge, .eq, .neq => {
            try loadNumericOperands(assembler, operation);
            try assembler.compareFloat64(0, 1);
            try assembler.conditionalSet32(9, comparisonCondition(operation.kind));
            try assembler.movImmediate64(10, Value.boolVal(false).rawBits());
            try assembler.addRegister64(9, 10, 9);
            try assembler.store64(9, 14, try slotOffset(operation.destination));
        },
        .runtime_operation => try emitRuntimeOperation(assembler, program, operation),
    }
}

fn emitRuntimeOperation(
    assembler: *aarch64.Assembler,
    program: *const Program,
    operation: Operation,
) !void {
    if (operation.immediate >= program.native_operations.len) return error.UnsupportedChunk;
    const descriptor = program.native_operations[operation.immediate];
    if (descriptor.first_input != operation.lhs or descriptor.input_count == 0 or
        descriptor.step_delta == 0 or (descriptor.exceptional_target != jit.NativeOperationDescriptor.none and
        descriptor.exceptional_target >= program.native_exceptional_targets.len))
        return error.UnsupportedChunk;

    try assembler.movImmediate64(9, descriptor.origin);
    try assembler.store64(9, 12, frameOffset("exit_ip"));
    try assembler.movImmediate64(9, descriptor.deopt_index);
    try assembler.store64(9, 12, frameOffset("deopt_index"));
    try assembler.movImmediate64(9, operation.immediate);
    try assembler.store64(9, 12, frameOffset("operation_detail"));
    try emitStepIncrement(
        assembler,
        std.math.cast(u12, descriptor.step_delta) orelse return error.UnsupportedChunk,
    );

    try assembler.load64(17, 12, frameOffset("operation"));
    try assembler.compareImmediate64(17, 0);
    const absent = try assembler.branchConditionPlaceholder(.eq);
    try assembler.pushPair(8, 12);
    try assembler.pushPair(13, 14);
    try assembler.pushPair(15, 16);
    try assembler.pushPair(17, 30);
    try assembler.moveRegister64(0, 12);
    try assembler.movImmediate32(1, @intCast(operation.immediate));
    try assembler.branchLinkRegister(17);
    try assembler.popPair(17, 30);
    try assembler.popPair(15, 16);
    try assembler.popPair(13, 14);
    try assembler.popPair(8, 12);

    try assembler.compareImmediate64(0, @backingInt(jit.NativeOperationStatus.value));
    const non_value = try assembler.branchConditionPlaceholder(.ne);
    try assembler.load64(9, 12, frameOffset("operation_value_bits"));
    try assembler.store64(9, 14, try slotOffset(operation.destination));
    const done = try assembler.branchPlaceholder();

    try assembler.patchConditionBranch(non_value, assembler.position());
    try assembler.compareImmediate64(0, @backingInt(jit.NativeOperationStatus.catchable_exception));
    const not_throw = try assembler.branchConditionPlaceholder(.ne);
    try assembler.movImmediate32(
        0,
        @intCast(@backingInt(if (descriptor.exceptional_target == jit.NativeOperationDescriptor.none)
            jit.ExitStatus.throw
        else
            jit.ExitStatus.operation_exception)),
    );
    try assembler.ret();

    try assembler.patchConditionBranch(not_throw, assembler.position());
    try assembler.compareImmediate64(0, @backingInt(jit.NativeOperationStatus.invalidated));
    const trap = try assembler.branchConditionPlaceholder(.ne);
    try assembler.movImmediate32(0, @backingInt(jit.ExitStatus.invalidated));
    try assembler.ret();

    try assembler.patchConditionBranch(trap, assembler.position());
    try assembler.compareImmediate64(0, @backingInt(jit.NativeOperationStatus.out_of_memory));
    const operation_trap = try assembler.branchConditionPlaceholder(.ne);
    try assembler.movImmediate32(0, @backingInt(jit.ExitStatus.stop));
    try assembler.ret();
    const trap_position = assembler.position();
    try assembler.patchConditionBranch(absent, trap_position);
    try assembler.patchConditionBranch(operation_trap, trap_position);
    try assembler.movImmediate32(0, @backingInt(jit.ExitStatus.operation_trap));
    try assembler.ret();
    try assembler.patchBranch(done, assembler.position());
}

fn emitStepIncrement(assembler: *aarch64.Assembler, steps: u12) !void {
    try assembler.load64(9, 12, frameOffset("steps"));
    try assembler.load64(10, 9, 0);
    try assembler.addImmediate64(10, 10, steps);
    try assembler.store64(10, 9, 0);
}

fn emitInvalidationPoll(assembler: *aarch64.Assembler) !void {
    try assembler.load64(9, 12, frameOffset("invalidation_generation"));
    try assembler.compareImmediate64(9, 0);
    const no_owner = try assembler.branchConditionPlaceholder(.eq);
    try assembler.load64(10, 9, 0);
    try assembler.load64(11, 12, frameOffset("expected_invalidation_generation"));
    try assembler.compareRegister64(10, 11);
    const current = try assembler.branchConditionPlaceholder(.eq);
    try assembler.movImmediate32(0, @backingInt(jit.ExitStatus.invalidated));
    try assembler.ret();
    try assembler.patchConditionBranch(no_owner, assembler.position());
    try assembler.patchConditionBranch(current, assembler.position());
}

fn emitInvalidationSideExitPoll(assembler: *aarch64.Assembler) !usize {
    try assembler.load64(9, 12, frameOffset("invalidation_generation"));
    try assembler.compareImmediate64(9, 0);
    const no_owner = try assembler.branchConditionPlaceholder(.eq);
    try assembler.load64(10, 9, 0);
    try assembler.load64(11, 12, frameOffset("expected_invalidation_generation"));
    try assembler.compareRegister64(10, 11);
    const invalidated = try assembler.branchConditionPlaceholder(.ne);
    try assembler.patchConditionBranch(no_owner, assembler.position());
    return invalidated;
}

fn emitMovingSafepointPoll(assembler: *aarch64.Assembler, deopt_index: u16, exit_ip: u32) !void {
    try assembler.subtractImmediateSetFlags64(8, 8, 1);
    const not_due = try assembler.branchConditionPlaceholder(.ne);
    try assembler.movImmediate32(8, moving_safepoint_backedge_interval);
    try assembler.load64(17, 12, frameOffset("moving_safepoint"));
    try assembler.compareImmediate64(17, 0);
    const absent = try assembler.branchConditionPlaceholder(.eq);

    // Publish the exact loop-header state before entering Zig. All generated
    // temporaries are dead here; the callback may rewrite selected frame and
    // scratch words in place, after which the next iteration reloads them.
    try assembler.movImmediate64(9, exit_ip);
    try assembler.store64(9, 12, frameOffset("exit_ip"));
    try assembler.movImmediate64(9, deopt_index);
    try assembler.store64(9, 12, frameOffset("deopt_index"));
    try assembler.pushPair(8, 12);
    try assembler.pushPair(13, 14);
    try assembler.pushPair(15, 16);
    try assembler.pushPair(17, 30);
    try assembler.moveRegister64(0, 12);
    try assembler.branchLinkRegister(17);
    try assembler.popPair(17, 30);
    try assembler.popPair(15, 16);
    try assembler.popPair(13, 14);
    try assembler.popPair(8, 12);

    const done = assembler.position();
    try assembler.patchConditionBranch(absent, done);
    try assembler.patchConditionBranch(not_due, done);
}

fn emitBackedgeObserver(assembler: *aarch64.Assembler) !void {
    try assembler.load64(17, 12, frameOffset("loop_backedge_observer"));
    try assembler.compareImmediate64(17, 0);
    const absent = try assembler.branchConditionPlaceholder(.eq);
    try assembler.movImmediate32(9, 1);
    try assembler.storeRelease64(9, 17);
    try assembler.patchConditionBranch(absent, assembler.position());
}

fn emitSideExit(assembler: *aarch64.Assembler, deopt_index: u16, exit_ip: u32) !void {
    try assembler.movImmediate64(9, exit_ip);
    try assembler.store64(9, 12, frameOffset("exit_ip"));
    try assembler.movImmediate64(9, deopt_index);
    try assembler.store64(9, 12, frameOffset("deopt_index"));
    try assembler.movImmediate32(0, @backingInt(jit.ExitStatus.side_exit));
    try assembler.ret();
}

fn loadNumericOperands(assembler: *aarch64.Assembler, operation: Operation) !void {
    try assembler.load64(9, 14, try slotOffset(operation.lhs));
    try assembler.load64(10, 14, try slotOffset(operation.rhs));
    try assembler.moveFloatFromRegister64(0, 9);
    try assembler.moveFloatFromRegister64(1, 10);
}

fn emitCanonicalNumber(assembler: *aarch64.Assembler, register: u5, float_register: u5) !void {
    try assembler.moveRegisterFromFloat64(register, float_register);
    try assembler.compareFloat64(float_register, float_register);
    const ordered = try assembler.branchConditionPlaceholder(.vc);
    try assembler.movImmediate64(register, Value.num(std.math.nan(f64)).rawBits());
    try assembler.patchConditionBranch(ordered, assembler.position());
}

fn comparisonCondition(kind: OperationKind) aarch64.Condition {
    return switch (kind) {
        .lt => .mi,
        .le => .ls,
        .gt => .gt,
        .ge => .ge,
        .eq => .eq,
        .neq => .ne,
        else => unreachable,
    };
}

fn slotOffset(index: anytype) error{UnsupportedChunk}!u15 {
    const value: usize = @intCast(index);
    return std.math.cast(u15, value * @sizeOf(u64)) orelse error.UnsupportedChunk;
}

fn frameOffset(comptime field: []const u8) u15 {
    return @intCast(@offsetOf(jit.NativeFrame, field));
}

fn makeExactBranchChunk(allocator: std.mem.Allocator) !bc.Chunk {
    var chunk = bc.Chunk.init(allocator);
    chunk.param_count = 2;
    chunk.local_count = 2;
    const ten = try chunk.addConst(Value.num(10));
    const twenty = try chunk.addConst(Value.num(20));
    _ = try chunk.emit(.load_local, 0);
    _ = try chunk.emit(.load_local, 1);
    _ = try chunk.emit(.lt, 0);
    _ = try chunk.emit(.jump_if_false, 8);
    _ = try chunk.emit(.load_local, 0);
    _ = try chunk.emit(.load_const, ten);
    _ = try chunk.emit(.add, 0);
    _ = try chunk.emit(.ret, 0);
    _ = try chunk.emit(.load_local, 1);
    _ = try chunk.emit(.load_const, twenty);
    _ = try chunk.emit(.add, 0);
    _ = try chunk.emit(.ret, 0);
    return chunk;
}

test "optimizer schedules edge assignments as parallel copies" {
    var operations: std.ArrayListUnmanaged(Operation) = .empty;
    defer operations.deinit(std.testing.allocator);
    var scratch_slots: usize = 3;
    try appendParallelCopies(
        std.testing.allocator,
        &operations,
        7,
        &.{
            .{ .destination = 0, .source = 1 },
            .{ .destination = 1, .source = 0 },
            .{ .destination = 2, .source = 1 },
        },
        &scratch_slots,
    );

    try std.testing.expectEqual(@as(usize, 4), scratch_slots);
    try std.testing.expectEqual(@as(usize, 4), operations.items.len);
    var values = [_]u64{ 10, 20, 30, 0 };
    for (operations.items) |operation| {
        try std.testing.expectEqual(OperationKind.copy, operation.kind);
        try std.testing.expectEqual(@as(u32, 7), operation.block);
        values[operation.destination] = values[operation.lhs];
    }
    try std.testing.expectEqualSlices(u64, &.{ 20, 10, 20 }, values[0..3]);
}

test "optimizer lowerer produces portable guarded numeric operations" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var chunk = bc.Chunk.init(arena.allocator());
    chunk.param_count = 2;
    chunk.local_count = 2;
    const two = try chunk.addConst(Value.num(2));
    _ = try chunk.emit(.load_local, 0);
    _ = try chunk.emit(.load_local, 1);
    _ = try chunk.emit(.add, 0);
    _ = try chunk.emit(.load_const, two);
    _ = try chunk.emit(.mul, 0);
    _ = try chunk.emit(.ret, 0);
    var plan = try optimizer.build(&chunk, std.testing.allocator);
    defer plan.deinit();
    var program = try lower(&chunk, &plan, std.testing.allocator);
    defer program.deinit();

    try std.testing.expectEqual(@as(u64, 0b11), program.required_numeric_slots);
    try std.testing.expectEqual(@as(u32, 2), program.frame_slots);
    try std.testing.expectEqual(@as(u32, 6), program.bytecode_steps);
    try std.testing.expect(program.branch == null);
    try std.testing.expectEqual(@as(usize, 2), program.deopt_points.len);
    try std.testing.expectEqual(program.deopt_points.len, program.stack_maps.len);
    for (program.stack_maps) |map| {
        try std.testing.expectEqual(@as(u64, 0), map.frame_pointer_slots);
        try std.testing.expectEqual(@as(u64, 0), map.scratch_pointer_slots);
    }
    try std.testing.expectEqual(jit.DeoptPointKind.block_entry, program.deopt_points[0].kind);
    try std.testing.expectEqual(jit.DeoptPointKind.return_, program.deopt_points[1].kind);
    try std.testing.expectEqual(OperationKind.mul, program.operations[program.operations.len - 1].kind);
}

test "optimizer lowering publishes frame-state handlers" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var chunk = bc.Chunk.init(arena.allocator());
    const value = try chunk.addConst(Value.num(7));
    _ = try chunk.emit(.load_const, value);
    _ = try chunk.emit(.ret, 0);
    var plan = try optimizer.build(&chunk, std.testing.allocator);
    defer plan.deinit();
    std.testing.allocator.free(plan.graph.handler_states);
    plan.graph.handler_states = try std.testing.allocator.dupe(optimizer.HandlerState, &.{.{
        .catch_ip = 1,
        .finally_ip = jit.RecoveryHandler.none,
        .stack_depth = 0,
    }});
    for (plan.graph.frame_states) |*state| {
        state.first_handler = 0;
        state.handler_count = 1;
    }

    var program = try lower(&chunk, &plan, std.testing.allocator);
    defer program.deinit();
    try std.testing.expectEqual(@as(usize, 1), program.deopt_handlers.len);
    try std.testing.expectEqual(@as(u32, 1), program.deopt_handlers[0].catch_ip);
    try std.testing.expectEqual(jit.RecoveryHandler.none, program.deopt_handlers[0].finally_ip);
    for (program.deopt_points) |point| {
        try std.testing.expectEqual(@as(u32, 0), point.first_handler);
        try std.testing.expectEqual(@as(u16, 1), point.handler_count);
    }
}

test "optimizer lowering executes a deterministic catch path natively" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var chunk = bc.Chunk.init(arena.allocator());
    const seven = try chunk.addConst(Value.num(7));
    const one = try chunk.addConst(Value.num(1));
    _ = try chunk.emitAB(.push_handler, 4, std.math.maxInt(u32));
    _ = try chunk.emit(.load_const, seven);
    _ = try chunk.emit(.throw_op, 0);
    _ = try chunk.emit(.ret_undef, 0);
    _ = try chunk.emit(.load_const, one);
    _ = try chunk.emit(.add, 0);
    _ = try chunk.emit(.ret, 0);
    var plan = try optimizer.build(&chunk, std.testing.allocator);
    defer plan.deinit();
    var program = try lower(&chunk, &plan, std.testing.allocator);
    defer program.deinit();

    try std.testing.expect(program.side_exit == null);
    try std.testing.expect(program.deterministic_path);
    try std.testing.expectEqual(@as(u32, 6), program.bytecode_steps);
    var saw_throw = false;
    for (program.deopt_points) |point| if (point.kind == .throw_) {
        try std.testing.expectEqual(@as(u32, 2), point.exit_ip);
        try std.testing.expectEqual(@as(u16, 1), point.stack_count);
        try std.testing.expectEqual(@as(u16, 1), point.handler_count);
        try std.testing.expectEqual(@as(u32, 4), program.deopt_handlers[point.first_handler].catch_ip);
        saw_throw = true;
    };
    try std.testing.expect(saw_throw);

    if (jit.supported and builtin.cpu.arch == .aarch64) {
        var compiled = try compile(&chunk);
        defer compiled.deinit();
        try std.testing.expect(!compiled.manages_steps);
        try std.testing.expect(!compiled.has_side_exits);
        var scratch: [jit.numeric_scratch_capacity]u64 = undefined;
        var frame = jit.NativeFrame{ .scratch = &scratch };
        try std.testing.expectEqual(jit.ExitStatus.complete, compiled.run(&frame));
        try std.testing.expectEqual(Value.num(8).rawBits(), frame.result_bits);
    }
}

test "optimizer lowering executes nested catch edges natively" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var chunk = bc.Chunk.init(arena.allocator());
    const three = try chunk.addConst(Value.num(3));
    const four = try chunk.addConst(Value.num(4));
    const five = try chunk.addConst(Value.num(5));
    _ = try chunk.emitAB(.push_handler, 8, std.math.maxInt(u32));
    _ = try chunk.emitAB(.push_handler, 5, std.math.maxInt(u32));
    _ = try chunk.emit(.load_const, three);
    _ = try chunk.emit(.throw_op, 0);
    _ = try chunk.emit(.ret_undef, 0);
    _ = try chunk.emit(.load_const, four);
    _ = try chunk.emit(.add, 0);
    _ = try chunk.emit(.throw_op, 0);
    _ = try chunk.emit(.load_const, five);
    _ = try chunk.emit(.add, 0);
    _ = try chunk.emit(.ret, 0);
    var plan = try optimizer.build(&chunk, std.testing.allocator);
    defer plan.deinit();
    var program = try lower(&chunk, &plan, std.testing.allocator);
    defer program.deinit();

    try std.testing.expect(program.deterministic_path);
    try std.testing.expectEqual(@as(u32, 10), program.bytecode_steps);
    var catch_edges: usize = 0;
    for (plan.graph.edges) |edge| {
        if (edge.kind == .catch_) catch_edges += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), catch_edges);

    if (jit.supported and builtin.cpu.arch == .aarch64) {
        var compiled = try compile(&chunk);
        defer compiled.deinit();
        var scratch: [jit.numeric_scratch_capacity]u64 = undefined;
        var frame = jit.NativeFrame{ .scratch = &scratch };
        try std.testing.expectEqual(jit.ExitStatus.complete, compiled.run(&frame));
        try std.testing.expectEqual(Value.num(12).rawBits(), frame.result_bits);
    }
}

test "optimizer lowering executes a finally body before exact dispatch" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var chunk = bc.Chunk.init(arena.allocator());
    chunk.local_count = 1;
    const seven = try chunk.addConst(Value.num(7));
    const one = try chunk.addConst(Value.num(1));
    const two = try chunk.addConst(Value.num(2));
    _ = try chunk.emitAB(.push_handler, std.math.maxInt(u32), 4);
    _ = try chunk.emit(.load_const, seven);
    _ = try chunk.emit(.throw_op, 0);
    _ = try chunk.emit(.ret_undef, 0);
    _ = try chunk.emit(.load_const, one);
    _ = try chunk.emit(.load_const, two);
    _ = try chunk.emit(.add, 0);
    _ = try chunk.emit(.store_local, 0);
    _ = try chunk.emit(.pop, 0);
    _ = try chunk.emit(.end_finally, 0);
    var plan = try optimizer.build(&chunk, std.testing.allocator);
    defer plan.deinit();
    var program = try lower(&chunk, &plan, std.testing.allocator);
    defer program.deinit();

    const side_exit = program.side_exit orelse return error.TestUnexpectedResult;
    try std.testing.expect(program.deterministic_path);
    try std.testing.expectEqual(@as(u12, 8), side_exit.steps);
    try std.testing.expectEqual(jit.DeoptPointKind.finally_dispatch, program.deopt_points[side_exit.deopt_index].kind);
    try std.testing.expectEqual(@as(u16, 2), program.deopt_points[side_exit.deopt_index].stack_count);
    var saw_finally_add = false;
    for (program.operations) |operation| if (operation.block != 0 and operation.kind == .add) {
        saw_finally_add = true;
    };
    try std.testing.expect(saw_finally_add);

    if (jit.supported and builtin.cpu.arch == .aarch64) {
        var compiled = try compile(&chunk);
        defer compiled.deinit();
        var scratch: [jit.numeric_scratch_capacity]u64 = undefined;
        var steps: u64 = 0;
        var frame = jit.NativeFrame{ .scratch = &scratch, .steps = &steps };
        try std.testing.expectEqual(jit.ExitStatus.side_exit, compiled.run(&frame));
        try std.testing.expectEqual(@as(u64, 8), steps);
        try std.testing.expectEqual(jit.DeoptPointKind.finally_dispatch, compiled.deopt.?.points[frame.deopt_index].kind);
    }
}

test "optimizer lowering lets a native finally return override a throw" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var chunk = bc.Chunk.init(arena.allocator());
    const seven = try chunk.addConst(Value.num(7));
    const nine = try chunk.addConst(Value.num(9));
    _ = try chunk.emitAB(.push_handler, std.math.maxInt(u32), 4);
    _ = try chunk.emit(.load_const, seven);
    _ = try chunk.emit(.throw_op, 0);
    _ = try chunk.emit(.ret_undef, 0);
    _ = try chunk.emit(.load_const, nine);
    _ = try chunk.emit(.ret, 0);
    _ = try chunk.emit(.end_finally, 0);
    var plan = try optimizer.build(&chunk, std.testing.allocator);
    defer plan.deinit();
    var program = try lower(&chunk, &plan, std.testing.allocator);
    defer program.deinit();

    try std.testing.expect(program.deterministic_path);
    try std.testing.expect(program.side_exit == null);
    try std.testing.expectEqual(@as(u32, 5), program.bytecode_steps);

    if (jit.supported and builtin.cpu.arch == .aarch64) {
        var compiled = try compile(&chunk);
        defer compiled.deinit();
        var scratch: [jit.numeric_scratch_capacity]u64 = undefined;
        var frame = jit.NativeFrame{ .scratch = &scratch };
        try std.testing.expectEqual(jit.ExitStatus.complete, compiled.run(&frame));
        try std.testing.expectEqual(Value.num(9).rawBits(), frame.result_bits);
    }
}

test "optimizer lowering keeps an uncaught throw as an exact side exit" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var chunk = bc.Chunk.init(arena.allocator());
    const seven = try chunk.addConst(Value.num(7));
    _ = try chunk.emit(.load_const, seven);
    _ = try chunk.emit(.throw_op, 0);
    var plan = try optimizer.build(&chunk, std.testing.allocator);
    defer plan.deinit();
    var program = try lower(&chunk, &plan, std.testing.allocator);
    defer program.deinit();

    const side_exit = program.side_exit orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u12, 1), side_exit.steps);
    const point = program.deopt_points[side_exit.deopt_index];
    try std.testing.expectEqual(jit.DeoptPointKind.throw_, point.kind);
    try std.testing.expectEqual(@as(u32, 1), point.exit_ip);
    try std.testing.expectEqual(@as(u16, 0), point.handler_count);
}

test "optimizer lowering publishes an exact abrupt return side exit" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var chunk = bc.Chunk.init(arena.allocator());
    const seven = try chunk.addConst(Value.num(7));
    _ = try chunk.emitAB(.push_handler, std.math.maxInt(u32), 4);
    _ = try chunk.emit(.load_const, seven);
    _ = try chunk.emit(.abrupt_return, 0);
    _ = try chunk.emit(.ret_undef, 0);
    _ = try chunk.emit(.push_completion, 0);
    _ = try chunk.emit(.end_finally, 0);
    var plan = try optimizer.build(&chunk, std.testing.allocator);
    defer plan.deinit();
    var program = try lower(&chunk, &plan, std.testing.allocator);
    defer program.deinit();

    const side_exit = program.side_exit orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u12, 2), side_exit.steps);
    const point = program.deopt_points[side_exit.deopt_index];
    try std.testing.expectEqual(jit.DeoptPointKind.abrupt_return, point.kind);
    try std.testing.expectEqual(@as(u32, 2), point.exit_ip);
    try std.testing.expectEqual(@as(u16, 1), point.stack_count);
    try std.testing.expectEqual(@as(u16, 1), point.handler_count);
    try std.testing.expectEqual(@as(u32, 4), program.deopt_handlers[point.first_handler].finally_ip);
}

test "optimizer lowering publishes exact abrupt loop-jump side exits" {
    for ([_]bc.Op{ .abrupt_break, .abrupt_continue }) |op| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var chunk = bc.Chunk.init(arena.allocator());
        chunk.param_count = 1;
        chunk.local_count = 1;
        _ = try chunk.emitAB(.push_handler, std.math.maxInt(u32), 2);
        _ = try chunk.emit(op, 4);
        _ = try chunk.emit(.push_completion, 0);
        _ = try chunk.emit(.end_finally, 0);
        _ = try chunk.emit(.ret_undef, 0);
        var plan = try optimizer.build(&chunk, std.testing.allocator);
        defer plan.deinit();
        var program = try lower(&chunk, &plan, std.testing.allocator);
        defer program.deinit();

        const side_exit = program.side_exit orelse return error.TestUnexpectedResult;
        try std.testing.expectEqual(@as(u12, 1), side_exit.steps);
        const point = program.deopt_points[side_exit.deopt_index];
        try std.testing.expectEqual(jit.DeoptPointKind.abrupt_jump, point.kind);
        try std.testing.expectEqual(@as(u32, 1), point.exit_ip);
        try std.testing.expectEqual(@as(u16, 0), point.stack_count);
        try std.testing.expectEqual(@as(u16, 1), point.handler_count);
        try std.testing.expectEqual(@as(u32, 2), program.deopt_handlers[point.first_handler].finally_ip);
    }
}

test "optimizer lowering publishes an executable ordinary call" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var chunk = bc.Chunk.init(arena.allocator());
    chunk.param_count = 2;
    chunk.local_count = 2;
    _ = try chunk.emit(.load_local, 0);
    _ = try chunk.emit(.load_local, 1);
    _ = try chunk.emit(.call, 1);
    _ = try chunk.emit(.ret, 0);
    var plan = try optimizer.build(&chunk, std.testing.allocator);
    defer plan.deinit();
    var program = try lower(&chunk, &plan, std.testing.allocator);
    defer program.deinit();

    try std.testing.expect(program.side_exit == null);
    try std.testing.expectEqual(@as(u32, 4), program.bytecode_steps);
    try std.testing.expectEqual(@as(u64, 0), program.required_numeric_slots);
    try std.testing.expectEqual(@as(usize, 1), program.native_operations.len);
    const operation = program.native_operations[0];
    const point = program.deopt_points[operation.deopt_index];
    try std.testing.expectEqual(jit.DeoptPointKind.call, point.kind);
    try std.testing.expectEqual(@as(u32, 2), point.exit_ip);
    try std.testing.expectEqual(@as(u16, 2), point.stack_count);
    const map = program.stack_maps[operation.deopt_index];
    try std.testing.expectEqual(@as(u64, 0b11), map.frame_pointer_slots);
    const input_roots = (@as(u64, 1) << @intCast(operation.first_input)) |
        (@as(u64, 1) << @intCast(operation.first_input + 1));
    try std.testing.expectEqual(input_roots, map.scratch_pointer_slots & input_roots);
    for (program.deopt_values[point.first_value .. point.first_value + point.local_count + point.stack_count]) |recovery|
        try std.testing.expectEqual(jit.RecoverySource.frame_slot, recovery.source);
    try std.testing.expectEqual(@as(u16, @backingInt(bc.Op.call)), operation.bytecode_op);
    try std.testing.expectEqual(@as(u16, 2), operation.input_count);
    try std.testing.expectEqual(jit.NativeOperationDescriptor.none, operation.exceptional_target);
    try std.testing.expectEqual(@as(u16, 3), operation.step_delta);
    try std.testing.expectEqual(@as(u32, 2), operation.origin);
    try std.testing.expectEqual(plan.graph.nodes.len + 2, @as(usize, program.scratch_slots));

    if (jit.supported and builtin.cpu.arch == .aarch64) {
        var compiled = try compile(&chunk);
        defer compiled.deinit();
        const metadata = compiled.native_operations orelse return error.TestUnexpectedResult;
        try std.testing.expectEqualSlices(
            jit.NativeOperationDescriptor,
            program.native_operations,
            metadata.descriptors,
        );
    }
}

const RuntimeOperationTestContext = struct {
    input_slot: u16,
    expected_input: u64,
    output: u64,
    status: jit.NativeOperationStatus,
    calls: u32 = 0,

    fn dispatch(frame: *jit.NativeFrame, operation_id: u32) callconv(.c) u32 {
        const context: *@This() = @ptrCast(@alignCast(frame.operation_context.?));
        if (operation_id != 0 or frame.scratch.?[context.input_slot] != context.expected_input)
            return @backingInt(jit.NativeOperationStatus.host_trap);
        context.calls += 1;
        frame.operation_value_bits = context.output;
        return @backingInt(context.status);
    }
};

test "optimizer executes to_numeric through the native operation ABI" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var chunk = bc.Chunk.init(arena.allocator());
    chunk.param_count = 1;
    chunk.local_count = 1;
    _ = try chunk.emit(.load_local, 0);
    _ = try chunk.emit(.to_numeric, 0);
    _ = try chunk.emit(.ret, 0);
    var plan = try optimizer.build(&chunk, std.testing.allocator);
    defer plan.deinit();
    var program = try lower(&chunk, &plan, std.testing.allocator);
    defer program.deinit();

    try std.testing.expect(program.side_exit == null);
    try std.testing.expectEqual(@as(u32, 3), program.bytecode_steps);
    try std.testing.expectEqual(@as(usize, 1), program.native_operations.len);
    const descriptor = program.native_operations[0];
    try std.testing.expectEqual(@as(u16, @backingInt(bc.Op.to_numeric)), descriptor.bytecode_op);
    try std.testing.expectEqual(@as(u16, 1), descriptor.input_count);
    try std.testing.expectEqual(@as(u16, 2), descriptor.step_delta);
    try std.testing.expectEqual(jit.NativeOperationDescriptor.none, descriptor.exceptional_target);
    const map = program.stack_maps[descriptor.deopt_index];
    try std.testing.expect(map.scratch_pointer_slots & (@as(u64, 1) << @intCast(descriptor.first_input)) != 0);
    var runtime_operation: ?Operation = null;
    for (program.operations) |operation| if (operation.kind == .runtime_operation) {
        runtime_operation = operation;
    };
    const operation = runtime_operation orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u64, 0), operation.immediate);
    try std.testing.expectEqual(descriptor.first_input, operation.lhs);

    if (jit.supported and builtin.cpu.arch == .aarch64) {
        var compiled = try compileAarch64(&program);
        defer compiled.deinit();
        try std.testing.expect(compiled.manages_steps);
        var slots = [_]u64{Value.num(7).rawBits()};
        var scratch: [jit.numeric_scratch_capacity]u64 = undefined;
        var steps: u64 = 0;
        var context = RuntimeOperationTestContext{
            .input_slot = descriptor.first_input,
            .expected_input = slots[0],
            .output = Value.num(42).rawBits(),
            .status = .value,
        };
        var frame = jit.NativeFrame{
            .slots = &slots,
            .scratch = &scratch,
            .steps = &steps,
            .operation = RuntimeOperationTestContext.dispatch,
            .operation_context = &context,
        };
        try std.testing.expectEqual(jit.ExitStatus.complete, compiled.run(&frame));
        try std.testing.expectEqual(Value.num(42).rawBits(), frame.result_bits);
        try std.testing.expectEqual(@as(u64, 3), steps);
        try std.testing.expectEqual(@as(u32, 1), context.calls);

        inline for (.{
            .{ jit.NativeOperationStatus.catchable_exception, jit.ExitStatus.throw },
            .{ jit.NativeOperationStatus.out_of_memory, jit.ExitStatus.stop },
            .{ jit.NativeOperationStatus.host_trap, jit.ExitStatus.operation_trap },
            .{ jit.NativeOperationStatus.invalidated, jit.ExitStatus.invalidated },
        }) |case| {
            steps = 0;
            context.status = case[0];
            context.calls = 0;
            try std.testing.expectEqual(case[1], compiled.run(&frame));
            try std.testing.expectEqual(@as(u64, 2), steps);
            try std.testing.expectEqual(@as(u32, 1), context.calls);
        }
    }
}

test "optimizer lowering publishes executable unary coercions" {
    const effects = [_]bc.Op{
        .neg,
        .pos,
        .not,
        .typeof_op,
        .inc,
        .dec,
        .bit_not,
        .to_string,
        .to_property_key,
    };
    for (effects) |op| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var chunk = bc.Chunk.init(arena.allocator());
        chunk.param_count = 1;
        chunk.local_count = 1;
        _ = try chunk.emit(.load_local, 0);
        _ = try chunk.emit(op, 0);
        _ = try chunk.emit(.ret, 0);
        var plan = try optimizer.build(&chunk, std.testing.allocator);
        defer plan.deinit();
        var program = try lower(&chunk, &plan, std.testing.allocator);
        defer program.deinit();

        try std.testing.expect(program.side_exit == null);
        try std.testing.expectEqual(@as(usize, 1), program.native_operations.len);
        const descriptor = program.native_operations[0];
        try std.testing.expectEqual(@as(u16, @backingInt(op)), descriptor.bytecode_op);
        try std.testing.expectEqual(@as(u16, 1), descriptor.input_count);
        try std.testing.expect(program.stack_maps[descriptor.deopt_index].scratch_pointer_slots &
            (@as(u64, 1) << @intCast(descriptor.first_input)) != 0);
    }

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var chunk = bc.Chunk.init(arena.allocator());
    chunk.param_count = 1;
    chunk.local_count = 1;
    _ = try chunk.emit(.load_local, 0);
    _ = try chunk.emit(.void_op, 0);
    _ = try chunk.emit(.ret, 0);
    var plan = try optimizer.build(&chunk, std.testing.allocator);
    defer plan.deinit();
    var program = try lower(&chunk, &plan, std.testing.allocator);
    defer program.deinit();
    try std.testing.expect(program.side_exit == null);
    try std.testing.expectEqual(@as(usize, 0), program.native_operations.len);

    var branch_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer branch_arena.deinit();
    var branch = bc.Chunk.init(branch_arena.allocator());
    branch.param_count = 1;
    branch.local_count = 1;
    const eleven = try branch.addConst(Value.num(11));
    const twenty_two = try branch.addConst(Value.num(22));
    _ = try branch.emit(.load_local, 0);
    _ = try branch.emit(.not, 0);
    _ = try branch.emit(.jump_if_false, 5);
    _ = try branch.emit(.load_const, eleven);
    _ = try branch.emit(.ret, 0);
    _ = try branch.emit(.load_const, twenty_two);
    _ = try branch.emit(.ret, 0);
    var branch_plan = try optimizer.build(&branch, std.testing.allocator);
    defer branch_plan.deinit();
    var branch_program = try lower(&branch, &branch_plan, std.testing.allocator);
    defer branch_program.deinit();
    try std.testing.expect(branch_program.side_exit == null);
    try std.testing.expectEqual(@as(usize, 1), branch_program.native_operations.len);
    try std.testing.expectEqual(@as(u16, @backingInt(bc.Op.not)), branch_program.native_operations[0].bytecode_op);
}

test "optimizer routes native to_numeric exceptions to an owned catch target" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var chunk = bc.Chunk.init(arena.allocator());
    chunk.param_count = 1;
    chunk.local_count = 1;
    const ninety_nine = try chunk.addConst(Value.num(99));
    _ = try chunk.emitAB(.push_handler, 5, std.math.maxInt(u32));
    _ = try chunk.emit(.load_local, 0);
    _ = try chunk.emit(.to_numeric, 0);
    _ = try chunk.emit(.pop_handler, 0);
    _ = try chunk.emit(.ret, 0);
    _ = try chunk.emit(.pop, 0);
    _ = try chunk.emit(.load_const, ninety_nine);
    _ = try chunk.emit(.ret, 0);
    var plan = try optimizer.build(&chunk, std.testing.allocator);
    defer plan.deinit();
    var program = try lower(&chunk, &plan, std.testing.allocator);
    defer program.deinit();

    try std.testing.expectEqual(@as(usize, 1), program.native_operations.len);
    try std.testing.expectEqual(@as(usize, 1), program.native_exceptional_targets.len);
    const descriptor = program.native_operations[0];
    try std.testing.expectEqual(@as(u16, 0), descriptor.exceptional_target);
    try std.testing.expectEqual(@as(u16, 3), descriptor.step_delta);
    const target = program.native_exceptional_targets[0];
    try std.testing.expectEqual(@as(u32, 5), target.target_ip);
    try std.testing.expectEqual(jit.NativeExceptionalTargetKind.catch_, target.kind);
    try std.testing.expectEqual(@as(u16, 0), target.unwind_stack_depth);
    try std.testing.expectEqual(@as(u16, 1), target.target_stack_depth);

    if (jit.supported and builtin.cpu.arch == .aarch64) {
        var compiled = try compileAarch64(&program);
        defer compiled.deinit();
        try std.testing.expect(compiled.has_side_exits);
        var slots = [_]u64{Value.num(7).rawBits()};
        var scratch: [jit.numeric_scratch_capacity]u64 = undefined;
        var steps: u64 = 0;
        var context = RuntimeOperationTestContext{
            .input_slot = descriptor.first_input,
            .expected_input = slots[0],
            .output = Value.num(91).rawBits(),
            .status = .catchable_exception,
        };
        var frame = jit.NativeFrame{
            .slots = &slots,
            .scratch = &scratch,
            .steps = &steps,
            .operation = RuntimeOperationTestContext.dispatch,
            .operation_context = &context,
        };
        try std.testing.expectEqual(jit.ExitStatus.operation_exception, compiled.run(&frame));
        try std.testing.expectEqual(@as(u64, 3), steps);
        try std.testing.expectEqual(@as(u64, 0), frame.operation_detail);
    }
}

test "optimizer lowering publishes an exact pre-tail-call side exit" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var chunk = bc.Chunk.init(arena.allocator());
    chunk.param_count = 2;
    chunk.local_count = 2;
    _ = try chunk.emit(.load_local, 0);
    _ = try chunk.emit(.load_local, 1);
    _ = try chunk.emit(.tail_call, 1);
    var plan = try optimizer.build(&chunk, std.testing.allocator);
    defer plan.deinit();
    var program = try lower(&chunk, &plan, std.testing.allocator);
    defer program.deinit();

    const side_exit = program.side_exit orelse return error.TestUnexpectedResult;
    const point = program.deopt_points[side_exit.deopt_index];
    try std.testing.expectEqual(jit.DeoptPointKind.call, point.kind);
    try std.testing.expectEqual(@as(u32, 2), point.exit_ip);
    try std.testing.expectEqual(@as(u16, 2), point.stack_count);
    try std.testing.expectEqual(@as(u64, 0b11), program.stack_maps[side_exit.deopt_index].frame_pointer_slots);
}

test "optimizer lowering publishes an executable named property read" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var chunk = bc.Chunk.init(arena.allocator());
    chunk.param_count = 1;
    chunk.local_count = 1;
    const name = try chunk.addName("value");
    _ = try chunk.emit(.load_local, 0);
    _ = try chunk.emit(.get_prop, name);
    _ = try chunk.emit(.ret, 0);
    var plan = try optimizer.build(&chunk, std.testing.allocator);
    defer plan.deinit();
    var program = try lower(&chunk, &plan, std.testing.allocator);
    defer program.deinit();

    try std.testing.expect(program.side_exit == null);
    try std.testing.expectEqual(@as(usize, 1), program.native_operations.len);
    try std.testing.expectEqual(@as(usize, 1), program.native_operation_names.len);
    const operation = program.native_operations[0];
    try std.testing.expectEqual(@as(u16, @backingInt(bc.Op.get_prop)), operation.bytecode_op);
    try std.testing.expectEqual(@as(u16, 1), operation.input_count);
    try std.testing.expectEqualStrings("value", program.native_operation_names[0].?);
    const point = program.deopt_points[operation.deopt_index];
    try std.testing.expectEqual(jit.DeoptPointKind.effect, point.kind);
    try std.testing.expectEqual(@as(u32, 1), point.exit_ip);
    try std.testing.expectEqual(@as(u16, 1), point.stack_count);
    try std.testing.expectEqual(@as(u64, 1), program.stack_maps[operation.deopt_index].frame_pointer_slots);
    try std.testing.expect(program.stack_maps[operation.deopt_index].scratch_pointer_slots &
        (@as(u64, 1) << @intCast(operation.first_input)) != 0);

    if (jit.supported and builtin.cpu.arch == .aarch64) {
        var compiled = try compile(&chunk);
        defer compiled.deinit();
        const metadata = compiled.native_operations orelse return error.TestUnexpectedResult;
        const owned_name = metadata.nameFor(0) orelse return error.TestUnexpectedResult;
        try std.testing.expectEqualStrings("value", owned_name);
        try std.testing.expect(owned_name.ptr != chunk.names.items[name].ptr);
    }
}

test "optimizer lowering publishes an executable computed property read" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var chunk = bc.Chunk.init(arena.allocator());
    chunk.param_count = 2;
    chunk.local_count = 2;
    _ = try chunk.emit(.load_local, 0);
    _ = try chunk.emit(.load_local, 1);
    _ = try chunk.emit(.get_index, 0);
    _ = try chunk.emit(.ret, 0);
    var plan = try optimizer.build(&chunk, std.testing.allocator);
    defer plan.deinit();
    var program = try lower(&chunk, &plan, std.testing.allocator);
    defer program.deinit();

    try std.testing.expect(program.side_exit == null);
    try std.testing.expectEqual(@as(usize, 1), program.native_operations.len);
    const operation = program.native_operations[0];
    try std.testing.expectEqual(@as(u16, @backingInt(bc.Op.get_index)), operation.bytecode_op);
    try std.testing.expectEqual(@as(u16, 2), operation.input_count);
    const roots = (@as(u64, 1) << @intCast(operation.first_input)) |
        (@as(u64, 1) << @intCast(operation.first_input + 1));
    try std.testing.expectEqual(
        roots,
        program.stack_maps[operation.deopt_index].scratch_pointer_slots & roots,
    );
}

test "optimizer lowering publishes an executable named property write" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var chunk = bc.Chunk.init(arena.allocator());
    chunk.param_count = 2;
    chunk.local_count = 2;
    const name = try chunk.addName("value");
    _ = try chunk.emit(.load_local, 0);
    _ = try chunk.emit(.load_local, 1);
    _ = try chunk.emit(.set_prop, name);
    _ = try chunk.emit(.ret, 0);
    var plan = try optimizer.build(&chunk, std.testing.allocator);
    defer plan.deinit();
    var program = try lower(&chunk, &plan, std.testing.allocator);
    defer program.deinit();

    try std.testing.expect(program.side_exit == null);
    try std.testing.expectEqual(@as(usize, 1), program.native_operations.len);
    const operation = program.native_operations[0];
    try std.testing.expectEqual(@as(u16, @backingInt(bc.Op.set_prop)), operation.bytecode_op);
    try std.testing.expectEqual(@as(u16, 2), operation.input_count);
    try std.testing.expectEqualStrings("value", program.native_operation_names[0].?);
    const roots = (@as(u64, 1) << @intCast(operation.first_input)) |
        (@as(u64, 1) << @intCast(operation.first_input + 1));
    try std.testing.expectEqual(roots, program.stack_maps[operation.deopt_index].scratch_pointer_slots & roots);
}

test "optimizer lowering publishes an executable computed property write" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var chunk = bc.Chunk.init(arena.allocator());
    chunk.param_count = 3;
    chunk.local_count = 3;
    _ = try chunk.emit(.load_local, 0);
    _ = try chunk.emit(.load_local, 1);
    _ = try chunk.emit(.load_local, 2);
    _ = try chunk.emit(.set_index, 0);
    _ = try chunk.emit(.ret, 0);
    var plan = try optimizer.build(&chunk, std.testing.allocator);
    defer plan.deinit();
    var program = try lower(&chunk, &plan, std.testing.allocator);
    defer program.deinit();

    try std.testing.expect(program.side_exit == null);
    try std.testing.expectEqual(@as(usize, 1), program.native_operations.len);
    const operation = program.native_operations[0];
    try std.testing.expectEqual(@as(u16, @backingInt(bc.Op.set_index)), operation.bytecode_op);
    try std.testing.expectEqual(@as(u16, 3), operation.input_count);
    var roots: u64 = 0;
    for (operation.first_input..operation.first_input + operation.input_count) |slot|
        roots |= @as(u64, 1) << @intCast(slot);
    try std.testing.expectEqual(roots, program.stack_maps[operation.deopt_index].scratch_pointer_slots & roots);
}

test "optimizer lowering publishes executable membership operations" {
    const Case = struct {
        op: bc.Op,
        inputs: u32,
        name: ?[]const u8 = null,
    };
    const cases = [_]Case{
        .{ .op = .in_op, .inputs = 2 },
        .{ .op = .instance_of, .inputs = 2 },
        .{ .op = .private_in, .inputs = 1, .name = "#value" },
    };

    for (cases) |case| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var chunk = bc.Chunk.init(arena.allocator());
        chunk.param_count = case.inputs;
        chunk.local_count = case.inputs;
        for (0..case.inputs) |slot| _ = try chunk.emit(.load_local, @intCast(slot));
        const operand = if (case.name) |name| try chunk.addName(name) else 0;
        _ = try chunk.emit(case.op, operand);
        _ = try chunk.emit(.ret, 0);
        var plan = try optimizer.build(&chunk, std.testing.allocator);
        defer plan.deinit();
        var program = try lower(&chunk, &plan, std.testing.allocator);
        defer program.deinit();

        try std.testing.expect(program.side_exit == null);
        try std.testing.expectEqual(@as(usize, 1), program.native_operations.len);
        const operation = program.native_operations[0];
        try std.testing.expectEqual(@as(u16, @backingInt(case.op)), operation.bytecode_op);
        try std.testing.expectEqual(@as(u16, @intCast(case.inputs)), operation.input_count);
        if (case.name) |name|
            try std.testing.expectEqualStrings(name, program.native_operation_names[0].?)
        else
            try std.testing.expect(program.native_operation_names[0] == null);
        var roots: u64 = 0;
        for (operation.first_input..operation.first_input + operation.input_count) |slot|
            roots |= @as(u64, 1) << @intCast(slot);
        try std.testing.expectEqual(roots, program.stack_maps[operation.deopt_index].scratch_pointer_slots & roots);
    }
}

test "optimizer lowering publishes executable binary coercions" {
    const cases = [_]bc.Op{ .pow, .bit_and, .bit_or, .bit_xor, .shl, .shr, .ushr };

    for (cases) |op| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var chunk = bc.Chunk.init(arena.allocator());
        chunk.param_count = 2;
        chunk.local_count = 2;
        _ = try chunk.emit(.load_local, 0);
        _ = try chunk.emit(.load_local, 1);
        _ = try chunk.emit(op, 0);
        _ = try chunk.emit(.ret, 0);
        var plan = try optimizer.build(&chunk, std.testing.allocator);
        defer plan.deinit();
        var program = try lower(&chunk, &plan, std.testing.allocator);
        defer program.deinit();

        try std.testing.expect(program.side_exit == null);
        try std.testing.expectEqual(@as(usize, 1), program.native_operations.len);
        const operation = program.native_operations[0];
        try std.testing.expectEqual(@as(u16, @backingInt(op)), operation.bytecode_op);
        try std.testing.expectEqual(@as(u16, 2), operation.input_count);
        const roots = (@as(u64, 1) << @intCast(operation.first_input)) |
            (@as(u64, 1) << @intCast(operation.first_input + 1));
        try std.testing.expectEqual(roots, program.stack_maps[operation.deopt_index].scratch_pointer_slots & roots);
    }
}

test "optimizer lowering publishes an executable construction" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var chunk = bc.Chunk.init(arena.allocator());
    chunk.param_count = 2;
    chunk.local_count = 2;
    _ = try chunk.emit(.load_local, 0);
    _ = try chunk.emit(.load_local, 1);
    _ = try chunk.emit(.new_call, 1);
    _ = try chunk.emit(.ret, 0);
    var plan = try optimizer.build(&chunk, std.testing.allocator);
    defer plan.deinit();
    var program = try lower(&chunk, &plan, std.testing.allocator);
    defer program.deinit();

    try std.testing.expect(program.side_exit == null);
    try std.testing.expectEqual(@as(u64, 0), program.required_numeric_slots);
    try std.testing.expectEqual(@as(usize, 1), program.native_operations.len);
    const operation = program.native_operations[0];
    try std.testing.expectEqual(@as(u16, @backingInt(bc.Op.new_call)), operation.bytecode_op);
    try std.testing.expectEqual(@as(u16, 2), operation.input_count);
    const point = program.deopt_points[operation.deopt_index];
    try std.testing.expectEqual(jit.DeoptPointKind.call, point.kind);
    try std.testing.expectEqual(@as(u16, 2), point.stack_count);
}

test "optimizer lowering publishes an executable explicit-this call" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var chunk = bc.Chunk.init(arena.allocator());
    chunk.param_count = 3;
    chunk.local_count = 3;
    _ = try chunk.emit(.load_local, 0);
    _ = try chunk.emit(.load_local, 1);
    _ = try chunk.emit(.load_local, 2);
    _ = try chunk.emit(.call_with_this, 1);
    _ = try chunk.emit(.ret, 0);
    var plan = try optimizer.build(&chunk, std.testing.allocator);
    defer plan.deinit();
    var program = try lower(&chunk, &plan, std.testing.allocator);
    defer program.deinit();

    try std.testing.expect(program.side_exit == null);
    try std.testing.expectEqual(@as(usize, 1), program.native_operations.len);
    const operation = program.native_operations[0];
    try std.testing.expectEqual(@as(u16, @backingInt(bc.Op.call_with_this)), operation.bytecode_op);
    try std.testing.expectEqual(@as(u16, 3), operation.input_count);
    const map = program.stack_maps[operation.deopt_index];
    const roots = (@as(u64, 1) << @intCast(operation.first_input)) |
        (@as(u64, 1) << @intCast(operation.first_input + 1)) |
        (@as(u64, 1) << @intCast(operation.first_input + 2));
    try std.testing.expectEqual(roots, map.scratch_pointer_slots & roots);
}

test "optimizer lowering publishes rooted interpreter-owned side exits" {
    const Case = struct {
        op: bc.Op,
        a: u32 = 0,
        b: u32 = 0,
        inputs: u32,
        kind: jit.DeoptPointKind,
    };
    const cases = [_]Case{
        .{ .op = .call_eval, .a = 1, .inputs = 2, .kind = .call },
        .{ .op = .call_method, .b = 1, .inputs = 2, .kind = .call },
        .{ .op = .call_spread, .inputs = 2, .kind = .call },
        .{ .op = .call_method_spread, .inputs = 2, .kind = .call },
        .{ .op = .new_spread, .inputs = 2, .kind = .call },
        .{ .op = .tail_call_eval, .a = 1, .inputs = 2, .kind = .call },
        .{ .op = .tail_call_method, .b = 1, .inputs = 2, .kind = .call },
        .{ .op = .tail_call_with_this, .a = 1, .inputs = 3, .kind = .call },
        .{ .op = .store_var, .inputs = 1, .kind = .effect },
        .{ .op = .def_var, .inputs = 1, .kind = .effect },
        .{ .op = .def_lex, .inputs = 1, .kind = .effect },
        .{ .op = .bind_pattern, .inputs = 1, .kind = .effect },
        .{ .op = .store_upval, .inputs = 1, .kind = .effect },
        .{ .op = .name_anon, .inputs = 1, .kind = .effect },
        .{ .op = .init_prop, .inputs = 2, .kind = .effect },
        .{ .op = .init_proto, .inputs = 2, .kind = .effect },
        .{ .op = .init_prop_computed, .inputs = 3, .kind = .effect },
        .{ .op = .init_spread, .inputs = 2, .kind = .effect },
        .{ .op = .init_getter, .inputs = 3, .kind = .effect },
        .{ .op = .init_setter, .inputs = 3, .kind = .effect },
        .{ .op = .array_append, .inputs = 2, .kind = .effect },
        .{ .op = .array_spread, .inputs = 2, .kind = .effect },
        .{ .op = .array_append_hole, .inputs = 1, .kind = .effect },
        .{ .op = .super_get_index, .inputs = 1, .kind = .effect },
        .{ .op = .enter_with, .inputs = 1, .kind = .effect },
        .{ .op = .register_disposable, .inputs = 1, .kind = .effect },
        .{ .op = .import_call, .inputs = 2, .kind = .effect },
        .{ .op = .assert_iter_result, .inputs = 1, .kind = .effect },
        .{ .op = .iter_of, .inputs = 1, .kind = .effect },
        .{ .op = .async_iter_of, .inputs = 1, .kind = .effect },
        .{ .op = .enum_keys, .inputs = 1, .kind = .effect },
        .{ .op = .iter_close, .inputs = 1, .kind = .effect },
        .{ .op = .iter_close_completion, .inputs = 3, .kind = .effect },
        .{ .op = .async_iter_close, .inputs = 1, .kind = .effect },
        .{ .op = .async_iter_close_completion, .inputs = 3, .kind = .effect },
        .{ .op = .eval_class, .b = 2, .inputs = 2, .kind = .effect },
    };

    for (cases) |case| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var chunk = bc.Chunk.init(arena.allocator());
        chunk.param_count = case.inputs;
        chunk.local_count = case.inputs;
        for (0..case.inputs) |slot| _ = try chunk.emit(.load_local, @intCast(slot));
        _ = try chunk.emitAB(case.op, case.a, case.b);
        var plan = try optimizer.build(&chunk, std.testing.allocator);
        defer plan.deinit();
        var program = try lower(&chunk, &plan, std.testing.allocator);
        defer program.deinit();

        const side_exit = program.side_exit orelse return error.TestUnexpectedResult;
        const point = program.deopt_points[side_exit.deopt_index];
        try std.testing.expectEqual(case.kind, point.kind);
        try std.testing.expectEqual(case.inputs, point.exit_ip);
        try std.testing.expectEqual(std.math.cast(u16, case.inputs).?, point.stack_count);
        try std.testing.expectEqual(@as(u64, 0), program.required_numeric_slots);
        const expected_roots = (@as(u64, 1) << @intCast(case.inputs)) - 1;
        try std.testing.expectEqual(expected_roots, program.stack_maps[side_exit.deopt_index].frame_pointer_slots);
        try std.testing.expectEqual(@as(u64, 0), program.stack_maps[side_exit.deopt_index].scratch_pointer_slots);
    }
}

test "optimizer lowering publishes zero-stack interpreter-owned side exits" {
    const Case = struct {
        op: bc.Op,
        a: u32 = 0,
    };
    const cases = [_]Case{
        .{ .op = .load_bigint },
        .{ .op = .load_var },
        .{ .op = .load_var_or_undef },
        .{ .op = .load_upval },
        .{ .op = .load_this },
        .{ .op = .load_new_target },
        .{ .op = .new_object },
        .{ .op = .new_array },
        .{ .op = .super_get },
        .{ .op = .enter_block },
        .{ .op = .exit_block },
        .{ .op = .dispose_scope },
        .{ .op = .dispose_scope, .a = 1 },
        .{ .op = .exit_with },
        .{ .op = .make_regex },
        .{ .op = .make_closure },
        .{ .op = .template_object },
    };

    for (cases) |case| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var chunk = bc.Chunk.init(arena.allocator());
        chunk.param_count = 1;
        chunk.local_count = 1;
        _ = try chunk.emit(.load_local, 0);
        _ = try chunk.emit(.pop, 0);
        _ = try chunk.emit(case.op, case.a);
        var plan = try optimizer.build(&chunk, std.testing.allocator);
        defer plan.deinit();
        var program = try lower(&chunk, &plan, std.testing.allocator);
        defer program.deinit();

        const side_exit = program.side_exit orelse return error.TestUnexpectedResult;
        const point = program.deopt_points[side_exit.deopt_index];
        try std.testing.expectEqual(jit.DeoptPointKind.effect, point.kind);
        try std.testing.expectEqual(@as(u32, 2), point.exit_ip);
        try std.testing.expectEqual(@as(u16, 0), point.stack_count);
        try std.testing.expectEqual(@as(u64, 1), program.stack_maps[side_exit.deopt_index].frame_pointer_slots);
        try std.testing.expectEqual(@as(u64, 0), program.stack_maps[side_exit.deopt_index].scratch_pointer_slots);
    }
}

test "optimizer compiler executes guarded parameter SSA" {
    if (!jit.supported or builtin.cpu.arch != .aarch64) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var chunk = bc.Chunk.init(arena.allocator());
    chunk.param_count = 2;
    chunk.local_count = 2;
    const two = try chunk.addConst(Value.num(2));
    _ = try chunk.emit(.load_local, 0);
    _ = try chunk.emit(.load_local, 1);
    _ = try chunk.emit(.add, 0);
    _ = try chunk.emit(.load_const, two);
    _ = try chunk.emit(.mul, 0);
    _ = try chunk.emit(.ret, 0);

    var compiled = try compile(&chunk);
    defer compiled.deinit();
    var slots = [_]Value{ Value.num(19), Value.num(2) };
    var scratch: [jit.numeric_scratch_capacity]u64 = undefined;
    var frame = jit.NativeFrame{ .slots = @ptrCast(slots[0..].ptr), .scratch = scratch[0..].ptr };
    try std.testing.expectEqual(jit.CodeKind.optimizer, compiled.kind);
    try std.testing.expectEqual(@as(u64, 0b11), compiled.required_numeric_slots);
    try std.testing.expectEqual(@as(usize, 2), compiled.deopt.?.points.len);
    try std.testing.expectEqual(compiled.deopt.?.points.len, compiled.stack_maps.?.maps.len);
    try std.testing.expectEqual(jit.ExitStatus.complete, compiled.run(&frame));
    try std.testing.expectEqual(@as(f64, 42), Value.fromRawBits(frame.result_bits).asNum());

    slots[0] = Value.num(std.math.nan(f64));
    try std.testing.expectEqual(jit.ExitStatus.complete, compiled.run(&frame));
    const nan_result = Value.fromRawBits(frame.result_bits);
    try std.testing.expect(nan_result.isNumber());
    try std.testing.expect(std.math.isNan(nan_result.asNum()));
}

test "optimizer compiler preserves numeric comparison semantics" {
    if (!jit.supported or builtin.cpu.arch != .aarch64) return error.SkipZigTest;
    const cases = [_]struct {
        op: bc.Op,
        lhs: f64,
        rhs: f64,
        expected: bool,
    }{
        .{ .op = .lt, .lhs = 1, .rhs = 2, .expected = true },
        .{ .op = .le, .lhs = 2, .rhs = 2, .expected = true },
        .{ .op = .gt, .lhs = 2, .rhs = 1, .expected = true },
        .{ .op = .ge, .lhs = 2, .rhs = 2, .expected = true },
        .{ .op = .eq, .lhs = 2, .rhs = 2, .expected = true },
        .{ .op = .neq, .lhs = std.math.nan(f64), .rhs = 2, .expected = true },
    };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    for (cases) |case| {
        var chunk = bc.Chunk.init(arena.allocator());
        chunk.param_count = 2;
        chunk.local_count = 2;
        _ = try chunk.emit(.load_local, 0);
        _ = try chunk.emit(.load_local, 1);
        _ = try chunk.emit(case.op, 0);
        _ = try chunk.emit(.ret, 0);

        var compiled = try compile(&chunk);
        defer compiled.deinit();
        var slots = [_]Value{ Value.num(case.lhs), Value.num(case.rhs) };
        var scratch: [jit.numeric_scratch_capacity]u64 = undefined;
        var frame = jit.NativeFrame{ .slots = @ptrCast(slots[0..].ptr), .scratch = scratch[0..].ptr };
        try std.testing.expectEqual(jit.ExitStatus.complete, compiled.run(&frame));
        try std.testing.expectEqual(case.expected, Value.fromRawBits(frame.result_bits).asBool());
    }
}

test "optimizer lowerer accepts exact two-way SSA control" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var chunk = try makeExactBranchChunk(arena.allocator());
    var plan = try optimizer.build(&chunk, std.testing.allocator);
    defer plan.deinit();
    var program = try lower(&chunk, &plan, std.testing.allocator);
    defer program.deinit();
    try std.testing.expect(program.branch != null);
    try std.testing.expectEqual(@as(u32, 8), program.bytecode_steps);
    try std.testing.expectEqual(@as(usize, 6), program.deopt_points.len);
}

test "optimizer compiler executes exact two-way SSA control" {
    if (!jit.supported or builtin.cpu.arch != .aarch64) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var chunk = try makeExactBranchChunk(arena.allocator());
    var compiled = try compile(&chunk);
    defer compiled.deinit();
    var slots = [_]Value{ Value.num(1), Value.num(2) };
    var scratch: [jit.numeric_scratch_capacity]u64 = undefined;
    var frame = jit.NativeFrame{ .slots = @ptrCast(slots[0..].ptr), .scratch = scratch[0..].ptr };
    try std.testing.expectEqual(jit.ExitStatus.complete, compiled.run(&frame));
    try std.testing.expectEqual(@as(f64, 11), Value.fromRawBits(frame.result_bits).asNum());
    slots = .{ Value.num(3), Value.num(2) };
    try std.testing.expectEqual(jit.ExitStatus.complete, compiled.run(&frame));
    try std.testing.expectEqual(@as(f64, 22), Value.fromRawBits(frame.result_bits).asNum());
}

test "optimizer compiler rejects remainder before publication" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var chunk = bc.Chunk.init(arena.allocator());
    chunk.param_count = 1;
    chunk.local_count = 1;
    const two = try chunk.addConst(Value.num(2));
    _ = try chunk.emit(.load_local, 0);
    _ = try chunk.emit(.load_const, two);
    _ = try chunk.emit(.mod, 0);
    _ = try chunk.emit(.ret, 0);
    try std.testing.expectError(error.UnsupportedChunk, compile(&chunk));
}

test "optimizer compiler side exits asymmetric control exactly" {
    if (!jit.supported or builtin.cpu.arch != .aarch64) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var asymmetric = bc.Chunk.init(arena.allocator());
    asymmetric.param_count = 1;
    asymmetric.local_count = 1;
    const zero = try asymmetric.addConst(Value.num(0));
    const one = try asymmetric.addConst(Value.num(1));
    const two_value = try asymmetric.addConst(Value.num(2));
    _ = try asymmetric.emit(.load_local, 0);
    _ = try asymmetric.emit(.load_const, zero);
    _ = try asymmetric.emit(.lt, 0);
    _ = try asymmetric.emit(.jump_if_false, 8);
    _ = try asymmetric.emit(.load_const, one);
    _ = try asymmetric.emit(.load_const, zero);
    _ = try asymmetric.emit(.pop, 0);
    _ = try asymmetric.emit(.ret, 0);
    _ = try asymmetric.emit(.load_const, two_value);
    _ = try asymmetric.emit(.ret, 0);

    var compiled = try compile(&asymmetric);
    defer compiled.deinit();
    try std.testing.expect(compiled.manages_steps);
    try std.testing.expect(compiled.has_side_exits);
    try std.testing.expectEqual(@as(u32, 4), compiled.bytecode_steps);
    var slots = [_]Value{Value.num(-1)};
    var scratch: [jit.numeric_scratch_capacity]u64 = undefined;
    var steps: u64 = 0;
    var frame = jit.NativeFrame{
        .slots = @ptrCast(slots[0..].ptr),
        .scratch = scratch[0..].ptr,
        .steps = &steps,
    };
    try std.testing.expectEqual(jit.ExitStatus.side_exit, compiled.run(&frame));
    try std.testing.expectEqual(@as(usize, 4), frame.exit_ip);
    try std.testing.expectEqual(@as(u64, 4), steps);
    try std.testing.expectEqual(jit.DeoptPointKind.block_entry, compiled.deopt.?.points[frame.deopt_index].kind);

    slots[0] = Value.num(1);
    steps = 0;
    try std.testing.expectEqual(jit.ExitStatus.side_exit, compiled.run(&frame));
    try std.testing.expectEqual(@as(usize, 8), frame.exit_ip);
    try std.testing.expectEqual(@as(u64, 4), steps);
}

test "optimizer compiler side exits with an active catch handler" {
    if (!jit.supported or builtin.cpu.arch != .aarch64) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var chunk = bc.Chunk.init(arena.allocator());
    chunk.param_count = 1;
    chunk.local_count = 1;
    const zero = try chunk.addConst(Value.num(0));
    const eleven = try chunk.addConst(Value.num(11));
    const dummy = try chunk.addConst(Value.num(1));
    const twenty_two = try chunk.addConst(Value.num(22));
    const ninety_nine = try chunk.addConst(Value.num(99));
    _ = try chunk.emitAB(.push_handler, 13, std.math.maxInt(u32));
    _ = try chunk.emit(.load_local, 0);
    _ = try chunk.emit(.load_const, zero);
    _ = try chunk.emit(.lt, 0);
    _ = try chunk.emit(.jump_if_false, 8);
    _ = try chunk.emit(.pop_handler, 0);
    _ = try chunk.emit(.load_const, eleven);
    _ = try chunk.emit(.ret, 0);
    _ = try chunk.emit(.pop_handler, 0);
    _ = try chunk.emit(.load_const, dummy);
    _ = try chunk.emit(.pop, 0);
    _ = try chunk.emit(.load_const, twenty_two);
    _ = try chunk.emit(.ret, 0);
    _ = try chunk.emit(.load_const, ninety_nine);
    _ = try chunk.emit(.ret, 0);

    var compiled = try compile(&chunk);
    defer compiled.deinit();
    var slots = [_]Value{Value.num(-1)};
    var scratch: [jit.numeric_scratch_capacity]u64 = undefined;
    var steps: u64 = 0;
    var frame = jit.NativeFrame{
        .slots = @ptrCast(slots[0..].ptr),
        .scratch = &scratch,
        .steps = &steps,
    };
    try std.testing.expectEqual(jit.ExitStatus.side_exit, compiled.run(&frame));
    try std.testing.expectEqual(@as(usize, 5), frame.exit_ip);
    try std.testing.expectEqual(@as(u64, 5), steps);
    var point = compiled.deopt.?.points[frame.deopt_index];
    try std.testing.expectEqual(@as(u16, 1), point.handler_count);
    try std.testing.expectEqual(@as(u32, 13), compiled.deopt.?.handlers[point.first_handler].catch_ip);

    slots[0] = Value.num(1);
    steps = 0;
    try std.testing.expectEqual(jit.ExitStatus.side_exit, compiled.run(&frame));
    try std.testing.expectEqual(@as(usize, 8), frame.exit_ip);
    try std.testing.expectEqual(@as(u64, 5), steps);
    point = compiled.deopt.?.points[frame.deopt_index];
    try std.testing.expectEqual(@as(u16, 1), point.handler_count);
    try std.testing.expectEqual(@as(u32, 13), compiled.deopt.?.handlers[point.first_handler].catch_ip);
}

test "optimizer loop OSR metadata imports an exact VM frame" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var chunk = bc.Chunk.init(arena.allocator());
    chunk.param_count = 1;
    chunk.local_count = 2;
    const zero = try chunk.addConst(Value.num(0));
    const one = try chunk.addConst(Value.num(1));
    _ = try chunk.emit(.load_const, zero);
    _ = try chunk.emit(.store_local, 1);
    _ = try chunk.emit(.pop, 0);
    _ = try chunk.emit(.jump, 4);
    _ = try chunk.emit(.load_local, 1);
    _ = try chunk.emit(.load_local, 0);
    _ = try chunk.emit(.lt, 0);
    _ = try chunk.emit(.jump_if_false, 14);
    _ = try chunk.emit(.load_local, 1);
    _ = try chunk.emit(.load_const, one);
    _ = try chunk.emit(.add, 0);
    _ = try chunk.emit(.store_local, 1);
    _ = try chunk.emit(.pop, 0);
    _ = try chunk.emit(.jump, 4);
    _ = try chunk.emit(.load_local, 1);
    _ = try chunk.emit(.ret, 0);

    var plan = try optimizer.build(&chunk, std.testing.allocator);
    defer plan.deinit();
    const metadata = try buildOsrMetadata(&plan, std.testing.allocator);
    defer metadata.destroy();

    try std.testing.expectEqual(@as(usize, 1), metadata.entries.len);
    const entry_index = metadata.findEntry(4, 2, 0, 0, Value.undef().rawBits()) orelse
        return error.TestUnexpectedResult;
    try std.testing.expect(metadata.findEntry(4, 2, 1, 0, Value.undef().rawBits()) == null);
    try std.testing.expect(metadata.findEntry(4, 2, 0, 1, Value.undef().rawBits()) == null);
    try std.testing.expect(metadata.findEntry(4, 2, 0, 0, Value.nul().rawBits()) == null);

    const slots = [_]u64{ Value.num(9).rawBits(), Value.num(3).rawBits() };
    var scratch: [jit.numeric_scratch_capacity]u64 = @splat(0);
    try std.testing.expect(metadata.prepareScratch(entry_index, &slots, &.{}, &scratch));
    const entry = metadata.entries[entry_index];
    for (metadata.imports[entry.first_import .. entry.first_import + entry.local_count], 0..) |import, index| {
        try std.testing.expectEqual(jit.OsrImportSource.frame_slot, import.source);
        try std.testing.expectEqual(@as(u16, @intCast(index)), import.source_index);
        try std.testing.expectEqual(slots[index], scratch[import.destination]);
    }
    try std.testing.expect(!metadata.prepareScratch(entry_index, slots[0..1], &.{}, &scratch));

    const last_import = entry.first_import + entry.local_count - 1;
    const saved_destination = metadata.imports[last_import].destination;
    metadata.imports[last_import].destination = std.math.maxInt(u8);
    scratch = @splat(0xfeed_face);
    try std.testing.expect(!metadata.prepareScratch(entry_index, &slots, &.{}, scratch[0..2]));
    try std.testing.expectEqualSlices(u64, &.{ 0xfeed_face, 0xfeed_face }, scratch[0..2]);
    metadata.imports[last_import].destination = saved_destination;
}

test "optimizer compiler executes multiple loop iterations through OSR" {
    if (!jit.supported or builtin.cpu.arch != .aarch64) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var chunk = bc.Chunk.init(arena.allocator());
    chunk.param_count = 1;
    chunk.local_count = 2;
    const zero = try chunk.addConst(Value.num(0));
    const one = try chunk.addConst(Value.num(1));
    _ = try chunk.emit(.load_const, zero);
    _ = try chunk.emit(.store_local, 1);
    _ = try chunk.emit(.pop, 0);
    _ = try chunk.emit(.jump, 4);
    _ = try chunk.emit(.load_local, 1);
    _ = try chunk.emit(.load_local, 0);
    _ = try chunk.emit(.lt, 0);
    _ = try chunk.emit(.jump_if_false, 14);
    _ = try chunk.emit(.load_local, 1);
    _ = try chunk.emit(.load_const, one);
    _ = try chunk.emit(.add, 0);
    _ = try chunk.emit(.store_local, 1);
    _ = try chunk.emit(.pop, 0);
    _ = try chunk.emit(.jump, 4);
    _ = try chunk.emit(.load_local, 1);
    _ = try chunk.emit(.ret, 0);

    var compiled = try compile(&chunk);
    defer compiled.deinit();
    try std.testing.expect(!compiled.entry_enabled);
    try std.testing.expect(compiled.has_side_exits);
    const osr = compiled.osr orelse return error.TestUnexpectedResult;
    const entry_index = osr.findEntry(4, 2, 0, 0, Value.undef().rawBits()) orelse
        return error.TestUnexpectedResult;
    var slots = [_]u64{ Value.num(9).rawBits(), Value.num(3).rawBits() };
    var scratch: [jit.numeric_scratch_capacity]u64 = @splat(0);
    try std.testing.expect(osr.prepareScratch(entry_index, &slots, &.{}, &scratch));
    var steps: u64 = 0;
    var frame = jit.NativeFrame{
        .slots = slots[0..].ptr,
        .scratch = &scratch,
        .steps = &steps,
        .steps_until_checkpoint = 1024,
        .steps_until_budget = 1024,
    };
    try std.testing.expectEqual(jit.ExitStatus.side_exit, compiled.run(&frame));
    try std.testing.expectEqual(@as(usize, 14), frame.exit_ip);
    try std.testing.expectEqual(@as(u64, 64), steps);
    const point = compiled.deopt.?.points[frame.deopt_index];
    try std.testing.expectEqual(jit.DeoptPointKind.edge, point.kind);
    const recovered_i = compiled.deopt.?.values[point.first_value + 1].materialize(&slots, &scratch) orelse
        return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(f64, 9), Value.fromRawBits(recovered_i).asNum());
    const stack_map = compiled.stack_maps.?.forDeopt(frame.deopt_index) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u64, 0), stack_map.frame_pointer_slots);
    try std.testing.expectEqual(@as(u64, 0), stack_map.scratch_pointer_slots);

    var invalidation_generation: std.atomic.Value(u64) = .init(1);
    frame.invalidation_generation = &invalidation_generation;
    frame.expected_invalidation_generation = 0;
    steps = 0;
    try std.testing.expectEqual(jit.ExitStatus.invalidated, compiled.run(&frame));
    try std.testing.expectEqual(@as(u64, 0), steps);

    invalidation_generation.store(0, .release);
    slots[0] = Value.num(4).rawBits();
    slots[1] = Value.num(3).rawBits();
    try std.testing.expect(osr.prepareScratch(entry_index, &slots, &.{}, &scratch));
    steps = 0;
    try std.testing.expectEqual(jit.ExitStatus.side_exit, compiled.run(&frame));
    try std.testing.expectEqual(@as(usize, 14), frame.exit_ip);
    try std.testing.expectEqual(@as(u64, 14), steps);
    const one_iteration_point = compiled.deopt.?.points[frame.deopt_index];
    const one_iteration_i = compiled.deopt.?.values[one_iteration_point.first_value + 1].materialize(&slots, &scratch) orelse
        return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(f64, 4), Value.fromRawBits(one_iteration_i).asNum());

    slots[0] = Value.num(9).rawBits();
    slots[1] = Value.num(3).rawBits();
    try std.testing.expect(osr.prepareScratch(entry_index, &slots, &.{}, &scratch));
    frame.steps_until_checkpoint = compiled.bytecode_steps;
    steps = 0;
    try std.testing.expectEqual(jit.ExitStatus.side_exit, compiled.run(&frame));
    try std.testing.expectEqual(@as(usize, 4), frame.exit_ip);
    try std.testing.expectEqual(@as(u64, 0), steps);
    try std.testing.expectEqual(jit.DeoptPointKind.block_entry, compiled.deopt.?.points[frame.deopt_index].kind);

    frame.steps_until_checkpoint = 1024;
    slots[1] = Value.num(9).rawBits();
    try std.testing.expect(osr.prepareScratch(entry_index, &slots, &.{}, &scratch));
    steps = 0;
    try std.testing.expectEqual(jit.ExitStatus.side_exit, compiled.run(&frame));
    try std.testing.expectEqual(@as(usize, 14), frame.exit_ip);
    try std.testing.expectEqual(@as(u64, 4), steps);

    if (!builtin.single_threaded) {
        var race_plan = try optimizer.build(&chunk, std.testing.allocator);
        defer race_plan.deinit();
        var race_program = try lowerLoopOsr(&chunk, &race_plan, std.testing.allocator);
        defer race_program.deinit();
        race_program.observe_loop_backedges = true;
        var race_compiled = try compileAarch64(&race_program);
        defer race_compiled.deinit();
        const race_osr = race_compiled.osr orelse return error.TestUnexpectedResult;
        const race_entry = race_osr.findEntry(4, 2, 0, 0, Value.undef().rawBits()) orelse
            return error.TestUnexpectedResult;
        var race_slots = [_]u64{ Value.num(1_000_000_000).rawBits(), Value.num(0).rawBits() };
        var race_scratch: [jit.numeric_scratch_capacity]u64 = @splat(0);
        try std.testing.expect(race_osr.prepareScratch(race_entry, &race_slots, &.{}, &race_scratch));
        var race_steps: u64 = 0;
        var generation: std.atomic.Value(u64) = .init(0);
        var backedge_observer: std.atomic.Value(u64) = .init(0);
        const Invalidation = struct {
            observer: *std.atomic.Value(u64),
            generation: *std.atomic.Value(u64),

            fn run(shared: *@This()) void {
                while (shared.observer.load(.acquire) == 0) std.atomic.spinLoopHint();
                shared.generation.store(1, .release);
            }
        };
        var invalidation = Invalidation{
            .observer = &backedge_observer,
            .generation = &generation,
        };
        var invalidator = try std.Thread.spawn(.{}, Invalidation.run, .{&invalidation});
        var race_frame = jit.NativeFrame{
            .slots = &race_slots,
            .scratch = &race_scratch,
            .steps = &race_steps,
            .steps_until_checkpoint = std.math.maxInt(u64),
            .steps_until_budget = std.math.maxInt(u64),
            .invalidation_generation = &generation,
            .expected_invalidation_generation = 0,
            .loop_backedge_observer = &backedge_observer,
        };
        const race_status = race_compiled.run(&race_frame);
        invalidator.join();

        try std.testing.expectEqual(jit.ExitStatus.side_exit, race_status);
        try std.testing.expectEqual(@as(u64, 1), backedge_observer.load(.acquire));
        try std.testing.expectEqual(@as(usize, 4), race_frame.exit_ip);
        try std.testing.expect(race_steps >= race_compiled.bytecode_steps);
        try std.testing.expect(race_steps < 1_000_000_000 * @as(u64, race_compiled.bytecode_steps));
        try std.testing.expectEqual(@as(u64, 0), race_steps % race_compiled.bytecode_steps);
        const race_point = race_compiled.deopt.?.points[race_frame.deopt_index];
        try std.testing.expectEqual(jit.DeoptPointKind.block_entry, race_point.kind);
        const race_i = race_compiled.deopt.?.values[race_point.first_value + 1].materialize(&race_slots, &race_scratch) orelse
            return error.TestUnexpectedResult;
        try std.testing.expectEqual(
            @as(f64, @floatFromInt(race_steps / race_compiled.bytecode_steps)),
            Value.fromRawBits(race_i).asNum(),
        );
    }
}

test "optimizer loop moving safepoint publishes and rewrites recovery-only local" {
    if (!jit.supported or builtin.cpu.arch != .aarch64) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var chunk = bc.Chunk.init(arena.allocator());
    chunk.param_count = 2;
    chunk.local_count = 3;
    const zero = try chunk.addConst(Value.num(0));
    const one = try chunk.addConst(Value.num(1));
    _ = try chunk.emit(.load_const, zero);
    _ = try chunk.emit(.store_local, 2);
    _ = try chunk.emit(.pop, 0);
    _ = try chunk.emit(.jump, 4);
    _ = try chunk.emit(.load_local, 2);
    _ = try chunk.emit(.load_local, 0);
    _ = try chunk.emit(.lt, 0);
    _ = try chunk.emit(.jump_if_false, 14);
    _ = try chunk.emit(.load_local, 2);
    _ = try chunk.emit(.load_const, one);
    _ = try chunk.emit(.add, 0);
    _ = try chunk.emit(.store_local, 2);
    _ = try chunk.emit(.pop, 0);
    _ = try chunk.emit(.jump, 4);
    _ = try chunk.emit(.load_local, 1);
    _ = try chunk.emit(.ret, 0);

    var compiled = try compile(&chunk);
    defer compiled.deinit();
    try std.testing.expectEqual(@as(u64, 0b101), compiled.required_numeric_slots);
    const osr = compiled.osr orelse return error.TestUnexpectedResult;
    const osr_entry = osr.findEntry(4, 3, 0, 0, Value.undef().rawBits()) orelse
        return error.TestUnexpectedResult;
    const entry = osr.entries[osr_entry];
    const held_import = osr.imports[entry.first_import + 1];
    try std.testing.expectEqual(jit.OsrImportSource.frame_slot, held_import.source);
    try std.testing.expectEqual(@as(u16, 1), held_import.source_index);

    const Callback = struct {
        hits: u32 = 0,
        seen_deopt: usize = std.math.maxInt(usize),
        held_slot: u8,

        fn run(frame: *jit.NativeFrame) callconv(.c) void {
            const self: *@This() = @ptrCast(@alignCast(frame.runtime_context.?));
            self.hits += 1;
            self.seen_deopt = frame.deopt_index;
            frame.scratch.?[self.held_slot] = Value.boolVal(true).rawBits();
            frame.moving_safepoint = null;
        }
    };
    var callback = Callback{ .held_slot = held_import.destination };
    var slots = [_]u64{ Value.num(70).rawBits(), Value.nul().rawBits(), Value.num(0).rawBits() };
    var scratch: [jit.numeric_scratch_capacity]u64 = @splat(0);
    try std.testing.expect(osr.prepareScratch(osr_entry, &slots, &.{}, &scratch));
    var steps: u64 = 0;
    var frame = jit.NativeFrame{
        .slots = &slots,
        .scratch = &scratch,
        .steps = &steps,
        .runtime_context = &callback,
        .moving_safepoint = Callback.run,
        .steps_until_checkpoint = 1024,
        .steps_until_budget = 1024,
    };
    try std.testing.expectEqual(jit.ExitStatus.side_exit, compiled.run(&frame));
    try std.testing.expectEqual(@as(u32, 1), callback.hits);
    const live_map = compiled.stack_maps.?.forDeopt(callback.seen_deopt) orelse
        return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u64, 0), live_map.frame_pointer_slots);
    try std.testing.expectEqual(@as(u64, 1) << @intCast(held_import.destination), live_map.scratch_pointer_slots);
    const exit = compiled.deopt.?.points[frame.deopt_index];
    const held = compiled.deopt.?.values[exit.first_value + 1].materialize(&slots, &scratch) orelse
        return error.TestUnexpectedResult;
    try std.testing.expect(Value.fromRawBits(held).asBool());
}

test "optimizer loop OSR preserves parallel multi-local backedges" {
    if (!jit.supported or builtin.cpu.arch != .aarch64) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var chunk = bc.Chunk.init(arena.allocator());
    chunk.param_count = 1;
    chunk.local_count = 4;
    const zero = try chunk.addConst(Value.num(0));
    const one = try chunk.addConst(Value.num(1));
    const ten = try chunk.addConst(Value.num(10));
    const twenty = try chunk.addConst(Value.num(20));
    _ = try chunk.emit(.load_const, zero);
    _ = try chunk.emit(.store_local, 1);
    _ = try chunk.emit(.pop, 0);
    _ = try chunk.emit(.load_const, ten);
    _ = try chunk.emit(.store_local, 2);
    _ = try chunk.emit(.pop, 0);
    _ = try chunk.emit(.load_const, twenty);
    _ = try chunk.emit(.store_local, 3);
    _ = try chunk.emit(.pop, 0);
    _ = try chunk.emit(.jump, 10);
    _ = try chunk.emit(.load_local, 1);
    _ = try chunk.emit(.load_local, 0);
    _ = try chunk.emit(.lt, 0);
    _ = try chunk.emit(.jump_if_false, 26);
    _ = try chunk.emit(.load_local, 2);
    _ = try chunk.emit(.load_local, 3);
    _ = try chunk.emit(.store_local, 2);
    _ = try chunk.emit(.pop, 0);
    _ = try chunk.emit(.store_local, 3);
    _ = try chunk.emit(.pop, 0);
    _ = try chunk.emit(.load_local, 1);
    _ = try chunk.emit(.load_const, one);
    _ = try chunk.emit(.add, 0);
    _ = try chunk.emit(.store_local, 1);
    _ = try chunk.emit(.pop, 0);
    _ = try chunk.emit(.jump, 10);
    _ = try chunk.emit(.load_local, 2);
    _ = try chunk.emit(.ret, 0);

    var compiled = try compile(&chunk);
    defer compiled.deinit();
    const osr = compiled.osr orelse return error.TestUnexpectedResult;
    const entry_index = osr.findEntry(10, 4, 0, 0, Value.undef().rawBits()) orelse
        return error.TestUnexpectedResult;
    var slots = [_]u64{
        Value.num(5).rawBits(),
        Value.num(0).rawBits(),
        Value.num(10).rawBits(),
        Value.num(20).rawBits(),
    };
    var scratch: [jit.numeric_scratch_capacity]u64 = @splat(0);
    try std.testing.expect(osr.prepareScratch(entry_index, &slots, &.{}, &scratch));
    var steps: u64 = 0;
    var frame = jit.NativeFrame{
        .slots = &slots,
        .scratch = &scratch,
        .steps = &steps,
        .steps_until_checkpoint = 1024,
        .steps_until_budget = 1024,
    };
    try std.testing.expectEqual(jit.ExitStatus.side_exit, compiled.run(&frame));
    try std.testing.expectEqual(@as(usize, 26), frame.exit_ip);
    try std.testing.expectEqual(@as(u64, 84), steps);
    const exit = compiled.deopt.?.points[frame.deopt_index];
    const expected = [_]f64{ 5, 5, 20, 10 };
    for (expected, 0..) |value, local| {
        const recovered = compiled.deopt.?.values[exit.first_value + local].materialize(&slots, &scratch) orelse
            return error.TestUnexpectedResult;
        try std.testing.expectEqual(value, Value.fromRawBits(recovered).asNum());
    }

    slots = .{
        Value.num(5).rawBits(),
        Value.num(0).rawBits(),
        Value.num(10).rawBits(),
        Value.num(20).rawBits(),
    };
    try std.testing.expect(osr.prepareScratch(entry_index, &slots, &.{}, &scratch));
    frame.steps_until_checkpoint = compiled.bytecode_steps * 2 + 1;
    steps = 0;
    try std.testing.expectEqual(jit.ExitStatus.side_exit, compiled.run(&frame));
    try std.testing.expectEqual(@as(usize, 10), frame.exit_ip);
    try std.testing.expectEqual(@as(u64, 32), steps);
    const checkpoint = compiled.deopt.?.points[frame.deopt_index];
    const checkpoint_expected = [_]f64{ 5, 2, 10, 20 };
    for (checkpoint_expected, 0..) |value, local| {
        const recovered = compiled.deopt.?.values[checkpoint.first_value + local].materialize(&slots, &scratch) orelse
            return error.TestUnexpectedResult;
        try std.testing.expectEqual(value, Value.fromRawBits(recovered).asNum());
    }
}

test "optimizer loop OSR executes an equal-cost nested branch" {
    if (!jit.supported or builtin.cpu.arch != .aarch64) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var chunk = bc.Chunk.init(arena.allocator());
    chunk.param_count = 1;
    chunk.local_count = 3;
    const zero = try chunk.addConst(Value.num(0));
    const one = try chunk.addConst(Value.num(1));
    const two = try chunk.addConst(Value.num(2));
    const ten = try chunk.addConst(Value.num(10));
    _ = try chunk.emit(.load_const, zero);
    _ = try chunk.emit(.store_local, 1);
    _ = try chunk.emit(.pop, 0);
    _ = try chunk.emit(.load_const, zero);
    _ = try chunk.emit(.store_local, 2);
    _ = try chunk.emit(.pop, 0);
    _ = try chunk.emit(.jump, 7);
    _ = try chunk.emit(.load_local, 1);
    _ = try chunk.emit(.load_local, 0);
    _ = try chunk.emit(.lt, 0);
    _ = try chunk.emit(.jump_if_false, 33);
    _ = try chunk.emit(.load_local, 1);
    _ = try chunk.emit(.load_const, two);
    _ = try chunk.emit(.lt, 0);
    _ = try chunk.emit(.jump_if_false, 21);
    _ = try chunk.emit(.load_local, 2);
    _ = try chunk.emit(.load_const, ten);
    _ = try chunk.emit(.add, 0);
    _ = try chunk.emit(.store_local, 2);
    _ = try chunk.emit(.pop, 0);
    _ = try chunk.emit(.jump, 27);
    _ = try chunk.emit(.load_local, 2);
    _ = try chunk.emit(.load_const, one);
    _ = try chunk.emit(.add, 0);
    _ = try chunk.emit(.store_local, 2);
    _ = try chunk.emit(.pop, 0);
    _ = try chunk.emit(.jump, 27);
    _ = try chunk.emit(.load_local, 1);
    _ = try chunk.emit(.load_const, one);
    _ = try chunk.emit(.add, 0);
    _ = try chunk.emit(.store_local, 1);
    _ = try chunk.emit(.pop, 0);
    _ = try chunk.emit(.jump, 7);
    _ = try chunk.emit(.load_local, 2);
    _ = try chunk.emit(.ret, 0);

    var compiled = try compile(&chunk);
    defer compiled.deinit();
    try std.testing.expectEqual(@as(u32, 20), compiled.bytecode_steps);
    const osr = compiled.osr orelse return error.TestUnexpectedResult;
    const entry_index = osr.findEntry(7, 3, 0, 0, Value.undef().rawBits()) orelse
        return error.TestUnexpectedResult;
    var slots = [_]u64{
        Value.num(4).rawBits(),
        Value.num(0).rawBits(),
        Value.num(0).rawBits(),
    };
    var scratch: [jit.numeric_scratch_capacity]u64 = @splat(0);
    try std.testing.expect(osr.prepareScratch(entry_index, &slots, &.{}, &scratch));
    var steps: u64 = 0;
    var frame = jit.NativeFrame{
        .slots = &slots,
        .scratch = &scratch,
        .steps = &steps,
        .steps_until_checkpoint = 1024,
        .steps_until_budget = 1024,
    };
    try std.testing.expectEqual(jit.ExitStatus.side_exit, compiled.run(&frame));
    try std.testing.expectEqual(@as(usize, 33), frame.exit_ip);
    try std.testing.expectEqual(@as(u64, 84), steps);
    const exit = compiled.deopt.?.points[frame.deopt_index];
    const expected = [_]f64{ 4, 4, 22 };
    for (expected, 0..) |value, local| {
        const recovered = compiled.deopt.?.values[exit.first_value + local].materialize(&slots, &scratch) orelse
            return error.TestUnexpectedResult;
        try std.testing.expectEqual(value, Value.fromRawBits(recovered).asNum());
    }

    slots = .{
        Value.num(4).rawBits(),
        Value.num(0).rawBits(),
        Value.num(0).rawBits(),
    };
    try std.testing.expect(osr.prepareScratch(entry_index, &slots, &.{}, &scratch));
    frame.steps_until_checkpoint = compiled.bytecode_steps * 2 + 1;
    steps = 0;
    try std.testing.expectEqual(jit.ExitStatus.side_exit, compiled.run(&frame));
    try std.testing.expectEqual(@as(usize, 7), frame.exit_ip);
    try std.testing.expectEqual(@as(u64, 40), steps);
    const checkpoint = compiled.deopt.?.points[frame.deopt_index];
    const checkpoint_expected = [_]f64{ 4, 2, 20 };
    for (checkpoint_expected, 0..) |value, local| {
        const recovered = compiled.deopt.?.values[checkpoint.first_value + local].materialize(&slots, &scratch) orelse
            return error.TestUnexpectedResult;
        try std.testing.expectEqual(value, Value.fromRawBits(recovered).asNum());
    }
}

fn makeUnequalNestedLoopChunk(allocator: std.mem.Allocator, pad_true: bool) !bc.Chunk {
    var chunk = bc.Chunk.init(allocator);
    chunk.param_count = 1;
    chunk.local_count = 3;
    const zero = try chunk.addConst(Value.num(0));
    const one = try chunk.addConst(Value.num(1));
    const two = try chunk.addConst(Value.num(2));
    const ten = try chunk.addConst(Value.num(10));
    _ = try chunk.emit(.load_const, zero);
    _ = try chunk.emit(.store_local, 1);
    _ = try chunk.emit(.pop, 0);
    _ = try chunk.emit(.load_const, zero);
    _ = try chunk.emit(.store_local, 2);
    _ = try chunk.emit(.pop, 0);
    const enter_loop = try chunk.emit(.jump, 0);

    const header: u32 = @intCast(chunk.code.items.len);
    chunk.code.items[enter_loop].a = header;
    _ = try chunk.emit(.load_local, 1);
    _ = try chunk.emit(.load_local, 0);
    _ = try chunk.emit(.lt, 0);
    const leave_loop = try chunk.emit(.jump_if_false, 0);
    _ = try chunk.emit(.load_local, 1);
    _ = try chunk.emit(.load_const, two);
    _ = try chunk.emit(.lt, 0);
    const take_false = try chunk.emit(.jump_if_false, 0);

    _ = try chunk.emit(.load_local, 2);
    _ = try chunk.emit(.load_const, ten);
    _ = try chunk.emit(.add, 0);
    _ = try chunk.emit(.store_local, 2);
    _ = try chunk.emit(.pop, 0);
    if (pad_true) {
        _ = try chunk.emit(.load_const, zero);
        _ = try chunk.emit(.pop, 0);
    }
    const true_to_merge = try chunk.emit(.jump, 0);

    const false_start: u32 = @intCast(chunk.code.items.len);
    chunk.code.items[take_false].a = false_start;
    _ = try chunk.emit(.load_local, 2);
    _ = try chunk.emit(.load_const, one);
    _ = try chunk.emit(.add, 0);
    _ = try chunk.emit(.store_local, 2);
    _ = try chunk.emit(.pop, 0);
    if (!pad_true) {
        _ = try chunk.emit(.load_const, zero);
        _ = try chunk.emit(.pop, 0);
    }
    const false_to_merge = try chunk.emit(.jump, 0);

    const merge: u32 = @intCast(chunk.code.items.len);
    chunk.code.items[true_to_merge].a = merge;
    chunk.code.items[false_to_merge].a = merge;
    _ = try chunk.emit(.load_local, 1);
    _ = try chunk.emit(.load_const, one);
    _ = try chunk.emit(.add, 0);
    _ = try chunk.emit(.store_local, 1);
    _ = try chunk.emit(.pop, 0);
    _ = try chunk.emit(.jump, header);

    const exit: u32 = @intCast(chunk.code.items.len);
    chunk.code.items[leave_loop].a = exit;
    _ = try chunk.emit(.load_local, 2);
    _ = try chunk.emit(.ret, 0);
    return chunk;
}

test "optimizer loop OSR accounts unequal nested branch paths" {
    if (!jit.supported or builtin.cpu.arch != .aarch64) return error.SkipZigTest;
    for ([_]bool{ true, false }) |pad_true| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var chunk = try makeUnequalNestedLoopChunk(arena.allocator(), pad_true);
        var compiled = try compile(&chunk);
        defer compiled.deinit();
        try std.testing.expectEqual(@as(u32, 22), compiled.bytecode_steps);
        const osr = compiled.osr orelse return error.TestUnexpectedResult;
        const entry_index = osr.findEntry(7, 3, 0, 0, Value.undef().rawBits()) orelse
            return error.TestUnexpectedResult;
        var slots = [_]u64{
            Value.num(4).rawBits(),
            Value.num(0).rawBits(),
            Value.num(0).rawBits(),
        };
        var scratch: [jit.numeric_scratch_capacity]u64 = @splat(0);
        try std.testing.expect(osr.prepareScratch(entry_index, &slots, &.{}, &scratch));
        var steps: u64 = 0;
        var frame = jit.NativeFrame{
            .slots = &slots,
            .scratch = &scratch,
            .steps = &steps,
            .steps_until_checkpoint = 1024,
            .steps_until_budget = 1024,
        };
        try std.testing.expectEqual(jit.ExitStatus.side_exit, compiled.run(&frame));
        try std.testing.expectEqual(@as(u64, 88), steps);
        const complete_exit = compiled.deopt.?.points[frame.deopt_index];
        try std.testing.expectEqual(@as(f64, 22), Value.fromRawBits(
            compiled.deopt.?.values[complete_exit.first_value + 2].materialize(&slots, &scratch) orelse
                return error.TestUnexpectedResult,
        ).asNum());

        slots = .{ Value.num(4).rawBits(), Value.num(0).rawBits(), Value.num(0).rawBits() };
        try std.testing.expect(osr.prepareScratch(entry_index, &slots, &.{}, &scratch));
        frame.steps_until_checkpoint = 43;
        steps = 0;
        try std.testing.expectEqual(jit.ExitStatus.side_exit, compiled.run(&frame));
        const true_checkpoint = compiled.deopt.?.points[frame.deopt_index];
        const expected_true_steps: u64 = if (pad_true) 22 else 40;
        const expected_true_i: f64 = if (pad_true) 1 else 2;
        try std.testing.expectEqual(expected_true_steps, steps);
        try std.testing.expectEqual(expected_true_i, Value.fromRawBits(
            compiled.deopt.?.values[true_checkpoint.first_value + 1].materialize(&slots, &scratch) orelse
                return error.TestUnexpectedResult,
        ).asNum());

        slots = .{ Value.num(4).rawBits(), Value.num(2).rawBits(), Value.num(20).rawBits() };
        try std.testing.expect(osr.prepareScratch(entry_index, &slots, &.{}, &scratch));
        frame.steps_until_checkpoint = 43;
        steps = 0;
        try std.testing.expectEqual(jit.ExitStatus.side_exit, compiled.run(&frame));
        const false_checkpoint = compiled.deopt.?.points[frame.deopt_index];
        const expected_false_steps: u64 = if (pad_true) 40 else 22;
        const expected_false_i: f64 = if (pad_true) 4 else 3;
        try std.testing.expectEqual(expected_false_steps, steps);
        try std.testing.expectEqual(expected_false_i, Value.fromRawBits(
            compiled.deopt.?.values[false_checkpoint.first_value + 1].materialize(&slots, &scratch) orelse
                return error.TestUnexpectedResult,
        ).asNum());
    }
}

fn makeTwoLatchLoopChunk(allocator: std.mem.Allocator) !bc.Chunk {
    var chunk = bc.Chunk.init(allocator);
    chunk.param_count = 1;
    chunk.local_count = 3;
    const zero = try chunk.addConst(Value.num(0));
    const one = try chunk.addConst(Value.num(1));
    const two = try chunk.addConst(Value.num(2));
    const ten = try chunk.addConst(Value.num(10));
    _ = try chunk.emit(.load_const, zero);
    _ = try chunk.emit(.store_local, 1);
    _ = try chunk.emit(.pop, 0);
    _ = try chunk.emit(.load_const, zero);
    _ = try chunk.emit(.store_local, 2);
    _ = try chunk.emit(.pop, 0);
    const enter_loop = try chunk.emit(.jump, 0);

    const header: u32 = @intCast(chunk.code.items.len);
    chunk.code.items[enter_loop].a = header;
    _ = try chunk.emit(.load_local, 1);
    _ = try chunk.emit(.load_local, 0);
    _ = try chunk.emit(.lt, 0);
    const leave_loop = try chunk.emit(.jump_if_false, 0);
    _ = try chunk.emit(.load_local, 1);
    _ = try chunk.emit(.load_const, two);
    _ = try chunk.emit(.lt, 0);
    const take_false = try chunk.emit(.jump_if_false, 0);

    _ = try chunk.emit(.load_local, 2);
    _ = try chunk.emit(.load_const, ten);
    _ = try chunk.emit(.add, 0);
    _ = try chunk.emit(.store_local, 2);
    _ = try chunk.emit(.pop, 0);
    _ = try chunk.emit(.load_local, 1);
    _ = try chunk.emit(.load_const, one);
    _ = try chunk.emit(.add, 0);
    _ = try chunk.emit(.store_local, 1);
    _ = try chunk.emit(.pop, 0);
    _ = try chunk.emit(.jump, header);

    const false_start: u32 = @intCast(chunk.code.items.len);
    chunk.code.items[take_false].a = false_start;
    _ = try chunk.emit(.load_local, 2);
    _ = try chunk.emit(.load_const, one);
    _ = try chunk.emit(.add, 0);
    _ = try chunk.emit(.store_local, 2);
    _ = try chunk.emit(.pop, 0);
    _ = try chunk.emit(.load_local, 1);
    _ = try chunk.emit(.load_const, one);
    _ = try chunk.emit(.add, 0);
    _ = try chunk.emit(.store_local, 1);
    _ = try chunk.emit(.pop, 0);
    _ = try chunk.emit(.jump, header);

    const exit: u32 = @intCast(chunk.code.items.len);
    chunk.code.items[leave_loop].a = exit;
    _ = try chunk.emit(.load_local, 2);
    _ = try chunk.emit(.ret, 0);
    return chunk;
}

test "optimizer loop OSR executes independent branch latches" {
    if (!jit.supported or builtin.cpu.arch != .aarch64) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var chunk = try makeTwoLatchLoopChunk(arena.allocator());
    var compiled = try compile(&chunk);
    defer compiled.deinit();
    try std.testing.expectEqual(@as(u32, 19), compiled.bytecode_steps);
    const osr = compiled.osr orelse return error.TestUnexpectedResult;
    const entry_index = osr.findEntry(7, 3, 0, 0, Value.undef().rawBits()) orelse
        return error.TestUnexpectedResult;
    var slots = [_]u64{ Value.num(4).rawBits(), Value.num(0).rawBits(), Value.num(0).rawBits() };
    var scratch: [jit.numeric_scratch_capacity]u64 = @splat(0);
    try std.testing.expect(osr.prepareScratch(entry_index, &slots, &.{}, &scratch));
    var steps: u64 = 0;
    var frame = jit.NativeFrame{
        .slots = &slots,
        .scratch = &scratch,
        .steps = &steps,
        .steps_until_checkpoint = 1024,
        .steps_until_budget = 1024,
    };
    try std.testing.expectEqual(jit.ExitStatus.side_exit, compiled.run(&frame));
    try std.testing.expectEqual(@as(usize, 37), frame.exit_ip);
    try std.testing.expectEqual(@as(u64, 80), steps);
    const exit = compiled.deopt.?.points[frame.deopt_index];
    try std.testing.expectEqual(@as(f64, 4), Value.fromRawBits(
        compiled.deopt.?.values[exit.first_value + 1].materialize(&slots, &scratch) orelse
            return error.TestUnexpectedResult,
    ).asNum());
    try std.testing.expectEqual(@as(f64, 22), Value.fromRawBits(
        compiled.deopt.?.values[exit.first_value + 2].materialize(&slots, &scratch) orelse
            return error.TestUnexpectedResult,
    ).asNum());
}

fn makeConditionalBreakLoopChunk(allocator: std.mem.Allocator) !bc.Chunk {
    var chunk = bc.Chunk.init(allocator);
    chunk.param_count = 1;
    chunk.local_count = 3;
    const zero = try chunk.addConst(Value.num(0));
    const one = try chunk.addConst(Value.num(1));
    const two = try chunk.addConst(Value.num(2));
    _ = try chunk.emit(.load_const, zero);
    _ = try chunk.emit(.store_local, 1);
    _ = try chunk.emit(.pop, 0);
    _ = try chunk.emit(.load_const, zero);
    _ = try chunk.emit(.store_local, 2);
    _ = try chunk.emit(.pop, 0);
    const enter_loop = try chunk.emit(.jump, 0);

    const header: u32 = @intCast(chunk.code.items.len);
    chunk.code.items[enter_loop].a = header;
    _ = try chunk.emit(.load_local, 1);
    _ = try chunk.emit(.load_local, 0);
    _ = try chunk.emit(.lt, 0);
    const leave_loop = try chunk.emit(.jump_if_false, 0);
    _ = try chunk.emit(.load_local, 1);
    _ = try chunk.emit(.load_const, two);
    _ = try chunk.emit(.eq, 0);
    const keep_running = try chunk.emit(.jump_if_false, 0);
    const break_jump = try chunk.emit(.jump, 0);

    const body: u32 = @intCast(chunk.code.items.len);
    chunk.code.items[keep_running].a = body;
    _ = try chunk.emit(.load_local, 2);
    _ = try chunk.emit(.load_const, one);
    _ = try chunk.emit(.add, 0);
    _ = try chunk.emit(.store_local, 2);
    _ = try chunk.emit(.pop, 0);
    _ = try chunk.emit(.load_local, 1);
    _ = try chunk.emit(.load_const, one);
    _ = try chunk.emit(.add, 0);
    _ = try chunk.emit(.store_local, 1);
    _ = try chunk.emit(.pop, 0);
    _ = try chunk.emit(.jump, header);

    const exit: u32 = @intCast(chunk.code.items.len);
    chunk.code.items[leave_loop].a = exit;
    chunk.code.items[break_jump].a = exit;
    _ = try chunk.emit(.load_local, 2);
    _ = try chunk.emit(.ret, 0);
    return chunk;
}

test "optimizer loop OSR side exits a conditional break edge" {
    if (!jit.supported or builtin.cpu.arch != .aarch64) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var chunk = try makeConditionalBreakLoopChunk(arena.allocator());
    var compiled = try compile(&chunk);
    defer compiled.deinit();
    try std.testing.expectEqual(@as(u32, 19), compiled.bytecode_steps);
    const osr = compiled.osr orelse return error.TestUnexpectedResult;
    const entry_index = osr.findEntry(7, 3, 0, 0, Value.undef().rawBits()) orelse
        return error.TestUnexpectedResult;
    var slots = [_]u64{ Value.num(5).rawBits(), Value.num(0).rawBits(), Value.num(0).rawBits() };
    var scratch: [jit.numeric_scratch_capacity]u64 = @splat(0);
    try std.testing.expect(osr.prepareScratch(entry_index, &slots, &.{}, &scratch));
    var steps: u64 = 0;
    var frame = jit.NativeFrame{
        .slots = &slots,
        .scratch = &scratch,
        .steps = &steps,
        .steps_until_checkpoint = 1024,
        .steps_until_budget = 1024,
    };
    try std.testing.expectEqual(jit.ExitStatus.side_exit, compiled.run(&frame));
    try std.testing.expectEqual(@as(usize, 27), frame.exit_ip);
    try std.testing.expectEqual(@as(u64, 47), steps);
    const exit = compiled.deopt.?.points[frame.deopt_index];
    try std.testing.expectEqual(@as(f64, 2), Value.fromRawBits(
        compiled.deopt.?.values[exit.first_value + 1].materialize(&slots, &scratch) orelse
            return error.TestUnexpectedResult,
    ).asNum());
    try std.testing.expectEqual(@as(f64, 2), Value.fromRawBits(
        compiled.deopt.?.values[exit.first_value + 2].materialize(&slots, &scratch) orelse
            return error.TestUnexpectedResult,
    ).asNum());
}

fn makeMultiExitLoopChunk(allocator: std.mem.Allocator) !bc.Chunk {
    var chunk = bc.Chunk.init(allocator);
    chunk.param_count = 1;
    chunk.local_count = 3;
    const zero = try chunk.addConst(Value.num(0));
    const one = try chunk.addConst(Value.num(1));
    const two = try chunk.addConst(Value.num(2));
    const ninety_nine = try chunk.addConst(Value.num(99));
    _ = try chunk.emit(.load_const, zero);
    _ = try chunk.emit(.store_local, 1);
    _ = try chunk.emit(.pop, 0);
    _ = try chunk.emit(.load_const, zero);
    _ = try chunk.emit(.store_local, 2);
    _ = try chunk.emit(.pop, 0);
    const enter_loop = try chunk.emit(.jump, 0);

    const header: u32 = @intCast(chunk.code.items.len);
    chunk.code.items[enter_loop].a = header;
    _ = try chunk.emit(.load_local, 1);
    _ = try chunk.emit(.load_local, 0);
    _ = try chunk.emit(.lt, 0);
    const leave_loop = try chunk.emit(.jump_if_false, 0);

    _ = try chunk.emit(.load_local, 1);
    _ = try chunk.emit(.load_const, two);
    _ = try chunk.emit(.eq, 0);
    const continue_first = try chunk.emit(.jump_if_false, 0);
    const first_break = try chunk.emit(.jump, 0);

    const second_guard: u32 = @intCast(chunk.code.items.len);
    chunk.code.items[continue_first].a = second_guard;
    _ = try chunk.emit(.load_local, 2);
    _ = try chunk.emit(.load_const, ninety_nine);
    _ = try chunk.emit(.eq, 0);
    const continue_second = try chunk.emit(.jump_if_false, 0);
    const second_break = try chunk.emit(.jump, 0);

    const body: u32 = @intCast(chunk.code.items.len);
    chunk.code.items[continue_second].a = body;
    _ = try chunk.emit(.load_local, 2);
    _ = try chunk.emit(.load_const, one);
    _ = try chunk.emit(.add, 0);
    _ = try chunk.emit(.store_local, 2);
    _ = try chunk.emit(.pop, 0);
    _ = try chunk.emit(.load_local, 1);
    _ = try chunk.emit(.load_const, one);
    _ = try chunk.emit(.add, 0);
    _ = try chunk.emit(.store_local, 1);
    _ = try chunk.emit(.pop, 0);
    _ = try chunk.emit(.jump, header);

    const exit: u32 = @intCast(chunk.code.items.len);
    chunk.code.items[leave_loop].a = exit;
    chunk.code.items[first_break].a = exit;
    chunk.code.items[second_break].a = exit;
    _ = try chunk.emit(.load_local, 2);
    _ = try chunk.emit(.ret, 0);
    return chunk;
}

test "optimizer loop OSR side exits either guard in a multi-exit chain" {
    if (!jit.supported or builtin.cpu.arch != .aarch64) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var chunk = try makeMultiExitLoopChunk(arena.allocator());
    var compiled = try compile(&chunk);
    defer compiled.deinit();
    try std.testing.expectEqual(@as(u32, 23), compiled.bytecode_steps);
    try std.testing.expectEqual(@as(usize, 5), compiled.deopt.?.points.len);
    const osr = compiled.osr orelse return error.TestUnexpectedResult;
    const entry_index = osr.findEntry(7, 3, 0, 0, Value.undef().rawBits()) orelse
        return error.TestUnexpectedResult;
    var scratch: [jit.numeric_scratch_capacity]u64 = @splat(0);

    var slots = [_]u64{ Value.num(5).rawBits(), Value.num(0).rawBits(), Value.num(0).rawBits() };
    try std.testing.expect(osr.prepareScratch(entry_index, &slots, &.{}, &scratch));
    var steps: u64 = 0;
    var frame = jit.NativeFrame{
        .slots = &slots,
        .scratch = &scratch,
        .steps = &steps,
        .steps_until_checkpoint = 1024,
        .steps_until_budget = 1024,
    };
    try std.testing.expectEqual(jit.ExitStatus.side_exit, compiled.run(&frame));
    try std.testing.expectEqual(@as(usize, 32), frame.exit_ip);
    try std.testing.expectEqual(@as(u64, 55), steps);
    var exit = compiled.deopt.?.points[frame.deopt_index];
    try std.testing.expectEqual(@as(f64, 2), Value.fromRawBits(
        compiled.deopt.?.values[exit.first_value + 1].materialize(&slots, &scratch) orelse
            return error.TestUnexpectedResult,
    ).asNum());
    try std.testing.expectEqual(@as(f64, 2), Value.fromRawBits(
        compiled.deopt.?.values[exit.first_value + 2].materialize(&slots, &scratch) orelse
            return error.TestUnexpectedResult,
    ).asNum());

    slots = .{ Value.num(5).rawBits(), Value.num(1).rawBits(), Value.num(99).rawBits() };
    try std.testing.expect(osr.prepareScratch(entry_index, &slots, &.{}, &scratch));
    steps = 0;
    frame.steps_until_checkpoint = 1024;
    frame.steps_until_budget = 1024;
    try std.testing.expectEqual(jit.ExitStatus.side_exit, compiled.run(&frame));
    try std.testing.expectEqual(@as(usize, 32), frame.exit_ip);
    try std.testing.expectEqual(@as(u64, 13), steps);
    exit = compiled.deopt.?.points[frame.deopt_index];
    try std.testing.expectEqual(@as(f64, 1), Value.fromRawBits(
        compiled.deopt.?.values[exit.first_value + 1].materialize(&slots, &scratch) orelse
            return error.TestUnexpectedResult,
    ).asNum());
    try std.testing.expectEqual(@as(f64, 99), Value.fromRawBits(
        compiled.deopt.?.values[exit.first_value + 2].materialize(&slots, &scratch) orelse
            return error.TestUnexpectedResult,
    ).asNum());
}

fn makeIrreducibleLoopChunk(allocator: std.mem.Allocator) !bc.Chunk {
    var chunk = bc.Chunk.init(allocator);
    chunk.param_count = 1;
    chunk.local_count = 1;
    _ = try chunk.emit(.load_local, 0);
    const enter_second = try chunk.emit(.jump_if_false, 0);

    const first: u32 = @intCast(chunk.code.items.len);
    _ = try chunk.emit(.load_local, 0);
    const leave_first = try chunk.emit(.jump_if_false, 0);
    const first_to_second = try chunk.emit(.jump, 0);

    const second: u32 = @intCast(chunk.code.items.len);
    chunk.code.items[enter_second].a = second;
    chunk.code.items[first_to_second].a = second;
    _ = try chunk.emit(.load_local, 0);
    const leave_second = try chunk.emit(.jump_if_false, 0);
    _ = try chunk.emit(.jump, first);

    const exit: u32 = @intCast(chunk.code.items.len);
    chunk.code.items[leave_first].a = exit;
    chunk.code.items[leave_second].a = exit;
    _ = try chunk.emit(.load_local, 0);
    _ = try chunk.emit(.ret, 0);
    return chunk;
}

test "optimizer loop OSR rejects an irreducible two-entry region" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var chunk = try makeIrreducibleLoopChunk(arena.allocator());
    try std.testing.expectError(error.UnsupportedChunk, compile(&chunk));
}
