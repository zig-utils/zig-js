# Exact-parent performance A/B — representative_json_stringify_depth_4096 (single, 1 lane(s))

- parent: `4be2bc64c995d43a778294b1b99e1ff07656e1d2`
- candidate: `63d054374b1398ce627c16782748ed9f514d04ec`
- zig-gc: `89b6652c81ba892119b7b9ce3b0d07fc78a009ff`
- zig-regex: `719673318b0c6250898d7ced3603876c148e370b`
- host class: `diagnostic`
- material-change categories: `cpu_work`
- sampling: 7 order-balanced pairs; no discarded samples
- timed boundary: one JSON.stringify invocation of a prebuilt depth-4096 object chain after ten one-job warmups; exact length, leaf offset, and delimiters validated inside the timed invocation

| parent median | candidate median | candidate / parent | parent RSD | candidate RSD | assessment |
| ---: | ---: | ---: | ---: | ---: | --- |
| 19.916 ms | 18.131 ms | 0.910x | 55.79% | 63.93% | `diagnostic_only` |

| memory/allocation metric | parent median | candidate median | candidate / parent | parent RSD | candidate RSD |
| --- | ---: | ---: | ---: | ---: | ---: |
| `peak_rss_bytes` | 2546630656 | 2548858880 | 1.0009x | 11.18% | 0.00% |

| efficiency metric | parent median | candidate median | candidate / parent | parent RSD | candidate RSD |
| --- | ---: | ---: | ---: | ---: | ---: |
| `instructions` | 216536198 | 178683094 | 0.8252x | 2.17% | 3.08% |
| `cycles` | 71617319 | 64629817 | 0.9024x | 11.03% | 11.54% |
| `energy_joules` | 0.064965086 | 0.056606344 | 0.8713x | 22.90% | 25.57% |

Thermal states: `nominal->nominal`. Unmet category metrics: none. Efficiency evidence: `blocked_or_diagnostic`.

All input identities and checksums matched. Missing attribution values are encoded as unavailable with a reason, never as zero.
