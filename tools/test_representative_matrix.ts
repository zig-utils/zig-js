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
rejects("missing dispatch", value => { value.implemented_families[0].variant = "representative_absent_variant"; }, "absent from representative source dispatch");
rejects("checksum lanes", value => value.implemented_families[0].checksums.base.full.pop(), "checksums must match lanes");
rejects("shared JSC", value => value.modes.shared.engines.push("JavaScriptCore"), "must not construct a JSC ratio");
console.log("representative matrix structural tests: 5/5 passed");
