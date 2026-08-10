# Exact-parent performance A/B — representative_collections (single, 1 lane(s))

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
| 331.555 ms | 330.409 ms | 0.997x | 2.29% | 2.51% | `diagnostic_only` |

| efficiency metric | parent median | candidate median | candidate / parent | parent RSD | candidate RSD |
| --- | ---: | ---: | ---: | ---: | ---: |
| `instructions` | 5524724241 | 5514081390 | 0.9981x | 0.02% | 0.04% |
| `cycles` | 1179604278 | 1168728425 | 0.9908x | 0.32% | 1.12% |
| `energy_joules` | 1.480721015 | 1.452032982 | 0.9806x | 0.48% | 1.00% |

Thermal states: `nominal->nominal`. Unmet category metrics: `cache_misses`. Efficiency evidence: `blocked_or_diagnostic`.

All input identities and checksums matched. Missing attribution values are encoded as unavailable with a reason, never as zero.
