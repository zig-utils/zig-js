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
| zig-js | 42d0ec2644372011bd0d8b4bff5e0f00752fc81d |
| JavaScriptCore | system framework 22625.1.20.11.3 |
| Power | Now drawing from 'AC Power' -InternalBattery-0 (id=22806627) 100%; charged; 0:00 remaining present: true |

## Single-thread result

Each row runs the same number of jobs in one GC-enabled zig-js context and one warmed JSC global context.
Both runners time the exact invocation `__benchmarkSelected(__benchmarkJobs, __benchmarkLane)`.
Lower time is better; `JSC / zig-js` is JSC throughput divided by zig-js throughput. RSD is relative standard deviation.

| workload | jobs | zig-js median (ms) | zig-js min–max (ms) | zig-js RSD | JSC median (ms) | JSC min–max (ms) | JSC RSD | JSC / zig-js |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `arithmetic` | 160 | 55.954 | 54.285–56.554 | 1.46% | 230.350 | 228.974–233.707 | 0.79% | 0.24x |
| `properties` | 200 | 56.900 | 55.232–73.208 | 12.36% | 192.922 | 191.535–194.178 | 0.50% | 0.29x |
| `arrays` | 450 | 61.569 | 60.634–62.594 | 1.21% | 124.911 | 122.696–159.423 | 10.10% | 0.49x |
| `fibonacci` | 100 | 66.945 | 66.810–67.328 | 0.27% | 366.149 | 363.943–367.800 | 0.33% | 0.18x |

## Independent-context steady state

Both engines keep one warmed context on one persistent OS worker per lane. The timed region contains the
same semaphore dispatch, exact invocation, and completion wait. Every lane performs the full job count.
`scaling` uses the same engine and mode at one lane; cross-engine throughput is directly comparable.

| workload | lanes | jobs/lane | zig-js median (ms) | zig-js min–max (ms) | zig-js RSD | JSC median (ms) | JSC min–max (ms) | JSC RSD | JSC / zig-js | zig-js scaling | JSC scaling |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `arithmetic` | 1 | 160 | 53.917 | 53.785–54.242 | 0.39% | 229.070 | 228.710–233.087 | 0.84% | 0.24x | 1.00x | 1.00x |
| `arithmetic` | 2 | 160 | 57.763 | 56.661–70.814 | 8.54% | 246.607 | 242.794–286.540 | 6.24% | 0.23x | 1.87x | 1.86x |
| `arithmetic` | 4 | 160 | 57.770 | 57.652–62.640 | 3.16% | 267.568 | 259.561–541.945 | 34.88% | 0.22x | 3.73x | 3.42x |
| `arithmetic` | 8 | 160 | 71.166 | 68.715–74.321 | 2.46% | 362.861 | 352.458–368.399 | 1.83% | 0.20x | 6.06x | 5.05x |
| `properties` | 1 | 200 | 60.432 | 59.229–66.171 | 4.66% | 208.496 | 206.511–211.269 | 0.87% | 0.29x | 1.00x | 1.00x |
| `properties` | 2 | 200 | 57.548 | 57.419–58.198 | 0.45% | 200.100 | 199.118–200.768 | 0.24% | 0.29x | 2.10x | 2.08x |
| `properties` | 4 | 200 | 58.754 | 58.672–59.612 | 0.60% | 204.024 | 203.686–205.356 | 0.31% | 0.29x | 4.11x | 4.09x |
| `properties` | 8 | 200 | 78.794 | 75.739–81.852 | 2.64% | 298.952 | 290.094–305.905 | 2.05% | 0.26x | 6.14x | 5.58x |
| `arrays` | 1 | 450 | 61.379 | 61.095–62.246 | 0.75% | 125.758 | 123.963–128.246 | 1.07% | 0.49x | 1.00x | 1.00x |
| `arrays` | 2 | 450 | 63.685 | 62.629–64.443 | 0.93% | 127.125 | 126.416–127.892 | 0.41% | 0.50x | 1.93x | 1.98x |
| `arrays` | 4 | 450 | 65.822 | 64.412–66.986 | 1.55% | 135.494 | 129.856–139.075 | 2.23% | 0.49x | 3.73x | 3.71x |
| `arrays` | 8 | 450 | 93.789 | 89.558–103.628 | 4.88% | 208.772 | 205.445–222.755 | 2.83% | 0.45x | 5.24x | 4.82x |
| `fibonacci` | 1 | 100 | 66.893 | 66.744–67.059 | 0.15% | 365.270 | 364.945–367.685 | 0.31% | 0.18x | 1.00x | 1.00x |
| `fibonacci` | 2 | 100 | 68.575 | 68.351–68.821 | 0.22% | 374.296 | 373.527–375.732 | 0.19% | 0.18x | 1.95x | 1.95x |
| `fibonacci` | 4 | 100 | 71.540 | 70.565–72.819 | 1.08% | 396.386 | 390.225–405.936 | 1.32% | 0.18x | 3.74x | 3.69x |
| `fibonacci` | 8 | 100 | 100.187 | 98.754–103.069 | 1.45% | 575.698 | 569.927–589.123 | 1.28% | 0.17x | 5.34x | 5.08x |

## Independent-context cold lifecycle

Neither engine warms these contexts. The timer covers OS-thread creation, context creation, workload-source
evaluation and configuration, the exact invocation, context destruction, and OS-thread join on both sides.
`scaling` uses the same engine and cold lifecycle at one lane.

| workload | lanes | jobs/lane | zig-js median (ms) | zig-js min–max (ms) | zig-js RSD | JSC median (ms) | JSC min–max (ms) | JSC RSD | JSC / zig-js | zig-js scaling | JSC scaling |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `arithmetic` | 1 | 160 | 54.987 | 54.476–55.712 | 0.79% | 233.633 | 231.496–241.093 | 1.62% | 0.24x | 1.00x | 1.00x |
| `arithmetic` | 2 | 160 | 58.415 | 58.274–59.481 | 0.72% | 252.005 | 243.655–288.304 | 5.96% | 0.23x | 1.88x | 1.85x |
| `arithmetic` | 4 | 160 | 60.055 | 59.799–63.559 | 2.41% | 263.875 | 257.900–280.757 | 3.10% | 0.23x | 3.66x | 3.54x |
| `arithmetic` | 8 | 160 | 81.126 | 74.691–96.609 | 9.33% | 353.384 | 339.705–382.249 | 5.07% | 0.23x | 5.42x | 5.29x |
| `properties` | 1 | 200 | 57.576 | 57.213–59.784 | 1.58% | 213.103 | 196.193–230.514 | 6.30% | 0.27x | 1.00x | 1.00x |
| `properties` | 2 | 200 | 59.229 | 58.933–59.612 | 0.39% | 201.723 | 200.995–203.379 | 0.41% | 0.29x | 1.94x | 2.11x |
| `properties` | 4 | 200 | 60.376 | 60.267–61.802 | 0.89% | 205.388 | 204.874–208.202 | 0.55% | 0.29x | 3.81x | 4.15x |
| `properties` | 8 | 200 | 81.192 | 80.012–85.109 | 2.30% | 306.101 | 299.850–316.233 | 1.80% | 0.27x | 5.67x | 5.57x |
| `arrays` | 1 | 450 | 60.979 | 60.818–63.807 | 1.74% | 126.370 | 125.512–127.720 | 0.65% | 0.48x | 1.00x | 1.00x |
| `arrays` | 2 | 450 | 63.739 | 63.222–65.781 | 1.41% | 128.586 | 128.093–129.367 | 0.40% | 0.50x | 1.91x | 1.97x |
| `arrays` | 4 | 450 | 65.689 | 65.320–68.307 | 1.61% | 137.901 | 131.791–140.500 | 1.98% | 0.48x | 3.71x | 3.67x |
| `arrays` | 8 | 450 | 99.306 | 93.767–102.001 | 2.80% | 211.454 | 205.133–222.486 | 2.92% | 0.47x | 4.91x | 4.78x |
| `fibonacci` | 1 | 100 | 70.030 | 68.670–77.815 | 4.99% | 365.727 | 364.797–367.188 | 0.24% | 0.19x | 1.00x | 1.00x |
| `fibonacci` | 2 | 100 | 70.253 | 69.710–70.885 | 0.67% | 375.207 | 375.022–376.204 | 0.13% | 0.19x | 1.99x | 1.95x |
| `fibonacci` | 4 | 100 | 73.161 | 71.470–74.211 | 1.22% | 398.881 | 392.757–404.859 | 1.17% | 0.18x | 3.83x | 3.67x |
| `fibonacci` | 8 | 100 | 106.815 | 102.860–108.626 | 1.79% | 585.694 | 577.179–599.577 | 1.48% | 0.18x | 5.24x | 5.00x |

## zig-js shared-realm scaling

This is zig-js's distinct no-GIL shared-object-graph model, which JSC's public C API does not provide.
The timed region creates JavaScript `Thread`s, performs the work, and joins them. Scaling uses the same
shared-realm path at one lane, so thread lifecycle overhead is present in every row.

| workload | lanes | jobs/lane | median (ms) | min–max (ms) | RSD | scaling |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `arithmetic` | 1 | 160 | 54.346 | 54.067–55.796 | 1.33% | 1.00x |
| `arithmetic` | 2 | 160 | 56.784 | 56.687–57.934 | 0.77% | 1.91x |
| `arithmetic` | 4 | 160 | 58.259 | 57.547–60.701 | 2.06% | 3.73x |
| `arithmetic` | 8 | 160 | 68.762 | 68.008–73.696 | 2.78% | 6.32x |
| `properties` | 1 | 200 | 76.414 | 76.286–76.619 | 0.17% | 1.00x |
| `properties` | 2 | 200 | 78.367 | 78.160–79.531 | 0.75% | 1.95x |
| `properties` | 4 | 200 | 79.805 | 79.647–79.904 | 0.13% | 3.83x |
| `properties` | 8 | 200 | 107.915 | 101.637–110.247 | 3.05% | 5.66x |
| `arrays` | 1 | 450 | 63.442 | 62.118–64.027 | 1.18% | 1.00x |
| `arrays` | 2 | 450 | 65.285 | 64.738–67.114 | 1.54% | 1.94x |
| `arrays` | 4 | 450 | 73.257 | 71.926–95.258 | 10.87% | 3.46x |
| `arrays` | 8 | 450 | 208.605 | 203.942–211.613 | 1.13% | 2.43x |
| `fibonacci` | 1 | 100 | 199.146 | 198.882–200.084 | 0.20% | 1.00x |
| `fibonacci` | 2 | 100 | 203.606 | 203.487–203.936 | 0.07% | 1.96x |
| `fibonacci` | 4 | 100 | 226.709 | 217.945–229.633 | 1.72% | 3.51x |
| `fibonacci` | 8 | 100 | 320.123 | 309.602–327.475 | 1.86% | 4.98x |

## Reading the result

Across these four deliberately small kernels, JSC's single-context throughput is 0.28x
the zig-js throughput by geometric mean. These kernels deliberately exercise guarded native/VM tiers that
zig-js currently implements; rows outside those documented subsets continue through general bytecode paths.
The number is a compact description of this matrix, not a claim about applications or unsupported workloads.

At 8 independent warmed contexts, JSC throughput is 0.25x zig-js by
geometric mean; scaling from the mode's own one-lane baseline is 5.68x
for zig-js and 5.12x for JSC. In the symmetric cold lifecycle, JSC
throughput is 0.27x zig-js, with 5.31x
and 5.15x scaling respectively.

zig-js's shared-realm path scales 4.56x at 8 lanes from its
own one-lane shared baseline. It has no direct JSC ratio because the public JSC embedding API exposes
isolated global contexts, not concurrent JavaScript workers sharing one object graph. Per-workload rows
matter more than any aggregate.

## Method and timed boundaries

- Both engines evaluate the exact bytes in `bench/comparison.js`. Directly compared single and independent rows use the exact invocation bytes `__benchmarkSelected(__benchmarkJobs, __benchmarkLane)`; shared mode calls the same selected function with the same jobs/lane arguments. The driver rejects unstable or cross-engine checksum mismatches.
- zig-js is built `ReleaseFast`. Direct and independent contexts explicitly enable precise GC; shared mode enables the shipping no-GIL thread configuration, which implies GC.
- zig-js independent workers give each context the process-wide thread-safe libc allocator, whose reusable infrastructure outlives timed cold contexts; cold mode still times every context-owned allocation and release. JSC uses its internal process allocator.
- Single mode evaluates the workload source, configures the context, and performs three reduced-size warm-up calls before timing one host evaluation call per sample.
- Independent steady mode uses the same persistent-worker protocol in both runners. Every worker creates, configures, and warms its own thread-affine context before measurement. Each timer includes semaphore dispatch, one invocation per lane, and completion waits; worker/context teardown follows all samples.
- Independent cold mode performs no warm-up. Every timer includes OS-thread spawn, worker-owned context creation, workload-source evaluation and configuration, one invocation, context destruction, and OS-thread join.
- Shared mode prepares and warms one zig-js shared realm outside the timer. Every timed sample creates and joins the requested JavaScript `Thread`s. Its one-lane row is the scaling baseline.
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
