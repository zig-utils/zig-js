# Exact-parent performance A/B — representative_frontend_modules_1024 (single, 1 lane(s))

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
| 97.356 ms | 63.060 ms | 0.648x | 0.90% | 0.94% | `diagnostic_only` |

| memory/allocation metric | parent median | candidate median | candidate / parent | parent RSD | candidate RSD |
| --- | ---: | ---: | ---: | ---: | ---: |
| `peak_rss_bytes` | 9846784 | 8945664 | 0.9085x | 4.01% | 4.46% |
| `allocations` | 18400 | 14600 | 0.7935x | 0.00% | 0.00% |
| `allocated_bytes` | 665972800 | 456219200 | 0.6850x | 0.00% | 0.00% |

| efficiency metric | parent median | candidate median | candidate / parent | parent RSD | candidate RSD |
| --- | ---: | ---: | ---: | ---: | ---: |
| `instructions` | 2122915279 | 1409815551 | 0.6641x | 0.01% | 0.01% |
| `cycles` | 349786456 | 227520334 | 0.6505x | 0.56% | 0.49% |
| `energy_joules` | 0.471378193 | 0.277488788 | 0.5887x | 3.63% | 4.48% |

Thermal states: `nominal->nominal`. Unmet category metrics: none. Efficiency evidence: `stable`.

All input identities and checksums matched. Missing attribution values are encoded as unavailable with a reason, never as zero.
