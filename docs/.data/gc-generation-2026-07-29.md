# GC generation policy — 2026-07-29

> Dated nursery-policy evidence, not a general application benchmark.
> Exact moving/non-moving parents, exact work/checksums, alternating age order, a 50 ms timing floor, byte conservation, zero unscheduled full-GC contamination, zero movement failures, zero conservative-parent timeouts, and at most two bounded moving retries are enforced. Shared moving rows include the one production automatic-compaction follow-on.

## Environment

| item | value |
| --- | --- |
| Date | 2026-07-29 |
| Host | Apple M3 Pro; 11 physical / 11 logical CPUs; 18.0 GiB |
| OS | macOS 27.0 (26A5388g) |
| Zig | 0.17.0-dev.1441+d5181a9c9 |
| zig-js | 7e71eecff7a43bfb3a0b020d57231a7094790fb9 |
| zig-gc | 958563a340ca4517deff05faa785b2c633e8798a |
| Power | Now drawing from 'AC Power' -InternalBattery-0 (id=23330915) 38%; charging; (no estimate) present: true |

## Age-three policy versus age-one control

| trigger | workload | trigger | movement | age 1 median | age 3 median | age 3 throughput | age 3 pause p50 / p95 | age 1 → age 3 promoted | age 1 → age 3 retained backing |
| --- | --- | ---: | --- | ---: | ---: | ---: | ---: | ---: | ---: |
| forced | ephemeral | 4.00 MiB | non-moving | 315.38 ms | 310.23 ms | **1.02x** | 4.811 / 6.202 ms | 0.0% → 0.0% | 12.94 → 12.94 MiB |
| forced | ephemeral | 4.00 MiB | moving | 313.93 ms | 307.64 ms | **1.02x** | 6.906 / 7.918 ms | 0.0% → 0.0% | 12.94 → 12.94 MiB |
| forced | high | 4.00 MiB | non-moving | 424.76 ms | 437.99 ms | **0.97x** | 16.553 / 17.200 ms | 25.4% → 13.5% | 33.94 → 33.94 MiB |
| forced | high | 4.00 MiB | moving | 585.16 ms | 694.09 ms | **0.84x** | 65.142 / 99.290 ms | 25.4% → 13.5% | 33.94 → 39.94 MiB |
| forced | mixed | 4.00 MiB | non-moving | 342.65 ms | 334.02 ms | **1.03x** | 6.000 / 6.205 ms | 3.2% → 0.0% | 15.56 → 13.69 MiB |
| forced | mixed | 4.00 MiB | moving | 343.40 ms | 341.51 ms | **1.01x** | 6.425 / 7.102 ms | 3.2% → 0.0% | 15.56 → 13.69 MiB |
| shared | mixed | 43.00 MiB | non-moving | 921.56 ms | 939.65 ms | **0.98x** | 25.172 / 30.227 ms | 1.5% → 0.0% | 46.06 → 45.44 MiB |
| shared | mixed | 43.00 MiB | moving | 1173.63 ms | 1174.15 ms | **1.00x** | 100.001 / 109.831 ms | 0.0% → 0.0% | 1.19 → 1.19 MiB |

Age-three is the production policy; age one is the control. Every moving row has an exact non-moving parent with the same trigger, workload, age, sample, and checksum. Forced rows isolate the quiescent minor pause after each equal allocation round. Shared rows run three JavaScript mutators without a context GIL and use the displayed cooperative allocation tranche.

## Moving age-three exact-parent comparison

| trigger | workload | trigger | non-moving median | moving median | moving throughput | moving pause p50 / p95 | copied | promoted | retained backing | timeouts |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| forced | ephemeral | 4.00 MiB | 310.23 ms | 307.64 ms | **1.01x** | 6.906 / 7.918 ms | 0.01 MiB | 0.0% | 12.94 MiB | 0 |
| forced | high | 4.00 MiB | 437.99 ms | 694.09 ms | **0.63x** | 65.142 / 99.290 ms | 441.02 MiB | 13.5% | 39.94 MiB | 0 |
| forced | mixed | 4.00 MiB | 334.02 ms | 341.51 ms | **0.98x** | 6.425 / 7.102 ms | 39.39 MiB | 0.0% | 13.69 MiB | 0 |
| shared | mixed | 43.00 MiB | 939.65 ms | 1174.15 ms | **0.80x** | 100.001 / 109.831 ms | 0.00 MiB | 0.0% | 1.19 MiB | 7 |

## Telemetry and dispersion

| trigger | workload | configured trigger | movement | age | elapsed RSD | reclaimed | survived | minor / moving / full | copied | pause max | rendezvous attempts / parks / timeouts |
| --- | --- | ---: | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| forced | ephemeral | 4.00 MiB | non-moving | 1 | 4.51% | 100.0% | 0.0% | 8 / 0 / 0 | 0.00 MiB | 10.887 ms | 0 / 0 / 0 |
| forced | ephemeral | 4.00 MiB | non-moving | 3 | 3.17% | 100.0% | 0.0% | 8 / 0 / 0 | 0.00 MiB | 6.278 ms | 0 / 0 / 0 |
| forced | ephemeral | 4.00 MiB | moving | 1 | 2.98% | 100.0% | 0.0% | 8 / 8 / 0 | 0.01 MiB | 6.396 ms | 0 / 0 / 0 |
| forced | ephemeral | 4.00 MiB | moving | 3 | 3.88% | 100.0% | 0.0% | 8 / 8 / 0 | 0.01 MiB | 8.147 ms | 0 / 0 / 0 |
| forced | high | 4.00 MiB | non-moving | 1 | 5.48% | 74.6% | 25.4% | 8 / 0 / 0 | 0.00 MiB | 60.857 ms | 0 / 0 / 0 |
| forced | high | 4.00 MiB | non-moving | 3 | 4.26% | 52.8% | 47.2% | 8 / 0 / 0 | 0.00 MiB | 17.202 ms | 0 / 0 / 0 |
| forced | high | 4.00 MiB | moving | 1 | 2.40% | 74.6% | 25.4% | 8 / 8 / 0 | 168.01 MiB | 57.372 ms | 0 / 0 / 0 |
| forced | high | 4.00 MiB | moving | 3 | 5.70% | 52.8% | 47.2% | 8 / 8 / 0 | 441.02 MiB | 105.028 ms | 0 / 0 / 0 |
| forced | mixed | 4.00 MiB | non-moving | 1 | 2.60% | 96.8% | 3.2% | 8 / 0 / 0 | 0.00 MiB | 9.243 ms | 0 / 0 / 0 |
| forced | mixed | 4.00 MiB | non-moving | 3 | 1.11% | 94.3% | 5.7% | 8 / 0 / 0 | 0.00 MiB | 6.256 ms | 0 / 0 / 0 |
| forced | mixed | 4.00 MiB | moving | 1 | 1.19% | 96.8% | 3.2% | 8 / 8 / 0 | 21.01 MiB | 9.132 ms | 0 / 0 / 0 |
| forced | mixed | 4.00 MiB | moving | 3 | 0.92% | 94.3% | 5.7% | 8 / 8 / 0 | 39.39 MiB | 7.193 ms | 0 / 0 / 0 |
| shared | mixed | 43.00 MiB | non-moving | 1 | 2.76% | 98.5% | 1.5% | 3 / 0 / 0 | 0.00 MiB | 27.865 ms | 21 / 42 / 0 |
| shared | mixed | 43.00 MiB | non-moving | 3 | 2.47% | 98.7% | 1.3% | 3 / 0 / 0 | 0.00 MiB | 31.307 ms | 21 / 42 / 0 |
| shared | mixed | 43.00 MiB | moving | 1 | 7.06% | 100.0% | 0.0% | 1 / 1 / 1 | 0.00 MiB | 105.989 ms | 12 / 46 / 5 |
| shared | mixed | 43.00 MiB | moving | 3 | 13.32% | 100.0% | 0.0% | 1 / 1 / 1 | 0.00 MiB | 110.563 ms | 14 / 58 / 7 |

## Method

Ephemeral rows retain nothing. Mixed rows retain 1/16 of graphs for two cycles, exposing premature age-one promotion. High-survival rows retain half the graphs for eight cycles, exercising legitimate promotion. Every graph contributes to an exact integer checksum.
Each process is fresh. One unrecorded warmup per matrix row precedes seven recorded samples; age order alternates per sample, and moving/non-moving configurations retain the same sample indexes. The harness rejects checksum drift, byte imbalance, any full collection except the single production automatic-compaction follow-on in a shared moving row, missing minor/movement/rendezvous activity, movement failures, any conservative-parent timeout, more than two bounded moving retries, samples below 50 ms, elapsed RSD above 15%, and stable age-three regressions above 20%.
Raw evidence: [gc-generation-2026-07-29.tsv](gc-generation-2026-07-29.tsv)

## Reproduce

```sh
zig build gc-generation-benchmark -Doptimize=ReleaseFast
zig build gc-generation-benchmark -Dgc-generation-benchmark-quick=true
```
