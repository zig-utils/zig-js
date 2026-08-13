# Exact-parent performance A/B — representative_frontend_strings_escaped_4096 (single, 1 lane(s))

- parent: `44d584817521be0c8011c5f09b29a87cadab3ff9`
- candidate: `3ca764e2867e891bcd4158213f2769aac217e732`
- zig-gc: `89b6652c81ba892119b7b9ce3b0d07fc78a009ff`
- zig-regex: `719673318b0c6250898d7ced3603876c148e370b`
- host class: `diagnostic`
- material-change categories: `cpu_work`
- sampling: 7 order-balanced pairs; no discarded samples
- timed boundary: two hundred parser-only parse and exact decoded-string validation jobs over one preconstructed 4,096-literal escaped-string source after ten 20-job warmups; allocation counters are an untimed exact-work replay

| parent median | candidate median | candidate / parent | parent RSD | candidate RSD | assessment |
| ---: | ---: | ---: | ---: | ---: | --- |
| 142.332 ms | 134.644 ms | 0.946x | 5.14% | 6.34% | `diagnostic_only` |

| memory/allocation metric | parent median | candidate median | candidate / parent | parent RSD | candidate RSD |
| --- | ---: | ---: | ---: | ---: | ---: |
| `peak_rss_bytes` | 13647872 | 13664256 | 1.0012x | 0.27% | 0.24% |
| `allocations` | 2465000 | 1645800 | 0.6677x | 0.00% | 0.00% |
| `allocated_bytes` | 729718400 | 663960400 | 0.9099x | 0.00% | 0.00% |

| efficiency metric | parent median | candidate median | candidate / parent | parent RSD | candidate RSD |
| --- | ---: | ---: | ---: | ---: | ---: |
| `instructions` | 1866125490 | 1818004343 | 0.9742x | 0.17% | 0.15% |
| `cycles` | 369506616 | 363998688 | 0.9851x | 2.91% | 3.56% |
| `energy_joules` | 0.331044884 | 0.32648261 | 0.9862x | 5.02% | 6.39% |

Thermal states: `nominal->nominal`. Unmet category metrics: none. Efficiency evidence: `blocked_or_diagnostic`.

All input identities and checksums matched. Missing attribution values are encoded as unavailable with a reason, never as zero.
