#ifndef ZIG_JS_JAVASCRIPTCORE_JSCONTEXTREF_H
#define ZIG_JS_JAVASCRIPTCORE_JSCONTEXTREF_H

#include <JavaScriptCore/JSBase.h>

#ifdef __cplusplus
extern "C" {
#endif

JS_EXPORT JSContextGroupRef JSContextGroupCreate(void);
JS_EXPORT JSContextGroupRef JSContextGroupRetain(JSContextGroupRef group);
JS_EXPORT void JSContextGroupRelease(JSContextGroupRef group);
JS_EXPORT JSGlobalContextRef JSGlobalContextCreate(JSClassRef globalObjectClass);
JS_EXPORT JSGlobalContextRef JSGlobalContextCreateInGroup(JSContextGroupRef group, JSClassRef globalObjectClass);
JS_EXPORT JSGlobalContextRef JSGlobalContextRetain(JSGlobalContextRef ctx);
JS_EXPORT void JSGlobalContextRelease(JSGlobalContextRef ctx);
JS_EXPORT JSObjectRef JSContextGetGlobalObject(JSContextRef ctx);
JS_EXPORT JSContextGroupRef JSContextGetGroup(JSContextRef ctx);
JS_EXPORT JSGlobalContextRef JSContextGetGlobalContext(JSContextRef ctx);
JS_EXPORT JSStringRef JSGlobalContextCopyName(JSGlobalContextRef ctx);
JS_EXPORT void JSGlobalContextSetName(JSGlobalContextRef ctx, JSStringRef name);
JS_EXPORT bool JSGlobalContextIsInspectable(JSGlobalContextRef ctx);
JS_EXPORT void JSGlobalContextSetInspectable(JSGlobalContextRef ctx, bool inspectable);

#ifdef __cplusplus
}
#endif

#endif
