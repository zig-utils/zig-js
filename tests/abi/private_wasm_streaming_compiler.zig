const std = @import("std");

const JSContextRef = ?*anyopaque;
const JSContextGroupRef = ?*anyopaque;
const StreamingCompilerRef = ?*anyopaque;

const Status = enum(c_uint) {
    ok = 0,
    invalid_handle = 1,
    foreign_vm = 2,
    invalid_bytes = 3,
    out_of_memory = 4,
    overflow = 5,
    buffer_too_small = 6,
    invalid_output = 7,
};

extern "c" fn JSGlobalContextCreate(?*anyopaque) JSContextRef;
extern "c" fn JSGlobalContextCreateInGroup(JSContextGroupRef, ?*anyopaque) JSContextRef;
extern "c" fn JSGlobalContextRelease(JSContextRef) void;
extern "c" fn JSContextGroupCreate() JSContextGroupRef;
extern "c" fn JSContextGroupRelease(JSContextGroupRef) void;
extern "c" fn JSC__Wasm__StreamingCompiler__addBytes(StreamingCompilerRef, ?[*]const u8, usize) void;
extern "c" fn ZJSWasmStreamingCompilerCreate(JSContextRef) StreamingCompilerRef;
extern "c" fn ZJSWasmStreamingCompilerFinalize(JSContextRef, StreamingCompilerRef, ?[*]u8, usize, ?*usize) Status;
extern "c" fn ZJSWasmStreamingCompilerRelease(JSContextRef, StreamingCompilerRef) Status;

fn fail(message: []const u8) noreturn {
    std.debug.panic("{s}", .{message});
}

fn expectStatus(actual: Status, expected: Status, message: []const u8) void {
    if (actual != expected) fail(message);
}

fn create(context: JSContextRef) StreamingCompilerRef {
    return ZJSWasmStreamingCompilerCreate(context) orelse fail("streaming compiler creation failed");
}

fn finalize(context: JSContextRef, compiler: StreamingCompilerRef, output: []u8) []const u8 {
    var required: usize = 0;
    const query = ZJSWasmStreamingCompilerFinalize(context, compiler, null, 0, &required);
    if (required == 0) {
        expectStatus(query, .ok, "empty streaming compiler query failed");
        return output[0..0];
    }
    expectStatus(query, .buffer_too_small, "streaming compiler size query failed");
    if (required > output.len) fail("streaming compiler output fixture is too small");
    var written: usize = 0;
    expectStatus(
        ZJSWasmStreamingCompilerFinalize(context, compiler, output.ptr, output.len, &written),
        .ok,
        "streaming compiler finalization failed",
    );
    if (written != required) fail("streaming compiler final length drifted");
    return output[0..written];
}

const ConcurrentFeed = struct {
    compiler: StreamingCompilerRef,
    byte: u8,
    count: usize,

    fn run(self: *ConcurrentFeed) void {
        var bytes: [1024]u8 = undefined;
        @memset(bytes[0..self.count], self.byte);
        JSC__Wasm__StreamingCompiler__addBytes(self.compiler, bytes[0..self.count].ptr, self.count);
    }
};

const TeardownFeed = struct {
    compiler: StreamingCompilerRef,
    started: *std.atomic.Value(bool),

    fn run(self: *TeardownFeed) void {
        self.started.store(true, .release);
        var index: usize = 0;
        while (index < 10_000) : (index += 1)
            JSC__Wasm__StreamingCompiler__addBytes(self.compiler, "x".ptr, 1);
    }
};

pub fn main() !void {
    const group = JSContextGroupCreate() orelse fail("context group creation failed");
    defer JSContextGroupRelease(group);
    const first = JSGlobalContextCreateInGroup(group, null) orelse fail("primary context creation failed");
    defer JSGlobalContextRelease(first);
    const sibling = JSGlobalContextCreateInGroup(group, null) orelse fail("sibling context creation failed");
    defer JSGlobalContextRelease(sibling);
    const foreign = JSGlobalContextCreate(null) orelse fail("foreign context creation failed");
    defer JSGlobalContextRelease(foreign);

    const ordered = create(first);
    JSC__Wasm__StreamingCompiler__addBytes(ordered, "ab".ptr, 2);
    JSC__Wasm__StreamingCompiler__addBytes(ordered, null, 0);
    JSC__Wasm__StreamingCompiler__addBytes(ordered, "cd".ptr, 2);
    var ordered_output: [8]u8 = undefined;
    if (!std.mem.eql(u8, finalize(sibling, ordered, &ordered_output), "abcd"))
        fail("ordered same-VM streaming feed mismatch");
    JSC__Wasm__StreamingCompiler__addBytes(ordered, "late".ptr, 4);
    if (!std.mem.eql(u8, finalize(first, ordered, &ordered_output), "abcd"))
        fail("finalized streaming compiler accepted late bytes");
    expectStatus(ZJSWasmStreamingCompilerFinalize(foreign, ordered, null, 0, null), .foreign_vm, "foreign finalize was accepted");
    expectStatus(ZJSWasmStreamingCompilerRelease(foreign, ordered), .foreign_vm, "foreign release was accepted");
    expectStatus(ZJSWasmStreamingCompilerRelease(first, ordered), .ok, "streaming compiler release failed");
    expectStatus(ZJSWasmStreamingCompilerRelease(first, ordered), .invalid_handle, "stale release was accepted");
    JSC__Wasm__StreamingCompiler__addBytes(ordered, "stale".ptr, 5);
    expectStatus(ZJSWasmStreamingCompilerFinalize(first, ordered, null, 0, null), .invalid_handle, "stale finalize was accepted");

    const invalid_bytes = create(first);
    JSC__Wasm__StreamingCompiler__addBytes(invalid_bytes, null, 1);
    expectStatus(ZJSWasmStreamingCompilerFinalize(first, invalid_bytes, null, 0, null), .invalid_bytes, "null non-empty span was accepted");
    expectStatus(ZJSWasmStreamingCompilerRelease(first, invalid_bytes), .ok, "failed compiler release failed");

    const invalid_output = create(first);
    JSC__Wasm__StreamingCompiler__addBytes(invalid_output, "x".ptr, 1);
    var invalid_output_len: usize = 0;
    expectStatus(
        ZJSWasmStreamingCompilerFinalize(first, invalid_output, null, 1, &invalid_output_len),
        .invalid_output,
        "null finalization output was accepted",
    );
    if (invalid_output_len != 1) fail("invalid output did not report required length");
    expectStatus(ZJSWasmStreamingCompilerRelease(first, invalid_output), .ok, "invalid-output compiler release failed");

    const overflow = create(first);
    JSC__Wasm__StreamingCompiler__addBytes(overflow, "x".ptr, 1);
    JSC__Wasm__StreamingCompiler__addBytes(overflow, "x".ptr, std.math.maxInt(usize));
    expectStatus(ZJSWasmStreamingCompilerFinalize(first, overflow, null, 0, null), .overflow, "overflow was not sticky");
    expectStatus(ZJSWasmStreamingCompilerRelease(first, overflow), .ok, "overflow compiler release failed");

    const empty = create(first);
    JSC__Wasm__StreamingCompiler__addBytes(empty, null, 0);
    var empty_len: usize = 99;
    expectStatus(ZJSWasmStreamingCompilerFinalize(first, empty, null, 0, &empty_len), .ok, "zero-length feed failed");
    if (empty_len != 0) fail("zero-length feed produced bytes");
    expectStatus(ZJSWasmStreamingCompilerRelease(first, empty), .ok, "empty compiler release failed");

    const concurrent = create(first);
    var feeds = [_]ConcurrentFeed{
        .{ .compiler = concurrent, .byte = 'a', .count = 1024 },
        .{ .compiler = concurrent, .byte = 'b', .count = 1024 },
        .{ .compiler = concurrent, .byte = 'c', .count = 1024 },
        .{ .compiler = concurrent, .byte = 'd', .count = 1024 },
    };
    var threads: [feeds.len]std.Thread = undefined;
    for (&threads, &feeds) |*thread, *feed| thread.* = try std.Thread.spawn(.{}, ConcurrentFeed.run, .{feed});
    for (threads) |thread| thread.join();
    var concurrent_output: [4096]u8 = undefined;
    const concurrent_bytes = finalize(first, concurrent, &concurrent_output);
    if (concurrent_bytes.len != concurrent_output.len) fail("concurrent streaming feed lost bytes");
    for ("abcd") |byte| {
        var count: usize = 0;
        for (concurrent_bytes) |actual| if (actual == byte) {
            count += 1;
        };
        if (count != 1024) fail("concurrent streaming feed corrupted bytes");
    }
    expectStatus(ZJSWasmStreamingCompilerRelease(first, concurrent), .ok, "concurrent compiler release failed");

    const teardown_context = JSGlobalContextCreate(null) orelse fail("teardown context creation failed");
    const teardown_handle = create(teardown_context);
    var teardown_started: std.atomic.Value(bool) = .init(false);
    var teardown_feed = TeardownFeed{ .compiler = teardown_handle, .started = &teardown_started };
    const teardown_thread = try std.Thread.spawn(.{}, TeardownFeed.run, .{&teardown_feed});
    while (!teardown_started.load(.acquire)) std.atomic.spinLoopHint();
    JSGlobalContextRelease(teardown_context);
    teardown_thread.join();
    JSC__Wasm__StreamingCompiler__addBytes(teardown_handle, "stale".ptr, 5);
    expectStatus(ZJSWasmStreamingCompilerFinalize(foreign, teardown_handle, null, 0, null), .invalid_handle, "context teardown left a live compiler");

    const forged: StreamingCompilerRef = @ptrFromInt(std.math.maxInt(usize) - 409);
    JSC__Wasm__StreamingCompiler__addBytes(forged, "x".ptr, 1);
    expectStatus(ZJSWasmStreamingCompilerFinalize(first, forged, null, 0, null), .invalid_handle, "forged compiler was accepted");
    expectStatus(ZJSWasmStreamingCompilerFinalize(first, null, null, 0, null), .invalid_handle, "null compiler was accepted");

    std.debug.print("Private Wasm StreamingCompiler: 1/1 pinned symbols linked; lifecycle matrix passed\n", .{});
}
