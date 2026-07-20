# GC Relocation Contract

Moving collection is not enabled. Issue
[#333](https://github.com/zig-utils/zig-js/issues/333) first makes the pointer
contract auditable so a later compactor cannot rely on an accidental stable
address.

The checked-in
[`gc-relocation-inventory.json`](../.data/gc-relocation-inventory.json) covers
all nine production cell kinds and 26 pointer surfaces across runtime edges,
realm and interpreter roots, C and Objective-C handles, private ABI references,
inspector frames, threads/workers, promises/modules/timers, WebAssembly, native
stack scanning, and the existing native JIT frame. Every entry names its current
representation, source anchor, and required relocation or pinning rule.

Run the drift gate with:

```sh
zig build gc-relocation-inventory-check
```

The verifier derives the live `CellKind` enum from `src/gc.zig`, requires exact
ordered coverage, validates every source anchor and boundary tag, and rejects
any claim that movement is already active. It is deliberately cheap enough for
ordinary CI.

## Code Contract

[`src/gc_relocation.zig`](../../src/gc_relocation.zig) defines the operations
later phases must use:

- a `StableCellId` represents logical identity independently of payload address;
- a `ForwardingRecord` retains the stable ID, kind, old/new payloads, and
  planning/copy/rewrite state;
- required and optional strong edges must resolve to a destination;
- weak and atomic-weak edges may clear when no live destination exists;
- atomic strong and tagged-`Value` slots use compare/exchange rewriting;
- interior projections preserve a proven byte offset from a relocated base;
- unmanaged static, arena, and interned strings remain unchanged;
- conservatively discovered cells are pinned because a scanned machine word
  does not carry a precise base/slot to rewrite.

These types do not allocate destinations, copy cells, mutate the heap, or make
raw native/JIT pointers safe. The ordered follow-ups are stop-the-world
failure-atomic movement (#334), complete root/edge rewriting (#335),
concurrent/native/JIT barriers (#336), and terminal evidence (#337).

The generic collector mechanism is now supplied by
[`zig-gc@e6ea569`](https://github.com/zig-utils/zig-gc/commit/e6ea569). It
reserves the complete old-to-new plan before mutation, rolls every destination
back on OOM, rewrites moved and pinned cells, and commits live storage without
running finalizers. zig-js's owned `GcCellBacking` provides a matching
unpublished reserve/release/commit trio: relocation does not inflate mutator
allocation pressure, publication swaps under one size-class lock, and live-slot
accounting stays unchanged. Production movement remains off until #334/#335
finish the engine cell policy and complete root/edge rewrite implementation.

The first engine rewrite slice is complete under
[#338](https://github.com/zig-utils/zig-js/issues/338): `Function` marking and
relocation now cover its closure, realm, home/super/wrapper objects,
`import.meta`, lexical `this`/`new.target`, shared derived-constructor `this`
cell, and captured `with` objects. Old functions are rescanned by minor GC
because `super()` can initialize the shared `this` cell after publication.
Movement is still disabled until every cell kind and root surface has the same
complete treatment.

## Safepoint Rule

A raw old-space address is valid only while the relocation safepoint is held
and its forwarding record remains live. Long-lived embedding references must
use stable handle storage whose contained value is rewritten; the handle's own
address does not move. Native frames without precise pointer stack maps and any
cell reached only by conservative stack scanning remain pinned until #336.
