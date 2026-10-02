# Array join active-receiver memory — 2026-10-02

Issue [#1023](https://github.com/zig-utils/zig-js/issues/1023) replaces the realm-arena `Array.prototype.join` / `toLocaleString` cycle detector with an eight-receiver inline owner and freeable fallback storage. This report contains deterministic memory counters only; it makes no timing claim.

The old owner was 32 bytes plus an `ArrayList` allocation. A shallow join retained capacity 9 (176 logical bytes including the owner), while a depth-40 join raised retained capacity to 44 (736 logical bytes). Cycle and throwing unwinds returned the list length to zero but retained that capacity until realm teardown, and a temporary `Interpreter.deinit` could not reclaim either arena allocation.

The new owner is 208 bytes, including eight inline 16-byte relocation-stable identities. It is allocated from the Context's freeable scratch allocator and destroyed at interpreter teardown. Fallback capacity appears only beyond eight simultaneous receivers. One-off deep capacity is released; a second comparable depth establishes a reusable working set, a third call reuses it without growth, and a later shallow call releases it.

| Production-path stage | Current owners | Peak receivers | Current fallback | Peak fallback | Current bytes | Peak bytes | Growths total | Releases total | Released bytes total |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| shallow | 0 | 1 | 0 | 0 | 0 | 208 | 0 | 0 | 0 |
| one-off depth 40 | 0 | 41 | 0 | 44 | 0 | 912 | 3 | 1 | 704 |
| three depth-40 calls, then shallow | 0 | 41 | 0 | 44 | 0 | 912 | 9 | 3 | 2,112 |
| cycle | 0 | 41 | 0 | 44 | 0 | 912 | 9 | 3 | 2,112 |
| throw, unwind, retry | 0 | 41 | 0 | 44 | 0 | 912 | 9 | 3 | 2,112 |

Counters are cumulative within one profiled Context. The repeated-depth stage contributes six growth events and two releases: the first deep call grows then releases, the second grows and retains, the third reuses without growth, and the final shallow call releases. Cycle detection and throw recovery add no fallback growth or retention.

Verification used real zig-gc revision `0285ef801dd221a4ae8e88b31a09ae31627657a3`: exhaustive allocation failures, teardown inventory, moving GC through proxy cycles in both tree and required-VM modes, shared no-GIL execution, and the same witness under unsuppressed TSan all passed. The affected test262 subtrees remained 23/23 (`join`) and 12/12 (`toLocaleString`), with 35/35 exact tree/required-VM agreement and no failure-set change from commit `2723311b`.

Machine-readable counters: [`array-join-active-receiver-memory-2026-10-02.json`](array-join-active-receiver-memory-2026-10-02.json).
