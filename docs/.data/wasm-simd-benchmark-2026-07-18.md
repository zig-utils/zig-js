# WebAssembly SIMD comparison — 2026-07-18

> Dated measurement, not a universal engine score. Lower elapsed time and higher throughput are better.
> Every SIMD kernel has a byte-identical-module scalar oracle; the harness rejects checksum disagreement.

## Environment

| item | value |
| --- | --- |
| Date | 2026-07-18T04:13:08-07:00 |
| Host | Apple M3 Pro; 11 physical / 11 logical CPUs; 18.0 GiB |
| OS | macOS 27.0 (26A5368g) |
| Zig | 0.17.0-dev.956+2dca73595 |
| zig-js | 7362c1e28c74f92b4c82e380a4ebcba038de5f1c |
| JavaScriptCore | system framework 22625.1.20.11.3 |
| WABT source compiler | 1.0.39 (ad75c5edcdff96d73c245b57fbc07607aaca9f95) |
| Wasm module SHA-256 | 5f33169c01f36873c1ac4ec8bb07675b8d4d770a6a4f3d961454f139f1818957 |
| Power | Now drawing from 'AC Power' -InternalBattery-0 (id=22806627) 100%; charged; 0:00 remaining present: true |

## SIMD throughput

Throughput is millions of logical 128-bit state updates per second, normalized by the exact inner-loop count.
The `8-thread` rows use `8` warmed, independent contexts and module instances on persistent OS workers.

| family | zig-js 1-thread | zig-js 8-thread | zig-js scaling | JSC 1-thread | JSC 8-thread | JSC scaling | zig-js / JSC, 1-thread | zig-js / JSC, 8-thread | max RSD |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `integer` | 7.73 M/s | 28.35 M/s | 3.67x | 62.02 M/s | 280.32 M/s | 4.52x | 0.12x | 0.10x | 17.52% |
| `float` | 7.06 M/s | 27.66 M/s | 3.92x | 63.66 M/s | 283.33 M/s | 4.45x | 0.11x | 0.10x | 15.84% |
| `shuffle` | 6.74 M/s | 29.00 M/s | 4.30x | 63.23 M/s | 286.75 M/s | 4.54x | 0.11x | 0.10x | 14.35% |
| `memory` | 8.98 M/s | 41.13 M/s | 4.58x | 53.32 M/s | 291.96 M/s | 5.48x | 0.17x | 0.14x | 6.98% |

## SIMD speedup over the scalar oracle

Each cell is SIMD logical-update throughput divided by its semantically equivalent scalar export.
Values above `1.00x` favor SIMD; the scalar path deliberately performs the same lane work without vector instructions.

| family | zig-js 1-thread | zig-js 8-thread | JSC 1-thread | JSC 8-thread |
| --- | ---: | ---: | ---: | ---: |
| `integer` | 1.38x | 1.34x | 1.24x | 1.82x |
| `float` | 1.27x | 1.21x | 1.15x | 1.65x |
| `shuffle` | 17.27x | 16.82x | 25.82x | 28.36x |
| `memory` | 1.69x | 1.72x | 1.22x | 1.40x |

## Method and boundaries

The run contains 224 raw samples (32 scored rows). Each row is sampled independently; engine launch order alternates by workload.
Scored-row medians span 50.7–1257.4 ms. The timer excludes process launch, source evaluation, module compilation/instantiation, and three warm-up invocations.
Single-thread timing covers only `__benchmarkSelected(jobs, lane)`. Multi-thread timing covers symmetric semaphore dispatch, one invocation per persistent worker, and the completion wait.
The two engines receive the exact same JavaScript, Wasm bytes, job counts, and logical update counts. Independent contexts are the common public-API concurrency model; zig-js shared-realm Threads are intentionally outside this cross-engine panel.
The integer kernel uses `i32x4.add/mul`; float uses `f32x4.add/mul`; shuffle rotates all 16 bytes with `i8x16.shuffle`; memory uses aligned `v128.load/store`. Scalar exports live in the same module and return identical checksums.

## Reproduce

```sh
zig build benchmark-comparison-bin -Doptimize=ReleaseFast
python3 tools/wasm-simd-benchmark.py --samples 7 --lanes 8 \
  --raw-out docs/.data/wasm-simd-benchmark-YYYY-MM-DD.tsv \
  --markdown-out docs/.data/wasm-simd-benchmark-YYYY-MM-DD.md
```

Regenerate the embedded module after editing the readable source:

```sh
wat2wasm --enable-all bench/wasm_simd_kernels.wat -o /tmp/wasm_simd_kernels.wasm
shasum -a 256 /tmp/wasm_simd_kernels.wasm
```
