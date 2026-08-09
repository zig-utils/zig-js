/** Run the zig-js unit suite as parallel shards against one built binary. */
import { cpuCount, fileExists, readText, run, writeText } from "./lib/home";
declare const __filename: string;
function requireValue(condition: boolean, message: string): void {
  if (!condition) throw new Error(message);
}
const quote = (value: string): string => `'${value.replace(/'/g, `'"'"'`)}'`;
type Aggregate = {
  passed: number;
  skipped: number;
  failed: number;
  leaked: number;
  failures: string[];
  slow: any[][];
};
export function aggregate(logs: string[], codes: number[]): Aggregate {
  const result: Aggregate = {
    passed: 0,
    skipped: 0,
    failed: 0,
    leaked: 0,
    failures: [],
    slow: [],
  };
  logs.forEach((text, index) => {
    const summary =
      /summary: (\d+) passed; (\d+) skipped; (\d+) failed; (\d+) leaked(?:; (\d+) ms)?/.exec(
        text,
      );
    if (summary) {
      result.passed += Number(summary[1]);
      result.skipped += Number(summary[2]);
      result.failed += Number(summary[3]);
      result.leaked += Number(summary[4]);
    } else {
      result.failed += 1;
      result.failures.push(
        `shard ${index}: produced no summary (exit ${codes[index]})`,
      );
    }
    text.split("\n").forEach((line) => {
      const slow = /slow: (\d+) ms (.+)$/.exec(line);
      if (slow) result.slow.push([Number(slow[1]), slow[2]]);
      else if (line.includes("FAIL") || line.startsWith("error:"))
        result.failures.push(`shard ${index}: ${line.trim()}`);
    });
  });
  result.slow.sort((a, b) => b[0] - a[0]);
  return result;
}
type ShardPlan = {
  assignments: number[];
  expectedMs: number[];
  measured: number;
  rebalanced: number;
};
export function timingHistory(logs: string[]): Map<string, number> {
  const history = new Map<string, number>();
  logs.forEach((text) =>
    text.split("\n").forEach((line) => {
      const timing = /^\d+\/\d+ \[\d+\/\d+\] (.+)\.\.\.(?:OK|FAIL) \((\d+) ms\)$/.exec(
        line,
      );
      if (!timing) return;
      const elapsed = Number(timing[2]),
        previous = history.get(timing[1]);
      if (Number.isInteger(elapsed) && elapsed >= 0)
        history.set(timing[1], Math.max(previous ?? 0, elapsed));
    }),
  );
  return history;
}
export function scheduleTests(
  names: string[],
  history: Map<string, number>,
  jobs: number,
): ShardPlan {
  requireValue(Number.isInteger(jobs) && jobs > 0, "shard count must be positive");
  const expectedMs = Array.from({ length: jobs }, () => 0),
    counts = Array.from({ length: jobs }, () => 0),
    assignments = names.map((_, index) => index % jobs),
    ranked = names
      .map((name, index) => ({
        name,
        index,
        measured: history.has(name),
        elapsed: Math.max(history.get(name) ?? 1, 1),
      }))
      .sort(
        (a, b) =>
          Number(b.measured) - Number(a.measured) ||
          b.elapsed - a.elapsed ||
          a.index - b.index,
      ),
    // Moving the whole measured suite made its internally parallel GC tests
    // start in one synchronized wave. Rebalance only the dominant tail and
    // preserve modulo placement for every other test.
    tail = ranked.filter((test) => test.measured).slice(0, jobs),
    tailIndices = new Set(tail.map((test) => test.index));
  ranked.forEach((test) => {
    if (tailIndices.has(test.index)) return;
    const shard = assignments[test.index];
    expectedMs[shard] += test.elapsed;
    counts[shard] += 1;
  });
  tail.forEach((test) => {
    let selected = 0;
    for (let shard = 1; shard < jobs; shard += 1)
      if (
        expectedMs[shard] < expectedMs[selected] ||
        (expectedMs[shard] === expectedMs[selected] &&
          (counts[shard] < counts[selected] ||
            (counts[shard] === counts[selected] && shard < selected)))
      )
        selected = shard;
    assignments[test.index] = selected;
    expectedMs[selected] += test.elapsed;
    counts[selected] += 1;
  });
  return {
    assignments,
    expectedMs,
    measured: names.filter((name) => history.has(name)).length,
    rebalanced: tail.length,
  };
}
function discoverTests(binary: string, filter: string | undefined): string[] {
  const env: Record<string, string> = { UNIT_LIST_TESTS: "1" };
  if (filter) env.UNIT_TEST_FILTER = filter;
  const discovery = run([binary], { env, inheritEnv: true });
  requireValue(
    discovery.exitCode === 0,
    discovery.stderr || discovery.stdout || "test discovery failed",
  );
  const names = discovery.stderr
    .split("\n")
    .filter((line) => line.startsWith("UNIT_TEST_NAME\t"))
    .map((line) => line.slice("UNIT_TEST_NAME\t".length));
  requireValue(names.length > 0, "test discovery produced a zero denominator");
  requireValue(new Set(names).size === names.length, "test discovery returned duplicate names");
  return names;
}
function historicalLogs(logDir: string): string[] {
  const logs: string[] = [];
  for (let index = 0; index < 256; index += 1) {
    const path = `${logDir}/shard-${index}.log`;
    if (fileExists(path)) logs.push(readText(path));
  }
  return logs;
}
function selfTest(): void {
  const result = aggregate(
    [
      "slow: 20 ms beta\nsummary: 2 passed; 1 skipped; 0 failed; 0 leaked; 30 ms\n",
      "error: crash\n",
    ],
    [0, 9],
  );
  requireValue(
    JSON.stringify([
      result.passed,
      result.skipped,
      result.failed,
      result.leaked,
    ]) === "[2,1,1,0]",
    "summary aggregation failed",
  );
  requireValue(
    result.failures.length === 2 && result.slow[0][1] === "beta",
    "diagnostic aggregation failed",
  );
  requireValue(
    Number.isInteger(cpuCount()) && cpuCount() > 0,
    "Home CPU count is invalid",
  );
  requireValue(quote("a'b") === `'a'"'"'b'`, "shell quoting failed");
  const history = timingHistory([
      "1/2 [0/2] alpha...OK (100 ms)\n2/2 [0/2] gamma...OK (20 ms)\n",
      "1/2 [1/2] beta...OK (90 ms)\n2/2 [1/2] delta...OK (10 ms)\n",
    ]),
    plan = scheduleTests(["alpha", "beta", "gamma", "delta"], history, 2);
  requireValue(
    JSON.stringify(plan.assignments) === "[1,0,0,1]" &&
      JSON.stringify(plan.expectedMs) === "[110,110]" &&
      plan.measured === 4 &&
      plan.rebalanced === 2,
    "conservative tail scheduling failed",
  );
  const cold = scheduleTests(["a", "b", "c", "d", "e"], new Map(), 3);
  requireValue(
    JSON.stringify(cold.assignments) === "[0,1,2,0,1]" &&
      JSON.stringify(cold.expectedMs) === "[2,2,1]" &&
      cold.measured === 0 &&
      cold.rebalanced === 0,
    "cold-cache scheduling failed",
  );
  console.log("unit-test-parallel self-test: ok");
}
function main(): void {
  const args = process.argv.slice(2);
  if (args.length === 1 && args[0] === "--self-test") return selfTest();
  requireValue(args.length > 0, "test binary is required");
  const binary = args[0],
    options: any = {
      jobs: Math.max(1, cpuCount() - 1),
      logDir: ".zig-cache/unit-shards",
      slowest: 10,
    };
  for (let index = 1; index < args.length; index += 1) {
    const name = args[index],
      value = args[++index];
    if (name === "--jobs") options.jobs = Number(value);
    else if (name === "--log-dir") options.logDir = value;
    else if (name === "--slowest") options.slowest = Number(value);
    else throw new Error(`unknown argument: ${name}`);
  }
  requireValue(fileExists(binary), `test binary not found: ${binary}`);
  requireValue(
    Number.isInteger(options.jobs) &&
      options.jobs > 0 &&
      Number.isInteger(options.slowest) &&
      options.slowest >= 0,
    "--jobs must be positive and --slowest non-negative",
  );
  const mkdir = run(["mkdir", "-p", options.logDir]);
  requireValue(
    mkdir.exitCode === 0,
    mkdir.stderr || "cannot create shard log directory",
  );
  console.log(
    `zig-js unit tests: ${options.jobs} parallel shards -> ${options.logDir}`,
  );
  const names = discoverTests(binary, process.env.UNIT_TEST_FILTER),
    history = timingHistory(historicalLogs(options.logDir)),
    plan = scheduleTests(names, history, options.jobs),
    encodedPlan = plan.assignments.join(","),
    planPath = `${options.logDir}/plan.tsv`;
  writeText(
    planPath,
    "shard\testimated_ms\tname\n" +
      names
        .map(
          (name, index) =>
            `${plan.assignments[index]}\t${history.get(name) ?? 1}\t${name}`,
        )
        .join("\n") +
      "\n",
  );
  console.log(
    `shard plan: ${plan.measured}/${names.length} measured tests, ${plan.rebalanced} tail tests rebalanced; expected-ms ${plan.expectedMs.join(",")}`,
  );
  const commands: string[] = ["set +e"];
  for (let index = 0; index < options.jobs; index += 1) {
    const log = `${options.logDir}/shard-${index}.log`;
    commands.push(
      `UNIT_SHARD_INDEX=${index} UNIT_SHARD_COUNT=${options.jobs} ${quote(binary)} >${quote(log)} 2>&1 & p${index}=$!`,
    );
  }
  for (let index = 0; index < options.jobs; index += 1)
    commands.push(`wait "$p${index}"; echo ${index}:$?`);
  const started = Date.now(),
    coordinator = run(["/bin/sh", "-c", commands.join("\n")], {
      env: { UNIT_SHARD_PLAN: encodedPlan },
      inheritEnv: true,
    }),
    elapsed = (Date.now() - started) / 1000;
  requireValue(
    coordinator.exitCode === 0,
    coordinator.stderr || `shard coordinator exited ${coordinator.exitCode}`,
  );
  const codes = Array.from({ length: options.jobs }, () => -1);
  coordinator.stdout
    .split("\n")
    .filter(Boolean)
    .forEach((line) => {
      const match = /^(\d+):(\d+)$/.exec(line);
      requireValue(
        !!match && Number(match[1]) < options.jobs,
        `invalid shard status: ${line}`,
      );
      codes[Number(match[1])] = Number(match[2]);
    });
  requireValue(
    codes.every((code) => code >= 0),
    "missing shard exit status",
  );
  const logs = codes.map((_, index) =>
      readText(`${options.logDir}/shard-${index}.log`),
    ),
    result = aggregate(logs, codes);
  result.failures.forEach((line) => console.log(line));
  result.slow
    .slice(0, options.slowest)
    .forEach((item) => console.log(`slowest: ${item[0]} ms ${item[1]}`));
  console.log(
    `zig-js unit tests: ${result.passed} passed; ${result.skipped} skipped; ${result.failed} failed; ${result.leaked} leaked; ${elapsed.toFixed(1)}s wall across ${options.jobs} shards`,
  );
  console.log(`per-shard logs: ${options.logDir}`);
  const accounted = result.passed + result.skipped + result.failed;
  requireValue(
    result.failed === 0 &&
      result.leaked === 0 &&
      accounted === names.length &&
      codes.every((code) => code === 0),
    `unit test shard failure or denominator mismatch: expected ${names.length}, accounted ${accounted}`,
  );
}
if (process.argv[1] === __filename) main();
