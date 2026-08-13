# Exact-parent performance A/B — representative_frontend_bigint_decimal_separated_4096 (single, 1 lane(s))

- parent: `04dd782e35e05d833d36c9f2a0ddc902c41dec6d`
- candidate: `f91369c6fb7645beb95f01ad52e01f39d99727d3`
- zig-gc: `89b6652c81ba892119b7b9ce3b0d07fc78a009ff`
- zig-regex: `719673318b0c6250898d7ced3603876c148e370b`
- host class: `diagnostic`
- material-change categories: `cpu_work`
- sampling: 7 order-balanced pairs; no discarded samples
- timed boundary: one thousand parser-only parse-and-full-canonical-digit-validation jobs over one preconstructed separated 4,096-digit decimal BigInt source after ten 100-job warmups; allocation counters are an untimed exact-work replay

| parent median | candidate median | candidate / parent | parent RSD | candidate RSD | assessment |
| ---: | ---: | ---: | ---: | ---: | --- |
| 13.114 ms | 13.002 ms | 0.991x | 0.30% | 0.39% | `diagnostic_only` |

| memory/allocation metric | parent median | candidate median | candidate / parent | parent RSD | candidate RSD |
| --- | ---: | ---: | ---: | ---: | ---: |
| `peak_rss_bytes` | 6488064 | 6438912 | 0.9924x | 0.20% | 0.14% |
| `allocations` | 11000 | 10000 | 0.9091x | 0.00% | 0.00% |
| `allocated_bytes` | 10496000 | 6400000 | 0.6098x | 0.00% | 0.00% |

| efficiency metric | parent median | candidate median | candidate / parent | parent RSD | candidate RSD |
| --- | ---: | ---: | ---: | ---: | ---: |
| `instructions` | 265117379 | 263453950 | 0.9937x | 0.01% | 0.01% |
| `cycles` | 48789541 | 48453056 | 0.9931x | 0.16% | 0.21% |
| `energy_joules` | 0.039789033 | 0.039640802 | 0.9963x | 12.52% | 0.59% |

Thermal states: `nominal->nominal`. Unmet category metrics: none. Efficiency evidence: `blocked_or_diagnostic`.

All input identities and checksums matched. Missing attribution values are encoded as unavailable with a reason, never as zero.
