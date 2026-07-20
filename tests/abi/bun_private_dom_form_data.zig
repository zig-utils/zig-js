const std = @import("std");

const JSContextRef = ?*anyopaque;
const JSValueRef = ?*anyopaque;
const JSObjectRef = ?*anyopaque;
const JSStringRef = ?*anyopaque;

const EncodedValue = enum(i64) {
    empty = 0,
    _,

    fn fromRef(value: JSValueRef) EncodedValue {
        return @enumFromInt(@as(i64, @bitCast(@as(u64, @intFromPtr(value.?)))));
    }
};

const ZigString = extern struct {
    tagged_ptr: usize,
    len: usize,
};

const ForEachCallback = *const fn (?*anyopaque, *ZigString, *anyopaque, ?*ZigString, u8) callconv(.c) void;

extern "c" fn JSGlobalContextCreate(?*anyopaque) JSContextRef;
extern "c" fn JSGlobalContextRelease(JSContextRef) void;
extern "c" fn JSStringCreateWithUTF8CString([*:0]const u8) JSStringRef;
extern "c" fn JSStringRelease(JSStringRef) void;
extern "c" fn JSEvaluateScript(JSContextRef, JSStringRef, JSObjectRef, JSStringRef, c_int, [*c]JSValueRef) JSValueRef;
extern "c" fn JSC__JSValue__toBoolean(EncodedValue) bool;
extern "c" fn JSC__JSGlobalObject__vm(JSContextRef) ?*anyopaque;

// Exact declarations consumed by Bun's pinned src/jsc/DOMFormData.zig.
extern "c" fn WebCore__DOMFormData__cast_(EncodedValue, ?*anyopaque) ?*anyopaque;
extern "c" fn WebCore__DOMFormData__create(JSContextRef) EncodedValue;
extern "c" fn WebCore__DOMFormData__createFromURLQuery(JSContextRef, *ZigString) EncodedValue;
extern "c" fn WebCore__DOMFormData__toQueryString(?*anyopaque, ?*anyopaque, *const fn (?*anyopaque, *ZigString) callconv(.c) void) void;
extern "c" fn WebCore__DOMFormData__fromJS(EncodedValue) ?*anyopaque;
extern "c" fn WebCore__DOMFormData__append(?*anyopaque, *ZigString, *ZigString) void;
extern "c" fn WebCore__DOMFormData__appendBlob(?*anyopaque, JSContextRef, *ZigString, *anyopaque, *ZigString) void;
extern "c" fn WebCore__DOMFormData__count(?*anyopaque) usize;
extern "c" fn DOMFormData__toQueryString(?*anyopaque, ?*anyopaque, *const fn (?*anyopaque, *ZigString) callconv(.c) void) void;
extern "c" fn DOMFormData__forEach(?*anyopaque, ?*anyopaque, ForEachCallback) void;

fn fail(message: []const u8) noreturn {
    std.debug.panic("{s}", .{message});
}

fn evaluate(context: JSContextRef, source: [*:0]const u8) EncodedValue {
    const script = JSStringCreateWithUTF8CString(source) orelse fail("script string creation failed");
    defer JSStringRelease(script);
    var exception: JSValueRef = null;
    const result = JSEvaluateScript(context, script, null, null, 1, &exception);
    if (exception != null or result == null) fail("script evaluation failed");
    return EncodedValue.fromRef(result);
}

fn zigString(bytes: []const u8) ZigString {
    return .{ .tagged_ptr = @intFromPtr(bytes.ptr), .len = bytes.len };
}

fn zigStringEquals(actual: ZigString, expected: []const u8) bool {
    if (actual.tagged_ptr & (@as(usize, 1) << 63) != 0) return false;
    const pointer = actual.tagged_ptr & ((@as(usize, 1) << 53) - 1);
    const bytes: [*]const u8 = @ptrFromInt(pointer);
    return actual.len == expected.len and std.mem.eql(u8, bytes[0..actual.len], expected);
}

const QueryState = struct {
    calls: usize = 0,
    value: ZigString = .{ .tagged_ptr = 0, .len = 0 },
};

fn queryCallback(raw: ?*anyopaque, value: *ZigString) callconv(.c) void {
    const state: *QueryState = @ptrCast(@alignCast(raw.?));
    state.calls += 1;
    state.value = value.*;
}

const EachEntry = struct {
    name: ZigString = .{ .tagged_ptr = 0, .len = 0 },
    value: ZigString = .{ .tagged_ptr = 0, .len = 0 },
    filename: ZigString = .{ .tagged_ptr = 0, .len = 0 },
    blob: ?*anyopaque = null,
    is_blob: bool = false,
};

const EachState = struct {
    entries: [8]EachEntry = @splat(.{}),
    calls: usize = 0,
};

fn eachCallback(raw: ?*anyopaque, name: *ZigString, value: *anyopaque, filename: ?*ZigString, is_blob: u8) callconv(.c) void {
    const state: *EachState = @ptrCast(@alignCast(raw.?));
    if (state.calls == state.entries.len or is_blob > 1) fail("Bun DOMFormData callback metadata mismatch");
    const entry = &state.entries[state.calls];
    entry.name = name.*;
    entry.is_blob = is_blob != 0;
    if (entry.is_blob) {
        entry.blob = value;
        entry.filename = if (filename) |name_value| name_value.* else .{ .tagged_ptr = 0, .len = 0 };
    } else {
        if (filename != null) fail("Bun DOMFormData string callback filename mismatch");
        entry.value = @as(*ZigString, @ptrCast(@alignCast(value))).*;
    }
    state.calls += 1;
}

pub fn main() void {
    const context = JSGlobalContextCreate(null) orelse fail("context creation failed");
    defer JSGlobalContextRelease(context);
    const vm = JSC__JSGlobalObject__vm(context) orelse fail("VM projection failed");

    const query_bytes = "a=1&b=two+words";
    var query = zigString(query_bytes);
    const form_value = WebCore__DOMFormData__createFromURLQuery(context, &query);
    const form = WebCore__DOMFormData__fromJS(form_value) orelse fail("Bun DOMFormData create/fromJS failed");
    if (WebCore__DOMFormData__cast_(form_value, vm) != form or WebCore__DOMFormData__count(form) != 2)
        fail("Bun DOMFormData cast/count mismatch");

    const duplicate_name_bytes = "a";
    const duplicate_value_bytes = "2";
    var duplicate_name = zigString(duplicate_name_bytes);
    var duplicate_value = zigString(duplicate_value_bytes);
    WebCore__DOMFormData__append(form, &duplicate_name, &duplicate_value);

    var native_blob_sentinel: usize = 0xB00B_374;
    const native_blob: *anyopaque = @ptrCast(&native_blob_sentinel);
    const blob_name_bytes = "file";
    const filename_bytes = "fixture.bin";
    var blob_name = zigString(blob_name_bytes);
    var filename = zigString(filename_bytes);
    WebCore__DOMFormData__appendBlob(form, context, &blob_name, native_blob, &filename);
    if (WebCore__DOMFormData__count(form) != 4) fail("Bun DOMFormData append count mismatch");

    var query_state: QueryState = .{};
    WebCore__DOMFormData__toQueryString(form, &query_state, queryCallback);
    if (query_state.calls != 1 or !zigStringEquals(query_state.value, "a=1&b=two+words&a=2"))
        fail("Bun DOMFormData WebCore serialization mismatch");
    query_state = .{};
    DOMFormData__toQueryString(form, &query_state, queryCallback);
    if (query_state.calls != 1 or !zigStringEquals(query_state.value, "a=1&b=two+words&a=2"))
        fail("Bun DOMFormData serialization alias mismatch");

    var each: EachState = .{};
    DOMFormData__forEach(form, &each, eachCallback);
    if (each.calls != 4 or !zigStringEquals(each.entries[0].name, "a") or
        !zigStringEquals(each.entries[1].value, "two words") or
        !each.entries[3].is_blob or each.entries[3].blob != native_blob or
        !zigStringEquals(each.entries[3].name, "file") or
        !zigStringEquals(each.entries[3].filename, "fixture.bin"))
        fail("Bun DOMFormData forEach projection mismatch");

    const empty = WebCore__DOMFormData__create(context);
    if (empty == .empty or WebCore__DOMFormData__fromJS(empty) == null)
        fail("Bun DOMFormData empty create failed");
    const js_form = evaluate(context,
        \\const fd = new FormData();
        \\fd.append('blob', new Blob(['abc']), 'x.bin');
        \\fd;
    );
    const js_form_native = WebCore__DOMFormData__fromJS(js_form) orelse fail("Bun DOMFormData rejected JS instance");
    var js_each: EachState = .{};
    DOMFormData__forEach(js_form_native, &js_each, eachCallback);
    if (WebCore__DOMFormData__count(js_form_native) != 1 or js_each.calls != 1 or
        !js_each.entries[0].is_blob or !zigStringEquals(js_each.entries[0].filename, "x.bin") or
        !JSC__JSValue__toBoolean(evaluate(context, "fd.get('blob') instanceof File && fd.get('blob').size === 3")))
        fail("Bun DOMFormData JS Blob integration mismatch");

    std.debug.print("Bun private DOMFormData: 10/10 symbols linked; runtime matrix passed\n", .{});
}
