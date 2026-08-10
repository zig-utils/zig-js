# Exact-parent performance A/B — representative_weak_lookup_control_4096 (single_observed, 1 lane(s))

- parent: `bfc795fddf36240eab5124fcb04c5a670368c114`
- candidate: `6989099bb20f05ae19c3b0811b879bcc8439f414`
- zig-gc: `89b6652c81ba892119b7b9ce3b0d07fc78a009ff`
- zig-regex: `719673318b0c6250898d7ced3603876c148e370b`
- host class: `diagnostic`
- material-change categories: `cpu_work`
- sampling: 7 order-balanced pairs; no discarded samples
- timed boundary: one observed invocation after ten observed reduced-work warmups; ordinary no-movement control performs no forced collection; retained RSS is sampled after invocation while the context remains live

| parent median | candidate median | candidate / parent | parent RSD | candidate RSD | assessment |
| ---: | ---: | ---: | ---: | ---: | --- |
| 5.279 ms | 5.967 ms | 1.130x | 4.96% | 49.15% | `diagnostic_only` |

| memory metric | parent median | candidate median | candidate / parent | parent RSD | candidate RSD |
| --- | ---: | ---: | ---: | ---: | ---: |
| `peak_rss_bytes` | 28262400 | 28475392 | 1.0075x | 0.21% | 0.35% |
| `retained_rss_bytes` | 28213248 | 28426240 | 1.0075x | 0.21% | 0.35% |

| efficiency metric | parent median | candidate median | candidate / parent | parent RSD | candidate RSD |
| --- | ---: | ---: | ---: | ---: | ---: |
| `instructions` | 95974641 | 98335732 | 1.0246x | 1.55% | 1.37% |
| `cycles` | 19020968 | 20201141 | 1.0620x | 2.24% | 20.26% |
| `energy_joules` | 0.01346952 | 0.018482958 | 1.3722x | 79.42% | 31.37% |

Thermal states: `nominal->nominal`. Unmet category metrics: none. Efficiency evidence: `blocked_or_diagnostic`.

All input identities and checksums matched. Missing attribution values are encoded as unavailable with a reason, never as zero.
