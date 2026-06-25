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
//! Scope: this scans only the *current* (collecting) thread's stack. Other
//! shared-realm `Thread`s parked in native code are not yet scanned, so
//! mid-script collection stays gated to single-threaded execution
//! (`Context.collectMidScript`); the multi-thread safepoint protocol is M3.

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
    tl_park.lo = sp;
    tl_park.high = stack_high orelse sp;
    // seq_cst (not just release): under `parallel_js` the parked flag is one half
    // of a two-flag mutual exclusion with `Context.gc_collection_active` (the
    // parked-world collector), which needs a single total order. Stronger than
    // the GIL path needs (release/acquire), but uncontended there — no cost.
    @atomicStore(bool, &tl_park.parked, true, .seq_cst);
}

/// Mark this thread no longer parked, immediately after reacquiring the GIL.
pub fn endPark() void {
    @atomicStore(bool, &tl_park.parked, false, .seq_cst);
}

/// Whether the given (other thread's) record is currently parked.
pub fn isParked(rec: *const ParkScan) bool {
    return @atomicLoad(bool, &rec.parked, .seq_cst);
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
    const high = stack_high orelse return false;

    // Force callee-saved registers onto the stack inside the range we scan.
    var regs: [spill_count]usize = undefined;
    spillRegisters(&regs);

    // Real current stack pointer: the lowest live address. Everything from here
    // up to `high` is a live frame (downward-growing stacks: aarch64/x86_64).
    const sp = currentSp();
    if (sp == 0 or sp >= high) {
        std.mem.doNotOptimizeAway(&regs);
        return true;
    }

    // Word-align the low bound; `markConservativeWord` reads each slot as a
    // `usize`, so the start must be `@alignOf(usize)`-aligned.
    const word = @sizeOf(usize);
    const lo = std.mem.alignForward(usize, sp, word);
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
