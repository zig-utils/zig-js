// Generate src/cldr_collation.zig from a revision-pinned CLDR checkout.
//
// The engine's compact collator uses these primary weights for Latin locale
// tailorings. This is deliberately narrower than a full UCA implementation:
// selected profiles must fit the reset/relation grammar below, and generation
// fails when pinned CLDR data no longer does.
//
//   home-tool run tools/gen_cldr_collation.ts /path/to/cldr > src/cldr_collation.zig
import { readText, run } from "./lib/home";

const CLDR_REVISION = "11299982335beb974c1c63c45265184e759c0f41"; // release-48-2
const CLDR_ROOT = process.argv[2];
if (!CLDR_ROOT) throw new Error("usage: gen_cldr_collation.ts <cldr-checkout>");
const revision = run(["git", "-C", CLDR_ROOT, "rev-parse", "HEAD"]);
if (revision.exitCode !== 0 || revision.stdout.trim() !== CLDR_REVISION) {
  throw new Error(`CLDR checkout pin drift: expected ${CLDR_REVISION}, found ${revision.stdout.trim() || revision.stderr.trim()}`);
}

// Profiles whose confirmed standard rules are expressible as a primary-order
// sequence over Latin letters, accents, and contractions. Keep this explicit:
// adding a locale is a reviewed semantic expansion, not an accidental parser
// side effect from a CLDR release.
const LOCALES = [
  "cs", "cy", "da", "eo", "es", "et", "fi", "fo", "hr", "hu", "is",
  "lt", "lv", "no", "pl", "ro", "sk", "sl", "sq", "sv", "vi",
];

type Node = { aliases: Set<string> };
type Profile = { locale: string; ascii: number[]; tokens: { token: string; weight: number }[] };

function decodeEscapes(value: string): string {
  return value.replace(/\\u([0-9a-fA-F]{4})/g, (_, hex) => String.fromCharCode(parseInt(hex, 16)));
}

function folded(value: string): string {
  return decodeEscapes(value.trim().replace(/^'(.*)'$/, "$1")).normalize("NFD").toLowerCase();
}

function stripComment(line: string): string {
  const index = line.indexOf("#");
  return (index < 0 ? line : line.slice(0, index)).trim();
}

function standardRules(locale: string): string[] {
  const xml = readText(`${CLDR_ROOT.replace(/\/$/, "")}/common/collation/${locale}.xml`);
  const collations = [...xml.matchAll(/<collation\b([^>]*)>([\s\S]*?)<\/collation\s*>/g)];
  const standard = collations.find((match) => /\btype="standard"/.test(match[1]) && !/\b(?:draft|alt)=/.test(match[1]));
  if (!standard) throw new Error(`${locale}: no confirmed standard collation`);
  const cdata = standard[2].match(/<cr><!\[CDATA\[([\s\S]*?)\]\]><\/cr>/);
  if (!cdata) throw new Error(`${locale}: standard collation has no inline rules`);
  const rules: string[] = [];
  for (const raw of cdata[1].split(/\r?\n/)) {
    const line = stripComment(raw);
    if (!line || /^\[[^\]]+\]$/.test(line)) continue;
    if (!line.startsWith("&")) throw new Error(`${locale}: unsupported continued rule: ${line}`);
    rules.push(line);
  }
  if (!rules.length) throw new Error(`${locale}: empty standard rule set`);
  return rules;
}

function findNode(nodes: Node[], token: string): number {
  return nodes.findIndex((node) => node.aliases.has(token));
}

function buildProfile(locale: string): Profile {
  const nodes: Node[] = Array.from({ length: 26 }, (_, index) => ({ aliases: new Set([String.fromCharCode(97 + index)]) }));
  for (const rule of standardRules(locale)) {
    const resetEnd = rule.search(/(?:<<<|<<|<|=)/);
    if (resetEnd < 0) throw new Error(`${locale}: rule has no relation: ${rule}`);
    let reset = rule.slice(1, resetEnd).trim();
    const before = reset.startsWith("[before 1]");
    if (before) reset = reset.slice("[before 1]".length).trim();
    const resetToken = folded(reset);
    let current = findNode(nodes, resetToken);
    // CLDR uses a root character beyond Latin as the reset for letters which
    // sort at the end of the Latin alphabet. In this Latin-only projection,
    // an unknown reset is therefore the virtual boundary after z. Rules which
    // only add secondary/tertiary aliases to an unknown root element are inert.
    if (current < 0) current = nodes.length;
    let insertion = before ? current : current + 1;
    if (current === nodes.length) insertion = nodes.length;

    const tail = rule.slice(resetEnd);
    const relations = [...tail.matchAll(/(<<<|<<|<|=)([^<=>]+)/g)];
    if (!relations.length || relations.map((m) => m[0]).join("") !== tail) {
      throw new Error(`${locale}: unsupported relation grammar: ${rule}`);
    }
    for (const relation of relations) {
      const rawToken = relation[2].trim();
      // CLDR expansion/context syntax needs a sequence of root weights. The
      // ordinary character path already handles those spellings component by
      // component, so it must not be collapsed into a contraction here.
      if (rawToken.includes("/") || rawToken.includes("|")) continue;
      const token = folded(rawToken);
      if (!token) throw new Error(`${locale}: empty relation token: ${rule}`);
      if (relation[1] === "<") {
        const existing = findNode(nodes, token);
        let node: Node;
        if (existing >= 0) {
          node = nodes.splice(existing, 1)[0];
          if (existing < insertion) insertion -= 1;
        } else {
          node = { aliases: new Set([token]) };
        }
        nodes.splice(insertion, 0, node);
        current = insertion;
        insertion = current + 1;
      } else if (current < nodes.length) {
        // Secondary, tertiary, and identical relations share the primary node.
        const existing = findNode(nodes, token);
        if (existing >= 0 && existing !== current) nodes[existing].aliases.delete(token);
        nodes[current].aliases.add(token);
      }
    }
  }

  const ascii = new Array(26).fill(0);
  const tokens: { token: string; weight: number }[] = [];
  nodes.forEach((node, index) => {
    const weight = index + 1;
    for (const token of node.aliases) {
      if (/^[a-z]$/.test(token)) ascii[token.charCodeAt(0) - 97] = weight;
      else tokens.push({ token, weight });
    }
  });
  if (ascii.some((weight) => weight === 0)) throw new Error(`${locale}: incomplete ASCII primary table`);
  tokens.sort((a, b) => b.token.length - a.token.length || (a.token < b.token ? -1 : a.token > b.token ? 1 : 0));
  return { locale, ascii, tokens };
}

const profiles = LOCALES.map(buildProfile);
const byLocale = new Map(profiles.map((profile) => [profile.locale, profile]));
function rank(locale: string, token: string): number {
  const profile = byLocale.get(locale)!;
  const key = folded(token);
  if (/^[a-z]$/.test(key)) return profile.ascii[key.charCodeAt(0) - 97];
  const row = profile.tokens.find((candidate) => candidate.token === key);
  if (!row) throw new Error(`${locale}: generated profile has no token ${token}`);
  return row.weight;
}
for (const [locale, left, right] of [["sv", "ä", "z"], ["sv", "ö", "z"], ["da", "å", "z"], ["cs", "ch", "h"]]) {
  if (!(rank(locale, left) > rank(locale, right))) throw new Error(`${locale}: expected ${left} after ${right}`);
}
for (const [locale, left, right] of [["da", "aa", "å"], ["lt", "y", "i"]]) {
  if (rank(locale, left) !== rank(locale, right)) throw new Error(`${locale}: expected ${left} primary-equal to ${right}`);
}

function zstr(value: string): string {
  return `"${value.replace(/\\/g, "\\\\").replace(/"/g, '\\"')}"`;
}

let out = `// GENERATED by tools/gen_cldr_collation.ts from CLDR 48.2 — do not edit.
// Compact primary tailorings for selected Latin-script standard collations.
const std = @import("std");

pub const Token = struct { bytes: []const u8, weight: u16 };
pub const Profile = struct { ascii: *const [26]u16, tokens: []const Token };

`;
for (const profile of profiles) {
  out += `const ascii_${profile.locale} = [26]u16{ ${profile.ascii.join(", ")} };\n`;
  out += `const tokens_${profile.locale} = [_]Token{\n`;
  for (const token of profile.tokens) out += `    .{ .bytes = ${zstr(token.token)}, .weight = ${token.weight} },\n`;
  out += `};\n\n`;
}
out += `const Row = struct { locale: []const u8, profile: Profile };
const rows = [_]Row{
`;
for (const profile of profiles) {
  out += `    .{ .locale = "${profile.locale}", .profile = .{ .ascii = &ascii_${profile.locale}, .tokens = &tokens_${profile.locale} } },\n`;
}
out += `};

fn asciiLower(byte: u8) u8 {
    return if (byte >= 'A' and byte <= 'Z') byte + ('a' - 'A') else byte;
}

fn language(locale: []const u8) []const u8 {
    const end = std.mem.indexOfScalar(u8, locale, '-') orelse locale.len;
    return locale[0..end];
}

fn orderFolded(a: []const u8, b: []const u8) std.math.Order {
    const n = @min(a.len, b.len);
    for (a[0..n], b[0..n]) |ac, bc| {
        const al = asciiLower(ac);
        const bl = asciiLower(bc);
        if (al < bl) return .lt;
        if (al > bl) return .gt;
    }
    return std.math.order(a.len, b.len);
}

/// Return the standard primary tailoring for a locale's language subtag.
pub fn forLocale(locale: []const u8) ?Profile {
    const lang = language(locale);
    var lo: usize = 0;
    var hi: usize = rows.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        switch (orderFolded(rows[mid].locale, lang)) {
            .lt => lo = mid + 1,
            .gt => hi = mid,
            .eq => return rows[mid].profile,
        }
    }
    return null;
}
`;
process.stdout.write(out);
