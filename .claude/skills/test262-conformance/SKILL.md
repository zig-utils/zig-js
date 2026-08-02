---
name: test262-conformance
description: Measure, diagnose, and fix zig-js ECMAScript conformance against the pinned tc39/test262 corpus. Use when the task mentions test262, conformance, pass rate, a failing JS language/built-in behavior, "how many tests flipped", or when a spec-semantics fix needs before/after evidence. Covers the --diag / --eval tooling, the before-binary diff method, and refreshing docs/.data/test262.json.
---

# test262 conformance

The corpus is the project's primary correctness signal, and every conformance
claim in `README.md` / `docs/` must trace to a real run. This skill is the
measure → diagnose → fix → re-measure loop.

## 1. Know what you are scoring

- Runner: [`conformance/test262.zig`](../../../conformance/test262.zig). It owns
  the subtree list, skip rules, excluded-file rules, unsupported flags, worker
  limits, and timeouts. **Runner scope questions are answered there, not from
  the docs.**
- Corpus: the `test262/` git submodule. `git submodule update --init test262`.
- Two axes are reported separately: **VALID** (can we run it) and **NEGATIVE**
  (do we reject what must be rejected).

> A missing corpus is skipped cleanly, not failed. A run that scores **zero**
> exits 0 and diffs as "all gains, no regressions". Always confirm the
> denominator is plausible before trusting any comparison.

## 2. Commands

```bash
zig build test262 -Doptimize=ReleaseFast        # full corpus; cold build ~25-30 min
zig build test262 -Dtest262=/path/to/test262 -Doptimize=ReleaseFast
zig build test262-bin                            # build the runner, do not run
zig build test262-bin --prefix /tmp/before       # build a comparison binary elsewhere
```

The runner binary is the fast path for iteration:

```bash
zig-out/bin/test262 --diag test/language          # outcome<TAB>path<TAB>reason per failure
zig-out/bin/test262 --diag test/built-ins Array   # narrow by substring
zig-out/bin/test262 --eval /tmp/probe.js          # OK <value> / ERR <name: msg>
zig-out/bin/test262 --list-skips
zig-out/bin/test262 --list-excluded
```

Notes that matter:

- `--diag` has **no per-test timeout**. `expressions/dynamic-import/*` dominates;
  a full `test/language` pass is minutes, not seconds. Run it as a foreground
  blocking call with a generous timeout, or background it and wait for the
  completion notification — do not poll the output file.
- `--diag` paths include the `test/` prefix (`test/language`, `test/annexB`,
  `test/built-ins`, `test/intl402`).
- A DebugAllocator leak report on stderr is harmless for `--diag`/`--eval`.
- The full-suite **summary goes to stderr**. Never `2>/dev/null` a run you plan
  to parse; capture with `> run.txt 2>&1`.

## 3. Diagnose: cluster before fixing

`--diag`'s third column is the failure reason. Sort and count it — a cluster of
`scope-*` / `name-*` failures under `statements/class` and `expressions/class`
almost always shares one root cause, and fixing it flips both halves at once.

```bash
zig-out/bin/test262 --diag test/language > /tmp/diag.txt 2>/dev/null
grep -av '^#' /tmp/diag.txt | cut -f3 | sort | uniq -c | sort -rn | head -30
```

Pick the largest cluster with a *clean* cause. Blank-reason clusters are usually
unimplemented features (a multi-hour build), not bugs.

## 4. Fix, keeping both execution paths in mind

The tree-walker (`src/interpreter.zig`) is the semantic baseline and runs nearly
all corpus code. The bytecode VM (`src/compiler.zig` + `src/vm.zig`) runs
generators, async functions, async generators, and a narrow set of plain
functions.

**A tree-walker fix often needs the mirrored fix in `vm.zig`.** Because the
corpus barely exercises the VM, a VM-only divergence can be introduced with a
green test262 run. Probe VM paths deliberately with IIFEs, generators, and
`--eval`.

Generator/async-generator work has ~2× leverage: async generators share
`makeGenerator` / `compileGenerator`, so apply every generator fix to the async
maker too.

## 5. Measure the flip count

Build a "before" binary with the engine files stashed but the tooling kept:

```bash
git stash push src/interpreter.zig src/vm.zig src/builtins.zig src/parser.zig src/lexer.zig
zig build test262-bin --prefix /tmp/before
git stash pop
```

Then diff per subtree:

```bash
/tmp/before/bin/test262 --diag test/language 2>/dev/null | grep -av '^#' | cut -f2 | sort -u > /tmp/base.txt
zig-out/bin/test262     --diag test/language 2>/dev/null | grep -av '^#' | cut -f2 | sort -u > /tmp/after.txt
comm -13 /tmp/base.txt /tmp/after.txt   # REGRESSIONS — must be empty
comm -23 /tmp/base.txt /tmp/after.txt   # gains
```

Keeping `/tmp/base.txt` from the last accepted state turns each subsequent probe
into a single `--diag` run.

If you build in a worktree, remember the worktree's `test262/` submodule is
usually uninitialized: **build there, but run the diag with the main repo as
CWD**, because the corpus path resolves relative to CWD.

## 6. Publish the numbers

Only after a real full run:

```bash
zig build test262 -Doptimize=ReleaseFast > /tmp/run.txt 2>&1
bun scripts/gen-test262-data.ts --from /tmp/run.txt # rewrites docs/.data/test262.json
python3 tools/release-compatibility.py --update-readme
zig build docs-manifest-update
zig build docs-build
```

The homepage bar, the conformance page, and every `data.test262` reference
update from that JSON. The README's status block is generated — do not hand-edit
inside the `<!-- release-compatibility:status:* -->` markers.

Do not describe skipped or excluded categories as implemented; they are outside
the denominator until the skip or exclusion is removed. See
[`docs/DOCS_ACCURACY_PLAN.md`](../../../docs/DOCS_ACCURACY_PLAN.md).

## 7. Commit

One cluster per commit, conventional subject, and the flip count in the body:

```
fix(class): evaluate computed field names once at class definition

test/language 502 -> 498 fail (+4), no regressions across test/language.
```

No `Co-Authored-By` trailers. Push to `main` as you go.
