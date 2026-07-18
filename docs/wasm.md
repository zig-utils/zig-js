# WebAssembly MVP Status

WebAssembly support is being landed as independently verified slices under
[issue #141](https://github.com/zig-utils/zig-js/issues/141). The MVP binary
runtime and JavaScript API are complete; WebAssembly remains separate from the
configured test262 score because it has its own upstream specification corpus.

## Implemented

The engine has a pure-Zig MVP binary pipeline:

- strict binary decoding with stable byte-offset diagnostics;
- module validation for MVP types, control flow, calls, globals, tables,
  linear memory, imports, exports, element/data segments, and start functions;
- an interpreter for MVP control, numeric, memory, table, global, direct-call,
  and indirect-call instructions; and
- deterministic traps and explicit rejection of unsupported opcodes and
  sections rather than silent acceptance.

The JS-facing MVP implementation on main through `9e16789e` provides:

- the `WebAssembly` namespace;
- `WebAssembly.CompileError`, `LinkError`, and `RuntimeError` with the correct
  `Error` prototype chain;
- `new WebAssembly.Module(BufferSource)` with an owned byte snapshot;
- `WebAssembly.validate(BufferSource)`;
- `WebAssembly.Module.imports`, `.exports`, and `.customSections`;
- `WebAssembly.Memory` with live zero-copy `buffer` exposure and
  failure-atomic `grow`;
- growth that preserves bytes, zero-fills new pages, detaches and empties the
  old buffer, and publishes a fresh buffer identity;
- transfer/detach protection for live Memory buffers, including
  `structuredClone`, ArrayBuffer transfer methods, and the test host hook;
- `WebAssembly.Global` for mutable and immutable `i32`, `i64`, `f32`, and `f64`
  values, including modulo integer conversion, BigInt boundaries, `valueOf`,
  and numeric coercion;
- `WebAssembly.Table` with `anyfunc` null/function references, exact JS identity,
  bounds checks, `get`, `set`, `grow`, and GC-visible atomic reference slots;
- `WebAssembly.Instance` with all four import/export kinds, limit/type checks,
  active element/data segments, start functions, imported-store identity, and
  immutable null-prototype exports, including primitive immutable-global
  imports and failure-atomic linking;
- callable exported functions with i32/i64/f32/f64 conversion, JS import calls,
  exception identity, indirect calls, and `RuntimeError` traps;
- `WebAssembly.compile` and both `WebAssembly.instantiate` Promise overloads,
  including synchronous byte snapshots, queued work, asynchronous rejection,
  exact error classes, and the specified Module-versus-bytes result shapes;
  and
- `WebAssembly`, `Module`, `Instance`, `Memory`, `Table`, and `Global` branding
  and derived constructor prototypes.

The module and its decoded data are owned by the creating context and released
during deterministic context teardown. `customSections` returns fresh
`ArrayBuffer` copies. Detached or out-of-bounds views and direct
`SharedArrayBuffer` inputs are rejected.

## Evidence

The focused WebAssembly unit suite passes 122/122 at `af689c4a`, covering the
decoder, validator, executor, JS API, store growth, linking, function calls,
traps, imported/defined identity, precise-GC retention, stable asynchronous
compilation inputs, Promise timing, overload result shapes, and rejection
classes. The same batched checkpoint passes the full engine suite 1,002/1,002.
Both runs report zero failures, skips, and leaks.

The checked-in [upstream inventory](.data/wasm-spec-inventory.json) pins
`WebAssembly/spec` tag `wg-1.0` at
`977f97014c962f7bd1291fcc6d28b41a924882bf` and WABT 1.0.12 at
`cf261f2bd561297e0da7008ddde8c09ba5ea35a2`. At engine checkpoint `038ebaf3`,
all 16,801 JavaScript-observable commands pass across all 73 MVP files, with
zero failures and zero runner errors. The inventory accounts for every one of
the 19,270 commands: 430 text-format syntax assertions are outside the binary
JavaScript API, and 2,039 exact f32/f64 NaN payload/sign assertions are linked
to the bit-exact runner work in
[#261](https://github.com/zig-utils/zig-js/issues/261).

Run the focused suite with:

```sh
zig build test -Dtest-filter=wasm
```

Build WABT 1.0.12 at the pinned commit above, then reproduce the deliberate
complete corpus run with:

```sh
zig build wasm-spec -Dwast2json=/path/to/wabt-1.0.12/wast2json
```

CI runs the bounded `linking.wast` smoke/drift gate; it verifies the corpus pin,
converter compatibility, and 118 linking/store commands without putting the
multi-minute complete inventory on every push.

## Beyond the MVP

The JavaScript `Number` boundary cannot carry every exact WebAssembly NaN
payload and sign. A direct bit-exact corpus path is tracked by
[#261](https://github.com/zig-utils/zig-js/issues/261); the public API inventory
keeps those commands explicit rather than counting accidental canonicalization
as a pass or an engine failure.

Post-MVP feature profiles are tracked separately by
[issue #142](https://github.com/zig-utils/zig-js/issues/142), and PR-249
WebAssembly/JIT shell hooks by
[issue #143](https://github.com/zig-utils/zig-js/issues/143).
