#!/usr/bin/env python3
"""Structural regression tests for the live-WABT corpus driver."""

from __future__ import annotations

import importlib.util
import pathlib
import sys
import tempfile
import unittest


DRIVER = pathlib.Path(__file__).with_name("wasm-spec.py")
SPEC = importlib.util.spec_from_file_location("wasm_spec", DRIVER)
if SPEC is None or SPEC.loader is None:
    raise RuntimeError(f"cannot load {DRIVER}")
wasm_spec = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = wasm_spec
SPEC.loader.exec_module(wasm_spec)


class WastParserTests(unittest.TestCase):
    def test_comments_strings_spans_and_lines(self) -> None:
        source = (
            ";; leading\n"
            '(module $M (func (export "(; not a comment ;)")))\n'
            "(; outer (; nested ;) comment ;)\n"
            "(wait $T)\n"
        )
        forms = wasm_spec.parse_wast_forms(source)
        self.assertEqual([form.head for form in forms], ["module", "wait"])
        self.assertEqual([form.line for form in forms], [2, 4])
        self.assertEqual(source[forms[0].start : forms[0].end], source.splitlines()[1])

    def test_thread_shared_modules_and_nested_body(self) -> None:
        source = (
            "(thread $outer\n"
            "  (shared (module $Mem))\n"
            "  (thread $inner (shared (module $Mem)) (wait $leaf))\n"
            "  (wait $inner))\n"
        )
        form = wasm_spec.parse_wast_forms(source)[0]
        name, shared, body = wasm_spec.thread_parts(form)
        self.assertEqual(name, "$outer")
        self.assertEqual(shared, ["$Mem"])
        self.assertEqual([item.head for item in body], ["thread", "wait"])

    def test_mask_keeps_only_converter_owned_forms_and_line_numbers(self) -> None:
        source = "(module $M)\n(thread $T (wait $X))\n(assert_return (invoke \"f\"))\n"
        masked = wasm_spec.masked_scope_source(source, wasm_spec.parse_wast_forms(source))
        self.assertEqual(masked.count("\n"), source.count("\n"))
        self.assertIn("(module $M)", masked)
        self.assertIn('(assert_return (invoke "f"))', masked)
        self.assertNotIn("thread", masked)

    def test_malformed_script_directives_are_rejected(self) -> None:
        with self.assertRaisesRegex(wasm_spec.WastSyntaxError, "unterminated block comment"):
            wasm_spec.parse_wast_forms("(; never closed")
        malformed = wasm_spec.parse_wast_forms("(thread $T (shared (module)))")[0]
        with self.assertRaisesRegex(wasm_spec.WastSyntaxError, "malformed shared module"):
            wasm_spec.thread_parts(malformed)


class ScriptGenerationTests(unittest.TestCase):
    def test_thread_wait_and_either_modes_are_explicit(self) -> None:
        directory = pathlib.Path(".")
        thread_js = wasm_spec.generate_command(0, {
            "type": "thread",
            "line": 3,
            "name": "$T",
            "shared": ["$Mem"],
            "document": {"commands": []},
        }, directory)
        wait_js = wasm_spec.generate_command(1, {
            "type": "wait", "line": 4, "name": "$T",
        }, directory)
        either_js = wasm_spec.generate_command(2, {
            "type": "assert_return",
            "line": 5,
            "action": {"type": "invoke", "field": "f"},
            "either": [
                {"type": "i32", "value": "0"},
                {"type": "i32", "value": "1"},
            ],
        }, directory)
        self.assertIn("proposal_thread", thread_js)
        self.assertIn('__modules["$Mem"]=__shared[0]', thread_js)
        self.assertIn("proposal_wait", wait_js)
        self.assertIn(".join()", wait_js)
        self.assertIn("||", either_js)

    def test_exception_assertion_requires_typed_webassembly_exception(self) -> None:
        generated = wasm_spec.generate_command(0, {
            "type": "assert_exception",
            "line": 9,
            "action": {"type": "invoke", "field": "throw"},
        }, pathlib.Path("."))
        self.assertIn("WebAssembly.Exception", generated)
        self.assertIn('__last.exports["throw"]()', generated)
        self.assertNotIn("WebAssembly.RuntimeError", generated)

    def test_module_definition_compiles_without_instantiating(self) -> None:
        with tempfile.TemporaryDirectory() as raw_directory:
            directory = pathlib.Path(raw_directory)
            (directory / "huge.wasm").write_bytes(b"\0asm\1\0\0\0")
            generated = wasm_spec.generate_command(0, {
                "type": "module_definition",
                "line": 8,
                "filename": "huge.wasm",
            }, directory)
        self.assertIn("new WebAssembly.Module", generated)
        self.assertNotIn("new WebAssembly.Instance", generated)

    def test_command_shards_keep_module_epochs_intact(self) -> None:
        document = {"commands": [
            {"type": "module", "line": 1, "filename": "a.wasm"},
            {"type": "assert_return", "line": 2, "action": {"type": "invoke", "field": "a"}},
            {"type": "module", "line": 3, "filename": "b.wasm"},
            {"type": "assert_return", "line": 4, "action": {"type": "invoke", "field": "b"}},
            {"type": "assert_invalid", "line": 5, "filename": "bad.wasm"},
        ]}
        shards = wasm_spec.module_command_shards(document, 2)
        flattened = sorted(
            (command for shard in shards for command in shard["commands"]),
            key=lambda command: command["_source_index"],
        )
        self.assertEqual([command["_source_index"] for command in flattened], list(range(5)))
        for shard in shards:
            commands = shard["commands"]
            for index, command in enumerate(commands):
                if command["type"] == "assert_return":
                    self.assertGreater(index, 0)
                    self.assertEqual(commands[index - 1]["type"], "module")

    def test_terminal_profiles_declare_every_dedicated_file(self) -> None:
        tail = wasm_spec.PROFILES["tail-calls"]
        exceptions = wasm_spec.PROFILES["exception-handling"]
        memory64 = wasm_spec.PROFILES["memory64"]
        gc = wasm_spec.PROFILES["gc"]
        self.assertEqual(tail["default_files"], [
            "return_call.wast",
            "return_call_indirect.wast",
        ])
        self.assertEqual(exceptions["default_files"], [
            "tag.wast",
            "throw.wast",
            "throw_ref.wast",
            "try_table.wast",
        ])
        self.assertIn("--enable-tail-call", tail["converter_args"])
        self.assertEqual(
            exceptions["converter_args"],
            ["--enable-exceptions", "--enable-tail-call"],
        )
        self.assertEqual(len(memory64["default_files"]), 23)
        self.assertEqual(memory64["converter_args"], [
            "--enable-memory64", "--enable-multi-memory",
            "--enable-function-references", "--enable-tail-call",
            "--enable-exceptions",
        ])
        self.assertEqual(len(gc["default_files"]), 18)
        self.assertEqual(gc["converter_kind"], "wasm-tools")
        self.assertEqual(gc["converter_version"], "1.253.0")
        self.assertEqual(gc["converter_args"], [])
        self.assertIn("item.type === 'eqref'", wasm_spec.PRELUDE)


if __name__ == "__main__":
    unittest.main()
