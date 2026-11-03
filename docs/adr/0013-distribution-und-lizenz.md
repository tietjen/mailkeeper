# ADR-0013: Vertrieb und Lizenz — quelloffen lesbar, Verwertung bleibt beim Autor

- Status: entschieden — PolyForm Noncommercial 1.0.0 (TJ, 2026-11-02, siehe
  [Nachtrag](#nachtrag-2026-11-02-polyform-noncommercial)); vorher teils entschieden (2026-10-28)
- Deciders: TJ

## Context

MailKeeper soll angeboten werden können (Leitentscheidung 5 der Plandatei). Vor Phase 8
(Distribution) stellte sich die Frage, ob Sparkle und Homebrew dem im Weg stehen. Tun sie
nicht — die Prüfung ergab:

- **Sparkle** ist der übliche Weg für bezahlte Mac-Apps außerhalb des App Store. Spike S4 hat
  gezeigt, dass Sparkle 2.10 in der Sandbox mit EdDSA-signiertem Feed funktioniert.
- **Homebrew** nimmt kommerzielle Software in `homebrew/cask`. Zwei Auflagen: Der Download muss
  **ohne Anmeldung** erreichbar sein, und eine Testversion muss **ohne erneuten Download** zur
  Vollversion werden können — also genau das Modell „frei ladbar, Schlüssel schaltet frei“.
- Im Weg stand etwas anderes: **das Repo war öffentlich, aber ohne Lizenz.**

## Decision

1. **Die Quelle bleibt öffentlich lesbar.** Bei einem Programm, dem man sein Mailarchiv
   anvertraut, ist Nachprüfbarkeit das Verkaufsargument, nicht ein Zugeständnis. Ein
   geschlossenes Repo kam deshalb nicht in Frage.
2. **Die Verwertung bleibt beim Autor.** Keine freizügige Open-Source-Lizenz (MIT, Apache),
   unter der ein Fork dieselbe App verkaufen dürfte.
3. **Heute: `LICENSE` mit „alle Rechte vorbehalten“** und ein Hinweis in der README. Das ist
   kein neues Recht, sondern die bestehende Rechtslage ausgesprochen — vorher war unklar, was
   Leser dürfen. Reversibel in beide Richtungen.
4. **Das Erlösmodell ist offen** und wird mit dem Preis entschieden. Die beiden ernsthaften
   Kandidaten, beide fertige Texte:
   - *privat frei, gewerblich zahlt* → PolyForm Noncommercial 1.0.0;
   - *alle zahlen, mit Testphase* → FSL-1.1 oder BUSL 1.1 (Wettbewerbsverbot, Umwandlung in
     Apache nach 2–4 Jahren).
5. **Vor öffentlichen Release-Binaries** müssen Lizenz **und** Nutzungsbedingungen stehen.
   Phase 8 baut bis dahin alles andere: CI, Notarisierung, Sparkle-Gerüst, Cask im eigenen Tap,
   Lokalisierung.

## Consequences

- **Sparkle:** Der EdDSA-Signaturschlüssel ist ab jetzt ein Geschäftswert, nicht nur ein
  Entwicklungsdetail — Vault, und als Secret in die Release-CI, nie ins Repo. Der Update-Feed
  bleibt offen und ungeschützt, auch bei einer Kaufversion: Updates hinter einen Lizenzcheck zu
  hängen, trifft zahlende Kunden bei jedem Schlüsselproblem und hält niemanden auf, der nicht
  zahlen will.
- **Eine spätere Lizenzprüfung gehört in die App, nicht in den Updater**, und zwar offline:
  eine Ed25519-signierte Lizenzdatei, geprüft wie Sparkle seine Updates prüft. Ein
  Aktivierungsserver widerspräche dem, was Handbuch-Kapitel 9 zusichert — dass nichts den Mac
  verlässt.
- **Homebrew:** Das Cask braucht `auto_updates true`, sonst streiten Sparkle und `brew upgrade`
  um dieselbe App; mit dem Eintrag lässt Homebrew sie in Ruhe und nur `brew upgrade --greedy`
  fasst sie an. Eigener Tap `tietjen/tap` zuerst — das Haupt-Repo hat Bekanntheitshürden, die
  für Selbsteinreicher höher liegen, und bleibt später offen.
- **Kein Mac App Store.** Er verträgt sich nicht mit Sparkle, und die Sandbox-Ausnahmen, die
  Sparkle braucht, gibt es dort nicht.
- **Gmail-OAuth (ADR-0012 §2):** Ein mitgelieferter, verifizierter Google-Client kostet ab dem
  Verkauf ein jährliches CASA-Assessment. Bis dahin bringt jedes Konto seine eigene Client-ID
  mit; das Format ist darauf vorbereitet.
- Drum herum kommt Kaufmännisches dazu, das keine Technik ist: Impressum,
  Widerrufsbelehrung für digitale Güter, Umsatzsteuer im EU-Ausland (üblicherweise über einen
  Merchant of Record wie Paddle, FastSpring oder Lemon Squeezy), ein Supportkanal.

## Alternatives

- **MIT/Apache:** maximale Verbreitung, aber ein Fork dürfte dieselbe App verkaufen. Als Geschäft
  blieben Bequemlichkeit, Marke und Support.
- **Repo schließen:** nähme der App den Grund, warum man ihr das Mailarchiv anvertraut — und die
  Historie ist ohnehin öffentlich.
- **Mac App Store:** schlösse Sparkle aus, kostet 15–30 % und erlaubt die nötigen
  Sandbox-Ausnahmen nicht.

## Nachtrag 2026-11-02: PolyForm Noncommercial

**Entscheidung (TJ):** MailKeeper steht unter der **PolyForm Noncommercial License 1.0.0**
(`LICENSE`, SPDX `PolyForm-Noncommercial-1.0.0`, Text unverändert und gegen die SPDX-Fassung
geprüft). Privat und für andere nichtkommerzielle Zwecke ist es frei, auch Ändern und
Weitergeben; gewerbliche Nutzung braucht eine eigene Lizenz. Damit ist die Lizenzsperre aus §5
technisch offen; veröffentlicht wird weiterhin erst mit einem Tag.

- **Warum diese:** Sie passt zum ersten Release als kostenlose Vorabversion. Wer privat
  nutzt, braucht keinen Schlüssel, und das Gewerbliche bleibt beim Autor. Eine Lizenz gilt je
  Version: Spätere Versionen können anders lizenziert werden, ohne dass jemand, der eine
  frühere Version hat, Rechte verliert.
- **Korrektur zu §4:** FSL-1.1 gehört nicht zu „alle zahlen“. Sie erlaubt jede Nutzung außer
  einem Konkurrenzprodukt, Endnutzer zahlten damit nicht. „Alle zahlen, mit Testphase“ ginge
  mit BUSL 1.1 ohne Additional Use Grant (dann ist nur Nicht-Produktivnutzung frei) oder mit
  eigenen Kaufbedingungen.
- **`TERMS.md`** (deutsch maßgeblich, englische Übersetzung) erklärt, was nichtkommerziell
  heißt, und regelt, was eine Lizenz nicht regelt: Haftung bei unentgeltlicher Überlassung nach
  deutschem Recht (Vorsatz, grobe Fahrlässigkeit, arglistig verschwiegene Mängel; zwingende
  Haftung unberührt), keine Pflicht zu Updates oder Unterstützung, Datenschutz mit Verweis auf
  Handbuch-Kapitel 9. Den Namen als Kennzeichen umfasst die Lizenz nicht; geänderte Fassungen
  werden gebeten, anders zu heißen. Eine Pflicht daraus zu machen, nähme zurück, was die Lizenz
  gibt (Review).
- **Änderungen der Bedingungen** gelten nur für die Version, der sie beiliegen, und werden in
  den Versionshinweisen angekündigt. Eine stille Sparkle-Installation macht neue Bedingungen
  nicht wirksam (§ 305 Abs. 2 BGB), deshalb behält die ältere Version ihre.
- **Update-Signatur:** Sparkle 2.10.1 nimmt ein Update an, wenn der EdDSA-Schlüssel **oder** die
  Developer-ID-Signatur zur installierten App passt (`SUUpdateValidator.m`, „any one of“).
  Handbuch Kapitel 9 und `TERMS.md` sagen das jetzt so.
- **Fremdlizenzen in der App:** Apache 2.0 (SwiftNIO und Verwandte), MIT (Sparkle) und die
  OpenSSL-/SSLeay-/ISC-Lizenzen des BoringSSL in swift-nio-ssl verlangen ihren Text in jeder
  weitergegebenen Kopie, und das DMG ist eine. `build-app.sh` legt `LICENSE.txt`, `TERMS.md` und
  `ThirdPartyNotices.txt` nach `Contents/Resources`. Die Notices entstehen beim Bau aus
  `Package.resolved` und den Checkouts. Der Bau bricht ab, wenn eine Lizenzdatei fehlt, wenn
  `Package.resolved` nicht lesbar ist und wenn die Zahl der Abschnitte nicht zur Zahl der Pakete
  passt. Zwei Texte nennen die Pakete nur als URL, sie liegen deshalb im Repo:
  `packaging/licenses/BoringSSL.txt` (Upstream, Commit `817ab07e…`, der Bau prüft den Commit in
  swift-nio-ssl) und `packaging/licenses/SwiftNIO-embedded.txt` (llhttp, cpp_magic, sha1 der
  WIDE Project, fastbase64, stringencoders). Für letztere prüft der Bau die SHA-256 der beiden
  `NOTICE.txt`, gegen die sie zusammengestellt sind.
- **Offen:** Preis und Bezugsweg der gewerblichen Lizenz (bis dahin auf Anfrage); Lizenz und
  Bedingungen in der App zeigen (Hilfe-Menü bzw. „Über MailKeeper“); juristische Durchsicht von
  `TERMS.md` vor dem ersten Verkauf.
