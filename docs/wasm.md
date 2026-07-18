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

Reproduce the deliberate complete corpus run with the live-WABT evaluator
(WABT 1.0.12 at the pinned commit above, plus a `WebAssembly/spec` checkout at
the pinned commit — the initialized `wasm-spec` submodule is the default
`--spec-root`):

```sh
zig build wasm-spec-eval
python3 tools/wasm-spec.py --profile mvp \
  --spec-root /path/to/WebAssembly-spec \
  --wast2json /path/to/wabt-1.0.12/wast2json
```

The packed native runner executes the same pinned corpus from checked-in
artifacts with no converter at run time (see [wasm-spec.md](wasm-spec.md)):

```sh
zig build wasm-spec
```

CI runs bounded `linking.wast` and `f32_bitwise.wast` smoke/drift gates through
the packed runner. Together they execute all 114 applicable linking/store
commands and 348 of 364 f32 bit-exact cases (the remaining NaN-pattern cases
are classified skips covered by the evaluator's raw-bit path) without putting
the multi-minute complete inventory on every push.

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

The tail-call binary and validation foundation is pinned independently to
`WebAssembly/tail-call@a6003d06aefef41e20a3e36fe2e500062555c895`. Its
[machine-readable inventory](.data/wasm-tail-call-opcodes.json) locks both
opcodes, binary field order, stack-polymorphic signatures, validation rules,
and the two proposal corpus files with all 119 top-level commands. Behind the
`tail_calls` switch, `return_call` and `return_call_indirect` decode with exact
byte-offset failures and validate direct/indirect indices, `funcref` tables,
operand types, unreachable-polymorphic stacks, and exact current-function
result compatibility. This foundation is tracked by
[#288](https://github.com/zig-utils/zig-js/issues/288). Frame-replacing bounded
execution is the next isolated slice in
[#289](https://github.com/zig-utils/zig-js/issues/289); this foundation does not
claim the proposal execution corpus yet.

The fixed-width-SIMD foundation additionally checks in an exact
[236-opcode inventory](.data/wasm-simd-opcodes.json) from the already-pinned
`WebAssembly/simd` revision. Its verifier locks the 56-file corpus count,
subopcode/name pairs, reserved holes, and immediate shapes to the runtime enum.
The decoder and validator cover v128 signatures, locals, globals, constants,
all six immediate forms, lane/shuffle bounds, memory alignment, and stack
signatures across the complete inventory. A distinct `u128` execution slot and
test-only raw-lane boundary preserve every bit; ordinary JavaScript function
and Global access rejects opaque v128 values with `TypeError`. This foundation
and every execution family are complete in
[#279](https://github.com/zig-utils/zig-js/issues/279) through
[#282](https://github.com/zig-utils/zig-js/issues/282); terminal corpus and
performance evidence are recorded by
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

### Complete fixed-width SIMD profile

The terminal `simd` profile scores every command in all 56 files at the exact
pinned `WebAssembly/simd` revision
`a78b98a6899c9e91a13095e560767af6e99d98fd`. At engine checkpoint `9c7288bf`,
all **25,466 / 25,466 applicable commands pass**, with zero failures, zero
runner errors, and 510 text-format parser assertions explicitly classified as
not applicable to the binary JavaScript API. The checked-in
[25,976-command inventory](.data/wasm-simd-inventory.json) retains every file,
line, command type, execution mode, exact vector-bit comparison, and
specification-permitted NaN policy. There are no hidden skips, exclusions, or
timeouts.

Reproduce the complete score with the exact proposal checkout and WABT 1.0.39:

```sh
zig build wasm-spec-eval -Doptimize=ReleaseFast
python3 tools/wasm-spec.py \
  --profile simd \
  --spec-root /path/to/WebAssembly-simd-a78b98a \
  --wast2json /path/to/wabt-1.0.39/wast2json \
  --inventory docs/.data/wasm-simd-inventory.json
```

Ordinary CI keeps this bounded: exact-pin witnesses run
`simd_i32x4_arith2.wast`, `simd_f32x4_rounding.wast`, `simd_lane.wast`, and
`simd_load.wast`. The deliberate command above owns the complete 56-file score.
The registry checker locks both the terminal totals and the four explicit
execution modes so a corpus, engine, or documentation change cannot silently
weaken the claim.

The implementation has no target-architecture branches. Every architecture
that can build zig-js uses the same portable `u128` slot and lane-by-lane
integer, floating, shuffle, and memory semantics; there is no unsupported-target
fallback gap and no claim of native SIMD intrinsic lowering. This is the
committed fallback behavior until an architecture-specific fast path lands, at
which point the portable path remains the semantic oracle.

Performance is recorded separately from conformance. The
[July 18, 2026 report](.data/wasm-simd-benchmark-2026-07-18.md) and its
[224 raw samples](.data/wasm-simd-benchmark-2026-07-18.tsv) compare integer,
float, shuffle, and memory kernels against scalar exports from the exact same
module and against macOS system JavaScriptCore. At eight warmed independent
contexts, zig-js reaches 28.35, 27.66, 29.00, and 41.13 million logical vector
updates per second respectively, scaling 3.67x–4.58x over one context. System
JSC reaches 280.32, 283.33, 286.75, and 291.96 M/s. These direct numbers are
published rather than hidden by one aggregate; the report records timing
boundaries, dispersion, checksums, environment, exact module hash, and full
reproduction.

### WebAssembly Threads foundation

The Phase-4 Threads proposal is pinned separately at
`WebAssembly/threads@979d0fcb994439423d63b2f0a8a7332d6285dd84`. Its checked-in
[67-opcode inventory](.data/wasm-atomic-opcodes.json) records the complete
`0xfe` surface from `memory.atomic.notify` through
`i64.atomic.rmw32.cmpxchg_u`, the reserved `0x04–0x0f` gap, all immediate
forms, natural alignments, stack shapes, and the exact 13-file proposal corpus.
The registry verifier compares that inventory directly with
[`src/wasm/atomic.zig`](../src/wasm/atomic.zig).

At checkpoint `040d0c00`, shared memory flags decode only when the `threads`
feature is selected, the validator requires every shared memory to declare a
maximum, atomic memory instructions require exact natural alignment, and all 67
instructions have proposal-exact operand/result signatures. Atomic fence keeps
its specified zero reserved byte and remains valid without a memory. Atomic
access and notify are valid on ordinary memories; wait-on-unshared is correctly
reserved for a runtime trap rather than misclassified as a validation failure.

At checkpoint `a62e0c55`, the shared-memory host boundary is complete.
`MemoryInst` owns either an ordinary allocation or a refcounted stable shared
slab reserved to the declared maximum. Shared growth is serialized and
failure-atomic, does not move the slab, and returns unique previous page counts
to racing callers. The JavaScript descriptor reads `initial`, `maximum`, then
`shared`; shared memories require a maximum and link only to shared imports.

The `Memory.buffer` contract follows the pinned Threads JS API rather than
growable-SAB shortcuts: every successful grow publishes a new fixed-length
`SharedArrayBuffer`, while historical buffers retain their old byte length,
never detach, and alias the same data block. Wrapper references and the native
memory owner independently retain the slab, so Context/registry/GC teardown
cannot free bytes still held by another realm. Structured-clone wire version 2
also carries each SAB wrapper's fixed/growable view metadata, preserving the
same semantics through isolated Workers without serializing a store or native
Memory owner.

Focused witnesses cover eight racing native grows, constructor evaluation and
error order, defined/exported/imported identity and sharedness mismatch,
historical-buffer aliasing, precise ownership after native owner destruction,
a real shared-realm `Thread`, and an isolated `Worker` that mutates an old
64-KiB view after the live memory has grown to 128 KiB. The batched WebAssembly
suite passes 176/176, Worker filters pass 33/33, and structured-clone filters
pass 11/11 at this checkpoint, all with zero failures, skips, or leaks.

At checkpoint `f5cc0f7a`, the executable atomic foundation is complete. All
widths of atomic load/store, add/sub/and/or/xor/exchange, compare-exchange, and
fence use hardware SeqCst operations. `memory.atomic.wait32`, `wait64`, and
`notify` share the engine's FIFO waiter domains, implement exact result codes,
signed nanosecond timeout conversion, alignment/bounds checks, the unshared
wait trap, and notify-on-unshared behavior. Blocking calls release the optional
context GIL, publish parked native-stack roots, and use targeted stop predicates
so Worker/Context termination interrupts only its own waiters.

Ordinary accesses to shared storage are also host-race-free without changing
the language memory model. ECMAScript's no-tear integer TypedArrays use one
monotonic width-sized event. DataView, floating/BigInt unordered access, Wasm
scalar/SIMD loads and stores, and bulk memory use monotonic byte events, retaining
their permitted multi-byte tearing while remaining clean under TSan when they
overlap an atomic instruction. Bounds are checked before any scalar, SIMD, or
bulk mutation, and shared growth never relocates an active address.

The exact pinned `threads/atomic.wast` path passes 372/372 with zero failures,
not-applicable commands, or runner errors. The complete unit root passes
1,069/1,069 with zero skips, failures, or leaks; the focused overlapping
ordinary/atomic TSan run passes 4/4. Those witnesses include eight no-GIL
Threads incrementing one Wasm counter, JS `Atomics`/Wasm differential access,
real cross-thread wait/notify, mismatch and timeout behavior, Worker termination,
waiter interruption/unlink, and a waiter surviving shared growth plus native
Memory-owner destruction.

At checkpoint `d8319174`, the proposal script layer is complete too. The runner
parses WAST S-expressions while preserving exact source spans and lines, handles
strings plus nested comments, delegates ordinary commands to pinned WABT, and
recursively lowers `(thread ...)`, `(shared (module ...))`, and `(wait ...)`.
Child command reports merge at their upstream wait positions, `either` results
retain their proposal meaning, and shared module instances cross Thread
boundaries by identity. The evaluator deliberately selects zig-js's
production-default true-parallel no-GIL configuration; serialized `.gil = true`
contexts still hand off the legacy GIL at Wasm backedges under contention.

The checked-in [complete Threads inventory](.data/wasm-threads-inventory.json)
pins `WebAssembly/threads@979d0fcb994439423d63b2f0a8a7332d6285dd84`
and WABT 1.0.39 commit
`ad75c5edcdff96d73c245b57fbc07607aaca9f95`. All **551 / 551 commands**
pass across all 13 files, with zero failures, zero not-applicable commands, and
zero runner errors: 493 commands execute through the JavaScript API, 29 are
proposal thread directives, and 29 are proposal waits. This includes all six
ordinary/atomic LB, MP, and SB litmus files, recursive/deep nesting, shared
registration, unlinkable imports, the real wait/notify loop, and all 372 atomic
commands. There are no hidden exclusions or timing sleeps.

Reproduce that terminal corpus score with exact checkouts:

```sh
git clone https://github.com/WebAssembly/threads.git /tmp/wasm-threads
git -C /tmp/wasm-threads checkout 979d0fcb994439423d63b2f0a8a7332d6285dd84
# Install/build WABT 1.0.39 commit ad75c5edcdff96d73c245b57fbc07607aaca9f95.
zig build wasm-spec-eval
python3 tools/wasm-spec.py \
  --profile threads \
  --spec-root /tmp/wasm-threads \
  --wast2json /path/to/wabt-1.0.39/wast2json \
  --inventory docs/.data/wasm-threads-inventory.json
```

Ordinary CI pins the same source/tool revisions and runs parser regressions plus
`simple.wast`, `deeply_nested.wast`, and `wait_notify.wast`; the deliberate
command above owns the complete score. The remaining full TSan matrix and
supported-host stress evidence are tracked by
[#287](https://github.com/zig-utils/zig-js/issues/287). Parent
[#265](https://github.com/zig-utils/zig-js/issues/265) closes only after that
evidence lands.

Performance is published separately from conformance. The
[July 18, 2026 Threads report](.data/wasm-threads-benchmark-2026-07-18.md) and
its [105 raw timing samples](.data/wasm-threads-benchmark-2026-07-18.tsv) were
generated from clean benchmark commit `eb43a2f9` on an 11-core Apple M3 Pro.
They run the same fixed shared-memory module at one owner thread and 2/4/8
no-GIL shared-realm workers. All atomic medians exceed 50 ms, each row has seven
samples, and the harness validates exact final counts, monotonic wait/notify
generations, zero timeouts, and a per-process watchdog.
This dated performance support boundary is macOS arm64; the artifact makes no
Linux or x86 throughput claim, and portable correctness/sanitizer hosts remain
separate evidence.

At checkpoint `87c0f0f8`, the exact checked-in benchmark module has a focused
repeat-lifecycle gate of its own. Five no-GIL GC contexts each execute four
rounds of contended add, CAS, disjoint atomics, and paired wait/notify before
teardown. Both the ordinary and ThreadSanitizer runs pass 3/3 tests with zero
skips, failures, leaks, or reported races. This is the local macOS arm64
sanitizer witness; the wider supported-host matrix remains the final #287 gate.

| workers | contended add | contended CAS | disjoint add | pair handoffs/s |
| ---: | ---: | ---: | ---: | ---: |
| 1 | 14.56 M/s | 8.81 M/s | 13.87 M/s | — |
| 2 | 19.19 M/s | 7.22 M/s | 19.31 M/s | 259,476 |
| 4 | 18.88 M/s | 6.18 M/s | 19.87 M/s | 1,067,241 |
| 8 | 17.23 M/s | 4.74 M/s | 17.28 M/s | 287,444 |

Multi-worker timing includes `Thread` construction, dispatch, joins, and final
validation; the detailed report publishes medians, scaling, RSD, exact job
counts, module hash, ownership boundaries, tool pins, and reproduction. The
system JavaScriptCore public embedding context exposes `WebAssembly` but not
`SharedArrayBuffer`, rejects the shared-memory atomic module, and has no
shared-realm worker API. There is therefore no equivalent JSC Threads score;
the report records `N/A` and points to the ordinary-JavaScript and SIMD panels
where the two public APIs do expose equivalent concurrency.

Reproduce the full or reduced benchmark matrix with:

```sh
zig build wasm-threads-benchmark -Doptimize=ReleaseFast
zig build wasm-threads-benchmark \
  -Doptimize=ReleaseFast \
  -Dwasm-threads-benchmark-quick=true
```

Zig embedders opt into an exact feature set per realm; module bytes never
self-enable proposals. Invalid dependency sets fail during Context creation.
A selected feature with no landed binary foundation produces a deterministic
`WebAssembly.CompileError` identifying it; the explicitly documented Threads
profile above decodes, validates, embeds, and executes its atomic instruction
surface:

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
scored Core 2 profile above; SIMD, Threads, exception handling, tail-call
execution, memory64/GC, and shell-only hooks remain separate profiles.

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
