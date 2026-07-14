#!/usr/bin/env python3
"""Generate src/unicode_normalize_data.zig from the Unicode Character Database.

Download the two UCD inputs, then run this generator:

    curl -sO https://www.unicode.org/Public/UCD/latest/ucd/UnicodeData.txt
    curl -sO https://www.unicode.org/Public/UCD/latest/ucd/CompositionExclusions.txt
    (place both in /tmp/, or edit the paths below)
    python3 tools/gen_norm.py > src/unicode_normalize_data.zig

Emits canonical/compatibility decompositions, non-zero combining classes, and
the primary-composite set (canonical decompositions of length 2 that are not
composition-excluded and whose first element is a starter). Hangul is handled
algorithmically in unicode_normalize.zig, so no Hangul entries are emitted.
Verify against NormalizationTest.txt after regenerating.
"""
import sys

ccc = {}          # cp -> combining class (non-zero)
canon = {}        # cp -> [cps]   (canonical, untagged)
compat = {}       # cp -> [cps]   (compatibility, tagged only)

with open('/tmp/UnicodeData.txt') as f:
    for line in f:
        parts = line.rstrip('\n').split(';')
        if len(parts) < 6:
            continue
        cp = int(parts[0], 16)
        cc = int(parts[3])
        if cc != 0:
            ccc[cp] = cc
        dec = parts[5].strip()
        if dec:
            if dec.startswith('<'):
                # compatibility (tagged)
                seq = [int(x, 16) for x in dec[dec.index('>')+1:].split()]
                compat[cp] = seq
            else:
                seq = [int(x, 16) for x in dec.split()]
                canon[cp] = seq

# composition exclusions (script list)
excl = set()
with open('/tmp/CompositionExclusions.txt') as f:
    for line in f:
        line = line.split('#')[0].strip()
        if not line:
            continue
        excl.add(int(line.split()[0], 16))

# primary composites: canonical decomp of length 2, not excluded, first char is a starter
compose = {}
for cp, seq in canon.items():
    if len(seq) != 2:
        continue
    if cp in excl:
        continue
    a, b = seq
    if ccc.get(a, 0) != 0:   # non-starter decomposition
        continue
    compose[(a, b)] = cp

def emit():
    out = []
    out.append("//! GENERATED from the Unicode Character Database (UnicodeData.txt +")
    out.append("//! CompositionExclusions.txt). Do not edit by hand; see tools/gen_norm.py.")
    out.append("//! Canonical/compatibility decomposition, combining classes, and primary")
    out.append("//! composites for String.prototype.normalize (NFC/NFD/NFKC/NFKD).")
    out.append("")
    out.append("pub const Decomp = struct { cp: u21, d: []const u21 };")
    out.append("pub const CCC = struct { cp: u21, cc: u8 };")
    out.append("pub const Compose = struct { a: u21, b: u21, to: u21 };")
    out.append("")
    def dline(cp, seq):
        return ".{ .cp = 0x%04X, .d = &.{ %s } }" % (cp, ", ".join("0x%04X" % c for c in seq))
    out.append("pub const canon_decomp = [_]Decomp{")
    for cp in sorted(canon):
        out.append("    " + dline(cp, canon[cp]) + ",")
    out.append("};")
    out.append("")
    out.append("pub const compat_decomp = [_]Decomp{")
    for cp in sorted(compat):
        out.append("    " + dline(cp, compat[cp]) + ",")
    out.append("};")
    out.append("")
    out.append("pub const ccc_table = [_]CCC{")
    for cp in sorted(ccc):
        out.append("    .{ .cp = 0x%04X, .cc = %d }," % (cp, ccc[cp]))
    out.append("};")
    out.append("")
    out.append("pub const compose_table = [_]Compose{")
    for (a, b) in sorted(compose):
        out.append("    .{ .a = 0x%04X, .b = 0x%04X, .to = 0x%04X }," % (a, b, compose[(a, b)]))
    out.append("};")
    out.append("")
    return "\n".join(out)

sys.stdout.write(emit())
sys.stderr.write("canon=%d compat=%d ccc=%d compose=%d\n" % (len(canon), len(compat), len(ccc), len(compose)))
