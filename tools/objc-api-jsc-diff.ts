/** Compile the Objective-C value fixture against zig-js and system JSC. */
import { checked, removeTemporaryDirectory, run, sha256File, temporaryDirectory, writeText } from "./lib/home";
declare const __dirname: string;
declare function require(specifier: string): any;
const { verifyObjCAPI } = require("./verify-objc-api");
// The imported verifier is the executable gate at tools/verify-objc-api.ts.
const ROOT = __dirname === "tools" ? "." : __dirname.slice(0, __dirname.lastIndexOf("/tools"));
const join = (left: string, right: string): string => `${left.replace(/\/$/, "")}/${right}`;
const args = process.argv.slice(2);
if (args.length !== 1) throw new Error("usage: objc-api-jsc-diff.ts <libzig-js.a>");
if (checked(["uname", "-s"], "detect platform").trim() !== "Darwin") throw new Error("the pinned Objective-C differential gate requires macOS");
const sdkRoot = checked(["xcrun", "--sdk", "macosx", "--show-sdk-path"], "locate macOS SDK").trim();
verifyObjCAPI(sdkRoot);
const directory = temporaryDirectory("zig-js-objc-diff"), fixture = join(ROOT, "tests/objc_api_value_diff.m");
try {
  const reference = join(directory, "system-jsc"), actual = join(directory, "zig-js");
  checked(["xcrun", "--sdk", "macosx", "clang", "-fobjc-arc", "-fblocks", fixture, "-framework", "JavaScriptCore", "-framework", "Foundation", "-o", reference], "compile Objective-C system JSC fixture");
  checked(["xcrun", "--sdk", "macosx", "clang", "-fobjc-arc", "-fblocks", fixture, "-I", join(ROOT, "include"), args[0], "-framework", "Foundation", "-o", actual], "compile Objective-C zig-js fixture");
  const expectedOutput = checked([reference], `run ${reference}`), actualOutput = checked([actual], `run ${actual}`);
  if (actualOutput !== expectedOutput) {
    const expectedPath = join(directory, "system-jsc.txt"), actualPath = join(directory, "zig-js.txt"); writeText(expectedPath, expectedOutput); writeText(actualPath, actualOutput);
    const difference = run(["diff", "-u", expectedPath, actualPath]); throw new Error(`Objective-C API differential mismatch:\n${difference.stdout || difference.stderr}`);
  }
  const output = join(directory, "actual.txt"); writeText(output, actualOutput);
  const rows = actualOutput ? actualOutput.replace(/\n$/, "").split("\n").length : 0;
  console.log(`Objective-C JSC differential: matched ${rows} rows (${sha256File(output).slice(0, 16)})`);
} finally { removeTemporaryDirectory(directory); }
