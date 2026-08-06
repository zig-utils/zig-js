/** Measure the runtime cost of the complete opt-in attribution sink against its disabled path. */
import { ensurePublishable, metadata } from "./benchmark-comparison";
import { DEFAULT_MANIFEST, loadManifest, validate as validateManifest } from "./representative-matrix";
import { run, sha256File, writeText } from "./lib/home";

declare const __filename: string;

type State = "disabled" | "enabled";
type Instrumentation = "execution_attribution" | "native_observability";
type Mode = "single" | "single_profiled" | "single_observed";
const OWNED_COUNTER_NAMES = ["instructions", "cycles", "process_energy_nj", "package_idle_wakeups", "interrupt_wakeups", "pageins", "page_cache_hits"] as const;
const TIME_COUNTER_NAMES = ["voluntary_context_switches", "involuntary_context_switches"] as const;
const COUNTER_NAMES = [...OWNED_COUNTER_NAMES, ...TIME_COUNTER_NAMES] as const;
type CounterName = typeof COUNTER_NAMES[number];
const COUNTER_LABELS: Record<typeof TIME_COUNTER_NAMES[number], string> = {
  voluntary_context_switches: "voluntary context switches",
  involuntary_context_switches: "involuntary context switches",
};
type CounterObservation =
  | { status: "measured"; value: number }
  | { status: "unavailable" | "permission_denied"; reason: string };
type CounterMeasurements = Record<CounterName, CounterObservation>;
type ThermalState = "nominal" | "fair" | "serious" | "critical";
type ThermalObservation =
  | { status: "measured"; before: ThermalState; after: ThermalState }
  | { status: "unavailable" | "permission_denied"; reason: string };
type Measurement = {
  wall_time_ns: number;
  process_wall_time_ns: number;
  process_cpu_user_ns: number;
  process_cpu_system_ns: number;
  peak_rss_bytes: number;
  thermal_state: ThermalObservation;
  native_observability?: NativeObservabilityMeasurement;
} & CounterMeasurements;
type NativeObservabilityMeasurement = {
  live_artifacts: number;
  live_code_bytes: number;
  baseline_publications: number;
  optimizer_publications: number;
  live_registrations: number;
  live_symfile_bytes: number;
  live_unwind_bytes: number;
  registrations: number;
  unregistrations: number;
  live_peak_rss_bytes: number;
  retained_rss_bytes: number;
  post_teardown_live_registrations: number;
  post_teardown_live_symfile_bytes: number;
  post_teardown_live_unwind_bytes: number;
  post_teardown_registrations: number;
  post_teardown_unregistrations: number;
  post_teardown_peak_rss_bytes: number;
  post_teardown_retained_rss_bytes: number;
};
type Sample = {
  identity: {
    pair_sample: number;
    order: number;
    state: State;
    mode: Mode;
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

function darwinFields(stdout: string, mode: string, workload: string, jobs: number): string[] {
  const rows = stdout.split("\n").filter((line) => line.startsWith("zig-js-darwin-rusage\t"));
  requireValue(rows.length === 1, `expected one Darwin rusage row, got ${rows.length}`);
  const fields = rows[0].split("\t");
  requireValue(fields.length === 15 && fields[1] === mode && fields[2] === workload && Number(fields[3]) === jobs && Number(fields[4]) === 0, "Darwin rusage identity drift");
  requireValue(fields[5] === "measured", `Darwin rusage status is ${fields[5]}`);
  return fields;
}

export function parseDarwinCounters(stdout: string, mode: string, workload: string, jobs: number): Pick<CounterMeasurements, typeof OWNED_COUNTER_NAMES[number]> {
  const observations = darwinFields(stdout, mode, workload, jobs).slice(6, 13).map((field) => ({ status: "measured" as const, value: Number(field) }));
  observations.forEach((observation) => requireValue(Number.isFinite(observation.value) && observation.value >= 0, "Darwin rusage counter is invalid"));
  return Object.fromEntries(OWNED_COUNTER_NAMES.map((name, index) => [name, observations[index]])) as Pick<CounterMeasurements, typeof OWNED_COUNTER_NAMES[number]>;
}

const THERMAL_STATES: ThermalState[] = ["nominal", "fair", "serious", "critical"];
export function parseDarwinThermalState(stdout: string, mode: string, workload: string, jobs: number): ThermalObservation {
  const fields = darwinFields(stdout, mode, workload, jobs), before = Number(fields[13]), after = Number(fields[14]);
  if (!Number.isInteger(before) || !Number.isInteger(after) || before < 0 || before >= THERMAL_STATES.length || after < 0 || after >= THERMAL_STATES.length)
    return { status: "unavailable", reason: "NSProcessInfo thermalState returned an unsupported value" };
  return { status: "measured", before: THERMAL_STATES[before], after: THERMAL_STATES[after] };
}

function parseCounters(stdout: string, stderr: string, mode: string, workload: string, jobs: number): CounterMeasurements {
  return {
    ...parseDarwinCounters(stdout, mode, workload, jobs),
    voluntary_context_switches: counterObservation(stderr, COUNTER_LABELS.voluntary_context_switches),
    involuntary_context_switches: counterObservation(stderr, COUNTER_LABELS.involuntary_context_switches),
  };
}

export function parseRow(
  stdout: string,
  mode: Mode,
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

function parseNativeObservability(stdout: string, mode: Mode, workload: string, jobs: number): NativeObservabilityMeasurement {
  const liveRows = stdout.split("\n").filter((line) => line.startsWith("zig-js-native-observability\t")),
    retiredRows = stdout.split("\n").filter((line) => line.startsWith("zig-js-native-observability-retired\t"));
  requireValue(liveRows.length === 1 && retiredRows.length === 1, "native observability telemetry row inventory drift");
  const live = liveRows[0].split("\t"), retired = retiredRows[0].split("\t");
  requireValue(live.length === 16 && live[1] === mode && live[2] === workload && Number(live[3]) === jobs && Number(live[4]) === 0, "native observability live identity drift");
  requireValue(retired.length === 11 && retired[1] === mode && retired[2] === workload && Number(retired[3]) === jobs, "native observability retired identity drift");
  const liveValues = live.slice(5).map(Number), retiredValues = retired.slice(4).map(Number);
  requireValue([...liveValues, ...retiredValues].every((value) => Number.isInteger(value) && value >= 0), "native observability telemetry value is invalid");
  return {
    live_artifacts: liveValues[0],
    live_code_bytes: liveValues[1],
    baseline_publications: liveValues[2],
    optimizer_publications: liveValues[3],
    live_registrations: liveValues[4],
    live_symfile_bytes: liveValues[5],
    live_unwind_bytes: liveValues[6],
    registrations: liveValues[7],
    unregistrations: liveValues[8],
    live_peak_rss_bytes: liveValues[9],
    retained_rss_bytes: liveValues[10],
    post_teardown_live_registrations: retiredValues[0],
    post_teardown_live_symfile_bytes: retiredValues[1],
    post_teardown_live_unwind_bytes: retiredValues[2],
    post_teardown_registrations: retiredValues[3],
    post_teardown_unregistrations: retiredValues[4],
    post_teardown_peak_rss_bytes: retiredValues[5],
    post_teardown_retained_rss_bytes: retiredValues[6],
  };
}

function modeFor(instrumentation: Instrumentation, state: State): Mode {
  if (state === "disabled") return "single";
  return instrumentation === "execution_attribution" ? "single_profiled" : "single_observed";
}

function runOne(
  runner: string,
  instrumentation: Instrumentation,
  state: State,
  workload: string,
  jobs: number,
): { mode: Mode; measurement: Measurement; checksum: number } {
  const mode = modeFor(instrumentation, state), telemetry = instrumentation === "native_observability";
  const command = ["env", "LC_ALL=C", "/usr/bin/time", "-l", runner, mode, workload, String(jobs), "1", telemetry ? "--native-observability-telemetry" : "--darwin-rusage"];
  console.error(`+ ${command.join(" ")}`);
  const completed = run(command);
  requireValue(completed.exitCode === 0, completed.stderr || `benchmark exited ${completed.exitCode}`);
  const row = parseRow(completed.stdout, mode, workload, jobs);
  const counters = parseCounters(completed.stdout, completed.stderr, mode, workload, jobs);
  return {
    mode,
    checksum: row.checksum,
    measurement: {
      wall_time_ns: row.wall_time_ns,
      process_wall_time_ns: Math.round(timeMetric(completed.stderr, "real") * 1e9),
      process_cpu_user_ns: Math.round(timeMetric(completed.stderr, "user") * 1e9),
      process_cpu_system_ns: Math.round(timeMetric(completed.stderr, "sys") * 1e9),
      peak_rss_bytes: Math.round(timeMetric(completed.stderr, "maximum resident set size")),
      thermal_state: parseDarwinThermalState(completed.stdout, mode, workload, jobs),
      ...(telemetry ? { native_observability: parseNativeObservability(completed.stdout, mode, workload, jobs) } : {}),
      ...counters,
    },
  };
}

type NoOpSample = { sample: number; counters: CounterMeasurements; thermal_state: ThermalObservation };

function collectNoOp(runner: string, repetitions: number): NoOpSample[] {
  const samples: NoOpSample[] = [];
  for (let sample = 0; sample < repetitions; sample += 1) {
    const command = ["env", "LC_ALL=C", "/usr/bin/time", "-l", runner, "--darwin-rusage-noop"];
    console.error(`+ ${command.join(" ")}`);
    const completed = run(command);
    requireValue(completed.exitCode === 0, completed.stderr || `no-op calibration exited ${completed.exitCode}`);
    samples.push({ sample, counters: parseCounters(completed.stdout, completed.stderr, "single", "counter_noop", 1), thermal_state: parseDarwinThermalState(completed.stdout, "single", "counter_noop", 1) });
  }
  return samples;
}

export function collect(
  runner: string,
  instrumentation: Instrumentation,
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
      const row = runOne(runner, instrumentation, state, workload, jobs);
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

function thermalObservationStatus(observations: ThermalObservation[]): "measured" | "unavailable" | "permission_denied" {
  if (observations.some((value) => value.status === "permission_denied")) return "permission_denied";
  if (observations.some((value) => value.status === "unavailable")) return "unavailable";
  return "measured";
}

function thermalQuality(observations: ThermalObservation[]): { samples: number; states: ThermalState[]; boundaries_stable: boolean; relative_standard_deviation: null; status: "stable" | "noisy" | "indeterminate" } {
  const measured = observations.filter((value): value is Extract<ThermalObservation, { status: "measured" }> => value.status === "measured"),
    states = [...new Set(measured.flatMap((value) => [value.before, value.after]))].sort() as ThermalState[],
    boundariesStable = measured.every((value) => value.before === value.after);
  return {
    samples: measured.length,
    states,
    boundaries_stable: boundariesStable,
    relative_standard_deviation: null,
    status: measured.length === 0 ? "indeterminate" : boundariesStable && states.length === 1 ? "stable" : "noisy",
  };
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
  for (const metric of ["wall_time_ns", "process_wall_time_ns", "process_cpu_user_ns", "process_cpu_system_ns", "peak_rss_bytes"] as const) {
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
  const energy = result.process_energy_nj, jobs = samples[0].identity.jobs;
  result.logical_work_per_joule = energy.status === "measured" && energy.disabled_median > 0 && energy.enabled_median > 0
    ? { status: "measured", disabled: jobs * 1e9 / energy.disabled_median, enabled: jobs * 1e9 / energy.enabled_median }
    : { status: energy.status || "unavailable", disabled: null, enabled: null };
  const cycles = result.cycles, instructions = result.instructions;
  result.cycles_per_logical_job = cycles.status === "measured"
    ? { status: "measured", disabled: cycles.disabled_median / jobs, enabled: cycles.enabled_median / jobs }
    : { status: cycles.status, disabled: null, enabled: null };
  result.instructions_per_logical_job = instructions.status === "measured"
    ? { status: "measured", disabled: instructions.disabled_median / jobs, enabled: instructions.enabled_median / jobs }
    : { status: instructions.status, disabled: null, enabled: null };
  result.process_energy_per_logical_job_nj = energy.status === "measured"
    ? { status: "measured", disabled: energy.disabled_median / jobs, enabled: energy.enabled_median / jobs }
    : { status: energy.status, disabled: null, enabled: null };
  result.instructions_per_cycle = cycles.status === "measured" && instructions.status === "measured" && cycles.disabled_median > 0 && cycles.enabled_median > 0
    ? { status: "measured", disabled: instructions.disabled_median / cycles.disabled_median, enabled: instructions.enabled_median / cycles.enabled_median }
    : { status: cycles.status !== "measured" ? cycles.status : instructions.status, disabled: null, enabled: null };
  const thermal = samples.map((sample) => sample.metrics.thermal_state), thermalStatus = thermalObservationStatus(thermal), quality = thermalQuality(thermal);
  result.thermal_state = thermalStatus === "measured"
    ? { status: "measured", states: quality.states, boundaries_stable: quality.boundaries_stable, quality: quality.status }
    : { status: thermalStatus, states: [], boundaries_stable: false, quality: "indeterminate" };
  if (samples.some((sample) => sample.metrics.native_observability)) {
    result.native_observability = {};
    for (const metric of [
      "live_artifacts", "live_code_bytes", "baseline_publications", "optimizer_publications",
      "live_registrations", "live_symfile_bytes", "live_unwind_bytes", "registrations", "unregistrations",
      "live_peak_rss_bytes", "retained_rss_bytes", "post_teardown_live_registrations", "post_teardown_live_symfile_bytes",
      "post_teardown_live_unwind_bytes", "post_teardown_registrations", "post_teardown_unregistrations",
      "post_teardown_peak_rss_bytes", "post_teardown_retained_rss_bytes",
    ] as const) {
      const disabled = median(samples.filter((sample) => sample.identity.state === "disabled").map((sample) => sample.metrics.native_observability![metric])),
        enabled = median(samples.filter((sample) => sample.identity.state === "enabled").map((sample) => sample.metrics.native_observability![metric]));
      result.native_observability[metric] = {
        disabled_median: disabled,
        enabled_median: enabled,
        enabled_minus_disabled: enabled - disabled,
        enabled_over_disabled: disabled === 0 ? null : enabled / disabled,
      };
    }
  }
  return result;
}

const UNAVAILABLE_CAPABILITIES: Record<string, { unit: string; reason: string }> = {
  branches: { unit: "count", reason: "the unprivileged macOS process-boundary interfaces do not expose branch counts" },
  branch_misses: { unit: "count", reason: "the unprivileged macOS process-boundary interfaces do not expose branch misses" },
  cache_misses: { unit: "count", reason: "the unprivileged macOS process-boundary interfaces do not expose CPU cache misses; VM page-cache hits are retained separately" },
  tlb_misses: { unit: "count", reason: "the unprivileged macOS process-boundary interfaces do not expose TLB misses" },
  migrations: { unit: "count", reason: "the unprivileged macOS process-boundary interfaces do not expose CPU migrations" },
  scheduler_wait_ns: { unit: "ns", reason: "the unprivileged macOS process-boundary interfaces do not expose scheduler wait time" },
  frequency_hz: { unit: "Hz", reason: "the unprivileged macOS process-boundary interfaces do not expose effective frequency" },
  package_energy_joules: { unit: "J", reason: "the unprivileged macOS process-boundary interfaces expose process energy but not package energy" },
  peak_power_watts: { unit: "W", reason: "the unprivileged macOS process-boundary interfaces expose cumulative process energy but not peak power" },
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
    const owned = (OWNED_COUNTER_NAMES as readonly string[]).includes(counter);
    const multiplexed = counter === "instructions" || counter === "cycles";
    inventory[counter] = {
      unit: counter === "process_energy_nj" ? "nJ" : "count",
      source: owned ? "proc_pid_rusage(RUSAGE_INFO_V6) self-process delta" : `/usr/bin/time -l: ${COUNTER_LABELS[counter as typeof TIME_COUNTER_NAMES[number]]}`,
      availability: status === "measured" ? { status } : { status, reason: firstMissing!.reason },
      multiplexing: multiplexed
        ? { status: "unavailable", reason: "proc_pid_rusage exposes no multiplexing or scaling metadata" }
        : { status: "not_applicable", reason: "this counter is not a multiplexed hardware event" },
      calibration: {
        no_op: dispersion(measuredValues(noOp)),
        known_work: dispersion(measuredValues(knownWork)),
        stability_threshold_relative_standard_deviation: 0.05,
      },
    };
  }
  const noOpThermal = noOpSamples.map((sample) => sample.thermal_state), knownWorkThermal = samples.filter((sample) => sample.identity.state === "disabled").map((sample) => sample.metrics.thermal_state), allThermal = samples.map((sample) => sample.metrics.thermal_state), thermalStatus = thermalObservationStatus([...noOpThermal, ...allThermal]);
  const firstMissingThermal = [...noOpThermal, ...allThermal].find((value) => value.status !== "measured") as Exclude<ThermalObservation, { status: "measured" }> | undefined;
  inventory.thermal_state = {
    unit: "categorical",
    source: "NSProcessInfo.thermalState immediately outside the timed/process-counter boundary",
    availability: thermalStatus === "measured" ? { status: "measured" } : { status: thermalStatus, reason: firstMissingThermal!.reason },
    multiplexing: { status: "not_applicable", reason: "thermal state is a system condition, not a multiplexed hardware event" },
    calibration: {
      no_op: thermalQuality(noOpThermal),
      known_work: thermalQuality(knownWorkThermal),
      stability_threshold_relative_standard_deviation: null,
    },
  };
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
  requireValue(artifact.schema_version === 5 && artifact.profile_id === "zig-js-instrumentation-overhead-v5", "overhead schema identity drift");
  requireValue(artifact.metadata && artifact.metadata.pairs >= 2, "overhead metadata is incomplete");
  requireValue(["execution_attribution", "native_observability"].includes(artifact.metadata.instrumentation), "overhead instrumentation identity drift");
  requireValue(["diagnostic", "quiet_reference"].includes(artifact.metadata.host_class), "overhead host class is invalid");
  if (artifact.metadata.host_class === "quiet_reference") {
    requireValue(artifact.metadata.environment.Power.includes("AC Power"), "quiet-reference overhead evidence requires AC power");
    for (const counter of ["instructions", "cycles", "process_energy_nj"])
      requireValue(artifact.counter_capabilities[counter].availability.status === "measured" && artifact.counter_capabilities[counter].calibration.known_work.status === "stable", `quiet-reference efficiency evidence requires stable known-work ${counter}`);
    const thermal = artifact.counter_capabilities.thermal_state;
    requireValue(thermal.availability.status === "measured" && thermal.calibration.no_op.status === "stable" && thermal.calibration.known_work.status === "stable" && JSON.stringify(thermal.calibration.no_op.states) === '["nominal"]' && JSON.stringify(thermal.calibration.known_work.states) === '["nominal"]' && artifact.summary.thermal_state.quality === "stable" && JSON.stringify(artifact.summary.thermal_state.states) === '["nominal"]', "quiet-reference efficiency evidence requires stable nominal thermal state");
  }
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
      requireValue(row.identity.mode === modeFor(artifact.metadata.instrumentation, row.identity.state), `pair ${pair} mode/state drift`);
      requireValue(row.identity.workload === artifact.metadata.workload && row.identity.jobs === artifact.metadata.jobs && row.identity.checksum === artifact.metadata.expected_checksum, `pair ${pair} metadata identity drift`);
      for (const metric of ["wall_time_ns", "process_wall_time_ns", "process_cpu_user_ns", "process_cpu_system_ns", "peak_rss_bytes"] as const)
        requireValue(Number.isFinite(row.metrics[metric]) && row.metrics[metric] >= 0, `pair ${pair} ${metric} is invalid`);
      requireValue(row.metrics.process_wall_time_ns >= row.metrics.wall_time_ns, `pair ${pair} process wall boundary is narrower than invocation wall time`);
      for (const counter of COUNTER_NAMES) {
        const observation = row.metrics[counter];
        requireValue(["measured", "unavailable", "permission_denied"].includes(observation.status), `pair ${pair} ${counter} status is invalid`);
        if (observation.status === "measured") requireValue(Number.isFinite(observation.value) && observation.value >= 0, `pair ${pair} ${counter} value is invalid`);
        else requireValue(typeof observation.reason === "string" && observation.reason.length > 0, `pair ${pair} ${counter} reason is missing`);
      }
      const thermal = row.metrics.thermal_state;
      requireValue(["measured", "unavailable", "permission_denied"].includes(thermal.status), `pair ${pair} thermal state status is invalid`);
      if (thermal.status === "measured") requireValue(THERMAL_STATES.includes(thermal.before) && THERMAL_STATES.includes(thermal.after), `pair ${pair} thermal state is invalid`);
      else requireValue(typeof thermal.reason === "string" && thermal.reason.length > 0, `pair ${pair} thermal state reason is missing`);
      if (artifact.metadata.instrumentation === "native_observability") {
        const native = row.metrics.native_observability;
        requireValue(Boolean(native), `pair ${pair} native observability telemetry is missing`);
        requireValue(Object.values(native!).every((value) => Number.isInteger(value) && (value as number) >= 0), `pair ${pair} native observability telemetry is invalid`);
        requireValue(native!.retained_rss_bytes <= native!.live_peak_rss_bytes, `pair ${pair} retained RSS exceeds live-snapshot peak`);
        requireValue(native!.post_teardown_retained_rss_bytes <= native!.post_teardown_peak_rss_bytes, `pair ${pair} post-teardown retained RSS exceeds peak`);
        requireValue(native!.post_teardown_peak_rss_bytes >= native!.live_peak_rss_bytes, `pair ${pair} process peak decreased across teardown`);
      } else requireValue(row.metrics.native_observability === undefined, `pair ${pair} unexpected native observability telemetry`);
    }
    if (artifact.metadata.instrumentation === "native_observability") {
      const disabled = rows.find((row) => row.identity.state === "disabled")!.metrics.native_observability!,
        enabled = rows.find((row) => row.identity.state === "enabled")!.metrics.native_observability!;
      for (const metric of ["live_artifacts", "live_code_bytes", "baseline_publications", "optimizer_publications"] as const)
        requireValue(disabled[metric] === enabled[metric], `pair ${pair} ${metric} tier parity drift`);
      for (const metric of ["live_registrations", "live_symfile_bytes", "live_unwind_bytes", "registrations", "unregistrations", "post_teardown_live_registrations", "post_teardown_live_symfile_bytes", "post_teardown_live_unwind_bytes", "post_teardown_registrations", "post_teardown_unregistrations"] as const)
        requireValue(disabled[metric] === 0, `pair ${pair} disabled publisher ${metric} is nonzero`);
      requireValue(enabled.live_registrations > 0 && enabled.live_symfile_bytes > 0 && enabled.live_unwind_bytes > 0, `pair ${pair} enabled publisher did not retain complete metadata`);
      requireValue(enabled.registrations - enabled.unregistrations === enabled.live_registrations, `pair ${pair} live publisher lifecycle is incoherent`);
      requireValue(enabled.post_teardown_live_registrations === 0 && enabled.post_teardown_live_symfile_bytes === 0 && enabled.post_teardown_live_unwind_bytes === 0, `pair ${pair} publisher storage survived teardown`);
      requireValue(enabled.post_teardown_registrations === enabled.registrations && enabled.post_teardown_unregistrations === enabled.registrations, `pair ${pair} publisher teardown lifecycle is incomplete`);
    }
  }
  requireValue(artifact.calibration?.no_op?.command?.join(" ") === `env LC_ALL=C /usr/bin/time -l ${artifact.metadata.runner_path} --darwin-rusage-noop`, "no-op calibration command drift");
  requireValue(artifact.calibration.no_op.samples.length === artifact.metadata.pairs, "no-op calibration repetition drift");
  artifact.calibration.no_op.samples.forEach((sample: NoOpSample, index: number) => {
    requireValue(sample.sample === index, `no-op calibration sample ${index} identity drift`);
    for (const counter of COUNTER_NAMES) requireValue(Boolean(sample.counters[counter]), `no-op calibration sample ${index} is missing ${counter}`);
    requireValue(Boolean(sample.thermal_state), `no-op calibration sample ${index} is missing thermal state`);
  });
  requireValue(artifact.calibration.known_work.sample_state === "disabled", "known-work calibration state drift");
  requireValue(artifact.calibration.known_work.sample_pairs.length === artifact.metadata.pairs, "known-work calibration pair inventory drift");
  const expectedCapabilities = [...COUNTER_NAMES, "thermal_state", ...Object.keys(UNAVAILABLE_CAPABILITIES)].sort();
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
    } else if (counter === "thermal_state") {
      const observations: ThermalObservation[] = [
        ...artifact.calibration.no_op.samples.map((sample: NoOpSample) => sample.thermal_state),
        ...samples.map((sample) => sample.metrics.thermal_state),
      ];
      requireValue(capability.availability.status === thermalObservationStatus(observations), "thermal capability/sample status drift");
      requireValue(["stable", "noisy", "indeterminate"].includes(capability.calibration.no_op.status) && ["stable", "noisy", "indeterminate"].includes(capability.calibration.known_work.status), "thermal calibration quality is invalid");
      requireValue(artifact.summary.thermal_state.status === capability.availability.status, "thermal summary/capability status drift");
    }
  }
  requireValue(artifact.boundaries.retained_rss.status === (artifact.metadata.instrumentation === "native_observability" ? "measured" : "unavailable"), "retained RSS boundary drift");
  requireValue(artifact.boundaries.contention.status === "not_applicable", "single-thread contention boundary drift");
  requireValue(artifact.boundaries.code_size.status === "same_binary", "runtime toggle must identify the same binary");
  if (artifact.counter_capabilities.process_energy_nj.availability.status === "measured")
    requireValue(artifact.summary.logical_work_per_joule.status === "measured" && artifact.summary.logical_work_per_joule.disabled > 0 && artifact.summary.logical_work_per_joule.enabled > 0 && artifact.summary.process_energy_per_logical_job_nj.status === "measured", "energy normalization is invalid");
  if (artifact.counter_capabilities.cycles.availability.status === "measured")
    requireValue(artifact.summary.cycles_per_logical_job.status === "measured" && artifact.summary.cycles_per_logical_job.disabled >= 0 && artifact.summary.cycles_per_logical_job.enabled >= 0, "cycle normalization is invalid");
  if (artifact.counter_capabilities.instructions.availability.status === "measured")
    requireValue(artifact.summary.instructions_per_logical_job.status === "measured" && artifact.summary.instructions_per_logical_job.disabled >= 0 && artifact.summary.instructions_per_logical_job.enabled >= 0, "instruction normalization is invalid");
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
    `- instrumentation: \`${metadata_.instrumentation}\``,
    `- runner: \`${metadata_.runner_sha256}\` (${metadata_.runner_size_bytes} bytes; one binary for both states)`,
    `- workload source: \`${metadata_.workload_source}\` (SHA-256 \`${metadata_.workload_source_sha256}\`)`,
    `- sampling: ${metadata_.pairs} alternating disabled/enabled pairs; no discarded samples`,
    `- logical work: ${metadata_.jobs} jobs; frozen checksum ${metadata_.expected_checksum}`,
    `- timed boundary: ${metadata_.timed_boundary}`,
    "",
    "| metric | disabled median | enabled median | enabled / disabled |",
    "| --- | ---: | ---: | ---: |",
  ];
  const metricRows: [string, string][] = [
    ["wall_time_ns", "ns"], ["process_wall_time_ns", "ns"], ["process_cpu_user_ns", "ns"], ["process_cpu_system_ns", "ns"], ["peak_rss_bytes", "bytes"],
    ...COUNTER_NAMES.map((name) => [name, name === "process_energy_nj" ? "nJ" : "count"] as [string, string]),
  ];
  for (const [name, unit] of metricRows) {
    const metric = summary[name];
    rows.push(metric.status && metric.status !== "measured"
      ? `| \`${name}\` | ${metric.status} | ${metric.status} | N/A |`
      : `| \`${name}\` | ${metric.disabled_median} ${unit} | ${metric.enabled_median} ${unit} | ${metric.enabled_over_disabled === null ? "N/A" : metric.enabled_over_disabled.toFixed(4) + "x"} |`);
  }
  const efficiency = summary.logical_work_per_joule;
  rows.push(efficiency.status === "measured"
    ? `| \`logical_work_per_joule\` | ${efficiency.disabled.toFixed(3)} jobs/J | ${efficiency.enabled.toFixed(3)} jobs/J | ${(efficiency.enabled / efficiency.disabled).toFixed(4)}x |`
    : `| \`logical_work_per_joule\` | ${efficiency.status} | ${efficiency.status} | N/A |`);
  for (const [name, unit] of [["cycles_per_logical_job", "cycles/job"], ["instructions_per_logical_job", "instructions/job"], ["process_energy_per_logical_job_nj", "nJ/job"], ["instructions_per_cycle", "instructions/cycle"]]) {
    const metric = summary[name];
    rows.push(metric.status === "measured"
      ? `| \`${name}\` | ${metric.disabled.toFixed(3)} ${unit} | ${metric.enabled.toFixed(3)} ${unit} | ${(metric.enabled / metric.disabled).toFixed(4)}x |`
      : `| \`${name}\` | ${metric.status} | ${metric.status} | N/A |`);
  }
  const thermal = summary.thermal_state;
  rows.push(thermal.status === "measured"
    ? `| \`thermal_state\` | ${thermal.states.join(", ")} | ${thermal.states.join(", ")} | ${thermal.boundaries_stable ? "stable" : "drifted"} |`
    : `| \`thermal_state\` | ${thermal.status} | ${thermal.status} | N/A |`);
  if (summary.native_observability) {
    rows.push(
      "",
      "## Native publication state",
      "",
      "These boundary medians are exact engine/publisher gauges, not inferred process-memory deltas. Zero-denominator ratios remain N/A and the absolute delta stays visible.",
      "",
      "| field | disabled median | enabled median | enabled - disabled | enabled / disabled |",
      "| --- | ---: | ---: | ---: | ---: |",
    );
    for (const [name, metric] of Object.entries(summary.native_observability) as [string, any][])
      rows.push(`| \`${name}\` | ${metric.disabled_median} | ${metric.enabled_median} | ${metric.enabled_minus_disabled} | ${metric.enabled_over_disabled === null ? "N/A" : metric.enabled_over_disabled.toFixed(4) + "x"} |`);
  }
  rows.push(
    "",
    "## Counter capability and calibration",
    "",
    "Counter availability is separate from sample quality. `noisy` retains every raw value but forbids a stable efficiency claim; unavailable multiplexing metadata is never treated as non-multiplexed. Instructions, cycles, process energy, wakeups, page-ins, and VM page-cache hits come from owned self-process `proc_pid_rusage(RUSAGE_INFO_V6)` deltas. System thermal state comes from public `NSProcessInfo.thermalState` snapshots outside both measured boundaries.",
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
    metadata_.instrumentation === "native_observability"
      ? "Retained RSS is measured in the runner immediately before Context teardown and again immediately after it; peak and current bytes share the same Mach task_vm_info accounting domain. Lock contention is not applicable to this single-thread fixture. Both states use the exact same runner, so this runtime-toggle A/B does not claim to measure compile-time support code size."
      : "Retained RSS is unavailable because each measurement exits after one sample. Lock contention is not applicable to this single-thread fixture. Both states use the exact same runner, so this runtime-toggle A/B does not claim to measure compile-time support code size.",
  );
  if (metadata_.host_class === "diagnostic")
    rows.push("", "This is diagnostic evidence. It does not establish a negligible-overhead publication claim; that requires an explicitly selected quiet reference host on AC power.");
  if (rawPath) rows.push("", `Raw samples: [\`${rawPath.split("/").pop()}\`](${rawPath.split("/").pop()})`);
  rows.push("");
  return rows.join("\n");
}

function syntheticSamples(instrumentation: Instrumentation = "execution_attribution"): Sample[] {
  const rows: Sample[] = [];
  for (let pair = 0; pair < 2; pair += 1) {
    const order: State[] = pair % 2 === 0 ? ["disabled", "enabled"] : ["enabled", "disabled"];
    order.forEach((state, position) => rows.push({
      identity: { pair_sample: pair, order: position, state, mode: modeFor(instrumentation, state), workload: "representative_json", jobs: 110, checksum: 5864992 },
      metrics: {
        wall_time_ns: state === "disabled" ? 100 : 102,
        process_wall_time_ns: state === "disabled" ? 200 : 204,
        process_cpu_user_ns: 80,
        process_cpu_system_ns: 20,
        peak_rss_bytes: 10_200_000,
        thermal_state: { status: "measured", before: "nominal", after: "nominal" },
        instructions: { status: "measured", value: 1000 + pair },
        cycles: { status: "measured", value: 500 + pair },
        process_energy_nj: { status: "measured", value: 200 + pair },
        package_idle_wakeups: { status: "measured", value: 1 },
        interrupt_wakeups: { status: "measured", value: 2 },
        pageins: { status: "measured", value: 0 },
        page_cache_hits: { status: "measured", value: 3 },
        voluntary_context_switches: { status: "measured", value: 1 },
        involuntary_context_switches: { status: "measured", value: 2 },
        ...(instrumentation === "native_observability" ? { native_observability: {
          live_artifacts: 1,
          live_code_bytes: 16384,
          baseline_publications: 0,
          optimizer_publications: 1,
          live_registrations: state === "enabled" ? 1 : 0,
          live_symfile_bytes: state === "enabled" ? 1335 : 0,
          live_unwind_bytes: state === "enabled" ? 72 : 0,
          registrations: state === "enabled" ? 1 : 0,
          unregistrations: 0,
          live_peak_rss_bytes: 10_200_000,
          retained_rss_bytes: state === "enabled" ? 10_100_000 : 10_000_000,
          post_teardown_live_registrations: 0,
          post_teardown_live_symfile_bytes: 0,
          post_teardown_live_unwind_bytes: 0,
          post_teardown_registrations: state === "enabled" ? 1 : 0,
          post_teardown_unregistrations: state === "enabled" ? 1 : 0,
          post_teardown_peak_rss_bytes: 10_200_000,
          post_teardown_retained_rss_bytes: state === "enabled" ? 9_100_000 : 9_000_000,
        } } : {}),
      },
    }));
  }
  return rows;
}

function syntheticNoOpSamples(): NoOpSample[] {
  return [0, 1].map((sample) => ({
    sample,
    thermal_state: { status: "measured", before: "nominal", after: "nominal" },
    counters: {
      instructions: { status: "measured", value: 100 + sample },
      cycles: { status: "measured", value: 50 + sample },
      process_energy_nj: { status: "measured", value: 20 + sample },
      package_idle_wakeups: { status: "measured", value: 0 },
      interrupt_wakeups: { status: "measured", value: 1 },
      pageins: { status: "measured", value: 0 },
      page_cache_hits: { status: "measured", value: 2 },
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
  const darwinFixture = "zig-js-darwin-rusage\tsingle\trepresentative_json\t110\t0\tmeasured\t1000\t500\t200\t1\t2\t0\t3\t0\t0\n",
    owned = parseDarwinCounters(darwinFixture, "single", "representative_json", 110), thermal = parseDarwinThermalState(darwinFixture, "single", "representative_json", 110);
  requireValue(owned.instructions.status === "measured" && owned.process_energy_nj.value === 200 && owned.page_cache_hits.value === 3 && thermal.status === "measured" && thermal.before === "nominal", "owned Darwin telemetry parse drift");
  const nativeFixture = "zig-js-native-observability\tsingle_observed\trepresentative_json\t110\t0\t1\t16384\t0\t1\t1\t1335\t72\t1\t0\t10200000\t10100000\nzig-js-native-observability-retired\tsingle_observed\trepresentative_json\t110\t0\t0\t0\t1\t1\t10200000\t9100000\n",
    nativeParsed = parseNativeObservability(nativeFixture, "single_observed", "representative_json", 110);
  requireValue(nativeParsed.live_peak_rss_bytes === 10_200_000 && nativeParsed.retained_rss_bytes === 10_100_000 && nativeParsed.post_teardown_unregistrations === 1, "native observability telemetry parse drift");
  const samples = syntheticSamples(), noOpSamples = syntheticNoOpSamples(), artifact = {
    schema_version: 5,
    profile_id: "zig-js-instrumentation-overhead-v5",
    metadata: { instrumentation: "execution_attribution", pairs: 2, host_class: "diagnostic", runner_path: "/tmp/runner", runner_sha256: "a".repeat(64), runner_size_bytes: 1, workload: "representative_json", workload_source: "bench/representative_comparison.js", workload_source_sha256: "b".repeat(64), jobs: 110, expected_checksum: 5864992, revision: "c".repeat(40), environment: { Date: "2026-08-04", Host: "fixture", OS: "fixture", Zig: "fixture", "zig-gc": "d".repeat(40), "zig-regex": "e".repeat(40), Power: "Battery Power" } },
    samples,
    summary: summarize(samples),
    calibration: {
      no_op: { command: ["env", "LC_ALL=C", "/usr/bin/time", "-l", "/tmp/runner", "--darwin-rusage-noop"], samples: noOpSamples },
      known_work: { sample_state: "disabled", sample_pairs: [0, 1] },
    },
    counter_capabilities: capabilityInventory(noOpSamples, samples),
    boundaries: { retained_rss: { status: "unavailable" }, contention: { status: "not_applicable" }, code_size: { status: "same_binary" } },
  };
  validateArtifact(artifact);
  requireValue(artifact.counter_capabilities.instructions.availability.status === "measured", "measured capability drift");
  requireValue(artifact.counter_capabilities.cache_misses.availability.status === "unavailable", "unavailable capability drift");
  requireValue(artifact.counter_capabilities.thermal_state.availability.status === "measured" && artifact.summary.thermal_state.boundaries_stable, "thermal capability drift");
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
  reference.metadata.environment.Power = "AC Power";
  const thermalDrift = JSON.parse(JSON.stringify(reference));
  thermalDrift.samples[0].metrics.thermal_state.after = "fair";
  thermalDrift.summary = summarize(thermalDrift.samples);
  thermalDrift.counter_capabilities = capabilityInventory(thermalDrift.calibration.no_op.samples, thermalDrift.samples);
  expectFailure(() => validateArtifact(thermalDrift), "requires stable nominal thermal state");
  (reference.samples.filter((sample: Sample) => sample.identity.state === "disabled")[1].metrics.process_energy_nj as any).value = 1000;
  reference.summary = summarize(reference.samples);
  reference.counter_capabilities = capabilityInventory(reference.calibration.no_op.samples, reference.samples);
  expectFailure(() => validateArtifact(reference), "requires stable known-work process_energy_nj");
  const nativeSamples = syntheticSamples("native_observability"), native = JSON.parse(JSON.stringify(artifact));
  native.metadata.instrumentation = "native_observability";
  native.samples = nativeSamples;
  native.summary = summarize(nativeSamples);
  native.counter_capabilities = capabilityInventory(native.calibration.no_op.samples, nativeSamples);
  native.boundaries.retained_rss = { status: "measured", source: "task_vm_info resident_size before and after Context teardown" };
  validateArtifact(native);
  requireValue(native.summary.native_observability.live_symfile_bytes.enabled_median === 1335, "native publisher byte summary drift");
  const tierDrift = JSON.parse(JSON.stringify(native));
  tierDrift.samples[0].metrics.native_observability.live_code_bytes += 4;
  expectFailure(() => validateArtifact(tierDrift), "tier parity drift");
  const teardownDrift = JSON.parse(JSON.stringify(native));
  teardownDrift.samples.find((sample: Sample) => sample.identity.state === "enabled").metrics.native_observability.post_teardown_live_symfile_bytes = 1;
  expectFailure(() => validateArtifact(teardownDrift), "survived teardown");
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
  let manifestPath = DEFAULT_MANIFEST, workload = "representative_json", pairs = 7, hostClass = "diagnostic", instrumentation: Instrumentation = "execution_attribution", rawOut = "", markdownOut = "", quick = false;
  for (let index = 1; index < args.length; index += 1) {
    const name = args[index];
    if (name === "--quick") quick = true;
    else {
      const value = args[++index];
      if (name === "--manifest") manifestPath = value;
      else if (name === "--workload") workload = value;
      else if (name === "--pairs") pairs = Number(value);
      else if (name === "--host-class") hostClass = value;
      else if (name === "--instrumentation") instrumentation = value as Instrumentation;
      else if (name === "--raw-out") rawOut = value;
      else if (name === "--markdown-out") markdownOut = value;
      else throw new Error(`unknown argument: ${name}`);
    }
  }
  if (quick && pairs === 7) pairs = 2;
  requireValue(Boolean(rawOut) === Boolean(markdownOut), "raw and Markdown overhead outputs must be written together");
  requireValue(["diagnostic", "quiet_reference"].includes(hostClass), "host class must be diagnostic or quiet_reference");
  requireValue(["execution_attribution", "native_observability"].includes(instrumentation), "instrumentation must be execution_attribution or native_observability");
  const manifest = loadManifest(manifestPath); validateManifest(manifest);
  const resolved = resolveWorkload(manifest, workload, quick), info = metadata();
  ensurePublishable(info, Boolean(rawOut));
  const noOpSamples = collectNoOp(runner, pairs);
  const samples = collect(runner, instrumentation, workload, resolved.jobs, resolved.checksum, pairs), size = Number(run(["/usr/bin/stat", "-f", "%z", runner]).stdout.trim());
  const artifact = {
    schema_version: 5,
    profile_id: "zig-js-instrumentation-overhead-v5",
    metadata: {
      environment: info,
      host_class: hostClass,
      instrumentation,
      revision: info["zig-js"],
      runner_path: runner,
      runner_sha256: sha256File(runner),
      runner_size_bytes: size,
      workload,
      workload_source: resolved.source,
      workload_source_sha256: sha256File(resolved.source),
      jobs: resolved.jobs,
      expected_checksum: resolved.checksum,
      pairs,
      timed_boundary: "one warmed single-context invocation; process wall/CPU and peak RSS cover the complete fresh runner lifecycle",
    },
    samples,
    summary: summarize(samples),
    calibration: {
      no_op: { command: ["env", "LC_ALL=C", "/usr/bin/time", "-l", runner, "--darwin-rusage-noop"], samples: noOpSamples },
      known_work: { sample_state: "disabled", sample_pairs: samples.filter((sample) => sample.identity.state === "disabled").map((sample) => sample.identity.pair_sample) },
    },
    counter_capabilities: capabilityInventory(noOpSamples, samples),
    boundaries: {
      retained_rss: instrumentation === "native_observability"
        ? { status: "measured", source: "Mach task_vm_info resident_size immediately before and after Context teardown" }
        : { status: "unavailable", reason: "the execution-attribution runner does not emit an in-process retained boundary" },
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
