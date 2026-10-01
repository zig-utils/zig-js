# Exact-parent performance A/B — representative_json_stringify_shallow_4096 (single, 1 lane(s))

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
| 1031.000 ms | 777.632 ms | 0.754x | 13.19% | 3.57% | `diagnostic_only` |

| memory/allocation metric | parent median | candidate median | candidate / parent | parent RSD | candidate RSD |
| --- | ---: | ---: | ---: | ---: | ---: |
| `peak_rss_bytes` | 131383296 | 187334656 | 1.4259x | 26.99% | 17.68% |

| efficiency metric | parent median | candidate median | candidate / parent | parent RSD | candidate RSD |
| --- | ---: | ---: | ---: | ---: | ---: |
| `instructions` | 15080196013 | 11674146009 | 0.7741x | 0.13% | 0.40% |
| `cycles` | 3236647410 | 2530032995 | 0.7817x | 2.85% | 1.17% |
| `energy_joules` | 4.404414541 | 3.593746858 | 0.8159x | 3.61% | 2.95% |

Thermal states: `nominal->nominal`. Unmet category metrics: none. Efficiency evidence: `stable`.

All input identities and checksums matched. Missing attribution values are encoded as unavailable with a reason, never as zero.
