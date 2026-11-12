#include <JavaScriptCore/JavaScript.h>
#include <stdio.h>
#include <string.h>

static JSValueRef host_script(JSContextRef context, JSObjectRef function,
    JSObjectRef receiver, size_t count, const JSValueRef arguments[], JSValueRef* exception)
{
    (void)function;
    (void)receiver;
    if (count != 1) return JSValueMakeUndefined(context);
    JSStringRef source = JSValueToStringCopy(context, arguments[0], exception);
    if (!source) return NULL;
    JSValueRef result = JSEvaluateScript(context, source, NULL, NULL, 1, exception);
    JSStringRelease(source);
    return result;
}

static int install_script(JSContextRef context, const char* name, JSObjectCallAsFunctionCallback callback)
{
    JSStringRef key = JSStringCreateWithUTF8CString(name);
    JSObjectRef function = JSObjectMakeFunctionWithCallback(context, key, callback);
    JSValueRef exception = NULL;
    JSObjectSetProperty(context, JSContextGetGlobalObject(context), key, function, kJSPropertyAttributeNone, &exception);
    JSStringRelease(key);
    return function && !exception;
}

static int expect_script(JSContextRef context, const char* source, const char* expected)
{
    JSStringRef script = JSStringCreateWithUTF8CString(source);
    JSValueRef exception = NULL;
    JSValueRef result = JSEvaluateScript(context, script, NULL, NULL, 1, &exception);
    JSStringRelease(script);
    if (!result && !exception) return 0;
    JSStringRef string = JSValueToStringCopy(context, exception ? exception : result, NULL);
    char actual[2048];
    if (!string) return 0;
    if (JSStringGetMaximumUTF8CStringSize(string) > sizeof(actual)) {
        JSStringRelease(string);
        return 0;
    }
    JSStringGetUTF8CString(string, actual, sizeof(actual));
    JSStringRelease(string);
    if (exception || !result || strcmp(actual, expected)) {
        fprintf(stderr, "reentrant Script expected [%s], got [%s]%s\n", expected, actual, exception ? " (exception)" : "");
        return 0;
    }
    return 1;
}
