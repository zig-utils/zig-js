/** Build and verify the terminal PR-249 execution artifact for issue #430. */
import { readText, writeText } from "./lib/home";
declare const __dirname: string;
declare const __filename: string;
const ROOT =
  __dirname === "tools"
    ? "."
    : __dirname.slice(0, __dirname.lastIndexOf("/tools"));
const REFERENCE = `${ROOT}/docs/.data/pr249-reference-inventory.json`,
  SERIALIZED = `${ROOT}/docs/.data/pr249-execution-serialized.json`,
  NOGIL = `${ROOT}/docs/.data/pr249-execution-nogil.json`,
  TAIL_SCAN = `${ROOT}/docs/.data/pr249-unpromoted-scan-2026-07-28.json`,
  OUTPUT = `${ROOT}/docs/.data/pr249-terminal-execution.json`;
type RecordValue = Record<string, any>;
function requireValue(condition: boolean, message: string): void {
  if (!condition) throw new Error(message);
}
function load(path: string): RecordValue {
  let value: any;
  try {
    value = JSON.parse(readText(path));
  } catch (error) {
    throw new Error(`${path.slice(ROOT.length + 1)}: ${error}`);
  }
  requireValue(
    value !== null && typeof value === "object" && !Array.isArray(value),
    `${path.slice(ROOT.length + 1)}: root must be an object`,
  );
  return value;
}
function modeRecords(
  artifact: RecordValue,
  expectedMode: string,
): Record<string, RecordValue> {
  requireValue(
    artifact.schema_version === 2,
    `${expectedMode}: schema_version must be 2`,
  );
  requireValue(
    artifact.build_mode === "ReleaseSafe",
    `${expectedMode}: build_mode must be ReleaseSafe`,
  );
  requireValue(
    artifact.mode === expectedMode,
    `${expectedMode}: mode field drift`,
  );
  requireValue(
    Array.isArray(artifact.cases),
    `${expectedMode}: cases must be an array`,
  );
  const records: Record<string, RecordValue> = {};
  for (const raw of artifact.cases) {
    requireValue(
      raw !== null && typeof raw === "object" && !Array.isArray(raw),
      `${expectedMode}: case record must be an object`,
    );
    const name = raw.case;
    requireValue(
      typeof name === "string",
      `${expectedMode}: case name must be a string`,
    );
    requireValue(
      records[name] === undefined,
      `${expectedMode}: duplicate case ${name}`,
    );
    requireValue(
      raw.mode === expectedMode,
      `${expectedMode}: ${name} mode drift`,
    );
    requireValue(
      raw.result === "pass",
      `${expectedMode}: promoted case ${name} did not pass`,
    );
    requireValue(
      Number.isInteger(raw.ms) && raw.ms >= 0,
      `${expectedMode}: ${name} invalid duration`,
    );
    for (const counter of ["optimizer_publications", "optimizer_invalidations"])
      requireValue(
        Number.isInteger(raw[counter]) && raw[counter] >= 0,
        `${expectedMode}: ${name} invalid ${counter}`,
      );
    records[name] = raw;
  }
  const summary = artifact.summary;
  requireValue(
    summary !== null && typeof summary === "object" && !Array.isArray(summary),
    `${expectedMode}: summary must be an object`,
  );
  const names = Object.keys(records);
  requireValue(
    summary.cases === names.length,
    `${expectedMode}: summary case count drift`,
  );
  requireValue(
    summary.passed === names.length,
    `${expectedMode}: every promoted case must pass`,
  );
  requireValue(
    summary.failed === 0,
    `${expectedMode}: failed count must be zero`,
  );
  requireValue(
    summary.skipped === 0,
    `${expectedMode}: skipped count must be zero`,
  );
  requireValue(
    summary.cases_reaching_optimizer ===
      names.filter((name) => records[name].optimizer_publications !== 0).length,
    `${expectedMode}: optimizer summary drift`,
  );
  requireValue(
    summary.total_ms === names.reduce((sum, name) => sum + records[name].ms, 0),
    `${expectedMode}: total_ms drift`,
  );
  return records;
}
function terminalModeRecords(
  scan: RecordValue,
): Record<string, Record<string, RecordValue>> {
  requireValue(
    scan.unpromoted_scan_disposition_drift === 0,
    "terminal scan disposition drift",
  );
  requireValue(
    Array.isArray(scan.unpromoted_scan_results),
    "terminal scan results must be an array",
  );
  const records: Record<string, Record<string, RecordValue>> = {};
  for (const raw of scan.unpromoted_scan_results) {
    requireValue(
      raw !== null && typeof raw === "object" && !Array.isArray(raw),
      "terminal scan record must be an object",
    );
    const name = raw.case;
    requireValue(
      typeof name === "string",
      "terminal scan case must be a string",
    );
    requireValue(
      raw.status === "terminal-disposition-confirmed",
      `${name}: terminal disposition drift`,
    );
    requireValue(
      raw.mode_results !== null &&
        typeof raw.mode_results === "object" &&
        !Array.isArray(raw.mode_results),
      `${name}: terminal mode results missing`,
    );
    requireValue(
      JSON.stringify(Object.keys(raw.mode_results).sort()) ===
        JSON.stringify(["parallel-js", "serialized"]),
      `${name}: terminal modes incomplete`,
    );
    const checked: Record<string, RecordValue> = {};
    for (const mode of ["parallel-js", "serialized"]) {
      const result = raw.mode_results[mode];
      requireValue(
        result !== null && typeof result === "object" && !Array.isArray(result),
        `${name}: ${mode} result must be an object`,
      );
      requireValue(
        result.expectation_matched === true,
        `${name}: ${mode} expectation drift`,
      );
      requireValue(
        result.observed_status === result.expected_status,
        `${name}: ${mode} observed/expected mismatch`,
      );
      requireValue(
        Number.isInteger(result.ms) && result.ms >= 0,
        `${name}: ${mode} invalid duration`,
      );
      checked[mode] = result;
    }
    requireValue(
      records[name] === undefined,
      `duplicate terminal scan case ${name}`,
    );
    records[name] = checked;
  }
  return records;
}
const compact = (record: RecordValue): RecordValue => ({
  ms: record.ms,
  optimizer_invalidations: record.optimizer_invalidations,
  optimizer_publications: record.optimizer_publications,
  result: "pass",
});
function sameNames(
  actual: Record<string, any>,
  expected: string[],
  message: string,
): void {
  requireValue(
    JSON.stringify(Object.keys(actual).sort()) ===
      JSON.stringify(expected.slice().sort()),
    message,
  );
}
export function buildArtifact(commit: string): RecordValue {
  requireValue(
    /^[0-9a-f]{40}$/.test(commit),
    "commit must be a full 40-hex SHA",
  );
  const reference = load(REFERENCE),
    referenceSummary = reference.summary;
  requireValue(
    reference.schema_version === 2,
    "reference inventory schema drift",
  );
  requireValue(
    referenceSummary !== null && typeof referenceSummary === "object",
    "reference summary missing",
  );
  requireValue(
    referenceSummary.executable === 259,
    "reference executable total drift",
  );
  requireValue(
    referenceSummary.blocked === 0,
    "terminal publication requires zero blocked cases",
  );
  const serialized = modeRecords(load(SERIALIZED), "serialized"),
    nogil = modeRecords(load(NOGIL), "parallel-js"),
    terminal = terminalModeRecords(load(TAIL_SCAN));
  requireValue(Array.isArray(reference.files), "reference files missing");
  const executable = reference.files.filter(
      (entry: any) =>
        entry &&
        ["promoted", "terminal-disposition"].includes(entry.execution_state),
    ),
    helpers = reference.files.filter(
      (entry: any) => entry && entry.execution_state === "helper/preload",
    );
  requireValue(executable.length === 259, "reference executable records drift");
  const cases: RecordValue[] = [],
    expectedSerialized: string[] = [],
    expectedNogil: string[] = [],
    expectedTerminal: string[] = [];
  executable
    .slice()
    .sort((a: any, b: any) => String(a.case).localeCompare(String(b.case)))
    .forEach((entry: any) => {
      const name = entry.case,
        modes = entry.execution_modes;
      requireValue(
        Array.isArray(modes) && modes.length > 0,
        `${name}: execution_modes missing`,
      );
      const executions: RecordValue = {};
      let owner: RecordValue;
      if (entry.execution_state === "promoted") {
        expectedNogil.push(name);
        requireValue(
          nogil[name] !== undefined,
          `${name}: missing no-GIL execution`,
        );
        executions["parallel-js"] = compact(nogil[name]);
        if (modes.includes("serialized")) {
          expectedSerialized.push(name);
          requireValue(
            serialized[name] !== undefined,
            `${name}: missing serialized execution`,
          );
          executions.serialized = compact(serialized[name]);
        }
        requireValue(
          JSON.stringify(Object.keys(executions).sort()) ===
            JSON.stringify(modes.slice().sort()),
          `${name}: promoted mode coverage drift`,
        );
        owner = { kind: "implementation", issues: [143] };
      } else {
        expectedTerminal.push(name);
        requireValue(
          terminal[name] !== undefined,
          `${name}: missing terminal execution`,
        );
        const disposition = entry.terminal_disposition,
          result =
            disposition.category === "intentionally-incompatible"
              ? "intentional-incompatibility"
              : "terminal-private-premise";
        for (const mode of modes) {
          const measured = terminal[name][mode];
          executions[mode] = {
            expected_result: measured.expected_status,
            ms: measured.ms,
            observed_result: measured.observed_status,
            result,
          };
        }
        owner = {
          kind: "terminal-disposition",
          issues: disposition.owner_issues,
        };
      }
      const record: RecordValue = {
        case: name,
        execution_state: entry.execution_state,
        executions,
        owner,
        path: entry.path,
        sha256: entry.sha256,
      };
      if (entry.terminal_premises)
        record.terminal_premises = entry.terminal_premises;
      if (entry.execution_state === "terminal-disposition")
        record.terminal_disposition = {
          category: entry.terminal_disposition.category,
          premise: entry.terminal_disposition.premise,
          zig_js_contract: entry.terminal_disposition.zig_js_contract,
        };
      cases.push(record);
    });
  sameNames(
    serialized,
    expectedSerialized,
    "serialized inventory has missing or extra cases",
  );
  sameNames(
    nogil,
    expectedNogil,
    "no-GIL inventory has missing or extra cases",
  );
  sameNames(
    terminal,
    expectedTerminal,
    "terminal scan has missing or extra cases",
  );
  const helperRecords = helpers
    .slice()
    .sort((a: any, b: any) => String(a.case).localeCompare(String(b.case)))
    .map((entry: any) => ({
      case: entry.case,
      execution_state: "helper/preload",
      path: entry.path,
      sha256: entry.sha256,
    }));
  return {
    schema_version: 1,
    source: {
      measured_commit: commit,
      reference_head: reference.source.head,
      reference_pull_request: reference.source.pull_request,
      reference_repository: reference.source.repository,
    },
    summary: {
      blocked: 0,
      executable: cases.length,
      helper_preload: helperRecords.length,
      parallel_js_required: expectedNogil.length + expectedTerminal.length,
      promoted: cases.filter((record) => record.execution_state === "promoted")
        .length,
      serialized_required: expectedSerialized.length + expectedTerminal.length,
      terminal_disposition: expectedTerminal.length,
    },
    cases,
    helpers: helperRecords,
  };
}
function canonical(value: any): string {
  if (Array.isArray(value)) return `[${value.map(canonical).join(",")}]`;
  if (value !== null && typeof value === "object")
    return `{${Object.keys(value)
      .sort()
      .map((key) => `${JSON.stringify(key)}:${canonical(value[key])}`)
      .join(",")}}`;
  return JSON.stringify(value);
}
function main(): void {
  const args = process.argv.slice(2),
    generate = args.includes("--generate"),
    check = args.includes("--check"),
    commitIndex = args.indexOf("--commit");
  requireValue(
    generate !== check,
    "choose exactly one of --generate or --check",
  );
  if (generate) {
    requireValue(
      commitIndex >= 0 && !!args[commitIndex + 1],
      "--generate requires --commit",
    );
    const artifact = buildArtifact(args[commitIndex + 1]);
    writeText(OUTPUT, JSON.stringify(artifact, null, 2) + "\n");
    console.log(
      `PR-249 terminal artifact written: ${artifact.summary.executable} executable, ${artifact.summary.promoted} promoted, ${artifact.summary.terminal_disposition} terminal`,
    );
  } else {
    const checked = load(OUTPUT);
    requireValue(
      checked.source !== null && typeof checked.source === "object",
      "checked terminal artifact source missing",
    );
    requireValue(
      typeof checked.source.measured_commit === "string",
      "checked terminal artifact measured_commit missing",
    );
    requireValue(
      canonical(checked) ===
        canonical(buildArtifact(checked.source.measured_commit)),
      "checked terminal artifact is stale",
    );
    console.log("PR-249 terminal execution artifact verified");
  }
}
if (process.argv[1] === __filename) {
  try {
    main();
  } catch (error) {
    console.error(
      `pr249-terminal-execution: ${String(error).replace(/^Error: /, "")}`,
    );
    process.exitCode = 1;
  }
}
