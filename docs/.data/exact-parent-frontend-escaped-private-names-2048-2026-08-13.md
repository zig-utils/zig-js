# Exact-parent performance A/B — representative_frontend_private_names_escaped_2048 (single, 1 lane(s))

- parent: `d05d9942effd95d9d15c625029fcfbdec65467ee`
- candidate: `364149025b03d96228c22cd7818b1a52b963869b`
- zig-gc: `89b6652c81ba892119b7b9ce3b0d07fc78a009ff`
- zig-regex: `719673318b0c6250898d7ced3603876c148e370b`
- host class: `diagnostic`
- material-change categories: `cpu_work`
- sampling: 7 order-balanced pairs; no discarded samples
- timed boundary: two hundred parser-only parse and exact decoded-private-key validation jobs over one preconstructed 2,048-field escaped-private-class source after ten 20-job warmups; allocation counters are an untimed exact-work replay

| parent median | candidate median | candidate / parent | parent RSD | candidate RSD | assessment |
| ---: | ---: | ---: | ---: | ---: | --- |
| 65.128 ms | 61.058 ms | 0.937x | 11.20% | 20.49% | `diagnostic_only` |

| memory/allocation metric | parent median | candidate median | candidate / parent | parent RSD | candidate RSD |
| --- | ---: | ---: | ---: | ---: | ---: |
| `peak_rss_bytes` | 10698752 | 10665984 | 0.9969x | 5.69% | 0.47% |
| `allocations` | 2057800 | 829000 | 0.4029x | 0.00% | 0.00% |
| `allocated_bytes` | 418150000 | 353280000 | 0.8449x | 0.00% | 0.00% |

| efficiency metric | parent median | candidate median | candidate / parent | parent RSD | candidate RSD |
| --- | ---: | ---: | ---: | ---: | ---: |
| `instructions` | 1083009891 | 973672827 | 0.8990x | 0.10% | 0.11% |
| `cycles` | 221036036 | 206750584 | 0.9354x | 4.92% | 9.03% |
| `energy_joules` | 0.245897249 | 0.221672102 | 0.9015x | 4.98% | 10.12% |

Thermal states: `nominal->nominal`. Unmet category metrics: none. Efficiency evidence: `blocked_or_diagnostic`.

All input identities and checksums matched. Missing attribution values are encoded as unavailable with a reason, never as zero.
