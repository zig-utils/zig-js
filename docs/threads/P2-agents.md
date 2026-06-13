# Phase 2 design: real concurrent agents + blocking Atomics

Status: implemented (`src/agent.zig`, typed-array Atomics hooks in
`src/interpreter.zig`). Scope: Phase 2 of
https://github.com/zig-utils/zig-js/issues/1 — replace the cooperative
`$262.agent` model with real OS-thread agents, and make `Atomics.wait` /
`Atomics.notify` genuinely block and wake. Builds on Phase 1
(`src/shared_buffer.zig`: refcounted process-wide SAB storage) and the
bindings audit (`bindings.md`).

## Primitives

This zig-0.17-dev's `std.Thread` has spawn/join/Id only; Mutex/Condition
moved to `std.Io` and require an `Io` instance (vtable with
`futexWait`/`futexWake`). `std.Io.Threaded` is the blocking implementation
with real futex waits and timeouts. Decision: one engine-global
`std.Io.Threaded` instance (lazily initialized, page_allocator-backed) in a
new `src/agent.zig`, giving the engine `Io.Mutex`, `Io.Condition.waitTimeout`,
and real sleep. The conformance runner already constructs a `std.Io` for file
I/O, so the dependency is precedented.

## AgentGroup (replaces `g_agent`)

One `AgentGroup` per main `Context` (process-global registry keyed by nothing
— v1 keeps exactly one live group; the runner runs one test per process-worker
already). All fields mutex-guarded unless noted:

- `reports: FIFO of []u8` — copied OUT of agent arenas (an agent's arena dies
  with the agent; the group allocator owns report strings).
- `agents: list of *AgentRecord`.
- `bcast: ?*SharedBufferStorage` (holds a ref) + a broadcast generation
  counter for the rendezvous.

`AgentRecord`: `std.Thread` handle, state word (`starting / parked_for_bcast /
running / done`, atomic), `can_block: bool = true`, stop flag (atomic, for
teardown), its own arena/realm (exactly today's `agentRunSync` realm setup —
per-realm shapes/microtasks/RetainList stay, which is why Phase 1 needs no
shape locks).

`threadlocal var t_agent: ?*AgentRecord` replaces `t_is_agent` (the bindings
audit's per-thread ruling).

## Protocol (test262 INTERPRETING.md semantics)

- `$262.agent.start(src)`: spawn the OS thread NOW. The agent thread runs
  `src` in its fresh realm. `receiveBroadcast(cb)` parks the agent
  (state=parked_for_bcast, waits on the group condition) until a broadcast
  generation arrives, then calls `cb(sab)` with a wrapper over the retained
  storage. This ordering — agent code runs immediately, broadcast blocks —
  is precisely what the cooperative model could not express and what the
  blocking-wait tests require.
- `broadcast(sab)`: publish storage + bump generation, wake all parked
  receivers, then block the caller until every started agent has acked
  receipt (counted under the group mutex). Agents started but never reaching
  `receiveBroadcast` would deadlock the parent — guard with the runner's
  process-level timeout plus a generous internal cap (60s) that reports and
  proceeds (matches engine262/V8 shell behavior closely enough for the
  corpus).
- `report(msg)`: mutex push (dupe into group allocator). `getReport()`:
  mutex pop or null. `sleep(ms)`: real sleep. `monotonicNow()`:
  `std.time.Timer` based, ms resolution, one timer per process (monotonic
  across agents — several timeout tests measure elapsed spans across agents).
- `leaving()`: marks done; the thread exits after draining microtasks.
  Group teardown (`agentResetState` successor, called per test): set every
  stop flag, notify all waiter lists (parked waiters must poll their stop
  flag on wake — PR-249's "stop the world waited for a world that couldn't
  hear it" lesson), join each thread with a hard cap, release the broadcast
  ref, free reports.
- Lifetime rule (assert in debug): no pointer into an agent arena survives
  the agent. Only SAB storage refs and group-owned report copies cross.

## Waiter table (blocking wait/notify)

In `src/shared_buffer.zig` (or `src/agent.zig`): a global table
`(storage: *SharedBufferStorage, byte_offset: usize) → WaiterList`, guarded
by one global `Io.Mutex` (contention is bounded by the corpus's scale; shard
later if it ever matters). `WaiterList`: FIFO of tickets; each ticket has its
own `Io.Condition` + woken/stop bits.

- `Atomics.wait(ta, i, expected, timeout)`: validate (i32/i64, shared,
  `[[CanBlock]]` else TypeError) → under the list lock re-load the element
  (SeqCst, via the Phase-1 atomic accessors) → `"not-equal"` early-out →
  enqueue ticket → `Condition.waitTimeout` loop until woken / timed out /
  stopped → dequeue → `"ok"` / `"timed-out"`.
- `Atomics.notify(ta, i, count)`: under the list lock, mark+signal up to
  `count` tickets FIFO; return the number actually woken. Non-shared
  buffers: return 0 without touching the table.
- `waitAsync` (Phase 3): same list, ticket carries a promise capability +
  owning agent; notify marks it and pokes the owner's inbox; the owner's
  drain loop settles it. Designed so Phase 2's table needs no rework.
- `[[CanBlock]]`: field on AgentRecord (agents true; main agent host-set).
  Runner gains a mode to run `CanBlockIsFalse` tests with main-agent
  can_block=false instead of skipping them.

## Runner interaction

The test262 runner's per-worker process isolation is the crash/hang backstop;
it needs a wall-clock timeout per test (currently none — a wedged agent test
would stall a worker subprocess forever). Add a watchdog: the parent already
respawns workers past a crash; extend the protocol with "no progress in N
seconds → kill + respawn past the test" BEFORE enabling real agents, so a
deadlock costs one test, not the run. This lands first, as its own commit.

## Order of work

1. Runner watchdog (independent, also useful today).
2. `src/agent.zig`: Io.Threaded bootstrap, AgentGroup/AgentRecord, rewire
   `$262.agent.*` (cooperative path deleted), `monotonicNow`/`sleep` real.
3. Waiter table + blocking `wait`/`notify` + `[[CanBlock]]` plumbing.
4. Bindings-audit execution: per-thread `math_prng`, atomic `symbol_counter`
   (both flagged in bindings.md), re-verify `re_legacy`/depth are per-realm.
5. Stress: 1000× loop of the heaviest wait/notify tests; TSan build of the
   agent unit tests.
