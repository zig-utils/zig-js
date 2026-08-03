/** Validate the versioned WebAssembly feature/profile and evidence registry. */
import { fileExists, readText } from "./lib/home";
declare const __filename: string;
type Item = Record<string, any>;

const SHA = /^[0-9a-f]{40}$/;
function requireValue(condition: boolean, message: string): void {
  if (!condition) throw new Error(`wasm-feature-profiles: ${message}`);
}
function load(path: string): Item {
  requireValue(fileExists(path), `missing evidence ${path}`);
  return JSON.parse(readText(path));
}
function recount(commands: Item[]): Item {
  const result: Item = { pass: 0, fail: 0, not_applicable: 0, runner_error: 0 };
  for (const command of commands) {
    requireValue(
      Object.hasOwn(result, command.status),
      `unknown command status ${command.status}`,
    );
    result[command.status] += 1;
    requireValue(
      typeof command.mode === "string",
      "command missing execution mode",
    );
    if (command.status === "not_applicable")
      requireValue(
        Boolean(command.detail),
        "unexplained not-applicable command",
      );
  }
  result.total = commands.length;
  return result;
}
function same(left: any, right: any): boolean {
  if (left === right) return true;
  if (Array.isArray(left) || Array.isArray(right))
    return (
      Array.isArray(left) &&
      Array.isArray(right) &&
      left.length === right.length &&
      left.every((value, index) => same(value, right[index]))
    );
  if (left && right && typeof left === "object" && typeof right === "object") {
    const leftKeys = Object.keys(left).sort(),
      rightKeys = Object.keys(right).sort();
    return (
      same(leftKeys, rightKeys) &&
      leftKeys.every((key) => same(left[key], right[key]))
    );
  }
  return false;
}
function validateInventory(path: string, matrixProfile: Item): void {
  const inventory = load(path);
  requireValue(inventory.schema_version === 2, `${path}: unsupported schema`);
  requireValue(
    inventory.profile === matrixProfile.id ||
      (matrixProfile.id === "mvp" && inventory.profile == null),
    `${path}: profile drift`,
  );
  requireValue(
    SHA.test(inventory.engine_commit),
    `${path}: invalid engine commit`,
  );
  requireValue(
    same(inventory.features || [], matrixProfile.features),
    `${path}: feature drift`,
  );
  requireValue(
    inventory.spec.repository === matrixProfile.spec.repository,
    `${path}: repository drift`,
  );
  requireValue(
    inventory.spec.commit === matrixProfile.spec.commit,
    `${path}: source pin drift`,
  );
  requireValue(
    inventory.converter.repository === matrixProfile.converter.repository,
    `${path}: converter repository drift`,
  );
  requireValue(
    inventory.converter.commit === matrixProfile.converter.commit,
    `${path}: converter pin drift`,
  );
  requireValue(
    inventory.converter.version === matrixProfile.converter.version,
    `${path}: converter version drift`,
  );
  const files: Item[] = inventory.files;
  requireValue(
    Array.isArray(files) && files.length === inventory.spec.files_scored,
    `${path}: scored-file drift`,
  );
  requireValue(
    new Set(files.map((entry) => entry.path)).size === files.length,
    `${path}: duplicate file`,
  );
  const allCommands: Item[] = [];
  for (const entry of files) {
    requireValue(
      Array.isArray(entry.commands),
      `${path}: missing commands for ${entry.path}`,
    );
    const actual = recount(entry.commands);
    requireValue(
      same(actual, entry.counts),
      `${path}: per-file count drift in ${entry.path}`,
    );
    allCommands.push(...entry.commands);
  }
  const totals = recount(allCommands);
  requireValue(
    same(totals, inventory.totals),
    `${path}: aggregate count drift`,
  );
  requireValue(
    same(totals, matrixProfile.totals),
    `${path}: matrix total drift`,
  );
  requireValue(
    totals.fail === 0 && totals.runner_error === 0,
    `${path}: terminal evidence is not green`,
  );
  if (matrixProfile.status === "shadow") {
    requireValue(
      inventory.accepted_score === false,
      `${path}: shadow must not be accepted score`,
    );
    requireValue(
      inventory.observation?.commit === inventory.spec.commit,
      `${path}: shadow provenance drift`,
    );
  } else
    requireValue(
      matrixProfile.status === "terminal",
      `${path}: unexpected matrix status`,
    );
}
function main(): void {
  const args = process.argv.slice(2);
  if (args.includes("--self-test")) {
    requireValue(
      same(recount([{ status: "pass", mode: "javascript_api" }]), {
        pass: 1,
        fail: 0,
        not_applicable: 0,
        runner_error: 0,
        total: 1,
      }),
      "counter self-test",
    );
    console.log("WebAssembly feature validator self-test: PASS");
    return;
  }
  requireValue(args.length === 0, `unknown arguments: ${args.join(" ")}`);
  const registry = load("docs/.data/wasm-feature-profiles.json");
  requireValue(
    registry.schema_version === 1 && SHA.test(registry.tracker.commit),
    "invalid feature registry provenance",
  );
  const features: Item[] = registry.features;
  const profiles: Item[] = registry.profiles;
  requireValue(
    Array.isArray(features) && Array.isArray(profiles),
    "invalid registry collections",
  );
  const featureIds = new Set(features.map((feature) => feature.id));
  requireValue(featureIds.size === features.length, "duplicate feature id");
  for (const feature of features) {
    requireValue(
      ["finished", "phase_4"].includes(feature.standardization),
      `${feature.id}: invalid standardization`,
    );
    requireValue(SHA.test(feature.commit), `${feature.id}: invalid source pin`);
    for (const dependency of feature.dependencies || [])
      requireValue(
        featureIds.has(dependency),
        `${feature.id}: unknown dependency ${dependency}`,
      );
  }
  requireValue(
    profiles.filter((profile) => profile.default).length === 1 &&
      profiles.find((profile) => profile.default)?.id === "mvp",
    "MVP must be the sole default",
  );
  for (const profile of profiles) {
    requireValue(
      profile.status === "implemented",
      `${profile.id}: profile is not implemented`,
    );
    const selected = new Set(profile.features);
    for (const id of selected) {
      requireValue(featureIds.has(id), `${profile.id}: unknown feature ${id}`);
      const feature = features.find((item) => item.id === id)!;
      for (const dependency of feature.dependencies || [])
        requireValue(
          selected.has(dependency),
          `${profile.id}: missing dependency ${dependency}`,
        );
    }
  }
  const matrix = load("docs/.data/wasm-conformance-matrix.json");
  requireValue(
    matrix.kind === "zig_js_webassembly_conformance_matrix",
    "invalid conformance matrix",
  );
  for (const profile of matrix.profiles)
    validateInventory(profile.inventory, profile);
  const combined = matrix.profiles.reduce(
    (sum: Item, profile: Item) => {
      for (const key of [
        "pass",
        "fail",
        "not_applicable",
        "runner_error",
        "total",
      ])
        sum[key] += profile.totals[key];
      return sum;
    },
    { pass: 0, fail: 0, not_applicable: 0, runner_error: 0, total: 0 },
  );
  requireValue(
    same(combined, matrix.combined_totals),
    "combined matrix totals drift",
  );
  const drift = load("docs/.data/wasm-core-3-upstream-drift.json");
  requireValue(
    drift.kind === "webassembly_core_3_upstream_drift" &&
      drift.accepted.commit === "9d36019973201a19f9c9ebb0f10828b2fe2374aa" &&
      drift.accepted_score_changed === false,
    "Core 3 drift evidence is invalid",
  );
  console.log(
    `WebAssembly feature registry: ${profiles.length} profiles, ${features.length} pinned features; ${matrix.profiles.length} evidence profiles green`,
  );
}
if (process.argv[1] === __filename) main();
