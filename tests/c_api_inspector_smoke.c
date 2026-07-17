#include <zig-js/Extensions.h>

#include <stddef.h>
#include <string.h>

struct Transcript {
    char bytes[4096];
    size_t length;
};

static void receive_message(const char* message, size_t length, void* user_data)
{
    struct Transcript* transcript = (struct Transcript*)user_data;
    if (transcript->length + length + 1 >= sizeof(transcript->bytes))
        return;
    memcpy(transcript->bytes + transcript->length, message, length);
    transcript->length += length;
    transcript->bytes[transcript->length++] = '\n';
    transcript->bytes[transcript->length] = '\0';
}

int main(void)
{
    JSGlobalContextRef context = JSGlobalContextCreate(NULL);
    if (!context || JSGlobalContextIsInspectable(context))
        return 1;
    struct Transcript transcript = { { 0 }, 0 };
    if (ZJSInspectorSessionCreate(context, receive_message, &transcript))
        return 2;

    JSGlobalContextSetInspectable(context, true);
    ZJSInspectorSessionRef session =
        ZJSInspectorSessionCreate(context, receive_message, &transcript);
    if (!session || !strstr(transcript.bytes, "zig-js-inspector/0.1"))
        return 3;

    const char schema[] = "{\"id\":1,\"method\":\"Schema.getDomains\"}";
    const char enable[] = "{\"id\":2,\"method\":\"Runtime.enable\"}";
    const char evaluate[] =
        "{\"id\":3,\"method\":\"Runtime.evaluate\",\"params\":{\"expression\":\"20 + 22\"}}";
    if (!ZJSInspectorSessionDispatch(session, schema, sizeof(schema) - 1) ||
        !ZJSInspectorSessionDispatch(session, enable, sizeof(enable) - 1) ||
        !ZJSInspectorSessionDispatch(session, evaluate, sizeof(evaluate) - 1))
        return 4;
    if (!strstr(transcript.bytes, "\"Runtime\"") ||
        !strstr(transcript.bytes, "Runtime.executionContextCreated") ||
        !strstr(transcript.bytes, "\"description\":\"42\""))
        return 5;

    JSGlobalContextRelease(context);
    if (!ZJSInspectorSessionDispatch(session, evaluate, sizeof(evaluate) - 1))
        return 6;
    ZJSInspectorSessionRelease(session);
    return 0;
}
