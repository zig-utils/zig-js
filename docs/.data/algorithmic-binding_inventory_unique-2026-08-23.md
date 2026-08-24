# Exact-parent algorithmic growth — representative_frontend_compile_binding_inventory_unique_<width>

- parent: `3bc06b01305fcd2b73973e0cc39dcf35a172c08d`
- candidate: `84efdae532e0bc9a198b3764dc9a20645bea2ed0`
- zig-gc: `89b6652c81ba892119b7b9ce3b0d07fc78a009ff`
- zig-regex: `87e9ca28fa14194dd1e8b4cae7461e179331efca`
- Zig: `0.17.0-dev.1441+d5181a9c9`
- host: arm64; Apple M3 Pro
- OS: Darwin Chris-MacBook 27.0.0 Darwin Kernel Version 27.0.0: Tue Jul 14 21:38:48 PDT 2026; root:xnu-13432.0.94.501.4~1/RELEASE_ARM64_T6030 arm64 arm Darwin
- host class: `quiet_reference`
- widths: 1024, 2048, 4096; 7 order-balanced pairs per width; no samples discarded
- scored boundary: Only normalized retired instructions and exact allocation replay are scored across frozen input widths. Wall time, CPU time, RSS, cycles, energy, and thermal observations are retained from the embedded exact-parent artifacts as diagnostics and cannot support a throughput, latency, energy, or full-efficiency claim.

This artifact does **not** score wall time, throughput, latency, cycles, energy, RSS, or thermals. Those complete observations and each ordinary full-efficiency decision remain embedded below the aggregate raw artifact.

| width | jobs | checksum | parent instructions/job | parent RSD | candidate instructions/job | candidate RSD | candidate/parent | allocations/job P/C | bytes/job P/C | ordinary A/B status |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| 1024 | 10 | 1666649330 | 7065992.70 | 0.07% | 6642817.60 | 0.08% | 0.9401x | 3217 / 3208 | 2529009 / 2426593 | blocked_efficiency_evidence |
| 2048 | 10 | 6552482440 | 14226169.00 | 0.15% | 13367904.00 | 0.20% | 0.9397x | 6307 / 6297 | 5643177 / 5438337 | blocked_efficiency_evidence |
| 4096 | 10 | 6051268060 | 28367436.90 | 0.15% | 26679151.80 | 0.24% | 0.9405x | 12467 / 12456 | 9687953 / 9278289 | blocked_efficiency_evidence |

| interval | width ratio | parent instruction ratio | parent exponent | candidate instruction ratio | candidate exponent |
| --- | ---: | ---: | ---: | ---: | ---: |
| 1024 → 2048 | 2.00x | 2.0133x | 1.010 | 2.0124x | 1.009 |
| 2048 → 4096 | 2.00x | 1.9940x | 0.996 | 1.9958x | 0.997 |

First→last (1024→4096) instruction growth: parent 4.0146x (exponent 1.003), candidate 4.0162x (exponent 1.003).

## Embedded source artifacts

- 1024: `exact-binding_inventory_unique-1024-2026-08-23.json` (file SHA-256 `2384578ea4fe12eee6aa499e6255a391350a3f0b0eb18e8f3e0c5128a1a5e6b8`; embedded SHA-256 `f429769b76b13c2c65d71ad4ec95d5f7faf2dde5653a4f6bfe4be4b5e5c31828`)
- 2048: `exact-binding_inventory_unique-2048-2026-08-23.json` (file SHA-256 `8835451543146e1b882a637a3639b7a193c55a34f4d0087f337a55ad4581716c`; embedded SHA-256 `34ec9bdf31a5be31df4857a6a0b2b9ee1598b769e83bab6f225ebc13ff9123fb`)
- 4096: `exact-binding_inventory_unique-4096-2026-08-23.json` (file SHA-256 `117478411b9e20814a273be123ce923addc188f70c97e70ec307d0cbfcb2eb3e`; embedded SHA-256 `fd5beb000198e442c0e1cc99942a2e920d0812cd940c27df9a77762fa96a390a`)

Power observations: `Now drawing from 'AC Power' -InternalBattery-0 (id=38535267) 100%; charged; 0:00 remaining present: true`, `Now drawing from 'Battery Power' -InternalBattery-0 (id=38535267) 72%; discharging; (no estimate) present: true`, `Now drawing from 'Battery Power' -InternalBattery-0 (id=38535267) 84%; discharging; (no estimate) present: true`.
Timed boundaries retained from the ordinary inputs: `ten production parse plus plain-function admission/compile jobs over one frozen generated source; process startup, two warmup jobs, hardware snapshots, and allocation replay are outside elapsed_ns`.
