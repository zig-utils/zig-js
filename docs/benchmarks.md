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

The latest saved run is the [July 14, 2026 report](.data/benchmark-comparison-2026-07-14.md), with all [1,540 raw timing samples](.data/benchmark-comparison-2026-07-14.tsv). It ran clean commit `0679295d2f8ebcaf8363e962ebfed9a007943b2d` on an 11-core Apple M3 Pro using Zig `0.17.0-dev.956+2dca73595` and the macOS 27.0 system JavaScriptCore framework `22625.1.20.11.3`. The machine was on AC power at 100% and charged when the environment was captured. Work counts are identical for both engines, and every full-run median exceeds the 50 ms timing floor.

The saved single-thread medians are:

| workload | jobs | zig-js (ms) | JSC (ms) | zig-js / JSC throughput |
| --- | ---: | ---: | ---: | ---: |
| arithmetic | 240 | 82.146 | 354.505 | 4.32x |
| properties | 300 | 85.345 | 288.632 | 3.38x |
| polymorphic properties | 400 | 81.839 | 199.637 | 2.44x |
| object churn | 100 | 149.265 | 115.398 | 0.77x |
| arrays | 550 | 80.055 | 150.122 | 1.88x |
| direct calls | 600 | 56.683 | 119.723 | 2.11x |
| method calls | 500 | 61.569 | 137.008 | 2.23x |
| closure calls | 600 | 61.976 | 189.138 | 3.05x |
| arguments calls | 600 | 66.354 | 294.617 | 4.44x |
| Fibonacci | 125 | 81.968 | 450.846 | 5.50x |

A ratio above 1.00x favors zig-js; below 1.00x favors JSC.

The symmetric eight-lane steady-state rows are directly comparable:

| workload | zig-js (ms) | JSC (ms) | zig-js / JSC throughput | zig-js scaling | JSC scaling |
| --- | ---: | ---: | ---: | ---: | ---: |
| arithmetic | 99.807 | 487.211 | 4.88x | 6.15x | 5.66x |
| properties | 113.220 | 405.957 | 3.59x | 6.07x | 5.65x |
| polymorphic properties | 119.755 | 307.803 | 2.57x | 5.36x | 5.19x |
| object churn | 433.277 | 182.804 | 0.42x | 2.78x | 5.01x |
| arrays | 114.639 | 232.494 | 2.03x | 5.34x | 5.17x |
| direct calls | 78.678 | 187.041 | 2.38x | 5.65x | 5.03x |
| method calls | 87.060 | 217.203 | 2.49x | 5.62x | 5.12x |
| closure calls | 85.659 | 318.143 | 3.71x | 5.75x | 4.69x |
| arguments calls | 95.554 | 491.736 | 5.15x | 5.59x | 4.96x |
| Fibonacci | 115.930 | 667.741 | 5.76x | 5.69x | 5.39x |

The separate no-GIL shared-realm path has no direct public-JSC equivalent. Its one-to-eight-lane result is:

| workload | one lane (ms) | eight lanes (ms) | throughput scaling |
| --- | ---: | ---: | ---: |
| arithmetic | 81.397 | 104.888 | 6.21x |
| properties | 124.813 | 170.870 | 5.84x |
| polymorphic properties | 513.592 | 694.118 | 5.92x |
| object churn | 350.226 | 7,658.643 | 0.37x |
| arrays | 81.129 | 212.559 | 3.05x |
| direct calls | 55.804 | 78.980 | 5.65x |
| method calls | 129.358 | 178.070 | 5.81x |
| closure calls | 62.539 | 87.309 | 5.73x |
| arguments calls | 66.618 | 95.818 | 5.56x |
| Fibonacci | 247.349 | 375.021 | 5.28x |

zig-js wins 9 of 10 single-context rows. Its geometric-mean throughput lead is 2.67x in direct single-context mode and 2.75x at eight warmed independent contexts. Mode-local eight-lane scaling is 5.29x for zig-js and 5.18x for JSC. The symmetric cold lifecycle also has a 2.75x zig-js throughput lead and scales 5.25x and 5.15x respectively. Shared-realm scaling is 4.09x by geometric mean. Object churn is the explicit exception: JSC leads the direct comparison and shared allocation/GC scaling remains below 1x. The new backing batch hook lets each 17-object VM batch acquire its GC size-class lock once instead of once per cell. Focused exact-runner A/B measured neutral direct performance and 3.3%/35.4%/14.8% lower shared wall time at 2/4/8 lanes. Against the previous full publication, shared 1/2/4/8-lane object-churn throughput improved 0.3%/6.2%/50.5%/21.6%. Those publication rows have 25–44% RSD; the focused A/B is the causal evidence, while the full raw range prevents the median from hiding run-to-run dispersion. Read the per-workload rows first; geometric means summarize this exact matrix and do not predict an application.

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
