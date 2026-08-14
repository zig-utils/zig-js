# Exact-parent performance A/B — representative_frontend_nested_functions_512 (single, 1 lane(s))

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
| 4.747 ms | 0.284 ms | 0.060x | 1.82% | 2.51% | `diagnostic_only` |

| memory/allocation metric | parent median | candidate median | candidate / parent | parent RSD | candidate RSD |
| --- | ---: | ---: | ---: | ---: | ---: |
| `peak_rss_bytes` | 8339456 | 8339456 | 1.0000x | 0.18% | 0.10% |
| `allocations` | 3107 | 3107 | 1.0000x | 0.00% | 0.00% |
| `allocated_bytes` | 1384168 | 1384168 | 1.0000x | 0.00% | 0.00% |

| efficiency metric | parent median | candidate median | candidate / parent | parent RSD | candidate RSD |
| --- | ---: | ---: | ---: | ---: | ---: |
| `instructions` | 51553060 | 5026272 | 0.0975x | 0.08% | 0.00% |
| `cycles` | 16616797 | 1023711 | 0.0616x | 0.29% | 1.41% |
| `energy_joules` | 0.006552606 | 0 | 0.0000x | 76.28% | NaN% |

Thermal states: `nominal->nominal`. Unmet category metrics: none. Efficiency evidence: `blocked_or_diagnostic`.

All input identities and checksums matched. Missing attribution values are encoded as unavailable with a reason, never as zero.
