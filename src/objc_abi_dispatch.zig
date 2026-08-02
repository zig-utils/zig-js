//! Owned Objective-C native-call ABI lowering (#463).
//!
//! Objective-C supplies already-converted values and a scratch region. This
//! module classifies the pinned scalar/Foundation types according to Darwin
//! AArch64 or x86-64, packs register/stack state, and calls a tiny assembly
//! leaf. Unsupported descriptors fail before the target function is entered.

const std = @import("std");
const builtin = @import("builtin");

const Kind = enum(u32) {
    void,
    sint8,
    uint8,
    sint16,
    uint16,
    sint32,
    uint32,
    sint64,
    uint64,
    float,
    double,
    pointer,
    point,
    size,
    rect,
    range,
};

const Storage = extern union {
    raw: [32]u8,
    alignment: u64,
};

const Argument = extern struct {
    kind: Kind,
    value: Storage,
};

const Call = extern struct {
    function: ?*const anyopaque,
    arguments: [*]const Argument,
    argument_count: usize,
    return_kind: Kind,
    scratch: [*]u8,
    scratch_capacity: usize,
    result: *Storage,
};

const Status = enum(i32) {
    ok = 0,
    invalid_descriptor = 1,
    unsupported_architecture = 2,
    insufficient_scratch = 3,
};

// Kept deliberately plain so both assembly files have one stable layout.
const NativeFrame = extern struct {
    function: usize, // 0
    stack: [*]u8, // 8
    stack_len: usize, // 16
    sret: usize, // 24
    gpr: [8]u64, // 32
    fpr: [8][2]u64, // 96
    ret_gpr: [2]u64, // 224
    ret_fpr: [4][2]u64, // 240
};

comptime {
    if (@sizeOf(Storage) != 32 or @alignOf(Storage) != 8) @compileError("Objective-C storage ABI drift");
    if (@offsetOf(Argument, "value") != 8 or @sizeOf(Argument) != 40) @compileError("Objective-C argument ABI drift");
    if (@offsetOf(Call, "arguments") != 8 or @offsetOf(Call, "argument_count") != 16 or
        @offsetOf(Call, "return_kind") != 24 or @offsetOf(Call, "scratch") != 32 or
        @offsetOf(Call, "scratch_capacity") != 40 or @offsetOf(Call, "result") != 48 or
        @sizeOf(Call) != 56) @compileError("Objective-C call descriptor ABI drift");
    if (@offsetOf(NativeFrame, "gpr") != 32 or @offsetOf(NativeFrame, "fpr") != 96 or
        @offsetOf(NativeFrame, "ret_gpr") != 224 or @offsetOf(NativeFrame, "ret_fpr") != 240 or
        @sizeOf(NativeFrame) != 304) @compileError("Objective-C assembly frame ABI drift");
}

extern fn ZJSObjCNativeInvokeAsm(frame: *NativeFrame) callconv(.c) void;

fn kindSize(kind: Kind) usize {
    return switch (kind) {
        .void => 0,
        .sint8, .uint8 => 1,
        .sint16, .uint16 => 2,
        .sint32, .uint32, .float => 4,
        .sint64, .uint64, .double, .pointer => 8,
        .point, .size, .range => 16,
        .rect => 32,
    };
}

fn isInteger(kind: Kind) bool {
    return switch (kind) {
        .sint8, .uint8, .sint16, .uint16, .sint32, .uint32, .sint64, .uint64, .pointer => true,
        else => false,
    };
}

fn storageBytes(storage: *const Storage) []const u8 {
    return @as([*]const u8, @ptrCast(storage))[0..@sizeOf(Storage)];
}

fn storageBytesMut(storage: *Storage) []u8 {
    return @as([*]u8, @ptrCast(storage))[0..@sizeOf(Storage)];
}

fn laneBytes(lane: *[2]u64) []u8 {
    return @as([*]u8, @ptrCast(lane))[0..16];
}

fn scalarBits(storage: *const Storage) u64 {
    var bits: u64 = 0;
    @memcpy(std.mem.asBytes(&bits), storageBytes(storage)[0..8]);
    return bits;
}

const StackBuilder = struct {
    bytes: []u8,
    len: usize = 0,

    fn push(self: *StackBuilder, source: []const u8, alignment: usize) bool {
        const start = std.mem.alignForward(usize, self.len, alignment);
        const end = std.mem.alignForward(usize, start + source.len, 8);
        if (end > self.bytes.len) return false;
        @memset(self.bytes[self.len..end], 0);
        @memcpy(self.bytes[start .. start + source.len], source);
        self.len = end;
        return true;
    }
};

fn putFpr(frame: *NativeFrame, index: usize, source: []const u8) void {
    @memset(laneBytes(&frame.fpr[index]), 0);
    @memcpy(laneBytes(&frame.fpr[index])[0..source.len], source);
}

fn lowerArm64(call: *Call, frame: *NativeFrame, stack: *StackBuilder) Status {
    var gpr_index: usize = 0;
    var fpr_index: usize = 0;
    for (call.arguments[0..call.argument_count]) |*argument| {
        const bytes = storageBytes(&argument.value);
        if (isInteger(argument.kind)) {
            if (gpr_index < 8) {
                frame.gpr[gpr_index] = scalarBits(&argument.value);
                gpr_index += 1;
            } else if (!stack.push(bytes[0..kindSize(argument.kind)], 8)) return .insufficient_scratch;
            continue;
        }
        switch (argument.kind) {
            .float, .double => {
                if (fpr_index < 8) {
                    putFpr(frame, fpr_index, bytes[0..kindSize(argument.kind)]);
                    fpr_index += 1;
                } else if (!stack.push(bytes[0..kindSize(argument.kind)], 8)) return .insufficient_scratch;
            },
            .point, .size => {
                if (fpr_index + 2 <= 8) {
                    putFpr(frame, fpr_index, bytes[0..8]);
                    putFpr(frame, fpr_index + 1, bytes[8..16]);
                    fpr_index += 2;
                } else {
                    fpr_index = 8;
                    if (!stack.push(bytes[0..16], 8)) return .insufficient_scratch;
                }
            },
            .rect => {
                if (fpr_index + 4 <= 8) {
                    for (0..4) |lane| putFpr(frame, fpr_index + lane, bytes[lane * 8 .. lane * 8 + 8]);
                    fpr_index += 4;
                } else {
                    fpr_index = 8;
                    if (!stack.push(bytes[0..32], 8)) return .insufficient_scratch;
                }
            },
            .range => {
                if (gpr_index + 2 <= 8) {
                    frame.gpr[gpr_index] = scalarBits(&argument.value);
                    var high: u64 = 0;
                    @memcpy(std.mem.asBytes(&high), bytes[8..16]);
                    frame.gpr[gpr_index + 1] = high;
                    gpr_index += 2;
                } else {
                    // AAPCS64 rule C.12: a composite that cannot fit wholly in
                    // the remaining argument registers starts on the stack.
                    gpr_index = 8;
                    if (!stack.push(bytes[0..16], 8)) return .insufficient_scratch;
                }
            },
            .void => return .invalid_descriptor,
            else => unreachable,
        }
    }
    frame.stack_len = std.mem.alignForward(usize, stack.len, 16);
    return .ok;
}

fn lowerX86_64(call: *Call, frame: *NativeFrame, stack: *StackBuilder) Status {
    var gpr_index: usize = 0;
    var fpr_index: usize = 0;
    if (call.return_kind == .rect) {
        frame.sret = @intFromPtr(call.result);
        frame.gpr[0] = frame.sret;
        gpr_index = 1;
    }
    for (call.arguments[0..call.argument_count]) |*argument| {
        const bytes = storageBytes(&argument.value);
        if (isInteger(argument.kind)) {
            if (gpr_index < 6) {
                frame.gpr[gpr_index] = scalarBits(&argument.value);
                gpr_index += 1;
            } else if (!stack.push(bytes[0..kindSize(argument.kind)], 8)) return .insufficient_scratch;
            continue;
        }
        switch (argument.kind) {
            .float, .double => {
                if (fpr_index < 8) {
                    putFpr(frame, fpr_index, bytes[0..kindSize(argument.kind)]);
                    fpr_index += 1;
                } else if (!stack.push(bytes[0..kindSize(argument.kind)], 8)) return .insufficient_scratch;
            },
            .point, .size => {
                if (fpr_index + 2 <= 8) {
                    putFpr(frame, fpr_index, bytes[0..8]);
                    putFpr(frame, fpr_index + 1, bytes[8..16]);
                    fpr_index += 2;
                } else if (!stack.push(bytes[0..16], 8)) return .insufficient_scratch;
            },
            .range => {
                if (gpr_index + 2 <= 6) {
                    frame.gpr[gpr_index] = scalarBits(&argument.value);
                    var high: u64 = 0;
                    @memcpy(std.mem.asBytes(&high), bytes[8..16]);
                    frame.gpr[gpr_index + 1] = high;
                    gpr_index += 2;
                } else {
                    gpr_index = 6;
                    if (!stack.push(bytes[0..16], 8)) return .insufficient_scratch;
                }
            },
            // Darwin x86-64 classifies aggregates larger than two eightbytes
            // as MEMORY, both for methods and block invoke functions.
            .rect => if (!stack.push(bytes[0..32], 8)) return .insufficient_scratch,
            .void => return .invalid_descriptor,
            else => unreachable,
        }
    }
    frame.stack_len = std.mem.alignForward(usize, stack.len, 16);
    return .ok;
}

fn copyReturns(call: *Call, frame: *const NativeFrame) void {
    const output = storageBytesMut(call.result);
    if (builtin.cpu.arch == .x86_64 and call.return_kind == .rect) return;
    switch (call.return_kind) {
        .void => {},
        .sint8, .uint8, .sint16, .uint16, .sint32, .uint32, .sint64, .uint64, .pointer => {
            @memcpy(output[0..8], std.mem.asBytes(&frame.ret_gpr[0]));
        },
        .float => @memcpy(output[0..4], @as([*]const u8, @ptrCast(&frame.ret_fpr[0]))[0..4]),
        .double => @memcpy(output[0..8], @as([*]const u8, @ptrCast(&frame.ret_fpr[0]))[0..8]),
        .point, .size => {
            @memcpy(output[0..8], @as([*]const u8, @ptrCast(&frame.ret_fpr[0]))[0..8]);
            @memcpy(output[8..16], @as([*]const u8, @ptrCast(&frame.ret_fpr[1]))[0..8]);
        },
        .rect => {
            for (0..4) |lane| @memcpy(output[lane * 8 .. lane * 8 + 8], @as([*]const u8, @ptrCast(&frame.ret_fpr[lane]))[0..8]);
        },
        .range => {
            @memcpy(output[0..8], std.mem.asBytes(&frame.ret_gpr[0]));
            @memcpy(output[8..16], std.mem.asBytes(&frame.ret_gpr[1]));
        },
    }
}

export fn ZJSObjCNativeCall(call: *Call) callconv(.c) Status {
    if (call.function == null) return .invalid_descriptor;
    if (builtin.os.tag != .macos or (builtin.cpu.arch != .aarch64 and builtin.cpu.arch != .x86_64))
        return .unsupported_architecture;

    @memset(storageBytesMut(call.result), 0);
    if (call.return_kind == .void) {} else _ = kindSize(call.return_kind);
    var frame: NativeFrame = std.mem.zeroes(NativeFrame);
    frame.function = @intFromPtr(call.function.?);
    frame.stack = call.scratch;
    var stack = StackBuilder{ .bytes = call.scratch[0..call.scratch_capacity] };
    const status = if (builtin.cpu.arch == .aarch64)
        lowerArm64(call, &frame, &stack)
    else
        lowerX86_64(call, &frame, &stack);
    if (status != .ok) return status;
    if (frame.stack_len > call.scratch_capacity) return .insufficient_scratch;
    ZJSObjCNativeInvokeAsm(&frame);
    copyReturns(call, &frame);
    return .ok;
}
