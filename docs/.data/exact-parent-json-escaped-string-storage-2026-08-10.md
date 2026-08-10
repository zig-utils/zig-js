# Exact-parent performance A/B — representative_json_escaped_strings (single, 1 lane(s))

- parent: `9d89770d44e35b64495f07074f203b4795dcee57`
- candidate: `da1c8b1812f237d6ffc5a4296b1df052529d9f83`
- zig-gc: `89b6652c81ba892119b7b9ce3b0d07fc78a009ff`
- zig-regex: `719673318b0c6250898d7ced3603876c148e370b`
- host class: `diagnostic`
- material-change categories: `cpu_work`, `cache_traffic`
- sampling: 7 order-balanced pairs; no discarded samples
- timed boundary: one invocation in a persistent context after ten reduced-work warmups

| parent median | candidate median | candidate / parent | parent RSD | candidate RSD | assessment |
| ---: | ---: | ---: | ---: | ---: | --- |
| 61.344 ms | 62.648 ms | 1.021x | 1.02% | 1.95% | `diagnostic_only` |

| efficiency metric | parent median | candidate median | candidate / parent | parent RSD | candidate RSD |
| --- | ---: | ---: | ---: | ---: | ---: |
| `instructions` | 1104062764 | 1105933265 | 1.0017x | 0.02% | 0.03% |
| `cycles` | 223006922 | 224958058 | 1.0087x | 0.36% | 0.87% |
| `energy_joules` | 0.229405824 | 0.249714318 | 1.0885x | 3.95% | 2.63% |

Thermal states: `nominal->nominal`. Unmet category metrics: `cache_misses`. Efficiency evidence: `blocked_or_diagnostic`.

All input identities and checksums matched. Missing attribution values are encoded as unavailable with a reason, never as zero.
