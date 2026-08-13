# Exact-parent performance A/B — representative_frontend_numeric_separators_2048 (single, 1 lane(s))

- parent: `0a212b51184f6e6e0eeb0ad49ad205ef34ea3f79`
- candidate: `4fdff17b1d8a09a03d5fe4a03e325766eb062c10`
- zig-gc: `89b6652c81ba892119b7b9ce3b0d07fc78a009ff`
- zig-regex: `719673318b0c6250898d7ced3603876c148e370b`
- host class: `diagnostic`
- material-change categories: `cpu_work`
- sampling: 7 order-balanced pairs; no discarded samples
- timed boundary: ten parser-only parse-and-AST-validation jobs over one preconstructed 2,048-literal source after ten one-job warmups; allocation counters are an untimed exact-work replay

| parent median | candidate median | candidate / parent | parent RSD | candidate RSD | assessment |
| ---: | ---: | ---: | ---: | ---: | --- |
| 1.814 ms | 1.617 ms | 0.891x | 20.95% | 17.65% | `diagnostic_only` |

| memory/allocation metric | parent median | candidate median | candidate / parent | parent RSD | candidate RSD |
| --- | ---: | ---: | ---: | ---: | ---: |
| `peak_rss_bytes` | 9551872 | 9076736 | 0.9503x | 9.58% | 10.77% |
| `allocations` | 61780 | 41300 | 0.6685x | 0.00% | 0.00% |
| `allocated_bytes` | 16870160 | 14474000 | 0.8580x | 0.00% | 0.00% |

| efficiency metric | parent median | candidate median | candidate / parent | parent RSD | candidate RSD |
| --- | ---: | ---: | ---: | ---: | ---: |
| `instructions` | 37100247 | 35022285 | 0.9440x | 1.28% | 1.09% |
| `cycles` | 6418975 | 5696515 | 0.8874x | 11.70% | 9.35% |
| `energy_joules` | 0.002851774 | 0 | 0.0000x | 103.87% | 172.38% |

Thermal states: `nominal->nominal`. Unmet category metrics: none. Efficiency evidence: `blocked_or_diagnostic`.

All input identities and checksums matched. Missing attribution values are encoded as unavailable with a reason, never as zero.
