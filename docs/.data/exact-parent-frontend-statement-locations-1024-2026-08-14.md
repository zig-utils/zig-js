# Exact-parent performance A/B — representative_frontend_statement_locations_1024 (single, 1 lane(s))

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
| 5.466 ms | 0.209 ms | 0.038x | 4.18% | 14.55% | `diagnostic_only` |

| memory/allocation metric | parent median | candidate median | candidate / parent | parent RSD | candidate RSD |
| --- | ---: | ---: | ---: | ---: | ---: |
| `peak_rss_bytes` | 7487488 | 7503872 | 1.0022x | 0.13% | 3.06% |
| `allocations` | 2086 | 2087 | 1.0005x | 0.00% | 0.00% |
| `allocated_bytes` | 917184 | 925384 | 1.0089x | 0.00% | 0.00% |

| efficiency metric | parent median | candidate median | candidate / parent | parent RSD | candidate RSD |
| --- | ---: | ---: | ---: | ---: | ---: |
| `instructions` | 138890199 | 3649926 | 0.0263x | 0.05% | 0.45% |
| `cycles` | 19859469 | 787992 | 0.0397x | 3.87% | 2.96% |
| `energy_joules` | 0.002871875 | 0 | 0.0000x | 116.03% | 264.58% |

Thermal states: `nominal->nominal`. Unmet category metrics: none. Efficiency evidence: `blocked_or_diagnostic`.

All input identities and checksums matched. Missing attribution values are encoded as unavailable with a reason, never as zero.
