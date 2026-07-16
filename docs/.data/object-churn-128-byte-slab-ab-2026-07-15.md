# Object-churn 128-byte-slab A/B — 2026-07-15

This focused comparison isolates the ordinary-object slab-class crossing introduced by zig-js commit
`0b82d1c8` and its wrapper-free literal guard at `12aa217c`. The candidate is `12aa217c`; the exact
parent is `41bfd83c`. Both runners used the same local zig-gc and zig-regex revisions, build mode,
workload source, host, and alternating execution order. Lower elapsed time is better.

## Direct and independent-context result

Seven samples were collected for each object-churn mode. The table reports medians and the parent/candidate
speedup, so values above 1.00x favor the 128-byte candidate.

| mode | lanes | candidate (ms) | parent (ms) | speedup |
| --- | ---: | ---: | ---: | ---: |
| direct warmed context | 1 | 95.840 | 106.280 | 1.11x |
| independent steady | 1 | 89.054 | 92.688 | 1.04x |
| independent steady | 4 | 113.555 | 172.304 | 1.52x |
| independent steady | 8 | 164.813 | 271.063 | 1.64x |
| independent cold | 1 | 86.977 | 90.279 | 1.04x |
| independent cold | 4 | 107.002 | 166.450 | 1.56x |
| independent cold | 8 | 163.082 | 256.702 | 1.57x |

## Shared-realm confirmation

Because shared object churn has higher dispersion, an independent 11-sample shared-only confirmation was
run. RSD is included rather than hiding the noise.

| lanes | candidate (ms) | candidate RSD | parent (ms) | parent RSD | speedup |
| ---: | ---: | ---: | ---: | ---: | ---: |
| 1 | 151.113 | 9.43% | 179.822 | 14.20% | 1.19x |
| 4 | 580.141 | 12.92% | 806.132 | 21.45% | 1.39x |
| 8 | 1,468.239 | 6.38% | 1,705.917 | 13.29% | 1.16x |

Shared four-lane scaling improved from 0.89x to 1.04x. Eight-lane scaling was 0.82x for the candidate and
0.84x for the parent, which is effectively stable relative to the observed dispersion while absolute
candidate time improved by 16%. The complete post-change JSC matrix is preserved in
[`benchmark-comparison-2026-07-15-128-byte-slab.md`](benchmark-comparison-2026-07-15-128-byte-slab.md)
with its raw TSV beside it. Cross-session comparisons to older published matrices are descriptive only;
this exact-parent run is the causal evidence for the layout change.
