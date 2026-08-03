/** Verify revision-pinned consumer ABI profiles against zig-js exports. */
import { checked, readText, sha256File } from "./lib/home";
declare const __dirname: string;
const ROOT = __dirname === "tools" ? "." : __dirname.slice(0, __dirname.lastIndexOf("/tools"));
const join = (left: string, right: string): string => `${left.replace(/\/$/, "")}/${right}`;
const PROFILES: Record<string, string> = { "home-public-c-7ed99c02": join(ROOT, "docs/abi/home-public-c-7ed99c02.json") };
const FIXTURES: Record<string, string> = { "home-public-c-7ed99c02": join(ROOT, "tests/abi/home_public_c_7ed99c02.zig") };
const fail = (message: string): never => { throw new Error(`ABI profile audit: ${message}`); };
const matchDeclarations = (file: string): Record<string, string> => {
  const result: Record<string, string> = {}, pattern = /^(?:pub )?extern "c" fn ([A-Za-z_][A-Za-z0-9_]*)(.*);$/gm;
  let match: RegExpExecArray | null;
  while ((match = pattern.exec(readText(file))) !== null) { if (result[match[1]]) fail(`duplicate extern declaration ${match[1]} in ${file}`); result[match[1]] = match[2].trim().replace(/\s+/g, " "); }
  return result;
};
const exportedNames = (file: string): string[] => { const out: string[] = [], pattern = /^export fn ([A-Za-z_][A-Za-z0-9_]*)\s*\(/gm; let match: RegExpExecArray | null; const text = readText(file); while ((match = pattern.exec(text)) !== null) out.push(match[1]); return out; };

let profile = "home-public-c-7ed99c02", homeRoot = "";
const args = process.argv.slice(2);
for (let index = 0; index < args.length; index += 1) {
  if (args[index] === "--profile" && args[index + 1]) profile = args[++index];
  else if (args[index] === "--home-root" && args[index + 1]) homeRoot = args[++index];
  else fail(`unknown argument: ${args[index]}`);
}
if (!PROFILES[profile]) fail(`unsupported profile ${JSON.stringify(profile)}; supported=${JSON.stringify(Object.keys(PROFILES).sort())}`);
const data = JSON.parse(readText(PROFILES[profile]));
if (data.schema_version !== 1 || data.profile_id !== profile) fail("profile schema or identity mismatch");
if (data.kind !== "public_c_embedding") fail("Home public profile must not be classified as a private ABI shim");
if (data.abi.calling_convention !== "C") fail("unsupported calling convention");
const names = data.functions;
if (!Array.isArray(names) || names.length !== 50 || new Set(names).size !== names.length) fail("Home profile must contain 50 unique functions");
const fixture = matchDeclarations(FIXTURES[profile]), fixtureNames = Object.keys(fixture);
const fixtureMissing = names.filter((name: string) => !fixtureNames.includes(name)).sort(), fixtureExtra = fixtureNames.filter((name) => !names.includes(name)).sort();
if (fixtureMissing.length || fixtureExtra.length) fail(`fixture/profile drift; missing=${JSON.stringify(fixtureMissing)}, extra=${JSON.stringify(fixtureExtra)}`);
const zigExports = exportedNames(join(ROOT, "src/c_api.zig")), missing = names.filter((name: string) => !zigExports.includes(name)).sort();
if (missing.length) fail(`zig-js exports are missing ${JSON.stringify(missing)}`);
const enums = data.abi.enums;
if (enums.JSType.backing !== "c_uint" || enums.JSTypedArrayType.backing !== "c_uint") fail("enum backing-type drift");
if (enums.JSType.values.kJSTypeBigInt !== 7) fail("JSType value drift");
if (enums.JSTypedArrayType.values.kJSTypedArrayTypeBigUint64Array !== 12) fail("JSTypedArrayType value drift");
if (!Array.isArray(data.semantic_assumptions) || data.semantic_assumptions.length < 5) fail("semantic assumption inventory is incomplete");
if (homeRoot) {
  const actualRevision = checked(["git", "-C", homeRoot, "rev-parse", "HEAD"], `cannot read Home revision at ${homeRoot}`).trim(), consumer = data.consumer;
  if (actualRevision !== consumer.revision) fail(`Home revision mismatch: ${actualRevision} != ${consumer.revision}`);
  for (const relative of Object.keys(consumer.sources)) { const actual = sha256File(join(homeRoot, relative)); if (actual !== consumer.sources[relative]) fail(`Home source digest mismatch for ${relative}: ${actual} != ${consumer.sources[relative]}`); }
  const sourceDeclarations = matchDeclarations(join(homeRoot, "packages/runtime/src/jsc/extern_fns.zig")), sourceNames = Object.keys(sourceDeclarations);
  const sourceMissing = fixtureNames.filter((name) => !sourceNames.includes(name)).sort(), sourceExtra = sourceNames.filter((name) => !fixtureNames.includes(name)).sort(), changed = fixtureNames.filter((name) => sourceNames.includes(name) && fixture[name] !== sourceDeclarations[name]).sort();
  if (sourceMissing.length || sourceExtra.length || changed.length) fail(`Home declaration drift; missing=${JSON.stringify(sourceMissing)}, extra=${JSON.stringify(sourceExtra)}, changed=${JSON.stringify(changed)}`);
}
console.log(`ABI profile audit: ${profile}: 50/50 exports${homeRoot ? " and pinned Home source" : ""}; zero missing`);
