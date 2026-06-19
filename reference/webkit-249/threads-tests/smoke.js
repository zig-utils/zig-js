//@ requireOptions("--useJSThreads=1")
// Hello-threads smoke test for the GIL'd Thread() stub.
load("./resources/assert.js", "caller relative");

// Basic spawn + join with a result.
shouldBe(new Thread(() => 42).join(), 42);

// Arguments and shared lexical scope: objects really are shared.
const shared = { counter: 0 };
const t1 = new Thread((obj, amount) => {
    obj.counter += amount;
    obj.fromThread = "hello";
    return obj;
}, shared, 5);
shouldBe(t1.join(), shared);
shouldBe(shared.counter, 5);
shouldBe(shared.fromThread, "hello");

// join() agreement across repeat calls; exceptions rethrow identically.
const boom = new Error("boom");
const failing = new Thread(() => { throw boom; });
shouldBe(shouldThrow(() => failing.join()), boom);
shouldBe(shouldThrow(() => failing.join()), boom);

// Thread identity: current, id, self-join rejection.
shouldBe(Thread.current.id, 0);
const t2 = new Thread(() => {
    if (Thread.current.id === 0)
        throw new Error("spawned thread must not have tid 0");
    shouldThrow(() => Thread.current.join());
    return Thread.current.id;
});
shouldBe(t2.join(), t2.id);

// Lock: mutual exclusion over a shared counter.
const lock = new Lock();
const data = { value: 0 };
const workers = spawnN(4, () => {
    for (let i = 0; i < 1000; ++i)
        lock.hold(() => { data.value++; });
});
joinAll(workers);
shouldBe(data.value, 4000);
shouldThrow(() => lock.hold(() => lock.hold(() => {})));

// Condition: producer/consumer handshake.
const cond = new Condition();
const mailbox = { ready: false, payload: null };
const consumer = new Thread(() => {
    let received;
    lock.hold(() => {
        while (!mailbox.ready)
            cond.wait(lock);
        received = mailbox.payload;
    });
    return received;
});
lock.hold(() => {
    mailbox.payload = "package";
    mailbox.ready = true;
    cond.notifyAll();
});
shouldBe(consumer.join(), "package");

// ThreadLocal: per-thread slots.
const tls = new ThreadLocal();
tls.value = "main";
const t3 = new Thread(() => {
    shouldBe(tls.value, undefined);
    tls.value = "worker";
    return tls.value;
});
shouldBe(t3.join(), "worker");
shouldBe(tls.value, "main");

// Atomics on object properties (trivially atomic under the GIL).
const cell = { x: 0 };
shouldBe(Atomics.store(cell, "x", 7), 7);
shouldBe(Atomics.load(cell, "x"), 7);
shouldBe(Atomics.add(cell, "x", 3), 7);
shouldBe(cell.x, 10);
shouldBe(Atomics.exchange(cell, "x", "swapped"), 10);
shouldBe(cell.x, "swapped");
shouldBe(Atomics.compareExchange(cell, "x", "swapped", 1), "swapped");
shouldBe(cell.x, 1);
const adders = spawnN(4, () => {
    for (let i = 0; i < 500; ++i)
        Atomics.add(cell, "x", 1);
});
joinAll(adders);
shouldBe(cell.x, 2001);

// Typed-array Atomics path is unchanged when given views.
const i32 = new Int32Array(new SharedArrayBuffer(8));
Atomics.store(i32, 0, 41);
shouldBe(Atomics.add(i32, 0, 1), 41);
shouldBe(Atomics.load(i32, 0), 42);

// Property Atomics.wait/notify ping.
const futex = { turn: 0, ready: 0, done: 0 };
const waiter = new Thread(() => {
    Atomics.store(futex, "ready", 1);
    Atomics.notify(futex, "ready");
    const result = Atomics.wait(futex, "turn", 0);
    Atomics.store(futex, "done", 1);
    Atomics.notify(futex, "done");
    return result + ":" + futex.turn;
});
// Give the waiter a chance to enter wait(), then publish and wake. In the
// no-GIL runner the old busy-spin warm-up could dominate Debug-mode runtime,
// so use a bounded wait/notify loop instead.
if (Atomics.load(futex, "ready") === 0)
    Atomics.wait(futex, "ready", 0, 1000);
Atomics.store(futex, "turn", 1);
let woken = Atomics.notify(futex, "turn");
const deadline = Date.now() + 30000;
while (woken === 0 && Atomics.load(futex, "done") === 0) {
    if (Date.now() > deadline)
        throw new Error("property wait ping did not finish");
    Atomics.wait(futex, "done", 0, 5);
    woken += Atomics.notify(futex, "turn");
}
const pingResult = waiter.join();
if (pingResult !== "ok:1" && pingResult !== "not-equal:1")
    throw new Error("unexpected wait result: " + pingResult);

// Thread.restrict: foreign access throws ConcurrentAccessError.
const restricted = Thread.restrict({ secret: 1 });
shouldBe(Thread.restrict(restricted), restricted); // idempotent from owner
shouldBe(restricted.secret, 1); // owner unaffected
shouldThrow(TypeError, () => Thread.restrict(globalThis));

print("hello-threads smoke: PASS");
