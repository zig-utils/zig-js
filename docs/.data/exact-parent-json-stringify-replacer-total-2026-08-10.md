# Exact-parent performance A/B — representative_json_stringify_replacer (single, 1 lane(s))

- parent: `531d4aa6d137d1d6bb5abda09df4726eb0c97cc2`
- candidate: `c823cfba5b82383d47b746a9424109b06b1788c1`
- zig-gc: `89b6652c81ba892119b7b9ce3b0d07fc78a009ff`
- zig-regex: `719673318b0c6250898d7ced3603876c148e370b`
- host class: `diagnostic`
- material-change categories: `cpu_work`, `cache_traffic`
- sampling: 7 order-balanced pairs; no discarded samples
- timed boundary: one invocation in a persistent context after ten reduced-work warmups

| parent median | candidate median | candidate / parent | parent RSD | candidate RSD | assessment |
| ---: | ---: | ---: | ---: | ---: | --- |
| 310.551 ms | 287.446 ms | 0.926x | 6.83% | 27.63% | `diagnostic_only` |

| efficiency metric | parent median | candidate median | candidate / parent | parent RSD | candidate RSD |
| --- | ---: | ---: | ---: | ---: | ---: |
| `instructions` | 1868758592 | 1618591683 | 0.8661x | 0.28% | 0.40% |
| `cycles` | 1071814873 | 1031951070 | 0.9628x | 3.03% | 3.88% |
| `energy_joules` | 0.758104274 | 0.704892673 | 0.9298x | 3.39% | 1.96% |

Thermal states: `nominal->nominal`. Unmet category metrics: `cache_misses`. Efficiency evidence: `blocked_or_diagnostic`.

All input identities and checksums matched. Missing attribution values are encoded as unavailable with a reason, never as zero.
