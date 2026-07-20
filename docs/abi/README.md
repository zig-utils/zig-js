# Versioned consumer ABI profiles

These profiles describe exact downstream consumers. A profile is supported only
when its checked-in symbol/type contract, compile-link-runtime fixture, and
revision checks pass. Unknown profile IDs and mismatched source revisions are
errors; zig-js does not silently approximate a moving private ABI.

## Home public C profile

`home-public-c-7ed99c02` pins Home revision
`7ed99c02e50034f869d0db6d487115bb44332fe4`. Its M1 Zig embedding layer declares
50 public JavaScriptCore C functions. The profile records all 50 functions, the
C calling convention, target-native pointer/`usize` layout, opaque pointer
types, enum backing types and values, source hashes, and semantic lifetime
assumptions.

Run the fast checked-in audit and real Zig consumer fixture with:

```sh
zig build home-public-abi-audit
zig build test-home-public-abi
```

When the pinned Home checkout is available, also prove that its revision,
source hashes, and declarations still match:

```sh
zig build home-public-abi-audit -Dhome-source-root="$HOME/Code/Home/lang"
```

This profile is deliberately `public_c_embedding`. It proves only that the
pinned Home public consumer compiles, links, and runs against zig-js. It does
not claim support for Home's `JSC__*`, `Bun__*`, generated-class, JSC object
layout, LLInt, or other private interfaces; those require separate `private_abi`
profiles tracked by GitHub issues #140, #163, and #164.

## Home private inventory

`home-private-7ed99c02` uses a comment/string-aware scanner over the pinned
Home `packages/runtime/src/jsc` tree. It records each unique symbol declared as
`extern fn` or `extern "c"`/`"C" fn`, including alternate declaration sites,
normalized signatures and digests, classification, status, and effective
calling convention. The exact current denominator is:

| Classification | Symbols |
|---|---:|
| Private JSC/Bun/WebCore ABI under #163 | 471 (356 implemented, 115 pending) |
| Overlap with zig-js's completed public C target | 59 |
| Platform libc imports | 7 |
| Consumer-generated definition (`JSFunctionCall`) | 1 |
| **Total** | **538** |

The 538 symbols come from 66 pinned source files; 15 repeated imports retain
alternate declaration provenance and none is unclassified. Of the canonical
contracts, 442 use default C linkage, 91 explicitly link `c`/`C`, four spell
`.c`, and one uses Home's `jsc.conv`.

```sh
zig build home-private-abi-audit
zig build home-private-abi-audit -Dhome-source-root="$HOME/Code/Home/lang"
```

This inventory is the denominator, not a claim that the whole surface works.
Of the private entries, 356 are implemented and 115 remain pending
until #163 provides their type/layout contracts, shims, and consumer evidence.
`JSFunctionCall` remains revision-pinned in the declaration inventory but is
not part of that denominator: each runtime-generated FFI module defines the
function and resolves it locally after relocation.

Home revisions `5e829ad483bb9e5ccb19766997df6462edd8e167`,
`38702f9e43b3aecbee7d5b7aa48cc66d41cabde7`, and
`4389ddeea0445f28f400f86995435b473b8aa167` are supported as the explicit
`home-private-5e829ad4`, `home-private-38702f9e`, and
`home-private-4389ddee` aliases. None is a silent
repin: the full `packages/runtime/src/jsc` diff against `7ed99c02` has zero
changed files, and each audit rechecks all 66 source hashes plus all 538
normalized symbol contracts, alternate declarations, classifications, and
calling conventions against the immutable base inventory. All three alias manifests report zero
additions, removals, signature changes, and calling-convention changes.

```sh
zig build test-home-private-abi \
  -Dhome-private-abi-profile=home-private-4389ddee \
  -Dhome-source-root="$HOME/Code/Home/lang"
```

## JSC64 value boundary

Private shims must use `private_abi.EncodedValue`; they must never expose
zig-js's internal `Value.rawBits()` as though it were JavaScriptCore. The two
types are both eight-byte NaN boxes but intentionally use different tags.

The pinned boundary implements the Home/Bun JSC64 encodings exactly:

| Value | Encoded word |
|---|---:|
| empty / thrown sentinel | `0x0` |
| null | `0x2` |
| deleted-property sentinel | `0x4` |
| false / true | `0x6` / `0x7` |
| undefined | `0xa` |
| int32 tag | `0xfffe000000000000 \| uint32(payload)` |
| double | raw IEEE-754 bits plus `1 << 49`, wrapping |
| cell | aligned non-null pointer word |

`zig build test-private-abi-value` runs the focused layout/codec tests and a
real bridge executable against `js.Value`. It covers the complete signed int32
range boundaries, finite doubles, infinities, negative zero, positive and
negative noncanonical NaNs, cell validation, every primitive conversion, and
the requirement that string/object conversion first acquire an external cell
handle.

The first completed shim slices export the pinned signatures for
`JSC__JSValue__eqlCell`, `JSC__JSValue__eqlValue`,
`JSC__JSValue__toBoolean`, `JSC__JSValue__toInt32`,
`JSC__JSValue__fromInt64NoTruncate`,
`JSC__JSValue__fromUInt64NoTruncate`, and
`JSC__JSValue__toUInt64NoTruncate`, plus
`JSC__JSValue__isStrictEqual` and `JSC__JSValue__isSameValue`. Raw primitive
words use the codec directly; cell words resolve through context-owned public
C-API boxes without exposing the internal NaN-box layout. The two constructors
produce real context-owned BigInt cells. Extraction returns the BigInt modulo
2^64 and preserves the pinned int32 and exact non-negative Int52 number
fallbacks. The equality pair implements JavaScript `===` and SameValue,
including string and BigInt value equality, object identity, NaN equivalence
only for SameValue, signed-zero distinction only for SameValue, and safe
rejection of foreign-context cells. The
compile-link-runtime gate is:

```sh
zig build test-home-private-abi
```

It covers empty/immediate/int32/double/NaN/negative-zero behavior, boxed
empty/nonempty strings, object identity/truthiness, signed minimum and unsigned
maximum BigInts, negative modulo extraction, exact number fallbacks, and every
invalid/non-exact boundary. Public accounting stays unchanged at 117 functions
and 19 extensions; these 200 symbols are reported only as private profile
exports.

The opaque BigInt cell slice additionally exports `JSC__JSBigInt__fromJS`, the
three signed/unsigned/double ordering functions, and `JSC__JSBigInt__toInt64`.
It reuses zig-js's arbitrary-precision integer comparison rather than narrowing
through `f64`: the runtime matrix covers values beyond i128, the 2^53 rounding
boundary, positive and negative fractional comparisons, the minimum positive
subnormal, infinities, a 10^400 BigInt against `floatMax`, and signed
modulo-2^64 extraction. `JSC__JSBigInt__toString` now mirrors the pinned
24-byte `BunString` tagged union and returns a fresh, owned, 8-bit
`WTFStringImpl` decimal result with refcount one. The fixture covers signed and
oversized values, same-VM sibling realms, fresh allocation identity, atomic
retain/release, exact layout/flags, and first-pending-exception preservation.
The cold destroy export also supports Bun's Rust-side inline atomic release.

The non-URL BunString conversion slice implements `BunString__toJS`,
`BunString__toJSWithLength`, `BunString__transferToJS`, and
`BunString__createArray`. It decodes Empty and Dead tags, 8/16-bit
WTFStringImpl storage, and Latin-1/UTF-8/UTF-16 pointer-tagged ZigStrings.
UTF-16 code units—including lone surrogates—are preserved exactly; the length
variant can split an astral pair at a requested code-unit boundary. Transfer
invalidates and releases owned storage only after successful conversion, while
array construction preserves order, selected-realm prototypes, zero-length
null-pointer input, and failure atomicity.

The four non-DOM ZigString error constructors reuse the same tagged decoder and
create fresh native `Error`, `TypeError`, `RangeError`, and `SyntaxError`
instances. Latin-1, UTF-8, UTF-16, empty, astral, and lone-surrogate messages
retain their exact JavaScript text. Prototype selection comes from the chosen
realm's intrinsic error family rather than mutable globals, and a pre-existing
VM exception prevents allocation without being replaced.

The value-level BigInt slice exports `JSC__JSValue__asBigIntCompare`,
`JSC__JSValue__bigIntSum`, and `JSC__JSValue__fromTimevalNoTruncate`. It returns
the pinned equal/undefined/greater/less enum values, including undefined for
NaN; compares arbitrary-size BigInts against BigInts, exact and fractional
doubles, signed zero, and infinities; and adds without narrowing. The timeval
constructor deliberately matches the pinned consumer formula
`sec * 1_000_000 + nsec` despite its parameter name, with signed i64 extremes
covered by the runtime fixture. Invalid and foreign-context cells are rejected.

The JSCell/JSString slice adds exact opaque downcast, equality, storage-width,
UTF-16 length, object access, and object-coercion boundaries. Its fixture covers
ASCII and Latin-1 8-bit strings, BMP and astral strings, lone-surrogate WTF-8,
equal content in distinct cells, non-string rejection, ordinary-object identity,
and String/Symbol/BigInt boxing. Foreign-context coercion is rejected rather
than accepting a handle from another VM.

The ordinary-object foundation exports fresh Object.prototype-backed and true
null-prototype constructors plus boxed-primitive unwrapping. The capacity input
remains an allocation hint with no observable semantic effect. Unwrapping
canonicalizes the complete int32 range, preserves out-of-range doubles,
negative zero and NaN, returns exact String/Boolean/BigInt primitives, leaves
ordinary objects and existing primitives unchanged, and rejects foreign-context
wrapper cells.

The object-coercion slice exports `JSC__JSValue__toObject` and
`JSC__JSValue__getPrototype`. Ordinary objects retain identity; Number,
Boolean, String, Symbol, and BigInt primitives receive selected-realm wrappers;
and null/undefined fail through the private empty boundary. Prototype queries
return exact ordinary, wrapper, function, null, and proxy-observed prototypes,
while invalid and foreign-context values are rejected.

The numeric DateInstance slice exports
`JSC__JSValue__dateInstanceFromNumber` and
`JSC__JSValue__getUnixTimestamp`. The constructor creates a fresh selected-realm
Date cell around an already-computed internal double, deliberately bypassing
JavaScript constructor TimeClip. Fractional values, negative zero, NaN,
infinities, and values outside ±8.64e15 are preserved; the getter returns NaN
for non-Date cells.

The Date parsing/formatting slice adds
`JSC__JSValue__dateInstanceFromNullTerminatedString`,
`JSC__JSValue__getUTCTimestamp`, `JSC__JSValue__toISOString`, and
`JSC__JSValue__DateNowISOString`. It parses the complete NUL-terminated input
into a fresh selected-realm Date, preserves invalid parses as NaN Dates, accepts
same-VM sibling values for UTC extraction and ISO formatting, rejects foreign
VMs, and writes exact 24-byte ordinary-year or 27-byte extended-year UTC text
without a terminator. All failures return `-1` without modifying the output
buffer. JavaScript Date construction and `Date.now()` now use the same real
Unix wall clock as the Date-now writer.

The pinned consumer sources contain three defects that the name-based inventory
cannot express: Bun's Zig declaration gives `DateNowISOString` the incompatible
`(*JSGlobalObject, f64) JSValue` signature even though its wrapper and C++ body
use `(*JSGlobalObject, *[28]u8) c_int`, and `getUTCTimestamp` is declared but has
no C++ definition. Both pinned Zig `RegularExpression` declarations also omit
the BunString argument from `searchRev`, while the C++ implementation and
current Rust binding expose `searchRev(RegularExpression*, BunString)`. The
runtime fixture therefore pins the executable writer, coherent owned-Date UTC
internal-time, and two-argument reverse-search contracts rather than claiming
those source inconsistencies match.

The six-symbol Yarr boundary owns a compiled zig-regex expression and mirrors
JavaScriptCore's stateful validity and last-match-length behavior. BunString
patterns and inputs preserve UTF-16 code units through WTF-8, so legacy dot can
consume one surrogate half while Unicode dot consumes a valid pair atomically;
all returned positions and lengths are UTF-16 offsets. Reverse search scans
forward from successive code-unit positions exactly like JSC, retaining the
last later non-subset match and handling overlaps and zero-width matches without
looping. Null BunStrings and invalid patterns remain non-matches. The fixture
uses the real two-argument executable ABI and covers flags, astral input,
overlap, subset replacement, empty patterns, invalid state, and match-state
reset. The underlying empty-pattern and Unicode-surrogate corrections are
tracked and completed in [zig-regex #11](https://github.com/zig-utils/zig-regex/issues/11)
and [zig-regex #12](https://github.com/zig-utils/zig-regex/issues/12).

The five-symbol WTF helper slice mirrors WebKit's stateless runtime boundary.
Decimal parsing accepts the longest signed decimal/fraction/exponent prefix,
reports its exact byte count, rejects leading whitespace and Infinity/NaN
spellings, and preserves signed zero and overflow-to-infinity behavior. The ES5
date parser is separate from JavaScript `Date.parse`: it implements WebKit's
strict date/time field widths, lenient space-separated and fractional forms,
timezone variants, leap-year validation, leap-second normalization, and NaN
failure contract. CPU discovery reports at least one online processor and
clamps to `c_int`. FastMalloc release is already satisfied because zig-js owns
no WTF allocator or per-thread FastMalloc cache. HTTP dates use exact 29-byte
RFC 7231 IMF-fixdate text, timestamp-zero suppression, and bounded
`snprintf`-style truncation with a terminator and full required-length return.

The seven-symbol Uint8Array/Buffer/ArrayBuffer slice constructs live
selected-realm values. Copy constructors own isolated backings and preserve
empty input; the ArrayBuffer path is a true fixed-length ArrayBuffer, while the
Uint8Array path can persist Bun Buffer subclass identity separately from its
ordinary byte-view kind. The two allocation-first exports expose an
uninitialized writable backing pointer only after the result is complete.
Pinned JSC's historically named `Bun__allocArrayBufferForCopy` actually returns
a Buffer-subclassed Uint8Array, and zig-js preserves that result rather than
normalizing the misleading name. `JSBuffer__isBuffer` reads the stored identity
without accepting lookalikes.

The two default-allocator constructors adopt the caller's non-empty byte slab
without copying as either Uint8Array or ArrayBuffer and attach it to the same
idempotent external-buffer owner, so GC or realm teardown invokes `mi_free`
exactly once. Empty values allocate independent zero-length backing metadata
without taking ownership of the caller's sentinel pointer. A weak libc fallback
keeps standalone builds linkable; Home/Bun's strong mimalloc export replaces it
in consumer builds. Invalid sources, oversized allocations, and construction
failures publish no pointer or half-created value and use the normal private
pending-exception boundary.

The remaining three JSBuffer constructors complete the same ownership model.
Signed lengths reject negative and engine-oversized requests as pending
RangeErrors while valid lengths return zero-filled Buffer-identified views.
External pointers retain their exact address and caller-supplied finalizer
context; non-empty storage releases exactly once from GC or realm teardown,
while zero-length transferred allocations invoke the finalizer immediately as
required by the pinned Bun leak fix. Mmap-backed Buffers similarly keep the
mapping live without a copy and call `munmap`/`UnmapViewOfFile` exactly once.
Invalid non-empty pointer/deallocator pairs fail explicitly rather than
publishing a dangling view.

The explicit uninitialized Uint8Array export uses the same aligned backing
allocator, GC byte accounting, metadata ownership, selected-realm prototype,
and finalization path as ordinary typed arrays, but deliberately skips only the
byte-zeroing step. That behavior is confined to the pinned native ABI for
callers that overwrite the complete view. JavaScript `new Uint8Array(...)`,
ArrayBuffer construction, resizing, transfer, and every other allocation path
continue to use the unchanged zero-filled allocator. Oversized requests fail
through the private pending RangeError boundary before publishing a view.

The generic no-copy ArrayBuffer and TypedArray adopters cover all 12 pinned
numeric tags, including Float16 and both BigInt views. They preserve the exact
external pointer and full backing byte length; typed views use
`floor(byteLength / elementSize)`, so trailing bytes stay owned by the backing
ArrayBuffer without making the view invalid. Empty storage remains a live
zero-length object. Caller callbacks, including null callbacks, use the same
idempotent owner record and run at most once; invalid tags and non-empty null
pointers fail atomically and release transferred input before publishing the
private pending exception.

`ArrayBuffer__fromSharedMemfd` imports one caller-owned descriptor without
copying or consuming it. It duplicates the descriptor to close the validation/
mapping race, requires a regular file large enough for the declared total,
maps that complete extent read/write and `MAP_PRIVATE`, and exposes only the
overflow-checked requested slice as the profile-selected ArrayBuffer or
Uint8Array type. The short-lived duplicate closes after mapping; GC, arena
teardown, and every later construction failure converge on one idempotent owner
that unmaps the complete original extent exactly once. Unsupported platforms,
invalid descriptors/ranges/sizes, and every other JSType fail empty without a
partial JS value or pending exception. Focused tests cover nonzero slices,
write isolation from the file, caller-fd survival, GC, teardown, and invalid
inputs; the compiled consumer exercises both result types.

The JSValue ArrayBuffer projection fills Home's exact 40-byte borrowed-view
record for ArrayBuffer, every numeric TypedArray, and DataView. It reports the
live offset-adjusted pointer, element and byte lengths, original encoded cell,
profile-selected Home/Bun JSType tag, shared state, and resizable/growable
state. Detached or out-of-bounds views return a successful zero-length/null
projection without touching stale bytes. Invalid and foreign cells leave the
caller output unchanged, and an existing VM exception blocks projection
without being replaced.

The pinned [`IDLArrayBufferRef` contract](array-buffer-handle-contract.json)
follows Home and Bun's `RefPtr<JSC::ArrayBuffer>` conversion through the
generated producer's `leakRef()` transfer. The resulting backing handle has
atomic, independently bounded external references and separate wrapper and VM
tracking ownership, so its storage can outlive the JavaScript wrapper, realm,
and VM without an over-`deref` stealing another ownership domain. Owned bytes
resize in place at the handle boundary, shared storage retains shared identity,
and external storage invokes its callback exactly once after the final owner.
`asBunArrayBuffer` fills the exact 40-byte record with stable pointer/length
pairs plus the shared and resizable flags. The generated fixture adopts the
producer through required, optional, and union fields and covers explicit
clone/drop, resize, teardown, over-release, renewed references, and last-owner
external finalization.

The private `typeof` projection returns the exact JavaScriptCore small-string
classification for every encoded primitive and cell: `undefined`, `boolean`,
`number`, `string`, `symbol`, `bigint`, `function`, or `object`. Null remains
`object`, while callable `[[IsHTMLDDA]]` objects remain `undefined`. Each result
is one stable JSString cell owned by the context group, so sibling realms share
identity while separate VMs do not. Invalid and foreign cells return null; the
operation invokes no user code and neither consumes nor replaces a pending VM
exception.

The VM entry-state query mirrors JavaScriptCore's live entry-scope predicate.
It returns true while any realm in the context group has an active interpreter,
including nested/reentrant entries, and remains true until the final entry
leaves. The read takes each realm's existing active-interpreter registry lock,
keeps separate VMs isolated, returns false for null handles, and never changes
exception or termination state.

The owning-VM query resolves any realm—including sibling realms in one context
group—to the single VM identity every `JSC__VM__*` boundary consumes, matching
the pointer `JSC__JSGlobalObject__vm` publishes. It allocates nothing, rejects
invalid handles with null and separate context groups by identity, and never
touches exception or termination state.

The private JSFunction boundary exposes the parser-captured source span rather
than reconstructing text through `Function.prototype.toString`. Ordinary,
arrow, method, generator, async, and class-constructor functions return stable
group-lifetime Latin-1 or UTF-16 ZigString views; native, bound, non-function,
invalid, and exception cells fail without modifying the output. Its tier-up
control is scheduling-only: an eligible cold bytecode chunk is primed so the
next invocation claims native-tier consideration, while the request itself
does no allocation or code generation. Tree-walk functions and already
settled tiers remain unchanged, as do pending VM exceptions.

The internal length projection follows the pinned type switch instead of
blindly reading `.length`. Strings use UTF-16 code units; Arrays use logical
length; numeric TypedArrays and ArrayBuffers use live view/byte lengths; and
Map, Set, and WeakMap report internal entry counts even when user code spoofs a
`length` property. Detached storage reports zero. Other objects perform one
ordinary `length` lookup followed by ToNumber, so inherited values, accessors,
proxies, conversion hooks, and abrupt completion remain observable. Missing or
unsupported cells return positive Infinity, while primitive/invalid/foreign
inputs return zero and an existing VM exception remains first.

The private property-path export reproduces Bun's pinned permissive Jest
grammar over UTF-16 code units: dots and brackets separate segments, while
empty, leading/trailing, and consecutive-dot cases retain their exact empty-key
behavior. Array paths accept only string/number entries and use JSC's
`ToLength`-plus-indexed-`Get` traversal, including holes, inherited entries,
proxies, and exact number-to-string keys. Each target segment is boxed through
`ToObject` and read once without a preliminary `has` lookup, preserving present
`undefined`, accessors, abrupt completion, and first-exception state.

The six shared property-iterator exports retain their VM and snapshot exact
enumerable string/Symbol names in JSC order. Own-only and non-index modes,
prototype traversal, enumerable-name de-duplication, mutation-stable borrowed
BunStrings, and UTF-16 longest-name length follow the pinned boundary.
Observable reads perform ordinary `Get`; VM inquiry walks only direct ordinary
data slots and stops at accessors, Proxies, or custom/opaque objects without
executing user code. Focused and independently compiled consumers cover both
paths, thrown getters, symbols, sibling/foreign VMs, and final iterator-owned
VM teardown.

Four class/display-name projections separate raw class-info metadata,
constructor-derived calculated class names, function/internal names, and Bun's
display-name result. Class calculation uses non-invoking VM-inquiry-style data
slots, while the name-property and display-name fallbacks perform exactly one
observable `@@toStringTag` read. Borrowed class/name output has context-group
lifetime; `BunString` display names own exact Latin-1 or UTF-16 storage,
including astral and lone-surrogate content.

The two private JSON writers use the complete runtime serializer with the exact
pinned space distinction: unsigned indentation clamped to ten spaces, or
`undefined` for compact/fast output. They preserve observable `toJSON`, getters,
proxies, property order, omission/null rules, BigInt and circular errors,
Unicode/lone-surrogate escaping, and selected-realm execution. Successful
output owns its Latin-1 or UTF-16 BunString backing; an unstringifiable
top-level value produces the empty representation without an exception.

The native `fromEntries` and `putRecord` boundaries construct records directly
from copied ZigStrings. `fromEntries` returns an ordinary selected-realm object,
keeps duplicate last-value and integer-key enumeration semantics, and leaves
both clone modes independent of caller-buffer mutation. `putRecord` maps zero,
one, and multiple values to an empty array, scalar string, and ordered string
array, then installs an all-true own data descriptor without invoking inherited
setters. Null/oversized/foreign/OOM paths are failure-atomic and the shared
pending-exception boundary remains first-wins.

The JSX element predicate performs one ordinary `$$typeof` Get and compares
only against the VM registry identities for `react.element` and
`react.transitional.element`. Inherited properties, getters, proxies, and
same-VM sibling realms preserve their observable behavior. Local Symbols,
same-description impostors, primitives, foreign cells, thrown accessors, and
pre-existing exceptions retain the pinned false/abrupt boundary.

The core deep-equality pair implements the pinned Bun structural engine for
SameValue primitives, active cycle pairs, enumerable string/Symbol properties,
unordered Maps/Sets, arrays and sparse holes, boxed strings, Date, RegExp,
Error/cause, ArrayBuffer, DataView, and every numeric TypedArray. Strict mode
adds calculated-class, property-count, missing/undefined, cause-presence, and
bitwise-float distinctions. Getter/proxy failures, sibling realms, foreign
cells, recursion limits, and existing pending exceptions retain the native
boundary behavior.

The three Jest modes enable right-first asymmetric dispatch for the pinned
anything/any, string-containing/matching, array/object-containing, close-to,
promise, negation, and custom-marker behaviors. `jestDeepMatch` performs one
existing-property lookup per subset key, handles Symbols and independent cycle
sets, requires exact arrays, keeps nested object-containing exhaustive, and can
replace a matched data/accessor property directly. The non-Jest pair remains
matcher-hook-free.

The five remote-inspector process controls expose atomic, idempotent state for
one-way auto-start disable, explicit start, console logging, and the default
inspection policy. Apple-family targets deterministically follow modern JSC's
disabled default and non-Apple targets default enabled; explicit policy changes
remain separate from each context's inspectability flag.

The proxy internal-field projection returns exact live target/handler cells
without ordinary property access or userland traps. Revoked fields become
JavaScript `null`; invalid field IDs and non-proxies return the empty ABI value.
A per-VM canonical object-handle table keeps re-published EncodedJSValues
bit-identical across sibling realms while isolating independent VMs.

The script-execution-context identifier boundary lazily assigns a stable,
nonzero 32-bit process identifier to each global context. Atomic allocation
keeps parallel independent creation unique; sibling realms in one VM remain
distinct, null handles return zero, and reads do not alter pending exceptions.

The pure fatal-diagnostic stringifier handles exact Number thresholds and
special values, booleans, null, undefined, arbitrary-size BigInts, and
described/undescribed Symbols. Strings retain their original encoded identity;
all other objects become `[object Object]` without conversion hooks, getters,
proxy traps, mutable globals, or pending-exception changes.

The unhandled-rejection classifier performs the pinned JSC own-`stack`
descriptor query. Own data and accessor descriptors return true without a
getter call, inherited-only properties and primitives return false, and Proxy
`[[GetOwnProperty]]` traps execute exactly once with their abrupt completion
published through the VM's first-wins pending-exception state.

The process-warning boundary accepts the pinned string/Error and options
shapes, installs non-enumerable name/code/detail metadata, and queues warning
listeners in FIFO order with the selected realm's Error prototype. Unhandled
rejection warnings deliver the projected reason first and the exact Bun warning
Error second; throwing stack reads, pure fallback formatting, exception
clearing, and listener failures are covered.

The process rejection and fatal-dispatch boundary preserves exact reason and
Promise identity, orders `uncaughtExceptionMonitor` before capture or ordinary
handlers, gives the capture callback precedence, and returns the pinned handled
status. The rejection wrapper has the exact `UnhandledPromiseRejection` name,
code, and message. Promise checkpoints cover early-handler suppression, one
unhandled notification, one identity-preserving late-handled notification, and
duplicate-checkpoint suppression. The same realm-local store backs repeatable
`beforeExit` and one-shot `exit` dispatch.

The two process next-tick exports feed a distinct realm-owned FIFO rather than
the PromiseJobs queue. One- and two-argument calls retain their exact arity and
identity, all next ticks drain before microtasks, and the checkpoint repeats
after Promise jobs only when they scheduled more next-tick work. Reentrant
enqueue, uncaught monitor/handler dispatch, resumable tails after listener
failure, foreign-VM rejection, and `_exiting` suppression are covered with
precise queue and active-batch roots.

The three IPC process-event exports check for a listener before decoding any
payload. `message` receives the exact value and handle, `error` receives one
value without taking the unhandled-error branch when absent, and `disconnect`
receives no arguments. The fixture covers same-VM sibling identity, once
removal, foreign-VM no-op versus observed rejection, and listener throws.

The four debugger async-call exports follow the pinned
[`AsyncCallType` contract](debugger-async-call-contract.json): five exact `u8`
call types, a no-agent return before enum conversion, and direct
schedule/cancel/will-dispatch/did-dispatch forwarding. With an enabled agent,
owned scheduling frames are keyed by `(type, callbackId)` without rooting the
source realm, nested active calls restore in LIFO order, duplicate schedules
replace their prior snapshot, and single-shot work retires only after matching
dispatch completion. `Debugger.paused` exposes the copied `asyncStackTrace`
only while that task is active; cancellation, final-agent disable/detach, and
teardown release every dormant and active snapshot.

The native iterable callback boundary executes the pinned `@@iterator` method,
caches the returned iterator's `next` function, and observes IteratorStep and
IteratorValue in order. Every yielded value retains stable encoded identity and
receives exact VM/global/context metadata; callback exceptions close an open
iterator while a throwing `return()` cannot replace the original exception.

The non-indexed property boundary exposes exact JSType 7 GetterSetter and
JSType 8 CustomGetterSetter cells plus their four null predicates. Traversal
visits own string and Symbol keys in pinned order, filters indices, length,
constructor, private/internal keys, and non-enumerable special cases, never
invokes ordinary or C-class accessors, clears property-read failures where JSC
does, and stops on callback-published exceptions. Descriptor identity survives
sibling realms, GC, and reentry; the 327/327 compiled fixture additionally
covers every accessor shape, proxies, Symbols, filters, and foreign inputs.

The ZigString JSON boundary decodes every tagged representation and constructs
the parsed graph with selected-realm intrinsics. Its pinned exceptional contract
returns the SyntaxError value after clearing the transient parse exception; an
input longer than `2^32 - 1` returns `ERR_STRING_TOO_LONG` without touching the
untrusted span.

The three external ZigString constructors retain the caller's original
Latin-1 or UTF-16 allocation until the last engine string dies. zig-js keeps a
canonical WTF-8 view internally without releasing that external obligation;
callbacks run exactly once after sweep locks are released, or during arena
teardown, and may re-enter GC. `toExternalU16` resolves the consumer's strong
`ZigString__freeGlobal`; standalone links use the weak libc fallback.

The custom-inspect boundary invokes the supplied callable with the inspected
value as `this` and exact `(depth, options, inspect)` arguments. The realm-owned
options expose `stylize`, `depth`, and `colors` in pinned insertion order; the
callable helper, ANSI styles, pending exceptions, cross-VM rejection, and roots
across user-triggered GC are covered in both focused and compiled consumers.

The owned serialization boundary returns the pinned 24-byte
`{bytes,size,handle}` layout and keeps its structured-clone frame stable until
an idempotent opaque-token release. Ordinary graphs round-trip cycles, aliases,
and typed data; default-mode SharedArrayBuffers retain process-local backing,
while storage and cross-process flags reject them rather than publishing
non-portable tokens. Malformed input, foreign values, uncloneable values, and
allocation failure use the shared pending-exception channel.

The VM exception slice exports the shared `JSGlobalObject`/`VM` pending-state
boundary plus exception-cell conversion and classification. Sibling realms in
one context group observe the same VM pointer and pending cell; taking or
clearing through either realm clears the shared state. Throws preserve the
original primitive or Error identity, retain the first pending exception, and
keep the thrown value rooted until clear/take. Exception cells remain distinct
from ordinary values and can be safely rethrown.

The structured exception-stack slice retains frames when an Error or
DOMException is created, independently of the public formatted stack string.
Tree-walker, bytecode, generator/async, constructor, global, and module paths
maintain a lightweight activation chain without allocating inspector scope
mirrors. `JSC__Exception__getStackTrace` truncates to the caller's `u8`
capacity and fills owned function/source BunStrings, zero-based line/column,
line-start bytes, code type, async state, and stable indices through
compile-pinned 48-byte `ZigStackTrace`, 72-byte `ZigStackFrame`, and 12-byte
position layouts. Matching upstream's `OnlyPosition` call, source-line arrays
remain empty and no source provider is retained. The consumer fixture covers a
line-41 named script, nested function/global frames, same-VM sibling access,
foreign rejection, capacity truncation, and explicit string release.

`Bun__attachAsyncStackFromPromise` adds the complementary native-error path:
pending Promises point to exact suspended async frames and transparent parent
links, while queued reactions retain activations only until delivery. The
bounded walker follows direct awaits and each plain forwarding segment for at
most 32 hops, stops at combinators/settled links, respects realm
`Error.stackTraceLimit`, and
never overwrites an existing or materialized stack or pending VM exception.
Focused coverage includes nested awaits, source positions, sibling realms, GC,
hop/limit boundaries, forwarding, and link clearing on completion.

The complete exception-projection slice pins the 216-byte `ZigException`
record and implements both inventoried follow-up exports plus the adjacent
`JSC__JSValue__toZigException` entry used by the native binding. It projects
owned name/message/system fields, exact error code and cause runtime type,
stable exception-cell identity, and the retained frame buffer without invoking
user getters. `ZigException__collectSourceLines` performs the second upstream
pass against the exact retained script ID, copying a capped current/preceding
source window into caller storage with zero-based numbers. Owned line strings
make the provider pointer deliberately null while preserving the consumer's
normal per-string deinit contract. The fixture covers Error, SyntaxError,
DOMException, primitive and system-like values, one- and three-line windows,
sibling lookup, foreign rejection, by-value conversion, and release.

The top-exception/termination slice adds all six pinned scope operations in the
caller-provided 8-byte release or 56-byte verification buffer, both 8-aligned.
Pure reads never process a termination request; trap-aware reads materialize one
stable VM-owned termination exception shared by sibling realms. Atomic request,
notification, clear, and set-only execution-forbidden controls preserve the
pinned VM behavior. Selective clear removes normal exceptions but retains
termination until explicit termination clear. OOM creation returns a fresh
selected-realm OutOfMemoryError without throwing; OOM and stack-overflow throw
helpers publish exact error kinds without replacing an existing exception.

The VM heap-control slice reports one context-group view of live heap bytes,
GC-owned external backing, and saturating embedder-reported extra memory.
`collectAsync` defers work to a runtime checkpoint; both pinned `runGC` paths
complete a full collection and return its post-sweep size. Weak-release and
footprint-shrink operations run real collection checkpoints, and opportunistic
work drains deferred GC plus live-realm microtasks only for a positive duration.
Precise heaps use zig-gc's race-safe live/last-full accounting API; arena VMs
report committed arena capacity. Sibling/foreign isolation, null boundaries,
counter saturation, deferred job execution, and first-exception preservation
are covered.

The VM execution-control slice adds the pinned API-lock trio and
execution-time-limit trio. The group API lock maps `JSC::VM::apiLock()` onto a
recursive per-group mutex: same-thread nesting increments depth without
deadlock while foreign threads block on a real atomic mutex, and the deprecated
callback form runs under that hold. The execution-time limit maps
`JSC::Watchdog` onto a lazily spawned host-watchdog thread per context group
that naps to the armed monotonic deadline, then raises the shared termination
request and cooperatively interrupts running evaluation through the documented
host-watchdog entry point. Arming mirrors the pinned timeout mapping (`+inf` is
`noTimeLimit`, non-positive values fire at the next watchdog tick, NaN stays
armed but never fires, finite values saturate instead of overflowing), one
arming fires at most once, the limit stays reported after firing, and clearing
never clears an already-requested termination. Per zig-js's documented
host-watchdog contract the interruption is terminal for the context. The
fixture covers armed-state sharing across sibling realms, foreign-VM isolation,
null tolerance, recursive reentry, cross-thread exclusion, and a real 30ms
interruption of an unbounded loop attributed to the watchdog through the
termination request.

The process-wide default-timezone boundary mirrors `WTF::setTimeZoneOverride`:
empty input clears the override, unknown names return false without disturbing
state, and accepted names are case-normalized, alias-resolved, and stored in
canonical IANA form exactly like the engine's Intl pipeline. The override
supplies the default zone for `Intl.DateTimeFormat` — and therefore
`Date#toLocaleString` — and for `Temporal.Now`, while explicit options keep
precedence; foreign context groups observe the same process-wide zone, and the
pinned date-cache reset is vacuous because zig-js caches none. zig-js `Date`
local-time methods remain UTC-coincident by engine design.

The VM trap-notification slice adds the two pinned `VMTraps` notifies that
have zig-js consumers. `JSC__VM__notifyNeedWatchdogCheck` sets a VM-wide trap
bit that the running interpreter consumes at its next step checkpoint,
re-checking the armed execution deadline on the executing thread and
terminating once it has elapsed — the synchronous half of the watchdog,
intentionally redundant with the host-watchdog thread exactly like JSC's trap
bit and `Watchdog` timer. Consumed with no armed limit or a future deadline
the trap is a no-op, so bounded evaluation is never disturbed.
`JSC__VM__notifyNeedDebuggerBreak` requests a debugger pause with reason
"pause" at the next statement boundary on every realm of the VM with an
enabled debugger session — the same path as CDP `Debugger.pause`, with
continuation ownership still chosen per pause — and stays inert while no
debugger is attached, matching a JSC trap without one. The inspector's
pause-request word is atomic end-to-end so a cross-thread notify cannot race
the runtime thread's consume, both exports tolerate a null VM, and the
fixture covers disarmed, future, and elapsed trap consumption against bounded
and unbounded loops plus termination attribution. The third pinned notify,
`JSC__VM__notifyNeedShellTimeoutCheck`, stays rejected: it is jsc-shell
`--timeout` machinery with no possible zig-js consumer.

The Bun-only object-marshalling boundary mirrors `JSC::constructEmptyObject`
followed by the consumer initializer (bindings.cpp:2477), the path Bun's
struct-to-POJO conversion uses. A fresh empty object with the realm
`Object.prototype` is handed to the callback exactly once, synchronously,
before the export returns, along with the exact pass-through context pointer,
the stable canonical cell handle the returned EncodedJSValue exposes at the
private cell boundary, and the same global handle. The capacity argument
stays a performance-only hint — JSC clamps it to `maxInlineCapacity`, zig-js
shapes grow on demand — a null initializer still creates the object, and a
null VM returns empty without invoking the callback.

The URLSearchParams boundary is thin plumbing over the engine's existing
builtin: `URLSearchParams__create` decodes the ZigString query through the
exact `new URLSearchParams(string)` path (URLSearchParams.cpp:34) — the
form-urlencoded parse strips one leading `?` and applies the `+`/percent
codec — so the result is a realm-prototype `instanceof URLSearchParams`
object whose methods all work. `URLSearchParams__fromJS` is the
`WebCoreCast<JSURLSearchParams, URLSearchParams>` downcast
(URLSearchParams.cpp:41): zig-js has no separate native object, the instance
IS the JS object carrying the engine's `\x00usp` pairs slot, so acceptance is
exactly "object with the pairs slot" — native-created or JS-constructed
alike, in any realm of the group — and the returned pointer is the canonical
cell handle per the object-marshalling convention above.
`URLSearchParams__toString` (URLSearchParams.cpp:49) serializes the pairs
exactly like the JS `toString` method and invokes the callback once with a
stable borrowed ZigString view, recovering the owner realm from the handle
because Bun's signature carries no global object. All three exports tolerate
null handles, and the full WHATWG URL parser surface (`URL__*`, `DOMURL__*`,
`BunString__toURL`/`toJSDOMURL`) stays deferred with the URL.zig cluster.

The URL native-record boundary (#308, first URL-cluster sub-slice) maps Bun's
context-free `WTF::URL*` exactly: because `URL__fromString` carries no global
object, the parsed URL is a native heap record (c_allocator, magic-validated
like the StringBuilder boundary) owning its component bytes in one backing
allocation — never a JS object. The engine's WHATWG parse layer
(`urlParse`/`urlSerialize` and helpers) was refactored from
interpreter-first to allocator-first with zero behavior change — those
functions only ever used the interpreter for its arena — so the JS `URL`
builtin, fetch Request/Response/redirect paths, and the new exports share
one parser. `URL__fromString` parses with no base and returns null for
invalid input (WTF validity: a scheme is required); `URL__deinit` frees the
record and clears its magic. The eleven component getters follow Bun/WTF
semantics rather than the JS getters wherever the two diverge: protocol is
the scheme without a colon, search keeps the leading `?` for a
present-but-empty query, host excludes the port while hostname includes it
(the inversion Home documents explicitly), port is `maxInt(u32)` when unset,
and hash keeps `#` only for a non-empty fragment. Every returned BunString is
an independently owned wtf-impl string, so results outlive the record and
any later parse. The remaining URL-cluster symbols (`URL__fromJS`,
`URL__getHref*`, the file-URL helpers, `BunString__toURL`/`toJSDOMURL`,
`DOMURL__*`, and `URL__originLength`) stay pending as follow-up sub-slices.

The URL JS-value and static string helpers (#309, second URL-cluster
sub-slice) complete the context-free and coercing halves of the cluster.
`URL__fromJS` and `URL__getHrefFromJS` coerce any same-VM value through
ToString: a throwing coercion publishes the pending exception and yields
null/Dead (Bun's `RETURN_IF_EXCEPTION` rule), a foreign-VM value publishes a
TypeError, and empty/invalid input yields null/Dead with no exception —
`fromJS` returns the #308 native record on success. The static helpers need
no realm: `URL__getHref` re-serializes with no base, `URL__getHrefJoin`
resolves the relative reference against the parsed base through the existing
`urlParse(rel, base)` path, `URL__getFileURLString` prefixes `file://` and
percent-encodes each `/`-separated segment with the WHATWG path encode set
(slashes preserved, dot segments NOT resolved — WTF sets the path
post-parse), and `URL__pathFromFileURL` returns the percent-decoded path
(`%XX` only — `+` stays literal) with no scheme check, matching
`url.fileSystemPath()`. Engine support stayed minimal and allocator-first:
`urlPercentEncode` gained `pub`, and one new `pub urlPercentDecode` helper
mirrors the form decoder without the `+` rule. Remaining URL-cluster symbols
after this slice: `BunString__toURL`/`toJSDOMURL` + `DOMURL__*` (JS DOMURL
object creation) and `URL__originLength` (Home declares it un-wrapped).

`URL__originLength` (#312, third URL-cluster sub-slice) closes the standalone
URL helpers: the latin-1 slice is widened to WTF-8 and parsed with no base,
and the returned `pathStart` mirrors `urlSerialize`'s prefix emission exactly
— `scheme:` plus, when a host component is present, `//` + userinfo
(`user[:pw]@`, only when non-empty) + host + (`:port` when set), plus the
`/.` sentinel for a non-opaque path that begins with `//`. Empty/invalid
input and a null slice yield 0 where Bun dereferences unconditionally. Only
the DOMURL object-creation group (`BunString__toURL`/`toJSDOMURL` +
`WebCore__DOMURL__cast_`/`href_`/`pathname_`/`fileSystemPath`) remains in
the cluster.

The DOMURL object boundary (#313, final URL-cluster sub-slice) completes the
cluster. `BunString__toJSDOMURL` and its ZigString-input sibling
`BunString__toURL` build the realm's URL-interface object exactly like
`new URL(str)` minus the new-target check — URL prototype, hidden component
slots, live `searchParams` snapshot — and, because `DOMURL::create` is
`ExceptionOr`, publish the TypeError and return an empty handle on invalid
input instead of creating empty-href objects. `WebCore__DOMURL__cast_` is
the VM-scoped downcast: it validates the VM handle zig-js publishes from
`JSC__JSGlobalObject__vm` (the context group), decodes with VM affinity, and
applies the hidden-slot predicate; the returned `DOMURL*` borrows the live
JS object (Bun's wrapper-owned impl pointer), so `href_`/`pathname_` read
through it as borrowed ZigString views interned in a process-global
latin1/UTF-16 store, and `fileSystemPath` stays context-free — `file:`
scheme required (error 3), non-empty host rejected (error 1),
case-insensitive `%2f` rejected (error 2) — returning the percent-decoded
path as an owned BunString and writing error codes only on failure, exactly
like Bun.

Seven shared job/registry imports implement selected-realm native callbacks and
encoded jobs, selected-realm and VM-wide microtask checkpoints, explicit
rejected-promise notification, exact ZigString module-entry deletion, and
delete-all-code. Native callback context/function bits remain queued until one
execution; encoded callables and arguments retain same-VM identity, empty
arguments normalize to `undefined`, and reentrant jobs drain to quiescence.
Throws publish the first VM exception and restore the untouched FIFO tail for a
later checkpoint. The persistent module registry is realm-local and traced
under the same lock used for deletion. Code deletion drains jobs, clears the
chosen realm's module/source caches, waits for every native execution and
compilation lease, resets all published tiers before unmapping pages, and
permits safe bytecode fallback or later recompilation.

Eight shared strong/weak reference imports implement the exact opaque embedding
handle boundary. Strong handles keep the EncodedJSValue word at offset zero for
Bun's inline `get`, trace the paired internal value, accept sibling-realm sets,
and reject foreign VMs without replacing the existing root. Weak handles accept
the two pinned owner kinds, retain the owner type/context, and use zig-gc atomic
external weak slots so `get`/`clear` cannot race collector clearing. A collected
FetchResponse target invokes its consumer finalizer exactly once outside the
collector weak lock; explicit clear/delete suppress that callback. Both handle
kinds retain their VM until delete, synchronize root-list mutation with tracing,
and cover null, invalid type/value, idempotent clear, GC, and finalization paths.

The array/index slice exports exact-length empty-array construction, direct
indexed put/push/read, and an observable indexed read. Logical holes are not
materialized as `undefined`; an explicit `undefined` remains present. Direct
writes bypass inherited setters, sparse writes advance length, index `2^32-1`
does not, and push at maximum length publishes a RangeError. Observable reads
perform ToObject and normal prototype/getter lookup, publishing thrown getter
values through the VM exception boundary. `JSArray__constructArray` validates
the complete encoded input slice before allocating the observable result, then
preserves packed order and owned-cell identity; sibling-realm values from the
same VM are accepted while foreign-VM values fail atomically with TypeError.
`JSArray__constructEmptyArray` preserves exact hole-only logical lengths through
the maximum u32 boundary. The two contiguous-vector exports return independent
stable JSC64 snapshots only for eligible packed Int32/boxed arrays. Revalidation
checks the exact array, vector, length, backing identity, current encodings, and
prototype safety; replacement, growth, holes, accessors, double/undecided
storage, pollution, or mismatched pointers fall back without dereference.
`Bun__JSValue__toNumber` implements full ToNumber:
primitive conversions, number-hint ToPrimitive hook order, Symbol/BigInt
TypeError, same-VM sibling values, foreign-value rejection, and exceptional NaN
with VM pending state while ordinary NaN remains non-exceptional. The private
has-instance predicate performs JSC's internal-capability precheck before
ordinary, custom, host, or proxy behavior; its counterpart implements JSC
`hasIteratorMethod`, rejecting primitives and running object GetMethod with
getter/callability exceptions. Private string inclusion applies full ToString
in receiver/search order and searches UTF-16 code units, preserving surrogate
substrings and publishing either coercion failure. Class classification follows
JSC call-data rules for JS classes, native constructors, bound functions, and
proxies; AggregateError checks immutable internal error kind. Shared C-API
realms reuse VM well-known Symbols and the Symbol registry. Private Object
keys/values create fresh selected-realm arrays of
own enumerable string properties in ECMAScript order; keys never read values,
while values re-check enumerability and perform Get in order. Proxy traps,
getters, abrupt completion, same-VM siblings, foreign VMs, and UTF-16 string
wrapper indices are covered. The native Promise slice adds the ten pinned
creation, direct-settlement, downcast, and callback-wrap symbols shared by Home
and Bun. InternalPromise is the pinned alias of JSPromise; constructors select
the requested realm and preserve exact value/reason identity without thenable
assimilation. `JSPromise__wrap` passes native promises through and converts
returned Errors or pending callback exceptions into rejections, whereas
`AnyPromise__wrap` settles an existing Promise through normal resolution and
therefore assimilates thenables and rejects self-resolution. Invalid or
foreign-VM inputs fail safely, callback exceptions are cleared exactly once,
and already-settled targets remain unchanged. `JSC__JSValue___then` adds the
detached reaction bridge shared by Home and Bun: the selected JSHostFn runs
asynchronously with exact `(settlement value, retained context)` JSC64
arguments. The handlers and context remain precise roots across pending
settlement and collection; sibling realms, FIFO/reentrant registration,
callback throws, non-Promise no-ops, and first-exception preservation are
covered. The Home-only JSMap slice adds all
seven direct native operations. It creates selected-realm Map cells and bypasses
mutable userland prototypes while preserving SameValueZero keys, exact stored
identity, insertion/reinsertion order, live size, sibling values, foreign-VM
failure atomicity, and first-exception behavior. The two shared FFI slow paths
decode validated JSC64 cells and apply exact signed/unsigned modulo-2^64 BigInt
conversion, including values beyond i128. CommonAbortReason conversion creates
fresh selected-realm TimeoutError/AbortError DOMExceptions with the pinned
messages and legacy codes and preserves a pre-existing VM exception. The
ZigString DOMException bridge implements the full pinned 0-through-40 code
matrix, including WebCore metadata and legacy codes, Bun's code-9 SyntaxError
divergence, all non-DOM special branches and Node-style codes, caller-message
override, and the unknown-code empty-name fallback. It constructs in the
selected realm and never replaces an existing exception. Four shared string
constructors copy every tagged ZigString representation, validate the pinned raw
UTF-8 path, intern atom backing per VM, and concatenate ordered ToString results
as exact UTF-16 sequences. Their tests cover source mutation, sibling realms,
foreign VMs, abrupt completion, and first-exception preservation. Two output
bridges cache stable group-lifetime borrowed views, using untagged
Latin-1 for 8-bit strings and tagged UTF-16 for all other strings. Direct
JSString output validates the cell/VM; JSValue output performs full ToString and
publishes Symbols, thrown values, and foreign-VM failures through the shared
exception slot. Five error factories construct fresh selected-realm Error,
TypeError, and RangeError instances from ZigString message/code pairs and every
BunString representation. They preserve the pinned writable TypeError `code`
and read-only RangeError `code` descriptors, omit empty codes, reject dead
strings, and retain the first exception. Three AggregateError bridges create
fresh ordered error arrays from encoded
slices or preserve an exact existing array and cause. Standard message/errors/
cause descriptors, direct own `errors` reads, selected realms, foreign-input
rejection, and failure atomicity are covered. Both pinned SystemError bridges
consume the exact 160-byte extern struct without owning its BunString fields.
The ordinary boundary creates a fresh Error with the exact message (including an
own empty `message`) and installs only populated
`code`/`path`/`dest`/`syscall`/`hostname` fields, a non-negative `fd`, and
unconditional `errno` in pinned order, all writable/enumerable but
non-configurable, with optional-field conversion failures cleared and skipped.
The `node:os` companion creates the `ERR_SYSTEM_ERROR` shape: a
`SystemError`-named Error with non-enumerable code, the composed summary
message, and a plain `info` object carrying unconditional
`code`/`syscall`/`message`/`errno` shared with the error's own DontDelete
fields. Eight property-boundary exports
add selected-realm two-key object creation with key-2-first definition order,
direct ZigString own writes, exact ToPropertyKey writes, ordinary deletion,
prototype-aware and Object.prototype-cutoff lookup, and own-only BunString or
value-key reads. Numeric/Symbol keys, accessors, proxies, duplicate insertion
order, Latin-1 names, sentinels, sibling realms, foreign values, and pending
exceptions are covered.
Three shared fast reads pin all 24 built-in IDs and distinguish direct data,
own-slot resolution, and pollution-mitigated lookup. Bun additionally exposes
a pure inherited-data `code` inquiry that rejects accessors, custom slots, and
proxies without executing them.
Three Symbol bridges share one registry across C-API sibling realms and expose
stable description/registry-key views for exact Latin-1 and UTF-16 content;
local and well-known Symbols correctly fail registry-key lookup. The native
StringBuilder slice adds all 13 pinned entry points with its 24-byte/8-byte
layout, exact UTF-16 and BunString decoding, shortest numeric formatting,
WebKit JSON escaping, sticky overflow/OOM, and non-destructive conversion.
The six TextCodec entry points implement the pinned fallback registry rather
than the browser-wide encoding universe: exact labels and canonical names,
replacement and x-user-defined codecs, ten single-byte tables, and seven
incremental CJK decoders. SHA-256-pinned WebKit tables are generated into a
compact embedded index, so behavior is cross-platform and adds no ICU, iconv,
or other runtime dependency. The fixture covers stable canonical-name storage,
owned results, split input, flush and stop-on-error state, deletion, and the
registry's no-op BOM hook.
The 14 shared AbortSignal exports attach a native owner only to genuine engine
signals, preserving one identity and reason across JS and native calls. Native
callbacks are exchanged before invocation for exact-once ordered reentrancy;
context-selective cleanup, common-reason sentinels, dependent premarking, and
ref/pending-activity roots share the same lifecycle. `AbortSignal.timeout()`
uses an unrefed, monotonic, generation-scoped context timer. Bun's additional
`WebCore__AbortSignal__getTimeout` borrows its exact four-field timeout record
only while active; cancellation invalidates it before native or JS callbacks.
The five rooted native-container entry points add callback-scoped marked
arguments and per-realm CommonJS function registries with precise-GC rooting,
cross-VM rejection, and exact append/set/swap-remove behavior. The private
module-loader slice adds persistent supplied/file sources, canonical relative
resolution, cache/namespace identity, exact Promise and exception channels,
top-level-await settlement, and complete module-graph tracing. The JSString
backing iterator adds pinned callback-layout validation and exact Latin-1 or
UTF-16 unit delivery. `JSFunction__createFromZig` creates native functions with
owned names and exact call/construct `CallFrame` delivery.
The three native CallFrame metadata exports layer a nested thread-local active
descriptor over that unchanged register layout. Exact frame and VM identity
gate an owned caller URL, one-based line/column, Bun-main origin detection, and
a bounded NUL-terminated description; the fixture covers sibling globals,
foreign VMs, stale/null pointers, constructors, and reentrant restoration.
The four FFI-function exports reuse that frame implementation with a distinct
validated function brand. Their names and arity are owned, the same callback
serves call and construct, nullable `dataPtr` mutation is atomic, and the
optional read-only/enumerable/configurable `ptr` property preserves the exact
callback-address bits. Dynamic-library metadata is stored separately; get/set
reject ordinary host functions and immediate values while accepting any valid
FFI cell regardless of VM ownership.
`JSC__Exception__getStackTrace` fills the caller-owned exact-layout frame buffer
from retained creation-time metadata rather than parsing `.stack`; the
position-only path owns its function/URL BunStrings and returns no source-line
provider. Full `ZigException` projection and its second source-line pass retain
the same frame/script identity and own every returned string. The combined
runtime fixtures cover these semantics; the two profile-selected JSType exports
retain their separate Home/Bun runtime fixtures.

## Profile-selectable JSType layout

[`private-jstype-layouts.json`](private-jstype-layouts.json) pins the complete
private enum from both consumer sources: 97 Home members and 98 Bun members.
All 97 Home names are shared, but Bun inserts
`WebAssemblyStreamingContext = 27`, renumbering 70 later shared tags. For
example, `FinalObject` is 34 for Home and 35 for Bun. The source revisions,
paths, SHA-256 digests, all member values, and the exact added/removed/renumbered
comparison are audited rather than inferred from declaration compatibility.

The library therefore requires an explicit compile-time profile whenever Bun
numbering is wanted; Home is the default and every other value is rejected:

```sh
zig build private-jstype-abi-audit
zig build private-jstype-abi-audit \
  -Dhome-source-root="$HOME/Code/Home/lang" \
  -Dbun-source-root="$HOME/Code/bun"
zig build test-private-jstype
zig build test-private-jstype -Dprivate-abi-consumer=bun
```

`JSC__JSValue__jsType` and `JSC__JSCell__getType` return the selected exact
tags without exposing zig-js object flags. Both separately compiled runtime
fixtures cover 20 real cell kinds, including GetterSetter,
CustomGetterSetter, strings, Symbols, BigInts,
ordinary objects, JavaScript/native functions, errors, arrays, buffers,
typed arrays, DataView, RegExp, Date, Promise, Map/Set/weak collections, and a
boxed string.

## Bun core private inventory

`bun-private-core-4982b91e` pins Bun revision
`4982b91e3702094330f3be3883354c52b8c01323` and scopes the first Bun profile to
`src/jsc`. Bundled C libraries, N-API, wider runtime/WebCore code, and generated
bindings are deliberately excluded until separately inventoried. The core
profile contains 484 unique symbols from 59 hashed files:

| Classification | Symbols |
|---|---:|
| Private JSC/Bun/WebCore ABI under #164 | 461 (348 implemented, 113 pending) |
| Public-C overlap | 22 |
| Consumer-generated definition (`JSFunctionCall`) | 1 |
| **Total** | **484** |

The checked-in comparison proves that Home cannot stand in for Bun: 481 symbol
names are shared, Bun has 3 core-only symbols, Home has 57 core-only symbols,
and 37 shared names have different normalized signatures. The inventory lists
every name in each category rather than reducing that result to counts.

```sh
zig build bun-private-abi-audit
zig build bun-private-abi-audit -Dbun-source-root="$HOME/Code/bun"
zig build test-bun-private-property-iterator -Dprivate-abi-consumer=bun
zig build test-bun-private-array-buffer -Dprivate-abi-consumer=bun
```

The audit rejects revision, file hash, declaration digest, classification,
calling-convention, implementation-status, and Home-comparison drift. It does
not claim complete Bun runtime compatibility; #164 remains open for the 113
pending core entries and later wider/generated profiles.
