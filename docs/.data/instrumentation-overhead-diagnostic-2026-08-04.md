# Instrumentation overhead — representative_json

- date: 2026-08-04
- host: Apple M3 Pro; 11 physical / 11 logical CPUs; 18.0 GiB
- OS: macOS 27.0 (26A5388g)
- Zig: 0.17.0-dev.1441+d5181a9c9
- zig-js: `2fa97532c28dda7391b9ce1d083852495d10c92f`
- zig-gc: `c89a10fc4454bfba3d28183cfa7fade08fab8aa4`
- zig-regex: `2de46683b948ec895e5fa9a9e7e4c384aceccdfe`
- power: Now drawing from 'Battery Power' -InternalBattery-0 (id=22151267) 56%; discharging; (no estimate) present: true
- host class: `diagnostic`
- runner: `3bebcb0f1694c8e9d36fdd98ee1881037c3300e0ad747e8d5a6a1d7df76cc439` (9235240 bytes; one binary for both states)
- workload source: `bench/representative_comparison.js` (SHA-256 `8ebd7f2eac703336c36d323cb1ef304bbccfb16d1c5cf2832e65a63a90ed5911`)
- sampling: 7 alternating disabled/enabled pairs; no discarded samples
- logical work: 2200 jobs; frozen checksum 324952086
- timed boundary: one warmed single-context invocation; process CPU and peak RSS cover the fresh runner process

| metric | disabled median | enabled median | enabled / disabled |
| --- | ---: | ---: | ---: |
| `wall_time_ns` | 574391792 ns | 568206916 ns | 0.9892x |
| `process_cpu_user_ns` | 1070000000 ns | 1070000000 ns | 1.0000x |
| `process_cpu_system_ns` | 80000000 ns | 80000000 ns | 1.0000x |
| `peak_rss_bytes` | 1426259968 bytes | 1426259968 bytes | 1.0000x |
| `instructions` | 19621063455 count | 19620119346 count | 1.0000x |
| `cycles` | 4180677189 count | 4189780891 count | 1.0022x |
| `voluntary_context_switches` | 0 count | 0 count | N/A |
| `involuntary_context_switches` | 69 count | 62 count | 0.8986x |

Retained RSS is unavailable because each measurement exits after one sample. Lock contention is not applicable to this single-thread fixture. Both states use the exact same runner, so this runtime-toggle A/B does not claim to measure compile-time support code size.

This is diagnostic evidence. It does not establish a negligible-overhead publication claim; that requires an explicitly selected quiet reference host on AC power.

Raw samples: [`instrumentation-overhead-diagnostic-2026-08-04.json`](instrumentation-overhead-diagnostic-2026-08-04.json)
