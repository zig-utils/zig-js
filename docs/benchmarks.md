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

The latest saved run is the [July 14, 2026 report](.data/benchmark-comparison-2026-07-14.md), with all [1,540 raw timing samples](.data/benchmark-comparison-2026-07-14.tsv). It ran clean commit `2dac7acaeef8fe45a8c9988226aa0ef8f6375712` on an 11-core Apple M3 Pro using Zig `0.17.0-dev.956+2dca73595` and the macOS 27.0 system JavaScriptCore framework `22625.1.20.11.3`. The machine was on battery power at 75% and discharging when the environment was captured. Work counts are identical for both engines, and every full-run median exceeds the 50 ms timing floor.

The saved single-thread medians are:

| workload | jobs | zig-js (ms) | JSC (ms) | zig-js / JSC throughput |
| --- | ---: | ---: | ---: | ---: |
| arithmetic | 240 | 75.493 | 345.936 | 4.58x |
| properties | 300 | 85.434 | 285.950 | 3.35x |
| polymorphic properties | 400 | 80.600 | 198.593 | 2.46x |
| object churn | 100 | 148.758 | 114.187 | 0.77x |
| arrays | 550 | 81.063 | 156.206 | 1.93x |
| direct calls | 600 | 56.518 | 118.742 | 2.10x |
| method calls | 500 | 60.936 | 136.774 | 2.24x |
| closure calls | 600 | 63.075 | 187.108 | 2.97x |
| arguments calls | 600 | 66.456 | 299.922 | 4.51x |
| Fibonacci | 125 | 82.211 | 458.377 | 5.58x |

A ratio above 1.00x favors zig-js; below 1.00x favors JSC.

The symmetric eight-lane steady-state rows are directly comparable:

| workload | zig-js (ms) | JSC (ms) | zig-js / JSC throughput | zig-js scaling | JSC scaling |
| --- | ---: | ---: | ---: | ---: | ---: |
| arithmetic | 100.466 | 481.092 | 4.79x | 6.54x | 5.91x |
| properties | 109.400 | 393.918 | 3.60x | 6.25x | 5.79x |
| polymorphic properties | 115.894 | 283.491 | 2.45x | 5.51x | 5.61x |
| object churn | 505.387 | 177.359 | 0.35x | 2.38x | 5.17x |
| arrays | 116.909 | 244.100 | 2.09x | 5.23x | 4.87x |
| direct calls | 79.470 | 192.317 | 2.42x | 5.81x | 4.90x |
| method calls | 92.473 | 226.364 | 2.45x | 5.50x | 4.91x |
| closure calls | 82.376 | 307.695 | 3.74x | 6.04x | 4.89x |
| arguments calls | 92.817 | 503.455 | 5.42x | 6.05x | 4.71x |
| Fibonacci | 120.485 | 693.256 | 5.75x | 5.54x | 5.18x |

The separate no-GIL shared-realm path has no direct public-JSC equivalent. Its one-to-eight-lane result is:

| workload | one lane (ms) | eight lanes (ms) | throughput scaling |
| --- | ---: | ---: | ---: |
| arithmetic | 80.947 | 98.987 | 6.54x |
| properties | 124.191 | 159.208 | 6.24x |
| polymorphic properties | 507.076 | 676.708 | 5.99x |
| object churn | 377.316 | 9,789.216 | 0.31x |
| arrays | 84.452 | 220.609 | 3.06x |
| direct calls | 57.317 | 77.657 | 5.90x |
| method calls | 122.815 | 183.377 | 5.36x |
| closure calls | 70.091 | 85.838 | 6.53x |
| arguments calls | 68.470 | 107.876 | 5.08x |
| Fibonacci | 243.452 | 385.353 | 5.05x |

zig-js wins 9 of 10 single-context rows. Its geometric-mean throughput lead is 2.69x in direct single-context mode and 2.71x at eight warmed independent contexts. Mode-local eight-lane scaling is 5.32x for zig-js and 5.18x for JSC. The symmetric cold lifecycle has a 2.77x zig-js throughput lead and scales 5.44x and 5.18x respectively. Shared-realm scaling is 4.06x by geometric mean. Object churn is the explicit exception: JSC leads the direct comparison and shared allocation/GC scaling remains below 1x. Servicing VM checkpoints without a generic fallback improved exact-parent object-churn medians by 16.57% direct, 20.39% at eight warmed independent contexts, and 9.02% at eight cold independent contexts. The shared path deliberately retains its previous checkpoint behavior; its full-publication variation is not attributed to this change. Read the per-workload rows first; geometric means summarize this exact matrix and do not predict an application.

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
