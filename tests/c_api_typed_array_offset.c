#include <JavaScriptCore/JavaScript.h>
#include <stdint.h>
#include <stdio.h>

#define CHECK(condition) do { if (!(condition)) { fprintf(stderr, "typed-array offset fixture failed at line %d\n", __LINE__); return 1; } } while (0)

static JSValueRef eval(JSContextRef ctx, const char* source)
{
    JSStringRef script = JSStringCreateWithUTF8CString(source);
    JSValueRef exception = NULL;
    JSValueRef result = JSEvaluateScript(ctx, script, NULL, NULL, 1, &exception);
    JSStringRelease(script);
    return exception ? NULL : result;
}

int main(void)
{
    JSGlobalContextRef ctx = JSGlobalContextCreate(NULL);
    CHECK(ctx);
    JSValueRef exception = NULL;
    JSValueRef value = eval(ctx,
        "globalThis.bytes = new Uint8Array([10,11,12,13,14,15,16,17,18,19,20,21]);"
        "new Uint16Array(bytes.buffer, 4, 2)");
    CHECK(value && JSValueIsObject(ctx, value));
    JSObjectRef view = JSValueToObject(ctx, value, &exception);
    JSValueProtect(ctx, view);
    JSObjectRef buffer = JSObjectGetTypedArrayBuffer(ctx, view, &exception);
    CHECK(buffer && !exception);
    JSValueProtect(ctx, buffer);
    CHECK(JSObjectGetTypedArrayLength(ctx, view, &exception) == 2);
    CHECK(JSObjectGetTypedArrayByteLength(ctx, view, &exception) == 4);
    size_t offset = JSObjectGetTypedArrayByteOffset(ctx, view, &exception);
    CHECK(offset == 4 && !exception);
    uint8_t* base = JSObjectGetArrayBufferBytesPtr(ctx, buffer, &exception);
    uint8_t* raw = JSObjectGetTypedArrayBytesPtr(ctx, view, &exception);
    CHECK(raw && raw == base && !exception);
    CHECK(raw[0] == 10 && raw[offset] == 14 && raw[offset + 3] == 17);
    /* Apply the separately reported offset exactly once, without another API
       call while the temporary pointer is borrowed. */
    raw[offset] = 99;
    CHECK(JSValueToBoolean(ctx, eval(ctx, "bytes[0] === 10 && bytes[4] === 99 && bytes[8] === 18")));
    JSValueUnprotect(ctx, buffer);
    JSValueUnprotect(ctx, view);
    JSGlobalContextRelease(ctx);
    puts("OK typed-array backing pointer, offset and view write");
    return 0;
}
