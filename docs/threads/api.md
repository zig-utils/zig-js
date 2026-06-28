# Thread API Reference

This page describes the shared-realm thread API installed by:

```zig
const ctx = try js.Context.createWith(gpa, .{ .enable_threads = true });
```

`enable_threads` now means shared-realm JavaScript threads run true-parallel by
default over the GC-managed, thread-safe heap. The serialized fallback is an
explicit opt-out:

```zig
const ctx = try js.Context.createWith(gpa, .{
    .enable_threads = true,
    .gil = true,
});
```

Without `enable_threads`, the context keeps the original single-thread affinity
rule and none of the globals below are installed. The C API exposes the same
choice with `ZJSGlobalContextCreateThreaded(gil)`.

## Model

`new Thread(fn, ...args)` runs `fn` on a real OS thread in the same realm as the
creator. That means:

- `globalThis`, ordinary objects, functions, symbols, arrays, closures,
  promises, and collections keep identity across `join`.
- There is no structured clone between shared-realm threads.
- Parallel mode uses synchronized engine structures: shape transitions,
  named-property metadata and slots, indexed storage, environments, promises,
  microtasks, inline caches, waiter queues, and thread records are protected by
  dedicated locks or atomics.
- GIL mode runs the same JavaScript surface but serializes execution behind the
  context GIL.
- Each running thread has its own interpreter instance, call-depth counter,
  exception slot, and thread-local state.

The shared-realm API exposes parallel JavaScript execution, not automatic
program-level data-race freedom. Unsynchronized user writes to shared objects or
shared buffers can still be racy at the JavaScript level; the engine guarantee
is that those races do not corrupt engine state.

## `Thread`

```js
const box = { n: 0 };
const t = new Thread((shared) => {
  shared.n += 1;
  return shared;
}, box);

if (t.join() !== box) throw new Error("identity changed");
```

Supported behavior:

- `new Thread(fn, ...args)` requires `new` and a callable `fn`.
- `fn` is called with `this === undefined` in strict functions.
- Arguments are same-realm values, not clones.
- `thread.id` is a numeric id; the main thread is `0`.
- `Thread.current` returns the current thread wrapper.
- `thread.join()` blocks until the target function returns and its own pending
  completion work drains.
- `join()` returns the target's value by identity, or rethrows the actual
  exception object.
- `thread.asyncJoin()` returns a promise for the same completion. If the thread
  is still running, the finishing thread settles the promise through the realm
  queue.
- Joining the current thread throws.
- Abrupt top-level failure requests spawned-thread termination before teardown
  so parked child threads cannot strand the context.

`Thread.restrict(obj)` pins a plain object or plain array to the calling OS
thread. Enforced foreign access throws `ConcurrentAccessError`. Exotic objects
such as functions, proxies, the global object, typed-array views, buffers,
collections, dates, regexps, errors, promises, and builtin prototypes are
refused.

## `ConcurrentAccessError`

`ConcurrentAccessError` is installed only in threaded contexts. It is thrown
when a restricted object is touched from an OS thread other than the owner
recorded by `Thread.restrict(obj)`.

Restriction is a defensive tool for tests and host-owned objects that must not
be shared accidentally. It is not a replacement for locks or Atomics around
ordinary shared mutable data.

## `Lock`

`Lock` is non-recursive. `hold(fn)` acquires the lock, runs `fn`, and releases
the lock even when `fn` throws.

`Atomics.Mutex` is the proposal-aligned constructor in threaded contexts. It is
the same constructor as `Lock`, while static `Atomics.Mutex.*` methods expose
the proposal-style unlock-token API.

```js
const lock = new Lock();
const counter = { n: 0 };

const ts = [];
for (let i = 0; i < 4; i++) {
  ts.push(new Thread(() => {
    for (let j = 0; j < 1000; j++) {
      lock.hold(() => {
        counter.n = counter.n + 1;
      });
    }
  }));
}
for (const t of ts) t.join();
```

Supported behavior:

- `new Lock()` requires `new`.
- `lock.hold(fn)` requires a callable.
- A nested `hold` on the same lock from the same thread throws instead of
  deadlocking.
- Contended `hold` parks on the lock's own synchronization record.
- `lock.locked` reports whether the lock is currently held or synchronously
  granted.
- `lock.asyncHold(fn?)` grants the lock through the realm task queue. With a
  function, the function runs when the grant is delivered; without one, the
  promise resolves with a release function.
- An `asyncHold(fn)` callback return resolves the promise with the returned
  value. A thrown callback rejects the promise with the actual thrown value and
  still releases the lock.
- `Atomics.Mutex.lock(mutex, token?)` acquires `mutex` and returns an
  `Atomics.Mutex.UnlockToken`. Passing an unlocked token reuses it.
- `Atomics.Mutex.lockIfAvailable(mutex, timeout, token?)` returns an unlock
  token when it acquires before the timeout, or `null` when it cannot.
- `Atomics.Mutex.UnlockToken.prototype.locked` reports whether the token still
  owns a mutex. `unlock()` releases once and returns `true`; later calls return
  `false`. `[Symbol.dispose]()` also unlocks.

## `Condition`

`Condition.wait(lock)` atomically releases `lock`, parks the current thread, and
reacquires the lock before returning. Spurious wakeups are allowed, so callers
must loop on their predicate.

`Atomics.Condition` is the same constructor as `Condition` in threaded
contexts, with static token-based helpers that operate on
`Atomics.Mutex.UnlockToken` objects.

```js
const lock = new Lock();
const cond = new Condition();
const box = { ready: false, value: null };

const consumer = new Thread(() => {
  let out;
  lock.hold(() => {
    while (!box.ready) cond.wait(lock);
    out = box.value;
  });
  return out;
});

lock.hold(() => {
  box.value = 42;
  box.ready = true;
  cond.notify();
});

if (consumer.join() !== 42) throw new Error("lost wake");
```

Supported behavior:

- `new Condition()` requires `new`.
- `wait(lock)` requires the caller to hold the provided `Lock`.
- `notify()` wakes one waiter and returns the number woken.
- `notifyAll()` wakes all current waiters and returns the number woken.
- `asyncWait(lock)` participates in the same FIFO wait domain as sync waiters.
- `Atomics.Condition.wait(condition, token)` waits using a locked
  `Atomics.Mutex.UnlockToken`, then returns with the token locked again.
- `Atomics.Condition.waitFor(condition, token, timeout, predicate?)` returns
  `true` when notified before the timeout, or when `predicate` becomes truthy.
  It returns `false` on timeout.
- `Atomics.Condition.notify(condition, count?)` wakes up to `count` waiters, or
  all waiters when `count` is omitted.

## `ThreadLocal`

`ThreadLocal.value` stores one value per current JS thread.

```js
const tls = new ThreadLocal();
tls.value = "main";

const seen = new Thread(() => {
  const before = tls.value; // undefined
  tls.value = "worker";
  return [before, tls.value];
}).join();
```

The main thread's `value` and each spawned thread's `value` are independent.

## Property-Mode `Atomics`

In an `enable_threads` context, `Atomics.*` also accepts ordinary objects when
the first argument is an object that is not a typed array. This path is scoped to
own data properties and is synchronized by the object's property lock and the
per-context waiter tables where applicable.

Supported operations:

- `Atomics.load(obj, key)`
- `Atomics.store(obj, key, value)`
- `Atomics.exchange(obj, key, value)`
- `Atomics.compareExchange(obj, key, expected, replacement)`
- `Atomics.add/sub/and/or/xor(obj, key, value)`
- `Atomics.wait(obj, key, expected, timeout?)`
- `Atomics.waitAsync(obj, key, expected, timeout?)`
- `Atomics.notify(obj, key, count?)`

Important rules:

- Property mode only exists when `enable_threads` is on.
- The property must be an own data property for load, exchange,
  compareExchange, RMW, wait, and waitAsync.
- `store` may create a fresh default-attribute property on an extensible
  object, but throws for accessors, non-writable properties, or non-extensible
  objects.
- Values are not coerced for load, store, exchange, wait, or compareExchange.
- `compareExchange` uses SameValueZero, so `NaN` compare-exchange loops work.
- Numeric RMW operations require the stored value to be a number.
- Finite `waitAsync` tickets keep the shell/event-loop drain alive until they
  settle, including timeout settlement when no notifier arrives.
- Waiters are keyed by object identity plus property key and live on the owning
  context, so independent threaded contexts cannot cross-notify.

## Test-Only Controls

`Context.TestingOptions.parallel_js`, `parallel_midscript_gc`, shell helpers,
and `$vm` compatibility hooks exist for the conformance runners and bring-up
tests. They are intentionally not stable embedder APIs.
