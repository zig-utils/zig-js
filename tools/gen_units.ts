/** Generate src/intl_units_data.zig from CLDR English units.json. */
import { readText } from "./lib/home";

const data = JSON.parse(readText(process.argv[2] || "/tmp/cldr_units.json")).main.en.units;
const widths = ["long", "short", "narrow"];
const suffix = (pattern: string) => { const index = pattern.indexOf("{0}"); return index >= 0 ? pattern.slice(index + 3) : pattern; };
const escapeZig = (text: string) => text.replace(/\\/g, "\\\\").replace(/"/g, '\\"');
const units: Record<string, Record<string, string[]>> = {};
const perSuffix: Record<string, Record<string, string>> = {};
const compound: Record<string, string> = {};
for (const width of widths) {
  if (data[width].per && data[width].per.compoundUnitPattern) compound[width] = data[width].per.compoundUnitPattern;
  for (const key of Object.keys(data[width])) {
    const value = data[width][key];
    if (!value || typeof value !== "object" || key.indexOf("-") < 0) continue;
    const id = key.slice(key.indexOf("-") + 1);
    let one = value["unitPattern-count-one"];
    let other = value["unitPattern-count-other"];
    if (one == null && other == null) continue;
    one = one == null ? other : one;
    other = other == null ? one : other;
    if (!units[id]) units[id] = {};
    if (!units[id][width]) units[id][width] = [suffix(one), suffix(other)];
    if (value.perUnitPattern != null) {
      if (!perSuffix[id]) perSuffix[id] = {};
      perSuffix[id][width] = suffix(value.perUnitPattern);
    }
  }
}
const lines = [
  "//! GENERATED from CLDR en units.json (see tools/gen_units.ts). English",
  "//! unit patterns for Intl.NumberFormat style:\"unit\": the text that follows",
  "//! the number, per width (long/short/narrow) and plural (one/other), plus",
  "//! the per-unit denominator suffix for compound X-per-Y composition.", "",
  "pub const Unit = struct {", "    id: []const u8,",
  "    l1: []const u8, lo: []const u8, // long one/other",
  "    s1: []const u8, so: []const u8, // short one/other",
  "    n1: []const u8, no: []const u8, // narrow one/other",
  "    pl: []const u8, ps: []const u8, pn: []const u8, // per-suffix long/short/narrow (denominator)",
  "};", "", "pub const units = [_]Unit{",
];
for (const id of Object.keys(units).sort()) {
  const get = (width: string, index: number) => escapeZig((units[id][width] || ["", ""])[index]);
  const per = perSuffix[id] || {};
  lines.push(`    .{ .id = "${escapeZig(id)}", .l1 = "${get("long", 0)}", .lo = "${get("long", 1)}", .s1 = "${get("short", 0)}", .so = "${get("short", 1)}", .n1 = "${get("narrow", 0)}", .no = "${get("narrow", 1)}", .pl = "${escapeZig(per.long || "")}", .ps = "${escapeZig(per.short || "")}", .pn = "${escapeZig(per.narrow || "")}" },`);
}
lines.push("};", "", `pub const compound_long = "${escapeZig(compound.long || "{0}/{1}")}";`, `pub const compound_short = "${escapeZig(compound.short || "{0}/{1}")}";`, `pub const compound_narrow = "${escapeZig(compound.narrow || "{0}/{1}")}";`, "");
process.stdout.write(lines.join("\n"));
const compoundRepr = "{" + widths.filter(width => compound[width] != null).map(width => `'${width}': '${compound[width]}'`).join(", ") + "}";
process.stderr.write(`units=${Object.keys(units).length} compound=${compoundRepr}\n`);
