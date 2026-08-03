/** Capture and verify the pinned Objective-C JavaScriptCore header surface. */
import { readText, removeTemporaryDirectory, sha256File, temporaryDirectory, writeText } from "./lib/home";
declare const __dirname: string;
declare const __filename: string;
const ROOT = __dirname === "tools" ? "." : __dirname.slice(0, __dirname.lastIndexOf("/tools"));
const join = (left: string, right: string): string => `${left.replace(/\/$/, "")}/${right}`;
const INVENTORY = join(ROOT, "docs/objc-api/jsc-objc-api-macos-27.0.json"), FRAMEWORK = "System/Library/Frameworks/JavaScriptCore.framework/Headers";
const HEADERS = ["JSContext.h", "JSValue.h", "JSVirtualMachine.h", "JSManagedValue.h", "JSExport.h"], VALID_STATUSES = ["implemented", "pending", "platform_gated"];
const fail = (message: string): never => { throw new Error(`objc-api audit: ${message}`); };
const normalize = (text: string): string => text.trim().split(/\s+/).join(" ");
const uncomment = (text: string): string => text.replace(/\/\*[\s\S]*?\*\//g, "").replace(/\/\/[^\n]*/g, "");
const allMatches = (pattern: RegExp, text: string): RegExpExecArray[] => { const out: RegExpExecArray[] = []; let match: RegExpExecArray | null; while ((match = pattern.exec(text)) !== null) out.push(match); return out; };
const selector = (tail: string): string => { const parts = allMatches(/\b([A-Za-z_][A-Za-z0-9_]*)\s*:/g, tail).map((match) => match[1]); if (parts.length) return parts.join(":") + ":"; const match = /\b([A-Za-z_][A-Za-z0-9_]*)\b/.exec(tail); if (!match) fail(`cannot derive selector from ${JSON.stringify(tail)}`); return match[1]; };
const propertyName = (declaration: string): string => { const block = /\(\^\s*([A-Za-z_][A-Za-z0-9_]*)\s*\)/.exec(declaration); if (block) return block[1]; const body = declaration.split(" API_")[0].split(" NS_")[0], names = allMatches(/\b([A-Za-z_][A-Za-z0-9_]*)\b/g, body).map((match) => match[1]); if (!names.length) fail(`cannot derive property name from ${JSON.stringify(declaration)}`); return names[names.length - 1]; };
const pendingIssue = (header: string, name: string): number => header === "JSManagedValue.h" || ["addManagedReference:withOwner:", "removeManagedReference:withOwner:"].includes(name) ? 159 : header === "JSExport.h" ? 160 : 158;

function parseHeader(header: string, source: string): { containers: any[]; declarations: any[] } {
  const text = uncomment(source), containers: any[] = [], declarations: any[] = [];
  const starts = allMatches(/@(interface|protocol)\s+([A-Za-z_][A-Za-z0-9_]*)/g, text);
  for (const start of starts) {
    const signatureEnd = text.indexOf("\n", start.index), end = text.indexOf("@end", signatureEnd);
    if (end < 0) fail(`${header}: unterminated ${start[1]} ${start[2]}`);
    const signature = text.slice(start.index, signatureEnd), details = /^@(interface|protocol)\s+([A-Za-z_][A-Za-z0-9_]*)(?:\s*\(([^)]*)\))?(?:\s*:\s*([A-Za-z_][A-Za-z0-9_]*))?(?:\s*<([^>]*)>)?/.exec(signature);
    if (!details) fail(`${header}: cannot parse ${signature}`);
    const kind = details[1], name = details[2], category = details[3], superclass = details[4] || null, adopted = details[5], body = text.slice(signatureEnd, end), container = category ? `${name}(${normalize(category)})` : name;
    const prefix = text.slice(Math.max(0, start.index - 200), start.index), availability = allMatches(/(?:API_AVAILABLE|NS_CLASS_AVAILABLE)\([^\n]*\)/g, prefix).map((item) => item[0]);
    containers.push({ header, kind, name, category: category ? normalize(category) : null, superclass, adopted_protocols: (adopted || "").split(",").map((item) => item.trim()).filter(Boolean).sort(), availability: availability.length ? availability[availability.length - 1] : null });
    let pending = "";
    for (const rawLine of body.split("\n")) {
      const line = rawLine.trim();
      if (!pending && (/^[+-]\s*\(/.test(line) || line.startsWith("@property "))) pending = line;
      else if (pending) pending += " " + line;
      if (!pending.includes(";")) continue;
      const declarationText = pending.slice(0, pending.indexOf(";")); pending = "";
      if (declarationText.startsWith("@property ")) {
        const declaration = normalize(declarationText), propertyValue = propertyName(declaration);
        declarations.push({ header, container, kind: "property", name: propertyValue, declaration, status: "pending", issue: pendingIssue(header, propertyValue) });
      } else {
        const method = /^([+-])\s*\(([^)]*)\)\s*([\s\S]*)$/.exec(declarationText);
        if (!method) fail(`${header}: cannot parse method ${declarationText}`);
        const methodSelector = selector(method[3]);
        declarations.push({ header, container, kind: method[1] === "+" ? "class_method" : "instance_method", name: methodSelector, declaration: normalize(`${method[1]} (${method[2]}) ${method[3]}`), status: "pending", issue: pendingIssue(header, methodSelector) });
      }
    }
  }
  for (const typedef of allMatches(/^typedef\s+([^;]*\bJSValueProperty)\s*;/gm, text)) declarations.push({ header, container: "global", kind: "typedef", name: "JSValueProperty", declaration: normalize(`typedef ${typedef[1]}`), status: "pending", issue: 158 });
  for (const symbol of allMatches(/^JS_EXPORT\s+extern\s+([^;]*\b(JSPropertyDescriptor[A-Za-z0-9_]+))\s*;/gm, text)) declarations.push({ header, container: "global", kind: "data_symbol", name: symbol[2], declaration: normalize(`JS_EXPORT extern ${symbol[1]}`), status: "pending", issue: 158 });
  return { containers, declarations };
}

function normalizedSha(file: string): string {
  const text = readText(file), lines = text.match(/[^\n]*\n|[^\n]+$/g) || [], normalized = lines.map((line) => line.replace(/[ \t\r\n]+$/, "") + (line.endsWith("\n") || line.endsWith("\r") ? "\n" : "")).join("");
  const directory = temporaryDirectory("zig-js-objc-hash");
  try { const output = join(directory, "normalized.h"); writeText(output, normalized); return sha256File(output); } finally { removeTemporaryDirectory(directory); }
}
const declarationKey = (entry: any): string[] => ["header", "container", "kind", "name", "declaration"].map((field) => String(entry[field] || ""));
const compareKeys = (left: any[], right: any[]): number => { const a = left.map(String).join("\u0000"), b = right.map(String).join("\u0000"); return a < b ? -1 : a > b ? 1 : 0; };
function parseSurface(root: string): any {
  const hashes: Record<string, string> = {}, normalized: Record<string, string> = {}, containers: any[] = [], declarations: any[] = [];
  for (const header of HEADERS) {
    const file = join(root, header), parsed = parseHeader(header, readText(file));
    containers.push(...parsed.containers); declarations.push(...parsed.declarations); hashes[header] = sha256File(file); normalized[header] = normalizedSha(file);
  }
  if (!uncomment(readText(join(root, "JSExport.h"))).includes("@protocol JSExport")) fail("JSExport protocol is absent");
  declarations.push({ header: "JSExport.h", container: "global", kind: "macro", name: "JSExportAs", declaration: "#define JSExportAs(PropertyName, Selector)", status: "pending", issue: 160 });
  containers.sort((a, b) => compareKeys([a.header, a.kind, a.name, a.category === null ? "None" : a.category], [b.header, b.kind, b.name, b.category === null ? "None" : b.category]));
  declarations.sort((a, b) => compareKeys(declarationKey(a), declarationKey(b)));
  return { hashes, normalized, containers, declarations };
}
function capture(sdkRoot: string): any { const surface = parseSurface(join(sdkRoot, FRAMEWORK)); return { schema_version: 1, target: { platform: "macOS", sdk_version: "27.0", sdk_build: "26A5368g", captured_at: "2026-07-16" }, source_headers: surface.hashes, checked_header_hashes: surface.normalized, containers: surface.containers, declarations: surface.declarations }; }
function validate(data: any): void {
  if (data.schema_version !== 1) fail("schema_version must be 1");
  if (JSON.stringify(Object.keys(data.source_headers || {}).sort()) !== JSON.stringify(HEADERS.slice().sort())) fail("source_headers must name exactly the five targeted Objective-C headers");
  if (JSON.stringify(Object.keys(data.checked_header_hashes || {}).sort()) !== JSON.stringify(HEADERS.slice().sort())) fail("checked_header_hashes must name exactly the five targeted Objective-C headers");
  if (!Array.isArray(data.containers) || !Array.isArray(data.declarations)) fail("containers and declarations must be arrays");
  const containerKeys = data.containers.map((entry: any) => JSON.stringify([entry.header, entry.kind, entry.name, entry.category])); if (new Set(containerKeys).size !== containerKeys.length) fail("container entries must be unique");
  const declarationKeys = data.declarations.map((entry: any) => JSON.stringify(declarationKey(entry))); if (new Set(declarationKeys).size !== declarationKeys.length) fail("declaration entries must be unique");
  const known = data.containers.map((entry: any) => entry.category ? `${entry.name}(${entry.category})` : entry.name);
  for (const entry of data.declarations) { if (entry.container !== "global" && !known.includes(entry.container)) fail(`unknown declaration container ${entry.container}`); if (!VALID_STATUSES.includes(entry.status)) fail(`${entry.name} has invalid status ${JSON.stringify(entry.status)}`); if (entry.status !== "implemented" && !Number.isInteger(entry.issue)) fail(`unfinished ${entry.name} must link a numeric GitHub issue`); }
}

export function verifyObjCAPI(sdkRoot = "", captureOnly = false): void {
  if (captureOnly) { if (!sdkRoot) fail("--capture requires --sdk-root"); process.stdout.write(JSON.stringify(capture(sdkRoot), null, 2) + "\n"); return; }
  const data = JSON.parse(readText(INVENTORY)); validate(data);
  const checked = parseSurface(join(ROOT, "include/JavaScriptCore"));
  if (JSON.stringify(checked.normalized) !== JSON.stringify(data.checked_header_hashes)) fail("checked-in Objective-C header hashes drifted from the pin");
  if (JSON.stringify(checked.containers) !== JSON.stringify(data.containers)) fail("checked-in Objective-C containers drifted from the inventory");
  if (JSON.stringify(checked.declarations.map(declarationKey)) !== JSON.stringify(data.declarations.map(declarationKey))) fail("checked-in Objective-C declarations drifted from the inventory");
  if (sdkRoot) { const actual = capture(sdkRoot); if (JSON.stringify(actual.source_headers) !== JSON.stringify(data.source_headers)) fail("pinned Objective-C SDK header hashes drifted"); if (JSON.stringify(actual.checked_header_hashes) !== JSON.stringify(data.checked_header_hashes)) fail("normalized Objective-C SDK header hashes drifted"); if (JSON.stringify(actual.containers) !== JSON.stringify(data.containers)) fail("pinned Objective-C containers drifted"); if (JSON.stringify(actual.declarations.map(declarationKey)) !== JSON.stringify(data.declarations.map(declarationKey))) fail("pinned Objective-C declarations drifted"); }
  const implemented = data.declarations.filter((entry: any) => entry.status === "implemented").length;
  console.log(`objc-api audit: ${data.containers.length} containers, ${data.declarations.length} declarations, ${implemented} complete, ${data.declarations.length - implemented} pending`);
}
if (process.argv[1] === __filename) {
  let sdkRoot = "", captureOnly = false; const args = process.argv.slice(2);
  for (let index = 0; index < args.length; index += 1) { if (args[index] === "--sdk-root" && args[index + 1]) sdkRoot = args[++index]; else if (args[index] === "--capture") captureOnly = true; else fail(`unknown argument: ${args[index]}`); }
  verifyObjCAPI(sdkRoot, captureOnly);
}
