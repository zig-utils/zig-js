/** Measure the runtime cost of opt-in execution attribution against its disabled path. */
import { ensurePublishable, metadata } from "./benchmark-comparison";
import { DEFAULT_MANIFEST, loadManifest, validate as validateManifest } from "./representative-matrix";
import { run, sha256File, writeText } from "./lib/home";

declare const __filename: string;

type State = "disabled" | "enabled";
type Measurement = {
  wall_time_ns: number;
  process_cpu_user_ns: number;
  process_cpu_system_ns: number;
  peak_rss_bytes: number;
  instructions: number;
  cycles: number;
  voluntary_context_switches: number;
  involuntary_context_switches: number;
};
type Sample = {
  identity: {
    pair_sample: number;
    order: number;
    state: State;
    mode: "single" | "single_profiled";
    workload: string;
    jobs: number;
    checksum: number;
  };
  metrics: Measurement;
};

function requireValue(condition: boolean, message: string): void {
  if (!condition) throw new Error(message);
}

function timeMetric(stderr: string, label: string): number {
  const match = new RegExp(`(?:^|\\s)([0-9.]+)\\s+${label}(?:\\s|$)`).exec(stderr);
  requireValue(Boolean(match), `missing ${label} from /usr/bin/time -l`);
  return Number(match![1]);
}

export function parseRow(
  stdout: string,
  mode: "single" | "single_profiled",
  workload: string,
  jobs: number,
): { wall_time_ns: number; checksum: number } {
  const rows = stdout.split("\n").filter((line) => line.startsWith("zig-js\t"));
  requireValue(rows.length === 1, `expected one benchmark row, got ${rows.length}`);
  const fields = rows[0].split("\t");
  requireValue(fields.length === 8, `benchmark row width is ${fields.length}, expected 8`);
  requireValue(
    fields[0] === "zig-js" && fields[1] === mode && fields[2] === workload,
    `benchmark identity drift: ${JSON.stringify(fields.slice(0, 3))}`,
  );
  requireValue(
    Number(fields[3]) === 1 && Number(fields[4]) === jobs && Number(fields[5]) === 0,
    "benchmark lane/jobs/sample identity drift",
  );
  return { wall_time_ns: Number(fields[6]), checksum: Number(fields[7]) };
}

function runOne(
  runner: string,
  state: State,
  workload: string,
  jobs: number,
): { mode: "single" | "single_profiled"; measurement: Measurement; checksum: number } {
  const mode = state === "disabled" ? "single" : "single_profiled";
  const command = ["env", "LC_ALL=C", "/usr/bin/time", "-l", runner, mode, workload, String(jobs), "1"];
  console.error(`+ ${command.join(" ")}`);
  const completed = run(command);
  requireValue(completed.exitCode === 0, completed.stderr || `benchmark exited ${completed.exitCode}`);
  const row = parseRow(completed.stdout, mode, workload, jobs);
  return {
    mode,
    checksum: row.checksum,
    measurement: {
      wall_time_ns: row.wall_time_ns,
      process_cpu_user_ns: Math.round(timeMetric(completed.stderr, "user") * 1e9),
      process_cpu_system_ns: Math.round(timeMetric(completed.stderr, "sys") * 1e9),
      peak_rss_bytes: Math.round(timeMetric(completed.stderr, "maximum resident set size")),
      instructions: Math.round(timeMetric(completed.stderr, "instructions retired")),
      cycles: Math.round(timeMetric(completed.stderr, "cycles elapsed")),
      voluntary_context_switches: Math.round(timeMetric(completed.stderr, "voluntary context switches")),
      involuntary_context_switches: Math.round(timeMetric(completed.stderr, "involuntary context switches")),
    },
  };
}

export function collect(
  runner: string,
  workload: string,
  jobs: number,
  expectedChecksum: number,
  pairs: number,
): Sample[] {
  requireValue(pairs >= 2, "instrumentation overhead requires at least two alternating pairs");
  const samples: Sample[] = [];
  for (let pair = 0; pair < pairs; pair += 1) {
    const order: State[] = pair % 2 === 0 ? ["disabled", "enabled"] : ["enabled", "disabled"];
    order.forEach((state, position) => {
      const row = runOne(runner, state, workload, jobs);
      requireValue(
        row.checksum === expectedChecksum,
        `${state} pair ${pair} checksum ${row.checksum} != frozen ${expectedChecksum}`,
      );
      samples.push({
        identity: { pair_sample: pair, order: position, state, mode: row.mode, workload, jobs, checksum: row.checksum },
        metrics: row.measurement,
      });
    });
  }
  return samples;
}

const median = (values: number[]): number => {
  const sorted = values.slice().sort((left, right) => left - right), middle = Math.floor(sorted.length / 2);
  return sorted.length % 2 ? sorted[middle] : (sorted[middle - 1] + sorted[middle]) / 2;
};

export function summarize(samples: Sample[]): any {
  const result: any = {};
  for (const metric of ["wall_time_ns", "process_cpu_user_ns", "process_cpu_system_ns", "peak_rss_bytes", "instructions", "cycles", "voluntary_context_switches", "involuntary_context_switches"] as const) {
    const disabled = median(samples.filter((sample) => sample.identity.state === "disabled").map((sample) => sample.metrics[metric])),
      enabled = median(samples.filter((sample) => sample.identity.state === "enabled").map((sample) => sample.metrics[metric])),
      jobs = samples[0].identity.jobs;
    result[metric] = { disabled_median: disabled, enabled_median: enabled, enabled_over_disabled: disabled === 0 ? null : enabled / disabled, disabled_per_job: disabled / jobs, enabled_per_job: enabled / jobs };
  }
  return result;
}

export function validateArtifact(artifact: any): void {
  requireValue(artifact.schema_version === 1 && artifact.profile_id === "zig-js-instrumentation-overhead-v1", "overhead schema identity drift");
  requireValue(artifact.metadata && artifact.metadata.pairs >= 2, "overhead metadata is incomplete");
  requireValue(/^[0-9a-f]{64}$/.test(artifact.metadata.runner_sha256), "runner hash is invalid");
  requireValue(Number.isInteger(artifact.metadata.runner_size_bytes) && artifact.metadata.runner_size_bytes > 0, "runner size is invalid");
  const samples: Sample[] = artifact.samples;
  requireValue(samples.length === artifact.metadata.pairs * 2, "overhead pair inventory drift");
  for (let pair = 0; pair < artifact.metadata.pairs; pair += 1) {
    const rows = samples.filter((sample) => sample.identity.pair_sample === pair).sort((left, right) => left.identity.order - right.identity.order),
      expected: State[] = pair % 2 === 0 ? ["disabled", "enabled"] : ["enabled", "disabled"];
    requireValue(rows.length === 2 && rows[0].identity.state === expected[0] && rows[1].identity.state === expected[1], `pair ${pair} order drift`);
    requireValue(new Set(rows.map((row) => row.identity.checksum)).size === 1, `pair ${pair} checksum drift`);
    for (const row of rows) {
      requireValue(row.identity.mode === (row.identity.state === "disabled" ? "single" : "single_profiled"), `pair ${pair} mode/state drift`);
      requireValue(row.identity.workload === artifact.metadata.workload && row.identity.jobs === artifact.metadata.jobs && row.identity.checksum === artifact.metadata.expected_checksum, `pair ${pair} metadata identity drift`);
      requireValue(Object.values(row.metrics).every((value) => Number.isFinite(value) && value >= 0), `pair ${pair} metric is invalid`);
    }
  }
  requireValue(artifact.boundaries.retained_rss.status === "unavailable", "retained RSS must remain explicit");
  requireValue(artifact.boundaries.contention.status === "not_applicable", "single-thread contention boundary drift");
  requireValue(artifact.boundaries.code_size.status === "same_binary", "runtime toggle must identify the same binary");
}

export function render(artifact: any): string {
  const summary = artifact.summary, metadata_ = artifact.metadata;
  const rows = [
    `# Instrumentation overhead — ${metadata_.workload}`,
    "",
    `- zig-js: \`${metadata_.revision}\``,
    `- runner: \`${metadata_.runner_sha256}\` (${metadata_.runner_size_bytes} bytes; one binary for both states)`,
    `- sampling: ${metadata_.pairs} alternating disabled/enabled pairs; no discarded samples`,
    `- logical work: ${metadata_.jobs} jobs; frozen checksum ${metadata_.expected_checksum}`,
    `- timed boundary: ${metadata_.timed_boundary}`,
    "",
    "| metric | disabled median | enabled median | enabled / disabled |",
    "| --- | ---: | ---: | ---: |",
  ];
  for (const [name, unit] of [["wall_time_ns", "ns"], ["process_cpu_user_ns", "ns"], ["process_cpu_system_ns", "ns"], ["peak_rss_bytes", "bytes"], ["instructions", "count"], ["cycles", "count"], ["voluntary_context_switches", "count"], ["involuntary_context_switches", "count"]]) {
    const metric = summary[name];
    rows.push(`| \`${name}\` | ${metric.disabled_median} ${unit} | ${metric.enabled_median} ${unit} | ${metric.enabled_over_disabled === null ? "N/A" : metric.enabled_over_disabled.toFixed(4) + "x"} |`);
  }
  rows.push(
    "",
    "Retained RSS is unavailable because each measurement exits after one sample. Lock contention is not applicable to this single-thread fixture. Both states use the exact same runner, so this runtime-toggle A/B does not claim to measure compile-time support code size.",
    "",
  );
  return rows.join("\n");
}

function syntheticSamples(): Sample[] {
  const rows: Sample[] = [];
  for (let pair = 0; pair < 2; pair += 1) {
    const order: State[] = pair % 2 === 0 ? ["disabled", "enabled"] : ["enabled", "disabled"];
    order.forEach((state, position) => rows.push({
      identity: { pair_sample: pair, order: position, state, mode: state === "disabled" ? "single" : "single_profiled", workload: "representative_json", jobs: 110, checksum: 5864992 },
      metrics: { wall_time_ns: state === "disabled" ? 100 : 102, process_cpu_user_ns: 80, process_cpu_system_ns: 20, peak_rss_bytes: 10_000_000, instructions: 1000, cycles: 500, voluntary_context_switches: 1, involuntary_context_switches: 2 },
    }));
  }
  return rows;
}

function expectFailure(action: () => void, pattern: string): void {
  try { action(); } catch (error) { requireValue(String(error).includes(pattern), `expected ${pattern}, got ${String(error)}`); return; }
  throw new Error(`expected failure containing ${pattern}`);
}

export function selfTest(): void {
  const stdout = "zig-js\tsingle_profiled\trepresentative_json\t1\t110\t0\t60000000\t5864992\n";
  requireValue(parseRow(stdout, "single_profiled", "representative_json", 110).checksum === 5864992, "profiled row parse drift");
  expectFailure(() => parseRow(stdout, "single", "representative_json", 110), "identity drift");
  const timing = "        0.07 real         0.06 user         0.00 sys\n            87605248  maximum resident set size\n          1088205673  instructions retired\n           243071578  cycles elapsed\n";
  requireValue(timeMetric(timing, "user") === 0.06 && timeMetric(timing, "maximum resident set size") === 87605248 && timeMetric(timing, "cycles elapsed") === 243071578, "macOS time layout parse drift");
  const samples = syntheticSamples(), artifact = {
    schema_version: 1,
    profile_id: "zig-js-instrumentation-overhead-v1",
    metadata: { pairs: 2, runner_sha256: "a".repeat(64), runner_size_bytes: 1, workload: "representative_json", jobs: 110, expected_checksum: 5864992 },
    samples,
    summary: summarize(samples),
    boundaries: { retained_rss: { status: "unavailable" }, contention: { status: "not_applicable" }, code_size: { status: "same_binary" } },
  };
  validateArtifact(artifact);
  const order = JSON.parse(JSON.stringify(artifact)); order.samples[2].identity.state = "disabled";
  expectFailure(() => validateArtifact(order), "order drift");
  console.log("OK instrumentation overhead self-test: parsing, alternation, checksums, metrics, and explicit boundaries verified");
}

function resolveWorkload(manifest: any, workload: string, quick: boolean): { jobs: number; checksum: number; source: string } {
  for (const family of manifest.implemented_families) {
    for (const role of ["base", "variant"]) if (family[role] === workload) {
      requireValue(!family.availability || family.availability.kind !== "zig_js_module_capability", "module workloads require their dedicated lifecycle mode");
      const scale = quick ? "quick" : "full";
      return { jobs: family.jobs[scale], checksum: family.checksums[role][scale][0], source: family.source || "bench/representative_comparison.js" };
    }
  }
  throw new Error(`workload is absent from the representative matrix: ${workload}`);
}

function main(): void {
  const args = process.argv.slice(2);
  if (args.length === 1 && args[0] === "--self-test") { selfTest(); return; }
  const runner = args[0];
  requireValue(Boolean(runner) && Home.fileExists(runner), "instrumentation overhead runner does not exist");
  let manifestPath = DEFAULT_MANIFEST, workload = "representative_json", pairs = 7, rawOut = "", markdownOut = "", quick = false;
  for (let index = 1; index < args.length; index += 1) {
    const name = args[index];
    if (name === "--quick") quick = true;
    else {
      const value = args[++index];
      if (name === "--manifest") manifestPath = value;
      else if (name === "--workload") workload = value;
      else if (name === "--pairs") pairs = Number(value);
      else if (name === "--raw-out") rawOut = value;
      else if (name === "--markdown-out") markdownOut = value;
      else throw new Error(`unknown argument: ${name}`);
    }
  }
  if (quick && pairs === 7) pairs = 2;
  requireValue(Boolean(rawOut) === Boolean(markdownOut), "raw and Markdown overhead outputs must be written together");
  const manifest = loadManifest(manifestPath); validateManifest(manifest);
  const resolved = resolveWorkload(manifest, workload, quick), info = metadata();
  ensurePublishable(info, Boolean(rawOut));
  const samples = collect(runner, workload, resolved.jobs, resolved.checksum, pairs), size = Number(run(["/usr/bin/stat", "-f", "%z", runner]).stdout.trim());
  const artifact = {
    schema_version: 1,
    profile_id: "zig-js-instrumentation-overhead-v1",
    metadata: {
      environment: info,
      revision: info["zig-js"],
      runner_sha256: sha256File(runner),
      runner_size_bytes: size,
      workload,
      workload_source: resolved.source,
      workload_source_sha256: sha256File(resolved.source),
      jobs: resolved.jobs,
      expected_checksum: resolved.checksum,
      pairs,
      timed_boundary: "one warmed single-context invocation; process CPU and peak RSS cover the fresh runner process",
    },
    samples,
    summary: summarize(samples),
    boundaries: {
      retained_rss: { status: "unavailable", reason: "the fresh runner process exits after each sample" },
      contention: { status: "not_applicable", reason: "the fixture uses one JavaScript thread and one context" },
      code_size: { status: "same_binary", value: size, reason: "runtime-disabled and runtime-enabled states execute the exact same binary" },
    },
  };
  validateArtifact(artifact);
  const report = render(artifact);
  if (rawOut) { writeText(rawOut, JSON.stringify(artifact, null, 2) + "\n"); writeText(markdownOut, report); }
  process.stdout.write(report);
}

if (process.argv[1] === __filename) main();
