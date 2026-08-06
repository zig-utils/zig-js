/** Validate attribution-v1 artifacts and losslessly migrate legacy A/B TSVs. */
import { readText, sha256File, writeText } from "./lib/home";

declare const __dirname: string;
declare const __filename: string;
export const ROOT = __dirname === "tools" ? "." : __dirname.slice(0, __dirname.lastIndexOf("/tools"));
export const DEFAULT_SCHEMA = `${ROOT}/docs/.data/performance-attribution-schema-v1.json`;
const ALLOWED_STATES = ["measured", "unavailable", "not_applicable"];
const ALLOWED_KINDS = ["duration", "gauge", "counter", "hardware_counter", "environment"];

function requireValue(condition: boolean, message: string): void { if (!condition) throw new Error(message); }
const sameSet = (left: any[], right: any[]): boolean => left.length === right.length && left.every((value) => right.includes(value));
const unique = (values: any[]): boolean => new Set(values.map((value) => JSON.stringify(value))).size === values.length;
const isHex = (value: any, length: number): boolean => typeof value === "string" && value.length === length && /^[0-9a-f]+$/.test(value);
const relativeRsd = (values: number[]): number => { if (values.length <= 1) return 0; const mean = values.reduce((sum, value) => sum + value, 0) / values.length; if (mean === 0) return Infinity; return Math.sqrt(values.reduce((sum, value) => sum + (value - mean) ** 2, 0) / (values.length - 1)) / mean; };

export function loadSchema(path = DEFAULT_SCHEMA): any { const schema = JSON.parse(readText(path)); validateSchema(schema); return schema; }

export function validateSchema(schema: any): void {
  requireValue(schema.schema_version === 1, "unsupported attribution schema");
  requireValue(schema.profile_id === "zig-js-performance-attribution-v1", "unexpected profile id");
  requireValue(sameSet(Object.keys(schema.metric_states || {}), ALLOWED_STATES), "metric state inventory drift");
  const identity = ["variant", "pair_sample", "order", "engine", "mode", "workload", "lanes", "jobs", "checksum"];
  requireValue(JSON.stringify(schema.sample_identity) === JSON.stringify(identity), "sample identity drift");
  const metadata = schema.required_metadata;
  requireValue(Array.isArray(metadata) && unique(metadata), "metadata inventory is invalid");
  const policy = schema.regression_policy || {};
  requireValue(policy.wall_regression_ratio === 1.1, "regression threshold must remain 10%");
  requireValue(policy.maximum_rsd === 0.05, "stable-row RSD threshold must remain 5%");
  requireValue(policy.gate_host_class === "quiet_reference", "only the quiet reference host may gate");
  const metrics = schema.metrics;
  requireValue(Array.isArray(metrics) && metrics.length > 0, "metrics must be non-empty");
  const names = metrics.map((metric: any) => metric.name);
  requireValue(unique(names), "metric names must be unique");
  for (const metric of metrics) {
    requireValue(typeof metric.name === "string" && metric.name.length > 0, "metric name is missing");
    requireValue(typeof metric.unit === "string" && metric.unit.length > 0, `metric unit missing: ${JSON.stringify(metric)}`);
    requireValue(typeof metric.scope === "string" && metric.scope.length > 0, `metric scope missing: ${JSON.stringify(metric)}`);
    requireValue(ALLOWED_KINDS.includes(metric.kind), `metric kind is invalid: ${JSON.stringify(metric)}`);
  }
  const expected = [
    "wall_time_ns", "process_cpu_user_ns", "process_cpu_system_ns", "peak_rss_bytes", "retained_rss_bytes", "allocations", "allocated_bytes",
    "interpreter_entries", "vm_dispatches", "vm_quick_kernel_hits", "baseline_compilations", "baseline_entries", "optimizer_compilations",
    "optimizer_publications", "optimizer_osr_entries", "optimizer_deopts", "tier_rejections", "tier_up_ns", "compilation_ns", "deoptimization_ns",
    "generated_code_bytes", "retired_code_bytes", "reclaimed_code_bytes", "invalidations", "runtime_operation_calls", "host_callbacks", "wasm_dispatches",
    "gc_minor_cycles", "gc_full_cycles", "gc_pause_total_ns", "gc_pause_p50_ns", "gc_pause_p95_ns", "gc_pause_max_ns", "gc_prepare_ns", "gc_trace_ns",
    "gc_sweep_ns", "gc_post_sweep_ns", "allocator_publication_calls", "allocator_publication_cells", "allocator_publication_ns", "shape_lock_contentions",
    "property_lock_contentions", "element_lock_contentions", "lock_wait_ns", "worker_runs", "worker_run_ns", "worker_wait_ns", "thread_join_wait_ns",
    "cycles", "instructions", "cache_misses", "energy_joules", "thermal_state", "symbolized_native_samples", "anonymous_native_samples",
  ];
  const missing = expected.filter((name) => !names.includes(name)).sort(), extra = names.filter((name: string) => !expected.includes(name)).sort();
  requireValue(!missing.length && !extra.length, `v1 metric inventory drift; missing=${JSON.stringify(missing)}, extra=${JSON.stringify(extra)}`);
}

export function observation(status: string, value: any, source: string, reason = ""): any {
  requireValue(ALLOWED_STATES.includes(status), `invalid metric state: ${status}`);
  if (status === "measured") {
    requireValue(value !== null && value !== undefined, "measured observation requires a value");
    requireValue(Boolean(source), "measured observation requires a source");
    requireValue(!reason, "measured observation cannot carry an unavailable reason");
  } else {
    requireValue(value === null, `${status} observation must have a null value`);
    requireValue(Boolean(reason), `${status} observation requires a reason`);
  }
  return { status, value, source, reason };
}

export function unavailableMetrics(schema: any, reason: string): any {
  const result: any = {};
  for (const metric of schema.metrics) result[metric.name] = observation("unavailable", null, "", reason);
  return result;
}

export function validateMetrics(metrics: any, schema: any): void {
  const definitions: any = {}; for (const metric of schema.metrics) definitions[metric.name] = metric;
  requireValue(sameSet(Object.keys(metrics), Object.keys(definitions)), "sample metric inventory does not exactly match schema");
  for (const name of Object.keys(metrics)) {
    const metric = metrics[name]; requireValue(metric && typeof metric === "object" && !Array.isArray(metric), `metric observation must be an object: ${name}`);
    const { status, value, reason, source } = metric;
    requireValue(ALLOWED_STATES.includes(status), `invalid state for ${name}`);
    requireValue(typeof reason === "string" && typeof source === "string", `invalid provenance for ${name}`);
    if (status === "measured") {
      requireValue(value !== null && value !== undefined && source.length > 0, `measured ${name} lacks value/source`);
      if (definitions[name].unit !== "categorical") requireValue(typeof value === "number" && Number.isFinite(value) && value >= 0, `measured ${name} must be numeric and non-negative`);
      requireValue(reason === "", `measured ${name} has a reason`);
    } else requireValue(value === null && reason.length > 0, `${status} ${name} must be null with a reason`);
  }
}

export function validateArtifact(artifact: any, schema: any): void {
  requireValue(artifact.schema_version === schema.schema_version, "artifact schema version mismatch");
  requireValue(artifact.profile_id === schema.profile_id, "artifact profile id mismatch");
  requireValue(["exact_parent_ab", "legacy_migration"].includes(artifact.kind), "artifact kind is invalid");
  const metadata = artifact.metadata; requireValue(metadata && typeof metadata === "object" && !Array.isArray(metadata), "artifact metadata is missing");
  for (const field of schema.required_metadata) requireValue(field in metadata, `artifact metadata missing ${field}`);
  const samples = artifact.samples; requireValue(Array.isArray(samples) && samples.length > 0, "artifact samples are missing");
  const identities = new Set<string>();
  for (const sample of samples) {
    requireValue(sample && typeof sample === "object" && !Array.isArray(sample), "sample must be an object");
    const identity = sample.identity; requireValue(identity && typeof identity === "object" && !Array.isArray(identity), "sample identity is missing");
    requireValue(sameSet(Object.keys(identity), schema.sample_identity), "sample identity fields drifted");
    const key = JSON.stringify(schema.sample_identity.map((field: string) => identity[field])); requireValue(!identities.has(key), `duplicate sample identity: ${key}`); identities.add(key);
    requireValue(["parent", "candidate"].includes(identity.variant), "sample variant is invalid");
    requireValue(identity.order === 0 || identity.order === 1, "sample order is invalid");
    requireValue(Number.isInteger(identity.pair_sample) && identity.pair_sample >= 0, "pair sample is invalid");
    requireValue(Number.isInteger(identity.lanes) && identity.lanes > 0, "lane count is invalid");
    requireValue(Number.isInteger(identity.jobs) && identity.jobs > 0, "job count is invalid");
    requireValue(Number.isInteger(identity.checksum) && identity.checksum >= 0, "checksum is invalid");
    validateMetrics(sample.metrics || {}, schema);
  }
  if (artifact.kind !== "exact_parent_ab") return;
  for (const field of ["parent_revision", "candidate_revision", "candidate_first_parent", "zig_gc_revision", "zig_regex_revision"]) requireValue(isHex(metadata[field], 40), `exact-parent metadata has invalid ${field}`);
  requireValue(metadata.candidate_first_parent === metadata.parent_revision, "candidate first parent does not match parent revision");
  for (const field of ["workload_source_sha256", "parent_binary_sha256", "candidate_binary_sha256"]) requireValue(isHex(metadata[field], 64), `exact-parent metadata has invalid ${field}`);
  requireValue(["diagnostic", "quiet_reference"].includes(metadata.host_class), "exact-parent host class is invalid");
  requireValue(Number.isInteger(metadata.samples) && metadata.samples >= 2, "exact-parent sample count is invalid");
  const expected = new Set<string>(); for (const variant of ["parent", "candidate"]) for (let index = 0; index < metadata.samples; index += 1) expected.add(`${variant}:${index}`);
  const actual = new Set(samples.map((sample: any) => `${sample.identity.variant}:${sample.identity.pair_sample}`));
  requireValue(expected.size === actual.size && [...expected].every((key) => actual.has(key)) && samples.length === expected.size, "exact-parent pair inventory drift");
  for (let index = 0; index < metadata.samples; index += 1) {
    const pair = samples.map((sample: any) => sample.identity).filter((identity: any) => identity.pair_sample === index);
    requireValue(JSON.stringify(pair.map((item: any) => item.order).sort()) === "[0,1]", `pair ${index} order drift`);
    requireValue(new Set(pair.map((item: any) => item.checksum)).size === 1, `pair ${index} checksum drift`);
    const first = pair.find((item: any) => item.order === 0), wanted = index % 2 === 0 ? "parent" : "candidate";
    requireValue(first.variant === wanted, `pair ${index} did not alternate process order`);
  }
  const identityRows = samples.map((sample: any) => sample.identity);
  for (const field of ["engine", "mode", "workload", "lanes", "jobs", "checksum"]) requireValue(new Set(identityRows.map((identity: any) => identity[field])).size === 1, `exact-parent ${field} drift`);
  for (const field of ["mode", "workload", "lanes", "jobs"]) requireValue(metadata[field] === identityRows[0][field], `exact-parent metadata/sample ${field} mismatch`);
  requireValue(metadata.expected_checksum === identityRows[0].checksum, "exact-parent frozen checksum mismatch");
  const materialCategories = metadata.material_change_categories;
  requireValue(Array.isArray(materialCategories) && materialCategories.length > 0 && materialCategories.every((value: any) => ["cpu_work", "threads", "generated_code", "cache_traffic"].includes(value)) && unique(materialCategories), "exact-parent material-change categories are invalid");
  const categoryMetrics: Record<string, string[]> = { cpu_work: [], threads: [], generated_code: ["generated_code_bytes"], cache_traffic: ["cache_misses"] };
  const requiredCategoryMetrics = [...new Set(materialCategories.flatMap((category: string) => categoryMetrics[category]))];
  const unmetMetrics = requiredCategoryMetrics.filter((name) => !["parent", "candidate"].every((variant) => {
    const values = samples.filter((sample: any) => sample.identity.variant === variant).map((sample: any) => sample.metrics[name]);
    return values.every((value: any) => value.status === "measured") && relativeRsd(values.map((value: any) => Number(value.value))) <= schema.regression_policy.maximum_rsd;
  }));
  const efficiencyMetrics = ["instructions", "cycles", "energy_joules"], expectedEfficiencyStable = efficiencyMetrics.every((name) => ["parent", "candidate"].every((variant) => {
    const values = samples.filter((sample: any) => sample.identity.variant === variant).map((sample: any) => sample.metrics[name]);
    return values.every((value: any) => value.status === "measured") && relativeRsd(values.map((value: any) => Number(value.value))) <= schema.regression_policy.maximum_rsd;
  })) && samples.every((sample: any) => sample.metrics.thermal_state.status === "measured" && sample.metrics.thermal_state.value === "nominal->nominal") && unmetMetrics.length === 0;
  requireValue(JSON.stringify(artifact.summary?.efficiency?.required_categories) === JSON.stringify(materialCategories) && JSON.stringify(artifact.summary?.efficiency?.unmet_metrics) === JSON.stringify(unmetMetrics), "exact-parent efficiency requirement summary drift");
  requireValue(artifact.summary?.efficiency?.stable === expectedEfficiencyStable, "exact-parent efficiency summary/sample drift");
  requireValue(artifact.summary.efficiency.blocks_publication === (metadata.host_class === schema.regression_policy.gate_host_class && !expectedEfficiencyStable), "exact-parent efficiency publication decision drift");
  requireValue(artifact.summary.blocks_publication === Boolean(artifact.summary.regression && artifact.summary.stable && artifact.summary.gating_host || artifact.summary.efficiency.blocks_publication), "exact-parent combined publication decision drift");
}

function parseTsv(text: string): string[][] {
  const rows: string[][] = []; let row: string[] = [], field = "", quoted = false;
  for (let index = 0; index < text.length; index += 1) {
    const char = text[index];
    if (quoted && char === '"' && text[index + 1] === '"') { field += '"'; index += 1; }
    else if (char === '"') quoted = !quoted;
    else if (!quoted && char === "\t") { row.push(field); field = ""; }
    else if (!quoted && char === "\n") { row.push(field.replace(/\r$/, "")); rows.push(row); row = []; field = ""; }
    else field += char;
  }
  if (field.length || row.length) { row.push(field.replace(/\r$/, "")); rows.push(row); }
  return rows.filter((entry) => entry.some((value) => value.length > 0));
}
function numeric(value: string): number | string { const number = Number(value); return /^-?\d+$/.test(value) && Number.isSafeInteger(number) ? number : value; }
export function measured(metrics: any, name: string, value: number, source: string): void { metrics[name] = observation("measured", value, source); }

export function migrateLegacyTsv(path: string, schema: any): any {
  const table = parseTsv(readText(path)); requireValue(table.length > 1, `legacy artifact has no rows: ${path}`);
  const columns = table[0], rows = table.slice(1).map((values) => { const row: any = {}; columns.forEach((name, index) => row[name] = numeric(values[index] || "")); return row; });
  const fields = Object.keys(rows[0]), independentColumns = ["variant", "mode", "lanes", "sample", "order", "elapsed_ns", "checksum", "max_rss_bytes"];
  const independent = sameSet(fields, independentColumns), sharedColumns = ["variant", "pair_sample", "order", "workload", "lanes", "jobs", "elapsed_ns", "checksum", "kind"], shared = sharedColumns.every((name) => fields.includes(name));
  requireValue(independent || shared, `unsupported legacy A/B schema: ${JSON.stringify(fields.sort())}`);
  const reason = "metric was not present in the losslessly retained legacy TSV row", samples: any[] = [];
  for (const row of rows) {
    const metrics = unavailableMetrics(schema, reason); measured(metrics, "wall_time_ns", Number(row.elapsed_ns), "legacy_fields.elapsed_ns");
    if ("max_rss_bytes" in row) measured(metrics, "peak_rss_bytes", Number(row.max_rss_bytes), "legacy_fields.max_rss_bytes");
    if (shared) {
      const mapping: any = { gc_minor_cycles: "minor_cycles", gc_full_cycles: "full_cycles", gc_pause_total_ns: "pause_ns_total", gc_pause_max_ns: "pause_ns_max", allocator_publication_calls: "object_batch_calls", allocator_publication_cells: "object_batch_cells", allocator_publication_ns: "object_batch_ns_total", worker_runs: "worker_runs", worker_run_ns: "worker_run_ns", thread_join_wait_ns: "join_wait_ns" };
      for (const target of Object.keys(mapping)) if (mapping[target] in row) measured(metrics, target, Number(row[mapping[target]]), `legacy_fields.${mapping[target]}`);
      const phases: any = { gc_prepare_ns: ["minor_prepare_ns", "full_prepare_ns"], gc_trace_ns: ["minor_trace_ns", "full_trace_ns"], gc_sweep_ns: ["minor_sweep_ns", "full_sweep_ns"], gc_post_sweep_ns: ["minor_post_sweep_ns", "full_post_sweep_ns"] };
      for (const target of Object.keys(phases)) if (phases[target].every((source: string) => source in row)) measured(metrics, target, Number(row[phases[target][0]]) + Number(row[phases[target][1]]), phases[target].map((source: string) => `legacy_fields.${source}`).join("+"));
    }
    samples.push({ identity: { variant: String(row.variant), pair_sample: Number(row.pair_sample === undefined ? row.sample || 0 : row.pair_sample), order: Number(row.order), engine: "zig-js", mode: String(row.mode || "shared"), workload: String(row.workload || "object_churn"), lanes: Number(row.lanes), jobs: Number(row.jobs || 100), checksum: Number(row.checksum) }, metrics, legacy_fields: row });
  }
  const unavailable = "unavailable: legacy TSV does not encode this metadata; consult its paired Markdown report", metadata: any = {};
  for (const field of schema.required_metadata) metadata[field] = unavailable;
  metadata.samples = new Set(samples.map((sample) => sample.identity.pair_sample)).size; metadata.timed_boundary = "preserved in legacy_fields; consult paired Markdown report";
  const artifact = { schema_version: schema.schema_version, profile_id: schema.profile_id, kind: "legacy_migration", metadata, legacy: { source_path: path.split("/").pop(), source_sha256: sha256File(path), source_columns: columns, rows: rows.length }, samples };
  validateArtifact(artifact, schema); return artifact;
}

function expectFailure(action: () => void, pattern: string): void { try { action(); } catch (error) { requireValue(String(error).includes(pattern), `expected error containing ${pattern}, got ${String(error)}`); return; } throw new Error(`expected failure containing ${pattern}`); }
export function selfTest(): void {
  const schema = loadSchema(); validateSchema(schema);
  const removed = JSON.parse(JSON.stringify(schema)); removed.metrics = removed.metrics.filter((metric: any) => metric.name !== "optimizer_deopts"); expectFailure(() => validateSchema(removed), "optimizer_deopts");
  const added = JSON.parse(JSON.stringify(schema)); added.metrics.push({ name: "silent_new_metric", unit: "count", scope: "test", kind: "counter" }); expectFailure(() => validateSchema(added), "silent_new_metric");
  expectFailure(() => observation("unavailable", 0, "", "missing"), "null value");
  const independent = migrateLegacyTsv(`${ROOT}/docs/.data/object-churn-independent-id-block-ab-2026-07-29.tsv`, schema); requireValue(independent.samples.length === 112, "independent migration row count drift"); requireValue(independent.samples[0].legacy_fields.elapsed_ns === independent.samples[0].metrics.wall_time_ns.value, "independent wall mapping drift"); requireValue(independent.samples[0].metrics.peak_rss_bytes.status === "measured", "independent RSS mapping drift"); requireValue(independent.samples[0].metrics.optimizer_deopts.status === "unavailable", "independent unavailable mapping drift");
  const shared = migrateLegacyTsv(`${ROOT}/docs/.data/object-churn-shared-reserve-ab-2026-07-29.tsv`, schema); requireValue(shared.samples.length === 56, "shared migration row count drift"); requireValue(shared.samples[0].legacy_fields.minor_cycles === shared.samples[0].metrics.gc_minor_cycles.value, "shared minor-cycle mapping drift"); requireValue(shared.samples[0].legacy_fields.object_batch_cells === shared.samples[0].metrics.allocator_publication_cells.value, "shared publication mapping drift"); requireValue(shared.samples[0].metrics.thread_join_wait_ns.status === "measured", "shared join-wait mapping drift");
  console.log("OK performance-attribution self-test: schema failures and 168 legacy rows verified");
}

function main(): void {
  let schemaPath = DEFAULT_SCHEMA, artifactPath = "", legacyPath = "", outputPath = "", runSelfTest = false;
  const args = process.argv.slice(2); for (let index = 0; index < args.length; index += 1) { const arg = args[index]; if (arg === "--schema") schemaPath = args[++index]; else if (arg === "--artifact") artifactPath = args[++index]; else if (arg === "--migrate-legacy") legacyPath = args[++index]; else if (arg === "--output") outputPath = args[++index]; else if (arg === "--self-test") runSelfTest = true; else throw new Error(`unknown argument: ${arg}`); }
  if (runSelfTest) { selfTest(); return; }
  const schema = loadSchema(schemaPath); requireValue(!(artifactPath && legacyPath), "choose --artifact or --migrate-legacy");
  if (artifactPath) { validateArtifact(JSON.parse(readText(artifactPath)), schema); console.log(`OK ${artifactPath}: ${schema.profile_id}`); return; }
  if (legacyPath) { requireValue(Boolean(outputPath), "--migrate-legacy requires --output"); const artifact = migrateLegacyTsv(legacyPath, schema); writeText(outputPath, JSON.stringify(artifact, null, 2) + "\n"); console.log(`OK migrated ${artifact.samples.length} rows from ${legacyPath}`); return; }
  validateSchema(schema); console.log(`OK ${schema.profile_id}: ${schema.metrics.length} metrics`);
}
if (process.argv[1] === __filename) main();
