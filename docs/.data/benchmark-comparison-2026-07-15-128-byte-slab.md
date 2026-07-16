# zig-js / JavaScriptCore benchmark — 2026-07-15

> This is a dated measurement, not a universal engine score. The workload source, raw samples,
> timed boundaries, and semantic differences are recorded so the result can be reproduced and challenged.

## Environment

| item | value |
| --- | --- |
| Date | 2026-07-15 |
| Host | Apple M3 Pro; 11 physical / 11 logical CPUs; 18.0 GiB |
| OS | macOS 27.0 (26A5368g) |
| Zig | 0.17.0-dev.956+2dca73595 |
| zig-js | 12aa217c2f66c0fe7fa95e38ec414ea5ec15a993 |
| zig-gc | 092d8d76b41b3c47c8cc4acb8646ee1d66879c20 |
| zig-regex | 50764b0352e73a434278de38825dbb55464f1cf6 |
| JavaScriptCore | system framework 22625.1.20.11.3 |
| Power | Now drawing from 'Battery Power' -InternalBattery-0 (id=22806627) 74%; discharging; (no estimate) present: true |

## Single-thread result

Each row runs the same number of jobs in one GC-enabled zig-js context and one warmed JSC global context.
Both runners time the exact invocation `__benchmarkSelected(__benchmarkJobs, __benchmarkLane)`.
Lower time is better; `JSC / zig-js` is JSC throughput divided by zig-js throughput. RSD is relative standard deviation.

| workload | jobs | zig-js median (ms) | zig-js min–max (ms) | zig-js RSD | JSC median (ms) | JSC min–max (ms) | JSC RSD | JSC / zig-js |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `arithmetic` | 240 | 91.807 | 84.268–107.305 | 8.02% | 356.516 | 352.511–374.634 | 2.41% | 0.26x |
| `properties` | 300 | 98.723 | 96.687–99.676 | 1.11% | 301.017 | 298.677–302.182 | 0.46% | 0.33x |
| `polymorphic_properties` | 400 | 100.367 | 98.820–101.544 | 1.02% | 214.948 | 212.478–219.759 | 1.23% | 0.47x |
| `object_churn` | 100 | 101.799 | 86.900–121.869 | 13.46% | 123.020 | 122.332–141.479 | 5.53% | 0.83x |
| `arrays` | 550 | 89.919 | 88.736–128.080 | 15.31% | 161.737 | 160.431–166.598 | 1.30% | 0.56x |
| `direct_calls` | 600 | 59.878 | 59.195–62.745 | 2.05% | 125.692 | 122.271–128.608 | 2.37% | 0.48x |
| `method_calls` | 500 | 66.639 | 66.194–68.856 | 1.52% | 144.348 | 143.977–147.243 | 0.79% | 0.46x |
| `closure_calls` | 600 | 65.634 | 65.259–67.531 | 1.31% | 198.020 | 196.804–201.225 | 0.79% | 0.33x |
| `arguments_calls` | 600 | 71.725 | 71.130–73.434 | 1.20% | 317.639 | 315.196–321.471 | 0.64% | 0.23x |
| `fibonacci` | 125 | 86.891 | 86.420–90.552 | 1.69% | 471.204 | 469.956–476.062 | 0.57% | 0.18x |

## Independent-context steady state

Both engines keep one warmed context on one persistent OS worker per lane. The timed region contains the
same semaphore dispatch, exact invocation, and completion wait. Every lane performs the full job count.
`scaling` uses the same engine and mode at one lane; cross-engine throughput is directly comparable.

| workload | lanes | jobs/lane | zig-js median (ms) | zig-js min–max (ms) | zig-js RSD | JSC median (ms) | JSC min–max (ms) | JSC RSD | JSC / zig-js | zig-js scaling | JSC scaling |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `arithmetic` | 1 | 240 | 83.028 | 82.613–92.652 | 4.34% | 352.804 | 347.805–415.957 | 6.65% | 0.24x | 1.00x | 1.00x |
| `arithmetic` | 2 | 240 | 86.855 | 86.513–104.831 | 7.49% | 372.319 | 366.312–415.493 | 4.55% | 0.23x | 1.91x | 1.90x |
| `arithmetic` | 4 | 240 | 90.251 | 89.101–115.355 | 10.12% | 417.396 | 398.071–427.760 | 2.32% | 0.22x | 3.68x | 3.38x |
| `arithmetic` | 8 | 240 | 110.972 | 108.998–121.587 | 3.77% | 597.356 | 591.149–614.191 | 1.46% | 0.19x | 5.99x | 4.72x |
| `properties` | 1 | 300 | 98.331 | 97.850–99.573 | 0.56% | 308.779 | 303.363–317.355 | 1.68% | 0.32x | 1.00x | 1.00x |
| `properties` | 2 | 300 | 103.955 | 102.582–122.105 | 6.50% | 345.605 | 326.061–376.950 | 5.45% | 0.30x | 1.89x | 1.79x |
| `properties` | 4 | 300 | 118.176 | 110.349–123.826 | 4.39% | 414.671 | 398.910–439.159 | 3.73% | 0.28x | 3.33x | 2.98x |
| `properties` | 8 | 300 | 137.042 | 131.912–150.689 | 4.65% | 544.779 | 541.472–553.744 | 0.81% | 0.25x | 5.74x | 4.53x |
| `polymorphic_properties` | 1 | 400 | 95.700 | 95.266–98.195 | 1.07% | 214.468 | 212.005–233.684 | 3.56% | 0.45x | 1.00x | 1.00x |
| `polymorphic_properties` | 2 | 400 | 96.979 | 96.555–142.128 | 16.41% | 225.719 | 222.740–243.497 | 3.15% | 0.43x | 1.97x | 1.90x |
| `polymorphic_properties` | 4 | 400 | 115.120 | 113.789–139.278 | 7.80% | 276.617 | 273.124–282.499 | 1.05% | 0.42x | 3.33x | 3.10x |
| `polymorphic_properties` | 8 | 400 | 161.032 | 154.790–182.375 | 5.83% | 378.132 | 373.840–411.109 | 3.57% | 0.43x | 4.75x | 4.54x |
| `object_churn` | 1 | 100 | 87.771 | 85.800–106.103 | 8.28% | 120.342 | 119.340–123.523 | 1.17% | 0.73x | 1.00x | 1.00x |
| `object_churn` | 2 | 100 | 90.484 | 90.017–125.724 | 13.91% | 123.012 | 122.326–124.401 | 0.52% | 0.74x | 1.94x | 1.96x |
| `object_churn` | 4 | 100 | 109.570 | 106.765–149.366 | 13.21% | 130.109 | 127.620–139.924 | 3.27% | 0.84x | 3.20x | 3.70x |
| `object_churn` | 8 | 100 | 168.520 | 165.192–210.493 | 11.34% | 185.412 | 177.456–192.652 | 2.82% | 0.91x | 4.17x | 5.19x |
| `arrays` | 1 | 550 | 89.266 | 88.570–91.380 | 1.02% | 160.790 | 160.338–163.849 | 0.77% | 0.56x | 1.00x | 1.00x |
| `arrays` | 2 | 550 | 91.197 | 90.980–94.286 | 1.27% | 162.490 | 161.011–191.509 | 6.69% | 0.56x | 1.96x | 1.98x |
| `arrays` | 4 | 550 | 102.639 | 101.612–121.999 | 6.97% | 180.008 | 175.007–189.008 | 2.93% | 0.57x | 3.48x | 3.57x |
| `arrays` | 8 | 550 | 141.976 | 138.701–186.926 | 13.00% | 268.272 | 260.555–282.419 | 2.47% | 0.53x | 5.03x | 4.79x |
| `direct_calls` | 1 | 600 | 59.857 | 59.647–61.955 | 1.36% | 122.011 | 121.698–125.194 | 1.00% | 0.49x | 1.00x | 1.00x |
| `direct_calls` | 2 | 600 | 62.859 | 61.059–64.691 | 2.00% | 124.321 | 123.844–131.268 | 2.22% | 0.51x | 1.90x | 1.96x |
| `direct_calls` | 4 | 600 | 72.015 | 66.420–117.199 | 22.36% | 142.832 | 138.411–150.498 | 3.20% | 0.50x | 3.32x | 3.42x |
| `direct_calls` | 8 | 600 | 94.218 | 90.876–100.048 | 3.74% | 209.355 | 203.970–251.604 | 7.67% | 0.45x | 5.08x | 4.66x |
| `method_calls` | 1 | 500 | 66.303 | 65.997–78.478 | 7.60% | 144.675 | 144.249–146.841 | 0.63% | 0.46x | 1.00x | 1.00x |
| `method_calls` | 2 | 500 | 68.060 | 67.059–71.704 | 2.36% | 146.534 | 146.324–149.951 | 0.89% | 0.46x | 1.95x | 1.97x |
| `method_calls` | 4 | 500 | 73.915 | 70.430–81.149 | 5.23% | 161.909 | 160.584–174.317 | 2.88% | 0.46x | 3.59x | 3.57x |
| `method_calls` | 8 | 500 | 102.515 | 99.056–109.004 | 3.75% | 236.261 | 229.957–245.304 | 2.36% | 0.43x | 5.17x | 4.90x |
| `closure_calls` | 1 | 600 | 65.493 | 65.309–67.034 | 1.03% | 196.311 | 195.743–199.599 | 0.67% | 0.33x | 1.00x | 1.00x |
| `closure_calls` | 2 | 600 | 66.490 | 66.352–68.686 | 1.35% | 200.694 | 199.869–203.361 | 0.58% | 0.33x | 1.97x | 1.96x |
| `closure_calls` | 4 | 600 | 75.649 | 71.480–84.812 | 6.30% | 231.076 | 227.387–233.775 | 0.99% | 0.33x | 3.46x | 3.40x |
| `closure_calls` | 8 | 600 | 95.660 | 93.446–100.507 | 2.99% | 340.897 | 329.517–343.234 | 1.50% | 0.28x | 5.48x | 4.61x |
| `arguments_calls` | 1 | 600 | 71.266 | 70.617–116.830 | 21.65% | 315.716 | 312.363–317.443 | 0.60% | 0.23x | 1.00x | 1.00x |
| `arguments_calls` | 2 | 600 | 72.099 | 71.765–106.865 | 16.92% | 324.693 | 321.227–330.432 | 1.04% | 0.22x | 1.98x | 1.94x |
| `arguments_calls` | 4 | 600 | 91.321 | 80.584–129.815 | 17.04% | 374.845 | 363.070–378.156 | 1.39% | 0.24x | 3.12x | 3.37x |
| `arguments_calls` | 8 | 600 | 112.923 | 108.165–230.568 | 34.65% | 536.181 | 534.758–545.131 | 0.74% | 0.21x | 5.05x | 4.71x |
| `fibonacci` | 1 | 125 | 87.043 | 86.393–105.184 | 7.63% | 472.630 | 469.997–473.923 | 0.29% | 0.18x | 1.00x | 1.00x |
| `fibonacci` | 2 | 125 | 88.990 | 88.136–127.353 | 15.36% | 479.729 | 478.913–484.555 | 0.44% | 0.19x | 1.96x | 1.97x |
| `fibonacci` | 4 | 125 | 103.967 | 100.399–123.018 | 7.22% | 527.371 | 516.770–555.209 | 2.29% | 0.20x | 3.35x | 3.58x |
| `fibonacci` | 8 | 125 | 134.122 | 128.139–165.106 | 9.29% | 748.166 | 736.614–753.061 | 0.84% | 0.18x | 5.19x | 5.05x |

## Independent-context cold lifecycle

Neither engine warms these contexts. The timer covers OS-thread creation, context creation, workload-source
evaluation and configuration, the exact invocation, context destruction, and OS-thread join on both sides.
`scaling` uses the same engine and cold lifecycle at one lane.

| workload | lanes | jobs/lane | zig-js median (ms) | zig-js min–max (ms) | zig-js RSD | JSC median (ms) | JSC min–max (ms) | JSC RSD | JSC / zig-js | zig-js scaling | JSC scaling |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `arithmetic` | 1 | 240 | 85.519 | 83.739–93.899 | 4.02% | 354.546 | 351.371–372.626 | 2.90% | 0.24x | 1.00x | 1.00x |
| `arithmetic` | 2 | 240 | 88.319 | 87.293–90.434 | 1.21% | 362.073 | 359.654–374.190 | 1.42% | 0.24x | 1.94x | 1.96x |
| `arithmetic` | 4 | 240 | 96.447 | 90.682–99.022 | 3.13% | 443.046 | 433.538–462.840 | 2.57% | 0.22x | 3.55x | 3.20x |
| `arithmetic` | 8 | 240 | 114.664 | 111.121–151.022 | 11.66% | 610.200 | 605.808–620.520 | 0.79% | 0.19x | 5.97x | 4.65x |
| `properties` | 1 | 300 | 130.449 | 100.030–161.736 | 17.41% | 335.170 | 305.910–404.311 | 10.52% | 0.39x | 1.00x | 1.00x |
| `properties` | 2 | 300 | 103.185 | 100.419–138.753 | 12.56% | 335.420 | 327.996–443.836 | 11.66% | 0.31x | 2.53x | 2.00x |
| `properties` | 4 | 300 | 109.896 | 109.269–129.198 | 6.42% | 409.815 | 407.075–475.936 | 6.03% | 0.27x | 4.75x | 3.27x |
| `properties` | 8 | 300 | 141.876 | 137.641–199.476 | 16.04% | 548.794 | 539.499–591.581 | 3.87% | 0.26x | 7.36x | 4.89x |
| `polymorphic_properties` | 1 | 400 | 97.251 | 96.311–100.621 | 1.46% | 214.664 | 211.851–218.450 | 1.25% | 0.45x | 1.00x | 1.00x |
| `polymorphic_properties` | 2 | 400 | 98.642 | 97.650–113.463 | 5.63% | 229.921 | 228.671–245.535 | 2.56% | 0.43x | 1.97x | 1.87x |
| `polymorphic_properties` | 4 | 400 | 119.755 | 118.236–145.488 | 8.07% | 275.479 | 272.244–280.146 | 1.21% | 0.43x | 3.25x | 3.12x |
| `polymorphic_properties` | 8 | 400 | 171.044 | 161.001–174.056 | 3.08% | 383.570 | 371.541–463.751 | 8.18% | 0.45x | 4.55x | 4.48x |
| `object_churn` | 1 | 100 | 89.254 | 88.061–92.522 | 2.00% | 120.938 | 120.489–161.410 | 11.91% | 0.74x | 1.00x | 1.00x |
| `object_churn` | 2 | 100 | 96.177 | 92.109–107.444 | 5.33% | 124.368 | 123.845–128.190 | 1.21% | 0.77x | 1.86x | 1.94x |
| `object_churn` | 4 | 100 | 120.488 | 110.684–129.223 | 6.35% | 133.204 | 129.678–141.791 | 2.87% | 0.90x | 2.96x | 3.63x |
| `object_churn` | 8 | 100 | 181.819 | 175.667–193.283 | 3.26% | 190.980 | 186.142–231.479 | 9.96% | 0.95x | 3.93x | 5.07x |
| `arrays` | 1 | 550 | 87.419 | 86.996–92.044 | 2.11% | 161.647 | 159.297–169.177 | 2.22% | 0.54x | 1.00x | 1.00x |
| `arrays` | 2 | 550 | 90.735 | 90.474–95.572 | 2.19% | 162.156 | 161.523–165.063 | 0.80% | 0.56x | 1.93x | 1.99x |
| `arrays` | 4 | 550 | 102.773 | 97.649–112.267 | 4.39% | 185.973 | 177.637–196.936 | 3.11% | 0.55x | 3.40x | 3.48x |
| `arrays` | 8 | 550 | 141.936 | 136.235–157.144 | 5.16% | 272.494 | 262.516–278.948 | 1.85% | 0.52x | 4.93x | 4.75x |
| `direct_calls` | 1 | 600 | 60.735 | 60.488–63.523 | 1.86% | 123.925 | 123.666–169.849 | 13.28% | 0.49x | 1.00x | 1.00x |
| `direct_calls` | 2 | 600 | 62.380 | 61.972–64.068 | 1.16% | 125.176 | 124.370–129.963 | 1.50% | 0.50x | 1.95x | 1.98x |
| `direct_calls` | 4 | 600 | 68.557 | 66.957–79.805 | 6.57% | 145.134 | 142.500–157.876 | 3.65% | 0.47x | 3.54x | 3.42x |
| `direct_calls` | 8 | 600 | 96.581 | 92.607–98.866 | 2.40% | 217.789 | 211.279–285.311 | 11.54% | 0.44x | 5.03x | 4.55x |
| `method_calls` | 1 | 500 | 67.766 | 67.435–70.863 | 1.77% | 145.095 | 144.704–149.124 | 1.08% | 0.47x | 1.00x | 1.00x |
| `method_calls` | 2 | 500 | 70.487 | 69.718–72.765 | 1.54% | 147.422 | 146.941–201.317 | 13.00% | 0.48x | 1.92x | 1.97x |
| `method_calls` | 4 | 500 | 77.093 | 73.153–87.185 | 6.20% | 165.201 | 163.558–179.195 | 3.32% | 0.47x | 3.52x | 3.51x |
| `method_calls` | 8 | 500 | 100.385 | 99.437–112.173 | 5.06% | 240.532 | 236.068–247.316 | 1.78% | 0.42x | 5.40x | 4.83x |
| `closure_calls` | 1 | 600 | 66.849 | 66.188–70.794 | 2.65% | 198.533 | 197.364–250.082 | 9.49% | 0.34x | 1.00x | 1.00x |
| `closure_calls` | 2 | 600 | 67.667 | 67.446–98.758 | 15.78% | 203.021 | 201.880–207.659 | 0.97% | 0.33x | 1.98x | 1.96x |
| `closure_calls` | 4 | 600 | 78.688 | 73.671–89.271 | 6.49% | 234.022 | 230.020–255.183 | 4.49% | 0.34x | 3.40x | 3.39x |
| `closure_calls` | 8 | 600 | 98.645 | 96.349–158.784 | 20.97% | 348.405 | 336.444–379.634 | 4.16% | 0.28x | 5.42x | 4.56x |
| `arguments_calls` | 1 | 600 | 72.051 | 71.777–73.833 | 1.06% | 317.861 | 315.621–328.237 | 1.44% | 0.23x | 1.00x | 1.00x |
| `arguments_calls` | 2 | 600 | 76.101 | 74.300–81.245 | 3.81% | 326.669 | 323.214–329.248 | 0.84% | 0.23x | 1.89x | 1.95x |
| `arguments_calls` | 4 | 600 | 90.921 | 85.681–102.066 | 6.38% | 380.590 | 375.177–399.048 | 2.55% | 0.24x | 3.17x | 3.34x |
| `arguments_calls` | 8 | 600 | 116.527 | 109.456–132.571 | 6.18% | 547.339 | 539.734–572.375 | 2.01% | 0.21x | 4.95x | 4.65x |
| `fibonacci` | 1 | 125 | 88.067 | 87.262–90.024 | 1.10% | 493.017 | 479.044–533.311 | 4.29% | 0.18x | 1.00x | 1.00x |
| `fibonacci` | 2 | 125 | 91.825 | 89.418–123.540 | 12.84% | 482.722 | 480.940–488.781 | 0.63% | 0.19x | 1.92x | 2.04x |
| `fibonacci` | 4 | 125 | 107.338 | 102.399–165.416 | 19.27% | 527.283 | 523.110–600.284 | 5.18% | 0.20x | 3.28x | 3.74x |
| `fibonacci` | 8 | 125 | 143.726 | 138.261–200.141 | 14.60% | 757.659 | 730.830–807.179 | 3.04% | 0.19x | 4.90x | 5.21x |

## zig-js shared-realm scaling

This is zig-js's distinct no-GIL shared-object-graph model, which JSC's public C API does not provide.
The timed region creates JavaScript `Thread`s, performs the work, and joins them. Scaling uses the same
shared-realm path at one lane, so thread lifecycle overhead is present in every row.

| workload | lanes | jobs/lane | median (ms) | min–max (ms) | RSD | scaling |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `arithmetic` | 1 | 240 | 88.521 | 84.583–89.442 | 2.16% | 1.00x |
| `arithmetic` | 2 | 240 | 88.704 | 87.245–92.502 | 2.00% | 2.00x |
| `arithmetic` | 4 | 240 | 91.679 | 90.077–100.189 | 3.64% | 3.86x |
| `arithmetic` | 8 | 240 | 112.673 | 106.837–139.413 | 10.56% | 6.29x |
| `properties` | 1 | 300 | 141.647 | 138.408–151.429 | 3.08% | 1.00x |
| `properties` | 2 | 300 | 150.819 | 143.137–165.815 | 6.04% | 1.88x |
| `properties` | 4 | 300 | 162.590 | 159.645–185.846 | 5.59% | 3.48x |
| `properties` | 8 | 300 | 232.852 | 222.749–261.892 | 5.69% | 4.87x |
| `polymorphic_properties` | 1 | 400 | 605.891 | 582.600–712.296 | 7.04% | 1.00x |
| `polymorphic_properties` | 2 | 400 | 591.713 | 588.315–595.306 | 0.42% | 2.05x |
| `polymorphic_properties` | 4 | 400 | 681.100 | 676.904–682.304 | 0.26% | 3.56x |
| `polymorphic_properties` | 8 | 400 | 842.059 | 836.812–845.162 | 0.38% | 5.76x |
| `object_churn` | 1 | 100 | 146.979 | 113.236–151.590 | 9.27% | 1.00x |
| `object_churn` | 2 | 100 | 273.948 | 203.092–292.117 | 12.32% | 1.07x |
| `object_churn` | 4 | 100 | 604.686 | 459.679–741.782 | 14.11% | 0.97x |
| `object_churn` | 8 | 100 | 1671.114 | 1534.975–1889.424 | 7.24% | 0.70x |
| `arrays` | 1 | 550 | 93.659 | 92.971–110.944 | 6.83% | 1.00x |
| `arrays` | 2 | 550 | 99.370 | 98.550–159.122 | 20.78% | 1.89x |
| `arrays` | 4 | 550 | 128.838 | 125.436–159.706 | 10.75% | 2.91x |
| `arrays` | 8 | 550 | 392.151 | 342.830–495.400 | 13.07% | 1.91x |
| `direct_calls` | 1 | 600 | 60.123 | 59.544–61.561 | 1.16% | 1.00x |
| `direct_calls` | 2 | 600 | 64.899 | 62.078–67.573 | 3.09% | 1.85x |
| `direct_calls` | 4 | 600 | 66.704 | 65.552–81.425 | 10.07% | 3.61x |
| `direct_calls` | 8 | 600 | 87.493 | 84.319–96.230 | 5.02% | 5.50x |
| `method_calls` | 1 | 500 | 155.268 | 155.046–158.104 | 0.69% | 1.00x |
| `method_calls` | 2 | 500 | 158.785 | 158.587–162.348 | 0.85% | 1.96x |
| `method_calls` | 4 | 500 | 175.380 | 169.837–204.854 | 6.72% | 3.54x |
| `method_calls` | 8 | 500 | 223.915 | 221.180–256.252 | 5.66% | 5.55x |
| `closure_calls` | 1 | 600 | 67.047 | 66.787–68.616 | 1.09% | 1.00x |
| `closure_calls` | 2 | 600 | 68.131 | 67.878–69.643 | 1.13% | 1.97x |
| `closure_calls` | 4 | 600 | 74.722 | 72.108–118.396 | 20.50% | 3.59x |
| `closure_calls` | 8 | 600 | 95.213 | 94.028–101.571 | 2.75% | 5.63x |
| `arguments_calls` | 1 | 600 | 71.888 | 70.985–73.621 | 1.41% | 1.00x |
| `arguments_calls` | 2 | 600 | 73.468 | 72.468–75.697 | 1.67% | 1.96x |
| `arguments_calls` | 4 | 600 | 82.093 | 79.463–90.948 | 4.93% | 3.50x |
| `arguments_calls` | 8 | 600 | 120.298 | 116.243–166.023 | 14.15% | 4.78x |
| `fibonacci` | 1 | 125 | 296.225 | 295.409–298.466 | 0.42% | 1.00x |
| `fibonacci` | 2 | 125 | 302.015 | 300.586–303.772 | 0.41% | 1.96x |
| `fibonacci` | 4 | 125 | 336.390 | 333.857–349.582 | 1.92% | 3.52x |
| `fibonacci` | 8 | 125 | 469.612 | 461.055–491.030 | 2.09% | 5.05x |

## Reading the result

Across these 10 deliberately small kernels, JSC's single-context throughput is 0.38x
the zig-js throughput by geometric mean. These kernels deliberately exercise guarded native/VM tiers that
zig-js currently implements; rows outside those documented subsets continue through general bytecode paths.
The number is a compact description of this matrix, not a claim about applications or unsupported workloads.

At 8 independent warmed contexts, JSC throughput is 0.34x zig-js by
geometric mean; scaling from the mode's own one-lane baseline is 5.14x
for zig-js and 4.77x for JSC. In the symmetric cold lifecycle, JSC
throughput is 0.34x zig-js, with 5.18x
and 4.76x scaling respectively.

zig-js's shared-realm path scales 3.97x at 8 lanes from its
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

Raw samples: [`benchmark-comparison-2026-07-15-128-byte-slab.tsv`](benchmark-comparison-2026-07-15-128-byte-slab.tsv)
