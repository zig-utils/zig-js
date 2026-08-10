# Exact-parent performance A/B — representative_named_delete_readd_4096 (single_observed, 1 lane(s))

- parent: `00848706d4b24487c9a2caf83e12fe7a1b04695f`
- candidate: `253b5b079d8b3698f086e403a86d6052d0eacecd`
- zig-gc: `89b6652c81ba892119b7b9ce3b0d07fc78a009ff`
- zig-regex: `719673318b0c6250898d7ced3603876c148e370b`
- host class: `diagnostic`
- material-change categories: `cpu_work`
- sampling: 7 order-balanced pairs; no discarded samples
- timed boundary: one distinct middle-key delete and non-default descriptor re-add over one prebuilt 4096-property object after ten warmup invocations; live retained RSS sampled after invocation before Context teardown

| parent median | candidate median | candidate / parent | parent RSD | candidate RSD | assessment |
| ---: | ---: | ---: | ---: | ---: | --- |
| 87.255 ms | 0.779 ms | 0.009x | 1.16% | 5.29% | `diagnostic_only` |

| memory metric | parent median | candidate median | candidate / parent | parent RSD | candidate RSD |
| --- | ---: | ---: | ---: | ---: | ---: |
| `peak_rss_bytes` | 45219840 | 27328512 | 0.6043x | 0.05% | 0.15% |
| `retained_rss_bytes` | 45154304 | 27262976 | 0.6038x | 0.05% | 0.16% |

| efficiency metric | parent median | candidate median | candidate / parent | parent RSD | candidate RSD |
| --- | ---: | ---: | ---: | ---: | ---: |
| `instructions` | 531999831 | 11777928 | 0.0221x | 0.04% | 0.67% |
| `cycles` | 329215918 | 2952070 | 0.0090x | 0.36% | 5.08% |
| `energy_joules` | 0.215704516 | 0 | 0.0000x | 1.03% | NaN% |

Thermal states: `nominal->nominal`. Unmet category metrics: none. Efficiency evidence: `blocked_or_diagnostic`.

All input identities and checksums matched. Missing attribution values are encoded as unavailable with a reason, never as zero.
