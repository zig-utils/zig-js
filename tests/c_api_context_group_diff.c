#include <JavaScriptCore/JavaScript.h>

#include <stdio.h>

static int initialized;
static int finalized;

static JSValueRef evaluate(JSContextRef context, const char* source)
{
    JSStringRef script = JSStringCreateWithUTF8CString(source);
    JSValueRef exception = NULL;
    JSValueRef result = JSEvaluateScript(context, script, NULL, NULL, 1, &exception);
    JSStringRelease(script);
    return exception ? NULL : result;
}

static void global_initialize(JSContextRef context, JSObjectRef object)
{
    (void)context;
    (void)object;
    ++initialized;
}

static void global_finalize(JSObjectRef object)
{
    (void)object;
    ++finalized;
}

static JSValueRef global_value(JSContextRef context, JSObjectRef object,
    JSStringRef property_name, JSValueRef* exception)
{
    (void)object;
    (void)property_name;
    (void)exception;
    return JSValueMakeNumber(context, 77);
}

int main(void)
{
    JSContextGroupRef group = JSContextGroupCreate();
    JSContextGroupRef retained_group = JSContextGroupRetain(group);
    JSContextGroupRelease(retained_group);
    JSGlobalContextRef realm_a = JSGlobalContextCreateInGroup(group, NULL);
    JSGlobalContextRef realm_b = JSGlobalContextCreateInGroup(group, NULL);
    if (!group || !realm_a || !realm_b)
        return 1;

    JSValueRef exception = NULL;
    JSValueRef shared_object = evaluate(realm_a, "({ answer: 42 })");
    JSStringRef shared_name = JSStringCreateWithUTF8CString("sharedFromA");
    JSObjectSetProperty(realm_b, JSContextGetGlobalObject(realm_b), shared_name,
        shared_object, kJSPropertyAttributeNone, &exception);
    JSValueRef group_answer = evaluate(realm_b, "sharedFromA.answer");
    int distinct_globals = !JSValueIsStrictEqual(realm_b,
        JSContextGetGlobalObject(realm_a), JSContextGetGlobalObject(realm_b));
    int same_group = JSContextGetGroup(realm_a) == group &&
        JSContextGetGroup(realm_b) == group;
    int global_context_identity = JSContextGetGlobalContext(realm_a) == realm_a;
    JSGlobalContextRelease(realm_a);
    JSValueRef answer_after_release = evaluate(realm_b, "sharedFromA.answer");
    printf("context-groups %d %d %d %.0f %.0f\n", same_group,
        distinct_globals, global_context_identity,
        JSValueToNumber(realm_b, group_answer, &exception),
        JSValueToNumber(realm_b, answer_after_release, &exception));
    JSStringRelease(shared_name);
    JSContextGroupRelease(group);
    JSGlobalContextRelease(realm_b);

    JSStaticValue values[] = {
        { "globalValue", global_value, NULL, kJSPropertyAttributeNone },
        { NULL, NULL, NULL, kJSPropertyAttributeNone }
    };
    JSClassDefinition definition = kJSClassDefinitionEmpty;
    definition.className = "CustomGlobal";
    definition.staticValues = values;
    definition.initialize = global_initialize;
    definition.finalize = global_finalize;
    JSClassRef global_class = JSClassCreate(&definition);
    JSGlobalContextRef custom = JSGlobalContextCreate(global_class);
    JSClassRelease(global_class);
    JSStringRef value_name = JSStringCreateWithUTF8CString("globalValue");
    JSValueRef value = JSObjectGetProperty(custom, JSContextGetGlobalObject(custom),
        value_name, &exception);
    double number = JSValueToNumber(custom, value, &exception);
    JSStringRelease(value_name);
    JSGlobalContextRelease(custom);
    printf("global-class %d %.0f %d\n", initialized, number, finalized);
    return exception ? 2 : 0;
}
