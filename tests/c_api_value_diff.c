#include <JavaScriptCore/JavaScript.h>

#include <inttypes.h>
#include <math.h>
#include <stdio.h>

static JSValueRef evaluate(JSContextRef context, const char* source)
{
    JSStringRef script = JSStringCreateWithUTF8CString(source);
    JSValueRef exception = NULL;
    JSValueRef result = JSEvaluateScript(context, script, NULL, NULL, 1, &exception);
    JSStringRelease(script);
    return exception ? NULL : result;
}

static JSValueRef static_function(JSContextRef context, JSObjectRef function,
    JSObjectRef this_object, size_t argument_count, const JSValueRef arguments[], JSValueRef* exception)
{
    (void)function;
    (void)this_object;
    (void)argument_count;
    (void)arguments;
    (void)exception;
    return JSValueMakeNumber(context, 17);
}

static double static_value_storage = 1;
static JSValueRef static_get_seven(JSContextRef context, JSObjectRef object,
    JSStringRef property_name, JSValueRef* exception)
{
    (void)object; (void)property_name; (void)exception;
    return JSValueMakeNumber(context, 7);
}
static JSValueRef static_get_stored(JSContextRef context, JSObjectRef object,
    JSStringRef property_name, JSValueRef* exception)
{
    (void)object; (void)property_name; (void)exception;
    return JSValueMakeNumber(context, static_value_storage);
}
static JSValueRef static_get_null(JSContextRef context, JSObjectRef object,
    JSStringRef property_name, JSValueRef* exception)
{
    (void)context; (void)object; (void)property_name; (void)exception;
    return NULL;
}
static bool static_set_false(JSContextRef context, JSObjectRef object,
    JSStringRef property_name, JSValueRef value, JSValueRef* exception)
{
    (void)object; (void)property_name;
    static_value_storage = JSValueToNumber(context, value, exception);
    return false;
}
static bool static_set_true(JSContextRef context, JSObjectRef object,
    JSStringRef property_name, JSValueRef value, JSValueRef* exception)
{
    (void)object; (void)property_name;
    static_value_storage = JSValueToNumber(context, value, exception);
    return true;
}

static int print_json_string(JSStringRef string)
{
    char bytes[512];
    size_t length = JSStringGetUTF8CString(string, bytes, sizeof(bytes));
    if (!length)
        return 0;
    for (size_t index = 0; index + 1 < length; ++index) {
        unsigned char byte = (unsigned char)bytes[index];
        if (byte == '\n')
            fputs("\\n", stdout);
        else if (byte == '\r')
            fputs("\\r", stdout);
        else if (byte == '\t')
            fputs("\\t", stdout);
        else
            fputc(byte, stdout);
    }
    return 1;
}

int main(void)
{
    JSGlobalContextRef context = JSGlobalContextCreate(NULL);
    JSValueRef exception = NULL;
    if (!context)
        return 1;

    JSStringRef description = JSStringCreateWithUTF8CString("value-diff");
    JSValueRef symbol_a = JSValueMakeSymbol(context, description);
    JSValueRef symbol_b = JSValueMakeSymbol(context, description);
    JSStringRelease(description);
    printf("symbols %d %d %d\n", JSValueIsSymbol(context, symbol_a),
        JSValueIsBigInt(context, symbol_a), JSValueIsStrictEqual(context, symbol_a, symbol_b));

    JSStringRef big_text = JSStringCreateWithUTF8CString("18446744073709551617");
    JSValueRef bigint = JSBigIntCreateWithString(context, big_text, &exception);
    JSStringRelease(big_text);
    printf("bigint %d %" PRIu32 " %" PRIu64 " %.17g\n", JSValueIsBigInt(context, bigint),
        JSValueToUInt32(context, bigint, &exception),
        JSValueToUInt64(context, bigint, &exception),
        JSValueToNumber(context, bigint, &exception));

    JSValueRef negative = JSValueMakeNumber(context, -1.5);
    JSValueRef two63 = JSValueMakeNumber(context, 9223372036854775808.0);
    printf("integers %" PRId32 " %" PRIu32 " %" PRId64 " %" PRIu64 "\n",
        JSValueToInt32(context, negative, &exception),
        JSValueToUInt32(context, negative, &exception),
        JSValueToInt64(context, two63, &exception),
        JSValueToUInt64(context, two63, &exception));

    printf("relations %d %d %d\n",
        JSValueCompareInt64(context, JSValueMakeNumber(context, 1.5), 1, &exception),
        JSValueCompareDouble(context, JSValueMakeNumber(context, NAN), 0, &exception),
        JSValueCompareUInt64(context, bigint, 1, &exception));

    JSStringRef json_text = JSStringCreateWithUTF8CString("{\"b\":[true,null],\"a\":1}");
    JSValueRef json = JSValueMakeFromJSONString(context, json_text);
    JSStringRelease(json_text);
    JSStringRef rendered = JSValueCreateJSONString(context, json, 2, &exception);
    fputs("json ", stdout);
    if (!rendered || !print_json_string(rendered))
        return 2;
    fputc('\n', stdout);
    JSStringRelease(rendered);

    JSValueRef pair = evaluate(context, "class DiffCtor {}; [new DiffCtor(), DiffCtor]");
    JSValueRef instance = JSObjectGetPropertyAtIndex(context, (JSObjectRef)pair, 0, &exception);
    JSObjectRef constructor = (JSObjectRef)JSObjectGetPropertyAtIndex(context, (JSObjectRef)pair, 1, &exception);
    printf("instanceof %d\n", JSValueIsInstanceOfConstructor(context, instance, constructor, &exception));

    JSClassDefinition parent_definition = kJSClassDefinitionEmpty;
    parent_definition.className = "DiffParent";
    JSClassRef parent_class = JSClassCreate(&parent_definition);
    JSClassDefinition child_definition = kJSClassDefinitionEmpty;
    child_definition.className = "DiffChild";
    child_definition.parentClass = parent_class;
    JSClassRef child_class = JSClassCreate(&child_definition);
    JSObjectRef class_object = JSObjectMake(context, child_class, NULL);
    JSObjectRef plain_object = JSObjectMake(context, NULL, NULL);
    printf("classes %d %d %d\n",
        JSValueIsObjectOfClass(context, class_object, child_class),
        JSValueIsObjectOfClass(context, class_object, parent_class),
        JSValueIsObjectOfClass(context, plain_object, child_class));
    JSClassRelease(parent_class);
    JSClassRelease(child_class);

    JSStaticFunction static_functions[] = {
        { "run", static_function, kJSPropertyAttributeNone }, { NULL, NULL, 0 }
    };
    JSClassDefinition static_definition = kJSClassDefinitionEmpty;
    static_definition.staticFunctions = static_functions;
    JSClassRef static_class = JSClassCreate(&static_definition);
    JSObjectRef static_a = JSObjectMake(context, static_class, NULL);
    JSObjectRef static_b = JSObjectMake(context, static_class, NULL);
    JSStringRef run_name = JSStringCreateWithUTF8CString("run");
    JSValueRef static_fn_a = JSObjectGetProperty(context, static_a, run_name, &exception);
    JSValueRef static_fn_b = JSObjectGetProperty(context, static_b, run_name, &exception);
    JSClassDefinition direct_definition = static_definition;
    direct_definition.attributes = kJSClassAttributeNoAutomaticPrototype;
    JSClassRef direct_class = JSClassCreate(&direct_definition);
    JSObjectRef direct_a = JSObjectMake(context, direct_class, NULL);
    JSObjectRef direct_b = JSObjectMake(context, direct_class, NULL);
    JSValueRef direct_fn_a = JSObjectGetProperty(context, direct_a, run_name, &exception);
    JSValueRef direct_fn_b = JSObjectGetProperty(context, direct_b, run_name, &exception);
    printf("static-functions %d %d %.0f\n",
        JSValueIsStrictEqual(context, static_fn_a, static_fn_b),
        JSValueIsStrictEqual(context, direct_fn_a, direct_fn_b),
        JSValueToNumber(context, JSObjectCallAsFunction(context,
            (JSObjectRef)static_fn_a, static_a, 0, NULL, &exception), &exception));
    JSStringRelease(run_name);
    JSClassRelease(static_class);
    JSClassRelease(direct_class);

    JSStaticValue static_values[] = {
        { "x", static_get_seven, static_set_false, kJSPropertyAttributeNone },
        { "y", static_get_stored, static_set_true, kJSPropertyAttributeNone },
        { "z", static_get_null, NULL, kJSPropertyAttributeNone },
        { "hidden", static_get_seven, NULL, kJSPropertyAttributeDontEnum },
        { NULL, NULL, NULL, 0 }
    };
    JSClassDefinition value_definition = kJSClassDefinitionEmpty;
    value_definition.staticValues = static_values;
    JSClassRef value_class = JSClassCreate(&value_definition);
    JSObjectRef value_object = JSObjectMake(context, value_class, NULL);
    JSStringRef x_name = JSStringCreateWithUTF8CString("x");
    JSStringRef y_name = JSStringCreateWithUTF8CString("y");
    JSStringRef z_name = JSStringCreateWithUTF8CString("z");
    printf("static-values %.0f %.0f %d %d ",
        JSValueToNumber(context, JSObjectGetProperty(context, value_object, x_name, &exception), &exception),
        JSValueToNumber(context, JSObjectGetProperty(context, value_object, y_name, &exception), &exception),
        JSObjectHasProperty(context, value_object, x_name),
        JSObjectHasProperty(context, value_object, z_name));
    JSObjectSetProperty(context, value_object, x_name,
        JSValueMakeNumber(context, 12), kJSPropertyAttributeNone, &exception);
    JSObjectSetProperty(context, value_object, y_name,
        JSValueMakeNumber(context, 15), kJSPropertyAttributeNone, &exception);
    printf("%.0f %.0f\n",
        JSValueToNumber(context, JSObjectGetProperty(context, value_object, x_name, &exception), &exception),
        JSValueToNumber(context, JSObjectGetProperty(context, value_object, y_name, &exception), &exception));
    JSObjectRef js_value_object = JSObjectMake(context, value_class, NULL);
    JSStringRef js_value_name = JSStringCreateWithUTF8CString("valueObject");
    JSObjectSetProperty(context, JSContextGetGlobalObject(context), js_value_name,
        js_value_object, kJSPropertyAttributeNone, &exception);
    JSStringRelease(js_value_name);
    JSValueRef js_static_result = evaluate(context,
        "valueObject.x=22; valueObject.y=25; JSON.stringify([valueObject.x,valueObject.y,Object.hasOwn(valueObject,'x'),Object.hasOwn(valueObject,'y'),Object.hasOwn(valueObject,'z')])");
    JSStringRef js_static_string = JSValueToStringCopy(context, js_static_result, &exception);
    fputs("static-js ", stdout);
    if (!js_static_string || !print_json_string(js_static_string))
        return 4;
    fputc('\n', stdout);
    JSStringRelease(js_static_string);
    JSValueRef js_static_keys = evaluate(context,
        "JSON.stringify([Object.keys(valueObject),valueObject.propertyIsEnumerable('x'),valueObject.propertyIsEnumerable('hidden'),valueObject.propertyIsEnumerable('z')])");
    JSStringRef js_static_keys_string = JSValueToStringCopy(context, js_static_keys, &exception);
    fputs("static-keys ", stdout);
    if (!js_static_keys_string || !print_json_string(js_static_keys_string))
        return 5;
    fputc('\n', stdout);
    JSStringRelease(js_static_keys_string);
    JSValueRef js_static_descriptors = evaluate(context,
        "JSON.stringify([Object.getOwnPropertyDescriptor(valueObject,'x')??null,Reflect.ownKeys(valueObject).sort()])");
    JSStringRef js_static_descriptors_string = JSValueToStringCopy(context, js_static_descriptors, &exception);
    fputs("static-reflection ", stdout);
    if (!js_static_descriptors_string || !print_json_string(js_static_descriptors_string))
        return 6;
    fputc('\n', stdout);
    JSStringRelease(js_static_descriptors_string);
    JSStringRelease(x_name); JSStringRelease(y_name); JSStringRelease(z_name);
    JSClassRelease(value_class);

    JSObjectRef prototype = JSObjectMake(context, NULL, NULL);
    JSObjectRef object = JSObjectMake(context, NULL, NULL);
    JSStringRef inherited_name = JSStringCreateWithUTF8CString("inherited");
    JSObjectSetProperty(context, prototype, inherited_name,
        JSValueMakeNumber(context, 11), kJSPropertyAttributeNone, &exception);
    JSObjectSetPrototype(context, object, prototype);
    JSObjectSetPropertyAtIndex(context, object, 4, JSValueMakeNumber(context, 42), &exception);
    JSStringRef temporary_name = JSStringCreateWithUTF8CString("temporary");
    JSObjectSetProperty(context, object, temporary_name,
        JSValueMakeBoolean(context, true), kJSPropertyAttributeNone, &exception);
    int deleted = JSObjectDeleteProperty(context, object, temporary_name, &exception);
    printf("objects %d %d %.0f %d %d\n",
        JSValueIsStrictEqual(context, JSObjectGetPrototype(context, object), prototype),
        JSObjectHasProperty(context, object, inherited_name),
        JSValueToNumber(context, JSObjectGetPropertyAtIndex(context, object, 4, &exception), &exception),
        deleted, JSObjectHasProperty(context, object, temporary_name));
    JSStringRelease(inherited_name);
    JSStringRelease(temporary_name);

    JSValueRef symbol_pair = evaluate(context,
        "(() => { const key = Symbol('key'); return [{ [key]: 13 }, key]; })()");
    JSObjectRef symbol_object = (JSObjectRef)JSObjectGetPropertyAtIndex(
        context, (JSObjectRef)symbol_pair, 0, &exception);
    JSValueRef symbol_key = JSObjectGetPropertyAtIndex(
        context, (JSObjectRef)symbol_pair, 1, &exception);
    int symbol_has = JSObjectHasPropertyForKey(context, symbol_object, symbol_key, &exception);
    double symbol_value = JSValueToNumber(context,
        JSObjectGetPropertyForKey(context, symbol_object, symbol_key, &exception), &exception);
    int symbol_deleted = JSObjectDeletePropertyForKey(
        context, symbol_object, symbol_key, &exception);
    printf("property-keys %d %.0f %d %d\n", symbol_has, symbol_value,
        symbol_deleted, JSObjectHasPropertyForKey(context, symbol_object, symbol_key, &exception));

    JSValueProtect(context, json);
    JSValueUnprotect(context, json);
    if (exception)
        return 3;
    JSGlobalContextRelease(context);
    return 0;
}
