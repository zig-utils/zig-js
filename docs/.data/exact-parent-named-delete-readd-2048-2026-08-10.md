# Exact-parent performance A/B — representative_named_delete_readd_2048 (single, 1 lane(s))

- parent: `00848706d4b24487c9a2caf83e12fe7a1b04695f`
- candidate: `253b5b079d8b3698f086e403a86d6052d0eacecd`
- zig-gc: `89b6652c81ba892119b7b9ce3b0d07fc78a009ff`
- zig-regex: `719673318b0c6250898d7ced3603876c148e370b`
- host class: `diagnostic`
- material-change categories: `cpu_work`
- sampling: 7 order-balanced pairs; no discarded samples
- timed boundary: one distinct middle-key delete over one prebuilt wide object after ten warmup invocations; fixture creation excluded; readd rows include exact non-default descriptor restoration and own-key checksum

| parent median | candidate median | candidate / parent | parent RSD | candidate RSD | assessment |
| ---: | ---: | ---: | ---: | ---: | --- |
| 12.383 ms | 0.422 ms | 0.034x | 3.48% | 9.98% | `diagnostic_only` |

| memory metric | parent median | candidate median | candidate / parent | parent RSD | candidate RSD |
| --- | ---: | ---: | ---: | ---: | ---: |
| `peak_rss_bytes` | 31391744 | 21856256 | 0.6962x | 0.11% | 0.18% |

| efficiency metric | parent median | candidate median | candidate / parent | parent RSD | candidate RSD |
| --- | ---: | ---: | ---: | ---: | ---: |
| `instructions` | 120225372 | 6072032 | 0.0505x | 0.10% | 1.23% |
| `cycles` | 45969209 | 1580025 | 0.0344x | 1.83% | 10.18% |
| `energy_joules` | 0.031756559 | 0 | 0.0000x | 2.25% | NaN% |

Thermal states: `nominal->nominal`. Unmet category metrics: none. Efficiency evidence: `blocked_or_diagnostic`.

All input identities and checksums matched. Missing attribution values are encoded as unavailable with a reason, never as zero.
