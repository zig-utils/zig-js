# Exact-parent performance A/B — representative_json_stringify_depth_4096 (single, 1 lane(s))

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
| 1106.573 ms | 1062.975 ms | 0.961x | 1.73% | 1.40% | `diagnostic_only` |

| memory/allocation metric | parent median | candidate median | candidate / parent | parent RSD | candidate RSD |
| --- | ---: | ---: | ---: | ---: | ---: |
| `peak_rss_bytes` | 378454016 | 414449664 | 1.0951x | 0.84% | 0.07% |

| efficiency metric | parent median | candidate median | candidate / parent | parent RSD | candidate RSD |
| --- | ---: | ---: | ---: | ---: | ---: |
| `instructions` | 15175041613 | 13823976295 | 0.9110x | 0.02% | 0.29% |
| `cycles` | 3738717701 | 3588442017 | 0.9598x | 0.59% | 1.28% |
| `energy_joules` | 5.095956165 | 4.779146905 | 0.9378x | 0.59% | 0.49% |

Thermal states: `nominal->nominal`. Unmet category metrics: none. Efficiency evidence: `stable`.

All input identities and checksums matched. Missing attribution values are encoded as unavailable with a reason, never as zero.
