# Änderungen

Diese Datei hält fest, was sich für Benutzerinnen und Benutzer ändert. Die Entscheidungen
dahinter stehen in [docs/adr/](docs/adr/).

## [Unveröffentlicht]

- **Pfad der Protokolle:** *Einstellungen › KI*, das Ergebnis eines Auftrags und die Meldung zur
  Einordnung nannten `~/Library/Logs/MailKeeper/`. Die App schreibt ihre Protokolle aber in
  ihren Container; jetzt steht dort der echte Pfad. Ein Archiv in deinem Benutzerordner erscheint
  mit `~` statt mit dem vollen Pfad.
- **Handbuch und README:** Ein neuer Abschnitt sagt, wie man MailKeeper installiert — mit
  Homebrew oder als DMG —, was bei Updates passiert und was beim Deinstallieren bleibt.

## [0.3.1] — 2026-11-09

Löschen auf dem Server übersteht ein langsames Gmail.

- **Löschen auf dem Server, langsames Gmail:** Antwortete Gmail beim Verschieben in den
  Papierkorb länger als zwei Minuten, brach der Auftrag mit „Verbindung geschlossen oder
  Zeitüberschreitung“ ab und musste von Hand fortgesetzt werden. MailKeeper wartet jetzt bis zu
  fünf Minuten, nimmt bei Gmail kleinere Stapel und verbindet sich nach einem Abbruch bis zu
  zweimal von selbst neu. Hält ein Auftrag trotzdem an, sagt die Meldung, dass sich der Rest
  fortsetzen lässt.
- **Nach einem Abbruch:** Mails, die der Server beim Abbruch schon verschoben hatte, hießen
  danach „war bereits nicht mehr auf dem Server“. Verbindet sich MailKeeper neu, heißen sie jetzt
  „beim unterbrochenen Lauf in den Papierkorb verschoben“, und **Komplett entfernen** nimmt auch
  ihre Archivkopie.
- **„Stimmt nicht mit dem Archiv überein“ ohne Grund:** Gmail lieferte in einem Stapel für eine
  Mail die Kopfzeile nicht mit; MailKeeper hielt sie deshalb für eine andere Mail. Jetzt werden
  Teilantworten zusammengeführt, und fehlt die Message-ID, entscheidet der Vergleich der Bytes.

## [0.3.0] — 2026-11-08

Aufräumen: Server und Archiv auf einen Blick, Mails komplett entfernen.

- **Aufräumen, Server und Archiv:** Die Gruppenliste hat zwei neue Spalten, **Server** und
  **Nur Archiv**: wie viele Mails einer Gruppe noch auf dem Server liegen und wie viele nur noch
  im Archiv. Beide lassen sich sortieren. Rechts zeigt ein zweifarbiger Balken dasselbe
  Verhältnis, darunter Anzahl und Größe beider Teile.
- **Aufräumen, Knöpfe:** Die Knöpfe unter einer Gruppe sind jetzt Symbole. Was sie tun, steht
  im Tooltip, und nichts wird mehr abgeschnitten.
- **Komplett entfernen:** Ein neuer Weg nimmt Mails vom Server und aus dem Archiv in einem
  Plan: erst in den Papierkorb ihres Servers, mit denselben Prüfungen wie beim Löschen auf dem
  Server, danach in den Papierkorb des Archivs. Was der Server nicht hergibt (Schonfrist,
  markiert, nicht erreichbar), bleibt an beiden Orten. Zu finden in *Bearbeiten* (⌥⌘⌫), im
  Kontextmenü, bei mehreren ausgewählten Mails und bei einer Gruppe unter *Aufräumen*. Der Plan
  *Aus dem Archiv löschen* bietet ihn an, wenn Mails noch auf einem Server liegen.
- **Papierkorb des Archivs:** Wie lange er Mails hält, bevor er sie von selbst endgültig löscht,
  stellst du oben in der Papierkorb-Ansicht ein: 7 Tage bis ein Jahr oder „nur von Hand“.
  Standard bleiben 30 Tage. Die Frist gilt je Archiv. Löscht eine kürzere Frist sofort Mails,
  fragt MailKeeper vorher nach Touch ID oder deinem Passwort.

## [0.2.1] — 2026-11-08

Gmail-Anmeldung verständlich.

- **Gmail-Konto hinzufügen:** Der Dialog sagt, was die beiden Wege kosten (App-Passwort: etwa
  2 Minuten; Anmeldung mit Google: einmalig ein eigener Google-Client, etwa 10 Minuten), und
  führt durch die Google-Anmeldung in vier Schritten — die Anleitung für den Client steht im
  Dialog, mit Links direkt auf die Seiten der Google Cloud Console. Zum App-Passwort gibt es den
  Link auf die Google-Seite, auf der es entsteht.
- **Konto hinzufügen:** Unter „Kürzel“ steht, wofür es da ist, und neben dem ausgegrauten
  *Verbinden und prüfen* steht, was noch fehlt.

## [0.2.0] — 2026-11-07

Erster Start und Einrichtung.

- **Erster Start:** MailKeeper legt kein Archiv mehr von sich aus an. Eine **Einrichtung** in drei
  Schritten erklärt, wie Server und Archiv zusammenhängen, legt das Archiv an (Standard-Ort,
  eigener Ordner oder vorhandenes) und verbindet ein oder mehrere Postfächer. Danach folgt der
  **Rundgang** durchs Fenster; beides gibt es unter *Hilfe › Einrichtung …* und
  *Hilfe › Rundgang zeigen*.
- **Rundgang:** Eine Karte bleibt stehen, bis du sie mit ihren Knöpfen weiterschaltest — sie
  verschwindet nicht mehr, wenn MailKeeper den Fokus verliert.
- **Leere Zustände** sagen, was zu tun ist: „Noch kein Archiv“, „… ist noch leer“ mit
  *Konto hinzufügen …*, „Noch nichts abgerufen“ mit *Jetzt abrufen*.
- **Seitenleiste:** je Konto „Alle Ordner“ — die Mails eines Kontos mit einem Klick.
- **Einstellungen › Konten** nennt das Archiv, zu dem die Konten gehören.
- **Hilfe und Handbuch:** neues Kapitel „Server und Archiv“ — was beim Löschen, Verschieben und
  Umbenennen auf dem Server mit dem Archiv passiert.

## [0.1.0] — 2026-11-04

Erste Fassung, als Vorabversion.

- **Lizenz:** PolyForm Noncommercial 1.0.0 — privat und für andere nichtkommerzielle Zwecke
  frei, gewerblich mit eigener Lizenz. Was das heißt und was für Downloads und Updates gilt,
  steht in [TERMS.md](https://github.com/tietjen/mailkeeper/blob/main/TERMS.md); die Lizenzen der eingebauten Fremdkomponenten liegen in der
  App (ADR-0013).

- **Archiv:** Mails als `.eml` plus Journal, SQLite-Index jederzeit neu baubar; Import aus
  Maildir, mbox und `.eml`-Ordnern.
- **Postfächer:** IMAP, Gmail (App-Passwort oder Anmeldung mit Google), Proton Mail Bridge.
  Abgerufen wird nur lesend.
- **Suchen:** eigene Suchsprache mit deutschen und englischen Feldnamen, Volltext inklusive
  PDF-Anhängen, gespeicherte Ansichten, Gruppierung nach Absender, Domain und Liste.
- **Aufräumen:** Löschen auf dem Server und im Archiv, Zurückspielen, Export, eigene Ablage —
  jedes Mal mit Plan, Bestätigung und Prüfprotokoll.
- **KI, lokal:** eigener Endpunkt oder das Modell auf diesem Mac. Einordnung in neun Arten,
  Phishing-Erkennung mit Linkprüfung und Beziehungsregister, Zusammenfassungen, Suche nach
  Bedeutung und in Alltagssprache.
- **Dokumentation:** Handbuch, Funktionsreferenz und Architektur unter [docs/](docs/).
