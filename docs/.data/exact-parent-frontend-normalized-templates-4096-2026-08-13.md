# Exact-parent performance A/B — representative_frontend_templates_normalized_4096 (single, 1 lane(s))

- parent: `48556702fec31b7cd59bdc45f8323ef33bf4e6e7`
- candidate: `ab8c6d9eb5ad5d7f655e6c046cef9d30d410c532`
- zig-gc: `89b6652c81ba892119b7b9ce3b0d07fc78a009ff`
- zig-regex: `719673318b0c6250898d7ced3603876c148e370b`
- host class: `diagnostic`
- material-change categories: `cpu_work`
- sampling: 7 order-balanced pairs; no discarded samples
- timed boundary: two hundred parser-only parse and exact normalized-template validation jobs over one preconstructed 4,096-template mixed-CRLF/lone-CR source after ten 20-job warmups; allocation counters are an untimed exact-work replay

| parent median | candidate median | candidate / parent | parent RSD | candidate RSD | assessment |
| ---: | ---: | ---: | ---: | ---: | --- |
| 159.458 ms | 141.139 ms | 0.885x | 3.87% | 7.36% | `diagnostic_only` |

| memory/allocation metric | parent median | candidate median | candidate / parent | parent RSD | candidate RSD |
| --- | ---: | ---: | ---: | ---: | ---: |
| `peak_rss_bytes` | 11059200 | 10764288 | 0.9733x | 0.76% | 0.29% |
| `allocations` | 1645800 | 1645800 | 1.0000x | 0.00% | 0.00% |
| `allocated_bytes` | 541577600 | 484011600 | 0.8937x | 0.00% | 0.00% |

| efficiency metric | parent median | candidate median | candidate / parent | parent RSD | candidate RSD |
| --- | ---: | ---: | ---: | ---: | ---: |
| `instructions` | 3143410180 | 2883612017 | 0.9174x | 0.07% | 0.09% |
| `cycles` | 557026315 | 504792145 | 0.9062x | 1.53% | 2.46% |
| `energy_joules` | 0.616436784 | 0.590625644 | 0.9581x | 1.31% | 2.09% |

Thermal states: `nominal->nominal`. Unmet category metrics: none. Efficiency evidence: `stable`.

All input identities and checksums matched. Missing attribution values are encoded as unavailable with a reason, never as zero.
