---
title: Building & Running
description: Compile zig-js and run the test262 conformance suite.
---

# Building & Running

## Prerequisites

zig-js requires **Zig 0.17.0-dev**. The 0.16 release will **not** build it.

> [!IMPORTANT]
> If your system `zig` is 0.16, use a pinned 0.17-dev toolchain (e.g. installed under `~/.local/share/zig-0.17-dev/zig`). The `bun run docs:data` script below auto-detects that path.

> [!IMPORTANT]
> zig-js resolves two sibling Zig packages by **local path** — `../zig-regex` and `../zig-gc` (see `build.zig.zon`). Both must be checked out next to your `zig-js` directory or the build cannot resolve its dependencies; CI provisions them from the `zig-utils` org.

## Build the library

```bash
zig build                 # builds libzig-js.a
zig build test            # unit tests (-Dtest-filter=<substr> narrows; -Dtsan=true for ThreadSanitizer)
zig build conformance     # fast local smoke suite (33/33; not a CI gate)
zig build bench           # bytecode VM vs tree-walk microbenchmarks
zig build threads-test    # the multithreading (issue #1) suite — this is what CI gates
```

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
bun run docs:data                      # runs the suite and rewrites the JSON
bun run docs:data -- --from run.txt    # or parse a saved run's output
```

Every page that reads `data.test262` (the homepage bar, the [conformance](/conformance) page) updates automatically on the next `bun run docs:build`.

To inspect what is still outside the denominator:

```bash
zig build test262-bin
./zig-out/bin/test262 --list-skips > docs/.data/test262-skips.tsv
./zig-out/bin/test262 --list-excluded > docs/.data/test262-excluded.tsv
```
