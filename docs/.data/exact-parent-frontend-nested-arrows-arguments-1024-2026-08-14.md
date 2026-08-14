# Exact-parent performance A/B — representative_frontend_nested_arrows_arguments_1024 (single, 1 lane(s))

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
| 0.099 ms | 0.097 ms | 0.977x | 3.59% | 32.22% | `diagnostic_only` |

| memory/allocation metric | parent median | candidate median | candidate / parent | parent RSD | candidate RSD |
| --- | ---: | ---: | ---: | ---: | ---: |
| `peak_rss_bytes` | 7995392 | 7995392 | 1.0000x | 0.26% | 1.50% |
| `allocations` | 2078 | 2078 | 1.0000x | 0.00% | 0.00% |
| `allocated_bytes` | 914264 | 914264 | 1.0000x | 0.00% | 0.00% |

| efficiency metric | parent median | candidate median | candidate / parent | parent RSD | candidate RSD |
| --- | ---: | ---: | ---: | ---: | ---: |
| `instructions` | 1357499 | 1353039 | 0.9967x | 0.37% | 4.92% |
| `cycles` | 368728 | 359746 | 0.9756x | 2.85% | 19.40% |
| `energy_joules` | 0 | 0 | NaNx | 264.58% | 264.58% |

Thermal states: `nominal->nominal`. Unmet category metrics: none. Efficiency evidence: `blocked_or_diagnostic`.

All input identities and checksums matched. Missing attribution values are encoded as unavailable with a reason, never as zero.
