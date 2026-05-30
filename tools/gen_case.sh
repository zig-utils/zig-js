#!/usr/bin/env bash
# Generate src/unicode_case_data.zig from the Unicode UCD data files.
# Usage: download UnicodeData.txt + SpecialCasing.txt, then:
#   UCD=/path/to/ucd bash tools/gen_case.sh
set -e
UCD="${UCD:-/tmp}"
OUT=src/unicode_case_data.zig
emit_full() { # $1 = field index of the mapping (2=lower, 4=upper)
  sed 's/#.*//' "$UCD/SpecialCasing.txt" | awk -F';' -v FLD="$1" '
    NF>=4 {
      cond=$5; gsub(/[ \t]/,"",cond); if (cond!="") next;   # conditional -> handled in code
      m=$FLD; gsub(/^[ \t]+|[ \t]+$/,"",m);
      n=split(m,parts," "); if (n<=1) next;                 # 1:1 covered by simple tables
      code=$1; gsub(/[ \t]/,"",code);
      printf "    .{ .cp = 0x%s, .len = %d", code, n;
      if(n>=1) printf ", .a = 0x%s", parts[1];
      if(n>=2) printf ", .b = 0x%s", parts[2];
      if(n>=3) printf ", .c = 0x%s", parts[3];
      printf " },\n";
    }' | LC_ALL=C sort
}
{
echo "//! GENERATED from Unicode UnicodeData.txt + SpecialCasing.txt. Do not edit."
echo "//! Regenerate via tools/gen_case.sh. Simple (1:1) and full (1:N,"
echo "//! unconditional) case mappings for String.prototype.to{Upper,Lower}Case."
echo "//! Every table is sorted ascending by .cp for binary search."
echo ""
echo "pub const Pair = struct { cp: u21, to: u21 };"
echo "pub const Full = struct { cp: u21, a: u21 = 0, b: u21 = 0, c: u21 = 0, len: u8 };"
echo ""
echo "pub const simple_upper = [_]Pair{"
awk -F';' '$13!="" {printf "    .{ .cp = 0x%s, .to = 0x%s },\n", $1, $13}' "$UCD/UnicodeData.txt"
echo "};"; echo ""
echo "pub const simple_lower = [_]Pair{"
awk -F';' '$14!="" {printf "    .{ .cp = 0x%s, .to = 0x%s },\n", $1, $14}' "$UCD/UnicodeData.txt"
echo "};"; echo ""
echo "pub const full_upper = [_]Full{"; emit_full 4; echo "};"; echo ""
echo "pub const full_lower = [_]Full{"; emit_full 2; echo "};"
} > "$OUT"
echo "wrote $OUT: $(grep -c '\.cp' $OUT) entries"
