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
| zig-js | 2dac7acaeef8fe45a8c9988226aa0ef8f6375712 |
| JavaScriptCore | system framework 22625.1.20.11.3 |
| Power | Now drawing from 'Battery Power' -InternalBattery-0 (id=22806627) 75%; discharging; (no estimate) present: true |

## Single-thread result

Each row runs the same number of jobs in one GC-enabled zig-js context and one warmed JSC global context.
Both runners time the exact invocation `__benchmarkSelected(__benchmarkJobs, __benchmarkLane)`.
Lower time is better; `JSC / zig-js` is JSC throughput divided by zig-js throughput. RSD is relative standard deviation.

| workload | jobs | zig-js median (ms) | zig-js min–max (ms) | zig-js RSD | JSC median (ms) | JSC min–max (ms) | JSC RSD | JSC / zig-js |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `arithmetic` | 240 | 75.493 | 75.427–81.357 | 3.12% | 345.936 | 342.907–355.376 | 1.21% | 0.22x |
| `properties` | 300 | 85.434 | 85.358–85.526 | 0.07% | 285.950 | 285.707–289.296 | 0.46% | 0.30x |
| `polymorphic_properties` | 400 | 80.600 | 80.425–81.365 | 0.42% | 198.593 | 198.101–204.165 | 1.07% | 0.41x |
| `object_churn` | 100 | 148.758 | 148.521–152.750 | 1.02% | 114.187 | 114.055–116.958 | 0.91% | 1.30x |
| `arrays` | 550 | 81.063 | 80.377–83.229 | 1.23% | 156.206 | 151.074–160.599 | 2.22% | 0.52x |
| `direct_calls` | 600 | 56.518 | 55.558–56.977 | 0.99% | 118.742 | 115.185–120.649 | 1.79% | 0.48x |
| `method_calls` | 500 | 60.936 | 60.455–61.180 | 0.39% | 136.774 | 136.450–141.111 | 1.23% | 0.45x |
| `closure_calls` | 600 | 63.075 | 62.144–68.969 | 3.67% | 187.108 | 186.578–188.042 | 0.32% | 0.34x |
| `arguments_calls` | 600 | 66.456 | 66.340–66.728 | 0.20% | 299.922 | 293.988–325.884 | 4.25% | 0.22x |
| `fibonacci` | 125 | 82.211 | 82.137–82.346 | 0.08% | 458.377 | 448.317–470.268 | 1.85% | 0.18x |

## Independent-context steady state

Both engines keep one warmed context on one persistent OS worker per lane. The timed region contains the
same semaphore dispatch, exact invocation, and completion wait. Every lane performs the full job count.
`scaling` uses the same engine and mode at one lane; cross-engine throughput is directly comparable.

| workload | lanes | jobs/lane | zig-js median (ms) | zig-js min–max (ms) | zig-js RSD | JSC median (ms) | JSC min–max (ms) | JSC RSD | JSC / zig-js | zig-js scaling | JSC scaling |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `arithmetic` | 1 | 240 | 82.152 | 75.605–85.292 | 5.71% | 355.421 | 342.918–360.320 | 1.92% | 0.23x | 1.00x | 1.00x |
| `arithmetic` | 2 | 240 | 82.651 | 82.553–85.654 | 1.41% | 353.377 | 350.337–383.016 | 3.88% | 0.23x | 1.99x | 2.01x |
| `arithmetic` | 4 | 240 | 84.634 | 84.492–89.385 | 2.08% | 365.682 | 359.588–378.980 | 2.05% | 0.23x | 3.88x | 3.89x |
| `arithmetic` | 8 | 240 | 100.466 | 98.483–108.234 | 3.26% | 481.092 | 474.381–497.239 | 1.76% | 0.21x | 6.54x | 5.91x |
| `properties` | 1 | 300 | 85.505 | 85.332–86.442 | 0.57% | 284.905 | 284.717–288.482 | 0.48% | 0.30x | 1.00x | 1.00x |
| `properties` | 2 | 300 | 87.416 | 87.155–89.306 | 0.86% | 290.653 | 290.554–291.032 | 0.08% | 0.30x | 1.96x | 1.96x |
| `properties` | 4 | 300 | 89.283 | 89.165–89.357 | 0.09% | 297.924 | 297.744–298.313 | 0.07% | 0.30x | 3.83x | 3.83x |
| `properties` | 8 | 300 | 109.400 | 108.880–111.156 | 0.96% | 393.918 | 388.396–399.996 | 1.10% | 0.28x | 6.25x | 5.79x |
| `polymorphic_properties` | 1 | 400 | 79.829 | 79.475–81.768 | 1.27% | 198.800 | 198.693–199.096 | 0.07% | 0.40x | 1.00x | 1.00x |
| `polymorphic_properties` | 2 | 400 | 82.017 | 81.851–84.046 | 1.12% | 202.708 | 202.220–206.657 | 0.75% | 0.40x | 1.95x | 1.96x |
| `polymorphic_properties` | 4 | 400 | 85.448 | 85.366–86.891 | 0.64% | 207.541 | 207.139–212.040 | 0.84% | 0.41x | 3.74x | 3.83x |
| `polymorphic_properties` | 8 | 400 | 115.894 | 114.260–120.370 | 2.15% | 283.491 | 274.776–307.574 | 3.80% | 0.41x | 5.51x | 5.61x |
| `object_churn` | 1 | 100 | 150.315 | 149.038–151.233 | 0.56% | 114.513 | 114.281–115.047 | 0.29% | 1.31x | 1.00x | 1.00x |
| `object_churn` | 2 | 100 | 156.342 | 155.634–161.867 | 1.40% | 119.629 | 117.792–122.020 | 1.12% | 1.31x | 1.92x | 1.91x |
| `object_churn` | 4 | 100 | 196.501 | 192.949–201.838 | 1.78% | 122.251 | 120.521–141.984 | 6.15% | 1.61x | 3.06x | 3.75x |
| `object_churn` | 8 | 100 | 505.387 | 496.430–532.123 | 2.90% | 177.359 | 169.692–188.459 | 3.20% | 2.85x | 2.38x | 5.17x |
| `arrays` | 1 | 550 | 76.432 | 76.084–76.756 | 0.31% | 148.627 | 147.968–149.760 | 0.45% | 0.51x | 1.00x | 1.00x |
| `arrays` | 2 | 550 | 79.329 | 78.868–83.171 | 1.99% | 150.232 | 149.867–177.197 | 6.42% | 0.53x | 1.93x | 1.98x |
| `arrays` | 4 | 550 | 89.040 | 83.000–91.257 | 3.14% | 156.319 | 154.557–166.561 | 2.56% | 0.57x | 3.43x | 3.80x |
| `arrays` | 8 | 550 | 116.909 | 112.035–121.571 | 2.88% | 244.100 | 230.462–250.438 | 3.09% | 0.48x | 5.23x | 4.87x |
| `direct_calls` | 1 | 600 | 57.753 | 57.573–68.834 | 7.00% | 117.800 | 115.794–119.928 | 1.12% | 0.49x | 1.00x | 1.00x |
| `direct_calls` | 2 | 600 | 56.778 | 56.605–57.641 | 0.63% | 121.316 | 118.004–131.236 | 3.51% | 0.47x | 2.03x | 1.94x |
| `direct_calls` | 4 | 600 | 66.448 | 61.507–72.081 | 6.27% | 127.288 | 123.158–133.270 | 3.25% | 0.52x | 3.48x | 3.70x |
| `direct_calls` | 8 | 600 | 79.470 | 75.477–84.241 | 4.03% | 192.317 | 183.045–205.730 | 3.53% | 0.41x | 5.81x | 4.90x |
| `method_calls` | 1 | 500 | 63.587 | 61.720–71.667 | 5.24% | 138.866 | 138.176–146.779 | 2.26% | 0.46x | 1.00x | 1.00x |
| `method_calls` | 2 | 500 | 65.969 | 64.044–66.413 | 1.37% | 141.461 | 139.312–144.428 | 1.26% | 0.47x | 1.93x | 1.96x |
| `method_calls` | 4 | 500 | 66.341 | 65.268–69.875 | 2.77% | 149.096 | 145.308–152.358 | 1.73% | 0.44x | 3.83x | 3.73x |
| `method_calls` | 8 | 500 | 92.473 | 87.510–116.557 | 10.79% | 226.364 | 218.699–235.670 | 2.45% | 0.41x | 5.50x | 4.91x |
| `closure_calls` | 1 | 600 | 62.218 | 61.867–64.690 | 1.61% | 187.969 | 186.626–212.653 | 5.36% | 0.33x | 1.00x | 1.00x |
| `closure_calls` | 2 | 600 | 69.622 | 67.644–78.750 | 6.03% | 219.012 | 202.301–233.398 | 4.60% | 0.32x | 1.79x | 1.72x |
| `closure_calls` | 4 | 600 | 69.104 | 66.357–69.179 | 1.49% | 208.748 | 206.092–219.191 | 2.31% | 0.33x | 3.60x | 3.60x |
| `closure_calls` | 8 | 600 | 82.376 | 78.688–87.263 | 4.36% | 307.695 | 306.482–312.217 | 0.67% | 0.27x | 6.04x | 4.89x |
| `arguments_calls` | 1 | 600 | 70.155 | 68.219–72.911 | 1.98% | 296.468 | 293.463–308.590 | 1.79% | 0.24x | 1.00x | 1.00x |
| `arguments_calls` | 2 | 600 | 75.130 | 69.845–83.126 | 5.46% | 306.010 | 304.707–322.327 | 2.01% | 0.25x | 1.87x | 1.94x |
| `arguments_calls` | 4 | 600 | 70.726 | 70.059–73.517 | 1.93% | 333.455 | 328.122–356.789 | 2.96% | 0.21x | 3.97x | 3.56x |
| `arguments_calls` | 8 | 600 | 92.817 | 90.246–102.551 | 5.37% | 503.455 | 491.136–781.793 | 20.12% | 0.18x | 6.05x | 4.71x |
| `fibonacci` | 1 | 125 | 83.424 | 82.491–85.523 | 1.38% | 448.772 | 447.090–480.987 | 2.71% | 0.19x | 1.00x | 1.00x |
| `fibonacci` | 2 | 125 | 84.252 | 84.056–88.473 | 1.90% | 473.301 | 455.093–490.059 | 3.01% | 0.18x | 1.98x | 1.90x |
| `fibonacci` | 4 | 125 | 87.924 | 86.173–108.644 | 10.38% | 466.667 | 465.191–537.397 | 5.72% | 0.19x | 3.80x | 3.85x |
| `fibonacci` | 8 | 125 | 120.485 | 116.223–128.782 | 3.78% | 693.256 | 647.700–708.703 | 3.76% | 0.17x | 5.54x | 5.18x |

## Independent-context cold lifecycle

Neither engine warms these contexts. The timer covers OS-thread creation, context creation, workload-source
evaluation and configuration, the exact invocation, context destruction, and OS-thread join on both sides.
`scaling` uses the same engine and cold lifecycle at one lane.

| workload | lanes | jobs/lane | zig-js median (ms) | zig-js min–max (ms) | zig-js RSD | JSC median (ms) | JSC min–max (ms) | JSC RSD | JSC / zig-js | zig-js scaling | JSC scaling |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `arithmetic` | 1 | 240 | 82.368 | 76.968–82.847 | 3.33% | 345.085 | 343.004–356.089 | 1.27% | 0.24x | 1.00x | 1.00x |
| `arithmetic` | 2 | 240 | 84.336 | 84.312–84.830 | 0.22% | 352.928 | 350.080–382.183 | 3.23% | 0.24x | 1.95x | 1.96x |
| `arithmetic` | 4 | 240 | 86.432 | 86.302–87.244 | 0.38% | 386.057 | 363.258–397.204 | 4.03% | 0.22x | 3.81x | 3.58x |
| `arithmetic` | 8 | 240 | 100.688 | 100.141–101.285 | 0.36% | 489.407 | 479.636–514.489 | 2.42% | 0.21x | 6.54x | 5.64x |
| `properties` | 1 | 300 | 86.708 | 86.432–87.192 | 0.34% | 286.507 | 285.898–303.530 | 2.23% | 0.30x | 1.00x | 1.00x |
| `properties` | 2 | 300 | 88.478 | 88.369–89.319 | 0.37% | 292.231 | 291.734–309.772 | 2.27% | 0.30x | 1.96x | 1.96x |
| `properties` | 4 | 300 | 90.599 | 90.461–91.433 | 0.38% | 299.141 | 298.832–335.945 | 4.58% | 0.30x | 3.83x | 3.83x |
| `properties` | 8 | 300 | 112.379 | 111.121–124.206 | 4.07% | 400.809 | 395.867–426.885 | 2.63% | 0.28x | 6.17x | 5.72x |
| `polymorphic_properties` | 1 | 400 | 81.592 | 81.123–89.559 | 3.67% | 199.518 | 199.338–200.996 | 0.37% | 0.41x | 1.00x | 1.00x |
| `polymorphic_properties` | 2 | 400 | 83.722 | 83.497–86.166 | 1.13% | 203.475 | 203.260–205.630 | 0.43% | 0.41x | 1.95x | 1.96x |
| `polymorphic_properties` | 4 | 400 | 85.537 | 85.492–86.146 | 0.27% | 208.755 | 208.016–210.564 | 0.46% | 0.41x | 3.82x | 3.82x |
| `polymorphic_properties` | 8 | 400 | 117.327 | 116.409–120.627 | 1.14% | 289.769 | 286.994–300.236 | 1.68% | 0.40x | 5.56x | 5.51x |
| `object_churn` | 1 | 100 | 149.238 | 148.472–150.621 | 0.58% | 115.037 | 114.542–116.705 | 0.64% | 1.30x | 1.00x | 1.00x |
| `object_churn` | 2 | 100 | 158.245 | 156.555–160.402 | 0.75% | 119.113 | 118.256–119.701 | 0.42% | 1.33x | 1.89x | 1.93x |
| `object_churn` | 4 | 100 | 199.501 | 197.684–208.810 | 1.92% | 122.046 | 121.625–125.070 | 0.98% | 1.63x | 2.99x | 3.77x |
| `object_churn` | 8 | 100 | 463.413 | 409.031–567.074 | 11.47% | 182.816 | 173.716–234.219 | 10.73% | 2.53x | 2.58x | 5.03x |
| `arrays` | 1 | 550 | 78.904 | 75.624–83.606 | 3.49% | 149.819 | 148.579–157.448 | 2.01% | 0.53x | 1.00x | 1.00x |
| `arrays` | 2 | 550 | 80.692 | 79.405–84.201 | 2.22% | 153.880 | 153.463–166.541 | 3.06% | 0.52x | 1.96x | 1.95x |
| `arrays` | 4 | 550 | 83.373 | 82.866–115.975 | 13.56% | 160.229 | 158.993–174.274 | 3.32% | 0.52x | 3.79x | 3.74x |
| `arrays` | 8 | 550 | 114.184 | 109.483–146.984 | 10.71% | 244.895 | 229.644–256.573 | 4.02% | 0.47x | 5.53x | 4.89x |
| `direct_calls` | 1 | 600 | 57.204 | 57.079–58.620 | 1.07% | 119.804 | 114.601–126.709 | 3.31% | 0.48x | 1.00x | 1.00x |
| `direct_calls` | 2 | 600 | 66.204 | 59.143–73.275 | 7.89% | 122.512 | 118.956–161.488 | 11.51% | 0.54x | 1.73x | 1.96x |
| `direct_calls` | 4 | 600 | 61.512 | 59.672–71.341 | 6.35% | 129.912 | 128.600–131.990 | 0.96% | 0.47x | 3.72x | 3.69x |
| `direct_calls` | 8 | 600 | 79.481 | 75.532–83.852 | 3.60% | 201.897 | 185.192–211.420 | 4.57% | 0.39x | 5.76x | 4.75x |
| `method_calls` | 1 | 500 | 63.365 | 62.995–66.844 | 2.62% | 139.036 | 137.484–146.421 | 2.89% | 0.46x | 1.00x | 1.00x |
| `method_calls` | 2 | 500 | 64.622 | 64.158–65.245 | 0.50% | 140.130 | 139.803–142.523 | 0.69% | 0.46x | 1.96x | 1.98x |
| `method_calls` | 4 | 500 | 65.637 | 65.352–72.774 | 4.05% | 149.927 | 146.394–178.947 | 7.39% | 0.44x | 3.86x | 3.71x |
| `method_calls` | 8 | 500 | 85.594 | 83.060–97.422 | 6.99% | 232.879 | 220.128–237.814 | 2.48% | 0.37x | 5.92x | 4.78x |
| `closure_calls` | 1 | 600 | 68.691 | 67.735–76.922 | 4.75% | 189.199 | 188.268–216.953 | 5.63% | 0.36x | 1.00x | 1.00x |
| `closure_calls` | 2 | 600 | 63.972 | 63.927–65.073 | 0.65% | 195.376 | 192.469–223.426 | 5.48% | 0.33x | 2.15x | 1.94x |
| `closure_calls` | 4 | 600 | 65.504 | 65.336–69.316 | 2.33% | 224.963 | 209.393–264.265 | 8.02% | 0.29x | 4.19x | 3.36x |
| `closure_calls` | 8 | 600 | 82.409 | 79.929–87.487 | 3.09% | 325.447 | 319.274–362.180 | 4.55% | 0.25x | 6.67x | 4.65x |
| `arguments_calls` | 1 | 600 | 72.179 | 68.557–78.728 | 5.25% | 320.589 | 305.840–334.959 | 3.30% | 0.23x | 1.00x | 1.00x |
| `arguments_calls` | 2 | 600 | 74.655 | 70.996–82.954 | 5.48% | 313.073 | 306.920–320.616 | 1.72% | 0.24x | 1.93x | 2.05x |
| `arguments_calls` | 4 | 600 | 72.707 | 71.292–90.507 | 9.18% | 342.085 | 323.578–362.394 | 3.83% | 0.21x | 3.97x | 3.75x |
| `arguments_calls` | 8 | 600 | 100.478 | 92.733–143.356 | 16.32% | 495.076 | 487.236–535.530 | 4.31% | 0.20x | 5.75x | 5.18x |
| `fibonacci` | 1 | 125 | 83.594 | 83.454–84.772 | 0.59% | 481.534 | 456.139–550.709 | 7.46% | 0.17x | 1.00x | 1.00x |
| `fibonacci` | 2 | 125 | 93.282 | 88.149–105.477 | 6.14% | 458.392 | 456.782–474.083 | 1.52% | 0.20x | 1.79x | 2.10x |
| `fibonacci` | 4 | 125 | 87.576 | 86.981–89.150 | 0.89% | 469.602 | 467.133–525.646 | 5.38% | 0.19x | 3.82x | 4.10x |
| `fibonacci` | 8 | 125 | 122.153 | 119.625–131.649 | 3.36% | 665.827 | 657.906–763.068 | 5.47% | 0.18x | 5.47x | 5.79x |

## zig-js shared-realm scaling

This is zig-js's distinct no-GIL shared-object-graph model, which JSC's public C API does not provide.
The timed region creates JavaScript `Thread`s, performs the work, and joins them. Scaling uses the same
shared-realm path at one lane, so thread lifecycle overhead is present in every row.

| workload | lanes | jobs/lane | median (ms) | min–max (ms) | RSD | scaling |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `arithmetic` | 1 | 240 | 80.947 | 75.679–81.171 | 2.51% | 1.00x |
| `arithmetic` | 2 | 240 | 82.696 | 82.656–84.052 | 0.74% | 1.96x |
| `arithmetic` | 4 | 240 | 84.608 | 84.603–84.770 | 0.07% | 3.83x |
| `arithmetic` | 8 | 240 | 98.987 | 98.195–100.755 | 0.93% | 6.54x |
| `properties` | 1 | 300 | 124.191 | 124.036–124.538 | 0.14% | 1.00x |
| `properties` | 2 | 300 | 126.521 | 126.386–126.567 | 0.05% | 1.96x |
| `properties` | 4 | 300 | 129.531 | 129.456–130.672 | 0.34% | 3.84x |
| `properties` | 8 | 300 | 159.208 | 157.931–162.387 | 1.12% | 6.24x |
| `polymorphic_properties` | 1 | 400 | 507.076 | 505.195–508.771 | 0.23% | 1.00x |
| `polymorphic_properties` | 2 | 400 | 515.797 | 514.481–518.741 | 0.28% | 1.97x |
| `polymorphic_properties` | 4 | 400 | 530.230 | 528.818–537.220 | 0.54% | 3.83x |
| `polymorphic_properties` | 8 | 400 | 676.708 | 663.501–705.118 | 2.22% | 5.99x |
| `object_churn` | 1 | 100 | 377.316 | 186.796–445.742 | 22.36% | 1.00x |
| `object_churn` | 2 | 100 | 741.069 | 351.685–863.702 | 22.98% | 1.02x |
| `object_churn` | 4 | 100 | 2316.414 | 857.477–3079.501 | 32.36% | 0.65x |
| `object_churn` | 8 | 100 | 9789.216 | 4234.067–11431.334 | 24.97% | 0.31x |
| `arrays` | 1 | 550 | 84.452 | 80.993–131.098 | 20.12% | 1.00x |
| `arrays` | 2 | 550 | 86.009 | 84.113–88.575 | 1.81% | 1.96x |
| `arrays` | 4 | 550 | 95.098 | 91.958–97.704 | 1.96% | 3.55x |
| `arrays` | 8 | 550 | 220.609 | 191.073–241.339 | 6.98% | 3.06x |
| `direct_calls` | 1 | 600 | 57.317 | 55.864–60.347 | 2.77% | 1.00x |
| `direct_calls` | 2 | 600 | 60.369 | 57.556–61.432 | 2.25% | 1.90x |
| `direct_calls` | 4 | 600 | 63.754 | 58.508–64.315 | 3.34% | 3.60x |
| `direct_calls` | 8 | 600 | 77.657 | 73.858–81.171 | 3.60% | 5.90x |
| `method_calls` | 1 | 500 | 122.815 | 115.303–123.183 | 2.68% | 1.00x |
| `method_calls` | 2 | 500 | 117.996 | 117.808–124.003 | 1.96% | 2.08x |
| `method_calls` | 4 | 500 | 129.338 | 122.680–130.115 | 2.25% | 3.80x |
| `method_calls` | 8 | 500 | 183.377 | 179.292–190.363 | 2.23% | 5.36x |
| `closure_calls` | 1 | 600 | 70.091 | 67.631–76.995 | 5.10% | 1.00x |
| `closure_calls` | 2 | 600 | 63.807 | 63.676–67.647 | 2.26% | 2.20x |
| `closure_calls` | 4 | 600 | 70.244 | 65.304–74.542 | 4.84% | 3.99x |
| `closure_calls` | 8 | 600 | 85.838 | 81.970–88.729 | 2.94% | 6.53x |
| `arguments_calls` | 1 | 600 | 68.470 | 67.242–75.566 | 4.77% | 1.00x |
| `arguments_calls` | 2 | 600 | 77.724 | 69.954–100.287 | 14.18% | 1.76x |
| `arguments_calls` | 4 | 600 | 96.847 | 92.259–135.457 | 15.56% | 2.83x |
| `arguments_calls` | 8 | 600 | 107.876 | 95.396–151.262 | 17.82% | 5.08x |
| `fibonacci` | 1 | 125 | 243.452 | 243.159–255.394 | 2.20% | 1.00x |
| `fibonacci` | 2 | 125 | 253.460 | 247.400–263.238 | 2.75% | 1.92x |
| `fibonacci` | 4 | 125 | 256.426 | 253.655–260.600 | 1.10% | 3.80x |
| `fibonacci` | 8 | 125 | 385.353 | 380.464–396.077 | 1.41% | 5.05x |

## Reading the result

Across these 10 deliberately small kernels, JSC's single-context throughput is 0.37x
the zig-js throughput by geometric mean. These kernels deliberately exercise guarded native/VM tiers that
zig-js currently implements; rows outside those documented subsets continue through general bytecode paths.
The number is a compact description of this matrix, not a claim about applications or unsupported workloads.

At 8 independent warmed contexts, JSC throughput is 0.37x zig-js by
geometric mean; scaling from the mode's own one-lane baseline is 5.32x
for zig-js and 5.18x for JSC. In the symmetric cold lifecycle, JSC
throughput is 0.36x zig-js, with 5.44x
and 5.18x scaling respectively.

zig-js's shared-realm path scales 4.06x at 8 lanes from its
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
