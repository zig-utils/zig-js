# Exact-parent performance A/B — representative_weak_lookup_control_4096 (single, 1 lane(s))

- parent: `bfc795fddf36240eab5124fcb04c5a670368c114`
- candidate: `6989099bb20f05ae19c3b0811b879bcc8439f414`
- zig-gc: `89b6652c81ba892119b7b9ce3b0d07fc78a009ff`
- zig-regex: `719673318b0c6250898d7ced3603876c148e370b`
- host class: `diagnostic`
- material-change categories: `cpu_work`
- sampling: 7 order-balanced pairs; no discarded samples
- timed boundary: one invocation in a persistent context after ten reduced-work warmups; ordinary no-movement control performs no forced collection

| parent median | candidate median | candidate / parent | parent RSD | candidate RSD | assessment |
| ---: | ---: | ---: | ---: | ---: | --- |
| 5.971 ms | 6.043 ms | 1.012x | 11.48% | 8.13% | `diagnostic_only` |

| memory metric | parent median | candidate median | candidate / parent | parent RSD | candidate RSD |
| --- | ---: | ---: | ---: | ---: | ---: |
| `peak_rss_bytes` | 28246016 | 28459008 | 1.0075x | 0.15% | 0.18% |

| efficiency metric | parent median | candidate median | candidate / parent | parent RSD | candidate RSD |
| --- | ---: | ---: | ---: | ---: | ---: |
| `instructions` | 95947717 | 96794574 | 1.0088x | 1.49% | 0.90% |
| `cycles` | 20149264 | 20124141 | 0.9988x | 6.28% | 4.51% |
| `energy_joules` | 0.019432138 | 0.013845991 | 0.7125x | 30.41% | 81.34% |

Thermal states: `nominal->nominal`. Unmet category metrics: none. Efficiency evidence: `blocked_or_diagnostic`.

All input identities and checksums matched. Missing attribution values are encoded as unavailable with a reason, never as zero.
