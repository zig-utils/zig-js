# Exact-parent performance A/B — representative_json_variant (single, 1 lane(s))

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
| 432.394 ms | 489.736 ms | 1.133x | 35.76% | 16.50% | `diagnostic_only` |

| memory/allocation metric | parent median | candidate median | candidate / parent | parent RSD | candidate RSD |
| --- | ---: | ---: | ---: | ---: | ---: |
| `peak_rss_bytes` | 108888064 | 108904448 | 1.0002x | 13.42% | 16.34% |

| efficiency metric | parent median | candidate median | candidate / parent | parent RSD | candidate RSD |
| --- | ---: | ---: | ---: | ---: | ---: |
| `instructions` | 5533428074 | 5689984079 | 1.0283x | 0.26% | 0.67% |
| `cycles` | 1302947303 | 1311014083 | 1.0062x | 9.18% | 6.53% |
| `energy_joules` | 1.643815612 | 1.735258216 | 1.0556x | 6.45% | 4.13% |

Thermal states: `nominal->nominal`. Unmet category metrics: none. Efficiency evidence: `blocked_or_diagnostic`.

All input identities and checksums matched. Missing attribution values are encoded as unavailable with a reason, never as zero.
