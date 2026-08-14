# Exact-parent performance A/B — representative_json_stringify_depth_512 (single, 1 lane(s))

- parent: `4be2bc64c995d43a778294b1b99e1ff07656e1d2`
- candidate: `63d054374b1398ce627c16782748ed9f514d04ec`
- zig-gc: `89b6652c81ba892119b7b9ce3b0d07fc78a009ff`
- zig-regex: `719673318b0c6250898d7ced3603876c148e370b`
- host class: `diagnostic`
- material-change categories: `cpu_work`
- sampling: 7 order-balanced pairs; no discarded samples
- timed boundary: one JSON.stringify invocation of a prebuilt depth-512 object chain after ten one-job warmups; exact length, leaf offset, and delimiters validated inside the timed invocation

| parent median | candidate median | candidate / parent | parent RSD | candidate RSD | assessment |
| ---: | ---: | ---: | ---: | ---: | --- |
| 0.695 ms | 0.672 ms | 0.968x | 42.74% | 10.83% | `diagnostic_only` |

| memory/allocation metric | parent median | candidate median | candidate / parent | parent RSD | candidate RSD |
| --- | ---: | ---: | ---: | ---: | ---: |
| `peak_rss_bytes` | 61112320 | 61489152 | 1.0062x | 0.07% | 0.06% |

| efficiency metric | parent median | candidate median | candidate / parent | parent RSD | candidate RSD |
| --- | ---: | ---: | ---: | ---: | ---: |
| `instructions` | 7873667 | 7763338 | 0.9860x | 2.34% | 0.89% |
| `cycles` | 2506757 | 2400626 | 0.9577x | 18.59% | 11.15% |
| `energy_joules` | 0 | 0 | NaNx | 264.58% | NaN% |

Thermal states: `nominal->nominal`. Unmet category metrics: none. Efficiency evidence: `blocked_or_diagnostic`.

All input identities and checksums matched. Missing attribution values are encoded as unavailable with a reason, never as zero.
