# Das Archiv einrichten

Ein **Archiv** ist ein Ordner, in dem MailKeeper alles ablegt: die Mails selbst, die Metadaten
und einen Suchindex. Du kannst mehrere Archive haben — eines für privat, eines für die Arbeit,
eines auf einer externen Platte.

## Das erste Archiv

Beim ersten Start legt MailKeeper ein **Standard-Archiv** in seinem eigenen Container an
(`~/Library/Containers/de.paranoidsecurity.MailKeeper/Data/Library/Application Support/MailKeeper/Archive`).
Das genügt zum Ausprobieren — wer auch mit `mkctl` arbeiten oder das Archiv gezielt sichern
will, legt es besser an einem selbst gewählten Ort an:

- **Ablage › Neues Archiv anlegen …** — der Ordner muss **leer** sein. („„…“ ist nicht leer. Ein
  neues Archiv braucht einen leeren Ordner.“)
- **Ablage › Archiv öffnen …** (⇧⌘O) für ein vorhandenes.
- **Ablage › Archiv wechseln** listet alles, was du schon einmal geöffnet hast. Dasselbe Menü
  erreichst du über einen Klick auf den Fenstertitel.

Der Fenstertitel zeigt immer, in welchem Archiv du gerade bist, und die Statusleiste unten
rechts den Pfad.

> **Während ein Abruf, ein Import oder eine Aktion läuft, lässt sich das Archiv nicht
> wechseln.** MailKeeper sagt dann, was läuft. Eine **Aktion** kannst du mit dem **×** in der
> Statusleiste anhalten; was fertig ist, bleibt fertig. Ein **Abruf oder Import** läuft zu Ende
> — beide arbeiten inkrementell, ein Abbruch würde also nur Zeit kosten.

## Wo es liegen sollte

**Verschlüsselt.** Die Mails liegen als gewöhnliche `.eml`-Dateien im Archiv — wer die Dateien
lesen kann, liest deine Mails. Die Verschlüsselung kommt von FileVault oder einem
verschlüsselten Volume. Liegt das Archiv auf einem unverschlüsselten Laufwerk, warnt die
Statusleiste: „Archiv-Volume ist nicht verschlüsselt“.

**Mit genug Platz.** Rechne grob mit der Größe deiner Postfächer plus etwa 20 % für den Index.
Gleiche Mails aus mehreren Ordnern werden nur einmal gespeichert.

**Gesichert.** Der ganze Ordner gehört ins Backup. Die Mail-Dateien ändern sich nie, nachdem sie
geschrieben wurden — das kommt Time Machine und restic entgegen.

**Auf einer externen Platte?** Geht, aber MailKeeper meldet „Das gewählte Archiv ist nicht
erreichbar. Ist das Laufwerk angeschlossen?“, wenn sie fehlt.

## Was drin liegt

```
<Archiv>/
├── blobs/              die Mails, als .eml, nach Prüfsumme abgelegt
├── journal/            Metadaten und deine Entscheidungen (kein Mailinhalt)
├── index.sqlite        Suchindex — jederzeit neu baubar
├── accounts.json       die Konten, ohne Passwörter
├── ai.json             KI-Einstellungen, ohne Schlüssel
├── saved-searches.json deine Ansichten
├── gold.json           deine Labels für die Messung
├── gold-runs.jsonl     die Ergebnisse der Messungen
├── queue/              laufende Aktionen, eine Datei je Auftrag
└── archive.json · .lock · tmp/
```

Wahrheit sind **blobs** und **journal**. Alles andere lässt sich daraus wieder herstellen:

```bash
mkctl --archive ~/MeinArchiv rebuild-index
```

Das brauchst du praktisch nie — aber es ist der Grund, warum ein kaputter Index kein Verlust
ist. Und: Jedes Mailprogramm kann die `.eml`-Dateien lesen, auch ohne MailKeeper. `grep` auch.

Ob alles unversehrt ist, prüft:

```bash
mkctl --archive ~/MeinArchiv verify
```

Das liest jede Mail-Datei und vergleicht ihre Prüfsumme.

## Das Fenster

Drei Spalten:

- **Links** die Seitenleiste: „Alle Nachrichten“, deine gespeicherten **Ansichten**, der Bereich
  **Archiv** (Papierkorb, Spam-Prüfung, Verdächtig) und darunter je Konto seine Postfächer.
- **In der Mitte** die Liste — entweder Nachrichten (Datum, Von, Betreff, 📎, 💬, Größe) oder,
  über das **Ansicht**-Auswahlfeld in der Symbolleiste, nach **Absender**, **Domain** oder
  **Liste** gruppiert ([Kapitel 7](07-aufraeumen.md)).
- **Rechts** der Leser mit Kopfzeilen, „Ort“, „Art“, „Prüfung“, „Echtheit“, „Ablage“, Anhängen
  und dem Text.

Spaltenbreiten und Sortierung merkt sich MailKeeper.

Die **Statusleiste** unten zeigt, was gerade läuft, wie viele Mails die Ansicht hat, die Größe
des Archivs und seinen Pfad. Dort steht auch der Link auf einen **unterbrochenen Auftrag**, den
du fortsetzen kannst.

Mit **⌘[** und **⌘]** gehst du im Verlauf zurück und vor, wie im Browser; das Menü **Verlauf**
zeigt die letzten Stationen.

## Mehrere Archive

Jedes Archiv ist für sich: eigene Konten, eigene KI-Einstellungen, eigenes Gedächtnis. Was sich
zwei Archive teilen, sind die **Zugangsdaten im Schlüsselbund** — dasselbe Postfach in zwei
Archiven braucht das Passwort nur einmal.

Aus der Liste der bekannten Archive entfernst du einen Eintrag über **Archiv wechseln › Aus der
Liste entfernen**. Der Ordner bleibt, wo er ist.

## Weiter

- [Kapitel 2 — Postfächer verbinden](02-postfaecher-verbinden.md)
