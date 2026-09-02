/** Verify revision-pinned Home and Bun private ABI inventories and contracts. */
import {
  fileExists,
  readText,
  run,
  sha256File,
  sha256Text,
  writeText,
} from "./lib/home";
declare const __filename: string;
type Item = Record<string, any>;
const HOME_OUTPUT = "docs/abi/home-private-7ed99c02-inventory.json",
  BUN_OUTPUT = "docs/abi/bun-private-core-4982b91e-inventory.json";
const INVENTORY_DIGESTS: Record<string, string> = {
  [HOME_OUTPUT]:
    "799a88f626d723828deab1732a1472e528b9fca2237ab073a66f2e1dca32d73b",
  [BUN_OUTPUT]:
    "744b1a3ab8f00b49f6e561f82436cae8bd16c78f9f41a871007e9bef3adcfb98",
};
const PLATFORM: Record<string, string[]> = {
  home: [
    "connect",
    "gnu_get_libc_version",
    "kill",
    "poll",
    "recvfrom",
    "sendto",
    "socket",
  ],
  bun: ["gnu_get_libc_version"],
};
const CONTRACT_DIGESTS: Record<string, string> = {
  "docs/abi/home-script-execution-context-7ed99c02.json":
    "a31d7fa5554cb94d9e1b4dd356fa77a8b3a72ace3b7a54b920df81207a8236a3",
  "docs/abi/cpu-profile-sampling-404.json":
    "fa30c5e8b8f72b6396be992d6543882e735ca8a84a9981220f3273e378b1cda4",
  "docs/abi/readable-stream-consumption-405.json":
    "5e691e4a65f53bed760ad79ea36f2348bb53f8a190744599cfa01c4c2b7efff2",
  "docs/abi/fetch-body-lifecycle-407.json":
    "45c9cbe41c39828dd5728993bc7d95cb31dc0069cf9cfea10afc2e48c45b96a5",
  "docs/abi/wasm-streaming-api-408.json":
    "755a58709e140bb03e34c9f057529a192c48402519684d30fe7ec14b97a29d20",
  "docs/abi/wasm-streaming-compiler-feed-409.json":
    "03a4981297c615229f6992913c2e141cbe66c5afcb1bcbc02d9cec1e295d5955",
  "docs/abi/wasm-streaming-response-feed-410.json":
    "b9dfc099b30ca62aef23a59f041968393c3862f81dc545a711905ee22900c992",
  "docs/abi/sql-object-structure-411.json":
    "ab2dd7209ed44cf24f62f8b55d77581b8a98fdf0c5f5b6b666165d9610ba3475",
  "docs/abi/global-object-lifecycle-412.json":
    "059a978d20e86316900e7c89b9656aab436b4097d1bad5f41920d9c406ac9b7b",
  "docs/abi/process-initialization-shell-timeout-417.json":
    "c9c8e6069310f24453e70b04e3568abd504d80ab094acd66239f88e9af904468",
  "docs/abi/consumer-provided-private-exports-422.json":
    "2544c85ce1eaa4fa9f2b1c6ad89b1ff8bbb249ca2ae9aeaafed0624c7b404b4a",
  "docs/abi/source-provider-lifecycle-424.json":
    "176f3a76ffbf0cab7aa3db41b9436534b26b458eaa5f2c8681cba35b74995b6d",
  "docs/abi/bun-diagnostic-inspector-4982b91e.json":
    "943394065e30d4f4fbd1480da1fd2e35f8758c0ab5efeb39a33a52811d540f9b",
  "docs/abi/bun-inspector-agents-4982b91e.json":
    "5c1420ea53d2b21aa765408b0d4db41e47de146cf8a757f55a6e45218ea631f6",
  "docs/abi/bun-http-server-inspector-4982b91e.json":
    "9e8025fe5c7b94a84d12ef2a8d99966147c4b421f8bfb48b8b9a9b7ca968eb3e",
  "docs/abi/bun-process-signal-4982b91e.json":
    "3e83eded1c615dd1190e415bb381115f37decef1c6832bc09cbda186fb0e6e2d",
  "docs/abi/bun-module-registry-shims-4982b91e.json":
    "2d002977449006b117b266fb29ad595f3b90dad158f3c44403c18e6f2aeed0b1",
  "docs/abi/heap-snapshot-serialization-403.json":
    "cf9f9af9a5e214854c5b1c2d88a8fc3ec3e31babd6cf12804bdfaddb6ee7be7b",
};
function requireValue(condition: boolean, message: string): void {
  if (!condition) throw new Error(message);
}
export function maskNonCode(source: string): string {
  const chars = source.split("");
  let index = 0,
    state = "code",
    depth = 0;
  while (index < chars.length) {
    const current = chars[index],
      next = chars[index + 1] || "";
    if (state === "code") {
      if (current === "/" && next === "/") {
        chars[index] = chars[index + 1] = " ";
        index += 2;
        state = "line";
      } else if (current === "/" && next === "*") {
        chars[index] = chars[index + 1] = " ";
        index += 2;
        state = "block";
        depth = 1;
      } else if (current === '"' || current === "'") {
        chars[index] = " ";
        index += 1;
        state = current === '"' ? "string" : "character";
      } else if (current === "\\" && next === "\\") {
        chars[index] = chars[index + 1] = " ";
        index += 2;
        state = "line";
      } else index += 1;
    } else if (state === "line") {
      if (current === "\n") state = "code";
      else chars[index] = " ";
      index += 1;
    } else if (state === "block") {
      if (current === "/" && next === "*") {
        chars[index] = chars[index + 1] = " ";
        depth += 1;
        index += 2;
      } else if (current === "*" && next === "/") {
        chars[index] = chars[index + 1] = " ";
        depth -= 1;
        index += 2;
        if (!depth) state = "code";
      } else {
        if (current !== "\n") chars[index] = " ";
        index += 1;
      }
    } else {
      const delimiter = state === "string" ? '"' : "'";
      if (current === "\\") {
        chars[index] = " ";
        if (index + 1 < chars.length) {
          if (chars[index + 1] !== "\n") chars[index + 1] = " ";
          index += 2;
        } else index += 1;
      } else if (current === delimiter) {
        chars[index] = " ";
        index += 1;
        state = "code";
      } else {
        if (current !== "\n") chars[index] = " ";
        index += 1;
      }
    }
  }
  return chars.join("");
}
function providers(): Record<string, string> {
  const contract = JSON.parse(
      readText("docs/abi/consumer-provided-private-exports-422.json"),
    ),
    result: Record<string, string> = {};
  contract.providers.forEach((provider: Item) =>
    provider.symbols.forEach(
      (symbol: string) => (result[symbol] = provider.path),
    ),
  );
  return result;
}
export function scanSource(
  source: string,
  sourceName: string,
  publicNames: string[],
  consumer = "home",
): Item[] {
  const masked = maskNonCode(source),
    result: Item[] = [],
    providerMap = providers(),
    regex =
      /\b(?:pub\s+)?extern\s+(?:\s*|"[^"]+"\s+)fn\s+([A-Za-z_][A-Za-z0-9_]*)\s*\(/g;
  let match: RegExpExecArray | null;
  while ((match = regex.exec(masked))) {
    const name = match[1],
      open = masked.indexOf("(", match.index),
      externStart = masked.indexOf("extern", match.index),
      fnStart = masked.indexOf("fn", externStart + 6);
    requireValue(
      open >= 0 && externStart >= 0 && fnStart >= 0,
      `cannot parse extern declaration for ${name}`,
    );
    const link = source.slice(externStart + 6, fnStart).trim();
    if (link && !/^"c"$/i.test(link)) continue;
    let depth = 0,
      close = -1;
    for (let index = open; index < masked.length; index += 1) {
      if (masked[index] === "(") depth += 1;
      else if (masked[index] === ")" && --depth === 0) {
        close = index;
        break;
      }
    }
    requireValue(close >= 0, `unterminated parameter list for ${name}`);
    const semicolon = masked.indexOf(";", close);
    requireValue(semicolon >= 0, `unterminated declaration for ${name}`);
    const declaration = source
        .slice(match.index, semicolon + 1)
        .trim()
        .replace(/\s+/g, " "),
      convention = /callconv\(([^)]+)\)/.exec(
        source.slice(close + 1, semicolon),
      ),
      classification = publicNames.includes(name)
        ? "public_c_api"
        : PLATFORM[consumer].includes(name)
          ? "platform_import"
          : name === "JSFunctionCall" || providerMap[name]
            ? "consumer_provided"
            : "private_jsc",
      entry: Item = {
        name,
        source: sourceName,
        line: source.slice(0, match.index).split("\n").length,
        calling_convention: convention ? convention[1].trim() : "C",
        classification,
        status:
          classification === "public_c_api"
            ? "implemented"
            : classification === "private_jsc"
              ? "pending"
              : "external",
        declaration,
        declaration_sha256: sha256Text(declaration),
      };
    if (classification === "private_jsc")
      entry.issue = consumer === "home" ? 163 : 164;
    if (providerMap[name])
      entry.provider = {
        contract: "docs/abi/consumer-provided-private-exports-422.json",
        source: providerMap[name],
      };
    result.push(entry);
  }
  return result;
}
export function uniqueDeclarations(entries: Item[]): Item[] {
  const grouped: Record<string, Item[]> = {};
  entries.forEach((entry) => {
    if (!grouped[entry.name]) grouped[entry.name] = [];
    grouped[entry.name].push(entry);
  });
  return Object.keys(grouped)
    .sort()
    .map((name) => {
      const candidates = grouped[name].sort(
          (a, b) =>
            Number(a.declaration.includes('extern "')) -
              Number(b.declaration.includes('extern "')) ||
            String(a.source).localeCompare(String(b.source)) ||
            a.line - b.line,
        ),
        canonical = candidates[0];
      if (candidates.length > 1)
        canonical.alternate_declarations = candidates.slice(1).map((entry) => ({
          source: entry.source,
          line: entry.line,
          declaration: entry.declaration,
          declaration_sha256: entry.declaration_sha256,
        }));
      return canonical;
    });
}
function counts(entries: Item[], field: string): Record<string, number> {
  const result: Record<string, number> = {};
  entries.forEach(
    (entry) => (result[entry[field]] = (result[entry[field]] || 0) + 1),
  );
  return Object.keys(result)
    .sort()
    .reduce((sorted: Record<string, number>, key) => {
      sorted[key] = result[key];
      return sorted;
    }, {});
}
function exports(): string[] {
  const result = run([
    "rg",
    "--only-matching",
    "--replace",
    "$1",
    "^export fn ([A-Za-z_][A-Za-z0-9_]*)\\s*\\(",
    "src/c_api.zig",
  ]);
  requireValue(
    result.exitCode === 0,
    result.stderr || "cannot inventory Zig C exports",
  );
  return result.stdout.split("\n").filter(Boolean);
}
function validateContracts(consumer: string): void {
  const common = Object.keys(CONTRACT_DIGESTS).filter(
      (path) => !path.includes("bun-") && !path.includes("heap-snapshot"),
    ),
    paths =
      consumer === "home"
        ? common
        : Object.keys(CONTRACT_DIGESTS).filter(
            (path) =>
              !path.includes("home-script") &&
              !path.includes("source-provider"),
          );
  for (const path of paths) {
    requireValue(fileExists(path), `missing private ABI contract ${path}`);
    requireValue(
      sha256File(path) === CONTRACT_DIGESTS[path],
      `private ABI contract drift: ${path}`,
    );
    const contract = JSON.parse(readText(path));
    requireValue(
      contract.schema_version === 1 &&
        typeof contract.contract === "string" &&
        Number.isInteger(contract.issue),
      `invalid private ABI contract schema: ${path}`,
    );
  }
}
function validateInventory(consumer: string, data: Item): void {
  const expectedProfile =
    consumer === "home" ? "home-private-7ed99c02" : "bun-private-core-4982b91e";
  requireValue(
    data.schema_version === 1 &&
      data.profile_id === expectedProfile &&
      data.kind === "private_abi_inventory",
    "stored inventory schema or identity mismatch",
  );
  requireValue(
    Array.isArray(data.declarations) && data.declarations.length > 0,
    "stored inventory has no declarations",
  );
  const publicNames = JSON.parse(
      readText("docs/c-api/jsc-public-api-macos-27.0.json"),
    ).functions.map((entry: Item) => entry.name),
    implemented = new Set(exports()),
    names: string[] = [];
  for (const entry of data.declarations) {
    requireValue(
      typeof entry.name === "string" && typeof entry.declaration === "string",
      "stored declaration is missing a name or signature",
    );
    requireValue(
      typeof entry.declaration_sha256 === "string" &&
        entry.declaration_sha256.length === 64,
      `${entry.name} declaration digest is malformed`,
    );
    requireValue(
      Object.keys(data.calling_conventions).includes(entry.calling_convention),
      `${entry.name} calling-convention drift`,
    );
    const expectedClass = publicNames.includes(entry.name)
      ? "public_c_api"
      : PLATFORM[consumer].includes(entry.name)
        ? "platform_import"
        : entry.classification === "consumer_provided"
          ? "consumer_provided"
          : "private_jsc";
    requireValue(
      entry.classification === expectedClass,
      `${entry.name} classification drift`,
    );
    const expectedStatus =
      expectedClass === "public_c_api"
        ? "implemented"
        : ["platform_import", "consumer_provided"].includes(expectedClass)
          ? "external"
          : implemented.has(entry.name)
            ? "implemented"
            : "pending";
    requireValue(
      entry.status === expectedStatus,
      `${entry.name} implementation-status drift`,
    );
    if (expectedStatus === "pending")
      requireValue(
        entry.issue === (consumer === "home" ? 163 : 164),
        `${entry.name} pending issue drift`,
      );
    for (const alternate of entry.alternate_declarations || [])
      requireValue(
        typeof alternate.declaration === "string" &&
          typeof alternate.declaration_sha256 === "string" &&
          alternate.declaration_sha256.length === 64,
        `${entry.name} alternate declaration digest is malformed`,
      );
    names.push(entry.name);
  }
  requireValue(
    new Set(names).size === names.length,
    "stored inventory contains duplicate symbols",
  );
  requireValue(
    data.totals.symbols === data.declarations.length &&
      data.totals.source_files ===
        Object.keys(data.consumer.source_files).length,
    "stored inventory totals drift",
  );
  requireValue(
    JSON.stringify(data.totals.by_classification) ===
      JSON.stringify(counts(data.declarations, "classification")) &&
      JSON.stringify(data.totals.by_status) ===
        JSON.stringify(counts(data.declarations, "status")),
    "stored classification/status totals drift",
  );
}
function validateRoot(
  root: string,
  data: Item,
  expectedRevision: string,
): void {
  const revision = run(["git", "-C", root, "rev-parse", "HEAD"]);
  requireValue(
    revision.exitCode === 0 && revision.stdout.trim() === expectedRevision,
    `consumer revision mismatch: ${revision.stdout.trim()} != ${expectedRevision}`,
  );
  for (const relative of Object.keys(data.consumer.source_files)) {
    const path = `${root}/${relative}`;
    requireValue(
      fileExists(path) &&
        sha256File(path) === data.consumer.source_files[relative],
      `consumer source hash mismatch: ${relative}`,
    );
  }
}
function refresh(data: Item, consumer: string): void {
  const implemented = new Set(exports());
  data.declarations.forEach((entry: Item) => {
    if (entry.classification === "private_jsc") {
      entry.status = implemented.has(entry.name) ? "implemented" : "pending";
      if (entry.status === "implemented") {
        delete entry.issue;
        entry.implementation = "src/c_api.zig";
      } else {
        entry.issue = consumer === "home" ? 163 : 164;
        delete entry.implementation;
      }
    }
  });
  data.totals.by_status = counts(data.declarations, "status");
}
function selfTest(): void {
  requireValue(
    sha256Text("abc") ===
      "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
    "SHA-256 implementation failed",
  );
  const source = `// extern fn Fake() void;\npub extern fn PublicDefault(value: u32) callconv(.c) void;\nextern "c" fn MultiLine(\n first: usize,\n second: ?*anyopaque,\n) bool;\nextern "env" fn Excluded() void;\nconst fake = "extern fn StringFake() void;";`,
    rows = scanSource(source, "fixture.zig", ["PublicDefault"]);
  requireValue(
    JSON.stringify(rows.map((row) => row.name)) ===
      '["PublicDefault","MultiLine"]',
    "declaration scanner included masked/non-C input",
  );
  requireValue(
    rows[0].calling_convention === ".c" &&
      rows[1].declaration.includes("first: usize"),
    "declaration scanner contract failed",
  );
  const duplicate = uniqueDeclarations(
    scanSource(
      'extern "c" fn Repeated(value: Alias) void;\nextern fn Repeated(value: usize) void;',
      "fixture.zig",
      [],
    ),
  );
  requireValue(
    duplicate.length === 1 &&
      duplicate[0].declaration === "extern fn Repeated(value: usize) void;" &&
      duplicate[0].alternate_declarations.length === 1,
    "duplicate declaration collapse failed",
  );
  console.log("private-abi self-test: ok");
}
function main(): void {
  const args = process.argv.slice(2);
  if (args.length === 1 && args[0] === "--self-test") return selfTest();
  let consumer = "",
    root: string | null = null,
    profile = "",
    write = false,
    refreshStatus = false;
  for (let index = 0; index < args.length; index += 1) {
    const name = args[index];
    if (name === "--write") write = true;
    else if (name === "--refresh-implementation-status") refreshStatus = true;
    else {
      const value = args[++index];
      if (name === "--consumer") consumer = value;
      else if (name === "--home-root" || name === "--bun-root") root = value;
      else if (name === "--profile") profile = value;
      else throw new Error(`unknown argument: ${name}`);
    }
  }
  requireValue(
    ["home", "bun"].includes(consumer),
    "--consumer must be home or bun",
  );
  requireValue(
    !(write && !root) && !(write && refreshStatus),
    "--write requires a consumer root and is mutually exclusive with refresh",
  );
  const output = consumer === "home" ? HOME_OUTPUT : BUN_OUTPUT;
  if (!refreshStatus && !write)
    requireValue(
      sha256File(output) === INVENTORY_DIGESTS[output],
      `stored inventory byte contract drift: ${output}`,
    );
  const data = JSON.parse(readText(output));
  validateContracts(consumer);
  validateInventory(consumer, data);
  if (refreshStatus) {
    refresh(data, consumer);
    writeText(output, JSON.stringify(data, null, 2) + "\n");
  }
  if (root) {
    let revision = data.consumer.revision;
    if (consumer === "home" && profile && profile !== data.profile_id) {
      const aliasPath = `docs/abi/${profile}.json`;
      requireValue(
        fileExists(aliasPath),
        `unknown Home private ABI profile: ${profile}`,
      );
      const alias = JSON.parse(readText(aliasPath));
      requireValue(
        alias.base_profile === data.profile_id &&
          alias.base_revision === data.consumer.revision,
        "alias base-profile identity mismatch",
      );
      revision = alias.consumer.revision;
    }
    validateRoot(root, data, revision);
    if (write) writeText(output, JSON.stringify(data, null, 2) + "\n");
  }
  const classes = data.totals.by_classification,
    statuses = data.totals.by_status,
    label =
      consumer === "home"
        ? `Home private ABI audit: ${profile || data.profile_id}`
        : "Bun private ABI audit";
  console.log(
    `${label}: ${data.totals.symbols} symbols from ${data.totals.source_files} files; private=${classes.private_jsc || 0}, public=${classes.public_c_api || 0}, platform=${classes.platform_import || 0}, consumer-provided=${classes.consumer_provided || 0}, implemented-private=${(statuses.implemented || 0) - (classes.public_c_api || 0)}, pending-private=${statuses.pending || 0}, unclassified=0`,
  );
}
if (process.argv[1] === __filename) main();
