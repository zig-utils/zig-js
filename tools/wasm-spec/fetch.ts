/** Acquire the pinned WebAssembly wg-1.0 corpus and WABT converter. */
import { run } from "../lib/home";

const revision = "977f97014c962f7bd1291fcc6d28b41a924882bf";
const checksum = "492f9a90dda9536d687746185f329c96a35226e5386ff82b331098d9070179a2";
const output = process.argv[2];
const converterOutput = process.argv[3];
if (!output) throw new Error("usage: fetch.ts <spec-out-dir> [wabt-out-dir]");
if (output === "/" || output === "." || output === ".." || output[0] === "-") throw new Error("refusing unsafe output directory: " + output);
const archive = `/tmp/zig-js-wasm-spec-${revision}.tar.gz`;
function checked(argv: string[], phase: string): string {
  const result = run(argv);
  if (result.exitCode !== 0) throw new Error(`${phase} failed: ${result.stderr || result.stdout}`);
  return result.stdout;
}
checked(["mkdir", "-p", output], "create output directory");
checked(["curl", "--fail", "--location", "--silent", "--show-error", "--output", archive, `https://github.com/WebAssembly/spec/archive/${revision}.tar.gz`], "download pinned specification");
const actual = checked(["shasum", "-a", "256", archive], "checksum specification").trim().split(/\s+/)[0];
if (actual !== checksum) throw new Error(`WebAssembly/spec checksum mismatch: expected ${checksum}, got ${actual}`);
checked(["tar", "-xzf", archive, "--strip-components=1", "-C", output], "extract pinned specification");
checked(["rm", "-f", archive], "remove acquisition archive");
console.log(`fetched WebAssembly/spec@${revision} (wg-1.0) into ${output}`);

if (converterOutput) {
  if (converterOutput === "/" || converterOutput === "." || converterOutput === ".." || converterOutput[0] === "-") throw new Error("refusing unsafe converter output directory: " + converterOutput);
  const os = checked(["uname", "-s"], "detect converter operating system").trim();
  const architecture = checked(["uname", "-m"], "detect converter architecture").trim();
  const targets: Record<string, { asset: string; checksum: string }> = {
    "Darwin:arm64": { asset: "wabt-1.0.39-macos-arm64.tar.gz", checksum: "168a83f22125a77d96ecb230341ed0e2b06b970aadb57eb89d2ed06f9b7f8aca" },
    "Linux:x86_64": { asset: "wabt-1.0.39-linux-x64.tar.gz", checksum: "1df1254b6639f5f1f89665907ee8cd0cd30114f40483515e583cccb86240840f" },
    "Linux:aarch64": { asset: "wabt-1.0.39-linux-arm64.tar.gz", checksum: "57a94e8b09084ab919c5b95559c1db8be87a0848384b84853d4d274ccaa5b46d" },
  };
  const target = targets[`${os}:${architecture}`];
  if (!target) throw new Error(`no pinned WABT 1.0.39 archive for ${os}:${architecture}`);
  const wabtArchive = `/tmp/zig-js-${target.asset}`;
  checked(["mkdir", "-p", converterOutput], "create converter output directory");
  checked(["curl", "--fail", "--location", "--silent", "--show-error", "--output", wabtArchive, `https://github.com/WebAssembly/wabt/releases/download/1.0.39/${target.asset}`], "download pinned WABT");
  const wabtActual = checked(["shasum", "-a", "256", wabtArchive], "checksum WABT").trim().split(/\s+/)[0];
  if (wabtActual !== target.checksum) throw new Error(`WABT checksum mismatch: expected ${target.checksum}, got ${wabtActual}`);
  checked(["tar", "-xzf", wabtArchive, "--strip-components=1", "-C", converterOutput], "extract pinned WABT");
  checked(["rm", "-f", wabtArchive], "remove WABT archive");
  const converter = `${converterOutput.replace(/\/$/, "")}/bin/wat2wasm`;
  let probe = run([converter, "--version"]);
  if (probe.exitCode !== 0 && os === "Darwin" && probe.stderr.includes("libcrypto.3.dylib")) {
    const home = checked(["printenv", "HOME"], "locate Pantry root").trim();
    const libraries = checked(["find", `${home}/.local/share/pantry/global/packages/openssl.org`, "-type", "f", "-name", "libcrypto.3.dylib", "-print"], "locate Pantry OpenSSL").split("\n").filter(Boolean).sort();
    if (!libraries.length) throw new Error("WABT requires libcrypto.3.dylib; install OpenSSL through Pantry");
    checked(["install_name_tool", "-change", "/opt/homebrew/opt/openssl@3/lib/libcrypto.3.dylib", libraries[libraries.length - 1], converter], "relocate WABT OpenSSL dependency");
    probe = run([converter, "--version"]);
  }
  if (probe.exitCode !== 0 || probe.stdout.trim() !== "1.0.39") throw new Error(`WABT executable verification failed: ${probe.stderr || probe.stdout}`);
  console.log(`fetched WABT 1.0.39 into ${converterOutput}`);
}
