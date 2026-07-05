---
title: Building & Running
description: Compile zig-js and run the test262 conformance suite.
---

# Building & Running

## Prerequisites

zig-js requires **Zig 0.17.0-dev**. The 0.16 release will **not** build it.

> [!IMPORTANT]
> If your system `zig` is 0.16, use a pinned 0.17-dev toolchain (e.g. installed under `~/.local/share/zig-0.17-dev/zig`). The `bun run docs:data` script below auto-detects that path.

## Build the library

```bash
zig build                 # builds libzig-js.a
zig build test            # unit tests
zig build conformance     # fast smoke suite (must stay green)
```

## Run the real test262 suite

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
skipped (module/async/unloadable-includes): {{ data.test262.skipped }}
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
