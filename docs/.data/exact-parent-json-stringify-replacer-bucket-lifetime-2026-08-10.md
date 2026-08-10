# Exact-parent performance A/B — representative_json_stringify_replacer_membership (single, 1 lane(s))

- parent: `c823cfba5b82383d47b746a9424109b06b1788c1`
- candidate: `2e48c838a117710071150b50256ac9be1fd7ed59`
- zig-gc: `89b6652c81ba892119b7b9ce3b0d07fc78a009ff`
- zig-regex: `719673318b0c6250898d7ced3603876c148e370b`
- host class: `diagnostic`
- material-change categories: `cpu_work`, `cache_traffic`
- sampling: 7 order-balanced pairs; no discarded samples
- timed boundary: one invocation in a persistent context after ten reduced-work warmups

| parent median | candidate median | candidate / parent | parent RSD | candidate RSD | assessment |
| ---: | ---: | ---: | ---: | ---: | --- |
| 6.515 ms | 6.507 ms | 0.999x | 1.44% | 1.58% | `diagnostic_only` |

| efficiency metric | parent median | candidate median | candidate / parent | parent RSD | candidate RSD |
| --- | ---: | ---: | ---: | ---: | ---: |
| `instructions` | 120940261 | 120379578 | 0.9954x | 0.02% | 0.02% |
| `cycles` | 24550830 | 24030248 | 0.9788x | 1.35% | 1.47% |
| `energy_joules` | 0 | 0 | NaNx | NaN% | NaN% |

Thermal states: `nominal->nominal`. Unmet category metrics: `cache_misses`. Efficiency evidence: `blocked_or_diagnostic`.

All input identities and checksums matched. Missing attribution values are encoded as unavailable with a reason, never as zero.
