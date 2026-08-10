# Exact-parent performance A/B — representative_weak_post_compact_4096 (single_observed, 1 lane(s))

- parent: `bfc795fddf36240eab5124fcb04c5a670368c114`
- candidate: `6989099bb20f05ae19c3b0811b879bcc8439f414`
- zig-gc: `89b6652c81ba892119b7b9ce3b0d07fc78a009ff`
- zig-regex: `719673318b0c6250898d7ced3603876c148e370b`
- host class: `diagnostic`
- material-change categories: `cpu_work`
- sampling: 7 order-balanced pairs; no discarded samples
- timed boundary: one observed invocation after ten observed reduced-work warmups; one successful moving full collection occurs outside the timed boundary; retained RSS is sampled after invocation while the context remains live

| parent median | candidate median | candidate / parent | parent RSD | candidate RSD | assessment |
| ---: | ---: | ---: | ---: | ---: | --- |
| 12.883 ms | 5.308 ms | 0.412x | 2.74% | 6.46% | `diagnostic_only` |

| memory metric | parent median | candidate median | candidate / parent | parent RSD | candidate RSD |
| --- | ---: | ---: | ---: | ---: | ---: |
| `peak_rss_bytes` | 28803072 | 29065216 | 1.0091x | 0.13% | 0.24% |
| `retained_rss_bytes` | 28753920 | 29016064 | 1.0091x | 0.14% | 0.24% |

| efficiency metric | parent median | candidate median | candidate / parent | parent RSD | candidate RSD |
| --- | ---: | ---: | ---: | ---: | ---: |
| `instructions` | 242794799 | 95418399 | 0.3930x | 0.69% | 1.22% |
| `cycles` | 46612384 | 19051122 | 0.4087x | 0.99% | 4.16% |
| `energy_joules` | 0.044538299 | 0.004160913 | 0.0934x | 11.70% | 123.01% |

Thermal states: `nominal->nominal`. Unmet category metrics: none. Efficiency evidence: `blocked_or_diagnostic`.

All input identities and checksums matched. Missing attribution values are encoded as unavailable with a reason, never as zero.
