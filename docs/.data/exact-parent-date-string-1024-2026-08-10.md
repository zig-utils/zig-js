# Exact-parent performance A/B — representative_date_string_1024 (single, 1 lane(s))

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
| 91.248 ms | 88.380 ms | 0.969x | 5.70% | 3.44% | `diagnostic_only` |

| memory metric | parent median | candidate median | candidate / parent | parent RSD | candidate RSD |
| --- | ---: | ---: | ---: | ---: | ---: |
| `peak_rss_bytes` | 107937792 | 105136128 | 0.9740x | 0.03% | 0.03% |

| efficiency metric | parent median | candidate median | candidate / parent | parent RSD | candidate RSD |
| --- | ---: | ---: | ---: | ---: | ---: |
| `instructions` | 1694893109 | 1671206233 | 0.9860x | 0.99% | 1.37% |
| `cycles` | 322699466 | 317155918 | 0.9828x | 2.12% | 1.40% |
| `energy_joules` | 0.368303534 | 0.38859791 | 1.0551x | 4.57% | 2.36% |

Thermal states: `nominal->nominal`. Unmet category metrics: none. Efficiency evidence: `stable`.

All input identities and checksums matched. Missing attribution values are encoded as unavailable with a reason, never as zero.
