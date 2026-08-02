# CLAUDE.md

Operating manual for coding agents working in `zig-js`. `AGENTS.md` is a symlink
to this file, so any agent convention that reads either name gets the same rules.

Read this before the first edit. When something here disagrees with what you
find in the tree, the tree wins — fix this file in the same change.

---

## 1. What this repository is

A JavaScript engine written from scratch in Zig, with no bundled C engine. It is
three products in one tree:

| Product | Entry point | Notes |
| --- | --- | --- |
| Embeddable Zig engine | [`src/root.zig`](src/root.zig) — `js.Context` | The primary API. |
| JavaScriptCore-shaped **public C API** | [`src/c_api.zig`](src/c_api.zig) | Installs `libzig-js.a` + `JavaScriptCore/`-compatible headers. A pinned *subset target*, never "all of JSC". |
| Versioned **private ABI profiles** | [`src/private_abi.zig`](src/private_abi.zig), [`docs/abi/README.md`](docs/abi/README.md) | Exact, revision-pinned contracts for named downstream consumers (Home, Bun). |

Plus a macOS Objective-C bridge (`src/objc_bridge.m`), a pure-Zig WebAssembly
runtime (`src/wasm/`), and GIL-free shared-realm threading (`src/jsthread.zig`,
`src/gil.zig`).

Dependencies are two sibling Zig packages — `zig-regex` and `zig-gc` — resolved
**by local path**. System JavaScriptCore is used only by explicitly-named
differential and benchmark targets, never by the library itself.

---

## 2. Prerequisites (get this wrong and nothing builds)

- **Zig `0.17.0-dev`**, at least `0.17.0-dev.956`. Zig 0.16 will not build this
  tree. On this machine zig is not on the default `PATH`; the pantry shim is at
  `$HOME/.local/share/pantry/global/bin`.
- **Sibling checkouts** next to this repo — `../zig-regex` and `../zig-gc` (see
  [`build.zig.zon`](build.zig.zon)). Without them dependency resolution fails
  before compilation starts. In a `.claude/worktrees/<name>` worktree you must
  create those two symlinks yourself.
- **Owned documentation source** at `../../Tools/bunpress`. Documentation
  commands execute that checkout directly; fix renderer defects there instead
  of adding a local substitute to zig-js.
- **Submodules** for corpora: `test262`, `wasm-spec-wg1`, `wasm-spec-wg3`. A
  missing corpus is skipped cleanly rather than failing, which means a run can
  silently score **zero** files — always sanity-check the denominator.
- **`python3`** for the `tools/*.py` gates, **`bun`** for the docs site.

---

## 3. Repository map

```
src/                 the engine
  lexer.zig parser.zig ast.zig      source -> AST
  interpreter.zig                   tree-walking evaluator (the semantic baseline, ~50k lines)
  compiler.zig bytecode.zig vm.zig  AST -> bytecode -> stack VM (suspend/resume, deep recursion, tail calls)
  jit.zig jit/                      baseline native tier + optimizing tier (aarch64)
  value.zig value_nb.zig nanbox.zig NaN-boxed Value, Object, coercions
  shape.zig                         hidden classes / transition tree
  context.zig                       the engine instance: allocators, globals, GC wiring, options
  builtins.zig promise.zig          built-ins and the microtask queue
  gc.zig gc_runtime.zig gc_relocation.zig stack_scan.zig root_handshake.zig  precise/parallel GC
  gil.zig jsthread.zig parallel_lock.zig worker.zig agent.zig  threading
  wasm/                             decode, validate, exec, simd, atomic, gc, JS API
  c_api.zig private_abi.zig private_abi/  embedding ABIs
  *_data.zig cldr_*.zig unicode_*.zig     generated tables (regenerate, never hand-edit)

conformance/         test262 + PR-249 thread corpus + wasm spec runners
tests/               C / C++ / Objective-C embedding fixtures
bench/               benchmark workloads and runners
tools/               python + zig gates, generators, audits, profilers
docs/                the published documentation site (bunpress)
docs/.data/          machine-readable evidence: run inventories, benchmark samples, matrices
reference/           vendored upstream reference material (see the do-not-touch note below)
.github/workflows/   CI — the authoritative gate list
```

`build.zig` is ~95 KB and defines **well over a hundred** named steps. It is the
real index of what this project can do: `zig build --help` (or
`grep -n 'b.step(' build.zig`) beats guessing.

---

## 4. Execution model in one paragraph

The **tree-walker is the semantic baseline** and runs nearly all code. The
bytecode VM exists for *capability*, not speed: generators, async functions, and
async generators need suspend/resume, and the VM's heap activation stack gives
deep recursion and proper tail calls. A plain function only tiers into the VM
when it can actually benefit. Above that sit a baseline native tier and an
optimizing tier, both of which must preserve an exact interpreter fallback.

The practical consequence for agents: **a fix in `interpreter.zig` frequently
needs a mirrored fix in `vm.zig`**, and the reverse. test262 exercises the VM
far less than the tree-walker, so VM/tree-walker divergence is a known bug
surface that the corpus will not catch for you. Use `threadfuzz` and
IIFE/`eval`-shaped probes to hit VM-only paths.

---

## 5. Commands, and what they cost

Always prefer the cheapest command that answers the question.

### Build

```bash
zig build                       # libzig-js.a + headers into zig-out/
zig build test262-bin           # build the corpus runner only (no run)
zig build threads-test-bin      # ~40 s; then drive zig-out/bin/threads-test directly
```

### Unit tests

```bash
zig build test-parallel         # ALWAYS use this for a full local run
zig build test -Dtest-filter=<substr>   # focused; still relinks
zig build test -Dtsan=true      # ThreadSanitizer
```

`zig build test` is single-threaded per process; unsharded it uses one core and
takes hours. `test-parallel` builds once and runs N shards against that same
binary (`-Dunit-jobs=N`, per-shard logs in `.zig-cache/unit-shards/`). Measured
reference point: ~1,430 tests, ~170 s across 10 shards.

Any edit under `src/` relinks the test artifact — budget ~4–6 min per build,
~8–10 min per filtered probe cycle. Prefer **one instrumentation pass that
answers several questions** over several narrow ones.

### Conformance

```bash
zig build conformance                       # fast local smoke suite, not a CI gate
zig build test262 -Doptimize=ReleaseFast    # the real corpus (cold ReleaseFast ~25-30 min)
zig-out/bin/test262 --diag test/language    # per-failure cluster report
zig-out/bin/test262 --eval file.js          # run one script: OK <value> / ERR <name: msg>
```

`--diag` has no per-test timeout, so a full `test/language` pass takes minutes
(the dynamic-import tail dominates). Paths carry the `test/` prefix. The summary
goes to **stderr** — do not `2>/dev/null` a run you intend to parse.

### Threads / no-GIL

```bash
zig build threads-test                                   # PR-249 corpus, GIL mode
zig build threads-test -Dthreads-case=<relpath>          # one case
zig build threads-test -Dthreads-parallel-js=true -Dthreads-case=<relpath>   # no-GIL
zig build threads-reference-audit threads-reference-probes
zig build threadfuzz -Dfuzz-iters=400                    # seeded, deterministic
zig build threadfuzz -Dfuzz-{amplify,broad,midgc,lifecycle,verify}=true
```

### WebAssembly, benchmarks, evidence

```bash
zig build wasm-spec                 # packed wg-1.0 runner
zig build wasm-spec-eval            # live-WABT corpus evaluator (driven by tools/wasm-spec.py)
zig build benchmark-comparison      # zig-js vs system JSC (macOS)
zig build release-compatibility     # validate the #134 release matrix
python3 tools/nogil-corpus-gate.py  # functional no-GIL corpus gate vs the published baseline
```

### Docs

```bash
bun run docs:dev / docs:build / docs:preview
bun run docs:manifest              # accept an intentional rendered-tree change
bun run docs:data -- --from run.txt   # regenerate docs/.data/test262.json from a run transcript
```

### Concurrency discipline for long jobs

- **Never run two corpus jobs at once**, not even a small probe beside a long
  run. Some drivers reap survivors with `pkill -f zig-out/bin/threads-test` and
  will kill the *other* run's cases, which are then silently recorded as
  failures. Confirm `pgrep -f 'zig-out/bin/threads-test'` is empty before
  trusting any timing.
- Do not run corpus cases while the unit suite runs. The suite makes no visible
  progress for 10+ minutes and looks hung; that is starvation, not deadlock.
- A job "taking hours" may be spinning. On macOS, `sample <pid> 3 -f out.txt`
  gives the recursive stack in seconds. Sample before believing the wall clock.
- Watch background jobs with the `Monitor` tool, not by re-reading the log.
  Filter on real signals — matching bare `panic` hits test *names* like "does
  not panic" and fires nonstop.

---

## 6. Evidence rules — the thing this project cares about most

Public claims in `README.md` and `docs/` are backed by checked-in evidence under
`docs/.data/`. [`docs/DOCS_ACCURACY_PLAN.md`](docs/DOCS_ACCURACY_PLAN.md) is the
binding guardrail. In short:

- **Never write a number you did not just produce or read from checked-in
  evidence.** Pass counts come from `docs/.data/test262.json`, a saved run
  transcript, or live command output.
- Skipped or excluded tests are **outside the denominator**, not "implemented".
- The C API is an *implemented public subset*, never "the JavaScriptCore
  framework" or "a drop-in".
- Performance claims need a dated report **and** its raw sample file under
  `docs/.data/`, plus hardware, engine versions, sample count, and statistic.
  Never publish from a dirty tracked worktree, and never promote quick-mode
  smoke timings into a public table.
- Do not publish a direct throughput ratio between shared-realm zig-js `Thread`s
  and independent JSC contexts — report them as separate scaling references.

### Generated regions — do not hand-edit

`README.md` and some docs pages contain marker-delimited generated blocks:

```
<!-- release-compatibility:<section>:start --> … <!-- release-compatibility:<section>:end -->
<!-- benchmark-comparison:start --> … <!-- benchmark-comparison:end -->
<!-- gc-generation:start --> … <!-- gc-generation:end -->
```

They are written by `tools/release-compatibility.py --update-readme`,
`tools/benchmark-publication.py`, `tools/gc-generation-benchmark.py`, and
`tools/platform-release-matrix.py` (which owns `docs/platforms.md` wholesale).
Change the evidence and re-run the generator; editing the rendered text by hand
will be reverted by the next run and can silently desync a release gate.

---

## 7. Code conventions

- **Zig style as the tree already writes it.** Match the surrounding comment
  density — this codebase comments the *why* (spec clause, ordering constraint,
  the bug a guard prevents), not the *what*.
- **Spec citations belong in comments.** When implementing an ECMA-262 or
  WebAssembly behavior, name the step or clause. Most non-obvious code here
  exists to satisfy an exact ordering requirement.
- **Generated files are generated.** Anything matching `*_data.zig`,
  `cldr_*.zig`, `unicode_*.zig`, `iana_*.zig`, `encoding_*_data.zig` comes from
  a `tools/gen_*` script. Edit the generator and re-run it.
- **Threading: new shared mutable state needs an explicit synchronization
  ruling.** Object shapes, properties, elements, environments, promises,
  microtasks, inline caches, thread records, waiter queues, and shared-buffer
  storage each already have one. Process-global mutable state must be listed in
  [`docs/threads/bindings.md`](docs/threads/bindings.md) with a `per-thread`,
  `locked`, or `refused` ruling. A plain field read from two threads is a race
  even when it "looks fine" — make it atomic with an explicit ordering.
- **A TSan-suppressed race is a decision, not an oversight.** Read
  [`docs/threads/memory-model.md`](docs/threads/memory-model.md) before
  narrowing or widening a lock. JavaScript *program* races are permitted; engine
  *state* races are not.
- **When a threading test still fails "with suppressions applied", read the
  actual FAIL line.** It is often the case's own functional assertion, not a
  sanitizer abort.

---

## 8. Landing changes

- Work lands **directly on `main`** in small, frequent commits — one logical fix
  per commit, pushed as you go, not one large batch.
- **Conventional-commit subjects**: `type(scope): summary` (`fix(typedarray):`,
  `fix(atomics):`, `chore(readme):`, `tools(tsan-witness):`). Match the existing
  history.
- **Quantify impact in the body.** How many test262 cases flipped, per affected
  subtree, before → after; say "no regressions" only when you actually measured
  it. Docs-only commits say `flips 0 test262 cases`.
- **No `Co-Authored-By` or other trailers.** This overrides the default trailer
  instruction. Author as `Chris <chrisbreuer93@gmail.com>`.
- **Do not commit `reference/webkit-249/threads-tests/*` or `docs/threads/*`**
  unless that is explicitly the change you were asked to make — a separate actor
  edits and stages those concurrently. Stage explicit paths (`git commit <paths>`
  or `git add` the exact files) rather than `git commit -a`, so a concurrent
  `git add` cannot sweep foreign files into your commit.
- Pushes can race. Retry with `git push origin HEAD:main || (git fetch && git
  rebase origin/main)`; "Everything up-to-date" means it already landed.
- `gh` is installed at a pantry path and is not on the default `PATH`.

### Measuring a conformance flip

Build a "before" binary with engine files stashed but tooling kept, then diff
`--diag` output per subtree:

```bash
git stash push src/interpreter.zig src/vm.zig src/builtins.zig src/parser.zig
zig build test262-bin --prefix /tmp/before
git stash pop
```

Keep a sorted baseline of failing paths; `comm -13 base after` is regressions,
`comm -23 base after` is gains. Sanity-check that the "after" count is plausible
before trusting the diff — a zero-length run means the corpus was not found.

---

## 9. CI gates

[`.github/workflows/ci.yml`](.github/workflows/ci.yml) is authoritative. It runs
on PRs, pushes to `main`, manual dispatch, and nightly. Each Required Check is
its own matrix leg (`fail-fast: false`) so a failure in one cannot mask the
threading gates. The families:

- sharded unit suite, and the same suite under **TSan**;
- sharded `threads-test` (GIL) plus a no-GIL witness case;
- **no-GIL corpus gates**: TSan sweep (races must be zero) and a functional gate
  against `docs/.data/pr249-execution-nogil.json`, in Debug and ReleaseSafe;
- `threadfuzz` in six profiles (default, amplified, broad, mid-GC, lifecycle,
  verify) plus TSan variants — seeded, so they are deterministic gates;
- WebAssembly smokes across ten pinned upstream corpora;
- private/public ABI boundary fixtures across Debug/ReleaseSafe/TSan;
- `test262-parallel` (parallel execution introduces no new failures);
- `bun run docs:build`.

**A promoted corpus case must also pass no-GIL within the gate's time budget**,
or CI breaks. Several PR-249 cases are roughly 20× slower with the GIL off —
"it passes in GIL mode" is not promotion evidence.

---

## 10. Traps that have cost real time here

1. **A run that scores zero looks like a pass.** An uninitialized `test262/`
   submodule makes `--diag` emit nothing, exit 0, and diff as "all gains, no
   regressions". Check the denominator.
2. **`git checkout -- <file>` wipes uncommitted work.** Commit early, or stash
   first.
3. **Filtered test builds still relink** — filters are compile-time.
4. **The C API and private ABI profiles are pinned contracts.** Changing an
   exported symbol, struct layout, or enum value breaks a revision-checked
   consumer. Run the matching `*-audit` step.
5. **`bench` numbers are not publication evidence.** Only the dated reports
   under `docs/.data/` with their raw `.tsv` samples are.
6. **`.zig-cache/` and `zig-out/` are fully reproducible** — deleting them only
   costs a rebuild. See [`docs/dev-cache.md`](docs/dev-cache.md).

---

## 11. Where to read next

| Question | File |
| --- | --- |
| How do I contribute / run things? | [`CONTRIBUTING.md`](CONTRIBUTING.md) |
| What does the engine support? | [`docs/features/`](docs/features/index.md) |
| How do the internals work? | [`docs/architecture.md`](docs/architecture.md), [`docs/advanced/`](docs/advanced/index.md) |
| Threading rules and status | [`docs/threads/index.md`](docs/threads/index.md) |
| Conformance methodology | [`docs/conformance.md`](docs/conformance.md) |
| Benchmark methodology | [`docs/benchmarks.md`](docs/benchmarks.md) |
| Embedding via C | [`docs/api.md`](docs/api.md) |
| Doc-accuracy guardrail | [`docs/DOCS_ACCURACY_PLAN.md`](docs/DOCS_ACCURACY_PLAN.md) |

Repeatable workflows are packaged as skills under
[`.claude/skills/`](.claude/skills/) — conformance, threading/no-GIL, benchmark
publication, WebAssembly corpora, ABI profiles, and docs accuracy. Prefer the
skill over reconstructing the workflow from scratch.
