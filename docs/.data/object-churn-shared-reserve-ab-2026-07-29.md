# Shared object-churn reserve A/B — 2026-07-29

Order-balanced exact-parent diagnostic for [#97](https://github.com/zig-utils/zig-js/issues/97).

- parent zig-js: `034fa5d3`
- candidate zig-js: `2e515479`
- zig-gc: `a09c01555f8b5e1485d8be5757864967942f699d` in both variants
- host: macOS-27.0-arm64-arm-64bit · arm64
- sampling: 7 alternating fresh-process pairs per lane; ReleaseFast; exact `object_churn`, 100 jobs/lane
- every checksum, worker count, and collector accounting invariant matched; maximum resident set size is captured by `/usr/bin/time -l`

| lanes | parent wall | candidate wall | speedup | parent scaling | candidate scaling | candidate/parent RSS | pair wins | publication batches parent → candidate |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 1 | 134.990 ms (1.6% RSD) | 128.214 ms (0.6% RSD) | 1.05x | 1.00x | 1.00x | 1.001x | 7/7 | 7,400 → 200 |
| 2 | 166.401 ms (0.9% RSD) | 139.313 ms (1.5% RSD) | 1.19x | 1.62x | 1.84x | 1.003x | 7/7 | 14,800 → 400 |
| 4 | 321.760 ms (18.0% RSD) | 176.972 ms (20.6% RSD) | 1.82x | 1.68x | 2.90x | 1.001x | 7/7 | 29,600 → 800 |
| 8 | 2,361.036 ms (3.5% RSD) | 488.855 ms (6.4% RSD) | 4.83x | 0.46x | 2.10x | 1.001x | 7/7 | 59,200 → 1,600 |

## Finding

The bounded per-interpreter reserve reduces eight-lane shared-heap publication from 59,200 to 1,600 batches (37.0x fewer). Candidate eight-lane scaling is 2.10x, clearing the issue's 1.0x floor without changing work or checksums.

The RSS ratio includes both live benchmark state and the bounded unused reserve tail. The exact-parent comparison therefore checks that the throughput improvement is not purchased with unbounded retention.

Raw timing/RSS/telemetry evidence: [object-churn-shared-reserve-ab-2026-07-29.tsv](object-churn-shared-reserve-ab-2026-07-29.tsv).

This focused A/B establishes causality; the complete zig-js/JavaScriptCore matrix remains the publication gate.
