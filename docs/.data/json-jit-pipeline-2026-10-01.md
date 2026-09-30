# JSON native-loop and JavaScriptCore diagnostics — 2026-10-01

> Dated evidence for [#1017](https://github.com/zig-utils/zig-js/issues/1017),
> [#1018](https://github.com/zig-utils/zig-js/issues/1018), and parent
> [#473](https://github.com/zig-utils/zig-js/issues/473). These are focused
> diagnostics, not a universal engine score or a parity claim.

## Identity

- host: Apple M2 Pro, 16 GiB, macOS 26.3.1, AC power;
- Zig: `0.17.0-dev.2163+89ff10d56`;
- zig-gc: `0285ef801dd221a4ae8e88b31a09ae31627657a3` (real precise collector);
- zig-regex: `fdd9c2e333ea6ac2fd06d080d939ef7f11d61b1b`;
- workload: `bench/representative_comparison.js`, SHA-256
  `89a7e4ebceb8993fa287d3ab886cec55d63436d74c21c139cfe57b24b08f9c34`;
- every measured runner is ReleaseFast and every zig-js context enables GC.

The exact-parent artifacts use seven order-balanced pairs and preserve all raw
samples, complete-process metrics, source/binary revisions, hashes, thermal
state, and checksums. This host is classified `diagnostic`; wall-time rows with
high dispersion are not promoted into stable speed claims.

## Causal native-loop changes

| change | parent → candidate | base instructions | variant instructions | four control instruction ratios | wall status | evidence |
| --- | --- | ---: | ---: | ---: | --- | --- |
| primitive String `length` in optimizer regions (#1017) | `0efe89ed` → `ac67db51` | `0.9326x` | `0.9328x` | `0.9995x`–`1.0003x` | base candidate RSD 24.99%; variant `0.9217x` | [base](exact-parent-jit-string-length-json-2026-10-01.md) · [variant](exact-parent-jit-string-length-json-variant-2026-10-01.md) · [reviver](exact-parent-jit-string-length-reviver-control-2026-10-01.md) · [escaped](exact-parent-jit-string-length-escaped-control-2026-10-01.md) · [depth](exact-parent-jit-string-length-depth-control-2026-10-01.md) · [shallow](exact-parent-jit-string-length-shallow-control-2026-10-01.md) |
| guarded Number `bit_and` in optimizer regions (#1018) | `ac67db51` → `8ca0d15b` | `0.9904x` | `0.9947x` | `0.9999x`–`1.0010x` | base `0.9753x`; variant candidate RSD 16.73% | [base](exact-parent-jit-bit-and-json-2026-10-01.md) · [variant](exact-parent-jit-bit-and-json-variant-2026-10-01.md) · [reviver](exact-parent-jit-bit-and-reviver-control-2026-10-01.md) · [escaped](exact-parent-jit-bit-and-escaped-control-2026-10-01.md) · [depth](exact-parent-jit-bit-and-depth-control-2026-10-01.md) · [shallow](exact-parent-jit-bit-and-shallow-control-2026-10-01.md) |

The String-length change removes 6.74%/6.72% of retired instructions from the
two touched rows while its controls remain within -0.05% to +0.03%. The guarded
bitwise change removes another 0.96%/0.53%; its controls remain within -0.01%
to +0.10%.

## Native-tier residency

The exact `8ca0d15b` binary was then compared against itself with native tiers
enabled and with JIT disabled plus bytecode execution required:

| workload | JIT median | required-VM median | JIT / VM | JIT RSD | VM RSD | checksum |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `representative_json` | 358.241 ms | 361.720 ms | `0.990x` | 2.55% | 11.25% | 324952086 |
| `representative_json_variant` | 354.177 ms | 357.100 ms | `0.992x` | 2.09% | 1.81% | 324952086 |

This clears the narrow #1017 criterion that JIT does not lose to required VM
on either frozen row. The base VM dispersion keeps the result diagnostic.
[Report](json-jit-residency-2026-10-01.md) ·
[28 raw samples](json-jit-residency-2026-10-01.json)

## Current JavaScriptCore gap

The same exact zig-js revision and workload bytes were compared with system
JavaScriptCore 21623.2.7.111.2. Every row uses seven fresh-process,
order-balanced pairs, clears a 50 ms median floor in both engines, and preserves
its exact cross-engine checksum.

| workload | zig-js median | JSC median | JSC / zig-js throughput | zig-js RSD | JSC RSD |
| --- | ---: | ---: | ---: | ---: | ---: |
| frozen base | 354.428 ms | 87.525 ms | `4.05x` | 1.69% | 1.40% |
| anti-specialization variant | 354.813 ms | 87.752 ms | `4.04x` | 1.74% | 1.45% |
| reviver/source control | 889.095 ms | 176.796 ms | `5.03x` | 2.81% | 2.72% |
| escaped-string control | 466.417 ms | 124.876 ms | `3.74x` | 2.18% | 2.06% |
| depth-4096 stringify | 1163.341 ms | 111.120 ms | `10.47x` | 17.58% | 2.82% |
| shallow-4096 stringify | 966.656 ms | 104.796 ms | `9.22x` | 3.31% | 1.32% |

[Direct-JSC report](json-jit-pipeline-jsc-2026-10-01.md) ·
[84 raw samples](json-jit-pipeline-jsc-2026-10-01.json)

## Correctness qualification

- affected bitwise test262: 30/30 pass and 30/30 tree/required-VM agreement;
- JSON test262: 165/165 pass and 165/165 tree/required-VM agreement;
- real-GC direct-root JSON parser/OOM family: 10/10 pass;
- real-GC deep-stringify family: 2/2 pass;
- 50,000-level array and object inputs throw catchable `RangeError` in both
  tree and required-VM modes, while 96-level inputs still parse;
- focused guarded-bitwise coverage passes in ReleaseFast and ReleaseSafe+TSan,
  including BigInt and observable-object fallback paths.

## Conclusion

The native-loop work is causal, checksum-exact, and control-bounded, and the
shipping JIT no longer trails required VM on these two rows. It does not close
#473: system JSC remains about 4.0x faster on the representative pair, and the
separate structure controls expose larger stringify gaps. Follow-up
[#1019](https://github.com/zig-utils/zig-js/issues/1019) owns the measured
recursive traversal problem, including deep/shallow, callback, OOM, GC,
no-GIL, and TSan guardrails.
