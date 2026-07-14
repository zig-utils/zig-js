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
| zig-js | c98a36c455848dc464bef9d0c40ccb9639dbc2df |
| JavaScriptCore | system framework 22625.1.20.11.3 |
| Power | Now drawing from 'AC Power' -InternalBattery-0 (id=22806627) 100%; charged; 0:00 remaining present: true |

## Single-thread result

Each row runs the same number of jobs in one GC-enabled zig-js context and one warmed JSC global context.
Both runners time the exact invocation `__benchmarkSelected(__benchmarkJobs, __benchmarkLane)`.
Lower time is better; `JSC / zig-js` is JSC throughput divided by zig-js throughput. RSD is relative standard deviation.

| workload | jobs | zig-js median (ms) | zig-js min–max (ms) | zig-js RSD | JSC median (ms) | JSC min–max (ms) | JSC RSD | JSC / zig-js |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `arithmetic` | 240 | 88.764 | 88.128–93.696 | 2.28% | 348.910 | 345.741–353.214 | 0.82% | 0.25x |
| `properties` | 300 | 87.972 | 86.810–91.098 | 1.66% | 289.043 | 288.619–298.860 | 1.51% | 0.30x |
| `polymorphic_properties` | 400 | 81.124 | 79.758–92.115 | 5.12% | 202.880 | 199.708–208.780 | 1.53% | 0.40x |
| `object_churn` | 100 | 197.469 | 183.213–205.876 | 4.47% | 119.400 | 117.462–122.951 | 1.70% | 1.65x |
| `arrays` | 550 | 78.073 | 76.902–79.896 | 1.41% | 147.870 | 146.336–149.550 | 0.83% | 0.53x |
| `direct_calls` | 600 | 56.532 | 55.558–65.741 | 6.21% | 118.268 | 115.299–120.748 | 1.81% | 0.48x |
| `method_calls` | 500 | 60.881 | 60.340–61.059 | 0.44% | 137.290 | 136.646–137.802 | 0.28% | 0.44x |
| `closure_calls` | 600 | 61.843 | 61.392–63.398 | 1.33% | 186.502 | 185.860–187.787 | 0.34% | 0.33x |
| `arguments_calls` | 600 | 66.822 | 66.570–67.209 | 0.34% | 293.922 | 293.582–294.768 | 0.14% | 0.23x |
| `fibonacci` | 125 | 83.070 | 82.763–83.949 | 0.50% | 453.216 | 449.127–489.271 | 3.19% | 0.18x |

## Independent-context steady state

Both engines keep one warmed context on one persistent OS worker per lane. The timed region contains the
same semaphore dispatch, exact invocation, and completion wait. Every lane performs the full job count.
`scaling` uses the same engine and mode at one lane; cross-engine throughput is directly comparable.

| workload | lanes | jobs/lane | zig-js median (ms) | zig-js min–max (ms) | zig-js RSD | JSC median (ms) | JSC min–max (ms) | JSC RSD | JSC / zig-js | zig-js scaling | JSC scaling |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `arithmetic` | 1 | 240 | 82.285 | 81.019–84.032 | 1.28% | 348.644 | 344.941–350.010 | 0.54% | 0.24x | 1.00x | 1.00x |
| `arithmetic` | 2 | 240 | 106.149 | 97.815–205.065 | 31.57% | 362.813 | 354.398–420.090 | 6.98% | 0.29x | 1.55x | 1.92x |
| `arithmetic` | 4 | 240 | 86.685 | 85.760–92.368 | 2.65% | 370.926 | 369.604–375.150 | 0.50% | 0.23x | 3.80x | 3.76x |
| `arithmetic` | 8 | 240 | 102.917 | 99.974–112.659 | 4.20% | 512.033 | 488.917–522.816 | 2.81% | 0.20x | 6.40x | 5.45x |
| `properties` | 1 | 300 | 91.127 | 89.724–91.601 | 0.66% | 297.303 | 292.974–307.208 | 1.81% | 0.31x | 1.00x | 1.00x |
| `properties` | 2 | 300 | 87.909 | 87.372–88.090 | 0.29% | 292.982 | 292.246–295.512 | 0.40% | 0.30x | 2.07x | 2.03x |
| `properties` | 4 | 300 | 92.148 | 90.906–95.812 | 1.95% | 301.654 | 298.835–314.590 | 1.88% | 0.31x | 3.96x | 3.94x |
| `properties` | 8 | 300 | 113.895 | 108.863–120.967 | 3.23% | 434.044 | 422.461–487.817 | 6.05% | 0.26x | 6.40x | 5.48x |
| `polymorphic_properties` | 1 | 400 | 80.817 | 80.171–82.198 | 0.86% | 204.122 | 200.798–212.296 | 1.86% | 0.40x | 1.00x | 1.00x |
| `polymorphic_properties` | 2 | 400 | 83.009 | 81.762–85.504 | 1.67% | 205.515 | 203.695–207.317 | 0.60% | 0.40x | 1.95x | 1.99x |
| `polymorphic_properties` | 4 | 400 | 83.540 | 83.312–85.185 | 0.77% | 209.784 | 208.850–223.296 | 2.46% | 0.40x | 3.87x | 3.89x |
| `polymorphic_properties` | 8 | 400 | 121.178 | 117.962–131.275 | 4.10% | 338.869 | 327.867–343.549 | 2.00% | 0.36x | 5.34x | 4.82x |
| `object_churn` | 1 | 100 | 193.662 | 184.098–222.519 | 7.44% | 117.745 | 114.680–125.469 | 3.10% | 1.64x | 1.00x | 1.00x |
| `object_churn` | 2 | 100 | 209.716 | 191.145–303.957 | 17.38% | 123.666 | 122.024–131.488 | 2.60% | 1.70x | 1.85x | 1.90x |
| `object_churn` | 4 | 100 | 448.570 | 417.418–604.634 | 16.37% | 151.262 | 134.055–168.737 | 8.41% | 2.97x | 1.73x | 3.11x |
| `object_churn` | 8 | 100 | 714.208 | 573.725–770.017 | 10.37% | 169.960 | 166.154–180.559 | 3.34% | 4.20x | 2.17x | 5.54x |
| `arrays` | 1 | 550 | 81.354 | 80.607–81.797 | 0.58% | 156.249 | 150.405–156.857 | 1.84% | 0.52x | 1.00x | 1.00x |
| `arrays` | 2 | 550 | 80.068 | 79.399–80.649 | 0.68% | 150.915 | 150.497–154.035 | 0.81% | 0.53x | 2.03x | 2.07x |
| `arrays` | 4 | 550 | 83.146 | 81.419–91.068 | 4.10% | 154.925 | 153.999–156.209 | 0.51% | 0.54x | 3.91x | 4.03x |
| `arrays` | 8 | 550 | 117.506 | 113.139–122.982 | 3.15% | 235.293 | 228.134–241.935 | 2.14% | 0.50x | 5.54x | 5.31x |
| `direct_calls` | 1 | 600 | 55.657 | 55.480–57.599 | 1.33% | 115.140 | 113.989–117.632 | 1.12% | 0.48x | 1.00x | 1.00x |
| `direct_calls` | 2 | 600 | 56.711 | 56.517–72.182 | 9.77% | 117.760 | 117.107–121.005 | 1.16% | 0.48x | 1.96x | 1.96x |
| `direct_calls` | 4 | 600 | 59.765 | 58.180–66.998 | 4.98% | 127.033 | 125.174–131.177 | 1.85% | 0.47x | 3.73x | 3.63x |
| `direct_calls` | 8 | 600 | 77.983 | 74.130–92.180 | 8.62% | 190.953 | 184.384–207.456 | 4.33% | 0.41x | 5.71x | 4.82x |
| `method_calls` | 1 | 500 | 61.081 | 60.873–61.679 | 0.47% | 137.126 | 136.945–138.401 | 0.37% | 0.45x | 1.00x | 1.00x |
| `method_calls` | 2 | 500 | 62.547 | 62.246–63.058 | 0.41% | 140.591 | 140.133–180.474 | 10.33% | 0.44x | 1.95x | 1.95x |
| `method_calls` | 4 | 500 | 64.133 | 64.074–75.106 | 6.49% | 144.943 | 143.714–147.977 | 0.98% | 0.44x | 3.81x | 3.78x |
| `method_calls` | 8 | 500 | 85.761 | 84.702–93.939 | 3.64% | 213.969 | 210.769–217.227 | 0.91% | 0.40x | 5.70x | 5.13x |
| `closure_calls` | 1 | 600 | 61.468 | 61.348–62.728 | 0.79% | 188.895 | 186.433–191.819 | 1.13% | 0.33x | 1.00x | 1.00x |
| `closure_calls` | 2 | 600 | 62.800 | 62.620–65.748 | 1.76% | 193.713 | 189.929–195.407 | 0.99% | 0.32x | 1.96x | 1.95x |
| `closure_calls` | 4 | 600 | 64.980 | 64.292–65.811 | 0.83% | 204.204 | 198.579–212.685 | 2.41% | 0.32x | 3.78x | 3.70x |
| `closure_calls` | 8 | 600 | 83.235 | 80.778–85.270 | 1.74% | 307.948 | 303.308–316.648 | 1.29% | 0.27x | 5.91x | 4.91x |
| `arguments_calls` | 1 | 600 | 66.718 | 66.569–66.868 | 0.14% | 296.629 | 295.229–299.930 | 0.52% | 0.22x | 1.00x | 1.00x |
| `arguments_calls` | 2 | 600 | 69.529 | 68.980–69.913 | 0.49% | 308.526 | 301.970–346.236 | 4.96% | 0.23x | 1.92x | 1.92x |
| `arguments_calls` | 4 | 600 | 73.278 | 69.568–86.452 | 9.18% | 326.115 | 313.486–327.820 | 1.53% | 0.22x | 3.64x | 3.64x |
| `arguments_calls` | 8 | 600 | 97.371 | 94.180–138.509 | 15.04% | 494.148 | 483.084–510.512 | 1.87% | 0.20x | 5.48x | 4.80x |
| `fibonacci` | 1 | 125 | 82.561 | 82.409–82.634 | 0.10% | 454.057 | 449.809–478.110 | 2.20% | 0.18x | 1.00x | 1.00x |
| `fibonacci` | 2 | 125 | 84.604 | 83.690–85.750 | 1.07% | 458.906 | 457.228–460.073 | 0.22% | 0.18x | 1.95x | 1.98x |
| `fibonacci` | 4 | 125 | 91.301 | 86.764–144.323 | 21.11% | 473.329 | 469.690–484.474 | 1.30% | 0.19x | 3.62x | 3.84x |
| `fibonacci` | 8 | 125 | 135.307 | 118.052–146.388 | 7.63% | 749.786 | 703.132–845.438 | 7.50% | 0.18x | 4.88x | 4.84x |

## Independent-context cold lifecycle

Neither engine warms these contexts. The timer covers OS-thread creation, context creation, workload-source
evaluation and configuration, the exact invocation, context destruction, and OS-thread join on both sides.
`scaling` uses the same engine and cold lifecycle at one lane.

| workload | lanes | jobs/lane | zig-js median (ms) | zig-js min–max (ms) | zig-js RSD | JSC median (ms) | JSC min–max (ms) | JSC RSD | JSC / zig-js | zig-js scaling | JSC scaling |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `arithmetic` | 1 | 240 | 83.814 | 83.066–85.233 | 0.91% | 355.884 | 346.270–393.799 | 4.68% | 0.24x | 1.00x | 1.00x |
| `arithmetic` | 2 | 240 | 90.778 | 87.861–304.699 | 66.31% | 374.445 | 355.236–491.593 | 11.96% | 0.24x | 1.85x | 1.90x |
| `arithmetic` | 4 | 240 | 87.792 | 87.358–88.362 | 0.36% | 376.634 | 368.721–396.604 | 2.60% | 0.23x | 3.82x | 3.78x |
| `arithmetic` | 8 | 240 | 106.380 | 103.057–112.493 | 2.75% | 504.805 | 497.931–552.886 | 3.71% | 0.21x | 6.30x | 5.64x |
| `properties` | 1 | 300 | 88.423 | 87.178–88.903 | 0.71% | 297.605 | 290.460–312.929 | 2.65% | 0.30x | 1.00x | 1.00x |
| `properties` | 2 | 300 | 89.741 | 88.910–92.495 | 1.46% | 297.663 | 294.338–317.089 | 2.82% | 0.30x | 1.97x | 2.00x |
| `properties` | 4 | 300 | 90.769 | 90.715–91.922 | 0.48% | 312.926 | 302.670–334.599 | 3.08% | 0.29x | 3.90x | 3.80x |
| `properties` | 8 | 300 | 116.851 | 114.486–121.429 | 2.30% | 463.608 | 441.853–511.066 | 4.95% | 0.25x | 6.05x | 5.14x |
| `polymorphic_properties` | 1 | 400 | 83.503 | 82.371–88.233 | 2.28% | 205.964 | 202.628–207.358 | 0.78% | 0.41x | 1.00x | 1.00x |
| `polymorphic_properties` | 2 | 400 | 84.257 | 83.253–87.331 | 1.70% | 205.788 | 204.367–209.591 | 0.90% | 0.41x | 1.98x | 2.00x |
| `polymorphic_properties` | 4 | 400 | 87.268 | 85.779–93.919 | 3.18% | 216.672 | 213.665–289.145 | 11.94% | 0.40x | 3.83x | 3.80x |
| `polymorphic_properties` | 8 | 400 | 126.834 | 121.835–133.472 | 3.19% | 323.658 | 309.414–333.238 | 2.97% | 0.39x | 5.27x | 5.09x |
| `object_churn` | 1 | 100 | 180.656 | 177.333–186.579 | 1.67% | 117.603 | 115.766–118.678 | 0.92% | 1.54x | 1.00x | 1.00x |
| `object_churn` | 2 | 100 | 191.700 | 188.667–204.458 | 3.23% | 122.781 | 121.118–132.615 | 3.14% | 1.56x | 1.88x | 1.92x |
| `object_churn` | 4 | 100 | 359.665 | 316.234–510.250 | 17.78% | 144.232 | 128.464–158.843 | 8.20% | 2.49x | 2.01x | 3.26x |
| `object_churn` | 8 | 100 | 570.335 | 550.291–600.951 | 2.99% | 185.293 | 180.735–195.135 | 2.45% | 3.08x | 2.53x | 5.08x |
| `arrays` | 1 | 550 | 76.207 | 75.812–80.162 | 2.52% | 148.795 | 148.245–156.628 | 2.12% | 0.51x | 1.00x | 1.00x |
| `arrays` | 2 | 550 | 78.706 | 78.462–80.707 | 0.99% | 152.695 | 151.897–153.727 | 0.42% | 0.52x | 1.94x | 1.95x |
| `arrays` | 4 | 550 | 82.265 | 81.793–84.682 | 1.22% | 157.722 | 155.596–163.565 | 2.03% | 0.52x | 3.71x | 3.77x |
| `arrays` | 8 | 550 | 117.090 | 110.426–140.785 | 8.89% | 246.807 | 242.751–251.548 | 1.32% | 0.47x | 5.21x | 4.82x |
| `direct_calls` | 1 | 600 | 57.608 | 57.430–57.675 | 0.17% | 116.458 | 114.577–119.521 | 1.55% | 0.49x | 1.00x | 1.00x |
| `direct_calls` | 2 | 600 | 59.644 | 58.507–76.963 | 10.60% | 119.484 | 117.558–119.947 | 0.77% | 0.50x | 1.93x | 1.95x |
| `direct_calls` | 4 | 600 | 59.603 | 59.479–60.346 | 0.50% | 130.032 | 127.308–131.620 | 1.33% | 0.46x | 3.87x | 3.58x |
| `direct_calls` | 8 | 600 | 79.483 | 77.196–90.263 | 5.56% | 195.635 | 185.695–218.175 | 5.46% | 0.41x | 5.80x | 4.76x |
| `method_calls` | 1 | 500 | 63.555 | 62.834–64.013 | 0.72% | 138.203 | 137.554–140.044 | 0.64% | 0.46x | 1.00x | 1.00x |
| `method_calls` | 2 | 500 | 64.993 | 64.679–66.019 | 0.70% | 141.295 | 140.735–141.898 | 0.35% | 0.46x | 1.96x | 1.96x |
| `method_calls` | 4 | 500 | 65.518 | 65.303–74.731 | 5.19% | 146.534 | 145.602–148.534 | 0.77% | 0.45x | 3.88x | 3.77x |
| `method_calls` | 8 | 500 | 83.890 | 80.903–89.790 | 3.49% | 215.032 | 212.080–218.439 | 0.99% | 0.39x | 6.06x | 5.14x |
| `closure_calls` | 1 | 600 | 63.782 | 63.649–63.993 | 0.19% | 189.764 | 187.431–229.982 | 7.81% | 0.34x | 1.00x | 1.00x |
| `closure_calls` | 2 | 600 | 65.973 | 65.334–67.805 | 1.33% | 193.118 | 192.101–196.036 | 0.73% | 0.34x | 1.93x | 1.97x |
| `closure_calls` | 4 | 600 | 66.084 | 65.662–69.504 | 2.03% | 206.871 | 203.737–234.080 | 4.95% | 0.32x | 3.86x | 3.67x |
| `closure_calls` | 8 | 600 | 83.713 | 80.251–86.036 | 2.17% | 308.218 | 307.067–333.162 | 3.19% | 0.27x | 6.10x | 4.93x |
| `arguments_calls` | 1 | 600 | 67.900 | 67.746–84.835 | 8.76% | 297.808 | 294.712–300.568 | 0.68% | 0.23x | 1.00x | 1.00x |
| `arguments_calls` | 2 | 600 | 69.409 | 69.317–73.084 | 1.99% | 305.577 | 303.160–346.671 | 5.04% | 0.23x | 1.96x | 1.95x |
| `arguments_calls` | 4 | 600 | 77.158 | 71.069–95.187 | 10.52% | 373.375 | 339.810–445.337 | 10.47% | 0.21x | 3.52x | 3.19x |
| `arguments_calls` | 8 | 600 | 102.998 | 96.468–106.249 | 3.92% | 500.940 | 496.211–588.736 | 6.48% | 0.21x | 5.27x | 4.76x |
| `fibonacci` | 1 | 125 | 85.136 | 83.412–92.088 | 3.52% | 452.407 | 448.127–485.030 | 2.81% | 0.19x | 1.00x | 1.00x |
| `fibonacci` | 2 | 125 | 85.318 | 85.233–88.373 | 1.65% | 474.032 | 458.145–507.253 | 3.38% | 0.18x | 2.00x | 1.91x |
| `fibonacci` | 4 | 125 | 90.142 | 87.582–101.757 | 5.11% | 484.487 | 479.875–495.381 | 1.06% | 0.19x | 3.78x | 3.74x |
| `fibonacci` | 8 | 125 | 160.459 | 127.413–241.566 | 22.25% | 756.999 | 716.597–900.770 | 8.83% | 0.21x | 4.24x | 4.78x |

## zig-js shared-realm scaling

This is zig-js's distinct no-GIL shared-object-graph model, which JSC's public C API does not provide.
The timed region creates JavaScript `Thread`s, performs the work, and joins them. Scaling uses the same
shared-realm path at one lane, so thread lifecycle overhead is present in every row.

| workload | lanes | jobs/lane | median (ms) | min–max (ms) | RSD | scaling |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `arithmetic` | 1 | 240 | 83.473 | 82.597–92.658 | 4.35% | 1.00x |
| `arithmetic` | 2 | 240 | 84.652 | 84.155–104.170 | 8.39% | 1.97x |
| `arithmetic` | 4 | 240 | 86.900 | 84.986–88.064 | 1.49% | 3.84x |
| `arithmetic` | 8 | 240 | 102.441 | 100.556–108.887 | 2.65% | 6.52x |
| `properties` | 1 | 300 | 125.505 | 125.363–125.656 | 0.09% | 1.00x |
| `properties` | 2 | 300 | 139.058 | 130.471–155.381 | 6.71% | 1.81x |
| `properties` | 4 | 300 | 129.287 | 128.870–131.067 | 0.57% | 3.88x |
| `properties` | 8 | 300 | 166.612 | 162.929–228.203 | 12.95% | 6.03x |
| `polymorphic_properties` | 1 | 400 | 519.222 | 502.943–535.703 | 2.17% | 1.00x |
| `polymorphic_properties` | 2 | 400 | 514.545 | 512.141–534.966 | 1.54% | 2.02x |
| `polymorphic_properties` | 4 | 400 | 546.665 | 534.734–583.274 | 3.37% | 3.80x |
| `polymorphic_properties` | 8 | 400 | 717.062 | 699.452–737.864 | 1.76% | 5.79x |
| `object_churn` | 1 | 100 | 399.682 | 211.467–456.036 | 21.01% | 1.00x |
| `object_churn` | 2 | 100 | 1027.310 | 382.404–1477.798 | 34.34% | 0.78x |
| `object_churn` | 4 | 100 | 3376.738 | 1302.414–4432.718 | 35.04% | 0.47x |
| `object_churn` | 8 | 100 | 11089.300 | 4650.615–11810.557 | 24.37% | 0.29x |
| `arrays` | 1 | 550 | 80.226 | 79.197–82.112 | 1.22% | 1.00x |
| `arrays` | 2 | 550 | 83.971 | 82.969–84.827 | 0.71% | 1.91x |
| `arrays` | 4 | 550 | 92.056 | 88.593–93.199 | 1.70% | 3.49x |
| `arrays` | 8 | 550 | 232.296 | 225.715–234.080 | 1.24% | 2.76x |
| `direct_calls` | 1 | 600 | 55.595 | 55.531–55.874 | 0.24% | 1.00x |
| `direct_calls` | 2 | 600 | 73.333 | 72.774–74.996 | 0.95% | 1.52x |
| `direct_calls` | 4 | 600 | 58.242 | 58.184–66.196 | 4.95% | 3.82x |
| `direct_calls` | 8 | 600 | 78.896 | 76.496–83.035 | 3.04% | 5.64x |
| `method_calls` | 1 | 500 | 114.588 | 114.180–115.184 | 0.29% | 1.00x |
| `method_calls` | 2 | 500 | 116.358 | 116.133–116.494 | 0.11% | 1.97x |
| `method_calls` | 4 | 500 | 119.395 | 118.762–121.431 | 0.92% | 3.84x |
| `method_calls` | 8 | 500 | 176.190 | 170.722–179.235 | 1.80% | 5.20x |
| `closure_calls` | 1 | 600 | 63.255 | 62.329–63.782 | 0.77% | 1.00x |
| `closure_calls` | 2 | 600 | 63.776 | 63.580–64.322 | 0.42% | 1.98x |
| `closure_calls` | 4 | 600 | 65.066 | 64.790–65.361 | 0.29% | 3.89x |
| `closure_calls` | 8 | 600 | 85.257 | 82.295–90.038 | 3.12% | 5.94x |
| `arguments_calls` | 1 | 600 | 69.610 | 66.484–78.150 | 6.37% | 1.00x |
| `arguments_calls` | 2 | 600 | 69.947 | 68.535–76.934 | 4.16% | 1.99x |
| `arguments_calls` | 4 | 600 | 71.432 | 70.022–73.282 | 1.47% | 3.90x |
| `arguments_calls` | 8 | 600 | 103.016 | 100.816–122.194 | 7.00% | 5.41x |
| `fibonacci` | 1 | 125 | 236.729 | 235.574–238.039 | 0.37% | 1.00x |
| `fibonacci` | 2 | 125 | 252.070 | 244.041–253.284 | 1.31% | 1.88x |
| `fibonacci` | 4 | 125 | 277.814 | 259.268–595.380 | 35.55% | 3.41x |
| `fibonacci` | 8 | 125 | 409.887 | 392.283–447.526 | 4.20% | 4.62x |

## Reading the result

Across these 10 deliberately small kernels, JSC's single-context throughput is 0.39x
the zig-js throughput by geometric mean. These kernels deliberately exercise guarded native/VM tiers that
zig-js currently implements; rows outside those documented subsets continue through general bytecode paths.
The number is a compact description of this matrix, not a claim about applications or unsupported workloads.

At 8 independent warmed contexts, JSC throughput is 0.38x zig-js by
geometric mean; scaling from the mode's own one-lane baseline is 5.16x
for zig-js and 5.10x for JSC. In the symmetric cold lifecycle, JSC
throughput is 0.38x zig-js, with 5.13x
and 5.01x scaling respectively.

zig-js's shared-realm path scales 3.89x at 8 lanes from its
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
