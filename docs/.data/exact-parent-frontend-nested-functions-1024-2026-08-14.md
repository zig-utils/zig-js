# Exact-parent performance A/B — representative_frontend_nested_functions_1024 (single, 1 lane(s))

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
| 18.788 ms | 0.615 ms | 0.033x | 0.60% | 11.29% | `diagnostic_only` |

| memory/allocation metric | parent median | candidate median | candidate / parent | parent RSD | candidate RSD |
| --- | ---: | ---: | ---: | ---: | ---: |
| `peak_rss_bytes` | 10567680 | 10600448 | 1.0031x | 0.19% | 0.52% |
| `allocations` | 6182 | 6182 | 1.0000x | 0.00% | 0.00% |
| `allocated_bytes` | 2862432 | 2862432 | 1.0000x | 0.00% | 0.00% |

| efficiency metric | parent median | candidate median | candidate / parent | parent RSD | candidate RSD |
| --- | ---: | ---: | ---: | ---: | ---: |
| `instructions` | 197002392 | 10152848 | 0.0515x | 0.05% | 0.51% |
| `cycles` | 65164147 | 2117317 | 0.0325x | 0.24% | 4.55% |
| `energy_joules` | 0.047154384 | 0.001411445 | 0.0299x | 6.06% | 97.13% |

Thermal states: `nominal->nominal`. Unmet category metrics: none. Efficiency evidence: `blocked_or_diagnostic`.

All input identities and checksums matched. Missing attribution values are encoded as unavailable with a reason, never as zero.
