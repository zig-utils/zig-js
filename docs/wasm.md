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
the pinned commit — the initialized `wasm-spec-wg1` submodule is the intentionally
MVP-only default `--spec-root`, not a checkout of upstream `main`):

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
The stable Core 3 corpus is a separate `wasm-spec-wg3` submodule pinned to
official tag `wg-3.0` at
`9d36019973201a19f9c9ebb0f10828b2fe2374aa`. It never changes the frozen
WG-1.0 baseline. Run the deliberate complete profile with pinned
`wasm-tools` 1.253.0:

```sh
git submodule update --init wasm-spec-wg3
zig build wasm-core-3 -Dwasm-core-3-converter=/path/to/wasm-tools
```

The terminal profile declares all 258 integrated Core 3 `.wast` files and
records every command. Typed function references
[#384](https://github.com/zig-utils/zig-js/issues/384), explicit exception
references [#385](https://github.com/zig-utils/zig-js/issues/385), and relaxed
SIMD [#386](https://github.com/zig-utils/zig-js/issues/386) are complete under
[#366](https://github.com/zig-utils/zig-js/issues/366).

Upstream `main` is a separate, non-release shadow profile. The current
observation pins `d7b37e4170d8315f2f1283aed4e8076591a9a333`: all 21 files changed
from WG3 pass 3,368/3,368 applicable commands, and the complete 258-file
snapshot passes **64,055/64,055 applicable commands**, with 1,235 explained
binary-API N/A commands and no failures or runner errors. See the exact
[changed-file inventory](.data/wasm-core-main-shadow-changed-inventory.json),
[complete inventory](.data/wasm-core-main-shadow-inventory.json), and
[tree diff](.data/wasm-core-3-upstream-drift.json).

Run the pinned observation from a detached checkout that contains both the
shadow and WG3 commits:

```sh
zig build wasm-core-main-shadow \
  -Dwasm-core-main-shadow-root=/path/to/spec-at-d7b37e4 \
  -Dwasm-core-main-shadow-converter=/path/to/wasm-tools
# Add -Dwasm-core-main-shadow-changed-only=true for the 21-file slice.
```

This never advances either submodule or changes the accepted WG1/WG3 scores.
The checked-in inventory records the complete exact changed-file slice. CI
keeps the shadow runtime gate bounded with the changed `binary-leb128.wast`
witness, while a network-tolerant drift step reports newer upstream commits for
the next deliberate observation.

The accepted ReleaseFast audit reaches **63,964 / 63,964 applicable commands**
with 1,235 binary-API-inapplicable text-format commands, zero failures, and zero
runner errors. The exact 258-file result is checked in as the
[Core 3 inventory](.data/wasm-core-3-inventory.json).

The machine-readable [feature registry](.data/wasm-feature-profiles.json) pins
the official proposal tracker and 14 selected proposal/spec revisions by exact
commit. It distinguishes finished WebAssembly 2.0/3.0 features from the active
Phase-4 Threads proposal, declares dependency closure and host constraints, and
keeps MVP as the only default while recording every named profile as
implemented. Validate registry drift with:

```sh
zig build wasm-feature-profiles-check
```

The generated [terminal conformance matrix](.data/wasm-conformance-matrix.json)
combines all ten scored profiles: **151,802/151,802 applicable commands pass**,
with 2,862 explicit N/A and zero failures or runner errors. It records each
inventory, proposal pin, converter, execution-mode counts, host requirements,
and architecture-independent interpreter scope. The same CI command above
rejects matrix drift; regenerate intentional inventory changes with
`python3 tools/wasm-conformance-matrix.py --write`.

CI also rebuilds exact proposal checkouts and converters for every profile.
Bounded smoke slices cover every post-MVP family; the deliberate complete
commands remain authoritative and keep long-tail corpus work off every push.

The tail-call binary, validation, and bounded execution foundation is pinned
independently to
`WebAssembly/tail-call@a6003d06aefef41e20a3e36fe2e500062555c895`. Its
[machine-readable inventory](.data/wasm-tail-call-opcodes.json) locks both
opcodes, binary field order, stack-polymorphic signatures, validation rules,
and the two proposal corpus files with all 119 top-level commands. Behind the
`tail_calls` switch, `return_call` and `return_call_indirect` decode with exact
byte-offset failures and validate direct/indirect indices, `funcref` tables,
operand types, unreachable-polymorphic stacks, and current-function result
subtyping. Direct and indirect dispatch replaces the active frame
while retaining its caller-facing stack, local, and label bases; tail calls to
host imports retire that same frame after exact argument/result checks. Focused
coverage proves a 200,000-call mutual recursion stays below 64 slots of capacity,
preserves nested callers and cross-instance funcref identity, retains live
externref/funcref parameters and locals at every replacement checkpoint, and
keeps both successful and trapping host-import boundaries precisely rooted.
The public JavaScript API also performs 33 repeated deep invocations to cover
per-call arena/frame teardown. Normal and ThreadSanitizer focused runs pass with
zero failures, leaks, or reported races.

Core 3 typed function calls extend that foundation with `call_ref` (`0x14`)
and `return_call_ref` (`0x15`). Validation consumes a nullable concrete
function reference after the call arguments, applies nominal reference
subtyping, and checks covariant tail results. Execution traps null references,
checks canonical function types across instances, and preserves typed function
slots through module-aware initialization and GC root checkpoints. The exact
`wg-3.0` corpus passes all 35 `call_ref.wast` and all 51
`return_call_ref.wast` commands, including million-step tail recursion. CI
runs both exact files in the shared pinned wasm-tools smoke leg.

Core 3 exception references add the disjoint `exn`/`noexn` heap hierarchy,
including `exnref`, `nullexnref`, `(ref exn)`, and `(ref null exn)` forms.
Catch branches validate payload and exception-reference subtyping, runtime
slots preserve exception identity and precise payload roots, and JavaScript
boundaries reuse canonical `WebAssembly.Exception` wrappers. Tag imports also
retain nominal recursive type identity. All 98 applicable commands in the
four-file `test/core/exceptions` directory pass; the remaining two commands
are text-parser assertions that the binary-backed runner records as N/A.

Core 3 relaxed SIMD adds all 20 `0xfd` subopcodes from `0x100` through `0x113`
behind the explicit `relaxed_simd` feature and its fixed-width-SIMD dependency.
The portable interpreter makes one stable spec-permitted choice for swizzle,
saturating truncation, lane selection, fused multiply-add, min/max, q15
multiplication, and dot products. The evaluator accepts only the alternatives
encoded by the corpus, including bit-precise vector and NaN policies. All
**77 / 77** commands in the seven exact `test/core/relaxed-simd` files pass,
with zero failures, N/A cases, or runner errors. The
[machine-readable opcode inventory](.data/wasm-relaxed-simd-opcodes.json) and
CI pin the exact `wg-3.0` source revision.

Reproduce the complete relaxed-SIMD slice with:

```sh
zig build wasm-core-3 \
  -Dwasm-core-3-converter=/path/to/wasm-tools-1.253.0/wasm-tools \
  -Dwasm-core-3-filter=test/core/relaxed-simd/
```

Core 3 extended constant expressions allow wrapping `i32`/`i64` add, subtract,
and multiply in global initializers and active data/element offsets, including
nested reads of earlier immutable globals. The shared decoder retains the full
instruction sequence, validation applies ordinary typed-stack rules plus the
constant-expression whitelist, and instantiation evaluates it without exposing
the runtime operand stack. `data.wast` passes 65/65 and `global.wast` passes all
121 applicable commands (3 text-only N/A); all extended-expression cases in
`elem.wast` pass, leaving only #389's five unrelated subtyping assertions.

Core 3 reference refinement accepts a nullable branch label when
`br_on_non_null` carries its non-null subtype, while preserving the nullable
fallthrough and unreachable-polymorphic rules. Explicit typed `select` results
also validate concrete heap indices even when operands are unreachable. The
exact `br_on_non_null.wast` and `ref.wast` files pass 12/12 and 13/13.

Legacy function-index element segments decode to their exact non-null
`(ref func)` type, so they can initialize non-null tables. Cross-instance
immutable global imports are covariant through canonical recursive type
identity; mutable imports remain invariant. The exact `elem.wast` and
`linking.wast` files pass 151/151 and 163/163.

Reproduce those execution and root-safety witnesses with:

```sh
zig build test -Dtest-filter='wasm.exec tail'
zig build test -Dtest-filter='bounded tail recursion'
zig build test -Dtsan=true -Dtest-filter='wasm.exec tail'
zig build test -Dtsan=true -Dtest-filter='bounded tail recursion'
```

Binary/validation is tracked by [#288](https://github.com/zig-utils/zig-js/issues/288)
and frame replacement/root safety by
[#289](https://github.com/zig-utils/zig-js/issues/289). The
[terminal command inventory](.data/wasm-tail-call-inventory.json) records every
command in both declared proposal files. All 108 applicable commands pass; the
remaining 11 of 119 are `assert_malformed` text-parser assertions, recorded
individually as not applicable because the JavaScript API accepts binary
modules only. There are no failures or runner errors.

The exception-handling foundation is pinned independently to
`WebAssembly/exception-handling@af287a73d8f3bf7ea216c10592f9e350b947c4f2`.
Its [machine-readable binary inventory](.data/wasm-exception-handling-opcodes.json)
locks the finished proposal's `exnref` value type, tag section and external
kind, `throw`, `throw_ref`, and `try_table` instructions, and the four ordered
catch-clause encodings with exact immediate fields. It also inventories 86
top-level commands across `tag.wast`, `throw.wast`, `throw_ref.wast`, and
`try_table.wast`, including each command and source-surface occurrence count.
This deliberately excludes the obsolete legacy try/catch/rethrow/delegate
encoding. Run `zig build wasm-feature-profiles-check` to verify the proposal
pin, inventory facts, and implemented tag surface. With the feature enabled,
tag declarations and section order decode exactly, imported and defined tag
types validate, tag imports preserve store identity, definitions allocate
distinct identities, and failed instantiation tears down every partially
created tag. The core linker checks exact payload types, while Module
import/export reflection exposes the standard `tag` kind.

The core exception runtime is complete at `979bb195`. `exnref`, `throw`,
`throw_ref`, `try_table`, and every catch form decode and validate against the
pinned rules. Runtime handlers match store tag identity, unwind nested blocks
and ordinary calls, disappear correctly across tail-frame replacement, and do
not intercept traps. Payload slots retain exact integer and NaN bits plus
externref identity; `catch_ref` and `catch_all_ref` preserve the same exception
record across `throw_ref` and later invocations. Dropped temporary references
are reclaimed when an invocation ends. Escaped records publish through an
atomic per-instance list whose flattened reference roots are visible both to
active execution checkpoints and ordinary object tracing.

Focused normal and ThreadSanitizer runs each pass all 8 executor tests with 0
failures, skips, leaks, or reported races. They include 512 nested handlers,
eight concurrent publishers, exhaustive allocation-failure injection, null
`throw_ref`, uncaught propagation, cross-call and cross-invocation rethrows,
tail-call handler removal, and trap bypass. The focused binary/validation and
GC-root witnesses pass 4/4 and 3/3 respectively.

The JavaScript boundary completed in
[#291](https://github.com/zig-utils/zig-js/issues/291). `WebAssembly.Tag`
accepts the Web IDL sequence descriptor with iterator-close and observable
conversion order, `Tag.prototype.type()` returns a fresh descriptor, and the
store owns one stable `WebAssembly.JSTag`. `WebAssembly.Exception` converts a
typed payload, exposes branded `is()` and `getArg()` methods, accepts the
proposal's `traceStack` option, and deliberately returns `undefined` from its
optional `stack` accessor because this engine does not capture a stack trace.
Constructor metadata, prototypes, descriptors, subclassing, receiver checks,
arity, range errors, and cross-store rejection are covered explicitly.

Imported tags retain their JavaScript identity; defined exports cache one
wrapper per tag; callbacks, catches, `throw_ref`, rethrows, tail calls, async
start rejection, and cross-instance transfers retain the same exception record
where the proposal requires it. An arbitrary JavaScript value thrown by an
imported callback is transported with `JSTag`, including `undefined`, while
engine traps, stack exhaustion, and allocation failure remain uncatchable.
Published wrappers and payload references are precise-GC roots, and failed
construction or instantiation releases each partially owned record exactly
once. Concurrent native-wrapper publication is atomic.

The broad JavaScript API run passes 34/34 tests with no failures, skips, or
leaks. A focused ThreadSanitizer transport run passes 3/3 with no race or leak,
and the executor's normal and ThreadSanitizer runs remain 8/8. The public API
differential compares 10 equivalent surface, descriptor, construction,
identity, error, iteration-order, and subclassing rows against macOS system
JavaScriptCore 22625.1.20.11.3; all rows match with digest
`1bb603912329d2e7`. The
[terminal command inventory](.data/wasm-exception-handling-inventory.json)
records every command in all four declared proposal files. All 84 applicable
commands pass; the remaining 2 of 86 are the same explicitly identified
text-only `assert_malformed` boundary. There are no failures or runner errors.

Together the terminal profiles account for all 205 declared commands: 192
public-JavaScript-API passes and 13 explicit text-parser N/A results. The
inventory schema records every command's file, source line, type, execution
mode, status, and detail. `zig build wasm-feature-profiles-check` verifies the
proposal and WABT pins, exact declared-file sets, per-file totals, every command
mode, and the only permitted N/A reason on ordinary CI without rerunning the
complete corpora. The complete score was produced on macOS arm64; the binary
decoder, validator, and portable executor have no architecture-specific path,
while the ordinary Linux CI unit and ThreadSanitizer suites remain the
cross-host behavior gates. This is not a claim that the complete upstream
corpora are rerun on every host or every push.

Reproduce the focused tag ownership and failure-atomicity witness with:

```sh
zig build test -Dtest-filter='exception tag'
zig build test -Dtest-filter='modern exception'
zig build test -Dtest-filter='wasm.exec exception'
zig build test -Dtsan=true -Dtest-filter='wasm.exec exception'
zig build test -Dtest-filter='exception-payload WebAssembly roots'
zig build test -Dtest-filter='wasm api'
zig build test -Dtsan=true -Dtest-filter='wasm api transports typed exceptions'
zig build wasm-exception-jsc-diff
```

Reproduce the complete proposal scores with WABT 1.0.39 at
`ad75c5edcdff96d73c245b57fbc07607aaca9f95`, proposal checkouts at the exact
revisions named above, and these deliberate full-run commands:

```sh
zig build wasm-spec-eval
python3 tools/wasm-spec.py --profile tail-calls \
  --spec-root /path/to/tail-call --wast2json /path/to/wast2json
python3 tools/wasm-spec.py --profile exception-handling \
  --spec-root /path/to/exception-handling --wast2json /path/to/wast2json
zig build wasm-feature-profiles-check
```

### Multi-memory terminal profile

The finished Wasm 3.0 multi-memory proposal is pinned independently at
`WebAssembly/multi-memory@cf8b5aa27257311b8eac80ae83f4ba22ee308064`.
The [binary/text contract](.data/wasm-multi-memory-binary-inventory.json) pins
the normative documents, hashes, memarg bit, immediate order, and text defaults.
Its [terminal inventory](.data/wasm-multi-memory-runtime-inventory.json) then
scores all 38 proposal files and **829/829 commands**, with zero failures,
skips, or runner errors.

`Features.multi_memory` retains every memory index through scalar, SIMD,
atomic, bulk-memory, size, grow, import, export, data-segment, validation, and
execution paths. It remains disabled by default and is independent of
Memory64; mixed memory32/memory64 validation uses each selected memory's
address type.

Focused robustness coverage fault-injects every allocation point, runs 32
mixed-memory lifecycle cycles, and checks 512 deterministic random operations
against independent byte-store models. Run it with
`zig build test -Dtest-filter="multi-memory"`; the CI unit shards repeat it
under Linux TSan, and `-Doptimize=ReleaseSafe` covers the optimized safety path.

Reproduce the score with pinned WABT 1.0.39:

```sh
zig build wasm-spec-eval
python3 tools/wasm-spec.py --profile multi-memory \
  --spec-root /path/to/multi-memory \
  --wast2json /path/to/wabt-1.0.39/wast2json \
  --engine zig-out/bin/wasm-spec-eval
```

### Memory64 binary, validation, runtime, and JavaScript API boundary

The finished Wasm 3.0 memory64 proposal is pinned at
`WebAssembly/memory64@9003cd5e24e53b84cd9027ea3dd7ae57159a6db1`. The checked-in
[memory64 inventory](.data/wasm-memory64-binary-inventory.json) records the
normative binary/type/validation documents, pointer-width host constraint,
empty proposal-dependency set, all eight limits flags, and the exact selected
upstream corpus. The selection contains 23 files and 13,918 top-level commands,
with 824 textual memory64 declarations and 151 table64 declarations; these are
inventory facts, not a terminal pass score.

Behind `Features.memory64`, memory and table types retain an explicit i32/i64
address type, i32 limits use u32 while i64 limits use u64, and every scalar,
SIMD, and atomic memory argument retains its u64 offset. The decoder enforces
the i32 memory limit of 2^16 pages, i64 memory limit of 2^48 pages, i32 table
limit of 2^32-1 elements, and i64 table limit of 2^64-1 elements. It rejects
oversized or overlong u64 LEB encodings and reports disabled memory64/Threads
gates at deterministic byte offsets.

Validation uses the selected memory or table address type for active segment
offsets, loads/stores, SIMD and atomic operations, `memory.size/grow`,
`table.get/set/size/grow/fill`, indirect calls, and the destination/source/
narrower-length rules for bulk copies. Memory/table initialization keeps its
segment offset and length operands at i32 as required by the proposal. A
memory32 memory argument above 2^32-1 is rejected even though its binary field
is u64. Allocation-failure injection covers every decoder allocation point.

Execution retains i64 addresses through checked effective-address and range
arithmetic rather than narrowing them through `usize` or u32. This applies to
scalar, SIMD, atomic, bulk-memory, table64, indirect-call, active-segment,
size, and grow operations. Out-of-bounds and overflowing accesses trap before
mutation. Growth over a declared or host limit returns the full-width Wasm -1
sentinel; zero growth succeeds even at the limit.

The public JavaScript API accepts `address: "i64"` only when memory64 is
enabled on a 64-bit host. Memory/Table constructors and methods require BigInt
for i64 sizes and indices, return BigInt growth results and table lengths, and
preserve imported/exported wrapper identity. The embedding caps actual
memory64 allocation at 262,144 pages (16 GiB) and tables at 10,000,000
elements. Valid core declarations can exceed those host limits, but allocation
and growth reject them deterministically without truncation or partial
mutation. A 32-bit host can still decode and validate memory64 modules, while
runtime construction reports the unsupported host before allocation.

Shared memory64 reserves only maxima inside that same host boundary, grows a
stable backing concurrently, and publishes fresh fixed-length
SharedArrayBuffer wrappers without detaching historical buffers. Cross-instance
imports retain object identity and see the same bytes. Failure-injection checks
cover decoder and instance construction rollback; precise-root checks prove
table64 externrefs survive while stored and are reclaimed after clearing.

The focused ordinary run and the same slice under ThreadSanitizer each pass
**22/22 memory64 tests, with 0 failures, 0 skips, and 0 leaks**. These include
forced 32-bit/64-bit host-policy witnesses, 4 GiB+ addresses, integer overflow,
concurrent shared growth, repeated JavaScript growth, historical buffer aliases,
cross-instance sharing, and allocation failure.

The [terminal runtime inventory](.data/wasm-memory64-runtime-inventory.json)
uses pinned `wasm-tools 1.253.0` at
`c799bb87b9cf9dc4fa7d11d63c5d52cbb3c4eb38` and scores all 23 declared files.
All **13,826/13,826 applicable commands pass**; 92 text-only assertions are
explicit N/A, with zero semantic failures or runner errors.

Reproduce the checked-in facts and focused boundary with:

```sh
zig build wasm-feature-profiles-check
zig build test -Dtest-filter=memory64
zig build test -Dtsan=true -Dtest-filter=memory64
zig build test -Dtest-filter=wasm.decode
zig build test -Dtest-filter=wasm.validate
python3 tools/wasm-spec.py --profile memory64 \
  --spec-root /path/to/memory64 \
  --converter /path/to/wasm-tools \
  --engine zig-out/bin/wasm-spec-eval --command-shards 8
```

The binary and validation boundary is complete in
[#296](https://github.com/zig-utils/zig-js/issues/296), and runtime/JavaScript
API/lifecycle coverage is complete in
[#297](https://github.com/zig-utils/zig-js/issues/297). The 13,918-command
terminal corpus score now satisfies the upstream semantic portion of
[#300](https://github.com/zig-utils/zig-js/issues/300), which remains open for
the final supported-host evidence matrix.

### Wasm GC pinned binary and corpus contract

The finished Wasm 3.0 GC proposal is pinned at
`WebAssembly/gc@756060f5816c7e2159f4817fbdee76cf52f9c923`, with its declared
`typed_function_references` dependency. The checked-in
[GC inventory](.data/wasm-gc-binary-inventory.json) also pins the proposal's
`test/core/gc` tree object and SHA-256 digests for the overview plus the
normative binary and validation type/instruction documents. This prevents a
branch name, rebuilt document, or later proposal edit from silently changing
the implementation target.

The binary contract contains i8/i16 packed storage, ten abstract heap types,
nullable and non-null reference forms with signed-33-bit heap immediates,
function/struct/array composite types, final and extensible subtypes, recursive
groups, and field mutability. It contains **33 instruction encodings**: direct
`ref.eq`/`ref.as_non_null` opcodes and every `0xfb` subopcode from 0 through 30,
including structs, arrays, casts/tests, cast branches, extern conversion, and
i31 operations.

All **18** dedicated upstream GC files are declared. They contain **698
top-level commands**: 88 modules, 408 return assertions, 100 trap assertions,
60 invalid assertions, two malformed assertions, eight unlinkable assertions,
20 invokes, and 12 registrations. Per-file command breakdowns and source-token
occurrences for every instruction family are recorded in the inventory. These
facts and exact file set are locked by `zig build wasm-feature-profiles-check`.
The [terminal runtime inventory](.data/wasm-gc-runtime-inventory.json), generated
at engine commit `e60432ab` with `wasm-tools 1.253.0` from source commit
`c799bb87b9cf9dc4fa7d11d63c5d52cbb3c4eb38`, records **697 / 697 applicable
passes**, zero semantic failures, one malformed-text N/A, and zero converter or
runner errors.
Every command retains its source file, line, kind, execution mode, and detail.

The binary and validation boundary is complete. The decoder retains packed
storage, nullability, concrete heap indices, field mutability, recursive-group
membership, and all instruction immediates. Validation closes recursive groups
independently of module indices so structurally equal iso-recursive types share
canonical identity; it also enforces earlier non-final supertypes, function
variance, struct width, immutable covariance, mutable invariance, packed-access
extensions, defaultability, segment types, cast refinement, and every aggregate
instruction stack. Forward references are legal only inside their declared
recursive group. Focused evidence covers all instruction families,
deterministic invalid diagnostics, validator allocation failure, and a
512-level subtype chain: **8/8 GC validation tests pass**. The complete
validator regression root passes **93/93 tests**.

The binary/validation boundary completes [#298](https://github.com/zig-utils/zig-js/issues/298),
and the runtime/lifetime boundary completes
[#299](https://github.com/zig-utils/zig-js/issues/299). All 33 instructions
execute, including extern conversions. Canonical wrappers preserve identity
across calls, tables, globals, exceptions, exports, imports, and independently
decoded modules. Active frames and stable external handles root instance-owned
mark/sweep; weak wrappers, cycles, nested host references, and dead exception
payloads reclaim exactly. The focused evidence is **10/10 GC runtime tests**
and **40/40 WebAssembly API tests**, both with zero leaks, plus a clean
eight-way wrapper-publication ThreadSanitizer witness. Extended constant
expressions initialize i31, struct, array, and typed-table values, including
immutable preceding/imported globals. The zero-failure terminal gate is
recorded in [#300](https://github.com/zig-utils/zig-js/issues/300).

Reproduce the complete GC proposal score with the exact checkout and converter
named above:

```sh
zig build wasm-spec-eval
python3 tools/wasm-spec.py --profile gc \
  --spec-root /path/to/gc \
  --converter /path/to/wasm-tools \
  --engine zig-out/bin/wasm-spec-eval
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
scored Core 2 profile above; SIMD, Threads, exception handling, and tail-call
execution are covered by separately scored profiles. Shell-only hooks stay
tracked separately.

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
