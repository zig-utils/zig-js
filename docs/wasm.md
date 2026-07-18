# WebAssembly MVP Status

WebAssembly support is being landed as independently verified slices under
[issue #141](https://github.com/zig-utils/zig-js/issues/141). It is not yet a
complete JavaScript WebAssembly API, and it is not included in the configured
test262 score.

## Implemented

The engine has a pure-Zig MVP binary pipeline:

- strict binary decoding with stable byte-offset diagnostics;
- module validation for MVP types, control flow, calls, globals, tables,
  linear memory, imports, exports, element/data segments, and start functions;
- an interpreter for MVP control, numeric, memory, table, global, direct-call,
  and indirect-call instructions; and
- deterministic traps and explicit rejection of unsupported opcodes and
  sections rather than silent acceptance.

The JS-facing slices on main through `0835f411` provide:

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
  immutable null-prototype exports;
- callable exported functions with i32/i64/f32/f64 conversion, JS import calls,
  exception identity, indirect calls, and `RuntimeError` traps; and
- `WebAssembly`, `Module`, `Instance`, `Memory`, `Table`, and `Global` branding
  and derived constructor prototypes.

The module and its decoded data are owned by the creating context and released
during deterministic context teardown. `customSections` returns fresh
`ArrayBuffer` copies. Detached or out-of-bounds views and direct
`SharedArrayBuffer` inputs are rejected.

## Evidence

The focused WebAssembly unit suite passes 118/118 at `0835f411`, covering the
decoder, validator, executor, JS API, store growth, linking, function calls,
traps, imported/defined identity, and precise-GC retention. The batched full
engine suite passes 998/998 at the same runtime checkpoint. Both runs report
zero failures, skips, and leaks.

Run the focused suite with:

```sh
zig build test -Dtest-filter=wasm
```

## Still open

The following remain required before #141 can close:

- `WebAssembly.compile` and both `WebAssembly.instantiate` overloads with
  Promise semantics; and
- a pinned upstream MVP specification corpus plus a machine-readable
  pass/fail/skip inventory with no hidden exclusions.

Post-MVP feature profiles are tracked separately by
[issue #142](https://github.com/zig-utils/zig-js/issues/142), and PR-249
WebAssembly/JIT shell hooks by
[issue #143](https://github.com/zig-utils/zig-js/issues/143).
