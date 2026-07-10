//! GC allocation and Context lifecycle profile.
//!
//! `zig build gc-profile`
//!
//! This is the local baseline for issue #1's GC allocation/lifecycle work. It
//! measures the embedder-visible costs that remain after no-GIL correctness:
//! creating/destroying contexts and running allocation-heavy scripts in arena,
//! GC, no-GIL threaded, and GIL-serialized threaded modes.

const std = @import("std");
const js = @import("js");

const Mode = struct {
    name: []const u8,
    options: js.Context.Options,
};

const modes = [_]Mode{
    .{ .name = "arena", .options = .{} },
    .{ .name = "gc", .options = .{ .enable_gc = true } },
    .{ .name = "threaded no-gil", .options = .{ .enable_threads = true } },
    .{ .name = "threaded gil", .options = .{ .enable_threads = true, .gil = true } },
};

const gc_backing_source =
    \\(function(){
    \\  var keep = [];
    \\  for (var i = 0; i < 10000; i = i + 1)
    \\    keep.push({ i: i, pair: { j: i + 1 }, text: 'gc-backing-' + i });
    \\  return keep.length;
    \\})()
;

fn nowNs(io: std.Io) i96 {
    return std.Io.Clock.Timestamp.now(io, .awake).raw.nanoseconds;
}

fn makeContext(gpa: std.mem.Allocator, mode: Mode) !*js.Context {
    return js.Context.createWith(gpa, mode.options);
}

const LifecycleTimes = struct {
    create_ns: u64 = 0,
    destroy_ns: u64 = 0,

    fn total(self: LifecycleTimes) u64 {
        return self.create_ns + self.destroy_ns;
    }
};

const WorkloadDestroyTimes = struct {
    destroy_live_ns: u64 = 0,
    precollect_ns: u64 = 0,
    destroy_after_collect_ns: u64 = 0,
};

fn timeLifecycle(gpa: std.mem.Allocator, io: std.Io, mode: Mode, rounds: usize) !LifecycleTimes {
    var times: LifecycleTimes = .{};
    var i: usize = 0;
    while (i < rounds) : (i += 1) {
        const create_t0 = nowNs(io);
        const ctx = try makeContext(gpa, mode);
        times.create_ns += @intCast(nowNs(io) - create_t0);
        const destroy_t0 = nowNs(io);
        ctx.destroy();
        times.destroy_ns += @intCast(nowNs(io) - destroy_t0);
    }
    return times;
}

fn timeWorkloadDestroy(gpa: std.mem.Allocator, io: std.Io, mode: Mode, source: []const u8, rounds: usize) !WorkloadDestroyTimes {
    var times: WorkloadDestroyTimes = .{};
    var i: usize = 0;
    while (i < rounds) : (i += 1) {
        {
            const ctx = try makeContext(gpa, mode);
            errdefer ctx.destroy();
            _ = try ctx.evaluate(source);
            const t0 = nowNs(io);
            ctx.destroy();
            times.destroy_live_ns += @intCast(nowNs(io) - t0);
        }

        if (!modeUsesGc(mode)) continue;

        {
            const ctx = try makeContext(gpa, mode);
            errdefer ctx.destroy();
            _ = try ctx.evaluate(source);
            const collect_t0 = nowNs(io);
            ctx.collectGarbage();
            times.precollect_ns += @intCast(nowNs(io) - collect_t0);
            const destroy_t0 = nowNs(io);
            ctx.destroy();
            times.destroy_after_collect_ns += @intCast(nowNs(io) - destroy_t0);
        }
    }
    return times;
}

fn timeScript(gpa: std.mem.Allocator, io: std.Io, mode: Mode, source: []const u8, rounds: usize) !u64 {
    const ctx = try makeContext(gpa, mode);
    defer ctx.destroy();

    _ = try ctx.evaluate(source);
    const t0 = nowNs(io);
    var i: usize = 0;
    while (i < rounds) : (i += 1) {
        _ = try ctx.evaluate(source);
    }
    return @intCast(nowNs(io) - t0);
}

fn timeTaskRecreate(gpa: std.mem.Allocator, io: std.Io, mode: Mode, source: []const u8, rounds: usize) !u64 {
    const t0 = nowNs(io);
    var i: usize = 0;
    while (i < rounds) : (i += 1) {
        const ctx = try makeContext(gpa, mode);
        errdefer ctx.destroy();
        _ = try ctx.evaluate(source);
        ctx.destroy();
    }
    return @intCast(nowNs(io) - t0);
}

fn timeTaskReuse(gpa: std.mem.Allocator, io: std.Io, mode: Mode, source: []const u8, rounds: usize) !u64 {
    const ctx = try makeContext(gpa, mode);
    defer ctx.destroy();

    _ = try ctx.evaluate(source);
    const t0 = nowNs(io);
    var i: usize = 0;
    while (i < rounds) : (i += 1) {
        _ = try ctx.evaluate(source);
        if ((i + 1) % 10 == 0) ctx.collectGarbage();
    }
    return @intCast(nowNs(io) - t0);
}

fn timeExplicitGc(gpa: std.mem.Allocator, io: std.Io, mode: Mode, rounds: usize) !?u64 {
    if (!mode.options.enable_gc and !(mode.options.enable_threads and !mode.options.gil)) return null;

    const ctx = try makeContext(gpa, mode);
    defer ctx.destroy();
    _ = try ctx.evaluate(
        \\var keep = [];
        \\for (var i = 0; i < 4000; i = i + 1)
        \\  keep.push({ i: i, pair: { j: i + 1 } });
    );

    const t0 = nowNs(io);
    var i: usize = 0;
    while (i < rounds) : (i += 1) ctx.collectGarbage();
    return @intCast(nowNs(io) - t0);
}

fn printLifecycle(gpa: std.mem.Allocator, io: std.Io) !void {
    const rounds: usize = 60;
    std.debug.print("\nContext create/destroy ({d} rounds)\n", .{rounds});
    std.debug.print("{s:<18} {s:>14} {s:>14} {s:>14} {s:>14}\n", .{
        "mode",
        "total ns",
        "ns/context",
        "create ns",
        "destroy ns",
    });
    for (modes) |mode| {
        const times = try timeLifecycle(gpa, io, mode, rounds);
        const total = times.total();
        std.debug.print("{s:<18} {d:>14} {d:>14} {d:>14} {d:>14}\n", .{
            mode.name,
            total,
            total / rounds,
            times.create_ns / rounds,
            times.destroy_ns / rounds,
        });
    }
}

fn printWorkloadDestroy(gpa: std.mem.Allocator, io: std.Io) !void {
    const rounds: usize = 20;
    std.debug.print("\nWorkload destroy attribution ({d} rounds, same object-heavy script)\n", .{rounds});
    std.debug.print("{s:<18} {s:>18} {s:>18} {s:>22} {s:>10}\n", .{
        "mode",
        "live destroy ns",
        "precollect ns",
        "post-collect destroy ns",
        "ratio",
    });
    for (modes) |mode| {
        const times = try timeWorkloadDestroy(gpa, io, mode, gc_backing_source, rounds);
        const live_per = times.destroy_live_ns / rounds;
        if (!modeUsesGc(mode)) {
            std.debug.print("{s:<18} {d:>18} {s:>18} {s:>22} {s:>10}\n", .{
                mode.name,
                live_per,
                "-",
                "-",
                "-",
            });
            continue;
        }

        const collect_per = times.precollect_ns / rounds;
        const post_per = times.destroy_after_collect_ns / rounds;
        const ratio_x100 = if (post_per == 0) @as(u64, 0) else (live_per * 100) / post_per;
        std.debug.print("{s:<18} {d:>18} {d:>18} {d:>22} {d:>6}.{d:0>2}x\n", .{
            mode.name,
            live_per,
            collect_per,
            post_per,
            ratio_x100 / 100,
            ratio_x100 % 100,
        });
    }
}

fn printAllocation(gpa: std.mem.Allocator, io: std.Io) !void {
    const object_rounds: usize = 8;
    const block_rounds: usize = 8;
    const object_source =
        \\(function(){
        \\  var keep = [];
        \\  for (var i = 0; i < 12000; i = i + 1)
        \\    keep.push({ i: i, x: i + 1, nested: { y: i + 2 } });
        \\  return keep.length;
        \\})()
    ;
    const block_source =
        \\(function(){
        \\  var sum = 0;
        \\  for (var i = 0; i < 20000; i = i + 1) {
        \\    let x = i + 1;
        \\    let y = x + 1;
        \\    sum = sum + y;
        \\  }
        \\  return sum;
        \\})()
    ;

    std.debug.print("\nAllocation-heavy scripts\n", .{});
    std.debug.print("{s:<18} {s:>16} {s:>16}\n", .{ "mode", "objects ns/run", "let ns/run" });
    for (modes) |mode| {
        const object_ns = try timeScript(gpa, io, mode, object_source, object_rounds);
        const block_ns = try timeScript(gpa, io, mode, block_source, block_rounds);
        std.debug.print("{s:<18} {d:>16} {d:>16}\n", .{
            mode.name,
            object_ns / object_rounds,
            block_ns / block_rounds,
        });
    }
}

fn printExplicitGc(gpa: std.mem.Allocator, io: std.Io) !void {
    const rounds: usize = 20;
    std.debug.print("\nExplicit collectGarbage ({d} rounds, GC modes only)\n", .{rounds});
    std.debug.print("{s:<18} {s:>14} {s:>14}\n", .{ "mode", "total ns", "ns/collect" });
    for (modes) |mode| {
        if (try timeExplicitGc(gpa, io, mode, rounds)) |ns| {
            std.debug.print("{s:<18} {d:>14} {d:>14}\n", .{ mode.name, ns, ns / rounds });
        }
    }
}

fn printGcBackingBaseline(gpa: std.mem.Allocator) !void {
    std.debug.print("\nGC cell backing baseline (empty context)\n", .{});
    std.debug.print("{s:<18} {s:>8} {s:>10} {s:>10} {s:>12}\n", .{
        "mode",
        "chunks",
        "cap slots",
        "free slots",
        "live create",
    });
    for (modes) |mode| {
        const ctx = try makeContext(gpa, mode);
        defer ctx.destroy();
        const backing = ctx.gc_cell_backing orelse continue;
        const created = backing.stats();
        std.debug.print("{s:<18} {d:>8} {d:>10} {d:>10} {d:>12}\n", .{
            mode.name,
            created.chunks,
            created.capacity_slots,
            created.free_slots,
            created.live_slots,
        });
    }
}

fn printGcBackingBaselineBuckets(gpa: std.mem.Allocator) !void {
    std.debug.print("\nGC cell backing baseline buckets (empty context)\n", .{});
    std.debug.print("{s:<18} {s:>6} {s:>8} {s:>10} {s:>10} {s:>10} {s:>10} {s:>10} {s:>10} {s:>10}\n", .{
        "mode",
        "slot",
        "chunks",
        "cap",
        "issued",
        "fresh",
        "reused",
        "freed",
        "free",
        "live",
    });
    for (modes) |mode| {
        const ctx = try makeContext(gpa, mode);
        defer ctx.destroy();
        const backing = ctx.gc_cell_backing orelse continue;
        const buckets = backing.bucketStats();
        for (buckets) |bucket| {
            if (bucket.chunks == 0) continue;
            std.debug.print("{s:<18} {d:>6} {d:>8} {d:>10} {d:>10} {d:>10} {d:>10} {d:>10} {d:>10} {d:>10}\n", .{
                mode.name,
                bucket.slot_size,
                bucket.chunks,
                bucket.capacity_slots,
                bucket.issued_slots,
                bucket.fresh_allocs,
                bucket.reused_allocs,
                bucket.freed_slots,
                bucket.free_slots,
                bucket.live_slots,
            });
        }
    }
}

fn printGcBacking(gpa: std.mem.Allocator) !void {
    std.debug.print("\nGC cell backing attribution (one object-heavy script + collect)\n", .{});
    std.debug.print("{s:<18} {s:>8} {s:>10} {s:>12} {s:>12} {s:>14} {s:>12}\n", .{
        "mode",
        "chunks",
        "cap slots",
        "live create",
        "live script",
        "free collect",
        "live collect",
    });
    for (modes) |mode| {
        const ctx = try makeContext(gpa, mode);
        defer ctx.destroy();
        const backing = ctx.gc_cell_backing orelse continue;
        const created = backing.stats();
        _ = try ctx.evaluate(gc_backing_source);
        const after_script = backing.stats();
        ctx.collectGarbage();
        const after_collect = backing.stats();
        std.debug.print("{s:<18} {d:>8} {d:>10} {d:>12} {d:>12} {d:>14} {d:>12}\n", .{
            mode.name,
            after_collect.chunks,
            after_collect.capacity_slots,
            created.live_slots,
            after_script.live_slots,
            after_collect.free_slots,
            after_collect.live_slots,
        });
    }
}

fn printGcBackingBuckets(gpa: std.mem.Allocator) !void {
    std.debug.print("\nGC cell backing buckets (same object-heavy script + collect)\n", .{});
    std.debug.print("{s:<18} {s:>6} {s:>8} {s:>10} {s:>10} {s:>10} {s:>10} {s:>10} {s:>10} {s:>10}\n", .{
        "mode",
        "slot",
        "chunks",
        "cap",
        "issued",
        "fresh",
        "reused",
        "freed",
        "free",
        "live",
    });
    for (modes) |mode| {
        const ctx = try makeContext(gpa, mode);
        defer ctx.destroy();
        const backing = ctx.gc_cell_backing orelse continue;
        _ = try ctx.evaluate(gc_backing_source);
        ctx.collectGarbage();
        const buckets = backing.bucketStats();
        for (buckets) |bucket| {
            if (bucket.chunks == 0) continue;
            std.debug.print("{s:<18} {d:>6} {d:>8} {d:>10} {d:>10} {d:>10} {d:>10} {d:>10} {d:>10} {d:>10}\n", .{
                mode.name,
                bucket.slot_size,
                bucket.chunks,
                bucket.capacity_slots,
                bucket.issued_slots,
                bucket.fresh_allocs,
                bucket.reused_allocs,
                bucket.freed_slots,
                bucket.free_slots,
                bucket.live_slots,
            });
        }
    }
}

const ChurnTotals = struct {
    fresh: usize = 0,
    reused: usize = 0,
    freed: usize = 0,
    chunks: usize = 0,
    live: usize = 0,
};

fn bucketChurnTotals(before: anytype, after: anytype) ChurnTotals {
    var totals = ChurnTotals{};
    for (before, after) |b, a| {
        totals.fresh += a.fresh_allocs - b.fresh_allocs;
        totals.reused += a.reused_allocs - b.reused_allocs;
        totals.freed += a.freed_slots - b.freed_slots;
        totals.chunks += a.chunks;
        totals.live += a.live_slots;
    }
    return totals;
}

fn printGcChurnReuse(gpa: std.mem.Allocator, io: std.Io) !void {
    const rounds: usize = 8;
    const source =
        \\(function(){
        \\  for (var round = 0; round < 4; round = round + 1) {
        \\    var keep = [];
        \\    for (var i = 0; i < 3500; i = i + 1)
        \\      keep.push({ i: i, pair: { j: i + 1 }, values: [i, i + 1, i + 2] });
        \\  }
        \\  return 1;
        \\})()
    ;

    std.debug.print("\nGC allocation churn reuse ({d} allocate+collect rounds)\n", .{rounds});
    std.debug.print("{s:<18} {s:>14} {s:>12} {s:>12} {s:>12} {s:>10} {s:>10} {s:>9}\n", .{
        "mode",
        "ns/round",
        "fresh",
        "reused",
        "freed",
        "chunks",
        "live",
        "reuse",
    });
    for (modes) |mode| {
        if (!modeUsesGc(mode)) continue;
        const ctx = try makeContext(gpa, mode);
        defer ctx.destroy();
        const backing = ctx.gc_cell_backing orelse continue;
        const before = backing.bucketStats();
        const t0 = nowNs(io);
        var i: usize = 0;
        while (i < rounds) : (i += 1) {
            _ = try ctx.evaluate(source);
            ctx.collectGarbage();
        }
        const ns: u64 = @intCast(nowNs(io) - t0);
        const after = backing.bucketStats();
        const totals = bucketChurnTotals(before, after);
        const allocs = totals.fresh + totals.reused;
        const reuse_x100 = if (allocs == 0) @as(usize, 0) else (totals.reused * 10000) / allocs;
        std.debug.print("{s:<18} {d:>14} {d:>12} {d:>12} {d:>12} {d:>10} {d:>10} {d:>5}.{d:0>2}%\n", .{
            mode.name,
            ns / rounds,
            totals.fresh,
            totals.reused,
            totals.freed,
            totals.chunks,
            totals.live,
            reuse_x100 / 100,
            reuse_x100 % 100,
        });
    }
}

fn modeUsesGc(mode: Mode) bool {
    return mode.options.enable_gc or (mode.options.enable_threads and !mode.options.gil);
}

fn destroyFinalizerStats(gpa: std.mem.Allocator, mode: Mode, source: ?[]const u8) !js.Context.GcFinalizerStats {
    var ctx = try makeContext(gpa, mode);
    errdefer ctx.destroy();
    if (source) |script| _ = try ctx.evaluate(script);

    var stats = js.Context.GcFinalizerStats{};
    ctx.gc_finalizer_stats_out = &stats;
    ctx.destroy();
    return stats;
}

fn printGcFinalizerTable(gpa: std.mem.Allocator, title: []const u8, source: ?[]const u8) !void {
    std.debug.print("\n{s}\n", .{title});
    std.debug.print("{s:<18} {s:>8} {s:>9} {s:>8} {s:>8} {s:>8} {s:>8} {s:>9} {s:>9} {s:>8} {s:>8}\n", .{
        "mode",
        "cells",
        "skipfree",
        "objects",
        "envs",
        "funcs",
        "prom",
        "backing",
        "buffers",
        "shared",
        "react",
    });
    for (modes) |mode| {
        if (!modeUsesGc(mode)) continue;
        const stats = try destroyFinalizerStats(gpa, mode, source);
        std.debug.print("{s:<18} {d:>8} {d:>9} {d:>8} {d:>8} {d:>8} {d:>8} {d:>9} {d:>9} {d:>8} {d:>8}\n", .{
            mode.name,
            stats.cells,
            stats.bulk_cell_frees_skipped,
            stats.objects,
            stats.environments,
            stats.functions + stats.bound_functions,
            stats.promises,
            stats.object_backing_releases,
            stats.array_buffers,
            stats.shared_array_buffers,
            stats.promise_reactions,
        });
    }
}

fn printGcFinalizers(gpa: std.mem.Allocator) !void {
    const source =
        \\(function(){
        \\  var keep = [];
        \\  for (var i = 0; i < 2500; i = i + 1) {
        \\    keep.push({
        \\      i: i,
        \\      pair: { j: i + 1 },
        \\      values: [i, i + 1, i + 2],
        \\      buffer: new ArrayBuffer(16)
        \\    });
        \\  }
        \\  return keep.length;
        \\})()
    ;

    try printGcFinalizerTable(gpa, "GC finalizer attribution (destroy empty context)", null);
    try printGcFinalizerTable(gpa, "GC finalizer attribution (destroy after object-heavy script)", source);
}

fn printTaskLifecycle(gpa: std.mem.Allocator, io: std.Io) !void {
    const rounds: usize = 40;
    const task_source =
        \\(function(){
        \\  var keep = [];
        \\  for (var i = 0; i < 600; i = i + 1)
        \\    keep.push({ i: i, pair: { j: i + 1 } });
        \\  return keep.length;
        \\})()
    ;

    std.debug.print("\nEmbedder task lifecycle ({d} tasks)\n", .{rounds});
    std.debug.print("{s:<18} {s:>18} {s:>18} {s:>10}\n", .{ "mode", "recreate ns/task", "reuse+gc ns/task", "ratio" });
    for (modes) |mode| {
        const recreate_ns = try timeTaskRecreate(gpa, io, mode, task_source, rounds);
        const reuse_ns = try timeTaskReuse(gpa, io, mode, task_source, rounds);
        const recreate_per = recreate_ns / rounds;
        const reuse_per = reuse_ns / rounds;
        const ratio_x100 = if (reuse_per == 0) @as(u64, 0) else (recreate_per * 100) / reuse_per;
        std.debug.print("{s:<18} {d:>18} {d:>18} {d:>6}.{d:0>2}x\n", .{
            mode.name,
            recreate_per,
            reuse_per,
            ratio_x100 / 100,
            ratio_x100 % 100,
        });
    }
}

fn printNursery(gpa: std.mem.Allocator, io: std.Io) !void {
    const source =
        \\globalThis.nurseryProfileKeep = [];
        \\(function () {
        \\  for (let i = 0; i < 512; i++) {
        \\    const value = { i: i, nested: { value: i + 1 } };
        \\    if ((i & 3) === 0) nurseryProfileKeep.push(value);
        \\  }
        \\})()
    ;

    std.debug.print("\nQuiescent nursery cycle (512 object graphs; 1/4 retained)\n", .{});
    std.debug.print("{s:<18} {s:>12} {s:>10} {s:>10} {s:>10} {s:>12} {s:>10} {s:>10}\n", .{
        "mode",
        "pause ns",
        "young in",
        "reclaimed",
        "promoted",
        "prom bytes",
        "minor",
        "full",
    });
    for (modes) |mode| {
        if (!modeUsesGc(mode)) continue;
        const ctx = try makeContext(gpa, mode);
        defer ctx.destroy();
        ctx.collectGarbage();
        const heap = ctx.gc.?;
        // Isolate the nursery boundary in this row. Single-mutator mode can
        // otherwise start a full incremental cycle mid-script when total bytes
        // cross the old-space threshold before the quiescent minor checkpoint.
        heap.threshold_bytes = std.math.maxInt(usize);
        const minor_before = heap.minor_collections;
        const full_before = heap.full_collections;
        const promoted_before = heap.promoted_cells;
        const promoted_bytes_before = heap.promoted_bytes;
        _ = try ctx.evaluate(source);
        const young_in = heap.young_cells;
        const t0 = nowNs(io);
        _ = try ctx.evaluate("0"); // collection runs at the quiescent entry boundary
        const pause_ns: u64 = @intCast(nowNs(io) - t0);
        const promoted = heap.promoted_cells - promoted_before;
        const minor_delta = heap.minor_collections - minor_before;
        const full_delta = heap.full_collections - full_before;
        const reclaimed = if (minor_delta + full_delta > 0) young_in -| promoted else 0;
        std.debug.print("{s:<18} {d:>12} {d:>10} {d:>10} {d:>10} {d:>12} {d:>10} {d:>10}\n", .{
            mode.name,
            pause_ns,
            young_in,
            reclaimed,
            promoted,
            heap.promoted_bytes - promoted_bytes_before,
            minor_delta,
            full_delta,
        });
    }
}

pub fn main() !void {
    const gpa = std.heap.page_allocator;
    var threaded = std.Io.Threaded.init(gpa, .{ .environ = .empty });
    defer threaded.deinit();
    const io = threaded.io();

    std.debug.print("zig-js GC allocation/context lifecycle profile\n", .{});
    try printLifecycle(gpa, io);
    try printTaskLifecycle(gpa, io);
    try printNursery(gpa, io);
    try printWorkloadDestroy(gpa, io);
    try printAllocation(gpa, io);
    try printExplicitGc(gpa, io);
    try printGcBackingBaseline(gpa);
    try printGcBackingBaselineBuckets(gpa);
    try printGcBacking(gpa);
    try printGcBackingBuckets(gpa);
    try printGcChurnReuse(gpa, io);
    try printGcFinalizers(gpa);
}
