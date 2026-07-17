#ifndef ZIG_JS_JAVASCRIPTCORE_JSBASE_H
#define ZIG_JS_JAVASCRIPTCORE_JSBASE_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#if defined(__APPLE__)
#  include <AvailabilityMacros.h>
#  include <TargetConditionals.h>
#endif

/* Objective-C bridge declarations are available only on Apple targets with
 * the modern Clang runtime. C, C++, and non-Apple consumers remain independent
 * of Foundation and the Objective-C ABI. */
#if !defined(JSC_OBJC_API_ENABLED)
#  if defined(__OBJC__) && defined(__clang__) && defined(__APPLE__) && \
      (defined(__MAC_OS_X_VERSION_MIN_REQUIRED) || \
       (defined(TARGET_OS_IPHONE) && TARGET_OS_IPHONE))
#    define JSC_OBJC_API_ENABLED 1
#  else
#    define JSC_OBJC_API_ENABLED 0
#  endif
#endif

#if JSC_OBJC_API_ENABLED
#  define JSC_NULL_UNSPECIFIED _Null_unspecified
#  define JSC_NULLABLE _Nullable
#  define JSC_NONNULL _Nonnull
#else
#  define JSC_NULL_UNSPECIFIED
#  define JSC_NULLABLE
#  define JSC_NONNULL
#endif

#if defined(_WIN32) && defined(ZIG_JS_SHARED)
#  if defined(ZIG_JS_BUILDING)
#    define JS_EXPORT __declspec(dllexport)
#  else
#    define JS_EXPORT __declspec(dllimport)
#  endif
#elif defined(__GNUC__)
#  define JS_EXPORT __attribute__((visibility("default")))
#else
#  define JS_EXPORT
#endif

typedef const struct OpaqueJSContextGroup* JSContextGroupRef;
typedef const struct OpaqueJSContext* JSContextRef;
typedef struct OpaqueJSContext* JSGlobalContextRef;
typedef struct OpaqueJSString* JSStringRef;
typedef struct OpaqueJSClass* JSClassRef;
typedef struct OpaqueJSPropertyNameArray* JSPropertyNameArrayRef;
typedef struct OpaqueJSPropertyNameAccumulator* JSPropertyNameAccumulatorRef;
typedef const struct OpaqueJSValue* JSValueRef;
typedef struct OpaqueJSValue* JSObjectRef;
typedef void (*JSTypedArrayBytesDeallocator)(void* bytes, void* deallocatorContext);

#ifdef __cplusplus
extern "C" {
#endif

JS_EXPORT JSValueRef JSEvaluateScript(JSContextRef ctx, JSStringRef script, JSObjectRef thisObject, JSStringRef sourceURL, int startingLineNumber, JSValueRef* exception);
JS_EXPORT bool JSCheckScriptSyntax(JSContextRef ctx, JSStringRef script, JSStringRef sourceURL, int startingLineNumber, JSValueRef* exception);
JS_EXPORT void JSGarbageCollect(JSContextRef ctx);

#ifdef __cplusplus
}
#endif

#endif
