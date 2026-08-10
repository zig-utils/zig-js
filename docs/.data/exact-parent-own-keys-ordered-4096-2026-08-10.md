# Exact-parent performance A/B — representative_own_keys_ordered_4096 (single, 1 lane(s))

- parent: `14ffcdb39683ecbb15a8add2bf6f6b1c2bcfdebd`
- candidate: `e96837983ddfe11b1eb0fbfa282fcde37aae2724`
- zig-gc: `89b6652c81ba892119b7b9ce3b0d07fc78a009ff`
- zig-regex: `719673318b0c6250898d7ced3603876c148e370b`
- host class: `diagnostic`
- material-change categories: `cpu_work`
- sampling: 7 order-balanced pairs; no discarded samples
- timed boundary: one Reflect.ownKeys call over a prebuilt 4096-data-property plus accessor fixture; fixture creation and warmup excluded

| parent median | candidate median | candidate / parent | parent RSD | candidate RSD | assessment |
| ---: | ---: | ---: | ---: | ---: | --- |
| 58.745 ms | 0.670 ms | 0.011x | 1.16% | 12.62% | `diagnostic_only` |

| efficiency metric | parent median | candidate median | candidate / parent | parent RSD | candidate RSD |
| --- | ---: | ---: | ---: | ---: | ---: |
| `instructions` | 600484219 | 11161500 | 0.0186x | 0.01% | 0.64% |
| `cycles` | 216007964 | 2455786 | 0.0114x | 0.53% | 12.02% |
| `energy_joules` | 0.147566307 | 0 | 0.0000x | 8.93% | NaN% |

Thermal states: `nominal->nominal`. Unmet category metrics: none. Efficiency evidence: `blocked_or_diagnostic`.

All input identities and checksums matched. Missing attribution values are encoded as unavailable with a reason, never as zero.
