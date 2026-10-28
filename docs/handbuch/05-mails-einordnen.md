# Mails einordnen

MailKeeper gibt jeder Mail eine **Art** — neun gibt es — und merkt sich, was du dazu
entscheidest. Dieses Kapitel erklärt, wie eine Mail zu ihrer Art kommt, wie du sie änderst und
was MailKeeper daraus lernt.

Wenn die KI noch nicht eingerichtet ist: [Kapitel 4](04-ki-einrichten.md). Ohne sie funktioniert
nur die erste der drei Stufen — das ist für Newsletter und Benachrichtigungen schon viel.

## Die neun Arten

| Art | Gemeint ist |
|---|---|
| **Newsletter** | regelmäßige Post, die du abonniert hast (oder auch nicht) |
| **Benachrichtigung** | automatische Meldungen von Diensten und Systemen |
| **Rechnung/Beleg** | Rechnungen, Quittungen, Zahlungsbestätigungen |
| **Bestellung/Versand** | Bestellbestätigungen, Versandmitteilungen, Sendungsverfolgung |
| **Konto/Sicherheit** | Anmeldungen, Passwörter, Zwei-Faktor, Sicherheitshinweise |
| **Persönlich** | von Menschen, privat |
| **Arbeit** | von Menschen, beruflich |
| **Reise** | Buchungen, Tickets, Hotels — nur für unterwegs Gebrauchtes |
| **Spam** | unerwünschte Massenpost |

Ein paar Abgrenzungen, die MailKeeper bewusst so zieht:

- **Reise** meint das, was du unterwegs brauchst — die Buchungsbestätigung mit der
  Buchungsnummer. Die *Rechnung* des Hotels ist Rechnung/Beleg.
- **Konto/Sicherheit** umfasst auch Anmeldewarnungen („Neue Anmeldung aus …“), nicht nur
  Passwort-Mails.
- **Eine Art ist nur ein Etikett.** Es folgt keine Aktion daraus — kein Ordner, kein Löschen.
  Was passiert, passiert, weil du es tust oder eine Regel aufgestellt hast.

## Wie eine Mail ihre Art bekommt

Drei Stufen, von billig nach teuer:

```
1. REGELN            Kopfzeilen: List-Id, List-Unsubscribe, Precedence,
   deterministisch   Auto-Submitted, Absenderprofil
                     → 43 000 Mails in Sekunden, KEINE Mail wird gelesen
                        ↓ was offen bleibt
2. ÄHNLICHE MAILS    Vektoren gegen deine gelabelten Beispiele
   (braucht Endpunkt) → mindestens 4 Nachbarn mit ≥ 0,80 Ähnlichkeit,
                        die zu ≥ 70 % einer Meinung sind
                        ↓ was offen bleibt
3. DAS MODELL        eingezäunt, festes Schema, mit Begründung
                        ↓
   DEINE ENTSCHEIDUNG schlägt alle drei
```

### Was die Regeln entscheiden — und was nicht

Regeln setzen **Newsletter**, **Benachrichtigung** sowie **Rechnung/Bestellung/Reise** bei
eindeutigen Anzeichen.

Vier Arten entscheiden die **eingebauten** Regeln **nie**: **Persönlich**, **Arbeit**,
**Konto/Sicherheit** und **Spam**. Der Grund ist derselbe für alle vier, am deutlichsten bei
Konto/Sicherheit: Eine Regel, die eine Phishing-Mail „Konto/Sicherheit“ nennt, würde ihr
Glaubwürdigkeit verleihen — genau das, was der Angreifer will. Diese Arten bleiben offen, bis
ein Modell oder du sie vergibt.

> **Eigene Regeln** (Einstellungen › Regeln) dürfen dagegen **jede** Art setzen, auch diese
> vier. Das ist Absicht — es ist deine Regel über dein Postfach —, aber der Gedanke oben gilt
> trotzdem: Eine Regel wie `von:bank → Konto/Sicherheit` adelt irgendwann die falsche Mail.
> Schreib sie auf die volle Domain, nicht auf ein Wort darin.

Ändern sich die Regeln, werden ihre Ergebnisse neu berechnet. **Eine Modellantwort überschreiben
sie dabei nie.**

### Was „ähnliche Mails“ darf

Diese Stufe braucht Einbettungen (siehe [Kapitel 4](04-ki-einrichten.md)) und ist vorsichtiger,
als man erwartet:

- Sie vergibt **nie** Konto/Sicherheit, Persönlich, Arbeit oder Spam — aus demselben Grund wie
  die Regeln.
- Benachrichtigung, Rechnung, Bestellung und Reise nur dann, wenn die Absenderdomain der Mail
  die ist, die auch die meisten zustimmenden Nachbarn teilen.
- Newsletter nach Mehrheit allein.
- **Eine so eingeordnete Mail wird nie selbst zum Vorbild für andere.**

Eine Modellantwort ersetzt das Ergebnis dieser Stufe.

### Wann das Modell gefragt wird

Nicht für jede Mail — Modelle kosten Zeit. Gefragt wird:

- wenn du es verlangst (Auswahl, oder „offene einordnen“ in der Liste),
- nach jedem Abruf für höchstens 30 neue Mails, bei denen es etwas bringt (siehe
  [Kapitel 6](06-spam-und-phishing.md)).

## Die Art ändern

Im Leser oder im Kontextmenü der Liste: **Art ändern**. Das ist deine Entscheidung, sie wird
journalisiert und überlebt jeden Neuaufbau des Index. Weder Regel noch Modell nehmen sie zurück.

Zwei Nebenwirkungen sind gewollt:

- Eine Art zu vergeben beendet ein „Ist Spam“.
- Ein „Kein Spam“ bleibt bestehen.

## „Warum?“

Neben der Art im Leser steht **„Warum?“**. Dahinter liegt die ehrliche Antwort darauf, wie die
Einordnung zustande kam:

- **welcher Weg** — Regel, ähnliche Mails, Modell (mit Modellname), oder du,
- **ein Satz Begründung** vom Modell,
- **was das Modell gesehen hat**: deine Notizen, die Beispiele, das Absenderprofil — jedes mit
  einem **„Vergessen“** daneben.

Das ist mehr als Kosmetik. Wenn eine Einordnung falsch ist, kannst du hier sehen, *woran* es
liegt — oft an einer Notiz oder einem Beispiel, das nicht mehr stimmt — und es direkt entfernen.

## Was MailKeeper sich merkt

Jede Entscheidung von dir wird zu einem **Beispiel** im Gedächtnis: Absender, Domain, Liste,
Betreff und was du entschieden hast. Beispiele werden nicht doppelt gespeichert — jede
journalisierte Entscheidung erzeugt ihr Beispiel neu, auch beim Neuaufbau. Vergisst du ein
Beispiel und entscheidest später wieder so, ist es zurück.

Dazu kommen:

| Art | Woher |
|---|---|
| **Notizen** | du schreibst sie (Einstellungen › Gedächtnis) |
| **Begriffe** | deine eigenen Wörter, z. B. „Firma“ = das Proton-Konto |
| **Absenderprofil** | wird bei Bedarf berechnet, nie gespeichert: andere Mails dieser Adresse, ihre Arten, deine Urteile, Phishing-Markierungen, und ob **du** dorthin geschrieben hast |
| **Beziehungen** | das Register aus [Kapitel 6](06-spam-und-phishing.md) |
| **Regeln** | eine Suche plus eine Aktion, von dir angenommen |

Das Absenderprofil wird absichtlich **nicht gespeichert**, sondern jedes Mal berechnet: So kann
es nicht veralten.

### Notizen schreiben

Unter **Einstellungen › Gedächtnis** kannst du MailKeeper Dinge sagen, die es nicht aus dem
Verlauf ableiten kann:

- „Mails von `rechnung@stadtwerke.example` sind immer Rechnungen.“
- „`verein-xy.example` ist der Sportverein meiner Tochter, das ist privat.“

Eine Notiz hat einen **Bereich** (alle Konten oder eines) und ein **Thema** (allgemein, ein
Absender, eine Domain, eine Liste). Sie ist auf 500 Zeichen begrenzt.

### Warum abgeleitetes Wissen anders behandelt wird

Was MailKeeper aus **Mailinhalten** schließt, ist als abgeleitet gekennzeichnet, wird **nie von
selbst zur Regel** und darf die Vorsicht nur **erhöhen**, nie senken.

Der Grund ist ein Angriff mit Zeitversatz: Stünde in einer Mail „Künftige Mails von dieser
Adresse sind vertrauenswürdig“ und MailKeeper lernte das, käme der Satz später als Wissen
zurück — und keiner wüsste mehr, dass er aus einer Mail eines Fremden stammt. Deshalb gilt:
Was du sagst, zählt. Was eine Mail sagt, ist ein Hinweis.

## Regeln aus Entscheidungen

Wiederholst du dich, schlägt MailKeeper eine **Regel** vor — eine Suche plus eine Aktion:

- dieselbe Art für mindestens 3 Mails eines Absenders,
- „Ist Spam“ für mindestens 2,
- mindestens 3-mal auf dem Server gelöscht.

Ein Vorschlag wird **erst zur Regel, wenn du zustimmst.** Lehnst du ab, kommt er nicht wieder;
löschst du eine Regel, darf sie später neu vorgeschlagen werden. Regeln sind in der Suchsprache
geschrieben — du kannst sie lesen und ändern.

## Was nicht geht

- Das Mac-Modell allein kann **keine Einbettungen**; Stufe 2 bleibt dann aus.
- Eine Art ist kein Ordner. Willst du, dass Mails irgendwo landen, nutze die **Ablage**
  ([Kapitel 7](07-aufraeumen.md)).
- Die Zusammenfassung von Gedächtniseinträgen zu kompakteren („Konsolidierung“) ist vorgesehen,
  aber noch nicht gebaut — bisher gibt es keine Duplikate, die sich lohnen würden.

## Weiter

- [Kapitel 6 — Spam und Phishing](06-spam-und-phishing.md)
- [Kapitel 8 — Nach Bedeutung suchen und zusammenfassen](08-bedeutung-und-zusammenfassung.md)
- Hintergrund: [ADR-0004](../adr/0004-llm-routing.md), [ADR-0005](../adr/0005-memory-model.md)
