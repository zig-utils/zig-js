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
| zig-js | aaa2c3abee26984f6243843795fdfded8a0aed6f |
| JavaScriptCore | system framework 22625.1.20.11.3 |
| Power | Now drawing from 'AC Power' -InternalBattery-0 (id=22806627) 100%; charged; 0:00 remaining present: true |

## Single-thread result

Each row runs the same number of jobs in one GC-enabled zig-js context and one warmed JSC global context.
Both runners time the exact invocation `__benchmarkSelected(__benchmarkJobs, __benchmarkLane)`.
Lower time is better; `JSC / zig-js` is JSC throughput divided by zig-js throughput. RSD is relative standard deviation.

| workload | jobs | zig-js median (ms) | zig-js min–max (ms) | zig-js RSD | JSC median (ms) | JSC min–max (ms) | JSC RSD | JSC / zig-js |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `arithmetic` | 240 | 81.505 | 81.425–83.047 | 0.72% | 344.578 | 342.591–350.359 | 0.81% | 0.24x |
| `properties` | 300 | 85.901 | 85.738–87.671 | 0.80% | 287.765 | 286.925–290.504 | 0.48% | 0.30x |
| `polymorphic_properties` | 400 | 80.838 | 80.373–82.778 | 1.04% | 199.300 | 199.091–202.553 | 0.63% | 0.41x |
| `object_churn` | 100 | 117.481 | 116.707–122.021 | 1.62% | 116.026 | 114.900–122.344 | 2.33% | 1.01x |
| `arrays` | 550 | 78.476 | 78.092–88.681 | 5.49% | 153.152 | 151.943–156.113 | 0.90% | 0.51x |
| `direct_calls` | 600 | 57.318 | 56.576–60.769 | 3.09% | 117.799 | 116.581–120.407 | 1.11% | 0.49x |
| `method_calls` | 500 | 63.735 | 62.026–64.035 | 1.44% | 139.215 | 138.492–141.963 | 0.85% | 0.46x |
| `closure_calls` | 600 | 63.065 | 62.124–68.320 | 3.76% | 189.150 | 187.617–191.525 | 0.63% | 0.33x |
| `arguments_calls` | 600 | 68.116 | 67.574–70.266 | 1.60% | 299.102 | 298.352–302.361 | 0.46% | 0.23x |
| `fibonacci` | 125 | 83.452 | 83.152–89.092 | 2.53% | 451.531 | 450.812–452.628 | 0.12% | 0.18x |

## Independent-context steady state

Both engines keep one warmed context on one persistent OS worker per lane. The timed region contains the
same semaphore dispatch, exact invocation, and completion wait. Every lane performs the full job count.
`scaling` uses the same engine and mode at one lane; cross-engine throughput is directly comparable.

| workload | lanes | jobs/lane | zig-js median (ms) | zig-js min–max (ms) | zig-js RSD | JSC median (ms) | JSC min–max (ms) | JSC RSD | JSC / zig-js | zig-js scaling | JSC scaling |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `arithmetic` | 1 | 240 | 81.407 | 81.272–83.036 | 0.86% | 343.832 | 343.358–388.146 | 4.70% | 0.24x | 1.00x | 1.00x |
| `arithmetic` | 2 | 240 | 83.126 | 82.908–89.366 | 2.86% | 355.770 | 353.675–360.341 | 0.78% | 0.23x | 1.96x | 1.93x |
| `arithmetic` | 4 | 240 | 85.072 | 84.972–95.967 | 4.71% | 373.902 | 370.635–376.866 | 0.55% | 0.23x | 3.83x | 3.68x |
| `arithmetic` | 8 | 240 | 103.308 | 101.128–120.648 | 6.38% | 495.683 | 492.646–505.199 | 1.03% | 0.21x | 6.30x | 5.55x |
| `properties` | 1 | 300 | 86.031 | 85.805–87.622 | 0.86% | 286.628 | 286.241–292.191 | 0.75% | 0.30x | 1.00x | 1.00x |
| `properties` | 2 | 300 | 87.818 | 87.534–89.746 | 0.90% | 292.560 | 291.973–296.600 | 0.55% | 0.30x | 1.96x | 1.96x |
| `properties` | 4 | 300 | 89.859 | 89.596–91.703 | 0.82% | 300.408 | 299.742–301.815 | 0.22% | 0.30x | 3.83x | 3.82x |
| `properties` | 8 | 300 | 118.653 | 112.317–123.257 | 3.20% | 430.937 | 422.587–438.581 | 1.28% | 0.28x | 5.80x | 5.32x |
| `polymorphic_properties` | 1 | 400 | 81.106 | 80.399–82.446 | 0.97% | 200.230 | 199.705–201.439 | 0.27% | 0.41x | 1.00x | 1.00x |
| `polymorphic_properties` | 2 | 400 | 83.124 | 82.266–95.867 | 5.79% | 204.212 | 203.811–206.534 | 0.44% | 0.41x | 1.95x | 1.96x |
| `polymorphic_properties` | 4 | 400 | 84.818 | 84.401–87.222 | 1.18% | 213.737 | 210.610–224.020 | 2.00% | 0.40x | 3.82x | 3.75x |
| `polymorphic_properties` | 8 | 400 | 120.807 | 117.755–128.413 | 2.79% | 315.832 | 307.022–333.427 | 2.80% | 0.38x | 5.37x | 5.07x |
| `object_churn` | 1 | 100 | 116.479 | 116.012–121.179 | 1.56% | 114.820 | 114.581–117.502 | 0.90% | 1.01x | 1.00x | 1.00x |
| `object_churn` | 2 | 100 | 127.593 | 126.277–138.548 | 3.36% | 118.941 | 118.683–122.305 | 1.32% | 1.07x | 1.83x | 1.93x |
| `object_churn` | 4 | 100 | 184.224 | 183.274–194.989 | 2.24% | 122.691 | 122.089–124.250 | 0.61% | 1.50x | 2.53x | 3.74x |
| `object_churn` | 8 | 100 | 351.185 | 346.506–447.012 | 10.07% | 174.828 | 168.808–176.267 | 1.61% | 2.01x | 2.65x | 5.25x |
| `arrays` | 1 | 550 | 78.622 | 78.022–82.671 | 2.09% | 153.839 | 152.420–154.708 | 0.55% | 0.51x | 1.00x | 1.00x |
| `arrays` | 2 | 550 | 80.884 | 80.441–83.072 | 1.19% | 157.206 | 156.168–158.905 | 0.57% | 0.51x | 1.94x | 1.96x |
| `arrays` | 4 | 550 | 92.514 | 84.904–108.355 | 9.06% | 158.202 | 157.893–163.210 | 1.20% | 0.58x | 3.40x | 3.89x |
| `arrays` | 8 | 550 | 120.212 | 115.841–129.669 | 4.15% | 241.182 | 235.285–248.549 | 1.65% | 0.50x | 5.23x | 5.10x |
| `direct_calls` | 1 | 600 | 70.120 | 69.975–71.691 | 1.03% | 116.741 | 116.222–120.412 | 1.27% | 0.60x | 1.00x | 1.00x |
| `direct_calls` | 2 | 600 | 57.191 | 57.098–59.340 | 1.55% | 120.058 | 118.826–122.369 | 0.94% | 0.48x | 2.45x | 1.94x |
| `direct_calls` | 4 | 600 | 59.592 | 59.001–62.241 | 1.99% | 130.166 | 129.868–131.840 | 0.51% | 0.46x | 4.71x | 3.59x |
| `direct_calls` | 8 | 600 | 80.747 | 78.035–86.155 | 4.36% | 190.897 | 187.373–202.077 | 2.76% | 0.42x | 6.95x | 4.89x |
| `method_calls` | 1 | 500 | 62.779 | 61.851–65.697 | 2.49% | 140.390 | 138.704–177.824 | 9.83% | 0.45x | 1.00x | 1.00x |
| `method_calls` | 2 | 500 | 65.768 | 65.126–67.933 | 1.40% | 141.962 | 141.478–144.865 | 0.83% | 0.46x | 1.91x | 1.98x |
| `method_calls` | 4 | 500 | 64.907 | 64.561–72.580 | 4.37% | 149.395 | 147.953–150.856 | 0.74% | 0.43x | 3.87x | 3.76x |
| `method_calls` | 8 | 500 | 91.679 | 82.628–108.567 | 8.88% | 221.452 | 214.757–235.370 | 3.23% | 0.41x | 5.48x | 5.07x |
| `closure_calls` | 1 | 600 | 74.551 | 73.462–77.291 | 1.88% | 187.725 | 187.234–190.546 | 0.65% | 0.40x | 1.00x | 1.00x |
| `closure_calls` | 2 | 600 | 63.376 | 63.233–65.086 | 1.12% | 199.242 | 198.025–205.598 | 1.30% | 0.32x | 2.35x | 1.88x |
| `closure_calls` | 4 | 600 | 65.251 | 64.798–68.189 | 1.94% | 209.256 | 208.443–215.176 | 1.20% | 0.31x | 4.57x | 3.59x |
| `closure_calls` | 8 | 600 | 106.872 | 94.170–151.926 | 17.22% | 344.971 | 312.280–361.818 | 5.02% | 0.31x | 5.58x | 4.35x |
| `arguments_calls` | 1 | 600 | 67.657 | 67.442–68.956 | 0.97% | 299.500 | 298.579–304.351 | 0.65% | 0.23x | 1.00x | 1.00x |
| `arguments_calls` | 2 | 600 | 71.588 | 70.001–73.568 | 2.12% | 309.755 | 306.761–317.531 | 1.12% | 0.23x | 1.89x | 1.93x |
| `arguments_calls` | 4 | 600 | 71.529 | 70.551–74.067 | 1.71% | 331.961 | 328.289–334.028 | 0.52% | 0.22x | 3.78x | 3.61x |
| `arguments_calls` | 8 | 600 | 94.945 | 90.853–153.755 | 21.59% | 498.824 | 487.629–528.150 | 2.55% | 0.19x | 5.70x | 4.80x |
| `fibonacci` | 1 | 125 | 83.681 | 83.253–85.293 | 0.93% | 452.082 | 451.460–455.529 | 0.31% | 0.19x | 1.00x | 1.00x |
| `fibonacci` | 2 | 125 | 85.419 | 84.899–86.956 | 0.93% | 460.152 | 459.369–461.019 | 0.14% | 0.19x | 1.96x | 1.96x |
| `fibonacci` | 4 | 125 | 88.062 | 87.291–101.214 | 5.57% | 473.632 | 472.870–474.923 | 0.15% | 0.19x | 3.80x | 3.82x |
| `fibonacci` | 8 | 125 | 123.021 | 117.475–127.319 | 2.96% | 673.352 | 665.799–685.232 | 0.97% | 0.18x | 5.44x | 5.37x |

## Independent-context cold lifecycle

Neither engine warms these contexts. The timer covers OS-thread creation, context creation, workload-source
evaluation and configuration, the exact invocation, context destruction, and OS-thread join on both sides.
`scaling` uses the same engine and cold lifecycle at one lane.

| workload | lanes | jobs/lane | zig-js median (ms) | zig-js min–max (ms) | zig-js RSD | JSC median (ms) | JSC min–max (ms) | JSC RSD | JSC / zig-js | zig-js scaling | JSC scaling |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `arithmetic` | 1 | 240 | 83.050 | 82.982–84.972 | 1.01% | 349.832 | 343.459–355.932 | 1.28% | 0.24x | 1.00x | 1.00x |
| `arithmetic` | 2 | 240 | 85.424 | 84.781–87.720 | 1.28% | 359.293 | 352.513–362.552 | 0.98% | 0.24x | 1.94x | 1.95x |
| `arithmetic` | 4 | 240 | 87.379 | 86.821–88.322 | 0.69% | 373.211 | 368.798–382.344 | 1.14% | 0.23x | 3.80x | 3.75x |
| `arithmetic` | 8 | 240 | 106.375 | 102.562–108.177 | 1.82% | 505.665 | 504.836–522.873 | 1.30% | 0.21x | 6.25x | 5.53x |
| `properties` | 1 | 300 | 87.427 | 87.002–89.218 | 0.96% | 287.701 | 287.378–304.636 | 2.18% | 0.30x | 1.00x | 1.00x |
| `properties` | 2 | 300 | 92.265 | 89.933–92.945 | 1.09% | 304.754 | 294.352–349.953 | 6.31% | 0.30x | 1.90x | 1.89x |
| `properties` | 4 | 300 | 91.399 | 91.163–93.336 | 1.00% | 302.482 | 301.336–343.659 | 5.09% | 0.30x | 3.83x | 3.80x |
| `properties` | 8 | 300 | 121.132 | 116.163–138.047 | 5.88% | 439.554 | 437.207–485.027 | 3.87% | 0.28x | 5.77x | 5.24x |
| `polymorphic_properties` | 1 | 400 | 82.051 | 81.794–84.138 | 1.16% | 201.122 | 200.435–205.250 | 0.82% | 0.41x | 1.00x | 1.00x |
| `polymorphic_properties` | 2 | 400 | 84.110 | 84.059–86.333 | 1.19% | 205.566 | 204.599–208.916 | 0.81% | 0.41x | 1.95x | 1.96x |
| `polymorphic_properties` | 4 | 400 | 86.720 | 86.162–124.718 | 15.36% | 217.358 | 216.263–218.500 | 0.36% | 0.40x | 3.78x | 3.70x |
| `polymorphic_properties` | 8 | 400 | 123.546 | 119.676–127.245 | 2.48% | 316.558 | 311.624–325.957 | 1.52% | 0.39x | 5.31x | 5.08x |
| `object_churn` | 1 | 100 | 118.301 | 118.207–122.328 | 1.27% | 116.044 | 115.725–118.966 | 1.03% | 1.02x | 1.00x | 1.00x |
| `object_churn` | 2 | 100 | 129.799 | 128.927–143.403 | 4.69% | 120.744 | 119.665–123.401 | 1.17% | 1.07x | 1.82x | 1.92x |
| `object_churn` | 4 | 100 | 189.649 | 185.684–212.863 | 4.83% | 123.761 | 123.296–127.401 | 1.15% | 1.53x | 2.50x | 3.75x |
| `object_churn` | 8 | 100 | 356.521 | 350.607–394.555 | 4.14% | 178.590 | 171.189–189.279 | 4.01% | 2.00x | 2.65x | 5.20x |
| `arrays` | 1 | 550 | 77.107 | 76.740–80.167 | 1.74% | 154.635 | 154.035–158.810 | 1.06% | 0.50x | 1.00x | 1.00x |
| `arrays` | 2 | 550 | 79.922 | 79.666–135.188 | 23.27% | 156.020 | 155.340–160.225 | 1.09% | 0.51x | 1.93x | 1.98x |
| `arrays` | 4 | 550 | 82.811 | 82.481–87.385 | 2.70% | 159.125 | 158.337–164.272 | 1.35% | 0.52x | 3.72x | 3.89x |
| `arrays` | 8 | 550 | 120.969 | 117.090–156.478 | 11.42% | 246.459 | 238.594–248.252 | 1.34% | 0.49x | 5.10x | 5.02x |
| `direct_calls` | 1 | 600 | 58.114 | 57.728–59.572 | 1.10% | 118.813 | 117.347–121.728 | 1.21% | 0.49x | 1.00x | 1.00x |
| `direct_calls` | 2 | 600 | 59.594 | 59.458–75.440 | 10.21% | 120.302 | 119.956–123.410 | 1.01% | 0.50x | 1.95x | 1.98x |
| `direct_calls` | 4 | 600 | 76.420 | 75.782–79.173 | 1.57% | 132.784 | 131.666–135.839 | 1.04% | 0.58x | 3.04x | 3.58x |
| `direct_calls` | 8 | 600 | 87.336 | 85.704–92.133 | 2.78% | 196.448 | 193.631–245.718 | 9.18% | 0.44x | 5.32x | 4.84x |
| `method_calls` | 1 | 500 | 65.867 | 65.441–67.013 | 0.96% | 139.540 | 139.218–143.324 | 1.06% | 0.47x | 1.00x | 1.00x |
| `method_calls` | 2 | 500 | 65.132 | 64.897–67.034 | 1.39% | 142.446 | 142.083–146.358 | 1.06% | 0.46x | 2.02x | 1.96x |
| `method_calls` | 4 | 500 | 67.872 | 67.256–70.101 | 1.52% | 152.229 | 151.306–153.716 | 0.67% | 0.45x | 3.88x | 3.67x |
| `method_calls` | 8 | 500 | 95.262 | 88.371–99.780 | 4.34% | 223.216 | 219.565–234.224 | 2.43% | 0.43x | 5.53x | 5.00x |
| `closure_calls` | 1 | 600 | 63.629 | 63.274–65.295 | 1.21% | 189.697 | 189.027–192.732 | 0.67% | 0.34x | 1.00x | 1.00x |
| `closure_calls` | 2 | 600 | 65.298 | 64.833–67.190 | 1.22% | 194.735 | 193.719–200.429 | 1.17% | 0.34x | 1.95x | 1.95x |
| `closure_calls` | 4 | 600 | 66.942 | 66.457–73.585 | 3.85% | 215.786 | 211.030–253.964 | 7.14% | 0.31x | 3.80x | 3.52x |
| `closure_calls` | 8 | 600 | 90.336 | 85.607–93.184 | 3.47% | 323.260 | 312.114–328.308 | 1.70% | 0.28x | 5.63x | 4.69x |
| `arguments_calls` | 1 | 600 | 69.962 | 68.756–70.969 | 1.34% | 300.151 | 299.566–305.122 | 0.65% | 0.23x | 1.00x | 1.00x |
| `arguments_calls` | 2 | 600 | 85.413 | 81.409–87.945 | 3.20% | 309.662 | 308.072–313.478 | 0.59% | 0.28x | 1.64x | 1.94x |
| `arguments_calls` | 4 | 600 | 76.330 | 71.925–83.925 | 5.14% | 337.310 | 335.294–343.362 | 0.85% | 0.23x | 3.67x | 3.56x |
| `arguments_calls` | 8 | 600 | 98.064 | 94.704–109.278 | 6.05% | 505.272 | 493.668–526.688 | 2.10% | 0.19x | 5.71x | 4.75x |
| `fibonacci` | 1 | 125 | 84.843 | 84.559–93.568 | 3.86% | 452.262 | 451.401–456.848 | 0.42% | 0.19x | 1.00x | 1.00x |
| `fibonacci` | 2 | 125 | 86.941 | 86.715–88.079 | 0.67% | 461.724 | 460.824–483.039 | 1.75% | 0.19x | 1.95x | 1.96x |
| `fibonacci` | 4 | 125 | 91.189 | 88.724–104.948 | 6.23% | 476.696 | 475.467–493.089 | 1.29% | 0.19x | 3.72x | 3.79x |
| `fibonacci` | 8 | 125 | 126.879 | 122.843–137.055 | 3.84% | 681.719 | 677.044–787.696 | 5.76% | 0.19x | 5.35x | 5.31x |

## zig-js shared-realm scaling

This is zig-js's distinct no-GIL shared-object-graph model, which JSC's public C API does not provide.
The timed region creates JavaScript `Thread`s, performs the work, and joins them. Scaling uses the same
shared-realm path at one lane, so thread lifecycle overhead is present in every row.

| workload | lanes | jobs/lane | median (ms) | min–max (ms) | RSD | scaling |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `arithmetic` | 1 | 240 | 81.561 | 81.461–83.066 | 0.76% | 1.00x |
| `arithmetic` | 2 | 240 | 83.296 | 83.093–85.107 | 0.85% | 1.96x |
| `arithmetic` | 4 | 240 | 85.385 | 85.186–86.711 | 0.77% | 3.82x |
| `arithmetic` | 8 | 240 | 104.743 | 100.083–118.115 | 6.54% | 6.23x |
| `properties` | 1 | 300 | 124.909 | 124.676–127.152 | 0.70% | 1.00x |
| `properties` | 2 | 300 | 127.669 | 127.448–130.250 | 0.78% | 1.96x |
| `properties` | 4 | 300 | 130.446 | 130.275–132.810 | 0.69% | 3.83x |
| `properties` | 8 | 300 | 167.770 | 166.829–170.750 | 0.88% | 5.96x |
| `polymorphic_properties` | 1 | 400 | 511.306 | 508.042–514.724 | 0.38% | 1.00x |
| `polymorphic_properties` | 2 | 400 | 520.185 | 519.402–526.098 | 0.48% | 1.97x |
| `polymorphic_properties` | 4 | 400 | 532.872 | 530.340–540.665 | 0.64% | 3.84x |
| `polymorphic_properties` | 8 | 400 | 717.688 | 712.815–720.435 | 0.40% | 5.70x |
| `object_churn` | 1 | 100 | 192.868 | 170.235–220.432 | 7.54% | 1.00x |
| `object_churn` | 2 | 100 | 350.919 | 241.407–375.197 | 12.92% | 1.10x |
| `object_churn` | 4 | 100 | 730.610 | 534.046–1879.840 | 50.35% | 1.06x |
| `object_churn` | 8 | 100 | 5192.344 | 2701.440–6292.456 | 22.95% | 0.30x |
| `arrays` | 1 | 550 | 82.504 | 81.283–87.221 | 2.85% | 1.00x |
| `arrays` | 2 | 550 | 86.114 | 85.599–88.647 | 1.17% | 1.92x |
| `arrays` | 4 | 550 | 95.278 | 92.114–118.858 | 9.59% | 3.46x |
| `arrays` | 8 | 550 | 223.361 | 222.011–257.910 | 5.76% | 2.96x |
| `direct_calls` | 1 | 600 | 56.815 | 56.580–59.968 | 2.10% | 1.00x |
| `direct_calls` | 2 | 600 | 57.912 | 57.576–63.408 | 4.02% | 1.96x |
| `direct_calls` | 4 | 600 | 59.277 | 59.094–61.583 | 1.76% | 3.83x |
| `direct_calls` | 8 | 600 | 79.160 | 76.933–88.154 | 4.69% | 5.74x |
| `method_calls` | 1 | 500 | 115.685 | 115.235–123.823 | 2.78% | 1.00x |
| `method_calls` | 2 | 500 | 120.368 | 120.258–122.990 | 0.83% | 1.92x |
| `method_calls` | 4 | 500 | 123.564 | 122.831–132.560 | 2.87% | 3.74x |
| `method_calls` | 8 | 500 | 181.472 | 179.715–185.589 | 1.16% | 5.10x |
| `closure_calls` | 1 | 600 | 63.498 | 63.349–64.941 | 1.03% | 1.00x |
| `closure_calls` | 2 | 600 | 64.928 | 64.671–66.751 | 1.12% | 1.96x |
| `closure_calls` | 4 | 600 | 70.945 | 69.293–77.489 | 4.45% | 3.58x |
| `closure_calls` | 8 | 600 | 90.690 | 86.929–92.758 | 2.67% | 5.60x |
| `arguments_calls` | 1 | 600 | 67.887 | 67.215–73.823 | 3.91% | 1.00x |
| `arguments_calls` | 2 | 600 | 73.045 | 68.598–81.740 | 6.28% | 1.86x |
| `arguments_calls` | 4 | 600 | 74.844 | 72.428–91.145 | 8.90% | 3.63x |
| `arguments_calls` | 8 | 600 | 94.387 | 90.878–101.134 | 3.54% | 5.75x |
| `fibonacci` | 1 | 125 | 246.377 | 246.133–248.459 | 0.33% | 1.00x |
| `fibonacci` | 2 | 125 | 251.509 | 250.644–264.147 | 1.91% | 1.96x |
| `fibonacci` | 4 | 125 | 263.603 | 259.084–264.201 | 0.70% | 3.74x |
| `fibonacci` | 8 | 125 | 384.350 | 373.864–403.423 | 2.46% | 5.13x |

## Reading the result

Across these 10 deliberately small kernels, JSC's single-context throughput is 0.37x
the zig-js throughput by geometric mean. These kernels deliberately exercise guarded native/VM tiers that
zig-js currently implements; rows outside those documented subsets continue through general bytecode paths.
The number is a compact description of this matrix, not a claim about applications or unsupported workloads.

At 8 independent warmed contexts, JSC throughput is 0.36x zig-js by
geometric mean; scaling from the mode's own one-lane baseline is 5.31x
for zig-js and 5.07x for JSC. In the symmetric cold lifecycle, JSC
throughput is 0.37x zig-js, with 5.15x
and 5.06x scaling respectively.

zig-js's shared-realm path scales 3.94x at 8 lanes from its
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
