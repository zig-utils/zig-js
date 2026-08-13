# Exact-parent performance A/B — representative_frontend_bigint_decimal_2048 (single, 1 lane(s))

- parent: `04dd782e35e05d833d36c9f2a0ddc902c41dec6d`
- candidate: `f91369c6fb7645beb95f01ad52e01f39d99727d3`
- zig-gc: `89b6652c81ba892119b7b9ce3b0d07fc78a009ff`
- zig-regex: `719673318b0c6250898d7ced3603876c148e370b`
- host class: `diagnostic`
- material-change categories: `cpu_work`
- sampling: 7 order-balanced pairs; no discarded samples
- timed boundary: one thousand parser-only parse-and-full-canonical-digit-validation jobs over one preconstructed 2,048-digit decimal BigInt source after ten 100-job warmups; allocation counters are an untimed exact-work replay

| parent median | candidate median | candidate / parent | parent RSD | candidate RSD | assessment |
| ---: | ---: | ---: | ---: | ---: | --- |
| 4.797 ms | 4.699 ms | 0.979x | 1.60% | 2.01% | `diagnostic_only` |

| memory/allocation metric | parent median | candidate median | candidate / parent | parent RSD | candidate RSD |
| --- | ---: | ---: | ---: | ---: | ---: |
| `peak_rss_bytes` | 6438912 | 6422528 | 0.9975x | 0.28% | 0.19% |
| `allocations` | 10000 | 9000 | 0.9000x | 0.00% | 0.00% |
| `allocated_bytes` | 4352000 | 1824000 | 0.4191x | 0.00% | 0.00% |

| efficiency metric | parent median | candidate median | candidate / parent | parent RSD | candidate RSD |
| --- | ---: | ---: | ---: | ---: | ---: |
| `instructions` | 87377540 | 86573509 | 0.9908x | 0.02% | 0.04% |
| `cycles` | 17376516 | 17195106 | 0.9896x | 0.21% | 0.48% |
| `energy_joules` | 0 | 0.000005287 | Infinityx | 162.83% | 125.93% |

Thermal states: `nominal->nominal`. Unmet category metrics: none. Efficiency evidence: `blocked_or_diagnostic`.

All input identities and checksums matched. Missing attribution values are encoded as unavailable with a reason, never as zero.
