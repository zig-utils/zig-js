/** Validate the optimizing-tier release contract and its checked evidence. */
import { readText } from "./lib/home";

declare const __dirname: string;
const ROOT = __dirname === "tools" ? "." : __dirname.slice(0, __dirname.lastIndexOf("/tools"));
const join = (left: string, right: string): string => `${left.replace(/\/$/, "")}/${right}`;
const DEFAULT_INVENTORY = join(ROOT, "docs/.data/optimizer-release-inventory.json");
const REQUIRED_SUITES = ["fallback-build-linux-x86_64", "fallback-build-macos-x86_64", "focused-jit-debug", "focused-jit-tsan", "seeded-differential-debug", "seeded-differential-tsan", "full-unit-debug", "pr249-terminal-release-safe"].sort();
const requireValue = (condition: boolean, message: string): void => { if (!condition) throw new Error(message); };
const relativePath = (value: any, field: string): string => {
  requireValue(typeof value === "string" && !!value, `${field} must be a non-empty path`);
  requireValue(!value.startsWith("/") && !value.split("/").includes(".."), `${field} must stay inside the repository`);
  const resolved = join(ROOT, value);
  try { readText(resolved); } catch (_) { throw new Error(`${field} does not exist: ${value}`); }
  return resolved;
};

function validateInventory(file: string): any {
  const data = JSON.parse(readText(file));
  requireValue(data.schema_version === 1, "schema_version must be 1");
  requireValue(typeof data.implementation_commit === "string" && /^[0-9a-f]{40}$/.test(data.implementation_commit), "implementation_commit must be a full lowercase Git commit");
  const contract = data.contract;
  requireValue(contract && typeof contract === "object" && !Array.isArray(contract), "contract must be an object");
  requireValue(Array.isArray(contract.supported) && contract.supported.length === 1, "the declared optimizer matrix must contain exactly one supported backend");
  const backend = contract.supported[0];
  requireValue(backend && typeof backend === "object", "supported backend must be an object");
  requireValue([backend.os, backend.architecture, backend.backend, backend.status].join(":") === "macos:aarch64:macos_aarch64:gated", "the sole supported optimizer backend must be gated macOS AArch64");
  requireValue(String(backend.executable_memory).includes("MAP_JIT"), "supported backend must state its executable-memory contract");
  requireValue(Array.isArray(contract.fallback) && contract.fallback.length >= 4, "fallback matrix must cover named unsupported host families");
  const pairs = contract.fallback.map((entry: any) => `${entry.os}:${entry.architecture}`);
  for (const pair of ["macos:x86_64", "linux:aarch64", "linux:x86_64"]) requireValue(pairs.includes(pair), `missing explicit fallback matrix entry ${pair}`);
  for (const entry of contract.fallback) {
    requireValue(entry && typeof entry === "object", "fallback entries must be objects");
    requireValue(String(entry.behavior).includes("baseline or bytecode"), "every unsupported host must name baseline/bytecode fallback");
    requireValue(String(entry.behavior).includes("zero"), "every unsupported host must reject fake optimizer publication counts");
  }
  const correctness = data.correctness;
  requireValue(correctness && typeof correctness === "object", "correctness must be an object");
  requireValue(correctness.seed === "0x434f4445585f3433", "seeded differential seed drifted");
  requireValue(correctness.seeded_cases_per_mode === 12, "seeded differential must retain twelve cases per execution mode");
  requireValue(Array.isArray(correctness.surfaces) && correctness.surfaces.length >= 8, "correctness surface inventory is incomplete");
  requireValue(Array.isArray(correctness.source_anchors) && correctness.source_anchors.length > 0, "source_anchors must be non-empty");
  correctness.source_anchors.forEach((anchor: any, index: number) => {
    requireValue(anchor && typeof anchor === "object", `source_anchors[${index}] must be an object`);
    const source = relativePath(anchor.path, `source_anchors[${index}].path`);
    requireValue(typeof anchor.text === "string" && readText(source).includes(anchor.text), `source anchor missing from ${anchor.path}: ${JSON.stringify(anchor.text)}`);
  });
  requireValue(Array.isArray(correctness.suites), "correctness.suites must be an array");
  const byId: Record<string, any> = {};
  for (const suite of correctness.suites) if (suite && typeof suite.id === "string") byId[suite.id] = suite;
  const suiteIds = Object.keys(byId).sort();
  requireValue(JSON.stringify(suiteIds) === JSON.stringify(REQUIRED_SUITES), `suite inventory drift: expected ${JSON.stringify(REQUIRED_SUITES)}, found ${JSON.stringify(suiteIds)}`);
  for (const id of suiteIds) {
    const suite = byId[id];
    requireValue(suite.failed === 0, `${id} records failures`);
    if (Object.prototype.hasOwnProperty.call(suite, "leaked")) requireValue(suite.leaked === 0, `${id} records leaks`);
    requireValue(typeof suite.command === "string" && !!suite.command, `${id} must carry a reproduction command`);
  }
  requireValue(byId["focused-jit-debug"].passed === byId["focused-jit-tsan"].passed, "normal and TSan focused gates must cover the same test count");
  requireValue(byId["seeded-differential-debug"].seed_executions === 24, "normal seeded gate must execute both twelve-case modes");
  requireValue(byId["seeded-differential-tsan"].seed_executions === 24, "TSan seeded gate must execute both twelve-case modes");
  const terminal = JSON.parse(readText(join(ROOT, "docs/.data/pr249-terminal-execution.json"))).summary || {}, terminalSuite = byId["pr249-terminal-release-safe"];
  for (const pair of [["executables", "executable"], ["promoted", "promoted"], ["terminal_disposition", "terminal_disposition"]]) requireValue(terminalSuite[pair[0]] === terminal[pair[1]], `PR-249 ${pair[1]} count drift`);
  requireValue(terminal.blocked === 0, "optimizer release evidence cannot retain blocked PR-249 cases");
  requireValue(data.sanitizers && typeof data.sanitizers === "object", "sanitizers must be an object");
  requireValue((data.sanitizers.engine || []).includes("ThreadSanitizer"), "TSan evidence is required");
  requireValue((data.sanitizers.not_claimed || []).includes("AddressSanitizer for Zig engine code"), "unavailable Zig ASan must not be claimed");
  const performance = data.performance;
  requireValue(performance && typeof performance === "object", "performance must be an object");
  const report = relativePath(performance.report, "performance.report"), raw = relativePath(performance.raw_samples, "performance.raw_samples");
  requireValue(typeof performance.measured_zig_js_commit === "string" && /^[0-9a-f]{40}$/.test(performance.measured_zig_js_commit), "performance measured_zig_js_commit must be a full Git commit");
  const reportText = readText(report);
  requireValue(reportText.includes(performance.measured_zig_js_commit), "performance report does not name its measured zig-js commit");
  requireValue(reportText.includes(String(performance.raw_samples).split("/").pop()), "performance report does not link its raw sample file");
  const rawLines = readText(raw).split("\n");
  requireValue(rawLines.length > 2 && rawLines[0].startsWith("engine\tmode\tworkload\t"), "performance raw sample file is empty or malformed");
  requireValue(performance.publication_gate && performance.publication_gate.failed === 0, "benchmark publication gate must be recorded green");
  return data;
}

let inventory = DEFAULT_INVENTORY;
const args = process.argv.slice(2);
for (let index = 0; index < args.length; index += 1) {
  if (args[index] === "--inventory" && args[index + 1]) inventory = args[++index];
  else throw new Error(`unknown argument: ${args[index]}`);
}
const data = validateInventory(inventory), correctness = data.correctness;
console.log(`optimizer release inventory: PASS (1 supported backend, ${correctness.surfaces.length} surfaces, ${correctness.suites.length} suites)`);
