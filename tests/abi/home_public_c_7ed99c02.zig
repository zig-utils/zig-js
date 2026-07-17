const std = @import("std");

const JSValue = opaque {};
const JSObject = opaque {};
const JSContextRef = opaque {};
const JSString = opaque {};

const JSType = enum(c_uint) {
    kJSTypeUndefined,
    kJSTypeNull,
    kJSTypeBoolean,
    kJSTypeNumber,
    kJSTypeString,
    kJSTypeObject,
    kJSTypeSymbol,
    kJSTypeBigInt,
};

const JSTypedArrayType = enum(c_uint) {
    kJSTypedArrayTypeInt8Array,
    kJSTypedArrayTypeInt16Array,
    kJSTypedArrayTypeInt32Array,
    kJSTypedArrayTypeUint8Array,
    kJSTypedArrayTypeUint8ClampedArray,
    kJSTypedArrayTypeUint16Array,
    kJSTypedArrayTypeUint32Array,
    kJSTypedArrayTypeFloat32Array,
    kJSTypedArrayTypeFloat64Array,
    kJSTypedArrayTypeArrayBuffer,
    kJSTypedArrayTypeNone,
    kJSTypedArrayTypeBigInt64Array,
    kJSTypedArrayTypeBigUint64Array,
    _,
};

const ExceptionRef = [*c]?*JSValue;
const JSObjectCallAsFunctionCallback = *const fn (
    ctx: ?*JSContextRef,
    function: ?*JSObject,
    this_object: ?*JSObject,
    argument_count: usize,
    arguments: [*c]const ?*JSValue,
    exception: ExceptionRef,
) callconv(.c) ?*JSValue;

extern "c" fn JSGarbageCollect(ctx: ?*JSContextRef) void;
extern "c" fn JSGlobalContextCreate(global_class: ?*anyopaque) ?*JSContextRef;
extern "c" fn JSGlobalContextRelease(ctx: ?*JSContextRef) void;
extern "c" fn JSGlobalContextRetain(ctx: ?*JSContextRef) ?*JSContextRef;
extern "c" fn JSContextGetGlobalObject(ctx: ?*JSContextRef) ?*JSObject;
extern "c" fn JSEvaluateScript(ctx: ?*JSContextRef, script: ?*JSString, this_object: ?*JSObject, source_url: ?*JSString, starting_line_number: c_int, exception: ExceptionRef) ?*JSValue;
extern "c" fn JSValueGetType(ctx: ?*JSContextRef, value: ?*JSValue) JSType;
extern "c" fn JSValueIsUndefined(ctx: ?*JSContextRef, value: ?*JSValue) bool;
extern "c" fn JSValueIsNull(ctx: ?*JSContextRef, value: ?*JSValue) bool;
extern "c" fn JSValueIsBoolean(ctx: ?*JSContextRef, value: ?*JSValue) bool;
extern "c" fn JSValueIsNumber(ctx: ?*JSContextRef, value: ?*JSValue) bool;
extern "c" fn JSValueIsString(ctx: ?*JSContextRef, value: ?*JSValue) bool;
extern "c" fn JSValueIsObject(ctx: ?*JSContextRef, value: ?*JSValue) bool;
extern "c" fn JSValueIsArray(ctx: ?*JSContextRef, value: ?*JSValue) bool;
extern "c" fn JSValueIsDate(ctx: ?*JSContextRef, value: ?*JSValue) bool;
extern "c" fn JSValueIsEqual(ctx: ?*JSContextRef, a: ?*JSValue, b: ?*JSValue, exception: ExceptionRef) bool;
extern "c" fn JSValueIsStrictEqual(ctx: ?*JSContextRef, a: ?*JSValue, b: ?*JSValue) bool;
extern "c" fn JSValueMakeUndefined(ctx: ?*JSContextRef) ?*JSValue;
extern "c" fn JSValueMakeNull(ctx: ?*JSContextRef) ?*JSValue;
extern "c" fn JSValueMakeBoolean(ctx: ?*JSContextRef, b: bool) ?*JSValue;
extern "c" fn JSValueMakeNumber(ctx: ?*JSContextRef, n: f64) ?*JSValue;
extern "c" fn JSValueMakeString(ctx: ?*JSContextRef, str: ?*JSString) ?*JSValue;
extern "c" fn JSValueToBoolean(ctx: ?*JSContextRef, value: ?*JSValue) bool;
extern "c" fn JSValueToNumber(ctx: ?*JSContextRef, value: ?*JSValue, exception: ExceptionRef) f64;
extern "c" fn JSValueToStringCopy(ctx: ?*JSContextRef, value: ?*JSValue, exception: ExceptionRef) ?*JSString;
extern "c" fn JSValueToObject(ctx: ?*JSContextRef, value: ?*JSValue, exception: ExceptionRef) ?*JSObject;
extern "c" fn JSValueProtect(ctx: ?*JSContextRef, value: ?*JSValue) void;
extern "c" fn JSValueUnprotect(ctx: ?*JSContextRef, value: ?*JSValue) void;
extern "c" fn JSObjectMake(ctx: ?*JSContextRef, class: ?*anyopaque, data: ?*anyopaque) ?*JSObject;
extern "c" fn JSObjectMakeArray(ctx: ?*JSContextRef, argc: usize, argv: [*c]const ?*JSValue, exception: ExceptionRef) ?*JSObject;
extern "c" fn JSObjectMakeDeferredPromise(ctx: ?*JSContextRef, resolve: [*c]?*JSObject, reject: [*c]?*JSObject, exception: ExceptionRef) ?*JSObject;
extern "c" fn JSObjectGetProperty(ctx: ?*JSContextRef, object: ?*JSObject, name: ?*JSString, exception: ExceptionRef) ?*JSValue;
extern "c" fn JSObjectSetProperty(ctx: ?*JSContextRef, object: ?*JSObject, name: ?*JSString, value: ?*JSValue, attrs: c_uint, exception: ExceptionRef) void;
extern "c" fn JSObjectGetPropertyAtIndex(ctx: ?*JSContextRef, object: ?*JSObject, index: c_uint, exception: ExceptionRef) ?*JSValue;
extern "c" fn JSObjectCallAsFunction(ctx: ?*JSContextRef, fun: ?*JSObject, this: ?*JSObject, argc: usize, argv: [*c]const ?*JSValue, exception: ExceptionRef) ?*JSValue;
extern "c" fn JSObjectMakeFunctionWithCallback(ctx: ?*JSContextRef, name: ?*JSString, callback: JSObjectCallAsFunctionCallback) ?*JSObject;
extern "c" fn JSObjectCallAsConstructor(ctx: ?*JSContextRef, constructor: ?*JSObject, argc: usize, argv: [*c]const ?*JSValue, exception: ExceptionRef) ?*JSObject;
extern "c" fn JSObjectIsFunction(ctx: ?*JSContextRef, object: ?*JSObject) bool;
extern "c" fn JSObjectIsConstructor(ctx: ?*JSContextRef, object: ?*JSObject) bool;
extern "c" fn JSObjectMakeTypedArray(ctx: ?*JSContextRef, array_type: JSTypedArrayType, length: usize, exception: ExceptionRef) ?*JSObject;
extern "c" fn JSObjectGetTypedArrayBytesPtr(ctx: ?*JSContextRef, object: ?*JSObject, exception: ExceptionRef) ?*anyopaque;
extern "c" fn JSObjectGetTypedArrayLength(ctx: ?*JSContextRef, object: ?*JSObject, exception: ExceptionRef) usize;
extern "c" fn JSObjectGetTypedArrayByteLength(ctx: ?*JSContextRef, object: ?*JSObject, exception: ExceptionRef) usize;
extern "c" fn JSValueGetTypedArrayType(ctx: ?*JSContextRef, value: ?*JSValue, exception: ExceptionRef) JSTypedArrayType;
extern "c" fn JSStringCreateWithUTF8CString(utf8: [*:0]const u8) ?*JSString;
extern "c" fn JSStringRetain(str: ?*JSString) ?*JSString;
extern "c" fn JSStringRelease(str: ?*JSString) void;
extern "c" fn JSStringGetLength(str: ?*JSString) usize;
extern "c" fn JSStringGetUTF8CString(str: ?*JSString, buf: [*]u8, buf_size: usize) usize;
extern "c" fn JSStringGetCharactersPtr(str: ?*JSString) [*]const u16;

const required_symbols = [_]*const anyopaque{
    @ptrCast(&JSGarbageCollect),
    @ptrCast(&JSGlobalContextCreate),
    @ptrCast(&JSGlobalContextRelease),
    @ptrCast(&JSGlobalContextRetain),
    @ptrCast(&JSContextGetGlobalObject),
    @ptrCast(&JSEvaluateScript),
    @ptrCast(&JSValueGetType),
    @ptrCast(&JSValueIsUndefined),
    @ptrCast(&JSValueIsNull),
    @ptrCast(&JSValueIsBoolean),
    @ptrCast(&JSValueIsNumber),
    @ptrCast(&JSValueIsString),
    @ptrCast(&JSValueIsObject),
    @ptrCast(&JSValueIsArray),
    @ptrCast(&JSValueIsDate),
    @ptrCast(&JSValueIsEqual),
    @ptrCast(&JSValueIsStrictEqual),
    @ptrCast(&JSValueMakeUndefined),
    @ptrCast(&JSValueMakeNull),
    @ptrCast(&JSValueMakeBoolean),
    @ptrCast(&JSValueMakeNumber),
    @ptrCast(&JSValueMakeString),
    @ptrCast(&JSValueToBoolean),
    @ptrCast(&JSValueToNumber),
    @ptrCast(&JSValueToStringCopy),
    @ptrCast(&JSValueToObject),
    @ptrCast(&JSValueProtect),
    @ptrCast(&JSValueUnprotect),
    @ptrCast(&JSObjectMake),
    @ptrCast(&JSObjectMakeArray),
    @ptrCast(&JSObjectMakeDeferredPromise),
    @ptrCast(&JSObjectGetProperty),
    @ptrCast(&JSObjectSetProperty),
    @ptrCast(&JSObjectGetPropertyAtIndex),
    @ptrCast(&JSObjectCallAsFunction),
    @ptrCast(&JSObjectMakeFunctionWithCallback),
    @ptrCast(&JSObjectCallAsConstructor),
    @ptrCast(&JSObjectIsFunction),
    @ptrCast(&JSObjectIsConstructor),
    @ptrCast(&JSObjectMakeTypedArray),
    @ptrCast(&JSObjectGetTypedArrayBytesPtr),
    @ptrCast(&JSObjectGetTypedArrayLength),
    @ptrCast(&JSObjectGetTypedArrayByteLength),
    @ptrCast(&JSValueGetTypedArrayType),
    @ptrCast(&JSStringCreateWithUTF8CString),
    @ptrCast(&JSStringRetain),
    @ptrCast(&JSStringRelease),
    @ptrCast(&JSStringGetLength),
    @ptrCast(&JSStringGetUTF8CString),
    @ptrCast(&JSStringGetCharactersPtr),
};

fn fail(message: []const u8) noreturn {
    std.debug.print("home public ABI fixture: {s}\n", .{message});
    std.process.exit(1);
}

pub fn main() void {
    std.mem.doNotOptimizeAway(&required_symbols);
    if (@sizeOf(JSType) != @sizeOf(c_uint) or @alignOf(JSType) != @alignOf(c_uint))
        fail("JSType layout mismatch");
    if (@sizeOf(JSTypedArrayType) != @sizeOf(c_uint) or @alignOf(JSTypedArrayType) != @alignOf(c_uint))
        fail("JSTypedArrayType layout mismatch");

    const context = JSGlobalContextCreate(null) orelse fail("context creation failed");
    defer JSGlobalContextRelease(context);
    if (JSGlobalContextRetain(context) != context) fail("context retain changed identity");
    JSGlobalContextRelease(context);

    const script = JSStringCreateWithUTF8CString("21 * 2") orelse fail("script string creation failed");
    defer JSStringRelease(script);
    var exception: ?*JSValue = null;
    const answer = JSEvaluateScript(context, script, null, null, 1, &exception) orelse
        fail("evaluation returned null");
    if (exception != null or !JSValueIsNumber(context, answer) or JSValueToNumber(context, answer, &exception) != 42)
        fail("number round trip failed");

    const array = JSObjectMakeTypedArray(context, .kJSTypedArrayTypeUint8Array, 4, &exception) orelse
        fail("typed array creation failed");
    if (exception != null or JSObjectGetTypedArrayLength(context, array, &exception) != 4 or
        JSObjectGetTypedArrayByteLength(context, array, &exception) != 4 or
        JSObjectGetTypedArrayBytesPtr(context, array, &exception) == null or
        JSValueGetTypedArrayType(context, @ptrCast(array), &exception) != .kJSTypedArrayTypeUint8Array)
        fail("typed array contract failed");

    JSGarbageCollect(context);
    std.debug.print("home public ABI: 50/50 symbols linked; runtime smoke passed\n", .{});
}
