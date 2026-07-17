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
- Debugger.enable and Debugger.disable
- Inspector.attached, Inspector.detached, and Runtime.executionContextCreated
  events

Requests require an integer id and string method. Responses use JSON-RPC/CDP
style result or error objects. Evaluation exceptions include an
exceptionDetails object. Malformed requests receive deterministic protocol
errors.

## Current debugger boundary

Version 0.1 establishes real attachment, lifecycle, concurrent sessions, and
live runtime evaluation. It does not yet advertise pause/resume, breakpoints,
stepping, exception pause, script/source events, call frames, or scopes. Those
execution hooks and their protocol transcripts remain tracked by
[GitHub issue #139](https://github.com/zig-utils/zig-js/issues/139). Unsupported
commands return -32601; there are no silently accepted debugger stubs.
