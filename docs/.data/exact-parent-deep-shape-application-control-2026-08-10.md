# Exact-parent performance A/B — representative_application_mix (single, 1 lane(s))

- parent: `8592a7dc844d4ac1911263cdd9c6b938a4d739e7`
- candidate: `7666c5f142abf568cfaf4d7ffdce55a6e4c7e4f3`
- zig-gc: `89b6652c81ba892119b7b9ce3b0d07fc78a009ff`
- zig-regex: `719673318b0c6250898d7ced3603876c148e370b`
- host class: `diagnostic`
- material-change categories: `cpu_work`
- sampling: 7 order-balanced pairs; no discarded samples
- timed boundary: one scored 50-job mixed shallow object, JSON, RegExp, Map, and Array workload

| parent median | candidate median | candidate / parent | parent RSD | candidate RSD | assessment |
| ---: | ---: | ---: | ---: | ---: | --- |
| 70.157 ms | 68.288 ms | 0.973x | 2.92% | 3.75% | `diagnostic_only` |

| memory metric | parent median | candidate median | candidate / parent | parent RSD | candidate RSD |
| --- | ---: | ---: | ---: | ---: | ---: |
| `peak_rss_bytes` | 40304640 | 40419328 | 1.0028x | 0.16% | 0.13% |

| efficiency metric | parent median | candidate median | candidate / parent | parent RSD | candidate RSD |
| --- | ---: | ---: | ---: | ---: | ---: |
| `instructions` | 932356675 | 931692170 | 0.9993x | 1.92% | 2.10% |
| `cycles` | 237356241 | 233201176 | 0.9825x | 1.47% | 2.70% |
| `energy_joules` | 0.236685442 | 0.233717635 | 0.9875x | 2.87% | 3.35% |

Thermal states: `nominal->nominal`. Unmet category metrics: none. Efficiency evidence: `stable`.

All input identities and checksums matched. Missing attribution values are encoded as unavailable with a reason, never as zero.
