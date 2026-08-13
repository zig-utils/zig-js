# Exact-parent performance A/B — representative_frontend_strict_params_4096 (single, 1 lane(s))

- parent: `b7bbea782aa5d2ef1b19a891ab18d6d188135cd1`
- candidate: `085cb6224cf135113b6dd112370a4e2aefcc0252`
- zig-gc: `89b6652c81ba892119b7b9ce3b0d07fc78a009ff`
- zig-regex: `719673318b0c6250898d7ced3603876c148e370b`
- host class: `diagnostic`
- material-change categories: `cpu_work`
- sampling: 7 order-balanced pairs; no discarded samples
- timed boundary: one hundred parser-only parses with structural validation over one preconstructed 4,096-parameter ASCII strict-function source after ten 10-job warmups; allocation counters are an untimed exact-work replay

| parent median | candidate median | candidate / parent | parent RSD | candidate RSD | assessment |
| ---: | ---: | ---: | ---: | ---: | --- |
| 69.662 ms | 69.481 ms | 0.997x | 0.75% | 13.98% | `diagnostic_only` |

| memory/allocation metric | parent median | candidate median | candidate / parent | parent RSD | candidate RSD |
| --- | ---: | ---: | ---: | ---: | ---: |
| `peak_rss_bytes` | 9699328 | 9715712 | 1.0017x | 2.74% | 4.90% |
| `allocations` | 6800 | 6800 | 1.0000x | 0.00% | 0.00% |
| `allocated_bytes` | 252188000 | 252188000 | 1.0000x | 0.00% | 0.00% |

| efficiency metric | parent median | candidate median | candidate / parent | parent RSD | candidate RSD |
| --- | ---: | ---: | ---: | ---: | ---: |
| `instructions` | 1281721029 | 1291789662 | 1.0079x | 0.02% | 0.12% |
| `cycles` | 245191117 | 245130578 | 0.9998x | 0.40% | 5.38% |
| `energy_joules` | 0.263323621 | 0.257044503 | 0.9762x | 3.25% | 4.81% |

Thermal states: `nominal->nominal`. Unmet category metrics: none. Efficiency evidence: `blocked_or_diagnostic`.

All input identities and checksums matched. Missing attribution values are encoded as unavailable with a reason, never as zero.
