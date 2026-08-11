# Exact-parent performance A/B — representative_array_like_1024 (single, 1 lane(s))

- parent: `8592a7dc844d4ac1911263cdd9c6b938a4d739e7`
- candidate: `7666c5f142abf568cfaf4d7ffdce55a6e4c7e4f3`
- zig-gc: `89b6652c81ba892119b7b9ce3b0d07fc78a009ff`
- zig-regex: `719673318b0c6250898d7ced3603876c148e370b`
- host class: `diagnostic`
- material-change categories: `cpu_work`
- sampling: 7 order-balanced pairs; no discarded samples
- timed boundary: prebuilt plain array-like; one scored 400-job computed Has/Get traversal

| parent median | candidate median | candidate / parent | parent RSD | candidate RSD | assessment |
| ---: | ---: | ---: | ---: | ---: | --- |
| 2512.307 ms | 694.647 ms | 0.276x | 11.11% | 21.00% | `diagnostic_only` |

| memory metric | parent median | candidate median | candidate / parent | parent RSD | candidate RSD |
| --- | ---: | ---: | ---: | ---: | ---: |
| `peak_rss_bytes` | 99401728 | 110166016 | 1.1083x | 23.41% | 26.20% |

| efficiency metric | parent median | candidate median | candidate / parent | parent RSD | candidate RSD |
| --- | ---: | ---: | ---: | ---: | ---: |
| `instructions` | 34832760941 | 10032956451 | 0.2880x | 1.43% | 1.92% |
| `cycles` | 7522681903 | 2169413687 | 0.2884x | 5.85% | 7.58% |
| `energy_joules` | 7.444318202 | 2.402986843 | 0.3228x | 3.31% | 4.78% |

Thermal states: `nominal->nominal`. Unmet category metrics: none. Efficiency evidence: `blocked_or_diagnostic`.

All input identities and checksums matched. Missing attribution values are encoded as unavailable with a reason, never as zero.
