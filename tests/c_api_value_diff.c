#include <JavaScriptCore/JavaScript.h>

#include <inttypes.h>
#include <math.h>
#include <stdio.h>

static int print_json_string(JSStringRef string);

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

static int delete_callback_calls;
static int parent_delete_callback_calls;
static bool class_delete(JSContextRef context, JSObjectRef object,
    JSStringRef property_name, JSValueRef* exception)
{
    (void)object;
    ++delete_callback_calls;
    if (JSStringIsEqualToUTF8CString(property_name, "throw")) {
        *exception = JSValueMakeNumber(context, 99);
        return false;
    }
    return JSStringIsEqualToUTF8CString(property_name, "handled");
}
static bool parent_class_delete(JSContextRef context, JSObjectRef object,
    JSStringRef property_name, JSValueRef* exception)
{
    (void)context; (void)object; (void)exception;
    ++parent_delete_callback_calls;
    return JSStringIsEqualToUTF8CString(property_name, "parent");
}

static int has_callback_calls;
static int get_callback_calls;
static int set_callback_calls;
static double dynamic_set_storage;
static bool class_has(JSContextRef context, JSObjectRef object, JSStringRef property_name)
{
    (void)context; (void)object;
    ++has_callback_calls;
    return JSStringIsEqualToUTF8CString(property_name, "present") ||
        JSStringIsEqualToUTF8CString(property_name, "throwGet");
}
static JSValueRef class_get(JSContextRef context, JSObjectRef object,
    JSStringRef property_name, JSValueRef* exception)
{
    (void)object; (void)exception;
    ++get_callback_calls;
    if (JSStringIsEqualToUTF8CString(property_name, "throwGet")) {
        *exception = JSValueMakeNumber(context, 91);
        return NULL;
    }
    if (JSStringIsEqualToUTF8CString(property_name, "present"))
        return JSValueMakeNumber(context, 31);
    if (JSStringIsEqualToUTF8CString(property_name, "getOnly"))
        return JSValueMakeNumber(context, 32);
    if (JSStringIsEqualToUTF8CString(property_name, "handledSet"))
        return JSValueMakeNumber(context, dynamic_set_storage);
    return NULL;
}
static bool class_set(JSContextRef context, JSObjectRef object,
    JSStringRef property_name, JSValueRef value, JSValueRef* exception)
{
    (void)object;
    ++set_callback_calls;
    if (JSStringIsEqualToUTF8CString(property_name, "throwSet")) {
        *exception = JSValueMakeNumber(context, 92);
        return false;
    }
    if (JSStringIsEqualToUTF8CString(property_name, "handledSet")) {
        dynamic_set_storage = JSValueToNumber(context, value, exception);
        return true;
    }
    return false;
}

static void class_property_names(JSContextRef context, JSObjectRef object,
    JSPropertyNameAccumulatorRef names)
{
    (void)context; (void)object;
    JSStringRef virtual_name = JSStringCreateWithUTF8CString("virtual");
    JSStringRef duplicate_name = JSStringCreateWithUTF8CString("own");
    JSPropertyNameAccumulatorAddName(names, virtual_name);
    JSPropertyNameAccumulatorAddName(names, duplicate_name);
    JSPropertyNameAccumulatorAddName(names, virtual_name);
    JSStringRelease(virtual_name);
    JSStringRelease(duplicate_name);
}

static JSValueRef class_call(JSContextRef context, JSObjectRef function,
    JSObjectRef this_object, size_t argument_count, const JSValueRef arguments[],
    JSValueRef* exception)
{
    (void)function; (void)this_object;
    double first = argument_count ? JSValueToNumber(context, arguments[0], exception) : 0;
    if (first == -1) {
        *exception = JSValueMakeNumber(context, 93);
        return NULL;
    }
    return JSValueMakeNumber(context, 70 + first);
}

static JSObjectRef class_construct(JSContextRef context, JSObjectRef constructor,
    size_t argument_count, const JSValueRef arguments[], JSValueRef* exception)
{
    (void)constructor;
    if (argument_count && JSValueToNumber(context, arguments[0], exception) == -1) {
        *exception = JSValueMakeNumber(context, 94);
        return NULL;
    }
    JSObjectRef result = JSObjectMake(context, NULL, NULL);
    JSStringRef name = JSStringCreateWithUTF8CString("constructed");
    JSValueRef value = argument_count ? arguments[0] : JSValueMakeNumber(context, 0);
    JSObjectSetProperty(context, result, name, value,
        kJSPropertyAttributeNone, exception);
    JSStringRelease(name);
    return result;
}

static bool class_has_instance(JSContextRef context, JSObjectRef constructor,
    JSValueRef possible_instance, JSValueRef* exception)
{
    (void)constructor;
    double candidate = JSValueToNumber(context, possible_instance, exception);
    if (candidate == -1) {
        *exception = JSValueMakeNumber(context, 95);
        return false;
    }
    return candidate == 42;
}

static int throw_convert;
static JSValueRef class_convert(JSContextRef context, JSObjectRef object,
    JSType type, JSValueRef* exception)
{
    (void)object; (void)exception;
    if (throw_convert) {
        *exception = JSValueMakeNumber(context, 96);
        return NULL;
    }
    if (type == kJSTypeString) {
        JSStringRef text = JSStringCreateWithUTF8CString("converted");
        JSValueRef result = JSValueMakeString(context, text);
        JSStringRelease(text);
        return result;
    }
    return JSValueMakeNumber(context, 88);
}

static int print_property_names(JSPropertyNameArrayRef names)
{
    printf("%zu", JSPropertyNameArrayGetCount(names));
    for (size_t index = 0; index < JSPropertyNameArrayGetCount(names); ++index) {
        fputc(' ', stdout);
        if (!print_json_string(JSPropertyNameArrayGetNameAtIndex(names, index)))
            return 0;
    }
    return 1;
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
        { "locked", static_get_seven, NULL, kJSPropertyAttributeDontDelete },
        { NULL, NULL, NULL, 0 }
    };
    JSClassDefinition value_definition = kJSClassDefinitionEmpty;
    value_definition.staticValues = static_values;
    value_definition.hasProperty = class_has;
    value_definition.setProperty = class_set;
    value_definition.deleteProperty = class_delete;
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
        "JSON.stringify([Object.keys(valueObject).sort(),valueObject.propertyIsEnumerable('x'),valueObject.propertyIsEnumerable('hidden'),valueObject.propertyIsEnumerable('z')])");
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
    JSValueRef js_static_delete = evaluate(context,
        "JSON.stringify([delete valueObject.x,valueObject.x,Object.hasOwn(valueObject,'x'),delete valueObject.locked,valueObject.locked,Object.hasOwn(valueObject,'locked'),delete valueObject.z,Object.hasOwn(valueObject,'z'),Reflect.ownKeys(valueObject).sort()])");
    JSStringRef js_static_delete_string = JSValueToStringCopy(context, js_static_delete, &exception);
    fputs("static-delete ", stdout);
    if (!js_static_delete_string || !print_json_string(js_static_delete_string))
        return 7;
    fputc('\n', stdout);
    JSStringRelease(js_static_delete_string);
    printf("static-delete-callbacks %d\n", delete_callback_calls);
    printf("static-property-callbacks %d\n", has_callback_calls);
    printf("static-set-callbacks %d\n", set_callback_calls);
    JSStringRelease(x_name); JSStringRelease(y_name); JSStringRelease(z_name);
    JSClassRelease(value_class);

    JSClassDefinition delete_parent_definition = kJSClassDefinitionEmpty;
    delete_parent_definition.deleteProperty = parent_class_delete;
    JSClassRef delete_parent_class = JSClassCreate(&delete_parent_definition);
    JSClassDefinition delete_definition = kJSClassDefinitionEmpty;
    delete_definition.parentClass = delete_parent_class;
    delete_definition.deleteProperty = class_delete;
    delete_callback_calls = 0;
    parent_delete_callback_calls = 0;
    JSClassRef delete_class = JSClassCreate(&delete_definition);
    JSClassRelease(delete_parent_class);
    JSObjectRef delete_object = JSObjectMake(context, delete_class, NULL);
    JSStringRef handled_name = JSStringCreateWithUTF8CString("handled");
    JSStringRef fallback_name = JSStringCreateWithUTF8CString("fallback");
    JSStringRef parent_name = JSStringCreateWithUTF8CString("parent");
    JSStringRef throw_name = JSStringCreateWithUTF8CString("throw");
    JSObjectSetProperty(context, delete_object, handled_name,
        JSValueMakeNumber(context, 1), kJSPropertyAttributeNone, &exception);
    JSObjectSetProperty(context, delete_object, fallback_name,
        JSValueMakeNumber(context, 2), kJSPropertyAttributeNone, &exception);
    JSObjectSetProperty(context, delete_object, parent_name,
        JSValueMakeNumber(context, 3), kJSPropertyAttributeNone, &exception);
    JSObjectSetProperty(context, delete_object, throw_name,
        JSValueMakeNumber(context, 4), kJSPropertyAttributeNone, &exception);
    int handled_deleted = JSObjectDeleteProperty(context, delete_object, handled_name, &exception);
    int fallback_deleted = JSObjectDeleteProperty(context, delete_object, fallback_name, &exception);
    int parent_deleted = JSObjectDeleteProperty(context, delete_object, parent_name, &exception);
    exception = NULL;
    int throw_deleted = JSObjectDeleteProperty(context, delete_object, throw_name, &exception);
    printf("class-delete %d %d %d %d %d %d %d %d %d %d %.0f\n",
        handled_deleted, fallback_deleted, parent_deleted, throw_deleted,
        JSObjectHasProperty(context, delete_object, handled_name),
        JSObjectHasProperty(context, delete_object, fallback_name),
        JSObjectHasProperty(context, delete_object, parent_name),
        JSObjectHasProperty(context, delete_object, throw_name),
        delete_callback_calls, parent_delete_callback_calls,
        JSValueToNumber(context, exception, NULL));
    exception = NULL;
    JSStringRelease(handled_name); JSStringRelease(fallback_name);
    JSStringRelease(parent_name); JSStringRelease(throw_name);
    JSClassRelease(delete_class);

    JSClassDefinition property_definition = kJSClassDefinitionEmpty;
    has_callback_calls = 0;
    get_callback_calls = 0;
    set_callback_calls = 0;
    property_definition.hasProperty = class_has;
    property_definition.getProperty = class_get;
    property_definition.setProperty = class_set;
    JSClassRef property_class = JSClassCreate(&property_definition);
    JSObjectRef property_object = JSObjectMake(context, property_class, NULL);
    JSStringRef property_object_name = JSStringCreateWithUTF8CString("propertyObject");
    JSObjectSetProperty(context, JSContextGetGlobalObject(context), property_object_name,
        property_object, kJSPropertyAttributeNone, &exception);
    JSStringRelease(property_object_name);
    JSStringRef present_name = JSStringCreateWithUTF8CString("present");
    JSStringRef get_only_name = JSStringCreateWithUTF8CString("getOnly");
    JSStringRef has_only_name = JSStringCreateWithUTF8CString("hasOnly");
    JSStringRef handled_set_name = JSStringCreateWithUTF8CString("handledSet");
    JSStringRef fallback_set_name = JSStringCreateWithUTF8CString("fallbackSet");
    int has_present = JSObjectHasProperty(context, property_object, present_name);
    int has_get_only = JSObjectHasProperty(context, property_object, get_only_name);
    JSValueRef present_value = JSObjectGetProperty(context, property_object, present_name, &exception);
    JSValueRef has_only_value = JSObjectGetProperty(context, property_object, has_only_name, &exception);
    JSObjectSetProperty(context, property_object, handled_set_name,
        JSValueMakeNumber(context, 51), kJSPropertyAttributeNone, &exception);
    JSObjectSetProperty(context, property_object, fallback_set_name,
        JSValueMakeNumber(context, 52), kJSPropertyAttributeNone, &exception);
    JSValueRef handled_set_value = JSObjectGetProperty(context, property_object, handled_set_name, &exception);
    JSValueRef fallback_set_value = JSObjectGetProperty(context, property_object, fallback_set_name, &exception);
    printf("class-properties %d %d %.0f %d %.0f %.0f %d %d %d %d\n",
        has_present, has_get_only, JSValueToNumber(context, present_value, &exception),
        JSValueIsUndefined(context, has_only_value),
        JSValueToNumber(context, handled_set_value, &exception),
        JSValueToNumber(context, fallback_set_value, &exception),
        JSObjectHasProperty(context, property_object, fallback_set_name),
        has_callback_calls, get_callback_calls, set_callback_calls);
    JSStringRef throw_get_name = JSStringCreateWithUTF8CString("throwGet");
    JSStringRef throw_set_name = JSStringCreateWithUTF8CString("throwSet");
    exception = NULL;
    JSValueRef throw_get_value = JSObjectGetProperty(context, property_object, throw_get_name, &exception);
    double get_exception = JSValueToNumber(context, exception, NULL);
    exception = NULL;
    JSObjectSetProperty(context, property_object, throw_set_name,
        JSValueMakeNumber(context, 1), kJSPropertyAttributeNone, &exception);
    double set_exception = JSValueToNumber(context, exception, NULL);
    printf("class-property-throws %d %.0f %.0f\n",
        throw_get_value == NULL, get_exception, set_exception);
    exception = NULL;
    JSValueRef property_reflection = evaluate(context,
        "JSON.stringify([Object.hasOwn(propertyObject,'present'),Object.getOwnPropertyDescriptor(propertyObject,'present')??null,propertyObject.propertyIsEnumerable('present'),Object.keys(propertyObject),Reflect.ownKeys(propertyObject).sort()])");
    JSStringRef property_reflection_string = JSValueToStringCopy(context, property_reflection, &exception);
    fputs("class-property-reflection ", stdout);
    if (!property_reflection_string || !print_json_string(property_reflection_string))
        return 8;
    fputc('\n', stdout);
    JSStringRelease(property_reflection_string);
    JSStringRelease(present_name); JSStringRelease(get_only_name);
    JSStringRelease(has_only_name); JSStringRelease(handled_set_name);
    JSStringRelease(fallback_set_name);
    JSStringRelease(throw_get_name); JSStringRelease(throw_set_name);
    JSClassRelease(property_class);

    property_definition.hasProperty = NULL;
    has_callback_calls = 0;
    get_callback_calls = 0;
    set_callback_calls = 0;
    JSClassRef get_only_class = JSClassCreate(&property_definition);
    JSObjectRef get_only_object = JSObjectMake(context, get_only_class, NULL);
    get_only_name = JSStringCreateWithUTF8CString("getOnly");
    handled_set_name = JSStringCreateWithUTF8CString("handledSet");
    JSStringRef missing_name = JSStringCreateWithUTF8CString("missing");
    int get_only_has = JSObjectHasProperty(context, get_only_object, get_only_name);
    int missing_has = JSObjectHasProperty(context, get_only_object, missing_name);
    JSValueRef get_only_value = JSObjectGetProperty(context, get_only_object, get_only_name, &exception);
    JSObjectSetProperty(context, get_only_object, handled_set_name,
        JSValueMakeNumber(context, 61), kJSPropertyAttributeNone, &exception);
    handled_set_value = JSObjectGetProperty(context, get_only_object, handled_set_name, &exception);
    printf("class-get-fallback %d %d %.0f %.0f %d %d\n",
        get_only_has, missing_has,
        JSValueToNumber(context, get_only_value, &exception),
        JSValueToNumber(context, handled_set_value, &exception),
        get_callback_calls, set_callback_calls);
    JSStringRelease(get_only_name); JSStringRelease(handled_set_name);
    JSStringRelease(missing_name);
    JSClassRelease(get_only_class);

    JSClassDefinition names_definition = kJSClassDefinitionEmpty;
    names_definition.getPropertyNames = class_property_names;
    JSClassRef names_class = JSClassCreate(&names_definition);
    JSObjectRef names_object = JSObjectMake(context, names_class, NULL);
    JSObjectRef names_prototype = JSObjectMake(context, NULL, NULL);
    JSStringRef own_name = JSStringCreateWithUTF8CString("own");
    JSStringRef inherited_names_name = JSStringCreateWithUTF8CString("inherited");
    JSObjectSetProperty(context, names_object, own_name,
        JSValueMakeNumber(context, 1), kJSPropertyAttributeNone, &exception);
    JSObjectSetProperty(context, names_prototype, inherited_names_name,
        JSValueMakeNumber(context, 2), kJSPropertyAttributeNone, &exception);
    JSObjectSetPrototype(context, names_object, names_prototype);
    JSStringRef names_object_name = JSStringCreateWithUTF8CString("namesObject");
    JSObjectSetProperty(context, JSContextGetGlobalObject(context), names_object_name,
        names_object, kJSPropertyAttributeNone, &exception);
    JSPropertyNameArrayRef property_names = JSObjectCopyPropertyNames(context, names_object);
    JSPropertyNameArrayRef retained_property_names = JSPropertyNameArrayRetain(property_names);
    JSPropertyNameArrayRelease(property_names);
    fputs("property-names ", stdout);
    if (!retained_property_names || !print_property_names(retained_property_names))
        return 9;
    fputc('\n', stdout);
    JSPropertyNameArrayRelease(retained_property_names);
    JSValueRef names_reflection = evaluate(context,
        "JSON.stringify([Object.keys(namesObject),Reflect.ownKeys(namesObject),Object.getOwnPropertyDescriptor(namesObject,'virtual')??null,(function(){const r=[];for(const k in namesObject)r.push(k);return r})()])");
    JSStringRef names_reflection_string = JSValueToStringCopy(context, names_reflection, &exception);
    fputs("property-names-js ", stdout);
    if (!names_reflection_string || !print_json_string(names_reflection_string))
        return 10;
    fputc('\n', stdout);
    JSStringRelease(names_reflection_string);
    JSStringRelease(own_name); JSStringRelease(inherited_names_name);
    JSStringRelease(names_object_name);
    JSClassRelease(names_class);

    JSClassDefinition callable_definition = kJSClassDefinitionEmpty;
    callable_definition.callAsFunction = class_call;
    callable_definition.callAsConstructor = class_construct;
    callable_definition.hasInstance = class_has_instance;
    callable_definition.convertToType = class_convert;
    JSClassRef callable_class = JSClassCreate(&callable_definition);
    JSObjectRef callable_object = JSObjectMake(context, callable_class, NULL);
    JSValueRef call_argument = JSValueMakeNumber(context, 5);
    JSValueRef call_result = JSObjectCallAsFunction(context, callable_object, NULL,
        1, &call_argument, &exception);
    JSValueRef construct_argument = JSValueMakeNumber(context, 6);
    JSObjectRef construct_result = JSObjectCallAsConstructor(context, callable_object,
        1, &construct_argument, &exception);
    JSStringRef constructed_name = JSStringCreateWithUTF8CString("constructed");
    printf("class-callable %d %d %.0f %.0f %d\n",
        JSObjectIsFunction(context, callable_object),
        JSObjectIsConstructor(context, callable_object),
        JSValueToNumber(context, call_result, &exception),
        JSValueToNumber(context, JSObjectGetProperty(context, construct_result,
            constructed_name, &exception), &exception),
        JSValueIsInstanceOfConstructor(context, JSValueMakeNumber(context, 42),
            callable_object, &exception));
    JSStringRef callable_object_name = JSStringCreateWithUTF8CString("callableObject");
    JSObjectSetProperty(context, JSContextGetGlobalObject(context), callable_object_name,
        callable_object, kJSPropertyAttributeNone, &exception);
    JSValueRef callable_js = evaluate(context,
        "JSON.stringify([callableObject(5),new callableObject(6).constructed,42 instanceof callableObject,7 instanceof callableObject,String(callableObject),Number(callableObject)])");
    JSStringRef callable_js_string = JSValueToStringCopy(context, callable_js, &exception);
    fputs("class-callable-js ", stdout);
    if (!callable_js_string || !print_json_string(callable_js_string))
        return 11;
    fputc('\n', stdout);
    JSStringRelease(callable_js_string);
    JSValueRef throw_argument = JSValueMakeNumber(context, -1);
    exception = NULL;
    JSValueRef thrown_call = JSObjectCallAsFunction(context, callable_object, NULL,
        1, &throw_argument, &exception);
    double call_exception = JSValueToNumber(context, exception, NULL);
    exception = NULL;
    JSObjectRef thrown_construct = JSObjectCallAsConstructor(context, callable_object,
        1, &throw_argument, &exception);
    double construct_exception = JSValueToNumber(context, exception, NULL);
    exception = NULL;
    int thrown_instance = JSValueIsInstanceOfConstructor(context, throw_argument,
        callable_object, &exception);
    double instance_exception = JSValueToNumber(context, exception, NULL);
    exception = NULL;
    throw_convert = 1;
    double thrown_conversion = JSValueToNumber(context, callable_object, &exception);
    throw_convert = 0;
    double conversion_exception = JSValueToNumber(context, exception, NULL);
    printf("class-callable-throws %d %.0f %d %.0f %d %.0f %d %.0f\n",
        thrown_call == NULL, call_exception, thrown_construct == NULL,
        construct_exception, !thrown_instance, instance_exception,
        isnan(thrown_conversion), conversion_exception);
    exception = NULL;
    JSClassRef callable_parent_class = JSClassCreate(&callable_definition);
    JSClassDefinition callable_child_definition = kJSClassDefinitionEmpty;
    callable_child_definition.parentClass = callable_parent_class;
    JSClassRef callable_child_class = JSClassCreate(&callable_child_definition);
    JSClassRelease(callable_parent_class);
    JSObjectRef inherited_callable = JSObjectMake(context, callable_child_class, NULL);
    JSValueRef inherited_argument = JSValueMakeNumber(context, 2);
    JSValueRef inherited_call = JSObjectCallAsFunction(context, inherited_callable,
        NULL, 1, &inherited_argument, &exception);
    JSObjectRef inherited_construct = JSObjectCallAsConstructor(context,
        inherited_callable, 1, &inherited_argument, &exception);
    printf("class-callable-inherited %.0f %.0f %d %.0f\n",
        JSValueToNumber(context, inherited_call, &exception),
        JSValueToNumber(context, JSObjectGetProperty(context, inherited_construct,
            constructed_name, &exception), &exception),
        JSValueIsInstanceOfConstructor(context, JSValueMakeNumber(context, 42),
            inherited_callable, &exception),
        JSValueToNumber(context, inherited_callable, &exception));
    JSClassRelease(callable_child_class);
    JSStringRelease(callable_object_name);
    JSClassRelease(callable_class);

    JSClassDefinition instance_definition = kJSClassDefinitionEmpty;
    JSClassRef instance_class = JSClassCreate(&instance_definition);
    JSObjectRef default_constructor = JSObjectMakeConstructor(context, instance_class, NULL);
    JSObjectRef default_instance = JSObjectCallAsConstructor(context, default_constructor,
        0, NULL, &exception);
    exception = NULL;
    JSValueRef default_call = JSObjectCallAsFunction(context, default_constructor,
        NULL, 0, NULL, &exception);
    int default_call_threw = exception != NULL;
    exception = NULL;
    JSObjectRef explicit_constructor = JSObjectMakeConstructor(context, instance_class,
        class_construct);
    JSObjectRef explicit_instance = JSObjectCallAsConstructor(context, explicit_constructor,
        1, &construct_argument, &exception);
    printf("made-constructor %d %d %d %d %d %.0f\n",
        JSObjectIsFunction(context, default_constructor),
        JSObjectIsConstructor(context, default_constructor),
        JSValueIsObjectOfClass(context, default_instance, instance_class),
        default_call != NULL, default_call_threw,
        JSValueToNumber(context, JSObjectGetProperty(context, explicit_instance,
            constructed_name, &exception), &exception));
    JSStringRelease(constructed_name);
    JSClassRelease(instance_class);

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
