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
 * Isolated worker runtimes. Worker handles are affine to the thread that
 * creates them; values cross the boundary through structured clone only.
 */
typedef struct OpaqueJSWorker* JSWorkerRef;

JS_EXPORT JSWorkerRef JSWorkerCreate(JSStringRef source);
JS_EXPORT JSWorkerRef JSWorkerCreateWithLimits(
    JSStringRef source, size_t maxMessageBytes, size_t maxQueuedBytes,
    size_t maxQueuedMessages);
JS_EXPORT bool JSWorkerPostMessage(
    JSWorkerRef worker, JSContextRef ctx, JSValueRef value,
    JSValueRef* exception);
JS_EXPORT JSValueRef JSWorkerReceive(
    JSWorkerRef worker, JSContextRef ctx, uint64_t timeoutMs,
    JSValueRef* exception);
JS_EXPORT void JSWorkerTerminate(JSWorkerRef worker);
JS_EXPORT void JSWorkerRelease(JSWorkerRef worker);

typedef enum ZJSInspectorTargetKind {
    kZJSInspectorTargetKindScript = 0,
    kZJSInspectorTargetKindModule = 1,
} ZJSInspectorTargetKind;

typedef enum ZJSInspectorTargetState {
    kZJSInspectorTargetStateStarting = 0,
    kZJSInspectorTargetStateRunning = 1,
    kZJSInspectorTargetStateClosing = 2,
    kZJSInspectorTargetStateClosed = 3,
} ZJSInspectorTargetState;

typedef struct ZJSInspectorTargetInfo {
    uint64_t id;
    ZJSInspectorTargetKind kind;
    ZJSInspectorTargetState state;
} ZJSInspectorTargetInfo;

JS_EXPORT bool ZJSWorkerGetInspectorTargetInfo(
    JSWorkerRef worker, ZJSInspectorTargetInfo* info);

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
