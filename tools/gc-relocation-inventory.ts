/** Validate the issue #333 moving-GC pointer and relocation inventory. */
import { readText } from "./lib/home";
declare const __dirname: string;
const ROOT = __dirname === "tools" ? "." : __dirname.slice(0, __dirname.lastIndexOf("/tools"));
const join = (left: string, right: string): string => `${left.replace(/\/$/, "")}/${right}`;
const requireValue = (condition: boolean, message: string): void => { if (!condition) throw new Error(`gc-relocation-inventory: ${message}`); };
const source = (relative: string, message: string): string => { try { return readText(join(ROOT, relative)); } catch (_) { throw new Error(`gc-relocation-inventory: ${message}`); } };
const same = (left: any, right: any): boolean => JSON.stringify(left) === JSON.stringify(right);
const unique = (values: any[]): any[] => Array.from(new Set(values));

const inventory = process.argv[2] || join(ROOT, "docs/.data/gc-relocation-inventory.json"), document = JSON.parse(readText(inventory));
requireValue(document.schema_version === 1, "unsupported schema");
requireValue(document.issue === 333, "issue owner drift");
requireValue(document.status === "explicit_stop_the_world", "relocation status drift");
requireValue(document.movement_enabled === true, "explicit compaction must remain inventoried");
requireValue(document.placement_policy === "dense_size_class_prefix_tail_evacuation", "compaction placement policy drift");
const automatic = document.automatic_policy || {};
requireValue(automatic.quiescent_full_gc === "enabled", "automatic quiescent compaction policy missing");
requireValue(automatic.trigger === "reclaimable_fragmented_backing_bytes >= 524288", "automatic compaction trigger drift");
requireValue(automatic.shared_mid_script === "enabled_at_declared_moving_safepoints", "shared/mid-script policy drift");
requireValue(automatic.shared_publication_evidence === "open_release_gate", "shared/mid-script publication gate drift");
const telemetry = ["requests", "attempts", "compacted", "no_candidates", "unsupported", "out_of_memory", "moved_cells", "moved_bytes", "shared_attempts", "shared_timeouts", "shared_rendezvous_ns_total", "shared_rendezvous_ns_max", "shared_pause_ns_total", "shared_pause_ns_max"];
requireValue(same(automatic.telemetry, telemetry), "automatic compaction telemetry drift");
const cApi = document.c_api || {};
requireValue(cApi.entrypoint === "ZJSContextCompactGarbage", "C compaction entrypoint drift");
requireValue(cApi.request_entrypoint === "ZJSContextRequestGarbageCompaction", "C compaction request entrypoint drift");
requireValue(same(cApi.statuses, ["unsupported", "no_candidates", "out_of_memory", "compacted"]), "C compaction status contract drift");
requireValue(same(cApi.optional_outputs, ["moved_cells", "moved_bytes"]), "C movement outputs drift");
requireValue(cApi.non_moving_outputs === "zero", "C non-moving outputs must remain deterministic");
const identity = document.identity || {};
requireValue(identity.forwarding_state === "executable", "forwarding contract status drift");
requireValue(String(identity.rule || "").includes("logical allocation"), "stable identity rule missing");
requireValue(String(identity.old_address_lifetime || "").includes("safepoint"), "old-address lifetime is not bounded");
const contract = document.contract || {}, contractText = source(contract.source || "", "relocation contract source missing"), operations = contract.operations || [];
requireValue(same(operations, unique(operations).sort()), "contract operations must be unique and sorted");
requireValue(operations.length >= 10, "relocation operation coverage unexpectedly small");
for (const operation of operations) requireValue(contractText.includes(operation), `relocation operation drift: ${operation}`);

const gcSource = source("src/gc.zig", "collector source missing"), enumStart = gcSource.indexOf("pub const CellKind = enum {");
requireValue(enumStart >= 0, "cannot locate CellKind");
const enumBody = gcSource.slice(enumStart, gcSource.indexOf("\n};", enumStart)), declaredKinds: string[] = [];
for (const line of enumBody.split("\n")) { const match = /^    ([a-z][a-z0-9_]*),\s*$/.exec(line); if (match) declaredKinds.push(match[1]); }
const entries = document.cell_kinds || [], inventoriedKinds = entries.map((entry: any) => entry.kind);
requireValue(same(inventoriedKinds, declaredKinds), "CellKind inventory drift");
requireValue(unique(inventoriedKinds).length === inventoriedKinds.length, "duplicate CellKind entry");
for (const entry of entries) {
  requireValue(["heap", "mixed_explicit"].includes(entry.ownership), `${entry.kind}: invalid ownership`);
  requireValue(entry.mobility === "movable_when_policy_active", `${entry.kind}: mobility policy drift`);
  requireValue(String(entry.rewrite || "").startsWith("relocate"), `${entry.kind}: rewrite operation missing`);
  const text = source(entry.source || "", `${entry.kind}: source missing`);
  requireValue(text.includes(entry.anchor || ""), `${entry.kind}: source anchor drift`);
  requireValue(gcSource.includes(entry.rewrite || ""), `${entry.kind}: executable rewriter missing`);
}

const context = source("src/context.zig", "context source missing"), jit = source("src/jit/compiler.zig", "JIT compiler source missing"), vm = source("src/vm.zig", "VM source missing"), cSource = source("src/c_api.zig", "C API source missing"), header = source("include/zig-js/Extensions.h", "extension header missing");
for (const check of [[cSource, "pub const ZJSGCCompactionStatus", "C compaction status enum missing"], [cSource, "export fn ZJSContextCompactGarbage", "C compaction export missing"], [cSource, "export fn ZJSContextRequestGarbageCompaction", "C compaction request export missing"], [header, "typedef enum ZJSGCCompactionStatus", "C compaction status header missing"], [header, "bool ZJSContextRequestGarbageCompaction(JSContextRef ctx)", "C compaction request header missing"], [header, "size_t* movedCells, size_t* movedBytes", "C movement output ABI missing"]]) requireValue(check[0].includes(check[1]), check[2]);
for (const hook of ["pub fn canRelocate", "pub fn relocateRoots", "pub fn relocateCell", "pub fn verifyRelocationRoots", "pub fn verifyRelocationCell"]) requireValue(gcSource.includes(hook), `collector binding hook missing: ${hook}`);
const compactStart = context.indexOf("pub fn compactGarbage"), compact = context.slice(compactStart, context.indexOf("fn collectQuiescentGarbage", compactStart));
const contextChecks = [
  [compact, "pub fn compactGarbage", "checked Context compaction entrypoint missing"], [context, "shouldRelocateCell", "dense-prefix candidate policy missing"], [context, "trimCompactedTailChunks", "compacted-tail release policy missing"], [context, "gc_auto_compaction_min_reclaimable_bytes: usize = 512 * 1024", "automatic compaction threshold missing"], [context, "pub fn compactionPressure", "automatic compaction pressure snapshot missing"], [context, "automaticGcCompactionStats", "automatic compaction telemetry snapshot missing"], [context, "runAutomaticCompactionWithConductor", "automatic compaction runner missing"], [context, "enable_gc automatic quiescent compaction follows full-GC slab pressure", "automatic compaction regression test missing"], [context, "parallel_js automatic compaction relocates at a shared moving stop", "automatic shared compaction regression test missing"], [context, "allCooperativePeersAtMovingSafepoint", "shared moving-stop predicate missing"], [context, "gc_auto_compaction_shared_attempts", "shared compaction telemetry missing"], [context, "pub fn protectValue", "Zig protected-value API missing"], [context, "pub fn unprotectValue", "Zig protected-value release API missing"], [context, "gc_relocation_active", "relocation activation token missing"], [compact, "self.gc_scan_native_stack", "conservative-stack fail-closed gate missing"], [compact, "self.gc_scan_parked_stacks", "parked-stack fail-closed gate missing"], [compact, "self.hasRunningJsThreads()", "running-thread fail-closed gate missing"], [compact, "has_active_interpreter", "active-interpreter fail-closed gate missing"], [compact, "compactGarbageAtMovingSafepoint", "moving-safepoint compaction entry missing"], [compact, "allowed_active_interpreter", "narrow active-interpreter allowance missing"], [context, "gc_compaction_requested", "explicit compaction request state missing"],
];
for (const check of contextChecks) requireValue(check[0].includes(check[1]), check[2]);
requireValue(!compact.includes("self.enable_jit"), "quiescent pointer-free JIT is still rejected");
const checkpointStart = vm.indexOf("fn nativeCheckpoint"), checkpoint = vm.slice(checkpointStart, vm.indexOf("fn generatorStackAllocator", checkpointStart));
for (const check of [["vm.gc_precise_safepoint = true", "native checkpoint precise declaration missing"], ["vm.gc_moving_safepoint = true", "native checkpoint moving declaration missing"], ["vm.gc_moving_safepoint = saved_moving", "native checkpoint moving restoration missing"], ["vm.gc_precise_safepoint = saved_precise", "native checkpoint precise restoration missing"]]) requireValue(checkpoint.includes(check[0]), check[1]);
requireValue(jit.split("if (result.isObject() or result.isString()) return null;").length - 1 >= 2, "constant-result JIT movable-pointer rejection missing");
for (const check of [[".string, .object => null", "numeric JIT managed-kind rejection missing"], ["Publish canonical frame words only at a", "native local materialization contract missing"], ["Spill live numeric operand values", "native operand materialization contract missing"]]) requireValue(jit.includes(check[0]), check[1]);

const surfaces = document.pointer_surfaces || [], ids = surfaces.map((entry: any) => entry.id);
requireValue(ids.length >= 25, "pointer inventory unexpectedly small"); requireValue(unique(ids).length === ids.length, "duplicate pointer surface");
const native = surfaces.find((entry: any) => entry.id === "native-jit-frame");
requireValue(!!native, "native JIT frame inventory missing");
requireValue(native.disposition === "allow_quiescent_or_declared_precise_checkpoint_reject_other_live_frames", "native JIT frame quiescent/rejection disposition drift");
const tags: string[] = [], categories: string[] = [];
for (const entry of surfaces) {
  const id = entry.id || "<missing>";
  requireValue(["edge", "embedding", "jit", "root", "weak"].includes(entry.category), `${id}: invalid category`); categories.push(entry.category);
  requireValue(!!entry.representation, `${id}: pointer representation missing`); requireValue(!!entry.disposition, `${id}: relocation disposition missing`);
  requireValue(Array.isArray(entry.tags) && entry.tags.length > 0 && unique(entry.tags).length === entry.tags.length, `${id}: tags missing or duplicated`); tags.push(...entry.tags);
  requireValue(source(entry.source || "", `${id}: source missing`).includes(entry.anchor || ""), `${id}: source anchor drift`);
}
requireValue(same(unique(categories).sort(), ["edge", "embedding", "jit", "root", "weak"]), "pointer category coverage drift");
const requiredTags = document.required_tags || [];
requireValue(same(requiredTags, unique(requiredTags).sort()), "required tags must be unique and sorted");
requireValue(same(unique(tags).sort(), requiredTags.slice().sort()), "boundary tag coverage drift");
console.log(`gc-relocation-inventory: ${entries.length} cell kinds, ${surfaces.length} pointer surfaces, ${requiredTags.length} boundary tags; explicit, automatic-quiescent, and declared shared-safepoint movement enabled`);
