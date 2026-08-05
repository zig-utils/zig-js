/** Validate the frozen representative performance-matrix contract. */
import { readText, run } from "./lib/home";

const script = process.argv[1].replace(/\\/g, "/"), suffix = "/tools/representative-matrix.ts";
export const ROOT = script.endsWith(suffix) ? script.slice(0, -suffix.length) : process.cwd();
export const DEFAULT_MANIFEST = ROOT + "/docs/.data/representative-benchmark-matrix-v12.json";
const defaultSourcePath = "bench/representative_comparison.js";
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
  requireValue(child.schema_version >= 2 && child.schema_version <= 12, "unsupported representative matrix schema");
  const parent = child.parent || {}, parentPath = root + "/" + parent.path;
  const expectedParent = `zig-js-representative-v${child.schema_version - 1}`;
  requireValue(parent.matrix_id === expectedParent, `v${child.schema_version} must inherit ${expectedParent}`);
  requireValue(Home.fileExists(parentPath), "representative parent manifest does not exist");
  requireValue(digest(parentPath) === parent.sha256, `representative parent manifest changed after v${child.schema_version} froze`);
  const inherited = loadManifest(parentPath, root);
  requireValue(inherited.matrix_id === parent.matrix_id, "representative parent matrix id drift");
  validate(inherited, root);
  requireValue(Array.isArray(parent.inherit) && unique(parent.inherit), `v${child.schema_version} inherited-field inventory is invalid`);
  for (const name of parent.inherit) {
    requireValue(Object.prototype.hasOwnProperty.call(inherited, name), `v${child.schema_version} inherits unknown parent field: ${name}`);
    requireValue(!Object.prototype.hasOwnProperty.call(child, name), `v${child.schema_version} rewrites inherited field: ${name}`);
  }
  if (child.schema_version === 2) return { ...inherited, ...child };
  if (child.schema_version >= 9) {
    requireValue(child.tier_attribution && typeof child.tier_attribution === "object", `v${child.schema_version} must replace the attribution contract`);
    requireValue(child.implemented_families_append === undefined && child.deferred_families_remove === undefined, `v${child.schema_version} changes attribution only`);
    return { ...inherited, ...child };
  }

  const additions = child.implemented_families_append,
    removals = child.deferred_families_remove;
  requireValue(Array.isArray(additions) && additions.length > 0, `v${child.schema_version} must append at least one implemented family`);
  requireValue(Array.isArray(removals) && removals.length === additions.length && unique(removals), `v${child.schema_version} deferred-family removal inventory is invalid`);
  const deferredNames = inherited.deferred_families.map((entry: any) => entry.family),
    addedNames = additions.map((entry: any) => entry.family);
  requireValue(unique(addedNames), `v${child.schema_version} appended family is duplicated`);
  requireValue(addedNames.every((name: string) => removals.indexOf(name) >= 0), `v${child.schema_version} must remove every appended family from the deferred inventory`);
  requireValue(removals.every((name: string) => deferredNames.indexOf(name) >= 0), `v${child.schema_version} removes a family that was not deferred`);
  return {
    ...inherited,
    ...child,
    implemented_families: inherited.implemented_families.concat(additions),
    deferred_families: inherited.deferred_families.filter((entry: any) => removals.indexOf(entry.family) < 0),
    additional_panels: (inherited.additional_panels || []).concat(child.additional_panels_append || []),
  };
}
export function validate(manifest: any, root = ROOT): void {
  requireValue(manifest.schema_version >= 1 && manifest.schema_version <= 12, "unsupported representative matrix schema");
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
  const sources: Record<string, string> = {}, workloads: string[] = [];
  for (const entry of implemented) {
    requireValue(Number.isInteger(entry.jobs.full) && entry.jobs.full > 0, "invalid full jobs: " + JSON.stringify(entry));
    requireValue(Number.isInteger(entry.jobs.quick) && entry.jobs.quick > 0 && entry.jobs.quick < entry.jobs.full, "invalid quick jobs: " + JSON.stringify(entry));
    requireValue(entry.shared === undefined || typeof entry.shared === "boolean", "invalid shared-mode ruling: " + JSON.stringify(entry));
    const sourceName = entry.source || defaultSourcePath,
      path = root + "/" + sourceName;
    requireValue(Home.fileExists(path), "workload source does not exist: " + sourceName);
    const source = sources[sourceName] ||= readText(path);
    for (const role of ["base", "variant"]) {
      const workload = entry[role];
      requireValue(typeof workload === "string" && workload.length > 0, `invalid ${role} workload: ${JSON.stringify(entry)}`);
      requireValue(workloads.indexOf(workload) < 0, "duplicate workload id: " + workload); workloads.push(workload);
      requireValue(source.indexOf(`"${workload}"`) >= 0, "workload is absent from declared source dispatch: " + workload);
      for (const scale of ["full", "quick"]) {
        const values = entry.checksums[role][scale];
        requireValue(Array.isArray(values) && values.length === lanes.length, `${workload} ${scale} checksums must match lanes`);
        requireValue(values.every((value: any) => Number.isInteger(value) && value >= 0 && value < 9007199254740992), `${workload} ${scale} checksum is not an exact non-negative integer`);
      }
    }
    requireValue(entry.base !== entry.variant, "base and variant must differ: " + entry.family);
    if (entry.completion !== undefined) {
      requireValue(entry.completion.kind === "host_microtask_checkpoint", "unknown completion boundary: " + JSON.stringify(entry));
      requireValue(entry.completion.checksum_hook === "__benchmarkReadChecksum", "checkpoint workload must use the generic checksum hook");
      requireValue(typeof entry.completion.timed_boundary === "string" && entry.completion.timed_boundary.length > 0, "checkpoint workload lacks a timed boundary");
      requireValue(source.indexOf(`globalThis.${entry.completion.checksum_hook}`) >= 0, "checkpoint checksum hook is absent from declared source");
    }
    if (entry.availability !== undefined) {
      const availability = entry.availability;
      requireValue(availability.kind === "zig_js_capability" || availability.kind === "zig_js_module_capability", "unknown availability boundary: " + JSON.stringify(entry));
      requireValue(same(availability.engines || [], ["zig-js"]), "availability-gated family must remain zig-js-only");
      requireValue(availability.JavaScriptCore && typeof availability.JavaScriptCore.result === "string" && availability.JavaScriptCore.result.length > 0, "availability-gated family lacks a JavaScriptCore result");
      if (availability.kind === "zig_js_capability") {
        requireValue(same(availability.modes || [], ["single", "shared"]), "availability-gated family mode inventory changed");
        requireValue(typeof availability.probe_workload === "string" && source.indexOf(`"${availability.probe_workload}"`) >= 0, "availability probe is absent from declared source dispatch");
        requireValue(availability.checksums && availability.checksums["zig-js"] === 1 && availability.checksums.JavaScriptCore === 0, "availability profile must require zig-js=1 and JavaScriptCore=0");
      } else {
        requireValue(same(availability.modes || [], ["module_cold"]), "module capability mode inventory changed");
        requireValue(availability.attribution_mode === "module_attribution", "module capability lacks its attribution mode");
        const probePath = root + "/" + availability.probe_source;
        requireValue(Home.fileExists(probePath) && readText(probePath).indexOf(`"${availability.probe_workload}"`) >= 0, "module capability probe is absent from declared source dispatch");
        requireValue(availability.JavaScriptCore.expected === "reject" && typeof availability.JavaScriptCore.stderr_contains === "string" && availability.JavaScriptCore.stderr_contains.length > 0, "module capability lacks an exact JavaScriptCore rejection gate");
        requireValue(typeof availability.public_api_inventory === "string" && availability.public_api_inventory.length > 0, "module capability lacks its public API inventory");
      }
    }
  }
  const additionalPanels = manifest.additional_panels || [];
  requireValue(Array.isArray(additionalPanels), "additional panel inventory must be a list");
  requireValue(unique(additionalPanels.map((entry: any) => entry.id)), "additional panel id is duplicated");
  for (const entry of additionalPanels) {
    requireValue(typeof entry.id === "string" && entry.id.length > 0, "additional panel lacks an id");
    requireValue(typeof entry.workload === "string" && workloads.indexOf(entry.workload) < 0, "additional panel workload is invalid or duplicated: " + JSON.stringify(entry));
    workloads.push(entry.workload);
    const sourceName = entry.source,
      path = root + "/" + sourceName;
    requireValue(typeof sourceName === "string" && Home.fileExists(path), "additional panel source does not exist: " + sourceName);
    const source = sources[sourceName] ||= readText(path);
    requireValue(source.indexOf(`"${entry.workload}"`) >= 0, "additional panel workload is absent from declared source dispatch: " + entry.workload);
    requireValue(Number.isInteger(entry.jobs.full) && entry.jobs.full > 0, "invalid additional panel full jobs: " + JSON.stringify(entry));
    requireValue(Number.isInteger(entry.jobs.quick) && entry.jobs.quick > 0 && entry.jobs.quick < entry.jobs.full, "invalid additional panel quick jobs: " + JSON.stringify(entry));
    for (const scale of ["full", "quick"]) {
      const values = entry.checksums[scale];
      requireValue(Array.isArray(values) && values.length === lanes.length, `${entry.workload} ${scale} checksums must match lanes`);
      requireValue(values.every((value: any) => Number.isInteger(value) && value >= 0 && value < 9007199254740992), `${entry.workload} ${scale} checksum is not an exact non-negative integer`);
    }
    requireValue(same(entry.lanes || [], lanes), "additional panel lanes must be exactly 1/2/4/8");
    if (entry.kind === "cross_engine_oracle") {
      requireValue(same(entry.engines || [], ["zig-js", "JavaScriptCore"]), "cross-engine panel engine inventory changed");
      requireValue(same(entry.modes || [], ["single", "independent_steady", "independent_cold"]), "cross-engine panel mode inventory changed");
    } else {
      requireValue(entry.kind === "zig_js_capability", "unknown additional panel kind: " + entry.kind);
      requireValue(same(entry.engines || [], ["zig-js"]), "capability panel must remain zig-js-only");
      requireValue(same(entry.modes || [], ["single", "shared"]), "capability panel mode inventory changed");
      const gate = entry.feature_gate && entry.feature_gate.JavaScriptCore;
      requireValue(gate && gate.expected === "reject" && typeof gate.stderr_contains === "string" && gate.stderr_contains.length > 0, "capability panel lacks an exact JavaScriptCore feature gate");
    }
  }
  requireValue(manifest.protocol.minimum_full_median_ns === 50000000, "v1 must retain the 50 ms timing floor");
  requireValue(manifest.protocol.full_samples === 7, "v1 must retain seven full samples");
  const modes = manifest.modes;
  requireValue(same(Object.keys(modes).sort(), ["independent_cold", "independent_steady", "shared", "single_warm"]), "v1 mode inventory changed");
  requireValue(same(modes.shared.engines, ["zig-js"]), "shared mode must not construct a JSC ratio");
  requireValue(Array.isArray(manifest.pending_metric_panels), "pending metric inventory must remain explicit");
  if (manifest.schema_version >= 12) {
    const pending = manifest.pending_metric_panels;
    requireValue(
      same(pending[0]?.metrics || [], ["tier_up_ns", "deoptimization_ns"]) &&
        pending[0]?.issue === 461 && pending[1]?.issue === 503 && pending[2]?.issue === 504,
      "V12 pending metric inventory does not remove exactly the implemented CPU/RSS metrics",
    );
  } else if (manifest.schema_version >= 11) {
    const pending = manifest.pending_metric_panels;
    requireValue(
      same(pending[0]?.metrics || [], ["cpu_time_ns", "peak_rss_bytes", "retained_rss_bytes", "tier_up_ns", "deoptimization_ns"]) &&
        pending[0]?.issue === 461 && pending[1]?.issue === 503 && pending[2]?.issue === 504,
      "V11 pending metric inventory does not remove exactly the implemented allocation/GC metrics",
    );
  }
  if (manifest.schema_version >= 2) {
    const attribution = manifest.tier_attribution || {};
    requireValue(same(attribution.phases || [], ["configuration", "warmup", "invocation"]), "representative tier phases changed");
    const expectedMetrics = manifest.schema_version >= 12
      ? [
        "tree_walker_entries", "vm_entries", "vm_dispatches", "vm_quick_kernel_hits", "baseline_entries", "optimizer_entries",
        "optimizer_osr_entries", "deoptimizations", "runtime_operation_calls", "host_callbacks", "wasm_dispatches",
        "environment_allocations", "bytecode_admissions_by_reason", "baseline_publications", "optimizer_publications", "generated_code_bytes",
        "native_code_lifetime_by_state", "heap_live_bytes", "heap_collections", "synchronization_by_path", "worker_lifecycle",
        "context_backing_allocations", "gc_cell_allocations", "gc_pause_samples", "process_cpu_time_by_mode", "peak_rss_bytes", "retained_rss_bytes",
      ]
      : manifest.schema_version >= 11
      ? [
        "tree_walker_entries", "vm_entries", "vm_dispatches", "vm_quick_kernel_hits", "baseline_entries", "optimizer_entries",
        "optimizer_osr_entries", "deoptimizations", "runtime_operation_calls", "host_callbacks", "wasm_dispatches",
        "environment_allocations", "bytecode_admissions_by_reason", "baseline_publications", "optimizer_publications", "generated_code_bytes",
        "native_code_lifetime_by_state", "heap_live_bytes", "heap_collections", "synchronization_by_path", "worker_lifecycle",
        "context_backing_allocations", "gc_cell_allocations", "gc_pause_samples",
      ]
      : manifest.schema_version >= 10
      ? [
        "tree_walker_entries", "vm_entries", "vm_dispatches", "vm_quick_kernel_hits", "baseline_entries", "optimizer_entries",
        "optimizer_osr_entries", "deoptimizations", "runtime_operation_calls", "host_callbacks", "wasm_dispatches",
        "environment_allocations", "bytecode_admissions_by_reason", "baseline_publications", "optimizer_publications", "generated_code_bytes",
        "native_code_lifetime_by_state", "heap_live_bytes", "heap_collections", "synchronization_by_path", "worker_lifecycle",
      ]
      : manifest.schema_version >= 9
      ? [
        "tree_walker_entries", "vm_entries", "vm_dispatches", "vm_quick_kernel_hits", "baseline_entries", "optimizer_entries",
        "optimizer_osr_entries", "deoptimizations", "runtime_operation_calls", "host_callbacks", "wasm_dispatches",
        "environment_allocations", "bytecode_admissions_by_reason", "baseline_publications", "optimizer_publications", "generated_code_bytes",
        "native_code_lifetime_by_state", "heap_live_bytes", "heap_collections",
      ]
      : [
        "tree_walker_entries", "vm_entries", "baseline_entries", "optimizer_entries", "optimizer_osr_entries", "deoptimizations",
        "environment_allocations", "bytecode_admissions_by_reason", "baseline_publications", "optimizer_publications", "generated_code_bytes",
      ];
    requireValue(same(attribution.metrics || [], expectedMetrics), "representative tier metric inventory changed");
    requireValue(typeof attribution.equivalence === "string" && attribution.equivalence.length > 0, "representative matrix lacks tier equivalence rule");
    requireValue(typeof attribution.timing_isolation === "string" && attribution.timing_isolation.length > 0, "representative matrix lacks timing isolation rule");
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
