# Exact-parent performance A/B — representative_json_variant (single, 1 lane(s))

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
| 386.983 ms | 351.389 ms | 0.908x | 5.94% | 3.20% | `diagnostic_only` |

| memory/allocation metric | parent median | candidate median | candidate / parent | parent RSD | candidate RSD |
| --- | ---: | ---: | ---: | ---: | ---: |
| `peak_rss_bytes` | 108953600 | 49758208 | 0.4567x | 6.48% | 0.18% |

| efficiency metric | parent median | candidate median | candidate / parent | parent RSD | candidate RSD |
| --- | ---: | ---: | ---: | ---: | ---: |
| `instructions` | 5664483364 | 5309563505 | 0.9373x | 0.80% | 0.32% |
| `cycles` | 1262691686 | 1153723306 | 0.9137x | 1.90% | 1.48% |
| `energy_joules` | 1.736536259 | 1.603922778 | 0.9236x | 3.80% | 2.03% |

Thermal states: `nominal->nominal`. Unmet category metrics: none. Efficiency evidence: `stable`.

All input identities and checksums matched. Missing attribution values are encoded as unavailable with a reason, never as zero.
