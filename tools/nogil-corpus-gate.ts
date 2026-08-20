/** Functional no-GIL PR-249 corpus gate checked against the published baseline. */
import { readText, run } from "./lib/home";
declare const __filename: string;
type Entry = Record<string, any>;
type Regression = {
  name: string;
  elapsed: number;
  exitCode: number | null;
  timedOut: boolean;
  diagnostics: string;
};
const FAILURE_DIAGNOSTIC_LIMIT = 8192;
function requireValue(condition: boolean, message: string): void {
  if (!condition) throw new Error(message);
}

function escapedDiagnosticText(text: string): string {
  return text
    .replace(/\r\n?/g, "\n")
    .replace(/[\u0000-\u0008\u000b\u000c\u000e-\u001f\u007f]/g, (value) =>
      `\\x${value.charCodeAt(0).toString(16).padStart(2, "0")}`,
    );
}

function labelledDiagnosticExcerpt(
  label: "stdout" | "stderr",
  text: string,
  limit: number,
): string {
  const prefix = `runner ${label} | `,
    safe = escapedDiagnosticText(text || "<empty>"),
    prefixed = safe
      .split("\n")
      .map((line) => `${prefix}${line}`)
      .join("\n");
  if (prefixed.length <= limit) return prefixed;
  const marker = `${prefix}[... middle characters omitted]`,
    payloadLength = limit - marker.length - 2 - prefix.length,
    headLength = Math.floor(payloadLength / 2),
    tailLength = payloadLength - headLength;
  let head = prefixed.slice(0, headLength);
  if (head.endsWith("\n")) head = head.slice(0, -1);
  else {
    const lastNewline = head.lastIndexOf("\n");
    if (lastNewline >= 0 && !head.slice(lastNewline + 1).startsWith(prefix))
      head = head.slice(0, lastNewline);
  }
  return `${head}\n${marker}\n${prefix}${prefixed.slice(-tailLength)}`;
}

export function failureDiagnostics(
  stdout: string,
  stderr: string,
  limit = FAILURE_DIAGNOSTIC_LIMIT,
): string {
  requireValue(limit >= 256, "failure diagnostic limit is too small");
  const streamLimit = Math.floor((limit - 1) / 2);
  return `${labelledDiagnosticExcerpt(
    "stdout",
    stdout,
    streamLimit,
  )}\n${labelledDiagnosticExcerpt("stderr", stderr, streamLimit)}`;
}

function regressionAnnotation(item: Regression): string {
  const status = item.timedOut ? "timed out" : `exit ${item.exitCode}`;
  return `::error::no-GIL regression in ${item.name} (${status}; after ${item.elapsed}s)`;
}

function selfTest(): void {
  const labelled = failureDiagnostics(
    "first\r\n::error::not-a-workflow-command\u001b",
    "panic\u0000tail",
  );
  requireValue(
    labelled.includes("runner stdout |") &&
      labelled.includes("runner stderr |") &&
      labelled.includes("\\x1b") &&
      labelled.includes("\\x00"),
    "failure diagnostics lost labels or control escaping",
  );
  requireValue(
    labelled.split("\n").every((line) => line.startsWith("runner ")),
    "failure diagnostic line can inject a workflow command",
  );
  const bounded = failureDiagnostics(
    `STDOUT_HEAD\n${"::error::spoof\n".repeat(2_000)}STDOUT_TAIL`,
    `STDERR_HEAD\n${"x".repeat(20_000)}\nSTDERR_TAIL`,
    512,
  );
  requireValue(
    bounded.length <= 512 &&
      bounded.includes("middle characters omitted") &&
      bounded.includes("STDOUT_HEAD") &&
      bounded.includes("STDOUT_TAIL") &&
      bounded.includes("STDERR_HEAD") &&
      bounded.includes("STDERR_TAIL") &&
      bounded.split("\n").every((line) => line.startsWith("runner ")),
    "failure diagnostic head/tail truncation is not bounded",
  );
  const empty = failureDiagnostics("", "");
  requireValue(
    empty.includes("runner stdout | <empty>") &&
      empty.includes("runner stderr | <empty>"),
    "empty failure diagnostics are ambiguous",
  );
  const fixture: Regression = {
    name: "fixture.js",
    elapsed: 3,
    exitCode: 7,
    timedOut: false,
    diagnostics: empty,
  };
  requireValue(
    regressionAnnotation(fixture).includes("exit 7; after 3s") &&
      regressionAnnotation({ ...fixture, exitCode: null, timedOut: true }).includes(
        "timed out; after 3s",
      ),
    "failure exit/timeout metadata is ambiguous",
  );
  console.log(
    "OK no-GIL corpus gate self-test: bounded, labelled, workflow-safe head/tail diagnostics",
  );
}

function main(): void {
  const args = process.argv.slice(2);
  if (args.length === 1 && args[0] === "--self-test") return selfTest();
  const options: any = {
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
  const regressions: Regression[] = [],
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
    } else if (expected)
      regressions.push({
        name,
        elapsed,
        exitCode: result.exitCode,
        timedOut: result.timedOut,
        diagnostics: failureDiagnostics(result.stdout, result.stderr),
      });
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
  for (const item of regressions) {
    console.log(regressionAnnotation(item));
    console.log(`runner diagnostics for ${item.name}:`);
    console.log(item.diagnostics);
  }
  requireValue(
    regressions.length === 0,
    `${regressions.length} regression(s) against ${baselinePath}`,
  );
  console.log(`\nno regressions against ${baselinePath}`);
}
if (process.argv[1] === __filename) main();
