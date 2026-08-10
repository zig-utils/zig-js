# Exact-parent performance A/B — representative_date_string_2048 (single, 1 lane(s))

- parent: `cdabd71fee32bf72abcd31283237a8a25f8c0f1e`
- candidate: `0b01b7899ed847349b66605bea73be8a949fc065`
- zig-gc: `89b6652c81ba892119b7b9ce3b0d07fc78a009ff`
- zig-regex: `719673318b0c6250898d7ced3603876c148e370b`
- host class: `diagnostic`
- material-change categories: `cpu_work`
- sampling: 7 order-balanced pairs; no discarded samples
- timed boundary: one invocation in a persistent context after ten reduced-work warmups

| parent median | candidate median | candidate / parent | parent RSD | candidate RSD | assessment |
| ---: | ---: | ---: | ---: | ---: | --- |
| 170.381 ms | 167.022 ms | 0.980x | 1.83% | 1.80% | `diagnostic_only` |

| memory metric | parent median | candidate median | candidate / parent | parent RSD | candidate RSD |
| --- | ---: | ---: | ---: | ---: | ---: |
| `peak_rss_bytes` | 185942016 | 180289536 | 0.9696x | 0.02% | 0.01% |

| efficiency metric | parent median | candidate median | candidate / parent | parent RSD | candidate RSD |
| --- | ---: | ---: | ---: | ---: | ---: |
| `instructions` | 3364745618 | 3314959883 | 0.9852x | 1.13% | 1.07% |
| `cycles` | 628449156 | 627219801 | 0.9980x | 1.38% | 0.83% |
| `energy_joules` | 0.779939372 | 0.756302863 | 0.9697x | 1.87% | 0.93% |

Thermal states: `nominal->nominal`. Unmet category metrics: none. Efficiency evidence: `stable`.

All input identities and checksums matched. Missing attribution values are encoded as unavailable with a reason, never as zero.
