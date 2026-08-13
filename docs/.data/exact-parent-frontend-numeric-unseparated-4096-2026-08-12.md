# Exact-parent performance A/B — representative_frontend_numeric_unseparated_4096 (single, 1 lane(s))

- parent: `0a212b51184f6e6e0eeb0ad49ad205ef34ea3f79`
- candidate: `4fdff17b1d8a09a03d5fe4a03e325766eb062c10`
- zig-gc: `89b6652c81ba892119b7b9ce3b0d07fc78a009ff`
- zig-regex: `719673318b0c6250898d7ced3603876c148e370b`
- host class: `diagnostic`
- material-change categories: `cpu_work`
- sampling: 7 order-balanced pairs; no discarded samples
- timed boundary: ten parser-only parse-and-AST-validation jobs over one preconstructed unseparated 4,096-literal source after ten one-job warmups; allocation counters are an untimed exact-work replay

| parent median | candidate median | candidate / parent | parent RSD | candidate RSD | assessment |
| ---: | ---: | ---: | ---: | ---: | --- |
| 2.537 ms | 2.549 ms | 1.005x | 8.85% | 4.38% | `diagnostic_only` |

| memory/allocation metric | parent median | candidate median | candidate / parent | parent RSD | candidate RSD |
| --- | ---: | ---: | ---: | ---: | ---: |
| `peak_rss_bytes` | 8732672 | 8683520 | 0.9944x | 2.69% | 1.36% |
| `allocations` | 41330 | 41330 | 1.0000x | 0.00% | 0.00% |
| `allocated_bytes` | 21795040 | 21795040 | 1.0000x | 0.00% | 0.00% |

| efficiency metric | parent median | candidate median | candidate / parent | parent RSD | candidate RSD |
| --- | ---: | ---: | ---: | ---: | ---: |
| `instructions` | 56547611 | 55007756 | 0.9728x | 0.23% | 0.07% |
| `cycles` | 9024160 | 8966018 | 0.9936x | 3.00% | 1.65% |
| `energy_joules` | 0 | 0 | NaNx | 264.58% | NaN% |

Thermal states: `nominal->nominal`. Unmet category metrics: none. Efficiency evidence: `blocked_or_diagnostic`.

All input identities and checksums matched. Missing attribution values are encoded as unavailable with a reason, never as zero.
