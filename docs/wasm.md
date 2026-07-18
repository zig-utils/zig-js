# WebAssembly Status

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

The JS-facing runtime on main through `66237d21` provides:

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
- `WebAssembly.Global` for mutable and immutable numeric and reference values,
  including modulo integer conversion, BigInt boundaries, arbitrary externref
  identity, `valueOf`, and numeric coercion;
- `WebAssembly.Table` with `anyfunc`/`funcref` and `externref` elements, exact JS
  identity, bounds checks, `get`, `set`, `grow`, and GC-visible atomic reference
  slots;
- `WebAssembly.Instance` with all four import/export kinds, limit/type checks,
  active element/data segments, start functions, imported-store identity, and
  immutable null-prototype exports, including primitive immutable-global
  imports and failure-atomic linking;
- callable exported functions with numeric, funcref, and externref conversion,
  JS import calls, mixed multi-value results, canonical function identity,
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

The focused WebAssembly unit suite passes 159/159 at `4c61bd90`, covering the
decoder, validator, executor, JS API, store growth, linking, function calls,
traps, imported/defined identity, precise-GC retention, stable asynchronous
compilation inputs, Promise timing, overload result shapes, and rejection
classes, the opt-in Core 2.0 numeric and multi-value operations, tagged
funcref/externref invocation and global slots, balanced root publication across
return/checkpoint/trap paths, reference-valued JS/Wasm calls, explicit
multi-table operations, cross-instance indirect calls, and the test-only
bit-exact corpus boundary, plus DataCount, every active/passive/declarative
segment encoding, bulk memory/table operations, overlap and zero-length bounds,
dropped-segment state, host-visible table synchronization, and precise-GC
barriers. The strengthened cross-instance bulk-table witness passes its focused
3/3 filter at `66237d21`. The separately recorded no-GIL filter passes
3/3 at `d2fca189` and proves a completed parallel mid-script collection retains
an externref held only by a frozen Wasm
frame, then reclaims it after that frame unregisters. The most recent batched
full engine checkpoint passes 1,002/1,002 at `af689c4a`. All recorded runs report zero
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

### Core 2 structural profile

The checked-in [Core 2 structural inventory](.data/wasm-core-2-structural-inventory.json)
pins `WebAssembly/spec` tag `wg-2.0` at
`fffc6e12fa454e475455a7b58d3b5dc343980c10` and WABT 1.0.39 at
`ad75c5edcdff96d73c245b57fbc07607aaca9f95`. At engine checkpoint
`a593fdea`, every applicable binary-runtime command passes across all 90 core
files: **27,437/27,437 pass, 0 fail, and 0 runner errors**. The inventory
accounts for all 28,018 commands: 25,350 use the public JavaScript API, 2,087
exact float payload/sign commands use the test-only bit-exact path, and 581
text-format parser commands are explicitly non-applicable to the binary API.

The file-area accounting is deliberately visible rather than hidden behind one
headline:

| Area | Pass | Text-format n/a | Total |
| --- | ---: | ---: | ---: |
| Shared core | 17,628 | 491 | 18,119 |
| Numeric extensions | 619 | 0 | 619 |
| Multi-value control | 1,553 | 90 | 1,643 |
| Reference types | 222 | 0 | 222 |
| Bulk memory/table | 7,415 | 0 | 7,415 |
| **All 90 files** | **27,437** | **581** | **28,018** |

Reproduce the complete score with exact checkouts (or equivalent paths to
those exact commits):

```sh
git clone https://github.com/WebAssembly/spec.git /tmp/wasm-core-2
git -C /tmp/wasm-core-2 checkout fffc6e12fa454e475455a7b58d3b5dc343980c10
# Install/build WABT 1.0.39 commit ad75c5edcdff96d73c245b57fbc07607aaca9f95.
zig build wasm-spec-eval
python3 tools/wasm-spec.py \
  --profile core-2-structural \
  --spec-root /tmp/wasm-core-2 \
  --wast2json /path/to/wabt-1.0.39/wast2json
```

The profile defaults to a bounded 600-second per-file evaluator timeout because
the official `memory_copy.wast` script alone contains 4,450 passing commands.
CI keeps exact pin/version drift and representative behavior gated with 426
applicable commands from `imports.wast`, `memory_init.wast`, `ref_func.wast`,
and `unreached-valid.wast`, without rerunning that complete long-tail file on
every push.

## Beyond the MVP

The corpus evaluator keeps the standards-facing JavaScript API unchanged while
using a test-only Context hook for NaN payload/sign assertions that JavaScript
`Number` cannot represent bit-exactly. This makes the full MVP binary-runtime
score auditable without exposing a non-standard WebAssembly method to embedders.

Post-Core-2 feature profiles are tracked separately by
[issue #142](https://github.com/zig-utils/zig-js/issues/142), and PR-249
WebAssembly/JIT shell hooks by
[issue #143](https://github.com/zig-utils/zig-js/issues/143).

The machine-readable [feature registry](.data/wasm-feature-profiles.json) pins
the official proposal tracker and 12 selected proposal repositories by exact
commit. It distinguishes finished WebAssembly 2.0/3.0 features from the active
Phase-4 Threads proposal, declares dependency closure and host constraints, and
keeps MVP as the only default complete profile until all features in a named
post-MVP profile are implemented. Validate registry drift with:

```sh
zig build wasm-feature-profiles-check
```

The fixed-width-SIMD foundation additionally checks in an exact
[236-opcode inventory](.data/wasm-simd-opcodes.json) from the already-pinned
`WebAssembly/simd` revision. Its verifier locks the 56-file corpus count,
subopcode/name pairs, reserved holes, and immediate shapes to the runtime enum.
The decoder and validator cover v128 signatures, locals, globals, constants,
all six immediate forms, lane/shuffle bounds, memory alignment, and stack
signatures across the complete inventory. A distinct `u128` execution slot and
test-only raw-lane boundary preserve every bit; ordinary JavaScript function
and Global access rejects opaque v128 values with `TypeError`. This foundation
is complete in [#279](https://github.com/zig-utils/zig-js/issues/279); execution
families and terminal corpus/performance evidence remain tracked by
[#280](https://github.com/zig-utils/zig-js/issues/280) through
[#283](https://github.com/zig-utils/zig-js/issues/283).

The same driver exposes a `simd-movement` profile over a declared 20-file
selection from the pinned 56-file proposal corpus. At engine checkpoint
`6306ed59`, all 2,253 applicable commands pass, with zero failures, 351
text-format assertions explicitly marked not applicable, and zero runner
errors. The checked-in [2,604-command inventory](.data/wasm-simd-movement-inventory.json)
records every address/alignment, bitwise/boolean, constant, lane, load/store,
splat, and contextual integer/float result without hidden exclusions.
Reproduce the terminal score with:

```sh
zig build wasm-spec-eval
python3 tools/wasm-spec.py \
  --profile simd-movement \
  --spec-root /path/to/WebAssembly-simd-a78b98a \
  --wast2json /path/to/wabt-1.0.39/wast2json \
  --inventory docs/.data/wasm-simd-movement-inventory.json
```

The architecture-independent integer fallback is also complete at `08e29a5f`.
Across 24 focused proposal files, all 4,380 applicable commands pass with zero
failures, 65 explicit text-format n/a, and zero runner errors. That score covers
all integer comparisons/reductions, shifts, wrapping and saturating arithmetic,
min/max/average, narrowing, low/high signed and unsigned extension, pairwise
extension-add, every extmul width, dot product, and q15 rounded saturation. No
native SIMD acceleration exists yet, so the portable implementation is both the
runtime path and the scalar oracle for future lane-by-lane differential checks.

The portable floating-point implementation is complete at `b5a9876a`. Across
13 focused proposal files, all 19,106 applicable commands pass with zero
failures, 98 explicit text-format n/a, and zero runner errors. This includes
comparisons, arithmetic, exact abs/neg payload transforms, sqrt and every
rounding mode, min/max and pseudo-min/max, promote/demote, saturating
float-to-integer conversions, integer-to-float conversions, signed-zero
preservation, and specification-permitted canonical/arithmetic NaN matching.
The ReleaseFast evaluator is used for the two 3,887-command pseudo-min/max files;
the runtime remains the same architecture-independent scalar oracle.

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
`nontrapping_float_to_int` switches, and multi-result functions and type-index
control signatures are implemented behind `multi_value`. DataCount, passive and
declarative segments, and `memory.init`/`data.drop`/`memory.copy`/`memory.fill`/
`table.init`/`elem.drop`/`table.copy` are implemented behind `bulk_memory`. They decode,
validate, instantiate, and execute through the public JavaScript API.
Multi-value exports return ordered JavaScript arrays; imports consume general
iterables and require the exact result arity. No post-MVP switch is enabled by
default. Together these switches form the structurally complete, independently
scored Core 2 profile above; SIMD, Threads, exceptions/tail calls, memory64/GC,
and shell-only hooks remain separate profiles.

The reference-types runtime foundation uses explicitly tagged numeric,
funcref, and externref slots. Active operand stacks, locals, arguments, results,
and globals participate in ordinary and parallel precise-GC publication without
permanently rooting dead externrefs. The feature-gated binary and validator now
cover reference value positions, typed select, `ref.*`, explicit table indices,
multiple typed tables, and `table.get/set/grow/size/fill`; the interpreter
executes tagged funcref and arbitrary externref tables. JavaScript externref
Table and Global values preserve identity through get/set/grow and precise GC,
then reclaim exactly after overwrite. Reference-valued exports and imports
preserve arbitrary externref identity and canonical funcref identity, including
mixed multi-value results. Explicit table indices select the intended table for
get/grow/fill and cross-instance indirect calls. This reference-types slice was
completed in [#275](https://github.com/zig-utils/zig-js/issues/275).

Bulk memory uses explicit per-instance passive-segment state. Active segments
are applied in declaration order: each segment is bounds-atomic, while writes
from completed earlier segments remain visible if a later segment traps, as
Core 2 requires. Declarative and active segments are dropped at instantiation,
and passive segments retain/drop exactly. Memory and
table copies use memmove overlap semantics, preflight both source and destination
bounds, and keep zero-length-at-end behavior exact. Wasm table writes and grows
synchronize JavaScript Table mirrors immediately, preserving cross-instance
funcref identity and externref precise-GC roots. This slice was completed in
[#272](https://github.com/zig-utils/zig-js/issues/272).

Implementation is split into the shared gating foundation
[#262](https://github.com/zig-utils/zig-js/issues/262), the Core 2.0 numeric
operations [#269](https://github.com/zig-utils/zig-js/issues/269), the structural core 2.0 baseline
[#263](https://github.com/zig-utils/zig-js/issues/263), including multi-value
[#270](https://github.com/zig-utils/zig-js/issues/270), reference types
[#271](https://github.com/zig-utils/zig-js/issues/271), bulk memory
[#272](https://github.com/zig-utils/zig-js/issues/272), and its exact score
[#273](https://github.com/zig-utils/zig-js/issues/273); SIMD is tracked in
[#264](https://github.com/zig-utils/zig-js/issues/264), Threads
[#265](https://github.com/zig-utils/zig-js/issues/265), exceptions/tail calls
[#266](https://github.com/zig-utils/zig-js/issues/266), memory64/GC
[#267](https://github.com/zig-utils/zig-js/issues/267), and the final profile
conformance matrix [#268](https://github.com/zig-utils/zig-js/issues/268).
