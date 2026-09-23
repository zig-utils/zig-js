# Bounded-repeat capture rollback: diagnostic cost controls

Measured 2026-09-23, 13:12:24–13:12:36 UTC. This is a **regex-library diagnostic**,
not an end-to-end zig-js benchmark, a JavaScriptCore comparison, or a quiet-host
reference result. It measures four controls whose outputs are identical before
and after the correctness fix. The observed median elapsed-time ratios span
0.987–1.002× the parent; they do not establish a speedup or negligible overhead
outside these controls.

## Evidence and revisions

- [All 56 scored samples and eight calibration records](regex-capture-cost-2026-09-23.json), including stdout, stderr, checksums, binary hashes, and host metadata.
- [Exact collector snapshot](regex-capture-cost-2026-09-23-collector.js).
- [Benchmark source](../../bench/regex_capture_rollback.zig), frozen at zig-js `c47efccf7aa601acc169cf1fdd724f48cc45bbf7` before measurement.
- zig-regex parent: `1d3e5c9e3f2fb1c421de6433cab503220988617f`.
- zig-regex candidate: `601edb49ba0579f1a30e4318290a7d7fb919aeed`, the parent's direct child.
- Source SHA-256: `5010e1cc826d99e817b3f97bd47a05398432737dfc75f3e8f09ccce7b2afbd79`.
- Collector SHA-256: `15501f4eea8336f103e0db29e21c783668ccd8600282493370da115f9f169d07`.

Tracked source trees were clean at collection. The collector checked this and
the exact-parent relationship before running; source, collector, and executable
hashes were independently rechecked afterward. The immutable collector retains
the local paths used in this run; they are provenance, not portable defaults.

## Host and timed boundary

Apple M2 Pro, 10 CPUs, 16 GiB RAM; macOS 26.3.1 (a), build 25D771280a, on AC power.
Zig `0.17.0-dev.1441+d5181a9c9`, `ReleaseFast`, `std.heap.c_allocator`, libc linked;
Node v24.4.1 drove collection and independently confirmed expected match results.
No JavaScript engine or GC is linked into the measured executables. Thermal,
instruction/cycle, and energy readings were unavailable. This desktop was not
qualified as a quiet reference host.

Each fresh process compiles its regex and performs ten matching warmups before
starting `clock_gettime(UPTIME_RAW)`. Timed work is repeated `findFrom(input, 0)`
on a reused matcher, exact match/capture validation, checksum accumulation, and
result destruction. Regex compilation and process startup are excluded. Both
revisions run the same source and iteration count for a given row.

A 100-iteration pilot on each side chooses a common iteration count targeting
200 ms on the faster pilot. Seven pairs per row alternate parent/candidate order
by pair and row. All 56 scored samples exceed the 50 ms floor; none were discarded
or retried. The eight calibration runs are retained separately and are not part
of the reported statistics. The shared machine guard limited the process tree
to 3072 MB, with no other goal-owned heavy job running concurrently.

## Controls and results

All patterns force the backtracking engine via `(?=a)`. Inputs are alternating
`ab` bytes. Each iteration validates full-match start/end/text and the one
present capture, not merely the aggregate checksum.

| row | pattern | input bytes | expected end / capture | iterations | checksum per sample |
| --- | --- | ---: | --- | ---: | ---: |
| max_bound | `(?=a)(a\|b){1,64}` | 64 | 64 / `b` | 12,532 | 207,354,472 |
| failed_extra | `(?=a)(a\|b){1,64}` | 62 | 62 / `b` | 13,827 | 221,674,464 |
| exact_bound_control | `(?=a)(a\|b){64}` | 64 | 64 / `b` | 15,164 | 250,903,544 |
| lazy_control | `(?=a)(a\|b){1,64}?` | 64 | 1 / `a` | 35,894 | 12,706,476 |

Elapsed milliseconds for the entire per-sample iteration batch; seven samples
per side. RSD is sample standard deviation (denominator n−1) divided by mean.
Ratios are candidate median / parent median; lower means less elapsed time.

| row | parent median | candidate median | ratio | parent min–max | candidate min–max | RSD parent / candidate |
| --- | ---: | ---: | ---: | --- | --- | --- |
| max_bound | 195.240 | 194.883 | 0.998× | 191.484–199.660 | 189.653–197.831 | 1.46% / 1.50% |
| failed_extra | 210.667 | 211.175 | 1.002× | 208.682–215.857 | 209.318–214.989 | 1.36% / 0.92% |
| exact_bound_control | 201.626 | 199.101 | 0.987× | 200.065–208.441 | 198.243–202.120 | 1.44% / 0.68% |
| lazy_control | 207.508 | 207.384 | 0.999× | 199.502–210.526 | 196.646–208.158 | 1.70% / 2.61% |

The lazy and exact-bound rows are controls, not claims that the fix accelerates
those paths. Neither confidence intervals nor statistical significance are
claimed. The short observation window and four shapes cannot establish universal
cost, memory efficiency, or the performance of nested/empty-capture cases.

## Reproduce

Use the frozen fixture and separate, clean checkouts of the two dependency
revisions. With the recorded Zig toolchain, compile each executable identically:

```sh
zig build-exe -OReleaseFast --dep regex \
  -Mroot=bench/regex_capture_rollback.zig \
  -OReleaseFast -Mregex=/path/to/parent/src/root.zig -lc \
  -femit-bin=/path/to/run/capture-bench-before
zig build-exe -OReleaseFast --dep regex \
  -Mroot=bench/regex_capture_rollback.zig \
  -OReleaseFast -Mregex=/path/to/candidate/src/root.zig -lc \
  -femit-bin=/path/to/run/capture-bench-after
```

Run builds and collection sequentially under the shared memory guard. Copy the
collector to a `.cjs` file outside this repository (it uses CommonJS), adjust its
`root`, `repo`, dependency paths and Zig executable path, then run it with Node.
Use a new output directory: it deliberately refuses to overwrite an existing
`capture-cost.json`. The collector records its adjusted hash. Preserve all raw
records and report host differences rather than merging reruns into this sample.

## Correctness context, separate from timing

The fix restores captures from an accepted greedy bounded repetition when a
subsequent optional iteration fails. Its preserved 21,575-input differential
corpus improved from 308 to 141 mismatches: 167 corrected case IDs and zero newly
mismatching IDs; 800 compile refusals remained unchanged. These are differential
inputs, not test262 flips. In zig-js, 992 targeted test262 cases passed both before
and after; a new ten-check focused probe improved from 6/10 to 10/10 in tree and
VM modes. The timed controls deliberately exclude differing outputs.

Scope and remaining 141 mismatches are tracked in
[zig-regex #30](https://github.com/zig-utils/zig-regex/issues/30#issuecomment-5794768385);
consumer qualification is recorded in
[zig-js #988](https://github.com/zig-utils/zig-js/issues/988#issuecomment-5795405277).
The dependency issue remains open. No existing engine/JSC scorecard was changed.
