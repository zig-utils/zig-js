/** Aggregate exact-parent rows into a versioned, non-throughput growth artifact. */
import { checked, fileExists, readText, run, sha256File, sha256Text, writeText } from "./lib/home";
import { DEFAULT_SCHEMA as ATTRIBUTION_SCHEMA, loadSchema as loadAttributionSchema, measured, unavailableMetrics, validateArtifact as validateAttributionArtifact } from "./performance-attribution";
import { summarize as summarizeExactParent, validateSampleQuality } from "./exact-parent-regression";
// Inventory-visible module edges: tools/performance-attribution.ts and tools/exact-parent-regression.ts.

declare const __dirname: string;
declare const __filename: string;
export const ROOT = __dirname === "tools" ? "." : __dirname.slice(0, __dirname.lastIndexOf("/tools"));
export const DEFAULT_SCHEMA = `${ROOT}/docs/.data/algorithmic-growth-schema-v1.json`;
const HEX_40 = /^[0-9a-f]{40}$/, HEX_64 = /^[0-9a-f]{64}$/;

function requireValue(condition: boolean, message: string): void { if (!condition) throw new Error(message); }
const mean = (values: number[]): number => values.reduce((sum, value) => sum + value, 0) / values.length;
const median = (values: number[]): number => { const sorted = values.slice().sort((a, b) => a - b), middle = Math.floor(sorted.length / 2); return sorted.length % 2 ? sorted[middle] : (sorted[middle - 1] + sorted[middle]) / 2; };
export function relativeStddev(values: number[]): number { if (values.length <= 1) return 0; const average = mean(values); requireValue(average > 0, "growth metric mean must be positive"); return Math.sqrt(values.reduce((sum, value) => sum + (value - average) ** 2, 0) / (values.length - 1)) / average; }
const basename = (path: string): string => path.split("/").filter(Boolean).pop() || path;
const exactJson = (value: any): string => JSON.stringify(value);

export function validateSchema(schema: any): any {
  requireValue(schema?.schema_version === 1 && schema.profile_id === "zig-js-algorithmic-growth-v1" && schema.owner_issue === 670, "algorithmic-growth schema identity drift");
  requireValue(schema.input_profile_id === "zig-js-performance-attribution-v1" && schema.input_kind === "exact_parent_ab", "algorithmic-growth input contract drift");
  requireValue(schema.minimum_widths === 3 && schema.minimum_pairs_per_width === 2 && schema.maximum_instruction_rsd === 0.05, "algorithmic-growth stability policy drift");
  requireValue(exactJson(schema.required_scored_metrics) === '["instructions","allocations","allocated_bytes"]', "algorithmic-growth scored metric inventory drift");
  requireValue(exactJson(schema.diagnostic_only_metrics) === '["wall_time_ns","process_cpu_user_ns","process_cpu_system_ns","peak_rss_bytes","retained_rss_bytes","cycles","energy_joules","thermal_state"]', "algorithmic-growth diagnostic metric inventory drift");
  const common = ["parent_revision", "candidate_revision", "candidate_first_parent", "zig_gc_revision", "zig_regex_revision", "zig_version", "os", "hardware", "host_class", "workload_source_sha256", "parent_binary_sha256", "candidate_binary_sha256", "samples", "minimum_process_cpu_occupancy", "mode", "lanes"];
  requireValue(exactJson(schema.required_common_metadata) === exactJson(common), "algorithmic-growth common metadata inventory drift");
  requireValue(typeof schema.claim_boundary === "string" && schema.claim_boundary.startsWith("Only normalized retired instructions") && schema.claim_boundary.includes("cannot support a throughput"), "algorithmic-growth claim boundary drift");
  requireValue(Array.isArray(schema.publication_guards) && schema.publication_guards.length === 8, "algorithmic-growth publication guard inventory drift");
  return schema;
}

export function loadSchema(path = DEFAULT_SCHEMA): any { return validateSchema(JSON.parse(readText(path))); }

type GrowthInput = {
  width: number;
  source_file: string;
  source_file_sha256: string;
  embedded_artifact_sha256: string;
  artifact: any;
};

function measuredValues(artifact: any, variant: string, metric: string, allowZero = false): number[] {
  const samples = artifact.samples.filter((sample: any) => sample.identity.variant === variant);
  requireValue(samples.length === artifact.metadata.samples, `${metric} ${variant} sample count drift at ${artifact.metadata.workload}`);
  return samples.map((sample: any) => {
    const observation = sample.metrics?.[metric];
    requireValue(observation?.status === "measured" && Number.isFinite(observation.value) && (allowZero ? observation.value >= 0 : observation.value > 0), `${metric} must be measured and ${allowZero ? "non-negative" : "positive"} for ${variant} at ${artifact.metadata.workload}`);
    return Number(observation.value);
  });
}

function exactReplay(values: number[], metric: string, variant: string, workload: string): number {
  requireValue(values.every((value) => Number.isSafeInteger(value)), `${metric} replay must use safe integers for ${variant} at ${workload}`);
  requireValue(new Set(values).size === 1, `${metric} replay drift for ${variant} at ${workload}`);
  return values[0];
}

function variantSummary(artifact: any, variant: string, maximumRsd: number): any {
  const jobs = artifact.metadata.jobs, workload = artifact.metadata.workload;
  const instructions = measuredValues(artifact, variant, "instructions").map((value) => value / jobs);
  const instructionRsd = relativeStddev(instructions);
  requireValue(instructionRsd <= maximumRsd, `normalized instruction RSD ${(instructionRsd * 100).toFixed(2)}% exceeds ${(maximumRsd * 100).toFixed(0)}% for ${variant} at ${workload}`);
  const allocations = exactReplay(measuredValues(artifact, variant, "allocations", true), "allocation", variant, workload);
  const allocatedBytes = exactReplay(measuredValues(artifact, variant, "allocated_bytes", true), "allocated-byte", variant, workload);
  return {
    instructions_per_job_median: median(instructions),
    instructions_per_job_rsd: instructionRsd,
    allocations_total: allocations,
    allocations_per_job: allocations / jobs,
    allocated_bytes_total: allocatedBytes,
    allocated_bytes_per_job: allocatedBytes / jobs,
  };
}

function validateInput(input: GrowthInput, familyPrefix: string, schema: any, attributionSchema: any): any {
  requireValue(Number.isSafeInteger(input.width) && input.width > 0, "algorithmic-growth width must be a positive safe integer");
  requireValue(typeof input.source_file === "string" && input.source_file === basename(input.source_file) && input.source_file.length > 0 && HEX_64.test(input.source_file_sha256), `algorithmic-growth source artifact identity is invalid at width ${input.width}`);
  requireValue(HEX_64.test(input.embedded_artifact_sha256) && input.embedded_artifact_sha256 === sha256Text(exactJson(input.artifact)), `embedded exact-parent artifact hash drift at width ${input.width}`);
  validateAttributionArtifact(input.artifact, attributionSchema);
  validateSampleQuality(input.artifact.samples);
  requireValue(input.artifact.kind === schema.input_kind && input.artifact.profile_id === schema.input_profile_id, `algorithmic-growth input profile drift at width ${input.width}`);
  const metadata = input.artifact.metadata;
  const rebuiltExactSummary = summarizeExactParent(input.artifact.samples, attributionSchema, metadata.host_class, metadata.material_change_categories);
  requireValue(exactJson(input.artifact.summary) === exactJson(rebuiltExactSummary), `ordinary exact-parent summary drift at width ${input.width}`);
  requireValue(metadata.workload === `${familyPrefix}${input.width}`, `workload ${metadata.workload} does not match ${familyPrefix}<width>`);
  requireValue(Number.isSafeInteger(metadata.jobs) && metadata.jobs > 0 && Number.isSafeInteger(metadata.expected_checksum) && metadata.expected_checksum >= 0, `logical work/checksum identity is invalid at width ${input.width}`);
  requireValue(metadata.samples >= schema.minimum_pairs_per_width && metadata.material_change_categories?.includes("cpu_work"), `sample or material-change contract drift at width ${input.width}`);
  const parent = variantSummary(input.artifact, "parent", schema.maximum_instruction_rsd), candidate = variantSummary(input.artifact, "candidate", schema.maximum_instruction_rsd);
  return {
    width: input.width,
    workload: metadata.workload,
    jobs: metadata.jobs,
    checksum: metadata.expected_checksum,
    full_efficiency_status: input.artifact.summary.status,
    parent,
    candidate,
    candidate_over_parent_instructions: candidate.instructions_per_job_median / parent.instructions_per_job_median,
  };
}

function exponent(firstWidth: number, lastWidth: number, firstValue: number, lastValue: number): number {
  requireValue(lastWidth > firstWidth && firstValue > 0 && lastValue > 0, "algorithmic-growth exponent inputs are invalid");
  return Math.log(lastValue / firstValue) / Math.log(lastWidth / firstWidth);
}

function derivedMetadata(inputs: GrowthInput[], familyPrefix: string, schema: any): any {
  const first = inputs[0].artifact.metadata;
  for (const field of schema.required_common_metadata) {
    for (const input of inputs.slice(1)) requireValue(exactJson(input.artifact.metadata[field]) === exactJson(first[field]), `exact-parent common metadata drift for ${field} at width ${input.width}`);
  }
  requireValue(HEX_40.test(first.parent_revision) && HEX_40.test(first.candidate_revision) && first.candidate_first_parent === first.parent_revision, "algorithmic-growth exact-parent revision identity is invalid");
  for (const field of ["zig_version", "os", "hardware"]) requireValue(typeof first[field] === "string" && first[field].length > 0, `algorithmic-growth ${field} identity is invalid`);
  for (const input of inputs) {
    const metadata = input.artifact.metadata;
    for (const field of ["power", "timed_boundary"]) requireValue(typeof metadata[field] === "string" && metadata[field].length > 0, `algorithmic-growth ${field} identity is invalid at width ${input.width}`);
    requireValue(metadata.minimum_process_cpu_occupancy === input.artifact.samples[0].quality.minimum_process_cpu_occupancy, `algorithmic-growth process-quality policy drift at width ${input.width}`);
  }
  return {
    parent_revision: first.parent_revision,
    candidate_revision: first.candidate_revision,
    candidate_first_parent: first.candidate_first_parent,
    zig_gc_revision: first.zig_gc_revision,
    zig_regex_revision: first.zig_regex_revision,
    zig_version: first.zig_version,
    os: first.os,
    hardware: first.hardware,
    host_class: first.host_class,
    workload_source_sha256: first.workload_source_sha256,
    parent_binary_sha256: first.parent_binary_sha256,
    candidate_binary_sha256: first.candidate_binary_sha256,
    samples_per_width: first.samples,
    minimum_process_cpu_occupancy: first.minimum_process_cpu_occupancy,
    mode: first.mode,
    lanes: first.lanes,
    family_prefix: familyPrefix,
    widths: inputs.map((input) => input.width),
    power_states: [...new Set(inputs.map((input) => input.artifact.metadata.power))].sort(),
    timed_boundaries: [...new Set(inputs.map((input) => input.artifact.metadata.timed_boundary))].sort(),
    claim_boundary: schema.claim_boundary,
    source_artifacts: inputs.map((input) => ({ width: input.width, file: input.source_file, file_sha256: input.source_file_sha256, embedded_artifact_sha256: input.embedded_artifact_sha256 })),
  };
}

function derivedSummary(inputs: GrowthInput[], familyPrefix: string, schema: any, attributionSchema: any): any {
  const rows = inputs.map((input) => validateInput(input, familyPrefix, schema, attributionSchema));
  const adjacent_growth = rows.slice(1).map((row, index) => {
    const previous = rows[index], widthRatio = row.width / previous.width;
    return {
      from_width: previous.width,
      to_width: row.width,
      width_ratio: widthRatio,
      parent_instruction_ratio: row.parent.instructions_per_job_median / previous.parent.instructions_per_job_median,
      candidate_instruction_ratio: row.candidate.instructions_per_job_median / previous.candidate.instructions_per_job_median,
      parent_growth_exponent: exponent(previous.width, row.width, previous.parent.instructions_per_job_median, row.parent.instructions_per_job_median),
      candidate_growth_exponent: exponent(previous.width, row.width, previous.candidate.instructions_per_job_median, row.candidate.instructions_per_job_median),
    };
  });
  const first = rows[0], last = rows[rows.length - 1];
  return {
    status: "accepted_algorithmic_growth",
    scored_metric: "normalized retired instructions per logical job",
    diagnostic_metrics_are_not_scored: true,
    rows,
    adjacent_growth,
    first_to_last: {
      from_width: first.width,
      to_width: last.width,
      width_ratio: last.width / first.width,
      parent_instruction_ratio: last.parent.instructions_per_job_median / first.parent.instructions_per_job_median,
      candidate_instruction_ratio: last.candidate.instructions_per_job_median / first.candidate.instructions_per_job_median,
      parent_growth_exponent: exponent(first.width, last.width, first.parent.instructions_per_job_median, last.parent.instructions_per_job_median),
      candidate_growth_exponent: exponent(first.width, last.width, first.candidate.instructions_per_job_median, last.candidate.instructions_per_job_median),
    },
  };
}

export function buildArtifact(inputs: GrowthInput[], familyPrefix: string, schema = loadSchema(), attributionSchema = loadAttributionSchema()): any {
  requireValue(typeof familyPrefix === "string" && /^[a-z][a-z0-9_]*_$/.test(familyPrefix), "algorithmic-growth family prefix must be a lowercase workload prefix ending in underscore");
  const sorted = inputs.slice().sort((left, right) => left.width - right.width);
  requireValue(sorted.length >= schema.minimum_widths, `algorithmic-growth requires at least ${schema.minimum_widths} widths`);
  requireValue(new Set(sorted.map((input) => input.width)).size === sorted.length, "algorithmic-growth widths must be unique");
  for (let index = 1; index < sorted.length; index += 1) requireValue(sorted[index].width > sorted[index - 1].width, "algorithmic-growth widths must increase strictly");
  const metadata = derivedMetadata(sorted, familyPrefix, schema), summary = derivedSummary(sorted, familyPrefix, schema, attributionSchema);
  return { schema_version: schema.schema_version, profile_id: schema.profile_id, kind: "algorithmic_growth", metadata, inputs: sorted, summary };
}

export function validateArtifact(artifact: any, schema = loadSchema(), attributionSchema = loadAttributionSchema()): any {
  requireValue(artifact?.schema_version === schema.schema_version && artifact.profile_id === schema.profile_id && artifact.kind === "algorithmic_growth", "algorithmic-growth artifact identity drift");
  requireValue(Array.isArray(artifact.inputs), "algorithmic-growth inputs are missing");
  const rebuilt = buildArtifact(artifact.inputs, artifact.metadata?.family_prefix, schema, attributionSchema);
  requireValue(exactJson(artifact.metadata) === exactJson(rebuilt.metadata), "algorithmic-growth metadata drift");
  requireValue(exactJson(artifact.summary) === exactJson(rebuilt.summary), "algorithmic-growth derived summary drift");
  return artifact;
}

function formatCount(value: number): string { return Number.isInteger(value) ? String(value) : value.toFixed(2); }
export function render(artifact: any): string {
  validateArtifact(artifact);
  const metadata = artifact.metadata, summary = artifact.summary;
  const rows = summary.rows.map((row: any) => `| ${row.width} | ${row.jobs} | ${row.checksum} | ${row.parent.instructions_per_job_median.toFixed(2)} | ${(row.parent.instructions_per_job_rsd * 100).toFixed(2)}% | ${row.candidate.instructions_per_job_median.toFixed(2)} | ${(row.candidate.instructions_per_job_rsd * 100).toFixed(2)}% | ${row.candidate_over_parent_instructions.toFixed(4)}x | ${formatCount(row.parent.allocations_per_job)} / ${formatCount(row.candidate.allocations_per_job)} | ${formatCount(row.parent.allocated_bytes_per_job)} / ${formatCount(row.candidate.allocated_bytes_per_job)} | ${row.full_efficiency_status} |`);
  const growth = summary.adjacent_growth.map((row: any) => `| ${row.from_width} → ${row.to_width} | ${row.width_ratio.toFixed(2)}x | ${row.parent_instruction_ratio.toFixed(4)}x | ${row.parent_growth_exponent.toFixed(3)} | ${row.candidate_instruction_ratio.toFixed(4)}x | ${row.candidate_growth_exponent.toFixed(3)} |`);
  const sources = metadata.source_artifacts.map((source: any) => `- ${source.width}: \`${source.file}\` (file SHA-256 \`${source.file_sha256}\`; embedded SHA-256 \`${source.embedded_artifact_sha256}\`)`);
  return [
    `# Exact-parent algorithmic growth — ${metadata.family_prefix}<width>`, "",
    `- parent: \`${metadata.parent_revision}\``, `- candidate: \`${metadata.candidate_revision}\``,
    `- zig-gc: \`${metadata.zig_gc_revision}\``, `- zig-regex: \`${metadata.zig_regex_revision}\``, `- Zig: \`${metadata.zig_version}\``,
    `- host: ${metadata.hardware}`, `- OS: ${metadata.os}`, `- host class: \`${metadata.host_class}\``,
    `- widths: ${metadata.widths.join(", ")}; ${metadata.samples_per_width} order-balanced pairs per width; no samples discarded`,
    `- scored boundary: ${metadata.claim_boundary}`, "",
    "This artifact does **not** score wall time, throughput, latency, cycles, energy, RSS, or thermals. Those complete observations and each ordinary full-efficiency decision remain embedded below the aggregate raw artifact.", "",
    "| width | jobs | checksum | parent instructions/job | parent RSD | candidate instructions/job | candidate RSD | candidate/parent | allocations/job P/C | bytes/job P/C | ordinary A/B status |",
    "| ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | --- |", ...rows, "",
    "| interval | width ratio | parent instruction ratio | parent exponent | candidate instruction ratio | candidate exponent |",
    "| --- | ---: | ---: | ---: | ---: | ---: |", ...growth, "",
    `First→last (${summary.first_to_last.from_width}→${summary.first_to_last.to_width}) instruction growth: parent ${summary.first_to_last.parent_instruction_ratio.toFixed(4)}x (exponent ${summary.first_to_last.parent_growth_exponent.toFixed(3)}), candidate ${summary.first_to_last.candidate_instruction_ratio.toFixed(4)}x (exponent ${summary.first_to_last.candidate_growth_exponent.toFixed(3)}).`, "",
    "## Embedded source artifacts", "", ...sources, "",
    `Power observations: ${metadata.power_states.map((value: string) => `\`${value}\``).join(", ")}.`,
    `Timed boundaries retained from the ordinary inputs: ${metadata.timed_boundaries.map((value: string) => `\`${value}\``).join(", ")}.`, "",
  ].join("\n");
}

function inputDescriptor(width: number, artifact: any, sourceFile = `row-${width}.json`): GrowthInput {
  return { width, source_file: sourceFile, source_file_sha256: sha256Text(`source-${width}`), embedded_artifact_sha256: sha256Text(exactJson(artifact)), artifact };
}

function exactFixture(width: number, attributionSchema: any): any {
  const jobs = 10, pairCount = 3, workload = `fixture_growth_${width}`, samples: any[] = [];
  for (let pair = 0; pair < pairCount; pair += 1) {
    const order = pair % 2 === 0 ? ["parent", "candidate"] : ["candidate", "parent"];
    order.forEach((variant, position) => {
      const metrics = unavailableMetrics(attributionSchema, "synthetic algorithmic-growth fixture leaves this metric unavailable");
      const quadratic = width * width / 16, linear = width * 64, instructionBase = variant === "parent" ? quadratic : linear;
      measured(metrics, "wall_time_ns", variant === "parent" ? width * width * 100 + pair : pair === 1 ? 1000 : 10, "fixture wall diagnostic");
      measured(metrics, "process_cpu_user_ns", 1000, "fixture process user"); measured(metrics, "process_cpu_system_ns", 10, "fixture process system"); measured(metrics, "peak_rss_bytes", 1000000, "fixture peak RSS");
      measured(metrics, "allocations", width + (variant === "candidate" ? 2 : 1), "fixture allocation replay"); measured(metrics, "allocated_bytes", width * 10 + (variant === "candidate" ? 20 : 10), "fixture byte replay");
      measured(metrics, "instructions", Math.round(instructionBase * jobs * (1 + pair / 1000)), "fixture instructions");
      measured(metrics, "cycles", pair === 1 ? 100000 : 10, "fixture noisy cycles"); measured(metrics, "energy_joules", pair === 1 ? 1 : 0.001, "fixture noisy energy");
      metrics.thermal_state = { status: "measured", value: "nominal->nominal", source: "fixture thermal", reason: "" };
      samples.push({ identity: { variant, pair_sample: pair, order: position, engine: "zig-js", mode: "single", workload, lanes: 1, jobs, checksum: width * 17 }, quality: { process_wall_time_ns: 2000, process_cpu_occupancy: 1, minimum_process_cpu_occupancy: 0.6 }, metrics });
    });
  }
  const metadata = { parent_revision: "a".repeat(40), candidate_revision: "b".repeat(40), candidate_first_parent: "a".repeat(40), zig_gc_revision: "c".repeat(40), zig_regex_revision: "d".repeat(40), zig_version: "fixture-zig", os: "fixture-os", hardware: "fixture-hardware", power: `Battery ${width}`, host_class: "diagnostic", material_change_categories: ["cpu_work"], workload_source_sha256: "e".repeat(64), parent_binary_sha256: "f".repeat(64), candidate_binary_sha256: "1".repeat(64), samples: pairCount, minimum_process_cpu_occupancy: 0.6, timed_boundary: "fixture exact logical jobs", mode: "single", workload, lanes: 1, jobs, expected_checksum: width * 17 };
  const artifact = { schema_version: attributionSchema.schema_version, profile_id: attributionSchema.profile_id, kind: "exact_parent_ab", metadata, samples, summary: summarizeExactParent(samples, attributionSchema, "diagnostic", ["cpu_work"]) };
  validateAttributionArtifact(artifact, attributionSchema); return artifact;
}

function expectFailure(action: () => void, pattern: string): void { try { action(); } catch (error) { requireValue(String(error).includes(pattern), `expected ${pattern}, got ${String(error)}`); return; } throw new Error(`expected failure containing ${pattern}`); }
export function selfTest(): void {
  const schema = loadSchema(), attributionSchema = loadAttributionSchema(ATTRIBUTION_SCHEMA), widths = [1024, 2048, 4096];
  const inputs = widths.map((width) => inputDescriptor(width, exactFixture(width, attributionSchema)));
  const artifact = buildArtifact(inputs, "fixture_growth_", schema, attributionSchema); validateArtifact(artifact, schema, attributionSchema);
  requireValue(Math.abs(artifact.summary.first_to_last.parent_growth_exponent - 2) < 0.01 && Math.abs(artifact.summary.first_to_last.candidate_growth_exponent - 1) < 0.01, "growth exponent derivation drift");
  requireValue(summarizeExactParent(inputs[0].artifact.samples, attributionSchema, "quiet_reference", ["cpu_work"]).status === "blocked_efficiency_evidence", "additive growth profile must not weaken the ordinary full-efficiency gate");
  requireValue(render(artifact).includes("does **not** score wall time"), "algorithmic-growth report lost its non-throughput boundary");

  const zeroAllocation = JSON.parse(JSON.stringify(inputs)); for (const sample of zeroAllocation[0].artifact.samples.filter((value: any) => value.identity.variant === "candidate")) { sample.metrics.allocations.value = 0; sample.metrics.allocated_bytes.value = 0; } zeroAllocation[0].artifact.summary = summarizeExactParent(zeroAllocation[0].artifact.samples, attributionSchema, "diagnostic", ["cpu_work"]); zeroAllocation[0].embedded_artifact_sha256 = sha256Text(exactJson(zeroAllocation[0].artifact)); requireValue(buildArtifact(zeroAllocation, "fixture_growth_", schema, attributionSchema).summary.rows[0].candidate.allocations_total === 0, "zero-allocation replay must remain valid");

  expectFailure(() => buildArtifact(inputs.slice(0, 2), "fixture_growth_", schema, attributionSchema), "at least 3 widths");
  const revisionDrift = JSON.parse(JSON.stringify(inputs)); revisionDrift[1].artifact.metadata.candidate_revision = "9".repeat(40); revisionDrift[1].artifact.summary = summarizeExactParent(revisionDrift[1].artifact.samples, attributionSchema, "diagnostic", ["cpu_work"]); revisionDrift[1].embedded_artifact_sha256 = sha256Text(exactJson(revisionDrift[1].artifact)); expectFailure(() => buildArtifact(revisionDrift, "fixture_growth_", schema, attributionSchema), "common metadata drift for candidate_revision");
  const noisyInstructions = JSON.parse(JSON.stringify(inputs)); const noisyArtifact = noisyInstructions[1].artifact, noisySample = noisyArtifact.samples.find((sample: any) => sample.identity.variant === "candidate" && sample.identity.pair_sample === 1); noisySample.metrics.instructions.value *= 2; noisyArtifact.summary = summarizeExactParent(noisyArtifact.samples, attributionSchema, "diagnostic", ["cpu_work"]); noisyInstructions[1].embedded_artifact_sha256 = sha256Text(exactJson(noisyArtifact)); expectFailure(() => buildArtifact(noisyInstructions, "fixture_growth_", schema, attributionSchema), "normalized instruction RSD");
  const allocationDrift = JSON.parse(JSON.stringify(inputs)); const allocationArtifact = allocationDrift[2].artifact, allocationSample = allocationArtifact.samples.find((sample: any) => sample.identity.variant === "parent" && sample.identity.pair_sample === 2); allocationSample.metrics.allocations.value += 1; allocationArtifact.summary = summarizeExactParent(allocationArtifact.samples, attributionSchema, "diagnostic", ["cpu_work"]); allocationDrift[2].embedded_artifact_sha256 = sha256Text(exactJson(allocationArtifact)); expectFailure(() => buildArtifact(allocationDrift, "fixture_growth_", schema, attributionSchema), "allocation replay drift");
  const summaryDrift = JSON.parse(JSON.stringify(artifact)); summaryDrift.summary.first_to_last.candidate_growth_exponent = 99; expectFailure(() => validateArtifact(summaryDrift, schema, attributionSchema), "derived summary drift");
  console.log("OK algorithmic-growth self-test: exact identities, normalization, stability, replay, growth, and non-throughput boundaries verified");
}

function requireClean(path: string): void { const result = run(["git", "-C", path, "status", "--porcelain", "--untracked-files=no"]); requireValue(result.exitCode === 0, `cannot verify clean evidence input: ${path}`); requireValue(!result.stdout.trim(), `refusing algorithmic-growth publication from dirty tracked worktree: ${path}`); }

function main(): void {
  const raw = process.argv.slice(2);
  if (raw.length === 1 && raw[0] === "--self-test") { selfTest(); return; }
  let schemaPath = DEFAULT_SCHEMA, artifactPath = "", familyPrefix = "", rawOut = "", markdownOut = ""; const rowSpecs: string[] = [];
  for (let index = 0; index < raw.length; index += 1) {
    const arg = raw[index];
    if (["--schema", "--artifact", "--family-prefix", "--row", "--raw-out", "--markdown-out"].includes(arg) && index + 1 < raw.length) {
      const value = raw[++index]; if (arg === "--schema") schemaPath = value; else if (arg === "--artifact") artifactPath = value; else if (arg === "--family-prefix") familyPrefix = value; else if (arg === "--row") rowSpecs.push(value); else if (arg === "--raw-out") rawOut = value; else markdownOut = value;
    } else throw new Error(`unknown or incomplete argument: ${arg}`);
  }
  const schema = loadSchema(schemaPath), attributionSchema = loadAttributionSchema();
  if (artifactPath) { requireValue(rowSpecs.length === 0 && !familyPrefix && !rawOut && !markdownOut, "--artifact cannot be combined with generation options"); validateArtifact(JSON.parse(readText(artifactPath)), schema, attributionSchema); console.log(`OK ${artifactPath}: ${schema.profile_id}`); return; }
  requireValue(familyPrefix && rawOut && markdownOut && rowSpecs.length >= schema.minimum_widths, "usage: algorithmic-growth.ts --family-prefix PREFIX --row WIDTH:EXACT.json [--row ...] --raw-out OUT.json --markdown-out OUT.md");
  for (const repository of [ROOT, `${ROOT}/../zig-gc`, `${ROOT}/../zig-regex`]) requireClean(repository);
  const inputs: GrowthInput[] = rowSpecs.map((spec) => {
    const separator = spec.indexOf(":"), width = Number(spec.slice(0, separator)), path = spec.slice(separator + 1);
    requireValue(separator > 0 && Number.isInteger(width) && width > 0 && path.length > 0 && fileExists(path), `invalid or missing algorithmic-growth row: ${spec}`);
    const source = readText(path), exactArtifact = JSON.parse(source);
    return { width, source_file: basename(path), source_file_sha256: sha256File(path), embedded_artifact_sha256: sha256Text(exactJson(exactArtifact)), artifact: exactArtifact };
  });
  const artifact = buildArtifact(inputs, familyPrefix, schema, attributionSchema); validateArtifact(artifact, schema, attributionSchema);
  checked(["mkdir", "-p", rawOut.slice(0, rawOut.lastIndexOf("/")) || ".", markdownOut.slice(0, markdownOut.lastIndexOf("/")) || "."], "create algorithmic-growth output directories");
  writeText(rawOut, JSON.stringify(artifact, null, 2) + "\n"); writeText(markdownOut, render(artifact));
}
if (process.argv[1] === __filename) main();
