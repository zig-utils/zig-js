/** Verify the pinned JSC C inventory, checked headers, and Zig exports. */
import { readText, sha256File } from "./lib/home";

declare const __dirname: string;
declare const __filename: string;
const ROOT = __dirname === "tools" ? "." : __dirname.slice(0, __dirname.lastIndexOf("/tools"));
const join = (left: string, right: string): string => `${left.replace(/\/$/, "")}/${right}`;
const INVENTORY = join(ROOT, "docs/c-api/jsc-public-api-macos-27.0.json"), INCLUDE = join(ROOT, "include/JavaScriptCore"), SOURCE = join(ROOT, "src/c_api.zig");
const PRIVATE_INVENTORIES = [join(ROOT, "docs/abi/home-private-7ed99c02-inventory.json"), join(ROOT, "docs/abi/bun-private-core-4982b91e-inventory.json")];
const PRIVATE_SUPPORT_EXPORTS = ["ZigJS__FetchHeadersBridge__installV1", "Bun__WTFStringImpl__ref", "Bun__WTFStringImpl__deref", "Bun__WTFStringImpl__destroy", "JSC__JSValue__isGetterSetter", "JSC__JSValue__isCustomGetterSetter", "JSC__JSValue__toZigException", "JSC__IDLArrayBufferRef__convertToExtern", "JSC__createEmptyObjectWithStructure", "JSC__putDirectOffset"];
const VALID_STATUSES = ["implemented", "pending", "platform_gated"];
const fail = (message: string): never => { throw new Error(`c-api audit: ${message}`); };
const matches = (pattern: RegExp, text: string, group = 1): string[] => { const values: string[] = []; let match: RegExpExecArray | null; while ((match = pattern.exec(text)) !== null) values.push(match[group]); return values; };
const unique = (values: string[]): string[] => Array.from(new Set(values));

function validateEntries(section: string, entries: any[]): void {
  const names = entries.map((entry) => String(entry.name || ""));
  if (names.some((name) => !name) || unique(names).length !== names.length) fail(`${section} names must be non-empty and unique`);
  for (const entry of entries) {
    if (!VALID_STATUSES.includes(entry.status)) fail(`${entry.name} has invalid status ${JSON.stringify(entry.status)}`);
    if (entry.status !== "implemented" && !Number.isInteger(entry.issue)) fail(`unfinished ${entry.name} must link a numeric GitHub issue`);
  }
}

export function verifyCAPI(sdkRoot = ""): void {
const data = JSON.parse(readText(INVENTORY)), functions = data.functions;
if (functions.length !== 117) fail(`expected 117 pinned functions, found ${functions.length}`);
for (const section of ["functions", "types", "callbacks", "enums", "data_symbols"]) validateEntries(section, data[section]);
const inventoryNames = functions.map((entry: any) => entry.name), declaredByHeader: Record<string, string[]> = {};
for (const header of Object.keys(data.source_headers)) {
  const file = join(INCLUDE, header), text = readText(file);
  declaredByHeader[header] = unique(matches(/JS_EXPORT\s+(?!extern\s+const\b)[\s\S]*?\b(JS[A-Za-z0-9_]+)\s*\(/g, text));
}
const declaredNames = unique([].concat(...Object.values(declaredByHeader)) as string[]);
const missing = inventoryNames.filter((name: string) => !declaredNames.includes(name)).sort(), extra = declaredNames.filter((name) => !inventoryNames.includes(name)).sort();
if (missing.length || extra.length) fail(`header/inventory drift; missing=${JSON.stringify(missing)}, extra=${JSON.stringify(extra)}`);
for (const entry of functions) if (!declaredByHeader[entry.header].includes(entry.name)) fail(`${entry.name} is not declared by its recorded header ${entry.header}`);
const allHeaderText = Object.keys(data.source_headers).map((header) => readText(join(INCLUDE, header))).join("\n");
for (const section of ["types", "callbacks", "enums", "data_symbols"]) for (const entry of data[section]) if (!new RegExp(`\\b${entry.name}\\b`).test(allHeaderText)) fail(`${section} entry ${entry.name} is absent from checked-in headers`);
const zigExports = unique(matches(/^export\s+fn\s+([A-Za-z_][A-Za-z0-9_]*)\s*\(/gm, readText(SOURCE))), implemented = functions.filter((entry: any) => entry.status === "implemented").map((entry: any) => entry.name);
const missingExports = implemented.filter((name: string) => !zigExports.includes(name)).sort();
if (missingExports.length) fail(`implemented functions missing Zig exports: ${JSON.stringify(missingExports)}`);
const extensions: string[] = data.zig_js_extensions.slice(), privateExports = PRIVATE_SUPPORT_EXPORTS.slice();
for (const inventory of PRIVATE_INVENTORIES) for (const entry of JSON.parse(readText(inventory)).declarations) if (entry.classification === "private_jsc" && entry.status === "implemented") privateExports.push(entry.name);
const privateUnique = unique(privateExports), unexpected = zigExports.filter((name) => !inventoryNames.includes(name) && !extensions.includes(name) && !privateUnique.includes(name)).sort(), missingExtensions = extensions.filter((name) => !zigExports.includes(name)).sort();
if (unexpected.length || missingExtensions.length) fail(`Zig export classification drift; unexpected=${JSON.stringify(unexpected)}, missing_extensions=${JSON.stringify(missingExtensions)}`);
if (sdkRoot) for (const header of Object.keys(data.source_headers)) { const actual = sha256File(join(sdkRoot, `System/Library/Frameworks/JavaScriptCore.framework/Headers/${header}`)); if (actual !== data.source_headers[header]) fail(`pinned SDK header drift for ${header}: ${actual} != ${data.source_headers[header]}`); }
const pending = functions.filter((entry: any) => entry.status !== "implemented").length, existing = inventoryNames.filter((name: string) => zigExports.includes(name)).length;
console.log(`c-api audit: 117 declarations, ${implemented.length} complete, ${pending} pending, ${existing} public symbols present, ${extensions.length} zig-js extensions, ${privateUnique.length} private profile exports`);
}

if (process.argv[1] === __filename) {
  let sdkRoot = "";
  const args = process.argv.slice(2);
  for (let index = 0; index < args.length; index += 1) {
    if (args[index] === "--sdk-root" && args[index + 1]) sdkRoot = args[++index];
    else fail(`unknown argument: ${args[index]}`);
  }
  verifyCAPI(sdkRoot);
}
