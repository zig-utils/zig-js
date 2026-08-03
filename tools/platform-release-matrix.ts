/** Generate or verify the supported release platform matrix. */
import { readText, run, writeText } from "./lib/home";

declare const __dirname: string;
const ROOT =
  __dirname === "tools"
    ? "."
    : __dirname.slice(0, __dirname.lastIndexOf("/tools"));
const path = (relative: string): string => `${ROOT}/${relative}`;
const WORKFLOW = path(".github/workflows/ci.yml");
const BENCHMARK_REPORT = path(
  "docs/.data/benchmark-comparison-2026-07-29-precise-nursery.md",
);
const BENCHMARK_RAW = path(
  "docs/.data/benchmark-comparison-2026-07-29-precise-nursery.tsv",
);
const OUTPUT_JSON = path("docs/.data/platform-release-matrix-2026-07-28.json");
const OUTPUT_MD = path("docs/platforms.md");

const REQUIRED_TOP_LEVEL_JOBS = [
  "gate",
  "tsan-nogil-corpus",
  "nogil-corpus-functional",
  "nogil-corpus-releasesafe",
  "nightly-threadfuzz-tsan",
  "test262-parallel",
  "docs",
];
const REQUIRED_GATE_MATRIX = [
  "unit (shard 0/4)",
  "unit (shard 1/4)",
  "unit (shard 2/4)",
  "unit (shard 3/4)",
  "threads-gil (shard 0/4)",
  "threads-gil (shard 1/4)",
  "threads-gil (shard 2/4)",
  "threads-gil (shard 3/4)",
  "threads-nogil-witness",
  "threads-reference-audit",
  "threads-execution-inventory-witness",
  "benchmark-comparison-harness",
  "wasm-feature-profiles",
  "wasm-mvp-smoke",
  "wasm-core-2-structural-smoke",
  "wasm-simd-smoke",
  "wasm-threads-smoke",
  "wasm-post-mvp-smoke",
  "wasm-core-3-memory64-gc-smoke",
  "focused-engine-tests",
  "private-abi-boundary",
  "tsan-unit (shard 0/4)",
  "tsan-unit (shard 1/4)",
  "tsan-unit (shard 2/4)",
  "tsan-unit (shard 3/4)",
  "tsan-parallel-js",
  "threadfuzz",
  "tsan-threadfuzz",
  "tsan-threadfuzz-watchdog-cleanup",
  "tsan-threadfuzz-midgc",
  "tsan-threadfuzz-lifecycle",
  "threadfuzz-amplified",
  "threadfuzz-broad",
  "threadfuzz-midgc",
  "threadfuzz-lifecycle",
  "releasesafe-threadfuzz",
  "threadfuzz-verify",
];
const SANITIZER_GATE_MATRIX = [
  "private-abi-boundary",
  "tsan-unit (shard 0/4)",
  "tsan-unit (shard 1/4)",
  "tsan-unit (shard 2/4)",
  "tsan-unit (shard 3/4)",
  "tsan-parallel-js",
  "tsan-threadfuzz",
  "tsan-threadfuzz-watchdog-cleanup",
  "tsan-threadfuzz-midgc",
  "tsan-threadfuzz-lifecycle",
];
const fail = (message: string): never => {
  throw new Error(`platform-release-matrix: ${message}`);
};
const digest = (file: string): string => {
  const result = run(["shasum", "-a", "256", file]);
  if (result.exitCode !== 0)
    fail(`cannot hash ${file}: ${result.stderr.trim()}`);
  return result.stdout.trim().split(/\s+/)[0];
};

function topLevelJobs(workflow: string): string[] {
  const jobs: string[] = [];
  let inJobs = false;
  for (const line of workflow.split("\n")) {
    if (line === "jobs:") {
      inJobs = true;
      continue;
    }
    if (!inJobs) continue;
    if (line && !line.startsWith(" ") && !line.startsWith("#")) break;
    if (
      line.startsWith("  ") &&
      !line.startsWith("    ") &&
      line.trim().endsWith(":") &&
      !line.trim().startsWith("#")
    )
      jobs.push(line.trim().slice(0, -1));
  }
  return jobs;
}

function jobBlock(workflow: string, job: string): string {
  const marker = `  ${job}:\n`,
    start = workflow.indexOf(marker);
  if (start < 0) fail(`missing CI job ${job}`);
  const rest = workflow.slice(start + marker.length),
    match = /^  [A-Za-z0-9_-]+:\n/m.exec(rest);
  return workflow.slice(
    start,
    match ? start + marker.length + match.index : workflow.length,
  );
}
const gateMatrixNames = (gate: string): string[] => {
  const names: string[] = [];
  for (const line of gate.split("\n"))
    if (line.startsWith("          - name: ")) names.push(line.slice(18));
  return names;
};

function parseReportMetadata(report: string): Record<string, string> {
  const metadata: Record<string, string> = {};
  let inEnvironment = false;
  for (const line of report.split("\n")) {
    if (line === "## Environment") {
      inEnvironment = true;
      continue;
    }
    if (inEnvironment && line.startsWith("## ")) break;
    if (!inEnvironment || !line.startsWith("|")) continue;
    const fields = line
      .slice(1, line.endsWith("|") ? -1 : undefined)
      .split("|")
      .map((field) => field.trim());
    if (fields.length === 2 && fields[0] !== "item" && fields[0] !== "---")
      metadata[fields[0]] = fields[1];
  }
  for (const key of [
    "Date",
    "Host",
    "OS",
    "Zig",
    "zig-js",
    "zig-gc",
    "zig-regex",
    "JavaScriptCore",
  ])
    if (!metadata[key]) fail(`benchmark report missing ${key}`);
  return metadata;
}

function rawSampleCount(raw: string): number {
  const lines = raw.split("\n").filter(Boolean);
  if (
    !lines.length ||
    lines[0] !==
      "engine\tmode\tworkload\tlanes\tjobs\tsample\telapsed_ns\tchecksum"
  )
    fail("benchmark raw TSV header drift");
  return lines.length - 1;
}

function validateInputs(): {
  workflow: string;
  matrixNames: string[];
  metadata: Record<string, string>;
  samples: number;
} {
  const workflow = readText(WORKFLOW),
    jobs = topLevelJobs(workflow);
  const duplicates = Array.from(
    new Set(jobs.filter((job) => jobs.indexOf(job) !== jobs.lastIndexOf(job))),
  ).sort();
  if (duplicates.length)
    fail(`duplicate top-level CI jobs: ${JSON.stringify(duplicates)}`);
  const missingJobs = REQUIRED_TOP_LEVEL_JOBS.filter(
    (job) => !jobs.includes(job),
  ).sort();
  if (missingJobs.length)
    fail(`missing top-level CI jobs: ${JSON.stringify(missingJobs)}`);
  for (const job of REQUIRED_TOP_LEVEL_JOBS)
    if (
      job !== "nightly-threadfuzz-tsan" &&
      !jobBlock(workflow, job).includes("runs-on: ubuntu-latest")
    )
      fail(`${job}: release CI runner is not ubuntu-latest`);
  if (
    !workflow.includes("pull_request:") ||
    !workflow.includes("branches: [main]")
  )
    fail("workflow trigger drift");
  if (
    !workflow.includes("schedule:") ||
    !workflow.includes("workflow_dispatch:")
  )
    fail("manual/nightly platform trigger drift");
  const matrixNames = gateMatrixNames(jobBlock(workflow, "gate"));
  const missingMatrix = REQUIRED_GATE_MATRIX.filter(
    (name) => !matrixNames.includes(name),
  ).sort();
  if (missingMatrix.length)
    fail(`missing gate matrix entries: ${JSON.stringify(missingMatrix)}`);
  if (SANITIZER_GATE_MATRIX.some((name) => !matrixNames.includes(name)))
    fail("sanitizer matrix entries are missing");
  if (
    !jobBlock(workflow, "tsan-nogil-corpus").includes(
      'TSAN_OPTIONS="halt_on_error=1"',
    )
  )
    fail("TSan corpus gate no longer halts on first race");
  if (
    !jobBlock(workflow, "nogil-corpus-functional").includes(
      "tools/nogil-corpus-gate.ts",
    )
  )
    fail("Debug no-GIL corpus gate drift");
  if (
    !jobBlock(workflow, "nogil-corpus-releasesafe").includes(
      "tools/nogil-corpus-gate.ts",
    )
  )
    fail("ReleaseSafe no-GIL corpus gate drift");
  const test262 = jobBlock(workflow, "test262-parallel");
  if (!test262.includes("zig build test262-bin -Dtest262-parallel-js=true"))
    fail("test262 parallel platform gate drift");
  if (!test262.includes("parallel mode introduced"))
    fail("test262 parallel baseline comparison drift");
  const metadata = parseReportMetadata(readText(BENCHMARK_REPORT));
  if (!metadata.Host.startsWith("Apple M3 Pro"))
    fail("benchmark host is no longer macOS arm64 release evidence");
  if (!metadata.OS.startsWith("macOS ")) fail("benchmark OS is not macOS");
  const samples = rawSampleCount(readText(BENCHMARK_RAW));
  if (samples !== 1540) fail(`benchmark sample count drift: ${samples}`);
  return { workflow, matrixNames, metadata, samples };
}

function buildMatrix(): any {
  const { matrixNames, metadata, samples } = validateInputs();
  const correctnessNames = matrixNames
    .filter((name) => !SANITIZER_GATE_MATRIX.includes(name))
    .sort();
  return {
    schema_version: 1,
    kind: "zig_js_platform_release_matrix",
    status: "published",
    generated_at: "2026-07-28",
    inputs: {
      ".github/workflows/ci.yml": digest(WORKFLOW),
      "docs/.data/benchmark-comparison-2026-07-29-precise-nursery.md":
        digest(BENCHMARK_REPORT),
      "docs/.data/benchmark-comparison-2026-07-29-precise-nursery.tsv":
        digest(BENCHMARK_RAW),
    },
    triggers: [
      "pull_request",
      "push:main",
      "workflow_dispatch",
      "nightly:schedule",
    ],
    platforms: [
      {
        id: "linux-x86_64-ci",
        os: "linux",
        architecture: "x86_64",
        runner: "ubuntu-latest",
        correctness: {
          status: "gated",
          jobs: correctnessNames,
          evidence: [".github/workflows/ci.yml"],
        },
        sanitizers: {
          status: "gated",
          jobs: SANITIZER_GATE_MATRIX.concat([
            "tsan-nogil-corpus",
            "nightly-threadfuzz-tsan",
          ]).sort(),
          evidence: [".github/workflows/ci.yml"],
        },
        performance: {
          status: "not_claimed",
          reason:
            "No checked release throughput artifact is published for Linux x86_64.",
        },
      },
      {
        id: "macos-arm64-performance",
        os: "macos",
        architecture: "arm64",
        runner: "local-Apple-M3-Pro",
        correctness: {
          status: "not_release_gated",
          reason:
            "macOS correctness exists in host-specific build/test steps but is not the final release CI correctness matrix.",
        },
        sanitizers: {
          status: "not_release_gated",
          reason:
            "macOS sanitizer coverage is host-specific and not the final release CI sanitizer matrix.",
        },
        performance: {
          status: "published",
          host: metadata.Host,
          os: metadata.OS,
          samples,
          evidence: [
            "docs/.data/benchmark-comparison-2026-07-29-precise-nursery.md",
            "docs/.data/benchmark-comparison-2026-07-29-precise-nursery.tsv",
          ],
        },
      },
    ],
    summary: {
      correctness_gated_platforms: 1,
      sanitizer_gated_platforms: 1,
      performance_published_platforms: 1,
      linux_gate_matrix_entries: matrixNames.length,
      benchmark_samples: samples,
    },
    unclaimed: [
      "No Windows release platform is claimed.",
      "No Linux throughput artifact is claimed.",
      "No macOS release CI correctness or sanitizer gate is claimed by this matrix.",
      "No architecture-specific WebAssembly or JIT fast path is claimed beyond the artifacts cited by their own gates.",
    ],
  };
}

function renderMarkdown(matrix: any): string {
  const mac = matrix.platforms[1],
    lines = [
      "# Supported Platform Matrix",
      "",
      "<!-- Generated by tools/platform-release-matrix.ts; do not edit by hand. -->",
      "",
      "This is the release support boundary for correctness, sanitizer, and performance evidence.",
      "It records what is gated or published; it does not imply broader OS or architecture support.",
      "",
      "| platform | correctness | sanitizer | performance | evidence |",
      "| --- | --- | --- | --- | --- |",
      `| Linux x86_64 (\`ubuntu-latest\`) | gated (${matrix.summary.linux_gate_matrix_entries} CI matrix entries) | gated (TSan unit/fuzz/corpus legs) | not claimed | [workflow](../.github/workflows/ci.yml) |`,
      `| macOS arm64 (\`Apple M3 Pro\`) | not release-gated | not release-gated | published (${mac.performance.samples} samples) | [report](.data/benchmark-comparison-2026-07-29-precise-nursery.md) · [raw](.data/benchmark-comparison-2026-07-29-precise-nursery.tsv) |`,
      "",
      "## Unclaimed",
      "",
    ];
  for (const item of matrix.unclaimed) lines.push(`- ${item}`);
  lines.push(
    "",
    "The machine-readable matrix is checked in at [`platform-release-matrix-2026-07-28.json`](.data/platform-release-matrix-2026-07-28.json).",
    "",
  );
  return lines.join("\n");
}

function sorted(value: any): any {
  if (Array.isArray(value)) return value.map(sorted);
  if (value && typeof value === "object") {
    const result: Record<string, any> = {};
    for (const key of Object.keys(value).sort())
      result[key] = sorted(value[key]);
    return result;
  }
  return value;
}

const args = process.argv.slice(2);
let write = false,
  jsonOutput = OUTPUT_JSON,
  markdownOutput = OUTPUT_MD;
for (let index = 0; index < args.length; index += 1) {
  if (args[index] === "--write") write = true;
  else if (args[index] === "--json-output" && args[index + 1])
    jsonOutput = args[++index];
  else if (args[index] === "--markdown-output" && args[index + 1])
    markdownOutput = args[++index];
  else fail(`unknown argument: ${args[index]}`);
}
const matrix = buildMatrix(),
  renderedJson = JSON.stringify(sorted(matrix), null, 2) + "\n",
  renderedMarkdown = renderMarkdown(matrix);
if (write) {
  writeText(jsonOutput, renderedJson);
  writeText(markdownOutput, renderedMarkdown);
  console.log(
    `platform release matrix written: ${jsonOutput}, ${markdownOutput}`,
  );
} else {
  if (readText(jsonOutput) !== renderedJson)
    fail("JSON drift; run tools/platform-release-matrix.ts --write");
  if (readText(markdownOutput) !== renderedMarkdown)
    fail("Markdown drift; run tools/platform-release-matrix.ts --write");
  console.log(
    `platform release matrix: ${matrix.summary.correctness_gated_platforms} correctness, ${matrix.summary.sanitizer_gated_platforms} sanitizer, ${matrix.summary.performance_published_platforms} performance platform`,
  );
}
