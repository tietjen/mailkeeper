# Die KI-Funktionen einrichten

MailKeeper kann ohne KI alles, was ein Archiv können muss: abrufen, suchen, aufräumen,
zurückspielen. Die KI kommt dort dazu, wo Regeln nicht weiterkommen — beim Einordnen, beim
Erkennen von Phishing, beim Zusammenfassen und beim Suchen in Alltagssprache.

Dieses Kapitel erklärt, **was eingerichtet wird, was dabei wohin geht und was nicht.**

## Was deinen Mac verlässt

Die kürzeste Antwort: **Es gibt keinen Cloud-Anbieter.** MailKeeper bringt keine Voreinstellung
auf OpenAI, Anthropic oder Google mit, und es gibt keinen Schalter dafür. Mails sind persönliche
Daten; sie gehen an **dein** Modell oder an gar keins.

Du hast zwei Wege, und MailKeeper nutzt beide:

| | Wohin | Was dafür spricht |
|---|---|---|
| **Endpunkt** | ein OpenAI-kompatibler Dienst, den du betreibst — LiteLLM, Ollama, LM Studio | bessere Antworten, Einbettungen, schnell bei vielen Mails |
| **Dieser Mac** | Apple Foundation Models, auf dem Gerät | läuft offline, nichts verlässt den Mac, dafür kleineres Modell |

Läuft der Endpunkt auf einem anderen Rechner — deinem Server im Keller, einem Mac im
Arbeitszimmer —, verlassen die Anfragen diesen Mac und gehen dorthin. Steht er im Internet,
warnt MailKeeper. Wählst du nur „dieser Mac“, bleibt alles hier.

**Was in einer Anfrage steht:** Betreff, Absender, einige Kopfzeilen, die **Namen** der Anhänge,
die Link-Befunde und ein begrenzter Auszug des Textes — bei Zusammenfassungen mehr (bis 24 000
Zeichen am Endpunkt, kompakte 5 000 für das Mac-Modell). Beim Einordnen kommen die Dinge dazu,
die MailKeeper selbst weiß: deine Notizen, passende Beispiele, das Absenderprofil und das
Ergebnis der Echtheitsprüfung. **Der Inhalt von Anhängen geht nie mit.**

**Was protokolliert wird:** `~/Library/Logs/MailKeeper/ai.jsonl` hält fest, *dass* eine Anfrage
lief — Aufgabe, Weg, Modell, Sekunden, Tokens, Ergebnis. **Nie der Prompt und nie die Antwort.**

## Einen Endpunkt einrichten

Alles unter **Einstellungen › KI**. Die Einstellungen gehören zum Archiv (`ai.json`), der
Schlüssel liegt im Schlüsselbund.

| Feld | Bedeutung |
|---|---|
| **KI-Funktionen verwenden** | ohne Haken fragt MailKeeper nie ein Modell |
| **Adresse** | Basis-Adresse der OpenAI-kompatiblen Schnittstelle, z. B. `http://127.0.0.1:11434/v1` |
| **API-Schlüssel** | falls dein Dienst einen verlangt (LiteLLM: Virtual Key); landet im Schlüsselbund |
| **Modell je Aufgabe** | vier Felder: Suche in Alltagssprache, Einordnen, Zusammenfassen, Embeddings; leer = `llm-fast`, für Embeddings `embedding` |
| **Modell auf diesem Mac verwenden, wenn der Endpoint fehlt oder nicht antwortet** | Apples Modell als Ausweichweg |

Das Zeitlimit je Anfrage (120 Sekunden) steht nicht in der Oberfläche, sondern in `ai.json`.

Es gibt fünf Aufgaben mit eigenem Modell-Alias: **search** (Alltagssprache → Suchanfrage),
**classify** (Art einer Mail), **summarize** (Zusammenfassung), **embed** (Vektoren für die
Bedeutungssuche) und **test** (Verbindungstest).

### Mit Ollama

```bash
ollama serve
ollama pull qwen2.5:14b-instruct
ollama pull nomic-embed-text
```

- Endpunkt: `http://127.0.0.1:11434/v1`
- Schlüssel: leer
- Modell für *classify*/*summarize*/*search*: `qwen2.5:14b-instruct`
- Modell für *embed*: `nomic-embed-text`

### Mit LM Studio

Server starten (Standardport 1234), ein Instruct-Modell und ein Embedding-Modell laden.

- Endpunkt: `http://127.0.0.1:1234/v1`
- Schlüssel: leer
- Modelle: die Namen, die LM Studio anzeigt

### Mit LiteLLM

LiteLLM ist ein Gateway vor mehreren Modellen und vergibt Aliasse. Endpunkt ist die Basis-URL
mit `/v1`, der Schlüssel ein Virtual Key, die Modellnamen sind deine Aliasse (etwa `llm-fast`).

> **HTTP statt HTTPS** erlaubt MailKeeper nur für `localhost`, `127.0.0.1`, `::1`,
> `*.localhost` und `*.ziti`. Das ist MailKeepers eigene Prüfung beim Sichern — Apples
> Transportsicherheit wäre großzügiger und ließe auch Klartext ins lokale Netz. Alles andere
> braucht HTTPS.

Zum Schluss **Verbindung testen**. Der Test sagt, welcher Weg geantwortet hat.

## Nur dieser Mac

Ohne Endpunkt reicht **Auf diesem Mac**. Apples Modell läuft auf dem Gerät, ist deutlich
kleiner und entsprechend schwächer — in der Messung gegen ein Gold-Set aus 32 Mails:

| | Art richtig | Phishing erkannt | Fehlalarme | Dauer |
|---|---|---|---|---|
| Endpunkt (`llm-fast`) | 30 von 32 | 7 von 7 | 0 | 158 s |
| Dieser Mac | 27 von 32 | 4 von 7 | 1 | 63 s |

Zählt man Art **und** Phishing zusammen als richtig, sind es 30 gegenüber 25 von 32.

Das Mac-Modell ist mehr als doppelt so schnell und trifft die Art fast genauso oft; beim
Phishing lässt es gut die Hälfte durch. Genau dafür ist es die Rückfallebene und nicht die
erste Wahl. **Für Einbettungen taugt es nicht** — die Bedeutungssuche und
die Stufe „ähnliche Mails“ brauchen einen Endpunkt.

## Wie MailKeeper zwischen beiden wählt

```
Anfrage
   ↓
Endpunkt eingerichtet und erreichbar?
   ├── ja  → Endpunkt antwortet
   ├── nein / 502-504 / stumm nach dem Zeitlimit
   │        → dieser Mac (wenn erlaubt), Endpunkt pausiert eine Minute
   └── Endpunkt antwortet FALSCH (4xx, kaputtes JSON, abgeschnitten)
            → Fehler. Kein stilles Ausweichen.
```

Der letzte Zweig ist Absicht: Ist der Endpunkt **weg**, wird ausgewichen. Antwortet er
**falsch**, siehst du einen Fehler — sonst würde eine schlechtere Antwort eine kaputte
Einrichtung verdecken, und du würdest dich über schlechte Einordnungen wundern, ohne den Grund
zu sehen.

Verbindungsfehler und 429/502/503 bekommen einen zweiten Versuch. Ein **Zeitlimit nie** — das
Gateway rechnet dann ja weiter, und ein zweiter Auftrag machte es nur langsamer.

An jeder Einordnung steht, welcher Weg sie erzeugt hat.

## Die Bedeutungssuche vorbereiten

Mit einem Endpunkt mit Embedding-Modell kannst du nach **Bedeutung** suchen statt nach Wörtern.
Dafür braucht jede Mail einen Vektor:

```bash
mkctl --archive ~/MailKeeperArchive embed
```

Berechnet werden sie aus Betreff, Absender, Anhangsnamen und einem Auszug — **Indexdaten, keine
Mail wird dafür gelesen.** Die Vektoren liegen im Index und sind, wie alles dort, neu baubar.

Danach gibt es **„Ähnliche Mails“** am Leser und die Suche mit `~` (siehe
[Kapitel 8](08-bedeutung-und-zusammenfassung.md)).

## Was die KI nie darf

Die Grenze ist nicht Geschmackssache, sondern eingebaut:

- **Kein Modell löst eine Aktion aus.** Kein Löschen, kein Verschieben, kein Abmelden. Was
  passiert, passiert durch deinen Klick.
- **Kein Modell gibt etwas frei.** Es gibt keine Stelle, an der eine Modellantwort eine
  Sicherheitsprüfung ersetzt.
- **Modellsignale dürfen nur strenger machen** — warnen, nachfragen, vorschlagen. Nie lockerer.
- **Mailinhalt ist eingezäunt.** Was aus der Mail stammt, steht in einem Block mit einer bei
  jeder Anfrage zufälligen Markierung, damit eine Mail ihn nicht nachbauen kann. Aufforderungen
  im Mailtext werden vorher entfernt und zählen als Warnzeichen.
- **Antworten müssen einem Schema genügen.** Kein Freitext, wo eine Auswahl reicht.

## Prüfen, ob es etwas taugt

MailKeeper bringt einen **Gold-Lauf** mit: eine Menge Mails mit bekannter richtiger Antwort.
Unter Einstellungen › **Messung** labelst du Mails selbst, und ein Lauf misst, wie gut die aktuelle
Einrichtung sie trifft — richtige Art, erkanntes Phishing, Fehlalarme, Dauer.

Das lohnt sich nach jedem Wechsel des Modells oder des Endpunkts. Ein Prompt, der sich für ein
Modell gut anfühlt, kann für ein anderes schlechter sein; gemessen weißt du es.

```bash
mkctl --archive ~/MailKeeperArchive gold status
mkctl --archive ~/MailKeeperArchive gold run
```

## Weiter

- [Kapitel 5 — Mails einordnen](05-mails-einordnen.md)
- [Kapitel 6 — Spam und Phishing](06-spam-und-phishing.md)
- Hintergrund: [ADR-0004](../adr/0004-llm-routing.md)
