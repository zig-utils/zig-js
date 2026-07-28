---
title: Language
description: The ECMAScript syntax and semantics zig-js implements — declarations, functions, classes, generators, async, modules, and explicit resource management.
---

# Language

The parser is a hand-written recursive-descent + precedence-climbing parser
([`src/parser.zig`](https://github.com/zig-utils/zig-js/blob/main/src/parser.zig))
over a single-pass lexer. Semantics live in the tree-walking evaluator
([`src/interpreter.zig`](https://github.com/zig-utils/zig-js/blob/main/src/interpreter.zig)),
with a bytecode VM for the constructs that need suspend/resume — see
[Execution tiers](/advanced/execution-tiers).

Both **strict mode** and sloppy mode are implemented, including the Annex B
web-compatibility semantics that the corpus scores.

## Declarations and bindings

- `var`, `let`, `const`, with a real Temporal Dead Zone.
- Block, function, module, `catch`, and per-iteration scoping. `for (let …)`
  heads create a fresh binding per iteration so body closures capture correctly.
- Destructuring in declarations, assignments, and parameters — array and object
  patterns, defaults, nested patterns, rest elements, and object rest to a
  member target (which runs the setter).
- Global `var`/`function` bindings live both in the environment and as own
  properties of the global object; global lexical bindings live only in the
  environment. Redeclaration conflicts are reported as early errors.

## Operators

The full operator set: arithmetic including `**`, bitwise and shifts, logical,
nullish coalescing `??`, optional chaining `?.`, logical assignment
(`&&=`, `||=`, `??=`), comma, `typeof` / `void` / `delete`, `in`, `instanceof`
(honouring `Symbol.hasInstance`), and `new.target`.

Coercion follows the specified evaluation order — `ToNumeric` of the left
operand fully, including its `Symbol` rejection, before the right. String
relational comparison is by **UTF-16 code unit**, and BigInt comparison against
Number/String is exact rather than float-approximated.

## Functions

- Function declarations and expressions, arrow functions, concise methods,
  getters and setters, and computed keys.
- Default, rest, and destructured parameters. A parameter list containing a
  default gets its own scope, distinct from the body's variable environment.
- `arguments` — mapped for simple sloppy parameter lists, unmapped otherwise,
  with `length` behaving as an ordinary configurable data property.
- Closures, `this` binding, `new`, `super`, and the `%ThrowTypeError%` poison
  pill on strict `caller`/`arguments`.
- **Proper tail calls** in strict code, via the VM's heap-allocated activation
  stack — recursion depth is bounded by the logical call-depth cap, not the
  native OS stack.

## Classes

- `class` declarations and expressions, inheritance, `super` in constructors,
  methods, and property accesses.
- Instance and static **public fields** (created with
  `CreateDataPropertyOrThrow`, not `[[Set]]`), **private fields, methods, and
  accessors**, `#x in obj` brand checks, and `static {}` initializer blocks.
- The class name is bound inside its own body as a `const`, in TDZ during
  heritage evaluation.
- Field initializers and static blocks are `[[Call]]`ed, so `new.target` is
  `undefined` inside them — including inside a direct `eval`, and lexically for
  an arrow defined there.
- Each evaluation of a class produces **distinct private names**, so two
  instances from two evaluations do not share brands.
- `accessor x` auto-accessor fields parse. Decorator lists parse and are
  **discarded** — decorator application is not implemented.

## Generators, async, and iteration

- Generators, async functions, async generators, and `for await…of`.
- `yield`, `yield*`, `await`, and top-level `await` in modules.
- Iterators close on abrupt completion — a throwing destructuring target or body
  runs the iterator's `return`.
- **Iterator helpers** on `Iterator.prototype`: `map`, `filter`, `take`, `drop`,
  `flatMap`, `reduce`, `toArray`, `forEach`, `some`, `every`, `find`, plus
  `Iterator.from`, sequencing (`concat`, `zip`, `zipKeyed`), and
  `Symbol.dispose`. `AsyncIterator` is present as the async counterpart.

These constructs always compile to the bytecode VM, because suspend/resume
cannot be expressed by the tree-walker.

## Control flow and errors

`if`/`else`, `while`, `do…while`, `for`, `for…in`, `for…of`, `for await…of`,
`switch` (with its own lexical scope), labelled statements, `break`/`continue`,
`try`/`catch`/`finally` with optional catch binding, `throw`, and `with`.

`finally` semantics are exact: a pending `break`/`continue`/`return`/throw from
the `try` is held aside while the `finally` block runs clean, and the block's own
abrupt completion overrides it.

The `Error` family is `Error`, `TypeError`, `RangeError`, `ReferenceError`,
`SyntaxError`, `EvalError`, `URIError`, `AggregateError`, `SuppressedError`, and
`OutOfMemoryError`.

## Explicit resource management

`using x = res;` and `await using x = res;` are implemented, with
`DisposeResources` running at the end of blocks, `switch` bodies, `for`
statements, `for…of` iterations, and generator / async function / async
generator bodies — on both normal and abrupt completion. Initializer validation
(a resource whose `Symbol.dispose` / `Symbol.asyncDispose` is not callable)
throws at registration.

## Modules

- `import` / `export` declarations, namespace imports, and re-exports.
- **Dynamic `import()`**, including its rejection paths, plus the `import.defer`
  and `import.source` phase forms.
- `import.meta`.
- Top-level `await`, with module-graph and async-module evaluation ordering
  scored by the corpus.

The engine does not resolve module specifiers itself.
`Context.evaluateModule(entry_path, entry_source, host)` takes a host hook so the
embedder owns resolution and loading — see [Embedding](/advanced/embedding).

## `eval` and realms

Direct and indirect `eval` are implemented with the correct variable
environments: a sloppy direct `eval`'s function-level `var` and function
declarations create **deletable** bindings, a direct `eval` in a parameter
default may not var-declare a parameter name, and a direct `eval` in a class
field initializer inherits that context's restrictions lexically.

`$262.createRealm()` is available to the conformance harness; well-known symbols
are shared across realms so symbol identity holds.

## Regular expressions

`RegExp` is backed by the sibling [`zig-regex`](https://github.com/zig-utils/zig-regex)
package compiled with an `ecmascript` flag, so ECMAScript-only rules are
enforced (no standalone `(?ims)` modifiers, no quantified lookbehind, named
backreference resolution). `RegExp.escape` is available.

## Where the paths differ

Nearly all code runs on the tree-walking evaluator. The bytecode VM runs
generators, async functions, async generators, and the narrow set of plain
functions that benefit from it. Because the corpus exercises the VM far less
than the tree-walker, **VM/tree-walker divergence is a known bug surface**; see
[Execution tiers](/advanced/execution-tiers) for the tiering rules and how
divergence is hunted.
