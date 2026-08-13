# Exact-parent performance A/B — representative_frontend_templates_tagged_substitutions_1024 (single, 1 lane(s))

- parent: `efa336aa0724cbd7e85c28ebe124734c0e76279f`
- candidate: `c3449e6b007a13c12525c13818af0a55d423eb67`
- zig-gc: `89b6652c81ba892119b7b9ce3b0d07fc78a009ff`
- zig-regex: `719673318b0c6250898d7ced3603876c148e370b`
- host class: `diagnostic`
- material-change categories: `cpu_work`
- sampling: 7 order-balanced pairs; no discarded samples
- timed boundary: two hundred parser-only parse and exact per-quasi/per-expression validation jobs over one preconstructed tagged template with 1,024 substitutions after ten 20-job warmups; allocation counters are an untimed exact-work replay

| parent median | candidate median | candidate / parent | parent RSD | candidate RSD | assessment |
| ---: | ---: | ---: | ---: | ---: | --- |
| 31.637 ms | 31.042 ms | 0.981x | 0.64% | 0.93% | `diagnostic_only` |

| memory/allocation metric | parent median | candidate median | candidate / parent | parent RSD | candidate RSD |
| --- | ---: | ---: | ---: | ---: | ---: |
| `peak_rss_bytes` | 7159808 | 7061504 | 0.9863x | 1.00% | 1.66% |
| `allocations` | 417400 | 412200 | 0.9875x | 0.00% | 0.00% |
| `allocated_bytes` | 80697600 | 70876800 | 0.8783x | 0.00% | 0.00% |

| efficiency metric | parent median | candidate median | candidate / parent | parent RSD | candidate RSD |
| --- | ---: | ---: | ---: | ---: | ---: |
| `instructions` | 608513598 | 599886538 | 0.9858x | 0.01% | 0.02% |
| `cycles` | 115314118 | 113470932 | 0.9840x | 0.55% | 0.50% |
| `energy_joules` | 0.119272478 | 0.124431181 | 1.0433x | 10.07% | 11.00% |

Thermal states: `nominal->nominal`. Unmet category metrics: none. Efficiency evidence: `blocked_or_diagnostic`.

All input identities and checksums matched. Missing attribution values are encoded as unavailable with a reason, never as zero.
