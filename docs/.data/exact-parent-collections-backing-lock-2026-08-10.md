# Exact-parent performance A/B — representative_collections (single, 1 lane(s))

- parent: `cbd4cb55c848fe8722aaeaf9df0fd780678a9210`
- candidate: `ae933649e19fdf18c77e158ecb8fe45eb49bafb7`
- zig-gc: `89b6652c81ba892119b7b9ce3b0d07fc78a009ff`
- zig-regex: `719673318b0c6250898d7ced3603876c148e370b`
- host class: `diagnostic`
- material-change categories: `cpu_work`, `cache_traffic`
- sampling: 7 order-balanced pairs; no discarded samples
- timed boundary: one invocation in a persistent context after ten reduced-work warmups

| parent median | candidate median | candidate / parent | parent RSD | candidate RSD | assessment |
| ---: | ---: | ---: | ---: | ---: | --- |
| 314.520 ms | 306.014 ms | 0.973x | 4.93% | 3.04% | `diagnostic_only` |

| efficiency metric | parent median | candidate median | candidate / parent | parent RSD | candidate RSD |
| --- | ---: | ---: | ---: | ---: | ---: |
| `instructions` | 5510844776 | 5420132074 | 0.9835x | 0.05% | 0.06% |
| `cycles` | 1150731122 | 1118756006 | 0.9722x | 1.59% | 1.30% |
| `energy_joules` | 1.44405372 | 1.399969118 | 0.9695x | 1.35% | 1.13% |

Thermal states: `nominal->nominal`. Unmet category metrics: `cache_misses`. Efficiency evidence: `blocked_or_diagnostic`.

All input identities and checksums matched. Missing attribution values are encoded as unavailable with a reason, never as zero.
