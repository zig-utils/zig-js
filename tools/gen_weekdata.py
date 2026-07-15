#!/usr/bin/env python3
"""Generate src/intl_weekdata.zig from CLDR supplemental weekData.json."""
import json, sys
d = json.load(open('/tmp/weekdata.json'))['supplemental']['weekData']
DAY = {'mon':1,'tue':2,'wed':3,'thu':4,'fri':5,'sat':6,'sun':7}

first = {r: DAY[v] for r, v in d['firstDay'].items() if r != '001' and '-' not in r}
default_first = DAY[d['firstDay'].get('001','mon')]

wstart = d.get('weekendStart', {})
wend = d.get('weekendEnd', {})
regions = set(list(wstart.keys()) + list(wend.keys()))
weekend = {}
for r in regions:
    if r == '001' or '-' in r:
        continue
    s = DAY[wstart.get(r, wstart.get('001','sat'))]
    e = DAY[wend.get(r, wend.get('001','sun'))]
    days = list(range(s, e+1)) if s <= e else list(range(s,8))+list(range(1,e+1))
    weekend[r] = days
default_weekend = [DAY[wstart.get('001','sat')], DAY[wend.get('001','sun')]]

out = []
out.append("//! GENERATED from CLDR supplemental weekData.json (tools/gen_weekdata.py).")
out.append("//! Per-region first day of week and weekend days for Intl.Locale.getWeekInfo.")
out.append("")
out.append("pub const First = struct { region: []const u8, day: u8 };")
out.append("pub const Weekend = struct { region: []const u8, days: []const u8 };")
out.append("")
out.append("pub const default_first_day: u8 = %d;" % default_first)
out.append("pub const default_weekend = [_]u8{ %s };" % ", ".join(str(x) for x in default_weekend))
out.append("")
out.append("pub const first_day = [_]First{")
for r in sorted(first):
    if first[r] != default_first:
        out.append('    .{ .region = "%s", .day = %d },' % (r, first[r]))
out.append("};")
out.append("")
out.append("pub const weekends = [_]Weekend{")
for r in sorted(weekend):
    if weekend[r] != default_weekend:
        out.append('    .{ .region = "%s", .days = &.{ %s } },' % (r, ", ".join(str(x) for x in weekend[r])))
out.append("};")
out.append("")
sys.stdout.write("\n".join(out))
sys.stderr.write("first_exceptions=%d weekend_exceptions=%d default_first=%d\n" % (
    sum(1 for r in first if first[r]!=default_first),
    sum(1 for r in weekend if weekend[r]!=default_weekend), default_first))
