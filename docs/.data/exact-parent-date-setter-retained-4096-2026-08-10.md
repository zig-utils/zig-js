# Exact-parent performance A/B — representative_date_setter_4096 (single_observed, 1 lane(s))

- parent: `e2348ffdd64aa999f3d5872607a91f397414921f`
- candidate: `ddaae8a53005610ee646d3d3f9571bdc5f4073b3`
- zig-gc: `89b6652c81ba892119b7b9ce3b0d07fc78a009ff`
- zig-regex: `719673318b0c6250898d7ced3603876c148e370b`
- host class: `diagnostic`
- material-change categories: `cpu_work`
- sampling: 7 order-balanced pairs; no discarded samples
- timed boundary: one observed invocation after ten observed reduced-work warmups; retained RSS is sampled after invocation while the context remains live

| parent median | candidate median | candidate / parent | parent RSD | candidate RSD | assessment |
| ---: | ---: | ---: | ---: | ---: | --- |
| 7.521 ms | 7.519 ms | 1.000x | 2.21% | 4.70% | `diagnostic_only` |

| memory metric | parent median | candidate median | candidate / parent | parent RSD | candidate RSD |
| --- | ---: | ---: | ---: | ---: | ---: |
| `peak_rss_bytes` | 25313280 | 23969792 | 0.9469x | 0.10% | 0.11% |
| `retained_rss_bytes` | 25247744 | 23904256 | 0.9468x | 0.10% | 0.11% |

| efficiency metric | parent median | candidate median | candidate / parent | parent RSD | candidate RSD |
| --- | ---: | ---: | ---: | ---: | ---: |
| `instructions` | 158812125 | 157464031 | 0.9915x | 1.27% | 3.10% |
| `cycles` | 28101975 | 27936797 | 0.9941x | 1.10% | 2.98% |
| `energy_joules` | 0 | 0 | NaNx | 171.07% | 155.42% |

Thermal states: `nominal->nominal`. Unmet category metrics: none. Efficiency evidence: `blocked_or_diagnostic`.

All input identities and checksums matched. Missing attribution values are encoded as unavailable with a reason, never as zero.
