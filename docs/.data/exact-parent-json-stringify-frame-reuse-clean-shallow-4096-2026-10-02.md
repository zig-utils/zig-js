# Exact-parent performance A/B — representative_json_stringify_shallow_4096 (single, 1 lane(s))

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
| 727.043 ms | 727.241 ms | 1.000x | 1.03% | 0.93% | `diagnostic_only` |

| memory/allocation metric | parent median | candidate median | candidate / parent | parent RSD | candidate RSD |
| --- | ---: | ---: | ---: | ---: | ---: |
| `peak_rss_bytes` | 193363968 | 193347584 | 0.9999x | 0.02% | 0.02% |

| efficiency metric | parent median | candidate median | candidate / parent | parent RSD | candidate RSD |
| --- | ---: | ---: | ---: | ---: | ---: |
| `instructions` | 11654781277 | 11648142534 | 0.9994x | 0.01% | 0.00% |
| `cycles` | 2467839612 | 2455568259 | 0.9950x | 0.97% | 0.95% |
| `energy_joules` | 3.649786684 | 3.653032969 | 1.0009x | 1.03% | 0.86% |

Thermal states: `nominal->nominal`. Unmet category metrics: none. Efficiency evidence: `stable`.

All input identities and checksums matched. Missing attribution values are encoded as unavailable with a reason, never as zero.
