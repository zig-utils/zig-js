# Objective-C JavaScriptCore Bridge

zig-js targets the Objective-C JavaScriptCore headers shipped by macOS SDK
27.0 build 26A5368g. The checked-in
[`jsc-objc-api-macos-27.0.json`](jsc-objc-api-macos-27.0.json) inventory records
the SHA-256 of `JSContext.h`, `JSValue.h`, `JSVirtualMachine.h`,
`JSManagedValue.h`, and `JSExport.h`, plus every interface, category, protocol,
method, property, typedef, data symbol, macro, signature, and availability
annotation parsed from those headers.

The inventory contains 11 containers and 108 declarations. It currently records
**32 implemented / 76 pending** under issues #158–#160. An `implemented` entry
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

That host exercises VM/context construction and identity, evaluation and
exception capture, context naming/inspectability, C-ref round trips, primitive
`JSValue` factories, every published type predicate, and boolean/string
conversion. Collection/object conversion, callbacks, property helpers, managed
references, and JSExport remain pending until their corresponding runtime and
evidence land.

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
