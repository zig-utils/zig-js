# Exact-parent performance A/B — representative_json (single, 1 lane(s))

- logical parent: `700736c82fb0d5a276c8285a2ac696ce0dc73e17`
- logical candidate: `1c837038d8a575d7a674b4e34af5761c81e1f7af`
- binary provenance: `direct`
- parent binary revision: `700736c82fb0d5a276c8285a2ac696ce0dc73e17`
- candidate binary revision: `1c837038d8a575d7a674b4e34af5761c81e1f7af`
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
| 374.033 ms | 407.939 ms | 1.091x | 1.95% | 2.87% | `diagnostic_only` |

| memory/allocation metric | parent median | candidate median | candidate / parent | parent RSD | candidate RSD |
| --- | ---: | ---: | ---: | ---: | ---: |
| `peak_rss_bytes` | 108920832 | 108937216 | 1.0002x | 0.06% | 0.06% |

| efficiency metric | parent median | candidate median | candidate / parent | parent RSD | candidate RSD |
| --- | ---: | ---: | ---: | ---: | ---: |
| `instructions` | 5499822039 | 5787236990 | 1.0523x | 0.24% | 0.55% |
| `cycles` | 1201535748 | 1294226616 | 1.0771x | 0.81% | 1.01% |
| `energy_joules` | 1.709917193 | 1.78104288 | 1.0416x | 2.27% | 2.40% |

Thermal states: `nominal->nominal`. Unmet category metrics: none. Efficiency evidence: `stable`.

All input identities and checksums matched. Missing attribution values are encoded as unavailable with a reason, never as zero.
