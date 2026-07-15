# zig-js / JavaScriptCore benchmark — 2026-07-14

> This is a dated measurement, not a universal engine score. The workload source, raw samples,
> timed boundaries, and semantic differences are recorded so the result can be reproduced and challenged.

## Environment

| item | value |
| --- | --- |
| Date | 2026-07-14 |
| Host | Apple M3 Pro; 11 physical / 11 logical CPUs; 18.0 GiB |
| OS | macOS 27.0 (26A5368g) |
| Zig | 0.17.0-dev.956+2dca73595 |
| zig-js | 9e832d19a577f18e3f1d75ff2cfe4f47123b8104 |
| zig-gc | 9d4af0d49be5eba5b9283d5ed135fdf02626e2ac |
| zig-regex | 5937fa7d4db0b69575c821066afd1a7da92aa019 |
| JavaScriptCore | system framework 22625.1.20.11.3 |
| Power | Now drawing from 'Battery Power' -InternalBattery-0 (id=22806627) 90%; discharging; (no estimate) present: true |

## Single-thread result

Each row runs the same number of jobs in one GC-enabled zig-js context and one warmed JSC global context.
Both runners time the exact invocation `__benchmarkSelected(__benchmarkJobs, __benchmarkLane)`.
Lower time is better; `JSC / zig-js` is JSC throughput divided by zig-js throughput. RSD is relative standard deviation.

| workload | jobs | zig-js median (ms) | zig-js min–max (ms) | zig-js RSD | JSC median (ms) | JSC min–max (ms) | JSC RSD | JSC / zig-js |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `arithmetic` | 240 | 84.666 | 84.155–86.049 | 0.78% | 360.032 | 353.005–364.168 | 1.20% | 0.24x |
| `properties` | 300 | 90.043 | 89.548–93.635 | 1.61% | 299.629 | 298.287–312.739 | 1.69% | 0.30x |
| `polymorphic_properties` | 400 | 91.538 | 85.626–111.476 | 9.36% | 211.314 | 208.450–223.357 | 2.59% | 0.43x |
| `object_churn` | 100 | 120.334 | 116.819–790.283 | 109.05% | 118.117 | 116.391–120.471 | 1.08% | 1.02x |
| `arrays` | 550 | 87.173 | 80.479–119.053 | 14.75% | 158.456 | 157.320–174.434 | 3.98% | 0.55x |
| `direct_calls` | 600 | 64.822 | 62.414–68.219 | 3.07% | 131.926 | 124.366–144.888 | 5.39% | 0.49x |
| `method_calls` | 500 | 65.177 | 64.795–68.138 | 1.90% | 142.794 | 142.092–148.895 | 2.05% | 0.46x |
| `closure_calls` | 600 | 64.538 | 64.083–82.093 | 9.87% | 195.889 | 194.634–205.220 | 1.90% | 0.33x |
| `arguments_calls` | 600 | 71.449 | 69.688–76.049 | 3.60% | 337.613 | 324.476–347.826 | 2.21% | 0.21x |
| `fibonacci` | 125 | 85.262 | 85.089–96.858 | 5.14% | 469.077 | 463.164–476.857 | 1.17% | 0.18x |

## Independent-context steady state

Both engines keep one warmed context on one persistent OS worker per lane. The timed region contains the
same semaphore dispatch, exact invocation, and completion wait. Every lane performs the full job count.
`scaling` uses the same engine and mode at one lane; cross-engine throughput is directly comparable.

| workload | lanes | jobs/lane | zig-js median (ms) | zig-js min–max (ms) | zig-js RSD | JSC median (ms) | JSC min–max (ms) | JSC RSD | JSC / zig-js | zig-js scaling | JSC scaling |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `arithmetic` | 1 | 240 | 85.678 | 85.060–96.285 | 4.59% | 356.799 | 353.344–413.869 | 5.95% | 0.24x | 1.00x | 1.00x |
| `arithmetic` | 2 | 240 | 85.439 | 85.225–95.124 | 4.28% | 362.913 | 359.179–411.813 | 5.09% | 0.24x | 2.01x | 1.97x |
| `arithmetic` | 4 | 240 | 89.027 | 87.529–107.673 | 7.70% | 375.729 | 374.066–382.132 | 0.75% | 0.24x | 3.85x | 3.80x |
| `arithmetic` | 8 | 240 | 110.350 | 107.759–132.791 | 7.80% | 553.636 | 543.865–563.040 | 1.20% | 0.20x | 6.21x | 5.16x |
| `properties` | 1 | 300 | 90.662 | 89.224–92.367 | 1.04% | 298.855 | 297.342–351.074 | 6.40% | 0.30x | 1.00x | 1.00x |
| `properties` | 2 | 300 | 94.720 | 93.250–96.528 | 1.22% | 325.191 | 307.128–394.562 | 8.83% | 0.29x | 1.91x | 1.84x |
| `properties` | 4 | 300 | 94.414 | 93.296–120.919 | 10.31% | 348.512 | 313.079–371.782 | 5.43% | 0.27x | 3.84x | 3.43x |
| `properties` | 8 | 300 | 129.120 | 121.017–175.465 | 14.46% | 501.985 | 476.503–557.470 | 6.12% | 0.26x | 5.62x | 4.76x |
| `polymorphic_properties` | 1 | 400 | 86.034 | 84.789–90.331 | 2.19% | 215.012 | 213.009–223.840 | 2.04% | 0.40x | 1.00x | 1.00x |
| `polymorphic_properties` | 2 | 400 | 88.289 | 85.691–96.952 | 4.71% | 219.337 | 211.554–256.233 | 6.73% | 0.40x | 1.95x | 1.96x |
| `polymorphic_properties` | 4 | 400 | 94.814 | 89.507–112.800 | 10.16% | 247.117 | 239.093–259.782 | 2.60% | 0.38x | 3.63x | 3.48x |
| `polymorphic_properties` | 8 | 400 | 151.167 | 134.781–225.119 | 19.43% | 378.777 | 328.020–410.553 | 7.39% | 0.40x | 4.55x | 4.54x |
| `object_churn` | 1 | 100 | 130.457 | 123.659–161.731 | 9.91% | 123.689 | 120.779–136.509 | 4.53% | 1.05x | 1.00x | 1.00x |
| `object_churn` | 2 | 100 | 125.978 | 123.281–136.201 | 3.41% | 138.611 | 116.847–203.191 | 21.58% | 0.91x | 2.07x | 1.78x |
| `object_churn` | 4 | 100 | 211.005 | 203.217–240.982 | 5.75% | 136.849 | 127.719–166.612 | 9.51% | 1.54x | 2.47x | 3.62x |
| `object_churn` | 8 | 100 | 465.616 | 433.833–507.760 | 6.73% | 200.717 | 192.943–247.018 | 8.96% | 2.32x | 2.24x | 4.93x |
| `arrays` | 1 | 550 | 82.018 | 79.296–84.023 | 1.91% | 157.929 | 156.705–245.310 | 18.81% | 0.52x | 1.00x | 1.00x |
| `arrays` | 2 | 550 | 79.736 | 79.632–81.826 | 0.99% | 154.034 | 151.680–164.678 | 3.18% | 0.52x | 2.06x | 2.05x |
| `arrays` | 4 | 550 | 87.459 | 86.397–134.152 | 18.60% | 187.416 | 173.727–219.739 | 7.97% | 0.47x | 3.75x | 3.37x |
| `arrays` | 8 | 550 | 134.196 | 130.741–176.554 | 14.21% | 265.228 | 256.103–279.272 | 3.37% | 0.51x | 4.89x | 4.76x |
| `direct_calls` | 1 | 600 | 64.677 | 62.112–70.796 | 4.09% | 122.725 | 120.622–129.048 | 2.30% | 0.53x | 1.00x | 1.00x |
| `direct_calls` | 2 | 600 | 68.423 | 62.171–86.596 | 14.05% | 128.891 | 122.525–259.972 | 32.46% | 0.53x | 1.89x | 1.90x |
| `direct_calls` | 4 | 600 | 64.236 | 63.480–77.900 | 8.89% | 152.615 | 136.261–182.395 | 12.31% | 0.42x | 4.03x | 3.22x |
| `direct_calls` | 8 | 600 | 95.484 | 87.043–102.542 | 4.99% | 212.386 | 200.528–226.169 | 4.17% | 0.45x | 5.42x | 4.62x |
| `method_calls` | 1 | 500 | 64.876 | 64.366–65.934 | 0.93% | 143.052 | 142.761–145.273 | 0.62% | 0.45x | 1.00x | 1.00x |
| `method_calls` | 2 | 500 | 64.795 | 64.462–67.420 | 1.88% | 156.758 | 147.259–194.332 | 10.93% | 0.41x | 2.00x | 1.83x |
| `method_calls` | 4 | 500 | 69.224 | 68.799–80.163 | 6.22% | 162.735 | 156.116–184.556 | 6.53% | 0.43x | 3.75x | 3.52x |
| `method_calls` | 8 | 500 | 106.249 | 99.338–144.888 | 13.78% | 242.312 | 232.074–261.843 | 4.71% | 0.44x | 4.88x | 4.72x |
| `closure_calls` | 1 | 600 | 64.241 | 64.012–66.076 | 1.19% | 193.694 | 192.542–197.441 | 0.85% | 0.33x | 1.00x | 1.00x |
| `closure_calls` | 2 | 600 | 64.796 | 64.707–66.962 | 1.33% | 196.978 | 196.447–206.216 | 1.77% | 0.33x | 1.98x | 1.97x |
| `closure_calls` | 4 | 600 | 67.846 | 66.799–79.101 | 7.37% | 262.190 | 248.372–317.377 | 8.39% | 0.26x | 3.79x | 2.96x |
| `closure_calls` | 8 | 600 | 94.650 | 93.452–106.934 | 5.27% | 338.706 | 322.484–365.071 | 4.14% | 0.28x | 5.43x | 4.57x |
| `arguments_calls` | 1 | 600 | 76.563 | 74.979–78.287 | 1.50% | 343.474 | 334.531–360.162 | 2.39% | 0.22x | 1.00x | 1.00x |
| `arguments_calls` | 2 | 600 | 70.287 | 70.084–72.088 | 1.09% | 318.500 | 315.527–340.103 | 3.39% | 0.22x | 2.18x | 2.16x |
| `arguments_calls` | 4 | 600 | 74.366 | 72.806–97.834 | 12.14% | 352.584 | 342.249–370.587 | 2.91% | 0.21x | 4.12x | 3.90x |
| `arguments_calls` | 8 | 600 | 108.220 | 105.126–118.160 | 3.82% | 536.621 | 520.514–544.771 | 1.70% | 0.20x | 5.66x | 5.12x |
| `fibonacci` | 1 | 125 | 87.719 | 86.011–135.997 | 19.93% | 470.639 | 465.195–515.961 | 3.81% | 0.19x | 1.00x | 1.00x |
| `fibonacci` | 2 | 125 | 97.118 | 93.574–110.784 | 5.88% | 475.996 | 468.958–516.637 | 3.47% | 0.20x | 1.81x | 1.98x |
| `fibonacci` | 4 | 125 | 110.947 | 93.602–129.872 | 11.17% | 496.533 | 484.481–570.082 | 5.81% | 0.22x | 3.16x | 3.79x |
| `fibonacci` | 8 | 125 | 129.324 | 126.672–162.589 | 9.61% | 732.437 | 704.770–770.431 | 3.44% | 0.18x | 5.43x | 5.14x |

## Independent-context cold lifecycle

Neither engine warms these contexts. The timer covers OS-thread creation, context creation, workload-source
evaluation and configuration, the exact invocation, context destruction, and OS-thread join on both sides.
`scaling` uses the same engine and cold lifecycle at one lane.

| workload | lanes | jobs/lane | zig-js median (ms) | zig-js min–max (ms) | zig-js RSD | JSC median (ms) | JSC min–max (ms) | JSC RSD | JSC / zig-js | zig-js scaling | JSC scaling |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `arithmetic` | 1 | 240 | 88.246 | 86.560–89.380 | 1.18% | 356.968 | 354.804–374.943 | 2.03% | 0.25x | 1.00x | 1.00x |
| `arithmetic` | 2 | 240 | 87.861 | 87.584–89.863 | 0.92% | 362.795 | 359.763–365.210 | 0.52% | 0.24x | 2.01x | 1.97x |
| `arithmetic` | 4 | 240 | 93.085 | 89.911–103.996 | 5.23% | 378.731 | 375.827–404.485 | 2.62% | 0.25x | 3.79x | 3.77x |
| `arithmetic` | 8 | 240 | 114.882 | 111.441–120.677 | 2.99% | 572.831 | 561.338–600.702 | 2.28% | 0.20x | 6.15x | 4.99x |
| `properties` | 1 | 300 | 91.835 | 90.816–95.983 | 1.86% | 301.409 | 298.211–328.599 | 3.41% | 0.30x | 1.00x | 1.00x |
| `properties` | 2 | 300 | 93.857 | 93.278–95.001 | 0.74% | 311.093 | 304.729–400.664 | 10.45% | 0.30x | 1.96x | 1.94x |
| `properties` | 4 | 300 | 100.516 | 96.305–150.745 | 17.67% | 338.862 | 313.086–392.581 | 8.11% | 0.30x | 3.65x | 3.56x |
| `properties` | 8 | 300 | 129.374 | 124.324–134.322 | 3.01% | 527.903 | 495.085–612.082 | 9.46% | 0.25x | 5.68x | 4.57x |
| `polymorphic_properties` | 1 | 400 | 87.020 | 86.281–91.670 | 2.59% | 215.534 | 212.110–291.988 | 12.58% | 0.40x | 1.00x | 1.00x |
| `polymorphic_properties` | 2 | 400 | 93.405 | 88.022–126.813 | 15.39% | 233.682 | 212.417–286.161 | 9.41% | 0.40x | 1.86x | 1.84x |
| `polymorphic_properties` | 4 | 400 | 91.501 | 90.045–109.362 | 7.64% | 238.463 | 233.705–253.378 | 2.85% | 0.38x | 3.80x | 3.62x |
| `polymorphic_properties` | 8 | 400 | 142.720 | 133.327–166.762 | 8.02% | 364.991 | 351.685–411.892 | 5.48% | 0.39x | 4.88x | 4.72x |
| `object_churn` | 1 | 100 | 129.617 | 123.592–174.868 | 13.08% | 126.713 | 122.796–129.325 | 1.90% | 1.02x | 1.00x | 1.00x |
| `object_churn` | 2 | 100 | 157.835 | 147.461–226.991 | 16.84% | 135.455 | 125.858–141.286 | 4.68% | 1.17x | 1.64x | 1.87x |
| `object_churn` | 4 | 100 | 216.565 | 213.175–296.855 | 13.36% | 134.909 | 132.793–147.668 | 4.67% | 1.61x | 2.39x | 3.76x |
| `object_churn` | 8 | 100 | 485.536 | 459.859–525.159 | 4.91% | 220.622 | 203.555–300.413 | 17.58% | 2.20x | 2.14x | 4.59x |
| `arrays` | 1 | 550 | 78.336 | 76.287–80.875 | 1.91% | 151.699 | 149.807–172.240 | 5.25% | 0.52x | 1.00x | 1.00x |
| `arrays` | 2 | 550 | 79.070 | 78.864–103.582 | 11.01% | 153.280 | 151.490–153.923 | 0.57% | 0.52x | 1.98x | 1.98x |
| `arrays` | 4 | 550 | 90.614 | 84.896–108.694 | 9.43% | 183.455 | 172.410–215.552 | 8.95% | 0.49x | 3.46x | 3.31x |
| `arrays` | 8 | 550 | 137.301 | 130.129–171.084 | 10.42% | 269.142 | 265.241–329.775 | 8.37% | 0.51x | 4.56x | 4.51x |
| `direct_calls` | 1 | 600 | 67.795 | 61.201–83.410 | 11.23% | 140.747 | 130.743–173.124 | 10.11% | 0.48x | 1.00x | 1.00x |
| `direct_calls` | 2 | 600 | 63.203 | 62.374–65.789 | 1.94% | 125.046 | 123.460–154.370 | 8.62% | 0.51x | 2.15x | 2.25x |
| `direct_calls` | 4 | 600 | 68.349 | 63.770–109.605 | 22.58% | 140.768 | 138.726–264.029 | 28.62% | 0.49x | 3.97x | 4.00x |
| `direct_calls` | 8 | 600 | 89.922 | 88.910–102.429 | 6.39% | 214.418 | 209.092–238.509 | 4.67% | 0.42x | 6.03x | 5.25x |
| `method_calls` | 1 | 500 | 65.672 | 65.476–67.118 | 0.96% | 147.081 | 143.739–183.045 | 9.11% | 0.45x | 1.00x | 1.00x |
| `method_calls` | 2 | 500 | 67.714 | 67.189–69.148 | 1.05% | 145.468 | 145.003–150.292 | 1.28% | 0.47x | 1.94x | 2.02x |
| `method_calls` | 4 | 500 | 69.801 | 68.441–84.676 | 8.13% | 162.185 | 157.518–173.669 | 4.23% | 0.43x | 3.76x | 3.63x |
| `method_calls` | 8 | 500 | 107.559 | 100.925–114.296 | 4.79% | 245.680 | 238.991–317.233 | 10.89% | 0.44x | 4.88x | 4.79x |
| `closure_calls` | 1 | 600 | 65.802 | 65.650–67.482 | 1.07% | 195.870 | 194.831–204.374 | 1.68% | 0.34x | 1.00x | 1.00x |
| `closure_calls` | 2 | 600 | 67.959 | 66.665–69.945 | 1.85% | 202.810 | 198.888–204.409 | 1.04% | 0.34x | 1.94x | 1.93x |
| `closure_calls` | 4 | 600 | 70.792 | 68.827–85.051 | 7.72% | 228.267 | 221.456–334.747 | 16.32% | 0.31x | 3.72x | 3.43x |
| `closure_calls` | 8 | 600 | 93.844 | 90.098–111.111 | 8.15% | 373.155 | 346.595–426.503 | 8.01% | 0.25x | 5.61x | 4.20x |
| `arguments_calls` | 1 | 600 | 79.589 | 76.685–82.913 | 3.19% | 320.820 | 315.683–340.861 | 3.15% | 0.25x | 1.00x | 1.00x |
| `arguments_calls` | 2 | 600 | 74.892 | 73.503–79.535 | 3.29% | 319.005 | 316.966–378.122 | 6.90% | 0.23x | 2.13x | 2.01x |
| `arguments_calls` | 4 | 600 | 83.093 | 79.723–109.457 | 12.34% | 369.986 | 344.531–422.029 | 7.93% | 0.22x | 3.83x | 3.47x |
| `arguments_calls` | 8 | 600 | 114.592 | 111.738–150.702 | 11.59% | 541.849 | 497.090–678.040 | 10.99% | 0.21x | 5.56x | 4.74x |
| `fibonacci` | 1 | 125 | 84.248 | 83.365–90.497 | 3.00% | 485.259 | 471.556–513.052 | 2.64% | 0.17x | 1.00x | 1.00x |
| `fibonacci` | 2 | 125 | 93.627 | 93.040–114.616 | 8.09% | 472.094 | 470.137–482.291 | 0.93% | 0.20x | 1.80x | 2.06x |
| `fibonacci` | 4 | 125 | 102.451 | 92.447–115.768 | 7.72% | 487.326 | 485.273–556.634 | 5.22% | 0.21x | 3.29x | 3.98x |
| `fibonacci` | 8 | 125 | 131.804 | 131.471–195.510 | 19.48% | 718.974 | 712.911–798.203 | 4.16% | 0.18x | 5.11x | 5.40x |

## zig-js shared-realm scaling

This is zig-js's distinct no-GIL shared-object-graph model, which JSC's public C API does not provide.
The timed region creates JavaScript `Thread`s, performs the work, and joins them. Scaling uses the same
shared-realm path at one lane, so thread lifecycle overhead is present in every row.

| workload | lanes | jobs/lane | median (ms) | min–max (ms) | RSD | scaling |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `arithmetic` | 1 | 240 | 86.075 | 84.755–125.554 | 16.40% | 1.00x |
| `arithmetic` | 2 | 240 | 86.305 | 85.751–88.378 | 1.03% | 1.99x |
| `arithmetic` | 4 | 240 | 89.129 | 87.806–92.930 | 2.28% | 3.86x |
| `arithmetic` | 8 | 240 | 109.816 | 107.228–133.354 | 8.22% | 6.27x |
| `properties` | 1 | 300 | 131.726 | 128.571–133.583 | 1.56% | 1.00x |
| `properties` | 2 | 300 | 131.676 | 130.656–135.864 | 1.45% | 2.00x |
| `properties` | 4 | 300 | 138.544 | 135.648–161.742 | 6.58% | 3.80x |
| `properties` | 8 | 300 | 187.112 | 174.992–252.765 | 13.04% | 5.63x |
| `polymorphic_properties` | 1 | 400 | 536.687 | 528.788–575.755 | 2.86% | 1.00x |
| `polymorphic_properties` | 2 | 400 | 561.479 | 547.387–576.836 | 1.83% | 1.91x |
| `polymorphic_properties` | 4 | 400 | 579.875 | 554.239–637.630 | 4.60% | 3.70x |
| `polymorphic_properties` | 8 | 400 | 779.673 | 743.010–801.024 | 2.59% | 5.51x |
| `object_churn` | 1 | 100 | 187.078 | 185.118–279.419 | 17.42% | 1.00x |
| `object_churn` | 2 | 100 | 420.071 | 379.432–968.379 | 41.44% | 0.89x |
| `object_churn` | 4 | 100 | 2250.007 | 846.510–2710.572 | 28.40% | 0.33x |
| `object_churn` | 8 | 100 | 7763.931 | 3666.373–8010.273 | 21.96% | 0.19x |
| `arrays` | 1 | 550 | 89.650 | 82.988–97.827 | 5.98% | 1.00x |
| `arrays` | 2 | 550 | 85.380 | 84.794–127.829 | 17.09% | 2.10x |
| `arrays` | 4 | 550 | 105.984 | 98.927–193.617 | 28.44% | 3.38x |
| `arrays` | 8 | 550 | 264.848 | 255.428–276.879 | 2.64% | 2.71x |
| `direct_calls` | 1 | 600 | 67.072 | 60.965–80.636 | 10.53% | 1.00x |
| `direct_calls` | 2 | 600 | 59.634 | 58.861–63.455 | 2.97% | 2.25x |
| `direct_calls` | 4 | 600 | 70.843 | 65.326–92.260 | 12.89% | 3.79x |
| `direct_calls` | 8 | 600 | 94.030 | 90.262–121.745 | 12.12% | 5.71x |
| `method_calls` | 1 | 500 | 122.013 | 120.831–189.284 | 18.95% | 1.00x |
| `method_calls` | 2 | 500 | 125.094 | 122.095–128.263 | 2.09% | 1.95x |
| `method_calls` | 4 | 500 | 129.242 | 125.965–139.395 | 3.39% | 3.78x |
| `method_calls` | 8 | 500 | 193.290 | 184.632–206.742 | 3.72% | 5.05x |
| `closure_calls` | 1 | 600 | 65.727 | 64.930–67.125 | 1.27% | 1.00x |
| `closure_calls` | 2 | 600 | 66.117 | 65.894–67.657 | 1.01% | 1.99x |
| `closure_calls` | 4 | 600 | 68.051 | 67.486–74.084 | 4.23% | 3.86x |
| `closure_calls` | 8 | 600 | 101.745 | 95.343–108.716 | 4.43% | 5.17x |
| `arguments_calls` | 1 | 600 | 73.269 | 69.656–78.709 | 4.29% | 1.00x |
| `arguments_calls` | 2 | 600 | 71.460 | 70.229–77.081 | 3.32% | 2.05x |
| `arguments_calls` | 4 | 600 | 74.679 | 72.991–83.901 | 5.35% | 3.92x |
| `arguments_calls` | 8 | 600 | 103.368 | 95.790–172.444 | 23.54% | 5.67x |
| `fibonacci` | 1 | 125 | 241.373 | 240.113–291.112 | 7.71% | 1.00x |
| `fibonacci` | 2 | 125 | 273.448 | 266.940–321.263 | 6.71% | 1.77x |
| `fibonacci` | 4 | 125 | 268.269 | 261.014–338.787 | 10.35% | 3.60x |
| `fibonacci` | 8 | 125 | 410.751 | 393.382–432.871 | 3.64% | 4.70x |

## Reading the result

Across these 10 deliberately small kernels, JSC's single-context throughput is 0.37x
the zig-js throughput by geometric mean. These kernels deliberately exercise guarded native/VM tiers that
zig-js currently implements; rows outside those documented subsets continue through general bytecode paths.
The number is a compact description of this matrix, not a claim about applications or unsupported workloads.

At 8 independent warmed contexts, JSC throughput is 0.37x zig-js by
geometric mean; scaling from the mode's own one-lane baseline is 4.88x
for zig-js and 4.83x for JSC. In the symmetric cold lifecycle, JSC
throughput is 0.36x zig-js, with 4.89x
and 4.76x scaling respectively.

zig-js's shared-realm path scales 3.64x at 8 lanes from its
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

Raw samples: [`benchmark-comparison-2026-07-14.tsv`](benchmark-comparison-2026-07-14.tsv)
