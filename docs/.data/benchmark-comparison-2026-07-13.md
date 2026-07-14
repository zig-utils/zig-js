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
| zig-js | 27ebbfb1660af39aa8b21cfc1801fceb202c0fe1 |
| JavaScriptCore | system framework 22625.1.20.11.3 |
| Power | Now drawing from 'Battery Power' -InternalBattery-0 (id=22806627) 74%; discharging; (no estimate) present: true |

## Single-thread result

Each row runs the same number of jobs in one GC-enabled zig-js context and one warmed JSC global context.
Both runners time the exact invocation `__benchmarkSelected(__benchmarkJobs, __benchmarkLane)`.
Lower time is better; `JSC / zig-js` is JSC throughput divided by zig-js throughput. RSD is relative standard deviation.

| workload | jobs | zig-js median (ms) | zig-js min–max (ms) | zig-js RSD | JSC median (ms) | JSC min–max (ms) | JSC RSD | JSC / zig-js |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `arithmetic` | 160 | 56.360 | 55.860–61.776 | 3.76% | 242.893 | 239.710–383.513 | 19.91% | 0.23x |
| `properties` | 200 | 59.821 | 59.504–62.285 | 1.64% | 208.153 | 205.346–213.763 | 1.28% | 0.29x |
| `arrays` | 450 | 64.517 | 63.706–67.913 | 2.34% | 130.636 | 129.983–132.167 | 0.63% | 0.49x |
| `direct_calls` | 500 | 68.548 | 65.934–70.116 | 1.93% | 105.109 | 101.496–106.403 | 1.89% | 0.65x |
| `method_calls` | 500 | 80.100 | 79.373–90.126 | 4.85% | 144.332 | 143.792–151.637 | 2.20% | 0.55x |
| `closure_calls` | 500 | 73.039 | 71.796–75.335 | 1.99% | 165.998 | 163.487–171.597 | 1.85% | 0.44x |
| `arguments_calls` | 400 | 64.888 | 63.040–74.916 | 6.19% | 205.600 | 204.409–278.752 | 12.55% | 0.32x |
| `fibonacci` | 100 | 69.739 | 69.023–78.319 | 4.94% | 387.101 | 377.185–395.901 | 1.93% | 0.18x |

## Independent-context steady state

Both engines keep one warmed context on one persistent OS worker per lane. The timed region contains the
same semaphore dispatch, exact invocation, and completion wait. Every lane performs the full job count.
`scaling` uses the same engine and mode at one lane; cross-engine throughput is directly comparable.

| workload | lanes | jobs/lane | zig-js median (ms) | zig-js min–max (ms) | zig-js RSD | JSC median (ms) | JSC min–max (ms) | JSC RSD | JSC / zig-js | zig-js scaling | JSC scaling |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `arithmetic` | 1 | 160 | 57.152 | 57.017–58.900 | 1.19% | 241.214 | 238.231–245.025 | 0.94% | 0.24x | 1.00x | 1.00x |
| `arithmetic` | 2 | 160 | 59.192 | 58.558–60.342 | 1.04% | 244.317 | 242.956–251.690 | 1.35% | 0.24x | 1.93x | 1.97x |
| `arithmetic` | 4 | 160 | 64.982 | 61.651–99.542 | 21.57% | 302.584 | 282.063–311.419 | 3.66% | 0.21x | 3.52x | 3.19x |
| `arithmetic` | 8 | 160 | 75.017 | 72.749–81.555 | 3.75% | 377.715 | 374.991–382.562 | 0.82% | 0.20x | 6.09x | 5.11x |
| `properties` | 1 | 200 | 59.273 | 58.731–60.712 | 1.30% | 202.978 | 201.495–231.500 | 5.27% | 0.29x | 1.00x | 1.00x |
| `properties` | 2 | 200 | 60.070 | 59.321–67.113 | 5.25% | 215.728 | 204.160–227.447 | 3.66% | 0.28x | 1.97x | 1.88x |
| `properties` | 4 | 200 | 76.526 | 66.508–81.364 | 6.60% | 228.203 | 222.858–231.643 | 1.45% | 0.34x | 3.10x | 3.56x |
| `properties` | 8 | 200 | 88.670 | 87.660–97.403 | 3.79% | 326.927 | 321.600–345.861 | 3.39% | 0.27x | 5.35x | 4.97x |
| `arrays` | 1 | 450 | 64.619 | 63.210–67.432 | 2.14% | 131.644 | 130.420–132.210 | 0.51% | 0.49x | 1.00x | 1.00x |
| `arrays` | 2 | 450 | 67.554 | 65.933–93.603 | 15.04% | 132.511 | 132.216–150.741 | 5.18% | 0.51x | 1.91x | 1.99x |
| `arrays` | 4 | 450 | 72.584 | 68.965–96.498 | 12.68% | 148.394 | 138.567–188.644 | 11.58% | 0.49x | 3.56x | 3.55x |
| `arrays` | 8 | 450 | 102.011 | 95.162–114.741 | 8.26% | 218.555 | 207.658–243.082 | 5.37% | 0.47x | 5.07x | 4.82x |
| `direct_calls` | 1 | 500 | 65.845 | 65.025–66.881 | 0.95% | 100.303 | 98.681–109.623 | 3.69% | 0.66x | 1.00x | 1.00x |
| `direct_calls` | 2 | 500 | 67.029 | 66.892–68.568 | 1.05% | 102.974 | 101.723–104.809 | 1.06% | 0.65x | 1.96x | 1.95x |
| `direct_calls` | 4 | 500 | 77.960 | 70.722–79.758 | 5.76% | 114.570 | 111.858–167.193 | 16.31% | 0.68x | 3.38x | 3.50x |
| `direct_calls` | 8 | 500 | 88.550 | 86.598–92.346 | 2.51% | 170.483 | 164.434–175.174 | 2.47% | 0.52x | 5.95x | 4.71x |
| `method_calls` | 1 | 500 | 82.513 | 79.728–103.325 | 9.79% | 152.058 | 148.074–162.931 | 3.08% | 0.54x | 1.00x | 1.00x |
| `method_calls` | 2 | 500 | 85.085 | 81.064–146.988 | 28.27% | 155.166 | 150.176–203.148 | 11.48% | 0.55x | 1.94x | 1.96x |
| `method_calls` | 4 | 500 | 87.943 | 86.370–94.228 | 2.98% | 205.007 | 170.581–312.804 | 23.82% | 0.43x | 3.75x | 2.97x |
| `method_calls` | 8 | 500 | 112.945 | 110.671–124.974 | 4.18% | 239.010 | 231.819–267.984 | 5.00% | 0.47x | 5.84x | 5.09x |
| `closure_calls` | 1 | 500 | 71.779 | 70.607–74.941 | 2.32% | 167.625 | 162.512–176.099 | 2.49% | 0.43x | 1.00x | 1.00x |
| `closure_calls` | 2 | 500 | 74.182 | 71.110–98.195 | 12.51% | 167.641 | 166.426–169.816 | 0.65% | 0.44x | 1.94x | 2.00x |
| `closure_calls` | 4 | 500 | 79.725 | 75.376–102.766 | 11.09% | 193.118 | 187.684–205.114 | 3.60% | 0.41x | 3.60x | 3.47x |
| `closure_calls` | 8 | 500 | 96.799 | 92.594–103.843 | 3.95% | 280.139 | 271.632–293.334 | 2.94% | 0.35x | 5.93x | 4.79x |
| `arguments_calls` | 1 | 400 | 61.454 | 60.434–65.101 | 2.90% | 204.082 | 203.461–206.628 | 0.51% | 0.30x | 1.00x | 1.00x |
| `arguments_calls` | 2 | 400 | 62.206 | 61.834–66.332 | 2.74% | 214.256 | 209.780–224.936 | 2.43% | 0.29x | 1.98x | 1.91x |
| `arguments_calls` | 4 | 400 | 80.723 | 76.508–113.634 | 15.42% | 252.956 | 237.643–267.204 | 4.17% | 0.32x | 3.05x | 3.23x |
| `arguments_calls` | 8 | 400 | 92.878 | 88.761–177.573 | 30.38% | 373.951 | 363.433–418.695 | 5.77% | 0.25x | 5.29x | 4.37x |
| `fibonacci` | 1 | 100 | 69.433 | 68.778–71.016 | 1.18% | 375.561 | 375.156–377.458 | 0.21% | 0.18x | 1.00x | 1.00x |
| `fibonacci` | 2 | 100 | 70.874 | 70.415–72.074 | 1.02% | 400.097 | 382.051–411.716 | 2.72% | 0.18x | 1.96x | 1.88x |
| `fibonacci` | 4 | 100 | 72.686 | 71.985–78.255 | 3.24% | 408.422 | 398.216–456.543 | 4.94% | 0.18x | 3.82x | 3.68x |
| `fibonacci` | 8 | 100 | 106.903 | 103.503–122.614 | 6.49% | 601.253 | 573.011–652.538 | 4.79% | 0.18x | 5.20x | 5.00x |

## Independent-context cold lifecycle

Neither engine warms these contexts. The timer covers OS-thread creation, context creation, workload-source
evaluation and configuration, the exact invocation, context destruction, and OS-thread join on both sides.
`scaling` uses the same engine and cold lifecycle at one lane.

| workload | lanes | jobs/lane | zig-js median (ms) | zig-js min–max (ms) | zig-js RSD | JSC median (ms) | JSC min–max (ms) | JSC RSD | JSC / zig-js | zig-js scaling | JSC scaling |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `arithmetic` | 1 | 160 | 58.816 | 58.418–60.372 | 1.13% | 247.606 | 241.177–253.695 | 1.48% | 0.24x | 1.00x | 1.00x |
| `arithmetic` | 2 | 160 | 60.007 | 59.498–63.020 | 2.58% | 246.759 | 241.661–250.121 | 1.09% | 0.24x | 1.96x | 2.01x |
| `arithmetic` | 4 | 160 | 69.524 | 64.454–85.873 | 10.25% | 289.864 | 281.492–304.753 | 2.87% | 0.24x | 3.38x | 3.42x |
| `arithmetic` | 8 | 160 | 81.403 | 77.132–85.457 | 3.03% | 406.001 | 377.702–597.803 | 19.13% | 0.20x | 5.78x | 4.88x |
| `properties` | 1 | 200 | 64.869 | 61.306–87.207 | 13.95% | 210.942 | 203.740–215.365 | 1.93% | 0.31x | 1.00x | 1.00x |
| `properties` | 2 | 200 | 63.713 | 60.837–64.792 | 2.29% | 206.188 | 204.928–218.038 | 2.68% | 0.31x | 2.04x | 2.05x |
| `properties` | 4 | 200 | 73.527 | 68.708–81.807 | 6.15% | 230.683 | 227.586–282.160 | 8.25% | 0.32x | 3.53x | 3.66x |
| `properties` | 8 | 200 | 91.435 | 85.864–161.799 | 27.67% | 344.732 | 326.928–387.073 | 5.47% | 0.27x | 5.68x | 4.90x |
| `arrays` | 1 | 450 | 64.743 | 64.291–67.361 | 2.08% | 132.591 | 131.473–135.344 | 1.03% | 0.49x | 1.00x | 1.00x |
| `arrays` | 2 | 450 | 69.302 | 67.964–75.215 | 3.49% | 143.446 | 131.105–153.565 | 5.38% | 0.48x | 1.87x | 1.85x |
| `arrays` | 4 | 450 | 71.021 | 70.347–80.911 | 5.90% | 159.937 | 141.433–191.143 | 11.38% | 0.44x | 3.65x | 3.32x |
| `arrays` | 8 | 450 | 105.462 | 100.734–150.782 | 16.17% | 219.432 | 213.057–275.767 | 9.59% | 0.48x | 4.91x | 4.83x |
| `direct_calls` | 1 | 500 | 68.392 | 67.331–69.971 | 1.15% | 101.456 | 100.519–105.002 | 1.76% | 0.67x | 1.00x | 1.00x |
| `direct_calls` | 2 | 500 | 71.104 | 70.251–72.058 | 0.89% | 106.729 | 102.976–123.426 | 6.37% | 0.67x | 1.92x | 1.90x |
| `direct_calls` | 4 | 500 | 73.589 | 70.798–79.198 | 4.76% | 116.124 | 114.241–188.046 | 20.91% | 0.63x | 3.72x | 3.49x |
| `direct_calls` | 8 | 500 | 102.367 | 100.062–192.586 | 29.25% | 185.612 | 168.842–224.396 | 9.68% | 0.55x | 5.34x | 4.37x |
| `method_calls` | 1 | 500 | 84.736 | 81.581–85.978 | 1.90% | 148.087 | 144.937–159.657 | 3.39% | 0.57x | 1.00x | 1.00x |
| `method_calls` | 2 | 500 | 90.352 | 83.137–127.793 | 19.44% | 155.478 | 149.953–188.096 | 9.85% | 0.58x | 1.88x | 1.90x |
| `method_calls` | 4 | 500 | 95.856 | 89.681–105.484 | 5.27% | 172.530 | 160.888–202.949 | 8.34% | 0.56x | 3.54x | 3.43x |
| `method_calls` | 8 | 500 | 122.797 | 119.334–126.939 | 2.25% | 249.661 | 230.291–277.072 | 6.41% | 0.49x | 5.52x | 4.75x |
| `closure_calls` | 1 | 500 | 73.720 | 71.378–83.471 | 6.07% | 169.261 | 165.119–180.724 | 3.48% | 0.44x | 1.00x | 1.00x |
| `closure_calls` | 2 | 500 | 73.996 | 73.071–75.539 | 1.17% | 170.320 | 167.662–174.563 | 1.67% | 0.43x | 1.99x | 1.99x |
| `closure_calls` | 4 | 500 | 79.916 | 77.979–89.903 | 5.19% | 194.751 | 192.849–215.204 | 4.46% | 0.41x | 3.69x | 3.48x |
| `closure_calls` | 8 | 500 | 104.162 | 99.644–108.695 | 3.51% | 299.167 | 277.827–326.871 | 5.59% | 0.35x | 5.66x | 4.53x |
| `arguments_calls` | 1 | 400 | 64.647 | 62.305–65.455 | 1.80% | 206.057 | 205.458–257.055 | 8.88% | 0.31x | 1.00x | 1.00x |
| `arguments_calls` | 2 | 400 | 63.340 | 62.978–65.427 | 1.30% | 217.579 | 212.465–221.871 | 1.66% | 0.29x | 2.04x | 1.89x |
| `arguments_calls` | 4 | 400 | 83.118 | 70.317–143.031 | 28.62% | 234.427 | 227.310–270.105 | 6.27% | 0.35x | 3.11x | 3.52x |
| `arguments_calls` | 8 | 400 | 99.559 | 88.004–115.660 | 10.29% | 382.803 | 366.633–396.784 | 2.89% | 0.26x | 5.19x | 4.31x |
| `fibonacci` | 1 | 100 | 70.038 | 69.893–87.991 | 9.15% | 377.455 | 376.985–382.358 | 0.50% | 0.19x | 1.00x | 1.00x |
| `fibonacci` | 2 | 100 | 70.627 | 70.555–72.826 | 1.16% | 391.545 | 379.147–466.728 | 8.44% | 0.18x | 1.98x | 1.93x |
| `fibonacci` | 4 | 100 | 87.848 | 82.831–115.757 | 14.07% | 399.961 | 392.268–460.729 | 6.27% | 0.22x | 3.19x | 3.77x |
| `fibonacci` | 8 | 100 | 106.917 | 101.001–117.397 | 5.34% | 631.247 | 583.753–680.833 | 5.94% | 0.17x | 5.24x | 4.78x |

## zig-js shared-realm scaling

This is zig-js's distinct no-GIL shared-object-graph model, which JSC's public C API does not provide.
The timed region creates JavaScript `Thread`s, performs the work, and joins them. Scaling uses the same
shared-realm path at one lane, so thread lifecycle overhead is present in every row.

| workload | lanes | jobs/lane | median (ms) | min–max (ms) | RSD | scaling |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `arithmetic` | 1 | 160 | 59.262 | 57.915–70.256 | 7.36% | 1.00x |
| `arithmetic` | 2 | 160 | 58.495 | 57.939–60.114 | 1.44% | 2.03x |
| `arithmetic` | 4 | 160 | 64.046 | 61.110–79.718 | 10.62% | 3.70x |
| `arithmetic` | 8 | 160 | 76.132 | 74.266–135.237 | 26.58% | 6.23x |
| `properties` | 1 | 200 | 83.543 | 81.286–103.002 | 10.84% | 1.00x |
| `properties` | 2 | 200 | 82.065 | 80.087–114.333 | 14.15% | 2.04x |
| `properties` | 4 | 200 | 95.769 | 90.359–124.070 | 11.96% | 3.49x |
| `properties` | 8 | 200 | 111.884 | 107.834–117.816 | 2.87% | 5.97x |
| `arrays` | 1 | 450 | 67.644 | 65.910–81.614 | 8.29% | 1.00x |
| `arrays` | 2 | 450 | 70.725 | 67.771–71.749 | 2.41% | 1.91x |
| `arrays` | 4 | 450 | 84.252 | 81.125–101.280 | 8.24% | 3.21x |
| `arrays` | 8 | 450 | 179.418 | 161.545–192.454 | 6.00% | 3.02x |
| `direct_calls` | 1 | 500 | 67.262 | 66.021–104.994 | 19.46% | 1.00x |
| `direct_calls` | 2 | 500 | 70.228 | 68.195–114.584 | 21.53% | 1.92x |
| `direct_calls` | 4 | 500 | 73.589 | 70.365–77.575 | 3.55% | 3.66x |
| `direct_calls` | 8 | 500 | 91.585 | 85.714–95.770 | 3.83% | 5.88x |
| `method_calls` | 1 | 500 | 91.817 | 89.776–93.993 | 1.73% | 1.00x |
| `method_calls` | 2 | 500 | 94.378 | 93.156–97.750 | 1.80% | 1.95x |
| `method_calls` | 4 | 500 | 184.233 | 116.754–251.358 | 29.29% | 1.99x |
| `method_calls` | 8 | 500 | 183.874 | 147.712–270.764 | 24.30% | 3.99x |
| `closure_calls` | 1 | 500 | 74.523 | 72.305–123.647 | 22.14% | 1.00x |
| `closure_calls` | 2 | 500 | 78.364 | 75.768–81.405 | 2.44% | 1.90x |
| `closure_calls` | 4 | 500 | 78.398 | 76.309–84.150 | 3.70% | 3.80x |
| `closure_calls` | 8 | 500 | 107.907 | 101.503–129.921 | 9.72% | 5.52x |
| `arguments_calls` | 1 | 400 | 60.552 | 59.889–66.714 | 4.54% | 1.00x |
| `arguments_calls` | 2 | 400 | 62.809 | 61.168–65.423 | 2.27% | 1.93x |
| `arguments_calls` | 4 | 400 | 68.854 | 64.473–74.314 | 4.80% | 3.52x |
| `arguments_calls` | 8 | 400 | 95.379 | 87.647–101.824 | 6.28% | 5.08x |
| `fibonacci` | 1 | 100 | 199.181 | 198.693–238.144 | 7.13% | 1.00x |
| `fibonacci` | 2 | 100 | 200.507 | 199.365–233.526 | 6.07% | 1.99x |
| `fibonacci` | 4 | 100 | 229.662 | 211.998–249.926 | 6.21% | 3.47x |
| `fibonacci` | 8 | 100 | 319.266 | 307.925–344.219 | 3.91% | 4.99x |

## Reading the result

Across these 8 deliberately small kernels, JSC's single-context throughput is 0.36x
the zig-js throughput by geometric mean. These kernels deliberately exercise guarded native/VM tiers that
zig-js currently implements; rows outside those documented subsets continue through general bytecode paths.
The number is a compact description of this matrix, not a claim about applications or unsupported workloads.

At 8 independent warmed contexts, JSC throughput is 0.31x zig-js by
geometric mean; scaling from the mode's own one-lane baseline is 5.58x
for zig-js and 4.85x for JSC. In the symmetric cold lifecycle, JSC
throughput is 0.32x zig-js, with 5.41x
and 4.66x scaling respectively.

zig-js's shared-realm path scales 4.96x at 8 lanes from its
own one-lane shared baseline. It has no direct JSC ratio because the public JSC embedding API exposes
isolated global contexts, not concurrent JavaScript workers sharing one object graph. Per-workload rows
matter more than any aggregate.

## Method and timed boundaries

- Both engines evaluate the exact bytes in `bench/comparison.js`. Directly compared single and independent rows use the exact invocation bytes `__benchmarkSelected(__benchmarkJobs, __benchmarkLane)`; shared mode calls the same selected function with the same jobs/lane arguments. The driver rejects unstable or cross-engine checksum mismatches.
- zig-js is built `ReleaseFast`. Direct and independent contexts explicitly enable precise GC; shared mode enables the shipping no-GIL thread configuration, which implies GC.
- Every measured zig-js context uses the process-wide thread-safe libc allocator, whose reusable infrastructure outlives timed cold contexts; cold mode still times every context-owned allocation and release. JSC uses its internal process allocator.
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
