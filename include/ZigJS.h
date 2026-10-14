#ifndef ZIG_JS_OWNED_EMBEDDING_H
#define ZIG_JS_OWNED_EMBEDDING_H

// AppKit/AVKit may load system JSC transitively. Owned names keep its classes
// out of this embedding even when both libraries are present in the process.
#define ZIG_JS_OWNED_OBJC 1
#define JSContext ZigJSContext
#define JSValue ZigJSValue
#define JSVirtualMachine ZigJSVirtualMachine
#define JSManagedValue ZigJSManagedValue
#define JSExport ZigJSExport
#define JSPropertyDescriptorWritableKey ZigJSPropertyDescriptorWritableKey
#define JSPropertyDescriptorEnumerableKey ZigJSPropertyDescriptorEnumerableKey
#define JSPropertyDescriptorConfigurableKey ZigJSPropertyDescriptorConfigurableKey
#define JSPropertyDescriptorValueKey ZigJSPropertyDescriptorValueKey
#define JSPropertyDescriptorGetKey ZigJSPropertyDescriptorGetKey
#define JSPropertyDescriptorSetKey ZigJSPropertyDescriptorSetKey
#include <JavaScriptCore/JavaScriptCore.h>

#if defined(__OBJC__) && JSC_OBJC_API_ENABLED
// Call after the outermost host evaluation or callback returns, on the realm's
// owning thread. Host callbacks must not run a checkpoint reentrantly.
JS_EXPORT void ZJSContextRunMicrotasks(ZigJSContext *context);
#endif
#endif
