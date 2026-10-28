#!/bin/zsh
# Collects the translatable texts out of the sources and merges them into
# Localization/Localizable.xcstrings.
#
#   Scripts/localize.sh            collect and merge (new texts appear as "new")
#   Scripts/localize.sh --check    change nothing; fail if the catalogue is out of date (CI)
#
# SwiftPM writes a .stringsdata next to every object file by itself — no extra compiler flags
# needed. Only the compiler knows the types, so only it can tell `Text("Abrufen")` (a
# LocalizedStringKey, translatable) from an ordinary string.
#
# The keys are the German texts. One catalogue for all targets: `String(localized:)` without a
# bundle looks in the main bundle, and build-app.sh compiles the catalogue into exactly that —
# so the GUI's texts and the error messages out of Kit, IMAP and AI share one file.
set -euo pipefail
cd "${0:A:h}/.."

CHECK=0
[[ "${1:-}" == "--check" ]] && CHECK=1
CATALOG="Localization/Localizable.xcstrings"
BUILD=".build/out/Intermediates.noindex/MailKeeper.build/Debug"

print -P "%F{blue}==>%f Texte einsammeln"
swift build >/dev/null

# Products and library targets, never the test bundles: a test's texts are not shipped.
FILES=("${(@f)$(find "$BUILD" -name '*.stringsdata' -not -path '*Tests*' | sort)}")
[[ -n "${FILES[1]:-}" ]] || { echo "keine .stringsdata unter $BUILD — hat SwiftPM das Layout geändert?" >&2; exit 1 }
print "    ${#FILES} Quelldateien"

merge_into() { xcrun xcstringstool sync "$1" --stringsdata "${FILES[@]}" }

if [[ $CHECK == 1 ]]; then
  WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT INT TERM
  cp "$CATALOG" "$WORK/Localizable.xcstrings"
  merge_into "$WORK/Localizable.xcstrings"
  if ! diff -q "$CATALOG" "$WORK/Localizable.xcstrings" >/dev/null; then
    echo "Der Katalog ist nicht aktuell. Scripts/localize.sh laufen lassen und mitcommitten." >&2
    diff <(xcrun xcstringstool print "$CATALOG" 2>/dev/null || true) \
         <(xcrun xcstringstool print "$WORK/Localizable.xcstrings") | head -40 >&2 || true
    exit 1
  fi
  print -P "%F{green}✓%f Katalog ist aktuell"
else
  merge_into "$CATALOG"
  print -P "%F{blue}==>%f $CATALOG aktualisiert"
fi

# What is still missing, so it is not discovered by seeing German in the English app.
python3 - "$CATALOG" <<'PY'
import collections, json, sys
cat = json.load(open(sys.argv[1], encoding="utf-8"))
strings = cat.get("strings", {})
languages = {lang for e in strings.values() for lang in e.get("localizations", {})} | {"en"}
languages.discard(cat.get("sourceLanguage", "de"))
missing, stale = collections.Counter(), 0
translatable = 0
for key, entry in strings.items():
    if entry.get("shouldTranslate") is False:
        continue
    translatable += 1
    if entry.get("extractionState") == "stale":
        stale += 1
    for lang in languages:
        unit = entry.get("localizations", {}).get(lang, {}).get("stringUnit", {})
        if unit.get("state") != "translated":
            missing[lang] += 1
print(f"    {translatable} Texte, Quellsprache {cat.get('sourceLanguage', '?')}")
for lang in sorted(languages):
    n = missing[lang]
    print(f"    {lang}: {n} fehlen" if n else f"    {lang}: vollständig")
if stale:
    print(f"    {stale} nicht mehr im Code (stale) — können raus")
PY
