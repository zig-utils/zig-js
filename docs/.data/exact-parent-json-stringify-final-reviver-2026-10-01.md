# Exact-parent performance A/B — representative_json_reviver_source (single, 1 lane(s))

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
| 864.679 ms | 855.837 ms | 0.990x | 4.21% | 1.83% | `diagnostic_only` |

| memory/allocation metric | parent median | candidate median | candidate / parent | parent RSD | candidate RSD |
| --- | ---: | ---: | ---: | ---: | ---: |
| `peak_rss_bytes` | 332251136 | 332316672 | 1.0002x | 12.53% | 0.44% |

| efficiency metric | parent median | candidate median | candidate / parent | parent RSD | candidate RSD |
| --- | ---: | ---: | ---: | ---: | ---: |
| `instructions` | 13387945303 | 13313126504 | 0.9944x | 0.78% | 0.79% |
| `cycles` | 2917839640 | 2898792946 | 0.9935x | 2.55% | 1.45% |
| `energy_joules` | 4.364485897 | 4.32872037 | 0.9918x | 1.36% | 1.19% |

Thermal states: `nominal->nominal`. Unmet category metrics: none. Efficiency evidence: `stable`.

All input identities and checksums matched. Missing attribution values are encoded as unavailable with a reason, never as zero.
