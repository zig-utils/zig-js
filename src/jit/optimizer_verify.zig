//! Structural and semantic checks for the optimizer's SSA/recovery contract.
const std = @import("std");
const ir = @import("optimizer.zig");
const bc = @import("../bytecode.zig");
const RuntimeValue = @import("../value.zig").Value;

pub const Mode = enum { function, region };
pub const Error = std.mem.Allocator.Error || error{
    InvalidBlock,
    InvalidInstruction,
    InvalidValue,
    InvalidSSA,
    InvalidDominance,
    InvalidEffect,
    InvalidFrameState,
    InvalidEdge,
    InvalidHandler,
    InvalidExceptionalTarget,
};
const none = std.math.maxInt(u32);

fn range(first: usize, count: usize, length: usize) bool {
    return first <= length and count <= length - first;
}

fn leaf(kind: ir.ValueKind) bool {
    return switch (kind) {
        .argument, .constant, .undefined, .null, .true, .false => true,
        else => false,
    };
}

fn binary(kind: ir.ValueKind) bool {
    return switch (kind) {
        .add, .sub, .mul, .div, .mod, .lt, .le, .gt, .ge, .eq, .neq, .eq_strict, .neq_strict => true,
        else => false,
    };
}

fn primitive(node: ir.ValueNode) bool {
    if (node.kind == .argument or node.kind == .block_argument or node.kind == .interpreter_value or node.kind == .binding_base) return false;
    return !node.may_have_effect;
}

fn operandCount(kind: ir.ValueKind) u2 {
    return switch (kind) {
        .argument,
        .block_argument,
        .constant,
        .undefined,
        .null,
        .true,
        .false,
        .call,
        .call_eval,
        .call_method,
        .call_spread,
        .call_eval_spread,
        .call_with_this_spread,
        .call_with_this,
        .construct,
        .construct_spread,
        .new_object,
        .new_array,
        .load_var,
        .load_this,
        .load_new_target,
        .load_capture,
        .load_var_or_undef,
        .init_declarations,
        .copy_annex_b,
        .resolve_binding_ref,
        .load_binding_ref,
        .clear_binding_ref,

        .interpreter_value,
        => 0,
        .store_capture,
        .store_var,
        .def_var,
        .def_lex,
        .store_binding_ref,
        .binding_base,
        .branch_predicate,

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
        .private_in,
        .array_append_hole,
        .iter_of,
        .assert_iter_result,
        .iter_close,
        => 1,
        .set_index, .init_prop_computed, .init_getter, .init_setter, .iter_close_completion => 3,
        else => 2,
    };
}

const Arc = struct { from: u32, to: u32 };
const Adjacency = struct {
    allocator: std.mem.Allocator,
    offsets: []usize,
    vertices: []u32,

    fn init(allocator: std.mem.Allocator, count: usize, arcs: []const Arc, reverse: bool) !Adjacency {
        const offsets = try allocator.alloc(usize, count + 1);
        errdefer allocator.free(offsets);
        @memset(offsets, 0);
        for (arcs) |arc| offsets[(if (reverse) arc.to else arc.from) + 1] += 1;
        for (1..offsets.len) |index| offsets[index] += offsets[index - 1];
        const vertices = try allocator.alloc(u32, arcs.len);
        errdefer allocator.free(vertices);
        const cursors = try allocator.dupe(usize, offsets[0..count]);
        defer allocator.free(cursors);
        for (arcs) |arc| {
            const from = if (reverse) arc.to else arc.from;
            vertices[cursors[from]] = if (reverse) arc.from else arc.to;
            cursors[from] += 1;
        }
        return .{ .allocator = allocator, .offsets = offsets, .vertices = vertices };
    }

    fn deinit(self: Adjacency) void {
        self.allocator.free(self.offsets);
        self.allocator.free(self.vertices);
    }

    fn at(self: Adjacency, vertex: u32) []const u32 {
        return self.vertices[self.offsets[vertex]..self.offsets[vertex + 1]];
    }
};

const Dominance = struct {
    allocator: std.mem.Allocator,
    parents: []u32,
    root: u32,

    fn intersect(parents: []const u32, rank: []const u32, left: u32, right: u32) u32 {
        var a = left;
        var b = right;
        while (a != b) {
            while (rank[a] > rank[b]) a = parents[a];
            while (rank[b] > rank[a]) b = parents[b];
        }
        return a;
    }

    fn init(allocator: std.mem.Allocator, plan: *const ir.Plan, active: []const bool, mode: Mode) Error!Dominance {
        if (plan.blocks.len >= none) return error.InvalidBlock;
        const root: u32 = @intCast(plan.blocks.len);
        const count = plan.blocks.len + 1;
        var arcs: std.ArrayListUnmanaged(Arc) = .empty;
        defer arcs.deinit(allocator);
        const region_entries = std.math.mul(usize, plan.blocks.len, 2) catch return error.InvalidBlock;
        const edge_count = std.math.add(usize, plan.graph.edges.len, plan.graph.exceptional_targets.len) catch return error.InvalidEdge;
        const arc_capacity = std.math.add(usize, edge_count, if (mode == .region) region_entries else 0) catch return error.InvalidEdge;
        try arcs.ensureTotalCapacityPrecise(allocator, arc_capacity);
        for (plan.graph.edges) |edge| {
            if (!active[edge.to]) continue;
            if (edge.from == none) {
                try arcs.append(allocator, .{ .from = root, .to = edge.to });
            } else if (active[edge.from]) {
                try arcs.append(allocator, .{ .from = edge.from, .to = edge.to });
            }
        }
        for (plan.graph.exceptional_targets) |target| {
            if (active[target.block] and active[target.target])
                try arcs.append(allocator, .{ .from = target.block, .to = target.target });
        }
        // Selected loop graphs keep original block ids and retain outgoing
        // recovery edges. Their preheader is outside the selected graph.
        if (mode == .region) for (plan.blocks) |block| {
            if (active[block.id]) continue;
            for (block.successors[0..block.successor_count]) |successor| {
                if (active[successor]) try arcs.append(allocator, .{ .from = root, .to = successor });
            }
        };
        const successors = try Adjacency.init(allocator, count, arcs.items, false);
        defer successors.deinit();
        const predecessors = try Adjacency.init(allocator, count, arcs.items, true);
        defer predecessors.deinit();
        const seen = try allocator.alloc(bool, count);
        defer allocator.free(seen);
        @memset(seen, false);
        const Visit = struct { vertex: u32, next: usize = 0 };
        var stack: std.ArrayListUnmanaged(Visit) = .empty;
        defer stack.deinit(allocator);
        var postorder: std.ArrayListUnmanaged(u32) = .empty;
        defer postorder.deinit(allocator);
        try stack.ensureTotalCapacityPrecise(allocator, count);
        try postorder.ensureTotalCapacityPrecise(allocator, count);
        seen[root] = true;
        try stack.append(allocator, .{ .vertex = root });
        while (stack.items.len != 0) {
            const last = &stack.items[stack.items.len - 1];
            const children = successors.at(last.vertex);
            if (last.next < children.len) {
                const child = children[last.next];
                last.next += 1;
                if (!seen[child]) {
                    seen[child] = true;
                    try stack.append(allocator, .{ .vertex = child });
                }
            } else {
                try postorder.append(allocator, last.vertex);
                _ = stack.pop();
            }
        }
        for (active, 0..) |included, block| if (included and !seen[block]) return error.InvalidDominance;
        std.mem.reverse(u32, postorder.items);
        const rank = try allocator.alloc(u32, count);
        defer allocator.free(rank);
        @memset(rank, none);
        for (postorder.items, 0..) |vertex, index| rank[vertex] = @intCast(index);
        const parents = try allocator.alloc(u32, count);
        errdefer allocator.free(parents);
        @memset(parents, none);
        parents[root] = root;
        var changed = true;
        while (changed) {
            changed = false;
            for (postorder.items[1..]) |vertex| {
                var parent: u32 = none;
                for (predecessors.at(vertex)) |predecessor| {
                    if (parents[predecessor] == none) continue;
                    parent = if (parent == none) predecessor else intersect(parents, rank, parent, predecessor);
                }
                if (parent != none and parents[vertex] != parent) {
                    parents[vertex] = parent;
                    changed = true;
                }
            }
        }
        return .{ .allocator = allocator, .parents = parents, .root = root };
    }

    fn deinit(self: Dominance) void {
        self.allocator.free(self.parents);
    }

    fn contains(self: Dominance, definition: u32, use: u32) bool {
        var cursor = use;
        while (cursor != self.root and cursor != none) {
            if (cursor == definition) return true;
            cursor = self.parents[cursor];
        }
        return false;
    }
};

fn available(plan: *const ir.Plan, dominance: Dominance, id: u32, block: u32, origin: u32, before: bool) Error!void {
    if (id >= plan.graph.nodes.len) return error.InvalidValue;
    const node = plan.graph.nodes[id];
    if (leaf(node.kind)) return;
    if (node.block == block) {
        if (node.kind == .block_argument) return;
        if (node.origin > origin or (before and node.origin == origin)) return error.InvalidSSA;
    } else if (!dominance.contains(node.block, block)) return error.InvalidDominance;
}

fn sameHandlers(graph: *const ir.ValueGraph, first: u32, count: u32, other_first: u32, other_count: u32) bool {
    if (count != other_count) return false;
    for (graph.handler_states[first .. first + count], graph.handler_states[other_first .. other_first + count]) |a, b| {
        if (a.catch_ip != b.catch_ip or a.finally_ip != b.finally_ip or a.stack_depth != b.stack_depth) return false;
    }
    return true;
}

/// Linear scratch storage, iterative CFG traversal, and immediate dominators
/// avoid a quadratic dominance matrix or native-stack recursion on deep graphs.
pub fn verify(plan: *const ir.Plan, mode: Mode) Error!void {
    const allocator = plan.allocator;
    const graph = &plan.graph;
    if (plan.blocks.len == 0 or plan.instructions.len == 0) return error.InvalidBlock;
    // A zero-input, zero-output interpreter side exit can have no SSA values;
    // every nonempty recovery/use slice below must still name an existing id.
    for (plan.instructions, 0..) |instruction, index| {
        if (instruction.id != index or instruction.origin != index) return error.InvalidInstruction;
    }
    var next_instruction: usize = 0;
    for (plan.blocks, 0..) |block, index| {
        if (block.id != index or block.start != next_instruction or block.end <= block.start or
            block.end > plan.instructions.len or block.first_instruction != block.start or
            block.instruction_count != block.end - block.start or block.successor_count > block.successors.len)
            return error.InvalidBlock;
        for (block.successors[0..block.successor_count]) |successor| if (successor >= plan.blocks.len) return error.InvalidBlock;
        next_instruction = block.end;
    }
    if (next_instruction != plan.instructions.len) return error.InvalidBlock;
    if (plan.entry_region_exit) |exit_ip| {
        if (exit_ip == 0 or exit_ip >= plan.instructions.len) return error.InvalidFrameState;
        var exit_block: ?u32 = null;
        for (plan.blocks) |block| if (block.start == exit_ip and block.successor_count == 0) {
            exit_block = block.id;
        };
        const boundary = exit_block orelse return error.InvalidFrameState;
        var found_entry = false;
        for (graph.frame_states) |state| if (state.block == boundary) {
            if (state.kind != .block_entry or state.origin != exit_ip) return error.InvalidFrameState;
            found_entry = true;
        };
        if (!found_entry) return error.InvalidFrameState;
        for (graph.nodes) |node| if (node.block == boundary and node.kind != .block_argument) return error.InvalidFrameState;
    }
    const entries = try allocator.alloc(u32, plan.blocks.len);
    defer allocator.free(entries);
    @memset(entries, none);
    const active = try allocator.alloc(bool, plan.blocks.len);
    defer allocator.free(active);
    @memset(active, false);
    const effects = try allocator.alloc(u32, plan.instructions.len);
    defer allocator.free(effects);
    @memset(effects, none);
    var local_count: ?u32 = null;
    for (graph.handler_states) |handler| {
        if (handler.catch_ip == none and handler.finally_ip == none) return error.InvalidHandler;
        for ([_]u32{ handler.catch_ip, handler.finally_ip }) |target| {
            if (target == none) continue;
            var found = false;
            for (plan.blocks) |block| if (block.start == target) {
                found = true;
                break;
            };
            if (!found) return error.InvalidHandler;
        }
    }
    for (graph.frame_states, 0..) |state, index| {
        if (state.block >= plan.blocks.len) return error.InvalidFrameState;
        const block = plan.blocks[state.block];
        if (state.origin < block.start or state.origin >= plan.instructions.len or
            (state.origin >= block.end and !(state.kind == .continuation and state.origin == block.end))) return error.InvalidFrameState;
        if (local_count) |known| if (state.local_count != known) return error.InvalidFrameState;
        local_count = state.local_count;
        const count = std.math.add(usize, state.local_count, state.stack_count) catch return error.InvalidFrameState;
        if (!range(state.first_value, count, graph.frame_state_values.len) or
            !range(state.first_handler, state.handler_count, graph.handler_states.len)) return error.InvalidFrameState;
        const instruction = plan.instructions[state.origin];
        const call_operation = switch (instruction.op) {
            .call,
            .call_eval,
            .call_method,
            .call_spread,
            .call_eval_spread,
            .call_with_this_spread,
            .call_with_this,
            .new_call,
            .new_spread,
            .tail_call,
            .tail_call_eval,
            .tail_call_method,
            .tail_call_eval_with_this,
            .tail_call_with_this,
            .tail_call_spread,
            .tail_call_with_this_spread,
            => true,
            else => false,
        };
        const valid_kind = switch (state.kind) {
            .block_entry => true,
            .call => call_operation,
            .effect => !call_operation and ir.nativeOperationInputCount(.{ .op = instruction.op, .a = instruction.a, .b = instruction.b }) != null,
            .continuation => state.origin > block.start and ir.nativeOperationInputCount(.{
                .op = plan.instructions[state.origin - 1].op,
                .a = plan.instructions[state.origin - 1].a,
                .b = plan.instructions[state.origin - 1].b,
            }) != null,
            .throw_ => instruction.op == .throw_op,
            .return_ => instruction.op == .ret or instruction.op == .ret_undef,
            .branch => instruction.op == .jump_if_false or instruction.op == .jump_if_true_peek or instruction.op == .jump_if_false_peek or instruction.op == .jump_if_nullish_peek or instruction.op == .jump_if_not_nullish_peek,
            .finally_dispatch => instruction.op == .end_finally,
            .abrupt_return => instruction.op == .abrupt_return,
            .abrupt_jump => instruction.op == .abrupt_break or instruction.op == .abrupt_continue,
        };
        if (!valid_kind) return error.InvalidFrameState;
        if (state.kind == .block_entry) {
            if (state.origin != block.start or entries[state.block] != none) return error.InvalidFrameState;
            entries[state.block] = @intCast(index);
            active[state.block] = true;
        } else if (state.kind == .effect or state.kind == .call or state.kind == .throw_) {
            if (effects[state.origin] != none) return error.InvalidFrameState;
            effects[state.origin] = @intCast(index);
            if (ir.nativeOperationInputCount(.{ .op = plan.instructions[state.origin].op, .a = plan.instructions[state.origin].a, .b = plan.instructions[state.origin].b })) |required| {
                if (state.stack_count < required) return error.InvalidFrameState;
            }
        }
    }
    if (mode == .function and !active[0]) return error.InvalidFrameState;
    if (local_count == null) return error.InvalidFrameState;
    if (graph.edges.len != graph.edge_states.len) return error.InvalidEdge;
    const normal_edges = try allocator.alloc([2]u32, plan.blocks.len);
    defer allocator.free(normal_edges);
    @memset(normal_edges, .{ 0, 0 });
    for (graph.edges, graph.edge_states) |edge, state| {
        if (edge.to >= plan.blocks.len or (edge.from != none and edge.from >= plan.blocks.len) or
            !range(edge.first_argument, edge.argument_count, graph.edge_arguments.len) or
            !range(state.first_handler, state.handler_count, graph.handler_states.len) or
            state.from != edge.from or state.to != edge.to or state.first_value != edge.first_argument or
            state.origin != plan.blocks[edge.to].start or
            state.local_count != local_count.? or
            @as(u64, state.local_count) + state.stack_count != edge.argument_count)
            return error.InvalidEdge;
        if (edge.from != none and !active[edge.from]) return error.InvalidEdge;
        if (active[edge.to]) {
            const entry = graph.frame_states[entries[edge.to]];
            if (state.origin != entry.origin or state.local_count != entry.local_count or state.stack_count != entry.stack_count or
                !sameHandlers(graph, state.first_handler, state.handler_count, entry.first_handler, entry.handler_count)) return error.InvalidEdge;
        } else if (mode == .function) return error.InvalidEdge;
        if (edge.from == none) {
            if (edge.to != 0 or edge.kind != .normal) return error.InvalidEdge;
        } else if (edge.kind == .normal) {
            var found = false;
            const source = plan.blocks[edge.from];
            for (source.successors[0..source.successor_count], 0..) |successor, slot| if (successor == edge.to) {
                normal_edges[edge.from][slot] += 1;
                found = true;
                break;
            };
            if (!found) return error.InvalidEdge;
        } else {
            const origin = plan.blocks[edge.from].end - 1;
            if (plan.instructions[origin].op != .throw_op or effects[origin] == none) return error.InvalidEdge;
            const recovery = graph.frame_states[effects[origin]];
            if (recovery.handler_count == 0) return error.InvalidEdge;
            const handler = graph.handler_states[recovery.first_handler + recovery.handler_count - 1];
            const catches = handler.catch_ip != none;
            if (edge.kind != (if (catches) ir.EdgeKind.catch_ else ir.EdgeKind.finally_) or
                plan.blocks[edge.to].start != (if (catches) handler.catch_ip else handler.finally_ip)) return error.InvalidEdge;
        }
    }
    for (plan.blocks) |block| if (active[block.id]) {
        for (normal_edges[block.id][0..block.successor_count]) |count| if (count != 1) return error.InvalidEdge;
    };
    const exceptional_origins = try allocator.alloc(bool, plan.instructions.len);
    defer allocator.free(exceptional_origins);
    @memset(exceptional_origins, false);
    for (graph.exceptional_targets) |target| {
        if (target.block >= plan.blocks.len or target.target >= plan.blocks.len or !active[target.block] or
            target.origin < plan.blocks[target.block].start or target.origin >= plan.blocks[target.block].end or
            target.kind == .normal or !range(target.first_handler, target.handler_count, graph.handler_states.len)) return error.InvalidExceptionalTarget;
        if (exceptional_origins[target.origin]) return error.InvalidExceptionalTarget;
        exceptional_origins[target.origin] = true;
        const expected_depth = std.math.add(u32, target.unwind_stack_depth, if (target.kind == .catch_) 1 else 2) catch return error.InvalidExceptionalTarget;
        if (expected_depth != target.target_stack_depth or effects[target.origin] == none) return error.InvalidExceptionalTarget;
        const source = graph.frame_states[effects[target.origin]];
        if (source.handler_count == 0 or target.handler_count != source.handler_count - 1) return error.InvalidExceptionalTarget;
        const handler = graph.handler_states[source.first_handler + source.handler_count - 1];
        const catches = handler.catch_ip != none;
        if (target.kind != (if (catches) ir.EdgeKind.catch_ else ir.EdgeKind.finally_) or
            plan.blocks[target.target].start != (if (catches) handler.catch_ip else handler.finally_ip) or
            target.unwind_stack_depth != handler.stack_depth or
            !sameHandlers(graph, target.first_handler, target.handler_count, source.first_handler, source.handler_count - 1)) return error.InvalidExceptionalTarget;
        if (active[target.target]) {
            const entry = graph.frame_states[entries[target.target]];
            if (entry.stack_count != target.target_stack_depth or
                !sameHandlers(graph, entry.first_handler, entry.handler_count, target.first_handler, target.handler_count)) return error.InvalidExceptionalTarget;
        }
        // An effect's exception may resume interpreter-owned bytecode rather
        // than a represented SSA block; its handler/depth contract above is
        // still mandatory, while no native block-entry map exists to compare.
    }
    for (effects, 0..) |state_index, origin| {
        if (state_index == none) continue;
        const state = graph.frame_states[state_index];
        if ((state.handler_count != 0) != exceptional_origins[origin]) return error.InvalidExceptionalTarget;
    }
    const dominance = try Dominance.init(allocator, plan, active, mode);
    defer dominance.deinit();
    const last_effect = try allocator.alloc(?u32, plan.blocks.len);
    defer allocator.free(last_effect);
    @memset(last_effect, null);
    for (graph.nodes, 0..) |node, index| {
        if (node.id != index or node.origin >= plan.instructions.len) return error.InvalidValue;
        if (!leaf(node.kind)) {
            if (node.block >= plan.blocks.len or !active[node.block]) return error.InvalidValue;
            const block = plan.blocks[node.block];
            if (node.origin < block.start or node.origin >= block.end) return error.InvalidValue;
        }
        if (node.kind == .block_argument) {
            const entry = graph.frame_states[entries[node.block]];
            if (node.origin != entry.origin or node.immediate >= @as(u64, entry.local_count) + entry.stack_count or
                graph.frame_state_values[entry.first_value + @as(usize, @intCast(node.immediate))] != node.id) return error.InvalidSSA;
        }
        const operands = [_]u32{ node.lhs, node.rhs, node.third };
        const operand_count = if (node.kind == .init_getter or node.kind == .init_setter) ir.nativeOperationInputCount(.{
            .op = plan.instructions[node.origin].op,
            .a = plan.instructions[node.origin].a,
            .b = plan.instructions[node.origin].b,
        }) orelse return error.InvalidSSA else operandCount(node.kind);
        for (operands, 0..) |operand, slot| {
            if ((operand != none) != (slot < operand_count)) return error.InvalidSSA;
        }
        if (leaf(node.kind) or node.kind == .block_argument) {
            if (node.may_have_effect) return error.InvalidEffect;
            if (node.block != none and node.block >= plan.blocks.len) return error.InvalidValue;
            if (node.kind == .argument) {
                if (node.block != none or local_count == null or node.immediate >= local_count.?)
                    return error.InvalidValue;
            } else if (node.kind == .constant) {
                const constant = RuntimeValue.fromRawBits(node.immediate);
                if (constant.isObject() or constant.isString()) return error.InvalidValue;
            }
        } else if (node.kind != .interpreter_value) {
            const op = plan.instructions[node.origin].op;
            const expected: ir.ValueKind = if (node.kind == .branch_predicate and (op == .jump_if_true_peek or op == .jump_if_false_peek or op == .jump_if_nullish_peek or op == .jump_if_not_nullish_peek)) .branch_predicate else if (node.kind == .binding_base and op == .load_binding_ref and plan.instructions[node.origin].b & bc.binding_ref_load_with_base != 0) .binding_base else switch (op) {
                .load_upval, .load_upval_mapped, .load_upval_lexical => .load_capture,
                .store_upval, .store_upval_mapped, .store_upval_lexical => .store_capture,
                .new_call => .construct,
                .new_spread => .construct_spread,
                .tail_call => .call,
                .tail_call_eval => .call_eval,
                .tail_call_method => .call_method,
                .tail_call_with_this => .call_with_this,
                .tail_call_spread => .call_spread,
                .tail_call_with_this_spread => .call_with_this_spread,
                else => std.meta.stringToEnum(ir.ValueKind, @tagName(op)) orelse return error.InvalidValue,
            };
            if (expected != node.kind) return error.InvalidValue;
            switch (node.kind) {
                .load_capture, .store_capture, .load_var_or_undef, .store_var, .def_var, .def_lex, .init_declarations, .copy_annex_b, .resolve_binding_ref, .load_binding_ref, .clear_binding_ref, .store_binding_ref => {
                    const instruction = plan.instructions[node.origin];
                    if (node.immediate != (@as(u64, instruction.a) << 32) | instruction.b) return error.InvalidValue;
                },
                .load_var,
                .get_prop,
                .set_prop,
                .private_in,
                .init_prop,
                .init_prop_computed,
                .init_getter,
                .init_setter,
                .call,
                .call_eval,
                .call_method,
                .call_with_this,
                .call_spread,
                .call_eval_spread,
                .call_with_this_spread,
                .construct,
                .construct_spread,
                => {
                    const instruction = plan.instructions[node.origin];
                    const immediate = if (node.kind == .call_method) instruction.b else instruction.a;
                    if (node.immediate != immediate) return error.InvalidValue;
                },
                .branch_predicate => {
                    if (node.immediate != @backingInt(op)) return error.InvalidValue;
                    if (node.may_have_effect) return error.InvalidEffect;
                },
                else => {},
            }
        }
        for ([_]u32{ node.lhs, node.rhs, node.third }) |operand| {
            if (operand == none) continue;
            if (operand >= graph.nodes.len or operand >= node.id) return error.InvalidSSA;
            const projection = node.kind == .binding_base;
            if (projection and node.may_have_effect) return error.InvalidEffect;
            if (projection and (operand != node.lhs or operand >= node.id or graph.nodes[operand].kind != .load_binding_ref or graph.nodes[operand].origin != node.origin)) return error.InvalidSSA;
            try available(plan, dominance, operand, node.block, node.origin, !projection);
        }
        if (binary(node.kind)) {
            if (node.lhs == none or node.rhs == none or node.third != none) return error.InvalidSSA;
            if (!node.may_have_effect and (!primitive(graph.nodes[node.lhs]) or !primitive(graph.nodes[node.rhs]))) return error.InvalidEffect;
            if (ir.binaryNeedsRuntimeOperands(graph.nodes, node.lhs, node.rhs) and effects[node.origin] == none) return error.InvalidEffect;
        } else if (!leaf(node.kind) and node.kind != .block_argument and node.kind != .binding_base and node.kind != .branch_predicate) {
            if (!node.may_have_effect) return error.InvalidEffect;
            if (node.kind != .interpreter_value or plan.instructions[node.origin].op != .load_const)
                if (effects[node.origin] == none) return error.InvalidEffect;
        }
        if (node.may_have_effect and node.block != none) {
            if (last_effect[node.block]) |previous| if (node.origin < previous) return error.InvalidEffect;
            last_effect[node.block] = node.origin;
        }
    }
    for (graph.frame_states) |state| {
        const count: usize = @as(usize, state.local_count) + state.stack_count;
        for (graph.frame_state_values[state.first_value .. state.first_value + count]) |id|
            try available(plan, dominance, id, state.block, state.origin, true);
    }
    for (graph.edges) |edge| {
        for (graph.edge_arguments[edge.first_argument .. edge.first_argument + edge.argument_count]) |id| {
            if (edge.from == none) {
                if (id >= graph.nodes.len or !leaf(graph.nodes[id].kind)) return error.InvalidEdge;
            } else try available(plan, dominance, id, edge.from, plan.blocks[edge.from].end, true);
        }
    }
    for (graph.returns) |ret| {
        if (ret.block >= plan.blocks.len or !active[ret.block] or ret.origin < plan.blocks[ret.block].start or ret.origin >= plan.blocks[ret.block].end) return error.InvalidFrameState;
        const after_tail_call = switch (plan.instructions[ret.origin].op) {
            .tail_call, .tail_call_eval, .tail_call_method, .tail_call_with_this, .tail_call_spread, .tail_call_with_this_spread => true,
            .ret, .ret_undef => false,
            else => return error.InvalidFrameState,
        };
        // A tail call's result is created by this same instruction; the call's
        // separate recovery map remains strictly pre-effect.
        try available(plan, dominance, ret.value, ret.block, ret.origin, !after_tail_call);
    }
    for (graph.branches) |branch| {
        if (branch.block >= plan.blocks.len or !active[branch.block] or branch.false_block >= plan.blocks.len or branch.true_block >= plan.blocks.len or
            branch.origin < plan.blocks[branch.block].start or branch.origin >= plan.blocks[branch.block].end) return error.InvalidBlock;
        const block = plan.blocks[branch.block];
        const branch_op = plan.instructions[branch.origin].op;
        if (branch_op != .jump_if_false and branch_op != .jump_if_true_peek and branch_op != .jump_if_false_peek and branch_op != .jump_if_nullish_peek and branch_op != .jump_if_not_nullish_peek) return error.InvalidBlock;
        for ([_]u32{ branch.false_block, branch.true_block }) |target| {
            var found = false;
            for (block.successors[0..block.successor_count]) |successor| if (successor == target) {
                found = true;
                break;
            };
            if (!found) return error.InvalidEdge;
        }
        try available(plan, dominance, branch.condition, branch.block, branch.origin, branch_op == .jump_if_false);
    }
    for (graph.frame_states) |state| if (state.kind == .continuation) {
        const index = effects[state.origin - 1];
        if (index == none) return error.InvalidFrameState;
        const previous = graph.frame_states[index];
        const instruction = plan.instructions[state.origin - 1];
        const inst = bc.Inst{ .op = instruction.op, .a = instruction.a, .b = instruction.b };
        const expected = ir.nativeOperationStackDepth(inst, previous.stack_count) orelse return error.InvalidFrameState;
        const inputs = ir.nativeOperationInputCount(inst) orelse return error.InvalidFrameState;
        if (previous.block != state.block or expected != state.stack_count or inputs > previous.stack_count or
            !sameHandlers(graph, previous.first_handler, previous.handler_count, state.first_handler, state.handler_count))
            return error.InvalidFrameState;
        // Close observes the completion pair but preserves it unchanged.
        const preserved_completion = inst.op == .iter_close_completion;
        const prefix = previous.local_count + previous.stack_count - (if (preserved_completion) @as(u32, 1) else inputs);
        if (!std.mem.eql(u32, graph.frame_state_values[previous.first_value..][0..prefix], graph.frame_state_values[state.first_value..][0..prefix]))
            return error.InvalidFrameState;
        if (!preserved_completion and state.stack_count > previous.stack_count - inputs) {
            const result = graph.frame_state_values[state.first_value + state.local_count + state.stack_count - 1];
            if (result >= graph.nodes.len) return error.InvalidValue;
            const producer = graph.nodes[result];
            if (producer.block != previous.block or producer.origin != previous.origin or !producer.may_have_effect or producer.kind == .interpreter_value)
                return error.InvalidFrameState;
        }
    };
}
fn diamond(allocator: std.mem.Allocator) !ir.Plan {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var chunk = bc.Chunk.init(arena.allocator());
    chunk.param_count = 1;
    chunk.local_count = 1;
    const one = try chunk.addConst(RuntimeValue.num(1));
    const two = try chunk.addConst(RuntimeValue.num(2));
    _ = try chunk.emit(.load_local, 0);
    _ = try chunk.emit(.jump_if_false, 6);
    _ = try chunk.emit(.load_local, 0);
    _ = try chunk.emit(.load_const, one);
    _ = try chunk.emit(.add, 0);
    _ = try chunk.emit(.ret, 0);
    _ = try chunk.emit(.load_local, 0);
    _ = try chunk.emit(.load_const, two);
    _ = try chunk.emit(.sub, 0);
    _ = try chunk.emit(.ret, 0);
    return ir.build(&chunk, allocator);
}

fn caughtCall(allocator: std.mem.Allocator) !ir.Plan {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var chunk = bc.Chunk.init(arena.allocator());
    chunk.param_count = 1;
    chunk.local_count = 1;
    _ = try chunk.emitAB(.push_handler, 6, none);
    _ = try chunk.emit(.load_local, 0);
    _ = try chunk.emit(.call, 0);
    _ = try chunk.emit(.ret, 0);
    _ = try chunk.emit(.ret_undef, 0);
    _ = try chunk.emit(.ret_undef, 0);
    _ = try chunk.emit(.ret, 0);
    return ir.build(&chunk, allocator);
}

fn nodeOf(plan: *const ir.Plan, kind: ir.ValueKind) usize {
    for (plan.graph.nodes, 0..) |node, index| if (node.kind == kind) return index;
    unreachable;
}

fn effectOf(plan: *const ir.Plan) usize {
    for (plan.graph.frame_states, 0..) |state, index| if (state.kind == .call) return index;
    unreachable;
}

test "optimizer verifier rejects invalid identities operands dominance and edges" {
    var plan = try diamond(std.testing.allocator);
    defer plan.deinit();
    try verify(&plan, .function);
    const nodes = plan.graph.nodes;
    plan.graph.nodes = nodes[0..0];
    try std.testing.expectError(error.InvalidValue, verify(&plan, .function));
    plan.graph.nodes = nodes;
    const add = nodeOf(&plan, .add);
    const sub = nodeOf(&plan, .sub);
    const original = plan.graph.nodes[sub];
    plan.graph.nodes[sub].id += 1;
    try std.testing.expectError(error.InvalidValue, verify(&plan, .function));
    plan.graph.nodes[sub] = original;
    plan.graph.nodes[sub].lhs = none;
    try std.testing.expectError(error.InvalidSSA, verify(&plan, .function));
    plan.graph.nodes[sub] = original;
    plan.graph.nodes[sub].lhs = @intCast(sub);
    try std.testing.expectError(error.InvalidSSA, verify(&plan, .function));
    plan.graph.nodes[sub] = original;
    plan.graph.nodes[sub].lhs = @intCast(add);
    try std.testing.expectError(error.InvalidDominance, verify(&plan, .function));
    plan.graph.nodes[sub] = original;
    plan.graph.nodes[sub].may_have_effect = false;
    try std.testing.expectError(error.InvalidEffect, verify(&plan, .function));
    plan.graph.nodes[sub] = original;
    const edge = plan.graph.edges[0];
    plan.graph.edges[0].first_argument = @intCast(plan.graph.edge_arguments.len + 1);
    try std.testing.expectError(error.InvalidEdge, verify(&plan, .function));
    plan.graph.edges[0] = edge;
    const state = plan.graph.edge_states[0];
    plan.graph.edge_states[0].local_count += 1;
    try std.testing.expectError(error.InvalidEdge, verify(&plan, .function));
    plan.graph.edge_states[0] = state;
    const block = plan.blocks[0];
    plan.blocks[0].successor_count = 3;
    try std.testing.expectError(error.InvalidBlock, verify(&plan, .function));
    plan.blocks[0] = block;
    const branch = plan.graph.branches[0];
    plan.graph.branches[0].true_block = 0;
    try std.testing.expectError(error.InvalidEdge, verify(&plan, .function));
    plan.graph.branches[0] = branch;
    try verify(&plan, .function);
}

test "optimizer verifier rejects absent pre-effect recovery" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var chunk = bc.Chunk.init(arena.allocator());
    chunk.param_count = 1;
    chunk.local_count = 1;
    const name = try chunk.addName("value");
    _ = try chunk.emit(.load_local, 0);
    _ = try chunk.emit(.get_prop, name);
    _ = try chunk.emit(.ret, 0);
    var plan = try ir.build(&chunk, std.testing.allocator);
    defer plan.deinit();
    const states = plan.graph.frame_states;
    const filtered = try std.testing.allocator.alloc(ir.FrameState, states.len - 1);
    defer std.testing.allocator.free(filtered);
    var index: usize = 0;
    for (states) |state| {
        if (state.kind == .effect) continue;
        filtered[index] = state;
        index += 1;
    }
    try std.testing.expectEqual(filtered.len, index);
    plan.graph.frame_states = filtered;
    defer plan.graph.frame_states = states;
    try std.testing.expectError(error.InvalidEffect, verify(&plan, .function));
}

test "optimizer verifier rejects exceptional edges without a throwing source" {
    var plan = try diamond(std.testing.allocator);
    defer plan.deinit();
    const original_edges = plan.graph.edges;
    const original_states = plan.graph.edge_states;
    const edges = try std.testing.allocator.alloc(ir.Edge, original_edges.len + 1);
    defer std.testing.allocator.free(edges);
    const states = try std.testing.allocator.alloc(ir.EdgeState, original_states.len + 1);
    defer std.testing.allocator.free(states);
    @memcpy(edges[0..original_edges.len], original_edges);
    @memcpy(states[0..original_states.len], original_states);
    const extra = edges.len - 1;
    edges[extra] = original_edges[2];
    edges[extra].from = 1;
    edges[extra].kind = .catch_;
    states[extra] = original_states[2];
    states[extra].from = 1;
    plan.graph.edges = edges;
    plan.graph.edge_states = states;
    defer plan.graph.edges = original_edges;
    defer plan.graph.edge_states = original_states;
    try std.testing.expectError(error.InvalidEdge, verify(&plan, .function));
}

test "optimizer verifier rejects missing effects and unsafe recovery maps" {
    var plan = try caughtCall(std.testing.allocator);
    defer plan.deinit();
    try verify(&plan, .function);
    const call = nodeOf(&plan, .call);
    const effect = effectOf(&plan);
    const original_node = plan.graph.nodes[call];
    plan.graph.nodes[call].may_have_effect = false;
    try std.testing.expectError(error.InvalidEffect, verify(&plan, .function));
    plan.graph.nodes[call] = original_node;
    const original_state = plan.graph.frame_states[effect];
    plan.graph.frame_states[effect].kind = .branch;
    try std.testing.expectError(error.InvalidFrameState, verify(&plan, .function));
    plan.graph.frame_states[effect] = original_state;
    plan.graph.frame_states[effect].first_value = @intCast(plan.graph.frame_state_values.len + 1);
    try std.testing.expectError(error.InvalidFrameState, verify(&plan, .function));
    plan.graph.frame_states[effect] = original_state;
    const map_slot = original_state.first_value;
    const original_value = plan.graph.frame_state_values[map_slot];
    plan.graph.frame_state_values[map_slot] = @intCast(call);
    try std.testing.expectError(error.InvalidSSA, verify(&plan, .function));
    plan.graph.frame_state_values[map_slot] = original_value;
    const target = plan.graph.exceptional_targets[0];
    const targets = plan.graph.exceptional_targets;
    plan.graph.exceptional_targets = targets[0..0];
    try std.testing.expectError(error.InvalidExceptionalTarget, verify(&plan, .function));
    plan.graph.exceptional_targets = targets;
    plan.graph.exceptional_targets[0].target_stack_depth += 1;
    try std.testing.expectError(error.InvalidExceptionalTarget, verify(&plan, .function));
    plan.graph.exceptional_targets[0] = target;
    const handler = plan.graph.handler_states[original_state.first_handler];
    plan.graph.handler_states[original_state.first_handler].catch_ip = none;
    plan.graph.handler_states[original_state.first_handler].finally_ip = none;
    try std.testing.expectError(error.InvalidHandler, verify(&plan, .function));
    plan.graph.handler_states[original_state.first_handler] = handler;
    try verify(&plan, .function);
}

test "optimizer verifier accepts dominating cross-block values and interpreter eval recovery" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var chunk = bc.Chunk.init(arena.allocator());
    chunk.param_count = 1;
    chunk.local_count = 1;
    const one = try chunk.addConst(RuntimeValue.num(1));
    _ = try chunk.emit(.load_local, 0);
    _ = try chunk.emit(.load_const, one);
    _ = try chunk.emit(.add, 0);
    _ = try chunk.emit(.store_local, 0);
    _ = try chunk.emit(.pop, 0);
    _ = try chunk.emit(.load_local, 0);
    _ = try chunk.emit(.jump_if_false, 11);
    _ = try chunk.emit(.load_local, 0);
    _ = try chunk.emit(.load_const, one);
    _ = try chunk.emit(.sub, 0);
    _ = try chunk.emit(.ret, 0);
    _ = try chunk.emit(.load_local, 0);
    _ = try chunk.emit(.ret, 0);
    var plan = try ir.build(&chunk, std.testing.allocator);
    defer plan.deinit();
    plan.graph.nodes[nodeOf(&plan, .sub)].lhs = @intCast(nodeOf(&plan, .add));
    try verify(&plan, .function);

    var eval_chunk = bc.Chunk.init(arena.allocator());
    eval_chunk.param_count = 1;
    eval_chunk.local_count = 1;
    _ = try eval_chunk.emit(.load_local, 0);
    _ = try eval_chunk.emit(.load_undefined, 0);
    _ = try eval_chunk.emit(.call_eval_with_this, 0);
    _ = try eval_chunk.emit(.ret, 0);
    var eval_plan = try ir.build(&eval_chunk, std.testing.allocator);
    defer eval_plan.deinit();
    try verify(&eval_plan, .function);
}

test "optimizer verifier preserves effect order within a block" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var chunk = bc.Chunk.init(arena.allocator());
    chunk.param_count = 1;
    chunk.local_count = 1;
    const a = try chunk.addName("a");
    const b = a;
    _ = try chunk.emit(.load_local, 0);
    _ = try chunk.emit(.get_prop, a);
    _ = try chunk.emit(.pop, 0);
    _ = try chunk.emit(.load_local, 0);
    _ = try chunk.emit(.get_prop, b);
    _ = try chunk.emit(.ret, 0);
    var plan = try ir.build(&chunk, std.testing.allocator);
    defer plan.deinit();
    var ids: [2]usize = undefined;
    var count: usize = 0;
    for (plan.graph.nodes, 0..) |node, index| if (node.kind == .get_prop) {
        ids[count] = index;
        count += 1;
    };
    try std.testing.expectEqual(@as(usize, 2), count);
    std.mem.swap(u32, &plan.graph.nodes[ids[0]].origin, &plan.graph.nodes[ids[1]].origin);
    try std.testing.expectError(error.InvalidEffect, verify(&plan, .function));
}

test "optimizer verifier allocation failures free graph and linear scratch" {
    const Probe = struct {
        fn run(allocator: std.mem.Allocator) !void {
            var plan = try caughtCall(allocator);
            defer plan.deinit();
            try verify(&plan, .function);
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Probe.run, .{});
}

test "optimizer verifier bounds scratch allocation on deep CFG chains" {
    const Counted = struct {
        requested: usize = 0,
        fn alloc(raw: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.requested += len;
            return std.testing.allocator.rawAlloc(len, alignment, ret_addr);
        }
        fn resize(raw: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
            const self: *@This() = @ptrCast(@alignCast(raw));
            const result = std.testing.allocator.rawResize(memory, alignment, new_len, ret_addr);
            if (result and new_len > memory.len) self.requested += new_len - memory.len;
            return result;
        }
        fn remap(raw: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
            const self: *@This() = @ptrCast(@alignCast(raw));
            const result = std.testing.allocator.rawRemap(memory, alignment, new_len, ret_addr);
            if (result != null and new_len > memory.len) self.requested += new_len - memory.len;
            return result;
        }
        fn free(_: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
            std.testing.allocator.rawFree(memory, alignment, ret_addr);
        }
        fn allocator(self: *@This()) std.mem.Allocator {
            return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free } };
        }
    };
    var prior: usize = 0;
    for ([_]usize{ 1024, 2048, 4096 }) |count| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var chunk = bc.Chunk.init(arena.allocator());
        chunk.param_count = 1;
        chunk.local_count = 1;
        for (0..count - 1) |index| _ = try chunk.emit(.jump, @intCast(index + 1));
        _ = try chunk.emit(.load_local, 0);
        _ = try chunk.emit(.ret, 0);
        var plan = try ir.build(&chunk, std.testing.allocator);
        defer plan.deinit();
        var tracked = Counted{};
        const previous = plan.allocator;
        plan.allocator = tracked.allocator();
        defer plan.allocator = previous;
        try verify(&plan, .function);
        try std.testing.expect(tracked.requested <= count * 512);
        std.debug.print("optimizer verifier CFG {d}: {d} requested scratch bytes\n", .{ count, tracked.requested });
        if (prior != 0) try std.testing.expect(tracked.requested <= prior * 22 / 10);
        prior = tracked.requested;
    }
}

test "optimizer verifier rejects changed iterator completion recovery values" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var chunk = bc.Chunk.init(arena.allocator());
    chunk.param_count = 3;
    chunk.local_count = 3;
    for (0..3) |slot| _ = try chunk.emit(.load_local, @intCast(slot));
    _ = try chunk.emit(.iter_close_completion, 0);
    _ = try chunk.emit(.pop, 0);
    _ = try chunk.emit(.ret, 0);
    var plan = try ir.build(&chunk, std.testing.allocator);
    defer plan.deinit();
    var found = false;
    for (plan.graph.frame_states) |state| if (state.kind == .continuation and state.origin == 4) {
        const first = state.first_value + state.local_count;
        const saved = plan.graph.frame_state_values[first + 1];
        plan.graph.frame_state_values[first + 1] = plan.graph.frame_state_values[first];
        try std.testing.expectError(error.InvalidFrameState, plan.verify(.function));
        plan.graph.frame_state_values[first + 1] = saved;
        try plan.verify(.function);
        found = true;
    };
    try std.testing.expect(found);
}
