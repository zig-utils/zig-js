# Exact-parent performance A/B — representative_date_setter_1024 (single, 1 lane(s))

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
| 1.958 ms | 1.892 ms | 0.967x | 3.52% | 5.10% | `diagnostic_only` |

| memory metric | parent median | candidate median | candidate / parent | parent RSD | candidate RSD |
| --- | ---: | ---: | ---: | ---: | ---: |
| `peak_rss_bytes` | 18251776 | 17940480 | 0.9829x | 0.13% | 0.13% |

| efficiency metric | parent median | candidate median | candidate / parent | parent RSD | candidate RSD |
| --- | ---: | ---: | ---: | ---: | ---: |
| `instructions` | 40079715 | 39699537 | 0.9905x | 2.28% | 1.07% |
| `cycles` | 7173158 | 6962926 | 0.9707x | 2.30% | 2.02% |
| `energy_joules` | 0 | 0 | NaNx | NaN% | NaN% |

Thermal states: `nominal->nominal`. Unmet category metrics: none. Efficiency evidence: `blocked_or_diagnostic`.

All input identities and checksums matched. Missing attribution values are encoded as unavailable with a reason, never as zero.
