/** Collect the opt-in tier sidecar for the versioned representative matrix. */
import {
  commandOutput,
  ensurePublishable,
  metadata,
} from "./benchmark-comparison";
import {
  DEFAULT_MANIFEST,
  loadManifest,
  validate as validateManifest,
} from "./representative-matrix";
import { run, writeText } from "./lib/home";

declare const __filename: string;

export type CounterMap = Record<string, number>;
export type TierSnapshot = {
  kind: "zig-js-tier-attribution";
  workload: string;
  jobs: number;
  phase: "configuration" | "warmup" | "invocation";
  checksum: number;
  execution: CounterMap;
  admissions: CounterMap;
  baseline_publications: number;
  optimizer_publications: number;
  generated_code_bytes: number;
};
export type TierDelta = {
  workload: string;
  jobs: number;
  phase: TierSnapshot["phase"];
  checksum: number;
  execution: CounterMap;
  admissions: CounterMap;
  baseline_publications: number;
  optimizer_publications: number;
  generated_code_bytes: number;
};

const phases: TierSnapshot["phase"][] = [
  "configuration",
  "warmup",
  "invocation",
];
const tierMetrics = [
  "tree_walker_entries",
  "vm_entries",
  "baseline_entries",
  "optimizer_entries",
  "optimizer_osr_entries",
  "deoptimizations",
];

function requireValue(condition: boolean, message: string): void {
  if (!condition) throw new Error(message);
}

function workloadEntries(manifest: any): any[] {
  const result: any[] = [];
  for (const family of manifest.implemented_families) {
    result.push([family, "base", family.base]);
    result.push([family, "variant", family.variant]);
  }
  return result;
}

const jobsFor = (family: any, quick: boolean): number =>
  family.jobs[quick ? "quick" : "full"];

export function parseSnapshots(output: string): TierSnapshot[] {
  return output
    .split("\n")
    .filter((line) => line.trim())
    .map((line) => {
      const row = JSON.parse(line);
      requireValue(
        row.kind === "zig-js-tier-attribution",
        `unexpected attribution row: ${line}`,
      );
      return row as TierSnapshot;
    });
}

export function collect(
  runner: string,
  manifest: any,
  quick: boolean,
): TierSnapshot[] {
  const rows: TierSnapshot[] = [];
  for (const entry of workloadEntries(manifest)) {
    const family = entry[0],
      workload = entry[2];
    const jobs = jobsFor(family, quick);
    const mode = family.availability && family.availability.attribution_mode
      ? family.availability.attribution_mode
      : "attribution";
    const command = [
      "env",
      "LC_ALL=C",
      runner,
      mode,
      workload,
      String(jobs),
      "1",
    ];
    console.error(`+ ${command.join(" ")}`);
    const completed = run(command);
    if (completed.stderr) process.stderr.write(completed.stderr);
    requireValue(
      completed.exitCode === 0,
      completed.stderr || `attribution runner exited ${completed.exitCode}`,
    );
    rows.push(...parseSnapshots(completed.stdout));
  }
  return rows;
}

function subtractMap(after: CounterMap, before: CounterMap): CounterMap {
  const result: CounterMap = {};
  const names = [...new Set(Object.keys(after).concat(Object.keys(before)))];
  for (const name of names) {
    const current = after[name] || 0,
      previous = before[name] || 0;
    requireValue(current >= previous, `${name} attribution counter regressed`);
    result[name] = current - previous;
  }
  return result;
}

function emptySnapshot(row: TierSnapshot): TierSnapshot {
  return {
    ...row,
    checksum: 0,
    execution: Object.fromEntries(
      Object.keys(row.execution).map((name) => [name, 0]),
    ),
    admissions: Object.fromEntries(
      Object.keys(row.admissions).map((name) => [name, 0]),
    ),
    baseline_publications: 0,
    optimizer_publications: 0,
    generated_code_bytes: 0,
  };
}

export function deltas(rows: TierSnapshot[]): TierDelta[] {
  const result: TierDelta[] = [];
  for (let index = 0; index < rows.length; index += phases.length) {
    const group = rows.slice(index, index + phases.length);
    requireValue(group.length === phases.length, "incomplete attribution phase group");
    let before = emptySnapshot(group[0]);
    for (const row of group) {
      requireValue(
        row.workload === group[0].workload && row.jobs === group[0].jobs,
        "attribution phase identity drift",
      );
      result.push({
        workload: row.workload,
        jobs: row.jobs,
        phase: row.phase,
        checksum: row.checksum,
        execution: subtractMap(row.execution, before.execution),
        admissions: subtractMap(row.admissions, before.admissions),
        baseline_publications:
          row.baseline_publications - before.baseline_publications,
        optimizer_publications:
          row.optimizer_publications - before.optimizer_publications,
        generated_code_bytes: row.generated_code_bytes,
      });
      requireValue(
        row.baseline_publications >= before.baseline_publications &&
          row.optimizer_publications >= before.optimizer_publications,
        "native publication counter regressed",
      );
      before = row;
    }
  }
  return result;
}

function signature(row: TierDelta): string {
  return tierMetrics
    .filter((name) => (row.execution[name] || 0) > 0)
    .join("+");
}

export function validate(
  rows: TierSnapshot[],
  manifest: any,
  quick: boolean,
): TierDelta[] {
  const entries = workloadEntries(manifest);
  requireValue(
    rows.length === entries.length * phases.length,
    `attribution row count ${rows.length} does not match ${entries.length * phases.length}`,
  );
  for (let index = 0; index < entries.length; index += 1) {
    const [family, role, workload] = entries[index],
      group = rows.slice(index * phases.length, (index + 1) * phases.length),
      jobs = jobsFor(family, quick);
    group.forEach((row, phaseIndex) => {
      requireValue(row.workload === workload, `unexpected workload ${row.workload}`);
      requireValue(row.jobs === jobs, `unexpected jobs for ${workload}`);
      requireValue(row.phase === phases[phaseIndex], `unexpected phase for ${workload}`);
      requireValue(
        Number.isInteger(row.checksum) &&
          Object.values(row.execution).every(Number.isInteger) &&
          Object.values(row.admissions).every(Number.isInteger),
        `non-integral attribution for ${workload}`,
      );
    });
    const lane = manifest.lanes.indexOf(1),
      scale = quick ? "quick" : "full";
    requireValue(
      group[2].checksum === family.checksums[role][scale][lane],
      `${workload} attribution checksum ${group[2].checksum} does not match frozen ${family.checksums[role][scale][lane]}`,
    );
  }
  const phaseDeltas = deltas(rows),
    byWorkload: Record<string, TierDelta[]> = {};
  phaseDeltas.forEach((row) => (byWorkload[row.workload] ||= []).push(row));
  for (const family of manifest.implemented_families) {
    for (const phase of ["warmup", "invocation"] as const) {
      const base = byWorkload[family.base].find((row) => row.phase === phase)!,
        variant = byWorkload[family.variant].find((row) => row.phase === phase)!;
      requireValue(signature(base).length > 0, `${family.base} selected no execution tier`);
      requireValue(
        signature(base) === signature(variant),
        `${family.family} ${phase} tier attribution differs: base=${signature(base)} variant=${signature(variant)}`,
      );
      const baseEnvironments = base.execution.environment_allocations || 0,
        variantEnvironments = variant.execution.environment_allocations || 0;
      requireValue(
        baseEnvironments === variantEnvironments,
        `${family.family} ${phase} environment allocations differ: base=${baseEnvironments} variant=${variantEnvironments}`,
      );
    }
  }
  return phaseDeltas;
}

export function render(
  deltas_: TierDelta[],
  manifest: any,
  heading = "#",
  rawPath: string | null = null,
): string {
  const rows: string[] = [
    `${heading} Representative tier attribution — ${manifest.matrix_id}`,
    "",
    "| family | phase | base tiers | variant tiers | base env allocations | variant env allocations |",
    "| --- | --- | --- | --- | ---: | ---: |",
  ];
  const byWorkload: Record<string, TierDelta[]> = {};
  deltas_.forEach((row) => (byWorkload[row.workload] ||= []).push(row));
  for (const family of manifest.implemented_families) {
    for (const phase of ["warmup", "invocation"] as const) {
      const base = byWorkload[family.base].find((row) => row.phase === phase)!,
        variant = byWorkload[family.variant].find((row) => row.phase === phase)!;
      rows.push(
        `| \`${family.family}\` | ${phase} | \`${signature(base)}\` | \`${signature(variant)}\` | ${base.execution.environment_allocations || 0} | ${variant.execution.environment_allocations || 0} |`,
      );
    }
  }
  if (rawPath) {
    const name = rawPath.split("/").pop();
    rows.push("", `Raw attribution: [\`${name}\`](${name})`);
  }
  return rows.join("\n") + "\n";
}

export function artifact(
  snapshots: TierSnapshot[],
  manifest: any,
  quick: boolean,
  info: Record<string, string>,
  runner: string,
): any {
  return {
    schema_version: 1,
    matrix_id: manifest.matrix_id,
    quick,
    environment: info,
    runner_sha256: commandOutput(["shasum", "-a", "256", runner]).split(/\s+/)[0],
    snapshots,
  };
}

function syntheticRows(manifest: any): TierSnapshot[] {
  const rows: TierSnapshot[] = [];
  for (const [family, role, workload] of workloadEntries(manifest)) {
    const jobs = jobsFor(family, true),
      checksum = family.checksums[role].quick[manifest.lanes.indexOf(1)];
    phases.forEach((phase, index) =>
      rows.push({
        kind: "zig-js-tier-attribution",
        workload,
        jobs,
        phase,
        checksum: phase === "invocation" ? checksum : 0,
        execution: {
          tree_walker_entries: 0,
          vm_entries: index + 1,
          baseline_entries: 0,
          optimizer_entries: index,
          optimizer_osr_entries: 0,
          deoptimizations: 0,
          environment_allocations: index,
        },
        admissions: { program_compiled: index + 1 },
        baseline_publications: 0,
        optimizer_publications: index > 0 ? 1 : 0,
        generated_code_bytes: index > 0 ? 4096 : 0,
      }),
    );
  }
  return rows;
}

function expectFailure(action: () => void, pattern: string): void {
  try {
    action();
  } catch (error) {
    requireValue(String(error).includes(pattern), `expected ${pattern}, got ${String(error)}`);
    return;
  }
  throw new Error(`expected failure containing ${pattern}`);
}

export function selfTest(): void {
  const manifest = loadManifest(DEFAULT_MANIFEST),
    rows = syntheticRows(manifest);
  validate(rows, manifest, true);
  const mismatch = JSON.parse(JSON.stringify(rows));
  mismatch[4].execution.tree_walker_entries = 1;
  mismatch[5].execution.tree_walker_entries = 1;
  expectFailure(() => validate(mismatch, manifest, true), "tier attribution differs");
  const environmentMismatch = JSON.parse(JSON.stringify(rows));
  environmentMismatch[5].execution.environment_allocations += 1;
  expectFailure(
    () => validate(environmentMismatch, manifest, true),
    "environment allocations differ",
  );
  const checksum = JSON.parse(JSON.stringify(rows));
  checksum[2].checksum += 1;
  expectFailure(() => validate(checksum, manifest, true), "does not match frozen");
  console.log("OK representative tier attribution self-test: phases, checksums, tier equivalence, and environment parity verified");
}

function main(): void {
  const args = process.argv.slice(2);
  if (args.length === 1 && args[0] === "--self-test") {
    selfTest();
    return;
  }
  let runner = "",
    manifestPath = DEFAULT_MANIFEST,
    output = "",
    markdown = "",
    quick = false;
  for (let index = 0; index < args.length; index += 1) {
    const name = args[index];
    if (name === "--quick") quick = true;
    else {
      const value = args[++index];
      if (name === "--runner") runner = value;
      else if (name === "--manifest") manifestPath = value;
      else if (name === "--out") output = value;
      else if (name === "--markdown-out") markdown = value;
      else throw new Error(`unknown argument: ${name}`);
    }
  }
  requireValue(Boolean(runner) && Home.fileExists(runner), "attribution runner does not exist");
  const manifest = loadManifest(manifestPath);
  validateManifest(manifest);
  const info = metadata();
  ensurePublishable(info, Boolean(output || markdown));
  const snapshots = collect(runner, manifest, quick),
    phaseDeltas = validate(snapshots, manifest, quick),
    report = render(phaseDeltas, manifest, "#", output || null),
    rawArtifact = artifact(snapshots, manifest, quick, info, runner);
  if (output) writeText(output, JSON.stringify(rawArtifact, null, 2) + "\n");
  if (markdown) writeText(markdown, report);
  process.stdout.write(report);
}

if (process.argv[1] === __filename) main();
