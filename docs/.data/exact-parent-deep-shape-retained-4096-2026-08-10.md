# Exact-parent performance A/B — representative_array_like_4096 (single_observed, 1 lane(s))

- parent: `8592a7dc844d4ac1911263cdd9c6b938a4d739e7`
- candidate: `7666c5f142abf568cfaf4d7ffdce55a6e4c7e4f3`
- zig-gc: `89b6652c81ba892119b7b9ce3b0d07fc78a009ff`
- zig-regex: `719673318b0c6250898d7ced3603876c148e370b`
- host class: `diagnostic`
- material-change categories: `cpu_work`
- sampling: 7 order-balanced pairs; no discarded samples
- timed boundary: prebuilt 4,096-property plain array-like; one observed 12-job computed Has/Get traversal plus post-invocation live RSS snapshot

| parent median | candidate median | candidate / parent | parent RSD | candidate RSD | assessment |
| ---: | ---: | ---: | ---: | ---: | --- |
| 2219.373 ms | 82.365 ms | 0.037x | 14.46% | 23.37% | `diagnostic_only` |

| memory metric | parent median | candidate median | candidate / parent | parent RSD | candidate RSD |
| --- | ---: | ---: | ---: | ---: | ---: |
| `peak_rss_bytes` | 38371328 | 40550400 | 1.0568x | 11.03% | 0.16% |
| `retained_rss_bytes` | 38322176 | 40501248 | 1.0569x | 20.32% | 0.16% |

| efficiency metric | parent median | candidate median | candidate / parent | parent RSD | candidate RSD |
| --- | ---: | ---: | ---: | ---: | ---: |
| `instructions` | 13511426411 | 1240438328 | 0.0918x | 0.25% | 2.91% |
| `cycles` | 7260499911 | 276197562 | 0.0380x | 5.97% | 10.98% |
| `energy_joules` | 5.097808516 | 0.288448573 | 0.0566x | 2.54% | 8.05% |

Thermal states: `nominal->nominal`. Unmet category metrics: none. Efficiency evidence: `blocked_or_diagnostic`.

All input identities and checksums matched. Missing attribution values are encoded as unavailable with a reason, never as zero.
