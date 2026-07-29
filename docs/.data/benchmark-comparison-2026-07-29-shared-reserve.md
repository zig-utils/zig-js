# zig-js / JavaScriptCore benchmark — 2026-07-29

> This is a dated measurement, not a universal engine score. The workload source, raw samples,
> timed boundaries, and semantic differences are recorded so the result can be reproduced and challenged.

## Environment

| item | value |
| --- | --- |
| Date | 2026-07-29 |
| Host | Apple M3 Pro; 11 physical / 11 logical CPUs; 18.0 GiB |
| OS | macOS 27.0 (26A5388g) |
| Zig | 0.17.0-dev.1441+d5181a9c9 |
| zig-js | e690a866686baa1762c0fc3375f2d66ba9028a6e |
| zig-gc | a09c01555f8b5e1485d8be5757864967942f699d |
| zig-regex | 2de46683b948ec895e5fa9a9e7e4c384aceccdfe |
| JavaScriptCore | system framework 22625.1.24.11.2 |
| Power | Now drawing from 'AC Power' -InternalBattery-0 (id=23330915) 80%; AC attached; not charging present: true |

## Single-thread result

Each row runs the same number of jobs in one GC-enabled zig-js context and one warmed JSC global context.
Both runners time the exact invocation `__benchmarkSelected(__benchmarkJobs, __benchmarkLane)`.
Lower time is better; `JSC / zig-js` is JSC throughput divided by zig-js throughput. RSD is relative standard deviation.

| workload | jobs | zig-js median (ms) | zig-js min–max (ms) | zig-js RSD | JSC median (ms) | JSC min–max (ms) | JSC RSD | JSC / zig-js |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `arithmetic` | 240 | 87.503 | 87.216–88.393 | 0.55% | 368.667 | 366.200–370.224 | 0.37% | 0.24x |
| `properties` | 300 | 110.182 | 109.682–110.632 | 0.37% | 326.170 | 311.291–327.680 | 2.11% | 0.34x |
| `polymorphic_properties` | 400 | 100.838 | 98.613–111.056 | 4.25% | 217.048 | 212.276–235.040 | 3.41% | 0.46x |
| `object_churn` | 100 | 127.480 | 125.021–135.613 | 2.79% | 129.976 | 128.160–134.136 | 1.71% | 0.98x |
| `arrays` | 550 | 105.089 | 104.390–106.097 | 0.65% | 167.600 | 165.956–169.665 | 0.84% | 0.63x |
| `direct_calls` | 600 | 83.620 | 83.058–86.638 | 1.45% | 125.515 | 124.579–129.245 | 1.47% | 0.67x |
| `method_calls` | 500 | 94.456 | 93.877–94.777 | 0.31% | 152.797 | 150.765–165.659 | 3.45% | 0.62x |
| `closure_calls` | 600 | 99.596 | 96.442–102.129 | 2.36% | 206.172 | 205.315–212.347 | 1.17% | 0.48x |
| `arguments_calls` | 600 | 95.117 | 95.020–97.306 | 0.94% | 328.887 | 323.911–340.542 | 1.76% | 0.29x |
| `fibonacci` | 125 | 91.254 | 90.060–92.735 | 1.04% | 486.184 | 483.320–489.293 | 0.45% | 0.19x |

## Independent-context steady state

Both engines keep one warmed context on one persistent OS worker per lane. The timed region contains the
same semaphore dispatch, exact invocation, and completion wait. Every lane performs the full job count.
`scaling` uses the same engine and mode at one lane; cross-engine throughput is directly comparable.

| workload | lanes | jobs/lane | zig-js median (ms) | zig-js min–max (ms) | zig-js RSD | JSC median (ms) | JSC min–max (ms) | JSC RSD | JSC / zig-js | zig-js scaling | JSC scaling |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `arithmetic` | 1 | 240 | 87.565 | 87.208–89.501 | 0.91% | 367.364 | 365.697–398.885 | 3.26% | 0.24x | 1.00x | 1.00x |
| `arithmetic` | 2 | 240 | 88.897 | 88.226–89.683 | 0.55% | 379.247 | 375.948–402.272 | 2.55% | 0.23x | 1.97x | 1.94x |
| `arithmetic` | 4 | 240 | 90.684 | 90.533–93.210 | 1.10% | 394.189 | 390.004–436.388 | 4.10% | 0.23x | 3.86x | 3.73x |
| `arithmetic` | 8 | 240 | 110.983 | 106.802–123.409 | 5.26% | 592.850 | 566.995–654.514 | 5.47% | 0.19x | 6.31x | 4.96x |
| `properties` | 1 | 300 | 114.133 | 110.578–119.846 | 2.76% | 310.693 | 309.378–311.991 | 0.29% | 0.37x | 1.00x | 1.00x |
| `properties` | 2 | 300 | 112.767 | 111.446–113.077 | 0.52% | 314.711 | 314.324–315.909 | 0.17% | 0.36x | 2.02x | 1.97x |
| `properties` | 4 | 300 | 115.513 | 114.647–121.581 | 2.23% | 351.439 | 348.087–365.526 | 1.78% | 0.33x | 3.95x | 3.54x |
| `properties` | 8 | 300 | 145.388 | 143.279–157.586 | 3.35% | 499.411 | 493.471–513.559 | 1.46% | 0.29x | 6.28x | 4.98x |
| `polymorphic_properties` | 1 | 400 | 98.544 | 98.168–98.888 | 0.25% | 218.489 | 212.338–225.239 | 2.59% | 0.45x | 1.00x | 1.00x |
| `polymorphic_properties` | 2 | 400 | 99.925 | 99.433–100.284 | 0.28% | 216.559 | 215.873–217.505 | 0.24% | 0.46x | 1.97x | 2.02x |
| `polymorphic_properties` | 4 | 400 | 103.382 | 102.807–105.762 | 1.00% | 246.982 | 244.104–255.042 | 1.46% | 0.42x | 3.81x | 3.54x |
| `polymorphic_properties` | 8 | 400 | 159.106 | 155.785–167.498 | 2.98% | 374.106 | 352.982–389.349 | 3.03% | 0.43x | 4.95x | 4.67x |
| `object_churn` | 1 | 100 | 128.257 | 125.285–132.223 | 2.13% | 130.223 | 127.645–132.278 | 1.58% | 0.98x | 1.00x | 1.00x |
| `object_churn` | 2 | 100 | 134.924 | 132.060–139.533 | 1.89% | 131.853 | 130.591–134.782 | 1.16% | 1.02x | 1.90x | 1.98x |
| `object_churn` | 4 | 100 | 148.266 | 145.883–162.747 | 4.42% | 143.282 | 141.696–159.074 | 4.21% | 1.03x | 3.46x | 3.64x |
| `object_churn` | 8 | 100 | 223.538 | 214.757–244.672 | 4.85% | 212.905 | 193.693–220.067 | 4.87% | 1.05x | 4.59x | 4.89x |
| `arrays` | 1 | 550 | 105.451 | 104.507–111.299 | 2.15% | 168.010 | 165.571–172.976 | 1.46% | 0.63x | 1.00x | 1.00x |
| `arrays` | 2 | 550 | 110.239 | 109.324–112.346 | 0.86% | 168.492 | 164.768–170.436 | 1.36% | 0.65x | 1.91x | 1.99x |
| `arrays` | 4 | 550 | 115.834 | 114.299–122.307 | 2.32% | 179.531 | 171.708–268.736 | 18.45% | 0.65x | 3.64x | 3.74x |
| `arrays` | 8 | 550 | 193.355 | 171.388–243.731 | 13.39% | 278.440 | 268.074–322.496 | 6.38% | 0.69x | 4.36x | 4.83x |
| `direct_calls` | 1 | 600 | 83.564 | 83.247–85.612 | 1.11% | 126.428 | 124.390–129.137 | 1.44% | 0.66x | 1.00x | 1.00x |
| `direct_calls` | 2 | 600 | 84.750 | 84.111–85.443 | 0.53% | 127.620 | 126.987–128.333 | 0.39% | 0.66x | 1.97x | 1.98x |
| `direct_calls` | 4 | 600 | 87.636 | 87.094–89.020 | 0.90% | 142.151 | 136.541–152.822 | 3.92% | 0.62x | 3.81x | 3.56x |
| `direct_calls` | 8 | 600 | 119.021 | 113.982–147.737 | 9.66% | 205.639 | 202.065–234.454 | 5.37% | 0.58x | 5.62x | 4.92x |
| `method_calls` | 1 | 500 | 91.588 | 90.916–94.146 | 1.18% | 148.817 | 147.084–160.018 | 3.05% | 0.62x | 1.00x | 1.00x |
| `method_calls` | 2 | 500 | 103.748 | 97.194–130.817 | 10.37% | 164.994 | 162.825–204.362 | 8.78% | 0.63x | 1.77x | 1.80x |
| `method_calls` | 4 | 500 | 96.941 | 96.722–99.300 | 1.20% | 157.528 | 156.779–158.986 | 0.49% | 0.62x | 3.78x | 3.78x |
| `method_calls` | 8 | 500 | 132.105 | 124.758–147.508 | 5.59% | 228.843 | 225.229–241.489 | 2.36% | 0.58x | 5.55x | 5.20x |
| `closure_calls` | 1 | 600 | 97.075 | 96.534–97.314 | 0.31% | 205.890 | 205.024–207.116 | 0.34% | 0.47x | 1.00x | 1.00x |
| `closure_calls` | 2 | 600 | 98.766 | 98.162–100.677 | 0.85% | 223.960 | 217.681–232.880 | 3.06% | 0.44x | 1.97x | 1.84x |
| `closure_calls` | 4 | 600 | 103.237 | 101.625–104.187 | 1.00% | 236.987 | 235.142–239.745 | 0.70% | 0.44x | 3.76x | 3.48x |
| `closure_calls` | 8 | 600 | 128.731 | 123.278–135.279 | 3.69% | 349.663 | 344.712–413.198 | 6.88% | 0.37x | 6.03x | 4.71x |
| `arguments_calls` | 1 | 600 | 95.817 | 94.776–100.358 | 1.96% | 325.336 | 323.598–331.767 | 1.14% | 0.29x | 1.00x | 1.00x |
| `arguments_calls` | 2 | 600 | 97.279 | 96.247–100.596 | 1.42% | 339.785 | 336.246–344.591 | 0.87% | 0.29x | 1.97x | 1.91x |
| `arguments_calls` | 4 | 600 | 99.683 | 99.016–100.233 | 0.52% | 349.057 | 345.616–372.835 | 2.63% | 0.29x | 3.84x | 3.73x |
| `arguments_calls` | 8 | 600 | 128.620 | 124.988–136.262 | 3.09% | 525.756 | 517.574–544.466 | 2.10% | 0.24x | 5.96x | 4.95x |
| `fibonacci` | 1 | 125 | 92.303 | 90.374–95.363 | 1.89% | 487.375 | 485.087–490.606 | 0.41% | 0.19x | 1.00x | 1.00x |
| `fibonacci` | 2 | 125 | 95.326 | 91.580–96.600 | 1.93% | 494.652 | 491.119–504.108 | 0.82% | 0.19x | 1.94x | 1.97x |
| `fibonacci` | 4 | 125 | 98.377 | 95.904–107.423 | 4.21% | 521.803 | 515.088–550.108 | 2.27% | 0.19x | 3.75x | 3.74x |
| `fibonacci` | 8 | 125 | 137.135 | 133.130–146.886 | 3.40% | 709.907 | 698.872–716.704 | 0.97% | 0.19x | 5.38x | 5.49x |

## Independent-context cold lifecycle

Neither engine warms these contexts. The timer covers OS-thread creation, context creation, workload-source
evaluation and configuration, the exact invocation, context destruction, and OS-thread join on both sides.
`scaling` uses the same engine and cold lifecycle at one lane.

| workload | lanes | jobs/lane | zig-js median (ms) | zig-js min–max (ms) | zig-js RSD | JSC median (ms) | JSC min–max (ms) | JSC RSD | JSC / zig-js | zig-js scaling | JSC scaling |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `arithmetic` | 1 | 240 | 90.043 | 89.377–90.863 | 0.51% | 368.894 | 365.644–373.998 | 0.72% | 0.24x | 1.00x | 1.00x |
| `arithmetic` | 2 | 240 | 91.837 | 91.127–92.709 | 0.66% | 378.323 | 376.048–387.363 | 1.08% | 0.24x | 1.96x | 1.95x |
| `arithmetic` | 4 | 240 | 94.382 | 93.935–99.289 | 2.01% | 402.296 | 391.877–526.502 | 11.14% | 0.23x | 3.82x | 3.67x |
| `arithmetic` | 8 | 240 | 113.238 | 112.536–122.164 | 3.25% | 598.104 | 584.740–615.843 | 1.59% | 0.19x | 6.36x | 4.93x |
| `properties` | 1 | 300 | 111.166 | 110.734–111.452 | 0.25% | 313.550 | 310.746–322.514 | 1.57% | 0.35x | 1.00x | 1.00x |
| `properties` | 2 | 300 | 112.706 | 112.154–114.955 | 0.86% | 317.697 | 315.970–331.786 | 2.00% | 0.35x | 1.97x | 1.97x |
| `properties` | 4 | 300 | 116.253 | 115.768–132.499 | 5.21% | 356.798 | 353.430–393.197 | 4.91% | 0.33x | 3.82x | 3.52x |
| `properties` | 8 | 300 | 150.063 | 145.353–168.322 | 5.12% | 504.563 | 501.528–591.452 | 6.36% | 0.30x | 5.93x | 4.97x |
| `polymorphic_properties` | 1 | 400 | 100.246 | 99.657–101.231 | 0.51% | 212.528 | 211.999–215.987 | 0.79% | 0.47x | 1.00x | 1.00x |
| `polymorphic_properties` | 2 | 400 | 102.820 | 102.127–104.495 | 0.74% | 216.848 | 215.916–224.964 | 1.47% | 0.47x | 1.95x | 1.96x |
| `polymorphic_properties` | 4 | 400 | 106.943 | 105.908–113.206 | 2.34% | 248.324 | 244.346–249.750 | 0.78% | 0.43x | 3.75x | 3.42x |
| `polymorphic_properties` | 8 | 400 | 162.894 | 156.207–181.046 | 5.85% | 360.610 | 356.916–371.524 | 1.39% | 0.45x | 4.92x | 4.71x |
| `object_churn` | 1 | 100 | 129.548 | 128.723–138.701 | 3.26% | 130.324 | 128.430–135.725 | 1.87% | 0.99x | 1.00x | 1.00x |
| `object_churn` | 2 | 100 | 135.559 | 134.750–143.165 | 2.46% | 134.989 | 133.444–136.805 | 0.87% | 1.00x | 1.91x | 1.93x |
| `object_churn` | 4 | 100 | 159.239 | 152.673–161.848 | 1.88% | 145.922 | 142.538–157.388 | 3.83% | 1.09x | 3.25x | 3.57x |
| `object_churn` | 8 | 100 | 230.256 | 221.510–237.028 | 2.60% | 204.000 | 195.721–211.851 | 2.97% | 1.13x | 4.50x | 5.11x |
| `arrays` | 1 | 550 | 89.155 | 87.895–92.888 | 2.05% | 167.875 | 166.618–177.577 | 2.39% | 0.53x | 1.00x | 1.00x |
| `arrays` | 2 | 550 | 94.371 | 92.727–99.134 | 2.37% | 169.510 | 168.428–172.885 | 1.02% | 0.56x | 1.89x | 1.98x |
| `arrays` | 4 | 550 | 98.247 | 97.086–109.112 | 4.85% | 179.054 | 173.261–186.941 | 2.72% | 0.55x | 3.63x | 3.75x |
| `arrays` | 8 | 550 | 147.127 | 135.045–169.701 | 8.29% | 270.194 | 264.980–275.076 | 1.29% | 0.54x | 4.85x | 4.97x |
| `direct_calls` | 1 | 600 | 85.896 | 85.253–87.431 | 0.89% | 126.020 | 125.299–128.065 | 0.71% | 0.68x | 1.00x | 1.00x |
| `direct_calls` | 2 | 600 | 89.499 | 87.994–97.978 | 3.79% | 133.534 | 129.920–150.100 | 5.86% | 0.67x | 1.92x | 1.89x |
| `direct_calls` | 4 | 600 | 90.796 | 89.535–95.375 | 2.18% | 140.996 | 136.992–143.577 | 1.51% | 0.64x | 3.78x | 3.58x |
| `direct_calls` | 8 | 600 | 111.747 | 109.957–115.395 | 1.76% | 212.560 | 206.571–220.502 | 2.22% | 0.53x | 6.15x | 4.74x |
| `method_calls` | 1 | 500 | 95.276 | 94.363–97.847 | 1.48% | 150.478 | 148.195–152.446 | 1.08% | 0.63x | 1.00x | 1.00x |
| `method_calls` | 2 | 500 | 100.418 | 99.377–103.071 | 1.29% | 153.203 | 151.935–156.198 | 1.01% | 0.66x | 1.90x | 1.96x |
| `method_calls` | 4 | 500 | 100.051 | 98.637–106.743 | 2.67% | 158.831 | 157.275–179.656 | 4.95% | 0.63x | 3.81x | 3.79x |
| `method_calls` | 8 | 500 | 140.780 | 135.988–156.061 | 5.25% | 245.705 | 228.409–284.645 | 7.90% | 0.57x | 5.41x | 4.90x |
| `closure_calls` | 1 | 600 | 98.911 | 98.092–101.270 | 1.12% | 208.847 | 207.487–240.347 | 5.54% | 0.47x | 1.00x | 1.00x |
| `closure_calls` | 2 | 600 | 102.511 | 101.663–106.276 | 1.69% | 218.883 | 217.657–230.794 | 2.33% | 0.47x | 1.93x | 1.91x |
| `closure_calls` | 4 | 600 | 104.712 | 103.254–111.784 | 2.93% | 241.842 | 234.510–260.589 | 3.55% | 0.43x | 3.78x | 3.45x |
| `closure_calls` | 8 | 600 | 130.512 | 126.565–139.746 | 3.67% | 352.182 | 350.230–361.332 | 1.31% | 0.37x | 6.06x | 4.74x |
| `arguments_calls` | 1 | 600 | 98.050 | 96.094–100.507 | 1.52% | 331.176 | 324.801–409.843 | 8.82% | 0.30x | 1.00x | 1.00x |
| `arguments_calls` | 2 | 600 | 101.671 | 99.217–103.909 | 1.70% | 340.846 | 336.718–347.725 | 1.07% | 0.30x | 1.93x | 1.94x |
| `arguments_calls` | 4 | 600 | 106.237 | 101.296–109.689 | 3.17% | 368.195 | 357.946–394.737 | 3.65% | 0.29x | 3.69x | 3.60x |
| `arguments_calls` | 8 | 600 | 142.336 | 127.944–146.986 | 5.00% | 533.784 | 523.624–541.272 | 1.06% | 0.27x | 5.51x | 4.96x |
| `fibonacci` | 1 | 125 | 93.763 | 92.159–97.657 | 1.98% | 488.374 | 485.554–491.091 | 0.42% | 0.19x | 1.00x | 1.00x |
| `fibonacci` | 2 | 125 | 96.342 | 94.732–97.271 | 0.97% | 498.461 | 496.022–503.204 | 0.47% | 0.19x | 1.95x | 1.96x |
| `fibonacci` | 4 | 125 | 101.469 | 99.472–108.123 | 2.68% | 523.362 | 508.324–529.403 | 1.49% | 0.19x | 3.70x | 3.73x |
| `fibonacci` | 8 | 125 | 140.401 | 136.612–156.695 | 5.17% | 714.952 | 702.511–718.832 | 0.94% | 0.20x | 5.34x | 5.46x |

## zig-js shared-realm scaling

This is zig-js's distinct no-GIL shared-object-graph model, which JSC's public C API does not provide.
The timed region creates JavaScript `Thread`s, performs the work, and joins them. Scaling uses the same
shared-realm path at one lane, so thread lifecycle overhead is present in every row.

| workload | lanes | jobs/lane | median (ms) | min–max (ms) | RSD | scaling |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `arithmetic` | 1 | 240 | 87.313 | 86.563–91.645 | 2.15% | 1.00x |
| `arithmetic` | 2 | 240 | 90.024 | 88.108–95.268 | 3.00% | 1.94x |
| `arithmetic` | 4 | 240 | 90.260 | 89.856–90.621 | 0.28% | 3.87x |
| `arithmetic` | 8 | 240 | 114.501 | 107.209–120.134 | 3.53% | 6.10x |
| `properties` | 1 | 300 | 157.951 | 155.693–167.457 | 2.59% | 1.00x |
| `properties` | 2 | 300 | 159.439 | 158.001–203.295 | 10.03% | 1.98x |
| `properties` | 4 | 300 | 163.121 | 162.445–164.422 | 0.42% | 3.87x |
| `properties` | 8 | 300 | 233.423 | 225.512–268.467 | 6.11% | 5.41x |
| `polymorphic_properties` | 1 | 400 | 747.339 | 742.630–773.424 | 1.38% | 1.00x |
| `polymorphic_properties` | 2 | 400 | 763.023 | 754.846–771.753 | 0.80% | 1.96x |
| `polymorphic_properties` | 4 | 400 | 834.328 | 796.911–981.486 | 7.41% | 3.58x |
| `polymorphic_properties` | 8 | 400 | 1145.667 | 1123.780–1162.190 | 1.21% | 5.22x |
| `object_churn` | 1 | 100 | 208.227 | 118.921–209.411 | 17.21% | 1.00x |
| `object_churn` | 2 | 100 | 319.134 | 122.956–367.329 | 26.60% | 1.30x |
| `object_churn` | 4 | 100 | 590.282 | 168.453–695.094 | 31.37% | 1.41x |
| `object_churn` | 8 | 100 | 1342.673 | 452.099–1847.553 | 33.70% | 1.24x |
| `arrays` | 1 | 550 | 674.275 | 662.636–689.759 | 1.52% | 1.00x |
| `arrays` | 2 | 550 | 673.326 | 670.931–676.520 | 0.26% | 2.00x |
| `arrays` | 4 | 550 | 703.043 | 696.284–705.216 | 0.54% | 3.84x |
| `arrays` | 8 | 550 | 1044.867 | 974.345–1072.927 | 3.54% | 5.16x |
| `direct_calls` | 1 | 600 | 85.332 | 83.285–88.025 | 2.09% | 1.00x |
| `direct_calls` | 2 | 600 | 90.305 | 89.822–91.693 | 0.82% | 1.89x |
| `direct_calls` | 4 | 600 | 108.277 | 99.529–132.667 | 10.43% | 3.15x |
| `direct_calls` | 8 | 600 | 147.405 | 146.779–149.004 | 0.56% | 4.63x |
| `method_calls` | 1 | 500 | 183.231 | 173.988–193.616 | 3.99% | 1.00x |
| `method_calls` | 2 | 500 | 185.799 | 184.619–187.491 | 0.50% | 1.97x |
| `method_calls` | 4 | 500 | 198.649 | 197.115–199.648 | 0.49% | 3.69x |
| `method_calls` | 8 | 500 | 264.306 | 255.255–280.494 | 3.21% | 5.55x |
| `closure_calls` | 1 | 600 | 98.694 | 97.890–99.864 | 0.71% | 1.00x |
| `closure_calls` | 2 | 600 | 109.157 | 107.188–114.042 | 2.00% | 1.81x |
| `closure_calls` | 4 | 600 | 112.800 | 111.307–114.255 | 0.93% | 3.50x |
| `closure_calls` | 8 | 600 | 169.847 | 164.613–174.071 | 1.88% | 4.65x |
| `arguments_calls` | 1 | 600 | 95.929 | 95.375–97.933 | 1.09% | 1.00x |
| `arguments_calls` | 2 | 600 | 97.083 | 96.608–99.433 | 1.20% | 1.98x |
| `arguments_calls` | 4 | 600 | 101.310 | 99.599–108.199 | 2.77% | 3.79x |
| `arguments_calls` | 8 | 600 | 129.485 | 124.307–137.110 | 3.15% | 5.93x |
| `fibonacci` | 1 | 125 | 281.266 | 278.078–283.479 | 0.66% | 1.00x |
| `fibonacci` | 2 | 125 | 285.582 | 281.023–287.481 | 0.85% | 1.97x |
| `fibonacci` | 4 | 125 | 291.566 | 289.706–300.406 | 1.28% | 3.86x |
| `fibonacci` | 8 | 125 | 415.551 | 402.520–558.805 | 12.92% | 5.41x |

## Reading the result

Across these 10 deliberately small kernels, JSC's single-context throughput is 0.44x
the zig-js throughput by geometric mean. These kernels deliberately exercise guarded native/VM tiers that
zig-js currently implements; rows outside those documented subsets continue through general bytecode paths.
The number is a compact description of this matrix, not a claim about applications or unsupported workloads.

At 8 independent warmed contexts, JSC throughput is 0.40x zig-js by
geometric mean; scaling from the mode's own one-lane baseline is 5.46x
for zig-js and 4.96x for JSC. In the symmetric cold lifecycle, JSC
throughput is 0.39x zig-js, with 5.47x
and 4.95x scaling respectively.

zig-js's shared-realm path scales 4.60x at 8 lanes from its
own one-lane shared baseline. It has no direct JSC ratio because the public JSC embedding API exposes
isolated global contexts, not concurrent JavaScript workers sharing one object graph. Per-workload rows
matter more than any aggregate.

## Method and timed boundaries

- Both engines evaluate the exact bytes in `bench/comparison.js`. Directly compared single and independent rows use the exact invocation bytes `__benchmarkSelected(__benchmarkJobs, __benchmarkLane)`; shared mode calls the same selected function with the same jobs/lane arguments. The driver rejects unstable or cross-engine checksum mismatches.
- zig-js is built `ReleaseFast`. Direct and independent contexts explicitly enable precise GC; shared mode enables the shipping no-GIL thread configuration, which implies GC.
- Every measured zig-js context uses the process-wide thread-safe libc allocator, whose reusable infrastructure outlives timed cold contexts; cold mode still times every context-owned allocation and release. JSC uses its internal process allocator.
- Single mode evaluates the workload source, configures the context, and performs ten reduced-size warm-up calls before timing one host evaluation call per sample.
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

Raw samples: [`benchmark-comparison-2026-07-29-shared-reserve.tsv`](benchmark-comparison-2026-07-29-shared-reserve.tsv)
