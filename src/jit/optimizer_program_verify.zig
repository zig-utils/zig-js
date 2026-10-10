//! Native lowering metadata checks, independent of machine-code emission.
const std = @import("std");
const compiler = @import("optimizer_compiler.zig");
const jit = @import("../jit.zig");
const bc = @import("../bytecode.zig");
const Value = @import("../value.zig").Value;

pub const Error = error{
    InvalidDimensions,
    InvalidOperation,
    InvalidRecovery,
    InvalidStackMap,
    MissingRoot,
    InvalidDescriptor,
    InvalidHandler,
    InvalidControl,
    InvalidOsr,
};

fn range(first: usize, count: usize, length: usize) bool {
    return first <= length and count <= length - first;
}

fn mask(comptime T: type, count: usize) T {
    return if (count == @bitSizeOf(T)) std.math.maxInt(T) else (@as(T, 1) << @intCast(count)) - 1;
}

fn bit(comptime T: type, index: usize) T {
    return @as(T, 1) << @intCast(index);
}

fn slot(program: *const compiler.Program, index: usize) Error!void {
    if (index >= program.scratch_slots) return error.InvalidOperation;
}

fn valueSlot(program: *const compiler.Program, index: usize, locations: []const bool) Error!void {
    try slot(program, index);
    if (locations[index]) return error.InvalidOperation;
}

fn point(program: *const compiler.Program, index: usize) Error!void {
    if (index >= program.deopt_points.len) return error.InvalidControl;
}

fn primitiveConstant(bits: u64) bool {
    const value = Value.fromRawBits(bits);
    return !value.isObject() and !value.isString();
}

fn primitiveRuntimeResult(op: bc.Op) bool {
    return switch (op) {
        .not,
        .in_op,
        .instance_of,
        .private_in,
        .lt,
        .le,
        .gt,
        .ge,
        .eq,
        .neq,
        .eq_strict,
        .neq_strict,
        .pos,
        .ushr,
        => true,
        else => false,
    };
}

fn recovery(program: *const compiler.Program, value: jit.RecoveryValue, map: jit.StackMap, managed: []const bool, defined: []const bool, locations: []const bool) Error!void {
    switch (value.source) {
        .frame_slot => {
            if (program.canonical_locals) return error.InvalidRecovery;
            if (value.index >= program.frame_slots) return error.InvalidRecovery;
            if (map.frame_pointer_slots & bit(u64, value.index) == 0) return error.MissingRoot;
        },
        .scratch_slot => {
            if (value.index >= program.scratch_slots or !defined[value.index] or locations[value.index]) return error.InvalidRecovery;
            if (managed[value.index] and map.scratch_pointer_slots & bit(u128, value.index) == 0) return error.MissingRoot;
        },
        .constant => if (!primitiveConstant(value.bits)) return error.InvalidRecovery,
    }
}

/// Fixed-size slot analysis is bounded by the native ABI's 64/128-word limits.
/// Possible managed values propagate through copies; a numeric result/entry
/// guard is the only reason an otherwise unknown scratch word loses that duty.
pub fn verify(program: *const compiler.Program) Error!void {
    if (program.frame_slots > 64 or program.scratch_slots > jit.numeric_scratch_capacity or
        program.required_numeric_slots & ~mask(u64, program.frame_slots) != 0) return error.InvalidDimensions;
    if (program.stack_maps.len != program.deopt_points.len or program.deopt_points.len > 65536) return error.InvalidStackMap;
    const descriptor_count = program.native_operations.len;
    for ([_]usize{ program.native_operation_names.len, program.native_property_caches.len, program.native_call_sites.len, program.native_evaluation_sites.len }) |length|
        if (length != 0 and length != descriptor_count) return error.InvalidDescriptor;
    var managed: [jit.numeric_scratch_capacity]bool = @splat(false);
    var locations: [jit.numeric_scratch_capacity]bool = @splat(false);
    if (program.canonical_locals and program.required_numeric_slots != 0) return error.InvalidDimensions;
    var defined: [jit.numeric_scratch_capacity]bool = @splat(false);
    if (program.osr) |osr| {
        if (osr.entries.len == 0) return error.InvalidOsr;
        for (osr.entries) |entry| {
            const count: usize = @as(usize, entry.local_count) + entry.stack_count;
            if (entry.local_count != program.frame_slots or !range(entry.first_import, count, osr.imports.len) or
                !primitiveConstant(entry.accumulator_bits)) return error.InvalidOsr;
            var destinations: u128 = 0;
            for (osr.imports[entry.first_import .. entry.first_import + count]) |import| {
                if (import.destination >= program.scratch_slots or destinations & bit(u128, import.destination) != 0) return error.InvalidOsr;
                destinations |= bit(u128, import.destination);
                defined[import.destination] = true;
                switch (import.source) {
                    .frame_slot => {
                        if (program.canonical_locals) return error.InvalidOsr;
                        if (import.source_index >= entry.local_count) return error.InvalidOsr;
                        if (program.required_numeric_slots & bit(u64, import.source_index) == 0) managed[import.destination] = true;
                    },
                    .frame_location => {
                        if (!program.canonical_locals or import.source_index >= entry.local_count) return error.InvalidOsr;
                        locations[import.destination] = true;
                    },
                    .stack_slot => {
                        if (import.source_index >= entry.stack_count) return error.InvalidOsr;
                        managed[import.destination] = true;
                    },
                }
            }
        }
    }
    for (program.native_operations) |descriptor| {
        if (descriptor.deopt_index >= program.deopt_points.len or
            !range(descriptor.first_input, descriptor.input_count, program.scratch_slots) or
            (descriptor.exceptional_target != jit.NativeOperationDescriptor.none and descriptor.exceptional_target >= program.native_exceptional_targets.len))
            return error.InvalidDescriptor;
        const op = std.enums.fromInt(bc.Op, descriptor.bytecode_op) orelse return error.InvalidDescriptor;
        switch (op) {
            .make_closure, .load_local, .load_local_mapped, .load_local_lexical, .store_local, .store_local_mapped, .store_local_lexical, .init_local_lexical => if (!program.canonical_locals) return error.InvalidDescriptor,
            else => {},
        }
        const expected_inputs = optimizer.nativeOperationInputCount(.{ .op = op, .a = descriptor.operand_a, .b = descriptor.operand_b }) orelse return error.InvalidDescriptor;
        if (descriptor.input_count != expected_inputs) return error.InvalidDescriptor;
        const origin = program.deopt_points[descriptor.deopt_index];
        if (origin.exit_ip != descriptor.origin or (origin.kind != .effect and origin.kind != .call) or
            descriptor.step_delta > std.math.maxInt(u12)) return error.InvalidDescriptor;
        if (descriptor.continuation_deopt_index != jit.NativeOperationDescriptor.none) {
            if (descriptor.continuation_deopt_index >= program.deopt_points.len or descriptor.origin == std.math.maxInt(u32))
                return error.InvalidDescriptor;
            const next = program.deopt_points[descriptor.continuation_deopt_index];
            const expected_depth = optimizer.nativeOperationStackDepth(.{ .op = op, .a = descriptor.operand_a, .b = descriptor.operand_b }, origin.stack_count) orelse return error.InvalidDescriptor;
            if (next.kind != .continuation or next.exit_ip != descriptor.origin + 1 or next.local_count != origin.local_count or
                next.stack_count != expected_depth or next.handler_count != origin.handler_count or
                descriptor.block_prefix_steps > program.bytecode_steps or descriptor.continuation_steps > program.bytecode_steps - descriptor.block_prefix_steps)
                return error.InvalidDescriptor;
        }
        if (descriptor.flags & ~(jit.NativeOperationDescriptor.numeric_result | jit.NativeOperationDescriptor.literal_function_method |
            jit.NativeOperationDescriptor.literal_function_anonymous) != 0) return error.InvalidDescriptor;
        switch (op) {
            .load_upval, .load_upval_mapped, .load_upval_lexical => if (descriptor.input_count != 0) return error.InvalidDescriptor,
            .load_var_or_undef, .init_declarations, .copy_annex_b, .resolve_binding_ref, .load_binding_ref, .clear_binding_ref => if (descriptor.input_count != 0) return error.InvalidDescriptor,
            .store_var, .def_var, .def_lex, .store_binding_ref => if (descriptor.input_count != 1) return error.InvalidDescriptor,
            .store_upval, .store_upval_mapped, .store_upval_lexical => if (descriptor.input_count != 1) return error.InvalidDescriptor,
            else => {},
        }
        if ((op == .def_var and descriptor.operand_b > 3) or (op == .def_lex and descriptor.operand_b > 4) or
            (op == .load_binding_ref and descriptor.operand_b & ~(bc.binding_ref_load_retain | bc.binding_ref_load_with_base | bc.binding_ref_load_allow_unresolvable) != 0))
            return error.InvalidDescriptor;
        if ((op == .load_var or op == .load_this or op == .load_new_target) and descriptor.input_count != 0) return error.InvalidDescriptor;
    }
    for (program.operations, 0..) |operation, operation_index| {
        try slot(program, operation.destination);
        defined[operation.destination] = true;
        switch (operation.kind) {
            .frame_slot => {
                if (!program.canonical_locals or operation.immediate >= program.frame_slots) return error.InvalidOperation;
                locations[operation.destination] = true;
            },
            .argument => {
                if (program.canonical_locals) return error.InvalidOperation;
                if (operation.immediate >= program.frame_slots) return error.InvalidOperation;
                if (program.required_numeric_slots & bit(u64, operation.immediate) == 0) managed[operation.destination] = true;
            },
            .constant => if (!primitiveConstant(operation.immediate)) return error.InvalidOperation,
            .copy => try slot(program, operation.lhs),
            .branch_predicate => {
                try slot(program, operation.lhs);
                const op = std.enums.fromInt(bc.Op, (std.math.cast(u16, operation.immediate) orelse return error.InvalidOperation)) orelse return error.InvalidOperation;
                if (op != .jump_if_true_peek and op != .jump_if_false_peek and op != .jump_if_nullish_peek and op != .jump_if_not_nullish_peek) return error.InvalidOperation;
            },
            .runtime_base => {
                try slot(program, operation.lhs);
                if (!defined[operation.lhs]) return error.InvalidOperation;
                var producer = false;
                for (program.operations[0..operation_index]) |candidate| {
                    if (candidate.kind != .runtime_operation or candidate.destination != operation.lhs or candidate.origin != operation.origin) continue;
                    if (candidate.immediate >= program.native_operations.len) return error.InvalidOperation;
                    const descriptor = program.native_operations[candidate.immediate];
                    producer = descriptor.bytecode_op == @backingInt(bc.Op.load_binding_ref) and descriptor.operand_b & bc.binding_ref_load_with_base != 0;
                }
                if (!producer) return error.InvalidOperation;
                managed[operation.destination] = true;
            },
            .runtime_operation => {
                if (operation.immediate >= descriptor_count) return error.InvalidOperation;
                const descriptor = program.native_operations[operation.immediate];
                if (descriptor.first_input != operation.lhs or descriptor.step_delta == 0 or operation.origin == null or
                    operation.origin.? != descriptor.origin) return error.InvalidOperation;
                const op = std.enums.fromInt(bc.Op, descriptor.bytecode_op) orelse return error.InvalidDescriptor;
                if (descriptor.flags & jit.NativeOperationDescriptor.numeric_result == 0 and !primitiveRuntimeResult(op))
                    managed[operation.destination] = true;
            },
            else => {
                try slot(program, operation.lhs);
                try slot(program, operation.rhs);
            },
        }
    }
    var changed = true;
    while (changed) {
        changed = false;
        for (program.operations) |operation| {
            if (operation.kind == .copy and managed[operation.lhs] and !managed[operation.destination]) {
                managed[operation.destination] = true;
                changed = true;
            }
        }
    }
    changed = true;
    while (changed) {
        changed = false;
        for (program.operations) |operation| if (operation.kind == .copy and locations[operation.lhs] and !locations[operation.destination]) {
            locations[operation.destination] = true;
            changed = true;
        };
    }
    for (program.operations) |operation| switch (operation.kind) {
        .copy, .argument, .constant, .frame_slot => {},
        .runtime_operation => {
            const descriptor = program.native_operations[operation.immediate];
            for (descriptor.first_input..descriptor.first_input + descriptor.input_count) |input|
                if (locations[input]) return error.InvalidOperation;
        },
        .runtime_base, .branch_predicate => if (locations[operation.lhs]) return error.InvalidOperation,
        else => if (locations[operation.lhs] or locations[operation.rhs]) return error.InvalidOperation,
    };
    if (program.osr == null and program.side_exit == null and program.side_exit_branch == null and program.finally_dispatch == null and program.branch == null and
        (program.result >= program.scratch_slots or locations[program.result])) return error.InvalidOperation;
    for (program.deopt_handlers) |handler| {
        if (handler.catch_ip == jit.RecoveryHandler.none and handler.finally_ip == jit.RecoveryHandler.none) return error.InvalidHandler;
    }
    for (program.deopt_points, program.stack_maps, 0..) |entry, map, index| {
        const count: usize = @as(usize, entry.local_count) + entry.stack_count;
        if (entry.local_count != program.frame_slots or !range(entry.first_value, count, program.deopt_values.len) or
            !range(entry.first_handler, entry.handler_count, program.deopt_handlers.len)) return error.InvalidRecovery;
        if (map.deopt_index != index or map.frame_pointer_slots & ~mask(u64, program.frame_slots) != 0 or
            map.scratch_pointer_slots & ~mask(u128, program.scratch_slots) != 0) return error.InvalidStackMap;
        if (entry.preserve_locals != program.canonical_locals or (entry.preserve_locals and map.frame_pointer_slots != 0)) return error.InvalidRecovery;
        for (program.deopt_values[entry.first_value .. entry.first_value + count], 0..) |value, ordinal| {
            if (entry.preserve_locals and ordinal < entry.local_count) {
                if (value.source != .frame_slot or value.index != ordinal) return error.InvalidRecovery;
            } else try recovery(program, value, map, &managed, &defined, &locations);
        }
        try recovery(program, entry.accumulator, map, &managed, &defined, &locations);
    }
    for (program.native_operations) |descriptor| {
        if (descriptor.step_delta == 0) continue;
        const map = program.stack_maps[descriptor.deopt_index];
        for (descriptor.first_input..descriptor.first_input + descriptor.input_count) |input| {
            if (!defined[input] or map.scratch_pointer_slots & bit(u128, input) == 0) return error.MissingRoot;
        }
    }
    for (program.native_exceptional_targets) |target| {
        if (target.reserved != 0 or !range(target.first_handler, target.handler_count, program.deopt_handlers.len) or
            @as(u32, target.unwind_stack_depth) + (if (target.kind == .catch_) @as(u32, 1) else 2) != target.target_stack_depth)
            return error.InvalidHandler;
    }
    if (program.side_exit) |exit| try point(program, exit.deopt_index);
    if (program.side_exit_branch) |branch| {
        try valueSlot(program, branch.condition, &locations);
        if (branch.entry_deopt_index) |index| try point(program, index);
        try point(program, branch.false_deopt_index);
        try point(program, branch.true_deopt_index);
    }
    if (program.finally_dispatch) |dispatch| {
        try point(program, dispatch.deopt_index);
        try valueSlot(program, dispatch.completion_value, &locations);
        try valueSlot(program, dispatch.completion_kind, &locations);
    }
    if (program.branch) |branch| {
        try valueSlot(program, branch.condition, &locations);
        try valueSlot(program, branch.false_result, &locations);
        try valueSlot(program, branch.true_result, &locations);
        if (branch.merge_block) |merge| {
            if (branch.false_block == branch.true_block or merge == branch.false_block or merge == branch.true_block or
                merge == program.execution_block or branch.false_block == program.execution_block or branch.true_block == program.execution_block or
                branch.false_result != program.result or branch.true_result != program.result or
                program.bytecode_steps != @as(u32, branch.entry_steps) + @max(@as(u32, branch.false_steps), @as(u32, branch.true_steps)) + branch.merge_steps)
                return error.InvalidControl;
            for (program.operations) |operation| {
                if (operation.block != optimizer.Block.none and operation.block != program.execution_block and
                    operation.block != branch.false_block and operation.block != branch.true_block and operation.block != merge)
                    return error.InvalidControl;
            }
        }
    } else if (program.side_exit == null and program.side_exit_branch == null and program.finally_dispatch == null) try valueSlot(program, program.result, &locations);
    for (program.loop_exit_guards) |guard| {
        try valueSlot(program, guard.condition, &locations);
        try point(program, guard.exit_deopt_index);
    }
    for (program.loop_latch_guards) |guard| try valueSlot(program, guard.condition, &locations);
    for (program.loop_branches) |branch| try valueSlot(program, branch.condition, &locations);
    for (program.loop_region_blocks) |block| {
        if (block.successor_count > block.successors.len) return error.InvalidControl;
        if (block.successor_count > 1) try valueSlot(program, block.condition, &locations);
        try point(program, block.entry_deopt_index);
        for (block.successors[0..block.successor_count]) |target| {
            if (target.kind == .exit) try point(program, target.deopt_index);
            if (target.kind == .header and target.block != program.execution_block) return error.InvalidControl;
            if (target.kind == .block) {
                var found = false;
                for (program.loop_region_blocks) |candidate| if (candidate.block == target.block) {
                    found = true;
                    break;
                };
                if (!found) return error.InvalidControl;
            }
            if (target.moving_safepoint and target.kind == .exit) return error.InvalidControl;
            if (target.moving_safepoint) try point(program, target.safepoint_deopt_index);
        }
    }
    if (program.loop_region_blocks.len != 0 and program.osr == null) return error.InvalidControl;
}

fn boxedProgram(allocator: std.mem.Allocator, caught: bool) !compiler.Program {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var chunk = bc.Chunk.init(arena.allocator());
    chunk.param_count = 1;
    chunk.local_count = 1;
    const key = try chunk.addName("value");
    if (caught) _ = try chunk.emitAB(.push_handler, 6, std.math.maxInt(u32));
    _ = try chunk.emit(.load_local, 0);
    _ = try chunk.emit(.get_prop, key);
    _ = try chunk.emit(.ret, 0);
    if (caught) {
        _ = try chunk.emit(.ret_undef, 0);
        _ = try chunk.emit(.ret_undef, 0);
        _ = try chunk.emit(.ret, 0);
    }
    var plan = try optimizer.build(&chunk, allocator);
    defer plan.deinit();
    return compiler.lower(&chunk, &plan, allocator);
}

const optimizer = @import("optimizer.zig");

test "optimizer native metadata verifier rejects invalid dimensions recovery and callback spans" {
    var program = try boxedProgram(std.testing.allocator, false);
    defer program.deinit();
    try verify(&program);
    const frame_slots = program.frame_slots;
    program.frame_slots = 65;
    try std.testing.expectError(error.InvalidDimensions, verify(&program));
    program.frame_slots = frame_slots;
    const scratch_slots = program.scratch_slots;
    program.scratch_slots = 129;
    try std.testing.expectError(error.InvalidDimensions, verify(&program));
    program.scratch_slots = scratch_slots;
    const maps = program.stack_maps;
    program.stack_maps = maps[0 .. maps.len - 1];
    try std.testing.expectError(error.InvalidStackMap, verify(&program));
    program.stack_maps = maps;
    const original_point = program.deopt_points[0];
    program.deopt_points[0].first_value = @intCast(program.deopt_values.len + 1);
    try std.testing.expectError(error.InvalidRecovery, verify(&program));
    program.deopt_points[0] = original_point;
    const original_descriptor = program.native_operations[0];
    program.native_operations[0].first_input = scratch_slots;
    program.native_operations[0].input_count = 1;
    try std.testing.expectError(error.InvalidDescriptor, verify(&program));
    program.native_operations[0] = original_descriptor;
    const original_operation = program.operations[0];
    program.operations[0].destination = scratch_slots;
    try std.testing.expectError(error.InvalidOperation, verify(&program));
    program.operations[0] = original_operation;
    try verify(&program);
}

test "optimizer native metadata verifier roots boxed scratch recovery and callback inputs" {
    var program = try boxedProgram(std.testing.allocator, false);
    defer program.deinit();
    var scratch_point: ?usize = null;
    var scratch_index: u8 = 0;
    for (program.deopt_points, 0..) |entry, index| {
        if (entry.kind != .return_) continue;
        const count: usize = @as(usize, entry.local_count) + entry.stack_count;
        for (program.deopt_values[entry.first_value .. entry.first_value + count]) |value| {
            if (value.source != .scratch_slot) continue;
            scratch_point = index;
            scratch_index = value.index;
        }
    }
    const index = scratch_point orelse return error.TestUnexpectedResult;
    try std.testing.expect(program.stack_maps[index].scratch_pointer_slots & bit(u128, scratch_index) != 0);
    const map = program.stack_maps[index];
    program.stack_maps[index].scratch_pointer_slots &= ~bit(u128, scratch_index);
    try std.testing.expectError(error.MissingRoot, verify(&program));
    program.stack_maps[index] = map;
    const descriptor = program.native_operations[0];
    const input_map = program.stack_maps[descriptor.deopt_index];
    program.stack_maps[descriptor.deopt_index].scratch_pointer_slots &= ~bit(u128, descriptor.first_input);
    try std.testing.expectError(error.MissingRoot, verify(&program));
    program.stack_maps[descriptor.deopt_index] = input_map;
    const entry_map = program.stack_maps[0];
    program.stack_maps[0].frame_pointer_slots = 0;
    try std.testing.expectError(error.MissingRoot, verify(&program));
    program.stack_maps[0] = entry_map;
    try verify(&program);
}

test "optimizer native metadata verifier rejects unsafe constants and exceptional target shape" {
    var program = try boxedProgram(std.testing.allocator, true);
    defer program.deinit();
    try verify(&program);
    var object: @import("../value.zig").Object = .{};
    const saved = program.deopt_points[0].accumulator;
    program.deopt_points[0].accumulator = .{ .source = .constant, .bits = Value.obj(&object).rawBits() };
    try std.testing.expectError(error.InvalidRecovery, verify(&program));
    program.deopt_points[0].accumulator = saved;
    const target = program.native_exceptional_targets[0];
    program.native_exceptional_targets[0].target_stack_depth += 1;
    try std.testing.expectError(error.InvalidHandler, verify(&program));
    program.native_exceptional_targets[0] = target;
    const descriptor = program.native_operations[0];
    program.native_operations[0].deopt_index = @intCast(program.deopt_points.len);
    try std.testing.expectError(error.InvalidDescriptor, verify(&program));
    program.native_operations[0] = descriptor;
    try verify(&program);
}

test "optimizer native metadata verifier lowering allocation failures free owned tables" {
    const Probe = struct {
        fn run(allocator: std.mem.Allocator) !void {
            var program = try boxedProgram(allocator, false);
            defer program.deinit();
            try verify(&program);
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Probe.run, .{});
}

test "optimizer native metadata verifier rejects OSR imports and control references" {
    var program = try boxedProgram(std.testing.allocator, false);
    defer program.deinit();
    const metadata = try jit.OsrMetadata.create(std.testing.allocator, &.{.{
        .entry_ip = 0,
        .first_import = 0,
        .local_count = 1,
        .stack_count = 0,
        .accumulator_bits = Value.undef().rawBits(),
    }}, &.{.{ .source = .frame_slot, .source_index = 0, .destination = 0 }});
    program.osr = metadata;
    try verify(&program);
    const entry = metadata.entries[0];
    metadata.entries[0].first_import = 2;
    try std.testing.expectError(error.InvalidOsr, verify(&program));
    metadata.entries[0] = entry;
    const import = metadata.imports[0];
    metadata.imports[0].destination = program.scratch_slots;
    try std.testing.expectError(error.InvalidOsr, verify(&program));
    metadata.imports[0] = import;
    metadata.imports[0].source_index = 1;
    try std.testing.expectError(error.InvalidOsr, verify(&program));
    metadata.imports[0] = import;
    const exit = program.side_exit;
    program.side_exit = .{ .deopt_index = @intCast(program.deopt_points.len), .steps = 1 };
    try std.testing.expectError(error.InvalidControl, verify(&program));
    program.side_exit = exit;
    try verify(&program);
}

test "optimizer native metadata verifier validates completed effect continuations" {
    var program = try boxedProgram(std.testing.allocator, false);
    defer program.deinit();
    try verify(&program);
    const descriptor = program.native_operations[0];
    try std.testing.expect(descriptor.continuation_deopt_index != jit.NativeOperationDescriptor.none);
    program.native_operations[0].continuation_deopt_index = @intCast(program.deopt_points.len);
    try std.testing.expectError(error.InvalidDescriptor, verify(&program));
    program.native_operations[0] = descriptor;
    const index = descriptor.continuation_deopt_index;
    const original = program.deopt_points[index];
    program.deopt_points[index].exit_ip += 1;
    try std.testing.expectError(error.InvalidDescriptor, verify(&program));
    program.deopt_points[index] = original;
    program.deopt_points[index].stack_count -= 1;
    try std.testing.expectError(error.InvalidDescriptor, verify(&program));
    program.deopt_points[index] = original;
    program.native_operations[0].continuation_steps = program.bytecode_steps + 1;
    try std.testing.expectError(error.InvalidDescriptor, verify(&program));
    program.native_operations[0] = descriptor;
    try verify(&program);
}
