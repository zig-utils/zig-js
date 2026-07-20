const std = @import("std");

pub const VM = opaque {};
pub const JSGlobalObject = opaque {};
const JSString = opaque {};
const JSValue = opaque {};

pub const WTFStringImpl = extern struct {
    ref_count: u32,
    length: u32,
    pointer: [*]const u8,
    hash_and_flags: u32,
};

pub const BunStringTag = enum(u8) {
    dead = 0,
    wtf_string_impl = 1,
    zig_string = 2,
    static_zig_string = 3,
    empty = 4,
};
pub const ZigString = extern struct { tagged_pointer: usize, length: usize };
pub const BunStringValue = extern union {
    zig_string: ZigString,
    wtf_string_impl: ?*WTFStringImpl,
};
pub const BunString = extern struct {
    tag: BunStringTag,
    value: BunStringValue,
};

comptime {
    if (@sizeOf(BunString) != 24 or @offsetOf(BunString, "value") != 8)
        @compileError("BunString CPU-profiler fixture layout drifted");
}

extern fn JSC__VM__create(heap_type: u8) *VM;
extern fn JSC__VM__deinit(vm: *VM, global: *JSGlobalObject) void;
extern fn JSGlobalContextCreateInGroup(group: ?*anyopaque, global_class: ?*anyopaque) ?*JSGlobalObject;
extern fn JSGlobalContextRelease(global: ?*JSGlobalObject) void;
extern fn JSStringCreateWithUTF8CString(string: [*:0]const u8) ?*JSString;
extern fn JSStringRelease(string: ?*JSString) void;
extern fn JSEvaluateScript(
    global: ?*JSGlobalObject,
    script: ?*JSString,
    this_object: ?*anyopaque,
    source_url: ?*JSString,
    starting_line_number: c_int,
    exception: ?*?*JSValue,
) ?*JSValue;
pub extern fn Bun__WTFStringImpl__deref(string: ?*WTFStringImpl) void;

pub fn createFixtureVM() !struct { vm: *VM, global: *JSGlobalObject, sibling: *JSGlobalObject } {
    const vm = JSC__VM__create(0);
    const global = JSGlobalContextCreateInGroup(@ptrCast(vm), null) orelse return error.ContextCreateFailed;
    errdefer JSGlobalContextRelease(global);
    const sibling = JSGlobalContextCreateInGroup(@ptrCast(vm), null) orelse return error.ContextCreateFailed;
    return .{ .vm = vm, .global = global, .sibling = sibling };
}

pub fn destroyFixtureVM(vm: *VM, global: *JSGlobalObject, sibling: *JSGlobalObject) void {
    JSGlobalContextRelease(sibling);
    JSC__VM__deinit(vm, global);
    JSGlobalContextRelease(global);
}

pub fn evaluate(global: *JSGlobalObject, source: [*:0]const u8, source_url: [*:0]const u8) !void {
    return evaluateAt(global, source, source_url, 1);
}

pub fn evaluateAt(global: *JSGlobalObject, source: [*:0]const u8, source_url: [*:0]const u8, starting_line: c_int) !void {
    const script = JSStringCreateWithUTF8CString(source) orelse return error.StringCreateFailed;
    defer JSStringRelease(script);
    const url = JSStringCreateWithUTF8CString(source_url) orelse return error.StringCreateFailed;
    defer JSStringRelease(url);
    var exception: ?*JSValue = null;
    _ = JSEvaluateScript(global, script, null, url, starting_line, &exception) orelse return error.EvaluationFailed;
    if (exception != null) return error.EvaluationThrew;
}

pub fn runMainWorkload(global: *JSGlobalObject) !void {
    try evaluate(global,
        \\function leaf404(limit) {
        \\  let total = 0;
        \\  for (let i = 0; i < limit; i++) total += i;
        \\  return total;
        \\}
        \\function recur404(depth) {
        \\  if (depth === 0) return leaf404(2500);
        \\  return recur404(depth - 1) + 1;
        \\}
        \\async function asyncWorker404() { return recur404(4); }
        \\globalThis.profileResult404 = asyncWorker404();
        \\(function () { let anonymous404 = 0; for (let i = 0; i < 1200; i++) anonymous404 += i; })();
    , "/tmp/zig-js-cpu-main-404.js");
}

pub fn runSiblingWorkload(global: *JSGlobalObject) !void {
    try evaluateAt(global,
        \\globalThis.siblingTotal404 = 0;
        \\for (let i = 0; i < 1800; i++) siblingTotal404 += i;
    , "/tmp/zig-js-cpu-sibling-404.js", 17);
}

pub fn runRestartWorkload(global: *JSGlobalObject) !void {
    try evaluate(global,
        \\globalThis.restartTotal404 = 0;
        \\for (let i = 0; i < 1600; i++) restartTotal404 += i;
    , "/tmp/zig-js-cpu-restart-404.js");
}

pub fn ownedImplBytes(allocator: std.mem.Allocator, implementation: *WTFStringImpl) ![]u8 {
    if (implementation.hash_and_flags & (1 << 2) != 0)
        return allocator.dupe(u8, implementation.pointer[0..implementation.length]);
    const units: [*]const u16 = @ptrCast(@alignCast(implementation.pointer));
    return std.unicode.wtf16LeToWtf8Alloc(allocator, units[0..implementation.length]);
}

const CPUProfile = struct {
    const Tick = struct { line: u32, ticks: u32 };
    const CallFrame = struct {
        functionName: []const u8,
        scriptId: []const u8,
        url: []const u8,
        lineNumber: i32,
        columnNumber: i32,
    };
    const Node = struct {
        id: u32,
        callFrame: CallFrame,
        hitCount: u32,
        children: []const u32 = &.{},
        positionTicks: []const Tick = &.{},
    };

    nodes: []const Node,
    startTime: i64,
    endTime: i64,
    samples: []const u32,
    timeDeltas: []const i64,
};

pub fn validateJSON(bytes: []const u8, expect_main: bool, expect_sibling: bool, expect_restart: bool) !void {
    var parsed = try std.json.parseFromSlice(CPUProfile, std.heap.page_allocator, bytes, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    const profile = parsed.value;
    try std.testing.expect(profile.nodes.len > 1);
    try std.testing.expectEqual(profile.samples.len, profile.timeDeltas.len);
    try std.testing.expect(profile.samples.len > 1);
    try std.testing.expect(profile.endTime >= profile.startTime);
    for (profile.timeDeltas) |delta| try std.testing.expect(delta >= 0);

    var saw_main = false;
    var saw_sibling = false;
    var saw_restart = false;
    var saw_named_function = false;
    var saw_anonymous = false;
    var saw_ticks = false;
    var saw_sibling_offset = false;
    for (profile.nodes) |node| {
        if (std.mem.eql(u8, node.callFrame.url, "file:///tmp/zig-js-cpu-main-404.js")) saw_main = true;
        if (std.mem.eql(u8, node.callFrame.url, "file:///tmp/zig-js-cpu-sibling-404.js")) saw_sibling = true;
        if (std.mem.eql(u8, node.callFrame.url, "file:///tmp/zig-js-cpu-restart-404.js")) saw_restart = true;
        if (std.mem.eql(u8, node.callFrame.functionName, "leaf404") or
            std.mem.eql(u8, node.callFrame.functionName, "recur404") or
            std.mem.eql(u8, node.callFrame.functionName, "asyncWorker404")) saw_named_function = true;
        if (std.mem.eql(u8, node.callFrame.functionName, "(anonymous)")) saw_anonymous = true;
        if (std.mem.eql(u8, node.callFrame.url, "file:///tmp/zig-js-cpu-sibling-404.js") and node.callFrame.lineNumber >= 16)
            saw_sibling_offset = true;
        if (node.positionTicks.len != 0) saw_ticks = true;
        for (node.children) |child| try std.testing.expect(child > node.id and child <= profile.nodes.len);
    }
    try std.testing.expectEqual(expect_main, saw_main);
    try std.testing.expectEqual(expect_sibling, saw_sibling);
    try std.testing.expectEqual(expect_restart, saw_restart);
    if (expect_main) try std.testing.expect(saw_named_function);
    if (expect_main) try std.testing.expect(saw_anonymous);
    if (expect_sibling) try std.testing.expect(saw_sibling_offset);
    try std.testing.expect(saw_ticks);
}

pub fn validateMarkdown(bytes: []const u8, expect_main: bool, expect_sibling: bool) !void {
    inline for (.{ "# CPU Profile", "## Hot Functions (Self Time)", "## Call Tree (Total Time)", "## Function Details", "**Called by:**", "**Calls:**", "## Files" }) |needle|
        try std.testing.expect(std.mem.indexOf(u8, bytes, needle) != null);
    try std.testing.expectEqual(expect_main, std.mem.indexOf(u8, bytes, "/tmp/zig-js-cpu-main-404.js") != null);
    try std.testing.expectEqual(expect_sibling, std.mem.indexOf(u8, bytes, "/tmp/zig-js-cpu-sibling-404.js") != null);
    if (expect_main) try std.testing.expect(std.mem.indexOf(u8, bytes, "async asyncWorker404") != null);
}

pub fn validateEmptyJSON(bytes: []const u8) !void {
    var parsed = try std.json.parseFromSlice(CPUProfile, std.heap.page_allocator, bytes, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 1), parsed.value.nodes.len);
    try std.testing.expectEqual(@as(usize, 0), parsed.value.samples.len);
    try std.testing.expectEqual(parsed.value.startTime, parsed.value.endTime);
}
