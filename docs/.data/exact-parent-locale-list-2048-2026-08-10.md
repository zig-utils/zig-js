# Exact-parent performance A/B — representative_locale_list_2048 (single, 1 lane(s))

- parent: `77b939131f6191cc18c92cc05bfad2f7f61d5bff`
- candidate: `9cc8d4964bbcc3b37cca35faf5254329a6d654f3`
- zig-gc: `89b6652c81ba892119b7b9ce3b0d07fc78a009ff`
- zig-regex: `719673318b0c6250898d7ced3603876c148e370b`
- host class: `diagnostic`
- material-change categories: `cpu_work`
- sampling: 7 order-balanced pairs; no discarded samples
- timed boundary: 50 CanonicalizeLocaleList invocations over one prebuilt 2,048-element unique locale array

| parent median | candidate median | candidate / parent | parent RSD | candidate RSD | assessment |
| ---: | ---: | ---: | ---: | ---: | --- |
| 291.403 ms | 45.527 ms | 0.156x | 1.20% | 1.18% | `diagnostic_only` |

| memory metric | parent median | candidate median | candidate / parent | parent RSD | candidate RSD |
| --- | ---: | ---: | ---: | ---: | ---: |
| `peak_rss_bytes` | 94470144 | 25886720 | 0.2740x | 0.05% | 0.20% |

| efficiency metric | parent median | candidate median | candidate / parent | parent RSD | candidate RSD |
| --- | ---: | ---: | ---: | ---: | ---: |
| `instructions` | 6170773040 | 869635498 | 0.1409x | 0.01% | 0.60% |
| `cycles` | 1064623612 | 165947684 | 0.1559x | 0.64% | 0.83% |
| `energy_joules` | 1.32153579 | 0.20373941 | 0.1542x | 1.31% | 7.19% |

Thermal states: `nominal->nominal`. Unmet category metrics: none. Efficiency evidence: `blocked_or_diagnostic`.

All input identities and checksums matched. Missing attribution values are encoded as unavailable with a reason, never as zero.
