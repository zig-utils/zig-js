---
title: Performance Benchmarks
description: Reproduce and interpret zig-js direct, independent-context, shared-realm, and JavaScriptCore comparison measurements.
---

# Performance Benchmarks

zig-js keeps five benchmark families separate:

- `zig build bench` compares the bytecode VM with the tree-walking interpreter and prints a small no-shared-state thread-scaling table.
- `zig build benchmark-comparison` directly compares GC-enabled zig-js and JavaScriptCore in direct single-context, independent-context steady-state, and independent-context cold-lifecycle modes. It reports zig-js shared-realm no-GIL scaling in a separate capability panel.
- `python3 tools/wasm-simd-benchmark.py` compares representative integer, float, shuffle, and memory Wasm SIMD kernels with scalar exports from the same module and with the system JavaScriptCore, at one and eight independent warmed contexts.
- `zig build gc-compaction-benchmark` compares identical fragmented heaps before and after explicit compaction, preserving retained backing, pause, fixed-point, and post-action checksum evidence.
- `zig build gc-generation-benchmark` compares age-one and age-three nursery policies across ephemeral, mixed-survival, high-survival, automatic-threshold, and shared no-GIL workloads with exact cumulative generation telemetry.

None is an application benchmark or a universal engine score. They are small, inspectable baselines intended to reveal regressions, scaling limits, and the engine paths that deserve profiling.

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

The [July 22, 2026 property-OSR report](.data/benchmark-comparison-2026-07-22-property-osr.md) preserves all [1,540 raw samples](.data/benchmark-comparison-2026-07-22-property-osr.tsv). It was collected on AC power from clean zig-js commit `0c9b329aaa61b1ddb8f0018a82ed69173ded7f8d`, zig-gc `88ea25433d1841483a57567c80557df04146a53d`, and zig-regex `b8ca89df644976801e0b6444419444b708eeaa25` using Zig `0.17.0-dev.1441+d5181a9c9` and system JavaScriptCore `22625.1.20.11.3`.

| mode | lanes | wins vs JSC | zig-js / JSC throughput | zig-js scaling | JSC scaling |
| --- | ---: | ---: | ---: | ---: | ---: |
| direct warmed context | 1 | 10 / 10 | **2.16x** | — | — |
| independent steady contexts | 8 | 9 / 10 | **1.79x** | **3.86x** | 4.73x |
| independent cold lifecycles | 8 | 9 / 10 | **1.95x** | **4.04x** | 4.75x |
| shared realm, no GIL | 8 | no public-JSC equivalent | — | **3.85x** | — |

The property rows favor zig-js directly by 1.63x (monomorphic) and 2.22x (four-shape polymorphic), and at eight warmed contexts by 1.64x and 2.18x. The [exact CPU profile](.data/optimizer-property-profile-2026-07-21.md) attributes 46.2% of property leaves to generated code. Ten reduced-size warm calls happen outside scored steady-state timers for both engines; cold lifecycle remains intentionally unwarmed. Equal checksums, alternating runner order, seven samples, and the 50 ms timing floor are enforced. Read per-row RSD in the report before interpreting small differences.

Object churn is the one eight-lane loss: zig-js records 3,548.104 ms warmed and 3,438.036 ms cold versus JSC at 195.609 ms and 198.845 ms. [#445](https://github.com/zig-utils/zig-js/issues/445) tracks that current scaling bottleneck; the aggregate does not hide it. Cross-session changes are not causal evidence because the Zig, zig-gc, and zig-regex revisions differ from the July 17 run.
The historical [exact-parent slab A/B](.data/object-churn-128-byte-slab-ab-2026-07-15.md) and [amortized-publication A/B](.data/object-churn-amortized-publication-ab-2026-07-16.md) remain causal evidence for accepted changes. Three later candidates were rejected: [owned enumeration](.data/object-churn-owned-enumeration-ab-2026-07-18.md) and [sharded enumeration](.data/object-churn-sharded-enumeration-ab-2026-07-18.md) failed the eight-lane gate, while [sharded pressure accounting](.data/object-churn-pressure-accounting-ab-2026-07-18.md) regressed every lane. These focused runs do not replace the current complete matrix. Read the per-workload rows first; geometric means summarize one exact matrix and do not predict an application.

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
| zig-js shared | one warmed context with the shipping no-GIL shared-realm `Thread` API; JavaScript thread creation, work, and join are timed |

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
5. In shared mode, configure and warm one zig-js realm outside the timer, then time creation, execution, and join of JavaScript `Thread`s. Use the same shared path at one lane as its scaling baseline.
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
