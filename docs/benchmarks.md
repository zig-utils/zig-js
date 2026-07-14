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

The latest saved run is the [July 14, 2026 report](.data/benchmark-comparison-2026-07-14.md), with all [1,540 raw timing samples](.data/benchmark-comparison-2026-07-14.tsv). It ran clean commit `c98a36c455848dc464bef9d0c40ccb9639dbc2df` on an 11-core Apple M3 Pro using Zig `0.17.0-dev.956+2dca73595` and the macOS 27.0 system JavaScriptCore framework `22625.1.20.11.3`. The machine was on AC power and fully charged when the environment was captured. Work counts are identical for both engines and were conservatively recalibrated so the fastest full-run rows retain margin above the 50 ms timing floor.

The saved single-thread medians are:

| workload | jobs | zig-js (ms) | JSC (ms) | zig-js / JSC throughput |
| --- | ---: | ---: | ---: | ---: |
| arithmetic | 240 | 88.764 | 348.910 | 3.93x |
| properties | 300 | 87.972 | 289.043 | 3.29x |
| polymorphic properties | 400 | 81.124 | 202.880 | 2.50x |
| object churn | 100 | 197.469 | 119.400 | 0.60x |
| arrays | 550 | 78.073 | 147.870 | 1.89x |
| direct calls | 600 | 56.532 | 118.268 | 2.09x |
| method calls | 500 | 60.881 | 137.290 | 2.25x |
| closure calls | 600 | 61.843 | 186.502 | 3.02x |
| arguments calls | 600 | 66.822 | 293.922 | 4.40x |
| Fibonacci | 125 | 83.070 | 453.216 | 5.46x |

A ratio above 1.00x favors zig-js; below 1.00x favors JSC.

The symmetric eight-lane steady-state rows are directly comparable:

| workload | zig-js (ms) | JSC (ms) | zig-js / JSC throughput | zig-js scaling | JSC scaling |
| --- | ---: | ---: | ---: | ---: | ---: |
| arithmetic | 102.917 | 512.033 | 4.98x | 6.40x | 5.45x |
| properties | 113.895 | 434.044 | 3.81x | 6.40x | 5.48x |
| polymorphic properties | 121.178 | 338.869 | 2.80x | 5.34x | 4.82x |
| object churn | 714.208 | 169.960 | 0.24x | 2.17x | 5.54x |
| arrays | 117.506 | 235.293 | 2.00x | 5.54x | 5.31x |
| direct calls | 77.983 | 190.953 | 2.45x | 5.71x | 4.82x |
| method calls | 85.761 | 213.969 | 2.49x | 5.70x | 5.13x |
| closure calls | 83.235 | 307.948 | 3.70x | 5.91x | 4.91x |
| arguments calls | 97.371 | 494.148 | 5.07x | 5.48x | 4.80x |
| Fibonacci | 135.307 | 749.786 | 5.54x | 4.88x | 4.84x |

The separate no-GIL shared-realm path has no direct public-JSC equivalent. Its one-to-eight-lane result is:

| workload | one lane (ms) | eight lanes (ms) | throughput scaling |
| --- | ---: | ---: | ---: |
| arithmetic | 83.473 | 102.441 | 6.52x |
| properties | 125.505 | 166.612 | 6.03x |
| polymorphic properties | 519.222 | 717.062 | 5.79x |
| object churn | 399.682 | 11,089.300 | 0.29x |
| arrays | 80.226 | 232.296 | 2.76x |
| direct calls | 55.595 | 78.896 | 5.64x |
| method calls | 114.588 | 176.190 | 5.20x |
| closure calls | 63.255 | 85.257 | 5.94x |
| arguments calls | 69.610 | 103.016 | 5.41x |
| Fibonacci | 236.729 | 409.887 | 4.62x |

zig-js wins 9 of 10 single-context rows. Its geometric-mean throughput lead is 2.56x in direct single-context mode and 2.63x at eight warmed independent contexts. Mode-local eight-lane scaling is 5.16x for zig-js and 5.10x for JSC. The symmetric cold lifecycle has a 2.63x zig-js throughput lead and scales 5.13x and 5.01x respectively. Shared-realm scaling is 3.89x by geometric mean. Object churn is the explicit exception: JSC leads the direct comparison and shared allocation/GC scaling remains below 1x. The bounded tail-freelist rebuild reduced the exact-parent eight-lane shared median by 12.2%; in the complete publication, object churn improved from 12,368.464 ms to 11,089.300 ms (10.3%), while its faster one-lane baseline leaves reported scaling at 0.29x. Read the per-workload rows first; geometric means summarize this exact matrix and do not predict an application.

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
