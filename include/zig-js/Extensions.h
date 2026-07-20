#ifndef ZIG_JS_EXTENSIONS_H
#define ZIG_JS_EXTENSIONS_H

#include <JavaScriptCore/JavaScript.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Observable variants of JSC's void protection API. */
JS_EXPORT bool ZJSValueProtect(JSContextRef ctx, JSValueRef value);
JS_EXPORT bool ZJSValueUnprotect(JSContextRef ctx, JSValueRef value);

/* Standalone precise-GC context and explicit quiescent compaction. */
JS_EXPORT JSGlobalContextRef ZJSGlobalContextCreateGarbageCollected(bool enableJIT);
typedef enum ZJSGCCompactionStatus {
    kZJSGCCompactionUnsupported = 0,
    kZJSGCCompactionNoCandidates = 1,
    kZJSGCCompactionOutOfMemory = 2,
    kZJSGCCompactionCompacted = 3,
} ZJSGCCompactionStatus;
JS_EXPORT ZJSGCCompactionStatus ZJSContextCompactGarbage(
    JSContextRef ctx, size_t* movedCells, size_t* movedBytes);

/* Monotonic explicit-collection epoch shared by every realm in a context group. */
JS_EXPORT uint64_t ZJSContextGetCollectionEpoch(JSContextRef ctx);
JS_EXPORT bool ZJSValueIsReachable(JSContextRef ctx, JSValueRef value);

typedef void (*ZJSInspectorMessageCallback)(
    const char* message, size_t messageLength, void* userData);

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

typedef struct OpaqueZJSWorkerInspectorSession* ZJSWorkerInspectorSessionRef;

typedef enum ZJSWorkerInspectorPumpResult {
    kZJSWorkerInspectorPumpMessage = 0,
    kZJSWorkerInspectorPumpTimeout = 1,
    kZJSWorkerInspectorPumpClosed = 2,
} ZJSWorkerInspectorPumpResult;

JS_EXPORT ZJSWorkerInspectorSessionRef ZJSWorkerInspectorSessionCreate(
    JSWorkerRef worker, ZJSInspectorMessageCallback callback, void* userData);
JS_EXPORT bool ZJSWorkerInspectorSessionDispatch(
    ZJSWorkerInspectorSessionRef session,
    const char* message, size_t messageLength);
JS_EXPORT ZJSWorkerInspectorPumpResult ZJSWorkerInspectorSessionPump(
    ZJSWorkerInspectorSessionRef session, uint64_t timeoutMs);
JS_EXPORT void ZJSWorkerInspectorSessionRelease(
    ZJSWorkerInspectorSessionRef session);

/*
 * In-process inspector transport. The embedder owns authentication and message
 * transport; zig-js synchronously emits versioned JSON protocol responses and
 * events through the callback.
 */
typedef struct OpaqueZJSInspectorSession* ZJSInspectorSessionRef;

JS_EXPORT ZJSInspectorSessionRef ZJSInspectorSessionCreate(
    JSGlobalContextRef ctx, ZJSInspectorMessageCallback callback, void* userData);
JS_EXPORT void ZJSInspectorSessionRelease(ZJSInspectorSessionRef session);
JS_EXPORT bool ZJSInspectorSessionDispatch(
    ZJSInspectorSessionRef session, const char* message, size_t messageLength);

#ifdef __cplusplus
}
#endif

#endif
