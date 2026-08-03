/** Generate or verify the terminal WebAssembly conformance matrix. */

declare const Home: {
  readTextFile(path: string): string;
  writeTextFile(path: string, contents: string): void;
  fileExists(path: string): boolean;
};

type Counts = Record<string, number>;
type JsonObject = Record<string, any>;

const PROFILES: Array<[string, string, JsonObject]> = [
  ["mvp", "wasm-spec-inventory.json", { decode_validate: ["portable"], execute: ["portable"] }],
  ["core-2-structural", "wasm-core-2-structural-inventory.json", { decode_validate: ["portable"], execute: ["portable"] }],
  ["simd", "wasm-simd-inventory.json", { decode_validate: ["portable"], execute: ["portable"] }],
  ["threads", "wasm-threads-inventory.json", { decode_validate: ["portable"], execute: ["threaded-context"] }],
  ["tail-calls", "wasm-tail-call-inventory.json", { decode_validate: ["portable"], execute: ["portable"] }],
  ["exception-handling", "wasm-exception-handling-inventory.json", { decode_validate: ["portable"], execute: ["portable"] }],
  ["multi-memory", "wasm-multi-memory-runtime-inventory.json", { decode_validate: ["portable"], execute: ["portable"] }],
  ["memory64", "wasm-memory64-runtime-inventory.json", { decode_validate: ["pointer-width-32", "pointer-width-64"], execute: ["pointer-width-64"] }],
  ["gc", "wasm-gc-runtime-inventory.json", { decode_validate: ["portable"], execute: ["portable"] }],
  ["core-3", "wasm-core-3-inventory.json", { decode_validate: ["pointer-width-32", "pointer-width-64"], execute: ["pointer-width-64"] }],
];

function repositoryRoot(): string {
  const script = process.argv[1].replace(/\\/g, "/");
  const suffix = "/tools/wasm-conformance-matrix.ts";
  if (script.endsWith(suffix)) return script.slice(0, -suffix.length);
  return process.cwd();
}

function join(left: string, right: string): string {
  return left.endsWith("/") ? left + right : left + "/" + right;
}

function addCount(counts: Counts, key: string, amount: number): void {
  counts[key] = (counts[key] || 0) + amount;
}

function orderedCounts(counts: Counts): Counts {
  const ordered: Counts = {};
  for (const key of Object.keys(counts).sort()) ordered[key] = counts[key];
  return ordered;
}

function buildMatrix(root: string): JsonObject {
  const profiles: JsonObject[] = [];
  const combined: Counts = {};

  for (const [profileId, filename, hosts] of PROFILES) {
    const path = join(root, "docs/.data/" + filename);
    const inventory = JSON.parse(Home.readTextFile(path));
    if (inventory.schema_version !== 2) {
      throw new Error(profileId + ": terminal inventory schema drift");
    }
    const totals = inventory.totals || {};
    if (totals.fail !== 0 || totals.runner_error !== 0) {
      throw new Error(profileId + ": terminal inventory is not green");
    }
    for (const key of Object.keys(totals)) addCount(combined, key, totals[key]);

    const modes: Counts = {};
    const notApplicable: Counts = {};
    for (const entry of inventory.files) {
      for (const command of entry.commands) {
        addCount(modes, command.mode || "javascript_api", 1);
        if (command.status === "not_applicable") {
          addCount(notApplicable, command.detail || "unspecified", 1);
        }
      }
    }

    const spec = inventory.spec;
    profiles.push({
      id: profileId,
      default: profileId === "mvp",
      status: "terminal",
      inventory: "docs/.data/" + filename,
      engine_commit: inventory.engine_commit,
      features: inventory.features || [],
      spec: {
        repository: spec.repository,
        commit: spec.commit,
        tag: spec.tag,
        files_scored: spec.files_scored,
      },
      converter: inventory.converter,
      execution_modes: orderedCounts(modes),
      not_applicable_reasons: orderedCounts(notApplicable),
      host_scope: hosts,
      architecture_scope: ["architecture-independent-interpreter"],
      totals,
    });
  }

  const combinedTotals: Counts = {};
  for (const key of ["pass", "not_applicable", "fail", "runner_error", "total"]) {
    combinedTotals[key] = combined[key];
  }
  return {
    schema_version: 1,
    kind: "zig_js_webassembly_conformance_matrix",
    profiles,
    combined_totals: combinedTotals,
  };
}

function sortKeys(value: any): any {
  if (Array.isArray(value)) return value.map(sortKeys);
  if (value !== null && typeof value === "object") {
    const ordered: JsonObject = {};
    for (const key of Object.keys(value).sort()) ordered[key] = sortKeys(value[key]);
    return ordered;
  }
  return value;
}

function main(): void {
  const root = repositoryRoot();
  let output = join(root, "docs/.data/wasm-conformance-matrix.json");
  let write = false;
  for (let index = 2; index < process.argv.length; index += 1) {
    const argument = process.argv[index];
    if (argument === "--write") {
      write = true;
    } else if (argument === "--output") {
      index += 1;
      if (index >= process.argv.length) throw new Error("--output requires a path");
      output = process.argv[index];
    } else {
      throw new Error("unknown argument: " + argument);
    }
  }

  const matrix = buildMatrix(root);
  const rendered = JSON.stringify(sortKeys(matrix), null, 2) + "\n";
  if (write) {
    Home.writeTextFile(output, rendered);
    console.log("WebAssembly conformance matrix written: " + output);
    return;
  }
  if (!Home.fileExists(output) || Home.readTextFile(output) !== rendered) {
    throw new Error(
      "WebAssembly conformance matrix drift; run " +
        "~/Code/Home/lang/zig-out/bin/home-tool run tools/wasm-conformance-matrix.ts --write",
    );
  }
  console.log(
    "WebAssembly conformance matrix: " +
      matrix.profiles.length +
      " terminal profiles, " +
      matrix.combined_totals.pass +
      " applicable passes",
  );
}

main();
