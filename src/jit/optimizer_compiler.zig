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
    lhs: u8 = 0,
    rhs: u8 = 0,
    immediate: u64 = 0,
};

pub const Program = struct {
    allocator: std.mem.Allocator,
    operations: []Operation,
    result: u8,
    scratch_slots: u8,
    frame_slots: u32,
    required_numeric_slots: u64,
    bytecode_steps: u32,

    pub fn deinit(self: *Program) void {
        self.allocator.free(self.operations);
        self.* = undefined;
    }
};

const ValueType = enum { number, boolean, other };

pub fn lower(chunk: *const bc.Chunk, plan: *const optimizer.Plan, allocator: std.mem.Allocator) !Program {
    const graph = &plan.graph;
    if (graph.returns.len != 1 or graph.returns[0].block != 0 or graph.edges.len != 1 or
        graph.edges[0].from != optimizer.Block.none or graph.edges[0].to != 0 or
        graph.nodes.len == 0 or graph.nodes.len > jit.numeric_scratch_capacity or chunk.local_count > 64)
        return error.UnsupportedChunk;

    var aliases: [jit.numeric_scratch_capacity]optimizer.ValueId = @splat(optimizer.ValueNode.none);
    var types: [jit.numeric_scratch_capacity]ValueType = @splat(.other);
    const entry = graph.edges[0];
    var entry_argument: usize = entry.first_argument;
    for (graph.nodes) |node| if (node.kind == .block_argument and node.block == 0) {
        if (entry_argument >= entry.first_argument + entry.argument_count) return error.UnsupportedChunk;
        aliases[node.id] = graph.edge_arguments[entry_argument];
        entry_argument += 1;
    };
    if (entry_argument != entry.first_argument + entry.argument_count) return error.UnsupportedChunk;

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
                .immediate = node.immediate,
            });
        },
        .constant => {
            const constant = Value.fromRawBits(node.immediate);
            types[node.id] = if (constant.isNumber()) .number else if (constant.isBoolean()) .boolean else .other;
            try operations.append(allocator, .{
                .kind = .constant,
                .destination = @intCast(node.id),
                .immediate = node.immediate,
            });
        },
        .undefined => {
            types[node.id] = .other;
            try operations.append(allocator, .{
                .kind = .constant,
                .destination = @intCast(node.id),
                .immediate = Value.undef().rawBits(),
            });
        },
        .null => {
            types[node.id] = .other;
            try operations.append(allocator, .{
                .kind = .constant,
                .destination = @intCast(node.id),
                .immediate = Value.nul().rawBits(),
            });
        },
        .true, .false => {
            types[node.id] = .boolean;
            try operations.append(allocator, .{
                .kind = .constant,
                .destination = @intCast(node.id),
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
                .lhs = @intCast(lhs),
                .rhs = @intCast(rhs),
            });
        },
        .mod => return error.UnsupportedChunk,
    };

    const result = try resolveAlias(graph.returns[0].value, aliases);
    return .{
        .allocator = allocator,
        .operations = try operations.toOwnedSlice(allocator),
        .result = @intCast(result),
        .scratch_slots = @intCast(graph.nodes.len),
        .frame_slots = chunk.local_count,
        .required_numeric_slots = required_numeric_slots,
        .bytecode_steps = graph.returns[0].origin + 1,
    };
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
    var program = try lower(chunk, &plan, std.heap.page_allocator);
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

    for (program.operations) |operation| switch (operation.kind) {
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
    };
    try assembler.load64(9, 14, try slotOffset(program.result));
    try assembler.store64(9, 12, frameOffset("result_bits"));
    try assembler.movImmediate32(0, @backingInt(jit.ExitStatus.complete));
    try assembler.ret();
    try memory.publish(assembler.bytes().len);

    return .{
        .memory = memory,
        .entry = @ptrCast(@alignCast(memory.executableBytes().ptr)),
        .kind = .optimizer,
        .bytecode_steps = program.bytecode_steps,
        .frame_slots = program.frame_slots,
        .required_numeric_slots = program.required_numeric_slots,
        .max_stack_depth = program.scratch_slots,
    };
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

test "optimizer compiler rejects control and remainder before publication" {
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
