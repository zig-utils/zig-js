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

The latest saved run is the [July 15, 2026 report](.data/benchmark-comparison-2026-07-15.md), with all [1,540 raw timing samples](.data/benchmark-comparison-2026-07-15.tsv). It ran clean zig-js commit `ab7b08fb468a1ad65fde12526933893c24b1f29a`, zig-gc commit `9d4af0d49be5eba5b9283d5ed135fdf02626e2ac`, and zig-regex commit `5937fa7d4db0b69575c821066afd1a7da92aa019` on an 11-core Apple M3 Pro using Zig `0.17.0-dev.956+2dca73595` and the macOS 27.0 system JavaScriptCore framework `22625.1.20.11.3`. The harness recorded battery power at 27% and discharging. That state and elevated dispersion in several unrelated rows rule out small cross-run delta claims; the same-session order-balanced A/B below is the evidence for `ab7b08fb`. Work counts are identical for both engines, and every full-run median exceeds the 50 ms timing floor.

The saved single-thread medians are:

| workload | jobs | zig-js (ms) | JSC (ms) | zig-js / JSC throughput |
| --- | ---: | ---: | ---: | ---: |
| arithmetic | 240 | 86.923 | 358.776 | 4.13x |
| properties | 300 | 91.910 | 305.549 | 3.32x |
| polymorphic properties | 400 | 87.212 | 215.203 | 2.47x |
| object churn | 100 | 122.226 | 126.404 | 1.03x |
| arrays | 550 | 85.570 | 161.837 | 1.89x |
| direct calls | 600 | 60.660 | 125.241 | 2.06x |
| method calls | 500 | 68.459 | 149.588 | 2.19x |
| closure calls | 600 | 66.742 | 204.052 | 3.06x |
| arguments calls | 600 | 73.521 | 313.364 | 4.26x |
| Fibonacci | 125 | 91.626 | 506.651 | 5.53x |

A ratio above 1.00x favors zig-js; below 1.00x favors JSC.

The symmetric eight-lane steady-state rows are directly comparable:

| workload | zig-js (ms) | JSC (ms) | zig-js / JSC throughput | zig-js scaling | JSC scaling |
| --- | ---: | ---: | ---: | ---: | ---: |
| arithmetic | 123.189 | 597.184 | 4.85x | 5.59x | 4.77x |
| properties | 131.300 | 507.696 | 3.87x | 5.60x | 4.78x |
| polymorphic properties | 141.809 | 357.007 | 2.52x | 4.86x | 4.81x |
| object churn | 401.792 | 214.719 | 0.53x | 2.42x | 4.78x |
| arrays | 147.565 | 266.507 | 1.81x | 4.57x | 4.92x |
| direct calls | 136.403 | 226.596 | 1.66x | 3.55x | 4.43x |
| method calls | 99.564 | 247.177 | 2.48x | 5.42x | 4.82x |
| closure calls | 100.285 | 362.967 | 3.62x | 5.46x | 4.68x |
| arguments calls | 107.386 | 560.438 | 5.22x | 5.16x | 4.52x |
| Fibonacci | 139.115 | 794.220 | 5.71x | 5.29x | 4.85x |

The separate no-GIL shared-realm path has no direct public-JSC equivalent. Its one-to-eight-lane result is:

| workload | one lane (ms) | eight lanes (ms) | throughput scaling |
| --- | ---: | ---: | ---: |
| arithmetic | 86.047 | 110.691 | 6.22x |
| properties | 132.315 | 190.547 | 5.56x |
| polymorphic properties | 542.462 | 807.831 | 5.37x |
| object churn | 206.281 | 6,089.801 | 0.27x |
| arrays | 86.880 | 259.905 | 2.67x |
| direct calls | 60.255 | 99.299 | 4.85x |
| method calls | 126.194 | 213.843 | 4.72x |
| closure calls | 65.843 | 111.918 | 4.71x |
| arguments calls | 70.402 | 112.753 | 5.00x |
| Fibonacci | 273.249 | 455.509 | 4.80x |

zig-js wins all 10 single-context rows. Its geometric-mean throughput lead is 2.71x direct, 2.70x at eight warmed independent contexts, and 2.72x in the symmetric eight-lane cold lifecycle. Mode-local eight-lane scaling is 4.66x for zig-js versus 4.73x for JSC when warmed and 4.72x versus 4.67x when cold. Shared-realm scaling is 3.58x by geometric mean. Commit `ab7b08fb` keeps collector scratch on the supplied reusable host allocator only for private contexts; threaded and concurrent heaps retain `std.heap.page_allocator`, and collector scratch remains outside the public heap budget. Against the frozen parent runner, order-balanced seven-sample object-churn A/B improved warmed eight-context throughput by 5.2% and 6.7%, cold throughput by 10.8% and 30.1%, and direct throughput by 16.2% and 1.6%, with exact checksums. A matched 10-second candidate profile contained no sampled `mmap`/`munmap` frames, versus 76 matching call-tree entries in the parent profile. The low-battery full matrix records object churn at 122.226 ms versus 126.404 ms for JSC directly, 401.792 versus 214.719 ms at eight warmed contexts, and 398.855 versus 201.659 ms cold. Shared object churn remains below the completion contract at 0.27x scaling with 29.38% RSD. Read the per-workload rows first; geometric means summarize this exact matrix and do not predict an application.

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
```

Use quick mode while changing the harness. Run the full matrix once after related changes are assembled; it is measurement work, not a per-edit correctness test.

## VM and tree-walker baseline

`zig build bench` remains the smaller internal baseline. It parses setup once, then times the same hot snippet through the bytecode VM and tree-walker. Its no-shared-state thread table answers whether aggregate compute throughput scales; the comparison suite above adds a second engine, repeat sampling, checksums, and a preserved report.

The latest saved internal run is [`docs/.data/bench-2026-07-04.txt`](.data/bench-2026-07-04.txt). Keep it separate from the JSC report so a VM/tree-walker change cannot silently rewrite the external comparison methodology.
