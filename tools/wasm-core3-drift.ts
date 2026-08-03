/** Report WebAssembly spec main drift from zig-js's accepted Core 3 pin. */
import { run, writeText } from "./lib/home";

const baseTag = "wg-3.0", baseCommit = "9d36019973201a19f9c9ebb0f10828b2fe2374aa";
const script = process.argv[1].replace(/\\/g, "/"), suffix = "/tools/wasm-core3-drift.ts";
const root = script.endsWith(suffix) ? script.slice(0, -suffix.length) : process.cwd();
function git(repo: string, args: string[]): string {
  const result = run(["git", "-C", repo].concat(args));
  if (result.exitCode !== 0) throw new Error(result.stderr || "git command failed");
  return result.stdout.trim();
}
const corpusFiles = (repo: string, revision: string) => git(repo, ["ls-tree", "-r", "--name-only", revision, "--", "test/core"]).split("\n").filter(path => path.endsWith(".wast")).sort();
let repo = root + "/wasm-spec-wg3", upstreamRef = "origin/main", output = "";
for (let index = 2; index < process.argv.length; index += 1) {
  const argument = process.argv[index], value = process.argv[++index];
  if (!value) throw new Error(argument + " requires a value");
  if (argument === "--spec-root") repo = value;
  else if (argument === "--upstream-ref") upstreamRef = value;
  else if (argument === "--output") output = value;
  else throw new Error("unknown argument: " + argument);
}
const pinned = git(repo, ["rev-parse", "HEAD"]);
if (pinned !== baseCommit) throw new Error(`Core 3 submodule pin drift: expected ${baseCommit}, found ${pinned}`);
if (git(repo, ["rev-parse", `${baseTag}^{commit}`]) !== baseCommit) throw new Error(`Core 3 tag drift: ${baseTag} does not resolve to ${baseCommit}`);
const upstream = git(repo, ["rev-parse", `${upstreamRef}^{commit}`]);
const baseFiles = corpusFiles(repo, baseCommit), upstreamFiles = corpusFiles(repo, upstream), changes: any[] = [];
for (const line of git(repo, ["diff", "--name-status", "--find-renames", baseCommit, upstream, "--", "test/core"]).split("\n")) {
  if (!line) continue;
  const fields = line.split("\t"), entry: any = { status: fields[0], path: fields[fields.length - 1] };
  if (fields.length === 3) entry.previous_path = fields[1];
  changes.push(entry);
}
const baseSet = new Set(baseFiles), upstreamSet = new Set(upstreamFiles);
const report = { schema_version: 1, kind: "webassembly_core_3_upstream_drift", accepted: { tag: baseTag, commit: baseCommit, corpus_files: baseFiles.length }, upstream: { ref: upstreamRef, commit: upstream, corpus_files: upstreamFiles.length }, core_test_diff: { changed_files: changes.length, added_files: upstreamFiles.filter(path => !baseSet.has(path)).length, removed_files: baseFiles.filter(path => !upstreamSet.has(path)).length, entries: changes }, accepted_score_changed: false };
function sortKeys(value: any): any { if (Array.isArray(value)) return value.map(sortKeys); if (value && typeof value === "object") { const out: any = {}; for (const key of Object.keys(value).sort()) out[key] = sortKeys(value[key]); return out; } return value; }
const rendered = JSON.stringify(sortKeys(report), null, 2) + "\n";
if (output) { const slash = output.lastIndexOf("/"); if (slash > 0) { const made = run(["mkdir", "-p", output.slice(0, slash)]); if (made.exitCode !== 0) throw new Error(made.stderr); } writeText(output, rendered); }
process.stdout.write(rendered);
