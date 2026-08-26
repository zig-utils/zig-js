/** Collect a stable, order-balanced exact-parent performance A/B artifact. */
import { checked, readText, removeTemporaryDirectory, run, sha256File, temporaryDirectory, writeText } from "./lib/home";
import { loadSchema, measured, unavailableMetrics, validateArtifact } from "./performance-attribution";
import { parseDarwinCounters, parseDarwinCpuTime, parseDarwinThermalState } from "./instrumentation-overhead";
import { competingEvidenceProcesses, MINIMUM_PROCESS_CPU_OCCUPANCY, processCpuOccupancy } from "./evidence-processes";
// Inventory-visible module edges: tools/performance-attribution.ts, tools/instrumentation-overhead.ts, and tools/evidence-processes.ts.

declare const __dirname: string;
declare const __filename: string;
export const ROOT = __dirname === "tools" ? "." : __dirname.slice(0, __dirname.lastIndexOf("/tools"));
export const DEFAULT_SCHEMA = `${ROOT}/docs/.data/performance-attribution-schema-v3.json`;
export const DEFAULT_LIFECYCLE_PROFILE = `${ROOT}/docs/.data/context-lifecycle-profile-v1.json`;
const REVISION_RE = /^[0-9a-f]{40}$/;
const SHARED_MEASUREMENT_OVERLAY_PATHS = [
  "bench/comparison_zig_js.zig", "bench/frontend_parse.zig",
  "docs/.data/algorithmic-growth-schema-v2.json", "docs/.data/bunpress-output-v1.json", "docs/.data/performance-attribution-schema-v2.json", "docs/.data/representative-benchmark-matrix-v24.json", "docs/benchmarks.md",
  "tools/algorithmic-growth.ts", "tools/exact-parent-regression.ts", "tools/instrumentation-overhead.ts", "tools/performance-attribution.ts", "tools/representative-matrix.ts",
];
export type RunnerRow = { engine: string; mode: string; workload: string; lanes: number; jobs: number; elapsed_ns: number; checksum: number; measured_boundary_cpu_user_ns: number; measured_boundary_cpu_system_ns: number; measured_boundary_cpu_occupancy: number; process_wall_time_ns: number; process_cpu_user_ns: number; process_cpu_system_ns: number; process_cpu_occupancy: number; peak_rss_bytes: number; retained_rss_bytes: number | null; allocations: number | null; allocated_bytes: number | null; allocation_source: string | null; allocation_replay_signature: any | null; instructions: number; cycles: number; energy_joules: number; thermal_state: string; lifecycle?: LifecycleTelemetry };
export type BatchRow = { workload: string; jobs: number; expected_checksum: number; raw_out: string; markdown_out: string };
export type LifecycleTelemetry = { schema_version: number; scenario: string; context_options_profile: string; iterations: number; sample: number; create_ns: number; work_ns: number; destroy_ns: number; phase_total_ns: number; cpu_user_ns: number; cpu_system_ns: number; baseline_rss_bytes: number; max_live_rss_bytes: number; post_destroy_rss_bytes: number; retained_delta_bytes: number; peak_rss_bytes: number; rss_checkpoints: number[]; finalizers: Record<string, number> };
export type AllocationReplayContract = { schema_version: number; profile_id: string; status: string; owner_issue: number; history_policy: string; replay: { mode: string; phase: string; workload: string; lanes: number; jobs: number; checksum: number }; signature: any };
function requireValue(condition: boolean, message: string): void { if (!condition) throw new Error(message); }
function requireNoCompetingEvidenceProcess(phase: string, listing = commandOutput(["ps", "-axo", "pid=,ppid=,command="], ""), selfPid = process.pid): void {
  const competitors = competingEvidenceProcesses(listing, selfPid);
  requireValue(competitors.length === 0, `competing build/test process detected ${phase}:\n${competitors.join("\n")}`);
}

export function commandOutput(arguments_: string[], defaultValue = "unknown"): string { const result = run(arguments_); return result.exitCode === 0 && result.stdout.trim() ? result.stdout.trim() : defaultValue; }
export function resolveRevision(revision: string, repository = ROOT): string { const resolved = commandOutput(["git", "-C", repository, "rev-parse", `${revision}^{commit}`], ""); requireValue(REVISION_RE.test(resolved), `cannot resolve commit: ${revision}`); return resolved; }
export function validateExactParent(parent: string, candidate: string, repository = ROOT): [string, string] { const parentRevision = resolveRevision(parent, repository), candidateRevision = resolveRevision(candidate, repository), candidateParent = resolveRevision(`${candidateRevision}^1`, repository); requireValue(candidateParent === parentRevision, `candidate first parent is ${candidateParent}, not requested exact parent ${parentRevision}`); return [parentRevision, candidateRevision]; }
export function repositoryRevision(path: string): string { const revision = commandOutput(["git", "-C", path, "rev-parse", "HEAD"], ""); requireValue(REVISION_RE.test(revision), `cannot resolve repository revision: ${path}`); return revision; }
export function requireClean(path: string): void { const result = run(["git", "-C", path, "status", "--porcelain", "--untracked-files=no"]); requireValue(result.exitCode === 0, `cannot verify tracked worktree cleanliness: ${path}`); requireValue(!result.stdout.trim(), `refusing exact-parent publication from dirty tracked worktree: ${path}`); }
function revisionChangedPaths(base: string, overlay: string, repository: string): string[] { const output = commandOutput(["git", "-C", repository, "diff", "--name-only", `${base}..${overlay}`], ""); return output ? output.split("\n").filter(Boolean).sort() : []; }
function revisionBlob(revision: string, path: string, repository: string): string { const blob = commandOutput(["git", "-C", repository, "rev-parse", `${revision}:${path}`], ""); requireValue(REVISION_RE.test(blob), `cannot resolve overlay blob ${revision}:${path}`); return blob; }
export function validateSharedMeasurementOverlay(logicalParent: string, logicalCandidate: string, parentBinary: string, candidateBinary: string, repository = ROOT, expectedPaths = SHARED_MEASUREMENT_OVERLAY_PATHS): [string, string] {
  const parentRevision = resolveRevision(logicalParent, repository), candidateRevision = resolveRevision(logicalCandidate, repository), parentBinaryRevision = resolveRevision(parentBinary, repository), candidateBinaryRevision = resolveRevision(candidateBinary, repository);
  requireValue(resolveRevision(`${parentBinaryRevision}^1`, repository) === parentRevision, "parent binary revision is not a one-commit child of the logical parent");
  requireValue(resolveRevision(`${candidateBinaryRevision}^1`, repository) === candidateRevision, "candidate binary revision is not a one-commit child of the logical candidate");
  const expected = expectedPaths.slice().sort(), parentPaths = revisionChangedPaths(parentRevision, parentBinaryRevision, repository), candidatePaths = revisionChangedPaths(candidateRevision, candidateBinaryRevision, repository);
  requireValue(JSON.stringify(parentPaths) === JSON.stringify(expected) && JSON.stringify(candidatePaths) === JSON.stringify(expected), "shared measurement overlay path inventory drift");
  for (const path of expected) requireValue(revisionBlob(parentBinaryRevision, path, repository) === revisionBlob(candidateBinaryRevision, path, repository), `shared measurement overlay blob drift: ${path}`);
  return [parentBinaryRevision, candidateBinaryRevision];
}
export function validateDirectBinaryRevisions(logicalParent: string, logicalCandidate: string, parentBinary: string, candidateBinary: string, repository = ROOT): [string, string] {
  const parentRevision = resolveRevision(logicalParent, repository), candidateRevision = resolveRevision(logicalCandidate, repository), parentBinaryRevision = resolveRevision(parentBinary, repository), candidateBinaryRevision = resolveRevision(candidateBinary, repository);
  requireValue(parentBinaryRevision === parentRevision, "direct parent binary revision does not match the logical parent");
  requireValue(candidateBinaryRevision === candidateRevision, "direct candidate binary revision does not match the logical candidate");
  return [parentBinaryRevision, candidateBinaryRevision];
}

export function parseBenchmark(stdout: string, expectedMode: string, expectedWorkload: string, lanes: number, jobs: number): [string, number, number] {
  const rows = stdout.split("\n").filter((line) => line.startsWith("zig-js\t")); requireValue(rows.length === 1, `expected one zig-js benchmark row, got ${rows.length}`);
  const fields = rows[0].split("\t"); requireValue(fields.length === 8, `benchmark row width is ${fields.length}, expected 8`);
  const [engine, mode, workload] = fields; requireValue(engine === "zig-js" && mode === expectedMode && workload === expectedWorkload, `benchmark row identity drift: ${JSON.stringify(fields.slice(0, 3))}`);
  requireValue(Number(fields[3]) === lanes && Number(fields[4]) === jobs && Number(fields[5]) === 0, "benchmark lane/jobs/sample identity drift");
  return [engine, Number(fields[6]), Number(fields[7])];
}
export function timeMetric(stderr: string, label: string): number { const match = new RegExp(`(?:^|\\s)([0-9.]+)\\s+${label}(?:\\s|$)`).exec(stderr); requireValue(Boolean(match), `missing ${label} from /usr/bin/time -l`); return Number(match![1]); }
export function parsePeakRss(stderr: string): number { return Math.round(timeMetric(stderr, "maximum resident set size")); }
export function runnerArguments(mode: string, workload: string, jobs: number, lanes: number): string[] { if (mode === "single" || mode === "single_no_jit" || mode === "single_observed" || mode === "context_lifecycle") { requireValue(lanes === 1, `${mode} mode requires one lane`); return [mode, workload, String(jobs), "1", mode === "single_observed" ? "--native-observability-telemetry" : "--darwin-rusage"]; } requireValue(["independent_steady", "independent_cold", "shared", "module_cold"].includes(mode), `unsupported benchmark mode: ${mode}`); return [mode, workload, String(jobs), "1", String(lanes), "--darwin-rusage"]; }

const FINALIZER_KINDS = ["objects", "strings", "environments", "functions", "bound_functions", "promises", "generators", "iter_helpers", "module_namespaces"];
const FINALIZER_FIELDS = ["cells", "bulk_cell_frees_skipped", ...FINALIZER_KINDS, "object_backing_releases", "array_buffers", "shared_array_buffers", "promise_reactions"];
export function validateLifecycleProfile(profile: any): any {
  requireValue(profile && profile.schema_version === 1 && profile.profile_id === "zig-js-context-lifecycle-v1" && profile.status === "frozen" && profile.owner_issue === 661 && profile.runner === "bench/comparison_zig_js.zig" && profile.mode === "context_lifecycle" && profile.lanes === 1 && typeof profile.sample_boundary === "string" && profile.sample_boundary.length > 0, "lifecycle profile identity drift");
  requireValue(Array.isArray(profile.scenarios) && JSON.stringify(profile.scenarios.map((entry: any) => entry.id)) === JSON.stringify(["context_no_evaluation", "context_first_source", "context_first_module", "context_full_feature"]), "lifecycle scenario inventory drift");
  requireValue(profile.scenarios.every((entry: any) => ["gc_default", "gc_full_wasm"].includes(entry.context_options_profile) && Number.isInteger(entry.expected_checksum_per_iteration)), "lifecycle scenario contract is invalid");
  requireValue(JSON.stringify(Object.keys(profile.context_options_profiles).sort()) === JSON.stringify(["gc_default", "gc_full_wasm"]), "lifecycle context options inventory drift");
  requireValue(JSON.stringify(profile.required_phase_fields) === JSON.stringify(["create_ns", "work_ns", "destroy_ns", "phase_total_ns", "cpu_user_ns", "cpu_system_ns"]), "lifecycle phase field inventory drift");
  requireValue(JSON.stringify(profile.required_memory_fields) === JSON.stringify(["baseline_rss_bytes", "max_live_rss_bytes", "post_destroy_rss_bytes", "retained_delta_bytes", "peak_rss_bytes", "rss_checkpoints"]), "lifecycle memory field inventory drift");
  requireValue(JSON.stringify(profile.finalizer_kind_fields) === JSON.stringify(FINALIZER_KINDS) && JSON.stringify(profile.required_finalizer_fields) === JSON.stringify(FINALIZER_FIELDS), "lifecycle finalizer field inventory drift");
  const soak = profile.soak_policy; requireValue(soak.minimum_iterations === 8 && JSON.stringify(soak.checkpoint_fractions) === "[0.25,0.5,0.75,1]" && soak.maximum_post_destroy_growth_bytes === 8 * 1024 * 1024 && soak.maximum_post_destroy_growth_fraction === 0.05 && soak.reject_material_monotonic_growth === true, "lifecycle soak policy drift");
  requireValue(Array.isArray(profile.publication_guards) && profile.publication_guards.length === 6, "lifecycle publication guard inventory drift");
  return profile;
}
export function loadLifecycleProfile(path = DEFAULT_LIFECYCLE_PROFILE): any { return validateLifecycleProfile(JSON.parse(readText(path))); }
export function validateLifecycleTelemetry(value: any, expectedScenario: string, iterations: number, sample = 0, profile = loadLifecycleProfile()): LifecycleTelemetry {
  const scenario = profile.scenarios.find((entry: any) => entry.id === expectedScenario);
  requireValue(Boolean(scenario), `unknown lifecycle scenario: ${expectedScenario}`);
  requireValue(value && value.schema_version === profile.schema_version, "lifecycle telemetry schema drift");
  requireValue(value.scenario === expectedScenario && value.iterations === iterations && value.sample === sample, "lifecycle telemetry identity drift");
  requireValue(value.context_options_profile === scenario.context_options_profile, "lifecycle context options profile drift");
  for (const name of ["create_ns", "work_ns", "destroy_ns", "phase_total_ns", "cpu_user_ns", "cpu_system_ns", "baseline_rss_bytes", "max_live_rss_bytes", "post_destroy_rss_bytes", "peak_rss_bytes"])
    requireValue(Number.isInteger(value[name]) && value[name] >= 0, `lifecycle telemetry ${name} is invalid`);
  requireValue(value.create_ns > 0 && value.destroy_ns > 0 && value.phase_total_ns === value.create_ns + value.work_ns + value.destroy_ns, "lifecycle phase accounting drift");
  requireValue(value.baseline_rss_bytes > 0 && value.max_live_rss_bytes >= value.baseline_rss_bytes && value.peak_rss_bytes >= value.max_live_rss_bytes && value.post_destroy_rss_bytes > 0, "lifecycle RSS accounting drift");
  requireValue(Number.isInteger(value.retained_delta_bytes) && value.retained_delta_bytes === value.post_destroy_rss_bytes - value.baseline_rss_bytes, "lifecycle retained RSS delta drift");
  requireValue(Array.isArray(value.rss_checkpoints) && value.rss_checkpoints.length === 4 && value.rss_checkpoints.every((entry: unknown) => Number.isInteger(entry) && Number(entry) > 0), "lifecycle RSS checkpoints are invalid");
  requireValue(value.finalizers && FINALIZER_FIELDS.every((name) => Number.isInteger(value.finalizers[name]) && value.finalizers[name] >= 0), "lifecycle finalizer accounting is incomplete");
  const kindTotal = FINALIZER_KINDS.reduce((sum, name) => sum + value.finalizers[name], 0);
  requireValue(value.finalizers.cells === kindTotal && value.finalizers.bulk_cell_frees_skipped === value.finalizers.cells && value.finalizers.cells > 0, "lifecycle cells were not finalized exactly once");
  if (iterations >= profile.soak_policy.minimum_iterations) {
    const checkpoints = value.rss_checkpoints as number[], tolerance = Math.max(profile.soak_policy.maximum_post_destroy_growth_bytes, Math.ceil(value.baseline_rss_bytes * profile.soak_policy.maximum_post_destroy_growth_fraction));
    const materiallyMonotonic = checkpoints.every((entry, index) => index === 0 || entry >= checkpoints[index - 1]) && checkpoints[3] - checkpoints[0] > tolerance;
    requireValue(!materiallyMonotonic && checkpoints[3] - checkpoints[0] <= tolerance, "lifecycle retained RSS did not reach a bounded plateau");
  }
  return value as LifecycleTelemetry;
}
export function parseLifecycleTelemetry(stdout: string, expectedScenario: string, iterations: number, sample = 0): LifecycleTelemetry {
  const rows = stdout.split("\n").filter((line) => line.startsWith("zig-js-context-lifecycle\t"));
  requireValue(rows.length === 1, `expected one lifecycle telemetry row, got ${rows.length}`);
  let value: any; try { value = JSON.parse(rows[0].slice(rows[0].indexOf("\t") + 1)); } catch { throw new Error("lifecycle telemetry JSON is invalid"); }
  return validateLifecycleTelemetry(value, expectedScenario, iterations, sample);
}
export function validateLifecycleCollectionRequest(workload: string, jobs: number, expectedChecksum: number, profile = loadLifecycleProfile()): any {
  const scenario = profile.scenarios.find((entry: any) => entry.id === workload);
  requireValue(Boolean(scenario), `unknown lifecycle scenario: ${workload}`);
  requireValue(jobs >= profile.soak_policy.minimum_iterations, `context lifecycle exact-parent collection requires at least ${profile.soak_policy.minimum_iterations} cold iterations`);
  requireValue(expectedChecksum === scenario.expected_checksum_per_iteration * jobs, "lifecycle expected checksum/profile drift");
  return scenario;
}
export function parseRetainedRss(stdout: string, mode: string, workload: string, jobs: number): number {
  const rows = stdout.split("\n").filter((line) => line.startsWith("zig-js-native-observability\t")); requireValue(rows.length === 1, `expected one native-observability row, got ${rows.length}`);
  const fields = rows[0].split("\t"); requireValue(fields.length === 16 && fields[1] === mode && fields[2] === workload && Number(fields[3]) === jobs && Number(fields[4]) === 0, "native-observability identity drift");
  const retained = Number(fields[15]); requireValue(Number.isInteger(retained) && retained > 0, "native-observability retained RSS is invalid"); return retained;
}
export function parseFrontendAllocations(stdout: string, mode: string, workload: string, jobs: number): [number, number] | null {
  const rows = stdout.split("\n").filter((line) => line.startsWith("zig-js-frontend-allocations\t"));
  if (rows.length === 0) return null;
  requireValue(rows.length === 1, `expected at most one frontend-allocation row, got ${rows.length}`);
  const fields = rows[0].split("\t");
  requireValue(fields.length === 7 && fields[1] === mode && fields[2] === workload && Number(fields[3]) === jobs && Number(fields[4]) === 0, "frontend-allocation identity drift");
  const allocations = Number(fields[5]), allocatedBytes = Number(fields[6]);
  requireValue(Number.isInteger(allocations) && allocations > 0 && Number.isInteger(allocatedBytes) && allocatedBytes > 0, "frontend-allocation counters are invalid");
  return [allocations, allocatedBytes];
}
const REPLAY_SIGNATURE_MAPS = ["execution", "quick_binary", "admissions", "shape", "native_code"];
const REPLAY_SIGNATURE_SCALARS = ["baseline_publications", "optimizer_publications", "generated_code_bytes"];
function exactKeys(value: any, expected: string[], label: string): void {
  requireValue(value && typeof value === "object" && !Array.isArray(value) && JSON.stringify(Object.keys(value).sort()) === JSON.stringify(expected.slice().sort()), `${label} fields drift`);
}
function exactCounterMap(value: any, label: string): void {
  requireValue(value && typeof value === "object" && !Array.isArray(value) && Object.keys(value).length > 0 && Object.values(value).every((entry) => Number.isSafeInteger(entry) && Number(entry) >= 0), `${label} counters are invalid`);
}
function exactJson(value: any): string {
  if (Array.isArray(value)) return `[${value.map(exactJson).join(",")}]`;
  if (value && typeof value === "object") return `{${Object.keys(value).sort().map((name) => `${JSON.stringify(name)}:${exactJson(value[name])}`).join(",")}}`;
  return JSON.stringify(value);
}
export function validateAllocationReplayContract(value: any): AllocationReplayContract {
  exactKeys(value, ["schema_version", "profile_id", "status", "owner_issue", "history_policy", "replay", "signature"], "allocation replay contract");
  requireValue(value.schema_version === 1 && /^zig-js-allocation-replay-signature-v1:[a-z0-9_]+$/.test(value.profile_id) && value.status === "frozen" && value.owner_issue === 775 && typeof value.history_policy === "string" && value.history_policy.length > 0, "allocation replay contract identity drift");
  exactKeys(value.replay, ["mode", "phase", "workload", "lanes", "jobs", "checksum"], "allocation replay identity");
  requireValue(["attribution", "attribution_no_jit"].includes(value.replay.mode) && value.replay.phase === "invocation" && typeof value.replay.workload === "string" && value.replay.workload.length > 0 && Number.isSafeInteger(value.replay.lanes) && value.replay.lanes > 0 && Number.isSafeInteger(value.replay.jobs) && value.replay.jobs > 0 && Number.isSafeInteger(value.replay.checksum) && value.replay.checksum >= 0, "allocation replay identity is invalid");
  exactKeys(value.signature, [...REPLAY_SIGNATURE_MAPS, ...REPLAY_SIGNATURE_SCALARS], "allocation replay signature");
  for (const name of REPLAY_SIGNATURE_MAPS) exactCounterMap(value.signature[name], `allocation replay ${name}`);
  for (const name of REPLAY_SIGNATURE_SCALARS) requireValue(Number.isSafeInteger(value.signature[name]) && value.signature[name] >= 0, `allocation replay ${name} is invalid`);
  return value as AllocationReplayContract;
}
export function loadAllocationReplayContract(path: string): AllocationReplayContract { return validateAllocationReplayContract(JSON.parse(readText(path))); }
function subtractReplayMap(after: any, before: any, label: string): any {
  exactCounterMap(after, `${label} after`); exactCounterMap(before, `${label} before`);
  const keys = Object.keys(after).sort(); requireValue(JSON.stringify(keys) === JSON.stringify(Object.keys(before).sort()), `${label} inventory drift`);
  return Object.fromEntries(keys.map((name) => { requireValue(after[name] >= before[name], `${label}.${name} counter regressed`); return [name, after[name] - before[name]]; }));
}
function requireExactReplayMap(actual: any, expected: any, label: string): void {
  requireValue(exactJson(actual) === exactJson(expected), `native allocation replay ${label} signature drift`);
}
function contractedReplay(records: any[], contract: AllocationReplayContract, expectedMode: string, workload: string, jobs: number, lanes: number, checksum: number): [number, number, any] {
  const snapshots = records.filter((record) => record?.kind === "zig-js-tier-attribution");
  requireValue(snapshots.length === 3 && JSON.stringify(snapshots.map((record) => record.phase)) === '["configuration","warmup","invocation"]', "native allocation replay phase inventory drift");
  for (const record of snapshots) requireValue(record.mode === expectedMode && record.workload === workload && record.lanes === lanes && record.jobs === jobs, "native allocation replay identity drift");
  const expectedReplay = contract.replay;
  requireValue(expectedReplay.mode === (expectedMode === "single_no_jit" ? "attribution_no_jit" : "attribution") && expectedReplay.phase === "invocation" && expectedReplay.workload === workload && expectedReplay.lanes === lanes && expectedReplay.jobs === jobs && expectedReplay.checksum === checksum, "native allocation replay contract identity drift");
  const warmup = snapshots[1], invocation = snapshots[2]; requireValue(invocation.checksum === checksum, "native allocation replay checksum drift");
  const signature: any = {
    execution: subtractReplayMap(invocation.execution, warmup.execution, "execution"),
    quick_binary: subtractReplayMap(invocation.quick_binary, warmup.quick_binary, "quick_binary"),
    admissions: subtractReplayMap(invocation.admissions, warmup.admissions, "admissions"),
    shape: subtractReplayMap(invocation.shape, warmup.shape, "shape"),
    native_code: invocation.native_code,
    baseline_publications: invocation.baseline_publications - warmup.baseline_publications,
    optimizer_publications: invocation.optimizer_publications - warmup.optimizer_publications,
    generated_code_bytes: invocation.generated_code_bytes,
  };
  exactCounterMap(signature.native_code, "native_code");
  for (const name of ["baseline_publications", "optimizer_publications"]) requireValue(Number.isSafeInteger(signature[name]) && signature[name] >= 0, `${name} counter regressed`);
  requireValue(Number.isSafeInteger(signature.generated_code_bytes) && signature.generated_code_bytes >= 0, "generated_code_bytes is invalid");
  for (const name of REPLAY_SIGNATURE_MAPS) requireExactReplayMap(signature[name], contract.signature[name], name);
  for (const name of REPLAY_SIGNATURE_SCALARS) requireValue(signature[name] === contract.signature[name], `native allocation replay ${name} signature drift`);
  exactCounterMap(invocation.allocation, "allocation after"); exactCounterMap(warmup.allocation, "allocation before");
  requireValue(JSON.stringify(Object.keys(invocation.allocation).sort()) === JSON.stringify(Object.keys(warmup.allocation).sort()), "allocation inventory drift");
  const allocations = invocation.allocation.backing_allocations - warmup.allocation.backing_allocations, allocatedBytes = invocation.allocation.backing_allocation_bytes - warmup.allocation.backing_allocation_bytes;
  requireValue(Number.isSafeInteger(allocations) && allocations > 0 && Number.isSafeInteger(allocatedBytes) && allocatedBytes > 0, "native allocation replay counters are invalid");
  return [allocations, allocatedBytes, signature];
}
export function parseNativeAllocationReplay(stdout: string, replayMode: string, workload: string, jobs: number, lanes: number, checksum: number, contract: AllocationReplayContract | null = null): [number, number] | [number, number, any] {
  requireValue(replayMode === "attribution" || replayMode === "attribution_no_jit", `unsupported allocation replay mode: ${replayMode}`);
  const records: any[] = [];
  for (const line of stdout.split("\n").filter(Boolean)) { try { records.push(JSON.parse(line)); } catch { throw new Error("native allocation replay JSON is invalid"); } }
  const invocations = records.filter((record) => record?.kind === "zig-js-tier-attribution" && record?.phase === "invocation");
  requireValue(invocations.length === 1, `expected one native allocation invocation row, got ${invocations.length}`);
  const record = invocations[0], expectedMode = replayMode === "attribution_no_jit" ? "single_no_jit" : "single";
  if (contract) return contractedReplay(records, contract, expectedMode, workload, jobs, lanes, checksum);
  requireValue(record.mode === expectedMode && record.workload === workload && record.lanes === lanes && record.jobs === jobs, "native allocation replay identity drift");
  requireValue(record.checksum === checksum, "native allocation replay checksum drift");
  const execution = record.execution, admissions = record.admissions;
  requireValue(execution && execution.tree_walker_entries === 0 && execution.vm_entries > 0 && execution.vm_dispatches > 0 && execution.baseline_entries === 0 && execution.optimizer_entries === 0 && record.baseline_publications === 0 && record.optimizer_publications === 0 && record.generated_code_bytes === 0, "native allocation replay tier boundary drift");
  requireValue(admissions && admissions.program_compiled > 0 && admissions.template_plain_compiled > 0, "native allocation replay admission boundary drift");
  const allocations = record.allocation?.backing_allocations, allocatedBytes = record.allocation?.backing_allocation_bytes;
  requireValue(Number.isSafeInteger(allocations) && allocations > 0 && Number.isSafeInteger(allocatedBytes) && allocatedBytes > 0, "native allocation replay counters are invalid");
  return [allocations, allocatedBytes];
}
export function runOne(binary: string, mode: string, workload: string, jobs: number, lanes: number, allocationReplayMode = "", allocationReplayContract: AllocationReplayContract | null = null): RunnerRow {
  requireNoCompetingEvidenceProcess("before benchmark invocation");
  const command = ["env", "LC_ALL=C", "/usr/bin/time", "-l", binary, ...runnerArguments(mode, workload, jobs, lanes)]; console.error(`+ ${command.join(" ")}`);
  const completed = run(command); requireValue(completed.exitCode === 0, completed.stderr || `benchmark exited ${completed.exitCode}`);
  requireNoCompetingEvidenceProcess("after benchmark invocation");
  const [engine, elapsed_ns, checksum] = parseBenchmark(completed.stdout, mode, workload, lanes, jobs);
  const counters: any = parseDarwinCounters(completed.stdout, mode, workload, jobs), cpu = parseDarwinCpuTime(completed.stdout, mode, workload, jobs), thermal: any = parseDarwinThermalState(completed.stdout, mode, workload, jobs);
  requireValue(counters.instructions.status === "measured" && counters.cycles.status === "measured" && counters.process_energy_nj.status === "measured", "exact-parent Darwin counters are unavailable");
  requireValue(thermal.status === "measured", "exact-parent thermal state is unavailable");
  let allocationCounters = parseFrontendAllocations(completed.stdout, mode, workload, jobs), allocationSource = allocationCounters ? "untimed exact-work frontend parse/compile allocator replay" : null, allocationReplaySignature: any | null = null;
  if (allocationReplayMode) {
    requireValue(allocationCounters === null, "benchmark exposes both inline and native allocation replays");
    requireValue((mode === "single" && allocationReplayMode === "attribution") || (mode === "single_no_jit" && allocationReplayMode === "attribution_no_jit"), "native allocation replay does not match the timed mode");
    requireNoCompetingEvidenceProcess("before native allocation replay");
    const replayCommand = [binary, allocationReplayMode, workload, String(jobs), String(lanes)]; console.error(`+ ${replayCommand.join(" ")}`);
    const replay = run(replayCommand); requireValue(replay.exitCode === 0, replay.stderr || `native allocation replay exited ${replay.exitCode}`);
    requireNoCompetingEvidenceProcess("after native allocation replay");
    const parsed = parseNativeAllocationReplay(replay.stdout, allocationReplayMode, workload, jobs, lanes, checksum, allocationReplayContract);
    allocationCounters = [parsed[0], parsed[1]];
    allocationReplaySignature = parsed[2] || null;
    allocationSource = `untimed exact-work ${allocationReplayMode} invocation-phase Context backing allocation replay${allocationReplayContract ? ` under ${allocationReplayContract.profile_id}` : ""}`;
  }
  const lifecycle = mode === "context_lifecycle" ? parseLifecycleTelemetry(completed.stdout, workload, jobs) : undefined;
  const measuredBoundaryOccupancy = processCpuOccupancy(elapsed_ns, cpu.user_ns, cpu.system_ns);
  requireValue(measuredBoundaryOccupancy >= MINIMUM_PROCESS_CPU_OCCUPANCY, `benchmark measured-boundary CPU occupancy ${(measuredBoundaryOccupancy * 100).toFixed(1)}% is below ${(MINIMUM_PROCESS_CPU_OCCUPANCY * 100).toFixed(0)}%; transient competing work overlapped the scored invocation`);
  const processWallNs = Math.round(timeMetric(completed.stderr, "real") * 1e9), userNs = Math.round(timeMetric(completed.stderr, "user") * 1e9), systemNs = Math.round(timeMetric(completed.stderr, "sys") * 1e9), processOccupancy = processCpuOccupancy(processWallNs, userNs, systemNs);
  return { engine, mode, workload, lanes, jobs, elapsed_ns, checksum, measured_boundary_cpu_user_ns: cpu.user_ns, measured_boundary_cpu_system_ns: cpu.system_ns, measured_boundary_cpu_occupancy: measuredBoundaryOccupancy, process_wall_time_ns: processWallNs, process_cpu_user_ns: userNs, process_cpu_system_ns: systemNs, process_cpu_occupancy: processOccupancy, peak_rss_bytes: parsePeakRss(completed.stderr), retained_rss_bytes: mode === "single_observed" ? parseRetainedRss(completed.stdout, mode, workload, jobs) : lifecycle?.post_destroy_rss_bytes ?? null, allocations: allocationCounters?.[0] ?? null, allocated_bytes: allocationCounters?.[1] ?? null, allocation_source: allocationSource, allocation_replay_signature: allocationReplaySignature, instructions: counters.instructions.value, cycles: counters.cycles.value, energy_joules: counters.process_energy_nj.value / 1e9, thermal_state: `${thermal.before}->${thermal.after}`, lifecycle };
}
export function sampleRecord(row: RunnerRow, variant: string, pairSample: number, order: number, schema: any): any {
  const metrics = unavailableMetrics(schema, "instrumentation is not yet connected for this metric; absence is explicit and is not a zero");
  requireValue((row.allocations === null) === (row.allocated_bytes === null), "allocation count/byte availability drift");
  if (row.allocations !== null) requireValue(typeof row.allocation_source === "string" && row.allocation_source.length > 0, "measured allocation replay lacks provenance");
  measured(metrics, "wall_time_ns", row.elapsed_ns, "benchmark_runner.elapsed_ns");
  measured(metrics, "process_cpu_user_ns", row.process_cpu_user_ns, "/usr/bin/time -l user");
  measured(metrics, "process_cpu_system_ns", row.process_cpu_system_ns, "/usr/bin/time -l sys");
  measured(metrics, "peak_rss_bytes", row.peak_rss_bytes, "/usr/bin/time -l maximum resident set size");
  if (row.retained_rss_bytes !== null) measured(metrics, "retained_rss_bytes", row.retained_rss_bytes, "task_vm_info.resident_size at the post-invocation live snapshot");
  if (row.allocations !== null) measured(metrics, "allocations", row.allocations, `${row.allocation_source}: allocation requests`);
  if (row.allocated_bytes !== null) measured(metrics, "allocated_bytes", row.allocated_bytes, `${row.allocation_source}: cumulative bytes`);
  measured(metrics, "instructions", row.instructions, "proc_pid_rusage(RUSAGE_INFO_V6).ri_instructions delta");
  measured(metrics, "cycles", row.cycles, "proc_pid_rusage(RUSAGE_INFO_V6).ri_cycles delta");
  measured(metrics, "energy_joules", row.energy_joules, "proc_pid_rusage(RUSAGE_INFO_V6).ri_energy_nj delta / 1e9");
  metrics.thermal_state = { status: "measured", value: row.thermal_state, source: "NSProcessInfo.thermalState before->after", reason: "" };
  return { identity: { variant, pair_sample: pairSample, order, engine: row.engine, mode: row.mode, workload: row.workload, lanes: row.lanes, jobs: row.jobs, checksum: row.checksum }, quality: { measured_boundary_cpu_user_ns: row.measured_boundary_cpu_user_ns, measured_boundary_cpu_system_ns: row.measured_boundary_cpu_system_ns, measured_boundary_cpu_occupancy: row.measured_boundary_cpu_occupancy, minimum_measured_boundary_cpu_occupancy: MINIMUM_PROCESS_CPU_OCCUPANCY, process_wall_time_ns: row.process_wall_time_ns, process_cpu_occupancy: row.process_cpu_occupancy }, metrics, ...(row.allocation_replay_signature ? { allocation_replay_signature: row.allocation_replay_signature } : {}), ...(row.lifecycle ? { lifecycle: row.lifecycle } : {}) };
}
export function validateSampleQuality(samples: any[]): void {
  requireValue(samples.length > 0, "exact-parent artifact has no samples");
  for (const sample of samples) {
    const quality = sample.quality;
    requireValue(quality && Number.isFinite(quality.process_wall_time_ns) && quality.process_wall_time_ns >= 0, "exact-parent sample process wall time is invalid");
    requireValue(Number.isFinite(quality.process_cpu_occupancy) && quality.process_cpu_occupancy >= 0 && quality.process_cpu_occupancy <= 1, "exact-parent complete-process CPU occupancy is invalid");
    if ("measured_boundary_cpu_occupancy" in quality) {
      requireValue(Number.isSafeInteger(quality.measured_boundary_cpu_user_ns) && quality.measured_boundary_cpu_user_ns >= 0 && Number.isSafeInteger(quality.measured_boundary_cpu_system_ns) && quality.measured_boundary_cpu_system_ns >= 0, "exact-parent measured-boundary CPU time is invalid");
      requireValue(Number.isFinite(quality.measured_boundary_cpu_occupancy) && quality.measured_boundary_cpu_occupancy >= MINIMUM_PROCESS_CPU_OCCUPANCY && quality.measured_boundary_cpu_occupancy <= 1, "exact-parent sample measured-boundary CPU occupancy is below the publication threshold");
      requireValue(quality.minimum_measured_boundary_cpu_occupancy === MINIMUM_PROCESS_CPU_OCCUPANCY, "exact-parent measured-boundary CPU occupancy policy drift");
    } else {
      requireValue(quality.process_cpu_occupancy >= MINIMUM_PROCESS_CPU_OCCUPANCY, "exact-parent legacy sample process CPU occupancy is below the publication threshold");
      requireValue(quality.minimum_process_cpu_occupancy === MINIMUM_PROCESS_CPU_OCCUPANCY, "exact-parent legacy process CPU occupancy policy drift");
    }
  }
}
const mean = (values: number[]): number => values.reduce((sum, value) => sum + value, 0) / values.length;
const median = (values: number[]): number => { const sorted = values.slice().sort((a, b) => a - b), middle = Math.floor(sorted.length / 2); return sorted.length % 2 ? sorted[middle] : (sorted[middle - 1] + sorted[middle]) / 2; };
export function relativeStddev(values: number[]): number { if (values.length <= 1) return 0; const average = mean(values), variance = values.reduce((sum, value) => sum + (value - average) ** 2, 0) / (values.length - 1); return Math.sqrt(variance) / average; }
function measuredMetricSummary(samples: any[], name: string): any | null { if (!samples.every((sample) => sample.metrics[name]?.status === "measured")) return null; const values: any = {}; for (const variant of ["parent", "candidate"]) values[variant] = samples.filter((sample) => sample.identity.variant === variant).map((sample) => Number(sample.metrics[name].value)); const parentMedian = median(values.parent), candidateMedian = median(values.candidate); return { parent_median: parentMedian, candidate_median: candidateMedian, candidate_over_parent: candidateMedian / parentMedian, parent_rsd: relativeStddev(values.parent), candidate_rsd: relativeStddev(values.candidate) }; }
const MATERIAL_CATEGORIES = ["cpu_work", "threads", "generated_code", "cache_traffic"];
export function summarize(samples: any[], schema: any, hostClass: string, materialCategories: string[] = ["cpu_work"]): any {
  requireValue(materialCategories.length > 0 && materialCategories.every((value) => MATERIAL_CATEGORIES.includes(value)), "invalid material-change category");
  const walls: any = {}; for (const variant of ["parent", "candidate"]) walls[variant] = samples.filter((sample) => sample.identity.variant === variant).map((sample) => Number(sample.metrics.wall_time_ns.value));
  const parentMedian = median(walls.parent), candidateMedian = median(walls.candidate), ratio = candidateMedian / parentMedian, parentRsd = relativeStddev(walls.parent), candidateRsd = relativeStddev(walls.candidate), policy = schema.regression_policy;
  const stable = parentRsd <= policy.maximum_rsd && candidateRsd <= policy.maximum_rsd, gatingHost = hostClass === policy.gate_host_class, regression = ratio > policy.wall_regression_ratio, blocks = gatingHost && stable && regression;
  const efficiency: any = {};
  for (const metric of ["instructions", "cycles", "energy_joules"]) {
    const values: any = {}; for (const variant of ["parent", "candidate"]) values[variant] = samples.filter((sample) => sample.identity.variant === variant).map((sample) => Number(sample.metrics[metric].value));
    efficiency[metric] = { parent_median: median(values.parent), candidate_median: median(values.candidate), candidate_over_parent: median(values.candidate) / median(values.parent), parent_rsd: relativeStddev(values.parent), candidate_rsd: relativeStddev(values.candidate), stable: relativeStddev(values.parent) <= policy.maximum_rsd && relativeStddev(values.candidate) <= policy.maximum_rsd };
  }
  const thermalStates = [...new Set(samples.map((sample) => sample.metrics.thermal_state.value))].sort(), thermalStableNominal = thermalStates.length === 1 && thermalStates[0] === "nominal->nominal";
  const categoryMetrics: Record<string, string[]> = { cpu_work: [], threads: [], generated_code: ["generated_code_bytes"], cache_traffic: ["cache_misses"] }, unmetMetrics: string[] = [];
  for (const name of [...new Set(materialCategories.flatMap((category) => categoryMetrics[category]))]) {
    const observations = samples.map((sample) => sample.metrics[name]);
    if (!observations.every((value) => value.status === "measured") || !["parent", "candidate"].every((variant) => relativeStddev(samples.filter((sample) => sample.identity.variant === variant).map((sample) => Number(sample.metrics[name].value))) <= policy.maximum_rsd)) unmetMetrics.push(name);
  }
  const efficiencyStable = Object.values(efficiency).every((metric: any) => metric.stable) && thermalStableNominal && unmetMetrics.length === 0;
  const efficiencyBlocks = gatingHost && !efficiencyStable, blocksPublication = blocks || efficiencyBlocks;
  const status = blocks ? "blocked_regression" : efficiencyBlocks ? "blocked_efficiency_evidence" : !gatingHost ? "diagnostic_only" : !stable ? "inconclusive_noise" : regression ? "visible_non_gating_regression" : "pass";
  return { parent_wall_median_ns: parentMedian, candidate_wall_median_ns: candidateMedian, candidate_over_parent: ratio, parent_wall_rsd: parentRsd, candidate_wall_rsd: candidateRsd, stable, gating_host: gatingHost, regression, efficiency: { metrics: efficiency, thermal_states: thermalStates, required_categories: materialCategories, unmet_metrics: unmetMetrics, stable: efficiencyStable, blocks_publication: efficiencyBlocks }, blocks_publication: blocksPublication, status };
}
export function collect(parentBinary: string, candidateBinary: string, mode: string, workload: string, jobs: number, lanes: number, expectedChecksum: number, samples: number, schema: any, allocationReplayMode = "", allocationReplayContract: AllocationReplayContract | null = null): any[] {
  if (mode === "context_lifecycle") validateLifecycleCollectionRequest(workload, jobs, expectedChecksum);
  const binaries: any = { parent: parentBinary, candidate: candidateBinary }, result: any[] = [];
  for (let pairSample = 0; pairSample < samples; pairSample += 1) {
    const order = pairSample % 2 === 0 ? ["parent", "candidate"] : ["candidate", "parent"];
    order.forEach((variant, position) => {
      const row = runOne(binaries[variant], mode, workload, jobs, lanes, allocationReplayMode, allocationReplayContract);
      requireValue(row.checksum === expectedChecksum, `${variant} pair ${pairSample} checksum ${row.checksum} != frozen ${expectedChecksum}`);
      result.push(sampleRecord(row, variant, pairSample, position, schema));
    });
  }
  return result;
}
export function render(artifact: any): string {
  const metadata = artifact.metadata, summary = artifact.summary, efficiency = summary.efficiency;
  const memoryRows = ["peak_rss_bytes", "retained_rss_bytes", "allocations", "allocated_bytes"].map((metric) => [metric, measuredMetricSummary(artifact.samples, metric)] as const).filter((entry) => entry[1] !== null).map(([metric, value]) => `| \`${metric}\` | ${value.parent_median} | ${value.candidate_median} | ${value.candidate_over_parent.toFixed(4)}x | ${(value.parent_rsd * 100).toFixed(2)}% | ${(value.candidate_rsd * 100).toFixed(2)}% |`);
  const qualityBoundary = metadata.minimum_measured_boundary_cpu_occupancy !== undefined ? `every measured invocation used at least ${(metadata.minimum_measured_boundary_cpu_occupancy * 100).toFixed(0)}% CPU occupancy; complete-process occupancy remains diagnostic` : `every complete process used at least ${(metadata.minimum_process_cpu_occupancy * 100).toFixed(0)}% CPU occupancy`;
  const binaryProvenance = metadata.parent_binary_revision ? [`- parent binary revision: \`${metadata.parent_binary_revision}\``, `- candidate binary revision: \`${metadata.candidate_binary_revision}\``, `- shared measurement overlay: ${metadata.shared_measurement_overlay_paths.map((path: string) => `\`${path}\``).join(", ")}`] : [];
  const replayContract = metadata.allocation_replay_contract ? [`- allocation replay signature: \`${metadata.allocation_replay_contract.profile_id}\` from \`${metadata.allocation_replay_contract.path}\` (\`${metadata.allocation_replay_contract.sha256}\`)`] : [];
  return [
    `# Exact-parent performance A/B — ${metadata.workload} (${metadata.mode}, ${metadata.lanes} lane(s))`, "",
    `- logical parent: \`${metadata.parent_revision}\``, `- logical candidate: \`${metadata.candidate_revision}\``, ...binaryProvenance, ...replayContract,
    `- zig-gc: \`${metadata.zig_gc_revision}\``, `- zig-regex: \`${metadata.zig_regex_revision}\``, `- host class: \`${metadata.host_class}\``,
    `- material-change categories: ${efficiency.required_categories.map((value: string) => `\`${value}\``).join(", ")}`,
    `- sampling: ${metadata.samples} order-balanced pairs; no discarded samples`, `- process quality: ${qualityBoundary}; before/after snapshots reject persistent competing jobs`, `- timed boundary: ${metadata.timed_boundary}`, "",
    "| parent median | candidate median | candidate / parent | parent RSD | candidate RSD | assessment |", "| ---: | ---: | ---: | ---: | ---: | --- |",
    `| ${(summary.parent_wall_median_ns / 1e6).toFixed(3)} ms | ${(summary.candidate_wall_median_ns / 1e6).toFixed(3)} ms | ${summary.candidate_over_parent.toFixed(3)}x | ${(summary.parent_wall_rsd * 100).toFixed(2)}% | ${(summary.candidate_wall_rsd * 100).toFixed(2)}% | \`${summary.status}\` |`, "",
    "| memory/allocation metric | parent median | candidate median | candidate / parent | parent RSD | candidate RSD |", "| --- | ---: | ---: | ---: | ---: | ---: |", ...memoryRows, "",
    "| efficiency metric | parent median | candidate median | candidate / parent | parent RSD | candidate RSD |", "| --- | ---: | ---: | ---: | ---: | ---: |",
    ...["instructions", "cycles", "energy_joules"].map((metric) => { const value = efficiency.metrics[metric]; return `| \`${metric}\` | ${value.parent_median} | ${value.candidate_median} | ${value.candidate_over_parent.toFixed(4)}x | ${(value.parent_rsd * 100).toFixed(2)}% | ${(value.candidate_rsd * 100).toFixed(2)}% |`; }), "",
    `Thermal states: ${efficiency.thermal_states.map((value: string) => `\`${value}\``).join(", ")}. Unmet category metrics: ${efficiency.unmet_metrics.length ? efficiency.unmet_metrics.map((value: string) => `\`${value}\``).join(", ") : "none"}. Efficiency evidence: \`${efficiency.stable ? "stable" : "blocked_or_diagnostic"}\`.`, "",
    "All input identities and checksums matched. Missing attribution values are encoded as unavailable with a reason, never as zero.", "",
  ].join("\n");
}

function syntheticSamples(parent: number[], candidate: number[], schema: any): any[] { const result: any[] = []; parent.forEach((parentWall, pairSample) => { const walls: any = { parent: parentWall, candidate: candidate[pairSample] }, order = pairSample % 2 === 0 ? ["parent", "candidate"] : ["candidate", "parent"]; order.forEach((variant, position) => result.push(sampleRecord({ engine: "zig-js", mode: "single", workload: "representative_json", lanes: 1, jobs: 2200, elapsed_ns: walls[variant], checksum: 324952086, measured_boundary_cpu_user_ns: Math.max(0, walls[variant] - 100), measured_boundary_cpu_system_ns: 100, measured_boundary_cpu_occupancy: 1, process_wall_time_ns: walls[variant] * 10, process_cpu_user_ns: walls[variant], process_cpu_system_ns: 0, process_cpu_occupancy: 0.1, peak_rss_bytes: 10000000, retained_rss_bytes: null, allocations: null, allocated_bytes: null, allocation_source: null, allocation_replay_signature: null, instructions: 1000 + pairSample, cycles: 500 + pairSample, energy_joules: 0.2 + pairSample / 1000, thermal_state: "nominal->nominal" }, variant, pairSample, position, schema))); }); return result; }
function expectFailure(action: () => void, pattern: string): void { try { action(); } catch (error) { requireValue(String(error).includes(pattern), `expected ${pattern}, got ${String(error)}`); return; } throw new Error(`expected failure containing ${pattern}`); }
export function validateBatchRows(value: any): BatchRow[] {
  requireValue(Array.isArray(value) && value.length > 0, "exact-parent batch must contain at least one row");
  const expectedFields = ["expected_checksum", "jobs", "markdown_out", "raw_out", "workload"];
  for (const row of value) {
    requireValue(row && typeof row === "object" && !Array.isArray(row) && JSON.stringify(Object.keys(row).sort()) === JSON.stringify(expectedFields), "exact-parent batch row fields drift");
    requireValue(typeof row.workload === "string" && row.workload.length > 0 && Number.isSafeInteger(row.jobs) && row.jobs > 0 && Number.isSafeInteger(row.expected_checksum) && row.expected_checksum >= 0, "exact-parent batch row identity is invalid");
    requireValue(typeof row.raw_out === "string" && row.raw_out.endsWith(".json") && typeof row.markdown_out === "string" && row.markdown_out.endsWith(".md"), "exact-parent batch output path is invalid");
  }
  requireValue(new Set(value.map((row) => row.workload)).size === value.length, "exact-parent batch repeats a workload");
  const outputs = value.flatMap((row) => [row.raw_out, row.markdown_out]); requireValue(new Set(outputs).size === outputs.length, "exact-parent batch repeats an output path");
  return value as BatchRow[];
}
export function loadBatchRows(path: string): BatchRow[] { return validateBatchRows(JSON.parse(readText(path))); }
export function selfTest(): void {
  const schema = loadSchema(DEFAULT_SCHEMA);
  const stdout = "zig-js\tsingle\trepresentative_json\t1\t2200\t0\t60000000\t324952086\n"; requireValue(JSON.stringify(parseBenchmark(stdout, "single", "representative_json", 1, 2200)) === JSON.stringify(["zig-js", 60000000, 324952086]), "runner row parse drift"); expectFailure(() => parseBenchmark(stdout, "single", "representative_regexp", 1, 2200), "identity drift");
  const cpu = "zig-js-darwin-cpu-time\tsingle\trepresentative_json\t2200\t0\tmeasured\t57000000\t1000000\n"; requireValue(JSON.stringify(parseDarwinCpuTime(cpu, "single", "representative_json", 2200)) === '{"user_ns":57000000,"system_ns":1000000}', "measured-boundary CPU row parse drift"); expectFailure(() => parseDarwinCpuTime(cpu, "single", "representative_regexp", 2200), "identity drift"); expectFailure(() => parseDarwinCpuTime("", "single", "representative_json", 2200), "expected one Darwin CPU-time row");
  const native = "zig-js-native-observability\tsingle_observed\trepresentative_json\t2200\t0\t0\t0\t0\t0\t0\t0\t0\t0\t0\t12000000\t11000000\n"; requireValue(parseRetainedRss(native, "single_observed", "representative_json", 2200) === 11000000, "retained RSS row parse drift"); expectFailure(() => parseRetainedRss(native, "single_observed", "representative_regexp", 2200), "identity drift");
  const frontend = "zig-js-frontend-allocations\tsingle\trepresentative_frontend_numeric_separators_1024\t10\t0\t123\t456\n"; requireValue(JSON.stringify(parseFrontendAllocations(frontend, "single", "representative_frontend_numeric_separators_1024", 10)) === "[123,456]", "frontend allocation parse drift"); expectFailure(() => parseFrontendAllocations(frontend, "single", "representative_frontend_numeric_separators_2048", 10), "identity drift");
  const allocationReplay: any = { kind: "zig-js-tier-attribution", phase: "invocation", mode: "single_no_jit", workload: "representative_string_utf16_ascii_1024", lanes: 1, jobs: 10, checksum: 23880132, execution: { tree_walker_entries: 0, vm_entries: 30, vm_dispatches: 1956966, baseline_entries: 0, optimizer_entries: 0 }, admissions: { program_compiled: 16, template_plain_compiled: 5 }, baseline_publications: 0, optimizer_publications: 0, generated_code_bytes: 0, allocation: { backing_allocations: 176365, backing_allocation_bytes: 24257955 } };
  const replayText = (value: any) => JSON.stringify(value) + "\n";
  requireValue(JSON.stringify(parseNativeAllocationReplay(replayText(allocationReplay), "attribution_no_jit", allocationReplay.workload, 10, 1, allocationReplay.checksum)) === "[176365,24257955]", "native allocation replay parse drift");
  expectFailure(() => parseNativeAllocationReplay("", "attribution_no_jit", allocationReplay.workload, 10, 1, allocationReplay.checksum), "expected one native allocation invocation row");
  expectFailure(() => parseNativeAllocationReplay(replayText(allocationReplay) + replayText(allocationReplay), "attribution_no_jit", allocationReplay.workload, 10, 1, allocationReplay.checksum), "got 2");
  const wrongPhase = { ...allocationReplay, phase: "warmup" }; expectFailure(() => parseNativeAllocationReplay(replayText(wrongPhase), "attribution_no_jit", allocationReplay.workload, 10, 1, allocationReplay.checksum), "got 0");
  const wrongIdentity = { ...allocationReplay, workload: "representative_string_utf16_ascii_2048" }; expectFailure(() => parseNativeAllocationReplay(replayText(wrongIdentity), "attribution_no_jit", allocationReplay.workload, 10, 1, allocationReplay.checksum), "identity drift");
  const wrongChecksum = { ...allocationReplay, checksum: allocationReplay.checksum + 1 }; expectFailure(() => parseNativeAllocationReplay(replayText(wrongChecksum), "attribution_no_jit", allocationReplay.workload, 10, 1, allocationReplay.checksum), "checksum drift");
  const wrongTier = JSON.parse(JSON.stringify(allocationReplay)); wrongTier.execution.tree_walker_entries = 1; expectFailure(() => parseNativeAllocationReplay(replayText(wrongTier), "attribution_no_jit", allocationReplay.workload, 10, 1, allocationReplay.checksum), "tier boundary drift");
  const wrongAllocation = JSON.parse(JSON.stringify(allocationReplay)); wrongAllocation.allocation.backing_allocations = 0; expectFailure(() => parseNativeAllocationReplay(replayText(wrongAllocation), "attribution_no_jit", allocationReplay.workload, 10, 1, allocationReplay.checksum), "counters are invalid");
  const mixedSignature = { execution: { tree_walker_entries: 84, vm_entries: 2, vm_dispatches: 1932, vm_quick_kernel_hits: 200, baseline_entries: 0, optimizer_entries: 0, optimizer_osr_entries: 0, deoptimizations: 0, runtime_operation_calls: 0, host_callbacks: 0, wasm_dispatches: 0, environment_allocations: 2 }, quick_binary: { number_hits: 200, number_misses: 0, dequickenings: 0 }, admissions: { program_compiled: 1, template_plain_compiled: 0, plain_compiled: 0 }, shape: { transition_requests: 89, transition_hits: 89, transition_misses: 0, transition_lock_yields: 0 }, native_code: { live_artifacts: 1, live_bytes: 16384, retired_artifacts: 0 }, baseline_publications: 0, optimizer_publications: 0, generated_code_bytes: 16384 };
  const mixedContract = validateAllocationReplayContract({ schema_version: 1, profile_id: "zig-js-allocation-replay-signature-v1:fixture_mixed_tier", status: "frozen", owner_issue: 775, history_policy: "Fixture freezes every declared counter without changing legacy VM-only replay.", replay: { mode: "attribution", phase: "invocation", workload: "representative_intl_date_time_format_resolved_hour_cycle", lanes: 1, jobs: 100, checksum: 705814248 }, signature: mixedSignature });
  const mixedSnapshot = (phase: string, multiplier: number, checksum = 0): any => ({ kind: "zig-js-tier-attribution", phase, mode: "single", workload: mixedContract.replay.workload, lanes: 1, jobs: 100, checksum, execution: Object.fromEntries(Object.entries(mixedSignature.execution).map(([name, value]) => [name, Number(value) * multiplier])), quick_binary: Object.fromEntries(Object.entries(mixedSignature.quick_binary).map(([name, value]) => [name, Number(value) * multiplier])), admissions: Object.fromEntries(Object.entries(mixedSignature.admissions).map(([name, value]) => [name, Number(value) * multiplier])), shape: Object.fromEntries(Object.entries(mixedSignature.shape).map(([name, value]) => [name, Number(value) * multiplier])), native_code: mixedSignature.native_code, baseline_publications: 0, optimizer_publications: 0, generated_code_bytes: 16384, allocation: { backing_allocations: 1000 * multiplier, backing_allocation_bytes: 2000 * multiplier } });
  const mixedRows = [mixedSnapshot("configuration", 0), mixedSnapshot("warmup", 1), mixedSnapshot("invocation", 2, mixedContract.replay.checksum)];
  const mixedParsed = parseNativeAllocationReplay(mixedRows.map(replayText).join(""), "attribution", mixedContract.replay.workload, 100, 1, mixedContract.replay.checksum, mixedContract);
  requireValue(mixedParsed[0] === 1000 && mixedParsed[1] === 2000 && exactJson(mixedParsed[2]) === exactJson(mixedSignature), "mixed-tier allocation replay parse drift");
  for (const section of REPLAY_SIGNATURE_MAPS) for (const field of Object.keys(mixedSignature[section])) {
    const mutated = JSON.parse(JSON.stringify(mixedRows));
    mutated[2][section][field] += 1;
    expectFailure(() => parseNativeAllocationReplay(mutated.map(replayText).join(""), "attribution", mixedContract.replay.workload, 100, 1, mixedContract.replay.checksum, mixedContract), `${section} signature drift`);
  }
  for (const field of REPLAY_SIGNATURE_SCALARS) {
    const mutated = JSON.parse(JSON.stringify(mixedRows)); mutated[2][field] += 1;
    expectFailure(() => parseNativeAllocationReplay(mutated.map(replayText).join(""), "attribution", mixedContract.replay.workload, 100, 1, mixedContract.replay.checksum, mixedContract), `${field} signature drift`);
  }
  const mixedPhaseDrift = JSON.parse(JSON.stringify(mixedRows)); mixedPhaseDrift[1].phase = "configuration"; expectFailure(() => parseNativeAllocationReplay(mixedPhaseDrift.map(replayText).join(""), "attribution", mixedContract.replay.workload, 100, 1, mixedContract.replay.checksum, mixedContract), "phase inventory drift");
  const mixedAllocationDrift = JSON.parse(JSON.stringify(mixedRows)); mixedAllocationDrift[2].allocation.backing_allocations = mixedAllocationDrift[1].allocation.backing_allocations; expectFailure(() => parseNativeAllocationReplay(mixedAllocationDrift.map(replayText).join(""), "attribution", mixedContract.replay.workload, 100, 1, mixedContract.replay.checksum, mixedContract), "counters are invalid");
  const contractIdentityDrift = JSON.parse(JSON.stringify(mixedContract)); contractIdentityDrift.replay.phase = "warmup"; expectFailure(() => validateAllocationReplayContract(contractIdentityDrift), "allocation replay identity is invalid");
  const contractFieldDrift = JSON.parse(JSON.stringify(mixedContract)); contractFieldDrift.extra = true; expectFailure(() => validateAllocationReplayContract(contractFieldDrift), "contract fields drift");
  const frozenMixedContract = loadAllocationReplayContract(`${ROOT}/docs/.data/allocation-replay-signature-intl-date-time-format-hour-cycle-v1.json`);
  requireValue(frozenMixedContract.replay.checksum === 705814248 && frozenMixedContract.signature.execution.tree_walker_entries === 84001 && frozenMixedContract.signature.execution.vm_entries === 2 && frozenMixedContract.signature.shape.transition_requests === 89600, "frozen mixed-tier allocation replay contract drift");
  const batchRows = [{ workload: allocationReplay.workload, jobs: 10, expected_checksum: allocationReplay.checksum, raw_out: "docs/.data/fixture.json", markdown_out: "docs/.data/fixture.md" }]; requireValue(validateBatchRows(batchRows).length === 1, "exact-parent batch fixture drift");
  expectFailure(() => validateBatchRows([...batchRows, { ...batchRows[0], raw_out: "docs/.data/fixture-2.json", markdown_out: "docs/.data/fixture-2.md" }]), "repeats a workload");
  expectFailure(() => validateBatchRows([{ ...batchRows[0], extra: true }]), "row fields drift");
  const observedArguments = runnerArguments("single_observed", "representative_json", 2200, 1); requireValue(observedArguments[observedArguments.length - 1] === "--native-observability-telemetry", "single_observed telemetry option drift");
  requireValue(JSON.stringify(runnerArguments("single_no_jit", "representative_vm_arithmetic_number", 10000, 1)) === '["single_no_jit","representative_vm_arithmetic_number","10000","1","--darwin-rusage"]', "single_no_jit exact-parent argument drift");
  const lifecycleArguments = runnerArguments("context_lifecycle", "context_no_evaluation", 1, 1); requireValue(JSON.stringify(lifecycleArguments) === '["context_lifecycle","context_no_evaluation","1","1","--darwin-rusage"]', "context lifecycle runner arguments drift");
  const lifecycleFixture: LifecycleTelemetry = { schema_version: 1, scenario: "context_no_evaluation", context_options_profile: "gc_default", iterations: 1, sample: 0, create_ns: 10, work_ns: 0, destroy_ns: 20, phase_total_ns: 30, cpu_user_ns: 20, cpu_system_ns: 5, baseline_rss_bytes: 100_000_000, max_live_rss_bytes: 110_000_000, post_destroy_rss_bytes: 100_000_000, retained_delta_bytes: 0, peak_rss_bytes: 120_000_000, rss_checkpoints: [100_000_000, 100_000_000, 100_000_000, 100_000_000], finalizers: { cells: 1, bulk_cell_frees_skipped: 1, objects: 1, strings: 0, environments: 0, functions: 0, bound_functions: 0, promises: 0, generators: 0, iter_helpers: 0, module_namespaces: 0, object_backing_releases: 1, array_buffers: 0, shared_array_buffers: 0, promise_reactions: 0 } };
  const lifecycleProfile = loadLifecycleProfile();
  requireValue(validateLifecycleCollectionRequest("context_first_source", 8, 336, lifecycleProfile).context_options_profile === "gc_default", "lifecycle collection request drift");
  expectFailure(() => validateLifecycleCollectionRequest("context_first_source", 1, 42, lifecycleProfile), "at least 8 cold iterations");
  expectFailure(() => validateLifecycleCollectionRequest("context_first_source", 8, 42, lifecycleProfile), "checksum/profile drift");
  for (const scenario of ["context_no_evaluation", "context_first_source", "context_first_module", "context_full_feature"]) { const fixture = JSON.parse(JSON.stringify(lifecycleFixture)); fixture.scenario = scenario; fixture.context_options_profile = lifecycleProfile.scenarios.find((entry: any) => entry.id === scenario).context_options_profile; requireValue(parseLifecycleTelemetry(`zig-js-context-lifecycle\t${JSON.stringify(fixture)}\n`, scenario, 1).scenario === scenario, `${scenario} lifecycle fixture drift`); }
  const incompleteFinalizers = JSON.parse(JSON.stringify(lifecycleFixture)); incompleteFinalizers.finalizers.cells = 2; expectFailure(() => validateLifecycleTelemetry(incompleteFinalizers, lifecycleFixture.scenario, 1), "not finalized exactly once");
  const retainingSoak = JSON.parse(JSON.stringify(lifecycleFixture)); Object.assign(retainingSoak, { iterations: 16, post_destroy_rss_bytes: 130_000_000, retained_delta_bytes: 30_000_000, peak_rss_bytes: 140_000_000, max_live_rss_bytes: 140_000_000, rss_checkpoints: [100_000_000, 110_000_000, 120_000_000, 130_000_000] }); retainingSoak.finalizers.cells = 16; retainingSoak.finalizers.bulk_cell_frees_skipped = 16; retainingSoak.finalizers.objects = 16; expectFailure(() => validateLifecycleTelemetry(retainingSoak, lifecycleFixture.scenario, 16), "bounded plateau");
  const timing = "        0.13 real         0.07 user         0.02 sys\n            91750400  maximum resident set size\n"; requireValue(timeMetric(timing, "user") === 0.07 && timeMetric(timing, "sys") === 0.02 && parsePeakRss(timing) === 91750400, "macOS time layout parse drift");
  requireValue(processCpuOccupancy(130, 70, 20) === 90 / 130 && processCpuOccupancy(0, 0, 0) === 1, "process CPU occupancy drift");
  expectFailure(() => requireValue(processCpuOccupancy(100, 40, 10) >= MINIMUM_PROCESS_CPU_OCCUPANCY, "transient competing work overlapped the invocation"), "transient competing work overlapped the invocation");
  const stable = syntheticSamples([100, 101, 99, 100], [112, 113, 111, 112], schema); requireValue(summarize(stable, schema, "quiet_reference").status === "blocked_regression", "stable regression must block"); requireValue(summarize(stable, schema, "diagnostic").status === "diagnostic_only", "diagnostic host must not block"); const noisy = syntheticSamples([100, 130, 70, 100], [150, 90, 130, 110], schema); requireValue(summarize(noisy, schema, "quiet_reference").status === "inconclusive_noise", "noisy reference must be inconclusive");
  const thermalDrift = syntheticSamples([100, 101], [99, 100], schema); thermalDrift[0].metrics.thermal_state.value = "nominal->fair"; requireValue(summarize(thermalDrift, schema, "quiet_reference").status === "blocked_efficiency_evidence", "thermal drift must block reference publication"); requireValue(summarize(thermalDrift, schema, "diagnostic").status === "diagnostic_only", "thermal drift must remain diagnostic off reference hosts");
  const cacheRequired = summarize(syntheticSamples([100, 101], [99, 100], schema), schema, "quiet_reference", ["cache_traffic"]); requireValue(cacheRequired.status === "blocked_efficiency_evidence" && JSON.stringify(cacheRequired.efficiency.unmet_metrics) === '["cache_misses"]', "unavailable cache evidence must block a cache-traffic publication");
  const samples = syntheticSamples([100, 101], [99, 100], schema), metadata: any = {}; for (const field of schema.required_metadata) metadata[field] = "test"; Object.assign(metadata, { parent_revision: "a".repeat(40), candidate_revision: "b".repeat(40), candidate_first_parent: "a".repeat(40), parent_binary_revision: "c".repeat(40), candidate_binary_revision: "d".repeat(40), shared_measurement_overlay_paths: ["bench/fixture.zig"], zig_gc_revision: "e".repeat(40), zig_regex_revision: "f".repeat(40), workload_source_sha256: "1".repeat(64), parent_binary_sha256: "2".repeat(64), candidate_binary_sha256: "3".repeat(64), host_class: "diagnostic", material_change_categories: ["cpu_work"], mode: "single", workload: "representative_json", lanes: 1, jobs: 2200, expected_checksum: 324952086, samples: 2, timed_boundary: "test boundary" });
  const artifact = { schema_version: schema.schema_version, profile_id: schema.profile_id, kind: "exact_parent_ab", metadata, samples, summary: summarize(samples, schema, "diagnostic") }; validateArtifact(artifact, schema);
  const invalidBinaryRevision = JSON.parse(JSON.stringify(artifact)); invalidBinaryRevision.metadata.parent_binary_revision = "not-a-revision"; expectFailure(() => validateArtifact(invalidBinaryRevision, schema), "invalid parent_binary_revision");
  const unsafeOverlayPath = JSON.parse(JSON.stringify(artifact)); unsafeOverlayPath.metadata.shared_measurement_overlay_paths = ["../fixture.zig"]; expectFailure(() => validateArtifact(unsafeOverlayPath, schema), "overlay path is unsafe");
  validateSampleQuality(samples); const invalidQuality = JSON.parse(JSON.stringify(samples)); invalidQuality[0].quality.measured_boundary_cpu_occupancy = 0.59; expectFailure(() => validateSampleQuality(invalidQuality), "below the publication threshold");
  const directory = temporaryDirectory("zig-js-exact-parent");
  try {
    checked(["git", "init", "-q", directory], "initialize clean-worktree fixture"); checked(["git", "-C", directory, "config", "user.name", "Test"], "configure fixture name"); checked(["git", "-C", directory, "config", "user.email", "test@example.com"], "configure fixture email");
    const tracked = `${directory}/tracked.txt`, overlay = `${directory}/overlay.txt`;
    for (let commit = 0; commit < 3; commit += 1) { writeText(tracked, `fixture ${commit}\n`); checked(["git", "-C", directory, "add", "tracked.txt"], "stage fixture"); checked(["git", "-C", directory, "commit", "-qm", `fixture ${commit}`], "commit fixture"); }
    const logicalParent = resolveRevision("HEAD~2", directory), logicalCandidate = resolveRevision("HEAD~1", directory);
    requireValue(JSON.stringify(validateExactParent(logicalParent, logicalCandidate, directory)) === JSON.stringify([logicalParent, logicalCandidate]), "fixture exact parent did not validate");
    requireValue(JSON.stringify(validateDirectBinaryRevisions(logicalParent, logicalCandidate, logicalParent, logicalCandidate, directory)) === JSON.stringify([logicalParent, logicalCandidate]), "direct binary revisions did not validate");
    expectFailure(() => validateDirectBinaryRevisions(logicalParent, logicalCandidate, logicalCandidate, logicalCandidate, directory), "direct parent binary revision does not match");
    expectFailure(() => validateExactParent(logicalParent, resolveRevision("HEAD", directory), directory), "not requested exact parent");
    checked(["git", "-C", directory, "checkout", "-qb", "parent-overlay", logicalParent], "create parent overlay fixture"); writeText(overlay, "shared overlay\n"); checked(["git", "-C", directory, "add", "overlay.txt"], "stage parent overlay"); checked(["git", "-C", directory, "commit", "-qm", "parent overlay"], "commit parent overlay"); const parentOverlay = resolveRevision("HEAD", directory);
    checked(["git", "-C", directory, "checkout", "-qb", "candidate-overlay", logicalCandidate], "create candidate overlay fixture"); writeText(overlay, "shared overlay\n"); checked(["git", "-C", directory, "add", "overlay.txt"], "stage candidate overlay"); checked(["git", "-C", directory, "commit", "-qm", "candidate overlay"], "commit candidate overlay"); const candidateOverlay = resolveRevision("HEAD", directory);
    requireValue(JSON.stringify(validateSharedMeasurementOverlay(logicalParent, logicalCandidate, parentOverlay, candidateOverlay, directory, ["overlay.txt"])) === JSON.stringify([parentOverlay, candidateOverlay]), "shared measurement overlay fixture did not validate");
    checked(["git", "-C", directory, "checkout", "-qb", "candidate-drift", logicalCandidate], "create mismatched candidate overlay fixture"); writeText(overlay, "different overlay\n"); checked(["git", "-C", directory, "add", "overlay.txt"], "stage mismatched overlay"); checked(["git", "-C", directory, "commit", "-qm", "candidate overlay drift"], "commit mismatched overlay"); const candidateDrift = resolveRevision("HEAD", directory);
    expectFailure(() => validateSharedMeasurementOverlay(logicalParent, logicalCandidate, parentOverlay, candidateDrift, directory, ["overlay.txt"]), "overlay blob drift");
    requireClean(directory); writeText(tracked, "dirty\n"); expectFailure(() => requireClean(directory), "dirty tracked worktree");
  } finally { removeTemporaryDirectory(directory); }
  const processFixture = [
    "100 1 /Applications/Host/app", "110 100 /Applications/Host/codex", "120 110 /tool/home-tool run exact-parent", "121 120 /usr/bin/time runner", "122 121 /repo/zig-out/bin/frontend-parse-benchmark single row 1 1",
    "200 100 /opt/zig build test", "210 100 /cache/maker build test", "220 100 /private/tmp/home-url-final", "230 100 /tmp/home-ts-checker/o/test --listen=-", "240 100 /repo/.zig-cache/o/hash/test --listen=-", "250 100 /repo/zig-out/bin/test262 --diag test/language", "260 100 /repo/zig-out/bin/unit-test-parallel", "270 100 /repo/zig-out/bin/threads-test", "280 100 /other/frontend-parse-benchmark single row 1 1", "290 100 /usr/bin/python3 unrelated.py",
  ].join("\n");
  const expectedCompetitors = ["200 /opt/zig build test", "210 /cache/maker build test", "220 /private/tmp/home-url-final", "230 /tmp/home-ts-checker/o/test --listen=-", "240 /repo/.zig-cache/o/hash/test --listen=-", "250 /repo/zig-out/bin/test262 --diag test/language", "260 /repo/zig-out/bin/unit-test-parallel", "270 /repo/zig-out/bin/threads-test", "280 /other/frontend-parse-benchmark single row 1 1"];
  requireValue(JSON.stringify(competingEvidenceProcesses(processFixture, 120)) === JSON.stringify(expectedCompetitors), "competing evidence-process classification drift");
  expectFailure(() => requireNoCompetingEvidenceProcess("before fixture", processFixture, 120), "competing build/test process detected before fixture");
  requireNoCompetingEvidenceProcess("clean fixture", processFixture.split("\n").filter((line) => !/^(200|210|220|230|240|250|260|270|280) /.test(line)).join("\n"), 120);
  console.log("OK exact-parent self-test: identity, pairing, legacy and contracted allocation replay, serial batch, regression, cleanliness, and competing-job gates verified");
}

function publishRow(parentBinary: string, candidateBinary: string, row: BatchRow, options: any, identities: any): void {
  const replayContract: AllocationReplayContract | null = options.allocation_replay_contract_value || null;
  const samples = collect(parentBinary, candidateBinary, options.mode, row.workload, row.jobs, options.lanes, row.expected_checksum, options.samples, identities.schema, options.allocation_replay_mode || "", replayContract);
  validateSampleQuality(samples);
  if (options.allocation_replay_mode) {
    requireValue(samples.every((sample: any) => sample.metrics.allocations.status === "measured" && sample.metrics.allocated_bytes.status === "measured"), `native allocation replay evidence is incomplete at ${row.workload}`);
    for (const variant of ["parent", "candidate"]) for (const metric of ["allocations", "allocated_bytes"]) requireValue(new Set(samples.filter((sample: any) => sample.identity.variant === variant).map((sample: any) => sample.metrics[metric].value)).size === 1, `${variant} ${metric} replay is not exact at ${row.workload}`);
  }
  if (replayContract) {
    requireValue(samples.every((sample: any) => exactJson(sample.allocation_replay_signature) === exactJson(replayContract.signature)), `allocation replay signature is not exact at ${row.workload}`);
    requireValue(new Set(samples.map((sample: any) => exactJson(sample.allocation_replay_signature))).size === 1, `parent/candidate allocation replay signatures diverge at ${row.workload}`);
  }
  const metadata = {
    parent_revision: identities.parent_revision, candidate_revision: identities.candidate_revision, candidate_first_parent: identities.parent_revision,
    zig_gc_revision: identities.zig_gc_revision, zig_regex_revision: identities.zig_regex_revision, zig_version: identities.zig_version, os: identities.os, hardware: identities.hardware,
    power: commandOutput(["pmset", "-g", "batt"], "unavailable").split(/\s+/).join(" "), host_class: options.host_class, material_change_categories: identities.material_categories,
    workload_source_sha256: identities.workload_source_sha256, parent_binary_sha256: identities.parent_binary_sha256, candidate_binary_sha256: identities.candidate_binary_sha256,
    samples: options.samples, minimum_measured_boundary_cpu_occupancy: MINIMUM_PROCESS_CPU_OCCUPANCY, timed_boundary: options.timed_boundary, mode: options.mode, workload: row.workload, lanes: options.lanes, jobs: row.jobs, expected_checksum: row.expected_checksum,
    ...(options.allocation_replay_mode ? { allocation_replay_mode: options.allocation_replay_mode } : {}),
    ...(replayContract ? { allocation_replay_contract: { schema_version: replayContract.schema_version, profile_id: replayContract.profile_id, path: options.allocation_replay_contract, sha256: sha256File(options.allocation_replay_contract) } } : {}),
    ...(identities.schema.schema_version >= 3 ? { parent_binary_revision: identities.parent_binary_revision, candidate_binary_revision: identities.candidate_binary_revision, shared_measurement_overlay_paths: identities.shared_measurement_overlay_paths } : {}),
  };
  const artifact = { schema_version: identities.schema.schema_version, profile_id: identities.schema.profile_id, kind: "exact_parent_ab", metadata, samples, summary: summarize(samples, identities.schema, options.host_class, identities.material_categories) };
  validateArtifact(artifact, identities.schema);
  checked(["mkdir", "-p", row.raw_out.slice(0, row.raw_out.lastIndexOf("/")) || ".", row.markdown_out.slice(0, row.markdown_out.lastIndexOf("/")) || "."], "create exact-parent output directories");
  writeText(row.raw_out, JSON.stringify(artifact, null, 2) + "\n"); writeText(row.markdown_out, render(artifact));
  console.log(`OK exact-parent row ${row.workload}: ${row.raw_out}`);
  if (artifact.summary.blocks_publication) throw new Error(`reference-host publication blocked: ${artifact.summary.status}`);
}

function main(): void {
  const raw = process.argv.slice(2); if (raw.length === 1 && raw[0] === "--self-test") { selfTest(); return; }
  const positional: string[] = [], options: any = { candidate_revision: "HEAD", lanes: 1, samples: 7, host_class: "diagnostic", schema: DEFAULT_SCHEMA };
  const names: any = { "--parent-revision": "parent_revision", "--candidate-revision": "candidate_revision", "--parent-binary-revision": "parent_binary_revision", "--candidate-binary-revision": "candidate_binary_revision", "--source": "source", "--mode": "mode", "--workload": "workload", "--jobs": "jobs", "--lanes": "lanes", "--expected-checksum": "expected_checksum", "--samples": "samples", "--host-class": "host_class", "--material-change": "material_change", "--timed-boundary": "timed_boundary", "--allocation-replay-mode": "allocation_replay_mode", "--allocation-replay-contract": "allocation_replay_contract", "--batch": "batch", "--schema": "schema", "--raw-out": "raw_out", "--markdown-out": "markdown_out" };
  for (let index = 0; index < raw.length; index += 1) { if (!raw[index].startsWith("--")) positional.push(raw[index]); else { requireValue(names[raw[index]] && index + 1 < raw.length, `unknown or incomplete argument: ${raw[index]}`); const key = names[raw[index]], value = raw[++index]; options[key] = ["jobs", "lanes", "expected_checksum", "samples"].includes(key) ? Number(value) : value; } }
  requireValue(positional.length === 2, "usage: exact-parent-regression.ts PARENT_RUNNER CANDIDATE_RUNNER [options]");
  for (const field of ["parent_revision", "source", "mode", "timed_boundary"]) requireValue(options[field] !== undefined, `missing required option: ${field}`);
  const singleFields = ["workload", "jobs", "expected_checksum", "raw_out", "markdown_out"], batchMode = options.batch !== undefined;
  if (batchMode) for (const field of singleFields) requireValue(options[field] === undefined, `--batch cannot be combined with --${field.replaceAll("_", "-")}`); else for (const field of singleFields) requireValue(options[field] !== undefined, `missing required option: ${field}`);
  requireValue(Number.isSafeInteger(options.samples) && options.samples >= 2 && Number.isSafeInteger(options.lanes) && options.lanes > 0, "samples must be >=2 and lanes must be positive");
  for (const path of [positional[0], positional[1], options.source, ...(batchMode ? [options.batch] : []), ...(options.allocation_replay_contract ? [options.allocation_replay_contract] : [])]) requireValue(Home.fileExists(path), `input does not exist: ${path}`);
  if (options.allocation_replay_mode) requireValue((options.mode === "single" && options.allocation_replay_mode === "attribution") || (options.mode === "single_no_jit" && options.allocation_replay_mode === "attribution_no_jit"), "native allocation replay does not match the timed mode");
  requireValue(!options.allocation_replay_contract || (options.allocation_replay_mode && !batchMode), "allocation replay contract requires a single-row native allocation replay");
  const rows = batchMode ? loadBatchRows(options.batch) : validateBatchRows([{ workload: options.workload, jobs: options.jobs, expected_checksum: options.expected_checksum, raw_out: options.raw_out, markdown_out: options.markdown_out }]);
  if (options.allocation_replay_contract) {
    requireValue(!options.allocation_replay_contract.startsWith("/") && !options.allocation_replay_contract.split("/").includes(".."), "allocation replay contract path is unsafe");
    const contract = loadAllocationReplayContract(options.allocation_replay_contract), row = rows[0];
    requireValue(contract.replay.mode === options.allocation_replay_mode && contract.replay.workload === row.workload && contract.replay.jobs === row.jobs && contract.replay.lanes === options.lanes && contract.replay.checksum === row.expected_checksum, "allocation replay contract does not match the requested row");
    options.allocation_replay_contract_value = contract;
  }
  for (const row of rows) for (const output of [row.raw_out, row.markdown_out]) requireValue(!Home.fileExists(output), `refusing to overwrite exact-parent artifact: ${output}`);
  const materialCategories = options.material_change ? String(options.material_change).split(",").filter(Boolean) : ["cpu_work", ...(["independent_steady", "independent_cold", "shared"].includes(options.mode) ? ["threads"] : [])];
  requireValue(materialCategories.length > 0 && materialCategories.every((value: string) => MATERIAL_CATEGORIES.includes(value)) && new Set(materialCategories).size === materialCategories.length, `material-change categories must be unique values from ${MATERIAL_CATEGORIES.join(",")}`);
  const schema = loadSchema(options.schema), [parentRevision, candidateRevision] = validateExactParent(options.parent_revision, options.candidate_revision);
  const binaryOptionsPresent = options.parent_binary_revision !== undefined || options.candidate_binary_revision !== undefined;
  requireValue(!binaryOptionsPresent || (options.parent_binary_revision !== undefined && options.candidate_binary_revision !== undefined), "parent and candidate binary revisions must be provided together");
  let parentBinaryRevision: string | undefined, candidateBinaryRevision: string | undefined, sharedMeasurementOverlayPaths: string[] | undefined;
  if (schema.schema_version >= 3) {
    requireValue(binaryOptionsPresent, "schema v3 requires parent and candidate binary revisions");
    [parentBinaryRevision, candidateBinaryRevision] = validateSharedMeasurementOverlay(parentRevision, candidateRevision, options.parent_binary_revision, options.candidate_binary_revision);
    sharedMeasurementOverlayPaths = SHARED_MEASUREMENT_OVERLAY_PATHS;
  } else if (binaryOptionsPresent) {
    [parentBinaryRevision, candidateBinaryRevision] = validateDirectBinaryRevisions(parentRevision, candidateRevision, options.parent_binary_revision, options.candidate_binary_revision);
  }
  for (const repository of [ROOT, `${ROOT}/../zig-gc`, `${ROOT}/../zig-regex`]) requireClean(repository);
  const identities = { schema, parent_revision: parentRevision, candidate_revision: candidateRevision, parent_binary_revision: parentBinaryRevision, candidate_binary_revision: candidateBinaryRevision, shared_measurement_overlay_paths: sharedMeasurementOverlayPaths, zig_gc_revision: repositoryRevision(`${ROOT}/../zig-gc`), zig_regex_revision: repositoryRevision(`${ROOT}/../zig-regex`), zig_version: commandOutput(["zig", "version"]), os: commandOutput(["uname", "-a"]), hardware: `${commandOutput(["uname", "-m"])}; ${commandOutput(["sysctl", "-n", "machdep.cpu.brand_string"])}`, material_categories: materialCategories, workload_source_sha256: sha256File(options.source), parent_binary_sha256: sha256File(positional[0]), candidate_binary_sha256: sha256File(positional[1]) };
  for (const row of rows) publishRow(positional[0], positional[1], row, options, identities);
  if (batchMode) console.log(`OK exact-parent batch: ${rows.length}/${rows.length} rows published serially`);
}
if (process.argv[1] === __filename) main();
