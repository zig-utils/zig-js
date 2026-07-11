//! Process-wide backing storage for `SharedArrayBuffer`.
//!
//! A SharedArrayBuffer's bytes must outlive any single realm/agent and be
//! visible to all of them, so they cannot live in a `Context` arena (which is
//! single-thread-affine and freed wholesale on context destroy). Instead each
//! SAB owns a `SharedBufferStorage`: refcounted, allocated from a stable
//! process-wide allocator, with a slab that **never moves** — a growable SAB
//! reserves `maxByteLength` up front and grows in place by publishing a new
//! length, which is what makes concurrent length-tracking views sound without
//! locking every access (see https://github.com/zig-utils/zig-js/issues/1,
//! Phase 1).
//!
//! Thread-safety contract:
//! - `retain`/`release` are atomic; any thread may call them. Retain is checked
//!   and refuses to wrap the storage refcount.
//! - `len()` / `slice()` are lock-free (acquire load of the published length).
//! - `grow` may race with other growers (CAS loop) and with readers (they see
//!   either the old or the new length, never a torn one).
//! - Element data races are the *JS program's* problem (per the memory model);
//!   torn multi-byte access is prevented by natural alignment of typed-array
//!   elements within the slab (`page_allocator` returns page-aligned slabs).

const std = @import("std");

/// Stable allocator for slabs and headers. `page_allocator` needs no libc, is
/// thread-safe, and page-aligns slabs (so every typed-array element offset is
/// naturally aligned for its size).
const global_alloc = std.heap.page_allocator;
const retain_list_reserve_granularity: usize = 64;

pub const SharedBufferStorage = struct {
    /// The reserved slab: `capacity` bytes, zero-initialized, fixed address.
    slab: [*]u8,
    /// Reserved size. For a growable SAB this is `maxByteLength`; for a
    /// fixed-length SAB it equals the byte length.
    capacity: usize,
    /// Whether `grow` is allowed (the SAB was created with `maxByteLength`).
    growable: bool,
    /// Current published byte length (monotonically non-decreasing).
    byte_len: std.atomic.Value(usize),
    /// Live references: one per realm-level wrapper (`ArrayBufferData.shared`)
    /// plus one per host hold (e.g. the agent-broadcast slot).
    refcount: std.atomic.Value(usize),

    /// Allocate storage with an initial length, reserving `max_byte_len` when
    /// growable. Returned with refcount 1 (the caller's reference).
    pub fn create(byte_len: usize, max_byte_len: ?usize) error{OutOfMemory}!*SharedBufferStorage {
        const cap = max_byte_len orelse byte_len;
        std.debug.assert(cap >= byte_len);
        const self = try global_alloc.create(SharedBufferStorage);
        errdefer global_alloc.destroy(self);
        const slab = try global_alloc.alloc(u8, @max(cap, 1));
        @memset(slab, 0);
        self.* = .{
            .slab = slab.ptr,
            .capacity = cap,
            .growable = max_byte_len != null,
            .byte_len = .init(byte_len),
            .refcount = .init(1),
        };
        return self;
    }

    pub fn retain(self: *SharedBufferStorage) *SharedBufferStorage {
        return self.tryRetain() orelse @panic("SharedBufferStorage refcount overflow");
    }

    pub fn tryRetain(self: *SharedBufferStorage) ?*SharedBufferStorage {
        var current = self.refcount.load(.monotonic);
        while (true) {
            if (current == std.math.maxInt(usize)) return null;
            if (self.refcount.cmpxchgWeak(current, current + 1, .monotonic, .monotonic)) |observed| {
                current = observed;
                continue;
            }
            return self;
        }
    }

    pub fn release(self: *SharedBufferStorage) void {
        if (self.refcount.fetchSub(1, .release) == 1) {
            _ = self.refcount.load(.acquire);
            global_alloc.free(self.slab[0..@max(self.capacity, 1)]);
            global_alloc.destroy(self);
        }
    }

    /// The current published byte length.
    pub fn len(self: *const SharedBufferStorage) usize {
        return self.byte_len.load(.acquire);
    }

    /// The live bytes `[0..len())`. The slice is valid as long as the caller
    /// holds a reference; its length is a snapshot (the buffer may grow, never
    /// shrink, so the bytes themselves stay valid).
    pub fn slice(self: *const SharedBufferStorage) []u8 {
        return self.slab[0..self.len()];
    }

    /// Grow the published length in place (SABs only ever grow). Racing
    /// growers are serialized by the CAS; a request below the current length
    /// or above capacity is the caller's RangeError.
    pub fn grow(self: *SharedBufferStorage, new_len: usize) error{ NotGrowable, OutOfRange }!void {
        if (!self.growable) return error.NotGrowable;
        if (new_len > self.capacity) return error.OutOfRange;
        var cur = self.byte_len.load(.acquire);
        while (true) {
            if (new_len < cur) return error.OutOfRange;
            cur = self.byte_len.cmpxchgWeak(cur, new_len, .acq_rel, .acquire) orelse return;
        }
    }
};

/// A realm's set of storage references, so a context/agent can release
/// everything it retained when it is destroyed (the arena itself runs no
/// per-object destructors). Owned by `Context` (and by each agent realm);
/// the interpreter reaches it the same way it reaches the microtask queue.
pub const RetainList = struct {
    gpa: std.mem.Allocator,
    lock: std.atomic.Mutex = .unlocked,
    items: std.ArrayListUnmanaged(*SharedBufferStorage) = .empty,

    fn lockList(self: *RetainList) void {
        var spins: usize = 0;
        while (!self.lock.tryLock()) : (spins += 1) {
            if ((spins & 0xff) == 0) {
                std.Thread.yield() catch {};
            } else {
                std.atomic.spinLoopHint();
            }
        }
    }

    fn unlockList(self: *RetainList) void {
        self.lock.unlock();
    }

    fn ensureCapacityLocked(self: *RetainList, additional: usize) error{OutOfMemory}!void {
        const spare = self.items.capacity - self.items.items.len;
        if (spare >= additional) return;
        const extra = @max(additional, retain_list_reserve_granularity);
        try self.items.ensureTotalCapacity(self.gpa, self.items.items.len + extra);
    }

    /// Record a reference owned by this realm. On OOM the reference is
    /// released immediately and the error propagated.
    pub fn track(self: *RetainList, s: *SharedBufferStorage) error{OutOfMemory}!void {
        self.lockList();
        defer self.unlockList();
        self.ensureCapacityLocked(1) catch |err| {
            s.release();
            return err;
        };
        self.items.appendAssumeCapacity(s);
    }

    /// Release exactly one realm-owned reference. Multiple wrappers may point
    /// at the same storage, so removing one list entry mirrors one dying
    /// wrapper cell rather than dropping every reference for that backing slab.
    pub fn releaseTracked(self: *RetainList, s: *SharedBufferStorage) bool {
        self.lockList();
        defer self.unlockList();
        for (self.items.items, 0..) |tracked, i| {
            if (tracked == s) {
                _ = self.items.swapRemove(i);
                s.release();
                return true;
            }
        }
        return false;
    }

    pub fn deinit(self: *RetainList) void {
        self.lockList();
        defer self.unlockList();
        for (self.items.items) |s| s.release();
        self.items.deinit(self.gpa);
    }
};

test "create/retain/release lifecycle" {
    const s = try SharedBufferStorage.create(16, null);
    try std.testing.expectEqual(@as(usize, 16), s.len());
    try std.testing.expect(!s.growable);
    _ = s.retain();
    s.release();
    s.release(); // frees
}

test "grow publishes monotonically within capacity" {
    const s = try SharedBufferStorage.create(8, 64);
    defer s.release();
    try std.testing.expect(s.growable);
    try s.grow(32);
    try std.testing.expectEqual(@as(usize, 32), s.len());
    try std.testing.expectError(error.OutOfRange, s.grow(16)); // shrink refused
    try std.testing.expectError(error.OutOfRange, s.grow(128)); // beyond capacity
    const fixed = try SharedBufferStorage.create(8, null);
    defer fixed.release();
    try std.testing.expectError(error.NotGrowable, fixed.grow(16));
}

test "zero-length storage is valid" {
    const s = try SharedBufferStorage.create(0, null);
    defer s.release();
    try std.testing.expectEqual(@as(usize, 0), s.slice().len);
}

test "RetainList releases exactly one tracked reference" {
    const a = std.testing.allocator;
    const s = try SharedBufferStorage.create(4, null);
    var list = RetainList{ .gpa = a };
    defer list.deinit();

    try list.track(s);
    try list.track(s.retain());
    try std.testing.expectEqual(@as(usize, 2), list.items.items.len);

    try std.testing.expect(list.releaseTracked(s));
    try std.testing.expectEqual(@as(usize, 1), list.items.items.len);
    try std.testing.expect(list.releaseTracked(s));
    try std.testing.expectEqual(@as(usize, 0), list.items.items.len);
    try std.testing.expect(!list.releaseTracked(s));
}

test "RetainList reserves fixed-size capacity chunks" {
    const a = std.testing.allocator;
    const s = try SharedBufferStorage.create(4, null);
    var list = RetainList{ .gpa = a };
    defer list.deinit();

    try list.track(s);
    try std.testing.expectEqual(@as(usize, 1), list.items.items.len);
    try std.testing.expect(list.items.capacity >= retain_list_reserve_granularity);

    const capacity_after_first = list.items.capacity;
    try list.track(s.retain());
    try std.testing.expectEqual(capacity_after_first, list.items.capacity);
}

test "cross-thread atomic increments land; refcount survives churn" {
    const s = try SharedBufferStorage.create(8, null);
    defer s.release();
    const iters = 10_000;
    const Worker = struct {
        fn run(storage: *SharedBufferStorage) void {
            const held = storage.retain();
            defer held.release();
            const counter: *u64 = @ptrCast(@alignCast(held.slab));
            for (0..iters) |_| _ = @atomicRmw(u64, counter, .Add, 1, .seq_cst);
        }
    };
    var threads: [4]std.Thread = undefined;
    for (&threads) |*t| t.* = try std.Thread.spawn(.{}, Worker.run, .{s});
    for (threads) |t| t.join();
    const counter: *u64 = @ptrCast(@alignCast(s.slab));
    try std.testing.expectEqual(@as(u64, 4 * iters), @atomicLoad(u64, counter, .seq_cst));
}

test "SharedBufferStorage retain refuses refcount overflow" {
    const s = try SharedBufferStorage.create(8, null);
    defer s.release();
    s.refcount.store(std.math.maxInt(usize), .release);
    try std.testing.expect(s.tryRetain() == null);
    try std.testing.expectEqual(std.math.maxInt(usize), s.refcount.load(.acquire));
    s.refcount.store(1, .release);
}
