# Exact-parent performance A/B — representative_date_string_4096 (single, 1 lane(s))

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
| 346.565 ms | 345.957 ms | 0.998x | 4.48% | 13.20% | `diagnostic_only` |

| memory metric | parent median | candidate median | candidate / parent | parent RSD | candidate RSD |
| --- | ---: | ---: | ---: | ---: | ---: |
| `peak_rss_bytes` | 341917696 | 330645504 | 0.9670x | 0.01% | 0.56% |

| efficiency metric | parent median | candidate median | candidate / parent | parent RSD | candidate RSD |
| --- | ---: | ---: | ---: | ---: | ---: |
| `instructions` | 6657817228 | 6617645362 | 0.9940x | 0.72% | 0.90% |
| `cycles` | 1257001729 | 1249485523 | 0.9940x | 1.42% | 3.61% |
| `energy_joules` | 1.55925389 | 1.564980886 | 1.0037x | 0.99% | 2.75% |

Thermal states: `nominal->nominal`. Unmet category metrics: none. Efficiency evidence: `stable`.

All input identities and checksums matched. Missing attribution values are encoded as unavailable with a reason, never as zero.
