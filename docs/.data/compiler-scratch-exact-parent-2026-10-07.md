# Exact-parent compiler scratch — 2026-10-07

> Paired independent-Context measurement for issue #1027, not a general engine score. Lower wall, CPU, RSS, and teardown time are better.
> Parent and candidate use the same benchmark source, Zig, zig-gc, zig-regex, host, lane widths, and checksums. Invocation order alternates across samples.

## Provenance

| item | value |
| --- | --- |
| Parent engine | `b4f5544d61036e296ebd0046579d0b991b509025` |
| Candidate engine | `24d7ff72fad07fc37512fea6c09b7cca9bb9c325` |
| Parent runner | `1949cc6ad1a5ff656ad1e4e1f17188dedef5572aa31702e1d10fd97e2e56af46` |
| Candidate runner | `cc419c920cd38716398d4fd934269c7d1a64d4cb2f89ae9db680c278770aacad` |
| Workload | `bench/compiler_pressure.js` at `7260df7f15efb177a067d8457df244044b6ea3c4c7e39b3225726228ba46d83f` |
| Date | 2026-10-07T19:51:05+0800 |
| Host | Apple M2 Pro; 10 physical / 10 logical CPUs; 16.0 GiB |
| OS | macOS 26.3.1 (25D771280a) |
| Zig | 0.17.0-dev.2163+89ff10d56 |
| zig-js | 24d7ff72fad07fc37512fea6c09b7cca9bb9c325 |
| zig-gc | 0285ef801dd221a4ae8e88b31a09ae31627657a3 |
| zig-regex | fdd9c2e333ea6ac2fd06d080d939ef7f11d61b1b |
| Samples | 9 |
| Warmups | 4 |
| Power | Now drawing from 'AC Power' -InternalBattery-0 (id=21364835) 96%; charging; 0:25 remaining present: true |

## Cold phase comparison

| lanes | mode | parent wall p50 | candidate wall p50 | wall change | parent CPU p50 | candidate CPU p50 | CPU change | parent peak RSS p50 | candidate peak RSS p50 | RSS change | checksum |
| ---: | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 1 | jit_off | 7.17 ms | 7.21 ms | 0.5% | 7.18 ms | 7.20 ms | 0.4% | 13.17 MiB | 13.19 MiB | 0.1% | 29668441 |
| 1 | jit_on | 23.00 ms | 23.64 ms | 2.8% | 22.89 ms | 23.59 ms | 3.1% | 15.25 MiB | 15.17 MiB | -0.5% | 29668441 |
| 20 | jit_off | 33.99 ms | 34.41 ms | 1.2% | 257.90 ms | 258.53 ms | 0.2% | 86.00 MiB | 85.94 MiB | -0.1% | 642913460 |
| 20 | jit_on | 309.64 ms | 319.20 ms | 3.1% | 1924.25 ms | 2013.38 ms | 4.6% | 115.73 MiB | 115.56 MiB | -0.1% | 642913460 |

Wall-time RSD by paired cell:

| lanes | mode | parent RSD | candidate RSD | parent throughput | candidate throughput |
| ---: | --- | ---: | ---: | ---: | ---: |
| 1 | jit_off | 2.38% | 28.92% | 1394.09 fixture invocations/s | 1387.07 fixture invocations/s |
| 1 | jit_on | 10.72% | 3.09% | 434.86 fixture invocations/s | 423.00 fixture invocations/s |
| 20 | jit_off | 6.62% | 6.29% | 5884.56 fixture invocations/s | 5812.62 fixture invocations/s |
| 20 | jit_on | 5.94% | 4.99% | 645.92 fixture invocations/s | 626.57 fixture invocations/s |

Cold timing is inconclusive where RSD exceeds 10% (maximum 28.92%); the accounting, lifecycle, RSS, and checksum evidence remains valid, but no speed claim is made from those rows.

## Candidate scratch accounting

| lanes | mode | process peak p50 | GC peak p50 | native requested p50 | native released p50 | native peak p50 | policy rejections | allocator failures |
| ---: | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 1 | jit_off | 0.00 MiB | 0.00 MiB | 0.00 MiB | 0.00 MiB | 0.00 MiB | 0 | 0 |
| 1 | jit_on | 0.61 MiB | 0.00 MiB | 24.30 MiB | 24.30 MiB | 0.60 MiB | 0 | 0 |
| 20 | jit_off | 0.05 MiB | 0.05 MiB | 0.00 MiB | 0.00 MiB | 0.00 MiB | 0 | 0 |
| 20 | jit_on | 4.18 MiB | 0.05 MiB | 486.03 MiB | 486.03 MiB | 4.13 MiB | 0 | 0 |

## Teardown

| lanes | mode | teardown p50 | scratch before p50 | scratch after | GC released p50 |
| ---: | --- | ---: | ---: | ---: | ---: |
| 1 | jit_off | 0.32 ms | 0.00 MiB | 0.00 MiB | 0.00 MiB |
| 1 | jit_on | 0.54 ms | 0.00 MiB | 0.00 MiB | 0.00 MiB |
| 20 | jit_off | 3.82 ms | 0.05 MiB | 0.00 MiB | 0.05 MiB |
| 20 | jit_on | 7.74 ms | 0.05 MiB | 0.00 MiB | 0.05 MiB |

The collector rejects any checksum drift, unbalanced runtime admission, default-policy rejection, allocator failure, native scratch retained after cold compilation, native activity outside JIT-on cold execution, Wasm scratch activity in this fixture, or process scratch remaining after Context teardown.

## Method

Each cell contains 9 fresh-process samples after 4 discarded warmup process(es). Only dedicated (1 lane) and busy (2× logical CPU) widths are measured. The four parent/candidate × JIT-on/off invocations rotate through four balanced orders.
Cold timing includes lane creation, Context construction, parsing/bytecode setup, ten fixture invocations, synchronous native compilation/publication, and completion. Warm timing reuses live Contexts for three invocations. Teardown joins every lane and destroys every Context.
The parent source tree receives only the updated benchmark runner as a measurement overlay; engine sources remain the exact parent revision. Both runners import the same pinned zig-gc and zig-regex revisions.
Raw evidence: [compiler-scratch-exact-parent-2026-10-07.json](compiler-scratch-exact-parent-2026-10-07.json)

## Reproduce

```bash
home-tool run tools/compiler-pressure-benchmark.ts --runner /tmp/compiler-pressure-candidate --parent-runner /tmp/compiler-pressure-parent --parent-revision <sha> --candidate-revision <sha> --gc-path <zig-gc> --regex-path <zig-regex> --samples 9 --warmups 4 --raw-out <json> --markdown-out <md>
```
