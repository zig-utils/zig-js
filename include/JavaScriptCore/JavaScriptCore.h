#ifndef ZIG_JS_JAVASCRIPTCORE_H
#define ZIG_JS_JAVASCRIPTCORE_H

#include <JavaScriptCore/JavaScript.h>

#if defined(__OBJC__) && JSC_OBJC_API_ENABLED
#import <Foundation/Foundation.h>
#include <JavaScriptCore/JSContext.h>
#include <JavaScriptCore/JSValue.h>
#include <JavaScriptCore/JSManagedValue.h>
#include <JavaScriptCore/JSVirtualMachine.h>
#include <JavaScriptCore/JSExport.h>
#endif

#endif
