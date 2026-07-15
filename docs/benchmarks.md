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

The latest saved run is the [July 14, 2026 report](.data/benchmark-comparison-2026-07-14.md), with all [1,540 raw timing samples](.data/benchmark-comparison-2026-07-14.tsv). It ran clean commit `6ec1fbd6fb931166a33f23d1754f4d30b8d056ee` on an 11-core Apple M3 Pro using Zig `0.17.0-dev.956+2dca73595` and the macOS 27.0 system JavaScriptCore framework `22625.1.20.11.3`. The machine was on battery power at 100% when the environment was captured. Work counts are identical for both engines, and every full-run median exceeds the 50 ms timing floor.

The saved single-thread medians are:

| workload | jobs | zig-js (ms) | JSC (ms) | zig-js / JSC throughput |
| --- | ---: | ---: | ---: | ---: |
| arithmetic | 240 | 76.500 | 350.458 | 4.58x |
| properties | 300 | 85.833 | 291.590 | 3.40x |
| polymorphic properties | 400 | 80.304 | 199.006 | 2.48x |
| object churn | 100 | 121.638 | 118.874 | 0.98x |
| arrays | 550 | 79.563 | 149.144 | 1.87x |
| direct calls | 600 | 58.278 | 120.848 | 2.07x |
| method calls | 500 | 60.132 | 136.643 | 2.27x |
| closure calls | 600 | 62.488 | 188.349 | 3.01x |
| arguments calls | 600 | 66.725 | 294.830 | 4.42x |
| Fibonacci | 125 | 84.692 | 451.621 | 5.33x |

A ratio above 1.00x favors zig-js; below 1.00x favors JSC.

The symmetric eight-lane steady-state rows are directly comparable:

| workload | zig-js (ms) | JSC (ms) | zig-js / JSC throughput | zig-js scaling | JSC scaling |
| --- | ---: | ---: | ---: | ---: | ---: |
| arithmetic | 99.466 | 482.166 | 4.85x | 6.21x | 5.73x |
| properties | 108.819 | 395.362 | 3.63x | 6.29x | 5.77x |
| polymorphic properties | 115.477 | 284.281 | 2.46x | 5.59x | 5.84x |
| object churn | 374.015 | 180.793 | 0.48x | 2.59x | 5.12x |
| arrays | 118.462 | 224.090 | 1.89x | 5.20x | 5.33x |
| direct calls | 77.225 | 182.380 | 2.36x | 6.34x | 5.16x |
| method calls | 87.356 | 206.942 | 2.37x | 5.88x | 5.31x |
| closure calls | 82.656 | 300.997 | 3.64x | 6.06x | 4.96x |
| arguments calls | 91.143 | 486.699 | 5.34x | 5.87x | 4.83x |
| Fibonacci | 112.031 | 657.463 | 5.87x | 6.13x | 5.59x |

The separate no-GIL shared-realm path has no direct public-JSC equivalent. Its one-to-eight-lane result is:

| workload | one lane (ms) | eight lanes (ms) | throughput scaling |
| --- | ---: | ---: | ---: |
| arithmetic | 77.473 | 100.215 | 6.18x |
| properties | 123.980 | 163.750 | 6.06x |
| polymorphic properties | 522.440 | 725.053 | 5.76x |
| object churn | 216.556 | 5,800.683 | 0.30x |
| arrays | 79.766 | 192.023 | 3.32x |
| direct calls | 57.137 | 76.208 | 6.00x |
| method calls | 116.376 | 203.498 | 4.58x |
| closure calls | 68.744 | 93.205 | 5.90x |
| arguments calls | 66.408 | 93.069 | 5.71x |
| Fibonacci | 249.606 | 380.241 | 5.25x |

zig-js wins 9 of 10 single-context rows. Its geometric-mean throughput lead is 2.74x in direct single-context mode and 2.76x at eight warmed independent contexts. Mode-local eight-lane scaling is 5.47x for zig-js and 5.35x for JSC. The symmetric cold lifecycle has a 2.65x zig-js throughput lead and scales 5.38x and 5.26x respectively. Shared-realm scaling is 4.00x by geometric mean. Object churn is the only direct loss, now 2.3%: 121.638 ms for zig-js versus 118.874 ms for JSC. The weak-pass gate proves that a context has no weak semantic state before skipping ephemeron, weak-slot, and after-weak processing. An exact pre-hook/current-pair A/B measured 24.4% lower direct object-churn time and 38–40% lower shared time at every lane count, with matching checksums. Against the previous full publication, direct object churn fell 18.5% and shared 1/2/4/8-lane wall time fell 38.2%/38.4%/40.7%/24.3%. Shared object-churn scaling remains below 1x and its 14–45% RSD makes it the next explicit GC/concurrency target. Read the per-workload rows first; geometric means summarize this exact matrix and do not predict an application.

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
thread-safe libc allocator. This is the representative embedding setup: libc
reuses freed slabs across short-lived contexts instead of forcing each arena and
GC backing allocation through page-level `mmap`/`munmap`. The allocator process
exists for the whole runner, just as JSC's internal cached allocator does. Cold
mode still times every context-owned allocation and release; only reusable
allocator infrastructure is process-scoped. The saved July 14 report uses this
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
```

Use quick mode while changing the harness. Run the full matrix once after related changes are assembled; it is measurement work, not a per-edit correctness test.

## VM and tree-walker baseline

`zig build bench` remains the smaller internal baseline. It parses setup once, then times the same hot snippet through the bytecode VM and tree-walker. Its no-shared-state thread table answers whether aggregate compute throughput scales; the comparison suite above adds a second engine, repeat sampling, checksums, and a preserved report.

The latest saved internal run is [`docs/.data/bench-2026-07-04.txt`](.data/bench-2026-07-04.txt). Keep it separate from the JSC report so a VM/tree-walker change cannot silently rewrite the external comparison methodology.
