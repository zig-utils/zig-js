/** Generate and validate the issue #659 VM quickening inventory. */
import { readText, writeText } from "./lib/home";

declare const __dirname: string;
const ROOT =
  __dirname === "tools"
    ? "."
    : __dirname.slice(0, __dirname.lastIndexOf("/tools"));
const path = (relative: string): string => `${ROOT}/${relative}`;
const INVENTORY = path("docs/.data/vm-quickening-inventory-v1.json");
const DOCUMENT = path("docs/advanced/vm-quickening.md");
const ENTRY_IDS = [
  "property-inline-cache",
  "quick-global-binding",
  "literal-shape-transition",
  "property-update-trace",
  "four-property-loop",
  "array-opcode-fast-paths",
  "packed-array-sum-loop",
  "packed-array-push-loop",
  "polymorphic-property-loop",
  "fixed-shape-object-allocation-loop",
  "numeric-leaf-call",
  "numeric-call-loop",
  "reusable-immediate-closure",
  "numeric-recurrence",
  "observable-numeric-recurrence",
  "binary-arithmetic-site",
  "native-direct-call",
];
const UNSUPPORTED_IDS = [
  "property-dispatch",
  "index-dispatch",
  "call-dispatch",
  "control-dispatch",
  "allocation-dispatch",
];
const LEGACY_ENTRY_IDS = [
  "four-property-loop",
  "packed-array-sum-loop",
  "packed-array-push-loop",
  "polymorphic-property-loop",
  "fixed-shape-object-allocation-loop",
  "numeric-call-loop",
  "reusable-immediate-closure",
  "numeric-recurrence",
  "observable-numeric-recurrence",
];
const CLASSIFICATIONS = [
  "general_adaptive",
  "bounded_structural",
  "legacy_narrow",
];
const IMPLEMENTATION_KINDS = [
  "adaptive_inline_cache",
  "adaptive_site_cache",
  "bounded_trace_plan",
  "legacy_pattern_kernel",
  "opcode_fast_path",
  "native_tier_entry",
];
const fail = (message: string): never => {
  throw new Error(`vm-quickening-inventory: ${message}`);
};
const requireValue = (condition: boolean, message: string): void => {
  if (!condition) fail(message);
};
const same = (left: any, right: any): boolean =>
  JSON.stringify(left) === JSON.stringify(right);
const sortedUnique = (values: string[]): string[] =>
  Array.from(new Set(values)).sort();
const strings = (value: any, field: string): string[] => {
  requireValue(Array.isArray(value) && value.length > 0, `${field} must be non-empty`);
  for (const item of value)
    requireValue(typeof item === "string" && item.length > 0, `${field} contains an invalid value`);
  requireValue(value.length === new Set(value).size, `${field} contains duplicates`);
  return value;
};

function repositoryText(relative: any, field: string): string {
  requireValue(
    typeof relative === "string" &&
      relative.length > 0 &&
      !relative.startsWith("/") &&
      !relative.split("/").includes(".."),
    `${field} must stay inside the repository`,
  );
  try {
    return readText(path(relative));
  } catch (_) {
    fail(`${field} does not exist: ${relative}`);
  }
}

function unionTags(source: string, type: string): string[] {
  const marker = `const ${type} = union(enum) {`,
    start = source.indexOf(marker);
  requireValue(start >= 0, `missing tagged type ${type}`);
  const body = source.slice(start + marker.length);
  let depth = 1;
  const tags: string[] = [];
  for (const line of body.split("\n")) {
    if (depth === 1) {
      const match = /^    ([a-z][a-z0-9_]*)(?::|,)\s*/.exec(line);
      if (match) tags.push(match[1]);
    }
    depth += (line.match(/{/g) || []).length;
    depth -= (line.match(/}/g) || []).length;
    if (depth === 0) break;
  }
  return tags;
}

function enumTags(source: string, type: string): string[] {
  const marker = `pub const ${type} = enum(u8) {`,
    start = source.indexOf(marker);
  requireValue(start >= 0, `missing attributed enum ${type}`);
  const body = source.slice(start + marker.length), tags: string[] = [];
  for (const line of body.split("\n")) {
    if (line.startsWith("};")) break;
    const match = /^    ([a-z][a-z0-9_]*),\s*/.exec(line);
    if (match) tags.push(match[1]);
  }
  return tags;
}

function sourceContract(bytecode: string, vm: string, interpreter: string): any {
  const planTypes = Array.from(
    vm.matchAll(/^const (Quick[A-Za-z]+Plan) =/gm),
    (match) => match[1],
  ).sort();
  const unionTypes = Array.from(
    vm.matchAll(/^const (Quick[A-Za-z]+) = union\(enum\) \{/gm),
    (match) => match[1],
  ).sort();
  const taggedTypes: Record<string, string[]> = {};
  for (const type of unionTypes) taggedTypes[type] = unionTags(vm, type);

  const chunkStart = bytecode.indexOf("pub const Chunk = struct {");
  const chunkEnd = bytecode.indexOf("    pub fn init(", chunkStart);
  requireValue(chunkStart >= 0 && chunkEnd > chunkStart, "cannot locate Chunk metadata");
  const chunk = bytecode.slice(chunkStart, chunkEnd);
  const chunkFields = Array.from(
    chunk.matchAll(/^    (quick_[a-z0-9_]+):/gm),
    (match) => match[1],
  ).sort();
  const candidates = Array.from(
    bytecode.matchAll(/^pub const (quick_[a-z0-9_]+_candidate):/gm),
    (match) => match[1],
  ).sort();
  const globalCounters = Array.from(
    vm.matchAll(/^var (quick_[a-z0-9_]+): std\.atomic\.Value/gm),
    (match) => match[1],
  )
    .filter((name) => !name.endsWith("_test_enabled"));
  const attributedCounters = enumTags(interpreter, "QuickBinaryMetric")
    .map((name) => `quick_binary_${name}`);
  const counters = globalCounters.concat(attributedCounters).sort();
  return {
    plan_types: planTypes,
    tagged_types: taggedTypes,
    chunk_metadata_fields: chunkFields,
    structural_candidate_flags: candidates,
    observability_counters: counters,
  };
}

function validateAnchors(anchors: any, field: string, test: boolean): void {
  requireValue(Array.isArray(anchors) && anchors.length > 0, `${field} must be non-empty`);
  for (let index = 0; index < anchors.length; index += 1) {
    const anchor = anchors[index];
    requireValue(anchor && typeof anchor === "object", `${field}[${index}] must be an object`);
    if (test)
      requireValue(
        anchor.path === "src/bytecode.zig" ||
          anchor.path === "src/vm.zig" ||
          anchor.path === "src/context.zig",
        `${field}[${index}] must point at an owned engine test`,
      );
    else
      requireValue(
        anchor.path === "src/bytecode.zig" ||
          anchor.path === "src/vm.zig" ||
          anchor.path === "src/interpreter.zig",
        `${field}[${index}] must point at production VM support`,
      );
    const source = repositoryText(anchor.path, `${field}[${index}].path`);
    requireValue(
      typeof anchor.text === "string" &&
        anchor.text.length > 0 &&
        source.includes(anchor.text),
      `${field}[${index}] anchor drift: ${JSON.stringify(anchor.text)}`,
    );
  }
}

function validateInventory(data: any): any {
  requireValue(data.schema_version === 1, "schema_version must be 1");
  requireValue(data.kind === "zig_js_vm_quickening_inventory", "kind drift");
  requireValue(data.issue === 659 && data.parent_issue === 498, "issue ownership drift");
  requireValue(data.status === "inventory_only_no_performance_claim", "status must reject a performance claim");
  requireValue(Array.isArray(data.entries), "entries must be an array");
  const ids = data.entries.map((entry: any) => entry?.id);
  requireValue(ids.length === new Set(ids).size, "duplicate entry identity");
  requireValue(same(ids, ENTRY_IDS), `entry identity drift: expected ${JSON.stringify(ENTRY_IDS)}, found ${JSON.stringify(ids)}`);

  const metrics: string[] = [];
  for (const entry of data.entries) {
    const prefix = entry.id;
    requireValue(typeof entry.title === "string" && entry.title.length > 0, `${prefix}: title missing`);
    requireValue(CLASSIFICATIONS.includes(entry.classification), `${prefix}: unsupported classification`);
    requireValue(IMPLEMENTATION_KINDS.includes(entry.implementation_kind), `${prefix}: unsupported implementation kind`);
    requireValue(entry.coverage_status === "covered_guarded", `${prefix}: unsupported coverage status`);
    if (LEGACY_ENTRY_IDS.includes(entry.id)) {
      requireValue(entry.implementation_kind === "legacy_pattern_kernel", `${prefix}: known legacy identity changed implementation kind`);
      requireValue(entry.classification === "legacy_narrow", `${prefix}: legacy kernel must remain legacy_narrow`);
    }
    if (entry.implementation_kind === "legacy_pattern_kernel")
      requireValue(entry.classification === "legacy_narrow", `${prefix}: legacy kernel must remain legacy_narrow`);
    strings(entry.surfaces, `${prefix}.surfaces`);
    strings(entry.guards, `${prefix}.guards`);
    strings(entry.miss_behavior, `${prefix}.miss_behavior`);
    requireValue(typeof entry.metadata_lifetime === "string" && entry.metadata_lifetime.length > 0, `${prefix}: metadata lifetime missing`);
    requireValue(typeof entry.no_gil_synchronization === "string" && entry.no_gil_synchronization.length > 0, `${prefix}: no-GIL synchronization ruling missing`);
    requireValue(typeof entry.observable_steps_debugger === "string" && entry.observable_steps_debugger.length > 0, `${prefix}: observability ruling missing`);
    validateAnchors(entry.source_anchors, `${prefix}.source_anchors`, false);
    validateAnchors(entry.test_anchors, `${prefix}.test_anchors`, true);
    if (!Array.isArray(entry.metrics)) fail(`${prefix}.metrics must be an array`);
    for (const metric of entry.metrics) {
      requireValue(typeof metric === "string" && metric.length > 0, `${prefix}: invalid metric`);
      metrics.push(metric);
    }
  }
  requireValue(metrics.length === new Set(metrics).size, "observability counter is owned by multiple entries");

  requireValue(Array.isArray(data.unsupported_families), "unsupported_families must be an array");
  const unsupportedIds = data.unsupported_families.map((entry: any) => entry?.id);
  requireValue(same(unsupportedIds, UNSUPPORTED_IDS), `unsupported family drift: expected ${JSON.stringify(UNSUPPORTED_IDS)}, found ${JSON.stringify(unsupportedIds)}`);
  for (const family of data.unsupported_families) {
    requireValue(family.status === "unsupported", `${family.id}: unsupported family has an invalid status`);
    requireValue(Array.isArray(family.covered_by) && family.covered_by.length === 0, `${family.id}: unsupported family must not be counted as covered`);
    strings(family.remaining, `${family.id}.remaining`);
    requireValue(typeof family.fallback === "string" && family.fallback.length > 0, `${family.id}: exact fallback missing`);
  }

  const bytecode = repositoryText("src/bytecode.zig", "bytecode source"),
    vm = repositoryText("src/vm.zig", "VM source"),
    interpreter = repositoryText("src/interpreter.zig", "interpreter source"),
    actual = sourceContract(bytecode, vm, interpreter),
    contract = data.runtime_contract;
  requireValue(contract && typeof contract === "object", "runtime_contract must be an object");
  requireValue(Array.isArray(contract.plan_types), "runtime_contract.plan_types must be an array");
  requireValue(contract.tagged_types && typeof contract.tagged_types === "object", "runtime_contract.tagged_types must be an object");
  requireValue(Array.isArray(contract.chunk_metadata_fields), "runtime_contract.chunk_metadata_fields must be an array");
  requireValue(Array.isArray(contract.structural_candidate_flags), "runtime_contract.structural_candidate_flags must be an array");
  requireValue(Array.isArray(contract.observability_counters), "runtime_contract.observability_counters must be an array");
  requireValue(same(contract.plan_types.slice().sort(), actual.plan_types), "quick plan type inventory drift");
  requireValue(same(Object.keys(contract.tagged_types).sort(), Object.keys(actual.tagged_types).sort()), "quick tagged type inventory drift");
  for (const type of Object.keys(actual.tagged_types))
    requireValue(same(contract.tagged_types[type], actual.tagged_types[type]), `${type} tag inventory drift`);
  requireValue(same(contract.chunk_metadata_fields.slice().sort(), actual.chunk_metadata_fields), "Chunk quick metadata inventory drift");
  requireValue(same(contract.structural_candidate_flags.slice().sort(), actual.structural_candidate_flags), "structural candidate inventory drift");
  requireValue(same(contract.observability_counters.slice().sort(), actual.observability_counters), "declared quick observability counter inventory drift");
  requireValue(same(sortedUnique(metrics), actual.observability_counters), "quick observability counter inventory drift");
  return data;
}

function renderMarkdown(data: any): string {
  const counts: Record<string, number> = {};
  for (const classification of CLASSIFICATIONS) counts[classification] = 0;
  for (const entry of data.entries) counts[entry.classification] += 1;
  const lines = [
    "---",
    "title: VM quickening inventory",
    "description: The guarded bytecode-VM caches and kernels, including the narrow legacy patterns that are not general quickening coverage.",
    "---",
    "",
    "# VM quickening inventory",
    "",
    "<!-- Generated by tools/vm-quickening-inventory.ts; do not edit by hand. -->",
    "",
    "This page is the architecture boundary for [issue #659](https://github.com/zig-utils/zig-js/issues/659) under the [fast no-JIT roadmap #498](https://github.com/zig-utils/zig-js/issues/498). It inventories existing guarded shortcuts; it publishes **no performance claim** and does not count tree-walker or ordinary-bytecode fallback as quickening coverage.",
    "",
    "The complete machine contract—including every guard, miss/dequickening rule, metadata lifetime, no-GIL synchronization ruling, debugger/step boundary, source anchor, and test anchor—is [`vm-quickening-inventory-v1.json`](../.data/vm-quickening-inventory-v1.json).",
    "",
    "## Classification boundary",
    "",
    "| classification | meaning | current families |",
    "| --- | --- | ---: |",
    `| \`general_adaptive\` | Site/opcode behavior selected from runtime identity, shape, or representation guards rather than a whole benchmark-shaped body. | ${counts.general_adaptive} |`,
    `| \`bounded_structural\` | A bounded expression/trace decoder with explicit accepted operations and size limits. | ${counts.bounded_structural} |`,
    `| \`legacy_narrow\` | An exact bytecode-pattern kernel. It is useful implementation history, not broad dispatch-family coverage. | ${counts.legacy_narrow} |`,
    "",
    "## Implemented guarded families",
    "",
    "| family | classification | surface | miss/dequickening boundary |",
    "| --- | --- | --- | --- |",
  ];
  for (const entry of data.entries)
    lines.push(
      `| \`${entry.id}\` | \`${entry.classification}\` | ${entry.surfaces.join("; ")} | ${entry.miss_behavior.join("; ")} |`,
    );
  lines.push(
    "",
    "Every legacy pattern above remains labeled `legacy_narrow`; none is used as evidence that its broader property, index, call, arithmetic, control, or allocation family is covered.",
    "",
    "## Explicitly unsupported broad families",
    "",
    "| family | remaining general work | exact fallback |",
    "| --- | --- | --- |",
  );
  for (const family of data.unsupported_families)
    lines.push(
      `| \`${family.id}\` | ${family.remaining.join("; ")} | ${family.fallback} |`,
    );
  lines.push(
    "",
    "## Drift gate",
    "",
    `The validator binds this inventory to ${data.runtime_contract.plan_types.length} plan types, ${Object.keys(data.runtime_contract.tagged_types).length} tagged quickening types, ${data.runtime_contract.chunk_metadata_fields.length} chunk metadata fields, ${data.runtime_contract.structural_candidate_flags.length} structural-candidate flags, and ${data.runtime_contract.observability_counters.length} test observability counters. Missing or duplicate identities, missing source/test anchors, unknown status values, and any legacy kernel relabeled as general all fail closed.`,
    "",
  );
  return lines.join("\n");
}

function expectFailure(data: any, expected: string): void {
  try {
    validateInventory(data);
  } catch (error) {
    if (String(error).includes(expected)) return;
    fail(`self-test expected ${expected}, got ${String(error)}`);
  }
  fail(`self-test expected failure containing ${expected}`);
}

function selfTest(data: any): void {
  const clone = (value: any): any => JSON.parse(JSON.stringify(value));
  validateInventory(data);
  const missing = clone(data);
  missing.entries.pop();
  expectFailure(missing, "entry identity drift");
  const duplicate = clone(data);
  duplicate.entries.push(duplicate.entries[0]);
  expectFailure(duplicate, "duplicate entry identity");
  const anchor = clone(data);
  anchor.entries[0].source_anchors[0].text = "missing source anchor witness";
  expectFailure(anchor, "anchor drift");
  const status = clone(data);
  status.entries[0].coverage_status = "general_enough";
  expectFailure(status, "unsupported coverage status");
  const unsupportedStatus = clone(data);
  unsupportedStatus.unsupported_families[0].status = "covered_by_fallback";
  expectFailure(unsupportedStatus, "unsupported family has an invalid status");
  const legacy = clone(data);
  legacy.entries.find((entry: any) => entry.implementation_kind === "legacy_pattern_kernel").classification = "general_adaptive";
  expectFailure(legacy, "legacy kernel must remain legacy_narrow");
  console.log("vm quickening inventory self-test: fail-closed identity, anchors, status, and legacy labels verified");
}

const args = process.argv.slice(2),
  data = validateInventory(JSON.parse(readText(INVENTORY)));
if (args.length === 1 && args[0] === "--self-test") {
  selfTest(data);
} else if (args.length === 1 && args[0] === "--write") {
  writeText(DOCUMENT, renderMarkdown(data));
  console.log(`vm quickening inventory written: ${DOCUMENT}`);
} else if (args.length === 0) {
  const rendered = renderMarkdown(data);
  requireValue(readText(DOCUMENT) === rendered, "Markdown drift; run tools/vm-quickening-inventory.ts --write");
  console.log(`vm quickening inventory: ${data.entries.length} guarded families, ${data.unsupported_families.length} explicit unsupported families`);
} else {
  fail(`unknown arguments: ${args.join(" ")}`);
}
