# Postfächer aufräumen

Ein volles Postfach räumt man nicht Mail für Mail auf, sondern nach **Absendern**. Dafür hat
MailKeeper eine eigene Ansicht — und für alles, was dabei gelöscht oder verschoben wird, den
immer gleichen Weg: erst der Plan, dann dein Klick, dann die Prüfung.

## Die Aufräum-Ansicht

Oben in der Symbolleiste steht **Ansicht**: „Nachrichten“, **„Absender“**, **„Domains“**,
**„Listen“**. Die drei letzten gruppieren dieselben Mails — mit Anzahl, Größe, Anteil
ungelesener, neuester und ältester Mail, und einem **✉︎** für Absender, die eine Abmeldung
anbieten.

Ein hoher Ungelesen-Anteil ist das deutlichste Zeichen: über 90 % bei mindestens zehn Mails
färbt MailKeeper orange ein. Das ist Post, die du nie liest.

**Doppelklick** auf eine Gruppe zeigt deren Mails.

### Die Detailspalte

Rechts stehen zu jeder Gruppe:

- **Mails · Größe · Gelesen · Seit** auf einen Blick,
- ein **Balkendiagramm über 24 Monate** („etwa N pro Monat“, „zuletzt vor …“) — daran siehst
  du, ob der Absender noch aktiv ist,
- **Ablage · Auf dem Server · Mit Anhang · Abmeldung**,
- bei Domains und Listen die einzelnen Absender darin,
- die neuesten Mails.

### Bereiche

Ohne ausgewählte Gruppe zeigt die rechte Spalte **Aufräumen** mit vier Bereichen, die die
Gruppenliste eingrenzen:

| Bereich | Suche dahinter |
|---|---|
| Newsletter, nie geöffnet | `is:list is:unread` |
| Älter als zwei Jahre, noch auf dem Server | `before:2y on:server` |
| Größer als 10 MB | `larger:10M` |
| Nur noch im Archiv | `only:archive` |

Immer nur einer ist aktiv; ein zweiter Klick hebt ihn auf. Daneben stehen **Vorschläge** und
deine **Regeln** sowie die fünf größten Gruppen nach Speicherplatz.

## Die vier Wege, eine Mail loszuwerden

| Weg | Was passiert | Umkehrbar? |
|---|---|---|
| **Auf dem Server löschen** | in den Papierkorb des Servers; Archiv behält sie | ja, über „Zurückspielen“ |
| **Aus dem Archiv löschen** | in den Archiv-Papierkorb, nach 30 Tagen endgültig | 30 Tage lang |
| **Endgültig löschen** | sofort weg | **nein** |
| **Abmelden** | keine neuen mehr | — |

Der häufigste Fall ist der erste: **Platz auf dem Server schaffen, ohne etwas zu verlieren.**
Das Archiv behält alles.

### Auf dem Server löschen

Aus dem Kontextmenü, dem Menü **Mails**, oder für eine ganze Gruppe über **Aufräumen …**.

Es öffnet sich der **Plan**: wie viele Mails, wie groß, je Konto aufgeschlüsselt, mit Beispielen
— und was **übersprungen** wird und warum. Erst dein Klick auf **Ausführen** startet etwas.

Im Plan steht die **Schonfrist** (Standard 30 Tage ab Eingang auf dem Server). Sie schützt neue
Mail vor anderen Programmen, die dasselbe Postfach lesen — ein Dokumentenarchiv etwa, das noch
nicht abgeholt hat. Unter sieben Tagen warnt MailKeeper.

> Gezählt wird ab dem **Eingang auf dem Server**, nicht ab dem Datum der Mail. Eine alte Mail,
> die erst kürzlich hochgeladen wurde (Umzug, Import), ist dort neu.

Typische Übersprungen-Gründe: „erst seit weniger als N Tagen auf dem Server (Schonfrist)“,
„Konto ist hier nicht eingerichtet“, „markiert“.

### Aus dem Archiv löschen

⌘⌫ oder das Kontextmenü. Die Mails wandern in den **Papierkorb des Archivs** und werden nach 30
Tagen endgültig gelöscht.

Was **noch auf einem Server liegt, wird übersprungen** („liegt noch auf einem Server – erst dort
löschen“). Der Plan bietet dafür direkt **„Zuerst auf dem Server löschen …“** an. Der Grund: Was
beim nächsten Abruf wiederkäme, löscht man nicht sinnvoll aus dem Archiv.

Im Papierkorb (Seitenleiste) gibt es **Wiederherstellen**, **Endgültig löschen …** und
**Papierkorb leeren …**. Die beiden letzten verlangen **Touch ID oder dein Passwort** — ohne
beides geht es nicht.

### Zurückspielen

Der umgekehrte Weg: **Auf den Server zurückspielen …** lädt Mails aus dem Archiv wieder hoch —
dorthin, wo sie zuletzt lagen, oder in einen Ordner deiner Wahl. Angeboten werden nur Ordner,
die MailKeeper für dieses Konto auch abruft.

Die ursprünglichen Markierungen und das Eingangsdatum kommen mit (Schalter „Ursprüngliches
Eingangsdatum behalten“). Nach dem Hochladen holt MailKeeper die Mail zurück und vergleicht sie.

> Proton braucht etwa 1,5 Sekunden je Mail und nimmt das Datum **immer** aus der Mail selbst.

### Vom Newsletter abmelden

In der Gruppenansicht und im Leser. Wann der Knopf gesperrt ist und warum, steht in
[Kapitel 6](06-spam-und-phishing.md#vom-newsletter-abmelden).

## Die Ablage ändern

Unabhängig vom Löschen: **wo eine Mail im Archiv einsortiert ist.** Im Leser auf **„Ablage
ändern …“** oder über das Kontextmenü.

MailKeeper unterscheidet:

- **„Ort“** — wo die Mail gesehen wurde. Tatsache, nicht änderbar.
- **„Ablage“** — wo das Archiv sie führt. Deine Entscheidung.

Im Blatt wählst du einen bekannten Ordner oder legst einen neuen Namen an; **„Zurück, wo
abgerufen bzw. importiert“** hebt die eigene Ablage wieder auf.

Liegt die Mail auf einem Server, fragt MailKeeper zusätzlich: **Nicht ändern** (Standard),
**Ebenso nach „X“** oder **In einen anderen Ordner …**.

> **MailKeeper legt auf dem Server nie Ordner an.** Fehlt der Ordner dort, bleibt die Mail, wo
> sie ist — und sagt es. Bei **Gmail** ändert MailKeeper die Ablage auf dem Server gar nicht,
> weil Ordner dort Labels sind; im Archiv funktioniert es trotzdem.

## Regeln

Was du immer wieder tust, kann eine **Regel** übernehmen (Einstellungen › Regeln): eine Suche
plus eine Aktion — „Art festlegen“, „nach N Tagen vom Server löschen“ oder „in den
Spam-Ordner“.

Beim Schreiben zeigt der Editor laufend, **wie viele Mails heute passen**. Die Spalte rechts in
der Regelliste sagt, wie viele gerade bereit wären, und ob die Regel **von selbst läuft**.

MailKeeper schlägt Regeln vor, wenn du dich wiederholst — dieselbe Art für mindestens drei
Mails eines Absenders, dreimal auf dem Server gelöscht. Angenommen wird ein Vorschlag nur von
dir.

## Exportieren

**Ablage › Auswahl exportieren …** (⇧⌘E) oder **Alle Mails der Liste exportieren …**:

- **einzelne `.eml`-Dateien** in einen Ordner (am besten einen leeren — vorhandene Dateien
  werden **nie** überschrieben), oder
- **eine mbox-Datei**.

Jede Mail wird vorher geprüft; beschädigte werden nicht geschrieben, sondern gemeldet. Am Ende
sagt MailKeeper, wie viel geschrieben wurde und was ausgelassen wurde.

## Wenn etwas schiefgeht

Jede Aktion lässt sich **anhalten** (× in der Statusleiste) — Erledigtes bleibt erledigt, der
Rest wird fortgesetzt. Nach einem Absturz steht in der Statusleiste „Unterbrochener Auftrag …
fortsetzen“.

Das Ergebnis-Blatt zeigt Erledigt / Fehlgeschlagen / Übersprungen / Offen mit Gründen, und
**„Fehlgeschlagene erneut versuchen …“**. Jede Aktion steht mit Metadaten im Prüfprotokoll
`~/Library/Logs/MailKeeper/audit.jsonl`.

## Weiter

- [Kapitel 8 — Nach Bedeutung suchen und zusammenfassen](08-bedeutung-und-zusammenfassung.md)
- Hintergrund: [ADR-0006](../adr/0006-destructive-actions.md),
  [ADR-0011](../adr/0011-archive-placement.md)
