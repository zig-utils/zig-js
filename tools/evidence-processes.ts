/** Shared fail-closed process-quality policy for performance evidence collectors. */

export const MINIMUM_PROCESS_CPU_OCCUPANCY = 0.6;

type ProcessRow = { pid: number; parent: number; command: string };

function processRows(source: string): ProcessRow[] {
  return source.split("\n").map((line) => {
    const match = /^\s*([0-9]+)\s+([0-9]+)\s+(.+)$/.exec(line);
    return match ? { pid: Number(match[1]), parent: Number(match[2]), command: match[3].trim() } : null;
  }).filter(Boolean) as ProcessRow[];
}

function processBasename(command: string): [string, string] {
  const executable = command.split(/\s+/, 1)[0], slash = executable.lastIndexOf("/");
  return [executable, executable.slice(slash + 1)];
}

function relatedProcesses(rows: ProcessRow[], selfPid: number): Set<number> {
  const parents = new Map(rows.map((row) => [row.pid, row.parent])),
    related = new Set<number>(),
    descendants = new Set<number>([selfPid]);
  for (let pid = selfPid; pid > 0 && !related.has(pid); pid = parents.get(pid) || 0) related.add(pid);
  let changed = true;
  while (changed) {
    changed = false;
    for (const row of rows) if (!descendants.has(row.pid) && descendants.has(row.parent)) {
      descendants.add(row.pid);
      changed = true;
    }
  }
  for (const pid of descendants) related.add(pid);
  return related;
}

export function competingEvidenceProcesses(source: string, selfPid: number): string[] {
  const rows = processRows(source), related = relatedProcesses(rows, selfPid);
  return rows.filter((row) => {
    if (related.has(row.pid)) return false;
    const [executable, basename] = processBasename(row.command);
    if (basename === "zig" || basename === "maker") return true;
    if (["home-url-final", "unit-test-parallel", "threads-test", "test262", "frontend-parse-benchmark"].includes(basename)) return true;
    return basename === "test" &&
      (executable.includes("/.zig-cache/") || executable.startsWith("/tmp/home-") || executable.startsWith("/private/tmp/home-"));
  }).map((row) => `${row.pid} ${row.command}`);
}

export function processCpuOccupancy(processWall: number, user: number, system: number): number {
  if (![processWall, user, system].every((value) => Number.isFinite(value) && value >= 0)) return NaN;
  return processWall === 0 ? 1 : Math.min(1, (user + system) / processWall);
}
