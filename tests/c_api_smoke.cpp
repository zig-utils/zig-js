#include <JavaScriptCore/JavaScript.h>

#include <cstdint>

int main()
{
    JSGlobalContextRef context = JSGlobalContextCreate(nullptr);
    if (!context)
        return 1;

    JSValueRef exception = nullptr;
    JSObjectRef array = JSObjectMakeTypedArray(
        context, kJSTypedArrayTypeUint16Array, 4, &exception);
    if (!array || exception)
        return 2;
    if (JSValueGetTypedArrayType(context, array, &exception) != kJSTypedArrayTypeUint16Array)
        return 3;
    if (JSObjectGetTypedArrayByteLength(context, array, &exception) != 8)
        return 4;

    auto* bytes = static_cast<std::uint16_t*>(
        JSObjectGetTypedArrayBytesPtr(context, array, &exception));
    if (!bytes || exception)
        return 5;
    bytes[0] = 42;

    JSGlobalContextRelease(context);
    return 0;
}
