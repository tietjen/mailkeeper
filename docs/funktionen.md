# Funktionsreferenz

Jede Funktion nach Bereich: **wo** sie steckt, **was** sie tut, **wo ihre Grenze** ist. Zum
Nachschlagen — zum Lernen ist das [Handbuch](handbuch/) da.

- [Fenster und Ansichten](#fenster-und-ansichten)
- [Suchsprache](#suchsprache)
- [Mails ansehen](#mails-ansehen)
- [Aktionen](#aktionen)
- [KI](#ki)
- [Einstellungen](#einstellungen)
- [Tastenkürzel](#tastenkürzel)
- [Grenzen und feste Werte](#grenzen-und-feste-werte)

## Fenster und Ansichten

| Was | Wo | Grenze |
|---|---|---|
| **Seitenleiste** | links | „Spam-Prüfung“ erscheint nur, wenn ein Konto „Spam prüfen“ an hat oder dort etwas liegt. Ein Konto als Ganzes lässt sich nicht auswählen, nur seine Ordner. |
| **Nachrichtenliste** | Mitte | Spalten Datum, Von, Betreff, 📎, 💬, Größe; alle außer 📎/💬 sortierbar. Breiten und Sortierung werden gemerkt. |
| **Gruppenansicht** | Auswahlfeld *Ansicht* in der Symbolleiste | zeigt höchstens **2 000** Gruppen (die größten) |
| **Leser** | rechts | HTML in einer gesperrten Ansicht: kein JavaScript, keine Netzladungen; Bilder nur aus der Mail selbst |
| **Verlauf** | ⌘[ / ⌘] , Menü *Verlauf* | **50** Stationen; das Menü zeigt die letzten 15 |
| **Statusleiste** | unten | Fortschritt, unterbrochene Aufträge, Archivgröße, Pfad, Warnung bei unverschlüsseltem Laufwerk |
| **Archive wechseln** | Ablage, oder Klick auf den Fenstertitel | gesperrt, solange Abruf, Import oder Aktion läuft |

## Suchsprache

Dieselbe Sprache im Suchfeld, in Ansichten, Regeln, `mkctl` und in dem, was die KI übersetzt.
Groß- und Kleinschreibung spielt bei Feldnamen keine Rolle.

### Felder

| Feld (Synonyme) | Findet |
|---|---|
| `von:` `from:` | Name **und** Adresse des Absenders |
| `an:` `to:` `cc:` | Empfänger — To und Cc liegen in **einem** Feld |
| `betreff:` `subject:` | Betreff |
| `text:` `body:` | nur den Nachrichtentext |
| `absender:` `sender:` | **exakte** Adresse; `sender:@domain.de` die ganze Domain |
| `domain:` | **exakte** Absenderdomain, ohne Unterdomänen |
| `anhang:` `datei:` `filename:` | Dateiname eines Anhangs |
| `anhangtext:` `pdf:` | **nur** Text aus PDF-Anhängen |
| `hat:` `has:` | `anhang` · `pdf` · `bild` · `kalender` (auch englisch) |
| `größer:` `larger:` / `kleiner:` `smaller:` | Größe, echt größer/kleiner |
| `ab:` `seit:` `after:` | ab diesem Zeitpunkt (einschließlich) |
| `vor:` `before:` | davor |
| `bis:` `until:` | bis einschließlich Ende |
| `datum:` `date:` | genau dieser Zeitraum |
| `konto:` `account:` | Kürzel eines Kontos |
| `ordner:` `in:` `folder:` | die **Ablage im Archiv**; `in:Projekte*` als Präfix |
| `label:` | Gmail-Label |
| `liste:` `list:` | List-Id **enthält** |
| `listid:` | **exakte** List-Id |
| `art:` `kategorie:` `category:` | siehe unten |
| `ist:` `is:` | siehe unten |
| `auf:server` `on:server` | liegt auf einem Server |
| `nur:archiv` `only:archive` | nur noch im Archiv |
| `msgid:` `message-id:` | exakte Message-ID (Klammern optional) |
| `konversation:` `thread:` | die **ganze** Unterhaltung dieser Message-ID |

### `ist:` — alle Werte

| Wert (Synonyme) | Bedeutet |
|---|---|
| `ungelesen` `neu` `unread` / `gelesen` `read` | Gelesen-Zustand |
| `markiert` `wichtig` `flagged` `starred` | markiert |
| `beantwortet` `answered` `replied` | beantwortet |
| `liste` `list` `newsletter` | hat List-Id oder List-Unsubscribe |
| `gesendet` `versendet` `sent` | aus einem Gesendet-Ordner |
| `im-spam` `junk` `spamordner` | liegt **jetzt** in einem Spam-Ordner |
| `war-im-spam` `jemals-im-spam` `was-junk` | lag **irgendwann** dort |
| `fehlalarm` `kein-spam-laut-ki` `false-positive` | im Spam-Ordner, KI sagt harmlos, niemand hat entschieden |
| `phishing` `betrug` | Modell meldet Verdacht oder Gewissheit |
| `verdächtig` `verdacht` `suspicious` | Phishing, Modell-Spam oder gespeicherte Warnung — außer du hast widersprochen |

### `art:` — alle Werte

`newsletter` · `benachrichtigung` · `rechnung` · `bestellung` · `konto` · `persönlich` ·
`arbeit` · `reise` · `spam` — dazu `offen` für noch nicht Eingeordnetes.

Zusätzlich verstanden: `info`, `beleg`, `quittung`, `versand`, `lieferung`, `sicherheit`,
`privat`, `beruf`, `reisen`, `werbung` (→ Spam) und die englischen Formen.
**`art:phishing` landet bei Spam** — für Phishing ist `ist:phishing` gemeint.

### Operatoren und Werte

| | |
|---|---|
| Leerzeichen | UND (`UND`/`AND` darf man schreiben, ändert nichts) |
| `ODER` `OR` | Oder; UND bindet stärker |
| `-wort` `NICHT` `NOT` | Verneinung; ein `-` *mitten* im Wort zählt nicht |
| `( … )` | Klammern, bis **16** Ebenen |
| `"…"` | Wortgruppe; darin keine Feldnamen |
| `wort*` | Wortanfang — nur am **Ende** eines Wortes |
| Größen | `500`, `500K`, `5M`, `1,5G` — K/M/G sind 1024; mit Leerzeichen nur in Anführungszeichen (`größer:"2 MB"`) |
| Daten | `heute`, `gestern`, `30d`/`30t`, `6w`, `3m`, `1j`/`1y`, `2024`, `2024-03`, `2024-03-17`, `17.3.2024`; Jahr 1900–2999 |

`datum:` braucht einen Zeitraum — `datum:30d` ist ein Fehler, gemeint ist `vor:30d`.

**Tippfehler:** Ein unbekanntes Wort vor einem Doppelpunkt ist gewöhnlicher Suchtext
(`re:hallo`). Ein **bekanntes** Feld mit ungültigem Wert ist ein Fehler, und die Suche läuft
nicht — damit ein Vertipper eine Treffermenge nie vergrößert.

**Freier Text** sucht in Betreff, Absender, Empfänger, Text, Anhangsnamen und PDF-Text. `ß`=`ss`,
`ae`=`ä`, `oe`=`ö`, `ue`=`ü`. Die exakten Felder (`sender:`, `domain:`, `konto:`, `ordner:`,
`label:`, `listid:`) falten nur Groß/klein — dort bleibt `ö` ein `ö`.

**Letztes Wort = Wortanfang**, solange kein Leerzeichen folgt. Nicht bei Aktionen, die etwas
verändern.

> Die Vorschläge beim Tippen decken die gebräuchlichen Felder und Werte ab, aber nicht jedes
> Synonym: `cc:`, `thread:`, `message-id:`, `category:`, `seit:`, `since:`, `auf:`, `nur:` und
> `groesser:` funktionieren, werden aber nicht vorgeschlagen.

Grenzen: 4096 Zeichen, 64 Begriffe, 16 Klammerebenen.

### Ansichten

Gespeicherte Suchen in der Seitenleiste; liegen im Archiv (`saved-searches.json`, Rechte 0600).
Eine Ansicht und der getippte Text werden mit **UND** verbunden, der Text dabei eingeklammert.
Anlegen und Löschen geht nur in der App.

Die festen Einträge **Spam-Prüfung** (`is:junk`) und **Verdächtig**
(`is:verdächtig -is:war-im-spam`) im Bereich *Archiv* der Seitenleiste benutzen dieselbe
Sprache, sind aber keine gespeicherten Ansichten: nicht in der Datei, nicht editierbar.

## Mails ansehen

| Zeile im Leser | Zeigt | Grenze |
|---|---|---|
| **Ort** | „Server und Archiv“ / „Nur im Archiv“ / „Im Papierkorb“, mit Datum der endgültigen Löschung | Tatsache, nicht änderbar |
| **Art** | Kategorie, woher sie kommt, „Warum?“ | „Warum?“ nur bei einer Modellantwort |
| **Prüfung** | Phishing-Stufe, Spam laut KI, auffällige Links | erscheint auch ohne Modell, wenn Links auffallen |
| **Echtheit** | Beziehungsregister und das Urteil deines eigenen Servers | fremde Server zählen nicht |
| **Ablage** | wo das Archiv die Mail führt, „Ablage ändern …“ | bei Papierkorb-Mails ohne Aktion |
| **Abmelden** | Verfahren oder Sperrgrund | siehe Handbuch, Kapitel 6 |
| **Verlauf** | die Konversation | bis 8 Zeilen sichtbar, Zustand wird gemerkt |
| **Inhalt** | Zusammenfassung | nur bei aktiver KI |
| **Anhänge** | Chips mit Vorschau/Öffnen/Sichern | Programme, Skripte, Installer, Makro-Dokumente und Web-Inhalte werden **nie** geöffnet |

Jede Kopfzeile ist ein Menü: „Alle Mails mit …“, „Zur Suche hinzufügen“, „Ausschließen“,
„Kopieren“.

## Aktionen

Alle gehen über **Plan → Ausführen → Prüfen**, mit Protokoll in
`~/Library/Logs/MailKeeper/audit.jsonl`.

| Aktion | Start | Was sie tut | Grenze |
|---|---|---|---|
| **Auf dem Server löschen** | Bearbeiten, Kontextmenü, Gruppe | in den Papierkorb des Servers | Schonfrist (Standard 30 Tage); Archiv behält alles |
| **Aus dem Archiv löschen** | ⌘⌫ | in den Archiv-Papierkorb, 30 Tage | überspringt, was noch auf einem Server liegt |
| **Wiederherstellen** | Papierkorb, Leser | zurück aus dem Archiv-Papierkorb | ohne Plan und Rückfrage |
| **Endgültig löschen / Papierkorb leeren** | Papierkorb-Leiste | unwiderruflich | verlangt **Touch ID oder Passwort** |
| **Auf den Server zurückspielen** | Bearbeiten, Kontextmenü | lädt wieder hoch, prüft danach | nur Ordner, die das Konto abruft; Proton ~1,5 s je Mail |
| **Kein Spam** | Leser, Kontextmenü, Spam-Leiste | zurück, wo sie lag (sonst Posteingang) | nur aus Spam-Ordnern |
| **Ist Spam** | Kontextmenü; im Leser nur, wenn MailKeeper etwas bemerkt hat | in den Spam-Ordner | nie aus Gesendet, Entwürfen, Papierkorb, Spam |
| **Ablage ändern** | Leser, Kontextmenü | Ablage im Archiv, optional auch auf dem Server | legt nie Ordner an; bei Gmail nur im Archiv; nie aus Papierkorb, Gesendet, Entwürfen, „Alle Nachrichten“ |
| **Abmelden** | Leser, Gruppe | Ein-Klick (RFC 8058), Browser oder vorbereitete Mail | gesperrt bei Phishing, Doppelgänger, Spam, auffälligem Link, mehr als einer Abmelde-Angabe |
| **Exportieren** | ⇧⌘E | `.eml` je Mail oder eine mbox | überschreibt nie; prüft jede Mail vorher |
| **Importieren** | Ablage › Importieren, Symbolleiste | Maildir, mbox (auch Google Takeout), Ordner mit `.eml` | läuft ohne Plan; solange kein Archivwechsel |

Jede **Aktion** lässt sich anhalten (× in der Statusleiste) und fortsetzen; Fehlgeschlagenes
lässt sich erneut versuchen. **Abruf und Import** laufen dagegen zu Ende — beide arbeiten
inkrementell.

## KI

| Funktion | Wo | Braucht |
|---|---|---|
| Einordnen durch Regeln | läuft von selbst | nichts |
| Einordnen über ähnliche Mails | läuft mit `embed` | Endpunkt |
| Einordnen durch das Modell | Kontextmenü, Bearbeiten, nach dem Abruf | KI an |
| Phishing-Prüfung | nach dem Abruf, „Posteingang prüfen“ | KI an |
| „Warum?“ | Leser | eine Modellantwort |
| Zusammenfassen | ⌥⌘S / ⌥⇧⌘S | KI an |
| Alltagssprache übersetzen | ⌥⌘F | KI an |
| Nach Bedeutung suchen | Symbolleiste, `~ text` | **Endpunkt** |
| Ähnliche Mails | Leser | **Endpunkt** |
| Gold-Messung | Einstellungen › Messung | ohne KI nur „MailKeeper heute“ |

Grenzen: höchstens **500** Mails je KI-Lauf; nach einem Abruf **30** Kandidaten und **50** aus
Spam-Ordnern, und nur Mail der letzten **14 Tage**; Zusammenfassungen **50** je Sitzung, nie
gespeichert; eine Konversation deckt die neuesten **25** Nachrichten ab.

## Einstellungen

| Reiter | Inhalt |
|---|---|
| **Konten** | anlegen, prüfen, entfernen; „Spam prüfen“ je Konto (Standard **aus**); Google-Anmeldung umstellen und zurück |
| **KI** | an/aus (Standard **aus**), Endpunkt, Schlüssel, Modell je Aufgabe, Modell auf diesem Mac (Standard **an**), Verbindungstest |
| **Gedächtnis** | Notizen, Begriffe, Beispiele ansehen, schreiben, vergessen; Export/Import als JSON |
| **Beziehungen** | bestätigt / Vorschläge / abgelehnt; öffentliche Adressen |
| **Regeln** | Suche + Aktion; Vorschläge aus Wiederholungen |
| **Messung** | Gold-Set labeln und messen |

Das Zeitlimit für KI-Anfragen (120 s) steht nur in `ai.json`, nicht in der Oberfläche.

## Tastenkürzel

| | |
|---|---|
| ⇧⌘O / ⌘, | Archiv öffnen / Einstellungen |
| ⌘R / ⇧⌘R | Aktualisieren / Neue Mails abrufen |
| ⌘⌫ | Aus dem Archiv löschen |
| ⇧⌘E | Auswahl exportieren |
| ⌥⌘F | Suchtext in Suchsprache übersetzen |
| ⌥⌘S / ⌥⇧⌘S | Mail / Konversation zusammenfassen |
| ⌘[ / ⌘] | Verlauf zurück / vor |
| ⌘L | Mails labeln (Einstellungen › Messung) |
| 1–9 · P · 0 · ← · esc | im Label-Blatt: Art · Phishing · weiß nicht · zurück · fertig |

## Grenzen und feste Werte

| | |
|---|---|
| Archiv-Papierkorb | 30 Tage |
| Schonfrist Server-Löschung | 30 Tage (0–3650 einstellbar) |
| KI-Lauf | 500 Mails |
| Prüfung nach dem Abruf | 14 Tage, 30 Mails, 50 aus Spam-Ordnern |
| Zusammenfassungen | 50 je Sitzung, Konversation 25 Nachrichten |
| Gruppenansicht | 2 000 Gruppen |
| Verlauf | 50 Stationen (das Menü zeigt 15) |
| Suche | 4096 Zeichen, 64 Begriffe, 16 Klammerebenen |
| Notizen | 500 Zeichen |
| KI-Zeitlimit | 120 s |

## Was es (noch) nicht gibt

- **Mails schreiben oder senden.** MailKeeper ist ein Archiv.
- **Phishing melden** — vorgesehen, braucht einen Sendeweg.
- **Ordner auf dem Server anlegen** — mit Absicht nie.
- **Ablage auf dem Server bei Gmail** — dort sind Ordner Labels.
- **Einbettungen auf dem Mac-Modell** — anderer Vektorraum.
- **Gedächtnis zusammenfassen („Konsolidierung“)** — vorgesehen, noch nicht nötig.
