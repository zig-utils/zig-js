# Frozen JSON pipeline versus JavaScriptCore — 2026-10-17

> Focused diagnostic for issue #473, not a universal engine score.
> Controls are scaled only to clear the same 50 ms timing floor as the touched rows.

## Provenance

| item | value |
| --- | --- |
| date | 2026-10-17 |
| host | Apple M2 Pro; 17179869184 bytes |
| os | macOS 26.3.1 (25D771280a) |
| power | Now drawing from 'AC Power' -InternalBattery-0 (id=21364835) 99%; finishing charge; 0:10 remaining present: true |
| zig_version | 0.18.0-dev.146+35accc06e |
| collector_revision | f0072c95780712d1bb789280e08e7e390e83ab94 |
| zig_js_binary_revision | f0072c95780712d1bb789280e08e7e390e83ab94 |
| zig_gc_revision | 0285ef801dd221a4ae8e88b31a09ae31627657a3 |
| zig_regex_revision | fdd9c2e333ea6ac2fd06d080d939ef7f11d61b1b |
| workload_source | bench/representative_comparison.js |
| workload_source_sha256 | 89a7e4ebceb8993fa287d3ab886cec55d63436d74c21c139cfe57b24b08f9c34 |
| zig_js_binary_sha256 | ce461e415e73dddf25ff131a94bde4773fe5d105133c44039fb717df0ed9c610 |
| optimize | ReleaseFast |
| allocator | real precise collector; GC enabled |
| timed_boundary | warmed persistent context; one exact invocation |
| samples | 7 |
| minimum_median_ns | 50000000 |
| sample_order | fresh-process alternating pairs, offset by workload |
| host_class | diagnostic |
| jsc_binary_sha256 | a7e2820f4f73819e1510ab74b8ee9e55c99240132843cf87d55b2e10239d0fb7 |
| javascriptcore | system framework 21623.2.7.111.2 |

## Result

Lower time is better. `JSC / zig-js` is JSC throughput divided by zig-js throughput.
Every row uses one warmed, GC-enabled context per fresh process and preserves the exact checksum.

| workload | role | jobs | zig-js median | zig-js RSD | JSC median | JSC RSD | JSC / zig-js | checksum |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `representative_json` | frozen parse/stringify row | 2200 | 277.927 ms | 1.55% | 86.136 ms | 1.23% | 3.23x | 324952086 |
| `representative_json_variant` | anti-specialization variant | 2200 | 277.350 ms | 1.38% | 85.487 ms | 42.14% | 3.24x | 324952086 |
| `representative_json_reviver_source` | reviver/source control | 128 | 911.934 ms | 40.38% | 170.814 ms | 1.46% | 5.34x | 4299681984 |
| `representative_json_escaped_strings` | escaped-string control | 500 | 513.856 ms | 2.62% | 122.435 ms | 1.45% | 4.20x | 121471500 |
| `representative_json_stringify_depth_4096` | deep-stringify control | 1200 | 996.713 ms | 2.60% | 110.525 ms | 1.23% | 9.02x | 83848800 |
| `representative_json_stringify_shallow_4096` | shallow-stringify control | 1400 | 742.772 ms | 0.87% | 103.743 ms | 1.06% | 7.16x | 63340200 |

## Method

- 7 fresh-process, order-balanced pairs per row; no sample was discarded.
- Both runners evaluate the same frozen `bench/representative_comparison.js` bytes and time the same invocation after their built-in reduced-size warmup.
- The zig-js runner is ReleaseFast with the real precise collector checkout recorded above. The JSC runner links the system JavaScriptCore framework.
- The collector rejects identity, job-count, checksum, sample-index, pair-order, and 50 ms median-floor drift before writing either artifact.
- Every invocation is bracketed by fail-closed competing-process snapshots; host scheduling and frequency are otherwise not controlled, so RSD is retained and the matrix remains diagnostic.

Raw evidence: [json-jit-pipeline-jsc-2026-10-17.json](json-jit-pipeline-jsc-2026-10-17.json)
