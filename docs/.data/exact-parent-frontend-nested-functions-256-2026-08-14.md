# Exact-parent performance A/B — representative_frontend_nested_functions_256 (single, 1 lane(s))

- parent: `6ce7124367ddb18d174c4381c572561515a26153`
- candidate: `00a401d77f9dddd4ad94f95795774b4523dd7b9b`
- zig-gc: `89b6652c81ba892119b7b9ce3b0d07fc78a009ff`
- zig-regex: `719673318b0c6250898d7ced3603876c148e370b`
- host class: `diagnostic`
- material-change categories: `cpu_work`
- sampling: 7 order-balanced pairs; no discarded samples
- timed boundary: source prepared once; ten single-parse warmups; one complete lex/parse/function-scope-metadata/AST/source-range validation job

| parent median | candidate median | candidate / parent | parent RSD | candidate RSD | assessment |
| ---: | ---: | ---: | ---: | ---: | --- |
| 1.251 ms | 0.160 ms | 0.127x | 1.25% | 4.87% | `diagnostic_only` |

| memory/allocation metric | parent median | candidate median | candidate / parent | parent RSD | candidate RSD |
| --- | ---: | ---: | ---: | ---: | ---: |
| `peak_rss_bytes` | 7618560 | 7618560 | 1.0000x | 0.22% | 1.57% |
| `allocations` | 1568 | 1568 | 1.0000x | 0.00% | 0.00% |
| `allocated_bytes` | 818080 | 818080 | 1.0000x | 0.00% | 0.00% |

| efficiency metric | parent median | candidate median | candidate / parent | parent RSD | candidate RSD |
| --- | ---: | ---: | ---: | ---: | ---: |
| `instructions` | 14046194 | 2541003 | 0.1809x | 0.19% | 0.07% |
| `cycles` | 4357091 | 537152 | 0.1233x | 0.31% | 2.08% |
| `energy_joules` | 0 | 0 | NaNx | 264.58% | NaN% |

Thermal states: `nominal->nominal`. Unmet category metrics: none. Efficiency evidence: `blocked_or_diagnostic`.

All input identities and checksums matched. Missing attribution values are encoded as unavailable with a reason, never as zero.
