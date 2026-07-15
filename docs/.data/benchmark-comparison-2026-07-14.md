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
| zig-js | 0679295d2f8ebcaf8363e962ebfed9a007943b2d |
| JavaScriptCore | system framework 22625.1.20.11.3 |
| Power | Now drawing from 'AC Power' -InternalBattery-0 (id=22806627) 100%; charged; 0:00 remaining present: true |

## Single-thread result

Each row runs the same number of jobs in one GC-enabled zig-js context and one warmed JSC global context.
Both runners time the exact invocation `__benchmarkSelected(__benchmarkJobs, __benchmarkLane)`.
Lower time is better; `JSC / zig-js` is JSC throughput divided by zig-js throughput. RSD is relative standard deviation.

| workload | jobs | zig-js median (ms) | zig-js min–max (ms) | zig-js RSD | JSC median (ms) | JSC min–max (ms) | JSC RSD | JSC / zig-js |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `arithmetic` | 240 | 82.146 | 79.018–84.810 | 2.74% | 354.505 | 342.558–364.830 | 2.63% | 0.23x |
| `properties` | 300 | 85.345 | 85.223–93.193 | 3.38% | 288.632 | 285.989–291.543 | 0.68% | 0.30x |
| `polymorphic_properties` | 400 | 81.839 | 80.507–83.681 | 1.34% | 199.637 | 198.211–203.324 | 1.12% | 0.41x |
| `object_churn` | 100 | 149.265 | 148.695–154.979 | 1.78% | 115.398 | 114.092–123.695 | 2.79% | 1.29x |
| `arrays` | 550 | 80.055 | 76.882–83.362 | 2.42% | 150.122 | 148.560–157.621 | 2.02% | 0.53x |
| `direct_calls` | 600 | 56.683 | 55.799–59.473 | 2.59% | 119.723 | 114.765–158.069 | 12.20% | 0.47x |
| `method_calls` | 500 | 61.569 | 61.276–64.113 | 1.60% | 137.008 | 136.541–141.624 | 1.51% | 0.45x |
| `closure_calls` | 600 | 61.976 | 61.215–80.532 | 10.84% | 189.138 | 187.140–193.359 | 1.41% | 0.33x |
| `arguments_calls` | 600 | 66.354 | 66.279–66.551 | 0.14% | 294.617 | 293.427–298.501 | 0.71% | 0.23x |
| `fibonacci` | 125 | 81.968 | 81.893–86.787 | 2.15% | 450.846 | 446.753–453.841 | 0.52% | 0.18x |

## Independent-context steady state

Both engines keep one warmed context on one persistent OS worker per lane. The timed region contains the
same semaphore dispatch, exact invocation, and completion wait. Every lane performs the full job count.
`scaling` uses the same engine and mode at one lane; cross-engine throughput is directly comparable.

| workload | lanes | jobs/lane | zig-js median (ms) | zig-js min–max (ms) | zig-js RSD | JSC median (ms) | JSC min–max (ms) | JSC RSD | JSC / zig-js | zig-js scaling | JSC scaling |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `arithmetic` | 1 | 240 | 76.672 | 75.464–84.207 | 3.97% | 344.818 | 343.095–352.838 | 0.99% | 0.22x | 1.00x | 1.00x |
| `arithmetic` | 2 | 240 | 83.346 | 82.021–85.970 | 1.60% | 356.331 | 352.989–393.838 | 4.60% | 0.23x | 1.84x | 1.94x |
| `arithmetic` | 4 | 240 | 84.518 | 84.458–86.066 | 0.77% | 370.380 | 359.879–372.922 | 1.20% | 0.23x | 3.63x | 3.72x |
| `arithmetic` | 8 | 240 | 99.807 | 98.938–102.517 | 1.40% | 487.211 | 478.341–517.789 | 2.88% | 0.20x | 6.15x | 5.66x |
| `properties` | 1 | 300 | 85.840 | 85.418–90.015 | 1.90% | 286.551 | 284.737–289.832 | 0.68% | 0.30x | 1.00x | 1.00x |
| `properties` | 2 | 300 | 88.426 | 87.153–91.840 | 1.93% | 292.556 | 291.120–295.335 | 0.48% | 0.30x | 1.94x | 1.96x |
| `properties` | 4 | 300 | 89.833 | 89.373–113.040 | 9.33% | 298.346 | 297.688–304.275 | 0.79% | 0.30x | 3.82x | 3.84x |
| `properties` | 8 | 300 | 113.220 | 110.262–122.298 | 3.91% | 405.957 | 396.976–414.745 | 1.40% | 0.28x | 6.07x | 5.65x |
| `polymorphic_properties` | 1 | 400 | 80.221 | 80.028–81.480 | 0.68% | 199.792 | 198.858–203.500 | 0.85% | 0.40x | 1.00x | 1.00x |
| `polymorphic_properties` | 2 | 400 | 81.669 | 81.513–83.509 | 0.95% | 204.410 | 202.599–214.950 | 2.14% | 0.40x | 1.96x | 1.95x |
| `polymorphic_properties` | 4 | 400 | 87.261 | 85.462–88.335 | 1.26% | 218.482 | 208.128–241.591 | 5.81% | 0.40x | 3.68x | 3.66x |
| `polymorphic_properties` | 8 | 400 | 119.755 | 116.665–125.754 | 2.90% | 307.803 | 300.295–324.574 | 2.58% | 0.39x | 5.36x | 5.19x |
| `object_churn` | 1 | 100 | 150.487 | 148.524–156.694 | 2.03% | 114.407 | 113.323–121.503 | 2.40% | 1.32x | 1.00x | 1.00x |
| `object_churn` | 2 | 100 | 158.618 | 157.272–160.583 | 0.62% | 118.259 | 117.566–118.591 | 0.29% | 1.34x | 1.90x | 1.93x |
| `object_churn` | 4 | 100 | 201.832 | 197.720–221.678 | 5.15% | 121.788 | 120.856–124.192 | 0.95% | 1.66x | 2.98x | 3.76x |
| `object_churn` | 8 | 100 | 433.277 | 403.370–507.167 | 7.74% | 182.804 | 167.908–187.480 | 3.60% | 2.37x | 2.78x | 5.01x |
| `arrays` | 1 | 550 | 76.538 | 76.081–82.198 | 2.78% | 150.225 | 149.378–155.091 | 1.61% | 0.51x | 1.00x | 1.00x |
| `arrays` | 2 | 550 | 79.320 | 78.947–86.599 | 3.68% | 153.184 | 152.183–158.238 | 1.43% | 0.52x | 1.93x | 1.96x |
| `arrays` | 4 | 550 | 82.421 | 81.408–83.047 | 0.74% | 155.706 | 154.365–156.680 | 0.60% | 0.53x | 3.71x | 3.86x |
| `arrays` | 8 | 550 | 114.639 | 112.742–125.345 | 4.40% | 232.494 | 222.507–239.128 | 2.74% | 0.49x | 5.34x | 5.17x |
| `direct_calls` | 1 | 600 | 55.556 | 55.456–55.851 | 0.29% | 117.546 | 115.360–120.131 | 1.48% | 0.47x | 1.00x | 1.00x |
| `direct_calls` | 2 | 600 | 57.326 | 56.751–59.660 | 1.85% | 119.858 | 118.489–123.398 | 1.38% | 0.48x | 1.94x | 1.96x |
| `direct_calls` | 4 | 600 | 57.934 | 57.854–58.401 | 0.32% | 131.123 | 124.397–133.469 | 2.79% | 0.44x | 3.84x | 3.59x |
| `direct_calls` | 8 | 600 | 78.678 | 74.641–83.897 | 3.76% | 187.041 | 179.193–190.243 | 2.15% | 0.42x | 5.65x | 5.03x |
| `method_calls` | 1 | 500 | 61.201 | 60.977–64.144 | 2.12% | 139.121 | 137.056–141.890 | 1.22% | 0.44x | 1.00x | 1.00x |
| `method_calls` | 2 | 500 | 63.181 | 62.453–69.829 | 4.02% | 142.814 | 142.656–143.032 | 0.08% | 0.44x | 1.94x | 1.95x |
| `method_calls` | 4 | 500 | 75.917 | 64.512–127.589 | 26.43% | 148.628 | 143.032–152.750 | 2.66% | 0.51x | 3.22x | 3.74x |
| `method_calls` | 8 | 500 | 87.060 | 84.744–90.077 | 2.61% | 217.203 | 211.389–234.169 | 3.64% | 0.40x | 5.62x | 5.12x |
| `closure_calls` | 1 | 600 | 61.583 | 61.196–81.110 | 11.05% | 186.455 | 185.248–191.885 | 1.43% | 0.33x | 1.00x | 1.00x |
| `closure_calls` | 2 | 600 | 62.619 | 62.489–65.746 | 2.00% | 191.303 | 190.518–194.327 | 0.73% | 0.33x | 1.97x | 1.95x |
| `closure_calls` | 4 | 600 | 64.259 | 63.939–65.307 | 0.81% | 208.050 | 205.895–214.294 | 1.64% | 0.31x | 3.83x | 3.58x |
| `closure_calls` | 8 | 600 | 85.659 | 78.519–90.836 | 6.42% | 318.143 | 304.215–338.988 | 3.62% | 0.27x | 5.75x | 4.69x |
| `arguments_calls` | 1 | 600 | 66.775 | 66.691–68.811 | 1.14% | 305.103 | 293.264–308.077 | 1.71% | 0.22x | 1.00x | 1.00x |
| `arguments_calls` | 2 | 600 | 84.011 | 83.639–85.161 | 0.64% | 304.660 | 302.661–317.711 | 1.77% | 0.28x | 1.59x | 2.00x |
| `arguments_calls` | 4 | 600 | 70.608 | 69.670–84.213 | 7.60% | 328.536 | 312.660–337.627 | 2.45% | 0.21x | 3.78x | 3.71x |
| `arguments_calls` | 8 | 600 | 95.554 | 88.644–99.219 | 3.47% | 491.736 | 481.385–496.697 | 1.18% | 0.19x | 5.59x | 4.96x |
| `fibonacci` | 1 | 125 | 82.472 | 82.265–85.884 | 1.55% | 449.712 | 446.344–457.791 | 0.85% | 0.18x | 1.00x | 1.00x |
| `fibonacci` | 2 | 125 | 85.759 | 83.852–95.258 | 4.92% | 459.277 | 455.584–460.363 | 0.40% | 0.19x | 1.92x | 1.96x |
| `fibonacci` | 4 | 125 | 95.222 | 88.560–95.740 | 3.38% | 469.419 | 465.200–474.538 | 0.69% | 0.20x | 3.46x | 3.83x |
| `fibonacci` | 8 | 125 | 115.930 | 114.698–122.009 | 2.23% | 667.741 | 658.456–690.449 | 1.55% | 0.17x | 5.69x | 5.39x |

## Independent-context cold lifecycle

Neither engine warms these contexts. The timer covers OS-thread creation, context creation, workload-source
evaluation and configuration, the exact invocation, context destruction, and OS-thread join on both sides.
`scaling` uses the same engine and cold lifecycle at one lane.

| workload | lanes | jobs/lane | zig-js median (ms) | zig-js min–max (ms) | zig-js RSD | JSC median (ms) | JSC min–max (ms) | JSC RSD | JSC / zig-js | zig-js scaling | JSC scaling |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `arithmetic` | 1 | 240 | 77.096 | 76.856–82.580 | 3.44% | 349.807 | 344.746–353.210 | 0.75% | 0.22x | 1.00x | 1.00x |
| `arithmetic` | 2 | 240 | 84.479 | 84.096–88.601 | 1.85% | 356.341 | 353.442–369.047 | 1.77% | 0.24x | 1.83x | 1.96x |
| `arithmetic` | 4 | 240 | 86.677 | 86.348–88.120 | 0.71% | 374.360 | 365.401–387.519 | 2.55% | 0.23x | 3.56x | 3.74x |
| `arithmetic` | 8 | 240 | 102.770 | 100.421–109.451 | 3.61% | 503.810 | 489.691–551.359 | 4.23% | 0.20x | 6.00x | 5.55x |
| `properties` | 1 | 300 | 87.865 | 86.739–89.054 | 1.06% | 288.402 | 286.025–301.475 | 1.84% | 0.30x | 1.00x | 1.00x |
| `properties` | 2 | 300 | 89.346 | 88.558–92.319 | 1.49% | 292.690 | 291.836–311.852 | 2.47% | 0.31x | 1.97x | 1.97x |
| `properties` | 4 | 300 | 90.700 | 90.565–92.861 | 1.12% | 301.266 | 299.299–322.614 | 2.72% | 0.30x | 3.87x | 3.83x |
| `properties` | 8 | 300 | 115.914 | 114.790–129.489 | 4.40% | 417.072 | 407.989–448.857 | 3.80% | 0.28x | 6.06x | 5.53x |
| `polymorphic_properties` | 1 | 400 | 81.806 | 81.347–87.952 | 3.07% | 201.153 | 199.603–204.479 | 0.89% | 0.41x | 1.00x | 1.00x |
| `polymorphic_properties` | 2 | 400 | 84.689 | 83.277–87.322 | 1.91% | 204.336 | 203.560–207.810 | 0.81% | 0.41x | 1.93x | 1.97x |
| `polymorphic_properties` | 4 | 400 | 87.134 | 85.751–88.837 | 1.30% | 209.403 | 208.536–213.308 | 0.92% | 0.42x | 3.76x | 3.84x |
| `polymorphic_properties` | 8 | 400 | 122.076 | 117.027–131.917 | 3.78% | 319.209 | 298.193–331.290 | 4.06% | 0.38x | 5.36x | 5.04x |
| `object_churn` | 1 | 100 | 152.921 | 151.192–157.789 | 1.70% | 115.176 | 114.888–115.858 | 0.28% | 1.33x | 1.00x | 1.00x |
| `object_churn` | 2 | 100 | 162.291 | 160.168–178.469 | 4.94% | 119.386 | 118.433–120.078 | 0.52% | 1.36x | 1.88x | 1.93x |
| `object_churn` | 4 | 100 | 203.132 | 199.428–220.834 | 3.72% | 123.716 | 122.228–131.332 | 2.92% | 1.64x | 3.01x | 3.72x |
| `object_churn` | 8 | 100 | 437.574 | 418.644–487.016 | 5.52% | 177.761 | 169.222–186.589 | 3.72% | 2.46x | 2.80x | 5.18x |
| `arrays` | 1 | 550 | 75.898 | 75.629–78.202 | 1.20% | 152.435 | 147.907–158.100 | 2.34% | 0.50x | 1.00x | 1.00x |
| `arrays` | 2 | 550 | 79.559 | 78.627–81.803 | 1.50% | 152.959 | 152.273–157.787 | 1.42% | 0.52x | 1.91x | 1.99x |
| `arrays` | 4 | 550 | 81.654 | 80.858–83.600 | 1.20% | 156.501 | 154.896–159.361 | 0.91% | 0.52x | 3.72x | 3.90x |
| `arrays` | 8 | 550 | 115.970 | 108.477–138.634 | 8.62% | 243.802 | 235.053–248.136 | 2.18% | 0.48x | 5.24x | 5.00x |
| `direct_calls` | 1 | 600 | 56.912 | 56.841–57.654 | 0.52% | 116.609 | 114.718–126.221 | 4.03% | 0.49x | 1.00x | 1.00x |
| `direct_calls` | 2 | 600 | 61.661 | 59.106–67.701 | 4.71% | 121.545 | 117.145–130.485 | 3.85% | 0.51x | 1.85x | 1.92x |
| `direct_calls` | 4 | 600 | 59.874 | 59.555–75.446 | 9.92% | 131.501 | 129.673–134.072 | 1.30% | 0.46x | 3.80x | 3.55x |
| `direct_calls` | 8 | 600 | 79.879 | 75.897–81.095 | 2.78% | 201.518 | 190.125–209.586 | 3.94% | 0.40x | 5.70x | 4.63x |
| `method_calls` | 1 | 500 | 62.902 | 62.280–65.314 | 1.74% | 158.653 | 140.847–207.257 | 13.18% | 0.40x | 1.00x | 1.00x |
| `method_calls` | 2 | 500 | 67.844 | 65.453–69.071 | 1.74% | 140.995 | 140.162–162.442 | 5.57% | 0.48x | 1.85x | 2.25x |
| `method_calls` | 4 | 500 | 68.854 | 67.643–76.136 | 5.27% | 150.987 | 148.862–160.161 | 2.55% | 0.46x | 3.65x | 4.20x |
| `method_calls` | 8 | 500 | 90.289 | 82.582–96.785 | 5.16% | 219.964 | 217.035–230.673 | 1.98% | 0.41x | 5.57x | 5.77x |
| `closure_calls` | 1 | 600 | 64.195 | 62.554–66.087 | 2.45% | 188.721 | 187.454–201.218 | 3.20% | 0.34x | 1.00x | 1.00x |
| `closure_calls` | 2 | 600 | 64.170 | 64.031–71.418 | 4.14% | 194.627 | 192.686–198.774 | 1.08% | 0.33x | 2.00x | 1.94x |
| `closure_calls` | 4 | 600 | 65.896 | 65.541–79.931 | 7.75% | 213.909 | 206.043–222.711 | 2.73% | 0.31x | 3.90x | 3.53x |
| `closure_calls` | 8 | 600 | 89.924 | 88.416–107.200 | 7.40% | 326.961 | 304.215–331.584 | 2.92% | 0.28x | 5.71x | 4.62x |
| `arguments_calls` | 1 | 600 | 67.994 | 67.841–71.707 | 2.19% | 299.952 | 295.618–305.896 | 1.17% | 0.23x | 1.00x | 1.00x |
| `arguments_calls` | 2 | 600 | 70.105 | 69.359–71.448 | 1.15% | 305.208 | 303.185–309.624 | 0.69% | 0.23x | 1.94x | 1.97x |
| `arguments_calls` | 4 | 600 | 71.791 | 70.916–72.704 | 0.91% | 332.186 | 317.324–335.784 | 1.86% | 0.22x | 3.79x | 3.61x |
| `arguments_calls` | 8 | 600 | 95.776 | 91.679–99.279 | 3.31% | 494.459 | 484.552–504.128 | 1.56% | 0.19x | 5.68x | 4.85x |
| `fibonacci` | 1 | 125 | 83.646 | 83.397–88.590 | 2.53% | 459.513 | 446.622–529.570 | 6.00% | 0.18x | 1.00x | 1.00x |
| `fibonacci` | 2 | 125 | 85.866 | 85.137–92.298 | 3.11% | 459.772 | 457.624–464.898 | 0.50% | 0.19x | 1.95x | 2.00x |
| `fibonacci` | 4 | 125 | 89.112 | 87.092–93.086 | 2.51% | 471.970 | 469.166–489.796 | 1.88% | 0.19x | 3.75x | 3.89x |
| `fibonacci` | 8 | 125 | 122.867 | 117.913–123.558 | 1.86% | 678.313 | 657.701–697.268 | 1.93% | 0.18x | 5.45x | 5.42x |

## zig-js shared-realm scaling

This is zig-js's distinct no-GIL shared-object-graph model, which JSC's public C API does not provide.
The timed region creates JavaScript `Thread`s, performs the work, and joins them. Scaling uses the same
shared-realm path at one lane, so thread lifecycle overhead is present in every row.

| workload | lanes | jobs/lane | median (ms) | min–max (ms) | RSD | scaling |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `arithmetic` | 1 | 240 | 81.397 | 75.612–87.597 | 5.16% | 1.00x |
| `arithmetic` | 2 | 240 | 82.708 | 82.665–86.004 | 1.49% | 1.97x |
| `arithmetic` | 4 | 240 | 85.072 | 84.662–86.201 | 0.84% | 3.83x |
| `arithmetic` | 8 | 240 | 104.888 | 101.071–106.704 | 2.03% | 6.21x |
| `properties` | 1 | 300 | 124.813 | 123.946–127.285 | 1.11% | 1.00x |
| `properties` | 2 | 300 | 126.594 | 126.381–128.793 | 0.80% | 1.97x |
| `properties` | 4 | 300 | 130.766 | 129.580–131.335 | 0.53% | 3.82x |
| `properties` | 8 | 300 | 170.870 | 163.373–177.749 | 3.09% | 5.84x |
| `polymorphic_properties` | 1 | 400 | 513.592 | 506.630–524.761 | 1.27% | 1.00x |
| `polymorphic_properties` | 2 | 400 | 525.079 | 517.978–549.663 | 2.53% | 1.96x |
| `polymorphic_properties` | 4 | 400 | 537.179 | 530.688–555.491 | 1.54% | 3.82x |
| `polymorphic_properties` | 8 | 400 | 694.118 | 688.266–702.043 | 0.73% | 5.92x |
| `object_churn` | 1 | 100 | 350.226 | 153.422–421.587 | 25.06% | 1.00x |
| `object_churn` | 2 | 100 | 676.030 | 243.410–787.075 | 27.87% | 1.04x |
| `object_churn` | 4 | 100 | 1403.741 | 521.145–2752.500 | 44.14% | 1.00x |
| `object_churn` | 8 | 100 | 7658.643 | 2548.865–7946.328 | 28.09% | 0.37x |
| `arrays` | 1 | 550 | 81.129 | 79.581–83.109 | 1.71% | 1.00x |
| `arrays` | 2 | 550 | 83.994 | 83.313–89.614 | 2.66% | 1.93x |
| `arrays` | 4 | 550 | 91.821 | 89.288–111.883 | 8.35% | 3.53x |
| `arrays` | 8 | 550 | 212.559 | 189.100–306.385 | 18.26% | 3.05x |
| `direct_calls` | 1 | 600 | 55.804 | 55.787–59.151 | 2.25% | 1.00x |
| `direct_calls` | 2 | 600 | 57.614 | 56.971–59.552 | 1.65% | 1.94x |
| `direct_calls` | 4 | 600 | 58.786 | 58.366–59.987 | 1.00% | 3.80x |
| `direct_calls` | 8 | 600 | 78.980 | 77.995–81.190 | 1.50% | 5.65x |
| `method_calls` | 1 | 500 | 129.358 | 119.424–221.467 | 25.42% | 1.00x |
| `method_calls` | 2 | 500 | 117.992 | 117.538–121.125 | 1.10% | 2.19x |
| `method_calls` | 4 | 500 | 122.229 | 120.408–127.802 | 2.07% | 4.23x |
| `method_calls` | 8 | 500 | 178.070 | 175.454–183.227 | 1.82% | 5.81x |
| `closure_calls` | 1 | 600 | 62.539 | 62.389–66.850 | 2.60% | 1.00x |
| `closure_calls` | 2 | 600 | 63.776 | 63.614–64.417 | 0.54% | 1.96x |
| `closure_calls` | 4 | 600 | 66.162 | 65.356–72.185 | 3.57% | 3.78x |
| `closure_calls` | 8 | 600 | 87.309 | 84.085–97.045 | 6.03% | 5.73x |
| `arguments_calls` | 1 | 600 | 66.618 | 66.437–69.225 | 1.60% | 1.00x |
| `arguments_calls` | 2 | 600 | 67.714 | 67.412–69.298 | 1.03% | 1.97x |
| `arguments_calls` | 4 | 600 | 69.555 | 69.449–72.879 | 1.89% | 3.83x |
| `arguments_calls` | 8 | 600 | 95.818 | 91.046–113.302 | 7.75% | 5.56x |
| `fibonacci` | 1 | 125 | 247.349 | 242.760–258.265 | 2.13% | 1.00x |
| `fibonacci` | 2 | 125 | 249.097 | 247.411–302.549 | 7.90% | 1.99x |
| `fibonacci` | 4 | 125 | 265.193 | 253.191–274.671 | 2.83% | 3.73x |
| `fibonacci` | 8 | 125 | 375.021 | 368.767–385.511 | 1.56% | 5.28x |

## Reading the result

Across these 10 deliberately small kernels, JSC's single-context throughput is 0.38x
the zig-js throughput by geometric mean. These kernels deliberately exercise guarded native/VM tiers that
zig-js currently implements; rows outside those documented subsets continue through general bytecode paths.
The number is a compact description of this matrix, not a claim about applications or unsupported workloads.

At 8 independent warmed contexts, JSC throughput is 0.36x zig-js by
geometric mean; scaling from the mode's own one-lane baseline is 5.29x
for zig-js and 5.18x for JSC. In the symmetric cold lifecycle, JSC
throughput is 0.36x zig-js, with 5.25x
and 5.15x scaling respectively.

zig-js's shared-realm path scales 4.09x at 8 lanes from its
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
