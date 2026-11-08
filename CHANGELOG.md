# Änderungen

Diese Datei hält fest, was sich für Benutzerinnen und Benutzer ändert. Die Entscheidungen
dahinter stehen in [docs/adr/](docs/adr/).

## [Unveröffentlicht]

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
