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

const PrivateTypedArrayType = enum(u8) {
    none = 0,
    i8 = 1,
    u8 = 2,
    u8c = 3,
    i16 = 4,
    u16 = 5,
    i32 = 6,
    u32 = 7,
    f16 = 8,
    f32 = 9,
    f64 = 10,
    i64 = 11,
    u64 = 12,
    data_view = 13,
    _,
};

const BunStringTag = enum(u8) {
    dead = 0,
    wtf_string_impl = 1,
    zig_string = 2,
    static_zig_string = 3,
    empty = 4,
};

const WTFStringImpl = extern struct {
    ref_count: u32,
    length: u32,
    bytes: [*]const u8,
    hash_and_flags: u32,
};

const ZigString = extern struct { tagged_ptr: usize, len: usize };

const BunStringImpl = extern union {
    zig_string: ZigString,
    wtf_string_impl: ?*WTFStringImpl,
};

const BunString = extern struct {
    tag: BunStringTag,
    value: BunStringImpl,
};

const StringBuilder = extern struct {
    bytes: [24]u8 align(8),
};

const PrivateBunArrayBuffer = extern struct {
    ptr: ?[*]u8 = null,
    len: usize = 0,
    byte_len: usize = 0,
    encoded_value: EncodedValue = .empty,
    cell_type: u8 = 0,
    shared: bool = false,
    resizable: bool = false,
};

comptime {
    if (@sizeOf(BunString) != 24 or @alignOf(BunString) != 8 or
        @offsetOf(BunString, "value") != 8)
        @compileError("BunString fixture layout drifted");
    if (@offsetOf(WTFStringImpl, "bytes") != 8 or
        @offsetOf(WTFStringImpl, "hash_and_flags") != 16)
        @compileError("WTFStringImpl fixture prefix drifted");
    if (@sizeOf(StringBuilder) != 24 or @alignOf(StringBuilder) != 8)
        @compileError("StringBuilder fixture layout drifted");
    if (@sizeOf(PrivateBunArrayBuffer) != 40 or @offsetOf(PrivateBunArrayBuffer, "cell_type") != 32)
        @compileError("Bun ArrayBuffer fixture layout drifted");
}

extern "c" fn JSGlobalContextCreate(?*anyopaque) JSContextRef;
extern "c" fn JSGlobalContextCreateInGroup(?*anyopaque, ?*anyopaque) JSContextRef;
extern "c" fn JSGlobalContextRelease(JSContextRef) void;
extern "c" fn JSContextGetGroup(JSContextRef) ?*anyopaque;
extern "c" fn JSContextGetGlobalObject(JSContextRef) JSObjectRef;
extern "c" fn JSValueMakeString(JSContextRef, JSStringRef) JSValueRef;
extern "c" fn JSValueToNumber(JSContextRef, JSValueRef, [*c]JSValueRef) f64;
extern "c" fn JSStringCreateWithUTF8CString([*:0]const u8) JSStringRef;
extern "c" fn JSStringRelease(JSStringRef) void;
extern "c" fn JSObjectMake(JSContextRef, ?*anyopaque, ?*anyopaque) JSObjectRef;
extern "c" fn JSObjectGetPrototype(JSContextRef, JSObjectRef) JSValueRef;
extern "c" fn JSObjectSetPrototype(JSContextRef, JSObjectRef, JSValueRef) void;
extern "c" fn JSObjectGetProperty(JSContextRef, JSObjectRef, JSStringRef, [*c]JSValueRef) JSValueRef;
extern "c" fn JSObjectSetProperty(JSContextRef, JSObjectRef, JSStringRef, JSValueRef, c_uint, [*c]JSValueRef) void;
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
extern "c" fn JSVALUE_TO_INT64_SLOW(EncodedValue) i64;
extern "c" fn JSVALUE_TO_UINT64_SLOW(EncodedValue) u64;
extern "c" fn JSC__JSValue__isStrictEqual(EncodedValue, EncodedValue, JSContextRef) bool;
extern "c" fn JSC__JSValue__isSameValue(EncodedValue, EncodedValue, JSContextRef) bool;
extern "c" fn JSC__JSBigInt__fromJS(EncodedValue) ?*anyopaque;
extern "c" fn JSC__JSBigInt__orderDouble(?*anyopaque, f64) i8;
extern "c" fn JSC__JSBigInt__orderInt64(?*anyopaque, i64) i8;
extern "c" fn JSC__JSBigInt__orderUint64(?*anyopaque, u64) i8;
extern "c" fn JSC__JSBigInt__toInt64(?*anyopaque) i64;
extern "c" fn JSC__JSBigInt__toString(?*anyopaque, JSContextRef) BunString;
extern "c" fn Bun__WTFStringImpl__ref(?*WTFStringImpl) void;
extern "c" fn Bun__WTFStringImpl__deref(?*WTFStringImpl) void;
extern "c" fn BunString__toJS(JSContextRef, *const BunString) EncodedValue;
extern "c" fn BunString__toJSWithLength(JSContextRef, *const BunString, usize) EncodedValue;
extern "c" fn BunString__transferToJS(*BunString, JSContextRef) EncodedValue;
extern "c" fn BunString__createArray(JSContextRef, [*c]const BunString, usize) EncodedValue;
extern "c" fn StringBuilder__init(*anyopaque) void;
extern "c" fn StringBuilder__deinit(*anyopaque) void;
extern "c" fn StringBuilder__ensureUnusedCapacity(*anyopaque, usize) void;
extern "c" fn StringBuilder__appendLatin1(*anyopaque, [*]const u8, usize) void;
extern "c" fn StringBuilder__appendUtf16(*anyopaque, [*]const u16, usize) void;
extern "c" fn StringBuilder__appendString(*anyopaque, BunString) void;
extern "c" fn StringBuilder__appendLChar(*anyopaque, u8) void;
extern "c" fn StringBuilder__appendUChar(*anyopaque, u16) void;
extern "c" fn StringBuilder__appendInt(*anyopaque, i32) void;
extern "c" fn StringBuilder__appendUsize(*anyopaque, usize) void;
extern "c" fn StringBuilder__appendDouble(*anyopaque, f64) void;
extern "c" fn StringBuilder__appendQuotedJsonString(*anyopaque, BunString) void;
extern "c" fn StringBuilder__toString(*anyopaque, JSContextRef) EncodedValue;
extern "c" fn Yarr__RegularExpression__init(BunString, u16) ?*anyopaque;
extern "c" fn Yarr__RegularExpression__deinit(?*anyopaque) void;
extern "c" fn Yarr__RegularExpression__isValid(?*anyopaque) bool;
extern "c" fn Yarr__RegularExpression__matchedLength(?*anyopaque) i32;
// This is the real C++/Rust executable ABI. The pinned Zig declaration's
// missing BunString parameter is tracked as source drift in issue #213.
extern "c" fn Yarr__RegularExpression__searchRev(?*anyopaque, BunString) i32;
extern "c" fn Yarr__RegularExpression__matches(?*anyopaque, BunString) i32;
extern "c" fn WTF__parseDouble([*]const u8, usize, *usize) f64;
extern "c" fn WTF__parseES5Date([*]const u8, usize) f64;
extern "c" fn WTF__numberOfProcessorCores() c_int;
extern "c" fn WTF__releaseFastMallocFreeMemoryForThisThread() void;
extern "c" fn Bun__writeHTTPDate(*[32]u8, usize, u64) c_int;
extern "c" fn Bun__createUint8ArrayForCopy(JSContextRef, ?*const anyopaque, usize, bool) EncodedValue;
extern "c" fn JSUint8Array__fromDefaultAllocator(JSContextRef, [*]u8, usize) EncodedValue;
extern "c" fn JSBuffer__isBuffer(JSContextRef, EncodedValue) bool;
extern "c" fn JSBuffer__bufferFromLength(JSContextRef, i64) EncodedValue;
extern "c" fn JSBuffer__bufferFromPointerAndLengthAndDeinit(JSContextRef, [*]u8, usize, ?*anyopaque, ?*const fn (?*anyopaque, ?*anyopaque) callconv(.c) void) EncodedValue;
extern "c" fn JSBuffer__fromMmap(JSContextRef, *anyopaque, usize) EncodedValue;
extern "c" fn JSC__JSValue__createUninitializedUint8Array(JSContextRef, usize) EncodedValue;
extern "c" fn Bun__makeArrayBufferWithBytesNoCopy(JSContextRef, ?*anyopaque, usize, ?*const fn (?*anyopaque, ?*anyopaque) callconv(.c) void, ?*anyopaque) EncodedValue;
extern "c" fn Bun__makeTypedArrayWithBytesNoCopy(JSContextRef, PrivateTypedArrayType, ?*anyopaque, usize, ?*const fn (?*anyopaque, ?*anyopaque) callconv(.c) void, ?*anyopaque) EncodedValue;
extern "c" fn JSC__JSValue__asArrayBuffer(EncodedValue, JSContextRef, *PrivateBunArrayBuffer) bool;
extern "c" fn JSObjectGetTypedArrayBytesPtr(JSContextRef, JSObjectRef, [*c]JSValueRef) ?*anyopaque;
extern "c" fn JSObjectGetTypedArrayLength(JSContextRef, JSObjectRef, [*c]JSValueRef) usize;
extern "c" fn JSObjectGetTypedArrayBuffer(JSContextRef, JSObjectRef, [*c]JSValueRef) JSObjectRef;
extern "c" fn JSObjectGetArrayBufferBytesPtr(JSContextRef, JSObjectRef, [*c]JSValueRef) ?*anyopaque;
extern "c" fn JSObjectGetArrayBufferByteLength(JSContextRef, JSObjectRef, [*c]JSValueRef) usize;
extern "c" fn ZigString__toErrorInstance(*const ZigString, JSContextRef) EncodedValue;
extern "c" fn ZigString__toTypeErrorInstance(*const ZigString, JSContextRef) EncodedValue;
extern "c" fn ZigString__toRangeErrorInstance(*const ZigString, JSContextRef) EncodedValue;
extern "c" fn ZigString__toSyntaxErrorInstance(*const ZigString, JSContextRef) EncodedValue;
extern "c" fn ZigString__toDOMExceptionInstance(*const ZigString, JSContextRef, u8) EncodedValue;
extern "c" fn ZigString__toValueGC(*const ZigString, JSContextRef) EncodedValue;
extern "c" fn ZigString__to16BitValue(*const ZigString, JSContextRef) EncodedValue;
extern "c" fn ZigString__toAtomicValue(*const ZigString, JSContextRef) EncodedValue;
extern "c" fn JSC__JSValue__createRopeString(EncodedValue, EncodedValue, JSContextRef) EncodedValue;
extern "c" fn JSC__JSString__toZigString(?*anyopaque, JSContextRef, *ZigString) void;
extern "c" fn JSC__JSValue__toZigString(EncodedValue, *ZigString, JSContextRef) void;
extern "c" fn JSC__JSValue__createTypeError(*const ZigString, *const ZigString, JSContextRef) EncodedValue;
extern "c" fn JSC__JSValue__createRangeError(*const ZigString, *const ZigString, JSContextRef) EncodedValue;
extern "c" fn JSC__createError(JSContextRef, *const BunString) EncodedValue;
extern "c" fn JSC__createTypeError(JSContextRef, *const BunString) EncodedValue;
extern "c" fn JSC__createRangeError(JSContextRef, *const BunString) EncodedValue;
extern "c" fn JSC__JSGlobalObject__createAggregateError(JSContextRef, [*c]const EncodedValue, usize, *const ZigString) EncodedValue;
extern "c" fn JSC__JSGlobalObject__createAggregateErrorWithArray(JSContextRef, EncodedValue, BunString, EncodedValue) EncodedValue;
extern "c" fn JSC__JSValue__getErrorsProperty(EncodedValue, JSContextRef) EncodedValue;
extern "c" fn JSC__JSValue__createObject2(JSContextRef, *const ZigString, *const ZigString, EncodedValue, EncodedValue) EncodedValue;
extern "c" fn JSC__JSValue__putRecord(EncodedValue, JSContextRef, ?*const ZigString, [*c]const ZigString, usize) void;
extern "c" fn JSC__JSValue__fromEntries(JSContextRef, [*c]const ZigString, [*c]const ZigString, usize, bool) EncodedValue;
extern "c" fn JSC__JSValue__put(EncodedValue, JSContextRef, *const ZigString, EncodedValue) void;
extern "c" fn JSC__JSValue__putToPropertyKey(EncodedValue, JSContextRef, EncodedValue, EncodedValue) void;
extern "c" fn JSC__JSValue__deleteProperty(EncodedValue, JSContextRef, *const ZigString) bool;
extern "c" fn JSC__JSValue__getIfPropertyExistsImpl(EncodedValue, JSContextRef, [*]const u8, u32) EncodedValue;
extern "c" fn JSC__JSValue__getPropertyValue(EncodedValue, JSContextRef, [*]const u8, u32) EncodedValue;
extern "c" fn JSC__JSValue__getOwn(EncodedValue, JSContextRef, *const BunString) EncodedValue;
extern "c" fn JSC__JSValue__getOwnByValue(EncodedValue, JSContextRef, EncodedValue) EncodedValue;
extern "c" fn JSC__JSValue__fastGetDirect_(EncodedValue, JSContextRef, u8) EncodedValue;
extern "c" fn JSC__JSValue__fastGet(EncodedValue, JSContextRef, u8) EncodedValue;
extern "c" fn JSC__JSValue__fastGetOwn(EncodedValue, JSContextRef, u8) EncodedValue;
extern "c" fn Bun__JSObject__getCodePropertyVMInquiry(JSContextRef, ?*anyopaque) EncodedValue;
extern "c" fn JSC__JSValue__symbolFor(JSContextRef, *const ZigString) EncodedValue;
extern "c" fn JSC__JSValue__symbolKeyFor(EncodedValue, JSContextRef, *ZigString) bool;
extern "c" fn JSC__JSValue__getSymbolDescription(EncodedValue, JSContextRef, *ZigString) void;
extern "c" fn JSC__JSValue__asString(EncodedValue) ?*anyopaque;
extern "c" fn JSC__JSFunction__getSourceCode(EncodedValue, *ZigString) bool;
extern "c" fn JSC__JSFunction__optimizeSoon(EncodedValue) void;
extern "c" fn JSC__JSValue__getLengthIfPropertyExistsInternal(EncodedValue, JSContextRef) f64;
extern "c" fn JSC__JSValue__getIfPropertyExistsFromPath(EncodedValue, JSContextRef, EncodedValue) EncodedValue;
extern "c" fn JSC__JSValue__getClassInfoName(EncodedValue, *[*:0]const u8, *usize) bool;
extern "c" fn JSC__JSValue__getClassName(EncodedValue, JSContextRef, *ZigString) void;
extern "c" fn JSC__JSValue__getNameProperty(EncodedValue, JSContextRef, *ZigString) void;
extern "c" fn JSC__JSValue__getName(EncodedValue, JSContextRef, *BunString) void;
extern "c" fn JSC__JSValue__jsonStringify(EncodedValue, JSContextRef, u32, *BunString) void;
extern "c" fn JSC__JSValue__jsonStringifyFast(EncodedValue, JSContextRef, *BunString) void;
extern "c" fn JSC__JSValue__isJSXElement(EncodedValue, JSContextRef) bool;
extern "c" fn Bun__ProxyObject__getInternalField(EncodedValue, u32) EncodedValue;
extern "c" fn JSC__JSValue__deepEquals(EncodedValue, EncodedValue, JSContextRef) bool;
extern "c" fn JSC__JSValue__strictDeepEquals(EncodedValue, EncodedValue, JSContextRef) bool;
extern "c" fn JSC__JSValue__jestDeepEquals(EncodedValue, EncodedValue, JSContextRef) bool;
extern "c" fn JSC__JSValue__jestStrictDeepEquals(EncodedValue, EncodedValue, JSContextRef) bool;
extern "c" fn JSC__JSValue__jestDeepMatch(EncodedValue, EncodedValue, JSContextRef, bool) bool;
extern "c" fn JSRemoteInspectorDisableAutoStart() void;
extern "c" fn JSRemoteInspectorStart() void;
extern "c" fn JSRemoteInspectorSetLogToSystemConsole(bool) void;
extern "c" fn JSRemoteInspectorGetInspectionEnabledByDefault() bool;
extern "c" fn JSRemoteInspectorSetInspectionEnabledByDefault(bool) void;
extern "c" fn ScriptExecutionContextIdentifier__forGlobalObject(JSContextRef) u32;
extern "c" fn Bun__noSideEffectsToString(?*anyopaque, JSContextRef, EncodedValue) EncodedValue;
extern "c" fn Bun__promises__isErrorLike(JSContextRef, EncodedValue) bool;
extern "c" fn JSC__jsTypeStringForValue(JSContextRef, EncodedValue) ?*anyopaque;
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
extern "c" fn JSC__JSValue__dateInstanceFromNullTerminatedString(JSContextRef, [*:0]const u8) EncodedValue;
extern "c" fn JSC__JSValue__getUnixTimestamp(EncodedValue) f64;
extern "c" fn JSC__JSValue__getUTCTimestamp(JSContextRef, EncodedValue) f64;
extern "c" fn JSC__JSValue__toISOString(JSContextRef, EncodedValue, *[28]u8) c_int;
// The pinned Zig declaration is stale; this is Bun's executable wrapper/C++ ABI.
extern "c" fn JSC__JSValue__DateNowISOString(JSContextRef, *[28]u8) c_int;
extern "c" fn JSC__JSGlobalObject__vm(JSContextRef) ?*anyopaque;
extern "c" fn JSC__VM__throwError(?*anyopaque, JSContextRef, EncodedValue) void;
extern "c" fn JSGlobalObject__hasException(JSContextRef) bool;
extern "c" fn JSGlobalObject__clearException(JSContextRef) void;
extern "c" fn JSGlobalObject__clearExceptionExceptTermination(JSContextRef) bool;
extern "c" fn JSGlobalObject__clearTerminationException(JSContextRef) void;
extern "c" fn JSGlobalObject__createOutOfMemoryError(JSContextRef) EncodedValue;
extern "c" fn JSGlobalObject__requestTermination(JSContextRef) void;
extern "c" fn JSGlobalObject__throwOutOfMemoryError(JSContextRef) void;
extern "c" fn JSGlobalObject__throwStackOverflow(JSContextRef) void;
extern "c" fn JSGlobalObject__tryTakeException(JSContextRef) EncodedValue;
extern "c" fn JSC__Exception__asJSValue(?*anyopaque) EncodedValue;
extern "c" fn JSC__JSValue__isException(EncodedValue, ?*anyopaque) bool;
extern "c" fn JSC__JSValue__isTerminationException(EncodedValue) bool;
extern "c" fn JSC__JSValue__toError_(EncodedValue) EncodedValue;
extern "c" fn JSC__JSValue__isAnyError(EncodedValue) bool;
extern "c" fn JSC__VM__clearHasTerminationRequest(?*anyopaque) void;
extern "c" fn JSC__VM__executionForbidden(?*anyopaque) bool;
extern "c" fn JSC__VM__hasTerminationRequest(?*anyopaque) bool;
extern "c" fn JSC__VM__isEntered(?*anyopaque) bool;
extern "c" fn JSC__VM__notifyNeedTermination(?*anyopaque) void;
extern "c" fn JSC__VM__setExecutionForbidden(?*anyopaque, bool) void;
extern "c" fn JSC__VM__blockBytesAllocated(?*anyopaque) usize;
extern "c" fn JSC__VM__collectAsync(?*anyopaque) void;
extern "c" fn JSC__VM__externalMemorySize(?*anyopaque) usize;
extern "c" fn JSC__VM__heapSize(?*anyopaque) usize;
extern "c" fn JSC__VM__performOpportunisticallyScheduledTasks(?*anyopaque, f64) void;
extern "c" fn JSC__VM__releaseWeakRefs(?*anyopaque) void;
extern "c" fn JSC__VM__reportExtraMemory(?*anyopaque, usize) void;
extern "c" fn JSC__VM__runGC(?*anyopaque, bool) usize;
extern "c" fn JSC__VM__shrinkFootprint(?*anyopaque) void;
extern "c" fn JSC__JSGlobalObject__deleteModuleRegistryEntry(JSContextRef, *const ZigString) void;
extern "c" fn JSC__JSGlobalObject__drainMicrotasks(JSContextRef) u8;
extern "c" fn JSC__JSGlobalObject__handleRejectedPromises(JSContextRef) void;
extern "c" fn JSC__JSGlobalObject__queueMicrotaskCallback(JSContextRef, ?*anyopaque, *const fn (?*anyopaque) callconv(.c) void) void;
extern "c" fn JSC__JSGlobalObject__queueMicrotaskJob(JSContextRef, EncodedValue, EncodedValue, EncodedValue) void;
extern "c" fn JSC__VM__deleteAllCode(?*anyopaque, JSContextRef) void;
extern "c" fn JSC__VM__drainMicrotasks(?*anyopaque) void;
extern "c" fn TopExceptionScope__construct(?*anyopaque, JSContextRef, [*:0]const u8, [*:0]const u8, c_uint, usize, usize) void;
extern "c" fn TopExceptionScope__pureException(?*anyopaque) ?*anyopaque;
extern "c" fn TopExceptionScope__exceptionIncludingTraps(?*anyopaque) ?*anyopaque;
extern "c" fn TopExceptionScope__clearException(?*anyopaque) void;
extern "c" fn TopExceptionScope__assertNoException(?*anyopaque) void;
extern "c" fn TopExceptionScope__destruct(?*anyopaque) void;
extern "c" fn JSC__JSValue__createEmptyArray(JSContextRef, usize) EncodedValue;
extern "c" fn JSC__JSValue__putIndex(EncodedValue, JSContextRef, u32, EncodedValue) void;
extern "c" fn JSC__JSValue__push(EncodedValue, JSContextRef, EncodedValue) void;
extern "c" fn JSC__JSValue__getDirectIndex(EncodedValue, JSContextRef, u32) EncodedValue;
extern "c" fn JSC__JSObject__getIndex(EncodedValue, JSContextRef, u32) EncodedValue;
extern "c" fn JSC__JSValue__keys(JSContextRef, EncodedValue) EncodedValue;
extern "c" fn JSC__JSValue__values(JSContextRef, EncodedValue) EncodedValue;
extern "c" fn JSArray__constructArray(JSContextRef, [*]const EncodedValue, usize) EncodedValue;
extern "c" fn JSArray__constructEmptyArray(JSContextRef, usize) EncodedValue;
extern "c" fn Bun__JSValue__toNumber(EncodedValue, JSContextRef) f64;
extern "c" fn JSC__JSValue__isInstanceOf(EncodedValue, JSContextRef, EncodedValue) bool;
extern "c" fn JSC__JSValue__isIterable(EncodedValue, JSContextRef) bool;
extern "c" fn JSC__JSValue__stringIncludes(EncodedValue, JSContextRef, EncodedValue) bool;
extern "c" fn JSC__JSValue__isClass(EncodedValue, JSContextRef) bool;
extern "c" fn JSC__JSValue__isAggregateError(EncodedValue, JSContextRef) bool;
extern "c" fn JSC__AnyPromise__wrap(JSContextRef, EncodedValue, *anyopaque, PromiseWrapCallback) void;
extern "c" fn JSC__JSPromise__create(JSContextRef) ?*anyopaque;
extern "c" fn JSC__JSPromise__rejectedPromise(JSContextRef, EncodedValue) ?*anyopaque;
extern "c" fn JSC__JSPromise__rejectedPromiseValue(JSContextRef, EncodedValue) EncodedValue;
extern "c" fn JSC__JSPromise__resolvedPromise(JSContextRef, EncodedValue) ?*anyopaque;
extern "c" fn JSC__JSPromise__resolvedPromiseValue(JSContextRef, EncodedValue) EncodedValue;
extern "c" fn JSC__JSPromise__wrap(JSContextRef, *anyopaque, PromiseWrapCallback) EncodedValue;
extern "c" fn JSC__JSValue__asInternalPromise(EncodedValue) ?*anyopaque;
extern "c" fn JSC__JSValue__asPromise(EncodedValue) ?*anyopaque;
extern "c" fn JSC__JSValue__createInternalPromise(JSContextRef) EncodedValue;
extern "c" fn JSC__JSMap__create(JSContextRef) ?*anyopaque;
extern "c" fn JSC__JSMap__set(?*anyopaque, JSContextRef, EncodedValue, EncodedValue) void;
extern "c" fn JSC__JSMap__get(?*anyopaque, JSContextRef, EncodedValue) EncodedValue;
extern "c" fn JSC__JSMap__has(?*anyopaque, JSContextRef, EncodedValue) bool;
extern "c" fn JSC__JSMap__remove(?*anyopaque, JSContextRef, EncodedValue) bool;
extern "c" fn JSC__JSMap__clear(?*anyopaque, JSContextRef) void;
extern "c" fn JSC__JSMap__size(?*anyopaque, JSContextRef) usize;
extern "c" fn WebCore__CommonAbortReason__toJS(JSContextRef, u8) EncodedValue;

const PromiseWrapCallback = *const fn (*anyopaque, JSContextRef) callconv(.c) EncodedValue;

const StrongRef = opaque {};
const WeakRef = opaque {};
const WeakRefType = enum(u32) {
    none = 0,
    fetch_response = 1,
    postgresql_query_client = 2,
};

extern "c" fn Bun__StrongRef__new(JSContextRef, EncodedValue) ?*StrongRef;
extern "c" fn Bun__StrongRef__set(?*StrongRef, JSContextRef, EncodedValue) void;
extern "c" fn Bun__StrongRef__clear(?*StrongRef) void;
extern "c" fn Bun__StrongRef__delete(?*StrongRef) void;
extern "c" fn Bun__WeakRef__new(JSContextRef, EncodedValue, WeakRefType, ?*anyopaque) ?*WeakRef;
extern "c" fn Bun__WeakRef__get(?*WeakRef) EncodedValue;
extern "c" fn Bun__WeakRef__clear(?*WeakRef) void;
extern "c" fn Bun__WeakRef__delete(?*WeakRef) void;
extern "c" fn MarkedArgumentBuffer__run(?*anyopaque, ?*const fn (?*anyopaque, ?*anyopaque) callconv(.c) void) void;
extern "c" fn MarkedArgumentBuffer__append(?*anyopaque, EncodedValue) void;
extern "c" fn JSCommonJSExtensions__appendFunction(JSContextRef, EncodedValue) u32;
extern "c" fn JSCommonJSExtensions__setFunction(JSContextRef, u32, EncodedValue) void;
extern "c" fn JSCommonJSExtensions__swapRemove(JSContextRef, u32) u32;

const PromiseCallbackState = struct {
    value: EncodedValue,
    calls: usize = 0,
};

const BufferDeallocatorState = struct {
    calls: usize = 0,
};

fn bufferFixtureDeallocator(bytes: ?*anyopaque, raw_state: ?*anyopaque) callconv(.c) void {
    const state: *BufferDeallocatorState = @ptrCast(@alignCast(raw_state.?));
    state.calls += 1;
    std.c.free(bytes);
}

const MarkedArgumentFixtureState = struct {
    vm: ?*anyopaque,
    value: EncodedValue,
    foreign: EncodedValue,
    calls: usize = 0,
};

fn markedArgumentFixtureCallback(raw: ?*anyopaque, buffer: ?*anyopaque) callconv(.c) void {
    const state: *MarkedArgumentFixtureState = @ptrCast(@alignCast(raw.?));
    state.calls += 1;
    MarkedArgumentBuffer__append(buffer, EncodedValue.fromInt32(212));
    MarkedArgumentBuffer__append(buffer, state.value);
    MarkedArgumentBuffer__append(buffer, state.foreign);
    _ = JSC__VM__runGC(state.vm, true);
}

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

fn getProperty(context: JSContextRef, object: EncodedValue, name: [*:0]const u8) EncodedValue {
    const property = JSStringCreateWithUTF8CString(name) orelse fail("property string creation failed");
    defer JSStringRelease(property);
    var exception: JSValueRef = null;
    const result = JSObjectGetProperty(context, object.cellPointer(), property, &exception);
    if (result == null or exception != null) fail("property read failed");
    return EncodedValue.fromRef(result);
}

fn encodedLatin1(context: JSContextRef, bytes: []const u8) EncodedValue {
    const string = BunString{
        .tag = .zig_string,
        .value = .{ .zig_string = .{ .tagged_ptr = @intFromPtr(bytes.ptr), .len = bytes.len } },
    };
    return BunString__toJS(context, &string);
}

fn expectZigStringUnits(actual: ZigString, expected: []const u16, utf16: bool, message: []const u8) void {
    if (actual.len != expected.len or (actual.tagged_ptr & (@as(usize, 1) << 63) != 0) != utf16)
        fail(message);
    if (actual.len == 0) {
        if (actual.tagged_ptr == 0) fail(message);
        return;
    }
    const address = actual.tagged_ptr & ((@as(usize, 1) << 53) - 1);
    if (address == 0) fail(message);
    if (utf16) {
        const units: [*]align(1) const u16 = @ptrFromInt(address);
        for (units[0..actual.len], expected) |unit, expected_unit| {
            if (unit != expected_unit) fail(message);
        }
    } else {
        const bytes: [*]const u8 = @ptrFromInt(address);
        for (bytes[0..actual.len], expected) |byte, unit| {
            if (byte != @as(u8, @intCast(unit))) fail(message);
        }
    }
}

fn getNumberProperty(context: JSContextRef, object: EncodedValue, name: [*:0]const u8) f64 {
    const property = getProperty(context, object, name);
    var exception: JSValueRef = null;
    const result = JSValueToNumber(context, property.cellPointer(), &exception);
    if (exception != null) fail("numeric property conversion failed");
    return result;
}

fn exposeCell(context: JSContextRef, name: [*:0]const u8, encoded: EncodedValue) void {
    const global = JSContextGetGlobalObject(context) orelse fail("global object lookup failed");
    const property = JSStringCreateWithUTF8CString(name) orelse fail("global property string creation failed");
    defer JSStringRelease(property);
    const cell = encoded.cellPointer() orelse fail("attempted to expose a non-cell value");
    var exception: JSValueRef = null;
    JSObjectSetProperty(context, global, property, cell, 0, &exception);
    if (exception != null) fail("global property write failed");
}

fn promiseCallback(context: *anyopaque, global: JSContextRef) callconv(.c) EncodedValue {
    _ = global;
    const state: *PromiseCallbackState = @ptrCast(@alignCast(context));
    state.calls += 1;
    return state.value;
}

fn throwingPromiseCallback(context: *anyopaque, global: JSContextRef) callconv(.c) EncodedValue {
    const state: *PromiseCallbackState = @ptrCast(@alignCast(context));
    state.calls += 1;
    JSC__VM__throwError(JSC__JSGlobalObject__vm(global), global, state.value);
    return .undefined;
}

const MicrotaskCallbackState = struct {
    global: JSContextRef,
    calls: usize = 0,
    requeue: bool = false,
    entry_observed: bool = false,
};

fn microtaskCallback(raw: ?*anyopaque) callconv(.c) void {
    const state: *MicrotaskCallbackState = @ptrCast(@alignCast(raw orelse return));
    state.calls += 1;
    state.entry_observed = state.entry_observed or JSC__VM__isEntered(JSC__JSGlobalObject__vm(state.global));
    if (state.requeue) {
        state.requeue = false;
        JSC__JSGlobalObject__queueMicrotaskCallback(state.global, state, microtaskCallback);
    }
}

fn expectPromise(
    context: JSContextRef,
    encoded: EncodedValue,
    state: enum { pending, fulfilled, rejected },
    expected: ?EncodedValue,
) void {
    exposeCell(context, "__private_observed_promise", encoded);
    _ = evaluate(context,
        \\globalThis.__private_promise_state = 'pending';
        \\globalThis.__private_promise_value = undefined;
        \\__private_observed_promise.then(
        \\  value => { __private_promise_state = 'fulfilled'; __private_promise_value = value; },
        \\  reason => { __private_promise_state = 'rejected'; __private_promise_value = reason; }
        \\);
    );
    const expected_state = switch (state) {
        .pending => evaluate(context, "'pending'"),
        .fulfilled => evaluate(context, "'fulfilled'"),
        .rejected => evaluate(context, "'rejected'"),
    };
    if (!JSC__JSValue__isStrictEqual(evaluate(context, "__private_promise_state"), expected_state, context))
        fail("private Promise state mismatch");
    if (expected) |value_| {
        if (!JSC__JSValue__isStrictEqual(evaluate(context, "__private_promise_value"), value_, context))
            fail("private Promise result identity mismatch");
    }
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

    const wrapped_large = evaluate(context, "(1n << 130n) + 5n");
    const wrapped_negative = evaluate(context, "-((1n << 130n) + 5n)");
    if (JSVALUE_TO_INT64_SLOW(signed_min) != std.math.minInt(i64) or
        JSVALUE_TO_UINT64_SLOW(signed_min) != (@as(u64, 1) << 63) or
        JSVALUE_TO_INT64_SLOW(signed_negative) != -1 or
        JSVALUE_TO_UINT64_SLOW(signed_negative) != std.math.maxInt(u64) or
        JSVALUE_TO_INT64_SLOW(unsigned_max) != -1 or
        JSVALUE_TO_UINT64_SLOW(unsigned_max) != std.math.maxInt(u64) or
        JSVALUE_TO_INT64_SLOW(wrapped_large) != 5 or
        JSVALUE_TO_UINT64_SLOW(wrapped_large) != 5 or
        JSVALUE_TO_INT64_SLOW(wrapped_negative) != -5 or
        JSVALUE_TO_UINT64_SLOW(wrapped_negative) != 0xffff_ffff_ffff_fffb or
        JSVALUE_TO_INT64_SLOW(EncodedValue.fromInt32(-42)) != -42 or
        JSVALUE_TO_UINT64_SLOW(EncodedValue.fromInt32(-42)) != @as(u64, @bitCast(@as(i64, -42))) or
        JSVALUE_TO_INT64_SLOW(EncodedValue.fromDouble(42.0)) != 42 or
        JSVALUE_TO_INT64_SLOW(.undefined) != 0 or
        JSVALUE_TO_UINT64_SLOW(encoded_object) != 0)
        fail("FFI 64-bit slow conversion mismatch");

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

    const signed_min_string = JSC__JSBigInt__toString(signed_min_cell, context);
    const huge_string = JSC__JSBigInt__toString(huge_positive, context);
    const huge_string_second = JSC__JSBigInt__toString(huge_positive, context);
    const signed_min_impl = signed_min_string.value.wtf_string_impl orelse fail("BigInt string missing StringImpl");
    const huge_impl = huge_string.value.wtf_string_impl orelse fail("huge BigInt string missing StringImpl");
    const huge_second_impl = huge_string_second.value.wtf_string_impl orelse fail("fresh BigInt string missing StringImpl");
    if (signed_min_string.tag != .wtf_string_impl or huge_string.tag != .wtf_string_impl or
        signed_min_impl.length != "-9223372036854775808".len or
        !std.mem.eql(u8, signed_min_impl.bytes[0..signed_min_impl.length], "-9223372036854775808") or
        !std.mem.eql(u8, huge_impl.bytes[0..huge_impl.length], "184467440737095516160000000000000000000") or
        huge_impl == huge_second_impl or
        signed_min_impl.ref_count != 2 or huge_impl.ref_count != 2 or
        signed_min_impl.hash_and_flags & 4 == 0)
        fail("owned BunString BigInt conversion mismatch");

    const latin1_bytes = "caf\xe9";
    var latin1_string = BunString{
        .tag = .zig_string,
        .value = .{ .zig_string = .{ .tagged_ptr = @intFromPtr(latin1_bytes.ptr), .len = latin1_bytes.len } },
    };
    const utf8_bytes = "A😀Z";
    var utf8_string = BunString{
        .tag = .zig_string,
        .value = .{ .zig_string = .{ .tagged_ptr = @intFromPtr(utf8_bytes.ptr) | (@as(usize, 1) << 61), .len = utf8_bytes.len } },
    };
    const utf16_units = [_]u16{ 'A', 0xd83d, 0xde00, 0xd800, 'Z' };
    var utf16_string = BunString{
        .tag = .static_zig_string,
        .value = .{ .zig_string = .{ .tagged_ptr = @intFromPtr(&utf16_units) | (@as(usize, 1) << 63), .len = utf16_units.len } },
    };
    var empty_bun_string = BunString{ .tag = .empty, .value = .{ .zig_string = .{ .tagged_ptr = 0, .len = 0 } } };
    if (!JSC__JSValue__isStrictEqual(BunString__toJS(context, &latin1_string), evaluate(context, "'café'"), context) or
        !JSC__JSValue__isStrictEqual(BunString__toJS(context, &utf8_string), evaluate(context, "'A😀Z'"), context) or
        !JSC__JSValue__isStrictEqual(BunString__toJS(context, &utf16_string), evaluate(context, "'A😀\\uD800Z'"), context) or
        !JSC__JSValue__isStrictEqual(BunString__toJS(context, &huge_string), evaluate(context, "'184467440737095516160000000000000000000'"), context) or
        !JSC__JSValue__isStrictEqual(BunString__toJS(context, &empty_bun_string), evaluate(context, "''"), context) or
        huge_impl.ref_count != 2)
        fail("BunString representation conversion mismatch");
    if (!JSC__JSValue__isStrictEqual(BunString__toJSWithLength(context, &utf8_string, 2), evaluate(context, "'A\\uD83D'"), context) or
        !JSC__JSValue__isStrictEqual(BunString__toJSWithLength(context, &utf16_string, 4), evaluate(context, "'A😀\\uD800'"), context) or
        !JSC__JSValue__isStrictEqual(BunString__toJSWithLength(context, &latin1_string, 3), evaluate(context, "'caf'"), context))
        fail("BunString UTF-16 length conversion mismatch");

    var transfer_string = JSC__JSBigInt__toString(unsigned_max_cell, context);
    if (!JSC__JSValue__isStrictEqual(BunString__transferToJS(&transfer_string, context), evaluate(context, "'18446744073709551615'"), context) or
        transfer_string.tag != .dead)
        fail("BunString owned transfer mismatch");
    if (!JSC__JSValue__isStrictEqual(BunString__transferToJS(&empty_bun_string, context), evaluate(context, "''"), context) or
        empty_bun_string.tag != .empty)
        fail("BunString empty transfer mismatch");

    const bun_strings = [_]BunString{ empty_bun_string, latin1_string, utf16_string };
    const bun_string_array = BunString__createArray(context, &bun_strings, bun_strings.len);
    const empty_bun_string_array = BunString__createArray(context, null, 0);
    exposeCell(context, "__private_bun_string_array", bun_string_array);
    exposeCell(context, "__private_empty_bun_string_array", empty_bun_string_array);
    if (!JSC__JSValue__toBoolean(evaluate(context, "__private_empty_bun_string_array.length === 0 && __private_bun_string_array.length === 3 && __private_bun_string_array[0] === '' && __private_bun_string_array[1] === 'café' && __private_bun_string_array[2] === 'A😀\\uD800Z'")))
        fail("BunString array conversion mismatch");

    var string_builder: StringBuilder = undefined;
    StringBuilder__init(&string_builder);
    StringBuilder__ensureUnusedCapacity(&string_builder, 4);
    StringBuilder__appendLatin1(&string_builder, "pre:", 4);
    StringBuilder__appendUtf16(&string_builder, &utf16_units, utf16_units.len);
    StringBuilder__appendLChar(&string_builder, '|');
    StringBuilder__appendString(&string_builder, latin1_string);
    StringBuilder__appendUChar(&string_builder, 0x03a9);
    StringBuilder__appendString(&string_builder, huge_string);
    const built_string = StringBuilder__toString(&string_builder, context);
    const built_string_again = StringBuilder__toString(&string_builder, context);
    if (!JSC__JSValue__isStrictEqual(built_string, evaluate(context, "'pre:A😀\\uD800Z|caféΩ184467440737095516160000000000000000000'"), context) or
        !JSC__JSValue__isStrictEqual(built_string, built_string_again, context) or
        huge_impl.ref_count != 2)
        fail("private StringBuilder text/repeated conversion mismatch");
    StringBuilder__deinit(&string_builder);

    const regex_pattern_bytes = "a+";
    const regex_pattern = BunString{
        .tag = .static_zig_string,
        .value = .{ .zig_string = .{ .tagged_ptr = @intFromPtr(regex_pattern_bytes.ptr), .len = regex_pattern_bytes.len } },
    };
    const regex_input_bytes = "xxaaayaaa";
    const regex_input = BunString{
        .tag = .static_zig_string,
        .value = .{ .zig_string = .{ .tagged_ptr = @intFromPtr(regex_input_bytes.ptr), .len = regex_input_bytes.len } },
    };
    const regular_expression = Yarr__RegularExpression__init(regex_pattern, 0) orelse
        fail("RegularExpression allocation failed");
    if (!Yarr__RegularExpression__isValid(regular_expression) or
        Yarr__RegularExpression__matches(regular_expression, regex_input) != 2 or
        Yarr__RegularExpression__matchedLength(regular_expression) != 3 or
        Yarr__RegularExpression__searchRev(regular_expression, regex_input) != 6 or
        Yarr__RegularExpression__matchedLength(regular_expression) != 3)
        fail("RegularExpression forward/reverse state mismatch");
    Yarr__RegularExpression__deinit(regular_expression);

    const invalid_regex_bytes = "[";
    const invalid_regular_expression = Yarr__RegularExpression__init(.{
        .tag = .static_zig_string,
        .value = .{ .zig_string = .{ .tagged_ptr = @intFromPtr(invalid_regex_bytes.ptr), .len = invalid_regex_bytes.len } },
    }, 0) orelse fail("invalid RegularExpression allocation failed");
    if (Yarr__RegularExpression__isValid(invalid_regular_expression) or
        Yarr__RegularExpression__matches(invalid_regular_expression, regex_input) != -1 or
        Yarr__RegularExpression__matchedLength(invalid_regular_expression) != -1)
        fail("invalid RegularExpression state mismatch");
    Yarr__RegularExpression__deinit(invalid_regular_expression);

    var parsed_length: usize = 0;
    if (WTF__parseDouble("12.5tail", 8, &parsed_length) != 12.5 or parsed_length != 4 or
        WTF__parseES5Date("2000-01-01T00:00:00.000Z", 24) != 946_684_800_000 or
        WTF__numberOfProcessorCores() < 1)
        fail("WTF parse/processor helper mismatch");
    WTF__releaseFastMallocFreeMemoryForThisThread();
    var http_date: [32]u8 = @splat(0);
    if (Bun__writeHTTPDate(&http_date, http_date.len, 784_111_777_000) != 29 or
        !std.mem.eql(u8, http_date[0..29], "Sun, 06 Nov 1994 08:49:37 GMT"))
        fail("WTF HTTP date helper mismatch");

    var uint8_source = [_]u8{ 1, 2, 3, 4 };
    const copied_uint8 = Bun__createUint8ArrayForCopy(context, &uint8_source, uint8_source.len, false);
    var typed_exception: JSValueRef = null;
    const copied_bytes_raw = JSObjectGetTypedArrayBytesPtr(context, copied_uint8.cellPointer(), &typed_exception) orelse
        fail("Uint8Array copy bytes lookup failed");
    const copied_bytes = @as([*]u8, @ptrCast(copied_bytes_raw))[0..uint8_source.len];
    if (typed_exception != null or JSObjectGetTypedArrayLength(context, copied_uint8.cellPointer(), &typed_exception) != uint8_source.len or
        !std.mem.eql(u8, copied_bytes, &uint8_source) or JSBuffer__isBuffer(context, copied_uint8))
        fail("Uint8Array copy constructor mismatch");
    uint8_source[0] = 99;
    if (copied_bytes[0] != 1) fail("Uint8Array copy aliases its source");

    const private_buffer = Bun__createUint8ArrayForCopy(context, null, 3, true);
    const private_buffer_bytes_raw = JSObjectGetTypedArrayBytesPtr(context, private_buffer.cellPointer(), &typed_exception) orelse
        fail("Buffer bytes lookup failed");
    const private_buffer_bytes = @as([*]u8, @ptrCast(private_buffer_bytes_raw))[0..3];
    private_buffer_bytes[1] = 42;
    if (typed_exception != null or !JSBuffer__isBuffer(context, private_buffer) or private_buffer_bytes[1] != 42)
        fail("Buffer identity/allocation mismatch");

    const adopted_raw = std.c.malloc(4) orelse fail("default-allocator fixture allocation failed");
    const adopted_input = @as([*]u8, @ptrCast(adopted_raw))[0..4];
    @memcpy(adopted_input, &[_]u8{ 7, 8, 9, 10 });
    const adopted_uint8 = JSUint8Array__fromDefaultAllocator(context, adopted_input.ptr, adopted_input.len);
    const adopted_bytes_raw = JSObjectGetTypedArrayBytesPtr(context, adopted_uint8.cellPointer(), &typed_exception) orelse
        fail("adopted Uint8Array bytes lookup failed");
    if (typed_exception != null or adopted_bytes_raw != adopted_raw or
        !std.mem.eql(u8, @as([*]const u8, @ptrCast(adopted_bytes_raw))[0..4], adopted_input))
        fail("default-allocator Uint8Array did not adopt its bytes");

    var empty_sentinel: u8 = 0;
    const empty_uint8 = JSUint8Array__fromDefaultAllocator(context, @ptrCast(&empty_sentinel), 0);
    if (JSObjectGetTypedArrayLength(context, empty_uint8.cellPointer(), &typed_exception) != 0 or typed_exception != null)
        fail("empty default-allocator Uint8Array mismatch");

    const allocated_buffer = JSBuffer__bufferFromLength(context, 5);
    if (!JSBuffer__isBuffer(context, allocated_buffer) or
        JSObjectGetTypedArrayLength(context, allocated_buffer.cellPointer(), &typed_exception) != 5 or typed_exception != null)
        fail("Buffer length constructor mismatch");
    if (JSBuffer__bufferFromLength(context, -1) != .empty or !JSGlobalObject__hasException(context))
        fail("negative Buffer length did not throw");
    JSGlobalObject__clearException(context);

    const ownership_context = JSGlobalContextCreate(null) orelse fail("no-copy ownership context creation failed");
    var no_copy_state = BufferDeallocatorState{};
    const adopted_array_buffer_raw = std.c.malloc(5) orelse fail("no-copy ArrayBuffer allocation failed");
    const adopted_array_buffer = Bun__makeArrayBufferWithBytesNoCopy(
        ownership_context,
        adopted_array_buffer_raw,
        5,
        bufferFixtureDeallocator,
        &no_copy_state,
    );
    var ownership_exception: JSValueRef = null;
    const adopted_array_buffer_ptr = JSObjectGetArrayBufferBytesPtr(ownership_context, adopted_array_buffer.cellPointer(), &ownership_exception) orelse
        fail("no-copy ArrayBuffer pointer lookup failed");
    if (ownership_exception != null or adopted_array_buffer_ptr != adopted_array_buffer_raw or
        JSObjectGetArrayBufferByteLength(ownership_context, adopted_array_buffer.cellPointer(), &ownership_exception) != 5)
        fail("no-copy ArrayBuffer adoption mismatch");

    const adopted_f64_raw = std.c.malloc(17) orelse fail("no-copy Float64Array allocation failed");
    const adopted_f64 = Bun__makeTypedArrayWithBytesNoCopy(
        ownership_context,
        .f64,
        adopted_f64_raw,
        17,
        bufferFixtureDeallocator,
        &no_copy_state,
    );
    const adopted_f64_buffer = JSObjectGetTypedArrayBuffer(ownership_context, adopted_f64.cellPointer(), &ownership_exception) orelse
        fail("no-copy Float64Array buffer lookup failed");
    if (ownership_exception != null or
        JSObjectGetTypedArrayLength(ownership_context, adopted_f64.cellPointer(), &ownership_exception) != 2 or
        JSObjectGetArrayBufferBytesPtr(ownership_context, adopted_f64_buffer, &ownership_exception) != adopted_f64_raw or
        JSObjectGetArrayBufferByteLength(ownership_context, adopted_f64_buffer, &ownership_exception) != 17)
        fail("no-copy Float64Array trailing-byte mismatch");

    const adopted_empty_raw = std.c.malloc(1) orelse fail("empty no-copy TypedArray allocation failed");
    const adopted_empty = Bun__makeTypedArrayWithBytesNoCopy(
        ownership_context,
        .u16,
        adopted_empty_raw,
        0,
        bufferFixtureDeallocator,
        &no_copy_state,
    );
    if (JSObjectGetTypedArrayLength(ownership_context, adopted_empty.cellPointer(), &ownership_exception) != 0 or
        ownership_exception != null or no_copy_state.calls != 0)
        fail("empty no-copy TypedArray ownership mismatch");

    const invalid_no_copy_raw = std.c.malloc(1) orelse fail("invalid no-copy TypedArray allocation failed");
    if (Bun__makeTypedArrayWithBytesNoCopy(
        ownership_context,
        .data_view,
        invalid_no_copy_raw,
        1,
        bufferFixtureDeallocator,
        &no_copy_state,
    ) != .empty or !JSGlobalObject__hasException(ownership_context) or no_copy_state.calls != 1)
        fail("invalid no-copy TypedArray did not fail atomically");
    JSGlobalObject__clearException(ownership_context);
    JSGlobalContextRelease(ownership_context);
    if (no_copy_state.calls != 4) fail("no-copy storage finalizers did not run exactly once");

    var buffer_deallocator_state = BufferDeallocatorState{};
    const external_buffer_raw = std.c.malloc(3) orelse fail("external Buffer fixture allocation failed");
    const external_buffer_input = @as([*]u8, @ptrCast(external_buffer_raw))[0..3];
    @memcpy(external_buffer_input, &[_]u8{ 21, 22, 23 });
    const external_buffer = JSBuffer__bufferFromPointerAndLengthAndDeinit(
        context,
        external_buffer_input.ptr,
        external_buffer_input.len,
        &buffer_deallocator_state,
        bufferFixtureDeallocator,
    );
    const external_buffer_bytes = JSObjectGetTypedArrayBytesPtr(context, external_buffer.cellPointer(), &typed_exception) orelse
        fail("external Buffer bytes lookup failed");
    if (typed_exception != null or !JSBuffer__isBuffer(context, external_buffer) or
        external_buffer_bytes != external_buffer_raw or buffer_deallocator_state.calls != 0)
        fail("external Buffer ownership mismatch");

    const empty_buffer_raw = std.c.malloc(1) orelse fail("empty Buffer fixture allocation failed");
    const empty_buffer = JSBuffer__bufferFromPointerAndLengthAndDeinit(
        context,
        @ptrCast(empty_buffer_raw),
        0,
        &buffer_deallocator_state,
        bufferFixtureDeallocator,
    );
    if (!JSBuffer__isBuffer(context, empty_buffer) or buffer_deallocator_state.calls != 1)
        fail("empty Buffer did not release transferred storage immediately");

    if (comptime @import("builtin").os.tag != .windows) {
        const fixture_mapping = std.posix.mmap(
            null,
            std.heap.page_size_min,
            .{ .READ = true, .WRITE = true },
            .{ .TYPE = .PRIVATE, .ANONYMOUS = true },
            -1,
            0,
        ) catch fail("Buffer mmap fixture allocation failed");
        fixture_mapping[0] = 0x6b;
        const mmap_buffer = JSBuffer__fromMmap(context, fixture_mapping.ptr, fixture_mapping.len);
        const mmap_buffer_bytes = JSObjectGetTypedArrayBytesPtr(context, mmap_buffer.cellPointer(), &typed_exception) orelse
            fail("mmap Buffer bytes lookup failed");
        if (typed_exception != null or !JSBuffer__isBuffer(context, mmap_buffer) or
            @intFromPtr(mmap_buffer_bytes) != @intFromPtr(fixture_mapping.ptr) or @as(*u8, @ptrCast(mmap_buffer_bytes)).* != 0x6b)
            fail("mmap Buffer ownership mismatch");
    }

    const uninitialized_uint8 = JSC__JSValue__createUninitializedUint8Array(context, 7);
    const uninitialized_bytes_raw = JSObjectGetTypedArrayBytesPtr(context, uninitialized_uint8.cellPointer(), &typed_exception) orelse
        fail("uninitialized Uint8Array bytes lookup failed");
    const uninitialized_bytes = @as([*]u8, @ptrCast(uninitialized_bytes_raw))[0..7];
    @memset(uninitialized_bytes, 0x7c);
    if (typed_exception != null or JSBuffer__isBuffer(context, uninitialized_uint8) or
        JSObjectGetTypedArrayLength(context, uninitialized_uint8.cellPointer(), &typed_exception) != 7 or
        !std.mem.eql(u8, uninitialized_bytes, &[_]u8{ 0x7c, 0x7c, 0x7c, 0x7c, 0x7c, 0x7c, 0x7c }))
        fail("uninitialized Uint8Array identity/write mismatch");
    if (JSC__JSValue__createUninitializedUint8Array(context, std.math.maxInt(usize)) != .empty or
        !JSGlobalObject__hasException(context))
        fail("oversized uninitialized Uint8Array did not throw");
    JSGlobalObject__clearException(context);

    var projected_uint8 = PrivateBunArrayBuffer{};
    if (!JSC__JSValue__asArrayBuffer(copied_uint8, context, &projected_uint8) or
        projected_uint8.ptr == null or projected_uint8.len != 4 or projected_uint8.byte_len != 4 or
        projected_uint8.encoded_value != copied_uint8 or projected_uint8.cell_type != 50 or
        projected_uint8.shared or projected_uint8.resizable)
        fail("Uint8Array projection mismatch");
    const projected_uint8_buffer = JSObjectGetTypedArrayBuffer(context, copied_uint8.cellPointer(), &typed_exception) orelse
        fail("projected Uint8Array buffer lookup failed");
    var projected_buffer = PrivateBunArrayBuffer{};
    const projected_buffer_encoded = EncodedValue.fromRef(projected_uint8_buffer);
    if (!JSC__JSValue__asArrayBuffer(projected_buffer_encoded, context, &projected_buffer) or
        projected_buffer.len != 4 or projected_buffer.byte_len != 4 or projected_buffer.cell_type != 48)
        fail("ArrayBuffer projection mismatch");
    const projected_view = evaluate(context, "new DataView(new ArrayBuffer(9), 2, 5)");
    var projected_data_view = PrivateBunArrayBuffer{};
    if (!JSC__JSValue__asArrayBuffer(projected_view, context, &projected_data_view) or
        projected_data_view.len != 5 or projected_data_view.byte_len != 5 or projected_data_view.cell_type != 61)
        fail("DataView projection mismatch");
    var untouched_projection = PrivateBunArrayBuffer{ .len = 77, .byte_len = 88 };
    if (JSC__JSValue__asArrayBuffer(.undefined, context, &untouched_projection) or
        untouched_projection.len != 77 or untouched_projection.byte_len != 88)
        fail("invalid ArrayBuffer projection modified output");

    const typeof_cases = [_]struct { EncodedValue, []const u8, EncodedValue }{
        .{ .undefined, "undefined", evaluate(context, "'undefined'") },
        .{ .null, "object", evaluate(context, "'object'") },
        .{ .true, "boolean", evaluate(context, "'boolean'") },
        .{ EncodedValue.fromInt32(220), "number", evaluate(context, "'number'") },
        .{ evaluate(context, "'value'"), "string", evaluate(context, "'string'") },
        .{ evaluate(context, "Symbol('value')"), "symbol", evaluate(context, "'symbol'") },
        .{ evaluate(context, "220n"), "bigint", evaluate(context, "'bigint'") },
        .{ evaluate(context, "({ value: 220 })"), "object", evaluate(context, "'object'") },
        .{ evaluate(context, "(function named() {})"), "function", evaluate(context, "'function'") },
    };
    var typeof_undefined: ?*anyopaque = null;
    var typeof_object: ?*anyopaque = null;
    for (typeof_cases) |case| {
        const cell = JSC__jsTypeStringForValue(context, case[0]) orelse fail("typeof string projection failed");
        if (!JSC__JSString__is8Bit(cell) or JSC__JSString__length(cell) != case[1].len or
            !JSC__JSValue__isStrictEqual(EncodedValue.fromBits(@intFromPtr(cell)), case[2], context))
            fail("typeof string contents mismatch");
        if (std.mem.eql(u8, case[1], "undefined")) typeof_undefined = cell;
        if (std.mem.eql(u8, case[1], "object")) {
            if (typeof_object) |first_object| {
                if (first_object != cell) fail("typeof object small string identity mismatch");
            } else typeof_object = cell;
        }
    }
    if (JSC__jsTypeStringForValue(context, .undefined) != typeof_undefined or
        JSC__jsTypeStringForValue(context, evaluate(foreign_context, "({})")) != null or
        JSC__jsTypeStringForValue(context, .empty) != null)
        fail("typeof VM ownership/rejection mismatch");
    JSC__VM__throwError(JSC__JSGlobalObject__vm(context), context, EncodedValue.fromInt32(220));
    if (JSC__jsTypeStringForValue(context, .undefined) != typeof_undefined)
        fail("typeof projection was blocked by pending exception");
    const typeof_exception = JSGlobalObject__tryTakeException(context);
    if (JSC__Exception__asJSValue(typeof_exception.cellPointer()) != EncodedValue.fromInt32(220))
        fail("typeof projection replaced pending exception");

    const tier_source = "function tier222(n) { if (n <= 0) return 0; return tier222(n - 1) + 1; }";
    const tier_function = evaluate(context, "(function tier222(n) { if (n <= 0) return 0; return tier222(n - 1) + 1; })");
    var tier_source_view = ZigString{ .tagged_ptr = 0x222, .len = 222 };
    if (!JSC__JSFunction__getSourceCode(tier_function, &tier_source_view) or
        tier_source_view.tagged_ptr >> 63 != 0 or tier_source_view.len != tier_source.len or
        !JSC__JSValue__isStrictEqual(ZigString__toValueGC(&tier_source_view, context), evaluate(context, "'function tier222(n) { if (n <= 0) return 0; return tier222(n - 1) + 1; }'"), context))
        fail("private JSFunction source projection mismatch");
    var rejected_source = ZigString{ .tagged_ptr = 0x222, .len = 222 };
    if (JSC__JSFunction__getSourceCode(evaluate(context, "Math.max"), &rejected_source) or
        rejected_source.tagged_ptr != 0x222 or rejected_source.len != 222)
        fail("private native function source rejection mismatch");
    exposeCell(context, "__private_tier_222", tier_function);
    JSC__JSFunction__optimizeSoon(tier_function);
    if (Bun__JSValue__toNumber(evaluate(context, "__private_tier_222(4)"), context) != 4)
        fail("private JSFunction tier-up changed execution");
    JSC__VM__throwError(JSC__JSGlobalObject__vm(context), context, EncodedValue.fromInt32(222));
    JSC__JSFunction__optimizeSoon(tier_function);
    const tier_exception = JSGlobalObject__tryTakeException(context);
    if (JSC__Exception__asJSValue(tier_exception.cellPointer()) != EncodedValue.fromInt32(222))
        fail("private JSFunction tier-up replaced pending exception");

    if (JSC__JSValue__getLengthIfPropertyExistsInternal(evaluate(context, "'A😀\\uD800'"), context) != 4 or
        JSC__JSValue__getLengthIfPropertyExistsInternal(evaluate(context, "new Array(8)"), context) != 8 or
        JSC__JSValue__getLengthIfPropertyExistsInternal(evaluate(context, "new Float64Array(6)"), context) != 6 or
        JSC__JSValue__getLengthIfPropertyExistsInternal(evaluate(context, "new ArrayBuffer(17)"), context) != 17 or
        JSC__JSValue__getLengthIfPropertyExistsInternal(evaluate(context, "(() => { const m = new Map([[1, 1], [2, 2]]); m.length = 99; return m; })()"), context) != 2 or
        JSC__JSValue__getLengthIfPropertyExistsInternal(evaluate(context, "({ get length() { return '12'; } })"), context) != 12 or
        !std.math.isPositiveInf(JSC__JSValue__getLengthIfPropertyExistsInternal(evaluate(context, "({})"), context)) or
        JSC__JSValue__getLengthIfPropertyExistsInternal(EncodedValue.fromInt32(1), context) != 0 or
        JSC__JSValue__getLengthIfPropertyExistsInternal(EncodedValue.fromRef(foreign_object), context) != 0)
        fail("private internal length projection mismatch");
    if (JSC__JSValue__getLengthIfPropertyExistsInternal(evaluate(context, "({ get length() { throw 223; } })"), context) != 0 or
        !JSGlobalObject__hasException(context))
        fail("private internal length projection missed abrupt completion");
    const length_exception = JSGlobalObject__tryTakeException(context);
    if (JSC__Exception__asJSValue(length_exception.cellPointer()) != EncodedValue.fromInt32(223))
        fail("private internal length projection changed thrown identity");

    const path_target = evaluate(context, "({ a: { '0': { b: 224 } }, present: undefined, '': { '': 225 } })");
    if (!JSC__JSValue__isStrictEqual(
        JSC__JSValue__getIfPropertyExistsFromPath(path_target, context, evaluate(context, "'a[0].b'")),
        EncodedValue.fromInt32(224),
        context,
    ) or !JSC__JSValue__isStrictEqual(
        JSC__JSValue__getIfPropertyExistsFromPath(path_target, context, evaluate(context, "['a', 0, 'b']")),
        EncodedValue.fromInt32(224),
        context,
    ) or !JSC__JSValue__isStrictEqual(
        JSC__JSValue__getIfPropertyExistsFromPath(path_target, context, evaluate(context, "'.'")),
        EncodedValue.fromInt32(225),
        context,
    ) or JSC__JSValue__getIfPropertyExistsFromPath(path_target, context, evaluate(context, "'present'")) != .undefined or
        JSC__JSValue__getIfPropertyExistsFromPath(path_target, context, evaluate(context, "'missing'")) != .empty)
        fail("private property-path traversal mismatch");
    if (JSC__JSValue__getIfPropertyExistsFromPath(
        evaluate(context, "({ get a() { throw 224; } })"),
        context,
        evaluate(context, "'a'"),
    ) != .empty or !JSGlobalObject__hasException(context))
        fail("private property-path traversal missed abrupt completion");
    const path_exception = JSGlobalObject__tryTakeException(context);
    if (JSC__Exception__asJSValue(path_exception.cellPointer()) != EncodedValue.fromInt32(224))
        fail("private property-path traversal changed thrown identity");

    var class_info_pointer: [*:0]const u8 = "untouched";
    var class_info_length: usize = 225;
    if (!JSC__JSValue__getClassInfoName(evaluate(context, "new Uint16Array(1)"), &class_info_pointer, &class_info_length) or
        !std.mem.eql(u8, class_info_pointer[0..class_info_length], "Uint16Array") or
        JSC__JSValue__getClassInfoName(EncodedValue.fromInt32(1), &class_info_pointer, &class_info_length))
        fail("private static class-info name mismatch");

    var projected_name = ZigString{ .tagged_ptr = 0x225, .len = 225 };
    JSC__JSValue__getNameProperty(evaluate(context, "({ [Symbol.toStringTag]: 'Tagged225' })"), context, &projected_name);
    if (!JSC__JSValue__isStrictEqual(ZigString__toValueGC(&projected_name, context), evaluate(context, "'Tagged225'"), context))
        fail("private name-property projection mismatch");
    projected_name = .{ .tagged_ptr = 0x225, .len = 225 };
    JSC__JSValue__getClassName(evaluate(context, "new (class Fixture225 {})"), context, &projected_name);
    if (!JSC__JSValue__isStrictEqual(ZigString__toValueGC(&projected_name, context), evaluate(context, "'Fixture225'"), context))
        fail("private calculated class-name projection mismatch");

    var owned_display_name = BunString{ .tag = .dead, .value = .{ .zig_string = .{ .tagged_ptr = 0, .len = 0 } } };
    JSC__JSValue__getName(evaluate(context, "({ [Symbol.toStringTag]: '名字😀' })"), context, &owned_display_name);
    if (owned_display_name.tag != .wtf_string_impl or
        !JSC__JSValue__isStrictEqual(BunString__toJS(context, &owned_display_name), evaluate(context, "'名字😀'"), context))
        fail("private owned display-name projection mismatch");
    Bun__WTFStringImpl__deref(owned_display_name.value.wtf_string_impl);

    var json_output = BunString{ .tag = .dead, .value = .{ .zig_string = .{ .tagged_ptr = 0, .len = 0 } } };
    const json_target = evaluate(context, "({ z: 1, a: [true, null] })");
    JSC__JSValue__jsonStringify(json_target, context, 2, &json_output);
    if (json_output.tag != .wtf_string_impl or
        !JSC__JSValue__isStrictEqual(BunString__toJS(context, &json_output), evaluate(context, "'{\\n  \\\"z\\\": 1,\\n  \\\"a\\\": [\\n    true,\\n    null\\n  ]\\n}'"), context))
        fail("private indented JSON stringification mismatch");
    Bun__WTFStringImpl__deref(json_output.value.wtf_string_impl);

    if (!JSC__JSValue__isJSXElement(evaluate(context, "({ $$typeof: Symbol.for('react.element') })"), context) or
        !JSC__JSValue__isJSXElement(evaluate(context, "({ $$typeof: Symbol.for('react.transitional.element') })"), context) or
        JSC__JSValue__isJSXElement(evaluate(context, "({ $$typeof: Symbol('react.element') })"), context))
        fail("private JSX element registry predicate mismatch");
    const proxy_value = evaluate(context, "globalThis.__proxy_target_233 = { target: 233 }; globalThis.__proxy_handler_233 = {}; new Proxy(__proxy_target_233, __proxy_handler_233)");
    if (!JSC__JSValue__isStrictEqual(Bun__ProxyObject__getInternalField(proxy_value, 0), evaluate(context, "__proxy_target_233"), context) or
        !JSC__JSValue__isStrictEqual(Bun__ProxyObject__getInternalField(proxy_value, 1), evaluate(context, "__proxy_handler_233"), context) or
        Bun__ProxyObject__getInternalField(evaluate(context, "({})"), 0) != .empty or
        Bun__ProxyObject__getInternalField(proxy_value, 2) != .empty or
        Bun__ProxyObject__getInternalField(evaluate(context, "(() => { const value = Proxy.revocable({}, {}); value.revoke(); return value.proxy; })()"), 0) != .null)
        fail("private proxy internal-field projection mismatch");
    const cyclic_left = evaluate(context, "(() => { const value = { key: [1, undefined] }; value.self = value; return value; })()");
    const cyclic_right = evaluate(context, "(() => { const value = { key: [1, undefined] }; value.self = value; return value; })()");
    if (!JSC__JSValue__deepEquals(cyclic_left, cyclic_right, context) or
        !JSC__JSValue__strictDeepEquals(cyclic_left, cyclic_right, context) or
        !JSC__JSValue__deepEquals(evaluate(context, "({ missing: undefined })"), evaluate(context, "({})"), context) or
        JSC__JSValue__strictDeepEquals(evaluate(context, "({ missing: undefined })"), evaluate(context, "({})"), context))
        fail("private core deep-equality semantics mismatch");
    const asymmetric_anything = evaluate(context, "globalThis.__private_asymmetric_anything = { __zig_js_asymmetric_matcher__: 'anything' }; __private_asymmetric_anything");
    const deep_match_target = evaluate(context, "globalThis.__private_deep_match_target = { nested: { value: 231, extra: true } }; __private_deep_match_target");
    const deep_match_subset = evaluate(context, "({ nested: { value: __private_asymmetric_anything } })");
    if (!JSC__JSValue__jestDeepEquals(EncodedValue.fromInt32(231), asymmetric_anything, context) or
        !JSC__JSValue__jestStrictDeepEquals(asymmetric_anything, EncodedValue.fromInt32(231), context) or
        !JSC__JSValue__jestDeepMatch(deep_match_target, deep_match_subset, context, true) or
        !JSC__JSValue__toBoolean(evaluate(context, "__private_deep_match_target.nested.value === __private_asymmetric_anything")))
        fail("private Jest equality/deep-match semantics mismatch");
    const remote_inspection_default = JSRemoteInspectorGetInspectionEnabledByDefault();
    JSRemoteInspectorSetInspectionEnabledByDefault(!remote_inspection_default);
    if (JSRemoteInspectorGetInspectionEnabledByDefault() == remote_inspection_default)
        fail("private remote-inspector default did not update");
    JSRemoteInspectorSetInspectionEnabledByDefault(remote_inspection_default);
    JSRemoteInspectorSetLogToSystemConsole(false);
    JSRemoteInspectorDisableAutoStart();
    JSRemoteInspectorStart();
    const script_execution_context_id = ScriptExecutionContextIdentifier__forGlobalObject(context);
    if (script_execution_context_id == 0 or
        ScriptExecutionContextIdentifier__forGlobalObject(context) != script_execution_context_id or
        ScriptExecutionContextIdentifier__forGlobalObject(null) != 0)
        fail("private script execution context identifier mismatch");
    if (!JSC__JSValue__isStrictEqual(
        Bun__noSideEffectsToString(JSC__JSGlobalObject__vm(context), context, evaluate(context, "new Proxy({}, { get() { throw 235; } })")),
        evaluate(context, "'[object Object]'"),
        context,
    )) fail("private no-side-effects stringification mismatch");
    _ = evaluate(context, "globalThis.__private_error_like_gets = 0");
    if (!Bun__promises__isErrorLike(context, evaluate(context, "({ get stack() { __private_error_like_gets++; throw 236; } })")) or
        Bun__promises__isErrorLike(context, evaluate(context, "Object.create({ stack: 1 })")) or
        Bun__promises__isErrorLike(context, EncodedValue.fromInt32(236)) or
        getNumberProperty(context, global_value, "__private_error_like_gets") != 0)
        fail("private rejection error-like classification mismatch");
    json_output = .{ .tag = .dead, .value = .{ .zig_string = .{ .tagged_ptr = 0, .len = 0 } } };
    JSC__JSValue__jsonStringifyFast(json_target, context, &json_output);
    if (json_output.tag != .wtf_string_impl or
        !JSC__JSValue__isStrictEqual(BunString__toJS(context, &json_output), evaluate(context, "'{\\\"z\\\":1,\\\"a\\\":[true,null]}'"), context))
        fail("private compact JSON stringification mismatch");
    Bun__WTFStringImpl__deref(json_output.value.wtf_string_impl);

    StringBuilder__init(&string_builder);
    StringBuilder__appendInt(&string_builder, std.math.minInt(i32));
    StringBuilder__appendLChar(&string_builder, '|');
    StringBuilder__appendUsize(&string_builder, std.math.maxInt(usize));
    for ([_]f64{ -0.0, std.math.nan(f64), std.math.inf(f64), -std.math.inf(f64), 1e21 }) |number| {
        StringBuilder__appendLChar(&string_builder, '|');
        StringBuilder__appendDouble(&string_builder, number);
    }
    if (!JSC__JSValue__isStrictEqual(
        StringBuilder__toString(&string_builder, context),
        evaluate(context, "'-2147483648|18446744073709551615|0|NaN|Infinity|-Infinity|1e+21'"),
        context,
    )) fail("private StringBuilder numeric formatting mismatch");
    StringBuilder__deinit(&string_builder);

    StringBuilder__init(&string_builder);
    StringBuilder__appendQuotedJsonString(&string_builder, utf16_string);
    if (!JSC__JSValue__isStrictEqual(
        StringBuilder__toString(&string_builder, context),
        evaluate(context, "JSON.stringify('A😀\\uD800Z')"),
        context,
    )) fail("private StringBuilder JSON quoting mismatch");
    StringBuilder__deinit(&string_builder);

    StringBuilder__init(&string_builder);
    StringBuilder__ensureUnusedCapacity(&string_builder, std.math.maxInt(usize));
    if (StringBuilder__toString(&string_builder, context) != .empty or !JSGlobalObject__hasException(context))
        fail("private StringBuilder overflow did not throw OOM");
    JSGlobalObject__clearException(context);
    StringBuilder__deinit(&string_builder);

    var blocked_transfer = JSC__JSBigInt__toString(signed_negative_cell, context);
    JSC__VM__throwError(JSC__JSGlobalObject__vm(context), context, EncodedValue.fromInt32(196));
    if (BunString__transferToJS(&blocked_transfer, context) != .empty or blocked_transfer.tag != .wtf_string_impl)
        fail("BunString transfer ignored pending exception");
    const preserved_transfer_exception = JSGlobalObject__tryTakeException(context);
    if (JSC__Exception__asJSValue(preserved_transfer_exception.cellPointer()) != EncodedValue.fromInt32(196))
        fail("BunString transfer replaced pending exception");
    Bun__WTFStringImpl__deref(blocked_transfer.value.wtf_string_impl);

    var dead_bun_string = BunString{ .tag = .dead, .value = .{ .zig_string = .{ .tagged_ptr = 0, .len = 0 } } };
    if (BunString__toJS(context, &dead_bun_string) != .empty or !JSGlobalObject__hasException(context))
        fail("dead BunString did not throw");
    JSGlobalObject__clearException(context);
    const invalid_array = [_]BunString{ latin1_string, dead_bun_string, utf8_string };
    if (BunString__createArray(context, &invalid_array, invalid_array.len) != .empty or !JSGlobalObject__hasException(context))
        fail("BunString array failure was not atomic");
    JSGlobalObject__clearException(context);

    const plain_error = ZigString__toErrorInstance(&latin1_string.value.zig_string, context);
    const zig_type_error = ZigString__toTypeErrorInstance(&utf8_string.value.zig_string, context);
    const type_error_second = ZigString__toTypeErrorInstance(&utf8_string.value.zig_string, context);
    const zig_range_error = ZigString__toRangeErrorInstance(&utf16_string.value.zig_string, context);
    const syntax_error = ZigString__toSyntaxErrorInstance(&empty_bun_string.value.zig_string, context);
    if (plain_error == .empty or zig_type_error == .empty or zig_range_error == .empty or syntax_error == .empty or
        !JSC__JSValue__isAnyError(plain_error) or !JSC__JSValue__isAnyError(zig_type_error) or
        JSC__JSValue__isStrictEqual(zig_type_error, type_error_second, context))
        fail("ZigString Error construction/freshness mismatch");
    exposeCell(context, "__private_plain_error", plain_error);
    exposeCell(context, "__private_type_error", zig_type_error);
    exposeCell(context, "__private_range_error", zig_range_error);
    exposeCell(context, "__private_syntax_error", syntax_error);
    if (!JSC__JSValue__toBoolean(evaluate(context, "__private_plain_error instanceof Error && Object.getPrototypeOf(__private_plain_error) === Error.prototype && __private_plain_error.name === 'Error' && __private_plain_error.message === 'café'")) or
        !JSC__JSValue__toBoolean(evaluate(context, "__private_type_error instanceof TypeError && Object.getPrototypeOf(__private_type_error) === TypeError.prototype && __private_type_error.name === 'TypeError' && __private_type_error.message === 'A😀Z'")) or
        !JSC__JSValue__toBoolean(evaluate(context, "__private_range_error instanceof RangeError && Object.getPrototypeOf(__private_range_error) === RangeError.prototype && __private_range_error.name === 'RangeError' && __private_range_error.message === 'A😀\\uD800Z'")) or
        !JSC__JSValue__toBoolean(evaluate(context, "__private_syntax_error instanceof SyntaxError && Object.getPrototypeOf(__private_syntax_error) === SyntaxError.prototype && __private_syntax_error.name === 'SyntaxError' && __private_syntax_error.message === ''")))
        fail("ZigString Error metadata/prototype mismatch");
    JSC__VM__throwError(JSC__JSGlobalObject__vm(context), context, EncodedValue.fromInt32(197));
    if (ZigString__toErrorInstance(&latin1_string.value.zig_string, context) != .empty)
        fail("ZigString Error ignored pending exception");
    const preserved_zig_string_error_exception = JSGlobalObject__tryTakeException(context);
    if (JSC__Exception__asJSValue(preserved_zig_string_error_exception.cellPointer()) != EncodedValue.fromInt32(197))
        fail("ZigString Error replaced pending exception");

    const empty_zig_string = ZigString{ .tagged_ptr = 0, .len = 0 };
    const type_code_bytes = "ERR_TYPE_FACTORY";
    const type_code_string = ZigString{ .tagged_ptr = @intFromPtr(type_code_bytes.ptr), .len = type_code_bytes.len };
    const range_code_units = [_]u16{ 'E', 'R', 'R', '_', 0xd83d, 0xde00, 0xd800 };
    const range_code_string = ZigString{ .tagged_ptr = @intFromPtr(&range_code_units) | (@as(usize, 1) << 63), .len = range_code_units.len };
    const coded_type_error = JSC__JSValue__createTypeError(&utf16_string.value.zig_string, &type_code_string, context);
    const coded_type_error_second = JSC__JSValue__createTypeError(&utf16_string.value.zig_string, &type_code_string, context);
    const coded_range_error = JSC__JSValue__createRangeError(&utf8_string.value.zig_string, &range_code_string, context);
    const uncoded_type_error = JSC__JSValue__createTypeError(&latin1_string.value.zig_string, &empty_zig_string, context);
    exposeCell(context, "__private_coded_type_error", coded_type_error);
    exposeCell(context, "__private_coded_range_error", coded_range_error);
    exposeCell(context, "__private_uncoded_type_error", uncoded_type_error);
    if (coded_type_error == .empty or coded_range_error == .empty or uncoded_type_error == .empty or
        JSC__JSValue__isStrictEqual(coded_type_error, coded_type_error_second, context) or
        !JSC__JSValue__toBoolean(evaluate(context, "__private_coded_type_error instanceof TypeError && Object.getPrototypeOf(__private_coded_type_error) === TypeError.prototype && __private_coded_type_error.message === 'A😀\\uD800Z' && __private_coded_type_error.code === 'ERR_TYPE_FACTORY'")) or
        !JSC__JSValue__toBoolean(evaluate(context, "__private_coded_range_error instanceof RangeError && Object.getPrototypeOf(__private_coded_range_error) === RangeError.prototype && __private_coded_range_error.message === 'A😀Z' && __private_coded_range_error.code === 'ERR_😀\\uD800'")) or
        !JSC__JSValue__toBoolean(evaluate(context, "!Object.hasOwn(__private_uncoded_type_error, 'code')")))
        fail("private ZigString coded error factory mismatch");
    if (!JSC__JSValue__toBoolean(evaluate(context,
        \\(() => {
        \\  const type = Object.getOwnPropertyDescriptor(__private_coded_type_error, 'code');
        \\  const range = Object.getOwnPropertyDescriptor(__private_coded_range_error, 'code');
        \\  return type.writable && type.enumerable && type.configurable &&
        \\    !range.writable && range.enumerable && range.configurable;
        \\})()
    ))) fail("private coded error descriptor mismatch");

    const bun_empty_error = JSC__createError(context, &empty_bun_string);
    const bun_wtf_error = JSC__createError(context, &huge_string);
    const bun_latin1_type_error = JSC__createTypeError(context, &latin1_string);
    const bun_utf8_type_error = JSC__createTypeError(context, &utf8_string);
    const bun_utf16_range_error = JSC__createRangeError(context, &utf16_string);
    exposeCell(context, "__private_bun_empty_error", bun_empty_error);
    exposeCell(context, "__private_bun_wtf_error", bun_wtf_error);
    exposeCell(context, "__private_bun_latin1_type_error", bun_latin1_type_error);
    exposeCell(context, "__private_bun_utf8_type_error", bun_utf8_type_error);
    exposeCell(context, "__private_bun_utf16_range_error", bun_utf16_range_error);
    if (!JSC__JSValue__toBoolean(evaluate(context, "__private_bun_empty_error instanceof Error && __private_bun_empty_error.message === ''")) or
        !JSC__JSValue__toBoolean(evaluate(context, "__private_bun_wtf_error instanceof Error && __private_bun_wtf_error.message === '184467440737095516160000000000000000000'")) or
        !JSC__JSValue__toBoolean(evaluate(context, "__private_bun_latin1_type_error instanceof TypeError && __private_bun_latin1_type_error.message === 'café'")) or
        !JSC__JSValue__toBoolean(evaluate(context, "__private_bun_utf8_type_error instanceof TypeError && __private_bun_utf8_type_error.message === 'A😀Z'")) or
        !JSC__JSValue__toBoolean(evaluate(context, "__private_bun_utf16_range_error instanceof RangeError && __private_bun_utf16_range_error.message === 'A😀\\uD800Z'")))
        fail("private BunString error factory mismatch");
    if (JSC__createError(context, &dead_bun_string) != .empty or !JSGlobalObject__hasException(context))
        fail("private BunString error factory accepted dead input");
    JSGlobalObject__clearException(context);
    JSC__VM__throwError(JSC__JSGlobalObject__vm(context), context, EncodedValue.fromInt32(201));
    if (JSC__JSValue__createTypeError(&latin1_string.value.zig_string, &type_code_string, context) != .empty or
        JSC__createRangeError(context, &latin1_string) != .empty)
        fail("private error factory ignored pending exception");
    const preserved_error_factory_exception = JSGlobalObject__tryTakeException(context);
    if (JSC__Exception__asJSValue(preserved_error_factory_exception.cellPointer()) != EncodedValue.fromInt32(201))
        fail("private error factory replaced pending exception");

    exposeCell(context, "__private_aggregate_identity", encoded_object);
    const aggregate_items = [_]EncodedValue{ EncodedValue.fromInt32(7), encoded_object, evaluate(context, "'tail'") };
    const slice_aggregate = JSC__JSGlobalObject__createAggregateError(
        context,
        &aggregate_items,
        aggregate_items.len,
        &utf16_string.value.zig_string,
    );
    const empty_slice_aggregate = JSC__JSGlobalObject__createAggregateError(context, null, 0, &empty_zig_string);
    exposeCell(context, "__private_slice_aggregate", slice_aggregate);
    exposeCell(context, "__private_empty_slice_aggregate", empty_slice_aggregate);
    const slice_errors = JSC__JSValue__getErrorsProperty(slice_aggregate, context);
    if (!JSC__JSValue__isAggregateError(slice_aggregate, context) or
        !JSC__JSValue__isStrictEqual(slice_errors, getProperty(context, slice_aggregate, "errors"), context) or
        !JSC__JSValue__toBoolean(evaluate(context, "__private_slice_aggregate instanceof AggregateError && Object.getPrototypeOf(__private_slice_aggregate) === AggregateError.prototype && __private_slice_aggregate.message === 'A😀\\uD800Z' && __private_slice_aggregate.errors.length === 3 && __private_slice_aggregate.errors[0] === 7 && __private_slice_aggregate.errors[1] === __private_aggregate_identity && __private_slice_aggregate.errors[2] === 'tail' && !Object.hasOwn(__private_slice_aggregate, 'cause')")) or
        !JSC__JSValue__toBoolean(evaluate(context, "__private_empty_slice_aggregate.errors.length === 0 && __private_empty_slice_aggregate.message === ''")))
        fail("private AggregateError slice construction mismatch");

    const existing_errors = evaluate(context, "globalThis.__private_existing_errors = [1, { exact: true }]; __private_existing_errors");
    const with_array_aggregate = JSC__JSGlobalObject__createAggregateErrorWithArray(context, existing_errors, latin1_string, encoded_object);
    const without_cause_aggregate = JSC__JSGlobalObject__createAggregateErrorWithArray(context, existing_errors, empty_bun_string, .undefined);
    exposeCell(context, "__private_with_array_aggregate", with_array_aggregate);
    exposeCell(context, "__private_without_cause_aggregate", without_cause_aggregate);
    if (!JSC__JSValue__isStrictEqual(JSC__JSValue__getErrorsProperty(with_array_aggregate, context), existing_errors, context) or
        !JSC__JSValue__isStrictEqual(getProperty(context, with_array_aggregate, "cause"), encoded_object, context) or
        !JSC__JSValue__toBoolean(evaluate(context, "__private_with_array_aggregate.errors === __private_existing_errors && __private_with_array_aggregate.message === 'café' && __private_with_array_aggregate.cause === __private_aggregate_identity && !Object.hasOwn(__private_without_cause_aggregate, 'cause')")))
        fail("private AggregateError existing-array/cause identity mismatch");
    if (!JSC__JSValue__toBoolean(evaluate(context,
        \\(() => {
        \\  for (const key of ['errors', 'message', 'cause']) {
        \\    const descriptor = Object.getOwnPropertyDescriptor(__private_with_array_aggregate, key);
        \\    if (!descriptor.writable || descriptor.enumerable || !descriptor.configurable) return false;
        \\  }
        \\  return true;
        \\})()
    ))) fail("private AggregateError descriptor mismatch");

    _ = evaluate(context, "Object.defineProperty(Object.prototype, 'errors', { get() { throw 2021; }, configurable: true })");
    if (JSC__JSValue__getErrorsProperty(encoded_object, context) != .undefined or JSGlobalObject__hasException(context))
        fail("private AggregateError errors read consulted prototype");
    _ = evaluate(context, "delete Object.prototype.errors");
    if (JSC__JSGlobalObject__createAggregateErrorWithArray(context, encoded_object, latin1_string, .undefined) != .empty or
        !JSGlobalObject__hasException(context))
        fail("private AggregateError accepted non-array errors");
    JSGlobalObject__clearException(context);
    const foreign_aggregate_items = [_]EncodedValue{EncodedValue.fromRef(foreign_object)};
    if (JSC__JSGlobalObject__createAggregateError(context, &foreign_aggregate_items, 1, &empty_zig_string) != .empty or
        !JSGlobalObject__hasException(context))
        fail("private AggregateError accepted foreign error value");
    JSGlobalObject__clearException(context);
    JSC__VM__throwError(JSC__JSGlobalObject__vm(context), context, EncodedValue.fromInt32(202));
    if (JSC__JSGlobalObject__createAggregateError(context, &aggregate_items, aggregate_items.len, &empty_zig_string) != .empty or
        JSC__JSValue__getErrorsProperty(slice_aggregate, context) != .empty)
        fail("private AggregateError ignored pending exception");
    const preserved_aggregate_exception = JSGlobalObject__tryTakeException(context);
    if (JSC__Exception__asJSValue(preserved_aggregate_exception.cellPointer()) != EncodedValue.fromInt32(202))
        fail("private AggregateError replaced pending exception");

    const dom_names = [_][]const u8{
        "IndexSizeError",             "HierarchyRequestError", "WrongDocumentError",       "InvalidCharacterError",
        "NoModificationAllowedError", "NotFoundError",         "NotSupportedError",        "InUseAttributeError",
        "InvalidStateError",          "SyntaxError",           "InvalidModificationError", "NamespaceError",
        "InvalidAccessError",         "TypeMismatchError",     "SecurityError",            "NetworkError",
        "AbortError",                 "URLMismatchError",      "QuotaExceededError",       "TimeoutError",
        "InvalidNodeTypeError",       "DataCloneError",        "EncodingError",            "NotReadableError",
        "UnknownError",               "ConstraintError",       "DataError",                "TransactionInactiveError",
        "ReadOnlyError",              "VersionError",          "OperationError",           "NotAllowedError",
    };
    const dom_messages = [_][]const u8{
        "The index is not in the allowed range.",
        "The operation would yield an incorrect node tree.",
        "The object is in the wrong document.",
        "The string contains invalid characters.",
        "The object can not be modified.",
        "The object can not be found here.",
        "The operation is not supported.",
        "The attribute is in use.",
        "The object is in an invalid state.",
        "",
        " The object can not be modified in this way.",
        "The operation is not allowed by Namespaces in XML.",
        "The object does not support the operation or argument.",
        "The type of an object was incompatible with the expected type of the parameter associated to the object.",
        "The operation is insecure.",
        " A network error occurred.",
        "The operation was aborted.",
        "The given URL does not match another URL.",
        "The quota has been exceeded.",
        "The operation timed out.",
        "The supplied node is incorrect or has an incorrect ancestor for this operation.",
        "The object can not be cloned.",
        "The encoding operation (either encoded or decoding) failed.",
        "The I/O read operation failed.",
        "The operation failed for an unknown transient reason (e.g. out of memory).",
        "A mutation operation in a transaction failed because a constraint was not satisfied.",
        "Provided data is inadequate.",
        "A request was placed against a transaction which is currently not active, or which is finished.",
        "The mutating operation was attempted in a \"readonly\" transaction.",
        "An attempt was made to open a database using a lower version than the existing version.",
        "The operation failed for an operation-specific reason.",
        "The request is not allowed by the user agent or the platform in the current context, possibly because the user denied permission.",
    };
    const dom_legacy_codes = [_]i32{ 1, 3, 4, 5, 7, 8, 9, 10, 11, 0, 13, 14, 15, 17, 18, 19, 20, 21, 22, 23, 24, 25, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 };
    for (dom_names, dom_messages, dom_legacy_codes, 0..) |name, message, legacy_code, code| {
        const instance = ZigString__toDOMExceptionInstance(&empty_zig_string, context, @intCast(code));
        if (instance == .empty or
            !JSC__JSValue__isStrictEqual(getProperty(context, instance, "name"), encodedLatin1(context, name), context) or
            !JSC__JSValue__isStrictEqual(getProperty(context, instance, "message"), encodedLatin1(context, message), context))
            fail("DOMException description matrix mismatch");
        if (code == 9) {
            if (!JSC__JSValue__isInstanceOf(instance, context, evaluate(context, "SyntaxError")))
                fail("Bun DOM SyntaxError divergence mismatch");
        } else {
            const is_dom = JSC__JSValue__isInstanceOf(instance, context, evaluate(context, "DOMException"));
            const actual_code: i32 = @intFromFloat(Bun__JSValue__toNumber(getProperty(context, instance, "code"), context));
            if (!is_dom or actual_code != legacy_code) {
                std.debug.print("DOMException row {d}: isDOM={} code={d} expected={d}\n", .{ code, is_dom, actual_code, legacy_code });
                fail("DOMException legacy code/class mismatch");
            }
        }
    }

    const special_names = [_][]const u8{ "RangeError", "TypeError", "SyntaxError", "RangeError", "Error", "undefined", "TypeError", "TypeError", "Error" };
    const special_messages = [_][]const u8{ "Bad value", "", "", "Maximum call stack size exceeded", "Out of memory", "", "Expected this to be of a different type", "Invalid URL", "Crypto operation failed" };
    const special_node_codes = [_][]const u8{ "", "", "", "", "", "", "ERR_INVALID_THIS", "ERR_INVALID_URL", "ERR_CRYPTO_OPERATION_FAILED" };
    for (special_names, special_messages, special_node_codes, 32..) |name, message, node_code, code| {
        const instance = ZigString__toDOMExceptionInstance(&empty_zig_string, context, @intCast(code));
        if (code == 37) {
            if (instance != .undefined) fail("ExistingExceptionError did not return undefined");
            continue;
        }
        if (instance == .empty or
            !JSC__JSValue__isStrictEqual(getProperty(context, instance, "name"), encodedLatin1(context, name), context) or
            !JSC__JSValue__isStrictEqual(getProperty(context, instance, "message"), encodedLatin1(context, message), context) or
            !JSC__JSValue__isInstanceOf(instance, context, evaluate(context, @ptrCast(name.ptr))))
            fail("DOMException special error matrix mismatch");
        if (node_code.len > 0 and !JSC__JSValue__isStrictEqual(getProperty(context, instance, "code"), encodedLatin1(context, node_code), context))
            fail("DOMException special Node code mismatch");
    }

    const override_dom = ZigString__toDOMExceptionInstance(&utf16_string.value.zig_string, context, 16);
    const unknown_dom = ZigString__toDOMExceptionInstance(&latin1_string.value.zig_string, context, 255);
    const override_ok = JSC__JSValue__isStrictEqual(getProperty(context, override_dom, "message"), evaluate(context, "'A😀\\uD800Z'"), context);
    const unknown_name_ok = JSC__JSValue__isStrictEqual(getProperty(context, unknown_dom, "name"), evaluate(context, "''"), context);
    const unknown_message_ok = JSC__JSValue__isStrictEqual(getProperty(context, unknown_dom, "message"), evaluate(context, "'café'"), context);
    if (!override_ok or !unknown_name_ok or !unknown_message_ok) {
        std.debug.print("DOMException override={} unknownName={} unknownMessage={}\n", .{ override_ok, unknown_name_ok, unknown_message_ok });
        fail("DOMException override/unknown-code disposition mismatch");
    }
    JSC__VM__throwError(JSC__JSGlobalObject__vm(context), context, EncodedValue.fromInt32(198));
    if (ZigString__toDOMExceptionInstance(&empty_zig_string, context, 16) != .empty)
        fail("DOMException matrix ignored pending exception");
    const preserved_dom_exception = JSGlobalObject__tryTakeException(context);
    if (JSC__Exception__asJSValue(preserved_dom_exception.cellPointer()) != EncodedValue.fromInt32(198))
        fail("DOMException matrix replaced pending exception");

    var mutable_latin1 = [_]u8{ 'c', 'a', 'f', 0xe9 };
    const mutable_latin1_string = ZigString{ .tagged_ptr = @intFromPtr(&mutable_latin1), .len = mutable_latin1.len };
    const copied_latin1 = ZigString__toValueGC(&mutable_latin1_string, context);
    mutable_latin1[0] = 'X';
    if (!JSC__JSValue__isStrictEqual(copied_latin1, evaluate(context, "'café'"), context) or
        !JSC__JSValue__isStrictEqual(ZigString__toValueGC(&utf8_string.value.zig_string, context), evaluate(context, "'A😀Z'"), context) or
        !JSC__JSValue__isStrictEqual(ZigString__toValueGC(&utf16_string.value.zig_string, context), evaluate(context, "'A😀\\uD800Z'"), context) or
        !JSC__JSValue__isStrictEqual(ZigString__toValueGC(&empty_zig_string, context), evaluate(context, "''"), context))
        fail("ZigString copied value construction mismatch");

    const raw_utf8_string = ZigString{ .tagged_ptr = @intFromPtr(utf8_bytes.ptr), .len = utf8_bytes.len };
    if (!JSC__JSValue__isStrictEqual(ZigString__to16BitValue(&raw_utf8_string, context), evaluate(context, "'A😀Z'"), context) or
        !JSC__JSValue__isStrictEqual(ZigString__to16BitValue(&empty_zig_string, context), evaluate(context, "''"), context))
        fail("ZigString UTF-8-to-16-bit value mismatch");
    const invalid_utf8_bytes = [_]u8{ 0xc0, 0x80 };
    const invalid_utf8_string = ZigString{ .tagged_ptr = @intFromPtr(&invalid_utf8_bytes), .len = invalid_utf8_bytes.len };
    if (ZigString__to16BitValue(&invalid_utf8_string, context) != .empty or !JSGlobalObject__hasException(context))
        fail("ZigString 16-bit conversion accepted invalid UTF-8");
    JSGlobalObject__clearException(context);

    var mutable_atom = [_]u8{ 'a', 't', 'o', 'm' };
    const mutable_atom_string = ZigString{ .tagged_ptr = @intFromPtr(&mutable_atom), .len = mutable_atom.len };
    const atomic_first = ZigString__toAtomicValue(&mutable_atom_string, context);
    const atomic_second = ZigString__toAtomicValue(&mutable_atom_string, context);
    mutable_atom[0] = 'X';
    if (!JSC__JSString__eql(
        JSC__JSValue__asString(atomic_first),
        context,
        JSC__JSValue__asString(atomic_second),
    ) or !JSC__JSValue__isStrictEqual(atomic_first, evaluate(context, "'atom'"), context))
        fail("ZigString atomic value canonicalization/copy mismatch");

    const rope_left_units = [_]u16{ 'A', 0xd83d };
    const rope_right_units = [_]u16{ 0xde00, 'Z' };
    const rope_left_string = ZigString{ .tagged_ptr = @intFromPtr(&rope_left_units) | (@as(usize, 1) << 63), .len = rope_left_units.len };
    const rope_right_string = ZigString{ .tagged_ptr = @intFromPtr(&rope_right_units) | (@as(usize, 1) << 63), .len = rope_right_units.len };
    exposeCell(context, "__private_rope_left_value", ZigString__toValueGC(&rope_left_string, context));
    exposeCell(context, "__private_rope_right_value", ZigString__toValueGC(&rope_right_string, context));
    const rope_left = evaluate(context,
        \\globalThis.__private_rope_log = [];
        \\({ toString() { __private_rope_log.push('left'); return __private_rope_left_value; } });
    );
    const rope_right = evaluate(context,
        \\({ toString() { __private_rope_log.push('right'); return __private_rope_right_value; } });
    );
    const rope = JSC__JSValue__createRopeString(rope_left, rope_right, context);
    if (!JSC__JSValue__isStrictEqual(rope, evaluate(context, "'A😀Z'"), context) or
        !JSC__JSValue__isStrictEqual(evaluate(context, "__private_rope_log.join(',')"), evaluate(context, "'left,right'"), context))
        fail("private rope string coercion/order mismatch");

    const throwing_rope_left = evaluate(context,
        \\globalThis.__private_rope_right_called = false;
        \\({ toString() { throw 1991; } });
    );
    const uncalled_rope_right = evaluate(context,
        \\({ toString() { __private_rope_right_called = true; return 'bad'; } });
    );
    if (JSC__JSValue__createRopeString(throwing_rope_left, uncalled_rope_right, context) != .empty or
        !JSGlobalObject__hasException(context))
        fail("private rope string did not publish left coercion failure");
    const rope_throw = JSGlobalObject__tryTakeException(context);
    if (JSC__Exception__asJSValue(rope_throw.cellPointer()) != EncodedValue.fromInt32(1991) or
        JSC__JSValue__toBoolean(evaluate(context, "__private_rope_right_called")))
        fail("private rope string evaluated right after left failure");

    if (JSC__JSValue__createRopeString(evaluate(context, "'local'"), EncodedValue.fromRef(foreign_object), context) != .empty or
        !JSGlobalObject__hasException(context))
        fail("private rope string accepted foreign-VM input");
    const foreign_rope_exception = JSGlobalObject__tryTakeException(context);
    const foreign_rope_error = JSC__Exception__asJSValue(foreign_rope_exception.cellPointer());
    if (!JSC__JSValue__isStrictEqual(getProperty(context, foreign_rope_error, "name"), evaluate(context, "'TypeError'"), context))
        fail("private rope string foreign-VM error mismatch");

    JSC__VM__throwError(JSC__JSGlobalObject__vm(context), context, EncodedValue.fromInt32(199));
    if (ZigString__toValueGC(&latin1_string.value.zig_string, context) != .empty or
        ZigString__toAtomicValue(&latin1_string.value.zig_string, context) != .empty or
        JSC__JSValue__createRopeString(.true, .false, context) != .empty)
        fail("private string construction ignored pending exception");
    const preserved_string_construction_exception = JSGlobalObject__tryTakeException(context);
    if (JSC__Exception__asJSValue(preserved_string_construction_exception.cellPointer()) != EncodedValue.fromInt32(199))
        fail("private string construction replaced pending exception");

    const view_values = [_]EncodedValue{
        evaluate(context, "''"),
        evaluate(context, "'ASCII'"),
        evaluate(context, "'café'"),
        evaluate(context, "'€'"),
        evaluate(context, "'😀'"),
        evaluate(context, "'\\uD800'"),
    };
    const empty_units = [_]u16{};
    const ascii_units = [_]u16{ 'A', 'S', 'C', 'I', 'I' };
    const latin1_units = [_]u16{ 'c', 'a', 'f', 0xe9 };
    const bmp_units = [_]u16{0x20ac};
    const astral_units = [_]u16{ 0xd83d, 0xde00 };
    const surrogate_units = [_]u16{0xd800};
    const expected_view_units = [_][]const u16{ &empty_units, &ascii_units, &latin1_units, &bmp_units, &astral_units, &surrogate_units };
    const expected_view_tags = [_]bool{ false, false, false, true, true, true };
    var borrowed_views: [view_values.len]ZigString = undefined;
    for (view_values, expected_view_units, expected_view_tags, &borrowed_views) |encoded, expected, expected_utf16, *out| {
        const cell = JSC__JSValue__asString(encoded) orelse fail("borrowed ZigString test downcast failed");
        JSC__JSString__toZigString(cell, context, out);
        expectZigStringUnits(out.*, expected, expected_utf16, "borrowed JSString ZigString view mismatch");
    }
    _ = evaluate(context, "Array.from({ length: 128 }, (_, i) => 'allocation-' + i).join('|')");
    var repeated_latin1_view: ZigString = undefined;
    JSC__JSString__toZigString(
        JSC__JSValue__asString(evaluate(context, "'café'")),
        context,
        &repeated_latin1_view,
    );
    if (repeated_latin1_view.tagged_ptr != borrowed_views[2].tagged_ptr)
        fail("borrowed ZigString view was not stable across allocations");
    expectZigStringUnits(borrowed_views[2], &latin1_units, false, "borrowed ZigString storage changed after allocation");

    const primitive_view_values = [_]EncodedValue{ .undefined, .null, .true, EncodedValue.fromInt32(-42), EncodedValue.fromDouble(1.5) };
    const primitive_view_units = [_][]const u16{
        &[_]u16{ 'u', 'n', 'd', 'e', 'f', 'i', 'n', 'e', 'd' },
        &[_]u16{ 'n', 'u', 'l', 'l' },
        &[_]u16{ 't', 'r', 'u', 'e' },
        &[_]u16{ '-', '4', '2' },
        &[_]u16{ '1', '.', '5' },
    };
    for (primitive_view_values, primitive_view_units) |encoded, expected| {
        var out: ZigString = undefined;
        JSC__JSValue__toZigString(encoded, &out, context);
        expectZigStringUnits(out, expected, false, "borrowed JSValue primitive conversion mismatch");
    }

    const coercible_view = evaluate(context,
        \\globalThis.__private_view_order = [];
        \\({ toString() { __private_view_order.push('toString'); return 'object-view'; }, valueOf() { __private_view_order.push('valueOf'); return 1; } });
    );
    var coercible_output: ZigString = undefined;
    JSC__JSValue__toZigString(coercible_view, &coercible_output, context);
    expectZigStringUnits(coercible_output, &[_]u16{ 'o', 'b', 'j', 'e', 'c', 't', '-', 'v', 'i', 'e', 'w' }, false, "borrowed JSValue object conversion mismatch");
    if (!JSC__JSValue__isStrictEqual(evaluate(context, "__private_view_order.join(',')"), evaluate(context, "'toString'"), context))
        fail("borrowed JSValue ToString order mismatch");

    var failed_view = ZigString{ .tagged_ptr = 1, .len = 1 };
    JSC__JSValue__toZigString(evaluate(context, "Symbol('view')"), &failed_view, context);
    if (failed_view.tagged_ptr != 0 or failed_view.len != 0 or !JSGlobalObject__hasException(context))
        fail("borrowed JSValue Symbol conversion mismatch");
    JSGlobalObject__clearException(context);
    JSC__JSValue__toZigString(evaluate(context, "({ toString() { throw 2001; } })"), &failed_view, context);
    const thrown_view_exception = JSGlobalObject__tryTakeException(context);
    if (failed_view.tagged_ptr != 0 or failed_view.len != 0 or
        JSC__Exception__asJSValue(thrown_view_exception.cellPointer()) != EncodedValue.fromInt32(2001))
        fail("borrowed JSValue thrown conversion mismatch");

    failed_view = .{ .tagged_ptr = 1, .len = 1 };
    JSC__JSString__toZigString(encoded_object.cellPointer(), context, &failed_view);
    if (failed_view.tagged_ptr != 0 or failed_view.len != 0)
        fail("borrowed JSString accepted non-string cell");
    JSC__JSValue__toZigString(EncodedValue.fromRef(foreign_object), &failed_view, context);
    if (failed_view.tagged_ptr != 0 or failed_view.len != 0 or !JSGlobalObject__hasException(context))
        fail("borrowed JSValue accepted foreign-VM value");
    JSGlobalObject__clearException(context);

    JSC__VM__throwError(JSC__JSGlobalObject__vm(context), context, EncodedValue.fromInt32(200));
    JSC__JSValue__toZigString(.true, &failed_view, context);
    const preserved_view_exception = JSGlobalObject__tryTakeException(context);
    if (failed_view.tagged_ptr != 0 or failed_view.len != 0 or
        JSC__Exception__asJSValue(preserved_view_exception.cellPointer()) != EncodedValue.fromInt32(200))
        fail("borrowed ZigString view replaced pending exception");

    Bun__WTFStringImpl__ref(signed_min_impl);
    if (@atomicLoad(u32, &signed_min_impl.ref_count, .acquire) != 4)
        fail("BunString retain mismatch");
    Bun__WTFStringImpl__deref(signed_min_impl);
    if (@atomicLoad(u32, &signed_min_impl.ref_count, .acquire) != 2)
        fail("BunString release mismatch");
    Bun__WTFStringImpl__deref(signed_min_impl);
    Bun__WTFStringImpl__deref(huge_impl);
    Bun__WTFStringImpl__deref(huge_second_impl);

    JSC__VM__throwError(JSC__JSGlobalObject__vm(context), context, EncodedValue.fromInt32(195));
    const blocked_bigint_string = JSC__JSBigInt__toString(signed_negative_cell, context);
    const preserved_bigint_string_exception = JSGlobalObject__tryTakeException(context);
    if (blocked_bigint_string.tag != .dead or
        JSC__Exception__asJSValue(preserved_bigint_string_exception.cellPointer()) != EncodedValue.fromInt32(195))
        fail("BigInt string replaced a pending exception");

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

    const parsed_epoch = JSC__JSValue__dateInstanceFromNullTerminatedString(context, "1970-01-01T00:00:00.000Z");
    const parsed_offset = JSC__JSValue__dateInstanceFromNullTerminatedString(context, "2020-02-29T12:34:56.789+02:30");
    const parsed_pre_epoch = JSC__JSValue__dateInstanceFromNullTerminatedString(context, "1969-12-31T23:59:59.999Z");
    const parsed_extended = JSC__JSValue__dateInstanceFromNullTerminatedString(context, "+010000-01-01T00:00:00.000Z");
    const parsed_invalid = JSC__JSValue__dateInstanceFromNullTerminatedString(context, "not a date");
    if (JSC__JSValue__getUTCTimestamp(context, parsed_epoch) != 0 or
        JSC__JSValue__getUTCTimestamp(context, parsed_pre_epoch) != -1 or
        !std.math.isNan(JSC__JSValue__getUTCTimestamp(context, parsed_invalid)) or
        !std.math.isNan(JSC__JSValue__getUTCTimestamp(context, encoded_object)) or
        !std.math.isNan(JSC__JSValue__getUTCTimestamp(foreign_context, parsed_epoch)))
        fail("private parsed Date UTC extraction mismatch");

    var iso_buffer: [28]u8 = @splat(0xa5);
    if (JSC__JSValue__toISOString(context, parsed_epoch, &iso_buffer) != 24 or
        !std.mem.eql(u8, iso_buffer[0..24], "1970-01-01T00:00:00.000Z") or
        !std.mem.allEqual(u8, iso_buffer[24..], 0xa5))
        fail("private epoch ISO formatting mismatch");
    iso_buffer = @splat(0xa5);
    if (JSC__JSValue__toISOString(context, fractional_date, &iso_buffer) != 24 or
        !std.mem.eql(u8, iso_buffer[0..24], "1970-01-01T00:00:00.001Z") or
        JSC__JSValue__toISOString(context, parsed_pre_epoch, &iso_buffer) != 24 or
        !std.mem.eql(u8, iso_buffer[0..24], "1969-12-31T23:59:59.999Z"))
        fail("private fractional/pre-epoch ISO formatting mismatch");
    iso_buffer = @splat(0xa5);
    if (JSC__JSValue__toISOString(context, parsed_offset, &iso_buffer) != 24 or
        !std.mem.eql(u8, iso_buffer[0..24], "2020-02-29T10:04:56.789Z"))
        fail("private offset ISO formatting mismatch");
    iso_buffer = @splat(0xa5);
    if (JSC__JSValue__toISOString(context, parsed_extended, &iso_buffer) != 27 or
        !std.mem.eql(u8, iso_buffer[0..27], "+010000-01-01T00:00:00.000Z"))
        fail("private extended-year ISO formatting mismatch");
    iso_buffer = @splat(0xa5);
    if (JSC__JSValue__toISOString(context, parsed_invalid, &iso_buffer) != -1 or
        !std.mem.allEqual(u8, &iso_buffer, 0xa5) or
        JSC__JSValue__toISOString(context, encoded_object, &iso_buffer) != -1 or
        !std.mem.allEqual(u8, &iso_buffer, 0xa5))
        fail("private ISO failure atomicity mismatch");

    const sibling_context = JSGlobalContextCreateInGroup(JSContextGetGroup(context), null) orelse fail("sibling context creation failed");
    defer JSGlobalContextRelease(sibling_context);
    const vm = JSC__JSGlobalObject__vm(context) orelse fail("private VM lookup failed");
    const sibling_vm = JSC__JSGlobalObject__vm(sibling_context) orelse fail("sibling VM lookup failed");
    const foreign_vm = JSC__JSGlobalObject__vm(foreign_context) orelse fail("foreign VM lookup failed");
    if (JSC__VM__isEntered(null) or JSC__VM__isEntered(vm) or JSC__VM__isEntered(sibling_vm) or JSC__VM__isEntered(foreign_vm))
        fail("private idle VM entry state mismatch");

    const sibling_bun_string_array = BunString__createArray(sibling_context, &bun_strings, bun_strings.len);
    exposeCell(sibling_context, "__private_sibling_bun_string_array", sibling_bun_string_array);
    if (!JSC__JSValue__isStrictEqual(BunString__toJS(sibling_context, &latin1_string), evaluate(sibling_context, "'café'"), sibling_context) or
        !JSC__JSValue__toBoolean(evaluate(sibling_context, "Object.getPrototypeOf(__private_sibling_bun_string_array) === Array.prototype")))
        fail("BunString selected-realm conversion mismatch");

    const sibling_type_error = ZigString__toTypeErrorInstance(&latin1_string.value.zig_string, sibling_context);
    exposeCell(sibling_context, "__private_sibling_type_error", sibling_type_error);
    if (!JSC__JSValue__toBoolean(evaluate(sibling_context, "Object.getPrototypeOf(__private_sibling_type_error) === TypeError.prototype && __private_sibling_type_error.message === 'café'")))
        fail("ZigString Error selected-realm prototype mismatch");

    const sibling_coded_error = JSC__JSValue__createTypeError(&latin1_string.value.zig_string, &type_code_string, sibling_context);
    const sibling_bun_range_error = JSC__createRangeError(sibling_context, &utf16_string);
    exposeCell(sibling_context, "__private_sibling_coded_error", sibling_coded_error);
    exposeCell(sibling_context, "__private_sibling_bun_range_error", sibling_bun_range_error);
    if (!JSC__JSValue__toBoolean(evaluate(sibling_context, "Object.getPrototypeOf(__private_sibling_coded_error) === TypeError.prototype && __private_sibling_coded_error.code === 'ERR_TYPE_FACTORY'")) or
        !JSC__JSValue__toBoolean(evaluate(sibling_context, "Object.getPrototypeOf(__private_sibling_bun_range_error) === RangeError.prototype && __private_sibling_bun_range_error.message === 'A😀\\uD800Z'")))
        fail("private error factory selected-realm mismatch");

    const sibling_aggregate_items = [_]EncodedValue{ encoded_object, evaluate(sibling_context, "'sibling-error'") };
    const sibling_aggregate = JSC__JSGlobalObject__createAggregateError(
        sibling_context,
        &sibling_aggregate_items,
        sibling_aggregate_items.len,
        &latin1_string.value.zig_string,
    );
    const sibling_existing_aggregate = JSC__JSGlobalObject__createAggregateErrorWithArray(
        sibling_context,
        existing_errors,
        utf8_string,
        encoded_object,
    );
    exposeCell(sibling_context, "__private_sibling_aggregate", sibling_aggregate);
    exposeCell(sibling_context, "__private_sibling_existing_aggregate", sibling_existing_aggregate);
    exposeCell(sibling_context, "__private_sibling_primary_identity", encoded_object);
    if (!JSC__JSValue__toBoolean(evaluate(sibling_context, "Object.getPrototypeOf(__private_sibling_aggregate) === AggregateError.prototype && Object.getPrototypeOf(__private_sibling_aggregate.errors) === Array.prototype && __private_sibling_aggregate.errors[0] === __private_sibling_primary_identity")) or
        !JSC__JSValue__isStrictEqual(JSC__JSValue__getErrorsProperty(sibling_existing_aggregate, sibling_context), existing_errors, sibling_context))
        fail("private AggregateError sibling realm/identity mismatch");

    const first_key_bytes = "first";
    const second_key_bytes = "second";
    const first_key = ZigString{ .tagged_ptr = @intFromPtr(first_key_bytes.ptr), .len = first_key_bytes.len };
    const second_key = ZigString{ .tagged_ptr = @intFromPtr(second_key_bytes.ptr), .len = second_key_bytes.len };
    const created_pair = JSC__JSValue__createObject2(
        sibling_context,
        &first_key,
        &second_key,
        encoded_object,
        EncodedValue.fromInt32(22),
    );
    const duplicate_pair = JSC__JSValue__createObject2(
        context,
        &first_key,
        &first_key,
        EncodedValue.fromInt32(11),
        EncodedValue.fromInt32(22),
    );
    exposeCell(sibling_context, "__private_created_pair", created_pair);
    exposeCell(sibling_context, "__private_created_pair_identity", encoded_object);
    exposeCell(context, "__private_duplicate_pair", duplicate_pair);
    if (!JSC__JSValue__toBoolean(evaluate(sibling_context,
        \\Object.getPrototypeOf(__private_created_pair) === Object.prototype &&
        \\Object.keys(__private_created_pair).join(',') === 'second,first' &&
        \\__private_created_pair.first === __private_created_pair_identity &&
        \\__private_created_pair.second === 22 &&
        \\['first', 'second'].every(key => {
        \\  const d = Object.getOwnPropertyDescriptor(__private_created_pair, key);
        \\  return d.writable && d.enumerable && d.configurable;
        \\})
    )) or !JSC__JSValue__toBoolean(evaluate(context, "Object.keys(__private_duplicate_pair).join(',') === 'first' && __private_duplicate_pair.first === 11")))
        fail("private createObject2 order/descriptor/realm mismatch");

    const entry_first_value_bytes = "entry-first";
    const entry_second_value_bytes = "entry-second";
    const entry_last_value_bytes = "entry-last";
    const entry_keys = [_]ZigString{ first_key, second_key, first_key };
    const entry_values = [_]ZigString{
        .{ .tagged_ptr = @intFromPtr(entry_first_value_bytes.ptr), .len = entry_first_value_bytes.len },
        .{ .tagged_ptr = @intFromPtr(entry_second_value_bytes.ptr), .len = entry_second_value_bytes.len },
        .{ .tagged_ptr = @intFromPtr(entry_last_value_bytes.ptr), .len = entry_last_value_bytes.len },
    };
    const from_entries = JSC__JSValue__fromEntries(sibling_context, &entry_keys, &entry_values, entry_keys.len, true);
    exposeCell(sibling_context, "__private_from_entries", from_entries);
    if (!JSC__JSValue__toBoolean(evaluate(
        sibling_context,
        "Object.getPrototypeOf(__private_from_entries) === Object.prototype && Object.keys(__private_from_entries).join(',') === 'first,second' && __private_from_entries.first === 'entry-last' && __private_from_entries.second === 'entry-second'",
    )))
        fail("private fromEntries realm/order/duplicate mismatch");

    const direct_target = evaluate(context,
        \\globalThis.__private_direct_setter_hits = 0;
        \\globalThis.__private_direct_target = Object.create({ set direct(value) { __private_direct_setter_hits++; } });
        \\__private_direct_target;
    );
    const direct_key_bytes = "direct";
    const direct_key = ZigString{ .tagged_ptr = @intFromPtr(direct_key_bytes.ptr), .len = direct_key_bytes.len };
    JSC__JSValue__put(direct_target, context, &direct_key, encoded_object);
    if (!JSC__JSValue__toBoolean(evaluate(context, "__private_direct_setter_hits === 0 && Object.hasOwn(__private_direct_target, 'direct') && __private_direct_target.direct === __private_aggregate_identity")))
        fail("private direct put invoked prototype setter or lost identity");
    const record_key_bytes = "record";
    const record_key = ZigString{ .tagged_ptr = @intFromPtr(record_key_bytes.ptr), .len = record_key_bytes.len };
    const record_values = [_]ZigString{ entry_values[0], entry_values[1] };
    JSC__JSValue__putRecord(direct_target, context, &record_key, &record_values, record_values.len);
    if (!JSC__JSValue__toBoolean(evaluate(
        context,
        "Array.isArray(__private_direct_target.record) && __private_direct_target.record.join(',') === 'entry-first,entry-second' && Object.keys(__private_direct_target).includes('record')",
    )))
        fail("private putRecord array/direct descriptor mismatch");

    const property_key_target = evaluate(context, "globalThis.__private_property_key_target = []; __private_property_key_target");
    const coercing_key = evaluate(context,
        \\globalThis.__private_property_key_hits = 0;
        \\globalThis.__private_coercing_key = { [Symbol.toPrimitive]() { __private_property_key_hits++; return 'coerced'; } };
        \\__private_coercing_key;
    );
    const symbol_key = evaluate(context, "globalThis.__private_property_symbol = Symbol('private-property'); __private_property_symbol");
    JSC__JSValue__putToPropertyKey(property_key_target, context, EncodedValue.fromInt32(2), EncodedValue.fromInt32(32));
    JSC__JSValue__putToPropertyKey(property_key_target, context, coercing_key, EncodedValue.fromInt32(33));
    JSC__JSValue__putToPropertyKey(property_key_target, context, symbol_key, encoded_object);
    if (!JSC__JSValue__toBoolean(evaluate(context, "__private_property_key_target.length === 3 && __private_property_key_target[2] === 32 && __private_property_key_target.coerced === 33 && __private_property_key_hits === 1 && __private_property_key_target[__private_property_symbol] === __private_aggregate_identity")))
        fail("private property-key put coercion/index/symbol mismatch");
    const throwing_property_key = evaluate(context, "({ [Symbol.toPrimitive]() { throw 2031; } })");
    JSC__JSValue__putToPropertyKey(property_key_target, context, throwing_property_key, .true);
    if (!JSGlobalObject__hasException(context) or JSC__JSValue__getPropertyValue(property_key_target, context, "true".ptr, 4) != .empty)
        fail("private property-key put did not publish coercion exception");
    const property_key_exception = JSGlobalObject__tryTakeException(context);
    if (JSC__Exception__asJSValue(property_key_exception.cellPointer()) != EncodedValue.fromInt32(2031))
        fail("private property-key put exception identity mismatch");

    const delete_target = evaluate(context,
        \\globalThis.__private_delete_target = {};
        \\Object.defineProperty(__private_delete_target, 'fixed', { value: 1, configurable: false });
        \\__private_delete_target.open = 2;
        \\__private_delete_target;
    );
    const open_key_bytes = "open";
    const fixed_key_bytes = "fixed";
    const open_key = ZigString{ .tagged_ptr = @intFromPtr(open_key_bytes.ptr), .len = open_key_bytes.len };
    const fixed_key = ZigString{ .tagged_ptr = @intFromPtr(fixed_key_bytes.ptr), .len = fixed_key_bytes.len };
    if (!JSC__JSValue__deleteProperty(delete_target, context, &open_key) or
        JSC__JSValue__deleteProperty(delete_target, context, &fixed_key) or
        JSC__JSValue__deleteProperty(.true, context, &open_key))
        fail("private ordinary delete configurability/non-object mismatch");
    const delete_proxy = evaluate(context,
        \\globalThis.__private_delete_traps = 0;
        \\globalThis.__private_delete_proxy = new Proxy({ open: 1 }, { deleteProperty(target, key) { __private_delete_traps++; return Reflect.deleteProperty(target, key); } });
        \\__private_delete_proxy;
    );
    if (!JSC__JSValue__deleteProperty(delete_proxy, context, &open_key) or
        !JSC__JSValue__toBoolean(evaluate(context, "__private_delete_traps === 1 && !Object.hasOwn(__private_delete_proxy, 'open')")))
        fail("private ordinary delete proxy mismatch");
    const throwing_delete_proxy = evaluate(context, "new Proxy({}, { deleteProperty() { throw 2032; } })");
    if (JSC__JSValue__deleteProperty(throwing_delete_proxy, context, &open_key) or !JSGlobalObject__hasException(context))
        fail("private ordinary delete swallowed proxy exception");
    JSGlobalObject__clearException(context);

    const property_read_target = evaluate(context,
        \\globalThis.__private_property_gets = 0;
        \\globalThis.__private_property_read_target = Object.create({ get inherited() { __private_property_gets++; return 41; } });
        \\Object.defineProperty(__private_property_read_target, 'presentUndefined', { value: undefined, configurable: true });
        \\__private_property_read_target[3] = 43;
        \\__private_property_read_target['café'] = 44;
        \\__private_property_read_target;
    );
    if (JSC__JSValue__getPropertyValue(property_read_target, context, "inherited".ptr, 9) != EncodedValue.fromInt32(41) or
        JSC__JSValue__getPropertyValue(property_read_target, context, "presentUndefined".ptr, 16) != .undefined or
        JSC__JSValue__getPropertyValue(property_read_target, context, "missing".ptr, 7) != .deleted or
        JSC__JSValue__getPropertyValue(property_read_target, context, "3".ptr, 1) != EncodedValue.fromInt32(43) or
        JSC__JSValue__getPropertyValue(property_read_target, context, latin1_bytes.ptr, @intCast(latin1_bytes.len)) != EncodedValue.fromInt32(44) or
        !JSC__JSValue__toBoolean(evaluate(context, "__private_property_gets === 1")))
        fail("private ordinary property read/sentinel/Latin-1 mismatch");
    const read_proxy = evaluate(context,
        \\globalThis.__private_read_gets = 0;
        \\globalThis.__private_read_has = 0;
        \\globalThis.__private_read_proxy = new Proxy({}, { get() { __private_read_gets++; return undefined; }, has() { __private_read_has++; return true; } });
        \\__private_read_proxy;
    );
    if (JSC__JSValue__getPropertyValue(read_proxy, context, "anything".ptr, 8) != .undefined or
        !JSC__JSValue__toBoolean(evaluate(context, "__private_read_gets === 1 && __private_read_has === 0")))
        fail("private ordinary property read added a has trap or lost present undefined");
    const throwing_read = evaluate(context, "Object.defineProperty({}, 'boom', { get() { throw 2033; } })");
    if (JSC__JSValue__getPropertyValue(throwing_read, context, "boom".ptr, 4) != .empty or !JSGlobalObject__hasException(context))
        fail("private ordinary property read swallowed getter exception");
    JSGlobalObject__clearException(context);

    const mitigated_target = evaluate(context,
        \\globalThis.__private_mitigated_gets = 0;
        \\Object.defineProperty(Object.prototype, 'polluted', { get() { __private_mitigated_gets++; return 50; }, configurable: true });
        \\const middle = Object.create(Object.prototype, { inheritedSafe: { get() { __private_mitigated_gets++; return 51; }, configurable: true } });
        \\globalThis.__private_mitigated_target = Object.create(middle);
        \\__private_mitigated_target;
    );
    if (JSC__JSValue__getIfPropertyExistsImpl(mitigated_target, context, "inheritedSafe".ptr, 13) != EncodedValue.fromInt32(51) or
        JSC__JSValue__getIfPropertyExistsImpl(mitigated_target, context, "polluted".ptr, 8) != .deleted or
        !JSC__JSValue__toBoolean(evaluate(context, "__private_mitigated_gets === 1")))
        fail("private mitigated lookup crossed Object.prototype cutoff");
    _ = evaluate(context, "delete Object.prototype.polluted");

    const own_target = evaluate(context,
        \\globalThis.__private_own_gets = 0;
        \\globalThis.__private_own_target = Object.create({ inheritedOwn: 61 });
        \\Object.defineProperty(__private_own_target, 'own', { get() { __private_own_gets++; return 62; }, configurable: true });
        \\__private_own_target[''] = 63;
        \\__private_own_target[4] = 64;
        \\__private_own_target;
    );
    const own_key_bytes = "own";
    const inherited_own_key_bytes = "inheritedOwn";
    var own_bun_key = BunString{ .tag = .zig_string, .value = .{ .zig_string = .{ .tagged_ptr = @intFromPtr(own_key_bytes.ptr), .len = own_key_bytes.len } } };
    var inherited_own_bun_key = BunString{ .tag = .zig_string, .value = .{ .zig_string = .{ .tagged_ptr = @intFromPtr(inherited_own_key_bytes.ptr), .len = inherited_own_key_bytes.len } } };
    if (JSC__JSValue__getOwn(own_target, context, &own_bun_key) != EncodedValue.fromInt32(62) or
        JSC__JSValue__getOwn(own_target, context, &inherited_own_bun_key) != .empty or
        JSC__JSValue__getOwn(own_target, context, &empty_bun_string) != EncodedValue.fromInt32(63) or
        JSC__JSValue__getOwnByValue(own_target, context, EncodedValue.fromInt32(4)) != EncodedValue.fromInt32(64) or
        JSC__JSValue__getOwnByValue(own_target, context, symbol_key) != .empty or
        !JSC__JSValue__toBoolean(evaluate(context, "__private_own_gets === 1")))
        fail("private own-property read/BunString/index sentinel mismatch");
    const own_coercion_key = evaluate(context,
        \\globalThis.__private_own_key_hits = 0;
        \\({ [Symbol.toPrimitive]() { __private_own_key_hits++; return 'own'; } })
    );
    if (JSC__JSValue__getOwnByValue(own_target, context, own_coercion_key) != EncodedValue.fromInt32(62) or
        !JSC__JSValue__toBoolean(evaluate(context, "__private_own_key_hits === 1 && __private_own_gets === 2")))
        fail("private own-property key coercion mismatch");
    const own_proxy = evaluate(context,
        \\globalThis.__private_own_descriptors = 0;
        \\new Proxy({}, { getOwnPropertyDescriptor(target, key) { __private_own_descriptors++; return { value: 65, writable: true, enumerable: true, configurable: true }; } })
    );
    if (JSC__JSValue__getOwnByValue(own_proxy, context, evaluate(context, "'proxyOwn'")) != EncodedValue.fromInt32(65) or
        !JSC__JSValue__toBoolean(evaluate(context, "__private_own_descriptors === 1")))
        fail("private own-property proxy slot mismatch");

    if (JSC__JSValue__getPropertyValue(.true, context, "x".ptr, 1) != .deleted or
        JSC__JSValue__getIfPropertyExistsImpl(.true, context, "x".ptr, 1) != .deleted or
        JSC__JSValue__getOwn(.true, context, &own_bun_key) != .empty or
        JSC__JSValue__getOwnByValue(.true, context, encoded_text) != .empty)
        fail("private property non-object sentinel mismatch");
    if (JSC__JSValue__createObject2(context, &first_key, &second_key, EncodedValue.fromRef(foreign_object), .true) != .empty or
        !JSGlobalObject__hasException(context))
        fail("private createObject2 accepted foreign-VM value");
    JSGlobalObject__clearException(context);

    JSC__VM__throwError(vm, context, EncodedValue.fromInt32(203));
    JSC__JSValue__put(direct_target, context, &direct_key, .false);
    JSC__JSValue__putToPropertyKey(property_key_target, context, encoded_text, .false);
    if (JSC__JSValue__createObject2(context, &first_key, &second_key, .true, .false) != .empty or
        JSC__JSValue__deleteProperty(delete_target, context, &fixed_key) or
        JSC__JSValue__getPropertyValue(property_read_target, context, "inherited".ptr, 9) != .empty or
        JSC__JSValue__getIfPropertyExistsImpl(mitigated_target, context, "inheritedSafe".ptr, 13) != .empty or
        JSC__JSValue__getOwn(own_target, context, &own_bun_key) != .empty or
        JSC__JSValue__getOwnByValue(own_target, context, encoded_text) != .empty)
        fail("private property boundary ignored pending exception");
    const preserved_property_exception = JSGlobalObject__tryTakeException(context);
    if (JSC__Exception__asJSValue(preserved_property_exception.cellPointer()) != EncodedValue.fromInt32(203) or
        !JSC__JSValue__toBoolean(evaluate(context, "__private_direct_target.direct === __private_aggregate_identity && !Object.hasOwn(__private_property_key_target, 'value')")))
        fail("private property boundary replaced pending exception or mutated state");

    const fast_names = [_][]const u8{
        "method",   "headers",       "status",        "statusText", "url",       "body",          "data",   "toString",
        "redirect", "inspectCustom", "highWaterMark", "path",       "stream",    "asyncIterator", "name",   "message",
        "error",    "default",       "encoding",      "fatal",      "ignoreBOM", "type",          "signal", "cmd",
    };
    const fast_target = evaluate(sibling_context, "globalThis.__private_fast_target = {}; ['method','headers','status','statusText','url','body','data','toString','redirect','highWaterMark','path','stream','name','message','error','default','encoding','fatal','ignoreBOM','type','signal','cmd'].forEach((key, i) => __private_fast_target[key] = 100 + (i < 9 ? i : i + (i < 12 ? 1 : 2))); __private_fast_target[Symbol.for('nodejs.util.inspect.custom')] = 109; __private_fast_target[Symbol.asyncIterator] = 113; __private_fast_target");
    for (fast_names, 0..) |_, index| {
        const expected = EncodedValue.fromInt32(@intCast(100 + index));
        if (JSC__JSValue__fastGetDirect_(fast_target, sibling_context, @intCast(index)) != expected or
            JSC__JSValue__fastGetOwn(fast_target, sibling_context, @intCast(index)) != expected or
            JSC__JSValue__fastGet(fast_target, sibling_context, @intCast(index)) != expected)
            fail("private fast built-in name table mismatch");
    }
    const fast_accessor = evaluate(context, "globalThis.__private_fast_gets = 0; Object.defineProperty({}, 'name', { get() { __private_fast_gets++; return 81; }, configurable: true })");
    if (JSC__JSValue__fastGetDirect_(fast_accessor, context, 14) != .empty or
        JSC__JSValue__fastGetOwn(fast_accessor, context, 14) != EncodedValue.fromInt32(81) or
        JSC__JSValue__fastGet(fast_accessor, context, 14) != EncodedValue.fromInt32(81) or
        !JSC__JSValue__toBoolean(evaluate(context, "__private_fast_gets === 2")))
        fail("private fast direct/own accessor distinction mismatch");
    const fast_inherited = evaluate(context, "Object.create({ name: 82 })");
    if (JSC__JSValue__fastGetDirect_(fast_inherited, context, 14) != .empty or
        JSC__JSValue__fastGetOwn(fast_inherited, context, 14) != .empty or
        JSC__JSValue__fastGet(fast_inherited, context, 14) != EncodedValue.fromInt32(82))
        fail("private fast inherited lookup distinction mismatch");
    const fast_proxy = evaluate(context, "globalThis.__private_fast_proxy_gets = 0; globalThis.__private_fast_proxy_descs = 0; new Proxy({}, { get() { __private_fast_proxy_gets++; return 83; }, getOwnPropertyDescriptor() { __private_fast_proxy_descs++; return { value: 84, writable: true, enumerable: true, configurable: true }; } })");
    if (JSC__JSValue__fastGetDirect_(fast_proxy, context, 14) != .empty or
        JSC__JSValue__fastGetOwn(fast_proxy, context, 14) != EncodedValue.fromInt32(84) or
        JSC__JSValue__fastGet(fast_proxy, context, 14) != EncodedValue.fromInt32(83) or
        !JSC__JSValue__toBoolean(evaluate(context, "__private_fast_proxy_gets === 1 && __private_fast_proxy_descs === 1")))
        fail("private fast Proxy observability mismatch");
    const fast_undefined = evaluate(context, "({ name: undefined })");
    _ = evaluate(context, "Object.defineProperty(Object.prototype, 'name', { value: 85, configurable: true })");
    if (JSC__JSValue__fastGet(fast_undefined, context, 14) != .undefined or
        JSC__JSValue__fastGet(evaluate(context, "({})"), context, 14) != .deleted or
        JSC__JSValue__fastGetDirect_(fast_target, context, 24) != .empty or
        JSC__JSValue__fastGetOwn(fast_target, context, 255) != .empty or
        JSC__JSValue__fastGet(fast_target, context, 255) != .deleted)
        fail("private fast undefined/cutoff/invalid-id sentinel mismatch");
    _ = evaluate(context, "delete Object.prototype.name");

    const code_target = evaluate(context, "Object.create({ code: 91 })");
    const code_own = evaluate(context, "({ code: 92 })");
    const code_accessor = evaluate(context, "globalThis.__private_code_gets = 0; Object.defineProperty({}, 'code', { get() { __private_code_gets++; return 93; } })");
    const code_proxy = evaluate(context, "new Proxy({ code: 94 }, {})");
    if (Bun__JSObject__getCodePropertyVMInquiry(context, code_target.cellPointer()) != EncodedValue.fromInt32(91) or
        Bun__JSObject__getCodePropertyVMInquiry(sibling_context, code_own.cellPointer()) != EncodedValue.fromInt32(92) or
        Bun__JSObject__getCodePropertyVMInquiry(context, code_accessor.cellPointer()) != .empty or
        Bun__JSObject__getCodePropertyVMInquiry(context, code_proxy.cellPointer()) != .empty or
        Bun__JSObject__getCodePropertyVMInquiry(context, null) != .empty or
        Bun__JSObject__getCodePropertyVMInquiry(context, foreign_object) != .empty or
        !JSC__JSValue__toBoolean(evaluate(context, "__private_code_gets === 0")))
        fail("private code VM inquiry purity/ownership mismatch");

    JSC__VM__throwError(vm, context, EncodedValue.fromInt32(204));
    if (JSC__JSValue__fastGetDirect_(fast_target, context, 14) != .empty or
        JSC__JSValue__fastGetOwn(fast_target, context, 14) != .empty or
        JSC__JSValue__fastGet(fast_target, context, 14) != .empty or
        Bun__JSObject__getCodePropertyVMInquiry(context, code_own.cellPointer()) != .empty)
        fail("private fast property reads ignored pending exception");
    const preserved_fast_exception = JSGlobalObject__tryTakeException(context);
    if (JSC__Exception__asJSValue(preserved_fast_exception.cellPointer()) != EncodedValue.fromInt32(204))
        fail("private fast property reads replaced pending exception");

    const registry_latin1 = JSC__JSValue__symbolFor(context, &latin1_string.value.zig_string);
    const registry_utf8 = JSC__JSValue__symbolFor(sibling_context, &utf8_string.value.zig_string);
    const registry_utf16 = JSC__JSValue__symbolFor(context, &utf16_string.value.zig_string);
    const registry_empty = JSC__JSValue__symbolFor(context, &empty_zig_string);
    if (!JSC__JSValue__isStrictEqual(registry_latin1, evaluate(sibling_context, "Symbol.for('café')"), sibling_context))
        fail("private Symbol.for Latin-1/sibling identity mismatch");
    if (!JSC__JSValue__isStrictEqual(registry_utf8, evaluate(context, "Symbol.for('A😀Z')"), context))
        fail("private Symbol.for UTF-8/sibling identity mismatch");
    if (!JSC__JSValue__isStrictEqual(registry_utf16, evaluate(context, "Symbol.for('A😀\\uD800Z')"), context))
        fail("private Symbol.for UTF-16 identity mismatch");
    if (!JSC__JSValue__isStrictEqual(registry_empty, evaluate(context, "Symbol.for('')"), context))
        fail("private Symbol.for empty identity mismatch");

    var mutable_symbol_bytes = [_]u8{ 'm', 'u', 't', 'a', 'b', 'l', 'e' };
    const mutable_symbol_key = ZigString{ .tagged_ptr = @intFromPtr(&mutable_symbol_bytes), .len = mutable_symbol_bytes.len };
    const mutation_safe_symbol = JSC__JSValue__symbolFor(context, &mutable_symbol_key);
    mutable_symbol_bytes[0] = 'X';
    if (!JSC__JSValue__isStrictEqual(mutation_safe_symbol, evaluate(context, "Symbol.for('mutable')"), context))
        fail("private Symbol.for retained caller storage");

    var symbol_output = ZigString{ .tagged_ptr = 1, .len = 999 };
    JSC__JSValue__getSymbolDescription(registry_latin1, sibling_context, &symbol_output);
    expectZigStringUnits(symbol_output, &[_]u16{ 'c', 'a', 'f', 0x00e9 }, false, "private registered Symbol description mismatch");
    const local_symbol = evaluate(context, "Symbol('local😀')");
    JSC__JSValue__getSymbolDescription(local_symbol, context, &symbol_output);
    expectZigStringUnits(symbol_output, &[_]u16{ 'l', 'o', 'c', 'a', 'l', 0xd83d, 0xde00 }, true, "private local Symbol description mismatch");
    JSC__JSValue__getSymbolDescription(evaluate(context, "Symbol()"), context, &symbol_output);
    expectZigStringUnits(symbol_output, &[_]u16{}, false, "private empty Symbol description mismatch");
    JSC__JSValue__getSymbolDescription(evaluate(context, "Symbol.iterator"), sibling_context, &symbol_output);
    expectZigStringUnits(symbol_output, &[_]u16{ 'S', 'y', 'm', 'b', 'o', 'l', '.', 'i', 't', 'e', 'r', 'a', 't', 'o', 'r' }, false, "private well-known Symbol description mismatch");

    symbol_output = .{ .tagged_ptr = 1, .len = 999 };
    if (!JSC__JSValue__symbolKeyFor(registry_utf16, sibling_context, &symbol_output))
        fail("private Symbol.keyFor rejected registered symbol");
    expectZigStringUnits(symbol_output, &[_]u16{ 'A', 0xd83d, 0xde00, 0xd800, 'Z' }, true, "private Symbol.keyFor UTF-16 key mismatch");
    const untouched_symbol_output = ZigString{ .tagged_ptr = 7, .len = 77 };
    symbol_output = untouched_symbol_output;
    if (JSC__JSValue__symbolKeyFor(local_symbol, context, &symbol_output) or
        symbol_output.tagged_ptr != untouched_symbol_output.tagged_ptr or symbol_output.len != untouched_symbol_output.len)
        fail("private Symbol.keyFor accepted local symbol or modified output");
    if (JSC__JSValue__symbolKeyFor(evaluate(context, "Symbol.iterator"), context, &symbol_output) or
        symbol_output.tagged_ptr != untouched_symbol_output.tagged_ptr or symbol_output.len != untouched_symbol_output.len)
        fail("private Symbol.keyFor accepted well-known symbol or modified output");
    JSC__JSValue__getSymbolDescription(.true, context, &symbol_output);
    if (symbol_output.tagged_ptr != untouched_symbol_output.tagged_ptr or symbol_output.len != untouched_symbol_output.len)
        fail("private Symbol description modified output for non-symbol");
    const foreign_registry_symbol = JSC__JSValue__symbolFor(foreign_context, &latin1_string.value.zig_string);
    if (JSC__JSValue__isStrictEqual(registry_latin1, foreign_registry_symbol, context) or
        JSC__JSValue__symbolKeyFor(foreign_registry_symbol, context, &symbol_output))
        fail("private Symbol registry crossed VM boundary");

    JSC__VM__throwError(vm, context, EncodedValue.fromInt32(205));
    symbol_output = untouched_symbol_output;
    if (JSC__JSValue__symbolFor(context, &latin1_string.value.zig_string) != .empty or
        JSC__JSValue__symbolKeyFor(registry_latin1, context, &symbol_output))
        fail("private Symbol bridges ignored pending exception");
    JSC__JSValue__getSymbolDescription(registry_latin1, context, &symbol_output);
    const preserved_symbol_exception = JSGlobalObject__tryTakeException(context);
    if (JSC__Exception__asJSValue(preserved_symbol_exception.cellPointer()) != EncodedValue.fromInt32(205) or
        symbol_output.tagged_ptr != untouched_symbol_output.tagged_ptr or symbol_output.len != untouched_symbol_output.len)
        fail("private Symbol bridges replaced pending exception or modified output");

    const sibling_dom_exception = ZigString__toDOMExceptionInstance(&empty_zig_string, sibling_context, 16);
    exposeCell(sibling_context, "__private_sibling_dom_exception", sibling_dom_exception);
    if (!JSC__JSValue__toBoolean(evaluate(sibling_context, "Object.getPrototypeOf(__private_sibling_dom_exception) === DOMException.prototype && __private_sibling_dom_exception.name === 'AbortError'")))
        fail("DOMException matrix selected-realm prototype mismatch");

    const atom_bytes = "shared-atom";
    const atom_string = ZigString{ .tagged_ptr = @intFromPtr(atom_bytes.ptr), .len = atom_bytes.len };
    const sibling_atom = ZigString__toAtomicValue(&atom_string, sibling_context);
    const primary_atom = ZigString__toAtomicValue(&atom_string, context);
    const foreign_atom = ZigString__toAtomicValue(&atom_string, foreign_context);
    if (!JSC__JSValue__isStrictEqual(sibling_atom, primary_atom, context) or
        !JSC__JSValue__isStrictEqual(sibling_atom, evaluate(sibling_context, "'shared-atom'"), sibling_context) or
        JSC__JSValue__isStrictEqual(primary_atom, foreign_atom, context))
        fail("private atomic string VM sharing/isolation mismatch");

    const sibling_rope = JSC__JSValue__createRopeString(
        evaluate(context, "'primary-'"),
        evaluate(sibling_context, "'sibling'"),
        sibling_context,
    );
    if (!JSC__JSValue__isStrictEqual(sibling_rope, evaluate(sibling_context, "'primary-sibling'"), sibling_context))
        fail("private rope string same-VM sibling mismatch");

    var sibling_borrowed_view: ZigString = undefined;
    JSC__JSString__toZigString(JSC__JSValue__asString(view_values[2]), sibling_context, &sibling_borrowed_view);
    if (sibling_borrowed_view.tagged_ptr != borrowed_views[2].tagged_ptr)
        fail("borrowed ZigString cache was not shared by sibling realms");
    const sibling_view_object = evaluate(sibling_context, "({ toString() { return 'sibling-view'; } })");
    JSC__JSValue__toZigString(sibling_view_object, &sibling_borrowed_view, context);
    expectZigStringUnits(
        sibling_borrowed_view,
        &[_]u16{ 's', 'i', 'b', 'l', 'i', 'n', 'g', '-', 'v', 'i', 'e', 'w' },
        false,
        "borrowed ZigString sibling JSValue conversion mismatch",
    );

    const sibling_bigint_string = JSC__JSBigInt__toString(signed_negative_cell, sibling_context);
    const sibling_bigint_impl = sibling_bigint_string.value.wtf_string_impl orelse fail("sibling BigInt string missing StringImpl");
    if (sibling_bigint_string.tag != .wtf_string_impl or
        !std.mem.eql(u8, sibling_bigint_impl.bytes[0..sibling_bigint_impl.length], "-1"))
        fail("same-VM sibling BigInt string conversion mismatch");
    Bun__WTFStringImpl__deref(sibling_bigint_impl);

    const timeout_reason = WebCore__CommonAbortReason__toJS(sibling_context, 1);
    const timeout_reason_second = WebCore__CommonAbortReason__toJS(sibling_context, 1);
    const user_abort_reason = WebCore__CommonAbortReason__toJS(context, 2);
    const closed_reason = WebCore__CommonAbortReason__toJS(context, 3);
    if (timeout_reason == .empty or timeout_reason_second == .empty or
        user_abort_reason == .empty or closed_reason == .empty or
        !JSC__JSValue__isAnyError(timeout_reason) or
        JSC__JSValue__isStrictEqual(timeout_reason, timeout_reason_second, sibling_context))
        fail("private CommonAbortReason construction/freshness mismatch");
    exposeCell(sibling_context, "__private_timeout_reason", timeout_reason);
    exposeCell(context, "__private_user_abort_reason", user_abort_reason);
    exposeCell(context, "__private_closed_reason", closed_reason);
    if (!JSC__JSValue__toBoolean(evaluate(sibling_context, "Object.getPrototypeOf(__private_timeout_reason) === DOMException.prototype")))
        fail("private CommonAbortReason selected-realm prototype mismatch");
    if (!JSC__JSValue__toBoolean(evaluate(sibling_context, "__private_timeout_reason instanceof DOMException")))
        fail("private CommonAbortReason DOMException classification mismatch");
    if (!JSC__JSValue__toBoolean(evaluate(sibling_context, "__private_timeout_reason instanceof Error")))
        fail("private CommonAbortReason Error classification mismatch");
    if (!JSC__JSValue__toBoolean(evaluate(sibling_context, "__private_timeout_reason.name === 'TimeoutError' && __private_timeout_reason.message === 'The operation timed out.' && __private_timeout_reason.code === 23")))
        fail("private CommonAbortReason timeout metadata mismatch");
    if (!JSC__JSValue__toBoolean(evaluate(context, "__private_user_abort_reason instanceof DOMException && __private_user_abort_reason.name === 'AbortError' && __private_user_abort_reason.message === 'The operation was aborted.' && __private_user_abort_reason.code === 20")))
        fail("private CommonAbortReason user-abort metadata mismatch");
    if (!JSC__JSValue__toBoolean(evaluate(context, "__private_closed_reason instanceof DOMException && __private_closed_reason.name === 'AbortError' && __private_closed_reason.message === 'The connection was closed.' && __private_closed_reason.code === 20")))
        fail("private CommonAbortReason connection-closed metadata mismatch");
    JSC__VM__throwError(vm, context, EncodedValue.fromInt32(445));
    if (WebCore__CommonAbortReason__toJS(sibling_context, 2) != .empty)
        fail("private CommonAbortReason ignored pending exception");
    const preserved_abort_exception = JSGlobalObject__tryTakeException(context);
    if (JSC__Exception__asJSValue(preserved_abort_exception.cellPointer()) != EncodedValue.fromInt32(445))
        fail("private CommonAbortReason replaced pending exception");
    if (vm != sibling_vm or vm == foreign_vm or JSGlobalObject__hasException(context) or
        JSGlobalObject__tryTakeException(context) != .empty)
        fail("private VM identity mismatch");

    iso_buffer = @splat(0xa5);
    if (JSC__JSValue__getUTCTimestamp(sibling_context, parsed_offset) != JSC__JSValue__getUnixTimestamp(parsed_offset) or
        JSC__JSValue__toISOString(sibling_context, parsed_offset, &iso_buffer) != 24 or
        !std.mem.eql(u8, iso_buffer[0..24], "2020-02-29T10:04:56.789Z"))
        fail("private Date sibling-realm mismatch");
    iso_buffer = @splat(0xa5);
    if (JSC__JSValue__toISOString(foreign_context, parsed_offset, &iso_buffer) != -1 or
        !std.mem.allEqual(u8, &iso_buffer, 0xa5))
        fail("private Date foreign-VM rejection mismatch");
    iso_buffer = @splat(0xa5);
    if (JSC__JSValue__DateNowISOString(context, &iso_buffer) != 24 or
        iso_buffer[4] != '-' or iso_buffer[7] != '-' or iso_buffer[10] != 'T' or
        iso_buffer[13] != ':' or iso_buffer[16] != ':' or iso_buffer[19] != '.' or iso_buffer[23] != 'Z')
        fail("private Date-now ISO formatting mismatch");

    const reflection_object = evaluate(context,
        \\globalThis.__private_reflection_gets = 0;
        \\const __private_reflection_symbol = Symbol('hidden');
        \\const __private_reflection_object = { 2: 'two', b: 'bee', 1: 'one' };
        \\Object.defineProperty(__private_reflection_object, 'hidden', { value: 9, enumerable: false });
        \\Object.defineProperty(__private_reflection_object, 'a', { enumerable: true, get() { __private_reflection_gets++; return 'aye'; } });
        \\__private_reflection_object[__private_reflection_symbol] = 'symbol';
        \\__private_reflection_object;
    );
    const reflection_keys = JSC__JSValue__keys(context, reflection_object);
    if (!JSC__JSValue__isStrictEqual(JSC__JSValue__getPrototype(reflection_keys, context), evaluate(context, "Array.prototype"), context) or
        !JSC__JSValue__isStrictEqual(JSC__JSValue__getDirectIndex(reflection_keys, context, 0), evaluate(context, "'1'"), context) or
        !JSC__JSValue__isStrictEqual(JSC__JSValue__getDirectIndex(reflection_keys, context, 1), evaluate(context, "'2'"), context) or
        !JSC__JSValue__isStrictEqual(JSC__JSValue__getDirectIndex(reflection_keys, context, 2), evaluate(context, "'b'"), context) or
        !JSC__JSValue__isStrictEqual(JSC__JSValue__getDirectIndex(reflection_keys, context, 3), evaluate(context, "'a'"), context) or
        Bun__JSValue__toNumber(evaluate(context, "__private_reflection_gets"), context) != 0)
        fail("private Object.keys ordering/getter mismatch");
    const reflection_values = JSC__JSValue__values(sibling_context, reflection_object);
    if (!JSC__JSValue__isStrictEqual(JSC__JSValue__getDirectIndex(reflection_values, context, 0), evaluate(context, "'one'"), context) or
        !JSC__JSValue__isStrictEqual(JSC__JSValue__getDirectIndex(reflection_values, context, 1), evaluate(context, "'two'"), context) or
        !JSC__JSValue__isStrictEqual(JSC__JSValue__getDirectIndex(reflection_values, context, 2), evaluate(context, "'bee'"), context) or
        !JSC__JSValue__isStrictEqual(JSC__JSValue__getDirectIndex(reflection_values, context, 3), evaluate(context, "'aye'"), context) or
        Bun__JSValue__toNumber(evaluate(context, "__private_reflection_gets"), context) != 1)
        fail("private Object.values ordering/getter mismatch");

    const astral_text = evaluate(context, "'💩'");
    const astral_keys = JSC__JSValue__keys(context, astral_text);
    const astral_values = JSC__JSValue__values(context, astral_text);
    if (!JSC__JSValue__isStrictEqual(JSC__JSValue__getDirectIndex(astral_keys, context, 0), evaluate(context, "'0'"), context) or
        !JSC__JSValue__isStrictEqual(JSC__JSValue__getDirectIndex(astral_keys, context, 1), evaluate(context, "'1'"), context) or
        JSC__JSValue__getDirectIndex(astral_keys, context, 2) != .empty or
        !JSC__JSValue__isStrictEqual(JSC__JSValue__getDirectIndex(astral_values, context, 0), evaluate(context, "'\\ud83d'"), context) or
        !JSC__JSValue__isStrictEqual(JSC__JSValue__getDirectIndex(astral_values, context, 1), evaluate(context, "'\\udca9'"), context))
        fail("private Object reflection UTF-16 mismatch");

    const reflection_proxy = evaluate(context,
        \\globalThis.__private_reflection_log = '';
        \\new Proxy({ x: 7 }, {
        \\  ownKeys() { __private_reflection_log += 'o'; return ['x']; },
        \\  getOwnPropertyDescriptor() { __private_reflection_log += 'd'; return { enumerable: true, configurable: true }; },
        \\  get(target, key) { __private_reflection_log += 'g'; return target[key]; }
        \\});
    );
    _ = JSC__JSValue__keys(context, reflection_proxy);
    if (!JSC__JSValue__isStrictEqual(evaluate(context, "__private_reflection_log"), evaluate(context, "'od'"), context))
        fail("private Object.keys proxy trap mismatch");
    _ = evaluate(context, "__private_reflection_log = ''");
    const proxy_values = JSC__JSValue__values(context, reflection_proxy);
    if (!JSC__JSValue__isStrictEqual(evaluate(context, "__private_reflection_log"), evaluate(context, "'odg'"), context) or
        Bun__JSValue__toNumber(JSC__JSValue__getDirectIndex(proxy_values, context, 0), context) != 7)
        fail("private Object.values proxy trap mismatch");

    const throwing_reflection = evaluate(context, "Object.defineProperty({}, 'x', { enumerable: true, get() { throw 777; } })");
    if (JSC__JSValue__values(context, throwing_reflection) != .empty or !JSGlobalObject__hasException(context))
        fail("private Object.values getter did not throw");
    const reflection_exception = JSGlobalObject__tryTakeException(context);
    if (JSC__Exception__asJSValue(reflection_exception.cellPointer()) != EncodedValue.fromInt32(777))
        fail("private Object.values thrown value mismatch");
    if (JSC__JSValue__keys(context, .null) != .empty or !JSGlobalObject__hasException(context))
        fail("private Object.keys null did not throw");
    JSGlobalObject__clearException(context);
    if (JSC__JSValue__keys(context, EncodedValue.fromRef(foreign_object)) != .empty or !JSGlobalObject__hasException(context))
        fail("private Object.keys foreign value did not throw");
    JSGlobalObject__clearException(context);

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

    const array = JSC__JSValue__createEmptyArray(context, 4);
    if (array == .empty or JSC__JSValue__getDirectIndex(array, context, 0) != .empty or
        getNumberProperty(context, array, "length") != 4)
        fail("private empty array hole/length mismatch");
    const indexed_prototype = evaluate(context, "globalThis.__private_array_setter_hits = 0; ({ get 1() { return 77; }, set 2(v) { __private_array_setter_hits++; }, get 3() { throw 99; } })");
    JSObjectSetPrototype(context, array.cellPointer(), indexed_prototype.cellPointer());
    if (JSC__JSObject__getIndex(array, context, 1) != EncodedValue.fromInt32(77) or
        JSC__JSValue__getDirectIndex(array, context, 1) != .empty)
        fail("private observable/direct inherited index mismatch");
    JSC__JSValue__putIndex(array, context, 2, EncodedValue.fromInt32(55));
    if (JSC__JSValue__getDirectIndex(array, context, 2) != EncodedValue.fromInt32(55) or
        JSC__JSObject__getIndex(array, context, 2) != EncodedValue.fromInt32(55) or
        JSC__JSValue__toInt32(evaluate(context, "__private_array_setter_hits")) != 0)
        fail("private direct write invoked inherited setter");
    if (JSC__JSObject__getIndex(array, sibling_context, 3) != .empty or
        !JSGlobalObject__hasException(context))
        fail("indexed getter throw did not publish VM exception");
    const getter_exception = JSGlobalObject__tryTakeException(sibling_context);
    if (JSC__Exception__asJSValue(getter_exception.cellPointer()) != EncodedValue.fromInt32(99))
        fail("indexed getter exception value mismatch");

    JSC__JSValue__putIndex(array, context, 0, .undefined);
    if (JSC__JSValue__getDirectIndex(array, context, 0) != .undefined)
        fail("present undefined was confused with an array hole");
    JSC__JSValue__push(array, context, EncodedValue.fromInt32(88));
    if (JSC__JSValue__getDirectIndex(array, context, 4) != EncodedValue.fromInt32(88) or
        getNumberProperty(context, array, "length") != 5)
        fail("private array push mismatch");
    JSC__JSValue__putIndex(array, context, 10000, EncodedValue.fromInt32(12));
    if (JSC__JSValue__getDirectIndex(array, context, 9999) != .empty or
        JSC__JSValue__getDirectIndex(array, context, 10000) != EncodedValue.fromInt32(12) or
        getNumberProperty(context, array, "length") != 10001)
        fail("private sparse array write mismatch");

    const max_length_array = JSC__JSValue__createEmptyArray(context, std.math.maxInt(u32));
    JSC__JSValue__putIndex(max_length_array, context, std.math.maxInt(u32), EncodedValue.fromInt32(7));
    if (max_length_array == .empty or
        JSC__JSValue__getDirectIndex(max_length_array, context, std.math.maxInt(u32)) != EncodedValue.fromInt32(7) or
        getNumberProperty(context, max_length_array, "length") != @as(f64, @floatFromInt(std.math.maxInt(u32))))
        fail("maximum private array length/index mismatch");
    JSC__JSValue__push(max_length_array, context, .true);
    if (!JSGlobalObject__hasException(context)) fail("maximum-length push did not throw");
    const range_exception = JSGlobalObject__tryTakeException(context);
    const range_error = JSC__Exception__asJSValue(range_exception.cellPointer());
    if (!JSC__JSValue__isAnyError(range_error) or
        !JSC__JSValue__isStrictEqual(getProperty(context, range_error, "name"), evaluate(context, "'RangeError'"), context))
        fail("maximum-length push did not produce RangeError");
    if (@bitSizeOf(usize) > 32) {
        const invalid_length = JSC__JSValue__createEmptyArray(context, @as(usize, std.math.maxInt(u32)) + 1);
        if (invalid_length != .empty or !JSGlobalObject__hasException(context))
            fail("invalid private array length did not throw");
        JSGlobalObject__clearException(context);
    }

    if (JSC__JSObject__getIndex(.null, context, 0) != .empty or !JSGlobalObject__hasException(context))
        fail("private indexed ToObject null mismatch");
    JSGlobalObject__clearException(context);
    JSC__JSValue__putIndex(EncodedValue.fromRef(foreign_object), context, 0, .true);
    JSC__JSValue__putIndex(array, context, 6, EncodedValue.fromRef(foreign_object));
    if (JSGlobalObject__hasException(context) or
        JSC__JSValue__getDirectIndex(EncodedValue.fromInt32(1), context, 0) != .empty or
        JSC__JSObject__getIndex(EncodedValue.fromInt32(1), context, 0) != .undefined)
        fail("private array invalid/primitive input mismatch");

    const sibling_item = evaluate(sibling_context, "({ sibling: true })");
    const constructed_items = [_]EncodedValue{ .true, EncodedValue.fromInt32(-7), encoded_object, sibling_item };
    const constructed = JSArray__constructArray(context, constructed_items[0..].ptr, constructed_items.len);
    if (constructed == .empty or
        JSC__JSValue__getDirectIndex(constructed, context, 0) != .true or
        JSC__JSValue__getDirectIndex(constructed, context, 1) != EncodedValue.fromInt32(-7) or
        !JSC__JSValue__isStrictEqual(JSC__JSValue__getDirectIndex(constructed, context, 2), encoded_object, context) or
        !JSC__JSValue__isStrictEqual(JSC__JSValue__getDirectIndex(constructed, context, 3), sibling_item, context) or
        getNumberProperty(context, constructed, "length") != @as(f64, @floatFromInt(constructed_items.len)) or
        !JSC__JSValue__isStrictEqual(JSC__JSValue__getPrototype(constructed, context), evaluate(context, "Array.prototype"), context))
        fail("private packed JSArray construction mismatch");
    const zero_items = [_]EncodedValue{};
    const constructed_zero = JSArray__constructArray(context, zero_items[0..].ptr, 0);
    const constructed_holes = JSArray__constructEmptyArray(context, 3);
    const constructed_max = JSArray__constructEmptyArray(context, std.math.maxInt(u32));
    if (constructed_zero == .empty or getNumberProperty(context, constructed_zero, "length") != 0 or
        constructed_holes == .empty or getNumberProperty(context, constructed_holes, "length") != 3 or
        JSC__JSValue__getDirectIndex(constructed_holes, context, 0) != .empty or
        JSC__JSValue__getDirectIndex(constructed_holes, context, 2) != .empty or
        constructed_max == .empty or
        getNumberProperty(context, constructed_max, "length") != @as(f64, @floatFromInt(std.math.maxInt(u32))))
        fail("private empty JSArray construction mismatch");

    const invalid_items = [_]EncodedValue{ EncodedValue.fromInt32(1), EncodedValue.fromRef(foreign_object) };
    if (JSArray__constructArray(context, invalid_items[0..].ptr, invalid_items.len) != .empty or
        !JSGlobalObject__hasException(context))
        fail("foreign private JSArray item did not fail atomically");
    const foreign_item_exception = JSGlobalObject__tryTakeException(context);
    const foreign_item_error = JSC__Exception__asJSValue(foreign_item_exception.cellPointer());
    if (!JSC__JSValue__isStrictEqual(getProperty(context, foreign_item_error, "name"), evaluate(context, "'TypeError'"), context))
        fail("foreign private JSArray item did not produce TypeError");
    if (@bitSizeOf(usize) > 32) {
        if (JSArray__constructEmptyArray(context, @as(usize, std.math.maxInt(u32)) + 1) != .empty or
            !JSGlobalObject__hasException(context))
            fail("invalid private JSArray length did not publish exception");
        JSGlobalObject__clearException(context);
    }

    if (!std.math.isNan(Bun__JSValue__toNumber(.undefined, context)) or
        JSGlobalObject__hasException(context) or
        Bun__JSValue__toNumber(.null, context) != 0 or
        Bun__JSValue__toNumber(.false, context) != 0 or
        Bun__JSValue__toNumber(.true, context) != 1 or
        Bun__JSValue__toNumber(EncodedValue.fromInt32(-42), context) != -42 or
        Bun__JSValue__toNumber(EncodedValue.fromDouble(-0.0), context) != 0 or
        !std.math.signbit(Bun__JSValue__toNumber(EncodedValue.fromDouble(-0.0), context)) or
        Bun__JSValue__toNumber(evaluate(sibling_context, "' 0x10 '"), context) != 16 or
        !std.math.isNan(Bun__JSValue__toNumber(evaluate(context, "'not a number'"), context)) or
        JSGlobalObject__hasException(context))
        fail("private ToNumber primitive mismatch");

    const custom_number = evaluate(context, "globalThis.__private_number_order = []; ({ [Symbol.toPrimitive](hint) { __private_number_order.push(hint); return 12.5; } })");
    if (Bun__JSValue__toNumber(custom_number, context) != 12.5 or
        !JSC__JSValue__isStrictEqual(evaluate(context, "__private_number_order.join(',')"), evaluate(context, "'number'"), context))
        fail("private ToNumber Symbol.toPrimitive mismatch");
    const fallback_number = evaluate(context, "__private_number_order = []; ({ valueOf() { __private_number_order.push('valueOf'); return {}; }, toString() { __private_number_order.push('toString'); return '31'; } })");
    if (Bun__JSValue__toNumber(fallback_number, context) != 31 or
        !JSC__JSValue__isStrictEqual(evaluate(context, "__private_number_order.join(',')"), evaluate(context, "'valueOf,toString'"), context))
        fail("private ToNumber ordinary coercion order mismatch");

    const throwing_number = evaluate(context, "({ valueOf() { throw 123; } })");
    if (!std.math.isNan(Bun__JSValue__toNumber(throwing_number, sibling_context)) or
        !JSGlobalObject__hasException(context))
        fail("private ToNumber throw did not publish exception");
    const number_exception = JSGlobalObject__tryTakeException(context);
    if (JSC__Exception__asJSValue(number_exception.cellPointer()) != EncodedValue.fromInt32(123))
        fail("private ToNumber thrown value mismatch");
    for ([_]EncodedValue{ evaluate(context, "Symbol('n')"), signed_negative }) |non_number| {
        if (!std.math.isNan(Bun__JSValue__toNumber(non_number, context)) or
            !JSGlobalObject__hasException(context))
            fail("private ToNumber Symbol/BigInt did not throw");
        const type_exception = JSGlobalObject__tryTakeException(context);
        const type_error = JSC__Exception__asJSValue(type_exception.cellPointer());
        if (!JSC__JSValue__isStrictEqual(getProperty(context, type_error, "name"), evaluate(context, "'TypeError'"), context))
            fail("private ToNumber Symbol/BigInt error type mismatch");
    }
    if (!std.math.isNan(Bun__JSValue__toNumber(EncodedValue.fromRef(foreign_object), context)) or
        !JSGlobalObject__hasException(context))
        fail("private ToNumber foreign value did not throw");
    JSGlobalObject__clearException(context);
    JSC__VM__throwError(vm, context, EncodedValue.fromInt32(77));
    if (!std.math.isNan(Bun__JSValue__toNumber(EncodedValue.fromInt32(1), context)))
        fail("private ToNumber ignored existing exception");
    const preserved_number_exception = JSGlobalObject__tryTakeException(context);
    if (JSC__Exception__asJSValue(preserved_number_exception.cellPointer()) != EncodedValue.fromInt32(77))
        fail("private ToNumber replaced existing exception");

    const ordinary_constructor = evaluate(context, "globalThis.__private_ctor = function PrivateCtor() {}; __private_ctor");
    const ordinary_instance = evaluate(context, "new __private_ctor()");
    if (!JSC__JSValue__isInstanceOf(ordinary_instance, context, ordinary_constructor) or
        JSC__JSValue__isInstanceOf(encoded_object, context, ordinary_constructor) or
        JSC__JSValue__isInstanceOf(ordinary_instance, context, EncodedValue.fromInt32(1)) or
        JSC__JSValue__isInstanceOf(EncodedValue.fromInt32(1), context, ordinary_constructor) or
        JSGlobalObject__hasException(context))
        fail("private ordinary instanceof mismatch");
    const custom_constructor = evaluate(context, "globalThis.__private_has_instance_hits = 0; Object.defineProperty(function CustomCtor() {}, Symbol.hasInstance, { value(v) { __private_has_instance_hits++; return v === 42; } })");
    if (!JSC__JSValue__isInstanceOf(EncodedValue.fromInt32(42), context, custom_constructor) or
        JSC__JSValue__isInstanceOf(EncodedValue.fromInt32(41), context, custom_constructor) or
        Bun__JSValue__toNumber(evaluate(context, "__private_has_instance_hits"), context) != 2)
        fail("private Symbol.hasInstance mismatch");
    const inert_has_instance = evaluate(context, "({ [Symbol.hasInstance]() { __private_has_instance_hits += 100; return true; } })");
    if (JSC__JSValue__isInstanceOf(encoded_object, context, inert_has_instance) or
        Bun__JSValue__toNumber(evaluate(context, "__private_has_instance_hits"), context) != 2 or
        JSGlobalObject__hasException(context))
        fail("private non-has-instance object precheck mismatch");
    const proxy_constructor = evaluate(context, "new Proxy(function ProxyCtor() {}, { get(target, key, receiver) { if (key === Symbol.hasInstance) return () => true; return Reflect.get(target, key, receiver); } })");
    if (!JSC__JSValue__isInstanceOf(encoded_object, sibling_context, proxy_constructor))
        fail("private proxy hasInstance mismatch");
    const throwing_constructor = evaluate(context, "Object.defineProperty(function ThrowCtor() {}, Symbol.hasInstance, { value() { throw 456; } })");
    if (JSC__JSValue__isInstanceOf(encoded_object, context, throwing_constructor) or
        !JSGlobalObject__hasException(context))
        fail("private hasInstance throw did not publish exception");
    const instance_exception = JSGlobalObject__tryTakeException(context);
    if (JSC__Exception__asJSValue(instance_exception.cellPointer()) != EncodedValue.fromInt32(456))
        fail("private hasInstance thrown value mismatch");
    const invalid_prototype_constructor = evaluate(context, "globalThis.__private_bad_ctor = function BadCtor() {}; __private_bad_ctor.prototype = 1; __private_bad_ctor");
    if (JSC__JSValue__isInstanceOf(encoded_object, context, invalid_prototype_constructor) or
        !JSGlobalObject__hasException(context))
        fail("private instanceof invalid prototype did not throw");
    JSGlobalObject__clearException(context);

    const explicit_iterable = evaluate(context, "globalThis.__private_iterator_gets = 0; ({ get [Symbol.iterator]() { __private_iterator_gets++; return function* () {}; } })");
    if (!JSC__JSValue__isIterable(evaluate(context, "[]"), context))
        fail("private array iterator method mismatch");
    if (!JSC__JSValue__isIterable(explicit_iterable, sibling_context))
        fail("private sibling iterator method mismatch");
    if (Bun__JSValue__toNumber(evaluate(context, "__private_iterator_gets"), context) != 1)
        fail("private iterator getter count mismatch");
    if (JSC__JSValue__isIterable(encoded_text, context) or
        JSC__JSValue__isIterable(.null, context) or
        JSC__JSValue__isIterable(evaluate(context, "({ [Symbol.iterator]: null })"), context) or
        JSGlobalObject__hasException(context))
        fail("private absent iterator-method mismatch");
    if (JSC__JSValue__isIterable(evaluate(context, "({ [Symbol.iterator]: 1 })"), context) or
        !JSGlobalObject__hasException(context))
        fail("private non-callable iterator did not throw");
    const iterator_type_exception = JSGlobalObject__tryTakeException(context);
    const iterator_type_error = JSC__Exception__asJSValue(iterator_type_exception.cellPointer());
    if (!JSC__JSValue__isStrictEqual(getProperty(context, iterator_type_error, "name"), evaluate(context, "'TypeError'"), context))
        fail("private non-callable iterator error type mismatch");
    const throwing_iterable = evaluate(context, "({ get [Symbol.iterator]() { throw 321; } })");
    if (JSC__JSValue__isIterable(throwing_iterable, sibling_context) or
        !JSGlobalObject__hasException(context))
        fail("private iterator getter throw did not publish exception");
    const iterator_exception = JSGlobalObject__tryTakeException(context);
    if (JSC__Exception__asJSValue(iterator_exception.cellPointer()) != EncodedValue.fromInt32(321))
        fail("private iterator getter thrown value mismatch");
    if (JSC__JSValue__isIterable(EncodedValue.fromRef(foreign_object), context) or
        !JSGlobalObject__hasException(context))
        fail("private iterator foreign value did not throw");
    JSGlobalObject__clearException(context);
    const pending_iterable = evaluate(context, "[]");
    JSC__VM__throwError(vm, context, EncodedValue.fromInt32(88));
    if (JSC__JSValue__isIterable(pending_iterable, context))
        fail("private iterator predicate ignored existing exception");
    const preserved_predicate_exception = JSGlobalObject__tryTakeException(context);
    if (JSC__Exception__asJSValue(preserved_predicate_exception.cellPointer()) != EncodedValue.fromInt32(88))
        fail("private iterator predicate replaced existing exception");

    if (!JSC__JSValue__stringIncludes(evaluate(context, "'abcdef'"), context, evaluate(context, "'bcd'")) or
        JSC__JSValue__stringIncludes(evaluate(context, "'abcdef'"), context, evaluate(context, "'bd'")) or
        !JSC__JSValue__stringIncludes(EncodedValue.fromInt32(12345), context, EncodedValue.fromInt32(234)) or
        !JSC__JSValue__stringIncludes(evaluate(sibling_context, "'value'"), context, evaluate(context, "''")) or
        !JSC__JSValue__stringIncludes(evaluate(context, "'😀'"), context, evaluate(context, "'\\ud83d'")) or
        !JSC__JSValue__stringIncludes(evaluate(context, "'😀'"), context, evaluate(context, "'\\ude00'")) or
        JSGlobalObject__hasException(context))
        fail("private UTF-16 string inclusion mismatch");
    const coercion_haystack = evaluate(context, "globalThis.__private_string_order = []; ({ toString() { __private_string_order.push('haystack'); return 'ordered search'; } })");
    const coercion_needle = evaluate(context, "({ toString() { __private_string_order.push('needle'); return 'search'; } })");
    if (!JSC__JSValue__stringIncludes(coercion_haystack, context, coercion_needle) or
        !JSC__JSValue__isStrictEqual(evaluate(context, "__private_string_order.join(',')"), evaluate(context, "'haystack,needle'"), context))
        fail("private string inclusion coercion order mismatch");
    const throwing_haystack = evaluate(context, "({ toString() { throw 901; } })");
    if (JSC__JSValue__stringIncludes(throwing_haystack, context, coercion_needle) or
        !JSGlobalObject__hasException(context))
        fail("private string receiver coercion did not throw");
    const string_receiver_exception = JSGlobalObject__tryTakeException(context);
    if (JSC__Exception__asJSValue(string_receiver_exception.cellPointer()) != EncodedValue.fromInt32(901))
        fail("private string receiver thrown value mismatch");
    const throwing_needle = evaluate(context, "({ toString() { throw 902; } })");
    if (JSC__JSValue__stringIncludes(encoded_text, sibling_context, throwing_needle) or
        !JSGlobalObject__hasException(context))
        fail("private string search coercion did not throw");
    const string_search_exception = JSGlobalObject__tryTakeException(context);
    if (JSC__Exception__asJSValue(string_search_exception.cellPointer()) != EncodedValue.fromInt32(902))
        fail("private string search thrown value mismatch");
    if (JSC__JSValue__stringIncludes(encoded_text, context, EncodedValue.fromRef(foreign_object)) or
        !JSGlobalObject__hasException(context))
        fail("private string inclusion foreign value did not throw");
    JSGlobalObject__clearException(context);

    const class_constructor = evaluate(context, "class PrivateClass {}; PrivateClass");
    const ordinary_function = evaluate(context, "function ordinary() {}; ordinary");
    const bound_class = evaluate(context, "(class BoundClass {}).bind(null)");
    const proxied_class = evaluate(context, "new Proxy(class ProxiedClass {}, {})");
    if (!JSC__JSValue__isClass(class_constructor, context) or
        JSC__JSValue__isClass(ordinary_function, context) or
        JSC__JSValue__isClass(evaluate(context, "() => {}"), context) or
        JSC__JSValue__isClass(bound_class, context) or
        !JSC__JSValue__isClass(evaluate(context, "Array"), context) or
        !JSC__JSValue__isClass(proxied_class, sibling_context) or
        JSC__JSValue__isClass(encoded_object, context) or
        JSC__JSValue__isClass(.null, context) or
        JSC__JSValue__isClass(EncodedValue.fromRef(foreign_object), context))
        fail("private class classification mismatch");

    const aggregate_error = evaluate(context, "globalThis.__private_aggregate = new AggregateError([], 'x'); __private_aggregate");
    const aggregate_subclass = evaluate(context, "class PrivateAggregate extends AggregateError {}; new PrivateAggregate([])");
    const spoofed_aggregate = evaluate(context, "({ name: 'AggregateError', __proto__: AggregateError.prototype })");
    if (!JSC__JSValue__isAggregateError(aggregate_error, context) or
        !JSC__JSValue__isAggregateError(aggregate_subclass, sibling_context) or
        JSC__JSValue__isAggregateError(evaluate(context, "new Error('x')"), context) or
        JSC__JSValue__isAggregateError(spoofed_aggregate, context) or
        JSC__JSValue__isAggregateError(.undefined, context) or
        JSC__JSValue__isAggregateError(EncodedValue.fromRef(foreign_object), context))
        fail("private AggregateError classification mismatch");
    _ = evaluate(context, "__private_aggregate.name = 'Error'; Object.setPrototypeOf(__private_aggregate, null)");
    if (!JSC__JSValue__isAggregateError(aggregate_error, context))
        fail("private AggregateError classification depended on mutable properties");

    const internal_promise = JSC__JSValue__createInternalPromise(context);
    const created_promise_cell = JSC__JSPromise__create(sibling_context) orelse fail("private JSPromise creation failed");
    const created_promise = EncodedValue.fromBits(@intFromPtr(created_promise_cell));
    if (internal_promise == .empty or
        JSC__JSValue__asPromise(internal_promise) != internal_promise.cellPointer() or
        JSC__JSValue__asInternalPromise(internal_promise) != internal_promise.cellPointer() or
        JSC__JSValue__asPromise(created_promise) != created_promise_cell or
        JSC__JSValue__asInternalPromise(created_promise) != created_promise_cell or
        JSC__JSValue__asPromise(.undefined) != null or
        JSC__JSValue__asInternalPromise(encoded_object) != null or
        JSC__JSValue__asPromise(primitive_exception) != null)
        fail("private Promise creation/downcast mismatch");
    if (!JSC__JSValue__isStrictEqual(
        JSC__JSValue__getPrototype(created_promise, sibling_context),
        evaluate(sibling_context, "Promise.prototype"),
        sibling_context,
    )) fail("private Promise selected-realm prototype mismatch");
    expectPromise(context, internal_promise, .pending, null);
    expectPromise(sibling_context, created_promise, .pending, null);

    const direct_value = evaluate(context, "globalThis.__private_direct_value = { marker: 1 }; __private_direct_value");
    const strong = Bun__StrongRef__new(context, direct_value) orelse fail("private StrongRef creation failed");
    const strong_slot: *const EncodedValue = @ptrCast(@alignCast(strong));
    if (strong_slot.* != direct_value)
        fail("private StrongRef direct slot identity mismatch");
    const sibling_strong_value = evaluate(sibling_context, "globalThis.__private_strong_sibling = { marker: 2 }; __private_strong_sibling");
    Bun__StrongRef__set(strong, sibling_context, sibling_strong_value);
    if (strong_slot.* != sibling_strong_value)
        fail("private StrongRef sibling set mismatch");
    Bun__StrongRef__set(strong, foreign_context, evaluate(foreign_context, "({ foreign: true })"));
    if (strong_slot.* != sibling_strong_value)
        fail("private StrongRef accepted foreign VM set");
    Bun__StrongRef__clear(strong);
    Bun__StrongRef__clear(strong);
    if (strong_slot.* != .empty)
        fail("private StrongRef clear mismatch");
    Bun__StrongRef__delete(strong);
    Bun__StrongRef__clear(null);
    Bun__StrongRef__delete(null);

    const weak_context: *anyopaque = @ptrFromInt(0x209);
    const weak = Bun__WeakRef__new(context, direct_value, .fetch_response, weak_context) orelse fail("private WeakRef creation failed");
    if (!JSC__JSValue__isStrictEqual(Bun__WeakRef__get(weak), direct_value, context))
        fail("private WeakRef live identity mismatch");
    Bun__WeakRef__clear(weak);
    Bun__WeakRef__clear(weak);
    if (Bun__WeakRef__get(weak) != .empty)
        fail("private WeakRef clear mismatch");
    Bun__WeakRef__delete(weak);
    if (Bun__WeakRef__new(context, direct_value, .none, null) != null or
        Bun__WeakRef__new(context, EncodedValue.fromInt32(1), .fetch_response, null) != null or
        Bun__WeakRef__get(null) != .empty)
        fail("private WeakRef invalid-input mismatch");
    Bun__WeakRef__clear(null);
    Bun__WeakRef__delete(null);

    const rooted_foreign = evaluate(foreign_context, "({ rootedForeign: true })");
    var marked_state = MarkedArgumentFixtureState{
        .vm = vm,
        .value = direct_value,
        .foreign = rooted_foreign,
    };
    MarkedArgumentBuffer__run(&marked_state, markedArgumentFixtureCallback);
    MarkedArgumentBuffer__run(null, null);
    MarkedArgumentBuffer__append(null, direct_value);
    if (marked_state.calls != 1 or !JSC__JSValue__isStrictEqual(marked_state.value, direct_value, context))
        fail("private MarkedArgumentBuffer callback/root mismatch");

    if (JSCommonJSExtensions__appendFunction(context, direct_value) != 0 or
        JSCommonJSExtensions__appendFunction(context, encoded_text) != 1 or
        JSCommonJSExtensions__appendFunction(context, sibling_strong_value) != 2)
        fail("private CommonJS extension append indices mismatch");
    JSCommonJSExtensions__setFunction(context, 1, sibling_strong_value);
    JSCommonJSExtensions__setFunction(context, 99, direct_value);
    JSCommonJSExtensions__setFunction(context, 1, rooted_foreign);
    if (JSCommonJSExtensions__swapRemove(context, 0) != 2 or
        JSCommonJSExtensions__swapRemove(context, 1) != 1 or
        JSCommonJSExtensions__swapRemove(context, 0) != 0 or
        JSCommonJSExtensions__swapRemove(context, 99) != 99)
        fail("private CommonJS extension swap-remove mismatch");
    if (JSCommonJSExtensions__appendFunction(sibling_context, sibling_strong_value) != 0 or
        JSCommonJSExtensions__swapRemove(sibling_context, 0) != 0 or
        JSCommonJSExtensions__appendFunction(context, rooted_foreign) != std.math.maxInt(u32))
        fail("private CommonJS extension realm/VM ownership mismatch");
    JSC__VM__throwError(vm, context, EncodedValue.fromInt32(212));
    if (JSCommonJSExtensions__appendFunction(context, direct_value) != std.math.maxInt(u32))
        fail("private CommonJS extension ignored pending exception");
    const rooted_container_exception = JSGlobalObject__tryTakeException(context);
    if (JSC__Exception__asJSValue(rooted_container_exception.cellPointer()) != EncodedValue.fromInt32(212))
        fail("private CommonJS extension replaced pending exception");

    const resolved_promise_cell = JSC__JSPromise__resolvedPromise(sibling_context, direct_value) orelse fail("private resolved JSPromise failed");
    const resolved_promise = EncodedValue.fromBits(@intFromPtr(resolved_promise_cell));
    const resolved_value_promise = JSC__JSPromise__resolvedPromiseValue(context, direct_value);
    expectPromise(sibling_context, resolved_promise, .fulfilled, direct_value);
    expectPromise(context, resolved_value_promise, .fulfilled, direct_value);

    const direct_thenable = evaluate(context,
        \\globalThis.__private_thenable_calls = 0;
        \\globalThis.__private_direct_thenable = { then(resolve) { __private_thenable_calls++; resolve(99); } };
        \\__private_direct_thenable;
    );
    const direct_thenable_promise = JSC__JSPromise__resolvedPromiseValue(context, direct_thenable);
    expectPromise(context, direct_thenable_promise, .fulfilled, direct_thenable);
    if (Bun__JSValue__toNumber(evaluate(context, "__private_thenable_calls"), context) != 0)
        fail("private resolved Promise assimilated thenable");

    const rejected_promise_cell = JSC__JSPromise__rejectedPromise(context, EncodedValue.fromInt32(321)) orelse fail("private rejected JSPromise failed");
    const rejected_promise = EncodedValue.fromBits(@intFromPtr(rejected_promise_cell));
    const rejected_value_promise = JSC__JSPromise__rejectedPromiseValue(sibling_context, direct_value);
    expectPromise(context, rejected_promise, .rejected, EncodedValue.fromInt32(321));
    expectPromise(sibling_context, rejected_value_promise, .rejected, direct_value);

    const foreign_promise = JSC__JSValue__createInternalPromise(foreign_context);
    if (JSC__JSValue__asPromise(foreign_promise) != foreign_promise.cellPointer())
        fail("private Promise downcast rejected another live VM");
    if (JSC__JSPromise__resolvedPromiseValue(context, EncodedValue.fromRef(foreign_object)) != .empty or
        !JSGlobalObject__hasException(context))
        fail("private resolved Promise accepted foreign-VM value");
    const foreign_promise_exception = JSGlobalObject__tryTakeException(context);
    const foreign_promise_error = JSC__Exception__asJSValue(foreign_promise_exception.cellPointer());
    if (!JSC__JSValue__isStrictEqual(getProperty(context, foreign_promise_error, "name"), evaluate(context, "'TypeError'"), context))
        fail("private resolved Promise foreign value error mismatch");

    var passthrough_state = PromiseCallbackState{ .value = resolved_value_promise };
    const passthrough = JSC__JSPromise__wrap(context, &passthrough_state, promiseCallback);
    if (passthrough != resolved_value_promise or passthrough_state.calls != 1)
        fail("private JSPromise wrap passthrough mismatch");

    var fulfilled_wrap_state = PromiseCallbackState{ .value = direct_value };
    const fulfilled_wrap = JSC__JSPromise__wrap(sibling_context, &fulfilled_wrap_state, promiseCallback);
    expectPromise(sibling_context, fulfilled_wrap, .fulfilled, direct_value);
    if (fulfilled_wrap_state.calls != 1)
        fail("private JSPromise fulfilled callback count mismatch");

    const wrap_error = evaluate(context, "globalThis.__private_wrap_error = new RangeError('wrapped'); __private_wrap_error");
    var error_wrap_state = PromiseCallbackState{ .value = wrap_error };
    const error_wrap = JSC__JSPromise__wrap(context, &error_wrap_state, promiseCallback);
    expectPromise(context, error_wrap, .rejected, wrap_error);

    var thrown_wrap_state = PromiseCallbackState{ .value = EncodedValue.fromInt32(777) };
    const thrown_wrap = JSC__JSPromise__wrap(context, &thrown_wrap_state, throwingPromiseCallback);
    if (JSGlobalObject__hasException(context))
        fail("private JSPromise wrap did not consume callback exception");
    expectPromise(context, thrown_wrap, .rejected, EncodedValue.fromInt32(777));

    var foreign_wrap_state = PromiseCallbackState{ .value = EncodedValue.fromRef(foreign_object) };
    const foreign_wrap = JSC__JSPromise__wrap(context, &foreign_wrap_state, promiseCallback);
    if (JSGlobalObject__hasException(context))
        fail("private JSPromise wrap leaked invalid callback exception");
    exposeCell(context, "__private_foreign_wrap", foreign_wrap);
    _ = evaluate(context, "globalThis.__private_foreign_wrap_name = ''; __private_foreign_wrap.catch(error => { __private_foreign_wrap_name = error.name; });");
    if (!JSC__JSValue__isStrictEqual(evaluate(context, "__private_foreign_wrap_name"), evaluate(context, "'TypeError'"), context))
        fail("private JSPromise wrap foreign callback error mismatch");

    const any_fulfilled = JSC__JSValue__createInternalPromise(context);
    var any_fulfilled_state = PromiseCallbackState{ .value = direct_value };
    JSC__AnyPromise__wrap(context, any_fulfilled, &any_fulfilled_state, promiseCallback);
    expectPromise(context, any_fulfilled, .fulfilled, direct_value);

    const any_rejected = JSC__JSValue__createInternalPromise(context);
    var any_rejected_state = PromiseCallbackState{ .value = wrap_error };
    JSC__AnyPromise__wrap(context, any_rejected, &any_rejected_state, promiseCallback);
    expectPromise(context, any_rejected, .rejected, wrap_error);

    const any_thrown = JSC__JSValue__createInternalPromise(context);
    var any_thrown_state = PromiseCallbackState{ .value = direct_value };
    JSC__AnyPromise__wrap(context, any_thrown, &any_thrown_state, throwingPromiseCallback);
    if (JSGlobalObject__hasException(context))
        fail("private AnyPromise wrap did not consume callback exception");
    expectPromise(context, any_thrown, .rejected, direct_value);

    const assimilating_thenable = evaluate(context,
        \\globalThis.__private_assimilating_thenable = { then(resolve) { resolve(55); } };
        \\__private_assimilating_thenable;
    );
    const any_assimilated = JSC__JSValue__createInternalPromise(context);
    var any_assimilated_state = PromiseCallbackState{ .value = assimilating_thenable };
    JSC__AnyPromise__wrap(context, any_assimilated, &any_assimilated_state, promiseCallback);
    expectPromise(context, any_assimilated, .fulfilled, EncodedValue.fromInt32(55));

    const any_self = JSC__JSValue__createInternalPromise(context);
    var any_self_state = PromiseCallbackState{ .value = any_self };
    JSC__AnyPromise__wrap(context, any_self, &any_self_state, promiseCallback);
    exposeCell(context, "__private_self_promise", any_self);
    _ = evaluate(context, "globalThis.__private_self_name = ''; __private_self_promise.catch(error => { __private_self_name = error.name; });");
    if (!JSC__JSValue__isStrictEqual(evaluate(context, "__private_self_name"), evaluate(context, "'TypeError'"), context))
        fail("private AnyPromise self-resolution mismatch");

    var settled_wrap_state = PromiseCallbackState{ .value = EncodedValue.fromInt32(999) };
    JSC__AnyPromise__wrap(context, resolved_value_promise, &settled_wrap_state, promiseCallback);
    expectPromise(context, resolved_value_promise, .fulfilled, direct_value);
    if (settled_wrap_state.calls != 1)
        fail("private AnyPromise settled callback count mismatch");

    var invalid_target_state = PromiseCallbackState{ .value = .true };
    JSC__AnyPromise__wrap(context, encoded_object, &invalid_target_state, promiseCallback);
    if (invalid_target_state.calls != 0 or !JSGlobalObject__hasException(context))
        fail("private AnyPromise invalid target handling mismatch");
    const invalid_target_exception = JSGlobalObject__tryTakeException(context);
    const invalid_target_error = JSC__Exception__asJSValue(invalid_target_exception.cellPointer());
    if (!JSC__JSValue__isStrictEqual(getProperty(context, invalid_target_error, "name"), evaluate(context, "'TypeError'"), context))
        fail("private AnyPromise invalid target error mismatch");

    const map_cell = JSC__JSMap__create(sibling_context) orelse fail("private JSMap creation failed");
    const map_value = EncodedValue.fromBits(@intFromPtr(map_cell));
    exposeCell(sibling_context, "__private_native_map", map_value);
    if (!JSC__JSValue__isStrictEqual(
        JSC__JSValue__getPrototype(map_value, sibling_context),
        evaluate(sibling_context, "Map.prototype"),
        sibling_context,
    ) or JSC__JSMap__size(map_cell, context) != 0 or
        JSC__JSMap__get(map_cell, context, EncodedValue.fromInt32(1)) != .undefined or
        JSC__JSMap__has(map_cell, context, EncodedValue.fromInt32(1)) or
        JSC__JSMap__remove(map_cell, context, EncodedValue.fromInt32(1)))
        fail("private JSMap empty/realm mismatch");

    const sibling_map_value = evaluate(sibling_context, "globalThis.__private_map_value = { sibling: true }; __private_map_value");
    JSC__JSMap__set(map_cell, context, evaluate(context, "'a'"), direct_value);
    JSC__JSMap__set(map_cell, sibling_context, evaluate(sibling_context, "'b'"), sibling_map_value);
    JSC__JSMap__set(map_cell, context, evaluate(context, "'a'"), wrap_error);
    if (JSC__JSMap__size(map_cell, context) != 2 or
        !JSC__JSValue__isStrictEqual(JSC__JSMap__get(map_cell, context, evaluate(context, "'a'")), wrap_error, context) or
        !JSC__JSValue__isStrictEqual(JSC__JSMap__get(map_cell, context, evaluate(context, "'b'")), sibling_map_value, context) or
        !JSC__JSValue__isStrictEqual(evaluate(sibling_context, "Array.from(__private_native_map.keys()).join(',')"), evaluate(context, "'a,b'"), context))
        fail("private JSMap insert/update/order mismatch");

    JSC__JSMap__set(map_cell, context, evaluate(context, "NaN"), EncodedValue.fromInt32(11));
    JSC__JSMap__set(map_cell, context, EncodedValue.fromDouble(-0.0), EncodedValue.fromInt32(12));
    const equal_string_key = evaluate(context, "'same-key'");
    JSC__JSMap__set(map_cell, context, equal_string_key, EncodedValue.fromInt32(13));
    if (JSC__JSMap__get(map_cell, context, EncodedValue.fromDouble(std.math.nan(f64))) != EncodedValue.fromInt32(11) or
        JSC__JSMap__get(map_cell, context, EncodedValue.fromDouble(0.0)) != EncodedValue.fromInt32(12) or
        JSC__JSMap__get(map_cell, context, evaluate(context, "'same-' + 'key'")) != EncodedValue.fromInt32(13) or
        !JSC__JSMap__has(map_cell, context, EncodedValue.fromDouble(std.math.nan(f64))))
        fail("private JSMap SameValueZero mismatch");

    const identity_key = evaluate(context, "globalThis.__private_map_identity_key = {}; __private_map_identity_key");
    const other_identity_key = evaluate(context, "({})");
    JSC__JSMap__set(map_cell, context, identity_key, EncodedValue.fromInt32(14));
    if (JSC__JSMap__get(map_cell, context, identity_key) != EncodedValue.fromInt32(14) or
        JSC__JSMap__has(map_cell, context, other_identity_key))
        fail("private JSMap object identity mismatch");

    if (!JSC__JSMap__remove(map_cell, context, evaluate(context, "'a'")) or
        JSC__JSMap__remove(map_cell, context, evaluate(context, "'a'")))
        fail("private JSMap removal mismatch");
    JSC__JSMap__set(map_cell, context, evaluate(context, "'a'"), direct_value);
    if (!JSC__JSValue__isStrictEqual(
        evaluate(sibling_context, "Array.from(__private_native_map.keys()).slice(-2).join(',')"),
        evaluate(context, "'[object Object],a'"),
        context,
    )) fail("private JSMap reinsertion order mismatch");

    _ = evaluate(sibling_context,
        \\Map.prototype.set = function () { throw 901; };
        \\Map.prototype.get = function () { throw 902; };
        \\Object.defineProperty(Map.prototype, 'size', { get() { throw 903; }, configurable: true });
    );
    JSC__JSMap__set(map_cell, sibling_context, evaluate(context, "'direct'"), EncodedValue.fromInt32(15));
    if (JSC__JSMap__get(map_cell, sibling_context, evaluate(context, "'direct'")) != EncodedValue.fromInt32(15) or
        JSC__JSMap__size(map_cell, sibling_context) == 0 or JSGlobalObject__hasException(context))
        fail("private JSMap invoked mutable prototype methods");

    const size_before_foreign = JSC__JSMap__size(map_cell, context);
    JSC__JSMap__set(map_cell, context, EncodedValue.fromRef(foreign_object), direct_value);
    if (!JSGlobalObject__hasException(context))
        fail("private JSMap foreign key did not preserve first exception");
    const foreign_map_key_exception = JSGlobalObject__tryTakeException(context);
    const foreign_map_key_error = JSC__Exception__asJSValue(foreign_map_key_exception.cellPointer());
    if (!JSC__JSValue__isStrictEqual(getProperty(context, foreign_map_key_error, "name"), evaluate(context, "'TypeError'"), context) or
        JSC__JSMap__size(map_cell, context) != size_before_foreign)
        fail("private JSMap foreign key failure atomicity mismatch");

    JSC__JSMap__set(map_cell, context, evaluate(context, "'foreign-value'"), EncodedValue.fromRef(foreign_object));
    if (!JSGlobalObject__hasException(context))
        fail("private JSMap foreign value did not throw");
    JSGlobalObject__clearException(context);
    if (JSC__JSMap__has(map_cell, context, evaluate(context, "'foreign-value'")))
        fail("private JSMap foreign value mutated map");

    const weak_map = evaluate(context, "new WeakMap()");
    if (JSC__JSMap__get(encoded_object.cellPointer(), context, .true) != .empty or
        !JSGlobalObject__hasException(context))
        fail("private JSMap ordinary-object receiver accepted");
    JSGlobalObject__clearException(context);
    if (JSC__JSMap__size(weak_map.cellPointer(), context) != 0 or !JSGlobalObject__hasException(context))
        fail("private JSMap WeakMap receiver accepted");
    JSGlobalObject__clearException(context);
    const foreign_map_cell = JSC__JSMap__create(foreign_context) orelse fail("foreign private JSMap creation failed");
    if (JSC__JSMap__has(foreign_map_cell, context, .true) or !JSGlobalObject__hasException(context))
        fail("private JSMap foreign receiver accepted");
    JSGlobalObject__clearException(context);

    JSC__VM__throwError(vm, context, EncodedValue.fromInt32(444));
    JSC__JSMap__set(map_cell, context, evaluate(context, "'blocked'"), .true);
    const preserved_map_exception = JSGlobalObject__tryTakeException(context);
    if (JSC__Exception__asJSValue(preserved_map_exception.cellPointer()) != EncodedValue.fromInt32(444) or
        JSC__JSMap__has(map_cell, context, evaluate(context, "'blocked'")))
        fail("private JSMap replaced pending exception or mutated state");

    JSC__JSMap__clear(map_cell, context);
    if (JSC__JSMap__size(map_cell, context) != 0 or
        JSC__JSMap__has(map_cell, context, evaluate(context, "NaN")) or
        JSC__JSMap__get(map_cell, context, evaluate(context, "'direct'")) != .undefined)
        fail("private JSMap clear mismatch");

    var release_scope: [8]u8 align(8) = @splat(0xa5);
    var verification_scope: [56]u8 align(8) = @splat(0xa5);
    var foreign_scope: [8]u8 align(8) = @splat(0xa5);
    TopExceptionScope__construct(&release_scope, context, "main", "home_private_value_shims.zig", 1, release_scope.len, 8);
    TopExceptionScope__construct(&verification_scope, sibling_context, "main", "home_private_value_shims.zig", 2, verification_scope.len, 8);
    TopExceptionScope__construct(&foreign_scope, foreign_context, "main", "home_private_value_shims.zig", 3, foreign_scope.len, 8);
    if (TopExceptionScope__pureException(&release_scope) != null or
        TopExceptionScope__exceptionIncludingTraps(&verification_scope) != null or
        TopExceptionScope__pureException(null) != null or
        TopExceptionScope__exceptionIncludingTraps(null) != null)
        fail("private TopExceptionScope initial state mismatch");

    JSC__VM__throwError(vm, sibling_context, EncodedValue.fromInt32(2061));
    const normal_scope_exception = TopExceptionScope__pureException(&release_scope) orelse fail("private scope missed normal exception");
    if (TopExceptionScope__exceptionIncludingTraps(&verification_scope) != normal_scope_exception or
        JSC__Exception__asJSValue(normal_scope_exception) != EncodedValue.fromInt32(2061) or
        JSC__JSValue__isTerminationException(JSC__Exception__asJSValue(normal_scope_exception)))
        fail("private TopExceptionScope normal exception mismatch");
    TopExceptionScope__clearException(&verification_scope);
    TopExceptionScope__assertNoException(&release_scope);
    if (JSGlobalObject__hasException(context))
        fail("private TopExceptionScope clear was not VM-shared");

    JSGlobalObject__requestTermination(sibling_context);
    if (!JSC__VM__hasTerminationRequest(vm) or !JSC__VM__hasTerminationRequest(sibling_vm) or
        JSC__VM__hasTerminationRequest(foreign_vm) or
        TopExceptionScope__pureException(&release_scope) != null)
        fail("private termination request sharing/pure lookup mismatch");
    const termination_exception = TopExceptionScope__exceptionIncludingTraps(&verification_scope) orelse fail("private trap lookup missed termination");
    const encoded_termination = JSC__Exception__asJSValue(termination_exception);
    if (TopExceptionScope__pureException(&release_scope) != termination_exception)
        fail("private termination materialization identity mismatch");
    if (!JSC__JSValue__isTerminationException(encoded_termination))
        fail("private termination exception classification mismatch");
    if (!JSGlobalObject__hasException(context))
        fail("private termination materialization did not publish");
    if (JSGlobalObject__clearExceptionExceptTermination(context))
        fail("private selective clear removed termination");

    TopExceptionScope__clearException(&release_scope);
    if (JSGlobalObject__hasException(context) or !JSC__VM__hasTerminationRequest(vm) or
        TopExceptionScope__exceptionIncludingTraps(&verification_scope) != termination_exception)
        fail("private termination identity/rematerialization mismatch");
    JSGlobalObject__clearTerminationException(sibling_context);
    if (JSC__VM__hasTerminationRequest(vm) or JSGlobalObject__hasException(context) or
        TopExceptionScope__pureException(&release_scope) != null)
        fail("private termination clear mismatch");
    TopExceptionScope__assertNoException(&verification_scope);

    JSC__VM__throwError(vm, context, EncodedValue.fromInt32(2062));
    if (!JSGlobalObject__clearExceptionExceptTermination(sibling_context) or JSGlobalObject__hasException(context))
        fail("private normal exception selective clear mismatch");
    JSC__VM__notifyNeedTermination(sibling_vm);
    if (!JSC__VM__hasTerminationRequest(vm))
        fail("private VM termination notification mismatch");
    JSC__VM__clearHasTerminationRequest(vm);
    if (JSC__VM__hasTerminationRequest(sibling_vm))
        fail("private VM termination request clear mismatch");
    JSC__VM__notifyNeedTermination(foreign_vm);
    if (!JSC__VM__hasTerminationRequest(foreign_vm) or JSC__VM__hasTerminationRequest(vm))
        fail("private foreign VM termination isolation mismatch");
    JSC__VM__clearHasTerminationRequest(foreign_vm);

    if (JSC__VM__executionForbidden(vm) or JSC__VM__executionForbidden(null))
        fail("private VM execution-forbidden initial state mismatch");
    JSC__VM__setExecutionForbidden(vm, false);
    if (!JSC__VM__executionForbidden(sibling_vm) or JSC__VM__executionForbidden(foreign_vm))
        fail("private VM execution-forbidden pinned behavior mismatch");

    const created_oom = JSGlobalObject__createOutOfMemoryError(sibling_context);
    if (created_oom == .empty or JSGlobalObject__hasException(context) or !JSC__JSValue__isAnyError(created_oom))
        fail("private OOM creation mismatch");
    exposeCell(sibling_context, "__private_created_oom", created_oom);
    if (!JSC__JSValue__toBoolean(evaluate(sibling_context, "__private_created_oom instanceof OutOfMemoryError && Object.getPrototypeOf(__private_created_oom) === OutOfMemoryError.prototype && __private_created_oom.name === 'OutOfMemoryError' && __private_created_oom.message === 'Out of memory'")))
        fail("private OOM selected-realm metadata mismatch");

    JSGlobalObject__throwOutOfMemoryError(context);
    const thrown_oom_cell = TopExceptionScope__pureException(&verification_scope) orelse fail("private OOM throw did not publish");
    const thrown_oom = JSC__Exception__asJSValue(thrown_oom_cell);
    exposeCell(context, "__private_thrown_oom", thrown_oom);
    if (!JSC__JSValue__toBoolean(evaluate(context, "__private_thrown_oom instanceof OutOfMemoryError && Object.getPrototypeOf(__private_thrown_oom) === OutOfMemoryError.prototype && __private_thrown_oom.name === 'OutOfMemoryError' && __private_thrown_oom.message === 'Out of memory'")))
        fail("private OOM throw metadata mismatch");
    TopExceptionScope__clearException(&release_scope);

    JSGlobalObject__throwStackOverflow(sibling_context);
    const thrown_stack_cell = TopExceptionScope__pureException(&release_scope) orelse fail("private stack overflow did not publish");
    const thrown_stack = JSC__Exception__asJSValue(thrown_stack_cell);
    exposeCell(sibling_context, "__private_thrown_stack", thrown_stack);
    if (!JSC__JSValue__toBoolean(evaluate(sibling_context, "Object.getPrototypeOf(__private_thrown_stack) === RangeError.prototype && __private_thrown_stack.name === 'RangeError' && __private_thrown_stack.message === 'Maximum call stack size exceeded'")))
        fail("private stack overflow metadata mismatch");
    TopExceptionScope__clearException(&verification_scope);

    JSC__VM__throwError(vm, context, EncodedValue.fromInt32(2063));
    JSGlobalObject__throwOutOfMemoryError(context);
    JSGlobalObject__throwStackOverflow(context);
    JSGlobalObject__requestTermination(context);
    const preserved_scope_exception = TopExceptionScope__exceptionIncludingTraps(&release_scope) orelse fail("private first pending exception disappeared");
    if (JSC__Exception__asJSValue(preserved_scope_exception) != EncodedValue.fromInt32(2063) or
        JSC__JSValue__isTerminationException(JSC__Exception__asJSValue(preserved_scope_exception)))
        fail("private exception/termination first-wins mismatch");
    TopExceptionScope__clearException(&release_scope);
    if (TopExceptionScope__exceptionIncludingTraps(&verification_scope) != termination_exception)
        fail("private termination exception identity was not stable");
    JSGlobalObject__clearTerminationException(context);

    JSGlobalObject__requestTermination(foreign_context);
    if (TopExceptionScope__exceptionIncludingTraps(&foreign_scope) == null or
        TopExceptionScope__pureException(&release_scope) != null or
        JSC__VM__hasTerminationRequest(vm))
        fail("private foreign TopExceptionScope isolation mismatch");
    JSGlobalObject__clearTerminationException(foreign_context);
    TopExceptionScope__assertNoException(&foreign_scope);

    const heap_before = JSC__VM__heapSize(vm);
    const block_before = JSC__VM__blockBytesAllocated(vm);
    if (heap_before == 0 or block_before != heap_before or
        JSC__VM__heapSize(sibling_vm) != heap_before or
        JSC__VM__externalMemorySize(vm) != 0 or
        JSC__VM__heapSize(null) != 0 or
        JSC__VM__blockBytesAllocated(null) != 0 or
        JSC__VM__externalMemorySize(null) != 0)
        fail("private VM initial heap accounting mismatch");

    JSC__VM__reportExtraMemory(sibling_vm, 4096);
    if (JSC__VM__heapSize(vm) != heap_before or
        JSC__VM__blockBytesAllocated(vm) != heap_before + 4096 or
        JSC__VM__externalMemorySize(vm) != 0 or
        JSC__VM__blockBytesAllocated(foreign_vm) == std.math.maxInt(usize))
        fail("private VM extra/external memory accounting mismatch");
    JSC__VM__reportExtraMemory(foreign_vm, std.math.maxInt(usize));
    JSC__VM__reportExtraMemory(foreign_vm, 1);
    if (JSC__VM__blockBytesAllocated(foreign_vm) != std.math.maxInt(usize) or
        JSC__VM__blockBytesAllocated(vm) != heap_before + 4096)
        fail("private VM saturating/foreign memory accounting mismatch");

    const idle_promise = JSC__JSValue__createInternalPromise(context);
    exposeCell(context, "__private_idle_promise", idle_promise);
    _ = evaluate(context, "globalThis.__private_idle_done = 0; __private_idle_promise.then(() => { __private_idle_done = 1; });");
    var idle_state = PromiseCallbackState{ .value = .undefined };
    JSC__AnyPromise__wrap(context, idle_promise, &idle_state, promiseCallback);
    const global_value = EncodedValue.fromBits(@intFromPtr(JSContextGetGlobalObject(context) orelse fail("private VM global lookup failed")));
    if (getNumberProperty(context, global_value, "__private_idle_done") != 0)
        fail("private VM idle work ran before checkpoint");
    JSC__VM__performOpportunisticallyScheduledTasks(vm, 0);
    if (getNumberProperty(context, global_value, "__private_idle_done") != 0)
        fail("private VM zero-duration checkpoint ran work");
    JSC__VM__collectAsync(sibling_vm);
    JSC__VM__performOpportunisticallyScheduledTasks(vm, 1);
    if (getNumberProperty(context, global_value, "__private_idle_done") != 1 or idle_state.calls != 1)
        fail("private VM opportunistic checkpoint mismatch");

    var native_microtask = MicrotaskCallbackState{ .global = context, .requeue = true };
    JSC__JSGlobalObject__queueMicrotaskCallback(context, &native_microtask, microtaskCallback);
    const sibling_job = evaluate(sibling_context,
        \\globalThis.__private_job_calls = 0;
        \\globalThis.__private_job_first = undefined;
        \\globalThis.__private_job_second = 1;
        \\(first, second) => { __private_job_calls++; __private_job_first = first; __private_job_second = second; };
    );
    JSC__JSGlobalObject__queueMicrotaskJob(sibling_context, sibling_job, direct_value, .empty);
    if (JSC__JSGlobalObject__drainMicrotasks(context) != 0 or native_microtask.calls != 2 or !native_microtask.entry_observed or
        getNumberProperty(sibling_context, EncodedValue.fromBits(@intFromPtr(JSContextGetGlobalObject(sibling_context).?)), "__private_job_calls") != 0)
        fail("private selected-realm/reentrant microtask drain mismatch");
    JSC__VM__drainMicrotasks(vm);
    if (getNumberProperty(sibling_context, EncodedValue.fromBits(@intFromPtr(JSContextGetGlobalObject(sibling_context).?)), "__private_job_calls") != 1)
        fail("private VM microtask job call-count mismatch");
    if (!JSC__JSValue__isStrictEqual(evaluate(sibling_context, "__private_job_first"), direct_value, sibling_context))
        fail("private VM microtask first-argument identity mismatch");
    if (!JSC__JSValue__isStrictEqual(evaluate(sibling_context, "__private_job_second"), .undefined, sibling_context))
        fail("private VM microtask empty-argument normalization mismatch");

    const throwing_job = evaluate(context, "() => { throw 2081; }");
    const following_job = evaluate(context, "() => { globalThis.__private_after_throw = 1; }");
    _ = evaluate(context, "globalThis.__private_after_throw = 0");
    JSC__JSGlobalObject__queueMicrotaskJob(context, throwing_job, .empty, .empty);
    JSC__JSGlobalObject__queueMicrotaskJob(context, following_job, .empty, .empty);
    if (JSC__JSGlobalObject__drainMicrotasks(context) != 0 or !JSGlobalObject__hasException(context) or
        getNumberProperty(context, global_value, "__private_after_throw") != 0)
        fail("private throwing microtask checkpoint mismatch");
    const microtask_exception = JSGlobalObject__tryTakeException(context);
    if (JSC__Exception__asJSValue(microtask_exception.cellPointer()) != EncodedValue.fromInt32(2081))
        fail("private microtask throw identity mismatch");
    if (JSC__JSGlobalObject__drainMicrotasks(context) != 0 or
        getNumberProperty(context, global_value, "__private_after_throw") != 1)
        fail("private post-throw microtask preservation mismatch");

    const foreign_job = evaluate(foreign_context, "() => 1");
    JSC__JSGlobalObject__queueMicrotaskJob(context, foreign_job, .empty, .empty);
    if (!JSGlobalObject__hasException(context))
        fail("private microtask accepted foreign-VM callable");
    JSGlobalObject__clearException(context);

    _ = evaluate(context,
        \\globalThis.__private_unhandled = [];
        \\globalThis.onunhandledrejection = reason => { __private_unhandled.push(reason); };
        \\Promise.reject(2082);
    );
    JSC__JSGlobalObject__handleRejectedPromises(context);
    JSC__JSGlobalObject__handleRejectedPromises(context);
    if (!JSC__JSValue__isStrictEqual(evaluate(context, "__private_unhandled.join(',')"), evaluate(context, "'2082'"), context))
        fail("private unhandled rejection notification count mismatch");
    _ = evaluate(context, "const __private_late_handled = Promise.reject(2083); __private_late_handled.catch(() => {});");
    JSC__JSGlobalObject__handleRejectedPromises(context);
    if (!JSC__JSValue__isStrictEqual(evaluate(context, "__private_unhandled.join(',')"), evaluate(context, "'2082'"), context))
        fail("private handled rejection emitted notification");

    JSGlobalObject__requestTermination(context);
    if (JSC__JSGlobalObject__drainMicrotasks(sibling_context) != 1)
        fail("private microtask drain missed VM termination");
    JSGlobalObject__clearTerminationException(context);

    const unused_module_key_bytes = "not-loaded.js";
    const unused_module_key = ZigString{ .tagged_ptr = @intFromPtr(unused_module_key_bytes.ptr), .len = unused_module_key_bytes.len };
    JSC__JSGlobalObject__deleteModuleRegistryEntry(context, &unused_module_key);
    JSC__JSGlobalObject__deleteModuleRegistryEntry(null, &unused_module_key);
    _ = evaluate(context,
        \\function __private_hot_after_delete(n) { let total = 0; for (let i = 0; i < n; i++) total += i; return total; }
        \\for (let i = 0; i < 4; i++) __private_hot_after_delete(1000);
    );
    JSC__VM__deleteAllCode(foreign_vm, context);
    JSC__VM__deleteAllCode(vm, context);
    JSC__VM__deleteAllCode(null, context);
    if (Bun__JSValue__toNumber(evaluate(context, "__private_hot_after_delete(10)"), context) != 45)
        fail("private delete-all-code bytecode fallback mismatch");

    const heap_after_checkpoint = JSC__VM__heapSize(vm);
    if (JSC__VM__runGC(vm, false) != heap_after_checkpoint or
        JSC__VM__runGC(sibling_vm, true) != JSC__VM__heapSize(vm))
        fail("private VM full collection result mismatch");
    JSC__VM__releaseWeakRefs(vm);
    JSC__VM__shrinkFootprint(sibling_vm);
    JSC__VM__collectAsync(null);
    JSC__VM__performOpportunisticallyScheduledTasks(null, 1);
    JSC__VM__releaseWeakRefs(null);
    JSC__VM__reportExtraMemory(null, 1);
    JSC__VM__shrinkFootprint(null);
    if (JSC__VM__runGC(null, true) != 0)
        fail("private VM null collection mismatch");

    JSC__VM__throwError(vm, context, EncodedValue.fromInt32(207));
    JSC__VM__collectAsync(vm);
    JSC__VM__performOpportunisticallyScheduledTasks(vm, 1);
    JSC__VM__releaseWeakRefs(vm);
    JSC__VM__shrinkFootprint(vm);
    const preserved_gc_exception = JSGlobalObject__tryTakeException(context);
    if (JSC__Exception__asJSValue(preserved_gc_exception.cellPointer()) != EncodedValue.fromInt32(207))
        fail("private VM collection replaced pending exception");

    TopExceptionScope__clearException(null);
    TopExceptionScope__assertNoException(null);
    TopExceptionScope__destruct(null);
    TopExceptionScope__destruct(&foreign_scope);
    TopExceptionScope__destruct(&verification_scope);
    TopExceptionScope__destruct(&release_scope);
    if (TopExceptionScope__pureException(&release_scope) != null or
        TopExceptionScope__exceptionIncludingTraps(&verification_scope) != null)
        fail("private TopExceptionScope destruction mismatch");

    std.debug.print("Home private value shims: 228/228 symbols linked; runtime matrix passed\n", .{});
}
