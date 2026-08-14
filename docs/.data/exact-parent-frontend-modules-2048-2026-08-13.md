# Exact-parent performance A/B — representative_frontend_modules_2048 (single, 1 lane(s))

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
| 215.212 ms | 134.458 ms | 0.625x | 13.51% | 28.23% | `diagnostic_only` |

| memory/allocation metric | parent median | candidate median | candidate / parent | parent RSD | candidate RSD |
| --- | ---: | ---: | ---: | ---: | ---: |
| `peak_rss_bytes` | 13582336 | 11436032 | 0.8420x | 3.09% | 3.73% |
| `allocations` | 20400 | 16200 | 0.7941x | 0.00% | 0.00% |
| `allocated_bytes` | 1305972800 | 771844800 | 0.5910x | 0.00% | 0.00% |

| efficiency metric | parent median | candidate median | candidate / parent | parent RSD | candidate RSD |
| --- | ---: | ---: | ---: | ---: | ---: |
| `instructions` | 4280388495 | 2830994458 | 0.6614x | 0.25% | 0.55% |
| `cycles` | 734425952 | 467896558 | 0.6371x | 5.94% | 9.01% |
| `energy_joules` | 0.970466627 | 0.595274107 | 0.6134x | 3.16% | 1.05% |

Thermal states: `nominal->nominal`. Unmet category metrics: none. Efficiency evidence: `blocked_or_diagnostic`.

All input identities and checksums matched. Missing attribution values are encoded as unavailable with a reason, never as zero.
