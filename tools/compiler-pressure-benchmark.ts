/** Collect and publish the independent-Context synchronous compiler-pressure matrix. */
import { cpuCount, run, sha256File, writeText } from "./lib/home";

declare const __dirname: string;
declare const __filename: string;

const ROOT =
  __dirname === "tools"
    ? "."
    : __dirname.slice(0, __dirname.lastIndexOf("/tools"));
const MODES = ["jit_off", "jit_on"];
const PHASES = ["cold", "warm"];
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

type RecordValue = Record<string, any>;
type Row = RecordValue & { iteration: number };

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
  requireValue(records.length === 3, `expected metadata plus two phase rows, got ${records.length}`);
  const metadata = records[0],
    rows = records.slice(1);
  requireValue(
    metadata.kind === "zig-js-compiler-pressure-metadata" &&
      metadata.schema === 1 &&
      metadata.source_path === "bench/compiler_pressure.js" &&
      /^[0-9a-f]{64}$/.test(metadata.source_sha256) &&
      metadata.cold_invocations === 10 &&
      metadata.warm_invocations === 3,
    `invalid runner metadata: ${JSON.stringify(metadata)}`,
  );
  integer(metadata.logical_cpus, "metadata.logical_cpus");
  requireValue(metadata.logical_cpus > 0, "logical CPU count must be positive");
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
  requireValue(rows.length === 2, `expected two phase rows, got ${rows.length}`);
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
    requireValue(row.elapsed_ns > 0 && row.checksum > 0, `invalid timing/checksum: ${JSON.stringify(row)}`);
    for (const field of [
      "cpu_user_ns",
      "cpu_system_ns",
      "peak_rss_bytes_before",
      "peak_rss_bytes_after",
      "retained_rss_bytes_before",
      "retained_rss_bytes_after",
    ]) integer(row.process[field], `${mode}/${lanes}/${row.phase}.process.${field}`);
    requireValue(
      row.process.cpu_user_ns + row.process.cpu_system_ns > 0,
      `zero process CPU: ${JSON.stringify(row)}`,
    );
    for (const field of COMPILER_FIELDS)
      integer(row.compiler[field], `${mode}/${lanes}/${row.phase}.compiler.${field}`);
  });
  requireValue(rows[0].checksum === rows[1].checksum, `${mode}/${lanes}: phase checksum mismatch`);

  const cold = rows[0].compiler,
    warm = rows[1].compiler;
  if (mode === "jit_off") {
    requireValue(
      COMPILER_FIELDS.every((field) => cold[field] === 0 && warm[field] === 0),
      `JIT-off published or attempted native code: ${JSON.stringify(rows)}`,
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
  }
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
  return [1, 2, 4, logicalCpus]
    .filter((value) => value <= logicalCpus)
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
  validateMatrix(rows, samples, lanes, runnerMetadata as RecordValue);
  return { runner_metadata: runnerMetadata as RecordValue, rows, lanes };
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
    for (const mode of MODES)
      for (const phase of PHASES) {
        const key = [mode, phase, laneCount].join("\t"),
          selected = groups[key] || [];
        requireValue(
          JSON.stringify(selected.map((row) => row.iteration).sort((a, b) => a - b)) ===
            JSON.stringify(expectedIterations),
          `missing or duplicate iterations for ${key}`,
        );
        selected.forEach((row) => validateInvocation(metadata, [
          phase === "cold" ? row : groups[[mode, "cold", laneCount].join("\t")][row.iteration],
          phase === "warm" ? row : groups[[mode, "warm", laneCount].join("\t")][row.iteration],
        ], mode, laneCount, 1));
        requireValue(
          selected.every((row) => row.checksum === selected[0].checksum),
          `checksum changed within ${key}`,
        );
        checksums[`${mode}\t${phase}`] = selected[0].checksum;
      }
    requireValue(
      checksums["jit_off\tcold"] === checksums["jit_on\tcold"] &&
        checksums["jit_off\twarm"] === checksums["jit_on\twarm"],
      `JIT-on/off checksum mismatch at ${laneCount} lanes`,
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

function assertClean(): void {
  assertCleanPath(ROOT, "zig-js");
  assertCleanPath(`${ROOT}/../zig-gc`, "zig-gc");
  assertCleanPath(`${ROOT}/../zig-regex`, "zig-regex");
}

function environment(runner: string, zig: string, samples: number, warmups: number): Record<string, string> {
  const memory = output(["sysctl", "-n", "hw.memsize"]),
    memoryGiB = /^\d+$/.test(memory)
      ? `${(Number(memory) / 1024 ** 3).toFixed(1)} GiB`
      : memory;
  return {
    Date: output(["date", "+%Y-%m-%dT%H:%M:%S%z"]),
    Host: `${output(["sysctl", "-n", "machdep.cpu.brand_string"])}; ${output(["sysctl", "-n", "hw.physicalcpu"])} physical / ${output(["sysctl", "-n", "hw.logicalcpu"])} logical CPUs; ${memoryGiB}`,
    OS: `macOS ${output(["sw_vers", "-productVersion"])} (${output(["sw_vers", "-buildVersion"])})`,
    Zig: output([zig, "version"]),
    "zig-js": revision(ROOT),
    "zig-gc": revision(`${ROOT}/../zig-gc`),
    "zig-regex": revision(`${ROOT}/../zig-regex`),
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
): string {
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
    "| lanes | mode | wall p50 | process CPU p50 | summed compiler p50 | CPU / wall | wall scaling | wall RSD | baseline publications | generated code | peak RSS p50 |",
    "| ---: | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |",
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
        peak = median(group.map((row) => row.process.peak_rss_bytes_after));
      lines.push(
        `| ${laneCount} | ${mode} | ${(elapsed / 1e6).toFixed(2)} ms | ${(cpu / 1e6).toFixed(2)} ms | ${(compile / 1e6).toFixed(2)} ms | ${(cpu / elapsed).toFixed(2)}x | ${(oneLane[mode] / elapsed).toFixed(2)}x | ${rsd(group.map((row) => row.elapsed_ns)).toFixed(2)}% | ${publications.toFixed(0)} | ${(generated / 1024 / 1024).toFixed(2)} MiB | ${(peak / 1024 / 1024).toFixed(2)} MiB |`,
      );
    }
  lines.push(
    "",
    "Wall scaling is one-lane wall divided by current wall. Process CPU divided by wall shows aggregate concurrency; summed compiler time adds independently timed tier attempts across lanes and can exceed wall time.",
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
    `The fixed source is \`bench/compiler_pressure.js\` at SHA-256 \`${sourceSha}\`. Each lane owns a fresh creator-thread-affine Context. Cold timing starts before OS-thread creation and includes Context construction, source parsing/bytecode setup, ten fixture invocations, native compilation/publication, and the completion join.`,
    "Warm timing reuses the live Contexts for three invocations. Context destruction is outside both timed phases. Process CPU comes from `getrusage`; peak and retained RSS use Darwin `task_vm_info`.",
    "The current engine compiles synchronously on the calling lane. This baseline therefore measures the uncoordinated behavior that runtime admission changes must improve without changing checksums, publication counts, or warm behavior.",
    "",
    "## Reproduce",
    "",
    "```bash",
    `zig build compiler-pressure-benchmark -Dcompiler-pressure-raw-out=${rawPath || "docs/.data/compiler-pressure-YYYY-MM-DD.json"} -Dcompiler-pressure-markdown-out=docs/.data/compiler-pressure-YYYY-MM-DD.md`,
    "```",
    "",
  );
  return lines.join("\n");
}

function fixtureRow(mode: string, phase: string, lanes: number, iteration: number): Row {
  const enabled = mode === "jit_on" && phase === "cold";
  return {
    kind: "zig-js-compiler-pressure",
    schema: 1,
    mode,
    phase,
    source_sha256: "a".repeat(64),
    lanes,
    jobs_per_lane: 1,
    sample: 0,
    iteration,
    elapsed_ns: (phase === "cold" ? 20_000_000 : 1_000_000) * lanes,
    checksum: 1000 + lanes,
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
  };
}

function selfTest(): void {
  const metadata = {
      kind: "zig-js-compiler-pressure-metadata",
      schema: 1,
      source_path: "bench/compiler_pressure.js",
      source_sha256: "a".repeat(64),
      logical_cpus: 8,
      jit_supported: true,
      cold_invocations: 10,
      warm_invocations: 3,
    },
    lanes = [1, 2, 4, 8],
    rows: Row[] = [];
  for (const laneCount of lanes)
    for (const mode of MODES)
      for (let iteration = 0; iteration < 3; iteration += 1)
        for (const phase of PHASES)
          rows.push(fixtureRow(mode, phase, laneCount, iteration));
  validateMatrix(rows, 3, lanes, metadata);
  const report = render(rows, lanes, { Date: "2026-09-22", Samples: "3", Warmups: "1" }, "raw.json");
  requireValue(report.includes("| 8 | jit_on |") && report.includes("48 phase rows"), "report fixture was not rendered");

  const invocation = [
    JSON.stringify(metadata),
    JSON.stringify(fixtureRow("jit_on", "cold", 1, 0)),
    JSON.stringify(fixtureRow("jit_on", "warm", 1, 0)),
  ].join("\n");
  const parsed = parseInvocation(invocation);
  validateInvocation(parsed.metadata, parsed.rows, "jit_on", 1, 1);

  let rejected = false;
  try {
    const invalid = fixtureRow("jit_off", "cold", 1, 0);
    invalid.compiler.generated_code_bytes = 1;
    validateInvocation(metadata, [invalid, fixtureRow("jit_off", "warm", 1, 0)], "jit_off", 1, 1);
  } catch (_) {
    rejected = true;
  }
  requireValue(rejected, "JIT-off native publication was accepted");
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
    zig = argument(args, "--zig") || "zig",
    rawPath = argument(args, "--raw-out"),
    markdownPath = argument(args, "--markdown-out"),
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
    assertClean();
  } else requireValue(!rawPath && !markdownPath, "quick runs cannot publish evidence files");
  const logicalCpus = cpuCount(),
    result = collect(runner as string, samples, warmups, logicalCpus),
    info = environment(runner as string, zig, samples, warmups),
    raw = {
      schema: 1,
      kind: "zig-js-compiler-pressure-evidence",
      metadata: info,
      runner_metadata: result.runner_metadata,
      lanes: result.lanes,
      rows: result.rows,
    },
    report = render(result.rows, result.lanes, info, rawPath);
  if (rawPath) writeText(rawPath, JSON.stringify(raw, null, 2) + "\n");
  if (markdownPath) writeText(markdownPath, report);
  if (!markdownPath) console.log(report);
}
if (process.argv[1] === __filename) main();
