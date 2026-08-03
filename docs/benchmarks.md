---
title: Performance Benchmarks
description: Reproduce and interpret zig-js direct, independent-context, shared-realm, and JavaScriptCore comparison measurements.
---

# Performance Benchmarks

zig-js keeps six benchmark families separate:

- `zig build bench` compares the bytecode VM with the tree-walking interpreter and prints a small no-shared-state thread-scaling table.
- `zig build benchmark-comparison` directly compares GC-enabled zig-js and JavaScriptCore in direct single-context, independent-context steady-state, and independent-context cold-lifecycle modes. It reports zig-js shared-realm no-GIL scaling in a separate capability panel.
- `zig build representative-benchmark` runs the versioned, dependency-free application-surface matrix from `docs/.data/representative-benchmark-matrix-v1.json`. Implemented rows and explicitly deferred families remain visible separately; quick mode is validation only.
- `python3 tools/wasm-simd-benchmark.py` compares representative integer, float, shuffle, and memory Wasm SIMD kernels with scalar exports from the same module and with the system JavaScriptCore, at one and eight independent warmed contexts.
- `zig build gc-compaction-benchmark` compares identical fragmented heaps before and after explicit compaction, preserving retained backing, pause, fixed-point, and post-action checksum evidence.
- `zig build gc-generation-benchmark` compares moving and non-moving age-one and age-three nursery policies across ephemeral, mixed-survival, high-survival, and shared no-GIL workloads with exact cumulative generation telemetry.

None is an application benchmark or a universal engine score. They are small, inspectable baselines intended to reveal regressions, scaling limits, and the engine paths that deserve profiling.

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
Metrics not connected yet remain explicitly unavailable. The tool refuses a
dirty tracked zig-js, zig-gc, or zig-regex worktree.

```sh
~/Code/Home/lang/zig-out/bin/home-tool run tools/exact-parent-regression.ts /path/to/parent-runner /path/to/candidate-runner \
  --parent-revision HEAD^ --candidate-revision HEAD \
  --source bench/representative_comparison.js \
  --mode single --workload representative_json --jobs 2200 --lanes 1 \
  --expected-checksum 324952086 --samples 7 \
  --timed-boundary "warmed persistent context; one exact invocation" \
  --raw-out docs/.data/exact-parent-YYYY-MM-DD.json \
  --markdown-out docs/.data/exact-parent-YYYY-MM-DD.md
```

The default host class is `diagnostic`, which never blocks publication. Only a
deliberately declared `quiet_reference` run gates: candidate wall time must be
more than 110% of its exact parent while both variants have at most 5% RSD.
Every smaller or noisier change remains in the artifact instead of being hidden.
Hosted CI validates schemas, migrations, checksums, and gate behavior without
executing reference-host measurements.

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
python3 tools/wasm-simd-benchmark.py --samples 7 --lanes 8 \
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
python3 tools/independent-object-churn-profile.py /path/to/parent-runner \
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
python3 tools/object-churn-gc-profile.py zig-out/bin/bench-comparison-zig-js \
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
python3 tools/benchmark-publication.py \
  --current-raw docs/.data/benchmark-comparison-YYYY-MM-DD.tsv \
  --current-report docs/.data/benchmark-comparison-YYYY-MM-DD.md \
  --readme README.md

# Compare two controlled, like-for-like pairs and retain every row's delta.
python3 tools/benchmark-publication.py \
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

## VM and tree-walker baseline

`zig build bench` remains the smaller internal baseline. It parses setup once, then times the same hot snippet through the bytecode VM and tree-walker. Its no-shared-state thread table answers whether aggregate compute throughput scales; the comparison suite above adds a second engine, repeat sampling, checksums, and a preserved report.

The latest saved internal run is [`docs/.data/bench-2026-07-04.txt`](.data/bench-2026-07-04.txt). Keep it separate from the JSC report so a VM/tree-walker change cannot silently rewrite the external comparison methodology.
