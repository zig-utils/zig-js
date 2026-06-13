# Thread Testing

Thread support is verified with Zig `0.17-dev`. The package declares this in
`build.zig.zon`, and the build options below use the Zig 0.17 build API.

## Required Checks

```sh
zig build test
zig build threads-test
zig build threads-test -Dthreads-case=atomics/property-waitasync-timeout.js
zig build test -Dtsan=true
bun run docs:build
```

`zig build test` runs the unit and C-API suite, including focused tests for
agents, workers, shared buffers, property-mode Atomics, `Thread`, `Lock`,
`Condition`, `ThreadLocal`, and the main can-block gate.

`zig build threads-test` runs the green WebKit PR-249 allowlist from
`reference/webkit-249/threads-tests`. The current allowlist is 30/30 and covers:

- `api/`: lifecycle, ids, constructor errors, exceptions, restriction,
  blocking gates, lock/condition basics, async lock/condition behavior, and
  thread-local storage.
- `atomics/`: property load/store, RMW, SameValueZero compare-exchange, errors,
  wait/notify, and waitAsync timeout behavior.
- `sync/`: mutex-style counters, condition handshakes, notify-all behavior, and
  thread-local isolation.

`zig build test -Dtsan=true` builds the unit suite under ThreadSanitizer. This
is the concurrency gate for shared-buffer storage, agent waiters, workers, and
the shared-realm GIL path.

## Focused Runs

Use `-Dthreads-case=<path>` to run a single vendored thread test:

```sh
zig build threads-test -Dthreads-case=api/thread-basic.js
zig build threads-test -Dthreads-case=atomics/property-waitasync-timeout.js
```

Use this when developing one behavior or debugging a regression. The path is
relative to `reference/webkit-249/threads-tests`.

## Sweep Runs

Use `-Dthreads-sweep=true` to run every vendored file in `api/`, `atomics/`,
and `sync/` instead of only the green allowlist:

```sh
zig build threads-test -Dthreads-sweep=true
```

Sweep mode is exploratory. A file can fail because it requires machinery outside
today's GIL'd tree-walker support, or because it targets a future Layer-C
object-model invariant. Keep the default allowlist green; promote sweep files
only when their behavior is implemented and stable.

## Docs Checks

```sh
bun run docs:build
rg "27/""27|threads-test ""--" README.md docs bunpress.config.ts
```

The search should find no stale 27-of-27 counts and no removed thread-test
pass-through command syntax. Use the `-Dthreads-case` and `-Dthreads-sweep`
options instead.

## When Adding Thread Work

- Add or update unit tests for narrow engine behavior.
- Add a WebKit PR-249 corpus file to the allowlist only after it passes
  consistently.
- Update [bindings.md](./bindings.md) for every new file-scope mutable `var`,
  `pub var`, `threadlocal`, or container-scope mutable static.
- Re-run the ThreadSanitizer suite before merging any change that affects
  waiters, shared buffers, workers, GIL ownership, or cross-thread task
  delivery.
