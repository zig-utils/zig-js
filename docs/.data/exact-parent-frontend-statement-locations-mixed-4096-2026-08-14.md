# Exact-parent performance A/B — representative_frontend_statement_locations_mixed_4096 (single, 1 lane(s))

- parent: `3bba3de96499a3321b14a87af7da67b9836ec5e0`
- candidate: `87eba6c25446d41347920ea9f92b73589fab4aa5`
- zig-gc: `89b6652c81ba892119b7b9ce3b0d07fc78a009ff`
- zig-regex: `719673318b0c6250898d7ced3603876c148e370b`
- host class: `diagnostic`
- material-change categories: `cpu_work`
- sampling: 7 order-balanced pairs; no discarded samples
- timed boundary: source prepared once; ten single-parse warmups; one complete lex/parse/statement-location/AST/validation job

| parent median | candidate median | candidate / parent | parent RSD | candidate RSD | assessment |
| ---: | ---: | ---: | ---: | ---: | --- |
| 158.953 ms | 0.945 ms | 0.006x | 0.86% | 2.04% | `diagnostic_only` |

| memory/allocation metric | parent median | candidate median | candidate / parent | parent RSD | candidate RSD |
| --- | ---: | ---: | ---: | ---: | ---: |
| `peak_rss_bytes` | 10256384 | 10305536 | 1.0048x | 3.74% | 0.20% |
| `allocations` | 8240 | 8241 | 1.0001x | 0.00% | 0.00% |
| `allocated_bytes` | 3438856 | 3471632 | 1.0095x | 0.00% | 0.00% |

| efficiency metric | parent median | candidate median | candidate / parent | parent RSD | candidate RSD |
| --- | ---: | ---: | ---: | ---: | ---: |
| `instructions` | 3408922483 | 16281753 | 0.0048x | 0.01% | 0.09% |
| `cycles` | 569775194 | 3429133 | 0.0060x | 0.24% | 2.01% |
| `energy_joules` | 0.629599271 | 0 | 0.0000x | 1.20% | 264.58% |

Thermal states: `fair->fair`. Unmet category metrics: none. Efficiency evidence: `blocked_or_diagnostic`.

All input identities and checksums matched. Missing attribution values are encoded as unavailable with a reason, never as zero.
