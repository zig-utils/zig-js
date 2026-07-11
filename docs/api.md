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

Native callbacks use the standard `JSObjectCallAsFunctionCallback` calling convention, so functions you expose to JavaScript through this subset are registered exactly as they are with JavaScriptCore. `JSObjectIsConstructor` uses the runtime's constructability check, including native constructors such as `Date` and `Array`. `JSObjectSetProperty` maps `ReadOnly`, `DontEnum`, and `DontDelete` attributes to JavaScript `writable`, `enumerable`, and `configurable` descriptor fields. `JSValueToObject` performs JavaScript `ToObject` conversion, returning real primitive wrapper objects and reporting an exception for `null` / `undefined`. `JSValueIsDate` reports the runtime's Date internal slot, including invalid Date objects. `ZJSGlobalContextCreateThreaded` and `JSWorker*` are zig-js extensions rather than public JSC symbols.

`JSObjectMake(..., data)` marks the opaque pointer as host-owned private data. `JSObjectGetPrivate` returns only host-owned private data; engine-owned native records are not exposed. `JSObjectSetPrivate` can update host-owned private data and can attach host data to plain objects that do not already carry engine private data.

`JSObjectMakeDeferredPromise` returns a pending native Promise and stores callable resolve/reject functions in the provided out pointers when they are non-null. Those functions settle the promise through the normal Promise job queue; embedder-observable callbacks run at the next microtask checkpoint, such as the one performed after `JSEvaluateScript`.

## Caveats

> [!WARNING]
> The implemented subset covers the common evaluation, value, object, string, and protected-handle surface plus the zig-js worker extension. Full JavaScriptCore class definitions, Objective-C `JSValue`/`JSContext`, inspector/debugger APIs, typed-array C constructors, and other WebKit internals are out of scope. The language/runtime scope is whatever the configured conformance runner currently proves — see [Conformance](/conformance).

Some functions currently accept JavaScriptCore-shaped signatures but do not yet honor every argument: `JSEvaluateScript` honors `thisObject` but still ignores `sourceURL` / `startingLineNumber`. Treat those as pre-stabilization gaps, not long-term ABI commitments: call sites compile today, but inert parameters should be implemented, renamed, or removed before the surface is declared stable. `JSGlobalContextRetain` / `JSGlobalContextRelease` maintain a real C-API reference count, `JSObjectMakeFunctionWithCallback` honors the provided function name, and `JSObjectSetProperty` honors property attributes.

**Threading.** Handles are affine to the thread that owns their context: a context and its `JSValueRef` / `JSObjectRef` handles must be created and used on one thread (one context per thread — the C surface asserts this). For cross-context / cross-thread work use the `JSWorker*` extension (isolated worker contexts that exchange messages); see the [threading docs](/threads/) for what may cross a thread boundary.
