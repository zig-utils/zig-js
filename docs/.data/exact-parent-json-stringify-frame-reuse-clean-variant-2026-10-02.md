# Exact-parent performance A/B — representative_json_variant (single, 1 lane(s))

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
| 325.382 ms | 324.283 ms | 0.997x | 0.99% | 3.79% | `diagnostic_only` |

| memory/allocation metric | parent median | candidate median | candidate / parent | parent RSD | candidate RSD |
| --- | ---: | ---: | ---: | ---: | ---: |
| `peak_rss_bytes` | 49774592 | 49790976 | 1.0003x | 0.12% | 0.09% |

| efficiency metric | parent median | candidate median | candidate / parent | parent RSD | candidate RSD |
| --- | ---: | ---: | ---: | ---: | ---: |
| `instructions` | 5308890701 | 5308551326 | 0.9999x | 0.35% | 0.56% |
| `cycles` | 1102794133 | 1104724716 | 1.0018x | 0.74% | 1.60% |
| `energy_joules` | 1.649289352 | 1.639352824 | 0.9940x | 0.89% | 1.28% |

Thermal states: `nominal->nominal`. Unmet category metrics: none. Efficiency evidence: `stable`.

All input identities and checksums matched. Missing attribution values are encoded as unavailable with a reason, never as zero.
