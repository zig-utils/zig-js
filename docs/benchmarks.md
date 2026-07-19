---
title: Performance Benchmarks
description: Reproduce and interpret zig-js direct, independent-context, shared-realm, and JavaScriptCore comparison measurements.
---

# Performance Benchmarks

zig-js keeps three benchmark families separate:

- `zig build bench` compares the bytecode VM with the tree-walking interpreter and prints a small no-shared-state thread-scaling table.
- `zig build benchmark-comparison` directly compares GC-enabled zig-js and JavaScriptCore in direct single-context, independent-context steady-state, and independent-context cold-lifecycle modes. It reports zig-js shared-realm no-GIL scaling in a separate capability panel.
- `python3 tools/wasm-simd-benchmark.py` compares representative integer, float, shuffle, and memory Wasm SIMD kernels with scalar exports from the same module and with the system JavaScriptCore, at one and eight independent warmed contexts.

None is an application benchmark or a universal engine score. They are small, inspectable baselines intended to reveal regressions, scaling limits, and the engine paths that deserve profiling.

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

The latest saved run is the [July 17, 2026 structured-stack report](.data/benchmark-comparison-2026-07-17-structured-stacks.md), with all [1,540 raw timing samples](.data/benchmark-comparison-2026-07-17-structured-stacks.tsv). It ran clean zig-js commit `01fcf42c9f6ca2b4e75a7cde13de748f9c037e04`, zig-gc commit `c67e344dd42e5246079a1c7835b9df3af42ff5e7`, and zig-regex commit `86159c5b9e0996ce6942b99d4ea76ed6c80a9a24` on an 11-core Apple M3 Pro using Zig `0.17.0-dev.956+2dca73595` and the macOS 27.0 system JavaScriptCore framework `22625.1.20.11.3`. The harness recorded AC power at 100% and charged. Work counts are identical for both engines, every full-run median exceeds the 50 ms timing floor, and runner order alternates. These controls make the within-run engine ratios comparable; read the saved min/max and RSD before interpreting small differences, and do not treat cross-session differences as causal.

| mode | lanes | wins vs JSC | zig-js / JSC throughput | zig-js scaling | JSC scaling |
| --- | ---: | ---: | ---: | ---: | ---: |
| direct warmed context | 1 | 10 / 10 | **2.43x** | — | — |
| independent steady contexts | 8 | 10 / 10 | **2.71x** | **4.67x** | 4.13x |
| independent cold lifecycles | 8 | 9 / 10 | **2.53x** | **4.40x** | 4.07x |
| shared realm, no GIL | 8 | no public-JSC equivalent | — | **3.84x** | — |

The saved single-thread medians are:

| workload | jobs | zig-js (ms) | JSC (ms) | zig-js / JSC throughput |
| --- | ---: | ---: | ---: | ---: |
| arithmetic | 240 | 85.429 | 358.819 | 4.20x |
| properties | 300 | 100.759 | 294.505 | 2.92x |
| polymorphic properties | 400 | 97.913 | 209.625 | 2.14x |
| object churn | 100 | 96.410 | 129.002 | 1.34x |
| arrays | 550 | 100.417 | 166.654 | 1.66x |
| direct calls | 600 | 81.097 | 122.462 | 1.51x |
| method calls | 500 | 86.833 | 148.788 | 1.71x |
| closure calls | 600 | 90.154 | 229.340 | 2.54x |
| arguments calls | 600 | 96.357 | 326.770 | 3.39x |
| Fibonacci | 125 | 90.338 | 489.696 | 5.42x |

A ratio above 1.00x favors zig-js; below 1.00x favors JSC.

The symmetric eight-lane steady-state rows are directly comparable:

| workload | zig-js (ms) | JSC (ms) | zig-js / JSC throughput | zig-js scaling | JSC scaling |
| --- | ---: | ---: | ---: | ---: | ---: |
| arithmetic | 106.607 | 593.386 | 5.57x | 6.29x | 4.80x |
| properties | 154.267 | 508.480 | 3.30x | 5.67x | 4.57x |
| polymorphic properties | 228.064 | 377.483 | 1.66x | 3.45x | 4.44x |
| object churn | 222.502 | 229.380 | 1.03x | 3.49x | 4.42x |
| arrays | 212.290 | 282.733 | 1.33x | 3.78x | 5.04x |
| direct calls | 127.018 | 246.439 | 1.94x | 5.11x | 3.98x |
| method calls | 141.173 | 279.008 | 1.98x | 4.92x | 4.29x |
| closure calls | 149.675 | 629.159 | 4.20x | 4.82x | 2.60x |
| arguments calls | 146.772 | 807.639 | 5.50x | 5.18x | 3.22x |
| Fibonacci | 149.289 | 851.687 | 5.70x | 4.82x | 4.65x |

The separate no-GIL shared-realm path has no direct public-JSC equivalent. Its one-to-eight-lane result is:

| workload | one lane (ms) | eight lanes (ms) | throughput scaling |
| --- | ---: | ---: | ---: |
| arithmetic | 1,559.626 | 2,336.735 | 5.34x |
| properties | 151.444 | 228.395 | 5.30x |
| polymorphic properties | 710.665 | 1,261.642 | 4.51x |
| object churn | 190.969 | 1,651.879 | 0.92x |
| arrays | 105.259 | 340.577 | 2.47x |
| direct calls | 92.705 | 141.091 | 5.26x |
| method calls | 164.730 | 280.145 | 4.70x |
| closure calls | 93.998 | 154.069 | 4.88x |
| arguments calls | 95.443 | 175.343 | 4.35x |
| Fibonacci | 305.889 | 538.814 | 4.54x |

zig-js wins 10/10 direct rows, 10/10 eight-lane warmed-independent rows, and 9/10 eight-lane cold-lifecycle rows. Its geometric-mean throughput lead is 2.43x direct, 2.71x at eight warmed independent contexts, and 2.53x across eight cold lifecycles. Mode-local eight-lane scaling is 4.67x for zig-js versus 4.13x for JSC when warmed and 4.40x versus 4.07x when cold. Shared-realm scaling is 3.84x by geometric mean.

Object instances occupy a 128-byte GC slab (`96` bytes of payload and `128` raw bytes including collector metadata). The accepted matrix reports object-churn medians of 96.410 versus 129.002 ms direct and 222.502 versus 229.380 ms across eight warmed contexts, both favoring zig-js. Its eight-lane cold-lifecycle result is the one symmetric-matrix loss: 243.603 versus 235.093 ms. Shared object churn is 1,651.879 ms at eight lanes with 0.92x scaling and 9.07% RSD. This is a visible scaling target, not something the geometric mean should obscure.

The historical [exact-parent slab A/B](.data/object-churn-128-byte-slab-ab-2026-07-15.md) and [amortized-publication A/B](.data/object-churn-amortized-publication-ab-2026-07-16.md) remain causal evidence for accepted changes. The [owned-enumeration A/B](.data/object-churn-owned-enumeration-ab-2026-07-18.md) records a rejected activation: four lanes improved 30%, but eight lanes did not improve. These focused runs do not replace the current complete matrix. Read the per-workload rows first; geometric means summarize one exact matrix and do not predict an application.

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
2. In direct single mode, create/configure one context and make three reduced-size warm-up calls outside the timer, then time the exact same `__benchmarkSelected(__benchmarkJobs, __benchmarkLane)` invocation bytes.
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
