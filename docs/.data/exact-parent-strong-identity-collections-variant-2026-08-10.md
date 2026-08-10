# Exact-parent performance A/B — representative_strong_identity_collections_variant (single, 1 lane(s))

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
| 135.400 ms | 110.298 ms | 0.815x | 2.28% | 1.95% | `diagnostic_only` |

| efficiency metric | parent median | candidate median | candidate / parent | parent RSD | candidate RSD |
| --- | ---: | ---: | ---: | ---: | ---: |
| `instructions` | 1276164575 | 789528541 | 0.6187x | 0.05% | 0.02% |
| `cycles` | 494315283 | 401324019 | 0.8119x | 0.94% | 0.49% |
| `energy_joules` | 0.435436522 | 0.316718653 | 0.7274x | 1.34% | 2.56% |

Thermal states: `nominal->nominal`. Unmet category metrics: `cache_misses`. Efficiency evidence: `blocked_or_diagnostic`.

All input identities and checksums matched. Missing attribution values are encoded as unavailable with a reason, never as zero.
