// Generate src/cldr_numbers.zig: per-locale decimal/grouping separators (and
// currency-symbol placement) from a revision-pinned CLDR-JSON checkout.
import { fileExists, readText, run, utf8Bytes } from "./lib/home";
const CLDR_REVISION = "a79b499916d486dca4b0f74fe423ea457705fdd9";
const CLDR_ROOT = process.argv[2];
if (!CLDR_ROOT) throw new Error("usage: gen_cldr_numbers.ts <cldr-json-checkout>");
const revision = run(["git", "-C", CLDR_ROOT, "rev-parse", "HEAD"]);
if (revision.exitCode !== 0 || revision.stdout.trim() !== CLDR_REVISION) {
  throw new Error(`CLDR checkout pin drift: expected ${CLDR_REVISION}, found ${revision.stdout.trim() || revision.stderr.trim()}`);
}
const BASE = CLDR_ROOT.replace(/\/$/, "") + "/cldr-json/cldr-numbers-full/main";

// Common languages used by the test corpus (region variants inherit symbols).
const LOCALES = [
  "en", "en-GB", "en-CA", "en-IN", "de", "de-CH", "fr", "fr-CA", "fr-CH", "es", "es-419",
  "it", "pt", "pt-BR", "nl", "ru", "ja", "ko", "zh", "zh-Hant", "ar",
  "hi", "th", "tr", "pl", "cs", "sv", "da", "fi", "nb", "hu",
  "ro", "el", "he", "id", "vi", "uk", "ca", "hr", "sk", "sl",
  "bg", "et", "lv", "lt", "fa", "sr", "is", "ga", "mt", "cy",
];

function zstr(s) {
  // Zig string literal with \xHH for non-ASCII bytes.
  const bytes = utf8Bytes(s);
  let out = '"';
  for (const b of bytes) {
    if (b === 0x22) out += '\\"';
    else if (b === 0x5c) out += "\\\\";
    else if (b >= 0x20 && b < 0x7f) out += String.fromCharCode(b);
    else out += "\\x" + b.toString(16).padStart(2, "0");
  }
  return out + '"';
}

function unquotePattern(pattern) {
  let result = "", quoted = false;
  for (let i = 0; i < pattern.length; i++) {
    if (pattern[i] !== "'") {
      result += pattern[i];
    } else if (pattern[i + 1] === "'") {
      result += "'";
      i++;
    } else {
      quoted = !quoted;
    }
  }
  if (quoted) throw new Error(`unterminated CLDR pattern quote: ${pattern}`);
  return result;
}

function boundaryCharacter(character) {
  return /\s/u.test(character) || character === "\u200e" || character === "\u200f" || character === "\u061c";
}

function splitPrefix(prefix) {
  let boundary = prefix.length;
  while (boundary > 0) {
    const previous = Array.from(prefix.slice(0, boundary)).pop();
    if (!boundaryCharacter(previous)) break;
    boundary -= previous.length;
  }
  return { affix: prefix.slice(0, boundary), literal: prefix.slice(boundary) };
}

function splitSuffix(suffix) {
  let boundary = 0;
  for (const character of suffix) {
    if (!boundaryCharacter(character)) break;
    boundary += character.length;
  }
  return { literal: suffix.slice(0, boundary), affix: suffix.slice(boundary) };
}

function compactRows(nums, sys) {
  const formats = nums[`decimalFormats-numberSystem-${sys}`] || nums["decimalFormats-numberSystem-latn"] || {};
  const result = [];
  for (const display of ["short", "long"]) {
    const patterns = formats[display]?.decimalFormat || {};
    for (const [key, sourcePattern] of Object.entries(patterns)) {
      const match = key.match(/^([0-9]+)-count-(.+)$/);
      if (!match || !/^10*$/.test(match[1])) throw new Error(`invalid compact pattern key ${key}`);
      const magnitude = match[1].length - 1;
      const pattern = unquotePattern(sourcePattern);
      const firstZero = pattern.indexOf("0");
      let zeros = 0, prefix = "", suffix = "", showNumber = firstZero >= 0;
      if (showNumber) {
        while (pattern[firstZero + zeros] === "0") zeros++;
        prefix = pattern.slice(0, firstZero);
        suffix = pattern.slice(firstZero + zeros);
      } else {
        suffix = pattern;
      }
      const prefixParts = splitPrefix(prefix);
      const suffixParts = splitSuffix(suffix);
      const hasAffix = prefixParts.affix.length > 0 || suffixParts.affix.length > 0;
      result.push({
        display,
        magnitude,
        category: match[2],
        exponent: showNumber && hasAffix ? magnitude - zeros + 1 : showNumber ? 0 : magnitude,
        prefix: prefixParts.affix,
        prefixLiteral: prefixParts.literal,
        suffixLiteral: suffixParts.literal,
        suffix: suffixParts.affix,
        showNumber,
      });
    }
  }
  result.sort((a, b) => a.display.localeCompare(b.display) || a.magnitude - b.magnitude || a.category.localeCompare(b.category));
  const groups = {};
  for (const row of result) (groups[`${row.display}:${row.magnitude}`] ||= []).push(row);
  for (const [key, group] of Object.entries(groups)) {
    const fallback = group.find((row) => row.category === "other");
    if (!fallback) throw new Error(`${key}: missing count-other compact fallback`);
    if (new Set(group.map((row) => row.exponent)).size !== 1) throw new Error(`${key}: plural categories disagree on compact exponent`);
    const fallbackPattern = JSON.stringify([
      fallback.exponent, fallback.prefix, fallback.prefixLiteral,
      fallback.suffixLiteral, fallback.suffix, fallback.showNumber,
    ]);
    for (const row of group) {
      const pattern = JSON.stringify([
        row.exponent, row.prefix, row.prefixLiteral,
        row.suffixLiteral, row.suffix, row.showNumber,
      ]);
      row.distinct = row.category === "other" || pattern !== fallbackPattern;
    }
    const pluralSensitive = group.some((row) => row.category !== "other" && row.distinct);
    for (const row of group) row.pluralSensitive = pluralSensitive;
  }
  return result.filter((row) => row.distinct);
}

const rows = [];
for (const loc of LOCALES) {
  const path = `${BASE}/${loc}/numbers.json`;
  if (!fileExists(path)) {
    process.stderr.write(`skip ${loc}: inherited locale has no dedicated numbers.json\n`);
    continue;
  }
  const j = JSON.parse(readText(path));
  const nums = j.main[loc].numbers;
  const sys = nums.defaultNumberingSystem || "latn";
  const sym = nums[`symbols-numberSystem-${sys}`] || nums["symbols-numberSystem-latn"];
  if (!sym) throw new Error(`${loc}: missing number symbols for ${sys} and latn`);
  const curFmts = nums[`currencyFormats-numberSystem-${sys}`] || nums["currencyFormats-numberSystem-latn"] || {};
  const curFmt = curFmts.standard || "¤#,##0.00";
  // Symbol placement: does ¤ come before the number?
  const symBefore = curFmt.indexOf("¤") < curFmt.indexOf("#");
  // Accounting negatives: some locales wrap in parentheses (en "(¤#,##0.00)"),
  // others just use the minus sign (de "-#,##0.00 ¤").
  const acctFmt = curFmts.accounting || "";
  const acctParens = acctFmt.includes("(");
  const compact = compactRows(nums, sys);
  if (!compact.length) throw new Error(`${loc}: missing compact number patterns`);
  rows.push({
    loc,
    decimal: sym.decimal, group: sym.group, percent: sym.percentSign, minus: sym.minusSign,
    nan: sym.nan || "NaN", infinity: sym.infinity || "∞",
    symBefore, acctParens, compact,
  });
  process.stderr.write(`ok ${loc}\n`);
}
// Region→script aliases the simple "xx-YY"→"xx" fallback can't derive
// (Traditional Chinese regions inherit from zh-Hant, not zh).
const ALIASES = { "zh-TW": "zh-Hant", "zh-HK": "zh-Hant", "zh-MO": "zh-Hant" };
for (const [alias, src] of Object.entries(ALIASES)) {
  const base = rows.find((r) => r.loc === src);
  if (base && !rows.find((r) => r.loc === alias)) rows.push({ ...base, loc: alias });
}
rows.sort((a, b) => (a.loc < b.loc ? -1 : 1));

let out = `// GENERATED by tools/gen_cldr_numbers.ts from CLDR-JSON — do not edit.
const std = @import("std");

pub const NumSym = struct {
    decimal: []const u8,
    group: []const u8,
    percent: []const u8,
    minus: []const u8,
    nan: []const u8,
    infinity: []const u8,
    symbol_before: bool,
    /// Whether the locale's accounting currency format wraps negatives in
    /// parentheses ("(¤#,##0.00)") rather than using a minus sign.
    accounting_parens: bool,
};

pub const CompactPattern = struct {
    exponent: u8 = 0,
    prefix: []const u8 = "",
    prefix_literal: []const u8 = "",
    suffix_literal: []const u8 = "",
    suffix: []const u8 = "",
    show_number: bool = true,
    plural_sensitive: bool = false,
};

const CompactRow = struct {
    magnitude: u8,
    category: []const u8,
    pattern: CompactPattern,
};

const Row = struct { loc: []const u8, sym: NumSym };
const table = [_]Row{
`;
for (const r of rows) {
  out += `    .{ .loc = ${zstr(r.loc)}, .sym = .{ .decimal = ${zstr(r.decimal)}, .group = ${zstr(r.group)}, .percent = ${zstr(r.percent)}, .minus = ${zstr(r.minus)}, .nan = ${zstr(r.nan)}, .infinity = ${zstr(r.infinity)}, .symbol_before = ${r.symBefore}, .accounting_parens = ${r.acctParens} } },\n`;
}
out += `};

`;
for (let index = 0; index < rows.length; index++) {
  const r = rows[index];
  out += `const compact_${index}_short = [_]CompactRow{\n`;
  for (const p of r.compact.filter((entry) => entry.display === "short")) {
    out += `    .{ .magnitude = ${p.magnitude}, .category = ${zstr(p.category)}, .pattern = .{ .exponent = ${p.exponent}, .prefix = ${zstr(p.prefix)}, .prefix_literal = ${zstr(p.prefixLiteral)}, .suffix_literal = ${zstr(p.suffixLiteral)}, .suffix = ${zstr(p.suffix)}, .show_number = ${p.showNumber}, .plural_sensitive = ${p.pluralSensitive} } },\n`;
  }
  out += `};\nconst compact_${index}_long = [_]CompactRow{\n`;
  for (const p of r.compact.filter((entry) => entry.display === "long")) {
    out += `    .{ .magnitude = ${p.magnitude}, .category = ${zstr(p.category)}, .pattern = .{ .exponent = ${p.exponent}, .prefix = ${zstr(p.prefix)}, .prefix_literal = ${zstr(p.prefixLiteral)}, .suffix_literal = ${zstr(p.suffixLiteral)}, .suffix = ${zstr(p.suffix)}, .show_number = ${p.showNumber}, .plural_sensitive = ${p.pluralSensitive} } },\n`;
  }
  out += `};\n`;
}
out += `
const CompactLocale = struct { loc: []const u8, short: []const CompactRow, long: []const CompactRow };
const compact_table = [_]CompactLocale{
`;
for (let index = 0; index < rows.length; index++) {
  out += `    .{ .loc = ${zstr(rows[index].loc)}, .short = &compact_${index}_short, .long = &compact_${index}_long },\n`;
}
out += `};

const default_sym = NumSym{ .decimal = ".", .group = ",", .percent = "%", .minus = "-", .nan = "NaN", .infinity = "\xe2\x88\x9e", .symbol_before = true, .accounting_parens = true };

/// Look up a locale's number symbols, falling back from "xx-YY" to "xx", then
/// to the en-style default.
pub fn lookup(locale: []const u8) NumSym {
    var probe = locale;
    while (true) {
        for (table) |row| if (std.mem.eql(u8, row.loc, probe)) return row.sym;
        if (std.mem.lastIndexOfScalar(u8, probe, '-')) |i| {
            probe = probe[0..i];
        } else break;
    }
    return default_sym;
}

fn compactLocale(locale: []const u8) ?CompactLocale {
    var lo: usize = 0;
    var hi: usize = compact_table.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        switch (std.mem.order(u8, compact_table[mid].loc, locale)) {
            .lt => lo = mid + 1,
            .gt => hi = mid,
            .eq => return compact_table[mid],
        }
    }
    return null;
}

fn compactIn(rows: []const CompactRow, magnitude: usize, category: []const u8, exact_one: bool) CompactPattern {
    if (rows.len == 0 or magnitude < @as(usize, rows[0].magnitude)) return .{};
    var selected_magnitude = rows[0].magnitude;
    for (rows) |row| {
        if (@as(usize, row.magnitude) > magnitude) break;
        selected_magnitude = row.magnitude;
    }
    var fallback: ?CompactPattern = null;
    for (rows) |row| {
        if (row.magnitude != selected_magnitude) continue;
        if (exact_one and std.mem.eql(u8, row.category, "1")) return row.pattern;
        if (std.mem.eql(u8, row.category, category)) return row.pattern;
        if (std.mem.eql(u8, row.category, "other")) fallback = row.pattern;
    }
    return fallback orelse .{};
}

/// Look up the greatest compact magnitude no larger than the requested one, with
/// locale fallback and a category→other fallback at that exact magnitude.
pub fn compact(locale: []const u8, long: bool, magnitude: usize, category: []const u8, exact_one: bool) CompactPattern {
    var probe = locale;
    while (true) {
        if (compactLocale(probe)) |found| return compactIn(if (long) found.long else found.short, magnitude, category, exact_one);
        if (std.mem.lastIndexOfScalar(u8, probe, '-')) |i| probe = probe[0..i] else break;
    }
    const english = compactLocale("en") orelse return .{};
    return compactIn(if (long) english.long else english.short, magnitude, category, exact_one);
}
`;
process.stdout.write(out);
