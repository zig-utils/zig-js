# Replacing JSC/WebKit in Home with zig-js

> Status: **public profile verified; private migration not started**
> (2026-07-17). Home currently links vendored JavaScriptCore. zig-js now proves
> the exact 50-function public M1 consumer at Home revision `7ed99c02`, while
> private profiles explicitly support `7ed99c02` and the byte-identical JSC
> source aliases `5e829ad4` and `38702f9e`. The broader private runtime remains
> separate work.

## Why this is not a link-swap

Home (`~/Code/Home/lang`) is the Bun-parity runtime. Its production runtime is
coupled to JSC **internals** through Bun's C++ binding layer. A prior built-binary
inventory measured:

| Surface | Symbols Home references |
|---|---:|
| JSC LowLevelInterpreter (`_jsc_llint_*`) — the bytecode engine | thousands |
| `Bun__*` / `JSC__*` binding entry points (C++) | **804 distinct** |
| Generated-class C++ bindings (`*Prototype__*`, `*Class__*`, `__construct`, `__finalize`) | **~4,325** |
| Public JSC C API references in that binary | **~17** |

Separately, Home revision `7ed99c02e50034f869d0db6d487115bb44332fe4`
contains a newer public-C M1 pathway with 50 Zig `extern "c"` declarations.
zig-js exports all 50 and runs its pinned compile-link-runtime fixture. The
[machine-readable profile](abi/home-public-c-7ed99c02.json) records exact source
hashes, calling convention, layouts, enum values, and semantic assumptions;
`zig build test-home-public-abi -Dhome-source-root="$HOME/Code/Home/lang"`
checks the live checkout too.

zig-js's complete public target is now 117 functions plus 19 extensions.
Nevertheless, **zig-js is not yet a drop-in for the JSC that Home's production
runtime links**: success of the 50-function public profile says nothing about
the thousands of LLInt and private/generated binding symbols above.

The first source-level private inventory is now reproducible too. At the same
pinned Home revision, the 58 JSC source files containing legacy/private
`extern fn` declarations require 448 unique symbols: 432 private JSC/Bun/WebCore
entries, 15 public-C overlaps already implemented by zig-js, and one platform
libc import. See [the exact declaration inventory](abi/home-private-7ed99c02-inventory.json)
and run `zig build home-private-abi-audit -Dhome-source-root="$HOME/Code/Home/lang"`
to verify the live revision, every source hash, signature, classification, and
calling convention. This replaces a vague source-level estimate, but the 432
private entries are now 59 implemented / 373 pending under #163. The implemented
slices cover JSC64 value identity, cell equality, truthiness, int32 extraction,
exact signed/unsigned 64-bit BigInt construction, and modulo-2^64 BigInt
extraction with the pinned number fallbacks, plus exact strict and SameValue
equality for primitives and context-owned cells. Five opaque BigInt cell shims
add exact arbitrary-size ordering against i64/u64/f64 plus signed modulo-2^64
extraction. Seven JSCell/JSString shims add exact UTF-16 and 8-bit string
semantics, value equality, object identity, and primitive boxing. The two
ordinary-object constructors and wrapper-unboxing shim add exact prototype,
freshness, int32/double, negative-zero, NaN, and primitive-value behavior. Three
value-level BigInt shims add four-way BigInt/Number comparison,
arbitrary-precision addition, and the exact pinned `sec * 1_000_000 + nsec`
timeval formula. The two
cell-type shims use
Home's exact 97-member JSType layout by default; Bun's distinct 98-member layout
requires `-Dprivate-abi-consumer=bun`. Two ToObject/prototype shims preserve
ordinary-object identity, box all five object-capable primitive kinds in the
selected realm, observe proxy/null prototypes, and reject nullish or foreign
values. Two numeric DateInstance shims create fresh selected-realm
Date cells without TimeClip and preserve/read raw fractional, signed-zero, NaN,
infinite, and out-of-range internal doubles. Four more Date shims parse complete
NUL-terminated strings, extract same-VM UTC epoch milliseconds, and write exact
ordinary/extended UTC ISO text failure-atomically; the Date-now writer shares
the real Unix wall clock used by JavaScript Date construction. Nine VM exception
shims add shared pending state
across sibling realms, stable exception-cell identity, primitive/Error
preservation, and exact has/clear/take/rethrow classification. Five array/index
shims add exact logical lengths and holes, direct put/push/read behavior that
bypasses inherited setters, observable prototype/getter reads with VM exception
publication, sparse growth, and the maximum-u32 boundary. Two JSArray
constructor shims add failure-atomic packed construction, selected-realm
prototypes, same-VM sibling value identity, and hole-only construction through
maximum u32 length. The ToNumber shim adds primitive and full object coercion,
spec-ordered user hooks, Symbol/BigInt TypeError behavior, ordinary-versus-
exceptional NaN distinction, same-VM sibling values, and first-exception
preservation. Two predicates add JSC-exact internal has-instance prechecks and
object-only iterator GetMethod behavior, including custom/proxy hooks, getter
execution, callability validation, and VM exception publication. Private
string inclusion adds ordered full ToString coercion and exact UTF-16
code-unit matching across astral and surrogate boundaries. Class and
AggregateError classification now follows executable/native and immutable error
metadata, while sibling C-API realms share VM well-known Symbols and the Symbol
registry. These slices do not
yet create a usable Home private runtime.

The newer Home revisions `5e829ad4` and `38702f9e` changed no files in
`packages/runtime/src/jsc` relative to `7ed99c02`. Their separate alias
manifests still verify every source hash and declaration and report zero added,
removed, signature-changed, or calling-convention-changed entries. This keeps
all three exact revisions supported without weakening revision rejection.

## Two migration paths

**Path A — rewrite Home's runtime onto zig-js's public C API.** (Recommended.)
Replace Home's ~804 `Bun__*`/`JSC__*` call sites and its generated-class layer
with calls to zig-js's public API (`JSObjectMake`, `JSObjectSetProperty`,
`JSObjectMakeFunctionWithCallback`, class definitions, etc.). Large but
well-bounded, keeps zig-js clean (a public-API engine), and decouples Home from
Bun's internal ABI. zig-js gains a focused set of new public-API features
(below).

**Path B — make zig-js export Bun's internal ABI.** zig-js would implement the
804 `Bun__*`/`JSC__*` entry points, the generated-class C ABI, and Bun's exact
`JSValue`/`JSCell`/`Structure` encodings. This couples zig-js permanently to
Bun's internal design and is far more surface area. Not recommended.

The rest of this doc assumes **Path A**.

## zig-js capability gaps to close for Path A

zig-js already has (verified in `src/c_api.zig`): context lifecycle, evaluate,
value predicates/conversions, `JSObjectMake`, property get/set/index,
call/construct, `JSObjectMakeFunctionWithCallback` (host functions),
`JSObjectMakeDeferredPromise`, `JSValueProtect`/`JSValueUnprotect`, string
create/get, the public TypedArray/ArrayBuffer construction and borrowed-bytes
surface (including no-copy lifetime callbacks), and the `JSWorker*` extension.

Missing primitives Home depends on heavily (each blocks a large class of corpus
tests):

1. **Complete custom native classes** — class ownership, inheritance,
   initialize/finalize, class identity, shared prototypes, and static functions
   plus static-value get/set/has/delete, descriptor, and key-enumeration dispatch
   are implemented. Every dynamic callback family, including property names,
   calls, construction, `hasInstance`, and conversion, is implemented, including
   deterministic rejection of foreign-context and invalid callback returns. Home defines ~100+
   JS-exposed classes (Subprocess, Glob, Server, Crypto hashers, FSWatcher,
   Stats, …) via the generated-class machinery; this public C-API layer is now
   available, while Home's private generated-class ABI remains separate work.
2. **Exception model** — set/get/clear a pending exception on the context;
   `JSObjectMakeError` plus distinct `TypeError`/`RangeError`/`SyntaxError`
   construction; the `JSValueRef* exception` out-parameter convention on every
   call/get/set. Home's invariant: a host call returns the empty value **iff**
   an exception is pending (see Home's `host_fn.zig` / `assertExceptionPresenceMatches`).
3. **Inspector integration** — the complete public C inventory, inspectability
   toggles, versioned in-process protocol transport, C/C++ hosts, the JSC
   differential gate, and real shared-VM context groups are in place. Runtime
   evaluation, statement pause/resume, resolved breakpoints, logical-depth
   stepping, exception policy, and suspendable-function checkpoints are usable
   today. Paused events also expose live call frames and lexical/global scope
   chains plus live evaluate-on-frame and GC-rooted, session-owned remote-object
   inspection. Concurrent sessions use deterministic pause ownership with
   observer-first snapshots and callback-safe deferred teardown. Independent
   JSWorker runtimes remain live rather than being falsely claimed as child
   targets; explicit cross-thread target transport is tracked in #156 before
   Home debugger integration is complete.
4. **Prototype & structure control** — `JSObjectGetPrototype`/`SetPrototype`
   and richer private/internal slot modeling. `JSObjectGetPrivate` /
   `JSObjectSetPrivate` now cover host-owned opaque pointers, but Home also
   stashes cached JS values on wrappers.
5. **GC reachability hooks** — an equivalent of JSC's "is this wrapper still
   reachable" output constraint so a native object with pending activity is not
   collected (Home uses Strong/Weak `JSRef` upgrade today; some classes need the
   `hasPendingActivity` callback path — see Home's subprocess finalize assert).
6. **Microtask / event-loop integration** — Home drives its own event loop
   (`io/posix_event_loop.zig`); zig-js must let the host pump the microtask queue
   (drain-on-demand) and integrate promise jobs with Home's loop rather than
   owning the loop.
7. **String interop** — efficient UTF-8/UTF-16 `bun.String`/`ZigString` ↔ engine
   string bridging without a full copy where possible.

## Suggested phased plan

1. **Spike:** stand up a `home_rt` build flag that links zig-js instead of JSC
   for a *minimal* path — `home eval "1+2"` and `home eval "console.log(...)"`
   only. Proves context + evaluate + a couple of host functions
   (`console.log`). Nothing else wired.
2. **Class system:** implement `JSClassDefinition` in zig-js; port ONE Home
   generated class (e.g. `Glob`, which is small) onto it end-to-end, including
   finalize + a static method. Establishes the pattern + codegen target.
3. **Exceptions + C ABI hardening:** close gaps (2) and (3); port `Buffer` and
   the node validators (they throw a lot — exercises the exception invariant).
4. **Event loop + promises:** wire (6); port `Bun.spawn` / timers.
5. **Bulk class migration:** regenerate Home's class layer against the new
   zig-js class API (Home's classes are codegen-driven, so most of the ~4,325
   symbols collapse into one generator change).
6. **Cutover gate:** Home's full-VM corpus (`HOME_CORPUS_FULL_VM`, see Home's
   `scripts/vm-corpus-scan.sh`) must be **no worse** on zig-js than on JSC before
   flipping the default.

## Measuring

- zig-js standalone: configured `tc39/test262` runner score. Keep this sourced
  from `docs/.data/test262.json` rather than hard-coding stale counts.
- Home integration: the full-VM corpus pass/fail/crash/hang counts from
  `~/Code/Home/lang/scripts/vm-corpus-scan.sh`, compared JSC-vs-zig-js per
  subsystem. Cut over only at parity-or-better.

## Note on current corpus crashes (context)

The crashes being fixed in Home today (the node `ERR().throw()` empty-value
segfault, `PollOrFd` use-after-free, `Bun.serve` returning an empty JSValue,
the Glob stubs) are **Home-side Zig bugs feeding invalid values to the engine**
— they are engine-agnostic and would occur on zig-js too. None required WebKit
source. So Home-side corpus parity work is *not blocked* on this migration and
should proceed in parallel; this migration is the longer-horizon engine track.
