# Exact-parent performance A/B — representative_named_delete_4096 (single_observed, 1 lane(s))

- parent: `00848706d4b24487c9a2caf83e12fe7a1b04695f`
- candidate: `253b5b079d8b3698f086e403a86d6052d0eacecd`
- zig-gc: `89b6652c81ba892119b7b9ce3b0d07fc78a009ff`
- zig-regex: `719673318b0c6250898d7ced3603876c148e370b`
- host class: `diagnostic`
- material-change categories: `cpu_work`
- sampling: 7 order-balanced pairs; no discarded samples
- timed boundary: one distinct middle-key delete over one prebuilt 4096-property object after ten warmup invocations; live retained RSS sampled after invocation before Context teardown

| parent median | candidate median | candidate / parent | parent RSD | candidate RSD | assessment |
| ---: | ---: | ---: | ---: | ---: | --- |
| 86.359 ms | 0.760 ms | 0.009x | 0.73% | 0.84% | `diagnostic_only` |

| memory metric | parent median | candidate median | candidate / parent | parent RSD | candidate RSD |
| --- | ---: | ---: | ---: | ---: | ---: |
| `peak_rss_bytes` | 45203456 | 27262976 | 0.6031x | 0.10% | 0.09% |
| `retained_rss_bytes` | 45137920 | 27197440 | 0.6025x | 0.10% | 0.09% |

| efficiency metric | parent median | candidate median | candidate / parent | parent RSD | candidate RSD |
| --- | ---: | ---: | ---: | ---: | ---: |
| `instructions` | 528829934 | 11602415 | 0.0219x | 0.00% | 0.11% |
| `cycles` | 325896895 | 2869758 | 0.0088x | 0.62% | 0.50% |
| `energy_joules` | 0.215486054 | 0 | 0.0000x | 0.63% | NaN% |

Thermal states: `nominal->nominal`. Unmet category metrics: none. Efficiency evidence: `blocked_or_diagnostic`.

All input identities and checksums matched. Missing attribution values are encoded as unavailable with a reason, never as zero.
