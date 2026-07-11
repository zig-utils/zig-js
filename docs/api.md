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
void        JSValueProtect(JSContextRef, JSValueRef);
void        JSValueUnprotect(JSContextRef, JSValueRef);
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

`JSEvaluateScript` rejects a null source string by returning null and reporting an exception through the out pointer when one is provided.

`JSObjectGetProperty`, `JSObjectGetPropertyAtIndex`, and `JSObjectSetProperty` reject null object refs and null property-name strings by reporting an exception through the out pointer.

`JSObjectCallAsFunction(..., thisObject, ...)` uses the provided object as the call receiver, or the context global object when `thisObject` is null.

`JSObjectCallAsConstructor` performs the runtime `[[Construct]]` path and reports constructor throws through the exception out pointer.

`JSObjectMakeFunctionWithCallback` returns null when the callback pointer is null.

`JSObjectMake(..., data)` returns an ordinary object in the current realm, inheriting from that realm's `Object.prototype`, and marks the opaque pointer as host-owned private data. `JSObjectGetPrivate` returns only host-owned private data; engine-owned native records are not exposed. `JSObjectSetPrivate` can update host-owned private data and can attach host data to plain objects that do not already carry engine private data.

`JSObjectMakeDeferredPromise` returns a pending native Promise and stores callable resolve/reject functions in the provided out pointers when they are non-null. Those functions settle the promise through the normal Promise job queue; embedder-observable callbacks run at the next microtask checkpoint, such as the one performed after `JSEvaluateScript`.

`JSWorkerPostMessage` and `JSWorkerReceive` use structured clone to move values between isolated worker contexts. Null worker refs and values that structured clone rejects, such as functions and Symbols, report through the exception out pointer.

`JSStringCreateWithUTF8CString(null)` returns null. `JSStringGetUTF8CString` returns 0 for null strings, null output buffers, or zero buffer size; otherwise it writes a null-terminated UTF-8 prefix and returns the number of bytes written including the terminator.

## Caveats

> [!WARNING]
> The implemented subset covers the common evaluation, value, object, string, and protected-handle surface plus the zig-js worker extension. Full JavaScriptCore class definitions, Objective-C `JSValue`/`JSContext`, inspector/debugger APIs, typed-array C constructors, and other WebKit internals are out of scope. Non-null `JSClassRef` inputs to `JSGlobalContextCreate` or `JSObjectMake` are rejected rather than silently ignored. The language/runtime scope is whatever the configured conformance runner currently proves — see [Conformance](/conformance).

Some functions currently accept JavaScriptCore-shaped signatures while zig-js is still pre-stabilization. `JSEvaluateScript` honors `thisObject` and uses `sourceURL` / `startingLineNumber` for syntax-diagnostic exception text; broader stack/source-note plumbing is still tracked separately. Treat any remaining inert compatibility-shaped parameters as cleanup targets, not long-term ABI commitments. `JSGlobalContextRetain` / `JSGlobalContextRelease` maintain a real C-API reference count, `JSObjectMakeFunctionWithCallback` honors the provided function name, and `JSObjectSetProperty` honors property attributes.

**Threading.** Handles are affine to the thread that owns their context: a context and its `JSValueRef` / `JSObjectRef` handles must be created and used on one thread (one context per thread — the C surface asserts this). For cross-context / cross-thread work use the `JSWorker*` extension (isolated worker contexts that exchange messages); see the [threading docs](/threads/) for what may cross a thread boundary.
