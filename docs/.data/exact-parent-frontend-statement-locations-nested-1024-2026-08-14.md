# Exact-parent performance A/B — representative_frontend_statement_locations_nested_1024 (single, 1 lane(s))

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
| 34.476 ms | 0.430 ms | 0.012x | 1.64% | 3.92% | `diagnostic_only` |

| memory/allocation metric | parent median | candidate median | candidate / parent | parent RSD | candidate RSD |
| --- | ---: | ---: | ---: | ---: | ---: |
| `peak_rss_bytes` | 9666560 | 9682944 | 1.0017x | 1.49% | 0.10% |
| `allocations` | 6188 | 6189 | 1.0002x | 0.00% | 0.00% |
| `allocated_bytes` | 3042296 | 3066880 | 1.0081x | 0.00% | 0.00% |

| efficiency metric | parent median | candidate median | candidate / parent | parent RSD | candidate RSD |
| --- | ---: | ---: | ---: | ---: | ---: |
| `instructions` | 882542236 | 7653114 | 0.0087x | 0.02% | 0.53% |
| `cycles` | 123927972 | 1585868 | 0.0128x | 1.57% | 2.75% |
| `energy_joules` | 0.142250709 | 0 | 0.0000x | 9.44% | 264.58% |

Thermal states: `fair->fair`. Unmet category metrics: none. Efficiency evidence: `blocked_or_diagnostic`.

All input identities and checksums matched. Missing attribution values are encoded as unavailable with a reason, never as zero.
