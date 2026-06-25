//! Conservative native-stack root scanning for mid-script GC (issue #1 Phase 7,
//! docs/threads/P7-gc-design.md, M1 item (a)).
//!
//! The precise tracing GC (`gc.zig` + `../zig-gc`) can mark every heap reference
//! it knows about, but a *running* tree-walker holds live `Value`s as ordinary
//! Zig locals and machine registers that a precise collector cannot see. Until
//! now collection was therefore only sound at quiescent points (the top of
//! `evaluate`, microtask boundaries) where the native stack holds no mutator
//! `Value`s. This module lifts that restriction for the **collecting thread**:
//! it spills callee-saved registers, captures the current stack pointer, and
//! conservatively marks every machine word in the live stack range that points
//! into a managed GC cell (`zig-gc`'s `Visitor.markConservativeWord`).
//!
//! Over-scanning is safe — a stale word that happens to point at an otherwise
//! dead cell merely retains it for one extra cycle (a bounded false retention,
//! standard for conservative roots). Under-scanning frees live objects, so the
//! scanned range must cover every native frame that can hold a `Value`: from
//! the current SP up to the outermost JS-execution frame, captured by `enter()`.
//!
//! Scope: the collecting thread scans its own live stack (`scan`), and any peer
//! shared-realm `Thread` that has parked at a GIL checkpoint publishes its
//! frozen range so the collector can root it too (`beginPark` / `scanRecord`,
//! walked via `gil.park_records`). Each thread's range is clamped to its OS
//! stack bounds (`registerThreadBounds`) so the conservative pass never reads
//! outside the real stack mapping. Mid-script collection still requires every
//! peer to be parked (`Context.collectMidScript`); the non-blocking
//! safepoint protocol for *running* parallel mutators is M3
//! (`root_handshake.zig`).

const std = @import("std");
const builtin = @import("builtin");

/// High address (outermost JS frame) of the current thread's live stack region,
/// captured by `enter()` at the realm's execution entry points. `null` means no
/// scan boundary is registered, so `scan()` is a no-op and collection falls back
/// to its quiescent-only behavior — the safe default for any thread or entry
/// path that has not opted in.
threadlocal var stack_high: ?usize = null;

/// Whether this build target has a register-spill + SP-capture implementation.
/// On unsupported targets `scan()` refuses to run (returns false) so the engine
/// keeps mid-script collection disabled rather than risk missing a live `Value`
/// stranded in a callee-saved register.
pub const supported = switch (builtin.cpu.arch) {
    .aarch64, .aarch64_be, .x86_64 => true,
    else => false,
};

/// The current thread's OS stack bounds, discovered once via the platform
/// threading API: `base` is the highest address (the stack base; the stack
/// grows down from here) and `limit` is the lowest mapped address. `0` means
/// "not discovered yet" or "unavailable on this platform". Recorded lazily by
/// `enter()`, so every thread that runs JS — the main thread via `evaluate`, a
/// spawned `Thread` via `threadMain` — publishes its bounds the first time it
/// becomes a scan participant, without any extra wiring at the spawn sites.
///
/// Bounds make conservative scanning *safe* and more *complete* for arbitrary
/// native frames (issue #1, the Layer-C "per-thread stack-bound registration"
/// blocker in docs/threads/limits.md):
///   - Safety: the scan range is clamped to `[limit, base]`, so a stale or
///     unusual frame address can never make `markConservativeWords` read memory
///     outside the real stack mapping (which would fault or mark garbage).
///   - Completeness: a thread parked with no JS-entry frame registered
///     (`stack_high == null`) is scanned from its current SP up to the true
///     stack base instead of yielding an empty range, so native frames between
///     JS invocations still root their live cells.
threadlocal var os_stack_base: usize = 0;
threadlocal var os_stack_limit: usize = 0;

const StackBounds = struct { base: usize, limit: usize };

// macOS / BSD expose the base (highest) address and the size directly. On
// Darwin libSystem is always linked, so these resolve without an explicit
// `linkLibC`. The Linux path is gated on `link_libc` because the freestanding
// `std.Thread` build has no libc to resolve `pthread_getattr_np` against.
extern "c" fn pthread_get_stackaddr_np(thread: std.c.pthread_t) ?*anyopaque;
extern "c" fn pthread_get_stacksize_np(thread: std.c.pthread_t) usize;
extern "c" fn pthread_getattr_np(thread: std.c.pthread_t, attr: *std.c.pthread_attr_t) c_int;
extern "c" fn pthread_attr_getstack(attr: *const std.c.pthread_attr_t, addr: *?*anyopaque, size: *usize) c_int;
extern "c" fn pthread_attr_destroy(attr: *std.c.pthread_attr_t) c_int;

/// Query the running thread's OS stack bounds, or `null` if the platform does
/// not expose them. Only the branch matching `builtin.os.tag` is compiled, so
/// the Linux-only externs are never referenced on Darwin and vice versa.
fn queryOsBounds() ?StackBounds {
    switch (builtin.os.tag) {
        .macos, .ios, .tvos, .watchos, .visionos => {
            const self = std.c.pthread_self();
            const base = @intFromPtr(pthread_get_stackaddr_np(self) orelse return null);
            const size = pthread_get_stacksize_np(self);
            if (base == 0 or size == 0 or size > base) return null;
            return .{ .base = base, .limit = base - size };
        },
        .linux => {
            if (!builtin.link_libc) return null;
            var attr: std.c.pthread_attr_t = undefined;
            if (pthread_getattr_np(std.c.pthread_self(), &attr) != 0) return null;
            defer _ = pthread_attr_destroy(&attr);
            var addr: ?*anyopaque = null;
            var size: usize = 0;
            if (pthread_attr_getstack(&attr, &addr, &size) != 0) return null;
            // Linux reports the *lowest* address; the base is `addr + size`.
            const low = @intFromPtr(addr orelse return null);
            if (low == 0 or size == 0) return null;
            return .{ .base = low + size, .limit = low };
        },
        else => return null,
    }
}

/// Discover and record this thread's OS stack bounds. Idempotent and cheap
/// after the first successful call (the platform query is skipped once `base`
/// is known). Safe to call from any thread that may become a GC scan
/// participant; a platform without bounds support leaves the fields `0` and the
/// scanner falls back to its frame-address-only behavior.
pub fn registerThreadBounds() void {
    if (os_stack_base != 0) return;
    if (queryOsBounds()) |b| {
        os_stack_limit = b.limit;
        // Publish `base` last: a non-zero `base` is the "bounds ready" flag.
        @atomicStore(usize, &os_stack_base, b.base, .release);
    }
}

/// Clamp a `[lo, high]` conservative-scan range to the thread's known OS stack
/// bounds. A `high` of 0 with known bounds falls back to the stack base so a
/// frame-less parked thread still scans its native frames. Returns the clamped
/// pair; when no bounds are known the range is returned unchanged.
fn clampToBounds(lo: usize, high: usize) struct { lo: usize, high: usize } {
    const base = os_stack_base;
    if (base == 0) return .{ .lo = lo, .high = high };
    var h = if (high == 0) base else high;
    if (h > base) h = base;
    var l = lo;
    if (l < os_stack_limit) l = os_stack_limit;
    return .{ .lo = l, .high = h };
}

/// Register the current frame as the high boundary of the stack region to scan.
/// Call at the outermost JS-execution entry on a thread (`evaluate`,
/// `evaluateModule`, a spawned `Thread`'s body) so every nested interpreter
/// frame falls inside `[sp, stack_high]` at collection time. Returns the prior
/// boundary; pass it to `leave()` so nested entry points restore it.
///
/// `frame_addr` should be `@frameAddress()` of the entry function — a high
/// address on the (downward-growing) native stack that stays valid for the
/// lifetime of that call, i.e. for as long as any nested frame can run JS.
pub fn enter(frame_addr: usize) ?usize {
    // Lazily record this thread's OS stack bounds the first time it becomes a
    // scan participant. `enter()` is the one call every JS-running thread makes
    // at its outermost frame, so no extra wiring is needed at the spawn sites.
    registerThreadBounds();
    const prev = stack_high;
    stack_high = frame_addr;
    return prev;
}

/// Restore the boundary saved by a matching `enter()`.
pub fn leave(prev: ?usize) void {
    stack_high = prev;
}

/// Whether a scan boundary is currently registered on this thread.
pub fn active() bool {
    return stack_high != null;
}

/// A parked thread's published conservative-scan range, so a *different* thread
/// holding the GIL can root the parked thread's native stack + callee-saved
/// registers during a mid-script collection (issue #1 Phase 7, the multi-thread
/// safepoint protocol). Each thread owns one of these as a threadlocal and
/// registers its address with the `Gil` (see `gil.zig`); the collector walks the
/// registry. `parked` gates whether the range is meaningful. All fields are
/// written before the parking thread releases the GIL and read after the
/// collector acquires it, so the GIL mutex supplies the happens-before edge.
pub const ParkScan = struct {
    parked: bool = false,
    lo: usize = 0,
    high: usize = 0,
    regs: [spill_count]usize = @splat(0),
};

threadlocal var tl_park: ParkScan = .{};

/// This thread's park record (stable address for the thread's lifetime).
pub fn parkRecord() *ParkScan {
    return &tl_park;
}

/// Publish this thread's live stack range + spilled callee-saved registers and
/// mark it parked, immediately before releasing the GIL to block. The collector
/// scans `[lo, high]` plus `regs`. A no-op-ish publish (empty range) is fine when
/// no boundary is registered — the collector just finds nothing.
pub fn beginPark() void {
    spillRegisters(&tl_park.regs);
    const sp = currentSp();
    // Clamp to the OS stack bounds: defends the collector against a wild `high`
    // and, when this thread parked with no JS-entry frame, falls back to the
    // real stack base instead of publishing an empty `[sp, sp]` range.
    const r = clampToBounds(sp, stack_high orelse 0);
    tl_park.lo = r.lo;
    tl_park.high = if (r.high == 0) sp else r.high;
    @atomicStore(bool, &tl_park.parked, true, .release);
}

/// Mark this thread no longer parked, immediately after reacquiring the GIL.
pub fn endPark() void {
    @atomicStore(bool, &tl_park.parked, false, .release);
}

/// Whether the given (other thread's) record is currently parked.
pub fn isParked(rec: *const ParkScan) bool {
    return @atomicLoad(bool, &rec.parked, .acquire);
}

/// Conservatively mark a parked thread's published stack range + registers.
/// Mirrors `scan()` but operates on a foreign, frozen stack (the parked thread
/// cannot run until the collecting thread releases the GIL).
pub fn scanRecord(rec: *const ParkScan, v: anytype) void {
    for (rec.regs) |word| v.markConservativeWord(word);
    if (rec.high <= rec.lo) return;
    const wsz = @sizeOf(usize);
    const lo = std.mem.alignForward(usize, rec.lo, wsz);
    if (lo >= rec.high) return;
    const words = (rec.high - lo) / wsz;
    v.markConservativeWords(@ptrFromInt(lo), words);
}

/// Callee-saved general-purpose registers per target. A live `Value`'s `*Object`
/// word can sit in one of these across the collection call, where the ordinary
/// stack scan would miss it; we spill them into a stack buffer (inside the
/// scanned range) so the conservative pass picks them up.
const spill_count: usize = switch (builtin.cpu.arch) {
    .aarch64, .aarch64_be => 11, // x19–x28, x29 (fp)
    .x86_64 => 6, // rbx, rbp, r12–r15
    else => 1,
};

inline fn spillRegisters(buf: *[spill_count]usize) void {
    switch (builtin.cpu.arch) {
        .aarch64, .aarch64_be => asm volatile (
            \\stp x19, x20, [%[b], #0]
            \\stp x21, x22, [%[b], #16]
            \\stp x23, x24, [%[b], #32]
            \\stp x25, x26, [%[b], #48]
            \\stp x27, x28, [%[b], #64]
            \\str x29, [%[b], #80]
            :
            : [b] "r" (buf),
            : .{ .memory = true }),
        // Spill each callee-saved register to a memory output (a per-register
        // `=m` slot, so the source registers are never clobbered mid-sequence),
        // then copy into `buf`. Zig's inline-asm output grammar only accepts a
        // plain identifier, and LLVM rejects the `off(%[b])` displacement-from-a-
        // `"r"`-operand form, so a stack scalar per register is the portable way.
        // This branch never compiled before (the engine had only been built on
        // aarch64, where the comptime switch picks the branch above).
        .x86_64 => {
            var r0: usize = undefined;
            var r1: usize = undefined;
            var r2: usize = undefined;
            var r3: usize = undefined;
            var r4: usize = undefined;
            var r5: usize = undefined;
            asm volatile (
                \\movq %%rbx, %[r0]
                \\movq %%rbp, %[r1]
                \\movq %%r12, %[r2]
                \\movq %%r13, %[r3]
                \\movq %%r14, %[r4]
                \\movq %%r15, %[r5]
                : [r0] "=m" (r0),
                  [r1] "=m" (r1),
                  [r2] "=m" (r2),
                  [r3] "=m" (r3),
                  [r4] "=m" (r4),
                  [r5] "=m" (r5),
                :
                : .{ .memory = true });
            buf[0] = r0;
            buf[1] = r1;
            buf[2] = r2;
            buf[3] = r3;
            buf[4] = r4;
            buf[5] = r5;
        },
        else => buf[0] = 0,
    }
}

inline fn currentSp() usize {
    return switch (builtin.cpu.arch) {
        .aarch64, .aarch64_be => asm volatile ("mov %[o], sp"
            : [o] "=r" (-> usize),
        ),
        .x86_64 => asm volatile ("movq %%rsp, %[o]"
            : [o] "=r" (-> usize),
        ),
        else => @intFromPtr(@as(*const u8, @ptrCast(&stack_high))),
    };
}

/// True when the current native stack pointer is within `margin` bytes of this
/// thread's registered OS stack limit — i.e. a few more native frames could
/// run off the end and fault the guard page. The interpreter's call guard uses
/// this to throw `RangeError: Maximum call stack size exceeded` *before* the
/// tree-walker's native recursion overflows, turning a process-killing
/// segfault into a catchable JS error on whichever thread is recursing.
///
/// Returns false when bounds are unknown (no `registerThreadBounds` yet) or the
/// target is unsupported, so the caller's logical depth counter stays the sole
/// guard there. Because each JS call uses only a handful of small native frames
/// in a normal build, the depth counter is reached long before the stack nears
/// its limit; this check only bites when frames are unusually large (e.g. a
/// ThreadSanitizer build, deep host callbacks), exactly where the fixed depth
/// limit would otherwise let the native stack overflow first.
pub fn nearLimit(margin: usize) bool {
    if (!supported) return false;
    const limit = os_stack_limit;
    if (limit == 0) return false;
    const sp = currentSp();
    // Downward-growing stack: the closer `sp` is to `limit`, the less headroom.
    return sp <= limit +| margin;
}

/// Conservatively mark the current thread's live stack as GC roots, using
/// `v.markConservativeWords` from the `zig-gc` `Visitor`. Returns false (a
/// no-op) when no boundary is registered or the target is unsupported — the
/// caller treats that as "stack roots unavailable" and must not collect while
/// the native stack holds live `Value`s.
///
/// Callee-saved registers are spilled into a local buffer that lives within the
/// scanned range, and caller-saved registers holding live values across the
/// collection call are spilled to the stack by the ABI, so both are covered.
pub fn scan(v: anytype) bool {
    if (!supported) return false;
    // A scan needs an upper bound: either the registered JS-entry frame or, for
    // a thread with no frame registered, the OS stack base. With neither, fall
    // back to quiescent-only behavior.
    if (stack_high == null and os_stack_base == 0) return false;

    // Force callee-saved registers onto the stack inside the range we scan.
    var regs: [spill_count]usize = undefined;
    spillRegisters(&regs);

    // Real current stack pointer: the lowest live address. Everything from here
    // up to `high` is a live frame (downward-growing stacks: aarch64/x86_64).
    const sp = currentSp();
    const clamped = clampToBounds(sp, stack_high orelse 0);
    const lo_raw = clamped.lo;
    const high = clamped.high;
    if (sp == 0 or high == 0 or lo_raw >= high) {
        std.mem.doNotOptimizeAway(&regs);
        return true;
    }

    // Word-align the low bound; `markConservativeWord` reads each slot as a
    // `usize`, so the start must be `@alignOf(usize)`-aligned.
    const word = @sizeOf(usize);
    const lo = std.mem.alignForward(usize, lo_raw, word);
    if (lo >= high) {
        std.mem.doNotOptimizeAway(&regs);
        return true;
    }
    const words = (high - lo) / word;
    v.markConservativeWords(@ptrFromInt(lo), words);

    // Keep the spill buffer materialized until after the scan reads it.
    std.mem.doNotOptimizeAway(&regs);
    return true;
}

test "stack_scan: enter/leave nest and restore" {
    try std.testing.expect(!active());
    var anchor: usize = undefined;
    const prev = enter(@intFromPtr(&anchor));
    try std.testing.expect(active());
    try std.testing.expect(prev == null);
    leave(prev);
    try std.testing.expect(!active());
}

test "stack_scan: OS bounds contain the live frame" {
    // Skip on platforms where bounds discovery is unavailable.
    registerThreadBounds();
    if (os_stack_base == 0) return error.SkipZigTest;
    try std.testing.expect(os_stack_limit < os_stack_base);
    var anchor: usize = undefined;
    const frame = @intFromPtr(&anchor);
    try std.testing.expect(frame >= os_stack_limit);
    try std.testing.expect(frame < os_stack_base);
    // The current SP is also inside the bounds and below the frame address.
    if (supported) {
        const sp = currentSp();
        try std.testing.expect(sp >= os_stack_limit and sp < os_stack_base);
        try std.testing.expect(sp <= frame);
    }
}

test "stack_scan: clampToBounds is a no-op for an in-range range but caps a wild high" {
    registerThreadBounds();
    if (os_stack_base == 0) return error.SkipZigTest;
    const base = os_stack_base;
    const limit = os_stack_limit;
    // In-range range passes through unchanged.
    const mid = limit + (base - limit) / 2;
    const ok = clampToBounds(mid, base - 16);
    try std.testing.expectEqual(mid, ok.lo);
    try std.testing.expectEqual(base - 16, ok.high);
    // A high above the base is capped to the base; a lo below the limit is
    // raised to the limit — the conservative pass can then never read outside
    // the real stack mapping.
    const wild = clampToBounds(limit -% 4096, base + 4096);
    try std.testing.expectEqual(limit, wild.lo);
    try std.testing.expectEqual(base, wild.high);
    // A zero high (no JS-entry frame) falls back to the stack base.
    const frameless = clampToBounds(mid, 0);
    try std.testing.expectEqual(base, frameless.high);
}

test "stack_scan: park publishes a bounded, non-empty range" {
    registerThreadBounds();
    if (os_stack_base == 0) return error.SkipZigTest;
    var anchor: usize = undefined;
    const saved = enter(@intFromPtr(&anchor));
    defer leave(saved);
    beginPark();
    defer endPark();
    const rec = parkRecord();
    try std.testing.expect(isParked(rec));
    try std.testing.expect(rec.lo >= os_stack_limit);
    try std.testing.expect(rec.high <= os_stack_base);
    try std.testing.expect(rec.high > rec.lo);
}
