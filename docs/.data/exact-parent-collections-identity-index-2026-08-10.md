# Exact-parent performance A/B — representative_collections (single, 1 lane(s))

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
| 323.005 ms | 330.176 ms | 1.022x | 7.76% | 1.69% | `diagnostic_only` |

| efficiency metric | parent median | candidate median | candidate / parent | parent RSD | candidate RSD |
| --- | ---: | ---: | ---: | ---: | ---: |
| `instructions` | 5316279255 | 5397992314 | 1.0154x | 0.09% | 0.03% |
| `cycles` | 1129241477 | 1145523057 | 1.0144x | 3.10% | 0.71% |
| `energy_joules` | 1.369328624 | 1.385047003 | 1.0115x | 1.61% | 0.83% |

Thermal states: `nominal->nominal`. Unmet category metrics: `cache_misses`. Efficiency evidence: `blocked_or_diagnostic`.

All input identities and checksums matched. Missing attribution values are encoded as unavailable with a reason, never as zero.
