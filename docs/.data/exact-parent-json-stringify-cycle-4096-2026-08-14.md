# Exact-parent performance A/B — representative_json_stringify_cycle_4096 (single, 1 lane(s))

- parent: `4be2bc64c995d43a778294b1b99e1ff07656e1d2`
- candidate: `63d054374b1398ce627c16782748ed9f514d04ec`
- zig-gc: `89b6652c81ba892119b7b9ce3b0d07fc78a009ff`
- zig-regex: `719673318b0c6250898d7ced3603876c148e370b`
- host class: `diagnostic`
- material-change categories: `cpu_work`
- sampling: 7 order-balanced pairs; no discarded samples
- timed boundary: one JSON.stringify invocation of a prebuilt depth-4096 object chain with a leaf-to-root back-edge after ten one-job warmups; exact TypeError validated inside the timed invocation

| parent median | candidate median | candidate / parent | parent RSD | candidate RSD | assessment |
| ---: | ---: | ---: | ---: | ---: | --- |
| 3.823 ms | 1.612 ms | 0.422x | 19.82% | 4.25% | `diagnostic_only` |

| memory/allocation metric | parent median | candidate median | candidate / parent | parent RSD | candidate RSD |
| --- | ---: | ---: | ---: | ---: | ---: |
| `peak_rss_bytes` | 54034432 | 56606720 | 1.0476x | 0.08% | 0.06% |

| efficiency metric | parent median | candidate median | candidate / parent | parent RSD | candidate RSD |
| --- | ---: | ---: | ---: | ---: | ---: |
| `instructions` | 59457654 | 21927790 | 0.3688x | 0.24% | 1.18% |
| `cycles` | 13822423 | 5953301 | 0.4307x | 19.94% | 4.11% |
| `energy_joules` | 0 | 0 | NaNx | NaN% | NaN% |

Thermal states: `nominal->nominal`. Unmet category metrics: none. Efficiency evidence: `blocked_or_diagnostic`.

All input identities and checksums matched. Missing attribution values are encoded as unavailable with a reason, never as zero.
