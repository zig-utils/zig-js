#!/usr/bin/env python3
"""Generate src/unicode_grapheme_data.zig from the UCD grapheme-break data."""
import sys, re

def parse_ranges(path, want_prop=None, field=1):
    out = []
    for line in open(path):
        line = line.split('#')[0].strip()
        if not line:
            continue
        parts = [p.strip() for p in line.split(';')]
        if len(parts) <= field:
            continue
        prop = parts[field]
        if want_prop is not None and prop != want_prop:
            continue
        rng = parts[0]
        if '..' in rng:
            lo, hi = rng.split('..')
        else:
            lo = hi = rng
        out.append((int(lo, 16), int(hi, 16), prop))
    return out

# GraphemeBreakProperty: class per range.
CLASS = {'CR':'cr','LF':'lf','Control':'control','Extend':'extend','ZWJ':'zwj',
         'Regional_Indicator':'ri','Prepend':'prepend','SpacingMark':'spacingmark',
         'L':'l','V':'v','T':'t','LV':'lv','LVT':'lvt'}
gb = []
for lo, hi, prop in parse_ranges('/tmp/gbp.txt'):
    if prop in CLASS:
        gb.append((lo, hi, CLASS[prop]))
gb.sort()

# Extended_Pictographic from emoji-data.txt.
extpict = [(lo, hi) for lo, hi, _ in parse_ranges('/tmp/emoji.txt', 'Extended_Pictographic')]
extpict.sort()

# InCB (Indic Conjunct Break) = Linker | Consonant | Extend from DerivedCoreProperties.
incb = []
for line in open('/tmp/dcp.txt'):
    line = line.split('#')[0].strip()
    if not line or 'InCB' not in line:
        continue
    parts = [p.strip() for p in line.split(';')]
    # format: range ; InCB ; Linker
    if len(parts) < 3 or parts[1] != 'InCB':
        continue
    kind = {'Linker':'linker','Consonant':'consonant','Extend':'incb_extend'}.get(parts[2])
    if not kind:
        continue
    rng = parts[0]
    lo, hi = (rng.split('..') if '..' in rng else (rng, rng))
    incb.append((int(lo,16), int(hi,16), kind))
incb.sort()

def emit(name, rows, has_kind):
    L = [f"pub const {name} = [_]{'GB' if has_kind else 'Range'}{{"]
    for r in rows:
        if has_kind:
            L.append('    .{ .lo = 0x%X, .hi = 0x%X, .v = .%s },' % (r[0], r[1], r[2]))
        else:
            L.append('    .{ .lo = 0x%X, .hi = 0x%X },' % (r[0], r[1]))
    L.append("};")
    return "\n".join(L)

out = []
out.append("//! GENERATED from UCD GraphemeBreakProperty.txt, emoji-data.txt, and")
out.append("//! DerivedCoreProperties.txt (InCB) — tools/gen_grapheme.py. Sorted ranges")
out.append("//! for the UAX #29 extended grapheme cluster algorithm.")
out.append("")
out.append("pub const Class = enum { other, cr, lf, control, extend, zwj, ri, prepend, spacingmark, l, v, t, lv, lvt };")
out.append("pub const Incb = enum { linker, consonant, incb_extend };")
out.append("pub const GB = struct { lo: u21, hi: u21, v: Class };")
out.append("pub const Range = struct { lo: u21, hi: u21 };")
out.append("pub const IncbR = struct { lo: u21, hi: u21, v: Incb };")
out.append("")
out.append(emit("gb_class", gb, True))
out.append("")
out.append(emit("ext_pictographic", extpict, False))
out.append("")
# incb uses IncbR
L = ["pub const incb = [_]IncbR{"]
for r in incb:
    L.append('    .{ .lo = 0x%X, .hi = 0x%X, .v = .%s },' % (r[0], r[1], r[2]))
L.append("};")
out.append("\n".join(L))
out.append("")
sys.stdout.write("\n".join(out))
sys.stderr.write("gb=%d extpict=%d incb=%d\n" % (len(gb), len(extpict), len(incb)))
