# Exact-parent performance A/B — properties (single, 1 lane(s))

- parent: `00848706d4b24487c9a2caf83e12fe7a1b04695f`
- candidate: `253b5b079d8b3698f086e403a86d6052d0eacecd`
- zig-gc: `89b6652c81ba892119b7b9ce3b0d07fc78a009ff`
- zig-regex: `719673318b0c6250898d7ced3603876c148e370b`
- host class: `diagnostic`
- material-change categories: `cpu_work`
- sampling: 7 order-balanced pairs; no discarded samples
- timed boundary: 25,000 ordinary named-property get/set iterations over one four-property object after ten warmup invocations

| parent median | candidate median | candidate / parent | parent RSD | candidate RSD | assessment |
| ---: | ---: | ---: | ---: | ---: | --- |
| 0.383 ms | 0.376 ms | 0.981x | 2.75% | 1.69% | `diagnostic_only` |

| memory metric | parent median | candidate median | candidate / parent | parent RSD | candidate RSD |
| --- | ---: | ---: | ---: | ---: | ---: |
| `peak_rss_bytes` | 13385728 | 13205504 | 0.9865x | 0.08% | 0.10% |

| efficiency metric | parent median | candidate median | candidate / parent | parent RSD | candidate RSD |
| --- | ---: | ---: | ---: | ---: | ---: |
| `instructions` | 4060947 | 4065870 | 1.0012x | 1.27% | 1.46% |
| `cycles` | 1405898 | 1406379 | 1.0003x | 2.96% | 1.97% |
| `energy_joules` | 0 | 0 | NaNx | 264.58% | 264.58% |

Thermal states: `nominal->nominal`. Unmet category metrics: none. Efficiency evidence: `blocked_or_diagnostic`.

All input identities and checksums matched. Missing attribution values are encoded as unavailable with a reason, never as zero.
