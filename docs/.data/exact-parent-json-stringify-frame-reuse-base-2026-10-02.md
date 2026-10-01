# Exact-parent performance A/B — representative_json (single, 1 lane(s))

- logical parent: `d165a68dcc833454ac55744118322f75f9fe38c2`
- logical candidate: `b617e7cfa583e3f67acff79bdecfbf877fb44530`
- binary provenance: `direct`
- parent binary revision: `d165a68dcc833454ac55744118322f75f9fe38c2`
- candidate binary revision: `b617e7cfa583e3f67acff79bdecfbf877fb44530`
- shared measurement overlay: none (direct builds)
- zig-gc: `0285ef801dd221a4ae8e88b31a09ae31627657a3`
- zig-regex: `fdd9c2e333ea6ac2fd06d080d939ef7f11d61b1b`
- host class: `diagnostic`
- material-change categories: `cpu_work`
- sampling: 7 order-balanced pairs; no discarded samples
- process quality: every measured invocation used at least 60% CPU occupancy; complete-process occupancy remains diagnostic; before/after snapshots reject persistent competing jobs
- timed boundary: warmed persistent context; one exact invocation

| parent median | candidate median | candidate / parent | parent RSD | candidate RSD | assessment |
| ---: | ---: | ---: | ---: | ---: | --- |
| 322.563 ms | 325.673 ms | 1.010x | 1.60% | 49.20% | `diagnostic_only` |

| memory/allocation metric | parent median | candidate median | candidate / parent | parent RSD | candidate RSD |
| --- | ---: | ---: | ---: | ---: | ---: |
| `peak_rss_bytes` | 49758208 | 49807360 | 1.0010x | 0.16% | 0.13% |

| efficiency metric | parent median | candidate median | candidate / parent | parent RSD | candidate RSD |
| --- | ---: | ---: | ---: | ---: | ---: |
| `instructions` | 5327020780 | 5338057535 | 1.0021x | 0.22% | 0.59% |
| `cycles` | 1109174741 | 1097285538 | 0.9893x | 1.23% | 13.68% |
| `energy_joules` | 1.640124565 | 1.603263964 | 0.9775x | 0.89% | 6.62% |

Thermal states: `nominal->nominal`. Unmet category metrics: none. Efficiency evidence: `blocked_or_diagnostic`.

All input identities and checksums matched. Missing attribution values are encoded as unavailable with a reason, never as zero.
