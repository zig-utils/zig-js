/** Validate the #134 release compatibility matrix and README removal gate. */
import { fileExists, readText, run, writeText } from "./lib/home";
declare const __filename: string;
type Item = Record<string, any>;
const EXPECTED = [
  "platform_matrix",
  "public_jsc_c_api",
  "objective_c_bridge",
  "inspector",
  "private_abi_profiles",
  "webassembly_mvp",
  "webassembly_profiles",
  "shell_and_reference_hooks",
  "moving_gc",
  "generational_gc",
  "optimizing_jit",
  "readme_generation",
].sort();
const BENCHMARK_START = "<!-- benchmark-comparison:start -->",
  BENCHMARK_END = "<!-- benchmark-comparison:end -->";
const HOME_TOOL =
  process.env.HOME_TOOL ||
  `${process.env.HOME || ""}/Code/Home/lang/zig-out/bin/home-tool`;
function requireValue(condition: boolean, message: string): void {
  if (!condition) throw new Error(`release-compatibility: ${message}`);
}
function checked(argv: string[], phase: string): string {
  const result = run(argv);
  requireValue(
    result.exitCode === 0,
    `${phase}: ${result.stderr.trim() || result.stdout.trim() || result.exitCode}`,
  );
  return result.stdout;
}
function statuses(value: any, result: string[] = []): string[] {
  if (Array.isArray(value)) value.forEach((item) => statuses(item, result));
  else if (value && typeof value === "object") {
    if (typeof value.status === "string") result.push(value.status);
    Object.keys(value).forEach((key) => statuses(value[key], result));
  }
  return result;
}
function replaceBlock(
  source: string,
  start: string,
  end: string,
  body: string,
): string {
  requireValue(
    source.split(start).length === 2 && source.split(end).length === 2,
    `README must contain exactly one ${start} marker pair`,
  );
  return (
    source.split(start)[0] +
    start +
    "\n" +
    body.trim() +
    "\n" +
    end +
    source.split(end)[1]
  );
}
function main(): void {
  const args = process.argv.slice(2);
  let matrixPath = "docs/.data/release-compatibility-matrix.json",
    release = false,
    update = false;
  for (const arg of args) {
    if (arg === "--release") release = true;
    else if (arg === "--update-readme") update = true;
    else if (!arg.startsWith("--")) matrixPath = arg;
    else throw new Error(`unknown argument: ${arg}`);
  }
  const matrix = JSON.parse(readText(matrixPath));
  requireValue(
    matrix.schema_version === 1 &&
      matrix.kind === "zig_js_release_compatibility_matrix",
    "invalid matrix schema or kind",
  );
  requireValue(
    matrix.roadmap_issue === 134 &&
      matrix.release_issue === 147 &&
      matrix.readme_removal_issue === 246,
    "release issue identity drift",
  );
  requireValue(Array.isArray(matrix.gates), "gates must be an array");
  const ids = matrix.gates.map((gate: Item) => gate.id).sort();
  requireValue(
    JSON.stringify(ids) === JSON.stringify(EXPECTED),
    "gate coverage drift",
  );
  const byId: Record<string, Item> = {};
  matrix.gates.forEach((gate: Item) => {
    requireValue(
      ["green", "open"].includes(gate.status) && Number.isInteger(gate.issue),
      `${gate.id}: invalid state`,
    );
    requireValue(
      Array.isArray(gate.evidence) &&
        gate.evidence.length > 0 &&
        new Set(gate.evidence).size === gate.evidence.length,
      `${gate.id}: invalid evidence`,
    );
    gate.evidence.forEach((path: string) =>
      requireValue(fileExists(path), `${gate.id}: missing evidence ${path}`),
    );
    requireValue(
      Array.isArray(gate.blockers) &&
        (gate.status === "green"
          ? gate.blockers.length === 0
          : gate.blockers.length > 0),
      `${gate.id}: blocker/state mismatch`,
    );
    byId[gate.id] = gate;
  });
  checked(
    [HOME_TOOL, "run", "tools/platform-release-matrix.ts"],
    "platform matrix validation",
  );
  checked(
    [HOME_TOOL, "run", "tools/platform-release-matrix.ts", "--self-test"],
    "platform profile fail-closed validation",
  );
  checked(
    [HOME_TOOL, "run", "tools/pr249-terminal-execution.ts", "--check"],
    "PR-249 terminal validation",
  );
  checked(
    [HOME_TOOL, "run", "tools/private-abi.ts", "--consumer", "home"],
    "Home private ABI validation",
  );
  checked(
    [HOME_TOOL, "run", "tools/private-abi.ts", "--consumer", "bun"],
    "Bun private ABI validation",
  );
  for (const id of ["public_jsc_c_api", "objective_c_bridge", "inspector"]) {
    const inventory = JSON.parse(readText(byId[id].evidence[0])),
      unique = Array.from(new Set(statuses(inventory)));
    requireValue(
      JSON.stringify(unique) === '["implemented"]',
      `${id}: inventory is not fully implemented`,
    );
  }
  let privatePending = 0;
  byId.private_abi_profiles.evidence.forEach((path: string) => {
    const inventory = JSON.parse(readText(path));
    privatePending +=
      (inventory.totals &&
        inventory.totals.by_status &&
        inventory.totals.by_status.pending) ||
      0;
  });
  requireValue(
    byId.private_abi_profiles.status === "green"
      ? privatePending === 0
      : privatePending > 0,
    "private ABI status drift",
  );
  const test262Summary = matrix.summaries.test262,
    test262 = JSON.parse(readText(test262Summary.artifact)),
    test262Pass = test262.valid.passing + test262.negative.passing,
    test262Total = test262.valid.total + test262.negative.total;
  requireValue(
    test262Summary.pass === test262Pass &&
      test262Summary.total === test262Total &&
      test262Summary.skipped === test262.skipped,
    "test262 summary drift",
  );
  const wasmSummary = matrix.summaries.webassembly,
    wasm = JSON.parse(readText(wasmSummary.artifact)),
    totals = wasm.combined_totals;
  requireValue(
    wasmSummary.profiles === wasm.profiles.length &&
      wasmSummary.pass === totals.pass &&
      wasmSummary.not_applicable === totals.not_applicable &&
      wasmSummary.fail === 0 &&
      wasmSummary.runner_error === 0,
    "WebAssembly summary drift",
  );
  requireValue(
    wasm.profiles.some(
      (profile: Item) => profile.id === "mvp" && profile.status === "terminal",
    ),
    "MVP WebAssembly gate drift",
  );
  const benchmark = matrix.summaries.benchmark_comparison;
  requireValue(
    fileExists(benchmark.raw) && fileExists(benchmark.report),
    "benchmark evidence missing",
  );
  const samples =
    readText(benchmark.raw).split("\n").filter(Boolean).length - 1;
  requireValue(samples === benchmark.samples, "benchmark sample count drift");
  const scorecard = checked(
    [
      HOME_TOOL,
      "run",
      "tools/benchmark-publication.ts",
      "--current-raw",
      benchmark.raw,
      "--current-report",
      benchmark.report,
      "--scorecard",
    ],
    "benchmark scorecard",
  ).trim();
  const allGreen = matrix.gates.every((gate: Item) => gate.status === "green");
  requireValue(
    matrix.all_green === allGreen &&
      matrix.readme_policy.remove_only_when_all_green === true,
    "all_green/readme policy drift",
  );
  let readme = readText(matrix.readme_policy.path);
  if (update) {
    readme = replaceBlock(readme, BENCHMARK_START, BENCHMARK_END, scorecard);
    writeText(matrix.readme_policy.path, readme);
  }
  requireValue(
    readme.includes(`${BENCHMARK_START}\n${scorecard}\n${BENCHMARK_END}`),
    "README benchmark comparison drift",
  );
  const heading = matrix.readme_policy.not_implemented_heading;
  requireValue(
    !readme.includes(heading) === allGreen,
    "README missing-surface section does not match release state",
  );
  for (const marker of [
    "overview",
    "quickstart",
    "status",
    "use",
    "wasm-performance",
    "gc-compaction",
    "build-test",
  ]) {
    const start = `<!-- release-compatibility:${marker}:start -->`,
      end = `<!-- release-compatibility:${marker}:end -->`;
    requireValue(
      readme.split(start).length === 2 &&
        readme.split(end).length === 2 &&
        readme.indexOf(start) < readme.indexOf(end),
      `README ${marker} generated region drift`,
    );
  }
  requireValue(
    readme.includes(
      `**${test262Pass.toLocaleString("en-US")} / ${test262Total.toLocaleString("en-US")}**`,
    ),
    "README test262 score drift",
  );
  requireValue(
    readme.includes(
      `**${totals.pass.toLocaleString("en-US")} / ${totals.pass.toLocaleString("en-US")} applicable**`,
    ),
    "README WebAssembly score drift",
  );
  console.log(
    `Release compatibility matrix: ${matrix.gates.filter((gate: Item) => gate.status === "green").length}/${matrix.gates.length} gates green; private ABI pending=${privatePending}`,
  );
  requireValue(
    !release || allGreen,
    `release blocked by: ${matrix.gates
      .filter((gate: Item) => gate.status !== "green")
      .map((gate: Item) => gate.id)
      .join(", ")}`,
  );
}
if (process.argv[1] === __filename) main();
