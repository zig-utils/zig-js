/** Measure the runtime cost of the complete opt-in attribution sink against its disabled path. */
import { ensurePublishable, metadata } from "./benchmark-comparison";
import { DEFAULT_MANIFEST, loadManifest, validate as validateManifest } from "./representative-matrix";
import { run, sha256File, writeText } from "./lib/home";

declare const __filename: string;

type State = "disabled" | "enabled";
const COUNTER_NAMES = ["instructions", "cycles", "voluntary_context_switches", "involuntary_context_switches"] as const;
type CounterName = typeof COUNTER_NAMES[number];
const COUNTER_LABELS: Record<CounterName, string> = {
  instructions: "instructions retired",
  cycles: "cycles elapsed",
  voluntary_context_switches: "voluntary context switches",
  involuntary_context_switches: "involuntary context switches",
};
type CounterObservation =
  | { status: "measured"; value: number }
  | { status: "unavailable" | "permission_denied"; reason: string };
type CounterMeasurements = Record<CounterName, CounterObservation>;
type Measurement = {
  wall_time_ns: number;
  process_cpu_user_ns: number;
  process_cpu_system_ns: number;
  peak_rss_bytes: number;
} & CounterMeasurements;
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

function counterObservation(stderr: string, label: string): CounterObservation {
  const match = new RegExp(`(?:^|\\s)([0-9.]+)\\s+${label}(?:\\s|$)`).exec(stderr);
  if (match) return { status: "measured", value: Math.round(Number(match[1])) };
  if (/permission denied|operation not permitted|not authorized/i.test(stderr))
    return { status: "permission_denied", reason: `${label} was denied by the platform interface` };
  return { status: "unavailable", reason: `${label} was not reported by /usr/bin/time -l` };
}

function parseCounters(stderr: string): CounterMeasurements {
  return {
    instructions: counterObservation(stderr, COUNTER_LABELS.instructions),
    cycles: counterObservation(stderr, COUNTER_LABELS.cycles),
    voluntary_context_switches: counterObservation(stderr, COUNTER_LABELS.voluntary_context_switches),
    involuntary_context_switches: counterObservation(stderr, COUNTER_LABELS.involuntary_context_switches),
  };
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
  const counters = parseCounters(completed.stderr);
  return {
    mode,
    checksum: row.checksum,
    measurement: {
      wall_time_ns: row.wall_time_ns,
      process_cpu_user_ns: Math.round(timeMetric(completed.stderr, "user") * 1e9),
      process_cpu_system_ns: Math.round(timeMetric(completed.stderr, "sys") * 1e9),
      peak_rss_bytes: Math.round(timeMetric(completed.stderr, "maximum resident set size")),
      ...counters,
    },
  };
}

type NoOpSample = { sample: number; counters: CounterMeasurements };

function collectNoOp(repetitions: number): NoOpSample[] {
  const samples: NoOpSample[] = [];
  for (let sample = 0; sample < repetitions; sample += 1) {
    const command = ["env", "LC_ALL=C", "/usr/bin/time", "-l", "/usr/bin/true"];
    console.error(`+ ${command.join(" ")}`);
    const completed = run(command);
    requireValue(completed.exitCode === 0, completed.stderr || `no-op calibration exited ${completed.exitCode}`);
    samples.push({ sample, counters: parseCounters(completed.stderr) });
  }
  return samples;
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

function measuredValues(observations: CounterObservation[]): number[] {
  return observations.filter((value): value is { status: "measured"; value: number } => value.status === "measured").map((value) => value.value);
}

function observationStatus(observations: CounterObservation[]): "measured" | "unavailable" | "permission_denied" {
  if (observations.some((value) => value.status === "permission_denied")) return "permission_denied";
  if (observations.some((value) => value.status === "unavailable")) return "unavailable";
  return "measured";
}

function dispersion(values: number[]): { samples: number; median: number | null; relative_standard_deviation: number | null; status: "stable" | "noisy" | "indeterminate" } {
  if (values.length < 2) return { samples: values.length, median: values.length ? median(values) : null, relative_standard_deviation: null, status: "indeterminate" };
  const mean = values.reduce((total, value) => total + value, 0) / values.length;
  if (mean === 0) return { samples: values.length, median: median(values), relative_standard_deviation: null, status: "indeterminate" };
  const variance = values.reduce((total, value) => total + (value - mean) ** 2, 0) / values.length;
  const rsd = Math.sqrt(variance) / mean;
  return { samples: values.length, median: median(values), relative_standard_deviation: rsd, status: rsd <= 0.05 ? "stable" : "noisy" };
}

export function summarize(samples: Sample[]): any {
  const result: any = {};
  for (const metric of ["wall_time_ns", "process_cpu_user_ns", "process_cpu_system_ns", "peak_rss_bytes"] as const) {
    const disabled = median(samples.filter((sample) => sample.identity.state === "disabled").map((sample) => sample.metrics[metric])),
      enabled = median(samples.filter((sample) => sample.identity.state === "enabled").map((sample) => sample.metrics[metric])),
      jobs = samples[0].identity.jobs;
    result[metric] = { disabled_median: disabled, enabled_median: enabled, enabled_over_disabled: disabled === 0 ? null : enabled / disabled, disabled_per_job: disabled / jobs, enabled_per_job: enabled / jobs };
  }
  for (const metric of COUNTER_NAMES) {
    const disabledObservations = samples.filter((sample) => sample.identity.state === "disabled").map((sample) => sample.metrics[metric]);
    const enabledObservations = samples.filter((sample) => sample.identity.state === "enabled").map((sample) => sample.metrics[metric]);
    const status = observationStatus([...disabledObservations, ...enabledObservations]);
    if (status !== "measured") {
      result[metric] = { status, disabled_median: null, enabled_median: null, enabled_over_disabled: null, disabled_per_job: null, enabled_per_job: null };
      continue;
    }
    const disabled = median(measuredValues(disabledObservations)), enabled = median(measuredValues(enabledObservations)), jobs = samples[0].identity.jobs;
    result[metric] = { status, disabled_median: disabled, enabled_median: enabled, enabled_over_disabled: disabled === 0 ? null : enabled / disabled, disabled_per_job: disabled / jobs, enabled_per_job: enabled / jobs };
  }
  return result;
}

const UNAVAILABLE_CAPABILITIES: Record<string, { unit: string; reason: string }> = {
  branches: { unit: "count", reason: "the unprivileged macOS /usr/bin/time -l interface does not expose branch counts" },
  branch_misses: { unit: "count", reason: "the unprivileged macOS /usr/bin/time -l interface does not expose branch misses" },
  cache_misses: { unit: "count", reason: "the unprivileged macOS /usr/bin/time -l interface does not expose cache misses" },
  tlb_misses: { unit: "count", reason: "the unprivileged macOS /usr/bin/time -l interface does not expose TLB misses" },
  migrations: { unit: "count", reason: "the unprivileged macOS /usr/bin/time -l interface does not expose CPU migrations" },
  scheduler_wait_ns: { unit: "ns", reason: "the unprivileged macOS /usr/bin/time -l interface does not expose scheduler wait time" },
  frequency_hz: { unit: "Hz", reason: "the unprivileged macOS /usr/bin/time -l interface does not expose effective frequency" },
  thermal_state: { unit: "state", reason: "the benchmark interface records power source but has no trustworthy process-scoped thermal sample" },
  package_energy_joules: { unit: "J", reason: "macOS exposes no unprivileged process-boundary package-energy counter through /usr/bin/time -l" },
  process_energy_joules: { unit: "J", reason: "macOS exposes no unprivileged process-energy counter through /usr/bin/time -l" },
  peak_power_watts: { unit: "W", reason: "macOS exposes no unprivileged process-boundary peak-power counter through /usr/bin/time -l" },
};

function capabilityInventory(noOpSamples: NoOpSample[], samples: Sample[]): Record<string, any> {
  const inventory: Record<string, any> = {};
  for (const counter of COUNTER_NAMES) {
    const noOp = noOpSamples.map((sample) => sample.counters[counter]);
    const knownWork = samples.filter((sample) => sample.identity.state === "disabled").map((sample) => sample.metrics[counter]);
    const allWork = samples.map((sample) => sample.metrics[counter]);
    const observed = [...noOp, ...allWork];
    const status = observationStatus(observed);
    const firstMissing = observed.find((value) => value.status !== "measured") as Exclude<CounterObservation, { status: "measured" }> | undefined;
    inventory[counter] = {
      unit: "count",
      source: `/usr/bin/time -l: ${COUNTER_LABELS[counter]}`,
      availability: status === "measured" ? { status } : { status, reason: firstMissing!.reason },
      multiplexing: { status: "unavailable", reason: "/usr/bin/time -l exposes no multiplexing or scaling metadata" },
      calibration: {
        no_op: dispersion(measuredValues(noOp)),
        known_work: dispersion(measuredValues(knownWork)),
        stability_threshold_relative_standard_deviation: 0.05,
      },
    };
  }
  for (const [counter, boundary] of Object.entries(UNAVAILABLE_CAPABILITIES)) inventory[counter] = {
    unit: boundary.unit,
    source: "platform capability inventory",
    availability: { status: "unavailable", reason: boundary.reason },
    multiplexing: { status: "not_applicable", reason: "no counter samples were collected" },
    calibration: { no_op: null, known_work: null, stability_threshold_relative_standard_deviation: 0.05 },
  };
  return inventory;
}

export function validateArtifact(artifact: any): void {
  requireValue(artifact.schema_version === 2 && artifact.profile_id === "zig-js-instrumentation-overhead-v2", "overhead schema identity drift");
  requireValue(artifact.metadata && artifact.metadata.pairs >= 2, "overhead metadata is incomplete");
  requireValue(["diagnostic", "quiet_reference"].includes(artifact.metadata.host_class), "overhead host class is invalid");
  if (artifact.metadata.host_class === "quiet_reference")
    requireValue(artifact.metadata.environment.Power.includes("AC Power"), "quiet-reference overhead evidence requires AC power");
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
      for (const metric of ["wall_time_ns", "process_cpu_user_ns", "process_cpu_system_ns", "peak_rss_bytes"] as const)
        requireValue(Number.isFinite(row.metrics[metric]) && row.metrics[metric] >= 0, `pair ${pair} ${metric} is invalid`);
      for (const counter of COUNTER_NAMES) {
        const observation = row.metrics[counter];
        requireValue(["measured", "unavailable", "permission_denied"].includes(observation.status), `pair ${pair} ${counter} status is invalid`);
        if (observation.status === "measured") requireValue(Number.isFinite(observation.value) && observation.value >= 0, `pair ${pair} ${counter} value is invalid`);
        else requireValue(typeof observation.reason === "string" && observation.reason.length > 0, `pair ${pair} ${counter} reason is missing`);
      }
    }
  }
  requireValue(artifact.calibration?.no_op?.command?.join(" ") === "env LC_ALL=C /usr/bin/time -l /usr/bin/true", "no-op calibration command drift");
  requireValue(artifact.calibration.no_op.samples.length === artifact.metadata.pairs, "no-op calibration repetition drift");
  artifact.calibration.no_op.samples.forEach((sample: NoOpSample, index: number) => {
    requireValue(sample.sample === index, `no-op calibration sample ${index} identity drift`);
    for (const counter of COUNTER_NAMES) requireValue(Boolean(sample.counters[counter]), `no-op calibration sample ${index} is missing ${counter}`);
  });
  requireValue(artifact.calibration.known_work.sample_state === "disabled", "known-work calibration state drift");
  requireValue(artifact.calibration.known_work.sample_pairs.length === artifact.metadata.pairs, "known-work calibration pair inventory drift");
  const expectedCapabilities = [...COUNTER_NAMES, ...Object.keys(UNAVAILABLE_CAPABILITIES)].sort();
  requireValue(JSON.stringify(Object.keys(artifact.counter_capabilities).sort()) === JSON.stringify(expectedCapabilities), "counter capability inventory drift");
  for (const counter of expectedCapabilities) {
    const capability = artifact.counter_capabilities[counter];
    requireValue(["measured", "unavailable", "permission_denied"].includes(capability.availability.status), `${counter} availability is invalid`);
    requireValue(["unavailable", "not_applicable"].includes(capability.multiplexing.status), `${counter} multiplexing boundary is invalid`);
    if (COUNTER_NAMES.includes(counter as CounterName)) {
      const typedCounter = counter as CounterName;
      const observations: CounterObservation[] = [
        ...artifact.calibration.no_op.samples.map((sample: NoOpSample) => sample.counters[typedCounter]),
        ...samples.map((sample) => sample.metrics[typedCounter]),
      ];
      requireValue(capability.availability.status === observationStatus(observations), `${counter} capability/sample status drift`);
      requireValue(artifact.summary[counter].status === capability.availability.status, `${counter} summary/capability status drift`);
      if (capability.availability.status === "measured") {
        requireValue(capability.calibration.no_op.samples === artifact.metadata.pairs, `${counter} no-op calibration inventory drift`);
        requireValue(capability.calibration.known_work.samples === artifact.metadata.pairs, `${counter} known-work calibration inventory drift`);
      } else {
        requireValue(capability.calibration.no_op.samples <= artifact.metadata.pairs, `${counter} unavailable no-op inventory drift`);
        requireValue(capability.calibration.known_work.samples <= artifact.metadata.pairs, `${counter} unavailable known-work inventory drift`);
      }
      requireValue(["stable", "noisy", "indeterminate"].includes(capability.calibration.no_op.status), `${counter} no-op quality is invalid`);
      requireValue(["stable", "noisy", "indeterminate"].includes(capability.calibration.known_work.status), `${counter} known-work quality is invalid`);
    }
  }
  requireValue(artifact.boundaries.retained_rss.status === "unavailable", "retained RSS must remain explicit");
  requireValue(artifact.boundaries.contention.status === "not_applicable", "single-thread contention boundary drift");
  requireValue(artifact.boundaries.code_size.status === "same_binary", "runtime toggle must identify the same binary");
}

export function render(artifact: any, rawPath = ""): string {
  const summary = artifact.summary, metadata_ = artifact.metadata, environment = metadata_.environment;
  const rows = [
    `# Instrumentation overhead — ${metadata_.workload}`,
    "",
    `- date: ${environment.Date}`,
    `- host: ${environment.Host}`,
    `- OS: ${environment.OS}`,
    `- Zig: ${environment.Zig}`,
    `- zig-js: \`${metadata_.revision}\``,
    `- zig-gc: \`${environment["zig-gc"]}\``,
    `- zig-regex: \`${environment["zig-regex"]}\``,
    `- power: ${environment.Power}`,
    `- host class: \`${metadata_.host_class}\``,
    `- runner: \`${metadata_.runner_sha256}\` (${metadata_.runner_size_bytes} bytes; one binary for both states)`,
    `- workload source: \`${metadata_.workload_source}\` (SHA-256 \`${metadata_.workload_source_sha256}\`)`,
    `- sampling: ${metadata_.pairs} alternating disabled/enabled pairs; no discarded samples`,
    `- logical work: ${metadata_.jobs} jobs; frozen checksum ${metadata_.expected_checksum}`,
    `- timed boundary: ${metadata_.timed_boundary}`,
    "",
    "| metric | disabled median | enabled median | enabled / disabled |",
    "| --- | ---: | ---: | ---: |",
  ];
  for (const [name, unit] of [["wall_time_ns", "ns"], ["process_cpu_user_ns", "ns"], ["process_cpu_system_ns", "ns"], ["peak_rss_bytes", "bytes"], ["instructions", "count"], ["cycles", "count"], ["voluntary_context_switches", "count"], ["involuntary_context_switches", "count"]]) {
    const metric = summary[name];
    rows.push(metric.status && metric.status !== "measured"
      ? `| \`${name}\` | ${metric.status} | ${metric.status} | N/A |`
      : `| \`${name}\` | ${metric.disabled_median} ${unit} | ${metric.enabled_median} ${unit} | ${metric.enabled_over_disabled === null ? "N/A" : metric.enabled_over_disabled.toFixed(4) + "x"} |`);
  }
  rows.push(
    "",
    "## Counter capability and calibration",
    "",
    "Counter availability is separate from sample quality. `noisy` retains every raw value but forbids a stable efficiency claim; unavailable multiplexing metadata is never treated as non-multiplexed.",
    "",
    "| counter | availability | multiplexing | no-op quality | known-work quality |",
    "| --- | --- | --- | --- | --- |",
  );
  for (const [name, capability] of Object.entries(artifact.counter_capabilities) as [string, any][]) {
    const quality = (value: any): string => value === null ? "N/A" : value.relative_standard_deviation === null ? value.status : `${value.status} (RSD ${(value.relative_standard_deviation * 100).toFixed(2)}%)`;
    rows.push(`| \`${name}\` | ${capability.availability.status} | ${capability.multiplexing.status} | ${quality(capability.calibration.no_op)} | ${quality(capability.calibration.known_work)} |`);
  }
  rows.push(
    "",
    `No-op calibration runs \`${artifact.calibration.no_op.command.join(" ")}\` ${artifact.calibration.no_op.samples.length} times outside the alternating A/B pairs. Known-work calibration references the ${metadata_.pairs} disabled samples with the same frozen workload, jobs, and checksum. The stability threshold is 5% relative standard deviation; no sample is discarded.`,
    "",
    "Retained RSS is unavailable because each measurement exits after one sample. Lock contention is not applicable to this single-thread fixture. Both states use the exact same runner, so this runtime-toggle A/B does not claim to measure compile-time support code size.",
  );
  if (metadata_.host_class === "diagnostic")
    rows.push("", "This is diagnostic evidence. It does not establish a negligible-overhead publication claim; that requires an explicitly selected quiet reference host on AC power.");
  if (rawPath) rows.push("", `Raw samples: [\`${rawPath.split("/").pop()}\`](${rawPath.split("/").pop()})`);
  rows.push("");
  return rows.join("\n");
}

function syntheticSamples(): Sample[] {
  const rows: Sample[] = [];
  for (let pair = 0; pair < 2; pair += 1) {
    const order: State[] = pair % 2 === 0 ? ["disabled", "enabled"] : ["enabled", "disabled"];
    order.forEach((state, position) => rows.push({
      identity: { pair_sample: pair, order: position, state, mode: state === "disabled" ? "single" : "single_profiled", workload: "representative_json", jobs: 110, checksum: 5864992 },
      metrics: {
        wall_time_ns: state === "disabled" ? 100 : 102,
        process_cpu_user_ns: 80,
        process_cpu_system_ns: 20,
        peak_rss_bytes: 10_000_000,
        instructions: { status: "measured", value: 1000 + pair },
        cycles: { status: "measured", value: 500 + pair },
        voluntary_context_switches: { status: "measured", value: 1 },
        involuntary_context_switches: { status: "measured", value: 2 },
      },
    }));
  }
  return rows;
}

function syntheticNoOpSamples(): NoOpSample[] {
  return [0, 1].map((sample) => ({
    sample,
    counters: {
      instructions: { status: "measured", value: 100 + sample },
      cycles: { status: "measured", value: 50 + sample },
      voluntary_context_switches: { status: "measured", value: 0 },
      involuntary_context_switches: { status: "measured", value: 1 },
    },
  }));
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
  requireValue(counterObservation(timing, "instructions retired").status === "measured", "measured counter classification drift");
  requireValue(counterObservation("operation not permitted", "cycles elapsed").status === "permission_denied", "permission counter classification drift");
  requireValue(counterObservation("", "cycles elapsed").status === "unavailable", "unavailable counter classification drift");
  const samples = syntheticSamples(), noOpSamples = syntheticNoOpSamples(), artifact = {
    schema_version: 2,
    profile_id: "zig-js-instrumentation-overhead-v2",
    metadata: { pairs: 2, host_class: "diagnostic", runner_sha256: "a".repeat(64), runner_size_bytes: 1, workload: "representative_json", workload_source: "bench/representative_comparison.js", workload_source_sha256: "b".repeat(64), jobs: 110, expected_checksum: 5864992, revision: "c".repeat(40), environment: { Date: "2026-08-04", Host: "fixture", OS: "fixture", Zig: "fixture", "zig-gc": "d".repeat(40), "zig-regex": "e".repeat(40), Power: "Battery Power" } },
    samples,
    summary: summarize(samples),
    calibration: {
      no_op: { command: ["env", "LC_ALL=C", "/usr/bin/time", "-l", "/usr/bin/true"], samples: noOpSamples },
      known_work: { sample_state: "disabled", sample_pairs: [0, 1] },
    },
    counter_capabilities: capabilityInventory(noOpSamples, samples),
    boundaries: { retained_rss: { status: "unavailable" }, contention: { status: "not_applicable" }, code_size: { status: "same_binary" } },
  };
  validateArtifact(artifact);
  requireValue(artifact.counter_capabilities.instructions.availability.status === "measured", "measured capability drift");
  requireValue(artifact.counter_capabilities.cache_misses.availability.status === "unavailable", "unavailable capability drift");
  requireValue(artifact.counter_capabilities.instructions.multiplexing.status === "unavailable", "multiplexing boundary drift");
  requireValue(render(artifact, "docs/.data/fixture.json").includes("Raw samples: [`fixture.json`](fixture.json)"), "report provenance drift");
  const unavailable = JSON.parse(JSON.stringify(artifact));
  unavailable.samples.forEach((sample: Sample) => sample.metrics.cycles = { status: "unavailable", reason: "fixture counter absent" });
  unavailable.calibration.no_op.samples.forEach((sample: NoOpSample) => sample.counters.cycles = { status: "unavailable", reason: "fixture counter absent" });
  unavailable.summary = summarize(unavailable.samples);
  unavailable.counter_capabilities = capabilityInventory(unavailable.calibration.no_op.samples, unavailable.samples);
  validateArtifact(unavailable);
  requireValue(unavailable.summary.cycles.status === "unavailable" && render(unavailable).includes("| `cycles` | unavailable | unavailable | N/A |"), "unavailable summary rendering drift");
  const order = JSON.parse(JSON.stringify(artifact)); order.samples[2].identity.state = "disabled";
  expectFailure(() => validateArtifact(order), "order drift");
  const reference = JSON.parse(JSON.stringify(artifact)); reference.metadata.host_class = "quiet_reference";
  expectFailure(() => validateArtifact(reference), "requires AC power");
  console.log("OK instrumentation overhead self-test: parsing, alternation, checksums, capability states, calibration quality, and explicit boundaries verified");
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
  let manifestPath = DEFAULT_MANIFEST, workload = "representative_json", pairs = 7, hostClass = "diagnostic", rawOut = "", markdownOut = "", quick = false;
  for (let index = 1; index < args.length; index += 1) {
    const name = args[index];
    if (name === "--quick") quick = true;
    else {
      const value = args[++index];
      if (name === "--manifest") manifestPath = value;
      else if (name === "--workload") workload = value;
      else if (name === "--pairs") pairs = Number(value);
      else if (name === "--host-class") hostClass = value;
      else if (name === "--raw-out") rawOut = value;
      else if (name === "--markdown-out") markdownOut = value;
      else throw new Error(`unknown argument: ${name}`);
    }
  }
  if (quick && pairs === 7) pairs = 2;
  requireValue(Boolean(rawOut) === Boolean(markdownOut), "raw and Markdown overhead outputs must be written together");
  requireValue(["diagnostic", "quiet_reference"].includes(hostClass), "host class must be diagnostic or quiet_reference");
  const manifest = loadManifest(manifestPath); validateManifest(manifest);
  const resolved = resolveWorkload(manifest, workload, quick), info = metadata();
  ensurePublishable(info, Boolean(rawOut));
  const noOpSamples = collectNoOp(pairs);
  const samples = collect(runner, workload, resolved.jobs, resolved.checksum, pairs), size = Number(run(["/usr/bin/stat", "-f", "%z", runner]).stdout.trim());
  const artifact = {
    schema_version: 2,
    profile_id: "zig-js-instrumentation-overhead-v2",
    metadata: {
      environment: info,
      host_class: hostClass,
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
    calibration: {
      no_op: { command: ["env", "LC_ALL=C", "/usr/bin/time", "-l", "/usr/bin/true"], samples: noOpSamples },
      known_work: { sample_state: "disabled", sample_pairs: samples.filter((sample) => sample.identity.state === "disabled").map((sample) => sample.identity.pair_sample) },
    },
    counter_capabilities: capabilityInventory(noOpSamples, samples),
    boundaries: {
      retained_rss: { status: "unavailable", reason: "the fresh runner process exits after each sample" },
      contention: { status: "not_applicable", reason: "the fixture uses one JavaScript thread and one context" },
      code_size: { status: "same_binary", value: size, reason: "runtime-disabled and runtime-enabled states execute the exact same binary" },
    },
  };
  validateArtifact(artifact);
  const report = render(artifact, rawOut);
  if (rawOut) { writeText(rawOut, JSON.stringify(artifact, null, 2) + "\n"); writeText(markdownOut, report); }
  process.stdout.write(report);
}

if (process.argv[1] === __filename) main();
