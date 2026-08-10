# Exact-parent performance A/B — representative_weak_post_compact_2048 (single, 1 lane(s))

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
| 4.301 ms | 2.559 ms | 0.595x | 2.43% | 2.24% | `diagnostic_only` |

| memory metric | parent median | candidate median | candidate / parent | parent RSD | candidate RSD |
| --- | ---: | ---: | ---: | ---: | ---: |
| `peak_rss_bytes` | 22593536 | 22773760 | 1.0080x | 0.06% | 0.19% |

| efficiency metric | parent median | candidate median | candidate / parent | parent RSD | candidate RSD |
| --- | ---: | ---: | ---: | ---: | ---: |
| `instructions` | 84581712 | 47759506 | 0.5647x | 0.94% | 1.98% |
| `cycles` | 15752080 | 9508734 | 0.6036x | 1.05% | 1.88% |
| `energy_joules` | 0 | 0 | NaNx | 264.58% | NaN% |

Thermal states: `nominal->nominal`. Unmet category metrics: none. Efficiency evidence: `blocked_or_diagnostic`.

All input identities and checksums matched. Missing attribution values are encoded as unavailable with a reason, never as zero.
