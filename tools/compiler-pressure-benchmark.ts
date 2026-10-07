/** Collect and publish the independent-Context synchronous compiler-pressure matrix. */
import { cpuCount, readText, run, sha256File, writeText } from "./lib/home";

declare const __dirname: string;
declare const __filename: string;

const ROOT =
  __dirname === "tools"
    ? "."
    : __dirname.slice(0, __dirname.lastIndexOf("/tools"));
const MODES = ["jit_off", "jit_on"];
const PHASES = ["cold", "warm", "teardown"];
const VARIANTS = ["parent", "candidate"];
const COMPILER_FIELDS = [
  "baseline_attempts",
  "baseline_tier_ups",
  "baseline_tier_up_ns",
  "baseline_failures",
  "baseline_failure_ns",
  "optimizer_attempts",
  "optimizer_tier_ups",
  "optimizer_tier_up_ns",
  "optimizer_failures",
  "optimizer_failure_ns",
  "baseline_publications",
  "optimizer_publications",
  "generated_code_bytes",
];
const RUNTIME_DELTA_FIELDS = [
  "requests",
  "starts",
  "completions",
  "typed_slot_reuses",
  "nested_reuses",
  "host_reserved_admissions",
  "general_slot_admissions",
  "waits",
  "wait_ns",
];
const RUNTIME_STATE_FIELDS = [
  "active_before",
  "active_after",
  "waiters_before",
  "waiters_after",
  "peak_active_after",
  "peak_waiters_after",
  "wait_ns_max_after",
  "general_active_before",
  "general_active_after",
  "host_reserved_active_before",
  "host_reserved_active_after",
  "peak_general_active_after",
  "peak_host_reserved_active_after",
];
const SCRATCH_DELTA_FIELDS = [
  "requests",
  "requested_bytes",
  "admissions",
  "admitted_bytes",
  "policy_rejections",
  "rejected_bytes",
  "allocator_failures",
  "rollback_bytes",
  "releases",
  "released_bytes",
];
const SCRATCH_STATE_FIELDS = ["current_before", "current_after", "peak_after"];
const SCRATCH_DOMAINS = ["gc_auxiliary", "native_compilation", "wasm_compilation"];

type RecordValue = Record<string, any>;
type Row = RecordValue & { iteration: number };
type Baseline = {
  path: string;
  sha256: string;
  evidence: RecordValue;
};

function requireValue(condition: boolean, message: string): void {
  if (!condition) throw new Error(message);
}

const output = (argv: string[], fallback = "unavailable"): string => {
  try {
    const result = run(argv);
    return result.exitCode === 0 ? result.stdout.trim() : fallback;
  } catch (_) {
    return fallback;
  }
};

const median = (values: number[]): number => {
  const ordered = values.slice().sort((a, b) => a - b),
    middle = Math.floor(ordered.length / 2);
  return ordered.length % 2
    ? ordered[middle]
    : (ordered[middle - 1] + ordered[middle]) / 2;
};

const rsd = (values: number[]): number => {
  if (values.length <= 1) return 0;
  const mean = values.reduce((sum, value) => sum + value, 0) / values.length;
  return (
    (Math.sqrt(
      values.reduce((sum, value) => sum + (value - mean) ** 2, 0) /
        (values.length - 1),
    ) /
      mean) *
    100
  );
};

function integer(value: any, name: string): void {
  requireValue(
    Number.isSafeInteger(value) && value >= 0,
    `${name} must be a non-negative safe integer, got ${JSON.stringify(value)}`,
  );
}

export function parseInvocation(text: string): {
  metadata: RecordValue;
  rows: RecordValue[];
} {
  const records = text
    .split("\n")
    .filter(Boolean)
    .map((line) => JSON.parse(line));
  requireValue(records.length === 4, `expected metadata plus three phase rows, got ${records.length}`);
  const metadata = records[0],
    rows = records.slice(1);
  requireValue(
    metadata.kind === "zig-js-compiler-pressure-metadata" &&
      metadata.schema === 3 &&
      metadata.source_path === "bench/compiler_pressure.js" &&
      /^[0-9a-f]{64}$/.test(metadata.source_sha256) &&
      metadata.cold_invocations === 10 &&
      metadata.warm_invocations === 3,
    `invalid runner metadata: ${JSON.stringify(metadata)}`,
  );
  integer(metadata.logical_cpus, "metadata.logical_cpus");
  integer(metadata.runtime_thread_schema, "metadata.runtime_thread_schema");
  integer(metadata.lane_configured_stack_bytes, "metadata.lane_configured_stack_bytes");
  requireValue(metadata.logical_cpus > 0, "logical CPU count must be positive");
  requireValue(
    metadata.runtime_thread_schema === 7 || metadata.runtime_thread_schema === 8,
    "unexpected runtime-thread telemetry schema",
  );
  requireValue(typeof metadata.scratch_available === "boolean", "scratch_available must be boolean");
  requireValue(
    metadata.scratch_available === (metadata.runtime_thread_schema >= 8),
    "scratch availability and runtime-thread schema disagree",
  );
  requireValue(metadata.lane_configured_stack_bytes > 0, "configured lane stack must be positive");
  requireValue(typeof metadata.jit_supported === "boolean", "jit_supported must be boolean");
  return { metadata, rows };
}

export function validateInvocation(
  metadata: RecordValue,
  rows: RecordValue[],
  mode: string,
  lanes: number,
  jobs: number,
): void {
  requireValue(MODES.includes(mode), `invalid mode ${mode}`);
  requireValue(rows.length === 3, `expected three phase rows, got ${rows.length}`);
  rows.forEach((row, index) => {
    requireValue(
      row.kind === "zig-js-compiler-pressure" &&
        row.schema === metadata.schema &&
        row.mode === mode &&
        row.phase === PHASES[index] &&
        row.source_sha256 === metadata.source_sha256 &&
        row.lanes === lanes &&
        row.jobs_per_lane === jobs &&
        row.sample === 0,
      `runner row identity mismatch: ${JSON.stringify(row)}`,
    );
    integer(row.elapsed_ns, `${mode}/${lanes}/${row.phase}.elapsed_ns`);
    integer(row.checksum, `${mode}/${lanes}/${row.phase}.checksum`);
    integer(row.configured_stack_bytes, `${mode}/${lanes}/${row.phase}.configured_stack_bytes`);
    requireValue(row.elapsed_ns > 0 && row.checksum > 0, `invalid timing/checksum: ${JSON.stringify(row)}`);
    requireValue(
      row.configured_stack_bytes === lanes * metadata.lane_configured_stack_bytes,
      `configured stack total mismatch: ${JSON.stringify(row)}`,
    );
    for (const field of [
      "cpu_user_ns",
      "cpu_system_ns",
      "peak_rss_bytes_before",
      "peak_rss_bytes_after",
      "retained_rss_bytes_before",
      "retained_rss_bytes_after",
    ]) integer(row.process[field], `${mode}/${lanes}/${row.phase}.process.${field}`);
    if (row.phase !== "teardown")
      requireValue(
        row.process.cpu_user_ns + row.process.cpu_system_ns > 0,
        `zero process CPU: ${JSON.stringify(row)}`,
      );
    for (const field of COMPILER_FIELDS)
      integer(row.compiler[field], `${mode}/${lanes}/${row.phase}.compiler.${field}`);
    for (const field of RUNTIME_DELTA_FIELDS.concat(RUNTIME_STATE_FIELDS))
      integer(row.runtime[field], `${mode}/${lanes}/${row.phase}.runtime.${field}`);
    requireValue(
      row.runtime.requests === row.runtime.starts &&
        row.runtime.starts === row.runtime.completions &&
        row.runtime.active_before === 0 &&
        row.runtime.active_after === 0 &&
        row.runtime.waiters_before === 0 &&
        row.runtime.waiters_after === 0 &&
        row.runtime.general_active_before === 0 &&
        row.runtime.general_active_after === 0 &&
        row.runtime.host_reserved_active_before === 0 &&
        row.runtime.host_reserved_active_after === 0 &&
        row.runtime.typed_slot_reuses === 0 &&
        row.runtime.nested_reuses === 0 &&
        row.runtime.starts ===
          row.runtime.host_reserved_admissions + row.runtime.general_slot_admissions,
      `runtime admission invariants failed: ${JSON.stringify(row.runtime)}`,
    );
    validateScratch(row, metadata, mode);
  });
  requireValue(
    rows.every((row) => row.checksum === rows[0].checksum),
    `${mode}/${lanes}: phase checksum mismatch`,
  );

  const coldRow = rows[0],
    warmRow = rows[1],
    cold = coldRow.compiler,
    warm = warmRow.compiler;
  if (mode === "jit_off") {
    requireValue(
      rows.every((row) => COMPILER_FIELDS.every((field) => row.compiler[field] === 0)),
      `JIT-off published or attempted native code: ${JSON.stringify(rows)}`,
    );
    requireValue(
      RUNTIME_DELTA_FIELDS.every(
        (field) => coldRow.runtime[field] === 0 && warmRow.runtime[field] === 0,
      ),
      `JIT-off entered native compiler admission: ${JSON.stringify(rows)}`,
    );
  } else if (metadata.jit_supported) {
    requireValue(
      cold.baseline_publications === 64 * lanes &&
        cold.baseline_tier_ups === cold.baseline_publications &&
        cold.generated_code_bytes > 0,
      `JIT-on did not publish the exact fixture inventory: ${JSON.stringify(cold)}`,
    );
    requireValue(
      warm.baseline_attempts === 0 &&
        warm.optimizer_attempts === 0 &&
        warm.baseline_publications === 0 &&
        warm.optimizer_publications === 0 &&
        warm.generated_code_bytes === 0,
      `warm phase unexpectedly compiled native code: ${JSON.stringify(warm)}`,
    );
    requireValue(
      coldRow.runtime.requests === cold.baseline_attempts + cold.optimizer_attempts &&
        coldRow.runtime.requests > 0,
      `native compiler attempts and runtime admissions disagree: ${JSON.stringify(rows[0])}`,
    );
    requireValue(
      RUNTIME_DELTA_FIELDS.every((field) => warmRow.runtime[field] === 0),
      `warm phase unexpectedly entered compiler admission: ${JSON.stringify(warmRow.runtime)}`,
    );
  }
}

function validateScratch(row: RecordValue, metadata: RecordValue, mode: string): void {
  requireValue(row.scratch && typeof row.scratch === "object", "missing scratch telemetry");
  const scratch = row.scratch;
  requireValue(scratch.available === metadata.scratch_available, "row scratch availability changed");
  for (const field of SCRATCH_STATE_FIELDS)
    integer(scratch[field], `${mode}/${row.phase}.scratch.${field}`);
  for (const domainName of SCRATCH_DOMAINS) {
    const domain = scratch[domainName];
    requireValue(domain && typeof domain === "object", `missing scratch domain ${domainName}`);
    for (const field of SCRATCH_DELTA_FIELDS.concat(SCRATCH_STATE_FIELDS))
      integer(domain[field], `${mode}/${row.phase}.scratch.${domainName}.${field}`);
  }
  const before = SCRATCH_DOMAINS.reduce(
      (sum, domain) => sum + scratch[domain].current_before,
      0,
    ),
    after = SCRATCH_DOMAINS.reduce(
      (sum, domain) => sum + scratch[domain].current_after,
      0,
    );
  requireValue(
    before === scratch.current_before && after === scratch.current_after,
    `process/domain scratch totals disagree: ${JSON.stringify(scratch)}`,
  );
  if (!scratch.available) {
    requireValue(
      SCRATCH_STATE_FIELDS.every((field) => scratch[field] === 0) &&
        SCRATCH_DOMAINS.every((domain) =>
          SCRATCH_DELTA_FIELDS.concat(SCRATCH_STATE_FIELDS).every(
            (field) => scratch[domain][field] === 0,
          ),
        ),
      `unavailable scratch telemetry was non-zero: ${JSON.stringify(scratch)}`,
    );
    return;
  }
  for (const domainName of SCRATCH_DOMAINS) {
    const domain = scratch[domainName];
    requireValue(
      domain.policy_rejections === 0 &&
        domain.rejected_bytes === 0 &&
        domain.allocator_failures === 0 &&
        domain.rollback_bytes === 0,
      `default-unlimited run rejected scratch: ${JSON.stringify(domain)}`,
    );
  }
  const native = scratch.native_compilation;
  if (mode === "jit_on" && row.phase === "cold") {
    requireValue(
      native.requests > 0 &&
        native.requests === native.admissions &&
        native.requested_bytes === native.admitted_bytes &&
        native.admitted_bytes === native.released_bytes &&
        native.current_before === 0 &&
        native.current_after === 0 &&
        native.peak_after > 0,
      `native compilation scratch did not balance: ${JSON.stringify(native)}`,
    );
  } else {
    requireValue(
      SCRATCH_DELTA_FIELDS.every((field) => native[field] === 0) &&
        native.current_before === 0 &&
        native.current_after === 0,
      `native scratch activity escaped JIT-on cold phase: ${JSON.stringify(native)}`,
    );
  }
  const wasm = scratch.wasm_compilation;
  requireValue(
    SCRATCH_DELTA_FIELDS.every((field) => wasm[field] === 0) &&
      wasm.current_before === 0 &&
      wasm.current_after === 0,
    `compiler-pressure fixture unexpectedly used Wasm scratch: ${JSON.stringify(wasm)}`,
  );
  const gc = scratch.gc_auxiliary;
  if (row.phase === "cold")
    requireValue(
      gc.current_before === 0 && gc.current_after > 0,
      `cold Context construction did not retain GC auxiliary scratch: ${JSON.stringify(gc)}`,
    );
  else if (row.phase === "warm")
    requireValue(
      gc.current_before > 0 && gc.current_after === gc.current_before,
      `warm phase changed Context-owned GC scratch: ${JSON.stringify(gc)}`,
    );
  else
    requireValue(
      gc.current_before > 0 &&
        gc.current_after === 0 &&
        gc.released_bytes >= gc.current_before &&
        scratch.current_after === 0,
      `teardown did not release all process scratch: ${JSON.stringify(scratch)}`,
    );
}

function runInvocation(
  runner: string,
  mode: string,
  lanes: number,
  jobs: number,
  iteration: number,
): { metadata: RecordValue; rows: Row[] } {
  const result = run([runner, mode, String(lanes), String(jobs), "1"]);
  requireValue(
    result.exitCode === 0,
    `runner failed (${mode}, ${lanes} lanes, iteration ${iteration}):\n${result.stderr || result.stdout}`,
  );
  const parsed = parseInvocation(result.stdout);
  validateInvocation(parsed.metadata, parsed.rows, mode, lanes, jobs);
  return {
    metadata: parsed.metadata,
    rows: parsed.rows.map((row) => ({ ...row, iteration })),
  };
}

function matrixLanes(logicalCpus: number): number[] {
  return [1, 2, 4]
    .filter((value) => value <= logicalCpus)
    .concat([logicalCpus, logicalCpus * 2])
    .filter((value) => value <= 1024)
    .filter((value, index, values) => values.indexOf(value) === index);
}

export function collect(
  runner: string,
  samples: number,
  warmups: number,
  logicalCpus: number,
): { runner_metadata: RecordValue; rows: Row[]; lanes: number[] } {
  const lanes = matrixLanes(logicalCpus),
    rows: Row[] = [];
  let runnerMetadata: RecordValue | null = null;
  for (const laneCount of lanes) {
    for (let warmup = 0; warmup < warmups; warmup += 1) {
      const order = warmup % 2 ? MODES.slice().reverse() : MODES;
      for (const mode of order) runInvocation(runner, mode, laneCount, 1, warmup);
    }
    for (let sample = 0; sample < samples; sample += 1) {
      const order = (sample + laneCount) % 2 ? MODES.slice().reverse() : MODES;
      for (const mode of order) {
        const invocation = runInvocation(runner, mode, laneCount, 1, sample);
        if (runnerMetadata === null) runnerMetadata = invocation.metadata;
        else
          requireValue(
            JSON.stringify(runnerMetadata) === JSON.stringify(invocation.metadata),
            "runner metadata changed during the matrix",
          );
        rows.push.apply(rows, invocation.rows);
      }
    }
  }
  requireValue(runnerMetadata !== null, "empty compiler-pressure matrix");
  requireValue(
    (runnerMetadata as RecordValue).jit_supported === true,
    "native compiler pressure requires a JIT-supported host",
  );
  requireValue(
    (runnerMetadata as RecordValue).logical_cpus === logicalCpus,
    `host-width disagreement: collector=${logicalCpus}, runner=${(runnerMetadata as RecordValue).logical_cpus}`,
  );
  validateMatrix(rows, samples, lanes, runnerMetadata as RecordValue);
  return { runner_metadata: runnerMetadata as RecordValue, rows, lanes };
}

function exactLanes(logicalCpus: number): number[] {
  return [1, Math.min(logicalCpus * 2, 1024)].filter(
    (value, index, values) => values.indexOf(value) === index,
  );
}

function exactOrder(index: number): { variant: string; mode: string }[] {
  const orders = [
    [
      { variant: "parent", mode: "jit_off" },
      { variant: "candidate", mode: "jit_off" },
      { variant: "parent", mode: "jit_on" },
      { variant: "candidate", mode: "jit_on" },
    ],
    [
      { variant: "candidate", mode: "jit_on" },
      { variant: "parent", mode: "jit_on" },
      { variant: "candidate", mode: "jit_off" },
      { variant: "parent", mode: "jit_off" },
    ],
    [
      { variant: "parent", mode: "jit_on" },
      { variant: "candidate", mode: "jit_on" },
      { variant: "parent", mode: "jit_off" },
      { variant: "candidate", mode: "jit_off" },
    ],
    [
      { variant: "candidate", mode: "jit_off" },
      { variant: "parent", mode: "jit_off" },
      { variant: "candidate", mode: "jit_on" },
      { variant: "parent", mode: "jit_on" },
    ],
  ];
  return orders[index % orders.length];
}

export function collectExact(
  parentRunner: string,
  candidateRunner: string,
  samples: number,
  warmups: number,
  logicalCpus: number,
): {
  runner_metadata: Record<string, RecordValue>;
  rows: Row[];
  lanes: number[];
} {
  const runners: Record<string, string> = {
      parent: parentRunner,
      candidate: candidateRunner,
    },
    lanes = exactLanes(logicalCpus),
    rows: Row[] = [],
    metadata: Record<string, RecordValue> = {};
  for (const laneCount of lanes) {
    for (let warmup = 0; warmup < warmups; warmup += 1)
      for (const task of exactOrder(warmup + laneCount))
        runInvocation(runners[task.variant], task.mode, laneCount, 1, warmup);
    for (let sample = 0; sample < samples; sample += 1) {
      const order = exactOrder(sample + laneCount);
      for (let orderIndex = 0; orderIndex < order.length; orderIndex += 1) {
        const task = order[orderIndex],
          invocation = runInvocation(
            runners[task.variant],
            task.mode,
            laneCount,
            1,
            sample,
          );
        if (!metadata[task.variant]) metadata[task.variant] = invocation.metadata;
        else
          requireValue(
            JSON.stringify(metadata[task.variant]) === JSON.stringify(invocation.metadata),
            `${task.variant} runner metadata changed during the matrix`,
          );
        rows.push.apply(
          rows,
          invocation.rows.map((row) => ({
            ...row,
            variant: task.variant,
            invocation_order: orderIndex,
          })),
        );
      }
    }
  }
  requireValue(
    metadata.parent?.scratch_available === false &&
      metadata.parent?.runtime_thread_schema === 7,
    "exact parent must expose schema-7 telemetry without scratch counters",
  );
  requireValue(
    metadata.candidate?.scratch_available === true &&
      metadata.candidate?.runtime_thread_schema === 8,
    "candidate must expose schema-8 scratch telemetry",
  );
  requireValue(
    metadata.parent?.schema === metadata.candidate?.schema &&
      metadata.parent?.source_sha256 === metadata.candidate?.source_sha256 &&
      metadata.parent?.cold_invocations === metadata.candidate?.cold_invocations &&
      metadata.parent?.warm_invocations === metadata.candidate?.warm_invocations &&
      metadata.parent?.lane_configured_stack_bytes ===
        metadata.candidate?.lane_configured_stack_bytes,
    "parent and candidate runner fixtures differ",
  );
  for (const variant of VARIANTS) {
    requireValue(metadata[variant]?.jit_supported === true, `${variant} lacks JIT support`);
    requireValue(
      metadata[variant]?.logical_cpus === logicalCpus,
      `${variant} host-width disagreement`,
    );
    validateMatrix(
      rows.filter((row) => row.variant === variant),
      samples,
      lanes,
      metadata[variant],
    );
  }
  for (const laneCount of lanes) {
    const checksums = rows
      .filter((row) => row.lanes === laneCount)
      .map((row) => row.checksum);
    requireValue(
      checksums.every((checksum) => checksum === checksums[0]),
      `parent/candidate checksum mismatch at ${laneCount} lanes`,
    );
  }
  return { runner_metadata: metadata, rows, lanes };
}

const groupKey = (row: Row): string => [row.mode, row.phase, row.lanes].join("\t");

function grouped(rows: Row[]): Record<string, Row[]> {
  const result: Record<string, Row[]> = {};
  for (const row of rows) {
    const key = groupKey(row);
    if (!result[key]) result[key] = [];
    result[key].push(row);
  }
  return result;
}

export function validateMatrix(
  rows: Row[],
  samples: number,
  lanes: number[],
  metadata: RecordValue,
): void {
  const groups = grouped(rows),
    expectedIterations = Array.from({ length: samples }, (_, index) => index);
  requireValue(
    rows.length === samples * lanes.length * MODES.length * PHASES.length,
    `matrix row count mismatch: ${rows.length}`,
  );
  for (const laneCount of lanes) {
    const checksums: Record<string, number> = {};
    for (const mode of MODES) {
      const phaseGroups: Record<string, Row[]> = {};
      for (const phase of PHASES) {
        const key = [mode, phase, laneCount].join("\t"),
          selected = groups[key] || [];
        phaseGroups[phase] = selected;
        requireValue(
          JSON.stringify(selected.map((row) => row.iteration).sort((a, b) => a - b)) ===
            JSON.stringify(expectedIterations),
          `missing or duplicate iterations for ${key}`,
        );
        requireValue(
          selected.every((row) => row.checksum === selected[0].checksum),
          `checksum changed within ${key}`,
        );
        checksums[`${mode}\t${phase}`] = selected[0].checksum;
      }
      for (let iteration = 0; iteration < samples; iteration += 1)
        validateInvocation(
          metadata,
          PHASES.map((phase) => phaseGroups[phase].find((row) => row.iteration === iteration)),
          mode,
          laneCount,
          1,
        );
    }
    requireValue(
      checksums["jit_off\tcold"] === checksums["jit_on\tcold"] &&
        checksums["jit_off\twarm"] === checksums["jit_on\twarm"] &&
        checksums["jit_off\tteardown"] === checksums["jit_on\tteardown"],
      `JIT-on/off checksum mismatch at ${laneCount} lanes`,
    );
    if (laneCount === metadata.logical_cpus * 2)
      requireValue(
        (groups[["jit_on", "cold", laneCount].join("\t")] || []).every(
          (row) => row.runtime.waits > 0 && row.runtime.wait_ns > 0,
        ),
        `oversubscribed JIT-on samples did not exercise the compiler queue`,
      );
  }
}

function revision(path: string): string {
  return output(["git", "-C", path, "rev-parse", "HEAD"]);
}

function assertCleanPath(path: string, name: string): void {
  const dirty = output(
    ["git", "-C", path, "status", "--porcelain", "--untracked-files=no"],
    "status unavailable",
  );
  requireValue(!dirty, `refusing publication from dirty tracked ${name} inputs:\n${dirty}`);
}

function assertClean(gcPath = `${ROOT}/../zig-gc`, regexPath = `${ROOT}/../zig-regex`): void {
  assertCleanPath(ROOT, "zig-js");
  assertCleanPath(gcPath, "zig-gc");
  assertCleanPath(regexPath, "zig-regex");
}

function environment(
  runner: string,
  zig: string,
  samples: number,
  warmups: number,
  gcPath = `${ROOT}/../zig-gc`,
  regexPath = `${ROOT}/../zig-regex`,
): Record<string, string> {
  const hardware = output([
      "/usr/sbin/system_profiler",
      "SPHardwareDataType",
      "-detailLevel",
      "mini",
    ]),
    hardwareValue = (name: string): string => {
      const prefix = `${name}:`,
        line = hardware
          .split("\n")
          .map((entry) => entry.trim())
          .find((entry) => entry.startsWith(prefix));
      return line ? line.slice(prefix.length).trim() : "unavailable";
    },
    coreCount = hardwareValue("Total Number of Cores").split(" ")[0] || "unavailable",
    memoryNumber = hardwareValue("Memory").split(" ")[0],
    memory = memoryNumber ? `${Number(memoryNumber).toFixed(1)} GiB` : "unavailable";
  return {
    Date: output(["date", "+%Y-%m-%dT%H:%M:%S%z"]),
    Host: `${hardwareValue("Chip")}; ${coreCount} physical / ${coreCount} logical CPUs; ${memory}`,
    OS: `macOS ${output(["sw_vers", "-productVersion"])} (${output(["sw_vers", "-buildVersion"])})`,
    Zig: output([zig, "version"]),
    "zig-js": revision(ROOT),
    "zig-gc": revision(gcPath),
    "zig-regex": revision(regexPath),
    "Runner SHA-256": sha256File(runner),
    Samples: String(samples),
    Warmups: String(warmups),
    Power: output(["pmset", "-g", "batt"]).split(/\s+/).join(" "),
  };
}

function selected(rows: Row[], mode: string, phase: string, lanes: number): Row[] {
  const result = rows.filter(
    (row) => row.mode === mode && row.phase === phase && row.lanes === lanes,
  );
  requireValue(result.length > 0, `missing ${mode}/${phase}/${lanes} rows`);
  return result;
}

function loadBaseline(
  path: string,
  runnerMetadata: RecordValue,
  info: Record<string, string>,
): Baseline {
  const evidence = JSON.parse(readText(path));
  requireValue(
    evidence.kind === "zig-js-compiler-pressure-evidence" &&
      evidence.schema === 1 &&
      evidence.runner_metadata?.schema === 1 &&
      evidence.runner_metadata?.source_sha256 === runnerMetadata.source_sha256 &&
      evidence.runner_metadata?.logical_cpus === runnerMetadata.logical_cpus &&
      evidence.runner_metadata?.jit_supported === runnerMetadata.jit_supported &&
      evidence.runner_metadata?.cold_invocations === runnerMetadata.cold_invocations &&
      evidence.runner_metadata?.warm_invocations === runnerMetadata.warm_invocations &&
      Array.isArray(evidence.lanes) &&
      Array.isArray(evidence.rows) &&
      evidence.rows.length > 0,
    `invalid compiler-pressure baseline ${path}`,
  );
  for (const key of ["Host", "OS", "Zig", "zig-gc", "zig-regex", "Samples", "Warmups"])
    requireValue(
      evidence.metadata?.[key] === info[key],
      `baseline environment mismatch for ${key}: ${evidence.metadata?.[key]} != ${info[key]}`,
    );
  for (const row of evidence.rows) {
    requireValue(
      row.kind === "zig-js-compiler-pressure" &&
        row.schema === 1 &&
        MODES.includes(row.mode) &&
        PHASES.includes(row.phase) &&
        evidence.lanes.includes(row.lanes) &&
        row.source_sha256 === runnerMetadata.source_sha256,
      `invalid baseline row: ${JSON.stringify(row)}`,
    );
    integer(row.elapsed_ns, "baseline.elapsed_ns");
    integer(row.iteration, "baseline.iteration");
    for (const field of COMPILER_FIELDS) integer(row.compiler[field], `baseline.compiler.${field}`);
  }
  return { path, sha256: sha256File(path), evidence };
}

const compilerNs = (row: Row): number =>
  row.compiler.baseline_tier_up_ns +
  row.compiler.baseline_failure_ns +
  row.compiler.optimizer_tier_up_ns +
  row.compiler.optimizer_failure_ns;

const processCpuNs = (row: Row): number =>
  row.process.cpu_user_ns + row.process.cpu_system_ns;

export function render(
  rows: Row[],
  lanes: number[],
  info: Record<string, string>,
  rawPath: string | null,
  baseline: Baseline | null = null,
): string {
  const reportPath = rawPath?.endsWith(".json")
    ? `${rawPath.slice(0, -5)}.md`
    : "docs/.data/compiler-pressure-YYYY-MM-DD.md";
  const lines = [
    `# Synchronous compiler pressure — ${info.Date.slice(0, 10)}`,
    "",
    "> Dated independent-Context measurement, not a general engine score. Lower wall and CPU time are better.",
    "> JIT-off forces required bytecode and is the exact source/checksum control. Every JIT-on cold lane must publish 64 baseline artifacts; warm phases must publish none.",
    "",
    "## Environment",
    "",
    "| item | value |",
    "| --- | --- |",
  ];
  Object.keys(info).forEach((key) => lines.push(`| ${key} | ${info[key]} |`));
  lines.push(
    "",
    "## Cold Context and compiler pressure",
    "",
    "| lanes | mode | wall p50 | process CPU p50 | summed compiler p50 | CPU / wall | throughput scaling | wall RSD | baseline publications | generated code | configured stacks | peak RSS p50 |",
    "| ---: | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |",
  );
  const oneLane: Record<string, number> = {};
  for (const mode of MODES)
    oneLane[mode] = median(selected(rows, mode, "cold", 1).map((row) => row.elapsed_ns));
  for (const laneCount of lanes)
    for (const mode of MODES) {
      const group = selected(rows, mode, "cold", laneCount),
        elapsed = median(group.map((row) => row.elapsed_ns)),
        cpu = median(group.map(processCpuNs)),
        compile = median(group.map(compilerNs)),
        publications = median(group.map((row) => row.compiler.baseline_publications)),
        generated = median(group.map((row) => row.compiler.generated_code_bytes)),
        configuredStack = median(group.map((row) => row.configured_stack_bytes)),
        peak = median(group.map((row) => row.process.peak_rss_bytes_after));
      lines.push(
        `| ${laneCount} | ${mode} | ${(elapsed / 1e6).toFixed(2)} ms | ${(cpu / 1e6).toFixed(2)} ms | ${(compile / 1e6).toFixed(2)} ms | ${(cpu / elapsed).toFixed(2)}x | ${((oneLane[mode] * laneCount) / elapsed).toFixed(2)}x | ${rsd(group.map((row) => row.elapsed_ns)).toFixed(2)}% | ${publications.toFixed(0)} | ${(generated / 1024 / 1024).toFixed(2)} MiB | ${(configuredStack / 1024 / 1024).toFixed(2)} MiB | ${(peak / 1024 / 1024).toFixed(2)} MiB |`,
      );
    }
  if (baseline) {
    const baselineRows = baseline.evidence.rows as Row[],
      commonLanes = baseline.evidence.lanes.filter((lane: number) => lanes.includes(lane));
    lines.push(
      "",
      "## Exact pre-admission comparison",
      "",
      `The control is ${baseline.path.split("/").pop()} at SHA-256 \`${baseline.sha256}\`, revision \`${baseline.evidence.metadata["zig-js"]}\`. Host, OS, Zig, zig-gc, zig-regex, source checksum, lane widths, invocation counts, samples, and warmups match. The zig-js revision and runner schema differ; each artifact records its own collection time, runner hash, and power status.`,
      "",
      "| lanes | baseline wall p50 | coordinated wall p50 | wall change | baseline CPU p50 | coordinated CPU p50 | CPU change |",
      "| ---: | ---: | ---: | ---: | ---: | ---: | ---: |",
    );
    for (const laneCount of commonLanes) {
      const before = selected(baselineRows, "jit_on", "cold", laneCount),
        after = selected(rows, "jit_on", "cold", laneCount),
        beforeWall = median(before.map((row) => row.elapsed_ns)),
        afterWall = median(after.map((row) => row.elapsed_ns)),
        beforeCpu = median(before.map(processCpuNs)),
        afterCpu = median(after.map(processCpuNs));
      lines.push(
        `| ${laneCount} | ${(beforeWall / 1e6).toFixed(2)} ms | ${(afterWall / 1e6).toFixed(2)} ms | ${(((afterWall / beforeWall) - 1) * 100).toFixed(1)}% | ${(beforeCpu / 1e6).toFixed(2)} ms | ${(afterCpu / 1e6).toFixed(2)} ms | ${(((afterCpu / beforeCpu) - 1) * 100).toFixed(1)}% |`,
      );
    }
  }
  lines.push(
    "",
    "Throughput scaling is one-lane wall multiplied by lanes, then divided by current wall. Process CPU divided by wall shows aggregate concurrency; summed compiler time adds independently timed tier attempts across lanes and can exceed wall time.",
    "",
    "## Runtime admission",
    "",
    "| lanes | mode | requests p50 | reserved p50 | general p50 | queued p50 | total wait p50 | peak compiler work | peak general slots | peak reserved lane |",
    "| ---: | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |",
  );
  for (const laneCount of lanes)
    for (const mode of MODES) {
      const group = selected(rows, mode, "cold", laneCount);
      lines.push(
        `| ${laneCount} | ${mode} | ${median(group.map((row) => row.runtime.requests)).toFixed(0)} | ${median(group.map((row) => row.runtime.host_reserved_admissions)).toFixed(0)} | ${median(group.map((row) => row.runtime.general_slot_admissions)).toFixed(0)} | ${median(group.map((row) => row.runtime.waits)).toFixed(0)} | ${(median(group.map((row) => row.runtime.wait_ns)) / 1e6).toFixed(2)} ms | ${median(group.map((row) => row.runtime.peak_active_after)).toFixed(0)} | ${median(group.map((row) => row.runtime.peak_general_active_after)).toFixed(0)} | ${median(group.map((row) => row.runtime.peak_host_reserved_active_after)).toFixed(0)} |`,
      );
    }
  lines.push(
    "",
    "Every runtime row is captured from the process-wide runtime-thread snapshot. The harness requires completed request/start/completion balance, zero residual active work or waiters, no typed or nested reuse in these untyped host lanes, and an exact reserved-plus-general admission total. The 2×-logical-CPU samples must enter the compiler queue.",
  );
  const oversubscribedLanes = lanes[lanes.length - 1],
    hostLanes = oversubscribedLanes / 2,
    hostRows = selected(rows, "jit_on", "cold", hostLanes),
    oversubscribedRows = selected(rows, "jit_on", "cold", oversubscribedLanes),
    hostWall = median(hostRows.map((row) => row.elapsed_ns)),
    baselineHostRows = baseline
      ? selected(baseline.evidence.rows as Row[], "jit_on", "cold", hostLanes)
      : null,
    hostWallChange = baselineHostRows
      ? (hostWall / median(baselineHostRows.map((row) => row.elapsed_ns)) - 1) * 100
      : null;
  lines.push(
    "",
    "## Decision",
    "",
    `At ${hostLanes} lanes, peak compiler work reaches the ${hostLanes}-CPU host capacity${hostWallChange === null ? "" : ` while cold JIT wall changes ${hostWallChange.toFixed(1)}% from the exact pre-admission baseline`}. At ${oversubscribedLanes} lanes, the median queues ${median(oversubscribedRows.map((row) => row.runtime.waits)).toFixed(0)} of ${median(oversubscribedRows.map((row) => row.runtime.requests)).toFixed(0)} compiler attempts and holds peak active work to ${median(oversubscribedRows.map((row) => row.runtime.peak_active_after)).toFixed(0)}.`,
    "This evidence does not justify an asynchronous artifact queue. Synchronous admission already saturates the available CPU budget at host width and applies bounded backpressure when oversubscribed; an asynchronous queue would add artifact ownership, cancellation, and teardown lifetimes without adding execution capacity.",
    "",
    "## Warm execution control",
    "",
    "| lanes | mode | wall p50 | process CPU p50 | wall RSD | new publications |",
    "| ---: | --- | ---: | ---: | ---: | ---: |",
  );
  for (const laneCount of lanes)
    for (const mode of MODES) {
      const group = selected(rows, mode, "warm", laneCount);
      lines.push(
        `| ${laneCount} | ${mode} | ${(median(group.map((row) => row.elapsed_ns)) / 1e6).toFixed(3)} ms | ${(median(group.map(processCpuNs)) / 1e6).toFixed(3)} ms | ${rsd(group.map((row) => row.elapsed_ns)).toFixed(2)}% | ${median(group.map((row) => row.compiler.baseline_publications + row.compiler.optimizer_publications)).toFixed(0)} |`,
      );
    }
  const sourceSha = rows[0].source_sha256;
  lines.push(
    "",
    "## Method and boundaries",
    "",
    `The matrix contains ${rows.length.toLocaleString("en-US")} phase rows. Each cell uses ${info.Samples} fresh-process samples after ${info.Warmups} discarded warmup process(es); JIT-on/off launch order alternates. Reported values are medians, with sample RSD shown for wall time.`,
    `The fixed source is \`bench/compiler_pressure.js\` at SHA-256 \`${sourceSha}\`. Each lane owns a fresh creator-thread-affine Context. Cold timing starts before OS-thread creation and includes Context construction, source parsing/bytecode setup, ten fixture invocations, native compilation/publication, and the completion wait.`,
    "Warm timing reuses the live Contexts for three invocations. A separate teardown phase joins every lane and destroys each Context. Process CPU comes from `getrusage`; peak and retained RSS use Darwin `task_vm_info`.",
    "The measured revision compiles synchronously on the calling lane. Runtime admission bounds simultaneous compiler CPU work without changing checksums, publication counts, or warm behavior.",
    rawPath ? `Raw evidence: [${rawPath.split("/").pop()}](${rawPath.split("/").pop()})` : "Raw evidence was printed only; pass --raw-out to preserve it.",
    "",
    "## Reproduce",
    "",
    "```bash",
    `zig build compiler-pressure-benchmark -Dcompiler-pressure-raw-out=${rawPath || "docs/.data/compiler-pressure-YYYY-MM-DD.json"} -Dcompiler-pressure-markdown-out=${reportPath}`,
    "```",
    "",
  );
  return lines.join("\n");
}

function exactSelected(
  rows: Row[],
  variant: string,
  mode: string,
  phase: string,
  lanes: number,
): Row[] {
  const result = rows.filter(
    (row) =>
      row.variant === variant &&
      row.mode === mode &&
      row.phase === phase &&
      row.lanes === lanes,
  );
  requireValue(result.length > 0, `missing ${variant}/${mode}/${phase}/${lanes} rows`);
  return result;
}

const mib = (bytes: number): string => `${(bytes / 1024 / 1024).toFixed(2)} MiB`;
const ms = (ns: number): string => `${(ns / 1e6).toFixed(2)} ms`;
const percentChange = (before: number, after: number): string =>
  `${(((after / before) - 1) * 100).toFixed(1)}%`;

export function renderExact(
  rows: Row[],
  lanes: number[],
  info: Record<string, string>,
  rawPath: string | null,
  parentRevision: string,
  candidateRevision: string,
  runnerMetadata: Record<string, RecordValue>,
): string {
  const lines = [
    `# Exact-parent compiler scratch — ${info.Date.slice(0, 10)}`,
    "",
    "> Paired independent-Context measurement for issue #1027, not a general engine score. Lower wall, CPU, RSS, and teardown time are better.",
    "> Parent and candidate use the same benchmark source, Zig, zig-gc, zig-regex, host, lane widths, and checksums. Invocation order alternates across samples.",
    "",
    "## Provenance",
    "",
    "| item | value |",
    "| --- | --- |",
    `| Parent engine | \`${parentRevision}\` |`,
    `| Candidate engine | \`${candidateRevision}\` |`,
    `| Parent runner | \`${info["Parent runner SHA-256"]}\` |`,
    `| Candidate runner | \`${info["Candidate runner SHA-256"]}\` |`,
    `| Workload | \`bench/compiler_pressure.js\` at \`${runnerMetadata.candidate.source_sha256}\` |`,
  ];
  Object.keys(info)
    .filter((key) => !key.toLowerCase().includes("runner sha-256"))
    .forEach((key) => lines.push(`| ${key} | ${info[key]} |`));
  lines.push(
    "",
    "## Cold phase comparison",
    "",
    "| lanes | mode | parent wall p50 | candidate wall p50 | wall change | parent CPU p50 | candidate CPU p50 | CPU change | parent peak RSS p50 | candidate peak RSS p50 | RSS change | checksum |",
    "| ---: | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |",
  );
  for (const laneCount of lanes)
    for (const mode of MODES) {
      const parent = exactSelected(rows, "parent", mode, "cold", laneCount),
        candidate = exactSelected(rows, "candidate", mode, "cold", laneCount),
        parentWall = median(parent.map((row) => row.elapsed_ns)),
        candidateWall = median(candidate.map((row) => row.elapsed_ns)),
        parentCpu = median(parent.map(processCpuNs)),
        candidateCpu = median(candidate.map(processCpuNs)),
        parentRss = median(parent.map((row) => row.process.peak_rss_bytes_after)),
        candidateRss = median(candidate.map((row) => row.process.peak_rss_bytes_after));
      lines.push(
        `| ${laneCount} | ${mode} | ${ms(parentWall)} | ${ms(candidateWall)} | ${percentChange(parentWall, candidateWall)} | ${ms(parentCpu)} | ${ms(candidateCpu)} | ${percentChange(parentCpu, candidateCpu)} | ${mib(parentRss)} | ${mib(candidateRss)} | ${percentChange(parentRss, candidateRss)} | ${candidate[0].checksum} |`,
      );
    }
  lines.push(
    "",
    "Wall-time RSD by paired cell:",
    "",
    "| lanes | mode | parent RSD | candidate RSD | parent throughput | candidate throughput |",
    "| ---: | --- | ---: | ---: | ---: | ---: |",
  );
  for (const laneCount of lanes)
    for (const mode of MODES) {
      const parent = exactSelected(rows, "parent", mode, "cold", laneCount),
        candidate = exactSelected(rows, "candidate", mode, "cold", laneCount),
        operations = laneCount * runnerMetadata.candidate.cold_invocations;
      lines.push(
        `| ${laneCount} | ${mode} | ${rsd(parent.map((row) => row.elapsed_ns)).toFixed(2)}% | ${rsd(candidate.map((row) => row.elapsed_ns)).toFixed(2)}% | ${(operations * 1e9 / median(parent.map((row) => row.elapsed_ns))).toFixed(2)} fixture invocations/s | ${(operations * 1e9 / median(candidate.map((row) => row.elapsed_ns))).toFixed(2)} fixture invocations/s |`,
      );
    }
  lines.push(
    "",
    "## Candidate scratch accounting",
    "",
    "| lanes | mode | process peak p50 | GC peak p50 | native requested p50 | native released p50 | native peak p50 | policy rejections | allocator failures |",
    "| ---: | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |",
  );
  for (const laneCount of lanes)
    for (const mode of MODES) {
      const group = exactSelected(rows, "candidate", mode, "cold", laneCount);
      lines.push(
        `| ${laneCount} | ${mode} | ${mib(median(group.map((row) => row.scratch.peak_after)))} | ${mib(median(group.map((row) => row.scratch.gc_auxiliary.peak_after)))} | ${mib(median(group.map((row) => row.scratch.native_compilation.requested_bytes)))} | ${mib(median(group.map((row) => row.scratch.native_compilation.released_bytes)))} | ${mib(median(group.map((row) => row.scratch.native_compilation.peak_after)))} | ${median(group.map((row) => row.scratch.native_compilation.policy_rejections)).toFixed(0)} | ${median(group.map((row) => row.scratch.native_compilation.allocator_failures)).toFixed(0)} |`,
      );
    }
  lines.push(
    "",
    "## Teardown",
    "",
    "| lanes | mode | teardown p50 | scratch before p50 | scratch after | GC released p50 |",
    "| ---: | --- | ---: | ---: | ---: | ---: |",
  );
  for (const laneCount of lanes)
    for (const mode of MODES) {
      const group = exactSelected(rows, "candidate", mode, "teardown", laneCount);
      lines.push(
        `| ${laneCount} | ${mode} | ${ms(median(group.map((row) => row.elapsed_ns)))} | ${mib(median(group.map((row) => row.scratch.current_before)))} | ${mib(median(group.map((row) => row.scratch.current_after)))} | ${mib(median(group.map((row) => row.scratch.gc_auxiliary.released_bytes)))} |`,
      );
    }
  lines.push(
    "",
    "The collector rejects any checksum drift, unbalanced runtime admission, default-policy rejection, allocator failure, native scratch retained after cold compilation, native activity outside JIT-on cold execution, Wasm scratch activity in this fixture, or process scratch remaining after Context teardown.",
    "",
    "## Method",
    "",
    `Each cell contains ${info.Samples} fresh-process samples after ${info.Warmups} discarded warmup process(es). Only dedicated (1 lane) and busy (2× logical CPU) widths are measured. The four parent/candidate × JIT-on/off invocations rotate through four balanced orders.`,
    "Cold timing includes lane creation, Context construction, parsing/bytecode setup, ten fixture invocations, synchronous native compilation/publication, and completion. Warm timing reuses live Contexts for three invocations. Teardown joins every lane and destroys every Context.",
    "The parent source tree receives only the updated benchmark runner as a measurement overlay; engine sources remain the exact parent revision. Both runners import the same pinned zig-gc and zig-regex revisions.",
    rawPath
      ? `Raw evidence: [${rawPath.split("/").pop()}](${rawPath.split("/").pop()})`
      : "Raw evidence was printed only; pass --raw-out to preserve it.",
    "",
    "## Reproduce",
    "",
    "```bash",
    "home-tool run tools/compiler-pressure-benchmark.ts --runner /tmp/compiler-pressure-candidate --parent-runner /tmp/compiler-pressure-parent --parent-revision <sha> --candidate-revision <sha> --gc-path <zig-gc> --regex-path <zig-regex> --raw-out <json> --markdown-out <md>",
    "```",
    "",
  );
  return lines.join("\n");
}

function fixtureScratch(
  mode: string,
  phase: string,
  lanes: number,
  available: boolean,
): RecordValue {
  const emptyDomain = () =>
      Object.fromEntries(
        SCRATCH_DELTA_FIELDS.concat(SCRATCH_STATE_FIELDS).map((field) => [field, 0]),
      ),
    gcBytes = 4096 * lanes,
    nativeBytes = 1024 * 1024 * lanes,
    gc = emptyDomain(),
    native = emptyDomain(),
    wasm = emptyDomain();
  if (!available)
    return {
      available: false,
      current_before: 0,
      current_after: 0,
      peak_after: 0,
      gc_auxiliary: gc,
      native_compilation: native,
      wasm_compilation: wasm,
    };
  if (phase === "cold") {
    Object.assign(gc, {
      requests: lanes,
      requested_bytes: gcBytes,
      admissions: lanes,
      admitted_bytes: gcBytes,
      current_after: gcBytes,
      peak_after: gcBytes,
    });
    if (mode === "jit_on")
      Object.assign(native, {
        requests: 64 * lanes,
        requested_bytes: nativeBytes,
        admissions: 64 * lanes,
        admitted_bytes: nativeBytes,
        releases: 64 * lanes,
        released_bytes: nativeBytes,
        peak_after: Math.floor(nativeBytes / 8),
      });
  } else if (phase === "warm") {
    Object.assign(gc, {
      current_before: gcBytes,
      current_after: gcBytes,
      peak_after: gcBytes,
    });
  } else {
    Object.assign(gc, {
      releases: lanes,
      released_bytes: gcBytes,
      current_before: gcBytes,
      peak_after: gcBytes,
    });
  }
  return {
    available: true,
    current_before: phase === "cold" ? 0 : gcBytes,
    current_after: phase === "teardown" ? 0 : gcBytes,
    peak_after: Math.max(gcBytes, native.peak_after),
    gc_auxiliary: gc,
    native_compilation: native,
    wasm_compilation: wasm,
  };
}

function fixtureRow(
  mode: string,
  phase: string,
  lanes: number,
  iteration: number,
  scratchAvailable = true,
): Row {
  const enabled = mode === "jit_on" && phase === "cold",
    requests = enabled ? 64 * lanes : 0,
    waits = enabled && lanes > 8 ? 64 : 0;
  return {
    kind: "zig-js-compiler-pressure",
    schema: 3,
    mode,
    phase,
    source_sha256: "a".repeat(64),
    lanes,
    jobs_per_lane: 1,
    sample: 0,
    iteration,
    elapsed_ns:
      (phase === "cold" ? 20_000_000 : phase === "warm" ? 1_000_000 : 500_000) * lanes,
    checksum: 1000 + lanes,
    configured_stack_bytes: lanes * 16 * 1024 * 1024,
    process: {
      cpu_user_ns: (phase === "cold" ? 18_000_000 : 900_000) * lanes,
      cpu_system_ns: 100_000 * lanes,
      peak_rss_bytes_before: 10_000_000,
      peak_rss_bytes_after: 12_000_000 * lanes,
      retained_rss_bytes_before: 10_000_000,
      retained_rss_bytes_after: 11_000_000 * lanes,
    },
    compiler: Object.fromEntries(
      COMPILER_FIELDS.map((field) => [
        field,
        enabled
          ? field === "baseline_publications" || field === "baseline_tier_ups"
            ? 64 * lanes
            : field === "generated_code_bytes"
              ? 2_000_000 * lanes
              : field === "baseline_attempts"
                ? 64 * lanes
                : field === "baseline_tier_up_ns"
                  ? 10_000_000 * lanes
                  : 0
          : 0,
      ]),
    ),
    runtime: {
      requests,
      starts: requests,
      completions: requests,
      typed_slot_reuses: 0,
      nested_reuses: 0,
      host_reserved_admissions: enabled ? 64 : 0,
      general_slot_admissions: enabled ? requests - 64 : 0,
      waits,
      wait_ns: waits * 1000,
      active_before: 0,
      active_after: 0,
      waiters_before: 0,
      waiters_after: 0,
      peak_active_after: enabled ? Math.min(lanes, 8) : 0,
      peak_waiters_after: waits ? lanes - 8 : 0,
      wait_ns_max_after: waits ? 1000 : 0,
      general_active_before: 0,
      general_active_after: 0,
      host_reserved_active_before: 0,
      host_reserved_active_after: 0,
      peak_general_active_after: enabled ? Math.min(Math.max(lanes - 1, 0), 7) : 0,
      peak_host_reserved_active_after: enabled ? 1 : 0,
    },
    scratch: fixtureScratch(mode, phase, lanes, scratchAvailable),
  };
}

function selfTest(): void {
  const metadata = {
      kind: "zig-js-compiler-pressure-metadata",
      schema: 3,
      source_path: "bench/compiler_pressure.js",
      source_sha256: "a".repeat(64),
      logical_cpus: 8,
      jit_supported: true,
      cold_invocations: 10,
      warm_invocations: 3,
      runtime_thread_schema: 8,
      scratch_available: true,
      lane_configured_stack_bytes: 16 * 1024 * 1024,
    },
    lanes = [1, 2, 4, 8, 16],
    rows: Row[] = [];
  for (const laneCount of lanes)
    for (const mode of MODES)
      for (let iteration = 0; iteration < 3; iteration += 1)
        for (const phase of PHASES)
          rows.push(fixtureRow(mode, phase, laneCount, iteration));
  validateMatrix(rows, 3, lanes, metadata);
  const report = render(rows, lanes, { Date: "2026-09-22", Samples: "3", Warmups: "1" }, "raw.json");
  requireValue(report.includes("| 16 | jit_on |") && report.includes("90 phase rows"), "report fixture was not rendered");

  const invocation = [
    JSON.stringify(metadata),
    JSON.stringify(fixtureRow("jit_on", "cold", 1, 0)),
    JSON.stringify(fixtureRow("jit_on", "warm", 1, 0)),
    JSON.stringify(fixtureRow("jit_on", "teardown", 1, 0)),
  ].join("\n");
  const parsed = parseInvocation(invocation);
  validateInvocation(parsed.metadata, parsed.rows, "jit_on", 1, 1);

  let rejected = false;
  try {
    const invalid = fixtureRow("jit_off", "cold", 1, 0);
    invalid.compiler.generated_code_bytes = 1;
    validateInvocation(
      metadata,
      [
        invalid,
        fixtureRow("jit_off", "warm", 1, 0),
        fixtureRow("jit_off", "teardown", 1, 0),
      ],
      "jit_off",
      1,
      1,
    );
  } catch (_) {
    rejected = true;
  }
  requireValue(rejected, "JIT-off native publication was accepted");

  const parentMetadata = {
      ...metadata,
      runtime_thread_schema: 7,
      scratch_available: false,
    },
    parentRows: Row[] = [],
    candidateRows: Row[] = [];
  for (const laneCount of [1, 16])
    for (const mode of MODES)
      for (let iteration = 0; iteration < 3; iteration += 1)
        for (const phase of PHASES) {
          parentRows.push({
            ...fixtureRow(mode, phase, laneCount, iteration, false),
            variant: "parent",
            invocation_order: iteration % 4,
          });
          candidateRows.push({
            ...fixtureRow(mode, phase, laneCount, iteration),
            variant: "candidate",
            invocation_order: (iteration + 1) % 4,
          });
        }
  validateMatrix(parentRows, 3, [1, 16], parentMetadata);
  validateMatrix(candidateRows, 3, [1, 16], metadata);
  const exactReport = renderExact(
    parentRows.concat(candidateRows),
    [1, 16],
    {
      Date: "2026-10-07",
      Samples: "3",
      Warmups: "1",
      "Parent runner SHA-256": "b".repeat(64),
      "Candidate runner SHA-256": "c".repeat(64),
    },
    "raw.json",
    "parent-sha",
    "candidate-sha",
    { parent: parentMetadata, candidate: metadata },
  );
  requireValue(
    exactReport.includes("Exact-parent compiler scratch") &&
      exactReport.includes("## Candidate scratch accounting"),
    "exact-parent report fixture was not rendered",
  );
  console.log("compiler-pressure-benchmark self-test: ok");
}

function argument(args: string[], name: string): string | null {
  const index = args.indexOf(name);
  return index >= 0 && index + 1 < args.length ? args[index + 1] : null;
}

function main(): void {
  const args = process.argv.slice(2);
  if (args.includes("--self-test")) {
    selfTest();
    return;
  }
  const runner = argument(args, "--runner"),
    parentRunner = argument(args, "--parent-runner"),
    parentRevision = argument(args, "--parent-revision"),
    candidateRevision = argument(args, "--candidate-revision") || revision(ROOT),
    gcPath = argument(args, "--gc-path") || `${ROOT}/../zig-gc`,
    regexPath = argument(args, "--regex-path") || `${ROOT}/../zig-regex`,
    zig = argument(args, "--zig") || "zig",
    rawPath = argument(args, "--raw-out"),
    markdownPath = argument(args, "--markdown-out"),
    baselinePath = argument(args, "--baseline") || `${ROOT}/docs/.data/compiler-pressure-2026-09-22.json`,
    configuredSamples = Number(argument(args, "--samples") || "9"),
    configuredWarmups = Number(argument(args, "--warmups") || "1"),
    quick = args.includes("--quick");
  const samples = quick ? 1 : configuredSamples,
    warmups = quick ? 0 : configuredWarmups;
  requireValue(!!runner, "--runner is required");
  requireValue(
    Number.isSafeInteger(samples) && samples > 0 && Number.isSafeInteger(warmups) && warmups >= 0,
    "samples and warmups must be non-negative integers, with at least one sample",
  );
  if (!quick) {
    requireValue(samples >= 7, "publication requires at least seven samples");
    requireValue(!!rawPath && !!markdownPath, "publication requires --raw-out and --markdown-out");
    assertClean(gcPath, regexPath);
  } else requireValue(!rawPath && !markdownPath, "quick runs cannot publish evidence files");
  const logicalCpus = cpuCount();
  if (parentRunner) {
    requireValue(!!parentRevision, "--parent-revision is required with --parent-runner");
    requireValue(
      /^[0-9a-f]{40,64}$/.test(parentRevision as string) &&
        /^[0-9a-f]{40,64}$/.test(candidateRevision),
      "exact-parent revisions must be full lowercase hexadecimal object IDs",
    );
    requireValue(
      quick || candidateRevision === revision(ROOT),
      "candidate revision does not match the clean checked-out HEAD",
    );
    const exact = collectExact(
        parentRunner,
        runner as string,
        samples,
        warmups,
        logicalCpus,
      ),
      info = environment(runner as string, zig, samples, warmups, gcPath, regexPath);
    info["Parent runner SHA-256"] = sha256File(parentRunner);
    info["Candidate runner SHA-256"] = sha256File(runner as string);
    const raw = {
        schema: 3,
        kind: "zig-js-compiler-scratch-exact-parent-evidence",
        metadata: info,
        revisions: { parent: parentRevision, candidate: candidateRevision },
        runner_metadata: exact.runner_metadata,
        lanes: exact.lanes,
        rows: exact.rows,
      },
      report = renderExact(
        exact.rows,
        exact.lanes,
        info,
        rawPath,
        parentRevision as string,
        candidateRevision,
        exact.runner_metadata,
      );
    if (rawPath) writeText(rawPath, JSON.stringify(raw, null, 2) + "\n");
    if (markdownPath) writeText(markdownPath, report);
    if (!markdownPath) console.log(report);
    return;
  }
  const result = collect(runner as string, samples, warmups, logicalCpus),
    info = environment(runner as string, zig, samples, warmups, gcPath, regexPath),
    baseline = quick ? null : loadBaseline(baselinePath, result.runner_metadata, info),
    raw = {
      schema: 3,
      kind: "zig-js-compiler-pressure-evidence",
      metadata: info,
      runner_metadata: result.runner_metadata,
      baseline: baseline ? { path: baseline.path, sha256: baseline.sha256 } : null,
      lanes: result.lanes,
      rows: result.rows,
    },
    report = render(result.rows, result.lanes, info, rawPath, baseline);
  if (rawPath) writeText(rawPath, JSON.stringify(raw, null, 2) + "\n");
  if (markdownPath) writeText(markdownPath, report);
  if (!markdownPath) console.log(report);
}
if (process.argv[1] === __filename) main();
