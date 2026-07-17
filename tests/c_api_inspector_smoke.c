#include <zig-js/Extensions.h>

#include <stddef.h>
#include <string.h>

struct Transcript {
    char bytes[16384];
    size_t length;
    ZJSInspectorSessionRef session;
    size_t pauses;
};

static int contains_fragment(const char* message, size_t length, const char* fragment)
{
    size_t fragment_length = strlen(fragment);
    if (fragment_length > length)
        return 0;
    for (size_t i = 0; i + fragment_length <= length; i++) {
        if (!memcmp(message + i, fragment, fragment_length))
            return 1;
    }
    return 0;
}

static void receive_message(const char* message, size_t length, void* user_data)
{
    struct Transcript* transcript = (struct Transcript*)user_data;
    if (transcript->length + length + 1 >= sizeof(transcript->bytes))
        return;
    memcpy(transcript->bytes + transcript->length, message, length);
    transcript->length += length;
    transcript->bytes[transcript->length++] = '\n';
    transcript->bytes[transcript->length] = '\0';
    if (contains_fragment(message, length, "Debugger.paused")) {
        const char resume[] = "{\"id\":90,\"method\":\"Debugger.resume\"}";
        transcript->pauses++;
        ZJSInspectorSessionDispatch(transcript->session, resume, sizeof(resume) - 1);
    }
}

int main(void)
{
    JSGlobalContextRef context = JSGlobalContextCreate(NULL);
    if (!context || JSGlobalContextIsInspectable(context))
        return 1;
    struct Transcript transcript = { { 0 }, 0, NULL, 0 };
    if (ZJSInspectorSessionCreate(context, receive_message, &transcript))
        return 2;

    JSGlobalContextSetInspectable(context, true);
    ZJSInspectorSessionRef session =
        ZJSInspectorSessionCreate(context, receive_message, &transcript);
    transcript.session = session;
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

    const char debugger_enable[] = "{\"id\":4,\"method\":\"Debugger.enable\"}";
    const char source_text[] = "let x = 1;\ndebugger;\nx += 2;\nx;";
    JSStringRef source = JSStringCreateWithUTF8CString(source_text);
    JSStringRef source_url = JSStringCreateWithUTF8CString("inspector-smoke.js");
    JSValueRef exception = NULL;
    if (!ZJSInspectorSessionDispatch(session, debugger_enable, sizeof(debugger_enable) - 1) ||
        !JSEvaluateScript(context, source, NULL, source_url, 7, &exception) || exception ||
        transcript.pauses != 1 || !strstr(transcript.bytes, "Debugger.scriptParsed") ||
        !strstr(transcript.bytes, "debuggerStatement") ||
        !strstr(transcript.bytes, "Debugger.resumed"))
        return 7;
    JSStringRelease(source_url);
    JSStringRelease(source);

    const char set_breakpoint[] =
        "{\"id\":5,\"method\":\"Debugger.setBreakpointByUrl\","
        "\"params\":{\"url\":\"breakpoint-smoke.js\",\"lineNumber\":1}}";
    const char breakpoint_text[] = "var answer = 40;\nanswer += 2;\nanswer;";
    JSStringRef breakpoint_source = JSStringCreateWithUTF8CString(breakpoint_text);
    JSStringRef breakpoint_url = JSStringCreateWithUTF8CString("breakpoint-smoke.js");
    if (!ZJSInspectorSessionDispatch(session, set_breakpoint, sizeof(set_breakpoint) - 1) ||
        !JSEvaluateScript(context, breakpoint_source, NULL, breakpoint_url, 1, &exception) ||
        exception || transcript.pauses != 2 ||
        !strstr(transcript.bytes, "Debugger.breakpointResolved") ||
        !strstr(transcript.bytes, "\"reason\":\"breakpoint\""))
        return 8;
    const char remove_breakpoint[] =
        "{\"id\":6,\"method\":\"Debugger.removeBreakpoint\",\"params\":{\"breakpointId\":1}}";
    if (!ZJSInspectorSessionDispatch(session, remove_breakpoint, sizeof(remove_breakpoint) - 1))
        return 9;
    JSStringRelease(breakpoint_url);
    JSStringRelease(breakpoint_source);

    JSGlobalContextRelease(context);
    if (!ZJSInspectorSessionDispatch(session, evaluate, sizeof(evaluate) - 1))
        return 6;
    ZJSInspectorSessionRelease(session);
    return 0;
}
