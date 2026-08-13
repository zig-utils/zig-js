# Exact-parent performance A/B — representative_frontend_numeric_separators_1024 (single, 1 lane(s))

- parent: `0a212b51184f6e6e0eeb0ad49ad205ef34ea3f79`
- candidate: `4fdff17b1d8a09a03d5fe4a03e325766eb062c10`
- zig-gc: `89b6652c81ba892119b7b9ce3b0d07fc78a009ff`
- zig-regex: `719673318b0c6250898d7ced3603876c148e370b`
- host class: `diagnostic`
- material-change categories: `cpu_work`
- sampling: 7 order-balanced pairs; no discarded samples
- timed boundary: ten parser-only parse-and-AST-validation jobs over one preconstructed 1,024-literal source after ten one-job warmups; allocation counters are an untimed exact-work replay

| parent median | candidate median | candidate / parent | parent RSD | candidate RSD | assessment |
| ---: | ---: | ---: | ---: | ---: | --- |
| 0.944 ms | 0.869 ms | 0.920x | 3.12% | 36.81% | `diagnostic_only` |

| memory/allocation metric | parent median | candidate median | candidate / parent | parent RSD | candidate RSD |
| --- | ---: | ---: | ---: | ---: | ---: |
| `peak_rss_bytes` | 7438336 | 7405568 | 0.9956x | 7.02% | 7.07% |
| `allocations` | 31030 | 20790 | 0.6700x | 0.00% | 0.00% |
| `allocated_bytes` | 10345760 | 9147680 | 0.8842x | 0.00% | 0.00% |

| efficiency metric | parent median | candidate median | candidate / parent | parent RSD | candidate RSD |
| --- | ---: | ---: | ---: | ---: | ---: |
| `instructions` | 18852145 | 17838992 | 0.9463x | 0.06% | 1.68% |
| `cycles` | 3358491 | 3080609 | 0.9173x | 2.23% | 21.61% |
| `energy_joules` | 0 | 0 | NaNx | 183.03% | 175.49% |

Thermal states: `nominal->nominal`. Unmet category metrics: none. Efficiency evidence: `blocked_or_diagnostic`.

All input identities and checksums matched. Missing attribution values are encoded as unavailable with a reason, never as zero.
