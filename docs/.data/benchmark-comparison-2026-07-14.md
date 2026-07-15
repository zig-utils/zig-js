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
| zig-js | 6ec1fbd6fb931166a33f23d1754f4d30b8d056ee |
| JavaScriptCore | system framework 22625.1.20.11.3 |
| Power | Now drawing from 'Battery Power' -InternalBattery-0 (id=22806627) 100%; discharging; (no estimate) present: true |

## Single-thread result

Each row runs the same number of jobs in one GC-enabled zig-js context and one warmed JSC global context.
Both runners time the exact invocation `__benchmarkSelected(__benchmarkJobs, __benchmarkLane)`.
Lower time is better; `JSC / zig-js` is JSC throughput divided by zig-js throughput. RSD is relative standard deviation.

| workload | jobs | zig-js median (ms) | zig-js min–max (ms) | zig-js RSD | JSC median (ms) | JSC min–max (ms) | JSC RSD | JSC / zig-js |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `arithmetic` | 240 | 76.500 | 75.505–83.736 | 4.73% | 350.458 | 343.973–379.356 | 3.41% | 0.22x |
| `properties` | 300 | 85.833 | 85.662–95.622 | 4.22% | 291.590 | 286.005–303.145 | 1.90% | 0.29x |
| `polymorphic_properties` | 400 | 80.304 | 80.056–80.810 | 0.35% | 199.006 | 198.641–202.561 | 0.81% | 0.40x |
| `object_churn` | 100 | 121.638 | 117.395–141.989 | 6.72% | 118.874 | 116.405–121.183 | 1.46% | 1.02x |
| `arrays` | 550 | 79.563 | 76.856–110.658 | 15.68% | 149.144 | 147.894–150.853 | 0.59% | 0.53x |
| `direct_calls` | 600 | 58.278 | 57.390–58.661 | 0.69% | 120.848 | 117.583–122.076 | 1.38% | 0.48x |
| `method_calls` | 500 | 60.132 | 60.064–60.205 | 0.09% | 136.643 | 136.433–159.032 | 7.50% | 0.44x |
| `closure_calls` | 600 | 62.488 | 61.793–64.697 | 1.85% | 188.349 | 186.549–192.769 | 1.13% | 0.33x |
| `arguments_calls` | 600 | 66.725 | 66.436–71.255 | 2.75% | 294.830 | 293.740–295.942 | 0.27% | 0.23x |
| `fibonacci` | 125 | 84.692 | 83.504–88.235 | 2.22% | 451.621 | 447.329–455.668 | 0.61% | 0.19x |

## Independent-context steady state

Both engines keep one warmed context on one persistent OS worker per lane. The timed region contains the
same semaphore dispatch, exact invocation, and completion wait. Every lane performs the full job count.
`scaling` uses the same engine and mode at one lane; cross-engine throughput is directly comparable.

| workload | lanes | jobs/lane | zig-js median (ms) | zig-js min–max (ms) | zig-js RSD | JSC median (ms) | JSC min–max (ms) | JSC RSD | JSC / zig-js | zig-js scaling | JSC scaling |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `arithmetic` | 1 | 240 | 77.270 | 75.526–78.882 | 1.69% | 345.127 | 341.993–355.911 | 1.32% | 0.22x | 1.00x | 1.00x |
| `arithmetic` | 2 | 240 | 80.988 | 80.355–82.987 | 1.46% | 357.264 | 350.923–360.415 | 1.21% | 0.23x | 1.91x | 1.93x |
| `arithmetic` | 4 | 240 | 84.649 | 84.514–85.039 | 0.26% | 374.699 | 363.277–390.633 | 2.43% | 0.23x | 3.65x | 3.68x |
| `arithmetic` | 8 | 240 | 99.466 | 98.954–102.356 | 1.32% | 482.166 | 478.152–486.512 | 0.58% | 0.21x | 6.21x | 5.73x |
| `properties` | 1 | 300 | 85.532 | 85.352–87.650 | 0.95% | 285.098 | 284.877–288.217 | 0.44% | 0.30x | 1.00x | 1.00x |
| `properties` | 2 | 300 | 87.415 | 86.975–88.304 | 0.60% | 290.870 | 290.768–291.578 | 0.11% | 0.30x | 1.96x | 1.96x |
| `properties` | 4 | 300 | 89.651 | 89.592–90.069 | 0.18% | 298.019 | 297.825–298.519 | 0.08% | 0.30x | 3.82x | 3.83x |
| `properties` | 8 | 300 | 108.819 | 107.592–111.617 | 1.14% | 395.362 | 390.249–402.264 | 1.24% | 0.28x | 6.29x | 5.77x |
| `polymorphic_properties` | 1 | 400 | 80.700 | 79.841–81.837 | 0.94% | 207.455 | 204.714–219.133 | 2.68% | 0.39x | 1.00x | 1.00x |
| `polymorphic_properties` | 2 | 400 | 82.247 | 81.495–84.581 | 1.37% | 203.573 | 202.620–210.245 | 1.31% | 0.40x | 1.96x | 2.04x |
| `polymorphic_properties` | 4 | 400 | 84.784 | 83.817–86.075 | 0.92% | 208.312 | 207.541–209.824 | 0.35% | 0.41x | 3.81x | 3.98x |
| `polymorphic_properties` | 8 | 400 | 115.477 | 113.245–117.064 | 1.11% | 284.281 | 277.835–295.601 | 2.23% | 0.41x | 5.59x | 5.84x |
| `object_churn` | 1 | 100 | 121.085 | 117.554–129.828 | 3.19% | 115.660 | 113.879–158.704 | 14.99% | 1.05x | 1.00x | 1.00x |
| `object_churn` | 2 | 100 | 129.036 | 127.096–130.383 | 0.96% | 120.849 | 118.338–121.638 | 1.00% | 1.07x | 1.88x | 1.91x |
| `object_churn` | 4 | 100 | 199.983 | 177.610–282.507 | 18.49% | 121.704 | 119.942–148.625 | 10.20% | 1.64x | 2.42x | 3.80x |
| `object_churn` | 8 | 100 | 374.015 | 368.409–417.427 | 4.87% | 180.793 | 171.822–191.837 | 4.15% | 2.07x | 2.59x | 5.12x |
| `arrays` | 1 | 550 | 76.965 | 76.688–77.252 | 0.27% | 149.411 | 147.541–155.102 | 1.66% | 0.52x | 1.00x | 1.00x |
| `arrays` | 2 | 550 | 79.217 | 78.884–80.047 | 0.47% | 154.392 | 151.565–176.624 | 7.14% | 0.51x | 1.94x | 1.94x |
| `arrays` | 4 | 550 | 82.428 | 81.860–88.675 | 2.93% | 157.097 | 154.597–158.369 | 0.90% | 0.52x | 3.73x | 3.80x |
| `arrays` | 8 | 550 | 118.462 | 113.269–130.679 | 5.16% | 224.090 | 220.212–236.942 | 2.48% | 0.53x | 5.20x | 5.33x |
| `direct_calls` | 1 | 600 | 61.198 | 56.770–70.927 | 7.12% | 117.745 | 115.888–147.435 | 9.27% | 0.52x | 1.00x | 1.00x |
| `direct_calls` | 2 | 600 | 60.740 | 56.763–68.252 | 6.82% | 122.741 | 120.321–127.243 | 2.14% | 0.49x | 2.02x | 1.92x |
| `direct_calls` | 4 | 600 | 57.989 | 57.899–59.332 | 0.87% | 126.296 | 125.315–129.076 | 1.01% | 0.46x | 4.22x | 3.73x |
| `direct_calls` | 8 | 600 | 77.225 | 74.640–81.610 | 3.95% | 182.380 | 180.070–193.169 | 2.55% | 0.42x | 6.34x | 5.16x |
| `method_calls` | 1 | 500 | 64.198 | 63.545–68.234 | 2.69% | 137.450 | 136.655–144.370 | 2.62% | 0.47x | 1.00x | 1.00x |
| `method_calls` | 2 | 500 | 65.200 | 63.171–85.040 | 12.75% | 143.834 | 140.591–146.735 | 1.70% | 0.45x | 1.97x | 1.91x |
| `method_calls` | 4 | 500 | 65.747 | 65.120–69.194 | 2.13% | 146.566 | 143.681–149.095 | 1.20% | 0.45x | 3.91x | 3.75x |
| `method_calls` | 8 | 500 | 87.356 | 84.249–92.154 | 3.11% | 206.942 | 202.872–221.393 | 2.94% | 0.42x | 5.88x | 5.31x |
| `closure_calls` | 1 | 600 | 62.629 | 61.387–64.627 | 1.77% | 186.571 | 186.418–188.350 | 0.40% | 0.34x | 1.00x | 1.00x |
| `closure_calls` | 2 | 600 | 63.220 | 62.489–67.791 | 2.92% | 194.376 | 191.145–202.743 | 1.99% | 0.33x | 1.98x | 1.92x |
| `closure_calls` | 4 | 600 | 64.102 | 63.881–74.873 | 6.20% | 204.793 | 199.222–206.587 | 1.39% | 0.31x | 3.91x | 3.64x |
| `closure_calls` | 8 | 600 | 82.656 | 78.483–86.333 | 3.36% | 300.997 | 298.874–311.712 | 1.46% | 0.27x | 6.06x | 4.96x |
| `arguments_calls` | 1 | 600 | 66.895 | 66.747–67.416 | 0.34% | 294.068 | 293.137–298.470 | 0.60% | 0.23x | 1.00x | 1.00x |
| `arguments_calls` | 2 | 600 | 69.855 | 67.841–72.810 | 3.05% | 303.571 | 302.124–310.108 | 0.95% | 0.23x | 1.92x | 1.94x |
| `arguments_calls` | 4 | 600 | 69.703 | 69.448–70.837 | 0.68% | 317.787 | 312.486–320.919 | 1.02% | 0.22x | 3.84x | 3.70x |
| `arguments_calls` | 8 | 600 | 91.143 | 89.643–94.175 | 1.80% | 486.699 | 481.342–522.311 | 3.38% | 0.19x | 5.87x | 4.83x |
| `fibonacci` | 1 | 125 | 85.780 | 82.844–87.840 | 2.46% | 459.361 | 447.393–468.759 | 1.63% | 0.19x | 1.00x | 1.00x |
| `fibonacci` | 2 | 125 | 83.816 | 83.802–86.257 | 1.09% | 461.523 | 454.274–466.415 | 0.95% | 0.18x | 2.05x | 1.99x |
| `fibonacci` | 4 | 125 | 86.698 | 85.837–127.633 | 16.54% | 466.352 | 464.593–471.702 | 0.48% | 0.19x | 3.96x | 3.94x |
| `fibonacci` | 8 | 125 | 112.031 | 109.844–123.334 | 4.10% | 657.463 | 646.104–693.704 | 2.40% | 0.17x | 6.13x | 5.59x |

## Independent-context cold lifecycle

Neither engine warms these contexts. The timer covers OS-thread creation, context creation, workload-source
evaluation and configuration, the exact invocation, context destruction, and OS-thread join on both sides.
`scaling` uses the same engine and cold lifecycle at one lane.

| workload | lanes | jobs/lane | zig-js median (ms) | zig-js min–max (ms) | zig-js RSD | JSC median (ms) | JSC min–max (ms) | JSC RSD | JSC / zig-js | zig-js scaling | JSC scaling |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `arithmetic` | 1 | 240 | 77.996 | 76.961–80.447 | 1.68% | 348.797 | 345.424–362.186 | 1.88% | 0.22x | 1.00x | 1.00x |
| `arithmetic` | 2 | 240 | 82.509 | 81.569–84.265 | 1.09% | 352.898 | 352.408–356.783 | 0.53% | 0.23x | 1.89x | 1.98x |
| `arithmetic` | 4 | 240 | 86.477 | 86.444–87.113 | 0.28% | 363.972 | 360.705–376.080 | 1.41% | 0.24x | 3.61x | 3.83x |
| `arithmetic` | 8 | 240 | 104.184 | 101.423–106.783 | 1.91% | 490.558 | 480.163–542.483 | 4.29% | 0.21x | 5.99x | 5.69x |
| `properties` | 1 | 300 | 87.070 | 86.515–95.500 | 3.63% | 286.162 | 285.915–288.833 | 0.36% | 0.30x | 1.00x | 1.00x |
| `properties` | 2 | 300 | 88.728 | 88.484–98.810 | 4.17% | 292.183 | 291.879–296.090 | 0.60% | 0.30x | 1.96x | 1.96x |
| `properties` | 4 | 300 | 91.062 | 90.677–102.601 | 4.70% | 300.129 | 299.264–301.038 | 0.23% | 0.30x | 3.82x | 3.81x |
| `properties` | 8 | 300 | 111.295 | 110.680–116.514 | 1.78% | 399.680 | 397.210–439.084 | 3.72% | 0.28x | 6.26x | 5.73x |
| `polymorphic_properties` | 1 | 400 | 86.252 | 83.568–89.460 | 2.05% | 202.021 | 200.151–217.952 | 3.15% | 0.43x | 1.00x | 1.00x |
| `polymorphic_properties` | 2 | 400 | 86.871 | 84.311–88.210 | 1.70% | 204.328 | 203.504–206.634 | 0.49% | 0.43x | 1.99x | 1.98x |
| `polymorphic_properties` | 4 | 400 | 85.619 | 85.270–86.152 | 0.41% | 209.169 | 208.651–218.856 | 1.75% | 0.41x | 4.03x | 3.86x |
| `polymorphic_properties` | 8 | 400 | 117.119 | 115.497–121.466 | 1.84% | 287.487 | 282.837–375.850 | 10.98% | 0.41x | 5.89x | 5.62x |
| `object_churn` | 1 | 100 | 118.878 | 116.974–120.061 | 0.98% | 116.540 | 115.183–117.888 | 0.84% | 1.02x | 1.00x | 1.00x |
| `object_churn` | 2 | 100 | 133.549 | 129.233–134.251 | 1.49% | 123.186 | 120.017–157.154 | 12.02% | 1.08x | 1.78x | 1.89x |
| `object_churn` | 4 | 100 | 183.887 | 180.853–202.309 | 3.88% | 123.505 | 122.308–141.507 | 5.54% | 1.49x | 2.59x | 3.77x |
| `object_churn` | 8 | 100 | 404.004 | 377.745–448.492 | 6.83% | 172.921 | 167.865–176.133 | 1.84% | 2.34x | 2.35x | 5.39x |
| `arrays` | 1 | 550 | 75.958 | 75.596–77.943 | 1.06% | 150.510 | 149.648–152.107 | 0.55% | 0.50x | 1.00x | 1.00x |
| `arrays` | 2 | 550 | 78.416 | 78.214–81.027 | 1.28% | 152.885 | 151.208–153.355 | 0.58% | 0.51x | 1.94x | 1.97x |
| `arrays` | 4 | 550 | 82.733 | 81.034–107.235 | 13.00% | 156.033 | 155.794–157.542 | 0.40% | 0.53x | 3.67x | 3.86x |
| `arrays` | 8 | 550 | 115.263 | 109.163–145.895 | 11.26% | 237.474 | 231.836–285.583 | 7.63% | 0.49x | 5.27x | 5.07x |
| `direct_calls` | 1 | 600 | 60.523 | 59.523–64.316 | 2.79% | 121.879 | 117.904–147.581 | 9.16% | 0.50x | 1.00x | 1.00x |
| `direct_calls` | 2 | 600 | 65.915 | 62.337–122.409 | 28.82% | 125.697 | 122.752–145.072 | 6.33% | 0.52x | 1.84x | 1.94x |
| `direct_calls` | 4 | 600 | 65.442 | 61.364–68.129 | 3.12% | 129.997 | 126.844–133.163 | 1.97% | 0.50x | 3.70x | 3.75x |
| `direct_calls` | 8 | 600 | 78.881 | 76.105–81.785 | 2.44% | 192.017 | 183.862–213.242 | 5.41% | 0.41x | 6.14x | 5.08x |
| `method_calls` | 1 | 500 | 63.793 | 63.522–64.802 | 0.79% | 138.981 | 137.380–183.099 | 11.43% | 0.46x | 1.00x | 1.00x |
| `method_calls` | 2 | 500 | 75.598 | 73.575–77.624 | 1.88% | 143.813 | 140.876–161.166 | 4.85% | 0.53x | 1.69x | 1.93x |
| `method_calls` | 4 | 500 | 68.410 | 66.474–70.000 | 2.10% | 146.693 | 145.648–148.659 | 0.74% | 0.47x | 3.73x | 3.79x |
| `method_calls` | 8 | 500 | 90.703 | 87.689–98.715 | 4.35% | 222.743 | 213.191–231.261 | 3.22% | 0.41x | 5.63x | 4.99x |
| `closure_calls` | 1 | 600 | 72.612 | 65.759–78.410 | 6.51% | 191.609 | 188.914–217.813 | 5.31% | 0.38x | 1.00x | 1.00x |
| `closure_calls` | 2 | 600 | 73.541 | 66.850–82.704 | 8.01% | 200.055 | 192.451–202.764 | 1.86% | 0.37x | 1.97x | 1.92x |
| `closure_calls` | 4 | 600 | 66.400 | 65.712–66.876 | 0.59% | 208.117 | 205.985–230.766 | 4.30% | 0.32x | 4.37x | 3.68x |
| `closure_calls` | 8 | 600 | 93.257 | 89.294–99.342 | 3.72% | 328.687 | 310.429–417.413 | 13.25% | 0.28x | 6.23x | 4.66x |
| `arguments_calls` | 1 | 600 | 68.245 | 67.519–71.200 | 1.82% | 299.215 | 294.961–301.607 | 0.89% | 0.23x | 1.00x | 1.00x |
| `arguments_calls` | 2 | 600 | 69.659 | 69.246–72.710 | 1.70% | 305.355 | 304.049–310.352 | 0.70% | 0.23x | 1.96x | 1.96x |
| `arguments_calls` | 4 | 600 | 71.433 | 70.932–79.204 | 4.10% | 323.829 | 316.835–327.457 | 1.17% | 0.22x | 3.82x | 3.70x |
| `arguments_calls` | 8 | 600 | 91.976 | 91.065–92.756 | 0.59% | 490.377 | 476.422–549.229 | 4.91% | 0.19x | 5.94x | 4.88x |
| `fibonacci` | 1 | 125 | 84.216 | 83.207–91.923 | 3.64% | 465.633 | 447.157–523.551 | 5.44% | 0.18x | 1.00x | 1.00x |
| `fibonacci` | 2 | 125 | 85.309 | 85.032–87.121 | 0.84% | 455.696 | 454.220–471.648 | 1.35% | 0.19x | 1.97x | 2.04x |
| `fibonacci` | 4 | 125 | 89.341 | 87.134–101.263 | 5.90% | 467.976 | 466.028–469.911 | 0.28% | 0.19x | 3.77x | 3.98x |
| `fibonacci` | 8 | 125 | 116.063 | 114.785–117.911 | 0.97% | 668.625 | 655.095–760.475 | 6.17% | 0.17x | 5.80x | 5.57x |

## zig-js shared-realm scaling

This is zig-js's distinct no-GIL shared-object-graph model, which JSC's public C API does not provide.
The timed region creates JavaScript `Thread`s, performs the work, and joins them. Scaling uses the same
shared-realm path at one lane, so thread lifecycle overhead is present in every row.

| workload | lanes | jobs/lane | median (ms) | min–max (ms) | RSD | scaling |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `arithmetic` | 1 | 240 | 77.473 | 75.616–82.720 | 3.65% | 1.00x |
| `arithmetic` | 2 | 240 | 82.520 | 79.657–84.393 | 2.00% | 1.88x |
| `arithmetic` | 4 | 240 | 85.038 | 84.667–88.506 | 1.82% | 3.64x |
| `arithmetic` | 8 | 240 | 100.215 | 98.563–102.220 | 1.10% | 6.18x |
| `properties` | 1 | 300 | 123.980 | 123.914–124.139 | 0.06% | 1.00x |
| `properties` | 2 | 300 | 126.489 | 126.254–126.811 | 0.16% | 1.96x |
| `properties` | 4 | 300 | 129.656 | 129.527–132.547 | 0.84% | 3.82x |
| `properties` | 8 | 300 | 163.750 | 159.088–165.310 | 1.72% | 6.06x |
| `polymorphic_properties` | 1 | 400 | 522.440 | 509.942–551.307 | 2.90% | 1.00x |
| `polymorphic_properties` | 2 | 400 | 519.249 | 517.439–523.676 | 0.41% | 2.01x |
| `polymorphic_properties` | 4 | 400 | 538.883 | 530.106–550.031 | 1.40% | 3.88x |
| `polymorphic_properties` | 8 | 400 | 725.053 | 678.727–801.396 | 5.58% | 5.76x |
| `object_churn` | 1 | 100 | 216.556 | 181.500–284.800 | 13.88% | 1.00x |
| `object_churn` | 2 | 100 | 416.495 | 319.221–688.609 | 25.52% | 1.04x |
| `object_churn` | 4 | 100 | 831.964 | 539.306–1867.363 | 44.52% | 1.04x |
| `object_churn` | 8 | 100 | 5800.683 | 2116.372–6113.288 | 26.85% | 0.30x |
| `arrays` | 1 | 550 | 79.766 | 79.313–82.099 | 1.24% | 1.00x |
| `arrays` | 2 | 550 | 84.378 | 83.835–84.410 | 0.30% | 1.89x |
| `arrays` | 4 | 550 | 91.278 | 88.589–93.121 | 1.84% | 3.50x |
| `arrays` | 8 | 550 | 192.023 | 187.969–201.600 | 2.43% | 3.32x |
| `direct_calls` | 1 | 600 | 57.137 | 56.022–57.873 | 1.04% | 1.00x |
| `direct_calls` | 2 | 600 | 60.748 | 58.644–63.940 | 2.58% | 1.88x |
| `direct_calls` | 4 | 600 | 63.513 | 58.447–68.475 | 6.46% | 3.60x |
| `direct_calls` | 8 | 600 | 76.208 | 74.381–82.657 | 4.30% | 6.00x |
| `method_calls` | 1 | 500 | 116.376 | 115.555–119.452 | 1.31% | 1.00x |
| `method_calls` | 2 | 500 | 121.347 | 119.983–126.083 | 1.66% | 1.92x |
| `method_calls` | 4 | 500 | 123.754 | 121.180–126.407 | 1.61% | 3.76x |
| `method_calls` | 8 | 500 | 203.498 | 166.374–283.933 | 19.31% | 4.58x |
| `closure_calls` | 1 | 600 | 68.744 | 64.264–76.037 | 5.73% | 1.00x |
| `closure_calls` | 2 | 600 | 64.092 | 63.970–67.852 | 2.54% | 2.15x |
| `closure_calls` | 4 | 600 | 65.361 | 65.278–66.325 | 0.59% | 4.21x |
| `closure_calls` | 8 | 600 | 93.205 | 83.226–97.500 | 5.98% | 5.90x |
| `arguments_calls` | 1 | 600 | 66.408 | 66.300–69.829 | 2.05% | 1.00x |
| `arguments_calls` | 2 | 600 | 68.719 | 67.853–71.388 | 1.83% | 1.93x |
| `arguments_calls` | 4 | 600 | 70.951 | 69.002–80.032 | 5.44% | 3.74x |
| `arguments_calls` | 8 | 600 | 93.069 | 92.119–98.893 | 2.50% | 5.71x |
| `fibonacci` | 1 | 125 | 249.606 | 248.535–249.972 | 0.23% | 1.00x |
| `fibonacci` | 2 | 125 | 248.045 | 247.660–259.529 | 1.72% | 2.01x |
| `fibonacci` | 4 | 125 | 256.324 | 253.722–260.939 | 1.17% | 3.90x |
| `fibonacci` | 8 | 125 | 380.241 | 371.089–384.907 | 1.38% | 5.25x |

## Reading the result

Across these 10 deliberately small kernels, JSC's single-context throughput is 0.37x
the zig-js throughput by geometric mean. These kernels deliberately exercise guarded native/VM tiers that
zig-js currently implements; rows outside those documented subsets continue through general bytecode paths.
The number is a compact description of this matrix, not a claim about applications or unsupported workloads.

At 8 independent warmed contexts, JSC throughput is 0.36x zig-js by
geometric mean; scaling from the mode's own one-lane baseline is 5.47x
for zig-js and 5.35x for JSC. In the symmetric cold lifecycle, JSC
throughput is 0.37x zig-js, with 5.38x
and 5.26x scaling respectively.

zig-js's shared-realm path scales 4.00x at 8 lanes from its
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
