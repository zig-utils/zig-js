# Exact-parent performance A/B — representative_locale_list_1024 (single, 1 lane(s))

- parent: `77b939131f6191cc18c92cc05bfad2f7f61d5bff`
- candidate: `9cc8d4964bbcc3b37cca35faf5254329a6d654f3`
- zig-gc: `89b6652c81ba892119b7b9ce3b0d07fc78a009ff`
- zig-regex: `719673318b0c6250898d7ced3603876c148e370b`
- host class: `diagnostic`
- material-change categories: `cpu_work`
- sampling: 7 order-balanced pairs; no discarded samples
- timed boundary: 100 CanonicalizeLocaleList invocations over one prebuilt 1,024-element unique locale array

| parent median | candidate median | candidate / parent | parent RSD | candidate RSD | assessment |
| ---: | ---: | ---: | ---: | ---: | --- |
| 181.839 ms | 45.771 ms | 0.252x | 0.60% | 1.96% | `diagnostic_only` |

| memory metric | parent median | candidate median | candidate / parent | parent RSD | candidate RSD |
| --- | ---: | ---: | ---: | ---: | ---: |
| `peak_rss_bytes` | 91766784 | 24756224 | 0.2698x | 0.04% | 0.14% |

| efficiency metric | parent median | candidate median | candidate / parent | parent RSD | candidate RSD |
| --- | ---: | ---: | ---: | ---: | ---: |
| `instructions` | 3975828244 | 870820849 | 0.2190x | 0.02% | 0.58% |
| `cycles` | 665442265 | 167748296 | 0.2521x | 0.57% | 1.45% |
| `energy_joules` | 0.831175782 | 0.184263936 | 0.2217x | 1.24% | 5.27% |

Thermal states: `nominal->nominal`. Unmet category metrics: none. Efficiency evidence: `blocked_or_diagnostic`.

All input identities and checksums matched. Missing attribution values are encoded as unavailable with a reason, never as zero.
