# Exact-parent performance A/B — representative_collections_variant (single, 1 lane(s))

- parent: `db6519ce91d0e690ec72d680aac3a0eebd0700ea`
- candidate: `cbd4cb55c848fe8722aaeaf9df0fd780678a9210`
- zig-gc: `89b6652c81ba892119b7b9ce3b0d07fc78a009ff`
- zig-regex: `719673318b0c6250898d7ced3603876c148e370b`
- host class: `diagnostic`
- material-change categories: `cpu_work`, `cache_traffic`
- sampling: 7 order-balanced pairs; no discarded samples
- timed boundary: one invocation in a persistent context after ten reduced-work warmups

| parent median | candidate median | candidate / parent | parent RSD | candidate RSD | assessment |
| ---: | ---: | ---: | ---: | ---: | --- |
| 329.888 ms | 324.577 ms | 0.984x | 1.10% | 2.61% | `diagnostic_only` |

| efficiency metric | parent median | candidate median | candidate / parent | parent RSD | candidate RSD |
| --- | ---: | ---: | ---: | ---: | ---: |
| `instructions` | 5611343148 | 5599030466 | 0.9978x | 0.01% | 0.04% |
| `cycles` | 1205918730 | 1187370575 | 0.9846x | 0.59% | 1.26% |
| `energy_joules` | 1.492941909 | 1.479570177 | 0.9910x | 0.49% | 0.82% |

Thermal states: `nominal->nominal`. Unmet category metrics: `cache_misses`. Efficiency evidence: `blocked_or_diagnostic`.

All input identities and checksums matched. Missing attribution values are encoded as unavailable with a reason, never as zero.
