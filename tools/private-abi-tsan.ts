/** Reject private-ABI executables that omit the selected TSan mode. */
import { readText } from "./lib/home";

const script = process.argv[1].replace(/\\/g, "/");
const suffix = "/tools/private-abi-tsan.ts";
const root = script.endsWith(suffix) ? script.slice(0, -suffix.length) : process.cwd();
const source = readText(root + "/build.zig");
const links = /^    (\w+)\.root_module\.linkLibrary\((home_private_lib|bun_private_lib)\);/gm;
const checked: string[][] = [], missing: string[] = [];
let match: RegExpExecArray | null;
while ((match = links.exec(source)) !== null) {
  const name = match[1], profile = match[2];
  const start = source.lastIndexOf(`    const ${name} = b.addExecutable(.{`, match.index);
  if (start < 0) throw new Error(`private ABI TSan audit: cannot find executable definition for ${name}`);
  const definition = source.slice(start, match.index + match[0].length);
  checked.push([name, profile]);
  if (definition.indexOf(".sanitize_thread = tsan") < 0) missing.push(name);
}
const home = checked.filter(row => row[1] === "home_private_lib").length;
const bun = checked.filter(row => row[1] === "bun_private_lib").length;
if (home !== 14 || bun !== 22) throw new Error(`private ABI TSan audit: fixture inventory drift: Home=${home}, Bun=${bun}`);
if (missing.length) throw new Error("private ABI TSan audit: missing propagation: " + missing.join(", "));
console.log(`Private ABI TSan audit: ${checked.length}/${checked.length} executables propagate -Dtsan`);
