#ifndef ZIG_JS_EXTENSIONS_H
#define ZIG_JS_EXTENSIONS_H

#include <JavaScriptCore/JavaScript.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Observable variants of JSC's void protection API. */
JS_EXPORT bool ZJSValueProtect(JSContextRef ctx, JSValueRef value);
JS_EXPORT bool ZJSValueUnprotect(JSContextRef ctx, JSValueRef value);

/* Standalone precise-GC context and explicit quiescent compaction. The current
 * pointer-free baseline JIT may remain enabled; live native frames fail closed. */
JS_EXPORT JSGlobalContextRef ZJSGlobalContextCreateGarbageCollected(bool enableJIT);
/* Schedule only; never moves inside the caller's native frame. */
JS_EXPORT bool ZJSContextRequestGarbageCompaction(JSContextRef ctx);
typedef enum ZJSGCCompactionStatus {
    kZJSGCCompactionUnsupported = 0,
    kZJSGCCompactionNoCandidates = 1,
    kZJSGCCompactionOutOfMemory = 2,
    kZJSGCCompactionCompacted = 3,
} ZJSGCCompactionStatus;
JS_EXPORT ZJSGCCompactionStatus ZJSContextCompactGarbage(
    JSContextRef ctx, size_t* movedCells, size_t* movedBytes);

/* Sample the JavaScript a context's group runs (0: every 1 ms) and stop with
 * the samples as Chrome DevTools .cpuprofile JSON, null if none was running.
 * Release the string with JSStringRelease. Statement-boundary sampling: time in
 * one long native call is counted at the statement after it. */
JS_EXPORT bool ZJSContextStartCPUProfile(JSContextRef ctx, uint32_t intervalMicroseconds);
JS_EXPORT JSStringRef ZJSContextStopCPUProfile(JSContextRef ctx);

/* Keep the parsed trees of large scripts (32 KB and up) this context evaluates
 * in the directory `path` (created when missing; NULL turns it off), so the next
 * evaluation of the same source, here or in a later process, skips parsing.
 * Entries are keyed on the source's SHA-256 and the running executable; stale or
 * damaged entries are misses and get rewritten. Keep `path` private to the app. */
JS_EXPORT bool ZJSContextSetScriptCacheDirectory(JSContextRef ctx, const char* path);

/* JSEvaluateScript for a script held as `length` bytes of UTF-8, without a
 * JSString (which keeps UTF-8 and UTF-16 copies of a large bundle). */
JS_EXPORT JSValueRef ZJSEvaluateScriptUTF8(JSContextRef ctx, const char* utf8, size_t length,
    JSObjectRef thisObject, JSStringRef sourceURL, int startingLineNumber, JSValueRef* exception);

/* Consume one still-unhandled rejection after the host's microtask checkpoint.
 * Returns false with null outputs when the queue is empty, or sets exception on
 * failure. Both output pointers must be non-null and distinct. A true result can
 * carry JavaScript undefined as its reason. Returned values have ordinary C-API
 * handle lifetime; protect them before executing more JS or collecting garbage.
 * Does not run jobs or dispatch events. Rejections handled before consumption
 * are omitted; a rejection is returned at most once, in notification order. */
JS_EXPORT bool ZJSContextTakeUnhandledRejection(JSContextRef ctx,
    JSValueRef* reason, JSValueRef* rejectedPromise, JSValueRef* exception);

/* Monotonic explicit-collection epoch shared by every realm in a context group. */
JS_EXPORT uint64_t ZJSContextGetCollectionEpoch(JSContextRef ctx);
JS_EXPORT bool ZJSValueIsReachable(JSContextRef ctx, JSValueRef value);

/* Lifetime-safe owner for the pinned Home/Bun
 * JSC__Wasm__StreamingCompiler__addBytes bridge. Finalize copies into caller
 * storage and may be repeated; release and context teardown retire the token. */
typedef struct OpaqueZJSWasmStreamingCompiler* ZJSWasmStreamingCompilerRef;
typedef enum ZJSWasmStreamingCompilerStatus {
    kZJSWasmStreamingCompilerOK = 0,
    kZJSWasmStreamingCompilerInvalidHandle = 1,
    kZJSWasmStreamingCompilerForeignVM = 2,
    kZJSWasmStreamingCompilerInvalidBytes = 3,
    kZJSWasmStreamingCompilerOutOfMemory = 4,
    kZJSWasmStreamingCompilerOverflow = 5,
    kZJSWasmStreamingCompilerBufferTooSmall = 6,
    kZJSWasmStreamingCompilerInvalidOutput = 7,
} ZJSWasmStreamingCompilerStatus;
JS_EXPORT ZJSWasmStreamingCompilerRef ZJSWasmStreamingCompilerCreate(
    JSContextRef ctx);
JS_EXPORT ZJSWasmStreamingCompilerStatus ZJSWasmStreamingCompilerFinalize(
    JSContextRef ctx, ZJSWasmStreamingCompilerRef compiler,
    uint8_t* output, size_t outputCapacity, size_t* outputLength);
JS_EXPORT ZJSWasmStreamingCompilerStatus ZJSWasmStreamingCompilerRelease(
    JSContextRef ctx, ZJSWasmStreamingCompilerRef compiler);

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
