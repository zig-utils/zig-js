# Exact-parent algorithmic growth — representative_frontend_compile_loop_capture_clear_<width>

- parent: `e6200a825fb72536a690ca5d02db4b452674bbba`
- candidate: `0bfd79d061946075d863abf04b1a75ced35fc663`
- zig-gc: `89b6652c81ba892119b7b9ce3b0d07fc78a009ff`
- zig-regex: `87e9ca28fa14194dd1e8b4cae7461e179331efca`
- Zig: `0.17.0-dev.1441+d5181a9c9`
- host: arm64; Apple M3 Pro
- OS: Darwin Chris-MacBook 27.0.0 Darwin Kernel Version 27.0.0: Tue Aug 11 22:03:57 PDT 2026; root:xnu-13432.1.9~3/RELEASE_ARM64_T6030 arm64 arm Darwin
- host class: `quiet_reference`
- widths: 1024, 2048, 4096; 7 order-balanced pairs per width; no samples discarded
- scored boundary: Only normalized retired instructions and exact allocation replay are scored across frozen input widths. Wall time, CPU time, RSS, cycles, energy, and thermal observations are retained from the embedded exact-parent artifacts as diagnostics and cannot support a throughput, latency, energy, or full-efficiency claim.

This artifact does **not** score wall time, throughput, latency, cycles, energy, RSS, or thermals. Those complete observations and each ordinary full-efficiency decision remain embedded below the aggregate raw artifact.

| width | jobs | checksum | parent instructions/job | parent RSD | candidate instructions/job | candidate RSD | candidate/parent | allocations/job P/C | bytes/job P/C | ordinary A/B status |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| 1024 | 10 | 9176097750 | 62863205.30 | 0.00% | 6560014.60 | 0.01% | 0.1044x | 2211 / 2220 | 2064466 / 2134178 | blocked_efficiency_evidence |
| 2048 | 10 | 3449065800 | 239154160.90 | 0.00% | 13294489.00 | 0.01% | 0.0556x | 4279 / 4289 | 4627314 / 4766682 | blocked_efficiency_evidence |
| 4096 | 10 | 2671656920 | 931289680.90 | 0.00% | 26558634.00 | 0.03% | 0.0285x | 8394 / 8405 | 8646922 / 8925578 | pass |

| interval | width ratio | parent instruction ratio | parent exponent | candidate instruction ratio | candidate exponent |
| --- | ---: | ---: | ---: | ---: | ---: |
| 1024 → 2048 | 2.00x | 3.8044x | 1.928 | 2.0266x | 1.019 |
| 2048 → 4096 | 2.00x | 3.8941x | 1.961 | 1.9977x | 0.998 |

First→last (1024→4096) instruction growth: parent 14.8145x (exponent 1.944), candidate 4.0486x (exponent 1.009).

## Embedded source artifacts

- 1024: `exact-parent-loop-capture-clear-1024-2026-09-01.json` (file SHA-256 `50a0f9dd1474bda646f36dbd9afb27eedf1ffd7f4f9839a29ee7be572d1e6983`; embedded SHA-256 `81088dd86277122e64f43eedf00efd71b3bbc7fd2a96c5d6d6b800a18fdc7868`)
- 2048: `exact-parent-loop-capture-clear-2048-2026-09-01.json` (file SHA-256 `b2529ae309db168a94a056c794660b386125adb16b84390582f7d629a89b2a82`; embedded SHA-256 `7f60d6a9e19e7c9fdfaade0354175e1d948145383355c2bcf6e9c35b80e868e1`)
- 4096: `exact-parent-loop-capture-clear-4096-2026-09-01.json` (file SHA-256 `6ce5f185db95ddba05b826535abbdb1e19547565ffc5b52b19b98d056c9f6306`; embedded SHA-256 `bac02711e289d062ddf04e958c819ed67e9c4e2ed8089781cd8588e6563e26e3`)

Power observations: `Now drawing from 'AC Power' -InternalBattery-0 (id=40239203) 100%; charged; 0:00 remaining present: true`.
Timed boundaries retained from the ordinary inputs: `ten production parse plus plain-function admission/compile jobs over one frozen generated closure-free lexical loop-head source; process startup, two one-job warmups, hardware snapshots, and untimed identical-work allocation replay are outside elapsed_ns`.
