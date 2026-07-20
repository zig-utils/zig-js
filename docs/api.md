---
title: zig-js public C API
description: Embed zig-js through its complete pinned JavaScriptCore-shaped public C target.
---

# zig-js public C API

zig-js exports the complete checked-in JavaScriptCore-shaped public C target
from `c_api.zig`. `zig build` installs the static library under `zig-out/lib`
and compatible headers under `zig-out/include/JavaScriptCore`. Hosts that stay
within the pinned target can link `libzig-js.a` in place of the system
`JavaScriptCore.framework` and keep those documented calls unchanged.

The machine-readable [macOS 27.0 inventory](c-api/jsc-public-api-macos-27.0.json)
is the completion authority for the full checked-in declaration surface.
The inventory currently has 117 implemented functions and zero pending entries.
Use `zig build c-api-audit` for the fast drift gate or `zig build test-c-api` to
compile, link, and execute both C and C++ embedding fixtures.
`zig build c-api-jsc-diff` is the macOS-only semantic gate for completed value
APIs against the hash-pinned system JavaScriptCore headers and framework.

The [versioned consumer profiles](abi/README.md) apply a narrower second gate to
real downstream source revisions. Home profile `home-public-c-7ed99c02` pins 50
Zig C-ABI declarations and reports 50/50 exports with a real Zig
compile-link-runtime fixture. It remains deliberately separate from private
Home/Bun ABI work.

Private-profile exports are audited independently and never inflate the public
or extension totals. The pinned Home inventory currently reports 440
implemented and 31 pending private symbols; `zig build test-home-private-abi`,
`zig build test-private-jstype`, and the feature-specific private ABI fixtures
are their focused compile-link-runtime gates.

`Response` and `Request` preserve `ReadableStream` bodies, expose `body` and
derived `bodyUsed`, tee live bodies during cloning, and route all Body
conversions through the engine stream consumer. The exact pinned behavior is
recorded in [`abi/fetch-body-lifecycle-407.json`](abi/fetch-body-lifecycle-407.json).
WebAssembly streaming compilation reuses that lifecycle and the ordinary Wasm
parser/linker; its exact MIME, Promise, realm, and error contract is recorded in
[`abi/wasm-streaming-api-408.json`](abi/wasm-streaming-api-408.json).
`Extensions.h` exposes the VM-affine create/finalize/release lifecycle around
the pinned void `JSC__Wasm__StreamingCompiler__addBytes` feed; arbitrary tokens
are never dereferenced, and finalization copies into caller storage.
The implemented surface covers JSC64 identity, cell equality,
truthiness, int32 extraction, exact signed/unsigned 64-bit BigInt construction,
modulo-2^64 BigInt extraction with the pinned int32/Int52 fallbacks, and exact
JavaScript strict/SameValue equality across primitives and owned cells, plus
profile-selected exact JSType queries and opaque BigInt downcast/order/signed
extraction across arbitrary-size values, owned decimal `BunString` conversion,
and exact JSCell/JSString downcast,
UTF-16 length, 8-bit eligibility, equality, object access, and boxing.
The BunString conversion family accepts 8/16-bit WTFStringImpl and every
pointer-tagged ZigString encoding, preserves lone UTF-16 surrogates, truncates
by code unit, consumes ownership only after successful transfer, and constructs
ordered selected-realm arrays failure-atomically.
Four ZigString error-instance exports create fresh Error, TypeError, RangeError,
and SyntaxError objects with exact tagged-input messages, selected-realm
intrinsic prototypes, and first-exception preservation.
The ZigString DOMException export implements the complete pinned code matrix
from 0 through 40: exact WebCore names, default messages, and legacy codes;
Bun's intentional code-9 SyntaxError divergence; all RangeError, TypeError,
ordinary Error, and undefined special branches; Node-style error codes;
caller-message override; and the unknown-code empty-name DOMException fallback.
It constructs against selected-realm intrinsics and preserves the first pending
exception.
Three AggregateError exports build fresh ordered error arrays or preserve an
exact supplied array/cause, install standard non-enumerable descriptors, and
read the own `errors` property directly. Same-VM siblings, foreign inputs,
invalid arrays, failure atomicity, and first-exception behavior are covered.
Eight property exports implement two-key selected-realm object construction,
direct ZigString own writes, single-coercion property-key writes, ordinary
deletion, ordinary prototype-aware reads, Bun's Object.prototype-cutoff lookup,
and own-only BunString/value-key reads. They preserve numeric and Symbol keys,
accessor/proxy behavior, duplicate-key insertion order, Latin-1 names, and the
distinct empty/deleted/exception sentinels without an extra observable `has`
trap.
The separate property-path export implements the pinned UTF-16 dot/bracket
parser and string/number array paths. It uses `ToObject` plus one ordinary
`Get` per target segment, distinguishes absent values from present `undefined`,
and preserves indexed path getters, proxy behavior, and abrupt completion
without adding a `has` trap.
Four class/display-name exports provide stable raw class metadata,
constructor-derived calculated class names, function/internal names, and owned
display names. They keep VM-inquiry class calculation non-invoking, perform one
observable `@@toStringTag` read where the pinned name paths require it, and
preserve exact borrowed ZigString versus owned UTF-16-capable BunString
lifetimes.
The received-value ErrorCode export additionally owns its BunString result and
uses the exact Bun diagnostic inspector when an observable constructor lookup
is falsy. It preserves null prototypes, descriptors, cycles, Proxy targets,
custom inspection, and WTF-16 strings while suppressing `constructor`; abrupt
completion and allocation failure publish no partial string.
The normal and fast JSON exports share the full serializer but preserve the
pinned numeric-indent versus undefined-space distinction. They retain
observable `toJSON`/getter/proxy behavior, order and omission rules, exact
Unicode escaping and error publication, and return independently owned
Latin-1/UTF-16 BunString results.
The native `fromEntries` and `putRecord` exports add exact copied ZigString
record construction. They preserve selected-realm Object/Array prototypes,
direct insertion, duplicate/integer-key ordering, zero/one/many cardinality,
all-true own descriptors, and caller-buffer independence without invoking
inherited setters. Invalid pointers, oversized counts, foreign cells, OOM, and
pre-existing exceptions cannot publish a partial result.
The value-key/BunString property trio performs one observable `ToPropertyKey`
own-property inquiry, direct own data writes, and Bun's scalar-to-array upsert
progression. Direct writes bypass prototype setters and replace configurable
accessors; Symbol/index/proxy behavior, foreign-value rejection, and first
pending exceptions remain exact.
The JSX element predicate performs one ordinary `$$typeof` read and accepts
only `Symbol.for('react.element')` or
`Symbol.for('react.transitional.element')` from the VM-wide registry. It keeps
inherited/getter/proxy observability and sibling-realm identity while rejecting
local symbols, same-description values, primitives, and foreign VMs.
The two core deep-equality exports provide Bun-pinned SameValue and cyclic
structural comparison for enumerable strings/Symbols, arrays, Map/Set,
buffers/views, numeric TypedArrays, boxed strings, Date, RegExp, and
Error/cause state. Strict mode additionally distinguishes calculated classes,
sparse holes, property counts, missing versus undefined, cause presence, and
raw float bits. Getter/proxy failures, sibling realms, foreign cells, bounded
recursion, and pending exceptions preserve the native boundary contract.
The three Jest-aware exports add right-first asymmetric matching for
anything/any, strings and regexes, array/object containment, numeric close-to,
promise modes, negation, and custom marker hooks. Recursive subset matching
uses inherited-aware single property reads, exact arrays, Symbols, independent
cycle sets, nested object-containing exhaustiveness, and optional direct
matched-property replacement. Ordinary deep equality remains hook-free.
Five remote-inspector process controls use atomic, idempotent state for
auto-start disable, explicit start, system-console logging, and the inspection
default. The default is disabled on modern Apple-family targets and enabled
elsewhere, and remains independently overrideable from context inspectability.
The proxy internal-field export reads the target/handler slots without invoking
traps, produces `null` for both after revocation, and rejects invalid field or
non-proxy inputs. VM-wide canonical private object handles preserve exact raw
EncodedJSValue identity when an existing object is projected again.
Script execution contexts receive lazy, process-unique nonzero `u32` IDs from
an atomic allocator. IDs remain stable for a context, distinguish sibling
realms, tolerate parallel independent creation, and leave pending exceptions
untouched.
The no-side-effects diagnostic projection renders every primitive, arbitrary
BigInt, and Symbol exactly, returns an input string unchanged, and collapses
all other objects to `[object Object]`. No conversion hook, getter, proxy trap,
or mutable global is consulted, and existing pending exceptions survive.
The rejection classifier performs JSC's exact own-`stack` descriptor check:
accessors count without invoking their getters, inherited properties do not,
and proxies receive one ordinary `[[GetOwnProperty]]` operation whose abrupt
completion is published through the shared pending-exception boundary.
The process-warning boundary converts strings and Error objects into queued,
realm-local `warning` events with pinned name/code/detail metadata. Its
unhandled-rejection companion emits the reason warning and Bun's exact warning
Error in FIFO order, preserving throwing stack reads, fallback stringification,
exception clearing, and listener failures.
The process dispatch boundary emits exact unhandled/late-handled Promise events,
orders the uncaught monitor before capture or ordinary handlers, preserves the
pinned origins and handled return codes, and constructs the exact
`UnhandledPromiseRejection` wrapper. Promise checkpoints suppress early-handled
and duplicate notifications while retaining the original reason and Promise.
The same realm-local event storage drives `beforeExit` and one-shot `exit`.
Native signal delivery maps the pinned platform signal table to canonical
`SIG*` event names and synchronously emits `(name, number)` on only the selected
realm's process object; unknown signals and pending exceptions are inert.
The private process next-tick calls enqueue into a separate realm FIFO with
exact one- or two-argument invocation. Host checkpoints drain it before Promise
jobs and repeat after the Promise phase when needed; precise roots cover queued
and active batches, including resumable tails after an uncaught listener throws.
IPC process-event shims gate decoding on listener presence, then synchronously
deliver exact `message(value, handle)`, `error(value)`, or zero-argument
`disconnect` events. Absent listeners are no-ops; observed foreign-VM values and
listener failures publish through the normal pending-exception boundary.
The iterable callback boundary performs ordered `@@iterator`, cached `next`,
IteratorStep, and IteratorValue operations before forwarding stable encoded
values and VM/global/context metadata. Callback-published exceptions close the
open iterator while preserving the original failure over a throwing `return()`.
The ZigString JSON bridge decodes all tagged forms into selected-realm parsed
values. It returns and clears SyntaxError objects on invalid JSON, and returns a
coded `ERR_STRING_TOO_LONG` Error before dereferencing an over-limit span.
Three fast built-in reads pin every byte-table entry and distinguish direct
data, own-slot, and Object.prototype-cutoff lookup. Bun's fourth core-only
`code` inquiry is deliberately pure: inherited data is visible, while
accessors, custom hooks, proxies, foreign cells, and absent properties are not.
Three Symbol registry bridges convert tagged ZigString keys without userland
coercion and return stable Latin-1/UTF-16 views for descriptions and registered
keys. The GlobalSymbolRegistry is one object per C context group from realm
creation onward; local/well-known symbols remain unregistered and VM boundaries
remain isolated.
Four additional string-construction exports copy every tagged ZigString form,
validate raw UTF-8 conversion, canonicalize atom backing within one VM, and
concatenate ordered ToString results with exact UTF-16 semantics. Source
mutation, same-VM siblings, foreign values, abrupt completion, and a pre-existing
exception are covered.
Two borrowed ZigString output exports cache stable group-lifetime views as
untagged Latin-1 or tagged UTF-16. Direct JSString conversion validates the
cell and VM; JSValue conversion performs observable ToString and publishes
Symbols, thrown values, foreign values, and allocation failure through the
shared exception boundary.
Five error-factory exports create fresh selected-realm Error, TypeError, and
RangeError objects from ZigString message/code pairs and all BunString forms.
They reproduce the pinned writable TypeError code and read-only RangeError code
descriptors, omit empty codes, reject dead input, and preserve the first VM
exception.
They also cover fresh ordinary/null-prototype construction and exact boxed
Number/String/Boolean/BigInt unwrapping, plus four-way BigInt/Number comparison,
arbitrary-precision BigInt addition, and the pinned timeval-to-BigInt formula.
Private ToObject/prototype queries preserve object identity, box every
object-capable primitive kind in the selected realm, observe proxy/null
prototypes, and reject nullish or foreign inputs.
The numeric DateInstance pair creates fresh selected-realm Date cells without
TimeClip and reads their raw internal doubles, including `-0`, NaN, infinities,
and values outside the JavaScript Date-constructor range.
Four Date parsing/ISO exports create fresh Date cells from NUL-terminated input,
extract same-VM UTC epoch milliseconds, and write exact ordinary or extended
UTC ISO text failure-atomically into 28-byte buffers. The Date-now writer shares
the real Unix wall clock with `Date.now()`, `Date()`, and `new Date()`; its ABI
follows Bun's executable wrapper/C++ contract because the pinned Zig declaration
has an incompatible stale signature.
The VM exception slice supplies one pending exception per shared context group,
stable exception-cell identity, exact primitive/Error unwrapping, and
has/clear/take/rethrow classification.
The top-exception/termination slice uses the pinned caller-owned 8/56-byte
scope layout, preserves VM identity across sibling realms, and distinguishes
pure pending reads from trap-aware termination materialization. Termination
requests and execution-forbidden state are atomic and VM-wide; selective clear
retains the stable termination exception until explicit termination clear.
Selected-realm OutOfMemoryError creation does not throw, while OOM and stack
overflow throw helpers publish exact error kinds without replacing the first
pending exception. Nine VM heap controls expose shared live, external, and
saturating extra-memory accounting, deferred and full collection, weak-state
processing, idle footprint reclamation, and positive-duration opportunistic job
checkpoints. Precise heaps consume zig-gc's race-safe accounting snapshot and
return the size after the completed full sweep; arena-backed VMs report their
committed capacity. Seven job/registry controls add realm-local native and
encoded microtasks, VM-wide live-realm draining, one-shot unhandled-rejection
notification, exact per-realm module deletion, and safe delete-all-code. Native
payloads execute once, encoded values must belong to the selected VM, reentrant
jobs drain to quiescence, and a throwing job retains the untouched FIFO tail.
Code deletion clears selected-realm module/source caches and blocks until every
native execution or compilation lease retires before resetting tiers and
unmapping pages; subsequent calls fall back safely and may recompile. Eight
strong/weak reference exports retain the consumer-visible EncodedJSValue
slot at offset zero, root exact same-VM values across collection, accept sibling
realms, and reject foreign-VM replacement. Weak object targets use zig-gc atomic
external slots, clear without retention, and deliver the FetchResponse owner
callback once after GC clearing but never after explicit clear/delete. Wrappers
retain their VM through deletion, and root-list mutation is synchronized with
concurrent tracing. The array/index slice supplies exact
logical-length and hole behavior, direct put/push/read operations that bypass
inherited setters, ordinary indexed reads that observe prototypes and getters,
VM exception publication for abrupt completion, sparse growth, and the u32
maximum-length boundary.
The JSArray constructor pair adds failure-atomic packed construction from
encoded slices and hole-only construction through the maximum u32 length,
preserving selected-realm prototypes and same-VM sibling value identity while
publishing foreign values and invalid lengths through the pending exception.
The two contiguous-vector exports provide stable JSC64 snapshots for eligible
packed arrays and require exact array/vector/length/backing/element
revalidation before direct reads. Multiple snapshots coexist; GC preserves
them, while mutation, holes, accessors, double/undecided storage, and indexed
prototype pollution force the consumer back to ordinary indexed Get.
`ArrayBuffer__fromSharedMemfd` validates and temporarily duplicates a caller
descriptor, maps the declared complete regular-file extent read/write with
`MAP_PRIVATE`, and exposes one overflow-checked subrange without copying as the
profile-selected ArrayBuffer or Uint8Array type. Only the duplicate is closed;
the caller descriptor remains owned by the caller. The mapping's idempotent
owner unmaps the complete extent exactly once on failed construction, precise
collection, or context teardown. Invalid descriptors, undersized files,
ranges, and result tags return empty without publishing a partial value or
pending exception.
The private copy/allocation boundary creates isolated ArrayBuffers, allocates
uninitialized Uint8Array storage for direct native filling, and preserves Bun's
historical `Bun__allocArrayBufferForCopy` behavior: that name returns a
Buffer-identified Uint8Array view. Its output pointer is written only after the
view is complete. Default-allocator Uint8Array and ArrayBuffer constructors
adopt non-empty mimalloc storage without copying and release it exactly once;
zero-length sentinel pointers are never adopted.
Private ToNumber performs the complete number-hint object coercion path,
including user hooks and thrown conversions, preserves primitive and ordinary
NaN behavior, throws for Symbol/BigInt, and retains the first VM exception.
Private has-instance and iterator-method predicates preserve JSC's narrower
internal prechecks, run ordinary/custom/proxy or object GetMethod behavior, and
publish invalid prototypes, getters, and non-callable methods through the VM
exception boundary.
Private string inclusion applies ordered full ToString coercion and exact
UTF-16 code-unit substring matching, including astral/surrogate boundaries and
VM exception publication.
Private class and AggregateError classification uses executable/native
constructability and immutable error metadata, not mutable names or prototypes.
Sibling C-API realms share well-known Symbols and the Symbol registry.
Private Object keys/values create fresh selected-realm arrays in own enumerable
string-key order. Keys do not read values; values execute getters in order, and
proxy traps or thrown getters publish through the shared VM exception slot.
String-wrapper indices are counted as UTF-16 code units.
The 13 native StringBuilder exports preserve the pinned 24-byte/8-byte
caller-owned storage contract and exact Latin-1/UTF-8/UTF-16 code units,
including astral and lone-surrogate content. Integer and double formatting,
JSON quoting, capacity overflow, non-destructive conversion, OOM publication,
and first-pending-exception behavior match the pinned WebKit boundary.
The two MarkedArgumentBuffer exports create a synchronous callback-only native
container and root appended same-VM cells across precise collection until
unconditional callback cleanup. Three CommonJS extension exports maintain a
separate rooted value registry per realm with exact append, set, and
swap-remove return behavior.
The ten private Promise/InternalPromise exports create selected-realm pending
or directly settled native promises, downcast exact Promise cells, preserve
result/reason identity, and implement the pinned callback wrappers.
`JSPromise__wrap` passes Promise results through and rejects callback Errors or
throws; `AnyPromise__wrap` performs normal settlement, including thenable
assimilation and self-resolution rejection. `JSC__JSValue___then` registers a
detached native reaction pair and invokes only the selected JSHostFn at the next
Promise checkpoint with `(settlement value, retained context)` in an exact
JSC64 CallFrame. FIFO order, GC roots, sibling-realm identity, reentry, callback
throws, and the pending-exception boundary are covered. The seven Home-only native Map
operations bypass mutable userland prototypes and preserve SameValueZero keys,
exact identity, insertion order, live size, sibling values, and failure-atomic
foreign-VM rejection. The shared FFI slow paths perform exact signed/unsigned
modulo-2^64 conversion for validated heap BigInts. CommonAbortReason conversion
creates fresh selected-realm TimeoutError/AbortError DOMExceptions with the
pinned messages and legacy codes. Three module-loader exports add persistent
source registration, normalized relative/file resolution, cached namespace
identity, exact Promise cells, the evaluate fulfilled/rejected/pending
tri-state, top-level-await settlement, and precise module-graph roots. The
JSString backing iterator adds exact Latin-1/UTF-16 callback delivery with
caller-owned stop and lifetime semantics. `JSFunction__createFromZig` adds
owned function metadata and exact JSC64 `CallFrame` delivery for call and
construct callbacks, including pending-exception and foreign-return rejection.
Three adjacent CallFrame exports expose the active callback's visible caller
without changing its pinned register words: owned source URL, one-based line and
column, exact `builtin://bun/main` recognition, and a thread-local NUL-terminated
debug description. Identity/VM checks reject null, stale, mismatched, and foreign
frames, while nested native reentry restores the outer descriptor.
Four FFI-function exports reuse those callbacks with a distinct runtime brand.
Names/arity are owned, call and construct share the pinned callback, nullable
native data is atomically mutable, and the optional `ptr` property is the exact
callback-address bit pattern with upstream read-only/enumerable/configurable
attributes. Dynamic-library metadata remains separate from `dataPtr`; only
validated FFI cells accept get/set, independent of their owning VM.
The structured exception boundary retains creation-time frames separately from
`.stack` and fills caller-owned Home/Bun buffers through the exact 48-byte trace,
72-byte frame, 12-byte position, and 216-byte exception layouts. Full projection
classifies Error, DOMException, primitive, and system-like values; owns its
strings; preserves the stable exception cell; and reports the cause runtime
type. The second pass resolves the retained script identity and copies the
current source line plus capped preceding lines with exact zero-based numbers,
including through a sibling realm. The combined 352-symbol fixture also covers
foreign-VM failures, exception clearing, callback reentrancy, and already-settled
targets.

`JSObjectCallAsFunctionReturnValueHoldingAPILock` recursively holds the owning
VM API lock, defaults a null receiver to the realm global, preserves argument
order, and returns a thrown value as an exception cell without leaving a
pending exception. `JSObjectGetProxyTarget` projects a live proxy's exact target
without invoking traps and rejects non-proxies, revoked proxies, and non-value
private handles. The Home and Bun compiled-consumer fixtures exercise both
signatures and behaviors in Debug and ReleaseSafe.

`Bun__JSC__operationMathPow` and the JavaScript `Math.pow` builtin share one
ECMAScript operation. It preserves JSC's NaN, infinity, signed-zero,
negative-base, and odd/even exponent behavior instead of exposing host-libm
exceptions at the private boundary.

The three async-context call exports snapshot a realm's active context into a
branded, non-callable frame with precise GC edges. Calling the frame installs
the captured value only for the callback's dynamic extent, restores the prior
value before normal return or exception publication, preserves argument and
receiver semantics, and never crosses VM ownership. With no active context the
original callback is returned unchanged, including its exact encoded identity.

The ten DOMFormData exports use the engine's branded JS entry list as their
single source of truth. They cover VM-scoped downcasts, empty and
form-urlencoded construction, USVString append, Blob/File append with exact
opaque native-pointer roundtrip, insertion-order callbacks, duplicate counts,
and query serialization that omits files. The Home and Bun fixtures separately
compile the pinned declarations and exercise native-created and JS-created
instances.

The CommonStrings projection maps the pinned 13-value Bun enum to one stable
encoded string cell per value per VM, shared by sibling realms but never by
independent VMs.

The FetchHeaders projection shares one branded ref-counted record with the
JavaScript `Headers` implementation. Its 21 core exports cover lifecycle,
JS/native conversion, cloning, validated mutation/query, the 94-value fast-name
enum, and checked sorted buffer projection. A 22nd export copies the pinned
PicoHeaders `{ptr,len}` rows with raw HTTP-map duplicate semantics. The three
opaque UWS/H3 adapters use an installed, version/size-checked v1 consumer table
for the real C++ methods. Missing/failed request bridges return an empty handle;
the response bridge receives Set-Cookie, known, then uncommon rows and applies
the pinned TCP/SSL/H3 state rules.

`Bun__attachAsyncStackFromPromise` reconstructs stackless native Errors from
pending async-await chains. Promise links retain only suspended activations,
survive GC and settlement-to-microtask handoff, follow each transparent
return/then forwarding segment for at most 32 hops, and stop at combinators or
settled/invalid links. It preserves existing/materialized stacks and pending
exceptions while honoring the selected realm's `Error.stackTraceLimit`.

Bun's separately pinned core `src/jsc` inventory reports 461 private symbols,
of which 424 shims are implemented and 37 remain pending. Its
source/signature audit is `zig build bun-private-abi-audit`; broader Bun runtime
and generated bindings are outside that first core profile. The inventoried
`JSFunctionCall` declaration is consumer-provided because each runtime-compiled
FFI module emits and resolves its own definition. Bun JSType numbering
is selected with `-Dprivate-abi-consumer=bun` and verified by
`zig build test-private-jstype -Dprivate-abi-consumer=bun`.

`ZJSContextGetCollectionEpoch` returns the monotonic count of explicit
`JSGarbageCollect` calls for a context group. Every realm in the group observes
the same epoch; arena-backed groups use it as a semantic weak-processing
boundary even though physical storage remains allocated until VM teardown.
`ZJSValueIsReachable` performs a quiescent, cycle-safe walk from every strong
root in the group, including sibling realms, closures, environments, promises,
and microtasks; WeakRef and weak-collection edges do not retain the queried
value. It reports semantic reachability and does not reclaim storage.

`JSC__JSGlobalObject__generateHeapSnapshot`,
`Bun__generateHeapSnapshotV8`, and `Bun__generateHeapProfile` reuse that exact
VM-wide strong graph with property, index, variable, and internal edge labels.
They publish WebKit GCDebugging v3, Chrome/V8 `.heapsnapshot`, and a complete
Markdown cell/edge inventory respectively. The profile accounts ArrayBuffer
backing bytes and computes retained sizes from the graph's dominator tree.
Stable IDs survive repeated arena snapshots and precise-GC compaction; Home and
Bun retain their distinct pointer and by-value string ownership ABIs. Run
`zig build test-private-heap-snapshot`.

`Bun__setSamplingInterval`, `Bun__startCPUProfiler`, and
`Bun__stopCPUProfiler` provide per-VM cooperative CPU sampling without a timer
thread reading live frames. Chrome `.cpuprofile` output contains parent-sensitive
nodes, samples, deltas, source positions, and position ticks; the Markdown form
reports hot functions, call relationships, and files from the same samples.
The interval is atomically published, restarting clears the prior session, and
Home/Bun keep their distinct owned-string layouts. Run
`zig build test-private-cpu-profile`.

## Objective-C bridge target

The Objective-C compatibility target is separately pinned to macOS SDK 27.0
build 26A5368g. Its machine-readable inventory covers 11 interfaces, categories,
and protocols plus 108 methods, properties, typedefs, data symbols, and macros
from `JSContext.h`, `JSValue.h`, `JSVirtualMachine.h`, `JSManagedValue.h`, and
`JSExport.h`. `zig build objc-api-audit` verifies the checked-in copies and
inventory on every host; `zig build test-objc-api-headers` compiles the umbrella
under the real macOS Objective-C ARC/blocks frontend. On macOS,
`zig build test-objc-api` also compiles, links, and runs a host against the
zig-js runtime classes. A live SDK comparison is:

```sh
python3 tools/verify-objc-api.py \
  --sdk-root "$(xcrun --sdk macosx --show-sdk-path)"
```

The inventory records **108 implemented / 0 pending** declarations. Coverage
includes VM/context construction, evaluation, C-ref wrapper identity, context
metadata, primitive and native object factories, type predicates,
numeric/string/geometry/Foundation conversion, comparisons, calls,
construction, property operations, promise callback state, managed owner/value
relations, exact wrapper identity, typed Objective-C blocks, `JSExport`
instances/classes/renamed selectors, and property-descriptor symbols. The
18-row Objective-C transcript matches system JavaScriptCore exactly
(`360c1ad3ccf51d6b`), including managed-owner behavior, same-VM cross-context
value identity, exported receivers, constructors, prototypes, and target-context
wrapper behavior. See
the [Objective-C bridge inventory
guide](objc-api/README.md) for the exact boundary and reproduction details.
The complete declared inventory does not claim compatibility with private JSC
framework internals. Managed values clear semantically at explicit collection
epochs while arena storage remains VM-lifetime.
`zig build test-objc-api-evidence` batches header, runtime, system-JSC
differential, 200-cycle lifetime/autorelease, ASan/UBSan,
deterministic allocation/registration fault injection, and Apple leak-checker
gates; the current leak result is 0 leaked bytes.

The project is still pre-stabilization. Compatibility-shaped entry points are an embedder convenience, not a promise to preserve inert arguments or incomplete JavaScriptCore behavior. When a compatibility shim conflicts with clear zig-js semantics, the shim should either grow real behavior or be redesigned before the API is declared stable.

## Minimal embedding

```c
#include <JavaScriptCore/JavaScript.h>

int main(void) {
  JSGlobalContextRef ctx = JSGlobalContextCreate(NULL);

  JSStringRef script = JSStringCreateWithUTF8CString("40 + 2");
  JSValueRef result = JSEvaluateScript(ctx, script, NULL, NULL, 0, NULL);

  double n = JSValueToNumber(ctx, result, NULL);   // 42.0

  JSStringRelease(script);
  JSGlobalContextRelease(ctx);
  return 0;
}
```

Link against `libzig-js.a` instead of JavaScriptCore when your host only uses the implemented surface below.

## Implemented surface

::: code-group
```c [Context]
JSContextGroupRef  JSContextGroupCreate(void);
JSContextGroupRef  JSContextGroupRetain(JSContextGroupRef);
void               JSContextGroupRelease(JSContextGroupRef);
JSGlobalContextRef JSGlobalContextCreate(JSClassRef);
JSGlobalContextRef JSGlobalContextCreateInGroup(JSContextGroupRef, JSClassRef);
JSGlobalContextRef ZJSGlobalContextCreateThreaded(bool gil);
JSGlobalContextRef ZJSGlobalContextCreateGarbageCollected(bool enableJIT);
bool               ZJSContextRequestGarbageCompaction(JSContextRef);
typedef enum ZJSGCCompactionStatus {
    kZJSGCCompactionUnsupported,
    kZJSGCCompactionNoCandidates,
    kZJSGCCompactionOutOfMemory,
    kZJSGCCompactionCompacted,
} ZJSGCCompactionStatus;
ZJSGCCompactionStatus ZJSContextCompactGarbage(
    JSContextRef, size_t* movedCells, size_t* movedBytes);
JSGlobalContextRef JSGlobalContextRetain(JSGlobalContextRef);
void               JSGlobalContextRelease(JSGlobalContextRef);
JSObjectRef        JSContextGetGlobalObject(JSContextRef);
JSContextGroupRef  JSContextGetGroup(JSContextRef);
JSGlobalContextRef JSContextGetGlobalContext(JSContextRef);
JSStringRef        JSGlobalContextCopyName(JSGlobalContextRef);
void               JSGlobalContextSetName(JSGlobalContextRef, JSStringRef);
bool               JSGlobalContextIsInspectable(JSGlobalContextRef);
void               JSGlobalContextSetInspectable(JSGlobalContextRef, bool);
bool               JSCheckScriptSyntax(JSContextRef, JSStringRef source,
                                       JSStringRef sourceURL,
                                       int startingLineNumber, JSValueRef* exception);
JSValueRef         JSEvaluateScript(JSContextRef, JSStringRef source,
                                    JSObjectRef thisObject, JSStringRef sourceURL,
                                    int startingLineNumber, JSValueRef* exception);
void               JSGarbageCollect(JSContextRef);
```

```c [Values]
JSType      JSValueGetType(JSContextRef, JSValueRef);
bool        JSValueIsUndefined(JSContextRef, JSValueRef);
bool        JSValueIsNull(JSContextRef, JSValueRef);
bool        JSValueIsBoolean(JSContextRef, JSValueRef);
bool        JSValueIsNumber(JSContextRef, JSValueRef);
bool        JSValueIsString(JSContextRef, JSValueRef);
bool        JSValueIsSymbol(JSContextRef, JSValueRef);
bool        JSValueIsBigInt(JSContextRef, JSValueRef);
bool        JSValueIsObject(JSContextRef, JSValueRef);
bool        JSValueIsObjectOfClass(JSContextRef, JSValueRef, JSClassRef);
bool        JSValueIsArray(JSContextRef, JSValueRef);
bool        JSValueIsDate(JSContextRef, JSValueRef);
JSTypedArrayType JSValueGetTypedArrayType(JSContextRef, JSValueRef, JSValueRef* exception);
bool        JSValueIsEqual(JSContextRef, JSValueRef, JSValueRef, JSValueRef* exception);
bool        JSValueIsStrictEqual(JSContextRef, JSValueRef, JSValueRef);
bool        JSValueIsInstanceOfConstructor(JSContextRef, JSValueRef,
                                           JSObjectRef constructor,
                                           JSValueRef* exception);
JSRelationCondition JSValueCompare(JSContextRef, JSValueRef, JSValueRef,
                                   JSValueRef* exception);
JSRelationCondition JSValueCompareInt64(JSContextRef, JSValueRef, int64_t,
                                        JSValueRef* exception);
JSRelationCondition JSValueCompareUInt64(JSContextRef, JSValueRef, uint64_t,
                                         JSValueRef* exception);
JSRelationCondition JSValueCompareDouble(JSContextRef, JSValueRef, double,
                                         JSValueRef* exception);
JSValueRef  JSValueMakeUndefined(JSContextRef);
JSValueRef  JSValueMakeNull(JSContextRef);
JSValueRef  JSValueMakeBoolean(JSContextRef, bool);
JSValueRef  JSValueMakeNumber(JSContextRef, double);
JSValueRef  JSValueMakeString(JSContextRef, JSStringRef);
JSValueRef  JSValueMakeSymbol(JSContextRef, JSStringRef description);
JSValueRef  JSBigIntCreateWithDouble(JSContextRef, double, JSValueRef* exception);
JSValueRef  JSBigIntCreateWithInt64(JSContextRef, int64_t, JSValueRef* exception);
JSValueRef  JSBigIntCreateWithUInt64(JSContextRef, uint64_t, JSValueRef* exception);
JSValueRef  JSBigIntCreateWithString(JSContextRef, JSStringRef, JSValueRef* exception);
JSValueRef  JSValueMakeFromJSONString(JSContextRef, JSStringRef);
JSStringRef JSValueCreateJSONString(JSContextRef, JSValueRef, unsigned indent,
                                    JSValueRef* exception);
bool        JSValueToBoolean(JSContextRef, JSValueRef);
double      JSValueToNumber(JSContextRef, JSValueRef, JSValueRef* exception);
int32_t     JSValueToInt32(JSContextRef, JSValueRef, JSValueRef* exception);
uint32_t    JSValueToUInt32(JSContextRef, JSValueRef, JSValueRef* exception);
int64_t     JSValueToInt64(JSContextRef, JSValueRef, JSValueRef* exception);
uint64_t    JSValueToUInt64(JSContextRef, JSValueRef, JSValueRef* exception);
JSStringRef JSValueToStringCopy(JSContextRef, JSValueRef, JSValueRef* exception);
JSObjectRef JSValueToObject(JSContextRef, JSValueRef, JSValueRef* exception);
void        JSValueProtect(JSContextRef, JSValueRef);
void        JSValueUnprotect(JSContextRef, JSValueRef);
bool        ZJSValueProtect(JSContextRef, JSValueRef);   // zig-js extension
bool        ZJSValueUnprotect(JSContextRef, JSValueRef); // zig-js extension
```

```c [Objects]
JSClassRef  JSClassCreate(const JSClassDefinition*);
JSClassRef  JSClassRetain(JSClassRef);
void        JSClassRelease(JSClassRef);
JSObjectRef JSObjectMake(JSContextRef, JSClassRef, void* data);
JSValueRef  JSObjectGetPrototype(JSContextRef, JSObjectRef);
void        JSObjectSetPrototype(JSContextRef, JSObjectRef, JSValueRef);
bool        JSObjectHasProperty(JSContextRef, JSObjectRef, JSStringRef);
bool        JSObjectHasPropertyForKey(JSContextRef, JSObjectRef, JSValueRef key,
                                      JSValueRef* exception);
JSValueRef  JSObjectGetPropertyForKey(JSContextRef, JSObjectRef, JSValueRef key,
                                      JSValueRef* exception);
void*       JSObjectGetPrivate(JSObjectRef);
bool        JSObjectSetPrivate(JSObjectRef, void* data);
JSObjectRef JSObjectMakeArray(JSContextRef, size_t argc, const JSValueRef args[], JSValueRef* exception);
JSObjectRef JSObjectMakeDate(JSContextRef, size_t argc, const JSValueRef args[], JSValueRef* exception);
JSObjectRef JSObjectMakeError(JSContextRef, size_t argc, const JSValueRef args[], JSValueRef* exception);
JSObjectRef JSObjectMakeRegExp(JSContextRef, size_t argc, const JSValueRef args[], JSValueRef* exception);
JSObjectRef JSObjectMakeFunction(JSContextRef, JSStringRef name, unsigned parameterCount,
                                 const JSStringRef parameterNames[], JSStringRef body,
                                 JSStringRef sourceURL, int startingLineNumber,
                                 JSValueRef* exception);
JSObjectRef JSObjectMakeDeferredPromise(JSContextRef, JSObjectRef* resolve,
                                        JSObjectRef* reject, JSValueRef* exception);
JSValueRef  JSObjectGetProperty(JSContextRef, JSObjectRef, JSStringRef name, JSValueRef* exception);
void        JSObjectSetProperty(JSContextRef, JSObjectRef, JSStringRef name,
                                JSValueRef value, JSPropertyAttributes, JSValueRef* exception);
void        JSObjectSetPropertyForKey(JSContextRef, JSObjectRef, JSValueRef key,
                                      JSValueRef value, JSPropertyAttributes,
                                      JSValueRef* exception);
JSValueRef  JSObjectGetPropertyAtIndex(JSContextRef, JSObjectRef, unsigned index,
                                       JSValueRef* exception);
void        JSObjectSetPropertyAtIndex(JSContextRef, JSObjectRef, unsigned index,
                                       JSValueRef value, JSValueRef* exception);
bool        JSObjectDeleteProperty(JSContextRef, JSObjectRef, JSStringRef,
                                   JSValueRef* exception);
bool        JSObjectDeletePropertyForKey(JSContextRef, JSObjectRef, JSValueRef key,
                                         JSValueRef* exception);
JSValueRef  JSObjectCallAsFunction(JSContextRef, JSObjectRef, JSObjectRef thisObject,
                                   size_t argc, const JSValueRef args[], JSValueRef* exception);
JSObjectRef JSObjectMakeFunctionWithCallback(JSContextRef, JSStringRef name,
                                             JSObjectCallAsFunctionCallback callback);
JSObjectRef JSObjectCallAsConstructor(JSContextRef, JSObjectRef constructor,
                                      size_t argc, const JSValueRef args[], JSValueRef* exception);
bool        JSObjectIsFunction(JSContextRef, JSObjectRef);
bool        JSObjectIsConstructor(JSContextRef, JSObjectRef);
```

```c [Typed arrays]
JSObjectRef JSObjectMakeTypedArray(JSContextRef, JSTypedArrayType, size_t length,
                                   JSValueRef* exception);
JSObjectRef JSObjectMakeTypedArrayWithBytesNoCopy(
    JSContextRef, JSTypedArrayType, void* bytes, size_t byteLength,
    JSTypedArrayBytesDeallocator, void* deallocatorContext, JSValueRef* exception);
JSObjectRef JSObjectMakeTypedArrayWithArrayBuffer(JSContextRef, JSTypedArrayType,
                                                  JSObjectRef buffer, JSValueRef* exception);
JSObjectRef JSObjectMakeTypedArrayWithArrayBufferAndOffset(
    JSContextRef, JSTypedArrayType, JSObjectRef buffer, size_t byteOffset,
    size_t length, JSValueRef* exception);
void*       JSObjectGetTypedArrayBytesPtr(JSContextRef, JSObjectRef, JSValueRef* exception);
size_t      JSObjectGetTypedArrayLength(JSContextRef, JSObjectRef, JSValueRef* exception);
size_t      JSObjectGetTypedArrayByteLength(JSContextRef, JSObjectRef, JSValueRef* exception);
size_t      JSObjectGetTypedArrayByteOffset(JSContextRef, JSObjectRef, JSValueRef* exception);
JSObjectRef JSObjectGetTypedArrayBuffer(JSContextRef, JSObjectRef, JSValueRef* exception);
JSObjectRef JSObjectMakeArrayBufferWithBytesNoCopy(
    JSContextRef, void* bytes, size_t byteLength, JSTypedArrayBytesDeallocator,
    void* deallocatorContext, JSValueRef* exception);
void*       JSObjectGetArrayBufferBytesPtr(JSContextRef, JSObjectRef, JSValueRef* exception);
size_t      JSObjectGetArrayBufferByteLength(JSContextRef, JSObjectRef, JSValueRef* exception);
```

```c [Strings]
JSStringRef JSStringCreateWithCharacters(const JSChar* characters, size_t length);
JSStringRef JSStringCreateWithUTF8CString(const char* string);
JSStringRef JSStringRetain(JSStringRef);
void        JSStringRelease(JSStringRef);
size_t      JSStringGetLength(JSStringRef);
const JSChar* JSStringGetCharactersPtr(JSStringRef);
size_t      JSStringGetMaximumUTF8CStringSize(JSStringRef);
size_t      JSStringGetUTF8CString(JSStringRef, char* buffer, size_t bufferSize);
bool        JSStringIsEqual(JSStringRef, JSStringRef);
bool        JSStringIsEqualToUTF8CString(JSStringRef, const char*);
```

```c [Workers]
JSWorkerRef JSWorkerCreate(JSStringRef source);
JSWorkerRef JSWorkerCreateWithLimits(JSStringRef source,
                                     size_t maxMessageBytes,
                                     size_t maxQueuedBytes,
                                     size_t maxQueuedMessages);
bool        JSWorkerPostMessage(JSWorkerRef, JSContextRef, JSValueRef, JSValueRef* exception);
JSValueRef  JSWorkerReceive(JSWorkerRef, JSContextRef, uint64_t timeoutMs, JSValueRef* exception);
void        JSWorkerTerminate(JSWorkerRef);
void        JSWorkerRelease(JSWorkerRef);
bool        ZJSWorkerGetInspectorTargetInfo(JSWorkerRef, ZJSInspectorTargetInfo* info);
ZJSWorkerInspectorSessionRef ZJSWorkerInspectorSessionCreate(
    JSWorkerRef, ZJSInspectorMessageCallback, void* userData);
bool        ZJSWorkerInspectorSessionDispatch(
    ZJSWorkerInspectorSessionRef, const char* message, size_t messageLength);
ZJSWorkerInspectorPumpResult ZJSWorkerInspectorSessionPump(
    ZJSWorkerInspectorSessionRef, uint64_t timeoutMs);
void        ZJSWorkerInspectorSessionRelease(ZJSWorkerInspectorSessionRef);
```
:::

Native callbacks use the standard `JSObjectCallAsFunctionCallback` calling convention, so functions you expose to JavaScript through this subset are registered exactly as they are with JavaScriptCore. `JSObjectIsConstructor` uses the runtime's constructability check, including native constructors such as `Date` and `Array`. `JSObjectMakeArray` returns a real runtime Array object in the current realm, inheriting from that realm's `Array.prototype`. `JSObjectGetProperty` and `JSObjectGetPropertyAtIndex` perform JavaScript `[[Get]]`, including prototype lookup, accessor/proxy behavior, and exception reporting. `JSObjectSetProperty` maps `ReadOnly`, `DontEnum`, and `DontDelete` attributes to JavaScript `writable`, `enumerable`, and `configurable` descriptor fields. `JSValueIsEqual` performs JavaScript abstract equality (`==`), including object coercion and exception reporting. `JSValueGetType` reports Symbol primitives as `symbol` and BigInt primitives as the zig-js `bigint` extension instead of leaking the engine's object-tagged representation. `JSValueToNumber` matches `Number(value)`, including primitive/boxed BigInt conversion and exception reporting for throwing coercions or Symbols. `JSValueToStringCopy` performs JavaScript `ToString`, including object coercion and exception reporting for throwing coercions or Symbol values. `JSValueToObject` performs JavaScript `ToObject` conversion, returning real primitive wrapper objects and reporting an exception for `null` / `undefined`. `JSValueIsDate` reports the runtime's Date internal slot, including invalid Date objects. `ZJSGlobalContextCreateThreaded`, `ZJSGlobalContextCreateGarbageCollected`, `ZJSContextRequestGarbageCompaction`, `ZJSContextCompactGarbage`, and `JSWorker*` are zig-js extensions rather than public JSC symbols. Direct compaction requires a quiescent precise-GC context. `ZJSContextRequestGarbageCompaction` only schedules movement, so it is safe inside a native callback; after that frame unwinds, the current movement-safe baseline checkpoint or a direct quiescent call consumes it. Generic live native frames and conservative-stack modes remain fail-closed. Direct attempts report `unsupported`, `no_candidates`, `out_of_memory`, or `compacted` exactly and zero-initialize optional movement outputs.

A `JSValueRef` kept across a scheduled movement boundary must be rooted with
`ZJSValueProtect`/`ZJSValueUnprotect`.

`JSContextGroupCreate` owns one shared arena heap and executable-code lifetime.
Each `JSGlobalContextCreateInGroup` call creates a distinct realm with its own
global object, intrinsics, lexical environment, shapes, and microtask queue.
Values retain identity and may cross between realms in the same group; another
group is rejected deterministically. Every global context retains its group, so
releasing a realm handle cannot invalidate a value already retained by a peer
realm. The final group/context release tears down every realm and the shared VM
once. A non-null `JSClassRef` is attached to the actual global object, including
static members and initialize/finalize lifetime callbacks.

The zig-js extension header exposes `ZJSInspectorSessionCreate`,
`ZJSInspectorSessionDispatch`, and `ZJSInspectorSessionRelease` for the
versioned in-process JSON transport documented in [Inspector protocol](/inspector).
All successful C-API, eval, generated-function, and JavaScript-module parses
publish stable script IDs and exact adjusted statement locations. `debugger;`
and explicit pause requests stop at those
boundaries; URL/script breakpoints resolve to the nearest following statement
and may be removed deterministically. Step-into, step-over, and step-out use
ordinary-function logical call depth. The synchronous callback must issue a
continuation before returning. Exception policy distinguishes caught-origin
pauses from throws that actually escape `JSEvaluateScript`. Suspendable
generator/async VM chunks carry the same statement checkpoints across
yield/await. Debug-parsed ordinary functions use the tree walker; historical
bytecode retains latent checkpoints, and attachment withholds native entry so a
warmed function cannot bypass a pause. Ordinary VM frame slots are exposed as a
live named scope and synchronized after debugger evaluation. Paused events
expose live call frames, function/source locations, `this`, and lexical through
global scope chains. `Debugger.evaluateOnCallFrame` evaluates against a selected live
environment and may update its bindings before resume. Expandable remote-object
handles expose own data/accessor descriptors without invoking getters. Handles
are session-owned, group-releasable, protected across GC, and invalidated on
explicit release/session teardown; scope handles also expire on resume. Worker
target transport remains tracked by inspector issue #156. When several debugger sessions
are enabled, observers receive the paused state first and only the deterministic
owner may resume or step; explicit pause/step requests retain that ownership.
`ZJSInspectorSessionRelease` is safe from within a protocol callback: physical
teardown is deferred until the enclosing dispatch/pause/detach operation has
unwound, and releasing the pause owner acts as a deterministic resume.

`JSWorkerCreate*` does not take a parent `JSContextRef`; each worker owns an
independent runtime on its own thread. A context inspector therefore never
claims those workers as implicit child targets. Parent pauses leave worker
message processing and termination live (the C transcript performs both from
the paused callback). Every worker already publishes a process-wide non-zero
target ID, script/module kind, and atomic `starting`, `running`, `closing`, or
`closed` lifecycle snapshot through `ZJSWorkerGetInspectorTargetInfo`.
`ZJSWorkerInspectorSession*` attaches to that isolated runtime, queues commands
to its owner thread, and returns events through an explicit owner-side pump.
Session release waits until runtime-side backend/root cleanup completes, with an
embedded allocation-independent detach fallback if the command queue cannot
grow. Worker-first release closes accepted pending traffic and leaves a session
safe to pump to `closed` and release afterward. The completed evidence matrix
is recorded in issue #156.

`JSGlobalContextRetain` and `JSGlobalContextRelease` maintain a real C-API reference count for contexts created through this C API. Releasing a retained context destroys the underlying runtime only after the final release. `JSGlobalContextRetain` returns null for a null context or if retaining would overflow the context refcount.

The typed-array API uses the public JavaScriptCore enum layout through `BigUint64Array`. JavaScript `Float16Array` remains available inside the engine, but the pinned public JSC enum has no Float16 entry, so `JSValueGetTypedArrayType` reports `kJSTypedArrayTypeNone` for that runtime-only kind. ArrayBuffer-backed constructors preserve the original buffer and requested view geometry; invalid types return null, while detached, out-of-bounds, misaligned, overflowing, wrong-context, and non-ArrayBuffer inputs report through the exception out pointer.

The pointers returned by `JSObjectGetTypedArrayBytesPtr` and `JSObjectGetArrayBufferBytesPtr` are borrowed and temporary. They may be invalidated by later engine calls that detach, transfer, resize, or collect the backing object. Hosts must keep the corresponding JS object reachable and must synchronize their own native access with JavaScript execution.

The no-copy constructors transfer backing-store lifetime to the context. Their deallocator is invoked exactly once: immediately when construction fails, from object finalization in GC-enabled contexts, or during context teardown in arena contexts. A successful zero-length no-copy buffer may use a null byte pointer; a non-empty buffer requires a non-null pointer.

`JSEvaluateScript` rejects a null source string by returning null and reporting an exception through the out pointer when one is provided. For parse/lex failures, the exception is a `SyntaxError` object whose message includes the source name and adjusted line/column; the object also carries non-enumerable `sourceURL`, `line`, `column`, and `byteOffset` properties for embedders that do not want to parse message text. For runtime throws of Error objects, `sourceURL` and `startingLineNumber` are attached as non-enumerable properties, and the default `stack` string includes that source frame when present.

When an exception-capable API has produced a successful JavaScript result but cannot allocate the C `JSValueRef` / `JSStringRef` wrapper needed to return it, it reports `OutOfMemory` through the exception out pointer instead of returning an ambiguous silent null.

`JSObjectGetProperty`, `JSObjectGetPropertyAtIndex`, and `JSObjectSetProperty` reject null object refs and null property-name strings by reporting an exception through the out pointer.

`JSValueIsEqual`, `JSValueToNumber`, `JSValueToStringCopy`, and `JSValueToObject` reject null value refs by reporting an exception through the out pointer.

`JSValueRef` / `JSObjectRef` handles are owned by the context that created them. APIs that receive a `JSContextRef` reject handles from a different context instead of mixing arenas or object graphs: exception-capable APIs report a `TypeError`, while no-exception inspection/protection APIs return their invalid-handle result.

For no-exception value inspection APIs, a null or wrong-context value ref is an invalid handle, not JavaScript `undefined`: `JSValueGetType` returns the zig-js extension `invalid`, value predicates and `JSValueIsStrictEqual` return false, and `JSValueToBoolean` returns false.

Public `JSValueProtect` and `JSValueUnprotect` have JavaScriptCore's `void` ABI. The `ZJSValueProtect` and `ZJSValueUnprotect` extensions return whether the handle-table operation was accepted; they report false for invalid/null handles, missing protected entries on GC-enabled contexts, allocation failure, or protection-count overflow.

`JSObjectSetProperty` and `JSWorkerPostMessage` reject null value refs by reporting an exception through the out pointer instead of storing or posting JavaScript `undefined`.

`JSObjectMakeArray`, `JSObjectCallAsFunction`, and `JSObjectCallAsConstructor` reject null `argv` arrays when `argc > 0` and null value refs inside non-null argument arrays by reporting an exception through the out pointer.

`JSValueMakeString` rejects a null string ref by returning null instead of creating JavaScript `undefined`.

`JSStringCreateWithUTF8CString` accepts valid UTF-8 only. A null pointer or invalid UTF-8 byte sequence returns null, so later string APIs can use the validated UTF-8 backing safely.

`JSStringRetain` returns null for a null string ref or if retaining would overflow the string refcount; successful retains must still be paired with `JSStringRelease`.

Native callbacks installed with `JSObjectMakeFunctionWithCallback` must return a non-null value ref or set the exception out pointer; returning null without an exception throws a `TypeError` instead of implicitly producing JavaScript `undefined`.

`JSObjectCallAsFunction(..., thisObject, ...)` uses the provided object as the call receiver, or the context global object when `thisObject` is null.

`JSObjectCallAsConstructor` performs the runtime `[[Construct]]` path and reports constructor throws through the exception out pointer.

`JSObjectMakeFunctionWithCallback` returns null when the callback pointer is null.

`JSObjectMakeDate`, `JSObjectMakeError`, and `JSObjectMakeRegExp` invoke the
realm's retained intrinsic constructors, so replacing the corresponding global
binding does not change their behavior. `JSObjectMakeFunction` likewise uses the
intrinsic Function constructor, preserves the requested name and source text,
and annotates syntax exceptions with the supplied source URL and starting line.
`JSObjectSetPropertyForKey` performs `ToPropertyKey` exactly once, supports
Symbols and coerced primitive/object keys, propagates coercion/internal-method
exceptions, and applies JSC property attributes to newly created own properties.

`JSClassCreate` deep-copies its definition, static tables, and names, retains its parent, and uses an atomic reference count independent of the caller's definition storage. `JSObjectMake(..., class, data)` retains the class for the object lifetime, runs inherited initializers parent-first, finalizers child-first, and keeps the opaque pointer as host-owned private data. Automatic classes share a per-context, GC-rooted prototype carrying their static functions; `NoAutomaticPrototype` classes receive distinct own function objects, matching JSC. Static values use a tri-state internal-method bridge: null getter results remain absent, handled setters consume a write, declined setters do not accidentally create a data property, and `DontDelete` controls the delete result while class-defined values remain virtual. Reflection exposes JSC-compatible static-value descriptors and key membership; zig-js deliberately returns declared static names in deterministic child-first definition order instead of exposing JSC's internal hash-table iteration order. Every `JSClassDefinition` callback family runs through the interpreter: inherited dynamic properties and property names, call/construction, `hasInstance`, and number/string conversion all use JSC's handled/fallback and exception rules. `JSObjectCopyPropertyNames` returns a retained, deduplicated snapshot of enumerable names across the prototype chain; callback-added names participate in `Object.keys` and `Reflect.ownKeys` exactly as in JSC. `JSObjectMakeConstructor` creates JSC-compatible construct-only objects, retains the instance class through GC, and either invokes its explicit constructor callback or creates a class instance by default. Callback results and exceptions are realm-validated: foreign-context handles, null required results, non-object constructor results, and object-valued primitive conversions become deterministic local exceptions. `JSValueIsObjectOfClass` recognizes both the exact class and retained ancestors. `JSObjectGetPrivate` returns only host-owned private data; engine-owned native records are not exposed. `JSObjectSetPrivate` can update host-owned private data and can attach host data to plain objects that do not already carry engine private data.

`JSObjectGetPrototype` and `JSObjectSetPrototype` use the runtime's real `[[GetPrototypeOf]]`/`[[SetPrototypeOf]]` paths, including Proxy traps, invariants, cycle prevention, and null prototypes. Their pinned JSC signatures have no exception out pointer, so rejected/throwing mutations leave the object unchanged. `JSObjectHasProperty`, `JSObjectSetProperty`, `JSObjectDeleteProperty`, and indexed writes likewise use the engine's internal-method funnels rather than bypassing class callbacks, proxies, accessors, typed-array rules, or property attributes.

`JSObjectMakeDeferredPromise` returns a pending native Promise and stores callable resolve/reject functions in the required out pointers. Passing a null resolve or reject out pointer is a contract error reported through the exception out pointer. The returned functions settle the promise through the normal Promise job queue; embedder-observable callbacks run at the next microtask checkpoint, such as the one performed after `JSEvaluateScript`.

`JSWorkerPostMessage` and `JSWorkerReceive` use structured clone to move values between isolated worker contexts. Each worker uses an independent precise GC heap by default, so long-lived agents reclaim unreachable values before join. `JSWorkerCreate` uses the default 64 MiB per-message, 256 MiB queued-byte, and 1024 queued-message caps in both directions; `JSWorkerCreateWithLimits` sets all three explicitly (zero is a real zero limit). The message cap includes frame/manifest overhead and is enforced during serialization. Rejected closed/full/oversized delivery returns `false` and reports an exception instead of silently dropping a frame. `JSWorkerRef` handles are owner-thread-affine: post, receive, terminate, release, and inspector operations must be called on the thread that created the worker. Null or foreign-thread worker refs are rejected; exception-capable worker APIs report through the exception out pointer. Values that structured clone rejects, such as functions and Symbols, also report through the exception out pointer. Inspector target IDs are process-wide non-zero integers and never encode a worker address; exhaustion fails worker creation instead of reusing an identity. Worker inspector dispatch is asynchronous: accepted JSON is copied into a synchronized command queue, executed only by the worker runtime, and its response/events are copied back. `ZJSWorkerInspectorSessionPump` invokes one callback on the worker-handle owner thread (`timeoutMs == 0` waits indefinitely) and reports message, timeout, or closed explicitly. A paused worker keeps servicing this queue, so the pump callback may dispatch evaluation or its continuation without accessing the worker Context directly.

`JSStringCreateWithUTF8CString(null)` returns null. `JSStringGetUTF8CString` returns 0 for null strings, null output buffers, or zero buffer size; otherwise it writes a null-terminated UTF-8 prefix and returns the number of bytes written including the terminator.

## Caveats

> [!WARNING]
> The complete pinned macOS 27.0 public C inventory is implemented. This does
> not imply compatibility with Objective-C `JSValue`/`JSContext`, WebKit private
> internals, or the still-growing pause/breakpoint/stepping portion of the zig-js
> inspector protocol; those remain tracked by [the umbrella roadmap](https://github.com/zig-utils/zig-js/issues/134)
> and [inspector issue](https://github.com/zig-utils/zig-js/issues/139). The
> language/runtime scope is whatever the configured conformance runner currently
> proves — see [Conformance](/conformance).

Some functions intentionally keep JavaScriptCore-shaped signatures while zig-js is still pre-stabilization, but the documented parameters now either have real behavior or fail fast when the underlying feature is out of scope. `JSEvaluateScript` honors `thisObject`, uses `sourceURL` / `startingLineNumber` for syntax and runtime Error metadata, and parser-created SyntaxErrors expose non-enumerable line/column diagnostics instead of requiring callers to parse message text. `JSGlobalContextRetain` / `JSGlobalContextRelease` maintain a real C-API reference count, `JSObjectMakeFunctionWithCallback` honors the provided function name, and `JSObjectSetProperty` honors property attributes.

**Threading.** Handles are affine to the thread that owns their context group.
Values may cross global contexts in the same group while retaining identity;
different groups are rejected. `JSWorkerRef` and inspector-session handles are
also owner-thread-affine. Use worker messages, not worker handles, as the
cross-thread boundary; see the [threading docs](/threads/).
