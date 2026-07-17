#ifndef ZIG_JS_EXTENSIONS_H
#define ZIG_JS_EXTENSIONS_H

#include <JavaScriptCore/JavaScript.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Observable variants of JSC's void protection API. */
JS_EXPORT bool ZJSValueProtect(JSContextRef ctx, JSValueRef value);
JS_EXPORT bool ZJSValueUnprotect(JSContextRef ctx, JSValueRef value);

/*
 * In-process inspector transport. The embedder owns authentication and message
 * transport; zig-js synchronously emits versioned JSON protocol responses and
 * events through the callback.
 */
typedef struct OpaqueZJSInspectorSession* ZJSInspectorSessionRef;
typedef void (*ZJSInspectorMessageCallback)(
    const char* message, size_t messageLength, void* userData);

JS_EXPORT ZJSInspectorSessionRef ZJSInspectorSessionCreate(
    JSGlobalContextRef ctx, ZJSInspectorMessageCallback callback, void* userData);
JS_EXPORT void ZJSInspectorSessionRelease(ZJSInspectorSessionRef session);
JS_EXPORT bool ZJSInspectorSessionDispatch(
    ZJSInspectorSessionRef session, const char* message, size_t messageLength);

#ifdef __cplusplus
}
#endif

#endif
