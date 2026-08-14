# Exact-parent performance A/B — representative_frontend_statement_locations_2048 (single, 1 lane(s))

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
| 21.228 ms | 0.426 ms | 0.020x | 1.66% | 3.23% | `diagnostic_only` |

| memory/allocation metric | parent median | candidate median | candidate / parent | parent RSD | candidate RSD |
| --- | ---: | ---: | ---: | ---: | ---: |
| `peak_rss_bytes` | 8142848 | 8175616 | 1.0040x | 1.86% | 1.68% |
| `allocations` | 4139 | 4140 | 1.0002x | 0.00% | 0.00% |
| `allocated_bytes` | 1434800 | 1451192 | 1.0114x | 0.00% | 0.00% |

| efficiency metric | parent median | candidate median | candidate / parent | parent RSD | candidate RSD |
| --- | ---: | ---: | ---: | ---: | ---: |
| `instructions` | 563959279 | 7332673 | 0.0130x | 0.01% | 0.08% |
| `cycles` | 76646659 | 1537888 | 0.0201x | 1.36% | 2.15% |
| `energy_joules` | 0.098613128 | 0 | 0.0000x | 5.51% | NaN% |

Thermal states: `fair->fair`. Unmet category metrics: none. Efficiency evidence: `blocked_or_diagnostic`.

All input identities and checksums matched. Missing attribution values are encoded as unavailable with a reason, never as zero.
