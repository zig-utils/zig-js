# Exact-parent performance A/B — representative_named_delete_4096 (single, 1 lane(s))

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
| 88.625 ms | 0.799 ms | 0.009x | 0.90% | 8.39% | `diagnostic_only` |

| memory metric | parent median | candidate median | candidate / parent | parent RSD | candidate RSD |
| --- | ---: | ---: | ---: | ---: | ---: |
| `peak_rss_bytes` | 45170688 | 27279360 | 0.6039x | 0.11% | 0.16% |

| efficiency metric | parent median | candidate median | candidate / parent | parent RSD | candidate RSD |
| --- | ---: | ---: | ---: | ---: | ---: |
| `instructions` | 528963775 | 11692360 | 0.0221x | 0.03% | 0.78% |
| `cycles` | 327940525 | 2974367 | 0.0091x | 0.83% | 9.08% |
| `energy_joules` | 0.210231082 | 0 | 0.0000x | 5.18% | NaN% |

Thermal states: `nominal->nominal`. Unmet category metrics: none. Efficiency evidence: `blocked_or_diagnostic`.

All input identities and checksums matched. Missing attribution values are encoded as unavailable with a reason, never as zero.
