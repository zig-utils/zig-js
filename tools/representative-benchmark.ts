/** Collect the versioned representative zig-js / JavaScriptCore matrix. */
import {
  Row,
  ensurePublishable,
  metadata,
  rowKey,
  runCase,
  writeRaw,
} from "./benchmark-comparison";
import {
  DEFAULT_MANIFEST,
  loadManifest,
  validate as validateManifest,
} from "./representative-matrix";
import {
  artifact as tierArtifact,
  collect as collectTierAttribution,
  render as renderTierAttribution,
  validate as validateTierAttribution,
} from "./representative-tier-attribution";
import { run, writeText } from "./lib/home";
// Inventory-visible module edges: tools/benchmark-comparison.ts and tools/representative-matrix.ts.
declare const __filename: string;
function requireValue(condition: boolean, message: string): void {
  if (!condition) throw new Error(message);
}
export function workloadEntries(manifest: any): any[] {
  const result: any[] = [];
  for (const family of manifest.implemented_families) {
    result.push([family, "base", family.base]);
    result.push([family, "variant", family.variant]);
  }
  return result;
}
export const jobsFor = (family: any, quick: boolean): number =>
  family.jobs[quick ? "quick" : "full"];
const isCapabilityFamily = (family: any): boolean =>
  Boolean(family.availability);
const isModuleCapability = (family: any): boolean =>
  family.availability && family.availability.kind === "zig_js_module_capability";
export function collect(
  zigJs: string,
  jsc: string,
  manifest: any,
  samples: number,
  lanes: number[],
  quick: boolean,
): Row[] {
  const rows: Row[] = [],
    allLanes = [1, ...lanes];
  let pairIndex = 0;
  const runPair = (arguments_: string[]) => {
    const pair = pairIndex++ % 2 ? [jsc, zigJs] : [zigJs, jsc];
    pair.forEach((binary) => rows.push(...runCase(binary, arguments_)));
  };
  for (const family of manifest.implemented_families) {
    const jobs = jobsFor(family, quick);
    if (isCapabilityFamily(family)) {
      const availability = family.availability;
      if (isModuleCapability(family)) {
        const gate = availability.JavaScriptCore,
          probe = run([jsc, "single", availability.probe_workload, "1", "1"]);
        requireValue(
          probe.exitCode !== 0 && probe.stderr.indexOf(gate.stderr_contains) >= 0,
          `JavaScriptCore module gate changed: exit=${probe.exitCode} stderr=${JSON.stringify(probe.stderr)}`,
        );
        for (const workload of [family.base, family.variant])
          for (const lane of allLanes)
            rows.push(...runCase(zigJs, ["module_cold", workload, String(jobs), String(samples), String(lane)]));
        continue;
      }
      for (const [engine, binary] of [["zig-js", zigJs], ["JavaScriptCore", jsc]]) {
        const probe = runCase(binary, ["single", availability.probe_workload, "1", "1"]);
        requireValue(
          probe.length === 1 && probe[0].checksum === availability.checksums[engine],
          `${engine} availability profile changed for ${family.family}`,
        );
      }
      for (const workload of [family.base, family.variant])
        rows.push(...runCase(zigJs, ["single", workload, String(jobs), String(samples)]));
      for (const lane of allLanes)
        rows.push(...runCase(zigJs, ["shared", family.base, String(jobs), String(samples), String(lane)]));
      continue;
    }
    for (const workload of [family.base, family.variant])
      runPair(["single", workload, String(jobs), String(samples)]);
    for (const lane of allLanes) {
      for (const mode of ["independent_steady", "independent_cold"])
        runPair([
          mode,
          family.base,
          String(jobs),
          String(samples),
          String(lane),
        ]);
      if (family.shared !== false)
        rows.push(
          ...runCase(zigJs, [
            "shared",
            family.base,
            String(jobs),
            String(samples),
            String(lane),
          ]),
        );
    }
  }
  for (const panel of manifest.additional_panels || []) {
    const jobs = jobsFor(panel, quick);
    if (panel.kind === "cross_engine_oracle") {
      runPair(["single", panel.workload, String(jobs), String(samples)]);
      for (const lane of allLanes)
        for (const mode of ["independent_steady", "independent_cold"])
          runPair([
            mode,
            panel.workload,
            String(jobs),
            String(samples),
            String(lane),
          ]);
    } else {
      const gate = panel.feature_gate.JavaScriptCore,
        probe = run([jsc, "single", panel.workload, "1", "1"]);
      requireValue(
        probe.exitCode !== 0 && probe.stderr.indexOf(gate.stderr_contains) >= 0,
        `JavaScriptCore feature gate changed for ${panel.workload}: exit=${probe.exitCode} stderr=${JSON.stringify(probe.stderr)}`,
      );
      rows.push(
        ...runCase(zigJs, ["single", panel.workload, String(jobs), String(samples)]),
      );
      for (const lane of lanes)
        rows.push(
          ...runCase(zigJs, [
            "shared",
            panel.workload,
            String(jobs),
            String(samples),
            String(lane),
          ]),
        );
    }
  }
  return rows;
}
export function expectedChecksum(
  manifest: any,
  workload: string,
  jobs: number,
  lanes: number,
): number {
  const laneIndex = manifest.lanes.indexOf(lanes);
  for (const [family, role, identifier] of workloadEntries(manifest))
    if (identifier === workload) {
      const scale =
        jobs === family.jobs.full
          ? "full"
          : jobs === family.jobs.quick
            ? "quick"
            : "";
      requireValue(Boolean(scale), `unsupported jobs for ${workload}: ${jobs}`);
      return family.checksums[role][scale][laneIndex];
    }
  for (const panel of manifest.additional_panels || [])
    if (panel.workload === workload) {
      const scale =
        jobs === panel.jobs.full
          ? "full"
          : jobs === panel.jobs.quick
            ? "quick"
            : "";
      requireValue(Boolean(scale), `unsupported jobs for ${workload}: ${jobs}`);
      return panel.checksums[scale][laneIndex];
    }
  throw new Error(`unknown workload: ${workload}`);
}
function grouped(rows: Row[]): Record<string, Row[]> {
  const result: Record<string, Row[]> = {};
  rows.forEach((row) => (result[rowKey(row)] ||= []).push(row));
  return result;
}
const median = (values: number[]): number => {
  const sorted = values.slice().sort((a, b) => a - b),
    middle = Math.floor(sorted.length / 2);
  return sorted.length % 2
    ? sorted[middle]
    : (sorted[middle - 1] + sorted[middle]) / 2;
};
export function validate(
  rows: Row[],
  manifest: any,
  samples: number,
  lanes: number[],
  quick: boolean,
): void {
  const groups = grouped(rows),
    allLanes = [1, ...lanes],
    expected = new Set<string>();
  for (const family of manifest.implemented_families) {
    const jobs = jobsFor(family, quick);
    if (isCapabilityFamily(family)) {
      if (isModuleCapability(family)) {
        for (const workload of [family.base, family.variant])
          for (const lane of allLanes)
            expected.add(JSON.stringify(["zig-js", "module_cold", workload, lane, jobs]));
        continue;
      }
      for (const workload of [family.base, family.variant])
        expected.add(JSON.stringify(["zig-js", "single", workload, 1, jobs]));
      for (const lane of allLanes)
        expected.add(JSON.stringify(["zig-js", "shared", family.base, lane, jobs]));
      continue;
    }
    for (const workload of [family.base, family.variant])
      for (const engine of ["zig-js", "JavaScriptCore"])
        expected.add(JSON.stringify([engine, "single", workload, 1, jobs]));
    for (const lane of allLanes) {
      if (family.shared !== false)
        expected.add(
          JSON.stringify(["zig-js", "shared", family.base, lane, jobs]),
        );
      for (const engine of ["zig-js", "JavaScriptCore"])
        for (const mode of ["independent_steady", "independent_cold"])
          expected.add(JSON.stringify([engine, mode, family.base, lane, jobs]));
    }
  }
  for (const panel of manifest.additional_panels || []) {
    const jobs = jobsFor(panel, quick);
    if (panel.kind === "cross_engine_oracle") {
      for (const engine of panel.engines)
        expected.add(JSON.stringify([engine, "single", panel.workload, 1, jobs]));
      for (const lane of allLanes)
        for (const engine of panel.engines)
          for (const mode of ["independent_steady", "independent_cold"])
            expected.add(JSON.stringify([engine, mode, panel.workload, lane, jobs]));
    } else {
      expected.add(JSON.stringify(["zig-js", "single", panel.workload, 1, jobs]));
      for (const lane of lanes)
        expected.add(JSON.stringify(["zig-js", "shared", panel.workload, lane, jobs]));
    }
  }
  const actual = new Set(Object.keys(groups));
  requireValue(
    actual.size === expected.size &&
      [...expected].every((key) => actual.has(key)),
    `representative matrix mismatch; missing=${JSON.stringify([...expected].filter((key) => !actual.has(key)))}, unexpected=${JSON.stringify([...actual].filter((key) => !expected.has(key)))}`,
  );
  for (const key of Object.keys(groups)) {
    const group = groups[key],
      identity = group[0];
    requireValue(
      group.length === samples,
      `${key} has ${group.length} samples, expected ${samples}`,
    );
    requireValue(
      JSON.stringify(group.map((row) => row.sample).sort((a, b) => a - b)) ===
        JSON.stringify(Array.from({ length: samples }, (_, index) => index)),
      `${key} has invalid sample indexes`,
    );
    const frozen = expectedChecksum(
        manifest,
        identity.workload,
        identity.jobs,
        identity.lanes,
      ),
      values = [...new Set(group.map((row) => row.checksum))];
    requireValue(
      values.length === 1 && values[0] === frozen,
      `${key} checksum ${JSON.stringify(values)} does not match frozen ${frozen}`,
    );
    requireValue(
      quick ||
        median(group.map((row) => row.elapsed_ns)) >=
          manifest.protocol.minimum_full_median_ns,
      `${key} median is shorter than the ${manifest.protocol.minimum_full_median_ns / 1e6} ms full-run timing floor`,
    );
  }
  for (const row of rows) {
    const peers = new Set(
      rows
        .filter(
          (candidate) =>
            candidate.mode === row.mode &&
            candidate.workload === row.workload &&
            candidate.lanes === row.lanes &&
            candidate.jobs === row.jobs,
        )
        .map((candidate) => candidate.checksum),
    );
    requireValue(
      peers.size === 1,
      `cross-engine checksum mismatch for ${rowKey(row)}`,
    );
  }
}
const medianMs = (groups: Record<string, Row[]>, key: any[]): number =>
  median(groups[JSON.stringify(key)].map((row) => row.elapsed_ns)) / 1e6;
const rsd = (groups: Record<string, Row[]>, key: any[]): number => {
  const values = groups[JSON.stringify(key)].map((row) => row.elapsed_ns);
  if (values.length <= 1) return 0;
  const mean = values.reduce((sum, value) => sum + value, 0) / values.length;
  return (
    (Math.sqrt(
      values.reduce((sum, value) => sum + (value - mean) ** 2, 0) /
        (values.length - 1),
    ) /
      mean) *
    100
  );
};
export function render(
  rows: Row[],
  manifest: any,
  lanes: number[],
  rawPath: string | null,
  info: Record<string, string>,
): string {
  const groups = grouped(rows),
    allLanes = [1, ...lanes],
    lines = [
      `# Representative zig-js / JavaScriptCore matrix — ${info.Date}`,
      "",
      "> This is a dated, workload-scoped measurement. It is not a universal engine score.",
      `> Contract: \`${manifest.matrix_id}\`; deferred families remain outside this report.`,
      "",
      "## Environment",
      "",
      "| item | value |",
      "| --- | --- |",
    ];
  Object.keys(info).forEach((key) => lines.push(`| ${key} | ${info[key]} |`));
  lines.push(
    "",
    "## Direct warmed contexts and anti-specialization variants",
    "",
    "| family | workload | jobs | zig-js median (ms) | zig-js RSD | JSC median (ms) | JSC RSD | zig-js / JSC throughput |",
    "| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: |",
  );
  for (const [family, role, workload] of workloadEntries(manifest)) {
    if (isCapabilityFamily(family)) continue;
    const jobs = rows.find((row) => row.workload === workload)!.jobs,
      zigKey = ["zig-js", "single", workload, 1, jobs],
      jscKey = ["JavaScriptCore", "single", workload, 1, jobs],
      zig = medianMs(groups, zigKey),
      jsc = medianMs(groups, jscKey);
    lines.push(
      `| \`${family.family}\` | \`${role}\` | ${jobs} | ${zig.toFixed(3)} | ${rsd(groups, zigKey).toFixed(2)}% | ${jsc.toFixed(3)} | ${rsd(groups, jscKey).toFixed(2)}% | ${(jsc / zig).toFixed(2)}x |`,
    );
  }
  for (const [mode, heading] of [
    ["independent_steady", "Independent-context steady state"],
    ["independent_cold", "Independent-context cold lifecycle"],
  ]) {
    lines.push(
      "",
      `## ${heading}`,
      "",
      "| family | lanes | jobs/lane | zig-js median (ms) | JSC median (ms) | zig-js / JSC throughput |",
      "| --- | ---: | ---: | ---: | ---: | ---: |",
    );
    for (const family of manifest.implemented_families) {
      if (isCapabilityFamily(family)) continue;
      const workload = family.base,
        jobs = rows.find((row) => row.workload === workload)!.jobs;
      for (const lane of allLanes) {
        const zig = medianMs(groups, ["zig-js", mode, workload, lane, jobs]),
          jsc = medianMs(groups, [
            "JavaScriptCore",
            mode,
            workload,
            lane,
            jobs,
          ]);
        lines.push(
          `| \`${family.family}\` | ${lane} | ${jobs} | ${zig.toFixed(3)} | ${jsc.toFixed(3)} | ${(jsc / zig).toFixed(2)}x |`,
        );
      }
    }
  }
  lines.push(
    "",
    "## zig-js shared-realm capability panel",
    "",
    "JSC's public API has no equivalent shared-realm execution model, so this panel has no cross-engine ratio.",
    "",
    "| family | lanes | jobs/lane | median (ms) | scaling |",
    "| --- | ---: | ---: | ---: | ---: |",
  );
  for (const family of manifest.implemented_families) {
    if (family.shared === false) continue;
    const workload = family.base,
      jobs = rows.find((row) => row.workload === workload)!.jobs,
      one = medianMs(groups, ["zig-js", "shared", workload, 1, jobs]);
    for (const lane of allLanes) {
      const elapsed = medianMs(groups, [
        "zig-js",
        "shared",
        workload,
        lane,
        jobs,
      ]);
      lines.push(
        `| \`${family.family}\` | ${lane} | ${jobs} | ${elapsed.toFixed(3)} | ${((lane * one) / elapsed).toFixed(2)}x |`,
      );
    }
  }
  const capabilityFamilies = manifest.implemented_families.filter(isCapabilityFamily);
  if (capabilityFamilies.length > 0) {
    lines.push(
      "",
      "## Availability-gated capability families",
      "",
      "These rows are scored only where the required public surface exists. Every run verifies the declared engine profile; no unavailable-engine ratio is constructed.",
      "",
      "| family | workload | mode | lanes | jobs/lane | zig-js median (ms) | JSC |",
      "| --- | --- | --- | ---: | ---: | ---: | --- |",
    );
    for (const family of capabilityFamilies) {
      const jobs = rows.find((row) => row.workload === family.base)!.jobs;
      if (isModuleCapability(family)) {
        for (const [role, workload] of [["base", family.base], ["variant", family.variant]])
          for (const lane of allLanes) {
            const elapsed = medianMs(groups, ["zig-js", "module_cold", workload, lane, jobs]);
            lines.push(`| \`${family.family}\` | \`${role}\` | \`module_cold\` | ${lane} | ${jobs} | ${elapsed.toFixed(3)} | N/A |`);
          }
      } else {
        for (const [role, workload] of [["base", family.base], ["variant", family.variant]]) {
          const elapsed = medianMs(groups, ["zig-js", "single", workload, 1, jobs]);
          lines.push(`| \`${family.family}\` | \`${role}\` | \`single\` | 1 | ${jobs} | ${elapsed.toFixed(3)} | N/A |`);
        }
      }
      lines.push(`| \`${family.family}\` | feature gate | — | — | — | supported | ${family.availability.JavaScriptCore.result} |`);
    }
  }
  if ((manifest.additional_panels || []).length > 0) {
    lines.push(
      "",
      "## Additional frozen subpanels",
      "",
      "These rows use separately declared programming-model boundaries. A capability row never constructs a ratio against an unavailable JavaScriptCore surface.",
      "",
      "| panel | mode | lanes | jobs/lane | zig-js median (ms) | JSC median (ms) | zig-js / JSC throughput |",
      "| --- | --- | ---: | ---: | ---: | ---: | ---: |",
    );
    for (const panel of manifest.additional_panels || []) {
      const jobs = rows.find((row) => row.workload === panel.workload)!.jobs;
      if (panel.kind === "cross_engine_oracle") {
        const variants: any[][] = [["single", 1]];
        for (const mode of ["independent_steady", "independent_cold"])
          for (const lane of allLanes) variants.push([mode, lane]);
        for (const [mode, lane] of variants) {
          const zig = medianMs(groups, ["zig-js", mode, panel.workload, lane, jobs]),
            jsc = medianMs(groups, ["JavaScriptCore", mode, panel.workload, lane, jobs]);
          lines.push(
            `| \`${panel.id}\` | \`${mode}\` | ${lane} | ${jobs} | ${zig.toFixed(3)} | ${jsc.toFixed(3)} | ${(jsc / zig).toFixed(2)}x |`,
          );
        }
      } else {
        const variants: any[][] = [["single", 1], ...lanes.map((lane) => ["shared", lane])];
        for (const [mode, lane] of variants) {
          const zig = medianMs(groups, ["zig-js", mode, panel.workload, lane, jobs]);
          lines.push(
            `| \`${panel.id}\` | \`${mode}\` | ${lane} | ${jobs} | ${zig.toFixed(3)} | N/A | N/A |`,
          );
        }
        const gate = panel.feature_gate.JavaScriptCore;
        lines.push(
          `| \`${panel.id}\` | feature gate | — | — | supported | ${gate.result} | no public equivalent |`,
        );
      }
    }
  }
  lines.push(
    "",
    "## Coverage boundary",
    "",
    `Implemented families in this version: ${manifest.implemented_families.length}.`,
  );
  if (manifest.deferred_families.length === 0) {
    lines.push(
      "All pre-registered workload families are implemented in this version.",
    );
  } else {
    lines.push(
      "The following pre-registered families are explicit deferrals, not passes or exclusions:",
      "",
    );
    manifest.deferred_families.forEach((entry: any) =>
      lines.push(`- \`${entry.family}\` — ${entry.reason}`),
    );
  }
  lines.push(
    "",
    "The original ten-kernel compatibility panel remains separately collected and hash-pinned by the manifest.",
    "Every recorded checksum must equal the checked-in jobs/lane value; cross-engine equality alone is insufficient.",
    "Full rows retain seven samples and a 50 ms median floor. Quick runs are validation only and are not publication evidence.",
  );
  if (rawPath) {
    const name = rawPath.split("/").pop();
    lines.push("", `Raw samples: [\`${name}\`](${name})`);
  }
  return lines.join("\n") + "\n";
}
function syntheticRows(
  manifest: any,
  samples = 1,
  quick = true,
  elapsedNs = 60000000,
): Row[] {
  const rows: Row[] = [],
    allLanes = [1, 2, 4, 8],
    scale = quick ? "quick" : "full";
  for (const family of manifest.implemented_families) {
    const jobs = family.jobs[scale],
      add = (
        engine: string,
        mode: string,
        workload: string,
        role: string,
        lanes: number,
      ) => {
        const checksum =
          family.checksums[role][scale][manifest.lanes.indexOf(lanes)];
        for (let sample = 0; sample < samples; sample += 1)
          rows.push({
            engine,
            mode,
            workload,
            lanes,
            jobs,
            sample,
            elapsed_ns: elapsedNs + sample,
            checksum,
          });
      };
    if (isModuleCapability(family)) {
      for (const role of ["base", "variant"])
        for (const lane of allLanes)
          add("zig-js", "module_cold", family[role], role, lane);
      continue;
    }
    for (const role of ["base", "variant"]) {
      add("zig-js", "single", family[role], role, 1);
      if (!isCapabilityFamily(family)) add("JavaScriptCore", "single", family[role], role, 1);
    }
    for (const lane of allLanes) {
      if (family.shared !== false)
        add("zig-js", "shared", family.base, "base", lane);
      if (isCapabilityFamily(family)) continue;
      for (const engine of ["zig-js", "JavaScriptCore"]) {
        add(engine, "independent_steady", family.base, "base", lane);
        add(engine, "independent_cold", family.base, "base", lane);
      }
    }
  }
  for (const panel of manifest.additional_panels || []) {
    const jobs = panel.jobs[scale],
      add = (engine: string, mode: string, lanes: number) => {
        const checksum = panel.checksums[scale][manifest.lanes.indexOf(lanes)];
        for (let sample = 0; sample < samples; sample += 1)
          rows.push({
            engine,
            mode,
            workload: panel.workload,
            lanes,
            jobs,
            sample,
            elapsed_ns: elapsedNs + sample,
            checksum,
          });
      };
    if (panel.kind === "cross_engine_oracle") {
      for (const engine of panel.engines) add(engine, "single", 1);
      for (const lane of allLanes)
        for (const engine of panel.engines)
          for (const mode of ["independent_steady", "independent_cold"])
            add(engine, mode, lane);
    } else {
      add("zig-js", "single", 1);
      for (const lane of [2, 4, 8]) add("zig-js", "shared", lane);
    }
  }
  return rows;
}
function expectFailure(action: () => void, pattern: string): void {
  try {
    action();
  } catch (error) {
    requireValue(
      String(error).includes(pattern),
      `expected ${pattern}, got ${String(error)}`,
    );
    return;
  }
  throw new Error(`expected failure containing ${pattern}`);
}
export function selfTest(): void {
  const manifest = loadManifest(DEFAULT_MANIFEST);
  validate(syntheticRows(manifest), manifest, 1, [2, 4, 8], true);
  const missing = syntheticRows(manifest);
  missing.pop();
  expectFailure(
    () => validate(missing, manifest, 1, [2, 4, 8], true),
    "matrix mismatch",
  );
  const checksum = syntheticRows(manifest);
  checksum[0] = { ...checksum[0], checksum: checksum[0].checksum + 1 };
  expectFailure(
    () => validate(checksum, manifest, 1, [2, 4, 8], true),
    "does not match frozen",
  );
  expectFailure(
    () =>
      validate(
        syntheticRows(manifest, 1, false, 1000000),
        manifest,
        1,
        [2, 4, 8],
        false,
      ),
    "timing floor",
  );
  console.log(
    "OK representative benchmark self-test: matrix, frozen checksums, and timing floor verified",
  );
}
function main(): void {
  const args = process.argv.slice(2);
  if (args.length === 1 && args[0] === "--self-test") {
    selfTest();
    return;
  }
  requireValue(
    args.length >= 2,
    "usage: representative-benchmark.ts ZIG_JS_RUNNER JSC_RUNNER [options]",
  );
  const options: any = {
    manifest: DEFAULT_MANIFEST,
    lanes: "2,4,8",
    quick: false,
  };
  for (let index = 2; index < args.length; index += 1) {
    const name = args[index];
    if (name === "--quick") options.quick = true;
    else {
      const value = args[++index];
      if (name === "--manifest") options.manifest = value;
      else if (name === "--samples") options.samples = Number(value);
      else if (name === "--lanes") options.lanes = value;
      else if (name === "--raw-out") options.raw = value;
      else if (name === "--tier-attribution-out") options.tierAttribution = value;
      else if (name === "--markdown-out") options.markdown = value;
      else throw new Error(`unknown argument: ${name}`);
    }
  }
  const manifest = loadManifest(options.manifest);
  validateManifest(manifest);
  const lanes = [
    ...new Set(options.lanes.split(",").filter(Boolean).map(Number)),
  ].sort((a, b) => a - b);
  requireValue(
    lanes.length > 0 &&
      lanes.every((value) => value !== 1 && manifest.lanes.includes(value)),
    "lanes must be a non-empty subset of the manifest lanes above one",
  );
  const samples = options.quick
    ? 1
    : options.samples || manifest.protocol.full_samples;
  requireValue(samples > 0, "samples must be positive");
  requireValue(
    Home.fileExists(args[0]) && Home.fileExists(args[1]),
    "runner does not exist",
  );
  const info = metadata();
  ensurePublishable(info, Boolean(options.raw || options.tierAttribution || options.markdown));
  requireValue(
    (!options.raw && !options.markdown) || Boolean(options.tierAttribution),
    "representative raw/report publication requires --tier-attribution-out",
  );
  const rows = collect(
    args[0],
    args[1],
    manifest,
    samples,
    lanes,
    options.quick,
  );
  validate(rows, manifest, samples, lanes, options.quick);
  const tierSnapshots = collectTierAttribution(args[0], manifest, options.quick),
    tierDeltas = validateTierAttribution(tierSnapshots, manifest, options.quick),
    report = render(rows, manifest, lanes, options.raw || null, info) + "\n" +
      renderTierAttribution(tierDeltas, manifest, "##", options.tierAttribution || null);
  if (options.raw) writeRaw(options.raw, rows);
  if (options.tierAttribution)
    writeText(
      options.tierAttribution,
      JSON.stringify(tierArtifact(tierSnapshots, manifest, options.quick, info, args[0]), null, 2) + "\n",
    );
  if (options.markdown) writeText(options.markdown, report);
  process.stdout.write(report);
}
if (process.argv[1] === __filename) main();
