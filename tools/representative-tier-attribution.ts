/** Collect the opt-in tier sidecar for the versioned representative matrix. */
import {
  commandOutput,
  ensurePublishable,
  metadata,
} from "./benchmark-comparison";
import {
  DEFAULT_MANIFEST,
  loadManifest,
  validate as validateManifest,
} from "./representative-matrix";
import { fileExists, readText, run, writeText } from "./lib/home";

declare const __filename: string;

export type CounterMap = Record<string, number>;
export type ProcessResourceSnapshot = {
  cpu_user_ns: number;
  cpu_system_ns: number;
  peak_rss_bytes: number;
  retained_rss_bytes: number;
};
export type TierSnapshot = {
  kind: "zig-js-tier-attribution";
  mode: "single" | "shared" | "module_cold";
  workload: string;
  lanes: number;
  jobs: number;
  phase: "configuration" | "warmup" | "invocation";
  checksum: number;
  execution: CounterMap;
  timing: CounterMap;
  admissions: CounterMap;
  synchronization: CounterMap;
  debug_registry: CounterMap;
  allocation: CounterMap;
  cell_slab_lock: CounterMap;
  gc_pauses: GcPauseSamples;
  baseline_publications: number;
  optimizer_publications: number;
  generated_code_bytes: number;
  native_code: CounterMap;
  heap: CounterMap;
  process: ProcessResourceSnapshot;
};
export type TierDelta = {
  mode: TierSnapshot["mode"];
  workload: string;
  lanes: number;
  jobs: number;
  phase: TierSnapshot["phase"];
  checksum: number;
  execution: CounterMap;
  timing: CounterMap;
  admissions: CounterMap;
  synchronization: CounterMap;
  debug_registry: CounterMap;
  allocation: CounterMap;
  cell_slab_lock: CounterMap;
  gc_pauses: GcPauseSamples;
  baseline_publications: number;
  optimizer_publications: number;
  generated_code_bytes: number;
  native_code: CounterMap;
  heap: CounterMap;
  process: ProcessResourceSnapshot;
};
type CollectionSegment = {
  first_snapshot: number;
  snapshot_count: number;
  environment: Record<string, string>;
};

type GcPauseSamples = {
  minor_ns: number[];
  minor_overflow: number;
  full_ns: number[];
  full_overflow: number;
};

const phases: TierSnapshot["phase"][] = [
  "configuration",
  "warmup",
  "invocation",
];
const tierMetrics = [
  "tree_walker_entries",
  "vm_entries",
  "baseline_entries",
  "optimizer_entries",
  "optimizer_osr_entries",
  "deoptimizations",
];
const runtimeMetrics = [
  "vm_dispatches",
  "vm_quick_kernel_hits",
  "runtime_operation_calls",
  "host_callbacks",
  "wasm_dispatches",
];
const timingMetrics = [
  "baseline_attempts",
  "baseline_tier_ups",
  "baseline_tier_up_ns",
  "baseline_tier_up_ns_max",
  "baseline_failures",
  "baseline_failure_ns",
  "baseline_failure_ns_max",
  "optimizer_attempts",
  "optimizer_tier_ups",
  "optimizer_tier_up_ns",
  "optimizer_tier_up_ns_max",
  "optimizer_failures",
  "optimizer_failure_ns",
  "optimizer_failure_ns_max",
  "deoptimizations",
  "deoptimization_ns",
  "deoptimization_ns_max",
];
const synchronizationMetrics = [
  "thread_join_parks",
  "lock_contentions",
  "lock_wait_parks",
  "async_hold_queued",
  "condition_async_waits",
  "condition_async_settled",
  "condition_waits",
  "condition_wait_parks",
  "property_waits",
  "property_wait_parks",
  "property_wait_async_enqueued",
  "property_wait_async_settled",
  "task_pump_empty",
  "task_pump_jobs",
  "task_pump_async_hold_jobs",
  "task_pump_condition_jobs",
  "condition_queue_grows",
  "condition_queue_compactions",
  "worker_channel_pushes",
  "worker_channel_pops",
  "worker_channel_empty_pops",
  "worker_channel_closes",
  "arena_lock_acquires",
  "arena_lock_contentions",
  "arena_lock_spins",
  "env_lock_acquires",
  "env_lock_contentions",
  "env_lock_spins",
  "env_read_lock_acquires",
  "env_read_root_lock_acquires",
  "env_read_captured_lock_acquires",
  "env_read_other_lock_acquires",
  "env_write_lock_acquires",
  "env_write_private_lock_acquires",
  "env_write_root_lock_acquires",
  "env_write_captured_lock_acquires",
  "env_write_other_lock_acquires",
  "env_write_private_elisions",
  "env_trace_lock_acquires",
  "object_backing_lock_acquires",
  "object_backing_lock_contentions",
  "object_backing_lock_spins",
  "object_property_lock_acquires",
  "object_property_lock_contentions",
  "object_property_lock_spins",
  "object_property_named_snapshot_acquires",
  "object_property_receiver_set_acquires",
  "object_property_named_delete_acquires",
  "object_property_other_acquires",
  "object_element_lock_acquires",
  "object_element_lock_contentions",
  "object_element_lock_spins",
  "worker_runs",
  "worker_run_ns",
  "worker_run_ns_max",
  "thread_join_wait_ns",
  "lock_wait_ns",
  "condition_wait_ns",
  "property_wait_ns",
];
const allocationMetrics = [
  "backing_allocations",
  "backing_allocation_bytes",
  "backing_growths",
  "backing_growth_bytes",
  "backing_releases",
  "backing_released_bytes",
  "backing_current_bytes",
  "backing_peak_bytes",
  "gc_cell_allocations",
  "gc_cell_bytes",
  "gc_cell_fresh_allocations",
  "gc_cell_reused_allocations",
  "gc_cell_relocation_allocations",
  "gc_cell_delegated_allocations",
  "gc_cell_frees",
  "gc_cell_freed_bytes",
];
const cellSlabLockMetrics = [
  "acquires",
  "contentions",
  "spins",
  "single_allocation_acquires",
  "batch_allocation_acquires",
  "publication_acquires",
  "unpublication_acquires",
  "free_acquires",
  "ownership_acquires",
  "relocation_acquires",
  "maintenance_acquires",
  "ownership_exact_allocation_acquires",
  "ownership_stable_identity_acquires",
  "ownership_conservative_interior_acquires",
  "ownership_realm_lookup_acquires",
  "ownership_realm_scan_acquires",
  "ownership_allocator_resize_acquires",
  "ownership_allocator_remap_acquires",
  "size_64_acquires",
  "size_64_contentions",
  "size_64_spins",
  "size_128_acquires",
  "size_128_contentions",
  "size_128_spins",
  "size_256_acquires",
  "size_256_contentions",
  "size_256_spins",
  "size_512_acquires",
  "size_512_contentions",
  "size_512_spins",
  "size_1024_acquires",
  "size_1024_contentions",
  "size_1024_spins",
  "size_2048_acquires",
  "size_2048_contentions",
  "size_2048_spins",
];
const cellSlabSizes = [64, 128, 256, 512, 1024, 2048];
const cellSlabPurposeMetrics = [
  "single_allocation_acquires",
  "batch_allocation_acquires",
  "publication_acquires",
  "unpublication_acquires",
  "free_acquires",
  "ownership_acquires",
  "relocation_acquires",
  "maintenance_acquires",
];
const cellSlabOwnershipPurposeMetrics = [
  "ownership_exact_allocation_acquires",
  "ownership_stable_identity_acquires",
  "ownership_conservative_interior_acquires",
  "ownership_realm_lookup_acquires",
  "ownership_realm_scan_acquires",
  "ownership_allocator_resize_acquires",
  "ownership_allocator_remap_acquires",
];
const debugRegistryMetrics = [
  "location_cache_hits",
  "location_cache_misses",
  "lock_acquires",
  "lock_contentions",
  "lock_spins",
];
const nativeCodeMetrics = [
  "live_artifacts",
  "live_bytes",
  "retired_artifacts",
  "retired_bytes_current",
  "reclaimed_artifacts",
  "reclaimed_bytes_total",
  "shape_invalidation_events",
  "shape_retired_artifacts",
  "shape_survivor_artifacts",
  "shape_retired_bytes",
  "full_invalidation_events",
  "unknown_shape_invalidation_events",
  "shape_fallback_events",
];
const heapMetrics = [
  "live_bytes",
  "last_full_collection_bytes",
  "collections",
  "full_collections",
];
const processMetrics = [
  "cpu_user_ns",
  "cpu_system_ns",
  "peak_rss_bytes",
  "retained_rss_bytes",
];

function requireValue(condition: boolean, message: string): void {
  if (!condition) throw new Error(message);
}

function workloadEntries(manifest: any): any[] {
  const result: any[] = [];
  for (const family of manifest.implemented_families) {
    const singleMode = family.availability?.attribution_mode === "module_attribution"
      ? "module_cold"
      : "single";
    for (const role of ["base", "variant"]) {
      result.push({
        owner: family,
        ownerKind: "family",
        role,
        workload: family[role],
        mode: singleMode,
        runnerMode: family.availability?.attribution_mode || "attribution",
        lanes: 1,
      });
    }
  }
  for (const panel of manifest.additional_panels || []) {
    result.push({
      owner: panel,
      ownerKind: "panel",
      role: "panel",
      workload: panel.workload,
      mode: "single",
      runnerMode: "attribution",
      lanes: 1,
    });
  }
  for (const family of manifest.implemented_families) {
    if (family.shared === false) continue;
    for (const role of ["base", "variant"]) for (const lanes of manifest.lanes) {
      result.push({
        owner: family,
        ownerKind: "family",
        role,
        workload: family[role],
        mode: "shared",
        runnerMode: "shared_attribution",
        lanes,
      });
    }
  }
  for (const panel of manifest.additional_panels || []) {
    if (!(panel.modes || []).includes("shared")) continue;
    for (const lanes of manifest.lanes) result.push({
      owner: panel,
      ownerKind: "panel",
      role: "panel",
      workload: panel.workload,
      mode: "shared",
      runnerMode: "shared_attribution",
      lanes,
    });
  }
  return result;
}

const jobsFor = (family: any, quick: boolean): number =>
  family.jobs[quick ? "quick" : "full"];

export function parseSnapshots(output: string): TierSnapshot[] {
  return output
    .split("\n")
    .filter((line) => line.trim())
    .map((line) => {
      const row = JSON.parse(line);
      requireValue(
        row.kind === "zig-js-tier-attribution",
        `unexpected attribution row: ${line}`,
      );
      return row as TierSnapshot;
    });
}

export function collect(
  runner: string,
  manifest: any,
  quick: boolean,
  initialRows: TierSnapshot[] = [],
  checkpoint?: (rows: TierSnapshot[]) => void,
): TierSnapshot[] {
  const entries = workloadEntries(manifest),
    rows: TierSnapshot[] = initialRows.slice();
  validateRows(rows, manifest, quick, false);
  const completedEntries = rows.length / phases.length;
  for (let entryIndex = completedEntries; entryIndex < entries.length; entryIndex += 1) {
    const entry = entries[entryIndex];
    const jobs = jobsFor(entry.owner, quick);
    const command = [
      "env",
      "LC_ALL=C",
      runner,
      entry.runnerMode,
      entry.workload,
      String(jobs),
      "1",
    ];
    if (entry.runnerMode === "shared_attribution") command.push(String(entry.lanes));
    console.error(`+ ${command.join(" ")}`);
    const completed = run(command);
    if (completed.stderr) process.stderr.write(completed.stderr);
    requireValue(
      completed.exitCode === 0,
      completed.stderr || `attribution runner exited ${completed.exitCode}`,
    );
    const result = parseSnapshots(completed.stdout);
    requireValue(result.length === phases.length, `incomplete runner result for ${entry.workload}`);
    rows.push(...result);
    validateRows(rows, manifest, quick, false);
    if (checkpoint) checkpoint(rows);
  }
  return rows;
}

function subtractMap(after: CounterMap, before: CounterMap): CounterMap {
  const result: CounterMap = {};
  const names = [...new Set(Object.keys(after).concat(Object.keys(before)))];
  for (const name of names) {
    const current = after[name] || 0,
      previous = before[name] || 0;
    requireValue(current >= previous, `${name} attribution counter regressed`);
    result[name] = current - previous;
  }
  return result;
}

function subtractSynchronization(after: CounterMap, before: CounterMap): CounterMap {
  const result = subtractMap(after, before);
  // Maxima are cumulative gauges, not additive counters. Preserve the exact
  // phase-boundary gauge instead of manufacturing a difference of maxima.
  result.worker_run_ns_max = after.worker_run_ns_max || 0;
  return result;
}

function subtractTiming(after: CounterMap, before: CounterMap): CounterMap {
  const result: CounterMap = {};
  for (const name of timingMetrics) {
    const current = after[name] || 0,
      previous = before[name] || 0;
    if (name.endsWith("_max")) {
      result[name] = current;
      continue;
    }
    requireValue(current >= previous, `${name} timing counter regressed`);
    result[name] = current - previous;
  }
  return result;
}

function subtractAllocation(after: CounterMap, before: CounterMap): CounterMap {
  const result: CounterMap = {};
  for (const name of allocationMetrics) {
    const current = after[name] || 0,
      previous = before[name] || 0;
    if (name === "backing_current_bytes" || name === "backing_peak_bytes") {
      result[name] = current;
      continue;
    }
    requireValue(current >= previous, `${name} attribution counter regressed`);
    result[name] = current - previous;
  }
  return result;
}

function subtractPauses(after: GcPauseSamples, before: GcPauseSamples): GcPauseSamples {
  requireValue(
    before.minor_ns.every((value, index) => after.minor_ns[index] === value) &&
      before.full_ns.every((value, index) => after.full_ns[index] === value) &&
      after.minor_overflow >= before.minor_overflow &&
      after.full_overflow >= before.full_overflow,
    "GC pause samples are not append-only",
  );
  return {
    minor_ns: after.minor_ns.slice(before.minor_ns.length),
    minor_overflow: after.minor_overflow - before.minor_overflow,
    full_ns: after.full_ns.slice(before.full_ns.length),
    full_overflow: after.full_overflow - before.full_overflow,
  };
}

function subtractProcess(
  after: ProcessResourceSnapshot,
  before: ProcessResourceSnapshot,
): ProcessResourceSnapshot {
  requireValue(
    after.cpu_user_ns >= before.cpu_user_ns &&
      after.cpu_system_ns >= before.cpu_system_ns &&
      after.peak_rss_bytes >= before.peak_rss_bytes,
    "process resource counter regressed",
  );
  return {
    cpu_user_ns: after.cpu_user_ns - before.cpu_user_ns,
    cpu_system_ns: after.cpu_system_ns - before.cpu_system_ns,
    peak_rss_bytes: after.peak_rss_bytes,
    retained_rss_bytes: after.retained_rss_bytes,
  };
}

function emptySnapshot(row: TierSnapshot): TierSnapshot {
  return {
    ...row,
    checksum: 0,
    execution: Object.fromEntries(
      Object.keys(row.execution).map((name) => [name, 0]),
    ),
    timing: Object.fromEntries(timingMetrics.map((name) => [name, 0])),
    admissions: Object.fromEntries(
      Object.keys(row.admissions).map((name) => [name, 0]),
    ),
    synchronization: Object.fromEntries(
      synchronizationMetrics.map((name) => [name, 0]),
    ),
    debug_registry: Object.fromEntries(
      debugRegistryMetrics.map((name) => [name, 0]),
    ),
    allocation: Object.fromEntries(allocationMetrics.map((name) => [name, 0])),
    cell_slab_lock: Object.fromEntries(cellSlabLockMetrics.map((name) => [name, 0])),
    gc_pauses: { minor_ns: [], minor_overflow: 0, full_ns: [], full_overflow: 0 },
    baseline_publications: 0,
    optimizer_publications: 0,
    generated_code_bytes: 0,
    native_code: Object.fromEntries(nativeCodeMetrics.map((name) => [name, 0])),
    heap: Object.fromEntries(heapMetrics.map((name) => [name, 0])),
    process: Object.fromEntries(processMetrics.map((name) => [name, 0])) as ProcessResourceSnapshot,
  };
}

export function deltas(rows: TierSnapshot[]): TierDelta[] {
  const result: TierDelta[] = [];
  for (let index = 0; index < rows.length; index += phases.length) {
    const group = rows.slice(index, index + phases.length);
    requireValue(group.length === phases.length, "incomplete attribution phase group");
    let before = emptySnapshot(group[0]);
    for (const row of group) {
      requireValue(
        row.mode === group[0].mode && row.workload === group[0].workload &&
          row.lanes === group[0].lanes && row.jobs === group[0].jobs,
        "attribution phase identity drift",
      );
      result.push({
        mode: row.mode,
        workload: row.workload,
        lanes: row.lanes,
        jobs: row.jobs,
        phase: row.phase,
        checksum: row.checksum,
        execution: subtractMap(row.execution, before.execution),
        timing: subtractTiming(row.timing, before.timing),
        admissions: subtractMap(row.admissions, before.admissions),
        synchronization: subtractSynchronization(row.synchronization, before.synchronization),
        debug_registry: subtractMap(row.debug_registry, before.debug_registry),
        allocation: subtractAllocation(row.allocation, before.allocation),
        cell_slab_lock: subtractMap(row.cell_slab_lock, before.cell_slab_lock),
        gc_pauses: subtractPauses(row.gc_pauses, before.gc_pauses),
        baseline_publications:
          row.baseline_publications - before.baseline_publications,
        optimizer_publications:
          row.optimizer_publications - before.optimizer_publications,
        generated_code_bytes: row.generated_code_bytes,
        native_code: row.native_code,
        heap: row.heap,
        process: subtractProcess(row.process, before.process),
      });
      requireValue(
        row.baseline_publications >= before.baseline_publications &&
          row.optimizer_publications >= before.optimizer_publications,
        "native publication counter regressed",
      );
      before = row;
    }
  }
  return result;
}

function signature(row: TierDelta): string {
  return tierMetrics
    .filter((name) => (row.execution[name] || 0) > 0)
    .join("+");
}

function entryChecksum(entry: any, manifest: any, quick: boolean): number {
  const scale = quick ? "quick" : "full",
    lane = manifest.lanes.indexOf(entry.lanes);
  requireValue(lane >= 0, `unknown lane count ${entry.lanes}`);
  return entry.ownerKind === "family"
    ? entry.owner.checksums[entry.role][scale][lane]
    : entry.owner.checksums[scale][lane];
}

const deltaKey = (workload: string, mode: string, lanes: number): string =>
  `${workload}\u0000${mode}\u0000${lanes}`;

function validateRows(
  rows: TierSnapshot[],
  manifest: any,
  quick: boolean,
  complete: boolean,
): TierDelta[] {
  const entries = workloadEntries(manifest);
  requireValue(
    rows.length % phases.length === 0 && rows.length <= entries.length * phases.length &&
      (!complete || rows.length === entries.length * phases.length),
    `attribution row count ${rows.length} does not match a valid ${entries.length * phases.length}-row prefix`,
  );
  const completedEntries = rows.length / phases.length;
  for (let index = 0; index < completedEntries; index += 1) {
    const entry = entries[index],
      group = rows.slice(index * phases.length, (index + 1) * phases.length),
      jobs = jobsFor(entry.owner, quick),
      workload = entry.workload;
    group.forEach((row, phaseIndex) => {
      requireValue(row.mode === entry.mode, `unexpected mode for ${workload}`);
      requireValue(row.workload === workload, `unexpected workload ${row.workload}`);
      requireValue(row.lanes === entry.lanes, `unexpected lanes for ${workload}`);
      requireValue(row.jobs === jobs, `unexpected jobs for ${workload}`);
      requireValue(row.phase === phases[phaseIndex], `unexpected phase for ${workload}`);
      requireValue(
        Number.isInteger(row.checksum) &&
          Object.values(row.execution).every(Number.isInteger) &&
          Object.values(row.timing).every(Number.isInteger) &&
          Object.values(row.admissions).every(Number.isInteger) &&
          Object.values(row.synchronization).every(Number.isInteger) &&
          Object.values(row.debug_registry).every(Number.isInteger) &&
          Object.values(row.allocation).every(Number.isInteger) &&
          row.gc_pauses.minor_ns.every(Number.isInteger) &&
          row.gc_pauses.full_ns.every(Number.isInteger) &&
          Number.isInteger(row.gc_pauses.minor_overflow) &&
          Number.isInteger(row.gc_pauses.full_overflow) &&
          Object.values(row.native_code).every(Number.isInteger) &&
          Object.values(row.heap).every(Number.isInteger) &&
          Object.values(row.process).every(Number.isInteger),
        `non-integral attribution for ${workload}`,
      );
      requireValue(
        JSON.stringify(Object.keys(row.execution).sort()) ===
          JSON.stringify([...tierMetrics, ...runtimeMetrics, "environment_allocations"].sort()),
        `execution attribution inventory drift for ${workload}`,
      );
      requireValue(
        JSON.stringify(Object.keys(row.timing).sort()) ===
          JSON.stringify([...timingMetrics].sort()),
        `tier timing inventory drift for ${workload}`,
      );
      requireValue(
        row.timing.baseline_attempts === row.timing.baseline_tier_ups + row.timing.baseline_failures &&
          row.timing.optimizer_attempts === row.timing.optimizer_tier_ups + row.timing.optimizer_failures &&
          row.timing.baseline_tier_ups === row.baseline_publications &&
          row.timing.optimizer_tier_ups === row.optimizer_publications &&
          row.timing.deoptimizations === row.execution.deoptimizations &&
          row.timing.baseline_tier_up_ns >= row.timing.baseline_tier_up_ns_max &&
          row.timing.baseline_failure_ns >= row.timing.baseline_failure_ns_max &&
          row.timing.optimizer_tier_up_ns >= row.timing.optimizer_tier_up_ns_max &&
          row.timing.optimizer_failure_ns >= row.timing.optimizer_failure_ns_max &&
          row.timing.deoptimization_ns >= row.timing.deoptimization_ns_max,
        `tier timing attribution is incoherent for ${workload}`,
      );
      requireValue(
        JSON.stringify(Object.keys(row.synchronization).sort()) ===
          JSON.stringify([...synchronizationMetrics].sort()),
        `synchronization attribution inventory drift for ${workload}`,
      );
      requireValue(
        JSON.stringify(Object.keys(row.debug_registry).sort()) ===
          JSON.stringify([...debugRegistryMetrics].sort()),
        `debug registry attribution inventory drift for ${workload}`,
      );
      requireValue(
        JSON.stringify(Object.keys(row.allocation).sort()) ===
          JSON.stringify([...allocationMetrics].sort()),
        `allocation attribution inventory drift for ${workload}`,
      );
      requireValue(
        JSON.stringify(Object.keys(row.cell_slab_lock).sort()) ===
          JSON.stringify([...cellSlabLockMetrics].sort()),
        `cell slab lock attribution inventory drift for ${workload}`,
      );
      requireValue(
        JSON.stringify(Object.keys(row.heap).sort()) ===
          JSON.stringify([...heapMetrics].sort()),
        `heap attribution inventory drift for ${workload}`,
      );
      requireValue(
        JSON.stringify(Object.keys(row.process).sort()) ===
          JSON.stringify([...processMetrics].sort()),
        `process resource inventory drift for ${workload}`,
      );
      requireValue(
        row.process.cpu_user_ns >= 0 && row.process.cpu_system_ns >= 0 &&
          row.process.peak_rss_bytes > 0 && row.process.retained_rss_bytes > 0 &&
          row.process.peak_rss_bytes >= row.process.retained_rss_bytes,
        `process resource attribution is incoherent for ${workload}`,
      );
      requireValue(
        row.allocation.backing_allocation_bytes + row.allocation.backing_growth_bytes >=
          row.allocation.backing_released_bytes &&
          row.allocation.backing_current_bytes ===
            row.allocation.backing_allocation_bytes + row.allocation.backing_growth_bytes -
              row.allocation.backing_released_bytes &&
          row.allocation.backing_peak_bytes >= row.allocation.backing_current_bytes &&
          row.allocation.gc_cell_allocations ===
            row.allocation.gc_cell_fresh_allocations + row.allocation.gc_cell_reused_allocations +
              row.allocation.gc_cell_relocation_allocations + row.allocation.gc_cell_delegated_allocations &&
          row.allocation.gc_cell_bytes >= row.allocation.gc_cell_freed_bytes,
        `allocation attribution is incoherent for ${workload}`,
      );
      const sizeAcquires = cellSlabSizes.reduce(
          (sum, size) => sum + row.cell_slab_lock[`size_${size}_acquires`],
          0,
        ),
        sizeContentions = cellSlabSizes.reduce(
          (sum, size) => sum + row.cell_slab_lock[`size_${size}_contentions`],
          0,
        ),
        sizeSpins = cellSlabSizes.reduce(
          (sum, size) => sum + row.cell_slab_lock[`size_${size}_spins`],
          0,
        ),
        purposeAcquires = cellSlabPurposeMetrics.reduce(
          (sum, name) => sum + row.cell_slab_lock[name],
          0,
        ),
        ownershipAcquires = cellSlabOwnershipPurposeMetrics.reduce(
          (sum, name) => sum + row.cell_slab_lock[name],
          0,
        );
      requireValue(
        row.cell_slab_lock.acquires === sizeAcquires &&
          row.cell_slab_lock.acquires === purposeAcquires &&
          row.cell_slab_lock.ownership_acquires === ownershipAcquires &&
          row.cell_slab_lock.contentions === sizeContentions &&
          row.cell_slab_lock.spins === sizeSpins &&
          row.cell_slab_lock.acquires >= row.cell_slab_lock.contentions &&
          row.cell_slab_lock.spins >= row.cell_slab_lock.contentions &&
          cellSlabSizes.every((size) =>
            row.cell_slab_lock[`size_${size}_acquires`] >=
              row.cell_slab_lock[`size_${size}_contentions`] &&
            row.cell_slab_lock[`size_${size}_spins`] >=
              row.cell_slab_lock[`size_${size}_contentions`]
          ),
        `cell slab lock attribution is incoherent for ${workload}`,
      );
      requireValue(
        row.gc_pauses.minor_overflow === 0 && row.gc_pauses.full_overflow === 0 &&
          row.gc_pauses.minor_ns.every((value) => value >= 0) &&
          row.gc_pauses.full_ns.every((value) => value >= 0) &&
          row.gc_pauses.full_ns.length === row.heap.full_collections &&
          row.gc_pauses.minor_ns.length === row.heap.collections - row.heap.full_collections,
        `GC pause attribution is incomplete for ${workload}`,
      );
      requireValue(
        row.synchronization.worker_run_ns >= row.synchronization.worker_run_ns_max &&
          row.synchronization.arena_lock_acquires >= row.synchronization.arena_lock_contentions &&
          row.synchronization.env_lock_acquires >= row.synchronization.env_lock_contentions &&
          row.synchronization.env_lock_acquires ===
            row.synchronization.env_read_lock_acquires +
              row.synchronization.env_write_lock_acquires +
              row.synchronization.env_trace_lock_acquires &&
          row.synchronization.env_read_lock_acquires ===
            row.synchronization.env_read_root_lock_acquires +
              row.synchronization.env_read_captured_lock_acquires +
              row.synchronization.env_read_other_lock_acquires &&
          row.synchronization.env_write_lock_acquires ===
            row.synchronization.env_write_private_lock_acquires +
              row.synchronization.env_write_root_lock_acquires +
              row.synchronization.env_write_captured_lock_acquires +
              row.synchronization.env_write_other_lock_acquires &&
          row.synchronization.object_backing_lock_acquires >= row.synchronization.object_backing_lock_contentions &&
          row.synchronization.object_property_lock_acquires >= row.synchronization.object_property_lock_contentions &&
          row.synchronization.object_property_lock_acquires ===
            row.synchronization.object_property_named_snapshot_acquires +
              row.synchronization.object_property_receiver_set_acquires +
              row.synchronization.object_property_named_delete_acquires +
              row.synchronization.object_property_other_acquires &&
          row.synchronization.object_element_lock_acquires >= row.synchronization.object_element_lock_contentions,
        `synchronization attribution is incoherent for ${workload}`,
      );
      requireValue(
        JSON.stringify(Object.keys(row.native_code).sort()) ===
          JSON.stringify([...nativeCodeMetrics].sort()),
        `native-code attribution inventory drift for ${workload}`,
      );
    });
    requireValue(
      group[2].checksum === entryChecksum(entry, manifest, quick),
      `${workload} attribution checksum ${group[2].checksum} does not match frozen ${entryChecksum(entry, manifest, quick)}`,
    );
    if (entry.owner.family?.startsWith("wasm_") || workload.startsWith("wasm_")) {
      requireValue(
        (group[2].execution.wasm_dispatches || 0) >
          (group[1].execution.wasm_dispatches || 0),
        `${workload} invocation recorded no WebAssembly dispatches`,
      );
    }
  }
  const phaseDeltas = deltas(rows),
    byWorkload: Record<string, TierDelta[]> = {};
  entries.slice(0, completedEntries).forEach((entry, index) => {
    if (entry.mode !== "shared") return;
    const invocation = phaseDeltas[index * phases.length + 2];
    requireValue(
      invocation.synchronization.worker_runs === entry.lanes,
      `${entry.workload} shared/${entry.lanes}-lane invocation recorded ${invocation.synchronization.worker_runs} worker runs`,
    );
  });
  phaseDeltas.forEach((row) =>
    (byWorkload[deltaKey(row.workload, row.mode, row.lanes)] ||= []).push(row));
  for (const family of manifest.implemented_families) {
    const modes: Array<[TierSnapshot["mode"], number]> = [[
      family.availability?.attribution_mode === "module_attribution" ? "module_cold" : "single",
      1,
    ]];
    if (family.shared !== false) for (const lanes of manifest.lanes) modes.push(["shared", lanes]);
    for (const [mode, lanes] of modes) for (const phase of ["warmup", "invocation"] as const) {
      const baseRows = byWorkload[deltaKey(family.base, mode, lanes)],
        variantRows = byWorkload[deltaKey(family.variant, mode, lanes)];
      if (!baseRows || !variantRows) continue;
      const base = baseRows.find((row) => row.phase === phase)!,
        variant = variantRows.find((row) => row.phase === phase)!;
      requireValue(signature(base).length > 0, `${family.base} selected no execution tier`);
      requireValue(
        signature(base) === signature(variant),
        `${family.family} ${mode}/${lanes}-lane ${phase} tier attribution differs: base=${signature(base)} variant=${signature(variant)}`,
      );
      const baseEnvironments = base.execution.environment_allocations || 0,
        variantEnvironments = variant.execution.environment_allocations || 0;
      requireValue(
        baseEnvironments === variantEnvironments,
        `${family.family} ${mode}/${lanes}-lane ${phase} environment allocations differ: base=${baseEnvironments} variant=${variantEnvironments}`,
      );
    }
  }
  return phaseDeltas;
}

export function validate(
  rows: TierSnapshot[],
  manifest: any,
  quick: boolean,
): TierDelta[] {
  return validateRows(rows, manifest, quick, true);
}

export function render(
  deltas_: TierDelta[],
  manifest: any,
  heading = "#",
  rawPath: string | null = null,
): string {
  const rows: string[] = [
    `${heading} Representative tier attribution — ${manifest.matrix_id}`,
    "",
    "| family | phase | base tiers | variant tiers | base env allocations | variant env allocations |",
    "| --- | --- | --- | --- | ---: | ---: |",
  ];
  const byWorkload: Record<string, TierDelta[]> = {};
  deltas_.filter((row) => row.mode !== "shared")
    .forEach((row) => (byWorkload[row.workload] ||= []).push(row));
  for (const family of manifest.implemented_families) {
    for (const phase of ["warmup", "invocation"] as const) {
      const base = byWorkload[family.base].find((row) => row.phase === phase)!,
        variant = byWorkload[family.variant].find((row) => row.phase === phase)!;
      rows.push(
        `| \`${family.family}\` | ${phase} | \`${signature(base)}\` | \`${signature(variant)}\` | ${base.execution.environment_allocations || 0} | ${variant.execution.environment_allocations || 0} |`,
      );
    }
  }
  if ((manifest.additional_panels || []).length) {
    rows.push(
      "",
      `${heading}${heading} Additional workload panels`,
      "",
      "These repository-owned #460 workloads use the same complete single-context attribution inventory; they are not silently omitted from the family report.",
      "",
      "| panel | workload | tiers | checksum |",
      "| --- | --- | --- | ---: |",
    );
    for (const panel of manifest.additional_panels) {
      const invocation = byWorkload[panel.workload].find((row) => row.phase === "invocation")!;
      rows.push(`| \`${panel.id}\` | \`${panel.workload}\` | \`${signature(invocation)}\` | ${invocation.checksum} |`);
    }
  }
  rows.push(
    "",
    `${heading}${heading} Tier-up and deoptimization latency`,
    "",
    "Tier-up time starts after a successful compilation claim and ends when code publication succeeds or the attempt is rejected. Deoptimization time starts when native code returns a recoverable exit and ends after the interpreter continuation is fully reconstructed; it excludes native execution before the exit.",
    "",
    "| family | phase | base tier-ups | variant tier-ups | base tier-up time | variant tier-up time | base deopts | variant deopts | base deopt time | variant deopt time |",
    "| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |",
  );
  for (const family of manifest.implemented_families) {
    for (const phase of ["warmup", "invocation"] as const) {
      const base = byWorkload[family.base].find((row) => row.phase === phase)!,
        variant = byWorkload[family.variant].find((row) => row.phase === phase)!,
        baseTierUps = base.timing.baseline_tier_ups + base.timing.optimizer_tier_ups,
        variantTierUps = variant.timing.baseline_tier_ups + variant.timing.optimizer_tier_ups,
        baseTierUpNs = base.timing.baseline_tier_up_ns + base.timing.optimizer_tier_up_ns,
        variantTierUpNs = variant.timing.baseline_tier_up_ns + variant.timing.optimizer_tier_up_ns;
      rows.push(
        `| \`${family.family}\` | ${phase} | ${baseTierUps} | ${variantTierUps} | ${baseTierUpNs} ns | ${variantTierUpNs} ns | ${base.timing.deoptimizations} | ${variant.timing.deoptimizations} | ${base.timing.deoptimization_ns} ns | ${variant.timing.deoptimization_ns} ns |`,
      );
    }
  }
  rows.push(
    "",
    `${heading}${heading} Allocation throughput`,
    "",
    "Backing rows count successful Context allocator calls and growth bytes. GC-cell rows count logical slab/delegated cell issuance separately, so backing growth is never double-counted as a cell allocation.",
    "",
    "| family | phase | base backing ops | variant backing ops | base backing bytes | variant backing bytes | base GC cells | variant GC cells | base GC bytes | variant GC bytes |",
    "| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |",
  );
  for (const family of manifest.implemented_families) {
    for (const phase of ["warmup", "invocation"] as const) {
      const base = byWorkload[family.base].find((row) => row.phase === phase)!,
        variant = byWorkload[family.variant].find((row) => row.phase === phase)!,
        baseBackingOps = base.allocation.backing_allocations + base.allocation.backing_growths,
        variantBackingOps = variant.allocation.backing_allocations + variant.allocation.backing_growths,
        baseBackingBytes = base.allocation.backing_allocation_bytes + base.allocation.backing_growth_bytes,
        variantBackingBytes = variant.allocation.backing_allocation_bytes + variant.allocation.backing_growth_bytes;
      rows.push(
        `| \`${family.family}\` | ${phase} | ${baseBackingOps} | ${variantBackingOps} | ${baseBackingBytes} | ${variantBackingBytes} | ${base.allocation.gc_cell_allocations} | ${variant.allocation.gc_cell_allocations} | ${base.allocation.gc_cell_bytes} | ${variant.allocation.gc_cell_bytes} |`,
      );
    }
  }
  const percentile = (samples: number[], quantile: number): string => {
    if (samples.length === 0) return "none";
    const ordered = [...samples].sort((a, b) => a - b);
    return `${ordered[Math.ceil(ordered.length * quantile) - 1]} ns`;
  };
  rows.push(
    "",
    `${heading}${heading} GC pause distribution`,
    "",
    "Each phase contains the exact completed minor/full cycle samples appended during that interval. Percentiles use the nearest-rank method; `none` means the phase completed no collection, and any sample overflow rejects the artifact.",
    "",
    "| family | phase | base cycles | variant cycles | base p50 | variant p50 | base p95 | variant p95 | base max | variant max |",
    "| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |",
  );
  for (const family of manifest.implemented_families) {
    for (const phase of ["warmup", "invocation"] as const) {
      const base = byWorkload[family.base].find((row) => row.phase === phase)!,
        variant = byWorkload[family.variant].find((row) => row.phase === phase)!,
        basePauses = [...base.gc_pauses.minor_ns, ...base.gc_pauses.full_ns],
        variantPauses = [...variant.gc_pauses.minor_ns, ...variant.gc_pauses.full_ns];
      rows.push(
        `| \`${family.family}\` | ${phase} | ${basePauses.length} | ${variantPauses.length} | ${percentile(basePauses, 0.5)} | ${percentile(variantPauses, 0.5)} | ${percentile(basePauses, 0.95)} | ${percentile(variantPauses, 0.95)} | ${percentile(basePauses, 1)} | ${percentile(variantPauses, 1)} |`,
      );
    }
  }
  rows.push(
    "",
    `${heading}${heading} Runtime dispatch`,
    "",
    "Counts are exact successful or entered runtime boundaries for each phase; they are not sampled estimates.",
    "",
    "| family | phase | base VM dispatches | variant VM dispatches | base quick kernels | variant quick kernels | base runtime ops | variant runtime ops | base host callbacks | variant host callbacks | base Wasm dispatches | variant Wasm dispatches |",
    "| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |",
  );
  for (const family of manifest.implemented_families) {
    for (const phase of ["warmup", "invocation"] as const) {
      const base = byWorkload[family.base].find((row) => row.phase === phase)!,
        variant = byWorkload[family.variant].find((row) => row.phase === phase)!;
      rows.push(
        `| \`${family.family}\` | ${phase} | ${base.execution.vm_dispatches || 0} | ${variant.execution.vm_dispatches || 0} | ${base.execution.vm_quick_kernel_hits || 0} | ${variant.execution.vm_quick_kernel_hits || 0} | ${base.execution.runtime_operation_calls || 0} | ${variant.execution.runtime_operation_calls || 0} | ${base.execution.host_callbacks || 0} | ${variant.execution.host_callbacks || 0} | ${base.execution.wasm_dispatches || 0} | ${variant.execution.wasm_dispatches || 0} |`,
      );
    }
  }
  rows.push(
    "",
    `${heading}${heading} Synchronization and worker lifecycle`,
    "",
    "Phase rows are deltas from process-global opt-in counters. Single-context rows can legitimately report zero; zero is measured, not a substitute for unavailable telemetry.",
    "",
    "| family | phase | base contentions | variant contentions | base wait | variant wait | base worker runs | variant worker runs | base worker time | variant worker time |",
    "| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |",
  );
  const contentions = (row: TierDelta): number =>
    [
      "lock_contentions",
      "arena_lock_contentions",
      "env_lock_contentions",
      "object_backing_lock_contentions",
      "object_property_lock_contentions",
      "object_element_lock_contentions",
    ].reduce((sum, name) => sum + (row.synchronization[name] || 0), 0) +
    row.cell_slab_lock.contentions;
  const waitNs = (row: TierDelta): number =>
    ["thread_join_wait_ns", "lock_wait_ns", "condition_wait_ns", "property_wait_ns"]
      .reduce((sum, name) => sum + (row.synchronization[name] || 0), 0);
  for (const family of manifest.implemented_families) {
    for (const phase of ["warmup", "invocation"] as const) {
      const base = byWorkload[family.base].find((row) => row.phase === phase)!,
        variant = byWorkload[family.variant].find((row) => row.phase === phase)!;
      rows.push(
        `| \`${family.family}\` | ${phase} | ${contentions(base)} | ${contentions(variant)} | ${waitNs(base)} ns | ${waitNs(variant)} ns | ${base.synchronization.worker_runs || 0} | ${variant.synchronization.worker_runs || 0} | ${base.synchronization.worker_run_ns || 0} ns | ${variant.synchronization.worker_run_ns || 0} ns |`,
      );
    }
  }
  rows.push(
    "",
    `${heading}${heading} Process CPU and resident memory`,
    "",
    "CPU values are exact getrusage deltas for the fresh runner process. Peak and retained RSS are Mach task_vm_info resident_size_peak/resident_size gauges captured in one phase-boundary snapshot. The invocation values are captured after the workload host checkpoint and before Context destruction.",
    "",
    "| family | phase | base CPU | variant CPU | base peak RSS | variant peak RSS | base retained RSS | variant retained RSS |",
    "| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: |",
  );
  for (const family of manifest.implemented_families) {
    for (const phase of ["warmup", "invocation"] as const) {
      const base = byWorkload[family.base].find((row) => row.phase === phase)!,
        variant = byWorkload[family.variant].find((row) => row.phase === phase)!,
        baseCpu = base.process.cpu_user_ns + base.process.cpu_system_ns,
        variantCpu = variant.process.cpu_user_ns + variant.process.cpu_system_ns;
      rows.push(
        `| \`${family.family}\` | ${phase} | ${baseCpu} ns | ${variantCpu} ns | ${base.process.peak_rss_bytes} bytes | ${variant.process.peak_rss_bytes} bytes | ${base.process.retained_rss_bytes} bytes | ${variant.process.retained_rss_bytes} bytes |`,
      );
    }
  }
  rows.push(
    "",
    `${heading}${heading} Native-code and heap state`,
    "",
    "These values are phase-boundary gauges or cumulative counters, not timing-row measurements.",
    "",
    "| family | phase | base live code bytes | variant live code bytes | base heap live bytes | variant heap live bytes | base collections | variant collections |",
    "| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: |",
  );
  for (const family of manifest.implemented_families) {
    for (const phase of ["warmup", "invocation"] as const) {
      const base = byWorkload[family.base].find((row) => row.phase === phase)!,
        variant = byWorkload[family.variant].find((row) => row.phase === phase)!;
      rows.push(
        `| \`${family.family}\` | ${phase} | ${base.native_code.live_bytes} | ${variant.native_code.live_bytes} | ${base.heap.live_bytes} | ${variant.heap.live_bytes} | ${base.heap.collections} | ${variant.heap.collections} |`,
      );
    }
  }
  const sharedByKey: Record<string, TierDelta[]> = {};
  deltas_.filter((row) => row.mode === "shared")
    .forEach((row) => (sharedByKey[deltaKey(row.workload, row.mode, row.lanes)] ||= []).push(row));
  rows.push(
    "",
    `${heading}${heading} Shared-realm attribution`,
    "",
    "Each row is the invocation delta after the scored shared-mode warmup boundary. Worker work, joins, contention, GC, allocation, CPU, and resident memory are observed in the same fresh profiled process after every spawned worker has joined.",
    "",
    "| family | lanes | base tiers | variant tiers | base contentions | variant contentions | base wait | variant wait | base worker runs | variant worker runs | base CPU | variant CPU | base retained RSS | variant retained RSS |",
    "| --- | ---: | --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |",
  );
  for (const family of manifest.implemented_families) {
    if (family.shared === false) continue;
    for (const lanes of manifest.lanes) {
      const base = sharedByKey[deltaKey(family.base, "shared", lanes)].find((row) => row.phase === "invocation")!,
        variant = sharedByKey[deltaKey(family.variant, "shared", lanes)].find((row) => row.phase === "invocation")!,
        baseCpu = base.process.cpu_user_ns + base.process.cpu_system_ns,
        variantCpu = variant.process.cpu_user_ns + variant.process.cpu_system_ns;
      rows.push(
        `| \`${family.family}\` | ${lanes} | \`${signature(base)}\` | \`${signature(variant)}\` | ${contentions(base)} | ${contentions(variant)} | ${waitNs(base)} ns | ${waitNs(variant)} ns | ${base.synchronization.worker_runs || 0} | ${variant.synchronization.worker_runs || 0} | ${baseCpu} ns | ${variantCpu} ns | ${base.process.retained_rss_bytes} bytes | ${variant.process.retained_rss_bytes} bytes |`,
      );
    }
  }
  for (const panel of manifest.additional_panels || []) {
    if (!(panel.modes || []).includes("shared")) continue;
    for (const lanes of manifest.lanes) {
      const row = sharedByKey[deltaKey(panel.workload, "shared", lanes)].find((entry) => entry.phase === "invocation")!,
        cpu = row.process.cpu_user_ns + row.process.cpu_system_ns;
      rows.push(
        `| \`${panel.id}\` | ${lanes} | \`${signature(row)}\` | n/a | ${contentions(row)} | n/a | ${waitNs(row)} ns | n/a | ${row.synchronization.worker_runs || 0} | n/a | ${cpu} ns | n/a | ${row.process.retained_rss_bytes} bytes | n/a |`,
      );
    }
  }
  const dominantCellSlabSize = (row: TierDelta): string => {
    let bestSize = 0, bestContentions = 0, bestAcquires = 0;
    for (const size of cellSlabSizes) {
      const sizeContentions = row.cell_slab_lock[`size_${size}_contentions`],
        sizeAcquires = row.cell_slab_lock[`size_${size}_acquires`];
      if (sizeContentions > bestContentions ||
          (sizeContentions === bestContentions && sizeAcquires > bestAcquires)) {
        bestSize = size;
        bestContentions = sizeContentions;
        bestAcquires = sizeAcquires;
      }
    }
    return bestAcquires === 0 ? "none" : `${bestSize} B`;
  };
  const dominantCellSlabOwnership = (row: TierDelta): string => {
    let best = "none", bestAcquires = 0;
    for (const name of cellSlabOwnershipPurposeMetrics) {
      const acquires = row.cell_slab_lock[name];
      if (acquires > bestAcquires) {
        best = name.replace(/^ownership_/, "").replace(/_acquires$/, "");
        bestAcquires = acquires;
      }
    }
    return bestAcquires === 0 ? "none" : best;
  };
  rows.push(
    "",
    `${heading}${heading} Shared-realm GC cell-slab locks`,
    "",
    "Each invocation row preserves exact lock attempts by purpose and by 64/128/256/512/1024/2048-byte size class. Ownership attempts are further classified as exact-allocation validation, stable identity, conservative interior classification, realm lookup/scan, or allocator resize/remap. The table exposes totals, the size class selected by highest contention then acquisition count, and the dominant ownership subpath; the raw sidecar retains the full inventory.",
    "",
    "| family | lanes | base acquires | variant acquires | base contentions | variant contentions | base spins | variant spins | base dominant class | variant dominant class | base ownership path | variant ownership path |",
    "| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | --- | --- | --- | --- |",
  );
  for (const family of manifest.implemented_families) {
    if (family.shared === false) continue;
    for (const lanes of manifest.lanes) {
      const base = sharedByKey[deltaKey(family.base, "shared", lanes)].find((row) => row.phase === "invocation")!,
        variant = sharedByKey[deltaKey(family.variant, "shared", lanes)].find((row) => row.phase === "invocation")!;
      rows.push(
        `| \`${family.family}\` | ${lanes} | ${base.cell_slab_lock.acquires} | ${variant.cell_slab_lock.acquires} | ${base.cell_slab_lock.contentions} | ${variant.cell_slab_lock.contentions} | ${base.cell_slab_lock.spins} | ${variant.cell_slab_lock.spins} | ${dominantCellSlabSize(base)} | ${dominantCellSlabSize(variant)} | \`${dominantCellSlabOwnership(base)}\` | \`${dominantCellSlabOwnership(variant)}\` |`,
      );
    }
  }
  for (const panel of manifest.additional_panels || []) {
    if (!(panel.modes || []).includes("shared")) continue;
    for (const lanes of manifest.lanes) {
      const row = sharedByKey[deltaKey(panel.workload, "shared", lanes)].find((entry) => entry.phase === "invocation")!;
      rows.push(
        `| \`${panel.id}\` | ${lanes} | ${row.cell_slab_lock.acquires} | n/a | ${row.cell_slab_lock.contentions} | n/a | ${row.cell_slab_lock.spins} | n/a | ${dominantCellSlabSize(row)} | n/a | \`${dominantCellSlabOwnership(row)}\` | n/a |`,
      );
    }
  }
  if (rawPath) {
    const name = rawPath.split("/").pop();
    rows.push("", `Raw attribution: [\`${name}\`](${name})`);
  }
  return rows.join("\n") + "\n";
}

export function artifact(
  snapshots: TierSnapshot[],
  manifest: any,
  quick: boolean,
  info: Record<string, string>,
  runner: string,
  complete = true,
  collectionSegments: CollectionSegment[] = [{
    first_snapshot: 0,
    snapshot_count: snapshots.length,
    environment: info,
  }],
): any {
  return {
    schema_version: 12,
    matrix_id: manifest.matrix_id,
    quick,
    complete,
    environment: info,
    runner_sha256: commandOutput(["shasum", "-a", "256", runner]).split(/\s+/)[0],
    collection_segments: collectionSegments,
    snapshots,
  };
}

const stableEnvironmentFields = [
  "Host",
  "OS",
  "Zig",
  "zig-js",
  "zig-gc",
  "zig-regex",
  "JavaScriptCore",
];

function validateCheckpoint(
  raw: any,
  manifest: any,
  quick: boolean,
  info: Record<string, string>,
  runner: string,
): void {
  requireValue(raw?.schema_version === 12, "checkpoint schema is not version 12");
  requireValue(raw.matrix_id === manifest.matrix_id, "checkpoint matrix identity drift");
  requireValue(raw.quick === quick, "checkpoint quick/full mode drift");
  requireValue(typeof raw.complete === "boolean", "checkpoint completion state is missing");
  requireValue(
    raw.runner_sha256 === commandOutput(["shasum", "-a", "256", runner]).split(/\s+/)[0],
    "checkpoint runner binary drift",
  );
  requireValue(Array.isArray(raw.snapshots), "checkpoint snapshots are missing");
  validateRows(raw.snapshots, manifest, quick, raw.complete);
  const segments = raw.collection_segments;
  requireValue(Array.isArray(segments) && segments.length > 0, "checkpoint collection segments are missing");
  requireValue(
    JSON.stringify(raw.environment) === JSON.stringify(segments[0].environment),
    "checkpoint initial environment drift",
  );
  let covered = 0;
  for (const segment of segments) {
    requireValue(
      Number.isInteger(segment.first_snapshot) && segment.first_snapshot === covered &&
        Number.isInteger(segment.snapshot_count) && segment.snapshot_count >= 0,
      "checkpoint collection segment is not contiguous",
    );
    requireValue(
      segment.environment && typeof segment.environment === "object" &&
        !Array.isArray(segment.environment),
      "checkpoint collection segment environment is missing",
    );
    ensurePublishable(segment.environment, true);
    for (const field of stableEnvironmentFields) {
      requireValue(
        segment.environment[field] === segments[0].environment[field],
        `checkpoint collection environment drift: ${field}`,
      );
    }
    covered += segment.snapshot_count;
  }
  requireValue(covered === raw.snapshots.length, "checkpoint collection segments do not cover snapshots");
  for (const field of stableEnvironmentFields) {
    requireValue(info[field] === raw.environment[field], `current checkpoint environment drift: ${field}`);
  }
}

function atomicWrite(path: string, contents: string): void {
  const temporary = `${path}.tmp`;
  writeText(temporary, contents);
  const moved = run(["mv", "-f", temporary, path]);
  requireValue(moved.exitCode === 0, moved.stderr || `cannot replace ${path}`);
}

function syntheticRows(manifest: any): TierSnapshot[] {
  const rows: TierSnapshot[] = [];
  for (const entry of workloadEntries(manifest)) {
    const jobs = jobsFor(entry.owner, true),
      checksum = entryChecksum(entry, manifest, true);
    phases.forEach((phase, index) =>
      rows.push({
        kind: "zig-js-tier-attribution",
        mode: entry.mode,
        workload: entry.workload,
        lanes: entry.lanes,
        jobs,
        phase,
        checksum: phase === "invocation" ? checksum : 0,
        execution: {
          tree_walker_entries: 0,
          vm_entries: index + 1,
          vm_dispatches: index + 10,
          vm_quick_kernel_hits: index,
          baseline_entries: 0,
          optimizer_entries: index,
          optimizer_osr_entries: 0,
          deoptimizations: 0,
          runtime_operation_calls: index,
          host_callbacks: 0,
          wasm_dispatches: entry.owner.family?.startsWith("wasm_") || entry.workload.startsWith("wasm_") ? index : 0,
          environment_allocations: index,
        },
        timing: {
          baseline_attempts: 0,
          baseline_tier_ups: 0,
          baseline_tier_up_ns: 0,
          baseline_tier_up_ns_max: 0,
          baseline_failures: 0,
          baseline_failure_ns: 0,
          baseline_failure_ns_max: 0,
          optimizer_attempts: index > 0 ? 1 : 0,
          optimizer_tier_ups: index > 0 ? 1 : 0,
          optimizer_tier_up_ns: index > 0 ? 10 : 0,
          optimizer_tier_up_ns_max: index > 0 ? 10 : 0,
          optimizer_failures: 0,
          optimizer_failure_ns: 0,
          optimizer_failure_ns_max: 0,
          deoptimizations: 0,
          deoptimization_ns: 0,
          deoptimization_ns_max: 0,
        },
        admissions: { program_compiled: index + 1 },
        synchronization: Object.fromEntries(
          synchronizationMetrics.map((name) => [
            name,
            name === "worker_runs" && entry.mode === "shared" ? index * entry.lanes : 0,
          ]),
        ),
        debug_registry: Object.fromEntries(
          debugRegistryMetrics.map((name) => [name, index]),
        ),
        allocation: Object.fromEntries(allocationMetrics.map((name) => {
          if (name === "backing_allocations" || name === "backing_allocation_bytes" ||
              name === "backing_current_bytes" || name === "backing_peak_bytes" ||
              name === "gc_cell_allocations" || name === "gc_cell_bytes" ||
              name === "gc_cell_fresh_allocations") return [name, index];
          return [name, 0];
        })),
        cell_slab_lock: Object.fromEntries(cellSlabLockMetrics.map((name) => [
          name,
          name === "acquires" || name === "single_allocation_acquires" ||
              name === "size_64_acquires" ? index : 0,
        ])),
        gc_pauses: {
          minor_ns: Array.from({ length: index }, (_, sample) => sample + 1),
          minor_overflow: 0,
          full_ns: [],
          full_overflow: 0,
        },
        baseline_publications: 0,
        optimizer_publications: index > 0 ? 1 : 0,
        generated_code_bytes: index > 0 ? 4096 : 0,
        native_code: Object.fromEntries(
          nativeCodeMetrics.map((name) => [name, name === "live_bytes" && index > 0 ? 4096 : 0]),
        ),
        heap: Object.fromEntries(
          heapMetrics.map((name) => [name,
            name === "live_bytes" ? 8192 + index : name === "collections" ? index : 0]),
        ),
        process: {
          cpu_user_ns: (index + 1) * 100,
          cpu_system_ns: (index + 1) * 10,
          peak_rss_bytes: 1_000_000 + index * 1_000,
          retained_rss_bytes: 900_000 + index * 500,
        },
      }),
    );
  }
  return rows;
}

function expectFailure(action: () => void, pattern: string): void {
  try {
    action();
  } catch (error) {
    requireValue(String(error).includes(pattern), `expected ${pattern}, got ${String(error)}`);
    return;
  }
  throw new Error(`expected failure containing ${pattern}`);
}

export function selfTest(): void {
  const manifest = loadManifest(DEFAULT_MANIFEST),
    entries = workloadEntries(manifest),
    rows = syntheticRows(manifest);
  requireValue(entries.length === 170 && rows.length === 510, "V16 attribution coverage drift");
  validate(rows, manifest, true);
  const mismatch = JSON.parse(JSON.stringify(rows));
  mismatch[4].execution.tree_walker_entries = 1;
  mismatch[5].execution.tree_walker_entries = 1;
  expectFailure(() => validate(mismatch, manifest, true), "tier attribution differs");
  const environmentMismatch = JSON.parse(JSON.stringify(rows));
  environmentMismatch[5].execution.environment_allocations += 1;
  expectFailure(
    () => validate(environmentMismatch, manifest, true),
    "environment allocations differ",
  );
  const checksum = JSON.parse(JSON.stringify(rows));
  checksum[2].checksum += 1;
  expectFailure(() => validate(checksum, manifest, true), "does not match frozen");
  const nativeCode = JSON.parse(JSON.stringify(rows));
  delete nativeCode[0].native_code.live_bytes;
  expectFailure(() => validate(nativeCode, manifest, true), "native-code attribution inventory drift");
  const heap = JSON.parse(JSON.stringify(rows));
  delete heap[0].heap.collections;
  expectFailure(() => validate(heap, manifest, true), "heap attribution inventory drift");
  const processResource = JSON.parse(JSON.stringify(rows));
  delete processResource[0].process.retained_rss_bytes;
  expectFailure(() => validate(processResource, manifest, true), "process resource inventory drift");
  const incoherentProcessResource = JSON.parse(JSON.stringify(rows));
  incoherentProcessResource[0].process.retained_rss_bytes =
    incoherentProcessResource[0].process.peak_rss_bytes + 1;
  expectFailure(
    () => validate(incoherentProcessResource, manifest, true),
    "process resource attribution is incoherent",
  );
  const regressedProcessResource = JSON.parse(JSON.stringify(rows));
  regressedProcessResource[1].process.cpu_user_ns =
    regressedProcessResource[0].process.cpu_user_ns - 1;
  expectFailure(
    () => validate(regressedProcessResource, manifest, true),
    "process resource counter regressed",
  );
  const execution = JSON.parse(JSON.stringify(rows));
  delete execution[0].execution.vm_dispatches;
  expectFailure(() => validate(execution, manifest, true), "execution attribution inventory drift");
  const timing = JSON.parse(JSON.stringify(rows));
  delete timing[0].timing.deoptimization_ns;
  expectFailure(() => validate(timing, manifest, true), "tier timing inventory drift");
  const incoherentTiming = JSON.parse(JSON.stringify(rows));
  incoherentTiming[1].timing.optimizer_attempts += 1;
  expectFailure(() => validate(incoherentTiming, manifest, true), "tier timing attribution is incoherent");
  const synchronization = JSON.parse(JSON.stringify(rows));
  delete synchronization[0].synchronization.lock_wait_ns;
  expectFailure(
    () => validate(synchronization, manifest, true),
    "synchronization attribution inventory drift",
  );
  const incoherentSynchronization = JSON.parse(JSON.stringify(rows));
  incoherentSynchronization[0].synchronization.arena_lock_contentions = 1;
  expectFailure(
    () => validate(incoherentSynchronization, manifest, true),
    "synchronization attribution is incoherent",
  );
  const incoherentEnvironmentReads = JSON.parse(JSON.stringify(rows));
  incoherentEnvironmentReads[0].synchronization.env_read_root_lock_acquires = 1;
  expectFailure(
    () => validate(incoherentEnvironmentReads, manifest, true),
    "synchronization attribution is incoherent",
  );
  const allocation = JSON.parse(JSON.stringify(rows));
  delete allocation[0].allocation.backing_allocations;
  expectFailure(() => validate(allocation, manifest, true), "allocation attribution inventory drift");
  const incoherentAllocation = JSON.parse(JSON.stringify(rows));
  incoherentAllocation[1].allocation.backing_current_bytes += 1;
  expectFailure(() => validate(incoherentAllocation, manifest, true), "allocation attribution is incoherent");
  const cellSlabLock = JSON.parse(JSON.stringify(rows));
  delete cellSlabLock[0].cell_slab_lock.size_256_spins;
  expectFailure(
    () => validate(cellSlabLock, manifest, true),
    "cell slab lock attribution inventory drift",
  );
  const incoherentCellSlabLock = JSON.parse(JSON.stringify(rows));
  incoherentCellSlabLock[1].cell_slab_lock.ownership_acquires += 1;
  expectFailure(
    () => validate(incoherentCellSlabLock, manifest, true),
    "cell slab lock attribution is incoherent",
  );
  const incompleteGc = JSON.parse(JSON.stringify(rows));
  incompleteGc[1].gc_pauses.minor_ns.pop();
  expectFailure(() => validate(incompleteGc, manifest, true), "GC pause attribution is incomplete");
  const overflowingGc = JSON.parse(JSON.stringify(rows));
  overflowingGc[0].gc_pauses.minor_overflow = 1;
  expectFailure(() => validate(overflowingGc, manifest, true), "GC pause attribution is incomplete");
  const sharedIndex = entries.findIndex((entry) => entry.mode === "shared");
  const missingWorker = JSON.parse(JSON.stringify(rows));
  missingWorker[sharedIndex * phases.length + 2].synchronization.worker_runs -= 1;
  expectFailure(() => validate(missingWorker, manifest, true), "worker runs");
  const wrongLanes = JSON.parse(JSON.stringify(rows));
  wrongLanes[sharedIndex * phases.length].lanes += 1;
  expectFailure(() => validate(wrongLanes, manifest, true), "unexpected lanes");
  expectFailure(
    () => validateRows(rows.slice(0, phases.length + 1), manifest, true, false),
    "valid 510-row prefix",
  );
  const checkpointInfo: Record<string, string> = {
    Date: "2026-08-04",
    Host: "test host",
    OS: "test OS",
    Zig: "test Zig",
    "zig-js": "0".repeat(40),
    "zig-gc": "1".repeat(40),
    "zig-regex": "2".repeat(40),
    JavaScriptCore: "test JSC",
    Power: "battery 90%",
  };
  const prefix = rows.slice(0, phases.length),
    checkpoint = artifact(prefix, manifest, true, checkpointInfo, __filename, false, [{
      first_snapshot: 0,
      snapshot_count: prefix.length,
      environment: checkpointInfo,
    }]),
    resumedInfo = { ...checkpointInfo, Date: "2026-08-05", Power: "AC Power" };
  validateCheckpoint(checkpoint, manifest, true, resumedInfo, __filename);
  const uncovered = JSON.parse(JSON.stringify(checkpoint));
  uncovered.collection_segments[0].snapshot_count -= 1;
  expectFailure(
    () => validateCheckpoint(uncovered, manifest, true, resumedInfo, __filename),
    "do not cover snapshots",
  );
  const prematureComplete = JSON.parse(JSON.stringify(checkpoint));
  prematureComplete.complete = true;
  expectFailure(
    () => validateCheckpoint(prematureComplete, manifest, true, resumedInfo, __filename),
    "valid 510-row prefix",
  );
  const changedRevision = { ...resumedInfo, "zig-js": "3".repeat(40) };
  expectFailure(
    () => validateCheckpoint(checkpoint, manifest, true, changedRevision, __filename),
    "current checkpoint environment drift: zig-js",
  );
  const wasm = JSON.parse(JSON.stringify(rows));
  const wasmIndex = workloadEntries(manifest).findIndex((entry) =>
    entry.owner.family?.startsWith("wasm_") || entry.workload.startsWith("wasm_"));
  wasm[wasmIndex * phases.length + 2].execution.wasm_dispatches =
    wasm[wasmIndex * phases.length + 1].execution.wasm_dispatches;
  expectFailure(() => validate(wasm, manifest, true), "recorded no WebAssembly dispatches");
  console.log("OK representative tier attribution self-test: phases, checksums, tier/runtime/timing/synchronization/allocation/process inventory, exact GC pauses, environment parity, native-code lifetime, heap state, CPU, RSS, tier transitions, and exact checkpoint/resume identity verified");
}

function main(): void {
  const args = process.argv.slice(2);
  if (args.length === 1 && args[0] === "--self-test") {
    selfTest();
    return;
  }
  let runner = "",
    manifestPath = DEFAULT_MANIFEST,
    output = "",
    markdown = "",
    quick = false;
  for (let index = 0; index < args.length; index += 1) {
    const name = args[index];
    if (name === "--quick") quick = true;
    else {
      const value = args[++index];
      if (name === "--runner") runner = value;
      else if (name === "--manifest") manifestPath = value;
      else if (name === "--out") output = value;
      else if (name === "--markdown-out") markdown = value;
      else throw new Error(`unknown argument: ${name}`);
    }
  }
  requireValue(Boolean(runner) && Home.fileExists(runner), "attribution runner does not exist");
  const manifest = loadManifest(manifestPath);
  validateManifest(manifest);
  const info = metadata();
  ensurePublishable(info, Boolean(output || markdown));
  let snapshots: TierSnapshot[] = [],
    collectionSegments: CollectionSegment[] = [],
    resumedComplete = false;
  if (output && fileExists(output)) {
    const checkpoint = JSON.parse(readText(output));
    validateCheckpoint(checkpoint, manifest, quick, info, runner);
    snapshots = checkpoint.snapshots;
    collectionSegments = checkpoint.collection_segments;
    resumedComplete = checkpoint.complete;
  }
  const expectedSnapshots = workloadEntries(manifest).length * phases.length;
  if (!resumedComplete && snapshots.length < expectedSnapshots) {
    const segment: CollectionSegment = {
      first_snapshot: snapshots.length,
      snapshot_count: 0,
      environment: info,
    };
    collectionSegments.push(segment);
    snapshots = collect(runner, manifest, quick, snapshots, (rows) => {
      segment.snapshot_count = rows.length - segment.first_snapshot;
      if (output) atomicWrite(
        output,
        JSON.stringify(artifact(
          rows,
          manifest,
          quick,
          collectionSegments[0].environment,
          runner,
          false,
          collectionSegments,
        ), null, 2) + "\n",
      );
    });
  }
  const phaseDeltas = validate(snapshots, manifest, quick),
    report = render(phaseDeltas, manifest, "#", output || null),
    rawArtifact = artifact(
      snapshots,
      manifest,
      quick,
      collectionSegments[0]?.environment || info,
      runner,
      true,
      collectionSegments.length ? collectionSegments : undefined,
    );
  if (output) atomicWrite(output, JSON.stringify(rawArtifact, null, 2) + "\n");
  if (markdown) atomicWrite(markdown, report);
  process.stdout.write(report);
}

if (process.argv[1] === __filename) main();
