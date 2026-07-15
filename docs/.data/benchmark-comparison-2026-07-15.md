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
| zig-js | 0a74f7d1a35a9504d82d7ca846ff7a05c53f6740 |
| zig-gc | 9d4af0d49be5eba5b9283d5ed135fdf02626e2ac |
| zig-regex | 50764b0352e73a434278de38825dbb55464f1cf6 |
| JavaScriptCore | system framework 22625.1.20.11.3 |
| Power | Now drawing from 'AC Power' -InternalBattery-0 (id=22806627) 100%; charged; 0:00 remaining present: true |

## Single-thread result

Each row runs the same number of jobs in one GC-enabled zig-js context and one warmed JSC global context.
Both runners time the exact invocation `__benchmarkSelected(__benchmarkJobs, __benchmarkLane)`.
Lower time is better; `JSC / zig-js` is JSC throughput divided by zig-js throughput. RSD is relative standard deviation.

| workload | jobs | zig-js median (ms) | zig-js min–max (ms) | zig-js RSD | JSC median (ms) | JSC min–max (ms) | JSC RSD | JSC / zig-js |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `arithmetic` | 240 | 82.936 | 82.877–83.168 | 0.12% | 353.899 | 352.114–414.029 | 6.31% | 0.23x |
| `properties` | 300 | 87.534 | 87.326–107.170 | 8.09% | 293.427 | 292.296–294.970 | 0.35% | 0.30x |
| `polymorphic_properties` | 400 | 82.027 | 81.896–84.143 | 1.05% | 204.107 | 203.926–206.799 | 0.50% | 0.40x |
| `object_churn` | 100 | 80.380 | 80.001–85.020 | 2.24% | 117.343 | 117.168–139.905 | 6.98% | 0.69x |
| `arrays` | 550 | 79.124 | 78.478–109.990 | 13.87% | 150.564 | 149.371–151.834 | 0.53% | 0.53x |
| `direct_calls` | 600 | 56.185 | 55.891–58.030 | 1.37% | 116.732 | 114.646–120.419 | 1.59% | 0.48x |
| `method_calls` | 500 | 63.899 | 61.466–70.246 | 4.58% | 137.733 | 137.462–169.330 | 8.28% | 0.46x |
| `closure_calls` | 600 | 77.444 | 62.834–80.545 | 10.27% | 187.510 | 187.069–190.234 | 0.57% | 0.41x |
| `arguments_calls` | 600 | 67.331 | 67.050–90.662 | 12.09% | 296.124 | 295.700–299.277 | 0.43% | 0.23x |
| `fibonacci` | 125 | 85.294 | 82.703–109.221 | 10.44% | 448.825 | 447.654–463.289 | 1.25% | 0.19x |

## Independent-context steady state

Both engines keep one warmed context on one persistent OS worker per lane. The timed region contains the
same semaphore dispatch, exact invocation, and completion wait. Every lane performs the full job count.
`scaling` uses the same engine and mode at one lane; cross-engine throughput is directly comparable.

| workload | lanes | jobs/lane | zig-js median (ms) | zig-js min–max (ms) | zig-js RSD | JSC median (ms) | JSC min–max (ms) | JSC RSD | JSC / zig-js | zig-js scaling | JSC scaling |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `arithmetic` | 1 | 240 | 83.008 | 82.930–84.892 | 0.87% | 350.327 | 349.220–382.462 | 3.45% | 0.24x | 1.00x | 1.00x |
| `arithmetic` | 2 | 240 | 84.971 | 84.745–85.768 | 0.46% | 366.543 | 362.158–368.907 | 0.68% | 0.23x | 1.95x | 1.91x |
| `arithmetic` | 4 | 240 | 86.297 | 86.167–97.131 | 4.61% | 384.800 | 378.853–386.804 | 0.85% | 0.22x | 3.85x | 3.64x |
| `arithmetic` | 8 | 240 | 106.720 | 104.727–110.467 | 1.79% | 550.496 | 536.417–557.274 | 1.21% | 0.19x | 6.22x | 5.09x |
| `properties` | 1 | 300 | 87.510 | 87.466–89.690 | 0.94% | 292.160 | 291.452–294.546 | 0.36% | 0.30x | 1.00x | 1.00x |
| `properties` | 2 | 300 | 89.757 | 89.427–90.657 | 0.50% | 299.664 | 298.525–300.986 | 0.34% | 0.30x | 1.95x | 1.95x |
| `properties` | 4 | 300 | 91.119 | 90.948–102.879 | 4.73% | 320.457 | 316.638–323.166 | 0.65% | 0.28x | 3.84x | 3.65x |
| `properties` | 8 | 300 | 119.083 | 118.656–128.324 | 2.94% | 462.222 | 455.812–475.214 | 1.34% | 0.26x | 5.88x | 5.06x |
| `polymorphic_properties` | 1 | 400 | 82.185 | 81.997–84.619 | 1.14% | 204.029 | 203.314–205.646 | 0.44% | 0.40x | 1.00x | 1.00x |
| `polymorphic_properties` | 2 | 400 | 83.616 | 83.546–84.728 | 0.63% | 208.038 | 207.599–210.838 | 0.58% | 0.40x | 1.97x | 1.96x |
| `polymorphic_properties` | 4 | 400 | 85.090 | 84.945–97.777 | 5.64% | 227.197 | 223.396–244.246 | 3.15% | 0.37x | 3.86x | 3.59x |
| `polymorphic_properties` | 8 | 400 | 129.555 | 127.320–137.102 | 2.69% | 336.130 | 325.083–338.935 | 1.56% | 0.39x | 5.07x | 4.86x |
| `object_churn` | 1 | 100 | 80.296 | 79.838–85.921 | 2.77% | 118.308 | 117.266–122.415 | 1.58% | 0.68x | 1.00x | 1.00x |
| `object_churn` | 2 | 100 | 83.120 | 82.817–86.823 | 1.76% | 122.179 | 121.492–123.208 | 0.50% | 0.68x | 1.93x | 1.94x |
| `object_churn` | 4 | 100 | 113.644 | 104.378–127.171 | 7.33% | 127.398 | 124.365–145.672 | 5.69% | 0.89x | 2.83x | 3.71x |
| `object_churn` | 8 | 100 | 170.179 | 167.510–184.652 | 3.44% | 187.303 | 181.810–193.810 | 2.16% | 0.91x | 3.77x | 5.05x |
| `arrays` | 1 | 550 | 80.782 | 79.054–82.262 | 1.63% | 150.795 | 149.173–158.972 | 3.07% | 0.54x | 1.00x | 1.00x |
| `arrays` | 2 | 550 | 82.471 | 81.489–84.912 | 1.60% | 153.768 | 152.257–155.528 | 0.79% | 0.54x | 1.96x | 1.96x |
| `arrays` | 4 | 550 | 85.265 | 84.328–120.199 | 14.67% | 156.363 | 155.573–167.187 | 2.76% | 0.55x | 3.79x | 3.86x |
| `arrays` | 8 | 550 | 128.029 | 114.956–142.073 | 8.30% | 233.891 | 226.109–242.658 | 2.41% | 0.55x | 5.05x | 5.16x |
| `direct_calls` | 1 | 600 | 56.122 | 56.024–57.669 | 1.14% | 116.445 | 114.715–119.454 | 1.46% | 0.48x | 1.00x | 1.00x |
| `direct_calls` | 2 | 600 | 57.341 | 57.211–85.947 | 17.24% | 118.539 | 118.108–121.461 | 0.98% | 0.48x | 1.96x | 1.96x |
| `direct_calls` | 4 | 600 | 58.729 | 58.573–72.922 | 8.66% | 121.829 | 121.043–125.783 | 1.33% | 0.48x | 3.82x | 3.82x |
| `direct_calls` | 8 | 600 | 77.858 | 74.917–83.422 | 3.62% | 184.310 | 181.067–190.851 | 1.84% | 0.42x | 5.77x | 5.05x |
| `method_calls` | 1 | 500 | 62.958 | 62.158–64.461 | 1.39% | 137.215 | 137.027–140.832 | 0.99% | 0.46x | 1.00x | 1.00x |
| `method_calls` | 2 | 500 | 62.968 | 62.805–64.297 | 1.05% | 140.006 | 139.851–142.691 | 0.75% | 0.45x | 2.00x | 1.96x |
| `method_calls` | 4 | 500 | 65.281 | 65.016–66.533 | 0.94% | 143.506 | 143.341–146.749 | 0.86% | 0.45x | 3.86x | 3.82x |
| `method_calls` | 8 | 500 | 88.482 | 84.511–92.853 | 3.93% | 205.107 | 201.587–215.451 | 2.29% | 0.43x | 5.69x | 5.35x |
| `closure_calls` | 1 | 600 | 62.086 | 61.893–63.555 | 1.04% | 185.957 | 185.779–190.771 | 0.99% | 0.33x | 1.00x | 1.00x |
| `closure_calls` | 2 | 600 | 63.046 | 62.884–64.653 | 1.18% | 191.582 | 190.715–194.999 | 0.75% | 0.33x | 1.97x | 1.94x |
| `closure_calls` | 4 | 600 | 64.562 | 64.406–68.353 | 2.68% | 198.835 | 197.948–202.524 | 0.80% | 0.32x | 3.85x | 3.74x |
| `closure_calls` | 8 | 600 | 85.020 | 80.562–90.419 | 4.22% | 295.237 | 283.014–299.003 | 2.31% | 0.29x | 5.84x | 5.04x |
| `arguments_calls` | 1 | 600 | 67.640 | 67.439–69.213 | 1.09% | 295.845 | 295.078–297.727 | 0.29% | 0.23x | 1.00x | 1.00x |
| `arguments_calls` | 2 | 600 | 68.562 | 68.405–71.343 | 1.92% | 304.858 | 304.496–306.208 | 0.20% | 0.22x | 1.97x | 1.94x |
| `arguments_calls` | 4 | 600 | 70.641 | 70.446–77.560 | 3.87% | 316.787 | 314.993–317.369 | 0.28% | 0.22x | 3.83x | 3.74x |
| `arguments_calls` | 8 | 600 | 102.239 | 95.959–114.990 | 5.92% | 459.981 | 454.435–468.030 | 1.13% | 0.22x | 5.29x | 5.15x |
| `fibonacci` | 1 | 125 | 82.557 | 82.332–84.432 | 1.09% | 448.808 | 447.954–457.220 | 0.72% | 0.18x | 1.00x | 1.00x |
| `fibonacci` | 2 | 125 | 86.732 | 86.233–87.649 | 0.65% | 469.347 | 465.402–471.393 | 0.39% | 0.18x | 1.90x | 1.91x |
| `fibonacci` | 4 | 125 | 86.731 | 86.102–91.012 | 1.94% | 470.958 | 469.694–647.077 | 13.23% | 0.18x | 3.81x | 3.81x |
| `fibonacci` | 8 | 125 | 116.174 | 113.577–122.676 | 2.58% | 640.952 | 631.962–653.282 | 1.09% | 0.18x | 5.69x | 5.60x |

## Independent-context cold lifecycle

Neither engine warms these contexts. The timer covers OS-thread creation, context creation, workload-source
evaluation and configuration, the exact invocation, context destruction, and OS-thread join on both sides.
`scaling` uses the same engine and cold lifecycle at one lane.

| workload | lanes | jobs/lane | zig-js median (ms) | zig-js min–max (ms) | zig-js RSD | JSC median (ms) | JSC min–max (ms) | JSC RSD | JSC / zig-js | zig-js scaling | JSC scaling |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `arithmetic` | 1 | 240 | 84.363 | 84.209–86.290 | 1.03% | 354.480 | 350.727–361.898 | 1.25% | 0.24x | 1.00x | 1.00x |
| `arithmetic` | 2 | 240 | 86.594 | 86.456–87.366 | 0.40% | 365.343 | 361.870–372.969 | 1.04% | 0.24x | 1.95x | 1.94x |
| `arithmetic` | 4 | 240 | 88.196 | 87.949–96.941 | 3.97% | 393.169 | 380.040–407.560 | 2.33% | 0.22x | 3.83x | 3.61x |
| `arithmetic` | 8 | 240 | 110.684 | 106.437–115.330 | 2.73% | 555.315 | 548.608–568.852 | 1.37% | 0.20x | 6.10x | 5.11x |
| `properties` | 1 | 300 | 88.621 | 88.333–90.700 | 1.14% | 293.476 | 293.199–300.870 | 0.95% | 0.30x | 1.00x | 1.00x |
| `properties` | 2 | 300 | 91.050 | 90.877–92.234 | 0.55% | 300.722 | 300.325–305.752 | 0.64% | 0.30x | 1.95x | 1.95x |
| `properties` | 4 | 300 | 92.568 | 92.329–133.397 | 15.37% | 327.938 | 323.354–342.999 | 2.04% | 0.28x | 3.83x | 3.58x |
| `properties` | 8 | 300 | 120.913 | 118.737–124.898 | 2.05% | 474.494 | 468.221–486.781 | 1.32% | 0.25x | 5.86x | 4.95x |
| `polymorphic_properties` | 1 | 400 | 82.662 | 82.404–84.539 | 1.12% | 204.586 | 204.463–209.057 | 0.82% | 0.40x | 1.00x | 1.00x |
| `polymorphic_properties` | 2 | 400 | 84.952 | 84.831–117.673 | 13.76% | 209.464 | 208.837–212.886 | 0.67% | 0.41x | 1.95x | 1.95x |
| `polymorphic_properties` | 4 | 400 | 87.555 | 86.331–98.134 | 5.62% | 234.508 | 227.636–250.262 | 3.33% | 0.37x | 3.78x | 3.49x |
| `polymorphic_properties` | 8 | 400 | 132.418 | 122.768–147.346 | 5.91% | 343.824 | 332.155–354.642 | 2.46% | 0.39x | 4.99x | 4.76x |
| `object_churn` | 1 | 100 | 82.903 | 82.792–85.857 | 1.67% | 119.362 | 118.322–122.903 | 1.30% | 0.69x | 1.00x | 1.00x |
| `object_churn` | 2 | 100 | 87.084 | 86.645–90.114 | 1.49% | 123.081 | 122.930–126.376 | 0.99% | 0.71x | 1.90x | 1.94x |
| `object_churn` | 4 | 100 | 106.125 | 104.543–115.918 | 3.98% | 128.605 | 126.531–158.021 | 9.63% | 0.83x | 3.12x | 3.71x |
| `object_churn` | 8 | 100 | 177.256 | 171.257–190.570 | 3.77% | 189.788 | 186.780–198.157 | 2.00% | 0.93x | 3.74x | 5.03x |
| `arrays` | 1 | 550 | 77.896 | 77.272–82.070 | 2.37% | 150.801 | 149.421–152.976 | 0.80% | 0.52x | 1.00x | 1.00x |
| `arrays` | 2 | 550 | 80.971 | 80.312–85.321 | 2.31% | 153.955 | 152.927–156.088 | 0.69% | 0.53x | 1.92x | 1.96x |
| `arrays` | 4 | 550 | 83.504 | 82.847–88.556 | 2.84% | 157.596 | 156.593–161.359 | 1.03% | 0.53x | 3.73x | 3.83x |
| `arrays` | 8 | 550 | 119.292 | 114.573–134.238 | 5.39% | 239.047 | 232.823–244.761 | 1.87% | 0.50x | 5.22x | 5.05x |
| `direct_calls` | 1 | 600 | 57.352 | 56.848–68.444 | 7.08% | 118.058 | 117.200–119.855 | 1.02% | 0.49x | 1.00x | 1.00x |
| `direct_calls` | 2 | 600 | 59.881 | 58.406–60.617 | 1.57% | 120.212 | 119.639–125.549 | 1.73% | 0.50x | 1.92x | 1.96x |
| `direct_calls` | 4 | 600 | 70.442 | 66.670–73.947 | 3.55% | 122.959 | 121.913–126.578 | 1.26% | 0.57x | 3.26x | 3.84x |
| `direct_calls` | 8 | 600 | 82.875 | 78.068–92.445 | 5.54% | 188.810 | 183.745–197.107 | 2.98% | 0.44x | 5.54x | 5.00x |
| `method_calls` | 1 | 500 | 62.457 | 61.922–64.616 | 1.49% | 139.626 | 138.163–141.934 | 0.83% | 0.45x | 1.00x | 1.00x |
| `method_calls` | 2 | 500 | 64.589 | 64.328–67.055 | 1.45% | 141.122 | 140.717–145.957 | 1.32% | 0.46x | 1.93x | 1.98x |
| `method_calls` | 4 | 500 | 66.633 | 65.557–71.751 | 3.37% | 145.245 | 144.914–179.411 | 8.46% | 0.46x | 3.75x | 3.85x |
| `method_calls` | 8 | 500 | 100.765 | 97.547–110.080 | 4.35% | 211.008 | 209.565–220.558 | 2.05% | 0.48x | 4.96x | 5.29x |
| `closure_calls` | 1 | 600 | 62.699 | 62.458–71.531 | 5.18% | 188.191 | 187.650–191.622 | 0.72% | 0.33x | 1.00x | 1.00x |
| `closure_calls` | 2 | 600 | 64.409 | 64.319–67.114 | 1.57% | 195.182 | 192.693–233.934 | 7.47% | 0.33x | 1.95x | 1.93x |
| `closure_calls` | 4 | 600 | 66.020 | 65.743–69.246 | 1.88% | 203.008 | 200.346–211.191 | 1.94% | 0.33x | 3.80x | 3.71x |
| `closure_calls` | 8 | 600 | 88.862 | 83.750–90.498 | 3.10% | 303.259 | 293.062–321.654 | 3.33% | 0.29x | 5.64x | 4.96x |
| `arguments_calls` | 1 | 600 | 73.046 | 68.019–79.493 | 5.46% | 297.656 | 296.392–302.731 | 0.78% | 0.25x | 1.00x | 1.00x |
| `arguments_calls` | 2 | 600 | 70.294 | 69.784–72.020 | 1.31% | 306.327 | 304.697–312.215 | 0.80% | 0.23x | 2.08x | 1.94x |
| `arguments_calls` | 4 | 600 | 71.485 | 71.272–83.357 | 6.10% | 318.249 | 316.179–322.534 | 0.62% | 0.22x | 4.09x | 3.74x |
| `arguments_calls` | 8 | 600 | 108.844 | 99.837–113.355 | 4.76% | 469.229 | 462.903–483.195 | 1.34% | 0.23x | 5.37x | 5.07x |
| `fibonacci` | 1 | 125 | 84.785 | 83.243–86.650 | 1.37% | 449.318 | 447.371–452.501 | 0.41% | 0.19x | 1.00x | 1.00x |
| `fibonacci` | 2 | 125 | 87.664 | 85.699–91.353 | 2.27% | 459.343 | 457.417–471.215 | 1.03% | 0.19x | 1.93x | 1.96x |
| `fibonacci` | 4 | 125 | 88.066 | 87.710–96.290 | 3.81% | 471.832 | 469.242–509.943 | 3.10% | 0.19x | 3.85x | 3.81x |
| `fibonacci` | 8 | 125 | 119.730 | 115.171–153.936 | 11.18% | 645.687 | 642.863–655.439 | 0.75% | 0.19x | 5.67x | 5.57x |

## zig-js shared-realm scaling

This is zig-js's distinct no-GIL shared-object-graph model, which JSC's public C API does not provide.
The timed region creates JavaScript `Thread`s, performs the work, and joins them. Scaling uses the same
shared-realm path at one lane, so thread lifecycle overhead is present in every row.

| workload | lanes | jobs/lane | median (ms) | min–max (ms) | RSD | scaling |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `arithmetic` | 1 | 240 | 83.101 | 83.056–85.297 | 0.99% | 1.00x |
| `arithmetic` | 2 | 240 | 85.054 | 84.899–85.797 | 0.45% | 1.95x |
| `arithmetic` | 4 | 240 | 86.294 | 86.095–119.258 | 13.40% | 3.85x |
| `arithmetic` | 8 | 240 | 106.705 | 104.155–109.725 | 2.02% | 6.23x |
| `properties` | 1 | 300 | 126.288 | 126.227–129.317 | 0.91% | 1.00x |
| `properties` | 2 | 300 | 129.076 | 128.843–130.966 | 0.57% | 1.96x |
| `properties` | 4 | 300 | 131.906 | 131.517–146.789 | 4.21% | 3.83x |
| `properties` | 8 | 300 | 175.031 | 171.794–179.373 | 1.66% | 5.77x |
| `polymorphic_properties` | 1 | 400 | 503.704 | 502.141–505.294 | 0.21% | 1.00x |
| `polymorphic_properties` | 2 | 400 | 519.088 | 515.832–558.050 | 2.86% | 1.94x |
| `polymorphic_properties` | 4 | 400 | 531.788 | 523.652–533.645 | 0.81% | 3.79x |
| `polymorphic_properties` | 8 | 400 | 738.795 | 722.343–746.408 | 1.26% | 5.45x |
| `object_churn` | 1 | 100 | 123.180 | 100.022–137.369 | 9.08% | 1.00x |
| `object_churn` | 2 | 100 | 246.548 | 168.646–260.304 | 13.34% | 1.00x |
| `object_churn` | 4 | 100 | 463.608 | 349.269–510.746 | 11.34% | 1.06x |
| `object_churn` | 8 | 100 | 1922.828 | 1753.677–1956.499 | 4.33% | 0.51x |
| `arrays` | 1 | 550 | 82.337 | 81.687–83.969 | 1.14% | 1.00x |
| `arrays` | 2 | 550 | 88.181 | 87.795–92.008 | 1.80% | 1.87x |
| `arrays` | 4 | 550 | 94.641 | 94.027–97.353 | 1.23% | 3.48x |
| `arrays` | 8 | 550 | 214.583 | 208.488–229.945 | 3.63% | 3.07x |
| `direct_calls` | 1 | 600 | 56.310 | 56.154–57.783 | 1.01% | 1.00x |
| `direct_calls` | 2 | 600 | 57.305 | 57.241–59.692 | 1.55% | 1.97x |
| `direct_calls` | 4 | 600 | 59.113 | 58.961–61.006 | 1.28% | 3.81x |
| `direct_calls` | 8 | 600 | 80.143 | 77.421–85.574 | 3.74% | 5.62x |
| `method_calls` | 1 | 500 | 116.787 | 116.362–119.261 | 0.84% | 1.00x |
| `method_calls` | 2 | 500 | 118.553 | 118.029–121.379 | 0.97% | 1.97x |
| `method_calls` | 4 | 500 | 121.437 | 121.312–126.829 | 1.66% | 3.85x |
| `method_calls` | 8 | 500 | 176.318 | 168.234–177.856 | 2.34% | 5.30x |
| `closure_calls` | 1 | 600 | 62.684 | 62.543–64.105 | 1.00% | 1.00x |
| `closure_calls` | 2 | 600 | 64.339 | 64.239–65.867 | 1.13% | 1.95x |
| `closure_calls` | 4 | 600 | 65.591 | 65.452–71.338 | 3.19% | 3.82x |
| `closure_calls` | 8 | 600 | 91.244 | 85.481–93.205 | 3.26% | 5.50x |
| `arguments_calls` | 1 | 600 | 67.804 | 67.330–69.257 | 0.97% | 1.00x |
| `arguments_calls` | 2 | 600 | 68.877 | 68.559–71.068 | 1.38% | 1.97x |
| `arguments_calls` | 4 | 600 | 70.588 | 70.289–122.102 | 24.83% | 3.84x |
| `arguments_calls` | 8 | 600 | 97.508 | 93.494–111.616 | 6.20% | 5.56x |
| `fibonacci` | 1 | 125 | 258.003 | 252.146–275.680 | 3.78% | 1.00x |
| `fibonacci` | 2 | 125 | 254.248 | 252.960–256.007 | 0.40% | 2.03x |
| `fibonacci` | 4 | 125 | 259.930 | 258.566–262.223 | 0.46% | 3.97x |
| `fibonacci` | 8 | 125 | 366.792 | 359.900–378.515 | 1.67% | 5.63x |

## Reading the result

Across these 10 deliberately small kernels, JSC's single-context throughput is 0.36x
the zig-js throughput by geometric mean. These kernels deliberately exercise guarded native/VM tiers that
zig-js currently implements; rows outside those documented subsets continue through general bytecode paths.
The number is a compact description of this matrix, not a claim about applications or unsupported workloads.

At 8 independent warmed contexts, JSC throughput is 0.34x zig-js by
geometric mean; scaling from the mode's own one-lane baseline is 5.38x
for zig-js and 5.14x for JSC. In the symmetric cold lifecycle, JSC
throughput is 0.35x zig-js, with 5.27x
and 5.08x scaling respectively.

zig-js's shared-realm path scales 4.17x at 8 lanes from its
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
