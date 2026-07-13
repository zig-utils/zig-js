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
| zig-js | 82207c244e08d2f8518b56f1bc2fc35fad7761c0 |
| JavaScriptCore | system framework 22625.1.20.11.3 |

## Single-thread result

Each row runs the same number of jobs in one GC-enabled zig-js context and one warmed JSC global context.
Both runners time the exact invocation `__benchmarkSelected(__benchmarkJobs, __benchmarkLane)`.
Lower time is better; `JSC / zig-js` is JSC throughput divided by zig-js throughput. RSD is relative standard deviation.

| workload | jobs | zig-js median (ms) | zig-js min–max (ms) | zig-js RSD | JSC median (ms) | JSC min–max (ms) | JSC RSD | JSC / zig-js |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `arithmetic` | 80 | 472.650 | 472.335–477.225 | 0.38% | 120.707 | 118.940–122.106 | 0.90% | 3.92x |
| `properties` | 80 | 346.126 | 345.430–346.778 | 0.13% | 80.259 | 80.070–80.359 | 0.14% | 4.31x |
| `arrays` | 180 | 575.475 | 569.434–602.503 | 1.96% | 51.924 | 50.612–52.113 | 1.28% | 11.08x |
| `fibonacci` | 24 | 496.859 | 484.646–534.558 | 3.38% | 60.960 | 59.118–62.588 | 2.02% | 8.15x |

## zig-js shared-realm scaling

Every lane performs the full per-row job count. The timed region creates and joins shared-realm no-GIL
JavaScript `Thread`s. `scaling` compares aggregate throughput with the zig-js single-context row.

| workload | lanes | jobs/lane | median (ms) | min–max (ms) | RSD | scaling |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `arithmetic` | 2 | 80 | 476.229 | 475.804–478.096 | 0.19% | 1.98x |
| `arithmetic` | 4 | 80 | 525.249 | 519.055–651.359 | 9.90% | 3.60x |
| `arithmetic` | 8 | 80 | 707.366 | 676.920–715.754 | 2.20% | 5.35x |
| `properties` | 2 | 80 | 349.297 | 348.657–356.269 | 0.77% | 1.98x |
| `properties` | 4 | 80 | 395.164 | 388.263–460.658 | 6.85% | 3.50x |
| `properties` | 8 | 80 | 555.492 | 552.827–717.773 | 10.60% | 4.98x |
| `arrays` | 2 | 180 | 782.997 | 699.625–883.585 | 7.69% | 1.47x |
| `arrays` | 4 | 180 | 1237.495 | 1167.277–1371.241 | 6.24% | 1.86x |
| `arrays` | 8 | 180 | 2923.704 | 2439.795–3125.563 | 8.24% | 1.57x |
| `fibonacci` | 2 | 24 | 938.320 | 923.881–996.352 | 2.68% | 1.06x |
| `fibonacci` | 4 | 24 | 2281.830 | 2244.507–2761.309 | 8.91% | 0.87x |
| `fibonacci` | 8 | 24 | 4712.298 | 4535.622–4810.019 | 1.90% | 0.84x |

## JSC independent-context scaling reference

Each lane owns a separately prepared and warmed `JSGlobalContext`. The timed region creates the OS threads,
evaluates one invocation per context, and joins them. This is an isolated-context scaling reference, not a
direct throughput competitor for zig-js's shared object graph.

| workload | lanes | jobs/lane | median (ms) | min–max (ms) | RSD | scaling |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `arithmetic` | 2 | 80 | 124.227 | 121.688–165.186 | 11.81% | 1.94x |
| `arithmetic` | 4 | 80 | 132.504 | 130.272–135.095 | 1.22% | 3.64x |
| `arithmetic` | 8 | 80 | 188.860 | 186.369–195.664 | 1.94% | 5.11x |
| `properties` | 2 | 80 | 81.485 | 80.780–81.809 | 0.53% | 1.97x |
| `properties` | 4 | 80 | 91.579 | 87.402–107.902 | 8.85% | 3.51x |
| `properties` | 8 | 80 | 133.407 | 127.149–139.546 | 3.57% | 4.81x |
| `arrays` | 2 | 180 | 52.111 | 51.729–52.658 | 0.64% | 1.99x |
| `arrays` | 4 | 180 | 53.063 | 52.609–53.290 | 0.48% | 3.91x |
| `arrays` | 8 | 180 | 84.847 | 78.625–94.211 | 5.89% | 4.90x |
| `fibonacci` | 2 | 24 | 61.350 | 60.118–62.318 | 1.07% | 1.99x |
| `fibonacci` | 4 | 24 | 61.867 | 61.200–69.149 | 4.41% | 3.94x |
| `fibonacci` | 8 | 24 | 94.161 | 91.338–116.324 | 10.30% | 5.18x |

## Reading the result

Across these four deliberately small kernels, JSC's single-context throughput is 6.25x
the zig-js throughput by geometric mean. This is expected: the system JSC is a mature optimizing JIT, while
zig-js currently has interpreters and no JIT. The number is a compact description of this matrix, not a claim
about applications or unsupported workloads.

At 8 lanes, geometric-mean throughput scaling is 2.44x for zig-js's
shared realm and 5.00x for the separate JSC isolated-context reference.
These are deliberately not divided into a cross-engine parallel ratio because the programming models differ.
Per-workload rows matter more than either aggregate.

## Method and timed boundaries

- Both engines evaluate the exact bytes in `bench/comparison.js`; the single-context rows time the exact same invocation bytes, and the driver rejects unstable or cross-engine checksum mismatches.
- zig-js is built `ReleaseFast`. Its single row explicitly enables precise GC; shared mode enables the shipping no-GIL thread configuration, which implies GC.
- Each context evaluates the workload source and performs three reduced-size warm-up calls before measurement.
- A single sample times one host evaluation call. Context/source setup and warm-up are outside the timer.
- Parallel JS state and JSC contexts are prepared and warmed before measurement. The timed region creates the zig-js `Thread`s / JSC OS threads, performs the work, and ends after every thread joins. JSC context teardown is outside the timer.
- Runner process order alternates deterministically for each matrix row instead of always favoring one engine with the cooler first run.
- Full runs reject any row whose median is shorter than 50 ms; quick harness validation skips that timing floor.
- Samples run sequentially on an otherwise ordinary host. No CPU pinning, frequency locking, or background-process suppression is attempted.
- Median is the headline; min/max and relative standard deviation expose dispersion, and every raw sample is retained.

## Reproduce

Requires macOS because the comparison links the system JavaScriptCore framework.

```sh
zig build benchmark-comparison
zig build benchmark-comparison -Dbenchmark-comparison-raw-out=docs/.data/benchmark-comparison-YYYY-MM-DD.tsv -Dbenchmark-comparison-markdown-out=docs/.data/benchmark-comparison-YYYY-MM-DD.md
zig build benchmark-comparison -Dbenchmark-comparison-quick=true
```

Raw samples: [`benchmark-comparison-2026-07-13.tsv`](benchmark-comparison-2026-07-13.tsv)
