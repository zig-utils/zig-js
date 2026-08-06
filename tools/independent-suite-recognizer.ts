/** Prove that independent-suite execution is not selected by exact source identity (#504). */
import { ROWS, expectedArgv, validateChild, type SourceVariant } from "./independent-suite-collector";
import { checked, run, writeText } from "./lib/home";

declare const __filename: string;

const STATIC_TOKENS = [
  "octane-2-retired",
  "570ad1ccfe86e3eecba0636c8f932ac08edec517",
  "e40d5c8489d05e384f32ed064d1f5286e9c236f3",
  "216612c2e7096a02b3e52b57e9cf9351bbaf180d60938d5c60b85fd756232733",
  "1246a64a24b931158bf01c24640343259fa74b0226e73bad630bd1f686aa0fa7",
  "a292d6047900c5296ea9e2628453832cc3bfe397e49fddade8aff7b5876c8263",
  "f9a6a60d8f205908f5542ad1180abc1902dcdab3dcb4278017c5ce179ee123f7",
  "27926de809451c60b0c49a4185c08f97081310d0db166a30c1d202fb656556a2",
  "83b10c280f004e7b156a9e04d09ce4109892ea92788f7c6c963f7fadf29c7bd4",
  "BenchmarkSuite.RunSingleBenchmark",
  "NavierStokes",
  "SplayLatency",
];

function requireValue(condition: boolean, message: string): void {
  if (!condition) throw new Error(message);
}

function nonzeroNames(counters: any[]): string[] {
  requireValue(Array.isArray(counters), "tier counter inventory is missing");
  return counters.filter((counter) => Number(counter.value) > 0).map((counter) => String(counter.name)).sort();
}

export function tierSignature(child: any): any {
  requireValue(child.tier_attribution?.status === "measured", "recognizer child lacks tier attribution");
  return {
    execution: nonzeroNames(child.tier_attribution.execution),
    admissions: nonzeroNames(child.tier_attribution.admissions),
  };
}

function comparePair(row: string, exact: any, variant: any): any {
  const exactSignature = tierSignature(exact), variantSignature = tierSignature(variant);
  requireValue(JSON.stringify(exactSignature) === JSON.stringify(variantSignature), `${row} exact/mutated tier signature drift`);
  for (let index = 0; index < exact.adapter.loaded_sources.length; index += 1)
    requireValue(exact.adapter.loaded_sources[index].evaluated_sha256 !== variant.adapter.loaded_sources[index].evaluated_sha256, `${row} source ${index} mutation did not change evaluated SHA-256`);
  return { status: "equivalent", exact: exactSignature, anti_specialization: variantSignature };
}

function parseChild(stdout: string, label: string): any {
  const lines = stdout.split("\n").filter((line) => line.trim().length > 0);
  requireValue(lines.length === 1, `${label} emitted ${lines.length} JSON lines`);
  try { return JSON.parse(lines[0]); }
  catch (error) { throw new Error(`${label} emitted invalid JSON: ${String(error)}`); }
}

function staticAudit(root: string): void {
  for (const token of STATIC_TOKENS) {
    const result = run(["rg", "-l", "-F", token, `${root}/src`]);
    requireValue(result.exitCode === 1, result.exitCode === 0
      ? `engine source recognizes independent suite token: ${token}`
      : result.stderr || `recognizer audit failed for ${token}`);
  }
}

function runChild(runner: string, checkout: string, row: string, revision: string, variant: SourceVariant, timeoutMs: number): any {
  const command = expectedArgv(runner, checkout, row, "attribution", revision, variant);
  console.error(`+ ${["env", "TZ=UTC", "LC_ALL=C", "LANG=C", ...command].join(" ")}`);
  const completed = run(["env", "TZ=UTC", "LC_ALL=C", "LANG=C", ...command], { timeoutMs });
  requireValue(completed.exitCode === 0 && !completed.timedOut, completed.stderr || `${row} ${variant} child failed`);
  const child = parseChild(completed.stdout, `${row} ${variant}`);
  validateChild(child, { runner, checkout, row, mode: "attribution", revision, variant });
  return { child, raw_stdout: completed.stdout, stderr: completed.stderr, exit_code: completed.exitCode, timed_out: completed.timedOut };
}

function expectFailure(action: () => void, pattern: string): void {
  try { action(); } catch (error) { requireValue(String(error).includes(pattern), `expected ${pattern}, got ${String(error)}`); return; }
  throw new Error(`expected failure containing ${pattern}`);
}

export function selfTest(): void {
  const child = { tier_attribution: { status: "measured", execution: [{ name: "tree_walker_entries", value: 1 }, { name: "vm_entries", value: 0 }], admissions: [{ name: "program_compiled", value: 1 }] }, adapter: { loaded_sources: [{ evaluated_sha256: "a" }, { evaluated_sha256: "b" }] } };
  const variant = JSON.parse(JSON.stringify(child));
  variant.adapter.loaded_sources[0].evaluated_sha256 = "c";
  variant.adapter.loaded_sources[1].evaluated_sha256 = "d";
  requireValue(comparePair("fixture", child, variant).status === "equivalent", "equivalent fixture pair failed");
  variant.tier_attribution.execution[1].value = 1;
  expectFailure(() => comparePair("fixture", child, variant), "tier signature drift");
  console.log("OK independent-suite recognizer self-test: source-hash and tier-signature drift fail closed");
}

function main(): void {
  const args = process.argv.slice(2);
  if (args.length === 1 && args[0] === "--self-test") { selfTest(); return; }
  const runner = args[0], checkout = args[1], revision = args[2], output = args[3];
  const timeoutMs = args[4] ? Number(args[4]) : 15 * 60 * 1000;
  requireValue(Boolean(runner && checkout && output) && runner.startsWith("/") && checkout.startsWith("/") && output.startsWith("/") && /^[0-9a-f]{40}$/.test(revision || ""), "usage: independent-suite-recognizer <runner> <checkout> <revision> <external-output> [timeout-ms]");
  requireValue(Number.isInteger(timeoutMs) && timeoutMs > 0, "timeout must be a positive integer");
  const root = checked(["git", "rev-parse", "--show-toplevel"], "resolve zig-js root").trim();
  requireValue(!output.startsWith(root + "/"), "recognizer output must remain outside the zig-js worktree");
  staticAudit(root);
  const pairs: any[] = [];
  for (const row of ROWS) {
    const exact = runChild(runner, checkout, row, revision, "exact", timeoutMs);
    const variant = runChild(runner, checkout, row, revision, "anti_specialization", timeoutMs);
    pairs.push({ row, equivalence: comparePair(row, exact.child, variant.child), exact, anti_specialization: variant });
  }
  const artifact = {
    schema_version: 1,
    kind: "zig-js-independent-suite-recognizer-audit",
    publication_status: "diagnostic_not_performance_evidence",
    source_revision: revision,
    static_engine_source_audit: { scope: ["src"], prohibited_tokens: STATIC_TOKENS, status: "passed" },
    mutation: "deterministic leading block comment added only after exact pinned-byte SHA-256 validation; scored sources remain untransformed",
    equivalence: "Each exact/mutated pair must pass the same output contract and select identical nonzero execution-tier and bytecode-admission sets.",
    pairs,
  };
  writeText(output, JSON.stringify(artifact, null, 2) + "\n");
  console.log(JSON.stringify({ output, status: "passed", rows: pairs.map((pair) => ({ row: pair.row, equivalence: pair.equivalence.status })) }, null, 2));
}

if (process.argv[1] === __filename) main();
