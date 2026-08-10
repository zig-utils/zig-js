# Exact-parent named-deletion allocation attribution — 2026-08-10

- parent: `00848706d4b24487c9a2caf83e12fe7a1b04695f`
- candidate: `253b5b079d8b3698f086e403a86d6052d0eacecd`
- parent runner SHA-256: `57fa021a1d583564d56cb2f29b136eefa7995a3b770673e324f7e2f6121099ba`
- candidate runner SHA-256: `0b88bbce6e774630d728dbb825650b35f3eb116e6af3688975c15c0d8e8a0c3b`
- mode: ReleaseFast `attribution`, one job, one deterministic phase-boundary run per exact revision and workload
- reported values: invocation snapshot minus the post-ten-call warmup snapshot

| workload | checksum | backing allocation calls parent → candidate | allocated bytes parent → candidate | growth calls parent → candidate | retained backing-byte delta parent → candidate |
| --- | ---: | ---: | ---: | ---: | ---: |
| `representative_named_delete_4096` | 1504112 | 4131 → 4141 | 15762278 → 7504214 | 61 → 11 | 15526404 → 6965206 |
| `representative_named_delete_readd_4096` | 1504123 | 4141 → 4152 | 15879226 → 7504436 | 23 → 11 | 15635152 → 6965428 |

The invocation still performs the same checksum-visible reflection work and the same GC-cell issuance. The representation change does not claim fewer allocation calls: it removes the full surviving-object rebuild, cutting attributed backing bytes by about 52.4–52.7%, growth calls by 52.2–82.0%, and retained backing growth by about 55.1–55.5%.

Raw phase snapshots: [exact-parent-named-delete-allocation-2026-08-10.json](exact-parent-named-delete-allocation-2026-08-10.json). Seven-pair CPU/RSS artifacts for the same binaries are recorded alongside this file.
