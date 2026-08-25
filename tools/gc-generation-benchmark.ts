/** Run and publish the generational nursery policy benchmark. */
import { readText, run, writeText } from "./lib/home";
declare const __dirname: string;
declare const __filename: string;
const ROOT =
  __dirname === "tools"
    ? "."
    : __dirname.slice(0, __dirname.lastIndexOf("/tools"));
const MIB = 1024 * 1024;
export const README_START = "<!-- gc-generation:start -->";
export const README_END = "<!-- gc-generation:end -->";
const FIELDS = [
  "trigger",
  "scenario",
  "tenuring_age",
  "moving",
  "trigger_bytes",
  "sample",
  "rounds",
  "batch",
  "elapsed_ns",
  "checksum",
  "minor_collections",
  "full_collections",
  "young_input_bytes",
  "survived_bytes",
  "reclaimed_bytes",
  "promoted_bytes",
  "moving_minor_collections",
  "moved_cells",
  "moved_bytes",
  "move_failures",
  "live_bytes",
  "young_bytes",
  "next_threshold_bytes",
  "backing_chunks",
  "backing_capacity_bytes",
  "pause_total_ns",
  "pause_max_ns",
  "cooperative_attempts",
  "cooperative_collections",
  "cooperative_parks",
  "cooperative_timeouts",
];
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
const sum = (values: number[]): number =>
  values.reduce((total, value) => total + value, 0);
const rsd = (values: number[]): number => {
  if (values.length <= 1) return 0;
  const mean = sum(values) / values.length;
  return (
    (Math.sqrt(
      sum(values.map((value) => (value - mean) ** 2)) / (values.length - 1),
    ) /
      mean) *
    100
  );
};
const percentile = (values: number[], fraction: number): number => {
  const ordered = values.slice().sort((a, b) => a - b),
    index = (ordered.length - 1) * fraction,
    lower = Math.floor(index),
    upper = Math.min(lower + 1, ordered.length - 1);
  return ordered[lower] + (ordered[upper] - ordered[lower]) * (index - lower);
};
const percentage = (numerator: number, denominator: number): number =>
  denominator ? (numerator / denominator) * 100 : 0;
const equal = (left: any, right: any): boolean =>
  JSON.stringify(left) === JSON.stringify(right);

export function parseRow(text: string): Row {
  const lines = text.split("\n").filter(Boolean);
  requireValue(
    lines.length === 1,
    `expected one runner row, got ${JSON.stringify(lines)}`,
  );
  const values = lines[0].split("\t");
  requireValue(
    values.length === FIELDS.length,
    `invalid runner row with ${values.length} fields: ${JSON.stringify(lines[0])}`,
  );
  const row: Row = {};
  FIELDS.forEach(
    (field, index) =>
      (row[field] = index < 2 ? values[index] : Number(values[index])),
  );
  return row;
}
export function validateRow(row: Row, quick: boolean): void {
  requireValue(
    ["forced", "automatic", "shared"].includes(row.trigger),
    `invalid trigger: ${row.trigger}`,
  );
  requireValue(
    ["ephemeral", "mixed", "high"].includes(row.scenario) &&
      [1, 3].includes(row.tenuring_age) &&
      [0, 1].includes(row.moving),
    `invalid policy row: ${JSON.stringify(row)}`,
  );
  const expected =
    row.rounds * row.batch * row.batch * (row.trigger === "shared" ? 3 : 1);
  requireValue(
    row.checksum === expected && row.elapsed_ns > 0,
    `checksum/timing failure: ${JSON.stringify(row)}`,
  );
  requireValue(
    quick || row.elapsed_ns >= 50000000,
    `sample is below the 50 ms timing floor: ${JSON.stringify(row)}`,
  );
  requireValue(
    row.minor_collections > 0 &&
      row.full_collections === (row.trigger === "shared" && row.moving ? 1 : 0),
    `invalid collection mix: ${JSON.stringify(row)}`,
  );
  requireValue(
    row.young_input_bytes === row.survived_bytes + row.reclaimed_bytes,
    `minor byte conservation failure: ${JSON.stringify(row)}`,
  );
  requireValue(
    row.promoted_bytes <= row.survived_bytes &&
      row.pause_total_ns >= row.pause_max_ns &&
      row.pause_max_ns > 0,
    `invalid promotion/pause telemetry: ${JSON.stringify(row)}`,
  );
  const movement = [
    row.moving_minor_collections,
    row.moved_cells,
    row.moved_bytes,
    row.move_failures,
  ];
  if (row.moving)
    requireValue(
      row.moving_minor_collections > 0 &&
        (row.scenario === "ephemeral" ||
          (row.moved_cells > 0 && row.moved_bytes > 0)) &&
        row.move_failures === 0,
      `invalid moving-minor telemetry: ${JSON.stringify(row)}`,
    );
  else
    requireValue(
      equal(movement, [0, 0, 0, 0]),
      `unexpected moving-minor telemetry: ${JSON.stringify(row)}`,
    );
  requireValue(
    row.next_threshold_bytes >= 4 * MIB &&
      row.backing_chunks > 0 &&
      row.backing_capacity_bytes > 0,
    `invalid heap telemetry: ${JSON.stringify(row)}`,
  );
  const cooperative = [
    row.cooperative_attempts,
    row.cooperative_collections,
    row.cooperative_parks,
    row.cooperative_timeouts,
  ];
  if (row.trigger === "shared")
    requireValue(
      Math.min(cooperative[0], cooperative[1], cooperative[2]) > 0 &&
        cooperative[1] <= cooperative[0] &&
        cooperative[3] <= (row.moving ? 2 : 0),
      `invalid cooperative rendezvous: ${JSON.stringify(row)}`,
    );
  else
    requireValue(
      equal(cooperative, [0, 0, 0, 0]),
      `unexpected cooperative telemetry: ${JSON.stringify(row)}`,
    );
}
function configurations(quick: boolean): any[][] {
  const result: any[][] = [];
  if (quick) {
    for (const scenario of ["ephemeral", "mixed", "high"])
      for (const moving of [0, 1])
        result.push(["forced", scenario, moving, 4 * MIB, 4, 2048]);
    for (const moving of [0, 1])
      result.push(["shared", "mixed", moving, 43 * MIB, 4, 8000]);
  } else {
    for (const scenario of ["ephemeral", "mixed", "high"])
      for (const moving of [0, 1])
        result.push(["forced", scenario, moving, 4 * MIB, 8, 24576]);
    for (const moving of [0, 1])
      result.push(["shared", "mixed", moving, 43 * MIB, 12, 8000]);
  }
  return result;
}
function runOne(
  runner: string,
  config: any[],
  age: number,
  sample: number,
): Row {
  const argv = [
      runner,
      String(config[0]),
      String(config[1]),
      String(age),
      String(config[2]),
      String(config[3]),
      String(config[4]),
      String(config[5]),
      String(sample),
    ],
    result = run(argv);
  requireValue(
    result.exitCode === 0,
    `runner failed with exit ${result.exitCode}: ${argv.join(" ")}\nstdout:\n${result.stdout || "<empty>"}\nstderr:\n${result.stderr || "<empty>"}`,
  );
  return parseRow(result.stdout);
}
export function collect(
  runner: string,
  samples: number,
  warmups: number,
  quick: boolean,
): Row[] {
  const rows: Row[] = [];
  for (const config of configurations(quick)) {
    for (let warmup = 0; warmup < warmups; warmup += 1)
      for (const age of [1, 3])
        validateRow(runOne(runner, config, age, warmup), quick);
    for (let sample = 0; sample < samples; sample += 1) {
      const ages = sample % 2 === 0 ? [1, 3] : [3, 1];
      for (const age of ages) {
        const row = runOne(runner, config, age, sample);
        validateRow(row, quick);
        rows.push(row);
      }
    }
  }
  rows.sort(
    (a, b) =>
      String(a.trigger).localeCompare(String(b.trigger)) ||
      String(a.scenario).localeCompare(String(b.scenario)) ||
      a.trigger_bytes - b.trigger_bytes ||
      a.moving - b.moving ||
      a.tenuring_age - b.tenuring_age ||
      a.sample - b.sample,
  );
  return rows;
}
const ageKey = (row: Row): string =>
  [row.trigger, row.scenario, row.trigger_bytes, row.moving].join("\t");
const movingKey = (row: Row): string =>
  [row.trigger, row.scenario, row.trigger_bytes, row.tenuring_age].join("\t");
function uniqueKeys(rows: Row[], key: (row: Row) => string): string[] {
  const keys: string[] = [];
  for (const row of rows) if (!keys.includes(key(row))) keys.push(key(row));
  return keys.sort();
}
function groups(rows: Row[]): any[][] {
  return uniqueKeys(rows, ageKey).map((key) => {
    const matching = rows.filter((row) => ageKey(row) === key);
    return [
      key.split("\t"),
      matching.filter((row) => row.tenuring_age === 1),
      matching.filter((row) => row.tenuring_age === 3),
    ];
  });
}
function movingGroups(rows: Row[]): any[][] {
  return uniqueKeys(rows, movingKey).map((key) => {
    const matching = rows.filter((row) => movingKey(row) === key);
    return [
      key.split("\t"),
      matching.filter((row) => row.moving === 0),
      matching.filter((row) => row.moving === 1),
    ];
  });
}
export function validateMatrix(
  rows: Row[],
  samples: number,
  quick: boolean,
): void {
  const indexes = Array.from({ length: samples }, (_, index) => index);
  for (const group of groups(rows)) {
    const key = group[0],
      ageOne = group[1],
      ageThree = group[2];
    requireValue(
      equal(
        ageOne.map((row: Row) => row.sample),
        indexes,
      ) &&
        equal(
          ageThree.map((row: Row) => row.sample),
          indexes,
        ),
      `missing or duplicate samples for ${key.join(",")}`,
    );
    if (!quick) {
      for (const ageRows of [ageOne, ageThree])
        requireValue(
          rsd(ageRows.map((row: Row) => row.elapsed_ns)) <= 15,
          `elapsed dispersion exceeds 15% for ${key.join(",")}, age ${ageRows[0].tenuring_age}`,
        );
      const one = median(ageOne.map((row: Row) => row.elapsed_ns)),
        three = median(ageThree.map((row: Row) => row.elapsed_ns));
      requireValue(
        !(
          three > one * 1.2 &&
          Math.max(
            rsd(ageOne.map((row: Row) => row.elapsed_ns)),
            rsd(ageThree.map((row: Row) => row.elapsed_ns)),
          ) <= 5
        ),
        `stable age-three throughput regression exceeds 20% for ${key.join(",")}`,
      );
    }
  }
  for (const group of movingGroups(rows))
    requireValue(
      equal(
        group[1].map((row: Row) => row.sample),
        indexes,
      ) &&
        equal(
          group[2].map((row: Row) => row.sample),
          indexes,
        ),
      `missing exact moving parent for ${group[0].join(",")}`,
    );
}
const revision = (path: string): string => {
  const commit = output(["git", "-C", path, "rev-parse", "HEAD"]),
    dirty = output(
      ["git", "-C", path, "status", "--porcelain", "--untracked-files=no"],
      "",
    );
  return commit + (dirty ? " (tracked worktree dirty)" : "");
};
export function metadata(): Record<string, string> {
  const memory = output(["sysctl", "-n", "hw.memsize"]),
    memoryGiB = /^\d+$/.test(memory)
      ? `${(Number(memory) / 1024 ** 3).toFixed(1)} GiB`
      : memory;
  return {
    Date: output(["date", "+%F"]),
    Host: `${output(["sysctl", "-n", "machdep.cpu.brand_string"])}; ${output(["sysctl", "-n", "hw.physicalcpu"])} physical / ${output(["sysctl", "-n", "hw.logicalcpu"])} logical CPUs; ${memoryGiB}`,
    OS: `macOS ${output(["sw_vers", "-productVersion"], output(["uname", "-a"]))} (${output(["sw_vers", "-buildVersion"])})`,
    Zig: output(["zig", "version"]),
    "zig-js": revision(ROOT),
    "zig-gc": revision(`${ROOT}/../zig-gc`),
    Power: output(["pmset", "-g", "batt"]).split(/\s+/).join(" "),
  };
}
export function render(
  rows: Row[],
  info: Record<string, string>,
  rawPath: string | null,
): string {
  const lines = [
    `# GC generation policy — ${info.Date}`,
    "",
    "> Dated nursery-policy evidence, not a general application benchmark.",
    "> Exact moving/non-moving parents, exact work/checksums, alternating age order, a 50 ms timing floor, byte conservation, zero unscheduled full-GC contamination, zero movement failures, zero conservative-parent timeouts, and at most two bounded moving retries are enforced. Shared moving rows include the one production automatic-compaction follow-on.",
    "",
    "## Environment",
    "",
    "| item | value |",
    "| --- | --- |",
  ];
  Object.keys(info).forEach((key) => lines.push(`| ${key} | ${info[key]} |`));
  lines.push(
    "",
    "## Age-three policy versus age-one control",
    "",
    "| trigger | workload | trigger | movement | age 1 median | age 3 median | age 3 throughput | age 3 pause p50 / p95 | age 1 → age 3 promoted | age 1 → age 3 retained backing |",
    "| --- | --- | ---: | --- | ---: | ---: | ---: | ---: | ---: | ---: |",
  );
  for (const group of groups(rows)) {
    const key = group[0],
      one: Row[] = group[1],
      three: Row[] = group[2],
      elapsedOne = median(one.map((row) => row.elapsed_ns)),
      elapsedThree = median(three.map((row) => row.elapsed_ns)),
      pauses = three.map((row) => row.pause_max_ns),
      promotedOne = percentage(
        sum(one.map((row) => row.promoted_bytes)),
        sum(one.map((row) => row.young_input_bytes)),
      ),
      promotedThree = percentage(
        sum(three.map((row) => row.promoted_bytes)),
        sum(three.map((row) => row.young_input_bytes)),
      ),
      backingOne = median(one.map((row) => row.backing_capacity_bytes)) / MIB,
      backingThree =
        median(three.map((row) => row.backing_capacity_bytes)) / MIB;
    lines.push(
      `| ${key[0]} | ${key[1]} | ${(Number(key[2]) / MIB).toFixed(2)} MiB | ${Number(key[3]) ? "moving" : "non-moving"} | ${(elapsedOne / 1e6).toFixed(2)} ms | ${(elapsedThree / 1e6).toFixed(2)} ms | **${(elapsedOne / elapsedThree).toFixed(2)}x** | ${(median(pauses) / 1e6).toFixed(3)} / ${(percentile(pauses, 0.95) / 1e6).toFixed(3)} ms | ${promotedOne.toFixed(1)}% → ${promotedThree.toFixed(1)}% | ${backingOne.toFixed(2)} → ${backingThree.toFixed(2)} MiB |`,
    );
  }
  lines.push(
    "",
    "Age-three is the production policy; age one is the control. Every moving row has an exact non-moving parent with the same trigger, workload, age, sample, and checksum. Forced rows isolate the quiescent minor pause after each equal allocation round. Shared rows run three JavaScript mutators without a context GIL and use the displayed cooperative allocation tranche.",
    "",
    "## Moving age-three exact-parent comparison",
    "",
    "| trigger | workload | trigger | non-moving median | moving median | moving throughput | moving pause p50 / p95 | copied | promoted | retained backing | timeouts |",
    "| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |",
  );
  for (const group of movingGroups(rows)) {
    const key = group[0];
    if (Number(key[3]) !== 3) continue;
    const nonmoving: Row[] = group[1],
      moving: Row[] = group[2],
      nonmovingElapsed = median(nonmoving.map((row) => row.elapsed_ns)),
      movingElapsed = median(moving.map((row) => row.elapsed_ns)),
      pauses = moving.map((row) => row.pause_max_ns),
      promoted = percentage(
        sum(moving.map((row) => row.promoted_bytes)),
        sum(moving.map((row) => row.young_input_bytes)),
      );
    lines.push(
      `| ${key[0]} | ${key[1]} | ${(Number(key[2]) / MIB).toFixed(2)} MiB | ${(nonmovingElapsed / 1e6).toFixed(2)} ms | ${(movingElapsed / 1e6).toFixed(2)} ms | **${(nonmovingElapsed / movingElapsed).toFixed(2)}x** | ${(median(pauses) / 1e6).toFixed(3)} / ${(percentile(pauses, 0.95) / 1e6).toFixed(3)} ms | ${(sum(moving.map((row) => row.moved_bytes)) / MIB).toFixed(2)} MiB | ${promoted.toFixed(1)}% | ${(median(moving.map((row) => row.backing_capacity_bytes)) / MIB).toFixed(2)} MiB | ${sum(moving.map((row) => row.cooperative_timeouts))} |`,
    );
  }
  lines.push(
    "",
    "## Telemetry and dispersion",
    "",
    "| trigger | workload | configured trigger | movement | age | elapsed RSD | reclaimed | survived | minor / moving / full | copied | pause max | rendezvous attempts / parks / timeouts |",
    "| --- | --- | ---: | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |",
  );
  for (const group of groups(rows))
    for (const ageRows of [group[1], group[2]]) {
      const first: Row = ageRows[0],
        young = sum(ageRows.map((row: Row) => row.young_input_bytes));
      lines.push(
        `| ${group[0][0]} | ${group[0][1]} | ${(Number(group[0][2]) / MIB).toFixed(2)} MiB | ${first.moving ? "moving" : "non-moving"} | ${first.tenuring_age} | ${rsd(ageRows.map((row: Row) => row.elapsed_ns)).toFixed(2)}% | ${percentage(sum(ageRows.map((row: Row) => row.reclaimed_bytes)), young).toFixed(1)}% | ${percentage(sum(ageRows.map((row: Row) => row.survived_bytes)), young).toFixed(1)}% | ${median(ageRows.map((row: Row) => row.minor_collections)).toFixed(0)} / ${median(ageRows.map((row: Row) => row.moving_minor_collections)).toFixed(0)} / ${median(ageRows.map((row: Row) => row.full_collections)).toFixed(0)} | ${(sum(ageRows.map((row: Row) => row.moved_bytes)) / MIB).toFixed(2)} MiB | ${(
          Math.max.apply(
            null,
            ageRows.map((row: Row) => row.pause_max_ns),
          ) / 1e6
        ).toFixed(
          3,
        )} ms | ${sum(ageRows.map((row: Row) => row.cooperative_attempts))} / ${sum(ageRows.map((row: Row) => row.cooperative_parks))} / ${sum(ageRows.map((row: Row) => row.cooperative_timeouts))} |`,
      );
    }
  const rawLine = rawPath
    ? `Raw evidence: [${rawPath.split("/").pop()}](${rawPath.split("/").pop()})`
    : "Pass --raw-out to preserve the raw TSV.";
  lines.push(
    "",
    "## Method",
    "",
    "Ephemeral rows retain nothing. Mixed rows retain 1/16 of graphs for two cycles, exposing premature age-one promotion. High-survival rows retain half the graphs for eight cycles, exercising legitimate promotion. Every graph contributes to an exact integer checksum.",
    "Each process is fresh. One unrecorded warmup per matrix row precedes seven recorded samples; age order alternates per sample, and moving/non-moving configurations retain the same sample indexes. The harness rejects checksum drift, byte imbalance, any full collection except the single production automatic-compaction follow-on in a shared moving row, missing minor/movement/rendezvous activity, movement failures, any conservative-parent timeout, more than two bounded moving retries, samples below 50 ms, elapsed RSD above 15%, and stable age-three regressions above 20%.",
    rawLine,
    "",
    "## Reproduce",
    "",
    "```sh",
    "zig build gc-generation-benchmark -Doptimize=ReleaseFast",
    "zig build gc-generation-benchmark -Dgc-generation-benchmark-quick=true",
    "```",
    "",
  );
  return lines.join("\n");
}
export function readmeScorecard(
  rows: Row[],
  reportPath: string,
  rawPath: string,
): string {
  const single = groups(rows).filter(
      (group) => group[0][0] === "forced" && Number(group[0][3]) === 1,
    ),
    parents = movingGroups(rows).filter((group) => Number(group[0][3]) === 3),
    shared = parents
      .filter((group) => group[0][0] === "shared")
      .map((group) => group[2]),
    ageThroughput = single.map(
      (group) =>
        median(group[1].map((row: Row) => row.elapsed_ns)) /
        median(group[2].map((row: Row) => row.elapsed_ns)),
    ),
    movingThroughput = parents.map(
      (group) =>
        median(group[1].map((row: Row) => row.elapsed_ns)) /
        median(group[2].map((row: Row) => row.elapsed_ns)),
    ),
    sharedPause = Math.max.apply(
      null,
      shared
        .reduce((all: Row[], rows: Row[]) => all.concat(rows), [])
        .map((row: Row) => row.pause_max_ns),
    ),
    copied = sum(
      parents.map((group) => sum(group[2].map((row: Row) => row.moved_bytes))),
    ),
    timeouts = sum(rows.map((row) => row.cooperative_timeouts));
  return `${README_START}\n- **Generational GC:** moving age-three is ${Math.min.apply(null, movingThroughput).toFixed(2)}–${Math.max.apply(null, movingThroughput).toFixed(2)}x its exact non-moving parents and ${Math.min.apply(null, ageThroughput).toFixed(2)}–${Math.max.apply(null, ageThroughput).toFixed(2)}x moving age-one across accepted single-mutator rows; ${(copied / MIB).toFixed(2)} MiB copied in the recorded moving age-three rows; shared no-GIL minor pause max ${(sharedPause / 1e6).toFixed(2)} ms with ${timeouts} timeouts ([report](${reportPath}) · [samples](${rawPath})).\n${README_END}`;
}
export function replaceReadmeBlock(source: string, generated: string): string {
  requireValue(
    source.split(README_START).length === 2 &&
      source.split(README_END).length === 2,
    "README must contain exactly one GC generation marker pair",
  );
  return (
    source.split(README_START)[0] + generated + source.split(README_END)[1]
  );
}
function writeRaw(rows: Row[], path: string): void {
  writeText(
    path,
    FIELDS.join("\t") +
      "\n" +
      rows
        .map((row) => FIELDS.map((field) => String(row[field])).join("\t"))
        .join("\n") +
      "\n",
  );
}
function fixture(updates: Row = {}): Row {
  const row: Row = {
    trigger: "automatic",
    scenario: "mixed",
    tenuring_age: 3,
    moving: 0,
    trigger_bytes: 4 * MIB,
    sample: 0,
    rounds: 8,
    batch: 24576,
    elapsed_ns: 100000000,
    checksum: 8 * 24576 * 24576,
    minor_collections: 4,
    full_collections: 0,
    young_input_bytes: 1000,
    survived_bytes: 250,
    reclaimed_bytes: 750,
    promoted_bytes: 100,
    moving_minor_collections: 0,
    moved_cells: 0,
    moved_bytes: 0,
    move_failures: 0,
    live_bytes: 500,
    young_bytes: 50,
    next_threshold_bytes: 4 * MIB,
    backing_chunks: 10,
    backing_capacity_bytes: 10 * MIB,
    pause_total_ns: 1000000,
    pause_max_ns: 400000,
    cooperative_attempts: 0,
    cooperative_collections: 0,
    cooperative_parks: 0,
    cooperative_timeouts: 0,
  };
  Object.keys(updates).forEach((key) => (row[key] = updates[key]));
  return row;
}
function expectFailure(action: () => void, pattern: string): void {
  let message = "";
  try {
    action();
  } catch (error) {
    message = String(error);
  }
  requireValue(
    message.includes(pattern),
    `expected failure containing ${pattern}, got ${message}`,
  );
}
export function selfTest(): void {
  const expected = fixture(),
    parsed = parseRow(
      FIELDS.map((field) => String(expected[field])).join("\t"),
    );
  requireValue(equal(parsed, expected), "row parse round trip failed");
  expectFailure(
    () => validateRow(fixture({ reclaimed_bytes: 749 }), false),
    "conservation",
  );
  const shared = fixture({
    trigger: "shared",
    checksum: 3 * 8 * 24576 * 24576,
    cooperative_attempts: 3,
    cooperative_collections: 3,
    cooperative_parks: 3,
  });
  validateRow(shared, false);
  expectFailure(
    () =>
      validateRow(
        fixture(Object.assign({}, shared, { cooperative_timeouts: 1 })),
        false,
      ),
    "rendezvous",
  );
  const moving = fixture(
    Object.assign({}, shared, {
      moving: 1,
      moving_minor_collections: 1,
      moved_cells: 8,
      moved_bytes: 1024,
      full_collections: 1,
      cooperative_timeouts: 2,
    }),
  );
  validateRow(moving, false);
  expectFailure(
    () =>
      validateRow(
        fixture(Object.assign({}, moving, { cooperative_timeouts: 3 })),
        false,
      ),
    "rendezvous",
  );
  expectFailure(
    () => validateRow(fixture({ cooperative_attempts: 1 }), false),
    "unexpected cooperative",
  );
  expectFailure(
    () =>
      validateRow(
        fixture({ moving: 1, moving_minor_collections: 3, moved_cells: 12 }),
        false,
      ),
    "moving-minor",
  );
  expectFailure(
    () => validateRow(fixture({ moved_bytes: 4096 }), false),
    "unexpected moving-minor",
  );
  const initial = `before\n${README_START}\nold\n${README_END}\nafter\n`,
    generated = `${README_START}\nnew\n${README_END}`,
    once = replaceReadmeBlock(initial, generated);
  requireValue(
    once === replaceReadmeBlock(once, generated),
    "README replacement is not idempotent",
  );
  expectFailure(() => replaceReadmeBlock("missing", generated), "exactly one");
  const rows: Row[] = [];
  [100000000, 101000000, 99000000].forEach((elapsed, sample) => {
    for (const movement of [0, 1]) {
      const copied = movement
        ? { moving_minor_collections: 3, moved_cells: 12, moved_bytes: 4096 }
        : {};
      rows.push(
        fixture(
          Object.assign(
            { tenuring_age: 1, sample, elapsed_ns: elapsed, moving: movement },
            copied,
          ),
        ),
      );
      rows.push(
        fixture(
          Object.assign(
            {
              tenuring_age: 3,
              sample,
              elapsed_ns: elapsed * 2,
              moving: movement,
            },
            copied,
          ),
        ),
      );
    }
  });
  expectFailure(() => validateMatrix(rows, 3, false), "regression");
  console.log("gc-generation-benchmark self-test: ok");
}
function main(): void {
  const args = process.argv.slice(2);
  if (args.length === 1 && args[0] === "--self-test") return selfTest();
  requireValue(args.length > 0, "runner is required");
  const runner = args[0],
    options: any = { samples: 7, warmups: 1, quick: false };
  for (let index = 1; index < args.length; index += 1) {
    const name = args[index];
    if (name === "--quick") options.quick = true;
    else {
      const value = args[++index];
      if (name === "--samples") options.samples = Number(value);
      else if (name === "--warmups") options.warmups = Number(value);
      else if (name === "--raw-out") options.raw = value;
      else if (name === "--markdown-out") options.markdown = value;
      else if (name === "--readme") options.readme = value;
      else throw new Error(`unknown argument: ${name}`);
    }
  }
  if (options.quick) Object.assign(options, { samples: 1, warmups: 0 });
  requireValue(
    options.samples > 0 && options.warmups >= 0,
    "samples must be positive and warmups non-negative",
  );
  requireValue(
    !options.readme || (options.raw && options.markdown),
    "--readme requires --raw-out and --markdown-out",
  );
  const info = metadata();
  requireValue(
    !(options.raw || options.markdown || options.readme) ||
      !Object.values(info).some((value) =>
        value.endsWith(" (tracked worktree dirty)"),
      ),
    "refusing to publish benchmark evidence from a dirty tracked worktree",
  );
  const rows = collect(runner, options.samples, options.warmups, options.quick);
  validateMatrix(rows, options.samples, options.quick);
  if (options.raw) writeRaw(rows, options.raw);
  const report = render(rows, info, options.raw || null);
  if (options.markdown) writeText(options.markdown, report);
  if (options.readme)
    writeText(
      options.readme,
      replaceReadmeBlock(
        readText(options.readme),
        readmeScorecard(rows, options.markdown, options.raw),
      ),
    );
  console.log(report);
}
if (process.argv[1] === __filename) main();
