---
title: Binary data
description: ArrayBuffer, the twelve typed arrays, DataView, SharedArrayBuffer, and Atomics in zig-js.
---

# Binary data

## `ArrayBuffer`

Beyond the classic surface, zig-js implements the modern buffer proposals:

| Member | Behaviour |
| --- | --- |
| `resizable`, `maxByteLength`, `resize()` | Resizable buffers, with length-tracking views following the buffer. |
| `transfer()`, `transferToFixedLength()` | Ownership transfer; the source detaches. |
| `transferToImmutable()`, `sliceToImmutable()`, `immutable` | Immutable buffers. |
| `detached` | Reflects detach state from transfer or structured clone. |
| `slice()` | Standard copy. |

Detached-buffer checks are enforced at every access site, and a resize is
synchronized against bulk copies (`Atomics` operations, `copyWithin`, `slice`)
so a concurrent resize cannot tear a copy — see
[Memory model](/threads/memory-model) for exactly which races are engine races
and which are program races.

## Typed arrays

All twelve element types share one `%TypedArray%.prototype`:

`Int8Array`, `Uint8Array`, `Uint8ClampedArray`, `Int16Array`, `Uint16Array`,
`Int32Array`, `Uint32Array`, `Float16Array`, `Float32Array`, `Float64Array`,
`BigInt64Array`, `BigUint64Array`.

`BigInt64Array` and `BigUint64Array` read and write BigInt values; the rest use
Numbers. `%TypedArray%` itself is the abstract superclass constructor — it can
neither be called nor constructed directly.

Length-tracking views over resizable buffers, out-of-bounds handling after a
resize, and the immutable-buffer write rejection are all implemented.

## `DataView`

Byte-precise access with explicit endianness across every element width,
including `getFloat16` / `setFloat16` and the BigInt accessors, with the same
detach and bounds checks.

## `SharedArrayBuffer`

Installed when the context allows it. Storage is **refcounted**
([`src/shared_buffer.zig`](https://github.com/zig-utils/zig-js/blob/main/src/shared_buffer.zig)),
so the same backing memory can be retained across agents, Workers, and
shared-realm `Thread`s while each holds its own JavaScript object.

A conformance-shaped knob exists for engine-shell parity: a context can leave
property-mode `Atomics` installed while hiding the global `SharedArrayBuffer`
constructor, modelling `--useSharedArrayBuffer=0`.

## `Atomics`

Two modes are supported:

- **Typed-array `Atomics`** — `add`, `and`, `compareExchange`, `exchange`,
  `load`, `or`, `store`, `sub`, `xor`, `isLockFree`, plus `wait`, `waitAsync`,
  and `notify` against the shared waiter table in
  [`src/agent.zig`](https://github.com/zig-utils/zig-js/blob/main/src/agent.zig).
- **Property-mode `Atomics`** — the same operations against ordinary object
  properties, used by the shared-realm `Thread` model.

With `enable_threads`, `Atomics` additionally carries the proposal-aligned
`Atomics.Mutex` and `Atomics.Condition`, alongside the standalone `Lock`,
`Condition`, and `ThreadLocal` globals. See
[Concurrency](/features/concurrency).

## Blocking and `[[CanBlock]]`

Whether a blocking `Atomics.wait` is permitted is a host decision. Conformance
and embedder harnesses model `[[CanBlock]]`; when it is false, blocking APIs
throw if they would have to park, while non-blocking fast paths and the async
forms (`waitAsync`) continue to work.

## Structured clone and transfer

[`src/structured_clone.zig`](https://github.com/zig-utils/zig-js/blob/main/src/structured_clone.zig)
implements the wire format used by `structuredClone()` and by Worker
`postMessage`, including `ArrayBuffer` transfer with detach and
`SharedArrayBuffer` retention (shared, not copied).

## WebAssembly memory

Wasm linear memory, including shared memory with atomic access and
`wait32`/`wait64`/`notify`, is documented in [WebAssembly](/wasm).
