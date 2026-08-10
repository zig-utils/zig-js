# Exact-parent performance A/B — representative_date_setter_4096 (single, 1 lane(s))

- parent: `e2348ffdd64aa999f3d5872607a91f397414921f`
- candidate: `ddaae8a53005610ee646d3d3f9571bdc5f4073b3`
- zig-gc: `89b6652c81ba892119b7b9ce3b0d07fc78a009ff`
- zig-regex: `719673318b0c6250898d7ced3603876c148e370b`
- host class: `diagnostic`
- material-change categories: `cpu_work`
- sampling: 7 order-balanced pairs; no discarded samples
- timed boundary: one invocation in a persistent context after ten reduced-work warmups

| parent median | candidate median | candidate / parent | parent RSD | candidate RSD | assessment |
| ---: | ---: | ---: | ---: | ---: | --- |
| 8.059 ms | 7.842 ms | 0.973x | 6.07% | 5.15% | `diagnostic_only` |

| memory metric | parent median | candidate median | candidate / parent | parent RSD | candidate RSD |
| --- | ---: | ---: | ---: | ---: | ---: |
| `peak_rss_bytes` | 25329664 | 23920640 | 0.9444x | 0.11% | 0.15% |

| efficiency metric | parent median | candidate median | candidate / parent | parent RSD | candidate RSD |
| --- | ---: | ---: | ---: | ---: | ---: |
| `instructions` | 158209245 | 159248559 | 1.0066x | 1.19% | 1.26% |
| `cycles` | 27876856 | 28428260 | 1.0198x | 3.42% | 2.86% |
| `energy_joules` | 0.024465558 | 0.002835572 | 0.1159x | 82.42% | 126.59% |

Thermal states: `nominal->nominal`. Unmet category metrics: none. Efficiency evidence: `blocked_or_diagnostic`.

All input identities and checksums matched. Missing attribution values are encoded as unavailable with a reason, never as zero.
