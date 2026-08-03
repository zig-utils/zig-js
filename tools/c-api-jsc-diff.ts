/** Compile C API fixtures against system JSC and compare their output. */
import { checked, removeTemporaryDirectory, sha256File, temporaryDirectory, writeText, run } from "./lib/home";
declare const __dirname: string;
declare function require(specifier: string): any;
const { verifyCAPI } = require("./verify-c-api");
// The imported verifier is the executable gate at tools/verify-c-api.ts.
const ROOT = __dirname === "tools" ? "." : __dirname.slice(0, __dirname.lastIndexOf("/tools"));
const join = (left: string, right: string): string => `${left.replace(/\/$/, "")}/${right}`;
const fixtures = [join(ROOT, "tests/c_api_value_diff.c"), join(ROOT, "tests/c_api_context_group_diff.c")], args = process.argv.slice(2);
if (args.length !== fixtures.length) throw new Error("usage: c-api-jsc-diff.ts <zig-js value fixture> <zig-js context-group fixture>");
if (checked(["uname", "-s"], "detect platform").trim() !== "Darwin") throw new Error("the pinned JavaScriptCore differential gate requires macOS");
const sdkRoot = checked(["xcrun", "--sdk", "macosx", "--show-sdk-path"], "locate macOS SDK").trim();
verifyCAPI(sdkRoot);
const directory = temporaryDirectory("zig-js-jsc-diff"), expectedParts: string[] = [], actualParts: string[] = [];
try {
  fixtures.forEach((fixture, index) => {
    const reference = join(directory, `jsc-diff-${index}`);
    checked(["xcrun", "--sdk", "macosx", "clang", fixture, "-framework", "JavaScriptCore", "-o", reference], `compile system JSC fixture ${fixture}`);
    expectedParts.push(checked([reference], `run ${reference}`));
    actualParts.push(checked([args[index]], `run ${args[index]}`));
  });
  const expected = expectedParts.join(""), actual = actualParts.join("");
  if (actual !== expected) {
    const expectedPath = join(directory, "system-jsc.txt"), actualPath = join(directory, "zig-js.txt");
    writeText(expectedPath, expected); writeText(actualPath, actual);
    const difference = run(["diff", "-u", expectedPath, actualPath]);
    throw new Error(`C API differential mismatch:\n${difference.stdout || difference.stderr}`);
  }
  const output = join(directory, "actual.txt"); writeText(output, actual);
  const rows = actual ? actual.replace(/\n$/, "").split("\n").length : 0;
  console.log(`c-api JSC differential: matched ${rows} rows (${sha256File(output).slice(0, 16)})`);
} finally { removeTemporaryDirectory(directory); }
