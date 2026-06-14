# Thread API Reference

This page describes the shared-realm thread API installed by:

```zig
const ctx = try js.Context.createWith(gpa, .{ .enable_threads = true });
```

Without `enable_threads`, the context keeps the original single-thread affinity
rule and none of the globals below are installed.

## Model

`new Thread(fn, ...args)` runs `fn` on a real OS thread in the same realm as the
creator. That means:

- `globalThis`, ordinary objects, functions, symbols, arrays, and closures keep
  identity across `join`.
- There is no structured clone between shared-realm threads.
- All JS execution and heap access is serialized by the context GIL.
- Each running thread has its own interpreter instance, microtask queue, async
  waiter list, call-depth counter, and exception slot.

The model gives blocking and interleaving semantics today without claiming true
parallel JavaScript heap mutation.

## `Thread`

```js
const t = new Thread((box) => {
  box.n += 1;
  return box;
}, sharedBox);

if (t.join() !== sharedBox) throw new Error("identity changed");
```

Supported behavior:

- `new Thread(fn, ...args)` requires `new` and a callable `fn`.
- `fn` is called with `this === undefined` in strict functions.
- Arguments are same-realm values, not clones.
- `thread.id` is a numeric id; the main thread is `0`.
- `Thread.current` returns the current thread wrapper.
- `thread.join()` blocks until the target function returns and its own
  microtask queue drains.
- `join()` returns the target's value by identity, or rethrows the actual
  exception object.
- `thread.asyncJoin()` returns a promise for the same completion. If the thread
  is still running, the finishing thread settles the promise.
- Joining the current thread throws.
- The test-shell `drainMicrotasks()` helper drains only the current
  interpreter's promise jobs. It does not deliver threaded task-queue work such
  as `Lock.asyncHold` grants.

`Thread.restrict(obj)` pins a plain object or plain array to the calling OS
thread. Enforced foreign access throws `ConcurrentAccessError`. Exotic objects
such as functions, proxies, the global object, typed-array views, buffers,
collections, dates, regexps, errors, promises, and builtin prototypes are
refused.

## `ConcurrentAccessError`

`ConcurrentAccessError` is installed only in threaded contexts. It is thrown
when a restricted object is touched from an OS thread other than the owner
recorded by `Thread.restrict(obj)`.

The restriction is a defensive tool for tests and host-owned objects that must
not be shared accidentally. It is not a substitute for true parallel JS object
mutation; ordinary shared-realm objects still rely on the context GIL for
safety.

## `Lock`

`Lock` is non-recursive. `hold(fn)` acquires the lock, runs `fn`, and releases
the lock even when `fn` throws.

`Atomics.Mutex` is the proposal-aligned constructor in threaded contexts. It is
the same constructor as `Lock`, so `new Atomics.Mutex()` creates the existing
non-recursive lock record, while static `Atomics.Mutex.*` methods expose the
proposal-style unlock-token API.

```js
const lock = new Lock();
const counter = { n: 0 };

new Thread(() => {
  for (let i = 0; i < 1000; i++) {
    lock.hold(() => {
      counter.n = counter.n + 1;
    });
  }
}).join();
```

Supported behavior:

- `new Lock()` requires `new`.
- `lock.hold(fn)` requires a callable.
- A nested `hold` on the same lock from the same thread throws instead of
  deadlocking.
- Contended `hold` releases the GIL while parked.
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
own data properties and is serialized by the GIL.

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
  context's `Gil`, so independent threaded contexts cannot cross-notify.
