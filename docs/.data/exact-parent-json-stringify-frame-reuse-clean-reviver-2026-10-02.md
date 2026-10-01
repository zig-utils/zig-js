# Exact-parent performance A/B — representative_json_reviver_source (single, 1 lane(s))

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
| 837.922 ms | 830.719 ms | 0.991x | 2.02% | 1.61% | `diagnostic_only` |

| memory/allocation metric | parent median | candidate median | candidate / parent | parent RSD | candidate RSD |
| --- | ---: | ---: | ---: | ---: | ---: |
| `peak_rss_bytes` | 332677120 | 332496896 | 0.9995x | 1.13% | 0.50% |

| efficiency metric | parent median | candidate median | candidate / parent | parent RSD | candidate RSD |
| --- | ---: | ---: | ---: | ---: | ---: |
| `instructions` | 13377141101 | 13339610731 | 0.9972x | 0.40% | 0.84% |
| `cycles` | 2837661928 | 2817790913 | 0.9930x | 1.12% | 1.58% |
| `energy_joules` | 4.329801067 | 4.310058762 | 0.9954x | 0.96% | 0.94% |

Thermal states: `nominal->nominal`. Unmet category metrics: none. Efficiency evidence: `stable`.

All input identities and checksums matched. Missing attribution values are encoded as unavailable with a reason, never as zero.
