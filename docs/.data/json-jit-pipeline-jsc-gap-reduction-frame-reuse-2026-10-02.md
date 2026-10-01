# Frozen JSON JSC gap reduction — 2026-10-02

> Same-window baseline/candidate/JSC diagnostic for issues #1019 and #473, not a universal engine score.
> Lower time is better; gap reduction is computed only from the order-balanced triplets below.

## Provenance

| item | value |
| --- | --- |
| date | 2026-10-02 |
| host | Apple M2 Pro; 17179869184 bytes |
| os | macOS 26.3.1 (25D771280a) |
| power | Now drawing from 'Battery Power' -InternalBattery-0 (id=21364835) 95%; discharging; 4:31 remaining present: true |
| zig_version | 0.17.0-dev.2163+89ff10d56 |
| collector_revision | 4099e91d15e3c50983266b42df2bb9838e0bba9c |
| zig_js_binary_revision | b617e7cfa583e3f67acff79bdecfbf877fb44530 |
| zig_gc_revision | 0285ef801dd221a4ae8e88b31a09ae31627657a3 |
| zig_regex_revision | fdd9c2e333ea6ac2fd06d080d939ef7f11d61b1b |
| workload_source | bench/representative_comparison.js |
| workload_source_sha256 | 89a7e4ebceb8993fa287d3ab886cec55d63436d74c21c139cfe57b24b08f9c34 |
| zig_js_binary_sha256 | 2842828dccca250d8f5887968c4e2a608060c6b3e155d39ed09508821d179a10 |
| optimize | ReleaseFast |
| allocator | real precise collector; GC enabled |
| timed_boundary | warmed persistent context; one exact invocation |
| samples | 7 |
| minimum_median_ns | 50000000 |
| sample_order | fresh-process alternating pairs, offset by workload |
| host_class | diagnostic |
| baseline_zig_js_binary_revision | 8ca0d15b180ff40fa942e21821ac36ddfe4d272d |
| baseline_zig_js_binary_sha256 | 68224516a680918bb105f886c736fd12ca74656825fbe469095e4ee597573565 |
| jsc_binary_sha256 | fc17950d5e664022e6a3a79f4bdca1a029e1a5731d4ec18fe286a17417076fd3 |
| javascriptcore | system framework 21623.2.7.111.2 |

## Result

| workload | role | jobs | baseline median | baseline RSD | candidate median | candidate RSD | candidate / baseline | JSC median | JSC RSD | baseline gap | candidate gap | gap reduction | checksum |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `representative_json` | frozen parse/stringify row | 2200 | 335.951 ms | 13.53% | 330.580 ms | 2.02% | 0.984x | 85.628 ms | 11.01% | 3.92x | 3.86x | 1.6% | 324952086 |
| `representative_json_variant` | anti-specialization variant | 2200 | 352.353 ms | 10.58% | 334.850 ms | 1.92% | 0.950x | 84.813 ms | 1.29% | 4.15x | 3.95x | 5.0% | 324952086 |
| `representative_json_reviver_source` | reviver/source control | 128 | 879.187 ms | 1.73% | 877.355 ms | 2.35% | 0.998x | 175.203 ms | 1.45% | 5.02x | 5.01x | 0.2% | 4299681984 |
| `representative_json_escaped_strings` | escaped-string control | 500 | 482.044 ms | 52.03% | 966.091 ms | 42.49% | 2.004x | 123.520 ms | 30.10% | 3.90x | 7.82x | -100.4% | 121471500 |
| `representative_json_stringify_depth_4096` | deep-stringify control | 1200 | 1177.338 ms | 3.86% | 1128.827 ms | 13.36% | 0.959x | 111.894 ms | 13.97% | 10.52x | 10.09x | 4.1% | 83848800 |
| `representative_json_stringify_shallow_4096` | shallow-stringify control | 1400 | 985.698 ms | 30.01% | 957.522 ms | 28.52% | 0.971x | 107.562 ms | 41.56% | 9.16x | 8.90x | 2.9% | 63340200 |

## Method

- 7 fresh-process, order-balanced triplets per row; no sample was discarded.
- Baseline, candidate, and JSC evaluate the same frozen workload bytes with identical jobs, warmup, timed boundary, and checksum.
- The six possible runner orders rotate across workloads and samples, so each appears equally often over the complete matrix.
- Both zig-js runners are ReleaseFast with the same real precise collector and zig-regex revisions. JSC links the system framework.
- The collector rejects variant/engine identity, checksum, sample-index, triplet-order, and 50 ms median-floor drift before writing either artifact.
- Host scheduling and frequency are not controlled, so every RSD remains visible and the result remains diagnostic.

Raw evidence: [json-jit-pipeline-jsc-gap-reduction-frame-reuse-2026-10-02.json](json-jit-pipeline-jsc-gap-reduction-frame-reuse-2026-10-02.json)
