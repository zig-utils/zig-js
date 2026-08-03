/** Generate src/intl_localeinfo.zig from CLDR calendarPreferenceData and timeData. */
import { readText } from "./lib/home";

const cal = JSON.parse(readText(process.argv[2] || "/tmp/calpref.json")).supplemental.calendarPreferenceData;
const time = JSON.parse(readText(process.argv[3] || "/tmp/timedata.json")).supplemental.timeData;
const mapCalendar = (name: string) => name === "gregorian" ? "gregory" : name;
const defaultCalendars: string[] = (cal["001"] || ["gregorian"]).map(mapCalendar);
const calendars: Record<string, string[]> = {};
for (const region of Object.keys(cal)) if (region !== "001" && region.indexOf("-") < 0) calendars[region] = cal[region].map(mapCalendar);
const cycles: Record<string, string> = { h: "h12", H: "h23", K: "h11", k: "h24" };
const preferred = (entry: any) => cycles[String((entry && entry._preferred) || "H").split(" ")[0]] || "h23";
const defaultCycle = preferred(time["001"] || {});
const hourCycles: Record<string, string> = {};
for (const region of Object.keys(time)) if (region !== "001" && region.indexOf("-") < 0) hourCycles[region] = preferred(time[region]);
const same = (a: string[], b: string[]) => a.length === b.length && a.every((value, index) => value === b[index]);
const quoted = (values: string[]) => values.map(value => `"${value}"`).join(", ");
const lines = [
  "//! GENERATED from CLDR calendarPreferenceData.json + timeData.json",
  "//! (tools/gen_localeinfo.ts). Region preferences for Intl.Locale",
  "//! getCalendars (preferred calendar list) and getHourCycles.", "",
  "pub const Cals = struct { region: []const u8, cals: []const []const u8 };",
  "pub const Hc = struct { region: []const u8, hc: []const u8 };", "",
  `pub const default_calendars = [_][]const u8{ ${quoted(defaultCalendars)} };`,
  `pub const default_hour_cycle = "${defaultCycle}";`, "", "pub const calendars = [_]Cals{",
];
let calendarCount = 0;
for (const region of Object.keys(calendars).sort()) if (!same(calendars[region], defaultCalendars)) {
  lines.push(`    .{ .region = "${region}", .cals = &.{ ${quoted(calendars[region])} } },`);
  calendarCount += 1;
}
lines.push("};", "", "pub const hour_cycles = [_]Hc{");
let cycleCount = 0;
for (const region of Object.keys(hourCycles).sort()) if (hourCycles[region] !== defaultCycle) {
  lines.push(`    .{ .region = "${region}", .hc = "${hourCycles[region]}" },`);
  cycleCount += 1;
}
lines.push("};", "");
process.stdout.write(lines.join("\n"));
process.stderr.write(`cal_exceptions=${calendarCount} hc_exceptions=${cycleCount} default_cal=${JSON.stringify(defaultCalendars).replace(/"/g, "'")} default_hc=${defaultCycle}\n`);
