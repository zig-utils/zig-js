# Exact-parent performance A/B — representative_named_delete_2048 (single, 1 lane(s))

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
| 11.876 ms | 0.399 ms | 0.034x | 4.14% | 8.50% | `diagnostic_only` |

| memory metric | parent median | candidate median | candidate / parent | parent RSD | candidate RSD |
| --- | ---: | ---: | ---: | ---: | ---: |
| `peak_rss_bytes` | 30801920 | 21856256 | 0.7096x | 0.13% | 0.33% |

| efficiency metric | parent median | candidate median | candidate / parent | parent RSD | candidate RSD |
| --- | ---: | ---: | ---: | ---: | ---: |
| `instructions` | 118695636 | 5873966 | 0.0495x | 0.02% | 0.25% |
| `cycles` | 46087717 | 1503279 | 0.0326x | 4.24% | 8.93% |
| `energy_joules` | 0.031882122 | 0 | 0.0000x | 5.05% | NaN% |

Thermal states: `nominal->nominal`. Unmet category metrics: none. Efficiency evidence: `blocked_or_diagnostic`.

All input identities and checksums matched. Missing attribution values are encoded as unavailable with a reason, never as zero.
