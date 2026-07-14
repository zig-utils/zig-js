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
| zig-js | b8a49730b66e1323db477ab7cdf42b14e81d59ce |
| JavaScriptCore | system framework 22625.1.20.11.3 |
| Power | Now drawing from 'AC Power' -InternalBattery-0 (id=22806627) 93%; charging; (no estimate) present: true |

## Single-thread result

Each row runs the same number of jobs in one GC-enabled zig-js context and one warmed JSC global context.
Both runners time the exact invocation `__benchmarkSelected(__benchmarkJobs, __benchmarkLane)`.
Lower time is better; `JSC / zig-js` is JSC throughput divided by zig-js throughput. RSD is relative standard deviation.

| workload | jobs | zig-js median (ms) | zig-js min–max (ms) | zig-js RSD | JSC median (ms) | JSC min–max (ms) | JSC RSD | JSC / zig-js |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `arithmetic` | 160 | 57.985 | 57.115–79.815 | 13.41% | 242.631 | 236.027–253.550 | 2.66% | 0.24x |
| `properties` | 200 | 57.995 | 57.677–60.697 | 2.36% | 207.635 | 195.636–240.196 | 8.14% | 0.28x |
| `polymorphic_properties` | 350 | 70.679 | 70.356–73.500 | 1.59% | 175.571 | 175.061–178.530 | 0.84% | 0.40x |
| `object_churn` | 100 | 195.331 | 184.936–207.611 | 4.45% | 116.085 | 114.356–130.030 | 4.72% | 1.68x |
| `arrays` | 450 | 68.510 | 67.211–89.802 | 11.38% | 135.381 | 133.012–145.223 | 3.59% | 0.51x |
| `direct_calls` | 500 | 67.249 | 66.327–71.366 | 2.95% | 99.113 | 98.220–107.938 | 3.37% | 0.68x |
| `method_calls` | 500 | 80.230 | 78.210–82.569 | 2.16% | 161.170 | 148.826–252.470 | 22.19% | 0.50x |
| `closure_calls` | 500 | 71.319 | 68.839–101.745 | 15.29% | 165.288 | 161.496–171.596 | 1.94% | 0.43x |
| `arguments_calls` | 400 | 60.032 | 58.721–72.533 | 9.33% | 214.764 | 202.482–231.457 | 4.91% | 0.28x |
| `fibonacci` | 100 | 67.460 | 67.124–71.973 | 2.81% | 367.172 | 365.468–380.555 | 1.45% | 0.18x |

## Independent-context steady state

Both engines keep one warmed context on one persistent OS worker per lane. The timed region contains the
same semaphore dispatch, exact invocation, and completion wait. Every lane performs the full job count.
`scaling` uses the same engine and mode at one lane; cross-engine throughput is directly comparable.

| workload | lanes | jobs/lane | zig-js median (ms) | zig-js min–max (ms) | zig-js RSD | JSC median (ms) | JSC min–max (ms) | JSC RSD | JSC / zig-js | zig-js scaling | JSC scaling |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `arithmetic` | 1 | 160 | 55.716 | 54.428–57.398 | 1.92% | 234.501 | 231.145–236.334 | 0.93% | 0.24x | 1.00x | 1.00x |
| `arithmetic` | 2 | 160 | 55.537 | 55.433–57.562 | 1.40% | 239.986 | 237.707–241.504 | 0.64% | 0.23x | 2.01x | 1.95x |
| `arithmetic` | 4 | 160 | 57.319 | 56.811–59.251 | 1.50% | 261.173 | 248.612–271.282 | 3.37% | 0.22x | 3.89x | 3.59x |
| `arithmetic` | 8 | 160 | 69.600 | 67.644–72.751 | 2.98% | 380.226 | 349.201–399.091 | 4.54% | 0.18x | 6.40x | 4.93x |
| `properties` | 1 | 200 | 58.422 | 57.209–59.906 | 1.66% | 194.601 | 192.216–203.904 | 2.11% | 0.30x | 1.00x | 1.00x |
| `properties` | 2 | 200 | 62.904 | 59.549–70.992 | 6.75% | 196.259 | 196.076–200.136 | 0.79% | 0.32x | 1.86x | 1.98x |
| `properties` | 4 | 200 | 61.851 | 60.998–67.262 | 3.59% | 216.950 | 208.619–244.637 | 5.36% | 0.29x | 3.78x | 3.59x |
| `properties` | 8 | 200 | 86.539 | 83.798–92.015 | 3.62% | 343.773 | 328.165–357.163 | 3.42% | 0.25x | 5.40x | 4.53x |
| `polymorphic_properties` | 1 | 350 | 73.203 | 72.070–82.258 | 4.83% | 181.782 | 177.076–192.679 | 2.76% | 0.40x | 1.00x | 1.00x |
| `polymorphic_properties` | 2 | 350 | 78.066 | 72.367–98.868 | 13.98% | 185.605 | 179.067–208.359 | 5.97% | 0.42x | 1.88x | 1.96x |
| `polymorphic_properties` | 4 | 350 | 77.284 | 75.003–82.755 | 3.64% | 242.405 | 188.047–276.063 | 15.59% | 0.32x | 3.79x | 3.00x |
| `polymorphic_properties` | 8 | 350 | 109.485 | 104.410–119.820 | 5.12% | 281.153 | 272.493–290.284 | 1.97% | 0.39x | 5.35x | 5.17x |
| `object_churn` | 1 | 100 | 195.351 | 182.915–206.377 | 4.62% | 114.977 | 114.585–117.049 | 0.74% | 1.70x | 1.00x | 1.00x |
| `object_churn` | 2 | 100 | 215.435 | 200.979–237.216 | 5.98% | 119.267 | 118.674–160.565 | 12.24% | 1.81x | 1.81x | 1.93x |
| `object_churn` | 4 | 100 | 370.276 | 337.604–458.933 | 10.49% | 126.253 | 122.306–138.115 | 4.08% | 2.93x | 2.11x | 3.64x |
| `object_churn` | 8 | 100 | 759.314 | 577.227–821.625 | 13.87% | 179.617 | 172.991–195.938 | 4.37% | 4.23x | 2.06x | 5.12x |
| `arrays` | 1 | 450 | 68.889 | 65.880–69.907 | 2.00% | 131.808 | 129.959–205.500 | 19.28% | 0.52x | 1.00x | 1.00x |
| `arrays` | 2 | 450 | 77.268 | 69.382–81.654 | 5.87% | 140.384 | 133.944–178.032 | 10.57% | 0.55x | 1.78x | 1.88x |
| `arrays` | 4 | 450 | 93.300 | 86.638–111.778 | 9.31% | 193.519 | 177.588–199.290 | 4.35% | 0.48x | 2.95x | 2.72x |
| `arrays` | 8 | 450 | 130.606 | 117.313–151.439 | 9.48% | 252.425 | 237.514–276.991 | 6.34% | 0.52x | 4.22x | 4.18x |
| `direct_calls` | 1 | 500 | 66.739 | 65.215–69.362 | 2.39% | 101.089 | 98.930–105.616 | 2.38% | 0.66x | 1.00x | 1.00x |
| `direct_calls` | 2 | 500 | 64.667 | 64.358–69.067 | 3.11% | 102.713 | 99.965–120.482 | 6.61% | 0.63x | 2.06x | 1.97x |
| `direct_calls` | 4 | 500 | 72.950 | 69.638–77.085 | 3.61% | 122.727 | 118.211–135.649 | 4.96% | 0.59x | 3.66x | 3.29x |
| `direct_calls` | 8 | 500 | 102.391 | 89.311–132.624 | 15.96% | 193.314 | 184.141–207.120 | 3.89% | 0.53x | 5.21x | 4.18x |
| `method_calls` | 1 | 500 | 80.494 | 78.548–95.106 | 7.08% | 144.107 | 140.431–158.488 | 4.98% | 0.56x | 1.00x | 1.00x |
| `method_calls` | 2 | 500 | 82.287 | 80.465–101.409 | 8.62% | 144.764 | 142.237–179.141 | 9.07% | 0.57x | 1.96x | 1.99x |
| `method_calls` | 4 | 500 | 88.480 | 82.822–103.885 | 9.14% | 172.443 | 169.026–189.595 | 4.59% | 0.51x | 3.64x | 3.34x |
| `method_calls` | 8 | 500 | 121.175 | 114.644–141.143 | 7.81% | 254.133 | 237.343–297.670 | 9.64% | 0.48x | 5.31x | 4.54x |
| `closure_calls` | 1 | 500 | 71.080 | 68.203–73.513 | 2.60% | 173.295 | 160.298–267.683 | 20.42% | 0.41x | 1.00x | 1.00x |
| `closure_calls` | 2 | 500 | 76.013 | 74.537–86.362 | 6.21% | 165.087 | 162.899–184.788 | 4.65% | 0.46x | 1.87x | 2.10x |
| `closure_calls` | 4 | 500 | 72.629 | 71.213–89.285 | 8.91% | 185.905 | 183.693–237.744 | 9.96% | 0.39x | 3.91x | 3.73x |
| `closure_calls` | 8 | 500 | 95.429 | 91.209–105.191 | 4.96% | 289.772 | 281.821–349.189 | 7.68% | 0.33x | 5.96x | 4.78x |
| `arguments_calls` | 1 | 400 | 61.754 | 60.609–63.157 | 1.42% | 203.517 | 201.606–223.263 | 4.34% | 0.30x | 1.00x | 1.00x |
| `arguments_calls` | 2 | 400 | 61.054 | 59.233–72.444 | 7.70% | 217.347 | 210.223–222.418 | 2.16% | 0.28x | 2.02x | 1.87x |
| `arguments_calls` | 4 | 400 | 66.616 | 61.587–91.069 | 14.68% | 297.134 | 242.845–302.271 | 9.00% | 0.22x | 3.71x | 2.74x |
| `arguments_calls` | 8 | 400 | 84.401 | 77.784–117.954 | 15.85% | 355.191 | 347.877–361.262 | 1.28% | 0.24x | 5.85x | 4.58x |
| `fibonacci` | 1 | 100 | 68.313 | 67.146–68.575 | 0.91% | 378.834 | 366.924–462.310 | 8.70% | 0.18x | 1.00x | 1.00x |
| `fibonacci` | 2 | 100 | 68.813 | 68.202–71.770 | 1.91% | 370.354 | 369.597–431.178 | 6.04% | 0.19x | 1.99x | 2.05x |
| `fibonacci` | 4 | 100 | 78.614 | 72.731–106.833 | 15.58% | 453.942 | 405.570–490.481 | 7.02% | 0.17x | 3.48x | 3.34x |
| `fibonacci` | 8 | 100 | 105.913 | 105.204–108.607 | 1.17% | 607.319 | 596.065–624.974 | 1.62% | 0.17x | 5.16x | 4.99x |

## Independent-context cold lifecycle

Neither engine warms these contexts. The timer covers OS-thread creation, context creation, workload-source
evaluation and configuration, the exact invocation, context destruction, and OS-thread join on both sides.
`scaling` uses the same engine and cold lifecycle at one lane.

| workload | lanes | jobs/lane | zig-js median (ms) | zig-js min–max (ms) | zig-js RSD | JSC median (ms) | JSC min–max (ms) | JSC RSD | JSC / zig-js | zig-js scaling | JSC scaling |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `arithmetic` | 1 | 160 | 58.019 | 56.054–60.587 | 3.15% | 236.748 | 233.348–241.230 | 1.25% | 0.25x | 1.00x | 1.00x |
| `arithmetic` | 2 | 160 | 57.626 | 57.297–59.364 | 1.26% | 242.729 | 238.225–301.616 | 9.26% | 0.24x | 2.01x | 1.95x |
| `arithmetic` | 4 | 160 | 59.172 | 58.707–60.921 | 1.30% | 252.221 | 248.506–256.205 | 1.07% | 0.23x | 3.92x | 3.75x |
| `arithmetic` | 8 | 160 | 75.162 | 70.356–77.411 | 3.54% | 360.458 | 348.279–379.361 | 2.82% | 0.21x | 6.18x | 5.25x |
| `properties` | 1 | 200 | 69.965 | 59.345–80.776 | 12.44% | 216.089 | 200.966–274.060 | 11.54% | 0.32x | 1.00x | 1.00x |
| `properties` | 2 | 200 | 73.016 | 64.234–85.327 | 10.92% | 202.113 | 197.587–272.301 | 13.16% | 0.36x | 1.92x | 2.14x |
| `properties` | 4 | 200 | 75.620 | 64.185–82.351 | 8.83% | 309.640 | 225.974–398.157 | 20.32% | 0.24x | 3.70x | 2.79x |
| `properties` | 8 | 200 | 83.527 | 81.221–114.675 | 13.82% | 320.738 | 307.348–401.571 | 10.55% | 0.26x | 6.70x | 5.39x |
| `polymorphic_properties` | 1 | 350 | 87.449 | 73.310–117.395 | 17.82% | 194.022 | 177.010–210.987 | 6.83% | 0.45x | 1.00x | 1.00x |
| `polymorphic_properties` | 2 | 350 | 76.232 | 74.473–85.584 | 5.01% | 179.934 | 179.156–191.225 | 2.40% | 0.42x | 2.29x | 2.16x |
| `polymorphic_properties` | 4 | 350 | 79.258 | 76.787–93.556 | 7.36% | 221.953 | 199.685–246.870 | 7.27% | 0.36x | 4.41x | 3.50x |
| `polymorphic_properties` | 8 | 350 | 109.453 | 107.144–121.619 | 4.52% | 283.027 | 273.898–291.274 | 2.07% | 0.39x | 6.39x | 5.48x |
| `object_churn` | 1 | 100 | 185.660 | 182.943–228.944 | 8.63% | 116.917 | 115.789–121.195 | 1.55% | 1.59x | 1.00x | 1.00x |
| `object_churn` | 2 | 100 | 188.220 | 186.058–199.988 | 2.53% | 120.574 | 120.025–124.041 | 1.22% | 1.56x | 1.97x | 1.94x |
| `object_churn` | 4 | 100 | 286.266 | 281.585–329.134 | 5.80% | 128.440 | 124.662–137.489 | 3.41% | 2.23x | 2.59x | 3.64x |
| `object_churn` | 8 | 100 | 597.549 | 548.966–674.712 | 7.54% | 175.780 | 166.062–205.548 | 7.06% | 3.40x | 2.49x | 5.32x |
| `arrays` | 1 | 450 | 66.516 | 65.179–72.018 | 3.37% | 134.798 | 132.803–158.558 | 7.27% | 0.49x | 1.00x | 1.00x |
| `arrays` | 2 | 450 | 70.986 | 68.199–78.112 | 5.11% | 141.063 | 138.350–174.870 | 8.91% | 0.50x | 1.87x | 1.91x |
| `arrays` | 4 | 450 | 82.477 | 74.594–102.350 | 12.89% | 174.005 | 160.133–181.277 | 4.46% | 0.47x | 3.23x | 3.10x |
| `arrays` | 8 | 450 | 112.838 | 108.331–138.345 | 10.08% | 234.762 | 224.597–267.826 | 6.76% | 0.48x | 4.72x | 4.59x |
| `direct_calls` | 1 | 500 | 66.307 | 65.205–70.533 | 2.96% | 103.433 | 100.236–128.118 | 8.92% | 0.64x | 1.00x | 1.00x |
| `direct_calls` | 2 | 500 | 70.518 | 69.437–83.597 | 7.13% | 122.623 | 106.810–136.332 | 10.09% | 0.58x | 1.88x | 1.69x |
| `direct_calls` | 4 | 500 | 73.193 | 71.824–77.338 | 2.44% | 122.139 | 119.544–137.592 | 5.14% | 0.60x | 3.62x | 3.39x |
| `direct_calls` | 8 | 500 | 90.282 | 86.916–96.786 | 3.73% | 192.117 | 184.556–208.858 | 3.95% | 0.47x | 5.88x | 4.31x |
| `method_calls` | 1 | 500 | 86.182 | 79.982–103.639 | 10.39% | 148.162 | 144.754–199.356 | 12.36% | 0.58x | 1.00x | 1.00x |
| `method_calls` | 2 | 500 | 86.736 | 84.560–95.422 | 4.15% | 150.723 | 147.175–178.708 | 7.38% | 0.58x | 1.99x | 1.97x |
| `method_calls` | 4 | 500 | 83.449 | 83.317–89.027 | 2.96% | 163.992 | 160.990–167.071 | 1.32% | 0.51x | 4.13x | 3.61x |
| `method_calls` | 8 | 500 | 117.179 | 108.566–151.620 | 11.84% | 244.643 | 235.697–317.150 | 11.38% | 0.48x | 5.88x | 4.85x |
| `closure_calls` | 1 | 500 | 73.047 | 70.663–75.174 | 2.14% | 175.498 | 161.484–208.348 | 8.52% | 0.42x | 1.00x | 1.00x |
| `closure_calls` | 2 | 500 | 73.451 | 70.628–81.507 | 5.06% | 164.680 | 163.072–171.064 | 1.69% | 0.45x | 1.99x | 2.13x |
| `closure_calls` | 4 | 500 | 76.511 | 72.581–80.936 | 4.15% | 188.679 | 187.685–227.442 | 7.44% | 0.41x | 3.82x | 3.72x |
| `closure_calls` | 8 | 500 | 97.985 | 92.530–100.182 | 3.01% | 301.828 | 284.522–380.184 | 10.67% | 0.32x | 5.96x | 4.65x |
| `arguments_calls` | 1 | 400 | 63.575 | 61.642–67.028 | 3.27% | 216.432 | 206.301–258.228 | 7.89% | 0.29x | 1.00x | 1.00x |
| `arguments_calls` | 2 | 400 | 61.598 | 61.020–63.271 | 1.25% | 214.696 | 207.993–262.434 | 8.68% | 0.29x | 2.06x | 2.02x |
| `arguments_calls` | 4 | 400 | 71.432 | 68.167–110.488 | 19.27% | 249.195 | 238.513–256.353 | 2.98% | 0.29x | 3.56x | 3.47x |
| `arguments_calls` | 8 | 400 | 82.580 | 80.704–90.840 | 4.27% | 361.899 | 356.690–382.826 | 2.95% | 0.23x | 6.16x | 4.78x |
| `fibonacci` | 1 | 100 | 69.927 | 68.243–81.594 | 6.48% | 370.911 | 364.536–392.190 | 2.70% | 0.19x | 1.00x | 1.00x |
| `fibonacci` | 2 | 100 | 73.523 | 72.996–75.905 | 1.34% | 392.924 | 374.127–524.070 | 13.09% | 0.19x | 1.90x | 1.89x |
| `fibonacci` | 4 | 100 | 77.314 | 72.957–100.359 | 12.50% | 478.464 | 422.195–645.829 | 15.98% | 0.16x | 3.62x | 3.10x |
| `fibonacci` | 8 | 100 | 106.059 | 102.953–161.982 | 18.15% | 602.595 | 588.329–646.769 | 3.66% | 0.18x | 5.27x | 4.92x |

## zig-js shared-realm scaling

This is zig-js's distinct no-GIL shared-object-graph model, which JSC's public C API does not provide.
The timed region creates JavaScript `Thread`s, performs the work, and joins them. Scaling uses the same
shared-realm path at one lane, so thread lifecycle overhead is present in every row.

| workload | lanes | jobs/lane | median (ms) | min–max (ms) | RSD | scaling |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `arithmetic` | 1 | 160 | 55.384 | 54.481–60.667 | 4.18% | 1.00x |
| `arithmetic` | 2 | 160 | 58.885 | 55.547–93.558 | 22.68% | 1.88x |
| `arithmetic` | 4 | 160 | 58.548 | 57.212–76.757 | 11.23% | 3.78x |
| `arithmetic` | 8 | 160 | 72.595 | 70.542–92.631 | 10.44% | 6.10x |
| `properties` | 1 | 200 | 93.042 | 86.223–119.773 | 11.78% | 1.00x |
| `properties` | 2 | 200 | 88.055 | 86.597–139.867 | 20.36% | 2.11x |
| `properties` | 4 | 200 | 96.750 | 90.251–116.513 | 9.85% | 3.85x |
| `properties` | 8 | 200 | 117.235 | 114.567–124.789 | 2.83% | 6.35x |
| `polymorphic_properties` | 1 | 350 | 444.667 | 440.008–517.322 | 6.10% | 1.00x |
| `polymorphic_properties` | 2 | 350 | 458.392 | 450.299–483.518 | 2.50% | 1.94x |
| `polymorphic_properties` | 4 | 350 | 486.744 | 471.292–557.478 | 7.53% | 3.65x |
| `polymorphic_properties` | 8 | 350 | 701.104 | 620.284–773.407 | 9.01% | 5.07x |
| `object_churn` | 1 | 100 | 488.792 | 228.132–579.220 | 24.02% | 1.00x |
| `object_churn` | 2 | 100 | 1276.891 | 682.646–2111.490 | 31.70% | 0.77x |
| `object_churn` | 4 | 100 | 4951.501 | 1722.903–5595.695 | 28.25% | 0.39x |
| `object_churn` | 8 | 100 | 18472.129 | 9866.811–23865.992 | 23.19% | 0.21x |
| `arrays` | 1 | 450 | 70.733 | 69.210–88.734 | 9.42% | 1.00x |
| `arrays` | 2 | 450 | 75.250 | 73.685–84.971 | 5.21% | 1.88x |
| `arrays` | 4 | 450 | 116.819 | 96.971–130.931 | 8.75% | 2.42x |
| `arrays` | 8 | 450 | 203.402 | 197.208–218.379 | 3.99% | 2.78x |
| `direct_calls` | 1 | 500 | 64.214 | 63.664–67.831 | 2.47% | 1.00x |
| `direct_calls` | 2 | 500 | 70.700 | 64.908–78.263 | 6.77% | 1.82x |
| `direct_calls` | 4 | 500 | 68.372 | 66.904–141.523 | 34.26% | 3.76x |
| `direct_calls` | 8 | 500 | 86.838 | 83.736–92.800 | 3.76% | 5.92x |
| `method_calls` | 1 | 500 | 124.508 | 121.282–131.192 | 2.52% | 1.00x |
| `method_calls` | 2 | 500 | 133.575 | 129.546–172.225 | 11.50% | 1.86x |
| `method_calls` | 4 | 500 | 130.241 | 128.104–135.410 | 1.90% | 3.82x |
| `method_calls` | 8 | 500 | 207.468 | 193.934–229.185 | 5.71% | 4.80x |
| `closure_calls` | 1 | 500 | 72.093 | 69.945–73.912 | 1.95% | 1.00x |
| `closure_calls` | 2 | 500 | 76.862 | 72.677–84.672 | 6.35% | 1.88x |
| `closure_calls` | 4 | 500 | 75.321 | 72.679–80.509 | 3.76% | 3.83x |
| `closure_calls` | 8 | 500 | 92.571 | 89.093–99.840 | 3.96% | 6.23x |
| `arguments_calls` | 1 | 400 | 60.327 | 59.453–70.654 | 7.30% | 1.00x |
| `arguments_calls` | 2 | 400 | 60.896 | 58.748–62.497 | 2.37% | 1.98x |
| `arguments_calls` | 4 | 400 | 63.815 | 61.237–66.480 | 3.11% | 3.78x |
| `arguments_calls` | 8 | 400 | 82.903 | 75.520–141.742 | 25.99% | 5.82x |
| `fibonacci` | 1 | 100 | 201.506 | 199.093–208.030 | 1.53% | 1.00x |
| `fibonacci` | 2 | 100 | 215.318 | 203.671–285.953 | 12.61% | 1.87x |
| `fibonacci` | 4 | 100 | 232.553 | 226.828–235.667 | 1.51% | 3.47x |
| `fibonacci` | 8 | 100 | 329.253 | 320.701–343.578 | 2.17% | 4.90x |

## Reading the result

Across these 10 deliberately small kernels, JSC's single-context throughput is 0.42x
the zig-js throughput by geometric mean. These kernels deliberately exercise guarded native/VM tiers that
zig-js currently implements; rows outside those documented subsets continue through general bytecode paths.
The number is a compact description of this matrix, not a claim about applications or unsupported workloads.

At 8 independent warmed contexts, JSC throughput is 0.41x zig-js by
geometric mean; scaling from the mode's own one-lane baseline is 4.90x
for zig-js and 4.69x for JSC. In the symmetric cold lifecycle, JSC
throughput is 0.40x zig-js, with 5.39x
and 4.94x scaling respectively.

zig-js's shared-realm path scales 3.77x at 8 lanes from its
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
