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
| 324.820 ms | 320.347 ms | 0.986x | 1.23% | 1.65% | `diagnostic_only` |

| memory/allocation metric | parent median | candidate median | candidate / parent | parent RSD | candidate RSD |
| --- | ---: | ---: | ---: | ---: | ---: |
| `peak_rss_bytes` | 49709056 | 49790976 | 1.0016x | 0.16% | 0.11% |

| efficiency metric | parent median | candidate median | candidate / parent | parent RSD | candidate RSD |
| --- | ---: | ---: | ---: | ---: | ---: |
| `instructions` | 5326967128 | 5324189873 | 0.9995x | 0.47% | 0.37% |
| `cycles` | 1106177222 | 1091332674 | 0.9866x | 0.83% | 0.92% |
| `energy_joules` | 1.663862553 | 1.633957488 | 0.9820x | 0.89% | 1.21% |

Thermal states: `nominal->nominal`. Unmet category metrics: none. Efficiency evidence: `stable`.

All input identities and checksums matched. Missing attribution values are encoded as unavailable with a reason, never as zero.
