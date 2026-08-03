/** Inspect and safely prune only zig-js's reproducible local build outputs. */
import { run } from "./lib/home";

const script = process.argv[1].replace(/\\/g, "/");
const scriptDir = script.indexOf("/") >= 0 ? script.slice(0, script.lastIndexOf("/")) : ".";
const git = run(["git", "-C", scriptDir, "rev-parse", "--show-toplevel"]);
if (git.exitCode !== 0) throw new Error("not inside a git repository (run from the zig-js checkout)");
const root = git.stdout.trim().replace(/\/$/, "");
const cache = root + "/.zig-cache", output = root + "/zig-out";
const targets = [cache, output];
function size(paths: string[]): string {
  const existing = paths.filter(path => Home.fileExists(path));
  if (existing.length === 0) return "0B";
  const result = run(["du", "-sh", "-c"].concat(existing));
  if (result.exitCode !== 0) throw new Error(result.stderr || "cannot inspect cache size");
  const rows = result.stdout.trim().split("\n");
  return rows[rows.length - 1].trim().split(/\s+/)[0];
}
function assertTarget(path: string): void {
  if (path !== cache && path !== output) throw new Error("refusing to touch a path outside the repo cache/build outputs: " + path);
  const parent = path.slice(0, path.lastIndexOf("/"));
  const resolved = run(["realpath", parent]);
  if (resolved.exitCode !== 0 || resolved.stdout.trim() !== root) throw new Error("refusing unresolved repository output: " + path);
}
function report(): void {
  console.log("repository: " + root + "\n");
  if (Home.fileExists(cache)) {
    console.log(".zig-cache total: " + size([cache]));
    for (const name of ["o", "tmp", "h", "z", "c"]) if (Home.fileExists(cache + "/" + name)) console.log(`  ${(name + "/").padEnd(4)} ${size([cache + "/" + name])}`);
    const objectDir = cache + "/o";
    if (Home.fileExists(objectDir)) {
      const found = run(["find", objectDir, "-mindepth", "1", "-maxdepth", "1", "-type", "d", "-exec", "du", "-sk", "{}", "+"]);
      if (found.exitCode === 0 && found.stdout.trim()) {
        console.log("\n  largest o/ artifacts (compiled test/exe outputs — the reproducible bulk):");
        const rows = found.stdout.trim().split("\n").map(line => ({ line: line.trim(), size: Number(line.trim().split(/\s+/)[0]) })).sort((a, b) => b.size - a.size).slice(0, 8);
        for (const row of rows) console.log("    " + row.line);
      }
    }
  } else console.log(".zig-cache: (none)");
  console.log("");
  console.log(Home.fileExists(output) ? "zig-out total: " + size([output]) : "zig-out: (none)");
  console.log("\nreclaimable now: " + size(targets));
  console.log("run 'home-tool run tools/zig-cache-tool.ts prune' to reclaim it.");
}
function prune(args: string[]): void {
  let dryRun = false;
  for (const argument of args) {
    if (argument === "--dry-run") dryRun = true;
    else if (argument !== "--all") throw new Error("unknown prune option: " + argument);
  }
  const reclaim = size(targets);
  console.log("would reclaim: " + reclaim);
  for (const target of targets) {
    assertTarget(target);
    if (!Home.fileExists(target)) continue;
    if (dryRun) console.log("  [dry-run] rm -rf " + target);
    else {
      console.log("  removing " + target);
      const removed = run(["rm", "-rf", "--", target]);
      if (removed.exitCode !== 0) throw new Error(removed.stderr || "cache removal failed");
    }
  }
  console.log(dryRun ? "dry run: nothing was deleted." : `done. reclaimed ~${reclaim} (rebuilds are fully reproducible).`);
}
const command = process.argv[2] || "report";
if (command === "report") report();
else if (command === "prune") prune(process.argv.slice(3));
else if (command === "help" || command === "-h" || command === "--help") console.log("usage: home-tool run tools/zig-cache-tool.ts report | prune [--dry-run]");
else throw new Error(`unknown command: ${command} (expected: report | prune | help)`);
