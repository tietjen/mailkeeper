# Die Kommandozeile: `mkctl`

`mkctl` arbeitet auf demselben Archiv wie die App — dasselbe Format, dieselben Regeln. Es ist
der Weg für Skripte, für große Importe und für alles, was man lieber in einem Terminal
wiederholt als mit der Maus.

```bash
swift build -c release --product mkctl
```

## Welches Archiv

```bash
mkctl --archive ~/MeinArchiv <befehl>     # ausdrücklich
export MAILKEEPER_ARCHIVE=~/MeinArchiv    # für die Sitzung
```

Ohne beides: `~/Library/Application Support/MailKeeper/Archive`. Die Reihenfolge der Argumente
ist egal — `mkctl search rechnung --archive ~/X` geht auch.

> **Achtung:** Das ist **nicht** das Standard-Archiv der App. Die läuft in einer Sandbox und legt
> ihres — wenn du in der Einrichtung „Am Standard-Ort anlegen“ wählst — in ihrem Container ab
> (`~/Library/Containers/de.paranoidsecurity.MailKeeper/Data/Library/Application Support/…`).
> Wer beide Wege nutzt, legt das Archiv an einen selbst gewählten Ort und gibt `--archive`
> immer mit — sonst prüft `mkctl verify` ein leeres Archiv und meldet brav, dass alles in
> Ordnung ist.

Ein Archiv **anlegen** können nur `init`, `import` und `account add`; alles andere erwartet ein
vorhandenes. Fehler gehen nach stderr (`mkctl: …`), der Rückgabewert ist dann 1.

## Einrichten und füllen

```bash
mkctl init
mkctl import maildir ~/MailArchive --account alt
mkctl import mbox ~/Takeout/Mail/"All mail.mbox" --account gmail-alt --mailbox "Alle Nachrichten"
mkctl import eml ~/Desktop/Einzelmails --account sonstiges
```

`--account` ist Pflicht. `--mailbox` wirkt **nur** bei `mbox`. Der Fortschritt läuft über
stderr, die Zusammenfassung über stdout — Pipes bleiben also sauber.

### Konten

```bash
mkctl account add imap tj@firma.de --id arbeit --host mail.firma.de
mkctl account add gmail ich@gmail.com --id gmail            # App-Passwort
mkctl account add gmail ich@gmail.com --id gmail \
      --google-client-id 123-abc.apps.googleusercontent.com --google-client-secret
mkctl account add proton ich@proton.me --id proton --trust <fingerabdruck>

mkctl account list
mkctl account test arbeit
mkctl account signin gmail --google-client-id …   # auf Google-Anmeldung umstellen
mkctl account password gmail                      # zurück zum App-Passwort
mkctl account remove arbeit [--keep-password]
```

Gemeinsame Schalter: `--name`, `--include A,B`, `--exclude A,B`, `--with-junk-trash`,
`--password-stdin`, `--trust <fingerabdruck>`.

Passwörter nimmt `mkctl` **nie als Argument** — entweder verdeckt abgefragt oder über
`--password-stdin` (eine Zeile von stdin). Gespeichert werden Zugangsdaten erst, **nachdem** die
Verbindung stand.

> **In Skripten:** Rückfragen beantwortet `mkctl` ohne Terminal immer mit *nein*. Für Proton
> heißt das `--trust <fingerabdruck>`, für Löschbefehle `--yes`.

## Abrufen, suchen, ansehen

```bash
mkctl sync                     # alle Konten
mkctl sync gmail arbeit        # nur diese
mkctl stats
mkctl accounts
mkctl search rechnung müller --limit 50
mkctl groups --by domain --limit 20
mkctl show 12345 [--headers]
```

`sync` gibt 1 zurück, wenn irgendetwas fehlgeschlagen ist — brauchbar für einen LaunchAgent.

> **Eine Falle:** Bei `search` und `groups` gilt das **letzte Wort als Wortanfang** (wie die
> Live-Suche in der App). `mkctl search rechnung amaz` findet „Amazon“. Willst du das Wort
> genau, häng ein Leerzeichen an: `mkctl search 'rechnung amaz '`. Bei den Befehlen, die etwas
> verändern, gilt immer das genaue Wort.

## Aufräumen

Immer erst der Trockenlauf:

```bash
mkctl plan server-delete 'is:list ist:ungelesen vor:1j'
mkctl plan restore 'konto:arbeit' --to arbeit:INBOX
```

Beide enden mit `dry run — nothing changed`. Dann im Ernst:

```bash
mkctl server-delete 'is:list ist:ungelesen vor:1j' --grace 60 --yes
mkctl restore 'konto:arbeit vor:2y' --to arbeit:Archiv --now
mkctl export 'kategorie:rechnung ab:1j' --eml ~/Rechnungen
mkctl export --all --mbox ~/Sicherung.mbox
```

`server-delete` und `restore` **verweigern eine leere Abfrage**. Ohne `--yes` kommt eine
Rückfrage (`j`/`ja`/`y`/`yes`).

## KI

```bash
mkctl ai config --on --endpoint http://127.0.0.1:11434/v1
mkctl ai config --model classify=qwen2.5:14b-instruct --model embed=nomic-embed-text
mkctl ai key                       # verdeckt eingeben; --delete löscht
mkctl ai status
mkctl ai test

mkctl classify --ai --limit 100 'ab:30d'
mkctl embed
mkctl similar 12345
mkctl meaning streit mit dem vermieter
mkctl summarize 12345 [--thread]
mkctl ask rechnungen vom letzten jahr mit pdf
```

> `classify` **schreibt auch ohne `--ai`**: Die Regel-Einordnung läuft immer. Mit `--ai` fragt
> es zusätzlich das Modell für die offenen Mails.

HTTP ohne TLS nimmt `ai config` nur für `localhost`, `127.0.0.1`, `::1`, `*.localhost` und
`*.ziti` an.

## Gedächtnis, Beziehungen, Regeln

```bash
mkctl memory list
mkctl memory note --about rechnung@stadtwerke.example "immer Rechnungen"
mkctl memory term "Firma = das Proton-Konto"
mkctl memory forget <id> [<id> …]
mkctl memory export [datei.json]      # ohne Datei: nach stdout
mkctl memory import datei.json

mkctl relations list
mkctl relations suggest
mkctl rules list
mkctl rules suggest
mkctl cleanup
mkctl unsubscribe 'ist:liste' --limit 30
```

`--about <text>` setzt das Thema einer Notiz, `--account <id>` ihren Bereich.
`mkctl rules suggest` liest das Prüfprotokoll von `mkctl` (`~/Library/Logs/MailKeeper/`), nicht
das der App aus ihrem Container ([Kapitel 9](09-sicherheit-und-datenschutz.md#wo-deine-daten-liegen)).
`mkctl unsubscribe --dkim` zeigt zusätzlich, was der Absender signiert hat.

## Messen

```bash
mkctl gold status
mkctl gold candidates --limit 40
mkctl gold run [--no-ai]
```

Gelabelt wird in der App (Einstellungen › Messung). Ohne Labels verweigert `gold run`.

## Pflege

```bash
mkctl verify           # alle Mail-Dateien gegen ihre Prüfsumme; 1 bei Schaden
mkctl rebuild-index    # Index aus blobs + journal neu; 1 bei fehlenden Dateien
```

## Was nur die App kann

Gespeicherte Ansichten anlegen und löschen, Mails fürs Gold-Set labeln, Beziehungen bestätigen,
Regeln annehmen, „Ablage ändern“, „Art ändern“, „Kein Spam“/„Ist Spam“, das Abmelden sowie
alles rund um den Archiv-Papierkorb (löschen, wiederherstellen, leeren). `mkctl` zeigt
Vorschläge und Zustände, entscheidet aber nicht.

## Ein Beispiel: nächtliche Sicherung

```bash
#!/bin/zsh
export MAILKEEPER_ARCHIVE="$HOME/MailArchiv"
mkctl sync || exit 1
mkctl classify
mkctl embed
mkctl verify
```

Als LaunchAgent eingerichtet hält das ein Archiv aktuell, eingeordnet und geprüft — ohne dass
die App läuft.

## Weiter

- [Funktionsreferenz](../funktionen.md) mit allen Suchfeldern
- [Kapitel 1 — Das Archiv einrichten](01-archiv-einrichten.md)
