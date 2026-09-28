# JSON parse CPU-work diagnostics (Debug)

Measured 29 September 2026 local time (28 September UTC). Two independently
profiled changes under [#473](https://github.com/zig-utils/zig-js/issues/473)
reduce work on selected JSON parsing paths. These are **Debug, default-arena,
whole-process diagnostics**, not production throughput or JavaScriptCore scores.

The [raw bundle](json-parse-cpu-work-2026-09-29.json) contains all 56 samples,
complete command output, checksums, collector source, workload source/hashes,
binary hashes, profiles and correctness receipts. No sample was discarded.

## Revisions and method

| change | exact parent | candidate |
| --- | --- | --- |
| [#991: ordinary spans between escapes](https://github.com/zig-utils/zig-js/issues/991) | `e07db3736f49676d6efef3c22a90b889ef5dd172` | `d74ac118d296f5c844acde719bff345b36374264` |
| [#992: exact short integers](https://github.com/zig-utils/zig-js/issues/992) | `d74ac118d296f5c844acde719bff345b36374264` | `0474640a5ffc6ae472c3679f9b7bd774f1b60162` |

- Apple M2 Pro, 16 GiB, macOS 26.3.1 (a), build 25D771280a; AC power.
- Zig `0.17.0-dev.1770+5d7cf3f34`, Debug, same compiler and dependency revisions
  on both sides of each comparison.
- zig-regex `fdd9c2e333ea6ac2fd06d080d939ef7f11d61b1b`; real zig-gc dependency
  `0285ef801dd221a4ae8e88b31a09ae31627657a3`, not the local stub. The dependency
  is linked, but **the runtime collector is off**: `test262 --eval` uses
  `Context.create` defaults. Corpus options also use `parallel_js=false`.
- Seven fresh-process samples per side and workload, alternating order by pair
  and workload; clean tracked candidate inputs when collecting each stage.
- `/usr/bin/time -l` measures process startup, Context creation, JS source/input
  preparation, parsing loop, checksum and teardown together. Tree mode is
  explicitly selected. There is no warmed-context timing boundary.
- All heavy work ran sequentially under the shared lock and 3072 MiB
  process-tree guard. This was not a qualified quiet reference host; timing
  dispersion is retained rather than filtered away.

## Measured CPU work

Medians of seven samples per side. RSD is population standard deviation divided
by mean. Ratios below compare the same workload against its exact parent;
different rows are not cross-workload comparisons.

| workload | parent instructions | candidate instructions | candidate / parent | instruction RSD, parent / candidate |
| --- | ---: | ---: | ---: | ---: |
| two 65,536-byte spans with a newline escape, 256 parses | 12,348,381,280 | 5,963,064,446 | 0.4829× | 0.10% / 0.18% |
| same-length unescaped control, 256 parses | 5,831,405,268 | 5,826,928,681 | 0.9992× | 0.16% / 0.15% |
| 4,096 nine-digit integers, 512 array parses | 9,753,810,274 | 7,075,225,009 | 0.7254× | 0.28% / 0.31% |
| matching fractional `.5` control, 512 array parses | 11,568,200,590 | 11,616,007,089 | 1.0041× | 0.16% / 0.15% |

The affected probes retire 51.7% and 27.5% fewer instructions. The plain-string
control differs by -0.08%; the fractional control costs 0.41% more, which remains
visible rather than being described as an improvement. Checksums are identical
before/after: `33593088` for each string workload, `126423945728` for integers,
and `126423946240` for fractions. Node v24.4.1 independently confirms them.

Whole-process wall medians are 0.84→0.49 s, 0.49→0.48 s, 1.01→0.74 s and
1.22→1.25 s respectively. Wall RSD ranges from 6.2% to 20.7%, so these timings
are **not promoted to throughput claims**. Peak process-footprint medians are
77,824,408→77,988,248 bytes for escaped strings, unchanged 43,762,024 bytes for
plain strings, unchanged 28,180,840 bytes for integers, and unchanged
28,475,752 bytes for fractions. This is not a memory-reduction claim either.

## What changed

The escaped-string profile found a dominant ordinary-byte append stack in 670
of 1,737 main-thread samples. The parser now copies its already-validated prefix
once and appends runs between escapes. Unicode escape decoding, raw-control
rejection and final string ownership remain on the existing paths.

The integer profile found a dominant general float-conversion stack in 730 of
1,782 main-thread samples. After unchanged JSON grammar validation, integer-only
tokens of at most 15 digits now accumulate in `u64` and convert once to `f64`.
That entire domain is exactly representable. Negating the float preserves
negative zero; longer integers, fractions and exponents retain correctly
rounded general conversion. No input, error or feature is excluded to obtain
these results.

## Correctness boundary

- Pinned test262 revision `4249661388e5d3f92a85186213da140a6481490f`:
  `test/built-ins/JSON` is **165 pass / 0 fail** at all three engine revisions.
  The configured runner's selected denominator is unchanged: **0 cases flip**.
- Each revision yields **165 tree/required-VM agreements, 0 divergences**.
- The 85-check string fixture passes tree and required-VM before/after #991
  and again after #992. It covers long spans, all raw controls, escapes,
  surrogate boundaries, NUL keys, duplicate decoded keys and reviver source.
- The number fixture passes Node and tree/required-VM before/after #992. It
  covers 23 numeric forms, 18 invalid forms, signed zero and reviver source.
- Final direct-root tests: four JSON parser tests plus the imported JIT test
  pass, including 4,096 seeded signed bit-exact integer comparisons, 22 explicit
  numeric boundaries and every-allocation failure injection for escaped runs.
- The compiled focused runtime runner passes all **three** `JSON` cases,
  including both new pinned fixtures and the existing nesting case.

These receipts do not claim a full test262/unit run, GC-enabled run, TSan run,
ReleaseFast performance improvement, or a JSC comparison.

## Reproduce

The raw bundle retains each stage's collector source. Build the three revisions
with the identical compiler/dependency pins and separate binary output paths;
its `build` record preserves the direct compiler command and build-options
module. Preserve the baseline binary before changing engine sources.

Run the checked-in workloads with each relevant binary from the repository
root, sequentially under the same memory guard:

```sh
/usr/bin/time -l /path/to/test262 --eval bench/json_parse_escaped.js tree
/usr/bin/time -l /path/to/test262 --eval bench/json_parse_plain.js tree
/usr/bin/time -l /path/to/test262 --eval bench/json_parse_integers.js tree
/usr/bin/time -l /path/to/test262 --eval bench/json_parse_decimals.js tree
/path/to/test262 --diag test/built-ins/JSON
/path/to/test262 --vm-witness-subtree test/built-ins/JSON
```

Each collector takes seven alternating pairs, requires matching exact checksums
and preserves stdout/stderr. Do not overlap these processes with corpus jobs or
compilers. The preserved full profiles are separate sampling runs, not members
of the performance sample set.
