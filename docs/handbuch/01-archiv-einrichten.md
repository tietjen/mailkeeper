# Das Archiv einrichten

Ein **Archiv** ist ein Ordner, in dem MailKeeper alles ablegt: die Mails selbst, die Metadaten
und einen Suchindex. Du kannst mehrere Archive haben — eines für privat, eines für die Arbeit,
eines auf einer externen Platte.

## Der erste Start

MailKeeper legt beim ersten Start **nichts** an — kein Archiv, keinen Ordner. Wer die App nur
ausprobiert und wieder löscht, hat keine Mails irgendwo liegen. Stattdessen kommen nacheinander
zwei Dinge:

1. **Die Einrichtung** — drei Seiten:
   - **So arbeitet MailKeeper:** Server und Archiv in einem Bild — Abrufen kopiert nur, das
     Archiv vergisst nichts, den Server ändert MailKeeper nur auf deinen Befehl
     ([Kapitel 3](03-abrufen-und-suchen.md#was-sich-auf-dem-server-ändert--und-was-das-archiv-daraus-macht)).
   - **Dein Archiv:** hier entsteht das erste Archiv — am Standard-Ort, in einem Ordner deiner
     Wahl oder durch Öffnen eines vorhandenen (siehe unten).
   - **Postfächer verbinden:** ein Konto nach dem anderen, so viele du willst
     ([Kapitel 2](02-postfaecher-verbinden.md)). Ist mindestens eines da, startet
     **Abrufen und weiter** gleich den ersten Abruf.
2. **Der Rundgang** — fünf Karten an den Teilen des Fensters: Seitenleiste, Liste, Leser,
   Symbolleiste. Eine Karte bleibt stehen, bis du **Weiter**, **Überspringen** oder **Fertig**
   klickst — auch wenn du zwischendurch in ein anderes Programm wechselst.

Beides kannst du überspringen („Später“) und jederzeit wieder holen: **Hilfe › Einrichtung …**
und **Hilfe › Rundgang zeigen**. Im selben Menü steht die Hilfe im Programm (**⌘?**) — die
Kurzfassung dieses Handbuchs, durchsuchbar.

Hast du die Einrichtung übersprungen, sagt das Fenster selbst, was fehlt: „Noch kein Archiv“
mit **Einrichtung starten**, und in einem leeren Archiv **Konto hinzufügen …** oder
**Jetzt abrufen**.

## Das erste Archiv

Drei Wege, in der Einrichtung wie im Menü:

- **Am Standard-Ort anlegen** — im Container der App
  (`~/Library/Containers/de.paranoidsecurity.MailKeeper/Data/Library/Application Support/MailKeeper/Archive`).
  Das genügt zum Ausprobieren. Der Fenstertitel heißt dann „Standard-Archiv“.
- **In eigenem Ordner anlegen …** (in der Ablage: **Neues Archiv anlegen …**) — besser, wenn
  du auch mit `mkctl` arbeiten oder das Archiv gezielt sichern willst. Der Ordner muss **leer**
  sein. („„…“ ist nicht leer. Ein neues Archiv braucht einen leeren Ordner.“)
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

**Die Konten gehören zum Archiv.** Wechselst du das Archiv, wechselt die Seitenleiste auf dessen
Konten, und **Einstellungen › Konten** zeigt oben, für welches Archiv die Liste gilt („Konten in
„Standard-Archiv““). Für mehrere Postfächer brauchst du aber kein zweites Archiv: Ein Archiv
nimmt beliebig viele Konten auf ([Kapitel 2](02-postfaecher-verbinden.md#mehrere-konten-in-einem-archiv)).

Aus der Liste der bekannten Archive entfernst du einen Eintrag über **Archiv wechseln › Aus der
Liste entfernen**. Der Ordner bleibt, wo er ist.

## Weiter

- [Kapitel 2 — Postfächer verbinden](02-postfaecher-verbinden.md)
