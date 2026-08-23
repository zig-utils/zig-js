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

- 1024: `exact-binding_inventory_unique-1024-2026-08-23.json` (file SHA-256 `e42046f943959019e3fa156ce3030ebd6936c6f4fe337aad2b7130f9d82adbf6`; embedded SHA-256 `a3be77a079aceb57e99241bae1f256b7ee4b3fbfe8435a76e14773e1276b1f9a`)
- 2048: `exact-binding_inventory_unique-2048-2026-08-23.json` (file SHA-256 `4e8fd00f15fdab25b8365adbea50ca99cdc235229445f3fb8f60f807a905bf3b`; embedded SHA-256 `e5153fa054879ba7e9cfc392aee7123693d600f2e32165b7ddd4b95ff35fd549`)
- 4096: `exact-binding_inventory_unique-4096-2026-08-23.json` (file SHA-256 `6565a2d242c896cdc0e54987cb160a3298b05303f376f715d0ed53c61002988a`; embedded SHA-256 `1be9f3f15718574dcdaceee700514d442abb07002d8b7c7434ad872b541db850`)

Power observations: `Now drawing from 'AC Power' -InternalBattery-0 (id=38535267) 100%; charged; 0:00 remaining present: true`, `Now drawing from 'Battery Power' -InternalBattery-0 (id=38535267) 72%; discharging; (no estimate) present: true`, `Now drawing from 'Battery Power' -InternalBattery-0 (id=38535267) 84%; discharging; (no estimate) present: true`.
Timed boundaries retained from the ordinary inputs: `ten production parse plus plain-function admission/compile jobs over one frozen generated source; process startup, twenty warmup jobs, hardware snapshots, and allocation replay are outside elapsed_ns`.
