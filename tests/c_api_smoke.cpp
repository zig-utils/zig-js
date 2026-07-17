#include <JavaScriptCore/JavaScript.h>
#include <zig-js/Extensions.h>

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
    if (!ZJSValueProtect(context, array) || !ZJSValueUnprotect(context, array))
        return 7;

    const JSChar characters[] = { 'C', '+', '+', 0xd83d, 0xde80 };
    JSStringRef string = JSStringCreateWithCharacters(characters, 5);
    if (!string || JSStringGetCharactersPtr(string)[4] != 0xde80 ||
        JSStringGetMaximumUTF8CStringSize(string) != 16 ||
        !JSStringIsEqualToUTF8CString(string, "C++\xf0\x9f\x9a\x80"))
        return 6;
    JSStringRelease(string);

    JSStringRef worker_source = JSStringCreateWithUTF8CString("");
    JSWorkerRef worker = JSWorkerCreate(worker_source);
    ZJSInspectorTargetInfo target {};
    if (!worker || !ZJSWorkerGetInspectorTargetInfo(worker, &target) || !target.id ||
        target.kind != kZJSInspectorTargetKindScript ||
        (target.state != kZJSInspectorTargetStateStarting &&
            target.state != kZJSInspectorTargetStateRunning))
        return 8;
    JSWorkerTerminate(worker);
    JSWorkerRelease(worker);
    JSStringRelease(worker_source);

    JSGlobalContextRelease(context);
    return 0;
}
