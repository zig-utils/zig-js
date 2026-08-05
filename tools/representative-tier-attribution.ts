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
import { run, writeText } from "./lib/home";

declare const __filename: string;

export type CounterMap = Record<string, number>;
export type TierSnapshot = {
  kind: "zig-js-tier-attribution";
  workload: string;
  jobs: number;
  phase: "configuration" | "warmup" | "invocation";
  checksum: number;
  execution: CounterMap;
  admissions: CounterMap;
  synchronization: CounterMap;
  allocation: CounterMap;
  gc_pauses: GcPauseSamples;
  baseline_publications: number;
  optimizer_publications: number;
  generated_code_bytes: number;
  native_code: CounterMap;
  heap: CounterMap;
};
export type TierDelta = {
  workload: string;
  jobs: number;
  phase: TierSnapshot["phase"];
  checksum: number;
  execution: CounterMap;
  admissions: CounterMap;
  synchronization: CounterMap;
  allocation: CounterMap;
  gc_pauses: GcPauseSamples;
  baseline_publications: number;
  optimizer_publications: number;
  generated_code_bytes: number;
  native_code: CounterMap;
  heap: CounterMap;
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
  "object_backing_lock_acquires",
  "object_backing_lock_contentions",
  "object_backing_lock_spins",
  "object_property_lock_acquires",
  "object_property_lock_contentions",
  "object_property_lock_spins",
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

function requireValue(condition: boolean, message: string): void {
  if (!condition) throw new Error(message);
}

function workloadEntries(manifest: any): any[] {
  const result: any[] = [];
  for (const family of manifest.implemented_families) {
    result.push([family, "base", family.base]);
    result.push([family, "variant", family.variant]);
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
): TierSnapshot[] {
  const rows: TierSnapshot[] = [];
  for (const entry of workloadEntries(manifest)) {
    const family = entry[0],
      workload = entry[2];
    const jobs = jobsFor(family, quick);
    const mode = family.availability && family.availability.attribution_mode
      ? family.availability.attribution_mode
      : "attribution";
    const command = [
      "env",
      "LC_ALL=C",
      runner,
      mode,
      workload,
      String(jobs),
      "1",
    ];
    console.error(`+ ${command.join(" ")}`);
    const completed = run(command);
    if (completed.stderr) process.stderr.write(completed.stderr);
    requireValue(
      completed.exitCode === 0,
      completed.stderr || `attribution runner exited ${completed.exitCode}`,
    );
    rows.push(...parseSnapshots(completed.stdout));
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

function emptySnapshot(row: TierSnapshot): TierSnapshot {
  return {
    ...row,
    checksum: 0,
    execution: Object.fromEntries(
      Object.keys(row.execution).map((name) => [name, 0]),
    ),
    admissions: Object.fromEntries(
      Object.keys(row.admissions).map((name) => [name, 0]),
    ),
    synchronization: Object.fromEntries(
      synchronizationMetrics.map((name) => [name, 0]),
    ),
    allocation: Object.fromEntries(allocationMetrics.map((name) => [name, 0])),
    gc_pauses: { minor_ns: [], minor_overflow: 0, full_ns: [], full_overflow: 0 },
    baseline_publications: 0,
    optimizer_publications: 0,
    generated_code_bytes: 0,
    native_code: Object.fromEntries(nativeCodeMetrics.map((name) => [name, 0])),
    heap: Object.fromEntries(heapMetrics.map((name) => [name, 0])),
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
        row.workload === group[0].workload && row.jobs === group[0].jobs,
        "attribution phase identity drift",
      );
      result.push({
        workload: row.workload,
        jobs: row.jobs,
        phase: row.phase,
        checksum: row.checksum,
        execution: subtractMap(row.execution, before.execution),
        admissions: subtractMap(row.admissions, before.admissions),
        synchronization: subtractSynchronization(row.synchronization, before.synchronization),
        allocation: subtractAllocation(row.allocation, before.allocation),
        gc_pauses: subtractPauses(row.gc_pauses, before.gc_pauses),
        baseline_publications:
          row.baseline_publications - before.baseline_publications,
        optimizer_publications:
          row.optimizer_publications - before.optimizer_publications,
        generated_code_bytes: row.generated_code_bytes,
        native_code: row.native_code,
        heap: row.heap,
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

export function validate(
  rows: TierSnapshot[],
  manifest: any,
  quick: boolean,
): TierDelta[] {
  const entries = workloadEntries(manifest);
  requireValue(
    rows.length === entries.length * phases.length,
    `attribution row count ${rows.length} does not match ${entries.length * phases.length}`,
  );
  for (let index = 0; index < entries.length; index += 1) {
    const [family, role, workload] = entries[index],
      group = rows.slice(index * phases.length, (index + 1) * phases.length),
      jobs = jobsFor(family, quick);
    group.forEach((row, phaseIndex) => {
      requireValue(row.workload === workload, `unexpected workload ${row.workload}`);
      requireValue(row.jobs === jobs, `unexpected jobs for ${workload}`);
      requireValue(row.phase === phases[phaseIndex], `unexpected phase for ${workload}`);
      requireValue(
        Number.isInteger(row.checksum) &&
          Object.values(row.execution).every(Number.isInteger) &&
          Object.values(row.admissions).every(Number.isInteger) &&
          Object.values(row.synchronization).every(Number.isInteger) &&
          Object.values(row.allocation).every(Number.isInteger) &&
          row.gc_pauses.minor_ns.every(Number.isInteger) &&
          row.gc_pauses.full_ns.every(Number.isInteger) &&
          Number.isInteger(row.gc_pauses.minor_overflow) &&
          Number.isInteger(row.gc_pauses.full_overflow) &&
          Object.values(row.native_code).every(Number.isInteger) &&
          Object.values(row.heap).every(Number.isInteger),
        `non-integral attribution for ${workload}`,
      );
      requireValue(
        JSON.stringify(Object.keys(row.execution).sort()) ===
          JSON.stringify([...tierMetrics, ...runtimeMetrics, "environment_allocations"].sort()),
        `execution attribution inventory drift for ${workload}`,
      );
      requireValue(
        JSON.stringify(Object.keys(row.synchronization).sort()) ===
          JSON.stringify([...synchronizationMetrics].sort()),
        `synchronization attribution inventory drift for ${workload}`,
      );
      requireValue(
        JSON.stringify(Object.keys(row.allocation).sort()) ===
          JSON.stringify([...allocationMetrics].sort()),
        `allocation attribution inventory drift for ${workload}`,
      );
      requireValue(
        JSON.stringify(Object.keys(row.heap).sort()) ===
          JSON.stringify([...heapMetrics].sort()),
        `heap attribution inventory drift for ${workload}`,
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
          row.synchronization.object_backing_lock_acquires >= row.synchronization.object_backing_lock_contentions &&
          row.synchronization.object_property_lock_acquires >= row.synchronization.object_property_lock_contentions &&
          row.synchronization.object_element_lock_acquires >= row.synchronization.object_element_lock_contentions,
        `synchronization attribution is incoherent for ${workload}`,
      );
      requireValue(
        JSON.stringify(Object.keys(row.native_code).sort()) ===
          JSON.stringify([...nativeCodeMetrics].sort()),
        `native-code attribution inventory drift for ${workload}`,
      );
    });
    const lane = manifest.lanes.indexOf(1),
      scale = quick ? "quick" : "full";
    requireValue(
      group[2].checksum === family.checksums[role][scale][lane],
      `${workload} attribution checksum ${group[2].checksum} does not match frozen ${family.checksums[role][scale][lane]}`,
    );
    if (family.family.startsWith("wasm_")) {
      requireValue(
        (group[2].execution.wasm_dispatches || 0) >
          (group[1].execution.wasm_dispatches || 0),
        `${workload} invocation recorded no WebAssembly dispatches`,
      );
    }
  }
  const phaseDeltas = deltas(rows),
    byWorkload: Record<string, TierDelta[]> = {};
  phaseDeltas.forEach((row) => (byWorkload[row.workload] ||= []).push(row));
  for (const family of manifest.implemented_families) {
    for (const phase of ["warmup", "invocation"] as const) {
      const base = byWorkload[family.base].find((row) => row.phase === phase)!,
        variant = byWorkload[family.variant].find((row) => row.phase === phase)!;
      requireValue(signature(base).length > 0, `${family.base} selected no execution tier`);
      requireValue(
        signature(base) === signature(variant),
        `${family.family} ${phase} tier attribution differs: base=${signature(base)} variant=${signature(variant)}`,
      );
      const baseEnvironments = base.execution.environment_allocations || 0,
        variantEnvironments = variant.execution.environment_allocations || 0;
      requireValue(
        baseEnvironments === variantEnvironments,
        `${family.family} ${phase} environment allocations differ: base=${baseEnvironments} variant=${variantEnvironments}`,
      );
    }
  }
  return phaseDeltas;
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
  deltas_.forEach((row) => (byWorkload[row.workload] ||= []).push(row));
  for (const family of manifest.implemented_families) {
    for (const phase of ["warmup", "invocation"] as const) {
      const base = byWorkload[family.base].find((row) => row.phase === phase)!,
        variant = byWorkload[family.variant].find((row) => row.phase === phase)!;
      rows.push(
        `| \`${family.family}\` | ${phase} | \`${signature(base)}\` | \`${signature(variant)}\` | ${base.execution.environment_allocations || 0} | ${variant.execution.environment_allocations || 0} |`,
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
    "| family | phase | base contentions | variant contentions | base wait | variant wait | base worker runs | variant worker runs | base worker CPU | variant worker CPU |",
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
    ].reduce((sum, name) => sum + (row.synchronization[name] || 0), 0);
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
): any {
  return {
    schema_version: 5,
    matrix_id: manifest.matrix_id,
    quick,
    environment: info,
    runner_sha256: commandOutput(["shasum", "-a", "256", runner]).split(/\s+/)[0],
    snapshots,
  };
}

function syntheticRows(manifest: any): TierSnapshot[] {
  const rows: TierSnapshot[] = [];
  for (const [family, role, workload] of workloadEntries(manifest)) {
    const jobs = jobsFor(family, true),
      checksum = family.checksums[role].quick[manifest.lanes.indexOf(1)];
    phases.forEach((phase, index) =>
      rows.push({
        kind: "zig-js-tier-attribution",
        workload,
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
          wasm_dispatches: family.family.startsWith("wasm_") ? index : 0,
          environment_allocations: index,
        },
        admissions: { program_compiled: index + 1 },
        synchronization: Object.fromEntries(
          synchronizationMetrics.map((name) => [name, name === "worker_runs" ? index : 0]),
        ),
        allocation: Object.fromEntries(allocationMetrics.map((name) => {
          if (name === "backing_allocations" || name === "backing_allocation_bytes" ||
              name === "backing_current_bytes" || name === "backing_peak_bytes" ||
              name === "gc_cell_allocations" || name === "gc_cell_bytes" ||
              name === "gc_cell_fresh_allocations") return [name, index];
          return [name, 0];
        })),
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
    rows = syntheticRows(manifest);
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
  const execution = JSON.parse(JSON.stringify(rows));
  delete execution[0].execution.vm_dispatches;
  expectFailure(() => validate(execution, manifest, true), "execution attribution inventory drift");
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
  const allocation = JSON.parse(JSON.stringify(rows));
  delete allocation[0].allocation.backing_allocations;
  expectFailure(() => validate(allocation, manifest, true), "allocation attribution inventory drift");
  const incoherentAllocation = JSON.parse(JSON.stringify(rows));
  incoherentAllocation[1].allocation.backing_current_bytes += 1;
  expectFailure(() => validate(incoherentAllocation, manifest, true), "allocation attribution is incoherent");
  const incompleteGc = JSON.parse(JSON.stringify(rows));
  incompleteGc[1].gc_pauses.minor_ns.pop();
  expectFailure(() => validate(incompleteGc, manifest, true), "GC pause attribution is incomplete");
  const overflowingGc = JSON.parse(JSON.stringify(rows));
  overflowingGc[0].gc_pauses.minor_overflow = 1;
  expectFailure(() => validate(overflowingGc, manifest, true), "GC pause attribution is incomplete");
  const wasm = JSON.parse(JSON.stringify(rows));
  const wasmIndex = workloadEntries(manifest).findIndex(([family]) => family.family.startsWith("wasm_"));
  wasm[wasmIndex * phases.length + 2].execution.wasm_dispatches =
    wasm[wasmIndex * phases.length + 1].execution.wasm_dispatches;
  expectFailure(() => validate(wasm, manifest, true), "recorded no WebAssembly dispatches");
  console.log("OK representative tier attribution self-test: phases, checksums, tier/runtime/synchronization/allocation inventory, exact GC pauses, environment parity, native-code lifetime, and heap state verified");
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
  const snapshots = collect(runner, manifest, quick),
    phaseDeltas = validate(snapshots, manifest, quick),
    report = render(phaseDeltas, manifest, "#", output || null),
    rawArtifact = artifact(snapshots, manifest, quick, info, runner);
  if (output) writeText(output, JSON.stringify(rawArtifact, null, 2) + "\n");
  if (markdown) writeText(markdown, report);
  process.stdout.write(report);
}

if (process.argv[1] === __filename) main();
