# Änderungen

Diese Datei hält fest, was sich für Benutzerinnen und Benutzer ändert. Die Entscheidungen
dahinter stehen in [docs/adr/](docs/adr/).

## [0.1.0] — unveröffentlicht

Erste Fassung. Noch kein öffentliches Release: die Lizenz steht noch nicht (ADR-0013).

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
