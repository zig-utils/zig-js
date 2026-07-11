//! Simple sharding test runner for `zig build test`.
//!
//! Zig's build-server test runner buffers useful progress until each test
//! finishes. The full zig-js unit suite is large enough that a CI timeout can
//! otherwise end as a silent `zig build test` hang. This runner keeps the
//! default per-test allocator isolation, prints every selected test as it
//! starts/finishes, and lets CI split the suite with:
//!
//!   UNIT_SHARD_INDEX=<zero-based> UNIT_SHARD_COUNT=<positive>

const builtin = @import("builtin");
const std = @import("std");

pub const std_options: std.Options = .{
    .logFn = log,
};

var log_err_count: usize = 0;

pub fn main(init: std.process.Init.Minimal) void {
    @disableInstrumentation();

    const shard_count = readShardEnv(init, "UNIT_SHARD_COUNT", 1);
    const shard_index = readShardEnv(init, "UNIT_SHARD_INDEX", 0);
    if (shard_count == 0) {
        std.debug.print("UNIT_SHARD_COUNT must be greater than zero\n", .{});
        std.process.exit(1);
    }
    if (shard_index >= shard_count) {
        std.debug.print("UNIT_SHARD_INDEX ({d}) must be less than UNIT_SHARD_COUNT ({d})\n", .{ shard_index, shard_count });
        std.process.exit(1);
    }

    const test_fns = builtin.test_functions;
    var selected: usize = 0;
    for (test_fns, 0..) |_, i| {
        if (i % shard_count == shard_index) selected += 1;
    }

    std.debug.print("zig-js unit tests: shard {d}/{d}, running {d} of {d} tests\n", .{
        shard_index,
        shard_count,
        selected,
        test_fns.len,
    });

    var ok_count: usize = 0;
    var skip_count: usize = 0;
    var fail_count: usize = 0;
    var leak_count: usize = 0;
    var seen: usize = 0;

    for (test_fns, 0..) |test_fn, i| {
        if (i % shard_count != shard_index) continue;
        seen += 1;

        std.testing.allocator_instance = .init(std.heap.page_allocator, .{
            .canary = 0xc3a701ba,
            .check_write_after_free = true,
        });
        std.testing.io_instance = .init(std.testing.allocator, .{
            .argv0 = .init(init.args),
            .environ = init.environ,
        });
        std.testing.environ = init.environ;
        std.testing.log_level = .warn;
        log_err_count = 0;

        std.debug.print("{d}/{d} [{d}/{d}] {s}...", .{
            seen,
            selected,
            shard_index,
            shard_count,
            test_fn.name,
        });

        const status: enum { ok, skip, fail } = if (test_fn.func()) |_|
            .ok
        else |err| switch (err) {
            error.SkipZigTest => .skip,
            else => blk: {
                if (@errorReturnTrace()) |trace| {
                    std.debug.print("FAIL ({t})\n", .{err});
                    std.debug.dumpErrorReturnTrace(trace);
                }
                break :blk .fail;
            },
        };

        std.testing.io_instance.deinit();
        const leaks = std.testing.allocator_instance.deinit();

        switch (status) {
            .ok => {
                ok_count += 1;
                std.debug.print("OK\n", .{});
            },
            .skip => {
                skip_count += 1;
                std.debug.print("SKIP\n", .{});
            },
            .fail => {
                fail_count += 1;
                std.debug.print("FAIL\n", .{});
            },
        }
        if (log_err_count != 0) {
            std.debug.print("{d} errors were logged by {s}\n", .{ log_err_count, test_fn.name });
        }
        if (leaks != 0) {
            leak_count += 1;
            std.debug.print("{s} leaked memory\n", .{test_fn.name});
        }
    }

    std.debug.print("zig-js unit tests: shard {d}/{d} summary: {d} passed; {d} skipped; {d} failed; {d} leaked\n", .{
        shard_index,
        shard_count,
        ok_count,
        skip_count,
        fail_count,
        leak_count,
    });
    if (fail_count != 0 or leak_count != 0) std.process.exit(1);
}

fn readShardEnv(init: std.process.Init.Minimal, comptime name: []const u8, default: usize) usize {
    const raw = switch (builtin.os.tag) {
        .windows => return default,
        else => std.process.Environ.getPosix(init.environ, name) orelse return default,
    };
    return std.fmt.parseUnsigned(usize, raw, 10) catch |err| {
        std.debug.print("{s} must be an unsigned integer, got '{s}' ({t})\n", .{ name, raw, err });
        std.process.exit(1);
    };
}

fn log(
    comptime message_level: std.log.Level,
    comptime scope: @EnumLiteral(),
    comptime format: []const u8,
    args: anytype,
) void {
    @disableInstrumentation();
    if (@intFromEnum(message_level) <= @intFromEnum(std.log.Level.err)) {
        log_err_count +|= 1;
    }
    if (@intFromEnum(message_level) <= @intFromEnum(std.testing.log_level)) {
        std.debug.print(
            "[" ++ @tagName(scope) ++ "] (" ++ @tagName(message_level) ++ "): " ++ format ++ "\n",
            args,
        );
    }
}
