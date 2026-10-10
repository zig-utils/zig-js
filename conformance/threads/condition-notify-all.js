//@ requireOptions("--useJSThreads=1")
// Condition notification counts require a registered waiter. Hold the lock
// before spawning the notifier: Condition.wait publishes its queue ticket
// before releasing the lock, so the notifier's acquisition proves that edge.
load("../resources/assert.js", "caller relative");

const cond = new Condition();
const lock = new Lock();
shouldBe(cond.notify(), 0);
shouldBe(cond.notifyAll(), 0);
for (let i = 0; i < 10; ++i)
    cond.notifyAll();

function withParkedMain(notify) {
    const box = { ready: false };
    let worker;
    lock.hold(() => {
        worker = new Thread(() => {
            lock.hold(() => { box.ready = true; });
            notify(box);
            return "ok";
        });
        while (!box.ready)
            cond.wait(lock);
    });
    shouldBe(worker.join(), "ok");
    return box;
}

{
    const box = withParkedMain(box => { box.woken = cond.notifyAll(); });
    shouldBe(box.woken, 1, "earlier notifications were not buffered; main really parked");
}

for (const useAll of [false, true]) {
    for (let lap = 0; lap < 3; ++lap) {
        const box = withParkedMain(box => {
            box.first = useAll ? cond.notifyAll() : cond.notify();
            box.second = useAll ? cond.notifyAll() : cond.notify();
        });
        shouldBe(box.first, 1, (useAll ? "notifyAll" : "notify") + " woke the parked waiter (lap " + lap + ")");
        shouldBe(box.second, 0, "queue empty after the wake (lap " + lap + ")");
    }
}

{
    const condB = new Condition();
    const box = withParkedMain(box => {
        box.onB = condB.notifyAll();
        box.onA = cond.notifyAll();
    });
    shouldBe(box.onB, 0);
    shouldBe(box.onA, 1);
}
