# Exact-parent performance A/B — representative_date_settime_control_4096 (single_observed, 1 lane(s))

- parent: `e2348ffdd64aa999f3d5872607a91f397414921f`
- candidate: `ddaae8a53005610ee646d3d3f9571bdc5f4073b3`
- zig-gc: `89b6652c81ba892119b7b9ce3b0d07fc78a009ff`
- zig-regex: `719673318b0c6250898d7ced3603876c148e370b`
- host class: `diagnostic`
- material-change categories: `cpu_work`
- sampling: 7 order-balanced pairs; no discarded samples
- timed boundary: one observed invocation after ten observed reduced-work warmups; retained RSS is sampled after the identical setTime control while the context remains live

| parent median | candidate median | candidate / parent | parent RSD | candidate RSD | assessment |
| ---: | ---: | ---: | ---: | ---: | --- |
| 7.867 ms | 7.978 ms | 1.014x | 0.90% | 1.27% | `diagnostic_only` |

| memory metric | parent median | candidate median | candidate / parent | parent RSD | candidate RSD |
| --- | ---: | ---: | ---: | ---: | ---: |
| `peak_rss_bytes` | 22773760 | 22872064 | 1.0043x | 0.09% | 0.14% |
| `retained_rss_bytes` | 22708224 | 22806528 | 1.0043x | 0.09% | 0.14% |

| efficiency metric | parent median | candidate median | candidate / parent | parent RSD | candidate RSD |
| --- | ---: | ---: | ---: | ---: | ---: |
| `instructions` | 168278058 | 169068125 | 1.0047x | 1.06% | 2.81% |
| `cycles` | 29654683 | 29508113 | 0.9951x | 1.10% | 1.56% |
| `energy_joules` | 0 | 0 | NaNx | NaN% | NaN% |

Thermal states: `nominal->nominal`. Unmet category metrics: none. Efficiency evidence: `blocked_or_diagnostic`.

All input identities and checksums matched. Missing attribution values are encoded as unavailable with a reason, never as zero.
