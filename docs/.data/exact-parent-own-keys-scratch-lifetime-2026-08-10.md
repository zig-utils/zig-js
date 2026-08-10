# Exact-parent performance A/B — representative_own_keys_ordered_4096 (single_observed, 1 lane(s))

- parent: `14ffcdb39683ecbb15a8add2bf6f6b1c2bcfdebd`
- candidate: `e96837983ddfe11b1eb0fbfa282fcde37aae2724`
- zig-gc: `89b6652c81ba892119b7b9ce3b0d07fc78a009ff`
- zig-regex: `719673318b0c6250898d7ced3603876c148e370b`
- host class: `diagnostic`
- material-change categories: `cpu_work`
- sampling: 7 order-balanced pairs; no discarded samples
- timed boundary: one Reflect.ownKeys call over a prebuilt 4096-data-property plus accessor fixture after ten warmup calls; live retained RSS is sampled after invocation before Context teardown

| parent median | candidate median | candidate / parent | parent RSD | candidate RSD | assessment |
| ---: | ---: | ---: | ---: | ---: | --- |
| 58.082 ms | 0.741 ms | 0.013x | 1.89% | 11.66% | `diagnostic_only` |

| memory metric | parent median | candidate median | candidate / parent | parent RSD | candidate RSD |
| --- | ---: | ---: | ---: | ---: | ---: |
| `peak_rss_bytes` | 31506432 | 27426816 | 0.8705x | 0.14% | 0.23% |
| `retained_rss_bytes` | 31408128 | 27361280 | 0.8712x | 0.14% | 0.23% |

| efficiency metric | parent median | candidate median | candidate / parent | parent RSD | candidate RSD |
| --- | ---: | ---: | ---: | ---: | ---: |
| `instructions` | 600734601 | 11082509 | 0.0184x | 0.04% | 0.56% |
| `cycles` | 215904374 | 2805665 | 0.0130x | 0.84% | 11.85% |
| `energy_joules` | 0.16209622 | 0 | 0.0000x | 8.90% | NaN% |

Thermal states: `nominal->nominal`. Unmet category metrics: none. Efficiency evidence: `blocked_or_diagnostic`.

All input identities and checksums matched. Missing attribution values are encoded as unavailable with a reason, never as zero.
