/** Public Intl.DisplayNames controls against system JavaScriptCore on macOS. */
import { checked, fileExists, removeTemporaryDirectory, sha256Text, temporaryDirectory, writeText } from "./lib/home";

const args = process.argv.slice(2);
if (args.length !== 1) throw new Error("usage: intl-displaynames-jsc-diff.ts <test262-runner>");
if (checked(["uname", "-s"], "detect platform").trim() !== "Darwin") {
  throw new Error("the Intl.DisplayNames JavaScriptCore differential requires macOS");
}
const jsc = "/System/Library/Frameworks/JavaScriptCore.framework/Versions/A/Helpers/jsc";
if (!fileExists(jsc)) throw new Error(`system JavaScriptCore shell not found: ${jsc}`);

const source = `
var controls = [
  ["en-language-dialect-long-zh-Hant", "en", "language", "long", "zh-Hant", "dialect"],
  ["en-language-standard-short-en-US", "en", "language", "short", "en-US", "standard"],
  ["fr-language-standard-long-en-Latn-US", "fr", "language", "long", "en-Latn-US", "standard"],
  ["fr-region-short-us", "fr", "region", "short", "us", "dialect"],
  ["fr-script-narrow-lAtN", "fr", "script", "narrow", "lAtN", "dialect"],
  ["fr-currency-narrow-USD", "fr", "currency", "narrow", "USD", "dialect"],
  ["fr-calendar-short-GREGORY", "fr", "calendar", "short", "GREGORY", "dialect"],
  ["fr-dateTimeField-short-timeZoneName", "fr", "dateTimeField", "short", "timeZoneName", "dialect"],
  ["de-AT-currency-long-USD", "de-AT", "currency", "long", "USD", "dialect"],
  ["zh-Hant-language-standard-long-en-Latn-US", "zh-Hant", "language", "long", "en-Latn-US", "standard"],
  ["en-language-dialect-long-en-US-posix", "en", "language", "long", "en-US-posix", "dialect"]
];
var result = controls.map(function (row) {
  var formatter = new Intl.DisplayNames(row[1], { type: row[2], style: row[3], languageDisplay: row[5] });
  return [row[0], formatter.of(row[4]), formatter.resolvedOptions()];
});
JSON.stringify(result);
`;

type Row = [string, string, Record<string, unknown>];
const directory = temporaryDirectory("zig-js-displaynames-jsc");
try {
  const sourcePath = `${directory}/controls.js`;
  writeText(sourcePath, source);
  const zigOutput = checked([args[0], "--eval", sourcePath], "run zig-js DisplayNames controls").trim();
  if (!zigOutput.startsWith("OK ")) throw new Error(`unexpected zig-js output: ${zigOutput}`);
  const actual: Row[] = JSON.parse(zigOutput.slice(3));
  const reference: Row[] = JSON.parse(checked([
    jsc, "-e", `load(${JSON.stringify(sourcePath)}); print(JSON.stringify(result));`,
  ], "run system JSC DisplayNames controls").trim());
  if (actual.length !== reference.length || actual.length !== 11) throw new Error("DisplayNames control count drift");

  // These are pinned CLDR/ICU-version deltas, not allowances for arbitrary
  // mismatches. Each side is frozen so a host update or generated-data change
  // forces an explicit review rather than a silent baseline rewrite.
  const classified: Record<string, [string, string]> = {
    "en-language-dialect-long-zh-Hant": ["Traditional Chinese", "Chinese, Traditional"],
    "fr-language-standard-long-en-Latn-US": ["anglais (latin, États-Unis)", "anglais (latin, É.-U.)"],
  };
  let exact = 0;
  for (let index = 0; index < actual.length; index += 1) {
    const got = actual[index], expected = reference[index];
    if (got[0] !== expected[0]) throw new Error(`DisplayNames control order drift at row ${index}`);
    if (JSON.stringify(got[2]) !== JSON.stringify(expected[2])) {
      throw new Error(`DisplayNames resolvedOptions mismatch for ${got[0]}: ${JSON.stringify(got[2])} != ${JSON.stringify(expected[2])}`);
    }
    const delta = classified[got[0]];
    if (delta) {
      if (got[1] !== delta[0] || expected[1] !== delta[1]) {
        throw new Error(`DisplayNames classified delta drift for ${got[0]}: ${JSON.stringify(got[1])} != ${JSON.stringify(expected[1])}`);
      }
    } else {
      if (got[1] !== expected[1]) throw new Error(`DisplayNames JSC mismatch for ${got[0]}: ${JSON.stringify(got[1])} != ${JSON.stringify(expected[1])}`);
      exact += 1;
    }
  }
  console.log(`Intl.DisplayNames JSC differential: ${exact} exact, ${Object.keys(classified).length} pinned CLDR/ICU deltas, 11 resolvedOptions exact (${sha256Text(JSON.stringify(actual)).slice(0, 16)})`);
} finally {
  removeTemporaryDirectory(directory);
}
