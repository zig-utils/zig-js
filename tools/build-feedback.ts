/** Collect reproducible clean, incremental, focused, full, and TSan build feedback evidence. */
import {
  checked,
  fileExists,
  readText,
  removeTemporaryDirectory,
  run,
  temporaryDirectory,
  writeText,
} from "./lib/home";
import {
  competingEvidenceProcesses,
  MINIMUM_PROCESS_CPU_OCCUPANCY,
  processCpuOccupancy,
} from "./evidence-processes";
// Inventory-visible module edge: tools/evidence-processes.ts.

declare const __filename: string;

type ScenarioName =
  | "clean_library"
  | "incremental_library"
  | "focused_engine_relink"
  | "focused_engine_cached"
  | "focused_test_relink"
  | "focused_test_cached"
  | "full_unit_cold_history"
  | "full_unit_warm_history"
  | "focused_engine_tsan"
  | "tsan_focused";

type Scenario = {
  name: ScenarioName;
  description: string;
  args: string[];
  cache_group?: string;
};

type Sample = {
  scenario: ScenarioName;
  sample: number;
  command: string[];
  environment: Record<string, string>;
  exit_code: number | null;
  timed_out: boolean;
  wall_seconds: number;
  user_seconds: number;
  system_seconds: number;
  process_cpu_occupancy?: number;
  peak_rss_bytes: number;
  build_summary: string[];
  stdout: string;
  stderr: string;
  unit_plan: string | null;
};

type Artifact = {
  schema: "zig-js-build-feedback-v1" | "zig-js-build-feedback-v2";
  complete: boolean;
  statistic: "median";
  sample_count: number;
  identity: {
    date_utc: string;
    revision: string;
    zig_version: string;
    zig_executable: string;
    host: string;
    os: string;
    arch: string;
    cpu: string;
    logical_cpu_count: number;
    memory_bytes: number | null;
    power: string;
    zig_gc_revision: string;
    zig_regex_revision: string;
  };
  scenarios: Scenario[];
  samples: Sample[];
};

function requireValue(condition: boolean, message: string): void {
  if (!condition) throw new Error(message);
}

function expectFailure(action: () => void, message: string): void {
  try {
    action();
  } catch (error) {
    requireValue(String(error).includes(message), `unexpected failure: ${String(error)}`);
    return;
  }
  throw new Error(`expected failure containing: ${message}`);
}

function commandOutput(argv: string[], fallback = "unavailable"): string {
  const result = run(argv);
  return result.exitCode === 0 && result.stdout.trim()
    ? result.stdout.trim()
    : fallback;
}

function requireNoCompetingEvidenceProcess(phase: string): void {
  const listing = commandOutput(["ps", "-axo", "pid=,ppid=,command="], ""),
    competitors = competingEvidenceProcesses(listing, process.pid);
  requireValue(
    competitors.length === 0,
    `competing build/test process detected ${phase}:\n${competitors.join("\n")}`,
  );
}

function requireSampleQuality(sample: Sample): void {
  requireValue(
    sample.process_cpu_occupancy !== undefined &&
      Number.isFinite(sample.process_cpu_occupancy) &&
      sample.process_cpu_occupancy >= MINIMUM_PROCESS_CPU_OCCUPANCY,
    `${sample.scenario}: process CPU occupancy ${((sample.process_cpu_occupancy || 0) * 100).toFixed(1)}% is below ${(MINIMUM_PROCESS_CPU_OCCUPANCY * 100).toFixed(0)}%; transient competing work overlapped the scenario`,
  );
}

function metric(stderr: string, pattern: RegExp, label: string): number {
  const match = pattern.exec(stderr);
  requireValue(Boolean(match), `missing ${label} from /usr/bin/time -lp`);
  const value = Number(match![1]);
  requireValue(Number.isFinite(value) && value >= 0, `invalid ${label}: ${match![1]}`);
  return value;
}

export function parseTime(stderr: string): Pick<
  Sample,
  "wall_seconds" | "user_seconds" | "system_seconds" | "peak_rss_bytes"
> {
  return {
    wall_seconds: metric(stderr, /^real\s+([0-9.]+)$/m, "real time"),
    user_seconds: metric(stderr, /^user\s+([0-9.]+)$/m, "user time"),
    system_seconds: metric(stderr, /^sys\s+([0-9.]+)$/m, "system time"),
    peak_rss_bytes: Math.round(
      metric(
        stderr,
        /^\s*([0-9.]+)\s+maximum resident set size$/m,
        "maximum resident set size",
      ),
    ),
  };
}

export function buildSummary(stderr: string): string[] {
  const lines = stderr.split("\n"),
    start = lines.findIndex((line) => line.startsWith("Build Summary:"));
  if (start < 0) return [];
  const summary: string[] = [];
  for (let index = start; index < lines.length; index += 1) {
    if (/^(real|user|sys)\s+[0-9.]+$/.test(lines[index])) break;
    summary.push(lines[index]);
  }
  while (summary.length && summary[summary.length - 1] === "") summary.pop();
  return summary;
}

function median(values: number[]): number {
  requireValue(values.length > 0, "cannot compute an empty median");
  const sorted = values.slice().sort((a, b) => a - b),
    middle = Math.floor(sorted.length / 2);
  return sorted.length % 2
    ? sorted[middle]
    : (sorted[middle - 1] + sorted[middle]) / 2;
}

function scenarios(jobs: number): Scenario[] {
  return [
    {
      name: "clean_library",
      description: "empty isolated local/global caches; build the library and installed headers",
      args: [],
      cache_group: "library",
    },
    {
      name: "incremental_library",
      description: "repeat the library build against the immediately preceding isolated caches",
      args: [],
      cache_group: "library",
    },
    {
      name: "focused_engine_relink",
      description: "build the production-module frontend artifact in an empty isolated cache and run all 12 cases",
      args: ["test-frontend"],
      cache_group: "focused_engine",
    },
    {
      name: "focused_engine_cached",
      description: "reuse the focused-engine artifact with an exact one-case runtime filter",
      args: ["test-frontend", "-Dtest-filter=template interpolation"],
      cache_group: "focused_engine",
    },
    {
      name: "focused_test_relink",
      description: "build the combined Debug unit artifact in an empty isolated cache and run one exact filter",
      args: ["test", "-Dtest-filter=executable memory target matrix separates mapping from tier support"],
      cache_group: "combined_unit",
    },
    {
      name: "focused_test_cached",
      description: "reuse the linked Debug unit artifact with a different one-test runtime filter",
      args: [
        "test",
        "-Dtest-filter=executable memory profile verifier rejects mismatched policy",
      ],
      cache_group: "combined_unit",
    },
    {
      name: "full_unit_cold_history",
      description: `run the complete unit suite across ${jobs} shards with an empty timing-history directory`,
      args: ["test-parallel", `-Dunit-jobs=${jobs}`],
      cache_group: "combined_unit",
    },
    {
      name: "full_unit_warm_history",
      description: `repeat the complete ${jobs}-shard suite using the immediately preceding timing history`,
      args: ["test-parallel", `-Dunit-jobs=${jobs}`],
      cache_group: "combined_unit",
    },
    {
      name: "focused_engine_tsan",
      description: "build the focused production-module TSan artifact in an empty isolated cache and run one case",
      args: ["test-frontend", "-Dtsan=true", "-Dtest-filter=template interpolation"],
      cache_group: "focused_engine_tsan",
    },
    {
      name: "tsan_focused",
      description: "build the combined TSan unit artifact in an empty isolated cache and run one exact filter",
      args: ["test", "-Dtsan=true", "-Dtest-filter=executable memory profile verifier rejects mismatched policy"],
      cache_group: "combined_tsan",
    },
  ];
}

function gitRevision(path: string): string {
  requireValue(
    checked(["git", "-C", path, "status", "--short", "--untracked-files=no"], `inspect ${path}`).trim() === "",
    `tracked worktree is dirty: ${path}`,
  );
  return checked(["git", "-C", path, "rev-parse", "HEAD"], `revision ${path}`).trim();
}

function identity(zig: string): Artifact["identity"] {
  const memory = Number(commandOutput(["sysctl", "-n", "hw.memsize"], ""));
  return {
    date_utc: new Date().toISOString(),
    revision: gitRevision("."),
    zig_version: checked([zig, "version"], "Zig version").trim(),
    zig_executable: commandOutput(["realpath", zig], zig),
    host: commandOutput(["hostname"]),
    os: commandOutput(["uname", "-a"]),
    arch: commandOutput(["uname", "-m"]),
    cpu: commandOutput(["sysctl", "-n", "machdep.cpu.brand_string"]),
    logical_cpu_count: Number(commandOutput(["sysctl", "-n", "hw.logicalcpu"], "0")),
    memory_bytes: Number.isFinite(memory) && memory > 0 ? memory : null,
    power: commandOutput(["pmset", "-g", "batt"]),
    zig_gc_revision: gitRevision("../zig-gc"),
    zig_regex_revision: gitRevision("../zig-regex"),
  };
}

function runSample(
  zig: string,
  scenario: Scenario,
  sample: number,
  cacheRoot: string,
): Sample {
  const scenarioArgs = scenario.args.slice(),
    cacheGroup = scenario.cache_group || "shared",
    groupRoot = `${cacheRoot}/${cacheGroup}`,
    unitLogDir = `${groupRoot}/unit-shards`,
    environment = { ZIG_GLOBAL_CACHE_DIR: `${groupRoot}/global` };
  if (scenario.name === "full_unit_cold_history" || scenario.name === "full_unit_warm_history")
    scenarioArgs.push(`-Dunit-log-dir=${unitLogDir}`);
  const command = [
      zig,
      "build",
      ...scenarioArgs,
      "--cache-dir",
      `${groupRoot}/local`,
      "--prefix",
      `${groupRoot}/prefix`,
      "--summary",
      "all",
    ],
    result = run(["/usr/bin/time", "-lp", ...command], {
      timeoutMs: 3 * 60 * 60 * 1000,
      env: environment,
      inheritEnv: true,
    }),
    timing = parseTime(result.stderr),
    process_cpu_occupancy = processCpuOccupancy(
      timing.wall_seconds,
      timing.user_seconds,
      timing.system_seconds,
    );
  return {
    scenario: scenario.name,
    sample,
    command,
    environment,
    exit_code: result.exitCode,
    timed_out: result.timedOut,
    ...timing,
    process_cpu_occupancy,
    build_summary: buildSummary(result.stderr),
    stdout: result.stdout,
    stderr: result.stderr,
    unit_plan:
      scenario.name.startsWith("full_unit_") && fileExists(`${unitLogDir}/plan.tsv`)
        ? readText(`${unitLogDir}/plan.tsv`)
        : null,
  };
}

export function validate(artifact: Artifact): void {
  requireValue(
    artifact.schema === "zig-js-build-feedback-v1" || artifact.schema === "zig-js-build-feedback-v2",
    "build-feedback schema drift",
  );
  requireValue(Number.isInteger(artifact.sample_count) && artifact.sample_count > 0, "invalid sample count");
  const names = artifact.scenarios.map((scenario) => scenario.name);
  requireValue(new Set(names).size === names.length, "duplicate scenario name");
  if (artifact.schema === "zig-js-build-feedback-v2") {
    requireValue(
      JSON.stringify(names) === JSON.stringify([
        "clean_library",
        "incremental_library",
        "focused_engine_relink",
        "focused_engine_cached",
        "focused_test_relink",
        "focused_test_cached",
        "full_unit_cold_history",
        "full_unit_warm_history",
        "focused_engine_tsan",
        "tsan_focused",
      ]),
      "V2 scenario inventory drift",
    );
    requireValue(
      JSON.stringify(artifact.scenarios.map((scenario) => scenario.cache_group)) === JSON.stringify([
        "library",
        "library",
        "focused_engine",
        "focused_engine",
        "combined_unit",
        "combined_unit",
        "combined_unit",
        "combined_unit",
        "focused_engine_tsan",
        "combined_tsan",
      ]),
      "V2 cache-group boundary drift",
    );
  }
  for (const name of names) {
    const scenario = artifact.scenarios.find((entry) => entry.name === name)!;
    const rows = artifact.samples.filter((sample) => sample.scenario === name);
    requireValue(rows.length === artifact.sample_count, `${name}: incomplete sample inventory`);
    rows.forEach((row, index) => {
      requireValue(row.sample === index, `${name}: sample index drift`);
      requireValue(row.exit_code === 0 && !row.timed_out, `${name}: command failed or timed out`);
      requireValue(
        [row.wall_seconds, row.user_seconds, row.system_seconds, row.peak_rss_bytes].every(
          (value) => Number.isFinite(value) && value >= 0,
        ),
        `${name}: invalid resource measurement`,
      );
      if (name.startsWith("full_unit_"))
        requireValue(Boolean(row.unit_plan?.startsWith("shard\testimated_ms\tname\n")), `${name}: missing unit plan`);
      if (artifact.schema === "zig-js-build-feedback-v2") {
        requireSampleQuality(row);
        const group = scenario.cache_group!;
        requireValue(row.environment.ZIG_GLOBAL_CACHE_DIR.endsWith(`/${group}/global`), `${name}: global cache boundary drift`);
        const cacheIndex = row.command.indexOf("--cache-dir"), prefixIndex = row.command.indexOf("--prefix");
        requireValue(
          cacheIndex >= 0 && row.command[cacheIndex + 1]?.endsWith(`/${group}/local`) &&
            prefixIndex >= 0 && row.command[prefixIndex + 1]?.endsWith(`/${group}/prefix`),
          `${name}: local cache or prefix boundary drift`,
        );
        const output = `${row.stdout}\n${row.stderr}`;
        if (name === "focused_engine_relink")
          requireValue(output.includes("focused engine frontend: 12 cases passed"), `${name}: exact denominator drift`);
        else if (name === "focused_engine_cached" || name === "focused_engine_tsan")
          requireValue(output.includes("focused engine frontend: 1 case passed"), `${name}: exact denominator drift`);
        else if (name === "focused_test_relink" || name === "focused_test_cached" || name === "tsan_focused") {
          const match = /matched 1 of ([1-9][0-9]*) tests/.exec(output);
          requireValue(Boolean(match), `${name}: exact nonzero denominator drift`);
          requireValue(
            output.includes("summary: 1 passed; 0 skipped; 0 failed; 0 leaked;"),
            `${name}: exact result drift`,
          );
        }
      }
    });
  }
  requireValue(artifact.complete, "build-feedback artifact is incomplete");
}

function formatSeconds(value: number): string {
  return `${value.toFixed(2)} s`;
}

function formatBytes(value: number): string {
  return `${(value / 1024 / 1024).toFixed(1)} MiB`;
}

export function render(artifact: Artifact, rawName: string): string {
  validate(artifact);
  const lines = [
    `# Build feedback — ${artifact.identity.date_utc.slice(0, 10)}`,
    "",
    `Exact clean-source measurements for [#494](https://github.com/zig-utils/zig-js/issues/494) at zig-js \`${artifact.identity.revision}\`.`,
    "",
    `- host: ${artifact.identity.cpu}; ${artifact.identity.arch}; ${artifact.identity.logical_cpu_count} logical CPUs; ${artifact.identity.memory_bytes === null ? "memory unavailable" : formatBytes(artifact.identity.memory_bytes)}`,
    `- OS: ${artifact.identity.os}`,
    `- Zig: \`${artifact.identity.zig_version}\` at \`${artifact.identity.zig_executable}\``,
    `- zig-gc: \`${artifact.identity.zig_gc_revision}\`; zig-regex: \`${artifact.identity.zig_regex_revision}\``,
    `- power: ${artifact.identity.power.replace(/\n/g, " · ")}`,
    `- sampling: ${artifact.sample_count} sequential sample${artifact.sample_count === 1 ? "" : "s"} per phase; median; no outlier removal; isolated local/global caches per sample sequence`,
    ...(artifact.schema === "zig-js-build-feedback-v2"
      ? [
        "- cache boundary: library, focused-engine, combined-unit, focused-engine TSan, and combined-unit TSan groups are isolated; only adjacent phases with the same named group reuse cache state",
        `- process quality: every complete build used at least ${(MINIMUM_PROCESS_CPU_OCCUPANCY * 100).toFixed(0)}% CPU occupancy; before/after snapshots reject persistent competing build and test jobs`,
      ]
      : []),
    "",
    "| phase | scope | median wall | wall range | median CPU (user + system) | median peak RSS |",
    "| --- | --- | ---: | ---: | ---: | ---: |",
  ];
  artifact.scenarios.forEach((scenario) => {
    const rows = artifact.samples.filter((sample) => sample.scenario === scenario.name),
      walls = rows.map((row) => row.wall_seconds),
      cpus = rows.map((row) => row.user_seconds + row.system_seconds),
      rss = rows.map((row) => row.peak_rss_bytes);
    lines.push(
      `| \`${scenario.name}\` | ${scenario.description} | ${formatSeconds(median(walls))} | ${formatSeconds(Math.min(...walls))}–${formatSeconds(Math.max(...walls))} | ${formatSeconds(median(cpus))} | ${formatBytes(median(rss))} |`,
    );
  });
  lines.push(
    "",
    "Wall time covers the complete listed `zig build` invocation. User/system CPU and peak RSS are `/usr/bin/time -lp` observations for that build process and its children; they are not compiler-internal phase counters. Every raw command, exit status, build summary, stdout, stderr, and sample is retained.",
    "",
    `Raw evidence: [${rawName}](${rawName}).`,
    "",
  );
  return lines.join("\n");
}

export function selfTest(): void {
  const parsed = parseTime(
    "real 2.50\nuser 3.00\nsys 1.25\n             104857600  maximum resident set size\n",
  );
  requireValue(
    parsed.wall_seconds === 2.5 &&
      parsed.user_seconds === 3 &&
      parsed.system_seconds === 1.25 &&
      parsed.peak_rss_bytes === 104857600,
    "/usr/bin/time parser failed",
  );
  requireValue(
    JSON.stringify(buildSummary("Build Summary: 2/2 steps succeeded\ninstall success\nreal 1.0\n")) ===
      '["Build Summary: 2/2 steps succeeded","install success"]',
    "build summary parser failed",
  );
  const scenario: Scenario = {
      name: "clean_library",
      description: "fixture",
      args: [],
    },
    artifact: Artifact = {
      schema: "zig-js-build-feedback-v1",
      complete: true,
      statistic: "median",
      sample_count: 1,
      identity: {
        date_utc: "2026-08-08T00:00:00.000Z",
        revision: "a".repeat(40),
        zig_version: "0.17.0-dev",
        zig_executable: "/zig",
        host: "fixture",
        os: "fixture",
        arch: "aarch64",
        cpu: "fixture",
        logical_cpu_count: 10,
        memory_bytes: 16 * 1024 * 1024,
        power: "AC Power",
        zig_gc_revision: "b".repeat(40),
        zig_regex_revision: "c".repeat(40),
      },
      scenarios: [scenario],
      samples: [
        {
          scenario: "clean_library",
          sample: 0,
          command: ["zig", "build"],
          environment: { ZIG_GLOBAL_CACHE_DIR: "/tmp/global" },
          exit_code: 0,
          timed_out: false,
          ...parsed,
          build_summary: ["Build Summary: 2/2 steps succeeded"],
          stdout: "",
          stderr: "",
          unit_plan: null,
        },
      ],
  };
  validate(artifact);
  requireValue(render(artifact, "raw.json").includes("2.50 s"), "report renderer failed");
  if (fileExists("docs/.data/build-feedback-2026-08-09.json"))
    validate(JSON.parse(readText("docs/.data/build-feedback-2026-08-09.json")) as Artifact);

  const v2Scenarios = scenarios(2),
    v2Samples = v2Scenarios.map((entry): Sample => {
      const group = entry.cache_group!, output = entry.name === "focused_engine_relink"
        ? "focused engine frontend: 12 cases passed\n"
        : entry.name === "focused_engine_cached" || entry.name === "focused_engine_tsan"
        ? "focused engine frontend: 1 case passed\n"
        : entry.name === "focused_test_relink" || entry.name === "focused_test_cached" || entry.name === "tsan_focused"
        ? "zig-js unit tests: filter 'fixture' matched 1 of 1731 tests; shard 0/1 running 1\nzig-js unit tests: shard 0/1 summary: 1 passed; 0 skipped; 0 failed; 0 leaked; 0 ms\n"
        : "";
      return {
        scenario: entry.name,
        sample: 0,
        command: ["zig", "build", ...entry.args, "--cache-dir", `/tmp/${group}/local`, "--prefix", `/tmp/${group}/prefix`],
        environment: { ZIG_GLOBAL_CACHE_DIR: `/tmp/${group}/global` },
        exit_code: 0,
        timed_out: false,
        ...parsed,
        process_cpu_occupancy: 1,
        build_summary: ["Build Summary: 2/2 steps succeeded"],
        stdout: output,
        stderr: "",
        unit_plan: entry.name.startsWith("full_unit_") ? "shard\testimated_ms\tname\n0\t1\tfixture\n" : null,
      };
    }),
    v2Artifact: Artifact = {
      ...artifact,
      schema: "zig-js-build-feedback-v2",
      scenarios: v2Scenarios,
      samples: v2Samples,
    };
  validate(v2Artifact);
  const brokenGroup = JSON.parse(JSON.stringify(v2Artifact)) as Artifact;
  brokenGroup.scenarios[2].cache_group = "combined_unit";
  expectFailure(() => validate(brokenGroup), "cache-group boundary drift");
  const brokenDenominator = JSON.parse(JSON.stringify(v2Artifact)) as Artifact;
  brokenDenominator.samples.find((row) => row.scenario === "focused_engine_cached")!.stdout =
    "focused engine frontend: 0 cases passed\n";
  expectFailure(() => validate(brokenDenominator), "exact denominator drift");
  const processFixture = [
    "100 1 /usr/bin/outer",
    "110 100 /cache/maker build build-feedback",
    "120 110 /home/home-tool run tools/build-feedback.ts",
    "121 120 /toolchain/zig build test-frontend",
    "200 1 /toolchain/zig test -Mroot=other.zig",
    "210 1 /cache/maker build test",
    "220 1 /private/tmp/home-url-final",
    "230 1 /tmp/home-ts-checker/o/test --listen=-",
    "240 1 /repo/zig-out/bin/test262 --diag test/language",
    "250 1 /tmp/unrelated-test",
  ].join("\n");
  requireValue(
    JSON.stringify(competingEvidenceProcesses(processFixture, 120)) === JSON.stringify([
      "200 /toolchain/zig test -Mroot=other.zig",
      "210 /cache/maker build test",
      "220 /private/tmp/home-url-final",
      "230 /tmp/home-ts-checker/o/test --listen=-",
      "240 /repo/zig-out/bin/test262 --diag test/language",
    ]),
    "competing evidence-process classification drift",
  );
  requireValue(processCpuOccupancy(2.5, 3, 1.25) === 1, "process CPU occupancy clamp drift");
  const lowOccupancy = { ...v2Samples[0], process_cpu_occupancy: 0.59 };
  expectFailure(() => requireSampleQuality(lowOccupancy), "transient competing work overlapped the scenario");
  console.log("build-feedback self-test: ok");
}

function main(): void {
  const args = process.argv.slice(2);
  if (args.length === 1 && args[0] === "--self-test") return selfTest();
  const options: any = { samples: 3, jobs: 10 };
  for (let index = 0; index < args.length; index += 2) {
    const name = args[index],
      value = args[index + 1];
    requireValue(Boolean(value), `missing value for ${name}`);
    if (name === "--zig") options.zig = value;
    else if (name === "--samples") options.samples = Number(value);
    else if (name === "--jobs") options.jobs = Number(value);
    else if (name === "--raw-out") options.rawOut = value;
    else if (name === "--markdown-out") options.markdownOut = value;
    else throw new Error(`unknown argument: ${name}`);
  }
  requireValue(options.zig && options.rawOut && options.markdownOut, "--zig, --raw-out, and --markdown-out are required");
  requireValue(options.rawOut !== options.markdownOut, "raw and Markdown outputs must differ");
  requireValue(Number.isInteger(options.samples) && options.samples > 0, "--samples must be positive");
  requireValue(Number.isInteger(options.jobs) && options.jobs > 0, "--jobs must be positive");

  const definitions = scenarios(options.jobs),
    artifact: Artifact = {
      schema: "zig-js-build-feedback-v2",
      complete: false,
      statistic: "median",
      sample_count: options.samples,
      identity: identity(options.zig),
      scenarios: definitions,
      samples: [],
    };
  try {
    for (let sample = 0; sample < options.samples; sample += 1) {
      const cacheRoot = temporaryDirectory("zig-js-build-feedback");
      try {
        for (let scenarioIndex = 0; scenarioIndex < definitions.length; scenarioIndex += 1) {
          const scenario = definitions[scenarioIndex];
          requireNoCompetingEvidenceProcess("before scenario");
          console.log(`[${sample + 1}/${options.samples}] ${scenario.name}`);
          const row = runSample(options.zig, scenario, sample, cacheRoot);
          artifact.samples.push(row);
          requireNoCompetingEvidenceProcess("after scenario");
          requireSampleQuality(row);
          console.log(
            `  exit=${row.exit_code} wall=${row.wall_seconds.toFixed(2)}s cpu=${(row.user_seconds + row.system_seconds).toFixed(2)}s rss=${formatBytes(row.peak_rss_bytes)}`,
          );
          if (row.exit_code !== 0 || row.timed_out)
            throw new Error(`${scenario.name} failed or timed out`);
          const next = definitions[scenarioIndex + 1];
          if (!next || next.cache_group !== scenario.cache_group)
            removeTemporaryDirectory(`${cacheRoot}/${scenario.cache_group}`);
        }
      } finally {
        removeTemporaryDirectory(cacheRoot);
      }
    }
  } catch (error) {
    writeText(options.rawOut, JSON.stringify(artifact, null, 2) + "\n");
    throw new Error(`${String(error)}; incomplete raw artifact preserved at ${options.rawOut}`);
  }
  artifact.complete = true;
  try {
    validate(artifact);
  } catch (error) {
    artifact.complete = false;
    writeText(options.rawOut, JSON.stringify(artifact, null, 2) + "\n");
    throw error;
  }
  writeText(options.rawOut, JSON.stringify(artifact, null, 2) + "\n");
  const rawName = options.rawOut.split("/").pop();
  writeText(options.markdownOut, render(artifact, rawName));
  console.log(`build-feedback evidence: ${options.rawOut} ${options.markdownOut}`);
}

if (process.argv[1] === __filename) main();
