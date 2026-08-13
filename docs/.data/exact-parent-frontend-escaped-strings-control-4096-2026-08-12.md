# Exact-parent performance A/B — representative_frontend_strings_4096 (single, 1 lane(s))

- parent: `44d584817521be0c8011c5f09b29a87cadab3ff9`
- candidate: `3ca764e2867e891bcd4158213f2769aac217e732`
- zig-gc: `89b6652c81ba892119b7b9ce3b0d07fc78a009ff`
- zig-regex: `719673318b0c6250898d7ced3603876c148e370b`
- host class: `diagnostic`
- material-change categories: `cpu_work`
- sampling: 7 order-balanced pairs; no discarded samples
- timed boundary: two hundred parser-only parse and exact decoded-string validation jobs over one preconstructed 4,096-literal unescaped-string control source after ten 20-job warmups; allocation counters are an untimed exact-work replay

| parent median | candidate median | candidate / parent | parent RSD | candidate RSD | assessment |
| ---: | ---: | ---: | ---: | ---: | --- |
| 97.554 ms | 89.744 ms | 0.920x | 36.88% | 12.30% | `diagnostic_only` |

| memory/allocation metric | parent median | candidate median | candidate / parent | parent RSD | candidate RSD |
| --- | ---: | ---: | ---: | ---: | ---: |
| `peak_rss_bytes` | 10452992 | 10469376 | 1.0016x | 0.23% | 0.25% |
| `allocations` | 826600 | 826600 | 1.0000x | 0.00% | 0.00% |
| `allocated_bytes` | 435900800 | 435900800 | 1.0000x | 0.00% | 0.00% |

| efficiency metric | parent median | candidate median | candidate / parent | parent RSD | candidate RSD |
| --- | ---: | ---: | ---: | ---: | ---: |
| `instructions` | 1447116114 | 1358992254 | 0.9391x | 0.72% | 0.28% |
| `cycles` | 257790514 | 250675025 | 0.9724x | 14.01% | 6.20% |
| `energy_joules` | 0.26502556 | 0.275670839 | 1.0402x | 17.09% | 6.85% |

Thermal states: `nominal->nominal`. Unmet category metrics: none. Efficiency evidence: `blocked_or_diagnostic`.

All input identities and checksums matched. Missing attribution values are encoded as unavailable with a reason, never as zero.
