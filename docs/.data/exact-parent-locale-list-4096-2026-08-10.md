# Exact-parent performance A/B — representative_locale_list_4096 (single, 1 lane(s))

- parent: `77b939131f6191cc18c92cc05bfad2f7f61d5bff`
- candidate: `9cc8d4964bbcc3b37cca35faf5254329a6d654f3`
- zig-gc: `89b6652c81ba892119b7b9ce3b0d07fc78a009ff`
- zig-regex: `719673318b0c6250898d7ced3603876c148e370b`
- host class: `diagnostic`
- material-change categories: `cpu_work`
- sampling: 7 order-balanced pairs; no discarded samples
- timed boundary: 20 CanonicalizeLocaleList invocations over one prebuilt 4,096-element unique locale array

| parent median | candidate median | candidate / parent | parent RSD | candidate RSD | assessment |
| ---: | ---: | ---: | ---: | ---: | --- |
| 436.721 ms | 36.678 ms | 0.084x | 10.04% | 2.74% | `diagnostic_only` |

| memory metric | parent median | candidate median | candidate / parent | parent RSD | candidate RSD |
| --- | ---: | ---: | ---: | ---: | ---: |
| `peak_rss_bytes` | 87703552 | 29425664 | 0.3355x | 0.03% | 0.29% |

| efficiency metric | parent median | candidate median | candidate / parent | parent RSD | candidate RSD |
| --- | ---: | ---: | ---: | ---: | ---: |
| `instructions` | 9560896982 | 682711563 | 0.0714x | 0.04% | 0.82% |
| `cycles` | 1629023485 | 131221563 | 0.0806x | 1.23% | 1.00% |
| `energy_joules` | 2.066274583 | 0.145917682 | 0.0706x | 0.67% | 7.76% |

Thermal states: `nominal->nominal`. Unmet category metrics: none. Efficiency evidence: `blocked_or_diagnostic`.

All input identities and checksums matched. Missing attribution values are encoded as unavailable with a reason, never as zero.
