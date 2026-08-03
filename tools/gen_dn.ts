/** Generate src/intl_displaynames_data.zig from CLDR English JSON. */
import { readText } from "./lib/home";

function load(path: string, keys: string[]): any { let value = JSON.parse(readText(path)); for (const key of keys) value = value[key]; return value; }
const argument = (index: number, fallback: string) => process.argv[index] || fallback;
const aliasesRaw = load(argument(2, "/tmp/cldr_aliases.json"), ["supplemental", "metadata", "alias", "languageAlias"]);
const territories = load(argument(3, "/tmp/cldr_territories.json"), ["main", "en", "localeDisplayNames", "territories"]);
const languages = load(argument(4, "/tmp/cldr_languages.json"), ["main", "en", "localeDisplayNames", "languages"]);
const scripts = load(argument(5, "/tmp/cldr_scripts.json"), ["main", "en", "localeDisplayNames", "scripts"]);
const currencies = load(argument(6, "/tmp/cldr_currencies.json"), ["main", "en", "numbers", "currencies"]);
const base = (values: any) => { const out: any = {}; for (const key of Object.keys(values)) if (key.indexOf("-alt-") < 0) out[key] = values[key]; return out; };
const short = (values: any) => { const out: any = {}; for (const key of Object.keys(values)) if (key.indexOf("-alt-short") >= 0) out[key.split("-alt-")[0]] = values[key]; return out; };
const regionNames = base(territories), languageNames = base(languages), scriptNames = base(scripts);
const regionShort = short(territories), languageShort = short(languages), scriptShort = short(scripts);
const currencyNames: any = {}, currencyOne: any = {}, currencyOther: any = {}, languageAliases: any = {};
for (const key of Object.keys(currencies)) if (currencies[key].displayName != null) {
  currencyNames[key] = currencies[key].displayName;
  currencyOne[key] = currencies[key]["displayName-count-one"] || currencies[key].displayName;
  currencyOther[key] = currencies[key]["displayName-count-other"] || currencies[key].displayName;
}
for (const code of Object.keys(aliasesRaw)) {
  const replacement = aliasesRaw[code]._replacement;
  if (replacement && code.indexOf("-") < 0 && /^[A-Za-z]+$/.test(code)) languageAliases[code] = replacement;
}
languageNames.und = "root";
const escapeZig = (text: string) => text.replace(/\\/g, "\\\\").replace(/"/g, '\\"');
function emit(name: string, values: any): string {
  const lines = [`pub const ${name} = [_]Entry{`];
  for (const key of Object.keys(values).sort()) lines.push(`    .{ .code = "${escapeZig(key)}", .name = "${escapeZig(values[key])}" },`);
  lines.push("};");
  return lines.join("\n");
}
const parts = [
  "//! GENERATED from CLDR en JSON (cldr-localenames-full + cldr-numbers-full).",
  "//! Do not edit by hand; see tools/gen_dn.ts. English display names for",
  "//! Intl.DisplayNames (language/region/script/currency), sorted by code.", "",
  "pub const Entry = struct { code: []const u8, name: []const u8 };", "",
  emit("languages", languageNames), "", emit("regions", regionNames), "", emit("scripts", scriptNames), "",
  emit("currencies", currencyNames), "", emit("regions_short", regionShort), "", emit("languages_short", languageShort), "",
  emit("scripts_short", scriptShort), "", emit("language_aliases", languageAliases), "", emit("currency_names_one", currencyOne), "",
  emit("currency_names_other", currencyOther), "",
];
process.stdout.write(parts.join("\n"));
process.stderr.write(`langs=${Object.keys(languageNames).length} regions=${Object.keys(regionNames).length} scripts=${Object.keys(scriptNames).length} currencies=${Object.keys(currencyNames).length}\n`);
