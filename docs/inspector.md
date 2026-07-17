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
At each stop, the first enabled session (or the session that requested the
pending pause/step) owns continuation. Observer sessions receive and may inspect
the paused snapshot before the owner callback runs, but their resume/step
commands receive a deterministic error. The owner receives the pause last and
must continue synchronously; step ownership carries into the resulting stop.
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
- Runtime.enable, Runtime.disable, Runtime.evaluate, Runtime.getProperties,
  Runtime.releaseObject, and Runtime.releaseObjectGroup
- Debugger.enable, Debugger.disable, Debugger.pause, Debugger.resume,
  Debugger.stepInto, Debugger.stepOver, Debugger.stepOut,
  Debugger.evaluateOnCallFrame,
  Debugger.setPauseOnExceptions,
  Debugger.getScriptSource, Debugger.setBreakpoint,
  Debugger.setBreakpointByUrl, and Debugger.removeBreakpoint
- Inspector.attached, Inspector.detached, Runtime.executionContextCreated,
  Debugger.scriptParsed, Debugger.breakpointResolved, Debugger.paused, and
  Debugger.resumed, and Debugger.exceptionThrown events

Every evaluated C-API script receives a monotonically increasing unsigned
integer scriptId. Debugger.scriptParsed publishes its URL, zero-based starting
line, and source length.
Statement locations retain byte offsets plus adjusted line/column coordinates;
a debugger statement pauses with reason debuggerStatement. An explicit
Debugger.pause request pauses at the next statement boundary. Debug-enabled
execution deliberately uses the tree walker, including ordinary synchronous
functions parsed from that script, so bytecode/baseline compilation cannot skip
these boundaries. Suspendable generator and async-function chunks retain the
same statement map inside the VM; stepping survives yield/await suspension and
VM quick paths are disabled for those debug chunks. The optimizing JIT does not
exist yet and therefore cannot be claimed as an inspected tier (tracked by
[issue #146](https://github.com/zig-utils/zig-js/issues/146)).

Script breakpoints identify a scriptId; URL breakpoints apply to every matching
present or future script. A requested location resolves deterministically to the
first statement at or after its zero-based line/column, emits
Debugger.breakpointResolved, and reports its id in paused.hitBreakpoints.
Removing a breakpoint removes all of its resolved locations. Breakpoints are
shared execution controls for the context, so every enabled session observes
their resolution, pause, and resume events.

stepInto pauses at the next executed statement. stepOver ignores statements in
deeper ordinary-function calls and stops at the next statement at the current
or a shallower logical call depth. stepOut stops after control returns to a
shallower call depth and is rejected at top level. A step completion pauses with
reason step; a debugger statement or breakpoint encountered first takes
precedence. Each continuation command emits Debugger.resumed.

Every Debugger.paused event includes callFrames ordered from the current
invocation outward to the global script. A frame has a pause-local numeric
callFrameId, function name, exact script location, `this`, and its live lexical
scope chain. Declarative block/local scopes include their current bindings;
global scopes publish a binding count without expanding the realm's full
builtin table into every pause transcript. Tree-walker frames and suspendable
generator/async VM frames use the same representation. These frames reference
the actual activation environments, and the collector traces every paused
caller environment and `this` value until execution continues.

Debugger.evaluateOnCallFrame accepts a callFrameId from the current pause and
an expression. It evaluates synchronously against that frame's real lexical
environment, `this`, and strictness, so assignments are visible when execution
resumes. Debugger-authored evaluation cannot recursively pause; the runtime
restores the suspended program's control state and any pre-existing exception
after returning a structured result or exceptionDetails response. Frame IDs
expire as soon as the pause resumes.

Object-valued evaluation results, `this` values, scope bindings, and accessor
functions carry a session-owned numeric objectId. Runtime.getProperties returns
own data/accessor descriptors without invoking getters; scope objectIds expand
the corresponding live environment. Evaluation accepts an optional objectGroup.
Runtime.releaseObject and Runtime.releaseObjectGroup deterministically unprotect
handles. Value handles remain rooted across precise GC until release, while the
`backtrace` handles attached to paused frames/scopes are released automatically
on resume. IDs cannot be used by another session, after their group/session is
released, or (for scopes) outside their originating pause.

setPauseOnExceptions accepts none, uncaught, or all. all pauses at the original
throwing statement even when a surrounding catch handles the value; uncaught
pauses only after propagation reaches the C-API evaluation boundary. Origin
events cover explicit throws, engine-created Error/DOMException/parser errors,
and fallback detection at the nearest catch/host boundary. Each selected throw
emits Debugger.exceptionThrown followed by a paused event with reason exception,
an exceptionId, the source location, and an uncaught flag.

scriptId and breakpointId are unsigned JSON integers in this protocol (they are
not opaque strings). All protocol line and column fields are zero-based; the
byteOffset field is zero-based UTF-8 source bytes.

Requests require an integer id and string method. Responses use JSON-RPC/CDP
style result or error objects. Evaluation exceptions include an
exceptionDetails object. Malformed requests receive deterministic protocol
errors.

The machine-readable [0.1 command/event inventory](inspector-protocol-0.1.json)
names all 20 commands and 8 events with transcript evidence. Every listed
command is implemented; an unlisted method receives -32601 and is never silently
accepted.

## Current debugger boundary

Version 0.1 establishes real attachment, lifecycle, concurrent sessions, live
runtime evaluation, stable scripts, statement-boundary pause/resume,
breakpoints, ordinary-call stepping, exception-pause policy, live call frames,
lexical/global scope chains, frame evaluation, and expandable remote objects
with deterministic GC-safe lifetime. Worker targets remain tracked by
[issue #154](https://github.com/zig-utils/zig-js/issues/154). Unsupported
commands return -32601; there are no silently accepted debugger stubs.
