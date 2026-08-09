# Build feedback — 2026-08-09

Exact clean-source measurements for [#494](https://github.com/zig-utils/zig-js/issues/494) at zig-js `6582207afca3275981df29ca1d7d4604bba7e8db`.

- host: Apple M3 Pro; arm64; 11 logical CPUs; 18432.0 MiB
- OS: Darwin Chris-MacBook 27.0.0 Darwin Kernel Version 27.0.0: Tue Jul 14 21:38:48 PDT 2026; root:xnu-13432.0.94.501.4~1/RELEASE_ARM64_T6030 arm64
- Zig: `0.17.0-dev.1441+d5181a9c9` at `/Users/chris/.local/share/pantry/global/packages/ziglang.org/v0.17.0-dev.1441_d5181a9c9/bin/zig`
- zig-gc: `89b6652c81ba892119b7b9ce3b0d07fc78a009ff`; zig-regex: `719673318b0c6250898d7ced3603876c148e370b`
- power: Now drawing from 'AC Power' ·  -InternalBattery-0 (id=28442723)	61%; charging; (no estimate) present: true
- sampling: 3 sequential samples per phase; median; no outlier removal; isolated local/global caches per sample sequence

| phase | scope | median wall | wall range | median CPU (user + system) | median peak RSS |
| --- | --- | ---: | ---: | ---: | ---: |
| `clean_library` | empty isolated local/global caches; build the library and installed headers | 67.08 s | 66.31 s–80.35 s | 68.68 s | 2061.8 MiB |
| `incremental_library` | repeat the library build against the immediately preceding isolated caches | 0.13 s | 0.12 s–0.13 s | 0.15 s | 31.0 MiB |
| `focused_test_relink` | build the combined Debug unit artifact and run the executable-memory filter | 33.42 s | 29.01 s–33.55 s | 32.35 s | 2371.4 MiB |
| `focused_test_cached` | reuse the linked Debug unit artifact with a different one-test runtime filter | 0.35 s | 0.33 s–0.35 s | 0.21 s | 31.2 MiB |
| `full_unit_cold_history` | run the complete unit suite across 10 shards with an empty timing-history directory | 214.08 s | 211.87 s–244.45 s | 1028.84 s | 789.9 MiB |
| `full_unit_warm_history` | repeat the complete 10-shard suite using the immediately preceding timing history | 170.33 s | 149.02 s–183.60 s | 989.93 s | 1014.3 MiB |
| `tsan_focused` | build the TSan unit artifact and run the executable-memory filter | 53.86 s | 52.16 s–60.55 s | 116.17 s | 2992.7 MiB |

Wall time covers the complete listed `zig build` invocation. User/system CPU and peak RSS are `/usr/bin/time -lp` observations for that build process and its children; they are not compiler-internal phase counters. Every raw command, exit status, build summary, stdout, stderr, and sample is retained.

Raw evidence: [build-feedback-2026-08-09.json](build-feedback-2026-08-09.json).
