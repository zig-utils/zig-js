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
| zig-js | 4e3de6f53853d6ae241132985e277096a1a24597 |
| JavaScriptCore | system framework 22625.1.20.11.3 |
| Power | Now drawing from 'Battery Power' -InternalBattery-0 (id=22806627) 93%; discharging; (no estimate) present: true |

## Single-thread result

Each row runs the same number of jobs in one GC-enabled zig-js context and one warmed JSC global context.
Both runners time the exact invocation `__benchmarkSelected(__benchmarkJobs, __benchmarkLane)`.
Lower time is better; `JSC / zig-js` is JSC throughput divided by zig-js throughput. RSD is relative standard deviation.

| workload | jobs | zig-js median (ms) | zig-js min–max (ms) | zig-js RSD | JSC median (ms) | JSC min–max (ms) | JSC RSD | JSC / zig-js |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `arithmetic` | 240 | 83.971 | 75.835–89.390 | 5.53% | 344.822 | 342.613–350.259 | 0.83% | 0.24x |
| `properties` | 300 | 88.214 | 85.654–88.968 | 1.61% | 295.844 | 289.101–298.632 | 1.27% | 0.30x |
| `polymorphic_properties` | 400 | 81.608 | 80.909–82.642 | 0.85% | 198.403 | 198.135–203.648 | 1.00% | 0.41x |
| `object_churn` | 100 | 176.398 | 176.283–176.922 | 0.15% | 116.168 | 114.246–118.920 | 1.29% | 1.52x |
| `arrays` | 550 | 81.078 | 78.690–94.849 | 6.96% | 158.210 | 151.054–196.275 | 10.07% | 0.51x |
| `direct_calls` | 600 | 56.462 | 56.344–56.731 | 0.23% | 117.743 | 116.552–118.600 | 0.62% | 0.48x |
| `method_calls` | 500 | 72.504 | 72.201–72.615 | 0.18% | 136.747 | 136.448–136.876 | 0.11% | 0.53x |
| `closure_calls` | 600 | 64.665 | 61.855–76.819 | 7.65% | 210.548 | 191.010–222.189 | 5.29% | 0.31x |
| `arguments_calls` | 600 | 70.965 | 66.882–74.928 | 4.27% | 295.125 | 294.196–311.021 | 2.01% | 0.24x |
| `fibonacci` | 125 | 83.211 | 81.908–86.237 | 2.06% | 447.072 | 445.553–452.264 | 0.53% | 0.19x |

## Independent-context steady state

Both engines keep one warmed context on one persistent OS worker per lane. The timed region contains the
same semaphore dispatch, exact invocation, and completion wait. Every lane performs the full job count.
`scaling` uses the same engine and mode at one lane; cross-engine throughput is directly comparable.

| workload | lanes | jobs/lane | zig-js median (ms) | zig-js min–max (ms) | zig-js RSD | JSC median (ms) | JSC min–max (ms) | JSC RSD | JSC / zig-js | zig-js scaling | JSC scaling |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `arithmetic` | 1 | 240 | 76.169 | 75.452–84.045 | 5.38% | 344.251 | 343.527–367.511 | 2.51% | 0.22x | 1.00x | 1.00x |
| `arithmetic` | 2 | 240 | 81.029 | 80.346–84.784 | 2.36% | 359.717 | 351.072–378.788 | 2.74% | 0.23x | 1.88x | 1.91x |
| `arithmetic` | 4 | 240 | 85.169 | 84.480–92.234 | 3.42% | 369.587 | 358.046–393.626 | 3.47% | 0.23x | 3.58x | 3.73x |
| `arithmetic` | 8 | 240 | 101.773 | 98.954–107.710 | 3.21% | 482.515 | 469.790–486.772 | 1.34% | 0.21x | 5.99x | 5.71x |
| `properties` | 1 | 300 | 88.641 | 86.401–89.676 | 1.29% | 284.821 | 284.747–298.523 | 1.92% | 0.31x | 1.00x | 1.00x |
| `properties` | 2 | 300 | 87.387 | 87.342–87.949 | 0.25% | 290.797 | 290.593–291.241 | 0.08% | 0.30x | 2.03x | 1.96x |
| `properties` | 4 | 300 | 90.112 | 89.376–90.157 | 0.41% | 302.024 | 297.199–310.188 | 1.41% | 0.30x | 3.93x | 3.77x |
| `properties` | 8 | 300 | 116.082 | 109.656–119.508 | 3.08% | 396.810 | 393.724–408.382 | 1.31% | 0.29x | 6.11x | 5.74x |
| `polymorphic_properties` | 1 | 400 | 81.723 | 80.827–82.941 | 0.90% | 198.824 | 198.101–200.667 | 0.49% | 0.41x | 1.00x | 1.00x |
| `polymorphic_properties` | 2 | 400 | 84.450 | 83.537–86.621 | 1.27% | 205.663 | 203.317–209.840 | 1.12% | 0.41x | 1.94x | 1.93x |
| `polymorphic_properties` | 4 | 400 | 84.113 | 84.066–86.258 | 0.96% | 207.745 | 207.332–211.191 | 0.65% | 0.40x | 3.89x | 3.83x |
| `polymorphic_properties` | 8 | 400 | 123.384 | 120.641–126.093 | 1.46% | 288.752 | 276.304–295.929 | 2.85% | 0.43x | 5.30x | 5.51x |
| `object_churn` | 1 | 100 | 178.529 | 178.124–178.781 | 0.14% | 114.010 | 113.575–114.406 | 0.26% | 1.57x | 1.00x | 1.00x |
| `object_churn` | 2 | 100 | 184.637 | 183.886–185.234 | 0.28% | 118.617 | 117.260–121.631 | 1.36% | 1.56x | 1.93x | 1.92x |
| `object_churn` | 4 | 100 | 271.877 | 270.007–281.312 | 1.42% | 123.370 | 122.991–128.656 | 1.64% | 2.20x | 2.63x | 3.70x |
| `object_churn` | 8 | 100 | 543.223 | 538.527–568.085 | 1.92% | 172.520 | 171.141–187.101 | 3.58% | 3.15x | 2.63x | 5.29x |
| `arrays` | 1 | 550 | 77.286 | 76.527–77.833 | 0.54% | 151.661 | 148.827–154.566 | 1.38% | 0.51x | 1.00x | 1.00x |
| `arrays` | 2 | 550 | 91.098 | 88.241–99.712 | 4.07% | 189.599 | 165.864–452.897 | 44.64% | 0.48x | 1.70x | 1.60x |
| `arrays` | 4 | 550 | 105.705 | 96.086–108.028 | 3.77% | 196.031 | 188.617–200.820 | 1.93% | 0.54x | 2.92x | 3.09x |
| `arrays` | 8 | 550 | 117.231 | 115.148–136.558 | 7.90% | 230.295 | 223.345–234.157 | 1.78% | 0.51x | 5.27x | 5.27x |
| `direct_calls` | 1 | 600 | 56.369 | 56.275–63.970 | 5.08% | 117.257 | 116.269–118.675 | 0.67% | 0.48x | 1.00x | 1.00x |
| `direct_calls` | 2 | 600 | 57.495 | 57.455–60.659 | 2.40% | 119.686 | 118.337–120.380 | 0.66% | 0.48x | 1.96x | 1.96x |
| `direct_calls` | 4 | 600 | 58.234 | 58.197–59.188 | 0.68% | 124.771 | 121.804–128.595 | 2.03% | 0.47x | 3.87x | 3.76x |
| `direct_calls` | 8 | 600 | 74.279 | 74.065–78.297 | 2.26% | 175.791 | 170.819–176.624 | 1.13% | 0.42x | 6.07x | 5.34x |
| `method_calls` | 1 | 500 | 61.458 | 61.111–62.253 | 0.71% | 136.638 | 136.541–136.963 | 0.12% | 0.45x | 1.00x | 1.00x |
| `method_calls` | 2 | 500 | 73.390 | 73.188–73.674 | 0.25% | 139.191 | 139.166–139.482 | 0.10% | 0.53x | 1.67x | 1.96x |
| `method_calls` | 4 | 500 | 65.480 | 64.969–72.512 | 4.00% | 142.962 | 142.672–143.515 | 0.25% | 0.46x | 3.75x | 3.82x |
| `method_calls` | 8 | 500 | 94.982 | 90.296–100.078 | 3.24% | 207.752 | 201.688–214.694 | 2.49% | 0.46x | 5.18x | 5.26x |
| `closure_calls` | 1 | 600 | 62.442 | 61.416–66.108 | 2.50% | 190.489 | 187.216–212.260 | 4.51% | 0.33x | 1.00x | 1.00x |
| `closure_calls` | 2 | 600 | 62.975 | 62.769–63.909 | 0.69% | 194.843 | 190.675–196.890 | 1.06% | 0.32x | 1.98x | 1.96x |
| `closure_calls` | 4 | 600 | 71.763 | 68.855–78.088 | 4.51% | 204.442 | 199.197–212.306 | 2.41% | 0.35x | 3.48x | 3.73x |
| `closure_calls` | 8 | 600 | 97.397 | 90.265–100.046 | 3.85% | 321.771 | 300.972–348.054 | 5.83% | 0.30x | 5.13x | 4.74x |
| `arguments_calls` | 1 | 600 | 66.955 | 66.763–78.036 | 6.00% | 297.089 | 294.237–298.544 | 0.50% | 0.23x | 1.00x | 1.00x |
| `arguments_calls` | 2 | 600 | 68.157 | 67.975–69.400 | 0.94% | 304.435 | 302.714–308.665 | 0.63% | 0.22x | 1.96x | 1.95x |
| `arguments_calls` | 4 | 600 | 72.850 | 71.262–77.847 | 3.30% | 314.796 | 313.642–319.032 | 0.59% | 0.23x | 3.68x | 3.78x |
| `arguments_calls` | 8 | 600 | 96.319 | 93.168–97.676 | 1.60% | 473.689 | 459.903–495.613 | 2.40% | 0.20x | 5.56x | 5.02x |
| `fibonacci` | 1 | 125 | 83.790 | 82.741–101.976 | 8.18% | 447.868 | 445.342–450.051 | 0.41% | 0.19x | 1.00x | 1.00x |
| `fibonacci` | 2 | 125 | 84.213 | 83.629–85.105 | 0.69% | 457.953 | 457.230–460.830 | 0.29% | 0.18x | 1.99x | 1.96x |
| `fibonacci` | 4 | 125 | 86.679 | 85.447–89.692 | 2.02% | 468.377 | 466.617–475.634 | 0.68% | 0.19x | 3.87x | 3.82x |
| `fibonacci` | 8 | 125 | 117.196 | 110.929–123.954 | 3.91% | 659.069 | 640.339–697.865 | 3.35% | 0.18x | 5.72x | 5.44x |

## Independent-context cold lifecycle

Neither engine warms these contexts. The timer covers OS-thread creation, context creation, workload-source
evaluation and configuration, the exact invocation, context destruction, and OS-thread join on both sides.
`scaling` uses the same engine and cold lifecycle at one lane.

| workload | lanes | jobs/lane | zig-js median (ms) | zig-js min–max (ms) | zig-js RSD | JSC median (ms) | JSC min–max (ms) | JSC RSD | JSC / zig-js | zig-js scaling | JSC scaling |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `arithmetic` | 1 | 240 | 78.521 | 76.780–81.979 | 2.73% | 356.605 | 344.941–394.399 | 4.87% | 0.22x | 1.00x | 1.00x |
| `arithmetic` | 2 | 240 | 83.033 | 81.159–84.393 | 1.64% | 359.372 | 355.764–384.539 | 2.77% | 0.23x | 1.89x | 1.98x |
| `arithmetic` | 4 | 240 | 86.767 | 86.445–91.340 | 2.16% | 374.864 | 361.382–391.644 | 2.83% | 0.23x | 3.62x | 3.81x |
| `arithmetic` | 8 | 240 | 102.582 | 100.713–104.974 | 1.37% | 512.547 | 491.643–547.340 | 3.59% | 0.20x | 6.12x | 5.57x |
| `properties` | 1 | 300 | 86.878 | 86.755–88.567 | 0.90% | 286.745 | 286.386–303.032 | 2.13% | 0.30x | 1.00x | 1.00x |
| `properties` | 2 | 300 | 88.982 | 88.727–93.931 | 2.65% | 293.098 | 292.279–306.104 | 1.99% | 0.30x | 1.95x | 1.96x |
| `properties` | 4 | 300 | 90.935 | 90.860–91.522 | 0.25% | 308.092 | 299.086–317.895 | 2.26% | 0.30x | 3.82x | 3.72x |
| `properties` | 8 | 300 | 111.546 | 110.337–112.559 | 0.70% | 399.899 | 396.210–429.758 | 2.91% | 0.28x | 6.23x | 5.74x |
| `polymorphic_properties` | 1 | 400 | 83.427 | 83.192–83.485 | 0.12% | 203.383 | 202.968–204.649 | 0.26% | 0.41x | 1.00x | 1.00x |
| `polymorphic_properties` | 2 | 400 | 85.404 | 85.094–85.728 | 0.23% | 207.238 | 206.659–208.542 | 0.31% | 0.41x | 1.95x | 1.96x |
| `polymorphic_properties` | 4 | 400 | 85.704 | 85.618–87.865 | 0.94% | 209.328 | 208.555–209.850 | 0.20% | 0.41x | 3.89x | 3.89x |
| `polymorphic_properties` | 8 | 400 | 128.056 | 121.238–130.935 | 2.67% | 299.909 | 296.889–310.631 | 1.83% | 0.43x | 5.21x | 5.43x |
| `object_churn` | 1 | 100 | 179.221 | 178.451–188.113 | 1.90% | 115.004 | 114.500–116.400 | 0.55% | 1.56x | 1.00x | 1.00x |
| `object_churn` | 2 | 100 | 186.195 | 185.979–187.389 | 0.34% | 119.004 | 118.390–119.181 | 0.25% | 1.56x | 1.93x | 1.93x |
| `object_churn` | 4 | 100 | 279.228 | 272.523–285.703 | 1.39% | 125.103 | 124.333–126.209 | 0.54% | 2.23x | 2.57x | 3.68x |
| `object_churn` | 8 | 100 | 543.472 | 432.457–550.781 | 10.27% | 176.349 | 173.319–205.283 | 6.49% | 3.08x | 2.64x | 5.22x |
| `arrays` | 1 | 550 | 76.069 | 75.787–78.181 | 1.09% | 152.508 | 148.723–169.785 | 4.65% | 0.50x | 1.00x | 1.00x |
| `arrays` | 2 | 550 | 90.594 | 86.990–103.600 | 6.41% | 171.819 | 164.952–179.996 | 2.91% | 0.53x | 1.68x | 1.78x |
| `arrays` | 4 | 550 | 103.157 | 82.879–108.419 | 11.23% | 157.149 | 156.639–158.734 | 0.46% | 0.66x | 2.95x | 3.88x |
| `arrays` | 8 | 550 | 117.143 | 114.299–125.597 | 3.12% | 232.310 | 229.972–242.093 | 1.76% | 0.50x | 5.19x | 5.25x |
| `direct_calls` | 1 | 600 | 59.456 | 57.732–65.808 | 4.58% | 118.622 | 117.942–120.983 | 0.88% | 0.50x | 1.00x | 1.00x |
| `direct_calls` | 2 | 600 | 58.762 | 58.627–59.961 | 0.82% | 122.807 | 120.411–141.312 | 6.38% | 0.48x | 2.02x | 1.93x |
| `direct_calls` | 4 | 600 | 75.328 | 59.902–75.448 | 11.79% | 126.854 | 125.128–149.303 | 6.53% | 0.59x | 3.16x | 3.74x |
| `direct_calls` | 8 | 600 | 86.489 | 76.158–119.641 | 16.57% | 186.202 | 179.855–190.107 | 1.99% | 0.46x | 5.50x | 5.10x |
| `method_calls` | 1 | 500 | 71.398 | 62.161–75.601 | 7.99% | 137.882 | 137.265–138.695 | 0.37% | 0.52x | 1.00x | 1.00x |
| `method_calls` | 2 | 500 | 64.753 | 64.578–76.063 | 6.44% | 140.368 | 139.936–141.335 | 0.35% | 0.46x | 2.21x | 1.96x |
| `method_calls` | 4 | 500 | 65.675 | 65.505–66.212 | 0.37% | 144.006 | 143.616–145.847 | 0.54% | 0.46x | 4.35x | 3.83x |
| `method_calls` | 8 | 500 | 96.246 | 93.118–129.502 | 12.53% | 220.025 | 210.927–235.599 | 4.01% | 0.44x | 5.93x | 5.01x |
| `closure_calls` | 1 | 600 | 65.360 | 63.092–77.967 | 7.86% | 190.361 | 187.699–195.917 | 1.50% | 0.34x | 1.00x | 1.00x |
| `closure_calls` | 2 | 600 | 65.478 | 65.355–67.318 | 1.15% | 197.047 | 195.456–198.192 | 0.51% | 0.33x | 2.00x | 1.93x |
| `closure_calls` | 4 | 600 | 65.522 | 65.489–66.437 | 0.53% | 201.339 | 199.351–229.045 | 5.23% | 0.33x | 3.99x | 3.78x |
| `closure_calls` | 8 | 600 | 83.849 | 81.537–87.278 | 2.30% | 308.216 | 296.754–332.325 | 3.72% | 0.27x | 6.24x | 4.94x |
| `arguments_calls` | 1 | 600 | 67.883 | 67.752–83.745 | 8.50% | 295.037 | 294.391–297.059 | 0.35% | 0.23x | 1.00x | 1.00x |
| `arguments_calls` | 2 | 600 | 70.486 | 69.660–89.158 | 9.61% | 306.807 | 303.878–307.674 | 0.41% | 0.23x | 1.93x | 1.92x |
| `arguments_calls` | 4 | 600 | 73.281 | 72.479–77.017 | 2.27% | 318.899 | 315.428–338.768 | 2.62% | 0.23x | 3.71x | 3.70x |
| `arguments_calls` | 8 | 600 | 93.154 | 90.911–106.870 | 5.91% | 486.502 | 482.731–507.135 | 2.00% | 0.19x | 5.83x | 4.85x |
| `fibonacci` | 1 | 125 | 84.408 | 83.448–91.091 | 3.11% | 448.650 | 444.579–454.629 | 0.73% | 0.19x | 1.00x | 1.00x |
| `fibonacci` | 2 | 125 | 85.645 | 85.099–87.129 | 0.80% | 458.158 | 455.565–477.169 | 1.69% | 0.19x | 1.97x | 1.96x |
| `fibonacci` | 4 | 125 | 93.318 | 87.964–108.161 | 8.16% | 472.435 | 468.444–491.999 | 1.70% | 0.20x | 3.62x | 3.80x |
| `fibonacci` | 8 | 125 | 127.534 | 123.531–133.375 | 2.41% | 655.491 | 650.982–688.024 | 2.00% | 0.19x | 5.29x | 5.48x |

## zig-js shared-realm scaling

This is zig-js's distinct no-GIL shared-object-graph model, which JSC's public C API does not provide.
The timed region creates JavaScript `Thread`s, performs the work, and joins them. Scaling uses the same
shared-realm path at one lane, so thread lifecycle overhead is present in every row.

| workload | lanes | jobs/lane | median (ms) | min–max (ms) | RSD | scaling |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `arithmetic` | 1 | 240 | 78.691 | 75.555–82.536 | 3.61% | 1.00x |
| `arithmetic` | 2 | 240 | 82.325 | 80.602–83.871 | 1.38% | 1.91x |
| `arithmetic` | 4 | 240 | 84.973 | 84.632–87.378 | 1.29% | 3.70x |
| `arithmetic` | 8 | 240 | 104.988 | 103.869–107.229 | 1.09% | 6.00x |
| `properties` | 1 | 300 | 123.939 | 123.852–125.721 | 0.55% | 1.00x |
| `properties` | 2 | 300 | 129.279 | 126.507–133.315 | 2.12% | 1.92x |
| `properties` | 4 | 300 | 130.384 | 129.280–134.623 | 1.60% | 3.80x |
| `properties` | 8 | 300 | 160.016 | 158.261–163.727 | 1.50% | 6.20x |
| `polymorphic_properties` | 1 | 400 | 520.453 | 512.571–523.044 | 0.66% | 1.00x |
| `polymorphic_properties` | 2 | 400 | 528.624 | 522.148–529.706 | 0.48% | 1.97x |
| `polymorphic_properties` | 4 | 400 | 534.308 | 531.091–539.940 | 0.56% | 3.90x |
| `polymorphic_properties` | 8 | 400 | 692.200 | 670.227–722.491 | 2.30% | 6.02x |
| `object_churn` | 1 | 100 | 374.794 | 187.900–433.782 | 21.76% | 1.00x |
| `object_churn` | 2 | 100 | 766.392 | 316.511–907.476 | 25.84% | 0.98x |
| `object_churn` | 4 | 100 | 1849.645 | 852.479–3252.370 | 36.77% | 0.81x |
| `object_churn` | 8 | 100 | 9203.183 | 3451.052–10354.697 | 27.13% | 0.33x |
| `arrays` | 1 | 550 | 92.151 | 86.362–114.346 | 12.51% | 1.00x |
| `arrays` | 2 | 550 | 94.181 | 85.715–112.279 | 10.05% | 1.96x |
| `arrays` | 4 | 550 | 92.874 | 90.764–93.879 | 1.35% | 3.97x |
| `arrays` | 8 | 550 | 232.684 | 231.259–260.995 | 5.17% | 3.17x |
| `direct_calls` | 1 | 600 | 56.468 | 56.191–59.207 | 1.87% | 1.00x |
| `direct_calls` | 2 | 600 | 56.866 | 56.832–56.933 | 0.07% | 1.99x |
| `direct_calls` | 4 | 600 | 58.134 | 58.119–58.267 | 0.09% | 3.89x |
| `direct_calls` | 8 | 600 | 78.439 | 74.459–90.235 | 6.83% | 5.76x |
| `method_calls` | 1 | 500 | 115.302 | 115.135–118.690 | 1.14% | 1.00x |
| `method_calls` | 2 | 500 | 117.091 | 116.788–118.598 | 0.52% | 1.97x |
| `method_calls` | 4 | 500 | 120.328 | 120.217–120.588 | 0.10% | 3.83x |
| `method_calls` | 8 | 500 | 175.250 | 168.590–185.563 | 3.10% | 5.26x |
| `closure_calls` | 1 | 600 | 67.827 | 63.904–79.871 | 9.31% | 1.00x |
| `closure_calls` | 2 | 600 | 65.032 | 64.217–66.740 | 1.21% | 2.09x |
| `closure_calls` | 4 | 600 | 65.910 | 65.021–89.606 | 12.78% | 4.12x |
| `closure_calls` | 8 | 600 | 85.510 | 83.311–90.984 | 2.86% | 6.35x |
| `arguments_calls` | 1 | 600 | 66.970 | 66.504–68.896 | 1.35% | 1.00x |
| `arguments_calls` | 2 | 600 | 69.253 | 67.945–72.055 | 2.19% | 1.93x |
| `arguments_calls` | 4 | 600 | 71.297 | 69.400–79.306 | 6.08% | 3.76x |
| `arguments_calls` | 8 | 600 | 95.524 | 91.249–100.192 | 3.56% | 5.61x |
| `fibonacci` | 1 | 125 | 243.440 | 242.566–264.173 | 3.18% | 1.00x |
| `fibonacci` | 2 | 125 | 248.878 | 247.445–251.703 | 0.58% | 1.96x |
| `fibonacci` | 4 | 125 | 256.024 | 253.191–256.585 | 0.60% | 3.80x |
| `fibonacci` | 8 | 125 | 366.814 | 361.890–392.691 | 2.91% | 5.31x |

## Reading the result

Across these 10 deliberately small kernels, JSC's single-context throughput is 0.39x
the zig-js throughput by geometric mean. These kernels deliberately exercise guarded native/VM tiers that
zig-js currently implements; rows outside those documented subsets continue through general bytecode paths.
The number is a compact description of this matrix, not a claim about applications or unsupported workloads.

At 8 independent warmed contexts, JSC throughput is 0.39x zig-js by
geometric mean; scaling from the mode's own one-lane baseline is 5.18x
for zig-js and 5.32x for JSC. In the symmetric cold lifecycle, JSC
throughput is 0.39x zig-js, with 5.29x
and 5.25x scaling respectively.

zig-js's shared-realm path scales 4.09x at 8 lanes from its
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
