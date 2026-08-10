# Exact-parent performance A/B — representative_date_settime_control_4096 (single, 1 lane(s))

- parent: `e2348ffdd64aa999f3d5872607a91f397414921f`
- candidate: `ddaae8a53005610ee646d3d3f9571bdc5f4073b3`
- zig-gc: `89b6652c81ba892119b7b9ce3b0d07fc78a009ff`
- zig-regex: `719673318b0c6250898d7ced3603876c148e370b`
- host class: `diagnostic`
- material-change categories: `cpu_work`
- sampling: 7 order-balanced pairs; no discarded samples
- timed boundary: one invocation in a persistent context after ten reduced-work warmups; setTime control performs identical timestamp mutation without component coercion storage

| parent median | candidate median | candidate / parent | parent RSD | candidate RSD | assessment |
| ---: | ---: | ---: | ---: | ---: | --- |
| 8.252 ms | 8.116 ms | 0.984x | 2.83% | 27.99% | `diagnostic_only` |

| memory metric | parent median | candidate median | candidate / parent | parent RSD | candidate RSD |
| --- | ---: | ---: | ---: | ---: | ---: |
| `peak_rss_bytes` | 22740992 | 22822912 | 1.0036x | 0.16% | 0.10% |

| efficiency metric | parent median | candidate median | candidate / parent | parent RSD | candidate RSD |
| --- | ---: | ---: | ---: | ---: | ---: |
| `instructions` | 169129732 | 169130657 | 1.0000x | 1.37% | 1.44% |
| `cycles` | 29903012 | 29447976 | 0.9848x | 1.15% | 13.67% |
| `energy_joules` | 0.010103931 | 0.019668155 | 1.9466x | 116.87% | 95.87% |

Thermal states: `nominal->nominal`. Unmet category metrics: none. Efficiency evidence: `blocked_or_diagnostic`.

All input identities and checksums matched. Missing attribution values are encoded as unavailable with a reason, never as zero.
