/** Validate benchmark history and generate the README scorecard (#50). */
import {
  Row,
  WORKLOADS,
  parseRow,
  render as renderBenchmark,
  validate as validateBenchmark,
} from "./benchmark-comparison";
import { readText, writeText } from "./lib/home";
// Inventory-visible module edge: tools/benchmark-comparison.ts.
declare const __filename: string;
export const README_START = "<!-- benchmark-comparison:start -->",
  README_END = "<!-- benchmark-comparison:end -->";
const LIKE_FOR_LIKE_KEYS = [
    "Host",
    "OS",
    "Zig",
    "zig-gc",
    "zig-regex",
    "JavaScriptCore",
  ],
  REGRESSION_THRESHOLD_PERCENT = 10,
  MAX_RSD_PERCENT = 5;
function requireValue(condition: boolean, message: string): void {
  if (!condition) throw new Error(message);
}
export function groups(rows: Row[]): Record<string, Row[]> {
  const result: Record<string, Row[]> = {};
  rows.forEach((row) =>
    (result[
      JSON.stringify([row.engine, row.mode, row.workload, row.lanes, row.jobs])
    ] ||= []).push(row),
  );
  return result;
}
export function matrixConfiguration(rows: Row[]): [number, number[], boolean] {
  const grouped = groups(rows),
    counts = Array.from(
      new Set(Object.values(grouped).map((group) => group.length)),
    );
  requireValue(
    counts.length === 1,
    `benchmark matrix has inconsistent sample counts: ${JSON.stringify(counts.sort())}`,
  );
  const samples = counts[0],
    lanes = Array.from(
      new Set(rows.filter((row) => row.lanes > 1).map((row) => row.lanes)),
    ).sort((a, b) => a - b),
    jobs: any = {};
  Object.keys(WORKLOADS).forEach(
    (workload) =>
      (jobs[workload] = rows.find((row) => row.workload === workload)!.jobs),
  );
  const full = JSON.stringify(jobs) === JSON.stringify(WORKLOADS),
    quickJobs: any = {};
  Object.keys(WORKLOADS).forEach(
    (workload) =>
      (quickJobs[workload] = Math.max(1, Math.floor(WORKLOADS[workload] / 20))),
  );
  requireValue(
    full || JSON.stringify(jobs) === JSON.stringify(quickJobs),
    `benchmark matrix has unsupported workload job counts: ${JSON.stringify(jobs)}`,
  );
  return [samples, lanes, !full];
}
export function readRows(path: string): Row[] {
  const lines = readText(path).split("\n"),
    header =
      "engine\tmode\tworkload\tlanes\tjobs\tsample\telapsed_ns\tchecksum";
  requireValue(
    lines.length > 0 && lines[0] === header,
    `${path}: invalid benchmark TSV header`,
  );
  const rows = lines.slice(1).filter(Boolean).map(parseRow);
  requireValue(rows.length > 0, `${path}: no benchmark rows`);
  const configuration = matrixConfiguration(rows);
  validateBenchmark(rows, configuration[0], configuration[1], configuration[2]);
  return rows;
}
export function parseMetadata(path: string): Record<string, string> {
  const metadata: Record<string, string> = {};
  let environment = false;
  for (const line of readText(path).split("\n")) {
    if (line === "## Environment") {
      environment = true;
      continue;
    }
    if (environment && line.startsWith("## ")) break;
    if (!environment || !line.startsWith("|")) continue;
    const fields = line
      .replace(/^\||\|$/g, "")
      .split("|")
      .map((field) => field.trim());
    if (fields.length === 2 && !["item", "---"].includes(fields[0]))
      metadata[fields[0]] = fields[1];
  }
  const required = ["Date", "Power", "zig-js"].concat(LIKE_FOR_LIKE_KEYS),
    missing = required.filter((key) => !(key in metadata));
  requireValue(
    !missing.length,
    `${path}: missing environment metadata: ${JSON.stringify(missing.sort())}`,
  );
  return metadata;
}
export function matrixSignature(rows: Row[]): Set<string> {
  return new Set(
    rows.map((row) =>
      JSON.stringify([row.engine, row.mode, row.workload, row.lanes, row.jobs]),
    ),
  );
}
export function powerSignature(value: string): [string, string] {
  const source = value.includes("Battery Power")
      ? "Battery Power"
      : value.includes("AC Power")
        ? "AC Power"
        : value,
    lower = value.toLowerCase(),
    state =
      ["discharging", "charging", "charged"].find((candidate) =>
        lower.includes(candidate),
      ) || "unknown";
  return [source, state];
}
export function ensureReportMatches(
  rows: Row[],
  metadata: Record<string, string>,
  rawPath: string,
  reportPath: string,
): void {
  const configuration = matrixConfiguration(rows),
    lanes = configuration[1],
    expected = renderBenchmark(rows, lanes, rawPath, metadata);
  requireValue(
    readText(reportPath) === expected,
    `${reportPath}: report does not exactly match ${rawPath}`,
  );
}
const sameSet = (a: Set<string>, b: Set<string>): boolean =>
  a.size === b.size && Array.from(a).every((key) => b.has(key));
export function ensureLikeForLike(
  currentMetadata: Record<string, string>,
  baselineMetadata: Record<string, string>,
  currentRows: Row[],
  baselineRows: Row[],
): void {
  const mismatches = LIKE_FOR_LIKE_KEYS.filter(
    (key) => currentMetadata[key] !== baselineMetadata[key],
  ).map(
    (key) =>
      `${key}: ${JSON.stringify(baselineMetadata[key])} != ${JSON.stringify(currentMetadata[key])}`,
  );
  requireValue(
    !mismatches.length,
    `benchmark environments are not like-for-like: ${mismatches.join("; ")}`,
  );
  requireValue(
    JSON.stringify(powerSignature(currentMetadata.Power)) ===
      JSON.stringify(powerSignature(baselineMetadata.Power)),
    `benchmark environments are not like-for-like: Power: ${JSON.stringify(powerSignature(baselineMetadata.Power))} != ${JSON.stringify(powerSignature(currentMetadata.Power))}`,
  );
  requireValue(
    sameSet(matrixSignature(currentRows), matrixSignature(baselineRows)),
    "benchmark matrices are not like-for-like (engine/mode/workload/lanes/jobs differ)",
  );
  const current = groups(currentRows),
    baseline = groups(baselineRows);
  requireValue(
    Object.keys(current).every(
      (key) => baseline[key] && current[key].length === baseline[key].length,
    ),
    "benchmark matrices are not like-for-like (sample counts differ)",
  );
}
const median = (values: number[]): number => {
  const sorted = values.slice().sort((a, b) => a - b),
    middle = Math.floor(sorted.length / 2);
  return sorted.length % 2
    ? sorted[middle]
    : (sorted[middle - 1] + sorted[middle]) / 2;
};
export function relativeStddev(values: number[]): number {
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
}
export function regressionRows(
  currentRows: Row[],
  baselineRows: Row[],
  threshold = REGRESSION_THRESHOLD_PERCENT,
  maxRsd = MAX_RSD_PERCENT,
): any[] {
  const current = groups(currentRows),
    baseline = groups(baselineRows),
    result: any[] = [];
  for (const key of Object.keys(current).sort()) {
    const identity = JSON.parse(key);
    if (identity[0] !== "zig-js") continue;
    const currentValues = current[key].map((row) => row.elapsed_ns),
      baselineValues = baseline[key].map((row) => row.elapsed_ns),
      currentMedian = median(currentValues),
      baselineMedian = median(baselineValues),
      delta = (currentMedian / baselineMedian - 1) * 100,
      currentRsd = relativeStddev(currentValues),
      baselineRsd = relativeStddev(baselineValues);
    if (delta > threshold && currentRsd <= maxRsd && baselineRsd <= maxRsd)
      result.push([
        identity,
        delta,
        baselineMedian,
        currentMedian,
        baselineRsd,
        currentRsd,
      ]);
  }
  return result;
}
export function historyRows(currentRows: Row[], baselineRows: Row[]): any[] {
  const current = groups(currentRows),
    baseline = groups(baselineRows),
    result: any[] = [];
  for (const key of Object.keys(current).sort()) {
    const identity = JSON.parse(key),
      currentValues = current[key].map((row) => row.elapsed_ns),
      baselineValues = baseline[key].map((row) => row.elapsed_ns),
      currentMedian = median(currentValues),
      baselineMedian = median(baselineValues),
      delta = (currentMedian / baselineMedian - 1) * 100,
      currentRsd = relativeStddev(currentValues),
      baselineRsd = relativeStddev(baselineValues);
    const status =
      identity[0] !== "zig-js"
        ? "control"
        : delta > 10
          ? Math.max(currentRsd, baselineRsd) <= 5
            ? "regression"
            : "noisy"
          : delta < -10
            ? "improved"
            : "stable";
    result.push([
      identity,
      delta,
      baselineMedian,
      currentMedian,
      baselineRsd,
      currentRsd,
      status,
    ]);
  }
  return result;
}
const geometricMean = (values: number[]): number =>
  Math.exp(
    values.reduce((sum, value) => sum + Math.log(value), 0) / values.length,
  );
const medianNs = (grouped: Record<string, Row[]>, key: any[]): number =>
  median(grouped[JSON.stringify(key)].map((row) => row.elapsed_ns));
export function readmeScorecard(
  rows: Row[],
  metadata: Record<string, string>,
  reportLink: string,
  rawLink: string,
): string {
  const grouped = groups(rows),
    workloads = Object.keys(WORKLOADS),
    maxLanes = rows.reduce((maximum, row) => Math.max(maximum, row.lanes), 0),
    jobs: any = {};
  workloads.forEach(
    (workload) =>
      (jobs[workload] = rows.find((row) => row.workload === workload)!.jobs),
  );
  const direct: number[] = [],
    steady: number[] = [],
    cold: number[] = [],
    zigSteady: number[] = [],
    jscSteady: number[] = [],
    zigCold: number[] = [],
    jscCold: number[] = [],
    shared: number[] = [];
  for (const workload of workloads) {
    const count = jobs[workload];
    direct.push(
      medianNs(grouped, ["JavaScriptCore", "single", workload, 1, count]) /
        medianNs(grouped, ["zig-js", "single", workload, 1, count]),
    );
    for (const [mode, ratios, zs, js] of [
      ["independent_steady", steady, zigSteady, jscSteady],
      ["independent_cold", cold, zigCold, jscCold],
    ] as any[]) {
      const zo = medianNs(grouped, ["zig-js", mode, workload, 1, count]),
        jo = medianNs(grouped, ["JavaScriptCore", mode, workload, 1, count]),
        zm = medianNs(grouped, ["zig-js", mode, workload, maxLanes, count]),
        jm = medianNs(grouped, [
          "JavaScriptCore",
          mode,
          workload,
          maxLanes,
          count,
        ]);
      ratios.push(jm / zm);
      zs.push((maxLanes * zo) / zm);
      js.push((maxLanes * jo) / jm);
    }
    const one = medianNs(grouped, ["zig-js", "shared", workload, 1, count]),
      maximum = medianNs(grouped, [
        "zig-js",
        "shared",
        workload,
        maxLanes,
        count,
      ]);
    shared.push((maxLanes * one) / maximum);
  }
  const wins = (values: number[]) => values.filter((value) => value > 1).length;
  return [
    "<!-- Generated by tools/benchmark-publication.ts; do not edit headline numbers manually. -->",
    "",
    `Latest accepted [report](${reportLink}) · [${rows.length.toLocaleString("en-US")} raw samples](${rawLink}). Equal-work checks, alternating order, dispersion limits, and a 50 ms timing floor are enforced by the harness.`,
    "",
    "| mode | lanes | wins vs JSC | zig-js / JSC throughput | zig-js scaling | JSC scaling |",
    "| --- | ---: | ---: | ---: | ---: | ---: |",
    `| direct warmed context | 1 | ${wins(direct)} / ${workloads.length} | **${geometricMean(direct).toFixed(2)}x** | — | — |`,
    `| independent steady contexts | ${maxLanes} | ${wins(steady)} / ${workloads.length} | **${geometricMean(steady).toFixed(2)}x** | **${geometricMean(zigSteady).toFixed(2)}x** | ${geometricMean(jscSteady).toFixed(2)}x |`,
    `| independent cold lifecycles | ${maxLanes} | ${wins(cold)} / ${workloads.length} | **${geometricMean(cold).toFixed(2)}x** | **${geometricMean(zigCold).toFixed(2)}x** | ${geometricMean(jscCold).toFixed(2)}x |`,
    `| shared realm, no GIL | ${maxLanes} | no public-JSC equivalent | — | **${geometricMean(shared).toFixed(2)}x** | — |`,
    "",
    "Ratios above 1.00x favor zig-js. JSC has no public shared-realm embedding equivalent.",
  ].join("\n");
}
export function replaceReadmeBlock(text: string, generated: string): string {
  requireValue(
    text.split(README_START).length - 1 === 1 &&
      text.split(README_END).length - 1 === 1 &&
      text.indexOf(README_START) < text.indexOf(README_END),
    "README must contain exactly one ordered benchmark-comparison marker pair",
  );
  const before = text.slice(0, text.indexOf(README_START)),
    after = text.slice(text.indexOf(README_END) + README_END.length);
  return `${before}${README_START}\n${generated.trimEnd()}\n${README_END}${after}`;
}
export function renderHistory(
  comparisons: any[],
  current: Record<string, string>,
  baseline: Record<string, string>,
  currentReport: string,
  baselineReport: string,
): string {
  const regressions = comparisons.filter(
      (row) => row[row.length - 1] === "regression",
    ),
    power = powerSignature(current.Power),
    lines = [
      `# Benchmark history: ${baseline.Date} → ${current.Date}`,
      "",
      `- Baseline: zig-js \`${baseline["zig-js"]}\` from \`${baselineReport}\``,
      `- Current: zig-js \`${current["zig-js"]}\` from \`${currentReport}\``,
      `- Controlled environment: ${current.Host}; ${current.OS}; ${power[0]} (${power[1]})`,
      "",
      "Environment, matrix, jobs, and sample counts are like-for-like. A zig-js regression fails publication only",
      `when median wall time worsens by more than ${REGRESSION_THRESHOLD_PERCENT}% and both baseline/current RSD are at most ${MAX_RSD_PERCENT}%.`,
      "JSC rows are retained as environmental controls but never gate zig-js publication.",
      "",
      "| engine | mode | workload | lanes | jobs | baseline (ms) | current (ms) | delta | baseline RSD | current RSD | status |",
      "| --- | --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | --- |",
    ];
  for (const [key, delta, base, now, baseRsd, nowRsd, status] of comparisons)
    lines.push(
      `| ${key[0]} | ${key[1]} | ${key[2]} | ${key[3]} | ${key[4]} | ${(base / 1e6).toFixed(3)} | ${(now / 1e6).toFixed(3)} | ${delta >= 0 ? "+" : ""}${delta.toFixed(2)}% | ${baseRsd.toFixed(2)}% | ${nowRsd.toFixed(2)}% | ${status} |`,
    );
  lines.push(
    "",
    `Noise-qualified zig-js regressions: **${regressions.length}**.`,
  );
  return lines.join("\n") + "\n";
}
function relativePath(fromFile: string, target: string): string {
  const from = fromFile.split("/").slice(0, -1),
    to = target.split("/"),
    absolute = fromFile.startsWith("/");
  if (absolute) {
    from.shift();
    to.shift();
  }
  while (from.length && to.length && from[0] === to[0]) {
    from.shift();
    to.shift();
  }
  return (
    from
      .map(() => "..")
      .concat(to)
      .join("/") || "."
  );
}
function testMetadata(updates: any = {}): Record<string, string> {
  return {
    Date: "2026-07-16",
    Host: "Example CPU; 8 physical / 8 logical CPUs; 16.0 GiB",
    OS: "macOS 27.0 (A)",
    Zig: "0.17.0-dev",
    "zig-js": "new",
    "zig-gc": "gc",
    "zig-regex": "regex",
    JavaScriptCore: "system framework 1",
    Power: "AC Power",
    ...updates,
  };
}
function testRows(elapsed = [100, 101, 99]): Row[] {
  return elapsed
    .map((value, sample) => ({
      engine: "zig-js",
      mode: "single",
      workload: "arithmetic",
      lanes: 1,
      jobs: 1,
      sample,
      elapsed_ns: value,
      checksum: 1,
    }))
    .concat(
      elapsed.map((_, sample) => ({
        engine: "JavaScriptCore",
        mode: "single",
        workload: "arithmetic",
        lanes: 1,
        jobs: 1,
        sample,
        elapsed_ns: 200,
        checksum: 1,
      })),
    );
}
function expectFailure(action: () => void, pattern: string): void {
  try {
    action();
  } catch (error) {
    requireValue(
      String(error).includes(pattern),
      `expected ${pattern}, got ${String(error)}`,
    );
    return;
  }
  throw new Error(`expected failure containing ${pattern}`);
}
export function selfTest(): void {
  ensureLikeForLike(
    testMetadata({ "zig-js": "new" }),
    testMetadata({ "zig-js": "old" }),
    testRows(),
    testRows(),
  );
  expectFailure(
    () =>
      ensureLikeForLike(
        testMetadata({ Zig: "new" }),
        testMetadata({ Zig: "old" }),
        testRows(),
        testRows(),
      ),
    "not like-for-like",
  );
  ensureLikeForLike(
    testMetadata({ Power: "Battery Power 32%; discharging" }),
    testMetadata({ Power: "Battery Power 91%; discharging" }),
    testRows(),
    testRows(),
  );
  expectFailure(
    () =>
      ensureLikeForLike(
        testMetadata({ Power: "AC Power; charged" }),
        testMetadata({ Power: "Battery Power 91%; discharging" }),
        testRows(),
        testRows(),
      ),
    "Power",
  );
  expectFailure(
    () =>
      ensureLikeForLike(
        testMetadata(),
        testMetadata(),
        testRows().map((row) => ({ ...row, jobs: 2 })),
        testRows(),
      ),
    "matrices are not like-for-like",
  );
  requireValue(
    regressionRows(testRows([121, 120, 119]), testRows()).length === 1,
    "stable regression not found",
  );
  requireValue(
    regressionRows(testRows([80, 120, 160]), testRows()).length === 0,
    "noisy regression falsely found",
  );
  requireValue(
    JSON.stringify(
      historyRows(testRows(), testRows())
        .map((row) => row[row.length - 1])
        .sort(),
    ) === '["control","stable"]',
    "history status drift",
  );
  const initial = `before\n${README_START}\nold\n${README_END}\nafter\n`,
    once = replaceReadmeBlock(initial, "generated");
  requireValue(
    replaceReadmeBlock(once, "generated") === once,
    "marker replacement is not idempotent",
  );
  expectFailure(
    () => replaceReadmeBlock("no markers", "generated"),
    "exactly one",
  );
  const generated: Row[] = [];
  Object.keys(WORKLOADS).forEach((workload, index) => {
    for (const [engine, elapsed] of [
      ["zig-js", 100],
      ["JavaScriptCore", 200],
    ] as any[])
      generated.push({
        engine,
        mode: "single",
        workload,
        lanes: 1,
        jobs: 1,
        sample: 0,
        elapsed_ns: elapsed,
        checksum: 1,
      });
    for (const mode of ["independent_steady", "independent_cold"])
      for (const lanes of [1, 8])
        for (const [engine, base] of [
          ["zig-js", 100],
          ["JavaScriptCore", 200],
        ] as any[])
          generated.push({
            engine,
            mode,
            workload,
            lanes,
            jobs: 1,
            sample: 0,
            elapsed_ns:
              mode === "independent_steady" &&
              lanes === 8 &&
              index === 0 &&
              engine === "zig-js"
                ? 300
                : base,
            checksum: 1,
          });
    for (const [lanes, elapsed] of [
      [1, 100],
      [8, 200],
    ])
      generated.push({
        engine: "zig-js",
        mode: "shared",
        workload,
        lanes,
        jobs: 1,
        sample: 0,
        elapsed_ns: elapsed,
        checksum: 1,
      });
  });
  const scorecard = readmeScorecard(
    generated,
    testMetadata(),
    "report.md",
    "raw.tsv",
  );
  requireValue(
    scorecard.includes("| independent steady contexts | 8 | 9 / 10 |") &&
      !scorecard.includes("wins all 10"),
    "partial-mode scorecard drift",
  );
  console.log(
    "OK benchmark publication self-test: history, noise, environment, and README gates verified",
  );
}
function main(): void {
  const rawArgs = process.argv.slice(2),
    scorecardOnly = rawArgs.includes("--scorecard"),
    args = rawArgs.filter((argument) => argument !== "--scorecard");
  if (args.length === 1 && args[0] === "--self-test") {
    selfTest();
    return;
  }
  const options: any = {};
  for (let index = 0; index < args.length; index += 2) {
    const name = args[index],
      value = args[index + 1];
    const key: any = {
      "--current-raw": "currentRaw",
      "--current-report": "currentReport",
      "--readme": "readme",
      "--baseline-raw": "baselineRaw",
      "--baseline-report": "baselineReport",
      "--history-out": "history",
    }[name];
    requireValue(key && value, `unknown or incomplete argument: ${name}`);
    options[key] = value;
  }
  requireValue(
    options.currentRaw && options.currentReport,
    "--current-raw and --current-report are required",
  );
  requireValue(
    scorecardOnly || options.readme || options.baselineRaw || options.baselineReport,
    "request --readme and/or a baseline raw/report pair",
  );
  requireValue(
    Boolean(options.baselineRaw) === Boolean(options.baselineReport),
    "--baseline-raw and --baseline-report must be provided together",
  );
  requireValue(
    !options.history || options.baselineRaw,
    "--history-out requires a baseline raw/report pair",
  );
  const currentRows = readRows(options.currentRaw),
    currentMetadata = parseMetadata(options.currentReport);
  ensureReportMatches(
    currentRows,
    currentMetadata,
    options.currentRaw,
    options.currentReport,
  );
  if (scorecardOnly) {
    process.stdout.write(readmeScorecard(currentRows, currentMetadata, options.currentReport, options.currentRaw) + "\n");
    return;
  }
  if (options.readme)
    writeText(
      options.readme,
      replaceReadmeBlock(
        readText(options.readme),
        readmeScorecard(
          currentRows,
          currentMetadata,
          relativePath(options.readme, options.currentReport),
          relativePath(options.readme, options.currentRaw),
        ),
      ),
    );
  if (options.baselineRaw) {
    const baselineRows = readRows(options.baselineRaw),
      baselineMetadata = parseMetadata(options.baselineReport);
    ensureReportMatches(
      baselineRows,
      baselineMetadata,
      options.baselineRaw,
      options.baselineReport,
    );
    ensureLikeForLike(
      currentMetadata,
      baselineMetadata,
      currentRows,
      baselineRows,
    );
    const regressions = regressionRows(currentRows, baselineRows),
      history = renderHistory(
        historyRows(currentRows, baselineRows),
        currentMetadata,
        baselineMetadata,
        options.currentReport,
        options.baselineReport,
      );
    if (options.history) writeText(options.history, history);
    else process.stdout.write(history);
    requireValue(
      !regressions.length,
      `${regressions.length} noise-qualified benchmark regressions exceeded 10%`,
    );
  }
}
if (process.argv[1] === __filename) main();
