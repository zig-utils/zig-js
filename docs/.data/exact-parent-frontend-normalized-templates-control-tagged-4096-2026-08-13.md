# Exact-parent performance A/B — representative_frontend_templates_normalized_tagged_4096 (single, 1 lane(s))

- parent: `48556702fec31b7cd59bdc45f8323ef33bf4e6e7`
- candidate: `ab8c6d9eb5ad5d7f655e6c046cef9d30d410c532`
- zig-gc: `89b6652c81ba892119b7b9ce3b0d07fc78a009ff`
- zig-regex: `719673318b0c6250898d7ced3603876c148e370b`
- host class: `diagnostic`
- material-change categories: `cpu_work`
- sampling: 7 order-balanced pairs; no discarded samples
- timed boundary: two hundred parser-only parse and exact tagged raw/cooked normalized-template validation jobs over one preconstructed 4,096-template mixed-CRLF/lone-CR source after ten 20-job warmups; allocation counters are an untimed exact-work replay

| parent median | candidate median | candidate / parent | parent RSD | candidate RSD | assessment |
| ---: | ---: | ---: | ---: | ---: | --- |
| 243.634 ms | 223.933 ms | 0.919x | 2.96% | 3.52% | `diagnostic_only` |

| memory/allocation metric | parent median | candidate median | candidate / parent | parent RSD | candidate RSD |
| --- | ---: | ---: | ---: | ---: | ---: |
| `peak_rss_bytes` | 11878400 | 11599872 | 0.9766x | 0.25% | 0.74% |
| `allocations` | 4103600 | 4103600 | 1.0000x | 0.00% | 0.00% |
| `allocated_bytes` | 723260800 | 665694800 | 0.9204x | 0.00% | 0.00% |

| efficiency metric | parent median | candidate median | candidate / parent | parent RSD | candidate RSD |
| --- | ---: | ---: | ---: | ---: | ---: |
| `instructions` | 4447891009 | 4196362656 | 0.9434x | 0.06% | 0.06% |
| `cycles` | 834445060 | 782121054 | 0.9373x | 1.23% | 1.18% |
| `energy_joules` | 0.905589383 | 0.882746699 | 0.9748x | 1.11% | 1.06% |

Thermal states: `nominal->nominal`. Unmet category metrics: none. Efficiency evidence: `stable`.

All input identities and checksums matched. Missing attribution values are encoded as unavailable with a reason, never as zero.
