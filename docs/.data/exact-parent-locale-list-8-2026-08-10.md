# Exact-parent performance A/B — representative_locale_list_8 (single, 1 lane(s))

- parent: `77b939131f6191cc18c92cc05bfad2f7f61d5bff`
- candidate: `9cc8d4964bbcc3b37cca35faf5254329a6d654f3`
- zig-gc: `89b6652c81ba892119b7b9ce3b0d07fc78a009ff`
- zig-regex: `719673318b0c6250898d7ced3603876c148e370b`
- host class: `diagnostic`
- material-change categories: `cpu_work`
- sampling: 7 order-balanced pairs; no discarded samples
- timed boundary: 10,000 CanonicalizeLocaleList invocations over one prebuilt 8-element locale array

| parent median | candidate median | candidate / parent | parent RSD | candidate RSD | assessment |
| ---: | ---: | ---: | ---: | ---: | --- |
| 70.631 ms | 72.749 ms | 1.030x | 0.94% | 2.44% | `diagnostic_only` |

| memory metric | parent median | candidate median | candidate / parent | parent RSD | candidate RSD |
| --- | ---: | ---: | ---: | ---: | ---: |
| `peak_rss_bytes` | 78610432 | 29671424 | 0.3774x | 0.06% | 0.13% |

| efficiency metric | parent median | candidate median | candidate / parent | parent RSD | candidate RSD |
| --- | ---: | ---: | ---: | ---: | ---: |
| `instructions` | 1257898623 | 1325796566 | 1.0540x | 0.50% | 1.23% |
| `cycles` | 258309136 | 264154524 | 1.0226x | 0.93% | 2.12% |
| `energy_joules` | 0.310911385 | 0.307219609 | 0.9881x | 4.59% | 3.95% |

Thermal states: `nominal->nominal`. Unmet category metrics: none. Efficiency evidence: `stable`.

All input identities and checksums matched. Missing attribution values are encoded as unavailable with a reason, never as zero.
