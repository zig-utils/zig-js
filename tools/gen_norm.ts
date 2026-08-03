/** Generate Unicode normalization tables from UCD inputs. */
import { readText } from "./lib/home";

const ccc: Record<string, number> = {}, canonical: Record<string, number[]> = {}, compatibility: Record<string, number[]> = {};
for (const line of readText(process.argv[2] || "/tmp/UnicodeData.txt").split("\n")) {
  const parts = line.replace(/\r$/, "").split(";");
  if (parts.length < 6) continue;
  const point = Number.parseInt(parts[0], 16), combining = Number(parts[3]);
  if (combining !== 0) ccc[String(point)] = combining;
  const decomposition = parts[5].trim();
  if (!decomposition) continue;
  if (decomposition[0] === "<") {
    const rest = decomposition.slice(decomposition.indexOf(">") + 1).trim();
    compatibility[String(point)] = rest ? rest.split(/\s+/).map(value => Number.parseInt(value, 16)) : [];
  } else canonical[String(point)] = decomposition.split(/\s+/).map(value => Number.parseInt(value, 16));
}
const excluded: Record<string, boolean> = {};
for (const raw of readText(process.argv[3] || "/tmp/CompositionExclusions.txt").split("\n")) {
  const line = raw.split("#")[0].trim();
  if (line) excluded[String(Number.parseInt(line.split(/\s+/)[0], 16))] = true;
}
const compose: Array<[number, number, number]> = [];
for (const key of Object.keys(canonical)) {
  const point = Number(key), sequence = canonical[key];
  if (sequence.length === 2 && !excluded[key] && !ccc[String(sequence[0])]) compose.push([sequence[0], sequence[1], point]);
}
compose.sort((a, b) => a[0] - b[0] || a[1] - b[1]);
const keys = (record: any) => Object.keys(record).map(Number).sort((a, b) => a - b);
const hex4 = (value: number) => value.toString(16).toUpperCase().padStart(4, "0");
const decompLine = (point: number, sequence: number[]) => `.{ .cp = 0x${hex4(point)}, .d = &.{ ${sequence.map(value => "0x" + hex4(value)).join(", ")} } }`;
const out = [
  "//! GENERATED from the Unicode Character Database (UnicodeData.txt +",
  "//! CompositionExclusions.txt). Do not edit by hand; see tools/gen_norm.ts.",
  "//! Canonical/compatibility decomposition, combining classes, and primary",
  "//! composites for String.prototype.normalize (NFC/NFD/NFKC/NFKD).", "",
  "pub const Decomp = struct { cp: u21, d: []const u21 };",
  "pub const CCC = struct { cp: u21, cc: u8 };",
  "pub const Compose = struct { a: u21, b: u21, to: u21 };", "", "pub const canon_decomp = [_]Decomp{",
];
for (const point of keys(canonical)) out.push("    " + decompLine(point, canonical[String(point)]) + ",");
out.push("};", "", "pub const compat_decomp = [_]Decomp{");
for (const point of keys(compatibility)) out.push("    " + decompLine(point, compatibility[String(point)]) + ",");
out.push("};", "", "pub const ccc_table = [_]CCC{");
for (const point of keys(ccc)) out.push(`    .{ .cp = 0x${hex4(point)}, .cc = ${ccc[String(point)]} },`);
out.push("};", "", "pub const compose_table = [_]Compose{");
for (const [a, b, to] of compose) out.push(`    .{ .a = 0x${hex4(a)}, .b = 0x${hex4(b)}, .to = 0x${hex4(to)} },`);
out.push("};", "");
process.stdout.write(out.join("\n"));
process.stderr.write(`canon=${Object.keys(canonical).length} compat=${Object.keys(compatibility).length} ccc=${Object.keys(ccc).length} compose=${compose.length}\n`);
