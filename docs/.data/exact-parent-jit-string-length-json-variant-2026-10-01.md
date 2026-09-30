# Exact-parent performance A/B — representative_json_variant (single, 1 lane(s))

- logical parent: `0efe89eda72f6a3665ee4a95547992253712c4cf`
- logical candidate: `ac67db51c988fd2a458f5b7bc44c55dbaed05d2b`
- binary provenance: `direct`
- parent binary revision: `0efe89eda72f6a3665ee4a95547992253712c4cf`
- candidate binary revision: `ac67db51c988fd2a458f5b7bc44c55dbaed05d2b`
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
| 390.472 ms | 359.899 ms | 0.922x | 3.06% | 2.93% | `diagnostic_only` |

| memory/allocation metric | parent median | candidate median | candidate / parent | parent RSD | candidate RSD |
| --- | ---: | ---: | ---: | ---: | ---: |
| `peak_rss_bytes` | 109019136 | 109019136 | 1.0000x | 0.02% | 0.06% |

| efficiency metric | parent median | candidate median | candidate / parent | parent RSD | candidate RSD |
| --- | ---: | ---: | ---: | ---: | ---: |
| `instructions` | 5973809120 | 5572496310 | 0.9328x | 0.23% | 0.61% |
| `cycles` | 1322922392 | 1215046728 | 0.9185x | 2.02% | 2.07% |
| `energy_joules` | 1.880137187 | 1.739023418 | 0.9249x | 0.74% | 1.12% |

Thermal states: `nominal->nominal`. Unmet category metrics: none. Efficiency evidence: `stable`.

All input identities and checksums matched. Missing attribution values are encoded as unavailable with a reason, never as zero.
