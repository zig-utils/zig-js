---
title: Building & Running
description: Compile zig-js and run the test262 conformance suite.
---

# Building & Running

## Prerequisites

zig-js requires **Zig 0.17.0-dev**. The 0.16 release will **not** build it.

> [!IMPORTANT]
> If your system `zig` is 0.16, use a pinned 0.17-dev toolchain (e.g. installed under `~/.local/share/zig-0.17-dev/zig`).

> [!IMPORTANT]
> zig-js resolves two sibling Zig packages by **local path** — `../zig-regex` and `../zig-gc` (see `build.zig.zon`). Both must be checked out next to your `zig-js` directory or the build cannot resolve its dependencies; CI provisions them from the `zig-utils` org.

The complete [dependency-ownership policy](/dependencies) is machine-checked.
Run `zig build dependency-audit` after changing a package, system link,
subprocess, script runtime, corpus, or acquisition input.

## Build the library

```bash
zig build                 # builds libzig-js.a
zig build test            # unit tests (-Dtest-filter=<substr> narrows; -Dtsan=true for ThreadSanitizer)
zig build conformance     # fast local smoke suite (33/33; not a CI gate)
zig build bench           # bytecode VM vs tree-walk microbenchmarks
zig build benchmark-comparison # zig-js single/shared vs system JSC (macOS only)
zig build threads-test    # the multithreading (issue #1) suite — this is what CI gates
```

The engine comparison runs seven median-scored samples of eight shared workloads and validates their checksums across zig-js and the system JavaScriptCore. Use `-Dbenchmark-comparison-quick=true` for a reduced harness check, and see [Performance Benchmarks](/benchmarks) for the method and latest saved result.

## Run the real test262 suite

`zig build test262` scores the pinned `test262` git submodule by default, so initialize it first (a missing corpus is skipped cleanly, not an error):

```bash
git submodule update --init test262
```

```bash
# Runs the pinned tc39/test262 corpus with a crash-proof subprocess harness.
zig build test262 -Doptimize=ReleaseFast

# Point at an explicit corpus root:
zig build test262 -Dtest262=/path/to/test262 -Doptimize=ReleaseFast
```

The runner prints a per-subtree breakdown and a totals summary:

<Terminal title="zig build test262 — summary">
<span class="cm">----------------------------------------------</span>
<span class="cy">VALID</span> (can we run it):  <span class="ok">{{ data.test262.valid.passing }}/{{ data.test262.valid.total }}</span> (<span class="hl">{{ data.test262.valid.percentage }}%</span>)   parse-fail {{ data.test262.valid.parseFail }} · runtime-fail {{ data.test262.valid.runtimeFail }} · host-fail {{ data.test262.valid.hostFail }}
<span class="cy">NEGATIVE</span> (strictness):  {{ data.test262.negative.passing }}/{{ data.test262.negative.total }} (<span class="hl">{{ data.test262.negative.percentage }}%</span>)
skipped (unsupported harness/path metadata): {{ data.test262.skipped }}
</Terminal>

> [!NOTE]
> A cold `ReleaseFast` build can take ~25–30 minutes; a cached run of the suite is a couple of minutes. There is no wall-clock timeout — a `step_budget` bounds runtime instead.

## Diagnostics

```bash
# Cluster failures within a single subtree
zig build diag -Doptimize=ReleaseFast -- run test/language
```

## Updating the docs numbers

The conformance figures on this site live in `docs/.data/test262.json`. Regenerate them from a real run:

```bash
bun scripts/gen-test262-data.ts                    # runs the suite and rewrites the JSON
bun scripts/gen-test262-data.ts --from run.txt     # or parse a saved run's output
```

The remaining Bun-based data generator is tracked by #497; the documentation
build itself is offline and requires only Zig. Every page that reads
`data.test262` (the homepage bar and [conformance](/conformance) page) updates
on `zig build docs-manifest-update`, after which `zig build docs-build` verifies
the exact output tree.

## Building and previewing the documentation

```bash
python3 tools/docs-link-check.py       # source links and configured navigation
zig build docs-build                  # render offline and verify the checked manifest
zig build docs-preview                # serve dist/ on 127.0.0.1:4173
zig build docs-preview -Ddocs-port=8080
```

The builder discovers every public Markdown page, expands the checked test262
data and repository components, renders code highlighting and search metadata,
copies evidence assets, and emits `sitemap.xml` and `robots.txt`. When an
intentional source or renderer change alters the output, inspect `dist/` and
run `zig build docs-manifest-update`; CI rejects any unaccepted page, asset, or
tree-hash drift.

To inspect what is still outside the denominator:

```bash
zig build test262-bin
./zig-out/bin/test262 --list-skips > docs/.data/test262-skips.tsv
./zig-out/bin/test262 --list-excluded > docs/.data/test262-excluded.tsv
```
