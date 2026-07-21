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

pub const BranchSelection = struct {
    condition: u8,
    false_result: u8,
    true_result: u8,
};

pub const SideExitBranch = struct {
    condition: u8,
    false_deopt_index: u16,
    true_deopt_index: u16,
    common_steps: u12,
};

pub const Program = struct {
    allocator: std.mem.Allocator,
    operations: []Operation,
    result: u8,
    branch: ?BranchSelection,
    side_exit_branch: ?SideExitBranch,
    scratch_slots: u8,
    frame_slots: u32,
    required_numeric_slots: u64,
    bytecode_steps: u32,
    deopt_points: []jit.DeoptPoint,
    deopt_values: []jit.RecoveryValue,
    osr: ?*jit.OsrMetadata = null,
    execution_block: u32 = 0,
    entry_enabled: bool = true,

    pub fn deinit(self: *Program) void {
        self.allocator.free(self.operations);
        self.allocator.free(self.deopt_points);
        self.allocator.free(self.deopt_values);
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
    for (graph.nodes) |node| switch (node.kind) {
        .block_argument => {},
        .argument => {
            if (node.immediate >= chunk.param_count or node.immediate >= 64) return error.UnsupportedChunk;
            required_numeric_slots |= @as(u64, 1) << @intCast(node.immediate);
            types[node.id] = .number;
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
    var side_exit_branch: ?SideExitBranch = null;
    var bytecode_steps: u32 = 0;
    if (graph.branches.len == 0) {
        if (graph.returns.len != 1 or graph.returns[0].block != 0 or graph.edges.len != 1 or
            graph.edges[0].from != optimizer.Block.none or graph.edges[0].to != 0)
            return error.UnsupportedChunk;
        result = try resolveAlias(graph.returns[0].value, aliases);
        bytecode_steps = graph.returns[0].origin + 1;
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
            };
        } else {
            bytecode_steps = plan.blocks[0].instruction_count;
            side_exit_branch = .{
                .condition = @intCast(condition),
                .false_deopt_index = try blockEntryStateIndex(graph.frame_states, branch.false_block),
                .true_deopt_index = try blockEntryStateIndex(graph.frame_states, branch.true_block),
                .common_steps = @intCast(plan.blocks[0].instruction_count),
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
            try deopt_values.append(allocator, .{ .source = .scratch_slot, .index = @intCast(resolved) });
        }
        try deopt_points.append(allocator, .{
            .kind = switch (state.kind) {
                .block_entry => .block_entry,
                .branch => .branch,
                .return_ => .return_,
            },
            .exit_ip = state.origin,
            .first_value = first_value,
            .local_count = @intCast(state.local_count),
            .stack_count = @intCast(state.stack_count),
            .accumulator = .{ .source = .constant, .bits = Value.undef().rawBits() },
        });
    }
    const owned_operations = try operations.toOwnedSlice(allocator);
    errdefer allocator.free(owned_operations);
    const owned_deopt_points = try deopt_points.toOwnedSlice(allocator);
    errdefer allocator.free(owned_deopt_points);
    const owned_deopt_values = try deopt_values.toOwnedSlice(allocator);
    errdefer allocator.free(owned_deopt_values);
    return .{
        .allocator = allocator,
        .operations = owned_operations,
        .result = @intCast(result),
        .branch = branch_selection,
        .side_exit_branch = side_exit_branch,
        .scratch_slots = @intCast(graph.nodes.len),
        .frame_slots = chunk.local_count,
        .required_numeric_slots = required_numeric_slots,
        .bytecode_steps = bytecode_steps,
        .deopt_points = owned_deopt_points,
        .deopt_values = owned_deopt_values,
    };
}

fn lowerLoopOsr(chunk: *const bc.Chunk, plan: *const optimizer.Plan, allocator: std.mem.Allocator) !Program {
    const graph = &plan.graph;
    if (graph.nodes.len == 0 or graph.nodes.len > jit.numeric_scratch_capacity or chunk.local_count > 64 or
        graph.branches.len != 1)
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
    const branch = graph.branches[0];
    if (branch.block != header or branch.false_block == branch.true_block) return error.UnsupportedChunk;

    var types: [jit.numeric_scratch_capacity]ValueType = @splat(.other);
    var initialized: [jit.numeric_scratch_capacity]bool = @splat(false);
    var operations: std.ArrayListUnmanaged(Operation) = .empty;
    errdefer operations.deinit(allocator);
    for (graph.nodes) |node| {
        if (node.block != header) continue;
        switch (node.kind) {
            .block_argument => {
                types[node.id] = .number;
                initialized[node.id] = true;
            },
            .constant => {
                const constant = Value.fromRawBits(node.immediate);
                types[node.id] = if (constant.isNumber()) .number else if (constant.isBoolean()) .boolean else .other;
                try operations.append(allocator, .{
                    .kind = .constant,
                    .destination = @intCast(node.id),
                    .block = header,
                    .immediate = node.immediate,
                });
                initialized[node.id] = true;
            },
            .true, .false => {
                types[node.id] = .boolean;
                try operations.append(allocator, .{
                    .kind = .constant,
                    .destination = @intCast(node.id),
                    .block = header,
                    .immediate = Value.boolVal(node.kind == .true).rawBits(),
                });
                initialized[node.id] = true;
            },
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
                    .block = header,
                    .lhs = @intCast(node.lhs),
                    .rhs = @intCast(node.rhs),
                });
                initialized[node.id] = true;
            },
            else => return error.UnsupportedChunk,
        }
    }
    if (types[branch.condition] != .boolean) return error.UnsupportedChunk;

    var deopt_points: std.ArrayListUnmanaged(jit.DeoptPoint) = .empty;
    errdefer deopt_points.deinit(allocator);
    var deopt_values: std.ArrayListUnmanaged(jit.RecoveryValue) = .empty;
    errdefer deopt_values.deinit(allocator);
    const false_index = try appendEdgeDeopt(graph, &initialized, header, branch.false_block, allocator, &deopt_points, &deopt_values);
    const true_index = try appendEdgeDeopt(graph, &initialized, header, branch.true_block, allocator, &deopt_points, &deopt_values);

    const owned_operations = try operations.toOwnedSlice(allocator);
    errdefer allocator.free(owned_operations);
    const owned_deopt_points = try deopt_points.toOwnedSlice(allocator);
    errdefer allocator.free(owned_deopt_points);
    const owned_deopt_values = try deopt_values.toOwnedSlice(allocator);
    errdefer allocator.free(owned_deopt_values);
    const local_mask: u64 = if (chunk.local_count == 64)
        std.math.maxInt(u64)
    else
        (@as(u64, 1) << @intCast(chunk.local_count)) - 1;
    return .{
        .allocator = allocator,
        .operations = owned_operations,
        .result = 0,
        .branch = null,
        .side_exit_branch = .{
            .condition = @intCast(branch.condition),
            .false_deopt_index = false_index,
            .true_deopt_index = true_index,
            .common_steps = @intCast(plan.blocks[header].instruction_count),
        },
        .scratch_slots = @intCast(graph.nodes.len),
        .frame_slots = chunk.local_count,
        .required_numeric_slots = local_mask,
        .bytecode_steps = plan.blocks[header].instruction_count,
        .deopt_points = owned_deopt_points,
        .deopt_values = owned_deopt_values,
        .osr = osr,
        .execution_block = header,
        .entry_enabled = false,
    };
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
    var memory = try jit.CodeMemory.init(@as(usize, program.operations.len) * 64 + 128);
    errdefer memory.deinit();
    var assembler = aarch64.Assembler.init(memory.writableBytes());
    try assembler.moveRegister64(12, 0); // stable NativeFrame
    try assembler.load64(13, 12, frameOffset("slots"));
    try assembler.load64(14, 12, frameOffset("scratch"));
    try emitInvalidationPoll(&assembler);

    for (program.operations) |operation| {
        if (program.side_exit_branch != null and operation.block != optimizer.Block.none and operation.block != program.execution_block) continue;
        switch (operation.kind) {
            .argument => {
                try assembler.load64(9, 13, try slotOffset(operation.immediate));
                try assembler.store64(9, 14, try slotOffset(operation.destination));
            },
            .constant => {
                try assembler.movImmediate64(9, operation.immediate);
                try assembler.store64(9, 14, try slotOffset(operation.destination));
            },
            .add, .sub, .mul, .div => {
                try loadNumericOperands(&assembler, operation);
                try assembler.floatBinary64(switch (operation.kind) {
                    .add => .add,
                    .sub => .sub,
                    .mul => .mul,
                    .div => .div,
                    else => unreachable,
                }, 0, 0, 1);
                try emitCanonicalNumber(&assembler, 9, 0);
                try assembler.store64(9, 14, try slotOffset(operation.destination));
            },
            .lt, .le, .gt, .ge, .eq, .neq => {
                try loadNumericOperands(&assembler, operation);
                try assembler.compareFloat64(0, 1);
                try assembler.conditionalSet32(9, comparisonCondition(operation.kind));
                try assembler.movImmediate64(10, Value.boolVal(false).rawBits());
                try assembler.addRegister64(9, 10, 9);
                try assembler.store64(9, 14, try slotOffset(operation.destination));
            },
        }
    }
    if (program.side_exit_branch) |branch| {
        try assembler.load64(9, 12, frameOffset("steps"));
        try assembler.load64(10, 9, 0);
        try assembler.addImmediate64(10, 10, branch.common_steps);
        try assembler.store64(10, 9, 0);
        try assembler.load64(9, 14, try slotOffset(branch.condition));
        try assembler.movImmediate64(10, Value.boolVal(false).rawBits());
        try assembler.compareRegister64(9, 10);
        const false_jump = try assembler.branchConditionPlaceholder(.eq);
        try emitSideExit(&assembler, branch.true_deopt_index, program.deopt_points[branch.true_deopt_index].exit_ip);
        try assembler.patchConditionBranch(false_jump, assembler.position());
        try emitSideExit(&assembler, branch.false_deopt_index, program.deopt_points[branch.false_deopt_index].exit_ip);
    } else if (program.branch) |branch| {
        try assembler.load64(9, 14, try slotOffset(branch.condition));
        try assembler.movImmediate64(10, Value.boolVal(false).rawBits());
        try assembler.compareRegister64(9, 10);
        const false_jump = try assembler.branchConditionPlaceholder(.eq);
        try assembler.load64(9, 14, try slotOffset(branch.true_result));
        const done = try assembler.branchPlaceholder();
        try assembler.patchConditionBranch(false_jump, assembler.position());
        try assembler.load64(9, 14, try slotOffset(branch.false_result));
        try assembler.patchBranch(done, assembler.position());
    } else {
        try assembler.load64(9, 14, try slotOffset(program.result));
    }
    if (program.side_exit_branch == null) {
        try assembler.store64(9, 12, frameOffset("result_bits"));
        try assembler.movImmediate32(0, @backingInt(jit.ExitStatus.complete));
        try assembler.ret();
    }
    try memory.publish(assembler.bytes().len);
    const deopt = try jit.DeoptMetadata.create(std.heap.page_allocator, program.deopt_points, program.deopt_values);
    errdefer deopt.destroy();
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
        .osr = osr,
        .entry_enabled = program.entry_enabled,
        .manages_steps = program.side_exit_branch != null,
        .has_side_exits = program.side_exit_branch != null,
    };
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
    const eleven = try chunk.addConst(Value.num(11));
    const twenty_two = try chunk.addConst(Value.num(22));
    _ = try chunk.emit(.load_local, 0);
    _ = try chunk.emit(.load_local, 1);
    _ = try chunk.emit(.lt, 0);
    _ = try chunk.emit(.jump_if_false, 6);
    _ = try chunk.emit(.load_const, eleven);
    _ = try chunk.emit(.ret, 0);
    _ = try chunk.emit(.load_const, twenty_two);
    _ = try chunk.emit(.ret, 0);
    return chunk;
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
    try std.testing.expectEqual(jit.DeoptPointKind.block_entry, program.deopt_points[0].kind);
    try std.testing.expectEqual(jit.DeoptPointKind.return_, program.deopt_points[1].kind);
    try std.testing.expectEqual(OperationKind.mul, program.operations[program.operations.len - 1].kind);
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
    try std.testing.expectEqual(@as(u32, 6), program.bytecode_steps);
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

test "optimizer compiler executes one loop-header OSR region" {
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
    var frame = jit.NativeFrame{ .slots = slots[0..].ptr, .scratch = &scratch, .steps = &steps };
    try std.testing.expectEqual(jit.ExitStatus.side_exit, compiled.run(&frame));
    try std.testing.expectEqual(@as(usize, 8), frame.exit_ip);
    try std.testing.expectEqual(@as(u64, 4), steps);
    try std.testing.expectEqual(jit.DeoptPointKind.edge, compiled.deopt.?.points[frame.deopt_index].kind);

    var invalidation_generation: std.atomic.Value(u64) = .init(1);
    frame.invalidation_generation = &invalidation_generation;
    frame.expected_invalidation_generation = 0;
    steps = 0;
    try std.testing.expectEqual(jit.ExitStatus.invalidated, compiled.run(&frame));
    try std.testing.expectEqual(@as(u64, 0), steps);

    invalidation_generation.store(0, .release);
    slots[1] = Value.num(9).rawBits();
    try std.testing.expect(osr.prepareScratch(entry_index, &slots, &.{}, &scratch));
    steps = 0;
    try std.testing.expectEqual(jit.ExitStatus.side_exit, compiled.run(&frame));
    try std.testing.expectEqual(@as(usize, 14), frame.exit_ip);
    try std.testing.expectEqual(@as(u64, 4), steps);
}
