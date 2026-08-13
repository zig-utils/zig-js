# Exact-parent performance A/B — representative_frontend_templates_normalized_1024 (single, 1 lane(s))

- parent: `48556702fec31b7cd59bdc45f8323ef33bf4e6e7`
- candidate: `ab8c6d9eb5ad5d7f655e6c046cef9d30d410c532`
- zig-gc: `89b6652c81ba892119b7b9ce3b0d07fc78a009ff`
- zig-regex: `719673318b0c6250898d7ced3603876c148e370b`
- host class: `diagnostic`
- material-change categories: `cpu_work`
- sampling: 7 order-balanced pairs; no discarded samples
- timed boundary: two hundred parser-only parse and exact normalized-template validation jobs over one preconstructed 1,024-template mixed-CRLF/lone-CR source after ten 20-job warmups; allocation counters are an untimed exact-work replay

| parent median | candidate median | candidate / parent | parent RSD | candidate RSD | assessment |
| ---: | ---: | ---: | ---: | ---: | --- |
| 40.209 ms | 36.143 ms | 0.899x | 3.48% | 3.90% | `diagnostic_only` |

| memory/allocation metric | parent median | candidate median | candidate / parent | parent RSD | candidate RSD |
| --- | ---: | ---: | ---: | ---: | ---: |
| `peak_rss_bytes` | 8421376 | 8224768 | 0.9767x | 0.18% | 0.66% |
| `allocations` | 415800 | 415800 | 1.0000x | 0.00% | 0.00% |
| `allocated_bytes` | 151830400 | 137272400 | 0.9041x | 0.00% | 0.00% |

| efficiency metric | parent median | candidate median | candidate / parent | parent RSD | candidate RSD |
| --- | ---: | ---: | ---: | ---: | ---: |
| `instructions` | 779337313 | 717425840 | 0.9206x | 0.07% | 0.06% |
| `cycles` | 139576752 | 127475541 | 0.9133x | 1.36% | 1.57% |
| `energy_joules` | 0.152973529 | 0.147880908 | 0.9667x | 2.10% | 4.50% |

Thermal states: `nominal->nominal`. Unmet category metrics: none. Efficiency evidence: `stable`.

All input identities and checksums matched. Missing attribution values are encoded as unavailable with a reason, never as zero.
