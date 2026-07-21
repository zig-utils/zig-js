from __future__ import annotations

import importlib.util
import tempfile
import unittest
from pathlib import Path


SCRIPT = Path(__file__).with_name("home-private-abi.py")
SPEC = importlib.util.spec_from_file_location("home_private_abi", SCRIPT)
if SPEC is None or SPEC.loader is None:
    raise RuntimeError(f"cannot import {SCRIPT}")
SCANNER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(SCANNER)


class DeclarationScannerTests(unittest.TestCase):
    def scan(self, source: str) -> list[dict[str, object]]:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            path = root / "fixture.zig"
            path.write_text(source)
            return SCANNER.declarations(path, root, {"PublicDefault"})

    def test_default_and_explicit_c_linkage(self) -> None:
        entries = self.scan(
            """
            pub extern fn PublicDefault(value: u32) callconv(.c) void;
            extern "c" fn LowerC(value: [*]const u8, len: usize) Value;
            extern "C" fn UpperC() callconv(jsc.conv) void;
            """
        )

        self.assertEqual(
            ["PublicDefault", "LowerC", "UpperC"],
            [entry["name"] for entry in entries],
        )
        self.assertEqual(
            [".c", "C", "jsc.conv"],
            [entry["calling_convention"] for entry in entries],
        )
        self.assertEqual("public_c_api", entries[0]["classification"])
        self.assertEqual(
            'extern "c" fn LowerC(value: [*]const u8, len: usize) Value;',
            entries[1]["declaration"],
        )

    def test_multiline_declaration_preserves_source_contract(self) -> None:
        entries = self.scan(
            """
            extern "c" fn MultiLine(
                first: usize,
                second: ?*anyopaque,
            ) callconv(.c) bool;
            """
        )

        self.assertEqual(1, len(entries))
        self.assertEqual("MultiLine", entries[0]["name"])
        self.assertEqual(
            'extern "c" fn MultiLine( first: usize, second: ?*anyopaque, ) callconv(.c) bool;',
            entries[0]["declaration"],
        )

    def test_comments_strings_and_non_c_link_names_are_excluded(self) -> None:
        entries = self.scan(
            r'''
            // extern fn InLineComment() void;
            /* extern "c" fn InBlockComment() void; */
            const fake = "extern fn InString() void;";
            const fake_multiline =
                \\extern "c" fn InMultilineString() void;
            extern "env" fn ImportedFromWasm() void;
            extern "system" fn ImportedFromSystem() void;
            extern fn RealDefault() void;
            ''',
        )

        self.assertEqual(["RealDefault"], [entry["name"] for entry in entries])

    def test_duplicate_symbols_prefer_default_and_retain_alternate(self) -> None:
        entries = SCANNER.unique_symbol_declarations(
            self.scan(
                """
                extern "c" fn Repeated(value: Alias) void;
                extern fn Repeated(value: usize) void;
                """
            )
        )

        self.assertEqual(1, len(entries))
        self.assertEqual("extern fn Repeated(value: usize) void;", entries[0]["declaration"])
        self.assertEqual(
            'extern "c" fn Repeated(value: Alias) void;',
            entries[0]["alternate_declarations"][0]["declaration"],
        )

    def test_consumer_provider_classification_retains_provenance(self) -> None:
        entries = self.scan(
            """
            extern fn Bun__EventLoopTaskNoContext__performTask() void;
            extern fn JSFunctionCall() void;
            """
        )

        self.assertEqual(
            ["consumer_provided", "consumer_provided"],
            [entry["classification"] for entry in entries],
        )
        self.assertEqual(
            {
                "contract": "docs/abi/consumer-provided-private-exports-422.json",
                "source": "src/jsc/bindings/EventLoopTaskNoContext.cpp",
            },
            entries[0]["provider"],
        )
        self.assertNotIn("provider", entries[1])


if __name__ == "__main__":
    unittest.main()
