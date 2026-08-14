# Exact-parent performance A/B — representative_frontend_nested_functions_arguments_1024 (single, 1 lane(s))

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
| 5.666 ms | 0.590 ms | 0.104x | 2.17% | 3.31% | `diagnostic_only` |

| memory/allocation metric | parent median | candidate median | candidate / parent | parent RSD | candidate RSD |
| --- | ---: | ---: | ---: | ---: | ---: |
| `peak_rss_bytes` | 10567680 | 10567680 | 1.0000x | 2.64% | 2.53% |
| `allocations` | 6183 | 6183 | 1.0000x | 0.00% | 0.00% |
| `allocated_bytes` | 2862512 | 2862512 | 1.0000x | 0.00% | 0.00% |

| efficiency metric | parent median | candidate median | candidate / parent | parent RSD | candidate RSD |
| --- | ---: | ---: | ---: | ---: | ---: |
| `instructions` | 35865252 | 10126172 | 0.2823x | 0.19% | 0.17% |
| `cycles` | 19223983 | 2071862 | 0.1078x | 0.72% | 0.71% |
| `energy_joules` | 0.012186081 | 0 | 0.0000x | 11.05% | 125.77% |

Thermal states: `nominal->nominal`. Unmet category metrics: none. Efficiency evidence: `blocked_or_diagnostic`.

All input identities and checksums matched. Missing attribution values are encoded as unavailable with a reason, never as zero.
