---
title: JavaScriptCore C-API
description: Embed zig-js through its implemented JavaScriptCore C-API subset.
---

# JavaScriptCore C-API

zig-js exports an implemented subset of the public JavaScriptCore C-ABI from `c_api.zig`. Hosts that only use this subset can link `libzig-js.a` in place of the system `JavaScriptCore.framework` and keep those calls unchanged.

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
JSGlobalContextRef JSGlobalContextRetain(JSGlobalContextRef);
void               JSGlobalContextRelease(JSGlobalContextRef);
JSValueRef         JSEvaluateScript(JSContextRef, JSStringRef source,
                                    JSObjectRef thisObject, JSStringRef sourceURL,
                                    int startingLineNumber, JSValueRef* exception);
```

```c [Values]
JSType    JSValueGetType(JSContextRef, JSValueRef);
bool      JSValueIsNumber(JSContextRef, JSValueRef);
bool      JSValueIsString(JSContextRef, JSValueRef);
bool      JSValueIsObject(JSContextRef, JSValueRef);
double    JSValueToNumber(JSContextRef, JSValueRef, JSValueRef* exception);
JSStringRef JSValueToStringCopy(JSContextRef, JSValueRef, JSValueRef* exception);
```

```c [Objects]
JSValueRef JSObjectGetProperty(JSContextRef, JSObjectRef, JSStringRef name, JSValueRef* exception);
void       JSObjectSetProperty(JSContextRef, JSObjectRef, JSStringRef name,
                               JSValueRef value, JSPropertyAttributes, JSValueRef* exception);
JSValueRef JSObjectCallAsFunction(JSContextRef, JSObjectRef, JSObjectRef thisObject,
                                  size_t argc, const JSValueRef args[], JSValueRef* exception);
```

```c [Strings]
JSStringRef JSStringCreateWithUTF8CString(const char* string);
size_t      JSStringGetLength(JSStringRef);
void        JSStringRetain(JSStringRef);
void        JSStringRelease(JSStringRef);
```
:::

Native callbacks use JSC's `HostCallback` calling convention, so functions you expose to JavaScript through this subset are registered as they are with JavaScriptCore.

## Caveats

> [!WARNING]
> The implemented subset covers the common evaluation, value, object, and string surface. Engine-specific extensions (the JSC inspector/debugger protocol, the Objective-C `JSValue`/`JSContext` bridge) are out of scope. The language/runtime scope is whatever the configured conformance runner currently proves — see [Conformance](/conformance).
