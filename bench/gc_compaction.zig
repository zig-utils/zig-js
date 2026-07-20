//! Machine-readable fragmentation benchmark for explicit GC compaction.
//!
//! Usage:
//!   gc-compaction-benchmark-runner <control|compact> <dead> <live> <probe-rounds> <sample>

const std = @import("std");
const js = @import("js");

const Mode = enum { control, compact };
const context_allocator = std.heap.c_allocator;

fn nowNs(io: std.Io) i96 {
    return std.Io.Clock.Timestamp.now(io, .awake).raw.nanoseconds;
}

fn parseMode(text: []const u8) !Mode {
    inline for (std.meta.tags(Mode)) |mode|
        if (std.mem.eql(u8, text, @tagName(mode))) return mode;
    return error.InvalidMode;
}

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len != 6) return error.InvalidArguments;
    const mode = try parseMode(args[1]);
    const dead = try std.fmt.parseUnsigned(usize, args[2], 10);
    const live = try std.fmt.parseUnsigned(usize, args[3], 10);
    const probe_rounds = try std.fmt.parseUnsigned(usize, args[4], 10);
    const sample = try std.fmt.parseUnsigned(usize, args[5], 10);
    if (dead == 0 or live == 0 or probe_rounds == 0) return error.InvalidArguments;

    const ctx = try js.Context.createWith(context_allocator, .{
        .enable_gc = true,
        .enable_jit = false,
    });
    defer ctx.destroy();

    const setup = try std.fmt.allocPrint(init.arena.allocator(),
        \\globalThis.__compactDiscard = [];
        \\for (let i = 0; i < {d}; i++)
        \\  __compactDiscard.push({{ dead: i, child: {{ value: i + 1 }} }});
        \\globalThis.__compactKeep = [];
        \\for (let i = 0; i < {d}; i++)
        \\  __compactKeep.push({{ i: i, peer: {{ value: i + 1 }} }});
        \\__compactDiscard = null;
    , .{ dead, live });
    _ = try ctx.evaluate(setup);
    ctx.collectGarbage();

    const backing = ctx.gc_cell_backing orelse return error.GcBackingUnavailable;
    const before = backing.stats();
    var moved_cells: usize = 0;
    var moved_bytes: usize = 0;
    var action_status: []const u8 = "control";

    const action_started = nowNs(init.io);
    if (mode == .control) {
        ctx.collectGarbage();
    } else {
        const result = ctx.compactGarbage();
        action_status = @tagName(result.status);
        moved_cells = result.moved_cells;
        moved_bytes = result.moved_bytes;
    }
    const action_ns: u64 = @intCast(nowNs(init.io) - action_started);
    const after = backing.stats();

    var fixed_status: []const u8 = "not_run";
    var fixed_ns: u64 = 0;
    if (mode == .compact) {
        const fixed_started = nowNs(init.io);
        const fixed = ctx.compactGarbage();
        fixed_ns = @intCast(nowNs(init.io) - fixed_started);
        fixed_status = @tagName(fixed.status);
        if (fixed.moved_cells != 0 or fixed.moved_bytes != 0) return error.NotDenseAfterCompaction;
    }

    const probe = try std.fmt.allocPrint(init.arena.allocator(),
        \\(function() {{
        \\  var sum = 0;
        \\  for (let round = 0; round < {d}; round++)
        \\    for (let i = 0; i < __compactKeep.length; i++)
        \\      sum = sum + __compactKeep[i].i + __compactKeep[i].peer.value;
        \\  return sum;
        \\}})()
    , .{probe_rounds});
    const probe_started = nowNs(init.io);
    const checksum = (try ctx.evaluate(probe)).toNumber();
    const probe_ns: u64 = @intCast(nowNs(init.io) - probe_started);
    const expected_checksum: f64 = @floatFromInt(probe_rounds * live * live);
    if (checksum != expected_checksum) return error.ChecksumMismatch;

    var stdout_buffer: [2048]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(init.io, &stdout_buffer);
    const stdout = &stdout_writer.interface;
    try stdout.print(
        "{s}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d:.0}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{d}\t{s}\t{s}\t{d}\n",
        .{
            @tagName(mode), sample,        dead,          live,                  probe_rounds,         probe_ns,          checksum,
            action_ns,      before.chunks, after.chunks,  before.capacity_bytes, after.capacity_bytes, before.live_slots, after.live_slots,
            moved_cells,    moved_bytes,   action_status, fixed_status,          fixed_ns,
        },
    );
    try stdout.flush();
}
