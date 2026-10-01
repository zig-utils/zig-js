# Exact-parent performance A/B — representative_json (single, 1 lane(s))

- logical parent: `292e2baa550bf0b27a1e8d90bcbfce633c582376`
- logical candidate: `b6ae21478930e03e8bbbc024e5ba2b3cb75e5e14`
- binary provenance: `direct`
- parent binary revision: `292e2baa550bf0b27a1e8d90bcbfce633c582376`
- candidate binary revision: `b6ae21478930e03e8bbbc024e5ba2b3cb75e5e14`
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
| 389.753 ms | 365.392 ms | 0.937x | 3.04% | 5.11% | `diagnostic_only` |

| memory/allocation metric | parent median | candidate median | candidate / parent | parent RSD | candidate RSD |
| --- | ---: | ---: | ---: | ---: | ---: |
| `peak_rss_bytes` | 109051904 | 49790976 | 0.4566x | 0.06% | 0.47% |

| efficiency metric | parent median | candidate median | candidate / parent | parent RSD | candidate RSD |
| --- | ---: | ---: | ---: | ---: | ---: |
| `instructions` | 5803149833 | 5325402825 | 0.9177x | 0.50% | 0.60% |
| `cycles` | 1280623667 | 1172779056 | 0.9158x | 2.13% | 2.46% |
| `energy_joules` | 1.780810378 | 1.614552204 | 0.9066x | 1.49% | 3.01% |

Thermal states: `nominal->nominal`. Unmet category metrics: none. Efficiency evidence: `stable`.

All input identities and checksums matched. Missing attribution values are encoded as unavailable with a reason, never as zero.
