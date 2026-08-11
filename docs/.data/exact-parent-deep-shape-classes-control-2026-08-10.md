# Exact-parent performance A/B — representative_classes (single, 1 lane(s))

- parent: `8592a7dc844d4ac1911263cdd9c6b938a4d739e7`
- candidate: `7666c5f142abf568cfaf4d7ffdce55a6e4c7e4f3`
- zig-gc: `89b6652c81ba892119b7b9ce3b0d07fc78a009ff`
- zig-regex: `719673318b0c6250898d7ced3603876c148e370b`
- host class: `diagnostic`
- material-change categories: `cpu_work`
- sampling: 7 order-balanced pairs; no discarded samples
- timed boundary: one scored eight-job shallow class construction and monomorphic property/call workload

| parent median | candidate median | candidate / parent | parent RSD | candidate RSD | assessment |
| ---: | ---: | ---: | ---: | ---: | --- |
| 75.823 ms | 76.027 ms | 1.003x | 4.58% | 5.42% | `diagnostic_only` |

| memory metric | parent median | candidate median | candidate / parent | parent RSD | candidate RSD |
| --- | ---: | ---: | ---: | ---: | ---: |
| `peak_rss_bytes` | 18120704 | 18104320 | 0.9991x | 0.09% | 0.17% |

| efficiency metric | parent median | candidate median | candidate / parent | parent RSD | candidate RSD |
| --- | ---: | ---: | ---: | ---: | ---: |
| `instructions` | 1455455574 | 1471784988 | 1.0112x | 3.45% | 3.43% |
| `cycles` | 262798280 | 266477457 | 1.0140x | 3.45% | 4.14% |
| `energy_joules` | 0.341473277 | 0.346839095 | 1.0157x | 4.41% | 4.55% |

Thermal states: `nominal->nominal`. Unmet category metrics: none. Efficiency evidence: `stable`.

All input identities and checksums matched. Missing attribution values are encoded as unavailable with a reason, never as zero.
