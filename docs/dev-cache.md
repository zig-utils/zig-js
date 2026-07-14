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

## Inspect

```sh
tools/zig-cache-tool.sh report        # (default) sizes, per-subdir breakdown,
                                      # largest o/ artifacts, reclaimable total
```

## Clean

```sh
tools/zig-cache-tool.sh prune --dry-run   # preview exactly what would be removed
tools/zig-cache-tool.sh prune             # remove .zig-cache/o, .zig-cache/tmp, zig-out
tools/zig-cache-tool.sh prune --all       # additionally drop h/ and z/ (fully cold rebuild)
```

`prune` removes only the reproducible bulk (compiled objects, scratch, and the
install tree) and keeps the small hash/manifest dirs so the next build can still
reuse unchanged inputs; `--all` forces a completely cold rebuild.

## Safety

The tool is deliberately conservative and is the recommended way to clean the
cache:

- It accepts **no path arguments** — every target is a fixed repository-relative
  directory (`.zig-cache/o`, `.zig-cache/tmp`, `.zig-cache/h`, `.zig-cache/z`,
  `zig-out`), so there is no way to point it at anything else.
- Before each removal it resolves the target through symlinks and refuses to
  proceed unless the result is inside `<repo>/.zig-cache` or `<repo>/zig-out`.
  Path-traversal attempts (e.g. a symlinked cache pointing outside the repo)
  are rejected rather than followed.
- It locates the repository from its own location via `git rev-parse`, so it
  never acts on an unrelated directory even if run from elsewhere.

The manual equivalent is `rm -rf .zig-cache zig-out` from the repo root, but the
tool adds the reporting and the outside-the-repo guard, and never leaves the
hash dirs in an inconsistent partial state.
