# Exact-parent performance A/B — representative_collections_variant (single, 1 lane(s))

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
| 362.109 ms | 366.490 ms | 1.012x | 3.50% | 51.09% | `diagnostic_only` |

| efficiency metric | parent median | candidate median | candidate / parent | parent RSD | candidate RSD |
| --- | ---: | ---: | ---: | ---: | ---: |
| `instructions` | 5617802329 | 5620149495 | 1.0004x | 0.04% | 0.22% |
| `cycles` | 1251178868 | 1260843534 | 1.0077x | 1.98% | 9.65% |
| `energy_joules` | 1.496519112 | 1.496985511 | 1.0003x | 1.34% | 7.30% |

Thermal states: `nominal->nominal`. Unmet category metrics: `cache_misses`. Efficiency evidence: `blocked_or_diagnostic`.

All input identities and checksums matched. Missing attribution values are encoded as unavailable with a reason, never as zero.
