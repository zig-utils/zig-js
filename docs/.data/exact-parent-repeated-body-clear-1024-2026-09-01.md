# Exact-parent performance A/B — representative_frontend_compile_repeated_body_clear_1024 (single, 1 lane(s))

- logical parent: `3fcd7f027954b4c9c1ed5d89f2e7a503b4a5ae91`
- logical candidate: `14ca5cd4588b8f40baea15eb931e3d696d3c66bc`
- parent binary revision: `3cb08815bd0bff8b98fa59bfaf71cf7a50e91383`
- candidate binary revision: `7f29984d1c59b1bd69548c0da6005fee91d3cd72`
- shared measurement overlay: `bench/comparison_zig_js.zig`, `bench/frontend_parse.zig`, `docs/.data/algorithmic-growth-schema-v2.json`, `docs/.data/bunpress-output-v1.json`, `docs/.data/performance-attribution-schema-v2.json`, `docs/.data/representative-benchmark-matrix-v24.json`, `docs/benchmarks.md`, `tools/algorithmic-growth.ts`, `tools/evidence-processes.ts`, `tools/exact-parent-regression.ts`, `tools/instrumentation-overhead.ts`, `tools/performance-attribution.ts`, `tools/representative-matrix.ts`
- zig-gc: `89b6652c81ba892119b7b9ce3b0d07fc78a009ff`
- zig-regex: `87e9ca28fa14194dd1e8b4cae7461e179331efca`
- host class: `quiet_reference`
- material-change categories: `cpu_work`
- sampling: 7 order-balanced pairs; no discarded samples
- process quality: every measured invocation used at least 60% CPU occupancy; complete-process occupancy remains diagnostic; before/after snapshots reject persistent competing jobs
- timed boundary: ten production parse plus plain-function admission/compile jobs over one frozen generated closure-free repeated-body source; process startup, two one-job warmups, hardware snapshots, and untimed identical-work allocation replay are outside elapsed_ns

| parent median | candidate median | candidate / parent | parent RSD | candidate RSD | assessment |
| ---: | ---: | ---: | ---: | ---: | --- |
| 36.120 ms | 4.039 ms | 0.112x | 3.23% | 3.03% | `blocked_efficiency_evidence` |

| memory/allocation metric | parent median | candidate median | candidate / parent | parent RSD | candidate RSD |
| --- | ---: | ---: | ---: | ---: | ---: |
| `peak_rss_bytes` | 9404416 | 9453568 | 1.0052x | 7.93% | 0.22% |
| `allocations` | 32240 | 32330 | 1.0028x | 0.00% | 0.00% |
| `allocated_bytes` | 25300940 | 26038940 | 1.0292x | 0.00% | 0.00% |

| efficiency metric | parent median | candidate median | candidate / parent | parent RSD | candidate RSD |
| --- | ---: | ---: | ---: | ---: | ---: |
| `instructions` | 637960069 | 75768726 | 0.1188x | 0.07% | 0.02% |
| `cycles` | 130615895 | 14752679 | 0.1129x | 1.50% | 2.43% |
| `energy_joules` | 0.163649885 | 0 | 0.0000x | 7.80% | 264.58% |

Thermal states: `nominal->nominal`. Unmet category metrics: none. Efficiency evidence: `blocked_or_diagnostic`.

All input identities and checksums matched. Missing attribution values are encoded as unavailable with a reason, never as zero.
