# Exact-parent performance A/B — representative_date_string_4096 (single_observed, 1 lane(s))

- parent: `cdabd71fee32bf72abcd31283237a8a25f8c0f1e`
- candidate: `0b01b7899ed847349b66605bea73be8a949fc065`
- zig-gc: `89b6652c81ba892119b7b9ce3b0d07fc78a009ff`
- zig-regex: `719673318b0c6250898d7ced3603876c148e370b`
- host class: `diagnostic`
- material-change categories: `cpu_work`
- sampling: 7 order-balanced pairs; no discarded samples
- timed boundary: one invocation in a persistent context after ten reduced-work warmups; retained RSS observed before Context destruction

| parent median | candidate median | candidate / parent | parent RSD | candidate RSD | assessment |
| ---: | ---: | ---: | ---: | ---: | --- |
| 349.726 ms | 340.495 ms | 0.974x | 6.97% | 2.56% | `diagnostic_only` |

| memory metric | parent median | candidate median | candidate / parent | parent RSD | candidate RSD |
| --- | ---: | ---: | ---: | ---: | ---: |
| `peak_rss_bytes` | 247545856 | 256770048 | 1.0373x | 29.34% | 19.01% |
| `retained_rss_bytes` | 196755456 | 216219648 | 1.0989x | 37.00% | 43.95% |

| efficiency metric | parent median | candidate median | candidate / parent | parent RSD | candidate RSD |
| --- | ---: | ---: | ---: | ---: | ---: |
| `instructions` | 6622235668 | 6593531568 | 0.9957x | 1.12% | 1.84% |
| `cycles` | 1251960764 | 1243534015 | 0.9933x | 3.86% | 1.70% |
| `energy_joules` | 1.584184333 | 1.580947941 | 0.9980x | 0.91% | 1.71% |

Thermal states: `nominal->nominal`. Unmet category metrics: none. Efficiency evidence: `stable`.

All input identities and checksums matched. Missing attribution values are encoded as unavailable with a reason, never as zero.
