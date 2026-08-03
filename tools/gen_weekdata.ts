/** Generate src/intl_weekdata.zig from CLDR supplemental weekData.json. */
import { readText } from "./lib/home";

const data = JSON.parse(readText(process.argv[2] || "/tmp/weekdata.json")).supplemental.weekData;
const day: Record<string, number> = { mon: 1, tue: 2, wed: 3, thu: 4, fri: 5, sat: 6, sun: 7 };
const first: Record<string, number> = {};
for (const region of Object.keys(data.firstDay)) {
  if (region !== "001" && region.indexOf("-") < 0) first[region] = day[data.firstDay[region]];
}
const defaultFirst = day[data.firstDay["001"] || "mon"];
const starts = data.weekendStart || {};
const ends = data.weekendEnd || {};
const regions: Record<string, boolean> = {};
for (const region of Object.keys(starts)) regions[region] = true;
for (const region of Object.keys(ends)) regions[region] = true;
const weekends: Record<string, number[]> = {};
for (const region of Object.keys(regions)) {
  if (region === "001" || region.indexOf("-") >= 0) continue;
  const start = day[starts[region] || starts["001"] || "sat"];
  const end = day[ends[region] || ends["001"] || "sun"];
  const days: number[] = [];
  let current = start;
  while (true) {
    days.push(current);
    if (current === end) break;
    current = current === 7 ? 1 : current + 1;
  }
  weekends[region] = days;
}
const defaultWeekend = [day[starts["001"] || "sat"], day[ends["001"] || "sun"]];
const equal = (a: number[], b: number[]) => a.length === b.length && a.every((value, index) => value === b[index]);
const lines = [
  "//! GENERATED from CLDR supplemental weekData.json (tools/gen_weekdata.ts).",
  "//! Per-region first day of week and weekend days for Intl.Locale.getWeekInfo.", "",
  "pub const First = struct { region: []const u8, day: u8 };",
  "pub const Weekend = struct { region: []const u8, days: []const u8 };", "",
  `pub const default_first_day: u8 = ${defaultFirst};`,
  `pub const default_weekend = [_]u8{ ${defaultWeekend.join(", ")} };`, "",
  "pub const first_day = [_]First{",
];
let firstCount = 0;
for (const region of Object.keys(first).sort()) if (first[region] !== defaultFirst) {
  lines.push(`    .{ .region = "${region}", .day = ${first[region]} },`);
  firstCount += 1;
}
lines.push("};", "", "pub const weekends = [_]Weekend{");
let weekendCount = 0;
for (const region of Object.keys(weekends).sort()) if (!equal(weekends[region], defaultWeekend)) {
  lines.push(`    .{ .region = "${region}", .days = &.{ ${weekends[region].join(", ")} } },`);
  weekendCount += 1;
}
lines.push("};", "");
process.stdout.write(lines.join("\n"));
process.stderr.write(`first_exceptions=${firstCount} weekend_exceptions=${weekendCount} default_first=${defaultFirst}\n`);
