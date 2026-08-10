# Exact-parent performance A/B — representative_own_keys_proxy_invariants (single, 1 lane(s))

- parent: `14ffcdb39683ecbb15a8add2bf6f6b1c2bcfdebd`
- candidate: `e96837983ddfe11b1eb0fbfa282fcde37aae2724`
- zig-gc: `89b6652c81ba892119b7b9ce3b0d07fc78a009ff`
- zig-regex: `719673318b0c6250898d7ced3603876c148e370b`
- host class: `diagnostic`
- material-change categories: `cpu_work`
- sampling: 7 order-balanced pairs; no discarded samples
- timed boundary: one Reflect.ownKeys call over a prebuilt non-extensible 2048-property Proxy with an exact ownKeys trap result; fixture creation and warmup excluded

| parent median | candidate median | candidate / parent | parent RSD | candidate RSD | assessment |
| ---: | ---: | ---: | ---: | ---: | --- |
| 20.218 ms | 20.078 ms | 0.993x | 5.32% | 4.10% | `diagnostic_only` |

| efficiency metric | parent median | candidate median | candidate / parent | parent RSD | candidate RSD |
| --- | ---: | ---: | ---: | ---: | ---: |
| `instructions` | 179608382 | 178184222 | 0.9921x | 0.04% | 0.05% |
| `cycles` | 73833480 | 72697661 | 0.9846x | 5.29% | 3.80% |
| `energy_joules` | 0.048265661 | 0.051255583 | 1.0619x | 27.23% | 19.94% |

Thermal states: `nominal->nominal`. Unmet category metrics: none. Efficiency evidence: `blocked_or_diagnostic`.

All input identities and checksums matched. Missing attribution values are encoded as unavailable with a reason, never as zero.
