---
title: zig-js C API subset
description: Embed zig-js through its implemented JavaScriptCore-shaped C API subset.
---

# zig-js C API subset

zig-js exports an implemented JavaScriptCore-shaped C API subset from `c_api.zig`. `zig build` installs the static library under `zig-out/lib` and compatible headers under `zig-out/include/JavaScriptCore`. Hosts that only use the completed subset can link `libzig-js.a` in place of the system `JavaScriptCore.framework` and keep those documented calls unchanged.

The machine-readable [macOS 27.0 inventory](c-api/jsc-public-api-macos-27.0.json)
is the completion authority for the full checked-in declaration surface. A
`pending` declaration is available so hosts can compile against one header
layout, but it must not be called until its linked implementation issue closes.
Use `zig build c-api-audit` for the fast drift gate or `zig build test-c-api` to
compile, link, and execute both C and C++ embedding fixtures.
`zig build c-api-jsc-diff` is the macOS-only semantic gate for completed value
APIs against the hash-pinned system JavaScriptCore headers and framework.

The project is still pre-stabilization. Compatibility-shaped entry points are an embedder convenience, not a promise to preserve inert arguments or incomplete JavaScriptCore behavior. When a compatibility shim conflicts with clear zig-js semantics, the shim should either grow real behavior or be redesigned before the API is declared stable.

## Minimal embedding

```c
#include <JavaScriptCore/JavaScript.h>

int main(void) {
  JSGlobalContextRef ctx = JSGlobalContextCreate(NULL);

  JSStringRef script = JSStringCreateWithUTF8CString("40 + 2");
  JSValueRef result = JSEvaluateScript(ctx, script, NULL, NULL, 0, NULL);

  double n = JSValueToNumber(ctx, result, NULL);   // 42.0

  JSStringRelease(script);
  JSGlobalContextRelease(ctx);
  return 0;
}
```

Link against `libzig-js.a` instead of JavaScriptCore when your host only uses the implemented surface below.

## Implemented surface

::: code-group
```c [Context]
JSGlobalContextRef JSGlobalContextCreate(JSClassRef);
JSGlobalContextRef ZJSGlobalContextCreateThreaded(bool gil);
JSGlobalContextRef JSGlobalContextRetain(JSGlobalContextRef);
void               JSGlobalContextRelease(JSGlobalContextRef);
JSObjectRef        JSContextGetGlobalObject(JSContextRef);
JSGlobalContextRef JSContextGetGlobalContext(JSContextRef);
JSStringRef        JSGlobalContextCopyName(JSGlobalContextRef);
void               JSGlobalContextSetName(JSGlobalContextRef, JSStringRef);
bool               JSCheckScriptSyntax(JSContextRef, JSStringRef source,
                                       JSStringRef sourceURL,
                                       int startingLineNumber, JSValueRef* exception);
JSValueRef         JSEvaluateScript(JSContextRef, JSStringRef source,
                                    JSObjectRef thisObject, JSStringRef sourceURL,
                                    int startingLineNumber, JSValueRef* exception);
void               JSGarbageCollect(JSContextRef);
```

```c [Values]
JSType      JSValueGetType(JSContextRef, JSValueRef);
bool        JSValueIsUndefined(JSContextRef, JSValueRef);
bool        JSValueIsNull(JSContextRef, JSValueRef);
bool        JSValueIsBoolean(JSContextRef, JSValueRef);
bool        JSValueIsNumber(JSContextRef, JSValueRef);
bool        JSValueIsString(JSContextRef, JSValueRef);
bool        JSValueIsSymbol(JSContextRef, JSValueRef);
bool        JSValueIsBigInt(JSContextRef, JSValueRef);
bool        JSValueIsObject(JSContextRef, JSValueRef);
bool        JSValueIsObjectOfClass(JSContextRef, JSValueRef, JSClassRef);
bool        JSValueIsArray(JSContextRef, JSValueRef);
bool        JSValueIsDate(JSContextRef, JSValueRef);
JSTypedArrayType JSValueGetTypedArrayType(JSContextRef, JSValueRef, JSValueRef* exception);
bool        JSValueIsEqual(JSContextRef, JSValueRef, JSValueRef, JSValueRef* exception);
bool        JSValueIsStrictEqual(JSContextRef, JSValueRef, JSValueRef);
bool        JSValueIsInstanceOfConstructor(JSContextRef, JSValueRef,
                                           JSObjectRef constructor,
                                           JSValueRef* exception);
JSRelationCondition JSValueCompare(JSContextRef, JSValueRef, JSValueRef,
                                   JSValueRef* exception);
JSRelationCondition JSValueCompareInt64(JSContextRef, JSValueRef, int64_t,
                                        JSValueRef* exception);
JSRelationCondition JSValueCompareUInt64(JSContextRef, JSValueRef, uint64_t,
                                         JSValueRef* exception);
JSRelationCondition JSValueCompareDouble(JSContextRef, JSValueRef, double,
                                         JSValueRef* exception);
JSValueRef  JSValueMakeUndefined(JSContextRef);
JSValueRef  JSValueMakeNull(JSContextRef);
JSValueRef  JSValueMakeBoolean(JSContextRef, bool);
JSValueRef  JSValueMakeNumber(JSContextRef, double);
JSValueRef  JSValueMakeString(JSContextRef, JSStringRef);
JSValueRef  JSValueMakeSymbol(JSContextRef, JSStringRef description);
JSValueRef  JSBigIntCreateWithDouble(JSContextRef, double, JSValueRef* exception);
JSValueRef  JSBigIntCreateWithInt64(JSContextRef, int64_t, JSValueRef* exception);
JSValueRef  JSBigIntCreateWithUInt64(JSContextRef, uint64_t, JSValueRef* exception);
JSValueRef  JSBigIntCreateWithString(JSContextRef, JSStringRef, JSValueRef* exception);
JSValueRef  JSValueMakeFromJSONString(JSContextRef, JSStringRef);
JSStringRef JSValueCreateJSONString(JSContextRef, JSValueRef, unsigned indent,
                                    JSValueRef* exception);
bool        JSValueToBoolean(JSContextRef, JSValueRef);
double      JSValueToNumber(JSContextRef, JSValueRef, JSValueRef* exception);
int32_t     JSValueToInt32(JSContextRef, JSValueRef, JSValueRef* exception);
uint32_t    JSValueToUInt32(JSContextRef, JSValueRef, JSValueRef* exception);
int64_t     JSValueToInt64(JSContextRef, JSValueRef, JSValueRef* exception);
uint64_t    JSValueToUInt64(JSContextRef, JSValueRef, JSValueRef* exception);
JSStringRef JSValueToStringCopy(JSContextRef, JSValueRef, JSValueRef* exception);
JSObjectRef JSValueToObject(JSContextRef, JSValueRef, JSValueRef* exception);
void        JSValueProtect(JSContextRef, JSValueRef);
void        JSValueUnprotect(JSContextRef, JSValueRef);
bool        ZJSValueProtect(JSContextRef, JSValueRef);   // zig-js extension
bool        ZJSValueUnprotect(JSContextRef, JSValueRef); // zig-js extension
```

```c [Objects]
JSClassRef  JSClassCreate(const JSClassDefinition*);
JSClassRef  JSClassRetain(JSClassRef);
void        JSClassRelease(JSClassRef);
JSObjectRef JSObjectMake(JSContextRef, JSClassRef, void* data);
JSValueRef  JSObjectGetPrototype(JSContextRef, JSObjectRef);
void        JSObjectSetPrototype(JSContextRef, JSObjectRef, JSValueRef);
bool        JSObjectHasProperty(JSContextRef, JSObjectRef, JSStringRef);
bool        JSObjectHasPropertyForKey(JSContextRef, JSObjectRef, JSValueRef key,
                                      JSValueRef* exception);
JSValueRef  JSObjectGetPropertyForKey(JSContextRef, JSObjectRef, JSValueRef key,
                                      JSValueRef* exception);
void*       JSObjectGetPrivate(JSObjectRef);
bool        JSObjectSetPrivate(JSObjectRef, void* data);
JSObjectRef JSObjectMakeArray(JSContextRef, size_t argc, const JSValueRef args[], JSValueRef* exception);
JSObjectRef JSObjectMakeDeferredPromise(JSContextRef, JSObjectRef* resolve,
                                        JSObjectRef* reject, JSValueRef* exception);
JSValueRef  JSObjectGetProperty(JSContextRef, JSObjectRef, JSStringRef name, JSValueRef* exception);
void        JSObjectSetProperty(JSContextRef, JSObjectRef, JSStringRef name,
                                JSValueRef value, JSPropertyAttributes, JSValueRef* exception);
JSValueRef  JSObjectGetPropertyAtIndex(JSContextRef, JSObjectRef, unsigned index,
                                       JSValueRef* exception);
void        JSObjectSetPropertyAtIndex(JSContextRef, JSObjectRef, unsigned index,
                                       JSValueRef value, JSValueRef* exception);
bool        JSObjectDeleteProperty(JSContextRef, JSObjectRef, JSStringRef,
                                   JSValueRef* exception);
bool        JSObjectDeletePropertyForKey(JSContextRef, JSObjectRef, JSValueRef key,
                                         JSValueRef* exception);
JSValueRef  JSObjectCallAsFunction(JSContextRef, JSObjectRef, JSObjectRef thisObject,
                                   size_t argc, const JSValueRef args[], JSValueRef* exception);
JSObjectRef JSObjectMakeFunctionWithCallback(JSContextRef, JSStringRef name,
                                             JSObjectCallAsFunctionCallback callback);
JSObjectRef JSObjectCallAsConstructor(JSContextRef, JSObjectRef constructor,
                                      size_t argc, const JSValueRef args[], JSValueRef* exception);
bool        JSObjectIsFunction(JSContextRef, JSObjectRef);
bool        JSObjectIsConstructor(JSContextRef, JSObjectRef);
```

```c [Typed arrays]
JSObjectRef JSObjectMakeTypedArray(JSContextRef, JSTypedArrayType, size_t length,
                                   JSValueRef* exception);
JSObjectRef JSObjectMakeTypedArrayWithBytesNoCopy(
    JSContextRef, JSTypedArrayType, void* bytes, size_t byteLength,
    JSTypedArrayBytesDeallocator, void* deallocatorContext, JSValueRef* exception);
JSObjectRef JSObjectMakeTypedArrayWithArrayBuffer(JSContextRef, JSTypedArrayType,
                                                  JSObjectRef buffer, JSValueRef* exception);
JSObjectRef JSObjectMakeTypedArrayWithArrayBufferAndOffset(
    JSContextRef, JSTypedArrayType, JSObjectRef buffer, size_t byteOffset,
    size_t length, JSValueRef* exception);
void*       JSObjectGetTypedArrayBytesPtr(JSContextRef, JSObjectRef, JSValueRef* exception);
size_t      JSObjectGetTypedArrayLength(JSContextRef, JSObjectRef, JSValueRef* exception);
size_t      JSObjectGetTypedArrayByteLength(JSContextRef, JSObjectRef, JSValueRef* exception);
size_t      JSObjectGetTypedArrayByteOffset(JSContextRef, JSObjectRef, JSValueRef* exception);
JSObjectRef JSObjectGetTypedArrayBuffer(JSContextRef, JSObjectRef, JSValueRef* exception);
JSObjectRef JSObjectMakeArrayBufferWithBytesNoCopy(
    JSContextRef, void* bytes, size_t byteLength, JSTypedArrayBytesDeallocator,
    void* deallocatorContext, JSValueRef* exception);
void*       JSObjectGetArrayBufferBytesPtr(JSContextRef, JSObjectRef, JSValueRef* exception);
size_t      JSObjectGetArrayBufferByteLength(JSContextRef, JSObjectRef, JSValueRef* exception);
```

```c [Strings]
JSStringRef JSStringCreateWithCharacters(const JSChar* characters, size_t length);
JSStringRef JSStringCreateWithUTF8CString(const char* string);
JSStringRef JSStringRetain(JSStringRef);
void        JSStringRelease(JSStringRef);
size_t      JSStringGetLength(JSStringRef);
const JSChar* JSStringGetCharactersPtr(JSStringRef);
size_t      JSStringGetMaximumUTF8CStringSize(JSStringRef);
size_t      JSStringGetUTF8CString(JSStringRef, char* buffer, size_t bufferSize);
bool        JSStringIsEqual(JSStringRef, JSStringRef);
bool        JSStringIsEqualToUTF8CString(JSStringRef, const char*);
```

```c [Workers]
JSWorkerRef JSWorkerCreate(JSStringRef source);
JSWorkerRef JSWorkerCreateWithLimits(JSStringRef source,
                                     size_t maxMessageBytes,
                                     size_t maxQueuedBytes,
                                     size_t maxQueuedMessages);
bool        JSWorkerPostMessage(JSWorkerRef, JSContextRef, JSValueRef, JSValueRef* exception);
JSValueRef  JSWorkerReceive(JSWorkerRef, JSContextRef, uint64_t timeoutMs, JSValueRef* exception);
void        JSWorkerTerminate(JSWorkerRef);
void        JSWorkerRelease(JSWorkerRef);
```
:::

Native callbacks use the standard `JSObjectCallAsFunctionCallback` calling convention, so functions you expose to JavaScript through this subset are registered exactly as they are with JavaScriptCore. `JSObjectIsConstructor` uses the runtime's constructability check, including native constructors such as `Date` and `Array`. `JSObjectMakeArray` returns a real runtime Array object in the current realm, inheriting from that realm's `Array.prototype`. `JSObjectGetProperty` and `JSObjectGetPropertyAtIndex` perform JavaScript `[[Get]]`, including prototype lookup, accessor/proxy behavior, and exception reporting. `JSObjectSetProperty` maps `ReadOnly`, `DontEnum`, and `DontDelete` attributes to JavaScript `writable`, `enumerable`, and `configurable` descriptor fields. `JSValueIsEqual` performs JavaScript abstract equality (`==`), including object coercion and exception reporting. `JSValueGetType` reports Symbol primitives as `symbol` and BigInt primitives as the zig-js `bigint` extension instead of leaking the engine's object-tagged representation. `JSValueToNumber` matches `Number(value)`, including primitive/boxed BigInt conversion and exception reporting for throwing coercions or Symbols. `JSValueToStringCopy` performs JavaScript `ToString`, including object coercion and exception reporting for throwing coercions or Symbol values. `JSValueToObject` performs JavaScript `ToObject` conversion, returning real primitive wrapper objects and reporting an exception for `null` / `undefined`. `JSValueIsDate` reports the runtime's Date internal slot, including invalid Date objects. `ZJSGlobalContextCreateThreaded` and `JSWorker*` are zig-js extensions rather than public JSC symbols.

`JSGlobalContextRetain` and `JSGlobalContextRelease` maintain a real C-API reference count for contexts created through this C API. Releasing a retained context destroys the underlying runtime only after the final release. `JSGlobalContextRetain` returns null for a null context or if retaining would overflow the context refcount.

The typed-array API uses the public JavaScriptCore enum layout through `BigUint64Array`. JavaScript `Float16Array` remains available inside the engine, but the pinned public JSC enum has no Float16 entry, so `JSValueGetTypedArrayType` reports `kJSTypedArrayTypeNone` for that runtime-only kind. ArrayBuffer-backed constructors preserve the original buffer and requested view geometry; invalid types return null, while detached, out-of-bounds, misaligned, overflowing, wrong-context, and non-ArrayBuffer inputs report through the exception out pointer.

The pointers returned by `JSObjectGetTypedArrayBytesPtr` and `JSObjectGetArrayBufferBytesPtr` are borrowed and temporary. They may be invalidated by later engine calls that detach, transfer, resize, or collect the backing object. Hosts must keep the corresponding JS object reachable and must synchronize their own native access with JavaScript execution.

The no-copy constructors transfer backing-store lifetime to the context. Their deallocator is invoked exactly once: immediately when construction fails, from object finalization in GC-enabled contexts, or during context teardown in arena contexts. A successful zero-length no-copy buffer may use a null byte pointer; a non-empty buffer requires a non-null pointer.

`JSEvaluateScript` rejects a null source string by returning null and reporting an exception through the out pointer when one is provided. For parse/lex failures, the exception is a `SyntaxError` object whose message includes the source name and adjusted line/column; the object also carries non-enumerable `sourceURL`, `line`, `column`, and `byteOffset` properties for embedders that do not want to parse message text. For runtime throws of Error objects, `sourceURL` and `startingLineNumber` are attached as non-enumerable properties, and the default `stack` string includes that source frame when present.

When an exception-capable API has produced a successful JavaScript result but cannot allocate the C `JSValueRef` / `JSStringRef` wrapper needed to return it, it reports `OutOfMemory` through the exception out pointer instead of returning an ambiguous silent null.

`JSObjectGetProperty`, `JSObjectGetPropertyAtIndex`, and `JSObjectSetProperty` reject null object refs and null property-name strings by reporting an exception through the out pointer.

`JSValueIsEqual`, `JSValueToNumber`, `JSValueToStringCopy`, and `JSValueToObject` reject null value refs by reporting an exception through the out pointer.

`JSValueRef` / `JSObjectRef` handles are owned by the context that created them. APIs that receive a `JSContextRef` reject handles from a different context instead of mixing arenas or object graphs: exception-capable APIs report a `TypeError`, while no-exception inspection/protection APIs return their invalid-handle result.

For no-exception value inspection APIs, a null or wrong-context value ref is an invalid handle, not JavaScript `undefined`: `JSValueGetType` returns the zig-js extension `invalid`, value predicates and `JSValueIsStrictEqual` return false, and `JSValueToBoolean` returns false.

Public `JSValueProtect` and `JSValueUnprotect` have JavaScriptCore's `void` ABI. The `ZJSValueProtect` and `ZJSValueUnprotect` extensions return whether the handle-table operation was accepted; they report false for invalid/null handles, missing protected entries on GC-enabled contexts, allocation failure, or protection-count overflow.

`JSObjectSetProperty` and `JSWorkerPostMessage` reject null value refs by reporting an exception through the out pointer instead of storing or posting JavaScript `undefined`.

`JSObjectMakeArray`, `JSObjectCallAsFunction`, and `JSObjectCallAsConstructor` reject null `argv` arrays when `argc > 0` and null value refs inside non-null argument arrays by reporting an exception through the out pointer.

`JSValueMakeString` rejects a null string ref by returning null instead of creating JavaScript `undefined`.

`JSStringCreateWithUTF8CString` accepts valid UTF-8 only. A null pointer or invalid UTF-8 byte sequence returns null, so later string APIs can use the validated UTF-8 backing safely.

`JSStringRetain` returns null for a null string ref or if retaining would overflow the string refcount; successful retains must still be paired with `JSStringRelease`.

Native callbacks installed with `JSObjectMakeFunctionWithCallback` must return a non-null value ref or set the exception out pointer; returning null without an exception throws a `TypeError` instead of implicitly producing JavaScript `undefined`.

`JSObjectCallAsFunction(..., thisObject, ...)` uses the provided object as the call receiver, or the context global object when `thisObject` is null.

`JSObjectCallAsConstructor` performs the runtime `[[Construct]]` path and reports constructor throws through the exception out pointer.

`JSObjectMakeFunctionWithCallback` returns null when the callback pointer is null.

`JSClassCreate` deep-copies its definition, static tables, and names, retains its parent, and uses an atomic reference count independent of the caller's definition storage. `JSObjectMake(..., class, data)` retains the class for the object lifetime, runs inherited initializers parent-first, finalizers child-first, and keeps the opaque pointer as host-owned private data. Automatic classes share a per-context, GC-rooted prototype carrying their static functions; `NoAutomaticPrototype` classes receive distinct own function objects, matching JSC. Static values use a tri-state internal-method bridge: null getter results remain absent, handled setters consume a write, declined setters do not accidentally create a data property, and `DontDelete` controls the delete result while class-defined values remain virtual. Reflection exposes JSC-compatible static-value descriptors and key membership; zig-js deliberately returns declared static names in deterministic child-first definition order instead of exposing JSC's internal hash-table iteration order. Dynamic `deleteProperty` callbacks run child-first, may consume deletion, fall through to parent/ordinary deletion when false, and propagate callback exceptions. `JSValueIsObjectOfClass` recognizes both the exact class and retained ancestors. The remaining property/call/conversion callbacks are still pending in issue #137. `JSObjectGetPrivate` returns only host-owned private data; engine-owned native records are not exposed. `JSObjectSetPrivate` can update host-owned private data and can attach host data to plain objects that do not already carry engine private data.

`JSObjectGetPrototype` and `JSObjectSetPrototype` use the runtime's real `[[GetPrototypeOf]]`/`[[SetPrototypeOf]]` paths, including Proxy traps, invariants, cycle prevention, and null prototypes. Their pinned JSC signatures have no exception out pointer, so rejected/throwing mutations leave the object unchanged. `JSObjectHasProperty`, `JSObjectSetProperty`, `JSObjectDeleteProperty`, and indexed writes likewise use the engine's internal-method funnels rather than bypassing class callbacks, proxies, accessors, typed-array rules, or property attributes.

`JSObjectMakeDeferredPromise` returns a pending native Promise and stores callable resolve/reject functions in the required out pointers. Passing a null resolve or reject out pointer is a contract error reported through the exception out pointer. The returned functions settle the promise through the normal Promise job queue; embedder-observable callbacks run at the next microtask checkpoint, such as the one performed after `JSEvaluateScript`.

`JSWorkerPostMessage` and `JSWorkerReceive` use structured clone to move values between isolated worker contexts. `JSWorkerCreate` uses the default 64 MiB per-message, 256 MiB queued-byte, and 1024 queued-message caps in both directions; `JSWorkerCreateWithLimits` sets all three explicitly (zero is a real zero limit). The message cap includes frame/manifest overhead and is enforced during serialization. Rejected closed/full/oversized delivery returns `false` and reports an exception instead of silently dropping a frame. `JSWorkerRef` handles are owner-thread-affine: post, receive, terminate, and release must be called on the thread that created the worker. Null or foreign-thread worker refs are rejected; exception-capable worker APIs report through the exception out pointer. Values that structured clone rejects, such as functions and Symbols, also report through the exception out pointer.

`JSStringCreateWithUTF8CString(null)` returns null. `JSStringGetUTF8CString` returns 0 for null strings, null output buffers, or zero buffer size; otherwise it writes a null-terminated UTF-8 prefix and returns the number of bytes written including the terminator.

## Caveats

> [!WARNING]
> The implemented subset covers the common evaluation, value, object, string, typed-array/ArrayBuffer, protected-handle, and foundational class-ownership surface plus the zig-js worker extension. Remaining JavaScriptCore class callbacks/static members, Objective-C `JSValue`/`JSContext`, inspector/debugger APIs, and other WebKit internals remain tracked by [the public C API roadmap](https://github.com/zig-utils/zig-js/issues/135) and [the umbrella roadmap](https://github.com/zig-utils/zig-js/issues/134). Non-null `JSClassRef` input to `JSGlobalContextCreate` remains pending; `JSObjectMake` accepts classes created by `JSClassCreate`. The language/runtime scope is whatever the configured conformance runner currently proves — see [Conformance](/conformance).

Some functions intentionally keep JavaScriptCore-shaped signatures while zig-js is still pre-stabilization, but the documented parameters now either have real behavior or fail fast when the underlying feature is out of scope. `JSEvaluateScript` honors `thisObject`, uses `sourceURL` / `startingLineNumber` for syntax and runtime Error metadata, and parser-created SyntaxErrors expose non-enumerable line/column diagnostics instead of requiring callers to parse message text. `JSGlobalContextRetain` / `JSGlobalContextRelease` maintain a real C-API reference count, `JSObjectMakeFunctionWithCallback` honors the provided function name, and `JSObjectSetProperty` honors property attributes.

**Threading.** Handles are affine to the thread that owns their context: a context and its `JSValueRef` / `JSObjectRef` handles must be created and used on one thread (one context per thread — the C surface asserts this). `JSWorkerRef` handles are also owner-thread-affine; use worker messages, not worker handles, as the cross-thread boundary. For cross-context / cross-thread work use the `JSWorker*` extension (isolated worker contexts that exchange messages); see the [threading docs](/threads/) for what may cross a thread boundary.
