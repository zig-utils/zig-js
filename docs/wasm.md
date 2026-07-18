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

The focused WebAssembly unit suite passes 133/133 at `f30577b2`, covering the
decoder, validator, executor, JS API, store growth, linking, function calls,
traps, imported/defined identity, precise-GC retention, stable asynchronous
compilation inputs, Promise timing, overload result shapes, and rejection
classes, the opt-in Core 2.0 numeric operations, and the test-only bit-exact
corpus boundary. The most recent batched
full engine checkpoint passes 1,002/1,002 at `af689c4a`. Both runs report zero
failures, skips, and leaks.

The checked-in [upstream inventory](.data/wasm-spec-inventory.json) pins
`WebAssembly/spec` tag `wg-1.0` at
`977f97014c962f7bd1291fcc6d28b41a924882bf` and WABT 1.0.12 at
`cf261f2bd561297e0da7008ddde8c09ba5ea35a2`. At engine checkpoint `977d02c8`,
all 18,840 applicable binary-runtime commands pass across all 73 MVP files,
with zero failures and zero runner errors. Inventory schema v2 accounts for
every one of the 19,270 commands and records its execution mode: 16,801 use the
public JavaScript API, 2,039 exact f32/f64 NaN payload/sign assertions use the
test-only raw-bit path, and 430 text-format syntax assertions are outside the
binary JavaScript API.

Run the focused suite with:

```sh
zig build test -Dtest-filter=wasm
```

Build WABT 1.0.12 at the pinned commit above, then reproduce the deliberate
complete corpus run with:

```sh
zig build wasm-spec -Dwast2json=/path/to/wabt-1.0.12/wast2json
```

CI runs bounded `linking.wast` and `f32_bitwise.wast` smoke/drift gates. Together
they verify the corpus pin, converter compatibility, 118 linking/store commands,
and all 364 f32 bit-exact cases without putting the multi-minute complete
inventory on every push.

## Beyond the MVP

The corpus evaluator keeps the standards-facing JavaScript API unchanged while
using a test-only Context hook for NaN payload/sign assertions that JavaScript
`Number` cannot represent bit-exactly. This makes the full MVP binary-runtime
score auditable without exposing a non-standard WebAssembly method to embedders.

Post-MVP feature profiles are tracked separately by
[issue #142](https://github.com/zig-utils/zig-js/issues/142), and PR-249
WebAssembly/JIT shell hooks by
[issue #143](https://github.com/zig-utils/zig-js/issues/143).

The machine-readable [feature registry](.data/wasm-feature-profiles.json) pins
the official proposal tracker and 12 selected proposal repositories by exact
commit. It distinguishes finished WebAssembly 2.0/3.0 features from the active
Phase-4 Threads proposal, declares dependency closure and host constraints, and
keeps MVP as the only default/implemented profile until the corresponding
runtime child issue is actually complete. Validate registry drift with:

```sh
zig build wasm-feature-profiles-check
```

Zig embedders opt into an exact feature set per realm; module bytes never
self-enable proposals. Invalid dependency sets fail during Context creation,
while a selected but unfinished feature produces a deterministic
`WebAssembly.CompileError` identifying it:

```zig
const ctx = try js.Context.createWith(gpa, .{
    .wasm_features = .{
        .reference_types = true,
        .multi_value = true,
    },
});
```

The five sign-extension instructions and eight nontrapping float-to-integer
conversions are implemented behind their independent `sign_extension_ops` and
`nontrapping_float_to_int` switches. They decode, validate, instantiate, and
execute through the public JavaScript API; neither switch is enabled by
default, and enabling them does not imply that the remaining Core 2.0 profile
is complete.

Implementation is split into the shared gating foundation
[#262](https://github.com/zig-utils/zig-js/issues/262), the Core 2.0 numeric
operations [#269](https://github.com/zig-utils/zig-js/issues/269), the structural core 2.0 baseline
[#263](https://github.com/zig-utils/zig-js/issues/263), SIMD
[#264](https://github.com/zig-utils/zig-js/issues/264), Threads
[#265](https://github.com/zig-utils/zig-js/issues/265), exceptions/tail calls
[#266](https://github.com/zig-utils/zig-js/issues/266), memory64/GC
[#267](https://github.com/zig-utils/zig-js/issues/267), and the final profile
conformance matrix [#268](https://github.com/zig-utils/zig-js/issues/268).
