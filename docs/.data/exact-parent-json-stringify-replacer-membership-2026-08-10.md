# Exact-parent performance A/B — representative_json_stringify_replacer_membership (single, 1 lane(s))

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
| 177.012 ms | 6.683 ms | 0.038x | 1.33% | 0.91% | `diagnostic_only` |

| efficiency metric | parent median | candidate median | candidate / parent | parent RSD | candidate RSD |
| --- | ---: | ---: | ---: | ---: | ---: |
| `instructions` | 3598513148 | 120928832 | 0.0336x | 0.00% | 0.02% |
| `cycles` | 647090080 | 24475524 | 0.0378x | 1.16% | 0.74% |
| `energy_joules` | 0.745494625 | 0 | 0.0000x | 1.11% | 190.75% |

Thermal states: `nominal->nominal`. Unmet category metrics: `cache_misses`. Efficiency evidence: `blocked_or_diagnostic`.

All input identities and checksums matched. Missing attribution values are encoded as unavailable with a reason, never as zero.
