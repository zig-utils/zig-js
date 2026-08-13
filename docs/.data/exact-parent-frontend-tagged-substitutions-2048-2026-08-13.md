# Exact-parent performance A/B — representative_frontend_templates_tagged_substitutions_2048 (single, 1 lane(s))

- parent: `efa336aa0724cbd7e85c28ebe124734c0e76279f`
- candidate: `c3449e6b007a13c12525c13818af0a55d423eb67`
- zig-gc: `89b6652c81ba892119b7b9ce3b0d07fc78a009ff`
- zig-regex: `719673318b0c6250898d7ced3603876c148e370b`
- host class: `diagnostic`
- material-change categories: `cpu_work`
- sampling: 7 order-balanced pairs; no discarded samples
- timed boundary: two hundred parser-only parse and exact per-quasi/per-expression validation jobs over one preconstructed tagged template with 2,048 substitutions after ten 20-job warmups; allocation counters are an untimed exact-work replay

| parent median | candidate median | candidate / parent | parent RSD | candidate RSD | assessment |
| ---: | ---: | ---: | ---: | ---: | --- |
| 63.027 ms | 61.645 ms | 0.978x | 0.87% | 0.28% | `diagnostic_only` |

| memory/allocation metric | parent median | candidate median | candidate / parent | parent RSD | candidate RSD |
| --- | ---: | ---: | ---: | ---: | ---: |
| `peak_rss_bytes` | 7831552 | 7602176 | 0.9707x | 2.35% | 1.67% |
| `allocations` | 828200 | 821800 | 0.9923x | 0.00% | 0.00% |
| `allocated_bytes` | 169572800 | 141328000 | 0.8334x | 0.00% | 0.00% |

| efficiency metric | parent median | candidate median | candidate / parent | parent RSD | candidate RSD |
| --- | ---: | ---: | ---: | ---: | ---: |
| `instructions` | 1237291798 | 1219721620 | 0.9858x | 0.01% | 0.01% |
| `cycles` | 235161990 | 230361848 | 0.9796x | 0.73% | 0.41% |
| `energy_joules` | 0.271808221 | 0.270376951 | 0.9947x | 4.72% | 2.91% |

Thermal states: `nominal->nominal`. Unmet category metrics: none. Efficiency evidence: `stable`.

All input identities and checksums matched. Missing attribution values are encoded as unavailable with a reason, never as zero.
