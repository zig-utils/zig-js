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

The latest saved run is the [July 15, 2026 report](.data/benchmark-comparison-2026-07-15.md), with all [1,540 raw timing samples](.data/benchmark-comparison-2026-07-15.tsv). It ran clean zig-js commit `0a74f7d1a35a9504d82d7ca846ff7a05c53f6740`, zig-gc commit `9d4af0d49be5eba5b9283d5ed135fdf02626e2ac`, and zig-regex commit `50764b0352e73a434278de38825dbb55464f1cf6` on an 11-core Apple M3 Pro using Zig `0.17.0-dev.956+2dca73595` and the macOS 27.0 system JavaScriptCore framework `22625.1.20.11.3`. The harness recorded AC power at 100% charge. Work counts are identical for both engines, every full-run median exceeds the 50 ms timing floor, and runner order alternates. Read the saved min/max and RSD before interpreting small differences or comparing sessions.

| mode | lanes | wins vs JSC | zig-js / JSC throughput | zig-js scaling | JSC scaling |
| --- | ---: | ---: | ---: | ---: | ---: |
| direct warmed context | 1 | 10 / 10 | **2.75x** | — | — |
| independent steady contexts | 8 | 10 / 10 | **2.95x** | **5.38x** | 5.14x |
| independent cold lifecycles | 8 | 10 / 10 | **2.90x** | **5.27x** | 5.08x |
| shared realm, no GIL | 8 | no public-JSC equivalent | — | **4.17x** | — |

The saved single-thread medians are:

| workload | jobs | zig-js (ms) | JSC (ms) | zig-js / JSC throughput |
| --- | ---: | ---: | ---: | ---: |
| arithmetic | 240 | 82.936 | 353.899 | 4.27x |
| properties | 300 | 87.534 | 293.427 | 3.35x |
| polymorphic properties | 400 | 82.027 | 204.107 | 2.49x |
| object churn | 100 | 80.380 | 117.343 | 1.46x |
| arrays | 550 | 79.124 | 150.564 | 1.90x |
| direct calls | 600 | 56.185 | 116.732 | 2.08x |
| method calls | 500 | 63.899 | 137.733 | 2.16x |
| closure calls | 600 | 77.444 | 187.510 | 2.42x |
| arguments calls | 600 | 67.331 | 296.124 | 4.40x |
| Fibonacci | 125 | 85.294 | 448.825 | 5.26x |

A ratio above 1.00x favors zig-js; below 1.00x favors JSC.

The symmetric eight-lane steady-state rows are directly comparable:

| workload | zig-js (ms) | JSC (ms) | zig-js / JSC throughput | zig-js scaling | JSC scaling |
| --- | ---: | ---: | ---: | ---: | ---: |
| arithmetic | 106.720 | 550.496 | 5.16x | 6.22x | 5.09x |
| properties | 119.083 | 462.222 | 3.88x | 5.88x | 5.06x |
| polymorphic properties | 129.555 | 336.130 | 2.59x | 5.07x | 4.86x |
| object churn | 170.179 | 187.303 | 1.10x | 3.77x | 5.05x |
| arrays | 128.029 | 233.891 | 1.83x | 5.05x | 5.16x |
| direct calls | 77.858 | 184.310 | 2.37x | 5.77x | 5.05x |
| method calls | 88.482 | 205.107 | 2.32x | 5.69x | 5.35x |
| closure calls | 85.020 | 295.237 | 3.47x | 5.84x | 5.04x |
| arguments calls | 102.239 | 459.981 | 4.50x | 5.29x | 5.15x |
| Fibonacci | 116.174 | 640.952 | 5.52x | 5.69x | 5.60x |

The separate no-GIL shared-realm path has no direct public-JSC equivalent. Its one-to-eight-lane result is:

| workload | one lane (ms) | eight lanes (ms) | throughput scaling |
| --- | ---: | ---: | ---: |
| arithmetic | 83.101 | 106.705 | 6.23x |
| properties | 126.288 | 175.031 | 5.77x |
| polymorphic properties | 503.704 | 738.795 | 5.45x |
| object churn | 123.180 | 1,922.828 | 0.51x |
| arrays | 82.337 | 214.583 | 3.07x |
| direct calls | 56.310 | 80.143 | 5.62x |
| method calls | 116.787 | 176.318 | 5.30x |
| closure calls | 62.684 | 91.244 | 5.50x |
| arguments calls | 67.804 | 97.508 | 5.56x |
| Fibonacci | 258.003 | 366.792 | 5.63x |

zig-js wins all 10 direct rows and all 10 eight-lane rows in both directly comparable multi-context modes. Its geometric-mean throughput lead is 2.75x direct, 2.95x at eight warmed independent contexts, and 2.90x in the symmetric eight-lane cold lifecycle. Mode-local eight-lane scaling is 5.38x for zig-js versus 5.14x for JSC when warmed and 5.27x versus 5.08x when cold. Shared-realm scaling is 4.17x by geometric mean.

Object instances now occupy a 256-byte GC slab (`208` bytes of payload and `240` raw bytes including allocator metadata), while cold error, regexp, constructor, and related state is allocated only when used. Current object buckets use 256 KiB chunks, avoiding repeated allocator and synchronized address-index growth without exceeding the fixed reuse bitmap. The object-churn medians are 80.380 versus 117.343 ms direct, 170.179 versus 187.303 ms at eight warmed contexts, and 177.256 versus 189.788 ms across cold eight-context lifecycles, so zig-js leads JSC in every directly compared object-churn row. Shared object churn is 1,922.828 ms at eight lanes with 0.51x scaling and 4.33% RSD; it remains the clearest shared-GC bottleneck. Read the per-workload rows first; geometric means summarize this exact matrix and do not predict an application.

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
