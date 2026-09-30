# Exact-parent performance A/B — representative_json_stringify_shallow_4096 (single, 1 lane(s))

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
| 35.587 ms | 34.764 ms | 0.977x | 2.10% | 1.51% | `diagnostic_only` |

| memory/allocation metric | parent median | candidate median | candidate / parent | parent RSD | candidate RSD |
| --- | ---: | ---: | ---: | ---: | ---: |
| `peak_rss_bytes` | 43008000 | 43073536 | 1.0015x | 0.12% | 0.19% |

| efficiency metric | parent median | candidate median | candidate / parent | parent RSD | candidate RSD |
| --- | ---: | ---: | ---: | ---: | ---: |
| `instructions` | 542245302 | 542087952 | 0.9997x | 0.24% | 0.06% |
| `cycles` | 119131001 | 116139076 | 0.9749x | 0.66% | 0.81% |
| `energy_joules` | 0.155313243 | 0.148336131 | 0.9551x | 6.81% | 6.93% |

Thermal states: `nominal->nominal`. Unmet category metrics: none. Efficiency evidence: `blocked_or_diagnostic`.

All input identities and checksums matched. Missing attribution values are encoded as unavailable with a reason, never as zero.
