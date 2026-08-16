// Generate locale-indexed Intl.DisplayNames data from a revision-pinned
// CLDR-JSON checkout. The runtime remains independent of CLDR and ICU.
import { fileExists, readText, run } from "./lib/home";

const CLDR_REVISION = "a79b499916d486dca4b0f74fe423ea457705fdd9";
const CLDR_ROOT = process.argv[2];
if (!CLDR_ROOT) throw new Error("usage: gen_dn.ts <cldr-json-checkout>");
const revision = run(["git", "-C", CLDR_ROOT, "rev-parse", "HEAD"]);
if (revision.exitCode !== 0 || revision.stdout.trim() !== CLDR_REVISION) {
  throw new Error(`CLDR checkout pin drift: expected ${CLDR_REVISION}, found ${revision.stdout.trim() || revision.stderr.trim()}`);
}

const root = CLDR_ROOT.replace(/\/$/, "") + "/cldr-json";
const localeNamesRoot = root + "/cldr-localenames-full/main";
const numbersRoot = root + "/cldr-numbers-full/main";
const datesRoot = root + "/cldr-dates-full/main";
const aliasesPath = root + "/cldr-core/supplemental/aliases.json";
const locales = [
  "ar", "bg", "ca", "cs", "cy", "da", "de", "de-CH", "el", "en", "en-CA", "en-GB", "en-IN",
  "es", "es-419", "et", "fa", "fi", "fr", "fr-CA", "fr-CH", "ga", "he", "hi", "hr", "hu",
  "id", "is", "it", "ja", "ko", "lt", "lv", "mt", "nb", "nl", "pl", "pt", "pt-BR", "ro",
  "ru", "sk", "sl", "sr", "sv", "th", "tr", "uk", "vi", "zh", "zh-Hant",
].sort();

function load(path: string, keys: string[]): any {
  if (!fileExists(path)) throw new Error(`missing pinned CLDR input: ${path}`);
  let value = JSON.parse(readText(path));
  for (const key of keys) value = value[key];
  if (value == null || typeof value !== "object") throw new Error(`missing CLDR path ${keys.join(".")} in ${path}`);
  return value;
}

function loadOptional(path: string, keys: string[]): any {
  return fileExists(path) ? load(path, keys) : {};
}

const aliasesRaw = load(aliasesPath, ["supplemental", "metadata", "alias", "languageAlias"]);
const languageAliases: Record<string, string> = {};
for (const code of Object.keys(aliasesRaw)) {
  const replacement = aliasesRaw[code]._replacement;
  if (replacement && !code.includes("-") && /^[A-Za-z]+$/.test(code)) languageAliases[code] = replacement.replace(/_/g, "-");
}

function base(values: Record<string, string>): Record<string, string> {
  const out: Record<string, string> = {};
  for (const key of Object.keys(values)) if (!key.includes("-alt-")) out[key] = values[key];
  return out;
}

function alternate(values: Record<string, string>, style: "short" | "narrow"): Record<string, string> {
  const out: Record<string, string> = {};
  const suffix = `-alt-${style}`;
  for (const key of Object.keys(values)) if (key.endsWith(suffix)) out[key.slice(0, -suffix.length)] = values[key];
  return out;
}

function lowerKeys(values: Record<string, string>): Record<string, string> {
  const out: Record<string, string> = {};
  for (const key of Object.keys(values)) out[key.toLowerCase()] = values[key];
  return out;
}

function escapeZig(text: string): string {
  return text.replace(/\\/g, "\\\\").replace(/"/g, '\\"').replace(/\n/g, "\\n").replace(/\r/g, "\\r").replace(/\t/g, "\\t");
}

function emit(name: string, values: Record<string, string>): string {
  const lines = [`pub const ${name} = [_]Entry{`];
  for (const key of Object.keys(values).sort()) lines.push(`    .{ .code = "${escapeZig(key)}", .name = "${escapeZig(values[key])}" },`);
  lines.push("};");
  return lines.join("\n");
}

const dateFieldCodes: Record<string, string> = {
  era: "era", year: "year", quarter: "quarter", month: "month", weekOfYear: "week", weekday: "weekday",
  day: "day", dayPeriod: "dayperiod", hour: "hour", minute: "minute", second: "second", timeZoneName: "zone",
};

const blocks: string[] = [];
const records: string[] = [];
for (const locale of locales) {
  const prefix = locale.replace(/-/g, "_").replace(/[^A-Za-z0-9_]/g, "_");
  // CLDR's base Portuguese bundle is Brazilian Portuguese; the resolved
  // ECMA-402 locale may still carry the explicit pt-BR region.
  const sourceLocale = locale === "pt-BR" ? "pt" : locale;
  const languageData = load(`${localeNamesRoot}/${sourceLocale}/languages.json`, ["main", sourceLocale, "localeDisplayNames", "languages"]);
  const regionData = load(`${localeNamesRoot}/${sourceLocale}/territories.json`, ["main", sourceLocale, "localeDisplayNames", "territories"]);
  const scriptData = load(`${localeNamesRoot}/${sourceLocale}/scripts.json`, ["main", sourceLocale, "localeDisplayNames", "scripts"]);
  const variantData = loadOptional(`${localeNamesRoot}/${sourceLocale}/variants.json`, ["main", sourceLocale, "localeDisplayNames", "variants"]);
  const displayData = load(`${localeNamesRoot}/${sourceLocale}/localeDisplayNames.json`, ["main", sourceLocale, "localeDisplayNames"]);
  const currencyData = load(`${numbersRoot}/${sourceLocale}/currencies.json`, ["main", sourceLocale, "numbers", "currencies"]);
  const dateFields = load(`${datesRoot}/${sourceLocale}/dateFields.json`, ["main", sourceLocale, "dates", "fields"]);

  const languagesLong = base(languageData);
  languagesLong.und = languagesLong.und || "root";
  const currenciesLong: Record<string, string> = {};
  const currenciesShort: Record<string, string> = {};
  const currenciesNarrow: Record<string, string> = {};
  for (const code of Object.keys(currencyData)) {
    const currency = currencyData[code];
    if (currency.displayName != null) currenciesLong[code] = currency.displayName;
    if (currency.symbol != null) currenciesShort[code] = currency.symbol;
    if (currency["symbol-alt-narrow"] != null) currenciesNarrow[code] = currency["symbol-alt-narrow"];
  }

  const fieldsLong: Record<string, string> = {};
  const fieldsShort: Record<string, string> = {};
  const fieldsNarrow: Record<string, string> = {};
  for (const code of Object.keys(dateFieldCodes)) {
    const cldr = dateFieldCodes[code];
    if (dateFields[cldr]?.displayName != null) fieldsLong[code] = dateFields[cldr].displayName;
    if (dateFields[`${cldr}-short`]?.displayName != null) fieldsShort[code] = dateFields[`${cldr}-short`].displayName;
    if (dateFields[`${cldr}-narrow`]?.displayName != null) fieldsNarrow[code] = dateFields[`${cldr}-narrow`].displayName;
  }

  const tables: Array<[string, Record<string, string>]> = [
    ["languages_long", languagesLong], ["languages_short", alternate(languageData, "short")], ["languages_narrow", alternate(languageData, "narrow")],
    ["regions_long", base(regionData)], ["regions_short", alternate(regionData, "short")], ["regions_narrow", alternate(regionData, "narrow")],
    ["scripts_long", base(scriptData)], ["scripts_short", alternate(scriptData, "short")], ["scripts_narrow", alternate(scriptData, "narrow")],
    ["variants_long", lowerKeys(base(variantData))], ["variants_short", lowerKeys(alternate(variantData, "short"))], ["variants_narrow", lowerKeys(alternate(variantData, "narrow"))],
    ["currencies_long", currenciesLong], ["currencies_short", currenciesShort], ["currencies_narrow", currenciesNarrow],
    ["calendars_long", base(displayData.types?.calendar || {})],
    ["date_fields_long", fieldsLong], ["date_fields_short", fieldsShort], ["date_fields_narrow", fieldsNarrow],
  ];
  for (const [name, values] of tables) blocks.push(emit(`${prefix}_${name}`, values));

  const patterns = displayData.localeDisplayPattern;
  for (const key of ["localePattern", "localeSeparator"]) {
    const pattern = patterns[key];
    if (typeof pattern !== "string" || !pattern.includes("{0}") || !pattern.includes("{1}")) {
      throw new Error(`invalid ${key} for ${locale}`);
    }
  }
  records.push([
    `    .{ .locale = "${escapeZig(locale)}",`,
    `        .locale_pattern = "${escapeZig(patterns.localePattern)}", .locale_separator = "${escapeZig(patterns.localeSeparator)}",`,
    ...tables.map(([name]) => `        .${name} = &${prefix}_${name},`),
    "    },",
  ].join("\n"));
}

const parts = [
  `//! GENERATED from CLDR-JSON revision ${CLDR_REVISION}.`,
  "//! Do not edit by hand; see tools/gen_dn.ts. Locale-indexed immutable",
  "//! Intl.DisplayNames data and composition patterns.", "",
  "pub const Entry = struct { code: []const u8, name: []const u8 };", "",
  "pub const LocaleData = struct {",
  "    locale: []const u8,",
  "    locale_pattern: []const u8,",
  "    locale_separator: []const u8,",
  "    languages_long: []const Entry, languages_short: []const Entry, languages_narrow: []const Entry,",
  "    regions_long: []const Entry, regions_short: []const Entry, regions_narrow: []const Entry,",
  "    scripts_long: []const Entry, scripts_short: []const Entry, scripts_narrow: []const Entry,",
  "    variants_long: []const Entry, variants_short: []const Entry, variants_narrow: []const Entry,",
  "    currencies_long: []const Entry, currencies_short: []const Entry, currencies_narrow: []const Entry,",
  "    calendars_long: []const Entry,",
  "    date_fields_long: []const Entry, date_fields_short: []const Entry, date_fields_narrow: []const Entry,",
  "};", "",
  ...blocks.flatMap((block) => [block, ""]),
  emit("language_aliases", languageAliases), "",
  "pub const locales = [_]LocaleData{", ...records, "};", "",
];
process.stdout.write(parts.join("\n"));
process.stderr.write(`revision=${CLDR_REVISION} locales=${locales.length} tables=${blocks.length}\n`);
