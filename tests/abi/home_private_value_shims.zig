const std = @import("std");

const JSContextRef = ?*anyopaque;
const JSValueRef = ?*anyopaque;
const JSObjectRef = ?*anyopaque;
const JSStringRef = ?*anyopaque;

const EncodedValue = enum(i64) {
    empty = 0,
    null = 2,
    deleted = 4,
    false = 6,
    true = 7,
    undefined = 10,
    _,

    fn fromBits(bits: u64) EncodedValue {
        return @enumFromInt(@as(i64, @bitCast(bits)));
    }

    fn fromInt32(value: i32) EncodedValue {
        return fromBits(0xfffe_0000_0000_0000 | @as(u64, @as(u32, @bitCast(value))));
    }

    fn fromDouble(value: f64) EncodedValue {
        return fromBits(@as(u64, @bitCast(value)) +% (1 << 49));
    }

    fn fromRef(value: JSValueRef) EncodedValue {
        return fromBits(@intFromPtr(value.?));
    }

    fn cellPointer(value: EncodedValue) ?*anyopaque {
        const bits: u64 = @bitCast(@intFromEnum(value));
        if (bits == 0) return null;
        return @ptrFromInt(@as(usize, @intCast(bits)));
    }
};

extern "c" fn JSGlobalContextCreate(?*anyopaque) JSContextRef;
extern "c" fn JSGlobalContextRelease(JSContextRef) void;
extern "c" fn JSValueMakeString(JSContextRef, JSStringRef) JSValueRef;
extern "c" fn JSStringCreateWithUTF8CString([*:0]const u8) JSStringRef;
extern "c" fn JSStringRelease(JSStringRef) void;
extern "c" fn JSObjectMake(JSContextRef, ?*anyopaque, ?*anyopaque) JSObjectRef;
extern "c" fn JSObjectGetPrototype(JSContextRef, JSObjectRef) JSValueRef;
extern "c" fn JSEvaluateScript(JSContextRef, JSStringRef, JSObjectRef, JSStringRef, c_int, [*c]JSValueRef) JSValueRef;

extern "c" fn JSC__JSValue__eqlCell(EncodedValue, ?*anyopaque) bool;
extern "c" fn JSC__JSValue__eqlValue(EncodedValue, EncodedValue) bool;
extern "c" fn JSC__JSValue__toBoolean(EncodedValue) bool;
extern "c" fn JSC__JSValue__toInt32(EncodedValue) i32;
extern "c" fn JSC__JSValue__fromInt64NoTruncate(JSContextRef, i64) EncodedValue;
extern "c" fn JSC__JSValue__fromUInt64NoTruncate(JSContextRef, u64) EncodedValue;
extern "c" fn JSC__JSValue__toUInt64NoTruncate(EncodedValue) u64;
extern "c" fn JSC__JSValue__isStrictEqual(EncodedValue, EncodedValue, JSContextRef) bool;
extern "c" fn JSC__JSValue__isSameValue(EncodedValue, EncodedValue, JSContextRef) bool;
extern "c" fn JSC__JSBigInt__fromJS(EncodedValue) ?*anyopaque;
extern "c" fn JSC__JSBigInt__orderDouble(?*anyopaque, f64) i8;
extern "c" fn JSC__JSBigInt__orderInt64(?*anyopaque, i64) i8;
extern "c" fn JSC__JSBigInt__orderUint64(?*anyopaque, u64) i8;
extern "c" fn JSC__JSBigInt__toInt64(?*anyopaque) i64;
extern "c" fn JSC__JSValue__asString(EncodedValue) ?*anyopaque;
extern "c" fn JSC__JSString__eql(?*anyopaque, JSContextRef, ?*anyopaque) bool;
extern "c" fn JSC__JSString__is8Bit(?*anyopaque) bool;
extern "c" fn JSC__JSString__length(?*anyopaque) usize;
extern "c" fn JSC__JSString__toObject(?*anyopaque, JSContextRef) JSObjectRef;
extern "c" fn JSC__JSCell__getObject(?*anyopaque) JSObjectRef;
extern "c" fn JSC__JSCell__toObject(?*anyopaque, JSContextRef) JSObjectRef;
extern "c" fn JSC__JSValue__createEmptyObject(JSContextRef, usize) EncodedValue;
extern "c" fn JSC__JSValue__createEmptyObjectWithNullPrototype(JSContextRef) EncodedValue;
extern "c" fn JSC__JSValue__unwrapBoxedPrimitive(JSContextRef, EncodedValue) EncodedValue;

fn fail(message: []const u8) noreturn {
    std.debug.print("Home private value shims: {s}\n", .{message});
    std.process.exit(1);
}

fn evaluate(context: JSContextRef, source: [*:0]const u8) EncodedValue {
    const script = JSStringCreateWithUTF8CString(source) orelse fail("script string creation failed");
    defer JSStringRelease(script);
    var exception: JSValueRef = null;
    const result = JSEvaluateScript(context, script, null, null, 1, &exception);
    if (result == null or exception != null) fail("BigInt fixture evaluation failed");
    return EncodedValue.fromRef(result);
}

pub fn main() void {
    const context = JSGlobalContextCreate(null) orelse fail("context creation failed");
    defer JSGlobalContextRelease(context);

    if (JSC__JSValue__toBoolean(.empty) or JSC__JSValue__toBoolean(.undefined) or
        JSC__JSValue__toBoolean(.null) or JSC__JSValue__toBoolean(.false) or
        JSC__JSValue__toBoolean(EncodedValue.fromDouble(0.0)) or
        JSC__JSValue__toBoolean(EncodedValue.fromDouble(-0.0)) or
        JSC__JSValue__toBoolean(EncodedValue.fromDouble(std.math.nan(f64))))
        fail("falsey primitive mismatch");
    if (!JSC__JSValue__toBoolean(.true) or
        !JSC__JSValue__toBoolean(EncodedValue.fromInt32(-1)) or
        !JSC__JSValue__toBoolean(EncodedValue.fromDouble(42.5)))
        fail("truthy primitive mismatch");

    for ([_]i32{ std.math.minInt(i32), -1, 0, 1, std.math.maxInt(i32) }) |value| {
        if (JSC__JSValue__toInt32(EncodedValue.fromInt32(value)) != value)
            fail("int32 round trip failed");
    }
    if (!JSC__JSValue__eqlValue(.null, .null) or
        JSC__JSValue__eqlValue(.null, .undefined) or
        !JSC__JSValue__eqlValue(EncodedValue.fromDouble(-0.0), EncodedValue.fromDouble(-0.0)) or
        JSC__JSValue__eqlValue(EncodedValue.fromDouble(-0.0), EncodedValue.fromDouble(0.0)))
        fail("encoded identity mismatch");

    const empty_string = JSStringCreateWithUTF8CString("") orelse fail("empty string creation failed");
    defer JSStringRelease(empty_string);
    const text_string = JSStringCreateWithUTF8CString("value") orelse fail("string creation failed");
    defer JSStringRelease(text_string);
    const empty_value = JSValueMakeString(context, empty_string) orelse fail("empty value creation failed");
    const text_value = JSValueMakeString(context, text_string) orelse fail("value creation failed");
    const object = JSObjectMake(context, null, null) orelse fail("object creation failed");
    const encoded_empty = EncodedValue.fromRef(empty_value);
    const encoded_text = EncodedValue.fromRef(text_value);
    const encoded_object = EncodedValue.fromRef(object);
    if (JSC__JSValue__toBoolean(encoded_empty) or
        !JSC__JSValue__toBoolean(encoded_text) or
        !JSC__JSValue__toBoolean(encoded_object))
        fail("boxed truthiness mismatch");
    if (!JSC__JSValue__eqlCell(encoded_object, object) or
        JSC__JSValue__eqlCell(encoded_object, text_value) or
        !JSC__JSValue__eqlValue(encoded_object, EncodedValue.fromRef(object)) or
        JSC__JSValue__eqlValue(encoded_object, encoded_text))
        fail("boxed identity mismatch");

    const signed_min = JSC__JSValue__fromInt64NoTruncate(context, std.math.minInt(i64));
    const signed_negative = JSC__JSValue__fromInt64NoTruncate(context, -1);
    const unsigned_max = JSC__JSValue__fromUInt64NoTruncate(context, std.math.maxInt(u64));
    if (JSC__JSValue__toUInt64NoTruncate(signed_min) != (@as(u64, 1) << 63) or
        JSC__JSValue__toUInt64NoTruncate(signed_negative) != std.math.maxInt(u64) or
        JSC__JSValue__toUInt64NoTruncate(unsigned_max) != std.math.maxInt(u64) or
        JSC__JSValue__toUInt64NoTruncate(JSC__JSValue__fromUInt64NoTruncate(context, 0)) != 0)
        fail("BigInt modulo extraction mismatch");
    if (JSC__JSValue__toUInt64NoTruncate(EncodedValue.fromInt32(-1)) != std.math.maxInt(u64) or
        JSC__JSValue__toUInt64NoTruncate(EncodedValue.fromDouble(42.0)) != 42 or
        JSC__JSValue__toUInt64NoTruncate(EncodedValue.fromDouble(-1.0)) != 0 or
        JSC__JSValue__toUInt64NoTruncate(EncodedValue.fromDouble(1.5)) != 0 or
        JSC__JSValue__toUInt64NoTruncate(EncodedValue.fromDouble(@floatFromInt(@as(u64, 1) << 51))) != 0 or
        JSC__JSValue__toUInt64NoTruncate(.true) != 0)
        fail("number fallback extraction mismatch");

    if (!JSC__JSValue__isStrictEqual(.null, .null, context) or
        JSC__JSValue__isStrictEqual(.null, .undefined, context) or
        !JSC__JSValue__isStrictEqual(EncodedValue.fromInt32(42), EncodedValue.fromDouble(42.0), context) or
        !JSC__JSValue__isStrictEqual(EncodedValue.fromDouble(0.0), EncodedValue.fromDouble(-0.0), context) or
        JSC__JSValue__isStrictEqual(EncodedValue.fromDouble(std.math.nan(f64)), EncodedValue.fromDouble(std.math.nan(f64)), context) or
        JSC__JSValue__isStrictEqual(.empty, .empty, context) or
        JSC__JSValue__isStrictEqual(.deleted, .deleted, context))
        fail("strict primitive equality mismatch");
    if (!JSC__JSValue__isSameValue(EncodedValue.fromDouble(std.math.nan(f64)), EncodedValue.fromDouble(std.math.nan(f64)), context) or
        JSC__JSValue__isSameValue(EncodedValue.fromDouble(0.0), EncodedValue.fromDouble(-0.0), context) or
        !JSC__JSValue__isSameValue(EncodedValue.fromInt32(42), EncodedValue.fromDouble(42.0), context))
        fail("SameValue number mismatch");

    const same_text_string = JSStringCreateWithUTF8CString("value") orelse fail("same text creation failed");
    defer JSStringRelease(same_text_string);
    const same_text_value = JSValueMakeString(context, same_text_string) orelse fail("same text value creation failed");
    const other_object = JSObjectMake(context, null, null) orelse fail("other object creation failed");
    if (!JSC__JSValue__isStrictEqual(encoded_text, EncodedValue.fromRef(same_text_value), context) or
        !JSC__JSValue__isSameValue(encoded_text, EncodedValue.fromRef(same_text_value), context) or
        !JSC__JSValue__isStrictEqual(encoded_object, encoded_object, context) or
        JSC__JSValue__isStrictEqual(encoded_object, EncodedValue.fromRef(other_object), context))
        fail("cell equality mismatch");

    const signed_negative_copy = JSC__JSValue__fromInt64NoTruncate(context, -1);
    if (!JSC__JSValue__isStrictEqual(signed_negative, signed_negative_copy, context) or
        JSC__JSValue__isStrictEqual(signed_negative, unsigned_max, context) or
        !JSC__JSValue__isSameValue(signed_negative, signed_negative_copy, context))
        fail("BigInt value equality mismatch");

    const foreign_context = JSGlobalContextCreate(null) orelse fail("foreign context creation failed");
    defer JSGlobalContextRelease(foreign_context);
    const foreign_object = JSObjectMake(foreign_context, null, null) orelse fail("foreign object creation failed");
    if (JSC__JSValue__isStrictEqual(EncodedValue.fromRef(foreign_object), EncodedValue.fromRef(foreign_object), context) or
        JSC__JSValue__isSameValue(EncodedValue.fromRef(foreign_object), EncodedValue.fromRef(foreign_object), context))
        fail("foreign context cell accepted");

    const signed_min_cell = JSC__JSBigInt__fromJS(signed_min) orelse fail("signed BigInt downcast failed");
    const signed_negative_cell = JSC__JSBigInt__fromJS(signed_negative) orelse fail("negative BigInt downcast failed");
    const unsigned_max_cell = JSC__JSBigInt__fromJS(unsigned_max) orelse fail("unsigned BigInt downcast failed");
    if (JSC__JSBigInt__fromJS(.true) != null or
        JSC__JSBigInt__fromJS(encoded_text) != null or
        JSC__JSBigInt__fromJS(.empty) != null)
        fail("non-BigInt downcast accepted");
    if (JSC__JSBigInt__orderInt64(signed_min_cell, std.math.minInt(i64)) != 0 or
        JSC__JSBigInt__orderInt64(signed_negative_cell, 0) != -1 or
        JSC__JSBigInt__orderUint64(unsigned_max_cell, std.math.maxInt(u64)) != 0 or
        JSC__JSBigInt__orderUint64(signed_negative_cell, 0) != -1)
        fail("64-bit BigInt ordering mismatch");

    const huge_positive = JSC__JSBigInt__fromJS(evaluate(context, "184467440737095516160000000000000000000n")) orelse fail("huge positive downcast failed");
    const huge_negative = JSC__JSBigInt__fromJS(evaluate(context, "-184467440737095516160000000000000000000n")) orelse fail("huge negative downcast failed");
    if (JSC__JSBigInt__orderUint64(huge_positive, std.math.maxInt(u64)) != 1 or
        JSC__JSBigInt__orderInt64(huge_negative, std.math.minInt(i64)) != -1)
        fail("arbitrary-size integer ordering mismatch");

    const above_safe = JSC__JSBigInt__fromJS(evaluate(context, "9007199254740993n")) orelse fail("above-safe BigInt downcast failed");
    const exact_safe = JSC__JSBigInt__fromJS(evaluate(context, "9007199254740992n")) orelse fail("safe BigInt downcast failed");
    const zero_cell = JSC__JSBigInt__fromJS(JSC__JSValue__fromUInt64NoTruncate(context, 0)) orelse fail("zero BigInt downcast failed");
    const two_cell = JSC__JSBigInt__fromJS(JSC__JSValue__fromUInt64NoTruncate(context, 2)) orelse fail("two BigInt downcast failed");
    const negative_two = JSC__JSBigInt__fromJS(JSC__JSValue__fromInt64NoTruncate(context, -2)) orelse fail("negative two downcast failed");
    const min_subnormal: f64 = @bitCast(@as(u64, 1));
    if (JSC__JSBigInt__orderDouble(above_safe, 9007199254740992.0) != 1 or
        JSC__JSBigInt__orderDouble(exact_safe, 9007199254740992.0) != 0 or
        JSC__JSBigInt__orderDouble(signed_negative_cell, -1.5) != 1 or
        JSC__JSBigInt__orderDouble(negative_two, -1.5) != -1 or
        JSC__JSBigInt__orderDouble(two_cell, 1.5) != 1 or
        JSC__JSBigInt__orderDouble(zero_cell, min_subnormal) != -1 or
        JSC__JSBigInt__orderDouble(huge_positive, std.math.inf(f64)) != -1 or
        JSC__JSBigInt__orderDouble(huge_negative, -std.math.inf(f64)) != 1)
        fail("exact double ordering mismatch");

    const beyond_double = JSC__JSBigInt__fromJS(evaluate(context, "10n ** 400n")) orelse fail("extreme BigInt downcast failed");
    if (JSC__JSBigInt__orderDouble(beyond_double, std.math.floatMax(f64)) != 1)
        fail("extreme double ordering mismatch");

    const modulo_one = JSC__JSBigInt__fromJS(evaluate(context, "18446744073709551617n")) orelse fail("modulo BigInt downcast failed");
    if (JSC__JSBigInt__toInt64(signed_min_cell) != std.math.minInt(i64) or
        JSC__JSBigInt__toInt64(signed_negative_cell) != -1 or
        JSC__JSBigInt__toInt64(unsigned_max_cell) != -1 or
        JSC__JSBigInt__toInt64(modulo_one) != 1)
        fail("signed modulo extraction mismatch");

    const text_cell = JSC__JSValue__asString(encoded_text) orelse fail("string downcast failed");
    const same_text_cell = JSC__JSValue__asString(EncodedValue.fromRef(same_text_value)) orelse fail("same string downcast failed");
    if (JSC__JSValue__asString(.true) != null or
        JSC__JSValue__asString(encoded_object) != null or
        !JSC__JSString__eql(text_cell, context, same_text_cell) or
        !JSC__JSString__is8Bit(text_cell) or
        JSC__JSString__length(text_cell) != 5)
        fail("basic JSString bridge mismatch");

    const latin1_cell = JSC__JSValue__asString(evaluate(context, "'é'")) orelse fail("Latin-1 downcast failed");
    const bmp_cell = JSC__JSValue__asString(evaluate(context, "'€'")) orelse fail("BMP downcast failed");
    const astral_cell = JSC__JSValue__asString(evaluate(context, "'😀'")) orelse fail("astral downcast failed");
    const surrogate_cell = JSC__JSValue__asString(evaluate(context, "'\\uD800'")) orelse fail("surrogate downcast failed");
    if (!JSC__JSString__is8Bit(latin1_cell) or JSC__JSString__length(latin1_cell) != 1 or
        JSC__JSString__is8Bit(bmp_cell) or JSC__JSString__length(bmp_cell) != 1 or
        JSC__JSString__is8Bit(astral_cell) or JSC__JSString__length(astral_cell) != 2 or
        JSC__JSString__is8Bit(surrogate_cell) or JSC__JSString__length(surrogate_cell) != 1)
        fail("UTF-16/8-bit JSString boundary mismatch");

    const symbol_cell = evaluate(context, "Symbol('cell')");
    const symbol_pointer = EncodedValue.cellPointer(symbol_cell);
    if (JSC__JSCell__getObject(object) != object or
        JSC__JSCell__getObject(text_cell) != null or
        JSC__JSCell__getObject(signed_negative_cell) != null or
        JSC__JSCell__getObject(symbol_pointer) != null)
        fail("JSCell object access mismatch");
    const boxed_string = JSC__JSString__toObject(text_cell, context) orelse fail("string boxing failed");
    const boxed_bigint = JSC__JSCell__toObject(signed_negative_cell, context) orelse fail("BigInt boxing failed");
    const boxed_symbol = JSC__JSCell__toObject(symbol_pointer, context) orelse fail("Symbol boxing failed");
    if (boxed_string == text_cell or boxed_bigint == signed_negative_cell or boxed_symbol == symbol_pointer or
        JSC__JSCell__getObject(boxed_string) != boxed_string or
        JSC__JSCell__getObject(boxed_bigint) != boxed_bigint or
        JSC__JSCell__getObject(boxed_symbol) != boxed_symbol or
        JSC__JSCell__toObject(object, context) != object or
        JSC__JSString__toObject(text_cell, foreign_context) != null)
        fail("JSCell object coercion mismatch");

    const empty_object = JSC__JSValue__createEmptyObject(context, 0);
    const reserved_object = JSC__JSValue__createEmptyObject(context, 4096);
    const null_proto_object = JSC__JSValue__createEmptyObjectWithNullPrototype(context);
    const object_prototype = evaluate(context, "Object.prototype");
    const empty_prototype = JSObjectGetPrototype(context, EncodedValue.cellPointer(empty_object)) orelse fail("empty object prototype lookup failed");
    const reserved_prototype = JSObjectGetPrototype(context, EncodedValue.cellPointer(reserved_object)) orelse fail("reserved object prototype lookup failed");
    const null_prototype = JSObjectGetPrototype(context, EncodedValue.cellPointer(null_proto_object)) orelse fail("null prototype lookup failed");
    if (!JSC__JSValue__isStrictEqual(EncodedValue.fromRef(empty_prototype), object_prototype, context) or
        !JSC__JSValue__isStrictEqual(EncodedValue.fromRef(reserved_prototype), object_prototype, context) or
        !JSC__JSValue__isStrictEqual(EncodedValue.fromRef(null_prototype), .null, context) or
        JSC__JSValue__isStrictEqual(empty_object, reserved_object, context))
        fail("ordinary object construction mismatch");

    const number_wrapper = evaluate(context, "new Number(42)");
    const int32_min_wrapper = evaluate(context, "new Number(-2147483648)");
    const int32_max_wrapper = evaluate(context, "new Number(2147483647)");
    const beyond_int32_wrapper = evaluate(context, "new Number(2147483648)");
    const negative_zero_wrapper = evaluate(context, "new Number(-0)");
    const nan_wrapper = evaluate(context, "new Number(NaN)");
    const string_wrapper = evaluate(context, "new String('value')");
    const boolean_wrapper = evaluate(context, "new Boolean(false)");
    const bigint_wrapper = evaluate(context, "Object(123n)");
    const unwrapped_bigint = JSC__JSValue__fromInt64NoTruncate(context, 123);
    if (JSC__JSValue__unwrapBoxedPrimitive(context, number_wrapper) != EncodedValue.fromInt32(42) or
        JSC__JSValue__unwrapBoxedPrimitive(context, int32_min_wrapper) != EncodedValue.fromInt32(std.math.minInt(i32)) or
        JSC__JSValue__unwrapBoxedPrimitive(context, int32_max_wrapper) != EncodedValue.fromInt32(std.math.maxInt(i32)) or
        JSC__JSValue__unwrapBoxedPrimitive(context, beyond_int32_wrapper) != EncodedValue.fromDouble(2147483648.0) or
        !JSC__JSValue__isSameValue(JSC__JSValue__unwrapBoxedPrimitive(context, negative_zero_wrapper), EncodedValue.fromDouble(-0.0), context) or
        !JSC__JSValue__isSameValue(JSC__JSValue__unwrapBoxedPrimitive(context, nan_wrapper), EncodedValue.fromDouble(std.math.nan(f64)), context) or
        !JSC__JSValue__isStrictEqual(JSC__JSValue__unwrapBoxedPrimitive(context, string_wrapper), encoded_text, context) or
        JSC__JSValue__unwrapBoxedPrimitive(context, boolean_wrapper) != .false or
        !JSC__JSValue__isStrictEqual(JSC__JSValue__unwrapBoxedPrimitive(context, bigint_wrapper), unwrapped_bigint, context) or
        JSC__JSValue__unwrapBoxedPrimitive(context, empty_object) != empty_object or
        JSC__JSValue__unwrapBoxedPrimitive(context, .true) != .true)
        fail("boxed primitive unwrapping mismatch");
    const foreign_wrapper = evaluate(foreign_context, "new Number(1)");
    if (JSC__JSValue__unwrapBoxedPrimitive(context, foreign_wrapper) != .empty)
        fail("foreign boxed primitive accepted");

    std.debug.print("Home private value shims: 24/24 symbols linked; runtime matrix passed\n", .{});
}
