# Exact-parent performance A/B — representative_frontend_strings_escaped_1024 (single, 1 lane(s))

- parent: `44d584817521be0c8011c5f09b29a87cadab3ff9`
- candidate: `3ca764e2867e891bcd4158213f2769aac217e732`
- zig-gc: `89b6652c81ba892119b7b9ce3b0d07fc78a009ff`
- zig-regex: `719673318b0c6250898d7ced3603876c148e370b`
- host class: `diagnostic`
- material-change categories: `cpu_work`
- sampling: 7 order-balanced pairs; no discarded samples
- timed boundary: two hundred parser-only parse and exact decoded-string validation jobs over one preconstructed 1,024-literal escaped-string source after ten 20-job warmups; allocation counters are an untimed exact-work replay

| parent median | candidate median | candidate / parent | parent RSD | candidate RSD | assessment |
| ---: | ---: | ---: | ---: | ---: | --- |
| 25.520 ms | 23.815 ms | 0.933x | 9.68% | 11.29% | `diagnostic_only` |

| memory/allocation metric | parent median | candidate median | candidate / parent | parent RSD | candidate RSD |
| --- | ---: | ---: | ---: | ---: | ---: |
| `peak_rss_bytes` | 8994816 | 8994816 | 1.0000x | 0.39% | 0.64% |
| `allocations` | 620600 | 415800 | 0.6700x | 0.00% | 0.00% |
| `allocated_bytes` | 206915200 | 190309200 | 0.9197x | 0.00% | 0.00% |

| efficiency metric | parent median | candidate median | candidate / parent | parent RSD | candidate RSD |
| --- | ---: | ---: | ---: | ---: | ---: |
| `instructions` | 465916263 | 451289783 | 0.9686x | 0.11% | 0.11% |
| `cycles` | 83309196 | 79985308 | 0.9601x | 4.28% | 5.33% |
| `energy_joules` | 0.092962994 | 0.085410435 | 0.9188x | 6.47% | 10.19% |

Thermal states: `nominal->nominal`. Unmet category metrics: none. Efficiency evidence: `blocked_or_diagnostic`.

All input identities and checksums matched. Missing attribution values are encoded as unavailable with a reason, never as zero.
