# Inspecting and cleaning the Zig build cache

Zig writes all build output into two repository-local directories:

| Path          | Contents                                                        |
| ------------- | --------------------------------------------------------------- |
| `.zig-cache/` | compiled objects (`o/`), scratch (`tmp/`), hashes (`h/`, `z/`)  |
| `zig-out/`    | installed artifacts (`zig build` `install` step outputs)        |

**Everything in both directories is reproducible** — deleting them only forces
the next build to recompile. Neither ever contains source or user-owned files.

## Why it grows without bound

Each distinct build configuration produces a distinct cache key and a fresh copy
of the artifact. Repeated *focused* test runs are the usual culprit: a filtered
build such as

```sh
zig build test -Dtest-filter=vm    # then ...=jit, ...=compiler, ...
```

relinks the whole root test binary under a new key for every filter string, so a
day of baseline-JIT development can leave dozens of multi-hundred-MB artifacts
behind. In practice `.zig-cache` has reached **~92 GB**, at which point LLVM
fails with `No space left on device`. Clearing the reproducible cache recovers
all of it.

Use the small production-module roots for repeated focused work:

```sh
zig build test-jit -Dtest-filter='integer provenance'
zig build test-vm -Dtest-filter='numeric loop'
zig build test-concurrency -Dtest-filter='atomic increments'
```

They use the same target, optimization mode, ThreadSanitizer option, external
dependencies, and production source modules as `zig build test`, but do not
link the unrelated C-API/corpus tests. `test-jit` is a 91-test low-level root.
The VM/concurrency steps are small semantic executables because importing the
production interpreter through `zig test` recursively discovers the entire
inline integration suite; their filter is a runtime selector, so distinct VM or
concurrency filters reuse one linked artifact. Run `zig build test` once after a
batch as the authoritative full-suite gate.

## Measured focused-build bound

On July 16, 2026, Zig `0.17.0-dev.956+2dca73595` on an Apple M3 Pro produced
the following repository-local cache growth from a fully cold `prune`:

| Invocations | Mode | Final `.zig-cache` | Documented bound |
| ----------- | ---- | ------------------ | ---------------- |
| 4 distinct `test-jit` filters + 3 distinct `test-vm` filters + 3 distinct `test-concurrency` filters | Debug | 121 MiB | at most 256 MiB |

The four JIT filters were `Tier claims`, `native entry`, `integer provenance`,
and `guarded unsigned`. The VM filters were `numeric loop`, `packed array`, and
`property loop`; the concurrency filters were `atomic increments`, `distinct
property`, and `join chain`. All ten selected and passed real cases. The cache
contained one 55 MiB production semantic executable, four roughly 5–13 MiB JIT
test artifacts, and 27 MiB of Zig metadata—rather than ten monolithic root test
images. Repeat this measurement after materially changing the focused roots;
Debug is the development-loop bound, while ReleaseFast/full-suite validation is
batched separately.

## Inspect

```sh
tools/zig-cache-tool.sh report        # (default) sizes, per-subdir breakdown,
                                      # largest o/ artifacts, reclaimable total
```

## Clean

```sh
tools/zig-cache-tool.sh prune --dry-run   # preview exactly what would be removed
tools/zig-cache-tool.sh prune             # remove .zig-cache and zig-out
```

`prune` removes the repository-local cache as one coherent unit. Zig 0.17's
`c/`, `h/`, and `z/` metadata retains references to compiled `o/` artifacts, so
keeping that metadata while deleting only the apparent bulk can make the next
build fail with `CacheCheckFailed`. A fully cold cache is both reproducible and
reliable.

## Safety

The tool is deliberately conservative and is the recommended way to clean the
cache:

- It accepts **no path arguments** — both targets are fixed repository-relative
  directories (`.zig-cache` and `zig-out`), so there is no way to point it at
  anything else.
- Before each removal it resolves the target parent and refuses to proceed
  unless the fixed target is `<repo>/.zig-cache` or `<repo>/zig-out`. `rm` does
  not traverse a final-component symlink, so a symlinked cache is unlinked
  rather than deleting its outside target.
- It locates the repository from its own location via `git rev-parse`, so it
  never acts on an unrelated directory even if run from elsewhere.

The manual equivalent is `rm -rf .zig-cache zig-out` from the repo root, but the
tool adds reporting and the outside-the-repo guard.
