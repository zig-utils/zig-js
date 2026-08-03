/** Generate UAX #29 grapheme-break tables from UCD inputs. */
import { readText } from "./lib/home";

type Range = [number, number, string];
function parseRanges(path: string, wanted?: string, field = 1): Range[] {
  const rows: Range[] = [];
  for (const raw of readText(path).split("\n")) {
    const line = raw.split("#")[0].trim();
    if (!line) continue;
    const parts = line.split(";").map(value => value.trim());
    if (parts.length <= field) continue;
    const property = parts[field];
    if (wanted != null && property !== wanted) continue;
    const bounds = parts[0].split("..");
    rows.push([Number.parseInt(bounds[0], 16), Number.parseInt(bounds.length > 1 ? bounds[1] : bounds[0], 16), property]);
  }
  return rows;
}
const classes: Record<string, string> = { CR: "cr", LF: "lf", Control: "control", Extend: "extend", ZWJ: "zwj", Regional_Indicator: "ri", Prepend: "prepend", SpacingMark: "spacingmark", L: "l", V: "v", T: "t", LV: "lv", LVT: "lvt" };
const gb: Range[] = [];
for (const [low, high, property] of parseRanges(process.argv[2] || "/tmp/gbp.txt")) if (classes[property]) gb.push([low, high, classes[property]]);
gb.sort((a, b) => a[0] - b[0] || a[1] - b[1]);
const pictographic: Range[] = parseRanges(process.argv[3] || "/tmp/emoji.txt", "Extended_Pictographic").sort((a, b) => a[0] - b[0] || a[1] - b[1]);
const incb: Range[] = [];
const incbKinds: Record<string, string> = { Linker: "linker", Consonant: "consonant", Extend: "incb_extend" };
for (const raw of readText(process.argv[4] || "/tmp/dcp.txt").split("\n")) {
  const line = raw.split("#")[0].trim();
  if (!line || line.indexOf("InCB") < 0) continue;
  const parts = line.split(";").map(value => value.trim());
  if (parts.length < 3 || parts[1] !== "InCB" || !incbKinds[parts[2]]) continue;
  const bounds = parts[0].split("..");
  incb.push([Number.parseInt(bounds[0], 16), Number.parseInt(bounds.length > 1 ? bounds[1] : bounds[0], 16), incbKinds[parts[2]]]);
}
incb.sort((a, b) => a[0] - b[0] || a[1] - b[1]);
const hex = (value: number) => value.toString(16).toUpperCase();
function emit(name: string, rows: Range[], kind: boolean): string {
  const lines = [`pub const ${name} = [_]${kind ? "GB" : "Range"}{`];
  for (const row of rows) lines.push(kind ? `    .{ .lo = 0x${hex(row[0])}, .hi = 0x${hex(row[1])}, .v = .${row[2]} },` : `    .{ .lo = 0x${hex(row[0])}, .hi = 0x${hex(row[1])} },`);
  lines.push("};");
  return lines.join("\n");
}
const out = [
  "//! GENERATED from UCD GraphemeBreakProperty.txt, emoji-data.txt, and",
  "//! DerivedCoreProperties.txt (InCB) — tools/gen_grapheme.ts. Sorted ranges",
  "//! for the UAX #29 extended grapheme cluster algorithm.", "",
  "pub const Class = enum { other, cr, lf, control, extend, zwj, ri, prepend, spacingmark, l, v, t, lv, lvt };",
  "pub const Incb = enum { linker, consonant, incb_extend };",
  "pub const GB = struct { lo: u21, hi: u21, v: Class };",
  "pub const Range = struct { lo: u21, hi: u21 };",
  "pub const IncbR = struct { lo: u21, hi: u21, v: Incb };", "", emit("gb_class", gb, true), "", emit("ext_pictographic", pictographic, false), "", "pub const incb = [_]IncbR{",
];
for (const row of incb) out.push(`    .{ .lo = 0x${hex(row[0])}, .hi = 0x${hex(row[1])}, .v = .${row[2]} },`);
out.push("};", "");
process.stdout.write(out.join("\n"));
process.stderr.write(`gb=${gb.length} extpict=${pictographic.length} incb=${incb.length}\n`);
