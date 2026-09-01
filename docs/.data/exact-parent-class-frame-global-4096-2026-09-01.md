# Exact-parent performance A/B — representative_frontend_compile_class_frame_global_4096 (single, 1 lane(s))

- logical parent: `be27ecd46dbb20b1bca090a256ad5927ae84b981`
- logical candidate: `8bbbf402d723815b19ad3de5da4d698ac1a74cd5`
- parent binary revision: `7f92e62813cda7ebc7b98b258eed2498f250a770`
- candidate binary revision: `b61a77b3d4da81f83d880eddc49066194059ae2a`
- shared measurement overlay: `bench/comparison_zig_js.zig`, `bench/frontend_parse.zig`, `docs/.data/algorithmic-growth-schema-v2.json`, `docs/.data/bunpress-output-v1.json`, `docs/.data/performance-attribution-schema-v2.json`, `docs/.data/representative-benchmark-matrix-v24.json`, `docs/benchmarks.md`, `tools/algorithmic-growth.ts`, `tools/evidence-processes.ts`, `tools/exact-parent-regression.ts`, `tools/instrumentation-overhead.ts`, `tools/performance-attribution.ts`, `tools/representative-matrix.ts`
- zig-gc: `89b6652c81ba892119b7b9ce3b0d07fc78a009ff`
- zig-regex: `87e9ca28fa14194dd1e8b4cae7461e179331efca`
- host class: `quiet_reference`
- material-change categories: `cpu_work`
- sampling: 7 order-balanced pairs; no discarded samples
- process quality: every measured invocation used at least 60% CPU occupancy; complete-process occupancy remains diagnostic; before/after snapshots reject persistent competing jobs
- timed boundary: ten production parse plus plain-function admission/compile jobs over one frozen generated global-only deferred-class source; process startup, two one-job warmups, hardware snapshots, and untimed identical-work allocation replay are outside elapsed_ns

| parent median | candidate median | candidate / parent | parent RSD | candidate RSD | assessment |
| ---: | ---: | ---: | ---: | ---: | --- |
| 1478.547 ms | 34.086 ms | 0.023x | 0.48% | 4.02% | `blocked_efficiency_evidence` |

| memory/allocation metric | parent median | candidate median | candidate / parent | parent RSD | candidate RSD |
| --- | ---: | ---: | ---: | ---: | ---: |
| `peak_rss_bytes` | 27115520 | 27377664 | 1.0097x | 1.39% | 0.06% |
| `allocations` | 370670 | 370780 | 1.0003x | 0.00% | 0.00% |
| `allocated_bytes` | 213195620 | 215982180 | 1.0131x | 0.00% | 0.00% |

| efficiency metric | parent median | candidate median | candidate / parent | parent RSD | candidate RSD |
| --- | ---: | ---: | ---: | ---: | ---: |
| `instructions` | 22366896826 | 576672848 | 0.0258x | 0.00% | 0.06% |
| `cycles` | 5396472062 | 123647767 | 0.0229x | 0.10% | 2.73% |
| `energy_joules` | 7.398525342 | 0.133547956 | 0.0181x | 0.23% | 11.44% |

Thermal states: `nominal->nominal`. Unmet category metrics: none. Efficiency evidence: `blocked_or_diagnostic`.

All input identities and checksums matched. Missing attribution values are encoded as unavailable with a reason, never as zero.
