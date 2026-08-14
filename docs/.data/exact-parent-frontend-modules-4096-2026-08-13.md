# Exact-parent performance A/B — representative_frontend_modules_4096 (single, 1 lane(s))

- parent: `1240045a7d5f4f7fe2e7a9d99d220b5984102629`
- candidate: `78dbd220f160d43b668d26a4457dea8de30a6486`
- zig-gc: `89b6652c81ba892119b7b9ce3b0d07fc78a009ff`
- zig-regex: `719673318b0c6250898d7ced3603876c148e370b`
- host class: `diagnostic`
- material-change categories: `cpu_work`
- sampling: 7 order-balanced pairs; no discarded samples
- timed boundary: source prepared once; ten 20-job warmups; 200 complete Module lex/parse/AST/early-error/validation jobs

| parent median | candidate median | candidate / parent | parent RSD | candidate RSD | assessment |
| ---: | ---: | ---: | ---: | ---: | --- |
| 502.327 ms | 316.135 ms | 0.629x | 17.25% | 7.82% | `diagnostic_only` |

| memory/allocation metric | parent median | candidate median | candidate / parent | parent RSD | candidate RSD |
| --- | ---: | ---: | ---: | ---: | ---: |
| `peak_rss_bytes` | 23756800 | 16547840 | 0.6966x | 0.26% | 0.56% |
| `allocations` | 22200 | 17600 | 0.7928x | 0.00% | 0.00% |
| `allocated_bytes` | 3697497600 | 1927113600 | 0.5212x | 0.00% | 0.00% |

| efficiency metric | parent median | candidate median | candidate / parent | parent RSD | candidate RSD |
| --- | ---: | ---: | ---: | ---: | ---: |
| `instructions` | 8776804818 | 5753759501 | 0.6556x | 0.11% | 0.05% |
| `cycles` | 1663795444 | 1064844382 | 0.6400x | 8.12% | 3.73% |
| `energy_joules` | 2.009788552 | 1.264961892 | 0.6294x | 7.98% | 4.14% |

Thermal states: `nominal->nominal`. Unmet category metrics: none. Efficiency evidence: `blocked_or_diagnostic`.

All input identities and checksums matched. Missing attribution values are encoded as unavailable with a reason, never as zero.
