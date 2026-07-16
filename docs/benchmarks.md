---
title: Performance Benchmarks
description: Reproduce and interpret zig-js direct, independent-context, shared-realm, and JavaScriptCore comparison measurements.
---

# Performance Benchmarks

zig-js keeps two benchmark families separate:

- `zig build bench` compares the bytecode VM with the tree-walking interpreter and prints a small no-shared-state thread-scaling table.
- `zig build benchmark-comparison` directly compares GC-enabled zig-js and JavaScriptCore in direct single-context, independent-context steady-state, and independent-context cold-lifecycle modes. It reports zig-js shared-realm no-GIL scaling in a separate capability panel.

Neither is an application benchmark or a universal engine score. They are small, inspectable baselines intended to reveal regressions, scaling limits, and the engine paths that deserve profiling.

## Latest JavaScriptCore comparison

The latest saved run is the [July 15, 2026 128-byte-slab report](.data/benchmark-comparison-2026-07-15-128-byte-slab.md), with all [1,540 raw timing samples](.data/benchmark-comparison-2026-07-15-128-byte-slab.tsv). It ran clean zig-js commit `12aa217c2f66c0fe7fa95e38ec414ea5ec15a993`, zig-gc commit `092d8d76b41b3c47c8cc4acb8646ee1d66879c20`, and zig-regex commit `50764b0352e73a434278de38825dbb55464f1cf6` on an 11-core Apple M3 Pro using Zig `0.17.0-dev.956+2dca73595` and the macOS 27.0 system JavaScriptCore framework `22625.1.20.11.3`. The harness recorded battery power at 74% and discharging. Work counts are identical for both engines, every full-run median exceeds the 50 ms timing floor, and runner order alternates. These controls make the within-run engine ratios comparable; read the saved min/max and RSD before interpreting small differences, and do not treat cross-session differences as causal.

| mode | lanes | wins vs JSC | zig-js / JSC throughput | zig-js scaling | JSC scaling |
| --- | ---: | ---: | ---: | ---: | ---: |
| direct warmed context | 1 | 10 / 10 | **2.67x** | — | — |
| independent steady contexts | 8 | 10 / 10 | **2.95x** | **5.14x** | 4.77x |
| independent cold lifecycles | 8 | 10 / 10 | **2.91x** | **5.18x** | 4.76x |
| shared realm, no GIL | 8 | no public-JSC equivalent | — | **3.97x** | — |

The saved single-thread medians are:

| workload | jobs | zig-js (ms) | JSC (ms) | zig-js / JSC throughput |
| --- | ---: | ---: | ---: | ---: |
| arithmetic | 240 | 91.807 | 356.516 | 3.88x |
| properties | 300 | 98.723 | 301.017 | 3.05x |
| polymorphic properties | 400 | 100.367 | 214.948 | 2.14x |
| object churn | 100 | 101.799 | 123.020 | 1.21x |
| arrays | 550 | 89.919 | 161.737 | 1.80x |
| direct calls | 600 | 59.878 | 125.692 | 2.10x |
| method calls | 500 | 66.639 | 144.348 | 2.17x |
| closure calls | 600 | 65.634 | 198.020 | 3.02x |
| arguments calls | 600 | 71.725 | 317.639 | 4.43x |
| Fibonacci | 125 | 86.891 | 471.204 | 5.42x |

A ratio above 1.00x favors zig-js; below 1.00x favors JSC.

The symmetric eight-lane steady-state rows are directly comparable:

| workload | zig-js (ms) | JSC (ms) | zig-js / JSC throughput | zig-js scaling | JSC scaling |
| --- | ---: | ---: | ---: | ---: | ---: |
| arithmetic | 110.972 | 597.356 | 5.38x | 5.99x | 4.72x |
| properties | 137.042 | 544.779 | 3.98x | 5.74x | 4.53x |
| polymorphic properties | 161.032 | 378.132 | 2.35x | 4.75x | 4.54x |
| object churn | 168.520 | 185.412 | 1.10x | 4.17x | 5.19x |
| arrays | 141.976 | 268.272 | 1.89x | 5.03x | 4.79x |
| direct calls | 94.218 | 209.355 | 2.22x | 5.08x | 4.66x |
| method calls | 102.515 | 236.261 | 2.30x | 5.17x | 4.90x |
| closure calls | 95.660 | 340.897 | 3.56x | 5.48x | 4.61x |
| arguments calls | 112.923 | 536.181 | 4.75x | 5.05x | 4.71x |
| Fibonacci | 134.122 | 748.166 | 5.58x | 5.19x | 5.05x |

The separate no-GIL shared-realm path has no direct public-JSC equivalent. Its one-to-eight-lane result is:

| workload | one lane (ms) | eight lanes (ms) | throughput scaling |
| --- | ---: | ---: | ---: |
| arithmetic | 88.521 | 112.673 | 6.29x |
| properties | 141.647 | 232.852 | 4.87x |
| polymorphic properties | 605.891 | 842.059 | 5.76x |
| object churn | 146.979 | 1,671.114 | 0.70x |
| arrays | 93.659 | 392.151 | 1.91x |
| direct calls | 60.123 | 87.493 | 5.50x |
| method calls | 155.268 | 223.915 | 5.55x |
| closure calls | 67.047 | 95.213 | 5.63x |
| arguments calls | 71.888 | 120.298 | 4.78x |
| Fibonacci | 296.225 | 469.612 | 5.05x |

zig-js wins all 10 direct rows and all 10 eight-lane rows in both directly comparable multi-context modes. Its geometric-mean throughput lead is 2.67x direct, 2.95x at eight warmed independent contexts, and 2.91x across eight cold lifecycles. Mode-local eight-lane scaling is 5.14x for zig-js versus 4.77x for JSC when warmed and 5.18x versus 4.76x when cold. Shared-realm scaling is 3.97x by geometric mean.

Object instances now occupy a 128-byte GC slab (`96` bytes of payload and `128` raw bytes including collector metadata). One lazy storage wrapper owns cold/exotic state, external named-slot metadata, dense/internal element metadata, and backing-allocator bookkeeping; a plain object with four or fewer named properties keeps its values entirely inline and allocates none of those side states. Current object buckets use 256 KiB chunks, avoiding repeated allocator and synchronized address-index growth without exceeding the fixed reuse bitmap. The accepted matrix reports object-churn medians of 101.799 versus 123.020 ms direct, 168.520 versus 185.412 ms at eight warmed contexts, and 181.819 versus 190.980 ms across cold eight-context lifecycles. Shared object churn is 1,671.114 ms at eight lanes with 0.70x scaling and 7.24% RSD. The [exact-parent A/B](.data/object-churn-128-byte-slab-ab-2026-07-15.md) isolates the slab crossing from session noise and shows a faster candidate in every measured mode. Read the per-workload rows first; geometric means summarize this exact matrix and do not predict an application.

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
