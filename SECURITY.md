# Security Policy

## Scope

zig-js is a JavaScript engine. Engines are a memory-safety-relevant surface, and
the interesting bug classes here are:

- **Memory safety** reachable from JavaScript — use-after-free, out-of-bounds
  access, type confusion, or a detached/resized `ArrayBuffer` observed as live.
- **Sandbox escape from JavaScript into host memory** through the interpreter,
  the bytecode VM, the native tiers, or the WebAssembly runtime.
- **Data races in engine state** that corrupt the heap under shared-realm
  `Thread`s or Workers. (A race between JavaScript programs is *not* a
  vulnerability — that is the language's memory model, and `Atomics` is the tool
  for it. See [`docs/threads/memory-model.md`](docs/threads/memory-model.md).)
- **Incorrect enforcement** of a security-relevant boundary: the inspector's
  opt-in gate, `[[CanBlock]]`, the heap budget, or termination.

Out of scope: a JavaScript program crashing itself, resource exhaustion by a
script the embedder chose to run without a step budget or heap limit, and
behavioural differences from other engines that are not memory-unsafe.

## Status

**APIs are pre-stabilization and there is no supported release line yet.**
Fixes land on `main`. Do not treat any tag as a security-supported version.

## Reporting

Report privately through GitHub's
[private vulnerability reporting](https://github.com/zig-utils/zig-js/security/advisories/new)
for this repository. Please do not open a public issue for a memory-safety bug
before it is fixed.

A useful report includes:

- a minimal JavaScript (or `.wast`) reproduction;
- **the mode it reproduces in** — this usually determines where the bug is:
  - allocator: arena (default) or `.enable_gc = true`;
  - execution path: tree-walker, bytecode VM, or with `.enable_jit = true`;
  - concurrency: single-threaded, `.enable_threads = true`, or with
    `.gil = true`;
- the build: `zig build` optimize mode, and whether it also reproduces under
  `-Doptimize=ReleaseSafe` or `-Dtsan=true`;
- the commit hash, and your Zig version.

`-Doptimize=ReleaseSafe` and `-Dtsan=true` are genuinely useful triage
information: ReleaseSafe keeps Zig's safety checks on under the optimizer and
catches codegen-dependent faults that Debug hides, and TSan distinguishes an
engine-state race from a functional bug.

## What to expect

We aim to acknowledge a report within a few days. Because there is no release
line, remediation is a fix on `main` plus, where the bug is reachable from a
plausible embedding, a note in the advisory about which configurations were
affected. Credit is given unless you ask otherwise.
