# Contributing to zig-js

Thanks for looking at this. zig-js is a JavaScript engine written from scratch in
Zig — a big codebase with an unusually strict evidence culture. This guide tells
you where things are, how to build and test them, what CI will ask of you, and
how changes land.

If you are a coding agent, read [`CLAUDE.md`](CLAUDE.md) (symlinked as
`AGENTS.md`) as well — it carries the same rules plus the specific traps that
have cost real time here.

---

## 1. Setup

### Toolchain

| Requirement | Notes |
| --- | --- |
| **Zig `0.17.0-dev`**, at least `0.17.0-dev.956` | Zig 0.16 will **not** build this tree. CI resolves the current `0.17.0-dev` master through pantry's action. |
| **`python3`** | Runs the `tools/*.py` gates, audits, and generators. |
| **`bun`** | Builds the documentation site. |
| macOS + Xcode CLT | Only for the Objective-C bridge, the JSC differential targets, and the JSC benchmark comparison. |

### Sibling packages (the most common first-time failure)

`build.zig.zon` resolves two dependencies **by local path**. Check them out next
to your `zig-js` directory:

```
parent/
├── zig-js/
├── zig-regex/     # github.com/zig-utils/zig-regex
└── zig-gc/        # github.com/zig-utils/zig-gc
```

Without both, dependency resolution fails before anything compiles. If you work
in a git worktree, create the two symlinks there yourself.

### Corpora

```bash
git submodule update --init test262        # tc39/test262
git submodule update --init wasm-spec-wg1  # WebAssembly wg-1.0
git submodule update --init wasm-spec-wg3  # WebAssembly Core 3
```

> A missing corpus is **skipped cleanly, not failed**. A run can therefore score
> zero, exit 0, and look like a pass. Always sanity-check the denominator.

### First build

```bash
zig build          # libzig-js.a + headers into zig-out/
zig build --help   # the full step list — there are well over a hundred
```

---

## 2. Where things are

```
src/                 the engine
  lexer.zig parser.zig ast.zig      source -> AST
  interpreter.zig                   tree-walking evaluator — the semantic baseline
  compiler.zig bytecode.zig vm.zig  AST -> bytecode -> stack VM
  jit.zig jit/                      baseline native tier + optimizing tier (AArch64)
  value.zig shape.zig               NaN-boxed values, hidden classes
  context.zig                       the engine instance: allocators, globals, options
  builtins.zig promise.zig          built-ins and the microtask queue
  gc*.zig stack_scan.zig root_handshake.zig   precise / parallel GC
  gil.zig jsthread.zig worker.zig agent.zig   threading
  wasm/                             decode, validate, exec, simd, atomic, gc, JS API
  c_api.zig private_abi*            embedding ABIs
  *_data.zig cldr_*.zig unicode_*.zig  GENERATED tables — edit the generator, not these

conformance/         test262, PR-249 thread corpus, and Wasm spec runners
tests/               C / C++ / Objective-C embedding fixtures
bench/               benchmark workloads and runners
tools/               gates, audits, generators, profilers
docs/                the published site
docs/.data/          machine-readable evidence: inventories, samples, matrices
.github/workflows/   CI — the authoritative gate list
```

`build.zig` is the real index of what the project can do. When you are not sure a
capability exists, `grep -n 'b.step(' build.zig`.

### The execution model, briefly

The **tree-walking interpreter is the semantic baseline** and runs nearly all
code. The bytecode VM exists for *capability* — suspend/resume for generators and
async, plus a heap activation stack for deep recursion and proper tail calls —
not for general speed. Above those sit a baseline native tier and an optimizing
tier, both of which always retain an exact interpreter fallback.

**The practical consequence: a semantics fix in `interpreter.zig` frequently needs
a mirrored fix in `vm.zig`.** test262 exercises the VM far less than the
tree-walker, so a VM-only divergence can hide behind a completely green corpus
run. See [`docs/advanced/execution-tiers.md`](docs/advanced/execution-tiers.md).

---

## 3. Running the tests

### Unit suite

```bash
zig build test-parallel                  # ALWAYS use this for a full local run
zig build test-parallel -Dunit-jobs=8    # pick the shard count (no relink cost)
zig build test -Dtest-filter=<substr>    # focused run
zig build test -Dtsan=true               # ThreadSanitizer
```

`zig build test` is single-threaded per process; unsharded it uses one core and
takes hours. `test-parallel` builds the binary once and runs N shards against it,
with per-shard logs in `.zig-cache/unit-shards/`. Reference point: ~1,430 tests
in ~170 s across 10 shards.

Any edit under `src/` relinks the test artifact — budget ~4–6 minutes. Filters
are compile-time, so a filtered probe still relinks (~8–10 minutes per cycle).
Prefer one instrumentation pass that answers several questions.

### Conformance (test262)

```bash
zig build conformance                        # fast local smoke suite, not a CI gate
zig build test262 -Doptimize=ReleaseFast     # the real corpus; cold build ~25-30 min
zig build test262-bin                        # build the runner only
zig-out/bin/test262 --diag test/language     # per-failure cluster report
zig-out/bin/test262 --eval /tmp/probe.js     # OK <value> / ERR <name: msg>
```

`--diag` has no per-test timeout; a full `test/language` pass takes minutes. The
full-suite summary goes to **stderr** — capture with `> run.txt 2>&1`.

### Threads

```bash
zig build threads-test                                    # PR-249 corpus, serialized
zig build threads-test -Dthreads-case=<relpath>           # one case
zig build threads-test -Dthreads-parallel-js=true -Dthreads-case=<relpath>
zig build threads-reference-audit threads-reference-probes
zig build threadfuzz -Dfuzz-iters=400
python3 tools/nogil-corpus-gate.py
```

`zig build threads-test-bin` (~40 s) plus
`zig-out/bin/threads-test one <case>` / `parallel-js one <case>` is much faster
than going through the build system per case.

### WebAssembly

```bash
zig build wasm-spec              # packed wg-1.0 runner
zig build wasm-spec-eval         # live corpus evaluator (driven by tools/wasm-spec.py)
zig build wasm-feature-profiles
```

### Embedding surfaces

```bash
zig build test-c-api                        # C and C++ hosts
zig build c-api-audit objc-api-audit        # inventory audits
zig build test-objc-api-evidence            # macOS Objective-C matrix
```

### Docs

```bash
bun run docs:dev
bun run docs:build      # this is a CI gate
```

### Concurrency discipline (please read)

- **Never run two corpus jobs at once**, not even a small probe beside a long
  run. Some drivers reap survivors by process name and will kill the other run's
  cases, which are then silently recorded as failures. Check
  `pgrep -f 'zig-out/bin/threads-test'` first.
- **Do not run corpus cases while the unit suite runs.** The suite makes no
  visible progress for 10+ minutes and looks hung. That is starvation.
- A job at high CPU for hours may be **spinning, not slow**. On macOS,
  `sample <pid> 3 -f /tmp/out.txt` gives the recursive stack in seconds.

---

## 4. Conventions

### Code

- Match the surrounding style. This codebase comments the **why** — the spec
  clause, the ordering constraint, the bug a guard prevents — not the what.
- Cite the spec step when you implement one. Most non-obvious code here exists to
  satisfy an exact ordering requirement.
- **Generated files are generated.** `*_data.zig`, `cldr_*.zig`, `unicode_*.zig`,
  `iana_*.zig`, and `encoding_*_data.zig` come from `tools/gen_*`. Edit the
  generator and re-run it.
- **New shared mutable state needs an explicit synchronization ruling.** Shapes,
  properties, elements, environments, promises, microtasks, inline caches, thread
  records, waiter queues, and shared-buffer storage each already have one.
  Process-global mutable state must be listed in
  [`docs/threads/bindings.md`](docs/threads/bindings.md) with a `per-thread`,
  `locked`, or `refused` ruling. A plain field read from two threads is a race
  even when it looks fine.
- A ThreadSanitizer suppression is a **decision**, not an oversight. Read
  [`docs/threads/memory-model.md`](docs/threads/memory-model.md) before
  narrowing or widening a lock.

### Documentation

Public claims are backed by checked-in evidence.
[`docs/DOCS_ACCURACY_PLAN.md`](docs/DOCS_ACCURACY_PLAN.md) is binding:

- **No number without a source** — `docs/.data/`, a saved transcript, or output
  you just produced.
- Skipped or excluded tests are **outside the denominator**, never "implemented".
- The C API is an implemented **public subset**, never "the JavaScriptCore
  framework" and never "drop-in".
- Performance claims need a dated report *and* its raw samples, with hardware,
  versions, sample count, and statistic. Never from a dirty tracked worktree, and
  never from quick-mode smoke timings.

**Marker-delimited regions are generated — do not hand-edit them:**

| Marker | Generator |
| --- | --- |
| `<!-- release-compatibility:*:start/end -->` | `python3 tools/release-compatibility.py --update-readme` |
| `<!-- benchmark-comparison:start/end -->` | `python3 tools/benchmark-publication.py …` |
| `<!-- gc-generation:start/end -->` | `zig build gc-generation-benchmark -Dgc-generation-benchmark-update-readme=true` |
| all of `docs/platforms.md` | `python3 tools/platform-release-matrix.py` |

New docs pages must be added to `markdown.sidebar` in
[`docs.config.ts`](docs.config.ts) — otherwise they are unreachable.

### Commits

- Work lands **directly on `main`**, in small, frequent commits — one logical fix
  per commit, pushed as you go.
- **Conventional-commit subjects**: `type(scope): summary`, e.g.
  `fix(typedarray): …`, `fix(atomics): …`, `docs(features): …`,
  `tools(tsan-witness): …`.
- **Quantify impact in the body.** How many test262 cases flipped, per affected
  subtree, before → after; say "no regressions" only when you measured it.
  Docs-only commits say `flips 0 test262 cases`.

```
fix(class): evaluate computed field names once at class definition

test/language 502 -> 498 fail (+4), no regressions across test/language.
```

#### Measuring a conformance flip

Build a "before" binary with the engine files stashed but tooling kept:

```bash
git stash push src/interpreter.zig src/vm.zig src/builtins.zig src/parser.zig src/lexer.zig
zig build test262-bin --prefix /tmp/before
git stash pop

/tmp/before/bin/test262 --diag test/language 2>/dev/null | grep -av '^#' | cut -f2 | sort -u > /tmp/base.txt
zig-out/bin/test262     --diag test/language 2>/dev/null | grep -av '^#' | cut -f2 | sort -u > /tmp/after.txt
comm -13 /tmp/base.txt /tmp/after.txt   # regressions — must be empty
comm -23 /tmp/base.txt /tmp/after.txt   # gains
```

Confirm the "after" count is plausible before trusting the diff; a zero-length
run means the corpus was not found.

---

## 5. What CI will ask of you

[`.github/workflows/ci.yml`](.github/workflows/ci.yml) is authoritative. Each
Required Check is its own matrix leg (`fail-fast: false`) so an unrelated failure
cannot mask the threading gates:

- sharded unit suite, and the same suite under ThreadSanitizer;
- sharded `threads-test`, plus a no-GIL witness and an execution-inventory
  witness;
- **no-GIL corpus gates** — a TSan sweep requiring zero engine-state races, and a
  functional gate against the published baseline, in Debug and ReleaseSafe;
- `threadfuzz` in six profiles plus TSan variants (seeded, so deterministic);
- WebAssembly smokes across ten pinned upstream corpora;
- public/private ABI boundary fixtures across Debug / ReleaseSafe / TSan;
- `test262-parallel` — parallel execution introduces no new failures;
- `bun run docs:build`.

Before opening a change, run the subset that matches what you touched. For
engine semantics: `zig build test-parallel` plus a `--diag` diff. For threading:
the list in [`docs/threads/testing.md`](docs/threads/testing.md). For an ABI
surface: the matching `*-audit` step and its fixture in all three build modes.

### Promotion has a bar

- A PR-249 thread case is promoted only when it passes **and** finishes inside
  the no-GIL gate's budget. Several cases are ~20× slower with the GIL off, so
  "it passes in GIL mode" is not promotion evidence — promoting such a case
  breaks CI.
- An ABI entry moves from `pending` to `implemented` only when behaviour tests
  cover it, not when the declaration compiles.

---

## 6. Good first contributions

- **Conformance clusters.** Run `--diag` on a subtree, group by the reason
  column, and take the largest cluster with a clean cause. A cluster of
  `scope-*` / `name-*` failures usually shares one root cause.
- **VM/tree-walker parity.** Find a semantics the tree-walker gets right and the
  VM does not. These are real bugs the corpus does not catch.
- **Documentation.** Every page in `docs/` should trace its claims to a source in
  [`DOCS_ACCURACY_PLAN.md`](docs/DOCS_ACCURACY_PLAN.md). Finding a claim that no
  longer does is a genuine contribution.
- **Generator refreshes.** Bumping a CLDR/IANA/Unicode release and re-running the
  matching `tools/gen_*` script, with the resulting flip count measured.

Areas that need a large, coordinated change rather than a piecemeal patch are
called out in the relevant docs — check there before starting.

---

## 7. Getting help

- [Discussions](https://github.com/zig-utils/zig-js/discussions) for anything
  worth making searchable.
- [Discord](https://discord.gg/f7wBym6JF2) for casual conversation.
- Issues for bugs, with a minimal script and the mode it reproduces in (arena vs.
  `enable_gc`, tree-walker vs. VM, serialized vs. no-GIL) — that context usually
  determines where the bug is.

By contributing you agree that your contributions are licensed under the
[MIT License](LICENSE).
