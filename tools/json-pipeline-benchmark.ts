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

function runSample(
  binary: string,
  workload: Workload,
  pairSample: number,
  order: number,
): Sample {
  const argv = [
    "env",
    "LC_ALL=C",
    binary,
    "single",
    workload.name,
    String(workload.jobs),
    "1",
  ];
  console.error(`+ ${argv.join(" ")}`);
  const completed = run(argv);
  if (completed.stderr) process.stderr.write(completed.stderr);
  requireValue(
    completed.exitCode === 0,
    completed.stderr || `benchmark exited ${completed.exitCode}`,
  );
  const lines = completed.stdout.split("\n").filter((line) => line.trim());
  requireValue(lines.length === 1, `expected one benchmark row, got ${lines.length}`);
  const row = parseRow(lines[0]);
  requireValue(row.mode === "single", `${workload.name}: mode drift`);
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
    "- Host scheduling and frequency are not controlled, so RSD is retained and the matrix remains diagnostic.",
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
  console.log("OK JSON pipeline benchmark: matrix, checksum, order, timing, and report gates verified");
}

function optionValue(args: string[], name: string): string {
  const index = args.indexOf(name);
  requireValue(index >= 0 && index + 1 < args.length, `missing ${name}`);
  return args[index + 1];
}

function main(): void {
  const args = process.argv.slice(2);
  if (args.length === 1 && args[0] === "--self-test") {
    selfTest();
    return;
  }
  requireValue(
    args.length >= 2,
    "usage: json-pipeline-benchmark.ts ZIG_JS_RUNNER JSC_RUNNER --zig-js-revision REV --zig PATH --zig-gc-repository PATH --zig-regex-repository PATH --raw-out PATH --markdown-out PATH [--samples N]",
  );
  const zigJs = args[0],
    jsc = args[1],
    revision = optionValue(args, "--zig-js-revision"),
    zig = optionValue(args, "--zig"),
    gcRepository = optionValue(args, "--zig-gc-repository"),
    regexRepository = optionValue(args, "--zig-regex-repository"),
    rawOut = optionValue(args, "--raw-out"),
    markdownOut = optionValue(args, "--markdown-out"),
    samplesIndex = args.indexOf("--samples"),
    samples = samplesIndex >= 0 ? Number(args[samplesIndex + 1]) : 7;
  requireValue(fileExists(zigJs) && fileExists(jsc), "benchmark runner does not exist");
  requireValue(/^[0-9a-f]{40}$/.test(revision), "zig-js revision must be a full commit id");
  requireValue(Number.isInteger(samples) && samples > 0, "samples must be a positive integer");
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
  const rows = collect(zigJs, jsc, samples);
  validate(rows, samples);
  const framework = "/System/Library/Frameworks/JavaScriptCore.framework/Resources/Info.plist";
  const artifact = {
    schema_version: 1,
    kind: "focused_json_jsc_comparison",
    metadata: {
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
      jsc_binary_sha256: sha256File(jsc),
      javascriptcore: `system framework ${commandOutput(["plutil", "-extract", "CFBundleVersion", "raw", framework])}`,
      optimize: "ReleaseFast",
      allocator: "real precise collector; GC enabled",
      timed_boundary: "warmed persistent context; one exact invocation",
      samples,
      minimum_median_ns: MINIMUM_MEDIAN_NS,
      sample_order: "fresh-process alternating pairs, offset by workload",
      host_class: "diagnostic",
    },
    workloads: WORKLOADS,
    summary: summarize(rows),
    samples: rows,
  };
  writeText(rawOut, JSON.stringify(artifact, null, 2) + "\n");
  writeText(markdownOut, render(artifact, rawOut));
  process.stdout.write(render(artifact, rawOut));
}

if (process.argv[1] === __filename) main();
