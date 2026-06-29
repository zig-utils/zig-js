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

fn nowNs(io: std.Io) i96 {
    return std.Io.Clock.Timestamp.now(io, .awake).raw.nanoseconds;
}

fn makeContext(gpa: std.mem.Allocator, mode: Mode) !*js.Context {
    return js.Context.createWith(gpa, mode.options);
}

fn timeLifecycle(gpa: std.mem.Allocator, io: std.Io, mode: Mode, rounds: usize) !u64 {
    const t0 = nowNs(io);
    var i: usize = 0;
    while (i < rounds) : (i += 1) {
        const ctx = try makeContext(gpa, mode);
        ctx.destroy();
    }
    return @intCast(nowNs(io) - t0);
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
    std.debug.print("{s:<18} {s:>14} {s:>14}\n", .{ "mode", "total ns", "ns/context" });
    for (modes) |mode| {
        const ns = try timeLifecycle(gpa, io, mode, rounds);
        std.debug.print("{s:<18} {d:>14} {d:>14}\n", .{ mode.name, ns, ns / rounds });
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

pub fn main() !void {
    const gpa = std.heap.page_allocator;
    var threaded = std.Io.Threaded.init(gpa, .{ .environ = .empty });
    defer threaded.deinit();
    const io = threaded.io();

    std.debug.print("zig-js GC allocation/context lifecycle profile\n", .{});
    try printLifecycle(gpa, io);
    try printTaskLifecycle(gpa, io);
    try printAllocation(gpa, io);
    try printExplicitGc(gpa, io);
}
