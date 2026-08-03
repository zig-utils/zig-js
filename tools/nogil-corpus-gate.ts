/** Functional no-GIL PR-249 corpus gate checked against the published baseline. */
import { readText, run } from "./lib/home";
declare const __filename: string;
type Entry = Record<string, any>;
function requireValue(condition: boolean, message: string): void {
  if (!condition) throw new Error(message);
}
function main(): void {
  const args = process.argv.slice(2),
    options: any = {
      shard: 0,
      shards: 1,
      deadline: 600,
      binary: "./zig-out/bin/threads-test",
      buildMode: "debug",
    };
  for (let index = 0; index < args.length; index += 1) {
    const name = args[index],
      value = args[++index];
    if (name === "--shard") options.shard = Number(value);
    else if (name === "--shards") options.shards = Number(value);
    else if (name === "--deadline") options.deadline = Number(value);
    else if (name === "--binary") options.binary = value;
    else if (name === "--build-mode") options.buildMode = value;
    else throw new Error(`unknown argument: ${name}`);
  }
  requireValue(
    Number.isInteger(options.shard) &&
      Number.isInteger(options.shards) &&
      options.shards > 0 &&
      options.shard >= 0 &&
      options.shard < options.shards,
    "--shard must select one valid zero-based shard",
  );
  requireValue(
    Number.isInteger(options.deadline) && options.deadline > 0,
    "--deadline must be a positive integer",
  );
  requireValue(
    ["debug", "releasesafe"].includes(options.buildMode),
    "--build-mode must be debug or releasesafe",
  );
  const baselinePath = "docs/.data/pr249-execution-nogil.json",
    document = JSON.parse(readText(baselinePath)),
    baseline: Record<string, Entry> = {};
  document.cases.forEach((entry: Entry) => (baseline[entry.case] = entry));
  const expectsPass = (name: string): boolean => {
    const entry = baseline[name];
    if (!entry) return true;
    if (
      entry.modes &&
      typeof entry.modes === "object" &&
      entry.modes[options.buildMode]
    )
      return entry.modes[options.buildMode].result === "pass";
    return (entry.result || "pass") === "pass";
  };
  const listing = run([options.binary, "parallel-js", "list"]),
    cases = (listing.stdout + listing.stderr)
      .split("\n")
      .map((name) => name.trim())
      .filter((name) => name.endsWith(".js"));
  requireValue(cases.length > 0, "could not read the parallel-js case list");
  const mine = cases.filter(
    (_, index) => index % options.shards === options.shard,
  );
  console.log(
    `shard ${options.shard}/${options.shards}: ${mine.length} of ${cases.length} cases, ${options.deadline}s deadline, ${options.buildMode} expectations`,
  );
  const regressions: any[][] = [],
    known: string[] = [],
    improved: string[] = [];
  let passed = 0;
  for (const name of mine) {
    const started = Date.now(),
      result = run([options.binary, "parallel-js", "one", name], {
        timeoutMs: options.deadline * 1000,
      }),
      ok = !result.timedOut && result.exitCode === 0,
      elapsed = Math.floor((Date.now() - started) / 1000),
      expected = expectsPass(name);
    if (ok) {
      passed += 1;
      if (!expected) improved.push(name);
    } else if (expected) regressions.push([name, elapsed]);
    else known.push(name);
  }
  console.log(`\npassed ${passed}/${mine.length}`);
  for (const name of known) {
    const entry = baseline[name] || {},
      note = (entry.modes && entry.modes[options.buildMode]) || {},
      why = note.note || entry.note || "";
    console.log(
      `::notice::known non-passing under no-GIL (${options.buildMode}): ${name}${why ? ` — ${why}` : ""}`,
    );
  }
  improved.forEach((name) =>
    console.log(`::notice::now passes, baseline is stale: ${name}`),
  );
  regressions.forEach((item) =>
    console.log(`::error::no-GIL regression in ${item[0]} (after ${item[1]}s)`),
  );
  requireValue(
    regressions.length === 0,
    `${regressions.length} regression(s) against ${baselinePath}`,
  );
  console.log(`\nno regressions against ${baselinePath}`);
}
if (process.argv[1] === __filename) main();
