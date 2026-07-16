#ifndef ZIG_JS_EXTENSIONS_H
#define ZIG_JS_EXTENSIONS_H

#include <JavaScriptCore/JavaScript.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Observable variants of JSC's void protection API. */
JS_EXPORT bool ZJSValueProtect(JSContextRef ctx, JSValueRef value);
JS_EXPORT bool ZJSValueUnprotect(JSContextRef ctx, JSValueRef value);

#ifdef __cplusplus
}
#endif

#endif
