const std = @import("std");

pub const VM = opaque {};
pub const JSGlobalObject = opaque {};
const JSString = opaque {};
const JSValue = opaque {};

pub const EncodedValue = enum(i64) {
    empty = 0,
    undefined = 0xa,
    _,

    fn fromRef(pointer: *JSValue) EncodedValue {
        return @enumFromInt(@as(i64, @bitCast(@as(u64, @intCast(@intFromPtr(pointer))))));
    }
};

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
        @compileError("BunString heap-profiler fixture layout drifted");
    if (@offsetOf(WTFStringImpl, "pointer") != 8 or @offsetOf(WTFStringImpl, "hash_and_flags") != 16)
        @compileError("WTF StringImpl heap-profiler prefix drifted");
}

extern fn JSC__VM__create(heap_type: u8) *VM;
extern fn JSC__VM__deinit(vm: *VM, global: *JSGlobalObject) void;
extern fn JSGlobalContextCreateInGroup(group: ?*anyopaque, global_class: ?*anyopaque) ?*JSGlobalObject;
extern fn ZJSGlobalContextCreateGarbageCollected(enable_jit: bool) ?*JSGlobalObject;
extern fn JSGlobalContextRelease(global: ?*JSGlobalObject) void;
extern fn JSContextGetGroup(global: ?*JSGlobalObject) ?*anyopaque;
extern fn ZJSContextCompactGarbage(global: ?*JSGlobalObject, moved_cells: ?*usize, moved_bytes: ?*usize) c_uint;
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
extern fn JSC__JSGlobalObject__generateHeapSnapshot(global: ?*JSGlobalObject) EncodedValue;
extern fn JSC__JSValue__getPropertyValue(
    value: EncodedValue,
    global: ?*JSGlobalObject,
    property: [*]const u8,
    property_length: u32,
) EncodedValue;
extern fn JSC__JSValue__getLengthIfPropertyExistsInternal(value: EncodedValue, global: ?*JSGlobalObject) f64;
extern fn JSC__JSValue__isStrictEqual(left: EncodedValue, right: EncodedValue, global: ?*JSGlobalObject) bool;
extern fn Bun__JSValue__toNumber(value: EncodedValue, global: ?*JSGlobalObject) f64;

pub extern fn Bun__WTFStringImpl__deref(string: ?*WTFStringImpl) void;

pub fn createFixtureVM() !struct { vm: *VM, global: *JSGlobalObject, sibling: *JSGlobalObject } {
    const vm = JSC__VM__create(0);
    const global = JSGlobalContextCreateInGroup(@ptrCast(vm), null) orelse return error.ContextCreateFailed;
    errdefer JSGlobalContextRelease(global);
    const sibling = JSGlobalContextCreateInGroup(@ptrCast(vm), null) orelse return error.ContextCreateFailed;
    errdefer JSGlobalContextRelease(sibling);
    try evaluate(global,
        \\globalThis.stableNode403 = { cycle403: null, marker403: 403 };
        \\stableNode403.cycle403 = stableNode403;
        \\globalThis.bufferRoot403 = new Uint8Array(new ArrayBuffer(64));
        \\let weakOnly403 = { weakOnlyMarker403: 1 };
        \\globalThis.weakRef403 = new WeakRef(weakOnly403);
        \\weakOnly403 = null;
        \\globalThis.loneSurrogate403 = '\uD800';
    );
    try evaluate(sibling, "globalThis.siblingRoot403 = { siblingMarker403: { value: 403 } };");
    return .{ .vm = vm, .global = global, .sibling = sibling };
}

pub fn destroyFixtureVM(vm: *VM, global: *JSGlobalObject, sibling: *JSGlobalObject) void {
    JSGlobalContextRelease(sibling);
    JSC__VM__deinit(vm, global);
    JSGlobalContextRelease(global);
}

pub fn createGcFixture() !struct { vm: *VM, global: *JSGlobalObject } {
    const global = ZJSGlobalContextCreateGarbageCollected(false) orelse return error.ContextCreateFailed;
    errdefer JSGlobalContextRelease(global);
    try evaluate(global,
        \\globalThis.discard403 = [];
        \\for (let i = 0; i < 4096; i++) discard403.push({ dead403: i });
        \\globalThis.stableNode403 = { cycle403: null, marker403: 403 };
        \\stableNode403.cycle403 = stableNode403;
        \\globalThis.bufferRoot403 = new Uint8Array(new ArrayBuffer(64));
        \\globalThis.siblingRoot403 = { siblingMarker403: { value: 403 } };
        \\let weakOnly403 = { weakOnlyMarker403: 1 };
        \\globalThis.weakRef403 = new WeakRef(weakOnly403);
        \\weakOnly403 = null;
        \\globalThis.loneSurrogate403 = '\uD800';
        \\discard403 = null;
    );
    const vm = JSContextGetGroup(global) orelse return error.MissingVM;
    return .{ .vm = @ptrCast(@alignCast(vm)), .global = global };
}

pub fn compactGcFixture(global: *JSGlobalObject) !void {
    var moved_cells: usize = 0;
    var moved_bytes: usize = 0;
    const status = ZJSContextCompactGarbage(global, &moved_cells, &moved_bytes);
    if (status != 3 or moved_cells == 0 or moved_bytes == 0) return error.CompactionDidNotMove;
}

pub fn destroyGcFixture(global: *JSGlobalObject) void {
    JSGlobalContextRelease(global);
}

fn evaluate(global: *JSGlobalObject, source: [*:0]const u8) !void {
    const script = JSStringCreateWithUTF8CString(source) orelse return error.StringCreateFailed;
    defer JSStringRelease(script);
    var exception: ?*JSValue = null;
    _ = JSEvaluateScript(global, script, null, null, 1, &exception) orelse return error.EvaluationFailed;
    if (exception != null) return error.EvaluationThrew;
}

fn evaluateValue(global: *JSGlobalObject, source: [*:0]const u8) !EncodedValue {
    const script = JSStringCreateWithUTF8CString(source) orelse return error.StringCreateFailed;
    defer JSStringRelease(script);
    var exception: ?*JSValue = null;
    const result = JSEvaluateScript(global, script, null, null, 1, &exception) orelse return error.EvaluationFailed;
    if (exception != null) return error.EvaluationThrew;
    return EncodedValue.fromRef(result);
}

pub fn validateGCDebugging(global: *JSGlobalObject) !void {
    const snapshot = JSC__JSGlobalObject__generateHeapSnapshot(global);
    try std.testing.expect(snapshot != .empty);
    const version = JSC__JSValue__getPropertyValue(snapshot, global, "version", 7);
    try std.testing.expectEqual(@as(f64, 3), Bun__JSValue__toNumber(version, global));
    const type_value = JSC__JSValue__getPropertyValue(snapshot, global, "type", 4);
    try std.testing.expect(JSC__JSValue__isStrictEqual(type_value, try evaluateValue(global, "'GCDebugging'"), global));
    inline for (.{ "nodes", "nodeClassNames", "edges", "edgeTypes", "edgeNames", "roots", "labels" }) |name| {
        const field = JSC__JSValue__getPropertyValue(snapshot, global, name, name.len);
        try std.testing.expect(JSC__JSValue__getLengthIfPropertyExistsInternal(field, global) > 0);
    }
}

pub fn ownedImplBytes(allocator: std.mem.Allocator, implementation: *WTFStringImpl) ![]u8 {
    if (implementation.hash_and_flags & (1 << 2) != 0)
        return allocator.dupe(u8, implementation.pointer[0..implementation.length]);
    const units: [*]const u16 = @ptrCast(@alignCast(implementation.pointer));
    return std.unicode.wtf16LeToWtf8Alloc(allocator, units[0..implementation.length]);
}

const V8Snapshot = struct {
    snapshot: struct {
        node_count: usize,
        edge_count: usize,
    },
    nodes: []const u64,
    edges: []const u64,
    strings: []const []const u8,
};

fn stringIndex(snapshot: V8Snapshot, needle: []const u8) ?usize {
    for (snapshot.strings, 0..) |string, index|
        if (std.mem.eql(u8, string, needle)) return index;
    return null;
}

pub fn validateV8Snapshot(bytes: []const u8) !u64 {
    var parsed = try std.json.parseFromSlice(V8Snapshot, std.heap.page_allocator, bytes, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    const snapshot = parsed.value;
    try std.testing.expect(snapshot.snapshot.node_count > 1);
    try std.testing.expect(snapshot.snapshot.edge_count > 0);
    try std.testing.expectEqual(snapshot.snapshot.node_count * 7, snapshot.nodes.len);
    try std.testing.expectEqual(snapshot.snapshot.edge_count * 3, snapshot.edges.len);
    inline for (.{ "stableNode403", "cycle403", "bufferRoot403", "siblingRoot403", "siblingMarker403", "loneSurrogate403" }) |name|
        try std.testing.expect(stringIndex(snapshot, name) != null);
    try std.testing.expect(stringIndex(snapshot, "weakOnlyMarker403") == null);

    const property_index = stringIndex(snapshot, "stableNode403") orelse return error.MissingStableProperty;
    var edge_offset: usize = 0;
    while (edge_offset < snapshot.edges.len) : (edge_offset += 3) {
        if (snapshot.edges[edge_offset] != 2 or snapshot.edges[edge_offset + 1] != property_index) continue;
        const node_offset: usize = @intCast(snapshot.edges[edge_offset + 2]);
        if (node_offset + 2 >= snapshot.nodes.len or node_offset % 7 != 0) return error.InvalidNodeOffset;
        const id = snapshot.nodes[node_offset + 2];
        if (id <= 1) return error.InvalidStableId;
        return id;
    }
    return error.MissingStableEdge;
}

pub fn validateProfile(bytes: []const u8) !void {
    inline for (.{ "# Bun Heap Profile", "## Type Statistics", "## GC Roots", "## Complete Cells", "## Complete Strong Edges", "stableNode403", "siblingRoot403" }) |needle|
        try std.testing.expect(std.mem.indexOf(u8, bytes, needle) != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "weakOnlyMarker403") == null);
}
