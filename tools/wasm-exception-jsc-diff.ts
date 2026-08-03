/** Compare the public WebAssembly exception JS API with system JSC. */
import { checked, removeTemporaryDirectory, sha256File, temporaryDirectory, writeText, run } from "./lib/home";
declare const __dirname: string;
const ROOT = __dirname === "tools" ? "." : __dirname.slice(0, __dirname.lastIndexOf("/tools"));
const join = (left: string, right: string): string => `${left.replace(/\/$/, "")}/${right}`;
const args = process.argv.slice(2);
if (args.length !== 1) throw new Error("usage: wasm-exception-jsc-diff.ts <zig-js fixture>");
if (checked(["uname", "-s"], "detect platform").trim() !== "Darwin") throw new Error("the WebAssembly exception JavaScriptCore differential requires macOS");
const directory = temporaryDirectory("zig-js-wasm-exception-jsc");
try {
  const reference = join(directory, "wasm-exception-jsc");
  checked(["xcrun", "--sdk", "macosx", "clang", join(ROOT, "tests/wasm_exception_jsc_diff.c"), "-framework", "JavaScriptCore", "-o", reference], "compile system JSC WebAssembly exception fixture");
  const expected = checked([reference], `run ${reference}`), actual = checked([args[0]], `run ${args[0]}`);
  if (actual !== expected) {
    const expectedPath = join(directory, "system-jsc.txt"), actualPath = join(directory, "zig-js.txt");
    writeText(expectedPath, expected); writeText(actualPath, actual);
    const difference = run(["diff", "-u", expectedPath, actualPath]);
    throw new Error(`WebAssembly exception JSC differential mismatch:\n${difference.stdout || difference.stderr}`);
  }
  const output = join(directory, "actual.txt"); writeText(output, actual);
  const rows = actual ? actual.replace(/\n$/, "").split("\n").length : 0;
  console.log(`WebAssembly exception JSC differential: matched ${rows} rows (${sha256File(output).slice(0, 16)})`);
} finally { removeTemporaryDirectory(directory); }
