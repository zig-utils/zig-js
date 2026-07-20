# Replacing JSC/WebKit in Home with zig-js

> Status: **public profile verified; private migration not started**
> (2026-07-20). Home currently links vendored JavaScriptCore. zig-js now proves
> the exact 50-function public M1 consumer at Home revision `7ed99c02`, while
> private profiles explicitly support `7ed99c02` and the byte-identical JSC
> source aliases `5e829ad4`, `38702f9e`, and `4389ddee`. The broader private
> runtime remains separate work.

## Why this is not a link-swap

Home (`~/Code/Home/lang`) is the Bun-parity runtime. Its production runtime is
coupled to JSC **internals** through Bun's C++ binding layer. A prior built-binary
inventory measured:

| Surface | Symbols Home references |
|---|---:|
| JSC LowLevelInterpreter (`_jsc_llint_*`) — the bytecode engine | thousands |
| `Bun__*` / `JSC__*` binding entry points (C++) | **804 distinct** |
| Generated-class C++ bindings (`*Prototype__*`, `*Class__*`, `__construct`, `__finalize`) | **~4,325** |
| Public JSC C API references in that binary | **~17** |

Separately, Home revision `7ed99c02e50034f869d0db6d487115bb44332fe4`
contains a newer public-C M1 pathway with 50 Zig `extern "c"` declarations.
zig-js exports all 50 and runs its pinned compile-link-runtime fixture. The
[machine-readable profile](abi/home-public-c-7ed99c02.json) records exact source
hashes, calling convention, layouts, enum values, and semantic assumptions;
`zig build test-home-public-abi -Dhome-source-root="$HOME/Code/Home/lang"`
checks the live checkout too.

zig-js's complete public target is now 117 functions plus 22 extensions.
Nevertheless, **zig-js is not yet a drop-in for the JSC that Home's production
runtime links**: success of the 50-function public profile says nothing about
the thousands of LLInt and private/generated binding symbols above.

The first source-level private inventory is now reproducible too. At the same
pinned Home revision, 66 JSC source files containing legacy/private
`extern fn` declarations contain 538 unique symbols: 471 private
JSC/Bun/WebCore imports, 59 public-C overlaps already implemented by zig-js,
seven platform libc imports, and one consumer-generated `JSFunctionCall`
definition. See [the exact declaration inventory](abi/home-private-7ed99c02-inventory.json)
and run:

```sh
zig build home-private-abi-audit \
  -Dhome-private-abi-profile=home-private-4389ddee \
  -Dhome-source-root="$HOME/Code/Home/lang"
```

This verifies the live revision, every source hash, signature, classification,
and calling convention. It replaces a vague source-level estimate: the 471
private imports are now 410 implemented / 61 pending under #163. The generated
FFI wrapper emits and resolves `JSFunctionCall` inside its own compiled module,
so zig-js must not provide a duplicate symbol. The implemented
slices cover JSC64 value identity, cell equality, truthiness, int32 extraction,
exact signed/unsigned 64-bit BigInt construction, and modulo-2^64 BigInt
extraction with the pinned number fallbacks, plus exact strict and SameValue
equality for primitives and context-owned cells. Six opaque BigInt cell shims
add exact arbitrary-size ordering against i64/u64/f64, signed modulo-2^64
extraction, and owned decimal conversion through the pinned 24-byte
`BunString`/refcounted `WTFStringImpl` ABI. Seven JSCell/JSString shims add exact UTF-16 and 8-bit string
semantics, value equality, object identity, and primitive boxing. The two
non-URL BunString conversion shims plus transfer and array construction decode
all pinned string representations, preserve lone surrogates and UTF-16-unit
prefixes, and publish selected-realm strings/arrays without partial transfer.
Four ZigString error constructors create fresh intrinsic Error, TypeError,
RangeError, and SyntaxError instances in the selected realm without consulting
mutable globals or replacing a pending VM exception.
The ZigString DOMException constructor implements all pinned codes 0 through
40, including the exact WebCore name/message/legacy-code table, Bun's code-9
SyntaxError divergence, special RangeError/TypeError/Error/undefined branches,
Node-style codes, message override, and the unknown-code empty-name fallback.
It also selects the requested realm and preserves the first pending exception.
Four shared string constructors copy Latin-1, UTF-8, and UTF-16 ZigStrings,
validate the raw UTF-8-to-16-bit path, canonicalize atom backing within one VM,
and concatenate ordered ToString results without losing UTF-16 surrogate
semantics. They preserve source ownership, accept sibling-realm values, reject
foreign VMs, and retain the first pending exception.
The two borrowed-output bridges return group-lifetime-stable Latin-1 or tagged
UTF-16 views from exact JSString cells and full JSValue ToString coercion. Their
cache is shared by sibling realms, isolated across VMs, and released with the
context group; invalid cells and abrupt completion zero the output safely.
Five private error factories consume ZigString message/code pairs or every
BunString representation and create fresh selected-realm Error, TypeError, and
RangeError objects. TypeError codes are writable, RangeError codes are
read-only, empty codes are omitted, and dead input or a pending exception fails
without exposing a partial result.
Three AggregateError bridges create a fresh ordered errors array from encoded
values or retain an exact supplied array and cause. They install the standard
non-enumerable descriptors, use selected-realm prototypes, reject foreign or
invalid input failure-atomically, and read the own `errors` slot without running
prototype getters.
Eight property-boundary shims create two-key selected-realm objects in the
pinned key-2-first order, perform direct own or single-coercion property-key
writes, delete through ordinary internal methods, and expose prototype-aware,
Object.prototype-cutoff, or own-only reads as required. Their focused cases
cover numeric/Symbol keys, accessors, proxies, duplicate keys, Latin-1 names,
same-VM siblings, foreign values, and exact empty/deleted exception sentinels.
The separate property-path shim implements the pinned UTF-16 dot/bracket
grammar and string/number array paths with one ordinary `Get` per traversed
segment. It preserves empty-key edge cases, present `undefined`, inherited
array entries, proxies, primitive boxing, and abrupt completion without an
extra observable `has` lookup.
Four class/display-name shims separate stable raw class metadata from
constructor-derived class names and observable display-name projection. Their
borrowed ZigString views remain group-owned, while BunString output owns exact
Latin-1 or UTF-16 storage; VM-inquiry class calculation does not invoke tag
getters, and the pinned name paths perform one observable `@@toStringTag` read.
The shared ErrorCode shim returns an owned BunString and uses the pinned Bun
diagnostic inspector after a falsy observable constructor lookup. Its focused
fixture covers null-prototype objects, descriptor-only accessors, cycles,
Proxy targets, custom inspection, UTF-16 escaping, failure atomicity, and
first-exception preservation in both Home and Bun profiles.
The paired JSON shims use the runtime's complete serializer with either the
pinned unsigned indentation request or undefined space for compact output.
They preserve `toJSON`, getter/proxy effects, ordering, omission/null behavior,
Unicode escaping, errors, selected-realm execution, and owned BunString output.
The paired record-construction shims copy native ZigString keys and values into
selected-realm ordinary objects. `fromEntries` preserves direct insertion,
duplicate last-value and integer-key order, and caller-buffer independence in
both clone modes. `putRecord` implements the pinned zero/one/many
empty-array/scalar/array cardinality and all-true own data descriptors without
running inherited setters; invalid, foreign, oversized, failed, or blocked
calls remain failure-atomic and preserve an existing exception.
The JSX element predicate performs exactly one ordinary `$$typeof` read and
recognizes only the legacy and transitional React symbols from the shared VM
registry. Inherited/accessor/proxy reads and sibling realms work normally;
local symbols, impostors, primitives, foreign cells, and exception paths retain
the pinned false-or-abrupt result without replacing pending state.
The paired deep-equality shims implement pinned SameValue and cyclic structural
comparison across ordinary properties, arrays, Map/Set, buffers/views, typed
arrays, boxed strings, Date, RegExp, and Error/cause state. Strict comparison
adds calculated-class, hole, property-count, missing/undefined,
cause-presence, and raw-float distinctions. Both retain observable getter/proxy
errors, same-VM sibling support, foreign rejection, bounded recursion, and
first-exception preservation.
The Jest-enabled variants add right-first asymmetric handling for all pinned
built-in matcher families, promise modes, negation, and custom matcher hooks.
Recursive subset matching preserves inherited/existing-property lookup,
Symbols, exact arrays, cycle termination, nested object-containing semantics,
and optional direct property replacement without changing the non-Jest path.
The five process-wide remote-inspector controls add atomic auto-start disable,
explicit start, system-console logging, and inspection-default state. The
default is deterministically disabled on modern Apple-family targets and
enabled elsewhere, and can be overridden independently of context
inspectability.
The proxy internal-field shim projects exact target/handler identities without
running traps, returns null fields after revocation, and safely rejects invalid
selectors and non-proxies. Canonical per-VM private object handles keep repeated
and sibling-realm EncodedJSValue publication bit-identical without crossing VM
boundaries.
The async-context call trio retains inactive callback identity, captures active
realm state in a non-callable branded frame, keeps its callback/context edges
precisely traced and relocatable, and restores the caller's prior state before
returning or publishing a throw. Encoded receivers and arguments preserve
ordering and same-VM ownership at the compiled Home/Bun boundary.
Script execution context IDs are lazily allocated as stable, nonzero process
identifiers. Sibling realms receive distinct IDs, repeated reads are identical,
parallel independent context creation is race-free, and the query leaves VM
exception state unchanged.
The pure diagnostic stringifier renders primitives, arbitrary-size BigInts,
and Symbols exactly, preserves input-string identity, and maps every other
object to `[object Object]` without invoking conversion hooks, getters, proxy
traps, or mutable globals. Existing pending exceptions remain first-wins.
The rejection classifier checks only for an own `stack` descriptor. It counts
data and accessor properties without invoking getters, rejects inherited-only
properties and primitives, and preserves exact proxy descriptor-trap and VM
exception behavior across sibling and foreign contexts.
The process-warning shims normalize strings, Error instances, and options into
selected-realm warning Errors, retain non-enumerable metadata, and queue ordered
realm-local events. Unhandled rejections emit the reason projection and exact
Bun warning Error in order, including throwing stack reads, pure fallback
formatting, and listener failures.
Process rejection and fatal dispatch preserves reason/Promise identity, runs
`uncaughtExceptionMonitor` before capture or ordinary handlers, gives capture
callbacks precedence, and returns the pinned handled status. Promise
checkpoints suppress early-handled rejections, emit one unhandled notification,
and emit one late-handled notification for the same rooted Promise without
duplicates. The exact rejection wrapper and `beforeExit`/one-shot `exit`
lifecycle hooks are covered by the same consumer fixture.
The two private process next-tick calls use a separate, precisely rooted FIFO.
They preserve exact callback arity and identity, drain before Promise jobs, and
repeat the checkpoint when microtasks enqueue more next-tick work. Reentrancy,
uncaught callback dispatch, resumable queued tails, foreign-VM rejection, and
`_exiting` suppression are pinned by the consumer matrix.
IPC `message`, `error`, and `disconnect` delivery checks listener presence
before decoding, preserves exact payload/handle identity and arity, and keeps
absent-listener calls as no-ops. The matrix covers sibling realms, once removal,
foreign-VM rejection only when observed, and listener throws.
Native iterable traversal performs one `@@iterator` lookup/call, caches `next`,
and forwards every yielded value with stable callback metadata. Arrays,
code-point strings, Map/Set, generators, and custom iterators preserve their
observable order; callback exceptions run IteratorClose with first-error wins.
ZigString JSON parsing constructs selected-realm values from every tagged input,
returns cleared SyntaxError values for malformed JSON, and guards over-limit
lengths before pointer access with an `ERR_STRING_TOO_LONG` Error value.
Three fast built-in-name reads cover all 24 pinned byte IDs and keep direct
data, own-slot, and Object.prototype-cutoff lookup observably distinct. The
Bun-only pure `code` VM inquiry is tracked solely in the Bun denominator.
Three shared Symbol bridges add exact VM-registry creation and stable borrowed
description/key output. Sibling C-API realms share one registry from bootstrap,
including when their first registration happens after both realms exist.
Two ordinary-object constructors and the wrapper-unboxing shim add exact prototype,
freshness, int32/double, negative-zero, NaN, and primitive-value behavior. Three
value-level BigInt shims add four-way BigInt/Number comparison,
arbitrary-precision addition, and the exact pinned `sec * 1_000_000 + nsec`
timeval formula. The two
cell-type shims use
Home's exact 97-member JSType layout by default; Bun's distinct 98-member layout
requires `-Dprivate-abi-consumer=bun`. Two ToObject/prototype shims preserve
ordinary-object identity, box all five object-capable primitive kinds in the
selected realm, observe proxy/null prototypes, and reject nullish or foreign
values. Two numeric DateInstance shims create fresh selected-realm
Date cells without TimeClip and preserve/read raw fractional, signed-zero, NaN,
infinite, and out-of-range internal doubles. Four more Date shims parse complete
NUL-terminated strings, extract same-VM UTC epoch milliseconds, and write exact
ordinary/extended UTC ISO text failure-atomically; the Date-now writer shares
the real Unix wall clock used by JavaScript Date construction. Nine VM exception
shims add shared pending state
across sibling realms, stable exception-cell identity, primitive/Error
preservation, and exact has/clear/take/rethrow classification. Eighteen
top-scope, termination, and native-error shims add 8/56-byte caller-owned scope
storage, pure versus trap-aware reads, stable VM-wide
termination identity, atomic request/clear and execution-forbidden controls,
termination-preserving selective clear, and selected-realm OOM/stack errors
with first-exception preservation. Nine VM heap controls add shared live,
external, and saturating extra-memory accounting, deferred/full collection,
weak-state processing, footprint reclamation, and positive-duration
opportunistic job checkpoints. Precise heaps use zig-gc's race-safe
live/last-full snapshot; arena VMs report committed capacity. Seven job/registry
shims queue exact native or encoded work,
drain one realm or all live VM realms, notify each unhandled rejection once,
delete exact per-realm module keys, and invalidate all native code safely after
active execution/compilation leases retire. Delete-all-code also clears the
selected realm's module/source caches and leaves bytecode fallback valid. Eight
strong/weak reference shims preserve Bun's direct EncodedJSValue slot layout,
root same-VM values, accept sibling realms, reject foreign replacement, and
retain the VM through handle deletion. Atomic weak slots clear without retaining
their object; collected FetchResponse owners are notified once outside the GC
weak lock, while explicit clear/delete suppresses notification. Five array/index
shims add exact logical lengths and holes, direct put/push/read behavior that
bypasses inherited setters, observable prototype/getter reads with VM exception
publication, sparse growth, and the maximum-u32 boundary. Two JSArray
constructor shims add failure-atomic packed construction, selected-realm
prototypes, same-VM sibling value identity, and hole-only construction through
maximum u32 length. Two contiguous-vector shims expose stable encoded snapshots
only for safe packed arrays, then revalidate vector identity, length, backing,
elements, shape, and prototype safety before each direct read. Concurrent
snapshots remain independent; mutation and exotic/indexed interception fall
back safely. The shared-memfd importer duplicates but never consumes the
caller descriptor, validates the complete regular-file extent plus an
overflow-safe slice, and exposes that slice without copying as the exact Home
ArrayBuffer or Uint8Array type over a writable `MAP_PRIVATE` mapping. The
duplicate closes immediately after mmap; construction failure, GC, or context
teardown unmaps the complete original extent exactly once. Invalid descriptors,
ranges, sizes, result tags, and unsupported platforms fail empty without a
partial owner or pending exception. The ToNumber shim adds primitive and full object coercion,
spec-ordered user hooks, Symbol/BigInt TypeError behavior, ordinary-versus-
exceptional NaN distinction, same-VM sibling values, and first-exception
preservation. Two predicates add JSC-exact internal has-instance prechecks and
object-only iterator GetMethod behavior, including custom/proxy hooks, getter
execution, callability validation, and VM exception publication. Private
string inclusion adds ordered full ToString coercion and exact UTF-16
code-unit matching across astral and surrogate boundaries. Class and
AggregateError classification now follows executable/native and immutable error
metadata, while sibling C-API realms share VM well-known Symbols and the Symbol
registry. Two Object reflection shims return fresh selected-realm keys/values
arrays with exact enumerable ordering, UTF-16 string indices, proxy/getter
behavior, and VM exception propagation. Ten Promise/InternalPromise shims add
selected-realm pending and directly settled promises, exact native downcasts,
callback Promise passthrough, Error/throw rejection, and normal AnyPromise
resolution with thenable assimilation and self-resolution protection. The
adjacent Promise-reaction bridge queues the selected fulfillment/rejection
JSHostFn with exact `(settlement value, retained context)` CallFrame arguments;
it retains the graph through GC and preserves sibling realms, FIFO reentry,
callback throws, and existing VM exceptions. Three
private module-loader shims provide persistent supplied/file sources, canonical
relative resolution, cached namespace identity, exact Promise and exception
channels, top-level-await settlement, and precise module-graph roots. The
JSString backing iterator additionally delivers exact Latin-1 or UTF-16 units
through the pinned caller-owned callback layout. `JSFunction__createFromZig`
now creates selected-realm native functions with owned metadata and invokes
call/construct callbacks through the exact JSC64 `CallFrame` register layout.
The three CallFrame metadata exports bind that active pointer to its owning VM
and visible caller, returning an owned URL with one-based coordinates, exact Bun
main-origin detection, and a stable debug description across nested callbacks.
Four FFI-function exports build on the same callback frame with owned names and
arity, upstream call/construct behavior, atomically mutable nullable native
data, and an optional read-only `ptr` number containing the exact callback
address bits. The dynamic-library token remains distinct from `dataPtr`, and
ordinary functions cannot be misclassified as FFI cells.
`JSC__Exception__getStackTrace` projects retained structured Error frames with
owned BunStrings and exact zero-based positions through Home's pinned
`ZigStackTrace`/`ZigStackFrame` layouts; it never parses the mutable `.stack`
string. Full `ZigException` conversion adds the exact 216-byte layout, owned
error/system fields, cause type, stable exception-cell identity, and a capped
second pass over current/preceding source lines by retained script ID.
`Bun__attachAsyncStackFromPromise` complements creation-time traces for
stackless native errors by walking pending await/transparent-forwarding links,
with exact suspension positions, a per-segment 32-hop guard, realm stack limits,
precise GC retention, and existing/materialized-stack preservation. The
352-symbol combined fixture covers sibling realms, foreign VMs, callback
reentrancy, exception clearing, settled-target no-ops, and the complete
DOMException code matrix. Seven Home-only
JSMap shims create selected-realm native maps and directly implement
SameValueZero get/has/set/remove/clear/size semantics without invoking mutable
Map prototypes, while preserving insertion order and failure atomicity. These
slices also include exact signed/unsigned modulo-2^64 FFI slow conversion for
validated BigInt cells. The shared CommonAbortReason shim creates fresh
selected-realm DOMExceptions with Bun's exact TimeoutError/AbortError names,
messages, and legacy codes while preserving an existing VM exception. They do
not yet create a usable Home private runtime.

The native StringBuilder slice adds all 13 pinned operations over Home's
caller-owned 24-byte, 8-byte-aligned buffer. It preserves exact UTF-16 across
every BunString form, uses WebKit-compatible numeric and JSON formatting,
keeps overflow sticky, returns non-destructive selected-realm strings, and
surfaces OOM without replacing a pending exception.
The rooted native-container slice adds MarkedArgumentBuffer's synchronous
callback/append pair plus the three per-realm CommonJS extension registry
operations. Appended and registered cells remain precise-GC roots for exactly
their required lifetimes; cross-VM values and invalid indices fail without
partial mutation.

The newer Home revisions `5e829ad4`, `38702f9e`, and `4389ddee` changed no files
in `packages/runtime/src/jsc` relative to `7ed99c02`. Their separate alias
manifests still verify every source hash and declaration and report zero added,
removed, signature-changed, or calling-convention-changed entries. This keeps
all four exact revisions supported without weakening revision rejection.

## Two migration paths

**Path A — rewrite Home's runtime onto zig-js's public C API.** (Recommended.)
Replace Home's ~804 `Bun__*`/`JSC__*` call sites and its generated-class layer
with calls to zig-js's public API (`JSObjectMake`, `JSObjectSetProperty`,
`JSObjectMakeFunctionWithCallback`, class definitions, etc.). Large but
well-bounded, keeps zig-js clean (a public-API engine), and decouples Home from
Bun's internal ABI. zig-js gains a focused set of new public-API features
(below).

**Path B — make zig-js export Bun's internal ABI.** zig-js would implement the
804 `Bun__*`/`JSC__*` entry points, the generated-class C ABI, and Bun's exact
`JSValue`/`JSCell`/`Structure` encodings. This couples zig-js permanently to
Bun's internal design and is far more surface area. Not recommended.

The rest of this doc assumes **Path A**.

## zig-js capability gaps to close for Path A

zig-js already has (verified in `src/c_api.zig`): context lifecycle, evaluate,
value predicates/conversions, `JSObjectMake`, property get/set/index,
call/construct, `JSObjectMakeFunctionWithCallback` (host functions),
`JSObjectMakeDeferredPromise`, `JSValueProtect`/`JSValueUnprotect`, string
create/get, the public TypedArray/ArrayBuffer construction and borrowed-bytes
surface (including no-copy lifetime callbacks), and the `JSWorker*` extension.

Missing primitives Home depends on heavily (each blocks a large class of corpus
tests):

1. **Complete custom native classes** — class ownership, inheritance,
   initialize/finalize, class identity, shared prototypes, and static functions
   plus static-value get/set/has/delete, descriptor, and key-enumeration dispatch
   are implemented. Every dynamic callback family, including property names,
   calls, construction, `hasInstance`, and conversion, is implemented, including
   deterministic rejection of foreign-context and invalid callback returns. Home defines ~100+
   JS-exposed classes (Subprocess, Glob, Server, Crypto hashers, FSWatcher,
   Stats, …) via the generated-class machinery; this public C-API layer is now
   available, while Home's private generated-class ABI remains separate work.
2. **Exception model** — set/get/clear a pending exception on the context;
   `JSObjectMakeError` plus distinct `TypeError`/`RangeError`/`SyntaxError`
   construction; the `JSValueRef* exception` out-parameter convention on every
   call/get/set. Home's invariant: a host call returns the empty value **iff**
   an exception is pending (see Home's `host_fn.zig` / `assertExceptionPresenceMatches`).
3. **Inspector integration** — the complete public C inventory, inspectability
   toggles, versioned in-process protocol transport, C/C++ hosts, the JSC
   differential gate, and real shared-VM context groups are in place. Runtime
   evaluation, statement pause/resume, resolved breakpoints, logical-depth
   stepping, exception policy, and suspendable-function checkpoints are usable
   today. Paused events also expose live call frames and lexical/global scope
   chains plus live evaluate-on-frame and GC-rooted, session-owned remote-object
   inspection. Concurrent sessions use deterministic pause ownership with
   observer-first snapshots and callback-safe deferred teardown. Independent
   JSWorker runtimes remain live rather than being falsely claimed as child
   targets; explicit cross-thread target transport is tracked in #156 before
   Home debugger integration is complete.
4. **Prototype & structure control** — `JSObjectGetPrototype`/`SetPrototype`
   and richer private/internal slot modeling. `JSObjectGetPrivate` /
   `JSObjectSetPrivate` now cover host-owned opaque pointers, but Home also
   stashes cached JS values on wrappers.
5. **GC reachability hooks** — an equivalent of JSC's "is this wrapper still
   reachable" output constraint so a native object with pending activity is not
   collected (Home uses Strong/Weak `JSRef` upgrade today; some classes need the
   `hasPendingActivity` callback path — see Home's subprocess finalize assert).
6. **Microtask / event-loop integration** — Home drives its own event loop
   (`io/posix_event_loop.zig`); zig-js must let the host pump the microtask queue
   (drain-on-demand) and integrate promise jobs with Home's loop rather than
   owning the loop.
7. **String interop** — efficient UTF-8/UTF-16 `bun.String`/`ZigString` ↔ engine
   string bridging without a full copy where possible.

## Suggested phased plan

1. **Spike:** stand up a `home_rt` build flag that links zig-js instead of JSC
   for a *minimal* path — `home eval "1+2"` and `home eval "console.log(...)"`
   only. Proves context + evaluate + a couple of host functions
   (`console.log`). Nothing else wired.
2. **Class system:** implement `JSClassDefinition` in zig-js; port ONE Home
   generated class (e.g. `Glob`, which is small) onto it end-to-end, including
   finalize + a static method. Establishes the pattern + codegen target.
3. **Exceptions + C ABI hardening:** close gaps (2) and (3); port `Buffer` and
   the node validators (they throw a lot — exercises the exception invariant).
4. **Event loop + promises:** wire (6); port `Bun.spawn` / timers.
5. **Bulk class migration:** regenerate Home's class layer against the new
   zig-js class API (Home's classes are codegen-driven, so most of the ~4,325
   symbols collapse into one generator change).
6. **Cutover gate:** Home's full-VM corpus (`HOME_CORPUS_FULL_VM`, see Home's
   `scripts/vm-corpus-scan.sh`) must be **no worse** on zig-js than on JSC before
   flipping the default.

## Measuring

- zig-js standalone: configured `tc39/test262` runner score. Keep this sourced
  from `docs/.data/test262.json` rather than hard-coding stale counts.
- Home integration: the full-VM corpus pass/fail/crash/hang counts from
  `~/Code/Home/lang/scripts/vm-corpus-scan.sh`, compared JSC-vs-zig-js per
  subsystem. Cut over only at parity-or-better.

## Note on current corpus crashes (context)

The crashes being fixed in Home today (the node `ERR().throw()` empty-value
segfault, `PollOrFd` use-after-free, `Bun.serve` returning an empty JSValue,
the Glob stubs) are **Home-side Zig bugs feeding invalid values to the engine**
— they are engine-agnostic and would occur on zig-js too. None required WebKit
source. So Home-side corpus parity work is *not blocked* on this migration and
should proceed in parallel; this migration is the longer-horizon engine track.
