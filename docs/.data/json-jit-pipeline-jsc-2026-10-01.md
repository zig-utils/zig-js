# Frozen JSON pipeline versus JavaScriptCore — 2026-10-01

> Focused diagnostic for issue #473, not a universal engine score.
> Controls are scaled only to clear the same 50 ms timing floor as the touched rows.

## Provenance

| item | value |
| --- | --- |
| date | 2026-10-01 |
| host | Apple M2 Pro; 17179869184 bytes |
| os | macOS 26.3.1 (25D771280a) |
| power | Now drawing from 'AC Power' -InternalBattery-0 (id=21364835) 99%; finishing charge; 0:03 remaining present: true |
| zig_version | 0.17.0-dev.2163+89ff10d56 |
| collector_revision | 9fa9b581f89159d9eae9462392d605794f38bc78 |
| zig_js_binary_revision | 8ca0d15b180ff40fa942e21821ac36ddfe4d272d |
| zig_gc_revision | 0285ef801dd221a4ae8e88b31a09ae31627657a3 |
| zig_regex_revision | fdd9c2e333ea6ac2fd06d080d939ef7f11d61b1b |
| workload_source | bench/representative_comparison.js |
| workload_source_sha256 | 89a7e4ebceb8993fa287d3ab886cec55d63436d74c21c139cfe57b24b08f9c34 |
| zig_js_binary_sha256 | 3e8803419aa33b45b7c6a79b3595917c834dfba340b5a61cc4dd47405a1e4ae3 |
| jsc_binary_sha256 | bbad0fbfeba7eca1d551c6356ffe9f9a290dbbb3e3b71be62ee1c61b1dd85805 |
| javascriptcore | system framework 21623.2.7.111.2 |
| optimize | ReleaseFast |
| allocator | real precise collector; GC enabled |
| timed_boundary | warmed persistent context; one exact invocation |
| samples | 7 |
| minimum_median_ns | 50000000 |
| sample_order | fresh-process alternating pairs, offset by workload |
| host_class | diagnostic |

## Result

Lower time is better. `JSC / zig-js` is JSC throughput divided by zig-js throughput.
Every row uses one warmed, GC-enabled context per fresh process and preserves the exact checksum.

| workload | role | jobs | zig-js median | zig-js RSD | JSC median | JSC RSD | JSC / zig-js | checksum |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `representative_json` | frozen parse/stringify row | 2200 | 354.428 ms | 1.69% | 87.525 ms | 1.40% | 4.05x | 324952086 |
| `representative_json_variant` | anti-specialization variant | 2200 | 354.813 ms | 1.74% | 87.752 ms | 1.45% | 4.04x | 324952086 |
| `representative_json_reviver_source` | reviver/source control | 128 | 889.095 ms | 2.81% | 176.796 ms | 2.72% | 5.03x | 4299681984 |
| `representative_json_escaped_strings` | escaped-string control | 500 | 466.417 ms | 2.18% | 124.876 ms | 2.06% | 3.74x | 121471500 |
| `representative_json_stringify_depth_4096` | deep-stringify control | 1200 | 1163.341 ms | 17.58% | 111.120 ms | 2.82% | 10.47x | 83848800 |
| `representative_json_stringify_shallow_4096` | shallow-stringify control | 1400 | 966.656 ms | 3.31% | 104.796 ms | 1.32% | 9.22x | 63340200 |

## Method

- 7 fresh-process, order-balanced pairs per row; no sample was discarded.
- Both runners evaluate the same frozen `bench/representative_comparison.js` bytes and time the same invocation after their built-in reduced-size warmup.
- The zig-js runner is ReleaseFast with the real precise collector checkout recorded above. The JSC runner links the system JavaScriptCore framework.
- The collector rejects identity, job-count, checksum, sample-index, pair-order, and 50 ms median-floor drift before writing either artifact.
- Host scheduling and frequency are not controlled, so RSD is retained and the matrix remains diagnostic.

Raw evidence: [json-jit-pipeline-jsc-2026-10-01.json](json-jit-pipeline-jsc-2026-10-01.json)
