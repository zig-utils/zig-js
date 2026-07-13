//! Architecture-neutral foundations for the baseline native tier.
//!
//! This module owns executable mappings and their write-to-execute transition.
//! Backends emit bytes through `writableBytes`, publish once, and thereafter
//! only retain the immutable `executableBytes` view. Unsupported targets return
//! `error.UnsupportedTarget`, leaving bytecode execution unchanged.

const std = @import("std");
const builtin = @import("builtin");

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

    pub fn publishReady(self: *Tier) void {
        std.debug.assert(self.state.load(.monotonic) == .compiling);
        self.state.store(.ready, .release);
    }

    pub fn publishRejected(self: *Tier) void {
        std.debug.assert(self.state.load(.monotonic) == .compiling);
        self.state.store(.rejected, .release);
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
    tier.publishReady();
    try std.testing.expectEqual(TierState.ready, tier.loadState());
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
