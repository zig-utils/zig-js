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

The latest saved run is the [July 14, 2026 report](.data/benchmark-comparison-2026-07-14.md), with all [1,540 raw timing samples](.data/benchmark-comparison-2026-07-14.tsv). It ran clean commit `aaa2c3abee26984f6243843795fdfded8a0aed6f` on an 11-core Apple M3 Pro using Zig `0.17.0-dev.956+2dca73595` and the macOS 27.0 system JavaScriptCore framework `22625.1.20.11.3`. The machine was connected to AC power when the environment was captured. Work counts are identical for both engines, and every full-run median exceeds the 50 ms timing floor.

The saved single-thread medians are:

| workload | jobs | zig-js (ms) | JSC (ms) | zig-js / JSC throughput |
| --- | ---: | ---: | ---: | ---: |
| arithmetic | 240 | 81.505 | 344.578 | 4.23x |
| properties | 300 | 85.901 | 287.765 | 3.35x |
| polymorphic properties | 400 | 80.838 | 199.300 | 2.47x |
| object churn | 100 | 117.481 | 116.026 | 0.99x |
| arrays | 550 | 78.476 | 153.152 | 1.95x |
| direct calls | 600 | 57.318 | 117.799 | 2.05x |
| method calls | 500 | 63.735 | 139.215 | 2.18x |
| closure calls | 600 | 63.065 | 189.150 | 3.00x |
| arguments calls | 600 | 68.116 | 299.102 | 4.39x |
| Fibonacci | 125 | 83.452 | 451.531 | 5.41x |

A ratio above 1.00x favors zig-js; below 1.00x favors JSC.

The symmetric eight-lane steady-state rows are directly comparable:

| workload | zig-js (ms) | JSC (ms) | zig-js / JSC throughput | zig-js scaling | JSC scaling |
| --- | ---: | ---: | ---: | ---: | ---: |
| arithmetic | 103.308 | 495.683 | 4.80x | 6.30x | 5.55x |
| properties | 118.653 | 430.937 | 3.63x | 5.80x | 5.32x |
| polymorphic properties | 120.807 | 315.832 | 2.61x | 5.37x | 5.07x |
| object churn | 351.185 | 174.828 | 0.50x | 2.65x | 5.25x |
| arrays | 120.212 | 241.182 | 2.01x | 5.23x | 5.10x |
| direct calls | 80.747 | 190.897 | 2.36x | 6.95x | 4.89x |
| method calls | 91.679 | 221.452 | 2.42x | 5.48x | 5.07x |
| closure calls | 106.872 | 344.971 | 3.23x | 5.58x | 4.35x |
| arguments calls | 94.945 | 498.824 | 5.25x | 5.70x | 4.80x |
| Fibonacci | 123.021 | 673.352 | 5.47x | 5.44x | 5.37x |

The separate no-GIL shared-realm path has no direct public-JSC equivalent. Its one-to-eight-lane result is:

| workload | one lane (ms) | eight lanes (ms) | throughput scaling |
| --- | ---: | ---: | ---: |
| arithmetic | 81.561 | 104.743 | 6.23x |
| properties | 124.909 | 167.770 | 5.96x |
| polymorphic properties | 511.306 | 717.688 | 5.70x |
| object churn | 192.868 | 5,192.344 | 0.30x |
| arrays | 82.504 | 223.361 | 2.96x |
| direct calls | 56.815 | 79.160 | 5.74x |
| method calls | 115.685 | 181.472 | 5.10x |
| closure calls | 63.498 | 90.690 | 5.60x |
| arguments calls | 67.887 | 94.387 | 5.75x |
| Fibonacci | 246.377 | 384.350 | 5.13x |

zig-js wins 9 of 10 single-context rows. Its geometric-mean throughput lead is about 2.70x in direct single-context mode and 2.78x at eight warmed independent contexts. Mode-local eight-lane scaling is 5.31x for zig-js and 5.07x for JSC. The symmetric cold lifecycle has about a 2.70x zig-js throughput lead and scales 5.15x and 5.06x respectively. Shared-realm scaling is 3.94x by geometric mean. Object churn is the only direct loss, now 1.3%: 117.481 ms for zig-js versus 116.026 ms for JSC. The new zig-gc sweep hook retains finalization and unlink order while releasing dead same-size slabs in bounded backing batches. Its exact baseline/candidate screen left direct performance neutral (+0.4% median, candidate faster in 12/21 pairs) and improved shared 1/2/4-lane object churn by 13.7%/15.7%/30.5%; the noisy 8-lane screen was neutral. Against the previous clean publication, shared 1/2/4/8-lane wall time fell 10.9%/15.7%/12.2%/10.5%, with matching checksums throughout. Shared object-churn scaling remains below 1x and its 8–50% RSD makes it the next explicit GC/concurrency target. Read the per-workload rows first; geometric means summarize this exact matrix and do not predict an application.

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
