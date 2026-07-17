#include <JavaScriptCore/JavaScript.h>

#include <stdint.h>
#include <stdlib.h>

static unsigned deallocations;

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
    return deallocations == 1 ? 0 : 7;
}
