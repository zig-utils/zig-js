# Exact-parent performance A/B — representative_frontend_bigint_decimal_1024 (single, 1 lane(s))

- parent: `04dd782e35e05d833d36c9f2a0ddc902c41dec6d`
- candidate: `f91369c6fb7645beb95f01ad52e01f39d99727d3`
- zig-gc: `89b6652c81ba892119b7b9ce3b0d07fc78a009ff`
- zig-regex: `719673318b0c6250898d7ced3603876c148e370b`
- host class: `diagnostic`
- material-change categories: `cpu_work`
- sampling: 7 order-balanced pairs; no discarded samples
- timed boundary: one thousand parser-only parse-and-full-canonical-digit-validation jobs over one preconstructed 1,024-digit decimal BigInt source after ten 100-job warmups; allocation counters are an untimed exact-work replay

| parent median | candidate median | candidate / parent | parent RSD | candidate RSD | assessment |
| ---: | ---: | ---: | ---: | ---: | --- |
| 2.583 ms | 2.570 ms | 0.995x | 1.86% | 2.07% | `diagnostic_only` |

| memory/allocation metric | parent median | candidate median | candidate / parent | parent RSD | candidate RSD |
| --- | ---: | ---: | ---: | ---: | ---: |
| `peak_rss_bytes` | 6438912 | 6422528 | 0.9975x | 0.25% | 0.23% |
| `allocations` | 10000 | 9000 | 0.9000x | 0.00% | 0.00% |
| `allocated_bytes` | 3328000 | 1824000 | 0.5481x | 0.00% | 0.00% |

| efficiency metric | parent median | candidate median | candidate / parent | parent RSD | candidate RSD |
| --- | ---: | ---: | ---: | ---: | ---: |
| `instructions` | 47539622 | 47081802 | 0.9904x | 0.06% | 0.06% |
| `cycles` | 9454290 | 9405410 | 0.9948x | 0.80% | 0.55% |
| `energy_joules` | 0 | 0 | NaNx | 259.84% | 219.12% |

Thermal states: `nominal->nominal`. Unmet category metrics: none. Efficiency evidence: `blocked_or_diagnostic`.

All input identities and checksums matched. Missing attribution values are encoded as unavailable with a reason, never as zero.
