# Exact-parent performance A/B — representative_frontend_unicode_identifiers_4096 (single, 1 lane(s))

- parent: `b7bbea782aa5d2ef1b19a891ab18d6d188135cd1`
- candidate: `085cb6224cf135113b6dd112370a4e2aefcc0252`
- zig-gc: `89b6652c81ba892119b7b9ce3b0d07fc78a009ff`
- zig-regex: `719673318b0c6250898d7ced3603876c148e370b`
- host class: `diagnostic`
- material-change categories: `cpu_work`
- sampling: 7 order-balanced pairs; no discarded samples
- timed boundary: one hundred parser-only parses with exact decoded-name and ordinal validation over one preconstructed 4,096-parameter raw-Unicode source after ten 10-job warmups; allocation counters are an untimed exact-work replay

| parent median | candidate median | candidate / parent | parent RSD | candidate RSD | assessment |
| ---: | ---: | ---: | ---: | ---: | --- |
| 89.049 ms | 97.350 ms | 1.093x | 0.99% | 1.58% | `diagnostic_only` |

| memory/allocation metric | parent median | candidate median | candidate / parent | parent RSD | candidate RSD |
| --- | ---: | ---: | ---: | ---: | ---: |
| `peak_rss_bytes` | 9650176 | 9715712 | 1.0068x | 3.87% | 2.75% |
| `allocations` | 6800 | 6800 | 1.0000x | 0.00% | 0.00% |
| `allocated_bytes` | 252188000 | 252188000 | 1.0000x | 0.00% | 0.00% |

| efficiency metric | parent median | candidate median | candidate / parent | parent RSD | candidate RSD |
| --- | ---: | ---: | ---: | ---: | ---: |
| `instructions` | 1644567047 | 1771910487 | 1.0774x | 0.02% | 0.05% |
| `cycles` | 315340718 | 342133784 | 1.0850x | 0.54% | 0.91% |
| `energy_joules` | 0.345213529 | 0.371765551 | 1.0769x | 2.79% | 2.77% |

Thermal states: `nominal->nominal`. Unmet category metrics: none. Efficiency evidence: `stable`.

All input identities and checksums matched. Missing attribution values are encoded as unavailable with a reason, never as zero.
