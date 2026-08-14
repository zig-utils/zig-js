# Exact-parent performance A/B — representative_json_stringify_depth_2048 (single, 1 lane(s))

- parent: `4be2bc64c995d43a778294b1b99e1ff07656e1d2`
- candidate: `63d054374b1398ce627c16782748ed9f514d04ec`
- zig-gc: `89b6652c81ba892119b7b9ce3b0d07fc78a009ff`
- zig-regex: `719673318b0c6250898d7ced3603876c148e370b`
- host class: `diagnostic`
- material-change categories: `cpu_work`
- sampling: 7 order-balanced pairs; no discarded samples
- timed boundary: one JSON.stringify invocation of a prebuilt depth-2048 object chain after ten one-job warmups; exact length, leaf offset, and delimiters validated inside the timed invocation

| parent median | candidate median | candidate / parent | parent RSD | candidate RSD | assessment |
| ---: | ---: | ---: | ---: | ---: | --- |
| 5.992 ms | 5.595 ms | 0.934x | 11.77% | 3.11% | `diagnostic_only` |

| memory/allocation metric | parent median | candidate median | candidate / parent | parent RSD | candidate RSD |
| --- | ---: | ---: | ---: | ---: | ---: |
| `peak_rss_bytes` | 664207360 | 665190400 | 1.0015x | 0.00% | 0.01% |

| efficiency metric | parent median | candidate median | candidate / parent | parent RSD | candidate RSD |
| --- | ---: | ---: | ---: | ---: | ---: |
| `instructions` | 64189683 | 55900332 | 0.8709x | 0.88% | 0.36% |
| `cycles` | 21294658 | 19904376 | 0.9347x | 5.19% | 2.20% |
| `energy_joules` | 0.013946484 | 0.007407022 | 0.5311x | 92.30% | 98.87% |

Thermal states: `nominal->nominal`. Unmet category metrics: none. Efficiency evidence: `blocked_or_diagnostic`.

All input identities and checksums matched. Missing attribution values are encoded as unavailable with a reason, never as zero.
