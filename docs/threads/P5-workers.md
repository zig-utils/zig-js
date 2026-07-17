# Phase 5 design: embedder Worker API + C-API rules

Status: implemented (`src/worker.zig`, C-API surface in `src/c_api.zig`).
Scope: Phase 5 of https://github.com/zig-utils/zig-js/issues/1 — the public,
embedder-facing face of Layer A. Builds on Phase 2 (`src/agent.zig`: the
engine-global `std.Io.Threaded`, real OS threads, blocking/wake) and Phase 4
(`src/structured_clone.zig`: the serialize→bytes→deserialize IR that is the
`postMessage` wire format).

## Model

A `Worker` owns one OS thread and one Context (own precise GC heap, realm,
shapes, microtask queue—the Phase-0 affinity model holds per worker). Precise
collection is the default because workers are long-lived agents;
`Worker.Options.context_options` exposes the complete Context policy for
deterministic and stress configurations. The only
things that cross a worker boundary are **serialized bytes** (process-
allocator-owned, produced by `structured_clone.serialize`) and **retained SAB
storage** (the refcounted `SharedBufferStorage` from Phase 1). Each framed
message owns a manifest of opaque random single-use SAB tokens, never process
pointers; the clone payload names them by canonical index. A locked registry
atomically consumes each token on deserialize or queue cleanup, and manifest
cleanup does not depend on recursively parsing a valid payload. Forged,
out-of-order, duplicate, and replayed token references fail closed. Nothing that
lives in a worker heap ever escapes it—same lifetime rule as agents.
Serialization, structural preflight, and deserialization share a 256-level
wire-nesting ceiling; an over-depth graph or payload produces a catchable clone
error while its frame manifest still releases retained SAB references.
Fixed-width graph IDs, lengths, and collection/property counts are checked on
write. Preflight rejects noncanonical flags/references and any count that cannot
fit the remaining payload before deserialization allocates or enters its loop;
`u64` sizes also fail closed when the host `usize` cannot represent them.

Messages flow over two `Channel`s (mutex + condition FIFOs of `[]u8`): `inbox`
(main→worker) and `outbox` (worker→main). Each channel drains with a FIFO head
cursor, so Worker-heavy receive loops do not front-shift remaining serialized
messages on every `pop`. Zero-timeout internal polls return while holding the
channel lock when the queue is empty instead of entering a timed condition wait,
which keeps `Worker.receive(..., 0)` suitable for host-side drain probes. A
channel `close()` wakes every waiter; already-queued messages stay poppable
(drain-then-stop). `Worker.spawnWith` / `spawnModuleWith` accept independent
inbox/outbox `ChannelLimits`; defaults are 64 MiB per frame, 256 MiB of live
queued bytes, and 1024 live messages. Push is nonblocking and fallible: closed,
limit, and metadata-allocation rejection is reported synchronously, after the
channel lock is released, and releases the rejected frame/SAB manifest exactly
once. Worker serialization enforces the complete per-frame cap from its first
write, including the frame header and SAB manifest, so rejection does not first
materialize an oversized process allocation. Live byte/message accounting is
decremented on pop; dead FIFO prefixes
compact before avoidable metadata growth. `deinit` releases any frames never
consumed.

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
  elapsed (null = wait forever). A post that returns successfully owns exactly
  one queued frame; closed/full/oversized delivery throws instead of silently
  dropping it.
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
- `JSWorkerCreateWithLimits(source, maxMessageBytes, maxQueuedBytes,
  maxQueuedMessages)` → `JSWorkerRef` with the same explicit cap applied to
  both directions (zero is a real zero limit).
- `JSWorkerPostMessage(worker, ctx, value, exception)` → bool — serialize
  `value` from `ctx`'s realm into the inbox; false + `exception` on a refused
  clone (function/symbol/etc.).
- `JSWorkerReceive(worker, ctx, timeout_ms, exception)` → `JSValueRef` —
  deserialize the next worker→main message into `ctx`'s realm; null on
  close/timeout.
- `JSWorkerTerminate(worker)` / `JSWorkerRelease(worker)` (close + join +
  destroy).
- `ZJSWorkerGetInspectorTargetInfo(worker, info)` snapshots a process-wide
  non-zero target ID, script/module kind, and atomic lifecycle state. IDs never
  encode a `Worker` address and are not reused; creation fails on theoretical
  64-bit exhaustion instead of aliasing a historical target.
- `ZJSWorkerInspectorSessionCreate/Dispatch/Pump/Release` is the worker-target
  inspector transport. Dispatch copies JSON into the worker queue; Pump invokes
  one message callback on the worker-handle owner thread and returns an explicit
  message/timeout/closed result. Paused runtimes continue draining inspector
  commands, so a pump callback can enqueue evaluation and the continuation.

### Thread rules

Every handle is affine to its creating thread (the Phase-0 C-API rule). A
`JSWorkerRef` is itself affine to the thread that called `JSWorkerCreate`:
post/receive/terminate/release all run there. Values cross only as structured-
clone bytes against the `JSContextRef` passed to each call, so no foreign
context's handles are ever touched.

## Verification

`src/worker.zig` tests: stable target identity plus script/module lifecycle,
4-way SAB counter + terminate-mid-loop, module-graph
import round-trip, exact host-hook wakes for multi-message replies plus
graceful final outbox close, terminate final outbox close, and FIFO channel
drain / zero-timeout poll behavior.
`src/c_api.zig` tests cover create/post/receive, owner-thread target metadata,
script and module inspector graphs, active-handler pauses, owner-pumped resume,
URL breakpoints, stepping, caught-exception pauses, live frames/scopes and frame
evaluation, retained remote-object inspection, observer continuation rejection,
callback detach, and termination while paused.
The real C++ host covers attach/schema dispatch/pump/release. All worker tests
are TSan-clean. `worker.zig` and the C-API are not exercised by the test262
shards, so the conformance total is unaffected.

## Deferred

- A `JSContextGroupRef`-shaped agent-cluster story for the C API (the standards
  agent cluster vs. the embedder worker pool) — deferred; the two pools are
  independent today.
