# Exact-parent performance A/B — representative_frontend_compile_loop_capture_clear_2048 (single, 1 lane(s))

- logical parent: `e6200a825fb72536a690ca5d02db4b452674bbba`
- logical candidate: `0bfd79d061946075d863abf04b1a75ced35fc663`
- parent binary revision: `5a1d235291e3ba8d7399ee901793297c134b7f08`
- candidate binary revision: `1bd20cbc640037f28f8501085de2a93365b0d42c`
- shared measurement overlay: `bench/comparison_zig_js.zig`, `bench/frontend_parse.zig`, `docs/.data/algorithmic-growth-schema-v2.json`, `docs/.data/bunpress-output-v1.json`, `docs/.data/performance-attribution-schema-v2.json`, `docs/.data/representative-benchmark-matrix-v24.json`, `docs/benchmarks.md`, `tools/algorithmic-growth.ts`, `tools/evidence-processes.ts`, `tools/exact-parent-regression.ts`, `tools/instrumentation-overhead.ts`, `tools/performance-attribution.ts`, `tools/representative-matrix.ts`
- zig-gc: `89b6652c81ba892119b7b9ce3b0d07fc78a009ff`
- zig-regex: `87e9ca28fa14194dd1e8b4cae7461e179331efca`
- host class: `quiet_reference`
- material-change categories: `cpu_work`
- sampling: 7 order-balanced pairs; no discarded samples
- process quality: every measured invocation used at least 60% CPU occupancy; complete-process occupancy remains diagnostic; before/after snapshots reject persistent competing jobs
- timed boundary: ten production parse plus plain-function admission/compile jobs over one frozen generated closure-free lexical loop-head source; process startup, two one-job warmups, hardware snapshots, and untimed identical-work allocation replay are outside elapsed_ns

| parent median | candidate median | candidate / parent | parent RSD | candidate RSD | assessment |
| ---: | ---: | ---: | ---: | ---: | --- |
| 98.891 ms | 7.188 ms | 0.073x | 1.55% | 3.18% | `blocked_efficiency_evidence` |

| memory/allocation metric | parent median | candidate median | candidate / parent | parent RSD | candidate RSD |
| --- | ---: | ---: | ---: | ---: | ---: |
| `peak_rss_bytes` | 11649024 | 11730944 | 1.0070x | 0.00% | 0.07% |
| `allocations` | 42790 | 42890 | 1.0023x | 0.00% | 0.00% |
| `allocated_bytes` | 46273140 | 47666820 | 1.0301x | 0.00% | 0.00% |

| efficiency metric | parent median | candidate median | candidate / parent | parent RSD | candidate RSD |
| --- | ---: | ---: | ---: | ---: | ---: |
| `instructions` | 2391541609 | 132944890 | 0.0556x | 0.00% | 0.01% |
| `cycles` | 362990906 | 26588121 | 0.0732x | 0.52% | 3.15% |
| `energy_joules` | 0.552600705 | 0 | 0.0000x | 3.49% | 264.58% |

Thermal states: `nominal->nominal`. Unmet category metrics: none. Efficiency evidence: `blocked_or_diagnostic`.

All input identities and checksums matched. Missing attribution values are encoded as unavailable with a reason, never as zero.
