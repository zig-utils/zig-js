# Synchronous compiler pressure — 2026-09-22

> Dated independent-Context measurement, not a general engine score. Lower wall and CPU time are better.
> JIT-off forces required bytecode and is the exact source/checksum control. Every JIT-on cold lane must publish 64 baseline artifacts; warm phases must publish none.

## Environment

| item | value |
| --- | --- |
| Date | 2026-09-22T23:47:01-0700 |
| Host | Apple M3 Pro; 11 physical / 11 logical CPUs; 18.0 GiB |
| OS | macOS 27.0 (26A428) |
| Zig | 0.17.0-dev.1441+d5181a9c9 |
| zig-js | de3ff426444bd0af37689080837d9095da17dc17 |
| zig-gc | 0285ef801dd221a4ae8e88b31a09ae31627657a3 |
| zig-regex | 1d3e5c9e3f2fb1c421de6433cab503220988617f |
| Runner SHA-256 | d18fcc23c6c00d688dd90952b957b361529363fa2701e5ba7d7a5506aa63d14c |
| Samples | 9 |
| Warmups | 1 |
| Power | Now drawing from 'Battery Power' -InternalBattery-0 (id=23724131) 45%; discharging; 2:49 remaining present: true |

## Cold Context and compiler pressure

| lanes | mode | wall p50 | process CPU p50 | summed compiler p50 | CPU / wall | throughput scaling | wall RSD | baseline publications | generated code | peak RSS p50 |
| ---: | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 1 | jit_off | 6.61 ms | 6.59 ms | 0.00 ms | 1.00x | 1.00x | 3.88% | 0 | 0.00 MiB | 13.56 MiB |
| 1 | jit_on | 18.97 ms | 18.91 ms | 15.28 ms | 1.00x | 1.00x | 2.42% | 64 | 2.02 MiB | 15.56 MiB |
| 2 | jit_off | 7.36 ms | 14.60 ms | 0.00 ms | 1.98x | 1.80x | 0.88% | 0 | 0.00 MiB | 17.44 MiB |
| 2 | jit_on | 20.24 ms | 40.21 ms | 31.88 ms | 1.99x | 1.87x | 0.87% | 128 | 4.03 MiB | 21.25 MiB |
| 4 | jit_off | 7.91 ms | 30.62 ms | 0.00 ms | 3.87x | 3.34x | 8.02% | 0 | 0.00 MiB | 25.16 MiB |
| 4 | jit_on | 22.84 ms | 87.65 ms | 70.65 ms | 3.84x | 3.32x | 9.14% | 256 | 8.06 MiB | 32.39 MiB |
| 11 | jit_off | 17.02 ms | 139.76 ms | 0.00 ms | 8.21x | 4.27x | 3.36% | 0 | 0.00 MiB | 51.98 MiB |
| 11 | jit_on | 54.98 ms | 482.89 ms | 460.16 ms | 8.78x | 3.80x | 1.84% | 704 | 22.17 MiB | 70.58 MiB |

Throughput scaling is one-lane wall multiplied by lanes, then divided by current wall. Process CPU divided by wall shows aggregate concurrency; summed compiler time adds independently timed tier attempts across lanes and can exceed wall time.

## Warm execution control

| lanes | mode | wall p50 | process CPU p50 | wall RSD | new publications |
| ---: | --- | ---: | ---: | ---: | ---: |
| 1 | jit_off | 1.056 ms | 1.057 ms | 7.22% | 0 |
| 1 | jit_on | 0.125 ms | 0.129 ms | 6.30% | 0 |
| 2 | jit_off | 1.075 ms | 2.148 ms | 8.34% | 0 |
| 2 | jit_on | 0.136 ms | 0.260 ms | 24.34% | 0 |
| 4 | jit_off | 1.322 ms | 4.835 ms | 15.88% | 0 |
| 4 | jit_on | 0.258 ms | 0.677 ms | 34.61% | 0 |
| 11 | jit_off | 2.381 ms | 17.599 ms | 7.02% | 0 |
| 11 | jit_on | 0.392 ms | 2.623 ms | 7.40% | 0 |

## Method and boundaries

The matrix contains 144 phase rows. Each cell uses 9 fresh-process samples after 1 discarded warmup process(es); JIT-on/off launch order alternates. Reported values are medians, with sample RSD shown for wall time.
The fixed source is `bench/compiler_pressure.js` at SHA-256 `7260df7f15efb177a067d8457df244044b6ea3c4c7e39b3225726228ba46d83f`. Each lane owns a fresh creator-thread-affine Context. Cold timing starts before OS-thread creation and includes Context construction, source parsing/bytecode setup, ten fixture invocations, native compilation/publication, and the completion wait.
Warm timing reuses the live Contexts for three invocations. Context destruction is outside both timed phases. Process CPU comes from `getrusage`; peak and retained RSS use Darwin `task_vm_info`.
The measured revision compiles synchronously on the calling lane. This baseline therefore measures the uncoordinated behavior that runtime admission changes must improve without changing checksums, publication counts, or warm behavior.

## Reproduce

```bash
zig build compiler-pressure-benchmark -Dcompiler-pressure-raw-out=docs/.data/compiler-pressure-2026-09-22.json -Dcompiler-pressure-markdown-out=docs/.data/compiler-pressure-YYYY-MM-DD.md
```
