---
title: Performance Benchmarks
description: Reproduce and interpret zig-js direct, independent-context, shared-realm, and JavaScriptCore comparison measurements.
---

# Performance Benchmarks

zig-js keeps six benchmark families separate:

- `zig build bench` compares the bytecode VM with the tree-walking interpreter and prints a small no-shared-state thread-scaling table.
- `zig build benchmark-comparison` directly compares GC-enabled zig-js and JavaScriptCore in direct single-context, independent-context steady-state, and independent-context cold-lifecycle modes. It reports zig-js shared-realm no-GIL scaling in a separate capability panel.
- `zig build representative-benchmark` runs the versioned, dependency-free application-surface matrix from `docs/.data/representative-benchmark-matrix-v29.json`. V29 hash-inherits every V28 workload, representation, width, job count, checksum, execution mode, scored operation, attribution counter, mixed-tier replay signature, timing boundary, occupancy rule, binary-provenance profile, and publication ruling. It re-pins only the exact-parent process classifier after bounded `zig version`/`zig --version` metadata probes were excluded from competing compiler work; every other Zig command remains fail-closed. Historical artifacts remain unchanged. Benchmark children never overlap, complete-process occupancy remains diagnostic, the scored boundary retains the 60% gate, historical reports are not rewritten, capability boundaries remain explicit, lifecycle/no-JIT/string-indexing/external-suite evidence never enters repository-owned aggregates, and quick mode is validation only.
- `home-tool run tools/wasm-simd-benchmark.ts` compares representative integer, float, shuffle, and memory Wasm SIMD kernels with scalar exports from the same module and with the system JavaScriptCore, at one and eight independent warmed contexts.
- `zig build gc-compaction-benchmark` compares identical fragmented heaps before and after explicit compaction, preserving retained backing, pause, fixed-point, and post-action checksum evidence.
- `zig build gc-generation-benchmark` compares moving and non-moving age-one and age-three nursery policies across ephemeral, mixed-survival, high-survival, and shared no-GIL workloads with exact cumulative generation telemetry.

None is an application benchmark or a universal engine score. They are small, inspectable baselines intended to reveal regressions, scaling limits, and the engine paths that deserve profiling.

## Cold context lifecycle evidence

The frozen [`context-lifecycle-profile-v1.json`](.data/context-lifecycle-profile-v1.json)
defines four zig-js-only cold rows: a fully installed context with no evaluation,
first script evaluation, first dependency-free module evaluation, and a
full-WebAssembly-feature context whose first script exercises classes, typed
arrays, JSON, and RegExp. `Thread`, Worker, Promise, and queue work are outside
this profile. Every iteration creates a new GC-enabled Context and destroys it;
there is no pre-created realm, cold warmup, forced collection, delayed finalizer,
or retained context pool.

`context_lifecycle` emits the ordinary exact-parent row plus a versioned
telemetry row. The latter retains create/work/destroy phase nanoseconds, total
process user/system CPU, same-domain Mach peak/current RSS, post-destroy RSS at
the 25/50/75/100% soak checkpoints, and every `Context.GcFinalizerStats` field.
The phase sum deliberately excludes adjacent telemetry reads, while the
fresh-process `/usr/bin/time` wall/CPU metrics include that instrumentation;
neither boundary is presented as the other. Cell-kind totals must reconcile to
the once-only bulk-teardown count. A soak of at least eight contexts rejects
material monotonically increasing post-destroy RSS and any final retained
growth above both the frozen absolute/fractional bound.

Collection uses the exact-parent driver with `--mode context_lifecycle`, one
lane, at least eight cold iterations per fresh process, the frozen per-iteration
scenario checksum, and the normal clean-worktree, exact-first-
parent, alternating-order, competing-process, CPU-occupancy, power, thermal,
and hardware-counter guards. The profile is a measurement contract, not a
published speedup. A dated raw artifact from a declared quiet reference host is
still required before #479 can claim a lifecycle improvement.

## Required-bytecode/no-JIT arithmetic profile

V20 added, and V23 retains, four zig-js-only non-scored rows from
[`vm_arithmetic_comparison.js`](../bench/vm_arithmetic_comparison.js): stable
Number arithmetic, a stable BigInt control, one Number/string/BigInt/object
polymorphic site, and observable coercion plus exception controls. The
`single_no_jit` and `attribution_no_jit` runner modes create a production
GC-enabled Context with native tiers disabled, then require bytecode admission.
Unsupported lowering is an error rather than a silent tree-walker result.

The frozen contract records quick and full work counts and checksums. Its
separate attribution run requires nonzero VM entry/dispatch and compilation
counters while tree-walker entry, baseline/optimizer publication, and generated
native-code bytes remain zero. V21 additionally records exact Number-specialized
hit, miss, and dequickening counts from Context-owned atomics. Ten reduced-work
warm calls occur outside the single timed invocation. These rows are witnesses for
[arithmetic quickening issue #734](https://github.com/zig-utils/zig-js/issues/734),
not a JavaScriptCore comparison or performance result. Any speed claim still
requires a clean exact-parent A/B on a quiet AC-powered reference host, with the
polymorphic and coercion controls reported beside the stable Number row.

## Required-bytecode UTF-16 indexing growth profile

V23 adds a separate zig-js-only non-scored profile from
[`string_indexing_comparison.js`](../bench/string_indexing_comparison.js) for
[#767](https://github.com/zig-utils/zig-js/issues/767). It freezes 1,024,
2,048, and 4,096 UTF-16-code-unit strings across ASCII, non-ASCII Latin-1,
non-Latin-1 BMP, astral, lone-surrogate, and mixed representations. Fixture
pattern expansion, exact-width slicing, and String boxing happen during
configuration, before the runner's ten one-job warmups and timed full-work
invocation.

Each job performs one `charCodeAt`, primitive exotic index, boxed exotic
index, primitive `length`, and boxed `length` operation per abstract code
unit. It also validates `charAt` at the middle, `at(-1)`, and
`codePointAt` at the middle. Every indexed character is checked across the
three access paths before it contributes to the frozen checksum. Both modes
disable native tiers and require bytecode, so tree-walker entry or generated
code is a contract failure rather than an unreported fallback.

Two separate full-work attribution replays must agree exactly on result,
admission, Context backing-allocation requests, and Context
backing-allocation bytes before a representation or indexing implementation
can change. The V23 manifest freezes each invocation snapshot; these cumulative
counters start before Context construction and include configuration and
warmup, while scored timing does not. The widths are intended for normalized
retired-instruction growth evidence under the additive algorithmic-growth
profile. They are not a JavaScriptCore comparison or a wall-time claim; an
efficiency claim still requires the ordinary quiet-reference AC exact-parent
gate.

## Representative WebAssembly rows

V3 moves `wasm_scalar` from the deferred inventory into the scored matrix; V4
does the same for `wasm_simd`, and V5 completes `wasm_memory`. Both
engines evaluate the exact existing `bench/wasm_simd_comparison.js` bytes and
instantiate the same embedded module. Warm rows time only the selected export
export after the inherited ten-call warmup; cold rows include source evaluation,
module compilation and instantiation, invocation, context teardown, and worker
join. Each base and structural variant pair calls the same scalar or `i32x4`
export with the same input multiset in ascending versus descending order, so
the harness requires identical frozen checksums and equivalent tier
attribution. The SIMD export also retains the scalar export in the same module
as its checksum oracle.

The memory family keeps non-shared `v128` load/store rows on direct and
independent-context modes. It deliberately does not invoke one non-shared
instance concurrently. A separate cross-engine subpanel scores the equivalent
scalar-memory export, while a zig-js capability subpanel runs disjoint atomics
over a genuinely shared module at 1/2/4/8 workers. Before that capability row
can report JavaScriptCore as `N/A`, every run re-probes the system JSC runner
and requires its documented `JavaScriptException`; no false throughput ratio is
constructed.

The separate accepted Wasm SIMD and Threads reports remain immutable historical
evidence. V5 integrates their owned workload contracts into the representative
matrix without copying their old timing numbers or rewriting their reports.

## Representative Promise and microtask row

V6 completes `promises_async_microtasks` with identical source bytes covering
direct and chained Promise reactions, thenable assimilation, and a two-stage
`async`/`await` continuation. Each runner invokes the workload through its
public evaluation API, lets that API perform its normal end-of-script microtask
checkpoint, and reads the exact checksum through the same generic hook. All
three actions are inside the timed boundary. Workloads without the hook retain
their historical one-evaluation path.

The base and structural variant enqueue the same continuation graph in opposite
orders and must produce identical frozen checksums. The full job count is sized
against JavaScriptCore's faster direct row so it clears the 50 ms floor; a slow
zig-js row remains visible rather than weakening the workload. The shared-realm
panel uses per-lane state prepared before thread creation, and `Thread.join()`
observes each worker only after its own microtask queue has drained.

## Representative Temporal row

V7 scores deterministic ISO/UTC `Temporal.PlainDate`, `Temporal.Instant`, and
`Temporal.Duration` construction and arithmetic in zig-js direct and
shared-realm modes. Separate forward and reverse implementations change loop
direction, identifiers, property order, and operation order while retaining
identical inputs, work, and frozen checksums.

This is an availability-gated capability family, not a cross-engine ratio.
Every run evaluates the same constructor-profile probe in both public runners;
zig-js must return `1` and the system JavaScriptCore `JSGlobalContext` must
return `0` before JSC is reported as `N/A`. The scored workload never changes
conditionally, and no result is inferred from the operating-system version.

## Representative module graph

V8 completes `modules_dynamic_import` with two repository-owned module graphs.
Each cold sample times OS-thread and context creation, host resolution, static
load/link/evaluation, top-level `await import()`, microtask settlement, exact
checksum extraction, context destruction, and join. The 1/2/4/8-lane rows use
independent contexts; no module registry survives a sample or grows across it.

The structural graph changes every module/binding name, reverses source-data
layout and traversal, and reverses static-import order while preserving exact
work and checksums. Its dedicated attribution mode proves the two graphs select
the same tiers and allocate the same number of environments.

This is also a capability boundary, not a false comparison. The installed JSC
public SDK exposes `JSEvaluateScript` and Objective-C `evaluateScript:` but no
public module evaluation/host-loader entry point. Every matrix run additionally
requires the public JSC runner to reject the exact module-syntax probe before
rendering `N/A`; no private SPI, source transform, or script emulation is used.

## Representative tier attribution

The V2 representative contract records tree-walker, bytecode-VM, baseline,
optimizer, optimizer-OSR, deoptimization, bytecode-admission, generated-code,
and environment-allocation observations in fresh zig-js contexts. It snapshots
configuration, the inherited ten-call reduced-work warmup, and one full-work
invocation separately. Every base/structural-variant pair must select the same
non-empty tier set during warmup and invocation; exact counts remain visible so
the equivalence gate cannot normalize an unexpected fallback away. Each pair
must also allocate exactly the same number of environments in each phase, so a
variant cannot hide an unnecessary heap scope behind otherwise equal tiers.

The first full-work V8 tier-only evidence is the
[`representative-tier-attribution-v8-2026-08-04.md`](.data/representative-tier-attribution-v8-2026-08-04.md)
report and its
[`representative-tier-attribution-v8-2026-08-04.json`](.data/representative-tier-attribution-v8-2026-08-04.json)
raw artifact. It records configuration, warmup, and invocation snapshots for
all 36 base/variant workloads at exact revision
`a1b5c3932c5a49a996da59ca9c20a852938975d4`; the earlier V2 artifact remains
unchanged as historical evidence.

Schema-version-2 sidecars add phase-boundary `native_code` and
`heap` objects. Native-code state distinguishes live mappings, currently
retired mappings, cumulative reclamation, and each invalidation/fallback class.
Heap state reports precise-collector live bytes, the last full-collection
baseline, and cumulative collection counts. These are engine residency gauges
and counters; they are not process RSS, allocation throughput, or GC-pause
percentiles, and the report labels them separately from timing measurements.
Schema-1 artifacts remain valid and are never rewritten to synthesize fields
that their runners did not capture.

Schema-version-3 sidecars use the V9 matrix contract and add exact VM
instruction dispatches, successful VM quick-kernel entries, native-tier runtime
operation entries, embedding host-callback invocations, and Wasm export
dispatches. The collector rejects an incomplete execution inventory and
requires every Wasm family to record invocation-phase Wasm dispatch. These are
monotonic phase counters, not timings or sampled estimates. Ordinary contexts
still retain the null attribution pointer; scored timing rows do not enable the
counter sidecar.

Schema-version-4 sidecars use the V10 matrix contract and snapshot the owned
contention profiler from before context construction. Raw fields retain every
Thread lock/condition/property wait, queue/channel operation,
arena/environment/object lock acquisition/contention/spin, worker run/CPU/max,
and thread-join park/wait observation. Rendered phase rows summarize contention,
wait, and worker deltas. A measured zero remains zero; it is not substituted for
missing telemetry. Normal timing runs leave the profiler disabled.

Schema-version-5 sidecars use the V11 contract. An opt-in allocator wrapper
counts successful Context backing allocations/growth/releases and their exact
bytes from before arena and Context construction; the profiler storage itself
is deliberately outside its accounting boundary. Separate GC-cell counters
retain fresh, reused, relocation, and delegated logical cell issuance so a slab
refill is never double-counted as every cell it serves. Cell bytes use the exact
issued size-class storage, matching the storage bytes recorded when cells are
freed. Every completed minor and full collection appends its raw nanosecond pause to bounded owned storage;
sample overflow rejects the artifact. Reports derive p50/p95/max with the
nearest-rank method and use `none`, not zero, when a phase completes no cycle.
Ordinary contexts keep the original allocator chain and allocate no pause
sample storage.

Schema-version-6 sidecars use the V12 contract. Each fresh attribution process
reads cumulative user/system CPU and peak RSS from `getrusage` and the live
resident size from Mach `task_info` at every phase boundary. Reports subtract
the CPU counters between boundaries while preserving peak and retained RSS as
gauges. The invocation retained value is sampled after the workload host
checkpoint and before Context destruction, so it is neither allocator-requested
bytes nor the process-exit peak. These resource queries remain outside scored
timing rows.

Schema-version-7 sidecars use the V13 contract. Successful and failed baseline
and optimizer attempts record total/max latency from an accepted compilation
claim through publication outcome. Deoptimization latency begins only after
native code returns a recoverable exit and ends when the bytecode interpreter's
continuation is fully reconstructed, excluding native execution before the
exit. Counts tie successful attempts to published artifacts and reconstructed
exits to the deoptimization execution counter. Ordinary contexts retain a null
attribution pointer and perform none of these clock reads.

Schema-version-8 sidecars use the V14 contract. In addition to the inherited
single-context and module rows, they cover both additional-panel workloads and
every supported shared-realm family/panel row at the frozen 1/2/4/8 lane
counts. Shared configuration, warmup, and invocation snapshots use the exact
scored shared harness. The invocation boundary is observed only after every
real JavaScript `Thread` joins, and validation requires exactly one worker run
per lane, the frozen lane-specific checksum, complete GC/allocation/process
inventories, and base/variant tier and environment-allocation equivalence at
each lane count. Families whose frozen contract says `shared: false` remain
excluded; the collector does not manufacture a shared result for them.

Schema-version-9 sidecars retain the V14 workload and metric contract and add
durable collection identity. After each complete three-phase execution, the
collector validates the entire ordered prefix and atomically replaces an
explicit `complete: false` checkpoint. A later invocation resumes only when
the matrix, quick/full mode, runner binary, host, OS, Zig, zig-js, zig-gc,
zig-regex, and JavaScriptCore identities match exactly. Date and power state
remain visible per collection segment instead of being normalized away. Only
a complete 510-snapshot inventory can transition to `complete: true` and
produce the Markdown report; a killed process can therefore neither publish a
partial artifact nor force already-validated workloads to run again.

Schema-version-10 sidecars use the V15 contract and retain schema 9's exact
checkpoint/resume rules. CPU remains cumulative `getrusage` user/system time.
Peak and current resident bytes now come from `task_vm_info`'s
`resident_size_peak` and `resident_size` fields in the same kernel snapshot.
Darwin declares non-CPU `rusage` fields implementation-defined, and a real
memory-pressure run demonstrated that `ru_maxrss` can be lower than Mach's
simultaneous current-resident gauge. V15 preserves the valid peak/current
ordering by measuring both in one documented Mach accounting domain rather
than dropping the coherence gate.

Schema-version-11 sidecars retain the V15 workload, resource, and durable
checkpoint contract and add exact GC cell-slab lock attribution. Every lock
attempt is classified once as single allocation, batch allocation, publication,
unpublication, free, ownership, relocation, or maintenance, and once by its
64/128/256/512/1024/2048-byte size class. The raw inventory preserves
acquisitions, contended acquisitions, and failed-CAS spins per class; validation
requires the purpose and size-class sums to reproduce the totals exactly.
These opt-in counters diagnose lock traffic and coherence pressure outside the
scored timing rows. Ordinary contexts retain the nullable profiler sink and do
not increment the counters.

Schema-version-12 sidecars retain schema 11's contract and split every
ownership acquisition into exact-allocation validation, stable-identity lookup,
conservative interior classification, realm lookup, realm scan, allocator
resize, or allocator remap. Validation requires those seven subpaths to sum
exactly to the ownership total. This distinction prevents a tolerant write
barrier, conservative stack scan, and allocator callback from being treated as
the same optimization target merely because they acquire the same size-class
lock.

The full-work schema-2 evidence is the
[`representative-tier-attribution-v8-schema-v2-2026-08-04.md`](.data/representative-tier-attribution-v8-schema-v2-2026-08-04.md)
report and its
[`representative-tier-attribution-v8-schema-v2-2026-08-04.json`](.data/representative-tier-attribution-v8-schema-v2-2026-08-04.json)
raw artifact. Its 108 snapshots name exact revision
`2c7c4f31025ffb793dc474ffe6847f1705f1dc76` and retain every native-code and
heap field for all 36 workloads.

The full-work schema-3 runtime-dispatch evidence is the
[`representative-tier-attribution-v9-schema-v3-2026-08-04.md`](.data/representative-tier-attribution-v9-schema-v3-2026-08-04.md)
report and its
[`representative-tier-attribution-v9-schema-v3-2026-08-04.json`](.data/representative-tier-attribution-v9-schema-v3-2026-08-04.json)
raw artifact. Its 108 snapshots name exact implementation revision
`e6b7dc42ed973737f937de6279cb567e25857c2d`, preserve the complete execution,
admission, native-code, and heap inventories, and record nonzero invocation
dispatches for all six Wasm base/variant rows.

The full-work schema-4 synchronization evidence is the
[`representative-tier-attribution-v10-schema-v4-2026-08-04.md`](.data/representative-tier-attribution-v10-schema-v4-2026-08-04.md)
report and its
[`representative-tier-attribution-v10-schema-v4-2026-08-04.json`](.data/representative-tier-attribution-v10-schema-v4-2026-08-04.json)
raw artifact. Its 108 snapshots name exact implementation revision
`539cdb0b7a63431b33985104ec91e88b95ac6c1c`. The single-context lane-zero
workloads record exact environment and object lock acquisitions while their
contention, wait, and worker deltas measure zero; shared-lane attribution is a
separate result and is not inferred from these runs.

The full-work schema-5 allocation/GC-pause evidence is the
[`representative-tier-attribution-v11-schema-v5-2026-08-04.md`](.data/representative-tier-attribution-v11-schema-v5-2026-08-04.md)
report and its
[`representative-tier-attribution-v11-schema-v5-2026-08-04.json`](.data/representative-tier-attribution-v11-schema-v5-2026-08-04.json)
raw artifact. Its 108 snapshots name exact implementation revision
`4ceaa61eb5298ffd9c4824c100ad3b5dc01d7634`, retain 16 allocation fields and
the raw histories of 1,953 completed collections with zero overflow, and match
every minor/full sample inventory to the corresponding heap collection counters.

The full-work schema-6 process-resource evidence is the
[`representative-tier-attribution-v12-schema-v6-2026-08-04.md`](.data/representative-tier-attribution-v12-schema-v6-2026-08-04.md)
report and its
[`representative-tier-attribution-v12-schema-v6-2026-08-04.json`](.data/representative-tier-attribution-v12-schema-v6-2026-08-04.json)
raw artifact. Its 108 snapshots name exact implementation revision
`00b5e00f2064687b7fdf9f1f7ca34445922d8340` and retain all four process-resource
fields. In the regexp invocation rows, the structural variant records
23,789,570,528 retained Context backing bytes but 2,986,147,840 live resident
bytes and a 3,172,679,680-byte fresh-process peak; the base records 160,907,264
live resident bytes. These are separate measured domains, not conversions of
allocator counters into RSS.

The full-work schema-7 tier-transition evidence is the
[`representative-tier-attribution-v13-schema-v7-2026-08-04.md`](.data/representative-tier-attribution-v13-schema-v7-2026-08-04.md)
report and its
[`representative-tier-attribution-v13-schema-v7-2026-08-04.json`](.data/representative-tier-attribution-v13-schema-v7-2026-08-04.json)
raw artifact. Its 108 snapshots name exact implementation revision
`f0546ee8a39898d07de7209aae08d3495ac4915f` and retain 17 timing fields. Across
the 36 fresh processes, the final snapshots contain 272 baseline/optimizer
attempts: 54 successful publications and 218 rejected attempts. Successful
tier-up work totals 6,678,959 ns. The same snapshots record 9,841,288 fully
reconstructed deoptimizations totaling 209,630,978 ns; publication and
deoptimization counts match their independent owner/execution counters.

Attribution is deliberately outside the timing rows. Normal contexts retain a
null telemetry pointer, while the sidecar opts in to atomic counters. A full
published representative report therefore preserves both its ordinary timing
TSV and its attribution JSON:

```sh
zig build representative-tier-attribution -Drepresentative-tier-attribution-quick=true
zig build representative-benchmark \
  -Drepresentative-benchmark-raw-out=docs/.data/representative-benchmark-YYYY-MM-DD.tsv \
  -Drepresentative-benchmark-tier-attribution-out=docs/.data/representative-tier-attribution-YYYY-MM-DD.json \
  -Drepresentative-benchmark-markdown-out=docs/.data/representative-benchmark-YYYY-MM-DD.md
```

Writing raw or Markdown representative evidence without the attribution
sidecar is rejected. As with every benchmark here, the quick command validates
the harness and frozen checksums but is not publication evidence.

## Instrumentation overhead

The V16 representative contract integrated this completed #503 panel by
hash-pinning both the opt-in exact-parent publication guard and the disabled-path
fixture below. V17 inherits the panel and re-pins only the exact-parent
integration after it gained frontend counters and fail-closed competing-job,
transient-overlap, and contaminated-build rejection. This does not copy
diagnostic timing numbers into representative rows: unavailable counters remain
unavailable, and only a stable nominal quiet-reference run can support an
efficiency claim.

[`tools/instrumentation-overhead.ts`](../tools/instrumentation-overhead.ts),
exposed as `zig build instrumentation-overhead`, alternates fresh-process
disabled/enabled pairs from one ReleaseFast runner and rejects any workload,
job-count, sample-index, or frozen-checksum mismatch. The default
`execution_attribution` profile compares `single` with `single_profiled`; the
`native_observability` profile compares `single` with `single_observed` and also
rejects generated-tier or live-code drift. The raw artifact retains invocation
wall time, complete
fresh-process wall time, process user/system CPU, peak RSS, retired instructions,
cycles, cumulative process energy, package/interrupt wakeups, page-ins, VM
page-cache hits, and voluntary/involuntary context switches for every sample.
It derives cycles, instructions, and process-energy per frozen logical job,
instructions per cycle, and jobs per joule without replacing the raw values.
Public `NSProcessInfo.thermalState` snapshots before and after each boundary
retain nominal/fair/serious/critical state and detect within- or across-sample
drift. No sample is discarded or reordered.

Schema v5 (with historical schema-v1/v2/v3/v4 artifacts left unchanged) keeps
each OS counter as a status-bearing observation: `measured`,
`unavailable`, or `permission_denied`. Before the alternating workload pairs it
runs the same number of runner-owned no-op boundary probes, then compares their
raw counter dispersion with the disabled known-work samples. Five-percent
relative standard deviation separates `stable` from `noisy`; zero-mean or
insufficient observations are `indeterminate`, never silently stable.

On macOS, the runner snapshots its own public
`proc_pid_rusage(RUSAGE_INFO_V6)` record immediately before and after the timed
JavaScript invocation. That owned boundary supplies instructions, cycles,
process energy in nanojoules, wakeups, page-ins, and VM page-cache hits;
`/usr/bin/time -l` independently supplies fresh-process CPU, peak RSS, and
context switches. System thermal snapshots occur immediately outside both the
wall-time and process-counter boundaries, so querying Foundation is not charged
to the JavaScript work. The artifact records that the instruction/cycle
interface exposes no multiplexing or scaling metadata. CPU cache/TLB misses,
branches, migrations, scheduler wait, frequency, package energy, and peak power
remain explicit unavailable capabilities rather than zero-valued measurements.
VM page-cache hits are never mislabeled as CPU cache behavior.

```sh
zig build instrumentation-overhead \
  -Dinstrumentation-overhead-raw-out=docs/.data/instrumentation-overhead-YYYY-MM-DD.json \
  -Dinstrumentation-overhead-markdown-out=docs/.data/instrumentation-overhead-YYYY-MM-DD.md
```

The two states execute the exact same binary, so the fixture records that
binary's hash and size but does not pretend the runtime toggle measures
compile-time support size. In the default profile, retained RSS is unavailable
after the fresh process exits. In the native-observability profile, runner-owned
Mach `task_vm_info` snapshots record current RSS before and after Context
teardown in the same accounting domain as their corresponding peak values. The
runner also emits exact live artifact/code/tier counts and GDB JIT registration,
symbol-object, unwind, and lifetime counters. Validation requires equal native
code in both states, zero publisher state when disabled, live publisher storage
when enabled, and zero live debugger storage after teardown. Single-thread lock
contention remains explicitly not applicable. Quick mode uses two reduced-work
pairs to validate the harness and is never publication evidence.

```sh
zig build instrumentation-overhead \
  -Dinstrumentation-overhead-profile=native_observability \
  -Dinstrumentation-overhead-raw-out=docs/.data/instrumentation-overhead-native-YYYY-MM-DD.json \
  -Dinstrumentation-overhead-markdown-out=docs/.data/instrumentation-overhead-native-YYYY-MM-DD.md
```

Counter collection is a separate `--darwin-rusage` runner mode. Ordinary
benchmark and production execution does not call `proc_pid_rusage`; the opt-in
snapshots and counter row are absent from that path. Native publisher telemetry
is likewise an explicit runner option. The execution-attribution and
native-observability profiles remain separate exact-binary A/B experiments, so
neither profile attributes the other profile's measurement work to its enabled
state.

Runs default to `diagnostic`. A negligible-overhead publication claim requires
`-Dinstrumentation-overhead-host-class=quiet_reference`; that classification
fails closed unless the captured power state is AC and known-work instructions,
cycles, and process energy are all measured and stable at the declared 5% RSD
threshold. Known-work thermal state must also remain nominal before and after
every sample with no across-sample state change. Battery, hosted,
unavailable-counter, noisy-counter, non-nominal, or thermally drifting results
stay visible as diagnostic artifacts and cannot satisfy the reference-host
gate.

The first full-work diagnostic is the seven-pair
[`instrumentation-overhead-diagnostic-2026-08-04.md`](.data/instrumentation-overhead-diagnostic-2026-08-04.md)
report with
[`instrumentation-overhead-diagnostic-2026-08-04.json`](.data/instrumentation-overhead-diagnostic-2026-08-04.json)
raw samples. It names exact revision
`2fa97532c28dda7391b9ce1d083852495d10c92f` and its battery/discharging power
state; it validates the complete collection path but makes no negligible-cost
claim.

## Independent suites and additional engines

The V16 representative contract integrated this completed #504 panel by
hash-pinning its inventory, offline verifier, three available engine adapters,
lossless collector, and source-hash recognizer. V17 inherits that contract
unchanged. The panel remains external corroboration by design: it adds no
ordinary dependency and contributes no numeric value to the repository-owned
representative aggregate.

The frozen [independent-suite inventory](./.data/independent-suite-inventory-v1.json)
keeps external benchmark candidates outside this repository and outside ordinary
build/runtime dependencies. It records exact repository/tree/file pins,
per-row license and applicability decisions, host-adapter limits, and the run
metadata required to pin zig-js, system JSC, V8, SpiderMonkey, or QuickJS.

The first applicable candidate is a six-result diagnostic subset of the 17
Octane 2 results. Octane is explicitly retired, so it can corroborate narrow
peak-throughput behavior but cannot support a modern-web or representative-suite
claim. Every unselected result remains visible with its license, host, or output
validation reason. JetStream 3 alpha is inventoried but excluded until its exact
subtests, mixed licenses, npm preparation, compressed assets, and shell boundary
are audited. Candidate status is not execution evidence.

```sh
zig build independent-suite-audit
git clone --filter=blob:none --no-checkout \
  https://github.com/chromium/octane.git /absolute/outside/zig-js/octane
git -C /absolute/outside/zig-js/octane checkout --detach \
  570ad1ccfe86e3eecba0636c8f932ac08edec517
zig build independent-suite-audit \
  -Dindependent-suite-id=octane-2-retired \
  -Dindependent-suite-checkout=/absolute/outside/zig-js/octane
```

Only the explicit `git clone` acquisition uses the network. Checkout and
verification are offline; the verifier rejects a checkout inside zig-js, the
wrong origin/commit/tree, a dirty tree, a missing file, or any pinned-file
SHA-256 mismatch. It never acquires the suite itself.

The owned zig-js adapter runs one selected row in a fresh, separate process. It
adds only `load` and `print` to the normal engine globals, installs both through
the supported embedding environment/global-object boundary, and evaluates the
verified upstream `base.js` and workload bytes without transformation. The
adapter callback protocol records exact upstream result, error, score, and
auxiliary-print strings; an unsupported or failing workload remains a failed
row rather than disappearing from the candidate set.

```sh
zig build independent-suite-zig-js-bin
zig build independent-suite-zig-js \
  -Dindependent-suite-checkout=/absolute/outside/zig-js/octane \
  -Dindependent-suite-row=richards \
  -Dindependent-suite-mode=score \
  -Dindependent-suite-zig-js-revision=$(git rev-parse HEAD)
```

The run step first performs the full checkout audit, then the runner repeats
the selected file checksums. It also rejects a dirty zig-js worktree, a source
revision other than the exact current `HEAD`, and an environment other than
`TZ=UTC`, `LC_ALL=C`, and `LANG=C`. Because zig-js links its sibling path
dependencies, the runner also rejects dirty `zig-regex` or `zig-gc` worktrees
or a noncanonical origin and retains each dependency's resolved path, exact
revision, canonical repository, and clean status. Each schema-1 JSON line
retains those complete source inputs, the runner path and SHA-256,
argv/environment, applicable row and licenses, exact loaded
sources, the evaluation-step budget and termination owner, pass/failure/skip
fields, all upstream and auxiliary outputs, the raw outer wall/CPU/peak-RSS
sample, explicit single-sample dispersion status, output validation, and both
timing boundaries. The adapter uniformly sets its harness-owned step budget to
unsigned-64 maximum for every row and mode because these pinned workloads are
finite; it does not change source, input, iteration count, or timing logic. The
collector's retained per-child process timeout owns termination, while ordinary
embedding contexts keep the engine's default runaway guard. `score` mode leaves
execution instrumentation off and marks tier, allocator, and pause fields as
not measured rather than emitting fake zeros. `attribution` mode enables the
complete named tier/admission counters, compilation/deoptimization timing, and
GC/allocation/pause summaries; its wall time and upstream score are diagnostic,
not scored performance.

On macOS, the corresponding system-JavaScriptCore adapter is a different
executable linked only to the platform framework. Both engine runners import
one frozen Octane path/checksum/license/result table, but each owns its context,
`load`/`print` callbacks, source evaluation, output capture, and JSON report.
zig-js's JSC-shaped public exports are never linked into the framework runner.

```sh
zig build independent-suite-jsc-bin
zig build independent-suite-jsc \
  -Dindependent-suite-checkout=/absolute/outside/zig-js/octane \
  -Dindependent-suite-row=richards \
  -Dindependent-suite-jsc-adapter-revision=$(git rev-parse HEAD)
```

The system-JSC schema-1 child records the adapter executable path/hash, exact
adapter source revision, framework bundle version, macOS build, argv and
environment. Current macOS releases provide JavaScriptCore code through the
dyld shared cache rather than a standalone framework binary, so that boundary
is explicit instead of inventing a binary hash. The public C API provides no
exact per-context tier/compilation/deoptimization or GC/allocation/pause
counters; those fields are `unavailable_public_api`, never zero. Framework
samples are score-only and remain separate from zig-js attribution samples.

An optional independently installed Node/V8 control is also explicit about its
programming model: it is a fresh `node:vm` context inside a Node process, not a
standalone `d8` shell and not a browser. The adapter verifies the same pinned
sources without transformation and records the Node executable path/hash, Node
and V8 versions, adapter path/hash/revision, argv/environment, raw process
sample, outputs, validation, and timing boundaries. Node exposes no exact
per-context V8 tier or GC counters through `node:vm`, so those fields are
`unavailable_public_api`.

```sh
zig build independent-suite-node-v8-self-test
zig build independent-suite-node-v8 \
  -Dindependent-suite-checkout=/absolute/outside/zig-js/octane \
  -Dindependent-suite-row=richards \
  -Dindependent-suite-node-v8-adapter-revision=$(git rev-parse HEAD)
```

The step is optional and resolves `node` only when invoked; Node/V8 never
becomes an ordinary build or runtime dependency. Standalone V8, SpiderMonkey,
and QuickJS remain separate planned adapters rather than being conflated with
this Node-hosted control.

A single adapter invocation is a compatibility diagnostic, not publishable
performance evidence. The
[`independent-suite-collector.ts`](../tools/independent-suite-collector.ts)
zig-js repeated collection path is a separate, lossless layer:

```sh
zig build independent-suite-collect \
  -Dindependent-suite-checkout=/absolute/outside/zig-js/octane \
  -Dindependent-suite-zig-js-revision=$(git rev-parse HEAD) \
  -Dindependent-suite-collection-out=/tmp/zig-js-octane-collection.json
```

The output path is required to be absolute and outside the zig-js worktree.
That keeps every child process's clean-source proof valid while the collector
atomically replaces the durable artifact after each child. Score rounds rotate
the five applicable rows by sample index, and every score and attribution
sample is a fresh adapter process. Attribution samples remain separate from the
uninstrumented score samples.

Anti-specialization evidence is a distinct attribution-only diagnostic. The
runner first verifies the exact pinned upstream bytes, then prepends a
deterministic block comment to each evaluated source so its SHA-256 and source
offsets differ without changing its AST or workload. Scored sources are never
transformed. The recognizer audit rejects Octane revisions, hashes, and
distinctive identifiers anywhere under `src/`, then requires every exact and
mutated pair to pass the same output contract and select identical nonzero
execution-tier and bytecode-admission sets:

```sh
zig build independent-suite-recognizer \
  -Dindependent-suite-checkout=/absolute/outside/zig-js/octane \
  -Dindependent-suite-zig-js-revision=$(git rev-parse HEAD) \
  -Dindependent-suite-recognizer-out=/tmp/zig-js-octane-recognizer.json
```

The artifact retains both complete child reports and raw transports. It is
diagnostic recognizer evidence, never a performance result.

The schema-1 collection retains each child's raw stdout, parsed JSON when
available, stderr, exit status, timeout state, and contract-validation result.
Failed and malformed children are never discarded. Dispersion is the median,
range, arithmetic mean, and sample relative standard deviation of only
contract-valid passed score children; the artifact lists every failed or
invalid sample index beside those statistics. The selected six-result geometric
score is unavailable unless collection is complete and all five applicable
rows pass. The command therefore writes the complete failure artifact and then
returns nonzero while any row fails.

Two score samples and one separate attribution sample per row are the structural
minimum. Suite-specific publication eligibility requires at least seven score
samples per row, an all-passing complete matrix, and an explicitly selected
`quiet_reference` host observed on AC power. Even then, the geometric value is
labeled as the selected non-browser subset, never the full official Octane or a
browser score. Cross-engine publication additionally requires the inventoried
executable and version pins for each separate engine process.

## Stable attribution and exact-parent A/Bs

[`performance-attribution-schema-v1.json`](.data/performance-attribution-schema-v1.json)
is the machine-readable contract for causal performance artifacts. Its 55
metrics cover wall and CPU time, memory and allocation, interpreter/VM/native
tier selection, compilation/deoptimization/code lifetime, runtime and Wasm
dispatch, GC phases, allocator publication, synchronization, worker lifetime,
hardware efficiency, and native-symbol coverage. Each sample must encode every
metric as `measured`, `unavailable`, or `not_applicable`. A missing instrument
therefore cannot silently become a zero or disappear from a report.

The schema validator also provides lossless versioned migration for the
historical object-churn A/B TSV layouts. It retains every original column and
the input SHA-256 while mapping fields whose scope is already known:

```sh
~/Code/Home/lang/zig-out/bin/home-tool run tools/performance-attribution.ts
~/Code/Home/lang/zig-out/bin/home-tool run tools/performance-attribution.ts \
  --migrate-legacy docs/.data/object-churn-independent-id-block-ab-2026-07-29.tsv \
  --output /tmp/object-churn-independent-attribution-v1.json
~/Code/Home/lang/zig-out/bin/home-tool run tools/performance-attribution.ts \
  --artifact /tmp/object-churn-independent-attribution-v1.json
```

For new causal experiments, `tools/exact-parent-regression.ts` verifies that
the named parent is exactly the candidate commit's first parent, records hashes
of both binaries and the workload source, alternates parent/candidate process
order within every pair, enforces the exact expected checksum, and preserves
process CPU and peak-RSS observations alongside the runner's timed wall value.
Single, independent steady/cold, shared-realm, and module-cold rows additionally
retain exact-boundary instructions, cycles, process energy, and before/after
thermal state. Metrics not connected yet remain explicitly unavailable. The
tool refuses a dirty tracked zig-js, zig-gc, or zig-regex worktree.

```sh
~/Code/Home/lang/zig-out/bin/home-tool run tools/exact-parent-regression.ts /path/to/parent-runner /path/to/candidate-runner \
  --parent-revision HEAD^ --candidate-revision HEAD \
  --source bench/representative_comparison.js \
  --mode single --workload representative_json --jobs 2200 --lanes 1 \
  --material-change cpu_work \
  --expected-checksum 324952086 --samples 7 \
  --timed-boundary "warmed persistent context; one exact invocation" \
  --raw-out docs/.data/exact-parent-YYYY-MM-DD.json \
  --markdown-out docs/.data/exact-parent-YYYY-MM-DD.md
```

An ordinary VM-only allocation replay may continue to use
`--allocation-replay-mode attribution_no_jit` under its historical fail-closed
predicate. A mixed-tier row must additionally name a versioned contract with
`--allocation-replay-contract`. The contract freezes the complete exact
execution, quickening, admission, Shape, native-code, publication, and
generated-code signature. The driver requires configuration, warmup, and
invocation snapshots in order, records the invocation-minus-warmup allocation
requests and bytes, embeds the raw signature in every parent/candidate sample,
and rejects any field, checksum, phase, or identity drift. The first contract
is [`allocation-replay-signature-intl-date-time-format-hour-cycle-v1.json`](.data/allocation-replay-signature-intl-date-time-format-hour-cycle-v1.json);
it preserves #772's mixed 84,001 tree-walker entries, 2 VM entries, and 89,600
Shape transition requests without normalizing any tier.

The default host class is `diagnostic`, which never blocks publication. Only a
deliberately declared `quiet_reference` run gates: candidate wall time must be
more than 110% of its exact parent while both variants have at most 5% RSD.
Independently, reference-host efficiency publication requires parent and
candidate instructions, cycles, and process energy to each remain at or below
5% RSD and every thermal boundary to remain `nominal → nominal`. Unavailable or
noisy efficiency data, non-nominal state, or thermal drift blocks publication
even when wall time improves. This fail-closed rule lets #460/#461 require
efficiency evidence for changes that add threads or CPU work. The
`--material-change` categories are `cpu_work`, `threads`, `generated_code`, and
`cache_traffic`; when the option is omitted, independent/shared modes default
to `cpu_work,threads` and other modes default to `cpu_work`. A
`generated_code` or `cache_traffic` publication additionally requires stable
`generated_code_bytes` or `cache_misses`, so those claims fail closed while the
exact-parent metric remains unavailable on the selected host. Every raw row
remains visible instead of being hidden.
Hosted CI validates schemas, migrations, checksums, thermal drift, and combined
gate behavior without executing reference-host measurements.

## Exact algorithmic-growth evidence

The additive
[`algorithmic-growth-schema-v1.json`](.data/algorithmic-growth-schema-v1.json)
owns compiler-classifier changes whose optimized timed boundary is too short
for stable wall, cycle, or energy measurement while the exact parent grows
superlinearly. It does not relax or replace the ordinary exact-parent profile.
Each input remains a complete `exact_parent_ab` artifact with every wall, CPU,
RSS, allocation, instruction, cycle, energy, thermal, quality, power, and
full-efficiency decision preserved.

The growth artifact scores only retired instructions per identical logical job
and exact allocation replay across at least three frozen, strictly increasing
input widths. Parent and candidate revision, first-parent, dependency, binary,
source, toolchain, host, sample-count, mode, lane, workload-family, job-count,
and checksum identities are validated before normalization. Each variant and
width must keep retired instructions at or below five-percent RSD; allocation
requests and bytes must repeat exactly. The report derives adjacent and
first-to-last instruction ratios and logarithmic growth exponents from the raw
normalized medians.

Wall time, CPU time, RSS, cycles, energy, and thermal observations are
diagnostic-only in this profile. They cannot support a throughput, latency,
energy, or full-efficiency claim, even when their raw values look favorable.
An ordinary exact-parent artifact rejected for noisy energy therefore stays
rejected by the ordinary profile while still being eligible to contribute
stable instruction evidence to this separate claim boundary.

Collect every ordinary row first, then aggregate the complete artifacts from a
clean tracked worktree:

```sh
~/Code/Home/lang/zig-out/bin/home-tool run tools/algorithmic-growth.ts \
  --family-prefix representative_frontend_compile_tdz_clear_ \
  --row 1024:docs/.data/exact-parent-tdz-clear-1024-YYYY-MM-DD.json \
  --row 2048:docs/.data/exact-parent-tdz-clear-2048-YYYY-MM-DD.json \
  --row 4096:docs/.data/exact-parent-tdz-clear-4096-YYYY-MM-DD.json \
  --raw-out docs/.data/algorithmic-growth-tdz-clear-YYYY-MM-DD.json \
  --markdown-out docs/.data/algorithmic-growth-tdz-clear-YYYY-MM-DD.md

~/Code/Home/lang/zig-out/bin/home-tool run tools/algorithmic-growth.ts \
  --artifact docs/.data/algorithmic-growth-tdz-clear-YYYY-MM-DD.json
```

The aggregate raw JSON embeds every exact-parent input losslessly and records
both the source-file and canonical embedded-artifact SHA-256. No sample is
discarded, extrapolated, rewritten, or replaced with an unavailable metric.

## Latest GC fragmentation and compaction

The [July 19, 2026 report](.data/gc-compaction-2026-07-19.md) preserves all
[14 raw samples](.data/gc-compaction-2026-07-19.tsv) from clean benchmark
commit `9f296900abc8adf33da4e18b24d6e8f628feddb4`. Explicit compaction reduced
retained backing from 8.81 MiB to 0.81 MiB and chunks from 141 to 13 (90.8%)
while preserving 6,559 live slots. Its median pause was 0.99 ms, and the
checksum-validated post-action probe was unchanged at 1.00x control throughput.

The dedicated compaction harness creates identical fresh GC contexts, retains a
large discard group followed by a smaller live tail, drops the first group, and
alternates non-moving control and explicit-compaction process order. It rejects
unequal starting heaps, backing growth, live-slot or checksum drift, missing
movement, and failure to reach an immediate dense `no_candidates` fixed point.

## Latest moving-nursery comparison

The [July 29, 2026 report](.data/gc-generation-2026-07-29.md) preserves all
[112 raw samples](.data/gc-generation-2026-07-29.tsv) from clean benchmark
commit `7e71eecff7a43bfb3a0b020d57231a7094790fb9`. Every moving row has an exact
non-moving parent with the same trigger, workload, age, sample, and checksum.
Across the forced single-mutator rows, moving age three measured 0.63–1.01x its
non-moving parents and 0.84–1.02x moving age one. The recorded moving age-three
rows copied 480.42 MiB with zero movement failures.

The shared rows run three mutators without a context GIL. Their moving age-three
median was 1,174.15 ms versus 939.65 ms for the exact non-moving parent
(0.80x), and the maximum recorded moving pause was 110.56 ms. The 14 shared
moving samples made 26 rendezvous attempts and completed 14 moving minors after
12 bounded retries; each row stayed within the enforced two-retry ceiling. Each
moving shared row also includes its one production automatic-compaction
follow-on, while conservative parents record no full collection or timeout.
Maximum elapsed RSD across the accepted matrix was 13.32%.

Use quick mode while changing the harness. A dated full run can preserve every
sample and its rendered report:

```sh
zig build gc-compaction-benchmark -Dgc-compaction-benchmark-quick=true
zig build gc-compaction-benchmark \
  -Dgc-compaction-benchmark-raw-out=docs/.data/gc-compaction-YYYY-MM-DD.tsv \
  -Dgc-compaction-benchmark-markdown-out=docs/.data/gc-compaction-YYYY-MM-DD.md
zig build gc-generation-benchmark -Dgc-generation-benchmark-quick=true
zig build gc-generation-benchmark \
  -Dgc-generation-benchmark-raw-out=docs/.data/gc-generation-YYYY-MM-DD.tsv \
  -Dgc-generation-benchmark-markdown-out=docs/.data/gc-generation-YYYY-MM-DD.md \
  -Dgc-generation-benchmark-update-readme=true
```

## Latest WebAssembly SIMD comparison

The [July 18, 2026 SIMD report](.data/wasm-simd-benchmark-2026-07-18.md)
preserves all [224 raw timing samples](.data/wasm-simd-benchmark-2026-07-18.tsv)
from clean benchmark inputs at zig-js commit
`7362c1e28c74f92b4c82e380a4ebcba038de5f1c`. It ran on an 11-core Apple M3
Pro using Zig `0.17.0-dev.956+2dca73595`, system JavaScriptCore framework
`22625.1.20.11.3`, and AC power. All 32 scored-row medians exceed 50 ms.

| family | zig-js 1 thread | zig-js 8 threads | zig-js scaling | JSC 1 thread | JSC 8 threads | JSC scaling | zig-js / JSC at 8 threads |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| integer | 7.73 M/s | 28.35 M/s | 3.67x | 62.02 M/s | 280.32 M/s | 4.52x | 0.10x |
| float | 7.06 M/s | 27.66 M/s | 3.92x | 63.66 M/s | 283.33 M/s | 4.45x | 0.10x |
| shuffle | 6.74 M/s | 29.00 M/s | 4.30x | 63.23 M/s | 286.75 M/s | 4.54x | 0.10x |
| memory | 8.98 M/s | 41.13 M/s | 4.58x | 53.32 M/s | 291.96 M/s | 5.48x | 0.14x |

`M/s` means millions of logical 128-bit state updates per second, normalized by
the exact inner-loop count. Each SIMD export has a semantically equivalent
scalar export in the same 1,166-byte module; the harness rejects disagreement
between them and between engines before scoring. At one zig-js thread, SIMD is
1.38x the scalar integer throughput, 1.27x float, 17.27x shuffle, and 1.69x
memory. Read those as instruction-path measurements: zig-js currently executes
all fixed-width SIMD through one portable architecture-independent
implementation, with no native per-architecture intrinsic path.

The one-thread timer covers only the exact warmed invocation. The eight-thread
timer covers symmetric dispatch, one invocation in each persistent worker-owned
context/module instance, and completion waits. Compilation, instantiation, and
three warm-ups are outside both timers. Independent contexts are the equivalent
public concurrency surface in both engines; zig-js shared-realm `Thread`s are a
different capability and are not folded into the cross-engine ratios.

Reproduce the dated matrix on macOS after building the two runners:

```sh
zig build benchmark-comparison-bin -Doptimize=ReleaseFast
home-tool run tools/wasm-simd-benchmark.ts --samples 7 --lanes 8 \
  --raw-out docs/.data/wasm-simd-benchmark-YYYY-MM-DD.tsv \
  --markdown-out docs/.data/wasm-simd-benchmark-YYYY-MM-DD.md
```

The readable module source is
[`bench/wasm_simd_kernels.wat`](../bench/wasm_simd_kernels.wat); the exact bytes
embedded in [`bench/wasm_simd_comparison.js`](../bench/wasm_simd_comparison.js)
were produced with pinned WABT 1.0.39 and have SHA-256
`5f33169c01f36873c1ac4ec8bb07675b8d4d770a6a4f3d961454f139f1818957`.

## Latest JavaScriptCore comparison

The [July 29, 2026 report](.data/benchmark-comparison-2026-07-29.md) preserves all [1,540 raw samples](.data/benchmark-comparison-2026-07-29.tsv). It was collected on AC power from clean zig-js commit `0f8b33c882eb53ad4d3111410d09fd71b15a10e9`, zig-gc `a09c01555f8b5e1485d8be5757864967942f699d`, and zig-regex `2de46683b948ec895e5fa9a9e7e4c384aceccdfe` using Zig `0.17.0-dev.1441+d5181a9c9` and system JavaScriptCore `22625.1.24.11.2`.

| mode | lanes | wins vs JSC | zig-js / JSC throughput | zig-js scaling | JSC scaling |
| --- | ---: | ---: | ---: | ---: | ---: |
| direct warmed context | 1 | 10 / 10 | **2.29x** | — | — |
| independent steady contexts | 8 | 9 / 10 | **2.51x** | **5.31x** | 4.83x |
| independent cold lifecycles | 8 | 9 / 10 | **2.61x** | **5.53x** | 4.89x |
| shared realm, no GIL | 8 | no public-JSC equivalent | — | **4.42x** | — |

The property rows favor zig-js directly by 2.79x (monomorphic) and 2.15x (four-shape polymorphic), and at eight warmed contexts by 3.06x and 2.32x. The [property CPU profile](.data/optimizer-property-profile-2026-07-21.md) attributes 46.2% of property leaves to generated code. The [exact-parent packed-array profile](.data/optimizer-array-profile-2026-07-22.md) confirms that the published arrays row still selects its guarded VM kernels. Ten reduced-size warm calls happen outside scored steady-state timers for both engines; cold lifecycle remains intentionally unwarmed. Equal checksums, alternating runner order, seven samples, and the 50 ms timing floor are enforced. Read per-row RSD in the report before interpreting small differences.

Object churn now wins directly at 130.957 ms versus JSC at 133.573 ms and
scales monotonically to 4.32x warmed and 4.62x cold. It remains the one
eight-lane independent loss: 242.790/255.224 ms versus JSC at
210.873/213.364 ms. The distinct shared-realm row reaches 0.74x at eight
lanes; [#97](https://github.com/zig-utils/zig-js/issues/97) tracks that final
sub-1.0x lane.
The historical [exact-parent slab A/B](.data/object-churn-128-byte-slab-ab-2026-07-15.md) and [amortized-publication A/B](.data/object-churn-amortized-publication-ab-2026-07-16.md) remain causal evidence for accepted changes. Three later candidates were rejected: [owned enumeration](.data/object-churn-owned-enumeration-ab-2026-07-18.md) and [sharded enumeration](.data/object-churn-sharded-enumeration-ab-2026-07-18.md) failed the eight-lane gate, while [sharded pressure accounting](.data/object-churn-pressure-accounting-ab-2026-07-18.md) regressed every lane. These focused runs do not replace the current complete matrix. Read the per-workload rows first; geometric means summarize one exact matrix and do not predict an application.

The July 29 [stable-identity exact-parent A/B](.data/object-churn-independent-id-block-ab-2026-07-29.md)
attributes that independent-context collapse to one process-global cell-ID CAS.
Non-recycled per-thread ID blocks improve the eight-lane steady median by
13.71x and cold by 14.14x, restore 4.12x/4.44x throughput scaling, preserve
checksums, and retain within 3.1%/1.1% of parent RSS. Its
[collapsed leaf profile](.data/object-churn-independent-profile-2026-07-29.tsv)
separates the publication hotspot from allocator, rendezvous, nursery, and
worker-lifecycle paths. The focused A/B does not replace the complete
zig-js/JavaScriptCore matrix.

Reproduce an exact-parent pair with:

```sh
~/Code/Home/lang/zig-out/bin/home-tool run tools/independent-object-churn-profile.ts /path/to/parent-runner \
  /path/to/candidate-runner \
  --parent-sample /tmp/parent.sample.txt \
  --candidate-sample /tmp/candidate.sample.txt \
  --raw-out /tmp/object-churn-independent.tsv \
  --profile-out /tmp/object-churn-independent-profile.tsv \
  --markdown-out /tmp/object-churn-independent.md \
  --zig-js-revision <revision> \
  --parent-gc-revision <revision> \
  --candidate-gc-revision <revision>
```

The opt-in #426 phase profiler keeps those exact workload bytes and checksums
while timing cooperative rendezvous, nursery prepare/trace/sweep, object-batch
allocation/publication, worker lifetime, and creator join. It does not enable
the per-object contention counters or alter normal benchmark output:

```sh
zig build benchmark-comparison-bin
~/Code/Home/lang/zig-out/bin/home-tool run tools/object-churn-gc-profile.ts zig-out/bin/bench-comparison-zig-js \
  --raw-out /tmp/object-churn-gc.tsv \
  --markdown-out /tmp/object-churn-gc.md
```

The July 21 [raw samples](.data/object-churn-gc-phases-2026-07-21.tsv) and
[summary](.data/object-churn-gc-phases-2026-07-21.md) attribute the eight-lane
collector pause primarily to nursery sweep. The resulting #427 whole-run
reclamation experiment was [rejected by its exact A/B](.data/object-churn-whole-run-reclamation-ab-2026-07-21.md):
it reduced sweep only 0.7% and regressed wall time 0.9%, so both activations
were reverted. These focused profiles do not replace the complete comparison
matrix or its README scores.

## What is compared

Both runners evaluate the exact source in [`bench/comparison.js`](../bench/comparison.js). Each workload returns an exactly representable integer checksum, and the driver rejects a run if a checksum changes between samples or differs across engines at the same lane count.

| workload | one job |
| --- | --- |
| `arithmetic` | 100,000 integer additions and modulo operations |
| `properties` | 25,000 rounds mutating four properties on one object |
| `polymorphic_properties` | 10,000 named-property read/modify/write rounds across four live receiver shapes |
| `object_churn` | initialize a 256-object lane-local ring, replace entries with 20,000 fresh three-property objects, read each displaced object, then checksum the bounded live tail |
| `arrays` | push 10,000 integers, then read and sum the array |
| `direct_calls` | 10,000 calls through a lane-local function binding |
| `method_calls` | 10,000 receiver-bound calls whose method reads `this.bias` |
| `closure_calls` | create and immediately call 10,000 fresh closures over a live mutable capture |
| `arguments_calls` | 10,000 calls whose callee reads both inputs through its real `arguments` object |
| `fibonacci` | recursively evaluate `fib(24)` while incrementing an invocation-local observable call counter |

The compared modes are intentionally explicit:

| label | execution model |
| --- | --- |
| direct single | one warmed context; one exact host evaluation call per sample |
| independent steady | one warmed creator-thread-owned context and persistent OS worker per lane; identical semaphore dispatch/evaluation/completion boundary in both runners |
| independent cold | one newly spawned OS worker and newly created context per lane; thread/context/source setup through context destruction and join is timed in both runners |
| zig-js shared | one context with two unrecorded full-work no-GIL shared-realm `Thread` invocations; recorded JavaScript thread creation, work, and join are timed |

The first three modes are cross-engine comparisons. JSC's public API does not expose zig-js's shared-realm `Thread` semantics, so the shared panel has no JSC ratio: zig-js lanes can see one object graph, while the comparable JSC embedding surface is isolated contexts.

## Timing protocol

The runners are separate executables. That prevents zig-js's JavaScriptCore-shaped C exports from interposing on the real framework symbols.

The current zig-js runner gives every measured context the same process-wide,
thread-safe libc allocator. Private contexts also use it for collector
pointer-stack and weak/barrier scratch; threaded and concurrent heaps retain the
process-global page allocator required by their cross-thread scratch access. This
is the
representative embedding setup: libc
reuses freed slabs across short-lived contexts instead of forcing each arena and
GC backing allocation through page-level `mmap`/`munmap`. The allocator process
exists for the whole runner, just as JSC's internal cached allocator does. Cold
mode still times every context-owned allocation and release; only reusable
allocator infrastructure is process-scoped. The saved July 15 report uses this
same allocator policy in every zig-js mode.

For every result group:

1. Build the runners in `ReleaseFast`.
2. In direct single mode, create/configure one context and make ten reduced-size warm-up calls outside the timer, then time the exact same `__benchmarkSelected(__benchmarkJobs, __benchmarkLane)` invocation bytes. Ten calls carry both runners past zig-js's current eight-entry optimizer threshold before scoring.
3. In independent steady mode, let every persistent OS worker create, configure, and warm its own thread-affine context. Time identical semaphore dispatch, one exact invocation per lane, and completion waits. Destroy workers and contexts after all samples.
4. In independent cold mode, perform no warm-up. Time OS-thread spawn, worker-owned context creation, source/configuration evaluation, the exact invocation, context destruction, and join.
5. In shared mode, configure one zig-js realm and run two unrecorded full-work shared `Thread` invocations outside the timer so one collect/reuse cycle completes before sampling, then time creation, execution, and join of JavaScript `Thread`s. Use the same shared path at one lane as its scaling baseline.
6. Alternate runner-process order deterministically for each directly compared matrix row, instead of always running one engine first.
7. Run seven samples sequentially and report median, min/max, and relative standard deviation. Preserve every sample in TSV form.
8. Reject a full row whose median is below 50 ms, then validate the exact expected matrix, sample indexes, within-run stability, and cross-engine checksum equality before rendering any table.
9. Record power source/state and refuse to publish raw/Markdown evidence from a dirty tracked worktree.

The runner does not pin CPUs, lock frequencies, disable background work, or discard outliers. Compare medians from the same host and power state, consult the raw range, and demand repeated evidence before treating a small delta as a regression.

## Reproduce

The JSC comparison requires macOS because it links the system `JavaScriptCore.framework`. On another target the build step fails with an explicit unsupported-platform message.

```sh
# Full seven-sample matrix, printed as Markdown.
zig build benchmark-comparison

# Save both the raw evidence and rendered dated report.
zig build benchmark-comparison \
  -Dbenchmark-comparison-raw-out=docs/.data/benchmark-comparison-YYYY-MM-DD.tsv \
  -Dbenchmark-comparison-markdown-out=docs/.data/benchmark-comparison-YYYY-MM-DD.md

# One reduced-size sample of every engine/mode/workload/lane combination.
zig build benchmark-comparison -Dbenchmark-comparison-quick=true

# Build the two machine-readable runners without executing the matrix.
zig build benchmark-comparison-bin

# Test matrix validation/publication guards without compiling or benchmarking.
zig build benchmark-comparison-test

# Regenerate the marker-delimited README scorecard from an accepted pair.
~/Code/Home/lang/zig-out/bin/home-tool run tools/benchmark-publication.ts \
  --current-raw docs/.data/benchmark-comparison-YYYY-MM-DD.tsv \
  --current-report docs/.data/benchmark-comparison-YYYY-MM-DD.md \
  --readme README.md

# Compare two controlled, like-for-like pairs and retain every row's delta.
~/Code/Home/lang/zig-out/bin/home-tool run tools/benchmark-publication.ts \
  --current-raw docs/.data/benchmark-comparison-current.tsv \
  --current-report docs/.data/benchmark-comparison-current.md \
  --baseline-raw docs/.data/benchmark-comparison-baseline.tsv \
  --baseline-report docs/.data/benchmark-comparison-baseline.md \
  --history-out docs/.data/benchmark-history-current-vs-baseline.md
```

Use quick mode while changing the harness. Run the full matrix once after related changes are assembled; it is measurement work, not a per-edit correctness test.

The publication tool first reruns the complete matrix, sample-index, timing-floor,
checksum, and workload-count validation and then reproduces the supplied report
byte for byte from its raw TSV. README replacement is marker-delimited and
idempotent. Historical comparison additionally requires exact host, OS, Zig,
zig-gc, zig-regex, JavaScriptCore, matrix, jobs, and sample-count matches. It
normalizes volatile battery details while preserving the power source and
charging state. Every engine row is retained with both medians,
both RSDs, and the delta. A zig-js row gates publication only when its median
worsens by more than 10% and both runs have at most 5% RSD; JSC rows remain
visible controls rather than gates.

The manual-only [Performance workflow](../.github/workflows/performance.yml)
runs the same full macOS/JSC matrix with configurable sample and lane counts,
then retains the raw TSV and rendered report as one 90-day Actions artifact.
It never runs on pushes or pull requests and does not gate ordinary CI: hosted
runner timing is evidence to inspect, not an automatic comparison with the
recorded M3 Pro baseline. Every workflow artifact includes a freshly generated
README scorecard. Supplying both optional baseline paths additionally produces
a per-row history report, or rejects the run when its controlled metadata does
not match. Promote a workflow artifact into `docs/.data` only after that review
and rerunning any causal candidate on the reference host.

## Build feedback evidence

[`tools/build-feedback.ts`](../tools/build-feedback.ts) measures the complete
developer feedback path without deleting or reusing the checkout's ordinary
build cache. V2 gives the library, focused-engine, combined-unit,
focused-engine TSan, and combined-unit TSan paths separate local/global cache
groups and install prefixes. Only adjacent phases in one named group reuse
state, so the two test artifacts have comparable cold and cached boundaries.
Completed groups are removed during collection to bound disk use. It runs these
phases in order:

1. a clean library/header build;
2. the immediate incremental cache-hit build;
3. the production-module frontend artifact from an empty cache, running all 12
   focused cases;
4. an exact one-case runtime filter against that cached focused artifact;
5. the combined Debug unit artifact from a separate empty cache, running one
   exact nonzero filter;
6. a different exact one-test filter against that cached combined artifact;
7. the complete unit suite with empty shard history;
8. the complete unit suite with the immediately preceding history;
9. the focused production-module TSan artifact from an empty cache; and
10. the combined TSan unit artifact from a separate empty cache.

Every raw sample retains the exact command, exit/timeout state, complete
stdout/stderr, Zig build summary, wall/user/system time, peak RSS, and (for
full-suite phases) the exact `plan.tsv`. `/usr/bin/time -lp` observes the whole
build process and its children; these are scenario-level process resources,
not invented compiler-internal phase counters. Samples run sequentially and no
outlier is discarded. V2 additionally rejects any cache-group drift, any
focused-engine denominator other than 12 for the cold run or one for the cached
and TSan runs, and any combined focused run that does not select exactly one
test from a positive linked inventory with zero skips, failures, or leaks. A
preflight before and postflight after every phase reject another active Zig
compiler/build-driver process outside the collector's own ancestor chain. A
competitor that appears while a command is running therefore leaves that row
only in an incomplete artifact. Any command, process-boundary, or
final-validation failure preserves the collected rows rather than publishing a
partial report.

```sh
zig build build-feedback-test
zig build build-feedback \
  -Dbuild-feedback-samples=3 \
  -Dbuild-feedback-jobs=10 \
  -Dbuild-feedback-raw-out=docs/.data/build-feedback-YYYY-MM-DD.json \
  -Dbuild-feedback-markdown-out=docs/.data/build-feedback-YYYY-MM-DD.md
```

The collector refuses dirty tracked zig-js, zig-gc, or zig-regex inputs and
records their exact revisions, the Zig executable/version, host/OS/CPU/memory,
and power state. A one-sample invocation is useful while changing the harness,
but it remains a diagnostic and is not promoted as repeated performance
evidence.

The first accepted three-sample collection is the
[`build-feedback-2026-08-09.md`](.data/build-feedback-2026-08-09.md) report and
its complete [`build-feedback-2026-08-09.json`](.data/build-feedback-2026-08-09.json)
raw artifact from clean revision `6582207afca3275981df29ca1d7d4604bba7e8db`
on the 11-core Apple M3 Pro reference host. Median clean library, first focused
unit relink, cold-history full unit, warm-history full unit, and focused TSan
walls were 67.08, 33.42, 214.08, 170.33, and 53.86 seconds respectively. The
immediate incremental library and cached focused-filter medians were 0.13 and
0.35 seconds. Read the report's ranges, CPU, peak RSS, exact command boundaries,
and full raw output before comparing a future run. That artifact remains the
accepted V1 history; V2 adds the isolated focused-engine comparison without
rewriting it.

## VM and tree-walker baseline

`zig build bench` remains the smaller internal baseline. It parses setup once, then times the same hot snippet through the bytecode VM and tree-walker. Its no-shared-state thread table answers whether aggregate compute throughput scales; the comparison suite above adds a second engine, repeat sampling, checksums, and a preserved report.

The latest saved internal run is [`docs/.data/bench-2026-07-04.txt`](.data/bench-2026-07-04.txt). Keep it separate from the JSC report so a VM/tree-walker change cannot silently rewrite the external comparison methodology.
