---
title: Built-ins
description: The zig-js standard library — global functions, fundamental objects, collections, Promise, Proxy/Reflect, and the global object itself.
---

# Built-ins

Every built-in constructor and prototype method is written from scratch in Zig
([`src/builtins.zig`](https://github.com/zig-utils/zig-js/blob/main/src/builtins.zig)
and the built-in installers in `src/interpreter.zig`). Nothing is delegated to a
host JavaScript engine.

## Global object

`globalThis` is the global object; global `var` and function declarations become
own properties of it, while global lexical declarations do not.

**Value properties:** `NaN`, `Infinity`, `undefined`.

**Function properties:** `eval`, `parseInt`, `parseFloat`, `isNaN`, `isFinite`,
`encodeURI`, `encodeURIComponent`, `decodeURI`, `decodeURIComponent`, `escape`,
`unescape`, `queueMicrotask`, `structuredClone`, `btoa`, `atob`.

**Harness and host hooks** are also installed: `print`, `gc`, `quit`,
`drainMicrotasks`, `$drainRunLoop`, `$drainFinalizationCleanup`, `noInline`, and
`numberOfDFGCompiles`. These exist so conformance and engine-shell corpora run
unmodified; treat them as harness surface, not as a stable embedding API. There
is **no `console`** — embedders install their own.

## Fundamental objects

| Constructor | Notes |
| --- | --- |
| `Object` | Full descriptor surface, `Object.groupBy`, `hasOwn`, spread and rest through Proxy traps. |
| `Function` | Including `bind`, `call`, `apply`, and the strict `caller`/`arguments` poison pill. |
| `Boolean`, `Number`, `String`, `Symbol`, `BigInt` | Wrapper objects coerce through `ToPrimitive`/`ToNumeric` in specified order. |
| `Array` | Dense and sparse (hole-preserving) semantics, `toSorted`/`toReversed`/`toSpliced`/`with`, `at`, `flat`/`flatMap`, `group`-style helpers. |
| `Error` family | `Error`, `TypeError`, `RangeError`, `ReferenceError`, `SyntaxError`, `EvalError`, `URIError`, `AggregateError`, `SuppressedError`, `OutOfMemoryError`. |
| `Date` | Backed by the checked-in IANA zone and offset tables. |
| `RegExp` | Backed by `zig-regex` in ECMAScript mode; includes `RegExp.escape`. |
| `JSON` | `parse` (with reviver and source access), `stringify` (with replacer and space), `rawJSON` / `isRawJSON`. |
| `Math` | The full method set. |

## Strings are UTF-16

`String` semantics are UTF-16: indexing, `length`, comparison, and iteration all
operate on code units, with a separate code-point iterator for `for…of`.
Internally strings are WTF-8 backed, so anything UTF-16-semantic must re-split
astral scalars into surrogate pairs — a recurring source of subtle bugs, and the
reason string work carries dedicated tests.

Unicode support is generated from checked-in tables: case mapping
(`unicode_case_data.zig`), normalization (`unicode_normalize_data.zig`),
grapheme segmentation (`unicode_grapheme_data.zig`), and IDNA
(`unicode_idna_data.zig`, `idna.zig`). Regenerate them with the `tools/gen_*`
scripts; never hand-edit.

## Collections and keyed data

`Map`, `Set`, `WeakMap`, `WeakSet`, plus `Map.groupBy` and the ES2024 `Set`
operations (`union`, `intersection`, `difference`, `symmetricDifference`,
`isSubsetOf`, `isSupersetOf`, `isDisjointFrom`).

`WeakRef` and `FinalizationRegistry` are implemented against the precise
collector: under `enable_gc`, collection clears `WeakRef` targets, prunes weak
keys, queues registry records, and drains registered cleanup callbacks as host
cleanup jobs at checkpoints. See [Memory & GC](/advanced/memory-and-gc).

## Iteration

`Symbol.iterator` / `Symbol.asyncIterator` protocols throughout, plus the
`Iterator` and `AsyncIterator` constructors with the iterator-helper method set
described in [Language](/features/language#generators-async-and-iteration).

## Symbols

`Symbol` with the well-known symbols — `iterator`, `asyncIterator`,
`hasInstance`, `toPrimitive`, `toStringTag`, `species`, `unscopables`,
`isConcatSpreadable`, `match`/`matchAll`/`replace`/`search`/`split`, `dispose`,
`asyncDispose` — plus the global symbol registry (`Symbol.for` / `keyFor`).

Well-known symbols are **shared across realms**, so symbol identity holds through
`$262.createRealm()`.

## Promises and jobs

`Promise` with `all`, `allSettled`, `any`, `race`, `resolve`, `reject`,
`withResolvers`, and `try`. The microtask queue lives in
[`src/promise.zig`](https://github.com/zig-utils/zig-js/blob/main/src/promise.zig)
and is owned by the `Context`.

Job ordering is exact and observable: `queueMicrotask` and promise reactions
share one queue, and the host drains it at defined checkpoints. Timers are a
separate macrotask stage — see [Timers](/timers).

## Reflection

`Proxy` with the full trap set, and `Reflect` with the matching operations.
Proxy traps are honoured by the operations that commonly forget them here:
object spread, object rest destructuring, `Object.assign`, `Object.keys` and
friends, and public class field definition on a proxy receiver.

## Binary data

`ArrayBuffer`, the twelve typed arrays, `DataView`, `SharedArrayBuffer`, and
`Atomics` have their own page: [Binary data](/features/binary-data).

## Internationalization

`Intl` and `Temporal` have their own page:
[Intl & Temporal](/features/intl-temporal).

## Host-shaped globals

`setTimeout`/`setInterval`, `URL`, `TextEncoder`/`TextDecoder`,
`Headers`/`Request`/`Response`, `Blob`, `FormData`, `AbortController`, and
`structuredClone` are documented in [Web-shaped APIs](/features/web-apis).

`WebAssembly` is installed when the Wasm API is enabled for the context; see
[WebAssembly](/wasm).
