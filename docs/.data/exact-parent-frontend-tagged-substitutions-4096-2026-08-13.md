# Exact-parent performance A/B — representative_frontend_templates_tagged_substitutions_4096 (single, 1 lane(s))

- parent: `efa336aa0724cbd7e85c28ebe124734c0e76279f`
- candidate: `c3449e6b007a13c12525c13818af0a55d423eb67`
- zig-gc: `89b6652c81ba892119b7b9ce3b0d07fc78a009ff`
- zig-regex: `719673318b0c6250898d7ced3603876c148e370b`
- host class: `diagnostic`
- material-change categories: `cpu_work`
- sampling: 7 order-balanced pairs; no discarded samples
- timed boundary: two hundred parser-only parse and exact per-quasi/per-expression validation jobs over one preconstructed tagged template with 4,096 substitutions after ten 20-job warmups; allocation counters are an untimed exact-work replay

| parent median | candidate median | candidate / parent | parent RSD | candidate RSD | assessment |
| ---: | ---: | ---: | ---: | ---: | --- |
| 131.400 ms | 132.740 ms | 1.010x | 12.06% | 32.85% | `diagnostic_only` |

| memory/allocation metric | parent median | candidate median | candidate / parent | parent RSD | candidate RSD |
| --- | ---: | ---: | ---: | ---: | ---: |
| `peak_rss_bytes` | 10715136 | 9404416 | 0.8777x | 8.84% | 7.58% |
| `allocations` | 1648400 | 1641000 | 0.9955x | 0.00% | 0.00% |
| `allocated_bytes` | 345382400 | 282230400 | 0.8172x | 0.00% | 0.00% |

| efficiency metric | parent median | candidate median | candidate / parent | parent RSD | candidate RSD |
| --- | ---: | ---: | ---: | ---: | ---: |
| `instructions` | 2494483254 | 2461482634 | 0.9868x | 0.07% | 0.25% |
| `cycles` | 476051433 | 469449854 | 0.9861x | 3.49% | 6.28% |
| `energy_joules` | 0.565666192 | 0.534459118 | 0.9448x | 1.17% | 4.60% |

Thermal states: `nominal->nominal`. Unmet category metrics: none. Efficiency evidence: `blocked_or_diagnostic`.

All input identities and checksums matched. Missing attribution values are encoded as unavailable with a reason, never as zero.
