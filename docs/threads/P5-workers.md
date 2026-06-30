# Phase 5 design: embedder Worker API + C-API rules

Status: implemented (`src/worker.zig`, C-API surface in `src/c_api.zig`).
Scope: Phase 5 of https://github.com/zig-utils/zig-js/issues/1 — the public,
embedder-facing face of Layer A. Builds on Phase 2 (`src/agent.zig`: the
engine-global `std.Io.Threaded`, real OS threads, blocking/wake) and Phase 4
(`src/structured_clone.zig`: the serialize→bytes→deserialize IR that is the
`postMessage` wire format).

## Model

A `Worker` owns one OS thread and one `Context` (own arena, realm, shapes,
microtask queue — the Phase-0 affinity model holds per worker). The only
things that cross a worker boundary are **serialized bytes** (process-
allocator-owned, produced by `structured_clone.serialize`) and **retained SAB
storage** (the refcounted `SharedBufferStorage` from Phase 1). Nothing that
lives in a worker arena ever escapes it — same lifetime rule as agents.

Messages flow over two `Channel`s (mutex + condition FIFOs of `[]u8`): `inbox`
(main→worker) and `outbox` (worker→main). Each channel drains with a FIFO head
cursor, so Worker-heavy receive loops do not front-shift remaining serialized
messages on every `pop`. A channel `close()` wakes every waiter; already-queued
messages stay poppable (drain-then-stop). `deinit` releases any bytes (and the
SAB refs inside them) never consumed.

## Worker lifecycle (`src/worker.zig`)

- `Worker.spawn(src)` — run `src` as a **script** in a fresh realm, then enter
  the delivery loop.
- `Worker.spawnModule(entry_path, entry_source, host)` — evaluate a **module
  graph** via `Context.evaluateModule`, resolving imports through the
  Phase-0 `Context.ModuleHost`. The `host.load` callback runs **on the worker
  thread**, so it must be thread-safe; an embedder-owned read-only module map
  is the canonical pattern. Returned source strings need only be valid for the
  duration of the call (they are duped into the worker realm's arena).
- `postMessage(from, v)` / `receive(into, timeout_ms)` — serialize from the
  caller's interpreter, deserialize into the caller's interpreter. `receive`
  returns null when the worker closed its outbox and drained, or the timeout
  elapsed (null = wait forever).
- `terminate()` — set the stop word the engines' step checkpoints poll
  (interpreter eval loop and `vm.zig` dispatch, every 1024 steps), making
  in-flight JS throw, and close the inbox so the delivery loop ends.
- `close()` — graceful shutdown: close the inbox so the loop drains remaining
  messages and exits, *without* the stop-flag interrupt of in-flight JS.
- `join()` then `destroy()` — join the thread, free the channels and the
  worker.

### Delivery loop

After the worker script/module runs (and installs `globalThis.onmessage`),
the worker parks on `inbox.pop`. Each message is deserialized into the worker
realm, handed to `onmessage({ data })`, then microtasks are drained and async
waiters settled before the next message. On loop exit the outbox is closed.

## Host scheduling hooks

`HostHooks{ ctx, notify }` + `Worker.setHostHooks(&hooks)` let an embedder with
its own event loop integrate instead of blocking in `receive`. `notify` fires
(possibly **from the worker thread**, so it must be thread-safe and
non-blocking) on every worker→main message push and on outbox close — the
embedder schedules a `receive` drain on the worker's owning thread. The hook
pointer is stored/loaded atomically; a message posted before the hook lands
fires no wake, so the embedder performs one initial drain after `setHostHooks`.

## C-API surface (`src/c_api.zig`)

A minimal `JSWorker*` surface, since JSC has no worker ABI to mirror (this is a
zig-js extension):

- `JSWorkerCreate(source)` → `JSWorkerRef` (script worker; null on failure).
- `JSWorkerPostMessage(worker, ctx, value, exception)` → bool — serialize
  `value` from `ctx`'s realm into the inbox; false + `exception` on a refused
  clone (function/symbol/etc.).
- `JSWorkerReceive(worker, ctx, timeout_ms, exception)` → `JSValueRef` —
  deserialize the next worker→main message into `ctx`'s realm; null on
  close/timeout.
- `JSWorkerTerminate(worker)` / `JSWorkerRelease(worker)` (close + join +
  destroy).

### Thread rules

Every handle is affine to its creating thread (the Phase-0 C-API rule). A
`JSWorkerRef` is itself affine to the thread that called `JSWorkerCreate`:
post/receive/terminate/release all run there. Values cross only as structured-
clone bytes against the `JSContextRef` passed to each call, so no foreign
context's handles are ever touched.

## Verification

`src/worker.zig` tests: 4-way SAB counter + terminate-mid-loop, module-graph
import round-trip, exact host-hook wakes for multi-message replies plus
graceful final outbox close, terminate final outbox close, and FIFO channel
drain without front shifts.
`src/c_api.zig` test: `JSWorkerCreate` → post a number → receive the doubled
reply. All TSan-clean. `worker.zig` and the C-API are not exercised by the
test262 shards, so the conformance total is unaffected.

## Deferred

- A `JSContextGroupRef`-shaped agent-cluster story for the C API (the standards
  agent cluster vs. the embedder worker pool) — deferred; the two pools are
  independent today.
