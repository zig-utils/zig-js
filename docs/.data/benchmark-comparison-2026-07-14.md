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
| zig-js | db131e0a6c70e8f9b3f22c580b54373cd13abdfc |
| JavaScriptCore | system framework 22625.1.20.11.3 |
| Power | Now drawing from 'AC Power' -InternalBattery-0 (id=22806627) 44%; charging; (no estimate) present: true |

## Single-thread result

Each row runs the same number of jobs in one GC-enabled zig-js context and one warmed JSC global context.
Both runners time the exact invocation `__benchmarkSelected(__benchmarkJobs, __benchmarkLane)`.
Lower time is better; `JSC / zig-js` is JSC throughput divided by zig-js throughput. RSD is relative standard deviation.

| workload | jobs | zig-js median (ms) | zig-js min–max (ms) | zig-js RSD | JSC median (ms) | JSC min–max (ms) | JSC RSD | JSC / zig-js |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `arithmetic` | 160 | 57.169 | 56.574–58.159 | 0.82% | 237.804 | 234.495–248.088 | 1.84% | 0.24x |
| `properties` | 200 | 58.924 | 58.470–59.973 | 0.99% | 201.435 | 198.390–203.462 | 0.80% | 0.29x |
| `polymorphic_properties` | 350 | 71.133 | 70.013–73.472 | 1.65% | 180.003 | 178.498–185.292 | 1.50% | 0.40x |
| `object_churn` | 100 | 204.392 | 194.926–224.413 | 4.66% | 120.512 | 119.900–173.918 | 15.76% | 1.70x |
| `arrays` | 450 | 65.839 | 65.429–72.332 | 3.79% | 128.433 | 127.084–132.187 | 1.41% | 0.51x |
| `direct_calls` | 500 | 64.457 | 64.403–65.780 | 0.89% | 100.548 | 99.848–102.258 | 0.83% | 0.64x |
| `method_calls` | 500 | 78.233 | 77.927–85.319 | 3.61% | 140.714 | 140.366–170.533 | 7.67% | 0.56x |
| `closure_calls` | 500 | 67.883 | 67.643–69.330 | 1.09% | 159.003 | 158.478–161.553 | 0.64% | 0.43x |
| `arguments_calls` | 400 | 60.091 | 59.026–62.139 | 1.86% | 213.843 | 207.273–236.169 | 4.87% | 0.28x |
| `fibonacci` | 100 | 68.897 | 67.547–72.164 | 2.26% | 373.520 | 367.517–379.710 | 1.51% | 0.18x |

## Independent-context steady state

Both engines keep one warmed context on one persistent OS worker per lane. The timed region contains the
same semaphore dispatch, exact invocation, and completion wait. Every lane performs the full job count.
`scaling` uses the same engine and mode at one lane; cross-engine throughput is directly comparable.

| workload | lanes | jobs/lane | zig-js median (ms) | zig-js min–max (ms) | zig-js RSD | JSC median (ms) | JSC min–max (ms) | JSC RSD | JSC / zig-js | zig-js scaling | JSC scaling |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `arithmetic` | 1 | 160 | 57.201 | 56.111–57.739 | 0.87% | 236.086 | 234.091–243.711 | 1.67% | 0.24x | 1.00x | 1.00x |
| `arithmetic` | 2 | 160 | 57.497 | 57.273–60.398 | 2.03% | 245.959 | 240.509–292.667 | 7.25% | 0.23x | 1.99x | 1.92x |
| `arithmetic` | 4 | 160 | 58.766 | 57.471–65.953 | 4.95% | 271.734 | 266.867–279.636 | 1.55% | 0.22x | 3.89x | 3.48x |
| `arithmetic` | 8 | 160 | 72.838 | 70.770–76.948 | 2.84% | 370.596 | 368.661–377.582 | 0.87% | 0.20x | 6.28x | 5.10x |
| `properties` | 1 | 200 | 58.611 | 58.455–60.483 | 1.22% | 199.986 | 197.754–202.213 | 0.78% | 0.29x | 1.00x | 1.00x |
| `properties` | 2 | 200 | 59.843 | 59.673–60.528 | 0.60% | 199.624 | 199.457–203.650 | 0.85% | 0.30x | 1.96x | 2.00x |
| `properties` | 4 | 200 | 61.536 | 60.668–81.208 | 12.40% | 225.570 | 222.893–229.276 | 0.88% | 0.27x | 3.81x | 3.55x |
| `properties` | 8 | 200 | 86.367 | 80.573–93.539 | 4.69% | 320.280 | 311.146–328.453 | 1.66% | 0.27x | 5.43x | 5.00x |
| `polymorphic_properties` | 1 | 350 | 70.400 | 69.996–71.591 | 0.84% | 183.178 | 178.549–185.318 | 1.63% | 0.38x | 1.00x | 1.00x |
| `polymorphic_properties` | 2 | 350 | 73.363 | 72.303–93.248 | 9.97% | 188.940 | 186.921–202.144 | 2.87% | 0.39x | 1.92x | 1.94x |
| `polymorphic_properties` | 4 | 350 | 76.517 | 73.875–93.688 | 9.22% | 209.272 | 206.975–227.751 | 3.44% | 0.37x | 3.68x | 3.50x |
| `polymorphic_properties` | 8 | 350 | 118.358 | 111.157–125.378 | 4.22% | 300.590 | 293.091–330.266 | 4.16% | 0.39x | 4.76x | 4.88x |
| `object_churn` | 1 | 100 | 208.680 | 190.965–225.465 | 5.61% | 120.111 | 117.570–121.664 | 1.35% | 1.74x | 1.00x | 1.00x |
| `object_churn` | 2 | 100 | 228.668 | 202.422–249.720 | 7.53% | 124.264 | 123.429–127.358 | 1.13% | 1.84x | 1.83x | 1.93x |
| `object_churn` | 4 | 100 | 375.998 | 322.277–417.232 | 10.32% | 129.094 | 126.442–144.695 | 4.76% | 2.91x | 2.22x | 3.72x |
| `object_churn` | 8 | 100 | 786.543 | 639.140–895.106 | 14.23% | 196.866 | 188.910–230.119 | 7.01% | 4.00x | 2.12x | 4.88x |
| `arrays` | 1 | 450 | 65.554 | 65.292–68.151 | 1.58% | 129.497 | 127.896–132.519 | 1.12% | 0.51x | 1.00x | 1.00x |
| `arrays` | 2 | 450 | 67.535 | 66.858–116.259 | 23.21% | 130.667 | 129.267–137.018 | 1.94% | 0.52x | 1.94x | 1.98x |
| `arrays` | 4 | 450 | 73.303 | 71.649–88.174 | 7.96% | 138.439 | 136.524–151.152 | 3.51% | 0.53x | 3.58x | 3.74x |
| `arrays` | 8 | 450 | 105.306 | 102.629–110.874 | 2.90% | 203.256 | 200.865–213.681 | 2.50% | 0.52x | 4.98x | 5.10x |
| `direct_calls` | 1 | 500 | 64.791 | 64.496–65.920 | 0.92% | 99.961 | 98.879–102.345 | 1.08% | 0.65x | 1.00x | 1.00x |
| `direct_calls` | 2 | 500 | 67.055 | 65.886–68.425 | 1.74% | 102.301 | 101.337–103.502 | 0.72% | 0.66x | 1.93x | 1.95x |
| `direct_calls` | 4 | 500 | 70.663 | 68.965–75.414 | 3.69% | 115.259 | 110.494–130.394 | 5.72% | 0.61x | 3.67x | 3.47x |
| `direct_calls` | 8 | 500 | 87.218 | 84.506–94.184 | 3.78% | 168.485 | 163.238–183.160 | 3.93% | 0.52x | 5.94x | 4.75x |
| `method_calls` | 1 | 500 | 78.066 | 77.866–79.941 | 0.97% | 140.943 | 140.352–144.238 | 1.14% | 0.55x | 1.00x | 1.00x |
| `method_calls` | 2 | 500 | 80.033 | 79.697–82.044 | 1.19% | 147.378 | 143.853–157.050 | 2.81% | 0.54x | 1.95x | 1.91x |
| `method_calls` | 4 | 500 | 83.466 | 81.651–98.798 | 7.11% | 148.341 | 147.152–159.923 | 3.00% | 0.56x | 3.74x | 3.80x |
| `method_calls` | 8 | 500 | 104.680 | 103.304–112.677 | 3.22% | 225.601 | 217.584–235.514 | 2.47% | 0.46x | 5.97x | 5.00x |
| `closure_calls` | 1 | 500 | 68.165 | 67.898–74.980 | 3.69% | 158.362 | 157.615–161.251 | 0.74% | 0.43x | 1.00x | 1.00x |
| `closure_calls` | 2 | 500 | 72.239 | 69.373–77.010 | 3.66% | 163.676 | 162.956–164.167 | 0.28% | 0.44x | 1.89x | 1.94x |
| `closure_calls` | 4 | 500 | 73.902 | 70.656–77.762 | 3.75% | 178.717 | 175.265–185.705 | 1.91% | 0.41x | 3.69x | 3.54x |
| `closure_calls` | 8 | 500 | 100.858 | 90.872–108.805 | 6.74% | 278.503 | 273.266–286.883 | 1.62% | 0.36x | 5.41x | 4.55x |
| `arguments_calls` | 1 | 400 | 59.649 | 59.060–68.118 | 5.71% | 203.595 | 203.315–213.582 | 1.99% | 0.29x | 1.00x | 1.00x |
| `arguments_calls` | 2 | 400 | 60.767 | 60.229–61.757 | 0.91% | 212.156 | 209.661–216.930 | 1.26% | 0.29x | 1.96x | 1.92x |
| `arguments_calls` | 4 | 400 | 65.845 | 62.350–72.850 | 5.73% | 234.458 | 228.180–235.756 | 1.31% | 0.28x | 3.62x | 3.47x |
| `arguments_calls` | 8 | 400 | 83.543 | 78.703–90.250 | 4.67% | 357.399 | 349.052–371.495 | 2.49% | 0.23x | 5.71x | 4.56x |
| `fibonacci` | 1 | 100 | 70.405 | 68.791–71.864 | 1.52% | 373.950 | 368.047–377.662 | 1.00% | 0.19x | 1.00x | 1.00x |
| `fibonacci` | 2 | 100 | 69.997 | 69.224–71.544 | 1.35% | 424.278 | 379.942–487.647 | 8.88% | 0.16x | 2.01x | 1.76x |
| `fibonacci` | 4 | 100 | 91.631 | 84.182–105.528 | 8.66% | 413.870 | 400.162–445.979 | 3.89% | 0.22x | 3.07x | 3.61x |
| `fibonacci` | 8 | 100 | 109.876 | 104.472–129.727 | 8.02% | 803.650 | 593.093–1179.622 | 26.89% | 0.14x | 5.13x | 3.72x |

## Independent-context cold lifecycle

Neither engine warms these contexts. The timer covers OS-thread creation, context creation, workload-source
evaluation and configuration, the exact invocation, context destruction, and OS-thread join on both sides.
`scaling` uses the same engine and cold lifecycle at one lane.

| workload | lanes | jobs/lane | zig-js median (ms) | zig-js min–max (ms) | zig-js RSD | JSC median (ms) | JSC min–max (ms) | JSC RSD | JSC / zig-js | zig-js scaling | JSC scaling |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `arithmetic` | 1 | 160 | 59.550 | 58.470–61.106 | 1.68% | 240.452 | 235.211–269.811 | 4.85% | 0.25x | 1.00x | 1.00x |
| `arithmetic` | 2 | 160 | 59.834 | 59.121–62.137 | 1.87% | 244.794 | 241.673–247.143 | 0.69% | 0.24x | 1.99x | 1.96x |
| `arithmetic` | 4 | 160 | 60.547 | 59.534–66.337 | 3.85% | 276.283 | 266.010–307.963 | 4.80% | 0.22x | 3.93x | 3.48x |
| `arithmetic` | 8 | 160 | 74.622 | 70.893–80.850 | 4.59% | 382.601 | 368.410–408.913 | 3.29% | 0.20x | 6.38x | 5.03x |
| `properties` | 1 | 200 | 62.233 | 61.155–70.487 | 5.32% | 196.576 | 196.240–202.694 | 1.52% | 0.32x | 1.00x | 1.00x |
| `properties` | 2 | 200 | 62.526 | 62.077–65.315 | 1.96% | 205.605 | 203.159–211.783 | 1.35% | 0.30x | 1.99x | 1.91x |
| `properties` | 4 | 200 | 66.351 | 64.990–117.845 | 25.83% | 226.055 | 223.686–234.976 | 1.66% | 0.29x | 3.75x | 3.48x |
| `properties` | 8 | 200 | 85.512 | 81.981–89.570 | 3.07% | 327.438 | 317.634–362.517 | 5.53% | 0.26x | 5.82x | 4.80x |
| `polymorphic_properties` | 1 | 350 | 71.685 | 71.374–73.481 | 1.11% | 184.561 | 183.704–185.597 | 0.37% | 0.39x | 1.00x | 1.00x |
| `polymorphic_properties` | 2 | 350 | 73.415 | 73.255–74.292 | 0.60% | 190.230 | 186.692–193.358 | 1.17% | 0.39x | 1.95x | 1.94x |
| `polymorphic_properties` | 4 | 350 | 78.190 | 74.587–85.794 | 6.47% | 210.204 | 207.503–232.288 | 4.00% | 0.37x | 3.67x | 3.51x |
| `polymorphic_properties` | 8 | 350 | 120.031 | 114.616–127.680 | 3.55% | 302.519 | 298.092–342.596 | 5.22% | 0.40x | 4.78x | 4.88x |
| `object_churn` | 1 | 100 | 187.582 | 187.324–196.221 | 1.72% | 122.192 | 121.391–125.582 | 1.20% | 1.54x | 1.00x | 1.00x |
| `object_churn` | 2 | 100 | 209.264 | 198.049–239.293 | 6.82% | 124.651 | 122.397–167.547 | 12.46% | 1.68x | 1.79x | 1.96x |
| `object_churn` | 4 | 100 | 326.704 | 300.983–467.595 | 16.54% | 135.185 | 126.300–159.515 | 8.97% | 2.42x | 2.30x | 3.62x |
| `object_churn` | 8 | 100 | 595.378 | 569.923–651.402 | 5.51% | 222.982 | 185.267–267.273 | 12.58% | 2.67x | 2.52x | 4.38x |
| `arrays` | 1 | 450 | 65.085 | 64.234–68.170 | 2.21% | 129.336 | 128.435–130.402 | 0.47% | 0.50x | 1.00x | 1.00x |
| `arrays` | 2 | 450 | 67.078 | 66.610–70.216 | 2.03% | 131.010 | 129.788–132.551 | 0.73% | 0.51x | 1.94x | 1.97x |
| `arrays` | 4 | 450 | 74.899 | 71.601–87.631 | 7.63% | 143.077 | 137.501–154.357 | 3.74% | 0.52x | 3.48x | 3.62x |
| `arrays` | 8 | 450 | 106.060 | 102.806–130.241 | 9.29% | 210.444 | 205.961–226.087 | 3.32% | 0.50x | 4.91x | 4.92x |
| `direct_calls` | 1 | 500 | 66.175 | 66.131–67.839 | 0.95% | 101.428 | 100.424–103.466 | 1.15% | 0.65x | 1.00x | 1.00x |
| `direct_calls` | 2 | 500 | 68.563 | 67.727–69.189 | 0.76% | 104.196 | 102.569–104.709 | 0.80% | 0.66x | 1.93x | 1.95x |
| `direct_calls` | 4 | 500 | 76.007 | 70.821–136.206 | 28.29% | 131.492 | 118.808–208.020 | 21.95% | 0.58x | 3.48x | 3.09x |
| `direct_calls` | 8 | 500 | 86.092 | 82.766–92.562 | 3.79% | 166.830 | 163.716–179.989 | 3.57% | 0.52x | 6.15x | 4.86x |
| `method_calls` | 1 | 500 | 80.355 | 79.126–81.407 | 1.06% | 143.725 | 141.629–147.939 | 1.49% | 0.56x | 1.00x | 1.00x |
| `method_calls` | 2 | 500 | 82.924 | 81.539–95.806 | 6.59% | 149.134 | 145.247–172.894 | 6.33% | 0.56x | 1.94x | 1.93x |
| `method_calls` | 4 | 500 | 83.526 | 82.864–98.988 | 6.93% | 153.232 | 148.582–165.558 | 3.73% | 0.55x | 3.85x | 3.75x |
| `method_calls` | 8 | 500 | 107.448 | 106.081–114.807 | 2.84% | 229.910 | 222.505–237.245 | 2.25% | 0.47x | 5.98x | 5.00x |
| `closure_calls` | 1 | 500 | 69.695 | 69.148–71.173 | 1.24% | 161.634 | 159.686–165.471 | 1.37% | 0.43x | 1.00x | 1.00x |
| `closure_calls` | 2 | 500 | 71.386 | 71.056–72.341 | 0.63% | 165.332 | 165.201–187.294 | 4.89% | 0.43x | 1.95x | 1.96x |
| `closure_calls` | 4 | 500 | 80.321 | 74.665–140.147 | 25.90% | 181.123 | 175.784–197.263 | 4.18% | 0.44x | 3.47x | 3.57x |
| `closure_calls` | 8 | 500 | 105.546 | 95.112–132.843 | 14.62% | 283.919 | 281.775–314.927 | 4.75% | 0.37x | 5.28x | 4.55x |
| `arguments_calls` | 1 | 400 | 60.653 | 60.538–62.521 | 1.33% | 203.827 | 203.296–210.107 | 1.36% | 0.30x | 1.00x | 1.00x |
| `arguments_calls` | 2 | 400 | 62.120 | 61.733–62.949 | 0.74% | 210.791 | 209.853–245.612 | 6.10% | 0.29x | 1.95x | 1.93x |
| `arguments_calls` | 4 | 400 | 68.242 | 66.748–73.746 | 3.88% | 240.591 | 234.454–249.669 | 2.12% | 0.28x | 3.56x | 3.39x |
| `arguments_calls` | 8 | 400 | 85.115 | 83.201–87.800 | 2.21% | 360.884 | 350.124–367.997 | 1.70% | 0.24x | 5.70x | 4.52x |
| `fibonacci` | 1 | 100 | 71.613 | 69.575–113.132 | 20.26% | 379.758 | 370.663–400.837 | 2.67% | 0.19x | 1.00x | 1.00x |
| `fibonacci` | 2 | 100 | 84.215 | 75.773–145.695 | 31.15% | 422.721 | 404.040–465.442 | 4.87% | 0.20x | 1.70x | 1.80x |
| `fibonacci` | 4 | 100 | 115.856 | 98.261–184.676 | 23.13% | 501.374 | 416.560–649.647 | 16.57% | 0.23x | 2.47x | 3.03x |
| `fibonacci` | 8 | 100 | 139.058 | 117.830–166.609 | 10.90% | 657.040 | 610.263–1003.285 | 19.27% | 0.21x | 4.12x | 4.62x |

## zig-js shared-realm scaling

This is zig-js's distinct no-GIL shared-object-graph model, which JSC's public C API does not provide.
The timed region creates JavaScript `Thread`s, performs the work, and joins them. Scaling uses the same
shared-realm path at one lane, so thread lifecycle overhead is present in every row.

| workload | lanes | jobs/lane | median (ms) | min–max (ms) | RSD | scaling |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `arithmetic` | 1 | 160 | 57.403 | 56.652–58.122 | 0.87% | 1.00x |
| `arithmetic` | 2 | 160 | 58.059 | 57.542–63.983 | 4.83% | 1.98x |
| `arithmetic` | 4 | 160 | 60.146 | 59.446–68.945 | 5.90% | 3.82x |
| `arithmetic` | 8 | 160 | 74.216 | 70.760–83.350 | 7.01% | 6.19x |
| `properties` | 1 | 200 | 87.853 | 85.918–89.727 | 1.32% | 1.00x |
| `properties` | 2 | 200 | 88.314 | 87.263–91.075 | 1.47% | 1.99x |
| `properties` | 4 | 200 | 93.127 | 92.455–108.146 | 5.95% | 3.77x |
| `properties` | 8 | 200 | 132.873 | 119.314–146.866 | 7.81% | 5.29x |
| `polymorphic_properties` | 1 | 350 | 463.550 | 455.933–470.877 | 1.25% | 1.00x |
| `polymorphic_properties` | 2 | 350 | 463.964 | 461.574–468.425 | 0.57% | 2.00x |
| `polymorphic_properties` | 4 | 350 | 501.993 | 491.180–508.567 | 1.13% | 3.69x |
| `polymorphic_properties` | 8 | 350 | 666.142 | 659.962–679.242 | 1.06% | 5.57x |
| `object_churn` | 1 | 100 | 986.746 | 676.536–1033.272 | 12.93% | 1.00x |
| `object_churn` | 2 | 100 | 2086.811 | 1355.346–2974.216 | 23.10% | 0.95x |
| `object_churn` | 4 | 100 | 8448.073 | 4232.287–9558.145 | 22.15% | 0.47x |
| `object_churn` | 8 | 100 | 28321.516 | 20416.102–30239.867 | 12.04% | 0.28x |
| `arrays` | 1 | 450 | 67.885 | 67.132–69.170 | 1.04% | 1.00x |
| `arrays` | 2 | 450 | 71.726 | 71.223–73.452 | 1.29% | 1.89x |
| `arrays` | 4 | 450 | 86.625 | 84.144–132.263 | 18.19% | 3.13x |
| `arrays` | 8 | 450 | 225.873 | 186.220–257.079 | 10.30% | 2.40x |
| `direct_calls` | 1 | 500 | 66.645 | 64.821–70.238 | 2.94% | 1.00x |
| `direct_calls` | 2 | 500 | 67.783 | 67.252–69.032 | 0.82% | 1.97x |
| `direct_calls` | 4 | 500 | 71.905 | 69.968–77.475 | 3.83% | 3.71x |
| `direct_calls` | 8 | 500 | 86.532 | 83.782–92.534 | 3.42% | 6.16x |
| `method_calls` | 1 | 500 | 121.762 | 121.238–123.932 | 0.77% | 1.00x |
| `method_calls` | 2 | 500 | 123.230 | 122.488–124.871 | 0.59% | 1.98x |
| `method_calls` | 4 | 500 | 127.251 | 126.710–148.131 | 6.58% | 3.83x |
| `method_calls` | 8 | 500 | 186.462 | 183.642–191.992 | 1.58% | 5.22x |
| `closure_calls` | 1 | 500 | 69.264 | 69.204–70.885 | 1.05% | 1.00x |
| `closure_calls` | 2 | 500 | 70.644 | 70.516–71.223 | 0.34% | 1.96x |
| `closure_calls` | 4 | 500 | 74.426 | 73.362–82.710 | 4.44% | 3.72x |
| `closure_calls` | 8 | 500 | 127.141 | 94.094–192.763 | 27.27% | 4.36x |
| `arguments_calls` | 1 | 400 | 59.335 | 59.041–62.038 | 2.05% | 1.00x |
| `arguments_calls` | 2 | 400 | 60.430 | 60.110–63.057 | 1.79% | 1.96x |
| `arguments_calls` | 4 | 400 | 65.143 | 62.243–79.018 | 10.25% | 3.64x |
| `arguments_calls` | 8 | 400 | 83.469 | 80.654–101.451 | 8.57% | 5.69x |
| `fibonacci` | 1 | 100 | 214.050 | 204.242–248.799 | 6.70% | 1.00x |
| `fibonacci` | 2 | 100 | 206.642 | 204.194–221.895 | 3.54% | 2.07x |
| `fibonacci` | 4 | 100 | 241.962 | 230.083–360.187 | 17.99% | 3.54x |
| `fibonacci` | 8 | 100 | 378.608 | 344.080–495.609 | 13.67% | 4.52x |

## Reading the result

Across these 10 deliberately small kernels, JSC's single-context throughput is 0.42x
the zig-js throughput by geometric mean. These kernels deliberately exercise guarded native/VM tiers that
zig-js currently implements; rows outside those documented subsets continue through general bytecode paths.
The number is a compact description of this matrix, not a claim about applications or unsupported workloads.

At 8 independent warmed contexts, JSC throughput is 0.41x zig-js by
geometric mean; scaling from the mode's own one-lane baseline is 4.99x
for zig-js and 4.73x for JSC. In the symmetric cold lifecycle, JSC
throughput is 0.41x zig-js, with 5.01x
and 4.75x scaling respectively.

zig-js's shared-realm path scales 3.67x at 8 lanes from its
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
