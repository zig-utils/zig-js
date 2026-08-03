/** Acquire the pinned WebAssembly wg-1.0 specification corpus. */
import { run } from "../lib/home";

const revision = "977f97014c962f7bd1291fcc6d28b41a924882bf";
const checksum = "492f9a90dda9536d687746185f329c96a35226e5386ff82b331098d9070179a2";
const output = process.argv[2];
if (!output) throw new Error("usage: fetch.ts <out-dir>");
if (output === "/" || output === "." || output === ".." || output[0] === "-") throw new Error("refusing unsafe output directory: " + output);
const archive = `/tmp/zig-js-wasm-spec-${revision}.tar.gz`;
function checked(argv: string[], phase: string): string {
  const result = run(argv);
  if (result.exitCode !== 0) throw new Error(`${phase} failed: ${result.stderr || result.stdout}`);
  return result.stdout;
}
checked(["mkdir", "-p", output], "create output directory");
checked(["curl", "--fail", "--location", "--silent", "--show-error", "--output", archive, `https://github.com/WebAssembly/spec/archive/${revision}.tar.gz`], "download pinned specification");
const actual = checked(["shasum", "-a", "256", archive], "checksum specification").trim().split(/\s+/)[0];
if (actual !== checksum) throw new Error(`WebAssembly/spec checksum mismatch: expected ${checksum}, got ${actual}`);
checked(["tar", "-xzf", archive, "--strip-components=1", "-C", output], "extract pinned specification");
checked(["rm", "-f", archive], "remove acquisition archive");
console.log(`fetched WebAssembly/spec@${revision} (wg-1.0) into ${output}`);
