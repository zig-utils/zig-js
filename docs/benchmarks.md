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

The latest saved run is the [July 15, 2026 report](.data/benchmark-comparison-2026-07-15.md), with all [1,540 raw timing samples](.data/benchmark-comparison-2026-07-15.tsv). It ran clean zig-js commit `d2e29fa07c1d356c7a42bdb03477d00bc29344e5`, zig-gc commit `9d4af0d49be5eba5b9283d5ed135fdf02626e2ac`, and zig-regex commit `5937fa7d4db0b69575c821066afd1a7da92aa019` on an 11-core Apple M3 Pro using Zig `0.17.0-dev.956+2dca73595` and the macOS 27.0 system JavaScriptCore framework `22625.1.20.11.3`. The harness environment capture reported battery power at 78% and discharging; a pre-run snapshot had reported AC power while the battery was still discharging, so this run is not used for small cross-run delta claims. Work counts are identical for both engines, and every full-run median exceeds the 50 ms timing floor.

The saved single-thread medians are:

| workload | jobs | zig-js (ms) | JSC (ms) | zig-js / JSC throughput |
| --- | ---: | ---: | ---: | ---: |
| arithmetic | 240 | 86.330 | 352.091 | 4.08x |
| properties | 300 | 89.551 | 301.100 | 3.36x |
| polymorphic properties | 400 | 83.589 | 208.683 | 2.50x |
| object churn | 100 | 114.315 | 119.322 | 1.04x |
| arrays | 550 | 86.368 | 159.212 | 1.84x |
| direct calls | 600 | 58.342 | 117.842 | 2.02x |
| method calls | 500 | 63.555 | 147.657 | 2.32x |
| closure calls | 600 | 62.892 | 190.860 | 3.03x |
| arguments calls | 600 | 69.751 | 304.132 | 4.36x |
| Fibonacci | 125 | 82.003 | 444.825 | 5.42x |

A ratio above 1.00x favors zig-js; below 1.00x favors JSC.

The symmetric eight-lane steady-state rows are directly comparable:

| workload | zig-js (ms) | JSC (ms) | zig-js / JSC throughput | zig-js scaling | JSC scaling |
| --- | ---: | ---: | ---: | ---: | ---: |
| arithmetic | 111.545 | 571.040 | 5.12x | 6.40x | 4.98x |
| properties | 113.485 | 470.981 | 4.15x | 6.29x | 5.06x |
| polymorphic properties | 124.055 | 320.994 | 2.59x | 5.42x | 5.17x |
| object churn | 277.124 | 172.070 | 0.62x | 3.32x | 5.58x |
| arrays | 121.355 | 227.679 | 1.88x | 5.42x | 5.50x |
| direct calls | 84.196 | 199.053 | 2.36x | 5.62x | 4.77x |
| method calls | 89.132 | 223.712 | 2.51x | 6.06x | 5.53x |
| closure calls | 89.767 | 316.334 | 3.52x | 5.63x | 4.81x |
| arguments calls | 90.583 | 472.062 | 5.21x | 6.25x | 5.21x |
| Fibonacci | 120.513 | 664.877 | 5.52x | 5.77x | 5.53x |

The separate no-GIL shared-realm path has no direct public-JSC equivalent. Its one-to-eight-lane result is:

| workload | one lane (ms) | eight lanes (ms) | throughput scaling |
| --- | ---: | ---: | ---: |
| arithmetic | 84.392 | 108.462 | 6.22x |
| properties | 131.039 | 183.684 | 5.71x |
| polymorphic properties | 530.664 | 729.113 | 5.82x |
| object churn | 193.942 | 4,751.665 | 0.33x |
| arrays | 83.149 | 212.185 | 3.13x |
| direct calls | 57.254 | 92.215 | 4.97x |
| method calls | 125.000 | 181.041 | 5.52x |
| closure calls | 64.051 | 92.878 | 5.52x |
| arguments calls | 68.318 | 90.724 | 6.02x |
| Fibonacci | 247.624 | 375.215 | 5.28x |

zig-js wins all 10 single-context rows. Its geometric-mean throughput lead is about 2.70x direct and 2.86x at eight warmed independent contexts. Mode-local eight-lane scaling is 5.54x for zig-js and 5.21x for JSC. The symmetric cold lifecycle has about a 2.78x zig-js throughput lead and scales 5.29x and 5.08x respectively. Shared-realm scaling is 3.99x by geometric mean. Commit `d2e29fa0` makes private fixed-shape quick-loop checkpoints precise after their live accumulator, instruction pointer, and frame values have been materialized into registered roots; generic, shared, and native-stack paths remain conservative. Its order-balanced focused direct A/B was 17.9% faster in baseline-first order and 5.1% faster in candidate-first order, while warmed and shared checks were neutral within run-order variance. The full matrix now has object churn ahead direct at 114.315 ms versus 119.322 ms for JSC, but it remains the only JSC loss at eight warmed contexts (277.124 versus 172.070 ms) and in the cold eight-lane lifecycle (351.305 versus 179.788 ms). Shared object churn remains the clearest GC/concurrency deficit, with 24.30% eight-lane RSD and 0.33x scaling. Read the per-workload rows first; geometric means summarize this exact matrix and do not predict an application.

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
```

Use quick mode while changing the harness. Run the full matrix once after related changes are assembled; it is measurement work, not a per-edit correctness test.

## VM and tree-walker baseline

`zig build bench` remains the smaller internal baseline. It parses setup once, then times the same hot snippet through the bytecode VM and tree-walker. Its no-shared-state thread table answers whether aggregate compute throughput scales; the comparison suite above adds a second engine, repeat sampling, checksums, and a preserved report.

The latest saved internal run is [`docs/.data/bench-2026-07-04.txt`](.data/bench-2026-07-04.txt). Keep it separate from the JSC report so a VM/tree-walker change cannot silently rewrite the external comparison methodology.
