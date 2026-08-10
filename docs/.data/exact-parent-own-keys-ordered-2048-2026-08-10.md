# Exact-parent performance A/B — representative_own_keys_ordered_2048 (single, 1 lane(s))

- parent: `14ffcdb39683ecbb15a8add2bf6f6b1c2bcfdebd`
- candidate: `e96837983ddfe11b1eb0fbfa282fcde37aae2724`
- zig-gc: `89b6652c81ba892119b7b9ce3b0d07fc78a009ff`
- zig-regex: `719673318b0c6250898d7ced3603876c148e370b`
- host class: `diagnostic`
- material-change categories: `cpu_work`
- sampling: 7 order-balanced pairs; no discarded samples
- timed boundary: one Reflect.ownKeys call over a prebuilt 2048-data-property plus accessor fixture; fixture creation and warmup excluded

| parent median | candidate median | candidate / parent | parent RSD | candidate RSD | assessment |
| ---: | ---: | ---: | ---: | ---: | --- |
| 11.328 ms | 0.404 ms | 0.036x | 3.74% | 16.99% | `diagnostic_only` |

| efficiency metric | parent median | candidate median | candidate / parent | parent RSD | candidate RSD |
| --- | ---: | ---: | ---: | ---: | ---: |
| `instructions` | 128626972 | 5596123 | 0.0435x | 0.04% | 0.65% |
| `cycles` | 40310385 | 1472212 | 0.0365x | 3.72% | 16.44% |
| `energy_joules` | 0.031556574 | 0 | 0.0000x | 5.40% | NaN% |

Thermal states: `nominal->nominal`. Unmet category metrics: none. Efficiency evidence: `blocked_or_diagnostic`.

All input identities and checksums matched. Missing attribution values are encoded as unavailable with a reason, never as zero.
