# Exact-parent performance A/B — representative_strong_identity_collections (single, 1 lane(s))

- parent: `7da3715a85bdf7dd0bac9f5d0d399f6448f2bb40`
- candidate: `c797973a80c8ba845a803eb93981ef94d5f4d54a`
- zig-gc: `89b6652c81ba892119b7b9ce3b0d07fc78a009ff`
- zig-regex: `719673318b0c6250898d7ced3603876c148e370b`
- host class: `diagnostic`
- material-change categories: `cpu_work`, `cache_traffic`
- sampling: 7 order-balanced pairs; no discarded samples
- timed boundary: one invocation in a persistent context after ten reduced-work warmups

| parent median | candidate median | candidate / parent | parent RSD | candidate RSD | assessment |
| ---: | ---: | ---: | ---: | ---: | --- |
| 166.211 ms | 142.937 ms | 0.860x | 5.47% | 12.37% | `diagnostic_only` |

| efficiency metric | parent median | candidate median | candidate / parent | parent RSD | candidate RSD |
| --- | ---: | ---: | ---: | ---: | ---: |
| `instructions` | 1275716161 | 789710149 | 0.6190x | 0.17% | 0.26% |
| `cycles` | 602730079 | 509035579 | 0.8445x | 2.48% | 3.57% |
| `energy_joules` | 0.493261142 | 0.379807648 | 0.7700x | 2.03% | 2.18% |

Thermal states: `nominal->nominal`. Unmet category metrics: `cache_misses`. Efficiency evidence: `blocked_or_diagnostic`.

All input identities and checksums matched. Missing attribution values are encoded as unavailable with a reason, never as zero.
