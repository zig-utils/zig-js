# Synchronous compiler pressure — 2026-09-23

> Dated independent-Context measurement, not a general engine score. Lower wall and CPU time are better.
> JIT-off forces required bytecode and is the exact source/checksum control. Every JIT-on cold lane must publish 64 baseline artifacts; warm phases must publish none.

## Environment

| item | value |
| --- | --- |
| Date | 2026-09-23T00:35:32-0700 |
| Host | Apple M3 Pro; 11 physical / 11 logical CPUs; 18.0 GiB |
| OS | macOS 27.0 (26A428) |
| Zig | 0.17.0-dev.1441+d5181a9c9 |
| zig-js | 9d75cba5e2f0bbb94fdf2a5be251f88b00b0ed88 |
| zig-gc | 0285ef801dd221a4ae8e88b31a09ae31627657a3 |
| zig-regex | 1d3e5c9e3f2fb1c421de6433cab503220988617f |
| Runner SHA-256 | 30fec9299674ac149ba14ef4709a112b0a832f848ccca4c69837724a36ae4957 |
| Samples | 9 |
| Warmups | 1 |
| Power | Now drawing from 'Battery Power' -InternalBattery-0 (id=23724131) 21%; discharging; 0:52 remaining present: true |

## Cold Context and compiler pressure

| lanes | mode | wall p50 | process CPU p50 | summed compiler p50 | CPU / wall | throughput scaling | wall RSD | baseline publications | generated code | peak RSS p50 |
| ---: | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 1 | jit_off | 6.35 ms | 6.36 ms | 0.00 ms | 1.00x | 1.00x | 3.12% | 0 | 0.00 MiB | 13.55 MiB |
| 1 | jit_on | 18.46 ms | 18.46 ms | 15.04 ms | 1.00x | 1.00x | 2.57% | 64 | 2.02 MiB | 15.58 MiB |
| 2 | jit_off | 7.36 ms | 14.54 ms | 0.00 ms | 1.98x | 1.73x | 2.23% | 0 | 0.00 MiB | 17.45 MiB |
| 2 | jit_on | 19.97 ms | 39.70 ms | 31.40 ms | 1.99x | 1.85x | 2.38% | 128 | 4.03 MiB | 21.31 MiB |
| 4 | jit_off | 7.87 ms | 30.44 ms | 0.00 ms | 3.87x | 3.23x | 19.77% | 0 | 0.00 MiB | 25.14 MiB |
| 4 | jit_on | 23.04 ms | 89.04 ms | 71.15 ms | 3.86x | 3.20x | 6.67% | 256 | 8.06 MiB | 32.48 MiB |
| 11 | jit_off | 16.99 ms | 137.17 ms | 0.00 ms | 8.07x | 4.11x | 2.60% | 0 | 0.00 MiB | 52.00 MiB |
| 11 | jit_on | 54.87 ms | 486.51 ms | 466.96 ms | 8.87x | 3.70x | 1.23% | 704 | 22.17 MiB | 70.38 MiB |
| 22 | jit_off | 30.32 ms | 258.38 ms | 0.00 ms | 8.52x | 4.61x | 2.71% | 0 | 0.00 MiB | 94.05 MiB |
| 22 | jit_on | 105.49 ms | 957.75 ms | 865.36 ms | 9.08x | 3.85x | 1.10% | 1408 | 44.34 MiB | 128.56 MiB |

## Exact pre-admission comparison

The control is compiler-pressure-2026-09-22.json at SHA-256 `a6208dae3e00bc12607ebb1a1f3996333618da27127cebccdf4d83b229557024`, revision `de3ff426444bd0af37689080837d9095da17dc17`. Host, OS, Zig, zig-gc, zig-regex, source checksum, lane widths, invocation counts, samples, and warmups match. The zig-js revision and runner schema differ; each artifact records its own collection time, runner hash, and power status.

| lanes | baseline wall p50 | coordinated wall p50 | wall change | baseline CPU p50 | coordinated CPU p50 | CPU change |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 1 | 18.97 ms | 18.46 ms | -2.7% | 18.91 ms | 18.46 ms | -2.4% |
| 2 | 20.24 ms | 19.97 ms | -1.3% | 40.21 ms | 39.70 ms | -1.3% |
| 4 | 22.84 ms | 23.04 ms | 0.9% | 87.65 ms | 89.04 ms | 1.6% |
| 11 | 54.98 ms | 54.87 ms | -0.2% | 482.89 ms | 486.51 ms | 0.7% |

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
| 11 | jit_on | 748 | 78 | 670 | 0 | 0.00 ms | 11 | 10 | 1 |
| 22 | jit_off | 0 | 0 | 0 | 0 | 0.00 ms | 0 | 0 | 0 |
| 22 | jit_on | 1496 | 146 | 1350 | 1355 | 806.47 ms | 11 | 10 | 1 |

Every runtime row is captured from the process-wide schema-v7 snapshot. The harness requires completed request/start/completion balance, zero residual active work or waiters, no typed or nested reuse in these untyped host lanes, and an exact reserved-plus-general admission total. The 2×-logical-CPU samples must enter the compiler queue.

## Warm execution control

| lanes | mode | wall p50 | process CPU p50 | wall RSD | new publications |
| ---: | --- | ---: | ---: | ---: | ---: |
| 1 | jit_off | 1.032 ms | 1.034 ms | 5.10% | 0 |
| 1 | jit_on | 0.123 ms | 0.125 ms | 1.95% | 0 |
| 2 | jit_off | 1.077 ms | 2.149 ms | 8.05% | 0 |
| 2 | jit_on | 0.135 ms | 0.262 ms | 2.46% | 0 |
| 4 | jit_off | 1.453 ms | 4.712 ms | 34.77% | 0 |
| 4 | jit_on | 0.153 ms | 0.547 ms | 30.55% | 0 |
| 11 | jit_off | 2.254 ms | 16.577 ms | 3.54% | 0 |
| 11 | jit_on | 0.409 ms | 2.618 ms | 12.99% | 0 |
| 22 | jit_off | 4.237 ms | 33.243 ms | 6.56% | 0 |
| 22 | jit_on | 0.685 ms | 5.228 ms | 7.44% | 0 |

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
