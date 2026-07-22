# zig-js / JavaScriptCore benchmark — 2026-07-22

> This is a dated measurement, not a universal engine score. The workload source, raw samples,
> timed boundaries, and semantic differences are recorded so the result can be reproduced and challenged.

## Environment

| item | value |
| --- | --- |
| Date | 2026-07-22 |
| Host | Apple M3 Pro; 11 physical / 11 logical CPUs; 18.0 GiB |
| OS | macOS 27.0 (26A5368g) |
| Zig | 0.17.0-dev.1441+d5181a9c9 |
| zig-js | 0c9b329aaa61b1ddb8f0018a82ed69173ded7f8d |
| zig-gc | 88ea25433d1841483a57567c80557df04146a53d |
| zig-regex | b8ca89df644976801e0b6444419444b708eeaa25 |
| JavaScriptCore | system framework 22625.1.20.11.3 |
| Power | Now drawing from 'AC Power' -InternalBattery-0 (id=22872163) 100%; charged; 0:00 remaining present: true |

## Single-thread result

Each row runs the same number of jobs in one GC-enabled zig-js context and one warmed JSC global context.
Both runners time the exact invocation `__benchmarkSelected(__benchmarkJobs, __benchmarkLane)`.
Lower time is better; `JSC / zig-js` is JSC throughput divided by zig-js throughput. RSD is relative standard deviation.

| workload | jobs | zig-js median (ms) | zig-js min–max (ms) | zig-js RSD | JSC median (ms) | JSC min–max (ms) | JSC RSD | JSC / zig-js |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `arithmetic` | 240 | 85.612 | 85.470–85.869 | 0.16% | 365.538 | 361.104–402.949 | 4.21% | 0.23x |
| `properties` | 300 | 188.060 | 187.723–189.354 | 0.35% | 305.747 | 302.671–313.091 | 1.33% | 0.62x |
| `polymorphic_properties` | 400 | 95.175 | 95.038–95.379 | 0.13% | 210.931 | 207.936–218.379 | 2.10% | 0.45x |
| `object_churn` | 100 | 120.935 | 114.947–136.680 | 6.55% | 127.838 | 124.704–269.211 | 36.17% | 0.95x |
| `arrays` | 550 | 93.498 | 87.685–114.248 | 10.63% | 167.486 | 161.540–180.900 | 4.02% | 0.56x |
| `direct_calls` | 600 | 93.154 | 90.085–94.906 | 1.87% | 121.268 | 120.863–123.798 | 0.84% | 0.77x |
| `method_calls` | 500 | 90.155 | 89.703–95.163 | 2.18% | 143.314 | 143.013–143.860 | 0.19% | 0.63x |
| `closure_calls` | 600 | 94.393 | 94.254–95.557 | 0.59% | 195.357 | 194.954–196.795 | 0.37% | 0.48x |
| `arguments_calls` | 600 | 96.988 | 92.713–98.485 | 2.42% | 311.864 | 311.595–319.260 | 0.89% | 0.31x |
| `fibonacci` | 125 | 89.225 | 88.152–99.610 | 5.27% | 480.414 | 476.964–499.080 | 1.59% | 0.19x |

## Independent-context steady state

Both engines keep one warmed context on one persistent OS worker per lane. The timed region contains the
same semaphore dispatch, exact invocation, and completion wait. Every lane performs the full job count.
`scaling` uses the same engine and mode at one lane; cross-engine throughput is directly comparable.

| workload | lanes | jobs/lane | zig-js median (ms) | zig-js min–max (ms) | zig-js RSD | JSC median (ms) | JSC min–max (ms) | JSC RSD | JSC / zig-js | zig-js scaling | JSC scaling |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `arithmetic` | 1 | 240 | 85.789 | 85.492–88.549 | 1.25% | 366.893 | 360.380–417.356 | 5.86% | 0.23x | 1.00x | 1.00x |
| `arithmetic` | 2 | 240 | 86.788 | 86.666–87.266 | 0.27% | 397.762 | 390.441–420.724 | 2.51% | 0.22x | 1.98x | 1.84x |
| `arithmetic` | 4 | 240 | 95.855 | 93.572–102.556 | 3.41% | 474.519 | 445.214–495.790 | 3.31% | 0.20x | 3.58x | 3.09x |
| `arithmetic` | 8 | 240 | 128.543 | 117.107–145.759 | 7.70% | 679.304 | 573.442–890.825 | 16.58% | 0.19x | 5.34x | 4.32x |
| `properties` | 1 | 300 | 188.073 | 187.774–194.956 | 1.59% | 303.517 | 302.174–320.835 | 2.19% | 0.62x | 1.00x | 1.00x |
| `properties` | 2 | 300 | 246.739 | 193.497–339.288 | 21.06% | 338.930 | 303.125–385.071 | 9.55% | 0.73x | 1.52x | 1.79x |
| `properties` | 4 | 300 | 267.965 | 232.775–345.216 | 16.36% | 393.584 | 358.607–446.324 | 8.91% | 0.68x | 2.81x | 3.08x |
| `properties` | 8 | 300 | 302.659 | 288.132–505.644 | 23.38% | 496.007 | 473.092–542.233 | 4.33% | 0.61x | 4.97x | 4.90x |
| `polymorphic_properties` | 1 | 400 | 95.939 | 95.616–102.008 | 2.35% | 212.889 | 209.672–260.575 | 10.33% | 0.45x | 1.00x | 1.00x |
| `polymorphic_properties` | 2 | 400 | 97.661 | 96.787–98.153 | 0.54% | 213.898 | 212.325–214.521 | 0.41% | 0.46x | 1.96x | 1.99x |
| `polymorphic_properties` | 4 | 400 | 117.756 | 104.471–120.698 | 4.64% | 257.327 | 254.469–266.423 | 1.91% | 0.46x | 3.26x | 3.31x |
| `polymorphic_properties` | 8 | 400 | 161.097 | 148.765–215.069 | 13.14% | 351.387 | 341.980–360.375 | 1.97% | 0.46x | 4.76x | 4.85x |
| `object_churn` | 1 | 100 | 114.636 | 114.229–115.719 | 0.49% | 122.697 | 122.354–123.680 | 0.41% | 0.93x | 1.00x | 1.00x |
| `object_churn` | 2 | 100 | 199.701 | 197.100–223.613 | 5.52% | 126.399 | 125.087–131.922 | 1.93% | 1.58x | 1.15x | 1.94x |
| `object_churn` | 4 | 100 | 892.263 | 826.267–902.905 | 3.38% | 130.527 | 128.693–142.113 | 3.56% | 6.84x | 0.51x | 3.76x |
| `object_churn` | 8 | 100 | 3548.104 | 3175.689–3651.683 | 5.44% | 195.609 | 189.484–232.430 | 7.88% | 18.14x | 0.26x | 5.02x |
| `arrays` | 1 | 550 | 88.963 | 88.049–89.507 | 0.49% | 162.299 | 161.295–177.706 | 3.57% | 0.55x | 1.00x | 1.00x |
| `arrays` | 2 | 550 | 89.538 | 88.746–92.621 | 1.66% | 159.588 | 158.748–161.885 | 0.71% | 0.56x | 1.99x | 2.03x |
| `arrays` | 4 | 550 | 95.869 | 94.675–98.213 | 1.36% | 169.624 | 167.079–171.657 | 0.93% | 0.57x | 3.71x | 3.83x |
| `arrays` | 8 | 550 | 137.190 | 131.017–160.951 | 8.09% | 261.037 | 255.539–278.474 | 2.89% | 0.53x | 5.19x | 4.97x |
| `direct_calls` | 1 | 600 | 81.397 | 81.279–82.950 | 0.74% | 122.388 | 121.998–122.793 | 0.23% | 0.67x | 1.00x | 1.00x |
| `direct_calls` | 2 | 600 | 81.991 | 81.747–83.062 | 0.53% | 133.743 | 126.177–145.598 | 4.52% | 0.61x | 1.99x | 1.83x |
| `direct_calls` | 4 | 600 | 85.857 | 84.241–88.517 | 1.67% | 137.486 | 132.367–139.339 | 1.69% | 0.62x | 3.79x | 3.56x |
| `direct_calls` | 8 | 600 | 112.317 | 108.986–120.816 | 3.87% | 202.801 | 195.305–220.574 | 3.85% | 0.55x | 5.80x | 4.83x |
| `method_calls` | 1 | 500 | 91.747 | 90.465–138.277 | 17.41% | 144.353 | 143.629–147.160 | 0.95% | 0.64x | 1.00x | 1.00x |
| `method_calls` | 2 | 500 | 92.895 | 90.944–99.430 | 3.71% | 145.093 | 144.577–145.737 | 0.29% | 0.64x | 1.98x | 1.99x |
| `method_calls` | 4 | 500 | 98.157 | 96.652–100.413 | 1.35% | 152.780 | 149.124–154.469 | 1.10% | 0.64x | 3.74x | 3.78x |
| `method_calls` | 8 | 500 | 125.654 | 121.428–128.155 | 1.99% | 242.232 | 227.833–259.741 | 4.97% | 0.52x | 5.84x | 4.77x |
| `closure_calls` | 1 | 600 | 95.629 | 94.503–128.951 | 12.98% | 201.716 | 196.647–267.775 | 12.07% | 0.47x | 1.00x | 1.00x |
| `closure_calls` | 2 | 600 | 94.979 | 94.788–95.159 | 0.16% | 197.931 | 197.235–200.374 | 0.54% | 0.48x | 2.01x | 2.04x |
| `closure_calls` | 4 | 600 | 124.592 | 115.892–136.205 | 6.69% | 232.474 | 221.183–288.959 | 11.73% | 0.54x | 3.07x | 3.47x |
| `closure_calls` | 8 | 600 | 137.289 | 130.364–150.246 | 5.29% | 348.737 | 327.111–395.687 | 7.37% | 0.39x | 5.57x | 4.63x |
| `arguments_calls` | 1 | 600 | 92.725 | 92.637–92.799 | 0.07% | 311.684 | 311.506–314.603 | 0.37% | 0.30x | 1.00x | 1.00x |
| `arguments_calls` | 2 | 600 | 95.136 | 93.677–98.143 | 1.50% | 318.874 | 316.367–319.622 | 0.38% | 0.30x | 1.95x | 1.95x |
| `arguments_calls` | 4 | 600 | 98.986 | 96.758–107.401 | 4.26% | 399.493 | 338.682–506.827 | 14.31% | 0.25x | 3.75x | 3.12x |
| `arguments_calls` | 8 | 600 | 143.082 | 137.548–146.926 | 2.57% | 540.173 | 521.336–605.221 | 5.25% | 0.26x | 5.18x | 4.62x |
| `fibonacci` | 1 | 125 | 89.429 | 87.909–90.325 | 1.06% | 478.695 | 477.185–479.626 | 0.20% | 0.19x | 1.00x | 1.00x |
| `fibonacci` | 2 | 125 | 95.519 | 92.313–133.576 | 16.05% | 480.598 | 478.828–482.906 | 0.31% | 0.20x | 1.87x | 1.99x |
| `fibonacci` | 4 | 125 | 126.089 | 113.240–144.532 | 8.98% | 503.375 | 497.536–514.046 | 1.13% | 0.25x | 2.84x | 3.80x |
| `fibonacci` | 8 | 125 | 163.211 | 141.492–222.693 | 17.03% | 851.681 | 739.014–884.086 | 7.15% | 0.19x | 4.38x | 4.50x |

## Independent-context cold lifecycle

Neither engine warms these contexts. The timer covers OS-thread creation, context creation, workload-source
evaluation and configuration, the exact invocation, context destruction, and OS-thread join on both sides.
`scaling` uses the same engine and cold lifecycle at one lane.

| workload | lanes | jobs/lane | zig-js median (ms) | zig-js min–max (ms) | zig-js RSD | JSC median (ms) | JSC min–max (ms) | JSC RSD | JSC / zig-js | zig-js scaling | JSC scaling |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `arithmetic` | 1 | 240 | 88.131 | 87.992–89.218 | 0.49% | 363.431 | 356.947–368.883 | 1.00% | 0.24x | 1.00x | 1.00x |
| `arithmetic` | 2 | 240 | 89.407 | 89.300–91.026 | 0.84% | 396.042 | 387.663–404.967 | 1.43% | 0.23x | 1.97x | 1.84x |
| `arithmetic` | 4 | 240 | 100.117 | 97.379–102.449 | 1.94% | 446.396 | 434.776–466.257 | 2.69% | 0.22x | 3.52x | 3.26x |
| `arithmetic` | 8 | 240 | 120.895 | 116.813–169.742 | 14.38% | 620.889 | 565.197–768.099 | 11.16% | 0.19x | 5.83x | 4.68x |
| `properties` | 1 | 300 | 108.941 | 107.682–110.563 | 0.85% | 303.481 | 302.804–306.041 | 0.36% | 0.36x | 1.00x | 1.00x |
| `properties` | 2 | 300 | 110.586 | 109.569–110.989 | 0.51% | 307.649 | 305.907–348.211 | 4.98% | 0.36x | 1.97x | 1.97x |
| `properties` | 4 | 300 | 123.111 | 121.137–162.315 | 11.36% | 423.037 | 365.570–534.214 | 11.73% | 0.29x | 3.54x | 2.87x |
| `properties` | 8 | 300 | 160.278 | 155.184–193.851 | 7.98% | 494.806 | 474.041–505.868 | 2.37% | 0.32x | 5.44x | 4.91x |
| `polymorphic_properties` | 1 | 400 | 97.982 | 97.659–99.190 | 0.53% | 210.746 | 210.223–212.108 | 0.29% | 0.46x | 1.00x | 1.00x |
| `polymorphic_properties` | 2 | 400 | 100.236 | 99.263–101.116 | 0.79% | 230.803 | 215.787–340.466 | 18.02% | 0.43x | 1.96x | 1.83x |
| `polymorphic_properties` | 4 | 400 | 118.036 | 115.673–120.504 | 1.57% | 259.127 | 255.514–266.062 | 1.50% | 0.46x | 3.32x | 3.25x |
| `polymorphic_properties` | 8 | 400 | 158.591 | 152.900–174.319 | 4.70% | 348.522 | 344.192–364.253 | 2.36% | 0.46x | 4.94x | 4.84x |
| `object_churn` | 1 | 100 | 123.067 | 120.620–179.564 | 16.54% | 132.221 | 124.070–187.073 | 18.04% | 0.93x | 1.00x | 1.00x |
| `object_churn` | 2 | 100 | 241.051 | 205.057–259.643 | 7.24% | 126.807 | 126.433–128.440 | 0.59% | 1.90x | 1.02x | 2.09x |
| `object_churn` | 4 | 100 | 816.325 | 809.179–820.197 | 0.48% | 134.486 | 131.482–140.324 | 2.26% | 6.07x | 0.60x | 3.93x |
| `object_churn` | 8 | 100 | 3438.036 | 2920.139–3561.671 | 6.66% | 198.845 | 192.941–215.533 | 3.81% | 17.29x | 0.29x | 5.32x |
| `arrays` | 1 | 550 | 86.418 | 86.034–89.551 | 1.42% | 161.492 | 159.191–171.682 | 2.57% | 0.54x | 1.00x | 1.00x |
| `arrays` | 2 | 550 | 89.060 | 88.413–93.639 | 2.16% | 161.514 | 160.648–161.879 | 0.28% | 0.55x | 1.94x | 2.00x |
| `arrays` | 4 | 550 | 95.579 | 92.803–101.441 | 2.94% | 170.356 | 167.330–171.616 | 0.80% | 0.56x | 3.62x | 3.79x |
| `arrays` | 8 | 550 | 137.550 | 135.334–147.071 | 2.81% | 271.975 | 266.201–370.854 | 13.01% | 0.51x | 5.03x | 4.75x |
| `direct_calls` | 1 | 600 | 83.367 | 83.233–85.433 | 0.95% | 121.550 | 121.476–144.353 | 6.89% | 0.69x | 1.00x | 1.00x |
| `direct_calls` | 2 | 600 | 84.567 | 84.237–87.270 | 1.27% | 125.952 | 124.946–216.331 | 24.38% | 0.67x | 1.97x | 1.93x |
| `direct_calls` | 4 | 600 | 101.787 | 99.692–103.240 | 1.24% | 136.521 | 132.652–139.989 | 1.89% | 0.75x | 3.28x | 3.56x |
| `direct_calls` | 8 | 600 | 114.421 | 108.558–119.474 | 2.98% | 207.776 | 205.663–211.704 | 0.99% | 0.55x | 5.83x | 4.68x |
| `method_calls` | 1 | 500 | 92.752 | 92.471–104.194 | 4.51% | 144.859 | 144.711–147.788 | 0.82% | 0.64x | 1.00x | 1.00x |
| `method_calls` | 2 | 500 | 93.357 | 93.215–93.614 | 0.14% | 145.897 | 145.559–147.527 | 0.48% | 0.64x | 1.99x | 1.99x |
| `method_calls` | 4 | 500 | 101.996 | 98.835–105.499 | 2.22% | 155.113 | 152.884–157.869 | 1.17% | 0.66x | 3.64x | 3.74x |
| `method_calls` | 8 | 500 | 129.926 | 125.775–132.369 | 1.56% | 275.540 | 236.064–347.539 | 14.52% | 0.47x | 5.71x | 4.21x |
| `closure_calls` | 1 | 600 | 96.466 | 96.044–134.114 | 14.54% | 198.954 | 195.609–232.180 | 6.82% | 0.48x | 1.00x | 1.00x |
| `closure_calls` | 2 | 600 | 97.809 | 97.292–99.500 | 0.82% | 199.447 | 198.270–200.436 | 0.38% | 0.49x | 1.97x | 2.00x |
| `closure_calls` | 4 | 600 | 132.841 | 106.351–196.647 | 21.67% | 223.391 | 216.779–258.421 | 6.39% | 0.59x | 2.90x | 3.56x |
| `closure_calls` | 8 | 600 | 135.687 | 131.570–176.712 | 11.42% | 359.047 | 341.782–372.793 | 3.22% | 0.38x | 5.69x | 4.43x |
| `arguments_calls` | 1 | 600 | 94.817 | 94.627–95.397 | 0.28% | 313.439 | 313.072–315.496 | 0.30% | 0.30x | 1.00x | 1.00x |
| `arguments_calls` | 2 | 600 | 97.149 | 95.955–99.129 | 1.14% | 319.692 | 317.348–320.476 | 0.32% | 0.30x | 1.95x | 1.96x |
| `arguments_calls` | 4 | 600 | 110.674 | 105.644–114.123 | 2.32% | 351.244 | 348.502–398.329 | 5.79% | 0.32x | 3.43x | 3.57x |
| `arguments_calls` | 8 | 600 | 134.330 | 131.309–136.839 | 1.76% | 539.916 | 521.740–554.055 | 2.25% | 0.25x | 5.65x | 4.64x |
| `fibonacci` | 1 | 125 | 91.132 | 90.131–91.967 | 0.69% | 480.598 | 478.374–497.660 | 1.41% | 0.19x | 1.00x | 1.00x |
| `fibonacci` | 2 | 125 | 94.110 | 92.029–126.752 | 12.60% | 484.820 | 480.796–499.333 | 1.28% | 0.19x | 1.94x | 1.98x |
| `fibonacci` | 4 | 125 | 109.034 | 104.931–182.530 | 22.90% | 508.365 | 494.766–552.416 | 3.80% | 0.21x | 3.34x | 3.78x |
| `fibonacci` | 8 | 125 | 151.257 | 138.824–412.340 | 52.54% | 742.694 | 714.736–917.456 | 9.58% | 0.20x | 4.82x | 5.18x |

## zig-js shared-realm scaling

This is zig-js's distinct no-GIL shared-object-graph model, which JSC's public C API does not provide.
The timed region creates JavaScript `Thread`s, performs the work, and joins them. Scaling uses the same
shared-realm path at one lane, so thread lifecycle overhead is present in every row.

| workload | lanes | jobs/lane | median (ms) | min–max (ms) | RSD | scaling |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `arithmetic` | 1 | 240 | 1669.693 | 1665.850–1868.678 | 5.19% | 1.00x |
| `arithmetic` | 2 | 240 | 1703.962 | 1685.755–1848.161 | 3.72% | 1.96x |
| `arithmetic` | 4 | 240 | 2127.420 | 1980.887–2233.279 | 4.61% | 3.14x |
| `arithmetic` | 8 | 240 | 2568.788 | 2471.511–2796.847 | 5.65% | 5.20x |
| `properties` | 1 | 300 | 149.164 | 148.871–149.362 | 0.12% | 1.00x |
| `properties` | 2 | 300 | 154.144 | 150.824–219.233 | 16.53% | 1.94x |
| `properties` | 4 | 300 | 186.437 | 178.061–276.082 | 17.22% | 3.20x |
| `properties` | 8 | 300 | 219.064 | 215.342–227.520 | 1.89% | 5.45x |
| `polymorphic_properties` | 1 | 400 | 719.091 | 717.194–720.056 | 0.14% | 1.00x |
| `polymorphic_properties` | 2 | 400 | 734.247 | 729.149–774.144 | 2.12% | 1.96x |
| `polymorphic_properties` | 4 | 400 | 873.986 | 833.836–1091.286 | 10.22% | 3.29x |
| `polymorphic_properties` | 8 | 400 | 1070.806 | 1059.175–1077.601 | 0.59% | 5.37x |
| `object_churn` | 1 | 100 | 192.658 | 110.701–212.282 | 17.99% | 1.00x |
| `object_churn` | 2 | 100 | 337.700 | 138.952–357.978 | 25.54% | 1.14x |
| `object_churn` | 4 | 100 | 638.948 | 298.247–687.726 | 22.62% | 1.21x |
| `object_churn` | 8 | 100 | 2043.289 | 1787.845–2225.879 | 8.30% | 0.75x |
| `arrays` | 1 | 550 | 92.665 | 91.445–94.997 | 1.55% | 1.00x |
| `arrays` | 2 | 550 | 96.215 | 95.855–98.365 | 0.90% | 1.93x |
| `arrays` | 4 | 550 | 135.714 | 129.704–155.594 | 6.40% | 2.73x |
| `arrays` | 8 | 550 | 327.614 | 291.281–345.331 | 5.70% | 2.26x |
| `direct_calls` | 1 | 600 | 86.687 | 86.610–86.790 | 0.07% | 1.00x |
| `direct_calls` | 2 | 600 | 94.974 | 90.904–112.096 | 8.88% | 1.83x |
| `direct_calls` | 4 | 600 | 98.592 | 97.293–101.434 | 1.67% | 3.52x |
| `direct_calls` | 8 | 600 | 165.194 | 162.828–169.785 | 1.58% | 4.20x |
| `method_calls` | 1 | 500 | 163.973 | 163.581–167.598 | 0.86% | 1.00x |
| `method_calls` | 2 | 500 | 170.598 | 170.437–171.310 | 0.18% | 1.92x |
| `method_calls` | 4 | 500 | 222.908 | 182.950–298.072 | 18.79% | 2.94x |
| `method_calls` | 8 | 500 | 264.889 | 257.398–303.746 | 5.85% | 4.95x |
| `closure_calls` | 1 | 600 | 90.517 | 89.299–94.042 | 1.81% | 1.00x |
| `closure_calls` | 2 | 600 | 103.010 | 97.410–107.901 | 3.57% | 1.76x |
| `closure_calls` | 4 | 600 | 109.636 | 102.045–118.791 | 6.48% | 3.30x |
| `closure_calls` | 8 | 600 | 162.807 | 159.866–168.649 | 1.83% | 4.45x |
| `arguments_calls` | 1 | 600 | 93.057 | 92.841–94.326 | 0.54% | 1.00x |
| `arguments_calls` | 2 | 600 | 94.122 | 93.255–96.521 | 1.17% | 1.98x |
| `arguments_calls` | 4 | 600 | 96.138 | 95.089–98.929 | 1.45% | 3.87x |
| `arguments_calls` | 8 | 600 | 132.310 | 130.442–163.193 | 9.05% | 5.63x |
| `fibonacci` | 1 | 125 | 279.448 | 273.136–282.206 | 1.15% | 1.00x |
| `fibonacci` | 2 | 125 | 279.135 | 275.185–300.569 | 3.18% | 2.00x |
| `fibonacci` | 4 | 125 | 287.895 | 281.950–371.166 | 10.59% | 3.88x |
| `fibonacci` | 8 | 125 | 418.668 | 397.971–500.181 | 8.35% | 5.34x |

## Reading the result

Across these 10 deliberately small kernels, JSC's single-context throughput is 0.46x
the zig-js throughput by geometric mean. These kernels deliberately exercise guarded native/VM tiers that
zig-js currently implements; rows outside those documented subsets continue through general bytecode paths.
The number is a compact description of this matrix, not a claim about applications or unsupported workloads.

At 8 independent warmed contexts, JSC throughput is 0.56x zig-js by
geometric mean; scaling from the mode's own one-lane baseline is 3.86x
for zig-js and 4.73x for JSC. In the symmetric cold lifecycle, JSC
throughput is 0.51x zig-js, with 4.04x
and 4.75x scaling respectively.

zig-js's shared-realm path scales 3.85x at 8 lanes from its
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

Raw samples: [`benchmark-comparison-2026-07-22-property-osr.tsv`](benchmark-comparison-2026-07-22-property-osr.tsv)
