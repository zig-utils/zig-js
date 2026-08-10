# Exact-parent performance A/B — representative_collections_variant (single, 1 lane(s))

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
| 343.618 ms | 382.713 ms | 1.114x | 10.17% | 5.09% | `diagnostic_only` |

| efficiency metric | parent median | candidate median | candidate / parent | parent RSD | candidate RSD |
| --- | ---: | ---: | ---: | ---: | ---: |
| `instructions` | 5493450758 | 5621116059 | 1.0232x | 0.16% | 0.05% |
| `cycles` | 1189357716 | 1282531937 | 1.0783x | 5.50% | 3.02% |
| `energy_joules` | 1.435689526 | 1.481489216 | 1.0319x | 2.33% | 1.43% |

Thermal states: `nominal->nominal`. Unmet category metrics: `cache_misses`. Efficiency evidence: `blocked_or_diagnostic`.

All input identities and checksums matched. Missing attribution values are encoded as unavailable with a reason, never as zero.
