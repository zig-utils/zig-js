#include "c_api_reentrant_support.h"
#include <zig-js/Extensions.h>

static unsigned collections;
static JSValueRef collect_now(JSContextRef context, JSObjectRef function, JSObjectRef receiver,
    size_t count, const JSValueRef arguments[], JSValueRef* exception)
{
    (void)function; (void)receiver; (void)count; (void)arguments; (void)exception;
    JSGarbageCollect(context);
    ++collections;
    return JSValueMakeUndefined(context);
}

static JSValueRef evaluate(JSContextRef context, const char* source, JSValueRef* exception)
{
    JSStringRef script = JSStringCreateWithUTF8CString(source);
    JSValueRef result = JSEvaluateScript(context, script, NULL, NULL, 1, exception);
    JSStringRelease(script);
    return result;
}

static double marker(JSContextRef context, JSValueRef result)
{
    JSValueRef exception = NULL;
    JSObjectRef object = result ? JSValueToObject(context, result, &exception) : NULL;
    if (!object || exception) return -1;
    JSStringRef key = JSStringCreateWithUTF8CString("marker");
    JSValueRef value = JSObjectGetProperty(context, object, key, &exception);
    JSStringRelease(key);
    return value && !exception ? JSValueToNumber(context, value, NULL) : -1;
}

int main(void)
{
    unsigned passed = 0;
    for (int throws = 0; throws <= 1; ++throws) {
        JSGlobalContextRef context = ZJSGlobalContextCreateGarbageCollected(false);
        if (!context || !install_script(context, "collectNow", collect_now)) return 1;
        JSValueRef exception = NULL;
        JSValueRef function_value = evaluate(context, throws
            ? "globalThis.token={marker:43};function job(){collectNow();throw Error('secondary job')}(function(){Promise.resolve().then(job);throw token})"
            : "function job(){collectNow()}(function(){Promise.resolve().then(job);return {marker:42}})", &exception);
        JSObjectRef function = function_value ? JSValueToObject(context, function_value, &exception) : NULL;
        if (!function || exception) return 1;
        collections = 0;
        JSValueRef result = JSObjectCallAsFunction(context, function, NULL, 0, NULL, &exception);
        int good = collections == 1 && (throws
            ? !result && exception && marker(context, exception) == 43
            : result && !exception && marker(context, result) == 42);
        if (good) ++passed;
        else fprintf(stderr, "precise-GC call case %d failed (collections=%u)\n", throws, collections);
        JSGlobalContextRelease(context);
    }
    printf("C call checkpoint precise-GC completions: %u/2 cases passed\n", passed);
    return passed == 2 ? 0 : 1;
}
