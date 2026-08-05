/** Structural tests for the representative performance-matrix contract. */
import { DEFAULT_MANIFEST, loadManifest, validate } from "./representative-matrix.ts";

const original = loadManifest(DEFAULT_MANIFEST);
const clone = () => JSON.parse(JSON.stringify(original));
function rejects(name: string, mutate: (value: any) => void, pattern: string): void {
  const value = clone(); mutate(value);
  try { validate(value); } catch (error) { if (String(error).indexOf(pattern) >= 0) return; throw error; }
  throw new Error(name + ": expected validation failure containing " + pattern);
}
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
console.log("representative matrix structural tests: 17/17 passed");
