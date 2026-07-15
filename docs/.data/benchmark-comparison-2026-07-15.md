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
| zig-js | d2e29fa07c1d356c7a42bdb03477d00bc29344e5 |
| zig-gc | 9d4af0d49be5eba5b9283d5ed135fdf02626e2ac |
| zig-regex | 5937fa7d4db0b69575c821066afd1a7da92aa019 |
| JavaScriptCore | system framework 22625.1.20.11.3 |
| Power | Now drawing from 'Battery Power' -InternalBattery-0 (id=22806627) 78%; discharging; (no estimate) present: true |

## Single-thread result

Each row runs the same number of jobs in one GC-enabled zig-js context and one warmed JSC global context.
Both runners time the exact invocation `__benchmarkSelected(__benchmarkJobs, __benchmarkLane)`.
Lower time is better; `JSC / zig-js` is JSC throughput divided by zig-js throughput. RSD is relative standard deviation.

| workload | jobs | zig-js median (ms) | zig-js min–max (ms) | zig-js RSD | JSC median (ms) | JSC min–max (ms) | JSC RSD | JSC / zig-js |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `arithmetic` | 240 | 86.330 | 85.310–86.626 | 0.63% | 352.091 | 350.070–360.933 | 1.10% | 0.25x |
| `properties` | 300 | 89.551 | 89.267–89.912 | 0.26% | 301.100 | 296.863–306.157 | 1.21% | 0.30x |
| `polymorphic_properties` | 400 | 83.589 | 82.972–84.226 | 0.52% | 208.683 | 205.409–213.074 | 1.44% | 0.40x |
| `object_churn` | 100 | 114.315 | 111.130–155.475 | 13.28% | 119.322 | 116.522–121.651 | 1.32% | 0.96x |
| `arrays` | 550 | 86.368 | 78.266–131.366 | 20.82% | 159.212 | 156.774–213.844 | 12.32% | 0.54x |
| `direct_calls` | 600 | 58.342 | 57.192–76.254 | 11.31% | 117.842 | 115.472–119.619 | 1.13% | 0.50x |
| `method_calls` | 500 | 63.555 | 62.568–64.132 | 0.92% | 147.657 | 141.049–176.050 | 7.71% | 0.43x |
| `closure_calls` | 600 | 62.892 | 62.675–64.245 | 0.87% | 190.860 | 189.957–194.327 | 0.76% | 0.33x |
| `arguments_calls` | 600 | 69.751 | 67.509–72.493 | 2.51% | 304.132 | 301.840–313.382 | 1.29% | 0.23x |
| `fibonacci` | 125 | 82.003 | 81.933–82.043 | 0.04% | 444.825 | 443.676–446.281 | 0.23% | 0.18x |

## Independent-context steady state

Both engines keep one warmed context on one persistent OS worker per lane. The timed region contains the
same semaphore dispatch, exact invocation, and completion wait. Every lane performs the full job count.
`scaling` uses the same engine and mode at one lane; cross-engine throughput is directly comparable.

| workload | lanes | jobs/lane | zig-js median (ms) | zig-js min–max (ms) | zig-js RSD | JSC median (ms) | JSC min–max (ms) | JSC RSD | JSC / zig-js | zig-js scaling | JSC scaling |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `arithmetic` | 1 | 240 | 89.271 | 86.166–93.091 | 3.04% | 355.359 | 350.141–363.873 | 1.27% | 0.25x | 1.00x | 1.00x |
| `arithmetic` | 2 | 240 | 89.086 | 86.922–91.741 | 2.11% | 384.574 | 368.206–435.853 | 5.88% | 0.23x | 2.00x | 1.85x |
| `arithmetic` | 4 | 240 | 96.035 | 92.178–122.929 | 10.87% | 415.714 | 404.217–452.077 | 4.32% | 0.23x | 3.72x | 3.42x |
| `arithmetic` | 8 | 240 | 111.545 | 108.749–112.458 | 1.34% | 571.040 | 557.768–580.910 | 1.25% | 0.20x | 6.40x | 4.98x |
| `properties` | 1 | 300 | 89.282 | 87.177–90.291 | 1.16% | 298.005 | 295.732–301.299 | 0.62% | 0.30x | 1.00x | 1.00x |
| `properties` | 2 | 300 | 91.719 | 91.222–91.999 | 0.31% | 303.531 | 299.944–309.276 | 1.02% | 0.30x | 1.95x | 1.96x |
| `properties` | 4 | 300 | 92.722 | 92.315–94.960 | 1.19% | 325.930 | 321.303–332.509 | 1.34% | 0.28x | 3.85x | 3.66x |
| `properties` | 8 | 300 | 113.485 | 111.733–119.203 | 2.36% | 470.981 | 454.075–502.758 | 3.31% | 0.24x | 6.29x | 5.06x |
| `polymorphic_properties` | 1 | 400 | 84.045 | 82.701–86.425 | 1.47% | 207.634 | 206.729–210.399 | 0.63% | 0.40x | 1.00x | 1.00x |
| `polymorphic_properties` | 2 | 400 | 86.319 | 85.062–115.920 | 12.42% | 207.900 | 206.559–212.404 | 1.11% | 0.42x | 1.95x | 2.00x |
| `polymorphic_properties` | 4 | 400 | 90.828 | 88.025–93.385 | 2.40% | 233.459 | 232.457–271.184 | 5.89% | 0.39x | 3.70x | 3.56x |
| `polymorphic_properties` | 8 | 400 | 124.055 | 122.700–126.045 | 0.90% | 320.994 | 317.123–326.924 | 1.08% | 0.39x | 5.42x | 5.17x |
| `object_churn` | 1 | 100 | 114.973 | 113.338–117.503 | 1.20% | 120.040 | 117.937–122.555 | 1.36% | 0.96x | 1.00x | 1.00x |
| `object_churn` | 2 | 100 | 120.614 | 117.553–146.108 | 8.03% | 119.459 | 117.522–120.444 | 0.98% | 1.01x | 1.91x | 2.01x |
| `object_churn` | 4 | 100 | 166.849 | 163.030–202.928 | 8.05% | 125.843 | 120.861–135.930 | 4.62% | 1.33x | 2.76x | 3.82x |
| `object_churn` | 8 | 100 | 277.124 | 274.297–279.980 | 0.64% | 172.070 | 164.020–188.965 | 5.38% | 1.61x | 3.32x | 5.58x |
| `arrays` | 1 | 550 | 82.225 | 81.054–83.959 | 1.47% | 156.591 | 154.878–158.342 | 0.75% | 0.53x | 1.00x | 1.00x |
| `arrays` | 2 | 550 | 80.953 | 80.489–90.860 | 4.53% | 155.485 | 154.839–157.356 | 0.54% | 0.52x | 2.03x | 2.01x |
| `arrays` | 4 | 550 | 83.848 | 82.426–84.478 | 0.92% | 157.505 | 154.617–164.264 | 1.89% | 0.53x | 3.92x | 3.98x |
| `arrays` | 8 | 550 | 121.355 | 117.950–127.409 | 3.16% | 227.679 | 214.784–237.508 | 3.65% | 0.53x | 5.42x | 5.50x |
| `direct_calls` | 1 | 600 | 59.187 | 56.576–63.065 | 3.48% | 118.777 | 113.710–123.465 | 2.81% | 0.50x | 1.00x | 1.00x |
| `direct_calls` | 2 | 600 | 59.868 | 57.149–62.948 | 3.43% | 130.800 | 123.298–156.880 | 8.55% | 0.46x | 1.98x | 1.82x |
| `direct_calls` | 4 | 600 | 60.780 | 59.666–71.938 | 7.35% | 124.499 | 122.929–126.749 | 1.09% | 0.49x | 3.90x | 3.82x |
| `direct_calls` | 8 | 600 | 84.196 | 79.081–109.707 | 11.56% | 199.053 | 195.356–211.341 | 2.95% | 0.42x | 5.62x | 4.77x |
| `method_calls` | 1 | 500 | 67.521 | 66.331–73.374 | 4.11% | 154.536 | 145.385–170.977 | 5.68% | 0.44x | 1.00x | 1.00x |
| `method_calls` | 2 | 500 | 63.402 | 63.238–64.836 | 1.03% | 144.098 | 141.982–152.279 | 2.74% | 0.44x | 2.13x | 2.14x |
| `method_calls` | 4 | 500 | 65.079 | 64.220–71.274 | 4.36% | 146.530 | 144.763–179.663 | 9.71% | 0.44x | 4.15x | 4.22x |
| `method_calls` | 8 | 500 | 89.132 | 85.827–97.694 | 4.49% | 223.712 | 209.135–241.588 | 4.92% | 0.40x | 6.06x | 5.53x |
| `closure_calls` | 1 | 600 | 63.132 | 62.710–64.013 | 0.75% | 190.012 | 189.109–192.693 | 0.62% | 0.33x | 1.00x | 1.00x |
| `closure_calls` | 2 | 600 | 63.971 | 63.691–64.814 | 0.62% | 193.482 | 192.361–194.772 | 0.43% | 0.33x | 1.97x | 1.96x |
| `closure_calls` | 4 | 600 | 77.031 | 66.166–102.617 | 14.01% | 205.700 | 204.166–208.481 | 0.75% | 0.37x | 3.28x | 3.69x |
| `closure_calls` | 8 | 600 | 89.767 | 85.084–91.221 | 3.15% | 316.334 | 309.888–337.079 | 3.10% | 0.28x | 5.63x | 4.81x |
| `arguments_calls` | 1 | 600 | 70.742 | 69.604–97.370 | 13.64% | 307.364 | 297.317–310.937 | 1.61% | 0.23x | 1.00x | 1.00x |
| `arguments_calls` | 2 | 600 | 68.596 | 68.208–74.687 | 3.52% | 311.539 | 304.011–312.594 | 1.20% | 0.22x | 2.06x | 1.97x |
| `arguments_calls` | 4 | 600 | 73.916 | 72.329–80.386 | 3.87% | 318.641 | 315.591–322.656 | 0.87% | 0.23x | 3.83x | 3.86x |
| `arguments_calls` | 8 | 600 | 90.583 | 88.380–93.769 | 1.95% | 472.062 | 469.423–486.975 | 1.59% | 0.19x | 6.25x | 5.21x |
| `fibonacci` | 1 | 125 | 86.940 | 82.366–111.519 | 11.35% | 459.837 | 457.739–473.448 | 1.47% | 0.19x | 1.00x | 1.00x |
| `fibonacci` | 2 | 125 | 85.514 | 85.031–87.372 | 0.89% | 463.697 | 463.152–465.618 | 0.22% | 0.18x | 2.03x | 1.98x |
| `fibonacci` | 4 | 125 | 89.380 | 87.990–99.531 | 4.53% | 498.813 | 477.827–543.841 | 4.69% | 0.18x | 3.89x | 3.69x |
| `fibonacci` | 8 | 125 | 120.513 | 114.649–130.065 | 4.59% | 664.877 | 653.968–687.288 | 1.85% | 0.18x | 5.77x | 5.53x |

## Independent-context cold lifecycle

Neither engine warms these contexts. The timer covers OS-thread creation, context creation, workload-source
evaluation and configuration, the exact invocation, context destruction, and OS-thread join on both sides.
`scaling` uses the same engine and cold lifecycle at one lane.

| workload | lanes | jobs/lane | zig-js median (ms) | zig-js min–max (ms) | zig-js RSD | JSC median (ms) | JSC min–max (ms) | JSC RSD | JSC / zig-js | zig-js scaling | JSC scaling |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `arithmetic` | 1 | 240 | 92.382 | 91.763–97.263 | 2.11% | 358.149 | 354.180–402.014 | 4.67% | 0.26x | 1.00x | 1.00x |
| `arithmetic` | 2 | 240 | 92.606 | 90.308–93.867 | 1.45% | 379.111 | 369.831–419.788 | 4.42% | 0.24x | 2.00x | 1.89x |
| `arithmetic` | 4 | 240 | 96.009 | 92.218–99.679 | 3.39% | 441.528 | 408.210–527.357 | 9.50% | 0.22x | 3.85x | 3.24x |
| `arithmetic` | 8 | 240 | 114.204 | 105.621–118.297 | 3.57% | 596.404 | 579.459–617.938 | 2.33% | 0.19x | 6.47x | 4.80x |
| `properties` | 1 | 300 | 90.064 | 88.427–90.494 | 0.84% | 300.383 | 293.442–327.523 | 3.74% | 0.30x | 1.00x | 1.00x |
| `properties` | 2 | 300 | 92.737 | 91.173–114.991 | 8.90% | 305.229 | 304.621–306.197 | 0.19% | 0.30x | 1.94x | 1.97x |
| `properties` | 4 | 300 | 94.628 | 92.687–96.569 | 1.30% | 327.644 | 320.792–335.911 | 1.37% | 0.29x | 3.81x | 3.67x |
| `properties` | 8 | 300 | 127.707 | 124.307–166.960 | 11.47% | 476.361 | 467.624–487.538 | 1.34% | 0.27x | 5.64x | 5.04x |
| `polymorphic_properties` | 1 | 400 | 87.705 | 85.609–115.957 | 12.15% | 209.626 | 206.563–210.882 | 0.66% | 0.42x | 1.00x | 1.00x |
| `polymorphic_properties` | 2 | 400 | 86.917 | 85.925–87.470 | 0.62% | 211.365 | 208.956–215.203 | 0.88% | 0.41x | 2.02x | 1.98x |
| `polymorphic_properties` | 4 | 400 | 93.146 | 92.204–98.776 | 2.75% | 234.518 | 232.914–237.214 | 0.60% | 0.40x | 3.77x | 3.58x |
| `polymorphic_properties` | 8 | 400 | 124.083 | 122.360–127.341 | 1.40% | 326.208 | 321.993–328.967 | 0.89% | 0.38x | 5.65x | 5.14x |
| `object_churn` | 1 | 100 | 114.831 | 113.797–116.027 | 0.68% | 119.036 | 116.617–120.524 | 1.10% | 0.96x | 1.00x | 1.00x |
| `object_churn` | 2 | 100 | 126.223 | 119.872–204.345 | 25.80% | 120.588 | 119.071–122.846 | 1.12% | 1.05x | 1.82x | 1.97x |
| `object_churn` | 4 | 100 | 191.175 | 166.376–213.048 | 8.91% | 128.577 | 123.184–135.015 | 2.92% | 1.49x | 2.40x | 3.70x |
| `object_churn` | 8 | 100 | 351.305 | 333.887–353.429 | 2.13% | 179.788 | 165.413–183.347 | 3.47% | 1.95x | 2.61x | 5.30x |
| `arrays` | 1 | 550 | 82.359 | 80.638–87.134 | 2.64% | 161.070 | 156.479–192.931 | 7.81% | 0.51x | 1.00x | 1.00x |
| `arrays` | 2 | 550 | 81.440 | 80.283–83.804 | 1.54% | 154.562 | 152.903–155.642 | 0.66% | 0.53x | 2.02x | 2.08x |
| `arrays` | 4 | 550 | 84.109 | 83.064–85.890 | 1.27% | 161.221 | 157.626–185.626 | 6.92% | 0.52x | 3.92x | 4.00x |
| `arrays` | 8 | 550 | 120.853 | 112.226–132.789 | 5.59% | 235.815 | 229.837–240.329 | 1.69% | 0.51x | 5.45x | 5.46x |
| `direct_calls` | 1 | 600 | 58.274 | 57.288–66.756 | 5.70% | 118.476 | 116.156–152.700 | 10.53% | 0.49x | 1.00x | 1.00x |
| `direct_calls` | 2 | 600 | 59.640 | 59.432–62.762 | 2.10% | 127.856 | 121.766–149.001 | 7.11% | 0.47x | 1.95x | 1.85x |
| `direct_calls` | 4 | 600 | 62.450 | 60.943–70.858 | 5.35% | 127.241 | 124.516–137.942 | 3.47% | 0.49x | 3.73x | 3.72x |
| `direct_calls` | 8 | 600 | 87.148 | 82.953–119.693 | 14.80% | 225.479 | 213.640–278.146 | 10.88% | 0.39x | 5.35x | 4.20x |
| `method_calls` | 1 | 500 | 71.537 | 66.099–78.909 | 5.57% | 154.278 | 149.598–173.346 | 5.39% | 0.46x | 1.00x | 1.00x |
| `method_calls` | 2 | 500 | 64.785 | 64.574–66.344 | 1.08% | 152.672 | 146.842–172.097 | 5.65% | 0.42x | 2.21x | 2.02x |
| `method_calls` | 4 | 500 | 66.463 | 66.404–77.308 | 7.95% | 144.131 | 143.614–146.030 | 0.69% | 0.46x | 4.31x | 4.28x |
| `method_calls` | 8 | 500 | 93.222 | 86.994–96.499 | 3.94% | 220.837 | 213.076–234.189 | 2.96% | 0.42x | 6.14x | 5.59x |
| `closure_calls` | 1 | 600 | 64.016 | 63.638–65.598 | 1.17% | 190.767 | 189.891–194.268 | 0.75% | 0.34x | 1.00x | 1.00x |
| `closure_calls` | 2 | 600 | 68.951 | 66.221–77.379 | 5.15% | 196.067 | 194.225–208.344 | 2.65% | 0.35x | 1.86x | 1.95x |
| `closure_calls` | 4 | 600 | 68.582 | 67.129–70.267 | 1.88% | 212.289 | 206.506–228.443 | 3.53% | 0.32x | 3.73x | 3.59x |
| `closure_calls` | 8 | 600 | 100.065 | 96.948–105.725 | 2.76% | 315.754 | 309.244–380.232 | 7.73% | 0.32x | 5.12x | 4.83x |
| `arguments_calls` | 1 | 600 | 70.460 | 68.218–72.123 | 2.14% | 303.749 | 297.487–309.867 | 1.35% | 0.23x | 1.00x | 1.00x |
| `arguments_calls` | 2 | 600 | 70.094 | 69.506–71.696 | 1.36% | 312.393 | 307.057–346.405 | 4.26% | 0.22x | 2.01x | 1.94x |
| `arguments_calls` | 4 | 600 | 73.683 | 71.162–77.628 | 3.39% | 322.811 | 320.271–328.628 | 0.86% | 0.23x | 3.83x | 3.76x |
| `arguments_calls` | 8 | 600 | 92.073 | 90.673–92.916 | 0.94% | 476.501 | 463.049–487.054 | 1.59% | 0.19x | 6.12x | 5.10x |
| `fibonacci` | 1 | 125 | 89.434 | 87.029–120.071 | 13.70% | 464.608 | 456.796–480.589 | 2.15% | 0.19x | 1.00x | 1.00x |
| `fibonacci` | 2 | 125 | 87.252 | 86.361–89.876 | 1.52% | 463.894 | 462.901–467.331 | 0.35% | 0.19x | 2.05x | 2.00x |
| `fibonacci` | 4 | 125 | 90.196 | 89.324–95.211 | 2.22% | 481.674 | 477.198–500.980 | 1.61% | 0.19x | 3.97x | 3.86x |
| `fibonacci` | 8 | 125 | 126.770 | 125.518–145.289 | 5.47% | 678.979 | 658.355–724.014 | 3.13% | 0.19x | 5.64x | 5.47x |

## zig-js shared-realm scaling

This is zig-js's distinct no-GIL shared-object-graph model, which JSC's public C API does not provide.
The timed region creates JavaScript `Thread`s, performs the work, and joins them. Scaling uses the same
shared-realm path at one lane, so thread lifecycle overhead is present in every row.

| workload | lanes | jobs/lane | median (ms) | min–max (ms) | RSD | scaling |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `arithmetic` | 1 | 240 | 84.392 | 84.355–86.862 | 1.09% | 1.00x |
| `arithmetic` | 2 | 240 | 88.036 | 87.057–91.811 | 1.80% | 1.92x |
| `arithmetic` | 4 | 240 | 87.361 | 86.763–89.308 | 1.14% | 3.86x |
| `arithmetic` | 8 | 240 | 108.462 | 104.734–151.426 | 14.47% | 6.22x |
| `properties` | 1 | 300 | 131.039 | 129.018–132.088 | 0.76% | 1.00x |
| `properties` | 2 | 300 | 132.400 | 129.657–132.732 | 0.85% | 1.98x |
| `properties` | 4 | 300 | 136.095 | 132.098–141.135 | 2.27% | 3.85x |
| `properties` | 8 | 300 | 183.684 | 179.642–191.726 | 2.35% | 5.71x |
| `polymorphic_properties` | 1 | 400 | 530.664 | 523.548–544.887 | 1.55% | 1.00x |
| `polymorphic_properties` | 2 | 400 | 546.401 | 536.985–553.012 | 0.91% | 1.94x |
| `polymorphic_properties` | 4 | 400 | 563.592 | 556.588–599.626 | 3.01% | 3.77x |
| `polymorphic_properties` | 8 | 400 | 729.113 | 722.395–800.723 | 3.77% | 5.82x |
| `object_churn` | 1 | 100 | 193.942 | 126.658–201.335 | 14.06% | 1.00x |
| `object_churn` | 2 | 100 | 353.325 | 215.833–382.718 | 16.29% | 1.10x |
| `object_churn` | 4 | 100 | 749.455 | 549.605–1813.247 | 48.02% | 1.04x |
| `object_churn` | 8 | 100 | 4751.665 | 2227.713–5799.246 | 24.30% | 0.33x |
| `arrays` | 1 | 550 | 83.149 | 81.732–87.317 | 2.74% | 1.00x |
| `arrays` | 2 | 550 | 85.261 | 84.822–86.432 | 0.70% | 1.95x |
| `arrays` | 4 | 550 | 95.434 | 91.813–96.769 | 1.88% | 3.49x |
| `arrays` | 8 | 550 | 212.185 | 208.635–229.291 | 3.22% | 3.13x |
| `direct_calls` | 1 | 600 | 57.254 | 56.554–57.971 | 0.88% | 1.00x |
| `direct_calls` | 2 | 600 | 58.568 | 57.762–59.999 | 1.54% | 1.96x |
| `direct_calls` | 4 | 600 | 62.705 | 60.060–88.042 | 15.31% | 3.65x |
| `direct_calls` | 8 | 600 | 92.215 | 85.138–137.351 | 18.03% | 4.97x |
| `method_calls` | 1 | 500 | 125.000 | 121.807–133.298 | 2.85% | 1.00x |
| `method_calls` | 2 | 500 | 122.020 | 119.862–138.084 | 5.08% | 2.05x |
| `method_calls` | 4 | 500 | 126.065 | 123.542–183.980 | 15.94% | 3.97x |
| `method_calls` | 8 | 500 | 181.041 | 175.262–188.291 | 2.89% | 5.52x |
| `closure_calls` | 1 | 600 | 64.051 | 63.713–68.486 | 2.62% | 1.00x |
| `closure_calls` | 2 | 600 | 67.230 | 65.551–68.000 | 1.38% | 1.91x |
| `closure_calls` | 4 | 600 | 69.670 | 67.484–74.170 | 3.25% | 3.68x |
| `closure_calls` | 8 | 600 | 92.878 | 90.755–99.854 | 3.25% | 5.52x |
| `arguments_calls` | 1 | 600 | 68.318 | 68.100–70.126 | 1.00% | 1.00x |
| `arguments_calls` | 2 | 600 | 69.139 | 68.301–69.496 | 0.58% | 1.98x |
| `arguments_calls` | 4 | 600 | 71.874 | 71.674–74.458 | 1.36% | 3.80x |
| `arguments_calls` | 8 | 600 | 90.724 | 88.158–95.978 | 2.91% | 6.02x |
| `fibonacci` | 1 | 125 | 247.624 | 243.900–314.374 | 10.02% | 1.00x |
| `fibonacci` | 2 | 125 | 247.393 | 247.256–248.668 | 0.26% | 2.00x |
| `fibonacci` | 4 | 125 | 256.273 | 254.766–258.039 | 0.50% | 3.87x |
| `fibonacci` | 8 | 125 | 375.215 | 371.663–403.003 | 2.90% | 5.28x |

## Reading the result

Across these 10 deliberately small kernels, JSC's single-context throughput is 0.37x
the zig-js throughput by geometric mean. These kernels deliberately exercise guarded native/VM tiers that
zig-js currently implements; rows outside those documented subsets continue through general bytecode paths.
The number is a compact description of this matrix, not a claim about applications or unsupported workloads.

At 8 independent warmed contexts, JSC throughput is 0.35x zig-js by
geometric mean; scaling from the mode's own one-lane baseline is 5.54x
for zig-js and 5.21x for JSC. In the symmetric cold lifecycle, JSC
throughput is 0.36x zig-js, with 5.29x
and 5.08x scaling respectively.

zig-js's shared-realm path scales 3.99x at 8 lanes from its
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
