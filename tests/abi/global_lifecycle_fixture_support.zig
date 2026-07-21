const std = @import("std");

const Global = opaque {};
const VM = opaque {};
const JSString = opaque {};
const JSValue = opaque {};

extern fn Zig__GlobalObject__create(?*anyopaque, i32, bool, bool, ?*anyopaque) ?*Global;
extern fn Zig__GlobalObject__createForTestIsolation(*Global, ?*anyopaque) ?*Global;
extern fn Zig__GlobalObject__destructOnExit(?*Global) void;
extern fn JSC__JSGlobalObject__vm(?*Global) ?*VM;
extern fn ScriptExecutionContextIdentifier__forGlobalObject(?*Global) u32;
extern fn ScriptExecutionContextIdentifier__getGlobalObject(u32) ?*Global;
extern fn JSGlobalContextCreate(?*anyopaque) ?*Global;
extern fn JSGlobalContextRetain(?*Global) ?*Global;
extern fn JSGlobalContextRelease(?*Global) void;
extern fn JSContextGetGlobalObject(?*Global) ?*anyopaque;
extern fn JSStringCreateWithUTF8CString([*:0]const u8) ?*JSString;
extern fn JSStringRelease(?*JSString) void;
extern fn JSEvaluateScript(
    ?*Global,
    ?*JSString,
    ?*anyopaque,
    ?*JSString,
    c_int,
    *?*JSValue,
) ?*JSValue;
extern fn JSValueToBoolean(?*Global, ?*JSValue) bool;

fn fail(profile: []const u8, message: []const u8) noreturn {
    std.debug.print("{s} private global lifecycle fixture: {s}\n", .{ profile, message });
    std.process.exit(1);
}

fn evaluateBoolean(profile: []const u8, global: *Global, source: [*:0]const u8) bool {
    const script = JSStringCreateWithUTF8CString(source) orelse fail(profile, "script allocation failed");
    defer JSStringRelease(script);
    var exception: ?*JSValue = null;
    const result = JSEvaluateScript(global, script, null, null, 1, &exception) orelse
        fail(profile, "script evaluation failed");
    if (exception != null) fail(profile, "script evaluation threw");
    return JSValueToBoolean(global, result);
}

const IsolationAttempt = struct {
    old: *Global,
    result: ?*Global = null,

    fn run(self: *@This()) void {
        self.result = Zig__GlobalObject__createForTestIsolation(self.old, null);
    }
};

const DestructAttempt = struct {
    global: *Global,

    fn run(self: *@This()) void {
        Zig__GlobalObject__destructOnExit(self.global);
    }
};

pub fn run(profile: []const u8) !void {
    var first_console: usize = 1;
    var second_console: usize = 2;
    var worker: usize = 3;
    const execution_context_id: i32 = 600_001;
    const identifier: u32 = @intCast(execution_context_id);
    const first = Zig__GlobalObject__create(&first_console, execution_context_id, true, true, &worker) orelse
        fail(profile, "initial creation failed");
    const vm = JSC__JSGlobalObject__vm(first) orelse fail(profile, "initial VM lookup failed");
    if (ScriptExecutionContextIdentifier__forGlobalObject(first) != identifier)
        fail(profile, "requested execution-context identifier was not preserved");
    if (ScriptExecutionContextIdentifier__getGlobalObject(identifier) != first)
        fail(profile, "initial execution-context lookup failed");
    if (!evaluateBoolean(profile, first, "globalThis.__lifecycleMarker = 42; true"))
        fail(profile, "initial realm evaluation failed");

    var foreign_thread = IsolationAttempt{ .old = first };
    const isolation_thread = try std.Thread.spawn(.{}, IsolationAttempt.run, .{&foreign_thread});
    isolation_thread.join();
    if (foreign_thread.result != null) fail(profile, "wrong-thread isolation was accepted");

    const retained = JSGlobalContextRetain(first) orelse fail(profile, "explicit retain failed");
    const isolated = Zig__GlobalObject__createForTestIsolation(first, &second_console) orelse
        fail(profile, "same-VM isolation failed");
    if (JSC__JSGlobalObject__vm(isolated) != vm) fail(profile, "isolation changed VM identity");
    if (ScriptExecutionContextIdentifier__forGlobalObject(isolated) != identifier or
        ScriptExecutionContextIdentifier__getGlobalObject(identifier) != isolated)
        fail(profile, "isolation did not transfer execution-context identity");
    if (ScriptExecutionContextIdentifier__forGlobalObject(retained) == identifier)
        fail(profile, "retired realm kept the inherited identifier");
    if (!evaluateBoolean(profile, isolated, "typeof globalThis.__lifecycleMarker === 'undefined'"))
        fail(profile, "isolated realm retained the previous global graph");
    JSGlobalContextRelease(retained);

    var wrong_destruct = DestructAttempt{ .global = isolated };
    const destruct_thread = try std.Thread.spawn(.{}, DestructAttempt.run, .{&wrong_destruct});
    destruct_thread.join();
    if (ScriptExecutionContextIdentifier__getGlobalObject(identifier) != isolated)
        fail(profile, "wrong-thread teardown consumed the lifecycle");
    Zig__GlobalObject__destructOnExit(isolated);
    Zig__GlobalObject__destructOnExit(isolated);
    Zig__GlobalObject__destructOnExit(null);
    if (ScriptExecutionContextIdentifier__getGlobalObject(identifier) != null)
        fail(profile, "teardown left a stale execution-context lookup");

    const ordinary = JSGlobalContextCreate(null) orelse fail(profile, "ordinary context creation failed");
    if (Zig__GlobalObject__createForTestIsolation(ordinary, null) != null)
        fail(profile, "foreign lifecycle isolation was accepted");
    Zig__GlobalObject__destructOnExit(ordinary);
    if (JSContextGetGlobalObject(ordinary) == null)
        fail(profile, "foreign lifecycle teardown consumed an ordinary context");
    JSGlobalContextRelease(ordinary);

    const large = Zig__GlobalObject__create(null, -1, false, false, null) orelse
        fail(profile, "large/default global creation failed");
    if (ScriptExecutionContextIdentifier__forGlobalObject(large) == 0)
        fail(profile, "default global received no execution-context identity");
    Zig__GlobalObject__destructOnExit(large);
}
