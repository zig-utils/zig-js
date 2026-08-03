/** Append object files to an existing static library without parsing Mach-O. */
import { run } from "./lib/home";

const args = process.argv.slice(2);
if (args.length < 3) throw new Error("usage: merge-static-library.ts OUTPUT BASE OBJECT...");
const output = args[0], base = args[1], objects = args.slice(2);
const slash = output.lastIndexOf("/");
if (slash > 0) {
  const made = run(["mkdir", "-p", output.slice(0, slash)]);
  if (made.exitCode !== 0) throw new Error(made.stderr || "cannot create archive output directory");
}
const copied = run(["cp", base, output]);
if (copied.exitCode !== 0) throw new Error(copied.stderr || "cannot copy base archive");
const archived = run(["xcrun", "ar", "-q", output].concat(objects));
if (archived.exitCode !== 0) throw new Error(archived.stderr || "cannot append archive members");
const indexed = run(["xcrun", "ranlib", output]);
if (indexed.exitCode !== 0) throw new Error(indexed.stderr || "cannot index merged archive");
