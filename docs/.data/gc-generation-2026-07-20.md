# GC generation policy — 2026-07-20

> Dated nursery-policy evidence, not a general application benchmark.
> Exact work/checksums, alternating age order, a 50 ms timing floor, byte conservation, zero full-GC contamination, and zero cooperative timeouts are enforced.

## Environment

| item | value |
| --- | --- |
| Date | 2026-07-20 |
| Host | Apple M3 Pro; 11 physical / 11 logical CPUs; 18.0 GiB |
| OS | macOS 27.0 (26A5368g) |
| Zig | 0.17.0-dev.956+2dca73595 |
| zig-js | c34b84740d320c9d2b1518d724ac9c60f79b76ba |
| zig-gc | 7be845a10cc61088eb7ae2a2223cdf5f31d84ecd |
| Power | Now drawing from 'AC Power' -InternalBattery-0 (id=22872163) 100%; charged; 0:00 remaining present: true |

## Age-three policy versus age-one control

| trigger | workload | trigger | age 1 median | age 3 median | age 3 throughput | age 3 pause p50 / p95 | age 1 → age 3 promoted | age 1 → age 3 retained backing |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| automatic | ephemeral | 4.00 MiB | 256.46 ms | 255.92 ms | **1.00x** | 0.751 / 0.765 ms | 0.0% → 0.0% | 4.62 → 4.62 MiB |
| automatic | ephemeral | 8.00 MiB | 258.25 ms | 256.62 ms | **1.01x** | 1.483 / 1.515 ms | 0.0% → 0.0% | 8.62 → 8.62 MiB |
| automatic | high | 4.00 MiB | 344.13 ms | 359.88 ms | **0.96x** | 2.653 / 2.753 ms | 25.4% → 16.1% | 27.12 → 27.00 MiB |
| automatic | high | 8.00 MiB | 345.08 ms | 358.76 ms | **0.96x** | 2.648 / 2.994 ms | 25.4% → 16.1% | 29.12 → 28.94 MiB |
| automatic | mixed | 4.00 MiB | 283.13 ms | 282.92 ms | **1.00x** | 0.997 / 1.863 ms | 3.2% → 2.8% | 7.38 → 7.31 MiB |
| automatic | mixed | 8.00 MiB | 282.79 ms | 282.46 ms | **1.00x** | 1.594 / 1.687 ms | 3.2% → 2.6% | 9.38 → 9.19 MiB |
| shared | mixed | 0.25 MiB | 133.67 ms | 134.04 ms | **1.00x** | 0.243 / 0.350 ms | 3.7% → 3.0% | 2.75 → 2.44 MiB |
| shared | mixed | 0.50 MiB | 123.80 ms | 125.14 ms | **0.99x** | 0.307 / 0.312 ms | 3.5% → 2.9% | 2.81 → 2.81 MiB |

Age-three is the production policy; age one is the control. Automatic rows exercise adaptive single-mutator nursery safepoints. Shared rows run two JavaScript mutators without a context GIL and use the displayed cooperative allocation tranche.

## Telemetry and dispersion

| trigger | workload | configured trigger | age | elapsed RSD | reclaimed | survived | collections | pause max | rendezvous attempts / parks / timeouts |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| automatic | ephemeral | 4.00 MiB | 1 | 0.49% | 100.0% | 0.0% | 23 | 0.868 ms | 0 / 0 / 0 |
| automatic | ephemeral | 4.00 MiB | 3 | 1.21% | 99.9% | 0.1% | 23 | 0.767 ms | 0 / 0 / 0 |
| automatic | ephemeral | 8.00 MiB | 1 | 0.67% | 100.0% | 0.0% | 22 | 1.485 ms | 0 / 0 / 0 |
| automatic | ephemeral | 8.00 MiB | 3 | 0.64% | 100.0% | 0.0% | 22 | 1.518 ms | 0 / 0 / 0 |
| automatic | high | 4.00 MiB | 1 | 0.50% | 74.6% | 25.4% | 23 | 3.017 ms | 0 / 0 / 0 |
| automatic | high | 4.00 MiB | 3 | 0.50% | 50.2% | 49.8% | 34 | 2.762 ms | 0 / 0 / 0 |
| automatic | high | 8.00 MiB | 1 | 0.54% | 74.6% | 25.4% | 22 | 2.899 ms | 0 / 0 / 0 |
| automatic | high | 8.00 MiB | 3 | 0.77% | 50.2% | 49.8% | 33 | 3.058 ms | 0 / 0 / 0 |
| automatic | mixed | 4.00 MiB | 1 | 0.93% | 96.8% | 3.2% | 23 | 0.978 ms | 0 / 0 / 0 |
| automatic | mixed | 4.00 MiB | 3 | 0.81% | 91.3% | 8.7% | 24 | 2.222 ms | 0 / 0 / 0 |
| automatic | mixed | 8.00 MiB | 1 | 1.02% | 96.8% | 3.2% | 22 | 1.604 ms | 0 / 0 / 0 |
| automatic | mixed | 8.00 MiB | 3 | 0.72% | 91.5% | 8.5% | 23 | 1.716 ms | 0 / 0 / 0 |
| shared | mixed | 0.25 MiB | 1 | 0.54% | 96.3% | 3.7% | 133 | 0.258 ms | 928 / 928 / 0 |
| shared | mixed | 0.25 MiB | 3 | 0.52% | 90.3% | 9.7% | 133 | 0.391 ms | 929 / 929 / 0 |
| shared | mixed | 0.50 MiB | 1 | 0.27% | 96.5% | 3.5% | 66 | 0.310 ms | 462 / 462 / 0 |
| shared | mixed | 0.50 MiB | 3 | 0.50% | 90.7% | 9.3% | 66 | 0.313 ms | 462 / 462 / 0 |

## Method

Ephemeral rows retain nothing. Mixed rows retain 1/16 of graphs for two cycles, exposing premature age-one promotion. High-survival rows retain half the graphs for eight cycles, exercising legitimate promotion. Every graph contributes to an exact integer checksum.
Each process is fresh. One unrecorded warmup per matrix row precedes seven recorded samples; age order alternates per sample. The harness rejects checksum drift, byte imbalance, full collections, missing minor/rendezvous activity, nonzero cooperative timeouts, samples below 50 ms, elapsed RSD above 15%, and stable age-three regressions above 20%.
Raw evidence: [gc-generation-2026-07-20.tsv](gc-generation-2026-07-20.tsv)

## Reproduce

```sh
zig build gc-generation-benchmark -Doptimize=ReleaseFast
zig build gc-generation-benchmark -Dgc-generation-benchmark-quick=true
```
