/** Collect the frozen JSON pipeline rows against the system JavaScriptCore. */
import {
  fileExists,
  run,
  sha256File,
  writeText,
} from "./lib/home";
import {
  ROOT,
  commandOutput,
  parseRow,
  repositoryRevision,
} from "./benchmark-comparison";
import { competingEvidenceProcesses } from "./evidence-processes";
// Inventory-visible module edge: tools/evidence-processes.ts.

declare const __filename: string;

type Workload = {
  name: string;
  jobs: number;
  checksum: number;
  role: string;
};

type Sample = {
  pair_sample: number;
  order: number;
  engine: string;
  mode: string;
  workload: string;
  lanes: number;
  jobs: number;
  elapsed_ns: number;
  checksum: number;
};

type GapVariant = "baseline" | "candidate" | "JavaScriptCore";
type GapSample = Sample & { variant: GapVariant };

export const WORKLOADS: Workload[] = [
  {
    name: "representative_json",
    jobs: 2200,
    checksum: 324952086,
    role: "frozen parse/stringify row",
  },
  {
    name: "representative_json_variant",
    jobs: 2200,
    checksum: 324952086,
    role: "anti-specialization variant",
  },
  {
    name: "representative_json_reviver_source",
    jobs: 128,
    checksum: 4299681984,
    role: "reviver/source control",
  },
  {
    name: "representative_json_escaped_strings",
    jobs: 500,
    checksum: 121471500,
    role: "escaped-string control",
  },
  {
    name: "representative_json_stringify_depth_4096",
    jobs: 1200,
    checksum: 83848800,
    role: "deep-stringify control",
  },
  {
    name: "representative_json_stringify_shallow_4096",
    jobs: 1400,
    checksum: 63340200,
    role: "shallow-stringify control",
  },
];

const MINIMUM_MEDIAN_NS = 50_000_000;

function requireValue(condition: boolean, message: string): void {
  if (!condition) throw new Error(message);
}

function median(values: number[]): number {
  const sorted = values.slice().sort((a, b) => a - b);
  return sorted[Math.floor(sorted.length / 2)];
}

function relativeStddev(values: number[]): number {
  if (values.length <= 1) return 0;
  const mean = values.reduce((sum, value) => sum + value, 0) / values.length;
  return Math.sqrt(
    values.reduce((sum, value) => sum + (value - mean) ** 2, 0) /
      (values.length - 1),
  ) / mean;
}

export function requireNoCompetingEvidenceProcess(
  phase: string,
  listing = commandOutput(["ps", "-axo", "pid=,ppid=,command="], ""),
  selfPid = process.pid,
): void {
  const competitors = competingEvidenceProcesses(listing, selfPid);
  requireValue(
    competitors.length === 0,
    `competing build/test process detected ${phase}:\n${competitors.join("\n")}`,
  );
}

function runSample(
  binary: string,
  workload: Workload,
  pairSample: number,
  order: number,
  mode = "single",
): Sample {
  requireNoCompetingEvidenceProcess("before benchmark invocation");
  const argv = [
    "env",
    "LC_ALL=C",
    binary,
    mode,
    workload.name,
    String(workload.jobs),
    "1",
  ];
  console.error(`+ ${argv.join(" ")}`);
  const completed = run(argv);
  requireNoCompetingEvidenceProcess("after benchmark invocation");
  if (completed.stderr) process.stderr.write(completed.stderr);
  requireValue(
    completed.exitCode === 0,
    completed.stderr || `benchmark exited ${completed.exitCode}`,
  );
  const lines = completed.stdout.split("\n").filter((line) => line.trim());
  requireValue(lines.length === 1, `expected one benchmark row, got ${lines.length}`);
  const row = parseRow(lines[0]);
  requireValue(row.mode === mode, `${workload.name}: mode drift`);
  requireValue(row.workload === workload.name, `${workload.name}: workload drift`);
  requireValue(row.lanes === 1, `${workload.name}: lane drift`);
  requireValue(row.jobs === workload.jobs, `${workload.name}: job-count drift`);
  requireValue(
    row.checksum === workload.checksum,
    `${workload.name}: expected checksum ${workload.checksum}, got ${row.checksum}`,
  );
  return {
    pair_sample: pairSample,
    order,
    engine: row.engine,
    mode: row.mode,
    workload: row.workload,
    lanes: row.lanes,
    jobs: row.jobs,
    elapsed_ns: row.elapsed_ns,
    checksum: row.checksum,
  };
}

export function collect(
  zigJs: string,
  jsc: string,
  samples: number,
): Sample[] {
  const rows: Sample[] = [];
  WORKLOADS.forEach((workload, workloadIndex) => {
    for (let pair = 0; pair < samples; pair += 1) {
      const binaries = (workloadIndex + pair) % 2 === 0
        ? [zigJs, jsc]
        : [jsc, zigJs];
      binaries.forEach((binary, order) =>
        rows.push(runSample(binary, workload, pair, order))
      );
    }
  });
  return rows;
}

const GAP_ORDERS: GapVariant[][] = [
  ["baseline", "candidate", "JavaScriptCore"],
  ["baseline", "JavaScriptCore", "candidate"],
  ["candidate", "baseline", "JavaScriptCore"],
  ["candidate", "JavaScriptCore", "baseline"],
  ["JavaScriptCore", "baseline", "candidate"],
  ["JavaScriptCore", "candidate", "baseline"],
];

export function collectGapReduction(
  candidate: string,
  baseline: string,
  jsc: string,
  samples: number,
): GapSample[] {
  const binaries: Record<GapVariant, string> = {
    baseline,
    candidate,
    JavaScriptCore: jsc,
  };
  const rows: GapSample[] = [];
  WORKLOADS.forEach((workload, workloadIndex) => {
    for (let pair = 0; pair < samples; pair += 1) {
      const order = GAP_ORDERS[(workloadIndex * samples + pair) % GAP_ORDERS.length];
      order.forEach((variant, orderIndex) => {
        const row = runSample(binaries[variant], workload, pair, orderIndex);
        const expectedEngine = variant === "JavaScriptCore" ? "JavaScriptCore" : "zig-js";
        requireValue(row.engine === expectedEngine, `${workload.name}/${variant}: engine identity drift`);
        rows.push({ ...row, variant });
      });
    }
  });
  return rows;
}

export function collectTierResidency(
  zigJs: string,
  samples: number,
): Sample[] {
  const rows: Sample[] = [];
  WORKLOADS.slice(0, 2).forEach((workload, workloadIndex) => {
    for (let pair = 0; pair < samples; pair += 1) {
      const modes = (workloadIndex + pair) % 2 === 0
        ? ["single", "single_no_jit"]
        : ["single_no_jit", "single"];
      modes.forEach((mode, order) =>
        rows.push(runSample(zigJs, workload, pair, order, mode))
      );
    }
  });
  return rows;
}

export function validate(rows: Sample[], samples: number): void {
  requireValue(samples > 0, "sample count must be positive");
  requireValue(
    rows.length === WORKLOADS.length * samples * 2,
    `expected ${WORKLOADS.length * samples * 2} rows, got ${rows.length}`,
  );
  for (const workload of WORKLOADS) {
    const group = rows.filter((row) => row.workload === workload.name);
    for (const engine of ["zig-js", "JavaScriptCore"]) {
      const engineRows = group.filter((row) => row.engine === engine);
      requireValue(
        engineRows.length === samples,
        `${workload.name}/${engine}: expected ${samples} rows`,
      );
      requireValue(
        JSON.stringify(engineRows.map((row) => row.pair_sample).sort((a, b) => a - b)) ===
          JSON.stringify(Array.from({ length: samples }, (_, index) => index)),
        `${workload.name}/${engine}: sample-index drift`,
      );
      requireValue(
        median(engineRows.map((row) => row.elapsed_ns)) >= MINIMUM_MEDIAN_NS,
        `${workload.name}/${engine}: median is below the 50 ms timing floor`,
      );
    }
    requireValue(
      group.every((row) => row.checksum === workload.checksum),
      `${workload.name}: cross-engine checksum drift`,
    );
    for (let pair = 0; pair < samples; pair += 1) {
      const pairRows = group.filter((row) => row.pair_sample === pair);
      requireValue(
        pairRows.length === 2 && pairRows[0].order === 0 && pairRows[1].order === 1,
        `${workload.name}: pair ${pair} order drift`,
      );
      requireValue(
        pairRows[0].engine !== pairRows[1].engine,
        `${workload.name}: pair ${pair} did not compare both engines`,
      );
    }
  }
}

export function validateGapReduction(rows: GapSample[], samples: number): void {
  requireValue(samples > 0, "sample count must be positive");
  requireValue(
    rows.length === WORKLOADS.length * samples * 3,
    `expected ${WORKLOADS.length * samples * 3} gap rows, got ${rows.length}`,
  );
  for (const workload of WORKLOADS) {
    const group = rows.filter((row) => row.workload === workload.name);
    for (const variant of ["baseline", "candidate", "JavaScriptCore"] as GapVariant[]) {
      const variantRows = group.filter((row) => row.variant === variant);
      requireValue(
        variantRows.length === samples,
        `${workload.name}/${variant}: expected ${samples} rows`,
      );
      requireValue(
        JSON.stringify(variantRows.map((row) => row.pair_sample).sort((a, b) => a - b)) ===
          JSON.stringify(Array.from({ length: samples }, (_, index) => index)),
        `${workload.name}/${variant}: sample-index drift`,
      );
      requireValue(
        median(variantRows.map((row) => row.elapsed_ns)) >= MINIMUM_MEDIAN_NS,
        `${workload.name}/${variant}: median is below the 50 ms timing floor`,
      );
      const expectedEngine = variant === "JavaScriptCore" ? "JavaScriptCore" : "zig-js";
      requireValue(
        variantRows.every((row) => row.engine === expectedEngine),
        `${workload.name}/${variant}: engine identity drift`,
      );
    }
    requireValue(
      group.every((row) => row.checksum === workload.checksum),
      `${workload.name}: gap-reduction checksum drift`,
    );
    for (let triplet = 0; triplet < samples; triplet += 1) {
      const tripletRows = group.filter((row) => row.pair_sample === triplet);
      requireValue(
        tripletRows.length === 3 && tripletRows.every((row, index) => row.order === index),
        `${workload.name}: triplet ${triplet} order drift`,
      );
      requireValue(
        new Set(tripletRows.map((row) => row.variant)).size === 3,
        `${workload.name}: triplet ${triplet} did not compare all variants`,
      );
    }
  }
}

export function validateTierResidency(rows: Sample[], samples: number): void {
  const workloads = WORKLOADS.slice(0, 2);
  requireValue(
    rows.length === workloads.length * samples * 2,
    `expected ${workloads.length * samples * 2} tier rows, got ${rows.length}`,
  );
  for (const workload of workloads) {
    const group = rows.filter((row) => row.workload === workload.name);
    for (const mode of ["single", "single_no_jit"]) {
      const modeRows = group.filter((row) => row.mode === mode);
      requireValue(
        modeRows.length === samples,
        `${workload.name}/${mode}: expected ${samples} rows`,
      );
      requireValue(
        JSON.stringify(modeRows.map((row) => row.pair_sample).sort((a, b) => a - b)) ===
          JSON.stringify(Array.from({ length: samples }, (_, index) => index)),
        `${workload.name}/${mode}: sample-index drift`,
      );
      requireValue(
        median(modeRows.map((row) => row.elapsed_ns)) >= MINIMUM_MEDIAN_NS,
        `${workload.name}/${mode}: median is below the 50 ms timing floor`,
      );
    }
    requireValue(
      group.every((row) => row.checksum === workload.checksum),
      `${workload.name}: tier checksum drift`,
    );
    for (let pair = 0; pair < samples; pair += 1) {
      const pairRows = group.filter((row) => row.pair_sample === pair);
      requireValue(
        pairRows.length === 2 && pairRows[0].order === 0 && pairRows[1].order === 1,
        `${workload.name}: tier pair ${pair} order drift`,
      );
      requireValue(
        pairRows[0].mode !== pairRows[1].mode,
        `${workload.name}: tier pair ${pair} did not compare both modes`,
      );
    }
  }
}

function summarize(rows: Sample[]): any[] {
  return WORKLOADS.map((workload) => {
    const zig = rows.filter(
        (row) => row.workload === workload.name && row.engine === "zig-js",
      ).map((row) => row.elapsed_ns),
      jsc = rows.filter(
        (row) => row.workload === workload.name && row.engine === "JavaScriptCore",
      ).map((row) => row.elapsed_ns),
      zigMedian = median(zig),
      jscMedian = median(jsc);
    return {
      workload: workload.name,
      role: workload.role,
      jobs: workload.jobs,
      checksum: workload.checksum,
      zig_js_median_ns: zigMedian,
      zig_js_rsd: relativeStddev(zig),
      jsc_median_ns: jscMedian,
      jsc_rsd: relativeStddev(jsc),
      jsc_throughput_over_zig_js: zigMedian / jscMedian,
    };
  });
}

function summarizeGapReduction(rows: GapSample[]): any[] {
  return WORKLOADS.map((workload) => {
    const values = (variant: GapVariant) => rows.filter(
      (row) => row.workload === workload.name && row.variant === variant,
    ).map((row) => row.elapsed_ns);
    const baseline = values("baseline"), candidate = values("candidate"), jsc = values("JavaScriptCore"),
      baselineMedian = median(baseline), candidateMedian = median(candidate), jscMedian = median(jsc),
      candidateOverBaseline = candidateMedian / baselineMedian;
    return {
      workload: workload.name,
      role: workload.role,
      jobs: workload.jobs,
      checksum: workload.checksum,
      baseline_median_ns: baselineMedian,
      baseline_rsd: relativeStddev(baseline),
      candidate_median_ns: candidateMedian,
      candidate_rsd: relativeStddev(candidate),
      candidate_over_baseline: candidateOverBaseline,
      jsc_median_ns: jscMedian,
      jsc_rsd: relativeStddev(jsc),
      baseline_jsc_gap: baselineMedian / jscMedian,
      candidate_jsc_gap: candidateMedian / jscMedian,
      gap_reduction: 1 - candidateOverBaseline,
    };
  });
}

function summarizeTierResidency(rows: Sample[]): any[] {
  return WORKLOADS.slice(0, 2).map((workload) => {
    const jit = rows.filter(
        (row) => row.workload === workload.name && row.mode === "single",
      ).map((row) => row.elapsed_ns),
      vm = rows.filter(
        (row) => row.workload === workload.name && row.mode === "single_no_jit",
      ).map((row) => row.elapsed_ns),
      jitMedian = median(jit),
      vmMedian = median(vm);
    return {
      workload: workload.name,
      jobs: workload.jobs,
      checksum: workload.checksum,
      jit_median_ns: jitMedian,
      jit_rsd: relativeStddev(jit),
      required_vm_median_ns: vmMedian,
      required_vm_rsd: relativeStddev(vm),
      jit_over_required_vm: jitMedian / vmMedian,
    };
  });
}

function render(artifact: any, rawPath: string): string {
  const lines = [
    `# Frozen JSON pipeline versus JavaScriptCore — ${artifact.metadata.date}`,
    "",
    "> Focused diagnostic for issue #473, not a universal engine score.",
    "> Controls are scaled only to clear the same 50 ms timing floor as the touched rows.",
    "",
    "## Provenance",
    "",
    "| item | value |",
    "| --- | --- |",
  ];
  Object.keys(artifact.metadata).forEach((key) =>
    lines.push(`| ${key} | ${String(artifact.metadata[key]).replace(/\|/g, "\\|")} |`)
  );
  lines.push(
    "",
    "## Result",
    "",
    "Lower time is better. `JSC / zig-js` is JSC throughput divided by zig-js throughput.",
    "Every row uses one warmed, GC-enabled context per fresh process and preserves the exact checksum.",
    "",
    "| workload | role | jobs | zig-js median | zig-js RSD | JSC median | JSC RSD | JSC / zig-js | checksum |",
    "| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |",
  );
  artifact.summary.forEach((row: any) => lines.push(
    `| \`${row.workload}\` | ${row.role} | ${row.jobs} | ${(row.zig_js_median_ns / 1e6).toFixed(3)} ms | ${(row.zig_js_rsd * 100).toFixed(2)}% | ${(row.jsc_median_ns / 1e6).toFixed(3)} ms | ${(row.jsc_rsd * 100).toFixed(2)}% | ${row.jsc_throughput_over_zig_js.toFixed(2)}x | ${row.checksum} |`,
  ));
  lines.push(
    "",
    "## Method",
    "",
    `- ${artifact.metadata.samples} fresh-process, order-balanced pairs per row; no sample was discarded.`,
    "- Both runners evaluate the same frozen `bench/representative_comparison.js` bytes and time the same invocation after their built-in reduced-size warmup.",
    "- The zig-js runner is ReleaseFast with the real precise collector checkout recorded above. The JSC runner links the system JavaScriptCore framework.",
    "- The collector rejects identity, job-count, checksum, sample-index, pair-order, and 50 ms median-floor drift before writing either artifact.",
    "- Every invocation is bracketed by fail-closed competing-process snapshots; host scheduling and frequency are otherwise not controlled, so RSD is retained and the matrix remains diagnostic.",
    "",
    `Raw evidence: [${rawPath.split("/").pop()}](${rawPath.split("/").pop()})`,
    "",
  );
  return lines.join("\n");
}

function renderGapReduction(artifact: any, rawPath: string): string {
  const lines = [
    `# Frozen JSON JSC gap reduction — ${artifact.metadata.date}`,
    "",
    "> Same-window baseline/candidate/JSC diagnostic for issues #1019 and #473, not a universal engine score.",
    "> Lower time is better; gap reduction is computed only from the order-balanced triplets below.",
    "",
    "## Provenance",
    "",
    "| item | value |",
    "| --- | --- |",
  ];
  Object.keys(artifact.metadata).forEach((key) =>
    lines.push(`| ${key} | ${String(artifact.metadata[key]).replace(/\|/g, "\\|")} |`)
  );
  lines.push(
    "",
    "## Result",
    "",
    "| workload | role | jobs | baseline median | baseline RSD | candidate median | candidate RSD | candidate / baseline | JSC median | JSC RSD | baseline gap | candidate gap | gap reduction | checksum |",
    "| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |",
  );
  artifact.summary.forEach((row: any) => lines.push(
    `| \`${row.workload}\` | ${row.role} | ${row.jobs} | ${(row.baseline_median_ns / 1e6).toFixed(3)} ms | ${(row.baseline_rsd * 100).toFixed(2)}% | ${(row.candidate_median_ns / 1e6).toFixed(3)} ms | ${(row.candidate_rsd * 100).toFixed(2)}% | ${row.candidate_over_baseline.toFixed(3)}x | ${(row.jsc_median_ns / 1e6).toFixed(3)} ms | ${(row.jsc_rsd * 100).toFixed(2)}% | ${row.baseline_jsc_gap.toFixed(2)}x | ${row.candidate_jsc_gap.toFixed(2)}x | ${(row.gap_reduction * 100).toFixed(1)}% | ${row.checksum} |`,
  ));
  lines.push(
    "",
    "## Method",
    "",
    `- ${artifact.metadata.samples} fresh-process, order-balanced triplets per row; no sample was discarded.`,
    "- Baseline, candidate, and JSC evaluate the same frozen workload bytes with identical jobs, warmup, timed boundary, and checksum.",
    "- The six possible runner orders rotate across workloads and samples, so each appears equally often over the complete matrix.",
    "- Both zig-js runners are ReleaseFast with the same real precise collector and zig-regex revisions. JSC links the system framework.",
    "- The collector rejects variant/engine identity, checksum, sample-index, triplet-order, and 50 ms median-floor drift before writing either artifact.",
    "- Every invocation is bracketed by fail-closed competing-process snapshots; host scheduling and frequency are otherwise not controlled, so every RSD remains visible and the result remains diagnostic.",
    "",
    `Raw evidence: [${rawPath.split("/").pop()}](${rawPath.split("/").pop()})`,
    "",
  );
  return lines.join("\n");
}

function renderTierResidency(artifact: any, rawPath: string): string {
  const lines = [
    `# Frozen JSON JIT residency — ${artifact.metadata.date}`,
    "",
    "> Focused JIT-versus-required-VM diagnostic for issue #1017.",
    "> Lower time is better; a JIT/VM ratio at or below 1.0 clears the residency throughput gate.",
    "",
    "## Provenance",
    "",
    "| item | value |",
    "| --- | --- |",
  ];
  Object.keys(artifact.metadata).forEach((key) =>
    lines.push(`| ${key} | ${String(artifact.metadata[key]).replace(/\|/g, "\\|")} |`)
  );
  lines.push(
    "",
    "## Result",
    "",
    "| workload | jobs | JIT median | JIT RSD | required VM median | VM RSD | JIT / VM | checksum |",
    "| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |",
  );
  artifact.summary.forEach((row: any) => lines.push(
    `| \`${row.workload}\` | ${row.jobs} | ${(row.jit_median_ns / 1e6).toFixed(3)} ms | ${(row.jit_rsd * 100).toFixed(2)}% | ${(row.required_vm_median_ns / 1e6).toFixed(3)} ms | ${(row.required_vm_rsd * 100).toFixed(2)}% | ${row.jit_over_required_vm.toFixed(3)}x | ${row.checksum} |`,
  ));
  lines.push(
    "",
    "## Method",
    "",
    `- ${artifact.metadata.samples} fresh-process, order-balanced pairs per row; no sample was discarded.`,
    "- Both modes use the same ReleaseFast binary, real precise collector, workload bytes, warmup, jobs, and timed invocation.",
    "- `single` enables the shipping native tiers. `single_no_jit` disables JIT and requires bytecode execution.",
    "- The collector rejects mode, identity, checksum, sample-index, pair-order, and 50 ms median-floor drift.",
    "- Every invocation is bracketed by fail-closed competing-process snapshots; host scheduling and frequency are otherwise not controlled, so RSD is retained and the result remains diagnostic.",
    "",
    `Raw evidence: [${rawPath.split("/").pop()}](${rawPath.split("/").pop()})`,
    "",
  );
  return lines.join("\n");
}

function syntheticRows(samples: number): Sample[] {
  const rows: Sample[] = [];
  WORKLOADS.forEach((workload, workloadIndex) => {
    for (let pair = 0; pair < samples; pair += 1) {
      const engines = (workloadIndex + pair) % 2 === 0
        ? ["zig-js", "JavaScriptCore"]
        : ["JavaScriptCore", "zig-js"];
      engines.forEach((engine, order) => rows.push({
        pair_sample: pair,
        order,
        engine,
        mode: "single",
        workload: workload.name,
        lanes: 1,
        jobs: workload.jobs,
        elapsed_ns: 60_000_000 + workloadIndex * 1_000_000 + pair,
        checksum: workload.checksum,
      }));
    }
  });
  return rows;
}

function syntheticGapRows(samples: number): GapSample[] {
  const rows: GapSample[] = [];
  WORKLOADS.forEach((workload, workloadIndex) => {
    for (let triplet = 0; triplet < samples; triplet += 1) {
      const order = GAP_ORDERS[(workloadIndex * samples + triplet) % GAP_ORDERS.length];
      order.forEach((variant, orderIndex) => rows.push({
        pair_sample: triplet,
        order: orderIndex,
        variant,
        engine: variant === "JavaScriptCore" ? "JavaScriptCore" : "zig-js",
        mode: "single",
        workload: workload.name,
        lanes: 1,
        jobs: workload.jobs,
        elapsed_ns: (variant === "baseline" ? 75_000_000 : variant === "candidate" ? 65_000_000 : 55_000_000) + workloadIndex * 1_000_000 + triplet,
        checksum: workload.checksum,
      }));
    }
  });
  return rows;
}

function expectFailure(action: () => void, pattern: string): void {
  try {
    action();
  } catch (error) {
    requireValue(String(error).includes(pattern), `expected ${pattern}, got ${error}`);
    return;
  }
  throw new Error(`expected failure containing ${pattern}`);
}

export function selfTest(): void {
  const rows = syntheticRows(3);
  validate(rows, 3);
  const checksum = rows.map((row) => ({ ...row }));
  checksum[0].checksum += 1;
  expectFailure(() => validate(checksum, 3), "checksum drift");
  const short = rows.map((row) => ({ ...row }));
  short.filter((row) => row.workload === WORKLOADS[0].name && row.engine === "zig-js")
    .forEach((row) => row.elapsed_ns = 1);
  expectFailure(() => validate(short, 3), "timing floor");
  const report = render({ metadata: { date: "fixture", samples: 3 }, summary: summarize(rows) }, "raw.json");
  requireValue(report.includes("representative_json_variant"), "report omitted variant");
  const gapRows = syntheticGapRows(3);
  validateGapReduction(gapRows, 3);
  const missingGapVariant = gapRows.map((row) => ({ ...row }));
  missingGapVariant[0].variant = "candidate";
  expectFailure(() => validateGapReduction(missingGapVariant, 3), "expected 3 rows");
  const gapReport = renderGapReduction(
    { metadata: { date: "fixture", samples: 3 }, summary: summarizeGapReduction(gapRows) },
    "gap-raw.json",
  );
  requireValue(gapReport.includes("baseline gap") && gapReport.includes("candidate gap"), "gap report omitted comparison columns");
  const tierRows = rows.filter((row) =>
    row.workload === WORKLOADS[0].name || row.workload === WORKLOADS[1].name
  ).map((row) => ({
    ...row,
    engine: "zig-js",
    mode: row.engine === "zig-js" ? "single" : "single_no_jit",
  }));
  validateTierResidency(tierRows, 3);
  const tierReport = renderTierResidency(
    { metadata: { date: "fixture", samples: 3 }, summary: summarizeTierResidency(tierRows) },
    "tier-raw.json",
  );
  requireValue(tierReport.includes("JIT / VM"), "tier report omitted ratio");
  const processFixture = [
    "100 1 /Applications/Host/app",
    "110 100 /Applications/Host/codex",
    "120 110 /tool/home-tool run json-pipeline-benchmark",
    "121 120 /repo/bench-comparison-zig-js single row 1 1",
    "200 100 /opt/zig build test",
    "210 100 /System/Library/CoreServices/ReportCrash",
    "220 100 /opt/bun test suite",
    "230 100 /repo/pantry/.bin/bun tools/dev.js",
    "231 100 /repo/pantry/.bin/bun",
  ].join("\n");
  expectFailure(
    () => requireNoCompetingEvidenceProcess("before fixture", processFixture, 120),
    "competing build/test process detected before fixture",
  );
  const cleanFixture = processFixture.split("\n").filter((line) =>
    !/^(200|210|220|230) /.test(line)
  ).join("\n");
  requireNoCompetingEvidenceProcess("before clean fixture", cleanFixture, 120);
  requireNoCompetingEvidenceProcess("after clean fixture", cleanFixture, 120);
  console.log("OK JSON pipeline benchmark: JSC/tier/gap matrices, checksums, order, timing, reports, and competing-job gates verified");
}

function optionValue(args: string[], name: string): string {
  const index = args.indexOf(name);
  requireValue(index >= 0 && index + 1 < args.length, `missing ${name}`);
  return args[index + 1];
}

function requireCleanTrackedRepository(): void {
  const trackedStatus = run([
    "git",
    "-C",
    ROOT,
    "status",
    "--porcelain",
    "--untracked-files=no",
  ]);
  requireValue(
    trackedStatus.exitCode === 0,
    trackedStatus.stderr || "cannot inspect repository status",
  );
  requireValue(
    !trackedStatus.stdout.trim(),
    "refusing evidence collection from a tracked-dirty repository",
  );
}

function main(): void {
  const args = process.argv.slice(2);
  if (args.length === 1 && args[0] === "--self-test") {
    selfTest();
    return;
  }
  const tierResidency = args[0] === "--tier-residency",
    gapReduction = args[0] === "--gap-reduction",
    runnerIndex = tierResidency || gapReduction ? 1 : 0,
    runnerCount = tierResidency ? 1 : gapReduction ? 3 : 2;
  requireValue(
    args.length >= runnerIndex + runnerCount,
    "usage: json-pipeline-benchmark.ts [--tier-residency ZIG_JS_RUNNER | --gap-reduction CANDIDATE_RUNNER BASELINE_RUNNER JSC_RUNNER | ZIG_JS_RUNNER JSC_RUNNER] --zig-js-revision REV [--baseline-revision REV] --zig PATH --zig-gc-repository PATH --zig-regex-repository PATH --raw-out PATH --markdown-out PATH [--samples N]",
  );
  const zigJs = args[runnerIndex],
    baseline = gapReduction ? args[runnerIndex + 1] : null,
    jsc = tierResidency ? null : args[runnerIndex + (gapReduction ? 2 : 1)],
    revision = optionValue(args, "--zig-js-revision"),
    baselineRevision = gapReduction ? optionValue(args, "--baseline-revision") : null,
    zig = optionValue(args, "--zig"),
    gcRepository = optionValue(args, "--zig-gc-repository"),
    regexRepository = optionValue(args, "--zig-regex-repository"),
    rawOut = optionValue(args, "--raw-out"),
    markdownOut = optionValue(args, "--markdown-out"),
    samplesIndex = args.indexOf("--samples"),
    samples = samplesIndex >= 0 ? Number(args[samplesIndex + 1]) : 7;
  requireValue(fileExists(zigJs) && (baseline === null || fileExists(baseline)) && (jsc === null || fileExists(jsc)), "benchmark runner does not exist");
  requireValue(/^[0-9a-f]{40}$/.test(revision), "zig-js revision must be a full commit id");
  requireValue(baselineRevision === null || (/^[0-9a-f]{40}$/.test(baselineRevision) && baselineRevision !== revision), "baseline revision must be a distinct full commit id");
  requireValue(Number.isInteger(samples) && samples > 0, "samples must be a positive integer");
  requireCleanTrackedRepository();
  const metadata: any = {
    date: commandOutput(["date", "+%F"]),
    host: `${commandOutput(["sysctl", "-n", "machdep.cpu.brand_string"])}; ${commandOutput(["sysctl", "-n", "hw.memsize"])} bytes`,
    os: `macOS ${commandOutput(["sw_vers", "-productVersion"])} (${commandOutput(["sw_vers", "-buildVersion"])})`,
    power: commandOutput(["pmset", "-g", "batt"], "unavailable").split(/\s+/).join(" "),
    zig_version: commandOutput([zig, "version"]),
    collector_revision: repositoryRevision(ROOT),
    zig_js_binary_revision: revision,
    zig_gc_revision: repositoryRevision(gcRepository),
    zig_regex_revision: repositoryRevision(regexRepository),
    workload_source: "bench/representative_comparison.js",
    workload_source_sha256: sha256File(`${ROOT}/bench/representative_comparison.js`),
    zig_js_binary_sha256: sha256File(zigJs),
    optimize: "ReleaseFast",
    allocator: "real precise collector; GC enabled",
    timed_boundary: "warmed persistent context; one exact invocation",
    samples,
    minimum_median_ns: MINIMUM_MEDIAN_NS,
    sample_order: "fresh-process alternating pairs, offset by workload",
    host_class: "diagnostic",
  };
  if (tierResidency) {
    const rows = collectTierResidency(zigJs, samples);
    validateTierResidency(rows, samples);
    const artifact = {
      schema_version: 1,
      kind: "focused_json_tier_residency",
      metadata,
      workloads: WORKLOADS.slice(0, 2),
      summary: summarizeTierResidency(rows),
      samples: rows,
    };
    writeText(rawOut, JSON.stringify(artifact, null, 2) + "\n");
    writeText(markdownOut, renderTierResidency(artifact, rawOut));
    process.stdout.write(renderTierResidency(artifact, rawOut));
    return;
  }
  if (gapReduction) {
    const rows = collectGapReduction(zigJs, baseline!, jsc!, samples);
    validateGapReduction(rows, samples);
    metadata.baseline_zig_js_binary_revision = baselineRevision;
    metadata.baseline_zig_js_binary_sha256 = sha256File(baseline!);
    metadata.jsc_binary_sha256 = sha256File(jsc!);
    const framework = "/System/Library/Frameworks/JavaScriptCore.framework/Resources/Info.plist";
    metadata.javascriptcore = `system framework ${commandOutput(["plutil", "-extract", "CFBundleVersion", "raw", framework])}`;
    const artifact = {
      schema_version: 1,
      kind: "focused_json_jsc_gap_reduction",
      metadata,
      workloads: WORKLOADS,
      summary: summarizeGapReduction(rows),
      samples: rows,
    };
    writeText(rawOut, JSON.stringify(artifact, null, 2) + "\n");
    writeText(markdownOut, renderGapReduction(artifact, rawOut));
    process.stdout.write(renderGapReduction(artifact, rawOut));
    return;
  }
  const rows = collect(zigJs, jsc!, samples);
  validate(rows, samples);
  const framework = "/System/Library/Frameworks/JavaScriptCore.framework/Resources/Info.plist";
  metadata.jsc_binary_sha256 = sha256File(jsc!);
  metadata.javascriptcore = `system framework ${commandOutput(["plutil", "-extract", "CFBundleVersion", "raw", framework])}`;
  const artifact = {
    schema_version: 1,
    kind: "focused_json_jsc_comparison",
    metadata,
    workloads: WORKLOADS,
    summary: summarize(rows),
    samples: rows,
  };
  writeText(rawOut, JSON.stringify(artifact, null, 2) + "\n");
  writeText(markdownOut, render(artifact, rawOut));
  process.stdout.write(render(artifact, rawOut));
}

if (process.argv[1] === __filename) main();
