//! Architecture-neutral foundations for the baseline native tier.
//!
//! This module owns executable mappings and their write-to-execute transition.
//! Backends emit bytes through `writableBytes`, publish once, and thereafter
//! only retain the immutable `executableBytes` view. Unsupported targets return
//! `error.UnsupportedTarget`, leaving bytecode execution unchanged.

const std = @import("std");
const builtin = @import("builtin");

const aarch64 = @import("jit/aarch64.zig");

const is_darwin = switch (builtin.os.tag) {
    .driverkit, .ios, .maccatalyst, .macos, .tvos, .visionos, .watchos => true,
    else => false,
};

pub const supported = is_darwin and switch (builtin.cpu.arch) {
    .aarch64, .x86_64 => true,
    else => false,
};

pub const TierState = enum(u8) { cold, compiling, ready, rejected };

/// Per-chunk hotness and single-writer compilation claim.
///
/// Entrants that lose the claim never wait: they continue in bytecode while
/// the winning thread compiles. Publishing `ready` or `rejected` releases all
/// compiler writes to later acquire readers.
pub const Tier = struct {
    state: std.atomic.Value(TierState) = .init(.cold),
    entries: std.atomic.Value(u32) = .init(0),
    code: ?*CompiledCode = null,

    pub fn observeEntry(self: *Tier, threshold: u32) bool {
        std.debug.assert(threshold > 0);
        if (self.state.load(.monotonic) != .cold) return false;
        const previous = self.entries.fetchAdd(1, .monotonic);
        if (previous < threshold - 1) return false;
        return self.state.cmpxchgStrong(.cold, .compiling, .acq_rel, .monotonic) == null;
    }

    pub fn loadState(self: *const Tier) TierState {
        return self.state.load(.acquire);
    }

    pub fn publishReady(self: *Tier, code: *CompiledCode) void {
        std.debug.assert(self.state.load(.monotonic) == .compiling);
        self.code = code;
        self.state.store(.ready, .release);
    }

    pub fn loadCode(self: *const Tier) ?*const CompiledCode {
        if (self.state.load(.acquire) != .ready) return null;
        return self.code.?;
    }

    pub fn publishRejected(self: *Tier) void {
        std.debug.assert(self.state.load(.monotonic) == .compiling);
        self.state.store(.rejected, .release);
    }
};

pub const ExitStatus = enum(u32) { complete, side_exit, throw, stop };
pub const numeric_scratch_capacity = 64;

/// Stable C-compatible boundary between generated code and the Zig runtime.
/// More fields are appended as lowering grows; generated code only addresses
/// fields through backend constants derived with `@offsetOf`.
pub const NativeFrame = extern struct {
    result_bits: u64 = 0,
    exit_ip: usize = 0,
    /// Raw NaN-boxed function slots. The VM keeps the owning activation rooted
    /// for the entire native call; generated code may only access indexes that
    /// the chunk's immutable frame metadata proves in bounds.
    slots: ?[*]u64 = null,
    /// Caller-owned spill storage for the native operand stack. The first
    /// numeric tier permits no GC pointer here, so precise tracing needs no
    /// backend-specific stack map.
    scratch: ?[*]u64 = null,
    /// Exact interpreter step counter, updated before every native safepoint
    /// and on every exit.
    steps: ?*u64 = null,
    runtime_context: ?*anyopaque = null,
    /// Returns zero to continue or a non-zero `ExitStatus` value to leave
    /// native code after servicing budget, termination, GIL, and GC work.
    checkpoint: ?*const fn (*NativeFrame) callconv(.c) u32 = null,
    /// Full Number remainder semantics for operands outside the generated
    /// positive-small-integer fast path.
    remainder: ?*const fn (f64, f64) callconv(.c) f64 = null,
    steps_until_checkpoint: u64 = 0,
    steps_until_budget: u64 = 0,
};

pub const NativeEntry = *const fn (*NativeFrame) callconv(.c) u32;

pub const CompiledCode = struct {
    memory: CodeMemory,
    entry: NativeEntry,
    /// Number of bytecode dispatches represented by a successful native entry.
    /// Used to preserve the interpreter's step-budget/checkpoint accounting.
    bytecode_steps: u32 = 0,
    /// Numeric/control entries update the interpreter counter themselves and
    /// call the runtime exactly at bytecode checkpoint boundaries.
    manages_steps: bool = false,
    frame_slots: u32 = 0,
    required_numeric_slots: u64 = 0,
    /// Parameter slots that must contain canonical non-negative u32 Numbers.
    /// The VM checks this before native step accounting or slot mutation, so a
    /// failed speculative integer entry restarts safely at bytecode IP zero.
    required_u32_slots: u64 = 0,
    max_stack_depth: u8 = 0,

    pub fn deinit(self: *CompiledCode) void {
        self.memory.deinit();
        self.* = undefined;
    }

    pub fn run(self: *const CompiledCode, frame: *NativeFrame) ExitStatus {
        return @enumFromInt(self.entry(frame));
    }
};

/// Context-owned lifetime registry for immutable compiled mappings. Adoption is
/// serialized because different shared-realm chunks can tier concurrently;
/// teardown runs only after all JavaScript threads have joined.
pub const Owner = struct {
    allocator: ?std.mem.Allocator = null,
    lock: std.atomic.Mutex = .unlocked,
    codes: std.ArrayListUnmanaged(*CompiledCode) = .empty,

    pub fn init(allocator: std.mem.Allocator) Owner {
        return .{ .allocator = allocator };
    }

    pub fn adopt(self: *Owner, compiled: CompiledCode) std.mem.Allocator.Error!*CompiledCode {
        const allocator = self.allocator orelse return error.OutOfMemory;
        const owned = try allocator.create(CompiledCode);
        errdefer allocator.destroy(owned);

        while (!self.lock.tryLock()) std.atomic.spinLoopHint();
        defer self.lock.unlock();
        try self.codes.append(allocator, owned);
        owned.* = compiled;
        return owned;
    }

    pub fn deinit(self: *Owner) void {
        const allocator = self.allocator orelse return;
        for (self.codes.items) |code| {
            code.deinit();
            allocator.destroy(code);
        }
        self.codes.deinit(allocator);
        self.* = .{};
    }
};

const State = enum { writable, executable };

/// One immutable-after-publication native-code mapping.
///
/// Darwin's JIT write protection is thread-local. Consequently allocation,
/// emission, and `publish` must happen on the compilation-claiming thread with
/// no call into untrusted code between them. The tier state machine guarantees
/// that only one thread owns a mapping before publication.
pub const CodeMemory = struct {
    mapping: []align(std.heap.page_size_min) u8,
    used: usize = 0,
    state: State = .writable,

    pub fn init(min_capacity: usize) !CodeMemory {
        if (!supported) return error.UnsupportedTarget;
        if (min_capacity == 0) return error.InvalidCapacity;

        const capacity = std.mem.alignForward(usize, min_capacity, std.heap.page_size_min);
        const protection: std.posix.PROT = .{ .READ = true, .WRITE = true, .EXEC = true };
        var flags: std.posix.MAP = .{ .TYPE = .PRIVATE, .ANONYMOUS = true };
        flags.JIT = true;
        const mapping = try std.posix.mmap(null, capacity, protection, flags, -1, 0);

        // MAP_JIT pages are executable to other threads while this thread gets
        // the writable view. Re-enable protection in publish/deinit.
        pthread_jit_write_protect_np(0);
        return .{ .mapping = mapping };
    }

    pub fn deinit(self: *CodeMemory) void {
        if (self.state == .writable and supported) pthread_jit_write_protect_np(1);
        std.posix.munmap(self.mapping);
        self.* = undefined;
    }

    pub fn writableBytes(self: *CodeMemory) []u8 {
        std.debug.assert(self.state == .writable);
        return self.mapping;
    }

    /// Flush the emitted range and make it immutable on the compiling thread.
    /// The caller may publish the returned entry pointer only after this call.
    pub fn publish(self: *CodeMemory, used: usize) error{InvalidCodeSize}!void {
        if (used == 0 or used > self.mapping.len) return error.InvalidCodeSize;
        std.debug.assert(self.state == .writable);

        self.used = used;
        sys_icache_invalidate(self.mapping.ptr, used);
        pthread_jit_write_protect_np(1);
        self.state = .executable;
    }

    pub fn executableBytes(self: *const CodeMemory) []const u8 {
        std.debug.assert(self.state == .executable);
        return self.mapping[0..self.used];
    }
};

/// Compile the smallest real native entry: publish one exact NaN-boxed word as
/// a completed result. This is the backend/ABI bring-up primitive used before
/// bytecode lowering; it deliberately knows nothing about source text.
pub fn compileConstantEntry(result_bits: u64) !CompiledCode {
    if (!supported or builtin.cpu.arch != .aarch64) return error.UnsupportedTarget;

    var memory = try CodeMemory.init(32);
    errdefer memory.deinit();
    var assembler = aarch64.Assembler.init(memory.writableBytes());
    try assembler.movImmediate64(1, result_bits);
    try assembler.store64(1, 0, @offsetOf(NativeFrame, "result_bits"));
    try assembler.movImmediate32(0, @intFromEnum(ExitStatus.complete));
    try assembler.ret();
    try memory.publish(assembler.bytes().len);

    const entry: NativeEntry = @ptrCast(@alignCast(memory.executableBytes().ptr));
    return .{ .memory = memory, .entry = entry };
}

extern "c" fn pthread_jit_write_protect_np(enabled: c_int) void;
extern "c" fn sys_icache_invalidate(start: *anyopaque, len: usize) void;

test "CodeMemory rejects empty mappings" {
    if (!supported) return error.SkipZigTest;
    try std.testing.expectError(error.InvalidCapacity, CodeMemory.init(0));
}

test "Tier claims compilation exactly at its hot threshold" {
    var tier = Tier{};
    try std.testing.expect(!tier.observeEntry(3));
    try std.testing.expect(!tier.observeEntry(3));
    try std.testing.expect(tier.observeEntry(3));
    try std.testing.expectEqual(TierState.compiling, tier.loadState());
    try std.testing.expect(!tier.observeEntry(3));
    var code: CompiledCode = undefined;
    tier.publishReady(&code);
    try std.testing.expectEqual(TierState.ready, tier.loadState());
    try std.testing.expectEqual(&code, tier.loadCode().?);
}

test "Tier caches an unsupported compilation" {
    var tier = Tier{};
    try std.testing.expect(tier.observeEntry(1));
    tier.publishRejected();
    try std.testing.expectEqual(TierState.rejected, tier.loadState());
    try std.testing.expect(!tier.observeEntry(1));
}

test "Tier permits one concurrent compiler" {
    if (builtin.single_threaded) return error.SkipZigTest;

    const Shared = struct {
        tier: Tier = .{},
        claims: std.atomic.Value(u32) = .init(0),

        fn enter(shared: *@This()) void {
            var i: u32 = 0;
            while (i < 1000) : (i += 1) {
                if (shared.tier.observeEntry(32)) _ = shared.claims.fetchAdd(1, .monotonic);
            }
        }
    };

    var shared = Shared{};
    var threads: [8]std.Thread = undefined;
    for (&threads) |*thread| thread.* = try std.Thread.spawn(.{}, Shared.enter, .{&shared});
    for (&threads) |*thread| thread.join();

    try std.testing.expectEqual(@as(u32, 1), shared.claims.load(.monotonic));
    try std.testing.expectEqual(TierState.compiling, shared.tier.loadState());
    shared.tier.publishRejected();
}

test "native entry publishes an exact result word through the stable ABI" {
    if (!supported or builtin.cpu.arch != .aarch64) return error.SkipZigTest;

    const expected: u64 = 0x7ff8_1234_5678_9abc;
    var compiled = try compileConstantEntry(expected);
    defer compiled.deinit();
    var frame = NativeFrame{};
    try std.testing.expectEqual(ExitStatus.complete, compiled.run(&frame));
    try std.testing.expectEqual(expected, frame.result_bits);
    try std.testing.expectEqual(@as(usize, 0), frame.exit_ip);
}

test "Owner releases adopted executable mappings" {
    if (!supported or builtin.cpu.arch != .aarch64) return error.SkipZigTest;

    var owner = Owner.init(std.testing.allocator);
    defer owner.deinit();
    const code = try owner.adopt(try compileConstantEntry(0x1234));
    var frame = NativeFrame{};
    try std.testing.expectEqual(ExitStatus.complete, code.run(&frame));
    try std.testing.expectEqual(@as(u64, 0x1234), frame.result_bits);
}

test "CodeMemory publishes and executes native code" {
    if (!supported) return error.SkipZigTest;

    const machine_code = switch (builtin.cpu.arch) {
        // mov w0, #42; ret
        .aarch64 => [_]u8{ 0x40, 0x05, 0x80, 0x52, 0xc0, 0x03, 0x5f, 0xd6 },
        // mov eax, 42; ret
        .x86_64 => [_]u8{ 0xb8, 0x2a, 0x00, 0x00, 0x00, 0x00, 0xc3 },
        else => unreachable,
    };

    var memory = try CodeMemory.init(machine_code.len);
    defer memory.deinit();
    @memcpy(memory.writableBytes()[0..machine_code.len], &machine_code);
    try memory.publish(machine_code.len);

    const NativeFn = *const fn () callconv(.c) u32;
    const entry: NativeFn = @ptrCast(@alignCast(memory.executableBytes().ptr));
    try std.testing.expectEqual(@as(u32, 42), entry());
}
