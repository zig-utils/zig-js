#!/usr/bin/env python3
"""Validate the issue #333 moving-GC pointer and relocation inventory."""

from __future__ import annotations

import argparse
import json
import re
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent
ALLOWED_CATEGORIES = {"edge", "embedding", "jit", "root", "weak"}
ALLOWED_OWNERSHIP = {"heap", "mixed_explicit"}


def require(condition: bool, message: str) -> None:
    if not condition:
        raise SystemExit(f"gc-relocation-inventory: {message}")


def cell_kinds(source: str) -> list[str]:
    match = re.search(r"pub const CellKind = enum \{(?P<body>.*?)\n\};", source, re.S)
    require(match is not None, "cannot locate CellKind")
    return re.findall(r"^\s{4}([a-z][a-z0-9_]*),\s*$", match.group("body"), re.M)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "inventory",
        nargs="?",
        type=Path,
        default=ROOT / "docs/.data/gc-relocation-inventory.json",
    )
    args = parser.parse_args()

    document = json.loads(args.inventory.read_text())
    require(document.get("schema_version") == 1, "unsupported schema")
    require(document.get("issue") == 333, "issue owner drift")
    require(document.get("status") == "explicit_stop_the_world", "relocation status drift")
    require(document.get("movement_enabled") is True, "explicit compaction must remain inventoried")
    require(
        document.get("placement_policy") == "dense_size_class_prefix_tail_evacuation",
        "compaction placement policy drift",
    )
    c_api = document.get("c_api", {})
    require(c_api.get("entrypoint") == "ZJSContextCompactGarbage", "C compaction entrypoint drift")
    require(c_api.get("request_entrypoint") == "ZJSContextRequestGarbageCompaction", "C compaction request entrypoint drift")
    require(
        c_api.get("statuses") == ["unsupported", "no_candidates", "out_of_memory", "compacted"],
        "C compaction status contract drift",
    )
    require(c_api.get("optional_outputs") == ["moved_cells", "moved_bytes"], "C movement outputs drift")
    require(c_api.get("non_moving_outputs") == "zero", "C non-moving outputs must remain deterministic")

    identity = document.get("identity", {})
    require(identity.get("forwarding_state") == "executable", "forwarding contract status drift")
    require("logical allocation" in identity.get("rule", ""), "stable identity rule missing")
    require("safepoint" in identity.get("old_address_lifetime", ""), "old-address lifetime is not bounded")

    contract = document.get("contract", {})
    contract_source = ROOT / contract.get("source", "")
    require(contract_source.is_file(), "relocation contract source missing")
    contract_text = contract_source.read_text()
    operations = contract.get("operations", [])
    require(operations == sorted(set(operations)), "contract operations must be unique and sorted")
    require(len(operations) >= 10, "relocation operation coverage unexpectedly small")
    for operation in operations:
        require(operation in contract_text, f"relocation operation drift: {operation}")

    gc_source = (ROOT / "src/gc.zig").read_text()
    declared_kinds = cell_kinds(gc_source)
    entries = document.get("cell_kinds", [])
    inventoried_kinds = [entry.get("kind") for entry in entries]
    require(inventoried_kinds == declared_kinds, "CellKind inventory drift")
    require(len(set(inventoried_kinds)) == len(inventoried_kinds), "duplicate CellKind entry")
    for entry in entries:
        require(entry.get("ownership") in ALLOWED_OWNERSHIP, f"{entry.get('kind')}: invalid ownership")
        require(entry.get("mobility") == "movable_when_policy_active", f"{entry.get('kind')}: mobility policy drift")
        require(str(entry.get("rewrite", "")).startswith("relocate"), f"{entry.get('kind')}: rewrite operation missing")
        source = ROOT / entry.get("source", "")
        require(source.is_file(), f"{entry.get('kind')}: source missing")
        require(entry.get("anchor", "") in source.read_text(), f"{entry.get('kind')}: source anchor drift")
        require(entry.get("rewrite", "") in gc_source, f"{entry.get('kind')}: executable rewriter missing")

    context_source = (ROOT / "src/context.zig").read_text()
    jit_compiler_source = (ROOT / "src/jit/compiler.zig").read_text()
    vm_source = (ROOT / "src/vm.zig").read_text()
    c_api_source = (ROOT / "src/c_api.zig").read_text()
    extension_header = (ROOT / "include/zig-js/Extensions.h").read_text()
    require("pub const ZJSGCCompactionStatus" in c_api_source, "C compaction status enum missing")
    require("export fn ZJSContextCompactGarbage" in c_api_source, "C compaction export missing")
    require("export fn ZJSContextRequestGarbageCompaction" in c_api_source, "C compaction request export missing")
    require("typedef enum ZJSGCCompactionStatus" in extension_header, "C compaction status header missing")
    require("bool ZJSContextRequestGarbageCompaction(JSContextRef ctx)" in extension_header, "C compaction request header missing")
    require("size_t* movedCells, size_t* movedBytes" in extension_header, "C movement output ABI missing")
    for hook in (
        "pub fn canRelocate",
        "pub fn relocateRoots",
        "pub fn relocateCell",
        "pub fn verifyRelocationRoots",
        "pub fn verifyRelocationCell",
    ):
        require(hook in gc_source, f"collector binding hook missing: {hook}")
    compact_start = context_source.index("pub fn compactGarbage")
    compact_end = context_source.index("fn collectQuiescentGarbage", compact_start)
    compact_source = context_source[compact_start:compact_end]
    require("pub fn compactGarbage" in compact_source, "checked Context compaction entrypoint missing")
    require("shouldRelocateCell" in context_source, "dense-prefix candidate policy missing")
    require("trimCompactedTailChunks" in context_source, "compacted-tail release policy missing")
    require("pub fn protectValue" in context_source, "Zig protected-value API missing")
    require("pub fn unprotectValue" in context_source, "Zig protected-value release API missing")
    require("gc_relocation_active" in context_source, "relocation activation token missing")
    require("self.enable_jit" not in compact_source, "quiescent pointer-free JIT is still rejected")
    require("self.gc_scan_native_stack" in compact_source, "conservative-stack fail-closed gate missing")
    require("self.gc_scan_parked_stacks" in compact_source, "parked-stack fail-closed gate missing")
    require("self.hasRunningJsThreads()" in compact_source, "running-thread fail-closed gate missing")
    require("has_active_interpreter" in compact_source, "active-interpreter fail-closed gate missing")
    require("compactGarbageAtMovingSafepoint" in compact_source, "moving-safepoint compaction entry missing")
    require("allowed_active_interpreter" in compact_source, "narrow active-interpreter allowance missing")
    require("gc_compaction_requested" in context_source, "explicit compaction request state missing")
    native_checkpoint_start = vm_source.index("fn nativeCheckpoint")
    native_checkpoint_end = vm_source.index("fn generatorStackAllocator", native_checkpoint_start)
    native_checkpoint_source = vm_source[native_checkpoint_start:native_checkpoint_end]
    require("vm.gc_precise_safepoint = true" in native_checkpoint_source, "native checkpoint precise declaration missing")
    require("vm.gc_moving_safepoint = true" in native_checkpoint_source, "native checkpoint moving declaration missing")
    require("vm.gc_moving_safepoint = saved_moving" in native_checkpoint_source, "native checkpoint moving restoration missing")
    require("vm.gc_precise_safepoint = saved_precise" in native_checkpoint_source, "native checkpoint precise restoration missing")
    require(
        jit_compiler_source.count("if (result.isObject() or result.isString()) return null;") >= 2,
        "constant-result JIT movable-pointer rejection missing",
    )
    require(".string, .object => null" in jit_compiler_source, "numeric JIT managed-kind rejection missing")
    require("Publish canonical frame words only at a" in jit_compiler_source, "native local materialization contract missing")
    require("Spill live numeric operand values" in jit_compiler_source, "native operand materialization contract missing")

    surfaces = document.get("pointer_surfaces", [])
    ids = [entry.get("id") for entry in surfaces]
    require(len(ids) >= 25, "pointer inventory unexpectedly small")
    require(len(set(ids)) == len(ids), "duplicate pointer surface")
    native_jit_frame = next((entry for entry in surfaces if entry.get("id") == "native-jit-frame"), None)
    require(native_jit_frame is not None, "native JIT frame inventory missing")
    require(
        native_jit_frame.get("disposition") == "allow_quiescent_or_declared_precise_checkpoint_reject_other_live_frames",
        "native JIT frame quiescent/rejection disposition drift",
    )
    all_tags: set[str] = set()
    categories: set[str] = set()
    for entry in surfaces:
        surface = entry.get("id", "<missing>")
        category = entry.get("category")
        require(category in ALLOWED_CATEGORIES, f"{surface}: invalid category")
        categories.add(category)
        require(entry.get("representation"), f"{surface}: pointer representation missing")
        require(entry.get("disposition"), f"{surface}: relocation disposition missing")
        tags = entry.get("tags", [])
        require(tags and len(tags) == len(set(tags)), f"{surface}: tags missing or duplicated")
        all_tags.update(tags)
        source = ROOT / entry.get("source", "")
        require(source.is_file(), f"{surface}: source missing")
        require(entry.get("anchor", "") in source.read_text(), f"{surface}: source anchor drift")

    require(categories == ALLOWED_CATEGORIES, "pointer category coverage drift")
    required_tags = document.get("required_tags", [])
    require(required_tags == sorted(set(required_tags)), "required tags must be unique and sorted")
    require(set(required_tags) == all_tags, "boundary tag coverage drift")

    print(
        "gc-relocation-inventory: "
        f"{len(entries)} cell kinds, {len(surfaces)} pointer surfaces, "
        f"{len(required_tags)} boundary tags; explicit stop-the-world movement enabled"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
