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
    true_block: ?u32 = null,
    nested_loop: ?NestedLoopBranch = null,
};

pub const SideExit = struct {
    deopt_index: u16,
    steps: u12,
};

pub const NestedLoopBranch = struct {
    entry_block: u32,
    condition: u8,
    false_block: u32,
    true_block: u32,
    /// Shared latch for a diamond, or null when arms independently backedge
    /// or one arm exits the loop.
    merge_block: ?u32,
    /// A conditional loop exit deoptimizes either directly from the branch
    /// block or after a tiny arm block into the outer exit block.
    false_exit_from: ?u32 = null,
    true_exit_from: ?u32 = null,
    false_exit_deopt_index: ?u16 = null,
    true_exit_deopt_index: ?u16 = null,
    false_steps: u12,
    true_steps: u12,
};

pub const Program = struct {
    allocator: std.mem.Allocator,
    operations: []Operation,
    result: u8,
    branch: ?BranchSelection,
    side_exit: ?SideExit,
    side_exit_branch: ?SideExitBranch,
    scratch_slots: u8,
    frame_slots: u32,
    required_numeric_slots: u64,
    bytecode_steps: u32,
    deopt_points: []jit.DeoptPoint,
    deopt_values: []jit.RecoveryValue,
    deopt_handlers: []jit.RecoveryHandler,
    stack_maps: []jit.StackMap,
    osr: ?*jit.OsrMetadata = null,
    execution_block: u32 = 0,
    entry_enabled: bool = true,
    observe_loop_backedges: bool = false,

    pub fn deinit(self: *Program) void {
        self.allocator.free(self.operations);
        self.allocator.free(self.deopt_points);
        self.allocator.free(self.deopt_values);
        self.allocator.free(self.deopt_handlers);
        self.allocator.free(self.stack_maps);
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

const ValueType = enum { number, boolean, other };

pub fn lower(chunk: *const bc.Chunk, plan: *const optimizer.Plan, allocator: std.mem.Allocator) !Program {
    const graph = &plan.graph;
    if (graph.nodes.len == 0 or graph.nodes.len > jit.numeric_scratch_capacity or chunk.local_count > 64 or
        graph.branches.len > 1)
        return error.UnsupportedChunk;

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
        .mod => return error.UnsupportedChunk,
    };

    var result: optimizer.ValueId = 0;
    var branch_selection: ?BranchSelection = null;
    var side_exit: ?SideExit = null;
    var side_exit_branch: ?SideExitBranch = null;
    var bytecode_steps: u32 = 0;
    if (graph.branches.len == 0) {
        if (graph.edges.len != 1 or graph.edges[0].from != optimizer.Block.none or graph.edges[0].to != 0)
            return error.UnsupportedChunk;
        if (graph.returns.len == 1 and graph.returns[0].block == 0) {
            result = try resolveAlias(graph.returns[0].value, aliases);
            bytecode_steps = graph.returns[0].origin + 1;
        } else if (graph.returns.len == 0) {
            var throw_index: ?u16 = null;
            for (graph.frame_states, 0..) |state, index| if (state.kind == .throw_ or state.kind == .abrupt_return or state.kind == .abrupt_jump or state.kind == .call or state.kind == .effect) {
                if (throw_index != null or state.block != 0) return error.UnsupportedChunk;
                throw_index = std.math.cast(u16, index) orelse return error.UnsupportedChunk;
                bytecode_steps = state.origin;
            };
            side_exit = .{
                .deopt_index = throw_index orelse return error.UnsupportedChunk,
                .steps = std.math.cast(u12, bytecode_steps) orelse return error.UnsupportedChunk,
            };
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
    return .{
        .allocator = allocator,
        .operations = owned_operations,
        .result = @intCast(result),
        .branch = branch_selection,
        .side_exit = side_exit,
        .side_exit_branch = side_exit_branch,
        .scratch_slots = @intCast(graph.nodes.len),
        .frame_slots = chunk.local_count,
        .required_numeric_slots = required_numeric_slots,
        .bytecode_steps = bytecode_steps,
        .deopt_points = owned_deopt_points,
        .deopt_values = owned_deopt_values,
        .deopt_handlers = owned_deopt_handlers,
        .stack_maps = stack_maps,
    };
}

fn lowerLoopOsr(chunk: *const bc.Chunk, plan: *const optimizer.Plan, allocator: std.mem.Allocator) !Program {
    const graph = &plan.graph;
    if (graph.nodes.len == 0 or graph.nodes.len > jit.numeric_scratch_capacity or chunk.local_count > 64 or
        graph.branches.len == 0 or graph.branches.len > 2)
        return error.UnsupportedChunk;

    const osr = try buildOsrMetadata(plan, allocator);
    errdefer osr.destroy();
    if (osr.entries.len != 1) return error.UnsupportedChunk;
    const entry = osr.entries[0];
    if (entry.stack_count != 0) return error.UnsupportedChunk;
    var header_block: ?u32 = null;
    for (plan.blocks) |block| if (block.start == entry.entry_ip) {
        if (header_block != null) return error.UnsupportedChunk;
        header_block = block.id;
    };
    const header = header_block orelse return error.UnsupportedChunk;
    var outer_branch: ?optimizer.BranchValue = null;
    var inner_branch: ?optimizer.BranchValue = null;
    for (graph.branches) |candidate| {
        if (candidate.block == header) {
            if (outer_branch != null) return error.UnsupportedChunk;
            outer_branch = candidate;
        } else {
            if (inner_branch != null) return error.UnsupportedChunk;
            inner_branch = candidate;
        }
    }
    const branch = outer_branch orelse return error.UnsupportedChunk;
    if (branch.block != header or branch.false_block == branch.true_block) return error.UnsupportedChunk;

    var body: ?u32 = null;
    var nested_loop: ?NestedLoopBranch = null;
    var latch: u32 = undefined;
    var true_steps: u32 = undefined;
    if (inner_branch) |nested| {
        if (nested.block != branch.true_block or nested.false_block == nested.true_block or
            nested.false_block >= plan.blocks.len or nested.true_block >= plan.blocks.len)
            return error.UnsupportedChunk;
        const false_arm = plan.blocks[nested.false_block];
        const true_arm = plan.blocks[nested.true_block];
        const false_direct_exit = nested.false_block == branch.false_block;
        const true_direct_exit = nested.true_block == branch.false_block;
        const false_successor = if (false_arm.successor_count == 1) false_arm.successors[0] else null;
        const true_successor = if (true_arm.successor_count == 1) true_arm.successors[0] else null;
        const false_backedge = false_successor == header;
        const true_backedge = true_successor == header;
        const false_exit_from: ?u32 = if (false_direct_exit)
            nested.block
        else if (false_successor == branch.false_block)
            nested.false_block
        else
            null;
        const true_exit_from: ?u32 = if (true_direct_exit)
            nested.block
        else if (true_successor == branch.false_block)
            nested.true_block
        else
            null;
        const conditional_exit = (false_exit_from != null and true_backedge) or
            (true_exit_from != null and false_backedge);
        if (!conditional_exit and (false_arm.successor_count != 1 or true_arm.successor_count != 1))
            return error.UnsupportedChunk;
        const shared_successor = !conditional_exit and false_successor == true_successor;
        const merge: ?u32 = if (shared_successor and false_successor != header)
            false_successor
        else
            null;
        if (merge) |merge_block| {
            if (merge_block >= plan.blocks.len or plan.blocks[merge_block].successor_count != 1 or
                plan.blocks[merge_block].successors[0] != header)
                return error.UnsupportedChunk;
        } else if (!conditional_exit and (!false_backedge or !true_backedge)) {
            return error.UnsupportedChunk;
        }
        const false_steps = if (false_direct_exit)
            try sumInstructionCounts(plan, &.{ header, nested.block })
        else if (merge) |merge_block|
            try sumInstructionCounts(plan, &.{ header, nested.block, nested.false_block, merge_block })
        else
            try sumInstructionCounts(plan, &.{ header, nested.block, nested.false_block });
        const nested_true_steps = if (true_direct_exit)
            try sumInstructionCounts(plan, &.{ header, nested.block })
        else if (merge) |merge_block|
            try sumInstructionCounts(plan, &.{ header, nested.block, nested.true_block, merge_block })
        else
            try sumInstructionCounts(plan, &.{ header, nested.block, nested.true_block });
        latch = merge orelse if (false_backedge) nested.false_block else nested.true_block;
        true_steps = @max(false_steps, nested_true_steps);
        nested_loop = .{
            .entry_block = nested.block,
            .condition = @intCast(nested.condition),
            .false_block = nested.false_block,
            .true_block = nested.true_block,
            .merge_block = merge,
            .false_exit_from = false_exit_from,
            .true_exit_from = true_exit_from,
            .false_steps = std.math.cast(u12, false_steps) orelse return error.UnsupportedChunk,
            .true_steps = std.math.cast(u12, nested_true_steps) orelse return error.UnsupportedChunk,
        };
    } else {
        const straight_body = branch.true_block;
        if (straight_body >= plan.blocks.len or plan.blocks[straight_body].successor_count != 1 or
            plan.blocks[straight_body].successors[0] != header)
            return error.UnsupportedChunk;
        body = straight_body;
        latch = straight_body;
        true_steps = try sumInstructionCounts(plan, &.{ header, straight_body });
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
    if (nested_loop) |nested| {
        try appendEdgeCopies(graph, header, nested.entry_block, nested.entry_block, allocator, &operations, &types, &initialized, &required_numeric, &scratch_slots);
        try appendBlockOperations(graph, nested.entry_block, false, allocator, &operations, &types, &initialized, &required_numeric);
        if (types[nested.condition] != .boolean) return error.UnsupportedChunk;

        if (nested.true_exit_from != nested.entry_block) {
            try appendEdgeCopies(graph, nested.entry_block, nested.true_block, nested.true_block, allocator, &operations, &types, &initialized, &required_numeric, &scratch_slots);
            try appendBlockOperations(graph, nested.true_block, false, allocator, &operations, &types, &initialized, &required_numeric);
            if (nested.true_exit_from == null) {
                if (nested.merge_block) |merge_block|
                    try appendEdgeCopies(graph, nested.true_block, merge_block, nested.true_block, allocator, &operations, &types, &initialized, &required_numeric, &scratch_slots)
                else
                    try appendEdgeCopies(graph, nested.true_block, header, nested.true_block, allocator, &operations, &types, &initialized, &required_numeric, &scratch_slots);
            }
        }

        if (nested.false_exit_from != nested.entry_block) {
            try appendEdgeCopies(graph, nested.entry_block, nested.false_block, nested.false_block, allocator, &operations, &types, &initialized, &required_numeric, &scratch_slots);
            try appendBlockOperations(graph, nested.false_block, false, allocator, &operations, &types, &initialized, &required_numeric);
            if (nested.false_exit_from == null) {
                if (nested.merge_block) |merge_block|
                    try appendEdgeCopies(graph, nested.false_block, merge_block, nested.false_block, allocator, &operations, &types, &initialized, &required_numeric, &scratch_slots)
                else
                    try appendEdgeCopies(graph, nested.false_block, header, nested.false_block, allocator, &operations, &types, &initialized, &required_numeric, &scratch_slots);
            }
        }

        if (nested.merge_block) |merge_block| {
            try appendBlockOperations(graph, merge_block, false, allocator, &operations, &types, &initialized, &required_numeric);
            try appendEdgeCopies(graph, merge_block, header, merge_block, allocator, &operations, &types, &initialized, &required_numeric, &scratch_slots);
        }
    } else {
        const straight_body = body.?;
        try appendEdgeCopies(graph, header, straight_body, straight_body, allocator, &operations, &types, &initialized, &required_numeric, &scratch_slots);
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
    if (nested_loop) |*nested| {
        if (nested.false_exit_from) |from| nested.false_exit_deopt_index = try appendEdgeDeopt(
            graph,
            &initialized,
            from,
            branch.false_block,
            allocator,
            &deopt_points,
            &deopt_values,
        );
        if (nested.true_exit_from) |from| nested.true_exit_deopt_index = try appendEdgeDeopt(
            graph,
            &initialized,
            from,
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
            .true_block = body,
            .nested_loop = nested_loop,
        },
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
        error.UnsupportedChunk => try lowerLoopOsr(chunk, &plan, std.heap.page_allocator),
        else => return err,
    };
    defer program.deinit();
    return compileAarch64(&program);
}

fn compileAarch64(program: *const Program) !jit.CompiledCode {
    if (!jit.supported or builtin.cpu.arch != .aarch64) return error.UnsupportedTarget;
    var memory = try jit.CodeMemory.init(@as(usize, program.operations.len) * 64 + 1024);
    errdefer memory.deinit();
    var assembler = aarch64.Assembler.init(memory.writableBytes());
    try assembler.moveRegister64(12, 0); // stable NativeFrame
    try assembler.load64(13, 12, frameOffset("slots"));
    try assembler.load64(14, 12, frameOffset("scratch"));
    try emitInvalidationPoll(&assembler);

    for (program.operations) |operation| if (operation.block == optimizer.Block.none)
        try emitOperation(&assembler, operation);
    if (program.side_exit) |side_exit| {
        for (program.operations) |operation| if (operation.block == program.execution_block)
            try emitOperation(&assembler, operation);
        try emitStepIncrement(&assembler, side_exit.steps);
        try emitSideExit(&assembler, side_exit.deopt_index, program.deopt_points[side_exit.deopt_index].exit_ip);
    } else if (program.side_exit_branch) |branch| if (branch.entry_deopt_index) |entry_deopt_index| {
        try assembler.load64(15, 12, frameOffset("steps_until_checkpoint"));
        try assembler.load64(16, 12, frameOffset("steps_until_budget"));
        try assembler.movImmediate32(8, 64);
        const loop_top = assembler.position();
        const invalidated = try emitInvalidationSideExitPoll(&assembler);
        try assembler.compareImmediate64(15, branch.true_steps);
        const checkpoint_exit = try assembler.branchConditionPlaceholder(.ls);
        try assembler.compareImmediate64(16, branch.true_steps);
        const budget_exit = try assembler.branchConditionPlaceholder(.lo);
        for (program.operations) |operation| if (operation.block == program.execution_block)
            try emitOperation(&assembler, operation);
        try assembler.load64(9, 14, try slotOffset(branch.condition));
        try assembler.movImmediate64(10, Value.boolVal(false).rawBits());
        try assembler.compareRegister64(9, 10);
        const false_jump = try assembler.branchConditionPlaceholder(.eq);
        if (branch.nested_loop) |nested| {
            try emitBlockOperations(&assembler, program, nested.entry_block);
            try assembler.load64(9, 14, try slotOffset(nested.condition));
            try assembler.movImmediate64(10, Value.boolVal(false).rawBits());
            try assembler.compareRegister64(9, 10);
            const nested_false_jump = try assembler.branchConditionPlaceholder(.eq);
            if (nested.true_exit_deopt_index) |exit_index| {
                if (nested.true_exit_from != nested.entry_block)
                    try emitBlockOperations(&assembler, program, nested.true_block);
                try emitStepIncrement(&assembler, nested.true_steps);
                try emitSideExit(&assembler, exit_index, program.deopt_points[exit_index].exit_ip);
            } else {
                try emitBlockOperations(&assembler, program, nested.true_block);
                if (nested.merge_block) |merge_block| try emitBlockOperations(&assembler, program, merge_block);
                try emitStepIncrement(&assembler, nested.true_steps);
                try assembler.subtractImmediate64(15, 15, nested.true_steps);
                try assembler.subtractImmediate64(16, 16, nested.true_steps);
                try emitMovingSafepointPoll(&assembler, entry_deopt_index, program.deopt_points[entry_deopt_index].exit_ip);
                if (program.observe_loop_backedges) try emitBackedgeObserver(&assembler);
                const true_backedge = try assembler.branchPlaceholder();
                try assembler.patchBranch(true_backedge, loop_top);
            }

            try assembler.patchConditionBranch(nested_false_jump, assembler.position());
            if (nested.false_exit_deopt_index) |exit_index| {
                if (nested.false_exit_from != nested.entry_block)
                    try emitBlockOperations(&assembler, program, nested.false_block);
                try emitStepIncrement(&assembler, nested.false_steps);
                try emitSideExit(&assembler, exit_index, program.deopt_points[exit_index].exit_ip);
            } else {
                try emitBlockOperations(&assembler, program, nested.false_block);
                if (nested.merge_block) |merge_block| try emitBlockOperations(&assembler, program, merge_block);
                try emitStepIncrement(&assembler, nested.false_steps);
                try assembler.subtractImmediate64(15, 15, nested.false_steps);
                try assembler.subtractImmediate64(16, 16, nested.false_steps);
                try emitMovingSafepointPoll(&assembler, entry_deopt_index, program.deopt_points[entry_deopt_index].exit_ip);
                if (program.observe_loop_backedges) try emitBackedgeObserver(&assembler);
                const false_backedge = try assembler.branchPlaceholder();
                try assembler.patchBranch(false_backedge, loop_top);
            }
        } else {
            try emitBlockOperations(&assembler, program, branch.true_block.?);
            try emitStepIncrement(&assembler, branch.true_steps);
            try assembler.subtractImmediate64(15, 15, branch.true_steps);
            try assembler.subtractImmediate64(16, 16, branch.true_steps);
            try emitMovingSafepointPoll(&assembler, entry_deopt_index, program.deopt_points[entry_deopt_index].exit_ip);
            if (program.observe_loop_backedges) try emitBackedgeObserver(&assembler);
            const backedge = try assembler.branchPlaceholder();
            try assembler.patchBranch(backedge, loop_top);
        }

        try assembler.patchConditionBranch(false_jump, assembler.position());
        try emitStepIncrement(&assembler, branch.false_steps);
        try emitSideExit(&assembler, branch.false_deopt_index, program.deopt_points[branch.false_deopt_index].exit_ip);

        const poll_exit = assembler.position();
        try assembler.patchConditionBranch(invalidated, poll_exit);
        try assembler.patchConditionBranch(checkpoint_exit, poll_exit);
        try assembler.patchConditionBranch(budget_exit, poll_exit);
        try emitSideExit(&assembler, entry_deopt_index, program.deopt_points[entry_deopt_index].exit_ip);
    } else {
        for (program.operations) |operation| if (operation.block == program.execution_block)
            try emitOperation(&assembler, operation);
        try assembler.load64(9, 14, try slotOffset(branch.condition));
        try assembler.movImmediate64(10, Value.boolVal(false).rawBits());
        try assembler.compareRegister64(9, 10);
        const false_jump = try assembler.branchConditionPlaceholder(.eq);
        if (branch.true_block) |block| for (program.operations) |operation|
            if (operation.block == block) try emitOperation(&assembler, operation);
        try emitStepIncrement(&assembler, branch.true_steps);
        try emitSideExit(&assembler, branch.true_deopt_index, program.deopt_points[branch.true_deopt_index].exit_ip);
        try assembler.patchConditionBranch(false_jump, assembler.position());
        try emitStepIncrement(&assembler, branch.false_steps);
        try emitSideExit(&assembler, branch.false_deopt_index, program.deopt_points[branch.false_deopt_index].exit_ip);
    } else if (program.branch) |branch| {
        for (program.operations) |operation| if (operation.block == program.execution_block)
            try emitOperation(&assembler, operation);
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
        for (program.operations) |operation| if (operation.block == program.execution_block)
            try emitOperation(&assembler, operation);
        try assembler.load64(9, 14, try slotOffset(program.result));
    }
    if (program.side_exit == null and program.side_exit_branch == null) {
        try assembler.store64(9, 12, frameOffset("result_bits"));
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
        .osr = osr,
        .entry_enabled = program.entry_enabled,
        .manages_steps = program.side_exit != null or program.side_exit_branch != null,
        .has_side_exits = program.side_exit != null or program.side_exit_branch != null,
    };
}

fn emitBlockOperations(assembler: *aarch64.Assembler, program: *const Program, block: u32) !void {
    for (program.operations) |operation| if (operation.block == block)
        try emitOperation(assembler, operation);
}

fn emitOperation(assembler: *aarch64.Assembler, operation: Operation) !void {
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
    }
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
    try assembler.movImmediate32(8, 64);
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

test "optimizer lowering publishes an exact throw side exit" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var chunk = bc.Chunk.init(arena.allocator());
    const seven = try chunk.addConst(Value.num(7));
    _ = try chunk.emitAB(.push_handler, 4, std.math.maxInt(u32));
    _ = try chunk.emit(.load_const, seven);
    _ = try chunk.emit(.throw_op, 0);
    _ = try chunk.emit(.ret_undef, 0);
    _ = try chunk.emit(.ret_undef, 0);
    var plan = try optimizer.build(&chunk, std.testing.allocator);
    defer plan.deinit();
    var program = try lower(&chunk, &plan, std.testing.allocator);
    defer program.deinit();

    const side_exit = program.side_exit orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u16, 1), side_exit.deopt_index);
    try std.testing.expectEqual(@as(u12, 2), side_exit.steps);
    try std.testing.expectEqual(@as(u32, 2), program.bytecode_steps);
    const point = program.deopt_points[side_exit.deopt_index];
    try std.testing.expectEqual(jit.DeoptPointKind.throw_, point.kind);
    try std.testing.expectEqual(@as(u32, 2), point.exit_ip);
    try std.testing.expectEqual(@as(u16, 1), point.stack_count);
    try std.testing.expectEqual(@as(u16, 1), point.handler_count);
    try std.testing.expectEqual(@as(u32, 4), program.deopt_handlers[point.first_handler].catch_ip);

    if (jit.supported and builtin.cpu.arch == .aarch64) {
        var compiled = try compile(&chunk);
        defer compiled.deinit();
        try std.testing.expect(compiled.manages_steps);
        try std.testing.expect(compiled.has_side_exits);
        var scratch: [jit.numeric_scratch_capacity]u64 = undefined;
        var steps: u64 = 0;
        var frame = jit.NativeFrame{ .scratch = &scratch, .steps = &steps };
        try std.testing.expectEqual(jit.ExitStatus.side_exit, compiled.run(&frame));
        try std.testing.expectEqual(@as(usize, 2), frame.exit_ip);
        try std.testing.expectEqual(@as(u64, 2), steps);
        try std.testing.expectEqual(jit.DeoptPointKind.throw_, compiled.deopt.?.points[frame.deopt_index].kind);
    }
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

test "optimizer lowering publishes an exact pre-call side exit" {
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

    const side_exit = program.side_exit orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u12, 2), side_exit.steps);
    try std.testing.expectEqual(@as(u64, 0), program.required_numeric_slots);
    const point = program.deopt_points[side_exit.deopt_index];
    try std.testing.expectEqual(jit.DeoptPointKind.call, point.kind);
    try std.testing.expectEqual(@as(u32, 2), point.exit_ip);
    try std.testing.expectEqual(@as(u16, 2), point.stack_count);
    const map = program.stack_maps[side_exit.deopt_index];
    try std.testing.expectEqual(@as(u64, 0b11), map.frame_pointer_slots);
    try std.testing.expectEqual(@as(u64, 0), map.scratch_pointer_slots);
    for (program.deopt_values[point.first_value .. point.first_value + point.local_count + point.stack_count]) |recovery|
        try std.testing.expectEqual(jit.RecoverySource.frame_slot, recovery.source);
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

test "optimizer lowering publishes an exact pre-property-effect side exit" {
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

    const side_exit = program.side_exit orelse return error.TestUnexpectedResult;
    const point = program.deopt_points[side_exit.deopt_index];
    try std.testing.expectEqual(jit.DeoptPointKind.effect, point.kind);
    try std.testing.expectEqual(@as(u32, 1), point.exit_ip);
    try std.testing.expectEqual(@as(u16, 1), point.stack_count);
    try std.testing.expectEqual(@as(u64, 1), program.stack_maps[side_exit.deopt_index].frame_pointer_slots);
}

test "optimizer lowering publishes an exact pre-construction side exit" {
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

    const side_exit = program.side_exit orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u12, 2), side_exit.steps);
    try std.testing.expectEqual(@as(u64, 0), program.required_numeric_slots);
    const point = program.deopt_points[side_exit.deopt_index];
    try std.testing.expectEqual(jit.DeoptPointKind.call, point.kind);
    try std.testing.expectEqual(@as(u16, 2), point.stack_count);
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
        .{ .op = .call_with_this, .a = 1, .inputs = 3, .kind = .call },
        .{ .op = .new_spread, .inputs = 2, .kind = .call },
        .{ .op = .tail_call_eval, .a = 1, .inputs = 2, .kind = .call },
        .{ .op = .tail_call_method, .b = 1, .inputs = 2, .kind = .call },
        .{ .op = .tail_call_with_this, .a = 1, .inputs = 3, .kind = .call },
        .{ .op = .get_index, .inputs = 2, .kind = .effect },
        .{ .op = .set_prop, .inputs = 2, .kind = .effect },
        .{ .op = .set_index, .inputs = 3, .kind = .effect },
        .{ .op = .instance_of, .inputs = 2, .kind = .effect },
        .{ .op = .private_in, .inputs = 1, .kind = .effect },
        .{ .op = .store_var, .inputs = 1, .kind = .effect },
        .{ .op = .def_var, .inputs = 1, .kind = .effect },
        .{ .op = .def_lex, .inputs = 1, .kind = .effect },
        .{ .op = .bind_pattern, .inputs = 1, .kind = .effect },
        .{ .op = .store_upval, .inputs = 1, .kind = .effect },
        .{ .op = .neg, .inputs = 1, .kind = .effect },
        .{ .op = .pos, .inputs = 1, .kind = .effect },
        .{ .op = .not, .inputs = 1, .kind = .effect },
        .{ .op = .typeof_op, .inputs = 1, .kind = .effect },
        .{ .op = .void_op, .inputs = 1, .kind = .effect },
        .{ .op = .to_numeric, .inputs = 1, .kind = .effect },
        .{ .op = .inc, .inputs = 1, .kind = .effect },
        .{ .op = .dec, .inputs = 1, .kind = .effect },
        .{ .op = .to_property_key, .inputs = 1, .kind = .effect },
        .{ .op = .bit_not, .inputs = 1, .kind = .effect },
        .{ .op = .to_string, .inputs = 1, .kind = .effect },
        .{ .op = .pow, .inputs = 2, .kind = .effect },
        .{ .op = .in_op, .inputs = 2, .kind = .effect },
        .{ .op = .bit_and, .inputs = 2, .kind = .effect },
        .{ .op = .bit_or, .inputs = 2, .kind = .effect },
        .{ .op = .bit_xor, .inputs = 2, .kind = .effect },
        .{ .op = .shl, .inputs = 2, .kind = .effect },
        .{ .op = .shr, .inputs = 2, .kind = .effect },
        .{ .op = .ushr, .inputs = 2, .kind = .effect },
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
