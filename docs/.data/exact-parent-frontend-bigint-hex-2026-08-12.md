# Radix BigInt conversion exact-parent evidence — 2026-08-12

Diagnostic exact-parent evidence for
[#546](https://github.com/zig-utils/zig-js/issues/546), comparing benchmark
parent `faa212516d330bceff9bf1f5bffcf93c02bbe205` with implementation
`727d87a50a0abb65900d0ddf8fa01552263f6173`. Both ReleaseFast runners use the
same committed parser-only workload, independent `std.math.big.int.Managed`
decimal oracle, and allocation/counter instrumentation. The raw artifacts
retain revisions and hashes for the workload source, both binaries, zig-gc,
and zig-regex.

Each row contains seven order-balanced fresh-process pairs with no discarded
samples. A sample runs 100 parser-only parses and validates every canonical
decimal output byte over a preconstructed hexadecimal BigInt source after ten
10-job warmups. Logical allocation requests and bytes come from an untimed
replay of identical work immediately above the parser arena.

| hexadecimal digits | wall parent → candidate | candidate / parent | instructions parent → candidate | instruction ratio | allocation requests parent → candidate | allocated bytes parent → candidate |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 1,024 | 106.733 ms → 1.895 ms | 0.018x | 703,836,711 → 16,097,931 | 0.0229x | 1,500 → 1,100 | 585,500 → 410,500 |
| 2,048 | 430.573 ms → 7.137 ms | 0.017x | 2,799,470,758 → 51,572,824 | 0.0184x | 1,600 → 1,100 | 807,000 → 590,300 |
| 4,096 | 1,847.163 ms → 29.703 ms | 0.016x | 11,191,280,909 → 183,268,047 | 0.0164x | 1,800 → 1,100 | 1,690,100 → 949,700 |

The implementation replaces byte-per-decimal-digit list growth with a bounded,
pre-sized base-1e9 limb buffer and ingests maximal radix chunks. It removes
26.7%, 31.3%, and 38.9% of allocation requests at 1K, 2K, and 4K; candidate
request count remains fixed at eleven per parse. Allocated bytes fall 29.9%,
26.9%, and 43.8%.

The wall and instruction results independently show the same large reduction
in conversion work. They do not establish a new asymptotic class: doubling
input size takes parent wall time to 4.03x then 4.29x, and candidate wall time
to 3.77x then 4.16x. The base-1e9 long-multiplication conversion therefore
still exposes approximately quadratic growth, now with bounded storage and a
substantially smaller constant factor. Peak RSS is process-level and moves by
at most 2.1%; energy is not used because the shortest readings are too noisy.
These artifacts are diagnostic rather than quiet-reference publication claims.

Per-row reports and raw samples:

- [1K report](exact-parent-frontend-bigint-hex-1024-2026-08-12.md) · [raw JSON](exact-parent-frontend-bigint-hex-1024-2026-08-12.json)
- [2K report](exact-parent-frontend-bigint-hex-2048-2026-08-12.md) · [raw JSON](exact-parent-frontend-bigint-hex-2048-2026-08-12.json)
- [4K report](exact-parent-frontend-bigint-hex-4096-2026-08-12.md) · [raw JSON](exact-parent-frontend-bigint-hex-4096-2026-08-12.json)
