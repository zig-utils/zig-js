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
Home `packages/runtime/src/jsc` tree. It records every legacy/private-style
`extern fn` declaration with its normalized signature and digest, source file
and line, source-file digest, classification, status, and effective calling
convention. The exact current denominator is:

| Classification | Symbols |
|---|---:|
| Private JSC/Bun/WebCore ABI under #163 | 431 (97 implemented, 334 pending) |
| Overlap with zig-js's completed public C target | 15 |
| Platform libc import | 1 |
| Consumer-generated definition (`JSFunctionCall`) | 1 |
| **Total** | **448** |

The 448 declarations come from 58 pinned source files, with zero duplicate or
unclassified symbols. Calling conventions are also explicit: 443 use the
`extern` C default, four spell `.c`, and one uses Home's `jsc.conv` (x86_64
SysV on Windows x64, C elsewhere).

```sh
zig build home-private-abi-audit
zig build home-private-abi-audit -Dhome-source-root="$HOME/Code/Home/lang"
```

This inventory is the denominator, not a claim that the whole surface works.
The first 97 private entries are implemented; the other 334 remain pending
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
changed files, and each audit rechecks all 58 source hashes plus all 448
normalized declarations, locations, classifications, and calling conventions
against the immutable base inventory. All three alias manifests report zero
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
and 19 extensions; these 97 symbols are reported only as private profile
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

The pinned consumer sources contain two defects that the name-based inventory
cannot express: Bun's Zig declaration gives `DateNowISOString` the incompatible
`(*JSGlobalObject, f64) JSValue` signature even though its wrapper and C++ body
use `(*JSGlobalObject, *[28]u8) c_int`, and `getUTCTimestamp` is declared but has
no C++ definition. The runtime fixture therefore pins the executable writer
contract and the coherent owned-Date UTC internal-time contract, rather than
claiming those two source inconsistencies match.

The VM exception slice exports the shared `JSGlobalObject`/`VM` pending-state
boundary plus exception-cell conversion and classification. Sibling realms in
one context group observe the same VM pointer and pending cell; taking or
clearing through either realm clears the shared state. Throws preserve the
original primitive or Error identity, retain the first pending exception, and
keep the thrown value rooted until clear/take. Exception cells remain distinct
from ordinary values and can be safely rethrown.

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
the maximum u32 boundary. `Bun__JSValue__toNumber` implements full ToNumber:
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
and already-settled targets remain unchanged. The Home-only JSMap slice adds all
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
exception slot. The 95-symbol combined runtime fixture covers these semantics;
the two profile-selected JSType exports retain their separate Home/Bun runtime
fixtures.

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
fixtures cover 20 real cell kinds, including strings, Symbols, BigInts,
ordinary objects, JavaScript/native functions, errors, arrays, buffers,
typed arrays, DataView, RegExp, Date, Promise, Map/Set/weak collections, and a
boxed string.

## Bun core private inventory

`bun-private-core-4982b91e` pins Bun revision
`4982b91e3702094330f3be3883354c52b8c01323` and scopes the first Bun profile to
`src/jsc`. Bundled C libraries, N-API, wider runtime/WebCore code, and generated
bindings are deliberately excluded until separately inventoried. The core
profile contains 437 unique declarations from 54 hashed files:

| Classification | Symbols |
|---|---:|
| Private JSC/Bun/WebCore ABI under #164 | 421 (90 implemented, 331 pending) |
| Public-C overlap | 15 |
| Consumer-generated definition (`JSFunctionCall`) | 1 |
| **Total** | **437** |

The checked-in comparison proves that Home cannot stand in for Bun: 434 symbol
names are shared, Bun has 3 core-only symbols, Home has 14 core-only symbols,
and 28 shared names have different normalized signatures. The inventory lists
every name in each category rather than reducing that result to counts.

```sh
zig build bun-private-abi-audit
zig build bun-private-abi-audit -Dbun-source-root="$HOME/Code/bun"
```

The audit rejects revision, file hash, declaration digest, classification,
calling-convention, implementation-status, and Home-comparison drift. It does
not claim complete Bun runtime compatibility; #164 remains open for the 331
pending core entries and later wider/generated profiles.
