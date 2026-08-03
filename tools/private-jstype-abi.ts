/** Generate and verify revision-pinned Home/Bun private JSType layouts. */
import { readText, run, writeText } from "./lib/home";

declare const __dirname: string;
const ROOT = __dirname === "tools" ? "." : __dirname.slice(0, __dirname.lastIndexOf("/tools"));
const join = (left: string, right: string): string => `${left.replace(/\/$/, "")}/${right}`;
const OUTPUT = join(ROOT, "docs/abi/private-jstype-layouts.json");
const HOME_SOURCE = "packages/runtime/src/jsc/JSType.zig", BUN_SOURCE = "src/jsc/JSType.zig";
const HOME_REVISIONS = ["7ed99c02e50034f869d0db6d487115bb44332fe4", "5e829ad483bb9e5ccb19766997df6462edd8e167", "38702f9e43b3aecbee7d5b7aa48cc66d41cabde7"];
const BUN_REVISION = "4982b91e3702094330f3be3883354c52b8c01323";
const HOME_SHA = "93abf0de1e71007acea7d2b41da258130d676be1d94494d5a572da511b9299dc", BUN_SHA = "34370d4e5230020e38d162fd0e2f047160bf94a1408670cedde168ca2b6555ee";
const ENUM_START = "pub const JSType = enum(u8) {";
const fail = (message: string): never => { throw new Error(`private JSType ABI audit: ${message}`); };
const checked = (argv: string[], phase: string): string => { const result = run(argv); if (result.exitCode !== 0) fail(`${phase}: ${result.stderr.trim() || result.stdout.trim()}`); return result.stdout; };
const revision = (root: string): string => checked(["git", "-C", root, "rev-parse", "HEAD"], `cannot determine revision at ${root}`).trim();
const sha256 = (file: string): string => checked(["shasum", "-a", "256", file], `cannot hash ${file}`).trim().split(/\s+/)[0];

function parse(file: string): Record<string, number> {
  const source = readText(file);
  if (source.split(ENUM_START).length !== 2) fail(`expected exactly one JSType enum in ${file}`);
  const body = source.split(ENUM_START)[1].split("\n    _,")[0], members: Record<string, number> = {};
  const pattern = /^    ([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(\d+),\s*$/gm;
  let match: RegExpExecArray | null, found = 0;
  while ((match = pattern.exec(body)) !== null) { members[match[1]] = Number.parseInt(match[2], 10); found += 1; }
  if (!found || Object.keys(members).length !== found) fail(`duplicate or empty JSType members in ${file}`);
  const values = Object.values(members).sort((a, b) => a - b);
  if (values.some((value, index) => value !== index)) fail(`JSType values are not contiguous from zero in ${file}`);
  return members;
}

function sourceRecord(root: string, source: string, revisions: string[], expectedSha: string): any {
  const actualRevision = revision(root);
  if (!revisions.includes(actualRevision)) fail(`unsupported revision ${actualRevision} at ${root}`);
  const file = join(root, source), digest = sha256(file);
  if (digest !== expectedSha) fail(`source digest mismatch for ${file}: ${digest}`);
  return { revision: actualRevision, source, source_sha256: digest, members: parse(file) };
}

function comparison(home: Record<string, number>, bun: Record<string, number>): any {
  const homeNames = Object.keys(home), bunNames = Object.keys(bun), shared = homeNames.filter((name) => bunNames.includes(name)).sort();
  return {
    shared_members: shared.length,
    home_only: homeNames.filter((name) => !bunNames.includes(name)).sort(),
    bun_only: bunNames.filter((name) => !homeNames.includes(name)).sort(),
    renumbered: shared.filter((name) => home[name] !== bun[name]).map((name) => ({ name, home: home[name], bun: bun[name] })),
  };
}

function generate(homeRoot: string, bunRoot: string): any {
  const home = sourceRecord(homeRoot, HOME_SOURCE, HOME_REVISIONS, HOME_SHA), bun = sourceRecord(bunRoot, BUN_SOURCE, [BUN_REVISION], BUN_SHA);
  return { schema_version: 1, kind: "private_jstype_layouts", profiles: { home, bun }, comparison: comparison(home.members, bun.members) };
}

function validate(data: any): void {
  if (data.schema_version !== 1 || data.kind !== "private_jstype_layouts") fail("schema or kind mismatch");
  const names = Object.keys(data.profiles || {}).sort();
  if (JSON.stringify(names) !== JSON.stringify(["bun", "home"])) fail("expected exactly the home and bun profiles");
  const home = data.profiles.home, bun = data.profiles.bun;
  if (!HOME_REVISIONS.includes(home.revision) || bun.revision !== BUN_REVISION) fail("stored revision mismatch");
  if (home.source !== HOME_SOURCE || bun.source !== BUN_SOURCE) fail("stored source path mismatch");
  if (home.source_sha256 !== HOME_SHA || bun.source_sha256 !== BUN_SHA) fail("stored source digest mismatch");
  for (const name of ["home", "bun"]) {
    const profile = data.profiles[name], values = Object.values(profile.members || {}).sort((a: any, b: any) => a - b);
    if (!values.length || values.some((value: any, index: number) => value !== index)) fail(`stored ${name} members are not contiguous from zero`);
    if (!/^[0-9a-f]{64}$/.test(String(profile.source_sha256 || ""))) fail(`stored ${name} source digest is invalid`);
  }
  if (JSON.stringify(data.comparison) !== JSON.stringify(comparison(home.members, bun.members))) fail("stored Home/Bun comparison drift");
}

let homeRoot = "", bunRoot = "", write = false;
const args = process.argv.slice(2);
for (let index = 0; index < args.length; index += 1) {
  if (args[index] === "--home-root" && args[index + 1]) homeRoot = args[++index];
  else if (args[index] === "--bun-root" && args[index + 1]) bunRoot = args[++index];
  else if (args[index] === "--write") write = true;
  else fail(`unknown argument: ${args[index]}`);
}
if (write && (!homeRoot || !bunRoot)) fail("--write requires --home-root and --bun-root");
if (!!homeRoot !== !!bunRoot) fail("live verification requires both --home-root and --bun-root");
if (homeRoot) {
  const generated = generate(homeRoot, bunRoot);
  if (write) writeText(OUTPUT, JSON.stringify(generated, null, 2) + "\n");
  else if (JSON.stringify(generated) !== JSON.stringify(JSON.parse(readText(OUTPUT)))) fail("checked-in layouts differ from the pinned consumer sources");
}
const stored = JSON.parse(readText(OUTPUT));
validate(stored);
console.log(`private JSType ABI audit: Home=${Object.keys(stored.profiles.home.members).length}, Bun=${Object.keys(stored.profiles.bun.members).length}, shared=${stored.comparison.shared_members}, Bun-only=${stored.comparison.bun_only.length}, renumbered=${stored.comparison.renumbered.length}`);
