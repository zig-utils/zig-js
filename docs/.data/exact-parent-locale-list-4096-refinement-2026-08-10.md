# Exact-parent performance A/B — representative_locale_list_4096 (single, 1 lane(s))

- parent: `9cc8d4964bbcc3b37cca35faf5254329a6d654f3`
- candidate: `c4662097610ff13199b804fca380e4b95802d439`
- zig-gc: `89b6652c81ba892119b7b9ce3b0d07fc78a009ff`
- zig-regex: `719673318b0c6250898d7ced3603876c148e370b`
- host class: `diagnostic`
- material-change categories: `cpu_work`
- sampling: 7 order-balanced pairs; no discarded samples
- timed boundary: 20 CanonicalizeLocaleList invocations over one prebuilt 4,096-element unique locale array

| parent median | candidate median | candidate / parent | parent RSD | candidate RSD | assessment |
| ---: | ---: | ---: | ---: | ---: | --- |
| 35.109 ms | 29.001 ms | 0.826x | 4.73% | 1.11% | `diagnostic_only` |

| memory metric | parent median | candidate median | candidate / parent | parent RSD | candidate RSD |
| --- | ---: | ---: | ---: | ---: | ---: |
| `peak_rss_bytes` | 29425664 | 29458432 | 1.0011x | 0.13% | 0.26% |

| efficiency metric | parent median | candidate median | candidate / parent | parent RSD | candidate RSD |
| --- | ---: | ---: | ---: | ---: | ---: |
| `instructions` | 682286420 | 532641082 | 0.7807x | 0.79% | 0.05% |
| `cycles` | 131446034 | 107854542 | 0.8205x | 2.15% | 0.87% |
| `energy_joules` | 0.140175239 | 0.089807348 | 0.6407x | 7.66% | 8.62% |

Thermal states: `nominal->nominal`. Unmet category metrics: none. Efficiency evidence: `blocked_or_diagnostic`.

All input identities and checksums matched. Missing attribution values are encoded as unavailable with a reason, never as zero.
