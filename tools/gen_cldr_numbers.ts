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

function currencyPattern(sourcePattern) {
  const pattern = unquotePattern(sourcePattern);
  const numberAt = pattern.indexOf("{0}");
  const currencyAt = pattern.indexOf("{1}");
  if (numberAt < 0 || currencyAt < 0 || pattern.indexOf("{0}", numberAt + 3) >= 0 || pattern.indexOf("{1}", currencyAt + 3) >= 0) {
    throw new Error(`currency unit pattern must contain exactly one {0} and {1}: ${sourcePattern}`);
  }
  const numberFirst = numberAt < currencyAt;
  const firstAt = numberFirst ? numberAt : currencyAt;
  const secondAt = numberFirst ? currencyAt : numberAt;
  const leading = pattern.slice(0, firstAt);
  const between = pattern.slice(firstAt + 3, secondAt);
  const trailing = pattern.slice(secondAt + 3);
  const beforeName = splitSuffix(numberFirst ? between : leading);
  const afterName = splitPrefix(numberFirst ? trailing : between);
  return {
    numberFirst,
    leading: numberFirst ? leading : beforeName.literal,
    between: numberFirst ? beforeName.literal : afterName.literal,
    trailing: numberFirst ? afterName.literal : trailing,
    namePrefix: beforeName.affix,
    nameSuffix: afterName.affix,
  };
}

function currencyRows(currencies, nums, sys) {
  const names = [];
  for (const code of Object.keys(currencies).sort()) {
    const entry = currencies[code];
    if (entry.displayName == null) continue;
    const fallback = entry["displayName-count-other"] || entry.displayName;
    names.push({ code, category: "other", name: fallback });
    for (const [key, name] of Object.entries(entry)) {
      const match = key.match(/^displayName-count-(.+)$/);
      if (match && match[1] !== "other" && name !== fallback) names.push({ code, category: match[1], name });
    }
  }
  names.sort((a, b) => a.code < b.code ? -1 : a.code > b.code ? 1 : a.category < b.category ? -1 : a.category > b.category ? 1 : 0);

  const formats = nums[`currencyFormats-numberSystem-${sys}`] || nums["currencyFormats-numberSystem-latn"] || {};
  const patterns = [];
  for (const [key, sourcePattern] of Object.entries(formats)) {
    const match = key.match(/^unitPattern-count-(.+)$/);
    if (match) patterns.push({ category: match[1], ...currencyPattern(sourcePattern) });
  }
  if (!patterns.some((row) => row.category === "other")) patterns.push({ category: "other", ...currencyPattern("{0} {1}") });
  const fallback = patterns.find((row) => row.category === "other");
  const fallbackPattern = JSON.stringify([fallback.numberFirst, fallback.leading, fallback.between, fallback.trailing, fallback.namePrefix, fallback.nameSuffix]);
  const distinctPatterns = patterns.filter((row) => row.category === "other" || JSON.stringify([row.numberFirst, row.leading, row.between, row.trailing, row.namePrefix, row.nameSuffix]) !== fallbackPattern);
  distinctPatterns.sort((a, b) => a.category.localeCompare(b.category));
  return { names, patterns: distinctPatterns };
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
  const currencies = JSON.parse(readText(`${BASE}/${loc}/currencies.json`)).main[loc].numbers.currencies;
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
  const currency = currencyRows(currencies, nums, sys);
  if (!currency.names.length) throw new Error(`${loc}: missing currency display names`);
  rows.push({
    loc,
    decimal: sym.decimal, group: sym.group, percent: sym.percentSign, minus: sym.minusSign,
    nan: sym.nan || "NaN", infinity: sym.infinity || "∞",
    symBefore, acctParens, compact, currency,
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
const currencyGroups = [];
const currencyGroupByData = new Map();
for (const row of rows) {
  const key = JSON.stringify(row.currency);
  let index = currencyGroupByData.get(key);
  if (index === undefined) {
    index = currencyGroups.length;
    currencyGroupByData.set(key, index);
    currencyGroups.push(row.currency);
  }
  row.currencyGroup = index;
}

const out = [`// GENERATED by tools/gen_cldr_numbers.ts from CLDR-JSON — do not edit.
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

pub const CurrencyDisplay = struct {
    name: []const u8,
    plural_sensitive: bool,
    name_prefix: []const u8,
    name_suffix: []const u8,
    number_first: bool,
    leading_literal: []const u8,
    between_literal: []const u8,
    trailing_literal: []const u8,
};

const CurrencyNameRow = struct { code: []const u8, category: []const u8, name: []const u8 };
const CurrencyNameMatch = struct { name: []const u8, plural_sensitive: bool };
const CurrencyPatternRow = struct {
    category: []const u8,
    number_first: bool,
    leading_literal: []const u8,
    between_literal: []const u8,
    trailing_literal: []const u8,
    name_prefix: []const u8,
    name_suffix: []const u8,
};

const Row = struct { loc: []const u8, sym: NumSym };
const table = [_]Row{
`];
for (const r of rows) {
  out.push(`    .{ .loc = ${zstr(r.loc)}, .sym = .{ .decimal = ${zstr(r.decimal)}, .group = ${zstr(r.group)}, .percent = ${zstr(r.percent)}, .minus = ${zstr(r.minus)}, .nan = ${zstr(r.nan)}, .infinity = ${zstr(r.infinity)}, .symbol_before = ${r.symBefore}, .accounting_parens = ${r.acctParens} } },\n`);
}
out.push(`};

`);
for (let index = 0; index < rows.length; index++) {
  const r = rows[index];
  out.push(`const compact_${index}_short = [_]CompactRow{\n`);
  for (const p of r.compact.filter((entry) => entry.display === "short")) {
    out.push(`    .{ .magnitude = ${p.magnitude}, .category = ${zstr(p.category)}, .pattern = .{ .exponent = ${p.exponent}, .prefix = ${zstr(p.prefix)}, .prefix_literal = ${zstr(p.prefixLiteral)}, .suffix_literal = ${zstr(p.suffixLiteral)}, .suffix = ${zstr(p.suffix)}, .show_number = ${p.showNumber}, .plural_sensitive = ${p.pluralSensitive} } },\n`);
  }
  out.push(`};\nconst compact_${index}_long = [_]CompactRow{\n`);
  for (const p of r.compact.filter((entry) => entry.display === "long")) {
    out.push(`    .{ .magnitude = ${p.magnitude}, .category = ${zstr(p.category)}, .pattern = .{ .exponent = ${p.exponent}, .prefix = ${zstr(p.prefix)}, .prefix_literal = ${zstr(p.prefixLiteral)}, .suffix_literal = ${zstr(p.suffixLiteral)}, .suffix = ${zstr(p.suffix)}, .show_number = ${p.showNumber}, .plural_sensitive = ${p.pluralSensitive} } },\n`);
  }
  out.push(`};\n`);
}
out.push(`
const CompactLocale = struct { loc: []const u8, short: []const CompactRow, long: []const CompactRow };
const compact_table = [_]CompactLocale{
`);
for (let index = 0; index < rows.length; index++) {
  out.push(`    .{ .loc = ${zstr(rows[index].loc)}, .short = &compact_${index}_short, .long = &compact_${index}_long },\n`);
}
out.push(`};

`);
for (let index = 0; index < currencyGroups.length; index++) {
  const group = currencyGroups[index];
  out.push(`const currency_names_${index} = [_]CurrencyNameRow{\n`);
  for (const row of group.names) out.push(`    .{ .code = ${zstr(row.code)}, .category = ${zstr(row.category)}, .name = ${zstr(row.name)} },\n`);
  out.push(`};\nconst currency_patterns_${index} = [_]CurrencyPatternRow{\n`);
  for (const row of group.patterns) {
    out.push(`    .{ .category = ${zstr(row.category)}, .number_first = ${row.numberFirst}, .leading_literal = ${zstr(row.leading)}, .between_literal = ${zstr(row.between)}, .trailing_literal = ${zstr(row.trailing)}, .name_prefix = ${zstr(row.namePrefix)}, .name_suffix = ${zstr(row.nameSuffix)} },\n`);
  }
  out.push(`};\n`);
}
out.push(`
const CurrencyLocale = struct { loc: []const u8, names: []const CurrencyNameRow, patterns: []const CurrencyPatternRow };
const currency_table = [_]CurrencyLocale{
`);
for (const row of rows) {
  out.push(`    .{ .loc = ${zstr(row.loc)}, .names = &currency_names_${row.currencyGroup}, .patterns = &currency_patterns_${row.currencyGroup} },\n`);
}
out.push(`};

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

fn currencyLocale(locale: []const u8) ?CurrencyLocale {
    var lo: usize = 0;
    var hi: usize = currency_table.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        switch (std.mem.order(u8, currency_table[mid].loc, locale)) {
            .lt => lo = mid + 1,
            .gt => hi = mid,
            .eq => return currency_table[mid],
        }
    }
    return null;
}

fn currencyNameIn(rows: []const CurrencyNameRow, code: []const u8, category: []const u8) ?CurrencyNameMatch {
    var lo: usize = 0;
    var hi: usize = rows.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (std.mem.order(u8, rows[mid].code, code) == .lt) lo = mid + 1 else hi = mid;
    }
    if (lo == rows.len or !std.mem.eql(u8, rows[lo].code, code)) return null;
    var end = lo + 1;
    while (end < rows.len and std.mem.eql(u8, rows[end].code, code)) : (end += 1) {}
    const plural_sensitive = end - lo > 1;
    var fallback: ?[]const u8 = null;
    for (rows[lo..end]) |row| {
        if (std.mem.eql(u8, row.category, category)) return .{ .name = row.name, .plural_sensitive = plural_sensitive };
        if (std.mem.eql(u8, row.category, "other")) fallback = row.name;
    }
    return if (fallback) |name| .{ .name = name, .plural_sensitive = plural_sensitive } else null;
}

fn currencyPatternIn(rows: []const CurrencyPatternRow, category: []const u8) CurrencyPatternRow {
    var fallback = CurrencyPatternRow{ .category = "other", .number_first = true, .leading_literal = "", .between_literal = " ", .trailing_literal = "", .name_prefix = "", .name_suffix = "" };
    for (rows) |row| {
        if (std.mem.eql(u8, row.category, category)) return row;
        if (std.mem.eql(u8, row.category, "other")) fallback = row;
    }
    return fallback;
}

/// Resolve a locale currency display name and its plural unit pattern. Missing
/// locale/code data falls back through locale parents, then to the ISO code
/// rather than borrowing a name from another language.
pub fn currency(locale: []const u8, code: []const u8, category: []const u8) CurrencyDisplay {
    var probe = locale;
    var selected_pattern: ?CurrencyPatternRow = null;
    while (true) {
        if (currencyLocale(probe)) |found| {
            if (selected_pattern == null) selected_pattern = currencyPatternIn(found.patterns, category);
            if (currencyNameIn(found.names, code, category)) |match| {
                const pattern = selected_pattern.?;
                return .{ .name = match.name, .plural_sensitive = match.plural_sensitive, .name_prefix = pattern.name_prefix, .name_suffix = pattern.name_suffix, .number_first = pattern.number_first, .leading_literal = pattern.leading_literal, .between_literal = pattern.between_literal, .trailing_literal = pattern.trailing_literal };
            }
        }
        if (std.mem.lastIndexOfScalar(u8, probe, '-')) |i| probe = probe[0..i] else break;
    }
    const pattern = selected_pattern orelse currencyPatternIn(&.{}, category);
    return .{ .name = code, .plural_sensitive = false, .name_prefix = pattern.name_prefix, .name_suffix = pattern.name_suffix, .number_first = pattern.number_first, .leading_literal = pattern.leading_literal, .between_literal = pattern.between_literal, .trailing_literal = pattern.trailing_literal };
}
`);
process.stdout.write(out.join(""));
