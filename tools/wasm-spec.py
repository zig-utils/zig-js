#!/usr/bin/env python3
"""Run and inventory the pinned upstream WebAssembly wg-1.0 core corpus."""

from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile


ROOT = Path(__file__).resolve().parent.parent
SPEC_COMMIT = "977f97014c962f7bd1291fcc6d28b41a924882bf"
WABT_VERSION = "1.0.12"
WABT_COMMIT = "cf261f2bd561297e0da7008ddde8c09ba5ea35a2"


def fail(message: str) -> None:
    print(f"wasm-spec: {message}", file=sys.stderr)
    raise SystemExit(2)


def checked_output(command: list[str], cwd: Path | None = None) -> str:
    result = subprocess.run(command, cwd=cwd, text=True, capture_output=True)
    if result.returncode != 0:
        fail(f"command failed: {' '.join(command)}\n{result.stderr.strip()}")
    return result.stdout.strip()


def verify_tools(spec_root: Path, converter: Path, engine: Path) -> None:
    if not (spec_root / "test/core").is_dir():
        fail(f"missing corpus at {spec_root}; run `git submodule update --init wasm-spec`")
    actual_spec = checked_output(["git", "rev-parse", "HEAD"], spec_root)
    if actual_spec != SPEC_COMMIT:
        fail(f"wasm-spec pin drift: expected {SPEC_COMMIT}, found {actual_spec}")
    if not converter.is_file():
        fail(
            f"missing wast2json at {converter}; build WABT {WABT_VERSION} "
            f"({WABT_COMMIT}) and pass --wast2json"
        )
    # WABT 1.0.12 predates `--version`. Probe the two syntax boundaries that
    # distinguish it from converters too old for final `local.get` spelling and
    # newer converters that removed wg-1.0's NaN assertion commands.
    with tempfile.TemporaryDirectory(prefix="zig-js-wabt-probe-") as raw_probe:
        probe = Path(raw_probe)
        source = probe / "probe.wast"
        source.write_text(
            "(module (func (export \"f\") (param i32) (result i32) (local.get 0)))\n"
            "(assert_return (invoke \"f\" (i32.const 1)) (i32.const 1))\n"
            "(module (func (export \"n\") (result f32) (f32.const nan)))\n"
            "(assert_return_canonical_nan (invoke \"n\"))\n"
        )
        converted = subprocess.run(
            [str(converter), str(source), "-o", str(probe / "probe.json")],
            text=True,
            capture_output=True,
        )
        if converted.returncode != 0:
            fail(
                f"wast2json is not compatible with pinned WABT {WABT_VERSION} "
                f"({WABT_COMMIT}): {converted.stderr.strip()}"
            )
    if not engine.is_file():
        fail(f"missing evaluator at {engine}; run `zig build wasm-spec-eval`")


def js_string(value: str) -> str:
    return json.dumps(value, ensure_ascii=True)


def binary_expression(path: Path) -> str:
    data = path.read_bytes()
    return "new Uint8Array([" + ",".join(str(byte) for byte in data) + "])"


def instance_expression(action: dict) -> str:
    name = action.get("module")
    return f"__modules[{js_string(name)}]" if name is not None else "__last"


def value_expression(value: dict) -> str:
    kind = value["type"]
    raw = js_string(value["value"])
    if kind == "i32":
        return f"(Number({raw}) | 0)"
    if kind == "i64":
        return f"BigInt.asIntN(64, BigInt({raw}))"
    if kind == "f32":
        return f"__f32({raw})"
    if kind == "f64":
        return f"__f64({raw})"
    raise ValueError(f"unknown value type {kind}")


def action_expression(action: dict) -> str:
    instance = instance_expression(action)
    field = js_string(action["field"])
    if action["type"] == "get":
        return f"__get({instance}, {field})"
    if action["type"] == "invoke":
        args = ",".join(value_expression(value) for value in action.get("args", []))
        return f"{instance}.exports[{field}]({args})"
    raise ValueError(f"unknown action type {action['type']}")


PRELUDE = r"""
const __report = { commands: [] };
const __modules = Object.create(null);
const __registry = Object.create(null);
let __last = null;
const __scratch = new ArrayBuffer(8);
const __view = new DataView(__scratch);
function __f32(bits) { __view.setUint32(0, Number(bits), true); return __view.getFloat32(0, true); }
function __f64(bits) { __view.setBigUint64(0, BigInt(bits), true); return __view.getFloat64(0, true); }
function __f32bits(value) { __view.setFloat32(0, value, true); return __view.getUint32(0, true); }
function __f64bits(value) { __view.setFloat64(0, value, true); return __view.getBigUint64(0, true); }
function __record(index, line, type, status, detail) {
  const entry = { index, line, type, status };
  if (detail) entry.detail = detail;
  __report.commands.push(entry);
}
function __message(error) {
  try { return String(error); } catch (_) { return '<unprintable>'; }
}
function __get(instance, field) {
  const value = instance.exports[field];
  return value instanceof WebAssembly.Global ? value.value : value;
}
function __same(actual, expected) {
  if (expected.length === 0) return actual === undefined;
  if (expected.length !== 1) return false;
  const item = expected[0];
  if (item.type === 'i32') return (actual | 0) === (Number(item.value) | 0);
  if (item.type === 'i64') return actual === BigInt.asIntN(64, BigInt(item.value));
  if (item.type === 'f32') return __f32bits(actual) === Number(item.value);
  if (item.type === 'f64') return __f64bits(actual) === BigInt(item.value);
  return false;
}
__registry.spectest = {
  print() {}, print_i32() {}, print_f32() {}, print_f64() {},
  print_i32_f32() {}, print_f64_f64() {},
  global_i32: 666,
  global_i64: 666n,
  global_f32: 666,
  global_f64: 666,
  table: new WebAssembly.Table({ initial: 10, maximum: 20, element: 'anyfunc' }),
  memory: new WebAssembly.Memory({ initial: 1, maximum: 2 }),
};
"""


def record_line(index: int, command: dict, status: str, detail: str = "") -> str:
    return (
        f"__record({index},{int(command.get('line', 0))},"
        f"{js_string(command['type'])},{js_string(status)},{js_string(detail)});"
    )


def expected_exception(
    index: int,
    command: dict,
    expression: str,
    exception_name: str,
) -> str:
    passed = record_line(index, command, "pass")
    missing = record_line(index, command, "fail", f"expected {exception_name}")
    wrong_prefix = (
        f"__record({index},{int(command.get('line', 0))},{js_string(command['type'])},"
        f"'fail','expected {exception_name}, got ' + __message(__error));"
    )
    return (
        "{let __threw=false;try{" + expression + ";}catch(__error){__threw=true;"
        f"if(__error instanceof {exception_name}){{{passed}}}else{{{wrong_prefix}}}"
        f"}}if(!__threw){{{missing}}}}}"
    )


def generate_command(index: int, command: dict, directory: Path) -> str:
    kind = command["type"]
    try:
        if kind == "module":
            binary = binary_expression(directory / command["filename"])
            name = command.get("name")
            assign_name = f"__modules[{js_string(name)}]=__last;" if name is not None else ""
            passed = record_line(index, command, "pass")
            failed = (
                f"__record({index},{int(command.get('line', 0))},{js_string(kind)},"
                "'fail',__message(__error));"
            )
            return (
                f"{{try{{__last=new WebAssembly.Instance(new WebAssembly.Module({binary}),__registry);"
                f"{assign_name}{passed}}}catch(__error){{{failed}}}}}"
            )
        if kind == "register":
            source = (
                f"__modules[{js_string(command['name'])}]"
                if command.get("name") is not None
                else "__last"
            )
            return (
                f"{{try{{__registry[{js_string(command['as'])}]={source}.exports;"
                f"{record_line(index, command, 'pass')}"
                f"}}catch(__error){{__record({index},{int(command.get('line', 0))},"
                f"{js_string(kind)},'fail',__message(__error));}}}}"
            )
        if kind == "action":
            expression = action_expression(command["action"])
            return (
                f"{{try{{{expression};{record_line(index, command, 'pass')}"
                f"}}catch(__error){{__record({index},{int(command.get('line', 0))},"
                f"{js_string(kind)},'fail',__message(__error));}}}}"
            )
        if kind == "assert_return":
            expression = action_expression(command["action"])
            expected = json.dumps(command.get("expected", []), separators=(",", ":"))
            return (
                f"{{try{{const __actual={expression};if(__same(__actual,{expected})){{"
                f"{record_line(index, command, 'pass')}"
                f"}}else{{{record_line(index, command, 'fail', 'result mismatch')}}}"
                f"}}catch(__error){{__record({index},{int(command.get('line', 0))},"
                f"{js_string(kind)},'fail',__message(__error));}}}}"
            )
        if kind in ("assert_return_canonical_nan", "assert_return_arithmetic_nan"):
            expression = action_expression(command["action"])
            return (
                f"{{try{{const __actual={expression};if(Number.isNaN(__actual)){{"
                f"{record_line(index, command, 'pass')}"
                f"}}else{{{record_line(index, command, 'fail', 'expected NaN')}}}"
                f"}}catch(__error){{__record({index},{int(command.get('line', 0))},"
                f"{js_string(kind)},'fail',__message(__error));}}}}"
            )
        if kind in ("assert_trap", "assert_exhaustion"):
            return expected_exception(
                index,
                command,
                action_expression(command["action"]),
                "WebAssembly.RuntimeError",
            )
        if kind in ("assert_malformed", "assert_invalid"):
            if command.get("module_type") == "text":
                return record_line(
                    index,
                    command,
                    "not_applicable",
                    "text-format syntax is not exposed by the JavaScript binary API",
                )
            binary = binary_expression(directory / command["filename"])
            return expected_exception(
                index,
                command,
                f"new WebAssembly.Module({binary})",
                "WebAssembly.CompileError",
            )
        if kind == "assert_unlinkable":
            binary = binary_expression(directory / command["filename"])
            expression = (
                f"new WebAssembly.Instance(new WebAssembly.Module({binary}),__registry)"
            )
            return expected_exception(index, command, expression, "WebAssembly.LinkError")
        if kind == "assert_uninstantiable":
            binary = binary_expression(directory / command["filename"])
            expression = (
                f"new WebAssembly.Instance(new WebAssembly.Module({binary}),__registry)"
            )
            return expected_exception(index, command, expression, "WebAssembly.RuntimeError")
    except (KeyError, ValueError) as error:
        return record_line(index, command, "runner_error", str(error))
    return record_line(index, command, "runner_error", "unsupported command kind")


def generate_script(document: dict, directory: Path) -> str:
    lines = [PRELUDE]
    for index, command in enumerate(document["commands"]):
        lines.append(generate_command(index, command, directory))
    lines.append("JSON.stringify(__report);")
    return "\n".join(lines)


def run_file(
    wast: Path,
    converter: Path,
    engine: Path,
    work_root: Path,
    timeout: float,
) -> dict:
    stem = wast.stem
    directory = work_root / stem
    directory.mkdir()
    json_path = directory / f"{stem}.json"
    converted = subprocess.run(
        [str(converter), str(wast), "-o", str(json_path)],
        text=True,
        capture_output=True,
    )
    if converted.returncode != 0:
        return {
            "path": wast.relative_to(ROOT).as_posix(),
            "status": "conversion_failed",
            "detail": converted.stderr.strip(),
            "commands": [],
        }
    document = json.loads(json_path.read_text())
    script_path = directory / f"{stem}.js"
    script_path.write_text(generate_script(document, directory))
    try:
        evaluated = subprocess.run(
            [str(engine), str(script_path)],
            text=True,
            capture_output=True,
            timeout=timeout,
        )
    except subprocess.TimeoutExpired:
        commands = [
            {
                "index": index,
                "line": command.get("line", 0),
                "type": command["type"],
                "status": "runner_error",
                "detail": "engine timeout",
            }
            for index, command in enumerate(document["commands"])
        ]
        return {"path": wast.relative_to(ROOT).as_posix(), "commands": commands}
    if evaluated.returncode != 0:
        detail = evaluated.stderr.strip() or f"engine exited {evaluated.returncode}"
        commands = [
            {
                "index": index,
                "line": command.get("line", 0),
                "type": command["type"],
                "status": "runner_error",
                "detail": detail,
            }
            for index, command in enumerate(document["commands"])
        ]
        return {"path": wast.relative_to(ROOT).as_posix(), "commands": commands}
    try:
        report = json.loads(evaluated.stdout)
    except json.JSONDecodeError as error:
        commands = [
            {
                "index": index,
                "line": command.get("line", 0),
                "type": command["type"],
                "status": "runner_error",
                "detail": f"invalid evaluator JSON: {error}",
            }
            for index, command in enumerate(document["commands"])
        ]
        return {"path": wast.relative_to(ROOT).as_posix(), "commands": commands}
    return {"path": wast.relative_to(ROOT).as_posix(), "commands": report["commands"]}


def counts(commands: list[dict]) -> dict[str, int]:
    result = {key: 0 for key in ("pass", "fail", "not_applicable", "runner_error")}
    for command in commands:
        result[command["status"]] = result.get(command["status"], 0) + 1
    result["total"] = len(commands)
    return result


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--spec-root", type=Path, default=ROOT / "wasm-spec")
    parser.add_argument(
        "--wast2json",
        type=Path,
        default=Path(os.environ.get("WAST2JSON", shutil.which("wast2json") or "wast2json")),
    )
    parser.add_argument("--engine", type=Path, default=ROOT / "zig-out/bin/wasm-spec-eval")
    parser.add_argument("--inventory", type=Path, default=ROOT / "docs/.data/wasm-spec-inventory.json")
    parser.add_argument("--filter", help="run only corpus paths containing this text")
    parser.add_argument("--timeout", type=float, default=120.0)
    parser.add_argument("--keep-work", type=Path)
    parser.add_argument("--allow-failures", action="store_true")
    args = parser.parse_args()

    spec_root = args.spec_root.resolve()
    converter = args.wast2json.resolve()
    engine = args.engine.resolve()
    verify_tools(spec_root, converter, engine)
    all_wast = sorted((spec_root / "test/core").glob("*.wast"))
    selected = [path for path in all_wast if not args.filter or args.filter in path.as_posix()]
    if not selected:
        fail("no corpus files selected")

    temporary = None
    if args.keep_work:
        work_root = args.keep_work.resolve()
        work_root.mkdir(parents=True, exist_ok=True)
    else:
        temporary = tempfile.TemporaryDirectory(prefix="zig-js-wasm-spec-")
        work_root = Path(temporary.name)

    files = []
    for number, wast in enumerate(selected, 1):
        entry = run_file(wast, converter, engine, work_root, args.timeout)
        entry["counts"] = counts(entry["commands"])
        files.append(entry)
        print(
            f"[{number:02d}/{len(selected):02d}] {wast.name}: "
            f"{entry['counts']['pass']} pass, {entry['counts']['fail']} fail, "
            f"{entry['counts']['not_applicable']} n/a, "
            f"{entry['counts']['runner_error']} runner"
        )

    all_commands = [command for entry in files for command in entry["commands"]]
    totals = counts(all_commands)
    engine_commit = checked_output(["git", "rev-parse", "HEAD"], ROOT)
    inventory = {
        "schema_version": 1,
        "kind": "webassembly_wg_1_0_core_inventory",
        "spec": {
            "repository": "https://github.com/WebAssembly/spec.git",
            "tag": "wg-1.0",
            "commit": SPEC_COMMIT,
            "license": "Apache-2.0",
            "suite": "test/core/*.wast",
            "files_available": len(all_wast),
            "files_scored": len(selected),
        },
        "converter": {
            "repository": "https://github.com/WebAssembly/wabt.git",
            "version": WABT_VERSION,
            "commit": WABT_COMMIT,
        },
        "engine_commit": engine_commit,
        "totals": totals,
        "files": files,
    }
    args.inventory.parent.mkdir(parents=True, exist_ok=True)
    args.inventory.write_text(json.dumps(inventory, indent=2, sort_keys=True) + "\n")
    print(
        f"TOTAL: {totals['pass']}/{totals['total']} pass, "
        f"{totals['fail']} fail, {totals['not_applicable']} n/a, "
        f"{totals['runner_error']} runner; inventory={args.inventory}"
    )
    if temporary is not None:
        temporary.cleanup()
    if args.allow_failures:
        return 0
    return 1 if totals["fail"] or totals["runner_error"] else 0


if __name__ == "__main__":
    raise SystemExit(main())
