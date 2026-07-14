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
const numeric_stack_register_capacity = 8;
const numeric_local_register_capacity = 8;
const unreachable_offset = std.math.maxInt(usize);

const Kind = enum(u8) { unknown, undefined, null, boolean, number };

/// Integer-valued expression provenance. This deliberately does not encode a
/// finite bound: lowering must also obtain a range proof before relying on a
/// fact, because repeated Number arithmetic can overflow to infinity.
const IntegerFact = enum(u8) { unknown, signed, nonnegative, positive };

const max_safe_integer: i64 = 9_007_199_254_740_991;

const IntegerRange = struct {
    min: i64,
    max: i64,

    const unknown: IntegerRange = .{ .min = 1, .max = 0 };

    fn isKnown(self: IntegerRange) bool {
        return self.min <= self.max;
    }
};

const RangeOperand = struct {
    integer: IntegerFact,
    range: IntegerRange,
    local: ?u8,
};

const Condition = struct {
    op: bc.Op,
    lhs: RangeOperand,
    rhs: RangeOperand,
};

const StackValue = struct {
    kind: Kind,
    integer: IntegerFact,
    range: IntegerRange,
    local: ?u8 = null,
    condition: ?Condition = null,
};

const State = struct {
    locals: [max_slots]Kind = @splat(.undefined),
    local_integers: [max_slots]IntegerFact = @splat(.unknown),
    local_ranges: [max_slots]IntegerRange = @splat(.unknown),
    stack: [jit.numeric_scratch_capacity]Kind = @splat(.undefined),
    stack_integers: [jit.numeric_scratch_capacity]IntegerFact = @splat(.unknown),
    stack_ranges: [jit.numeric_scratch_capacity]IntegerRange = @splat(.unknown),
    stack_locals: [jit.numeric_scratch_capacity]?u8 = @splat(null),
    stack_conditions: [jit.numeric_scratch_capacity]?Condition = @splat(null),
    depth: u8 = 0,

    fn push(self: *State, value_state: StackValue) error{UnsupportedChunk}!void {
        if (self.depth == jit.numeric_scratch_capacity) return error.UnsupportedChunk;
        self.stack[self.depth] = value_state.kind;
        self.stack_integers[self.depth] = value_state.integer;
        self.stack_ranges[self.depth] = value_state.range;
        self.stack_locals[self.depth] = value_state.local;
        self.stack_conditions[self.depth] = value_state.condition;
        self.depth += 1;
    }

    fn pop(self: *State) error{UnsupportedChunk}!StackValue {
        if (self.depth == 0) return error.UnsupportedChunk;
        self.depth -= 1;
        const kind = self.stack[self.depth];
        const integer = self.stack_integers[self.depth];
        const range = self.stack_ranges[self.depth];
        const local = self.stack_locals[self.depth];
        const condition = self.stack_conditions[self.depth];
        self.stack[self.depth] = .undefined;
        self.stack_integers[self.depth] = .unknown;
        self.stack_ranges[self.depth] = .unknown;
        self.stack_locals[self.depth] = null;
        self.stack_conditions[self.depth] = null;
        return .{ .kind = kind, .integer = integer, .range = range, .local = local, .condition = condition };
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

const Block = struct {
    start: u32,
    end: u32,

    fn instructionCount(self: Block) u12 {
        return @intCast(self.end - self.start);
    }
};

fn isBlockTerminator(op: bc.Op) bool {
    return switch (op) {
        .jump, .jump_if_false, .ret, .ret_undef => true,
        else => false,
    };
}

fn buildBlocks(chunk: *const Chunk, analysis: *const Analysis, allocator: std.mem.Allocator) ![]Block {
    const code = chunk.code.items;
    const starts = try allocator.alloc(bool, code.len);
    defer allocator.free(starts);
    @memset(starts, false);
    starts[0] = true;

    for (code, 0..) |inst, ip| {
        if (analysis.states[ip] == null) continue;
        switch (inst.op) {
            .jump => {
                if (inst.a >= code.len) return error.UnsupportedChunk;
                starts[inst.a] = true;
            },
            .jump_if_false => {
                if (inst.a >= code.len) return error.UnsupportedChunk;
                starts[inst.a] = true;
                if (ip + 1 < code.len) starts[ip + 1] = true;
            },
            else => {},
        }
    }

    var blocks: std.ArrayListUnmanaged(Block) = .empty;
    errdefer blocks.deinit(allocator);
    var ip: usize = 0;
    while (ip < code.len) {
        if (analysis.states[ip] == null) {
            ip += 1;
            continue;
        }
        if (!starts[ip]) return error.UnsupportedChunk;
        const start = ip;
        while (true) {
            const terminates = isBlockTerminator(code[ip].op);
            ip += 1;
            const reached_encoding_limit = ip - start == std.math.maxInt(u12);
            if (reached_encoding_limit and ip < code.len and analysis.states[ip] != null) starts[ip] = true;
            if (terminates or ip == code.len or analysis.states[ip] == null or starts[ip] or reached_encoding_limit) break;
        }
        try blocks.append(allocator, .{ .start = @intCast(start), .end = @intCast(ip) });
    }
    return blocks.toOwnedSlice(allocator);
}

fn buildCoveredSuccessors(
    chunk: *const Chunk,
    analysis: *const Analysis,
    blocks: []const Block,
    allocator: std.mem.Allocator,
) ![]bool {
    const block_at = try allocator.alloc(usize, chunk.code.items.len);
    defer allocator.free(block_at);
    @memset(block_at, unreachable_offset);
    for (blocks, 0..) |block, index| block_at[block.start] = index;

    const predecessors = try allocator.alloc(u32, blocks.len);
    defer allocator.free(predecessors);
    @memset(predecessors, 0);
    for (blocks) |block| {
        const last = chunk.code.items[block.end - 1];
        switch (last.op) {
            .jump => {
                if (last.a >= block_at.len or block_at[last.a] == unreachable_offset) return error.UnsupportedChunk;
                predecessors[block_at[last.a]] += 1;
            },
            .jump_if_false => {
                if (last.a >= block_at.len or block_at[last.a] == unreachable_offset) return error.UnsupportedChunk;
                predecessors[block_at[last.a]] += 1;
                if (block.end < block_at.len and analysis.states[block.end] != null) {
                    if (block_at[block.end] == unreachable_offset) return error.UnsupportedChunk;
                    predecessors[block_at[block.end]] += 1;
                }
            },
            .ret, .ret_undef => {},
            else => if (block.end < block_at.len and analysis.states[block.end] != null) {
                if (block_at[block.end] == unreachable_offset) return error.UnsupportedChunk;
                predecessors[block_at[block.end]] += 1;
            },
        }
    }

    const covered = try allocator.alloc(bool, blocks.len);
    @memset(covered, false);
    for (blocks[0 .. blocks.len - 1], 0..) |block, index| {
        if (covered[index] or chunk.code.items[block.end - 1].op != .jump_if_false) continue;
        const successor = blocks[index + 1];
        const combined = @as(u32, block.instructionCount()) + successor.instructionCount();
        if (block.end == successor.start and predecessors[index + 1] == 1 and combined <= std.math.maxInt(u12))
            covered[index + 1] = true;
    }
    return covered;
}

fn classify(v: Value) ?Kind {
    return switch (v.kind()) {
        .undefined => .undefined,
        .null => .null,
        .boolean => .boolean,
        .number => .number,
        .string, .object => null,
    };
}

fn classifyInteger(v: Value) IntegerFact {
    if (!v.isNumber()) return .unknown;
    const number = v.asNum();
    if (!std.math.isFinite(number) or @trunc(number) != number or (number == 0 and std.math.signbit(number))) return .unknown;
    if (number > 0) return .positive;
    if (number == 0) return .nonnegative;
    return .signed;
}

fn classifyIntegerRange(v: Value) IntegerRange {
    if (classifyInteger(v) == .unknown) return .unknown;
    const number = v.asNum();
    if (number < -@as(f64, @floatFromInt(max_safe_integer)) or number > @as(f64, @floatFromInt(max_safe_integer)))
        return .unknown;
    const integer: i64 = @intFromFloat(number);
    return .{ .min = integer, .max = integer };
}

fn joinIntegerFact(left: IntegerFact, right: IntegerFact) IntegerFact {
    if (left == right) return left;
    if (left == .unknown or right == .unknown) return .unknown;
    if (left == .signed or right == .signed) return .signed;
    return .nonnegative;
}

fn joinIntegerRange(left: IntegerRange, right: IntegerRange, widen: bool) IntegerRange {
    if (!left.isKnown() or !right.isKnown()) return .unknown;
    const joined: IntegerRange = .{ .min = @min(left.min, right.min), .max = @max(left.max, right.max) };
    if (widen and !std.meta.eql(left, joined)) return .unknown;
    return joined;
}

fn joinKind(left: Kind, right: Kind) Kind {
    if (left == right) return left;
    return .unknown;
}

fn joinCondition(left: ?Condition, right: ?Condition, widen_ranges: bool) ?Condition {
    const lhs = left orelse return null;
    const rhs = right orelse return null;
    if (lhs.op != rhs.op or
        !std.meta.eql(lhs.lhs.local, rhs.lhs.local) or
        !std.meta.eql(lhs.rhs.local, rhs.rhs.local))
        return null;
    return .{
        .op = lhs.op,
        .lhs = .{
            .integer = joinIntegerFact(lhs.lhs.integer, rhs.lhs.integer),
            .range = joinIntegerRange(lhs.lhs.range, rhs.lhs.range, widen_ranges),
            .local = lhs.lhs.local,
        },
        .rhs = .{
            .integer = joinIntegerFact(lhs.rhs.integer, rhs.rhs.integer),
            .range = joinIntegerRange(lhs.rhs.range, rhs.rhs.range, widen_ranges),
            .local = lhs.rhs.local,
        },
    };
}

fn mergeState(existing: *State, incoming: State, widen_ranges: bool) error{UnsupportedChunk}!bool {
    if (existing.depth != incoming.depth) return error.UnsupportedChunk;
    for (existing.stack[0..existing.depth], incoming.stack[0..incoming.depth]) |current, next|
        if (current != next) return error.UnsupportedChunk;

    var changed = false;
    for (&existing.locals, incoming.locals) |*current, next| {
        const merged = joinKind(current.*, next);
        if (merged != current.*) {
            current.* = merged;
            changed = true;
        }
    }
    for (&existing.local_integers, incoming.local_integers) |*current, next| {
        const merged = joinIntegerFact(current.*, next);
        if (merged != current.*) {
            current.* = merged;
            changed = true;
        }
    }
    for (&existing.local_ranges, incoming.local_ranges) |*current, next| {
        const merged = joinIntegerRange(current.*, next, widen_ranges);
        if (!std.meta.eql(merged, current.*)) {
            current.* = merged;
            changed = true;
        }
    }
    for (existing.stack_integers[0..existing.depth], incoming.stack_integers[0..incoming.depth]) |*current, next| {
        const merged = joinIntegerFact(current.*, next);
        if (merged != current.*) {
            current.* = merged;
            changed = true;
        }
    }
    for (existing.stack_ranges[0..existing.depth], incoming.stack_ranges[0..incoming.depth]) |*current, next| {
        const merged = joinIntegerRange(current.*, next, widen_ranges);
        if (!std.meta.eql(merged, current.*)) {
            current.* = merged;
            changed = true;
        }
    }
    for (existing.stack_locals[0..existing.depth], incoming.stack_locals[0..incoming.depth]) |*current, next| {
        if (!std.meta.eql(current.*, next) and current.* != null) {
            current.* = null;
            changed = true;
        }
    }
    for (existing.stack_conditions[0..existing.depth], incoming.stack_conditions[0..incoming.depth]) |*current, next| {
        const merged = joinCondition(current.*, next, widen_ranges);
        if (!std.meta.eql(current.*, merged)) {
            current.* = merged;
            changed = true;
        }
    }
    return changed;
}

fn arithmeticIntegerFact(op: bc.Op, lhs: IntegerFact, rhs: IntegerFact) IntegerFact {
    if (lhs == .unknown or rhs == .unknown) return .unknown;
    return switch (op) {
        .add, .mul => if (lhs == .signed or rhs == .signed) .signed else .nonnegative,
        .sub => .signed,
        .mod => if (rhs != .positive) .unknown else if (lhs == .signed) .signed else .nonnegative,
        .div => .unknown,
        else => unreachable,
    };
}

fn boundedIntegerRange(min: i128, max: i128) IntegerRange {
    if (min < -@as(i128, max_safe_integer) or max > max_safe_integer) return .unknown;
    return .{ .min = @intCast(min), .max = @intCast(max) };
}

fn arithmeticIntegerRange(op: bc.Op, lhs: StackValue, rhs: StackValue) IntegerRange {
    if (op == .mod and rhs.range.isKnown() and rhs.range.min > 0) {
        const remainder_bound = rhs.range.max - 1;
        if (lhs.integer == .nonnegative or lhs.integer == .positive) {
            const upper = if (lhs.range.isKnown()) @min(lhs.range.max, remainder_bound) else remainder_bound;
            return .{ .min = 0, .max = upper };
        }
        if (lhs.integer == .signed) {
            const lower = if (lhs.range.isKnown()) @max(lhs.range.min, -remainder_bound) else -remainder_bound;
            const upper = if (lhs.range.isKnown()) @min(lhs.range.max, remainder_bound) else remainder_bound;
            return .{ .min = lower, .max = upper };
        }
    }
    if (!lhs.range.isKnown() or !rhs.range.isKnown()) return .unknown;
    const lhs_min: i128 = lhs.range.min;
    const lhs_max: i128 = lhs.range.max;
    const rhs_min: i128 = rhs.range.min;
    const rhs_max: i128 = rhs.range.max;
    return switch (op) {
        .add => boundedIntegerRange(lhs_min + rhs_min, lhs_max + rhs_max),
        .sub => boundedIntegerRange(lhs_min - rhs_max, lhs_max - rhs_min),
        .mul => blk: {
            const products = [4]i128{
                lhs_min * rhs_min,
                lhs_min * rhs_max,
                lhs_max * rhs_min,
                lhs_max * rhs_max,
            };
            break :blk boundedIntegerRange(std.mem.min(i128, &products), std.mem.max(i128, &products));
        },
        .div, .mod => .unknown,
        else => unreachable,
    };
}

fn operandLowerBound(operand: RangeOperand) ?i64 {
    if (operand.range.isKnown()) return operand.range.min;
    return switch (operand.integer) {
        .positive => 1,
        .nonnegative => 0,
        .signed, .unknown => null,
    };
}

fn operandUpperBound(operand: RangeOperand) ?i64 {
    return if (operand.range.isKnown()) operand.range.max else null;
}

fn refineOperand(state: *State, operand: RangeOperand, minimum: ?i64, maximum: ?i64) void {
    const slot = operand.local orelse return;
    var lower = operandLowerBound(operand);
    var upper = operandUpperBound(operand);
    if (minimum) |bound| lower = if (lower) |current| @max(current, bound) else bound;
    if (maximum) |bound| upper = if (upper) |current| @min(current, bound) else bound;
    if (lower == null or upper == null or lower.? > upper.?) return;
    state.local_ranges[slot] = .{ .min = lower.?, .max = upper.? };
}

fn refineOrdered(state: *State, lhs: RangeOperand, rhs: RangeOperand, inclusive: bool) void {
    const delta: i64 = if (inclusive) 0 else 1;
    const lhs_max = if (operandUpperBound(rhs)) |bound| bound - delta else null;
    const rhs_min = if (operandLowerBound(lhs)) |bound| bound + delta else null;
    refineOperand(state, lhs, null, lhs_max);
    refineOperand(state, rhs, rhs_min, null);
}

fn refineEqual(state: *State, lhs: RangeOperand, rhs: RangeOperand) void {
    const minimum = if (operandLowerBound(lhs)) |lhs_min|
        if (operandLowerBound(rhs)) |rhs_min| @max(lhs_min, rhs_min) else lhs_min
    else
        operandLowerBound(rhs);
    const maximum = if (operandUpperBound(lhs)) |lhs_max|
        if (operandUpperBound(rhs)) |rhs_max| @min(lhs_max, rhs_max) else lhs_max
    else
        operandUpperBound(rhs);
    refineOperand(state, lhs, minimum, maximum);
    refineOperand(state, rhs, minimum, maximum);
}

fn refineComparison(state: *State, condition: Condition, truth: bool) void {
    if (condition.lhs.integer == .unknown or condition.rhs.integer == .unknown) return;
    switch (condition.op) {
        .lt => if (truth) refineOrdered(state, condition.lhs, condition.rhs, false) else refineOrdered(state, condition.rhs, condition.lhs, true),
        .le => if (truth) refineOrdered(state, condition.lhs, condition.rhs, true) else refineOrdered(state, condition.rhs, condition.lhs, false),
        .gt => if (truth) refineOrdered(state, condition.rhs, condition.lhs, false) else refineOrdered(state, condition.lhs, condition.rhs, true),
        .ge => if (truth) refineOrdered(state, condition.rhs, condition.lhs, true) else refineOrdered(state, condition.lhs, condition.rhs, false),
        .eq, .eq_strict => if (truth) refineEqual(state, condition.lhs, condition.rhs),
        .neq, .neq_strict => if (!truth) refineEqual(state, condition.lhs, condition.rhs),
        else => unreachable,
    }
}

fn enqueueState(
    states: []?State,
    worklist: *std.ArrayListUnmanaged(u32),
    allocator: std.mem.Allocator,
    target: u32,
    state: State,
    widen_ranges: bool,
) !void {
    if (target >= states.len) return error.UnsupportedChunk;
    if (states[target]) |existing_state| {
        var existing = existing_state;
        if (try mergeState(&existing, state, widen_ranges)) {
            states[target] = existing;
            try worklist.append(allocator, target);
        }
        return;
    }
    states[target] = state;
    try worklist.append(allocator, target);
}

fn analyzeNumeric(chunk: *const Chunk, integer_parameters: bool) !Analysis {
    if (chunk.code.items.len == 0 or chunk.code.items.len > max_code_len) return error.UnsupportedChunk;
    if (chunk.local_count > max_slots or chunk.param_count > chunk.local_count) return error.UnsupportedChunk;

    const allocator = std.heap.page_allocator;
    const states = try allocator.alloc(?State, chunk.code.items.len);
    errdefer allocator.free(states);
    @memset(states, null);

    var initial = State{};
    for (0..chunk.param_count) |slot| {
        initial.locals[slot] = .number;
        if (integer_parameters) {
            initial.local_integers[slot] = .nonnegative;
            initial.local_ranges[slot] = .{ .min = 0, .max = std.math.maxInt(u32) };
        }
    }
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
                const constant = chunk.consts.items[inst.a];
                try state.push(.{
                    .kind = classify(constant) orelse return error.UnsupportedChunk,
                    .integer = classifyInteger(constant),
                    .range = classifyIntegerRange(constant),
                });
            },
            .load_undefined => try state.push(.{ .kind = .undefined, .integer = .unknown, .range = .unknown }),
            .load_null => try state.push(.{ .kind = .null, .integer = .unknown, .range = .unknown }),
            .load_true, .load_false => try state.push(.{ .kind = .boolean, .integer = .unknown, .range = .unknown }),
            .pop => _ = try state.pop(),
            .load_local => {
                if (inst.a >= chunk.local_count) return error.UnsupportedChunk;
                // A local whose representation differs across predecessors is
                // safe only after an unconditional overwrite. Reconciliation
                // at a live mixed-kind merge is outside this numeric tier.
                if (state.locals[inst.a] == .unknown) return error.UnsupportedChunk;
                try state.push(.{
                    .kind = state.locals[inst.a],
                    .integer = state.local_integers[inst.a],
                    .range = state.local_ranges[inst.a],
                    .local = @intCast(inst.a),
                });
            },
            .store_local => {
                if (inst.a >= chunk.local_count or state.depth == 0) return error.UnsupportedChunk;
                state.locals[inst.a] = state.stack[state.depth - 1];
                state.local_integers[inst.a] = state.stack_integers[state.depth - 1];
                state.local_ranges[inst.a] = state.stack_ranges[state.depth - 1];
            },
            .add, .sub, .mul, .div, .mod => {
                const rhs = try state.pop();
                const lhs = try state.pop();
                if (rhs.kind != .number or lhs.kind != .number) return error.UnsupportedChunk;
                try state.push(.{
                    .kind = .number,
                    .integer = arithmeticIntegerFact(inst.op, lhs.integer, rhs.integer),
                    .range = arithmeticIntegerRange(inst.op, lhs, rhs),
                });
            },
            .lt, .le, .gt, .ge, .eq, .neq, .eq_strict, .neq_strict => {
                const rhs = try state.pop();
                const lhs = try state.pop();
                if (rhs.kind != .number or lhs.kind != .number) return error.UnsupportedChunk;
                try state.push(.{
                    .kind = .boolean,
                    .integer = .unknown,
                    .range = .unknown,
                    .condition = .{
                        .op = inst.op,
                        .lhs = .{ .integer = lhs.integer, .range = lhs.range, .local = lhs.local },
                        .rhs = .{ .integer = rhs.integer, .range = rhs.range, .local = rhs.local },
                    },
                });
            },
            .jump => {
                try enqueueState(states, &worklist, allocator, inst.a, state, inst.a <= ip);
                fallthrough = false;
            },
            .jump_if_false => {
                const condition_value = try state.pop();
                if (condition_value.kind != .boolean) return error.UnsupportedChunk;
                var false_state = state;
                if (condition_value.condition) |condition| {
                    refineComparison(&false_state, condition, false);
                    refineComparison(&state, condition, true);
                }
                try enqueueState(states, &worklist, allocator, inst.a, false_state, inst.a <= ip);
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
            try enqueueState(states, &worklist, allocator, next, state, false);
        }
    }

    if (!saw_return) return error.UnsupportedChunk;
    return .{ .states = states, .max_stack_depth = max_stack_depth, .allocator = allocator };
}

const ControlFixup = union(enum) {
    branch: struct { at: usize, target: u32 },
    condition: struct { at: usize, target: u32 },
    test_zero: struct { at: usize, target: u32 },
};

fn slotOffset(index: usize) error{UnsupportedChunk}!u15 {
    return std.math.cast(u15, index * @sizeOf(u64)) orelse error.UnsupportedChunk;
}

fn frameOffset(comptime field: []const u8) u15 {
    return @intCast(@offsetOf(jit.NativeFrame, field));
}

fn numericRegister(stack_slot: usize) error{UnsupportedChunk}!u5 {
    if (stack_slot >= numeric_stack_register_capacity) return error.UnsupportedChunk;
    return @intCast(16 + stack_slot);
}

fn numericLocalRegister(local_slot: usize) error{UnsupportedChunk}!u5 {
    if (local_slot >= numeric_local_register_capacity) return error.UnsupportedChunk;
    return @intCast(8 + local_slot);
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

fn isNumericComparison(op: bc.Op) bool {
    return switch (op) {
        .lt, .le, .gt, .ge, .eq, .neq, .eq_strict, .neq_strict => true,
        else => false,
    };
}

fn comparisonFalseCondition(op: bc.Op) aarch64.Condition {
    return switch (op) {
        .lt => .pl,
        .le => .hi,
        .gt => .le,
        .ge => .lt,
        .eq, .eq_strict => .ne,
        .neq, .neq_strict => .eq,
        else => unreachable,
    };
}

fn emitFusedComparisonBranch(
    assembler: *aarch64.Assembler,
    state: State,
    comparison: bc.Op,
    target: u32,
) !ControlFixup {
    const lhs_slot = state.depth - 2;
    try assembler.compareFloat64(try numericRegister(lhs_slot), try numericRegister(lhs_slot + 1));
    return .{ .condition = .{
        .at = try assembler.branchConditionPlaceholder(comparisonFalseCondition(comparison)),
        .target = target,
    } };
}

fn emitOperation(assembler: *aarch64.Assembler, chunk: *const Chunk, state: State, inst: bc.Inst) !?ControlFixup {
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
            if (state.locals[inst.a] == .number)
                try assembler.moveFloat64(try numericRegister(state.depth), try numericLocalRegister(inst.a))
            else {
                try assembler.load64(9, 22, try slotOffset(inst.a));
                try assembler.store64(9, 20, try slotOffset(state.depth));
            }
        },
        .store_local => {
            if (state.stack[state.depth - 1] == .number)
                try assembler.moveFloat64(try numericLocalRegister(inst.a), try numericRegister(state.depth - 1))
            else {
                try assembler.load64(9, 20, try slotOffset(state.depth - 1));
                try assembler.store64(9, 22, try slotOffset(inst.a));
            }
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
                // The semantic helper follows the C ABI and may clobber
                // caller-saved d16-d23. Preserve any outer numeric operands
                // that remain live below this binary expression.
                for (0..result_slot) |slot| if (state.stack[slot] == .number) {
                    try assembler.moveRegisterFromFloat64(9, try numericRegister(slot));
                    try assembler.store64(9, 20, try slotOffset(slot));
                };
                try assembler.moveFloat64(0, result_register);
                try assembler.moveFloat64(1, rhs_register);
                try assembler.load64(16, 21, frameOffset("remainder"));
                try assembler.branchLinkRegister(16);
                try assembler.moveFloat64(result_register, 0);
                for (0..result_slot) |slot| if (state.stack[slot] == .number) {
                    try assembler.load64(9, 20, try slotOffset(slot));
                    try assembler.moveFloatFromRegister64(try numericRegister(slot), 9);
                };
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
        .jump => return .{ .branch = .{ .at = try assembler.branchPlaceholder(), .target = inst.a } },
        .jump_if_false => {
            try assembler.load64(9, 20, try slotOffset(state.depth - 1));
            return .{ .test_zero = .{ .at = try assembler.testBitZeroPlaceholder(9, 0), .target = inst.a } };
        },
        .ret => {
            if (state.stack[state.depth - 1] == .number)
                try emitCanonicalNumber(assembler, 9, try numericRegister(state.depth - 1))
            else
                try assembler.load64(9, 20, try slotOffset(state.depth - 1));
            try emitCompletedExit(assembler, 9);
        },
        .ret_undef => {
            try assembler.movImmediate64(9, Value.undef().rawBits());
            try emitCompletedExit(assembler, 9);
        },
        else => unreachable,
    }
    return null;
}

fn patchControlFixups(
    assembler: *aarch64.Assembler,
    fixups: []const ?ControlFixup,
    bytecode_offsets: []const usize,
) !void {
    for (fixups) |fixup_opt| if (fixup_opt) |fixup| switch (fixup) {
        .branch => |branch| {
            if (branch.target >= bytecode_offsets.len or bytecode_offsets[branch.target] == unreachable_offset)
                return error.UnsupportedChunk;
            try assembler.patchBranch(branch.at, bytecode_offsets[branch.target]);
        },
        .condition => |branch| {
            if (branch.target >= bytecode_offsets.len or bytecode_offsets[branch.target] == unreachable_offset)
                return error.UnsupportedChunk;
            try assembler.patchConditionBranch(branch.at, bytecode_offsets[branch.target]);
        },
        .test_zero => |branch| {
            if (branch.target >= bytecode_offsets.len or bytecode_offsets[branch.target] == unreachable_offset)
                return error.UnsupportedChunk;
            try assembler.patchTestBranch(branch.at, bytecode_offsets[branch.target]);
        },
    };
}

fn patchControlToOffset(assembler: *aarch64.Assembler, fixup: ControlFixup, target: usize) !void {
    switch (fixup) {
        .branch => |branch| try assembler.patchBranch(branch.at, target),
        .condition => |branch| try assembler.patchConditionBranch(branch.at, target),
        .test_zero => |branch| try assembler.patchTestBranch(branch.at, target),
    }
}

fn compileNumeric(chunk: *const Chunk) !jit.CompiledCode {
    if (!jit.supported or builtin.cpu.arch != .aarch64) return error.UnsupportedTarget;

    var analysis = try analyzeNumeric(chunk, false);
    defer analysis.deinit();
    if (analysis.max_stack_depth > numeric_stack_register_capacity or chunk.local_count > numeric_local_register_capacity)
        return error.UnsupportedChunk;
    const allocator = std.heap.page_allocator;
    const code_len = chunk.code.items.len;
    const blocks = try buildBlocks(chunk, &analysis, allocator);
    defer allocator.free(blocks);
    const covered_successors = try buildCoveredSuccessors(chunk, &analysis, blocks, allocator);
    defer allocator.free(covered_successors);

    const estimated = std.math.mul(usize, code_len, 768) catch return error.UnsupportedChunk;
    var memory = try jit.CodeMemory.init(estimated + 4096);
    errdefer memory.deinit();
    var assembler = aarch64.Assembler.init(memory.writableBytes());

    const fast_offsets = try allocator.alloc(usize, code_len);
    defer allocator.free(fast_offsets);
    const hot_offsets = try allocator.alloc(usize, blocks.len);
    defer allocator.free(hot_offsets);
    const fast_budget_fixups = try allocator.alloc(usize, blocks.len);
    defer allocator.free(fast_budget_fixups);
    const fast_checkpoint_fixups = try allocator.alloc(usize, blocks.len);
    defer allocator.free(fast_checkpoint_fixups);
    const fast_control_fixups = try allocator.alloc(?ControlFixup, code_len);
    defer allocator.free(fast_control_fixups);
    const refund_fixups = try allocator.alloc(?ControlFixup, blocks.len);
    defer allocator.free(refund_fixups);
    const slow_offsets = try allocator.alloc(usize, blocks.len);
    defer allocator.free(slow_offsets);
    const slow_fallthrough_fixups = try allocator.alloc(usize, blocks.len);
    defer allocator.free(slow_fallthrough_fixups);
    const operation_offsets = try allocator.alloc(usize, code_len);
    defer allocator.free(operation_offsets);
    const budget_fixups = try allocator.alloc(usize, code_len);
    defer allocator.free(budget_fixups);
    const checkpoint_fixups = try allocator.alloc(usize, code_len);
    defer allocator.free(checkpoint_fixups);
    const slow_control_fixups = try allocator.alloc(?ControlFixup, code_len);
    defer allocator.free(slow_control_fixups);
    const status_fixups = try allocator.alloc(usize, code_len);
    defer allocator.free(status_fixups);
    @memset(fast_offsets, unreachable_offset);
    @memset(hot_offsets, unreachable_offset);
    @memset(fast_budget_fixups, unreachable_offset);
    @memset(fast_checkpoint_fixups, unreachable_offset);
    @memset(fast_control_fixups, null);
    @memset(refund_fixups, null);
    @memset(slow_offsets, unreachable_offset);
    @memset(slow_fallthrough_fixups, unreachable_offset);
    @memset(operation_offsets, unreachable_offset);
    @memset(budget_fixups, unreachable_offset);
    @memset(checkpoint_fixups, unreachable_offset);
    @memset(slow_control_fixups, null);
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
    for (0..chunk.param_count) |slot| {
        try assembler.load64(9, 22, try slotOffset(slot));
        try assembler.moveFloatFromRegister64(try numericLocalRegister(slot), 9);
    }

    // Normal execution accounts for an entire basic block at once. A block
    // enters the exact replay path when either the evaluation budget or the
    // next 1024-step safepoint falls within it, so observable boundaries keep
    // the interpreter's instruction-level semantics.
    for (blocks, 0..) |block, block_index| {
        if (!covered_successors[block_index]) {
            fast_offsets[block.start] = assembler.position();
            const instruction_count: u12 = if (block_index + 1 < blocks.len and covered_successors[block_index + 1])
                @intCast(@as(u32, block.instructionCount()) + blocks[block_index + 1].instructionCount())
            else
                block.instructionCount();
            try assembler.compareImmediate64(25, instruction_count);
            fast_budget_fixups[block_index] = try assembler.branchConditionPlaceholder(.lo);
            try assembler.compareImmediate64(24, instruction_count);
            fast_checkpoint_fixups[block_index] = try assembler.branchConditionPlaceholder(.ls);
            try assembler.subtractImmediate64(25, 25, instruction_count);
            try assembler.subtractImmediate64(24, 24, instruction_count);
            try assembler.addImmediate64(19, 19, instruction_count);
        }
        hot_offsets[block_index] = assembler.position();

        var ip: usize = block.start;
        while (ip < block.end) {
            const state = analysis.states[ip].?;
            const inst = chunk.code.items[ip];
            if (isNumericComparison(inst.op) and ip + 1 < block.end and chunk.code.items[ip + 1].op == .jump_if_false) {
                fast_control_fixups[ip + 1] = try emitFusedComparisonBranch(
                    &assembler,
                    state,
                    inst.op,
                    chunk.code.items[ip + 1].a,
                );
                ip += 2;
                continue;
            }
            fast_control_fixups[ip] = try emitOperation(&assembler, chunk, state, inst);
            ip += 1;
        }
        if (block_index + 1 < blocks.len and covered_successors[block_index + 1]) {
            const last_ip = block.end - 1;
            refund_fixups[block_index] = fast_control_fixups[last_ip] orelse return error.UnsupportedChunk;
            fast_control_fixups[last_ip] = null;
        }
    }

    // A covered successor is physically entered without another accounting
    // prefix only from its pre-accounting predecessor. Slow replay and explicit
    // transfers use this guarded entry, which then jumps back to the same body.
    for (blocks, 0..) |block, block_index| if (covered_successors[block_index]) {
        fast_offsets[block.start] = assembler.position();
        const instruction_count = block.instructionCount();
        try assembler.compareImmediate64(25, instruction_count);
        fast_budget_fixups[block_index] = try assembler.branchConditionPlaceholder(.lo);
        try assembler.compareImmediate64(24, instruction_count);
        fast_checkpoint_fixups[block_index] = try assembler.branchConditionPlaceholder(.ls);
        try assembler.subtractImmediate64(25, 25, instruction_count);
        try assembler.subtractImmediate64(24, 24, instruction_count);
        try assembler.addImmediate64(19, 19, instruction_count);
        const body = try assembler.branchPlaceholder();
        try assembler.patchBranch(body, hot_offsets[block_index]);
    };

    // A false conditional executes only the predecessor bytecodes. Refund the
    // covered successor that was conservatively pre-accounted, then enter the
    // false target through its ordinary guarded offset.
    for (blocks, 0..) |block, block_index| if (refund_fixups[block_index]) |fixup| {
        const stub = assembler.position();
        try patchControlToOffset(&assembler, fixup, stub);
        const successor_count = blocks[block_index + 1].instructionCount();
        try assembler.addImmediate64(25, 25, successor_count);
        try assembler.addImmediate64(24, 24, successor_count);
        try assembler.subtractImmediate64(19, 19, successor_count);
        const target = chunk.code.items[block.end - 1].a;
        if (target >= code_len or fast_offsets[target] == unreachable_offset) return error.UnsupportedChunk;
        const leave = try assembler.branchPlaceholder();
        try assembler.patchBranch(leave, fast_offsets[target]);
    };
    try patchControlFixups(&assembler, fast_control_fixups, fast_offsets);

    // Boundary blocks replay the original instruction accounting until their
    // end, then rejoin a fast block. Checkpoint islands resume immediately at
    // the operation whose accounting triggered the callback.
    for (blocks, 0..) |block, block_index| {
        slow_offsets[block_index] = assembler.position();
        try assembler.patchConditionBranch(fast_budget_fixups[block_index], slow_offsets[block_index]);
        try assembler.patchConditionBranch(fast_checkpoint_fixups[block_index], slow_offsets[block_index]);

        for (block.start..block.end) |ip| {
            const state = analysis.states[ip].?;
            try assembler.addImmediate64(19, 19, 1);
            try assembler.subtractImmediateSetFlags64(25, 25, 1);
            budget_fixups[ip] = try assembler.branchConditionPlaceholder(.lo);
            try assembler.subtractImmediateSetFlags64(24, 24, 1);
            checkpoint_fixups[ip] = try assembler.branchConditionPlaceholder(.eq);
            operation_offsets[ip] = assembler.position();
            slow_control_fixups[ip] = try emitOperation(&assembler, chunk, state, chunk.code.items[ip]);
        }

        const last_op = chunk.code.items[block.end - 1].op;
        if (!isBlockTerminator(last_op) or last_op == .jump_if_false) {
            if (block.end >= code_len or fast_offsets[block.end] == unreachable_offset) return error.UnsupportedChunk;
            slow_fallthrough_fixups[block_index] = try assembler.branchPlaceholder();
        }
    }
    try patchControlFixups(&assembler, slow_control_fixups, fast_offsets);
    for (blocks, slow_fallthrough_fixups) |block, at| if (at != unreachable_offset)
        try assembler.patchBranch(at, fast_offsets[block.end]);

    // Each bytecode instruction has one cold checkpoint island. The hot path
    // reaches these only through a boundary block's exact replay. Runtime work
    // happens before the instruction whose step reaches a 1024 boundary (or
    // exceeds the evaluation budget).
    for (chunk.code.items, 0..) |_, ip| {
        const state = analysis.states[ip] orelse continue;
        const stub = assembler.position();
        try assembler.patchConditionBranch(budget_fixups[ip], stub);
        try assembler.patchConditionBranch(checkpoint_fixups[ip], stub);
        // Numeric locals live in callee-saved d8-d15 on the hot path. Publish
        // canonical frame words only at a safepoint, where precise GC and error
        // creation can inspect the activation. The frame is proven unescaped
        // before entry, so no peer can observe the write-back delay.
        for (0..chunk.local_count) |slot| if (state.locals[slot] == .number) {
            try emitCanonicalNumber(&assembler, 9, try numericLocalRegister(slot));
            try assembler.store64(9, 22, try slotOffset(slot));
        };
        // d16-d23 are caller-saved. Spill live numeric operand values around
        // the runtime callback; non-numeric values already live in scratch.
        for (0..state.depth) |slot| if (state.stack[slot] == .number) {
            try assembler.moveRegisterFromFloat64(9, try numericRegister(slot));
            try assembler.store64(9, 20, try slotOffset(slot));
        };
        try assembler.load64(9, 21, frameOffset("steps"));
        try assembler.store64(19, 9, 0);
        try assembler.movImmediate64(9, ip);
        try assembler.store64(9, 21, frameOffset("exit_ip"));
        try assembler.moveRegister64(0, 21);
        try assembler.load64(16, 21, frameOffset("checkpoint"));
        try assembler.branchLinkRegister(16);
        status_fixups[ip] = try assembler.branchNotZero32Placeholder(0);
        for (0..state.depth) |slot| if (state.stack[slot] == .number) {
            try assembler.load64(9, 20, try slotOffset(slot));
            try assembler.moveFloatFromRegister64(try numericRegister(slot), 9);
        };
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
    if (!jit.supported or builtin.cpu.arch != .aarch64) return error.SkipZigTest;
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

test "integer provenance converges through benchmark-shaped loops" {
    const Parser = @import("../parser.zig").Parser;
    const Compiler = @import("../compiler.zig").Compiler;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var parser = try Parser.init(allocator,
        \\function kernel(jobs, lane) {
        \\  var total = 0;
        \\  for (var job = 0; job < jobs; job = job + 1) {
        \\    var value = lane + job + 1;
        \\    for (var i = 0; i < 100000; i = i + 1)
        \\      value = (value + i + lane) % 1000003;
        \\    total = total + value;
        \\  }
        \\  return total;
        \\}
    );
    const program = try parser.parseProgram();
    const root = try Compiler.compileProgram(allocator, program);
    const chunk = root.fns.items[0].chunk.?;
    var analysis = try analyzeNumeric(chunk, true);
    defer analysis.deinit();

    var saw_inner_bound = false;
    var saw_remainder = false;
    var saw_return = false;
    for (chunk.code.items, 0..) |inst, ip| switch (inst.op) {
        .lt => {
            const state = analysis.states[ip].?;
            if (state.depth >= 2 and
                std.meta.eql(state.stack_ranges[state.depth - 1], IntegerRange{ .min = 100_000, .max = 100_000 }))
            {
                const induction_slot = state.stack_locals[state.depth - 2].?;
                try std.testing.expectEqual(bc.Op.jump_if_false, chunk.code.items[ip + 1].op);
                const body_state = analysis.states[ip + 2].?;
                try std.testing.expectEqual(IntegerRange{ .min = 0, .max = 99_999 }, body_state.local_ranges[induction_slot]);
                saw_inner_bound = true;
            }
        },
        .mod => {
            const state = analysis.states[ip].?;
            try std.testing.expect(state.depth >= 2);
            try std.testing.expectEqual(IntegerFact.nonnegative, state.stack_integers[state.depth - 2]);
            try std.testing.expectEqual(IntegerFact.positive, state.stack_integers[state.depth - 1]);
            try std.testing.expectEqual(IntegerRange{ .min = 1_000_003, .max = 1_000_003 }, state.stack_ranges[state.depth - 1]);
            const result_state = analysis.states[ip + 1].?;
            try std.testing.expectEqual(IntegerRange{ .min = 0, .max = 1_000_002 }, result_state.stack_ranges[result_state.depth - 1]);
            saw_remainder = true;
        },
        .ret => {
            const state = analysis.states[ip].?;
            try std.testing.expect(state.depth >= 1);
            try std.testing.expectEqual(IntegerFact.nonnegative, state.stack_integers[state.depth - 1]);
            saw_return = true;
        },
        else => {},
    };
    try std.testing.expect(saw_inner_bound);
    try std.testing.expect(saw_remainder);
    try std.testing.expect(saw_return);
}

test "integer ranges bound guarded straight-line remainder" {
    const Parser = @import("../parser.zig").Parser;
    const Compiler = @import("../compiler.zig").Compiler;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var parser = try Parser.init(allocator, "function bounded(n) { return (n + 5) % 1000; }");
    const program = try parser.parseProgram();
    const root = try Compiler.compileProgram(allocator, program);
    const chunk = root.fns.items[0].chunk.?;
    var analysis = try analyzeNumeric(chunk, true);
    defer analysis.deinit();

    for (chunk.code.items, 0..) |inst, ip| if (inst.op == .ret) {
        const state = analysis.states[ip].?;
        try std.testing.expectEqual(IntegerRange{ .min = 0, .max = 999 }, state.stack_ranges[state.depth - 1]);
        return;
    };
    return error.TestExpectedEqual;
}

test "integer provenance rejects live mixed-kind locals" {
    const Parser = @import("../parser.zig").Parser;
    const Compiler = @import("../compiler.zig").Compiler;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var parser = try Parser.init(allocator,
        \\function mixed(n) {
        \\  var value;
        \\  if (n > 0) value = 1;
        \\  return value;
        \\}
    );
    const program = try parser.parseProgram();
    const root = try Compiler.compileProgram(allocator, program);
    const chunk = root.fns.items[0].chunk.?;
    try std.testing.expectError(error.UnsupportedChunk, analyzeNumeric(chunk, true));
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

    var slots: [3]u64 = undefined;
    var scratch: [jit.numeric_scratch_capacity]u64 = undefined;
    var expected_steps: ?u64 = null;
    for (1..48) |checkpoint_distance| {
        slots = .{
            Value.num(10).rawBits(),
            Value.undef().rawBits(),
            Value.undef().rawBits(),
        };
        var steps: u64 = 0;
        var checkpoint_calls: u32 = 0;
        var frame = jit.NativeFrame{
            .slots = &slots,
            .scratch = &scratch,
            .steps = &steps,
            .runtime_context = &checkpoint_calls,
            .checkpoint = Runtime.checkpoint,
            .remainder = Runtime.remainder,
            .steps_until_checkpoint = checkpoint_distance,
            .steps_until_budget = 1_000_000,
        };
        try std.testing.expectEqual(jit.ExitStatus.complete, compiled.run(&frame));
        try std.testing.expectEqual(@as(f64, 45), Value.fromRawBits(frame.result_bits).asNum());
        try std.testing.expectEqual(@as(u32, 1), checkpoint_calls);
        if (expected_steps) |expected| try std.testing.expectEqual(expected, steps) else expected_steps = steps;
    }
    try std.testing.expect(expected_steps.? > 100);
    try std.testing.expect(compiled.manages_steps);
    try std.testing.expectEqual(@as(u32, 3), compiled.frame_slots);
    try std.testing.expectEqual(@as(u64, 1), compiled.required_numeric_slots);
}
