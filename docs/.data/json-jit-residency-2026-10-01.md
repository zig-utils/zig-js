# Frozen JSON JIT residency — 2026-10-01

> Focused JIT-versus-required-VM diagnostic for issue #1017.
> Lower time is better; a JIT/VM ratio at or below 1.0 clears the residency throughput gate.

## Provenance

| item | value |
| --- | --- |
| date | 2026-10-01 |
| host | Apple M2 Pro; 17179869184 bytes |
| os | macOS 26.3.1 (25D771280a) |
| power | Now drawing from 'AC Power' -InternalBattery-0 (id=21364835) 100%; finishing charge; 0:00 remaining present: true |
| zig_version | 0.17.0-dev.2163+89ff10d56 |
| collector_revision | 8c2a68bb3f2afbb177bd3f862b8155a3d0cc6d0c |
| zig_js_binary_revision | 8ca0d15b180ff40fa942e21821ac36ddfe4d272d |
| zig_gc_revision | 0285ef801dd221a4ae8e88b31a09ae31627657a3 |
| zig_regex_revision | fdd9c2e333ea6ac2fd06d080d939ef7f11d61b1b |
| workload_source | bench/representative_comparison.js |
| workload_source_sha256 | 89a7e4ebceb8993fa287d3ab886cec55d63436d74c21c139cfe57b24b08f9c34 |
| zig_js_binary_sha256 | 3e8803419aa33b45b7c6a79b3595917c834dfba340b5a61cc4dd47405a1e4ae3 |
| optimize | ReleaseFast |
| allocator | real precise collector; GC enabled |
| timed_boundary | warmed persistent context; one exact invocation |
| samples | 7 |
| minimum_median_ns | 50000000 |
| sample_order | fresh-process alternating pairs, offset by workload |
| host_class | diagnostic |

## Result

| workload | jobs | JIT median | JIT RSD | required VM median | VM RSD | JIT / VM | checksum |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `representative_json` | 2200 | 358.241 ms | 2.55% | 361.719 ms | 11.25% | 0.990x | 324952086 |
| `representative_json_variant` | 2200 | 354.177 ms | 2.09% | 357.100 ms | 1.81% | 0.992x | 324952086 |

## Method

- 7 fresh-process, order-balanced pairs per row; no sample was discarded.
- Both modes use the same ReleaseFast binary, real precise collector, workload bytes, warmup, jobs, and timed invocation.
- `single` enables the shipping native tiers. `single_no_jit` disables JIT and requires bytecode execution.
- The collector rejects mode, identity, checksum, sample-index, pair-order, and 50 ms median-floor drift.
- Host scheduling and frequency are not controlled, so RSD is retained and the result remains diagnostic.

Raw evidence: [json-jit-residency-2026-10-01.json](json-jit-residency-2026-10-01.json)
