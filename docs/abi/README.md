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
| Private JSC/Bun/WebCore ABI under #163 | 432 (4 implemented, 428 pending) |
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
The first four private entries are implemented; the other 428 remain pending
until #163 provides their type/layout contracts, shims, and consumer evidence.

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

The first completed shim slice exports the pinned signatures for
`JSC__JSValue__eqlCell`, `JSC__JSValue__eqlValue`,
`JSC__JSValue__toBoolean`, and `JSC__JSValue__toInt32`. Raw primitive words use
the codec directly; cell words resolve through context-owned public C-API boxes
without exposing the internal NaN-box layout. The compile-link-runtime gate is:

```sh
zig build test-home-private-abi
```

It covers empty/immediate/int32/double/NaN/negative-zero behavior and boxed
empty/nonempty strings plus object identity/truthiness. Public accounting stays
unchanged at 117 functions and 19 extensions; these four symbols are reported
only as private profile exports.
