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
# Only Swift Build leaves .stringsdata behind. It is the default from Xcode 27 on; the native
# build system that older toolchains default to (the CI runners' Xcode 26) writes none.
swift build --build-system swiftbuild >/dev/null

# Products and library targets, never the test bundles: a test's texts are not shipped.
# `-testable-` is the second, identical copy a target gets when a test bundle links it; the
# keys are the same, but counting them twice makes the numbers below lie.
FILES=("${(@f)$(find "$BUILD" -name '*.stringsdata' -not -path '*Tests*' -not -path '*-testable-*' | sort)}")
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

# Two checks the app itself cannot make: is anything still untranslated, and does every
# translation take its arguments in the same order and of the same type as the German?
# A swapped %lld and %@ does not look wrong — it reads the integer as a pointer and crashes.
python3 - "$CATALOG" "$CHECK" <<'CATALOGCHECK'
import collections, json, re, sys
cat = json.load(open(sys.argv[1], encoding="utf-8"))
strict = sys.argv[2] == "1"
strings = cat.get("strings", {})
source = cat.get("sourceLanguage", "de")
languages = {lang for e in strings.values() for lang in e.get("localizations", {})} - {source}

SPEC = re.compile(r"%(?:(\d+)\$)?(lld|ld|d|@|f|%)")
# Markdown links inside a text (the Gmail guide in the account sheet): a translation has to
# point at the same pages, or the English guide drifts the day Google moves one.
LINK = re.compile(r"\]\((https?://[^)\s]+)\)")
def sequence(text):
    """The argument types in the order the format consumes them."""
    out, auto = {}, 0
    for position, kind in SPEC.findall(text):
        if kind == "%":
            continue
        if position:
            out[int(position)] = kind
        else:
            auto += 1
            out[auto] = kind
    return [out[i] for i in sorted(out)]

missing, mismatched, relinked, translatable = collections.Counter(), [], [], 0
for key, entry in strings.items():
    if entry.get("shouldTranslate") is False:
        continue
    translatable += 1
    for lang in languages:
        unit = entry.get("localizations", {}).get(lang, {}).get("stringUnit", {})
        if unit.get("state") != "translated":
            missing[lang] += 1
            continue
        if sequence(key) != sequence(unit.get("value", "")):
            mismatched.append((lang, key, unit["value"]))
        if sorted(LINK.findall(key)) != sorted(LINK.findall(unit.get("value", ""))):
            relinked.append((lang, key, unit["value"]))

print(f"    {translatable} Texte, Quellsprache {source}")
for lang in sorted(languages):
    n = missing[lang]
    print(f"    {lang}: {n} fehlen" if n else f"    {lang}: vollständig")
for lang, key, value in mismatched:
    print(f"    x {lang}: Platzhalter in anderer Reihenfolge oder Art")
    print(f"        {key!r}")
    print(f"        {value!r}")

for lang, key, value in relinked:
    print(f"    x {lang}: andere Links als im deutschen Text")
    print(f"        {key!r}")
    print(f"        {value!r}")

if mismatched:
    sys.exit("Platzhalter passen nicht zusammen - ein vertauschtes %lld/%@ stuerzt zur Laufzeit ab.")
if relinked:
    sys.exit("Links in einer Uebersetzung weichen vom deutschen Text ab.")
if strict and any(missing.values()):
    sys.exit("Es fehlen Uebersetzungen.")
CATALOGCHECK
