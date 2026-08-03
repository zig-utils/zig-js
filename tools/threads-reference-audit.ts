/** Audit promoted and terminal WebKit PR-249 thread corpus files. */
import { fileExists, readText, run, sha256File, writeText } from "./lib/home";
declare const __filename: string;
type Item = Record<string, any>;
const ROOT = ".",
  REFERENCE_ROOT = "reference/webkit-249",
  CORPUS = `${REFERENCE_ROOT}/threads-tests`,
  RUNNER_SOURCE = "conformance/threads_test.zig",
  RUNNER = "zig-out/bin/threads-test",
  INVENTORY = "docs/.data/pr249-reference-inventory.json";
const HELPERS = [
  "bench/harness.js",
  "harness.js",
  "resources/assert.js",
  "scaling/harness.js",
  "vmstate/resources/workload.js",
];
const PROBES = [
  "api/wasm-refused-sd7.js",
  "congc-t2-lockorder-lint.js",
  "congc-t8-stop-interleaving.js",
  "cve/mc-df-arraycopy-relabel.js",
  "cve/mc-life-creator-thread-dies.js",
];
const CATEGORIES: Record<string, string[]> = {
  "api/wasm-refused-sd7.js": [
    "JSC-specific spawned-thread WebAssembly refusal contract",
    "zig-js intentionally supports WebAssembly in shared-realm Threads",
  ],
  "congc-t2-lockorder-lint.js": ["$vm shared-heap/shell hooks"],
  "congc-t8-stop-interleaving.js": ["$vm shared-heap/shell hooks"],
  "cve/mc-df-arraycopy-relabel.js": [
    "JSC butterfly verification shell option",
    "typed-array set source-length snapshot covered by zig-js witnesses",
  ],
  "cve/mc-life-creator-thread-dies.js": [
    "detached ArrayBuffer fresh-view construction race",
    "portable creator-owned buffer survival already covered",
  ],
  "w16-c1-prevent-collection.js": [
    "portable snapshot graph/parse/ownership promoted by test-private-heap-snapshot",
    "JSC shared-collector preventCollection election hook has a terminal disposition",
  ],
};
function requireValue(condition: boolean, message: string): void {
  if (!condition) throw new Error(`threads-reference-audit: ${message}`);
}
function load(): Item {
  return JSON.parse(readText(INVENTORY));
}
function relative(path: string): string {
  return path.startsWith(`${REFERENCE_ROOT}/`)
    ? path.slice(REFERENCE_ROOT.length + 1)
    : path;
}
function corpusCase(path: string): string {
  const prefix = "threads-tests/";
  return path.startsWith(prefix) ? path.slice(prefix.length) : path;
}
function extractAllowlist(source: string, name: string): string[] {
  const marker = `const ${name} = [_][]const u8{`,
    start = source.indexOf(marker);
  requireValue(start >= 0, `missing ${name}`);
  const end = source.indexOf("};", start);
  requireValue(end > start, `unterminated ${name}`);
  const values: string[] = [],
    expression = /"([^"\n]+\.js)"/g;
  let match: RegExpExecArray | null;
  while ((match = expression.exec(source.slice(start, end))))
    values.push(match[1]);
  return values;
}
function allowlists(): { serialized: Set<string>; parallel: Set<string> } {
  const source = readText(RUNNER_SOURCE);
  return {
    serialized: new Set(extractAllowlist(source, "allowlist")),
    parallel: new Set(extractAllowlist(source, "parallel_only_allowlist")),
  };
}
function promotedCases(): string[] {
  const lists = allowlists();
  return Array.from(new Set([...lists.serialized, ...lists.parallel])).sort();
}
function actualFiles(): string[] {
  const result = run(["find", REFERENCE_ROOT, "-type", "f"]);
  requireValue(result.exitCode === 0, result.stderr);
  return result.stdout.split("\n").filter(Boolean).map(relative).sort();
}
function byteCount(path: string): number {
  const result = run(["wc", "-c", path]);
  requireValue(result.exitCode === 0, result.stderr);
  return Number(result.stdout.trim().split(/\s+/)[0]);
}
function validate(inventory: Item): string[] {
  const errors: string[] = [],
    report = (condition: boolean, message: string) => {
      if (!condition) errors.push(message);
    };
  report(inventory.schema_version === 2, "unsupported inventory schema");
  report(
    inventory.source?.head === "3a14f2a821ac56fcb01d1c765200be7e9dfdb458",
    "source pin drift",
  );
  report(Array.isArray(inventory.files), "files must be an array");
  if (!Array.isArray(inventory.files)) return errors;
  const entries: Item[] = inventory.files,
    paths = entries.map((entry) => entry.path),
    actual = actualFiles();
  report(
    JSON.stringify(paths) === JSON.stringify(actual),
    "reference file list/order drift",
  );
  report(new Set(paths).size === paths.length, "duplicate inventory path");
  const lists = allowlists(),
    promoted = new Set([...lists.serialized, ...lists.parallel]),
    helpers = new Set(HELPERS),
    seenCases = new Set<string>();
  for (const entry of entries) {
    const path = `${REFERENCE_ROOT}/${entry.path}`;
    if (!fileExists(path)) continue;
    report(entry.bytes === byteCount(path), `${entry.path}: byte count drift`);
    report(entry.sha256 === sha256File(path), `${entry.path}: SHA-256 drift`);
    if (entry.kind !== "javascript") continue;
    const name = corpusCase(entry.path);
    report(!seenCases.has(name), `${name}: duplicate JS case`);
    seenCases.add(name);
    const expected = helpers.has(name)
      ? "helper/preload"
      : promoted.has(name)
        ? "promoted"
        : entry.terminal_disposition
          ? "terminal-disposition"
          : "uncategorized";
    report(
      entry.execution_state === expected,
      `${name}: execution state drift (${entry.execution_state} != ${expected})`,
    );
    if (expected === "promoted")
      report(
        Array.isArray(entry.execution_modes) &&
          (lists.serialized.has(name)
            ? entry.execution_modes.includes("serialized")
            : entry.execution_modes.includes("parallel-js")),
        `${name}: promoted modes drift`,
      );
    if (expected === "terminal-disposition") {
      const disposition = entry.terminal_disposition;
      report(
        Array.isArray(disposition.owner_issues) &&
          disposition.owner_issues.length > 0,
        `${name}: missing owner issue`,
      );
      for (const mode of ["default", "parallel_js"])
        report(
          ["pass", "fail", "timeout"].includes(
            disposition.verification?.[mode]?.status,
          ),
          `${name}: invalid ${mode} disposition`,
        );
    }
  }
  const executable = entries.filter(
      (entry) =>
        entry.kind === "javascript" &&
        entry.execution_state !== "helper/preload",
    ),
    terminal = entries.filter(
      (entry) => entry.execution_state === "terminal-disposition",
    );
  report(
    promoted.size === inventory.summary.promoted,
    "promoted summary drift",
  );
  report(
    executable.length === inventory.summary.executable,
    "executable summary drift",
  );
  report(
    terminal.length === inventory.summary.terminal_disposition,
    "terminal summary drift",
  );
  report(
    terminal.length === 6 && helpers.size === 5,
    "terminal/helper coverage drift",
  );
  report(inventory.summary.blocked === 0, "blocked cases remain");
  return errors;
}
function terminalEntries(inventory: Item): Item[] {
  return inventory.files
    .filter((entry: Item) => entry.execution_state === "terminal-disposition")
    .sort((a: Item, b: Item) => a.case.localeCompare(b.case));
}
function expectation(entry: Item, mode: "serialized" | "parallel-js"): Item {
  return entry.terminal_disposition.verification[
    mode === "serialized" ? "default" : "parallel_js"
  ];
}
function command(name: string, mode: "serialized" | "parallel-js"): string[] {
  return mode === "serialized"
    ? [RUNNER, "one", name]
    : [RUNNER, "parallel-js", "one", name];
}
function outputSummary(output: string): Item {
  const lines = output.split("\n"),
    evidence = lines.filter(
      (line) =>
        /^(\s*)(PASS|FAIL|SKIP|MISS)\s/.test(line) ||
        /(RangeError|ReferenceError|SyntaxError|TypeError|CorpusFailures|optimizer:|parallel GC:|cooperative GC:)/.test(
          line,
        ),
    );
  return { evidence, tail: lines.slice(-20).filter(Boolean) };
}
function runOne(
  entry: Item,
  mode: "serialized" | "parallel-js",
  timeoutMs: number,
): Item {
  const expected = expectation(entry, mode),
    result = run(command(entry.case, mode), { timeoutMs }),
    output = `${result.stdout}\n${result.stderr}`,
    observed = result.timedOut
      ? "timeout"
      : result.exitCode === 0
        ? "pass"
        : "fail",
    evidence =
      expected.status === "fail" &&
      typeof expected.evidence === "string" &&
      expected.evidence.length > 0
        ? [expected.evidence]
        : [],
    matched =
      observed === expected.status &&
      evidence.every((item) =>
        output.replaceAll('"', "").includes(item.replaceAll('"', "")),
      );
  return {
    command: command(entry.case, mode),
    expected_status: expected.status,
    observed_status: observed,
    expectation_matched: matched,
    exit_code: result.exitCode,
    ms: 0,
    output: outputSummary(output),
  };
}
function candidates(inventory: Item): Item[] {
  const byCase: Record<string, Item> = {};
  terminalEntries(inventory).forEach((entry) => (byCase[entry.case] = entry));
  return PROBES.map((name) => {
    const entry = byCase[name];
    const expected = expectation(entry, "serialized");
    return {
      case: name,
      categories: CATEGORIES[name] || [],
      command: command(name, "serialized"),
      expected_terminal_disposition: {
        status: expected.status,
        evidence:
          expected.status === "fail" && expected.evidence
            ? [expected.evidence]
            : [],
      },
    };
  });
}
function baseSummary(inventory: Item): Item {
  const terminal = terminalEntries(inventory),
    byCategory: Record<string, string[]> = {};
  for (const entry of terminal)
    for (const category of CATEGORIES[entry.case] || [])
      (byCategory[category] ||= []).push(entry.case);
  return {
    promoted_executable: inventory.summary.promoted,
    executable_total: inventory.summary.executable,
    blocked_executable: inventory.summary.blocked,
    terminal_disposition_executable: inventory.summary.terminal_disposition,
    helper_preload: inventory.summary.helper_preload,
    allowlist: {
      executable_passed: inventory.summary.promoted,
      executable_total: inventory.summary.executable,
    },
    unpromoted: {
      blocked: [],
      terminal_dispositions: Object.fromEntries(
        terminal.map((entry) => [entry.case, entry.terminal_disposition]),
      ),
      helper_preload: HELPERS.slice().sort(),
    },
    categories: byCategory,
    uncategorized: [],
    missing_allowlist_entries: [],
    disposition_probe_candidates: candidates(inventory),
  };
}
function parseArgs(): Item {
  const args: Item = { format: "text", timeoutMs: 60000 };
  for (let index = 2; index < process.argv.length; index++) {
    const arg = process.argv[index];
    if (["--format", "--probe-timeout", "--output"].includes(arg)) {
      const value = process.argv[++index];
      requireValue(value != null, `${arg} requires a value`);
      if (arg === "--format") args.format = value;
      else if (arg === "--output") args.output = value;
      else args.timeoutMs = Number(value) * 1000;
    } else if (arg.startsWith("--"))
      args[
        arg
          .slice(2)
          .replace(/-([a-z])/g, (_: string, c: string) => c.toUpperCase())
      ] = true;
    else requireValue(false, `unknown argument ${arg}`);
  }
  return args;
}
function main(): void {
  const args = parseArgs(),
    inventory = load(),
    errors = validate(inventory);
  if (args.printInventory) {
    requireValue(!errors.length, errors.join("\n"));
    process.stdout.write(readText(INVENTORY));
    return;
  }
  let selfTest = true;
  if (args.selfTestInventory) {
    const copy = JSON.parse(JSON.stringify(inventory));
    copy.files[0].sha256 = "0".repeat(64);
    selfTest = validate(copy).some((error) => error.includes("SHA-256 drift"));
  }
  let probeFailures = 0,
    probeResults: Item[] = [];
  if (args.runDispositionProbes) {
    requireValue(
      fileExists(RUNNER),
      `missing ${RUNNER}; build threads-test-bin`,
    );
    const byCase: Record<string, Item> = {};
    terminalEntries(inventory).forEach((entry) => (byCase[entry.case] = entry));
    for (const name of PROBES) {
      const result = runOne(byCase[name], "serialized", args.timeoutMs);
      probeResults.push({ case: name, ...result });
      if (!result.expectation_matched) probeFailures += 1;
    }
  }
  let scanFailures = 0,
    scanResults: Item[] = [];
  if (args.scanUnpromoted) {
    requireValue(
      fileExists(RUNNER),
      `missing ${RUNNER}; build threads-test-bin`,
    );
    for (const entry of terminalEntries(inventory)) {
      const modeResults: Item = {};
      for (const mode of ["serialized", "parallel-js"] as const) {
        const result = runOne(entry, mode, args.timeoutMs);
        modeResults[mode] = result;
        if (!result.expectation_matched) scanFailures += 1;
      }
      scanResults.push({
        case: entry.case,
        status: Object.values(modeResults).every(
          (result: any) => result.expectation_matched,
        )
          ? "terminal-disposition-confirmed"
          : "terminal-disposition-drift",
        exit_code: null,
        terminal_disposition: entry.terminal_disposition,
        mode_results: modeResults,
      });
    }
  }
  const summary = baseSummary(inventory);
  if (args.runDispositionProbes) {
    summary.disposition_probe_results = probeResults;
    summary.disposition_probe_failures = probeFailures;
  }
  if (args.scanUnpromoted) {
    summary.unpromoted_scan_results = scanResults;
    summary.unpromoted_scan_disposition_drift = scanFailures;
  }
  if (args.checkInventory) summary.inventory_matches = errors.length === 0;
  if (args.selfTestInventory) summary.inventory_self_tests_pass = selfTest;
  if (args.format === "json") {
    const text = JSON.stringify(summary, null, 2) + "\n";
    if (args.output) {
      const slash = args.output.lastIndexOf("/");
      if (slash > 0) {
        const made = run(["mkdir", "-p", args.output.slice(0, slash)]);
        requireValue(made.exitCode === 0, made.stderr);
      }
      writeText(args.output, text);
    } else process.stdout.write(text);
  } else {
    console.log(
      `PR-249 promoted coverage: ${inventory.summary.promoted}/${inventory.summary.executable} executable files`,
    );
    console.log(
      `unpromoted: ${inventory.summary.blocked} blocked, ${inventory.summary.terminal_disposition} terminal dispositions, ${inventory.summary.helper_preload} helper/preload`,
    );
    if (errors.length) errors.forEach((error) => console.error(`  ${error}`));
    if (args.runDispositionProbes)
      console.log(
        `terminal disposition probes: ${PROBES.length - probeFailures}/${PROBES.length} matched`,
      );
  }
  requireValue(!errors.length || !args.checkInventory, errors.join("\n"));
  requireValue(selfTest, "inventory drift self-test failed");
  requireValue(
    !args.failOnUncategorized || summary.uncategorized.length === 0,
    "uncategorized cases remain",
  );
  requireValue(probeFailures === 0, "terminal disposition probe drift");
  requireValue(scanFailures === 0, "unpromoted disposition drift");
}
if (process.argv[1] === __filename) main();
