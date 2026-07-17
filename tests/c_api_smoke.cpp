#include <JavaScriptCore/JavaScript.h>
#include <zig-js/Extensions.h>

#include <cstdint>
#include <cstring>

struct WorkerInspectorTranscript {
    char bytes[1024] {};
    std::size_t length { 0 };
};

static void receive_worker_inspector(const char* message, std::size_t length, void* user_data)
{
    auto* transcript = static_cast<WorkerInspectorTranscript*>(user_data);
    const auto copied = length < sizeof(transcript->bytes) - transcript->length - 1
        ? length
        : sizeof(transcript->bytes) - transcript->length - 1;
    std::memcpy(transcript->bytes + transcript->length, message, copied);
    transcript->length += copied;
    transcript->bytes[transcript->length] = '\0';
}

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
    WorkerInspectorTranscript worker_transcript;
    auto worker_inspector = ZJSWorkerInspectorSessionCreate(
        worker, receive_worker_inspector, &worker_transcript);
    if (!worker_inspector ||
        ZJSWorkerInspectorSessionPump(worker_inspector, 10000) != kZJSWorkerInspectorPumpMessage)
        return 9;
    const char schema[] = "{\"id\":1,\"method\":\"Schema.getDomains\"}";
    if (!ZJSWorkerInspectorSessionDispatch(worker_inspector, schema, sizeof(schema) - 1) ||
        ZJSWorkerInspectorSessionPump(worker_inspector, 10000) != kZJSWorkerInspectorPumpMessage ||
        !std::strstr(worker_transcript.bytes, "Schema"))
        return 10;
    ZJSWorkerInspectorSessionRelease(worker_inspector);
    JSWorkerTerminate(worker);
    JSWorkerRelease(worker);
    JSStringRelease(worker_source);

    JSGlobalContextRelease(context);
    return 0;
}
