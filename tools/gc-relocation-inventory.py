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
    for hook in ("pub fn canRelocate", "pub fn relocateRoots", "pub fn relocateCell"):
        require(hook in gc_source, f"collector binding hook missing: {hook}")
    require("pub fn compactGarbage" in context_source, "checked Context compaction entrypoint missing")
    require("gc_relocation_active" in context_source, "relocation activation token missing")
    require("self.enable_jit" in context_source, "JIT fail-closed gate missing")
    require("self.gc_scan_native_stack" in context_source, "conservative-stack fail-closed gate missing")
    require("has_active_interpreter" in context_source, "active-interpreter fail-closed gate missing")

    surfaces = document.get("pointer_surfaces", [])
    ids = [entry.get("id") for entry in surfaces]
    require(len(ids) >= 25, "pointer inventory unexpectedly small")
    require(len(set(ids)) == len(ids), "duplicate pointer surface")
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
