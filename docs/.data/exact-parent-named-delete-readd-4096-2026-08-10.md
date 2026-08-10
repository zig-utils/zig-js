# Exact-parent performance A/B — representative_named_delete_readd_4096 (single, 1 lane(s))

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
| 88.746 ms | 0.846 ms | 0.010x | 7.99% | 8.93% | `diagnostic_only` |

| memory metric | parent median | candidate median | candidate / parent | parent RSD | candidate RSD |
| --- | ---: | ---: | ---: | ---: | ---: |
| `peak_rss_bytes` | 45301760 | 27361280 | 0.6040x | 0.20% | 0.23% |

| efficiency metric | parent median | candidate median | candidate / parent | parent RSD | candidate RSD |
| --- | ---: | ---: | ---: | ---: | ---: |
| `instructions` | 532216137 | 11897142 | 0.0224x | 0.34% | 1.31% |
| `cycles` | 331864510 | 3048793 | 0.0092x | 2.71% | 9.41% |
| `energy_joules` | 0.217275079 | 0 | 0.0000x | 5.15% | NaN% |

Thermal states: `nominal->nominal`. Unmet category metrics: none. Efficiency evidence: `blocked_or_diagnostic`.

All input identities and checksums matched. Missing attribution values are encoded as unavailable with a reason, never as zero.
