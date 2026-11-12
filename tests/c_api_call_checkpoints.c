#include "c_api_reentrant_support.h"

static JSValueRef evaluate(JSContextRef context, const char* source, JSValueRef* exception)
{
    JSStringRef script = JSStringCreateWithUTF8CString(source);
    JSValueRef result = JSEvaluateScript(context, script, NULL, NULL, 1, exception);
    JSStringRelease(script);
    return result;
}

static int value_equals(JSContextRef context, JSValueRef value, const char* expected)
{
    if (!value) return 0;
    JSStringRef text = JSValueToStringCopy(context, value, NULL);
    if (!text) return 0;
    char actual[2048];
    JSStringGetUTF8CString(text, actual, sizeof(actual));
    JSStringRelease(text);
    if (strcmp(actual, expected)) {
        fprintf(stderr, "call completion expected [%s], got [%s]\n", expected, actual);
        return 0;
    }
    return 1;
}

static JSValueRef nested_call(JSContextRef context, JSObjectRef function, JSObjectRef receiver,
    size_t count, const JSValueRef arguments[], JSValueRef* exception)
{
    (void)function; (void)receiver;
    if (count != 1) return JSValueMakeUndefined(context);
    JSObjectRef target = JSValueToObject(context, arguments[0], exception);
    return target ? JSObjectCallAsFunction(context, target, NULL, 0, NULL, exception) : NULL;
}

static JSValueRef native_echo(JSContextRef context, JSObjectRef function, JSObjectRef receiver,
    size_t count, const JSValueRef arguments[], JSValueRef* exception)
{
    (void)function; (void)receiver;
    if (count != 1) return NULL;
    if (!evaluate(context, "globalThis.trace=[];Promise.resolve().then(()=>trace.push('job'));trace.push('inner')", exception)) return NULL;
    if (!evaluate(context, "trace.push('native-after')", exception)) return NULL;
    return arguments[0];
}

static JSValueRef native_throw(JSContextRef context, JSObjectRef function, JSObjectRef receiver,
    size_t count, const JSValueRef arguments[], JSValueRef* exception)
{
    (void)function; (void)receiver; (void)count; (void)arguments;
    JSValueRef thrown = NULL;
    evaluate(context, "globalThis.trace=[];Promise.resolve().then(()=>trace.push('job'));trace.push('inner');throw token", &thrown);
    if (!thrown) return NULL;
    if (!evaluate(context, "trace.push('caught-native')", exception)) return NULL;
    *exception = thrown;
    return NULL;
}

int main(void)
{
    const struct { const char* source; const char* completion; const char* state; int throws; } cases[] = {
        { "(function(){globalThis.trace=[];Promise.resolve().then(()=>trace.push('job'));trace.push('before');hostScript(\"trace.push('nested')\");trace.push('after');return trace.join(',')})",
            "before,nested,after", "before,nested,after,job", 0 },
        { "(function(){globalThis.trace=[];Promise.resolve().then(()=>trace.push('job'));throw token})",
            NULL, "job", 1 },
        { "(function(){globalThis.trace=[];Promise.resolve().then(()=>trace.push('outer-job'));trace.push('outer');nestedCall(()=>{trace.push('inner');Promise.resolve().then(()=>trace.push('inner-job'))});trace.push('after');return trace.join(',')})",
            "outer,inner,after", "outer,inner,after,outer-job,inner-job", 0 },
        { "(function(value){globalThis.trace=[];Promise.resolve().then(()=>trace.push('job'));return this.factor+value})",
            "12", "job", 0 },
        { "nativeEcho", NULL, "inner,native-after,job", 0 },
        { "nativeThrow", NULL, "inner,caught-native,job", 1 },
    };
    unsigned passed = 0;
    for (size_t index = 0; index < sizeof(cases) / sizeof(cases[0]); ++index) {
        JSGlobalContextRef context = JSGlobalContextCreate(NULL);
        if (!context || !install_script(context, "hostScript", host_script)
            || !install_script(context, "nestedCall", nested_call)
            || !install_script(context, "nativeEcho", native_echo)
            || !install_script(context, "nativeThrow", native_throw)) return 1;
        JSValueRef exception = NULL;
        JSValueRef token = evaluate(context, "globalThis.token={marker:42};token", &exception);
        JSValueRef value = evaluate(context, cases[index].source, &exception);
        JSObjectRef function = value ? JSValueToObject(context, value, &exception) : NULL;
        JSValueRef receiver_value = evaluate(context, "({factor:7})", &exception);
        JSObjectRef receiver = receiver_value ? JSValueToObject(context, receiver_value, &exception) : NULL;
        if (exception || !token || !function || !receiver) return 1;
        JSValueRef argument = index == 4 ? token : JSValueMakeNumber(context, 5);
        JSValueRef result = JSObjectCallAsFunction(context, function, receiver, 1, &argument, &exception);
        int completion = cases[index].throws
            ? !result && exception && JSValueIsStrictEqual(context, exception, token)
            : result && !exception && (index == 4 ? result == token : value_equals(context, result, cases[index].completion));
        int state = expect_script(context, "trace.join(',')", cases[index].state);
        if (completion && state) ++passed;
        else fprintf(stderr, "call checkpoint case %zu failed (completion=%d, state=%d)\n", index, completion, state);
        JSGlobalContextRelease(context);
    }
    printf("C function call checkpoints: %u/6 cases passed\n", passed);
    return passed == 6 ? 0 : 1;
}
