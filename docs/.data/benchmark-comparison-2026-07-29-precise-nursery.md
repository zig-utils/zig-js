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
| zig-js | 14d94ec0ca4c0f9f98dbf4ffcd30d524df997d4d |
| zig-gc | 98edfaa4aa1b2676680d95801d14118f8ed84156 |
| zig-regex | 2de46683b948ec895e5fa9a9e7e4c384aceccdfe |
| JavaScriptCore | system framework 22625.1.24.11.2 |
| Power | Now drawing from 'AC Power' -InternalBattery-0 (id=23330915) 80%; AC attached; not charging present: true |

## Single-thread result

Each row runs the same number of jobs in one GC-enabled zig-js context and one warmed JSC global context.
Both runners time the exact invocation `__benchmarkSelected(__benchmarkJobs, __benchmarkLane)`.
Lower time is better; `JSC / zig-js` is JSC throughput divided by zig-js throughput. RSD is relative standard deviation.

| workload | jobs | zig-js median (ms) | zig-js min–max (ms) | zig-js RSD | JSC median (ms) | JSC min–max (ms) | JSC RSD | JSC / zig-js |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `arithmetic` | 240 | 87.346 | 86.646–88.574 | 0.73% | 371.065 | 366.529–496.049 | 12.23% | 0.24x |
| `properties` | 300 | 112.459 | 110.145–114.364 | 1.49% | 333.003 | 322.166–394.470 | 7.70% | 0.34x |
| `polymorphic_properties` | 400 | 101.300 | 98.030–103.603 | 2.05% | 215.934 | 211.920–254.292 | 6.82% | 0.47x |
| `object_churn` | 100 | 109.545 | 103.749–111.771 | 2.77% | 132.953 | 130.586–138.729 | 2.20% | 0.82x |
| `arrays` | 550 | 115.129 | 110.963–118.263 | 2.58% | 172.804 | 166.739–177.272 | 2.42% | 0.67x |
| `direct_calls` | 600 | 86.023 | 85.479–88.401 | 1.20% | 129.282 | 128.017–130.200 | 0.58% | 0.67x |
| `method_calls` | 500 | 99.001 | 96.022–149.323 | 20.62% | 155.075 | 154.281–159.680 | 1.25% | 0.64x |
| `closure_calls` | 600 | 102.302 | 100.026–108.762 | 3.32% | 215.938 | 215.534–217.037 | 0.31% | 0.47x |
| `arguments_calls` | 600 | 98.800 | 98.630–103.285 | 1.72% | 341.875 | 337.355–490.883 | 15.30% | 0.29x |
| `fibonacci` | 125 | 93.659 | 92.566–96.059 | 1.20% | 500.404 | 499.285–501.184 | 0.16% | 0.19x |

## Independent-context steady state

Both engines keep one warmed context on one persistent OS worker per lane. The timed region contains the
same semaphore dispatch, exact invocation, and completion wait. Every lane performs the full job count.
`scaling` uses the same engine and mode at one lane; cross-engine throughput is directly comparable.

| workload | lanes | jobs/lane | zig-js median (ms) | zig-js min–max (ms) | zig-js RSD | JSC median (ms) | JSC min–max (ms) | JSC RSD | JSC / zig-js | zig-js scaling | JSC scaling |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `arithmetic` | 1 | 240 | 87.891 | 86.838–88.350 | 0.74% | 368.397 | 365.058–371.525 | 0.57% | 0.24x | 1.00x | 1.00x |
| `arithmetic` | 2 | 240 | 88.509 | 88.263–89.839 | 0.60% | 376.858 | 374.662–379.840 | 0.49% | 0.23x | 1.99x | 1.96x |
| `arithmetic` | 4 | 240 | 90.514 | 89.718–92.045 | 0.78% | 394.366 | 392.825–570.739 | 15.85% | 0.23x | 3.88x | 3.74x |
| `arithmetic` | 8 | 240 | 110.722 | 109.631–124.192 | 5.02% | 583.909 | 542.178–790.296 | 14.76% | 0.19x | 6.35x | 5.05x |
| `properties` | 1 | 300 | 112.312 | 110.886–114.449 | 1.36% | 318.792 | 313.908–325.456 | 1.25% | 0.35x | 1.00x | 1.00x |
| `properties` | 2 | 300 | 113.304 | 112.049–117.533 | 1.65% | 323.722 | 319.491–478.482 | 17.10% | 0.35x | 1.98x | 1.97x |
| `properties` | 4 | 300 | 117.852 | 115.174–125.613 | 3.61% | 339.063 | 333.624–351.037 | 1.99% | 0.35x | 3.81x | 3.76x |
| `properties` | 8 | 300 | 154.824 | 145.900–163.526 | 4.41% | 475.103 | 462.205–488.753 | 2.16% | 0.33x | 5.80x | 5.37x |
| `polymorphic_properties` | 1 | 400 | 105.679 | 99.644–126.130 | 9.32% | 239.455 | 223.571–301.422 | 10.78% | 0.44x | 1.00x | 1.00x |
| `polymorphic_properties` | 2 | 400 | 106.746 | 101.160–107.536 | 2.70% | 219.592 | 218.438–223.373 | 0.88% | 0.49x | 1.98x | 2.18x |
| `polymorphic_properties` | 4 | 400 | 107.768 | 104.965–115.305 | 4.35% | 238.409 | 232.592–255.921 | 3.62% | 0.45x | 3.92x | 4.02x |
| `polymorphic_properties` | 8 | 400 | 181.513 | 164.338–194.674 | 6.42% | 438.309 | 351.780–674.454 | 23.41% | 0.41x | 4.66x | 4.37x |
| `object_churn` | 1 | 100 | 106.180 | 104.558–109.471 | 1.76% | 134.892 | 131.416–232.961 | 24.31% | 0.79x | 1.00x | 1.00x |
| `object_churn` | 2 | 100 | 116.422 | 109.349–118.455 | 3.44% | 139.490 | 136.505–144.093 | 1.96% | 0.83x | 1.82x | 1.93x |
| `object_churn` | 4 | 100 | 145.601 | 123.573–152.391 | 6.82% | 156.091 | 141.470–162.256 | 5.13% | 0.93x | 2.92x | 3.46x |
| `object_churn` | 8 | 100 | 207.214 | 187.407–223.480 | 6.32% | 208.272 | 197.302–378.952 | 27.59% | 0.99x | 4.10x | 5.18x |
| `arrays` | 1 | 550 | 111.240 | 109.562–117.264 | 2.40% | 172.020 | 166.815–176.543 | 2.18% | 0.65x | 1.00x | 1.00x |
| `arrays` | 2 | 550 | 118.829 | 113.163–123.753 | 3.30% | 191.720 | 185.716–218.094 | 5.55% | 0.62x | 1.87x | 1.79x |
| `arrays` | 4 | 550 | 120.468 | 119.067–125.380 | 1.80% | 179.331 | 176.109–180.046 | 0.74% | 0.67x | 3.69x | 3.84x |
| `arrays` | 8 | 550 | 180.861 | 172.184–324.723 | 28.76% | 306.425 | 274.923–328.236 | 7.31% | 0.59x | 4.92x | 4.49x |
| `direct_calls` | 1 | 600 | 89.935 | 87.653–91.016 | 1.19% | 136.306 | 132.610–138.560 | 1.39% | 0.66x | 1.00x | 1.00x |
| `direct_calls` | 2 | 600 | 90.423 | 87.661–94.426 | 2.38% | 136.741 | 130.872–137.806 | 2.25% | 0.66x | 1.99x | 1.99x |
| `direct_calls` | 4 | 600 | 98.976 | 90.047–117.713 | 9.98% | 186.288 | 145.353–322.437 | 29.85% | 0.53x | 3.63x | 2.93x |
| `direct_calls` | 8 | 600 | 123.743 | 113.130–130.675 | 4.50% | 215.434 | 212.563–253.447 | 6.79% | 0.57x | 5.81x | 5.06x |
| `method_calls` | 1 | 500 | 101.291 | 97.201–103.549 | 2.16% | 160.150 | 157.474–162.057 | 1.12% | 0.63x | 1.00x | 1.00x |
| `method_calls` | 2 | 500 | 98.856 | 97.252–101.299 | 1.66% | 156.882 | 156.070–163.221 | 1.54% | 0.63x | 2.05x | 2.04x |
| `method_calls` | 4 | 500 | 102.766 | 102.028–105.032 | 1.12% | 162.606 | 161.566–164.645 | 0.60% | 0.63x | 3.94x | 3.94x |
| `method_calls` | 8 | 500 | 145.647 | 132.215–323.915 | 40.78% | 273.888 | 252.398–283.993 | 3.84% | 0.53x | 5.56x | 4.68x |
| `closure_calls` | 1 | 600 | 103.562 | 102.334–104.736 | 0.84% | 226.242 | 223.582–228.779 | 0.75% | 0.46x | 1.00x | 1.00x |
| `closure_calls` | 2 | 600 | 195.859 | 190.700–209.684 | 3.36% | 234.584 | 224.769–613.632 | 46.63% | 0.83x | 1.06x | 1.93x |
| `closure_calls` | 4 | 600 | 107.295 | 105.357–110.585 | 1.69% | 245.123 | 237.971–327.257 | 12.20% | 0.44x | 3.86x | 3.69x |
| `closure_calls` | 8 | 600 | 145.780 | 140.199–171.551 | 7.18% | 357.832 | 354.858–392.014 | 3.97% | 0.41x | 5.68x | 5.06x |
| `arguments_calls` | 1 | 600 | 101.626 | 100.040–103.246 | 1.18% | 345.073 | 338.125–391.115 | 5.28% | 0.29x | 1.00x | 1.00x |
| `arguments_calls` | 2 | 600 | 100.911 | 99.439–103.228 | 1.30% | 346.643 | 343.531–387.796 | 4.46% | 0.29x | 2.01x | 1.99x |
| `arguments_calls` | 4 | 600 | 107.477 | 105.165–127.674 | 7.27% | 377.478 | 362.026–409.601 | 5.28% | 0.28x | 3.78x | 3.66x |
| `arguments_calls` | 8 | 600 | 141.210 | 132.355–158.308 | 5.89% | 547.461 | 543.425–563.830 | 1.34% | 0.26x | 5.76x | 5.04x |
| `fibonacci` | 1 | 125 | 94.360 | 92.828–97.175 | 1.70% | 500.907 | 498.345–596.510 | 7.21% | 0.19x | 1.00x | 1.00x |
| `fibonacci` | 2 | 125 | 95.359 | 93.744–97.937 | 1.43% | 506.965 | 505.533–513.555 | 0.54% | 0.19x | 1.98x | 1.98x |
| `fibonacci` | 4 | 125 | 100.927 | 99.354–104.107 | 1.55% | 551.073 | 520.852–658.622 | 8.46% | 0.18x | 3.74x | 3.64x |
| `fibonacci` | 8 | 125 | 145.235 | 139.653–148.206 | 2.23% | 743.200 | 730.061–979.163 | 11.59% | 0.20x | 5.20x | 5.39x |

## Independent-context cold lifecycle

Neither engine warms these contexts. The timer covers OS-thread creation, context creation, workload-source
evaluation and configuration, the exact invocation, context destruction, and OS-thread join on both sides.
`scaling` uses the same engine and cold lifecycle at one lane.

| workload | lanes | jobs/lane | zig-js median (ms) | zig-js min–max (ms) | zig-js RSD | JSC median (ms) | JSC min–max (ms) | JSC RSD | JSC / zig-js | zig-js scaling | JSC scaling |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `arithmetic` | 1 | 240 | 90.848 | 90.128–92.725 | 0.91% | 374.633 | 368.669–396.836 | 2.74% | 0.24x | 1.00x | 1.00x |
| `arithmetic` | 2 | 240 | 91.728 | 91.349–93.842 | 0.95% | 377.802 | 375.745–386.536 | 0.96% | 0.24x | 1.98x | 1.98x |
| `arithmetic` | 4 | 240 | 95.920 | 93.988–103.686 | 3.65% | 445.990 | 401.863–508.260 | 9.48% | 0.22x | 3.79x | 3.36x |
| `arithmetic` | 8 | 240 | 114.282 | 111.766–119.862 | 2.77% | 645.684 | 551.271–888.809 | 17.24% | 0.18x | 6.36x | 4.64x |
| `properties` | 1 | 300 | 113.498 | 111.639–115.131 | 1.09% | 322.601 | 315.418–403.962 | 9.56% | 0.35x | 1.00x | 1.00x |
| `properties` | 2 | 300 | 115.292 | 113.367–117.557 | 1.37% | 327.768 | 318.316–336.775 | 2.38% | 0.35x | 1.97x | 1.97x |
| `properties` | 4 | 300 | 123.435 | 117.274–164.576 | 12.95% | 349.831 | 331.779–362.446 | 2.78% | 0.35x | 3.68x | 3.69x |
| `properties` | 8 | 300 | 157.375 | 146.977–175.776 | 5.80% | 478.948 | 463.704–669.515 | 14.54% | 0.33x | 5.77x | 5.39x |
| `polymorphic_properties` | 1 | 400 | 101.811 | 100.667–106.002 | 1.78% | 214.862 | 214.553–219.855 | 0.89% | 0.47x | 1.00x | 1.00x |
| `polymorphic_properties` | 2 | 400 | 110.567 | 104.028–188.245 | 23.69% | 230.157 | 219.192–234.052 | 2.09% | 0.48x | 1.84x | 1.87x |
| `polymorphic_properties` | 4 | 400 | 119.410 | 114.064–260.916 | 38.67% | 244.139 | 236.943–262.406 | 3.72% | 0.49x | 3.41x | 3.52x |
| `polymorphic_properties` | 8 | 400 | 182.485 | 157.488–219.397 | 12.13% | 348.879 | 341.475–379.693 | 3.63% | 0.52x | 4.46x | 4.93x |
| `object_churn` | 1 | 100 | 109.688 | 107.267–114.839 | 2.66% | 137.150 | 133.354–140.490 | 2.01% | 0.80x | 1.00x | 1.00x |
| `object_churn` | 2 | 100 | 117.079 | 112.053–126.515 | 4.67% | 143.667 | 137.621–243.448 | 24.11% | 0.81x | 1.87x | 1.91x |
| `object_churn` | 4 | 100 | 135.536 | 125.801–148.503 | 6.04% | 155.324 | 143.016–160.749 | 4.97% | 0.87x | 3.24x | 3.53x |
| `object_churn` | 8 | 100 | 216.272 | 188.433–226.213 | 6.47% | 220.921 | 200.798–238.647 | 5.68% | 0.98x | 4.06x | 4.97x |
| `arrays` | 1 | 550 | 96.119 | 92.352–100.845 | 2.71% | 184.051 | 179.106–302.236 | 22.76% | 0.52x | 1.00x | 1.00x |
| `arrays` | 2 | 550 | 100.201 | 95.520–168.985 | 23.81% | 175.062 | 173.091–177.201 | 0.73% | 0.57x | 1.92x | 2.10x |
| `arrays` | 4 | 550 | 101.570 | 100.248–114.737 | 5.21% | 209.499 | 181.207–242.110 | 9.74% | 0.48x | 3.79x | 3.51x |
| `arrays` | 8 | 550 | 143.269 | 140.403–167.334 | 6.46% | 274.217 | 271.747–291.897 | 2.82% | 0.52x | 5.37x | 5.37x |
| `direct_calls` | 1 | 600 | 92.201 | 90.359–152.318 | 24.28% | 136.510 | 133.832–152.914 | 4.72% | 0.68x | 1.00x | 1.00x |
| `direct_calls` | 2 | 600 | 91.859 | 89.189–93.979 | 1.81% | 132.551 | 131.998–138.755 | 2.06% | 0.69x | 2.01x | 2.06x |
| `direct_calls` | 4 | 600 | 94.912 | 92.159–102.027 | 4.30% | 146.959 | 141.778–184.693 | 11.23% | 0.65x | 3.89x | 3.72x |
| `direct_calls` | 8 | 600 | 133.303 | 122.771–145.743 | 5.49% | 221.747 | 212.148–255.979 | 6.76% | 0.60x | 5.53x | 4.92x |
| `method_calls` | 1 | 500 | 99.708 | 98.143–100.805 | 0.86% | 158.524 | 155.451–163.251 | 2.04% | 0.63x | 1.00x | 1.00x |
| `method_calls` | 2 | 500 | 100.057 | 99.137–102.585 | 1.22% | 156.902 | 156.162–162.013 | 1.28% | 0.64x | 1.99x | 2.02x |
| `method_calls` | 4 | 500 | 105.688 | 102.743–123.908 | 8.54% | 165.070 | 162.399–201.613 | 8.06% | 0.64x | 3.77x | 3.84x |
| `method_calls` | 8 | 500 | 132.961 | 127.980–146.966 | 4.63% | 248.152 | 242.227–259.577 | 2.55% | 0.54x | 6.00x | 5.11x |
| `closure_calls` | 1 | 600 | 203.962 | 107.068–210.891 | 20.07% | 230.857 | 217.691–288.099 | 12.55% | 0.88x | 1.00x | 1.00x |
| `closure_calls` | 2 | 600 | 104.409 | 103.422–106.929 | 1.10% | 224.080 | 221.644–230.980 | 1.51% | 0.47x | 3.91x | 2.06x |
| `closure_calls` | 4 | 600 | 109.328 | 107.776–122.353 | 5.75% | 260.501 | 243.205–465.722 | 26.24% | 0.42x | 7.46x | 3.54x |
| `closure_calls` | 8 | 600 | 147.254 | 139.803–165.387 | 5.60% | 373.753 | 366.994–424.312 | 5.37% | 0.39x | 11.08x | 4.94x |
| `arguments_calls` | 1 | 600 | 100.586 | 100.155–103.376 | 1.16% | 339.791 | 338.099–347.619 | 0.93% | 0.30x | 1.00x | 1.00x |
| `arguments_calls` | 2 | 600 | 103.383 | 102.244–107.272 | 1.79% | 350.134 | 345.954–361.990 | 1.53% | 0.30x | 1.95x | 1.94x |
| `arguments_calls` | 4 | 600 | 108.236 | 106.536–118.293 | 3.70% | 378.282 | 365.472–445.949 | 7.39% | 0.29x | 3.72x | 3.59x |
| `arguments_calls` | 8 | 600 | 136.654 | 134.734–165.272 | 7.70% | 622.466 | 547.265–665.016 | 7.53% | 0.22x | 5.89x | 4.37x |
| `fibonacci` | 1 | 125 | 98.256 | 95.937–100.626 | 1.42% | 506.760 | 502.947–527.306 | 1.93% | 0.19x | 1.00x | 1.00x |
| `fibonacci` | 2 | 125 | 97.915 | 96.494–105.546 | 3.07% | 506.731 | 505.937–628.945 | 8.70% | 0.19x | 2.01x | 2.00x |
| `fibonacci` | 4 | 125 | 104.474 | 101.143–127.484 | 11.27% | 525.568 | 523.330–561.986 | 2.72% | 0.20x | 3.76x | 3.86x |
| `fibonacci` | 8 | 125 | 175.739 | 160.526–181.948 | 5.44% | 786.981 | 763.547–806.696 | 2.22% | 0.22x | 4.47x | 5.15x |

## zig-js shared-realm scaling

This is zig-js's distinct no-GIL shared-object-graph model, which JSC's public C API does not provide.
The timed region creates JavaScript `Thread`s, performs the work, and joins them. Scaling uses the same
shared-realm path at one lane, so thread lifecycle overhead is present in every row.

| workload | lanes | jobs/lane | median (ms) | min–max (ms) | RSD | scaling |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `arithmetic` | 1 | 240 | 87.596 | 87.227–89.380 | 0.95% | 1.00x |
| `arithmetic` | 2 | 240 | 88.691 | 88.135–89.050 | 0.40% | 1.98x |
| `arithmetic` | 4 | 240 | 91.355 | 90.236–94.169 | 1.41% | 3.84x |
| `arithmetic` | 8 | 240 | 117.922 | 115.175–119.842 | 1.25% | 5.94x |
| `properties` | 1 | 300 | 162.411 | 160.551–165.902 | 1.31% | 1.00x |
| `properties` | 2 | 300 | 165.820 | 161.689–167.802 | 1.28% | 1.96x |
| `properties` | 4 | 300 | 172.045 | 167.929–185.072 | 3.66% | 3.78x |
| `properties` | 8 | 300 | 230.759 | 208.964–240.549 | 4.94% | 5.63x |
| `polymorphic_properties` | 1 | 400 | 755.363 | 749.848–788.097 | 1.71% | 1.00x |
| `polymorphic_properties` | 2 | 400 | 774.966 | 761.043–874.505 | 5.02% | 1.95x |
| `polymorphic_properties` | 4 | 400 | 822.093 | 807.515–963.195 | 6.61% | 3.68x |
| `polymorphic_properties` | 8 | 400 | 1170.687 | 1132.078–1327.643 | 5.74% | 5.16x |
| `object_churn` | 1 | 100 | 178.017 | 174.642–179.393 | 0.98% | 1.00x |
| `object_churn` | 2 | 100 | 252.439 | 226.025–282.590 | 7.66% | 1.41x |
| `object_churn` | 4 | 100 | 446.505 | 398.295–459.714 | 5.75% | 1.59x |
| `object_churn` | 8 | 100 | 964.917 | 864.091–1047.918 | 7.46% | 1.48x |
| `arrays` | 1 | 550 | 718.687 | 689.655–802.192 | 5.43% | 1.00x |
| `arrays` | 2 | 550 | 735.388 | 689.392–772.504 | 3.95% | 1.95x |
| `arrays` | 4 | 550 | 767.613 | 731.779–878.185 | 6.56% | 3.75x |
| `arrays` | 8 | 550 | 1132.373 | 1038.935–1211.826 | 6.58% | 5.08x |
| `direct_calls` | 1 | 600 | 91.062 | 89.093–93.167 | 1.62% | 1.00x |
| `direct_calls` | 2 | 600 | 92.674 | 92.194–94.123 | 0.70% | 1.97x |
| `direct_calls` | 4 | 600 | 100.377 | 99.781–103.219 | 1.37% | 3.63x |
| `direct_calls` | 8 | 600 | 162.305 | 159.505–174.951 | 3.96% | 4.49x |
| `method_calls` | 1 | 500 | 182.278 | 181.106–183.113 | 0.42% | 1.00x |
| `method_calls` | 2 | 500 | 195.523 | 189.653–308.188 | 20.04% | 1.86x |
| `method_calls` | 4 | 500 | 201.150 | 198.155–229.514 | 5.82% | 3.62x |
| `method_calls` | 8 | 500 | 274.260 | 271.592–284.166 | 1.66% | 5.32x |
| `closure_calls` | 1 | 600 | 178.420 | 176.616–183.789 | 1.66% | 1.00x |
| `closure_calls` | 2 | 600 | 112.207 | 111.069–113.898 | 0.85% | 3.18x |
| `closure_calls` | 4 | 600 | 118.863 | 116.299–120.415 | 1.12% | 6.00x |
| `closure_calls` | 8 | 600 | 186.012 | 178.344–195.222 | 3.55% | 7.67x |
| `arguments_calls` | 1 | 600 | 98.328 | 97.566–99.217 | 0.56% | 1.00x |
| `arguments_calls` | 2 | 600 | 99.870 | 99.345–100.048 | 0.25% | 1.97x |
| `arguments_calls` | 4 | 600 | 102.967 | 101.808–104.797 | 0.95% | 3.82x |
| `arguments_calls` | 8 | 600 | 135.106 | 132.808–142.291 | 2.71% | 5.82x |
| `fibonacci` | 1 | 125 | 287.267 | 281.248–307.737 | 3.22% | 1.00x |
| `fibonacci` | 2 | 125 | 286.826 | 286.080–295.487 | 1.16% | 2.00x |
| `fibonacci` | 4 | 125 | 296.282 | 295.579–320.365 | 3.02% | 3.88x |
| `fibonacci` | 8 | 125 | 445.879 | 428.014–456.472 | 2.52% | 5.15x |

## Reading the result

Across these 10 deliberately small kernels, JSC's single-context throughput is 0.43x
the zig-js throughput by geometric mean. These kernels deliberately exercise guarded native/VM tiers that
zig-js currently implements; rows outside those documented subsets continue through general bytecode paths.
The number is a compact description of this matrix, not a claim about applications or unsupported workloads.

At 8 independent warmed contexts, JSC throughput is 0.40x zig-js by
geometric mean; scaling from the mode's own one-lane baseline is 5.35x
for zig-js and 4.96x for JSC. In the symmetric cold lifecycle, JSC
throughput is 0.40x zig-js, with 5.67x
and 4.97x scaling respectively.

zig-js's shared-realm path scales 4.84x at 8 lanes from its
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

Raw samples: [`benchmark-comparison-2026-07-29-precise-nursery.tsv`](benchmark-comparison-2026-07-29-precise-nursery.tsv)
