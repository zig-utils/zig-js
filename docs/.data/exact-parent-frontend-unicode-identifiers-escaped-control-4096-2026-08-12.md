# Exact-parent performance A/B — representative_frontend_escaped_identifiers_4096 (single, 1 lane(s))

- parent: `b7bbea782aa5d2ef1b19a891ab18d6d188135cd1`
- candidate: `085cb6224cf135113b6dd112370a4e2aefcc0252`
- zig-gc: `89b6652c81ba892119b7b9ce3b0d07fc78a009ff`
- zig-regex: `719673318b0c6250898d7ced3603876c148e370b`
- host class: `diagnostic`
- material-change categories: `cpu_work`
- sampling: 7 order-balanced pairs; no discarded samples
- timed boundary: one hundred parser-only parses with exact decoded-name and ordinal validation over one preconstructed 4,096-parameter escaped-ASCII identifier source after ten 10-job warmups; allocation counters are an untimed exact-work replay

| parent median | candidate median | candidate / parent | parent RSD | candidate RSD | assessment |
| ---: | ---: | ---: | ---: | ---: | --- |
| 91.660 ms | 90.975 ms | 0.993x | 0.64% | 0.83% | `diagnostic_only` |

| memory/allocation metric | parent median | candidate median | candidate / parent | parent RSD | candidate RSD |
| --- | ---: | ---: | ---: | ---: | ---: |
| `peak_rss_bytes` | 11173888 | 11632640 | 1.0411x | 5.96% | 4.69% |
| `allocations` | 826000 | 826000 | 1.0000x | 0.00% | 0.00% |
| `allocated_bytes` | 402783200 | 402783200 | 1.0000x | 0.00% | 0.00% |

| efficiency metric | parent median | candidate median | candidate / parent | parent RSD | candidate RSD |
| --- | ---: | ---: | ---: | ---: | ---: |
| `instructions` | 1629936337 | 1637255592 | 1.0045x | 0.02% | 0.02% |
| `cycles` | 324572344 | 322885289 | 0.9948x | 0.39% | 0.39% |
| `energy_joules` | 0.355336632 | 0.352517118 | 0.9921x | 2.46% | 3.12% |

Thermal states: `nominal->nominal`. Unmet category metrics: none. Efficiency evidence: `stable`.

All input identities and checksums matched. Missing attribution values are encoded as unavailable with a reason, never as zero.
