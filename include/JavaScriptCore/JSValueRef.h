#ifndef ZIG_JS_JAVASCRIPTCORE_JSVALUEREF_H
#define ZIG_JS_JAVASCRIPTCORE_JSVALUEREF_H

#include <JavaScriptCore/JSBase.h>

typedef enum {
    kJSTypeUndefined,
    kJSTypeNull,
    kJSTypeBoolean,
    kJSTypeNumber,
    kJSTypeString,
    kJSTypeObject,
    kJSTypeSymbol,
    kJSTypeBigInt
} JSType;

typedef enum {
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
    kJSTypedArrayTypeBigUint64Array
} JSTypedArrayType;

typedef enum {
    kJSRelationConditionUndefined,
    kJSRelationConditionEqual,
    kJSRelationConditionGreaterThan,
    kJSRelationConditionLessThan
} JSRelationCondition;

#ifdef __cplusplus
extern "C" {
#endif

JS_EXPORT JSType JSValueGetType(JSContextRef ctx, JSValueRef value);
JS_EXPORT bool JSValueIsUndefined(JSContextRef ctx, JSValueRef value);
JS_EXPORT bool JSValueIsNull(JSContextRef ctx, JSValueRef value);
JS_EXPORT bool JSValueIsBoolean(JSContextRef ctx, JSValueRef value);
JS_EXPORT bool JSValueIsNumber(JSContextRef ctx, JSValueRef value);
JS_EXPORT bool JSValueIsString(JSContextRef ctx, JSValueRef value);
JS_EXPORT bool JSValueIsSymbol(JSContextRef ctx, JSValueRef value);
JS_EXPORT bool JSValueIsBigInt(JSContextRef ctx, JSValueRef value);
JS_EXPORT bool JSValueIsObject(JSContextRef ctx, JSValueRef value);
JS_EXPORT bool JSValueIsObjectOfClass(JSContextRef ctx, JSValueRef value, JSClassRef jsClass);
JS_EXPORT bool JSValueIsArray(JSContextRef ctx, JSValueRef value);
JS_EXPORT bool JSValueIsDate(JSContextRef ctx, JSValueRef value);
JS_EXPORT JSTypedArrayType JSValueGetTypedArrayType(JSContextRef ctx, JSValueRef value, JSValueRef* exception);
JS_EXPORT bool JSValueIsEqual(JSContextRef ctx, JSValueRef a, JSValueRef b, JSValueRef* exception);
JS_EXPORT bool JSValueIsStrictEqual(JSContextRef ctx, JSValueRef a, JSValueRef b);
JS_EXPORT bool JSValueIsInstanceOfConstructor(JSContextRef ctx, JSValueRef value, JSObjectRef constructor, JSValueRef* exception);
JS_EXPORT JSRelationCondition JSValueCompare(JSContextRef ctx, JSValueRef left, JSValueRef right, JSValueRef* exception);
JS_EXPORT JSRelationCondition JSValueCompareInt64(JSContextRef ctx, JSValueRef left, int64_t right, JSValueRef* exception);
JS_EXPORT JSRelationCondition JSValueCompareUInt64(JSContextRef ctx, JSValueRef left, uint64_t right, JSValueRef* exception);
JS_EXPORT JSRelationCondition JSValueCompareDouble(JSContextRef ctx, JSValueRef left, double right, JSValueRef* exception);
JS_EXPORT JSValueRef JSValueMakeUndefined(JSContextRef ctx);
JS_EXPORT JSValueRef JSValueMakeNull(JSContextRef ctx);
JS_EXPORT JSValueRef JSValueMakeBoolean(JSContextRef ctx, bool boolean);
JS_EXPORT JSValueRef JSValueMakeNumber(JSContextRef ctx, double number);
JS_EXPORT JSValueRef JSValueMakeString(JSContextRef ctx, JSStringRef string);
JS_EXPORT JSValueRef JSValueMakeSymbol(JSContextRef ctx, JSStringRef description);
JS_EXPORT JSValueRef JSBigIntCreateWithDouble(JSContextRef ctx, double value, JSValueRef* exception);
JS_EXPORT JSValueRef JSBigIntCreateWithInt64(JSContextRef ctx, int64_t integer, JSValueRef* exception);
JS_EXPORT JSValueRef JSBigIntCreateWithUInt64(JSContextRef ctx, uint64_t integer, JSValueRef* exception);
JS_EXPORT JSValueRef JSBigIntCreateWithString(JSContextRef ctx, JSStringRef string, JSValueRef* exception);
JS_EXPORT JSValueRef JSValueMakeFromJSONString(JSContextRef ctx, JSStringRef string);
JS_EXPORT JSStringRef JSValueCreateJSONString(JSContextRef ctx, JSValueRef value, unsigned indent, JSValueRef* exception);
JS_EXPORT bool JSValueToBoolean(JSContextRef ctx, JSValueRef value);
JS_EXPORT double JSValueToNumber(JSContextRef ctx, JSValueRef value, JSValueRef* exception);
JS_EXPORT int32_t JSValueToInt32(JSContextRef ctx, JSValueRef value, JSValueRef* exception);
JS_EXPORT uint32_t JSValueToUInt32(JSContextRef ctx, JSValueRef value, JSValueRef* exception);
JS_EXPORT int64_t JSValueToInt64(JSContextRef ctx, JSValueRef value, JSValueRef* exception);
JS_EXPORT uint64_t JSValueToUInt64(JSContextRef ctx, JSValueRef value, JSValueRef* exception);
JS_EXPORT JSStringRef JSValueToStringCopy(JSContextRef ctx, JSValueRef value, JSValueRef* exception);
JS_EXPORT JSObjectRef JSValueToObject(JSContextRef ctx, JSValueRef value, JSValueRef* exception);
JS_EXPORT void JSValueProtect(JSContextRef ctx, JSValueRef value);
JS_EXPORT void JSValueUnprotect(JSContextRef ctx, JSValueRef value);

#ifdef __cplusplus
}
#endif

#endif
