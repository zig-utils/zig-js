# Exact-parent performance A/B — representative_locale_list_duplicates_4096 (single, 1 lane(s))

- parent: `77b939131f6191cc18c92cc05bfad2f7f61d5bff`
- candidate: `9cc8d4964bbcc3b37cca35faf5254329a6d654f3`
- zig-gc: `89b6652c81ba892119b7b9ce3b0d07fc78a009ff`
- zig-regex: `719673318b0c6250898d7ced3603876c148e370b`
- host class: `diagnostic`
- material-change categories: `cpu_work`
- sampling: 7 order-balanced pairs; no discarded samples
- timed boundary: 100 CanonicalizeLocaleList invocations over one prebuilt 4,096-element duplicate-heavy locale array with 32 first occurrences

| parent median | candidate median | candidate / parent | parent RSD | candidate RSD | assessment |
| ---: | ---: | ---: | ---: | ---: | --- |
| 133.642 ms | 115.185 ms | 0.862x | 2.09% | 2.11% | `diagnostic_only` |

| memory metric | parent median | candidate median | candidate / parent | parent RSD | candidate RSD |
| --- | ---: | ---: | ---: | ---: | ---: |
| `peak_rss_bytes` | 285818880 | 20807680 | 0.0728x | 0.02% | 0.11% |

| efficiency metric | parent median | candidate median | candidate / parent | parent RSD | candidate RSD |
| --- | ---: | ---: | ---: | ---: | ---: |
| `instructions` | 2482313406 | 2285302827 | 0.9206x | 0.04% | 1.21% |
| `cycles` | 485201110 | 415047204 | 0.8554x | 1.30% | 1.79% |
| `energy_joules` | 0.595318179 | 0.510211516 | 0.8570x | 2.45% | 2.60% |

Thermal states: `nominal->nominal`. Unmet category metrics: none. Efficiency evidence: `stable`.

All input identities and checksums matched. Missing attribution values are encoded as unavailable with a reason, never as zero.
