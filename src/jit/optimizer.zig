//! Architecture-neutral optimizer foundation.
//!
//! This first layer turns the currently supported numeric/control bytecode
//! subset into a deterministic control-flow plan. It deliberately does not
//! execute the plan yet: baseline native code and the interpreter remain the
//! only executable tiers until guarded lowering and deoptimization metadata
//! land. Keeping planning separate prevents baseline publication or shell
//! counters from being mislabeled as optimizing execution.

const std = @import("std");
const bc = @import("../bytecode.zig");
const RuntimeValue = @import("../value.zig").Value;

pub const BuildError = std.mem.Allocator.Error || error{
    EmptyChunk,
    InvalidControlFlow,
    UnsupportedChunk,
};

pub const Instruction = struct {
    id: u32,
    origin: u32,
    op: bc.Op,
    a: u32,
    b: u32,
};

pub const ValueId = u32;

/// SSA values use block arguments instead of mutable phi nodes. Every incoming
/// edge supplies the live local/stack values for its target block, which keeps
/// loops deterministic without a sealing or renaming pass.
pub const ValueKind = enum {
    argument,
    block_argument,
    constant,
    undefined,
    null,
    true,
    false,
    add,
    sub,
    mul,
    div,
    mod,
    pow,
    bit_and,
    bit_or,
    bit_xor,
    shl,
    shr,
    ushr,
    lt,
    le,
    gt,
    ge,
    eq,
    neq,
    eq_strict,
    neq_strict,
    to_numeric,
    neg,
    pos,
    not,
    typeof_op,
    inc,
    dec,
    bit_not,
    to_string,
    to_property_key,
    call,
    call_eval,
    call_method,
    call_spread,
    call_eval_spread,
    call_with_this_spread,
    call_with_this,
    construct,
    construct_spread,
    new_object,
    new_array,
    init_prop,
    init_proto,
    init_prop_computed,
    init_spread,
    init_getter,
    init_setter,
    array_append,
    array_spread,
    array_append_hole,
    get_prop,
    get_index,
    set_prop,
    set_index,
    in_op,
    instance_of,
    private_in,
};

pub const ValueNode = struct {
    id: ValueId,
    block: u32,
    origin: u32,
    kind: ValueKind,
    lhs: ValueId = none,
    rhs: ValueId = none,
    third: ValueId = none,
    immediate: u64 = 0,
    may_have_effect: bool = false,

    pub const none = std.math.maxInt(ValueId);
};

pub const EdgeKind = enum { normal, catch_, finally_ };

pub const Edge = struct {
    from: u32,
    to: u32,
    first_argument: u32,
    argument_count: u32,
    kind: EdgeKind = .normal,
};

pub const ReturnValue = struct {
    block: u32,
    origin: u32,
    value: ValueId,
};

pub const BranchValue = struct {
    block: u32,
    origin: u32,
    condition: ValueId,
    false_block: u32,
    true_block: u32,
};

pub const FrameStateKind = enum { block_entry, branch, return_, throw_, finally_dispatch, abrupt_return, abrupt_jump, call, effect };

fn terminalFrameStateKind(op: bc.Op) ?FrameStateKind {
    return switch (op) {
        .throw_op => .throw_,
        .end_finally => .finally_dispatch,
        .abrupt_return => .abrupt_return,
        .abrupt_break, .abrupt_continue => .abrupt_jump,
        .tail_call,
        .tail_call_eval,
        .tail_call_method,
        .tail_call_with_this,
        => .call,
        .load_bigint,
        .load_var,
        .load_var_or_undef,
        .store_var,
        .def_var,
        .def_lex,
        .bind_pattern,
        .load_upval,
        .store_upval,
        .name_anon,
        .load_this,
        .load_new_target,
        .super_get,
        .super_get_index,
        .enter_block,
        .exit_block,
        .dispose_scope,
        .enter_with,
        .exit_with,
        .make_regex,
        .register_disposable,
        .import_call,
        .make_closure,
        .assert_iter_result,
        .iter_of,
        .async_iter_of,
        .enum_keys,
        .iter_close,
        .iter_close_completion,
        .async_iter_close,
        .async_iter_close_completion,
        .eval_class,
        .template_object,
        => .effect,
        else => null,
    };
}

pub const HandlerState = struct {
    catch_ip: u32,
    finally_ip: u32,
    stack_depth: u32,
};

/// Interpreter-owned operation target if the operation raises after its
/// mandatory pre-effect side exit. The exception value does not exist yet, so
/// this records control/unwind state rather than an SSA value edge.
pub const ExceptionalTarget = struct {
    block: u32,
    origin: u32,
    target: u32,
    kind: EdgeKind,
    unwind_stack_depth: u32,
    target_stack_depth: u32,
    first_handler: u32,
    handler_count: u32,
};

/// Immutable interpreter reconstruction state at an optimizer entry or exit.
/// Values are SSA ids in locals-then-operand-stack order. Keeping the boundary
/// explicit prevents a future side exit from guessing at dead values or
/// restarting bytecode after observable work has already happened.
pub const FrameState = struct {
    kind: FrameStateKind,
    block: u32,
    origin: u32,
    first_value: u32,
    local_count: u32,
    stack_count: u32,
    first_handler: u32,
    handler_count: u32,
};

/// Exact state supplied by one predecessor edge. Unlike a block-entry state,
/// these values remain unambiguous at loop headers and other SSA merges.
pub const EdgeState = struct {
    from: u32,
    to: u32,
    origin: u32,
    first_value: u32,
    local_count: u32,
    stack_count: u32,
    first_handler: u32,
    handler_count: u32,
};

pub const ValueGraph = struct {
    allocator: std.mem.Allocator,
    nodes: []ValueNode,
    edges: []Edge,
    edge_arguments: []ValueId,
    returns: []ReturnValue,
    branches: []BranchValue,
    frame_states: []FrameState,
    frame_state_values: []ValueId,
    handler_states: []HandlerState,
    edge_states: []EdgeState,
    exceptional_targets: []ExceptionalTarget,

    pub fn deinit(self: *ValueGraph) void {
        self.allocator.free(self.nodes);
        self.allocator.free(self.edges);
        self.allocator.free(self.edge_arguments);
        self.allocator.free(self.returns);
        self.allocator.free(self.branches);
        self.allocator.free(self.frame_states);
        self.allocator.free(self.frame_state_values);
        self.allocator.free(self.handler_states);
        self.allocator.free(self.edge_states);
        self.allocator.free(self.exceptional_targets);
        self.* = undefined;
    }
};

pub const Block = struct {
    id: u32,
    start: u32,
    end: u32,
    first_instruction: u32,
    instruction_count: u32,
    successors: [2]u32 = .{ none, none },
    successor_count: u8 = 0,

    pub const none = std.math.maxInt(u32);
};

pub const Plan = struct {
    allocator: std.mem.Allocator,
    blocks: []Block,
    instructions: []Instruction,
    graph: ValueGraph,

    pub fn deinit(self: *Plan) void {
        self.allocator.free(self.blocks);
        self.allocator.free(self.instructions);
        self.graph.deinit();
        self.* = undefined;
    }

    /// Stable text used by focused tests and future differential tooling.
    pub fn dump(self: *const Plan, allocator: std.mem.Allocator) std.mem.Allocator.Error![]u8 {
        var out: std.ArrayListUnmanaged(u8) = .empty;
        errdefer out.deinit(allocator);
        for (self.blocks) |block| {
            try out.print(allocator, "block {d} [{d},{d})", .{ block.id, block.start, block.end });
            if (block.successor_count == 0) {
                try out.appendSlice(allocator, " -> -\n");
            } else {
                try out.appendSlice(allocator, " -> ");
                for (0..block.successor_count) |index| {
                    if (index != 0) try out.append(allocator, ',');
                    try out.print(allocator, "{d}", .{block.successors[index]});
                }
                try out.append(allocator, '\n');
            }
            const first: usize = block.first_instruction;
            const end = first + block.instruction_count;
            for (self.instructions[first..end]) |inst| {
                try out.print(allocator, "  %{d} @{d} {s} {d} {d}\n", .{
                    inst.id,
                    inst.origin,
                    @tagName(inst.op),
                    inst.a,
                    inst.b,
                });
            }
        }
        for (self.graph.nodes) |node| {
            try out.print(allocator, "value %{d} b{d} @{d} {s}", .{ node.id, node.block, node.origin, @tagName(node.kind) });
            if (node.lhs != ValueNode.none) try out.print(allocator, " %{d}", .{node.lhs});
            if (node.rhs != ValueNode.none) try out.print(allocator, " %{d}", .{node.rhs});
            if (node.third != ValueNode.none) try out.print(allocator, " %{d}", .{node.third});
            switch (node.kind) {
                .argument, .block_argument, .constant => try out.print(allocator, " 0x{x}", .{node.immediate}),
                else => {},
            }
            if (node.may_have_effect) try out.appendSlice(allocator, " effect");
            try out.append(allocator, '\n');
        }
        for (self.graph.edges) |edge| {
            if (edge.from == Block.none) {
                try out.print(allocator, "edge entry -> b{d} (", .{edge.to});
            } else {
                try out.print(allocator, "edge {s} b{d} -> b{d} (", .{ @tagName(edge.kind), edge.from, edge.to });
            }
            const first: usize = edge.first_argument;
            for (self.graph.edge_arguments[first .. first + edge.argument_count], 0..) |argument, index| {
                if (index != 0) try out.append(allocator, ',');
                try out.print(allocator, "%{d}", .{argument});
            }
            try out.appendSlice(allocator, ")\n");
        }
        for (self.graph.returns) |ret| try out.print(allocator, "return b{d} @{d} %{d}\n", .{ ret.block, ret.origin, ret.value });
        for (self.graph.branches) |branch| try out.print(allocator, "branch b{d} @{d} %{d} -> b{d},b{d}\n", .{
            branch.block,
            branch.origin,
            branch.condition,
            branch.false_block,
            branch.true_block,
        });
        for (self.graph.frame_states) |state| {
            try out.print(allocator, "state {s} b{d} @{d} locals={d} stack={d} handlers={d} (", .{
                @tagName(state.kind),
                state.block,
                state.origin,
                state.local_count,
                state.stack_count,
                state.handler_count,
            });
            const first: usize = state.first_value;
            const count: usize = state.local_count + state.stack_count;
            for (self.graph.frame_state_values[first .. first + count], 0..) |value, index| {
                if (index != 0) try out.append(allocator, ',');
                try out.print(allocator, "%{d}", .{value});
            }
            try out.appendSlice(allocator, ")\n");
        }
        for (self.graph.edge_states) |state| {
            if (state.from == Block.none) {
                try out.print(allocator, "state edge entry -> b{d} @{d} handlers={d} (", .{ state.to, state.origin, state.handler_count });
            } else {
                try out.print(allocator, "state edge b{d} -> b{d} @{d} handlers={d} (", .{ state.from, state.to, state.origin, state.handler_count });
            }
            const first: usize = state.first_value;
            const count: usize = state.local_count + state.stack_count;
            for (self.graph.edge_arguments[first .. first + count], 0..) |value, index| {
                if (index != 0) try out.append(allocator, ',');
                try out.print(allocator, "%{d}", .{value});
            }
            try out.appendSlice(allocator, ")\n");
        }
        for (self.graph.exceptional_targets) |target| try out.print(
            allocator,
            "exception {s} b{d} @{d} -> b{d} unwind={d} stack={d} handlers={d}\n",
            .{
                @tagName(target.kind),
                target.block,
                target.origin,
                target.target,
                target.unwind_stack_depth,
                target.target_stack_depth,
                target.handler_count,
            },
        );
        return out.toOwnedSlice(allocator);
    }
};

pub fn build(chunk: *const bc.Chunk, allocator: std.mem.Allocator) BuildError!Plan {
    const code = chunk.code.items;
    if (code.len == 0) return error.EmptyChunk;
    if (code.len > std.math.maxInt(u32)) return error.UnsupportedChunk;

    const starts = try allocator.alloc(bool, code.len);
    defer allocator.free(starts);
    @memset(starts, false);
    starts[0] = true;
    for (code, 0..) |inst, ip| switch (inst.op) {
        .jump, .jump_if_false => {
            if (inst.a >= code.len) return error.InvalidControlFlow;
            starts[inst.a] = true;
            if (ip + 1 < code.len) starts[ip + 1] = true;
        },
        .abrupt_break, .abrupt_continue => {
            if (inst.a >= code.len) return error.InvalidControlFlow;
            starts[inst.a] = true;
            if (ip + 1 < code.len) starts[ip + 1] = true;
        },
        .ret, .ret_undef => if (ip + 1 < code.len) {
            starts[ip + 1] = true;
        },
        .push_handler => {
            if (inst.a != std.math.maxInt(u32)) {
                if (inst.a >= code.len) return error.InvalidControlFlow;
                starts[inst.a] = true;
            }
            if (inst.b != std.math.maxInt(u32)) {
                if (inst.b >= code.len) return error.InvalidControlFlow;
                starts[inst.b] = true;
            }
        },
        else => if (terminalFrameStateKind(inst.op) != null and ip + 1 < code.len) {
            starts[ip + 1] = true;
        },
    };

    var blocks_list: std.ArrayListUnmanaged(Block) = .empty;
    errdefer blocks_list.deinit(allocator);
    var start: usize = 0;
    while (start < code.len) {
        if (!starts[start]) return error.InvalidControlFlow;
        var end = start + 1;
        while (end < code.len and !starts[end]) : (end += 1) {}
        try blocks_list.append(allocator, .{
            .id = @intCast(blocks_list.items.len),
            .start = @intCast(start),
            .end = @intCast(end),
            .first_instruction = @intCast(start),
            .instruction_count = @intCast(end - start),
        });
        start = end;
    }

    const block_at = try allocator.alloc(u32, code.len);
    defer allocator.free(block_at);
    for (blocks_list.items) |block| {
        for (block.start..block.end) |ip| block_at[ip] = block.id;
    }

    for (blocks_list.items, 0..) |*block, index| {
        const last = code[block.end - 1];
        switch (last.op) {
            .jump => addSuccessor(block, block_at[last.a]),
            .jump_if_false => {
                addSuccessor(block, block_at[last.a]);
                if (index + 1 < blocks_list.items.len) addSuccessor(block, @intCast(index + 1));
            },
            .ret, .ret_undef => {},
            else => if (terminalFrameStateKind(last.op) == null and index + 1 < blocks_list.items.len)
                addSuccessor(block, @intCast(index + 1)),
        }
    }

    const instructions = try allocator.alloc(Instruction, code.len);
    errdefer allocator.free(instructions);
    for (code, 0..) |inst, id| instructions[id] = .{
        .id = @intCast(id),
        .origin = @intCast(id),
        .op = inst.op,
        .a = inst.a,
        .b = inst.b,
    };

    const blocks = try blocks_list.toOwnedSlice(allocator);
    errdefer allocator.free(blocks);
    var graph = try buildValueGraph(chunk, blocks, allocator);
    errdefer graph.deinit();
    return .{
        .allocator = allocator,
        .blocks = blocks,
        .instructions = instructions,
        .graph = graph,
    };
}

const DepthEffect = struct {
    required: u32,
    removed: u32,
    added: u32,
};

fn depthEffect(inst: bc.Inst) DepthEffect {
    return switch (inst.op) {
        .load_const,
        .load_bigint,
        .load_undefined,
        .load_null,
        .load_true,
        .load_false,
        .load_var,
        .load_var_or_undef,
        .load_local,
        .load_upval,
        .load_this,
        .load_new_target,
        .new_object,
        .new_array,
        .super_get,
        .make_regex,
        .make_closure,
        .template_object,
        => .{ .required = 0, .removed = 0, .added = 1 },
        .pop, .jump_if_false, .ret, .throw_op, .abrupt_return => .{ .required = 1, .removed = 1, .added = 0 },
        .end_finally => .{ .required = 2, .removed = 2, .added = 0 },
        .store_var, .store_local, .store_upval, .name_anon, .assert_iter_result, .array_append_hole => .{ .required = 1, .removed = 0, .added = 0 },
        .dup => .{ .required = 1, .removed = 0, .added = 1 },
        .swap => .{ .required = 2, .removed = 0, .added = 0 },
        .def_var, .def_lex, .bind_pattern, .enter_with, .register_disposable, .iter_close => .{ .required = 1, .removed = 1, .added = 0 },
        .add, .sub, .mul, .div, .mod, .lt, .le, .gt, .ge, .eq, .neq, .eq_strict, .neq_strict => .{ .required = 2, .removed = 2, .added = 1 },
        .jump, .ret_undef, .push_handler, .pop_handler, .abrupt_break, .abrupt_continue, .enter_block, .exit_block, .exit_with => .{ .required = 0, .removed = 0, .added = 0 },
        .push_completion => .{ .required = 0, .removed = 0, .added = 2 },
        .call, .call_eval, .new_call, .tail_call, .tail_call_eval => .{ .required = inst.a +| 1, .removed = inst.a +| 1, .added = 1 },
        .call_method, .tail_call_method => .{ .required = inst.b +| 1, .removed = inst.b +| 1, .added = 1 },
        .call_with_this, .tail_call_with_this => .{ .required = inst.a +| 2, .removed = inst.a +| 2, .added = 1 },
        .call_spread, .call_eval_spread, .new_spread => .{ .required = 2, .removed = 2, .added = 1 },
        .call_with_this_spread => .{ .required = 3, .removed = 3, .added = 1 },
        .get_prop, .super_get_index, .iter_of, .async_iter_of, .enum_keys => .{ .required = 1, .removed = 1, .added = 1 },
        .get_index, .set_prop, .instance_of, .import_call => .{ .required = 2, .removed = 2, .added = 1 },
        .set_index => .{ .required = 3, .removed = 3, .added = 1 },
        .private_in => .{ .required = 1, .removed = 1, .added = 1 },
        .neg, .pos, .not, .typeof_op, .bit_not, .void_op, .to_string, .to_numeric, .inc, .dec, .to_property_key => .{ .required = 1, .removed = 1, .added = 1 },
        .pow, .in_op, .bit_and, .bit_or, .bit_xor, .shl, .shr, .ushr => .{ .required = 2, .removed = 2, .added = 1 },
        .init_prop, .init_proto, .init_spread, .array_append, .array_spread => .{ .required = 2, .removed = 1, .added = 0 },
        .init_prop_computed, .init_getter, .init_setter => .{ .required = 3, .removed = 2, .added = 0 },
        .iter_close_completion => .{ .required = 3, .removed = 1, .added = 0 },
        .async_iter_close => .{ .required = 1, .removed = 1, .added = 2 },
        .async_iter_close_completion => .{ .required = 3, .removed = 1, .added = 2 },
        .eval_class => .{ .required = inst.b, .removed = inst.b, .added = 1 },
        .dispose_scope => if (inst.a == 1)
            .{ .required = 0, .removed = 0, .added = 1 }
        else
            .{ .required = 0, .removed = 0, .added = 0 },
        else => unreachable,
    };
}

pub fn nativeOperationInputCount(inst: bc.Inst) ?u32 {
    switch (inst.op) {
        .to_numeric,
        .neg,
        .pos,
        .not,
        .typeof_op,
        .inc,
        .dec,
        .bit_not,
        .to_string,
        .to_property_key,
        .get_prop,
        .get_index,
        .set_prop,
        .set_index,
        .add,
        .sub,
        .mul,
        .div,
        .mod,
        .lt,
        .le,
        .gt,
        .ge,
        .eq,
        .neq,
        .eq_strict,
        .neq_strict,
        .pow,
        .bit_and,
        .bit_or,
        .bit_xor,
        .shl,
        .shr,
        .ushr,
        .in_op,
        .instance_of,
        .private_in,
        .call,
        .call_eval,
        .call_method,
        .call_spread,
        .call_eval_spread,
        .call_with_this_spread,
        .call_with_this,
        .new_call,
        .new_spread,
        .new_object,
        .new_array,
        .init_prop,
        .init_proto,
        .init_prop_computed,
        .init_spread,
        .init_getter,
        .init_setter,
        .array_append,
        .array_spread,
        .array_append_hole,
        => return depthEffect(inst).required,
        else => {},
    }
    const kind = terminalFrameStateKind(inst.op) orelse return null;
    if (kind != .call and kind != .effect) return null;
    return depthEffect(inst).required;
}

const GraphBuilder = struct {
    allocator: std.mem.Allocator,
    nodes: std.ArrayListUnmanaged(ValueNode) = .empty,
    edges: std.ArrayListUnmanaged(Edge) = .empty,
    edge_arguments: std.ArrayListUnmanaged(ValueId) = .empty,
    roots: std.ArrayListUnmanaged(ValueId) = .empty,
    returns: std.ArrayListUnmanaged(ReturnValue) = .empty,
    branches: std.ArrayListUnmanaged(BranchValue) = .empty,
    frame_states: std.ArrayListUnmanaged(FrameState) = .empty,
    frame_state_values: std.ArrayListUnmanaged(ValueId) = .empty,
    handler_states: std.ArrayListUnmanaged(HandlerState) = .empty,
    exceptional_targets: std.ArrayListUnmanaged(ExceptionalTarget) = .empty,

    fn deinit(self: *GraphBuilder) void {
        self.nodes.deinit(self.allocator);
        self.edges.deinit(self.allocator);
        self.edge_arguments.deinit(self.allocator);
        self.roots.deinit(self.allocator);
        self.returns.deinit(self.allocator);
        self.branches.deinit(self.allocator);
        self.frame_states.deinit(self.allocator);
        self.frame_state_values.deinit(self.allocator);
        self.handler_states.deinit(self.allocator);
        self.exceptional_targets.deinit(self.allocator);
    }

    fn appendNode(self: *GraphBuilder, node: ValueNode) std.mem.Allocator.Error!ValueId {
        var value = node;
        value.id = @intCast(self.nodes.items.len);
        try self.nodes.append(self.allocator, value);
        return value.id;
    }

    fn internLeaf(self: *GraphBuilder, block: u32, origin: u32, kind: ValueKind, immediate: u64) std.mem.Allocator.Error!ValueId {
        for (self.nodes.items) |node| {
            if (node.kind == kind and node.immediate == immediate and node.lhs == ValueNode.none and node.rhs == ValueNode.none)
                return node.id;
        }
        return self.appendNode(.{
            .id = undefined,
            .block = block,
            .origin = origin,
            .kind = kind,
            .immediate = immediate,
        });
    }

    fn appendBinary(
        self: *GraphBuilder,
        block: u32,
        origin: u32,
        kind: ValueKind,
        lhs: ValueId,
        rhs: ValueId,
        force_effect: bool,
    ) std.mem.Allocator.Error!ValueId {
        const may_have_effect = force_effect or !knownSafePrimitive(self.nodes.items[lhs]) or
            !knownSafePrimitive(self.nodes.items[rhs]);
        if (!may_have_effect) {
            for (self.nodes.items) |node| {
                if (node.block == block and node.kind == kind and node.lhs == lhs and node.rhs == rhs and !node.may_have_effect)
                    return node.id;
            }
        }
        const id = try self.appendNode(.{
            .id = undefined,
            .block = block,
            .origin = origin,
            .kind = kind,
            .lhs = lhs,
            .rhs = rhs,
            .may_have_effect = may_have_effect,
        });
        if (may_have_effect) try self.roots.append(self.allocator, id);
        return id;
    }

    fn appendFrameState(
        self: *GraphBuilder,
        kind: FrameStateKind,
        block: u32,
        origin: u32,
        locals: []const ValueId,
        stack: []const ValueId,
        handlers: []const HandlerState,
    ) std.mem.Allocator.Error!void {
        const first_value: u32 = @intCast(self.frame_state_values.items.len);
        const first_handler: u32 = @intCast(self.handler_states.items.len);
        try self.frame_state_values.appendSlice(self.allocator, locals);
        try self.frame_state_values.appendSlice(self.allocator, stack);
        try self.handler_states.appendSlice(self.allocator, handlers);
        try self.roots.appendSlice(self.allocator, locals);
        try self.roots.appendSlice(self.allocator, stack);
        try self.frame_states.append(self.allocator, .{
            .kind = kind,
            .block = block,
            .origin = origin,
            .first_value = first_value,
            .local_count = @intCast(locals.len),
            .stack_count = @intCast(stack.len),
            .first_handler = first_handler,
            .handler_count = @intCast(handlers.len),
        });
    }

    fn appendExceptionalTarget(
        self: *GraphBuilder,
        blocks: []const Block,
        block: u32,
        origin: u32,
        handlers: []const HandlerState,
    ) BuildError!void {
        if (handlers.len == 0) return;
        const handler = handlers[handlers.len - 1];
        const catches = handler.catch_ip != std.math.maxInt(u32);
        const target_ip = if (catches) handler.catch_ip else handler.finally_ip;
        if (target_ip == std.math.maxInt(u32)) return error.InvalidControlFlow;
        const target = blockAtIp(blocks, target_ip) orelse return error.InvalidControlFlow;
        const first_handler: u32 = @intCast(self.handler_states.items.len);
        try self.handler_states.appendSlice(self.allocator, handlers[0 .. handlers.len - 1]);
        const target_stack_depth = std.math.add(u32, handler.stack_depth, if (catches) 1 else 2) catch
            return error.InvalidControlFlow;
        try self.exceptional_targets.append(self.allocator, .{
            .block = block,
            .origin = origin,
            .target = target,
            .kind = if (catches) .catch_ else .finally_,
            .unwind_stack_depth = handler.stack_depth,
            .target_stack_depth = target_stack_depth,
            .first_handler = first_handler,
            .handler_count = @intCast(handlers.len - 1),
        });
    }
};

fn knownSafePrimitive(node: ValueNode) bool {
    return switch (node.kind) {
        .argument, .block_argument => false,
        .constant, .undefined, .null, .true, .false => true,
        else => !node.may_have_effect,
    };
}

fn valueKindForBinary(op: bc.Op) ValueKind {
    return switch (op) {
        .add => .add,
        .sub => .sub,
        .mul => .mul,
        .div => .div,
        .mod => .mod,
        .lt => .lt,
        .le => .le,
        .gt => .gt,
        .ge => .ge,
        .eq => .eq,
        .neq => .neq,
        .eq_strict => .eq_strict,
        .neq_strict => .neq_strict,
        else => unreachable,
    };
}

fn handlerStatesEqual(lhs: []const HandlerState, rhs: []const HandlerState) bool {
    if (lhs.len != rhs.len) return false;
    for (lhs, rhs) |a, b| {
        if (a.catch_ip != b.catch_ip or a.finally_ip != b.finally_ip or a.stack_depth != b.stack_depth)
            return false;
    }
    return true;
}

fn blockAtIp(blocks: []const Block, ip: u32) ?u32 {
    for (blocks) |block| if (block.start == ip) return block.id;
    return null;
}

fn propagateEntryState(
    allocator: std.mem.Allocator,
    entry_depths: []?u32,
    entry_handlers: []?[]HandlerState,
    queue: *std.ArrayListUnmanaged(u32),
    target: u32,
    depth: u32,
    handlers: []const HandlerState,
) BuildError!void {
    if (target >= entry_depths.len) return error.InvalidControlFlow;
    if (entry_depths[target]) |known_depth| {
        if (known_depth != depth) return error.InvalidControlFlow;
        const known_handlers = entry_handlers[target] orelse return error.InvalidControlFlow;
        if (!handlerStatesEqual(known_handlers, handlers)) return error.InvalidControlFlow;
        return;
    }
    entry_depths[target] = depth;
    entry_handlers[target] = try allocator.dupe(HandlerState, handlers);
    try queue.append(allocator, target);
}

fn buildValueGraph(chunk: *const bc.Chunk, blocks: []const Block, allocator: std.mem.Allocator) BuildError!ValueGraph {
    const local_count: usize = chunk.local_count;
    if (chunk.param_count > chunk.local_count) return error.UnsupportedChunk;

    const entry_depths = try allocator.alloc(?u32, blocks.len);
    defer allocator.free(entry_depths);
    @memset(entry_depths, null);
    const entry_handlers = try allocator.alloc(?[]HandlerState, blocks.len);
    @memset(entry_handlers, null);
    defer {
        for (entry_handlers) |maybe_handlers| if (maybe_handlers) |handlers| allocator.free(handlers);
        allocator.free(entry_handlers);
    }
    entry_depths[0] = 0;
    entry_handlers[0] = try allocator.alloc(HandlerState, 0);
    var queue: std.ArrayListUnmanaged(u32) = .empty;
    defer queue.deinit(allocator);
    try queue.append(allocator, 0);
    var queue_index: usize = 0;
    var active_handlers: std.ArrayListUnmanaged(HandlerState) = .empty;
    defer active_handlers.deinit(allocator);
    while (queue_index < queue.items.len) : (queue_index += 1) {
        const block_id = queue.items[queue_index];
        const block = blocks[block_id];
        active_handlers.clearRetainingCapacity();
        try active_handlers.appendSlice(allocator, entry_handlers[block_id].?);
        var depth = entry_depths[block_id] orelse return error.InvalidControlFlow;
        for (chunk.code.items[block.start..block.end]) |inst| {
            if (!supports(inst.op)) return error.UnsupportedChunk;
            switch (inst.op) {
                .push_handler => {
                    if (inst.a == std.math.maxInt(u32) and inst.b == std.math.maxInt(u32))
                        return error.InvalidControlFlow;
                    try active_handlers.append(allocator, .{
                        .catch_ip = inst.a,
                        .finally_ip = inst.b,
                        .stack_depth = depth,
                    });
                },
                .pop_handler => if (active_handlers.pop() == null) return error.InvalidControlFlow,
                .throw_op => if (active_handlers.items.len != 0) {
                    if (depth == 0) return error.InvalidControlFlow;
                    const handler = active_handlers.items[active_handlers.items.len - 1];
                    if (handler.stack_depth > depth - 1) return error.InvalidControlFlow;
                    const catches = handler.catch_ip != std.math.maxInt(u32);
                    const target_ip = if (catches) handler.catch_ip else handler.finally_ip;
                    if (target_ip == std.math.maxInt(u32)) return error.InvalidControlFlow;
                    const target = blockAtIp(blocks, target_ip) orelse return error.InvalidControlFlow;
                    const target_depth = std.math.add(u32, handler.stack_depth, if (catches) 1 else 2) catch
                        return error.InvalidControlFlow;
                    try propagateEntryState(
                        allocator,
                        entry_depths,
                        entry_handlers,
                        &queue,
                        target,
                        target_depth,
                        active_handlers.items[0 .. active_handlers.items.len - 1],
                    );
                },
                else => {},
            }
            const effect = depthEffect(inst);
            if (depth < effect.required) return error.InvalidControlFlow;
            depth = depth - effect.removed + effect.added;
        }
        for (block.successors[0..block.successor_count]) |successor| {
            try propagateEntryState(allocator, entry_depths, entry_handlers, &queue, successor, depth, active_handlers.items);
        }
    }

    const entry_starts = try allocator.alloc(usize, blocks.len);
    defer allocator.free(entry_starts);
    const entry_counts = try allocator.alloc(usize, blocks.len);
    defer allocator.free(entry_counts);
    var total_entries: usize = 0;
    for (entry_depths, 0..) |maybe_depth, block_id| {
        entry_starts[block_id] = total_entries;
        entry_counts[block_id] = if (maybe_depth) |depth| local_count + depth else 0;
        total_entries = std.math.add(usize, total_entries, entry_counts[block_id]) catch return error.UnsupportedChunk;
    }
    const entry_values = try allocator.alloc(ValueId, total_entries);
    defer allocator.free(entry_values);

    var builder = GraphBuilder{ .allocator = allocator };
    defer builder.deinit();
    for (blocks, 0..) |block, block_id| {
        const depth = entry_depths[block_id] orelse continue;
        const entry = entry_values[entry_starts[block_id] .. entry_starts[block_id] + entry_counts[block_id]];
        for (0..local_count) |slot| {
            entry[slot] = try builder.appendNode(.{
                .id = undefined,
                .block = @intCast(block_id),
                .origin = block.start,
                .kind = .block_argument,
                .immediate = slot,
            });
        }
        for (0..depth) |stack_slot| {
            entry[local_count + stack_slot] = try builder.appendNode(.{
                .id = undefined,
                .block = @intCast(block_id),
                .origin = block.start,
                .kind = .block_argument,
                .immediate = local_count + stack_slot,
            });
        }
        if (block_id == 0) {
            const first_argument: u32 = @intCast(builder.edge_arguments.items.len);
            for (0..local_count) |slot| {
                const source = if (slot < chunk.param_count)
                    try builder.appendNode(.{
                        .id = undefined,
                        .block = Block.none,
                        .origin = block.start,
                        .kind = .argument,
                        .immediate = slot,
                    })
                else
                    try builder.internLeaf(Block.none, block.start, .undefined, 0);
                try builder.edge_arguments.append(allocator, source);
            }
            try builder.edges.append(allocator, .{
                .from = Block.none,
                .to = 0,
                .first_argument = first_argument,
                .argument_count = @intCast(local_count),
            });
        }
    }

    const locals = try allocator.alloc(ValueId, local_count);
    defer allocator.free(locals);
    const stack = try allocator.alloc(ValueId, chunk.code.items.len + 1);
    defer allocator.free(stack);
    var handlers: std.ArrayListUnmanaged(HandlerState) = .empty;
    defer handlers.deinit(allocator);

    for (blocks, 0..) |block, block_id| {
        const entry_depth = entry_depths[block_id] orelse continue;
        const entry = entry_values[entry_starts[block_id] .. entry_starts[block_id] + entry_counts[block_id]];
        @memcpy(locals, entry[0..local_count]);
        @memcpy(stack[0..entry_depth], entry[local_count..]);
        var depth: usize = entry_depth;
        handlers.clearRetainingCapacity();
        try handlers.appendSlice(allocator, entry_handlers[block_id].?);
        try builder.appendFrameState(.block_entry, @intCast(block_id), block.start, locals, stack[0..depth], handlers.items);

        for (chunk.code.items[block.start..block.end], block.start..) |inst, origin| switch (inst.op) {
            .load_const => {
                if (inst.a >= chunk.consts.items.len) return error.InvalidControlFlow;
                const constant: RuntimeValue = chunk.consts.items[inst.a];
                if (constant.isObject() or constant.isString()) return error.UnsupportedChunk;
                stack[depth] = try builder.internLeaf(0, @intCast(origin), .constant, constant.rawBits());
                depth += 1;
            },
            .load_undefined => {
                stack[depth] = try builder.internLeaf(0, @intCast(origin), .undefined, 0);
                depth += 1;
            },
            .load_null => {
                stack[depth] = try builder.internLeaf(0, @intCast(origin), .null, 0);
                depth += 1;
            },
            .load_true => {
                stack[depth] = try builder.internLeaf(0, @intCast(origin), .true, 1);
                depth += 1;
            },
            .load_false => {
                stack[depth] = try builder.internLeaf(0, @intCast(origin), .false, 0);
                depth += 1;
            },
            .load_local => {
                if (inst.a >= local_count) return error.InvalidControlFlow;
                stack[depth] = locals[inst.a];
                depth += 1;
            },
            .store_local => {
                if (inst.a >= local_count or depth == 0) return error.InvalidControlFlow;
                locals[inst.a] = stack[depth - 1];
            },
            .pop => {
                if (depth == 0) return error.InvalidControlFlow;
                depth -= 1;
            },
            .dup => {
                if (depth == 0) return error.InvalidControlFlow;
                stack[depth] = stack[depth - 1];
                depth += 1;
            },
            .swap => {
                if (depth < 2) return error.InvalidControlFlow;
                std.mem.swap(ValueId, &stack[depth - 1], &stack[depth - 2]);
            },
            .add, .sub, .mul, .div, .mod, .lt, .le, .gt, .ge, .eq, .neq, .eq_strict, .neq_strict => {
                if (depth < 2) return error.InvalidControlFlow;
                const runtime_operation = chunk.optimizerBinaryRequiresRuntime(origin);
                if (runtime_operation) {
                    try builder.appendFrameState(.effect, @intCast(block_id), @intCast(origin), locals, stack[0..depth], handlers.items);
                    try builder.appendExceptionalTarget(blocks, @intCast(block_id), @intCast(origin), handlers.items);
                }
                const rhs = stack[depth - 1];
                const lhs = stack[depth - 2];
                depth -= 1;
                stack[depth - 1] = try builder.appendBinary(
                    @intCast(block_id),
                    @intCast(origin),
                    valueKindForBinary(inst.op),
                    lhs,
                    rhs,
                    runtime_operation,
                );
            },
            .to_numeric, .neg, .pos, .not, .typeof_op, .inc, .dec, .bit_not, .to_string, .to_property_key => {
                if (depth == 0) return error.InvalidControlFlow;
                try builder.appendFrameState(.effect, @intCast(block_id), @intCast(origin), locals, stack[0..depth], handlers.items);
                try builder.appendExceptionalTarget(blocks, @intCast(block_id), @intCast(origin), handlers.items);
                const input = stack[depth - 1];
                const result = try builder.appendNode(.{
                    .id = undefined,
                    .block = @intCast(block_id),
                    .origin = @intCast(origin),
                    .kind = switch (inst.op) {
                        .to_numeric => .to_numeric,
                        .neg => .neg,
                        .pos => .pos,
                        .not => .not,
                        .typeof_op => .typeof_op,
                        .inc => .inc,
                        .dec => .dec,
                        .bit_not => .bit_not,
                        .to_string => .to_string,
                        .to_property_key => .to_property_key,
                        else => unreachable,
                    },
                    .lhs = input,
                    .may_have_effect = true,
                });
                try builder.roots.append(allocator, result);
                stack[depth - 1] = result;
            },
            .void_op => {
                if (depth == 0) return error.InvalidControlFlow;
                stack[depth - 1] = try builder.internLeaf(0, @intCast(origin), .undefined, 0);
            },
            .get_prop => {
                if (depth == 0 or inst.a >= chunk.names.items.len) return error.InvalidControlFlow;
                try builder.appendFrameState(.effect, @intCast(block_id), @intCast(origin), locals, stack[0..depth], handlers.items);
                try builder.appendExceptionalTarget(blocks, @intCast(block_id), @intCast(origin), handlers.items);
                const input = stack[depth - 1];
                const result = try builder.appendNode(.{
                    .id = undefined,
                    .block = @intCast(block_id),
                    .origin = @intCast(origin),
                    .kind = .get_prop,
                    .lhs = input,
                    .immediate = inst.a,
                    .may_have_effect = true,
                });
                try builder.roots.append(allocator, result);
                stack[depth - 1] = result;
            },
            .get_index => {
                if (depth < 2) return error.InvalidControlFlow;
                try builder.appendFrameState(.effect, @intCast(block_id), @intCast(origin), locals, stack[0..depth], handlers.items);
                try builder.appendExceptionalTarget(blocks, @intCast(block_id), @intCast(origin), handlers.items);
                const object = stack[depth - 2];
                const key = stack[depth - 1];
                depth -= 1;
                const result = try builder.appendNode(.{
                    .id = undefined,
                    .block = @intCast(block_id),
                    .origin = @intCast(origin),
                    .kind = .get_index,
                    .lhs = object,
                    .rhs = key,
                    .may_have_effect = true,
                });
                try builder.roots.append(allocator, result);
                stack[depth - 1] = result;
            },
            .set_prop => {
                if (depth < 2 or inst.a >= chunk.names.items.len) return error.InvalidControlFlow;
                try builder.appendFrameState(.effect, @intCast(block_id), @intCast(origin), locals, stack[0..depth], handlers.items);
                try builder.appendExceptionalTarget(blocks, @intCast(block_id), @intCast(origin), handlers.items);
                const object = stack[depth - 2];
                const value_word = stack[depth - 1];
                depth -= 1;
                const result = try builder.appendNode(.{
                    .id = undefined,
                    .block = @intCast(block_id),
                    .origin = @intCast(origin),
                    .kind = .set_prop,
                    .lhs = object,
                    .rhs = value_word,
                    .immediate = inst.a,
                    .may_have_effect = true,
                });
                try builder.roots.append(allocator, result);
                stack[depth - 1] = result;
            },
            .set_index => {
                if (depth < 3) return error.InvalidControlFlow;
                try builder.appendFrameState(.effect, @intCast(block_id), @intCast(origin), locals, stack[0..depth], handlers.items);
                try builder.appendExceptionalTarget(blocks, @intCast(block_id), @intCast(origin), handlers.items);
                const object = stack[depth - 3];
                const key = stack[depth - 2];
                const value_word = stack[depth - 1];
                depth -= 2;
                const result = try builder.appendNode(.{
                    .id = undefined,
                    .block = @intCast(block_id),
                    .origin = @intCast(origin),
                    .kind = .set_index,
                    .lhs = object,
                    .rhs = key,
                    .third = value_word,
                    .may_have_effect = true,
                });
                try builder.roots.append(allocator, result);
                stack[depth - 1] = result;
            },
            .pow, .bit_and, .bit_or, .bit_xor, .shl, .shr, .ushr, .in_op, .instance_of => {
                if (depth < 2) return error.InvalidControlFlow;
                try builder.appendFrameState(.effect, @intCast(block_id), @intCast(origin), locals, stack[0..depth], handlers.items);
                try builder.appendExceptionalTarget(blocks, @intCast(block_id), @intCast(origin), handlers.items);
                const lhs = stack[depth - 2];
                const rhs = stack[depth - 1];
                depth -= 1;
                const result = try builder.appendNode(.{
                    .id = undefined,
                    .block = @intCast(block_id),
                    .origin = @intCast(origin),
                    .kind = switch (inst.op) {
                        .pow => .pow,
                        .bit_and => .bit_and,
                        .bit_or => .bit_or,
                        .bit_xor => .bit_xor,
                        .shl => .shl,
                        .shr => .shr,
                        .ushr => .ushr,
                        .in_op => .in_op,
                        .instance_of => .instance_of,
                        else => unreachable,
                    },
                    .lhs = lhs,
                    .rhs = rhs,
                    .may_have_effect = true,
                });
                try builder.roots.append(allocator, result);
                stack[depth - 1] = result;
            },
            .private_in => {
                if (depth == 0 or inst.a >= chunk.names.items.len) return error.InvalidControlFlow;
                try builder.appendFrameState(.effect, @intCast(block_id), @intCast(origin), locals, stack[0..depth], handlers.items);
                try builder.appendExceptionalTarget(blocks, @intCast(block_id), @intCast(origin), handlers.items);
                const input = stack[depth - 1];
                const result = try builder.appendNode(.{
                    .id = undefined,
                    .block = @intCast(block_id),
                    .origin = @intCast(origin),
                    .kind = .private_in,
                    .lhs = input,
                    .immediate = inst.a,
                    .may_have_effect = true,
                });
                try builder.roots.append(allocator, result);
                stack[depth - 1] = result;
            },
            .new_object, .new_array => {
                try builder.appendFrameState(.effect, @intCast(block_id), @intCast(origin), locals, stack[0..depth], handlers.items);
                try builder.appendExceptionalTarget(blocks, @intCast(block_id), @intCast(origin), handlers.items);
                const result = try builder.appendNode(.{
                    .id = undefined,
                    .block = @intCast(block_id),
                    .origin = @intCast(origin),
                    .kind = if (inst.op == .new_object) .new_object else .new_array,
                    .may_have_effect = true,
                });
                try builder.roots.append(allocator, result);
                stack[depth] = result;
                depth += 1;
            },
            .init_prop, .init_proto, .init_prop_computed, .init_spread, .init_getter, .init_setter, .array_append, .array_spread, .array_append_hole => {
                const effect = depthEffect(inst);
                if (depth < effect.required) return error.InvalidControlFlow;
                if (inst.op == .init_prop and inst.a >= chunk.names.items.len) return error.InvalidControlFlow;
                try builder.appendFrameState(.effect, @intCast(block_id), @intCast(origin), locals, stack[0..depth], handlers.items);
                try builder.appendExceptionalTarget(blocks, @intCast(block_id), @intCast(origin), handlers.items);
                const input_count: usize = @intCast(effect.required);
                const first_input = depth - input_count;
                const result = try builder.appendNode(.{
                    .id = undefined,
                    .block = @intCast(block_id),
                    .origin = @intCast(origin),
                    .kind = switch (inst.op) {
                        .init_prop => .init_prop,
                        .init_proto => .init_proto,
                        .init_prop_computed => .init_prop_computed,
                        .init_spread => .init_spread,
                        .init_getter => .init_getter,
                        .init_setter => .init_setter,
                        .array_append => .array_append,
                        .array_spread => .array_spread,
                        .array_append_hole => .array_append_hole,
                        else => unreachable,
                    },
                    .lhs = stack[first_input],
                    .rhs = if (input_count >= 2) stack[first_input + 1] else ValueNode.none,
                    .third = if (input_count >= 3) stack[first_input + 2] else ValueNode.none,
                    .immediate = inst.a,
                    .may_have_effect = true,
                });
                try builder.roots.append(allocator, result);
                depth -= effect.removed;
                stack[depth - 1] = result;
            },
            .call, .call_eval, .call_method, .call_spread, .call_eval_spread, .call_with_this_spread, .call_with_this, .new_call, .new_spread => {
                const effect = depthEffect(inst);
                if (depth < effect.required) return error.InvalidControlFlow;
                try builder.appendFrameState(.call, @intCast(block_id), @intCast(origin), locals, stack[0..depth], handlers.items);
                try builder.appendExceptionalTarget(blocks, @intCast(block_id), @intCast(origin), handlers.items);
                depth -= effect.removed;
                const result = try builder.appendNode(.{
                    .id = undefined,
                    .block = @intCast(block_id),
                    .origin = @intCast(origin),
                    .kind = switch (inst.op) {
                        .call => .call,
                        .call_eval => .call_eval,
                        .call_method => .call_method,
                        .call_spread => .call_spread,
                        .call_eval_spread => .call_eval_spread,
                        .call_with_this_spread => .call_with_this_spread,
                        .call_with_this => .call_with_this,
                        .new_call => .construct,
                        .new_spread => .construct_spread,
                        else => unreachable,
                    },
                    .immediate = if (inst.op == .call_method) inst.b else inst.a,
                    .may_have_effect = true,
                });
                try builder.roots.append(allocator, result);
                stack[depth] = result;
                depth += effect.added;
            },
            .tail_call, .tail_call_eval, .tail_call_method, .tail_call_with_this => {
                const effect = depthEffect(inst);
                if (depth < effect.required) return error.InvalidControlFlow;
                try builder.appendFrameState(.call, @intCast(block_id), @intCast(origin), locals, stack[0..depth], handlers.items);
                try builder.appendExceptionalTarget(blocks, @intCast(block_id), @intCast(origin), handlers.items);
                depth -= effect.removed;
                const result = try builder.appendNode(.{
                    .id = undefined,
                    .block = @intCast(block_id),
                    .origin = @intCast(origin),
                    .kind = switch (inst.op) {
                        .tail_call => .call,
                        .tail_call_eval => .call_eval,
                        .tail_call_method => .call_method,
                        .tail_call_with_this => .call_with_this,
                        else => unreachable,
                    },
                    .immediate = if (inst.op == .tail_call_method) inst.b else inst.a,
                    .may_have_effect = true,
                });
                try builder.roots.append(allocator, result);
                try builder.returns.append(allocator, .{
                    .block = @intCast(block_id),
                    .origin = @intCast(origin),
                    .value = result,
                });
            },
            .jump => {},
            .jump_if_false => {
                if (depth == 0) return error.InvalidControlFlow;
                try builder.appendFrameState(.branch, @intCast(block_id), @intCast(origin), locals, stack[0..depth], handlers.items);
                depth -= 1;
                try builder.roots.append(allocator, stack[depth]);
                if (block.successor_count != 2) return error.InvalidControlFlow;
                try builder.branches.append(allocator, .{
                    .block = @intCast(block_id),
                    .origin = @intCast(origin),
                    .condition = stack[depth],
                    .false_block = block.successors[0],
                    .true_block = block.successors[1],
                });
            },
            .ret => {
                if (depth == 0) return error.InvalidControlFlow;
                try builder.appendFrameState(.return_, @intCast(block_id), @intCast(origin), locals, stack[0..depth], handlers.items);
                depth -= 1;
                try builder.roots.append(allocator, stack[depth]);
                try builder.returns.append(allocator, .{
                    .block = @intCast(block_id),
                    .origin = @intCast(origin),
                    .value = stack[depth],
                });
            },
            .ret_undef => {
                try builder.appendFrameState(.return_, @intCast(block_id), @intCast(origin), locals, stack[0..depth], handlers.items);
                const result = try builder.internLeaf(0, @intCast(origin), .undefined, 0);
                try builder.roots.append(allocator, result);
                try builder.returns.append(allocator, .{
                    .block = @intCast(block_id),
                    .origin = @intCast(origin),
                    .value = result,
                });
            },
            .throw_op => {
                if (depth == 0) return error.InvalidControlFlow;
                // Preserve the pre-instruction state for uncaught throws and
                // any policy-driven side exit. With an active handler, also
                // publish the exact exceptional SSA edge after unwinding the
                // innermost record; guarded native lowering may follow it.
                try builder.appendFrameState(.throw_, @intCast(block_id), @intCast(origin), locals, stack[0..depth], handlers.items);
                try builder.appendExceptionalTarget(blocks, @intCast(block_id), @intCast(origin), handlers.items);
                depth -= 1;
                if (handlers.items.len != 0) {
                    const handler = handlers.items[handlers.items.len - 1];
                    if (handler.stack_depth > depth) return error.InvalidControlFlow;
                    const catches = handler.catch_ip != std.math.maxInt(u32);
                    const target_ip = if (catches) handler.catch_ip else handler.finally_ip;
                    if (target_ip == std.math.maxInt(u32)) return error.InvalidControlFlow;
                    const target = blockAtIp(blocks, target_ip) orelse return error.InvalidControlFlow;
                    const first_argument: u32 = @intCast(builder.edge_arguments.items.len);
                    try builder.edge_arguments.appendSlice(allocator, locals);
                    try builder.edge_arguments.appendSlice(allocator, stack[0..handler.stack_depth]);
                    try builder.edge_arguments.append(allocator, stack[depth]);
                    if (!catches) {
                        const completion = try builder.internLeaf(
                            @intCast(block_id),
                            @intCast(origin),
                            .constant,
                            RuntimeValue.num(1).rawBits(),
                        );
                        try builder.edge_arguments.append(allocator, completion);
                    }
                    try builder.edges.append(allocator, .{
                        .from = @intCast(block_id),
                        .to = target,
                        .first_argument = first_argument,
                        .argument_count = @intCast(builder.edge_arguments.items.len - first_argument),
                        .kind = if (catches) .catch_ else .finally_,
                    });
                }
            },
            .push_completion => {
                stack[depth] = try builder.internLeaf(@intCast(block_id), @intCast(origin), .undefined, 0);
                stack[depth + 1] = try builder.internLeaf(
                    @intCast(block_id),
                    @intCast(origin),
                    .constant,
                    RuntimeValue.num(@floatFromInt(inst.a)).rawBits(),
                );
                depth += 2;
            },
            .end_finally => {
                if (depth < 2) return error.InvalidControlFlow;
                try builder.appendFrameState(
                    .finally_dispatch,
                    @intCast(block_id),
                    @intCast(origin),
                    locals,
                    stack[0..depth],
                    handlers.items,
                );
                depth -= 2;
            },
            .abrupt_return => {
                if (depth == 0) return error.InvalidControlFlow;
                // The bytecode VM owns completion propagation through finally;
                // retain its input and handler stack and resume this opcode.
                try builder.appendFrameState(.abrupt_return, @intCast(block_id), @intCast(origin), locals, stack[0..depth], handlers.items);
                depth -= 1;
            },
            .abrupt_break, .abrupt_continue => {
                // The target is encoded in the bytecode. Preserve locals and
                // active finally records before canonical completion unwinding.
                try builder.appendFrameState(.abrupt_jump, @intCast(block_id), @intCast(origin), locals, stack[0..depth], handlers.items);
            },
            .push_handler => try handlers.append(allocator, .{
                .catch_ip = inst.a,
                .finally_ip = inst.b,
                .stack_depth = @intCast(depth),
            }),
            .pop_handler => if (handlers.pop() == null) return error.InvalidControlFlow,
            else => {
                const kind = terminalFrameStateKind(inst.op) orelse unreachable;
                if (kind != .call and kind != .effect) unreachable;
                const effect = depthEffect(inst);
                const required: usize = @intCast(effect.required);
                if (depth < required) return error.InvalidControlFlow;
                // Interpreter-owned operations exit before observable work.
                // Preserve every input and active handler so calls, allocation,
                // environment access, iteration, and other effects execute once.
                try builder.appendFrameState(kind, @intCast(block_id), @intCast(origin), locals, stack[0..depth], handlers.items);
                try builder.appendExceptionalTarget(blocks, @intCast(block_id), @intCast(origin), handlers.items);
                depth = depth - @as(usize, @intCast(effect.removed)) + effect.added;
            },
        };

        for (block.successors[0..block.successor_count]) |successor| {
            const first_argument: u32 = @intCast(builder.edge_arguments.items.len);
            try builder.edge_arguments.appendSlice(allocator, locals);
            try builder.edge_arguments.appendSlice(allocator, stack[0..depth]);
            try builder.edges.append(allocator, .{
                .from = @intCast(block_id),
                .to = successor,
                .first_argument = first_argument,
                .argument_count = @intCast(local_count + depth),
            });
        }
    }

    return compactValueGraph(&builder, entry_values, entry_starts, entry_counts, allocator);
}

fn compactValueGraph(
    builder: *GraphBuilder,
    entry_values: []const ValueId,
    entry_starts: []const usize,
    entry_counts: []const usize,
    allocator: std.mem.Allocator,
) std.mem.Allocator.Error!ValueGraph {
    const live = try allocator.alloc(bool, builder.nodes.items.len);
    defer allocator.free(live);
    @memset(live, false);
    var queue: std.ArrayListUnmanaged(ValueId) = .empty;
    defer queue.deinit(allocator);
    try queue.appendSlice(allocator, builder.roots.items);
    var index: usize = 0;
    while (index < queue.items.len) : (index += 1) {
        const id = queue.items[index];
        if (live[id]) continue;
        live[id] = true;
        const node = builder.nodes.items[id];
        if (node.lhs != ValueNode.none) try queue.append(allocator, node.lhs);
        if (node.rhs != ValueNode.none) try queue.append(allocator, node.rhs);
        if (node.third != ValueNode.none) try queue.append(allocator, node.third);
        if (node.kind == .block_argument) {
            const slot: usize = @intCast(node.immediate);
            for (builder.edges.items) |edge| {
                if (edge.to != node.block or slot >= edge.argument_count) continue;
                try queue.append(allocator, builder.edge_arguments.items[edge.first_argument + slot]);
            }
        }
    }

    const remap = try allocator.alloc(ValueId, builder.nodes.items.len);
    defer allocator.free(remap);
    @memset(remap, ValueNode.none);
    var node_count: usize = 0;
    for (live, 0..) |is_live, old_id| if (is_live) {
        remap[old_id] = @intCast(node_count);
        node_count += 1;
    };
    const nodes = try allocator.alloc(ValueNode, node_count);
    errdefer allocator.free(nodes);
    var next_node: usize = 0;
    for (builder.nodes.items, 0..) |old, old_id| {
        if (!live[old_id]) continue;
        var node = old;
        node.id = remap[old_id];
        if (node.lhs != ValueNode.none) node.lhs = remap[node.lhs];
        if (node.rhs != ValueNode.none) node.rhs = remap[node.rhs];
        if (node.third != ValueNode.none) node.third = remap[node.third];
        nodes[next_node] = node;
        next_node += 1;
    }

    var edges: std.ArrayListUnmanaged(Edge) = .empty;
    errdefer edges.deinit(allocator);
    var edge_arguments: std.ArrayListUnmanaged(ValueId) = .empty;
    errdefer edge_arguments.deinit(allocator);
    for (builder.edges.items) |old_edge| {
        const first_argument: u32 = @intCast(edge_arguments.items.len);
        const target_entry = entry_values[entry_starts[old_edge.to] .. entry_starts[old_edge.to] + entry_counts[old_edge.to]];
        for (target_entry, 0..) |target_value, slot| {
            if (!live[target_value]) continue;
            const source = builder.edge_arguments.items[old_edge.first_argument + slot];
            try edge_arguments.append(allocator, remap[source]);
        }
        try edges.append(allocator, .{
            .from = old_edge.from,
            .to = old_edge.to,
            .first_argument = first_argument,
            .argument_count = @intCast(edge_arguments.items.len - first_argument),
            .kind = old_edge.kind,
        });
    }

    const owned_edges = try edges.toOwnedSlice(allocator);
    errdefer allocator.free(owned_edges);
    const owned_edge_arguments = try edge_arguments.toOwnedSlice(allocator);
    errdefer allocator.free(owned_edge_arguments);
    const returns = try allocator.alloc(ReturnValue, builder.returns.items.len);
    errdefer allocator.free(returns);
    for (builder.returns.items, returns) |old, *ret| ret.* = .{
        .block = old.block,
        .origin = old.origin,
        .value = remap[old.value],
    };
    const branches = try allocator.alloc(BranchValue, builder.branches.items.len);
    errdefer allocator.free(branches);
    for (builder.branches.items, branches) |old, *branch| branch.* = .{
        .block = old.block,
        .origin = old.origin,
        .condition = remap[old.condition],
        .false_block = old.false_block,
        .true_block = old.true_block,
    };
    const frame_states = try allocator.dupe(FrameState, builder.frame_states.items);
    errdefer allocator.free(frame_states);
    const frame_state_values = try allocator.alloc(ValueId, builder.frame_state_values.items.len);
    errdefer allocator.free(frame_state_values);
    for (builder.frame_state_values.items, frame_state_values) |old, *value| value.* = remap[old];
    const handler_states = try allocator.dupe(HandlerState, builder.handler_states.items);
    errdefer allocator.free(handler_states);
    const exceptional_targets = try allocator.dupe(ExceptionalTarget, builder.exceptional_targets.items);
    errdefer allocator.free(exceptional_targets);
    const edge_states = try allocator.alloc(EdgeState, owned_edges.len);
    errdefer allocator.free(edge_states);
    for (owned_edges, edge_states) |edge, *state| {
        var entry_state: ?FrameState = null;
        for (frame_states) |candidate| if (candidate.kind == .block_entry and candidate.block == edge.to) {
            std.debug.assert(entry_state == null);
            entry_state = candidate;
        };
        const target = entry_state.?;
        std.debug.assert(target.local_count + target.stack_count == edge.argument_count);
        state.* = .{
            .from = edge.from,
            .to = edge.to,
            .origin = target.origin,
            .first_value = edge.first_argument,
            .local_count = target.local_count,
            .stack_count = target.stack_count,
            .first_handler = target.first_handler,
            .handler_count = target.handler_count,
        };
    }
    return .{
        .allocator = allocator,
        .nodes = nodes,
        .edges = owned_edges,
        .edge_arguments = owned_edge_arguments,
        .returns = returns,
        .branches = branches,
        .frame_states = frame_states,
        .frame_state_values = frame_state_values,
        .handler_states = handler_states,
        .edge_states = edge_states,
        .exceptional_targets = exceptional_targets,
    };
}

fn addSuccessor(block: *Block, successor: u32) void {
    for (block.successors[0..block.successor_count]) |existing| if (existing == successor) return;
    std.debug.assert(block.successor_count < block.successors.len);
    block.successors[block.successor_count] = successor;
    block.successor_count += 1;
}

fn supports(op: bc.Op) bool {
    if (terminalFrameStateKind(op) != null) return true;
    return switch (op) {
        .load_const,
        .load_undefined,
        .load_null,
        .load_true,
        .load_false,
        .pop,
        .dup,
        .swap,
        .load_local,
        .store_local,
        .add,
        .sub,
        .mul,
        .div,
        .mod,
        .lt,
        .le,
        .gt,
        .ge,
        .eq,
        .neq,
        .eq_strict,
        .neq_strict,
        .jump,
        .jump_if_false,
        .ret,
        .ret_undef,
        .push_handler,
        .pop_handler,
        .push_completion,
        .to_numeric,
        .neg,
        .pos,
        .not,
        .typeof_op,
        .void_op,
        .inc,
        .dec,
        .bit_not,
        .to_string,
        .to_property_key,
        .get_prop,
        .get_index,
        .set_prop,
        .set_index,
        .pow,
        .bit_and,
        .bit_or,
        .bit_xor,
        .shl,
        .shr,
        .ushr,
        .in_op,
        .instance_of,
        .private_in,
        .call,
        .call_eval,
        .call_method,
        .call_spread,
        .call_eval_spread,
        .call_with_this_spread,
        .call_with_this,
        .new_call,
        .new_spread,
        .new_object,
        .new_array,
        .init_prop,
        .init_proto,
        .init_prop_computed,
        .init_spread,
        .init_getter,
        .init_setter,
        .array_append,
        .array_spread,
        .array_append_hole,
        => true,
        else => false,
    };
}

test "optimizer control-flow plans are deterministic" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var chunk = bc.Chunk.init(a);
    chunk.param_count = 1;
    chunk.local_count = 1;
    _ = try chunk.addConst(RuntimeValue.num(1));
    _ = try chunk.addConst(RuntimeValue.num(2));
    _ = try chunk.emit(.load_local, 0);
    _ = try chunk.emit(.load_const, 0);
    _ = try chunk.emit(.lt, 0);
    _ = try chunk.emit(.jump_if_false, 8);
    _ = try chunk.emit(.load_local, 0);
    _ = try chunk.emit(.load_const, 1);
    _ = try chunk.emit(.add, 0);
    _ = try chunk.emit(.ret, 0);
    _ = try chunk.emit(.ret_undef, 0);

    var first = try build(&chunk, std.testing.allocator);
    defer first.deinit();
    var second = try build(&chunk, std.testing.allocator);
    defer second.deinit();
    const first_dump = try first.dump(std.testing.allocator);
    defer std.testing.allocator.free(first_dump);
    const second_dump = try second.dump(std.testing.allocator);
    defer std.testing.allocator.free(second_dump);

    try std.testing.expectEqualStrings(first_dump, second_dump);
    try std.testing.expectEqual(@as(usize, 3), first.blocks.len);
    try std.testing.expectEqualSlices(u32, &.{ 2, 1 }, first.blocks[0].successors[0..2]);
    try std.testing.expect(std.mem.indexOf(u8, first_dump, "block 0 [0,4) -> 2,1") != null);
    try std.testing.expect(std.mem.indexOf(u8, first_dump, "%3 @3 jump_if_false 8 0") != null);
    try std.testing.expect(std.mem.indexOf(u8, first_dump, "block_argument") != null);
    try std.testing.expect(std.mem.indexOf(u8, first_dump, "edge entry -> b0") != null);
    try std.testing.expectEqual(@as(usize, 1), first.graph.branches.len);
    try std.testing.expect(std.mem.indexOf(u8, first_dump, "branch b0 @3") != null);
    try std.testing.expectEqual(@as(usize, 6), first.graph.frame_states.len);
    try std.testing.expectEqual(first.graph.edges.len, first.graph.edge_states.len);
    try std.testing.expect(std.mem.indexOf(u8, first_dump, "state branch b0 @3 locals=1 stack=1") != null);
    try std.testing.expect(std.mem.indexOf(u8, first_dump, "state edge entry -> b0 @0") != null);
    for (first.graph.frame_state_values) |value| try std.testing.expect(value < first.graph.nodes.len);
}

test "optimizer SSA block arguments close loop backedges" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var chunk = bc.Chunk.init(a);
    chunk.param_count = 1;
    chunk.local_count = 2;
    const zero = try chunk.addConst(RuntimeValue.num(0));
    const one = try chunk.addConst(RuntimeValue.num(1));
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

    var plan = try build(&chunk, std.testing.allocator);
    defer plan.deinit();
    const dump = try plan.dump(std.testing.allocator);
    defer std.testing.allocator.free(dump);

    try std.testing.expectEqual(@as(usize, 4), plan.blocks.len);
    try std.testing.expectEqual(@as(usize, 5), plan.graph.edges.len);
    try std.testing.expectEqual(plan.graph.edges.len, plan.graph.edge_states.len);
    try std.testing.expect(std.mem.indexOf(u8, dump, "edge b2 -> b1") != null);
    try std.testing.expect(std.mem.indexOf(u8, dump, "state edge b0 -> b1 @4") != null);
    try std.testing.expect(std.mem.indexOf(u8, dump, "state edge b2 -> b1 @4") != null);
    try std.testing.expect(std.mem.indexOf(u8, dump, "block_argument") != null);

    var preheader: ?EdgeState = null;
    var backedge: ?EdgeState = null;
    for (plan.graph.edge_states) |state| {
        if (state.from == 0 and state.to == 1) preheader = state;
        if (state.from == 2 and state.to == 1) backedge = state;
    }
    const preheader_state = preheader.?;
    const backedge_state = backedge.?;
    try std.testing.expectEqual(preheader_state.local_count, backedge_state.local_count);
    try std.testing.expectEqual(preheader_state.stack_count, backedge_state.stack_count);
    const count: usize = preheader_state.local_count + preheader_state.stack_count;
    const preheader_values = plan.graph.edge_arguments[preheader_state.first_value .. preheader_state.first_value + count];
    const backedge_values = plan.graph.edge_arguments[backedge_state.first_value .. backedge_state.first_value + count];
    try std.testing.expect(!std.mem.eql(ValueId, preheader_values, backedge_values));
    try std.testing.expect(preheader_values[1] != backedge_values[1]);
}

test "optimizer frame states preserve active normal-flow handlers" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var chunk = bc.Chunk.init(arena.allocator());
    chunk.param_count = 1;
    chunk.local_count = 1;
    const zero = try chunk.addConst(RuntimeValue.num(0));
    const eleven = try chunk.addConst(RuntimeValue.num(11));
    const dummy = try chunk.addConst(RuntimeValue.num(1));
    const twenty_two = try chunk.addConst(RuntimeValue.num(22));
    const ninety_nine = try chunk.addConst(RuntimeValue.num(99));
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

    var plan = try build(&chunk, std.testing.allocator);
    defer plan.deinit();
    var active_entries: usize = 0;
    for (plan.graph.frame_states) |state| {
        if (state.kind == .branch or (state.kind == .block_entry and state.block != 0)) {
            try std.testing.expectEqual(@as(u32, 1), state.handler_count);
            const handler = plan.graph.handler_states[state.first_handler];
            try std.testing.expectEqual(@as(u32, 13), handler.catch_ip);
            try std.testing.expectEqual(std.math.maxInt(u32), handler.finally_ip);
            try std.testing.expectEqual(@as(u32, 0), handler.stack_depth);
            active_entries += 1;
        } else {
            try std.testing.expectEqual(@as(u32, 0), state.handler_count);
        }
    }
    try std.testing.expectEqual(@as(usize, 3), active_entries);
    for (plan.graph.edge_states) |state| {
        if (state.to != 0) try std.testing.expectEqual(@as(u32, 1), state.handler_count);
    }
}

test "optimizer models throw as a resumable terminal frame" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var chunk = bc.Chunk.init(arena.allocator());
    const seven = try chunk.addConst(RuntimeValue.num(7));
    _ = try chunk.emitAB(.push_handler, std.math.maxInt(u32), 4);
    _ = try chunk.emit(.load_const, seven);
    _ = try chunk.emit(.throw_op, 0);
    _ = try chunk.emit(.ret_undef, 0);
    _ = try chunk.emit(.end_finally, 0);

    var plan = try build(&chunk, std.testing.allocator);
    defer plan.deinit();
    try std.testing.expectEqual(@as(usize, 0), plan.graph.returns.len);
    var throw_state: ?FrameState = null;
    for (plan.graph.frame_states) |state| if (state.kind == .throw_) {
        try std.testing.expect(throw_state == null);
        throw_state = state;
    };
    const state = throw_state orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u32, 2), state.origin);
    try std.testing.expectEqual(@as(u32, 1), state.stack_count);
    try std.testing.expectEqual(@as(u32, 1), state.handler_count);
    const handler = plan.graph.handler_states[state.first_handler];
    try std.testing.expectEqual(std.math.maxInt(u32), handler.catch_ip);
    try std.testing.expectEqual(@as(u32, 4), handler.finally_ip);
    try std.testing.expectEqual(@as(u32, 0), handler.stack_depth);
    try std.testing.expectEqual(@as(usize, 2), plan.graph.edges.len);
    try std.testing.expectEqual(EdgeKind.finally_, plan.graph.edges[1].kind);
    try std.testing.expectEqual(@as(u32, 2), plan.graph.edges[1].argument_count);
    const edge_state = plan.graph.edge_states[1];
    try std.testing.expectEqual(@as(u32, 2), edge_state.stack_count);
    try std.testing.expectEqual(@as(u32, 0), edge_state.handler_count);
    var dispatch_state: ?FrameState = null;
    for (plan.graph.frame_states) |candidate| if (candidate.kind == .finally_dispatch) {
        dispatch_state = candidate;
    };
    try std.testing.expectEqual(@as(u32, 4), dispatch_state.?.origin);
    try std.testing.expectEqual(@as(u32, 2), dispatch_state.?.stack_count);
}

test "optimizer publishes an exact catch edge after handler unwind" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var chunk = bc.Chunk.init(arena.allocator());
    const seven = try chunk.addConst(RuntimeValue.num(7));
    _ = try chunk.emitAB(.push_handler, 4, std.math.maxInt(u32));
    _ = try chunk.emit(.load_const, seven);
    _ = try chunk.emit(.throw_op, 0);
    _ = try chunk.emit(.ret_undef, 0);
    _ = try chunk.emit(.ret, 0);

    var plan = try build(&chunk, std.testing.allocator);
    defer plan.deinit();
    try std.testing.expectEqual(@as(usize, 2), plan.graph.edges.len);
    const edge = plan.graph.edges[1];
    try std.testing.expectEqual(EdgeKind.catch_, edge.kind);
    try std.testing.expectEqual(@as(u32, 0), edge.from);
    try std.testing.expectEqual(@as(u32, 2), edge.to);
    try std.testing.expectEqual(@as(u32, 1), edge.argument_count);
    const state = plan.graph.edge_states[1];
    try std.testing.expectEqual(@as(u32, 1), state.stack_count);
    try std.testing.expectEqual(@as(u32, 0), state.handler_count);
    try std.testing.expectEqual(@as(usize, 1), plan.graph.returns.len);
    try std.testing.expectEqual(edge.to, plan.graph.returns[0].block);
}

test "optimizer models abrupt return as a resumable terminal frame" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var chunk = bc.Chunk.init(arena.allocator());
    const seven = try chunk.addConst(RuntimeValue.num(7));
    _ = try chunk.emitAB(.push_handler, std.math.maxInt(u32), 4);
    _ = try chunk.emit(.load_const, seven);
    _ = try chunk.emit(.abrupt_return, 0);
    _ = try chunk.emit(.ret_undef, 0);
    _ = try chunk.emit(.push_completion, 0);
    _ = try chunk.emit(.end_finally, 0);

    var plan = try build(&chunk, std.testing.allocator);
    defer plan.deinit();
    var abrupt_state: ?FrameState = null;
    for (plan.graph.frame_states) |state| {
        if (state.kind == .abrupt_return) abrupt_state = state;
    }
    const state = abrupt_state orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u32, 2), state.origin);
    try std.testing.expectEqual(@as(u32, 1), state.stack_count);
    try std.testing.expectEqual(@as(u32, 1), state.handler_count);
    try std.testing.expectEqual(@as(u32, 4), plan.graph.handler_states[state.first_handler].finally_ip);
}

test "optimizer models a call as an effectful value with normal flow" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var chunk = bc.Chunk.init(arena.allocator());
    chunk.param_count = 2;
    chunk.local_count = 2;
    _ = try chunk.emit(.load_local, 0);
    _ = try chunk.emit(.load_local, 1);
    _ = try chunk.emit(.call, 1);
    _ = try chunk.emit(.ret, 0);

    var plan = try build(&chunk, std.testing.allocator);
    defer plan.deinit();
    var call_state: ?FrameState = null;
    for (plan.graph.frame_states) |state| {
        if (state.kind == .call) call_state = state;
    }
    const state = call_state orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u32, 2), state.origin);
    try std.testing.expectEqual(@as(u32, 2), state.stack_count);
    try std.testing.expectEqual(@as(usize, 1), plan.graph.returns.len);
    const result = plan.graph.returns[0].value;
    try std.testing.expectEqual(ValueKind.call, plan.graph.nodes[result].kind);
    try std.testing.expectEqual(@as(u64, 1), plan.graph.nodes[result].immediate);
    try std.testing.expect(plan.graph.nodes[result].may_have_effect);
}

test "optimizer models to_numeric as an effectful value with normal flow" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var chunk = bc.Chunk.init(arena.allocator());
    chunk.param_count = 1;
    chunk.local_count = 1;
    _ = try chunk.emit(.load_local, 0);
    _ = try chunk.emit(.to_numeric, 0);
    _ = try chunk.emit(.ret, 0);

    var plan = try build(&chunk, std.testing.allocator);
    defer plan.deinit();
    try std.testing.expectEqual(@as(usize, 1), plan.graph.returns.len);
    const result = plan.graph.returns[0].value;
    try std.testing.expectEqual(ValueKind.to_numeric, plan.graph.nodes[result].kind);
    try std.testing.expect(plan.graph.nodes[result].may_have_effect);
    var effect_state: ?FrameState = null;
    for (plan.graph.frame_states) |state| if (state.kind == .effect and state.origin == 1) {
        effect_state = state;
    };
    const state = effect_state orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u32, 1), state.stack_count);
    try std.testing.expectEqual(@as(usize, 0), plan.graph.exceptional_targets.len);
}

test "optimizer models a named read through dup and swap with normal flow" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var chunk = bc.Chunk.init(arena.allocator());
    chunk.param_count = 1;
    chunk.local_count = 1;
    const name = try chunk.addName("value");
    _ = try chunk.emit(.load_local, 0);
    _ = try chunk.emit(.dup, 0);
    _ = try chunk.emit(.get_prop, name);
    _ = try chunk.emit(.swap, 0);
    _ = try chunk.emit(.pop, 0);
    _ = try chunk.emit(.ret, 0);

    var plan = try build(&chunk, std.testing.allocator);
    defer plan.deinit();
    try std.testing.expectEqual(@as(usize, 1), plan.graph.returns.len);
    const result = plan.graph.returns[0].value;
    try std.testing.expectEqual(ValueKind.get_prop, plan.graph.nodes[result].kind);
    try std.testing.expectEqual(@as(u64, name), plan.graph.nodes[result].immediate);
    try std.testing.expect(plan.graph.nodes[result].may_have_effect);
}

test "optimizer keeps every computed write operand live" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var chunk = bc.Chunk.init(arena.allocator());
    chunk.param_count = 2;
    chunk.local_count = 2;
    const seven = try chunk.addConst(RuntimeValue.num(7));
    _ = try chunk.emit(.load_local, 0);
    _ = try chunk.emit(.load_local, 1);
    _ = try chunk.emit(.load_const, seven);
    _ = try chunk.emit(.set_index, 0);
    _ = try chunk.emit(.ret, 0);

    var plan = try build(&chunk, std.testing.allocator);
    defer plan.deinit();
    const result = plan.graph.returns[0].value;
    const write = plan.graph.nodes[result];
    try std.testing.expectEqual(ValueKind.set_index, write.kind);
    try std.testing.expect(write.lhs != ValueNode.none and write.rhs != ValueNode.none and write.third != ValueNode.none);
    try std.testing.expectEqual(ValueKind.constant, plan.graph.nodes[write.third].kind);
}

test "optimizer records exact exceptional targets for interpreter-owned effects" {
    const Case = struct { op: bc.Op, inputs: u32, a: u32 = 0, b: u32 = 0 };
    const cases = [_]Case{
        .{ .op = .add, .inputs = 2 },
        .{ .op = .sub, .inputs = 2 },
        .{ .op = .mul, .inputs = 2 },
        .{ .op = .div, .inputs = 2 },
        .{ .op = .mod, .inputs = 2 },
        .{ .op = .lt, .inputs = 2 },
        .{ .op = .le, .inputs = 2 },
        .{ .op = .gt, .inputs = 2 },
        .{ .op = .ge, .inputs = 2 },
        .{ .op = .eq, .inputs = 2 },
        .{ .op = .neq, .inputs = 2 },
        .{ .op = .eq_strict, .inputs = 2 },
        .{ .op = .neq_strict, .inputs = 2 },
        .{ .op = .call, .inputs = 2, .a = 1 },
        .{ .op = .call_eval, .inputs = 2, .a = 1 },
        .{ .op = .call_method, .inputs = 2, .b = 1 },
        .{ .op = .call_spread, .inputs = 2 },
        .{ .op = .call_eval_spread, .inputs = 2 },
        .{ .op = .call_with_this_spread, .inputs = 3 },
        .{ .op = .call_with_this, .inputs = 3, .a = 1 },
        .{ .op = .new_call, .inputs = 2, .a = 1 },
        .{ .op = .new_spread, .inputs = 2 },
        .{ .op = .tail_call, .inputs = 2, .a = 1 },
        .{ .op = .tail_call_eval, .inputs = 2, .a = 1 },
        .{ .op = .tail_call_method, .inputs = 2, .b = 1 },
        .{ .op = .tail_call_with_this, .inputs = 3, .a = 1 },
        .{ .op = .new_object, .inputs = 0 },
        .{ .op = .new_array, .inputs = 0 },
        .{ .op = .init_prop, .inputs = 2 },
        .{ .op = .init_proto, .inputs = 2 },
        .{ .op = .init_prop_computed, .inputs = 3 },
        .{ .op = .init_spread, .inputs = 2 },
        .{ .op = .init_getter, .inputs = 3 },
        .{ .op = .init_setter, .inputs = 3 },
        .{ .op = .array_append, .inputs = 2 },
        .{ .op = .array_spread, .inputs = 2 },
        .{ .op = .array_append_hole, .inputs = 1 },
        .{ .op = .get_prop, .inputs = 1 },
        .{ .op = .get_index, .inputs = 2 },
        .{ .op = .set_prop, .inputs = 2 },
        .{ .op = .set_index, .inputs = 3 },
        .{ .op = .pow, .inputs = 2 },
        .{ .op = .bit_and, .inputs = 2 },
        .{ .op = .bit_or, .inputs = 2 },
        .{ .op = .bit_xor, .inputs = 2 },
        .{ .op = .shl, .inputs = 2 },
        .{ .op = .shr, .inputs = 2 },
        .{ .op = .ushr, .inputs = 2 },
        .{ .op = .in_op, .inputs = 2 },
        .{ .op = .instance_of, .inputs = 2 },
        .{ .op = .private_in, .inputs = 1 },
        .{ .op = .to_numeric, .inputs = 1 },
        .{ .op = .neg, .inputs = 1 },
        .{ .op = .pos, .inputs = 1 },
        .{ .op = .not, .inputs = 1 },
        .{ .op = .typeof_op, .inputs = 1 },
        .{ .op = .inc, .inputs = 1 },
        .{ .op = .dec, .inputs = 1 },
        .{ .op = .bit_not, .inputs = 1 },
        .{ .op = .to_string, .inputs = 1 },
        .{ .op = .to_property_key, .inputs = 1 },
    };
    for (cases) |case| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var chunk = bc.Chunk.init(arena.allocator());
        chunk.param_count = case.inputs;
        chunk.local_count = case.inputs;
        const catch_ip = case.inputs + 3;
        _ = try chunk.emitAB(.push_handler, catch_ip, std.math.maxInt(u32));
        for (0..case.inputs) |slot| _ = try chunk.emit(.load_local, @intCast(slot));
        const operand_a = if (case.op == .get_prop or case.op == .set_prop or case.op == .call_method or
            case.op == .init_prop)
            try chunk.addName("value")
        else if (case.op == .private_in)
            try chunk.addName("#value")
        else
            case.a;
        const operation = try chunk.emitAB(case.op, operand_a, case.b);
        _ = try chunk.emit(.ret_undef, 0);
        _ = try chunk.emit(.ret_undef, 0);
        try chunk.finalize();
        switch (case.op) {
            .add, .sub, .mul, .div, .mod, .lt, .le, .gt, .ge, .eq, .neq, .eq_strict, .neq_strict => chunk.observeOptimizerBinary(operation, .object, .number),
            else => {},
        }

        var plan = try build(&chunk, std.testing.allocator);
        defer plan.deinit();
        try std.testing.expectEqual(@as(usize, 1), plan.graph.exceptional_targets.len);
        const target = plan.graph.exceptional_targets[0];
        try std.testing.expectEqual(EdgeKind.catch_, target.kind);
        try std.testing.expectEqual(case.inputs + 1, target.origin);
        try std.testing.expectEqual(@as(u32, 0), target.unwind_stack_depth);
        try std.testing.expectEqual(@as(u32, 1), target.target_stack_depth);
        try std.testing.expectEqual(@as(u32, 0), target.handler_count);
        try std.testing.expectEqual(catch_ip, plan.blocks[target.target].start);
    }
}

test "optimizer exceptional targets retain outer handlers after finally unwind" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var chunk = bc.Chunk.init(arena.allocator());
    chunk.param_count = 1;
    chunk.local_count = 1;
    _ = try chunk.emitAB(.push_handler, 7, std.math.maxInt(u32));
    _ = try chunk.emitAB(.push_handler, std.math.maxInt(u32), 6);
    _ = try chunk.emit(.load_local, 0);
    _ = try chunk.emit(.call, 0);
    _ = try chunk.emit(.ret_undef, 0);
    _ = try chunk.emit(.ret_undef, 0);
    _ = try chunk.emit(.end_finally, 0);
    _ = try chunk.emit(.ret_undef, 0);

    var plan = try build(&chunk, std.testing.allocator);
    defer plan.deinit();
    try std.testing.expectEqual(@as(usize, 1), plan.graph.exceptional_targets.len);
    const target = plan.graph.exceptional_targets[0];
    try std.testing.expectEqual(EdgeKind.finally_, target.kind);
    try std.testing.expectEqual(@as(u32, 2), target.target_stack_depth);
    try std.testing.expectEqual(@as(u32, 1), target.handler_count);
    const outer = plan.graph.handler_states[target.first_handler];
    try std.testing.expectEqual(@as(u32, 7), outer.catch_ip);
    try std.testing.expectEqual(std.math.maxInt(u32), outer.finally_ip);
}

test "optimizer canonicalizes pure values and removes dead SSA" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var chunk = bc.Chunk.init(a);
    const one = try chunk.addConst(RuntimeValue.num(1));
    const two = try chunk.addConst(RuntimeValue.num(2));
    const three = try chunk.addConst(RuntimeValue.num(3));
    const four = try chunk.addConst(RuntimeValue.num(4));
    _ = try chunk.emit(.load_const, three);
    _ = try chunk.emit(.load_const, four);
    _ = try chunk.emit(.add, 0);
    _ = try chunk.emit(.pop, 0);
    _ = try chunk.emit(.load_const, one);
    _ = try chunk.emit(.load_const, two);
    _ = try chunk.emit(.add, 0);
    _ = try chunk.emit(.load_const, one);
    _ = try chunk.emit(.load_const, two);
    _ = try chunk.emit(.add, 0);
    _ = try chunk.emit(.add, 0);
    _ = try chunk.emit(.ret, 0);

    var plan = try build(&chunk, std.testing.allocator);
    defer plan.deinit();
    try std.testing.expectEqual(@as(usize, 4), plan.graph.nodes.len);
    var additions: usize = 0;
    for (plan.graph.nodes) |node| if (node.kind == .add) {
        additions += 1;
    };
    try std.testing.expectEqual(@as(usize, 2), additions);
}

test "optimizer rejects unsupported bytecode and invalid control flow" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var chunk = bc.Chunk.init(arena.allocator());
    _ = try chunk.emit(.nop, 0);
    _ = try chunk.emit(.ret, 0);
    try std.testing.expectError(error.UnsupportedChunk, build(&chunk, std.testing.allocator));

    var invalid = bc.Chunk.init(arena.allocator());
    _ = try invalid.emit(.jump, 1);
    try std.testing.expectError(error.InvalidControlFlow, build(&invalid, std.testing.allocator));

    var mismatched_merge = bc.Chunk.init(arena.allocator());
    const one = try mismatched_merge.addConst(RuntimeValue.num(1));
    _ = try mismatched_merge.emit(.load_true, 0);
    _ = try mismatched_merge.emit(.jump_if_false, 4);
    _ = try mismatched_merge.emit(.load_const, one);
    _ = try mismatched_merge.emit(.jump, 4);
    _ = try mismatched_merge.emit(.ret_undef, 0);
    try std.testing.expectError(error.InvalidControlFlow, build(&mismatched_merge, std.testing.allocator));

    var mismatched_handlers = bc.Chunk.init(arena.allocator());
    _ = try mismatched_handlers.emit(.load_true, 0);
    _ = try mismatched_handlers.emit(.jump_if_false, 4);
    _ = try mismatched_handlers.emitAB(.push_handler, 5, std.math.maxInt(u32));
    _ = try mismatched_handlers.emit(.jump, 4);
    _ = try mismatched_handlers.emit(.ret_undef, 0);
    _ = try mismatched_handlers.emit(.ret_undef, 0);
    try std.testing.expectError(error.InvalidControlFlow, build(&mismatched_handlers, std.testing.allocator));

    var unbalanced_handler = bc.Chunk.init(arena.allocator());
    _ = try unbalanced_handler.emit(.pop_handler, 0);
    _ = try unbalanced_handler.emit(.ret_undef, 0);
    try std.testing.expectError(error.InvalidControlFlow, build(&unbalanced_handler, std.testing.allocator));
}
