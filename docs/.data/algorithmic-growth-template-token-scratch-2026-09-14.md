# Exact-parent algorithmic growth — representative_frontend_templates_tagged_substitutions_<width>

- parent: `bff189afd18a122ad0b6c5919b45e684fa92c0fc`
- candidate: `261981c53b904158e0b2fdc090500fad9a4dacdf`
- binary provenance: `direct`
- zig-gc: `0285ef801dd221a4ae8e88b31a09ae31627657a3`
- zig-regex: `c60344dec54f71efe885c62a02e29dfd7ab0f5c0`
- Zig: `0.17.0-dev.1441+d5181a9c9`
- host: arm64; Apple M2 Pro
- OS: Darwin Glenns-M2-Macbook-Pro.local 25.3.0 Darwin Kernel Version 25.3.0: Wed Jan 28 20:55:08 PST 2026; root:xnu-12377.91.3~2/RELEASE_ARM64_T6020 arm64
- host class: `diagnostic`
- widths: 1024, 2048, 4096; 7 order-balanced pairs per width; no samples discarded
- scored boundary: Only normalized retired instructions and exact allocation replay are scored across frozen input widths. Wall time, CPU time, RSS, cycles, energy, and thermal observations are retained from the embedded exact-parent artifacts as diagnostics and cannot support a throughput, latency, energy, or full-efficiency claim.

This artifact does **not** score wall time, throughput, latency, cycles, energy, RSS, or thermals. Those complete observations and each ordinary full-efficiency decision remain embedded below the aggregate raw artifact.

| width | jobs | checksum | parent instructions/job | parent RSD | candidate instructions/job | candidate RSD | candidate/parent | allocations/job P/C | bytes/job P/C | ordinary A/B status |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| 1024 | 1000 | 563665000 | 3020824.04 | 0.05% | 2977722.03 | 0.02% | 0.9857x | 2061 / 1038 | 354384 / 125232 | diagnostic_only |
| 2048 | 1000 | 2176977000 | 6131525.46 | 0.10% | 6065548.15 | 0.03% | 0.9892x | 4109 / 2062 | 706640 / 248112 | diagnostic_only |
| 4096 | 1000 | 8549329000 | 12338840.84 | 0.06% | 12226714.88 | 0.02% | 0.9909x | 8205 / 4110 | 1411152 / 493872 | diagnostic_only |

| interval | width ratio | parent instruction ratio | parent exponent | candidate instruction ratio | candidate exponent |
| --- | ---: | ---: | ---: | ---: | ---: |
| 1024 → 2048 | 2.00x | 2.0298x | 1.021 | 2.0370x | 1.026 |
| 2048 → 4096 | 2.00x | 2.0124x | 1.009 | 2.0158x | 1.011 |

First→last (1024→4096) instruction growth: parent 4.0846x (exponent 1.015), candidate 4.1061x (exponent 1.019).

## Embedded source artifacts

- 1024: `exact-parent-template-token-scratch-1024-2026-09-14.json` (file SHA-256 `a726dd343951777a0728383081aac042c234e7ba3cd1cd343490f681739423f4`; embedded SHA-256 `df71f51fad2121e3d7b45957430ce0cbbf232c01cf715d9a1bbe2fc221b9b5fc`)
- 2048: `exact-parent-template-token-scratch-2048-2026-09-14.json` (file SHA-256 `251bc904a544166135ee23582b8bf9ca136e2872622faee754946db27461864a`; embedded SHA-256 `528bca31b37c302ba173b01627329faa144e93a6f49143c9932a6763ce296cb2`)
- 4096: `exact-parent-template-token-scratch-4096-2026-09-14.json` (file SHA-256 `4c52a09303769daa626108e67ce7e311002343d48c71f81a86d1d1b9db1e1cd5`; embedded SHA-256 `26ea6271fe325c24cdebfff482d5338f616d0e4c60f3ac0891f49da6e22df137`)

Power observations: `Now drawing from 'AC Power' -InternalBattery-0 (id=21364835) 88%; charging; 0:54 remaining present: true`, `Now drawing from 'AC Power' -InternalBattery-0 (id=21364835) 88%; charging; 0:55 remaining present: true`, `Now drawing from 'AC Power' -InternalBattery-0 (id=21364835) 94%; charging; 1:00 remaining present: true`.
Timed boundaries retained from the ordinary inputs: `Complete parse and AST-shape validation in a fresh arena per job; source generation, warmup, and identical allocation replay excluded`.
