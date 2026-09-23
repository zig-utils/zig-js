# Synchronous compiler pressure — 2026-09-23

> Dated independent-Context measurement, not a general engine score. Lower wall and CPU time are better.
> JIT-off forces required bytecode and is the exact source/checksum control. Every JIT-on cold lane must publish 64 baseline artifacts; warm phases must publish none.

## Environment

| item | value |
| --- | --- |
| Date | 2026-09-23T00:40:59-0700 |
| Host | Apple M3 Pro; 11 physical / 11 logical CPUs; 18.0 GiB |
| OS | macOS 27.0 (26A428) |
| Zig | 0.17.0-dev.1441+d5181a9c9 |
| zig-js | a125bd73b6e8bd20129670484af12ebb240b1796 |
| zig-gc | 0285ef801dd221a4ae8e88b31a09ae31627657a3 |
| zig-regex | 1d3e5c9e3f2fb1c421de6433cab503220988617f |
| Runner SHA-256 | 52e7bbaee78e83718cdad79f6e504e4f16aa0ac94abda31397bc3d2468632ef4 |
| Samples | 9 |
| Warmups | 1 |
| Power | Now drawing from 'Battery Power' -InternalBattery-0 (id=23724131) 20%; discharging; 1:02 remaining present: true |

## Cold Context and compiler pressure

| lanes | mode | wall p50 | process CPU p50 | summed compiler p50 | CPU / wall | throughput scaling | wall RSD | baseline publications | generated code | configured stacks | peak RSS p50 |
| ---: | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 1 | jit_off | 6.11 ms | 6.12 ms | 0.00 ms | 1.00x | 1.00x | 2.86% | 0 | 0.00 MiB | 16.00 MiB | 13.56 MiB |
| 1 | jit_on | 17.92 ms | 17.92 ms | 14.60 ms | 1.00x | 1.00x | 1.31% | 64 | 2.02 MiB | 16.00 MiB | 15.59 MiB |
| 2 | jit_off | 6.95 ms | 13.85 ms | 0.00 ms | 1.99x | 1.76x | 1.35% | 0 | 0.00 MiB | 32.00 MiB | 17.44 MiB |
| 2 | jit_on | 19.43 ms | 38.79 ms | 30.81 ms | 2.00x | 1.84x | 0.60% | 128 | 4.03 MiB | 32.00 MiB | 21.31 MiB |
| 4 | jit_off | 7.43 ms | 29.33 ms | 0.00 ms | 3.94x | 3.29x | 2.04% | 0 | 0.00 MiB | 64.00 MiB | 25.14 MiB |
| 4 | jit_on | 21.20 ms | 84.01 ms | 66.58 ms | 3.96x | 3.38x | 1.26% | 256 | 8.06 MiB | 64.00 MiB | 32.59 MiB |
| 11 | jit_off | 16.38 ms | 146.68 ms | 0.00 ms | 8.96x | 4.11x | 2.11% | 0 | 0.00 MiB | 176.00 MiB | 51.98 MiB |
| 11 | jit_on | 54.02 ms | 537.17 ms | 468.12 ms | 9.94x | 3.65x | 1.48% | 704 | 22.17 MiB | 176.00 MiB | 70.73 MiB |
| 22 | jit_off | 28.35 ms | 266.54 ms | 0.00 ms | 9.40x | 4.74x | 4.13% | 0 | 0.00 MiB | 352.00 MiB | 93.98 MiB |
| 22 | jit_on | 101.78 ms | 1007.57 ms | 897.21 ms | 9.90x | 3.87x | 1.17% | 1408 | 44.34 MiB | 352.00 MiB | 128.00 MiB |

## Exact pre-admission comparison

The control is compiler-pressure-2026-09-22.json at SHA-256 `a6208dae3e00bc12607ebb1a1f3996333618da27127cebccdf4d83b229557024`, revision `de3ff426444bd0af37689080837d9095da17dc17`. Host, OS, Zig, zig-gc, zig-regex, source checksum, lane widths, invocation counts, samples, and warmups match. The zig-js revision and runner schema differ; each artifact records its own collection time, runner hash, and power status.

| lanes | baseline wall p50 | coordinated wall p50 | wall change | baseline CPU p50 | coordinated CPU p50 | CPU change |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 1 | 18.97 ms | 17.92 ms | -5.6% | 18.91 ms | 17.92 ms | -5.2% |
| 2 | 20.24 ms | 19.43 ms | -4.0% | 40.21 ms | 38.79 ms | -3.5% |
| 4 | 22.84 ms | 21.20 ms | -7.2% | 87.65 ms | 84.01 ms | -4.2% |
| 11 | 54.98 ms | 54.02 ms | -1.7% | 482.89 ms | 537.17 ms | 11.2% |

Throughput scaling is one-lane wall multiplied by lanes, then divided by current wall. Process CPU divided by wall shows aggregate concurrency; summed compiler time adds independently timed tier attempts across lanes and can exceed wall time.

## Runtime admission

| lanes | mode | requests p50 | reserved p50 | general p50 | queued p50 | total wait p50 | peak compiler work | peak general slots | peak reserved lane |
| ---: | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 1 | jit_off | 0 | 0 | 0 | 0 | 0.00 ms | 0 | 0 | 0 |
| 1 | jit_on | 68 | 68 | 0 | 0 | 0.00 ms | 1 | 0 | 1 |
| 2 | jit_off | 0 | 0 | 0 | 0 | 0.00 ms | 0 | 0 | 0 |
| 2 | jit_on | 136 | 68 | 68 | 0 | 0.00 ms | 2 | 1 | 1 |
| 4 | jit_off | 0 | 0 | 0 | 0 | 0.00 ms | 0 | 0 | 0 |
| 4 | jit_on | 272 | 69 | 203 | 0 | 0.00 ms | 4 | 3 | 1 |
| 11 | jit_off | 0 | 0 | 0 | 0 | 0.00 ms | 0 | 0 | 0 |
| 11 | jit_on | 748 | 77 | 671 | 0 | 0.00 ms | 11 | 10 | 1 |
| 22 | jit_off | 0 | 0 | 0 | 0 | 0.00 ms | 0 | 0 | 0 |
| 22 | jit_on | 1496 | 145 | 1351 | 1372 | 784.36 ms | 11 | 10 | 1 |

Every runtime row is captured from the process-wide schema-v7 snapshot. The harness requires completed request/start/completion balance, zero residual active work or waiters, no typed or nested reuse in these untyped host lanes, and an exact reserved-plus-general admission total. The 2×-logical-CPU samples must enter the compiler queue.

## Decision

At 11 lanes, peak compiler work reaches the 11-CPU host capacity while cold JIT wall changes -1.7% from the exact pre-admission baseline. At 22 lanes, the median queues 1372 of 1496 compiler attempts and holds peak active work to 11.
This evidence does not justify an asynchronous artifact queue. Synchronous admission already saturates the available CPU budget at host width and applies bounded backpressure when oversubscribed; an asynchronous queue would add artifact ownership, cancellation, and teardown lifetimes without adding execution capacity.

## Warm execution control

| lanes | mode | wall p50 | process CPU p50 | wall RSD | new publications |
| ---: | --- | ---: | ---: | ---: | ---: |
| 1 | jit_off | 1.046 ms | 1.048 ms | 1.10% | 0 |
| 1 | jit_on | 0.126 ms | 0.127 ms | 1.74% | 0 |
| 2 | jit_off | 1.062 ms | 2.105 ms | 1.41% | 0 |
| 2 | jit_on | 0.136 ms | 0.257 ms | 3.02% | 0 |
| 4 | jit_off | 1.134 ms | 4.384 ms | 9.59% | 0 |
| 4 | jit_on | 0.147 ms | 0.555 ms | 15.49% | 0 |
| 11 | jit_off | 2.167 ms | 16.280 ms | 2.28% | 0 |
| 11 | jit_on | 0.374 ms | 2.291 ms | 13.51% | 0 |
| 22 | jit_off | 3.943 ms | 33.525 ms | 4.23% | 0 |
| 22 | jit_on | 0.627 ms | 4.870 ms | 5.10% | 0 |

## Method and boundaries

The matrix contains 180 phase rows. Each cell uses 9 fresh-process samples after 1 discarded warmup process(es); JIT-on/off launch order alternates. Reported values are medians, with sample RSD shown for wall time.
The fixed source is `bench/compiler_pressure.js` at SHA-256 `7260df7f15efb177a067d8457df244044b6ea3c4c7e39b3225726228ba46d83f`. Each lane owns a fresh creator-thread-affine Context. Cold timing starts before OS-thread creation and includes Context construction, source parsing/bytecode setup, ten fixture invocations, native compilation/publication, and the completion wait.
Warm timing reuses the live Contexts for three invocations. Context destruction is outside both timed phases. Process CPU comes from `getrusage`; peak and retained RSS use Darwin `task_vm_info`.
The measured revision compiles synchronously on the calling lane. Runtime admission bounds simultaneous compiler CPU work without changing checksums, publication counts, or warm behavior.
Raw evidence: [compiler-pressure-2026-09-23.json](compiler-pressure-2026-09-23.json)

## Reproduce

```bash
zig build compiler-pressure-benchmark -Dcompiler-pressure-raw-out=docs/.data/compiler-pressure-2026-09-23.json -Dcompiler-pressure-markdown-out=docs/.data/compiler-pressure-2026-09-23.md
```
