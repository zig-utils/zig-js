# Exact-parent performance A/B — representative_frontend_bigint_decimal_4096 (single, 1 lane(s))

- parent: `04dd782e35e05d833d36c9f2a0ddc902c41dec6d`
- candidate: `f91369c6fb7645beb95f01ad52e01f39d99727d3`
- zig-gc: `89b6652c81ba892119b7b9ce3b0d07fc78a009ff`
- zig-regex: `719673318b0c6250898d7ced3603876c148e370b`
- host class: `diagnostic`
- material-change categories: `cpu_work`
- sampling: 7 order-balanced pairs; no discarded samples
- timed boundary: one thousand parser-only parse-and-full-canonical-digit-validation jobs over one preconstructed 4,096-digit decimal BigInt source after ten 100-job warmups; allocation counters are an untimed exact-work replay

| parent median | candidate median | candidate / parent | parent RSD | candidate RSD | assessment |
| ---: | ---: | ---: | ---: | ---: | --- |
| 8.916 ms | 9.087 ms | 1.019x | 1.27% | 0.90% | `diagnostic_only` |

| memory/allocation metric | parent median | candidate median | candidate / parent | parent RSD | candidate RSD |
| --- | ---: | ---: | ---: | ---: | ---: |
| `peak_rss_bytes` | 6455296 | 6422528 | 0.9949x | 0.31% | 0.25% |
| `allocations` | 10000 | 9000 | 0.9000x | 0.00% | 0.00% |
| `allocated_bytes` | 6400000 | 1824000 | 0.2850x | 0.00% | 0.00% |

| efficiency metric | parent median | candidate median | candidate / parent | parent RSD | candidate RSD |
| --- | ---: | ---: | ---: | ---: | ---: |
| `instructions` | 166662685 | 165509344 | 0.9931x | 0.02% | 0.03% |
| `cycles` | 32896364 | 32868205 | 0.9991x | 1.56% | 0.22% |
| `energy_joules` | 0.00170191 | 0.024714058 | 14.5214x | 158.01% | 58.42% |

Thermal states: `nominal->nominal`. Unmet category metrics: none. Efficiency evidence: `blocked_or_diagnostic`.

All input identities and checksums matched. Missing attribution values are encoded as unavailable with a reason, never as zero.
