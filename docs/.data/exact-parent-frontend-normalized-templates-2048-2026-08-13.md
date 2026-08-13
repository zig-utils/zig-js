# Exact-parent performance A/B — representative_frontend_templates_normalized_2048 (single, 1 lane(s))

- parent: `48556702fec31b7cd59bdc45f8323ef33bf4e6e7`
- candidate: `ab8c6d9eb5ad5d7f655e6c046cef9d30d410c532`
- zig-gc: `89b6652c81ba892119b7b9ce3b0d07fc78a009ff`
- zig-regex: `719673318b0c6250898d7ced3603876c148e370b`
- host class: `diagnostic`
- material-change categories: `cpu_work`
- sampling: 7 order-balanced pairs; no discarded samples
- timed boundary: two hundred parser-only parse and exact normalized-template validation jobs over one preconstructed 2,048-template mixed-CRLF/lone-CR source after ten 20-job warmups; allocation counters are an untimed exact-work replay

| parent median | candidate median | candidate / parent | parent RSD | candidate RSD | assessment |
| ---: | ---: | ---: | ---: | ---: | --- |
| 74.082 ms | 68.418 ms | 0.924x | 3.19% | 1.07% | `diagnostic_only` |

| memory/allocation metric | parent median | candidate median | candidate / parent | parent RSD | candidate RSD |
| --- | ---: | ---: | ---: | ---: | ---: |
| `peak_rss_bytes` | 8142848 | 8994816 | 1.1046x | 7.09% | 5.34% |
| `allocations` | 826000 | 826000 | 1.0000x | 0.00% | 0.00% |
| `allocated_bytes` | 229115200 | 200221200 | 0.8739x | 0.00% | 0.00% |

| efficiency metric | parent median | candidate median | candidate / parent | parent RSD | candidate RSD |
| --- | ---: | ---: | ---: | ---: | ---: |
| `instructions` | 1560053651 | 1434257957 | 0.9194x | 0.05% | 0.02% |
| `cycles` | 269785635 | 248654991 | 0.9217x | 1.39% | 0.66% |
| `energy_joules` | 0.302423814 | 0.285584473 | 0.9443x | 2.81% | 4.65% |

Thermal states: `nominal->nominal`. Unmet category metrics: none. Efficiency evidence: `stable`.

All input identities and checksums matched. Missing attribution values are encoded as unavailable with a reason, never as zero.
