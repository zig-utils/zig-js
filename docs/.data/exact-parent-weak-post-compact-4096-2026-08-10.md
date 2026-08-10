# Exact-parent performance A/B — representative_weak_post_compact_4096 (single, 1 lane(s))

- parent: `bfc795fddf36240eab5124fcb04c5a670368c114`
- candidate: `6989099bb20f05ae19c3b0811b879bcc8439f414`
- zig-gc: `89b6652c81ba892119b7b9ce3b0d07fc78a009ff`
- zig-regex: `719673318b0c6250898d7ced3603876c148e370b`
- host class: `diagnostic`
- material-change categories: `cpu_work`
- sampling: 7 order-balanced pairs; no discarded samples
- timed boundary: one invocation in a persistent context after ten reduced-work warmups; post-compact rows force one successful moving full collection outside the timed boundary

| parent median | candidate median | candidate / parent | parent RSD | candidate RSD | assessment |
| ---: | ---: | ---: | ---: | ---: | --- |
| 12.694 ms | 5.316 ms | 0.419x | 3.04% | 6.76% | `diagnostic_only` |

| memory metric | parent median | candidate median | candidate / parent | parent RSD | candidate RSD |
| --- | ---: | ---: | ---: | ---: | ---: |
| `peak_rss_bytes` | 28803072 | 29048832 | 1.0085x | 0.13% | 0.09% |

| efficiency metric | parent median | candidate median | candidate / parent | parent RSD | candidate RSD |
| --- | ---: | ---: | ---: | ---: | ---: |
| `instructions` | 244052461 | 96371302 | 0.3949x | 0.91% | 0.93% |
| `cycles` | 45967625 | 19232645 | 0.4184x | 1.44% | 4.07% |
| `energy_joules` | 0.045003852 | 0.006905975 | 0.1535x | 10.13% | 109.13% |

Thermal states: `nominal->nominal`. Unmet category metrics: none. Efficiency evidence: `blocked_or_diagnostic`.

All input identities and checksums matched. Missing attribution values are encoded as unavailable with a reason, never as zero.
