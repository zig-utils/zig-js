//! Simple sharding test runner for `zig build test`.
//!
//! Zig's build-server test runner buffers useful progress until each test
//! finishes. The full zig-js unit suite is large enough that a CI timeout can
//! otherwise end as a silent `zig build test` hang. This runner keeps the
//! default per-test allocator isolation, prints every selected test as it
//! starts/finishes, and lets CI split the suite with:
//!
//!   UNIT_SHARD_INDEX=<zero-based> UNIT_SHARD_COUNT=<positive>
//!   UNIT_TEST_FILTER=<test-name substring>
//!   UNIT_SHARD_PLAN=<comma-separated shard index per matched test>
//!   UNIT_LIST_TESTS=1
//!
//! Every test also reports its own wall time, and the run ends with the ten
//! slowest. A single unsharded run of this suite takes hours, and without
//! per-test timing there was no way to tell a pathologically slow test from a
//! suite that is merely large — the whole thing just looked like one opaque
//! wait. `zig build test-parallel` fans shards across cores; the timings are
//! what let you rebalance them or fix the outlier.

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
    const owned_filter = readEnv(init, "UNIT_TEST_FILTER");
    defer if (owned_filter) |value| std.heap.page_allocator.free(value);
    const filter = owned_filter orelse "";
    const owned_plan = readEnv(init, "UNIT_SHARD_PLAN");
    defer if (owned_plan) |value| std.heap.page_allocator.free(value);
    const owned_list_tests = readEnv(init, "UNIT_LIST_TESTS");
    defer if (owned_list_tests) |value| std.heap.page_allocator.free(value);
    const list_tests = if (owned_list_tests) |value| blk: {
        if (!std.mem.eql(u8, value, "1")) {
            std.debug.print("UNIT_LIST_TESTS must be 1, got '{s}'\n", .{value});
            std.process.exit(1);
        }
        break :blk true;
    } else false;
    if (shard_count == 0) {
        std.debug.print("UNIT_SHARD_COUNT must be greater than zero\n", .{});
        std.process.exit(1);
    }
    if (shard_index >= shard_count) {
        std.debug.print("UNIT_SHARD_INDEX ({d}) must be less than UNIT_SHARD_COUNT ({d})\n", .{ shard_index, shard_count });
        std.process.exit(1);
    }

    const test_fns = builtin.test_functions;
    var matched: usize = 0;
    var selected: usize = 0;
    for (test_fns) |test_fn| {
        if (!matchesFilter(test_fn.name, filter)) continue;
        matched += 1;
    }

    if (matched == 0) {
        if (filter.len != 0)
            std.debug.print("zig-js unit tests: filter '{s}' matched 0 of {d} tests\n", .{ filter, test_fns.len })
        else
            std.debug.print("zig-js unit tests: discovered 0 tests\n", .{});
        std.process.exit(1);
    }
    if (list_tests) {
        for (test_fns) |test_fn| {
            if (!matchesFilter(test_fn.name, filter)) continue;
            if (std.mem.indexOfAny(u8, test_fn.name, "\t\r\n") != null) {
                std.debug.print("test name cannot be represented in discovery output: {s}\n", .{test_fn.name});
                std.process.exit(1);
            }
            std.debug.print("UNIT_TEST_NAME\t{s}\n", .{test_fn.name});
        }
        return;
    }

    const plan = if (owned_plan) |raw|
        parseShardPlan(std.heap.page_allocator, raw, matched, shard_count) catch |err| {
            std.debug.print("invalid UNIT_SHARD_PLAN ({t})\n", .{err});
            std.process.exit(1);
        }
    else
        null;
    defer if (plan) |assignments| std.heap.page_allocator.free(assignments);
    for (0..matched) |matched_index| {
        if (selectedShard(plan, matched_index, shard_count) == shard_index) selected += 1;
    }

    if (filter.len != 0) {
        std.debug.print("zig-js unit tests: filter '{s}' matched {d} of {d} tests; shard {d}/{d} running {d}\n", .{
            filter,
            matched,
            test_fns.len,
            shard_index,
            shard_count,
            selected,
        });
    } else {
        std.debug.print("zig-js unit tests: shard {d}/{d}, running {d} of {d} tests\n", .{
            shard_index,
            shard_count,
            selected,
            test_fns.len,
        });
    }

    var ok_count: usize = 0;
    var skip_count: usize = 0;
    var fail_count: usize = 0;
    var leak_count: usize = 0;
    var seen: usize = 0;
    var slowest: [slowest_reported]SlowTest = @splat(.{});
    var total_ns: u64 = 0;

    var matched_index: usize = 0;
    for (test_fns) |test_fn| {
        if (!matchesFilter(test_fn.name, filter)) continue;
        const selected_index = matched_index;
        matched_index += 1;
        if (selectedShard(plan, selected_index, shard_count) != shard_index) continue;
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

        const started_ns = nowNs();
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

        // Read the clock before `io_instance.deinit()`, which is what owns it.
        const elapsed_ns = elapsedNs(started_ns, nowNs());
        total_ns +|= elapsed_ns;
        recordSlow(&slowest, test_fn.name, elapsed_ns);

        std.testing.io_instance.deinit();
        const leaks = std.testing.allocator_instance.deinit();

        const elapsed_ms = elapsed_ns / std.time.ns_per_ms;
        switch (status) {
            .ok => {
                ok_count += 1;
                std.debug.print("OK ({d} ms)\n", .{elapsed_ms});
            },
            .skip => {
                skip_count += 1;
                std.debug.print("SKIP\n", .{});
            },
            .fail => {
                fail_count += 1;
                std.debug.print("FAIL ({d} ms)\n", .{elapsed_ms});
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

    for (slowest) |entry| {
        const name = entry.name orelse continue;
        // Only tests worth acting on. A filtered run where everything is
        // instant should not print a "slowest" list at all.
        if (entry.ns < slow_threshold_ns) continue;
        std.debug.print("zig-js unit tests: shard {d}/{d} slow: {d} ms {s}\n", .{
            shard_index,
            shard_count,
            entry.ns / std.time.ns_per_ms,
            name,
        });
    }
    std.debug.print("zig-js unit tests: shard {d}/{d} summary: {d} passed; {d} skipped; {d} failed; {d} leaked; {d} ms\n", .{
        shard_index,
        shard_count,
        ok_count,
        skip_count,
        fail_count,
        leak_count,
        total_ns / std.time.ns_per_ms,
    });
    if (fail_count != 0 or leak_count != 0) std.process.exit(1);
}

/// Awake-clock nanoseconds from the per-test `Io`. Valid only between that
/// instance's `init` and `deinit`, which brackets every use here.
fn nowNs() i96 {
    @disableInstrumentation();
    return std.Io.Clock.awake.now(std.testing.io_instance.io()).nanoseconds;
}

fn elapsedNs(start_ns: i96, end_ns: i96) u64 {
    @disableInstrumentation();
    if (end_ns <= start_ns) return 0;
    return @intCast(end_ns - start_ns);
}

const slowest_reported = 10;
const slow_threshold_ns = 1 * std.time.ns_per_s;

const SlowTest = struct {
    name: ?[]const u8 = null,
    ns: u64 = 0,
};

/// Keep the slowest `slowest_reported` tests seen so far, most expensive first.
/// A plain insertion sort over ten entries is cheaper than sorting the whole
/// suite and needs no allocator, which matters because this runs between the
/// per-test allocator teardown and the next test's setup.
fn recordSlow(slowest: []SlowTest, name: []const u8, ns: u64) void {
    @disableInstrumentation();
    var at: ?usize = null;
    for (slowest, 0..) |entry, i| {
        if (ns > entry.ns) {
            at = i;
            break;
        }
    }
    const index = at orelse return;
    var i = slowest.len - 1;
    while (i > index) : (i -= 1) slowest[i] = slowest[i - 1];
    slowest[index] = .{ .name = name, .ns = ns };
}

fn readShardEnv(init: std.process.Init.Minimal, comptime name: []const u8, default: usize) usize {
    const raw = readEnv(init, name) orelse return default;
    defer std.heap.page_allocator.free(raw);
    return std.fmt.parseUnsigned(usize, raw, 10) catch |err| {
        std.debug.print("{s} must be an unsigned integer, got '{s}' ({t})\n", .{ name, raw, err });
        std.process.exit(1);
    };
}

fn readEnv(init: std.process.Init.Minimal, comptime name: []const u8) ?[]u8 {
    return std.process.Environ.getAlloc(init.environ, std.heap.page_allocator, name) catch |err| switch (err) {
        error.EnvironmentVariableMissing => null,
        else => {
            std.debug.print("could not read {s} ({t})\n", .{ name, err });
            std.process.exit(1);
        },
    };
}

fn matchesFilter(name: []const u8, filter: []const u8) bool {
    return filter.len == 0 or std.mem.indexOf(u8, name, filter) != null;
}

const ShardPlanError = std.mem.Allocator.Error || error{
    EmptyAssignment,
    InvalidAssignment,
    AssignmentOutOfRange,
    AssignmentCountMismatch,
};

fn parseShardPlan(
    allocator: std.mem.Allocator,
    raw: []const u8,
    expected_count: usize,
    shard_count: usize,
) ShardPlanError![]usize {
    const assignments = try allocator.alloc(usize, expected_count);
    errdefer allocator.free(assignments);
    var tokens = std.mem.splitScalar(u8, raw, ',');
    var count: usize = 0;
    while (tokens.next()) |token| {
        if (token.len == 0) return error.EmptyAssignment;
        if (count >= assignments.len) return error.AssignmentCountMismatch;
        const assignment = std.fmt.parseUnsigned(usize, token, 10) catch
            return error.InvalidAssignment;
        if (assignment >= shard_count) return error.AssignmentOutOfRange;
        assignments[count] = assignment;
        count += 1;
    }
    if (count != expected_count) return error.AssignmentCountMismatch;
    return assignments;
}

fn selectedShard(plan: ?[]const usize, matched_index: usize, shard_count: usize) usize {
    return if (plan) |assignments| assignments[matched_index] else matched_index % shard_count;
}

fn log(
    comptime message_level: std.log.Level,
    comptime scope: @EnumLiteral(),
    comptime format: []const u8,
    args: anytype,
) void {
    @disableInstrumentation();
    if (@backingInt(message_level) <= @backingInt(std.log.Level.err)) {
        log_err_count +|= 1;
    }
    if (@backingInt(message_level) <= @backingInt(std.testing.log_level)) {
        std.debug.print(
            "[" ++ @tagName(scope) ++ "] (" ++ @tagName(message_level) ++ "): " ++ format ++ "\n",
            args,
        );
    }
}
