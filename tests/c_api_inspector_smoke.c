#include <zig-js/Extensions.h>

#include <stddef.h>
#include <string.h>

struct Transcript {
    char bytes[32768];
    size_t length;
    ZJSInspectorSessionRef session;
    size_t pauses;
    int step_over_next;
    int evaluate_frame_next;
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
        const char step_over[] = "{\"id\":91,\"method\":\"Debugger.stepOver\"}";
        const char evaluate_frame[] =
            "{\"id\":92,\"method\":\"Debugger.evaluateOnCallFrame\","
            "\"params\":{\"callFrameId\":0,\"expression\":\"x += 4\"}}";
        transcript->pauses++;
        if (transcript->evaluate_frame_next) {
            transcript->evaluate_frame_next = 0;
            if (!ZJSInspectorSessionDispatch(
                    transcript->session, evaluate_frame, sizeof(evaluate_frame) - 1))
                return;
        }
        if (transcript->step_over_next) {
            transcript->step_over_next = 0;
            ZJSInspectorSessionDispatch(transcript->session, step_over, sizeof(step_over) - 1);
        } else {
            ZJSInspectorSessionDispatch(transcript->session, resume, sizeof(resume) - 1);
        }
    }
}

int main(void)
{
    JSGlobalContextRef context = JSGlobalContextCreate(NULL);
    if (!context || JSGlobalContextIsInspectable(context))
        return 1;
    struct Transcript transcript = { { 0 }, 0, NULL, 0, 0, 0 };
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
    transcript.evaluate_frame_next = 1;
    JSValueRef inspected_result;
    if (!ZJSInspectorSessionDispatch(session, debugger_enable, sizeof(debugger_enable) - 1) ||
        !(inspected_result = JSEvaluateScript(context, source, NULL, source_url, 7, &exception)) || exception ||
        transcript.pauses != 1 || !strstr(transcript.bytes, "Debugger.scriptParsed") ||
        !strstr(transcript.bytes, "\"callFrames\"") ||
        !strstr(transcript.bytes, "\"scopeChain\"") ||
        !strstr(transcript.bytes, "\"id\":92") ||
        JSValueToNumber(context, inspected_result, &exception) != 7 || exception ||
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

    const char set_step_breakpoint[] =
        "{\"id\":7,\"method\":\"Debugger.setBreakpointByUrl\","
        "\"params\":{\"url\":\"step-smoke.js\",\"lineNumber\":4}}";
    const char step_text[] =
        "function stepFn() {\n var inner = 1;\n return inner;\n}\n"
        "var stepped = stepFn();\nstepped += 1;\nstepped;";
    JSStringRef step_source = JSStringCreateWithUTF8CString(step_text);
    JSStringRef step_url = JSStringCreateWithUTF8CString("step-smoke.js");
    transcript.step_over_next = 1;
    if (!ZJSInspectorSessionDispatch(session, set_step_breakpoint, sizeof(set_step_breakpoint) - 1) ||
        !JSEvaluateScript(context, step_source, NULL, step_url, 1, &exception) ||
        exception || transcript.pauses != 4 || !strstr(transcript.bytes, "\"reason\":\"step\""))
        return 10;
    const char remove_step_breakpoint[] =
        "{\"id\":8,\"method\":\"Debugger.removeBreakpoint\",\"params\":{\"breakpointId\":2}}";
    if (!ZJSInspectorSessionDispatch(session, remove_step_breakpoint, sizeof(remove_step_breakpoint) - 1))
        return 11;
    JSStringRelease(step_url);
    JSStringRelease(step_source);

    const char pause_all[] =
        "{\"id\":9,\"method\":\"Debugger.setPauseOnExceptions\",\"params\":{\"state\":\"all\"}}";
    const char caught_text[] = "var caught = 0;\ntry { throw 'caught'; } catch (value) { caught = 1; }\ncaught;";
    JSStringRef caught_source = JSStringCreateWithUTF8CString(caught_text);
    JSStringRef exception_url = JSStringCreateWithUTF8CString("exception-smoke.js");
    if (!ZJSInspectorSessionDispatch(session, pause_all, sizeof(pause_all) - 1) ||
        !JSEvaluateScript(context, caught_source, NULL, exception_url, 1, &exception) ||
        exception || transcript.pauses != 5 ||
        !strstr(transcript.bytes, "Debugger.exceptionThrown") ||
        !strstr(transcript.bytes, "\"uncaught\":false"))
        return 12;
    const char pause_none[] =
        "{\"id\":10,\"method\":\"Debugger.setPauseOnExceptions\",\"params\":{\"state\":\"none\"}}";
    if (!ZJSInspectorSessionDispatch(session, pause_none, sizeof(pause_none) - 1))
        return 13;
    JSStringRelease(exception_url);
    JSStringRelease(caught_source);

    JSGlobalContextRelease(context);
    if (!ZJSInspectorSessionDispatch(session, evaluate, sizeof(evaluate) - 1))
        return 6;
    ZJSInspectorSessionRelease(session);
    return 0;
}
