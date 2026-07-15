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

The latest saved run is the [July 15, 2026 report](.data/benchmark-comparison-2026-07-15.md), with all [1,540 raw timing samples](.data/benchmark-comparison-2026-07-15.tsv). It ran clean zig-js commit `fff12f905819fab376372fabddb46d6a95f02f97`, zig-gc commit `9d4af0d49be5eba5b9283d5ed135fdf02626e2ac`, and zig-regex commit `5937fa7d4db0b69575c821066afd1a7da92aa019` on an 11-core Apple M3 Pro using Zig `0.17.0-dev.956+2dca73595` and the macOS 27.0 system JavaScriptCore framework `22625.1.20.11.3`. The harness recorded battery power at 83% and discharging. Work counts are identical for both engines, every full-run median exceeds the 50 ms timing floor, and runner order alternates. Read the saved min/max and RSD before interpreting small differences or comparing sessions.

| mode | lanes | wins vs JSC | zig-js / JSC throughput | zig-js scaling | JSC scaling |
| --- | ---: | ---: | ---: | ---: | ---: |
| direct warmed context | 1 | 10 / 10 | **2.76x** | — | — |
| independent steady contexts | 8 | 9 / 10 | **2.88x** | **5.30x** | 5.04x |
| independent cold lifecycles | 8 | 9 / 10 | **2.98x** | **5.41x** | 4.88x |
| shared realm, no GIL | 8 | no public-JSC equivalent | — | **4.23x** | — |

The saved single-thread medians are:

| workload | jobs | zig-js (ms) | JSC (ms) | zig-js / JSC throughput |
| --- | ---: | ---: | ---: | ---: |
| arithmetic | 240 | 83.460 | 356.409 | 4.27x |
| properties | 300 | 90.049 | 298.925 | 3.32x |
| polymorphic properties | 400 | 84.488 | 227.078 | 2.69x |
| object churn | 100 | 109.144 | 117.864 | 1.08x |
| arrays | 550 | 80.170 | 152.181 | 1.90x |
| direct calls | 600 | 57.853 | 119.884 | 2.07x |
| method calls | 500 | 63.367 | 141.896 | 2.24x |
| closure calls | 600 | 64.975 | 196.604 | 3.03x |
| arguments calls | 600 | 70.252 | 300.100 | 4.27x |
| Fibonacci | 125 | 82.233 | 455.227 | 5.54x |

A ratio above 1.00x favors zig-js; below 1.00x favors JSC.

The symmetric eight-lane steady-state rows are directly comparable:

| workload | zig-js (ms) | JSC (ms) | zig-js / JSC throughput | zig-js scaling | JSC scaling |
| --- | ---: | ---: | ---: | ---: | ---: |
| arithmetic | 107.624 | 537.507 | 4.99x | 6.20x | 5.29x |
| properties | 127.531 | 470.714 | 3.69x | 5.70x | 5.00x |
| polymorphic properties | 124.906 | 321.927 | 2.58x | 5.88x | 6.10x |
| object churn | 266.624 | 183.781 | 0.69x | 3.28x | 5.07x |
| arrays | 128.020 | 265.918 | 2.08x | 5.03x | 4.57x |
| direct calls | 86.650 | 209.146 | 2.41x | 5.66x | 4.69x |
| method calls | 94.638 | 225.753 | 2.39x | 5.45x | 5.00x |
| closure calls | 94.428 | 338.457 | 3.58x | 5.44x | 4.56x |
| arguments calls | 100.188 | 507.589 | 5.07x | 5.56x | 4.79x |
| Fibonacci | 120.613 | 660.264 | 5.47x | 5.53x | 5.48x |

The separate no-GIL shared-realm path has no direct public-JSC equivalent. Its one-to-eight-lane result is:

| workload | one lane (ms) | eight lanes (ms) | throughput scaling |
| --- | ---: | ---: | ---: |
| arithmetic | 83.622 | 109.544 | 6.11x |
| properties | 129.786 | 185.549 | 5.60x |
| polymorphic properties | 597.711 | 757.858 | 6.31x |
| object churn | 193.853 | 2,374.329 | 0.65x |
| arrays | 83.483 | 242.194 | 2.76x |
| direct calls | 59.257 | 85.414 | 5.55x |
| method calls | 124.318 | 199.988 | 4.97x |
| closure calls | 67.528 | 96.832 | 5.58x |
| arguments calls | 70.621 | 102.137 | 5.53x |
| Fibonacci | 257.612 | 374.975 | 5.50x |

zig-js wins all 10 direct rows and 9 of 10 eight-lane rows in both directly comparable multi-context modes; object churn is the remaining loss. Its geometric-mean throughput lead is 2.76x direct, 2.88x at eight warmed independent contexts, and 2.98x in the symmetric eight-lane cold lifecycle. Mode-local eight-lane scaling is 5.30x for zig-js versus 5.04x for JSC when warmed and 5.41x versus 4.88x when cold. Shared-realm scaling is 4.23x by geometric mean.

The shipping no-GIL heap now enables allocation accounting only after a second worker is registered, then performs a bounded cooperative young collection after a 1 GiB aggregate GC-cell tranche. Peers freeze at existing safepoints, publish their native stacks, and are released after collection; a 100 ms rendezvous timeout fails closed without sweeping. An order-balanced same-session object-churn A/B held the one-lane median effectively flat (195.479 versus 196.399 ms, -0.5%) and cut the eight-lane median from 5,554.628 to 2,214.625 ms (-60.1%), with exact checksums. The full matrix records shared object churn at 2,374.329 ms, 0.65x scaling, and 6.32% RSD. It remains below the shared-scaling completion target, while directly compared eight-context object churn is 266.624 versus 183.781 ms warmed and 275.548 versus 188.630 ms cold. Read the per-workload rows first; geometric means summarize this exact matrix and do not predict an application.

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
