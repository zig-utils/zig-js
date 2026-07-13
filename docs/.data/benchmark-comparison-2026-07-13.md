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
| zig-js | c9f68e3299f9184027980e5944e9d5e397cb87ee |
| JavaScriptCore | system framework 22625.1.20.11.3 |
| Power | Now drawing from 'Battery Power' -InternalBattery-0 (id=22806627) 66%; discharging; (no estimate) present: true |

## Single-thread result

Each row runs the same number of jobs in one GC-enabled zig-js context and one warmed JSC global context.
Both runners time the exact invocation `__benchmarkSelected(__benchmarkJobs, __benchmarkLane)`.
Lower time is better; `JSC / zig-js` is JSC throughput divided by zig-js throughput. RSD is relative standard deviation.

| workload | jobs | zig-js median (ms) | zig-js min–max (ms) | zig-js RSD | JSC median (ms) | JSC min–max (ms) | JSC RSD | JSC / zig-js |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `arithmetic` | 80 | 433.536 | 415.841–448.622 | 2.71% | 119.881 | 118.348–124.370 | 1.90% | 3.62x |
| `properties` | 80 | 329.675 | 328.671–331.043 | 0.23% | 86.305 | 82.875–137.086 | 21.59% | 3.82x |
| `arrays` | 180 | 544.743 | 541.676–590.392 | 3.60% | 52.876 | 52.692–53.950 | 0.91% | 10.30x |
| `fibonacci` | 24 | 474.637 | 473.548–479.441 | 0.43% | 62.094 | 60.797–62.628 | 1.26% | 7.64x |

## Independent-context steady state

Both engines keep one warmed context on one persistent OS worker per lane. The timed region contains the
same semaphore dispatch, exact invocation, and completion wait. Every lane performs the full job count.
`scaling` uses the same engine and mode at one lane; cross-engine throughput is directly comparable.

| workload | lanes | jobs/lane | zig-js median (ms) | zig-js min–max (ms) | zig-js RSD | JSC median (ms) | JSC min–max (ms) | JSC RSD | JSC / zig-js | zig-js scaling | JSC scaling |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `arithmetic` | 1 | 80 | 422.368 | 415.288–436.884 | 1.99% | 120.566 | 119.023–133.625 | 4.54% | 3.50x | 1.00x | 1.00x |
| `arithmetic` | 2 | 80 | 434.523 | 422.577–437.361 | 1.15% | 135.270 | 122.304–171.198 | 13.02% | 3.21x | 1.94x | 1.78x |
| `arithmetic` | 4 | 80 | 474.739 | 464.725–480.738 | 1.21% | 146.377 | 136.980–152.460 | 4.26% | 3.24x | 3.56x | 3.29x |
| `arithmetic` | 8 | 80 | 662.490 | 646.963–668.470 | 1.36% | 209.608 | 201.443–237.055 | 6.65% | 3.16x | 5.10x | 4.60x |
| `properties` | 1 | 80 | 309.636 | 309.195–312.569 | 0.38% | 80.972 | 80.787–104.236 | 12.48% | 3.82x | 1.00x | 1.00x |
| `properties` | 2 | 80 | 313.935 | 312.076–390.171 | 8.90% | 81.674 | 81.294–82.825 | 0.65% | 3.84x | 1.97x | 1.98x |
| `properties` | 4 | 80 | 401.788 | 375.370–445.713 | 5.83% | 106.238 | 95.338–113.562 | 6.59% | 3.78x | 3.08x | 3.05x |
| `properties` | 8 | 80 | 522.445 | 513.787–525.638 | 0.94% | 142.411 | 134.289–180.459 | 12.01% | 3.67x | 4.74x | 4.55x |
| `arrays` | 1 | 180 | 552.312 | 548.025–567.047 | 1.29% | 53.238 | 51.587–54.730 | 2.22% | 10.37x | 1.00x | 1.00x |
| `arrays` | 2 | 180 | 549.890 | 543.770–568.357 | 1.57% | 52.986 | 51.626–53.308 | 1.09% | 10.38x | 2.01x | 2.01x |
| `arrays` | 4 | 180 | 580.195 | 575.861–587.301 | 0.70% | 59.031 | 57.944–60.829 | 1.81% | 9.83x | 3.81x | 3.61x |
| `arrays` | 8 | 180 | 805.877 | 797.851–820.371 | 0.99% | 92.791 | 89.660–101.150 | 4.10% | 8.68x | 5.48x | 4.59x |
| `fibonacci` | 1 | 24 | 485.886 | 478.069–492.549 | 0.97% | 62.403 | 60.656–63.666 | 1.67% | 7.79x | 1.00x | 1.00x |
| `fibonacci` | 2 | 24 | 483.751 | 477.170–488.172 | 0.78% | 62.154 | 61.416–63.131 | 0.96% | 7.78x | 2.01x | 2.01x |
| `fibonacci` | 4 | 24 | 525.775 | 511.503–569.749 | 3.67% | 88.944 | 85.326–96.001 | 4.09% | 5.91x | 3.70x | 2.81x |
| `fibonacci` | 8 | 24 | 728.851 | 715.020–755.814 | 1.95% | 105.038 | 99.724–110.189 | 2.96% | 6.94x | 5.33x | 4.75x |

## Independent-context cold lifecycle

Neither engine warms these contexts. The timer covers OS-thread creation, context creation, workload-source
evaluation and configuration, the exact invocation, context destruction, and OS-thread join on both sides.
`scaling` uses the same engine and cold lifecycle at one lane.

| workload | lanes | jobs/lane | zig-js median (ms) | zig-js min–max (ms) | zig-js RSD | JSC median (ms) | JSC min–max (ms) | JSC RSD | JSC / zig-js | zig-js scaling | JSC scaling |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `arithmetic` | 1 | 80 | 470.580 | 445.695–512.413 | 5.20% | 125.781 | 120.407–141.581 | 5.96% | 3.74x | 1.00x | 1.00x |
| `arithmetic` | 2 | 80 | 459.229 | 453.321–525.751 | 5.54% | 123.197 | 122.547–150.368 | 9.76% | 3.73x | 2.05x | 2.04x |
| `arithmetic` | 4 | 80 | 521.474 | 510.019–572.544 | 3.97% | 152.114 | 149.099–161.644 | 2.67% | 3.43x | 3.61x | 3.31x |
| `arithmetic` | 8 | 80 | 760.859 | 738.454–797.597 | 2.41% | 240.960 | 215.961–260.243 | 7.65% | 3.16x | 4.95x | 4.18x |
| `properties` | 1 | 80 | 331.333 | 328.645–331.955 | 0.34% | 82.092 | 81.879–84.333 | 1.05% | 4.04x | 1.00x | 1.00x |
| `properties` | 2 | 80 | 342.082 | 340.628–363.670 | 2.59% | 84.578 | 83.557–89.712 | 2.54% | 4.04x | 1.94x | 1.94x |
| `properties` | 4 | 80 | 406.993 | 398.260–417.529 | 1.62% | 98.672 | 96.976–101.614 | 1.71% | 4.12x | 3.26x | 3.33x |
| `properties` | 8 | 80 | 633.520 | 595.417–670.186 | 4.14% | 146.999 | 141.899–224.777 | 18.83% | 4.31x | 4.18x | 4.47x |
| `arrays` | 1 | 180 | 572.934 | 564.260–586.184 | 1.38% | 53.940 | 52.430–62.553 | 6.08% | 10.62x | 1.00x | 1.00x |
| `arrays` | 2 | 180 | 580.427 | 574.448–590.735 | 0.92% | 54.011 | 51.792–54.865 | 1.92% | 10.75x | 1.97x | 2.00x |
| `arrays` | 4 | 180 | 617.718 | 611.309–630.251 | 1.04% | 62.672 | 59.252–82.648 | 12.42% | 9.86x | 3.71x | 3.44x |
| `arrays` | 8 | 180 | 875.253 | 870.752–918.019 | 2.14% | 95.676 | 94.156–108.559 | 5.13% | 9.15x | 5.24x | 4.51x |
| `fibonacci` | 1 | 24 | 521.059 | 507.627–536.008 | 1.89% | 62.459 | 60.698–65.504 | 3.15% | 8.34x | 1.00x | 1.00x |
| `fibonacci` | 2 | 24 | 500.820 | 499.257–511.266 | 0.95% | 63.051 | 62.185–70.043 | 4.32% | 7.94x | 2.08x | 1.98x |
| `fibonacci` | 4 | 24 | 579.331 | 567.450–640.443 | 4.70% | 78.104 | 69.173–83.092 | 5.80% | 7.42x | 3.60x | 3.20x |
| `fibonacci` | 8 | 24 | 820.780 | 805.772–837.600 | 1.29% | 117.016 | 103.514–123.353 | 6.88% | 7.01x | 5.08x | 4.27x |

## zig-js shared-realm scaling

This is zig-js's distinct no-GIL shared-object-graph model, which JSC's public C API does not provide.
The timed region creates JavaScript `Thread`s, performs the work, and joins them. Scaling uses the same
shared-realm path at one lane, so thread lifecycle overhead is present in every row.

| workload | lanes | jobs/lane | median (ms) | min–max (ms) | RSD | scaling |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `arithmetic` | 1 | 80 | 435.488 | 420.536–474.872 | 4.26% | 1.00x |
| `arithmetic` | 2 | 80 | 421.715 | 416.250–591.324 | 14.41% | 2.07x |
| `arithmetic` | 4 | 80 | 492.469 | 487.181–501.627 | 1.00% | 3.54x |
| `arithmetic` | 8 | 80 | 710.189 | 692.246–788.037 | 4.57% | 4.91x |
| `properties` | 1 | 80 | 320.425 | 319.444–320.908 | 0.19% | 1.00x |
| `properties` | 2 | 80 | 327.182 | 323.312–334.767 | 1.49% | 1.96x |
| `properties` | 4 | 80 | 385.745 | 378.584–416.932 | 3.86% | 3.32x |
| `properties` | 8 | 80 | 536.103 | 524.681–590.351 | 4.01% | 4.78x |
| `arrays` | 1 | 180 | 622.644 | 608.402–654.461 | 2.92% | 1.00x |
| `arrays` | 2 | 180 | 719.164 | 676.592–741.642 | 3.52% | 1.73x |
| `arrays` | 4 | 180 | 1387.326 | 1377.005–1404.931 | 0.74% | 1.80x |
| `arrays` | 8 | 180 | 2920.470 | 2666.452–3358.129 | 7.81% | 1.71x |
| `fibonacci` | 1 | 24 | 484.348 | 476.927–499.502 | 1.57% | 1.00x |
| `fibonacci` | 2 | 24 | 969.305 | 966.175–980.783 | 0.63% | 1.00x |
| `fibonacci` | 4 | 24 | 2787.451 | 2617.520–3108.218 | 6.61% | 0.70x |
| `fibonacci` | 8 | 24 | 4887.213 | 4732.521–4924.973 | 1.53% | 0.79x |

## Reading the result

Across these four deliberately small kernels, JSC's single-context throughput is 5.74x
the zig-js throughput by geometric mean. This is expected: the system JSC is a mature optimizing JIT, while
zig-js currently has interpreters and no JIT. The number is a compact description of this matrix, not a claim
about applications or unsupported workloads.

At 8 independent warmed contexts, JSC throughput is 5.14x zig-js by
geometric mean; scaling from the mode's own one-lane baseline is 5.16x
for zig-js and 4.62x for JSC. In the symmetric cold lifecycle, JSC
throughput is 5.44x zig-js, with 4.84x
and 4.35x scaling respectively.

zig-js's shared-realm path scales 2.37x at 8 lanes from its
own one-lane shared baseline. It has no direct JSC ratio because the public JSC embedding API exposes
isolated global contexts, not concurrent JavaScript workers sharing one object graph. Per-workload rows
matter more than any aggregate.

## Method and timed boundaries

- Both engines evaluate the exact bytes in `bench/comparison.js`. Directly compared single and independent rows use the exact invocation bytes `__benchmarkSelected(__benchmarkJobs, __benchmarkLane)`; shared mode calls the same selected function with the same jobs/lane arguments. The driver rejects unstable or cross-engine checksum mismatches.
- zig-js is built `ReleaseFast`. Direct and independent contexts explicitly enable precise GC; shared mode enables the shipping no-GIL thread configuration, which implies GC.
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
