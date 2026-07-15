#!/usr/bin/env python3
"""Generate src/intl_units_data.zig from CLDR en units.json."""
import json, sys

d = json.load(open('/tmp/cldr_units.json'))['main']['en']['units']

def suffix(pat):
    # pattern is "{0} meter" / "{0}m" / "{0}°C"; return the part after {0}.
    i = pat.find('{0}')
    return pat[i+3:] if i >= 0 else pat

# Build per-width maps: JS unit id -> (one_suffix, other_suffix)
widths = ['long', 'short', 'narrow']
units = {}   # id -> {width: (one, other)}
per_suffix = {}  # id -> {width: perUnitPattern-suffix} (denominator form, e.g. "/s")
compound = {}    # width -> compoundUnitPattern "{0}/{1}"

for w in widths:
    comp = d[w].get('per', {}).get('compoundUnitPattern')
    if comp:
        compound[w] = comp
    for key, val in d[w].items():
        if not isinstance(val, dict):
            continue
        if '-' not in key:
            continue
        uid = key.split('-', 1)[1]  # strip category (length-meter -> meter)
        one = val.get('unitPattern-count-one')
        other = val.get('unitPattern-count-other')
        if one is None and other is None:
            continue
        one = one if one is not None else other
        other = other if other is not None else one
        units.setdefault(uid, {})
        if w not in units[uid]:
            units[uid][w] = (suffix(one), suffix(other))
        pu = val.get('perUnitPattern')
        if pu is not None:
            per_suffix.setdefault(uid, {})[w] = suffix(pu)

def zesc(s):
    return s.replace('\\', '\\\\').replace('"', '\\"')

# Emit a table: unit id + 6 suffixes (l1,lo,s1,so,n1,no) + per denom forms (pl,ps,pn)
lines = []
lines.append("//! GENERATED from CLDR en units.json (see tools/gen_units.py). English")
lines.append("//! unit patterns for Intl.NumberFormat style:\"unit\": the text that follows")
lines.append("//! the number, per width (long/short/narrow) and plural (one/other), plus")
lines.append("//! the per-unit denominator suffix for compound X-per-Y composition.")
lines.append("")
lines.append("pub const Unit = struct {")
lines.append("    id: []const u8,")
lines.append("    l1: []const u8, lo: []const u8, // long one/other")
lines.append("    s1: []const u8, so: []const u8, // short one/other")
lines.append("    n1: []const u8, no: []const u8, // narrow one/other")
lines.append("    pl: []const u8, ps: []const u8, pn: []const u8, // per-suffix long/short/narrow (denominator)")
lines.append("};")
lines.append("")
lines.append("pub const units = [_]Unit{")
for uid in sorted(units):
    u = units[uid]
    def g(w, i):
        return zesc(u.get(w, ('', ''))[i])
    ps = per_suffix.get(uid, {})
    lines.append('    .{ .id = "%s", .l1 = "%s", .lo = "%s", .s1 = "%s", .so = "%s", .n1 = "%s", .no = "%s", .pl = "%s", .ps = "%s", .pn = "%s" },' % (
        zesc(uid), g('long',0), g('long',1), g('short',0), g('short',1), g('narrow',0), g('narrow',1),
        zesc(ps.get('long','')), zesc(ps.get('short','')), zesc(ps.get('narrow',''))))
lines.append("};")
lines.append("")
# compound patterns
lines.append('pub const compound_long = "%s";' % zesc(compound.get('long','{0}/{1}')))
lines.append('pub const compound_short = "%s";' % zesc(compound.get('short','{0}/{1}')))
lines.append('pub const compound_narrow = "%s";' % zesc(compound.get('narrow','{0}/{1}')))
lines.append("")
sys.stdout.write("\n".join(lines))
sys.stderr.write("units=%d compound=%s\n" % (len(units), compound))
