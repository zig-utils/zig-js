# zig-js / JavaScriptCore benchmark — 2026-07-29

> This is a dated measurement, not a universal engine score. The workload source, raw samples,
> timed boundaries, and semantic differences are recorded so the result can be reproduced and challenged.

## Environment

| item | value |
| --- | --- |
| Date | 2026-07-29 |
| Host | Apple M3 Pro; 11 physical / 11 logical CPUs; 18.0 GiB |
| OS | macOS 27.0 (26A5388g) |
| Zig | 0.17.0-dev.1441+d5181a9c9 |
| zig-js | 0f8b33c882eb53ad4d3111410d09fd71b15a10e9 |
| zig-gc | a09c01555f8b5e1485d8be5757864967942f699d |
| zig-regex | 2de46683b948ec895e5fa9a9e7e4c384aceccdfe |
| JavaScriptCore | system framework 22625.1.24.11.2 |
| Power | Now drawing from 'AC Power' -InternalBattery-0 (id=23330915) 80%; AC attached; not charging present: true |

## Single-thread result

Each row runs the same number of jobs in one GC-enabled zig-js context and one warmed JSC global context.
Both runners time the exact invocation `__benchmarkSelected(__benchmarkJobs, __benchmarkLane)`.
Lower time is better; `JSC / zig-js` is JSC throughput divided by zig-js throughput. RSD is relative standard deviation.

| workload | jobs | zig-js median (ms) | zig-js min–max (ms) | zig-js RSD | JSC median (ms) | JSC min–max (ms) | JSC RSD | JSC / zig-js |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `arithmetic` | 240 | 87.806 | 86.994–91.171 | 1.61% | 368.954 | 365.040–409.992 | 4.32% | 0.24x |
| `properties` | 300 | 113.487 | 112.039–114.855 | 0.81% | 316.978 | 315.688–320.019 | 0.50% | 0.36x |
| `polymorphic_properties` | 400 | 100.264 | 98.378–104.641 | 2.22% | 215.304 | 214.493–218.221 | 0.67% | 0.47x |
| `object_churn` | 100 | 130.957 | 128.991–132.597 | 0.92% | 133.573 | 131.816–135.230 | 0.76% | 0.98x |
| `arrays` | 550 | 122.055 | 115.048–148.422 | 9.78% | 184.949 | 179.939–274.548 | 17.34% | 0.66x |
| `direct_calls` | 600 | 89.470 | 89.023–90.866 | 0.79% | 136.727 | 135.551–142.814 | 1.82% | 0.65x |
| `method_calls` | 500 | 100.722 | 99.294–104.132 | 1.74% | 164.479 | 160.894–231.136 | 14.33% | 0.61x |
| `closure_calls` | 600 | 106.594 | 104.882–109.315 | 1.66% | 235.884 | 224.282–268.258 | 6.27% | 0.45x |
| `arguments_calls` | 600 | 103.201 | 102.098–105.363 | 1.15% | 363.363 | 355.929–385.231 | 2.74% | 0.28x |
| `fibonacci` | 125 | 100.952 | 99.844–106.129 | 2.08% | 525.299 | 522.496–534.748 | 0.74% | 0.19x |

## Independent-context steady state

Both engines keep one warmed context on one persistent OS worker per lane. The timed region contains the
same semaphore dispatch, exact invocation, and completion wait. Every lane performs the full job count.
`scaling` uses the same engine and mode at one lane; cross-engine throughput is directly comparable.

| workload | lanes | jobs/lane | zig-js median (ms) | zig-js min–max (ms) | zig-js RSD | JSC median (ms) | JSC min–max (ms) | JSC RSD | JSC / zig-js | zig-js scaling | JSC scaling |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `arithmetic` | 1 | 240 | 87.442 | 86.948–88.947 | 0.75% | 369.614 | 367.576–370.949 | 0.33% | 0.24x | 1.00x | 1.00x |
| `arithmetic` | 2 | 240 | 88.307 | 87.997–88.905 | 0.37% | 374.085 | 370.854–377.411 | 0.60% | 0.24x | 1.98x | 1.98x |
| `arithmetic` | 4 | 240 | 91.382 | 90.283–93.407 | 1.43% | 390.999 | 386.902–396.677 | 1.03% | 0.23x | 3.83x | 3.78x |
| `arithmetic` | 8 | 240 | 109.723 | 107.972–113.244 | 1.83% | 678.864 | 576.069–756.320 | 9.42% | 0.16x | 6.38x | 4.36x |
| `properties` | 1 | 300 | 112.722 | 112.447–113.457 | 0.29% | 316.147 | 314.433–338.168 | 2.61% | 0.36x | 1.00x | 1.00x |
| `properties` | 2 | 300 | 113.447 | 112.565–113.937 | 0.44% | 320.542 | 319.484–321.293 | 0.21% | 0.35x | 1.99x | 1.97x |
| `properties` | 4 | 300 | 116.349 | 116.088–117.325 | 0.37% | 351.776 | 348.758–354.635 | 0.65% | 0.33x | 3.88x | 3.59x |
| `properties` | 8 | 300 | 165.245 | 146.174–258.764 | 22.63% | 505.208 | 494.058–519.283 | 1.48% | 0.33x | 5.46x | 5.01x |
| `polymorphic_properties` | 1 | 400 | 100.388 | 99.636–103.228 | 1.17% | 215.895 | 214.813–283.597 | 11.25% | 0.46x | 1.00x | 1.00x |
| `polymorphic_properties` | 2 | 400 | 103.686 | 102.614–112.125 | 3.18% | 241.294 | 222.279–348.345 | 16.81% | 0.43x | 1.94x | 1.79x |
| `polymorphic_properties` | 4 | 400 | 108.503 | 106.641–109.652 | 0.88% | 253.686 | 252.502–342.239 | 12.31% | 0.43x | 3.70x | 3.40x |
| `polymorphic_properties` | 8 | 400 | 163.655 | 159.756–170.391 | 2.43% | 379.464 | 374.412–428.402 | 5.28% | 0.43x | 4.91x | 4.55x |
| `object_churn` | 1 | 100 | 131.065 | 130.178–133.071 | 0.85% | 132.587 | 131.661–134.289 | 0.74% | 0.99x | 1.00x | 1.00x |
| `object_churn` | 2 | 100 | 134.762 | 134.231–136.385 | 0.65% | 134.203 | 133.021–136.335 | 0.98% | 1.00x | 1.95x | 1.98x |
| `object_churn` | 4 | 100 | 154.072 | 150.118–155.117 | 1.14% | 147.493 | 146.086–149.279 | 0.83% | 1.04x | 3.40x | 3.60x |
| `object_churn` | 8 | 100 | 242.790 | 228.964–316.564 | 11.55% | 210.873 | 204.231–228.899 | 4.11% | 1.15x | 4.32x | 5.03x |
| `arrays` | 1 | 550 | 116.344 | 115.684–118.125 | 0.78% | 183.949 | 182.118–187.265 | 0.92% | 0.63x | 1.00x | 1.00x |
| `arrays` | 2 | 550 | 121.100 | 119.264–122.924 | 1.08% | 186.186 | 183.996–187.123 | 0.66% | 0.65x | 1.92x | 1.98x |
| `arrays` | 4 | 550 | 132.447 | 124.519–139.616 | 4.11% | 198.968 | 196.852–201.980 | 0.82% | 0.67x | 3.51x | 3.70x |
| `arrays` | 8 | 550 | 228.489 | 195.845–368.204 | 23.38% | 300.050 | 289.485–361.164 | 9.39% | 0.76x | 4.07x | 4.90x |
| `direct_calls` | 1 | 600 | 93.448 | 90.960–99.174 | 3.15% | 136.664 | 135.877–137.809 | 0.45% | 0.68x | 1.00x | 1.00x |
| `direct_calls` | 2 | 600 | 91.212 | 90.018–95.420 | 2.54% | 138.249 | 137.665–139.976 | 0.74% | 0.66x | 2.05x | 1.98x |
| `direct_calls` | 4 | 600 | 100.499 | 98.799–102.805 | 1.42% | 155.840 | 154.886–157.324 | 0.63% | 0.64x | 3.72x | 3.51x |
| `direct_calls` | 8 | 600 | 114.073 | 110.980–123.037 | 3.78% | 220.590 | 215.777–229.867 | 2.21% | 0.52x | 6.55x | 4.96x |
| `method_calls` | 1 | 500 | 100.967 | 99.637–102.853 | 1.13% | 163.129 | 157.754–167.239 | 1.72% | 0.62x | 1.00x | 1.00x |
| `method_calls` | 2 | 500 | 101.547 | 100.623–105.978 | 2.09% | 164.136 | 163.532–168.198 | 1.14% | 0.62x | 1.99x | 1.99x |
| `method_calls` | 4 | 500 | 104.765 | 102.833–112.777 | 3.55% | 176.619 | 170.506–183.617 | 2.46% | 0.59x | 3.85x | 3.69x |
| `method_calls` | 8 | 500 | 132.464 | 128.421–139.072 | 3.05% | 264.416 | 249.632–267.504 | 3.21% | 0.50x | 6.10x | 4.94x |
| `closure_calls` | 1 | 600 | 108.754 | 105.917–110.018 | 1.46% | 227.300 | 224.178–231.197 | 0.99% | 0.48x | 1.00x | 1.00x |
| `closure_calls` | 2 | 600 | 104.959 | 104.216–106.195 | 0.63% | 234.665 | 233.790–325.076 | 13.80% | 0.45x | 2.07x | 1.94x |
| `closure_calls` | 4 | 600 | 110.447 | 106.850–113.354 | 2.11% | 290.542 | 267.566–306.690 | 5.09% | 0.38x | 3.94x | 3.13x |
| `closure_calls` | 8 | 600 | 149.856 | 140.569–156.548 | 3.90% | 402.743 | 392.064–411.902 | 1.62% | 0.37x | 5.81x | 4.52x |
| `arguments_calls` | 1 | 600 | 102.329 | 101.636–103.634 | 0.66% | 359.254 | 355.660–363.221 | 0.85% | 0.28x | 1.00x | 1.00x |
| `arguments_calls` | 2 | 600 | 106.536 | 102.554–111.477 | 2.96% | 363.592 | 360.661–376.931 | 1.45% | 0.29x | 1.92x | 1.98x |
| `arguments_calls` | 4 | 600 | 110.669 | 108.771–112.924 | 1.34% | 407.598 | 401.025–438.535 | 3.03% | 0.27x | 3.70x | 3.53x |
| `arguments_calls` | 8 | 600 | 154.727 | 128.352–168.719 | 10.59% | 594.665 | 570.768–730.588 | 9.09% | 0.26x | 5.29x | 4.83x |
| `fibonacci` | 1 | 125 | 99.266 | 96.902–100.472 | 1.10% | 534.825 | 524.108–569.290 | 3.05% | 0.19x | 1.00x | 1.00x |
| `fibonacci` | 2 | 125 | 99.555 | 98.298–101.012 | 1.02% | 619.690 | 524.380–825.593 | 17.90% | 0.16x | 1.99x | 1.73x |
| `fibonacci` | 4 | 125 | 105.334 | 102.996–106.924 | 1.61% | 573.231 | 554.238–685.944 | 7.70% | 0.18x | 3.77x | 3.73x |
| `fibonacci` | 8 | 125 | 164.180 | 153.367–173.787 | 4.36% | 809.854 | 801.270–903.332 | 4.37% | 0.20x | 4.84x | 5.28x |

## Independent-context cold lifecycle

Neither engine warms these contexts. The timer covers OS-thread creation, context creation, workload-source
evaluation and configuration, the exact invocation, context destruction, and OS-thread join on both sides.
`scaling` uses the same engine and cold lifecycle at one lane.

| workload | lanes | jobs/lane | zig-js median (ms) | zig-js min–max (ms) | zig-js RSD | JSC median (ms) | JSC min–max (ms) | JSC RSD | JSC / zig-js | zig-js scaling | JSC scaling |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `arithmetic` | 1 | 240 | 89.909 | 89.506–90.869 | 0.54% | 368.962 | 363.254–372.609 | 0.88% | 0.24x | 1.00x | 1.00x |
| `arithmetic` | 2 | 240 | 91.828 | 91.106–95.046 | 1.50% | 375.168 | 373.818–377.051 | 0.31% | 0.24x | 1.96x | 1.97x |
| `arithmetic` | 4 | 240 | 94.639 | 93.660–95.038 | 0.61% | 398.170 | 390.482–398.806 | 0.89% | 0.24x | 3.80x | 3.71x |
| `arithmetic` | 8 | 240 | 120.122 | 112.448–121.917 | 3.05% | 582.844 | 573.973–615.520 | 2.71% | 0.21x | 5.99x | 5.06x |
| `properties` | 1 | 300 | 113.760 | 112.458–119.288 | 2.50% | 319.459 | 316.047–400.025 | 9.31% | 0.36x | 1.00x | 1.00x |
| `properties` | 2 | 300 | 114.916 | 114.515–116.754 | 0.64% | 320.889 | 318.899–323.551 | 0.48% | 0.36x | 1.98x | 1.99x |
| `properties` | 4 | 300 | 129.208 | 118.975–228.388 | 27.53% | 358.593 | 356.062–363.178 | 0.82% | 0.36x | 3.52x | 3.56x |
| `properties` | 8 | 300 | 152.150 | 146.516–166.193 | 4.43% | 519.308 | 513.780–527.758 | 0.99% | 0.29x | 5.98x | 4.92x |
| `polymorphic_properties` | 1 | 400 | 102.055 | 101.317–106.138 | 1.73% | 229.594 | 219.375–257.998 | 5.79% | 0.44x | 1.00x | 1.00x |
| `polymorphic_properties` | 2 | 400 | 108.598 | 105.100–111.938 | 2.29% | 226.037 | 222.527–233.911 | 1.82% | 0.48x | 1.88x | 2.03x |
| `polymorphic_properties` | 4 | 400 | 110.907 | 108.934–116.169 | 2.21% | 261.907 | 256.743–269.684 | 1.90% | 0.42x | 3.68x | 3.51x |
| `polymorphic_properties` | 8 | 400 | 167.698 | 163.372–173.522 | 2.03% | 385.959 | 377.675–537.790 | 14.31% | 0.43x | 4.87x | 4.76x |
| `object_churn` | 1 | 100 | 147.324 | 133.722–149.635 | 4.99% | 133.234 | 132.208–139.361 | 1.83% | 1.11x | 1.00x | 1.00x |
| `object_churn` | 2 | 100 | 143.828 | 137.993–160.265 | 5.24% | 137.552 | 137.171–143.278 | 1.72% | 1.05x | 2.05x | 1.94x |
| `object_churn` | 4 | 100 | 163.467 | 158.517–167.047 | 2.02% | 152.705 | 148.911–184.227 | 7.97% | 1.07x | 3.60x | 3.49x |
| `object_churn` | 8 | 100 | 255.224 | 240.186–289.946 | 6.90% | 213.364 | 208.642–242.229 | 5.15% | 1.20x | 4.62x | 5.00x |
| `arrays` | 1 | 550 | 97.263 | 95.862–100.757 | 1.54% | 185.333 | 183.585–189.366 | 1.01% | 0.52x | 1.00x | 1.00x |
| `arrays` | 2 | 550 | 101.107 | 100.146–108.290 | 2.84% | 182.290 | 180.506–186.354 | 1.10% | 0.55x | 1.92x | 2.03x |
| `arrays` | 4 | 550 | 107.870 | 104.797–118.949 | 4.44% | 201.914 | 197.155–212.332 | 2.30% | 0.53x | 3.61x | 3.67x |
| `arrays` | 8 | 550 | 161.846 | 145.613–212.884 | 13.60% | 308.229 | 300.084–323.891 | 3.24% | 0.53x | 4.81x | 4.81x |
| `direct_calls` | 1 | 600 | 92.583 | 90.749–97.665 | 2.54% | 137.563 | 136.374–140.727 | 1.00% | 0.67x | 1.00x | 1.00x |
| `direct_calls` | 2 | 600 | 93.606 | 92.210–95.114 | 1.12% | 139.967 | 138.227–142.051 | 0.84% | 0.67x | 1.98x | 1.97x |
| `direct_calls` | 4 | 600 | 99.596 | 97.572–104.964 | 2.29% | 157.323 | 153.721–253.600 | 21.36% | 0.63x | 3.72x | 3.50x |
| `direct_calls` | 8 | 600 | 117.235 | 115.741–120.019 | 1.44% | 231.051 | 228.360–250.962 | 3.28% | 0.51x | 6.32x | 4.76x |
| `method_calls` | 1 | 500 | 103.572 | 101.759–105.932 | 1.75% | 164.222 | 162.850–166.428 | 0.90% | 0.63x | 1.00x | 1.00x |
| `method_calls` | 2 | 500 | 105.484 | 103.307–113.986 | 3.52% | 166.852 | 163.316–174.957 | 2.37% | 0.63x | 1.96x | 1.97x |
| `method_calls` | 4 | 500 | 107.620 | 106.302–115.360 | 3.26% | 178.930 | 175.169–189.130 | 3.03% | 0.60x | 3.85x | 3.67x |
| `method_calls` | 8 | 500 | 134.240 | 131.218–147.831 | 4.66% | 270.205 | 252.950–384.675 | 15.79% | 0.50x | 6.17x | 4.86x |
| `closure_calls` | 1 | 600 | 106.439 | 105.512–109.323 | 1.29% | 230.895 | 227.613–236.803 | 1.22% | 0.46x | 1.00x | 1.00x |
| `closure_calls` | 2 | 600 | 108.974 | 107.090–115.198 | 2.72% | 240.659 | 235.739–266.714 | 4.36% | 0.45x | 1.95x | 1.92x |
| `closure_calls` | 4 | 600 | 111.838 | 109.696–122.767 | 4.27% | 276.055 | 261.004–381.081 | 14.33% | 0.41x | 3.81x | 3.35x |
| `closure_calls` | 8 | 600 | 138.338 | 135.517–162.828 | 6.79% | 414.141 | 394.753–419.022 | 2.32% | 0.33x | 6.16x | 4.46x |
| `arguments_calls` | 1 | 600 | 109.647 | 105.165–113.323 | 2.35% | 388.345 | 362.765–720.944 | 29.45% | 0.28x | 1.00x | 1.00x |
| `arguments_calls` | 2 | 600 | 106.987 | 104.906–111.292 | 1.93% | 374.180 | 364.293–386.017 | 1.90% | 0.29x | 2.05x | 2.08x |
| `arguments_calls` | 4 | 600 | 111.460 | 109.844–115.875 | 1.73% | 414.179 | 412.203–432.098 | 1.69% | 0.27x | 3.93x | 3.75x |
| `arguments_calls` | 8 | 600 | 145.240 | 134.438–170.863 | 8.75% | 609.879 | 599.349–689.676 | 6.30% | 0.24x | 6.04x | 5.09x |
| `fibonacci` | 1 | 125 | 100.234 | 99.723–101.552 | 0.64% | 526.197 | 523.013–546.895 | 1.56% | 0.19x | 1.00x | 1.00x |
| `fibonacci` | 2 | 125 | 103.664 | 101.675–107.226 | 2.00% | 546.457 | 517.113–640.520 | 7.17% | 0.19x | 1.93x | 1.93x |
| `fibonacci` | 4 | 125 | 117.302 | 110.460–120.915 | 3.09% | 579.108 | 570.494–586.214 | 1.31% | 0.20x | 3.42x | 3.63x |
| `fibonacci` | 8 | 125 | 168.209 | 161.725–180.631 | 3.83% | 811.768 | 804.361–928.292 | 6.50% | 0.21x | 4.77x | 5.19x |

## zig-js shared-realm scaling

This is zig-js's distinct no-GIL shared-object-graph model, which JSC's public C API does not provide.
The timed region creates JavaScript `Thread`s, performs the work, and joins them. Scaling uses the same
shared-realm path at one lane, so thread lifecycle overhead is present in every row.

| workload | lanes | jobs/lane | median (ms) | min–max (ms) | RSD | scaling |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `arithmetic` | 1 | 240 | 86.737 | 86.462–87.269 | 0.37% | 1.00x |
| `arithmetic` | 2 | 240 | 87.660 | 87.418–95.718 | 3.40% | 1.98x |
| `arithmetic` | 4 | 240 | 90.522 | 89.485–91.136 | 0.62% | 3.83x |
| `arithmetic` | 8 | 240 | 109.895 | 107.972–114.121 | 1.97% | 6.31x |
| `properties` | 1 | 300 | 158.924 | 157.715–159.728 | 0.45% | 1.00x |
| `properties` | 2 | 300 | 160.463 | 158.970–161.730 | 0.57% | 1.98x |
| `properties` | 4 | 300 | 185.002 | 179.677–188.665 | 1.67% | 3.44x |
| `properties` | 8 | 300 | 221.755 | 217.765–229.021 | 1.56% | 5.73x |
| `polymorphic_properties` | 1 | 400 | 768.125 | 766.648–821.850 | 2.59% | 1.00x |
| `polymorphic_properties` | 2 | 400 | 782.616 | 780.351–792.190 | 0.56% | 1.96x |
| `polymorphic_properties` | 4 | 400 | 874.518 | 837.693–890.352 | 2.01% | 3.51x |
| `polymorphic_properties` | 8 | 400 | 1188.795 | 1173.315–1205.151 | 0.91% | 5.17x |
| `object_churn` | 1 | 100 | 213.933 | 203.308–241.862 | 6.03% | 1.00x |
| `object_churn` | 2 | 100 | 348.333 | 161.454–433.600 | 24.92% | 1.23x |
| `object_churn` | 4 | 100 | 658.507 | 279.148–760.161 | 26.25% | 1.30x |
| `object_churn` | 8 | 100 | 2315.385 | 1954.319–3652.737 | 24.16% | 0.74x |
| `arrays` | 1 | 550 | 749.390 | 744.197–776.314 | 1.49% | 1.00x |
| `arrays` | 2 | 550 | 745.372 | 726.604–828.230 | 4.72% | 2.01x |
| `arrays` | 4 | 550 | 792.833 | 743.512–951.436 | 8.91% | 3.78x |
| `arrays` | 8 | 550 | 1115.850 | 1103.140–1262.883 | 4.89% | 5.37x |
| `direct_calls` | 1 | 600 | 90.127 | 88.659–92.330 | 1.39% | 1.00x |
| `direct_calls` | 2 | 600 | 96.933 | 96.460–100.375 | 1.51% | 1.86x |
| `direct_calls` | 4 | 600 | 101.056 | 100.858–104.071 | 1.24% | 3.57x |
| `direct_calls` | 8 | 600 | 162.868 | 161.023–164.761 | 0.75% | 4.43x |
| `method_calls` | 1 | 500 | 191.592 | 188.599–194.320 | 0.97% | 1.00x |
| `method_calls` | 2 | 500 | 199.968 | 198.650–278.803 | 13.95% | 1.92x |
| `method_calls` | 4 | 500 | 208.793 | 204.654–219.679 | 2.72% | 3.67x |
| `method_calls` | 8 | 500 | 289.750 | 283.833–300.362 | 2.45% | 5.29x |
| `closure_calls` | 1 | 600 | 105.442 | 104.530–106.924 | 0.95% | 1.00x |
| `closure_calls` | 2 | 600 | 117.400 | 114.432–121.137 | 2.15% | 1.80x |
| `closure_calls` | 4 | 600 | 122.294 | 119.581–129.934 | 3.40% | 3.45x |
| `closure_calls` | 8 | 600 | 181.972 | 174.887–288.260 | 20.48% | 4.64x |
| `arguments_calls` | 1 | 600 | 128.400 | 114.618–190.091 | 18.23% | 1.00x |
| `arguments_calls` | 2 | 600 | 104.241 | 102.556–106.939 | 1.50% | 2.46x |
| `arguments_calls` | 4 | 600 | 107.993 | 105.643–111.231 | 1.95% | 4.76x |
| `arguments_calls` | 8 | 600 | 165.210 | 159.906–173.865 | 2.90% | 6.22x |
| `fibonacci` | 1 | 125 | 299.602 | 298.356–303.576 | 0.55% | 1.00x |
| `fibonacci` | 2 | 125 | 302.753 | 302.025–307.249 | 0.70% | 1.98x |
| `fibonacci` | 4 | 125 | 337.097 | 317.416–342.306 | 2.81% | 3.56x |
| `fibonacci` | 8 | 125 | 422.605 | 408.759–1034.897 | 44.97% | 5.67x |

## Reading the result

Across these 10 deliberately small kernels, JSC's single-context throughput is 0.44x
the zig-js throughput by geometric mean. These kernels deliberately exercise guarded native/VM tiers that
zig-js currently implements; rows outside those documented subsets continue through general bytecode paths.
The number is a compact description of this matrix, not a claim about applications or unsupported workloads.

At 8 independent warmed contexts, JSC throughput is 0.40x zig-js by
geometric mean; scaling from the mode's own one-lane baseline is 5.31x
for zig-js and 4.83x for JSC. In the symmetric cold lifecycle, JSC
throughput is 0.38x zig-js, with 5.53x
and 4.89x scaling respectively.

zig-js's shared-realm path scales 4.42x at 8 lanes from its
own one-lane shared baseline. It has no direct JSC ratio because the public JSC embedding API exposes
isolated global contexts, not concurrent JavaScript workers sharing one object graph. Per-workload rows
matter more than any aggregate.

## Method and timed boundaries

- Both engines evaluate the exact bytes in `bench/comparison.js`. Directly compared single and independent rows use the exact invocation bytes `__benchmarkSelected(__benchmarkJobs, __benchmarkLane)`; shared mode calls the same selected function with the same jobs/lane arguments. The driver rejects unstable or cross-engine checksum mismatches.
- zig-js is built `ReleaseFast`. Direct and independent contexts explicitly enable precise GC; shared mode enables the shipping no-GIL thread configuration, which implies GC.
- Every measured zig-js context uses the process-wide thread-safe libc allocator, whose reusable infrastructure outlives timed cold contexts; cold mode still times every context-owned allocation and release. JSC uses its internal process allocator.
- Single mode evaluates the workload source, configures the context, and performs ten reduced-size warm-up calls before timing one host evaluation call per sample.
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

Raw samples: [`benchmark-comparison-2026-07-29.tsv`](benchmark-comparison-2026-07-29.tsv)
