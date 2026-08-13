# Exact-parent performance A/B — representative_frontend_unicode_identifiers_2048 (single, 1 lane(s))

- parent: `b7bbea782aa5d2ef1b19a891ab18d6d188135cd1`
- candidate: `085cb6224cf135113b6dd112370a4e2aefcc0252`
- zig-gc: `89b6652c81ba892119b7b9ce3b0d07fc78a009ff`
- zig-regex: `719673318b0c6250898d7ced3603876c148e370b`
- host class: `diagnostic`
- material-change categories: `cpu_work`
- sampling: 7 order-balanced pairs; no discarded samples
- timed boundary: one hundred parser-only parses with exact decoded-name and ordinal validation over one preconstructed 2,048-parameter raw-Unicode source after ten 10-job warmups; allocation counters are an untimed exact-work replay

| parent median | candidate median | candidate / parent | parent RSD | candidate RSD | assessment |
| ---: | ---: | ---: | ---: | ---: | --- |
| 44.352 ms | 50.118 ms | 1.130x | 4.81% | 4.39% | `diagnostic_only` |

| memory/allocation metric | parent median | candidate median | candidate / parent | parent RSD | candidate RSD |
| --- | ---: | ---: | ---: | ---: | ---: |
| `peak_rss_bytes` | 8650752 | 8683520 | 1.0038x | 4.13% | 3.28% |
| `allocations` | 6200 | 6200 | 1.0000x | 0.00% | 0.00% |
| `allocated_bytes` | 102460800 | 102460800 | 1.0000x | 0.00% | 0.00% |

| efficiency metric | parent median | candidate median | candidate / parent | parent RSD | candidate RSD |
| --- | ---: | ---: | ---: | ---: | ---: |
| `instructions` | 813172413 | 876521335 | 1.0779x | 0.06% | 0.07% |
| `cycles` | 155935651 | 171243926 | 1.0982x | 2.61% | 2.47% |
| `energy_joules` | 0.169775045 | 0.181216355 | 1.0674x | 6.70% | 4.62% |

Thermal states: `nominal->nominal`. Unmet category metrics: none. Efficiency evidence: `blocked_or_diagnostic`.

All input identities and checksums matched. Missing attribution values are encoded as unavailable with a reason, never as zero.
