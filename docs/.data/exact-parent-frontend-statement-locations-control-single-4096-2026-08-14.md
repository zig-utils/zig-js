# Exact-parent performance A/B — representative_frontend_statement_location_single_4096 (single, 1 lane(s))

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
| 0.241 ms | 0.242 ms | 1.004x | 2.67% | 3.56% | `diagnostic_only` |

| memory/allocation metric | parent median | candidate median | candidate / parent | parent RSD | candidate RSD |
| --- | ---: | ---: | ---: | ---: | ---: |
| `peak_rss_bytes` | 9060352 | 9076736 | 1.0018x | 0.20% | 0.20% |
| `allocations` | 4133 | 4133 | 1.0000x | 0.00% | 0.00% |
| `allocated_bytes` | 2470848 | 2470848 | 1.0000x | 0.00% | 0.00% |

| efficiency metric | parent median | candidate median | candidate / parent | parent RSD | candidate RSD |
| --- | ---: | ---: | ---: | ---: | ---: |
| `instructions` | 4803468 | 4799105 | 0.9991x | 1.30% | 1.14% |
| `cycles` | 923416 | 898577 | 0.9731x | 5.92% | 5.19% |
| `energy_joules` | 0 | 0 | NaNx | 264.58% | 264.58% |

Thermal states: `fair->fair`. Unmet category metrics: none. Efficiency evidence: `blocked_or_diagnostic`.

All input identities and checksums matched. Missing attribution values are encoded as unavailable with a reason, never as zero.
