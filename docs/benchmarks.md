---
title: Performance Benchmarks
description: Reproduce and interpret zig-js single-thread, shared-realm, and JavaScriptCore comparison measurements.
---

# Performance Benchmarks

zig-js keeps two benchmark families separate:

- `zig build bench` compares the bytecode VM with the tree-walking interpreter and prints a small no-shared-state thread-scaling table.
- `zig build benchmark-comparison` directly compares GC-enabled zig-js and JavaScriptCore single-context execution, then reports zig-js shared-realm no-GIL scaling and JSC isolated-context scaling in separate panels.

Neither is an application benchmark or a universal engine score. They are small, inspectable baselines intended to reveal regressions, scaling limits, and the engine paths that deserve profiling.

## Latest JavaScriptCore comparison

The latest saved run is the [July 13, 2026 report](.data/benchmark-comparison-2026-07-13.md), with all [224 raw timing samples](.data/benchmark-comparison-2026-07-13.tsv). It ran commit `82207c244e08d2f8518b56f1bc2fc35fad7761c0` on an 11-core Apple M3 Pro using Zig `0.17.0-dev.956+2dca73595` and the macOS 27.0 system JavaScriptCore framework `22625.1.20.11.3`.

The saved single-thread medians are:

| workload | jobs | zig-js (ms) | JSC (ms) | JSC / zig-js throughput |
| --- | ---: | ---: | ---: | ---: |
| arithmetic | 80 | 472.650 | 120.707 | 3.92x |
| properties | 80 | 346.126 | 80.259 | 4.31x |
| arrays | 180 | 575.475 | 51.924 | 11.08x |
| Fibonacci | 24 | 496.859 | 60.960 | 8.15x |

At eight lanes, zig-js throughput scaled by 5.35x for arithmetic and 4.98x for property mutation. Array construction reached 1.57x, while recursive Fibonacci reached 0.84x; those rows expose current allocation and shared function/environment contention rather than hiding it in one aggregate. The separate JSC isolated-context reference scaled by 5.11x, 4.81x, 4.90x, and 5.18x for the same workloads.

The single-thread JSC advantage is 6.25x by geometric mean across these four kernels. The eight-lane geometric-mean scaling is 2.44x for the zig-js shared realm and 5.00x for isolated JSC contexts. Read the per-workload rows first: geometric means summarize this exact matrix and do not predict an application.

## What is compared

Both runners evaluate the exact source in [`bench/comparison.js`](../bench/comparison.js). Each workload returns an exactly representable integer checksum, and the driver rejects a run if a checksum changes between samples or differs across engines at the same lane count.

| workload | one job |
| --- | --- |
| `arithmetic` | 100,000 integer additions and modulo operations |
| `properties` | 25,000 rounds mutating four properties on one object |
| `arrays` | push 10,000 integers, then read and sum the array |
| `fibonacci` | recursively evaluate `fib(24)` |

The compared modes are intentionally explicit:

| label | execution model |
| --- | --- |
| zig-js single | one context with precise GC enabled |
| zig-js shared | one context with the shipping no-GIL shared-realm `Thread` API; precise GC is implied |
| JSC single | one warmed `JSGlobalContext` using the public JavaScriptCore C API |
| JSC contexts | one independent warmed `JSGlobalContext` per OS thread |

JSC's public API does not expose zig-js's shared-realm `Thread` semantics. The report therefore does not publish a cross-engine parallel throughput ratio: zig-js lanes can see one object graph, while the JSC lanes deliberately use isolated contexts. Adding symmetric independent-context zig-js rows remains tracked in [#45](https://github.com/zig-utils/zig-js/issues/45).

## Timing protocol

The runners are separate executables. That prevents zig-js's JavaScriptCore-shaped C exports from interposing on the real framework symbols.

For every result group:

1. Build the runners in `ReleaseFast`.
2. Create the context, evaluate the shared workload source, and make three reduced-size warm-up calls outside the timer.
3. Time the exact same `__benchmarkSelected(__benchmarkJobs, __benchmarkLane)` invocation bytes for each single-context sample.
4. For parallel samples, prepare the shared JS state or independent JSC contexts outside the timer, then time thread creation, execution, and join. JSC context teardown remains outside the timer.
5. Alternate runner-process order deterministically for each matrix row, instead of always running one engine first.
6. Run seven samples sequentially and report median, min/max, and relative standard deviation. Preserve every sample in TSV form.
7. Reject a full row whose median is below 50 ms, then validate within-run stability and cross-engine checksum equality before rendering any table.
8. Refuse to publish raw/Markdown evidence from a dirty tracked worktree.

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
```

Use quick mode while changing the harness. Run the full matrix once after related changes are assembled; it is measurement work, not a per-edit correctness test.

## VM and tree-walker baseline

`zig build bench` remains the smaller internal baseline. It parses setup once, then times the same hot snippet through the bytecode VM and tree-walker. Its no-shared-state thread table answers whether aggregate compute throughput scales; the comparison suite above adds a second engine, repeat sampling, checksums, and a preserved report.

The latest saved internal run is [`docs/.data/bench-2026-07-04.txt`](.data/bench-2026-07-04.txt). Keep it separate from the JSC report so a VM/tree-walker change cannot silently rewrite the external comparison methodology.
