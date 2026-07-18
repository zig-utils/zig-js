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

The JS-facing slice on main through `1296dd80` provides:

- the `WebAssembly` namespace;
- `WebAssembly.CompileError`, `LinkError`, and `RuntimeError` with the correct
  `Error` prototype chain;
- `new WebAssembly.Module(BufferSource)` with an owned byte snapshot;
- `WebAssembly.validate(BufferSource)`;
- `WebAssembly.Module.imports`, `.exports`, and `.customSections`; and
- `WebAssembly` and `WebAssembly.Module` branding.

The module and its decoded data are owned by the creating context and released
during deterministic context teardown. `customSections` returns fresh
`ArrayBuffer` copies. Detached or out-of-bounds views and direct
`SharedArrayBuffer` inputs are rejected.

## Evidence

The focused WebAssembly unit suite passes 110/110 at `1296dd80`, covering the
decoder, validator, executor, and first JS API slice. The most recent complete
engine suite was 989/989 at `ed109b6d`; the full suite is intentionally batched
after multiple WebAssembly store/API slices instead of being rerun for every
small checkpoint.

Run the focused suite with:

```sh
zig build test -Dtest-filter=wasm
```

## Still open

The following remain required before #141 can close:

- JS-facing `Instance`, `Memory`, `Table`, `Global`, and exported function
  behavior;
- import/export linking, JS/Wasm conversion, exception propagation, traps,
  start functions, and growth visible through the JS API;
- `WebAssembly.compile` and both `WebAssembly.instantiate` overloads with
  Promise semantics; and
- a pinned upstream MVP specification corpus plus a machine-readable
  pass/fail/skip inventory with no hidden exclusions.

Post-MVP feature profiles are tracked separately by
[issue #142](https://github.com/zig-utils/zig-js/issues/142), and PR-249
WebAssembly/JIT shell hooks by
[issue #143](https://github.com/zig-utils/zig-js/issues/143).
