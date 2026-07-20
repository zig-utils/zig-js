const std = @import("std");

const JSContextRef = ?*anyopaque;
const JSValueRef = ?*anyopaque;
const JSObjectRef = ?*anyopaque;
const JSStringRef = ?*anyopaque;
const JSClassRef = ?*anyopaque;
const ExceptionRef = [*c]JSValueRef;

const JSObjectInitializeCallback = ?*const fn (JSContextRef, JSObjectRef) callconv(.c) void;
const JSObjectFinalizeCallback = ?*const fn (JSObjectRef) callconv(.c) void;
const JSObjectHasPropertyCallback = ?*const fn (JSContextRef, JSObjectRef, JSStringRef) callconv(.c) bool;
const JSObjectGetPropertyCallback = ?*const fn (JSContextRef, JSObjectRef, JSStringRef, ExceptionRef) callconv(.c) JSValueRef;
const JSObjectSetPropertyCallback = ?*const fn (JSContextRef, JSObjectRef, JSStringRef, JSValueRef, ExceptionRef) callconv(.c) bool;
const JSObjectDeletePropertyCallback = ?*const fn (JSContextRef, JSObjectRef, JSStringRef, ExceptionRef) callconv(.c) bool;
const JSObjectGetPropertyNamesCallback = ?*const fn (JSContextRef, JSObjectRef, ?*anyopaque) callconv(.c) void;
const JSObjectCallAsFunctionCallback = ?*const fn (JSContextRef, JSObjectRef, JSObjectRef, usize, [*c]const JSValueRef, ExceptionRef) callconv(.c) JSValueRef;
const JSObjectCallAsConstructorCallback = ?*const fn (JSContextRef, JSObjectRef, usize, [*c]const JSValueRef, ExceptionRef) callconv(.c) JSObjectRef;
const JSObjectHasInstanceCallback = ?*const fn (JSContextRef, JSObjectRef, JSValueRef, ExceptionRef) callconv(.c) bool;
const JSObjectConvertToTypeCallback = ?*const fn (JSContextRef, JSObjectRef, c_uint, ExceptionRef) callconv(.c) JSValueRef;

const JSStaticValue = extern struct {
    name: ?[*:0]const u8 = null,
    get_property: JSObjectGetPropertyCallback = null,
    set_property: JSObjectSetPropertyCallback = null,
    attributes: c_uint = 0,
};

const JSStaticFunction = extern struct {
    name: ?[*:0]const u8 = null,
    call_as_function: JSObjectCallAsFunctionCallback = null,
    attributes: c_uint = 0,
};

const JSClassDefinition = extern struct {
    version: c_int = 0,
    attributes: c_uint = 0,
    class_name: ?[*:0]const u8 = null,
    parent_class: JSClassRef = null,
    static_values: [*c]const JSStaticValue = null,
    static_functions: [*c]const JSStaticFunction = null,
    initialize: JSObjectInitializeCallback = null,
    finalize: JSObjectFinalizeCallback = null,
    has_property: JSObjectHasPropertyCallback = null,
    get_property: JSObjectGetPropertyCallback = null,
    set_property: JSObjectSetPropertyCallback = null,
    delete_property: JSObjectDeletePropertyCallback = null,
    get_property_names: JSObjectGetPropertyNamesCallback = null,
    call_as_function: JSObjectCallAsFunctionCallback = null,
    call_as_constructor: JSObjectCallAsConstructorCallback = null,
    has_instance: JSObjectHasInstanceCallback = null,
    convert_to_type: JSObjectConvertToTypeCallback = null,
};

extern "c" fn tmpfile() ?*std.c.FILE;
extern "c" fn fileno(*std.c.FILE) c_int;
extern "c" fn fflush(*std.c.FILE) c_int;

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

    fn isInt32(value: EncodedValue) bool {
        return @as(u64, @bitCast(@intFromEnum(value))) & 0xfffe_0000_0000_0000 == 0xfffe_0000_0000_0000;
    }

    fn isNumber(value: EncodedValue) bool {
        return @as(u64, @bitCast(@intFromEnum(value))) & 0xfffe_0000_0000_0000 != 0;
    }

    fn isCell(value: EncodedValue) bool {
        if (value == .empty or value == .deleted) return false;
        return @as(u64, @bitCast(@intFromEnum(value))) & 0xfffe_0000_0000_0002 == 0;
    }

    fn fromRef(value: JSValueRef) EncodedValue {
        return fromBits(@intFromPtr(value.?));
    }

    fn cellPointer(value: EncodedValue) ?*anyopaque {
        if (!value.isCell() or value.isNumber()) return null;
        const bits: u64 = @bitCast(@intFromEnum(value));
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

const CommonStringsForZig = enum(u8) {
    IPv4 = 0,
    IPv6 = 1,
    IN4Loopback = 2,
    IN6Any = 3,
    ipv4Lower = 4,
    ipv6Lower = 5,
    fetchDefault = 6,
    fetchError = 7,
    fetchInclude = 8,
    buffer = 9,
    binaryTypeArrayBuffer = 10,
    binaryTypeNodeBuffer = 11,
    binaryTypeUint8Array = 12,
    _,
};

const DebuggerAsyncCallType = enum(u8) {
    DOMTimer = 1,
    EventListener = 2,
    PostMessage = 3,
    RequestAnimationFrame = 4,
    Microtask = 5,
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
const IterableCallback = *const fn (?*anyopaque, JSContextRef, ?*anyopaque, EncodedValue) callconv(.c) void;
const PropertyCallback = *const fn (JSContextRef, ?*anyopaque, *ZigString, EncodedValue, bool, bool) callconv(.c) void;

const BunStringImpl = extern union {
    zig_string: ZigString,
    wtf_string_impl: ?*WTFStringImpl,
};

const BunString = extern struct {
    tag: BunStringTag,
    value: BunStringImpl,
};

const SerializedScriptExternal = extern struct {
    bytes: ?[*]const u8,
    size: usize,
    handle: ?*anyopaque,
};

const SystemError = extern struct {
    errno: c_int = 0,
    code: BunString = emptyBunString(),
    message: BunString,
    path: BunString = emptyBunString(),
    syscall: BunString = emptyBunString(),
    hostname: BunString = emptyBunString(),
    fd: c_int = std.math.minInt(c_int),
    dest: BunString = emptyBunString(),
};

const ZigStackFrameCode = enum(u8) {
    None = 0,
    Eval = 1,
    Module = 2,
    Function = 3,
    Global = 4,
    Wasm = 5,
    Constructor = 6,
    _,
};

const ZigStackFramePosition = extern struct { line: c_int, column: c_int, line_start_byte: c_int };
const ZigStackFrame = extern struct {
    function_name: BunString,
    source_url: BunString,
    position: ZigStackFramePosition,
    code_type: ZigStackFrameCode,
    is_async: bool,
    remapped: bool = false,
    jsc_stack_frame_index: i32 = -1,
};
const ZigStackTrace = extern struct {
    source_lines_ptr: [*c]BunString,
    source_lines_numbers: [*c]i32,
    source_lines_len: u8,
    source_lines_to_collect: u8,
    frames_ptr: [*c]ZigStackFrame,
    frames_len: u8,
    frames_cap: u8,
    referenced_source_provider: ?*anyopaque = null,
};

const JSErrorCode = enum(u8) {
    Error = 0,
    EvalError = 1,
    RangeError = 2,
    ReferenceError = 3,
    SyntaxError = 4,
    TypeError = 5,
    URIError = 6,
    AggregateError = 7,
    OutOfMemoryError = 8,
    UserErrorCode = 254,
    _,
};

const JSRuntimeType = enum(u16) {
    Nothing = 0,
    Function = 1,
    Undefined = 2,
    Null = 4,
    Boolean = 8,
    AnyInt = 16,
    Number = 32,
    String = 64,
    Object = 128,
    Symbol = 256,
    BigInt = 512,
    _,
};

const ZigException = extern struct {
    type: JSErrorCode,
    runtime_type: JSRuntimeType,
    errno: c_int = 0,
    syscall: BunString,
    system_code: BunString,
    path: BunString,
    name: BunString,
    message: BunString,
    stack: ZigStackTrace,
    exception: ?*anyopaque,
    remapped: bool = false,
    fd: i32 = -1,
    browser_url: BunString,
};

comptime {
    if (@sizeOf(ZigException) != 216 or @alignOf(ZigException) != 8 or
        @offsetOf(ZigException, "stack") != 128 or
        @offsetOf(ZigException, "exception") != 176 or
        @offsetOf(ZigException, "browser_url") != 192)
        @compileError("pinned ZigException layout drifted");
}

const StringBuilder = extern struct {
    bytes: [24]u8 align(8),
};

const JSStringIterator = extern struct {
    data: ?*anyopaque,
    stop: u8,
    append8: ?*const fn (*JSStringIterator, [*]const u8, u32) callconv(.c) void,
    append16: ?*const fn (*JSStringIterator, [*]const u16, u32) callconv(.c) void,
    write8: ?*const fn (*JSStringIterator, [*]const u8, u32, u32) callconv(.c) void,
    write16: ?*const fn (*JSStringIterator, [*]const u16, u32, u32) callconv(.c) void,
};

const PrivateCallFrame = opaque {};
const PrivateArrayBufferHandle = opaque {};
const JSPropertyIterator = opaque {};
const TextCodec = opaque {};
const AbortSignal = opaque {};
const JSHostFn = fn (JSContextRef, *PrivateCallFrame) callconv(.c) EncodedValue;
const ImplementationVisibility = enum(u8) {
    public = 0,
    private = 1,
    private_recursive = 2,
    _,
};
const Intrinsic = enum(u8) { none = 0, _ };

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
    if (@sizeOf(JSStringIterator) != 48 or @offsetOf(JSStringIterator, "append8") != 16)
        @compileError("JSString iterator fixture layout drifted");
    if (@sizeOf(PrivateBunArrayBuffer) != 40 or @offsetOf(PrivateBunArrayBuffer, "cell_type") != 32)
        @compileError("Bun ArrayBuffer fixture layout drifted");
}

extern "c" fn JSGlobalContextCreate(?*anyopaque) JSContextRef;
extern "c" fn JSGlobalContextCreateInGroup(?*anyopaque, ?*anyopaque) JSContextRef;
extern "c" fn ZJSGlobalContextCreateGarbageCollected(bool) JSContextRef;
extern "c" fn JSGlobalContextRelease(JSContextRef) void;
extern "c" fn JSContextGetGroup(JSContextRef) ?*anyopaque;
extern "c" fn JSContextGetGlobalObject(JSContextRef) JSObjectRef;
extern "c" fn JSValueMakeNumber(JSContextRef, f64) JSValueRef;
extern "c" fn JSValueMakeString(JSContextRef, JSStringRef) JSValueRef;
extern "c" fn JSValueToNumber(JSContextRef, JSValueRef, [*c]JSValueRef) f64;
extern "c" fn JSStringCreateWithUTF8CString([*:0]const u8) JSStringRef;
extern "c" fn JSStringRelease(JSStringRef) void;
extern "c" fn JSObjectMake(JSContextRef, ?*anyopaque, ?*anyopaque) JSObjectRef;
extern "c" fn JSClassCreate(?*const JSClassDefinition) JSClassRef;
extern "c" fn JSClassRelease(JSClassRef) void;
extern "c" fn JSObjectGetPrototype(JSContextRef, JSObjectRef) JSValueRef;
extern "c" fn JSObjectSetPrototype(JSContextRef, JSObjectRef, JSValueRef) void;
extern "c" fn JSObjectGetProperty(JSContextRef, JSObjectRef, JSStringRef, [*c]JSValueRef) JSValueRef;
extern "c" fn JSObjectSetProperty(JSContextRef, JSObjectRef, JSStringRef, JSValueRef, c_uint, [*c]JSValueRef) void;
extern "c" fn JSEvaluateScript(JSContextRef, JSStringRef, JSObjectRef, JSStringRef, c_int, [*c]JSValueRef) JSValueRef;
extern "c" fn JSGarbageCollect(JSContextRef) void;
extern "c" fn JSObjectCallAsFunctionReturnValueHoldingAPILock(JSContextRef, JSObjectRef, JSObjectRef, usize, [*c]const JSValueRef) EncodedValue;
extern "c" fn JSObjectGetProxyTarget(JSObjectRef) JSObjectRef;
extern "c" fn Bun__JSC__operationMathPow(f64, f64) f64;
extern "c" fn AsyncContextFrame__withAsyncContextIfNeeded(JSContextRef, EncodedValue) EncodedValue;
extern "c" fn Bun__JSValue__isAsyncContextFrame(EncodedValue) bool;
extern "c" fn Bun__JSValue__call(JSContextRef, EncodedValue, EncodedValue, usize, [*]const EncodedValue) EncodedValue;

extern "c" fn JSC__JSValue__eqlCell(EncodedValue, ?*anyopaque) bool;
extern "c" fn JSC__JSValue__eqlValue(EncodedValue, EncodedValue) bool;
extern "c" fn JSC__JSValue__callCustomInspectFunction(JSContextRef, EncodedValue, EncodedValue, u32, u32, bool) EncodedValue;
extern "c" fn Bun__JSValue__protect(EncodedValue) void;
extern "c" fn Bun__JSValue__unprotect(EncodedValue) void;
extern "c" fn Bun__JSPropertyIterator__create(JSContextRef, EncodedValue, *usize, bool, bool) ?*JSPropertyIterator;
extern "c" fn Bun__JSPropertyIterator__deinit(*JSPropertyIterator) void;
extern "c" fn Bun__JSPropertyIterator__getLongestPropertyName(*JSPropertyIterator, JSContextRef, ?*anyopaque) usize;
extern "c" fn Bun__JSPropertyIterator__getName(*JSPropertyIterator, *BunString, usize) void;
extern "c" fn Bun__JSPropertyIterator__getNameAndValue(*JSPropertyIterator, JSContextRef, ?*anyopaque, *BunString, usize) EncodedValue;
extern "c" fn Bun__JSPropertyIterator__getNameAndValueNonObservable(*JSPropertyIterator, JSContextRef, ?*anyopaque, *BunString, usize) EncodedValue;
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
extern "c" fn Bun__createTextCodec([*]const u8, usize) ?*TextCodec;
extern "c" fn Bun__decodeWithTextCodec(*TextCodec, [*]const u8, usize, bool, bool, *bool) BunString;
extern "c" fn Bun__deleteTextCodec(*TextCodec) void;
extern "c" fn Bun__stripBOMFromTextCodec(*TextCodec) void;
extern "c" fn Bun__isEncodingSupported([*]const u8, usize) bool;
extern "c" fn Bun__getCanonicalEncodingName([*]const u8, usize, *usize) ?[*]const u8;
extern "c" fn WebCore__AbortSignal__new(JSContextRef) *AbortSignal;
extern "c" fn WebCore__AbortSignal__create(JSContextRef) EncodedValue;
extern "c" fn WebCore__AbortSignal__fromJS(EncodedValue) ?*AbortSignal;
extern "c" fn WebCore__AbortSignal__toJS(*AbortSignal, JSContextRef) EncodedValue;
extern "c" fn WebCore__AbortSignal__ref(*AbortSignal) *AbortSignal;
extern "c" fn WebCore__AbortSignal__unref(*AbortSignal) void;
extern "c" fn WebCore__AbortSignal__incrementPendingActivity(*AbortSignal) void;
extern "c" fn WebCore__AbortSignal__decrementPendingActivity(*AbortSignal) void;
extern "c" fn WebCore__AbortSignal__aborted(*AbortSignal) bool;
extern "c" fn WebCore__AbortSignal__abortReason(*AbortSignal) EncodedValue;
extern "c" fn WebCore__AbortSignal__reasonIfAborted(*AbortSignal, JSContextRef, *u8) EncodedValue;
extern "c" fn WebCore__AbortSignal__signal(*AbortSignal, JSContextRef, u8) void;
extern "c" fn WebCore__AbortSignal__addListener(*AbortSignal, ?*anyopaque, ?*const fn (?*anyopaque, EncodedValue) callconv(.c) void) *AbortSignal;
extern "c" fn WebCore__AbortSignal__cleanNativeBindings(*AbortSignal, ?*anyopaque) void;
extern "c" fn BunString__toJS(JSContextRef, *const BunString) EncodedValue;
extern "c" fn BunString__toJSWithLength(JSContextRef, *const BunString, usize) EncodedValue;
extern "c" fn BunString__transferToJS(*BunString, JSContextRef) EncodedValue;
extern "c" fn BunString__createArray(JSContextRef, [*c]const BunString, usize) EncodedValue;
extern "c" fn JSC__JSString__iterator(?*anyopaque, JSContextRef, ?*anyopaque) void;
extern "c" fn JSFunction__createFromZig(JSContextRef, BunString, ?*const JSHostFn, u32, ImplementationVisibility, Intrinsic, ?*const JSHostFn) EncodedValue;
extern "c" fn Bun__CallFrame__getCallerSrcLoc(?*const PrivateCallFrame, JSContextRef, *BunString, *c_uint, *c_uint) void;
extern "c" fn Bun__CallFrame__isFromBunMain(?*const PrivateCallFrame, ?*const anyopaque) bool;
extern "c" fn Bun__CallFrame__describeFrame(?*const PrivateCallFrame) [*:0]const u8;
extern "c" fn Bun__CreateFFIFunctionValue(JSContextRef, ?*const ZigString, u32, ?*const JSHostFn, bool, ?*anyopaque) EncodedValue;
extern "c" fn Bun__CreateFFIFunctionWithDataValue(JSContextRef, ?*const ZigString, u32, ?*const JSHostFn, ?*anyopaque) EncodedValue;
extern "c" fn Bun__FFIFunction_getDataPtr(EncodedValue) ?*anyopaque;
extern "c" fn Bun__FFIFunction_setDataPtr(EncodedValue, ?*anyopaque) void;
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
extern "c" fn Bun__createArrayBufferForCopy(JSContextRef, ?*const anyopaque, usize) EncodedValue;
extern "c" fn Bun__allocUint8ArrayForCopy(JSContextRef, usize, **anyopaque) EncodedValue;
extern "c" fn Bun__allocArrayBufferForCopy(JSContextRef, usize, **anyopaque) EncodedValue;
extern "c" fn JSUint8Array__fromDefaultAllocator(JSContextRef, [*]u8, usize) EncodedValue;
extern "c" fn JSArrayBuffer__fromDefaultAllocator(JSContextRef, [*]u8, usize) EncodedValue;
extern "c" fn JSBuffer__isBuffer(JSContextRef, EncodedValue) bool;
extern "c" fn JSBuffer__bufferFromLength(JSContextRef, i64) EncodedValue;
extern "c" fn JSBuffer__bufferFromPointerAndLengthAndDeinit(JSContextRef, [*]u8, usize, ?*anyopaque, ?*const fn (?*anyopaque, ?*anyopaque) callconv(.c) void) EncodedValue;
extern "c" fn JSBuffer__fromMmap(JSContextRef, *anyopaque, usize) EncodedValue;
extern "c" fn ArrayBuffer__fromSharedMemfd(i64, JSContextRef, usize, usize, usize, u8) EncodedValue;
extern "c" fn JSC__JSValue__createUninitializedUint8Array(JSContextRef, usize) EncodedValue;
extern "c" fn Bun__makeArrayBufferWithBytesNoCopy(JSContextRef, ?*anyopaque, usize, ?*const fn (?*anyopaque, ?*anyopaque) callconv(.c) void, ?*anyopaque) EncodedValue;
extern "c" fn Bun__makeTypedArrayWithBytesNoCopy(JSContextRef, PrivateTypedArrayType, ?*anyopaque, usize, ?*const fn (?*anyopaque, ?*anyopaque) callconv(.c) void, ?*anyopaque) EncodedValue;
extern "c" fn JSC__JSValue__asArrayBuffer(EncodedValue, JSContextRef, *PrivateBunArrayBuffer) bool;
extern "c" fn JSC__IDLArrayBufferRef__convertToExtern(EncodedValue, JSContextRef) ?*PrivateArrayBufferHandle;
extern "c" fn JSC__ArrayBuffer__ref(*PrivateArrayBufferHandle) void;
extern "c" fn JSC__ArrayBuffer__deref(*PrivateArrayBufferHandle) void;
extern "c" fn JSC__ArrayBuffer__asBunArrayBuffer(*PrivateArrayBufferHandle, *PrivateBunArrayBuffer) void;
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
extern "c" fn ZigString__external(*const ZigString, JSContextRef, ?*anyopaque, *const fn (?*anyopaque, ?*anyopaque, usize) callconv(.c) void) EncodedValue;
extern "c" fn ZigString__toExternalValueWithCallback(*const ZigString, JSContextRef, *const fn (?*anyopaque, ?*anyopaque, usize) callconv(.c) void) EncodedValue;
extern "c" fn ZigString__toExternalU16([*]const u16, usize, JSContextRef) EncodedValue;
extern "c" fn JSC__JSValue__createRopeString(EncodedValue, EncodedValue, JSContextRef) EncodedValue;
extern "c" fn JSC__JSString__toZigString(?*anyopaque, JSContextRef, *ZigString) void;
extern "c" fn JSC__JSValue__toZigString(EncodedValue, *ZigString, JSContextRef) void;
extern "c" fn JSC__JSValue__createTypeError(*const ZigString, *const ZigString, JSContextRef) EncodedValue;
extern "c" fn JSC__JSValue__createRangeError(*const ZigString, *const ZigString, JSContextRef) EncodedValue;
extern "c" fn JSC__createError(JSContextRef, *const BunString) EncodedValue;
extern "c" fn JSC__createTypeError(JSContextRef, *const BunString) EncodedValue;
extern "c" fn JSC__createRangeError(JSContextRef, *const BunString) EncodedValue;
extern "c" fn SystemError__toErrorInstance(?*const SystemError, JSContextRef) EncodedValue;
extern "c" fn SystemError__toErrorInstanceWithInfoObject(?*const SystemError, JSContextRef) EncodedValue;
extern "c" fn JSC__JSGlobalObject__createAggregateError(JSContextRef, [*c]const EncodedValue, usize, *const ZigString) EncodedValue;
extern "c" fn JSC__JSGlobalObject__createAggregateErrorWithArray(JSContextRef, EncodedValue, BunString, EncodedValue) EncodedValue;
extern "c" fn JSC__JSValue__getErrorsProperty(EncodedValue, JSContextRef) EncodedValue;
extern "c" fn JSC__JSValue__createObject2(JSContextRef, *const ZigString, *const ZigString, EncodedValue, EncodedValue) EncodedValue;
extern "c" fn JSC__JSValue__putRecord(EncodedValue, JSContextRef, ?*const ZigString, [*c]const ZigString, usize) void;
extern "c" fn JSC__JSValue__fromEntries(JSContextRef, [*c]const ZigString, [*c]const ZigString, usize, bool) EncodedValue;
extern "c" fn JSC__JSValue__put(EncodedValue, JSContextRef, *const ZigString, EncodedValue) void;
extern "c" fn JSC__JSValue__putBunString(EncodedValue, JSContextRef, *const BunString, EncodedValue) void;
extern "c" fn JSC__JSValue__upsertBunStringArray(EncodedValue, JSContextRef, *const BunString, EncodedValue) EncodedValue;
extern "c" fn JSC__JSValue__hasOwnPropertyValue(EncodedValue, JSContextRef, EncodedValue) bool;
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
extern "c" fn JSC__JSValue__forEachPropertyNonIndexed(EncodedValue, JSContextRef, ?*anyopaque, ?PropertyCallback) void;
extern "c" fn JSC__JSValue__isGetterSetter(EncodedValue) bool;
extern "c" fn JSC__JSValue__isCustomGetterSetter(EncodedValue) bool;
extern "c" fn JSC__JSValue__jsType(EncodedValue) u8;
extern "c" fn JSC__GetterSetter__isGetterNull(?*anyopaque) bool;
extern "c" fn JSC__GetterSetter__isSetterNull(?*anyopaque) bool;
extern "c" fn JSC__CustomGetterSetter__isGetterNull(?*anyopaque) bool;
extern "c" fn JSC__CustomGetterSetter__isSetterNull(?*anyopaque) bool;
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
extern "c" fn Debugger__didScheduleAsyncCall(JSContextRef, DebuggerAsyncCallType, u64, bool) void;
extern "c" fn Debugger__didCancelAsyncCall(JSContextRef, DebuggerAsyncCallType, u64) void;
extern "c" fn Debugger__didDispatchAsyncCall(JSContextRef, DebuggerAsyncCallType, u64) void;
extern "c" fn Debugger__willDispatchAsyncCall(JSContextRef, DebuggerAsyncCallType, u64) void;
extern "c" fn Bun__noSideEffectsToString(?*anyopaque, JSContextRef, EncodedValue) EncodedValue;
extern "c" fn Bun__promises__isErrorLike(JSContextRef, EncodedValue) bool;
extern "c" fn Bun__Process__emitWarning(JSContextRef, EncodedValue, EncodedValue, EncodedValue, EncodedValue) void;
extern "c" fn Bun__Process__queueNextTick1(JSContextRef, EncodedValue, EncodedValue) void;
extern "c" fn Bun__Process__queueNextTick2(JSContextRef, EncodedValue, EncodedValue, EncodedValue) void;
extern "c" fn Bun__promises__emitUnhandledRejectionWarning(JSContextRef, EncodedValue, EncodedValue) void;
extern "c" fn Bun__handleUnhandledRejection(JSContextRef, EncodedValue, EncodedValue) c_int;
extern "c" fn Bun__emitHandledPromiseEvent(JSContextRef, EncodedValue) bool;
extern "c" fn Bun__handleUncaughtException(JSContextRef, EncodedValue, c_int) c_int;
extern "c" fn Bun__wrapUnhandledRejectionErrorForUncaughtException(JSContextRef, EncodedValue) EncodedValue;
extern "c" fn Bun__serializeJSValue(JSContextRef, EncodedValue, u8) SerializedScriptExternal;
extern "c" fn Bun__SerializedScriptSlice__free(?*anyopaque) void;
extern "c" fn Bun__JSValue__deserialize(JSContextRef, [*c]const u8, usize) EncodedValue;
extern "c" fn Process__dispatchOnBeforeExit(JSContextRef, u8) void;
extern "c" fn Process__dispatchOnExit(JSContextRef, u8) void;
extern "c" fn Process__emitMessageEvent(JSContextRef, EncodedValue, EncodedValue) void;
extern "c" fn Process__emitDisconnectEvent(JSContextRef) void;
extern "c" fn Process__emitErrorEvent(JSContextRef, EncodedValue) void;
extern "c" fn JSC__JSValue__forEach(EncodedValue, JSContextRef, ?*anyopaque, IterableCallback) void;
extern "c" fn ZigString__toJSONObject(*const ZigString, JSContextRef) EncodedValue;
extern "c" fn JSC__jsTypeStringForValue(JSContextRef, EncodedValue) ?*anyopaque;
extern "c" fn JSC__JSString__eql(?*anyopaque, JSContextRef, ?*anyopaque) bool;
extern "c" fn JSC__JSString__is8Bit(?*anyopaque) bool;
extern "c" fn JSC__JSString__length(?*anyopaque) usize;
extern "c" fn JSC__JSString__toObject(?*anyopaque, JSContextRef) JSObjectRef;
extern "c" fn JSC__JSCell__getObject(?*anyopaque) JSObjectRef;
extern "c" fn JSC__JSCell__toObject(?*anyopaque, JSContextRef) JSObjectRef;
extern "c" fn JSC__JSValue__createEmptyObject(JSContextRef, usize) EncodedValue;
extern "c" fn JSC__JSValue__createEmptyObjectWithNullPrototype(JSContextRef) EncodedValue;
extern "c" fn JSC__JSObject__create(JSContextRef, usize, ?*anyopaque, ?*const fn (?*anyopaque, ?*anyopaque, ?*anyopaque) callconv(.c) void) EncodedValue;
extern "c" fn URLSearchParams__create(JSContextRef, *const ZigString) EncodedValue;
extern "c" fn URLSearchParams__fromJS(EncodedValue) ?*anyopaque;
extern "c" fn URLSearchParams__toString(?*anyopaque, ?*anyopaque, ?*const fn (?*anyopaque, *const ZigString) callconv(.c) void) void;
extern "c" fn Bun__CommonStringsForZig__toJS(CommonStringsForZig, JSContextRef) EncodedValue;
extern "c" fn WebCore__DOMFormData__create(JSContextRef) EncodedValue;
extern "c" fn WebCore__DOMFormData__createFromURLQuery(JSContextRef, *const ZigString) EncodedValue;
extern "c" fn WebCore__DOMFormData__fromJS(EncodedValue) ?*anyopaque;
extern "c" fn WebCore__DOMFormData__cast_(EncodedValue, ?*anyopaque) ?*anyopaque;
extern "c" fn WebCore__DOMFormData__append(?*anyopaque, *const ZigString, *const ZigString) void;
extern "c" fn WebCore__DOMFormData__appendBlob(?*anyopaque, JSContextRef, *const ZigString, *anyopaque, *const ZigString) void;
extern "c" fn WebCore__DOMFormData__count(?*anyopaque) usize;
extern "c" fn DOMFormData__toQueryString(?*anyopaque, ?*anyopaque, ?*const fn (?*anyopaque, *const ZigString) callconv(.c) void) void;
extern "c" fn WebCore__DOMFormData__toQueryString(?*anyopaque, ?*anyopaque, ?*const fn (?*anyopaque, *const ZigString) callconv(.c) void) void;
const DOMFormDataForEachCallback = *const fn (?*anyopaque, *const ZigString, *anyopaque, ?*const ZigString, u8) callconv(.c) void;
extern "c" fn DOMFormData__forEach(?*anyopaque, ?*anyopaque, DOMFormDataForEachCallback) void;
const FetchHeaders = opaque {};
const FetchHeadersStringPointer = extern struct { offset: u32, length: u32 };
extern "c" fn WebCore__FetchHeaders__append(*FetchHeaders, *const ZigString, *const ZigString, JSContextRef) void;
extern "c" fn WebCore__FetchHeaders__cast_(EncodedValue, ?*anyopaque) ?*FetchHeaders;
extern "c" fn WebCore__FetchHeaders__clone(*FetchHeaders, JSContextRef) EncodedValue;
extern "c" fn WebCore__FetchHeaders__cloneThis(*FetchHeaders, JSContextRef) ?*FetchHeaders;
extern "c" fn WebCore__FetchHeaders__copyTo(*FetchHeaders, [*]FetchHeadersStringPointer, [*]FetchHeadersStringPointer, [*]u8) void;
extern "c" fn WebCore__FetchHeaders__count(*FetchHeaders, *u32, *u32) void;
extern "c" fn WebCore__FetchHeaders__createEmpty() *FetchHeaders;
extern "c" fn WebCore__FetchHeaders__createFromJS(JSContextRef, EncodedValue) ?*FetchHeaders;
extern "c" fn WebCore__FetchHeaders__createValue(JSContextRef, [*c]const FetchHeadersStringPointer, [*c]const FetchHeadersStringPointer, *const ZigString, u32) EncodedValue;
extern "c" fn WebCore__FetchHeaders__createValueNotJS(JSContextRef, [*c]const FetchHeadersStringPointer, [*c]const FetchHeadersStringPointer, *const ZigString, u32) ?*FetchHeaders;
extern "c" fn WebCore__FetchHeaders__deref(*FetchHeaders) void;
extern "c" fn WebCore__FetchHeaders__fastGet_(*FetchHeaders, u8, *ZigString) void;
extern "c" fn WebCore__FetchHeaders__fastHas_(*FetchHeaders, u8) bool;
extern "c" fn WebCore__FetchHeaders__fastRemove_(*FetchHeaders, u8) void;
extern "c" fn WebCore__FetchHeaders__get_(*FetchHeaders, *const ZigString, *ZigString, JSContextRef) void;
extern "c" fn WebCore__FetchHeaders__has(*FetchHeaders, *const ZigString, JSContextRef) bool;
extern "c" fn WebCore__FetchHeaders__isEmpty(*FetchHeaders) bool;
extern "c" fn WebCore__FetchHeaders__put(*FetchHeaders, u8, *const ZigString, JSContextRef) void;
extern "c" fn WebCore__FetchHeaders__put_(*FetchHeaders, *const ZigString, *const ZigString, JSContextRef) void;
extern "c" fn WebCore__FetchHeaders__remove(*FetchHeaders, *const ZigString, JSContextRef) void;
extern "c" fn WebCore__FetchHeaders__toJS(*FetchHeaders, JSContextRef) EncodedValue;
extern "c" fn URL__fromString(?*const BunString) ?*anyopaque;
extern "c" fn URL__deinit(?*anyopaque) void;
extern "c" fn URL__href(?*anyopaque) BunString;
extern "c" fn URL__protocol(?*anyopaque) BunString;
extern "c" fn URL__username(?*anyopaque) BunString;
extern "c" fn URL__password(?*anyopaque) BunString;
extern "c" fn URL__search(?*anyopaque) BunString;
extern "c" fn URL__host(?*anyopaque) BunString;
extern "c" fn URL__hostname(?*anyopaque) BunString;
extern "c" fn URL__port(?*anyopaque) u32;
extern "c" fn URL__pathname(?*anyopaque) BunString;
extern "c" fn URL__hash(?*anyopaque) BunString;
extern "c" fn URL__fragmentIdentifier(?*anyopaque) BunString;
extern "c" fn URL__fromJS(EncodedValue, JSContextRef) ?*anyopaque;
extern "c" fn URL__getHrefFromJS(EncodedValue, JSContextRef) BunString;
extern "c" fn URL__getHref(?*const BunString) BunString;
extern "c" fn URL__getHrefJoin(?*const BunString, ?*const BunString) BunString;
extern "c" fn URL__getFileURLString(?*const BunString) BunString;
extern "c" fn URL__pathFromFileURL(?*const BunString) BunString;
extern "c" fn URL__originLength(?[*]const u8, usize) u32;
extern "c" fn BunString__toURL(?*const ZigString, JSContextRef) EncodedValue;
extern "c" fn BunString__toJSDOMURL(JSContextRef, ?*const BunString) EncodedValue;
extern "c" fn WebCore__DOMURL__cast_(EncodedValue, ?*anyopaque) ?*anyopaque;
extern "c" fn WebCore__DOMURL__href_(?*anyopaque, ?*ZigString) void;
extern "c" fn WebCore__DOMURL__pathname_(?*anyopaque, ?*ZigString) void;
extern "c" fn WebCore__DOMURL__fileSystemPath(?*anyopaque, ?*c_int) BunString;
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
extern "c" fn JSC__JSGlobalObject__bunVM(JSContextRef) ?*anyopaque;
extern "c" fn JSC__VM__throwError(?*anyopaque, JSContextRef, EncodedValue) void;
extern "c" fn JSGlobalObject__hasException(JSContextRef) bool;
extern "c" fn JSGlobalObject__clearException(JSContextRef) void;
extern "c" fn JSGlobalObject__clearExceptionExceptTermination(JSContextRef) bool;
extern "c" fn JSGlobalObject__clearTerminationException(JSContextRef) void;
extern "c" fn JSGlobalObject__createOutOfMemoryError(JSContextRef) EncodedValue;
extern "c" fn JSGlobalObject__requestTermination(JSContextRef) void;
extern "c" fn JSGlobalObject__setTimeZone(JSContextRef, ?*const ZigString) bool;
extern "c" fn JSGlobalObject__throwOutOfMemoryError(JSContextRef) void;
extern "c" fn JSGlobalObject__throwStackOverflow(JSContextRef) void;
extern "c" fn JSGlobalObject__tryTakeException(JSContextRef) EncodedValue;
extern "c" fn JSC__Exception__asJSValue(?*anyopaque) EncodedValue;
extern "c" fn JSC__Exception__getStackTrace(?*anyopaque, JSContextRef, *ZigStackTrace) void;
extern "c" fn JSC__JSValue__toZigException(EncodedValue, JSContextRef, *ZigException) void;
extern "c" fn ZigException__collectSourceLines(EncodedValue, JSContextRef, *ZigException) void;
extern "c" fn ZigException__fromException(?*anyopaque) ZigException;
extern "c" fn JSC__JSValue__isException(EncodedValue, ?*anyopaque) bool;
extern "c" fn JSC__JSValue__isTerminationException(EncodedValue) bool;
extern "c" fn JSC__JSValue__toError_(EncodedValue) EncodedValue;
extern "c" fn JSC__JSValue__isAnyError(EncodedValue) bool;
extern "c" fn JSC__VM__clearHasTerminationRequest(?*anyopaque) void;
extern "c" fn JSC__VM__executionForbidden(?*anyopaque) bool;
extern "c" fn JSC__VM__hasTerminationRequest(?*anyopaque) bool;
extern "c" fn JSC__VM__isEntered(?*anyopaque) bool;
extern "c" fn JSC__VM__notifyNeedTermination(?*anyopaque) void;
extern "c" fn JSC__VM__notifyNeedWatchdogCheck(?*anyopaque) void;
extern "c" fn JSC__VM__notifyNeedDebuggerBreak(?*anyopaque) void;
extern "c" fn JSC__VM__setExecutionForbidden(?*anyopaque, bool) void;
extern "c" fn JSC__VM__getAPILock(?*anyopaque) void;
extern "c" fn JSC__VM__holdAPILock(?*anyopaque, ?*anyopaque, *const fn (?*anyopaque) callconv(.c) void) void;
extern "c" fn JSC__VM__releaseAPILock(?*anyopaque) void;
extern "c" fn JSC__VM__setExecutionTimeLimit(?*anyopaque, f64) void;
extern "c" fn JSC__VM__clearExecutionTimeLimit(?*anyopaque) void;
extern "c" fn JSC__VM__hasExecutionTimeLimit(?*anyopaque) bool;
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
extern "c" fn JSC__JSModuleLoader__evaluate(JSContextRef, [*c]const u8, usize, [*c]const u8, usize, [*c]const u8, usize, EncodedValue, *EncodedValue) EncodedValue;
extern "c" fn JSC__JSModuleLoader__loadAndEvaluateModule(JSContextRef, ?*const BunString) ?*anyopaque;
extern "c" fn JSModuleLoader__import(JSContextRef, ?*const BunString) ?*anyopaque;
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
extern "c" fn Bun__JSArray__getContiguousVector(EncodedValue, ?*u32) ?[*]const EncodedValue;
extern "c" fn Bun__JSArray__contiguousVectorIsStillValid(EncodedValue, ?[*]const EncodedValue, u32) bool;
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
extern "c" fn JSC__JSValue___then(EncodedValue, JSContextRef, EncodedValue, ?*const JSHostFn, ?*const JSHostFn) void;
extern "c" fn Bun__attachAsyncStackFromPromise(JSContextRef, EncodedValue, ?*anyopaque) void;
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

const ApiLockProbe = struct {
    vm: ?*anyopaque,
    started: std.atomic.Value(bool) = .init(false),
    entered: std.atomic.Value(bool) = .init(false),
    received: ?*anyopaque = null,
};

fn apiLockProbeCallback(raw: ?*anyopaque) callconv(.c) void {
    const probe: *ApiLockProbe = @ptrCast(@alignCast(raw.?));
    probe.received = raw;
    probe.entered.store(true, .release);
}

fn apiLockProbeThread(probe: *ApiLockProbe) void {
    probe.started.store(true, .release);
    JSC__VM__holdAPILock(probe.vm, probe, apiLockProbeCallback);
}

var api_lock_null_callback_ran: bool = false;
fn apiLockNullCallback(raw: ?*anyopaque) callconv(.c) void {
    _ = raw;
    api_lock_null_callback_ran = true;
}

const ObjectCreateState = struct {
    calls: usize = 0,
    ctx: ?*anyopaque = null,
    obj: ?*anyopaque = null,
    global: ?*anyopaque = null,
};
var object_create_state: ObjectCreateState = .{};
fn objectCreateInitializer(ctx: ?*anyopaque, obj: ?*anyopaque, global: ?*anyopaque) callconv(.c) void {
    object_create_state.calls += 1;
    object_create_state.ctx = ctx;
    object_create_state.obj = obj;
    object_create_state.global = global;
}

const UspToStringState = struct {
    calls: usize = 0,
    utf16: bool = false,
    len: usize = 0,
    bytes: [256]u8 = @splat(0),
};
var usp_to_string_state: UspToStringState = .{};
fn uspToStringCallback(ctx: ?*anyopaque, str: *const ZigString) callconv(.c) void {
    const state: *UspToStringState = @ptrCast(@alignCast(ctx.?));
    state.calls += 1;
    state.utf16 = (str.tagged_ptr & (@as(usize, 1) << 63)) != 0;
    state.len = str.len;
    if (str.len > state.bytes.len) fail("private URLSearchParams serialization exceeded fixture capacity");
    const pointer = str.tagged_ptr & ~(@as(usize, 1) << 63);
    if (state.utf16) {
        const units: [*]const u16 = @ptrFromInt(pointer);
        for (units[0..str.len], 0..) |unit, i| state.bytes[i] = @intCast(unit);
    } else if (str.len > 0) {
        const bytes: [*]const u8 = @ptrFromInt(pointer);
        @memcpy(state.bytes[0..str.len], bytes[0..str.len]);
    }
}

const DOMFormDataFixtureEntry = struct {
    name: ZigString = .{ .tagged_ptr = 0, .len = 0 },
    string: ZigString = .{ .tagged_ptr = 0, .len = 0 },
    filename: ZigString = .{ .tagged_ptr = 0, .len = 0 },
    blob: ?*anyopaque = null,
    is_blob: bool = false,
};

const DOMFormDataFixtureState = struct {
    entries: [16]DOMFormDataFixtureEntry = @splat(.{}),
    calls: usize = 0,
};

fn domFormDataForEachCallback(
    raw_state: ?*anyopaque,
    name: *const ZigString,
    raw_value: *anyopaque,
    filename: ?*const ZigString,
    is_blob: u8,
) callconv(.c) void {
    const state: *DOMFormDataFixtureState = @ptrCast(@alignCast(raw_state.?));
    if (state.calls == state.entries.len or is_blob > 1) fail("private DOMFormData callback metadata mismatch");
    const entry = &state.entries[state.calls];
    entry.name = name.*;
    entry.is_blob = is_blob != 0;
    if (entry.is_blob) {
        entry.blob = raw_value;
        entry.filename = if (filename) |value| value.* else .{ .tagged_ptr = 0, .len = 0 };
    } else {
        if (filename != null) fail("private DOMFormData string callback carried a filename");
        const string: *const ZigString = @ptrCast(@alignCast(raw_value));
        entry.string = string.*;
    }
    state.calls += 1;
}

fn bunStringUtf8Equals(actual: BunString, expected: []const u8) bool {
    if (actual.tag == .empty) return expected.len == 0;
    if (actual.tag == .zig_string or actual.tag == .static_zig_string)
        return zigStringUtf8Equals(actual.value.zig_string, expected);
    if (actual.tag != .wtf_string_impl) return false;
    const impl = actual.value.wtf_string_impl orelse return false;
    var view = std.unicode.Utf8View.init(expected) catch return false;
    var codepoints = view.iterator();
    var index: usize = 0;
    if (impl.hash_and_flags & 4 != 0) { // Latin-1 buffer
        while (codepoints.nextCodepoint()) |codepoint| {
            if (index >= impl.length or codepoint > 0xff or impl.bytes[index] != @as(u8, @intCast(codepoint))) return false;
            index += 1;
        }
        return index == impl.length;
    }
    const units: [*]align(1) const u16 = @ptrCast(impl.bytes);
    while (codepoints.nextCodepoint()) |codepoint| {
        if (codepoint <= 0xffff) {
            if (index >= impl.length or units[index] != @as(u16, @intCast(codepoint))) return false;
            index += 1;
            continue;
        }
        if (index + 1 >= impl.length) return false;
        const scalar = codepoint - 0x10000;
        if (units[index] != @as(u16, @intCast(0xd800 + (scalar >> 10))) or
            units[index + 1] != @as(u16, @intCast(0xdc00 + (scalar & 0x3ff)))) return false;
        index += 2;
    }
    return index == impl.length;
}

fn zigStringUtf8Equals(actual: ZigString, expected: []const u8) bool {
    const untagged = actual.tagged_ptr & ((@as(usize, 1) << 53) - 1);
    if (actual.tagged_ptr & (@as(usize, 1) << 63) != 0) {
        const units: [*]align(1) const u16 = @ptrFromInt(untagged);
        var view = std.unicode.Utf8View.init(expected) catch return false;
        var codepoints = view.iterator();
        var index: usize = 0;
        while (codepoints.nextCodepoint()) |codepoint| {
            if (codepoint <= 0xffff) {
                if (index >= actual.len or units[index] != @as(u16, @intCast(codepoint))) return false;
                index += 1;
                continue;
            }
            if (index + 1 >= actual.len) return false;
            const scalar = codepoint - 0x10000;
            if (units[index] != @as(u16, @intCast(0xd800 + (scalar >> 10))) or
                units[index + 1] != @as(u16, @intCast(0xdc00 + (scalar & 0x3ff)))) return false;
            index += 2;
        }
        return index == actual.len;
    }
    const bytes: [*]const u8 = @ptrFromInt(untagged);
    if (actual.tagged_ptr & (@as(usize, 1) << 61) != 0)
        return actual.len == expected.len and std.mem.eql(u8, bytes[0..actual.len], expected);
    var view = std.unicode.Utf8View.init(expected) catch return false;
    var codepoints = view.iterator();
    var index: usize = 0;
    while (codepoints.nextCodepoint()) |codepoint| {
        if (index >= actual.len or codepoint > 0xff or bytes[index] != @as(u8, @intCast(codepoint))) return false;
        index += 1;
    }
    return index == actual.len;
}

fn expectNativeUrlField(context: JSContextRef, actual: BunString, js_source: [*:0]const u8) bool {
    exposeCell(context, "__nu_actual", BunString__toJS(context, &actual));
    exposeCell(context, "__nu_expected", evaluate(context, js_source));
    return JSC__JSValue__toBoolean(evaluate(context, "__nu_actual === __nu_expected"));
}

fn markedArgumentFixtureCallback(raw: ?*anyopaque, buffer: ?*anyopaque) callconv(.c) void {
    const state: *MarkedArgumentFixtureState = @ptrCast(@alignCast(raw.?));
    state.calls += 1;
    MarkedArgumentBuffer__append(buffer, EncodedValue.fromInt32(212));
    MarkedArgumentBuffer__append(buffer, state.value);
    MarkedArgumentBuffer__append(buffer, state.foreign);
    _ = JSC__VM__runGC(state.vm, true);
}

const IterableFixtureState = struct {
    vm: ?*anyopaque,
    global: JSContextRef,
    values: [2]EncodedValue = @splat(.empty),
    calls: usize = 0,
};

const PropertyFixtureEntry = struct {
    name: [32]u8 = @splat(0),
    name_len: usize = 0,
    value: EncodedValue = .empty,
    is_symbol: bool = false,
};

const PropertyFixtureState = struct {
    global: JSContextRef,
    vm: ?*anyopaque,
    entries: [16]PropertyFixtureEntry = @splat(.{}),
    calls: usize = 0,
    run_gc: bool = false,
    reenter: bool = false,
    throw_at: ?usize = null,
};

fn copyPropertyKey(key: ZigString, output: *[32]u8) usize {
    const utf16 = (key.tagged_ptr & (@as(usize, 1) << 63)) != 0;
    const pointer = key.tagged_ptr & ~(@as(usize, 1) << 63);
    if (key.len > output.len) fail("private property traversal key exceeded fixture capacity");
    if (utf16) {
        const units: [*]const u16 = @ptrFromInt(pointer);
        for (units[0..key.len], output[0..key.len]) |unit, *byte| {
            if (unit > 0x7f) fail("private property traversal fixture expected ASCII key");
            byte.* = @intCast(unit);
        }
    } else if (key.len > 0) {
        const bytes: [*]const u8 = @ptrFromInt(pointer);
        @memcpy(output[0..key.len], bytes[0..key.len]);
    }
    return key.len;
}

fn propertyFixtureCallback(
    global: JSContextRef,
    raw_state: ?*anyopaque,
    key: *ZigString,
    property_value: EncodedValue,
    is_symbol: bool,
    is_private_symbol: bool,
) callconv(.c) void {
    const state: *PropertyFixtureState = @ptrCast(@alignCast(raw_state.?));
    if (global != state.global or is_private_symbol or state.calls >= state.entries.len)
        fail("private property traversal callback metadata mismatch");
    const index = state.calls;
    state.entries[index].name_len = copyPropertyKey(key.*, &state.entries[index].name);
    state.entries[index].value = property_value;
    state.entries[index].is_symbol = is_symbol;
    state.calls += 1;
    if (state.run_gc) {
        state.run_gc = false;
        _ = JSC__VM__runGC(state.vm, true);
    }
    if (state.reenter) {
        state.reenter = false;
        if (!JSC__JSValue__isStrictEqual(evaluate(global, "__private_property_258.data + 1"), EncodedValue.fromInt32(259), global))
            fail("private property traversal reentry mismatch");
    }
    if (state.throw_at != null and state.throw_at.? == index)
        JSC__VM__throwError(state.vm, global, EncodedValue.fromInt32(2581));
}

fn propertyEntryName(entry: *const PropertyFixtureEntry) []const u8 {
    return entry.name[0..entry.name_len];
}

var custom_property_get_calls: usize = 0;
var custom_property_set_calls: usize = 0;

fn customPropertyGetter(
    _: JSContextRef,
    _: JSObjectRef,
    _: JSStringRef,
    _: ExceptionRef,
) callconv(.c) JSValueRef {
    custom_property_get_calls += 1;
    return null;
}

fn customPropertySetter(
    _: JSContextRef,
    _: JSObjectRef,
    _: JSStringRef,
    _: JSValueRef,
    _: ExceptionRef,
) callconv(.c) bool {
    custom_property_set_calls += 1;
    return true;
}

fn iterableFixtureCallback(vm: ?*anyopaque, global: JSContextRef, raw: ?*anyopaque, item: EncodedValue) callconv(.c) void {
    const state: *IterableFixtureState = @ptrCast(@alignCast(raw.?));
    if (vm != state.vm or global != state.global or state.calls == state.values.len)
        fail("private iterable callback metadata mismatch");
    state.values[state.calls] = item;
    state.calls += 1;
}

const HostFunctionFixtureState = struct {
    global: JSContextRef = null,
    callee: EncodedValue = .empty,
    this_value: EncodedValue = .empty,
    args: [2]EncodedValue = @splat(.undefined),
    calls: usize = 0,
    constructs: usize = 0,
    introspection_global: JSContextRef = null,
    vm: ?*anyopaque = null,
    caller_source: BunString = .{ .tag = .empty, .value = .{ .zig_string = .{ .tagged_ptr = 0, .len = 0 } } },
    caller_line: c_uint = 0,
    caller_column: c_uint = 0,
    caller_is_bun_main: bool = false,
    description: [512]u8 = @splat(0),
    description_len: usize = 0,
    last_frame: ?*const PrivateCallFrame = null,
    reenter: bool = false,
    reentry_restored: bool = false,
};

var host_function_fixture = HostFunctionFixtureState{};
var host_function_foreign_result: EncodedValue = .empty;

const FFIFunctionFixtureState = struct {
    global: JSContextRef = null,
    function: EncodedValue = .empty,
    expected_this: ?EncodedValue = null,
    args: [2]EncodedValue = @splat(.undefined),
    arg_count: usize = 0,
    expected_data: ?*anyopaque = null,
    observed_data: ?*anyopaque = null,
    calls: usize = 0,
    constructs: usize = 0,
    reenter: bool = false,
    reentry_ok: bool = false,
};

var ffi_function_fixture = FFIFunctionFixtureState{};

const PromiseThenFixtureState = struct {
    expected_global: JSContextRef = null,
    expected_value: EncodedValue = .empty,
    contexts: [8]EncodedValue = @splat(.empty),
    fulfilled: usize = 0,
    rejected: usize = 0,
    reenter: bool = false,
    reentry_promise: EncodedValue = .empty,
    reentry_context: EncodedValue = .empty,
};

var promise_then_fixture = PromiseThenFixtureState{};

fn callFrameSlots(frame: *PrivateCallFrame) [*]const EncodedValue {
    return @ptrCast(@alignCast(frame));
}

fn callFrameArgumentCount(slots: [*]const EncodedValue) u32 {
    const bits: u64 = @bitCast(@intFromEnum(slots[4]));
    return @truncate(bits);
}

fn capturePromiseThenCallback(global: JSContextRef, frame: *PrivateCallFrame, fulfilled: bool) EncodedValue {
    const slots = callFrameSlots(frame);
    const index = promise_then_fixture.fulfilled + promise_then_fixture.rejected;
    if (global != promise_then_fixture.expected_global or
        callFrameArgumentCount(slots) != 3 or
        index >= promise_then_fixture.contexts.len or
        !JSC__JSValue__isStrictEqual(slots[5], .undefined, global) or
        !JSC__JSValue__isStrictEqual(slots[6], promise_then_fixture.expected_value, global))
        fail("private Promise JSHostFn CallFrame mismatch");
    promise_then_fixture.contexts[index] = slots[7];
    if (fulfilled)
        promise_then_fixture.fulfilled += 1
    else
        promise_then_fixture.rejected += 1;
    if (promise_then_fixture.reenter) {
        promise_then_fixture.reenter = false;
        JSC__JSValue___then(
            promise_then_fixture.reentry_promise,
            global,
            promise_then_fixture.reentry_context,
            promiseThenResolve,
            promiseThenReject,
        );
    }
    return .undefined;
}

fn promiseThenResolve(global: JSContextRef, frame: *PrivateCallFrame) callconv(.c) EncodedValue {
    return capturePromiseThenCallback(global, frame, true);
}

fn promiseThenReject(global: JSContextRef, frame: *PrivateCallFrame) callconv(.c) EncodedValue {
    return capturePromiseThenCallback(global, frame, false);
}

fn promiseThenThrow(global: JSContextRef, frame: *PrivateCallFrame) callconv(.c) EncodedValue {
    _ = capturePromiseThenCallback(global, frame, true);
    JSC__VM__throwError(JSC__JSGlobalObject__vm(global), global, EncodedValue.fromInt32(2538));
    return .empty;
}

fn captureCallFrame(frame: *PrivateCallFrame) void {
    if (host_function_fixture.caller_source.tag == .wtf_string_impl)
        Bun__WTFStringImpl__deref(host_function_fixture.caller_source.value.wtf_string_impl);
    host_function_fixture.caller_source = emptyBunString();
    host_function_fixture.caller_line = 0;
    host_function_fixture.caller_column = 0;
    Bun__CallFrame__getCallerSrcLoc(
        frame,
        host_function_fixture.introspection_global,
        &host_function_fixture.caller_source,
        &host_function_fixture.caller_line,
        &host_function_fixture.caller_column,
    );
    host_function_fixture.caller_is_bun_main = Bun__CallFrame__isFromBunMain(frame, host_function_fixture.vm);
    const description = std.mem.span(Bun__CallFrame__describeFrame(frame));
    host_function_fixture.description_len = @min(description.len, host_function_fixture.description.len);
    @memcpy(host_function_fixture.description[0..host_function_fixture.description_len], description[0..host_function_fixture.description_len]);
    host_function_fixture.last_frame = frame;
}

fn hostFunctionAdd(global: JSContextRef, frame: *PrivateCallFrame) callconv(.c) EncodedValue {
    const slots = callFrameSlots(frame);
    if (global != host_function_fixture.global or
        !JSC__JSValue__isStrictEqual(slots[3], host_function_fixture.callee, global) or
        callFrameArgumentCount(slots) != 3 or
        !JSC__JSValue__isStrictEqual(slots[5], host_function_fixture.this_value, global) or
        slots[6] != host_function_fixture.args[0] or
        slots[7] != host_function_fixture.args[1])
        fail("private JSHostFn CallFrame call layout mismatch");
    captureCallFrame(frame);
    if (host_function_fixture.reenter) {
        host_function_fixture.reenter = false;
        const outer_line = host_function_fixture.caller_line;
        const outer_args = host_function_fixture.args;
        host_function_fixture.args = .{ EncodedValue.fromInt32(1), EncodedValue.fromInt32(2) };
        const nested = evaluate(global, "__private_host_function_248.call(__private_host_receiver_248, 1, 2)");
        host_function_fixture.args = outer_args;
        if (!JSC__JSValue__isStrictEqual(nested, EncodedValue.fromInt32(3), global)) fail("private CallFrame nested callback result mismatch");
        captureCallFrame(frame);
        host_function_fixture.reentry_restored = host_function_fixture.last_frame == frame and
            host_function_fixture.caller_line == outer_line and
            std.mem.indexOf(u8, host_function_fixture.description[0..host_function_fixture.description_len], "reentry-251.js") != null;
    }
    host_function_fixture.calls += 1;
    return EncodedValue.fromInt32(JSC__JSValue__toInt32(slots[6]) + JSC__JSValue__toInt32(slots[7]));
}

fn hostFunctionConstruct(global: JSContextRef, frame: *PrivateCallFrame) callconv(.c) EncodedValue {
    const slots = callFrameSlots(frame);
    if (global != host_function_fixture.global or
        !JSC__JSValue__isStrictEqual(slots[3], host_function_fixture.callee, global) or
        callFrameArgumentCount(slots) != 2 or
        !JSC__JSValue__isStrictEqual(slots[5], slots[3], global) or
        slots[6] != host_function_fixture.args[0])
        fail("private JSHostFn CallFrame construct layout mismatch");
    captureCallFrame(frame);
    host_function_fixture.constructs += 1;
    const instance = JSC__JSValue__createEmptyObject(global, 1);
    const answer_bytes = "answer";
    const answer = ZigString{ .tagged_ptr = @intFromPtr(answer_bytes.ptr), .len = answer_bytes.len };
    JSC__JSValue__put(instance, global, &answer, slots[6]);
    return instance;
}

fn hostFunctionThrow(global: JSContextRef, frame: *PrivateCallFrame) callconv(.c) EncodedValue {
    _ = frame;
    JSC__VM__throwError(JSC__JSGlobalObject__vm(global), global, EncodedValue.fromInt32(2481));
    return .empty;
}

fn hostFunctionEmpty(global: JSContextRef, frame: *PrivateCallFrame) callconv(.c) EncodedValue {
    _ = global;
    _ = frame;
    return .empty;
}

fn hostFunctionForeign(global: JSContextRef, frame: *PrivateCallFrame) callconv(.c) EncodedValue {
    _ = global;
    _ = frame;
    return host_function_foreign_result;
}

fn ffiFunctionCallback(global: JSContextRef, frame: *PrivateCallFrame) callconv(.c) EncodedValue {
    const slots = callFrameSlots(frame);
    if (global != ffi_function_fixture.global or
        !JSC__JSValue__isStrictEqual(slots[3], ffi_function_fixture.function, global) or
        callFrameArgumentCount(slots) != @as(u32, @intCast(ffi_function_fixture.arg_count + 1)))
        fail("private FFI CallFrame metadata mismatch");
    if (ffi_function_fixture.expected_this) |expected| {
        if (!JSC__JSValue__isStrictEqual(slots[5], expected, global))
            fail("private FFI CallFrame this mismatch");
    }
    for (ffi_function_fixture.args[0..ffi_function_fixture.arg_count], slots[6 .. 6 + ffi_function_fixture.arg_count]) |expected, actual| {
        if (expected != actual) fail("private FFI CallFrame argument mismatch");
    }
    ffi_function_fixture.observed_data = Bun__FFIFunction_getDataPtr(slots[3]);
    if (ffi_function_fixture.observed_data != ffi_function_fixture.expected_data)
        fail("private FFI callback data mismatch");

    const constructing = JSC__JSValue__isStrictEqual(slots[5], slots[3], global);
    if (ffi_function_fixture.reenter) {
        ffi_function_fixture.reenter = false;
        const saved_args = ffi_function_fixture.args;
        const saved_count = ffi_function_fixture.arg_count;
        const saved_this = ffi_function_fixture.expected_this;
        ffi_function_fixture.args = .{ EncodedValue.fromInt32(1), EncodedValue.fromInt32(2) };
        ffi_function_fixture.arg_count = 2;
        ffi_function_fixture.expected_this = null;
        const nested = evaluate(global, "__private_ffi_function_252(1, 2)");
        ffi_function_fixture.args = saved_args;
        ffi_function_fixture.arg_count = saved_count;
        ffi_function_fixture.expected_this = saved_this;
        ffi_function_fixture.reentry_ok = JSC__JSValue__isStrictEqual(nested, EncodedValue.fromInt32(3), global) and
            Bun__FFIFunction_getDataPtr(slots[3]) == ffi_function_fixture.expected_data;
    }
    ffi_function_fixture.calls += 1;

    if (constructing) {
        ffi_function_fixture.constructs += 1;
        const instance = JSC__JSValue__createEmptyObject(global, 1);
        const key_bytes = "constructed";
        const key = ZigString{ .tagged_ptr = @intFromPtr(key_bytes.ptr), .len = key_bytes.len };
        JSC__JSValue__put(instance, global, &key, if (ffi_function_fixture.arg_count > 0) slots[6] else .undefined);
        return instance;
    }

    var total: i32 = 0;
    for (slots[6 .. 6 + ffi_function_fixture.arg_count]) |argument|
        total += JSC__JSValue__toInt32(argument);
    return EncodedValue.fromInt32(total);
}

fn ffiFunctionThrow(global: JSContextRef, frame: *PrivateCallFrame) callconv(.c) EncodedValue {
    _ = frame;
    JSC__VM__throwError(JSC__JSGlobalObject__vm(global), global, EncodedValue.fromInt32(2521));
    return .empty;
}

fn fail(message: []const u8) noreturn {
    std.debug.print("Home private value shims: {s}\n", .{message});
    std.process.exit(1);
}

fn emptyBunString() BunString {
    return .{ .tag = .empty, .value = .{ .zig_string = .{ .tagged_ptr = 0, .len = 0 } } };
}

fn derefBunString(string: BunString) void {
    if (string.tag == .wtf_string_impl) Bun__WTFStringImpl__deref(string.value.wtf_string_impl);
}

fn releaseZigException(exception: *ZigException) void {
    derefBunString(exception.syscall);
    derefBunString(exception.system_code);
    derefBunString(exception.path);
    derefBunString(exception.name);
    derefBunString(exception.message);
    derefBunString(exception.browser_url);
    if (exception.stack.source_lines_ptr != null) {
        for (exception.stack.source_lines_ptr[0..exception.stack.source_lines_len]) |line| derefBunString(line);
    }
    if (exception.stack.frames_ptr != null) {
        for (exception.stack.frames_ptr[0..exception.stack.frames_len]) |frame| {
            derefBunString(frame.function_name);
            derefBunString(frame.source_url);
        }
    }
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
    const cell = encoded.cellPointer() orelse
        (JSValueMakeNumber(context, @floatFromInt(JSC__JSValue__toInt32(encoded))) orelse
            fail("failed to materialize an immediate value"));
    var exception: JSValueRef = null;
    JSObjectSetProperty(context, global, property, cell, 0, &exception);
    if (exception != null) fail("global property write failed");
}

const ExternalStringProbe = struct {
    expected_pointer: ?*anyopaque,
    expected_len: usize,

    fn release(raw: ?*anyopaque, pointer: ?*anyopaque, len: usize) callconv(.c) void {
        const self: *@This() = @ptrCast(@alignCast(raw orelse fail("external ZigString callback context missing")));
        if (pointer != self.expected_pointer or len != self.expected_len)
            fail("external ZigString callback arguments mismatch");
    }

    fn releaseNull(raw: ?*anyopaque, _: ?*anyopaque, _: usize) callconv(.c) void {
        if (raw != null) fail("external ZigString null callback context mismatch");
    }
};

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

const JSStringIteratorState = struct {
    units: [16]u16 = @splat(0),
    len: usize = 0,
    calls: usize = 0,
    width: u8 = 0,
};

fn jsStringAppend8(iterator: *JSStringIterator, bytes: [*]const u8, len: u32) callconv(.c) void {
    const state: *JSStringIteratorState = @ptrCast(@alignCast(iterator.data.?));
    state.calls += 1;
    state.width = 8;
    state.len = @intCast(len);
    for (bytes[0..@as(usize, @intCast(len))], 0..) |byte, i| state.units[i] = byte;
}

fn jsStringAppend16(iterator: *JSStringIterator, units: [*]const u16, len: u32) callconv(.c) void {
    const state: *JSStringIteratorState = @ptrCast(@alignCast(iterator.data.?));
    state.calls += 1;
    state.width = 16;
    state.len = @intCast(len);
    @memcpy(state.units[0..@as(usize, @intCast(len))], units[0..@as(usize, @intCast(len))]);
}

fn jsStringIterator(state: *JSStringIteratorState) JSStringIterator {
    return .{
        .data = state,
        .stop = 0,
        .append8 = jsStringAppend8,
        .append16 = jsStringAppend16,
        .write8 = null,
        .write16 = null,
    };
}

fn runFetchHeadersFixture(context: JSContextRef, vm: ?*anyopaque) void {
    const headers = WebCore__FetchHeaders__createEmpty();
    defer WebCore__FetchHeaders__deref(headers);
    if (!WebCore__FetchHeaders__isEmpty(headers)) fail("private FetchHeaders empty state mismatch");

    var accept = ZigString{ .tagged_ptr = @intFromPtr("Accept".ptr), .len = "Accept".len };
    var plain = ZigString{ .tagged_ptr = @intFromPtr(" text/plain ".ptr), .len = " text/plain ".len };
    var json = ZigString{ .tagged_ptr = @intFromPtr("application/json".ptr), .len = "application/json".len };
    WebCore__FetchHeaders__append(headers, &accept, &plain, context);
    WebCore__FetchHeaders__append(headers, &accept, &json, context);
    var output: ZigString = .{ .tagged_ptr = 0, .len = 0 };
    WebCore__FetchHeaders__get_(headers, &accept, &output, context);
    if (!zigStringUtf8Equals(output, "text/plain, application/json")) fail("private FetchHeaders append/get mismatch");

    var content_type = ZigString{ .tagged_ptr = @intFromPtr("text/html".ptr), .len = "text/html".len };
    WebCore__FetchHeaders__put(headers, 25, &content_type, context);
    var custom_name = ZigString{ .tagged_ptr = @intFromPtr("x-home".ptr), .len = "x-home".len };
    var custom_value = ZigString{ .tagged_ptr = @intFromPtr("fixture".ptr), .len = "fixture".len };
    WebCore__FetchHeaders__put_(headers, &custom_name, &custom_value, context);
    if (!WebCore__FetchHeaders__fastHas_(headers, 25) or !WebCore__FetchHeaders__has(headers, &custom_name, context))
        fail("private FetchHeaders has mismatch");
    output = .{ .tagged_ptr = 0, .len = 0 };
    WebCore__FetchHeaders__fastGet_(headers, 25, &output);
    if (!zigStringUtf8Equals(output, "text/html")) fail("private FetchHeaders fastGet mismatch");

    var count: u32 = 0;
    var bytes_len: u32 = 0;
    WebCore__FetchHeaders__count(headers, &count, &bytes_len);
    if (count != 3 or bytes_len == 0) fail("private FetchHeaders count mismatch");
    const names = std.heap.page_allocator.alloc(FetchHeadersStringPointer, count) catch fail("private FetchHeaders names allocation failed");
    defer std.heap.page_allocator.free(names);
    const values = std.heap.page_allocator.alloc(FetchHeadersStringPointer, count) catch fail("private FetchHeaders values allocation failed");
    defer std.heap.page_allocator.free(values);
    const bytes = std.heap.page_allocator.alloc(u8, bytes_len) catch fail("private FetchHeaders buffer allocation failed");
    defer std.heap.page_allocator.free(bytes);
    WebCore__FetchHeaders__copyTo(headers, names.ptr, values.ptr, bytes.ptr);
    if (!std.mem.eql(u8, bytes[names[0].offset .. names[0].offset + names[0].length], "Accept"))
        fail("private FetchHeaders copyTo mismatch");

    const wrapped = WebCore__FetchHeaders__toJS(headers, context);
    if (wrapped == .empty or WebCore__FetchHeaders__cast_(wrapped, vm) != headers or
        WebCore__FetchHeaders__toJS(headers, context) != wrapped or
        WebCore__FetchHeaders__cast_(evaluate(context, "Object.create(Headers.prototype)"), vm) != null)
        fail("private FetchHeaders branding/identity mismatch");
    const clone_value = WebCore__FetchHeaders__clone(headers, context);
    if (clone_value == .empty or WebCore__FetchHeaders__cast_(clone_value, vm) == null)
        fail("private FetchHeaders clone wrapper mismatch");
    const native_clone = WebCore__FetchHeaders__cloneThis(headers, context) orelse fail("private FetchHeaders cloneThis failed");
    WebCore__FetchHeaders__fastRemove_(native_clone, 25);
    if (WebCore__FetchHeaders__fastHas_(native_clone, 25) or !WebCore__FetchHeaders__fastHas_(headers, 25))
        fail("private FetchHeaders clone independence mismatch");
    WebCore__FetchHeaders__deref(native_clone);

    const table = "A1Set-Cookiea=1Set-Cookieb=2";
    var table_string = ZigString{ .tagged_ptr = @intFromPtr(table.ptr), .len = table.len };
    const table_names = [_]FetchHeadersStringPointer{
        .{ .offset = 0, .length = 1 },
        .{ .offset = 2, .length = 10 },
        .{ .offset = 15, .length = 10 },
    };
    const table_values = [_]FetchHeadersStringPointer{
        .{ .offset = 1, .length = 1 },
        .{ .offset = 12, .length = 3 },
        .{ .offset = 25, .length = 3 },
    };
    const native_table = WebCore__FetchHeaders__createValueNotJS(context, &table_names, &table_values, &table_string, @intCast(table_names.len)) orelse
        fail("private FetchHeaders createValueNotJS failed");
    WebCore__FetchHeaders__deref(native_table);
    if (WebCore__FetchHeaders__createValue(context, &table_names, &table_values, &table_string, @intCast(table_names.len)) == .empty)
        fail("private FetchHeaders createValue failed");
    const from_js = WebCore__FetchHeaders__createFromJS(context, evaluate(context, "[['A','1'],['a','2']]")) orelse
        fail("private FetchHeaders createFromJS failed");
    WebCore__FetchHeaders__deref(from_js);

    WebCore__FetchHeaders__remove(headers, &custom_name, context);
    if (WebCore__FetchHeaders__has(headers, &custom_name, context)) fail("private FetchHeaders remove mismatch");
}

pub fn main() void {
    const context = JSGlobalContextCreate(null) orelse fail("context creation failed");
    defer JSGlobalContextRelease(context);

    const private_pow_negative_zero = Bun__JSC__operationMathPow(-0.0, 3);
    if (Bun__JSC__operationMathPow(2, 10) != 1024 or
        !std.math.isNan(Bun__JSC__operationMathPow(1, std.math.nan(f64))) or
        !std.math.isNan(Bun__JSC__operationMathPow(-1, std.math.inf(f64))) or
        private_pow_negative_zero != 0 or !std.math.signbit(private_pow_negative_zero) or
        Bun__JSC__operationMathPow(-0.0, -3) != -std.math.inf(f64))
        fail("private JSC Math.pow operation mismatch");

    // The pinned bridge is deliberately dormant without an attached debugger
    // agent, but every enum and lifecycle entry still crosses the real ABI.
    for ([_]DebuggerAsyncCallType{ .DOMTimer, .EventListener, .PostMessage, .RequestAnimationFrame, .Microtask }, 0..) |call_type, index| {
        const callback_id: u64 = if (index == 0) 0 else if (index == 4) std.math.maxInt(u64) else @intCast(index);
        Debugger__didScheduleAsyncCall(context, call_type, callback_id, index != 1);
        Debugger__willDispatchAsyncCall(context, call_type, callback_id);
        Debugger__didDispatchAsyncCall(context, call_type, callback_id);
        Debugger__didCancelAsyncCall(context, call_type, callback_id);
    }
    Debugger__didScheduleAsyncCall(null, .EventListener, 1, true);
    Debugger__didCancelAsyncCall(null, .EventListener, 1);
    Debugger__willDispatchAsyncCall(null, .EventListener, 1);
    Debugger__didDispatchAsyncCall(null, .EventListener, 1);

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

    // Invoke this ABI near the start of the independently compiled consumer so
    // later long-running watchdog coverage cannot mask a linkage/runtime fault.
    const inspect_receiver = evaluate(context, "({ value: 322 })");
    const inspect_function = evaluate(context, "(function(d,o,i){return this.value===322&&d===3&&o.depth===9&&!o.colors&&" ++
        "Object.keys(o).join(',')==='stylize,depth,colors'&&typeof o.stylize==='function'&&" ++
        "typeof i==='function'&&i(322,o)==='322'})");
    if (JSC__JSValue__callCustomInspectFunction(context, inspect_function, inspect_receiver, 3, 9, false) != .true)
        fail("private custom inspect invocation mismatch");

    // Revision-pinned counted protection (#367): the encoded cell discovers
    // its owning VM without a global argument and remains live until the final
    // matching unprotect. Primitive and unmatched calls are exact no-ops.
    const protected_context = ZJSGlobalContextCreateGarbageCollected(false) orelse
        fail("private protected-value context creation failed");
    defer JSGlobalContextRelease(protected_context);
    const protected_value = evaluate(protected_context, "({ marker: 367 })");
    Bun__JSValue__protect(.empty);
    Bun__JSValue__protect(.undefined);
    Bun__JSValue__protect(EncodedValue.fromInt32(367));
    Bun__JSValue__unprotect(.null);
    Bun__JSValue__protect(protected_value);
    Bun__JSValue__protect(protected_value);
    JSGarbageCollect(protected_context);
    if (JSValueToNumber(
        protected_context,
        getProperty(protected_context, protected_value, "marker").cellPointer(),
        null,
    ) != 367)
        fail("private protected value did not survive collection");
    Bun__JSValue__unprotect(protected_value);
    JSGarbageCollect(protected_context);
    if (JSValueToNumber(
        protected_context,
        getProperty(protected_context, protected_value, "marker").cellPointer(),
        null,
    ) != 367)
        fail("private counted protection released too early");
    Bun__JSValue__unprotect(protected_value);
    Bun__JSValue__unprotect(protected_value);

    // Revision-pinned property iterator (#368): the independently compiled
    // consumer sees the exact opaque pointer/BunString ABI, stable name
    // snapshot, UTF-16 length, and observable-versus-VMInquiry split.
    const iterator_target = evaluate(context, "globalThis.__property_iterator_gets_368 = 0; " ++
        "globalThis.__property_iterator_target_368 = { 2: 2, 0: 0, alpha: 10, " ++
        "get getter() { __property_iterator_gets_368++; return 20; }, 'unicode😀key': 30, [Symbol('ownSymbol')]: 40 }; " ++
        "__property_iterator_target_368");
    var iterator_count: usize = 999;
    const property_iterator = Bun__JSPropertyIterator__create(context, iterator_target, &iterator_count, true, false) orelse
        fail("private property iterator creation failed");
    defer Bun__JSPropertyIterator__deinit(property_iterator);
    if (iterator_count != 6 or
        Bun__JSPropertyIterator__getLongestPropertyName(property_iterator, context, iterator_target.cellPointer()) != 12)
        fail("private property iterator count/UTF-16 length mismatch");
    const iterator_names = [_][]const u8{ "0", "2", "alpha", "getter", "unicode😀key", "ownSymbol" };
    for (iterator_names, 0..) |expected, index| {
        var property_name = emptyBunString();
        Bun__JSPropertyIterator__getName(property_iterator, &property_name, index);
        if (property_name.tag != .zig_string or !bunStringUtf8Equals(property_name, expected))
            fail("private property iterator name order/borrow mismatch");
    }
    var property_name = emptyBunString();
    if (Bun__JSPropertyIterator__getNameAndValueNonObservable(
        property_iterator,
        context,
        iterator_target.cellPointer(),
        &property_name,
        3,
    ) != .empty or property_name.tag != .dead or
        JSValueToNumber(context, evaluate(context, "__property_iterator_gets_368").cellPointer(), null) != 0)
        fail("private property iterator VM inquiry invoked a getter");
    const observable_property = Bun__JSPropertyIterator__getNameAndValue(
        property_iterator,
        context,
        iterator_target.cellPointer(),
        &property_name,
        3,
    );
    const observable_gets = JSValueToNumber(context, evaluate(context, "__property_iterator_gets_368").cellPointer(), null);
    if (observable_property != EncodedValue.fromInt32(20) or !bunStringUtf8Equals(property_name, "getter") or observable_gets != 1)
        fail("private property iterator observable getter mismatch");
    _ = evaluate(context, "delete __property_iterator_target_368.alpha; __property_iterator_target_368.afterSnapshot = 50");
    if (Bun__JSPropertyIterator__getNameAndValue(
        property_iterator,
        context,
        iterator_target.cellPointer(),
        &property_name,
        2,
    ) != .empty)
        fail("private property iterator value lookup ignored live deletion");
    Bun__JSPropertyIterator__getName(property_iterator, &property_name, 2);
    if (!bunStringUtf8Equals(property_name, "alpha"))
        fail("private property iterator name snapshot changed after mutation");

    // Revision-pinned native TextCodec fallback (#327): exact registry,
    // stable canonical-name storage, incremental state, errors, and ownership.
    const sjis_label = "sJiS";
    const sjis_alias = "windows-31j";
    if (!Bun__isEncodingSupported(sjis_label.ptr, sjis_label.len) or
        Bun__isEncodingSupported("utf-8".ptr, "utf-8".len) or
        Bun__isEncodingSupported(" sjis".ptr, " sjis".len))
        fail("private TextCodec support registry mismatch");
    var canonical_len: usize = 99;
    const canonical = Bun__getCanonicalEncodingName(sjis_label.ptr, sjis_label.len, &canonical_len) orelse
        fail("private TextCodec canonical name missing");
    var alias_len: usize = 99;
    const canonical_alias = Bun__getCanonicalEncodingName(sjis_alias.ptr, sjis_alias.len, &alias_len) orelse
        fail("private TextCodec canonical alias missing");
    if (!std.mem.eql(u8, canonical[0..canonical_len], "Shift_JIS") or
        canonical != canonical_alias or canonical_len != alias_len)
        fail("private TextCodec canonical name mismatch");
    var rejected_len: usize = 99;
    if (Bun__getCanonicalEncodingName("utf-8".ptr, "utf-8".len, &rejected_len) != null or rejected_len != 0)
        fail("private TextCodec canonical rejection mismatch");

    const sjis_codec = Bun__createTextCodec(sjis_label.ptr, sjis_label.len) orelse
        fail("private TextCodec creation failed");
    var saw_codec_error = true;
    const sjis_lead = [_]u8{0x82};
    const split_empty = Bun__decodeWithTextCodec(sjis_codec, &sjis_lead, sjis_lead.len, false, false, &saw_codec_error);
    if (!bunStringUtf8Equals(split_empty, "") or saw_codec_error)
        fail("private TextCodec incremental lead mismatch");
    const sjis_trail = [_]u8{0xa0};
    const split_value = Bun__decodeWithTextCodec(sjis_codec, &sjis_trail, sjis_trail.len, false, false, &saw_codec_error);
    if (!bunStringUtf8Equals(split_value, "\u{3042}") or saw_codec_error)
        fail("private TextCodec incremental trail mismatch");
    if (split_value.tag == .wtf_string_impl) Bun__WTFStringImpl__deref(split_value.value.wtf_string_impl);
    const invalid_sjis = [_]u8{ 0xfd, 'A' };
    const stopped_value = Bun__decodeWithTextCodec(sjis_codec, &invalid_sjis, invalid_sjis.len, true, true, &saw_codec_error);
    if (!bunStringUtf8Equals(stopped_value, "\u{fffd}") or !saw_codec_error)
        fail("private TextCodec stop-on-error mismatch");
    if (stopped_value.tag == .wtf_string_impl) Bun__WTFStringImpl__deref(stopped_value.value.wtf_string_impl);
    Bun__stripBOMFromTextCodec(sjis_codec);
    Bun__deleteTextCodec(sjis_codec);

    const replacement_label = "replacement";
    const replacement_codec = Bun__createTextCodec(replacement_label.ptr, replacement_label.len) orelse
        fail("private replacement TextCodec creation failed");
    const replacement_first = Bun__decodeWithTextCodec(replacement_codec, "ignored".ptr, "ignored".len, false, false, &saw_codec_error);
    if (!bunStringUtf8Equals(replacement_first, "\u{fffd}") or !saw_codec_error)
        fail("private replacement TextCodec first result mismatch");
    if (replacement_first.tag == .wtf_string_impl) Bun__WTFStringImpl__deref(replacement_first.value.wtf_string_impl);
    const replacement_second = Bun__decodeWithTextCodec(replacement_codec, "ignored".ptr, "ignored".len, true, true, &saw_codec_error);
    if (!bunStringUtf8Equals(replacement_second, "") or !saw_codec_error)
        fail("private replacement TextCodec state mismatch");
    Bun__deleteTextCodec(replacement_codec);

    const user_label = "x-user-defined";
    const user_codec = Bun__createTextCodec(user_label.ptr, user_label.len) orelse
        fail("private user-defined TextCodec creation failed");
    const user_bytes = [_]u8{ 0x41, 0x80, 0xff };
    const user_value = Bun__decodeWithTextCodec(user_codec, &user_bytes, user_bytes.len, true, false, &saw_codec_error);
    if (!bunStringUtf8Equals(user_value, "A\u{f780}\u{f7ff}") or saw_codec_error)
        fail("private user-defined TextCodec mapping mismatch");
    if (user_value.tag == .wtf_string_impl) Bun__WTFStringImpl__deref(user_value.value.wtf_string_impl);
    Bun__deleteTextCodec(user_codec);

    // One JS/native AbortSignal identity with exact-once native callbacks,
    // common/arbitrary reason channels, selective cleanup, and balanced roots.
    const AbortCallback = struct {
        calls: usize = 0,
        reason: EncodedValue = .empty,

        fn run(raw: ?*anyopaque, reason: EncodedValue) callconv(.c) void {
            const state: *@This() = @ptrCast(@alignCast(raw orelse return));
            state.calls += 1;
            state.reason = reason;
        }
    };
    const abort_value = WebCore__AbortSignal__create(context);
    const abort_signal = WebCore__AbortSignal__fromJS(abort_value) orelse
        fail("private AbortSignal create/fromJS mismatch");
    if (WebCore__AbortSignal__fromJS(abort_value) != abort_signal or
        !JSC__JSValue__isStrictEqual(WebCore__AbortSignal__toJS(abort_signal, context), abort_value, context) or
        WebCore__AbortSignal__aborted(abort_signal))
        fail("private AbortSignal identity mismatch");
    var common_abort_reason: u8 = 99;
    if (WebCore__AbortSignal__reasonIfAborted(abort_signal, context, &common_abort_reason) != .empty or common_abort_reason != 0)
        fail("private AbortSignal pending reason mismatch");
    var abort_callback = AbortCallback{};
    if (WebCore__AbortSignal__addListener(abort_signal, &abort_callback, AbortCallback.run) != abort_signal)
        fail("private AbortSignal listener registration mismatch");
    WebCore__AbortSignal__signal(abort_signal, context, 1);
    if (!WebCore__AbortSignal__aborted(abort_signal) or abort_callback.calls != 1 or abort_callback.reason == .empty or
        WebCore__AbortSignal__reasonIfAborted(abort_signal, context, &common_abort_reason) != .undefined or common_abort_reason != 1 or
        !JSC__JSValue__isStrictEqual(WebCore__AbortSignal__abortReason(abort_signal), abort_callback.reason, context))
        fail("private AbortSignal common abort mismatch");
    WebCore__AbortSignal__signal(abort_signal, context, 2);
    if (abort_callback.calls != 1) fail("private AbortSignal duplicate abort mismatch");

    const cleaned_value = WebCore__AbortSignal__create(context);
    const cleaned_signal = WebCore__AbortSignal__fromJS(cleaned_value) orelse fail("private AbortSignal cleanup creation failed");
    var removed_callback = AbortCallback{};
    _ = WebCore__AbortSignal__addListener(cleaned_signal, &removed_callback, AbortCallback.run);
    WebCore__AbortSignal__cleanNativeBindings(cleaned_signal, &removed_callback);
    WebCore__AbortSignal__signal(cleaned_signal, context, 3);
    if (removed_callback.calls != 0) fail("private AbortSignal selective cleanup mismatch");

    const js_abort_value = evaluate(context, "globalThis.__fixture_abort_329 = new AbortController(); __fixture_abort_329.signal");
    const js_abort_signal = WebCore__AbortSignal__fromJS(js_abort_value) orelse fail("private JS AbortSignal downcast failed");
    var js_abort_callback = AbortCallback{};
    _ = WebCore__AbortSignal__addListener(js_abort_signal, &js_abort_callback, AbortCallback.run);
    _ = evaluate(context, "__fixture_abort_329.abort({ marker: 329 })");
    common_abort_reason = 99;
    const js_abort_reason = WebCore__AbortSignal__reasonIfAborted(js_abort_signal, context, &common_abort_reason);
    if (js_abort_callback.calls != 1 or common_abort_reason != 0 or js_abort_reason == .empty or
        !JSC__JSValue__isStrictEqual(js_abort_reason, js_abort_callback.reason, context))
        fail("private AbortSignal arbitrary reason mismatch");
    if (WebCore__AbortSignal__fromJS(evaluate(context, "({})")) != null)
        fail("private AbortSignal accepted unbranded object");

    const owned_abort = WebCore__AbortSignal__new(context);
    if (WebCore__AbortSignal__ref(owned_abort) != owned_abort) fail("private AbortSignal ref mismatch");
    WebCore__AbortSignal__incrementPendingActivity(owned_abort);
    WebCore__AbortSignal__decrementPendingActivity(owned_abort);
    WebCore__AbortSignal__unref(owned_abort);
    WebCore__AbortSignal__unref(owned_abort);

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

    var iter_state = JSStringIteratorState{};
    var string_iterator = jsStringIterator(&iter_state);
    JSC__JSString__iterator(evaluate(context, "'café\\u0000'").cellPointer(), context, &string_iterator);
    if (iter_state.calls != 1 or iter_state.width != 8 or iter_state.len != 5 or
        !std.mem.eql(u16, iter_state.units[0..5], &.{ 'c', 'a', 'f', 0xe9, 0 }))
        fail("private JSString iterator Latin-1 delivery mismatch");
    iter_state = .{};
    string_iterator = jsStringIterator(&iter_state);
    JSC__JSString__iterator(evaluate(context, "'A😀\\uD800Z'").cellPointer(), context, &string_iterator);
    if (iter_state.calls != 1 or iter_state.width != 16 or iter_state.len != utf16_units.len or
        !std.mem.eql(u16, iter_state.units[0..iter_state.len], &utf16_units))
        fail("private JSString iterator UTF-16 delivery mismatch");
    iter_state = .{};
    string_iterator = jsStringIterator(&iter_state);
    JSC__JSString__iterator(evaluate(context, "''").cellPointer(), context, &string_iterator);
    if (iter_state.calls != 1 or iter_state.width != 8 or iter_state.len != 0)
        fail("private JSString iterator empty delivery mismatch");
    string_iterator.stop = 1;
    JSC__JSString__iterator(evaluate(context, "'stopped'").cellPointer(), context, &string_iterator);
    JSC__JSString__iterator(evaluate(foreign_context, "'foreign'").cellPointer(), context, &string_iterator);
    JSC__JSString__iterator(null, context, &string_iterator);
    JSC__JSString__iterator(evaluate(context, "'null-iterator'").cellPointer(), context, null);
    if (iter_state.calls != 1)
        fail("private JSString iterator invalid/stop boundary invoked a callback");
    JSC__VM__throwError(JSC__JSGlobalObject__vm(context), context, EncodedValue.fromInt32(247));
    string_iterator.stop = 0;
    JSC__JSString__iterator(evaluate(foreign_context, "'pending'").cellPointer(), context, &string_iterator);
    const string_iterator_exception_247 = JSGlobalObject__tryTakeException(context);
    if (iter_state.calls != 1 or JSC__Exception__asJSValue(string_iterator_exception_247.cellPointer()) != EncodedValue.fromInt32(247))
        fail("private JSString iterator replaced a pending exception");

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

    var array_buffer_source = [_]u8{ 11, 12, 13, 14 };
    const copied_array_buffer = Bun__createArrayBufferForCopy(context, &array_buffer_source, array_buffer_source.len);
    const copied_array_buffer_raw = JSObjectGetArrayBufferBytesPtr(context, copied_array_buffer.cellPointer(), &typed_exception) orelse
        fail("ArrayBuffer copy bytes lookup failed");
    const copied_array_buffer_bytes = @as([*]u8, @ptrCast(copied_array_buffer_raw))[0..array_buffer_source.len];
    if (typed_exception != null or
        JSObjectGetArrayBufferByteLength(context, copied_array_buffer.cellPointer(), &typed_exception) != array_buffer_source.len or
        !std.mem.eql(u8, copied_array_buffer_bytes, &array_buffer_source))
        fail("ArrayBuffer copy constructor mismatch");
    array_buffer_source[0] = 99;
    if (copied_array_buffer_bytes[0] != 11) fail("ArrayBuffer copy aliases its source");

    var allocated_uint8_raw: *anyopaque = @ptrFromInt(1);
    const allocated_uint8 = Bun__allocUint8ArrayForCopy(context, 4, &allocated_uint8_raw);
    const allocated_uint8_bytes = JSObjectGetTypedArrayBytesPtr(context, allocated_uint8.cellPointer(), &typed_exception) orelse
        fail("allocated Uint8Array bytes lookup failed");
    if (typed_exception != null or allocated_uint8_bytes != allocated_uint8_raw or
        JSObjectGetTypedArrayLength(context, allocated_uint8.cellPointer(), &typed_exception) != 4 or
        JSBuffer__isBuffer(context, allocated_uint8))
        fail("allocated Uint8Array pointer/result mismatch");
    @as([*]u8, @ptrCast(allocated_uint8_raw))[2] = 77;
    if (@as([*]const u8, @ptrCast(allocated_uint8_bytes))[2] != 77)
        fail("allocated Uint8Array pointer did not expose its backing");

    var allocated_private_buffer_raw: *anyopaque = @ptrFromInt(1);
    const allocated_private_buffer = Bun__allocArrayBufferForCopy(context, 3, &allocated_private_buffer_raw);
    const allocated_private_buffer_bytes = JSObjectGetTypedArrayBytesPtr(context, allocated_private_buffer.cellPointer(), &typed_exception) orelse
        fail("allocated Buffer bytes lookup failed");
    if (typed_exception != null or allocated_private_buffer_bytes != allocated_private_buffer_raw or
        JSObjectGetTypedArrayLength(context, allocated_private_buffer.cellPointer(), &typed_exception) != 3 or
        !JSBuffer__isBuffer(context, allocated_private_buffer))
        fail("historically named ArrayBuffer allocator did not return a Buffer view");

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

    const adopted_default_array_buffer_raw = std.c.malloc(3) orelse fail("default-allocator ArrayBuffer fixture allocation failed");
    const adopted_array_buffer_input = @as([*]u8, @ptrCast(adopted_default_array_buffer_raw))[0..3];
    @memcpy(adopted_array_buffer_input, &[_]u8{ 31, 32, 33 });
    const adopted_default_array_buffer = JSArrayBuffer__fromDefaultAllocator(
        context,
        adopted_array_buffer_input.ptr,
        adopted_array_buffer_input.len,
    );
    const adopted_default_array_buffer_bytes = JSObjectGetArrayBufferBytesPtr(
        context,
        adopted_default_array_buffer.cellPointer(),
        &typed_exception,
    ) orelse fail("adopted ArrayBuffer bytes lookup failed");
    if (typed_exception != null or adopted_default_array_buffer_bytes != adopted_default_array_buffer_raw or
        JSObjectGetArrayBufferByteLength(context, adopted_default_array_buffer.cellPointer(), &typed_exception) != 3 or
        !std.mem.eql(u8, @as([*]const u8, @ptrCast(adopted_default_array_buffer_bytes))[0..3], adopted_array_buffer_input))
        fail("default-allocator ArrayBuffer did not adopt its bytes");

    const empty_default_array_buffer = JSArrayBuffer__fromDefaultAllocator(context, @ptrCast(&empty_sentinel), 0);
    if (JSObjectGetArrayBufferByteLength(context, empty_default_array_buffer.cellPointer(), &typed_exception) != 0 or typed_exception != null)
        fail("empty default-allocator ArrayBuffer mismatch");

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

        const shared_file = tmpfile() orelse fail("shared memfd fixture file creation failed");
        defer _ = std.c.fclose(shared_file);
        const shared_source = [_]u8{ 31, 32, 33, 34, 35, 36, 37, 38, 39, 40 };
        if (std.c.fwrite(&shared_source, 1, shared_source.len, shared_file) != shared_source.len or fflush(shared_file) != 0)
            fail("shared memfd fixture write failed");
        const shared_native_fd = fileno(shared_file);
        if (shared_native_fd < 0) fail("shared memfd fixture descriptor lookup failed");
        const shared_fd: i64 = shared_native_fd;

        const shared_array_buffer = ArrayBuffer__fromSharedMemfd(shared_fd, context, 2, 5, shared_source.len, 48);
        const shared_array_buffer_ptr = JSObjectGetArrayBufferBytesPtr(context, shared_array_buffer.cellPointer(), &typed_exception) orelse
            fail("shared memfd ArrayBuffer pointer lookup failed");
        const shared_array_buffer_bytes = @as([*]u8, @ptrCast(shared_array_buffer_ptr))[0..5];
        if (typed_exception != null or
            JSObjectGetArrayBufferByteLength(context, shared_array_buffer.cellPointer(), &typed_exception) != 5 or
            !std.mem.eql(u8, shared_array_buffer_bytes, shared_source[2..7]))
            fail("shared memfd ArrayBuffer slice mismatch");
        shared_array_buffer_bytes[0] = 0xee;
        var shared_file_bytes: [shared_source.len]u8 = undefined;
        const shared_file_read = std.c.pread(shared_native_fd, &shared_file_bytes, shared_file_bytes.len, 0);
        if (shared_file_read != @as(isize, @intCast(shared_source.len)) or !std.mem.eql(u8, &shared_file_bytes, &shared_source))
            fail("shared memfd mapping was not private");

        const shared_uint8 = ArrayBuffer__fromSharedMemfd(shared_fd, context, 4, 3, shared_source.len, 50);
        const shared_uint8_ptr = JSObjectGetTypedArrayBytesPtr(context, shared_uint8.cellPointer(), &typed_exception) orelse
            fail("shared memfd Uint8Array pointer lookup failed");
        if (typed_exception != null or JSBuffer__isBuffer(context, shared_uint8) or
            JSObjectGetTypedArrayLength(context, shared_uint8.cellPointer(), &typed_exception) != 3 or
            !std.mem.eql(u8, @as([*]u8, @ptrCast(shared_uint8_ptr))[0..3], shared_source[4..7]))
            fail("shared memfd Uint8Array slice mismatch");
        if (ArrayBuffer__fromSharedMemfd(-1, context, 0, 1, 1, 48) != .empty or
            ArrayBuffer__fromSharedMemfd(shared_fd, context, shared_source.len, 1, shared_source.len, 48) != .empty or
            ArrayBuffer__fromSharedMemfd(shared_fd, context, 0, 1, shared_source.len, 61) != .empty or
            JSGlobalObject__hasException(context))
            fail("invalid shared memfd input was not rejected cleanly");
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

    // The pinned generated path converts IDLArrayBufferRef to RefPtr and then
    // leaks one native +1 into each field. Exercise required, optional, and
    // union-shaped adopters plus an explicit clone before destroying the VM.
    const GeneratedFields = struct {
        required: *PrivateArrayBufferHandle,
        optional: ?*PrivateArrayBufferHandle,
        variant: union(enum) { none, buffer: *PrivateArrayBufferHandle },
    };
    const handle_context = JSGlobalContextCreate(null) orelse fail("ArrayBuffer handle context creation failed");
    const generated_value = evaluate(handle_context, "globalThis.__native_backing = new ArrayBuffer(6, { maxByteLength: 12 });" ++
        "new Uint8Array(__native_backing).fill(37); new Uint8Array(__native_backing)");
    var generated = GeneratedFields{
        .required = JSC__IDLArrayBufferRef__convertToExtern(generated_value, handle_context) orelse
            fail("required ArrayBuffer handle conversion failed"),
        .optional = JSC__IDLArrayBufferRef__convertToExtern(generated_value, handle_context) orelse
            fail("optional ArrayBuffer handle conversion failed"),
        .variant = .{ .buffer = JSC__IDLArrayBufferRef__convertToExtern(generated_value, handle_context) orelse
            fail("union ArrayBuffer handle conversion failed") },
    };
    if (generated.required != generated.optional.? or generated.required != generated.variant.buffer or
        JSC__IDLArrayBufferRef__convertToExtern(EncodedValue.fromInt32(1), handle_context) != null)
        fail("generated ArrayBuffer producer identity/rejection mismatch");
    JSC__ArrayBuffer__ref(generated.required);
    JSGlobalContextRelease(handle_context);
    var generated_projection = PrivateBunArrayBuffer{};
    JSC__ArrayBuffer__asBunArrayBuffer(generated.required, &generated_projection);
    if (generated_projection.ptr == null or generated_projection.len != 6 or
        generated_projection.byte_len != 6 or generated_projection.encoded_value != .empty or
        generated_projection.cell_type != 48 or generated_projection.shared or !generated_projection.resizable or
        !std.mem.eql(u8, generated_projection.ptr.?[0..6], &[_]u8{ 37, 37, 37, 37, 37, 37 }))
        fail("generated ArrayBuffer handle did not survive VM teardown");
    JSC__ArrayBuffer__deref(generated.required); // explicit clone
    JSC__ArrayBuffer__deref(generated.required); // required field
    JSC__ArrayBuffer__deref(generated.optional.?); // optional field
    JSC__ArrayBuffer__deref(generated.variant.buffer); // union field
    generated.optional = null;
    generated.variant = .none;

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
        Bun__JSValue__toNumber(evaluate(context, "__private_error_like_gets"), context) != 0)
        fail("private rejection error-like classification mismatch");
    _ = evaluate(context, "globalThis.__private_warnings_241 = []; process.on('warning', warning => __private_warnings_241.push(warning));");
    Bun__Process__emitWarning(
        context,
        evaluate(context, "'consumer warning 241'"),
        evaluate(context, "({ type: 'ConsumerWarning', code: 'W241', detail: 'consumer-detail' })"),
        .undefined,
        .undefined,
    );
    _ = JSC__JSGlobalObject__drainMicrotasks(context);
    if (!JSC__JSValue__toBoolean(evaluate(context, "__private_warnings_241.length === 1 && __private_warnings_241[0] instanceof Error && __private_warnings_241[0].name === 'ConsumerWarning' && __private_warnings_241[0].code === 'W241' && __private_warnings_241[0].detail === 'consumer-detail'")))
        fail("private process warning normalization mismatch");
    Bun__promises__emitUnhandledRejectionWarning(
        context,
        evaluate(context, "({ stack: 'consumer-stack-241' })"),
        evaluate(context, "Promise.resolve(241)"),
    );
    _ = JSC__JSGlobalObject__drainMicrotasks(context);
    if (!JSC__JSValue__toBoolean(evaluate(context, "__private_warnings_241.length === 3 && __private_warnings_241[1].message === 'consumer-stack-241' && __private_warnings_241[2].name === 'UnhandledPromiseRejectionWarning' && Object.getOwnPropertyDescriptor(__private_warnings_241[2], 'stack').value === 'consumer-stack-241'")))
        fail("private unhandled rejection warning sequence mismatch");
    _ = evaluate(context, "globalThis.__private_events_242 = []; globalThis.__private_reason_242 = { issue: 242 }; globalThis.__private_promise_242 = Promise.resolve(242); globalThis.__private_on_unhandled_242 = (reason, promise) => __private_events_242.push(reason === __private_reason_242 && promise === __private_promise_242); globalThis.__private_on_handled_242 = promise => __private_events_242.push(promise === __private_promise_242); process.on('unhandledRejection', __private_on_unhandled_242); process.on('rejectionHandled', __private_on_handled_242);");
    const private_reason_242 = evaluate(context, "__private_reason_242");
    const private_promise_242 = evaluate(context, "__private_promise_242");
    if (Bun__handleUnhandledRejection(context, private_reason_242, private_promise_242) != 1 or
        !Bun__emitHandledPromiseEvent(context, private_promise_242) or
        !JSC__JSValue__toBoolean(evaluate(context, "__private_events_242.length === 2 && __private_events_242[0] && __private_events_242[1]")))
        fail("private rejection process event dispatch mismatch");
    const wrapped_rejection_242 = Bun__wrapUnhandledRejectionErrorForUncaughtException(context, EncodedValue.fromInt32(242));
    exposeCell(context, "__private_wrapped_rejection_242", wrapped_rejection_242);
    if (!JSC__JSValue__toBoolean(evaluate(context, "__private_wrapped_rejection_242 instanceof Error && __private_wrapped_rejection_242.name === 'UnhandledPromiseRejection' && __private_wrapped_rejection_242.code === 'ERR_UNHANDLED_REJECTION' && __private_wrapped_rejection_242.message.endsWith('reason \"242\".')")))
        fail("private rejection wrapper mismatch");
    _ = evaluate(context, "globalThis.__private_uncaught_242 = []; globalThis.__private_error_242 = new Error('consumer-242'); process.on('uncaughtExceptionMonitor', (error, origin) => __private_uncaught_242.push('monitor:' + origin + ':' + (error === __private_error_242))); process.on('uncaughtException', (error, origin) => __private_uncaught_242.push('handler:' + origin + ':' + (error === __private_error_242)));");
    if (Bun__handleUncaughtException(context, evaluate(context, "__private_error_242"), 1) != 1 or
        !JSC__JSValue__toBoolean(evaluate(context, "__private_uncaught_242.join(',') === 'monitor:unhandledRejection:true,handler:unhandledRejection:true'")))
        fail("private uncaught exception dispatch mismatch");
    JSC__JSGlobalObject__handleRejectedPromises(context);
    _ = evaluate(context, "globalThis.__private_auto_242 = []; globalThis.__private_auto_unhandled_242 = (reason, promise) => __private_auto_242.push(['unhandled', reason, promise]); globalThis.__private_auto_handled_242 = promise => __private_auto_242.push(['handled', promise]); process.on('unhandledRejection', __private_auto_unhandled_242); process.on('rejectionHandled', __private_auto_handled_242); globalThis.__private_early_242 = Promise.reject('early'); __private_early_242.catch(() => {});");
    JSC__JSGlobalObject__handleRejectedPromises(context);
    if (Bun__JSValue__toNumber(evaluate(context, "__private_auto_242.length"), context) != 0)
        fail("private early-handled rejection emitted an event");
    _ = evaluate(context, "globalThis.__private_late_reason_242 = { late: 242 }; globalThis.__private_late_242 = Promise.reject(__private_late_reason_242);");
    JSC__JSGlobalObject__handleRejectedPromises(context);
    JSC__JSGlobalObject__handleRejectedPromises(context);
    _ = evaluate(context, "__private_late_242.catch(() => {});");
    JSC__JSGlobalObject__handleRejectedPromises(context);
    JSC__JSGlobalObject__handleRejectedPromises(context);
    if (!JSC__JSValue__toBoolean(evaluate(context, "__private_auto_242.length === 2 && __private_auto_242[0][0] === 'unhandled' && __private_auto_242[0][1] === __private_late_reason_242 && __private_auto_242[0][2] === __private_late_242 && __private_auto_242[1][0] === 'handled' && __private_auto_242[1][1] === __private_late_242")))
        fail("private automatic rejection tracking mismatch");
    _ = evaluate(context, "process.off('unhandledRejection', __private_auto_unhandled_242); process.off('unhandledRejection', __private_on_unhandled_242); process.off('rejectionHandled', __private_auto_handled_242); process.off('rejectionHandled', __private_on_handled_242);");
    _ = evaluate(context, "globalThis.__private_ticks_243 = []; globalThis.__private_arg1_243 = { arg: 1 }; globalThis.__private_arg2_243 = { arg: 2 }; globalThis.__private_tick1_243 = function(a) { 'use strict'; __private_ticks_243.push(['one', arguments.length, a === __private_arg1_243, this === undefined]); }; globalThis.__private_tick2_243 = function(a, b) { 'use strict'; __private_ticks_243.push(['two', arguments.length, a === __private_arg1_243, b === __private_arg2_243, this === undefined]); }; globalThis.__private_outer_243 = function() { __private_ticks_243.push(['outer']); process.nextTick(() => __private_ticks_243.push(['inner'])); }; globalThis.__private_micro_243 = function() { __private_ticks_243.push(['micro']); process.nextTick(() => __private_ticks_243.push(['tick-from-micro'])); }; ");
    const private_tick1_243 = evaluate(context, "__private_tick1_243");
    const private_tick2_243 = evaluate(context, "__private_tick2_243");
    const private_outer_243 = evaluate(context, "__private_outer_243");
    const private_micro_243 = evaluate(context, "__private_micro_243");
    const private_arg1_243 = evaluate(context, "__private_arg1_243");
    const private_arg2_243 = evaluate(context, "__private_arg2_243");
    JSC__JSGlobalObject__queueMicrotaskJob(context, private_micro_243, .undefined, .undefined);
    Bun__Process__queueNextTick1(context, private_tick1_243, private_arg1_243);
    Bun__Process__queueNextTick2(context, private_tick2_243, private_arg1_243, private_arg2_243);
    Bun__Process__queueNextTick1(context, private_outer_243, .undefined);
    _ = JSC__JSGlobalObject__drainMicrotasks(context);
    if (!JSC__JSValue__toBoolean(evaluate(context, "JSON.stringify(__private_ticks_243) === '[[\"one\",1,true,true],[\"two\",2,true,true,true],[\"outer\"],[\"inner\"],[\"micro\"],[\"tick-from-micro\"]]'")))
        fail("private process nextTick queue ordering/arity mismatch");
    _ = evaluate(context, "globalThis.__private_ipc_244 = []; globalThis.__private_ipc_value_244 = { value: 244 }; globalThis.__private_ipc_handle_244 = { handle: 244 }; process.on('message', function(value, handle) { __private_ipc_244.push(['message', value === __private_ipc_value_244, handle === __private_ipc_handle_244, this === process, arguments.length]); }); process.on('error', function(value) { __private_ipc_244.push(['error', value === __private_ipc_value_244, this === process, arguments.length]); }); process.once('disconnect', function() { __private_ipc_244.push(['disconnect', this === process, arguments.length]); });");
    const private_ipc_value_244 = evaluate(context, "__private_ipc_value_244");
    const private_ipc_handle_244 = evaluate(context, "__private_ipc_handle_244");
    Process__emitMessageEvent(context, private_ipc_value_244, private_ipc_handle_244);
    Process__emitErrorEvent(context, private_ipc_value_244);
    Process__emitDisconnectEvent(context);
    Process__emitDisconnectEvent(context);
    if (!JSC__JSValue__toBoolean(evaluate(context, "JSON.stringify(__private_ipc_244) === '[[\"message\",true,true,true,2],[\"error\",true,true,1],[\"disconnect\",true,0]]'")))
        fail("private IPC process event identity/arity mismatch");

    const module_dep_source = "globalThis.__private_module_dep_runs = (globalThis.__private_module_dep_runs || 0) + 1; export const dep = 244;";
    const module_dep_origin = "/virtual/private-245-dep.js";
    var module_exception = EncodedValue.empty;
    const module_dep_namespace = JSC__JSModuleLoader__evaluate(
        context,
        module_dep_source.ptr,
        module_dep_source.len,
        module_dep_origin.ptr,
        module_dep_origin.len,
        null,
        0,
        .undefined,
        &module_exception,
    );
    if (module_dep_namespace == .empty or module_dep_namespace == .undefined or module_exception != .empty or
        Bun__JSValue__toNumber(getProperty(context, module_dep_namespace, "dep"), context) != 244)
        fail("private module loader supplied dependency mismatch");

    const module_entry_source = "globalThis.__private_module_entry_runs = (globalThis.__private_module_entry_runs || 0) + 1; import { dep } from './private-245-dep.js'; export const value = dep + 1; export const token = globalThis.__private_module_token_245;";
    const module_entry_origin = "/virtual/private-245-entry.js";
    _ = evaluate(context, "globalThis.__private_module_token_245 = { issue: 245 };");
    module_exception = .empty;
    const module_namespace = JSC__JSModuleLoader__evaluate(
        context,
        module_entry_source.ptr,
        module_entry_source.len,
        module_entry_origin.ptr,
        module_entry_origin.len,
        module_dep_origin.ptr,
        module_dep_origin.len,
        .undefined,
        &module_exception,
    );
    if (module_namespace == .empty or module_namespace == .undefined or module_exception != .empty or
        Bun__JSValue__toNumber(getProperty(context, module_namespace, "value"), context) != 245 or
        !JSC__JSValue__isStrictEqual(getProperty(context, module_namespace, "token"), evaluate(context, "__private_module_token_245"), context) or
        Bun__JSValue__toNumber(evaluate(context, "__private_module_dep_runs"), context) != 1 or
        Bun__JSValue__toNumber(evaluate(context, "__private_module_entry_runs"), context) != 1)
        fail("private module loader link/evaluation/namespace mismatch");

    const module_entry_name = BunString{
        .tag = .zig_string,
        .value = .{ .zig_string = .{ .tagged_ptr = @intFromPtr(module_entry_origin.ptr), .len = module_entry_origin.len } },
    };
    const loaded_module_cell = JSC__JSModuleLoader__loadAndEvaluateModule(context, &module_entry_name) orelse
        fail("private loadAndEvaluateModule did not return a Promise");
    const loaded_module = EncodedValue.fromBits(@intFromPtr(loaded_module_cell));
    expectPromise(context, loaded_module, .fulfilled, module_namespace);
    const imported_module_cell = JSModuleLoader__import(context, &module_entry_name) orelse
        fail("private JSModuleLoader import did not return a Promise");
    const imported_module = EncodedValue.fromBits(@intFromPtr(imported_module_cell));
    expectPromise(context, imported_module, .fulfilled, module_namespace);
    if (Bun__JSValue__toNumber(evaluate(context, "__private_module_entry_runs"), context) != 1)
        fail("private module loader cache re-evaluated an instantiated module");

    const module_tla_source = "export const awaited = await Promise.resolve(246);";
    const module_tla_origin = "/virtual/private-245-tla.js";
    module_exception = .empty;
    const pending_module = JSC__JSModuleLoader__evaluate(
        context,
        module_tla_source.ptr,
        module_tla_source.len,
        module_tla_origin.ptr,
        module_tla_origin.len,
        null,
        0,
        .undefined,
        &module_exception,
    );
    if (pending_module == .empty or module_exception != .empty or JSC__JSValue__asPromise(pending_module) == null)
        fail("private top-level-await module did not return a pending Promise");
    exposeCell(context, "__private_module_tla_promise_245", pending_module);
    _ = JSC__VM__runGC(JSC__JSGlobalObject__vm(context), true);
    _ = JSC__JSGlobalObject__drainMicrotasks(context);
    _ = evaluate(context, "globalThis.__private_module_tla_value_245 = 0; __private_module_tla_promise_245.then(ns => { __private_module_tla_value_245 = ns.awaited; });");
    if (Bun__JSValue__toNumber(evaluate(context, "__private_module_tla_value_245"), context) != 246)
        fail("private top-level-await module settlement/rooting mismatch");

    const invalid_module_source = "export const = ;";
    const invalid_module_origin = "/virtual/private-245-invalid.js";
    module_exception = .empty;
    if (JSC__JSModuleLoader__evaluate(
        context,
        invalid_module_source.ptr,
        invalid_module_source.len,
        invalid_module_origin.ptr,
        invalid_module_origin.len,
        null,
        0,
        .undefined,
        &module_exception,
    ) != .undefined or module_exception == .empty or !JSC__JSValue__isAnyError(module_exception))
        fail("private module parse rejection/out-parameter mismatch");
    module_exception = .empty;
    if (JSC__JSModuleLoader__evaluate(context, null, 1, null, 0, null, 0, .undefined, &module_exception) != .undefined or
        module_exception == .empty or !JSC__JSValue__isAnyError(module_exception))
        fail("private module invalid-span safety mismatch");

    const foreign_module_cell = JSModuleLoader__import(foreign_context, &module_entry_name) orelse
        fail("private foreign module import did not return a rejection Promise");
    expectPromise(foreign_context, EncodedValue.fromBits(@intFromPtr(foreign_module_cell)), .rejected, null);
    if (JSC__JSModuleLoader__loadAndEvaluateModule(context, null) != null or !JSGlobalObject__hasException(context))
        fail("private module loader accepted a null BunString");
    JSGlobalObject__clearException(context);

    _ = evaluate(context, "globalThis.__private_lifecycle_242 = []; process.on('beforeExit', code => __private_lifecycle_242.push('before:' + code)); process.on('exit', code => __private_lifecycle_242.push('exit:' + code));");
    Process__dispatchOnBeforeExit(context, 2);
    Process__dispatchOnExit(context, 4);
    Process__dispatchOnExit(context, 5);
    if (!JSC__JSValue__toBoolean(evaluate(context, "__private_lifecycle_242.join(',') === 'before:2,exit:4' && process._exiting === true")))
        fail("private process lifecycle dispatch mismatch");
    var iterable_state = IterableFixtureState{ .vm = JSC__JSGlobalObject__vm(context), .global = context };
    JSC__JSValue__forEach(evaluate(context, "[237, 'iterable']"), context, &iterable_state, iterableFixtureCallback);
    if (iterable_state.calls != 2 or iterable_state.values[0] != EncodedValue.fromInt32(237) or
        !JSC__JSValue__isStrictEqual(iterable_state.values[1], evaluate(context, "'iterable'"), context))
        fail("private iterable callback traversal mismatch");
    const json_bytes = "{\"issue\":238}";
    const json_input = ZigString{ .tagged_ptr = @intFromPtr(json_bytes.ptr), .len = json_bytes.len };
    const parsed_json = ZigString__toJSONObject(&json_input, context);
    if (Bun__JSValue__toNumber(getProperty(context, parsed_json, "issue"), context) != 238)
        fail("private ZigString JSON parsing mismatch");
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

    const enoent_bytes = "ENOENT";
    const enoent_message_bytes = "no such file or directory";
    const open_bytes = "open";
    const nope_path_bytes = "/tmp/nope";
    const dest_path_bytes = "/tmp/else";
    const full_system_error = SystemError{
        .errno = -2,
        .code = .{ .tag = .zig_string, .value = .{ .zig_string = .{ .tagged_ptr = @intFromPtr(enoent_bytes.ptr), .len = enoent_bytes.len } } },
        .message = .{ .tag = .zig_string, .value = .{ .zig_string = .{ .tagged_ptr = @intFromPtr(enoent_message_bytes.ptr), .len = enoent_message_bytes.len } } },
        .path = .{ .tag = .zig_string, .value = .{ .zig_string = .{ .tagged_ptr = @intFromPtr(nope_path_bytes.ptr), .len = nope_path_bytes.len } } },
        .syscall = .{ .tag = .zig_string, .value = .{ .zig_string = .{ .tagged_ptr = @intFromPtr(open_bytes.ptr), .len = open_bytes.len } } },
        .fd = 9,
        .dest = .{ .tag = .zig_string, .value = .{ .zig_string = .{ .tagged_ptr = @intFromPtr(dest_path_bytes.ptr), .len = dest_path_bytes.len } } },
    };
    const full_system_error_instance = SystemError__toErrorInstance(&full_system_error, context);
    if (full_system_error_instance == .empty or !JSC__JSValue__isAnyError(full_system_error_instance))
        fail("SystemError error-instance construction failed");
    exposeCell(context, "__private_system_error", full_system_error_instance);
    if (!JSC__JSValue__toBoolean(evaluate(context, "__private_system_error instanceof Error && Object.getPrototypeOf(__private_system_error) === Error.prototype && __private_system_error.name === 'Error' && __private_system_error.message === 'no such file or directory' && __private_system_error.code === 'ENOENT' && __private_system_error.path === '/tmp/nope' && __private_system_error.dest === '/tmp/else' && __private_system_error.syscall === 'open' && __private_system_error.fd === 9 && __private_system_error.errno === -2 && !Object.hasOwn(__private_system_error, 'hostname')")) or
        !JSC__JSValue__toBoolean(evaluate(context, "Object.keys(__private_system_error).join(',') === 'code,path,dest,fd,syscall,errno'")))
        fail("SystemError error-instance field/order mismatch");
    if (!JSC__JSValue__toBoolean(evaluate(context,
        \\(() => {
        \\  const code = Object.getOwnPropertyDescriptor(__private_system_error, 'code');
        \\  const fd = Object.getOwnPropertyDescriptor(__private_system_error, 'fd');
        \\  const errno = Object.getOwnPropertyDescriptor(__private_system_error, 'errno');
        \\  const message = Object.getOwnPropertyDescriptor(__private_system_error, 'message');
        \\  return code.writable && code.enumerable && !code.configurable &&
        \\    fd.writable && fd.enumerable && !fd.configurable &&
        \\    errno.writable && errno.enumerable && !errno.configurable &&
        \\    message.writable && !message.enumerable && message.configurable;
        \\})()
    ))) fail("SystemError error-instance descriptor mismatch");

    const minimal_system_error = SystemError{ .message = latin1_string };
    const minimal_system_error_instance = SystemError__toErrorInstance(&minimal_system_error, context);
    exposeCell(context, "__private_minimal_system_error", minimal_system_error_instance);
    if (minimal_system_error_instance == .empty or
        !JSC__JSValue__toBoolean(evaluate(context, "__private_minimal_system_error.message === 'café' && __private_minimal_system_error.errno === 0 && Object.keys(__private_minimal_system_error).join(',') === 'errno'")))
        fail("SystemError minimal error-instance mismatch");

    const empty_message_system_error = SystemError{ .errno = 34, .message = emptyBunString(), .fd = 0 };
    const empty_message_system_error_instance = SystemError__toErrorInstance(&empty_message_system_error, context);
    exposeCell(context, "__private_empty_message_system_error", empty_message_system_error_instance);
    if (empty_message_system_error_instance == .empty or
        !JSC__JSValue__toBoolean(evaluate(context, "__private_empty_message_system_error.message === '' && Object.hasOwn(__private_empty_message_system_error, 'message') && __private_empty_message_system_error.fd === 0 && __private_empty_message_system_error.errno === 34 && Object.keys(__private_empty_message_system_error).join(',') === 'fd,errno'")))
        fail("SystemError empty-message error-instance mismatch");

    const eio_bytes = "EIO";
    const read_bytes = "read";
    const info_system_error = SystemError{
        .errno = -5,
        .code = .{ .tag = .zig_string, .value = .{ .zig_string = .{ .tagged_ptr = @intFromPtr(eio_bytes.ptr), .len = eio_bytes.len } } },
        .message = utf16_string,
        .syscall = .{ .tag = .zig_string, .value = .{ .zig_string = .{ .tagged_ptr = @intFromPtr(read_bytes.ptr), .len = read_bytes.len } } },
    };
    const info_system_error_instance = SystemError__toErrorInstanceWithInfoObject(&info_system_error, context);
    if (info_system_error_instance == .empty or !JSC__JSValue__isAnyError(info_system_error_instance))
        fail("SystemError info-object error construction failed");
    exposeCell(context, "__private_info_system_error", info_system_error_instance);
    if (!JSC__JSValue__toBoolean(evaluate(context, "__private_info_system_error instanceof Error && __private_info_system_error.name === 'SystemError' && __private_info_system_error.code === 'ERR_SYSTEM_ERROR' && __private_info_system_error.message === 'A system error occurred: read returned EIO (A😀\\uD800Z)' && __private_info_system_error.syscall === 'read' && __private_info_system_error.errno === -5")) or
        !JSC__JSValue__toBoolean(evaluate(context, "Object.getPrototypeOf(__private_info_system_error.info) === Object.prototype && __private_info_system_error.info.code === 'EIO' && __private_info_system_error.info.syscall === 'read' && __private_info_system_error.info.message === 'A😀\\uD800Z' && __private_info_system_error.info.errno === -5")) or
        !JSC__JSValue__toBoolean(evaluate(context, "Object.keys(__private_info_system_error).join(',') === 'info,syscall,errno' && Object.keys(__private_info_system_error.info).join(',') === 'code,syscall,message,errno'")))
        fail("SystemError info-object field/order mismatch");
    if (!JSC__JSValue__toBoolean(evaluate(context,
        \\(() => {
        \\  const name = Object.getOwnPropertyDescriptor(__private_info_system_error, 'name');
        \\  const code = Object.getOwnPropertyDescriptor(__private_info_system_error, 'code');
        \\  const info = Object.getOwnPropertyDescriptor(__private_info_system_error, 'info');
        \\  const errno = Object.getOwnPropertyDescriptor(__private_info_system_error, 'errno');
        \\  const infoCode = Object.getOwnPropertyDescriptor(__private_info_system_error.info, 'code');
        \\  return name.writable && !name.enumerable && name.configurable &&
        \\    code.writable && !code.enumerable && code.configurable &&
        \\    info.writable && info.enumerable && !info.configurable &&
        \\    errno.writable && errno.enumerable && !errno.configurable &&
        \\    infoCode.writable && infoCode.enumerable && !infoCode.configurable;
        \\})()
    ))) fail("SystemError info-object descriptor mismatch");

    const sparse_info_system_error = SystemError{ .errno = 2, .message = latin1_string };
    const sparse_info_system_error_instance = SystemError__toErrorInstanceWithInfoObject(&sparse_info_system_error, context);
    exposeCell(context, "__private_sparse_info_system_error", sparse_info_system_error_instance);
    if (sparse_info_system_error_instance == .empty or
        !JSC__JSValue__toBoolean(evaluate(context, "__private_sparse_info_system_error.message === 'A system error occurred:  returned  (café)' && __private_sparse_info_system_error.syscall === '' && __private_sparse_info_system_error.info.code === '' && __private_sparse_info_system_error.info.syscall === '' && __private_sparse_info_system_error.info.message === 'café' && __private_sparse_info_system_error.info.errno === 2")))
        fail("SystemError sparse info-object mismatch");

    if (SystemError__toErrorInstance(null, context) != .empty or
        SystemError__toErrorInstanceWithInfoObject(null, context) != .empty or
        JSGlobalObject__hasException(context))
        fail("SystemError bridges accepted a null struct");
    JSC__VM__throwError(JSC__JSGlobalObject__vm(context), context, EncodedValue.fromInt32(199));
    if (SystemError__toErrorInstance(&full_system_error, context) != .empty or
        SystemError__toErrorInstanceWithInfoObject(&full_system_error, context) != .empty)
        fail("SystemError bridges ignored pending exception");
    const preserved_system_error_exception = JSGlobalObject__tryTakeException(context);
    if (JSC__Exception__asJSValue(preserved_system_error_exception.cellPointer()) != EncodedValue.fromInt32(199))
        fail("SystemError bridges replaced pending exception");

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

    var external_latin1 = [_]u8{ 'e', 'x', 't', 0xe9 };
    const external_latin1_string = ZigString{ .tagged_ptr = @intFromPtr(&external_latin1), .len = external_latin1.len };
    var external_probe = ExternalStringProbe{
        .expected_pointer = @ptrCast(&external_latin1),
        .expected_len = external_latin1.len,
    };
    const external_latin1_value = ZigString__external(&external_latin1_string, context, &external_probe, ExternalStringProbe.release);
    if (!JSC__JSValue__isStrictEqual(external_latin1_value, evaluate(context, "'exté'"), context))
        fail("external ZigString Latin-1 construction mismatch");
    exposeCell(context, "__private_external_latin1", external_latin1_value);

    var external_utf16 = [_]u16{ 'E', 0xd83d, 0xde00, 0xd800 };
    const external_utf16_string = ZigString{
        .tagged_ptr = @intFromPtr(&external_utf16) | (@as(usize, 1) << 63),
        .len = external_utf16.len,
    };
    const external_utf16_value = ZigString__toExternalValueWithCallback(&external_utf16_string, context, ExternalStringProbe.releaseNull);
    if (!JSC__JSValue__isStrictEqual(external_utf16_value, evaluate(context, "'E😀\\uD800'"), context))
        fail("external ZigString UTF-16 construction mismatch");
    exposeCell(context, "__private_external_utf16", external_utf16_value);

    const transferred_raw = std.c.malloc(3 * @sizeOf(u16)) orelse fail("external U16 allocation failed");
    const transferred_u16: [*]u16 = @ptrCast(@alignCast(transferred_raw));
    @memcpy(transferred_u16[0..3], &[_]u16{ 'U', 0xd83d, 0xde00 });
    const external_u16_value = ZigString__toExternalU16(transferred_u16, 3, context);
    if (!JSC__JSValue__isStrictEqual(external_u16_value, evaluate(context, "'U😀'"), context))
        fail("external transferred U16 construction mismatch");
    exposeCell(context, "__private_external_u16", external_u16_value);

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

    // `JSC__JSObject__create` (#306): empty realm object plus exactly one
    // synchronous consumer initializer receiving the pass-through ctx, the
    // stable cell pointer the returned value exposes, and the same global.
    var create_sentinel: usize = 0xC0FFEE;
    object_create_state = .{};
    const marshalled_object = JSC__JSObject__create(context, 8, &create_sentinel, objectCreateInitializer);
    if (marshalled_object == .empty or object_create_state.calls != 1 or
        object_create_state.ctx != @as(?*anyopaque, @ptrCast(&create_sentinel)) or
        object_create_state.global != @as(?*anyopaque, @ptrCast(context)) or
        object_create_state.obj == null or
        object_create_state.obj != EncodedValue.cellPointer(marshalled_object))
        fail("private JSObject create initializer mismatch");
    const marshalled_prototype = JSObjectGetPrototype(context, EncodedValue.cellPointer(marshalled_object)) orelse fail("marshalled object prototype lookup failed");
    if (!JSC__JSValue__isStrictEqual(EncodedValue.fromRef(marshalled_prototype), object_prototype, context))
        fail("private JSObject create prototype mismatch");
    // Capacity beyond JSC's maxInlineCapacity clamp is observably identical,
    // a null initializer still creates a distinct object, and a null VM
    // returns empty without invoking the callback.
    const over_reserved_object = JSC__JSObject__create(context, 1 << 20, null, null);
    if (over_reserved_object == .empty or
        JSC__JSValue__isStrictEqual(over_reserved_object, marshalled_object, context))
        fail("private JSObject create capacity/null-initializer mismatch");
    if (JSC__JSObject__create(null, 0, null, objectCreateInitializer) != .empty or object_create_state.calls != 1)
        fail("private JSObject create null-VM tolerance mismatch");

    // URLSearchParams boundary (#307): create decodes a ZigString query into
    // a realm `instanceof URLSearchParams` object through the same parse the
    // JS constructor uses (one leading `?` stripped, `+`/percent codec), and
    // toString serializes through the JS method path into a borrowed
    // ZigString view delivered exactly once.
    const usp_query_bytes = "?a=1&b=two+words&b=3&c=%41%2C";
    const usp_query = ZigString{ .tagged_ptr = @intFromPtr(usp_query_bytes.ptr), .len = usp_query_bytes.len };
    const usp_object = URLSearchParams__create(context, &usp_query);
    if (usp_object == .empty or URLSearchParams__fromJS(usp_object) == null)
        fail("private URLSearchParams create/fromJS mismatch");
    exposeCell(context, "__private_usp", usp_object);
    if (!JSC__JSValue__toBoolean(evaluate(context, "__private_usp instanceof URLSearchParams")) or
        !JSC__JSValue__toBoolean(evaluate(context, "__private_usp.get('b') === 'two words'")) or
        !JSC__JSValue__toBoolean(evaluate(context, "__private_usp.getAll('b').length === 2")))
        fail("private URLSearchParams engine integration mismatch");
    usp_to_string_state = .{};
    URLSearchParams__toString(URLSearchParams__fromJS(usp_object), &usp_to_string_state, uspToStringCallback);
    if (usp_to_string_state.calls != 1 or usp_to_string_state.utf16 or
        !std.mem.eql(u8, usp_to_string_state.bytes[0..usp_to_string_state.len], "a=1&b=two+words&b=3&c=A%2C"))
        fail("private URLSearchParams serialization mismatch");
    const js_usp = evaluate(context, "new URLSearchParams('x=9&x=10')");
    if (URLSearchParams__fromJS(js_usp) == null or
        URLSearchParams__fromJS(empty_object) != null or
        URLSearchParams__fromJS(encoded_text) != null or
        URLSearchParams__fromJS(EncodedValue.fromInt32(7)) != null or
        URLSearchParams__fromJS(.undefined) != null or
        URLSearchParams__fromJS(.empty) != null)
        fail("private URLSearchParams fromJS discrimination mismatch");
    usp_to_string_state = .{};
    URLSearchParams__toString(URLSearchParams__fromJS(js_usp), &usp_to_string_state, uspToStringCallback);
    if (usp_to_string_state.calls != 1 or
        !std.mem.eql(u8, usp_to_string_state.bytes[0..usp_to_string_state.len], "x=9&x=10"))
        fail("private URLSearchParams JS-instance serialization mismatch");
    const usp_empty_bytes = "";
    const usp_empty_query = ZigString{ .tagged_ptr = @intFromPtr(usp_empty_bytes.ptr), .len = 0 };
    const usp_empty = URLSearchParams__create(context, &usp_empty_query);
    usp_to_string_state = .{};
    URLSearchParams__toString(URLSearchParams__fromJS(usp_empty), &usp_to_string_state, uspToStringCallback);
    if (usp_empty == .empty or usp_to_string_state.calls != 1 or usp_to_string_state.len != 0)
        fail("private URLSearchParams empty-input mismatch");
    // The owner realm is recovered from the handle: a foreign-realm instance
    // serializes through its own context without the caller naming one.
    const foreign_usp_object = URLSearchParams__create(foreign_context, &usp_query);
    usp_to_string_state = .{};
    URLSearchParams__toString(URLSearchParams__fromJS(foreign_usp_object), &usp_to_string_state, uspToStringCallback);
    if (URLSearchParams__fromJS(foreign_usp_object) == null or usp_to_string_state.calls != 1 or
        !std.mem.eql(u8, usp_to_string_state.bytes[0..usp_to_string_state.len], "a=1&b=two+words&b=3&c=A%2C"))
        fail("private URLSearchParams foreign-realm mismatch");
    URLSearchParams__toString(null, &usp_to_string_state, uspToStringCallback);
    URLSearchParams__toString(URLSearchParams__fromJS(usp_object), null, null);
    if (URLSearchParams__create(null, &usp_query) != .empty or usp_to_string_state.calls != 1)
        fail("private URLSearchParams null tolerance mismatch");

    // DOMFormData boundary (#374): one branded JS entry list backs native and
    // JS-created instances. URL-query parsing uses the URL Standard codec,
    // string and filename inputs are USVStrings, Blob entries remain Files,
    // and opaque native BlobImpl pointers round-trip without dereference.
    const fd_empty = WebCore__DOMFormData__create(context);
    const fd_vm = JSC__JSGlobalObject__vm(context);
    const fd_empty_handle = WebCore__DOMFormData__fromJS(fd_empty) orelse fail("private DOMFormData create/fromJS mismatch");
    exposeCell(context, "__private_fd_empty", fd_empty);
    if (!JSC__JSValue__toBoolean(evaluate(context, "__private_fd_empty instanceof FormData")) or
        WebCore__DOMFormData__cast_(fd_empty, fd_vm) != fd_empty_handle or
        WebCore__DOMFormData__count(fd_empty_handle) != 0 or
        WebCore__DOMFormData__fromJS(evaluate(context, "Object.create(FormData.prototype)")) != null or
        WebCore__DOMFormData__fromJS(encoded_object) != null or
        WebCore__DOMFormData__fromJS(encoded_text) != null or
        WebCore__DOMFormData__fromJS(.undefined) != null or
        WebCore__DOMFormData__fromJS(.empty) != null or
        WebCore__DOMFormData__cast_(fd_empty, null) != null)
        fail("private DOMFormData branding/downcast mismatch");

    const foreign_fd = evaluate(foreign_context, "new FormData()");
    if (WebCore__DOMFormData__fromJS(foreign_fd) == null or
        WebCore__DOMFormData__cast_(foreign_fd, fd_vm) != null or
        WebCore__DOMFormData__cast_(foreign_fd, JSC__JSGlobalObject__vm(foreign_context)) == null)
        fail("private DOMFormData VM ownership mismatch");

    const fd_query_bytes = "?lead=x&a=1&b=two+words&bad=%E0%A4&empty=&=blank";
    const fd_query_input = ZigString{ .tagged_ptr = @intFromPtr(fd_query_bytes.ptr), .len = fd_query_bytes.len };
    const fd_query = WebCore__DOMFormData__createFromURLQuery(context, &fd_query_input);
    const fd_query_handle = WebCore__DOMFormData__fromJS(fd_query) orelse fail("private DOMFormData URL-query create mismatch");
    exposeCell(context, "__private_fd_query", fd_query);
    if (WebCore__DOMFormData__count(fd_query_handle) != 6 or
        !JSC__JSValue__toBoolean(evaluate(context, "__private_fd_query.get('?lead') === 'x' && __private_fd_query.get('b') === 'two words' && __private_fd_query.get('bad') === '�' && __private_fd_query.get('') === 'blank'")))
        fail("private DOMFormData URL-query parse mismatch");

    const fd_query_expected = "%3Flead=x&a=1&b=two+words&bad=%EF%BF%BD&empty=&=blank";
    usp_to_string_state = .{};
    DOMFormData__toQueryString(fd_query_handle, &usp_to_string_state, uspToStringCallback);
    if (usp_to_string_state.calls != 1 or usp_to_string_state.utf16 or
        !std.mem.eql(u8, usp_to_string_state.bytes[0..usp_to_string_state.len], fd_query_expected))
        fail("private DOMFormData query serialization mismatch");
    usp_to_string_state = .{};
    WebCore__DOMFormData__toQueryString(fd_query_handle, &usp_to_string_state, uspToStringCallback);
    if (usp_to_string_state.calls != 1 or
        !std.mem.eql(u8, usp_to_string_state.bytes[0..usp_to_string_state.len], fd_query_expected))
        fail("private DOMFormData query serialization alias mismatch");

    const fd_name_units = [_]u16{ 0xD800, 'n' };
    const fd_value_units = [_]u16{ 'v', 0xDC00 };
    const fd_filename_units = [_]u16{ 'f', 0xD800 };
    const fd_name = ZigString{ .tagged_ptr = @intFromPtr(&fd_name_units) | (@as(usize, 1) << 63), .len = fd_name_units.len };
    const fd_value = ZigString{ .tagged_ptr = @intFromPtr(&fd_value_units) | (@as(usize, 1) << 63), .len = fd_value_units.len };
    const fd_filename = ZigString{ .tagged_ptr = @intFromPtr(&fd_filename_units) | (@as(usize, 1) << 63), .len = fd_filename_units.len };
    WebCore__DOMFormData__append(fd_query_handle, &fd_name, &fd_value);
    var native_blob_sentinel: usize = 0xF04D_DA7A;
    const native_blob_pointer: *anyopaque = @ptrCast(&native_blob_sentinel);
    const native_blob_name_bytes = "native";
    const native_blob_name = ZigString{ .tagged_ptr = @intFromPtr(native_blob_name_bytes.ptr), .len = native_blob_name_bytes.len };
    WebCore__DOMFormData__appendBlob(fd_query_handle, context, &native_blob_name, native_blob_pointer, &fd_filename);
    if (WebCore__DOMFormData__count(fd_query_handle) != 8 or
        !JSC__JSValue__toBoolean(evaluate(context, "__private_fd_query.get('�n') === 'v�' && __private_fd_query.get('native') instanceof File && __private_fd_query.get('native').name === 'f�'")))
        fail("private DOMFormData append/Blob JS integration mismatch");

    _ = JSC__VM__runGC(fd_vm, true);
    var fd_each: DOMFormDataFixtureState = .{};
    DOMFormData__forEach(fd_query_handle, &fd_each, domFormDataForEachCallback);
    if (fd_each.calls != 8 or
        !zigStringUtf8Equals(fd_each.entries[0].name, "?lead") or
        !zigStringUtf8Equals(fd_each.entries[0].string, "x") or
        !zigStringUtf8Equals(fd_each.entries[6].name, "�n") or
        !zigStringUtf8Equals(fd_each.entries[6].string, "v�") or
        !fd_each.entries[7].is_blob or fd_each.entries[7].blob != native_blob_pointer or
        !zigStringUtf8Equals(fd_each.entries[7].name, "native") or
        !zigStringUtf8Equals(fd_each.entries[7].filename, "f�"))
        fail("private DOMFormData forEach entry projection mismatch");
    const fd_with_string_expected = fd_query_expected ++ "&%EF%BF%BDn=v%EF%BF%BD";
    usp_to_string_state = .{};
    DOMFormData__toQueryString(fd_query_handle, &usp_to_string_state, uspToStringCallback);
    if (usp_to_string_state.calls != 1 or
        !std.mem.eql(u8, usp_to_string_state.bytes[0..usp_to_string_state.len], fd_with_string_expected))
        fail("private DOMFormData Blob omission mismatch");

    const js_fd = evaluate(context,
        \\globalThis.__private_fd_file = new File(['file-body'], 'orig.txt', { type: 'text/plain', lastModified: 123 });
        \\globalThis.__private_fd_blob = new Blob(['blob-body'], { type: 'application/test' });
        \\globalThis.__private_fd_js = new FormData();
        \\__private_fd_js.append('file', __private_fd_file);
        \\__private_fd_js.append('blob', __private_fd_blob);
        \\__private_fd_js.append('named', __private_fd_blob, 'renamed\uD800');
        \\__private_fd_js;
    );
    const js_fd_handle = WebCore__DOMFormData__fromJS(js_fd) orelse fail("private DOMFormData rejected a JS-created instance");
    if (WebCore__DOMFormData__count(js_fd_handle) != 3 or
        !JSC__JSValue__toBoolean(evaluate(context,
            \\__private_fd_js.get('file') === __private_fd_file &&
            \\__private_fd_js.get('blob') !== __private_fd_blob &&
            \\__private_fd_js.get('blob') instanceof File &&
            \\__private_fd_js.get('blob').name === 'blob' &&
            \\__private_fd_js.get('blob').type === 'application/test' &&
            \\__private_fd_js.get('named') instanceof File &&
            \\__private_fd_js.get('named').name === 'renamed\uFFFD'
        )))
        fail("private DOMFormData JS Blob/File entry semantics mismatch");
    if (!JSC__JSValue__toBoolean(evaluate(context,
        \\(() => {
        \\  for (const filename of ['filename', undefined]) {
        \\    try { new FormData().append('x', 'value', filename); return false; } catch (error) { if (!(error instanceof TypeError)) return false; }
        \\  }
        \\  return true;
        \\})()
    ))) fail("private DOMFormData overload discrimination mismatch");

    var js_fd_each: DOMFormDataFixtureState = .{};
    DOMFormData__forEach(js_fd_handle, &js_fd_each, domFormDataForEachCallback);
    if (js_fd_each.calls != 3 or
        !js_fd_each.entries[0].is_blob or !zigStringUtf8Equals(js_fd_each.entries[0].filename, "orig.txt") or
        !js_fd_each.entries[1].is_blob or !zigStringUtf8Equals(js_fd_each.entries[1].filename, "blob") or
        !js_fd_each.entries[2].is_blob or !zigStringUtf8Equals(js_fd_each.entries[2].filename, "renamed�") or
        js_fd_each.entries[1].blob == null)
        fail("private DOMFormData JS Blob callback projection mismatch");

    const fd_roundtrip = WebCore__DOMFormData__create(context);
    const fd_roundtrip_handle = WebCore__DOMFormData__fromJS(fd_roundtrip) orelse fail("private DOMFormData roundtrip create mismatch");
    const fd_copy_name_bytes = "copy";
    const fd_copy_filename_bytes = "copy.txt";
    const fd_copy_name = ZigString{ .tagged_ptr = @intFromPtr(fd_copy_name_bytes.ptr), .len = fd_copy_name_bytes.len };
    const fd_copy_filename = ZigString{ .tagged_ptr = @intFromPtr(fd_copy_filename_bytes.ptr), .len = fd_copy_filename_bytes.len };
    WebCore__DOMFormData__appendBlob(fd_roundtrip_handle, context, &fd_copy_name, js_fd_each.entries[1].blob.?, &fd_copy_filename);
    exposeCell(context, "__private_fd_roundtrip", fd_roundtrip);
    var fd_roundtrip_each: DOMFormDataFixtureState = .{};
    DOMFormData__forEach(fd_roundtrip_handle, &fd_roundtrip_each, domFormDataForEachCallback);
    if (fd_roundtrip_each.calls != 1 or fd_roundtrip_each.entries[0].blob != js_fd_each.entries[1].blob or
        !zigStringUtf8Equals(fd_roundtrip_each.entries[0].filename, "copy.txt") or
        !JSC__JSValue__toBoolean(evaluate(context, "__private_fd_roundtrip.get('copy') instanceof File && __private_fd_roundtrip.get('copy').name === 'copy.txt' && __private_fd_roundtrip.get('copy').size === 9 && __private_fd_roundtrip.get('copy').type === 'application/test'")))
        fail("private DOMFormData JS/native Blob identity roundtrip mismatch");

    usp_to_string_state = .{};
    DOMFormData__toQueryString(fd_roundtrip_handle, &usp_to_string_state, uspToStringCallback);
    if (usp_to_string_state.calls != 1 or usp_to_string_state.len != 0)
        fail("private DOMFormData Blob-only serialization mismatch");
    DOMFormData__forEach(null, &fd_roundtrip_each, domFormDataForEachCallback);
    DOMFormData__toQueryString(null, &usp_to_string_state, uspToStringCallback);
    WebCore__DOMFormData__append(null, &fd_copy_name, &fd_copy_filename);
    WebCore__DOMFormData__appendBlob(fd_empty_handle, foreign_context, &fd_copy_name, native_blob_pointer, &fd_copy_filename);
    if (WebCore__DOMFormData__create(null) != .empty or
        WebCore__DOMFormData__createFromURLQuery(null, &fd_query_input) != .empty or
        WebCore__DOMFormData__count(null) != 0 or
        WebCore__DOMFormData__count(fd_empty_handle) != 0 or
        fd_roundtrip_each.calls != 1 or usp_to_string_state.calls != 1)
        fail("private DOMFormData null/cross-VM tolerance mismatch");

    // URL native record boundary (#308): fromString parses through the
    // engine's WHATWG urlParse into an owned native record (no realm), and the
    // component getters match Bun/WTF semantics — host WITHOUT port, hostname
    // WITH port — with JS `new URL` parity wherever semantics overlap.
    const url_input_a = "https://user:pw@Example.COM:8443/p/../a%20b?q=1&x=#frag";
    var url_bunstring_a = BunString{ .tag = .zig_string, .value = .{ .zig_string = .{ .tagged_ptr = @intFromPtr(url_input_a.ptr), .len = url_input_a.len } } };
    const native_url_a = URL__fromString(&url_bunstring_a) orelse fail("private URL fromString rejected a valid URL");
    if (!expectNativeUrlField(context, URL__href(native_url_a), "new URL('https://user:pw@Example.COM:8443/p/../a%20b?q=1&x=#frag').href"))
        fail("private URL href JS parity mismatch");
    // WTF `url->protocol()` is the scheme WITHOUT the colon — native
    // semantics, deliberately not the JS `protocol` getter.
    if (!bunStringUtf8Equals(URL__protocol(native_url_a), "https"))
        fail("private URL protocol semantics mismatch");
    if (!expectNativeUrlField(context, URL__username(native_url_a), "new URL('https://user:pw@Example.COM:8443/p/../a%20b?q=1&x=#frag').username"))
        fail("private URL username JS parity mismatch");
    if (!expectNativeUrlField(context, URL__password(native_url_a), "new URL('https://user:pw@Example.COM:8443/p/../a%20b?q=1&x=#frag').password"))
        fail("private URL password JS parity mismatch");
    if (!expectNativeUrlField(context, URL__pathname(native_url_a), "new URL('https://user:pw@Example.COM:8443/p/../a%20b?q=1&x=#frag').pathname"))
        fail("private URL pathname JS parity mismatch");
    if (!expectNativeUrlField(context, URL__search(native_url_a), "new URL('https://user:pw@Example.COM:8443/p/../a%20b?q=1&x=#frag').search"))
        fail("private URL search JS parity mismatch");
    if (!expectNativeUrlField(context, URL__hash(native_url_a), "new URL('https://user:pw@Example.COM:8443/p/../a%20b?q=1&x=#frag').hash"))
        fail("private URL hash JS parity mismatch");
    if (!bunStringUtf8Equals(URL__host(native_url_a), "example.com") or
        !bunStringUtf8Equals(URL__hostname(native_url_a), "example.com:8443") or
        URL__port(native_url_a) != 8443 or
        !bunStringUtf8Equals(URL__fragmentIdentifier(native_url_a), "frag"))
        fail("private URL native getter semantics mismatch");
    const native_url_a_href = URL__href(native_url_a);

    // Default-port elision: the port component vanishes and port/hostname
    // follow WTF, not the JS getters.
    const url_input_b = "http://example.com:80/";
    var url_bunstring_b = BunString{ .tag = .zig_string, .value = .{ .zig_string = .{ .tagged_ptr = @intFromPtr(url_input_b.ptr), .len = url_input_b.len } } };
    const native_url_b = URL__fromString(&url_bunstring_b) orelse fail("private URL fromString rejected a default-port URL");
    if (URL__port(native_url_b) != std.math.maxInt(u32) or
        !bunStringUtf8Equals(URL__hostname(native_url_b), "example.com") or
        !bunStringUtf8Equals(URL__host(native_url_b), "example.com") or
        !expectNativeUrlField(context, URL__href(native_url_b), "new URL('http://example.com:80/').href"))
        fail("private URL default-port mismatch");

    // Non-special opaque-path URL: no host, path is the opaque body.
    const url_input_c = "mailto:someone@example.com";
    var url_bunstring_c = BunString{ .tag = .zig_string, .value = .{ .zig_string = .{ .tagged_ptr = @intFromPtr(url_input_c.ptr), .len = url_input_c.len } } };
    const native_url_c = URL__fromString(&url_bunstring_c) orelse fail("private URL fromString rejected an opaque-path URL");
    if (!bunStringUtf8Equals(URL__protocol(native_url_c), "mailto") or
        !bunStringUtf8Equals(URL__host(native_url_c), "") or
        !bunStringUtf8Equals(URL__hostname(native_url_c), "") or
        URL__port(native_url_c) != std.math.maxInt(u32) or
        !bunStringUtf8Equals(URL__search(native_url_c), "") or
        !bunStringUtf8Equals(URL__hash(native_url_c), "") or
        !expectNativeUrlField(context, URL__pathname(native_url_c), "new URL('mailto:someone@example.com').pathname") or
        !expectNativeUrlField(context, URL__href(native_url_c), "new URL('mailto:someone@example.com').href"))
        fail("private URL opaque-path mismatch");

    // Present-but-empty query keeps its `?` under WTF `url->query()` —
    // deliberately NOT the JS `search` getter, which the WHATWG DOM spec
    // maps to "" for an empty query. Absent and empty fragments both produce
    // an empty hash (WTF `fragmentIdentifier().isEmpty()` rule).
    const url_input_d = "http://x.com/?";
    var url_bunstring_d = BunString{ .tag = .zig_string, .value = .{ .zig_string = .{ .tagged_ptr = @intFromPtr(url_input_d.ptr), .len = url_input_d.len } } };
    const native_url_d = URL__fromString(&url_bunstring_d) orelse fail("private URL fromString rejected an empty-query URL");
    const url_input_e = "http://x.com/#";
    var url_bunstring_e = BunString{ .tag = .zig_string, .value = .{ .zig_string = .{ .tagged_ptr = @intFromPtr(url_input_e.ptr), .len = url_input_e.len } } };
    const native_url_e = URL__fromString(&url_bunstring_e) orelse fail("private URL fromString rejected an empty-fragment URL");
    if (!bunStringUtf8Equals(URL__search(native_url_d), "?") or
        !JSC__JSValue__toBoolean(evaluate(context, "new URL('http://x.com/?').search === ''")) or
        !bunStringUtf8Equals(URL__hash(native_url_d), "") or
        !bunStringUtf8Equals(URL__hash(native_url_e), "") or
        !bunStringUtf8Equals(URL__fragmentIdentifier(native_url_e), ""))
        fail("private URL empty-component mismatch");

    // UTF-16 BunString input decodes to the identical record.
    const url_units = [_]u16{ 'm', 'a', 'i', 'l', 't', 'o', ':', 'a', 'b' };
    var url_bunstring_u16 = BunString{ .tag = .zig_string, .value = .{ .zig_string = .{ .tagged_ptr = @intFromPtr(&url_units) | (@as(usize, 1) << 63), .len = url_units.len } } };
    const native_url_u16 = URL__fromString(&url_bunstring_u16) orelse fail("private URL fromString rejected a UTF-16 input");
    if (!bunStringUtf8Equals(URL__href(native_url_u16), "mailto:ab"))
        fail("private URL UTF-16 input mismatch");

    // Invalid and empty inputs return null; returned strings stay valid after
    // later parses; a second record is fully independent of the first.
    const url_invalid_1 = "not a url";
    var url_bunstring_bad = BunString{ .tag = .zig_string, .value = .{ .zig_string = .{ .tagged_ptr = @intFromPtr(url_invalid_1.ptr), .len = url_invalid_1.len } } };
    const url_invalid_2 = "http://[::1";
    var url_bunstring_bad2 = BunString{ .tag = .zig_string, .value = .{ .zig_string = .{ .tagged_ptr = @intFromPtr(url_invalid_2.ptr), .len = url_invalid_2.len } } };
    const url_invalid_3 = "";
    var url_bunstring_bad3 = BunString{ .tag = .zig_string, .value = .{ .zig_string = .{ .tagged_ptr = @intFromPtr(url_invalid_3.ptr), .len = 0 } } };
    if (URL__fromString(&url_bunstring_bad) != null or
        URL__fromString(&url_bunstring_bad2) != null or
        URL__fromString(&url_bunstring_bad3) != null or
        URL__fromString(null) != null)
        fail("private URL invalid-input mismatch");
    const native_url_a2 = URL__fromString(&url_bunstring_a) orelse fail("private URL second parse failed");
    if (native_url_a2 == native_url_a or
        !bunStringUtf8Equals(native_url_a_href, "https://user:pw@example.com:8443/a%20b?q=1&x=#frag") or
        !bunStringUtf8Equals(URL__href(native_url_a2), "https://user:pw@example.com:8443/a%20b?q=1&x=#frag"))
        fail("private URL record independence mismatch");

    // Null tolerance: Bun dereferences unconditionally (UB), zig-js returns
    // safe sentinels instead; deinit frees the record, null is a no-op.
    if (URL__href(null).tag != .dead or URL__protocol(null).tag != .dead or
        URL__username(null).tag != .dead or URL__password(null).tag != .dead or
        URL__search(null).tag != .dead or URL__host(null).tag != .dead or
        URL__hostname(null).tag != .dead or URL__pathname(null).tag != .dead or
        URL__hash(null).tag != .dead or URL__fragmentIdentifier(null).tag != .dead or
        URL__port(null) != std.math.maxInt(u32))
        fail("private URL null tolerance mismatch");
    URL__deinit(native_url_a);
    URL__deinit(native_url_b);
    URL__deinit(native_url_c);
    URL__deinit(native_url_d);
    URL__deinit(native_url_e);
    URL__deinit(native_url_u16);
    URL__deinit(native_url_a2);
    URL__deinit(null);

    // URL JS-value and static string helpers (#309): fromJS/getHrefFromJS
    // coerce through ToString with published-exception semantics; the static
    // helpers are context-free BunString in/out shims over the same parser.
    const url_js_input = evaluate(context, "'https://a:b@Example.COM:1/p?q#f'");
    const native_url_js = URL__fromJS(url_js_input, context) orelse fail("private URL fromJS rejected a valid string");
    if (!expectNativeUrlField(context, URL__href(native_url_js), "new URL('https://a:b@Example.COM:1/p?q#f').href") or
        !expectNativeUrlField(context, URL__getHrefFromJS(url_js_input, context), "new URL('https://a:b@Example.COM:1/p?q#f').href"))
        fail("private URL fromJS/getHrefFromJS parity mismatch");

    // ToString coercion: an object with toString coerces; a throwing toString
    // publishes the exception and yields null/Dead.
    const url_coercible = evaluate(context, "({toString(){return 'http://h.com/x?q=1'}})");
    const native_url_coerced = URL__fromJS(url_coercible, context) orelse fail("private URL fromJS rejected a coercible object");
    if (!bunStringUtf8Equals(URL__href(native_url_coerced), "http://h.com/x?q=1") or
        !bunStringUtf8Equals(URL__getHrefFromJS(url_coercible, context), "http://h.com/x?q=1"))
        fail("private URL toString coercion mismatch");
    const url_throwing = evaluate(context, "({toString(){throw new Error('boom')}})");
    if (URL__fromJS(url_throwing, context) != null or !JSGlobalObject__hasException(context))
        fail("private URL fromJS did not publish a throwing coercion");
    JSGlobalObject__clearException(context);
    if (URL__getHrefFromJS(url_throwing, context).tag != .dead or !JSGlobalObject__hasException(context))
        fail("private URL getHrefFromJS did not publish a throwing coercion");
    JSGlobalObject__clearException(context);

    // Empty/invalid inputs coerce to null/Dead WITHOUT an exception;
    // foreign-VM values publish a TypeError and yield null/Dead.
    if (URL__fromJS(evaluate(context, "''"), context) != null or
        URL__getHrefFromJS(evaluate(context, "''"), context).tag != .dead or
        URL__fromJS(encoded_text, context) != null or // 'value' is not a URL
        JSGlobalObject__hasException(context))
        fail("private URL empty/invalid JS input mismatch");
    const foreign_url_string = evaluate(foreign_context, "'http://h.com/x'");
    if (URL__fromJS(foreign_url_string, context) != null or !JSGlobalObject__hasException(context))
        fail("private URL fromJS accepted a foreign value");
    JSGlobalObject__clearException(context);
    if (URL__getHrefFromJS(foreign_url_string, context).tag != .dead or !JSGlobalObject__hasException(context))
        fail("private URL getHrefFromJS accepted a foreign value");
    JSGlobalObject__clearException(context);

    // getHref (context-free): full re-serialization, Dead for invalid input.
    if (!expectNativeUrlField(context, URL__getHref(&url_bunstring_a), "new URL('https://user:pw@Example.COM:8443/p/../a%20b?q=1&x=#frag').href"))
        fail("private URL getHref mismatch");
    if (URL__getHref(&url_bunstring_bad).tag != .dead or
        URL__getHref(&url_bunstring_bad3).tag != .dead or
        URL__getHref(null).tag != .dead)
        fail("private URL getHref invalid-input mismatch");

    // getHrefJoin: WHATWG base resolution with JS `new URL(rel, base)` parity
    // across relative, absolute-path, dot-segment, and file-base references.
    const join_base_http = "http://h.com/a/b";
    var join_base_http_bs = BunString{ .tag = .zig_string, .value = .{ .zig_string = .{ .tagged_ptr = @intFromPtr(join_base_http.ptr), .len = join_base_http.len } } };
    const join_base_slash = "http://h.com/a/b/";
    var join_base_slash_bs = BunString{ .tag = .zig_string, .value = .{ .zig_string = .{ .tagged_ptr = @intFromPtr(join_base_slash.ptr), .len = join_base_slash.len } } };
    const join_base_file = "file:///tmp/a/";
    var join_base_file_bs = BunString{ .tag = .zig_string, .value = .{ .zig_string = .{ .tagged_ptr = @intFromPtr(join_base_file.ptr), .len = join_base_file.len } } };
    const join_rel_child = "c/d";
    var join_rel_child_bs = BunString{ .tag = .zig_string, .value = .{ .zig_string = .{ .tagged_ptr = @intFromPtr(join_rel_child.ptr), .len = join_rel_child.len } } };
    const join_rel_root = "/x";
    var join_rel_root_bs = BunString{ .tag = .zig_string, .value = .{ .zig_string = .{ .tagged_ptr = @intFromPtr(join_rel_root.ptr), .len = join_rel_root.len } } };
    const join_rel_dot = "../y";
    var join_rel_dot_bs = BunString{ .tag = .zig_string, .value = .{ .zig_string = .{ .tagged_ptr = @intFromPtr(join_rel_dot.ptr), .len = join_rel_dot.len } } };
    const join_rel_space = "b c.txt";
    var join_rel_space_bs = BunString{ .tag = .zig_string, .value = .{ .zig_string = .{ .tagged_ptr = @intFromPtr(join_rel_space.ptr), .len = join_rel_space.len } } };
    if (!expectNativeUrlField(context, URL__getHrefJoin(&join_base_http_bs, &join_rel_child_bs), "new URL('c/d', 'http://h.com/a/b').href") or
        !expectNativeUrlField(context, URL__getHrefJoin(&join_base_http_bs, &join_rel_root_bs), "new URL('/x', 'http://h.com/a/b').href") or
        !expectNativeUrlField(context, URL__getHrefJoin(&join_base_slash_bs, &join_rel_dot_bs), "new URL('../y', 'http://h.com/a/b/').href") or
        !expectNativeUrlField(context, URL__getHrefJoin(&join_base_file_bs, &join_rel_space_bs), "new URL('b c.txt', 'file:///tmp/a/').href"))
        fail("private URL getHrefJoin parity mismatch");
    const join_rel_bad = "http://[::1";
    var join_rel_bad_bs = BunString{ .tag = .zig_string, .value = .{ .zig_string = .{ .tagged_ptr = @intFromPtr(join_rel_bad.ptr), .len = join_rel_bad.len } } };
    if (URL__getHrefJoin(&url_bunstring_bad, &join_rel_child_bs).tag != .dead or
        URL__getHrefJoin(&join_base_http_bs, &join_rel_bad_bs).tag != .dead or
        URL__getHrefJoin(null, &join_rel_child_bs).tag != .dead or
        URL__getHrefJoin(&join_base_http_bs, null).tag != .dead)
        fail("private URL getHrefJoin invalid-input mismatch");

    // getFileURLString: each `/`-separated segment percent-encoded with the
    // WHATWG path encode set — slashes preserved, dot segments NOT resolved
    // (WTF sets the path post-parse). Latin-1 and UTF-16 inputs decode first.
    const file_path_latin1 = "/tmp/a b/caf\xE9.txt";
    var file_path_latin1_bs = BunString{ .tag = .zig_string, .value = .{ .zig_string = .{ .tagged_ptr = @intFromPtr(file_path_latin1.ptr), .len = file_path_latin1.len } } };
    const file_path_dots = "/a/./b/../c";
    var file_path_dots_bs = BunString{ .tag = .zig_string, .value = .{ .zig_string = .{ .tagged_ptr = @intFromPtr(file_path_dots.ptr), .len = file_path_dots.len } } };
    const file_path_empty = "";
    var file_path_empty_bs = BunString{ .tag = .zig_string, .value = .{ .zig_string = .{ .tagged_ptr = @intFromPtr(file_path_empty.ptr), .len = 0 } } };
    const file_path_units = [_]u16{ '/', 't', 'm', 'p', '/', 0x20AC, ' ', 'x' };
    var file_path_u16_bs = BunString{ .tag = .zig_string, .value = .{ .zig_string = .{ .tagged_ptr = @intFromPtr(&file_path_units) | (@as(usize, 1) << 63), .len = file_path_units.len } } };
    if (!bunStringUtf8Equals(URL__getFileURLString(&file_path_latin1_bs), "file:///tmp/a%20b/caf%C3%A9.txt") or
        !bunStringUtf8Equals(URL__getFileURLString(&file_path_dots_bs), "file:///a/./b/../c") or
        !bunStringUtf8Equals(URL__getFileURLString(&file_path_empty_bs), "file://") or
        !bunStringUtf8Equals(URL__getFileURLString(&file_path_u16_bs), "file:///tmp/%E2%82%AC%20x") or
        URL__getFileURLString(null).tag != .dead)
        fail("private URL getFileURLString mismatch");

    // pathFromFileURL: percent-decoded path (`%XX` only — `+` stays literal);
    // no scheme check, Dead for invalid input.
    const file_url_encoded = "file:///tmp/a%20b/x+y";
    var file_url_encoded_bs = BunString{ .tag = .zig_string, .value = .{ .zig_string = .{ .tagged_ptr = @intFromPtr(file_url_encoded.ptr), .len = file_url_encoded.len } } };
    const file_url_utf8 = "file:///caf%C3%A9";
    var file_url_utf8_bs = BunString{ .tag = .zig_string, .value = .{ .zig_string = .{ .tagged_ptr = @intFromPtr(file_url_utf8.ptr), .len = file_url_utf8.len } } };
    const http_url_encoded = "http://h.com/a%20b";
    var http_url_encoded_bs = BunString{ .tag = .zig_string, .value = .{ .zig_string = .{ .tagged_ptr = @intFromPtr(http_url_encoded.ptr), .len = http_url_encoded.len } } };
    if (!bunStringUtf8Equals(URL__pathFromFileURL(&file_url_encoded_bs), "/tmp/a b/x+y") or
        !bunStringUtf8Equals(URL__pathFromFileURL(&file_url_utf8_bs), "/caf\xC3\xA9") or
        !bunStringUtf8Equals(URL__pathFromFileURL(&http_url_encoded_bs), "/a b") or
        URL__pathFromFileURL(&url_bunstring_bad).tag != .dead or
        URL__pathFromFileURL(null).tag != .dead)
        fail("private URL pathFromFileURL mismatch");
    URL__deinit(native_url_js);
    URL__deinit(native_url_coerced);

    // URL__originLength (#312): byte offset where the path begins in the
    // canonical serialization — the origin length for tuple-origin URLs.
    const origin_userinfo = "http://user:pw@example.com:8080/p?q";
    const origin_default_port = "http://example.com:80/";
    const origin_file = "file:///tmp/x";
    const origin_opaque = "mailto:a@b.com";
    if (URL__originLength(origin_userinfo.ptr, origin_userinfo.len) != 31 or // "http://user:pw@example.com:8080"
        URL__originLength(origin_default_port.ptr, origin_default_port.len) != 18 or // default port elided
        URL__originLength(origin_file.ptr, origin_file.len) != 7 or // empty authority present
        URL__originLength(origin_opaque.ptr, origin_opaque.len) != 7) // scheme-only prefix
        fail("private URL originLength mismatch");
    // JS-derived parity: for URLs without query/fragment, pathStart equals
    // href.length - pathname.length — covers non-special hierarchical URLs
    // and the `/.`-sentinel case without hard-coding parser outcomes.
    const origin_sentinel = "foo:////p";
    exposeCell(context, "__ol", EncodedValue.fromInt32(@intCast(URL__originLength(origin_sentinel.ptr, origin_sentinel.len))));
    if (!JSC__JSValue__toBoolean(evaluate(context, "__ol === (()=>{const u=new URL('foo:////p'); return u.href.length - u.pathname.length})()")))
        fail("private URL originLength sentinel parity mismatch");
    const origin_nonspecial = "foo://host:9/p";
    exposeCell(context, "__ol", EncodedValue.fromInt32(@intCast(URL__originLength(origin_nonspecial.ptr, origin_nonspecial.len))));
    if (!JSC__JSValue__toBoolean(evaluate(context, "__ol === (()=>{const u=new URL('foo://host:9/p'); return u.href.length - u.pathname.length})()")))
        fail("private URL originLength non-special parity mismatch");
    // http(s) cross-check against the JS origin getter.
    const origin_https = "https://example.com:8443/a";
    exposeCell(context, "__ol", EncodedValue.fromInt32(@intCast(URL__originLength(origin_https.ptr, origin_https.len))));
    if (!JSC__JSValue__toBoolean(evaluate(context, "__ol === new URL('https://example.com:8443/a').origin.length")))
        fail("private URL originLength origin parity mismatch");
    // Invalid/empty/null input yields 0.
    const origin_bad = "not a url";
    if (URL__originLength(origin_bad.ptr, origin_bad.len) != 0 or
        URL__originLength(origin_bad.ptr, 0) != 0 or
        URL__originLength(null, 3) != 0)
        fail("private URL originLength invalid-input mismatch");

    // DOMURL object boundary (#313): toJSDOMURL/toURL create the realm's
    // URL-interface object (DOMURL::create semantics — invalid input throws),
    // cast_ is the VM-scoped downcast borrowing the live object, and the
    // getters read through that borrow.
    const domurl_input = "https://user:pw@Example.COM:8443/p/../a%20b?q=1&x=#frag";
    var domurl_bunstring = BunString{ .tag = .zig_string, .value = .{ .zig_string = .{ .tagged_ptr = @intFromPtr(domurl_input.ptr), .len = domurl_input.len } } };
    const domurl_value = BunString__toJSDOMURL(context, &domurl_bunstring);
    if (domurl_value == .empty) fail("private DOMURL toJSDOMURL rejected a valid URL");
    exposeCell(context, "__du", domurl_value);
    if (!JSC__JSValue__toBoolean(evaluate(context, "__du instanceof URL")) or
        !JSC__JSValue__toBoolean(evaluate(context, "__du.href === new URL('https://user:pw@Example.COM:8443/p/../a%20b?q=1&x=#frag').href")) or
        !JSC__JSValue__toBoolean(evaluate(context, "__du.searchParams.get('q') === '1'")))
        fail("private DOMURL object shape mismatch");
    const domurl_zig_input = "http://zig.example/path only";
    const domurl_zig_string = ZigString{ .tagged_ptr = @intFromPtr(domurl_zig_input.ptr), .len = domurl_zig_input.len };
    const domurl_value2 = BunString__toURL(&domurl_zig_string, context);
    if (domurl_value2 == .empty) fail("private DOMURL toURL rejected a valid URL");
    exposeCell(context, "__du2", domurl_value2);
    if (!JSC__JSValue__toBoolean(evaluate(context, "__du2 instanceof URL && __du2.href === new URL('http://zig.example/path only').href")))
        fail("private DOMURL toURL object mismatch");

    // Invalid input publishes the TypeError and returns an empty handle;
    // null input returns empty without an exception.
    const domurl_bad = "not a url";
    var domurl_bad_bs = BunString{ .tag = .zig_string, .value = .{ .zig_string = .{ .tagged_ptr = @intFromPtr(domurl_bad.ptr), .len = domurl_bad.len } } };
    const domurl_bad_zs = ZigString{ .tagged_ptr = @intFromPtr(domurl_bad.ptr), .len = domurl_bad.len };
    if (BunString__toJSDOMURL(context, &domurl_bad_bs) != .empty or !JSGlobalObject__hasException(context))
        fail("private DOMURL toJSDOMURL did not publish invalid input");
    JSGlobalObject__clearException(context);
    if (BunString__toURL(&domurl_bad_zs, context) != .empty or !JSGlobalObject__hasException(context))
        fail("private DOMURL toURL did not publish invalid input");
    JSGlobalObject__clearException(context);
    if (BunString__toJSDOMURL(context, null) != .empty or
        BunString__toURL(null, context) != .empty or
        JSGlobalObject__hasException(context))
        fail("private DOMURL null-input mismatch");

    // cast_: VM-scoped downcast accepting native-created AND JS-constructed
    // URL objects (any same-VM realm), rejecting everything else.
    const domurl_vm = JSC__JSGlobalObject__vm(context);
    const domurl_native = WebCore__DOMURL__cast_(domurl_value, domurl_vm) orelse fail("private DOMURL cast_ rejected its own object");
    const domurl_from_ctor = evaluate(context, "new URL('http://h.com/a b?q=1#f')");
    if (WebCore__DOMURL__cast_(domurl_from_ctor, domurl_vm) == null)
        fail("private DOMURL cast_ rejected a JS-constructed URL");
    if (WebCore__DOMURL__cast_(encoded_object, domurl_vm) != null or
        WebCore__DOMURL__cast_(encoded_text, domurl_vm) != null or
        WebCore__DOMURL__cast_(domurl_value, null) != null)
        fail("private DOMURL cast_ acceptance mismatch");
    const foreign_domurl = BunString__toJSDOMURL(foreign_context, &domurl_bunstring);
    if (foreign_domurl == .empty) fail("private DOMURL foreign-realm creation failed");
    if (WebCore__DOMURL__cast_(foreign_domurl, domurl_vm) != null)
        fail("private DOMURL cast_ accepted a foreign-VM value");
    if (WebCore__DOMURL__cast_(foreign_domurl, JSC__JSGlobalObject__vm(foreign_context)) == null)
        fail("private DOMURL cast_ rejected a same-VM foreign-realm object");

    // href_/pathname_ read through the borrow as interned borrowed views.
    var domurl_href_view = ZigString{ .tagged_ptr = 0, .len = 7 };
    WebCore__DOMURL__href_(domurl_native, &domurl_href_view);
    if (!zigStringUtf8Equals(domurl_href_view, "https://user:pw@example.com:8443/a%20b?q=1&x=#frag"))
        fail("private DOMURL href_ mismatch");
    var domurl_path_view = ZigString{ .tagged_ptr = 0, .len = 7 };
    WebCore__DOMURL__pathname_(domurl_native, &domurl_path_view);
    if (!zigStringUtf8Equals(domurl_path_view, "/a%20b"))
        fail("private DOMURL pathname_ mismatch");
    WebCore__DOMURL__href_(null, &domurl_href_view);
    WebCore__DOMURL__pathname_(null, &domurl_path_view);
    if (domurl_href_view.len != 0 or domurl_path_view.len != 0)
        fail("private DOMURL null getter mismatch");

    // fileSystemPath: decoded path for file: URLs; the three error codes.
    const domurl_file_input = "file:///tmp/a%20b/x+y";
    var domurl_file_bs = BunString{ .tag = .zig_string, .value = .{ .zig_string = .{ .tagged_ptr = @intFromPtr(domurl_file_input.ptr), .len = domurl_file_input.len } } };
    const domurl_file_value = BunString__toJSDOMURL(context, &domurl_file_bs);
    const domurl_file_native = WebCore__DOMURL__cast_(domurl_file_value, domurl_vm) orelse fail("private DOMURL cast_ rejected a file URL");
    var domurl_error_code: c_int = 0;
    if (!bunStringUtf8Equals(WebCore__DOMURL__fileSystemPath(domurl_file_native, &domurl_error_code), "/tmp/a b/x+y") or domurl_error_code != 0)
        fail("private DOMURL fileSystemPath mismatch");
    const domurl_host_url = evaluate(context, "new URL('file://host/x')");
    domurl_error_code = 0;
    if (WebCore__DOMURL__fileSystemPath(WebCore__DOMURL__cast_(domurl_host_url, domurl_vm), &domurl_error_code).tag != .dead or domurl_error_code != 1)
        fail("private DOMURL fileSystemPath host error mismatch");
    const domurl_2f_url = evaluate(context, "new URL('file:///a%2Fb')");
    domurl_error_code = 0;
    if (WebCore__DOMURL__fileSystemPath(WebCore__DOMURL__cast_(domurl_2f_url, domurl_vm), &domurl_error_code).tag != .dead or domurl_error_code != 2)
        fail("private DOMURL fileSystemPath %2f error mismatch");
    domurl_error_code = 0;
    if (WebCore__DOMURL__fileSystemPath(domurl_native, &domurl_error_code).tag != .dead or domurl_error_code != 3)
        fail("private DOMURL fileSystemPath non-file error mismatch");
    domurl_error_code = 0;
    if (WebCore__DOMURL__fileSystemPath(null, &domurl_error_code).tag != .dead or domurl_error_code != 2)
        fail("private DOMURL fileSystemPath null tolerance mismatch");

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
    runFetchHeadersFixture(context, vm);

    const common_string_kinds = [_]CommonStringsForZig{
        .IPv4,       .IPv6,         .IN4Loopback, .IN6Any,                .ipv4Lower,            .ipv6Lower,            .fetchDefault,
        .fetchError, .fetchInclude, .buffer,      .binaryTypeArrayBuffer, .binaryTypeNodeBuffer, .binaryTypeUint8Array,
    };
    const common_string_sources = [_][*:0]const u8{
        "'IPv4'",  "'IPv6'",    "'127.0.0.1'", "'::'",          "'ipv4'",       "'ipv6'",       "'default'",
        "'error'", "'include'", "'buffer'",    "'arraybuffer'", "'nodebuffer'", "'uint8array'",
    };
    for (common_string_kinds, common_string_sources) |kind, source| {
        const projected = Bun__CommonStringsForZig__toJS(kind, context);
        if (projected == .empty or
            projected != Bun__CommonStringsForZig__toJS(kind, sibling_context) or
            !JSC__JSValue__isStrictEqual(projected, evaluate(context, source), context) or
            projected == Bun__CommonStringsForZig__toJS(kind, foreign_context))
            fail("private CommonStrings VM identity/value mismatch");
    }
    const common_ipv4 = Bun__CommonStringsForZig__toJS(.IPv4, context);
    JSC__VM__throwError(vm, context, EncodedValue.fromInt32(378));
    const common_exception = JSGlobalObject__tryTakeException(context);
    if (Bun__CommonStringsForZig__toJS(.IPv4, context) != common_ipv4 or
        JSC__Exception__asJSValue(common_exception.cellPointer()) != EncodedValue.fromInt32(378) or
        Bun__CommonStringsForZig__toJS(@enumFromInt(13), context) != .empty or
        Bun__CommonStringsForZig__toJS(.IPv4, null) != .empty)
        fail("private CommonStrings invalid/pending-exception mismatch");
    const foreign_vm = JSC__JSGlobalObject__vm(foreign_context) orelse fail("foreign VM lookup failed");
    if (JSC__VM__isEntered(null) or JSC__VM__isEntered(vm) or JSC__VM__isEntered(sibling_vm) or JSC__VM__isEntered(foreign_vm))
        fail("private idle VM entry state mismatch");

    const sibling_bun_string_array = BunString__createArray(sibling_context, &bun_strings, bun_strings.len);
    exposeCell(sibling_context, "__private_sibling_bun_string_array", sibling_bun_string_array);
    if (!JSC__JSValue__isStrictEqual(BunString__toJS(sibling_context, &latin1_string), evaluate(sibling_context, "'café'"), sibling_context) or
        !JSC__JSValue__toBoolean(evaluate(sibling_context, "Object.getPrototypeOf(__private_sibling_bun_string_array) === Array.prototype")))
        fail("BunString selected-realm conversion mismatch");

    var host_name_bytes = [_]u8{ 'n', 'a', 't', 'i', 'v', 'e', 'A', 'd', 'd' };
    const host_name = BunString{
        .tag = .static_zig_string,
        .value = .{ .zig_string = .{ .tagged_ptr = @intFromPtr(&host_name_bytes), .len = host_name_bytes.len } },
    };
    const host_function = JSFunction__createFromZig(
        context,
        host_name,
        hostFunctionAdd,
        2,
        .private_recursive,
        .none,
        hostFunctionConstruct,
    );
    if (host_function == .empty or JSGlobalObject__hasException(context))
        fail("private JSFunction creation failed");
    host_name_bytes[0] = 'X';
    exposeCell(context, "__private_host_function_248", host_function);
    if (!JSC__JSValue__toBoolean(evaluate(context, "typeof __private_host_function_248 === 'function' && __private_host_function_248.name === 'nativeAdd' && __private_host_function_248.length === 2 && Object.getPrototypeOf(__private_host_function_248) === Function.prototype && Object.getOwnPropertyDescriptor(__private_host_function_248, 'name').configurable === true && Object.getOwnPropertyDescriptor(__private_host_function_248, 'length').writable === false")))
        fail("private JSFunction metadata/name ownership mismatch");

    const host_receiver = evaluate(context, "({ receiver: 248 })");
    exposeCell(context, "__private_host_receiver_248", host_receiver);
    host_function_fixture = .{
        .global = context,
        .callee = host_function,
        .this_value = host_receiver,
        .args = .{ EncodedValue.fromInt32(11), EncodedValue.fromInt32(22) },
        .introspection_global = context,
        .vm = vm,
    };
    defer {
        derefBunString(host_function_fixture.caller_source);
        host_function_fixture.caller_source = emptyBunString();
    }
    if (!JSC__JSValue__isStrictEqual(
        evaluate(context, "__private_host_function_248.call(__private_host_receiver_248, 11, 22)"),
        EncodedValue.fromInt32(33),
        context,
    ) or host_function_fixture.calls != 1)
        fail("private JSFunction call result mismatch");

    const caller_script = JSStringCreateWithUTF8CString("__private_host_function_248.call(__private_host_receiver_248, 13, 14)") orelse fail("CallFrame script creation failed");
    defer JSStringRelease(caller_script);
    const caller_url = JSStringCreateWithUTF8CString("callframe-251.js") orelse fail("CallFrame URL creation failed");
    defer JSStringRelease(caller_url);
    host_function_fixture.args = .{ EncodedValue.fromInt32(13), EncodedValue.fromInt32(14) };
    host_function_fixture.introspection_global = sibling_context;
    var caller_exception: JSValueRef = null;
    const caller_result = JSEvaluateScript(context, caller_script, null, caller_url, 31, &caller_exception) orelse fail("CallFrame named evaluation failed");
    if (caller_exception != null or !JSC__JSValue__isStrictEqual(EncodedValue.fromRef(caller_result), EncodedValue.fromInt32(27), context) or
        host_function_fixture.caller_line != 31 or host_function_fixture.caller_column == 0 or host_function_fixture.caller_is_bun_main or
        !JSC__JSValue__isStrictEqual(BunString__toJS(context, &host_function_fixture.caller_source), evaluate(context, "'callframe-251.js'"), context) or
        std.mem.indexOf(u8, host_function_fixture.description[0..host_function_fixture.description_len], "callframe-251.js") == null)
        fail("private CallFrame caller location mismatch");

    var stale_source = emptyBunString();
    var stale_line: c_uint = 99;
    var stale_column: c_uint = 99;
    Bun__CallFrame__getCallerSrcLoc(host_function_fixture.last_frame, context, &stale_source, &stale_line, &stale_column);
    if (stale_source.tag != .empty or stale_line != 0 or stale_column != 0 or
        Bun__CallFrame__isFromBunMain(host_function_fixture.last_frame, vm) or
        !std.mem.eql(u8, std.mem.span(Bun__CallFrame__describeFrame(host_function_fixture.last_frame)), "invalid CallFrame") or
        Bun__CallFrame__isFromBunMain(null, vm))
        fail("private CallFrame stale/null rejection mismatch");

    const builtin_url = JSStringCreateWithUTF8CString("builtin://bun/main") orelse fail("CallFrame builtin URL creation failed");
    defer JSStringRelease(builtin_url);
    host_function_fixture.args = .{ EncodedValue.fromInt32(13), EncodedValue.fromInt32(14) };
    host_function_fixture.introspection_global = context;
    caller_exception = null;
    const builtin_result = JSEvaluateScript(context, caller_script, null, builtin_url, 1, &caller_exception) orelse fail("CallFrame builtin evaluation failed");
    if (caller_exception != null or !JSC__JSValue__isStrictEqual(EncodedValue.fromRef(builtin_result), EncodedValue.fromInt32(27), context) or
        !host_function_fixture.caller_is_bun_main)
        fail("private CallFrame Bun main origin mismatch");
    host_function_fixture.vm = foreign_vm;
    caller_exception = null;
    _ = JSEvaluateScript(context, caller_script, null, builtin_url, 1, &caller_exception) orelse fail("CallFrame foreign-VM evaluation failed");
    if (caller_exception != null or host_function_fixture.caller_is_bun_main)
        fail("private CallFrame Bun main foreign-VM rejection mismatch");
    host_function_fixture.vm = vm;

    const reentry_url = JSStringCreateWithUTF8CString("reentry-251.js") orelse fail("CallFrame reentry URL creation failed");
    defer JSStringRelease(reentry_url);
    host_function_fixture.reenter = true;
    host_function_fixture.reentry_restored = false;
    caller_exception = null;
    const reentry_result = JSEvaluateScript(context, caller_script, null, reentry_url, 61, &caller_exception) orelse fail("CallFrame reentry evaluation failed");
    if (caller_exception != null or !JSC__JSValue__isStrictEqual(EncodedValue.fromRef(reentry_result), EncodedValue.fromInt32(27), context) or
        !host_function_fixture.reentry_restored)
        fail("private CallFrame nested active-frame restoration mismatch");

    host_function_fixture.args = .{ EncodedValue.fromInt32(5), EncodedValue.fromInt32(6) };
    host_function_fixture.introspection_global = foreign_context;
    if (!JSC__JSValue__isStrictEqual(evaluate(context, "__private_host_function_248.call(__private_host_receiver_248, 5, 6)"), EncodedValue.fromInt32(11), context) or
        host_function_fixture.caller_source.tag != .empty or host_function_fixture.caller_line != 0 or host_function_fixture.caller_column != 0)
        fail("private CallFrame foreign-global rejection mismatch");
    host_function_fixture.introspection_global = context;

    host_function_fixture.args[0] = EncodedValue.fromInt32(41);
    if (!JSC__JSValue__toBoolean(evaluate(context, "new __private_host_function_248(41).answer === 41")) or
        host_function_fixture.constructs != 1 or host_function_fixture.caller_line == 0)
        fail("private JSFunction explicit constructor mismatch");

    _ = JSC__VM__runGC(vm, true);
    host_function_fixture.this_value = host_receiver;
    host_function_fixture.args = .{ EncodedValue.fromInt32(2), EncodedValue.fromInt32(3) };
    if (!JSC__JSValue__isStrictEqual(
        evaluate(context, "__private_host_function_248.call(__private_host_receiver_248, 2, 3)"),
        EncodedValue.fromInt32(5),
        context,
    )) fail("private JSFunction GC rooting mismatch");

    exposeCell(sibling_context, "__private_sibling_host_function_248", host_function);
    const sibling_host_receiver = evaluate(sibling_context, "({ siblingReceiver: 248 })");
    exposeCell(sibling_context, "__private_sibling_host_receiver_248", sibling_host_receiver);
    host_function_fixture.this_value = sibling_host_receiver;
    host_function_fixture.args = .{ EncodedValue.fromInt32(7), EncodedValue.fromInt32(8) };
    if (!JSC__JSValue__isStrictEqual(
        evaluate(sibling_context, "__private_sibling_host_function_248.call(__private_sibling_host_receiver_248, 7, 8)"),
        EncodedValue.fromInt32(15),
        sibling_context,
    )) fail("private JSFunction sibling-realm call mismatch");

    const default_constructor = JSFunction__createFromZig(context, empty_bun_string, hostFunctionAdd, 0, .public, .none, null);
    exposeCell(context, "__private_default_constructor_248", default_constructor);
    if (!JSC__JSValue__toBoolean(evaluate(
        context,
        "try { new __private_default_constructor_248(); false } catch (error) { error instanceof TypeError }",
    ))) fail("private JSFunction default constructor did not throw");

    const throwing_host = JSFunction__createFromZig(context, empty_bun_string, hostFunctionThrow, 0, .private, .none, null);
    exposeCell(context, "__private_throwing_host_248", throwing_host);
    if (!JSC__JSValue__toBoolean(evaluate(
        context,
        "try { __private_throwing_host_248(); false } catch (error) { error === 2481 }",
    ))) fail("private JSFunction pending exception translation mismatch");

    const empty_host = JSFunction__createFromZig(context, empty_bun_string, hostFunctionEmpty, 0, .public, .none, null);
    exposeCell(context, "__private_empty_host_248", empty_host);
    if (!JSC__JSValue__toBoolean(evaluate(
        context,
        "try { __private_empty_host_248(); false } catch (error) { error instanceof TypeError }",
    ))) fail("private JSFunction empty return was accepted");

    host_function_foreign_result = evaluate(foreign_context, "({ foreign: 248 })");
    const foreign_host = JSFunction__createFromZig(context, empty_bun_string, hostFunctionForeign, 0, .public, .none, null);
    exposeCell(context, "__private_foreign_host_248", foreign_host);
    if (!JSC__JSValue__toBoolean(evaluate(
        context,
        "try { __private_foreign_host_248(); false } catch (error) { error instanceof TypeError }",
    ))) fail("private JSFunction foreign return was accepted");

    if (JSFunction__createFromZig(context, empty_bun_string, null, 0, .public, .none, null) != .empty or
        !JSGlobalObject__hasException(context))
        fail("private JSFunction null implementation was accepted");
    const null_implementation_exception = JSGlobalObject__tryTakeException(context);
    if (!JSC__JSValue__isAnyError(JSC__Exception__asJSValue(null_implementation_exception.cellPointer())))
        fail("private JSFunction null implementation exception mismatch");

    const dead_host_name = BunString{ .tag = .dead, .value = .{ .zig_string = .{ .tagged_ptr = 0, .len = 0 } } };
    if (JSFunction__createFromZig(context, dead_host_name, hostFunctionAdd, 0, .public, .none, null) != .empty or
        !JSGlobalObject__hasException(context))
        fail("private JSFunction dead name was accepted");
    JSGlobalObject__clearException(context);

    JSC__VM__throwError(vm, context, EncodedValue.fromInt32(2482));
    if (JSFunction__createFromZig(context, empty_bun_string, hostFunctionAdd, 0, .public, .none, null) != .empty)
        fail("private JSFunction ignored a pending exception");
    const preserved_host_exception = JSGlobalObject__tryTakeException(context);
    if (JSC__Exception__asJSValue(preserved_host_exception.cellPointer()) != EncodedValue.fromInt32(2482))
        fail("private JSFunction replaced a pending exception");

    var ffi_data_a: u64 = 0x252a;
    var ffi_data_b: u64 = 0x252b;
    var ffi_name_bytes = [_]u8{ 'f', 'f', 'i', 'A', 'd', 'd' };
    const ffi_name = ZigString{ .tagged_ptr = @intFromPtr(&ffi_name_bytes), .len = ffi_name_bytes.len };
    const ffi_function = Bun__CreateFFIFunctionWithDataValue(
        context,
        &ffi_name,
        2,
        ffiFunctionCallback,
        @ptrCast(&ffi_data_a),
    );
    if (ffi_function == .empty or Bun__FFIFunction_getDataPtr(ffi_function) != @as(*anyopaque, @ptrCast(&ffi_data_a)))
        fail("private FFI function creation/data mismatch");
    ffi_name_bytes[0] = 'X';
    exposeCell(context, "__private_ffi_function_252", ffi_function);
    if (!JSC__JSValue__toBoolean(evaluate(context, "typeof __private_ffi_function_252 === 'function' && __private_ffi_function_252.name === 'ffiAdd' && __private_ffi_function_252.length === 2")))
        fail("private FFI function metadata/name ownership mismatch");

    const ffi_receiver = evaluate(context, "({ ffiReceiver: 252 })");
    exposeCell(context, "__private_ffi_receiver_252", ffi_receiver);
    ffi_function_fixture = .{
        .global = context,
        .function = ffi_function,
        .expected_this = ffi_receiver,
        .args = .{ EncodedValue.fromInt32(10), EncodedValue.fromInt32(20) },
        .arg_count = 2,
        .expected_data = @ptrCast(&ffi_data_a),
    };
    if (!JSC__JSValue__isStrictEqual(
        evaluate(context, "__private_ffi_function_252.call(__private_ffi_receiver_252, 10, 20)"),
        EncodedValue.fromInt32(30),
        context,
    ) or ffi_function_fixture.calls != 1)
        fail("private FFI function call mismatch");

    Bun__FFIFunction_setDataPtr(ffi_function, @ptrCast(&ffi_data_b));
    ffi_function_fixture.expected_data = @ptrCast(&ffi_data_b);
    ffi_function_fixture.args = .{ EncodedValue.fromInt32(2), EncodedValue.fromInt32(3) };
    _ = JSC__VM__runGC(vm, true);
    if (Bun__FFIFunction_getDataPtr(ffi_function) != @as(*anyopaque, @ptrCast(&ffi_data_b)) or
        !JSC__JSValue__isStrictEqual(evaluate(context, "__private_ffi_function_252.call(__private_ffi_receiver_252, 2, 3)"), EncodedValue.fromInt32(5), context))
        fail("private FFI data mutation/GC mismatch");

    exposeCell(sibling_context, "__private_sibling_ffi_function_252", ffi_function);
    const sibling_ffi_receiver = evaluate(sibling_context, "({ siblingFFI: 252 })");
    exposeCell(sibling_context, "__private_sibling_ffi_receiver_252", sibling_ffi_receiver);
    ffi_function_fixture.expected_this = sibling_ffi_receiver;
    ffi_function_fixture.args = .{ EncodedValue.fromInt32(4), EncodedValue.fromInt32(5) };
    if (!JSC__JSValue__isStrictEqual(
        evaluate(sibling_context, "__private_sibling_ffi_function_252.call(__private_sibling_ffi_receiver_252, 4, 5)"),
        EncodedValue.fromInt32(9),
        sibling_context,
    )) fail("private FFI sibling-realm call mismatch");

    ffi_function_fixture.expected_this = null;
    ffi_function_fixture.args = .{ EncodedValue.fromInt32(41), .undefined };
    ffi_function_fixture.arg_count = 1;
    if (!JSC__JSValue__toBoolean(evaluate(context, "new __private_ffi_function_252(41).constructed === 41")) or
        ffi_function_fixture.constructs != 1)
        fail("private FFI constructor callback mismatch");

    ffi_function_fixture.expected_this = ffi_receiver;
    ffi_function_fixture.args = .{ EncodedValue.fromInt32(7), EncodedValue.fromInt32(8) };
    ffi_function_fixture.arg_count = 2;
    ffi_function_fixture.reenter = true;
    ffi_function_fixture.reentry_ok = false;
    if (!JSC__JSValue__isStrictEqual(
        evaluate(context, "__private_ffi_function_252.call(__private_ffi_receiver_252, 7, 8)"),
        EncodedValue.fromInt32(15),
        context,
    ) or !ffi_function_fixture.reentry_ok)
        fail("private FFI nested/reentrant call mismatch");

    Bun__FFIFunction_setDataPtr(ffi_function, null);
    ffi_function_fixture.expected_data = null;
    ffi_function_fixture.args = .{ EncodedValue.fromInt32(6), EncodedValue.fromInt32(7) };
    if (Bun__FFIFunction_getDataPtr(ffi_function) != null or
        !JSC__JSValue__isStrictEqual(evaluate(context, "__private_ffi_function_252.call(__private_ffi_receiver_252, 6, 7)"), EncodedValue.fromInt32(13), context))
        fail("private FFI null data mismatch");

    var dynamic_library_token: u8 = 0;
    const ffi_ptr_function = Bun__CreateFFIFunctionValue(
        context,
        null,
        0,
        ffiFunctionCallback,
        true,
        &dynamic_library_token,
    );
    exposeCell(context, "__private_ffi_ptr_function_252", ffi_ptr_function);
    const ffi_ptr_number = Bun__JSValue__toNumber(getProperty(context, ffi_ptr_function, "ptr"), context);
    if (@as(u64, @bitCast(ffi_ptr_number)) != @intFromPtr(&ffiFunctionCallback) or
        Bun__FFIFunction_getDataPtr(ffi_ptr_function) != null or
        !JSC__JSValue__toBoolean(evaluate(context, "__private_ffi_ptr_function_252.name === '' && __private_ffi_ptr_function_252.length === 0 && (() => { const d = Object.getOwnPropertyDescriptor(__private_ffi_ptr_function_252, 'ptr'); return d.writable === false && d.enumerable === true && d.configurable === true; })()")))
        fail("private FFI ptr property mismatch");
    Bun__FFIFunction_setDataPtr(ffi_ptr_function, @ptrCast(&ffi_data_a));
    if (Bun__FFIFunction_getDataPtr(ffi_ptr_function) != @as(*anyopaque, @ptrCast(&ffi_data_a)))
        fail("private FFI ptr/data field separation mismatch");

    if (Bun__FFIFunction_getDataPtr(host_function) != null or Bun__FFIFunction_getDataPtr(.undefined) != null) {
        fail("private FFI getter accepted a non-FFI value");
    }
    Bun__FFIFunction_setDataPtr(host_function, @ptrCast(&ffi_data_b));
    if (Bun__FFIFunction_getDataPtr(host_function) != null)
        fail("private FFI setter mutated an ordinary host function");

    const foreign_ffi = Bun__CreateFFIFunctionWithDataValue(
        foreign_context,
        null,
        0,
        ffiFunctionCallback,
        @ptrCast(&ffi_data_a),
    );
    if (Bun__FFIFunction_getDataPtr(foreign_ffi) != @as(*anyopaque, @ptrCast(&ffi_data_a)))
        fail("private FFI VM-independent cell downcast mismatch");
    Bun__FFIFunction_setDataPtr(foreign_ffi, @ptrCast(&ffi_data_b));
    if (Bun__FFIFunction_getDataPtr(foreign_ffi) != @as(*anyopaque, @ptrCast(&ffi_data_b)))
        fail("private FFI foreign-cell data mutation mismatch");

    const throwing_ffi = Bun__CreateFFIFunctionWithDataValue(context, null, 0, ffiFunctionThrow, null);
    exposeCell(context, "__private_throwing_ffi_252", throwing_ffi);
    if (!JSC__JSValue__toBoolean(evaluate(context, "try { __private_throwing_ffi_252(); false } catch (error) { error === 2521 }")))
        fail("private FFI pending exception translation mismatch");

    if (Bun__CreateFFIFunctionWithDataValue(context, null, 0, null, null) != .empty or
        !JSGlobalObject__hasException(context))
        fail("private FFI null callback was accepted");
    JSGlobalObject__clearException(context);
    JSC__VM__throwError(vm, context, EncodedValue.fromInt32(2522));
    if (Bun__CreateFFIFunctionValue(context, null, 0, ffiFunctionCallback, false, null) != .empty)
        fail("private FFI creation ignored a pending exception");
    const preserved_ffi_exception = JSGlobalObject__tryTakeException(context);
    if (JSC__Exception__asJSValue(preserved_ffi_exception.cellPointer()) != EncodedValue.fromInt32(2522))
        fail("private FFI creation replaced a pending exception");

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
        \\globalThis.__private_direct_target = Object.create({ set direct(value) { __private_direct_setter_hits++; }, set bunDirect(value) { __private_direct_setter_hits++; } });
        \\__private_direct_target;
    );
    const direct_key_bytes = "direct";
    const direct_key = ZigString{ .tagged_ptr = @intFromPtr(direct_key_bytes.ptr), .len = direct_key_bytes.len };
    JSC__JSValue__put(direct_target, context, &direct_key, encoded_object);
    if (!JSC__JSValue__toBoolean(evaluate(context, "__private_direct_setter_hits === 0 && Object.hasOwn(__private_direct_target, 'direct') && __private_direct_target.direct === __private_aggregate_identity")))
        fail("private direct put invoked prototype setter or lost identity");
    const bun_direct_key_bytes = "bunDirect";
    const bun_direct_key = BunString{ .tag = .static_zig_string, .value = .{ .zig_string = .{ .tagged_ptr = @intFromPtr(bun_direct_key_bytes.ptr), .len = bun_direct_key_bytes.len } } };
    JSC__JSValue__putBunString(direct_target, context, &bun_direct_key, EncodedValue.fromInt32(370));
    if (!JSC__JSValue__toBoolean(evaluate(context, "__private_direct_setter_hits === 0 && __private_direct_target.bunDirect === 370")))
        fail("private BunString direct put mismatch");
    const bun_items_bytes = "items";
    const bun_items = BunString{ .tag = .static_zig_string, .value = .{ .zig_string = .{ .tagged_ptr = @intFromPtr(bun_items_bytes.ptr), .len = bun_items_bytes.len } } };
    if (JSC__JSValue__upsertBunStringArray(direct_target, context, &bun_items, EncodedValue.fromInt32(1)) != .undefined or
        JSC__JSValue__upsertBunStringArray(direct_target, context, &bun_items, EncodedValue.fromInt32(2)) != .undefined or
        JSC__JSValue__upsertBunStringArray(direct_target, context, &bun_items, EncodedValue.fromInt32(3)) != .undefined or
        !JSC__JSValue__toBoolean(evaluate(context, "Array.isArray(__private_direct_target.items) && __private_direct_target.items.join(',') === '1,2,3'")))
        fail("private BunString one-or-array upsert mismatch");
    if (!JSC__JSValue__hasOwnPropertyValue(direct_target, context, evaluate(context, "'items'")) or
        JSC__JSValue__hasOwnPropertyValue(direct_target, context, evaluate(context, "'missing'")))
        fail("private value-key own-property query mismatch");
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

    const property_target = evaluate(context,
        \\globalThis.__private_property_258_hits = 0;
        \\globalThis.__private_property_258_symbol = Symbol('symbol258');
        \\globalThis.__private_property_258 = {};
        \\Object.defineProperty(__private_property_258, '2', { value: 2, enumerable: true, configurable: true });
        \\Object.defineProperty(__private_property_258, 'data', { value: 258, enumerable: true, configurable: true });
        \\Object.defineProperty(__private_property_258, 'hidden', { value: 259, enumerable: false, configurable: true });
        \\Object.defineProperty(__private_property_258, 'getOnly', { get() { __private_property_258_hits++; return 260; }, enumerable: true, configurable: true });
        \\Object.defineProperty(__private_property_258, 'setOnly', { set(v) { __private_property_258_hits += v; }, enumerable: false, configurable: true });
        \\Object.defineProperty(__private_property_258, 'both', { get() { __private_property_258_hits++; return 261; }, set(v) { __private_property_258_hits += v; }, enumerable: true, configurable: true });
        \\Object.defineProperty(__private_property_258, 'neither', { get: undefined, set: undefined, enumerable: true, configurable: true });
        \\Object.defineProperty(__private_property_258, '__proto__', { value: 1, enumerable: false, configurable: true });
        \\Object.defineProperty(__private_property_258, '__esModule', { value: true, enumerable: false, configurable: true });
        \\Object.defineProperty(__private_property_258, Symbol.toStringTag, { value: 'Filtered', enumerable: false, configurable: true });
        \\Object.defineProperty(__private_property_258, 'constructor', { value: 1, enumerable: true, configurable: true });
        \\Object.defineProperty(__private_property_258, 'length', { value: 1, enumerable: true, configurable: true });
        \\__private_property_258[__private_property_258_symbol] = 262;
        \\__private_property_258;
    );
    var property_state = PropertyFixtureState{
        .global = context,
        .vm = vm,
        .run_gc = true,
        .reenter = true,
    };
    JSC__JSValue__forEachPropertyNonIndexed(property_target, context, &property_state, propertyFixtureCallback);
    const expected_property_names = [_][]const u8{ "data", "hidden", "getOnly", "setOnly", "both", "neither", "symbol258" };
    if (property_state.calls != expected_property_names.len or
        !JSC__JSValue__toBoolean(evaluate(context, "__private_property_258_hits === 0")))
        fail("private property traversal count/filter/getter-purity mismatch");
    for (expected_property_names, property_state.entries[0..property_state.calls], 0..) |expected, *entry, index| {
        if (!std.mem.eql(u8, propertyEntryName(entry), expected) or entry.is_symbol != (index == expected_property_names.len - 1))
            fail("private property traversal key order/flags mismatch");
    }
    if (!JSC__JSValue__isStrictEqual(property_state.entries[0].value, EncodedValue.fromInt32(258), context) or
        !JSC__JSValue__isStrictEqual(property_state.entries[1].value, EncodedValue.fromInt32(259), context) or
        !JSC__JSValue__isStrictEqual(property_state.entries[6].value, EncodedValue.fromInt32(262), context))
        fail("private property traversal data value mismatch");
    const getter_cells = property_state.entries[2..6];
    for (getter_cells) |entry| {
        if (!JSC__JSValue__isGetterSetter(entry.value) or JSC__JSValue__isCustomGetterSetter(entry.value) or
            JSC__JSValue__jsType(entry.value) != 7)
            fail("private property traversal GetterSetter classification mismatch");
    }
    if (JSC__GetterSetter__isGetterNull(getter_cells[0].value.cellPointer()) or
        !JSC__GetterSetter__isSetterNull(getter_cells[0].value.cellPointer()) or
        !JSC__GetterSetter__isGetterNull(getter_cells[1].value.cellPointer()) or
        JSC__GetterSetter__isSetterNull(getter_cells[1].value.cellPointer()) or
        JSC__GetterSetter__isGetterNull(getter_cells[2].value.cellPointer()) or
        JSC__GetterSetter__isSetterNull(getter_cells[2].value.cellPointer()) or
        !JSC__GetterSetter__isGetterNull(getter_cells[3].value.cellPointer()) or
        !JSC__GetterSetter__isSetterNull(getter_cells[3].value.cellPointer()))
        fail("private property traversal GetterSetter null-slot mismatch");
    if (!JSC__CustomGetterSetter__isGetterNull(getter_cells[0].value.cellPointer()) or
        !JSC__CustomGetterSetter__isSetterNull(getter_cells[0].value.cellPointer()))
        fail("private property traversal wrong-kind custom null safety mismatch");

    var property_repeat = PropertyFixtureState{ .global = sibling_context, .vm = vm };
    JSC__JSValue__forEachPropertyNonIndexed(property_target, sibling_context, &property_repeat, propertyFixtureCallback);
    if (property_repeat.calls != property_state.calls) fail("private property traversal sibling count mismatch");
    for (expected_property_names, property_repeat.entries[0..property_repeat.calls], 0..) |expected, *entry, index| {
        if (!std.mem.eql(u8, propertyEntryName(entry), expected) or entry.is_symbol != (index == expected_property_names.len - 1))
            fail("private property traversal sibling Symbol recovery mismatch");
    }
    for (getter_cells, property_repeat.entries[2..6]) |first, second| {
        if (!JSC__JSValue__isStrictEqual(first.value, second.value, sibling_context))
            fail("private property traversal stable sibling descriptor identity mismatch");
    }

    var property_throw = PropertyFixtureState{ .global = context, .vm = vm, .throw_at = 1 };
    JSC__JSValue__forEachPropertyNonIndexed(property_target, context, &property_throw, propertyFixtureCallback);
    if (property_throw.calls != 2 or !JSGlobalObject__hasException(context))
        fail("private property traversal callback exception stop mismatch");
    const property_callback_exception = JSGlobalObject__tryTakeException(context);
    if (JSC__Exception__asJSValue(property_callback_exception.cellPointer()) != EncodedValue.fromInt32(2581))
        fail("private property traversal callback exception identity mismatch");

    var property_blocked = PropertyFixtureState{ .global = context, .vm = vm };
    JSC__VM__throwError(vm, context, EncodedValue.fromInt32(2582));
    JSC__JSValue__forEachPropertyNonIndexed(property_target, context, &property_blocked, propertyFixtureCallback);
    JSC__JSValue__forEachPropertyNonIndexed(evaluate(foreign_context, "({ foreign: 1 })"), context, &property_blocked, propertyFixtureCallback);
    JSC__JSValue__forEachPropertyNonIndexed(EncodedValue.fromInt32(1), context, &property_blocked, propertyFixtureCallback);
    const property_preserved_exception = JSGlobalObject__tryTakeException(context);
    if (property_blocked.calls != 0 or
        JSC__Exception__asJSValue(property_preserved_exception.cellPointer()) != EncodedValue.fromInt32(2582))
        fail("private property traversal pending/foreign/primitive boundary mismatch");

    const property_proxy = evaluate(context,
        \\globalThis.__private_property_258_proxy_hits = 0;
        \\globalThis.__private_property_258_proxy = new Proxy({}, {
        \\  ownKeys() { return ['proxyData', 'proxyAccessor', 'proxyThrow']; },
        \\  getOwnPropertyDescriptor(target, key) {
        \\    if (key === 'proxyAccessor') return { get() { __private_property_258_proxy_hits += 100; return 302; }, set: undefined, enumerable: false, configurable: true };
        \\    return { value: key === 'proxyData' ? 300 : 303, writable: true, enumerable: true, configurable: true };
        \\  },
        \\  get(target, key) {
        \\    if (key === 'proxyThrow') throw 2583;
        \\    __private_property_258_proxy_hits++;
        \\    return 301;
        \\  }
        \\});
        \\__private_property_258_proxy;
    );
    var proxy_property_state = PropertyFixtureState{ .global = context, .vm = vm };
    JSC__JSValue__forEachPropertyNonIndexed(property_proxy, context, &proxy_property_state, propertyFixtureCallback);
    if (proxy_property_state.calls != 3 or
        !std.mem.eql(u8, propertyEntryName(&proxy_property_state.entries[0]), "proxyData") or
        !std.mem.eql(u8, propertyEntryName(&proxy_property_state.entries[1]), "proxyAccessor") or
        !std.mem.eql(u8, propertyEntryName(&proxy_property_state.entries[2]), "proxyThrow") or
        !JSC__JSValue__isStrictEqual(proxy_property_state.entries[0].value, EncodedValue.fromInt32(301), context) or
        !JSC__JSValue__isGetterSetter(proxy_property_state.entries[1].value) or
        proxy_property_state.entries[2].value != .undefined or
        !JSC__JSValue__toBoolean(evaluate(context, "__private_property_258_proxy_hits === 1")) or
        JSGlobalObject__hasException(context))
        fail("private property traversal Proxy descriptor/get-exception mismatch");

    var throwing_keys_state = PropertyFixtureState{ .global = context, .vm = vm };
    const throwing_keys = evaluate(context, "new Proxy({}, { ownKeys() { throw 2584; } })");
    JSC__JSValue__forEachPropertyNonIndexed(throwing_keys, context, &throwing_keys_state, propertyFixtureCallback);
    const throwing_keys_exception = JSGlobalObject__tryTakeException(context);
    if (throwing_keys_state.calls != 0 or
        JSC__Exception__asJSValue(throwing_keys_exception.cellPointer()) != EncodedValue.fromInt32(2584))
        fail("private property traversal Proxy ownKeys exception mismatch");

    const custom_values = [_]JSStaticValue{
        .{ .name = "customGet", .get_property = customPropertyGetter },
        .{ .name = "customSet", .set_property = customPropertySetter, .attributes = 1 << 2 },
        .{},
    };
    var custom_definition = JSClassDefinition{ .static_values = &custom_values };
    const custom_class = JSClassCreate(&custom_definition) orelse fail("private property traversal custom class creation failed");
    defer JSClassRelease(custom_class);
    const custom_object = JSObjectMake(context, custom_class, null) orelse fail("private property traversal custom object creation failed");
    var custom_state = PropertyFixtureState{ .global = context, .vm = vm, .run_gc = true };
    JSC__JSValue__forEachPropertyNonIndexed(EncodedValue.fromRef(custom_object), context, &custom_state, propertyFixtureCallback);
    if (custom_state.calls != 2 or
        !std.mem.eql(u8, propertyEntryName(&custom_state.entries[0]), "customGet") or
        !std.mem.eql(u8, propertyEntryName(&custom_state.entries[1]), "customSet") or
        custom_property_get_calls != 0 or custom_property_set_calls != 0)
        fail("private property traversal custom accessor order/purity mismatch");
    const custom_get = custom_state.entries[0].value;
    const custom_set = custom_state.entries[1].value;
    if (!JSC__JSValue__isCustomGetterSetter(custom_get) or !JSC__JSValue__isCustomGetterSetter(custom_set) or
        JSC__JSValue__isGetterSetter(custom_get) or JSC__JSValue__jsType(custom_get) != 8 or
        JSC__CustomGetterSetter__isGetterNull(custom_get.cellPointer()) or
        !JSC__CustomGetterSetter__isSetterNull(custom_get.cellPointer()) or
        !JSC__CustomGetterSetter__isGetterNull(custom_set.cellPointer()) or
        JSC__CustomGetterSetter__isSetterNull(custom_set.cellPointer()))
        fail("private property traversal CustomGetterSetter classification/null-slot mismatch");
    var custom_repeat = PropertyFixtureState{ .global = sibling_context, .vm = vm };
    JSC__JSValue__forEachPropertyNonIndexed(EncodedValue.fromRef(custom_object), sibling_context, &custom_repeat, propertyFixtureCallback);
    if (custom_repeat.calls != 2 or
        !JSC__JSValue__isStrictEqual(custom_get, custom_repeat.entries[0].value, sibling_context) or
        !JSC__JSValue__isStrictEqual(custom_set, custom_repeat.entries[1].value, sibling_context))
        fail("private property traversal stable custom sibling identity mismatch");

    const sibling_dom_exception = ZigString__toDOMExceptionInstance(&empty_zig_string, sibling_context, 16);
    exposeCell(sibling_context, "__private_sibling_dom_exception", sibling_dom_exception);
    if (!JSC__JSValue__toBoolean(evaluate(sibling_context, "Object.getPrototypeOf(__private_sibling_dom_exception) === DOMException.prototype && __private_sibling_dom_exception.name === 'AbortError'")))
        fail("DOMException matrix selected-realm prototype mismatch");

    const sibling_system_error_instance = SystemError__toErrorInstance(&full_system_error, sibling_context);
    exposeCell(sibling_context, "__private_sibling_system_error", sibling_system_error_instance);
    if (sibling_system_error_instance == .empty or
        !JSC__JSValue__toBoolean(evaluate(sibling_context, "Object.getPrototypeOf(__private_sibling_system_error) === Error.prototype && __private_sibling_system_error.code === 'ENOENT' && __private_sibling_system_error.errno === -2")))
        fail("SystemError bridge selected-realm prototype/field mismatch");

    if (JSC__JSGlobalObject__bunVM(context) == null or
        JSC__JSGlobalObject__bunVM(context) != JSC__JSGlobalObject__vm(context) or
        JSC__JSGlobalObject__bunVM(sibling_context) != JSC__JSGlobalObject__bunVM(context) or
        JSC__JSGlobalObject__bunVM(sibling_context) != JSC__JSGlobalObject__vm(sibling_context) or
        JSC__JSGlobalObject__bunVM(foreign_context) == JSC__JSGlobalObject__bunVM(context) or
        JSC__JSGlobalObject__bunVM(foreign_context) != JSC__JSGlobalObject__vm(foreign_context) or
        JSC__JSGlobalObject__bunVM(null) != null)
        fail("private bunVM ownership identity mismatch");

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

    // Private C-API extensions (#371): the call wrapper owns the recursive API
    // lock, preserves argument order/default-this, and returns throws as an
    // exception cell. Proxy projection is a direct, trap-free VM inquiry.
    const private_call_function = evaluate(context, "(function(a,b){return [this.marker,a,b]})");
    const private_call_this = evaluate(context, "({marker:371})");
    const private_call_args = [_]JSValueRef{
        evaluate(context, "10").cellPointer(),
        evaluate(context, "11").cellPointer(),
    };
    const private_call_result = JSObjectCallAsFunctionReturnValueHoldingAPILock(
        context,
        private_call_function.cellPointer(),
        private_call_this.cellPointer(),
        private_call_args.len,
        &private_call_args,
    );
    exposeCell(context, "__private_call_result_371", private_call_result);
    if (!JSC__JSValue__toBoolean(evaluate(context, "JSON.stringify(__private_call_result_371)==='[371,10,11]'")))
        fail("private API-lock call result mismatch");
    const default_this_function = evaluate(context, "(function(){return this===globalThis})");
    if (JSObjectCallAsFunctionReturnValueHoldingAPILock(context, default_this_function.cellPointer(), null, 0, null) != .true)
        fail("private API-lock call default this mismatch");
    const private_call_thrower = evaluate(context, "(function(){throw 371})");
    const private_call_exception = JSObjectCallAsFunctionReturnValueHoldingAPILock(context, private_call_thrower.cellPointer(), null, 0, null);
    if (!JSC__JSValue__isException(private_call_exception, vm) or
        JSC__Exception__asJSValue(private_call_exception.cellPointer()) != EncodedValue.fromInt32(371) or
        JSGlobalObject__hasException(context))
        fail("private API-lock call exception-cell mismatch");
    if (JSObjectCallAsFunctionReturnValueHoldingAPILock(context, null, null, 0, null) != .empty or
        JSObjectCallAsFunctionReturnValueHoldingAPILock(context, private_call_this.cellPointer(), null, 0, null) != .empty)
        fail("private API-lock call invalid callable mismatch");

    const private_proxy_target = evaluate(context, "globalThis.__private_proxy_target_371={marker:371};__private_proxy_target_371");
    const private_proxy = evaluate(
        context,
        "globalThis.__private_proxy_traps_371=0;new Proxy(__private_proxy_target_371,{" ++
            "get(){__private_proxy_traps_371++},getOwnPropertyDescriptor(){__private_proxy_traps_371++}})",
    );
    const projected_proxy_target = JSObjectGetProxyTarget(private_proxy.cellPointer()) orelse
        fail("private proxy target projection failed");
    if (!JSC__JSValue__isStrictEqual(EncodedValue.fromRef(projected_proxy_target), private_proxy_target, context) or
        JSC__JSValue__toInt32(evaluate(context, "__private_proxy_traps_371")) != 0 or
        JSObjectGetProxyTarget(private_proxy_target.cellPointer()) != null)
        fail("private proxy target identity/trap mismatch");
    const revoked_proxy = evaluate(context, "(()=>{const p=Proxy.revocable({},{});p.revoke();return p.proxy})()");
    if (JSObjectGetProxyTarget(revoked_proxy.cellPointer()) != null or JSObjectGetProxyTarget(null) != null)
        fail("private proxy target invalid/revoked mismatch");

    // Async-context call boundary (#373): a realm with no active context keeps
    // the callback's exact identity, while the call export still exercises the
    // pinned encoded-value signature, argument order, default-this, exception,
    // and VM-ownership behavior. Active capture/restoration is covered by the
    // engine test, which can set the otherwise-private realm slot legitimately.
    if (AsyncContextFrame__withAsyncContextIfNeeded(context, private_call_function) != private_call_function or
        Bun__JSValue__isAsyncContextFrame(private_call_function))
        fail("private inactive async-context identity/brand mismatch");
    const async_call_args = [_]EncodedValue{ EncodedValue.fromInt32(12), EncodedValue.fromInt32(13) };
    const async_call_result = Bun__JSValue__call(
        context,
        private_call_function,
        private_call_this,
        async_call_args.len,
        &async_call_args,
    );
    exposeCell(context, "__private_async_call_result_373", async_call_result);
    if (!JSC__JSValue__toBoolean(evaluate(context, "JSON.stringify(__private_async_call_result_373)==='[371,12,13]'")))
        fail("private async-context call result mismatch");
    const no_async_args: [1]EncodedValue = undefined;
    if (Bun__JSValue__call(context, default_this_function, .empty, 0, &no_async_args) != .true)
        fail("private async-context call default-this mismatch");
    if (Bun__JSValue__call(context, private_call_thrower, .empty, 0, &no_async_args) != .empty or
        JSC__Exception__asJSValue(JSGlobalObject__tryTakeException(context).cellPointer()) != EncodedValue.fromInt32(371))
        fail("private async-context call exception mismatch");
    if (Bun__JSValue__call(context, evaluate(foreign_context, "(function(){return 1})"), .empty, 0, &no_async_args) != .empty or
        AsyncContextFrame__withAsyncContextIfNeeded(context, .empty) != .empty or
        Bun__JSValue__isAsyncContextFrame(EncodedValue.fromInt32(1)))
        fail("private async-context invalid/foreign boundary mismatch");

    const traced_script = JSStringCreateWithUTF8CString("(function outer249(){ return (function inner249(){ return new Error('stack-249'); })(); })()") orelse fail("trace script creation failed");
    defer JSStringRelease(traced_script);
    const traced_url = JSStringCreateWithUTF8CString("trace-249.js") orelse fail("trace URL creation failed");
    defer JSStringRelease(traced_url);
    var traced_eval_exception: JSValueRef = null;
    const traced_error_ref = JSEvaluateScript(context, traced_script, null, traced_url, 41, &traced_eval_exception) orelse fail("trace evaluation failed");
    if (traced_eval_exception != null) fail("trace evaluation threw");
    const traced_error = EncodedValue.fromRef(traced_error_ref);
    JSC__VM__throwError(vm, context, traced_error);
    const traced_exception = JSGlobalObject__tryTakeException(context);
    var trace_frames: [4]ZigStackFrame = undefined;
    var trace = ZigStackTrace{
        .source_lines_ptr = null,
        .source_lines_numbers = null,
        .source_lines_len = 99,
        .source_lines_to_collect = 0,
        .frames_ptr = &trace_frames,
        .frames_len = 99,
        .frames_cap = trace_frames.len,
    };
    JSC__Exception__getStackTrace(traced_exception.cellPointer(), sibling_context, &trace);
    if (trace.frames_len != 3 or trace.source_lines_len != 0 or trace.referenced_source_provider != null or
        trace_frames[0].code_type != .Function or trace_frames[1].code_type != .Function or
        trace_frames[2].code_type != .Global or trace_frames[0].position.line != 40 or
        trace_frames[0].position.column < 0 or trace_frames[0].jsc_stack_frame_index != 0 or
        trace_frames[1].jsc_stack_frame_index != 1 or trace_frames[2].jsc_stack_frame_index != 2 or
        trace_frames[0].function_name.tag != .wtf_string_impl or
        trace_frames[1].function_name.tag != .wtf_string_impl)
        fail("structured exception stack mismatch");
    if (!JSC__JSValue__isStrictEqual(BunString__toJS(context, &trace_frames[0].source_url), evaluate(context, "'trace-249.js'"), context))
        fail("structured exception stack source URL mismatch");
    for (trace_frames[0..trace.frames_len]) |frame| {
        if (frame.function_name.tag == .wtf_string_impl) Bun__WTFStringImpl__deref(frame.function_name.value.wtf_string_impl);
        if (frame.source_url.tag == .wtf_string_impl) Bun__WTFStringImpl__deref(frame.source_url.value.wtf_string_impl);
    }
    trace.frames_len = 99;
    trace.frames_cap = 1;
    JSC__Exception__getStackTrace(traced_exception.cellPointer(), context, &trace);
    if (trace.frames_len != 1 or trace_frames[0].jsc_stack_frame_index != 0)
        fail("structured exception stack capacity mismatch");
    if (trace_frames[0].function_name.tag == .wtf_string_impl) Bun__WTFStringImpl__deref(trace_frames[0].function_name.value.wtf_string_impl);
    if (trace_frames[0].source_url.tag == .wtf_string_impl) Bun__WTFStringImpl__deref(trace_frames[0].source_url.value.wtf_string_impl);
    trace.frames_len = 99;
    JSC__Exception__getStackTrace(traced_exception.cellPointer(), foreign_context, &trace);
    if (trace.frames_len != 0) fail("structured exception stack accepted foreign VM");

    var projected_frames: [4]ZigStackFrame = undefined;
    var projected_source_lines: [3]BunString = @splat(emptyBunString());
    var projected_source_numbers: [3]i32 = @splat(-1);
    var projected = ZigException{
        .type = .UserErrorCode,
        .runtime_type = .Nothing,
        .syscall = emptyBunString(),
        .system_code = emptyBunString(),
        .path = emptyBunString(),
        .name = emptyBunString(),
        .message = emptyBunString(),
        .stack = .{
            .source_lines_ptr = &projected_source_lines,
            .source_lines_numbers = &projected_source_numbers,
            .source_lines_len = projected_source_lines.len,
            .source_lines_to_collect = projected_source_lines.len,
            .frames_ptr = &projected_frames,
            .frames_len = 0,
            .frames_cap = projected_frames.len,
        },
        .exception = null,
        .browser_url = emptyBunString(),
    };
    JSC__JSValue__toZigException(traced_exception, sibling_context, &projected);
    if (projected.type != .Error or projected.runtime_type != .Nothing or
        projected.exception != traced_exception.cellPointer() or projected.stack.frames_len != 3 or
        !JSC__JSValue__isStrictEqual(BunString__toJS(context, &projected.name), evaluate(context, "'Error'"), context) or
        !JSC__JSValue__isStrictEqual(BunString__toJS(context, &projected.message), evaluate(context, "'stack-249'"), context))
        fail("complete ZigException projection mismatch");
    ZigException__collectSourceLines(traced_exception, context, &projected);
    if (projected.stack.source_lines_len != 1 or projected_source_numbers[0] != 40 or
        !JSC__JSValue__isStrictEqual(BunString__toJS(context, &projected_source_lines[0]), evaluate(context, "\"(function outer249(){ return (function inner249(){ return new Error('stack-249'); })(); })()\""), context))
        fail("ZigException source-line projection mismatch");

    var by_value = ZigException__fromException(traced_exception.cellPointer());
    if (by_value.type != .Error or by_value.exception != traced_exception.cellPointer() or by_value.stack.frames_len != 0 or
        !JSC__JSValue__isStrictEqual(BunString__toJS(context, &by_value.message), evaluate(context, "'stack-249'"), context))
        fail("by-value ZigException projection mismatch");
    releaseZigException(&by_value);

    var primitive_projection = ZigException__fromException(primitive_exception_cell);
    if (primitive_projection.type != .Error or primitive_projection.exception != primitive_exception_cell or
        !JSC__JSValue__isStrictEqual(BunString__toJS(context, &primitive_projection.name), evaluate(context, "'Error'"), context) or
        !JSC__JSValue__isStrictEqual(BunString__toJS(context, &primitive_projection.message), evaluate(context, "'42'"), context))
        fail("primitive ZigException projection mismatch");
    releaseZigException(&primitive_projection);

    var system_projection = ZigException__fromException(null);
    const system_error = evaluate(context, "Object.assign(new TypeError('disk'), { cause: 1.5, errno: -2, syscall: 'open', code: 'ENOENT', path: '/tmp/x', fd: 9 })");
    JSC__JSValue__toZigException(system_error, context, &system_projection);
    if (system_projection.type != .TypeError or system_projection.runtime_type != .Number or
        system_projection.errno != -2 or system_projection.fd != 9 or system_projection.exception != null or
        !JSC__JSValue__isStrictEqual(BunString__toJS(context, &system_projection.syscall), evaluate(context, "'open'"), context) or
        !JSC__JSValue__isStrictEqual(BunString__toJS(context, &system_projection.system_code), evaluate(context, "'ENOENT'"), context) or
        !JSC__JSValue__isStrictEqual(BunString__toJS(context, &system_projection.path), evaluate(context, "'/tmp/x'"), context))
        fail("system-like ZigException projection mismatch");
    releaseZigException(&system_projection);

    var dom_projection = ZigException__fromException(null);
    const dom_error = evaluate(context, "new DOMException('gone', 'AbortError')");
    JSC__JSValue__toZigException(dom_error, context, &dom_projection);
    if (dom_projection.type != .Error or
        !JSC__JSValue__isStrictEqual(BunString__toJS(context, &dom_projection.name), evaluate(context, "'AbortError'"), context) or
        !JSC__JSValue__isStrictEqual(BunString__toJS(context, &dom_projection.message), evaluate(context, "'gone'"), context))
        fail("DOM ZigException projection mismatch");
    releaseZigException(&dom_projection);

    var syntax_projection = ZigException__fromException(null);
    JSC__JSValue__toZigException(evaluate(context, "new SyntaxError('parse')"), context, &syntax_projection);
    if (syntax_projection.type != .SyntaxError or
        !JSC__JSValue__isStrictEqual(BunString__toJS(context, &syntax_projection.message), evaluate(context, "'parse'"), context))
        fail("SyntaxError ZigException projection mismatch");
    releaseZigException(&syntax_projection);

    const line_script = JSStringCreateWithUTF8CString("const pre250 = 1;\nconst mid250 = '💩';\nnew Error('lines-250');") orelse fail("source-line script creation failed");
    defer JSStringRelease(line_script);
    const line_url = JSStringCreateWithUTF8CString("lines-250.js") orelse fail("source-line URL creation failed");
    defer JSStringRelease(line_url);
    const line_error_ref = JSEvaluateScript(context, line_script, null, line_url, 70, &traced_eval_exception) orelse fail("source-line evaluation failed");
    if (traced_eval_exception != null) fail("source-line evaluation threw");
    const line_error = EncodedValue.fromRef(line_error_ref);
    var line_frames: [2]ZigStackFrame = undefined;
    var line_strings: [3]BunString = @splat(emptyBunString());
    var line_numbers: [3]i32 = @splat(-1);
    var line_projection = ZigException__fromException(null);
    line_projection.stack = .{
        .source_lines_ptr = &line_strings,
        .source_lines_numbers = &line_numbers,
        .source_lines_len = line_strings.len,
        .source_lines_to_collect = 2,
        .frames_ptr = &line_frames,
        .frames_len = 0,
        .frames_cap = line_frames.len,
    };
    JSC__JSValue__toZigException(line_error, context, &line_projection);
    ZigException__collectSourceLines(line_error, sibling_context, &line_projection);
    if (line_projection.stack.source_lines_len != 2) fail("multi-line ZigException source count mismatch");
    if (line_numbers[0] != 71 or line_numbers[1] != 70 or line_numbers[2] != -1)
        fail("multi-line ZigException source numbers mismatch");
    if (!JSC__JSValue__isStrictEqual(BunString__toJS(context, &line_strings[0]), evaluate(context, "\"new Error('lines-250');\""), context))
        fail("multi-line ZigException current source mismatch");
    if (!JSC__JSValue__isStrictEqual(BunString__toJS(context, &line_strings[1]), evaluate(context, "\"const mid250 = '💩';\""), context))
        fail("multi-line ZigException previous source mismatch");
    releaseZigException(&line_projection);

    var rejected_projection = projected;
    rejected_projection.type = .AggregateError;
    JSC__JSValue__toZigException(traced_exception, foreign_context, &rejected_projection);
    if (rejected_projection.type != .AggregateError) fail("complete ZigException projection accepted foreign VM");
    releaseZigException(&projected);

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

    const contiguous_array = evaluate(context, "globalThis.__private_contiguous_255 = [1, 2, 3]; __private_contiguous_255");
    var contiguous_length: u32 = 0xfeed_beef;
    const contiguous = Bun__JSArray__getContiguousVector(contiguous_array, &contiguous_length) orelse
        fail("private contiguous JSArray vector missing");
    if (contiguous_length != 3 or
        contiguous[0] != EncodedValue.fromInt32(1) or
        contiguous[1] != EncodedValue.fromInt32(2) or
        contiguous[2] != EncodedValue.fromInt32(3) or
        !Bun__JSArray__contiguousVectorIsStillValid(contiguous_array, contiguous, contiguous_length))
        fail("private contiguous JSArray vector mismatch");
    var second_contiguous_length: u32 = 0;
    const second_contiguous = Bun__JSArray__getContiguousVector(contiguous_array, &second_contiguous_length) orelse
        fail("second private contiguous JSArray vector missing");
    if (second_contiguous == contiguous or second_contiguous_length != contiguous_length or
        !Bun__JSArray__contiguousVectorIsStillValid(contiguous_array, contiguous, contiguous_length) or
        !Bun__JSArray__contiguousVectorIsStillValid(contiguous_array, second_contiguous, second_contiguous_length) or
        Bun__JSArray__contiguousVectorIsStillValid(constructed, contiguous, contiguous_length) or
        Bun__JSArray__contiguousVectorIsStillValid(contiguous_array, contiguous, contiguous_length - 1) or
        Bun__JSArray__contiguousVectorIsStillValid(contiguous_array, @ptrFromInt(16), contiguous_length) or
        Bun__JSArray__contiguousVectorIsStillValid(contiguous_array, null, contiguous_length))
        fail("private contiguous JSArray vector identity mismatch");

    _ = JSC__VM__runGC(vm, true);
    if (!Bun__JSArray__contiguousVectorIsStillValid(contiguous_array, contiguous, contiguous_length))
        fail("private contiguous JSArray vector did not survive GC");
    _ = evaluate(context, "__private_contiguous_255[1] = 22");
    if (Bun__JSArray__contiguousVectorIsStillValid(contiguous_array, contiguous, contiguous_length) or
        JSC__JSValue__getDirectIndex(contiguous_array, context, 1) != EncodedValue.fromInt32(22))
        fail("private contiguous JSArray replacement invalidation mismatch");
    var replaced_length: u32 = 0;
    const replaced_vector = Bun__JSArray__getContiguousVector(contiguous_array, &replaced_length) orelse
        fail("private replaced contiguous JSArray vector missing");
    _ = evaluate(context, "__private_contiguous_255.push(4)");
    if (Bun__JSArray__contiguousVectorIsStillValid(contiguous_array, replaced_vector, replaced_length))
        fail("private contiguous JSArray growth did not invalidate vector");

    var mixed_length: u32 = 0;
    const mixed_vector = Bun__JSArray__getContiguousVector(constructed, &mixed_length) orelse
        fail("private mixed contiguous JSArray vector missing");
    if (mixed_length != constructed_items.len or
        mixed_vector[0] != .true or mixed_vector[1] != EncodedValue.fromInt32(-7) or
        !JSC__JSValue__isStrictEqual(mixed_vector[2], encoded_object, context) or
        !JSC__JSValue__isStrictEqual(mixed_vector[3], sibling_item, context) or
        !Bun__JSArray__contiguousVectorIsStillValid(constructed, mixed_vector, mixed_length))
        fail("private mixed/sibling contiguous JSArray vector mismatch");
    const undefined_array = evaluate(context, "[undefined]");
    var undefined_length: u32 = 0;
    const undefined_vector = Bun__JSArray__getContiguousVector(undefined_array, &undefined_length) orelse
        fail("private undefined contiguous JSArray vector missing");
    if (undefined_length != 1 or undefined_vector[0] != .undefined)
        fail("private contiguous JSArray present-undefined mismatch");

    for ([_]EncodedValue{
        .undefined,
        encoded_object,
        evaluate(context, "new Uint8Array([1, 2])"),
        evaluate(context, "[]"),
        evaluate(context, "[1.5, 2.5]"),
        evaluate(context, "[1, , 3]"),
        evaluate(context, "(() => { const a = [1]; Object.defineProperty(a, '0', { get() { return 9; } }); return a; })()"),
    }) |invalid_contiguous| {
        var untouched_length: u32 = 0xa5a5_a5a5;
        if (Bun__JSArray__getContiguousVector(invalid_contiguous, &untouched_length) != null or
            untouched_length != 0xa5a5_a5a5)
            fail("private invalid contiguous JSArray changed output length");
    }

    var pending_contiguous_length: u32 = 0;
    JSC__VM__throwError(vm, context, EncodedValue.fromInt32(2551));
    const pending_contiguous = Bun__JSArray__getContiguousVector(constructed, &pending_contiguous_length) orelse
        fail("private contiguous JSArray observed pending exception");
    if (!Bun__JSArray__contiguousVectorIsStillValid(constructed, pending_contiguous, pending_contiguous_length))
        fail("private contiguous JSArray validation observed pending exception");
    const contiguous_exception = JSGlobalObject__tryTakeException(context);
    if (JSC__Exception__asJSValue(contiguous_exception.cellPointer()) != EncodedValue.fromInt32(2551) or
        Bun__JSArray__getContiguousVector(constructed, null) != null)
        fail("private contiguous JSArray replaced pending exception");

    var polluted_length: u32 = 0x1234_5678;
    _ = evaluate(context, "Object.defineProperty(Array.prototype, '9', { get() { return 9; }, configurable: true })");
    if (Bun__JSArray__getContiguousVector(evaluate(context, "[1, 2]"), &polluted_length) != null or
        polluted_length != 0x1234_5678)
        fail("private contiguous JSArray ignored indexed prototype pollution");
    _ = evaluate(context, "delete Array.prototype[9]");

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

    promise_then_fixture = .{
        .expected_global = context,
        .expected_value = direct_value,
    };
    JSC__JSValue___then(
        resolved_value_promise,
        context,
        EncodedValue.fromInt32(2531),
        promiseThenResolve,
        promiseThenReject,
    );
    if (promise_then_fixture.fulfilled != 0 or promise_then_fixture.rejected != 0)
        fail("private Promise reaction ran inline");
    if (JSC__JSGlobalObject__drainMicrotasks(context) != 0 or
        promise_then_fixture.fulfilled != 1 or
        promise_then_fixture.rejected != 0 or
        promise_then_fixture.contexts[0] != EncodedValue.fromInt32(2531))
        fail("private fulfilled Promise reaction mismatch");

    promise_then_fixture = .{
        .expected_global = sibling_context,
        .expected_value = direct_value,
    };
    JSC__JSValue___then(
        rejected_value_promise,
        sibling_context,
        EncodedValue.fromInt32(2532),
        promiseThenResolve,
        promiseThenReject,
    );
    if (JSC__JSGlobalObject__drainMicrotasks(sibling_context) != 0 or
        promise_then_fixture.fulfilled != 0 or
        promise_then_fixture.rejected != 1 or
        promise_then_fixture.contexts[0] != EncodedValue.fromInt32(2532))
        fail("private rejected sibling Promise reaction mismatch");

    const pending_then = JSC__JSValue__createInternalPromise(context);
    const retained_then_context = evaluate(context, "globalThis.__private_then_context_253 = { retained: true }; __private_then_context_253");
    promise_then_fixture = .{
        .expected_global = context,
        .expected_value = direct_value,
    };
    JSC__JSValue___then(pending_then, context, retained_then_context, promiseThenResolve, promiseThenReject);
    _ = JSC__VM__runGC(vm, true);
    var settle_then_state = PromiseCallbackState{ .value = direct_value };
    JSC__AnyPromise__wrap(context, pending_then, &settle_then_state, promiseCallback);
    if (promise_then_fixture.fulfilled != 0 or
        JSC__JSGlobalObject__drainMicrotasks(context) != 0 or
        promise_then_fixture.fulfilled != 1 or
        !JSC__JSValue__isStrictEqual(promise_then_fixture.contexts[0], retained_then_context, context))
        fail("private pending Promise reaction rooting mismatch");

    promise_then_fixture = .{
        .expected_global = context,
        .expected_value = direct_value,
        .reenter = true,
        .reentry_promise = resolved_value_promise,
        .reentry_context = EncodedValue.fromInt32(2534),
    };
    JSC__JSValue___then(resolved_value_promise, context, EncodedValue.fromInt32(2533), promiseThenResolve, promiseThenReject);
    if (JSC__JSGlobalObject__drainMicrotasks(context) != 0 or
        promise_then_fixture.fulfilled != 2 or
        promise_then_fixture.rejected != 0 or
        promise_then_fixture.contexts[0] != EncodedValue.fromInt32(2533) or
        promise_then_fixture.contexts[1] != EncodedValue.fromInt32(2534))
        fail("private Promise reaction reentry/FIFO mismatch");

    promise_then_fixture = .{
        .expected_global = context,
        .expected_value = direct_value,
    };
    JSC__JSValue___then(resolved_value_promise, context, EncodedValue.fromInt32(2536), promiseThenThrow, promiseThenReject);
    JSC__JSValue___then(resolved_value_promise, context, EncodedValue.fromInt32(2537), promiseThenResolve, promiseThenReject);
    if (JSC__JSGlobalObject__drainMicrotasks(context) != 0 or
        !JSGlobalObject__hasException(context) or
        promise_then_fixture.fulfilled != 1 or
        promise_then_fixture.contexts[0] != EncodedValue.fromInt32(2536))
        fail("private Promise throwing reaction boundary mismatch");
    const promise_then_exception = JSGlobalObject__tryTakeException(context);
    if (JSC__Exception__asJSValue(promise_then_exception.cellPointer()) != EncodedValue.fromInt32(2538) or
        JSC__JSGlobalObject__drainMicrotasks(context) != 0 or
        promise_then_fixture.fulfilled != 2 or
        promise_then_fixture.contexts[1] != EncodedValue.fromInt32(2537))
        fail("private Promise post-throw FIFO preservation mismatch");

    promise_then_fixture = .{
        .expected_global = context,
        .expected_value = direct_value,
    };
    JSC__JSValue___then(encoded_object, context, .true, promiseThenResolve, promiseThenReject);
    JSC__JSValue___then(.undefined, context, .true, promiseThenResolve, promiseThenReject);
    JSC__JSValue___then(resolved_value_promise, context, .true, null, promiseThenReject);
    JSC__JSValue___then(resolved_value_promise, context, .true, promiseThenResolve, null);
    if (JSC__JSGlobalObject__drainMicrotasks(context) != 0 or
        promise_then_fixture.fulfilled != 0 or promise_then_fixture.rejected != 0 or
        JSGlobalObject__hasException(context))
        fail("private Promise reaction invalid-input no-op mismatch");

    JSC__VM__throwError(vm, context, EncodedValue.fromInt32(2535));
    JSC__JSValue___then(resolved_value_promise, context, .true, promiseThenResolve, promiseThenReject);
    const preserved_then_exception = JSGlobalObject__tryTakeException(context);
    if (JSC__Exception__asJSValue(preserved_then_exception.cellPointer()) != EncodedValue.fromInt32(2535) or
        JSC__JSGlobalObject__drainMicrotasks(context) != 0 or
        promise_then_fixture.fulfilled != 0)
        fail("private Promise reaction replaced a pending exception");

    const async_stack_gate = evaluate(context,
        \\globalThis.__private_async_stack_gate_254 = new Promise(resolve => { globalThis.__private_async_stack_resolve_254 = resolve; });
        \\async function privateAsyncStackInner254() { await __private_async_stack_gate_254; }
        \\async function privateAsyncStackOuter254() { await privateAsyncStackInner254(); }
        \\globalThis.__private_async_stack_outer_254 = privateAsyncStackOuter254();
        \\globalThis.__private_async_stack_error_254 = new Error('existing-254');
        \\globalThis.__private_async_stack_before_254 = __private_async_stack_error_254.stack;
        \\__private_async_stack_gate_254;
    );
    const async_stack_error = evaluate(context, "__private_async_stack_error_254");
    const async_stack_gate_cell = JSC__JSValue__asPromise(async_stack_gate) orelse fail("private async stack Promise downcast failed");
    Bun__attachAsyncStackFromPromise(context, async_stack_error, async_stack_gate_cell);
    Bun__attachAsyncStackFromPromise(context, async_stack_error, null);
    Bun__attachAsyncStackFromPromise(context, .undefined, async_stack_gate_cell);
    if (!JSC__JSValue__toBoolean(evaluate(context, "__private_async_stack_error_254.stack === __private_async_stack_before_254")))
        fail("private async stack overwrote existing/materialized Error stack");
    JSC__VM__throwError(vm, context, EncodedValue.fromInt32(254));
    Bun__attachAsyncStackFromPromise(context, async_stack_error, async_stack_gate_cell);
    const preserved_async_stack_exception = JSGlobalObject__tryTakeException(context);
    if (JSC__Exception__asJSValue(preserved_async_stack_exception.cellPointer()) != EncodedValue.fromInt32(254))
        fail("private async stack replaced a pending exception");

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

    // VM execution-control exports (#302): API lock + execution time limit.
    if (JSC__VM__hasExecutionTimeLimit(vm) or JSC__VM__hasExecutionTimeLimit(null))
        fail("private execution time limit initial state mismatch");
    JSC__VM__setExecutionTimeLimit(vm, 60.0);
    if (!JSC__VM__hasExecutionTimeLimit(vm) or !JSC__VM__hasExecutionTimeLimit(sibling_vm) or
        JSC__VM__hasExecutionTimeLimit(foreign_vm))
        fail("private execution time limit arming/sharing mismatch");
    JSC__VM__clearExecutionTimeLimit(vm);
    if (JSC__VM__hasExecutionTimeLimit(vm))
        fail("private execution time limit clear mismatch");
    JSC__VM__setExecutionTimeLimit(vm, std.math.inf(f64));
    if (JSC__VM__hasExecutionTimeLimit(vm))
        fail("private execution time limit noTimeLimit mapping mismatch");
    JSC__VM__setExecutionTimeLimit(null, 1.0);
    JSC__VM__clearExecutionTimeLimit(null);

    // The host watchdog really interrupts running evaluation: a 30ms limit
    // aborts an unbounded loop, and `termination_requested` attributes the
    // abort to the watchdog rather than the interpreter step budget.
    const watchdog_context = JSGlobalContextCreate(null) orelse fail("watchdog context creation failed");
    const watchdog_vm = JSC__JSGlobalObject__vm(watchdog_context) orelse fail("watchdog VM lookup failed");
    JSC__VM__setExecutionTimeLimit(watchdog_vm, 0.03);
    if (!JSC__VM__hasExecutionTimeLimit(watchdog_vm))
        fail("private watchdog arming mismatch");
    {
        const loop_script = JSStringCreateWithUTF8CString("while (true) {}") orelse fail("loop script creation failed");
        defer JSStringRelease(loop_script);
        var loop_exception: JSValueRef = null;
        const loop_result = JSEvaluateScript(watchdog_context, loop_script, null, null, 1, &loop_exception);
        if (loop_result != null or loop_exception == null)
            fail("private watchdog did not abort unbounded evaluation");
        if (!JSC__VM__hasTerminationRequest(watchdog_vm))
            fail("private watchdog abort did not request termination");
        // JSC `Watchdog::hasTimeLimit` stays true after firing and clearing
        // the limit never clears the termination request.
        if (!JSC__VM__hasExecutionTimeLimit(watchdog_vm))
            fail("private watchdog limit did not stay armed after firing");
        JSC__VM__clearExecutionTimeLimit(watchdog_vm);
        if (JSC__VM__hasExecutionTimeLimit(watchdog_vm) or !JSC__VM__hasTerminationRequest(watchdog_vm))
            fail("private watchdog clear semantics mismatch");
        JSC__VM__clearHasTerminationRequest(watchdog_vm);
    }
    JSGlobalContextRelease(watchdog_context);

    // VM trap notifications (#304): NeedWatchdogCheck re-checks the armed
    // deadline on the executing thread at the next step checkpoint;
    // NeedDebuggerBreak is inert without an attached debugger. Both tolerate
    // a null VM.
    JSC__VM__notifyNeedWatchdogCheck(null);
    JSC__VM__notifyNeedDebuggerBreak(null);
    JSC__VM__notifyNeedDebuggerBreak(vm);
    JSC__VM__notifyNeedDebuggerBreak(sibling_vm);
    JSC__VM__notifyNeedDebuggerBreak(foreign_vm);

    // The watchdog trap consumed with no armed limit (cleared above, then
    // mapped to noTimeLimit) must not disturb bounded evaluation, and the
    // debugger-break trap stays inert while no realm has a debugger session.
    JSC__VM__notifyNeedWatchdogCheck(vm);
    if (!JSC__JSValue__toBoolean(evaluate(context, "let ts = 0; for (let ti = 0; ti < 5000; ti += 1) ts += ti; ts === 12497500")))
        fail("private watchdog trap disturbed disarmed evaluation");

    // Consumed with a future deadline, the trap re-checks and keeps running.
    JSC__VM__setExecutionTimeLimit(vm, 60.0);
    JSC__VM__notifyNeedWatchdogCheck(vm);
    if (!JSC__JSValue__toBoolean(evaluate(context, "let tf = 0; for (let tj = 0; tj < 5000; tj += 1) tf += tj; tf === 12497500")))
        fail("private watchdog trap fired before the armed deadline");
    JSC__VM__clearExecutionTimeLimit(vm);

    // Consumed with an elapsed deadline, the trap terminates unbounded
    // evaluation; the host watchdog thread is the redundant second path to
    // the same termination, exactly like JSC's trap bit and Watchdog timer.
    const trap_context = JSGlobalContextCreate(null) orelse fail("trap context creation failed");
    const trap_vm = JSC__JSGlobalObject__vm(trap_context) orelse fail("trap VM lookup failed");
    JSC__VM__setExecutionTimeLimit(trap_vm, 0.0);
    JSC__VM__notifyNeedWatchdogCheck(trap_vm);
    {
        const trap_script = JSStringCreateWithUTF8CString("while (true) {}") orelse fail("trap script creation failed");
        defer JSStringRelease(trap_script);
        var trap_exception: JSValueRef = null;
        const trap_result = JSEvaluateScript(trap_context, trap_script, null, null, 1, &trap_exception);
        if (trap_result != null or trap_exception == null)
            fail("private watchdog trap did not terminate elapsed evaluation");
        // Whichever half fired first, the host watchdog attributes the abort
        // to the time limit within its nap bound.
        var trap_spins: usize = 0;
        while (!JSC__VM__hasTerminationRequest(trap_vm) and trap_spins < 100_000_000) : (trap_spins += 1)
            std.atomic.spinLoopHint();
        if (!JSC__VM__hasTerminationRequest(trap_vm))
            fail("private watchdog trap abort was not attributed to the time limit");
        JSC__VM__clearExecutionTimeLimit(trap_vm);
        JSC__VM__clearHasTerminationRequest(trap_vm);
    }
    JSGlobalContextRelease(trap_context);

    // API lock: null-tolerant, recursive for the owner thread (JSLock
    // semantics), and real mutual exclusion against foreign threads.
    JSC__VM__getAPILock(null);
    JSC__VM__releaseAPILock(null);
    JSC__VM__holdAPILock(null, null, apiLockNullCallback);
    if (api_lock_null_callback_ran)
        fail("private API lock null VM ran callback");

    var probe: ApiLockProbe = .{ .vm = vm };
    JSC__VM__holdAPILock(vm, &probe, apiLockProbeCallback);
    if (!probe.entered.load(.acquire) or probe.received != @as(?*anyopaque, @ptrCast(&probe)))
        fail("private holdAPILock callback mismatch");

    probe.entered.store(false, .release);
    JSC__VM__getAPILock(vm);
    JSC__VM__getAPILock(vm);
    JSC__VM__holdAPILock(vm, &probe, apiLockProbeCallback);
    JSC__VM__releaseAPILock(vm);
    JSC__VM__releaseAPILock(vm);
    if (!probe.entered.load(.acquire))
        fail("private recursive API lock callback mismatch");

    var contention: ApiLockProbe = .{ .vm = vm };
    JSC__VM__getAPILock(vm);
    const lock_thread = std.Thread.spawn(.{}, apiLockProbeThread, .{&contention}) catch
        fail("API lock probe thread spawn failed");
    while (!contention.started.load(.acquire)) std.Thread.yield() catch {};
    var guard: usize = 0;
    while (guard < 100_000) : (guard += 1) {
        if (contention.entered.load(.acquire))
            fail("private API lock admitted foreign thread while held");
        std.Thread.yield() catch {};
    }
    JSC__VM__releaseAPILock(vm);
    lock_thread.join();
    if (!contention.entered.load(.acquire))
        fail("private API lock foreign thread never acquired");

    // Process-wide default time zone override (#303): WTF::setTimeZoneOverride
    // semantics consumed by the Intl/Temporal default-zone paths.
    const tz_ny_bytes = "America/New_York";
    var tz_ny = ZigString{ .tagged_ptr = @intFromPtr(tz_ny_bytes.ptr), .len = tz_ny_bytes.len };
    const tz_bad_bytes = "Not/AZone";
    var tz_bad = ZigString{ .tagged_ptr = @intFromPtr(tz_bad_bytes.ptr), .len = tz_bad_bytes.len };
    const tz_berlin_bytes = "europe/berlin";
    var tz_berlin = ZigString{ .tagged_ptr = @intFromPtr(tz_berlin_bytes.ptr), .len = tz_berlin_bytes.len };
    const tz_alias_bytes = "America/Atka";
    var tz_alias = ZigString{ .tagged_ptr = @intFromPtr(tz_alias_bytes.ptr), .len = tz_alias_bytes.len };
    var tz_empty = ZigString{ .tagged_ptr = 0, .len = 0 };
    if (!JSC__JSValue__toBoolean(evaluate(context, "new Intl.DateTimeFormat('en-US').resolvedOptions().timeZone === 'UTC'")) or
        !JSC__JSValue__toBoolean(evaluate(context, "Temporal.Now.timeZoneId() === 'UTC'")))
        fail("private time zone default baseline mismatch");
    if (JSGlobalObject__setTimeZone(null, &tz_ny) or JSGlobalObject__setTimeZone(context, null))
        fail("private setTimeZone null-boundary mismatch");
    if (JSGlobalObject__setTimeZone(context, &tz_bad))
        fail("private setTimeZone accepted unknown zone");
    if (!JSC__JSValue__toBoolean(evaluate(context, "new Intl.DateTimeFormat('en-US').resolvedOptions().timeZone === 'UTC'")))
        fail("private setTimeZone rejection disturbed state");
    if (!JSGlobalObject__setTimeZone(context, &tz_ny))
        fail("private setTimeZone rejected canonical zone");
    if (!JSC__JSValue__toBoolean(evaluate(context, "new Intl.DateTimeFormat('en-US').resolvedOptions().timeZone === 'America/New_York'")) or
        !JSC__JSValue__toBoolean(evaluate(context, "Temporal.Now.timeZoneId() === 'America/New_York'")) or
        !JSC__JSValue__toBoolean(evaluate(context, "new Intl.DateTimeFormat('en-US', { timeZone: 'Asia/Tokyo' }).resolvedOptions().timeZone === 'Asia/Tokyo'")) or
        !JSC__JSValue__toBoolean(evaluate(foreign_context, "new Intl.DateTimeFormat('en-US').resolvedOptions().timeZone === 'America/New_York'")))
        fail("private time zone override consumer mismatch");
    if (!JSGlobalObject__setTimeZone(context, &tz_berlin) or
        !JSC__JSValue__toBoolean(evaluate(context, "new Intl.DateTimeFormat('en-US').resolvedOptions().timeZone === 'Europe/Berlin'")))
        fail("private setTimeZone case normalization mismatch");
    if (!JSGlobalObject__setTimeZone(context, &tz_alias) or
        !JSC__JSValue__toBoolean(evaluate(context, "Temporal.Now.timeZoneId() === 'America/Adak'")))
        fail("private setTimeZone alias canonicalization mismatch");
    if (!JSGlobalObject__setTimeZone(context, &tz_empty) or
        !JSC__JSValue__toBoolean(evaluate(context, "new Intl.DateTimeFormat('en-US').resolvedOptions().timeZone === 'UTC'")) or
        !JSC__JSValue__toBoolean(evaluate(context, "Temporal.Now.timeZoneId() === 'UTC'")))
        fail("private setTimeZone empty reset mismatch");

    // Owned structured serialization (#323): exact returned layout, stable
    // graph identity/typed data, companion round-trip, and idempotent release.
    if (@sizeOf(SerializedScriptExternal) != 24 or @alignOf(SerializedScriptExternal) != 8 or
        @offsetOf(SerializedScriptExternal, "size") != 8 or @offsetOf(SerializedScriptExternal, "handle") != 16)
        fail("private serialized-script external layout mismatch");
    const serialized_source = evaluate(context, "globalThis.__serialized_source_323={typed:new Uint8Array([3,2,3])};" ++
        "__serialized_source_323.self=__serialized_source_323;__serialized_source_323");
    const serialized = Bun__serializeJSValue(context, serialized_source, 0);
    if (serialized.bytes == null or serialized.size == 0 or serialized.handle == null)
        fail("private structured serialization returned an empty slice");
    const deserialized = Bun__JSValue__deserialize(context, serialized.bytes.?, serialized.size);
    if (deserialized == .empty or JSGlobalObject__hasException(context))
        fail("private structured deserialization failed");
    exposeCell(context, "__serialized_restored_323", deserialized);
    if (!JSC__JSValue__toBoolean(evaluate(context, "__serialized_restored_323!==__serialized_source_323&&" ++
        "__serialized_restored_323.self===__serialized_restored_323&&" ++
        "Array.from(__serialized_restored_323.typed).join(',')==='3,2,3'")))
        fail("private structured serialization round-trip mismatch");
    Bun__SerializedScriptSlice__free(serialized.handle);
    Bun__SerializedScriptSlice__free(serialized.handle);

    std.debug.print("Home private value shims: 384/384 symbols linked; runtime matrix passed\n", .{});
}
