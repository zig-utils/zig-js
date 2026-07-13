# zig-js / JavaScriptCore benchmark — 2026-07-13

> This is a dated measurement, not a universal engine score. The workload source, raw samples,
> timed boundaries, and semantic differences are recorded so the result can be reproduced and challenged.

## Environment

| item | value |
| --- | --- |
| Date | 2026-07-13 |
| Host | Apple M3 Pro; 11 physical / 11 logical CPUs; 18.0 GiB |
| OS | macOS 27.0 (26A5368g) |
| Zig | 0.17.0-dev.956+2dca73595 |
| zig-js | dde04264b143cc68bc6de42dadc7bcb1465ed738 |
| JavaScriptCore | system framework 22625.1.20.11.3 |

## Single-thread result

Each row runs the same number of jobs in one GC-enabled zig-js context and one warmed JSC global context.
Lower time is better; `JSC / zig-js` is JSC throughput divided by zig-js throughput.

| workload | jobs | zig-js median (ms) | JSC median (ms) | JSC / zig-js |
| --- | ---: | ---: | ---: | ---: |
| `arithmetic` | 40 | 248.075 | 60.305 | 4.11x |
| `properties` | 40 | 163.112 | 40.633 | 4.01x |
| `arrays` | 30 | 93.505 | 9.338 | 10.01x |
| `fibonacci` | 8 | 262.657 | 20.668 | 12.71x |

## Parallel throughput and scaling

Every lane performs the full per-row job count. `scaling` compares total throughput with that engine's
single-lane row. zig-js lanes are shared-realm no-GIL JavaScript `Thread`s; JSC lanes are independent
warmed `JSGlobalContext`s on OS threads. Those are intentionally reported together for throughput, but
they are not the same programming model.

| workload | lanes | zig-js median (ms) | zig-js scaling | JSC median (ms) | JSC scaling | JSC / zig-js |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `arithmetic` | 2 | 221.238 | 2.24x | 62.100 | 1.94x | 3.56x |
| `arithmetic` | 4 | 240.272 | 4.13x | 71.521 | 3.37x | 3.36x |
| `arithmetic` | 8 | 332.534 | 5.97x | 98.194 | 4.91x | 3.39x |
| `properties` | 2 | 164.429 | 1.98x | 42.675 | 1.90x | 3.85x |
| `properties` | 4 | 236.031 | 2.76x | 47.961 | 3.39x | 4.92x |
| `properties` | 8 | 295.402 | 4.42x | 69.552 | 4.67x | 4.25x |
| `arrays` | 2 | 154.889 | 1.21x | 11.690 | 1.60x | 13.25x |
| `arrays` | 4 | 302.406 | 1.24x | 14.045 | 2.66x | 21.53x |
| `arrays` | 8 | 565.969 | 1.32x | 25.921 | 2.88x | 21.83x |
| `fibonacci` | 2 | 495.576 | 1.06x | 21.413 | 1.93x | 23.14x |
| `fibonacci` | 4 | 1248.333 | 0.84x | 23.974 | 3.45x | 52.07x |
| `fibonacci` | 8 | 2426.465 | 0.87x | 37.526 | 4.41x | 64.66x |

## Reading the result

Across these four deliberately small kernels, JSC's single-context throughput is 6.77x
the zig-js throughput by geometric mean. This is expected: the system JSC is a mature optimizing JIT, while
zig-js currently has interpreters and no JIT. The number is a compact description of this matrix, not a claim
about applications or unsupported workloads.

At 8 lanes, geometric-mean throughput scaling is 2.34x for zig-js's
shared realm and 4.13x for independent JSC contexts. Per-workload rows matter more
than the aggregate: recursion, allocation, property access, and integer loops stress different engine paths.

## Method and timed boundaries

- Both engines evaluate the exact bytes in `bench/comparison.js`; the driver rejects unstable or cross-engine checksum mismatches.
- zig-js is built `ReleaseFast`. Its single row explicitly enables precise GC; shared mode enables the shipping no-GIL thread configuration, which implies GC.
- Each context evaluates the workload source and performs three reduced-size warm-up calls before measurement.
- A single sample times one host evaluation call. Context/source setup and warm-up are outside the timer.
- Parallel JS state and JSC contexts are prepared and warmed before measurement. The timed region creates the zig-js `Thread`s / JSC OS threads, performs the work, and ends after every thread joins. JSC context teardown is outside the timer.
- Samples run sequentially on an otherwise ordinary host. No CPU pinning, frequency locking, or background-process suppression is attempted.
- Median is the headline; every raw sample is retained. Compare runs on the same hardware and power state before treating small deltas as meaningful.

## Reproduce

Requires macOS because the comparison links the system JavaScriptCore framework.

```sh
zig build benchmark-comparison
zig build benchmark-comparison -Dbenchmark-comparison-raw-out=docs/.data/benchmark-comparison-YYYY-MM-DD.tsv -Dbenchmark-comparison-markdown-out=docs/.data/benchmark-comparison-YYYY-MM-DD.md
zig build benchmark-comparison -Dbenchmark-comparison-quick=true
```

Raw samples: [`benchmark-comparison-2026-07-13.tsv`](benchmark-comparison-2026-07-13.tsv)
