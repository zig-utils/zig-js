# Exact-parent performance A/B — representative_locale_list_8 (single, 1 lane(s))

- parent: `9cc8d4964bbcc3b37cca35faf5254329a6d654f3`
- candidate: `c4662097610ff13199b804fca380e4b95802d439`
- zig-gc: `89b6652c81ba892119b7b9ce3b0d07fc78a009ff`
- zig-regex: `719673318b0c6250898d7ced3603876c148e370b`
- host class: `diagnostic`
- material-change categories: `cpu_work`
- sampling: 7 order-balanced pairs; no discarded samples
- timed boundary: 10,000 CanonicalizeLocaleList invocations over one prebuilt 8-element locale array

| parent median | candidate median | candidate / parent | parent RSD | candidate RSD | assessment |
| ---: | ---: | ---: | ---: | ---: | --- |
| 71.501 ms | 67.262 ms | 0.941x | 1.91% | 1.57% | `diagnostic_only` |

| memory metric | parent median | candidate median | candidate / parent | parent RSD | candidate RSD |
| --- | ---: | ---: | ---: | ---: | ---: |
| `peak_rss_bytes` | 29671424 | 29736960 | 1.0022x | 0.08% | 0.10% |

| efficiency metric | parent median | candidate median | candidate / parent | parent RSD | candidate RSD |
| --- | ---: | ---: | ---: | ---: | ---: |
| `instructions` | 1336020519 | 1209588137 | 0.9054x | 0.77% | 0.72% |
| `cycles` | 265193894 | 249097937 | 0.9393x | 0.94% | 1.28% |
| `energy_joules` | 0.307848339 | 0.285808046 | 0.9284x | 5.18% | 4.85% |

Thermal states: `nominal->nominal`. Unmet category metrics: none. Efficiency evidence: `blocked_or_diagnostic`.

All input identities and checksums matched. Missing attribution values are encoded as unavailable with a reason, never as zero.
