# zig-js / JavaScriptCore benchmark — 2026-07-17

> This is a dated measurement, not a universal engine score. The workload source, raw samples,
> timed boundaries, and semantic differences are recorded so the result can be reproduced and challenged.

## Environment

| item | value |
| --- | --- |
| Date | 2026-07-17 |
| Host | Apple M3 Pro; 11 physical / 11 logical CPUs; 18.0 GiB |
| OS | macOS 27.0 (26A5368g) |
| Zig | 0.17.0-dev.956+2dca73595 |
| zig-js | 01fcf42c9f6ca2b4e75a7cde13de748f9c037e04 |
| zig-gc | c67e344dd42e5246079a1c7835b9df3af42ff5e7 |
| zig-regex | 86159c5b9e0996ce6942b99d4ea76ed6c80a9a24 |
| JavaScriptCore | system framework 22625.1.20.11.3 |
| Power | Now drawing from 'AC Power' -InternalBattery-0 (id=22806627) 100%; charged; 0:00 remaining present: true |

## Single-thread result

Each row runs the same number of jobs in one GC-enabled zig-js context and one warmed JSC global context.
Both runners time the exact invocation `__benchmarkSelected(__benchmarkJobs, __benchmarkLane)`.
Lower time is better; `JSC / zig-js` is JSC throughput divided by zig-js throughput. RSD is relative standard deviation.

| workload | jobs | zig-js median (ms) | zig-js min–max (ms) | zig-js RSD | JSC median (ms) | JSC min–max (ms) | JSC RSD | JSC / zig-js |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `arithmetic` | 240 | 85.429 | 84.477–97.200 | 5.14% | 358.819 | 355.160–375.367 | 2.05% | 0.24x |
| `properties` | 300 | 100.759 | 100.228–108.107 | 2.85% | 294.505 | 291.942–299.103 | 0.81% | 0.34x |
| `polymorphic_properties` | 400 | 97.913 | 97.770–114.248 | 6.15% | 209.625 | 209.236–211.716 | 0.51% | 0.47x |
| `object_churn` | 100 | 96.410 | 95.009–97.350 | 0.87% | 129.002 | 128.638–146.259 | 4.94% | 0.75x |
| `arrays` | 550 | 100.417 | 99.628–116.472 | 5.87% | 166.654 | 163.688–226.785 | 15.77% | 0.60x |
| `direct_calls` | 600 | 81.097 | 80.885–82.843 | 0.85% | 122.462 | 121.843–140.606 | 5.49% | 0.66x |
| `method_calls` | 500 | 86.833 | 86.459–87.354 | 0.34% | 148.788 | 148.262–158.697 | 2.59% | 0.58x |
| `closure_calls` | 600 | 90.154 | 89.740–91.413 | 0.67% | 229.340 | 203.536–250.497 | 7.75% | 0.39x |
| `arguments_calls` | 600 | 96.357 | 94.799–110.023 | 6.33% | 326.770 | 325.192–328.040 | 0.30% | 0.29x |
| `fibonacci` | 125 | 90.338 | 89.715–104.962 | 6.48% | 489.696 | 485.209–507.847 | 1.95% | 0.18x |

## Independent-context steady state

Both engines keep one warmed context on one persistent OS worker per lane. The timed region contains the
same semaphore dispatch, exact invocation, and completion wait. Every lane performs the full job count.
`scaling` uses the same engine and mode at one lane; cross-engine throughput is directly comparable.

| workload | lanes | jobs/lane | zig-js median (ms) | zig-js min–max (ms) | zig-js RSD | JSC median (ms) | JSC min–max (ms) | JSC RSD | JSC / zig-js | zig-js scaling | JSC scaling |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `arithmetic` | 1 | 240 | 83.782 | 83.591–85.975 | 1.00% | 355.752 | 352.283–383.668 | 3.05% | 0.24x | 1.00x | 1.00x |
| `arithmetic` | 2 | 240 | 85.902 | 85.546–94.888 | 3.91% | 365.264 | 363.791–371.263 | 0.76% | 0.24x | 1.95x | 1.95x |
| `arithmetic` | 4 | 240 | 89.618 | 88.379–98.576 | 4.58% | 419.553 | 415.388–438.084 | 1.95% | 0.21x | 3.74x | 3.39x |
| `arithmetic` | 8 | 240 | 106.607 | 105.497–112.072 | 2.12% | 593.386 | 581.087–781.338 | 11.98% | 0.18x | 6.29x | 4.80x |
| `properties` | 1 | 300 | 109.293 | 107.964–125.094 | 6.34% | 290.728 | 289.950–313.754 | 3.12% | 0.38x | 1.00x | 1.00x |
| `properties` | 2 | 300 | 113.125 | 112.930–114.328 | 0.43% | 303.825 | 302.666–313.419 | 1.44% | 0.37x | 1.93x | 1.91x |
| `properties` | 4 | 300 | 125.137 | 120.081–126.602 | 1.91% | 361.540 | 341.919–384.937 | 3.99% | 0.35x | 3.49x | 3.22x |
| `properties` | 8 | 300 | 154.267 | 148.591–169.788 | 4.30% | 508.480 | 485.051–1832.562 | 72.34% | 0.30x | 5.67x | 4.57x |
| `polymorphic_properties` | 1 | 400 | 98.304 | 98.231–110.978 | 4.66% | 209.721 | 209.264–211.419 | 0.34% | 0.47x | 1.00x | 1.00x |
| `polymorphic_properties` | 2 | 400 | 100.636 | 100.118–101.708 | 0.58% | 217.811 | 214.575–237.694 | 3.69% | 0.46x | 1.95x | 1.93x |
| `polymorphic_properties` | 4 | 400 | 120.726 | 118.080–127.839 | 2.76% | 268.962 | 259.750–298.284 | 5.00% | 0.45x | 3.26x | 3.12x |
| `polymorphic_properties` | 8 | 400 | 228.064 | 178.782–442.834 | 33.68% | 377.483 | 352.512–510.866 | 13.78% | 0.60x | 3.45x | 4.44x |
| `object_churn` | 1 | 100 | 97.057 | 96.398–133.530 | 13.49% | 126.798 | 126.201–133.306 | 1.99% | 0.77x | 1.00x | 1.00x |
| `object_churn` | 2 | 100 | 105.952 | 104.294–128.585 | 8.13% | 137.168 | 129.992–167.906 | 10.21% | 0.77x | 1.83x | 1.85x |
| `object_churn` | 4 | 100 | 149.090 | 142.135–154.119 | 2.50% | 162.549 | 161.007–194.037 | 7.34% | 0.92x | 2.60x | 3.12x |
| `object_churn` | 8 | 100 | 222.502 | 212.877–252.985 | 6.23% | 229.380 | 223.959–246.326 | 3.65% | 0.97x | 3.49x | 4.42x |
| `arrays` | 1 | 550 | 100.225 | 96.937–117.233 | 6.65% | 178.296 | 165.309–234.998 | 13.09% | 0.56x | 1.00x | 1.00x |
| `arrays` | 2 | 550 | 103.451 | 103.054–105.175 | 0.70% | 170.364 | 168.762–187.631 | 3.85% | 0.61x | 1.94x | 2.09x |
| `arrays` | 4 | 550 | 129.309 | 110.360–151.087 | 9.72% | 185.477 | 174.701–190.532 | 2.90% | 0.70x | 3.10x | 3.85x |
| `arrays` | 8 | 550 | 212.290 | 158.885–229.673 | 16.43% | 282.733 | 271.614–288.340 | 2.15% | 0.75x | 3.78x | 5.04x |
| `direct_calls` | 1 | 600 | 81.056 | 80.794–92.090 | 4.95% | 122.604 | 121.771–138.305 | 4.84% | 0.66x | 1.00x | 1.00x |
| `direct_calls` | 2 | 600 | 87.552 | 86.563–101.012 | 5.84% | 132.619 | 131.138–134.610 | 0.99% | 0.66x | 1.85x | 1.85x |
| `direct_calls` | 4 | 600 | 99.064 | 96.416–105.117 | 3.44% | 177.335 | 167.590–197.267 | 5.01% | 0.56x | 3.27x | 2.77x |
| `direct_calls` | 8 | 600 | 127.018 | 121.601–150.705 | 7.35% | 246.439 | 239.548–292.625 | 7.27% | 0.52x | 5.11x | 3.98x |
| `method_calls` | 1 | 500 | 86.763 | 84.265–89.147 | 1.68% | 149.470 | 147.679–187.613 | 10.05% | 0.58x | 1.00x | 1.00x |
| `method_calls` | 2 | 500 | 103.467 | 91.192–115.812 | 7.94% | 152.937 | 152.552–154.236 | 0.37% | 0.68x | 1.68x | 1.95x |
| `method_calls` | 4 | 500 | 110.599 | 106.057–124.962 | 5.51% | 206.599 | 202.325–229.119 | 5.59% | 0.54x | 3.14x | 2.89x |
| `method_calls` | 8 | 500 | 141.173 | 136.004–163.035 | 6.44% | 279.008 | 275.109–289.004 | 1.82% | 0.51x | 4.92x | 4.29x |
| `closure_calls` | 1 | 600 | 90.130 | 89.814–102.514 | 5.06% | 204.224 | 201.717–243.149 | 7.17% | 0.44x | 1.00x | 1.00x |
| `closure_calls` | 2 | 600 | 93.401 | 92.324–104.698 | 4.86% | 208.677 | 207.827–209.560 | 0.34% | 0.45x | 1.93x | 1.96x |
| `closure_calls` | 4 | 600 | 113.494 | 108.461–115.004 | 2.12% | 298.924 | 291.193–324.350 | 3.45% | 0.38x | 3.18x | 2.73x |
| `closure_calls` | 8 | 600 | 149.675 | 140.354–186.747 | 10.90% | 629.159 | 518.314–695.802 | 11.15% | 0.24x | 4.82x | 2.60x |
| `arguments_calls` | 1 | 600 | 95.063 | 94.629–104.614 | 4.01% | 324.799 | 323.792–325.738 | 0.23% | 0.29x | 1.00x | 1.00x |
| `arguments_calls` | 2 | 600 | 99.108 | 98.967–121.239 | 8.00% | 338.473 | 334.637–364.304 | 3.42% | 0.29x | 1.92x | 1.92x |
| `arguments_calls` | 4 | 600 | 132.158 | 130.049–215.261 | 20.67% | 507.094 | 478.594–1168.293 | 38.67% | 0.26x | 2.88x | 2.56x |
| `arguments_calls` | 8 | 600 | 146.772 | 142.147–240.065 | 21.71% | 807.639 | 571.531–1217.368 | 25.68% | 0.18x | 5.18x | 3.22x |
| `fibonacci` | 1 | 125 | 89.912 | 89.400–113.135 | 9.47% | 494.726 | 487.928–516.419 | 2.12% | 0.18x | 1.00x | 1.00x |
| `fibonacci` | 2 | 125 | 91.334 | 90.610–91.991 | 0.57% | 497.502 | 495.134–514.975 | 1.34% | 0.18x | 1.97x | 1.99x |
| `fibonacci` | 4 | 125 | 116.730 | 110.378–135.228 | 6.66% | 616.580 | 599.997–643.722 | 2.27% | 0.19x | 3.08x | 3.21x |
| `fibonacci` | 8 | 125 | 149.289 | 143.936–177.994 | 7.55% | 851.687 | 845.497–973.848 | 5.81% | 0.18x | 4.82x | 4.65x |

## Independent-context cold lifecycle

Neither engine warms these contexts. The timer covers OS-thread creation, context creation, workload-source
evaluation and configuration, the exact invocation, context destruction, and OS-thread join on both sides.
`scaling` uses the same engine and cold lifecycle at one lane.

| workload | lanes | jobs/lane | zig-js median (ms) | zig-js min–max (ms) | zig-js RSD | JSC median (ms) | JSC min–max (ms) | JSC RSD | JSC / zig-js | zig-js scaling | JSC scaling |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `arithmetic` | 1 | 240 | 86.170 | 85.842–88.541 | 1.10% | 356.805 | 355.159–360.199 | 0.48% | 0.24x | 1.00x | 1.00x |
| `arithmetic` | 2 | 240 | 88.271 | 88.011–92.742 | 1.91% | 367.549 | 363.620–381.661 | 1.56% | 0.24x | 1.95x | 1.94x |
| `arithmetic` | 4 | 240 | 92.619 | 91.394–94.925 | 1.54% | 430.247 | 422.048–469.267 | 3.98% | 0.22x | 3.72x | 3.32x |
| `arithmetic` | 8 | 240 | 114.073 | 111.015–137.602 | 7.77% | 603.377 | 581.549–628.604 | 2.94% | 0.19x | 6.04x | 4.73x |
| `properties` | 1 | 300 | 108.880 | 108.150–121.793 | 4.39% | 298.030 | 296.921–310.046 | 1.53% | 0.37x | 1.00x | 1.00x |
| `properties` | 2 | 300 | 107.080 | 106.699–123.822 | 6.00% | 307.220 | 304.187–336.003 | 3.74% | 0.35x | 2.03x | 1.94x |
| `properties` | 4 | 300 | 113.707 | 109.690–115.562 | 1.69% | 356.131 | 345.716–388.425 | 3.99% | 0.32x | 3.83x | 3.35x |
| `properties` | 8 | 300 | 175.707 | 157.936–190.978 | 6.68% | 576.750 | 529.081–797.649 | 17.63% | 0.30x | 4.96x | 4.13x |
| `polymorphic_properties` | 1 | 400 | 99.934 | 99.650–100.591 | 0.36% | 213.978 | 210.066–218.725 | 1.38% | 0.47x | 1.00x | 1.00x |
| `polymorphic_properties` | 2 | 400 | 102.852 | 101.981–104.526 | 1.07% | 218.757 | 215.170–311.267 | 15.39% | 0.47x | 1.94x | 1.96x |
| `polymorphic_properties` | 4 | 400 | 125.021 | 122.340–131.288 | 2.45% | 269.684 | 259.744–286.066 | 3.53% | 0.46x | 3.20x | 3.17x |
| `polymorphic_properties` | 8 | 400 | 269.217 | 206.416–330.064 | 18.09% | 538.617 | 418.974–764.103 | 25.46% | 0.50x | 2.97x | 3.18x |
| `object_churn` | 1 | 100 | 100.742 | 96.804–129.744 | 11.04% | 128.913 | 126.903–143.901 | 4.61% | 0.78x | 1.00x | 1.00x |
| `object_churn` | 2 | 100 | 122.648 | 110.427–178.875 | 19.08% | 139.779 | 133.589–158.991 | 7.04% | 0.88x | 1.64x | 1.84x |
| `object_churn` | 4 | 100 | 189.416 | 168.745–275.915 | 20.37% | 184.532 | 171.449–194.955 | 5.39% | 1.03x | 2.13x | 2.79x |
| `object_churn` | 8 | 100 | 243.603 | 226.945–302.869 | 11.64% | 235.093 | 225.315–255.235 | 4.02% | 1.04x | 3.31x | 4.39x |
| `arrays` | 1 | 550 | 96.740 | 95.999–101.052 | 1.76% | 170.683 | 163.660–199.067 | 8.36% | 0.57x | 1.00x | 1.00x |
| `arrays` | 2 | 550 | 105.445 | 104.990–106.065 | 0.44% | 167.625 | 166.719–190.627 | 6.30% | 0.63x | 1.83x | 2.04x |
| `arrays` | 4 | 550 | 115.421 | 113.377–118.697 | 1.70% | 190.643 | 188.047–198.462 | 2.01% | 0.61x | 3.35x | 3.58x |
| `arrays` | 8 | 550 | 244.263 | 173.645–477.757 | 42.33% | 361.489 | 286.418–470.591 | 15.62% | 0.68x | 3.17x | 3.78x |
| `direct_calls` | 1 | 600 | 90.932 | 88.569–111.309 | 8.78% | 130.067 | 123.342–206.085 | 20.91% | 0.70x | 1.00x | 1.00x |
| `direct_calls` | 2 | 600 | 89.142 | 88.353–91.305 | 1.05% | 129.883 | 128.687–161.166 | 8.94% | 0.69x | 2.04x | 2.00x |
| `direct_calls` | 4 | 600 | 109.382 | 102.316–114.443 | 3.93% | 177.602 | 172.532–228.780 | 10.80% | 0.62x | 3.33x | 2.93x |
| `direct_calls` | 8 | 600 | 130.477 | 126.704–135.715 | 2.60% | 246.327 | 243.276–328.137 | 13.43% | 0.53x | 5.58x | 4.22x |
| `method_calls` | 1 | 500 | 90.706 | 90.301–98.933 | 3.43% | 149.317 | 149.013–159.178 | 2.48% | 0.61x | 1.00x | 1.00x |
| `method_calls` | 2 | 500 | 98.063 | 93.135–110.539 | 7.39% | 154.381 | 152.726–181.638 | 6.58% | 0.64x | 1.85x | 1.93x |
| `method_calls` | 4 | 500 | 112.753 | 109.927–120.509 | 3.05% | 193.550 | 181.702–230.456 | 9.33% | 0.58x | 3.22x | 3.09x |
| `method_calls` | 8 | 500 | 148.601 | 142.775–158.224 | 3.53% | 278.736 | 271.038–335.945 | 8.04% | 0.53x | 4.88x | 4.29x |
| `closure_calls` | 1 | 600 | 94.569 | 93.897–119.987 | 9.53% | 206.651 | 203.905–211.494 | 1.20% | 0.46x | 1.00x | 1.00x |
| `closure_calls` | 2 | 600 | 108.290 | 98.701–141.878 | 12.88% | 213.388 | 210.336–236.497 | 4.26% | 0.51x | 1.75x | 1.94x |
| `closure_calls` | 4 | 600 | 120.412 | 107.895–211.617 | 28.71% | 303.809 | 294.442–325.293 | 3.52% | 0.40x | 3.14x | 2.72x |
| `closure_calls` | 8 | 600 | 152.878 | 146.983–237.952 | 19.86% | 429.699 | 420.313–494.207 | 6.49% | 0.36x | 4.95x | 3.85x |
| `arguments_calls` | 1 | 600 | 99.346 | 98.729–158.219 | 20.47% | 327.327 | 324.864–367.486 | 4.59% | 0.30x | 1.00x | 1.00x |
| `arguments_calls` | 2 | 600 | 103.222 | 102.553–133.224 | 10.13% | 344.130 | 338.444–410.671 | 7.26% | 0.30x | 1.92x | 1.90x |
| `arguments_calls` | 4 | 600 | 178.626 | 135.168–254.091 | 22.72% | 395.296 | 358.598–443.703 | 7.80% | 0.45x | 2.22x | 3.31x |
| `arguments_calls` | 8 | 600 | 162.314 | 161.063–188.188 | 7.23% | 661.020 | 632.816–769.147 | 7.02% | 0.25x | 4.90x | 3.96x |
| `fibonacci` | 1 | 125 | 91.187 | 90.811–126.301 | 13.71% | 485.086 | 482.798–489.618 | 0.48% | 0.19x | 1.00x | 1.00x |
| `fibonacci` | 2 | 125 | 93.828 | 93.160–97.425 | 1.96% | 501.786 | 494.214–562.231 | 4.73% | 0.19x | 1.94x | 1.93x |
| `fibonacci` | 4 | 125 | 120.556 | 112.652–128.465 | 4.18% | 641.066 | 602.778–656.746 | 3.42% | 0.19x | 3.03x | 3.03x |
| `fibonacci` | 8 | 125 | 164.550 | 157.464–218.079 | 11.94% | 893.627 | 871.748–951.438 | 3.03% | 0.18x | 4.43x | 4.34x |

## zig-js shared-realm scaling

This is zig-js's distinct no-GIL shared-object-graph model, which JSC's public C API does not provide.
The timed region creates JavaScript `Thread`s, performs the work, and joins them. Scaling uses the same
shared-realm path at one lane, so thread lifecycle overhead is present in every row.

| workload | lanes | jobs/lane | median (ms) | min–max (ms) | RSD | scaling |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `arithmetic` | 1 | 240 | 1559.626 | 1546.031–1578.301 | 0.64% | 1.00x |
| `arithmetic` | 2 | 240 | 1584.441 | 1561.916–1605.535 | 0.95% | 1.97x |
| `arithmetic` | 4 | 240 | 1729.190 | 1717.100–1826.064 | 2.24% | 3.61x |
| `arithmetic` | 8 | 240 | 2336.735 | 2252.101–2423.241 | 2.50% | 5.34x |
| `properties` | 1 | 300 | 151.444 | 145.419–160.783 | 3.13% | 1.00x |
| `properties` | 2 | 300 | 151.708 | 147.685–163.304 | 3.28% | 2.00x |
| `properties` | 4 | 300 | 156.172 | 153.168–161.340 | 2.03% | 3.88x |
| `properties` | 8 | 300 | 228.395 | 218.202–295.571 | 11.31% | 5.30x |
| `polymorphic_properties` | 1 | 400 | 710.665 | 687.687–805.301 | 5.86% | 1.00x |
| `polymorphic_properties` | 2 | 400 | 725.296 | 709.233–788.592 | 3.69% | 1.96x |
| `polymorphic_properties` | 4 | 400 | 811.510 | 800.358–830.920 | 1.47% | 3.50x |
| `polymorphic_properties` | 8 | 400 | 1261.642 | 1230.860–1368.071 | 4.27% | 4.51x |
| `object_churn` | 1 | 100 | 190.969 | 158.192–213.289 | 9.64% | 1.00x |
| `object_churn` | 2 | 100 | 293.039 | 258.181–307.928 | 6.06% | 1.30x |
| `object_churn` | 4 | 100 | 683.870 | 517.644–916.220 | 20.84% | 1.12x |
| `object_churn` | 8 | 100 | 1651.879 | 1323.977–1734.101 | 9.07% | 0.92x |
| `arrays` | 1 | 550 | 105.259 | 104.404–106.108 | 0.64% | 1.00x |
| `arrays` | 2 | 550 | 111.340 | 111.030–132.077 | 6.85% | 1.89x |
| `arrays` | 4 | 550 | 144.146 | 138.033–176.375 | 10.47% | 2.92x |
| `arrays` | 8 | 550 | 340.577 | 283.095–419.865 | 15.12% | 2.47x |
| `direct_calls` | 1 | 600 | 92.705 | 89.410–102.550 | 4.46% | 1.00x |
| `direct_calls` | 2 | 600 | 90.212 | 89.782–103.891 | 5.54% | 2.06x |
| `direct_calls` | 4 | 600 | 110.982 | 105.268–113.988 | 2.90% | 3.34x |
| `direct_calls` | 8 | 600 | 141.091 | 136.407–148.402 | 2.90% | 5.26x |
| `method_calls` | 1 | 500 | 164.730 | 163.673–165.673 | 0.41% | 1.00x |
| `method_calls` | 2 | 500 | 168.134 | 167.982–175.266 | 1.59% | 1.96x |
| `method_calls` | 4 | 500 | 199.450 | 192.468–204.118 | 2.17% | 3.30x |
| `method_calls` | 8 | 500 | 280.145 | 263.358–373.404 | 12.92% | 4.70x |
| `closure_calls` | 1 | 600 | 93.998 | 93.503–94.418 | 0.30% | 1.00x |
| `closure_calls` | 2 | 600 | 104.673 | 95.112–147.633 | 16.35% | 1.80x |
| `closure_calls` | 4 | 600 | 111.602 | 106.566–113.686 | 2.06% | 3.37x |
| `closure_calls` | 8 | 600 | 154.069 | 147.044–175.535 | 7.08% | 4.88x |
| `arguments_calls` | 1 | 600 | 95.443 | 94.510–97.545 | 1.23% | 1.00x |
| `arguments_calls` | 2 | 600 | 113.582 | 100.186–216.379 | 33.02% | 1.68x |
| `arguments_calls` | 4 | 600 | 107.143 | 100.383–113.522 | 3.86% | 3.56x |
| `arguments_calls` | 8 | 600 | 175.343 | 149.716–209.669 | 12.74% | 4.35x |
| `fibonacci` | 1 | 125 | 305.889 | 305.404–327.260 | 2.98% | 1.00x |
| `fibonacci` | 2 | 125 | 318.734 | 314.020–354.350 | 4.49% | 1.92x |
| `fibonacci` | 4 | 125 | 382.602 | 371.952–395.386 | 2.31% | 3.20x |
| `fibonacci` | 8 | 125 | 538.814 | 512.825–587.665 | 4.83% | 4.54x |

## Reading the result

Across these 10 deliberately small kernels, JSC's single-context throughput is 0.41x
the zig-js throughput by geometric mean. These kernels deliberately exercise guarded native/VM tiers that
zig-js currently implements; rows outside those documented subsets continue through general bytecode paths.
The number is a compact description of this matrix, not a claim about applications or unsupported workloads.

At 8 independent warmed contexts, JSC throughput is 0.37x zig-js by
geometric mean; scaling from the mode's own one-lane baseline is 4.67x
for zig-js and 4.13x for JSC. In the symmetric cold lifecycle, JSC
throughput is 0.39x zig-js, with 4.40x
and 4.07x scaling respectively.

zig-js's shared-realm path scales 3.84x at 8 lanes from its
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

Raw samples: [`benchmark-comparison-2026-07-17-structured-stacks.tsv`](benchmark-comparison-2026-07-17-structured-stacks.tsv)
