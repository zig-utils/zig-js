# Exact-parent performance A/B — representative_frontend_nested_functions_decoys_1024 (single, 1 lane(s))

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
| 6.021 ms | 1.005 ms | 0.167x | 4.96% | 11.59% | `diagnostic_only` |

| memory/allocation metric | parent median | candidate median | candidate / parent | parent RSD | candidate RSD |
| --- | ---: | ---: | ---: | ---: | ---: |
| `peak_rss_bytes` | 12435456 | 12402688 | 0.9974x | 3.85% | 2.30% |
| `allocations` | 11306 | 11306 | 1.0000x | 0.00% | 0.00% |
| `allocated_bytes` | 4999856 | 4999856 | 1.0000x | 0.00% | 0.00% |

| efficiency metric | parent median | candidate median | candidate / parent | parent RSD | candidate RSD |
| --- | ---: | ---: | ---: | ---: | ---: |
| `instructions` | 43290192 | 17454164 | 0.4032x | 0.43% | 0.47% |
| `cycles` | 20870327 | 3513468 | 0.1683x | 1.63% | 5.45% |
| `energy_joules` | 0.015103602 | 0.002507591 | 0.1660x | 14.14% | 89.25% |

Thermal states: `nominal->nominal`. Unmet category metrics: none. Efficiency evidence: `blocked_or_diagnostic`.

All input identities and checksums matched. Missing attribution values are encoded as unavailable with a reason, never as zero.
