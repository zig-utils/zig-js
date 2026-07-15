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
| zig-js | ab7b08fb468a1ad65fde12526933893c24b1f29a |
| zig-gc | 9d4af0d49be5eba5b9283d5ed135fdf02626e2ac |
| zig-regex | 5937fa7d4db0b69575c821066afd1a7da92aa019 |
| JavaScriptCore | system framework 22625.1.20.11.3 |
| Power | Now drawing from 'Battery Power' -InternalBattery-0 (id=22806627) 27%; discharging; (no estimate) present: true |

## Single-thread result

Each row runs the same number of jobs in one GC-enabled zig-js context and one warmed JSC global context.
Both runners time the exact invocation `__benchmarkSelected(__benchmarkJobs, __benchmarkLane)`.
Lower time is better; `JSC / zig-js` is JSC throughput divided by zig-js throughput. RSD is relative standard deviation.

| workload | jobs | zig-js median (ms) | zig-js min–max (ms) | zig-js RSD | JSC median (ms) | JSC min–max (ms) | JSC RSD | JSC / zig-js |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `arithmetic` | 240 | 86.923 | 85.598–89.775 | 1.54% | 358.776 | 356.933–360.176 | 0.30% | 0.24x |
| `properties` | 300 | 91.910 | 91.366–92.441 | 0.36% | 305.549 | 304.147–306.236 | 0.22% | 0.30x |
| `polymorphic_properties` | 400 | 87.212 | 86.670–87.796 | 0.44% | 215.203 | 214.311–216.080 | 0.38% | 0.41x |
| `object_churn` | 100 | 122.226 | 121.338–123.184 | 0.67% | 126.404 | 125.149–127.756 | 0.65% | 0.97x |
| `arrays` | 550 | 85.570 | 83.852–88.882 | 2.14% | 161.837 | 160.079–164.908 | 0.92% | 0.53x |
| `direct_calls` | 600 | 60.660 | 59.481–62.199 | 1.75% | 125.241 | 123.385–127.199 | 0.92% | 0.48x |
| `method_calls` | 500 | 68.459 | 66.652–69.834 | 1.63% | 149.588 | 146.921–150.508 | 0.83% | 0.46x |
| `closure_calls` | 600 | 66.742 | 66.550–67.130 | 0.28% | 204.052 | 203.267–207.915 | 0.80% | 0.33x |
| `arguments_calls` | 600 | 73.521 | 69.515–74.485 | 2.42% | 313.364 | 304.406–335.013 | 3.49% | 0.23x |
| `fibonacci` | 125 | 91.626 | 90.581–94.289 | 1.67% | 506.651 | 478.624–547.763 | 5.41% | 0.18x |

## Independent-context steady state

Both engines keep one warmed context on one persistent OS worker per lane. The timed region contains the
same semaphore dispatch, exact invocation, and completion wait. Every lane performs the full job count.
`scaling` uses the same engine and mode at one lane; cross-engine throughput is directly comparable.

| workload | lanes | jobs/lane | zig-js median (ms) | zig-js min–max (ms) | zig-js RSD | JSC median (ms) | JSC min–max (ms) | JSC RSD | JSC / zig-js | zig-js scaling | JSC scaling |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `arithmetic` | 1 | 240 | 86.113 | 85.586–86.982 | 0.54% | 356.397 | 355.070–384.291 | 2.94% | 0.24x | 1.00x | 1.00x |
| `arithmetic` | 2 | 240 | 87.753 | 87.440–88.268 | 0.36% | 368.848 | 366.224–370.509 | 0.39% | 0.24x | 1.96x | 1.93x |
| `arithmetic` | 4 | 240 | 93.119 | 92.550–94.302 | 0.74% | 405.882 | 401.595–420.843 | 1.98% | 0.23x | 3.70x | 3.51x |
| `arithmetic` | 8 | 240 | 123.189 | 116.877–170.151 | 14.64% | 597.184 | 572.228–619.012 | 2.58% | 0.21x | 5.59x | 4.77x |
| `properties` | 1 | 300 | 91.896 | 91.594–93.170 | 0.58% | 303.488 | 302.515–306.252 | 0.42% | 0.30x | 1.00x | 1.00x |
| `properties` | 2 | 300 | 93.263 | 92.612–94.419 | 0.71% | 310.107 | 308.630–311.737 | 0.36% | 0.30x | 1.97x | 1.96x |
| `properties` | 4 | 300 | 100.093 | 98.559–149.042 | 17.42% | 339.588 | 334.341–365.215 | 3.54% | 0.29x | 3.67x | 3.57x |
| `properties` | 8 | 300 | 131.300 | 126.341–137.003 | 2.48% | 507.696 | 497.991–554.307 | 3.76% | 0.26x | 5.60x | 4.78x |
| `polymorphic_properties` | 1 | 400 | 86.173 | 85.859–87.275 | 0.60% | 214.495 | 213.255–215.751 | 0.46% | 0.40x | 1.00x | 1.00x |
| `polymorphic_properties` | 2 | 400 | 87.713 | 87.021–89.495 | 0.90% | 217.567 | 215.878–244.023 | 4.62% | 0.40x | 1.96x | 1.97x |
| `polymorphic_properties` | 4 | 400 | 121.983 | 100.126–127.148 | 9.83% | 293.757 | 241.750–367.751 | 14.24% | 0.42x | 2.83x | 2.92x |
| `polymorphic_properties` | 8 | 400 | 141.809 | 135.518–151.015 | 3.36% | 357.007 | 348.318–444.463 | 9.14% | 0.40x | 4.86x | 4.81x |
| `object_churn` | 1 | 100 | 121.467 | 119.415–123.566 | 1.33% | 128.195 | 126.036–129.559 | 1.01% | 0.95x | 1.00x | 1.00x |
| `object_churn` | 2 | 100 | 142.898 | 140.090–147.160 | 1.64% | 130.704 | 129.612–137.691 | 2.11% | 1.09x | 1.70x | 1.96x |
| `object_churn` | 4 | 100 | 213.292 | 207.321–230.620 | 4.05% | 150.790 | 145.972–214.249 | 15.16% | 1.41x | 2.28x | 3.40x |
| `object_churn` | 8 | 100 | 401.792 | 387.447–437.114 | 4.24% | 214.719 | 205.378–258.938 | 8.36% | 1.87x | 2.42x | 4.78x |
| `arrays` | 1 | 550 | 84.275 | 83.634–85.066 | 0.53% | 164.022 | 162.519–225.830 | 13.69% | 0.51x | 1.00x | 1.00x |
| `arrays` | 2 | 550 | 86.646 | 85.391–88.307 | 1.24% | 165.142 | 163.311–180.662 | 3.68% | 0.52x | 1.95x | 1.99x |
| `arrays` | 4 | 550 | 97.982 | 93.944–106.284 | 4.06% | 182.414 | 180.094–193.309 | 2.53% | 0.54x | 3.44x | 3.60x |
| `arrays` | 8 | 550 | 147.565 | 140.897–150.249 | 2.52% | 266.507 | 263.947–272.657 | 1.13% | 0.55x | 4.57x | 4.92x |
| `direct_calls` | 1 | 600 | 60.452 | 60.217–61.283 | 0.65% | 125.482 | 124.754–163.231 | 10.87% | 0.48x | 1.00x | 1.00x |
| `direct_calls` | 2 | 600 | 62.276 | 61.388–62.643 | 0.69% | 127.584 | 125.835–129.177 | 0.91% | 0.49x | 1.94x | 1.97x |
| `direct_calls` | 4 | 600 | 92.180 | 88.753–93.265 | 1.76% | 153.373 | 150.659–165.753 | 3.42% | 0.60x | 2.62x | 3.27x |
| `direct_calls` | 8 | 600 | 136.403 | 131.832–198.809 | 16.72% | 226.596 | 223.055–280.894 | 10.41% | 0.60x | 3.55x | 4.43x |
| `method_calls` | 1 | 500 | 67.504 | 66.626–102.287 | 18.17% | 148.805 | 147.848–149.442 | 0.37% | 0.45x | 1.00x | 1.00x |
| `method_calls` | 2 | 500 | 66.946 | 66.218–67.367 | 0.62% | 149.774 | 148.268–161.634 | 3.03% | 0.45x | 2.02x | 1.99x |
| `method_calls` | 4 | 500 | 85.927 | 81.996–96.252 | 5.33% | 169.654 | 166.409–174.694 | 1.52% | 0.51x | 3.14x | 3.51x |
| `method_calls` | 8 | 500 | 99.564 | 95.149–104.135 | 3.48% | 247.177 | 238.691–250.919 | 1.57% | 0.40x | 5.42x | 4.82x |
| `closure_calls` | 1 | 600 | 68.477 | 67.155–69.304 | 1.34% | 212.279 | 195.396–321.939 | 19.05% | 0.32x | 1.00x | 1.00x |
| `closure_calls` | 2 | 600 | 65.920 | 65.790–66.197 | 0.25% | 197.296 | 195.792–199.354 | 0.58% | 0.33x | 2.08x | 2.15x |
| `closure_calls` | 4 | 600 | 75.950 | 68.136–111.518 | 18.54% | 243.598 | 220.979–266.164 | 5.49% | 0.31x | 3.61x | 3.49x |
| `closure_calls` | 8 | 600 | 100.285 | 97.455–103.111 | 2.42% | 362.967 | 348.875–376.867 | 2.71% | 0.28x | 5.46x | 4.68x |
| `arguments_calls` | 1 | 600 | 69.273 | 68.620–98.113 | 14.63% | 316.393 | 304.102–324.130 | 1.99% | 0.22x | 1.00x | 1.00x |
| `arguments_calls` | 2 | 600 | 71.411 | 70.914–76.637 | 3.24% | 335.200 | 318.646–446.779 | 13.13% | 0.21x | 1.94x | 1.89x |
| `arguments_calls` | 4 | 600 | 80.072 | 75.756–87.593 | 5.34% | 344.107 | 335.834–487.454 | 14.59% | 0.23x | 3.46x | 3.68x |
| `arguments_calls` | 8 | 600 | 107.386 | 102.858–114.908 | 4.36% | 560.438 | 530.825–923.624 | 22.40% | 0.19x | 5.16x | 4.52x |
| `fibonacci` | 1 | 125 | 91.908 | 89.834–93.542 | 1.30% | 481.864 | 480.471–486.835 | 0.55% | 0.19x | 1.00x | 1.00x |
| `fibonacci` | 2 | 125 | 95.640 | 87.989–177.531 | 29.90% | 505.510 | 487.158–581.298 | 6.22% | 0.19x | 1.92x | 1.91x |
| `fibonacci` | 4 | 125 | 101.676 | 99.102–109.091 | 3.68% | 534.741 | 526.811–610.209 | 5.34% | 0.19x | 3.62x | 3.60x |
| `fibonacci` | 8 | 125 | 139.115 | 132.880–197.509 | 15.30% | 794.220 | 711.040–910.237 | 8.14% | 0.18x | 5.29x | 4.85x |

## Independent-context cold lifecycle

Neither engine warms these contexts. The timer covers OS-thread creation, context creation, workload-source
evaluation and configuration, the exact invocation, context destruction, and OS-thread join on both sides.
`scaling` uses the same engine and cold lifecycle at one lane.

| workload | lanes | jobs/lane | zig-js median (ms) | zig-js min–max (ms) | zig-js RSD | JSC median (ms) | JSC min–max (ms) | JSC RSD | JSC / zig-js | zig-js scaling | JSC scaling |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `arithmetic` | 1 | 240 | 87.838 | 87.471–88.361 | 0.35% | 358.381 | 356.126–359.903 | 0.33% | 0.25x | 1.00x | 1.00x |
| `arithmetic` | 2 | 240 | 90.365 | 89.697–117.239 | 10.83% | 369.206 | 368.044–375.865 | 0.77% | 0.24x | 1.94x | 1.94x |
| `arithmetic` | 4 | 240 | 94.949 | 94.024–96.113 | 0.82% | 494.164 | 427.632–541.929 | 8.49% | 0.19x | 3.70x | 2.90x |
| `arithmetic` | 8 | 240 | 124.329 | 119.235–175.635 | 15.35% | 594.531 | 582.625–618.526 | 2.12% | 0.21x | 5.65x | 4.82x |
| `properties` | 1 | 300 | 92.947 | 92.430–93.944 | 0.58% | 307.989 | 306.570–329.436 | 2.68% | 0.30x | 1.00x | 1.00x |
| `properties` | 2 | 300 | 95.850 | 94.778–97.785 | 1.08% | 313.343 | 311.439–316.730 | 0.54% | 0.31x | 1.94x | 1.97x |
| `properties` | 4 | 300 | 104.008 | 100.081–106.128 | 2.32% | 347.564 | 344.858–351.175 | 0.62% | 0.30x | 3.57x | 3.54x |
| `properties` | 8 | 300 | 131.581 | 127.960–137.159 | 2.39% | 516.168 | 507.287–530.523 | 1.60% | 0.25x | 5.65x | 4.77x |
| `polymorphic_properties` | 1 | 400 | 87.743 | 87.359–88.930 | 0.59% | 213.738 | 213.491–252.456 | 6.61% | 0.41x | 1.00x | 1.00x |
| `polymorphic_properties` | 2 | 400 | 89.896 | 89.043–91.750 | 1.15% | 218.207 | 216.624–219.561 | 0.48% | 0.41x | 1.95x | 1.96x |
| `polymorphic_properties` | 4 | 400 | 100.162 | 98.162–102.762 | 1.53% | 251.569 | 250.917–254.808 | 0.62% | 0.40x | 3.50x | 3.40x |
| `polymorphic_properties` | 8 | 400 | 145.759 | 141.923–158.226 | 3.73% | 361.257 | 353.969–375.731 | 2.46% | 0.40x | 4.82x | 4.73x |
| `object_churn` | 1 | 100 | 124.490 | 122.246–125.728 | 1.20% | 128.672 | 126.690–131.115 | 1.06% | 0.97x | 1.00x | 1.00x |
| `object_churn` | 2 | 100 | 147.593 | 144.609–151.262 | 1.68% | 139.761 | 137.303–185.582 | 12.11% | 1.06x | 1.69x | 1.84x |
| `object_churn` | 4 | 100 | 217.513 | 209.075–220.943 | 2.01% | 147.384 | 141.254–153.558 | 2.87% | 1.48x | 2.29x | 3.49x |
| `object_churn` | 8 | 100 | 398.855 | 391.528–407.847 | 1.44% | 201.659 | 196.281–227.236 | 5.30% | 1.98x | 2.50x | 5.10x |
| `arrays` | 1 | 550 | 82.710 | 82.072–85.429 | 1.41% | 163.164 | 161.348–182.943 | 4.66% | 0.51x | 1.00x | 1.00x |
| `arrays` | 2 | 550 | 85.827 | 84.891–88.857 | 1.52% | 164.792 | 163.848–165.617 | 0.41% | 0.52x | 1.93x | 1.98x |
| `arrays` | 4 | 550 | 98.040 | 93.096–116.018 | 7.64% | 187.362 | 181.640–196.019 | 2.56% | 0.52x | 3.37x | 3.48x |
| `arrays` | 8 | 550 | 145.328 | 138.795–156.595 | 3.88% | 291.270 | 285.262–322.932 | 4.33% | 0.50x | 4.55x | 4.48x |
| `direct_calls` | 1 | 600 | 61.541 | 60.926–63.331 | 1.26% | 127.203 | 125.634–130.319 | 1.27% | 0.48x | 1.00x | 1.00x |
| `direct_calls` | 2 | 600 | 63.946 | 63.402–66.139 | 1.54% | 130.535 | 128.732–130.851 | 0.65% | 0.49x | 1.92x | 1.95x |
| `direct_calls` | 4 | 600 | 87.917 | 83.216–94.491 | 4.28% | 158.550 | 157.155–167.563 | 2.33% | 0.55x | 2.80x | 3.21x |
| `direct_calls` | 8 | 600 | 103.159 | 97.215–106.048 | 3.08% | 225.376 | 217.955–241.425 | 3.60% | 0.46x | 4.77x | 4.52x |
| `method_calls` | 1 | 500 | 69.552 | 68.543–112.487 | 21.42% | 150.359 | 148.497–152.061 | 0.83% | 0.46x | 1.00x | 1.00x |
| `method_calls` | 2 | 500 | 71.743 | 69.802–97.376 | 13.09% | 151.696 | 150.410–152.410 | 0.42% | 0.47x | 1.94x | 1.98x |
| `method_calls` | 4 | 500 | 80.360 | 74.205–86.497 | 4.79% | 174.246 | 168.139–234.697 | 12.79% | 0.46x | 3.46x | 3.45x |
| `method_calls` | 8 | 500 | 117.874 | 110.209–124.130 | 3.75% | 262.686 | 250.120–268.124 | 2.40% | 0.45x | 4.72x | 4.58x |
| `closure_calls` | 1 | 600 | 65.269 | 64.729–66.431 | 0.89% | 194.119 | 193.085–197.905 | 1.07% | 0.34x | 1.00x | 1.00x |
| `closure_calls` | 2 | 600 | 66.674 | 66.414–72.134 | 3.05% | 199.867 | 197.518–202.198 | 0.94% | 0.33x | 1.96x | 1.94x |
| `closure_calls` | 4 | 600 | 80.925 | 77.392–92.987 | 6.22% | 250.681 | 237.077–308.741 | 9.10% | 0.32x | 3.23x | 3.10x |
| `closure_calls` | 8 | 600 | 94.454 | 92.008–100.531 | 3.15% | 351.526 | 331.170–376.203 | 4.57% | 0.27x | 5.53x | 4.42x |
| `arguments_calls` | 1 | 600 | 73.467 | 72.631–76.443 | 2.14% | 320.316 | 314.547–345.147 | 3.30% | 0.23x | 1.00x | 1.00x |
| `arguments_calls` | 2 | 600 | 77.056 | 74.544–92.355 | 8.22% | 375.413 | 327.546–456.384 | 13.03% | 0.21x | 1.91x | 1.71x |
| `arguments_calls` | 4 | 600 | 80.731 | 76.335–82.768 | 2.82% | 381.024 | 349.543–418.709 | 6.68% | 0.21x | 3.64x | 3.36x |
| `arguments_calls` | 8 | 600 | 120.453 | 116.242–171.138 | 15.11% | 578.995 | 549.788–703.410 | 9.13% | 0.21x | 4.88x | 4.43x |
| `fibonacci` | 1 | 125 | 93.636 | 91.748–106.086 | 5.56% | 491.265 | 483.426–516.658 | 2.31% | 0.19x | 1.00x | 1.00x |
| `fibonacci` | 2 | 125 | 95.575 | 92.001–99.100 | 2.75% | 498.952 | 490.453–528.302 | 2.76% | 0.19x | 1.96x | 1.97x |
| `fibonacci` | 4 | 125 | 115.921 | 105.297–127.964 | 7.13% | 564.747 | 531.811–607.569 | 4.79% | 0.21x | 3.23x | 3.48x |
| `fibonacci` | 8 | 125 | 145.924 | 142.080–156.817 | 4.59% | 798.133 | 761.905–890.392 | 5.01% | 0.18x | 5.13x | 4.92x |

## zig-js shared-realm scaling

This is zig-js's distinct no-GIL shared-object-graph model, which JSC's public C API does not provide.
The timed region creates JavaScript `Thread`s, performs the work, and joins them. Scaling uses the same
shared-realm path at one lane, so thread lifecycle overhead is present in every row.

| workload | lanes | jobs/lane | median (ms) | min–max (ms) | RSD | scaling |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `arithmetic` | 1 | 240 | 86.047 | 85.897–86.564 | 0.33% | 1.00x |
| `arithmetic` | 2 | 240 | 88.006 | 87.456–88.457 | 0.40% | 1.96x |
| `arithmetic` | 4 | 240 | 94.777 | 94.356–96.585 | 0.94% | 3.63x |
| `arithmetic` | 8 | 240 | 110.691 | 108.760–113.148 | 1.35% | 6.22x |
| `properties` | 1 | 300 | 132.315 | 130.945–134.421 | 0.81% | 1.00x |
| `properties` | 2 | 300 | 134.184 | 133.736–135.060 | 0.37% | 1.97x |
| `properties` | 4 | 300 | 147.257 | 145.859–150.128 | 1.01% | 3.59x |
| `properties` | 8 | 300 | 190.547 | 183.692–196.402 | 2.16% | 5.56x |
| `polymorphic_properties` | 1 | 400 | 542.462 | 541.227–544.006 | 0.20% | 1.00x |
| `polymorphic_properties` | 2 | 400 | 550.387 | 547.796–555.090 | 0.49% | 1.97x |
| `polymorphic_properties` | 4 | 400 | 595.660 | 589.856–628.458 | 2.65% | 3.64x |
| `polymorphic_properties` | 8 | 400 | 807.831 | 772.579–863.314 | 4.32% | 5.37x |
| `object_churn` | 1 | 100 | 206.281 | 204.290–276.178 | 12.20% | 1.00x |
| `object_churn` | 2 | 100 | 396.955 | 292.887–552.103 | 18.81% | 1.04x |
| `object_churn` | 4 | 100 | 1436.164 | 716.702–2141.570 | 35.80% | 0.57x |
| `object_churn` | 8 | 100 | 6089.801 | 2139.530–7232.786 | 29.38% | 0.27x |
| `arrays` | 1 | 550 | 86.880 | 85.630–88.078 | 0.85% | 1.00x |
| `arrays` | 2 | 550 | 93.242 | 92.682–93.511 | 0.36% | 1.86x |
| `arrays` | 4 | 550 | 117.836 | 113.341–125.557 | 3.60% | 2.95x |
| `arrays` | 8 | 550 | 259.905 | 238.809–273.095 | 6.47% | 2.67x |
| `direct_calls` | 1 | 600 | 60.255 | 59.779–60.588 | 0.56% | 1.00x |
| `direct_calls` | 2 | 600 | 67.992 | 66.121–71.111 | 2.43% | 1.77x |
| `direct_calls` | 4 | 600 | 91.908 | 87.035–103.843 | 6.86% | 2.62x |
| `direct_calls` | 8 | 600 | 99.299 | 93.174–102.700 | 2.97% | 4.85x |
| `method_calls` | 1 | 500 | 126.194 | 125.200–126.680 | 0.45% | 1.00x |
| `method_calls` | 2 | 500 | 126.829 | 125.760–127.480 | 0.53% | 1.99x |
| `method_calls` | 4 | 500 | 141.739 | 138.438–146.404 | 1.73% | 3.56x |
| `method_calls` | 8 | 500 | 213.843 | 209.082–217.012 | 1.34% | 4.72x |
| `closure_calls` | 1 | 600 | 65.843 | 64.653–66.687 | 1.02% | 1.00x |
| `closure_calls` | 2 | 600 | 65.766 | 65.423–65.886 | 0.30% | 2.00x |
| `closure_calls` | 4 | 600 | 77.287 | 67.404–81.270 | 6.97% | 3.41x |
| `closure_calls` | 8 | 600 | 111.918 | 99.145–155.683 | 17.01% | 4.71x |
| `arguments_calls` | 1 | 600 | 70.402 | 69.408–74.561 | 2.69% | 1.00x |
| `arguments_calls` | 2 | 600 | 83.137 | 70.303–113.487 | 17.91% | 1.69x |
| `arguments_calls` | 4 | 600 | 87.962 | 86.585–92.017 | 2.03% | 3.20x |
| `arguments_calls` | 8 | 600 | 112.753 | 110.550–118.914 | 3.02% | 5.00x |
| `fibonacci` | 1 | 125 | 273.249 | 255.223–311.279 | 6.82% | 1.00x |
| `fibonacci` | 2 | 125 | 276.057 | 264.821–280.158 | 2.03% | 1.98x |
| `fibonacci` | 4 | 125 | 295.207 | 279.663–341.533 | 7.08% | 3.70x |
| `fibonacci` | 8 | 125 | 455.509 | 419.454–581.955 | 12.51% | 4.80x |

## Reading the result

Across these 10 deliberately small kernels, JSC's single-context throughput is 0.37x
the zig-js throughput by geometric mean. These kernels deliberately exercise guarded native/VM tiers that
zig-js currently implements; rows outside those documented subsets continue through general bytecode paths.
The number is a compact description of this matrix, not a claim about applications or unsupported workloads.

At 8 independent warmed contexts, JSC throughput is 0.37x zig-js by
geometric mean; scaling from the mode's own one-lane baseline is 4.66x
for zig-js and 4.73x for JSC. In the symmetric cold lifecycle, JSC
throughput is 0.37x zig-js, with 4.72x
and 4.67x scaling respectively.

zig-js's shared-realm path scales 3.58x at 8 lanes from its
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

Raw samples: [`benchmark-comparison-2026-07-15.tsv`](benchmark-comparison-2026-07-15.tsv)
