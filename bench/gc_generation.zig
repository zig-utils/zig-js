//! Machine-readable generational-policy benchmark runner.
//!
//! Usage:
//!   gc-generation-benchmark-runner \
//!     <forced|automatic|shared> <ephemeral|mixed|high> \
//!     <tenuring-age> <moving:0|1> <trigger-bytes> <rounds> <batch> <sample>

const std = @import("std");
const js = @import("js");

const Trigger = enum { forced, automatic, shared };
const Scenario = enum { ephemeral, mixed, high };
const context_allocator = std.heap.c_allocator;

const Result = struct {
    checksum: u64,
    elapsed_ns: u64,
    pause_total_ns: u64,
    pause_max_ns: u64,
};

const Completed = struct {
    ctx: *js.Context,
    result: Result,
    minor_before: usize,
    full_before: usize,
    young_input_before: usize,
    survived_before: usize,
    reclaimed_before: usize,
    promoted_before: usize,
    moving_minor_before: usize,
    moved_cells_before: usize,
    moved_bytes_before: usize,
    move_failures_before: usize,
};

fn nowNs(io: std.Io) i96 {
    return std.Io.Clock.Timestamp.now(io, .awake).raw.nanoseconds;
}

fn parseEnum(comptime T: type, text: []const u8) !T {
    inline for (std.meta.tags(T)) |tag|
        if (std.mem.eql(u8, text, @tagName(tag))) return tag;
    return error.InvalidArguments;
}

fn evaluate(ctx: *js.Context, source: []const u8) !js.Value {
    return ctx.evaluate(source) catch |err| {
        if (ctx.exception) |exception| {
            if (exception.isObject()) {
                const object = exception.asObj();
                const name = object.getOwn("name");
                const message = object.getOwn("message");
                std.debug.print(
                    "GC generation benchmark evaluation failed: {s}: {s}: {s}\n",
                    .{
                        @errorName(err),
                        if (name != null and name.?.isString()) name.?.asStr() else "<unnamed exception>",
                        if (message != null and message.?.isString()) message.?.asStr() else "<no message>",
                    },
                );
            } else {
                std.debug.print("GC generation benchmark evaluation failed: {s}: exception kind {s}\n", .{
                    @errorName(err),
                    @tagName(exception.kind()),
                });
            }
        } else {
            std.debug.print("GC generation benchmark evaluation failed: {s}: no exception value\n", .{@errorName(err)});
        }
        return err;
    };
}

fn scenarioConfig(scenario: Scenario) struct {
    ring: []const u8,
    slot_mask: usize,
    retain: []const u8,
} {
    return switch (scenario) {
        .ephemeral => .{ .ring = "[[]]", .slot_mask = 0, .retain = "false" },
        // Two-cycle objects distinguish age-one premature promotion from the
        // production age-three nursery.
        .mixed => .{ .ring = "[[], []]", .slot_mask = 1, .retain = "(i & 15) === 0" },
        // Eight-cycle objects are intentionally long-lived and should promote
        // under both policies.
        .high => .{
            .ring = "[[], [], [], [], [], [], [], []]",
            .slot_mask = 7,
            .retain = "(i & 1) === 0",
        },
    };
}

fn prepareContext(ctx: *js.Context, age: u8, moving: bool, trigger_bytes: usize) *js.Context.GcHeap {
    ctx.collectGarbage();
    const heap = ctx.gc.?;
    heap.setNurseryTenuringAge(age);
    heap.setMovingNurseryEnabled(moving);
    heap.threshold_bytes = std.math.maxInt(usize);
    heap.nursery_threshold_bytes = trigger_bytes;
    return heap;
}

fn singleFunctionSource(arena: std.mem.Allocator, scenario: Scenario) ![]const u8 {
    const config = scenarioConfig(scenario);
    return std.fmt.allocPrint(arena,
        \\function __generationRun(__limit) {{
        \\  const __slot = __generationRound & {d};
        \\  __generationRing[__slot] = [];
        \\  for (let i = 0; i < __limit; i++) {{
        \\    const value = {{ i: i, nested: {{ value: i + 1 }} }};
        \\    __generationChecksum = __generationChecksum + value.i + value.nested.value;
        \\    if ({s}) __generationRing[__slot].push(value);
        \\  }}
        \\  __generationRound = __generationRound + 1;
        \\  return __generationChecksum;
        \\}}
    , .{ config.slot_mask, config.retain });
}

fn runSingle(
    init: std.process.Init,
    trigger: Trigger,
    scenario: Scenario,
    age: u8,
    moving: bool,
    trigger_bytes: usize,
    rounds: usize,
    batch: usize,
) !Completed {
    const ctx = try js.Context.createWith(context_allocator, .{
        .enable_gc = true,
        .enable_jit = true,
    });
    errdefer ctx.destroy();
    const config = scenarioConfig(scenario);
    _ = try evaluate(ctx, try singleFunctionSource(init.arena.allocator(), scenario));
    _ = try evaluate(ctx, try std.fmt.allocPrint(
        init.arena.allocator(),
        "globalThis.__generationRing = {s}; globalThis.__generationRound = 0; globalThis.__generationChecksum = 0;",
        .{config.ring},
    ));
    // Cross the baseline threshold without reaching the eight-entry optimizer
    // threshold: baseline checkpoints run every 1024 steps even when no
    // explicit movement word is armed, so automatic nursery pressure is the
    // sole trigger in both exact-parent configurations.
    for (0..4) |_| _ = try evaluate(ctx, "__generationRun(16)");
    _ = try evaluate(ctx, try std.fmt.allocPrint(
        init.arena.allocator(),
        "globalThis.__generationRing = {s}; globalThis.__generationRound = 0; globalThis.__generationChecksum = 0;",
        .{config.ring},
    ));
    const heap = prepareContext(ctx, age, moving, trigger_bytes);
    const before = heap.accounting();
    const source = try std.fmt.allocPrint(init.arena.allocator(), "__generationRun({d})", .{batch});
    var pause_total_ns: u64 = 0;
    var pause_max_ns: u64 = 0;
    var value = try evaluate(ctx, "0");
    const started = nowNs(init.io);
    for (0..rounds) |_| {
        value = try evaluate(ctx, source);
        if (trigger == .forced) {
            const pause_started = nowNs(init.io);
            if (moving) {
                ctx.gc_relocation_active.store(true, .release);
                const relocation = heap.collectYoungAndCompact();
                ctx.gc_relocation_active.store(false, .release);
                if (relocation.status == .unsupported or relocation.status == .out_of_memory)
                    return error.MovingMinorFailed;
            } else {
                heap.collectYoung();
            }
            const pause_ns: u64 = @intCast(nowNs(init.io) - pause_started);
            pause_total_ns +|= pause_ns;
            pause_max_ns = @max(pause_max_ns, pause_ns);
        }
    }
    const elapsed_ns: u64 = @intCast(nowNs(init.io) - started);
    if (trigger == .automatic) {
        pause_total_ns = ctx.gc_minor_pause_ns_total.load(.monotonic);
        pause_max_ns = ctx.gc_minor_pause_ns_max.load(.monotonic);
    }
    return .{
        .ctx = ctx,
        .result = .{
            .checksum = @intFromFloat(value.toNumber()),
            .elapsed_ns = elapsed_ns,
            .pause_total_ns = pause_total_ns,
            .pause_max_ns = pause_max_ns,
        },
        .minor_before = before.minor_collections,
        .full_before = before.full_collections,
        .young_input_before = before.total_minor_young_bytes,
        .survived_before = before.total_minor_survived_bytes,
        .reclaimed_before = before.total_minor_reclaimed_bytes,
        .promoted_before = before.total_minor_promoted_bytes,
        .moving_minor_before = before.moving_minor_collections,
        .moved_cells_before = before.total_minor_moved_cells,
        .moved_bytes_before = before.total_minor_moved_bytes,
        .move_failures_before = before.minor_move_failures,
    };
}

fn runShared(
    init: std.process.Init,
    scenario: Scenario,
    age: u8,
    moving: bool,
    trigger_bytes: usize,
    rounds: usize,
    batch: usize,
) !Completed {
    const ctx = try js.Context.createWithTestingOptions(context_allocator, .{
        .enable_threads = true,
        .enable_gc = true,
        .enable_jit = true,
        .parallel_gc = true,
        .parallel_js = true,
    });
    errdefer ctx.destroy();
    const config = scenarioConfig(scenario);
    const checkpoint_tail = if (moving)
        "return checksum + __generationCheckpoint(2000000, __generationSharedRoot) - 1;"
    else
        "return checksum;";
    const setup_source = try std.fmt.allocPrint(init.arena.allocator(),
        \\function __generationChurn(lane) {{
        \\  const ring = {s};
        \\  let checksum = 0;
        \\  for (let round = 0; round < {d}; round++) {{
        \\    const slot = round & {d};
        \\    ring[slot] = [];
        \\    for (let i = 0; i < {d}; i++) {{
        \\      const value = {{ lane: lane, i: i, nested: {{ value: i + 1 }} }};
        \\      checksum = checksum + value.i + value.nested.value;
        \\      if ({s}) ring[slot].push(value);
        \\    }}
        \\  }}
        \\  Atomics.add(__generationGate, 0, 1);
        \\  while (Atomics.load(__generationGate, 0) !== 3) {{}}
        \\  {s}
        \\}}
        \\function __generationCheckpoint(limit, held) {{
        \\  var cursor = 0;
        \\  while (cursor < limit) cursor = cursor + 1;
        \\  return held.marker;
        \\}}
        \\globalThis.__generationGate = new Int32Array(new SharedArrayBuffer(4));
        \\globalThis.__generationSharedRoot = {{ marker: 1 }};
        \\for (let warm = 0; warm < 10; warm++)
        \\  __generationCheckpoint(6, __generationSharedRoot);
    , .{ config.ring, rounds, config.slot_mask, batch, config.retain, checkpoint_tail });
    _ = try evaluate(ctx, setup_source);
    ctx.collectGarbage();
    const heap = ctx.gc.?;
    heap.setNurseryTenuringAge(age);
    heap.setMovingNurseryEnabled(moving);
    heap.threshold_bytes = std.math.maxInt(usize);
    heap.nursery_threshold_bytes = trigger_bytes;
    ctx.gc_cooperative_tranche_bytes = trigger_bytes;
    _ = try evaluate(ctx, "globalThis.__generationSharedRoot = { marker: 1 };");
    const before = heap.accounting();
    const source =
        \\globalThis.__generationFirst = new Thread(__generationChurn, 0);
        \\globalThis.__generationSecond = new Thread(__generationChurn, 1);
        \\globalThis.__generationMain = __generationChurn(2);
        \\__generationMain + __generationFirst.join() + __generationSecond.join();
    ;
    const started = nowNs(init.io);
    const value = try evaluate(ctx, source);
    const elapsed_ns: u64 = @intCast(nowNs(init.io) - started);
    return .{
        .ctx = ctx,
        .result = .{
            .checksum = @intFromFloat(value.toNumber()),
            .elapsed_ns = elapsed_ns,
            .pause_total_ns = ctx.gc_cooperative_pause_ns_total.load(.monotonic),
            .pause_max_ns = ctx.gc_cooperative_pause_ns_max.load(.monotonic),
        },
        .minor_before = before.minor_collections,
        .full_before = before.full_collections,
        .young_input_before = before.total_minor_young_bytes,
        .survived_before = before.total_minor_survived_bytes,
        .reclaimed_before = before.total_minor_reclaimed_bytes,
        .promoted_before = before.total_minor_promoted_bytes,
        .moving_minor_before = before.moving_minor_collections,
        .moved_cells_before = before.total_minor_moved_cells,
        .moved_bytes_before = before.total_minor_moved_bytes,
        .move_failures_before = before.minor_move_failures,
    };
}

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len != 9) return error.InvalidArguments;
    const trigger = try parseEnum(Trigger, args[1]);
    const scenario = try parseEnum(Scenario, args[2]);
    const age = try std.fmt.parseUnsigned(u8, args[3], 10);
    const moving_raw = try std.fmt.parseUnsigned(u8, args[4], 10);
    const moving = moving_raw == 1;
    const trigger_bytes = try std.fmt.parseUnsigned(usize, args[5], 10);
    const rounds = try std.fmt.parseUnsigned(usize, args[6], 10);
    const batch = try std.fmt.parseUnsigned(usize, args[7], 10);
    const sample = try std.fmt.parseUnsigned(usize, args[8], 10);
    if (age == 0 or age >= 255 or moving_raw > 1 or
        trigger_bytes == 0 or rounds == 0 or batch == 0)
        return error.InvalidArguments;

    const completed = if (trigger == .shared)
        try runShared(init, scenario, age, moving, trigger_bytes, rounds, batch)
    else
        try runSingle(init, trigger, scenario, age, moving, trigger_bytes, rounds, batch);
    defer completed.ctx.destroy();
    const ctx = completed.ctx;
    const heap = ctx.gc.?;
    const stats = heap.accounting();
    const backing = (ctx.gc_cell_backing orelse return error.GcBackingUnavailable).stats();
    const minor_collections = stats.minor_collections - completed.minor_before;
    const full_collections = stats.full_collections - completed.full_before;
    const young_input_bytes = stats.total_minor_young_bytes - completed.young_input_before;
    const survived_bytes = stats.total_minor_survived_bytes - completed.survived_before;
    const reclaimed_bytes = stats.total_minor_reclaimed_bytes - completed.reclaimed_before;
    const promoted_bytes = stats.total_minor_promoted_bytes - completed.promoted_before;
    const moving_minor_collections = stats.moving_minor_collections - completed.moving_minor_before;
    const moved_cells = stats.total_minor_moved_cells - completed.moved_cells_before;
    const moved_bytes = stats.total_minor_moved_bytes - completed.moved_bytes_before;
    const move_failures = stats.minor_move_failures - completed.move_failures_before;
    const expected: u64 = @intCast(rounds * batch * batch * (if (trigger == .shared) @as(usize, 3) else 1));
    if (completed.result.checksum != expected) return error.ChecksumMismatch;
    if (minor_collections == 0) return error.NoMinorCollection;
    if (young_input_bytes != survived_bytes + reclaimed_bytes)
        return error.InvalidMinorAccounting;
    if (moving) {
        if (moving_minor_collections == 0 or moved_cells == 0 or moved_bytes == 0 or move_failures != 0) {
            std.debug.print(
                "invalid moving minor accounting: minors={d} moving={d} moved_cells={d} moved_bytes={d} failures={d} survivors={d} attempts={d} cooperative={d} parks={d} timeouts={d} request={}\n",
                .{
                    minor_collections,
                    moving_minor_collections,
                    moved_cells,
                    moved_bytes,
                    move_failures,
                    survived_bytes,
                    ctx.gc_cooperative_attempts.load(.monotonic),
                    ctx.gc_cooperative_collections.load(.monotonic),
                    ctx.gc_cooperative_peer_parks.load(.monotonic),
                    ctx.gc_cooperative_timeouts.load(.monotonic),
                    ctx.gc_moving_checkpoint_requested.load(.acquire),
                },
            );
            return error.InvalidMovingMinorAccounting;
        }
    } else if (moving_minor_collections != 0 or moved_cells != 0 or moved_bytes != 0 or move_failures != 0) {
        return error.UnexpectedMovingMinor;
    }
    if (trigger == .shared) {
        if (ctx.gc_cooperative_attempts.load(.monotonic) == 0 or
            ctx.gc_cooperative_collections.load(.monotonic) == 0 or
            ctx.gc_cooperative_peer_parks.load(.monotonic) == 0)
            return error.NoCooperativeCollection;
        const timeout_limit: u64 = if (moving) 2 else 0;
        if (ctx.gc_cooperative_timeouts.load(.monotonic) > timeout_limit)
            return error.CooperativeTimeout;
    }

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(init.io, &stdout_buffer);
    const stdout = &stdout_writer.interface;
    try stdout.print(
        "{s}\t{s}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\n",
        .{
            @tagName(trigger),
            @tagName(scenario),
            age,
            @intFromBool(moving),
            trigger_bytes,
            sample,
            rounds,
            batch,
            completed.result.elapsed_ns,
            completed.result.checksum,
            minor_collections,
            full_collections,
            young_input_bytes,
            survived_bytes,
            reclaimed_bytes,
            promoted_bytes,
            moving_minor_collections,
            moved_cells,
            moved_bytes,
            move_failures,
            stats.live_bytes,
            stats.young_bytes,
            heap.nursery_threshold_bytes,
            backing.chunks,
            backing.capacity_bytes,
            completed.result.pause_total_ns,
            completed.result.pause_max_ns,
            ctx.gc_cooperative_attempts.load(.monotonic),
            ctx.gc_cooperative_collections.load(.monotonic),
            ctx.gc_cooperative_peer_parks.load(.monotonic),
            ctx.gc_cooperative_timeouts.load(.monotonic),
        },
    );
    try stdout.flush();
}
