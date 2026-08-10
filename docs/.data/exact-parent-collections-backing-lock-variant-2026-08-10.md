# Exact-parent performance A/B — representative_collections_variant (single, 1 lane(s))

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
| 319.990 ms | 311.410 ms | 0.973x | 4.88% | 0.53% | `diagnostic_only` |

| efficiency metric | parent median | candidate median | candidate / parent | parent RSD | candidate RSD |
| --- | ---: | ---: | ---: | ---: | ---: |
| `instructions` | 5598514376 | 5507960925 | 0.9838x | 0.02% | 0.01% |
| `cycles` | 1177767000 | 1145590025 | 0.9727x | 1.69% | 0.41% |
| `energy_joules` | 1.469746715 | 1.423698499 | 0.9687x | 2.00% | 1.26% |

Thermal states: `nominal->nominal`. Unmet category metrics: `cache_misses`. Efficiency evidence: `blocked_or_diagnostic`.

All input identities and checksums matched. Missing attribution values are encoded as unavailable with a reason, never as zero.
