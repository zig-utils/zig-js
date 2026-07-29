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
| zig-js | a7cf92c7282727769ddea43dd238173bb18dd108 |
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
| `arithmetic` | 240 | 87.719 | 87.387–88.528 | 0.45% | 368.213 | 363.875–368.930 | 0.51% | 0.24x |
| `properties` | 300 | 112.044 | 110.376–117.201 | 1.95% | 321.821 | 315.485–347.742 | 4.32% | 0.35x |
| `polymorphic_properties` | 400 | 101.278 | 100.063–104.520 | 1.47% | 218.540 | 214.952–225.813 | 2.02% | 0.46x |
| `object_churn` | 100 | 127.183 | 125.748–127.992 | 0.70% | 128.264 | 127.137–129.697 | 0.71% | 0.99x |
| `arrays` | 550 | 111.365 | 110.654–116.440 | 2.16% | 168.565 | 166.065–177.347 | 2.15% | 0.66x |
| `direct_calls` | 600 | 86.081 | 85.898–87.618 | 0.69% | 130.078 | 128.578–130.261 | 0.46% | 0.66x |
| `method_calls` | 500 | 96.430 | 95.331–96.589 | 0.52% | 157.356 | 154.588–162.573 | 1.85% | 0.61x |
| `closure_calls` | 600 | 100.546 | 100.249–109.075 | 3.15% | 216.393 | 214.344–219.068 | 0.74% | 0.46x |
| `arguments_calls` | 600 | 99.417 | 97.708–102.660 | 1.94% | 339.649 | 338.869–344.240 | 0.69% | 0.29x |
| `fibonacci` | 125 | 99.495 | 97.471–100.612 | 1.14% | 504.670 | 502.869–524.212 | 1.54% | 0.20x |

## Independent-context steady state

Both engines keep one warmed context on one persistent OS worker per lane. The timed region contains the
same semaphore dispatch, exact invocation, and completion wait. Every lane performs the full job count.
`scaling` uses the same engine and mode at one lane; cross-engine throughput is directly comparable.

| workload | lanes | jobs/lane | zig-js median (ms) | zig-js min–max (ms) | zig-js RSD | JSC median (ms) | JSC min–max (ms) | JSC RSD | JSC / zig-js | zig-js scaling | JSC scaling |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `arithmetic` | 1 | 240 | 88.034 | 87.450–146.732 | 22.54% | 368.201 | 361.729–370.235 | 0.79% | 0.24x | 1.00x | 1.00x |
| `arithmetic` | 2 | 240 | 90.436 | 88.525–92.073 | 1.29% | 378.724 | 376.089–380.382 | 0.45% | 0.24x | 1.95x | 1.94x |
| `arithmetic` | 4 | 240 | 91.362 | 89.983–95.934 | 2.34% | 409.935 | 401.317–521.346 | 10.16% | 0.22x | 3.85x | 3.59x |
| `arithmetic` | 8 | 240 | 116.747 | 107.498–118.412 | 3.87% | 592.872 | 579.781–643.177 | 3.56% | 0.20x | 6.03x | 4.97x |
| `properties` | 1 | 300 | 113.208 | 112.497–113.587 | 0.31% | 320.111 | 315.954–341.637 | 3.11% | 0.35x | 1.00x | 1.00x |
| `properties` | 2 | 300 | 113.805 | 112.871–114.752 | 0.49% | 323.791 | 320.929–351.984 | 4.07% | 0.35x | 1.99x | 1.98x |
| `properties` | 4 | 300 | 131.037 | 116.155–198.488 | 23.33% | 362.633 | 354.308–393.438 | 3.77% | 0.36x | 3.46x | 3.53x |
| `properties` | 8 | 300 | 149.728 | 147.597–194.740 | 10.68% | 512.982 | 508.792–519.710 | 0.74% | 0.29x | 6.05x | 4.99x |
| `polymorphic_properties` | 1 | 400 | 101.122 | 99.729–101.490 | 0.60% | 217.623 | 215.669–221.746 | 0.99% | 0.46x | 1.00x | 1.00x |
| `polymorphic_properties` | 2 | 400 | 104.656 | 101.567–119.048 | 5.60% | 221.675 | 219.790–232.541 | 2.49% | 0.47x | 1.93x | 1.96x |
| `polymorphic_properties` | 4 | 400 | 106.219 | 104.876–109.338 | 1.39% | 243.118 | 239.332–271.957 | 4.93% | 0.44x | 3.81x | 3.58x |
| `polymorphic_properties` | 8 | 400 | 153.995 | 148.792–160.694 | 2.32% | 345.293 | 340.689–370.040 | 2.85% | 0.45x | 5.25x | 5.04x |
| `object_churn` | 1 | 100 | 126.140 | 125.656–127.467 | 0.56% | 128.627 | 127.743–132.410 | 1.35% | 0.98x | 1.00x | 1.00x |
| `object_churn` | 2 | 100 | 137.092 | 134.085–143.763 | 2.81% | 138.822 | 131.980–207.182 | 19.03% | 0.99x | 1.84x | 1.85x |
| `object_churn` | 4 | 100 | 153.850 | 147.734–172.561 | 6.30% | 149.694 | 137.176–153.830 | 5.07% | 1.03x | 3.28x | 3.44x |
| `object_churn` | 8 | 100 | 237.536 | 231.053–289.295 | 8.36% | 201.957 | 195.060–216.958 | 4.10% | 1.18x | 4.25x | 5.10x |
| `arrays` | 1 | 550 | 115.113 | 110.702–118.457 | 2.75% | 168.859 | 168.032–170.364 | 0.48% | 0.68x | 1.00x | 1.00x |
| `arrays` | 2 | 550 | 114.048 | 113.691–114.545 | 0.25% | 170.297 | 168.497–173.256 | 0.90% | 0.67x | 2.02x | 1.98x |
| `arrays` | 4 | 550 | 118.984 | 118.032–120.473 | 0.75% | 175.754 | 175.320–178.203 | 0.70% | 0.68x | 3.87x | 3.84x |
| `arrays` | 8 | 550 | 169.087 | 160.627–184.717 | 5.21% | 261.708 | 253.692–269.392 | 2.02% | 0.65x | 5.45x | 5.16x |
| `direct_calls` | 1 | 600 | 86.588 | 86.032–87.199 | 0.48% | 130.189 | 129.756–132.630 | 0.75% | 0.67x | 1.00x | 1.00x |
| `direct_calls` | 2 | 600 | 88.833 | 87.029–93.056 | 2.49% | 134.496 | 130.628–147.466 | 4.57% | 0.66x | 1.95x | 1.94x |
| `direct_calls` | 4 | 600 | 92.972 | 90.160–98.597 | 2.84% | 166.641 | 136.861–345.059 | 38.24% | 0.56x | 3.73x | 3.13x |
| `direct_calls` | 8 | 600 | 111.096 | 108.327–118.201 | 2.87% | 210.460 | 199.928–274.290 | 11.70% | 0.53x | 6.24x | 4.95x |
| `method_calls` | 1 | 500 | 100.017 | 95.734–103.268 | 2.38% | 166.369 | 155.723–179.214 | 5.62% | 0.60x | 1.00x | 1.00x |
| `method_calls` | 2 | 500 | 97.669 | 96.396–99.081 | 0.84% | 157.380 | 156.712–197.801 | 9.37% | 0.62x | 2.05x | 2.11x |
| `method_calls` | 4 | 500 | 108.466 | 100.645–122.101 | 7.75% | 164.633 | 162.470–190.036 | 7.63% | 0.66x | 3.69x | 4.04x |
| `method_calls` | 8 | 500 | 132.303 | 125.798–142.235 | 4.07% | 237.769 | 226.785–303.218 | 10.72% | 0.56x | 6.05x | 5.60x |
| `closure_calls` | 1 | 600 | 102.078 | 100.552–104.856 | 1.42% | 213.915 | 213.108–214.626 | 0.27% | 0.48x | 1.00x | 1.00x |
| `closure_calls` | 2 | 600 | 105.970 | 102.170–109.461 | 2.09% | 223.094 | 221.709–225.377 | 0.58% | 0.47x | 1.93x | 1.92x |
| `closure_calls` | 4 | 600 | 104.304 | 103.570–106.691 | 1.05% | 243.680 | 240.597–248.881 | 1.19% | 0.43x | 3.91x | 3.51x |
| `closure_calls` | 8 | 600 | 140.638 | 133.536–146.138 | 3.64% | 351.633 | 350.228–360.654 | 1.07% | 0.40x | 5.81x | 4.87x |
| `arguments_calls` | 1 | 600 | 98.792 | 97.684–99.498 | 0.56% | 340.515 | 334.854–356.322 | 2.18% | 0.29x | 1.00x | 1.00x |
| `arguments_calls` | 2 | 600 | 100.137 | 99.723–100.620 | 0.36% | 348.795 | 345.435–380.796 | 3.50% | 0.29x | 1.97x | 1.95x |
| `arguments_calls` | 4 | 600 | 103.801 | 102.412–115.395 | 4.23% | 365.430 | 363.458–415.143 | 5.50% | 0.28x | 3.81x | 3.73x |
| `arguments_calls` | 8 | 600 | 128.629 | 126.110–132.482 | 1.78% | 532.736 | 515.395–605.236 | 5.63% | 0.24x | 6.14x | 5.11x |
| `fibonacci` | 1 | 125 | 96.387 | 95.183–99.210 | 1.33% | 504.172 | 501.516–527.014 | 1.76% | 0.19x | 1.00x | 1.00x |
| `fibonacci` | 2 | 125 | 97.327 | 95.531–99.570 | 1.37% | 509.037 | 507.218–530.787 | 2.07% | 0.19x | 1.98x | 1.98x |
| `fibonacci` | 4 | 125 | 137.867 | 130.687–153.891 | 6.28% | 574.674 | 548.826–794.751 | 15.62% | 0.24x | 2.80x | 3.51x |
| `fibonacci` | 8 | 125 | 152.711 | 150.868–163.412 | 2.90% | 804.432 | 770.469–835.272 | 2.37% | 0.19x | 5.05x | 5.01x |

## Independent-context cold lifecycle

Neither engine warms these contexts. The timer covers OS-thread creation, context creation, workload-source
evaluation and configuration, the exact invocation, context destruction, and OS-thread join on both sides.
`scaling` uses the same engine and cold lifecycle at one lane.

| workload | lanes | jobs/lane | zig-js median (ms) | zig-js min–max (ms) | zig-js RSD | JSC median (ms) | JSC min–max (ms) | JSC RSD | JSC / zig-js | zig-js scaling | JSC scaling |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `arithmetic` | 1 | 240 | 90.272 | 88.926–91.591 | 1.01% | 373.060 | 368.520–385.595 | 1.50% | 0.24x | 1.00x | 1.00x |
| `arithmetic` | 2 | 240 | 92.069 | 91.470–95.535 | 1.59% | 381.376 | 377.345–384.486 | 0.73% | 0.24x | 1.96x | 1.96x |
| `arithmetic` | 4 | 240 | 95.500 | 93.839–98.548 | 2.20% | 407.267 | 392.726–415.000 | 2.30% | 0.23x | 3.78x | 3.66x |
| `arithmetic` | 8 | 240 | 112.974 | 110.372–125.924 | 5.04% | 604.337 | 580.703–702.056 | 7.62% | 0.19x | 6.39x | 4.94x |
| `properties` | 1 | 300 | 112.905 | 112.416–114.191 | 0.63% | 316.963 | 316.040–328.577 | 1.41% | 0.36x | 1.00x | 1.00x |
| `properties` | 2 | 300 | 114.361 | 113.796–115.317 | 0.43% | 324.325 | 321.349–340.197 | 2.01% | 0.35x | 1.97x | 1.95x |
| `properties` | 4 | 300 | 117.769 | 117.520–134.473 | 5.26% | 407.348 | 359.226–431.599 | 6.90% | 0.29x | 3.83x | 3.11x |
| `properties` | 8 | 300 | 151.531 | 146.643–166.952 | 5.00% | 520.005 | 513.680–598.543 | 5.72% | 0.29x | 5.96x | 4.88x |
| `polymorphic_properties` | 1 | 400 | 103.561 | 102.874–105.010 | 0.66% | 218.281 | 216.194–222.675 | 1.14% | 0.47x | 1.00x | 1.00x |
| `polymorphic_properties` | 2 | 400 | 104.611 | 103.873–105.847 | 0.79% | 220.900 | 220.325–225.701 | 0.87% | 0.47x | 1.98x | 1.98x |
| `polymorphic_properties` | 4 | 400 | 112.642 | 107.347–119.332 | 3.51% | 243.614 | 241.724–249.000 | 1.04% | 0.46x | 3.68x | 3.58x |
| `polymorphic_properties` | 8 | 400 | 164.397 | 153.114–182.399 | 6.99% | 371.573 | 345.625–393.380 | 5.02% | 0.44x | 5.04x | 4.70x |
| `object_churn` | 1 | 100 | 135.589 | 131.132–140.864 | 2.81% | 131.292 | 129.792–135.761 | 1.95% | 1.03x | 1.00x | 1.00x |
| `object_churn` | 2 | 100 | 149.074 | 137.931–163.422 | 5.40% | 144.098 | 135.496–150.666 | 3.47% | 1.03x | 1.82x | 1.82x |
| `object_churn` | 4 | 100 | 153.899 | 152.398–165.367 | 2.90% | 143.188 | 138.515–167.862 | 7.46% | 1.07x | 3.52x | 3.67x |
| `object_churn` | 8 | 100 | 248.468 | 238.993–260.185 | 2.92% | 211.654 | 196.572–233.321 | 5.61% | 1.17x | 4.37x | 4.96x |
| `arrays` | 1 | 550 | 98.414 | 97.251–101.762 | 1.48% | 179.980 | 178.306–181.265 | 0.58% | 0.55x | 1.00x | 1.00x |
| `arrays` | 2 | 550 | 97.072 | 95.680–100.716 | 1.87% | 170.977 | 170.481–175.616 | 1.05% | 0.57x | 2.03x | 2.11x |
| `arrays` | 4 | 550 | 100.567 | 99.868–110.510 | 3.71% | 177.525 | 175.677–182.921 | 1.42% | 0.57x | 3.91x | 4.06x |
| `arrays` | 8 | 550 | 149.909 | 138.270–156.959 | 5.06% | 301.580 | 280.154–366.094 | 10.32% | 0.50x | 5.25x | 4.77x |
| `direct_calls` | 1 | 600 | 88.383 | 87.975–90.622 | 1.06% | 130.992 | 130.694–134.717 | 1.07% | 0.67x | 1.00x | 1.00x |
| `direct_calls` | 2 | 600 | 91.159 | 89.523–95.381 | 2.39% | 133.482 | 132.864–137.127 | 1.10% | 0.68x | 1.94x | 1.96x |
| `direct_calls` | 4 | 600 | 92.397 | 91.893–99.744 | 3.04% | 143.114 | 137.154–202.278 | 15.32% | 0.65x | 3.83x | 3.66x |
| `direct_calls` | 8 | 600 | 128.066 | 120.007–212.516 | 22.84% | 266.379 | 221.287–488.413 | 31.09% | 0.48x | 5.52x | 3.93x |
| `method_calls` | 1 | 500 | 98.899 | 98.242–100.295 | 0.71% | 157.418 | 155.851–163.066 | 1.61% | 0.63x | 1.00x | 1.00x |
| `method_calls` | 2 | 500 | 101.615 | 100.361–103.306 | 1.05% | 158.352 | 157.515–162.560 | 1.11% | 0.64x | 1.95x | 1.99x |
| `method_calls` | 4 | 500 | 107.108 | 103.938–122.086 | 5.97% | 174.765 | 165.071–190.109 | 5.56% | 0.61x | 3.69x | 3.60x |
| `method_calls` | 8 | 500 | 133.610 | 131.139–145.578 | 4.11% | 235.412 | 231.972–242.868 | 1.83% | 0.57x | 5.92x | 5.35x |
| `closure_calls` | 1 | 600 | 102.426 | 102.195–106.186 | 1.42% | 217.022 | 216.099–246.841 | 5.12% | 0.47x | 1.00x | 1.00x |
| `closure_calls` | 2 | 600 | 104.980 | 103.753–107.705 | 1.49% | 225.304 | 221.387–233.496 | 1.82% | 0.47x | 1.95x | 1.93x |
| `closure_calls` | 4 | 600 | 111.714 | 108.344–119.753 | 3.94% | 248.985 | 243.312–260.787 | 2.12% | 0.45x | 3.67x | 3.49x |
| `closure_calls` | 8 | 600 | 145.694 | 139.273–289.837 | 32.71% | 353.987 | 346.674–365.265 | 1.87% | 0.41x | 5.62x | 4.90x |
| `arguments_calls` | 1 | 600 | 101.363 | 100.722–104.131 | 1.22% | 341.635 | 339.274–351.543 | 1.33% | 0.30x | 1.00x | 1.00x |
| `arguments_calls` | 2 | 600 | 104.029 | 101.908–106.323 | 1.27% | 350.406 | 348.795–359.375 | 1.03% | 0.30x | 1.95x | 1.95x |
| `arguments_calls` | 4 | 600 | 106.916 | 105.834–114.555 | 2.88% | 395.461 | 379.601–478.252 | 8.33% | 0.27x | 3.79x | 3.46x |
| `arguments_calls` | 8 | 600 | 137.452 | 132.026–145.817 | 3.78% | 549.731 | 539.872–650.805 | 6.99% | 0.25x | 5.90x | 4.97x |
| `fibonacci` | 1 | 125 | 101.765 | 97.295–108.160 | 3.38% | 505.931 | 503.957–508.467 | 0.37% | 0.20x | 1.00x | 1.00x |
| `fibonacci` | 2 | 125 | 101.530 | 99.406–102.419 | 1.05% | 515.857 | 512.650–524.840 | 0.79% | 0.20x | 2.00x | 1.96x |
| `fibonacci` | 4 | 125 | 112.075 | 110.292–128.862 | 5.71% | 558.632 | 551.425–638.213 | 6.28% | 0.20x | 3.63x | 3.62x |
| `fibonacci` | 8 | 125 | 174.327 | 163.346–189.350 | 5.66% | 852.681 | 821.672–978.974 | 7.29% | 0.20x | 4.67x | 4.75x |

## zig-js shared-realm scaling

This is zig-js's distinct no-GIL shared-object-graph model, which JSC's public C API does not provide.
The timed region creates JavaScript `Thread`s, performs the work, and joins them. Scaling uses the same
shared-realm path at one lane, so thread lifecycle overhead is present in every row.

| workload | lanes | jobs/lane | median (ms) | min–max (ms) | RSD | scaling |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `arithmetic` | 1 | 240 | 87.509 | 86.488–90.317 | 1.49% | 1.00x |
| `arithmetic` | 2 | 240 | 89.276 | 88.706–93.278 | 1.78% | 1.96x |
| `arithmetic` | 4 | 240 | 90.688 | 89.758–93.316 | 1.55% | 3.86x |
| `arithmetic` | 8 | 240 | 126.498 | 120.902–152.029 | 7.95% | 5.53x |
| `properties` | 1 | 300 | 163.085 | 162.154–166.685 | 0.91% | 1.00x |
| `properties` | 2 | 300 | 174.079 | 171.558–261.393 | 20.36% | 1.87x |
| `properties` | 4 | 300 | 169.029 | 168.288–172.895 | 1.11% | 3.86x |
| `properties` | 8 | 300 | 224.242 | 217.409–277.613 | 9.37% | 5.82x |
| `polymorphic_properties` | 1 | 400 | 764.455 | 762.229–857.335 | 4.51% | 1.00x |
| `polymorphic_properties` | 2 | 400 | 777.681 | 771.431–801.879 | 1.66% | 1.97x |
| `polymorphic_properties` | 4 | 400 | 803.264 | 791.568–808.842 | 0.68% | 3.81x |
| `polymorphic_properties` | 8 | 400 | 1137.280 | 1111.854–1325.358 | 6.32% | 5.38x |
| `object_churn` | 1 | 100 | 208.212 | 202.844–211.275 | 1.39% | 1.00x |
| `object_churn` | 2 | 100 | 330.048 | 293.530–353.094 | 6.26% | 1.26x |
| `object_churn` | 4 | 100 | 720.769 | 604.319–816.501 | 11.31% | 1.16x |
| `object_churn` | 8 | 100 | 1390.013 | 1365.453–1465.906 | 2.82% | 1.20x |
| `arrays` | 1 | 550 | 696.604 | 694.326–705.288 | 0.59% | 1.00x |
| `arrays` | 2 | 550 | 699.319 | 693.446–795.324 | 5.05% | 1.99x |
| `arrays` | 4 | 550 | 715.783 | 712.642–717.945 | 0.28% | 3.89x |
| `arrays` | 8 | 550 | 1005.790 | 983.410–1079.045 | 3.64% | 5.54x |
| `direct_calls` | 1 | 600 | 86.497 | 86.086–91.439 | 2.72% | 1.00x |
| `direct_calls` | 2 | 600 | 92.954 | 92.386–95.965 | 1.32% | 1.86x |
| `direct_calls` | 4 | 600 | 102.848 | 99.468–113.175 | 5.44% | 3.36x |
| `direct_calls` | 8 | 600 | 152.235 | 150.148–152.823 | 0.75% | 4.55x |
| `method_calls` | 1 | 500 | 182.351 | 182.046–187.159 | 1.07% | 1.00x |
| `method_calls` | 2 | 500 | 191.448 | 190.858–197.065 | 1.40% | 1.90x |
| `method_calls` | 4 | 500 | 200.911 | 198.248–213.129 | 2.77% | 3.63x |
| `method_calls` | 8 | 500 | 268.453 | 262.734–287.123 | 2.84% | 5.43x |
| `closure_calls` | 1 | 600 | 101.738 | 101.561–105.203 | 1.28% | 1.00x |
| `closure_calls` | 2 | 600 | 114.731 | 111.868–127.592 | 4.71% | 1.77x |
| `closure_calls` | 4 | 600 | 118.051 | 116.878–121.223 | 1.22% | 3.45x |
| `closure_calls` | 8 | 600 | 176.785 | 174.857–183.283 | 1.64% | 4.60x |
| `arguments_calls` | 1 | 600 | 98.905 | 97.648–101.370 | 1.29% | 1.00x |
| `arguments_calls` | 2 | 600 | 99.916 | 99.676–100.958 | 0.49% | 1.98x |
| `arguments_calls` | 4 | 600 | 102.758 | 101.408–103.145 | 0.57% | 3.85x |
| `arguments_calls` | 8 | 600 | 135.391 | 132.791–138.992 | 1.98% | 5.84x |
| `fibonacci` | 1 | 125 | 284.786 | 283.711–285.341 | 0.22% | 1.00x |
| `fibonacci` | 2 | 125 | 327.388 | 288.295–385.144 | 10.03% | 1.74x |
| `fibonacci` | 4 | 125 | 312.595 | 307.879–314.479 | 0.69% | 3.64x |
| `fibonacci` | 8 | 125 | 467.831 | 448.055–475.890 | 2.18% | 4.87x |

## Reading the result

Across these 10 deliberately small kernels, JSC's single-context throughput is 0.44x
the zig-js throughput by geometric mean. These kernels deliberately exercise guarded native/VM tiers that
zig-js currently implements; rows outside those documented subsets continue through general bytecode paths.
The number is a compact description of this matrix, not a claim about applications or unsupported workloads.

At 8 independent warmed contexts, JSC throughput is 0.40x zig-js by
geometric mean; scaling from the mode's own one-lane baseline is 5.60x
for zig-js and 5.08x for JSC. In the symmetric cold lifecycle, JSC
throughput is 0.39x zig-js, with 5.43x
and 4.80x scaling respectively.

zig-js's shared-realm path scales 4.54x at 8 lanes from its
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
- Shared mode prepares one zig-js shared realm and runs two unrecorded full-work shared `Thread` invocations outside the timer, completing one collect/reuse cycle before sampling. Every timed sample then creates and joins the requested JavaScript `Thread`s. Its one-lane row is the scaling baseline.
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

Raw samples: [`benchmark-comparison-2026-07-29-shared-steady.tsv`](benchmark-comparison-2026-07-29-shared-steady.tsv)
