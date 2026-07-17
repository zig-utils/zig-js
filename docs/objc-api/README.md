# Objective-C JavaScriptCore Bridge

zig-js targets the Objective-C JavaScriptCore headers shipped by macOS SDK
27.0 build 26A5368g. The checked-in
[`jsc-objc-api-macos-27.0.json`](jsc-objc-api-macos-27.0.json) inventory records
the SHA-256 of `JSContext.h`, `JSValue.h`, `JSVirtualMachine.h`,
`JSManagedValue.h`, and `JSExport.h`, plus every interface, category, protocol,
method, property, typedef, data symbol, macro, signature, and availability
annotation parsed from those headers.

The inventory contains 11 containers and 108 declarations. It currently records
**79 implemented / 29 pending** under issues #158–#160. An `implemented` entry
has runtime behavior exercised by the compile-link-runtime host; a `pending`
entry may be declared in the headers but must not be treated as usable.

Run the checked-in drift gate on every host:

```sh
zig build objc-api-audit
```

On macOS, compile the headers with the real Objective-C ARC/blocks frontend:

```sh
zig build test-objc-api-headers
```

Compile, link, and execute the implemented runtime slice on macOS:

```sh
zig build test-objc-api
```

Compare the completed Foundation conversion rows with system JavaScriptCore:

```sh
zig build objc-api-jsc-diff
```

That host exercises VM/context construction and identity, evaluation and
exception capture, context naming/inspectability, C-ref round trips, primitive
and native object `JSValue` factories, every published type predicate,
exception-aware numeric/string conversion, and exact comparisons.
Indexed reads, geometry structs, and the property-descriptor constants are also
covered. Recursive array/dictionary/date conversion matches all six rows in the
pinned system-JSC transcript and handles cyclic graphs by strict JavaScript
identity. Promise executors preserve nested callback state and match system JSC's
context/callee/this/two-argument contract. Arbitrary Objective-C wrappers,
general exported callbacks, general property helpers, and JSExport remain
pending until their corresponding runtime and evidence land. Opaque
Objective-C objects preserve bidirectional identity, JS object wrappers are
canonical by strict identity, and all 8 differential rows match system JSC
(`bc1860c0e6e8d919`). `JSManagedValue` and VM owner relations are implemented with
real weak targets plus weak owners; because current context groups use the
VM-lifetime arena policy, unreachable targets remain available until VM teardown
rather than being reclaimed mid-VM.

Compare the pin against an installed SDK explicitly:

```sh
python3 tools/verify-objc-api.py \
  --sdk-root "$(xcrun --sdk macosx --show-sdk-path)"
```

The live comparison fails on any source hash, container, selector, property,
signature, availability, typedef, data-symbol, or macro drift. A different SDK
revision must receive a separately named inventory instead of silently changing
the compatibility target.

The copied Objective-C declarations are exposed only when Clang targets the
Apple Objective-C runtime. C, C++, Zig, and non-Apple consumers continue to use
the public C headers without importing or linking Foundation.

Runtime implementation and evidence are split into:

- #158 — `JSContext`, `JSVirtualMachine`, and `JSValue` behavior;
- #159 — managed references, wrapper identity, and lifetime semantics;
- #160 — `JSExport`, Objective-C blocks, conversions, and completion evidence.
