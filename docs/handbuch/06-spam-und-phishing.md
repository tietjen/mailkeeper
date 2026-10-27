# Spam und Phishing erkennen und behandeln

Dieses Kapitel ist das längste des Handbuchs, und das mit Absicht: Hier steckt die Arbeit, die
MailKeeper von einem Archiv mit Suchfeld unterscheidet. Es erklärt nicht nur, welche Knöpfe es
gibt, sondern **warum** MailKeeper bestimmten Dingen glaubt und anderen nicht.

Vorher lohnt sich [Kapitel 5 — Mails einordnen](05-mails-einordnen.md); die Einordnung ist die
Stufe, auf der die Spam-Prüfung aufsetzt.

## Drei Dinge, die oft verwechselt werden

MailKeeper hält konsequent auseinander:

| | Was es bedeutet | Wer entscheidet |
|---|---|---|
| **Art: Spam** | unerwünschte Massenpost | Regeln oder Modell |
| **Phishing-Stufe** | der Versuch, dich hereinzulegen (`nein` · `verdacht` · `ja`) | nur das Modell, mit konkreten Anzeichen |
| **Dein Urteil** | „Ist Spam“ / „Kein Spam“ | du |

Der Unterschied ist nicht akademisch:

- Ein Werbe-Newsletter, den du nicht wolltest, ist **Spam, aber kein Phishing**. Abmelden genügt.
- Eine gefälschte Rechnung ist **beides** — und das Gefährliche daran ist nicht, dass sie
  unerwünscht ist.
- Die echte Mail deiner Bank, die im Spam-Ordner gelandet ist, ist **keins von beidem** und
  gehört dort heraus (siehe [„Kein Spam“](#kein-spam--die-mail-gehört-da-nicht-hin)).

**Deine Entscheidung schlägt alles.** Sagst du „Kein Spam“, überschreibt das weder eine Regel
noch ein Modell später wieder — und sie übersteht auch einen Neuaufbau des Index, weil sie im
Journal steht und nicht nur in der Datenbank.

## Was automatisch passiert

Nach jedem Abruf prüft MailKeeper still einen Teil der neuen Post. Nicht alles: Prüfen kostet
Zeit, und das meiste ist offensichtlich harmlos.

```
Neue Mail der letzten 14 Tage, nicht in Spam/Gesendet/Papierkorb,
von niemandem beurteilt
        ↓
1. Regeln laufen (Kopfzeilen, keine Mail wird gelesen)
        ↓
2. Deterministische Prüfung: Beziehungsregister, eigener Server, Links
        → eine Warnung wird gespeichert und reicht für „Verdächtig“,
          ganz ohne Modell
        ↓
3. Das Modell — nur wo es etwas bringt (höchstens 30 je Abruf):
   · es gibt eine Warnung
   · Erstkontakt an einer öffentlichen Adresse
   · die Regeln haben nichts entschieden
   · Rechnung/Bestellung/Benachrichtigung/Konto-Mail, die NICHT von einer
     bestätigten Beziehung mit bestandener Prüfung kommt
```

Die letzte Zeile ist der Kern: Eine Rechnung von einem Absender, den du bestätigt hast und
dessen Prüfung dein eigener Server bestanden hat, ist uninteressant. Eine Rechnung von sonst
irgendwem ist es nicht.

Ältere Mail prüfst du über die Seitenleiste nach: **Verdächtig › Posteingang prüfen** für die
letzten 14, 90 oder 365 Tage.

Außerdem schaut MailKeeper in den **Spam-Ordner** — aber nur, wenn das Konto es erlaubt
(Einstellungen › Konten › „Spam prüfen“) und nie in den Papierkorb.

## Warum nur dein eigener Server zählt

Das ist der wichtigste Absatz dieses Kapitels.

Viele Mails tragen eine Kopfzeile wie diese:

```
Authentication-Results: mail.example.com;
        dkim=pass header.d=bank.example; spf=pass; dmarc=pass
```

Das sieht nach einem Echtheitsnachweis aus. **Ist es aber nur, wenn dein eigener Server diese
Zeile geschrieben hat.** Jeder kann sie hineinschreiben — auch der Angreifer, der die Mail
verschickt. Eine Mail mit `dmarc=pass` von einem Server, der nichts mit dir zu tun hat, ist
exakt so vertrauenswürdig wie eine Mail ganz ohne diese Zeile: nämlich gar nicht.

MailKeeper lernt deshalb pro Konto, **welche Server deine eigenen sind.** Ein Server gilt als
eigen, wenn er

- mindestens die **Hälfte** aller eingehenden Mails dieses Kontos gestempelt hat (im letzten
  Jahr oder überhaupt, mindestens 20), **oder**
- ein **Fünftel** (mindestens 5), wenn sein Hostname zur IMAP-Domain des Kontos passt
  (`mx.google.com` zu `imap.gmail.com`), **oder**
- in einem anderen deiner Konten schon als eigen gilt und hier ein Viertel geprüft hat.

Dass es mehrere sein dürfen, ist kein Luxus: Ein Postfach zieht um. In TJs Archiv stehen 27 030
Mails von einem Server und danach 7 093 von einem anderen — beide sind echt.

Prüfergebnisse **jedes anderen Servers zählen nichts** und werden nicht einmal als Prüfung
angezeigt. Auch das Modell bekommt sie nicht zu sehen: Es soll nicht in Versuchung kommen, einer
gefälschten Zeile zu glauben.

> **Was das nicht schafft.** Ein ruhendes Konto mit sehr wenigen Mails ließe sich mit genug
> gefälschten Kopfzeilen (etwa 20) überstimmen. Der Hostname allein reicht nie — das war eine
> frühere Lücke: Bei einem Anbieter, der gar keine solche Zeile setzt, hätten fünf gefälschte
> genügt, um einen fremden Server zum „eigenen“ zu machen.

## Links prüfen, ohne sie anzuklicken

MailKeeper liest Links wie ein misstrauischer Mensch — **ohne sie jemals abzurufen**. Geprüft
wird im Text selbst:

| Befund | Warum verdächtig |
|---|---|
| Linktext nennt eine andere Domain als das Ziel | „www.bank.de“, das woanders hinführt |
| nackte IP-Adresse statt eines Namens | kein seriöser Absender tut das |
| Punycode (`xn--…`) | Buchstaben, die wie andere aussehen |
| Kurz-URL-Dienst | versteckt das Ziel |
| ungewöhnliches Schema | weder `https:` noch `mailto:` |
| Benutzername vor dem Host | `https://bank.de@angreifer.example` — alles vor dem `@` ist Text |

Die Befunde siehst du beim Darüberfahren und im Leser, und das Modell bekommt sie als Befunde
mitgeteilt.

**Ein Linkbefund allein ist nie ein Urteil.** Fast jeder legitime Newsletter leitet Klicks über
eine Zähl-Domain um — das ist ärgerlich, aber kein Betrug. Darum zählen Links als Hinweis
zwischen anderen, nicht als Beweis.

## Das Beziehungsregister

MailKeeper kann wissen, wer wirklich zu dir gehört: deine Bank, die Schule, der Händler, bei dem
du bestellst. Eine **Beziehung** besteht aus einem Namen, den Domains, von denen diese Stelle
dir *authentifiziert* geschrieben hat, und dem Zeitraum.

**Vorgeschlagen** werden Beziehungen aus deinem Verlauf — wenn es positive Belege gibt:

- du hast an diese Domain geschrieben (aus deinem Gesendet-Ordner),
- du hast dort „Kein Spam“ gesagt oder eine Art vergeben,
- es gibt mindestens zwei geprüfte Transaktionsmails.

Nie vorgeschlagen werden Freemail-Domains (`gmail.com` und Verwandte) und deine eigenen Domains.
Und nichts davon wird zu einer Beziehung, **bevor du zustimmst** — unter Einstellungen ›
Beziehungen. Lehnst du einen Vorschlag ab, kommt er nicht wieder; vergisst du eine Beziehung,
darf sie später neu vorgeschlagen werden.

### Was daraus im Leser wird: „Echtheit“

Pro Mail läuft eine feste Prüfung — kein Modell, nur Vergleiche:

| Befund | Bedeutung |
|---|---|
| **bekannte Beziehung** | Absender gehört zu einer bestätigten Beziehung — zusammen mit dem Urteil deines eigenen Servers |
| **Doppelgänger** | Name oder Domain trägt den Namen einer bekannten Beziehung, kommt aber von **einer anderen Domain** |
| **Prüfung fehlgeschlagen** | dein eigener Server sagt: DKIM oder DMARC nicht bestanden |
| **Erstkontakt** | an einer Adresse, die du als öffentlich hinterlegt hast |

**Doppelgänger ist der klassische Angriff.** „Sparkasse Service“ von `sparkasse-sicherheit.example`
ist genau das Muster. MailKeeper sieht es, weil es deine echte Sparkasse kennt — und meldet es,
*weil* die Domain nicht dazugehört.

Eine Beziehung darf die Vorsicht nur **senken, wenn es Belege gibt**. Ein Doppelgänger **hebt**
sie immer. Einzelne Wörter eines Personennamens lösen nie einen Doppelgänger-Verdacht aus —
sonst wäre jeder „Michael“ verdächtig.

Kennst du den Absender doch, steht im Leser **„… gehört doch dazu“** — damit nimmst du die
Domain in die Beziehung auf.

### Erstkontakt an einer öffentlichen Adresse

Hast du eine Adresse, die auf deiner Webseite steht? Hinterlege sie als öffentlich (eine Notiz
mit dem Betreff `public:<adresse>` im Gedächtnis). Dann weiß MailKeeper: Wer dort zum ersten Mal
schreibt, schreibt **unaufgefordert**.

Wichtig ist, was daraus *nicht* folgt: Unaufgefordert ist **nicht** dasselbe wie Spam — an eine
öffentliche Adresse kommen echte Anfragen. Und persönliche Daten in so einer Mail (dein Name,
deine Firma) sind **kein Echtheitsnachweis**: Die stehen ja ebenfalls öffentlich.

## Was du tun kannst

### „Kein Spam“ — die Mail gehört da nicht hin

Findest du im Spam-Ordner eine echte Mail, ist das nicht nur ein Ärgernis für dich, sondern ein
Problem für die Zukunft: **Spamfilter wie rspamd oder SpamAssassin lernen aus dem Spam-Ordner.**
Jede echte Mail, die dort liegen bleibt, verschlechtert die Erkennung.

„Kein Spam“ holt die Mail deshalb auf dem Server wieder heraus — und zwar **dorthin, wo sie
vorher lag** (sonst in den Posteingang). Für eine einzelne Mail ist es ein Klick; für viele
zeigt MailKeeper erst die Liste, du nimmst heraus, was doch Spam ist, und bestätigst einmal.

In der Seitenleiste führt **„Laut KI kein Spam“** die Mails im Spam-Ordner auf, die das Modell
für harmlos hält und über die noch niemand entschieden hat.

### „Ist Spam“ — die Mail gehört dorthin

Der umgekehrte Weg: Die Mail wandert in den Spam-Ordner des Servers, und dein Spamfilter lernt
mit. Nie aus Gesendet, Entwürfen, Papierkorb oder einem Spam-Ordner heraus — das wird abgelehnt,
egal ob die Ordner über ihre Rolle oder über ihren Namen erkannt werden.

### „Einschätzung korrigieren“

Hat MailKeeper eine echte Mail angeschwärzt, reicht ein Widerspruch nicht immer — der nächste
Absender derselben Firma träfe auf dieselbe Lage. Darum kannst du in einem Zug:

1. die Mail für echt erklären (wird als „kein Spam“ journalisiert),
2. eine **Beziehung** als feste Regel anlegen,
3. eine **Notiz** für die Domain des Absenders hinterlegen,
4. **diese und die anderen** vom Modell angeschwärzten Mails dieser Domains neu beurteilen lassen.

Danach gilt auch ein `Reply-To` innerhalb derselben bestätigten Beziehung nicht mehr als
Warnzeichen (`paypal.de` → `paypal.com` ist dann in Ordnung).

### Vom Newsletter abmelden

Der Abmelde-Knopf erscheint, wenn die Mail einen `List-Unsubscribe`-Eintrag hat — aber er ist
**gesperrt**, wenn Abmelden eine schlechte Idee wäre, und sagt warum:

- ein Modell hält die Mail für Phishing,
- das Register sieht einen Doppelgänger oder die Prüfung des eigenen Servers ist fehlgeschlagen,
- die Mail ist Spam (dein Urteil, das eines Modells, oder sie liegt im Spam-Ordner ohne „Kein Spam“),
- der Abmeldelink selbst hat Befunde.

Der Grund dahinter: **Bei echtem Spam bestätigt eine Abmeldung nur, dass deine Adresse gelesen
wird.**

Ist alles sauber, geht die Abmeldung mit **einem Klick** (RFC 8058: ein einziger POST, keine
Cookies, keine Weiterleitungen) — aber nur, wenn DKIM und DMARC bei deinem eigenen Server
bestanden haben. Sonst öffnet sich die Seite im Browser oder eine Mail wird vorbereitet.

> **Eine Feinheit, die ein Review zutage gefördert hat.** Nimmt jemand einen echten, signierten
> Newsletter und setzt oben eine eigene `List-Unsubscribe`-Zeile darauf, bestehen DKIM und DMARC
> weiterhin — ein Prüfer sieht die **unterste** Instanz an (RFC 6376). Deshalb nimmt MailKeeper
> die letzte Instanz, sperrt den Knopf, wenn es mehr als eine gibt, und verlangt für den
> Ein-Klick-Weg eine DKIM-Signatur der Absenderdomain, deren `h=` die Abmelde-Kopfzeilen so oft
> abdeckt, wie sie vorkommen. Das Ziel muss außerdem ein gewöhnlicher öffentlicher Name sein und
> unmittelbar vor der Anfrage auf eine öffentliche Adresse zeigen.

Jede Abmeldung steht im Protokoll (nur Domain und Art, kein Inhalt) und wird als Notiz gemerkt:
Weitere Newsletter dieser Liste sind unerwünscht.

## Was MailKeeper nicht tut

- **Nichts wird wegen eines Verdachts gelöscht.** Eine Fehleinschätzung kostet ein falsches
  Etikett, nie eine Mail.
- **Kein Modell verschiebt etwas.** Jedes Verschieben ist dein Klick.
- **Phishing melden** (an eine Stelle wie die Verbraucherzentrale) ist vorgesehen, aber noch
  nicht gebaut — dafür fehlt MailKeeper ein Sendeweg.

## Weiter

- [Kapitel 7 — Postfächer aufräumen](07-aufraeumen.md)
- [Kapitel 5 — Mails einordnen](05-mails-einordnen.md), wenn die Einordnung selbst unklar ist
- Hintergrund: [ADR-0010](../adr/0010-spam-phishing-signals.md) mit allen Entscheidungen und
  ihren Gründen
