/** Benchmark zig-js WebAssembly Threads kernels and document the JSC boundary. */
import { fileExists, run, writeText } from "./lib/home";
declare const __dirname: string;
declare const __filename: string;
const ROOT =
  __dirname === "tools"
    ? "."
    : __dirname.slice(0, __dirname.lastIndexOf("/tools"));
const WORKLOADS = [
  "wasm_threads_atomic_add",
  "wasm_threads_atomic_cas",
  "wasm_threads_atomic_disjoint",
];
const LABELS: Record<string, string> = {
  wasm_threads_atomic_add: "contended atomic add",
  wasm_threads_atomic_cas: "contended CAS increment",
  wasm_threads_atomic_disjoint: "disjoint atomic add",
};
const JOBS: Record<string, number> = {
  wasm_threads_atomic_add: 900000,
  wasm_threads_atomic_cas: 500000,
  wasm_threads_atomic_disjoint: 850000,
  wasm_threads_wait_notify: 30000,
};
const PINNED_WABT = "1.0.39 (ad75c5edcdff96d73c245b57fbc07607aaca9f95)",
  MODULE_SHA256 =
    "890076044756dcfb67445614cd08d0c73de9529e500d7ec13eeca424ae230d57";
type Row = Record<string, any>;
function requireValue(condition: boolean, message: string): void {
  if (!condition) throw new Error(message);
}
const output = (argv: string[], fallback = "unavailable"): string => {
  try {
    const result = run(argv);
    return result.exitCode === 0 ? result.stdout.trim() : fallback;
  } catch (_) {
    return fallback;
  }
};
const median = (rows: Row[]): number => {
  const values = rows.map((row) => row.elapsed_ns).sort((a, b) => a - b),
    middle = Math.floor(values.length / 2);
  return values.length % 2
    ? values[middle]
    : (values[middle - 1] + values[middle]) / 2;
};
const rsd = (rows: Row[]): number => {
  if (rows.length <= 1) return 0;
  const values = rows.map((row) => row.elapsed_ns),
    mean = values.reduce((a, b) => a + b, 0) / values.length;
  return (
    (Math.sqrt(
      values.reduce((sum, value) => sum + (value - mean) ** 2, 0) /
        (values.length - 1),
    ) /
      mean) *
    100
  );
};
const rowKey = (row: Row): string =>
  [row.mode, row.workload, row.lanes, row.jobs].join("\t");
export function parseRows(text: string): Row[] {
  return text
    .split("\n")
    .filter(Boolean)
    .map((line) => {
      const fields = line.split("\t");
      requireValue(
        fields.length === 8,
        `invalid runner row: ${JSON.stringify(line)}`,
      );
      return {
        engine: fields[0],
        mode: fields[1],
        workload: fields[2],
        lanes: Number(fields[3]),
        jobs: Number(fields[4]),
        sample: Number(fields[5]),
        elapsed_ns: Number(fields[6]),
        checksum: Number(fields[7]),
      };
    });
}
function runRows(
  runner: string,
  mode: string,
  workload: string,
  jobs: number,
  samples: number,
  lanes: number,
): Row[] {
  const argv = [runner, mode, workload, String(jobs), String(samples)];
  if (mode !== "single") argv.push(String(lanes));
  const result = run(argv);
  requireValue(
    result.exitCode === 0,
    result.stderr || `runner exited ${result.exitCode}`,
  );
  const rows = parseRows(result.stdout),
    expectedLanes = mode === "single" ? 1 : lanes,
    checksum = jobs * expectedLanes;
  requireValue(
    rows.length === samples,
    `${mode}/${workload}: expected ${samples} samples, got ${rows.length}`,
  );
  rows.forEach((row, sample) => {
    const expected = ["zig-js", mode, workload, expectedLanes, jobs, sample],
      actual = [
        row.engine,
        row.mode,
        row.workload,
        row.lanes,
        row.jobs,
        row.sample,
      ];
    requireValue(
      JSON.stringify(actual) === JSON.stringify(expected),
      `runner metadata mismatch: expected ${JSON.stringify(expected)}, got ${JSON.stringify(actual)}`,
    );
    requireValue(
      row.elapsed_ns > 0 && row.checksum === checksum,
      `${mode}/${workload}: invalid timing/checksum ${JSON.stringify(row)}`,
    );
  });
  return rows;
}
function probeJsc(runner: string): string[] {
  const sab = output([
      "osascript",
      "-l",
      "JavaScript",
      "-e",
      "typeof WebAssembly + ':' + typeof SharedArrayBuffer",
    ]),
    result = run([runner, "single", "wasm_threads_atomic_add", "1", "1"]);
  requireValue(
    result.exitCode !== 0,
    "system JSC unexpectedly accepted the shared-memory module; add equivalent scored rows",
  );
  return [sab, "rejected with JavaScriptException"];
}
export function collect(
  runner: string,
  samples: number,
  lanes: number[],
  quick: boolean,
): Row[] {
  const rows: Row[] = [];
  for (const workload of WORKLOADS) {
    const jobs = quick ? 10 : JOBS[workload];
    rows.push.apply(
      rows,
      runRows(runner, "single", workload, jobs, samples, 1),
    );
    for (const laneCount of lanes)
      rows.push.apply(
        rows,
        runRows(runner, "shared", workload, jobs, samples, laneCount),
      );
  }
  const waitJobs = quick ? 2 : JOBS.wasm_threads_wait_notify;
  for (const laneCount of lanes)
    rows.push.apply(
      rows,
      runRows(
        runner,
        "shared",
        "wasm_threads_wait_notify",
        waitJobs,
        samples,
        laneCount,
      ),
    );
  return rows;
}
const revision = (): string => {
  const commit = output(["git", "-C", ROOT, "rev-parse", "HEAD"]),
    dirty = output(
      [
        "git",
        "-C",
        ROOT,
        "status",
        "--porcelain",
        "--",
        "bench/comparison_zig_js.zig",
        "bench/comparison_jsc.zig",
        "bench/wasm_threads_comparison.js",
        "bench/wasm_threads_kernels.wat",
        "tools/wasm-threads-benchmark.ts",
        "build.zig",
      ],
      "",
    );
  return commit + (dirty ? " (benchmark inputs dirty)" : "");
};
function metadata(): Record<string, string> {
  const memory = output(["sysctl", "-n", "hw.memsize"]),
    gib = /^\d+$/.test(memory)
      ? `${(Number(memory) / 1024 ** 3).toFixed(1)} GiB`
      : memory;
  return {
    Date: output(["date", "+%Y-%m-%dT%H:%M:%S%z"]),
    Host: `${output(["sysctl", "-n", "machdep.cpu.brand_string"])}; ${output(["sysctl", "-n", "hw.physicalcpu"])} physical / ${output(["sysctl", "-n", "hw.logicalcpu"])} logical CPUs; ${gib}`,
    OS: `macOS ${output(["sw_vers", "-productVersion"])} (${output(["sw_vers", "-buildVersion"])})`,
    Zig: output(["zig", "version"]),
    "zig-js": revision(),
    JavaScriptCore: `system framework ${output(["plutil", "-extract", "CFBundleVersion", "raw", "/System/Library/Frameworks/JavaScriptCore.framework/Resources/Info.plist"])}`,
    "WABT source compiler": PINNED_WABT,
    "Wasm module SHA-256": MODULE_SHA256,
    Power: output(["pmset", "-g", "batt"]).split(/\s+/).join(" "),
  };
}
function grouped(rows: Row[]): Record<string, Row[]> {
  const groups: Record<string, Row[]> = {};
  for (const row of rows) {
    const key = rowKey(row);
    if (!groups[key]) groups[key] = [];
    groups[key].push(row);
  }
  return groups;
}
function findGroup(
  groups: Record<string, Row[]>,
  mode: string,
  workload: string,
  lanes: number,
): Row[] {
  const prefix = [mode, workload, lanes].join("\t") + "\t",
    key = Object.keys(groups).find((name) => name.startsWith(prefix));
  requireValue(!!key, `missing scored row ${prefix}`);
  return groups[key as string];
}
export function render(
  rows: Row[],
  lanes: number[],
  info: Record<string, string>,
  probe: string[],
): string {
  const groups = grouped(rows),
    lines = [
      `# WebAssembly Threads comparison — ${info.Date.slice(0, 10)}`,
      "",
      "> Dated measurement, not a universal engine score. Higher throughput is better.",
      "> Checksums, generation counts, timeouts, and the 120-second per-run watchdog are validated by the harness.",
      "",
      "## Environment",
      "",
      "| item | value |",
      "| --- | --- |",
    ];
  Object.keys(info).forEach((name) =>
    lines.push(`| ${name} | ${info[name]} |`),
  );
  lines.push(
    "",
    "## Atomic throughput",
    "",
    "Each operation is executed inside the same shared Wasm module. `1` worker calls the export on the owner thread; multi-worker rows spawn zig-js shared-realm `Thread`s that contend on the same instance and memory.",
    "",
    "| kernel | workers | median | operations/s | scaling vs 1 | RSD |",
    "| --- | ---: | ---: | ---: | ---: | ---: |",
  );
  for (const workload of WORKLOADS) {
    const single = findGroup(groups, "single", workload, 1),
      singleRate = single[0].jobs / (median(single) / 1e9),
      variants: any[][] = [["single", 1]];
    for (const lane of lanes) variants.push(["shared", lane]);
    for (const variant of variants) {
      const lane = variant[1],
        group = findGroup(groups, variant[0], workload, lane),
        rate = (group[0].jobs * lane) / (median(group) / 1e9);
      lines.push(
        `| ${LABELS[workload]} | ${lane} | ${(median(group) / 1e6).toFixed(2)} ms | ${(rate / 1e6).toFixed(2)} M/s | ${(rate / singleRate).toFixed(2)}x | ${rsd(group).toFixed(2)}% |`,
      );
    }
  }
  lines.push(
    "",
    "## Wait/notify handoffs",
    "",
    "Workers are paired. Each generation increments a request counter, parks with `memory.atomic.wait32`, increments an acknowledgement counter, and wakes with `memory.atomic.notify`; the harness rejects timeouts or mismatched final generations.",
    "",
    "| workers | median | pair handoffs/s | RSD |",
    "| ---: | ---: | ---: | ---: |",
  );
  for (const lane of lanes) {
    const group = findGroup(groups, "shared", "wasm_threads_wait_notify", lane),
      handoffs = (group[0].jobs * lane) / 2;
    lines.push(
      `| ${lane} | ${(median(group) / 1e6).toFixed(2)} ms | ${(handoffs / (median(group) / 1e9)).toLocaleString("en-US", { maximumFractionDigits: 0 })} | ${rsd(group).toFixed(2)}% |`,
    );
  }
  lines.push(
    "",
    "## JavaScriptCore comparison boundary",
    "",
    "The system JSC public embedding API was probed before scoring. There is no equivalent row to report for this module:",
    "",
    "| probe | result |",
    "| --- | --- |",
    `| automation JavaScript context (\`typeof WebAssembly:typeof SharedArrayBuffer\`) | \`${probe[0]}\` |`,
    `| shared-memory/atomic module through \`JSGlobalContext\` | ${probe[1]} |`,
    "| equivalent shared-realm worker API | not present in the public C API |",
    "",
    "JSC is therefore `N/A`, not zero and not slower. The main README comparison separately scores zig-js and system JSC for equivalent single and independent-context workloads.",
    "",
    "## Method and timing boundary",
    "",
    `The artifact contains ${rows.length.toLocaleString("en-US")} raw samples across ${Object.keys(groups).length} rows. Module decoding, validation, instantiation, JavaScript setup, and warm-up are outside the timer.`,
    "The published performance support boundary is the macOS arm64 host recorded above; this artifact makes no Linux or x86 throughput claim. Portable correctness and sanitizer hosts are tracked separately.",
    "Single-worker rows time one selected Wasm invocation. Multi-worker rows deliberately include shared-realm `Thread` construction, dispatch, joins, and the final checksum/generation validation; every worker executes the displayed per-worker job count.",
    "Contended add targets word zero. CAS retries until each requested increment commits. Disjoint add assigns one cache-adjacent word per worker. Wait/notify uses two monotonic words per pair so scheduling delays cannot lose a generation.",
    "",
    "## Reproduce",
    "",
    "```sh",
    "zig build wasm-threads-benchmark -Doptimize=ReleaseFast",
    "zig build wasm-threads-benchmark -Doptimize=ReleaseFast -Dwasm-threads-benchmark-quick=true",
    "```",
    "",
    "Regenerate the embedded module after editing its readable source:",
    "",
    "```sh",
    "wat2wasm --enable-threads bench/wasm_threads_kernels.wat -o /tmp/wasm_threads_kernels.wasm",
    "shasum -a 256 /tmp/wasm_threads_kernels.wasm",
    "```",
    "",
  );
  return lines.join("\n");
}
function writeRaw(rows: Row[], path: string): void {
  writeText(
    path,
    "engine\tmode\tworkload\tlanes\tjobs\tsample\telapsed_ns\tchecksum\n" +
      rows
        .map((row) =>
          [
            row.engine,
            row.mode,
            row.workload,
            row.lanes,
            row.jobs,
            row.sample,
            row.elapsed_ns,
            row.checksum,
          ].join("\t"),
        )
        .join("\n") +
      "\n",
  );
}
export function selfTest(): void {
  const rows = parseRows(
    "zig-js\tshared\twasm_threads_atomic_add\t2\t10\t0\t3\t20\n",
  );
  requireValue(
    rows.length === 1 && rows[0].checksum === 20,
    "row parse failed",
  );
  let failed = false;
  try {
    parseRows("bad");
  } catch (_) {
    failed = true;
  }
  requireValue(failed, "malformed row was accepted");
  console.log("wasm-threads-benchmark self-test: ok");
}
function main(): void {
  const args = process.argv.slice(2);
  if (args.length === 1 && args[0] === "--self-test") return selfTest();
  const positional: string[] = [],
    options: any = { samples: 7, lanes: "2,4,8", quick: false };
  for (let index = 0; index < args.length; index += 1) {
    const name = args[index];
    if (!name.startsWith("--")) positional.push(name);
    else if (name === "--quick") options.quick = true;
    else {
      const value = args[++index];
      if (name === "--samples") options.samples = Number(value);
      else if (name === "--lanes") options.lanes = value;
      else if (name === "--raw-out") options.raw = value;
      else if (name === "--markdown-out") options.markdown = value;
      else throw new Error(`unknown argument: ${name}`);
    }
  }
  const zigRunner =
      positional[0] || `${ROOT}/zig-out/bin/bench-comparison-zig-js`,
    jscRunner = positional[1] || `${ROOT}/zig-out/bin/bench-comparison-jsc`,
    lanes: number[] = [];
  String(options.lanes)
    .split(",")
    .forEach((value) => {
      const lane = Number(value);
      if (!lanes.includes(lane)) lanes.push(lane);
    });
  requireValue(
    options.samples > 0 &&
      lanes.length > 0 &&
      lanes.every((lane) => lane >= 2 && lane % 2 === 0),
    "--samples must be positive and --lanes must contain even integers >= 2",
  );
  requireValue(
    fileExists(zigRunner) && fileExists(jscRunner),
    "missing comparison runner; build benchmark-comparison-bin first",
  );
  const rows = collect(
      zigRunner,
      options.quick ? 1 : options.samples,
      lanes,
      options.quick,
    ),
    report = render(rows, lanes, metadata(), probeJsc(jscRunner));
  if (options.raw) writeRaw(rows, options.raw);
  if (options.markdown) writeText(options.markdown, report);
  else console.log(report);
}
if (process.argv[1] === __filename) main();
