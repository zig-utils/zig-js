/** Regenerate docs/.data/test262.json from a real or saved conformance run. */
import { readText, run, writeText } from "../tools/lib/home";

const script = process.argv[1].replace(/\\/g, "/"), suffix = "/scripts/gen-test262-data.ts";
const root = script.endsWith(suffix) ? script.slice(0, -suffix.length) : process.cwd();
let outputPath = root + "/docs/.data/test262.json";
const outputIndex = process.argv.indexOf("--output");
if (outputIndex >= 0) {
  if (!process.argv[outputIndex + 1]) throw new Error("--output requires a path");
  outputPath = process.argv[outputIndex + 1];
}
function getOutput(): string {
  const index = process.argv.indexOf("--from");
  if (index >= 0) {
    if (!process.argv[index + 1]) throw new Error("--from requires a saved transcript path");
    return readText(process.argv[index + 1]);
  }
  if (process.cwd().replace(/\/$/, "") !== root) throw new Error("run the live test262 collection from the zig-js repository root");
  const pantry = (process.env.HOME || "") + "/.local/share/pantry/global/bin/zig";
  const zig = process.env.ZIG || (Home.fileExists(pantry) ? pantry : "zig");
  console.error(`Running: ${zig} build test262 -Doptimize=ReleaseFast (this can take a while)…`);
  const result = run([zig, "build", "test262", "-Doptimize=ReleaseFast"]);
  if (result.exitCode !== 0) throw new Error("test262 command failed:\n" + result.stderr);
  return result.stdout + "\n" + result.stderr;
}
function parse(text: string): any {
  const percentage = (passing: number, total: number) => total === 0 ? 0 : Number(((passing / total) * 100).toFixed(2));
  const valid = text.match(/VALID[^:]*:\s*(\d+)\/(\d+)\s*\(([\d.]+)%\)(?:[^\n]*parse-fail\s*(\d+)[^\n]*runtime-fail\s*(\d+)[^\n]*host-fail\s*(\d+))?/i);
  const negative = text.match(/NEGATIVE[^:]*:\s*(\d+)\/(\d+)\s*\(([\d.]+)%\)/i), skipped = text.match(/skipped[^:]*:\s*(\d+)/i);
  if (!valid) throw new Error("Could not find VALID summary line in test262 output. Pass --from <file> with the run output.");
  const suites: any[] = [], suite = /test\/(.+?):\s*valid\s*(\d+)\/(\d+)\s*\(([\d.]+)%\)(?:\s*\[parse-fail\s*(\d+)[^\]]*runtime-fail\s*(\d+)[^\]]*host-fail\s*(\d+)\])?/gi;
  let match: RegExpExecArray | null;
  while ((match = suite.exec(text)) !== null) {
    const passing = Number(match[2]), total = Number(match[3]), row: any = { name: match[1], passing, total, percentage: percentage(passing, total) };
    if (match[5] !== undefined) { row.parseFail = Number(match[5]); row.runtimeFail = Number(match[6]); row.hostFail = Number(match[7]); }
    suites.push(row);
  }
  const passing = Number(valid[1]), total = Number(valid[2]), validRow: any = { passing, total, percentage: percentage(passing, total) };
  if (valid[4] !== undefined) { validRow.parseFail = Number(valid[4]); validRow.runtimeFail = Number(valid[5]); validRow.hostFail = Number(valid[6]); }
  const negativePassing = negative ? Number(negative[1]) : 0, negativeTotal = negative ? Number(negative[2]) : 0;
  return { valid: validRow, negative: { passing: negativePassing, total: negativeTotal, percentage: percentage(negativePassing, negativeTotal) }, skipped: skipped ? Number(skipped[1]) : 0, generatedAt: new Date().toISOString().slice(0, 10), harness: "real (pinned tc39/test262 submodule)", suites };
}
const data = parse(getOutput());
writeText(outputPath, JSON.stringify(data, null, 2) + "\n");
console.error(`Wrote ${outputPath}: VALID ${data.valid.passing}/${data.valid.total} (${data.valid.percentage}%), ${data.suites.length} suites.`);
