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
rejects("missing family", value => value.deferred_families.pop(), "exactly cover");
rejects("missing dispatch", value => { value.implemented_families[0].variant = "representative_absent_variant"; }, "absent from declared source dispatch");
rejects("missing declared source", value => { value.implemented_families[0].source = "bench/absent.js"; }, "workload source does not exist");
rejects("checksum lanes", value => value.implemented_families[0].checksums.base.full.pop(), "checksums must match lanes");
rejects("shared JSC", value => value.modes.shared.engines.push("JavaScriptCore"), "must not construct a JSC ratio");
rejects("invalid shared ruling", value => { value.implemented_families[0].shared = "sometimes"; }, "invalid shared-mode ruling");
rejects("missing capability gate", value => { value.additional_panels.find((entry: any) => entry.kind === "zig_js_capability").feature_gate.JavaScriptCore.expected = "accept"; }, "lacks an exact JavaScriptCore feature gate");
console.log("representative matrix structural tests: 8/8 passed");
