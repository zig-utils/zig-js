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

    pub fn deinit(self: *Plan) void {
        self.allocator.free(self.blocks);
        self.allocator.free(self.instructions);
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
        return out.toOwnedSlice(allocator);
    }
};

pub fn build(chunk: *const bc.Chunk, allocator: std.mem.Allocator) BuildError!Plan {
    const code = chunk.code.items;
    if (code.len == 0) return error.EmptyChunk;
    if (code.len > std.math.maxInt(u32)) return error.UnsupportedChunk;
    for (code) |inst| if (!supports(inst.op)) return error.UnsupportedChunk;

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
        .ret, .ret_undef => if (ip + 1 < code.len) {
            starts[ip + 1] = true;
        },
        else => {},
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
            else => if (index + 1 < blocks_list.items.len) {
                addSuccessor(block, @intCast(index + 1));
            },
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

    return .{
        .allocator = allocator,
        .blocks = try blocks_list.toOwnedSlice(allocator),
        .instructions = instructions,
    };
}

fn addSuccessor(block: *Block, successor: u32) void {
    for (block.successors[0..block.successor_count]) |existing| if (existing == successor) return;
    std.debug.assert(block.successor_count < block.successors.len);
    block.successors[block.successor_count] = successor;
    block.successor_count += 1;
}

fn supports(op: bc.Op) bool {
    return switch (op) {
        .load_const,
        .load_undefined,
        .load_null,
        .load_true,
        .load_false,
        .pop,
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
        => true,
        else => false,
    };
}

test "optimizer control-flow plans are deterministic" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var chunk = bc.Chunk.init(a);
    _ = try chunk.emit(.load_local, 0);
    _ = try chunk.emit(.load_const, 0);
    _ = try chunk.emit(.lt, 0);
    _ = try chunk.emit(.jump_if_false, 7);
    _ = try chunk.emit(.load_local, 0);
    _ = try chunk.emit(.load_const, 1);
    _ = try chunk.emit(.add, 0);
    _ = try chunk.emit(.ret, 0);

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
    try std.testing.expect(std.mem.indexOf(u8, first_dump, "%3 @3 jump_if_false 7 0") != null);
}

test "optimizer rejects unsupported bytecode and invalid control flow" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var chunk = bc.Chunk.init(arena.allocator());
    _ = try chunk.emit(.new_object, 0);
    _ = try chunk.emit(.ret, 0);
    try std.testing.expectError(error.UnsupportedChunk, build(&chunk, std.testing.allocator));

    var invalid = bc.Chunk.init(arena.allocator());
    _ = try invalid.emit(.jump, 1);
    try std.testing.expectError(error.InvalidControlFlow, build(&invalid, std.testing.allocator));
}
