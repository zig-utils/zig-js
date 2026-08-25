/** Benchmark zig-js and system JSC WebAssembly SIMD against scalar oracles. */
import { fileExists, run, writeText } from "./lib/home";
declare const __dirname: string;
declare const __filename: string;
const ROOT =
  __dirname === "tools"
    ? "."
    : __dirname.slice(0, __dirname.lastIndexOf("/tools"));
const RUNNERS: Record<string, string> = {
  "zig-js": `${ROOT}/zig-out/bin/bench-comparison-zig-js`,
  JavaScriptCore: `${ROOT}/zig-out/bin/bench-comparison-jsc`,
};
const BASE: Record<string, number> = {
  integer: 20000,
  float: 20000,
  shuffle: 4000,
  memory: 20000,
};
const JOBS: Record<string, number> = {
  wasm_integer_simd: 200,
  wasm_integer_scalar: 160,
  wasm_float_simd: 180,
  wasm_float_scalar: 180,
  wasm_shuffle_simd: 800,
  wasm_shuffle_scalar: 35,
  wasm_memory_simd: 180,
  wasm_memory_scalar: 120,
};
const FAMILIES = Object.keys(BASE),
  KINDS = ["simd", "scalar"],
  MODES = ["single", "independent_steady"];
const PINNED_WABT = "1.0.39 (ad75c5edcdff96d73c245b57fbc07607aaca9f95)",
  MODULE_SHA256 =
    "5f33169c01f36873c1ac4ec8bb07675b8d4d770a6a4f3d961454f139f1818957";
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
const median = (values: number[]): number => {
  const ordered = values.slice().sort((a, b) => a - b),
    middle = Math.floor(ordered.length / 2);
  return ordered.length % 2
    ? ordered[middle]
    : (ordered[middle - 1] + ordered[middle]) / 2;
};
const rsdValues = (values: number[]): number => {
  if (values.length <= 1) return 0;
  const mean = values.reduce((a, b) => a + b, 0) / values.length;
  return (
    (Math.sqrt(
      values.reduce((sum, value) => sum + (value - mean) ** 2, 0) /
        (values.length - 1),
    ) /
      mean) *
    100
  );
};
const key = (row: Row): string =>
  [row.engine, row.mode, row.workload, row.lanes, row.jobs].join("\t");
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
  engine: string,
  mode: string,
  workload: string,
  jobs: number,
  samples: number,
  lanes: number,
): Row[] {
  const argv = [RUNNERS[engine], mode, workload, String(jobs), String(samples)];
  if (mode !== "single") argv.push(String(lanes));
  const result = run(argv);
  requireValue(
    result.exitCode === 0,
    result.stderr || `runner exited ${result.exitCode}`,
  );
  const rows = parseRows(result.stdout),
    expectedLanes = mode === "single" ? 1 : lanes;
  requireValue(
    rows.length === samples,
    `${engine}/${mode}/${workload}: expected ${samples} samples, got ${rows.length}`,
  );
  rows.forEach((row, sample) => {
    const expected = [engine, mode, workload, expectedLanes, jobs, sample],
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
      row.elapsed_ns > 0,
      `${engine}/${mode}/${workload}: non-positive elapsed time`,
    );
  });
  requireValue(
    rows.every((row) => row.checksum === rows[0].checksum),
    `${engine}/${mode}/${workload}: checksum changed between samples`,
  );
  return rows;
}
function validateOracles(): void {
  const checksums: Record<string, number> = {};
  for (const engine of Object.keys(RUNNERS)) {
    for (const family of FAMILIES) {
      for (const kind of KINDS) {
        const workload = `wasm_${family}_${kind}`;
        checksums[`${engine}\t${workload}`] = runRows(
          engine,
          "single",
          workload,
          1,
          1,
          1,
        )[0].checksum;
      }
      requireValue(
        checksums[`${engine}\twasm_${family}_simd`] ===
          checksums[`${engine}\twasm_${family}_scalar`],
        `${engine}/${family}: SIMD checksum differs from scalar oracle`,
      );
    }
    for (const workload of Object.keys(JOBS)) {
      const other = engine === "zig-js" ? "JavaScriptCore" : "zig-js";
      if (checksums[`${other}\t${workload}`] !== undefined)
        requireValue(
          checksums[`${engine}\t${workload}`] ===
            checksums[`${other}\t${workload}`],
          `${workload}: cross-engine checksum mismatch`,
        );
    }
  }
}
export function collect(samples: number, lanes: number, quick: boolean): Row[] {
  validateOracles();
  const rows: Row[] = [];
  let ordinal = 0;
  for (const mode of MODES)
    for (const family of FAMILIES)
      for (const kind of KINDS) {
        const workload = `wasm_${family}_${kind}`,
          jobs = quick ? 1 : JOBS[workload],
          engines = Object.keys(RUNNERS);
        if (ordinal % 2) engines.reverse();
        for (const engine of engines)
          rows.push.apply(
            rows,
            runRows(engine, mode, workload, jobs, samples, lanes),
          );
        ordinal += 1;
      }
  return rows;
}
const logicalUpdates = (
  family: string,
  jobs: number,
  lanes: number,
): number => {
  let total = 0;
  for (let lane = 0; lane < lanes; lane += 1)
    for (let job = 0; job < jobs; job += 1)
      total += BASE[family] + ((job + lane) & 15);
  return total;
};
function grouped(rows: Row[]): Record<string, Row[]> {
  const groups: Record<string, Row[]> = {};
  for (const row of rows) {
    const name = key(row);
    if (!groups[name]) groups[name] = [];
    groups[name].push(row);
  }
  return groups;
}
function selected(
  groups: Record<string, Row[]>,
  engine: string,
  mode: string,
  family: string,
  kind: string,
  lanes: number,
): Row[] {
  const prefix =
      [engine, mode, `wasm_${family}_${kind}`, lanes].join("\t") + "\t",
    name = Object.keys(groups).find((candidate) =>
      candidate.startsWith(prefix),
    );
  requireValue(!!name, `missing row ${prefix}`);
  return groups[name as string];
}
function rate(
  groups: Record<string, Row[]>,
  engine: string,
  mode: string,
  family: string,
  kind: string,
  lanes: number,
): number {
  const rows = selected(groups, engine, mode, family, kind, lanes);
  return (
    logicalUpdates(family, rows[0].jobs, lanes) /
    (median(rows.map((row) => row.elapsed_ns)) / 1e9)
  );
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
        "bench/wasm_simd_comparison.js",
        "bench/wasm_simd_kernels.wat",
        "tools/wasm-simd-benchmark.ts",
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
export function render(
  rows: Row[],
  lanes: number,
  info: Record<string, string>,
): string {
  const groups = grouped(rows),
    lines = [
      `# WebAssembly SIMD comparison — ${info.Date.slice(0, 10)}`,
      "",
      "> Dated measurement, not a universal engine score. Lower elapsed time and higher throughput are better.",
      "> Every SIMD kernel has a byte-identical-module scalar oracle; the harness rejects checksum disagreement.",
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
    "## SIMD throughput",
    "",
    "Throughput is millions of logical 128-bit state updates per second, normalized by the exact inner-loop count.",
    `The \`${lanes}-thread\` rows use \`${lanes}\` warmed, independent contexts and module instances on persistent OS workers.`,
    "",
    `| family | zig-js 1-thread | zig-js ${lanes}-thread | zig-js scaling | JSC 1-thread | JSC ${lanes}-thread | JSC scaling | zig-js / JSC, 1-thread | zig-js / JSC, ${lanes}-thread | max RSD |`,
    "| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |",
  );
  for (const family of FAMILIES) {
    const z1 = rate(groups, "zig-js", "single", family, "simd", 1),
      zm = rate(groups, "zig-js", "independent_steady", family, "simd", lanes),
      j1 = rate(groups, "JavaScriptCore", "single", family, "simd", 1),
      jm = rate(
        groups,
        "JavaScriptCore",
        "independent_steady",
        family,
        "simd",
        lanes,
      ),
      dispersion = Math.max.apply(
        null,
        Object.keys(RUNNERS).reduce(
          (all: number[], engine) =>
            all.concat(
              MODES.map((mode) =>
                rsdValues(
                  selected(
                    groups,
                    engine,
                    mode,
                    family,
                    "simd",
                    mode === "single" ? 1 : lanes,
                  ).map((row) => row.elapsed_ns),
                ),
              ),
            ),
          [],
        ),
      );
    lines.push(
      `| \`${family}\` | ${(z1 / 1e6).toFixed(2)} M/s | ${(zm / 1e6).toFixed(2)} M/s | ${(zm / z1).toFixed(2)}x | ${(j1 / 1e6).toFixed(2)} M/s | ${(jm / 1e6).toFixed(2)} M/s | ${(jm / j1).toFixed(2)}x | ${(z1 / j1).toFixed(2)}x | ${(zm / jm).toFixed(2)}x | ${dispersion.toFixed(2)}% |`,
    );
  }
  lines.push(
    "",
    "## SIMD speedup over the scalar oracle",
    "",
    "Each cell is SIMD logical-update throughput divided by its semantically equivalent scalar export.",
    "Values above `1.00x` favor SIMD; the scalar path deliberately performs the same lane work without vector instructions.",
    "",
    `| family | zig-js 1-thread | zig-js ${lanes}-thread | JSC 1-thread | JSC ${lanes}-thread |`,
    "| --- | ---: | ---: | ---: | ---: |",
  );
  for (const family of FAMILIES) {
    const values: number[] = [];
    for (const engine of Object.keys(RUNNERS))
      for (const mode of MODES) {
        const laneCount = mode === "single" ? 1 : lanes;
        values.push(
          rate(groups, engine, mode, family, "simd", laneCount) /
            rate(groups, engine, mode, family, "scalar", laneCount),
        );
      }
    lines.push(
      `| \`${family}\` | ${values.map((value) => `${value.toFixed(2)}x`).join(" | ")} |`,
    );
  }
  const medians = Object.keys(groups).map(
    (name) => median(groups[name].map((row) => row.elapsed_ns)) / 1e6,
  );
  lines.push(
    "",
    "## Method and boundaries",
    "",
    `The run contains ${rows.length.toLocaleString("en-US")} raw samples (${Object.keys(groups).length} scored rows). Each row is sampled independently; engine launch order alternates by workload.`,
    `Scored-row medians span ${Math.min.apply(null, medians).toFixed(1)}–${Math.max.apply(null, medians).toFixed(1)} ms. The timer excludes process launch, source evaluation, module compilation/instantiation, and three warm-up invocations.`,
    "Single-thread timing covers only `__benchmarkSelected(jobs, lane)`. Multi-thread timing covers symmetric semaphore dispatch, one invocation per persistent worker, and the completion wait.",
    "The two engines receive the exact same JavaScript, Wasm bytes, job counts, and logical update counts. Independent contexts are the common public-API concurrency model; zig-js shared-realm Threads are intentionally outside this cross-engine panel.",
    "The integer kernel uses `i32x4.add/mul`; float uses `f32x4.add/mul`; shuffle rotates all 16 bytes with `i8x16.shuffle`; memory uses aligned `v128.load/store`. Scalar exports live in the same module and return identical checksums.",
    "",
    "## Reproduce",
    "",
    "```sh",
    "zig build benchmark-comparison-bin -Doptimize=ReleaseFast",
    `home-tool run tools/wasm-simd-benchmark.ts --samples ${groups[Object.keys(groups)[0]].length} --lanes ${lanes} \\`,
    "  --raw-out docs/.data/wasm-simd-benchmark-YYYY-MM-DD.tsv \\",
    "  --markdown-out docs/.data/wasm-simd-benchmark-YYYY-MM-DD.md",
    "```",
    "",
    "Regenerate the embedded module after editing the readable source:",
    "",
    "```sh",
    "wat2wasm --enable-all bench/wasm_simd_kernels.wat -o /tmp/wasm_simd_kernels.wasm",
    "shasum -a 256 /tmp/wasm_simd_kernels.wasm",
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
  const rows = parseRows("zig-js\tsingle\twasm_integer_simd\t1\t2\t0\t3\t4\n");
  requireValue(
    rows.length === 1 && rows[0].elapsed_ns === 3,
    "row parse failed",
  );
  let failed = false;
  try {
    parseRows("bad");
  } catch (_) {
    failed = true;
  }
  requireValue(failed, "malformed row was accepted");
  console.log("wasm-simd-benchmark self-test: ok");
}
function main(): void {
  const args = process.argv.slice(2);
  if (args.length === 1 && args[0] === "--self-test") return selfTest();
  const options: any = { samples: 7, lanes: 8, quick: false };
  for (let index = 0; index < args.length; index += 1) {
    const name = args[index];
    if (name === "--quick") options.quick = true;
    else {
      const value = args[++index];
      if (name === "--samples") options.samples = Number(value);
      else if (name === "--lanes") options.lanes = Number(value);
      else if (name === "--raw-out") options.raw = value;
      else if (name === "--markdown-out") options.markdown = value;
      else throw new Error(`unknown argument: ${name}`);
    }
  }
  requireValue(
    options.samples > 0 && options.lanes > 1,
    "--samples must be positive and --lanes must be greater than one",
  );
  Object.keys(RUNNERS).forEach((engine) =>
    requireValue(
      fileExists(RUNNERS[engine]),
      `missing ${RUNNERS[engine]}; run zig build benchmark-comparison-bin -Doptimize=ReleaseFast`,
    ),
  );
  const rows = collect(
      options.quick ? 1 : options.samples,
      options.lanes,
      options.quick,
    ),
    report = render(rows, options.lanes, metadata());
  if (options.raw) writeRaw(rows, options.raw);
  if (options.markdown) writeText(options.markdown, report);
  else console.log(report);
}
if (process.argv[1] === __filename) main();
