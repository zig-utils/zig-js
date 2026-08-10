# Exact-parent performance A/B — representative_own_keys_ordered_1024 (single, 1 lane(s))

- parent: `14ffcdb39683ecbb15a8add2bf6f6b1c2bcfdebd`
- candidate: `e96837983ddfe11b1eb0fbfa282fcde37aae2724`
- zig-gc: `89b6652c81ba892119b7b9ce3b0d07fc78a009ff`
- zig-regex: `719673318b0c6250898d7ced3603876c148e370b`
- host class: `diagnostic`
- material-change categories: `cpu_work`
- sampling: 7 order-balanced pairs; no discarded samples
- timed boundary: one Reflect.ownKeys call over a prebuilt 1024-data-property plus accessor fixture; fixture creation and warmup excluded

| parent median | candidate median | candidate / parent | parent RSD | candidate RSD | assessment |
| ---: | ---: | ---: | ---: | ---: | --- |
| 2.089 ms | 0.194 ms | 0.093x | 2.64% | 73.56% | `diagnostic_only` |

| efficiency metric | parent median | candidate median | candidate / parent | parent RSD | candidate RSD |
| --- | ---: | ---: | ---: | ---: | ---: |
| `instructions` | 45259190 | 2837724 | 0.0627x | 0.07% | 1.22% |
| `cycles` | 7437400 | 727712 | 0.0978x | 2.76% | 33.30% |
| `energy_joules` | 0 | 0 | NaNx | 184.46% | 264.58% |

Thermal states: `nominal->nominal`. Unmet category metrics: none. Efficiency evidence: `blocked_or_diagnostic`.

All input identities and checksums matched. Missing attribution values are encoded as unavailable with a reason, never as zero.
