#!/usr/bin/env python3
"""Generate src/intl_displaynames_data.zig from CLDR en JSON."""
import json, sys

def load(path, *keys):
    d = json.load(open(path))
    for k in keys:
        d = d[k]
    return d

aliases_raw = load('/tmp/cldr_aliases.json','supplemental','metadata','alias','languageAlias')
lang_aliases = {c: info['_replacement'] for c, info in aliases_raw.items()
                if info.get('_replacement') and '-' not in c and c.isalpha()}
terr = load('/tmp/cldr_territories.json','main','en','localeDisplayNames','territories')
langs = load('/tmp/cldr_languages.json','main','en','localeDisplayNames','languages')
scripts = load('/tmp/cldr_scripts.json','main','en','localeDisplayNames','scripts')
curr = load('/tmp/cldr_currencies.json','main','en','numbers','currencies')

def base(d):
    return {k: v for k, v in d.items() if '-alt-' not in k}

def short(d):
    return {k.split('-alt-')[0]: v for k, v in d.items() if '-alt-short' in k}

region_names = base(terr)
lang_names = base(langs)
script_names = base(scripts)
region_short = short(terr)
lang_short = short(langs)
script_short = short(scripts)
curr_names = {k: v['displayName'] for k, v in curr.items() if 'displayName' in v}
# Plural long names for currencyDisplay:"name" (fall back to the base displayName).
curr_one = {k: v.get('displayName-count-one', v.get('displayName')) for k, v in curr.items() if v.get('displayName')}
curr_other = {k: v.get('displayName-count-other', v.get('displayName')) for k, v in curr.items() if v.get('displayName')}
# ICU quirk: DisplayNames maps "und" to "root".
lang_names['und'] = 'root'

def zesc(s):
    return s.replace('\\', '\\\\').replace('"', '\\"')

def emit(name, d):
    out = [f"pub const {name} = [_]Entry{{"]
    for k in sorted(d):
        out.append('    .{ .code = "%s", .name = "%s" },' % (zesc(k), zesc(d[k])))
    out.append("};")
    return "\n".join(out)

parts = []
parts.append("//! GENERATED from CLDR en JSON (cldr-localenames-full + cldr-numbers-full).")
parts.append("//! Do not edit by hand; see tools/gen_dn.py. English display names for")
parts.append("//! Intl.DisplayNames (language/region/script/currency), sorted by code.")
parts.append("")
parts.append("pub const Entry = struct { code: []const u8, name: []const u8 };")
parts.append("")
parts.append(emit("languages", lang_names))
parts.append("")
parts.append(emit("regions", region_names))
parts.append("")
parts.append(emit("scripts", script_names))
parts.append("")
parts.append(emit("currencies", curr_names))
parts.append("")
parts.append(emit("regions_short", region_short))
parts.append("")
parts.append(emit("languages_short", lang_short))
parts.append("")
parts.append(emit("scripts_short", script_short))
parts.append("")
parts.append(emit("language_aliases", lang_aliases))
parts.append("")
parts.append(emit("currency_names_one", curr_one))
parts.append("")
parts.append(emit("currency_names_other", curr_other))
parts.append("")
sys.stdout.write("\n".join(parts))
sys.stderr.write("langs=%d regions=%d scripts=%d currencies=%d\n" % (
    len(lang_names), len(region_names), len(script_names), len(curr_names)))
