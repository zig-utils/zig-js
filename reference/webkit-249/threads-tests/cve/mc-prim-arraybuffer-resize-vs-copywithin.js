//@ requireOptions("--useJSThreads=1")
// MC-PRIM susceptibility test (docs/threads/cve/map-MC-PRIM.md, surface P6).
//
// Sibling of mc-prim-arraybuffer-transfer-vs-atomics.js for the memmove-class
// fast path: %TypedArray%.prototype.copyWithin resolves its backing store via
// ArrayBufferData.bytes() and then issues a bulk copyForwards/copyBackwards
// over the raw {base, length} tuple. A NON-shared ArrayBuffer is reachable
// from two Threads under the shared heap, so a peer's resize() can, under the
// buffer lock, memcpy the old base into a fresh allocation and then FREE the
// old base (arrayBufferResizeFn -> freeArrayBufferBytes -> rawFree) while
// thread A's copyWithin is mid-memmove over that same old base — the exact
// CVE-2012-0507 torn-pair shape, here a data race (resize's read of old_data
// vs copyWithin's write) that escalates to a use-after-free / torn memmove.
// SPEC-ungil §N.6: a racing bulk copy must NEVER pair a passing length with an
// unmapped base. The fix serializes copyWithin's length re-read + memmove under
// lockBuffer (mirroring taRead/taWrite and the Atomics paths), which mutually
// excludes it against resize's swap+free.
//
// This bug is invisible to a value check alone: both the old and the fresh
// base carry MARK in the head window, so even a torn copy reads back MARK — it
// surfaces only as a TSAN data race / ASAN UAF. So the probe maximizes OVERLAP
// rather than relying on an out-of-band value: a hammer thread runs copyWithin
// in a tight loop over a FIXED-length WORDS-word head view while the main
// thread resizes the SAME buffer between MIN and MAX in a tight loop (each
// resize's under-lock memcpy reads exactly the head window that copyWithin is
// writing). A start gate releases both at once. The value check is retained as
// a cheap secondary signal: the head window only ever holds MARK, and a detach
// (never issued mid-run here) would read back `undefined` — so only a DEFINED
// non-MARK number is susceptibility. Run under ASAN/TSAN post-ungil.
load("../harness.js", "caller relative");

const MARK = 0x5a5a5a5a | 0;
const WORDS = 16; // Fixed head window, in bounds at the min buffer size.
const MIN_BYTES = WORDS * 4;
const MAX_BYTES = 4096;
const RESIZE_ITERS = 4000; // grow/shrink cycles; each frees the old base.

const box = { ta: null, stop: 0 };
const gate = { go: 0, started: 0 };

const hammer = new Thread(() => {
    Atomics.add(gate, "started", 1);
    while (Atomics.load(gate, "go") === 0)
        Atomics.wait(gate, "go", 0, 100);
    const ta = Atomics.load(box, "ta");
    let badValues = 0;
    while (Atomics.load(box, "stop") === 0) {
        try {
            // Bulk overlapping memmove racing the main thread's resize of
            // ta.buffer. Both overlap directions: target>start uses
            // copyBackwards, else copyForwards.
            ta.copyWithin(1, 0);
            ta.copyWithin(0, 1);
            for (let k = 0; k < WORDS; ++k) {
                const w = ta[k];
                // A detach (not issued mid-run) reads back `undefined` and is
                // legal; only a defined non-MARK word is a torn copy through a
                // stale/foreign base.
                if (w !== undefined && (w | 0) !== MARK) {
                    ++badValues;
                    break;
                }
            }
        } catch (e) {
            if (!(e instanceof TypeError))
                throw new Error("non-TypeError out of copyWithin: " + e);
        }
    }
    return badValues;
});

const canResize = typeof ArrayBuffer.prototype.resize === "function";
const ab = canResize ? new ArrayBuffer(MIN_BYTES, { maxByteLength: MAX_BYTES }) : new ArrayBuffer(MIN_BYTES);
const ta = new Int32Array(ab, 0, WORDS); // fixed-length head window
ta.fill(MARK);
Atomics.store(box, "ta", ta);

// Release the hammer, then resize the SAME buffer under it. Grow/shrink both
// preserve the head window's MARK words (grow zero-fills only above MIN_BYTES;
// shrink returns to exactly the head size), and each grow reallocates + frees
// the old base beneath the in-flight memmove.
waitUntil(() => Atomics.load(gate, "started") === 1);
Atomics.store(gate, "go", 1); // the hammer's bounded 100ms wait re-checks this
if (canResize) {
    for (let i = 0; i < RESIZE_ITERS; ++i) {
        ab.resize(MAX_BYTES); // GROW: memcpy old->fresh (reads head), frees old.
        ab.resize(MIN_BYTES); // SHRINK: memcpy old->fresh (reads head), frees old.
    }
}
Atomics.store(box, "stop", 1);
const badValues = hammer.join();
shouldBe(badValues, 0, "no word ever copied through a stale/short base (torn {base,length} pair)");
