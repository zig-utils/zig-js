#include <JavaScriptCore/JavaScript.h>

#include <stdint.h>
#include <stdlib.h>

static unsigned deallocations;
static unsigned class_events[4];
static unsigned class_event_count;
static int private_token;

static void parent_initialize(JSContextRef context, JSObjectRef object)
{
    (void)context;
    if (JSObjectGetPrivate(object) == &private_token)
        class_events[class_event_count++] = 1;
}

static void child_initialize(JSContextRef context, JSObjectRef object)
{
    (void)context;
    (void)object;
    class_events[class_event_count++] = 2;
}

static void parent_finalize(JSObjectRef object)
{
    (void)object;
    class_events[class_event_count++] = 4;
}

static void child_finalize(JSObjectRef object)
{
    (void)object;
    class_events[class_event_count++] = 3;
}

static JSValueRef class_static_function(JSContextRef context, JSObjectRef function,
    JSObjectRef this_object, size_t argument_count, const JSValueRef arguments[], JSValueRef* exception)
{
    (void)function;
    (void)argument_count;
    (void)arguments;
    (void)exception;
    return JSValueMakeBoolean(context, JSObjectGetPrivate(this_object) == &private_token);
}

static void release_bytes(void* bytes, void* context)
{
    unsigned* count = (unsigned*)context;
    ++*count;
    free(bytes);
}

int main(void)
{
    JSGlobalContextRef context = JSGlobalContextCreate(NULL);
    if (!context)
        return 1;
    if (JSContextGetGlobalContext(context) != context)
        return 9;

    JSStringRef context_name = JSStringCreateWithUTF8CString("c-smoke");
    JSGlobalContextSetName(context, context_name);
    JSStringRelease(context_name);
    JSStringRef copied_name = JSGlobalContextCopyName(context);
    if (!copied_name || !JSStringIsEqualToUTF8CString(copied_name, "c-smoke"))
        return 10;
    JSStringRelease(copied_name);

    JSStringRef source = JSStringCreateWithUTF8CString("21 * 2");
    JSValueRef exception = NULL;
    if (!JSCheckScriptSyntax(context, source, NULL, 1, &exception) || exception)
        return 11;
    JSValueRef answer = JSEvaluateScript(context, source, NULL, NULL, 1, &exception);
    JSStringRelease(source);
    if (!answer || exception || JSValueToNumber(context, answer, &exception) != 42.0)
        return 2;
    JSValueProtect(context, answer);
    JSValueUnprotect(context, answer);

    JSStringRef symbol_description = JSStringCreateWithUTF8CString("smoke");
    JSValueRef symbol = JSValueMakeSymbol(context, symbol_description);
    JSStringRelease(symbol_description);
    if (!symbol || !JSValueIsSymbol(context, symbol) || JSValueIsBigInt(context, symbol))
        return 12;
    JSValueRef bigint = JSBigIntCreateWithUInt64(context, UINT64_MAX, &exception);
    if (!bigint || exception || !JSValueIsBigInt(context, bigint))
        return 13;

    JSStringRef json = JSStringCreateWithUTF8CString("{\"ok\":true}");
    JSValueRef parsed_json = JSValueMakeFromJSONString(context, json);
    JSStringRelease(json);
    JSStringRef rendered_json = JSValueCreateJSONString(context, parsed_json, 2, &exception);
    if (!parsed_json || !rendered_json || exception ||
        !JSStringIsEqualToUTF8CString(rendered_json, "{\n  \"ok\": true\n}"))
        return 14;
    JSStringRelease(rendered_json);
    if (JSValueToInt32(context, JSValueMakeNumber(context, 4294967297.0), &exception) != 1 ||
        JSValueToUInt64(context, bigint, &exception) != UINT64_MAX)
        return 15;
    if (JSValueCompareInt64(context, answer, 42, &exception) != kJSRelationConditionEqual ||
        JSValueCompareDouble(context, answer, 41.5, &exception) != kJSRelationConditionGreaterThan)
        return 16;
    JSStringRef array_name = JSStringCreateWithUTF8CString("Array");
    JSObjectRef array_ctor = (JSObjectRef)JSObjectGetProperty(
        context, JSContextGetGlobalObject(context), array_name, &exception);
    JSStringRelease(array_name);
    JSObjectRef array = JSObjectMakeArray(context, 0, NULL, &exception);
    if (!array_ctor || !array || !JSValueIsInstanceOfConstructor(context, array, array_ctor, &exception))
        return 17;

    JSClassDefinition parent_definition = kJSClassDefinitionEmpty;
    parent_definition.className = "Parent";
    parent_definition.initialize = parent_initialize;
    parent_definition.finalize = parent_finalize;
    JSClassRef parent_class = JSClassCreate(&parent_definition);
    JSClassDefinition child_definition = kJSClassDefinitionEmpty;
    child_definition.className = "Child";
    child_definition.parentClass = parent_class;
    child_definition.initialize = child_initialize;
    child_definition.finalize = child_finalize;
    JSClassRef child_class = JSClassCreate(&child_definition);
    if (!parent_class || !child_class || JSClassRetain(child_class) != child_class)
        return 18;
    JSClassRelease(child_class);

    JSStaticFunction static_functions[] = {
        { "checkThis", class_static_function, kJSPropertyAttributeNone },
        { NULL, NULL, 0 }
    };
    JSClassDefinition static_definition = kJSClassDefinitionEmpty;
    static_definition.className = "StaticClass";
    static_definition.staticFunctions = static_functions;
    JSClassRef static_class = JSClassCreate(&static_definition);
    if (!static_class)
        return 28;
    JSObjectRef static_a = JSObjectMake(context, static_class, &private_token);
    JSObjectRef static_b = JSObjectMake(context, static_class, NULL);
    JSStringRef check_this_name = JSStringCreateWithUTF8CString("checkThis");
    JSValueRef static_a_function = JSObjectGetProperty(context, static_a, check_this_name, &exception);
    JSValueRef static_b_function = JSObjectGetProperty(context, static_b, check_this_name, &exception);
    if (!static_a || !static_b || exception ||
        !JSValueIsStrictEqual(context, static_a_function, static_b_function) ||
        !JSValueToBoolean(context, JSObjectCallAsFunction(context,
            (JSObjectRef)static_a_function, static_a, 0, NULL, &exception)))
        return 28;
    JSClassRelease(static_class);

    JSClassDefinition direct_definition = static_definition;
    direct_definition.attributes = kJSClassAttributeNoAutomaticPrototype;
    JSClassRef direct_class = JSClassCreate(&direct_definition);
    if (!direct_class)
        return 29;
    JSObjectRef direct_a = JSObjectMake(context, direct_class, &private_token);
    JSObjectRef direct_b = JSObjectMake(context, direct_class, NULL);
    JSValueRef direct_a_function = JSObjectGetProperty(context, direct_a, check_this_name, &exception);
    JSValueRef direct_b_function = JSObjectGetProperty(context, direct_b, check_this_name, &exception);
    if (!direct_a || !direct_b || exception ||
        JSValueIsStrictEqual(context, direct_a_function, direct_b_function))
        return 29;
    JSClassRelease(direct_class);
    JSStringRelease(check_this_name);
    JSClassRelease(parent_class);
    JSObjectRef class_object = JSObjectMake(context, child_class, &private_token);
    if (!class_object || class_event_count != 2 || class_events[0] != 1 || class_events[1] != 2)
        return 19;
    if (!JSValueIsObjectOfClass(context, class_object, child_class) ||
        !JSValueIsObjectOfClass(context, class_object, parent_class) ||
        JSObjectGetPrivate(class_object) != &private_token)
        return 20;
    JSClassRelease(child_class);

    JSObjectRef prototype = JSObjectMake(context, NULL, NULL);
    JSObjectRef prototyped = JSObjectMake(context, NULL, NULL);
    JSStringRef inherited_name = JSStringCreateWithUTF8CString("inherited");
    JSObjectSetProperty(context, prototype, inherited_name, answer, kJSPropertyAttributeNone, &exception);
    JSObjectSetPrototype(context, prototyped, prototype);
    if (!prototype || !prototyped || !JSValueIsStrictEqual(context, JSObjectGetPrototype(context, prototyped), prototype) ||
        !JSObjectHasProperty(context, prototyped, inherited_name))
        return 22;
    JSStringRelease(inherited_name);
    JSObjectSetPropertyAtIndex(context, prototyped, 3, answer, &exception);
    if (exception || JSValueToNumber(context,
            JSObjectGetPropertyAtIndex(context, prototyped, 3, &exception), &exception) != 42.0)
        return 23;
    JSStringRef temporary_name = JSStringCreateWithUTF8CString("temporary");
    JSObjectSetProperty(context, prototyped, temporary_name, answer, kJSPropertyAttributeNone, &exception);
    if (!JSObjectDeleteProperty(context, prototyped, temporary_name, &exception) ||
        JSObjectHasProperty(context, prototyped, temporary_name))
        return 24;
    JSStringRelease(temporary_name);
    JSStringRef locked_name = JSStringCreateWithUTF8CString("locked");
    JSObjectSetProperty(context, prototyped, locked_name, answer, kJSPropertyAttributeDontDelete, &exception);
    if (JSObjectDeleteProperty(context, prototyped, locked_name, &exception) || exception)
        return 25;
    JSStringRelease(locked_name);

    JSStringRef symbol_object_source = JSStringCreateWithUTF8CString(
        "(() => { const key = Symbol('key'); return [{ [key]: 42 }, key]; })()");
    JSValueRef symbol_object_pair = JSEvaluateScript(
        context, symbol_object_source, NULL, NULL, 1, &exception);
    JSStringRelease(symbol_object_source);
    JSObjectRef symbol_object = (JSObjectRef)JSObjectGetPropertyAtIndex(
        context, (JSObjectRef)symbol_object_pair, 0, &exception);
    JSValueRef symbol_key = JSObjectGetPropertyAtIndex(
        context, (JSObjectRef)symbol_object_pair, 1, &exception);
    if (!symbol_object || !symbol_key || exception ||
        !JSObjectHasPropertyForKey(context, symbol_object, symbol_key, &exception) ||
        JSValueToNumber(context,
            JSObjectGetPropertyForKey(context, symbol_object, symbol_key, &exception), &exception) != 42.0)
        return 26;
    if (!JSObjectDeletePropertyForKey(context, symbol_object, symbol_key, &exception) ||
        JSObjectHasPropertyForKey(context, symbol_object, symbol_key, &exception) || exception)
        return 27;

    const JSChar utf16[] = { 'z', 'i', 'g', 0xd83d, 0xde00 };
    JSStringRef wide = JSStringCreateWithCharacters(utf16, 5);
    if (!wide || JSStringGetLength(wide) != 5 ||
        JSStringGetMaximumUTF8CStringSize(wide) != 16 ||
        JSStringGetCharactersPtr(wide)[4] != 0xde00 ||
        !JSStringIsEqualToUTF8CString(wide, "zig\xf0\x9f\x98\x80"))
        return 8;
    JSStringRelease(wide);

    uint8_t* bytes = (uint8_t*)malloc(8);
    if (!bytes)
        return 3;
    bytes[0] = 0x2a;
    JSObjectRef buffer = JSObjectMakeArrayBufferWithBytesNoCopy(
        context, bytes, 8, release_bytes, &deallocations, &exception);
    if (!buffer || exception || JSObjectGetArrayBufferByteLength(context, buffer, &exception) != 8)
        return 4;
    if (((uint8_t*)JSObjectGetArrayBufferBytesPtr(context, buffer, &exception))[0] != 0x2a)
        return 5;

    JSObjectRef view = JSObjectMakeTypedArrayWithArrayBuffer(
        context, kJSTypedArrayTypeUint8Array, buffer, &exception);
    if (!view || exception || JSObjectGetTypedArrayLength(context, view, &exception) != 8)
        return 6;

    JSGlobalContextRelease(context);
    if (class_event_count != 4 || class_events[2] != 3 || class_events[3] != 4)
        return 21;
    return deallocations == 1 ? 0 : 7;
}
