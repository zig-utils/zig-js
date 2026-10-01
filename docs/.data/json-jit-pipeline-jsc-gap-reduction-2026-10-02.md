# Frozen JSON JSC gap reduction — 2026-10-02

> Same-window baseline/candidate/JSC diagnostic for issues #1019 and #473, not a universal engine score.
> Lower time is better; gap reduction is computed only from the order-balanced triplets below.

## Provenance

| item | value |
| --- | --- |
| date | 2026-10-02 |
| host | Apple M2 Pro; 17179869184 bytes |
| os | macOS 26.3.1 (25D771280a) |
| power | Now drawing from 'AC Power' -InternalBattery-0 (id=21364835) 99%; finishing charge; 0:06 remaining present: true |
| zig_version | 0.17.0-dev.2163+89ff10d56 |
| collector_revision | 29435dfda2f4e3022a72b448bb6216bf7a5347e4 |
| zig_js_binary_revision | b6ae21478930e03e8bbbc024e5ba2b3cb75e5e14 |
| zig_gc_revision | 0285ef801dd221a4ae8e88b31a09ae31627657a3 |
| zig_regex_revision | fdd9c2e333ea6ac2fd06d080d939ef7f11d61b1b |
| workload_source | bench/representative_comparison.js |
| workload_source_sha256 | 89a7e4ebceb8993fa287d3ab886cec55d63436d74c21c139cfe57b24b08f9c34 |
| zig_js_binary_sha256 | 197eecd28d90b6fe6462c708737476767639470dbd251c5b39efe73ee4d9080e |
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
| `representative_json` | frozen parse/stringify row | 2200 | 352.456 ms | 2.19% | 335.479 ms | 1.08% | 0.952x | 88.151 ms | 1.44% | 4.00x | 3.81x | 4.8% | 324952086 |
| `representative_json_variant` | anti-specialization variant | 2200 | 353.409 ms | 27.33% | 336.130 ms | 25.40% | 0.951x | 87.029 ms | 50.15% | 4.06x | 3.86x | 4.9% | 324952086 |
| `representative_json_reviver_source` | reviver/source control | 128 | 855.039 ms | 0.77% | 856.149 ms | 43.40% | 1.001x | 172.208 ms | 1.95% | 4.97x | 4.97x | -0.1% | 4299681984 |
| `representative_json_escaped_strings` | escaped-string control | 500 | 451.487 ms | 1.71% | 456.794 ms | 1.62% | 1.012x | 122.155 ms | 0.95% | 3.70x | 3.74x | -1.2% | 121471500 |
| `representative_json_stringify_depth_4096` | deep-stringify control | 1200 | 1139.308 ms | 0.46% | 1254.352 ms | 41.42% | 1.101x | 109.737 ms | 0.89% | 10.38x | 11.43x | -10.1% | 83848800 |
| `representative_json_stringify_shallow_4096` | shallow-stringify control | 1400 | 949.202 ms | 0.12% | 743.663 ms | 39.98% | 0.783x | 104.756 ms | 0.78% | 9.06x | 7.10x | 21.7% | 63340200 |

## Method

- 7 fresh-process, order-balanced triplets per row; no sample was discarded.
- Baseline, candidate, and JSC evaluate the same frozen workload bytes with identical jobs, warmup, timed boundary, and checksum.
- The six possible runner orders rotate across workloads and samples, so each appears equally often over the complete matrix.
- Both zig-js runners are ReleaseFast with the same real precise collector and zig-regex revisions. JSC links the system framework.
- The collector rejects variant/engine identity, checksum, sample-index, triplet-order, and 50 ms median-floor drift before writing either artifact.
- Host scheduling and frequency are not controlled, so every RSD remains visible and the result remains diagnostic.

Raw evidence: [json-jit-pipeline-jsc-gap-reduction-2026-10-02.json](json-jit-pipeline-jsc-gap-reduction-2026-10-02.json)
