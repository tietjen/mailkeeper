#!/bin/zsh
# Collects the translatable texts out of the sources and merges them into
# Localization/Localizable.xcstrings.
#
#   Scripts/localize.sh            collect and merge (new texts appear as "new")
#   Scripts/localize.sh --check    change nothing; fail if the catalogue is out of date (CI)
#
# Why the compiler and not `xcstringstool extract`: only the compiler knows the types, so only
# it can tell `Text("Abrufen")` (a LocalizedStringKey, translatable) from an ordinary string.
#
# The keys are the German texts. One catalogue for all targets: `String(localized:)` without a
# bundle looks in the main bundle, and build-app.sh compiles the catalogue into exactly that.
set -euo pipefail
cd "${0:A:h}/.."

CHECK=0
[[ "${1:-}" == "--check" ]] && CHECK=1

CATALOG="Localization/Localizable.xcstrings"
STRINGSDATA=$(mktemp -d)
trap 'rm -rf "$STRINGSDATA"' EXIT INT TERM

print -P "%F{blue}==>%f Texte einsammeln"
# -emit-localized-strings writes one .stringsdata per module next to the other build output.
swift build \
  -Xswiftc -emit-localized-strings \
  -Xswiftc -emit-localized-strings-path -Xswiftc "$STRINGSDATA" \
  >/dev/null

FILES=("${(@f)$(find "$STRINGSDATA" -name '*.stringsdata' | sort)}")
[[ -n "${FILES[1]:-}" ]] || { echo "keine .stringsdata erzeugt — hat sich die Compiler-Option geändert?" >&2; exit 1 }
print "    ${#FILES} Module"

if [[ $CHECK == 1 ]]; then
  BEFORE=$(shasum -a 256 "$CATALOG" | cut -d' ' -f1)
  WORK=$(mktemp -d); trap 'rm -rf "$STRINGSDATA" "$WORK"' EXIT INT TERM
  cp "$CATALOG" "$WORK/Localizable.xcstrings"
  xcrun xcstringstool sync "$WORK/Localizable.xcstrings" --stringsdata "${FILES[@]}"
  AFTER=$(shasum -a 256 "$WORK/Localizable.xcstrings" | cut -d' ' -f1)
  if [[ "$BEFORE" != "$AFTER" ]]; then
    echo "Der Katalog ist nicht aktuell. Scripts/localize.sh laufen lassen und mitcommitten." >&2
    diff <(xcrun xcstringstool print "$CATALOG") \
         <(xcrun xcstringstool print "$WORK/Localizable.xcstrings") | head -40 >&2 || true
    exit 1
  fi
  print -P "%F{green}✓%f Katalog ist aktuell"
else
  xcrun xcstringstool sync "$CATALOG" --stringsdata "${FILES[@]}"
  print -P "%F{blue}==>%f $CATALOG aktualisiert"
fi

# What is still missing, so it does not go unnoticed until someone sees German in the English
# app. "new" and "needs_review" are Xcode's own states.
python3 - "$CATALOG" <<'PY'
import collections, json, sys
cat = json.load(open(sys.argv[1], encoding="utf-8"))
languages = {lang for entry in cat["strings"].values() for lang in entry.get("localizations", {})}
missing = collections.Counter()
for key, entry in cat["strings"].items():
    if entry.get("shouldTranslate") is False:
        continue
    for lang in sorted(languages | {"en"}):
        unit = entry.get("localizations", {}).get(lang, {}).get("stringUnit", {})
        if unit.get("state") not in ("translated",):
            missing[lang] += 1
total = sum(1 for e in cat["strings"].values() if e.get("shouldTranslate") is not False)
print(f"    {total} Texte insgesamt")
for lang, n in sorted(missing.items()):
    print(f"    {lang}: {n} fehlen noch" if n else f"    {lang}: vollständig")
PY
