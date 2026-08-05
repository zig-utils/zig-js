/** Collect lossless repeated samples from the isolated zig-js Octane adapter (#504). */
import { metadata } from "./benchmark-comparison";
import { checked, readText, removeTemporaryDirectory, run, temporaryDirectory, writeText } from "./lib/home";

declare const __filename: string;

const ROWS = ["richards", "regexp", "splay", "navier_stokes", "box2d"] as const;
const ROW_LICENSES: Record<string, string[]> = {
  richards: ["BSD-3-Clause"],
  regexp: ["BSD-3-Clause"],
  splay: ["BSD-3-Clause"],
  navier_stokes: ["MIT"],
  box2d: ["Zlib"],
};
const ROW_RESULTS: Record<string, string[]> = {
  richards: ["Richards"],
  regexp: ["RegExp"],
  splay: ["Splay", "SplayLatency"],
  navier_stokes: ["NavierStokes"],
  box2d: ["Box2D"],
};
const BASE_SOURCE = { path: "base.js", sha256: "216612c2e7096a02b3e52b57e9cf9351bbaf180d60938d5c60b85fd756232733" };
const ROW_SOURCES: Record<string, { path: string; sha256: string }> = {
  richards: { path: "richards.js", sha256: "1246a64a24b931158bf01c24640343259fa74b0226e73bad630bd1f686aa0fa7" },
  regexp: { path: "regexp.js", sha256: "a292d6047900c5296ea9e2628453832cc3bfe397e49fddade8aff7b5876c8263" },
  splay: { path: "splay.js", sha256: "f9a6a60d8f205908f5542ad1180abc1902dcdab3dcb4278017c5ce179ee123f7" },
  navier_stokes: { path: "navier-stokes.js", sha256: "27926de809451c60b0c49a4185c08f97081310d0db166a30c1d202fb656556a2" },
  box2d: { path: "box2d.js", sha256: "83b10c280f004e7b156a9e04d09ce4109892ea92788f7c6c963f7fadf29c7bd4" },
};
const REQUIRED_ENVIRONMENT = ["TZ=UTC", "LC_ALL=C", "LANG=C", "network=forbidden"];
const EVALUATION_STEP_BUDGET = "18446744073709551615";
const TERMINATION_BOUNDARY = "external_process_timeout";
const SUITE_REVISION = "570ad1ccfe86e3eecba0636c8f932ac08edec517";
const SUITE_TREE = "e40d5c8489d05e384f32ed064d1f5286e9c236f3";
type Mode = "score" | "attribution";
type Completed = ReturnType<typeof run>;

function requireValue(condition: boolean, message: string): void {
  if (!condition) throw new Error(message);
}

function median(values: number[]): number {
  const sorted = values.slice().sort((left, right) => left - right), middle = Math.floor(sorted.length / 2);
  return sorted.length % 2 ? sorted[middle] : (sorted[middle - 1] + sorted[middle]) / 2;
}

export function statistics(values: number[]): any {
  if (!values.length) return {
    status: "unavailable_no_valid_samples",
    samples: 0,
    median: null,
    minimum: null,
    maximum: null,
    mean: null,
    relative_standard_deviation: null,
  };
  values.forEach((value) => requireValue(Number.isFinite(value), "dispersion input is not finite"));
  const mean = values.reduce((total, value) => total + value, 0) / values.length;
  const variance = values.length > 1
    ? values.reduce((total, value) => total + (value - mean) ** 2, 0) / (values.length - 1)
    : null;
  return {
    status: values.length > 1 && mean !== 0 ? "measured" : "indeterminate",
    samples: values.length,
    median: median(values),
    minimum: Math.min(...values),
    maximum: Math.max(...values),
    mean,
    relative_standard_deviation: variance === null || mean === 0 ? null : Math.sqrt(variance) / Math.abs(mean),
  };
}

function parsePositive(value: unknown, label: string): number {
  const parsed = typeof value === "string" ? Number(value) : Number.NaN;
  requireValue(Number.isFinite(parsed) && parsed > 0, `${label} is not a finite positive score string`);
  return parsed;
}

function expectedArgv(runner: string, checkout: string, row: string, mode: Mode, revision: string): string[] {
  return [runner, checkout, row, mode, revision];
}

export function validateChild(child: any, expected: { runner: string; checkout: string; row: string; mode: Mode; revision: string }): void {
  requireValue(child && child.schema_version === 1 && child.kind === "zig-js-independent-suite-sample", "child schema identity drift");
  requireValue(child.suite === "octane-2-retired" && child.suite_revision === SUITE_REVISION && child.suite_tree === SUITE_TREE, "child suite identity drift");
  requireValue(child.row === expected.row && child.mode === expected.mode, "child row/mode identity drift");
  requireValue(JSON.stringify(child.licenses) === JSON.stringify(ROW_LICENSES[expected.row]), "child license identity drift");
  requireValue(["passed", "failed"].includes(child.status), "child status is invalid");
  requireValue(child.engine?.id === "zig-js" && child.engine.separate_process === true, "child engine isolation drift");
  requireValue(typeof child.engine.executable_path === "string" && child.engine.executable_path.length > 0 && typeof child.engine.version_output === "string" && child.engine.version_output.length > 0, "child executable identity is incomplete");
  requireValue(child.engine.source_revision === expected.revision, "child source revision drift");
  requireValue(/^[0-9a-f]{64}$/.test(child.engine.executable_sha256 || ""), "child executable SHA-256 is invalid");
  requireValue(JSON.stringify(child.engine.argv) === JSON.stringify(expectedArgv(expected.runner, expected.checkout, expected.row, expected.mode, expected.revision)), "child argv drift");
  requireValue(JSON.stringify(child.engine.environment) === JSON.stringify(REQUIRED_ENVIRONMENT), "child environment drift");
  requireValue(child.adapter?.id === "zig-js-octane-minimal-shell-v1" && child.adapter.source_transform === false, "child adapter boundary drift");
  requireValue(JSON.stringify(child.adapter.host_globals) === JSON.stringify(["load", "print"]), "child host-global boundary drift");
  requireValue(child.adapter.evaluation_step_budget === EVALUATION_STEP_BUDGET, "child evaluation-step budget drift");
  requireValue(child.adapter.termination_boundary === TERMINATION_BOUNDARY, "child termination boundary drift");
  requireValue(JSON.stringify(child.adapter.loaded_sources) === JSON.stringify([BASE_SOURCE, ROW_SOURCES[expected.row]]), "child source identity drift");
  requireValue(Array.isArray(child.raw_samples) && child.raw_samples.length === 1, "child raw-sample cardinality drift");
  const raw = child.raw_samples[0];
  requireValue(raw.index === 0 && raw.mode === expected.mode && raw.instrumentation_enabled === (expected.mode === "attribution"), "child raw-sample identity drift");
  for (const field of ["outer_wall_ns", "cpu_user_ns", "cpu_system_ns", "peak_rss_bytes_before", "peak_rss_bytes_after"])
    requireValue(Number.isFinite(raw[field]) && raw[field] >= 0, `child ${field} is invalid`);
  requireValue(child.dispersion?.status === "not_applicable_single_sample" && child.dispersion.sample_count === 1 && child.dispersion.statistic === null, "child single-sample dispersion drift");
  requireValue(child.validated_output?.status === child.status, "child output/status mismatch");
  requireValue(JSON.stringify(child.validated_output.expected_result_names) === JSON.stringify(ROW_RESULTS[expected.row]), "child expected-result inventory drift");
  requireValue(typeof child.timed_boundary?.upstream === "string" && typeof child.timed_boundary?.outer === "string", "child timed boundary is missing");
  requireValue(child.skip_reason === null, "applicable child unexpectedly skipped");
  if (expected.mode === "score") {
    requireValue(child.tier_attribution?.status === "not_measured_scored_path", "scored child enabled tier attribution");
    requireValue(child.gc?.attribution_status === "not_measured_scored_path", "scored child enabled GC attribution");
  } else {
    requireValue(child.tier_attribution?.status === "measured" && child.gc?.attribution_status === "measured", "attribution child did not measure attribution");
  }
  if (child.status === "passed") {
    requireValue(child.failure === null && child.validated_output.final_score_count === 1, "passed child failure/output drift");
    requireValue(JSON.stringify(child.validated_output.observed_result_names) === JSON.stringify(ROW_RESULTS[expected.row]), "passed child observed-result inventory drift");
    const scores = child.upstream_outputs.filter((event: any) => event.kind === "score");
    requireValue(scores.length === 1, "passed child final-score cardinality drift");
    parsePositive(scores[0].value, "child final score");
    const results = child.upstream_outputs.filter((event: any) => event.kind === "result");
    requireValue(JSON.stringify(results.map((event: any) => event.name)) === JSON.stringify(ROW_RESULTS[expected.row]), "passed child result-event inventory drift");
    results.forEach((event: any) => parsePositive(event.value, `child ${event.name} result`));
  } else requireValue(typeof child.failure === "string" && child.failure.length > 0, "failed child is missing its failure");
}

function parseChild(stdout: string): { child: any | null; failure: string | null } {
  const lines = stdout.split("\n").filter((line) => line.trim().length > 0);
  if (lines.length !== 1) return { child: null, failure: `expected exactly one JSON line, got ${lines.length}` };
  try { return { child: JSON.parse(lines[0]), failure: null }; }
  catch (error) { return { child: null, failure: `invalid child JSON: ${String(error)}` }; }
}

export function retainCompleted(
  completed: Completed,
  expected: { runner: string; checkout: string; row: string; mode: Mode; revision: string; sample: number; collection_order: number; order_in_round: number },
): any {
  const parsed = parseChild(completed.stdout);
  let contractFailure = parsed.failure;
  if (parsed.child && !contractFailure) {
    try { validateChild(parsed.child, expected); }
    catch (error) { contractFailure = String(error); }
  }
  if (!contractFailure && parsed.child) {
    const expectedExit = parsed.child.status === "passed" ? 0 : 1;
    if (completed.timedOut || completed.exitCode !== expectedExit)
      contractFailure = `child status ${parsed.child.status} requires exit ${expectedExit}, got ${completed.timedOut ? "timeout" : completed.exitCode}`;
  }
  return {
    sample_index: expected.sample,
    collection_order: expected.collection_order,
    order_in_round: expected.order_in_round,
    requested_mode: expected.mode,
    command: expectedArgv(expected.runner, expected.checkout, expected.row, expected.mode, expected.revision),
    environment: REQUIRED_ENVIRONMENT,
    process: { exit_code: completed.exitCode, timed_out: completed.timedOut, stderr: completed.stderr },
    raw_stdout: completed.stdout,
    parsed_child: parsed.child,
    contract_validation: { status: contractFailure ? "failed" : "passed", failure: contractFailure },
    retention_status: contractFailure ? "invalid_child" : parsed.child.status === "passed" ? "valid_passed_child" : "valid_failed_child",
  };
}

function passedCaptures(captures: any[]): any[] {
  return captures.filter((capture) => capture.retention_status === "valid_passed_child");
}

function upstreamValues(captures: any[], kind: "result" | "score", name?: string): number[] {
  return passedCaptures(captures).map((capture) => {
    const matches = capture.parsed_child.upstream_outputs.filter((event: any) => event.kind === kind && (name === undefined || event.name === name));
    requireValue(matches.length === 1, `valid child has ${matches.length} ${kind} events for ${name || "aggregate"}`);
    return parsePositive(matches[0].value, `${name || "aggregate"} score`);
  });
}

export function summarizeRow(row: any, plannedScoreSamples: number): any {
  const valid = passedCaptures(row.score_samples), failedIndexes = row.score_samples
    .filter((capture: any) => capture.retention_status !== "valid_passed_child")
    .map((capture: any) => capture.sample_index);
  const resultNames = valid.length
    ? valid[0].parsed_child.validated_output.expected_result_names
    : row.score_samples.find((capture: any) => capture.parsed_child)?.parsed_child?.validated_output?.expected_result_names || [];
  const resultScores: Record<string, any> = {};
  resultNames.forEach((name: string) => resultScores[name] = statistics(upstreamValues(row.score_samples, "result", name)));
  const raw = valid.map((capture: any) => capture.parsed_child.raw_samples[0]);
  return {
    status: !valid.length ? "unavailable_no_valid_samples" : failedIndexes.length || valid.length !== plannedScoreSamples ? "partial_valid_samples" : "measured",
    valid_sample_count: valid.length,
    planned_sample_count: plannedScoreSamples,
    failed_or_invalid_sample_indexes: failedIndexes,
    statistic: "median, range, arithmetic mean, and sample standard deviation divided by absolute mean",
    valid_sample_policy: "Only contract-valid children whose upstream row passed contribute values; every excluded failed/invalid child remains retained beside this summary.",
    result_scores: resultScores,
    selected_row_aggregate_score: statistics(upstreamValues(row.score_samples, "score")),
    outer_wall_ns: statistics(raw.map((sample: any) => sample.outer_wall_ns)),
    cpu_user_ns: statistics(raw.map((sample: any) => sample.cpu_user_ns)),
    cpu_system_ns: statistics(raw.map((sample: any) => sample.cpu_system_ns)),
    peak_rss_bytes_after: statistics(raw.map((sample: any) => sample.peak_rss_bytes_after)),
  };
}

function captureFailure(capture: any): string | null {
  if (capture.contract_validation.status === "failed") return capture.contract_validation.failure;
  if (capture.parsed_child?.status === "failed") return capture.parsed_child.failure;
  return null;
}

function finalizeRows(rows: any[], scoreSamples: number, attributionSamples: number): any[] {
  return rows.map((row) => {
    const failures = [...row.score_samples, ...row.attribution_samples].map(captureFailure).filter(Boolean);
    const complete = row.score_samples.length === scoreSamples && row.attribution_samples.length === attributionSamples;
    return {
      ...row,
      status: complete && failures.length === 0 ? "passed" : "failed",
      failure: failures.length ? failures.join("; ") : complete ? null : "collection incomplete",
      skip_reason: null,
      raw_samples: { score: row.score_samples, attribution: row.attribution_samples },
      dispersion: summarizeRow(row, scoreSamples),
      validated_output: {
        status: complete && failures.length === 0 ? "passed" : "failed",
        score_children: row.score_samples.map((capture: any) => capture.parsed_child?.validated_output || null),
        attribution_children: row.attribution_samples.map((capture: any) => capture.parsed_child?.validated_output || null),
      },
      timed_boundary: row.score_samples.find((capture: any) => capture.parsed_child)?.parsed_child?.timed_boundary || null,
    };
  }).map((row) => {
    const result = { ...row };
    delete result.score_samples;
    delete result.attribution_samples;
    return result;
  });
}

function subsetAggregate(rows: any[], complete: boolean, scoreSamples: number): any {
  const failed = rows.filter((row) => row.status !== "passed").map((row) => row.row);
  if (!complete) return { status: "unavailable", reason: "collection is incomplete", failed_or_incomplete_rows: failed };
  if (failed.length) return { status: "unavailable", reason: "every applicable row must pass before an aggregate is computed", failed_or_incomplete_rows: failed };
  const perSample = Array.from({ length: scoreSamples }, (_, sample) => {
    const rowScores = rows.map((row) => {
      const capture = row.raw_samples.score.find((entry: any) => entry.sample_index === sample);
      return upstreamValues([capture], "score")[0];
    });
    return { sample_index: sample, row_scores: Object.fromEntries(rows.map((row, index) => [row.row, rowScores[index]])), geometric_mean: Math.exp(rowScores.reduce((total, value) => total + Math.log(value), 0) / rowScores.length) };
  });
  return {
    status: "available",
    name: "selected-six-result-subset-geometric-score",
    claim_boundary: "This is a selected non-browser Octane subset, not the full official Octane or a browser score.",
    per_sample: perSample,
    dispersion: statistics(perSample.map((sample) => sample.geometric_mean)),
  };
}

function publicationStatus(complete: boolean, rows: any[], scoreSamples: number, hostClass: string, environment: any): any {
  const reasons: string[] = [];
  if (!complete) reasons.push("collection incomplete");
  if (rows.some((row) => row.status !== "passed")) reasons.push("one or more applicable rows failed");
  if (scoreSamples < 7) reasons.push("fewer than seven score samples per row");
  if (hostClass !== "quiet_reference") reasons.push("host class is diagnostic");
  if (!String(environment.Power || "").includes("AC Power")) reasons.push("host power state is not confirmed AC");
  return reasons.length
    ? { status: "diagnostic_not_publishable", reasons }
    : { status: "suite_specific_evidence_eligible", reasons: [] };
}

function materialize(state: any, complete: boolean): any {
  const rows = finalizeRows(state.rows, state.score_samples, state.attribution_samples);
  return {
    schema_version: 1,
    kind: "zig-js-independent-suite-collection",
    collection_id: "zig-js-octane-selected-subset-v1",
    complete,
    suite: "octane-2-retired",
    suite_revision: SUITE_REVISION,
    suite_tree: SUITE_TREE,
    suite_checkout: state.checkout,
    engine: {
      id: "zig-js",
      runner_path: state.runner,
      source_revision: state.revision,
      process_model: "one fresh isolated adapter process per child sample",
    },
    adapter: "zig-js-octane-minimal-shell-v1",
    host: { class: state.host_class, environment: state.host_environment },
    sample_plan: {
      score_samples_per_row: state.score_samples,
      attribution_samples_per_row: state.attribution_samples,
      score_and_attribution_separate: true,
      row_order: "inventory order rotated by sample index",
      timeout_ms_per_child: state.timeout_ms,
    },
    artifact_policy: {
      checkpoint: "atomically replaced after every child process",
      output_location: "outside the zig-js worktree so child clean-revision verification remains exact",
      execution_guard: `child evaluation-step budget ${EVALUATION_STEP_BUDGET}; collector per-process timeout owns termination`,
      failed_child_retention: "raw stdout, parsed JSON when available, stderr, exit status, timeout state, and contract validation are never dropped",
      aggregate: "unavailable unless collection is complete and every applicable row passes",
    },
    publication_status: publicationStatus(complete, rows, state.score_samples, state.host_class, state.host_environment),
    rows,
    aggregate: subsetAggregate(rows, complete, state.score_samples),
  };
}

export function validateArtifact(artifact: any): void {
  requireValue(artifact?.schema_version === 1 && artifact.kind === "zig-js-independent-suite-collection", "collection schema identity drift");
  requireValue(artifact.suite_revision === SUITE_REVISION && artifact.suite_tree === SUITE_TREE, "collection suite identity drift");
  requireValue(typeof artifact.suite_checkout === "string" && artifact.suite_checkout.length > 0, "collection suite checkout is missing");
  requireValue(JSON.stringify(artifact.rows.map((row: any) => row.row)) === JSON.stringify(ROWS), "collection row inventory drift");
  requireValue(artifact.sample_plan.score_samples_per_row >= 2 && artifact.sample_plan.attribution_samples_per_row >= 1, "collection sample plan is invalid");
  const identities: string[] = [], timedBoundaries: string[] = [];
  for (const row of artifact.rows) {
    requireValue(["passed", "failed"].includes(row.status) && row.skip_reason === null, `${row.row} row status drift`);
    requireValue(JSON.stringify(row.licenses) === JSON.stringify(ROW_LICENSES[row.row]), `${row.row} license identity drift`);
    for (const mode of ["score", "attribution"] as Mode[]) {
      const captures = row.raw_samples[mode], planned = artifact.sample_plan[`${mode}_samples_per_row`];
      requireValue(Array.isArray(captures) && captures.length <= planned, `${row.row} ${mode} sample cardinality drift`);
      if (artifact.complete) requireValue(captures.length === planned, `${row.row} ${mode} collection is incomplete`);
      const indexes = captures.map((capture: any) => capture.sample_index).sort((left: number, right: number) => left - right);
      requireValue(JSON.stringify(indexes) === JSON.stringify(Array.from({ length: captures.length }, (_, index) => index)), `${row.row} ${mode} sample indexes drift`);
      captures.forEach((capture: any) => {
        requireValue(typeof capture.raw_stdout === "string" && typeof capture.process.stderr === "string", `${row.row} ${mode} raw child output is missing`);
        requireValue(["valid_passed_child", "valid_failed_child", "invalid_child"].includes(capture.retention_status), `${row.row} ${mode} retention status drift`);
        requireValue(JSON.stringify(capture.command) === JSON.stringify(expectedArgv(artifact.engine.runner_path, artifact.suite_checkout, row.row, mode, artifact.engine.source_revision)), `${row.row} ${mode} command identity drift`);
        if (capture.parsed_child && capture.contract_validation.status === "passed") {
          validateChild(capture.parsed_child, { runner: artifact.engine.runner_path, checkout: artifact.suite_checkout, row: row.row, mode, revision: artifact.engine.source_revision });
          identities.push(JSON.stringify([capture.parsed_child.engine.executable_path, capture.parsed_child.engine.executable_sha256, capture.parsed_child.engine.source_revision]));
          timedBoundaries.push(JSON.stringify(capture.parsed_child.timed_boundary));
        }
      });
    }
    requireValue(JSON.stringify(row.dispersion) === JSON.stringify(summarizeRow({ score_samples: row.raw_samples.score }, artifact.sample_plan.score_samples_per_row)), `${row.row} dispersion drift`);
  }
  requireValue(new Set(identities).size <= 1, "child executable/source identity changed within collection");
  requireValue(new Set(timedBoundaries).size <= 1, "child timed boundary changed within collection");
  const failed = artifact.rows.some((row: any) => row.status !== "passed");
  requireValue(artifact.aggregate.status === (artifact.complete && !failed ? "available" : "unavailable"), "aggregate fail-closed policy drift");
  if (artifact.aggregate.status === "available") requireValue(artifact.aggregate.per_sample.length === artifact.sample_plan.score_samples_per_row, "aggregate sample inventory drift");
  if (artifact.publication_status.status === "suite_specific_evidence_eligible") {
    requireValue(artifact.complete && !failed && artifact.sample_plan.score_samples_per_row >= 7, "publishable collection is incomplete");
    requireValue(artifact.host.class === "quiet_reference" && String(artifact.host.environment.Power).includes("AC Power"), "publishable collection host gate drift");
  }
}

function parentDirectory(path: string): string {
  const slash = path.lastIndexOf("/");
  return slash <= 0 ? "." : path.slice(0, slash);
}

function assertExternalOutput(output: string): void {
  requireValue(output.startsWith("/"), "collection output must be an absolute path");
  const root = checked(["git", "rev-parse", "--show-toplevel"], "resolve zig-js root").trim();
  const parent = checked(["realpath", parentDirectory(output)], "resolve collection output parent").trim();
  requireValue(parent !== root && !parent.startsWith(root + "/"), "collection output must remain outside the zig-js worktree during child sampling");
}

function atomicWrite(path: string, contents: string): void {
  const created = run(["mktemp", `${path}.tmp.XXXXXX`]);
  requireValue(created.exitCode === 0, created.stderr || `cannot create temporary artifact beside ${path}`);
  const temporary = created.stdout.trim();
  try {
    writeText(temporary, contents);
    const moved = run(["mv", "-f", temporary, path]);
    requireValue(moved.exitCode === 0, moved.stderr || `cannot atomically replace ${path}`);
  } catch (error) {
    run(["rm", "-f", temporary]);
    throw error;
  }
}

function checkpoint(state: any, output: string, complete: boolean): any {
  const artifact = materialize(state, complete);
  validateArtifact(artifact);
  atomicWrite(output, JSON.stringify(artifact, null, 2) + "\n");
  return artifact;
}

function syntheticChild(row: string, mode: Mode, status: "passed" | "failed", runner = "/tmp/runner", checkout = "/tmp/octane", revision = "a".repeat(40)): any {
  const passed = status === "passed";
  return {
    schema_version: 1, kind: "zig-js-independent-suite-sample", suite: "octane-2-retired", suite_revision: SUITE_REVISION, suite_tree: SUITE_TREE,
    row, licenses: ROW_LICENSES[row], mode, publication_status: "diagnostic_single_sample",
    engine: { id: "zig-js", executable_path: runner, executable_sha256: "b".repeat(64), source_revision: revision, version_output: "fixture", argv: expectedArgv(runner, checkout, row, mode, revision), environment: REQUIRED_ENVIRONMENT, separate_process: true },
    adapter: { id: "zig-js-octane-minimal-shell-v1", host_globals: ["load", "print"], source_transform: false, evaluation_step_budget: EVALUATION_STEP_BUDGET, termination_boundary: TERMINATION_BOUNDARY, loaded_sources: [BASE_SOURCE, ROW_SOURCES[row]] },
    status, failure: passed ? null : "fixture failure", skip_reason: null,
    upstream_outputs: passed ? [...ROW_RESULTS[row].map((name) => ({ kind: "result", name, value: "100" })), { kind: "score", name: "selected-geometric-aggregate", value: "200" }] : [{ kind: "error", name: ROW_RESULTS[row][0], value: "fixture failure" }],
    auxiliary_outputs: [], raw_samples: [{ index: 0, mode, instrumentation_enabled: mode === "attribution", outer_wall_ns: 100, cpu_user_ns: 80, cpu_system_ns: 20, peak_rss_bytes_before: 10, peak_rss_bytes_after: 20 }],
    dispersion: { status: "not_applicable_single_sample", sample_count: 1, statistic: null },
    validated_output: { status, expected_result_names: ROW_RESULTS[row], observed_result_names: passed ? ROW_RESULTS[row] : [], final_score_count: passed ? 1 : 0 },
    timed_boundary: { upstream: "fixture upstream", outer: "fixture outer" },
    tier_attribution: { status: mode === "attribution" ? "measured" : "not_measured_scored_path" },
    gc: { attribution_status: mode === "attribution" ? "measured" : "not_measured_scored_path" },
  };
}

function expectFailure(action: () => void, pattern: string): void {
  try { action(); } catch (error) { requireValue(String(error).includes(pattern), `expected ${pattern}, got ${String(error)}`); return; }
  throw new Error(`expected failure containing ${pattern}`);
}

export function selfTest(): void {
  const runner = "/tmp/runner", checkout = "/tmp/octane", revision = "a".repeat(40);
  const capture = (row: string, mode: Mode, sample: number, status: "passed" | "failed") => retainCompleted({ exitCode: status === "passed" ? 0 : 1, stdout: JSON.stringify(syntheticChild(row, mode, status)) + "\n", stderr: status === "passed" ? "" : "fixture diagnostic", timedOut: false }, { runner, checkout, row, mode, revision, sample, collection_order: sample, order_in_round: 0 });
  const state: any = { runner, checkout, revision, host_class: "diagnostic", host_environment: { Power: "Battery Power" }, score_samples: 2, attribution_samples: 1, timeout_ms: 1000, rows: ROWS.map((row) => ({ row, licenses: ROW_LICENSES[row], score_samples: [capture(row, "score", 0, "passed"), capture(row, "score", 1, row === "regexp" ? "failed" : "passed")], attribution_samples: [capture(row, "attribution", 0, "passed")] })) };
  const artifact = materialize(state, true);
  validateArtifact(artifact);
  requireValue(artifact.rows.find((row: any) => row.row === "regexp").raw_samples.score[1].parsed_child.failure === "fixture failure", "failed child was not retained");
  requireValue(artifact.rows.find((row: any) => row.row === "regexp").dispersion.valid_sample_count === 1, "failed child contaminated dispersion");
  requireValue(artifact.aggregate.status === "unavailable" && artifact.aggregate.failed_or_incomplete_rows.includes("regexp"), "aggregate did not fail closed");
  const malformed = retainCompleted({ exitCode: 7, stdout: "not json\n", stderr: "broken", timedOut: false }, { runner, checkout, row: "richards", mode: "score", revision, sample: 0, collection_order: 0, order_in_round: 0 });
  requireValue(malformed.retention_status === "invalid_child" && malformed.raw_stdout === "not json\n", "malformed child was not retained losslessly");
  const allPassed = JSON.parse(JSON.stringify(state));
  allPassed.rows.find((row: any) => row.row === "regexp").score_samples[1] = capture("regexp", "score", 1, "passed");
  const complete = materialize(allPassed, true); validateArtifact(complete);
  requireValue(complete.aggregate.status === "available" && complete.aggregate.per_sample.length === 2, "complete aggregate was not computed");
  const drift = JSON.parse(JSON.stringify(complete)); drift.rows[0].raw_samples.score[0].parsed_child.engine.executable_sha256 = "e".repeat(64);
  expectFailure(() => validateArtifact(drift), "identity changed");
  const guardDrift = JSON.parse(JSON.stringify(complete)); guardDrift.rows[0].raw_samples.score[0].parsed_child.adapter.evaluation_step_budget = "500000000";
  expectFailure(() => validateArtifact(guardDrift), "evaluation-step budget drift");
  const temporary = temporaryDirectory("zig-js-independent-suite-collector");
  try {
    const output = `${temporary}/artifact.json`, written = checkpoint(state, output, true);
    requireValue(JSON.stringify(JSON.parse(readText(output))) === JSON.stringify(written), "atomic checkpoint bytes drift");
  } finally { removeTemporaryDirectory(temporary); }
  console.log("OK independent-suite collector self-test: child validation, lossless failures, valid-only dispersion, checkpoints, and fail-closed aggregate verified");
}

function main(): void {
  const args = process.argv.slice(2);
  if (args.length === 1 && args[0] === "--self-test") { selfTest(); return; }
  const runner = args[0], checkout = args[1], revision = args[2];
  requireValue(Boolean(runner && checkout) && /^[0-9a-f]{40}$/.test(revision || ""), "usage: independent-suite-collector <runner> <verified-checkout> <zig-js-revision> --output <absolute-external-path> [--score-samples N] [--attribution-samples N] [--host-class diagnostic|quiet_reference] [--timeout-ms N]");
  requireValue(runner.startsWith("/") && checkout.startsWith("/"), "runner and verified checkout paths must be absolute");
  let output = "", scoreSamples = 7, attributionSamples = 1, hostClass = "diagnostic", timeoutMs = 15 * 60 * 1000;
  for (let index = 3; index < args.length; index += 1) {
    const name = args[index], value = args[++index];
    if (name === "--output") output = value;
    else if (name === "--score-samples") scoreSamples = Number(value);
    else if (name === "--attribution-samples") attributionSamples = Number(value);
    else if (name === "--host-class") hostClass = value;
    else if (name === "--timeout-ms") timeoutMs = Number(value);
    else throw new Error(`unknown argument: ${name}`);
  }
  requireValue(scoreSamples >= 2 && Number.isInteger(scoreSamples), "score samples must be an integer of at least two");
  requireValue(attributionSamples >= 1 && Number.isInteger(attributionSamples), "attribution samples must be a positive integer");
  requireValue(Number.isInteger(timeoutMs) && timeoutMs > 0, "child timeout must be a positive integer");
  requireValue(["diagnostic", "quiet_reference"].includes(hostClass), "host class must be diagnostic or quiet_reference");
  requireValue(Boolean(output), "collection output is required");
  assertExternalOutput(output);
  const hostEnvironment = metadata();
  requireValue(hostEnvironment["zig-js"] === revision, `collector source revision ${hostEnvironment["zig-js"]} != requested ${revision}`);
  if (hostClass === "quiet_reference") requireValue(hostEnvironment.Power.includes("AC Power"), "quiet-reference collection requires AC power");
  const state: any = { runner, checkout, revision, host_class: hostClass, host_environment: hostEnvironment, score_samples: scoreSamples, attribution_samples: attributionSamples, timeout_ms: timeoutMs, rows: ROWS.map((row) => ({ row, licenses: ROW_LICENSES[row], score_samples: [], attribution_samples: [] })) };
  checkpoint(state, output, false);
  let collectionOrder = 0;
  for (const mode of ["score", "attribution"] as Mode[]) {
    const samples = mode === "score" ? scoreSamples : attributionSamples;
    for (let sample = 0; sample < samples; sample += 1) {
      const order = ROWS.map((_, index) => ROWS[(index + sample) % ROWS.length]);
      for (let position = 0; position < order.length; position += 1) {
        const rowName = order[position], command = expectedArgv(runner, checkout, rowName, mode, revision);
        console.error(`+ ${["env", "TZ=UTC", "LC_ALL=C", "LANG=C", ...command].join(" ")}`);
        const completed = run(["env", "TZ=UTC", "LC_ALL=C", "LANG=C", ...command], { timeoutMs });
        const capture = retainCompleted(completed, { runner, checkout, row: rowName, mode, revision, sample, collection_order: collectionOrder++, order_in_round: position });
        const row = state.rows.find((entry: any) => entry.row === rowName);
        row[mode === "score" ? "score_samples" : "attribution_samples"].push(capture);
        checkpoint(state, output, false);
      }
    }
  }
  const artifact = checkpoint(state, output, true);
  process.stdout.write(JSON.stringify({ output, complete: artifact.complete, publication_status: artifact.publication_status, rows: artifact.rows.map((row: any) => ({ row: row.row, status: row.status, valid_score_samples: row.dispersion.valid_sample_count })), aggregate: artifact.aggregate.status }, null, 2) + "\n");
  requireValue(artifact.aggregate.status === "available", `collection retained failures; aggregate unavailable in ${output}`);
}

if (process.argv[1] === __filename) main();
