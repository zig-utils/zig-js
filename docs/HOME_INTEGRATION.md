# Replacing JSC/WebKit in Home with zig-js

> Status: **scoping doc** (2026-06-10). Home currently links vendored
> JavaScriptCore; this describes what zig-js must provide before it can replace
> JSC/WebKit as Home's JS engine. No migration has started.

## Why this is not a link-swap

Home (`~/Code/Home/lang`) is the Bun-parity runtime. Its `home` binary does
**not** consume the JSC *public embedding* C API — it is coupled to JSC
**internals** through Bun's C++ binding layer. Measured from the built binary:

| Surface | Symbols Home references |
|---|---:|
| JSC LowLevelInterpreter (`_jsc_llint_*`) — the bytecode engine | thousands |
| `Bun__*` / `JSC__*` binding entry points (C++) | **804 distinct** |
| Generated-class C++ bindings (`*Prototype__*`, `*Class__*`, `__construct`, `__finalize`) | **~4,325** |
| **Public JSC C API** (what zig-js exposes today) | **only ~17** |

zig-js's `src/c_api.zig` exports ~44 *public* JSC C-API functions
(`JSGlobalContextCreate`, `JSEvaluateScript`, `JSObjectMake`,
`JSObjectMakeFunctionWithCallback`, `JSValueMakeNumber`, …). The overlap with
what Home actually links is ~17 symbols. **zig-js is therefore not a drop-in for
the JSC that Home links** — the two surfaces barely intersect.

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
`JSObjectMakeDeferredPromise`, `JSValueProtect/Unprotect`, string create/get.

Missing primitives Home depends on heavily (each blocks a large class of corpus
tests):

1. **Custom native classes** — `JSClassCreate` / `JSClassDefinition` (static
   functions, static value accessors with getter/setter, `finalize`,
   `hasInstance`, `callAsConstructor`, parent class). Home defines ~100+
   JS-exposed classes (Subprocess, Glob, Server, Crypto hashers, FSWatcher,
   Stats, …) via the generated-class machinery. This is the single biggest gap.
2. **Exception model** — set/get/clear a pending exception on the context;
   `JSObjectMakeError` plus distinct `TypeError`/`RangeError`/`SyntaxError`
   construction; the `JSValueRef* exception` out-parameter convention on every
   call/get/set. Home's invariant: a host call returns the empty value **iff**
   an exception is pending (see Home's `host_fn.zig` / `assertExceptionPresenceMatches`).
3. **TypedArray / ArrayBuffer** — `JSObjectMakeTypedArray`,
   `JSObjectMakeArrayBufferWithBytesNoCopy`, byte-length/bytes accessors,
   `JSValueGetTypedArrayType`. Needed for `Buffer`, fetch/stream bodies, crypto.
4. **Prototype & structure control** — `JSObjectGetPrototype`/`SetPrototype`,
   private/internal slots (Home stashes native pointers + cached JS values on
   wrappers), and `JSObjectGetPrivate`/`SetPrivate` equivalents.
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
3. **Exceptions + TypedArray:** close gaps (2) and (3); port `Buffer` and the
   node validators (they throw a lot — exercises the exception invariant).
4. **Event loop + promises:** wire (6); port `Bun.spawn` / timers.
5. **Bulk class migration:** regenerate Home's class layer against the new
   zig-js class API (Home's classes are codegen-driven, so most of the ~4,325
   symbols collapse into one generator change).
6. **Cutover gate:** Home's full-VM corpus (`HOME_CORPUS_FULL_VM`, see Home's
   `scripts/vm-corpus-scan.sh`) must be **no worse** on zig-js than on JSC before
   flipping the default.

## Measuring

- zig-js standalone: `tc39/test262` score (today **42,577 / 47,930 = 88.8%**).
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
