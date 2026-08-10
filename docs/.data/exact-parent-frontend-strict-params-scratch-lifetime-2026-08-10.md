# Exact-parent performance A/B — representative_frontend_strict_params_4096 (single, 1 lane(s))

- parent: `a5bb209a9488a6eaaf4f9473f6214808519bf151`
- candidate: `e11bec9ce7da3048e884feb5aaf66e6fb947d324`
- zig-gc: `89b6652c81ba892119b7b9ce3b0d07fc78a009ff`
- zig-regex: `719673318b0c6250898d7ced3603876c148e370b`
- host class: `diagnostic`
- material-change categories: `cpu_work`, `cache_traffic`
- sampling: 7 order-balanced pairs; no discarded samples
- timed boundary: one eval parse-and-compile invocation in a persistent context after ten reduced-work warmups

| parent median | candidate median | candidate / parent | parent RSD | candidate RSD | assessment |
| ---: | ---: | ---: | ---: | ---: | --- |
| 1.598 ms | 1.574 ms | 0.984x | 4.42% | 10.69% | `diagnostic_only` |

| efficiency metric | parent median | candidate median | candidate / parent | parent RSD | candidate RSD |
| --- | ---: | ---: | ---: | ---: | ---: |
| `instructions` | 21010191 | 20943742 | 0.9968x | 0.42% | 0.45% |
| `cycles` | 5850200 | 5709596 | 0.9760x | 2.27% | 7.86% |
| `energy_joules` | 0 | 0 | NaNx | 264.58% | 171.46% |

Thermal states: `nominal->nominal`. Unmet category metrics: `cache_misses`. Efficiency evidence: `blocked_or_diagnostic`.

All input identities and checksums matched. Missing attribution values are encoded as unavailable with a reason, never as zero.
