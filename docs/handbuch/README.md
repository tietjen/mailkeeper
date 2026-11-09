# MailKeeper — Handbuch

In der Reihenfolge, in der man es braucht. Die ersten drei Kapitel reichen, um loszulegen.

| | Kapitel | Worum es geht |
|---|---|---|
| 1 | [Das Archiv einrichten](01-archiv-einrichten.md) | Installation, wo die Mails liegen, wie das Fenster aufgebaut ist |
| 2 | [Postfächer verbinden](02-postfaecher-verbinden.md) | IMAP, Gmail (App-Passwort oder Google-Anmeldung), Proton Bridge, Importe |
| 3 | [Abrufen und durchsuchen](03-abrufen-und-suchen.md) | Der Abruf, die Suchsprache, Ansichten, Gruppen |
| 4 | [Die KI-Funktionen einrichten](04-ki-einrichten.md) | Endpunkt oder Mac-Modell, was den Mac verlässt |
| 5 | [Mails einordnen](05-mails-einordnen.md) | Die neun Arten, die drei Stufen, „Warum?“, das Gedächtnis |
| 6 | [Spam und Phishing](06-spam-und-phishing.md) | Warum nur dein Server zählt, Links, Beziehungsregister, Abmelden |
| 7 | [Postfächer aufräumen](07-aufraeumen.md) | Gruppen, Löschen, Zurückspielen, Ablage, Regeln, Export |
| 8 | [Nach Bedeutung suchen und zusammenfassen](08-bedeutung-und-zusammenfassung.md) | Vektorsuche, Alltagssprache, Zusammenfassungen |
| 9 | [Sicherheit und Datenschutz](09-sicherheit-und-datenschutz.md) | Was wohin geht, Sandbox, und die Grenzen |
| 10 | [Die Kommandozeile `mkctl`](10-kommandozeile.md) | Skripte, große Importe, nächtliche Läufe |

**In der App:** **⌘?** öffnet die Hilfe im Programm — dieselben Themen in Kurzform und
durchsuchbar, mit einem Link hierher. Einrichtung und Rundgang vom ersten Start holst du über
**Hilfe › Einrichtung …** und **Hilfe › Rundgang zeigen** zurück.

**Wie Server und Archiv zusammenhängen** — was beim Abrufen wohin geht und was das Archiv macht,
wenn du auf dem Server löschst oder verschiebst — steht in
[Kapitel 3](03-abrufen-und-suchen.md#was-sich-auf-dem-server-ändert--und-was-das-archiv-daraus-macht).

**Zum Nachschlagen:** [Funktionsreferenz](../funktionen.md) — jede Funktion mit ihren Grenzen.

**Zum Verstehen:** [Wie MailKeeper gebaut ist](../architektur.md) — und dahinter die
[Architekturentscheidungen](../adr/) mit ihren Gründen.

## Die fünf Leitsätze

Wenn MailKeeper sich einmal anders verhält als erwartet, liegt es fast immer an einem davon:

1. **Archiv zuerst, Server danach.** Auf dem Server wird erst gelöscht, wenn die Mail geprüft im
   Archiv liegt.
2. **Plan → Ausführen → Prüfen.** Nichts Veränderndes passiert ohne vorherige Ansage.
3. **Die KI schlägt vor, du entscheidest.** Kein Modell löscht, verschiebt oder gibt etwas frei.
4. **Mailinhalte sind Daten, keine Anweisungen.**
5. **Das Archiv ist ohne die App lesbar** — rohe `.eml`-Dateien plus ein Index, der sich jederzeit
   neu bauen lässt.
