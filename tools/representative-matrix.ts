/** Validate the frozen representative performance-matrix contract. */
import { readText, run } from "./lib/home";

const script = process.argv[1].replace(/\\/g, "/"), suffix = "/tools/representative-matrix.ts";
export const ROOT = script.endsWith(suffix) ? script.slice(0, -suffix.length) : process.cwd();
export const DEFAULT_MANIFEST = ROOT + "/docs/.data/representative-benchmark-matrix-v2.json";
const sourcePath = ROOT + "/bench/representative_comparison.js";
function requireValue(condition: boolean, message: string): void { if (!condition) throw new Error(message); }
function digest(path: string): string {
  const result = run(["shasum", "-a", "256", path]);
  if (result.exitCode !== 0) throw new Error(result.stderr || "cannot hash " + path);
  return result.stdout.trim().split(/\s+/)[0];
}
const same = (left: any[], right: any[]) => left.length === right.length && left.every((value, index) => value === right[index]);
const unique = (values: any[]) => new Set(values).size === values.length;
export function loadManifest(path = DEFAULT_MANIFEST, root = ROOT): any {
  const child = JSON.parse(readText(path));
  if (child.schema_version === 1) return child;
  requireValue(child.schema_version === 2, "unsupported representative matrix schema");
  const parent = child.parent || {}, parentPath = root + "/" + parent.path;
  requireValue(parent.matrix_id === "zig-js-representative-v1", "v2 must inherit representative v1");
  requireValue(Home.fileExists(parentPath), "representative parent manifest does not exist");
  requireValue(digest(parentPath) === parent.sha256, "representative parent manifest changed after v2 froze");
  const inherited = JSON.parse(readText(parentPath));
  requireValue(inherited.matrix_id === parent.matrix_id, "representative parent matrix id drift");
  validate(inherited, root);
  requireValue(Array.isArray(parent.inherit) && unique(parent.inherit), "v2 inherited-field inventory is invalid");
  for (const name of parent.inherit) {
    requireValue(Object.prototype.hasOwnProperty.call(inherited, name), "v2 inherits unknown parent field: " + name);
    requireValue(!Object.prototype.hasOwnProperty.call(child, name), "v2 rewrites inherited field: " + name);
  }
  return { ...inherited, ...child };
}
export function validate(manifest: any, root = ROOT): void {
  requireValue(manifest.schema_version === 1 || manifest.schema_version === 2, "unsupported representative matrix schema");
  requireValue(manifest.status === "frozen", "representative matrix must be frozen");
  const lanes = manifest.lanes;
  requireValue(Array.isArray(lanes) && same(lanes, [1, 2, 4, 8]), "v1 lanes must be exactly 1/2/4/8");
  const panel = manifest.compatibility_panel || {};
  for (const field of ["source", "source_sha256", "driver", "driver_sha256"]) requireValue(typeof panel[field] === "string", "compatibility panel missing " + field);
  for (const pair of [["source", "source_sha256"], ["driver", "driver_sha256"]]) {
    const path = root + "/" + panel[pair[0]];
    requireValue(Home.fileExists(path), "compatibility panel path does not exist: " + path);
    requireValue(digest(path) === panel[pair[1]], "compatibility panel changed without a matrix version bump: " + path);
  }
  const required = manifest.required_families, implemented = manifest.implemented_families, deferred = manifest.deferred_families;
  requireValue(Array.isArray(required) && required.length > 0, "required_families must be non-empty");
  requireValue(unique(required), "required_families contains duplicates");
  requireValue(Array.isArray(implemented) && implemented.length > 0, "implemented_families must be non-empty");
  requireValue(Array.isArray(deferred), "deferred_families must be a list");
  const implementedNames = implemented.map((entry: any) => entry.family), deferredNames = deferred.map((entry: any) => entry.family);
  requireValue(unique(implementedNames), "implemented family is duplicated");
  requireValue(unique(deferredNames), "deferred family is duplicated");
  requireValue(implementedNames.every((name: string) => deferredNames.indexOf(name) < 0), "family cannot be implemented and deferred");
  const coverage = new Set(implementedNames.concat(deferredNames));
  requireValue(coverage.size === required.length && required.every((name: string) => coverage.has(name)), "implemented/deferred inventory must exactly cover required_families");
  for (const entry of deferred) requireValue(typeof entry.reason === "string" && entry.reason.length > 0, "deferred family lacks a reason: " + JSON.stringify(entry));
  const source = readText(root + "/bench/representative_comparison.js"), workloads: string[] = [];
  for (const entry of implemented) {
    requireValue(Number.isInteger(entry.jobs.full) && entry.jobs.full > 0, "invalid full jobs: " + JSON.stringify(entry));
    requireValue(Number.isInteger(entry.jobs.quick) && entry.jobs.quick > 0 && entry.jobs.quick < entry.jobs.full, "invalid quick jobs: " + JSON.stringify(entry));
    for (const role of ["base", "variant"]) {
      const workload = entry[role];
      requireValue(typeof workload === "string" && workload.startsWith("representative_"), `invalid ${role} workload: ${JSON.stringify(entry)}`);
      requireValue(workloads.indexOf(workload) < 0, "duplicate workload id: " + workload); workloads.push(workload);
      requireValue(source.indexOf(`"${workload}"`) >= 0, "workload is absent from representative source dispatch: " + workload);
      for (const scale of ["full", "quick"]) {
        const values = entry.checksums[role][scale];
        requireValue(Array.isArray(values) && values.length === lanes.length, `${workload} ${scale} checksums must match lanes`);
        requireValue(values.every((value: any) => Number.isInteger(value) && value >= 0 && value < 9007199254740992), `${workload} ${scale} checksum is not an exact non-negative integer`);
      }
    }
    requireValue(entry.base !== entry.variant, "base and variant must differ: " + entry.family);
  }
  requireValue(manifest.protocol.minimum_full_median_ns === 50000000, "v1 must retain the 50 ms timing floor");
  requireValue(manifest.protocol.full_samples === 7, "v1 must retain seven full samples");
  const modes = manifest.modes;
  requireValue(same(Object.keys(modes).sort(), ["independent_cold", "independent_steady", "shared", "single_warm"]), "v1 mode inventory changed");
  requireValue(same(modes.shared.engines, ["zig-js"]), "shared mode must not construct a JSC ratio");
  requireValue(Array.isArray(manifest.pending_metric_panels), "pending metric inventory must remain explicit");
  if (manifest.schema_version === 2) {
    const attribution = manifest.tier_attribution || {};
    requireValue(same(attribution.phases || [], ["configuration", "warmup", "invocation"]), "v2 tier phases changed");
    requireValue(same(attribution.metrics || [], [
      "tree_walker_entries", "vm_entries", "baseline_entries", "optimizer_entries", "optimizer_osr_entries", "deoptimizations",
      "environment_allocations", "bytecode_admissions_by_reason", "baseline_publications", "optimizer_publications", "generated_code_bytes",
    ]), "v2 tier metric inventory changed");
    requireValue(typeof attribution.equivalence === "string" && attribution.equivalence.length > 0, "v2 lacks tier equivalence rule");
    requireValue(typeof attribution.timing_isolation === "string" && attribution.timing_isolation.length > 0, "v2 lacks timing isolation rule");
    for (const workload of workloads) {
      const result = run(["rg", "-l", "-F", workload, root + "/src"]);
      requireValue(result.exitCode === 1, result.exitCode === 0
        ? "engine source recognizes representative workload: " + workload
        : result.stderr || "representative recognizer audit failed");
    }
  }
}
function main(): void {
  let path = DEFAULT_MANIFEST;
  for (let index = 2; index < process.argv.length; index += 1) {
    if (process.argv[index] !== "--manifest" || index + 1 >= process.argv.length) throw new Error("usage: representative-matrix.ts [--manifest PATH]");
    path = process.argv[++index];
  }
  const manifest = loadManifest(path); validate(manifest);
  console.log(`OK ${manifest.matrix_id}: ${manifest.implemented_families.length} implemented families, ${manifest.deferred_families.length} explicit deferred families`);
}
if (process.argv[1].replace(/\\/g, "/").endsWith("/tools/representative-matrix.ts") || process.argv[1] === "tools/representative-matrix.ts") main();
