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
| zig-js | ee079b274761916628c74fe6f76c28016d447caa |
| zig-gc | 87c5297e5e442b1f60fe14cab6484e44fd65c988 |
| zig-regex | 50764b0352e73a434278de38825dbb55464f1cf6 |
| JavaScriptCore | system framework 22625.1.20.11.3 |
| Power | Now drawing from 'Battery Power' -InternalBattery-0 (id=22806627) 83%; discharging; (no estimate) present: true |

## Single-thread result

Each row runs the same number of jobs in one GC-enabled zig-js context and one warmed JSC global context.
Both runners time the exact invocation `__benchmarkSelected(__benchmarkJobs, __benchmarkLane)`.
Lower time is better; `JSC / zig-js` is JSC throughput divided by zig-js throughput. RSD is relative standard deviation.

| workload | jobs | zig-js median (ms) | zig-js min–max (ms) | zig-js RSD | JSC median (ms) | JSC min–max (ms) | JSC RSD | JSC / zig-js |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `arithmetic` | 240 | 82.620 | 82.564–86.309 | 1.66% | 351.164 | 349.315–384.974 | 3.59% | 0.24x |
| `properties` | 300 | 95.347 | 95.102–95.481 | 0.16% | 291.019 | 290.783–335.569 | 5.59% | 0.33x |
| `polymorphic_properties` | 400 | 97.700 | 95.639–112.378 | 5.94% | 209.031 | 207.497–213.464 | 0.99% | 0.47x |
| `object_churn` | 100 | 89.223 | 88.951–94.549 | 2.68% | 120.483 | 119.281–175.572 | 16.07% | 0.74x |
| `arrays` | 550 | 91.493 | 90.454–93.218 | 1.03% | 152.330 | 151.106–156.087 | 1.11% | 0.60x |
| `direct_calls` | 600 | 77.444 | 77.316–77.755 | 0.19% | 119.702 | 115.978–120.688 | 1.76% | 0.65x |
| `method_calls` | 500 | 89.819 | 89.718–89.882 | 0.07% | 137.087 | 136.664–149.588 | 3.40% | 0.66x |
| `closure_calls` | 600 | 90.125 | 84.251–95.501 | 4.40% | 209.932 | 208.702–224.797 | 3.28% | 0.43x |
| `arguments_calls` | 600 | 91.467 | 91.275–91.790 | 0.18% | 309.319 | 307.600–312.079 | 0.44% | 0.30x |
| `fibonacci` | 125 | 92.864 | 86.606–100.116 | 5.86% | 465.310 | 464.193–466.168 | 0.14% | 0.20x |

## Independent-context steady state

Both engines keep one warmed context on one persistent OS worker per lane. The timed region contains the
same semaphore dispatch, exact invocation, and completion wait. Every lane performs the full job count.
`scaling` uses the same engine and mode at one lane; cross-engine throughput is directly comparable.

| workload | lanes | jobs/lane | zig-js median (ms) | zig-js min–max (ms) | zig-js RSD | JSC median (ms) | JSC min–max (ms) | JSC RSD | JSC / zig-js | zig-js scaling | JSC scaling |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `arithmetic` | 1 | 240 | 82.934 | 82.626–86.028 | 1.47% | 350.014 | 348.293–354.230 | 0.52% | 0.24x | 1.00x | 1.00x |
| `arithmetic` | 2 | 240 | 84.518 | 84.498–85.154 | 0.29% | 359.985 | 358.313–398.480 | 4.09% | 0.23x | 1.96x | 1.94x |
| `arithmetic` | 4 | 240 | 85.837 | 85.667–85.950 | 0.13% | 379.135 | 365.922–400.790 | 3.49% | 0.23x | 3.86x | 3.69x |
| `arithmetic` | 8 | 240 | 111.897 | 103.497–118.668 | 5.35% | 522.087 | 510.951–548.570 | 2.49% | 0.21x | 5.93x | 5.36x |
| `properties` | 1 | 300 | 95.138 | 95.003–95.280 | 0.12% | 290.321 | 290.149–293.704 | 0.44% | 0.33x | 1.00x | 1.00x |
| `properties` | 2 | 300 | 98.468 | 97.922–104.200 | 2.74% | 309.935 | 297.630–328.388 | 3.37% | 0.32x | 1.93x | 1.87x |
| `properties` | 4 | 300 | 101.164 | 100.179–102.536 | 0.79% | 316.614 | 308.806–322.882 | 1.38% | 0.32x | 3.76x | 3.67x |
| `properties` | 8 | 300 | 125.562 | 125.017–130.241 | 1.46% | 443.502 | 433.188–456.386 | 1.87% | 0.28x | 6.06x | 5.24x |
| `polymorphic_properties` | 1 | 400 | 93.956 | 93.850–94.434 | 0.20% | 203.439 | 203.187–203.936 | 0.14% | 0.46x | 1.00x | 1.00x |
| `polymorphic_properties` | 2 | 400 | 97.370 | 96.630–103.052 | 2.64% | 207.095 | 206.785–217.401 | 1.84% | 0.47x | 1.93x | 1.96x |
| `polymorphic_properties` | 4 | 400 | 110.078 | 97.941–121.017 | 7.31% | 230.553 | 214.683–293.287 | 11.05% | 0.48x | 3.41x | 3.53x |
| `polymorphic_properties` | 8 | 400 | 155.439 | 145.972–177.900 | 6.99% | 339.326 | 331.319–359.089 | 2.86% | 0.46x | 4.84x | 4.80x |
| `object_churn` | 1 | 100 | 89.451 | 88.113–96.223 | 3.18% | 120.356 | 119.518–122.504 | 0.85% | 0.74x | 1.00x | 1.00x |
| `object_churn` | 2 | 100 | 91.073 | 88.856–198.987 | 38.18% | 123.985 | 121.076–152.207 | 8.62% | 0.73x | 1.96x | 1.94x |
| `object_churn` | 4 | 100 | 93.459 | 92.351–109.825 | 7.19% | 123.063 | 122.308–139.845 | 5.25% | 0.76x | 3.83x | 3.91x |
| `object_churn` | 8 | 100 | 210.643 | 196.634–221.985 | 3.79% | 180.245 | 174.553–193.738 | 3.95% | 1.17x | 3.40x | 5.34x |
| `arrays` | 1 | 550 | 90.247 | 88.037–91.631 | 1.49% | 153.249 | 151.209–154.689 | 0.91% | 0.59x | 1.00x | 1.00x |
| `arrays` | 2 | 550 | 96.745 | 94.045–98.721 | 1.85% | 157.564 | 156.300–174.386 | 4.55% | 0.61x | 1.87x | 1.95x |
| `arrays` | 4 | 550 | 129.011 | 124.127–144.811 | 5.67% | 160.769 | 157.690–222.064 | 13.36% | 0.80x | 2.80x | 3.81x |
| `arrays` | 8 | 550 | 186.876 | 151.024–212.795 | 14.94% | 242.845 | 239.501–357.057 | 16.33% | 0.77x | 3.86x | 5.05x |
| `direct_calls` | 1 | 600 | 78.267 | 78.171–78.373 | 0.08% | 118.848 | 116.190–120.574 | 1.56% | 0.66x | 1.00x | 1.00x |
| `direct_calls` | 2 | 600 | 79.493 | 79.109–79.632 | 0.27% | 122.723 | 120.544–125.798 | 1.33% | 0.65x | 1.97x | 1.94x |
| `direct_calls` | 4 | 600 | 81.109 | 80.993–81.217 | 0.11% | 124.299 | 121.526–151.972 | 9.86% | 0.65x | 3.86x | 3.82x |
| `direct_calls` | 8 | 600 | 101.823 | 96.214–104.604 | 3.19% | 180.444 | 173.087–188.538 | 2.63% | 0.56x | 6.15x | 5.27x |
| `method_calls` | 1 | 500 | 78.545 | 78.444–79.557 | 0.51% | 136.974 | 136.764–137.277 | 0.13% | 0.57x | 1.00x | 1.00x |
| `method_calls` | 2 | 500 | 90.796 | 83.554–122.954 | 15.07% | 144.077 | 139.961–154.345 | 3.98% | 0.63x | 1.73x | 1.90x |
| `method_calls` | 4 | 500 | 99.870 | 96.305–120.010 | 7.92% | 169.153 | 164.197–179.458 | 2.99% | 0.59x | 3.15x | 3.24x |
| `method_calls` | 8 | 500 | 189.252 | 130.987–256.299 | 22.48% | 238.313 | 226.555–314.592 | 13.38% | 0.79x | 3.32x | 4.60x |
| `closure_calls` | 1 | 600 | 86.469 | 84.363–102.938 | 7.38% | 196.170 | 194.044–220.698 | 4.64% | 0.44x | 1.00x | 1.00x |
| `closure_calls` | 2 | 600 | 107.992 | 95.989–119.282 | 9.31% | 200.274 | 198.365–204.785 | 1.16% | 0.54x | 1.60x | 1.96x |
| `closure_calls` | 4 | 600 | 125.167 | 114.221–132.107 | 4.75% | 265.317 | 251.442–293.159 | 7.04% | 0.47x | 2.76x | 2.96x |
| `closure_calls` | 8 | 600 | 140.620 | 129.168–143.388 | 3.58% | 354.540 | 338.470–379.839 | 3.79% | 0.40x | 4.92x | 4.43x |
| `arguments_calls` | 1 | 600 | 91.640 | 91.507–98.806 | 2.93% | 307.343 | 306.939–332.615 | 3.52% | 0.30x | 1.00x | 1.00x |
| `arguments_calls` | 2 | 600 | 91.847 | 91.666–92.537 | 0.32% | 314.452 | 313.637–314.885 | 0.14% | 0.29x | 2.00x | 1.95x |
| `arguments_calls` | 4 | 600 | 124.296 | 109.386–145.384 | 8.83% | 443.067 | 386.942–532.765 | 10.17% | 0.28x | 2.95x | 2.77x |
| `arguments_calls` | 8 | 600 | 121.729 | 118.824–137.135 | 5.07% | 536.569 | 518.782–558.216 | 2.24% | 0.23x | 6.02x | 4.58x |
| `fibonacci` | 1 | 125 | 86.073 | 85.773–88.101 | 0.96% | 488.990 | 467.875–551.774 | 5.72% | 0.18x | 1.00x | 1.00x |
| `fibonacci` | 2 | 125 | 91.530 | 90.661–100.425 | 3.72% | 468.572 | 465.833–487.778 | 1.61% | 0.20x | 1.88x | 2.09x |
| `fibonacci` | 4 | 125 | 131.709 | 125.613–154.306 | 6.99% | 538.422 | 527.799–580.654 | 3.38% | 0.24x | 2.61x | 3.63x |
| `fibonacci` | 8 | 125 | 129.989 | 127.225–144.818 | 4.49% | 714.533 | 690.831–944.262 | 12.93% | 0.18x | 5.30x | 5.47x |

## Independent-context cold lifecycle

Neither engine warms these contexts. The timer covers OS-thread creation, context creation, workload-source
evaluation and configuration, the exact invocation, context destruction, and OS-thread join on both sides.
`scaling` uses the same engine and cold lifecycle at one lane.

| workload | lanes | jobs/lane | zig-js median (ms) | zig-js min–max (ms) | zig-js RSD | JSC median (ms) | JSC min–max (ms) | JSC RSD | JSC / zig-js | zig-js scaling | JSC scaling |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `arithmetic` | 1 | 240 | 84.671 | 84.508–85.024 | 0.26% | 353.170 | 351.183–367.999 | 1.76% | 0.24x | 1.00x | 1.00x |
| `arithmetic` | 2 | 240 | 86.752 | 86.680–87.002 | 0.12% | 362.771 | 359.477–391.930 | 4.02% | 0.24x | 1.95x | 1.95x |
| `arithmetic` | 4 | 240 | 88.218 | 88.121–88.558 | 0.18% | 389.157 | 373.825–398.113 | 2.64% | 0.23x | 3.84x | 3.63x |
| `arithmetic` | 8 | 240 | 113.195 | 107.622–123.209 | 4.97% | 526.501 | 521.729–568.501 | 3.15% | 0.21x | 5.98x | 5.37x |
| `properties` | 1 | 300 | 102.262 | 99.952–108.561 | 3.27% | 304.755 | 295.694–340.140 | 5.04% | 0.34x | 1.00x | 1.00x |
| `properties` | 2 | 300 | 104.118 | 100.200–108.474 | 2.97% | 305.463 | 299.695–339.478 | 4.73% | 0.34x | 1.96x | 2.00x |
| `properties` | 4 | 300 | 103.636 | 103.299–104.525 | 0.41% | 318.239 | 315.675–350.199 | 3.81% | 0.33x | 3.95x | 3.83x |
| `properties` | 8 | 300 | 153.997 | 137.426–175.210 | 10.70% | 471.907 | 464.230–699.265 | 16.88% | 0.33x | 5.31x | 5.17x |
| `polymorphic_properties` | 1 | 400 | 96.225 | 96.048–96.520 | 0.18% | 204.282 | 204.048–219.605 | 2.80% | 0.47x | 1.00x | 1.00x |
| `polymorphic_properties` | 2 | 400 | 98.620 | 98.109–125.354 | 9.82% | 210.579 | 207.871–215.014 | 1.35% | 0.47x | 1.95x | 1.94x |
| `polymorphic_properties` | 4 | 400 | 139.938 | 115.603–321.336 | 47.89% | 288.424 | 224.036–318.183 | 13.57% | 0.49x | 2.75x | 2.83x |
| `polymorphic_properties` | 8 | 400 | 155.756 | 154.744–171.215 | 4.07% | 343.170 | 336.901–416.044 | 7.81% | 0.45x | 4.94x | 4.76x |
| `object_churn` | 1 | 100 | 118.160 | 92.068–246.786 | 44.04% | 125.059 | 119.838–214.258 | 24.90% | 0.94x | 1.00x | 1.00x |
| `object_churn` | 2 | 100 | 95.473 | 92.887–132.457 | 15.93% | 312.597 | 121.873–336.016 | 39.50% | 0.31x | 2.48x | 0.80x |
| `object_churn` | 4 | 100 | 97.586 | 96.643–116.922 | 7.27% | 128.292 | 124.252–144.001 | 5.28% | 0.76x | 4.84x | 3.90x |
| `object_churn` | 8 | 100 | 163.456 | 159.395–190.564 | 6.30% | 191.581 | 184.702–228.572 | 7.50% | 0.85x | 5.78x | 5.22x |
| `arrays` | 1 | 550 | 88.442 | 87.733–89.447 | 0.63% | 153.902 | 152.295–155.105 | 0.64% | 0.57x | 1.00x | 1.00x |
| `arrays` | 2 | 550 | 97.452 | 95.951–103.742 | 2.67% | 156.451 | 155.437–159.311 | 0.79% | 0.62x | 1.82x | 1.97x |
| `arrays` | 4 | 550 | 129.259 | 107.567–134.748 | 8.60% | 160.019 | 159.077–171.225 | 2.70% | 0.81x | 2.74x | 3.85x |
| `arrays` | 8 | 550 | 146.788 | 143.276–152.487 | 2.71% | 255.541 | 247.874–264.300 | 2.24% | 0.57x | 4.82x | 4.82x |
| `direct_calls` | 1 | 600 | 79.683 | 79.141–83.281 | 1.78% | 120.140 | 117.166–159.519 | 12.08% | 0.66x | 1.00x | 1.00x |
| `direct_calls` | 2 | 600 | 82.500 | 81.314–96.033 | 6.19% | 122.947 | 121.193–124.627 | 1.10% | 0.67x | 1.93x | 1.95x |
| `direct_calls` | 4 | 600 | 86.206 | 82.017–96.147 | 6.38% | 129.016 | 124.898–163.139 | 10.24% | 0.67x | 3.70x | 3.72x |
| `direct_calls` | 8 | 600 | 98.872 | 98.355–102.636 | 1.62% | 183.626 | 179.597–188.174 | 1.40% | 0.54x | 6.45x | 5.23x |
| `method_calls` | 1 | 500 | 80.665 | 80.174–84.275 | 1.93% | 138.477 | 137.366–139.616 | 0.58% | 0.58x | 1.00x | 1.00x |
| `method_calls` | 2 | 500 | 94.025 | 91.706–110.580 | 8.11% | 162.145 | 154.367–172.045 | 3.76% | 0.58x | 1.72x | 1.71x |
| `method_calls` | 4 | 500 | 97.034 | 94.145–111.700 | 6.27% | 174.868 | 160.160–282.675 | 22.23% | 0.55x | 3.33x | 3.17x |
| `method_calls` | 8 | 500 | 161.377 | 136.048–188.476 | 11.02% | 289.420 | 283.697–364.563 | 9.80% | 0.56x | 4.00x | 3.83x |
| `closure_calls` | 1 | 600 | 101.773 | 95.795–109.494 | 4.31% | 212.765 | 211.509–213.957 | 0.41% | 0.48x | 1.00x | 1.00x |
| `closure_calls` | 2 | 600 | 87.675 | 87.063–120.497 | 13.27% | 201.006 | 197.103–205.080 | 1.47% | 0.44x | 2.32x | 2.12x |
| `closure_calls` | 4 | 600 | 120.464 | 109.433–144.244 | 10.13% | 269.998 | 255.403–314.193 | 8.75% | 0.45x | 3.38x | 3.15x |
| `closure_calls` | 8 | 600 | 113.854 | 112.790–121.520 | 2.94% | 355.157 | 339.032–380.108 | 3.50% | 0.32x | 7.15x | 4.79x |
| `arguments_calls` | 1 | 600 | 93.375 | 93.195–93.658 | 0.17% | 309.852 | 308.479–319.297 | 1.26% | 0.30x | 1.00x | 1.00x |
| `arguments_calls` | 2 | 600 | 96.221 | 94.129–113.381 | 6.84% | 422.553 | 325.560–660.508 | 27.01% | 0.23x | 1.94x | 1.47x |
| `arguments_calls` | 4 | 600 | 107.753 | 103.243–139.815 | 11.69% | 409.104 | 389.596–445.040 | 4.47% | 0.26x | 3.47x | 3.03x |
| `arguments_calls` | 8 | 600 | 127.094 | 123.477–131.938 | 2.58% | 600.600 | 533.823–682.248 | 9.57% | 0.21x | 5.88x | 4.13x |
| `fibonacci` | 1 | 125 | 87.607 | 87.269–98.187 | 4.41% | 466.181 | 464.090–468.005 | 0.29% | 0.19x | 1.00x | 1.00x |
| `fibonacci` | 2 | 125 | 97.859 | 87.628–101.200 | 4.64% | 468.267 | 466.555–493.436 | 2.06% | 0.21x | 1.79x | 1.99x |
| `fibonacci` | 4 | 125 | 99.836 | 99.035–103.694 | 1.92% | 540.172 | 535.060–576.630 | 2.67% | 0.18x | 3.51x | 3.45x |
| `fibonacci` | 8 | 125 | 155.558 | 126.711–205.768 | 17.34% | 727.657 | 708.890–1111.938 | 18.70% | 0.21x | 4.51x | 5.13x |

## zig-js shared-realm scaling

This is zig-js's distinct no-GIL shared-object-graph model, which JSC's public C API does not provide.
The timed region creates JavaScript `Thread`s, performs the work, and joins them. Scaling uses the same
shared-realm path at one lane, so thread lifecycle overhead is present in every row.

| workload | lanes | jobs/lane | median (ms) | min–max (ms) | RSD | scaling |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `arithmetic` | 1 | 240 | 1474.047 | 1470.625–1497.312 | 0.75% | 1.00x |
| `arithmetic` | 2 | 240 | 1508.588 | 1502.801–1531.345 | 0.63% | 1.95x |
| `arithmetic` | 4 | 240 | 1526.814 | 1523.592–1546.863 | 0.67% | 3.86x |
| `arithmetic` | 8 | 240 | 1942.086 | 1881.739–1988.035 | 2.38% | 6.07x |
| `properties` | 1 | 300 | 137.291 | 136.884–142.248 | 1.70% | 1.00x |
| `properties` | 2 | 300 | 139.426 | 139.224–141.733 | 0.73% | 1.97x |
| `properties` | 4 | 300 | 143.842 | 141.064–144.120 | 0.75% | 3.82x |
| `properties` | 8 | 300 | 205.062 | 188.913–206.510 | 4.11% | 5.36x |
| `polymorphic_properties` | 1 | 400 | 600.163 | 598.197–617.932 | 1.15% | 1.00x |
| `polymorphic_properties` | 2 | 400 | 619.236 | 610.935–664.050 | 3.10% | 1.94x |
| `polymorphic_properties` | 4 | 400 | 654.817 | 643.451–670.514 | 1.38% | 3.67x |
| `polymorphic_properties` | 8 | 400 | 860.929 | 842.481–1068.490 | 9.73% | 5.58x |
| `object_churn` | 1 | 100 | 167.593 | 162.700–322.618 | 32.33% | 1.00x |
| `object_churn` | 2 | 100 | 240.703 | 128.335–258.529 | 20.03% | 1.39x |
| `object_churn` | 4 | 100 | 412.671 | 262.614–549.457 | 22.20% | 1.62x |
| `object_churn` | 8 | 100 | 1648.219 | 1323.769–1960.373 | 13.22% | 0.81x |
| `arrays` | 1 | 550 | 96.868 | 95.790–99.758 | 1.40% | 1.00x |
| `arrays` | 2 | 550 | 100.704 | 100.159–102.339 | 0.87% | 1.92x |
| `arrays` | 4 | 550 | 115.581 | 110.970–122.633 | 3.93% | 3.35x |
| `arrays` | 8 | 550 | 304.039 | 295.669–351.060 | 7.13% | 2.55x |
| `direct_calls` | 1 | 600 | 81.718 | 81.583–82.322 | 0.30% | 1.00x |
| `direct_calls` | 2 | 600 | 83.390 | 83.149–95.724 | 5.48% | 1.96x |
| `direct_calls` | 4 | 600 | 84.883 | 83.289–104.034 | 8.87% | 3.85x |
| `direct_calls` | 8 | 600 | 101.724 | 100.669–106.565 | 1.89% | 6.43x |
| `method_calls` | 1 | 500 | 169.037 | 167.816–175.103 | 1.52% | 1.00x |
| `method_calls` | 2 | 500 | 175.546 | 168.605–179.301 | 1.87% | 1.93x |
| `method_calls` | 4 | 500 | 221.947 | 190.394–296.189 | 15.69% | 3.05x |
| `method_calls` | 8 | 500 | 307.492 | 285.364–406.212 | 15.78% | 4.40x |
| `closure_calls` | 1 | 600 | 106.139 | 99.715–118.527 | 6.75% | 1.00x |
| `closure_calls` | 2 | 600 | 87.016 | 85.743–102.756 | 6.89% | 2.44x |
| `closure_calls` | 4 | 600 | 123.423 | 115.345–129.661 | 4.74% | 3.44x |
| `closure_calls` | 8 | 600 | 117.515 | 113.827–120.628 | 2.16% | 7.23x |
| `arguments_calls` | 1 | 600 | 91.813 | 91.493–93.144 | 0.72% | 1.00x |
| `arguments_calls` | 2 | 600 | 99.220 | 95.632–112.964 | 6.10% | 1.85x |
| `arguments_calls` | 4 | 600 | 103.125 | 101.488–105.653 | 1.38% | 3.56x |
| `arguments_calls` | 8 | 600 | 129.560 | 119.725–154.968 | 8.51% | 5.67x |
| `fibonacci` | 1 | 125 | 302.461 | 300.293–326.608 | 3.04% | 1.00x |
| `fibonacci` | 2 | 125 | 346.861 | 302.096–372.022 | 9.49% | 1.74x |
| `fibonacci` | 4 | 125 | 336.852 | 331.361–343.340 | 1.47% | 3.59x |
| `fibonacci` | 8 | 125 | 566.443 | 475.157–778.217 | 17.99% | 4.27x |

## Reading the result

Across these 10 deliberately small kernels, JSC's single-context throughput is 0.42x
the zig-js throughput by geometric mean. These kernels deliberately exercise guarded native/VM tiers that
zig-js currently implements; rows outside those documented subsets continue through general bytecode paths.
The number is a compact description of this matrix, not a claim about applications or unsupported workloads.

At 8 independent warmed contexts, JSC throughput is 0.42x zig-js by
geometric mean; scaling from the mode's own one-lane baseline is 4.86x
for zig-js and 5.00x for JSC. In the symmetric cold lifecycle, JSC
throughput is 0.38x zig-js, with 5.41x
and 4.82x scaling respectively.

zig-js's shared-realm path scales 4.24x at 8 lanes from its
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

Raw samples: [`benchmark-comparison-2026-07-17-vm-run-leases.tsv`](benchmark-comparison-2026-07-17-vm-run-leases.tsv)
