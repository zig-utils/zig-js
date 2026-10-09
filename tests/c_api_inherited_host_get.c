#include <JavaScriptCore/JavaScript.h>

#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>

struct State { unsigned calls; bool handled; bool throwing; };

static JSValueRef get(JSContextRef context, JSObjectRef object,
                      JSStringRef name, JSValueRef *exception)
{
    struct State *state = JSObjectGetPrivate(object);
    if (!JSStringIsEqualToUTF8CString(name, "value")) return NULL;
    ++state->calls;
    if (state->throwing) {
        *exception = JSValueMakeNumber(context, 123);
        return NULL;
    }
    return state->handled ? JSValueMakeNumber(context, 99) : NULL;
}

static double evaluate(JSGlobalContextRef context, const char *source)
{
    JSStringRef script = JSStringCreateWithUTF8CString(source);
    JSValueRef exception = NULL;
    JSValueRef result = JSEvaluateScript(context, script, NULL, NULL, 1, &exception);
    JSStringRelease(script);
    if (exception || !result) {
        fprintf(stderr, "inherited host get: evaluation failed\n");
        exit(1);
    }
    return JSValueToNumber(context, result, NULL);
}

int main(void)
{
    JSGlobalContextRef context = JSGlobalContextCreate(NULL);
    struct State state = { 0, false, false };
    JSClassDefinition definition = kJSClassDefinitionEmpty;
    definition.className = "InheritedHostGet";
    definition.getProperty = get;
    JSClassRef cls = JSClassCreate(&definition);
    JSObjectRef host = JSObjectMake(context, cls, &state);
    JSObjectRef prototype = JSObjectMake(context, NULL, NULL);
    JSStringRef key = JSStringCreateWithUTF8CString("value");
    JSObjectSetProperty(context, prototype, key, JSValueMakeNumber(context, 7), kJSPropertyAttributeNone, NULL);
    JSObjectSetPrototype(context, host, prototype);
    JSStringRef host_name = JSStringCreateWithUTF8CString("host");
    JSObjectSetProperty(context, JSContextGetGlobalObject(context), host_name, host, kJSPropertyAttributeNone, NULL);

    double warm = evaluate(context, "function read(subject){return subject.value;} var sum=0;for(var i=0;i<64;i++)sum+=read(host);sum;");
    unsigned warm_calls = state.calls;
    state.handled = true;
    double handled = evaluate(context, "read(host);");
    unsigned handled_calls = state.calls;
    state.throwing = true;
    double thrown = evaluate(context, "(function(){try{return read(host);}catch(error){return error;}})();");
    unsigned thrown_calls = state.calls;
    state.throwing = false;
    state.handled = false;
    double unhandled = evaluate(context, "read(host);");
    unsigned unhandled_calls = state.calls;
    printf("inherited host get: %.0f/%.0f/%.0f/%.0f, %u/%u/%u/%u callbacks\n",
           warm, handled, thrown, unhandled, warm_calls, handled_calls, thrown_calls, unhandled_calls);
    bool passed = warm == 448 && handled == 99 && thrown == 123 && unhandled == 7 &&
                  warm_calls == 64 && handled_calls == 65 && thrown_calls == 66 && unhandled_calls == 67;

    JSStringRelease(key);
    JSStringRelease(host_name);
    JSClassRelease(cls);
    JSGlobalContextRelease(context);
    return passed ? 0 : 1;
}
