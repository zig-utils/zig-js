# Exact-parent performance A/B — representative_json_stringify_shallow_4096 (single, 1 lane(s))

- parent: `4be2bc64c995d43a778294b1b99e1ff07656e1d2`
- candidate: `63d054374b1398ce627c16782748ed9f514d04ec`
- zig-gc: `89b6652c81ba892119b7b9ce3b0d07fc78a009ff`
- zig-regex: `719673318b0c6250898d7ced3603876c148e370b`
- host class: `diagnostic`
- material-change categories: `cpu_work`
- sampling: 7 order-balanced pairs; no discarded samples
- timed boundary: one JSON.stringify invocation of a prebuilt 4096-element shallow array containing the same object reference in every slot after ten one-job warmups; exact length, first leaf offset, and delimiters validated inside the timed invocation

| parent median | candidate median | candidate / parent | parent RSD | candidate RSD | assessment |
| ---: | ---: | ---: | ---: | ---: | --- |
| 2.641 ms | 2.656 ms | 1.006x | 3.77% | 1.65% | `diagnostic_only` |

| memory/allocation metric | parent median | candidate median | candidate / parent | parent RSD | candidate RSD |
| --- | ---: | ---: | ---: | ---: | ---: |
| `peak_rss_bytes` | 62701568 | 62734336 | 1.0005x | 0.05% | 0.06% |

| efficiency metric | parent median | candidate median | candidate / parent | parent RSD | candidate RSD |
| --- | ---: | ---: | ---: | ---: | ---: |
| `instructions` | 47795317 | 48388213 | 1.0124x | 0.11% | 0.06% |
| `cycles` | 9773758 | 9844234 | 1.0072x | 1.10% | 1.32% |
| `energy_joules` | 0 | 0 | NaNx | 182.15% | 264.58% |

Thermal states: `nominal->nominal`. Unmet category metrics: none. Efficiency evidence: `blocked_or_diagnostic`.

All input identities and checksums matched. Missing attribution values are encoded as unavailable with a reason, never as zero.
