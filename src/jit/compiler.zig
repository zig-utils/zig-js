//! Architecture-neutral bytecode selection for the baseline native tier.
//!
//! The supported set begins deliberately small. A chunk is accepted only when
//! every instruction has a native implementation; otherwise the VM caches the
//! rejection and interprets it normally.

const std = @import("std");
const builtin = @import("builtin");

const bc = @import("../bytecode.zig");
const jit = @import("../jit.zig");
const aarch64 = @import("aarch64.zig");
const value = @import("../value.zig");

const Chunk = bc.Chunk;
const Value = value.Value;

pub fn compile(chunk: *const Chunk) !jit.CompiledCode {
    if (constantResult(chunk)) |selection| {
        var compiled = try jit.compileConstantEntry(selection.bits);
        compiled.bytecode_steps = selection.steps;
        return compiled;
    }
    return compileNumeric(chunk);
}

const ConstantSelection = struct { bits: u64, steps: u32 };

fn constantResult(chunk: *const Chunk) ?ConstantSelection {
    const code = chunk.code.items;
    if ((code.len == 2 or (code.len == 3 and code[2].op == .ret_undef)) and code[0].op == .load_const and code[1].op == .ret) {
        if (code[0].a >= chunk.consts.items.len) return null;
        const result = chunk.consts.items[code[0].a];
        // Generated code may not embed a movable GC pointer. Primitive words
        // are immutable and self-contained; strings/objects come later through
        // a rooted constant table in NativeFrame.
        if (result.isObject() or result.isString()) return null;
        return .{ .bits = result.rawBits(), .steps = 2 };
    }
    if (code.len == 3 and code[0].op == .load_const and code[1].op == .set_acc and code[2].op == .halt) {
        if (code[0].a >= chunk.consts.items.len) return null;
        const result = chunk.consts.items[code[0].a];
        if (result.isObject() or result.isString()) return null;
        return .{ .bits = result.rawBits(), .steps = 3 };
    }
    return null;
}

const max_slots = 64;
const max_code_len = 4096;
const numeric_register_capacity = 8;
const unreachable_offset = std.math.maxInt(usize);

const Kind = enum(u8) { undefined, null, boolean, number };

const State = struct {
    locals: [max_slots]Kind = @splat(.undefined),
    stack: [jit.numeric_scratch_capacity]Kind = @splat(.undefined),
    depth: u8 = 0,

    fn push(self: *State, kind: Kind) error{UnsupportedChunk}!void {
        if (self.depth == jit.numeric_scratch_capacity) return error.UnsupportedChunk;
        self.stack[self.depth] = kind;
        self.depth += 1;
    }

    fn pop(self: *State) error{UnsupportedChunk}!Kind {
        if (self.depth == 0) return error.UnsupportedChunk;
        self.depth -= 1;
        const kind = self.stack[self.depth];
        self.stack[self.depth] = .undefined;
        return kind;
    }
};

const Analysis = struct {
    states: []?State,
    max_stack_depth: u8,
    allocator: std.mem.Allocator,

    fn deinit(self: *Analysis) void {
        self.allocator.free(self.states);
        self.* = undefined;
    }
};

fn classify(v: Value) ?Kind {
    return switch (v.kind()) {
        .undefined => .undefined,
        .null => .null,
        .boolean => .boolean,
        .number => .number,
        .string, .object => null,
    };
}

fn enqueueState(
    states: []?State,
    worklist: *std.ArrayListUnmanaged(u32),
    allocator: std.mem.Allocator,
    target: u32,
    state: State,
) !void {
    if (target >= states.len) return error.UnsupportedChunk;
    if (states[target]) |existing| {
        if (!std.meta.eql(existing, state)) return error.UnsupportedChunk;
        return;
    }
    states[target] = state;
    try worklist.append(allocator, target);
}

fn analyzeNumeric(chunk: *const Chunk) !Analysis {
    if (chunk.code.items.len == 0 or chunk.code.items.len > max_code_len) return error.UnsupportedChunk;
    if (chunk.local_count > max_slots or chunk.param_count > chunk.local_count) return error.UnsupportedChunk;

    const allocator = std.heap.page_allocator;
    const states = try allocator.alloc(?State, chunk.code.items.len);
    errdefer allocator.free(states);
    @memset(states, null);

    var initial = State{};
    for (0..chunk.param_count) |slot| initial.locals[slot] = .number;
    states[0] = initial;

    var worklist: std.ArrayListUnmanaged(u32) = .empty;
    defer worklist.deinit(allocator);
    try worklist.append(allocator, 0);
    var max_stack_depth: u8 = 0;
    var saw_return = false;

    while (worklist.pop()) |ip_u32| {
        const ip: usize = ip_u32;
        const inst = chunk.code.items[ip];
        var state = states[ip].?;
        var fallthrough = true;

        switch (inst.op) {
            .load_const => {
                if (inst.a >= chunk.consts.items.len) return error.UnsupportedChunk;
                try state.push(classify(chunk.consts.items[inst.a]) orelse return error.UnsupportedChunk);
            },
            .load_undefined => try state.push(.undefined),
            .load_null => try state.push(.null),
            .load_true, .load_false => try state.push(.boolean),
            .pop => _ = try state.pop(),
            .load_local => {
                if (inst.a >= chunk.local_count) return error.UnsupportedChunk;
                try state.push(state.locals[inst.a]);
            },
            .store_local => {
                if (inst.a >= chunk.local_count or state.depth == 0) return error.UnsupportedChunk;
                state.locals[inst.a] = state.stack[state.depth - 1];
            },
            .add, .sub, .mul, .div, .mod => {
                if (try state.pop() != .number or try state.pop() != .number) return error.UnsupportedChunk;
                try state.push(.number);
            },
            .lt, .le, .gt, .ge, .eq, .neq, .eq_strict, .neq_strict => {
                if (try state.pop() != .number or try state.pop() != .number) return error.UnsupportedChunk;
                try state.push(.boolean);
            },
            .jump => {
                try enqueueState(states, &worklist, allocator, inst.a, state);
                fallthrough = false;
            },
            .jump_if_false => {
                if (try state.pop() != .boolean) return error.UnsupportedChunk;
                try enqueueState(states, &worklist, allocator, inst.a, state);
            },
            .ret => {
                _ = try state.pop();
                if (state.depth != 0) return error.UnsupportedChunk;
                saw_return = true;
                fallthrough = false;
            },
            .ret_undef => {
                if (state.depth != 0) return error.UnsupportedChunk;
                saw_return = true;
                fallthrough = false;
            },
            else => return error.UnsupportedChunk,
        }

        max_stack_depth = @max(max_stack_depth, state.depth);
        if (fallthrough) {
            const next = std.math.cast(u32, ip + 1) orelse return error.UnsupportedChunk;
            try enqueueState(states, &worklist, allocator, next, state);
        }
    }

    if (!saw_return) return error.UnsupportedChunk;
    return .{ .states = states, .max_stack_depth = max_stack_depth, .allocator = allocator };
}

const ControlFixup = union(enum) {
    branch: struct { at: usize, target: u32 },
    test_zero: struct { at: usize, target: u32 },
};

fn slotOffset(index: usize) error{UnsupportedChunk}!u15 {
    return std.math.cast(u15, index * @sizeOf(u64)) orelse error.UnsupportedChunk;
}

fn frameOffset(comptime field: []const u8) u15 {
    return @intCast(@offsetOf(jit.NativeFrame, field));
}

fn numericRegister(stack_slot: usize) error{UnsupportedChunk}!u5 {
    if (stack_slot >= numeric_register_capacity) return error.UnsupportedChunk;
    return @intCast(8 + stack_slot);
}

fn emitRestoreAndReturn(assembler: *aarch64.Assembler) !void {
    try assembler.popFloatPair64(14, 15);
    try assembler.popFloatPair64(12, 13);
    try assembler.popFloatPair64(10, 11);
    try assembler.popFloatPair64(8, 9);
    try assembler.popPair(25, 26);
    try assembler.popPair(23, 24);
    try assembler.popPair(21, 22);
    try assembler.popPair(19, 20);
    try assembler.popPair(29, 30);
    try assembler.ret();
}

fn emitCompletedExit(assembler: *aarch64.Assembler, result_register: u5) !void {
    try assembler.load64(10, 21, frameOffset("steps"));
    try assembler.store64(19, 10, 0);
    try assembler.store64(result_register, 21, frameOffset("result_bits"));
    try assembler.movImmediate32(0, @intFromEnum(jit.ExitStatus.complete));
    try emitRestoreAndReturn(assembler);
}

fn emitCanonicalNumber(assembler: *aarch64.Assembler, register: u5, float_register: u5) !void {
    try assembler.moveRegisterFromFloat64(register, float_register);
    try assembler.compareFloat64(float_register, float_register);
    const ordered = try assembler.branchConditionPlaceholder(.vc);
    try assembler.movImmediate64(register, Value.num(std.math.nan(f64)).rawBits());
    try assembler.patchConditionBranch(ordered, assembler.position());
}

fn comparisonCondition(op: bc.Op) aarch64.Condition {
    return switch (op) {
        .lt => .mi,
        .le => .ls,
        .gt => .gt,
        .ge => .ge,
        .eq, .eq_strict => .eq,
        .neq, .neq_strict => .ne,
        else => unreachable,
    };
}

fn compileNumeric(chunk: *const Chunk) !jit.CompiledCode {
    if (!jit.supported or builtin.cpu.arch != .aarch64) return error.UnsupportedTarget;

    var analysis = try analyzeNumeric(chunk);
    defer analysis.deinit();
    if (analysis.max_stack_depth > numeric_register_capacity) return error.UnsupportedChunk;
    const allocator = std.heap.page_allocator;
    const code_len = chunk.code.items.len;

    const estimated = std.math.mul(usize, code_len, 192) catch return error.UnsupportedChunk;
    var memory = try jit.CodeMemory.init(estimated + 4096);
    errdefer memory.deinit();
    var assembler = aarch64.Assembler.init(memory.writableBytes());

    const bytecode_offsets = try allocator.alloc(usize, code_len);
    defer allocator.free(bytecode_offsets);
    const operation_offsets = try allocator.alloc(usize, code_len);
    defer allocator.free(operation_offsets);
    const budget_fixups = try allocator.alloc(usize, code_len);
    defer allocator.free(budget_fixups);
    const checkpoint_fixups = try allocator.alloc(usize, code_len);
    defer allocator.free(checkpoint_fixups);
    const control_fixups = try allocator.alloc(?ControlFixup, code_len);
    defer allocator.free(control_fixups);
    const status_fixups = try allocator.alloc(usize, code_len);
    defer allocator.free(status_fixups);
    @memset(bytecode_offsets, unreachable_offset);
    @memset(operation_offsets, unreachable_offset);
    @memset(budget_fixups, unreachable_offset);
    @memset(checkpoint_fixups, unreachable_offset);
    @memset(control_fixups, null);
    @memset(status_fixups, unreachable_offset);

    // Preserve every callee-saved register used by the generated entry. x21 is
    // the stable NativeFrame, x22 slots, x20 scratch, x19 exact steps, x24 the
    // checkpoint countdown, and x25 the remaining evaluation budget.
    try assembler.pushPair(29, 30);
    try assembler.pushPair(19, 20);
    try assembler.pushPair(21, 22);
    try assembler.pushPair(23, 24);
    try assembler.pushPair(25, 26);
    try assembler.pushFloatPair64(8, 9);
    try assembler.pushFloatPair64(10, 11);
    try assembler.pushFloatPair64(12, 13);
    try assembler.pushFloatPair64(14, 15);
    try assembler.moveRegister64(21, 0);
    try assembler.load64(22, 21, frameOffset("slots"));
    try assembler.load64(20, 21, frameOffset("scratch"));
    try assembler.load64(9, 21, frameOffset("steps"));
    try assembler.load64(19, 9, 0);
    try assembler.load64(24, 21, frameOffset("steps_until_checkpoint"));
    try assembler.load64(25, 21, frameOffset("steps_until_budget"));

    for (chunk.code.items, 0..) |inst, ip| {
        const state = analysis.states[ip] orelse continue;
        bytecode_offsets[ip] = assembler.position();

        try assembler.addImmediate64(19, 19, 1);
        try assembler.subtractImmediateSetFlags64(25, 25, 1);
        budget_fixups[ip] = try assembler.branchConditionPlaceholder(.lo);
        try assembler.subtractImmediateSetFlags64(24, 24, 1);
        checkpoint_fixups[ip] = try assembler.branchConditionPlaceholder(.eq);
        operation_offsets[ip] = assembler.position();

        switch (inst.op) {
            .load_const => {
                try assembler.movImmediate64(9, chunk.consts.items[inst.a].rawBits());
                if (classify(chunk.consts.items[inst.a]).? == .number)
                    try assembler.moveFloatFromRegister64(try numericRegister(state.depth), 9)
                else
                    try assembler.store64(9, 20, try slotOffset(state.depth));
            },
            .load_undefined => {
                try assembler.movImmediate64(9, Value.undef().rawBits());
                try assembler.store64(9, 20, try slotOffset(state.depth));
            },
            .load_null => {
                try assembler.movImmediate64(9, Value.nul().rawBits());
                try assembler.store64(9, 20, try slotOffset(state.depth));
            },
            .load_true, .load_false => {
                try assembler.movImmediate64(9, Value.boolVal(inst.op == .load_true).rawBits());
                try assembler.store64(9, 20, try slotOffset(state.depth));
            },
            .pop => {},
            .load_local => {
                try assembler.load64(9, 22, try slotOffset(inst.a));
                if (state.locals[inst.a] == .number)
                    try assembler.moveFloatFromRegister64(try numericRegister(state.depth), 9)
                else
                    try assembler.store64(9, 20, try slotOffset(state.depth));
            },
            .store_local => {
                if (state.stack[state.depth - 1] == .number)
                    try emitCanonicalNumber(&assembler, 9, try numericRegister(state.depth - 1))
                else
                    try assembler.load64(9, 20, try slotOffset(state.depth - 1));
                try assembler.store64(9, 22, try slotOffset(inst.a));
            },
            .add, .sub, .mul, .div, .mod => {
                const result_slot = state.depth - 2;
                const result_register = try numericRegister(result_slot);
                const rhs_register = try numericRegister(result_slot + 1);
                if (inst.op == .mod) {
                    // Match `numberRemainder`'s hot positive-u32 guard. Exact
                    // integral conversions stay entirely in generated code;
                    // negative, zero, fractional, infinite, and NaN operands
                    // take the full IEEE helper without changing VM semantics.
                    try assembler.convertFloat64ToUnsigned32(9, result_register);
                    try assembler.convertUnsigned32ToFloat64(2, 9);
                    try assembler.compareFloat64(result_register, 2);
                    const lhs_slow = try assembler.branchConditionPlaceholder(.ne);
                    const lhs_zero = try assembler.branchZero32Placeholder(9);
                    try assembler.convertFloat64ToUnsigned32(10, rhs_register);
                    try assembler.convertUnsigned32ToFloat64(2, 10);
                    try assembler.compareFloat64(rhs_register, 2);
                    const rhs_slow = try assembler.branchConditionPlaceholder(.ne);
                    const rhs_zero = try assembler.branchZero32Placeholder(10);
                    try assembler.divideUnsigned32(11, 9, 10);
                    try assembler.multiplySubtract32(9, 11, 10, 9);
                    try assembler.convertUnsigned32ToFloat64(result_register, 9);
                    const fast_done = try assembler.branchPlaceholder();
                    const slow = assembler.position();
                    try assembler.patchConditionBranch(lhs_slow, slow);
                    try assembler.patchCompareBranch(lhs_zero, slow);
                    try assembler.patchConditionBranch(rhs_slow, slow);
                    try assembler.patchCompareBranch(rhs_zero, slow);
                    try assembler.moveFloat64(0, result_register);
                    try assembler.moveFloat64(1, rhs_register);
                    try assembler.load64(16, 21, frameOffset("remainder"));
                    try assembler.branchLinkRegister(16);
                    try assembler.moveFloat64(result_register, 0);
                    try assembler.patchBranch(fast_done, assembler.position());
                } else {
                    const op: aarch64.FloatOp = switch (inst.op) {
                        .add => .add,
                        .sub => .sub,
                        .mul => .mul,
                        .div => .div,
                        else => unreachable,
                    };
                    try assembler.floatBinary64(op, result_register, result_register, rhs_register);
                }
            },
            .lt, .le, .gt, .ge, .eq, .neq, .eq_strict, .neq_strict => {
                const result_slot = state.depth - 2;
                try assembler.compareFloat64(try numericRegister(result_slot), try numericRegister(result_slot + 1));
                try assembler.conditionalSet32(9, comparisonCondition(inst.op));
                try assembler.movImmediate64(10, Value.boolVal(false).rawBits());
                try assembler.addRegister64(9, 10, 9);
                try assembler.store64(9, 20, try slotOffset(result_slot));
            },
            .jump => control_fixups[ip] = .{ .branch = .{ .at = try assembler.branchPlaceholder(), .target = inst.a } },
            .jump_if_false => {
                try assembler.load64(9, 20, try slotOffset(state.depth - 1));
                control_fixups[ip] = .{ .test_zero = .{ .at = try assembler.testBitZeroPlaceholder(9, 0), .target = inst.a } };
            },
            .ret => {
                if (state.stack[state.depth - 1] == .number)
                    try emitCanonicalNumber(&assembler, 9, try numericRegister(state.depth - 1))
                else
                    try assembler.load64(9, 20, try slotOffset(state.depth - 1));
                try emitCompletedExit(&assembler, 9);
            },
            .ret_undef => {
                try assembler.movImmediate64(9, Value.undef().rawBits());
                try emitCompletedExit(&assembler, 9);
            },
            else => unreachable,
        }
    }

    for (control_fixups) |fixup_opt| if (fixup_opt) |fixup| switch (fixup) {
        .branch => |branch| {
            if (branch.target >= code_len or bytecode_offsets[branch.target] == unreachable_offset) return error.UnsupportedChunk;
            try assembler.patchBranch(branch.at, bytecode_offsets[branch.target]);
        },
        .test_zero => |branch| {
            if (branch.target >= code_len or bytecode_offsets[branch.target] == unreachable_offset) return error.UnsupportedChunk;
            try assembler.patchTestBranch(branch.at, bytecode_offsets[branch.target]);
        },
    };

    // Each bytecode instruction has one cold checkpoint island. The hot path
    // pays only two countdown decrements and predicted-not-taken branches;
    // runtime work happens exactly before the instruction whose step reaches a
    // 1024 boundary (or exceeds the evaluation budget).
    for (chunk.code.items, 0..) |_, ip| {
        if (analysis.states[ip] == null) continue;
        const stub = assembler.position();
        try assembler.patchConditionBranch(budget_fixups[ip], stub);
        try assembler.patchConditionBranch(checkpoint_fixups[ip], stub);
        try assembler.load64(9, 21, frameOffset("steps"));
        try assembler.store64(19, 9, 0);
        try assembler.movImmediate64(9, ip);
        try assembler.store64(9, 21, frameOffset("exit_ip"));
        try assembler.moveRegister64(0, 21);
        try assembler.load64(16, 21, frameOffset("checkpoint"));
        try assembler.branchLinkRegister(16);
        status_fixups[ip] = try assembler.branchNotZero32Placeholder(0);
        try assembler.movImmediate32(24, 1024);
        const resume_branch = try assembler.branchPlaceholder();
        try assembler.patchBranch(resume_branch, operation_offsets[ip]);
    }

    const status_exit = assembler.position();
    try emitRestoreAndReturn(&assembler);
    for (status_fixups) |at| if (at != unreachable_offset) try assembler.patchCompareBranch(at, status_exit);

    try memory.publish(assembler.bytes().len);
    const entry: jit.NativeEntry = @ptrCast(@alignCast(memory.executableBytes().ptr));
    const required_numeric_slots: u64 = if (chunk.param_count == 64)
        std.math.maxInt(u64)
    else if (chunk.param_count == 0)
        0
    else
        (@as(u64, 1) << @intCast(chunk.param_count)) - 1;
    return .{
        .memory = memory,
        .entry = entry,
        .manages_steps = true,
        .frame_slots = chunk.local_count,
        .required_numeric_slots = required_numeric_slots,
        .max_stack_depth = analysis.max_stack_depth,
    };
}

test "compiler lowers a constant-return bytecode function" {
    const Parser = @import("../parser.zig").Parser;
    const Compiler = @import("../compiler.zig").Compiler;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var parser = try Parser.init(allocator, "function answer() { return 42; }");
    const program = try parser.parseProgram();
    const root = try Compiler.compileProgram(allocator, program);
    const function_chunk = root.fns.items[0].chunk.?;
    try std.testing.expectEqual(@as(u32, 0), function_chunk.param_count);
    try std.testing.expectEqual(@as(u32, 0), function_chunk.local_count);

    var compiled = try compile(function_chunk);
    defer compiled.deinit();
    var frame = jit.NativeFrame{};
    try std.testing.expectEqual(jit.ExitStatus.complete, compiled.run(&frame));
    try std.testing.expectEqual(@as(f64, 42), @import("../value.zig").Value.fromRawBits(frame.result_bits).asNum());
}

test "plain function chunks record native frame arity" {
    const Parser = @import("../parser.zig").Parser;
    const Compiler = @import("../compiler.zig").Compiler;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var parser = try Parser.init(allocator, "function sum(a, b) { var c = 0; return a + b + c; }");
    const program = try parser.parseProgram();
    const root = try Compiler.compileProgram(allocator, program);
    const function_chunk = root.fns.items[0].chunk.?;

    try std.testing.expectEqual(@as(u32, 2), function_chunk.param_count);
    try std.testing.expectEqual(@as(u32, 3), function_chunk.local_count);
}

test "compiler executes a numeric local loop across a checkpoint" {
    if (!jit.supported or builtin.cpu.arch != .aarch64) return error.SkipZigTest;
    const Parser = @import("../parser.zig").Parser;
    const Compiler = @import("../compiler.zig").Compiler;

    const Runtime = struct {
        fn checkpoint(frame: *jit.NativeFrame) callconv(.c) u32 {
            const calls: *u32 = @ptrCast(@alignCast(frame.runtime_context.?));
            calls.* += 1;
            return 0;
        }

        fn remainder(a: f64, b: f64) callconv(.c) f64 {
            return @rem(a, b);
        }
    };

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var parser = try Parser.init(allocator,
        \\function sum(n) {
        \\  var total = 0;
        \\  for (var i = 0; i < n; i = i + 1) total = total + i;
        \\  return total;
        \\}
    );
    const program = try parser.parseProgram();
    const root = try Compiler.compileProgram(allocator, program);
    const function_chunk = root.fns.items[0].chunk.?;
    var compiled = try compile(function_chunk);
    defer compiled.deinit();

    var slots = [_]u64{
        Value.num(10).rawBits(),
        Value.undef().rawBits(),
        Value.undef().rawBits(),
    };
    var scratch: [jit.numeric_scratch_capacity]u64 = undefined;
    var steps: u64 = 0;
    var checkpoint_calls: u32 = 0;
    var frame = jit.NativeFrame{
        .slots = &slots,
        .scratch = &scratch,
        .steps = &steps,
        .runtime_context = &checkpoint_calls,
        .checkpoint = Runtime.checkpoint,
        .remainder = Runtime.remainder,
        .steps_until_checkpoint = 1,
        .steps_until_budget = 1_000_000,
    };
    try std.testing.expectEqual(jit.ExitStatus.complete, compiled.run(&frame));
    try std.testing.expectEqual(@as(f64, 45), Value.fromRawBits(frame.result_bits).asNum());
    try std.testing.expectEqual(@as(u32, 1), checkpoint_calls);
    try std.testing.expect(steps > 100);
    try std.testing.expect(compiled.manages_steps);
    try std.testing.expectEqual(@as(u32, 3), compiled.frame_slots);
    try std.testing.expectEqual(@as(u64, 1), compiled.required_numeric_slots);
}
