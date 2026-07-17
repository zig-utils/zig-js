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
| Private JSC/Bun/WebCore ABI under #163 | 432 (52 implemented, 380 pending) |
| Overlap with zig-js's completed public C target | 15 |
| Platform libc import | 1 |
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
The first fifty-two private entries are implemented; the other 380 remain pending
until #163 provides their type/layout contracts, shims, and consumer evidence.

Home revisions `5e829ad483bb9e5ccb19766997df6462edd8e167` and
`38702f9e43b3aecbee7d5b7aa48cc66d41cabde7` are supported as the explicit
`home-private-5e829ad4` and `home-private-38702f9e` aliases. Neither is a silent
repin: the full `packages/runtime/src/jsc` diff against `7ed99c02` has zero
changed files, and each audit rechecks all 58 source hashes plus all 448
normalized declarations, locations, classifications, and calling conventions
against the immutable base inventory. Both alias manifests report zero
additions, removals, signature changes, and calling-convention changes.

```sh
zig build test-home-private-abi \
  -Dhome-private-abi-profile=home-private-38702f9e \
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
and 19 extensions; these fifty-two symbols are reported only as private profile
exports.

The opaque BigInt cell slice additionally exports `JSC__JSBigInt__fromJS`, the
three signed/unsigned/double ordering functions, and `JSC__JSBigInt__toInt64`.
It reuses zig-js's arbitrary-precision integer comparison rather than narrowing
through `f64`: the runtime matrix covers values beyond i128, the 2^53 rounding
boundary, positive and negative fractional comparisons, the minimum positive
subnormal, infinities, a 10^400 BigInt against `floatMax`, and signed
modulo-2^64 extraction. `JSC__JSBigInt__toString` remains pending until its
separate Bun/Home string-return layout is pinned.

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
for non-Date cells. String parsing, local/UTC conversion, and buffer-based ISO
formatting remain pending as separate contracts.

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
getter/callability exceptions. The 50-symbol combined runtime fixture covers
these semantics; the two profile-selected JSType exports retain
their separate Home/Bun runtime fixtures.

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
| Private JSC/Bun/WebCore ABI under #164 | 422 (52 implemented, 370 pending) |
| Public-C overlap | 15 |
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
not claim complete Bun runtime compatibility; #164 remains open for the 370
pending core entries and later wider/generated profiles.
