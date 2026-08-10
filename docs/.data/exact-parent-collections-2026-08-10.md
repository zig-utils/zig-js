# Exact-parent performance A/B — representative_collections (single, 1 lane(s))

- parent: `b09f9a552984a7d9a45e305652d00f7c38331388`
- candidate: `3c2b69fd1c2a69e1cd51025194ae28392ca62d57`
- zig-gc: `89b6652c81ba892119b7b9ce3b0d07fc78a009ff`
- zig-regex: `719673318b0c6250898d7ced3603876c148e370b`
- host class: `diagnostic`
- material-change categories: `cpu_work`, `cache_traffic`
- sampling: 7 order-balanced pairs; no discarded samples
- timed boundary: one invocation in a persistent context after ten reduced-work warmups

| parent median | candidate median | candidate / parent | parent RSD | candidate RSD | assessment |
| ---: | ---: | ---: | ---: | ---: | --- |
| 312.358 ms | 327.110 ms | 1.047x | 4.20% | 0.82% | `diagnostic_only` |

| efficiency metric | parent median | candidate median | candidate / parent | parent RSD | candidate RSD |
| --- | ---: | ---: | ---: | ---: | ---: |
| `instructions` | 5398138984 | 5523280879 | 1.0232x | 0.07% | 0.02% |
| `cycles` | 1119024102 | 1165805729 | 1.0418x | 2.08% | 0.39% |
| `energy_joules` | 1.402798472 | 1.447920701 | 1.0322x | 0.80% | 0.60% |

Thermal states: `nominal->nominal`. Unmet category metrics: `cache_misses`. Efficiency evidence: `blocked_or_diagnostic`.

All input identities and checksums matched. Missing attribution values are encoded as unavailable with a reason, never as zero.
