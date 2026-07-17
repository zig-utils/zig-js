# Inspector protocol

zig-js exposes an embedder-transported inspector protocol through
include/zig-js/Extensions.h. Public JavaScriptCore inspectability remains
opt-in: JSGlobalContextSetInspectable(ctx, true) must run before a
ZJSInspectorSessionCreate succeeds.

## Transport and trust boundary

The protocol version is zig-js-inspector/0.1. A session receives JSON messages
through a synchronous callback and accepts JSON requests through
ZJSInspectorSessionDispatch. Message bytes are borrowed only for the duration of
the callback. zig-js does not open a socket, choose an origin, authenticate a
client, or authorize commands. The embedder owns those transport and security
decisions and should expose dispatch only to an authenticated debugger peer.

Sessions and their context group are thread-affine. A session retains its global
context until ZJSInspectorSessionRelease, supports multiple simultaneous
sessions, and is detached deterministically when inspectability is disabled.
Because transport callbacks are synchronous and contexts are thread-affine, a
client that receives Debugger.paused must dispatch Debugger.resume from that
callback. If it returns without a continuation command, zig-js aborts that
evaluation with a deterministic JavaScript Error instead of silently running
while claiming to be paused.

    static void receive(const char* json, size_t length, void* userData);

    JSGlobalContextSetInspectable(ctx, true);
    ZJSInspectorSessionRef session =
        ZJSInspectorSessionCreate(ctx, receive, userData);

    const char request[] =
        "{\"id\":1,\"method\":\"Runtime.evaluate\","
        "\"params\":{\"expression\":\"6 * 7\"}}";
    ZJSInspectorSessionDispatch(session, request, sizeof(request) - 1);
    ZJSInspectorSessionRelease(session);

## Version 0.1 domains

- Schema.getDomains
- Runtime.enable, Runtime.disable, and Runtime.evaluate
- Debugger.enable, Debugger.disable, Debugger.pause, and Debugger.resume
- Inspector.attached, Inspector.detached, Runtime.executionContextCreated,
  Debugger.scriptParsed, Debugger.paused, and Debugger.resumed events

Every evaluated C-API script receives a monotonically increasing scriptId.
Debugger.scriptParsed publishes its URL, starting line, and source length.
Statement locations retain byte offsets plus adjusted line/column coordinates;
a debugger statement pauses with reason debuggerStatement. An explicit
Debugger.pause request pauses at the next statement boundary. Debug-enabled
execution deliberately uses the tree walker, including ordinary synchronous
functions parsed from that script, so bytecode/baseline compilation cannot skip
these boundaries.

Requests require an integer id and string method. Responses use JSON-RPC/CDP
style result or error objects. Evaluation exceptions include an
exceptionDetails object. Malformed requests receive deterministic protocol
errors.

## Current debugger boundary

Version 0.1 establishes real attachment, lifecycle, concurrent sessions, live
runtime evaluation, stable scripts, and statement-boundary pause/resume. URL and
script breakpoints, stepping, exception-pause policy, call frames, remote
objects, and scopes remain tracked by [issue #153](https://github.com/zig-utils/zig-js/issues/153)
and [issue #154](https://github.com/zig-utils/zig-js/issues/154). Unsupported
commands return -32601; there are no silently accepted debugger stubs.
Suspendable generator/async execution still uses its VM and does not yet expose
statement pause points; that tier-coherence work remains in #153.
