# GC Relocation Contract

Moving collection is available through explicit `Context.compactGarbage` on a
quiescent precise-GC realm, or a `Context.requestGarbageCompaction` consumed at
the current AArch64 numeric tier's declared precise checkpoint. Published code,
tier metadata, bytecode chunks, and native-frame storage do not move; the
checkpoint has already materialized every managed local/operand in registered
roots. Running JS threads, generic/native-host checkpoints, conservative stack
scans, and in-flight concurrent/parallel collections still fail closed. C and
Objective-C embedders use `ZJSGlobalContextCreateGarbageCollected`,
`ZJSContextRequestGarbageCompaction`, and `ZJSContextCompactGarbage` for the
same scheduled/direct boundaries.

The checked-in
[`gc-relocation-inventory.json`](../.data/gc-relocation-inventory.json) covers
all nine production cell kinds and 27 pointer surfaces across runtime edges,
realm and interpreter roots, C and Objective-C handles, private ABI references,
inspector frames, threads/workers, promises/modules/timers, WebAssembly, native
stack scanning, and the existing native JIT frame. Every entry names its current
representation, source anchor, and required relocation or pinning rule.

Run the drift gate with:

```sh
zig build gc-relocation-inventory-check
```

The verifier derives the live `CellKind` enum from `src/gc.zig`, requires exact
ordered coverage and an executable rewriter for each kind, validates every
source anchor/boundary tag, and checks the fail-closed activation gates. It also
pins the current JIT compiler's object/string-constant rejection so the
quiescent allowance cannot silently outlive its pointer-free premise. The gate
is deliberately cheap enough for ordinary CI.

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
- compaction is rejected while conservative scanning is active because a
  scanned machine word does not carry a precise base/slot to rewrite.

These types do not allocate destinations, copy cells, mutate the heap, or make
raw native/JIT pointers safe. The ordered follow-ups are stop-the-world
failure-atomic movement (#334), complete root/edge rewriting (#335),
concurrent/native/JIT barriers (#336), and terminal evidence (#337).

The generic collector mechanism is now supplied by
[`zig-gc@5883b02`](https://github.com/zig-utils/zig-gc/commit/5883b02). It
reserves the complete old-to-new plan before mutation, rolls every destination
back on OOM, rewrites moved and pinned cells, and commits live storage without
running finalizers. zig-js's owned `GcCellBacking` provides a matching
unpublished reserve/release/commit trio: relocation does not inflate mutator
allocation pressure, publication swaps under one size-class lock, and live-slot
accounting stays unchanged. The engine now invokes this mechanism only through
the checked explicit stop-the-world policy; automatic and mid-script movement
remain off. Paired post-commit verification hooks retain the forwarding map
long enough to trace every current root/live cell and trap if any audited slot
still contains an old payload address.

The first engine rewrite slice is complete under
[#338](https://github.com/zig-utils/zig-js/issues/338): `Function` marking and
relocation now cover its closure, realm, home/super/wrapper objects,
`import.meta`, lexical `this`/`new.target`, shared derived-constructor `this`
cell, and captured `with` objects. Old functions are rescanned by minor GC
because `super()` can initialize the shared `this` cell after publication.

[#339](https://github.com/zig-utils/zig-js/issues/339) also completes the two
small immutable side-cell graphs: bound functions rewrite their target,
captured `this`, and every bound argument, while module namespaces rewrite each
environment pointer and preserve their arena-owned name/deferred-module
metadata.

The mutable suspension graphs follow under
[#340](https://github.com/zig-utils/zig-js/issues/340): generator marking and
relocation share environment, operand-stack, accumulator, persisted frame,
realm, `import.meta`, async-parent, and pending-request coverage; iterator
helpers rewrite all six `Value` slots. Both remain world-stopped during the
rewrite, matching their existing concurrent-mark finish deferral.

[#341](https://github.com/zig-utils/zig-js/issues/341) completes Environment
payload rewriting across binding values, disposal state, live module aliases,
realm prototype, parent scope, and `with` object. Binding names, declaration
sets, allocator/accounting fields, and arena-owned containers stay in place;
the world-stopped rewrite deliberately takes no binding lock.

Promise state follows in
[#342](https://github.com/zig-utils/zig-js/issues/342): the settled value,
wrapper, awaiting/forwarding links, inline reactions, and overflow reactions
all rewrite through the same plan. Each reaction preserves the tracer's
result-Promise versus resolve/reject branch, and the world-stopped commit takes
no Promise lock.

Object rewriting starts with the hot/property graph in
[#343](https://github.com/zig-utils/zig-js/issues/343): prototype, inline and
external named slots, dense elements, accessor payloads/descriptor cells, and
C API custom-accessor cells move while Shape and backing-container addresses
stay stable. Weak collection elements are intentionally deferred to their
ordered weak-processing slice.

[#344](https://github.com/zig-utils/zig-js/issues/344) extends Object rewriting
to actual cold/rare union storage: boxed and getter/setter Values,
constructor/proxy links, callable side cells, arguments-map Environment, and
TypedArray/DataView buffer owners. Marker snapshots are never mutated, and
native ArrayBuffer/arena metadata remains address-stable.

Internal weak ordering is covered by
[#346](https://github.com/zig-utils/zig-js/issues/346): dead finalization targets
are nulled before sweep can leave a stale address, then surviving WeakRef,
weak-collection, ephemeron, callback/held, and unregister-token slots rewrite.
The pointer-keyed weak lookup cache is cleared because its old-address hashes
are invalid; linear lookup remains correct and later mutations repopulate it.

Engine-owned native payloads gain paired mutating hooks in
[#347](https://github.com/zig-utils/zig-js/issues/347). Promise resolver state,
interpreter Promise/iterator/combinator captures, VM async-resume links, and
Thread lock/condition/TLS/release queues now rewrite their hidden roots while
host-opaque payloads remain untouched. The audit also added the previously
missing `Promise.prototype.finally` constructor edge to marking.

WebAssembly-owned roots complete the Object boundary in
[#348](https://github.com/zig-utils/zig-js/issues/348). `WasmGcRef` and instance
owners now expose paired by-value trace and by-pointer relocation callbacks;
imports, atomic globals/tables, execution roots, exceptions/wrappers, nested
externref/hostref slots, and cyclic GC aggregates all rewrite. Numeric,
funcref, i31, native-owner, and aggregate identities remain stable.

Root-registry rewriting begins in
[#349](https://github.com/zig-utils/zig-js/issues/349): every microtask variant,
module graph edge, active interpreter operand/frame/environment root, cache,
debug frame, `import.meta`, and parked Wasm execution root now has a mutating
world-stopped traversal. The same pass now covers Context globals and builtins,
rejection/finalization/timer queues, C API boxes and prototype owners, private
strong/weak handles, Thread results and join promises, GIL task jobs, property
waiters, and the host exception slot. Queue, handle, and native-record addresses
and ordering remain stable; only their managed payloads change.

[#350](https://github.com/zig-utils/zig-js/issues/350) composes those helpers
into the collector-facing root and exact nine-kind cell dispatch. Its Context
entrypoint opens a short-lived relocation token only after every fail-closed
gate passes. A protected cyclic/aliased graph is moved repeatedly with exact
live-cell/live-byte accounting, and deterministic scratch OOM proves the plan
leaves its original graph and accounting untouched. The same witness executes
pre-move Function/Environment/Promise/Generator/String representatives after
two moves. Ordinary collection stays non-moving.

[#351](https://github.com/zig-utils/zig-js/issues/351) adds that post-commit
stale-address traversal to the engine. It reuses the non-mutating marker view,
adds the weak-map/finalization-only surfaces that ordinary tracing omits, and
runs only after all backing publication and heap indexes name destinations.
The repeated-move witness also covers stable C/private handle addresses, live
and dead weak embedding roots, WeakRef/WeakMap/WeakSet/finalization behavior,
and standalone WebAssembly table/global identity. Table and global owners use
paired native-slot audit/relocate callbacks, so their atomic JS root mirrors
and the slots WebAssembly actually executes are rewritten together without
adding plain native reads to concurrent marking.

[#352](https://github.com/zig-utils/zig-js/issues/352) makes movement useful for
fragmented heaps. After sweep, each size class freezes its minimal dense leading
chunk count; cells already inside that prefix stay pinned while tail cells move
only into lower free or never-issued prefix slots. Relocation never grows cell
backing, explicit compaction returns every newly empty tail chunk, and a second
pass over the packed heap reports `no_candidates` without mutation.

[#355](https://github.com/zig-utils/zig-js/issues/355) proves the native callback
boundary is fail-closed: reentrant C compaction is rejected while its interpreter
is active. At the next quiescent host boundary, the same counted
`JSValueProtect` wrapper survives while its managed payload moves and remains
fully usable.

[#356](https://github.com/zig-utils/zig-js/issues/356) makes that C boundary
diagnostic instead of boolean: embedders receive the exact unsupported,
already-dense, planning-OOM, or compacted status plus optional exact moved-cell
and moved-byte totals. Every non-moving outcome deterministically reports zero.

[#357](https://github.com/zig-utils/zig-js/issues/357) gives Zig embedders the
same safe lifetime model through `Context.protectValue` and
`Context.unprotectValue`. A `ProtectedValue` address remains stable while its
contained `Value` is traced and rewritten; raw `Value` copies returned by
`get()` are valid only until the next compaction boundary.

[#358](https://github.com/zig-utils/zig-js/issues/358) removes the blanket JIT
flag rejection at that quiescent boundary. Its regression moves the rooted
Function/Object graph around a ready numeric tier, proves the immutable native
entry and arena-owned chunk stay stable, and enters the same tier afterward.

[#359](https://github.com/zig-utils/zig-js/issues/359) admits exactly one active
native boundary: an explicit pending request at the current AArch64 numeric
checkpoint, after its compiler island publishes canonical frame locals, spills
live operands, and records exact instruction/step state. Movement rewrites the
active registered graph, clears the request only after a supported attempt, and
resumes the same native entry. Other live native/interpreter boundaries remain
rejected.

[#360](https://github.com/zig-utils/zig-js/issues/360) exposes that scheduling
primitive to C and Objective-C hosts. A native callback may set the pending bit
but cannot move the heap reentrantly; after it unwinds, the declared native
checkpoint consumes the request. Long-lived C values still require counted
`JSValueProtect` storage across that boundary.

[#361](https://github.com/zig-utils/zig-js/issues/361) makes the no-GIL policy
deterministic: a parked spawned peer keeps a callback-scheduled request pending
across repeated movement-safe native checkpoints, with the relocation token
closed and movement count unchanged. After wake and join, the same request
compacts usefully at the quiescent host boundary and reaches a dense fixed point.

## Safepoint Rule

A raw old-space address is valid only while the relocation safepoint is held
and its forwarding record remains live. Long-lived embedding references must
use stable handle storage whose contained value is rewritten; the handle's own
address does not move. A live frame may move only at a checkpoint whose compiler
and runtime jointly declare complete materialization; the current AArch64
numeric tier is the sole admitted path. Other native frames and conservative
stack scans remain unsupported; each future tier or native boundary must add
its own precise maps, rewrite protocol, or per-cell pinning before admission.

## Focused Evidence

```sh
zig build test -Dtest-filter=compaction
zig build test -Doptimize=ReleaseSafe -Dtest-filter=compaction
zig build test -Dtsan=true -Dtest-filter=compaction
zig build gc-relocation-inventory-check c-api-audit objc-api-audit test-c-api test-objc-api
```

The native-safepoint witness first offers the request to a marking-precise but
movement-unsafe checkpoint and proves it remains pending. A warmed numeric tier
then consumes it inside its compiler-generated checkpoint island, relocates the
active Function/Object/protected graph, resumes the same immutable entry, and
returns the exact loop result.
