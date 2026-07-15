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
| zig-js | fff12f905819fab376372fabddb46d6a95f02f97 |
| zig-gc | 9d4af0d49be5eba5b9283d5ed135fdf02626e2ac |
| zig-regex | 5937fa7d4db0b69575c821066afd1a7da92aa019 |
| JavaScriptCore | system framework 22625.1.20.11.3 |
| Power | Now drawing from 'Battery Power' -InternalBattery-0 (id=22806627) 83%; discharging; (no estimate) present: true |

## Single-thread result

Each row runs the same number of jobs in one GC-enabled zig-js context and one warmed JSC global context.
Both runners time the exact invocation `__benchmarkSelected(__benchmarkJobs, __benchmarkLane)`.
Lower time is better; `JSC / zig-js` is JSC throughput divided by zig-js throughput. RSD is relative standard deviation.

| workload | jobs | zig-js median (ms) | zig-js min–max (ms) | zig-js RSD | JSC median (ms) | JSC min–max (ms) | JSC RSD | JSC / zig-js |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `arithmetic` | 240 | 83.460 | 83.232–84.510 | 0.69% | 356.409 | 352.524–369.873 | 1.75% | 0.23x |
| `properties` | 300 | 90.049 | 89.758–90.511 | 0.27% | 298.925 | 295.342–308.859 | 1.48% | 0.30x |
| `polymorphic_properties` | 400 | 84.488 | 83.386–85.440 | 0.78% | 227.078 | 213.113–348.724 | 19.59% | 0.37x |
| `object_churn` | 100 | 109.144 | 108.262–110.307 | 0.61% | 117.864 | 116.670–126.835 | 4.01% | 0.93x |
| `arrays` | 550 | 80.170 | 79.821–80.599 | 0.37% | 152.181 | 150.648–153.153 | 0.64% | 0.53x |
| `direct_calls` | 600 | 57.853 | 57.478–60.940 | 2.36% | 119.884 | 118.314–122.624 | 1.26% | 0.48x |
| `method_calls` | 500 | 63.367 | 63.266–65.637 | 1.47% | 141.896 | 140.148–167.559 | 6.70% | 0.45x |
| `closure_calls` | 600 | 64.975 | 64.274–66.249 | 1.15% | 196.604 | 190.546–197.350 | 1.38% | 0.33x |
| `arguments_calls` | 600 | 70.252 | 69.179–95.907 | 12.82% | 300.100 | 299.258–307.868 | 0.99% | 0.23x |
| `fibonacci` | 125 | 82.233 | 81.840–83.906 | 0.97% | 455.227 | 446.400–478.125 | 2.25% | 0.18x |

## Independent-context steady state

Both engines keep one warmed context on one persistent OS worker per lane. The timed region contains the
same semaphore dispatch, exact invocation, and completion wait. Every lane performs the full job count.
`scaling` uses the same engine and mode at one lane; cross-engine throughput is directly comparable.

| workload | lanes | jobs/lane | zig-js median (ms) | zig-js min–max (ms) | zig-js RSD | JSC median (ms) | JSC min–max (ms) | JSC RSD | JSC / zig-js | zig-js scaling | JSC scaling |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `arithmetic` | 1 | 240 | 83.362 | 83.223–83.475 | 0.11% | 355.442 | 351.444–363.260 | 1.21% | 0.23x | 1.00x | 1.00x |
| `arithmetic` | 2 | 240 | 85.882 | 85.334–87.872 | 1.08% | 366.380 | 362.578–391.202 | 2.69% | 0.23x | 1.94x | 1.94x |
| `arithmetic` | 4 | 240 | 87.176 | 85.816–87.834 | 0.87% | 404.910 | 398.663–450.907 | 4.42% | 0.22x | 3.83x | 3.51x |
| `arithmetic` | 8 | 240 | 107.624 | 104.534–109.828 | 2.00% | 537.507 | 526.814–563.147 | 2.58% | 0.20x | 6.20x | 5.29x |
| `properties` | 1 | 300 | 90.787 | 90.035–116.174 | 10.24% | 293.975 | 292.678–301.821 | 1.10% | 0.31x | 1.00x | 1.00x |
| `properties` | 2 | 300 | 90.986 | 90.597–91.396 | 0.30% | 299.639 | 299.015–300.968 | 0.23% | 0.30x | 2.00x | 1.96x |
| `properties` | 4 | 300 | 93.688 | 91.811–99.956 | 2.85% | 328.413 | 319.059–356.711 | 3.59% | 0.29x | 3.88x | 3.58x |
| `properties` | 8 | 300 | 127.531 | 120.288–141.985 | 5.26% | 470.714 | 465.179–477.149 | 1.14% | 0.27x | 5.70x | 5.00x |
| `polymorphic_properties` | 1 | 400 | 91.868 | 87.347–96.290 | 3.35% | 245.433 | 221.618–288.903 | 10.99% | 0.37x | 1.00x | 1.00x |
| `polymorphic_properties` | 2 | 400 | 85.694 | 85.382–89.876 | 1.86% | 231.982 | 212.235–258.016 | 7.04% | 0.37x | 2.14x | 2.12x |
| `polymorphic_properties` | 4 | 400 | 105.279 | 97.983–125.137 | 10.27% | 234.029 | 231.077–252.751 | 3.42% | 0.45x | 3.49x | 4.19x |
| `polymorphic_properties` | 8 | 400 | 124.906 | 119.416–232.537 | 28.61% | 321.927 | 315.450–326.803 | 1.30% | 0.39x | 5.88x | 6.10x |
| `object_churn` | 1 | 100 | 109.378 | 108.884–118.694 | 3.21% | 116.486 | 116.189–117.043 | 0.28% | 0.94x | 1.00x | 1.00x |
| `object_churn` | 2 | 100 | 118.824 | 118.135–120.045 | 0.57% | 120.695 | 120.029–121.229 | 0.36% | 0.98x | 1.84x | 1.93x |
| `object_churn` | 4 | 100 | 135.197 | 133.293–138.065 | 1.18% | 124.018 | 123.121–151.589 | 8.02% | 1.09x | 3.24x | 3.76x |
| `object_churn` | 8 | 100 | 266.624 | 264.002–270.842 | 0.97% | 183.781 | 180.340–188.692 | 1.60% | 1.45x | 3.28x | 5.07x |
| `arrays` | 1 | 550 | 80.413 | 79.547–81.493 | 0.91% | 152.001 | 151.318–152.474 | 0.28% | 0.53x | 1.00x | 1.00x |
| `arrays` | 2 | 550 | 83.514 | 82.964–85.448 | 1.02% | 158.943 | 157.309–163.295 | 1.46% | 0.53x | 1.93x | 1.91x |
| `arrays` | 4 | 550 | 85.766 | 85.024–86.405 | 0.66% | 171.391 | 159.589–182.809 | 4.98% | 0.50x | 3.75x | 3.55x |
| `arrays` | 8 | 550 | 128.020 | 124.341–152.842 | 8.80% | 265.918 | 248.041–289.169 | 5.07% | 0.48x | 5.03x | 4.57x |
| `direct_calls` | 1 | 600 | 61.272 | 58.411–73.904 | 9.42% | 122.680 | 118.218–123.317 | 1.63% | 0.50x | 1.00x | 1.00x |
| `direct_calls` | 2 | 600 | 64.983 | 59.524–71.528 | 6.33% | 132.067 | 123.941–138.917 | 4.65% | 0.49x | 1.89x | 1.86x |
| `direct_calls` | 4 | 600 | 59.321 | 59.278–60.664 | 0.85% | 134.718 | 129.337–140.983 | 2.80% | 0.44x | 4.13x | 3.64x |
| `direct_calls` | 8 | 600 | 86.650 | 80.342–93.885 | 5.55% | 209.146 | 194.246–222.043 | 4.39% | 0.41x | 5.66x | 4.69x |
| `method_calls` | 1 | 500 | 64.416 | 63.822–65.311 | 0.74% | 141.105 | 140.313–172.924 | 9.32% | 0.46x | 1.00x | 1.00x |
| `method_calls` | 2 | 500 | 66.671 | 66.111–67.519 | 0.70% | 145.580 | 143.208–176.398 | 7.95% | 0.46x | 1.93x | 1.94x |
| `method_calls` | 4 | 500 | 73.368 | 67.525–74.878 | 4.28% | 153.633 | 150.131–164.361 | 3.02% | 0.48x | 3.51x | 3.67x |
| `method_calls` | 8 | 500 | 94.638 | 90.681–99.345 | 3.39% | 225.753 | 217.728–237.409 | 3.15% | 0.42x | 5.45x | 5.00x |
| `closure_calls` | 1 | 600 | 64.159 | 63.625–68.421 | 2.59% | 192.983 | 190.339–229.986 | 7.15% | 0.33x | 1.00x | 1.00x |
| `closure_calls` | 2 | 600 | 66.421 | 65.762–68.884 | 1.80% | 199.388 | 196.132–230.501 | 5.96% | 0.33x | 1.93x | 1.94x |
| `closure_calls` | 4 | 600 | 69.857 | 66.009–72.965 | 3.61% | 212.893 | 210.024–237.259 | 4.41% | 0.33x | 3.67x | 3.63x |
| `closure_calls` | 8 | 600 | 94.428 | 90.399–101.937 | 3.63% | 338.457 | 322.974–347.070 | 2.74% | 0.28x | 5.44x | 4.56x |
| `arguments_calls` | 1 | 600 | 69.641 | 69.216–71.262 | 1.02% | 304.225 | 299.107–341.975 | 4.81% | 0.23x | 1.00x | 1.00x |
| `arguments_calls` | 2 | 600 | 71.246 | 70.956–71.428 | 0.24% | 313.359 | 311.173–314.685 | 0.40% | 0.23x | 1.95x | 1.94x |
| `arguments_calls` | 4 | 600 | 74.943 | 71.776–80.737 | 3.77% | 328.365 | 323.497–333.511 | 1.19% | 0.23x | 3.72x | 3.71x |
| `arguments_calls` | 8 | 600 | 100.188 | 96.946–115.362 | 6.21% | 507.589 | 499.446–523.922 | 1.59% | 0.20x | 5.56x | 4.79x |
| `fibonacci` | 1 | 125 | 83.384 | 82.617–89.088 | 3.38% | 452.141 | 450.390–489.160 | 3.10% | 0.18x | 1.00x | 1.00x |
| `fibonacci` | 2 | 125 | 85.593 | 84.479–86.592 | 1.04% | 459.933 | 458.598–464.042 | 0.39% | 0.19x | 1.95x | 1.97x |
| `fibonacci` | 4 | 125 | 89.770 | 88.351–90.598 | 0.78% | 477.396 | 469.387–498.705 | 2.56% | 0.19x | 3.72x | 3.79x |
| `fibonacci` | 8 | 125 | 120.613 | 113.657–157.510 | 14.13% | 660.264 | 648.294–755.739 | 5.53% | 0.18x | 5.53x | 5.48x |

## Independent-context cold lifecycle

Neither engine warms these contexts. The timer covers OS-thread creation, context creation, workload-source
evaluation and configuration, the exact invocation, context destruction, and OS-thread join on both sides.
`scaling` uses the same engine and cold lifecycle at one lane.

| workload | lanes | jobs/lane | zig-js median (ms) | zig-js min–max (ms) | zig-js RSD | JSC median (ms) | JSC min–max (ms) | JSC RSD | JSC / zig-js | zig-js scaling | JSC scaling |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `arithmetic` | 1 | 240 | 85.128 | 85.013–85.617 | 0.24% | 357.699 | 354.574–360.902 | 0.66% | 0.24x | 1.00x | 1.00x |
| `arithmetic` | 2 | 240 | 87.284 | 87.108–88.350 | 0.49% | 369.594 | 363.669–371.956 | 0.86% | 0.24x | 1.95x | 1.94x |
| `arithmetic` | 4 | 240 | 87.855 | 87.634–88.883 | 0.48% | 400.600 | 391.846–413.159 | 2.11% | 0.22x | 3.88x | 3.57x |
| `arithmetic` | 8 | 240 | 110.290 | 107.943–111.523 | 1.08% | 568.159 | 531.177–593.705 | 3.53% | 0.19x | 6.17x | 5.04x |
| `properties` | 1 | 300 | 90.321 | 90.126–91.368 | 0.45% | 295.154 | 294.575–297.299 | 0.31% | 0.31x | 1.00x | 1.00x |
| `properties` | 2 | 300 | 92.175 | 91.982–92.757 | 0.28% | 302.464 | 301.050–305.053 | 0.44% | 0.30x | 1.96x | 1.95x |
| `properties` | 4 | 300 | 94.166 | 93.940–97.702 | 1.49% | 348.398 | 332.071–375.782 | 4.42% | 0.27x | 3.84x | 3.39x |
| `properties` | 8 | 300 | 122.974 | 119.667–129.922 | 2.65% | 539.044 | 531.401–559.017 | 1.71% | 0.23x | 5.88x | 4.38x |
| `polymorphic_properties` | 1 | 400 | 94.051 | 90.086–98.423 | 3.05% | 232.735 | 215.384–278.003 | 9.50% | 0.40x | 1.00x | 1.00x |
| `polymorphic_properties` | 2 | 400 | 87.554 | 87.237–88.191 | 0.41% | 211.547 | 208.251–248.611 | 8.41% | 0.41x | 2.15x | 2.20x |
| `polymorphic_properties` | 4 | 400 | 100.796 | 96.632–108.721 | 4.52% | 282.544 | 249.019–349.396 | 13.13% | 0.36x | 3.73x | 3.29x |
| `polymorphic_properties` | 8 | 400 | 128.216 | 123.095–144.249 | 5.83% | 341.695 | 315.935–349.580 | 3.85% | 0.38x | 5.87x | 5.45x |
| `object_churn` | 1 | 100 | 110.323 | 110.060–111.672 | 0.53% | 117.817 | 117.096–118.730 | 0.53% | 0.94x | 1.00x | 1.00x |
| `object_churn` | 2 | 100 | 120.896 | 119.100–156.629 | 10.71% | 121.978 | 121.489–123.754 | 0.68% | 0.99x | 1.83x | 1.93x |
| `object_churn` | 4 | 100 | 138.377 | 136.386–142.328 | 1.49% | 133.423 | 127.488–142.282 | 4.12% | 1.04x | 3.19x | 3.53x |
| `object_churn` | 8 | 100 | 275.548 | 271.355–281.204 | 1.25% | 188.630 | 185.713–194.224 | 1.54% | 1.46x | 3.20x | 5.00x |
| `arrays` | 1 | 550 | 79.110 | 78.517–81.218 | 1.15% | 155.918 | 151.289–164.999 | 2.71% | 0.51x | 1.00x | 1.00x |
| `arrays` | 2 | 550 | 82.805 | 82.543–84.694 | 1.12% | 159.301 | 157.662–188.072 | 6.64% | 0.52x | 1.91x | 1.96x |
| `arrays` | 4 | 550 | 84.758 | 84.238–87.623 | 1.57% | 165.107 | 159.097–168.264 | 1.89% | 0.51x | 3.73x | 3.78x |
| `arrays` | 8 | 550 | 123.941 | 119.939–168.395 | 13.39% | 256.301 | 249.813–263.253 | 1.93% | 0.48x | 5.11x | 4.87x |
| `direct_calls` | 1 | 600 | 60.808 | 59.141–67.325 | 4.52% | 121.040 | 120.596–122.365 | 0.60% | 0.50x | 1.00x | 1.00x |
| `direct_calls` | 2 | 600 | 63.965 | 60.756–66.535 | 3.19% | 133.038 | 123.522–149.710 | 7.19% | 0.48x | 1.90x | 1.82x |
| `direct_calls` | 4 | 600 | 62.520 | 61.201–66.008 | 3.01% | 134.380 | 133.978–141.288 | 1.97% | 0.47x | 3.89x | 3.60x |
| `direct_calls` | 8 | 600 | 86.799 | 83.061–89.644 | 3.13% | 202.909 | 195.507–225.893 | 5.00% | 0.43x | 5.60x | 4.77x |
| `method_calls` | 1 | 500 | 68.030 | 66.624–70.795 | 1.88% | 142.087 | 140.530–149.809 | 2.23% | 0.48x | 1.00x | 1.00x |
| `method_calls` | 2 | 500 | 68.594 | 67.270–70.895 | 1.88% | 146.187 | 145.023–177.468 | 7.92% | 0.47x | 1.98x | 1.94x |
| `method_calls` | 4 | 500 | 78.365 | 70.994–82.121 | 5.40% | 157.020 | 150.070–164.678 | 2.81% | 0.50x | 3.47x | 3.62x |
| `method_calls` | 8 | 500 | 94.919 | 88.213–135.599 | 16.24% | 255.271 | 217.982–312.722 | 12.11% | 0.37x | 5.73x | 4.45x |
| `closure_calls` | 1 | 600 | 66.709 | 64.889–66.877 | 1.04% | 196.858 | 195.620–230.636 | 6.40% | 0.34x | 1.00x | 1.00x |
| `closure_calls` | 2 | 600 | 67.924 | 65.885–70.003 | 2.26% | 202.451 | 199.185–216.478 | 2.89% | 0.34x | 1.96x | 1.94x |
| `closure_calls` | 4 | 600 | 70.484 | 67.161–73.265 | 3.51% | 214.947 | 213.300–254.356 | 6.79% | 0.33x | 3.79x | 3.66x |
| `closure_calls` | 8 | 600 | 90.067 | 85.928–92.091 | 2.45% | 337.317 | 328.371–355.574 | 2.56% | 0.27x | 5.93x | 4.67x |
| `arguments_calls` | 1 | 600 | 71.780 | 71.008–74.614 | 2.12% | 309.394 | 304.065–317.263 | 1.64% | 0.23x | 1.00x | 1.00x |
| `arguments_calls` | 2 | 600 | 72.387 | 72.077–72.968 | 0.47% | 313.105 | 311.098–335.522 | 2.74% | 0.23x | 1.98x | 1.98x |
| `arguments_calls` | 4 | 600 | 75.831 | 73.239–108.883 | 15.73% | 332.229 | 328.364–363.636 | 3.70% | 0.23x | 3.79x | 3.73x |
| `arguments_calls` | 8 | 600 | 101.023 | 100.647–102.669 | 0.85% | 512.579 | 511.395–525.481 | 1.08% | 0.20x | 5.68x | 4.83x |
| `fibonacci` | 1 | 125 | 85.511 | 83.897–93.457 | 4.15% | 452.304 | 450.322–481.086 | 2.40% | 0.19x | 1.00x | 1.00x |
| `fibonacci` | 2 | 125 | 85.310 | 85.203–89.066 | 1.62% | 457.288 | 454.469–464.946 | 0.89% | 0.19x | 2.00x | 1.98x |
| `fibonacci` | 4 | 125 | 86.896 | 86.807–88.438 | 0.74% | 471.662 | 470.237–482.491 | 0.95% | 0.18x | 3.94x | 3.84x |
| `fibonacci` | 8 | 125 | 119.385 | 117.178–122.645 | 1.95% | 655.648 | 643.884–699.050 | 3.34% | 0.18x | 5.73x | 5.52x |

## zig-js shared-realm scaling

This is zig-js's distinct no-GIL shared-object-graph model, which JSC's public C API does not provide.
The timed region creates JavaScript `Thread`s, performs the work, and joins them. Scaling uses the same
shared-realm path at one lane, so thread lifecycle overhead is present in every row.

| workload | lanes | jobs/lane | median (ms) | min–max (ms) | RSD | scaling |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `arithmetic` | 1 | 240 | 83.622 | 83.221–87.222 | 1.70% | 1.00x |
| `arithmetic` | 2 | 240 | 85.377 | 85.140–86.565 | 0.57% | 1.96x |
| `arithmetic` | 4 | 240 | 88.668 | 85.759–104.933 | 7.73% | 3.77x |
| `arithmetic` | 8 | 240 | 109.544 | 107.691–117.932 | 3.95% | 6.11x |
| `properties` | 1 | 300 | 129.786 | 129.571–129.890 | 0.10% | 1.00x |
| `properties` | 2 | 300 | 131.813 | 131.363–132.564 | 0.39% | 1.97x |
| `properties` | 4 | 300 | 135.993 | 134.913–146.252 | 2.90% | 3.82x |
| `properties` | 8 | 300 | 185.549 | 180.902–190.206 | 1.76% | 5.60x |
| `polymorphic_properties` | 1 | 400 | 597.711 | 589.432–630.904 | 2.29% | 1.00x |
| `polymorphic_properties` | 2 | 400 | 571.943 | 571.056–584.686 | 1.07% | 2.09x |
| `polymorphic_properties` | 4 | 400 | 580.060 | 572.190–631.890 | 4.13% | 4.12x |
| `polymorphic_properties` | 8 | 400 | 757.858 | 746.780–768.502 | 1.05% | 6.31x |
| `object_churn` | 1 | 100 | 193.853 | 171.034–255.143 | 13.09% | 1.00x |
| `object_churn` | 2 | 100 | 391.765 | 265.203–408.164 | 13.07% | 0.99x |
| `object_churn` | 4 | 100 | 752.843 | 632.113–780.342 | 8.40% | 1.03x |
| `object_churn` | 8 | 100 | 2374.329 | 2156.791–2629.282 | 6.32% | 0.65x |
| `arrays` | 1 | 550 | 83.483 | 82.932–116.281 | 13.90% | 1.00x |
| `arrays` | 2 | 550 | 89.474 | 88.325–89.804 | 0.72% | 1.87x |
| `arrays` | 4 | 550 | 97.459 | 93.779–104.513 | 3.46% | 3.43x |
| `arrays` | 8 | 550 | 242.194 | 227.060–281.378 | 7.68% | 2.76x |
| `direct_calls` | 1 | 600 | 59.257 | 57.921–59.918 | 1.32% | 1.00x |
| `direct_calls` | 2 | 600 | 59.071 | 58.590–88.005 | 17.26% | 2.01x |
| `direct_calls` | 4 | 600 | 60.690 | 59.425–69.658 | 7.17% | 3.91x |
| `direct_calls` | 8 | 600 | 85.414 | 79.186–93.401 | 6.47% | 5.55x |
| `method_calls` | 1 | 500 | 124.318 | 119.082–128.979 | 2.96% | 1.00x |
| `method_calls` | 2 | 500 | 123.521 | 122.932–125.131 | 0.65% | 2.01x |
| `method_calls` | 4 | 500 | 126.546 | 125.549–128.141 | 0.73% | 3.93x |
| `method_calls` | 8 | 500 | 199.988 | 183.127–245.874 | 10.93% | 4.97x |
| `closure_calls` | 1 | 600 | 67.528 | 64.723–82.182 | 9.67% | 1.00x |
| `closure_calls` | 2 | 600 | 68.541 | 65.681–72.279 | 3.24% | 1.97x |
| `closure_calls` | 4 | 600 | 71.611 | 67.891–77.623 | 4.93% | 3.77x |
| `closure_calls` | 8 | 600 | 96.832 | 91.331–103.550 | 3.99% | 5.58x |
| `arguments_calls` | 1 | 600 | 70.621 | 69.818–73.111 | 1.69% | 1.00x |
| `arguments_calls` | 2 | 600 | 71.378 | 71.277–71.464 | 0.09% | 1.98x |
| `arguments_calls` | 4 | 600 | 75.112 | 71.197–79.267 | 4.42% | 3.76x |
| `arguments_calls` | 8 | 600 | 102.137 | 98.531–121.261 | 7.67% | 5.53x |
| `fibonacci` | 1 | 125 | 257.612 | 248.500–270.485 | 2.96% | 1.00x |
| `fibonacci` | 2 | 125 | 252.206 | 249.202–286.074 | 5.02% | 2.04x |
| `fibonacci` | 4 | 125 | 260.708 | 255.290–290.390 | 4.63% | 3.95x |
| `fibonacci` | 8 | 125 | 374.975 | 361.903–378.236 | 1.70% | 5.50x |

## Reading the result

Across these 10 deliberately small kernels, JSC's single-context throughput is 0.36x
the zig-js throughput by geometric mean. These kernels deliberately exercise guarded native/VM tiers that
zig-js currently implements; rows outside those documented subsets continue through general bytecode paths.
The number is a compact description of this matrix, not a claim about applications or unsupported workloads.

At 8 independent warmed contexts, JSC throughput is 0.35x zig-js by
geometric mean; scaling from the mode's own one-lane baseline is 5.30x
for zig-js and 5.04x for JSC. In the symmetric cold lifecycle, JSC
throughput is 0.34x zig-js, with 5.41x
and 4.88x scaling respectively.

zig-js's shared-realm path scales 4.23x at 8 lanes from its
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
