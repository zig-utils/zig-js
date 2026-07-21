//! Executable lowering for optimizer plans.
//!
//! The first native subset is intentionally exact and narrow: an SSA return
//! whose complete live value graph consists only of primitive constants, with
//! arithmetic/comparisons restricted to Numbers. Anything involving a parameter,
//! block merge, coercion, or multiple returns is rejected before publication,
//! leaving baseline bytecode/native execution unchanged.

const std = @import("std");
const bc = @import("../bytecode.zig");
const jit = @import("../jit.zig");
const optimizer = @import("optimizer.zig");
const Value = @import("../value.zig").Value;

pub fn compile(chunk: *const bc.Chunk) !jit.CompiledCode {
    var plan = try optimizer.build(chunk, std.heap.page_allocator);
    defer plan.deinit();
    const result = try constantReturn(&plan);
    var compiled = try jit.compileConstantEntry(result.rawBits());
    compiled.bytecode_steps = plan.graph.returns[0].origin + 1;
    compiled.kind = .optimizer;
    return compiled;
}

fn constantReturn(plan: *const optimizer.Plan) error{UnsupportedChunk}!Value {
    if (plan.graph.returns.len != 1 or plan.graph.returns[0].block != 0 or plan.graph.edges.len != 1)
        return error.UnsupportedChunk;
    var values: [256]?Value = @splat(null);
    if (plan.graph.nodes.len > values.len) return error.UnsupportedChunk;

    for (plan.graph.nodes) |node| {
        values[node.id] = switch (node.kind) {
            .argument, .block_argument => return error.UnsupportedChunk,
            .constant => Value.fromRawBits(node.immediate),
            .undefined => Value.undef(),
            .null => Value.nul(),
            .true => Value.boolVal(true),
            .false => Value.boolVal(false),
            .add, .sub, .mul, .div, .mod, .lt, .le, .gt, .ge, .eq, .neq, .eq_strict, .neq_strict => result: {
                if (node.may_have_effect) return error.UnsupportedChunk;
                const lhs = values[node.lhs] orelse return error.UnsupportedChunk;
                const rhs = values[node.rhs] orelse return error.UnsupportedChunk;
                if (!lhs.isNumber() or !rhs.isNumber()) return error.UnsupportedChunk;
                const left = lhs.asNum();
                const right = rhs.asNum();
                break :result switch (node.kind) {
                    .add => Value.num(left + right),
                    .sub => Value.num(left - right),
                    .mul => Value.num(left * right),
                    .div => Value.num(left / right),
                    .mod => Value.num(@rem(left, right)),
                    .lt => Value.boolVal(left < right),
                    .le => Value.boolVal(left <= right),
                    .gt => Value.boolVal(left > right),
                    .ge => Value.boolVal(left >= right),
                    .eq, .eq_strict => Value.boolVal(left == right),
                    .neq, .neq_strict => Value.boolVal(left != right),
                    else => unreachable,
                };
            },
        };
    }
    return values[plan.graph.returns[0].value] orelse error.UnsupportedChunk;
}

test "optimizer compiler lowers one exact constant SSA return" {
    if (!jit.supported or @import("builtin").cpu.arch != .aarch64) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var chunk = bc.Chunk.init(arena.allocator());
    const one = try chunk.addConst(Value.num(1));
    const two = try chunk.addConst(Value.num(2));
    const fourteen = try chunk.addConst(Value.num(14));
    _ = try chunk.emit(.load_const, one);
    _ = try chunk.emit(.load_const, two);
    _ = try chunk.emit(.add, 0);
    _ = try chunk.emit(.load_const, fourteen);
    _ = try chunk.emit(.mul, 0);
    _ = try chunk.emit(.ret, 0);

    var compiled = try compile(&chunk);
    defer compiled.deinit();
    var frame = jit.NativeFrame{};
    try std.testing.expectEqual(jit.CodeKind.optimizer, compiled.kind);
    try std.testing.expectEqual(@as(u32, 6), compiled.bytecode_steps);
    try std.testing.expectEqual(jit.ExitStatus.complete, compiled.run(&frame));
    try std.testing.expectEqual(@as(f64, 42), Value.fromRawBits(frame.result_bits).asNum());
}

test "optimizer compiler rejects live arguments before publication" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var chunk = bc.Chunk.init(arena.allocator());
    chunk.param_count = 1;
    chunk.local_count = 1;
    _ = try chunk.emit(.load_local, 0);
    _ = try chunk.emit(.ret, 0);
    try std.testing.expectError(error.UnsupportedChunk, compile(&chunk));
}
