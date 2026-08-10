# Exact-parent performance A/B — representative_weak_post_compact_1024 (single, 1 lane(s))

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
| 1.696 ms | 1.254 ms | 0.739x | 2.47% | 1.99% | `diagnostic_only` |

| memory metric | parent median | candidate median | candidate / parent | parent RSD | candidate RSD |
| --- | ---: | ---: | ---: | ---: | ---: |
| `peak_rss_bytes` | 19415040 | 19562496 | 1.0076x | 0.12% | 0.22% |

| efficiency metric | parent median | candidate median | candidate / parent | parent RSD | candidate RSD |
| --- | ---: | ---: | ---: | ---: | ---: |
| `instructions` | 32873697 | 23860078 | 0.7258x | 1.11% | 1.38% |
| `cycles` | 6369409 | 4722527 | 0.7414x | 0.99% | 0.59% |
| `energy_joules` | 0 | 0 | NaNx | NaN% | NaN% |

Thermal states: `nominal->nominal`. Unmet category metrics: none. Efficiency evidence: `blocked_or_diagnostic`.

All input identities and checksums matched. Missing attribution values are encoded as unavailable with a reason, never as zero.
