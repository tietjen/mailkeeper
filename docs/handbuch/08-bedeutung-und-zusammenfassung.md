# Nach Bedeutung suchen und zusammenfassen

Zwei Funktionen, die einen eingerichteten KI-Endpunkt brauchen
([Kapitel 4](04-ki-einrichten.md)). Das Modell auf dem Mac reicht hier **nicht**: Beides setzt
Vektoren voraus, und die kann es nicht erzeugen.

## Nach Bedeutung suchen

Die gewöhnliche Suche findet Wörter. Die Bedeutungssuche findet Mails, die *von etwas handeln*
— auch wenn kein Wort davon vorkommt.

Du startest sie mit **„Nach Bedeutung suchen“** in der Symbolleiste oder indem du der Suche ein
**`~`** voranstellst:

```
~ Streit mit dem Vermieter wegen der Nebenkosten
```

Darüber erscheint eine Leiste „Nach Bedeutung: …“, und die Treffer stehen nach Ähnlichkeit
sortiert (bis zu 200). Klickst du auf eine Spaltenüberschrift, wird normal sortiert; **„Ähnlichste
zuerst“** bringt die Reihenfolge zurück.

### Ähnliche Mails

Im Leser neben der Art: **„Ähnliche Mails“** nimmt die geöffnete Mail als Frage und zeigt bis zu
100 verwandte. Praktisch, wenn du einen Vorgang zusammensuchst, dessen Betreff sich unterwegs
geändert hat.

### Vorbereiten

Beides braucht einen Vektor je Mail. MailKeeper rechnet sie im Hintergrund; die Statusleiste
zeigt **„Bedeutungssuche vorbereiten: x von y“**. Auf der Kommandozeile:

```bash
mkctl --archive ~/MeinArchiv embed
```

Berechnet wird aus Betreff, Absender, Anhangsnamen und einem Auszug — **Indexdaten; keine Mail
wird dafür gelesen.** Fehlt ein Vektor, sagt MailKeeper das („Für diese Mail gibt es noch keinen
Vektor – die Embeddings laufen im Hintergrund“).

Nebenbei ordnet der Lauf offene Mails über ihre Nachbarn ein — Stufe 2 aus
[Kapitel 5](05-mails-einordnen.md).

## Suchen in Alltagssprache

Etwas anderes als die Bedeutungssuche: Hier **übersetzt** das Modell deinen Satz in die
Suchsprache, und die Suche selbst läuft ganz normal.

Schreib, was du meinst, und drücke **⌥⌘F** (oder den Knopf in der Symbolleiste):

```
rechnungen vom letzten jahr mit pdf
        ↓
kategorie:rechnung ab:1j hat:pdf
```

Über der Liste steht dann, was du eingegeben hattest, dazu die Erklärung des Modells und welches
Modell es war. **„Zurück“** stellt deinen Text wieder her.

Der Vorteil gegenüber der Bedeutungssuche: Du **siehst**, wonach gesucht wird, und kannst die
Abfrage korrigieren. Deine eigenen Begriffe aus dem Gedächtnis fließen mit ein — hast du
hinterlegt, dass „Firma“ das Proton-Konto meint, wird daraus `konto:proton`.

```bash
mkctl --archive ~/MeinArchiv ask rechnungen vom letzten jahr mit pdf
```

(Das zählt nur die Treffer; ausgeführt wird die Suche nicht.)

## Zusammenfassen

Im Leser unter **„Inhalt“**:

- **„Zusammenfassen“** (⌥⌘S) für eine Mail,
- **„Konversation zusammenfassen“** (⌥⇧⌘S) für den ganzen Verlauf — die neuesten 25
  Nachrichten, älteste zuerst, Zitate herausgerechnet.

Heraus kommen zwei bis fünf Sätze, bis zu sechs Fakten und bis zu drei Aufgaben, dazu die
Fußzeile mit Modell, Dauer und wie viele Nachrichten gelesen wurden.

**Ist die Mail ein Betrugsversuch, bleiben die Aufgaben leer** — und oben steht eine Warnung.
Was eine Betrugsmail von dir verlangt, ist keine Aufgabe. Das gilt auch, wenn MailKeeper selbst
Phishing festgestellt hat.

> **Zusammenfassungen werden nie gespeichert.** Sie leben nur in dieser Sitzung (höchstens 50)
> und landen nicht im Index. Kopieren kannst du sie.

```bash
mkctl --archive ~/MeinArchiv summarize 12345
mkctl --archive ~/MeinArchiv summarize 12345 --thread
```

## Weiter

- [Kapitel 9 — Sicherheit und Datenschutz](09-sicherheit-und-datenschutz.md)
- [Kapitel 10 — Die Kommandozeile](10-kommandozeile.md)
