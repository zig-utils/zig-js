# Exact-parent performance A/B — representative_frontend_statement_locations_4096 (single, 1 lane(s))

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
| 86.982 ms | 0.876 ms | 0.010x | 2.29% | 3.34% | `diagnostic_only` |

| memory/allocation metric | parent median | candidate median | candidate / parent | parent RSD | candidate RSD |
| --- | ---: | ---: | ---: | ---: | ---: |
| `peak_rss_bytes` | 10141696 | 10207232 | 1.0065x | 0.17% | 0.20% |
| `allocations` | 8240 | 8241 | 1.0001x | 0.00% | 0.00% |
| `allocated_bytes` | 3438856 | 3471632 | 1.0095x | 0.00% | 0.00% |

| efficiency metric | parent median | candidate median | candidate / parent | parent RSD | candidate RSD |
| --- | ---: | ---: | ---: | ---: | ---: |
| `instructions` | 2301460713 | 14829228 | 0.0064x | 0.01% | 0.01% |
| `cycles` | 312616849 | 3137162 | 0.0100x | 2.33% | 2.00% |
| `energy_joules` | 0.411229856 | 0 | 0.0000x | 3.79% | NaN% |

Thermal states: `fair->fair`. Unmet category metrics: none. Efficiency evidence: `blocked_or_diagnostic`.

All input identities and checksums matched. Missing attribution values are encoded as unavailable with a reason, never as zero.
