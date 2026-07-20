const std = @import("std");

const JSContextRef = ?*anyopaque;

extern "c" fn JSGlobalContextCreate(?*anyopaque) JSContextRef;
extern "c" fn JSGlobalContextRelease(JSContextRef) void;
extern "c" fn ScriptExecutionContextIdentifier__forGlobalObject(JSContextRef) u32;
extern "c" fn ScriptExecutionContextIdentifier__getGlobalObject(u32) JSContextRef;
extern "c" fn Bun__ScriptExecutionContext__removeFromContextsMapByIdentifier(u32) void;

fn fail(message: []const u8) noreturn {
    std.debug.panic("{s}", .{message});
}

pub fn main() void {
    if (ScriptExecutionContextIdentifier__forGlobalObject(null) != 0) fail("null global received an identifier");
    if (ScriptExecutionContextIdentifier__getGlobalObject(0) != null) fail("zero identifier resolved");

    const first = JSGlobalContextCreate(null) orelse fail("first context creation failed");
    defer JSGlobalContextRelease(first);
    const second = JSGlobalContextCreate(null) orelse fail("second context creation failed");
    const first_id = ScriptExecutionContextIdentifier__forGlobalObject(first);
    const second_id = ScriptExecutionContextIdentifier__forGlobalObject(second);
    if (first_id == 0 or second_id == 0 or first_id == second_id) fail("identifiers are not process unique");
    if (ScriptExecutionContextIdentifier__forGlobalObject(first) != first_id) fail("first identifier changed");
    if (ScriptExecutionContextIdentifier__getGlobalObject(first_id) != first) fail("first identifier did not resolve");
    if (ScriptExecutionContextIdentifier__getGlobalObject(second_id) != second) fail("second identifier did not resolve");

    Bun__ScriptExecutionContext__removeFromContextsMapByIdentifier(first_id);
    Bun__ScriptExecutionContext__removeFromContextsMapByIdentifier(first_id);
    Bun__ScriptExecutionContext__removeFromContextsMapByIdentifier(0);
    Bun__ScriptExecutionContext__removeFromContextsMapByIdentifier(std.math.maxInt(u32));
    if (ScriptExecutionContextIdentifier__getGlobalObject(first_id) != null) fail("explicitly retired identifier resolved");
    if (ScriptExecutionContextIdentifier__forGlobalObject(first) != first_id) fail("retirement mutated the stable identifier");
    if (ScriptExecutionContextIdentifier__getGlobalObject(second_id) != second) fail("retirement crossed contexts");

    JSGlobalContextRelease(second);
    if (ScriptExecutionContextIdentifier__getGlobalObject(second_id) != null) fail("natural teardown left a stale identifier");

    const Worker = struct {
        const Result = struct {
            id: u32 = 0,
            resolved_live: bool = false,
            retired: bool = false,
        };

        fn run(result: *Result) void {
            const context = JSGlobalContextCreate(null) orelse return;
            result.id = ScriptExecutionContextIdentifier__forGlobalObject(context);
            result.resolved_live = result.id != 0 and ScriptExecutionContextIdentifier__getGlobalObject(result.id) == context;
            JSGlobalContextRelease(context);
            result.retired = ScriptExecutionContextIdentifier__getGlobalObject(result.id) == null;
        }
    };
    var results: [8]Worker.Result = @splat(.{});
    var threads: [8]std.Thread = undefined;
    for (&threads, &results) |*thread, *result| thread.* = std.Thread.spawn(.{}, Worker.run, .{result}) catch fail("thread spawn failed");
    for (&threads) |*thread| thread.join();
    for (results, 0..) |result, index| {
        if (result.id == 0 or !result.resolved_live or !result.retired) fail("parallel registry lifecycle failed");
        for (results[0..index]) |prior| if (result.id == prior.id) fail("parallel identifiers collided");
    }
}
