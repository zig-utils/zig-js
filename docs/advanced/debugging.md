---
title: Debugging & tooling
description: Inspector protocol, corpus diagnostics, sanitizers, profiles, and managing the Zig build cache.
---

# Debugging & tooling

## Inspecting running JavaScript

zig-js exposes an embedder-transported inspector protocol
(`zig-js-inspector/0.1`) through `include/zig-js/Extensions.h`. Public
JavaScriptCore inspectability stays **opt-in**:
`JSGlobalContextSetInspectable(ctx, true)` must run before
`ZJSInspectorSessionCreate` succeeds.

A session receives JSON messages through a synchronous callback and accepts JSON
requests through `ZJSInspectorSessionDispatch`; message bytes are borrowed only
for the duration of the call. Worker targets are isolated. The full domain list,
trust boundary, and current debugger boundary are in
[Inspector protocol](/inspector).

Script identity and source locations come from `Context.registerDebugScript` /
`registerDebugScriptWithLocations`.

## Diagnosing engine behaviour

The corpus runner doubles as the fastest engine probe:

```bash
zig build test262-bin
zig-out/bin/test262 --eval /tmp/probe.js       # OK <value> / ERR <name: msg>
zig-out/bin/test262 --diag test/language       # outcome<TAB>path<TAB>reason, clustered
```

`--diag`'s third column clusters failures by cause, which is how you tell "one
root cause across forty tests" from "forty distinct bugs":

```bash
zig-out/bin/test262 --diag test/language 2>/dev/null \
  | grep -av '^#' | cut -f3 | sort | uniq -c | sort -rn | head -30
```

`--diag` has **no per-test timeout**, so a full `test/language` pass takes
minutes. A DebugAllocator leak report on stderr is harmless for these modes; the
full-suite summary, by contrast, goes to stderr and must not be discarded.

For threading, the corpus binary is the cheap loop:

```bash
zig build threads-test-bin                            # ~40 s
zig-out/bin/threads-test one <case.js>
zig-out/bin/threads-test parallel-js one <case.js>
```

## Sanitizers

```bash
zig build test -Dtsan=true                     # ThreadSanitizer
zig build test -Dtsan=true -Dtest-filter=parallel_js
zig build threadfuzz -Dtsan=true -Dfuzz-iters=60
zig build threadfuzz -Doptimize=ReleaseSafe -Dfuzz-iters=400
zig build test-objc-api-sanitize               # ASan + UBSan (macOS bridge)
zig build test-objc-api-leaks                  # macOS leak checker
```

`ReleaseSafe` is a **different bug class** from TSan: it keeps Zig's safety
checks (UB, bounds, overflow, unreachable) on under the optimizer and catches
codegen-dependent faults the Debug build hides.

Reading a TSan result: "still fails with suppressions applied" is frequently the
case's **own functional assertion**, not a sanitizer abort — read the actual
`FAIL` line. The suppression boundary itself is a documented decision, not an
oversight: see [Memory model](/threads/memory-model).

## Profiles

```bash
zig build threads-profile                                  # no-GIL contention baseline
zig build threads-profile -Dthreads-profile-case='condition asyncWait'
zig build midgc-profile                                    # mid-script parallel-GC convergence
zig build gc-profile                                       # allocation + Context lifecycle
zig build bench                                            # VM vs tree-walker
```

Profiles locate cost. They are **not correctness gates and not publication
evidence** — publishing a number follows [Benchmarks](/benchmarks).

## When a job looks hung

A run at high CPU for hours may be **spinning, not slow**. Sample it before
believing the wall clock — on macOS:

```bash
sample <pid> 3 -f /tmp/out.txt
```

That has turned a "the tests are slow" belief into a diagnosed infinite loop in
seconds. Two related traps:

- **Never run two corpus jobs at once.** Some drivers reap survivors by process
  name and will kill the other run's cases, which are then silently recorded as
  failures or timeouts. Check `pgrep -f 'zig-out/bin/threads-test'` first.
- **Do not run corpus cases beside the unit suite.** The suite makes no visible
  progress for ten minutes and looks hung; that is starvation.

## Build cache

All build output lives in two repository-local directories:

| Path | Contents |
| --- | --- |
| `.zig-cache/` | compiled objects, scratch, hashes |
| `zig-out/` | installed artifacts |

**Everything in both is reproducible** — deleting them only forces a rebuild, and
neither ever contains source or user-owned files. Repeated focused test builds
(each filter is compile-time, so each relinks) grow the cache quickly. Inspection
and safe reclamation: [Build cache](/dev-cache), or `tools/zig-cache-tool.sh`.

## Build-cost expectations

| Action | Rough cost |
| --- | --- |
| `zig build test` relink after any `src/*.zig` edit | ~4–6 min |
| A filtered probe cycle (`-Dtest-filter=…`) | ~8–10 min |
| Full unit suite via `zig build test-parallel` | ~3 min across ~10 shards |
| `zig build threads-test-bin` | ~40 s |
| Cold `test262 -Doptimize=ReleaseFast` build | ~25–30 min |

Prefer **one instrumentation pass that answers several questions** over several
narrow probes.
