# Abrufen und durchsuchen

## Abrufen

**Abrufen** in der Symbolleiste holt neue Mail aus allen eingerichteten Konten, eines nach dem
anderen. Der erste Lauf dauert, je nach Postfach: Er lädt alles. Danach wird nur geholt, was
dazugekommen ist.

Was dabei passiert, zeigt die Fortschrittszeile je Postfach: wie viele neue Mails, wie viele
Flags abgeglichen, wie viele nicht mehr auf dem Server sind. **Abbrechen ist jederzeit möglich**
— der nächste Lauf macht dort weiter.

Verschwundene Mails werden als *nicht mehr auf dem Server* vermerkt, **nicht gelöscht**. Sie
bleiben im Archiv und in der Suche; im Leser steht dann „nur im Archiv“.

Auf der Kommandozeile dasselbe:

```bash
mkctl --archive ~/MailKeeperArchive sync            # alle Konten
mkctl --archive ~/MailKeeperArchive sync gmail      # nur eines
```

Nach jedem Abruf laufen die Einordnungsregeln über die neue Post, und ein kleiner Teil geht zur
Prüfung an ein Modell (siehe [Kapitel 5](05-mails-einordnen.md) und
[Kapitel 6](06-spam-und-phishing.md)).

## Suchen

Ins Suchfeld tippen genügt. Gesucht wird in **Betreff, Absender, Empfänger, Text, Namen von
Anhängen** — und im **Text von PDF-Anhängen**, falls der schon gewonnen wurde.

### Beim Tippen

Das **letzte Wort gilt als Anfang eines Wortes**, solange du noch kein Leerzeichen getippt hast:
`rechnung amaz` findet „Amazon“. Tippst du ein Leerzeichen dahinter, ist `amaz` gemeint und
sonst nichts.

Für Aktionen, die etwas verändern, gilt das **nicht** — dort zählt immer das genaue Wort. Ein
Tippfehler darf nie mehr Mails treffen, als du meinst.

### Umlaute, ß und Großschreibung

Groß- und Kleinschreibung spielt keine Rolle. Darüber hinaus:

- **`ß` und `ss`** sind dasselbe: `Grüße` findet „Grüsse“.
- **`ae`/`oe`/`ue` und `ä`/`ö`/`ü`** sind dasselbe: `mueller` findet „Müller“, `Müller` findet
  „Mueller“.
- Bei den **exakten** Feldern (`sender:`, `domain:`, `konto:`, `ordner:`, `label:`, `listid:`)
  zählt nur Groß/klein — ein `ö` bleibt dort ein `ö`.

### Wortgruppen, Platzhalter, Verneinung

| Schreibweise | Bedeutung |
|---|---|
| `rechnung amazon` | **beides** muss vorkommen |
| `"offene rechnung"` | genau diese Wortfolge |
| `rechn*` | Wortanfang (nur am Ende eines Wortes) |
| `-werbung` oder `NICHT werbung` | ohne dieses Wort |
| `a ODER b` | eines von beiden (`UND` bindet stärker) |
| `-(werbung angebot)` | keines von beiden |

`e-mail` bleibt ein Wort — ein Bindestrich *mitten* im Wort ist kein Minus.

### Die Felder

Alles lässt sich auf ein Feld einschränken. Deutsch und Englisch sind gleichwertig.

**Wer und was**

| Feld | Findet |
|---|---|
| `von:` `from:` | Name **und** Adresse des Absenders |
| `an:` `to:` `cc:` | Empfänger (To **und** Cc zusammen) |
| `betreff:` `subject:` | nur im Betreff |
| `text:` `body:` | nur im Nachrichtentext |
| `absender:` `sender:` | **exakte** Adresse — `sender:@firma.de` nimmt die ganze Domain |
| `domain:` | **exakte** Absenderdomain, ohne Unterdomänen |

**Anhänge**

| Feld | Findet |
|---|---|
| `anhang:` `datei:` `filename:` | Dateiname eines Anhangs |
| `anhangtext:` `pdf:` | **nur** im Text von PDF-Anhängen |
| `hat:anhang` · `hat:pdf` · `hat:bild` · `hat:kalender` | Mails mit so einem Anhang |

**Wann und wie groß**

| Feld | Beispiele |
|---|---|
| `ab:` `seit:` `after:` | `ab:2024-03`, `ab:30d`, `ab:heute` |
| `vor:` `before:` | `vor:2024`, `vor:1j` |
| `bis:` `until:` | `bis:2024-03-17` (einschließlich) |
| `datum:` `date:` | `datum:2024`, `datum:17.3.2024` — ein Zeitraum, keine Angabe wie `30d` |
| `größer:` `larger:` | `größer:5M` |
| `kleiner:` `smaller:` | `kleiner:100K` |

Datumsformen: `heute`, `gestern`, `30d` (Tage, auch `t`), `6w`, `3m`, `1j` (auch `y`), `2024`,
`2024-03`, `2024-03-17`, `17.3.2024`. Größen: `500`, `500K`, `5M`, `1,5G` — K/M/G sind 1024.

**Wo**

| Feld | Findet |
|---|---|
| `konto:` `account:` | das Kürzel eines Kontos |
| `ordner:` `in:` `folder:` | die **Ablage im Archiv** — `in:Projekte*` geht auch |
| `label:` | Gmail-Label |
| `liste:` `list:` | List-Id enthält diesen Text |
| `listid:` | **exakte** List-Id |
| `auf:server` | liegt (noch) auf einem Server |
| `nur:archiv` | liegt nur noch im Archiv |

**Zustand**

| Schreibweise | Bedeutet |
|---|---|
| `ist:ungelesen` · `ist:gelesen` | Gelesen-Zustand |
| `ist:markiert` | markiert/mit Stern |
| `ist:beantwortet` | beantwortet |
| `ist:liste` | Newsletter oder Mailingliste |
| `ist:gesendet` | aus einem Gesendet-Ordner |
| `ist:im-spam` · `ist:junk` | liegt **jetzt** in einem Spam-Ordner |
| `ist:war-im-spam` | lag **irgendwann** in einem |
| `ist:fehlalarm` | im Spam-Ordner, aber die KI hält sie für harmlos und niemand hat entschieden |
| `ist:phishing` · `ist:betrug` | die KI meldet Verdacht oder Gewissheit |
| `ist:verdächtig` | Phishing, Modell-Spam oder eine Warnung — außer du hast widersprochen |

**Art**

`art:newsletter` · `benachrichtigung` · `rechnung` · `bestellung` · `konto` · `persönlich` ·
`arbeit` · `reise` · `spam` — und `art:offen` für noch nicht Eingeordnetes. `kategorie:` und
`category:` sind dasselbe Feld.

> Achtung: `art:phishing` gibt es nicht als eigene Art — das Wort landet bei **Spam**. Für
> Phishing ist `ist:phishing` gemeint.

**Einzelne Mails**

`msgid:<…>` findet eine Mail über ihre Message-ID, `konversation:<…>` die **ganze Unterhaltung**
dazu. Spitze Klammern darfst du weglassen.

### Was ein Tippfehler bewirkt

Zwei Fälle, mit Absicht verschieden:

- **Unbekanntes Wort vor einem Doppelpunkt** = gewöhnlicher Suchtext. `re:hallo` sucht nach
  „re:hallo“, `https://x.de` nach dem Link.
- **Bekanntes Feld mit ungültigem Wert** = Fehler, und die Suche läuft **nicht**. `hat:video`
  sagt dir, dass es nur `attachment`, `pdf`, `image` oder `calendar` gibt — die deutschen
  Wörter `anhang`, `bild` und `kalender` versteht es genauso.

Der Grund für die Strenge: Auf einer Treffermenge wird manchmal gelöscht. Ein Tippfehler darf
sie nie *größer* machen.

Grenzen: 4096 Zeichen, 64 Begriffe, 16 Klammerebenen.

### Begriffe als Chips

Über dem Ergebnis steht jeder Teil der Suche als Chip mit deutscher Beschriftung — „Von:
amazon“, „mit PDF“, „nicht gelesen“. Enthält die Suche ein `ODER` auf oberster Ebene, wird die
ganze Suche **ein** Chip, denn einzeln wegzunehmen ergäbe etwas anderes.

> Die Vorschlagsliste beim Tippen kennt nicht alles: `kategorie:`, `konversation:`, `msgid:`,
> die deutschen Feldnamen und die meisten `ist:`-Werte funktionieren, werden aber nicht
> vorgeschlagen. Die Sprache kann mehr, als die Vervollständigung zeigt.

## Ansichten speichern

Eine Suche, die du öfter brauchst, speicherst du als **Ansicht**; sie erscheint in der
Seitenleiste. Ansichten liegen im Archiv (`saved-searches.json`), weil ihre Abfragen dessen
Konten und Ordner nennen.

Wählst du eine Ansicht aus und tippst dann ins Suchfeld, wird **beides mit UND verbunden** —
der getippte Teil wird dabei eingeklammert, damit aus `a ODER b` nicht versehentlich etwas
anderes wird.

Zwei Ansichten bringt MailKeeper mit: **Spam-Durchsicht** (`is:junk`) und **Verdächtig**
(`is:verdächtig -is:war-im-spam`).

## Gruppieren

Die Gruppenansicht fasst nach **Absender**, **Domain** oder **Liste** zusammen — mit Anzahl,
Größe und Anteil ungelesener Mails. Das ist der schnellste Weg zu der Frage „wer schickt mir
eigentlich die ganze Post?“ und der Einstieg ins Aufräumen
([Kapitel 7](07-aufraeumen.md)).

```bash
mkctl --archive ~/MailKeeperArchive groups --by domain --limit 20
```

## Weiter

- [Kapitel 7 — Postfächer aufräumen](07-aufraeumen.md)
- [Kapitel 8 — Nach Bedeutung suchen](08-bedeutung-und-zusammenfassung.md)
- Alle Felder auf einen Blick: [Funktionsreferenz](../funktionen.md)
