const std = @import("std");

const JSContextRef = ?*anyopaque;
const JSValueRef = ?*anyopaque;
const JSObjectRef = ?*anyopaque;
const JSStringRef = ?*anyopaque;

const EncodedValue = enum(i64) {
    empty = 0,
    undefined = 10,
    _,

    fn fromRef(value: JSValueRef) EncodedValue {
        return @enumFromInt(@as(i64, @bitCast(@as(u64, @intFromPtr(value.?)))));
    }
};

const BunStringTag = enum(u8) {
    dead = 0,
    wtf_string_impl = 1,
    zig_string = 2,
    static_zig_string = 3,
    empty = 4,
};
const ZigString = extern struct { tagged_ptr: usize = 0, len: usize = 0 };
const BunStringImpl = extern union {
    zig_string: ZigString,
    wtf_string_impl: ?*anyopaque,
};
const BunString = extern struct {
    tag: BunStringTag,
    value: BunStringImpl,

    fn dead() BunString {
        return .{ .tag = .dead, .value = .{ .zig_string = .{} } };
    }
};
const JSPropertyIterator = opaque {};

comptime {
    if (@sizeOf(BunString) != 24 or @alignOf(BunString) != 8 or @offsetOf(BunString, "value") != 8)
        @compileError("Bun property-iterator BunString layout drifted");
}

extern "c" fn JSGlobalContextCreate(?*anyopaque) JSContextRef;
extern "c" fn JSGlobalContextRelease(JSContextRef) void;
extern "c" fn JSStringCreateWithUTF8CString([*:0]const u8) JSStringRef;
extern "c" fn JSStringRelease(JSStringRef) void;
extern "c" fn JSEvaluateScript(JSContextRef, JSStringRef, JSObjectRef, JSStringRef, c_int, [*c]JSValueRef) JSValueRef;
extern "c" fn JSValueToNumber(JSContextRef, JSValueRef, [*c]JSValueRef) f64;
extern "c" fn BunString__toJS(JSContextRef, *const BunString) EncodedValue;
extern "c" fn JSC__JSValue__isStrictEqual(EncodedValue, EncodedValue, JSContextRef) bool;
extern "c" fn Bun__JSPropertyIterator__create(JSContextRef, EncodedValue, *usize, bool, bool) ?*JSPropertyIterator;
extern "c" fn Bun__JSPropertyIterator__deinit(*JSPropertyIterator) void;
extern "c" fn Bun__JSPropertyIterator__getLongestPropertyName(*JSPropertyIterator, JSContextRef, ?*anyopaque) usize;
extern "c" fn Bun__JSPropertyIterator__getName(*JSPropertyIterator, *BunString, usize) void;
extern "c" fn Bun__JSPropertyIterator__getNameAndValue(*JSPropertyIterator, JSContextRef, ?*anyopaque, *BunString, usize) EncodedValue;
extern "c" fn Bun__JSPropertyIterator__getNameAndValueNonObservable(*JSPropertyIterator, JSContextRef, ?*anyopaque, *BunString, usize) EncodedValue;
extern "c" fn JSC__JSValue__putBunString(EncodedValue, JSContextRef, *const BunString, EncodedValue) void;
extern "c" fn JSC__JSValue__upsertBunStringArray(EncodedValue, JSContextRef, *const BunString, EncodedValue) EncodedValue;
extern "c" fn JSC__JSValue__hasOwnPropertyValue(EncodedValue, JSContextRef, EncodedValue) bool;

fn fail(message: []const u8) noreturn {
    std.debug.panic("{s}", .{message});
}

fn evaluate(context: JSContextRef, source: [*:0]const u8) JSValueRef {
    const script = JSStringCreateWithUTF8CString(source) orelse fail("script string creation failed");
    defer JSStringRelease(script);
    var exception: JSValueRef = null;
    const result = JSEvaluateScript(context, script, null, null, 1, &exception);
    if (exception != null or result == null) fail("script evaluation failed");
    return result;
}

fn nameEquals(context: JSContextRef, name: *const BunString, expected: [*:0]const u8) bool {
    return JSC__JSValue__isStrictEqual(
        BunString__toJS(context, name),
        EncodedValue.fromRef(evaluate(context, expected)),
        context,
    );
}

pub fn main() void {
    const context = JSGlobalContextCreate(null) orelse fail("context creation failed");
    defer JSGlobalContextRelease(context);
    const target_ref = evaluate(context, "globalThis.__bun_property_gets_368 = 0; " ++
        "globalThis.__bun_property_target_368 = { 0: 1, alpha: 10, " ++
        "get getter() { __bun_property_gets_368++; return 20; }, 'unicode😀key': 30 }; " ++
        "__bun_property_target_368");
    const target = EncodedValue.fromRef(target_ref);
    var count: usize = 999;
    const iterator = Bun__JSPropertyIterator__create(context, target, &count, true, false) orelse
        fail("Bun property iterator creation failed");
    defer Bun__JSPropertyIterator__deinit(iterator);

    if (count != 4 or Bun__JSPropertyIterator__getLongestPropertyName(iterator, context, target_ref) != 12)
        fail("Bun property iterator count/length mismatch");
    var name = BunString.dead();
    Bun__JSPropertyIterator__getName(iterator, &name, 1);
    if (name.tag != .zig_string or !nameEquals(context, &name, "'alpha'"))
        fail("Bun property iterator borrowed name mismatch");
    Bun__JSPropertyIterator__getName(iterator, &name, 3);
    if (!nameEquals(context, &name, "'unicode😀key'"))
        fail("Bun property iterator UTF-16 name mismatch");

    if (Bun__JSPropertyIterator__getNameAndValueNonObservable(iterator, context, target_ref, &name, 2) != .empty or
        name.tag != .dead or JSValueToNumber(context, evaluate(context, "__bun_property_gets_368"), null) != 0)
        fail("Bun property iterator VM inquiry invoked a getter");
    const observable = Bun__JSPropertyIterator__getNameAndValue(iterator, context, target_ref, &name, 2);
    if (!JSC__JSValue__isStrictEqual(observable, EncodedValue.fromRef(evaluate(context, "20")), context) or
        !nameEquals(context, &name, "'getter'") or
        JSValueToNumber(context, evaluate(context, "__bun_property_gets_368"), null) != 1)
        fail("Bun property iterator observable getter mismatch");

    _ = evaluate(context, "delete __bun_property_target_368.alpha; __bun_property_target_368.afterSnapshot = 40");
    if (Bun__JSPropertyIterator__getNameAndValue(iterator, context, target_ref, &name, 1) != .empty)
        fail("Bun property iterator ignored live deletion");
    Bun__JSPropertyIterator__getName(iterator, &name, 1);
    if (!nameEquals(context, &name, "'alpha'"))
        fail("Bun property iterator snapshot changed after mutation");

    const property_target = EncodedValue.fromRef(evaluate(context, "globalThis.__bun_property_ops_370 = {}; __bun_property_ops_370"));
    const direct_bytes = "direct";
    const direct = BunString{
        .tag = .static_zig_string,
        .value = .{ .zig_string = .{ .tagged_ptr = @intFromPtr(direct_bytes.ptr), .len = direct_bytes.len } },
    };
    const one = EncodedValue.fromRef(evaluate(context, "1"));
    const two = EncodedValue.fromRef(evaluate(context, "2"));
    JSC__JSValue__putBunString(property_target, context, &direct, one);
    if (!JSC__JSValue__hasOwnPropertyValue(property_target, context, EncodedValue.fromRef(evaluate(context, "'direct'"))))
        fail("Bun value-key own-property query mismatch");
    const items_bytes = "items";
    const items = BunString{
        .tag = .static_zig_string,
        .value = .{ .zig_string = .{ .tagged_ptr = @intFromPtr(items_bytes.ptr), .len = items_bytes.len } },
    };
    if (JSC__JSValue__upsertBunStringArray(property_target, context, &items, one) != .undefined or
        JSC__JSValue__upsertBunStringArray(property_target, context, &items, two) != .undefined)
        fail("Bun one-or-array upsert returned an invalid value");
    if (JSValueToNumber(context, evaluate(context, "__bun_property_ops_370.items.length"), null) != 2)
        fail("Bun one-or-array upsert mismatch");
}
