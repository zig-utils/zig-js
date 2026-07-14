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
| zig-js | 5f891bc838e4a44644517f01436f040a0e24d7c4 |
| JavaScriptCore | system framework 22625.1.20.11.3 |
| Power | Now drawing from 'AC Power' -InternalBattery-0 (id=22806627) 96%; charging; (no estimate) present: true |

## Single-thread result

Each row runs the same number of jobs in one GC-enabled zig-js context and one warmed JSC global context.
Both runners time the exact invocation `__benchmarkSelected(__benchmarkJobs, __benchmarkLane)`.
Lower time is better; `JSC / zig-js` is JSC throughput divided by zig-js throughput. RSD is relative standard deviation.

| workload | jobs | zig-js median (ms) | zig-js min–max (ms) | zig-js RSD | JSC median (ms) | JSC min–max (ms) | JSC RSD | JSC / zig-js |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `arithmetic` | 240 | 80.681 | 79.479–85.862 | 2.96% | 345.460 | 340.362–361.852 | 2.05% | 0.23x |
| `properties` | 300 | 86.082 | 85.362–89.822 | 2.38% | 286.917 | 285.659–296.713 | 1.54% | 0.30x |
| `polymorphic_properties` | 400 | 79.711 | 79.486–83.213 | 1.65% | 202.073 | 199.397–225.124 | 5.13% | 0.39x |
| `object_churn` | 100 | 150.652 | 150.045–157.177 | 1.65% | 114.952 | 114.148–117.759 | 1.26% | 1.31x |
| `arrays` | 550 | 77.984 | 76.807–80.864 | 2.06% | 149.256 | 148.823–156.644 | 2.19% | 0.52x |
| `direct_calls` | 600 | 57.509 | 55.234–68.366 | 8.07% | 115.254 | 113.947–118.361 | 1.49% | 0.50x |
| `method_calls` | 500 | 60.984 | 60.867–61.008 | 0.08% | 136.921 | 136.470–141.018 | 1.33% | 0.45x |
| `closure_calls` | 600 | 61.140 | 61.039–64.082 | 1.80% | 187.207 | 185.900–198.030 | 2.21% | 0.33x |
| `arguments_calls` | 600 | 70.848 | 67.025–78.508 | 5.33% | 295.448 | 293.753–298.615 | 0.60% | 0.24x |
| `fibonacci` | 125 | 82.023 | 81.874–87.972 | 2.80% | 450.667 | 446.268–455.187 | 0.77% | 0.18x |

## Independent-context steady state

Both engines keep one warmed context on one persistent OS worker per lane. The timed region contains the
same semaphore dispatch, exact invocation, and completion wait. Every lane performs the full job count.
`scaling` uses the same engine and mode at one lane; cross-engine throughput is directly comparable.

| workload | lanes | jobs/lane | zig-js median (ms) | zig-js min–max (ms) | zig-js RSD | JSC median (ms) | JSC min–max (ms) | JSC RSD | JSC / zig-js | zig-js scaling | JSC scaling |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `arithmetic` | 1 | 240 | 80.013 | 75.472–84.454 | 4.85% | 347.205 | 341.070–372.399 | 3.40% | 0.23x | 1.00x | 1.00x |
| `arithmetic` | 2 | 240 | 82.933 | 82.550–85.912 | 1.42% | 360.740 | 353.321–378.092 | 2.57% | 0.23x | 1.93x | 1.92x |
| `arithmetic` | 4 | 240 | 84.880 | 84.466–85.901 | 0.57% | 362.418 | 359.441–380.438 | 2.54% | 0.23x | 3.77x | 3.83x |
| `arithmetic` | 8 | 240 | 102.542 | 98.421–121.882 | 7.83% | 494.079 | 474.280–510.312 | 2.38% | 0.21x | 6.24x | 5.62x |
| `properties` | 1 | 300 | 86.223 | 85.533–89.655 | 1.79% | 286.678 | 286.260–288.412 | 0.29% | 0.30x | 1.00x | 1.00x |
| `properties` | 2 | 300 | 87.703 | 87.121–89.537 | 1.03% | 291.464 | 290.652–293.439 | 0.42% | 0.30x | 1.97x | 1.97x |
| `properties` | 4 | 300 | 89.516 | 89.295–90.509 | 0.49% | 306.282 | 297.190–357.277 | 6.73% | 0.29x | 3.85x | 3.74x |
| `properties` | 8 | 300 | 112.217 | 111.247–114.832 | 1.20% | 404.541 | 392.767–416.920 | 1.82% | 0.28x | 6.15x | 5.67x |
| `polymorphic_properties` | 1 | 400 | 79.662 | 79.582–82.658 | 1.38% | 198.804 | 198.566–207.853 | 1.83% | 0.40x | 1.00x | 1.00x |
| `polymorphic_properties` | 2 | 400 | 85.229 | 83.647–105.469 | 10.53% | 205.126 | 203.622–214.800 | 2.17% | 0.42x | 1.87x | 1.94x |
| `polymorphic_properties` | 4 | 400 | 83.539 | 83.397–86.547 | 1.38% | 207.383 | 206.989–264.567 | 9.81% | 0.40x | 3.81x | 3.83x |
| `polymorphic_properties` | 8 | 400 | 119.113 | 113.691–131.244 | 5.14% | 308.127 | 302.666–319.077 | 1.84% | 0.39x | 5.35x | 5.16x |
| `object_churn` | 1 | 100 | 149.512 | 149.114–155.559 | 1.89% | 114.152 | 113.850–118.484 | 1.45% | 1.31x | 1.00x | 1.00x |
| `object_churn` | 2 | 100 | 162.526 | 158.940–168.199 | 2.17% | 118.501 | 117.907–120.103 | 0.64% | 1.37x | 1.84x | 1.93x |
| `object_churn` | 4 | 100 | 201.119 | 196.917–310.748 | 18.53% | 122.035 | 120.930–124.692 | 1.13% | 1.65x | 2.97x | 3.74x |
| `object_churn` | 8 | 100 | 419.609 | 411.437–487.491 | 6.38% | 172.023 | 164.535–173.199 | 2.15% | 2.44x | 2.85x | 5.31x |
| `arrays` | 1 | 550 | 77.611 | 76.536–78.710 | 1.03% | 150.491 | 147.334–158.282 | 2.42% | 0.52x | 1.00x | 1.00x |
| `arrays` | 2 | 550 | 78.978 | 78.804–80.800 | 0.88% | 152.612 | 151.066–155.444 | 0.92% | 0.52x | 1.97x | 1.97x |
| `arrays` | 4 | 550 | 81.569 | 81.217–82.072 | 0.38% | 155.269 | 154.495–157.238 | 0.60% | 0.53x | 3.81x | 3.88x |
| `arrays` | 8 | 550 | 116.315 | 112.499–118.436 | 1.71% | 230.159 | 217.748–249.759 | 4.98% | 0.51x | 5.34x | 5.23x |
| `direct_calls` | 1 | 600 | 56.169 | 55.621–63.919 | 5.22% | 115.085 | 114.024–120.628 | 1.99% | 0.49x | 1.00x | 1.00x |
| `direct_calls` | 2 | 600 | 56.658 | 56.620–57.676 | 0.68% | 120.403 | 115.959–121.604 | 1.68% | 0.47x | 1.98x | 1.91x |
| `direct_calls` | 4 | 600 | 58.148 | 57.921–59.559 | 1.05% | 130.723 | 124.769–133.444 | 2.26% | 0.44x | 3.86x | 3.52x |
| `direct_calls` | 8 | 600 | 91.242 | 88.234–93.384 | 2.03% | 185.375 | 179.853–193.333 | 2.53% | 0.49x | 4.92x | 4.97x |
| `method_calls` | 1 | 500 | 62.892 | 61.342–64.902 | 1.92% | 137.950 | 136.741–140.432 | 0.98% | 0.46x | 1.00x | 1.00x |
| `method_calls` | 2 | 500 | 62.918 | 62.822–63.215 | 0.22% | 139.795 | 139.335–146.939 | 1.96% | 0.45x | 2.00x | 1.97x |
| `method_calls` | 4 | 500 | 65.660 | 65.495–69.172 | 2.42% | 145.479 | 142.817–149.591 | 1.46% | 0.45x | 3.83x | 3.79x |
| `method_calls` | 8 | 500 | 82.842 | 81.423–88.518 | 2.95% | 213.860 | 205.914–216.990 | 1.97% | 0.39x | 6.07x | 5.16x |
| `closure_calls` | 1 | 600 | 61.334 | 61.171–63.428 | 1.43% | 185.602 | 184.747–189.145 | 0.93% | 0.33x | 1.00x | 1.00x |
| `closure_calls` | 2 | 600 | 62.307 | 62.227–64.645 | 1.73% | 191.444 | 188.728–198.217 | 1.77% | 0.33x | 1.97x | 1.94x |
| `closure_calls` | 4 | 600 | 64.175 | 63.878–64.611 | 0.45% | 204.147 | 202.466–214.326 | 1.97% | 0.31x | 3.82x | 3.64x |
| `closure_calls` | 8 | 600 | 80.184 | 79.279–86.404 | 3.04% | 308.498 | 298.863–330.708 | 3.20% | 0.26x | 6.12x | 4.81x |
| `arguments_calls` | 1 | 600 | 66.563 | 66.152–71.041 | 2.67% | 294.744 | 293.487–300.475 | 0.95% | 0.23x | 1.00x | 1.00x |
| `arguments_calls` | 2 | 600 | 68.418 | 68.221–70.449 | 1.14% | 304.831 | 303.741–306.847 | 0.48% | 0.22x | 1.95x | 1.93x |
| `arguments_calls` | 4 | 600 | 75.396 | 72.188–85.067 | 7.55% | 328.204 | 320.007–331.576 | 1.29% | 0.23x | 3.53x | 3.59x |
| `arguments_calls` | 8 | 600 | 91.630 | 89.261–107.746 | 7.36% | 491.939 | 482.721–506.336 | 1.63% | 0.19x | 5.81x | 4.79x |
| `fibonacci` | 1 | 125 | 84.040 | 82.255–86.473 | 1.91% | 448.756 | 445.847–452.554 | 0.61% | 0.19x | 1.00x | 1.00x |
| `fibonacci` | 2 | 125 | 84.250 | 83.858–87.467 | 1.52% | 458.381 | 455.759–466.496 | 0.74% | 0.18x | 2.00x | 1.96x |
| `fibonacci` | 4 | 125 | 88.001 | 86.581–94.967 | 3.15% | 468.214 | 467.159–470.229 | 0.26% | 0.19x | 3.82x | 3.83x |
| `fibonacci` | 8 | 125 | 115.385 | 111.471–129.506 | 5.95% | 660.652 | 655.453–677.882 | 1.24% | 0.17x | 5.83x | 5.43x |

## Independent-context cold lifecycle

Neither engine warms these contexts. The timer covers OS-thread creation, context creation, workload-source
evaluation and configuration, the exact invocation, context destruction, and OS-thread join on both sides.
`scaling` uses the same engine and cold lifecycle at one lane.

| workload | lanes | jobs/lane | zig-js median (ms) | zig-js min–max (ms) | zig-js RSD | JSC median (ms) | JSC min–max (ms) | JSC RSD | JSC / zig-js | zig-js scaling | JSC scaling |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `arithmetic` | 1 | 240 | 78.805 | 76.870–82.755 | 3.02% | 363.976 | 348.006–379.562 | 3.33% | 0.22x | 1.00x | 1.00x |
| `arithmetic` | 2 | 240 | 84.509 | 79.062–85.376 | 2.62% | 354.704 | 351.664–377.801 | 2.83% | 0.24x | 1.87x | 2.05x |
| `arithmetic` | 4 | 240 | 86.570 | 86.352–87.667 | 0.59% | 373.199 | 361.644–392.046 | 3.37% | 0.23x | 3.64x | 3.90x |
| `arithmetic` | 8 | 240 | 103.131 | 100.581–105.646 | 1.75% | 495.015 | 479.927–505.126 | 1.63% | 0.21x | 6.11x | 5.88x |
| `properties` | 1 | 300 | 87.513 | 86.632–91.020 | 1.87% | 288.765 | 286.618–304.655 | 2.30% | 0.30x | 1.00x | 1.00x |
| `properties` | 2 | 300 | 89.100 | 88.673–94.666 | 2.36% | 293.395 | 291.937–310.107 | 2.17% | 0.30x | 1.96x | 1.97x |
| `properties` | 4 | 300 | 92.020 | 90.888–98.203 | 2.74% | 302.017 | 299.716–317.192 | 2.47% | 0.30x | 3.80x | 3.82x |
| `properties` | 8 | 300 | 114.049 | 111.184–119.812 | 2.54% | 413.508 | 404.851–474.833 | 5.70% | 0.28x | 6.14x | 5.59x |
| `polymorphic_properties` | 1 | 400 | 82.471 | 82.190–86.054 | 1.65% | 203.694 | 199.461–207.819 | 1.47% | 0.40x | 1.00x | 1.00x |
| `polymorphic_properties` | 2 | 400 | 84.324 | 84.101–86.452 | 0.99% | 204.605 | 203.255–206.403 | 0.55% | 0.41x | 1.96x | 1.99x |
| `polymorphic_properties` | 4 | 400 | 85.042 | 84.773–86.555 | 0.74% | 210.311 | 208.457–211.770 | 0.58% | 0.40x | 3.88x | 3.87x |
| `polymorphic_properties` | 8 | 400 | 118.280 | 114.178–121.772 | 2.14% | 305.830 | 301.577–315.098 | 1.73% | 0.39x | 5.58x | 5.33x |
| `object_churn` | 1 | 100 | 152.349 | 151.220–160.307 | 2.49% | 117.390 | 115.506–120.437 | 1.81% | 1.30x | 1.00x | 1.00x |
| `object_churn` | 2 | 100 | 168.233 | 162.056–172.775 | 2.31% | 119.237 | 119.015–123.338 | 1.66% | 1.41x | 1.81x | 1.97x |
| `object_churn` | 4 | 100 | 208.750 | 198.125–236.661 | 5.89% | 123.238 | 122.355–125.254 | 0.95% | 1.69x | 2.92x | 3.81x |
| `object_churn` | 8 | 100 | 417.247 | 409.674–425.790 | 1.30% | 171.305 | 169.380–174.857 | 1.01% | 2.44x | 2.92x | 5.48x |
| `arrays` | 1 | 550 | 75.746 | 75.385–82.412 | 3.34% | 150.287 | 148.714–154.503 | 1.32% | 0.50x | 1.00x | 1.00x |
| `arrays` | 2 | 550 | 78.591 | 78.313–83.166 | 2.20% | 155.569 | 152.974–159.562 | 1.34% | 0.51x | 1.93x | 1.93x |
| `arrays` | 4 | 550 | 81.225 | 80.900–85.365 | 2.00% | 157.346 | 155.582–159.973 | 0.89% | 0.52x | 3.73x | 3.82x |
| `arrays` | 8 | 550 | 113.343 | 111.383–128.134 | 4.96% | 239.259 | 233.276–245.987 | 1.64% | 0.47x | 5.35x | 5.03x |
| `direct_calls` | 1 | 600 | 57.060 | 56.951–59.645 | 1.76% | 117.619 | 114.585–125.029 | 2.71% | 0.49x | 1.00x | 1.00x |
| `direct_calls` | 2 | 600 | 72.453 | 72.327–79.154 | 3.45% | 125.169 | 121.425–128.126 | 1.85% | 0.58x | 1.58x | 1.88x |
| `direct_calls` | 4 | 600 | 60.445 | 60.006–76.709 | 10.57% | 132.677 | 126.613–136.370 | 2.63% | 0.46x | 3.78x | 3.55x |
| `direct_calls` | 8 | 600 | 79.195 | 76.333–81.799 | 2.28% | 195.459 | 186.936–223.743 | 6.30% | 0.41x | 5.76x | 4.81x |
| `method_calls` | 1 | 500 | 63.368 | 62.486–67.362 | 2.64% | 137.435 | 137.204–139.527 | 0.58% | 0.46x | 1.00x | 1.00x |
| `method_calls` | 2 | 500 | 64.334 | 63.590–78.485 | 9.50% | 140.482 | 139.851–143.114 | 0.96% | 0.46x | 1.97x | 1.96x |
| `method_calls` | 4 | 500 | 66.220 | 65.052–67.171 | 1.10% | 149.644 | 146.011–154.043 | 1.78% | 0.44x | 3.83x | 3.67x |
| `method_calls` | 8 | 500 | 86.310 | 84.966–88.745 | 1.34% | 218.620 | 211.810–224.280 | 2.14% | 0.39x | 5.87x | 5.03x |
| `closure_calls` | 1 | 600 | 62.543 | 62.284–64.507 | 1.69% | 187.376 | 186.394–192.638 | 1.16% | 0.33x | 1.00x | 1.00x |
| `closure_calls` | 2 | 600 | 64.797 | 64.049–66.394 | 1.35% | 194.272 | 191.866–199.525 | 1.32% | 0.33x | 1.93x | 1.93x |
| `closure_calls` | 4 | 600 | 65.907 | 65.522–71.244 | 3.08% | 213.719 | 206.385–217.979 | 2.11% | 0.31x | 3.80x | 3.51x |
| `closure_calls` | 8 | 600 | 83.167 | 80.081–85.340 | 1.97% | 319.936 | 305.691–335.705 | 2.83% | 0.26x | 6.02x | 4.69x |
| `arguments_calls` | 1 | 600 | 68.464 | 68.127–72.271 | 2.63% | 299.111 | 294.456–300.255 | 0.78% | 0.23x | 1.00x | 1.00x |
| `arguments_calls` | 2 | 600 | 69.612 | 69.161–73.102 | 2.03% | 305.740 | 304.091–316.579 | 1.43% | 0.23x | 1.97x | 1.96x |
| `arguments_calls` | 4 | 600 | 71.281 | 70.757–74.310 | 2.23% | 331.266 | 321.712–342.817 | 2.21% | 0.22x | 3.84x | 3.61x |
| `arguments_calls` | 8 | 600 | 98.434 | 92.038–116.417 | 7.73% | 496.931 | 488.457–523.125 | 2.25% | 0.20x | 5.56x | 4.82x |
| `fibonacci` | 1 | 125 | 84.439 | 83.326–91.126 | 3.32% | 451.145 | 446.940–455.616 | 0.65% | 0.19x | 1.00x | 1.00x |
| `fibonacci` | 2 | 125 | 85.103 | 85.074–85.989 | 0.39% | 460.199 | 455.574–473.003 | 1.18% | 0.18x | 1.98x | 1.96x |
| `fibonacci` | 4 | 125 | 87.761 | 87.130–103.037 | 6.44% | 469.917 | 466.411–477.903 | 0.81% | 0.19x | 3.85x | 3.84x |
| `fibonacci` | 8 | 125 | 125.316 | 116.260–133.607 | 4.89% | 681.812 | 672.845–730.809 | 3.66% | 0.18x | 5.39x | 5.29x |

## zig-js shared-realm scaling

This is zig-js's distinct no-GIL shared-object-graph model, which JSC's public C API does not provide.
The timed region creates JavaScript `Thread`s, performs the work, and joins them. Scaling uses the same
shared-realm path at one lane, so thread lifecycle overhead is present in every row.

| workload | lanes | jobs/lane | median (ms) | min–max (ms) | RSD | scaling |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `arithmetic` | 1 | 240 | 77.019 | 75.621–80.647 | 3.02% | 1.00x |
| `arithmetic` | 2 | 240 | 82.640 | 77.515–83.763 | 3.36% | 1.86x |
| `arithmetic` | 4 | 240 | 84.671 | 84.614–85.900 | 0.61% | 3.64x |
| `arithmetic` | 8 | 240 | 102.173 | 98.089–111.047 | 3.91% | 6.03x |
| `properties` | 1 | 300 | 125.081 | 124.152–127.221 | 0.90% | 1.00x |
| `properties` | 2 | 300 | 128.531 | 126.566–129.418 | 0.83% | 1.95x |
| `properties` | 4 | 300 | 129.959 | 129.629–131.290 | 0.50% | 3.85x |
| `properties` | 8 | 300 | 166.599 | 161.950–172.018 | 2.14% | 6.01x |
| `polymorphic_properties` | 1 | 400 | 512.433 | 507.242–552.506 | 3.09% | 1.00x |
| `polymorphic_properties` | 2 | 400 | 520.311 | 518.238–528.698 | 0.81% | 1.97x |
| `polymorphic_properties` | 4 | 400 | 534.833 | 531.618–580.195 | 3.19% | 3.83x |
| `polymorphic_properties` | 8 | 400 | 691.857 | 671.478–715.766 | 2.24% | 5.93x |
| `object_churn` | 1 | 100 | 351.344 | 142.625–402.019 | 25.74% | 1.00x |
| `object_churn` | 2 | 100 | 717.910 | 269.940–819.788 | 27.21% | 0.98x |
| `object_churn` | 4 | 100 | 2112.202 | 620.912–3121.840 | 35.95% | 0.67x |
| `object_churn` | 8 | 100 | 9311.238 | 3176.532–9960.220 | 28.07% | 0.30x |
| `arrays` | 1 | 550 | 79.844 | 79.022–83.480 | 1.98% | 1.00x |
| `arrays` | 2 | 550 | 85.284 | 83.714–86.891 | 1.36% | 1.87x |
| `arrays` | 4 | 550 | 94.028 | 91.360–107.993 | 6.05% | 3.40x |
| `arrays` | 8 | 550 | 192.443 | 185.724–208.167 | 4.89% | 3.32x |
| `direct_calls` | 1 | 600 | 56.114 | 55.878–57.826 | 1.22% | 1.00x |
| `direct_calls` | 2 | 600 | 57.175 | 56.953–59.106 | 1.55% | 1.96x |
| `direct_calls` | 4 | 600 | 58.263 | 58.202–58.302 | 0.06% | 3.85x |
| `direct_calls` | 8 | 600 | 79.582 | 76.147–104.184 | 11.56% | 5.64x |
| `method_calls` | 1 | 500 | 115.459 | 115.245–120.885 | 2.18% | 1.00x |
| `method_calls` | 2 | 500 | 118.251 | 118.115–119.551 | 0.52% | 1.95x |
| `method_calls` | 4 | 500 | 121.668 | 120.752–126.967 | 1.79% | 3.80x |
| `method_calls` | 8 | 500 | 172.628 | 170.676–182.099 | 2.29% | 5.35x |
| `closure_calls` | 1 | 600 | 62.666 | 62.454–64.183 | 1.16% | 1.00x |
| `closure_calls` | 2 | 600 | 63.751 | 63.657–63.934 | 0.15% | 1.97x |
| `closure_calls` | 4 | 600 | 65.460 | 65.264–66.551 | 0.68% | 3.83x |
| `closure_calls` | 8 | 600 | 86.328 | 83.806–96.342 | 5.29% | 5.81x |
| `arguments_calls` | 1 | 600 | 66.250 | 66.073–67.502 | 0.81% | 1.00x |
| `arguments_calls` | 2 | 600 | 68.078 | 67.929–82.802 | 7.70% | 1.95x |
| `arguments_calls` | 4 | 600 | 69.552 | 69.379–85.433 | 8.27% | 3.81x |
| `arguments_calls` | 8 | 600 | 90.801 | 90.483–108.705 | 8.21% | 5.84x |
| `fibonacci` | 1 | 125 | 242.991 | 242.821–248.878 | 1.19% | 1.00x |
| `fibonacci` | 2 | 125 | 247.581 | 247.296–257.826 | 1.56% | 1.96x |
| `fibonacci` | 4 | 125 | 259.660 | 253.245–265.109 | 1.59% | 3.74x |
| `fibonacci` | 8 | 125 | 376.771 | 368.993–393.384 | 2.11% | 5.16x |

## Reading the result

Across these 10 deliberately small kernels, JSC's single-context throughput is 0.38x
the zig-js throughput by geometric mean. These kernels deliberately exercise guarded native/VM tiers that
zig-js currently implements; rows outside those documented subsets continue through general bytecode paths.
The number is a compact description of this matrix, not a claim about applications or unsupported workloads.

At 8 independent warmed contexts, JSC throughput is 0.37x zig-js by
geometric mean; scaling from the mode's own one-lane baseline is 5.35x
for zig-js and 5.21x for JSC. In the symmetric cold lifecycle, JSC
throughput is 0.36x zig-js, with 5.37x
and 5.18x scaling respectively.

zig-js's shared-realm path scales 4.03x at 8 lanes from its
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
