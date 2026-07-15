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

The latest saved run is the [July 14, 2026 report](.data/benchmark-comparison-2026-07-14.md), with all [1,540 raw timing samples](.data/benchmark-comparison-2026-07-14.tsv). It ran clean zig-js commit `9e832d19a577f18e3f1d75ff2cfe4f47123b8104`, zig-gc commit `9d4af0d49be5eba5b9283d5ed135fdf02626e2ac`, and zig-regex commit `5937fa7d4db0b69575c821066afd1a7da92aa019` on an 11-core Apple M3 Pro using Zig `0.17.0-dev.956+2dca73595` and the macOS 27.0 system JavaScriptCore framework `22625.1.20.11.3`. The machine was on battery power and discharging when the environment was captured. Work counts are identical for both engines, and every full-run median exceeds the 50 ms timing floor.

The saved single-thread medians are:

| workload | jobs | zig-js (ms) | JSC (ms) | zig-js / JSC throughput |
| --- | ---: | ---: | ---: | ---: |
| arithmetic | 240 | 84.666 | 360.032 | 4.25x |
| properties | 300 | 90.043 | 299.629 | 3.33x |
| polymorphic properties | 400 | 91.538 | 211.314 | 2.31x |
| object churn | 100 | 120.334 | 118.117 | 0.98x |
| arrays | 550 | 87.173 | 158.456 | 1.82x |
| direct calls | 600 | 64.822 | 131.926 | 2.04x |
| method calls | 500 | 65.177 | 142.794 | 2.19x |
| closure calls | 600 | 64.538 | 195.889 | 3.04x |
| arguments calls | 600 | 71.449 | 337.613 | 4.73x |
| Fibonacci | 125 | 85.262 | 469.077 | 5.50x |

A ratio above 1.00x favors zig-js; below 1.00x favors JSC.

The symmetric eight-lane steady-state rows are directly comparable:

| workload | zig-js (ms) | JSC (ms) | zig-js / JSC throughput | zig-js scaling | JSC scaling |
| --- | ---: | ---: | ---: | ---: | ---: |
| arithmetic | 110.350 | 553.636 | 5.02x | 6.21x | 5.16x |
| properties | 129.120 | 501.985 | 3.89x | 5.62x | 4.76x |
| polymorphic properties | 151.167 | 378.777 | 2.51x | 4.55x | 4.54x |
| object churn | 465.616 | 200.717 | 0.43x | 2.24x | 4.93x |
| arrays | 134.196 | 265.228 | 1.98x | 4.89x | 4.76x |
| direct calls | 95.484 | 212.386 | 2.22x | 5.42x | 4.62x |
| method calls | 106.249 | 242.312 | 2.28x | 4.88x | 4.72x |
| closure calls | 94.650 | 338.706 | 3.58x | 5.43x | 4.57x |
| arguments calls | 108.220 | 536.621 | 4.96x | 5.66x | 5.12x |
| Fibonacci | 129.324 | 732.437 | 5.66x | 5.43x | 5.14x |

The separate no-GIL shared-realm path has no direct public-JSC equivalent. Its one-to-eight-lane result is:

| workload | one lane (ms) | eight lanes (ms) | throughput scaling |
| --- | ---: | ---: | ---: |
| arithmetic | 86.075 | 109.816 | 6.27x |
| properties | 131.726 | 187.112 | 5.63x |
| polymorphic properties | 536.687 | 779.673 | 5.51x |
| object churn | 187.078 | 7,763.931 | 0.19x |
| arrays | 89.650 | 264.848 | 2.71x |
| direct calls | 67.072 | 94.030 | 5.71x |
| method calls | 122.013 | 193.290 | 5.05x |
| closure calls | 65.727 | 101.745 | 5.17x |
| arguments calls | 73.269 | 103.368 | 5.67x |
| Fibonacci | 241.373 | 410.751 | 4.70x |

zig-js wins 9 of 10 single-context rows. Its geometric-mean throughput lead is about 2.70x in direct single-context mode and 2.70x at eight warmed independent contexts. Mode-local eight-lane scaling is 4.88x for zig-js and 4.83x for JSC. The symmetric cold lifecycle has about a 2.78x zig-js throughput lead and scales 4.89x and 4.76x respectively. Shared-realm scaling is 3.64x by geometric mean. Object churn is the only direct loss, by 1.9%: 120.334 ms for zig-js versus 118.117 ms for JSC. zig-gc commit `9d4af0d` batches heap-wide live/young counter publication after sweeping while preserving immediate finalization, unlinking, header invalidation, backing release, and exact telemetry. Its order-balanced focused A/B was neutral direct (+0.057 ms paired median) and 9.734 ms faster at eight warmed independent contexts. This later full capture ran on battery, so it is not used for a small cross-power delta claim. Shared object churn remains the clearest GC/concurrency deficit, with 21.96% eight-lane RSD and 0.19x scaling. Read the per-workload rows first; geometric means summarize this exact matrix and do not predict an application.

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
