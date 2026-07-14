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

The latest saved run is the [July 14, 2026 report](.data/benchmark-comparison-2026-07-14.md), with all [1,540 raw timing samples](.data/benchmark-comparison-2026-07-14.tsv). It ran clean commit `4e3de6f53853d6ae241132985e277096a1a24597` on an 11-core Apple M3 Pro using Zig `0.17.0-dev.956+2dca73595` and the macOS 27.0 system JavaScriptCore framework `22625.1.20.11.3`. The machine was on battery power at 93% and discharging when the environment was captured. Work counts are identical for both engines, and every full-run median exceeds the 50 ms timing floor.

The saved single-thread medians are:

| workload | jobs | zig-js (ms) | JSC (ms) | zig-js / JSC throughput |
| --- | ---: | ---: | ---: | ---: |
| arithmetic | 240 | 83.971 | 344.822 | 4.11x |
| properties | 300 | 88.214 | 295.844 | 3.35x |
| polymorphic properties | 400 | 81.608 | 198.403 | 2.43x |
| object churn | 100 | 176.398 | 116.168 | 0.66x |
| arrays | 550 | 81.078 | 158.210 | 1.95x |
| direct calls | 600 | 56.462 | 117.743 | 2.09x |
| method calls | 500 | 72.504 | 136.747 | 1.89x |
| closure calls | 600 | 64.665 | 210.548 | 3.26x |
| arguments calls | 600 | 70.965 | 295.125 | 4.16x |
| Fibonacci | 125 | 83.211 | 447.072 | 5.37x |

A ratio above 1.00x favors zig-js; below 1.00x favors JSC.

The symmetric eight-lane steady-state rows are directly comparable:

| workload | zig-js (ms) | JSC (ms) | zig-js / JSC throughput | zig-js scaling | JSC scaling |
| --- | ---: | ---: | ---: | ---: | ---: |
| arithmetic | 101.773 | 482.515 | 4.74x | 5.99x | 5.71x |
| properties | 116.082 | 396.810 | 3.42x | 6.11x | 5.74x |
| polymorphic properties | 123.384 | 288.752 | 2.34x | 5.30x | 5.51x |
| object churn | 543.223 | 172.520 | 0.32x | 2.63x | 5.29x |
| arrays | 117.231 | 230.295 | 1.96x | 5.27x | 5.27x |
| direct calls | 74.279 | 175.791 | 2.37x | 6.07x | 5.34x |
| method calls | 94.982 | 207.752 | 2.19x | 5.18x | 5.26x |
| closure calls | 97.397 | 321.771 | 3.30x | 5.13x | 4.74x |
| arguments calls | 96.319 | 473.689 | 4.92x | 5.56x | 5.02x |
| Fibonacci | 117.196 | 659.069 | 5.62x | 5.72x | 5.44x |

The separate no-GIL shared-realm path has no direct public-JSC equivalent. Its one-to-eight-lane result is:

| workload | one lane (ms) | eight lanes (ms) | throughput scaling |
| --- | ---: | ---: | ---: |
| arithmetic | 78.691 | 104.988 | 6.00x |
| properties | 123.939 | 160.016 | 6.20x |
| polymorphic properties | 520.453 | 692.200 | 6.02x |
| object churn | 374.794 | 9,203.183 | 0.33x |
| arrays | 92.151 | 232.684 | 3.17x |
| direct calls | 56.468 | 78.439 | 5.76x |
| method calls | 115.302 | 175.250 | 5.26x |
| closure calls | 67.827 | 85.510 | 6.35x |
| arguments calls | 66.970 | 95.524 | 5.61x |
| Fibonacci | 243.440 | 366.814 | 5.31x |

zig-js wins 9 of 10 single-context rows. Its geometric-mean throughput lead is 2.56x in direct single-context mode and 2.54x at eight warmed independent contexts. Mode-local eight-lane scaling is 5.18x for zig-js and 5.32x for JSC. The symmetric cold lifecycle has a 2.58x zig-js throughput lead and scales 5.29x and 5.25x respectively. Shared-realm scaling is 4.09x by geometric mean. Object churn is the explicit exception: JSC leads the direct comparison and shared allocation/GC scaling remains below 1x. Per-chunk free-state tracking improved the exact-parent direct median by 7.37% and the decision-load shared median by 2.96%; compared with the previous full publication, the direct median fell from 197.469 to 176.398 ms (10.7%) and the shared eight-lane median fell from 11,089.300 to 9,203.183 ms (17.0%). The exact-parent comparison is the causal measurement; the cross-publication change also includes ordinary host/run variation. Read the per-workload rows first; geometric means summarize this exact matrix and do not predict an application.

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
