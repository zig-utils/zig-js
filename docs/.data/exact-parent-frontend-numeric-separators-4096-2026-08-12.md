# Exact-parent performance A/B — representative_frontend_numeric_separators_4096 (single, 1 lane(s))

- parent: `0a212b51184f6e6e0eeb0ad49ad205ef34ea3f79`
- candidate: `4fdff17b1d8a09a03d5fe4a03e325766eb062c10`
- zig-gc: `89b6652c81ba892119b7b9ce3b0d07fc78a009ff`
- zig-regex: `719673318b0c6250898d7ced3603876c148e370b`
- host class: `diagnostic`
- material-change categories: `cpu_work`
- sampling: 7 order-balanced pairs; no discarded samples
- timed boundary: ten parser-only parse-and-AST-validation jobs over one preconstructed 4,096-literal source after ten one-job warmups; allocation counters are an untimed exact-work replay

| parent median | candidate median | candidate / parent | parent RSD | candidate RSD | assessment |
| ---: | ---: | ---: | ---: | ---: | --- |
| 3.487 ms | 3.091 ms | 0.887x | 3.86% | 3.42% | `diagnostic_only` |

| memory/allocation metric | parent median | candidate median | candidate / parent | parent RSD | candidate RSD |
| --- | ---: | ---: | ---: | ---: | ---: |
| `peak_rss_bytes` | 9797632 | 9732096 | 0.9933x | 0.19% | 0.25% |
| `allocations` | 123250 | 82290 | 0.6677x | 0.00% | 0.00% |
| `allocated_bytes` | 36485920 | 31693600 | 0.8687x | 0.00% | 0.00% |

| efficiency metric | parent median | candidate median | candidate / parent | parent RSD | candidate RSD |
| --- | ---: | ---: | ---: | ---: | ---: |
| `instructions` | 74229609 | 70181926 | 0.9455x | 0.01% | 0.01% |
| `cycles` | 12664596 | 11657530 | 0.9205x | 2.83% | 3.03% |
| `energy_joules` | 0 | 0 | NaNx | NaN% | NaN% |

Thermal states: `nominal->nominal`. Unmet category metrics: none. Efficiency evidence: `blocked_or_diagnostic`.

All input identities and checksums matched. Missing attribution values are encoded as unavailable with a reason, never as zero.
