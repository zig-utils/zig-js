#!/usr/bin/env python3
"""Generate src/intl_localeinfo.zig from CLDR calendarPreferenceData + timeData."""
import json, sys
cal = json.load(open('/tmp/calpref.json'))['supplemental']['calendarPreferenceData']
time = json.load(open('/tmp/timedata.json'))['supplemental']['timeData']

def mapcal(c):
    return 'gregory' if c == 'gregorian' else c

default_cal = [mapcal(c) for c in cal.get('001', ['gregorian'])]
cals = {}
for r, lst in cal.items():
    if r == '001' or '-' in r:
        continue
    cals[r] = [mapcal(c) for c in lst]

HC = {'h': 'h12', 'H': 'h23', 'K': 'h11', 'k': 'h24'}
def pref_hc(entry):
    p = entry.get('_preferred', 'H').split()[0]
    return HC.get(p, 'h23')
default_hc = pref_hc(time.get('001', {}))
hcs = {}
for r, entry in time.items():
    if r == '001' or '-' in r:
        continue
    hcs[r] = pref_hc(entry)

out = []
out.append("//! GENERATED from CLDR calendarPreferenceData.json + timeData.json")
out.append("//! (tools/gen_localeinfo.py). Region preferences for Intl.Locale")
out.append("//! getCalendars (preferred calendar list) and getHourCycles.")
out.append("")
out.append("pub const Cals = struct { region: []const u8, cals: []const []const u8 };")
out.append("pub const Hc = struct { region: []const u8, hc: []const u8 };")
out.append("")
out.append('pub const default_calendars = [_][]const u8{ %s };' % ", ".join('"%s"' % c for c in default_cal))
out.append('pub const default_hour_cycle = "%s";' % default_hc)
out.append("")
out.append("pub const calendars = [_]Cals{")
for r in sorted(cals):
    if cals[r] != default_cal:
        out.append('    .{ .region = "%s", .cals = &.{ %s } },' % (r, ", ".join('"%s"' % c for c in cals[r])))
out.append("};")
out.append("")
out.append("pub const hour_cycles = [_]Hc{")
for r in sorted(hcs):
    if hcs[r] != default_hc:
        out.append('    .{ .region = "%s", .hc = "%s" },' % (r, hcs[r]))
out.append("};")
out.append("")
sys.stdout.write("\n".join(out))
sys.stderr.write("cal_exceptions=%d hc_exceptions=%d default_cal=%s default_hc=%s\n" % (
    sum(1 for r in cals if cals[r]!=default_cal), sum(1 for r in hcs if hcs[r]!=default_hc), default_cal, default_hc))
