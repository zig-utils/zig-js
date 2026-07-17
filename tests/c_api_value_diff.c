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

    JSValueProtect(context, json);
    JSValueUnprotect(context, json);
    if (exception)
        return 3;
    JSGlobalContextRelease(context);
    return 0;
}
