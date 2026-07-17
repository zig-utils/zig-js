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

The latest saved run is the [July 17, 2026 VM-run-lease report](.data/benchmark-comparison-2026-07-17-vm-run-leases.md), with all [1,540 raw timing samples](.data/benchmark-comparison-2026-07-17-vm-run-leases.tsv). It ran clean zig-js commit `ee079b274761916628c74fe6f76c28016d447caa`, zig-gc commit `87c5297e5e442b1f60fe14cab6484e44fd65c988`, and zig-regex commit `50764b0352e73a434278de38825dbb55464f1cf6` on an 11-core Apple M3 Pro using Zig `0.17.0-dev.956+2dca73595` and the macOS 27.0 system JavaScriptCore framework `22625.1.20.11.3`. The harness recorded battery power at 83% and discharging. Work counts are identical for both engines, every full-run median exceeds the 50 ms timing floor, and runner order alternates. These controls make the within-run engine ratios comparable; read the saved min/max and RSD before interpreting small differences, and do not treat cross-session differences as causal.

| mode | lanes | wins vs JSC | zig-js / JSC throughput | zig-js scaling | JSC scaling |
| --- | ---: | ---: | ---: | ---: | ---: |
| direct warmed context | 1 | 10 / 10 | **2.38x** | — | — |
| independent steady contexts | 8 | 9 / 10 | **2.36x** | **4.86x** | 5.00x |
| independent cold lifecycles | 8 | 10 / 10 | **2.61x** | **5.41x** | 4.82x |
| shared realm, no GIL | 8 | no public-JSC equivalent | — | **4.24x** | — |

The saved single-thread medians are:

| workload | jobs | zig-js (ms) | JSC (ms) | zig-js / JSC throughput |
| --- | ---: | ---: | ---: | ---: |
| arithmetic | 240 | 82.620 | 351.164 | 4.25x |
| properties | 300 | 95.347 | 291.019 | 3.05x |
| polymorphic properties | 400 | 97.700 | 209.031 | 2.14x |
| object churn | 100 | 89.223 | 120.483 | 1.35x |
| arrays | 550 | 91.493 | 152.330 | 1.66x |
| direct calls | 600 | 77.444 | 119.702 | 1.55x |
| method calls | 500 | 89.819 | 137.087 | 1.53x |
| closure calls | 600 | 90.125 | 209.932 | 2.33x |
| arguments calls | 600 | 91.467 | 309.319 | 3.38x |
| Fibonacci | 125 | 92.864 | 465.310 | 5.01x |

A ratio above 1.00x favors zig-js; below 1.00x favors JSC.

The symmetric eight-lane steady-state rows are directly comparable:

| workload | zig-js (ms) | JSC (ms) | zig-js / JSC throughput | zig-js scaling | JSC scaling |
| --- | ---: | ---: | ---: | ---: | ---: |
| arithmetic | 111.897 | 522.087 | 4.67x | 5.93x | 5.36x |
| properties | 125.562 | 443.502 | 3.53x | 6.06x | 5.24x |
| polymorphic properties | 155.439 | 339.326 | 2.18x | 4.84x | 4.80x |
| object churn | 210.643 | 180.245 | 0.86x | 3.40x | 5.34x |
| arrays | 186.876 | 242.845 | 1.30x | 3.86x | 5.05x |
| direct calls | 101.823 | 180.444 | 1.77x | 6.15x | 5.27x |
| method calls | 189.252 | 238.313 | 1.26x | 3.32x | 4.60x |
| closure calls | 140.620 | 354.540 | 2.52x | 4.92x | 4.43x |
| arguments calls | 121.729 | 536.569 | 4.41x | 6.02x | 4.58x |
| Fibonacci | 129.989 | 714.533 | 5.50x | 5.30x | 5.47x |

The separate no-GIL shared-realm path has no direct public-JSC equivalent. Its one-to-eight-lane result is:

| workload | one lane (ms) | eight lanes (ms) | throughput scaling |
| --- | ---: | ---: | ---: |
| arithmetic | 1,474.047 | 1,942.086 | 6.07x |
| properties | 137.291 | 205.062 | 5.36x |
| polymorphic properties | 600.163 | 860.929 | 5.58x |
| object churn | 167.593 | 1,648.219 | 0.81x |
| arrays | 96.868 | 304.039 | 2.55x |
| direct calls | 81.718 | 101.724 | 6.43x |
| method calls | 169.037 | 307.492 | 4.40x |
| closure calls | 106.139 | 117.515 | 7.23x |
| arguments calls | 91.813 | 129.560 | 5.67x |
| Fibonacci | 302.461 | 566.443 | 4.27x |

zig-js wins 10/10 direct rows, 9/10 eight-lane warmed-independent rows, and 10/10 eight-lane cold-lifecycle rows. Its geometric-mean throughput lead is 2.38x direct, 2.36x at eight warmed independent contexts, and 2.61x across eight cold lifecycles. Mode-local eight-lane scaling is 4.86x for zig-js versus 5.00x for JSC when warmed and 5.41x versus 4.82x when cold. Shared-realm scaling is 4.24x by geometric mean.

Object instances occupy a 128-byte GC slab (`96` bytes of payload and `128` raw bytes including collector metadata). The accepted matrix reports object-churn medians of 89.223 versus 120.483 ms direct and 163.456 versus 191.581 ms across eight cold lifecycles, both favoring zig-js. Its warmed eight-context result is the one symmetric-matrix loss: 210.643 versus 180.245 ms. Shared object churn is 1,648.219 ms at eight lanes with 0.81x scaling and 13.22% RSD. This is a visible scaling target, not something the geometric mean should obscure.

The historical [exact-parent slab A/B](.data/object-churn-128-byte-slab-ab-2026-07-15.md) and [amortized-publication A/B](.data/object-churn-amortized-publication-ab-2026-07-16.md) remain causal evidence for those individual changes. They do not replace the current complete matrix. Read the per-workload rows first; geometric means summarize one exact matrix and do not predict an application.

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
