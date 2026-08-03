/** Run and report the reproducible zig-js / system-JSC comparison matrix. */
import { checked, run, writeText } from "./lib/home";
declare const __dirname: string;
declare const __filename: string;
export const ROOT =
  __dirname === "tools"
    ? "."
    : __dirname.slice(0, __dirname.lastIndexOf("/tools"));
export const WORKLOADS: Record<string, number> = {
  arithmetic: 240,
  properties: 300,
  polymorphic_properties: 400,
  object_churn: 100,
  arrays: 550,
  direct_calls: 600,
  method_calls: 500,
  closure_calls: 600,
  arguments_calls: 600,
  fibonacci: 125,
};
export const MIN_FULL_MEDIAN_NS = 50000000;
export type Row = {
  engine: string;
  mode: string;
  workload: string;
  lanes: number;
  jobs: number;
  sample: number;
  elapsed_ns: number;
  checksum: number;
};
export const rowKey = (row: Row): string =>
  JSON.stringify([row.engine, row.mode, row.workload, row.lanes, row.jobs]);
function requireValue(condition: boolean, message: string): void {
  if (!condition) throw new Error(message);
}
export function commandOutput(
  args: string[],
  defaultValue = "unknown",
): string {
  const result = run(args);
  return result.exitCode === 0 && result.stdout.trim()
    ? result.stdout.trim()
    : defaultValue;
}
export function parseRow(line: string): Row {
  const fields = line.replace(/\n$/, "").split("\t");
  requireValue(
    fields.length === 8,
    `expected 8 TSV fields, got ${fields.length}: ${JSON.stringify(line)}`,
  );
  return {
    engine: fields[0],
    mode: fields[1],
    workload: fields[2],
    lanes: Number(fields[3]),
    jobs: Number(fields[4]),
    sample: Number(fields[5]),
    elapsed_ns: Number(fields[6]),
    checksum: Number(fields[7]),
  };
}
export function runCase(binary: string, arguments_: string[]): Row[] {
  const command = ["env", "LC_ALL=C", binary].concat(arguments_);
  console.error(`+ ${command.join(" ")}`);
  const completed = run(command);
  if (completed.stderr) process.stderr.write(completed.stderr);
  requireValue(
    completed.exitCode === 0,
    completed.stderr || `benchmark exited ${completed.exitCode}`,
  );
  return completed.stdout
    .split("\n")
    .filter((line) => line.trim())
    .map(parseRow);
}
export function collect(
  zigJs: string,
  jsc: string,
  samples: number,
  lanes: number[],
  quick: boolean,
): Row[] {
  const rows: Row[] = [],
    allLanes = [1].concat(lanes);
  let pairIndex = 0;
  const runPair = (arguments_: string[]) => {
    const pair = pairIndex++ % 2 ? [jsc, zigJs] : [zigJs, jsc];
    pair.forEach((binary) => runCase(binary, arguments_).forEach((row) => rows.push(row)));
  };
  for (const workload of Object.keys(WORKLOADS)) {
    const jobs = quick
      ? Math.max(1, Math.floor(WORKLOADS[workload] / 20))
      : WORKLOADS[workload];
    runPair(["single", workload, String(jobs), String(samples)]);
    for (const lane of allLanes) {
      for (const mode of ["independent_steady", "independent_cold"])
        runPair([mode, workload, String(jobs), String(samples), String(lane)]);
      runCase(zigJs, [
          "shared",
          workload,
          String(jobs),
          String(samples),
          String(lane),
        ]).forEach((row) => rows.push(row));
    }
  }
  return rows;
}
export function groups(rows: Row[]): Record<string, Row[]> {
  const result: Record<string, Row[]> = {};
  rows.forEach((row) => (result[rowKey(row)] ||= []).push(row));
  return result;
}
export function validate(
  rows: Row[],
  samples: number,
  lanes: number[],
  quick: boolean,
): void {
  const grouped = groups(rows),
    allLanes = [1].concat(lanes),
    expected = new Set<string>();
  for (const workload of Object.keys(WORKLOADS)) {
    const jobs = quick
      ? Math.max(1, Math.floor(WORKLOADS[workload] / 20))
      : WORKLOADS[workload];
    expected.add(JSON.stringify(["zig-js", "single", workload, 1, jobs]));
    expected.add(
      JSON.stringify(["JavaScriptCore", "single", workload, 1, jobs]),
    );
    for (const lane of allLanes) {
      expected.add(JSON.stringify(["zig-js", "shared", workload, lane, jobs]));
      for (const engine of ["zig-js", "JavaScriptCore"])
        for (const mode of ["independent_steady", "independent_cold"])
          expected.add(JSON.stringify([engine, mode, workload, lane, jobs]));
    }
  }
  const actual = new Set(Object.keys(grouped));
  requireValue(
    actual.size === expected.size &&
      Array.from(expected).every((key) => actual.has(key)),
    `result matrix mismatch; missing=${JSON.stringify(Array.from(expected).filter((key) => !actual.has(key)))}, unexpected=${JSON.stringify(Array.from(actual).filter((key) => !expected.has(key)))}`,
  );
  for (const key of Object.keys(grouped)) {
    const group = grouped[key];
    requireValue(
      group.length === samples,
      `${key} has ${group.length} samples, expected ${samples}`,
    );
    requireValue(
      JSON.stringify(group.map((row) => row.sample).sort((a, b) => a - b)) ===
        JSON.stringify(Array.from({ length: samples }, (_, index) => index)),
      `${key} has invalid sample indexes`,
    );
    requireValue(
      new Set(group.map((row) => row.checksum)).size === 1,
      `${key} produced unstable checksums`,
    );
    requireValue(
      quick || median(group.map((row) => row.elapsed_ns)) >= MIN_FULL_MEDIAN_NS,
      `${key} median is shorter than the ${MIN_FULL_MEDIAN_NS / 1e6} ms full-run timing floor`,
    );
  }
  const byWork: Record<string, Set<number>> = {};
  rows.forEach((row) =>
    (byWork[JSON.stringify([row.workload, row.lanes, row.jobs])] ||=
      new Set()).add(row.checksum),
  );
  const mismatches = Object.keys(byWork).filter(
    (key) => byWork[key].size !== 1,
  );
  requireValue(
    !mismatches.length,
    `cross-engine checksum mismatch: ${JSON.stringify(mismatches)}`,
  );
}
const median = (values: number[]): number => {
  const sorted = values.slice().sort((a, b) => a - b),
    middle = Math.floor(sorted.length / 2);
  return sorted.length % 2
    ? sorted[middle]
    : (sorted[middle - 1] + sorted[middle]) / 2;
};
export function medianNs(grouped: Record<string, Row[]>, key: any[]): number {
  const group = grouped[JSON.stringify(key)];
  requireValue(Boolean(group), `missing benchmark group ${JSON.stringify(key)}`);
  return median(group.map((row) => row.elapsed_ns));
}
export function spread(
  grouped: Record<string, Row[]>,
  key: any[],
): [number, number, number] {
  const values = grouped[JSON.stringify(key)].map((row) => row.elapsed_ns),
    mean = values.reduce((sum, value) => sum + value, 0) / values.length,
    rsd =
      values.length > 1
        ? (Math.sqrt(
            values.reduce((sum, value) => sum + (value - mean) ** 2, 0) /
              (values.length - 1),
          ) /
            mean) *
          100
        : 0;
  return [
    values.reduce((minimum, value) => Math.min(minimum, value), values[0]),
    values.reduce((maximum, value) => Math.max(maximum, value), values[0]),
    rsd,
  ];
}
export const geometricMean = (values: number[]): number =>
  Math.exp(
    values.reduce((sum, value) => sum + Math.log(value), 0) / values.length,
  );
export function repositoryRevision(path: string): string {
  const commit = commandOutput(["git", "-C", path, "rev-parse", "HEAD"]),
    dirty = commandOutput(
      ["git", "-C", path, "status", "--porcelain", "--untracked-files=no"],
      "",
    );
  return commit + (dirty ? " (tracked worktree dirty)" : "");
}
export function metadata(): Record<string, string> {
  const framework =
      "/System/Library/Frameworks/JavaScriptCore.framework/Resources/Info.plist",
    memory = commandOutput(["sysctl", "-n", "hw.memsize"]),
    memoryGiB = /^\d+$/.test(memory)
      ? `${(Number(memory) / 1024 ** 3).toFixed(1)} GiB`
      : memory,
    cpu = commandOutput(["sysctl", "-n", "machdep.cpu.brand_string"]),
    physical = commandOutput(["sysctl", "-n", "hw.physicalcpu"]),
    logical = commandOutput(["sysctl", "-n", "hw.logicalcpu"]);
  return {
    Date: commandOutput(["date", "+%F"]),
    Host: `${cpu}; ${physical} physical / ${logical} logical CPUs; ${memoryGiB}`,
    OS: `macOS ${commandOutput(["sw_vers", "-productVersion"], commandOutput(["uname", "-a"]))} (${commandOutput(["sw_vers", "-buildVersion"])})`,
    Zig: commandOutput(["zig", "version"]),
    "zig-js": repositoryRevision(ROOT),
    "zig-gc": repositoryRevision(`${ROOT}/../zig-gc`),
    "zig-regex": repositoryRevision(`${ROOT}/../zig-regex`),
    JavaScriptCore: `system framework ${commandOutput(["plutil", "-extract", "CFBundleVersion", "raw", framework])}`,
    Power: commandOutput(["pmset", "-g", "batt"], "unavailable")
      .split(/\s+/)
      .join(" "),
  };
}
export function ensurePublishable(
  info: Record<string, string>,
  publishing: boolean,
): void {
  if (!publishing) return;
  const dirty = Object.keys(info).filter((name) =>
    info[name].endsWith(" (tracked worktree dirty)"),
  );
  requireValue(
    !dirty.length,
    `refusing to publish benchmark evidence from dirty tracked worktree(s): ${dirty.join(", ")}`,
  );
}
const fmt = (value: number, digits = 3): string => value.toFixed(digits);
function engineTable(
  lines: string[],
  rows: Row[],
  grouped: Record<string, Row[]>,
  allLanes: number[],
  mode: string,
  heading: string,
  maxRatios: number[],
  zigScaling: number[],
  jscScaling: number[],
): void {
  lines.push(
    "",
    `## ${heading}`,
    "",
  );
  if (mode === "independent_steady") lines.push(
    "Both engines keep one warmed context on one persistent OS worker per lane. The timed region contains the",
    "same semaphore dispatch, exact invocation, and completion wait. Every lane performs the full job count.",
    "`scaling` uses the same engine and mode at one lane; cross-engine throughput is directly comparable.",
    "",
  );
  else lines.push(
    "Neither engine warms these contexts. The timer covers OS-thread creation, context creation, workload-source",
    "evaluation and configuration, the exact invocation, context destruction, and OS-thread join on both sides.",
    "`scaling` uses the same engine and cold lifecycle at one lane.",
    "",
  );
  lines.push(
    "| workload | lanes | jobs/lane | zig-js median (ms) | zig-js min–max (ms) | zig-js RSD | JSC median (ms) | JSC min–max (ms) | JSC RSD | JSC / zig-js | zig-js scaling | JSC scaling |",
    "| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |",
  );
  for (const workload of Object.keys(WORKLOADS)) {
    const jobs = rows.find((row) => row.workload === workload)!.jobs,
      zigOne = medianNs(grouped, ["zig-js", mode, workload, 1, jobs]),
      jscOne = medianNs(grouped, ["JavaScriptCore", mode, workload, 1, jobs]);
    for (const lane of allLanes) {
      const zk = ["zig-js", mode, workload, lane, jobs],
        jk = ["JavaScriptCore", mode, workload, lane, jobs],
        zig = medianNs(grouped, zk),
        jsc = medianNs(grouped, jk),
        [zmin, zmax, zrsd] = spread(grouped, zk),
        [jmin, jmax, jrsd] = spread(grouped, jk),
        zs = (lane * zigOne) / zig,
        js = (lane * jscOne) / jsc,
        ratio = zig / jsc;
      if (lane === allLanes[allLanes.length - 1]) {
        maxRatios.push(ratio);
        zigScaling.push(zs);
        jscScaling.push(js);
      }
      lines.push(
        `| \`${workload}\` | ${lane} | ${jobs} | ${fmt(zig / 1e6)} | ${fmt(zmin / 1e6)}–${fmt(zmax / 1e6)} | ${zrsd.toFixed(2)}% | ${fmt(jsc / 1e6)} | ${fmt(jmin / 1e6)}–${fmt(jmax / 1e6)} | ${jrsd.toFixed(2)}% | ${ratio.toFixed(2)}x | ${zs.toFixed(2)}x | ${js.toFixed(2)}x |`,
      );
    }
  }
}
export function render(
  rows: Row[],
  lanes: number[],
  rawPath: string | null,
  info: Record<string, string>,
): string {
  const grouped = groups(rows),
    allLanes = [1].concat(lanes),
    maxLanes = allLanes[allLanes.length - 1],
    lines = [
      `# zig-js / JavaScriptCore benchmark — ${info.Date}`,
      "",
      "> This is a dated measurement, not a universal engine score. The workload source, raw samples,",
      "> timed boundaries, and semantic differences are recorded so the result can be reproduced and challenged.",
      "",
      "## Environment",
      "",
      "| item | value |",
      "| --- | --- |",
    ];
  Object.keys(info).forEach((key) => lines.push(`| ${key} | ${info[key]} |`));
  lines.push(
    "",
    "## Single-thread result",
    "",
    "Each row runs the same number of jobs in one GC-enabled zig-js context and one warmed JSC global context.",
    "Both runners time the exact invocation `__benchmarkSelected(__benchmarkJobs, __benchmarkLane)`.",
    "Lower time is better; `JSC / zig-js` is JSC throughput divided by zig-js throughput. RSD is relative standard deviation.",
    "",
    "| workload | jobs | zig-js median (ms) | zig-js min–max (ms) | zig-js RSD | JSC median (ms) | JSC min–max (ms) | JSC RSD | JSC / zig-js |",
    "| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |",
  );
  const singles: number[] = [];
  for (const workload of Object.keys(WORKLOADS)) {
    const jobs = rows.find((row) => row.workload === workload)!.jobs,
      zk = ["zig-js", "single", workload, 1, jobs],
      jk = ["JavaScriptCore", "single", workload, 1, jobs],
      zig = medianNs(grouped, zk),
      jsc = medianNs(grouped, jk),
      [zmin, zmax, zrsd] = spread(grouped, zk),
      [jmin, jmax, jrsd] = spread(grouped, jk),
      ratio = zig / jsc;
    singles.push(ratio);
    lines.push(
      `| \`${workload}\` | ${jobs} | ${fmt(zig / 1e6)} | ${fmt(zmin / 1e6)}–${fmt(zmax / 1e6)} | ${zrsd.toFixed(2)}% | ${fmt(jsc / 1e6)} | ${fmt(jmin / 1e6)}–${fmt(jmax / 1e6)} | ${jrsd.toFixed(2)}% | ${ratio.toFixed(2)}x |`,
    );
  }
  const steadyRatios: number[] = [],
    zigSteady: number[] = [],
    jscSteady: number[] = [],
    coldRatios: number[] = [],
    zigCold: number[] = [],
    jscCold: number[] = [];
  engineTable(
    lines,
    rows,
    grouped,
    allLanes,
    "independent_steady",
    "Independent-context steady state",
    steadyRatios,
    zigSteady,
    jscSteady,
  );
  engineTable(
    lines,
    rows,
    grouped,
    allLanes,
    "independent_cold",
    "Independent-context cold lifecycle",
    coldRatios,
    zigCold,
    jscCold,
  );
  lines.push(
    "",
    "## zig-js shared-realm scaling",
    "",
    "This is zig-js's distinct no-GIL shared-object-graph model, which JSC's public C API does not provide.",
    "The timed region creates JavaScript `Thread`s, performs the work, and joins them. Scaling uses the same",
    "shared-realm path at one lane, so thread lifecycle overhead is present in every row.",
    "",
    "| workload | lanes | jobs/lane | median (ms) | min–max (ms) | RSD | scaling |",
    "| --- | ---: | ---: | ---: | ---: | ---: | ---: |",
  );
  const sharedScaling: number[] = [];
  for (const workload of Object.keys(WORKLOADS)) {
    const jobs = rows.find((row) => row.workload === workload)!.jobs,
      one = medianNs(grouped, ["zig-js", "shared", workload, 1, jobs]);
    for (const lane of allLanes) {
      const key = ["zig-js", "shared", workload, lane, jobs],
        elapsed = medianNs(grouped, key),
        [minimum, maximum, dispersion] = spread(grouped, key),
        scaling = (lane * one) / elapsed;
      if (lane === maxLanes) sharedScaling.push(scaling);
      lines.push(
        `| \`${workload}\` | ${lane} | ${jobs} | ${fmt(elapsed / 1e6)} | ${fmt(minimum / 1e6)}–${fmt(maximum / 1e6)} | ${dispersion.toFixed(2)}% | ${scaling.toFixed(2)}x |`,
      );
    }
  }
  lines.push(
    "",
    "## Reading the result",
    "",
    `Across these ${Object.keys(WORKLOADS).length} deliberately small kernels, JSC's single-context throughput is ${geometricMean(singles).toFixed(2)}x`,
    "the zig-js throughput by geometric mean. These kernels deliberately exercise guarded native/VM tiers that",
    "zig-js currently implements; rows outside those documented subsets continue through general bytecode paths.",
    "The number is a compact description of this matrix, not a claim about applications or unsupported workloads.",
    "",
    `At ${maxLanes} independent warmed contexts, JSC throughput is ${geometricMean(steadyRatios).toFixed(2)}x zig-js by`,
    `geometric mean; scaling from the mode's own one-lane baseline is ${geometricMean(zigSteady).toFixed(2)}x`,
    `for zig-js and ${geometricMean(jscSteady).toFixed(2)}x for JSC. In the symmetric cold lifecycle, JSC`,
    `throughput is ${geometricMean(coldRatios).toFixed(2)}x zig-js, with ${geometricMean(zigCold).toFixed(2)}x`,
    `and ${geometricMean(jscCold).toFixed(2)}x scaling respectively.`,
    "",
    `zig-js's shared-realm path scales ${geometricMean(sharedScaling).toFixed(2)}x at ${maxLanes} lanes from its`,
    "own one-lane shared baseline. It has no direct JSC ratio because the public JSC embedding API exposes",
    "isolated global contexts, not concurrent JavaScript workers sharing one object graph. Per-workload rows",
    "matter more than any aggregate.",
    "",
    "## Method and timed boundaries",
    "",
    "- Both engines evaluate the exact bytes in `bench/comparison.js`. Directly compared single and independent rows use the exact invocation bytes `__benchmarkSelected(__benchmarkJobs, __benchmarkLane)`; shared mode calls the same selected function with the same jobs/lane arguments. The driver rejects unstable or cross-engine checksum mismatches.",
    "- zig-js is built `ReleaseFast`. Direct and independent contexts explicitly enable precise GC; shared mode enables the shipping no-GIL thread configuration, which implies GC.",
    "- Every measured zig-js context uses the process-wide thread-safe libc allocator, whose reusable infrastructure outlives timed cold contexts; cold mode still times every context-owned allocation and release. JSC uses its internal process allocator.",
    "- Single mode evaluates the workload source, configures the context, and performs ten reduced-size warm-up calls before timing one host evaluation call per sample.",
    "- Independent steady mode uses the same persistent-worker protocol in both runners. Every worker creates, configures, and warms its own thread-affine context before measurement. Each timer includes semaphore dispatch, one invocation per lane, and completion waits; worker/context teardown follows all samples.",
    "- Independent cold mode performs no warm-up. Every timer includes OS-thread spawn, worker-owned context creation, workload-source evaluation and configuration, one invocation, context destruction, and OS-thread join.",
    "- Shared mode prepares one zig-js shared realm and runs two unrecorded full-work shared `Thread` invocations outside the timer, completing one collect/reuse cycle before sampling. Every timed sample then creates and joins the requested JavaScript `Thread`s. Its one-lane row is the scaling baseline.",
    "- Runner process order alternates deterministically for each matrix row instead of always favoring one engine with the cooler first run.",
    `- Full runs reject any row whose median is shorter than ${MIN_FULL_MEDIAN_NS / 1e6} ms; quick harness validation skips that timing floor.`,
    "- Samples run sequentially on an otherwise ordinary host. No CPU pinning, frequency locking, or background-process suppression is attempted.",
    "- Median is the headline; min/max and relative standard deviation expose dispersion, and every raw sample is retained.",
    "",
    "## Reproduce",
    "",
    "Requires macOS because the comparison links the system JavaScriptCore framework.",
    "",
    "```sh",
    "zig build benchmark-comparison",
    "zig build benchmark-comparison -Dbenchmark-comparison-raw-out=docs/.data/benchmark-comparison-YYYY-MM-DD.tsv -Dbenchmark-comparison-markdown-out=docs/.data/benchmark-comparison-YYYY-MM-DD.md",
    "zig build benchmark-comparison -Dbenchmark-comparison-quick=true",
    "```",
  );
  if (rawPath) {
    const name = rawPath.split("/").pop();
    lines.push("", `Raw samples: [\`${name}\`](${name})`);
  }
  return lines.join("\n") + "\n";
}
export function writeRaw(path: string, rows: Row[]): void {
  const lines = ["engine\tmode\tworkload\tlanes\tjobs\tsample\telapsed_ns\tchecksum"].concat(
    rows.map((row) => `${row.engine}\t${row.mode}\t${row.workload}\t${row.lanes}\t${row.jobs}\t${row.sample}\t${row.elapsed_ns}\t${row.checksum}`),
  );
  writeText(path, lines.join("\n") + "\n");
}
function syntheticRows(samples = 1, quick = true, elapsedNs = 60000000): Row[] {
  const rows: Row[] = [],
    allLanes = [1, 2, 4, 8];
  Object.keys(WORKLOADS).forEach((workload, index) => {
    const jobs = quick
        ? Math.max(1, Math.floor(WORKLOADS[workload] / 20))
        : WORKLOADS[workload],
      add = (engine: string, mode: string, lanes: number) => {
        for (let sample = 0; sample < samples; sample += 1)
          rows.push({
            engine,
            mode,
            workload,
            lanes,
            jobs,
            sample,
            elapsed_ns: elapsedNs + sample,
            checksum: (index + 1) * 1000 * lanes,
          });
      };
    add("zig-js", "single", 1);
    add("JavaScriptCore", "single", 1);
    allLanes.forEach((lane) => {
      add("zig-js", "shared", lane);
      for (const engine of ["zig-js", "JavaScriptCore"]) {
        add(engine, "independent_steady", lane);
        add(engine, "independent_cold", lane);
      }
    });
  });
  return rows;
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
  validate(syntheticRows(), 1, [2, 4, 8], true);
  const missing = syntheticRows();
  missing.pop();
  expectFailure(
    () => validate(missing, 1, [2, 4, 8], true),
    "result matrix mismatch",
  );
  const duplicate = syntheticRows();
  duplicate.push({ ...duplicate[0] });
  expectFailure(() => validate(duplicate, 1, [2, 4, 8], true), "has 2 samples");
  const mismatch = syntheticRows(),
    target = mismatch.findIndex((row) => row.engine === "JavaScriptCore");
  mismatch[target] = {
    ...mismatch[target],
    checksum: mismatch[target].checksum + 1,
  };
  expectFailure(
    () => validate(mismatch, 1, [2, 4, 8], true),
    "cross-engine checksum mismatch",
  );
  const short = syntheticRows(1, false);
  short[0] = { ...short[0], elapsed_ns: 1000000 };
  expectFailure(
    () => validate(short, 1, [2, 4, 8], false),
    "median is shorter",
  );
  expectFailure(
    () =>
      ensurePublishable(
        { "zig-js": "deadbeef", "zig-gc": "cafebabe (tracked worktree dirty)" },
        true,
      ),
    "dirty tracked worktree",
  );
  ensurePublishable({ "zig-js": "dirty (tracked worktree dirty)" }, false);
  console.log(
    "OK benchmark comparison self-test: matrix, checksum, timing, and publication gates verified",
  );
}
function main(): void {
  const args = process.argv.slice(2);
  if (args.length === 1 && args[0] === "--self-test") {
    selfTest();
    return;
  }
  requireValue(
    args.length >= 2,
    "usage: benchmark-comparison.ts ZIG_JS_RUNNER JSC_RUNNER [options]",
  );
  const options: any = { samples: 7, lanes: "2,4,8", quick: false };
  for (let index = 2; index < args.length; index += 1) {
    const name = args[index];
    if (name === "--quick") options.quick = true;
    else {
      const value = args[++index];
      if (name === "--samples") options.samples = Number(value);
      else if (name === "--lanes") options.lanes = value;
      else if (name === "--raw-out") options.raw = value;
      else if (name === "--markdown-out") options.markdown = value;
      else throw new Error(`unknown argument: ${name}`);
    }
  }
  const lanes = Array.from(new Set(options.lanes.split(",").filter(Boolean).map(Number))).sort((a, b) => a - b),
    samples = options.quick ? 1 : options.samples;
  requireValue(
    samples > 0 && lanes.length > 0 && lanes.every((value) => value > 1),
    "samples must be positive and lanes must contain values greater than one",
  );
  requireValue(
    Home.fileExists(args[0]) && Home.fileExists(args[1]),
    "benchmark runner does not exist",
  );
  const info = metadata();
  ensurePublishable(info, Boolean(options.raw || options.markdown));
  const rows = collect(args[0], args[1], samples, lanes, options.quick);
  validate(rows, samples, lanes, options.quick);
  const report = render(rows, lanes, options.raw || null, info);
  if (options.raw) writeRaw(options.raw, rows);
  if (options.markdown) writeText(options.markdown, report);
  process.stdout.write(report);
}
if (process.argv[1] === __filename) main();
