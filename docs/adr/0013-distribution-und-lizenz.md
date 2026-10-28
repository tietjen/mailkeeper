# ADR-0013: Vertrieb und Lizenz — quelloffen lesbar, Verwertung bleibt beim Autor

- Status: teils entschieden (TJ, 2026-10-28); das Erlösmodell ist offen
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
