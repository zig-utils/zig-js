---
title: zig-js C API subset
description: Embed zig-js through its implemented JavaScriptCore-shaped C API subset.
---

# zig-js C API subset

zig-js exports an implemented JavaScriptCore-shaped C API subset from `c_api.zig`. Hosts that only use this subset can link `libzig-js.a` in place of the system `JavaScriptCore.framework` and keep those documented calls unchanged.

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
bool        JSValueIsObject(JSContextRef, JSValueRef);
bool        JSValueIsArray(JSContextRef, JSValueRef);
bool        JSValueIsDate(JSContextRef, JSValueRef);
bool        JSValueIsEqual(JSContextRef, JSValueRef, JSValueRef, JSValueRef* exception);
bool        JSValueIsStrictEqual(JSContextRef, JSValueRef, JSValueRef);
JSValueRef  JSValueMakeUndefined(JSContextRef);
JSValueRef  JSValueMakeNull(JSContextRef);
JSValueRef  JSValueMakeBoolean(JSContextRef, bool);
JSValueRef  JSValueMakeNumber(JSContextRef, double);
JSValueRef  JSValueMakeString(JSContextRef, JSStringRef);
bool        JSValueToBoolean(JSContextRef, JSValueRef);
double      JSValueToNumber(JSContextRef, JSValueRef, JSValueRef* exception);
JSStringRef JSValueToStringCopy(JSContextRef, JSValueRef, JSValueRef* exception);
JSObjectRef JSValueToObject(JSContextRef, JSValueRef, JSValueRef* exception);
bool        JSValueProtect(JSContextRef, JSValueRef);
bool        JSValueUnprotect(JSContextRef, JSValueRef);
```

```c [Objects]
JSObjectRef JSObjectMake(JSContextRef, JSClassRef, void* data);
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
JSValueRef  JSObjectCallAsFunction(JSContextRef, JSObjectRef, JSObjectRef thisObject,
                                   size_t argc, const JSValueRef args[], JSValueRef* exception);
JSObjectRef JSObjectMakeFunctionWithCallback(JSContextRef, JSStringRef name,
                                             JSObjectCallAsFunctionCallback callback);
JSObjectRef JSObjectCallAsConstructor(JSContextRef, JSObjectRef constructor,
                                      size_t argc, const JSValueRef args[], JSValueRef* exception);
bool        JSObjectIsFunction(JSContextRef, JSObjectRef);
bool        JSObjectIsConstructor(JSContextRef, JSObjectRef);
```

```c [Strings]
JSStringRef JSStringCreateWithUTF8CString(const char* string);
JSStringRef JSStringRetain(JSStringRef);
void        JSStringRelease(JSStringRef);
size_t      JSStringGetLength(JSStringRef);
size_t      JSStringGetUTF8CString(JSStringRef, char* buffer, size_t bufferSize);
```

```c [Workers]
JSWorkerRef JSWorkerCreate(JSStringRef source);
bool        JSWorkerPostMessage(JSWorkerRef, JSContextRef, JSValueRef, JSValueRef* exception);
JSValueRef  JSWorkerReceive(JSWorkerRef, JSContextRef, uint64_t timeoutMs, JSValueRef* exception);
void        JSWorkerTerminate(JSWorkerRef);
void        JSWorkerRelease(JSWorkerRef);
```
:::

Native callbacks use the standard `JSObjectCallAsFunctionCallback` calling convention, so functions you expose to JavaScript through this subset are registered exactly as they are with JavaScriptCore. `JSObjectIsConstructor` uses the runtime's constructability check, including native constructors such as `Date` and `Array`. `JSObjectMakeArray` returns a real runtime Array object in the current realm, inheriting from that realm's `Array.prototype`. `JSObjectGetProperty` and `JSObjectGetPropertyAtIndex` perform JavaScript `[[Get]]`, including prototype lookup, accessor/proxy behavior, and exception reporting. `JSObjectSetProperty` maps `ReadOnly`, `DontEnum`, and `DontDelete` attributes to JavaScript `writable`, `enumerable`, and `configurable` descriptor fields. `JSValueIsEqual` performs JavaScript abstract equality (`==`), including object coercion and exception reporting. `JSValueGetType` reports Symbol primitives as `symbol` and BigInt primitives as the zig-js `bigint` extension instead of leaking the engine's object-tagged representation. `JSValueToNumber` performs JavaScript `ToNumber`, including object coercion and exception reporting for throwing coercions or Symbol/BigInt values. `JSValueToStringCopy` performs JavaScript `ToString`, including object coercion and exception reporting for throwing coercions or Symbol values. `JSValueToObject` performs JavaScript `ToObject` conversion, returning real primitive wrapper objects and reporting an exception for `null` / `undefined`. `JSValueIsDate` reports the runtime's Date internal slot, including invalid Date objects. `ZJSGlobalContextCreateThreaded` and `JSWorker*` are zig-js extensions rather than public JSC symbols.

`JSGlobalContextRetain` and `JSGlobalContextRelease` maintain a real C-API reference count for contexts created through this C API. Releasing a retained context destroys the underlying runtime only after the final release. `JSGlobalContextRetain` returns null for a null context or if retaining would overflow the context refcount.

`JSEvaluateScript` rejects a null source string by returning null and reporting an exception through the out pointer when one is provided. For parse/lex failures, the exception is a `SyntaxError` object whose message includes the source name and adjusted line/column; the object also carries non-enumerable `sourceURL`, `line`, `column`, and `byteOffset` properties for embedders that do not want to parse message text. For runtime throws of Error objects, `sourceURL` and `startingLineNumber` are attached as non-enumerable properties, and the default `stack` string includes that source frame when present.

When an exception-capable API has produced a successful JavaScript result but cannot allocate the C `JSValueRef` / `JSStringRef` wrapper needed to return it, it reports `OutOfMemory` through the exception out pointer instead of returning an ambiguous silent null.

`JSObjectGetProperty`, `JSObjectGetPropertyAtIndex`, and `JSObjectSetProperty` reject null object refs and null property-name strings by reporting an exception through the out pointer.

`JSValueIsEqual`, `JSValueToNumber`, `JSValueToStringCopy`, and `JSValueToObject` reject null value refs by reporting an exception through the out pointer.

`JSValueRef` / `JSObjectRef` handles are owned by the context that created them. APIs that receive a `JSContextRef` reject handles from a different context instead of mixing arenas or object graphs: exception-capable APIs report a `TypeError`, while no-exception inspection/protection APIs return their invalid-handle result.

For no-exception value inspection APIs, a null or wrong-context value ref is an invalid handle, not JavaScript `undefined`: `JSValueGetType` returns the zig-js extension `invalid`, value predicates and `JSValueIsStrictEqual` return false, and `JSValueToBoolean` returns false.

`JSValueProtect` and `JSValueUnprotect` return `true` when the handle table operation is accepted. They return `false` for invalid/null handles, missing protected entries on GC-enabled contexts, allocation failure, or protection-count overflow; overflow is rejected rather than wrapping the counted root.

`JSObjectSetProperty` and `JSWorkerPostMessage` reject null value refs by reporting an exception through the out pointer instead of storing or posting JavaScript `undefined`.

`JSObjectMakeArray`, `JSObjectCallAsFunction`, and `JSObjectCallAsConstructor` reject null `argv` arrays when `argc > 0` and null value refs inside non-null argument arrays by reporting an exception through the out pointer.

`JSValueMakeString` rejects a null string ref by returning null instead of creating JavaScript `undefined`.

`JSStringCreateWithUTF8CString` accepts valid UTF-8 only. A null pointer or invalid UTF-8 byte sequence returns null, so later string APIs can use the validated UTF-8 backing safely.

`JSStringRetain` returns null for a null string ref or if retaining would overflow the string refcount; successful retains must still be paired with `JSStringRelease`.

Native callbacks installed with `JSObjectMakeFunctionWithCallback` must return a non-null value ref or set the exception out pointer; returning null without an exception throws a `TypeError` instead of implicitly producing JavaScript `undefined`.

`JSObjectCallAsFunction(..., thisObject, ...)` uses the provided object as the call receiver, or the context global object when `thisObject` is null.

`JSObjectCallAsConstructor` performs the runtime `[[Construct]]` path and reports constructor throws through the exception out pointer.

`JSObjectMakeFunctionWithCallback` returns null when the callback pointer is null.

`JSObjectMake(..., data)` returns an ordinary object in the current realm, inheriting from that realm's `Object.prototype`, and marks the opaque pointer as host-owned private data. `JSObjectGetPrivate` returns only host-owned private data; engine-owned native records are not exposed. `JSObjectSetPrivate` can update host-owned private data and can attach host data to plain objects that do not already carry engine private data.

`JSObjectMakeDeferredPromise` returns a pending native Promise and stores callable resolve/reject functions in the required out pointers. Passing a null resolve or reject out pointer is a contract error reported through the exception out pointer. The returned functions settle the promise through the normal Promise job queue; embedder-observable callbacks run at the next microtask checkpoint, such as the one performed after `JSEvaluateScript`.

`JSWorkerPostMessage` and `JSWorkerReceive` use structured clone to move values between isolated worker contexts. Null worker refs and values that structured clone rejects, such as functions and Symbols, report through the exception out pointer.

`JSStringCreateWithUTF8CString(null)` returns null. `JSStringGetUTF8CString` returns 0 for null strings, null output buffers, or zero buffer size; otherwise it writes a null-terminated UTF-8 prefix and returns the number of bytes written including the terminator.

## Caveats

> [!WARNING]
> The implemented subset covers the common evaluation, value, object, string, and protected-handle surface plus the zig-js worker extension. Full JavaScriptCore class definitions, Objective-C `JSValue`/`JSContext`, inspector/debugger APIs, typed-array C constructors, and other WebKit internals are out of scope. Non-null `JSClassRef` inputs to `JSGlobalContextCreate` or `JSObjectMake` are rejected rather than silently ignored. The language/runtime scope is whatever the configured conformance runner currently proves — see [Conformance](/conformance).

Some functions intentionally keep JavaScriptCore-shaped signatures while zig-js is still pre-stabilization, but the documented parameters now either have real behavior or fail fast when the underlying feature is out of scope. `JSEvaluateScript` honors `thisObject`, uses `sourceURL` / `startingLineNumber` for syntax and runtime Error metadata, and parser-created SyntaxErrors expose non-enumerable line/column diagnostics instead of requiring callers to parse message text. `JSGlobalContextRetain` / `JSGlobalContextRelease` maintain a real C-API reference count, `JSObjectMakeFunctionWithCallback` honors the provided function name, and `JSObjectSetProperty` honors property attributes.

**Threading.** Handles are affine to the thread that owns their context: a context and its `JSValueRef` / `JSObjectRef` handles must be created and used on one thread (one context per thread — the C surface asserts this). For cross-context / cross-thread work use the `JSWorker*` extension (isolated worker contexts that exchange messages); see the [threading docs](/threads/) for what may cross a thread boundary.
