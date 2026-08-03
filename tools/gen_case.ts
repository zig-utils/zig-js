/** Generate Unicode simple and unconditional full case-mapping tables. */
import { readText, writeText } from "./lib/home";

const ucd = process.env.UCD || process.argv[2] || "/tmp";
const output = process.argv[3] || "src/unicode_case_data.zig";
const join = (left: string, right: string) => left.replace(/\/$/, "") + "/" + right;
const unicode = readText(join(ucd, "UnicodeData.txt"));
const special = readText(join(ucd, "SpecialCasing.txt"));
const simpleUpper: string[] = [], simpleLower: string[] = [];
for (const line of unicode.split("\n")) {
  const fields = line.split(";");
  if (fields.length < 14) continue;
  if (fields[12]) simpleUpper.push(`    .{ .cp = 0x${fields[0]}, .to = 0x${fields[12]} },`);
  if (fields[13]) simpleLower.push(`    .{ .cp = 0x${fields[0]}, .to = 0x${fields[13]} },`);
}
function full(field: number): string[] {
  const rows: string[] = [];
  for (const raw of special.split("\n")) {
    const line = raw.split("#")[0];
    const fields = line.split(";");
    if (fields.length < 5 || fields[4].replace(/[ \t]/g, "") !== "") continue;
    const parts = fields[field - 1].trim().split(/\s+/).filter(Boolean);
    if (parts.length <= 1) continue;
    const values = ["a", "b", "c"].slice(0, parts.length).map((name, index) => `, .${name} = 0x${parts[index]}`).join("");
    rows.push(`    .{ .cp = 0x${fields[0].replace(/[ \t]/g, "")}, .len = ${parts.length}${values} },`);
  }
  return rows.sort();
}
const fullUpper = full(4), fullLower = full(2);
const lines = [
  "//! GENERATED from Unicode UnicodeData.txt + SpecialCasing.txt. Do not edit.",
  "//! Regenerate via tools/gen_case.ts. Simple (1:1) and full (1:N,",
  "//! unconditional) case mappings for String.prototype.to{Upper,Lower}Case.",
  "//! Every table is sorted ascending by .cp for binary search.", "",
  "pub const Pair = struct { cp: u21, to: u21 };",
  "pub const Full = struct { cp: u21, a: u21 = 0, b: u21 = 0, c: u21 = 0, len: u8 };", "",
  "pub const simple_upper = [_]Pair{", ...simpleUpper, "};", "",
  "pub const simple_lower = [_]Pair{", ...simpleLower, "};", "",
  "pub const full_upper = [_]Full{", ...fullUpper, "};", "",
  "pub const full_lower = [_]Full{", ...fullLower, "};", "",
];
const rendered = lines.join("\n");
writeText(output, rendered);
console.log(`wrote ${output}: ${simpleUpper.length + simpleLower.length + fullUpper.length + fullLower.length} entries`);
