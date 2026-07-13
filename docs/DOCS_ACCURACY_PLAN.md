# Documentation Accuracy Plan

This file is the guardrail for updating `README.md` and `docs/` without
inventing implementation status.

## Source Of Truth

- **test262 totals** come from a full parent `zig build test262` run, preferably
  saved to a transcript and parsed with:

  ```sh
  bun run docs:data -- --from run.txt
  ```

- **test262 runner scope** comes from `conformance/test262.zig`, especially the
  skip rules, excluded-file rules, unsupported flags, subtree list, worker limits, and timeout rules.
- **C API scope** comes from exported symbols and tests in `src/c_api.zig`.
- **Threading status** comes from `docs/threads/*`, `conformance/threads_test.zig`,
  and the current `zig build threads-test` result.
- **Build commands** come from `build.zig` and `package.json`.
- **Performance claims** come from a dated report under `docs/.data/`, its raw
  sample file, and the exact workload/runner sources documented in
  `docs/benchmarks.md`. Do not copy quick-mode smoke timings into public tables.

## Rules

- Do not write a pass count unless it is present in `docs/.data/test262.json`,
  a saved run transcript, or a just-run command output.
- Do not write a per-suite row unless the suite line appeared in a saved
  `zig build test262` transcript. If only the final summary is available,
  leave `docs/.data/test262.json.suites` empty.
- Do not describe skipped or excluded test262 categories as implemented. Say
  they are outside the denominator until focused workers pass and the skip or
  exclusion is removed.
- Do not describe the C API as the whole JavaScriptCore framework. It is an
  implemented public C-API subset.
- Do not publish a direct throughput ratio between shared-realm zig-js `Thread`s
  and independent JSC contexts. Report them as separate scaling references until
  a symmetric independent-context zig-js mode exists. State the hardware, engine
  versions, sample count, statistic, workload scope, and saved raw evidence.
- Do not publish a benchmark report from a dirty tracked worktree. The report's
  commit must identify the exact runner/workload source that produced the raw
  samples; generated output files are written only after metadata is captured.
- Historical design notes may keep old numbers only when they are clearly
  framed as history. Public status pages should use current data.

## Refresh Checklist

1. Run or parse conformance:

   ```sh
   timeout 10800 zig build test262 -Doptimize=ReleaseFast
   bun run docs:data -- --from run.txt
   ```

2. Search for stale claims:

   ```sh
   rg -n 'drop-in|WebKit test262|partial|unimplemented|[0-9]{2,}/[0-9]{2,}' README.md docs
   ```

3. For each claim, either:
   - tie it to a source listed above,
   - rewrite it as a scoped statement, or
   - remove it.

4. Build or at least syntax-check docs changes:

   ```sh
   bun run docs:build
   ```

5. Commit docs-only updates with `flips 0 test262 cases` in the body.
