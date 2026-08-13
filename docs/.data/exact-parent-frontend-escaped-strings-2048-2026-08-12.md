# Exact-parent performance A/B — representative_frontend_strings_escaped_2048 (single, 1 lane(s))

- parent: `44d584817521be0c8011c5f09b29a87cadab3ff9`
- candidate: `3ca764e2867e891bcd4158213f2769aac217e732`
- zig-gc: `89b6652c81ba892119b7b9ce3b0d07fc78a009ff`
- zig-regex: `719673318b0c6250898d7ced3603876c148e370b`
- host class: `diagnostic`
- material-change categories: `cpu_work`
- sampling: 7 order-balanced pairs; no discarded samples
- timed boundary: two hundred parser-only parse and exact decoded-string validation jobs over one preconstructed 2,048-literal escaped-string source after ten 20-job warmups; allocation counters are an untimed exact-work replay

| parent median | candidate median | candidate / parent | parent RSD | candidate RSD | assessment |
| ---: | ---: | ---: | ---: | ---: | --- |
| 43.934 ms | 43.541 ms | 0.991x | 9.00% | 8.28% | `diagnostic_only` |

| memory/allocation metric | parent median | candidate median | candidate / parent | parent RSD | candidate RSD |
| --- | ---: | ---: | ---: | ---: | ---: |
| `peak_rss_bytes` | 10928128 | 10944512 | 1.0015x | 3.57% | 0.78% |
| `allocations` | 1235600 | 826000 | 0.6685x | 0.00% | 0.00% |
| `allocated_bytes` | 337403200 | 304413200 | 0.9022x | 0.00% | 0.00% |

| efficiency metric | parent median | candidate median | candidate / parent | parent RSD | candidate RSD |
| --- | ---: | ---: | ---: | ---: | ---: |
| `instructions` | 920380605 | 895035106 | 0.9725x | 0.06% | 0.11% |
| `cycles` | 151995567 | 151736550 | 0.9983x | 3.85% | 2.42% |
| `energy_joules` | 0.179681165 | 0.162665956 | 0.9053x | 5.95% | 8.87% |

Thermal states: `nominal->nominal`. Unmet category metrics: none. Efficiency evidence: `blocked_or_diagnostic`.

All input identities and checksums matched. Missing attribution values are encoded as unavailable with a reason, never as zero.
