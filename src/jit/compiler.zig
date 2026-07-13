//! Architecture-neutral bytecode selection for the baseline native tier.
//!
//! The supported set begins deliberately small. A chunk is accepted only when
//! every instruction has a native implementation; otherwise the VM caches the
//! rejection and interprets it normally.

const bc = @import("../bytecode.zig");
const jit = @import("../jit.zig");

const Chunk = bc.Chunk;

pub fn compile(chunk: *const Chunk) !jit.CompiledCode {
    const selection = constantResult(chunk) orelse return error.UnsupportedChunk;
    var compiled = try jit.compileConstantEntry(selection.bits);
    compiled.bytecode_steps = selection.steps;
    return compiled;
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

test "compiler lowers a constant-return bytecode function" {
    const std = @import("std");
    const Parser = @import("../parser.zig").Parser;
    const Compiler = @import("../compiler.zig").Compiler;

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var parser = try Parser.init(allocator, "function answer() { return 42; }");
    const program = try parser.parseProgram();
    const root = try Compiler.compileProgram(allocator, program);
    const function_chunk = root.fns.items[0].chunk.?;

    var compiled = try compile(function_chunk);
    defer compiled.deinit();
    var frame = jit.NativeFrame{};
    try std.testing.expectEqual(jit.ExitStatus.complete, compiled.run(&frame));
    try std.testing.expectEqual(@as(f64, 42), @import("../value.zig").Value.fromRawBits(frame.result_bits).asNum());
}
