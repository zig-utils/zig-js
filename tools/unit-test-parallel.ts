/** Run the zig-js unit suite as parallel shards against one built binary. */
import { fileExists, readText, run } from "./lib/home";
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
  requireValue(quote("a'b") === `'a'"'"'b'`, "shell quoting failed");
  console.log("unit-test-parallel self-test: ok");
}
function main(): void {
  const args = process.argv.slice(2);
  if (args.length === 1 && args[0] === "--self-test") return selfTest();
  requireValue(args.length > 0, "test binary is required");
  const binary = args[0],
    options: any = { jobs: 1, logDir: ".zig-cache/unit-shards", slowest: 10 };
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
    coordinator = run(["/bin/sh", "-c", commands.join("\n")]),
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
  requireValue(
    result.failed === 0 &&
      result.leaked === 0 &&
      codes.every((code) => code === 0),
    "unit test shard failure",
  );
}
if (process.argv[1] === __filename) main();
