# Exact-parent performance A/B — representative_json_reviver_source (single, 1 lane(s))

- parent: `7a842b3a3c710a8126b13635f86874508b516c82`
- candidate: `535d5cdad7fac3c72db787c4c5fa1005746d0593`
- zig-gc: `89b6652c81ba892119b7b9ce3b0d07fc78a009ff`
- zig-regex: `719673318b0c6250898d7ced3603876c148e370b`
- host class: `diagnostic`
- material-change categories: `cpu_work`, `cache_traffic`
- sampling: 7 order-balanced pairs; no discarded samples
- timed boundary: one invocation in a persistent context after ten reduced-work warmups

| parent median | candidate median | candidate / parent | parent RSD | candidate RSD | assessment |
| ---: | ---: | ---: | ---: | ---: | --- |
| 238.862 ms | 44.800 ms | 0.188x | 0.86% | 3.28% | `diagnostic_only` |

| efficiency metric | parent median | candidate median | candidate / parent | parent RSD | candidate RSD |
| --- | ---: | ---: | ---: | ---: | ---: |
| `instructions` | 5955794387 | 743052431 | 0.1248x | 0.06% | 0.05% |
| `cycles` | 870164333 | 164490201 | 0.1890x | 0.26% | 1.98% |
| `energy_joules` | 1.253325009 | 0.179615999 | 0.1433x | 0.84% | 4.17% |

Thermal states: `nominal->nominal`. Unmet category metrics: `cache_misses`. Efficiency evidence: `blocked_or_diagnostic`.

All input identities and checksums matched. Missing attribution values are encoded as unavailable with a reason, never as zero.
