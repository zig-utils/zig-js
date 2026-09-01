/** Validate the frozen representative performance-matrix contract. */
import { readText, run } from "./lib/home";

const script = process.argv[1].replace(/\\/g, "/"), suffix = "/tools/representative-matrix.ts";
export const ROOT = script.endsWith(suffix) ? script.slice(0, -suffix.length) : process.cwd();
export const DEFAULT_MANIFEST = ROOT + "/docs/.data/representative-benchmark-matrix-v33.json";
const defaultSourcePath = "bench/representative_comparison.js";
function requireValue(condition: boolean, message: string): void { if (!condition) throw new Error(message); }
function digest(path: string): string {
  const result = run(["shasum", "-a", "256", path]);
  if (result.exitCode !== 0) throw new Error(result.stderr || "cannot hash " + path);
  return result.stdout.trim().split(/\s+/)[0];
}
const same = (left: any[], right: any[]) => left.length === right.length && left.every((value, index) => value === right[index]);
const unique = (values: any[]) => new Set(values).size === values.length;
function validatePinnedFile(entry: any, label: string, root: string): void {
  requireValue(entry && typeof entry.path === "string" && entry.path.length > 0, `${label} path is invalid`);
  requireValue(typeof entry.sha256 === "string" && /^[0-9a-f]{64}$/.test(entry.sha256), `${label} SHA-256 is invalid`);
  const path = root + "/" + entry.path;
  requireValue(Home.fileExists(path), `${label} path does not exist: ${entry.path}`);
  requireValue(digest(path) === entry.sha256, `${label} changed without a matrix version bump: ${entry.path}`);
}
export function loadManifest(
  path = DEFAULT_MANIFEST,
  root = ROOT,
  supersedingExactParent: any = null,
  supersedingContextLifecycle: any = null,
  supersedingNoJit: any = null,
  deferIntegrationValidation = false,
): any {
  const child = JSON.parse(readText(path));
  if (child.schema_version === 1) return child;
  requireValue(child.schema_version >= 2 && child.schema_version <= 33, "unsupported representative matrix schema");
  const parent = child.parent || {}, parentPath = root + "/" + parent.path;
  const expectedParent = `zig-js-representative-v${child.schema_version - 1}`;
  requireValue(parent.matrix_id === expectedParent, `v${child.schema_version} must inherit ${expectedParent}`);
  requireValue(Home.fileExists(parentPath), "representative parent manifest does not exist");
  requireValue(digest(parentPath) === parent.sha256, `representative parent manifest changed after v${child.schema_version} froze`);
  // A newer matrix may supersede an integration's source/runner pin while
  // retaining every other historical field. Thread those replacements through
  // the parent load so it is still fully validated against the current tree
  // without requiring a historical checkout.
  const inherited = loadManifest(
    parentPath,
    root,
    supersedingExactParent ||
      (child.schema_version >= 17 && child.schema_version < 24 ? child.exact_parent_integration : null),
    supersedingContextLifecycle ||
      (child.schema_version >= 20 && child.schema_version < 24 ? child.context_lifecycle_integration : null),
    supersedingNoJit ||
      (child.schema_version >= 21 && child.schema_version < 24 ? child.no_jit_integration : null),
    deferIntegrationValidation || (child.schema_version >= 24 && child.schema_version <= 33),
  );
  requireValue(inherited.matrix_id === parent.matrix_id, "representative parent matrix id drift");
  requireValue(Array.isArray(parent.inherit) && unique(parent.inherit), `v${child.schema_version} inherited-field inventory is invalid`);
  for (const name of parent.inherit) {
    requireValue(Object.prototype.hasOwnProperty.call(inherited, name), `v${child.schema_version} inherits unknown parent field: ${name}`);
    requireValue(!Object.prototype.hasOwnProperty.call(child, name), `v${child.schema_version} rewrites inherited field: ${name}`);
  }
  if (child.schema_version === 33) {
    requireValue(child.tier_attribution && typeof child.tier_attribution === "object", "v33 must replace the attribution contract");
    requireValue(child.implemented_families_append === undefined && child.deferred_families_remove === undefined, "v33 changes attribution inventory only");
    requireValue(child.pending_metric_panels === undefined && child.completed_metric_panels === undefined, "v33 must inherit completed panel inventory unchanged");
    for (const name of ["exact_parent_integration", "instrumentation_overhead_integration", "context_lifecycle_integration", "no_jit_integration", "string_indexing_integration"])
      requireValue(child[name] === undefined, `v33 must inherit ${name} unchanged`);
    const merged = {
      ...inherited,
      ...child,
      tier_attribution: { ...inherited.tier_attribution, ...child.tier_attribution },
    };
    if (!deferIntegrationValidation) validate(merged, root);
    return merged;
  }
  if (child.schema_version === 32) {
    requireValue(child.tier_attribution === undefined, "v32 must inherit the scored attribution contract unchanged");
    requireValue(child.implemented_families_append === undefined && child.deferred_families_remove === undefined, "v32 changes the no-JIT publication tier only");
    requireValue(child.pending_metric_panels === undefined && child.completed_metric_panels === undefined, "v32 must inherit completed panel inventory unchanged");
    requireValue(child.no_jit_integration && typeof child.no_jit_integration === "object", "v32 must replace the no-JIT integration");
    for (const name of ["exact_parent_integration", "instrumentation_overhead_integration", "context_lifecycle_integration", "string_indexing_integration"])
      requireValue(child[name] === undefined, `v32 must inherit ${name} unchanged`);
    const merged = {
      ...inherited,
      ...child,
      no_jit_integration: { ...inherited.no_jit_integration, ...child.no_jit_integration },
    };
    if (!deferIntegrationValidation) validate(merged, root);
    return merged;
  }
  if (child.schema_version >= 24 && child.schema_version <= 31) {
    const version = `v${child.schema_version}`;
    requireValue(child.tier_attribution === undefined, `${version} must inherit the scored attribution contract unchanged`);
    requireValue(child.implemented_families_append === undefined && child.deferred_families_remove === undefined, `${version} changes evidence integration only`);
    requireValue(child.pending_metric_panels === undefined && child.completed_metric_panels === undefined, `${version} must inherit completed panel inventory unchanged`);
    for (const name of ["exact_parent_integration", "instrumentation_overhead_integration", "context_lifecycle_integration", "no_jit_integration", "string_indexing_integration"])
      requireValue(child[name] && typeof child[name] === "object", `${version} must replace ${name}`);
    const exactParent = { ...inherited.exact_parent_integration, ...child.exact_parent_integration };
    const merged = {
      ...inherited,
      ...child,
      exact_parent_integration: exactParent,
      context_lifecycle_integration: { ...inherited.context_lifecycle_integration, ...child.context_lifecycle_integration },
      no_jit_integration: { ...inherited.no_jit_integration, ...child.no_jit_integration },
      string_indexing_integration: { ...inherited.string_indexing_integration, ...child.string_indexing_integration },
      completed_metric_panels: {
        ...inherited.completed_metric_panels,
        efficiency_thermal: {
          ...inherited.completed_metric_panels.efficiency_thermal,
          scored_integration: exactParent,
          disabled_path_fixture: { ...inherited.completed_metric_panels.efficiency_thermal.disabled_path_fixture, ...child.instrumentation_overhead_integration },
        },
      },
    };
    if (!deferIntegrationValidation) validate(merged, root);
    return merged;
  }
  if (child.schema_version === 23) {
    requireValue(child.tier_attribution === undefined, "v23 must inherit the scored attribution contract unchanged");
    requireValue(child.implemented_families_append === undefined && child.deferred_families_remove === undefined, "v23 must not change scored workload coverage");
    requireValue(child.pending_metric_panels === undefined && child.completed_metric_panels === undefined, "v23 must inherit completed panel inventory unchanged");
    requireValue(child.context_lifecycle_integration && typeof child.context_lifecycle_integration === "object", "v23 must repin the context lifecycle runner");
    requireValue(child.no_jit_integration && typeof child.no_jit_integration === "object", "v23 must repin the no-JIT runner");
    requireValue(child.string_indexing_integration && typeof child.string_indexing_integration === "object", "v23 must add the string-indexing integration");
    const merged = {
      ...inherited,
      ...child,
      context_lifecycle_integration: supersedingContextLifecycle || child.context_lifecycle_integration,
      no_jit_integration: supersedingNoJit || child.no_jit_integration,
    };
    if (!deferIntegrationValidation) validate(merged, root);
    return merged;
  }
  if (child.schema_version === 21) {
    requireValue(child.tier_attribution === undefined, "v21 must inherit the scored attribution contract unchanged");
    requireValue(child.implemented_families_append === undefined && child.deferred_families_remove === undefined, "v21 must not change scored workload coverage");
    requireValue(child.pending_metric_panels === undefined && child.completed_metric_panels === undefined, "v21 must inherit completed panel inventory unchanged");
    requireValue(child.context_lifecycle_integration && typeof child.context_lifecycle_integration === "object", "v21 must repin the context lifecycle runner");
    requireValue(child.no_jit_integration && typeof child.no_jit_integration === "object", "v21 must repin the no-JIT integration");
    const merged = {
      ...inherited,
      ...child,
      context_lifecycle_integration: supersedingContextLifecycle || child.context_lifecycle_integration,
      no_jit_integration: supersedingNoJit || child.no_jit_integration,
    };
    if (!deferIntegrationValidation) validate(merged, root);
    return merged;
  }
  if (child.schema_version === 20) {
    requireValue(child.tier_attribution === undefined, "v20 must inherit the scored attribution contract unchanged");
    requireValue(child.implemented_families_append === undefined && child.deferred_families_remove === undefined, "v20 must not change scored workload coverage");
    requireValue(child.pending_metric_panels === undefined && child.completed_metric_panels === undefined, "v20 must inherit completed panel inventory unchanged");
    requireValue(child.context_lifecycle_integration && typeof child.context_lifecycle_integration === "object", "v20 must repin the context lifecycle runner");
    requireValue(child.no_jit_integration && typeof child.no_jit_integration === "object", "v20 must add the no-JIT integration");
    const merged = {
      ...inherited,
      ...child,
      context_lifecycle_integration: supersedingContextLifecycle || child.context_lifecycle_integration,
      no_jit_integration: supersedingNoJit || child.no_jit_integration,
    };
    if (!deferIntegrationValidation) validate(merged, root);
    return merged;
  }
  if (child.schema_version === 19) {
    requireValue(child.tier_attribution === undefined, "v19 must inherit the attribution contract unchanged");
    requireValue(child.implemented_families_append === undefined && child.deferred_families_remove === undefined, "v19 must not change scored workload coverage");
    requireValue(child.pending_metric_panels === undefined && child.completed_metric_panels === undefined, "v19 must inherit completed panel inventory unchanged");
    requireValue(child.exact_parent_integration && typeof child.exact_parent_integration === "object", "v19 must replace the exact-parent integration contract");
    requireValue(child.context_lifecycle_integration && typeof child.context_lifecycle_integration === "object", "v19 must add the context lifecycle integration");
    const exactParent = supersedingExactParent || child.exact_parent_integration;
    const contextLifecycle = supersedingContextLifecycle || child.context_lifecycle_integration;
    const merged = {
      ...inherited,
      ...child,
      context_lifecycle_integration: contextLifecycle,
      completed_metric_panels: {
        ...inherited.completed_metric_panels,
        efficiency_thermal: {
          ...inherited.completed_metric_panels.efficiency_thermal,
          scored_integration: exactParent,
        },
      },
    };
    if (!deferIntegrationValidation) validate(merged, root);
    return merged;
  }
  if (child.schema_version === 17 || child.schema_version === 18 || child.schema_version === 22) {
    const version = `v${child.schema_version}`;
    requireValue(child.tier_attribution === undefined, `${version} must inherit the attribution contract unchanged`);
    requireValue(child.implemented_families_append === undefined && child.deferred_families_remove === undefined, `${version} changes exact-parent integration only`);
    requireValue(child.pending_metric_panels === undefined && child.completed_metric_panels === undefined, `${version} must inherit completed panel inventory unchanged`);
    requireValue(child.exact_parent_integration && typeof child.exact_parent_integration === "object", `${version} must replace the exact-parent integration contract`);
    const exactParent = supersedingExactParent || child.exact_parent_integration;
    const merged = {
      ...inherited,
      ...child,
      completed_metric_panels: {
        ...inherited.completed_metric_panels,
        efficiency_thermal: {
          ...inherited.completed_metric_panels.efficiency_thermal,
          scored_integration: exactParent,
        },
      },
    };
    // V17/V18 each supersede only their parent's exact-parent source pin.
    // Validate the fully merged child so every other inherited hash remains
    // fail-closed without requiring a historical source checkout (#632).
    if (!deferIntegrationValidation) validate(merged, root);
    return merged;
  }
  if (!deferIntegrationValidation) validate(inherited, root);
  if (child.schema_version === 2) return { ...inherited, ...child };
  if (child.schema_version === 16) {
    requireValue(child.tier_attribution === undefined, "v16 must inherit the attribution contract unchanged");
    requireValue(child.implemented_families_append === undefined && child.deferred_families_remove === undefined, "v16 changes external panel integration only");
    requireValue(Array.isArray(child.pending_metric_panels) && child.pending_metric_panels.length === 0, "v16 must empty the completed pending-panel inventory");
    requireValue(child.completed_metric_panels && typeof child.completed_metric_panels === "object", "v16 must integrate the completed external panels");
    return { ...inherited, ...child };
  }
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
  requireValue(manifest.schema_version >= 1 && manifest.schema_version <= 33, "unsupported representative matrix schema");
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
  if (manifest.schema_version >= 16) {
    const version = `V${manifest.schema_version}`;
    requireValue(manifest.pending_metric_panels.length === 0, `${version} completed pending metric inventory must be empty`);
    const completed = manifest.completed_metric_panels;
    requireValue(
      completed && same(Object.keys(completed).sort(), ["efficiency_thermal", "independent_suite"]),
      `${version} completed panel inventory drift`,
    );
    const efficiency = completed.efficiency_thermal;
    requireValue(efficiency.issue === 503 && efficiency.status === "integrated", `${version} efficiency panel identity drift`);
    requireValue(JSON.stringify(manifest.exact_parent_integration) === JSON.stringify(efficiency.scored_integration), `${version} exact-parent integration mirror drift`);
    validatePinnedFile(efficiency.scored_integration, `${version} exact-parent integration`, root);
    if (manifest.schema_version >= 24) {
      const evidenceVersion = `V${manifest.schema_version}`;
      requireValue(efficiency.scored_integration.occupancy_scope === "declared_timed_boundary" && efficiency.scored_integration.minimum_cpu_occupancy === 0.6 && efficiency.scored_integration.complete_process_occupancy === "diagnostic_only", `${evidenceVersion} exact-parent occupancy policy drift`);
      validatePinnedFile(efficiency.scored_integration.attribution_schema, `${evidenceVersion} attribution schema`, root);
      validatePinnedFile(efficiency.scored_integration.attribution_validator, `${evidenceVersion} attribution validator`, root);
      validatePinnedFile(efficiency.scored_integration.algorithmic_growth_schema, `${evidenceVersion} algorithmic-growth schema`, root);
      validatePinnedFile(efficiency.scored_integration.algorithmic_growth_validator, `${evidenceVersion} algorithmic-growth validator`, root);
      requireValue(Array.isArray(efficiency.scored_integration.native_runners) && efficiency.scored_integration.native_runners.length === 2, `${evidenceVersion} native runner inventory drift`);
      for (const runner of efficiency.scored_integration.native_runners) validatePinnedFile(runner, `${evidenceVersion} measured-boundary native runner`, root);
      if (manifest.schema_version >= 25 && manifest.schema_version <= 26)
        requireValue(efficiency.scored_integration.binary_provenance === "identical_one-commit_measurement_overlay", "V25 binary provenance policy drift");
      if (manifest.schema_version >= 27) {
        const profiles = efficiency.scored_integration.binary_provenance_profiles;
        requireValue(efficiency.scored_integration.binary_provenance === "schema_v2_direct_or_schema_v3_identical_one_commit_measurement_overlay", "V27 binary provenance policy drift");
        const schemaV3 = manifest.schema_version >= 31
          ? "identical_one_commit_measurement_overlay_with_symmetric_inherited_blobs"
          : "identical_one_commit_measurement_overlay";
        requireValue(profiles && profiles.schema_v2 === "declared_binary_revisions_equal_logical_revisions" && profiles.schema_v3 === schemaV3 && profiles.partial_assertions === "refuse", "V27 binary provenance profile drift");
        if (manifest.schema_version >= 31) {
          const overlay = efficiency.scored_integration.shared_measurement_overlay;
          requireValue(overlay && overlay.path_surface === "complete_frozen_inventory" && overlay.changed_subset === "same_nonempty_subset_on_parent_and_candidate" && overlay.effective_blobs === "identical_across_parent_and_candidate" && overlay.undeclared_changes === "refuse", "V31 shared measurement overlay policy drift");
        }
      }
      if (manifest.schema_version >= 26) {
        const replay = efficiency.scored_integration.native_allocation_replay, batch = efficiency.scored_integration.serial_batch;
        requireValue(replay && same(replay.modes, ["attribution", "attribution_no_jit"]) && replay.phase === "invocation" && replay.timing === "outside_elapsed_ns" && same(replay.metrics, ["backing_allocations", "backing_allocation_bytes"]), "V26 native allocation replay policy drift");
        requireValue(batch && batch.execution === "strictly_serial" && batch.home_compilations === 1 && batch.artifact_boundary === "one_validated_artifact_per_row" && batch.existing_outputs === "refuse", "V26 exact-parent batch policy drift");
        if (manifest.schema_version >= 28) {
          requireValue(replay.phase_boundary === "invocation snapshot minus warmup snapshot" && same(replay.required_snapshots || [], ["configuration", "warmup", "invocation"]), "V28 allocation replay phase contract drift");
          requireValue(replay.signature_schema_version === 1 && same(replay.signature_sections || [], ["execution", "quick_binary", "admissions", "shape", "native_code", "baseline_publications", "optimizer_publications", "generated_code_bytes"]), "V28 allocation replay signature inventory drift");
          requireValue(Array.isArray(replay.signature_contracts) && replay.signature_contracts.length === 1, "V28 allocation replay contract inventory drift");
          const contractEntry = replay.signature_contracts[0]; validatePinnedFile(contractEntry, "V28 allocation replay signature contract", root);
          const contract = JSON.parse(readText(root + "/" + contractEntry.path));
          requireValue(contract.schema_version === replay.signature_schema_version && contract.profile_id === contractEntry.profile_id && contract.status === "frozen" && contract.owner_issue === 775, "V28 allocation replay contract identity drift");
          for (const field of ["mode", "phase", "workload", "lanes", "jobs", "checksum"]) requireValue(contract.replay[field] === contractEntry[field], `V28 allocation replay contract ${field} drift`);
          requireValue(typeof replay.legacy_vm_only === "string" && replay.legacy_vm_only.length > 0 && typeof replay.cross_variant_ruling === "string" && replay.cross_variant_ruling.length > 0, "V28 allocation replay compatibility ruling drift");
        }
      }
    }
    validatePinnedFile(efficiency.disabled_path_fixture, `${version} instrumentation fixture`, root);
    validatePinnedFile(efficiency.disabled_path_fixture.raw_evidence, `${version} instrumentation raw evidence`, root);
    validatePinnedFile(efficiency.disabled_path_fixture.report, `${version} instrumentation report`, root);
    requireValue(
      same(efficiency.scored_integration.measured_metrics || [], ["instructions", "cycles", "energy_joules", "thermal_state"]),
      `${version} measured efficiency metric inventory drift`,
    );
    requireValue(
      same(efficiency.scored_integration.material_change_categories || [], ["cpu_work", "threads", "generated_code", "cache_traffic"]),
      `${version} material-change category inventory drift`,
    );
    requireValue(
      same(efficiency.explicitly_unavailable || [], ["cpu_cache_misses", "tlb_misses", "branches_and_misses", "migrations", "scheduler_wait", "frequency", "package_energy", "peak_power"]),
      `${version} unavailable efficiency metric inventory drift`,
    );
    requireValue(
      typeof efficiency.scored_integration.publication_boundary === "string" && efficiency.scored_integration.publication_boundary.length > 0 &&
        typeof efficiency.disabled_path_fixture.evidence_ruling === "string" && efficiency.disabled_path_fixture.evidence_ruling.length > 0,
      `${version} efficiency publication ruling is incomplete`,
    );

    const independent = completed.independent_suite;
    requireValue(independent.issue === 504 && independent.status === "integrated", `${version} independent-suite panel identity drift`);
    validatePinnedFile(independent.inventory, `${version} independent-suite inventory`, root);
    validatePinnedFile(independent.offline_verifier, `${version} independent-suite verifier`, root);
    requireValue(
      Array.isArray(independent.adapters) && same(independent.adapters.map((entry: any) => entry.engine), ["zig-js", "system-jsc", "node-v8"]),
      `${version} independent engine adapter inventory drift`,
    );
    for (const adapter of independent.adapters) validatePinnedFile(adapter, `${version} ${adapter.engine} adapter`, root);
    validatePinnedFile(independent.collector, `${version} independent-suite collector`, root);
    validatePinnedFile(independent.recognizer, `${version} independent-suite recognizer`, root);
    requireValue(
      same(independent.unavailable_optional_engines || [], ["standalone-v8", "spidermonkey", "quickjs"]),
      `${version} unavailable optional-engine inventory drift`,
    );
    requireValue(
      typeof independent.recognizer.required_equivalence === "string" && independent.recognizer.required_equivalence.length > 0 &&
        typeof independent.publication_boundary === "string" && independent.publication_boundary.length > 0,
      `${version} independent-suite publication ruling is incomplete`,
    );
    if (manifest.schema_version >= 19) {
      const lifecycle = manifest.context_lifecycle_integration;
      requireValue(lifecycle && lifecycle.issue === 661 && lifecycle.status === "integrated_non_scored_profile" && lifecycle.mode === "context_lifecycle", "V19 context lifecycle identity drift");
      requireValue(same(lifecycle.engines || [], ["zig-js"]) && same(lifecycle.lanes || [], [1]), "V19 context lifecycle engine/lane boundary drift");
      requireValue(same(lifecycle.scenarios || [], ["context_no_evaluation", "context_first_source", "context_first_module", "context_full_feature"]), "V19 context lifecycle scenario inventory drift");
      validatePinnedFile(lifecycle.profile, "V19 context lifecycle profile", root);
      validatePinnedFile(lifecycle.runner, "V19 context lifecycle runner", root);
      requireValue(same(lifecycle.telemetry || [], ["create_ns", "work_ns", "destroy_ns", "cpu_user_ns", "cpu_system_ns", "baseline_rss_bytes", "max_live_rss_bytes", "post_destroy_rss_bytes", "retained_delta_bytes", "peak_rss_bytes", "rss_checkpoints", "gc_finalizer_stats"]), "V19 context lifecycle telemetry inventory drift");
      requireValue(typeof lifecycle.publication_boundary === "string" && lifecycle.publication_boundary.length > 0, "V19 context lifecycle publication boundary is missing");
    }
    if (manifest.schema_version >= 20) {
      const noJit = manifest.no_jit_integration;
      requireValue(noJit && noJit.issue === 734 && noJit.status === "integrated_non_scored_profile", "V20 no-JIT profile identity drift");
      requireValue(same(noJit.modes || [], ["single_no_jit", "attribution_no_jit"]), "V20 no-JIT mode inventory drift");
      requireValue(same(noJit.engines || [], ["zig-js"]) && same(noJit.lanes || [], [1]), "V20 no-JIT engine/lane boundary drift");
      validatePinnedFile(noJit.source, "V20 no-JIT workload source", root);
      validatePinnedFile(noJit.runner, "V20 no-JIT runner", root);
      requireValue(noJit.context_options?.enable_jit === false && noJit.context_options?.bytecode_execution_mode === "required", "V20 no-JIT Context options drift");
      const expectedWorkloads = [
        ["representative_vm_arithmetic_number", "stable_number", 606036, 5236590351],
        ["representative_vm_arithmetic_bigint", "stable_bigint_control", 5412345, 630334997],
        ["representative_vm_arithmetic_polymorphic", "number_string_bigint_object_control", 29422, 28806122],
        ["representative_vm_arithmetic_coercion", "effect_and_exception_control", 101766, 10176362],
      ];
      requireValue(Array.isArray(noJit.workloads) && same(noJit.workloads.map((entry: any) => entry.id), expectedWorkloads.map(entry => entry[0])), "V20 no-JIT workload inventory drift");
      const source = readText(root + "/" + noJit.source.path);
      for (let index = 0; index < noJit.workloads.length; index += 1) {
        const workload = noJit.workloads[index], expected = expectedWorkloads[index];
        requireValue(source.indexOf(`"${workload.id}"`) >= 0, `V20 no-JIT workload is absent from source: ${workload.id}`);
        requireValue(workload.role === expected[1], `V20 no-JIT workload role drift: ${workload.id}`);
        requireValue(workload.jobs?.quick === 100 && workload.jobs?.full === 10000, `V20 no-JIT job contract drift: ${workload.id}`);
        requireValue(workload.checksums?.quick === expected[2] && workload.checksums?.full === expected[3], `V20 no-JIT checksum drift: ${workload.id}`);
      }
      if (manifest.schema_version >= 32) {
        const publication = noJit.publication_tier;
        const expectedPublication = [
          ["representative_vm_arithmetic_number", 4594271287158],
          ["representative_vm_arithmetic_bigint", 31534975730],
          ["representative_vm_arithmetic_polymorphic", 62690691228],
          ["representative_vm_arithmetic_coercion", 508812500],
        ];
        requireValue(publication && publication.owner_issue === 843 && publication.jobs === 500000, "V32 no-JIT publication-tier identity drift");
        requireValue(publication.preserves_quick_and_full === true && publication.exact_parent_required === true, "V32 no-JIT publication-tier boundary drift");
        requireValue(same(publication.required_efficiency_metrics || [], ["instructions", "cycles", "energy_joules", "thermal_state"]), "V32 no-JIT publication-tier metric inventory drift");
        requireValue(typeof publication.rationale === "string" && publication.rationale.length > 0, "V32 no-JIT publication-tier rationale is missing");
        requireValue(Array.isArray(publication.checksums) && publication.checksums.length === expectedPublication.length, "V32 no-JIT publication-tier workload inventory drift");
        for (let index = 0; index < expectedPublication.length; index += 1) {
          const actual = publication.checksums[index], expected = expectedPublication[index];
          requireValue(actual?.workload === expected[0] && actual?.checksum === expected[1], `V32 no-JIT publication-tier checksum drift: ${expected[0]}`);
        }
      }
      requireValue(noJit.attribution?.tree_walker_entries === 0 && noJit.attribution?.baseline_publications === 0 && noJit.attribution?.optimizer_publications === 0 && noJit.attribution?.generated_code_bytes === 0, "V20 no-JIT attribution boundary drift");
      requireValue(same(noJit.attribution?.required_nonzero || [], ["vm_entries", "vm_dispatches", "program_compiled", "template_plain_compiled"]), "V20 no-JIT required attribution inventory drift");
      requireValue(typeof noJit.timed_boundary === "string" && noJit.timed_boundary.length > 0, "V20 no-JIT timed boundary is missing");
      requireValue(typeof noJit.publication_boundary === "string" && noJit.publication_boundary.length > 0, "V20 no-JIT publication boundary is missing");
    }
    if (manifest.schema_version >= 21) {
      const quick = manifest.no_jit_integration.quick_binary;
      requireValue(quick && quick.issue === 734 && quick.number_observation_threshold === 8 && quick.state_bytes_per_instruction === 1, "V21 quick-binary identity/state contract drift");
      requireValue(quick.generic_is_terminal === true && quick.specialized_miss_executes_ordinary_once === true, "V21 quick-binary miss contract drift");
      requireValue(same(quick.counters || [], ["number_hits", "number_misses", "dequickenings"]), "V21 quick-binary counter inventory drift");
      requireValue(quick.stable_number?.number_hits === "nonzero" && quick.stable_number?.number_misses === 0 && quick.stable_number?.dequickenings === 0, "V21 stable-Number attribution contract drift");
      const expectedFullAttribution = [
        ["representative_vm_arithmetic_number", 28, 3020460, 919643],
        ["representative_vm_arithmetic_bigint", 28, 900541, 79982],
        ["representative_vm_arithmetic_polymorphic", 28, 1180600, 164905],
        ["representative_vm_arithmetic_coercion", 28, 810659, 157437],
      ];
      requireValue(Array.isArray(quick.full_attribution) && quick.full_attribution.length === expectedFullAttribution.length, "V21 quick-binary full attribution inventory drift");
      for (let index = 0; index < expectedFullAttribution.length; index += 1) {
        const actual = quick.full_attribution[index], expected = expectedFullAttribution[index];
        requireValue(
          actual?.workload === expected[0] && actual?.vm_entries === expected[1] && actual?.vm_dispatches === expected[2] && actual?.number_hits === expected[3] && actual?.number_misses === 0 && actual?.dequickenings === 0,
          `V21 quick-binary full attribution drift: ${expected[0]}`,
        );
      }
      requireValue(typeof quick.publication_boundary === "string" && quick.publication_boundary.length > 0, "V21 quick-binary publication boundary is missing");
    }
    if (manifest.schema_version >= 23) {
      const indexing = manifest.string_indexing_integration;
      requireValue(indexing && indexing.issue === 767 && indexing.status === "benchmark_first_non_scored_profile", "V23 string-indexing profile identity drift");
      requireValue(same(indexing.engines || [], ["zig-js"]) && same(indexing.modes || [], ["single_no_jit", "attribution_no_jit"]) && same(indexing.lanes || [], [1]), "V23 string-indexing execution boundary drift");
      requireValue(indexing.context_options?.enable_jit === false && indexing.context_options?.bytecode_execution_mode === "required", "V23 string-indexing Context options drift");
      validatePinnedFile(indexing.source, "V23 string-indexing workload source", root);
      validatePinnedFile(indexing.runner, "V23 string-indexing runner", root);
      requireValue(same(indexing.widths || [], [1024, 2048, 4096]), "V23 string-indexing width inventory drift");
      const expectedRepresentations = [
        ["ascii", "one_byte_control", "Ax"],
        ["latin1", "non_ascii_latin1", "éÿ"],
        ["bmp", "non_latin1_bmp", "水Ω"],
        ["astral", "surrogate_pair", "😀"],
        ["lone", "lone_surrogate", "\\ud800x"],
        ["mixed", "mixed_code_units", "Aé水😀\\ud800x"],
      ];
      requireValue(Array.isArray(indexing.representations) && indexing.representations.length === expectedRepresentations.length, "V23 string-indexing representation inventory drift");
      for (let index = 0; index < expectedRepresentations.length; index += 1) {
        const actual = indexing.representations[index], expected = expectedRepresentations[index];
        requireValue(actual?.id === expected[0] && actual?.role === expected[1] && actual?.pattern === expected[2], `V23 string-indexing representation drift: ${expected[0]}`);
      }
      const expectedChecksums: Record<string, [number, number]> = {
        ascii_1024: [2386682, 23880132], ascii_2048: [8967418, 89700804], ascii_4096: [34711802, 347171268],
        latin1_1024: [2852561, 28538922], latin1_2048: [9898705, 99013674], latin1_4096: [36573905, 365792298],
        bmp_1024: [46145041, 461463722], bmp_2048: [96428049, 964307114], bmp_4096: [209576977, 2095823018],
        astral_1024: [174665277, 1746666082], astral_2048: [353284157, 3532868194], astral_4096: [723104829, 7231101538],
        lone_1024: [87331960, 873332912], lone_2048: [178747512, 1787501744], lone_4096: [374161528, 3741668528],
        mixed_1024: [87777979, 877793102], mixed_2048: [180107898, 1801105604], mixed_4096: [376972101, 3769774258],
      };
      const expectedFullAttribution: Record<string, [number, number, number]> = {
        ascii_1024: [1956966, 176365, 24257955], ascii_2048: [3911786, 340214, 42514047], ascii_4096: [7821422, 667894, 77006481],
        latin1_1024: [1956974, 176365, 24301006], latin1_2048: [3911794, 340214, 42600918], latin1_4096: [7821430, 667894, 77178556],
        bmp_1024: [1956982, 176366, 25060023], bmp_2048: [3911802, 340214, 42643143], bmp_4096: [7821438, 667895, 78395211],
        astral_1024: [1956990, 176366, 25079506], astral_2048: [3911810, 340214, 42682602], astral_4096: [7821446, 667895, 78472956],
        lone_1024: [1956998, 176365, 24301000], lone_2048: [3911818, 340214, 42600912], lone_4096: [7821454, 667894, 77178550],
        mixed_1024: [1950445, 176368, 24314979], mixed_2048: [3898677, 340217, 42627945], mixed_4096: [7795155, 667898, 78364389],
      };
      const expectedWorkloads = expectedRepresentations.flatMap(([representation]) =>
        indexing.widths.map((width: number) => `representative_string_utf16_${representation}_${width}`),
      );
      requireValue(Array.isArray(indexing.workloads) && same(indexing.workloads.map((entry: any) => entry.id), expectedWorkloads), "V23 string-indexing workload inventory drift");
      for (const workload of indexing.workloads) {
        const suffix = `${workload.representation}_${workload.width}`, expected = expectedChecksums[suffix];
        requireValue(Boolean(expected) && workload.id === `representative_string_utf16_${suffix}`, `V23 string-indexing workload identity drift: ${workload.id}`);
        requireValue(workload.jobs?.quick === 1 && workload.jobs?.full === 10, `V23 string-indexing job contract drift: ${workload.id}`);
        requireValue(workload.checksums?.quick === expected[0] && workload.checksums?.full === expected[1], `V23 string-indexing checksum drift: ${workload.id}`);
        requireValue(Number.isSafeInteger(workload.checksums.quick) && Number.isSafeInteger(workload.checksums.full), `V23 string-indexing checksum is not exactly representable: ${workload.id}`);
      }
      const indexingSource = readText(root + "/" + indexing.source.path);
      requireValue(indexingSource.includes('"representative_string_utf16_"') && indexingSource.includes("selectRepresentativeStringIndex"), "V23 string-indexing dispatch is absent from the declared source");
      requireValue(
        JSON.stringify(indexing.scored_operations_per_code_unit) === JSON.stringify({ char_code_at: 1, primitive_exotic_index: 1, boxed_exotic_index: 1, primitive_length: 1, boxed_length: 1 }),
        "V23 string-indexing scored-operation inventory drift",
      );
      requireValue(same(indexing.per_job_boundary_probes || [], ["charAt(middle)", "at(-1)", "codePointAt(middle)"]), "V23 string-indexing boundary-probe inventory drift");
      requireValue(indexing.allocation_replay?.mode === "attribution_no_jit" && indexing.allocation_replay?.replays === 2 && same(indexing.allocation_replay?.required_exact_metrics || [], ["backing_allocations", "backing_allocation_bytes"]) && typeof indexing.allocation_replay?.ruling === "string" && indexing.allocation_replay.ruling.length > 0, "V23 string-indexing allocation-replay contract drift");
      requireValue(Array.isArray(indexing.full_attribution) && same(indexing.full_attribution.map((entry: any) => entry.workload), expectedWorkloads), "V23 string-indexing full attribution inventory drift");
      for (const entry of indexing.full_attribution) {
        const suffix = entry.workload.replace("representative_string_utf16_", ""), expected = expectedFullAttribution[suffix];
        requireValue(Boolean(expected) && entry.checksum === expectedChecksums[suffix][1] && entry.vm_entries === 30 && entry.vm_dispatches === expected[0] && entry.program_compiled === 16 && entry.template_plain_compiled === 5 && entry.backing_allocations === expected[1] && entry.backing_allocation_bytes === expected[2], `V23 string-indexing full attribution drift: ${entry.workload}`);
      }
      requireValue(indexing.attribution?.tree_walker_entries === 0 && indexing.attribution?.baseline_publications === 0 && indexing.attribution?.optimizer_publications === 0 && indexing.attribution?.generated_code_bytes === 0, "V23 string-indexing attribution boundary drift");
      requireValue(same(indexing.attribution?.required_nonzero || [], ["vm_entries", "vm_dispatches", "program_compiled", "template_plain_compiled"]), "V23 string-indexing required attribution inventory drift");
      requireValue(typeof indexing.timed_boundary === "string" && indexing.timed_boundary.length > 0, "V23 string-indexing timed boundary is missing");
      requireValue(typeof indexing.publication_boundary === "string" && indexing.publication_boundary.length > 0, "V23 string-indexing publication boundary is missing");
    }
  } else if (manifest.schema_version >= 13) {
    const pending = manifest.pending_metric_panels;
    requireValue(
      pending.length === 2 &&
        same(pending[0]?.metrics || [], ["cycles", "instructions", "cache_misses", "energy_joules", "thermal_state"]) &&
        same(pending[1]?.metrics || [], ["independent_suite_results", "additional_engine_results"]) &&
        pending[0]?.issue === 503 && pending[1]?.issue === 504,
      "V13 pending metric inventory does not remove the completed issue-461 panel",
    );
  } else if (manifest.schema_version >= 12) {
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
    if (manifest.schema_version >= 14) {
      requireValue(
        same(attribution.runner_modes || [], ["attribution", "shared_attribution", "module_attribution"]),
        "V14 attribution runner-mode inventory drift",
      );
      requireValue(same(attribution.shared_lanes || [], lanes), "V14 shared attribution lanes drift");
      requireValue(
        typeof attribution.workload_coverage === "string" && attribution.workload_coverage.length > 0,
        "V14 attribution lacks complete workload coverage",
      );
    }
    if (manifest.schema_version >= 15) {
      requireValue(
        attribution.process_resident_source === "Mach task_vm_info resident_size_peak/resident_size from one snapshot",
        "V15 process resident source drift",
      );
    }
    requireValue(same(attribution.phases || [], ["configuration", "warmup", "invocation"]), "representative tier phases changed");
    const expectedMetrics = manifest.schema_version >= 13
      ? [
        "tree_walker_entries", "vm_entries", "vm_dispatches", "vm_quick_kernel_hits", "baseline_entries", "optimizer_entries",
        "optimizer_osr_entries", "deoptimizations", "runtime_operation_calls", "host_callbacks", "wasm_dispatches",
        "environment_allocations", "bytecode_admissions_by_reason", "baseline_publications", "optimizer_publications", "generated_code_bytes",
        "native_code_lifetime_by_state", "heap_live_bytes", "heap_collections", "synchronization_by_path", "worker_lifecycle",
        "context_backing_allocations", "gc_cell_allocations", "gc_pause_samples", "process_cpu_time_by_mode", "peak_rss_bytes", "retained_rss_bytes",
        "tier_up_attempts_and_time", "deoptimization_time",
        ...(manifest.schema_version >= 33 ? ["shape_transition_publication"] : []),
      ]
      : manifest.schema_version >= 12
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
    if (manifest.schema_version >= 33) {
      requireValue(attribution.artifact_schema_version === 13, "V33 attribution artifact schema drift");
      requireValue(
        same(attribution.shape_counters || [], ["transition_requests", "transition_hits", "transition_misses", "transition_lock_yields"]),
        "V33 Shape attribution counter inventory drift",
      );
      requireValue(
        typeof attribution.shape_invariant === "string" && attribution.shape_invariant.includes("requests = hits + misses"),
        "V33 Shape attribution invariant is missing",
      );
    }
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
