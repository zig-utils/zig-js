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
extern "c" fn JSGlobalContextCreateInGroup(?*anyopaque, ?*anyopaque) JSContextRef;
extern "c" fn JSGlobalContextRelease(JSContextRef) void;
extern "c" fn JSContextGetGroup(JSContextRef) ?*anyopaque;
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
extern "c" fn JSC__JSValue__asBigIntCompare(EncodedValue, JSContextRef, EncodedValue) u8;
extern "c" fn JSC__JSValue__bigIntSum(JSContextRef, EncodedValue, EncodedValue) EncodedValue;
extern "c" fn JSC__JSValue__fromTimevalNoTruncate(JSContextRef, i64, i64) EncodedValue;
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
extern "c" fn JSC__JSValue__toObject(EncodedValue, JSContextRef) JSObjectRef;
extern "c" fn JSC__JSValue__getPrototype(EncodedValue, JSContextRef) EncodedValue;
extern "c" fn JSC__JSValue__dateInstanceFromNumber(JSContextRef, f64) EncodedValue;
extern "c" fn JSC__JSValue__getUnixTimestamp(EncodedValue) f64;
extern "c" fn JSC__JSGlobalObject__vm(JSContextRef) ?*anyopaque;
extern "c" fn JSC__VM__throwError(?*anyopaque, JSContextRef, EncodedValue) void;
extern "c" fn JSGlobalObject__hasException(JSContextRef) bool;
extern "c" fn JSGlobalObject__clearException(JSContextRef) void;
extern "c" fn JSGlobalObject__tryTakeException(JSContextRef) EncodedValue;
extern "c" fn JSC__Exception__asJSValue(?*anyopaque) EncodedValue;
extern "c" fn JSC__JSValue__isException(EncodedValue, ?*anyopaque) bool;
extern "c" fn JSC__JSValue__toError_(EncodedValue) EncodedValue;
extern "c" fn JSC__JSValue__isAnyError(EncodedValue) bool;

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

    if (JSC__JSValue__asBigIntCompare(signed_negative, context, EncodedValue.fromInt32(-1)) != 0 or
        JSC__JSValue__asBigIntCompare(signed_negative, context, EncodedValue.fromDouble(std.math.nan(f64))) != 1 or
        JSC__JSValue__asBigIntCompare(evaluate(context, "9007199254740993n"), context, EncodedValue.fromDouble(9007199254740992.0)) != 2 or
        JSC__JSValue__asBigIntCompare(evaluate(context, "-2n"), context, EncodedValue.fromDouble(-1.5)) != 3 or
        JSC__JSValue__asBigIntCompare(evaluate(context, "0n"), context, EncodedValue.fromDouble(-0.0)) != 0 or
        JSC__JSValue__asBigIntCompare(evaluate(context, "0n"), context, EncodedValue.fromDouble(std.math.inf(f64))) != 3 or
        JSC__JSValue__asBigIntCompare(evaluate(context, "0n"), context, EncodedValue.fromDouble(-std.math.inf(f64))) != 2 or
        JSC__JSValue__asBigIntCompare(evaluate(context, "10n ** 400n"), context, evaluate(context, "10n ** 399n")) != 2 or
        JSC__JSValue__asBigIntCompare(.true, context, .true) != 4)
        fail("private BigInt comparison mismatch");

    const overflow_sum = JSC__JSValue__bigIntSum(
        context,
        evaluate(context, "184467440737095516160000000000000000000n"),
        evaluate(context, "-184467440737095516159999999999999999999n"),
    );
    const timeval_max = JSC__JSValue__fromTimevalNoTruncate(context, std.math.maxInt(i64), std.math.maxInt(i64));
    const timeval_min = JSC__JSValue__fromTimevalNoTruncate(context, std.math.minInt(i64), std.math.minInt(i64));
    const foreign_bigint = evaluate(foreign_context, "1n");
    if (!JSC__JSValue__isStrictEqual(overflow_sum, evaluate(context, "1n"), context) or
        !JSC__JSValue__isStrictEqual(timeval_max, evaluate(context, "9223372036854775807n * 1000000n + 9223372036854775807n"), context) or
        !JSC__JSValue__isStrictEqual(timeval_min, evaluate(context, "-9223372036854775808n * 1000000n - 9223372036854775808n"), context) or
        JSC__JSValue__bigIntSum(context, .true, signed_negative) != .empty or
        JSC__JSValue__bigIntSum(context, signed_negative, foreign_bigint) != .empty or
        JSC__JSValue__asBigIntCompare(signed_negative, context, foreign_bigint) != 4)
        fail("private BigInt arithmetic mismatch");

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

    const number_object = JSC__JSValue__toObject(EncodedValue.fromInt32(42), context) orelse fail("number ToObject failed");
    const boolean_object = JSC__JSValue__toObject(.true, context) orelse fail("boolean ToObject failed");
    const string_object = JSC__JSValue__toObject(encoded_text, context) orelse fail("string ToObject failed");
    const symbol_object = JSC__JSValue__toObject(symbol_cell, context) orelse fail("Symbol ToObject failed");
    const bigint_object = JSC__JSValue__toObject(signed_negative, context) orelse fail("BigInt ToObject failed");
    if (JSC__JSValue__toObject(encoded_object, context) != object or
        number_object == object or boolean_object == object or string_object == text_cell or
        symbol_object == symbol_pointer or bigint_object == signed_negative_cell or
        JSC__JSValue__toObject(.null, context) != null or
        JSC__JSValue__toObject(.undefined, context) != null or
        JSC__JSValue__toObject(encoded_object, foreign_context) != null)
        fail("private ToObject mismatch");

    if (!JSC__JSValue__isStrictEqual(JSC__JSValue__getPrototype(encoded_object, context), object_prototype, context))
        fail("ordinary object prototype mismatch");
    if (!JSC__JSValue__isStrictEqual(JSC__JSValue__getPrototype(EncodedValue.fromInt32(42), context), evaluate(context, "Number.prototype"), context))
        fail("Number primitive prototype mismatch");
    if (!JSC__JSValue__isStrictEqual(JSC__JSValue__getPrototype(.true, context), evaluate(context, "Boolean.prototype"), context))
        fail("Boolean primitive prototype mismatch");
    if (!JSC__JSValue__isStrictEqual(JSC__JSValue__getPrototype(encoded_text, context), evaluate(context, "String.prototype"), context))
        fail("String primitive prototype mismatch");
    if (!JSC__JSValue__isStrictEqual(JSC__JSValue__getPrototype(symbol_cell, context), evaluate(context, "Symbol.prototype"), context))
        fail("Symbol primitive prototype mismatch");
    if (!JSC__JSValue__isStrictEqual(JSC__JSValue__getPrototype(signed_negative, context), evaluate(context, "BigInt.prototype"), context))
        fail("BigInt primitive prototype mismatch");
    if (JSC__JSValue__getPrototype(null_proto_object, context) != .null or
        JSC__JSValue__getPrototype(.null, context) != .empty)
        fail("null prototype mismatch");

    const proxy = evaluate(context, "globalThis.__private_proto = {}; new Proxy({}, { getPrototypeOf() { return __private_proto; } })");
    if (!JSC__JSValue__isStrictEqual(JSC__JSValue__getPrototype(proxy, context), evaluate(context, "__private_proto"), context) or
        JSC__JSValue__getPrototype(EncodedValue.fromRef(foreign_object), context) != .empty)
        fail("private object prototype mismatch");

    const epoch_date = JSC__JSValue__dateInstanceFromNumber(context, 0.0);
    const epoch_date_copy = JSC__JSValue__dateInstanceFromNumber(context, 0.0);
    const fractional_date = JSC__JSValue__dateInstanceFromNumber(context, 1.25);
    const negative_zero_date = JSC__JSValue__dateInstanceFromNumber(context, -0.0);
    const nan_date = JSC__JSValue__dateInstanceFromNumber(context, std.math.nan(f64));
    const positive_infinity_date = JSC__JSValue__dateInstanceFromNumber(context, std.math.inf(f64));
    const beyond_time_clip_date = JSC__JSValue__dateInstanceFromNumber(context, 8.64e15 + 1.0);
    const foreign_date = JSC__JSValue__dateInstanceFromNumber(foreign_context, -123.5);
    if (!JSC__JSValue__isStrictEqual(JSC__JSValue__getPrototype(epoch_date, context), evaluate(context, "Date.prototype"), context) or
        JSC__JSValue__isStrictEqual(epoch_date, epoch_date_copy, context) or
        JSC__JSValue__getUnixTimestamp(epoch_date) != 0.0 or
        JSC__JSValue__getUnixTimestamp(fractional_date) != 1.25 or
        !std.math.signbit(JSC__JSValue__getUnixTimestamp(negative_zero_date)) or
        !std.math.isNan(JSC__JSValue__getUnixTimestamp(nan_date)) or
        JSC__JSValue__getUnixTimestamp(positive_infinity_date) != std.math.inf(f64) or
        JSC__JSValue__getUnixTimestamp(beyond_time_clip_date) != 8.64e15 + 1.0 or
        JSC__JSValue__getUnixTimestamp(foreign_date) != -123.5 or
        !std.math.isNan(JSC__JSValue__getUnixTimestamp(encoded_object)) or
        !std.math.isNan(JSC__JSValue__getUnixTimestamp(.empty)))
        fail("private numeric DateInstance mismatch");

    const sibling_context = JSGlobalContextCreateInGroup(JSContextGetGroup(context), null) orelse fail("sibling context creation failed");
    defer JSGlobalContextRelease(sibling_context);
    const vm = JSC__JSGlobalObject__vm(context) orelse fail("private VM lookup failed");
    const sibling_vm = JSC__JSGlobalObject__vm(sibling_context) orelse fail("sibling VM lookup failed");
    const foreign_vm = JSC__JSGlobalObject__vm(foreign_context) orelse fail("foreign VM lookup failed");
    if (vm != sibling_vm or vm == foreign_vm or JSGlobalObject__hasException(context) or
        JSGlobalObject__tryTakeException(context) != .empty)
        fail("private VM identity mismatch");

    JSC__VM__throwError(vm, context, EncodedValue.fromInt32(42));
    if (!JSGlobalObject__hasException(context) or !JSGlobalObject__hasException(sibling_context))
        fail("pending exception is not VM-shared");
    const primitive_exception = JSGlobalObject__tryTakeException(sibling_context);
    const primitive_exception_cell = EncodedValue.cellPointer(primitive_exception);
    if (primitive_exception == .empty or primitive_exception_cell == null or
        JSGlobalObject__hasException(context) or
        !JSC__JSValue__isException(primitive_exception, vm) or
        !JSC__JSValue__isAnyError(primitive_exception) or
        JSC__Exception__asJSValue(primitive_exception_cell) != EncodedValue.fromInt32(42) or
        JSC__JSValue__toError_(primitive_exception) != EncodedValue.fromInt32(42) or
        !JSC__JSValue__isStrictEqual(primitive_exception, primitive_exception, context) or
        JSC__JSValue__isStrictEqual(primitive_exception, EncodedValue.fromInt32(42), context))
        fail("primitive exception-cell mismatch");

    const error_value = evaluate(context, "new TypeError('private pending')");
    if (!JSC__JSValue__isAnyError(error_value) or JSC__JSValue__toError_(error_value) != error_value or
        JSC__JSValue__isException(error_value, vm))
        fail("ErrorInstance classification mismatch");
    JSC__VM__throwError(vm, context, error_value);
    const error_exception = JSGlobalObject__tryTakeException(context);
    if (JSC__Exception__asJSValue(EncodedValue.cellPointer(error_exception)) != error_value or
        JSC__JSValue__toError_(error_exception) != error_value)
        fail("ErrorInstance exception unwrapping mismatch");

    JSC__VM__throwError(vm, context, EncodedValue.fromInt32(1));
    JSC__VM__throwError(vm, context, EncodedValue.fromInt32(2));
    const first_exception = JSGlobalObject__tryTakeException(context);
    if (JSC__Exception__asJSValue(EncodedValue.cellPointer(first_exception)) != EncodedValue.fromInt32(1))
        fail("pending exception replacement mismatch");
    JSC__VM__throwError(vm, context, .true);
    JSGlobalObject__clearException(sibling_context);
    JSC__VM__throwError(foreign_vm, context, .false);
    JSC__VM__throwError(vm, context, .empty);
    if (JSGlobalObject__hasException(context) or JSC__JSGlobalObject__vm(null) != null or
        JSC__Exception__asJSValue(object) != .empty or
        JSC__JSValue__toError_(encoded_object) != .empty or
        JSC__JSValue__isAnyError(encoded_object))
        fail("pending exception invalid-input mismatch");

    std.debug.print("Home private value shims: 40/40 symbols linked; runtime matrix passed\n", .{});
}
