//@ requireOptions("--useJSThreads=1")
// API-I20: a pending asyncJoin keeps the shell alive until it settles
// (4.6.3: ticket liveness = 5.5 addPendingWork at registration); a FINISHED
// thread's pending asyncHold continuation still settles (4.6.2: tickets
// outlive their registering thread; the dead registrant's ticket settles per
// the 5.5 GIL relaxation).
load("../harness.js", "caller relative");

asyncTestStart(4);

// ---- 1. A pending asyncJoin retains its registration until settlement. ----
new Thread(() => "kept-alive").asyncJoin().then(v => {
    shouldBe(v, "kept-alive");
    asyncTestPassed();
});

// ---- 2. 4.6.2: thread registers an asyncHold ticket against a lock main
// holds, then FINISHES; the ticket must still be granted and its
// continuation must still run after main releases. ----
{
    const lock = new Lock();
    const sideEffects = { ran: 0 };
    let promiseFromThread;
    let t;
    lock.hold(() => {
        t = new Thread(() => lock.asyncHold(() => {
            sideEffects.ran++;
            return 7;
        }));
        // Main owns the lock before t can attempt asyncHold. Joining proves
        // the registrant has exited with its ticket still pending; releasing
        // the hold is the only grant edge.
        promiseFromThread = t.join();
        shouldBeTrue(promiseFromThread instanceof Promise);
        shouldBe(sideEffects.ran, 0, "continuation cannot run while the lock is held");
    });
    // Release pump (5.5a R) grants the dead thread's ticket on a RL turn.
    promiseFromThread.then(v => {
        shouldBe(v, 7);
        shouldBe(sideEffects.ran, 1);
        asyncTestPassed();
    });
}

// ---- 3. asyncJoin of an ALREADY-FINISHED thread settles on a run-loop
// turn (never synchronously — the I12 discipline applies here too) and
// keeps the shell alive meanwhile. ----
{
    const done = new Thread(() => 123);
    shouldBe(done.join(), 123);
    let settled = false;
    done.asyncJoin().then(v => {
        settled = true;
        shouldBe(v, 123);
        asyncTestPassed();
    });
    shouldBeFalse(settled, "asyncJoin of a finished thread must not settle synchronously");
}

// ---- 4. repeat asyncJoin calls: distinct promises, same settle (4.1). ----
{
    const t = new Thread(() => ({ once: true }));
    const pa = t.asyncJoin();
    const pb = t.asyncJoin();
    shouldBeFalse(pa === pb, "repeat asyncJoin calls return distinct promises");
    Promise.all([pa, pb]).then(([a, b]) => {
        shouldBe(a, b, "all joins agree (I4)");
        shouldBe(a.once, true);
        asyncTestPassed();
    });
}
