const std = @import("std");

const Global = opaque {};
const VM = opaque {};
const JSString = opaque {};
const JSValue = opaque {};

const InvalidOptionState = struct {
    calls: std.atomic.Value(usize) = .init(0),
    matched: std.atomic.Value(u8) = .init(0),
    reentered: std.atomic.Value(bool) = .init(false),
    entered: std.atomic.Value(bool) = .init(false),
    release: std.atomic.Value(bool) = .init(false),
};

var invalid_option_state: InvalidOptionState = .{};

extern fn JSCInitialize(
    [*]const ?[*:0]const u8,
    usize,
    *const fn ([*]const u8, usize) callconv(.c) void,
    bool,
    bool,
) void;
extern fn Zig__GlobalObject__create(?*anyopaque, i32, bool, bool, ?*anyopaque) ?*Global;
extern fn Zig__GlobalObject__destructOnExit(?*Global) void;
extern fn JSC__JSGlobalObject__vm(?*Global) ?*VM;
extern fn JSC__VM__notifyNeedShellTimeoutCheck(?*VM) void;
extern fn JSC__VM__hasTerminationRequest(?*VM) bool;
extern fn JSC__VM__clearHasTerminationRequest(?*VM) void;
extern fn JSStringCreateWithUTF8CString([*:0]const u8) ?*JSString;
extern fn JSStringRelease(?*JSString) void;
extern fn JSEvaluateScript(?*Global, ?*JSString, ?*anyopaque, ?*JSString, c_int, *?*JSValue) ?*JSValue;
extern fn JSValueToBoolean(?*Global, ?*JSValue) bool;

fn fail(profile: []const u8, message: []const u8) noreturn {
    std.debug.print("{s} process initialization fixture: {s}\n", .{ profile, message });
    std.process.exit(1);
}

fn invalidOption(bytes: [*]const u8, len: usize) callconv(.c) void {
    const call_index = invalid_option_state.calls.fetchAdd(1, .acq_rel);
    const entry = bytes[0..len];
    if (std.mem.eql(u8, entry, "BUN_JSC_unknownPerfectOption=true"))
        _ = invalid_option_state.matched.fetchOr(1, .acq_rel)
    else if (std.mem.eql(u8, entry, "BUN_JSC_useWasm=definitely"))
        _ = invalid_option_state.matched.fetchOr(2, .acq_rel);
    if (call_index != 0) return;
    const reentrant_env = [_]?[*:0]const u8{"BUN_JSC_useWasm=true"};
    JSCInitialize(&reentrant_env, reentrant_env.len, ignoredInvalidOption, true, false);
    invalid_option_state.reentered.store(true, .release);
    invalid_option_state.entered.store(true, .release);
    while (!invalid_option_state.release.load(.acquire)) std.Thread.yield() catch {};
}

fn ignoredInvalidOption(_: [*]const u8, _: usize) callconv(.c) void {
    _ = invalid_option_state.calls.fetchAdd(1000, .acq_rel);
}

fn evaluate(
    profile: []const u8,
    global: *Global,
    source: [*:0]const u8,
    expect_throw: bool,
) ?*JSValue {
    const script = JSStringCreateWithUTF8CString(source) orelse fail(profile, "script allocation failed");
    defer JSStringRelease(script);
    var exception: ?*JSValue = null;
    const result = JSEvaluateScript(global, script, null, null, 1, &exception);
    if (expect_throw) {
        if (result != null or exception == null) fail(profile, "expected timeout throw was not reported");
        return null;
    }
    if (result == null or exception != null) fail(profile, "script evaluation failed");
    return result;
}

const RepeatInitialization = struct {
    env: *const [1]?[*:0]const u8,
    attempted: *std.atomic.Value(usize),
    completed: *std.atomic.Value(usize),

    fn run(self: *@This()) void {
        _ = self.attempted.fetchAdd(1, .acq_rel);
        JSCInitialize(self.env, self.env.len, ignoredInvalidOption, false, false);
        _ = self.completed.fetchAdd(1, .acq_rel);
    }
};

const WinningInitialization = struct {
    env: *const [10]?[*:0]const u8,

    fn run(self: *@This()) void {
        JSCInitialize(self.env, self.env.len, invalidOption, false, true);
    }
};

pub fn run(profile: []const u8) !void {
    const env = [_]?[*:0]const u8{
        "PATH=/usr/bin",
        null,
        "BUN_JSC_useJIT=false",
        "BUN_JSC_useWasm=false",
        "BUN_JSC_useSharedArrayBuffer=false",
        "BUN_JSC_useShadowRealm=false",
        "BUN_JSC_evalMode=true",
        "BUN_JSC_useConcurrentJIT=false",
        "BUN_JSC_unknownPerfectOption=true",
        "BUN_JSC_useWasm=definitely",
    };
    var winner = WinningInitialization{ .env = &env };
    const winner_thread = try std.Thread.spawn(.{}, WinningInitialization.run, .{&winner});
    while (!invalid_option_state.entered.load(.acquire)) std.Thread.yield() catch {};

    var attempted = std.atomic.Value(usize).init(0);
    var completed = std.atomic.Value(usize).init(0);
    const later_env = [_]?[*:0]const u8{"BUN_JSC_useWasm=true"};
    var repeat = RepeatInitialization{
        .env = &later_env,
        .attempted = &attempted,
        .completed = &completed,
    };
    var threads: [4]std.Thread = undefined;
    for (&threads) |*thread| thread.* = try std.Thread.spawn(.{}, RepeatInitialization.run, .{&repeat});
    while (attempted.load(.acquire) != threads.len) std.Thread.yield() catch {};
    var yields: usize = 0;
    while (yields < 1024) : (yields += 1) std.Thread.yield() catch {};
    if (completed.load(.acquire) != 0) fail(profile, "concurrent initialization did not wait for publication");
    invalid_option_state.release.store(true, .release);
    winner_thread.join();
    for (threads) |thread| thread.join();

    if (invalid_option_state.calls.load(.acquire) != 2 or
        invalid_option_state.matched.load(.acquire) != 3 or
        !invalid_option_state.reentered.load(.acquire))
        fail(profile, "invalid option callback mismatch");
    if (completed.load(.acquire) != threads.len)
        fail(profile, "concurrent initialization callers did not complete");
    if (invalid_option_state.calls.load(.acquire) != 2)
        fail(profile, "later initialization invoked its callback");

    const first = Zig__GlobalObject__create(null, 700_001, true, false, null) orelse
        fail(profile, "first global creation failed");
    defer Zig__GlobalObject__destructOnExit(first);
    const second = Zig__GlobalObject__create(null, 700_002, false, false, null) orelse
        fail(profile, "second global creation failed");
    defer Zig__GlobalObject__destructOnExit(second);
    const first_vm = JSC__JSGlobalObject__vm(first) orelse fail(profile, "first VM lookup failed");

    const globals_hidden = evaluate(
        profile,
        first,
        "typeof WebAssembly === 'undefined' && typeof SharedArrayBuffer === 'undefined' && typeof ShadowRealm === 'undefined'",
        false,
    ) orelse unreachable;
    if (!JSValueToBoolean(first, globals_hidden)) fail(profile, "first-call process options were not applied");

    JSC__VM__notifyNeedShellTimeoutCheck(first_vm);
    if (JSC__VM__hasTerminationRequest(first_vm))
        fail(profile, "shell trap published termination before execution consumed it");
    _ = evaluate(
        profile,
        first,
        "let shellTimeoutCounter = 0; while (shellTimeoutCounter < 4096) shellTimeoutCounter++; shellTimeoutCounter",
        true,
    );
    if (!JSC__VM__hasTerminationRequest(first_vm))
        fail(profile, "shell trap did not publish termination after consumption");

    const other_vm_ok = evaluate(profile, second, "40 + 2 === 42", false) orelse unreachable;
    if (!JSValueToBoolean(second, other_vm_ok)) fail(profile, "shell trap crossed VM ownership");
    JSC__VM__clearHasTerminationRequest(first_vm);
    const reused = evaluate(profile, first, "6 * 7 === 42", false) orelse unreachable;
    if (!JSValueToBoolean(first, reused)) fail(profile, "consumed shell trap was not one-shot");
    JSC__VM__notifyNeedShellTimeoutCheck(null);
}
