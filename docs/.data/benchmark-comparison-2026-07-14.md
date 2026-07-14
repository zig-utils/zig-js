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
| zig-js | 3d790a60caa28bd228f962a7da9227b64d10b574 |
| JavaScriptCore | system framework 22625.1.20.11.3 |
| Power | Now drawing from 'AC Power' -InternalBattery-0 (id=22806627) 100%; charged; 0:00 remaining present: true |

## Single-thread result

Each row runs the same number of jobs in one GC-enabled zig-js context and one warmed JSC global context.
Both runners time the exact invocation `__benchmarkSelected(__benchmarkJobs, __benchmarkLane)`.
Lower time is better; `JSC / zig-js` is JSC throughput divided by zig-js throughput. RSD is relative standard deviation.

| workload | jobs | zig-js median (ms) | zig-js min–max (ms) | zig-js RSD | JSC median (ms) | JSC min–max (ms) | JSC RSD | JSC / zig-js |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `arithmetic` | 240 | 83.780 | 83.682–85.892 | 0.96% | 354.933 | 349.702–355.641 | 0.63% | 0.24x |
| `properties` | 300 | 87.945 | 87.824–89.973 | 0.88% | 295.436 | 294.696–296.872 | 0.25% | 0.30x |
| `polymorphic_properties` | 400 | 83.648 | 82.048–92.296 | 4.22% | 212.007 | 211.360–212.353 | 0.18% | 0.39x |
| `object_churn` | 100 | 199.623 | 193.440–212.936 | 3.98% | 118.685 | 118.092–127.339 | 2.77% | 1.68x |
| `arrays` | 550 | 82.491 | 81.729–93.874 | 5.13% | 160.115 | 158.217–213.232 | 11.93% | 0.52x |
| `direct_calls` | 600 | 58.718 | 58.608–60.306 | 1.04% | 121.950 | 121.181–123.180 | 0.61% | 0.48x |
| `method_calls` | 500 | 64.648 | 63.788–65.140 | 0.85% | 143.897 | 142.623–146.750 | 1.13% | 0.45x |
| `closure_calls` | 600 | 65.262 | 64.521–67.665 | 2.03% | 197.284 | 194.798–274.819 | 13.73% | 0.33x |
| `arguments_calls` | 600 | 72.378 | 71.095–130.065 | 25.90% | 323.357 | 315.690–368.263 | 5.52% | 0.22x |
| `fibonacci` | 125 | 86.982 | 85.432–88.321 | 1.10% | 470.070 | 465.929–471.035 | 0.43% | 0.19x |

## Independent-context steady state

Both engines keep one warmed context on one persistent OS worker per lane. The timed region contains the
same semaphore dispatch, exact invocation, and completion wait. Every lane performs the full job count.
`scaling` uses the same engine and mode at one lane; cross-engine throughput is directly comparable.

| workload | lanes | jobs/lane | zig-js median (ms) | zig-js min–max (ms) | zig-js RSD | JSC median (ms) | JSC min–max (ms) | JSC RSD | JSC / zig-js | zig-js scaling | JSC scaling |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `arithmetic` | 1 | 240 | 83.549 | 83.390–85.334 | 0.94% | 352.906 | 350.129–354.214 | 0.41% | 0.24x | 1.00x | 1.00x |
| `arithmetic` | 2 | 240 | 87.968 | 85.584–89.483 | 2.02% | 364.195 | 363.615–366.837 | 0.34% | 0.24x | 1.90x | 1.94x |
| `arithmetic` | 4 | 240 | 92.682 | 91.143–109.417 | 6.97% | 404.727 | 393.297–421.296 | 2.21% | 0.23x | 3.61x | 3.49x |
| `arithmetic` | 8 | 240 | 109.669 | 105.895–129.628 | 7.29% | 543.247 | 530.653–600.580 | 4.28% | 0.20x | 6.09x | 5.20x |
| `properties` | 1 | 300 | 88.563 | 88.247–90.242 | 0.83% | 293.916 | 293.323–296.185 | 0.39% | 0.30x | 1.00x | 1.00x |
| `properties` | 2 | 300 | 89.816 | 89.707–93.056 | 1.44% | 300.353 | 299.363–302.774 | 0.39% | 0.30x | 1.97x | 1.96x |
| `properties` | 4 | 300 | 93.593 | 92.459–100.764 | 3.04% | 310.969 | 308.990–318.041 | 0.95% | 0.30x | 3.79x | 3.78x |
| `properties` | 8 | 300 | 122.480 | 117.246–126.044 | 2.46% | 488.012 | 451.564–540.385 | 5.40% | 0.25x | 5.78x | 4.82x |
| `polymorphic_properties` | 1 | 400 | 82.358 | 81.630–84.476 | 1.19% | 207.089 | 205.036–210.781 | 1.11% | 0.40x | 1.00x | 1.00x |
| `polymorphic_properties` | 2 | 400 | 84.436 | 83.340–95.988 | 5.34% | 209.931 | 209.290–212.476 | 0.54% | 0.40x | 1.95x | 1.97x |
| `polymorphic_properties` | 4 | 400 | 90.734 | 87.281–105.231 | 6.56% | 217.995 | 215.524–242.373 | 4.26% | 0.42x | 3.63x | 3.80x |
| `polymorphic_properties` | 8 | 400 | 134.291 | 132.557–210.801 | 19.63% | 331.476 | 320.820–337.967 | 1.92% | 0.41x | 4.91x | 5.00x |
| `object_churn` | 1 | 100 | 214.757 | 192.661–228.530 | 6.48% | 122.614 | 119.923–162.010 | 11.73% | 1.75x | 1.00x | 1.00x |
| `object_churn` | 2 | 100 | 217.057 | 205.706–241.987 | 6.65% | 132.369 | 123.269–215.576 | 22.19% | 1.64x | 1.98x | 1.85x |
| `object_churn` | 4 | 100 | 369.524 | 313.008–409.544 | 10.06% | 124.029 | 122.920–130.000 | 1.93% | 2.98x | 2.32x | 3.95x |
| `object_churn` | 8 | 100 | 844.149 | 627.752–910.199 | 15.28% | 185.509 | 183.861–204.900 | 4.04% | 4.55x | 2.04x | 5.29x |
| `arrays` | 1 | 550 | 81.708 | 80.886–83.723 | 1.21% | 159.425 | 158.409–162.453 | 0.83% | 0.51x | 1.00x | 1.00x |
| `arrays` | 2 | 550 | 84.784 | 84.049–88.444 | 2.08% | 164.383 | 161.414–181.488 | 4.13% | 0.52x | 1.93x | 1.94x |
| `arrays` | 4 | 550 | 107.209 | 95.014–125.568 | 9.92% | 196.914 | 190.382–281.999 | 15.37% | 0.54x | 3.05x | 3.24x |
| `arrays` | 8 | 550 | 132.075 | 127.599–147.100 | 4.93% | 266.929 | 261.727–276.807 | 1.93% | 0.49x | 4.95x | 4.78x |
| `direct_calls` | 1 | 600 | 61.041 | 60.096–65.920 | 3.57% | 121.541 | 120.752–122.817 | 0.63% | 0.50x | 1.00x | 1.00x |
| `direct_calls` | 2 | 600 | 65.341 | 59.503–99.004 | 19.37% | 142.983 | 125.951–264.318 | 29.94% | 0.46x | 1.87x | 1.70x |
| `direct_calls` | 4 | 600 | 62.948 | 62.036–81.069 | 10.57% | 146.063 | 142.942–161.287 | 4.11% | 0.43x | 3.88x | 3.33x |
| `direct_calls` | 8 | 600 | 100.311 | 85.040–109.456 | 10.25% | 217.947 | 215.793–235.341 | 3.30% | 0.46x | 4.87x | 4.46x |
| `method_calls` | 1 | 500 | 63.945 | 63.255–64.264 | 0.58% | 143.187 | 142.995–144.361 | 0.34% | 0.45x | 1.00x | 1.00x |
| `method_calls` | 2 | 500 | 64.059 | 63.694–72.117 | 4.79% | 143.463 | 143.251–147.044 | 1.06% | 0.45x | 2.00x | 2.00x |
| `method_calls` | 4 | 500 | 67.213 | 65.171–94.507 | 14.45% | 160.041 | 156.901–172.929 | 3.30% | 0.42x | 3.81x | 3.58x |
| `method_calls` | 8 | 500 | 96.162 | 92.798–117.402 | 8.84% | 240.392 | 238.180–294.005 | 8.25% | 0.40x | 5.32x | 4.77x |
| `closure_calls` | 1 | 600 | 64.161 | 63.900–64.591 | 0.37% | 194.698 | 192.389–201.915 | 1.68% | 0.33x | 1.00x | 1.00x |
| `closure_calls` | 2 | 600 | 64.288 | 64.128–72.906 | 5.30% | 196.503 | 195.323–205.101 | 1.69% | 0.33x | 2.00x | 1.98x |
| `closure_calls` | 4 | 600 | 65.667 | 65.530–77.436 | 7.47% | 218.285 | 216.419–230.781 | 2.39% | 0.30x | 3.91x | 3.57x |
| `closure_calls` | 8 | 600 | 107.425 | 97.779–116.962 | 5.68% | 370.290 | 348.260–412.334 | 6.43% | 0.29x | 4.78x | 4.21x |
| `arguments_calls` | 1 | 600 | 69.280 | 69.218–70.178 | 0.58% | 318.133 | 315.072–323.303 | 0.82% | 0.22x | 1.00x | 1.00x |
| `arguments_calls` | 2 | 600 | 71.755 | 70.709–74.141 | 1.77% | 314.656 | 312.470–324.971 | 1.42% | 0.23x | 1.93x | 2.02x |
| `arguments_calls` | 4 | 600 | 79.207 | 72.766–88.212 | 7.14% | 356.999 | 353.782–365.708 | 1.39% | 0.22x | 3.50x | 3.56x |
| `arguments_calls` | 8 | 600 | 105.167 | 103.693–119.430 | 5.29% | 563.438 | 537.236–588.254 | 2.73% | 0.19x | 5.27x | 4.52x |
| `fibonacci` | 1 | 125 | 86.922 | 85.987–88.408 | 0.99% | 472.414 | 469.056–473.966 | 0.42% | 0.18x | 1.00x | 1.00x |
| `fibonacci` | 2 | 125 | 88.115 | 86.964–93.904 | 2.67% | 478.406 | 468.148–574.750 | 7.63% | 0.18x | 1.97x | 1.97x |
| `fibonacci` | 4 | 125 | 92.399 | 87.997–113.366 | 9.25% | 492.991 | 479.753–530.938 | 4.03% | 0.19x | 3.76x | 3.83x |
| `fibonacci` | 8 | 125 | 131.385 | 125.692–134.537 | 2.43% | 708.475 | 697.625–747.883 | 2.38% | 0.19x | 5.29x | 5.33x |

## Independent-context cold lifecycle

Neither engine warms these contexts. The timer covers OS-thread creation, context creation, workload-source
evaluation and configuration, the exact invocation, context destruction, and OS-thread join on both sides.
`scaling` uses the same engine and cold lifecycle at one lane.

| workload | lanes | jobs/lane | zig-js median (ms) | zig-js min–max (ms) | zig-js RSD | JSC median (ms) | JSC min–max (ms) | JSC RSD | JSC / zig-js | zig-js scaling | JSC scaling |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `arithmetic` | 1 | 240 | 85.584 | 85.131–86.570 | 0.76% | 356.442 | 351.244–399.842 | 4.70% | 0.24x | 1.00x | 1.00x |
| `arithmetic` | 2 | 240 | 98.686 | 89.446–139.019 | 16.89% | 366.770 | 362.265–391.005 | 2.65% | 0.27x | 1.73x | 1.94x |
| `arithmetic` | 4 | 240 | 94.363 | 89.566–99.184 | 3.42% | 391.982 | 387.854–407.606 | 1.69% | 0.24x | 3.63x | 3.64x |
| `arithmetic` | 8 | 240 | 108.921 | 108.481–117.933 | 3.06% | 561.034 | 539.762–604.771 | 3.83% | 0.19x | 6.29x | 5.08x |
| `properties` | 1 | 300 | 89.914 | 89.204–91.278 | 1.00% | 295.575 | 294.743–313.487 | 2.27% | 0.30x | 1.00x | 1.00x |
| `properties` | 2 | 300 | 91.442 | 91.265–92.451 | 0.50% | 301.973 | 301.631–331.651 | 3.66% | 0.30x | 1.97x | 1.96x |
| `properties` | 4 | 300 | 94.534 | 94.264–106.944 | 5.13% | 313.161 | 312.414–364.048 | 6.01% | 0.30x | 3.80x | 3.78x |
| `properties` | 8 | 300 | 126.847 | 123.087–172.154 | 13.18% | 465.444 | 456.819–519.984 | 4.68% | 0.27x | 5.67x | 5.08x |
| `polymorphic_properties` | 1 | 400 | 83.366 | 83.159–85.245 | 1.07% | 206.208 | 205.657–242.800 | 6.45% | 0.40x | 1.00x | 1.00x |
| `polymorphic_properties` | 2 | 400 | 85.662 | 85.251–87.235 | 0.80% | 214.709 | 210.946–222.964 | 2.33% | 0.40x | 1.95x | 1.92x |
| `polymorphic_properties` | 4 | 400 | 90.268 | 89.098–103.303 | 5.63% | 219.120 | 217.262–244.957 | 4.42% | 0.41x | 3.69x | 3.76x |
| `polymorphic_properties` | 8 | 400 | 139.815 | 133.220–146.751 | 3.34% | 333.653 | 325.274–365.434 | 4.64% | 0.42x | 4.77x | 4.94x |
| `object_churn` | 1 | 100 | 185.399 | 183.524–217.175 | 6.44% | 119.510 | 118.981–126.286 | 2.13% | 1.55x | 1.00x | 1.00x |
| `object_churn` | 2 | 100 | 207.073 | 195.891–239.325 | 7.67% | 129.030 | 124.174–140.525 | 3.82% | 1.60x | 1.79x | 1.85x |
| `object_churn` | 4 | 100 | 300.932 | 297.377–314.867 | 1.89% | 129.864 | 125.250–174.540 | 12.99% | 2.32x | 2.46x | 3.68x |
| `object_churn` | 8 | 100 | 641.918 | 614.624–698.500 | 4.57% | 192.556 | 185.684–222.692 | 6.35% | 3.33x | 2.31x | 4.97x |
| `arrays` | 1 | 550 | 80.749 | 80.122–84.000 | 1.89% | 160.630 | 158.989–228.401 | 14.82% | 0.50x | 1.00x | 1.00x |
| `arrays` | 2 | 550 | 85.233 | 83.417–89.848 | 2.96% | 167.086 | 163.728–176.284 | 3.09% | 0.51x | 1.89x | 1.92x |
| `arrays` | 4 | 550 | 93.180 | 86.334–123.564 | 13.41% | 176.474 | 172.019–222.172 | 9.50% | 0.53x | 3.47x | 3.64x |
| `arrays` | 8 | 550 | 129.178 | 125.415–147.221 | 5.65% | 278.494 | 269.781–289.678 | 2.73% | 0.46x | 5.00x | 4.61x |
| `direct_calls` | 1 | 600 | 66.680 | 60.164–76.087 | 7.41% | 122.646 | 121.143–124.485 | 1.06% | 0.54x | 1.00x | 1.00x |
| `direct_calls` | 2 | 600 | 62.920 | 60.429–77.222 | 9.79% | 134.656 | 125.131–144.277 | 5.33% | 0.47x | 2.12x | 1.82x |
| `direct_calls` | 4 | 600 | 80.072 | 70.854–90.551 | 8.68% | 170.511 | 152.077–209.563 | 13.96% | 0.47x | 3.33x | 2.88x |
| `direct_calls` | 8 | 600 | 87.796 | 84.602–138.147 | 19.80% | 220.885 | 216.613–229.254 | 2.28% | 0.40x | 6.08x | 4.44x |
| `method_calls` | 1 | 500 | 64.940 | 64.760–66.258 | 0.88% | 143.693 | 143.098–146.294 | 0.76% | 0.45x | 1.00x | 1.00x |
| `method_calls` | 2 | 500 | 65.937 | 65.732–75.551 | 5.34% | 144.319 | 144.117–148.361 | 1.06% | 0.46x | 1.97x | 1.99x |
| `method_calls` | 4 | 500 | 73.683 | 68.301–84.423 | 7.56% | 161.335 | 160.332–175.982 | 3.40% | 0.46x | 3.53x | 3.56x |
| `method_calls` | 8 | 500 | 96.371 | 92.873–105.615 | 4.45% | 244.716 | 236.951–252.144 | 1.94% | 0.39x | 5.39x | 4.70x |
| `closure_calls` | 1 | 600 | 65.423 | 64.954–68.196 | 1.87% | 196.365 | 195.393–234.138 | 7.00% | 0.33x | 1.00x | 1.00x |
| `closure_calls` | 2 | 600 | 65.939 | 65.810–72.268 | 3.52% | 197.971 | 197.004–200.995 | 0.84% | 0.33x | 1.98x | 1.98x |
| `closure_calls` | 4 | 600 | 73.234 | 71.077–81.422 | 4.99% | 252.287 | 225.043–284.236 | 10.13% | 0.29x | 3.57x | 3.11x |
| `closure_calls` | 8 | 600 | 106.784 | 103.625–110.799 | 2.17% | 387.724 | 362.698–447.117 | 7.22% | 0.28x | 4.90x | 4.05x |
| `arguments_calls` | 1 | 600 | 71.170 | 70.713–74.459 | 2.39% | 309.929 | 307.594–352.126 | 5.12% | 0.23x | 1.00x | 1.00x |
| `arguments_calls` | 2 | 600 | 75.554 | 71.819–78.264 | 3.46% | 316.158 | 313.674–320.316 | 0.69% | 0.24x | 1.88x | 1.96x |
| `arguments_calls` | 4 | 600 | 82.223 | 78.309–97.577 | 7.97% | 365.829 | 355.245–409.820 | 5.03% | 0.22x | 3.46x | 3.39x |
| `arguments_calls` | 8 | 600 | 134.843 | 127.062–157.299 | 7.39% | 553.067 | 543.710–635.258 | 6.84% | 0.24x | 4.22x | 4.48x |
| `fibonacci` | 1 | 125 | 89.037 | 87.454–107.585 | 7.81% | 472.363 | 468.346–506.853 | 2.83% | 0.19x | 1.00x | 1.00x |
| `fibonacci` | 2 | 125 | 92.409 | 88.712–93.787 | 2.32% | 481.655 | 471.731–515.460 | 3.05% | 0.19x | 1.93x | 1.96x |
| `fibonacci` | 4 | 125 | 97.510 | 91.582–130.985 | 13.60% | 503.481 | 479.653–577.568 | 7.13% | 0.19x | 3.65x | 3.75x |
| `fibonacci` | 8 | 125 | 133.427 | 128.546–190.665 | 15.63% | 751.484 | 717.006–824.252 | 4.69% | 0.18x | 5.34x | 5.03x |

## zig-js shared-realm scaling

This is zig-js's distinct no-GIL shared-object-graph model, which JSC's public C API does not provide.
The timed region creates JavaScript `Thread`s, performs the work, and joins them. Scaling uses the same
shared-realm path at one lane, so thread lifecycle overhead is present in every row.

| workload | lanes | jobs/lane | median (ms) | min–max (ms) | RSD | scaling |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `arithmetic` | 1 | 240 | 83.943 | 83.683–89.859 | 2.67% | 1.00x |
| `arithmetic` | 2 | 240 | 85.516 | 85.195–88.437 | 1.43% | 1.96x |
| `arithmetic` | 4 | 240 | 88.975 | 87.540–95.984 | 3.38% | 3.77x |
| `arithmetic` | 8 | 240 | 109.145 | 107.033–136.173 | 9.07% | 6.15x |
| `properties` | 1 | 300 | 127.460 | 127.153–129.546 | 0.70% | 1.00x |
| `properties` | 2 | 300 | 130.155 | 129.890–132.018 | 0.63% | 1.96x |
| `properties` | 4 | 300 | 135.354 | 133.299–147.895 | 3.72% | 3.77x |
| `properties` | 8 | 300 | 179.127 | 176.413–247.930 | 13.56% | 5.69x |
| `polymorphic_properties` | 1 | 400 | 514.127 | 511.852–518.763 | 0.60% | 1.00x |
| `polymorphic_properties` | 2 | 400 | 541.173 | 523.337–581.152 | 3.63% | 1.90x |
| `polymorphic_properties` | 4 | 400 | 541.010 | 539.600–557.563 | 1.60% | 3.80x |
| `polymorphic_properties` | 8 | 400 | 739.518 | 719.575–765.557 | 2.22% | 5.56x |
| `object_churn` | 1 | 100 | 475.705 | 268.614–537.789 | 18.87% | 1.00x |
| `object_churn` | 2 | 100 | 959.634 | 412.981–1242.534 | 26.99% | 0.99x |
| `object_churn` | 4 | 100 | 4867.850 | 952.259–6065.939 | 40.64% | 0.39x |
| `object_churn` | 8 | 100 | 12368.464 | 5018.402–14664.293 | 26.29% | 0.31x |
| `arrays` | 1 | 550 | 87.152 | 85.428–116.193 | 12.24% | 1.00x |
| `arrays` | 2 | 550 | 97.079 | 96.346–103.994 | 2.91% | 1.80x |
| `arrays` | 4 | 550 | 101.424 | 96.926–118.157 | 6.90% | 3.44x |
| `arrays` | 8 | 550 | 240.393 | 229.389–298.251 | 9.38% | 2.90x |
| `direct_calls` | 1 | 600 | 58.556 | 58.474–66.918 | 5.56% | 1.00x |
| `direct_calls` | 2 | 600 | 61.042 | 60.114–63.457 | 2.32% | 1.92x |
| `direct_calls` | 4 | 600 | 75.427 | 71.092–79.804 | 4.27% | 3.11x |
| `direct_calls` | 8 | 600 | 88.240 | 83.813–91.009 | 2.63% | 5.31x |
| `method_calls` | 1 | 500 | 119.050 | 118.747–124.731 | 1.80% | 1.00x |
| `method_calls` | 2 | 500 | 119.895 | 119.581–122.288 | 0.80% | 1.99x |
| `method_calls` | 4 | 500 | 130.553 | 123.872–141.630 | 4.23% | 3.65x |
| `method_calls` | 8 | 500 | 202.933 | 192.168–338.887 | 24.00% | 4.69x |
| `closure_calls` | 1 | 600 | 64.700 | 64.504–66.786 | 1.48% | 1.00x |
| `closure_calls` | 2 | 600 | 65.693 | 65.347–66.988 | 0.85% | 1.97x |
| `closure_calls` | 4 | 600 | 72.250 | 70.840–78.412 | 3.92% | 3.58x |
| `closure_calls` | 8 | 600 | 100.115 | 98.978–153.590 | 17.93% | 5.17x |
| `arguments_calls` | 1 | 600 | 70.687 | 69.568–76.001 | 3.19% | 1.00x |
| `arguments_calls` | 2 | 600 | 72.833 | 71.159–89.914 | 8.82% | 1.94x |
| `arguments_calls` | 4 | 600 | 80.551 | 78.363–148.517 | 27.73% | 3.51x |
| `arguments_calls` | 8 | 600 | 104.094 | 100.984–142.723 | 13.31% | 5.43x |
| `fibonacci` | 1 | 125 | 250.330 | 247.426–253.321 | 0.92% | 1.00x |
| `fibonacci` | 2 | 125 | 255.069 | 246.701–300.240 | 6.90% | 1.96x |
| `fibonacci` | 4 | 125 | 261.623 | 258.906–266.722 | 0.91% | 3.83x |
| `fibonacci` | 8 | 125 | 394.495 | 378.237–422.726 | 3.89% | 5.08x |

## Reading the result

Across these 10 deliberately small kernels, JSC's single-context throughput is 0.38x
the zig-js throughput by geometric mean. These kernels deliberately exercise guarded native/VM tiers that
zig-js currently implements; rows outside those documented subsets continue through general bytecode paths.
The number is a compact description of this matrix, not a claim about applications or unsupported workloads.

At 8 independent warmed contexts, JSC throughput is 0.39x zig-js by
geometric mean; scaling from the mode's own one-lane baseline is 4.76x
for zig-js and 4.82x for JSC. In the symmetric cold lifecycle, JSC
throughput is 0.38x zig-js, with 4.84x
and 4.73x scaling respectively.

zig-js's shared-realm path scales 3.79x at 8 lanes from its
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
