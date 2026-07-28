---
name: docs-accuracy
description: Update README.md or docs/ for zig-js without inventing implementation status — which numbers are generated, which markers are off-limits, where each claim's source of truth lives, and how to refresh the release matrix and docs site. Use when writing or editing documentation, changing a status/pass-rate/performance claim, or when a doc build or release gate needs to pass.
---

# Documentation accuracy

This project's docs are evidence-backed. The binding guardrail is
[`docs/DOCS_ACCURACY_PLAN.md`](../../../docs/DOCS_ACCURACY_PLAN.md); this skill
is how to apply it.

## 1. Source of truth per claim

| Claim | Comes from |
| --- | --- |
| test262 totals / per-suite rows | `docs/.data/test262.json`, or a saved `zig build test262` transcript |
| test262 runner scope (skips, exclusions, subtrees, timeouts) | `conformance/test262.zig` |
| C API scope | exported symbols and tests in `src/c_api.zig`; the inventories under `docs/c-api/`, `docs/objc-api/`, `docs/abi/` |
| Threading status | `docs/threads/*`, `conformance/threads_test.zig`, a current `zig build threads-test` result |
| WebAssembly scores | the per-profile inventories under `docs/.data/` and `docs/.data/wasm-conformance-matrix.json` |
| Build commands | `build.zig` and `package.json` |
| Performance | a dated report under `docs/.data/` **plus** its raw sample file, with the workload/runner sources named in `docs/benchmarks.md` |
| Platform support boundary | `docs/platforms.md` (generated) |
| Release gates | `docs/.data/release-compatibility-matrix.json` |

## 2. Hard rules

- **No number without a source.** Not in `docs/.data/`, not in a saved
  transcript, not in output you just produced → do not write it.
- No per-suite row unless that suite line appeared in a saved transcript. If only
  the summary is available, leave `suites` empty rather than inventing rows.
- Skipped or excluded tests are **outside the denominator** — never described as
  implemented.
- The C API is an implemented **public subset**, never "the JavaScriptCore
  framework" and never "drop-in".
- Never publish a direct throughput ratio between shared-realm zig-js `Thread`s
  and independent JSC contexts. They are separate scaling references.
- Never publish performance evidence from a dirty tracked worktree, and never
  promote quick-mode smoke timings into a public table.
- Historical design notes may keep old numbers **only** when clearly framed as
  history. Status pages use current data.

## 3. Generated regions — never hand-edit

| Marker | Generator |
| --- | --- |
| `<!-- release-compatibility:<section>:start/end -->` (overview, quickstart, status, use, build-test, notice, wasm-performance, gc-compaction) | `python3 tools/release-compatibility.py --update-readme` |
| `<!-- benchmark-comparison:start/end -->` | `python3 tools/benchmark-publication.py …` |
| `<!-- gc-generation:start/end -->` | `zig build gc-generation-benchmark -Dgc-generation-benchmark-update-readme=true` |
| whole file: `docs/platforms.md` | `python3 tools/platform-release-matrix.py` |

Change the evidence, then re-run the generator. Hand-edited text inside a marker
is reverted by the next run and can silently desync a release gate.

## 4. Refresh checklist

```bash
# 1. Conformance
zig build test262 -Doptimize=ReleaseFast > /tmp/run.txt 2>&1   # summary is on stderr
bun run docs:data -- --from /tmp/run.txt

# 2. Release matrix + generated README sections
zig build release-compatibility
python3 tools/release-compatibility.py --update-readme
python3 tools/platform-release-matrix.py

# 3. Hunt stale claims
rg -n 'drop-in|WebKit test262|partial|unimplemented|[0-9]{2,}/[0-9]{2,}' README.md docs

# 4. Build the site
bun run docs:build
```

For each flagged claim: tie it to a source above, rewrite it as a scoped
statement, or delete it.

## 5. Writing new pages

- The site is [bunpress](../../../docs.config.ts). New pages must be added to
  `markdown.sidebar` (and `nav`, for a top-level section) or they are
  unreachable.
- Frontmatter is `title` + `description`. Links are site-absolute
  (`/features/language`), not file-relative, inside `docs/`.
- Custom components already available: `<Test262Progress :stats="data.test262" />`,
  `<Terminal title="…">`, `<FeatureCard tag="…" title="…">`, and the `.cards` /
  `.suites` CSS classes defined in `docs.config.ts`.
- `data.test262` is read from `docs/.data/test262.json` at build time — prefer
  binding to it over typing a number into prose, so the page cannot go stale.
- `bun run docs:build` is a **CI gate**. Run it before committing docs changes.

## 6. Commit

Docs-only commits state `flips 0 test262 cases` in the body, use a conventional
subject (`docs(...)`, `chore(readme): …`), and carry no `Co-Authored-By` trailer.
Do not commit `docs/threads/*` unless that is explicitly your assignment — a
separate actor stages those files concurrently.
