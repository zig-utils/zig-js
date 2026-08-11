# Exact-parent performance A/B — representative_array_like_4096 (single, 1 lane(s))

- parent: `8592a7dc844d4ac1911263cdd9c6b938a4d739e7`
- candidate: `7666c5f142abf568cfaf4d7ffdce55a6e4c7e4f3`
- zig-gc: `89b6652c81ba892119b7b9ce3b0d07fc78a009ff`
- zig-regex: `719673318b0c6250898d7ced3603876c148e370b`
- host class: `diagnostic`
- material-change categories: `cpu_work`
- sampling: 7 order-balanced pairs; no discarded samples
- timed boundary: prebuilt plain array-like; one scored 12-job computed Has/Get traversal

| parent median | candidate median | candidate / parent | parent RSD | candidate RSD | assessment |
| ---: | ---: | ---: | ---: | ---: | --- |
| 2075.056 ms | 76.514 ms | 0.037x | 9.78% | 74.08% | `diagnostic_only` |

| memory metric | parent median | candidate median | candidate / parent | parent RSD | candidate RSD |
| --- | ---: | ---: | ---: | ---: | ---: |
| `peak_rss_bytes` | 38469632 | 40583168 | 1.0549x | 8.35% | 0.11% |

| efficiency metric | parent median | candidate median | candidate / parent | parent RSD | candidate RSD |
| --- | ---: | ---: | ---: | ---: | ---: |
| `instructions` | 13448191148 | 1233065214 | 0.0917x | 0.39% | 3.57% |
| `cycles` | 7003301079 | 259370397 | 0.0370x | 5.36% | 13.37% |
| `energy_joules` | 5.040023133 | 0.294133827 | 0.0584x | 0.81% | 6.25% |

Thermal states: `nominal->nominal`. Unmet category metrics: none. Efficiency evidence: `blocked_or_diagnostic`.

All input identities and checksums matched. Missing attribution values are encoded as unavailable with a reason, never as zero.
