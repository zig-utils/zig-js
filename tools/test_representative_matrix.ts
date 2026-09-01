/** Structural tests for the representative performance-matrix contract. */
import { DEFAULT_MANIFEST, loadManifest, validate } from "./representative-matrix.ts";

const original = loadManifest(DEFAULT_MANIFEST);
const clone = () => JSON.parse(JSON.stringify(original));
function rejects(name: string, mutate: (value: any) => void, pattern: string): void {
  const value = clone(); mutate(value);
  try { validate(value); } catch (error) { if (String(error).indexOf(pattern) >= 0) return; throw error; }
  throw new Error(name + ": expected validation failure containing " + pattern);
}
export function selfTest(): void {
  validate(clone());
  rejects("missing family", value => value.implemented_families.pop(), "exactly cover");
  rejects("missing dispatch", value => { value.implemented_families[0].variant = "representative_absent_variant"; }, "absent from declared source dispatch");
  rejects("missing declared source", value => { value.implemented_families[0].source = "bench/absent.js"; }, "workload source does not exist");
  rejects("checksum lanes", value => value.implemented_families[0].checksums.base.full.pop(), "checksums must match lanes");
  rejects("shared JSC", value => value.modes.shared.engines.push("JavaScriptCore"), "must not construct a JSC ratio");
  rejects("invalid shared ruling", value => { value.implemented_families[0].shared = "sometimes"; }, "invalid shared-mode ruling");
  rejects("missing capability gate", value => { value.additional_panels.find((entry: any) => entry.kind === "zig_js_capability").feature_gate.JavaScriptCore.expected = "accept"; }, "lacks an exact JavaScriptCore feature gate");
  rejects("invalid completion boundary", value => { value.implemented_families.find((entry: any) => entry.completion).completion.kind = "polling"; }, "unknown completion boundary");
  rejects("renamed checkpoint hook", value => { value.implemented_families.find((entry: any) => entry.completion).completion.checksum_hook = "readLater"; }, "generic checksum hook");
  rejects("invalid availability modes", value => { value.implemented_families.find((entry: any) => entry.availability).availability.modes.push("independent_cold"); }, "mode inventory changed");
  rejects("false JSC availability", value => { value.implemented_families.find((entry: any) => entry.availability).availability.checksums.JavaScriptCore = 1; }, "must require zig-js=1 and JavaScriptCore=0");
  rejects("missing module attribution", value => { value.implemented_families.find((entry: any) => entry.availability && entry.availability.kind === "zig_js_module_capability").availability.attribution_mode = "attribution"; }, "lacks its attribution mode");
  rejects("missing module API inventory", value => { value.implemented_families.find((entry: any) => entry.availability && entry.availability.kind === "zig_js_module_capability").availability.public_api_inventory = ""; }, "lacks its public API inventory");
  rejects("missing shared attribution runner", value => value.tier_attribution.runner_modes.splice(1, 1), "runner-mode inventory drift");
  rejects("shared attribution lanes", value => value.tier_attribution.shared_lanes.pop(), "shared attribution lanes drift");
  rejects("missing attribution coverage", value => { value.tier_attribution.workload_coverage = ""; }, "complete workload coverage");
  rejects("resident source drift", value => { value.tier_attribution.process_resident_source = "mixed APIs"; }, "process resident source drift");
  rejects("restored pending panel", value => value.pending_metric_panels.push({ issue: 503 }), "must be empty");
  rejects("missing completed panel", value => { delete value.completed_metric_panels.independent_suite; }, "completed panel inventory drift");
  rejects("efficiency source drift", value => { value.exact_parent_integration.sha256 = "0".repeat(64); value.completed_metric_panels.efficiency_thermal.scored_integration.sha256 = "0".repeat(64); }, "changed without a matrix version bump");
  rejects("independent adapter drift", value => value.completed_metric_panels.independent_suite.adapters.pop(), "adapter inventory drift");
  rejects("lifecycle scenario drift", value => value.context_lifecycle_integration.scenarios.pop(), "scenario inventory drift");
  rejects("lifecycle telemetry drift", value => value.context_lifecycle_integration.telemetry.pop(), "telemetry inventory drift");
  rejects("lifecycle runner drift", value => { value.context_lifecycle_integration.runner.sha256 = "0".repeat(64); }, "changed without a matrix version bump");
  rejects("no-JIT mode drift", value => value.no_jit_integration.modes.pop(), "mode inventory drift");
  rejects("no-JIT Context drift", value => { value.no_jit_integration.context_options.enable_jit = true; }, "Context options drift");
  rejects("no-JIT source drift", value => { value.no_jit_integration.source.sha256 = "0".repeat(64); }, "changed without a matrix version bump");
  rejects("no-JIT workload role drift", value => { value.no_jit_integration.workloads[0].role = "generic"; }, "workload role drift");
  rejects("no-JIT checksum drift", value => { value.no_jit_integration.workloads[0].checksums.full += 1; }, "checksum drift");
  rejects("no-JIT native attribution drift", value => { value.no_jit_integration.attribution.generated_code_bytes = 1; }, "attribution boundary drift");
  rejects("no-JIT required attribution drift", value => value.no_jit_integration.attribution.required_nonzero.pop(), "required attribution inventory drift");
  rejects("no-JIT timed boundary missing", value => { value.no_jit_integration.timed_boundary = ""; }, "timed boundary is missing");
  rejects("quick-binary threshold drift", value => { value.no_jit_integration.quick_binary.number_observation_threshold = 7; }, "identity/state contract drift");
  rejects("quick-binary state size drift", value => { value.no_jit_integration.quick_binary.state_bytes_per_instruction = 2; }, "identity/state contract drift");
  rejects("quick-binary generic terminal drift", value => { value.no_jit_integration.quick_binary.generic_is_terminal = false; }, "miss contract drift");
  rejects("quick-binary counter drift", value => value.no_jit_integration.quick_binary.counters.pop(), "counter inventory drift");
  rejects("quick-binary stable miss drift", value => { value.no_jit_integration.quick_binary.stable_number.number_misses = 1; }, "stable-Number attribution contract drift");
  rejects("quick-binary full attribution drift", value => { value.no_jit_integration.quick_binary.full_attribution[0].number_hits += 1; }, "full attribution drift");
  rejects("string-indexing Context drift", value => { value.string_indexing_integration.context_options.enable_jit = true; }, "Context options drift");
  rejects("string-indexing source drift", value => { value.string_indexing_integration.source.sha256 = "0".repeat(64); }, "changed without a matrix version bump");
  rejects("string-indexing runner drift", value => { value.string_indexing_integration.runner.sha256 = "0".repeat(64); }, "changed without a matrix version bump");
  rejects("string-indexing width drift", value => value.string_indexing_integration.widths.pop(), "width inventory drift");
  rejects("string-indexing representation drift", value => { value.string_indexing_integration.representations[1].role = "control"; }, "representation drift");
  rejects("string-indexing workload drift", value => { value.string_indexing_integration.workloads[0].id = "renamed"; }, "workload inventory drift");
  rejects("string-indexing checksum drift", value => { value.string_indexing_integration.workloads[0].checksums.full += 1; }, "checksum drift");
  rejects("string-indexing operation drift", value => { value.string_indexing_integration.scored_operations_per_code_unit.char_code_at = 2; }, "scored-operation inventory drift");
  rejects("string-indexing probe drift", value => value.string_indexing_integration.per_job_boundary_probes.pop(), "boundary-probe inventory drift");
  rejects("string-indexing allocation replay drift", value => value.string_indexing_integration.allocation_replay.required_exact_metrics.pop(), "allocation-replay contract drift");
  rejects("string-indexing full attribution drift", value => { value.string_indexing_integration.full_attribution[0].backing_allocations += 1; }, "full attribution drift");
  rejects("string-indexing attribution drift", value => { value.string_indexing_integration.attribution.generated_code_bytes = 1; }, "attribution boundary drift");
  rejects("string-indexing timed boundary drift", value => { value.string_indexing_integration.timed_boundary = ""; }, "timed boundary is missing");
  rejects("exact-parent integration mirror drift", value => { value.exact_parent_integration.native_allocation_replay.phase = "warmup"; }, "exact-parent integration mirror drift");
  rejects("native allocation replay phase drift", value => { value.exact_parent_integration.native_allocation_replay.phase = "warmup"; value.completed_metric_panels.efficiency_thermal.scored_integration.native_allocation_replay.phase = "warmup"; }, "native allocation replay policy drift");
  rejects("mixed replay phase boundary drift", value => { value.exact_parent_integration.native_allocation_replay.phase_boundary = "cumulative"; value.completed_metric_panels.efficiency_thermal.scored_integration.native_allocation_replay.phase_boundary = "cumulative"; }, "phase contract drift");
  rejects("mixed replay snapshot inventory drift", value => { value.exact_parent_integration.native_allocation_replay.required_snapshots.pop(); value.completed_metric_panels.efficiency_thermal.scored_integration.native_allocation_replay.required_snapshots.pop(); }, "phase contract drift");
  rejects("mixed replay signature inventory drift", value => { value.exact_parent_integration.native_allocation_replay.signature_sections.pop(); value.completed_metric_panels.efficiency_thermal.scored_integration.native_allocation_replay.signature_sections.pop(); }, "signature inventory drift");
  rejects("mixed replay contract hash drift", value => { value.exact_parent_integration.native_allocation_replay.signature_contracts[0].sha256 = "0".repeat(64); value.completed_metric_panels.efficiency_thermal.scored_integration.native_allocation_replay.signature_contracts[0].sha256 = "0".repeat(64); }, "changed without a matrix version bump");
  rejects("mixed replay contract checksum drift", value => { value.exact_parent_integration.native_allocation_replay.signature_contracts[0].checksum += 1; value.completed_metric_panels.efficiency_thermal.scored_integration.native_allocation_replay.signature_contracts[0].checksum += 1; }, "contract checksum drift");
  rejects("mixed replay legacy ruling drift", value => { value.exact_parent_integration.native_allocation_replay.legacy_vm_only = ""; value.completed_metric_panels.efficiency_thermal.scored_integration.native_allocation_replay.legacy_vm_only = ""; }, "compatibility ruling drift");
  rejects("mixed replay cross-variant ruling drift", value => { value.exact_parent_integration.native_allocation_replay.cross_variant_ruling = ""; value.completed_metric_panels.efficiency_thermal.scored_integration.native_allocation_replay.cross_variant_ruling = ""; }, "compatibility ruling drift");
  rejects("exact-parent batch concurrency drift", value => { value.exact_parent_integration.serial_batch.execution = "parallel"; value.completed_metric_panels.efficiency_thermal.scored_integration.serial_batch.execution = "parallel"; }, "exact-parent batch policy drift");
  rejects("direct binary provenance drift", value => { value.exact_parent_integration.binary_provenance_profiles.schema_v2 = "unchecked"; value.completed_metric_panels.efficiency_thermal.scored_integration.binary_provenance_profiles.schema_v2 = "unchecked"; }, "binary provenance profile drift");
  rejects("inherited overlay provenance drift", value => { value.exact_parent_integration.shared_measurement_overlay.changed_subset = "any"; value.completed_metric_panels.efficiency_thermal.scored_integration.shared_measurement_overlay.changed_subset = "any"; }, "V31 shared measurement overlay policy drift");
  rejects("frontend native runner drift", value => { value.exact_parent_integration.native_runners[1].sha256 = "0".repeat(64); value.completed_metric_panels.efficiency_thermal.scored_integration.native_runners[1].sha256 = "0".repeat(64); }, "changed without a matrix version bump");
  rejects("unsupported future matrix", value => { value.schema_version = 32; }, "unsupported representative matrix schema");
  console.log("representative matrix structural tests: 66/66 passed");
}

if (process.argv[1] === __filename) selfTest();
