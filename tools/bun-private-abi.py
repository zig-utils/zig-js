#!/usr/bin/env python3
"""Generate and verify Bun's revision-pinned core src/jsc extern inventory."""

from __future__ import annotations

import argparse
import hashlib
import importlib.util
import json
import re
import subprocess
import sys
from collections import Counter
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
OUTPUT = ROOT / "docs/abi/bun-private-core-4982b91e-inventory.json"
DIAGNOSTIC_CONTRACT = ROOT / "docs/abi/bun-diagnostic-inspector-4982b91e.json"
INSPECTOR_AGENTS_CONTRACT = ROOT / "docs/abi/bun-inspector-agents-4982b91e.json"
HTTP_SERVER_INSPECTOR_CONTRACT = ROOT / "docs/abi/bun-http-server-inspector-4982b91e.json"
PROCESS_SIGNAL_CONTRACT = ROOT / "docs/abi/bun-process-signal-4982b91e.json"
MODULE_REGISTRY_SHIMS_CONTRACT = ROOT / "docs/abi/bun-module-registry-shims-4982b91e.json"
HEAP_SNAPSHOT_CONTRACT = ROOT / "docs/abi/heap-snapshot-serialization-403.json"
CPU_PROFILE_CONTRACT = ROOT / "docs/abi/cpu-profile-sampling-404.json"
HOME_INVENTORY = ROOT / "docs/abi/home-private-7ed99c02-inventory.json"
PUBLIC_INVENTORY = ROOT / "docs/c-api/jsc-public-api-macos-27.0.json"
EXPORT_SOURCE = ROOT / "src/c_api.zig"
PROFILE_ID = "bun-private-core-4982b91e"
REVISION = "4982b91e3702094330f3be3883354c52b8c01323"
SOURCE_ROOT = Path("src/jsc")
PLATFORM_IMPORTS = {"gnu_get_libc_version"}
EXPORT_RE = re.compile(r"^export fn ([A-Za-z_][A-Za-z0-9_]*)\s*\(", re.M)

scanner_spec = importlib.util.spec_from_file_location(
    "private_abi_scanner", ROOT / "tools/home-private-abi.py"
)
if scanner_spec is None or scanner_spec.loader is None:
    raise RuntimeError("cannot load the shared private ABI scanner")
scanner = importlib.util.module_from_spec(scanner_spec)
scanner_spec.loader.exec_module(scanner)


def fail(message: str) -> None:
    print(f"Bun private ABI audit: {message}", file=sys.stderr)
    raise SystemExit(1)


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def revision(root: Path) -> str:
    try:
        return subprocess.check_output(
            ["git", "-C", str(root), "rev-parse", "HEAD"], text=True
        ).strip()
    except (OSError, subprocess.CalledProcessError) as error:
        fail(f"cannot determine Bun revision at {root}: {error}")


def expected_classification(name: str, public_names: set[str]) -> str:
    if name in public_names:
        return "public_c_api"
    if name in PLATFORM_IMPORTS:
        return "platform_import"
    if name in scanner.CONSUMER_PROVIDED:
        return "consumer_provided"
    return "private_jsc"


def apply_status(entries: list[dict[str, object]]) -> None:
    exports = set(EXPORT_RE.findall(EXPORT_SOURCE.read_text()))
    public_data = json.loads(PUBLIC_INVENTORY.read_text())
    public_names = {entry["name"] for entry in public_data["functions"]}
    for entry in entries:
        entry["classification"] = expected_classification(str(entry["name"]), public_names)
        if entry["classification"] != "private_jsc":
            if entry["classification"] == "public_c_api":
                entry["status"] = "implemented"
            else:
                entry["status"] = "external"
            entry.pop("issue", None)
            entry.pop("implementation", None)
            continue
        if entry["name"] in exports:
            entry["status"] = "implemented"
            entry.pop("issue", None)
            entry["implementation"] = "src/c_api.zig"
        else:
            entry["status"] = "pending"
            entry["issue"] = 164
            entry.pop("implementation", None)


def refresh_implementation_status(data: dict[str, object]) -> None:
    apply_status(data["declarations"])
    statuses = Counter(str(entry["status"]) for entry in data["declarations"])
    classifications = Counter(str(entry["classification"]) for entry in data["declarations"])
    data["totals"]["by_status"] = dict(sorted(statuses.items()))
    data["totals"]["by_classification"] = dict(sorted(classifications.items()))


def home_comparison(entries: list[dict[str, object]]) -> dict[str, object]:
    home = json.loads(HOME_INVENTORY.read_text())["declarations"]
    home_by_name = {entry["name"]: entry for entry in home}
    bun_by_name = {entry["name"]: entry for entry in entries}
    shared = sorted(home_by_name.keys() & bun_by_name.keys())
    changed = sorted(
        name for name in shared
        if home_by_name[name]["declaration"] != bun_by_name[name]["declaration"]
    )
    return {
        "home_profile": "home-private-7ed99c02",
        "shared_symbols": len(shared),
        "bun_only_symbols": sorted(bun_by_name.keys() - home_by_name.keys()),
        "home_only_symbols": sorted(home_by_name.keys() - bun_by_name.keys()),
        "signature_changed_symbols": changed,
    }


def generate(bun_root: Path) -> dict[str, object]:
    actual_revision = revision(bun_root)
    if actual_revision != REVISION:
        fail(f"Bun revision mismatch: {actual_revision} != {REVISION}")
    public_data = json.loads(PUBLIC_INVENTORY.read_text())
    public_names = {entry["name"] for entry in public_data["functions"]}
    absolute_source_root = bun_root / SOURCE_ROOT
    entries: list[dict[str, object]] = []
    source_hashes: dict[str, str] = {}
    for path in sorted(absolute_source_root.rglob("*.zig")):
        found = scanner.declarations(path, absolute_source_root, public_names)
        if not found:
            continue
        relative = path.relative_to(bun_root).as_posix()
        source_hashes[relative] = sha256(path)
        entries.extend(found)
    entries = scanner.unique_symbol_declarations(entries)
    for entry in entries:
        classification = expected_classification(str(entry["name"]), public_names)
        entry["classification"] = classification
        if classification == "private_jsc":
            entry["issue"] = 164
    apply_status(entries)
    classes = Counter(str(entry["classification"]) for entry in entries)
    statuses = Counter(str(entry["status"]) for entry in entries)
    return {
        "schema_version": 1,
        "profile_id": PROFILE_ID,
        "kind": "private_abi_inventory",
        "consumer": {
            "name": "Bun",
            "revision": REVISION,
            "source_root": SOURCE_ROOT.as_posix(),
            "source_files": source_hashes,
        },
        "boundary": {
            "included": "unique legacy/private symbols from extern fn and extern \"c\"/\"C\" fn declarations under Bun src/jsc; repeated imports retain alternate declaration provenance",
            "excluded": "non-C named-library declarations, bundled C libraries, runtime/webcore, N-API, and generated bindings; consumer-generated definitions such as JSFunctionCall remain inventoried as consumer_provided",
            "implementation_issue": 164,
        },
        "calling_conventions": {
            "C": "extern default C calling convention, with optional explicit c/C library linkage",
            ".c": "explicit C calling convention",
            "jsc.conv": "x86_64 SysV on Windows x64; C on every other Bun target",
        },
        "totals": {
            "symbols": len(entries),
            "source_files": len(source_hashes),
            "by_classification": dict(sorted(classes.items())),
            "by_status": dict(sorted(statuses.items())),
        },
        "home_comparison": home_comparison(entries),
        "declarations": entries,
    }


def validate(data: dict[str, object]) -> None:
    if data.get("schema_version") != 1 or data.get("profile_id") != PROFILE_ID:
        fail("stored inventory schema or identity mismatch")
    entries = data.get("declarations")
    if not isinstance(entries, list) or not entries:
        fail("stored inventory has no declarations")
    public_data = json.loads(PUBLIC_INVENTORY.read_text())
    public_names = {entry["name"] for entry in public_data["functions"]}
    exports = set(EXPORT_RE.findall(EXPORT_SOURCE.read_text()))
    names: list[str] = []
    for entry in entries:
        name = str(entry.get("name", ""))
        declaration = str(entry.get("declaration", ""))
        if not name or entry.get("declaration_sha256") != hashlib.sha256(declaration.encode()).hexdigest():
            fail(f"invalid declaration or digest for {name!r}")
        alternates = entry.get("alternate_declarations", [])
        if not isinstance(alternates, list):
            fail(f"malformed alternate declarations for {name}")
        for alternate in alternates:
            alternate_declaration = alternate.get("declaration")
            if (
                not isinstance(alternate_declaration, str)
                or alternate.get("declaration_sha256")
                != hashlib.sha256(alternate_declaration.encode()).hexdigest()
            ):
                fail(f"invalid alternate declaration or digest for {name}")
        classification = expected_classification(name, public_names)
        if entry.get("classification") != classification:
            fail(f"classification drift for {name}")
        if entry.get("calling_convention") not in data["calling_conventions"]:
            fail(f"calling-convention drift for {name}")
        if classification == "private_jsc":
            expected_status = "implemented" if name in exports else "pending"
            if entry.get("status") != expected_status:
                fail(f"implementation-status drift for {name}")
            if expected_status == "pending" and entry.get("issue") != 164:
                fail(f"pending {name} is not linked to #164")
        names.append(name)
    if len(names) != len(set(names)):
        fail("stored inventory contains duplicate symbols")
    classes = Counter(str(entry["classification"]) for entry in entries)
    statuses = Counter(str(entry["status"]) for entry in entries)
    totals = data["totals"]
    if totals["symbols"] != len(entries) or totals["source_files"] != len(data["consumer"]["source_files"]):
        fail("stored inventory totals drift")
    if totals["by_classification"] != dict(sorted(classes.items())) or totals["by_status"] != dict(sorted(statuses.items())):
        fail("stored classification/status totals drift")
    if data.get("home_comparison") != home_comparison(entries):
        fail("stored Home-vs-Bun comparison drift")


def validate_diagnostic_contract(bun_root: Path | None) -> None:
    if not DIAGNOSTIC_CONTRACT.is_file():
        fail(f"missing checked-in diagnostic inspector contract {DIAGNOSTIC_CONTRACT}")
    contract = json.loads(DIAGNOSTIC_CONTRACT.read_text())
    if (
        contract.get("schema_version") != 1
        or contract.get("contract") != "received-value-diagnostic-inspector"
        or contract.get("revision") != REVISION
        or contract.get("issue") != 394
    ):
        fail("diagnostic inspector contract schema, revision, or issue drift")
    sources = contract.get("sources")
    if not isinstance(sources, dict) or set(sources) != {
        "src/jsc/bindings/ErrorCode.cpp",
        "src/jsc/ConsoleObject.zig",
        "src/runtime/api/BunObject.zig",
    }:
        fail("diagnostic inspector source set drift")
    for relative, digest in sources.items():
        if not isinstance(digest, str) or re.fullmatch(r"[0-9a-f]{64}", digest) is None:
            fail(f"invalid diagnostic inspector digest for {relative}")
        if bun_root is not None:
            path = bun_root / relative
            if not path.is_file() or sha256(path) != digest:
                fail(f"diagnostic inspector source drift for {relative}")
    semantics = contract.get("semantics")
    if not isinstance(semantics, list) or len(semantics) < 8 or len(semantics) != len(set(semantics)):
        fail("diagnostic inspector semantic inventory is incomplete or duplicated")


def validate_inspector_agents_contract(bun_root: Path | None) -> None:
    if not INSPECTOR_AGENTS_CONTRACT.is_file():
        fail(f"missing checked-in inspector agents contract {INSPECTOR_AGENTS_CONTRACT}")
    contract = json.loads(INSPECTOR_AGENTS_CONTRACT.read_text())
    if (
        contract.get("schema_version") != 1
        or contract.get("contract") != "lifecycle-test-reporter-inspector-agents"
        or contract.get("revision") != REVISION
        or contract.get("issue") != 396
        or contract.get("parent_issue") != 140
    ):
        fail("inspector agents contract schema, revision, or issue drift")
    sources = contract.get("sources")
    expected_sources = {
        "src/jsc/bindings/InspectorLifecycleAgent.cpp",
        "src/jsc/bindings/InspectorTestReporterAgent.cpp",
        "packages/bun-inspector-protocol/src/protocol/jsc/protocol.json",
    }
    if not isinstance(sources, dict) or set(sources) != expected_sources:
        fail("inspector agents source set drift")
    for relative, digest in sources.items():
        if not isinstance(digest, str) or re.fullmatch(r"[0-9a-f]{64}", digest) is None:
            fail(f"invalid inspector agents digest for {relative}")
        if bun_root is not None:
            path = bun_root / relative
            if not path.is_file() or sha256(path) != digest:
                fail(f"inspector agents source drift for {relative}")
    expected_exports = {
        "Bun__LifecycleAgentReportReload",
        "Bun__LifecycleAgentReportError",
        "Bun__LifecycleAgentPreventExit",
        "Bun__LifecycleAgentStopPreventingExit",
        "Bun__TestReporterAgentReportTestFound",
        "Bun__TestReporterAgentReportTestFoundWithLocation",
        "Bun__TestReporterAgentReportTestStart",
        "Bun__TestReporterAgentReportTestEnd",
    }
    exports = contract.get("exports")
    if not isinstance(exports, list) or set(exports) != expected_exports or len(exports) != len(expected_exports):
        fail("inspector agents export inventory drift")
    domains = contract.get("domains")
    if not isinstance(domains, dict) or set(domains) != {"LifecycleReporter", "TestReporter"}:
        fail("inspector agents domain inventory drift")
    lifecycle = domains["LifecycleReporter"]
    tests = domains["TestReporter"]
    if lifecycle.get("commands") != ["enable", "disable", "preventExit", "stopPreventingExit"]:
        fail("LifecycleReporter command contract drift")
    if lifecycle.get("events") != ["reload", "error"]:
        fail("LifecycleReporter event contract drift")
    if tests.get("commands") != ["enable", "disable"] or tests.get("events") != ["found", "start", "end"]:
        fail("TestReporter command or event contract drift")
    if tests.get("test_type") != {"0": "test", "1": "describe"}:
        fail("TestReporter type enum drift")
    if tests.get("test_status") != {
        "0": "pass",
        "1": "fail",
        "2": "timeout",
        "3": "skip",
        "4": "todo",
        "5": "skipped_because_label",
    }:
        fail("TestReporter status enum drift")
    semantics = contract.get("semantics")
    if not isinstance(semantics, list) or len(semantics) < 10 or len(semantics) != len(set(semantics)):
        fail("inspector agents semantic inventory is incomplete or duplicated")


def validate_http_server_inspector_contract(bun_root: Path | None) -> None:
    if not HTTP_SERVER_INSPECTOR_CONTRACT.is_file():
        fail(f"missing checked-in HTTP server inspector contract {HTTP_SERVER_INSPECTOR_CONTRACT}")
    contract = json.loads(HTTP_SERVER_INSPECTOR_CONTRACT.read_text())
    webkit_revision = "cd821fecca0d39c8bac874c283d956868c7f0de0"
    if (
        contract.get("schema_version") != 1
        or contract.get("contract") != "http-server-inspector-request-lifecycle"
        or contract.get("revision") != REVISION
        or contract.get("webkit_revision") != webkit_revision
        or contract.get("issue") != 398
        or contract.get("parent_issue") != 140
    ):
        fail("HTTP server inspector contract schema, revision, or issue drift")
    sources = contract.get("sources")
    expected_sources = {
        "src/http_types/Method.rs",
        "src/jsc/HTTPServerAgent.rs",
        "src/jsc/HTTPServerAgent.zig",
        "src/jsc/bindings/InspectorHTTPServerAgent.cpp",
        "scripts/build/deps/webkit.ts",
    }
    if not isinstance(sources, dict) or set(sources) != expected_sources:
        fail("HTTP server inspector source set drift")
    for relative, digest in sources.items():
        if not isinstance(digest, str) or re.fullmatch(r"[0-9a-f]{64}", digest) is None:
            fail(f"invalid HTTP server inspector digest for {relative}")
        if bun_root is not None:
            path = bun_root / relative
            if not path.is_file() or sha256(path) != digest:
                fail(f"HTTP server inspector source drift for {relative}")
    if bun_root is not None:
        webkit_config = (bun_root / "scripts/build/deps/webkit.ts").read_text()
        if f'WEBKIT_VERSION = "{webkit_revision}"' not in webkit_config:
            fail("HTTP server inspector WebKit revision drift")
    protocol = contract.get("webkit_protocol")
    if protocol != {
        "path": "Source/JavaScriptCore/inspector/protocol/HTTPServer.json",
        "sha256": "d758684a03ced8989a0377fa3323a3b91df6b32236f49bc39afc62e631a98cc0",
    }:
        fail("HTTP server inspector protocol identity drift")
    expected_exports = {
        "Bun__HTTPServerAgent__notifyRequestWillBeSent",
        "Bun__HTTPServerAgent__notifyResponseReceived",
        "Bun__HTTPServerAgent__notifyBodyChunkReceived",
        "Bun__HTTPServerAgent__notifyRequestFinished",
        "Bun__HTTPServerAgent__notifyRequestHandlerException",
    }
    exports = contract.get("exports")
    if not isinstance(exports, list) or set(exports) != expected_exports or len(exports) != len(expected_exports):
        fail("HTTP server inspector export inventory drift")
    domain = contract.get("domain")
    if not isinstance(domain, dict) or domain.get("name") != "HTTPServer":
        fail("HTTP server inspector domain identity drift")
    if domain.get("commands") != ["enable", "disable"]:
        fail("HTTP server inspector command contract drift")
    if domain.get("events") != [
        "requestWillBeSent",
        "responseReceived",
        "bodyChunkReceived",
        "requestFinished",
        "requestHandlerException",
    ]:
        fail("HTTP server inspector event contract drift")
    if domain.get("http_method_range") != [0, 35]:
        fail("HTTP server inspector method range drift")
    semantics = contract.get("semantics")
    if not isinstance(semantics, list) or len(semantics) < 10 or len(semantics) != len(set(semantics)):
        fail("HTTP server inspector semantic inventory is incomplete or duplicated")


def validate_process_signal_contract(bun_root: Path | None) -> None:
    if not PROCESS_SIGNAL_CONTRACT.is_file():
        fail(f"missing checked-in process signal contract {PROCESS_SIGNAL_CONTRACT}")
    contract = json.loads(PROCESS_SIGNAL_CONTRACT.read_text())
    if (
        contract.get("schema_version") != 1
        or contract.get("contract") != "process-native-signal-delivery"
        or contract.get("revision") != REVISION
        or contract.get("issue") != 400
        or contract.get("parent_issue") != 140
        or contract.get("export") != "Bun__onSignalForJS"
        or contract.get("event_arguments") != ["signalName", "signalNumber"]
    ):
        fail("process signal contract schema, revision, or boundary drift")
    sources = contract.get("sources")
    if not isinstance(sources, dict) or set(sources) != {"src/jsc/bindings/BunProcess.cpp"}:
        fail("process signal source set drift")
    for relative, digest in sources.items():
        if not isinstance(digest, str) or re.fullmatch(r"[0-9a-f]{64}", digest) is None:
            fail(f"invalid process signal digest for {relative}")
        if bun_root is not None:
            path = bun_root / relative
            if not path.is_file() or sha256(path) != digest:
                fail(f"process signal source drift for {relative}")
    expected_names = [
        "SIGHUP", "SIGINT", "SIGQUIT", "SIGILL", "SIGTRAP", "SIGABRT", "SIGIOT", "SIGBUS",
        "SIGFPE", "SIGKILL", "SIGUSR1", "SIGSEGV", "SIGUSR2", "SIGPIPE", "SIGALRM", "SIGTERM",
        "SIGCHLD", "SIGCONT", "SIGSTOP", "SIGTSTP", "SIGTTIN", "SIGTTOU", "SIGURG", "SIGXCPU",
        "SIGXFSZ", "SIGVTALRM", "SIGPROF", "SIGWINCH", "SIGIO", "SIGINFO", "SIGSYS", "SIGBREAK",
    ]
    if contract.get("signal_names") != expected_names:
        fail("process signal name order drift")
    if contract.get("windows_signal_names") != [
        "SIGHUP", "SIGINT", "SIGQUIT", "SIGKILL", "SIGTERM", "SIGWINCH", "SIGBREAK"
    ]:
        fail("process Windows signal subset drift")
    semantics = contract.get("semantics")
    if not isinstance(semantics, list) or len(semantics) < 7 or len(semantics) != len(set(semantics)):
        fail("process signal semantic inventory is incomplete or duplicated")


def validate_module_registry_shims_contract(bun_root: Path | None) -> None:
    if not MODULE_REGISTRY_SHIMS_CONTRACT.is_file():
        fail(f"missing checked-in module registry shims contract {MODULE_REGISTRY_SHIMS_CONTRACT}")
    contract = json.loads(MODULE_REGISTRY_SHIMS_CONTRACT.read_text())
    if (
        contract.get("schema_version") != 1
        or contract.get("contract") != "retired-module-registry-snapshot-shims"
        or contract.get("revision") != REVISION
        or contract.get("issue") != 402
        or contract.get("parent_issue") != 140
    ):
        fail("module registry shims contract schema, revision, or issue drift")
    sources = contract.get("sources")
    expected_sources = {"src/jsc/bindings/ZigGlobalObject.cpp"}
    if not isinstance(sources, dict) or set(sources) != expected_sources:
        fail("module registry shims source set drift")
    for relative, digest in sources.items():
        if not isinstance(digest, str) or re.fullmatch(r"[0-9a-f]{64}", digest) is None:
            fail(f"invalid module registry shims digest for {relative}")
        if bun_root is not None:
            path = bun_root / relative
            if not path.is_file() or sha256(path) != digest:
                fail(f"module registry shims source drift for {relative}")
    expected_exports = {
        "Zig__GlobalObject__getModuleRegistryMap",
        "Zig__GlobalObject__resetModuleRegistryMap",
    }
    exports = contract.get("exports")
    if not isinstance(exports, list) or set(exports) != expected_exports or len(exports) != len(expected_exports):
        fail("module registry shims export inventory drift")
    semantics = contract.get("semantics")
    if not isinstance(semantics, list) or len(semantics) < 7 or len(semantics) != len(set(semantics)):
        fail("module registry shims semantic inventory is incomplete or duplicated")


def validate_heap_snapshot_contract(bun_root: Path | None) -> None:
    if not HEAP_SNAPSHOT_CONTRACT.is_file():
        fail(f"missing checked-in heap snapshot contract {HEAP_SNAPSHOT_CONTRACT}")
    contract = json.loads(HEAP_SNAPSHOT_CONTRACT.read_text())
    if (
        contract.get("schema_version") != 1
        or contract.get("contract") != "heap-snapshot-graph-and-profile-serialization"
        or contract.get("issue") != 403
        or contract.get("parent_issues") != [140, 143, 246]
    ):
        fail("heap snapshot contract schema or issue lineage drift")
    if contract.get("revisions") != {
        "home": "7ed99c02e50034f869d0db6d487115bb44332fe4",
        "bun": REVISION,
        "webkit": "cd821fecca0d39c8bac874c283d956868c7f0de0",
        "zig_gc": "c17c01af7ee8a38bbe1b47bc02751653d2b81afc",
    }:
        fail("heap snapshot revision set drift")
    sources = contract.get("sources")
    expected_sources = {
        "packages/runtime/src/jsc/BunHeapProfiler.zig",
        "packages/runtime/upstream/src/jsc/BunHeapProfiler.zig",
        "packages/runtime/upstream/src/jsc/bindings/BunHeapProfiler.cpp",
        "WebKit/Source/JavaScriptCore/heap/HeapSnapshotBuilder.cpp",
        "WebKit/Source/JavaScriptCore/heap/BunV8HeapSnapshotBuilder.cpp",
    }
    if not isinstance(sources, dict) or set(sources) != expected_sources:
        fail("heap snapshot source set drift")
    for relative, digest in sources.items():
        if not isinstance(digest, str) or re.fullmatch(r"[0-9a-f]{64}", digest) is None:
            fail(f"invalid heap snapshot digest for {relative}")
    if bun_root is not None:
        bun_sources = {
            "packages/runtime/upstream/src/jsc/BunHeapProfiler.zig": "src/jsc/BunHeapProfiler.zig",
            "packages/runtime/upstream/src/jsc/bindings/BunHeapProfiler.cpp": "src/jsc/bindings/BunHeapProfiler.cpp",
        }
        for contract_path, bun_path in bun_sources.items():
            path = bun_root / bun_path
            if not path.is_file() or sha256(path) != sources[contract_path]:
                fail(f"heap snapshot source drift for {bun_path}")
    expected_exports = {
        "JSC__JSGlobalObject__generateHeapSnapshot",
        "Bun__generateHeapSnapshotV8",
        "Bun__generateHeapProfile",
    }
    exports = contract.get("exports")
    if not isinstance(exports, list) or set(exports) != expected_exports or len(exports) != len(expected_exports):
        fail("heap snapshot export inventory drift")
    semantics = contract.get("semantics")
    if not isinstance(semantics, list) or len(semantics) < 9 or len(semantics) != len(set(semantics)):
        fail("heap snapshot semantic inventory is incomplete or duplicated")


def validate_cpu_profile_contract(bun_root: Path | None) -> None:
    if not CPU_PROFILE_CONTRACT.is_file():
        fail(f"missing checked-in CPU profile contract {CPU_PROFILE_CONTRACT}")
    contract = json.loads(CPU_PROFILE_CONTRACT.read_text())
    if (
        contract.get("schema_version") != 1
        or contract.get("contract") != "per-vm-cpu-sampling-profile"
        or contract.get("issue") != 404
        or contract.get("parent_issues") != [140, 143, 163, 164]
    ):
        fail("CPU profile contract schema or issue lineage drift")
    if contract.get("revisions") != {
        "home": "7ed99c02e50034f869d0db6d487115bb44332fe4",
        "bun": REVISION,
    }:
        fail("CPU profile revision set drift")
    sources = contract.get("sources")
    expected_sources = {
        "packages/runtime/src/jsc/BunCPUProfiler.zig",
        "packages/runtime/upstream/src/jsc/BunCPUProfiler.zig",
        "packages/runtime/upstream/src/jsc/bindings/BunCPUProfiler.cpp",
    }
    if not isinstance(sources, dict) or set(sources) != expected_sources:
        fail("CPU profile source set drift")
    for relative, digest in sources.items():
        if not isinstance(digest, str) or re.fullmatch(r"[0-9a-f]{64}", digest) is None:
            fail(f"invalid CPU profile digest for {relative}")
    if bun_root is not None:
        bun_sources = {
            "packages/runtime/upstream/src/jsc/BunCPUProfiler.zig": "src/jsc/BunCPUProfiler.zig",
            "packages/runtime/upstream/src/jsc/bindings/BunCPUProfiler.cpp": "src/jsc/bindings/BunCPUProfiler.cpp",
        }
        for contract_path, bun_path in bun_sources.items():
            path = bun_root / bun_path
            if not path.is_file() or sha256(path) != sources[contract_path]:
                fail(f"CPU profile source drift for {bun_path}")
    expected_exports = {"Bun__setSamplingInterval", "Bun__startCPUProfiler", "Bun__stopCPUProfiler"}
    exports = contract.get("exports")
    if not isinstance(exports, list) or set(exports) != expected_exports or len(exports) != len(expected_exports):
        fail("CPU profile export inventory drift")
    semantics = contract.get("semantics")
    if not isinstance(semantics, list) or len(semantics) < 10 or len(semantics) != len(set(semantics)):
        fail("CPU profile semantic inventory is incomplete or duplicated")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--bun-root", type=Path)
    parser.add_argument("--write", action="store_true")
    parser.add_argument("--refresh-implementation-status", action="store_true")
    args = parser.parse_args()
    if args.write and not args.bun_root:
        fail("--write requires --bun-root")
    if args.write and args.refresh_implementation_status:
        fail("--write and --refresh-implementation-status are mutually exclusive")
    if args.bun_root:
        generated = generate(args.bun_root.resolve())
        if args.write:
            OUTPUT.write_text(json.dumps(generated, indent=2) + "\n")
        elif not OUTPUT.is_file() or generated != json.loads(OUTPUT.read_text()):
            fail("checked-in inventory differs from the pinned Bun source")
    if not OUTPUT.is_file():
        fail(f"missing checked-in inventory {OUTPUT}")
    stored = json.loads(OUTPUT.read_text())
    if args.refresh_implementation_status:
        refresh_implementation_status(stored)
        OUTPUT.write_text(json.dumps(stored, indent=2) + "\n")
    validate(stored)
    validate_diagnostic_contract(args.bun_root.resolve() if args.bun_root else None)
    validate_inspector_agents_contract(args.bun_root.resolve() if args.bun_root else None)
    validate_http_server_inspector_contract(args.bun_root.resolve() if args.bun_root else None)
    validate_process_signal_contract(args.bun_root.resolve() if args.bun_root else None)
    validate_module_registry_shims_contract(args.bun_root.resolve() if args.bun_root else None)
    validate_heap_snapshot_contract(args.bun_root.resolve() if args.bun_root else None)
    validate_cpu_profile_contract(args.bun_root.resolve() if args.bun_root else None)
    totals = stored["totals"]
    classes = totals["by_classification"]
    statuses = totals["by_status"]
    comparison = stored["home_comparison"]
    print(
        f"Bun private ABI audit: {totals['symbols']} symbols from {totals['source_files']} files; "
        f"private={classes.get('private_jsc', 0)}, public={classes.get('public_c_api', 0)}, "
        f"consumer-provided={classes.get('consumer_provided', 0)}, "
        f"implemented-private={statuses.get('implemented', 0) - classes.get('public_c_api', 0)}, "
        f"pending-private={statuses.get('pending', 0)}, unclassified=0; "
        f"Home shared={comparison['shared_symbols']}, Bun-only={len(comparison['bun_only_symbols'])}, "
        f"Home-only={len(comparison['home_only_symbols'])}, changed-signature={len(comparison['signature_changed_symbols'])}"
    )


if __name__ == "__main__":
    main()
