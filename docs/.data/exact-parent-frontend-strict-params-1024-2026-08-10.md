# Exact-parent performance A/B — representative_frontend_strict_params_1024 (single, 1 lane(s))

- parent: `ca7a2bf342c88f2f7660936932d19650ef2fe2bf`
- candidate: `a5bb209a9488a6eaaf4f9473f6214808519bf151`
- zig-gc: `89b6652c81ba892119b7b9ce3b0d07fc78a009ff`
- zig-regex: `719673318b0c6250898d7ced3603876c148e370b`
- host class: `diagnostic`
- material-change categories: `cpu_work`, `cache_traffic`
- sampling: 7 order-balanced pairs; no discarded samples
- timed boundary: one eval parse-and-compile invocation in a persistent context after ten reduced-work warmups

| parent median | candidate median | candidate / parent | parent RSD | candidate RSD | assessment |
| ---: | ---: | ---: | ---: | ---: | --- |
| 1.152 ms | 0.407 ms | 0.354x | 15.09% | 13.33% | `diagnostic_only` |

| efficiency metric | parent median | candidate median | candidate / parent | parent RSD | candidate RSD |
| --- | ---: | ---: | ---: | ---: | ---: |
| `instructions` | 23562021 | 5252162 | 0.2229x | 0.05% | 0.06% |
| `cycles` | 4097097 | 1513440 | 0.3694x | 16.46% | 13.56% |
| `energy_joules` | 0 | 0 | NaNx | NaN% | NaN% |

Thermal states: `nominal->nominal`. Unmet category metrics: `cache_misses`. Efficiency evidence: `blocked_or_diagnostic`.

All input identities and checksums matched. Missing attribution values are encoded as unavailable with a reason, never as zero.
