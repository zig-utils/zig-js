---
title: Intl & Temporal
description: Internationalization constructors and the Temporal date/time namespace, backed by checked-in CLDR and IANA data.
---

# Intl & Temporal

Both namespaces are implemented in pure Zig against **checked-in data tables**.
There is no ICU dependency and no runtime data download: locale data, plural
rules, number systems, time-zone rules, and unit data are generated into Zig
source and compiled in.

The `test/intl402` subtree — including its `Temporal` areas — is part of the
configured test262 corpus, so both namespaces are scored on every run. See
[Conformance](/conformance).

## `Intl`

| Constructor | Purpose |
| --- | --- |
| `Intl.Collator` | Locale-aware string comparison. |
| `Intl.NumberFormat` | Numbers, currencies, units, notation, and `formatToParts`. |
| `Intl.DateTimeFormat` | Dates and times, including ranges and `formatToParts`. |
| `Intl.RelativeTimeFormat` | "3 days ago" style formatting. |
| `Intl.PluralRules` | Cardinal and ordinal plural category selection. |
| `Intl.ListFormat` | Conjunction / disjunction / unit list joining. |
| `Intl.DisplayNames` | Names for languages, regions, scripts, currencies, calendars. |
| `Intl.Segmenter` | Grapheme, word, and sentence segmentation with `containing`. |
| `Intl.DurationFormat` | Duration formatting. |
| `Intl.Locale` | Locale identifier parsing, `maximize`/`minimize`, and the `getCalendars` / `getCollations` / `getHourCycles` / `getNumberingSystems` / `getTextInfo` / `getTimeZones` / `getWeekInfo` accessors, plus `firstDayOfWeek`. |

Namespace functions: `Intl.getCanonicalLocales` and `Intl.supportedValuesOf`.

Every constructor implements the standard resolution pipeline — option
coercion, locale negotiation, and `resolvedOptions()` reporting what was
actually selected.

### Where the data comes from

| Table | Source module |
| --- | --- |
| Locale/likely-subtags data | `cldr_locale.zig` |
| Number formats and symbols | `cldr_numbers.zig`, `numbering_systems.zig` |
| Plural rules | `cldr_plurals.zig` |
| Date/time patterns | `cldr_timedata.zig` |
| Time-zone aliases | `cldr_tzalias.zig` |
| Zone rules and offsets | `iana_zones.zig`, `iana_offsets.zig` |
| Display names | `intl_displaynames_data.zig` |
| Locale info (text direction, week data) | `intl_localeinfo.zig`, `intl_weekdata.zig` |
| Units | `intl_units_data.zig` |
| Segmentation | `unicode_grapheme_data.zig` |

These are **generated** by the `tools/gen_*` scripts (`gen_cldr_*.ts`,
`gen_iana_offsets.ts`, `gen_dn.ts`, `gen_localeinfo.ts`, `gen_units.ts`,
`gen_weekdata.ts`, `gen_numbering.ts`, `gen_grapheme.ts`). TypeScript generators
run through `~/Code/Home/lang/zig-out/bin/home-tool`. Regenerate the tables from
an upstream bump — never hand-edit the `.zig` tables.

## `Temporal`

The `Temporal` namespace provides:

- `Temporal.Now`
- `Temporal.Instant`
- `Temporal.Duration`
- `Temporal.PlainDate`, `Temporal.PlainTime`, `Temporal.PlainDateTime`
- `Temporal.PlainYearMonth`, `Temporal.PlainMonthDay`
- `Temporal.ZonedDateTime`

Arithmetic, rounding, comparison, calendar and time-zone handling, and the
ISO-8601 string round-trips are implemented against the same IANA tables that
back `Date` and `Intl.DateTimeFormat`, so a zone answer is consistent across all
three.

## Keeping the data current

A time-zone or CLDR release changes real behaviour. When bumping:

1. Re-run the relevant `tools/gen_*` generator against the new upstream release.
2. Run the full corpus — `test/intl402` and `test/built-ins/Date` are the
   sensitive subtrees.
3. Record the flip count in the commit body, as with any conformance change.

See the [contributing guide](https://github.com/zig-utils/zig-js/blob/main/CONTRIBUTING.md)
for the generated-file policy.
