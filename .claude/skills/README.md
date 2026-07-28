# Project skills

Packaged workflows for the recurring jobs in this repository. Each directory
holds a `SKILL.md` whose frontmatter `description` decides when it is offered.

| Skill | Use it for |
| --- | --- |
| [`test262-conformance`](test262-conformance/SKILL.md) | Measuring, diagnosing, and fixing ECMAScript conformance; `--diag` / `--eval`; flip counts; refreshing `docs/.data/test262.json`. |
| [`nogil-threading`](nogil-threading/SKILL.md) | GIL-free threading, data races, ThreadSanitizer, the PR-249 corpus, `threadfuzz`, the no-GIL promotion gate. |
| [`jit-tiers`](jit-tiers/SKILL.md) | Baseline and optimizing native tiers: tier records, entry ABI, safepoints, deopt, differential gates. |
| [`wasm-conformance`](wasm-conformance/SKILL.md) | WebAssembly spec corpora, feature gates, inventories, the ten-profile matrix. |
| [`embedding-abi`](embedding-abi/SKILL.md) | Public C API, Objective-C bridge, revision-pinned private ABI profiles, audits and JSC diffs. |
| [`benchmark-evidence`](benchmark-evidence/SKILL.md) | Benchmarks, profiles, and publishing performance claims through the marker-delimited scorecard. |
| [`docs-accuracy`](docs-accuracy/SKILL.md) | Editing `README.md` / `docs/` without inventing status; generated regions; the refresh checklist. |

General repository rules — toolchain, layout, build costs, commit conventions —
live in [`../../CLAUDE.md`](../../CLAUDE.md) (symlinked as `AGENTS.md`), and the
human-facing version is [`../../CONTRIBUTING.md`](../../CONTRIBUTING.md).

## Adding a skill

Create `.claude/skills/<name>/SKILL.md` with frontmatter:

```markdown
---
name: <kebab-case, matches the directory>
description: <what it does AND when to use it — this is the trigger text>
---
```

Write the description so it names the concrete nouns that appear in a request
("test262", "TSan", "MAP_JIT"). Keep the body to commands that actually exist in
`build.zig` / `tools/`, and cite the doc that owns each rule rather than
restating it — a skill that drifts from the tree is worse than no skill.
