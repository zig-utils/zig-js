---
title: Contributing
description: Set up the toolchain, run the suites, and land a change in zig-js.
---

# Contributing

The canonical, complete guide is
[`CONTRIBUTING.md`](https://github.com/zig-utils/zig-js/blob/main/CONTRIBUTING.md)
in the repository root. This page is the orientation version, with links into the
rest of the site.

## Get it building

1. **Zig `0.17.0-dev`**, at least `0.17.0-dev.956`. Zig 0.16 will not build the
   tree.
2. **Sibling checkouts** of `zig-regex` and `zig-gc` next to your `zig-js`
   directory — `build.zig.zon` resolves them by local path, so without them
   dependency resolution fails before anything compiles.
3. **Corpora**: `git submodule update --init test262 wasm-spec-wg1 wasm-spec-wg3`.
   A missing corpus is skipped cleanly rather than failed, so a run can score
   zero and still exit 0 — check the denominator.
4. `python3` for the tool gates, `bun` for this site.

Detail: [Building & Running](/guide/building).

## Know the shape of the engine

The **tree-walking interpreter is the semantic baseline** and runs nearly all
code. The bytecode VM exists for capability — suspend/resume, deep recursion,
proper tail calls — not for general speed, and the native tiers above it always
retain an exact interpreter fallback.

The practical consequence: **a semantics fix in `interpreter.zig` often needs a
mirrored fix in `vm.zig`**, and the corpus will not reliably catch a VM-only
divergence. See [Execution tiers](/advanced/execution-tiers) and
[Architecture](/architecture).

## Run the right suite

```bash
zig build test-parallel                     # full unit suite, sharded — use this
zig build test -Dtest-filter=<substr>       # focused; changing the filter does not relink
zig build test262 -Doptimize=ReleaseFast    # the real corpus
zig build threads-test                      # PR-249 thread corpus
zig build threadfuzz -Dfuzz-iters=400       # seeded concurrent fuzzing
bun run docs:build                          # docs are a CI gate
```

`zig build test` unsharded uses one core and takes hours — `test-parallel` builds
once and runs shards against the same binary. Test-name filtering happens in the
runner, so repeated focused probes reuse that binary.

**Never run two corpus jobs at once**, and never beside the unit suite — see
[Debugging & tooling](/advanced/debugging) for why, and for what to do when a job
looks hung.

## Meet the evidence bar

Claims here are backed by checked-in artifacts. Before writing a number, know
where it comes from; before editing a status block, check whether a tool
generates it. [Verification & evidence](/advanced/verification) explains the
system, and the
[accuracy plan](https://github.com/zig-utils/zig-js/blob/main/docs/DOCS_ACCURACY_PLAN.md)
is the binding rule set.

New docs pages must be registered in `markdown.sidebar` in `docs.config.ts`, or
they are unreachable.

## Land the change

Small, frequent commits directly on `main`, conventional subjects
(`fix(scope): summary`), and **the impact quantified in the body** — how many
test262 cases flipped per subtree, before → after, with "no regressions" stated
only when measured. Docs-only commits say `flips 0 test262 cases`.

## Where to start

- A `--diag` failure cluster in one test262 subtree — group by the reason column
  and take the largest cluster with a clean cause.
- A VM/tree-walker parity bug: real, and invisible to a green corpus run.
- A docs claim that no longer traces to its source.
- A CLDR / IANA / Unicode generator refresh, with the flip count measured.

Ask in [Discussions](https://github.com/zig-utils/zig-js/discussions) or
[Discord](https://discord.gg/f7wBym6JF2).
