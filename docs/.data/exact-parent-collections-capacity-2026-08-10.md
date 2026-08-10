# Exact-parent performance A/B — representative_collections (single, 1 lane(s))

- parent: `3c2b69fd1c2a69e1cd51025194ae28392ca62d57`
- candidate: `db6519ce91d0e690ec72d680aac3a0eebd0700ea`
- zig-gc: `89b6652c81ba892119b7b9ce3b0d07fc78a009ff`
- zig-regex: `719673318b0c6250898d7ced3603876c148e370b`
- host class: `diagnostic`
- material-change categories: `cpu_work`, `cache_traffic`
- sampling: 7 order-balanced pairs; no discarded samples
- timed boundary: one invocation in a persistent context after ten reduced-work warmups

| parent median | candidate median | candidate / parent | parent RSD | candidate RSD | assessment |
| ---: | ---: | ---: | ---: | ---: | --- |
| 335.323 ms | 328.543 ms | 0.980x | 5.87% | 8.73% | `diagnostic_only` |

| efficiency metric | parent median | candidate median | candidate / parent | parent RSD | candidate RSD |
| --- | ---: | ---: | ---: | ---: | ---: |
| `instructions` | 5524881817 | 5523669503 | 0.9998x | 0.08% | 0.09% |
| `cycles` | 1179628874 | 1172755268 | 0.9942x | 1.72% | 2.92% |
| `energy_joules` | 1.463989227 | 1.462142163 | 0.9987x | 0.57% | 1.92% |

Thermal states: `nominal->nominal`. Unmet category metrics: `cache_misses`. Efficiency evidence: `blocked_or_diagnostic`.

All input identities and checksums matched. Missing attribution values are encoded as unavailable with a reason, never as zero.
