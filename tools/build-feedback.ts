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

declare const __filename: string;

type ScenarioName =
  | "clean_library"
  | "incremental_library"
  | "focused_test_relink"
  | "focused_test_cached"
  | "full_unit_cold_history"
  | "full_unit_warm_history"
  | "tsan_focused";

type Scenario = {
  name: ScenarioName;
  description: string;
  args: string[];
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
  peak_rss_bytes: number;
  build_summary: string[];
  stdout: string;
  stderr: string;
  unit_plan: string | null;
};

type Artifact = {
  schema: "zig-js-build-feedback-v1";
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

function commandOutput(argv: string[], fallback = "unavailable"): string {
  const result = run(argv);
  return result.exitCode === 0 && result.stdout.trim()
    ? result.stdout.trim()
    : fallback;
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
    },
    {
      name: "incremental_library",
      description: "repeat the library build against the immediately preceding isolated caches",
      args: [],
    },
    {
      name: "focused_test_relink",
      description: "build the combined Debug unit artifact and run the executable-memory filter",
      args: ["test", "-Dtest-filter=executable memory"],
    },
    {
      name: "focused_test_cached",
      description: "reuse the linked Debug unit artifact with a different one-test runtime filter",
      args: [
        "test",
        "-Dtest-filter=executable memory profile verifier rejects mismatched policy",
      ],
    },
    {
      name: "full_unit_cold_history",
      description: `run the complete unit suite across ${jobs} shards with an empty timing-history directory`,
      args: ["test-parallel", `-Dunit-jobs=${jobs}`],
    },
    {
      name: "full_unit_warm_history",
      description: `repeat the complete ${jobs}-shard suite using the immediately preceding timing history`,
      args: ["test-parallel", `-Dunit-jobs=${jobs}`],
    },
    {
      name: "tsan_focused",
      description: "build the TSan unit artifact and run the executable-memory filter",
      args: ["test", "-Dtsan=true", "-Dtest-filter=executable memory"],
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
    unitLogDir = `${cacheRoot}/unit-shards`,
    environment = { ZIG_GLOBAL_CACHE_DIR: `${cacheRoot}/global` };
  if (scenario.name === "full_unit_cold_history" || scenario.name === "full_unit_warm_history")
    scenarioArgs.push(`-Dunit-log-dir=${unitLogDir}`);
  const command = [
      zig,
      "build",
      ...scenarioArgs,
      "--cache-dir",
      `${cacheRoot}/local`,
      "--prefix",
      `${cacheRoot}/prefix`,
      "--summary",
      "all",
    ],
    result = run(["/usr/bin/time", "-lp", ...command], {
      timeoutMs: 3 * 60 * 60 * 1000,
      env: environment,
      inheritEnv: true,
    }),
    timing = parseTime(result.stderr);
  return {
    scenario: scenario.name,
    sample,
    command,
    environment,
    exit_code: result.exitCode,
    timed_out: result.timedOut,
    ...timing,
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
  requireValue(artifact.schema === "zig-js-build-feedback-v1", "build-feedback schema drift");
  requireValue(Number.isInteger(artifact.sample_count) && artifact.sample_count > 0, "invalid sample count");
  const names = artifact.scenarios.map((scenario) => scenario.name);
  requireValue(new Set(names).size === names.length, "duplicate scenario name");
  for (const name of names) {
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

function selfTest(): void {
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
      schema: "zig-js-build-feedback-v1",
      complete: false,
      statistic: "median",
      sample_count: options.samples,
      identity: identity(options.zig),
      scenarios: definitions,
      samples: [],
    };
  for (let sample = 0; sample < options.samples; sample += 1) {
    const cacheRoot = temporaryDirectory("zig-js-build-feedback");
    try {
      for (const scenario of definitions) {
        console.log(`[${sample + 1}/${options.samples}] ${scenario.name}`);
        const row = runSample(options.zig, scenario, sample, cacheRoot);
        artifact.samples.push(row);
        console.log(
          `  exit=${row.exit_code} wall=${row.wall_seconds.toFixed(2)}s cpu=${(row.user_seconds + row.system_seconds).toFixed(2)}s rss=${formatBytes(row.peak_rss_bytes)}`,
        );
        if (row.exit_code !== 0 || row.timed_out) {
          writeText(options.rawOut, JSON.stringify(artifact, null, 2) + "\n");
          throw new Error(`${scenario.name} failed; incomplete raw artifact preserved at ${options.rawOut}`);
        }
      }
    } finally {
      removeTemporaryDirectory(cacheRoot);
    }
  }
  artifact.complete = true;
  validate(artifact);
  writeText(options.rawOut, JSON.stringify(artifact, null, 2) + "\n");
  const rawName = options.rawOut.split("/").pop();
  writeText(options.markdownOut, render(artifact, rawName));
  console.log(`build-feedback evidence: ${options.rawOut} ${options.markdownOut}`);
}

if (process.argv[1] === __filename) main();
