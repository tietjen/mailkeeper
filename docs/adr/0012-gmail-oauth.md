# ADR-0012: Anmeldung bei Gmail mit Google (OAuth)

- Status: accepted (TJ, 2026-10-27)
- Deciders: TJ

## Context

Gmail nimmt für IMAP ein App-Passwort oder ein OAuth-Zugriffstoken (`AUTH=XOAUTH2`). Bis Phase 6
konnte MailKeeper nur das App-Passwort. Das setzt die 2-Schritt-Verifizierung voraus, ist für
viele ein Umweg, und Google drängt seit Jahren auf OAuth.

Der Haken: IMAP verlangt den Bereich `https://mail.google.com/`. Der ist *restricted* — wer ihn
fremden Nutzern anbietet, braucht Googles Überprüfung mit jährlichem CASA-Assessment (Kosten und
wiederkehrender Aufwand). TJ hält sich offen, MailKeeper als Produkt anzubieten; die Entscheidung
darf diesen Weg also nicht verbauen, ihn aber auch nicht heute schon bezahlen.

## Decision

1. **OAuth tritt neben das App-Passwort, nicht an seine Stelle.** Ein Gmail-Konto meldet sich
   per Passwort oder per Google an; beide Wege bleiben. `AccountConfig.oauth` fehlt bei allen
   Konten von vor 7.1, und das heißt weiterhin „Passwort“ — eine `accounts.json` aus Phase 6
   liest sich unverändert.
2. **Der Client gehört dem, der MailKeeper betreibt.** Jedes Konto trägt die Client-ID eines
   eigenen Google-Cloud-Projekts (Anleitung: `docs/gmail-oauth.md`). `clientID` ist dennoch
   optional: ist sie leer, nimmt MailKeeper den Client aus dem eigenen Bundle
   (`MKGoogleClientID`/`MKGoogleClientSecret` in der Info.plist). Heute liefert kein Build einen
   mit. **Der Produktweg** ist damit offen: Sobald MailKeeper einen geprüften Client hat, trägt
   ihn der Build, die Felder sind vorausgefüllt, eingerichtete Konten laufen unverändert weiter —
   ohne Format- oder Schlüsselbund-Änderung.
3. **Authorization Code + PKCE mit Loopback-Redirect** (RFC 8252). Kein Client-Secret im Code,
   keine eingebettete Web-Ansicht: die Anmeldung läuft im Browser des Nutzers. Der Rückweg ist
   ein kurzlebiger Server auf `127.0.0.1` mit einem Port, den der Kernel vergibt; er nimmt genau
   eine Weiterleitung an, prüft `state`, antwortet mit einer Seite und endet. Gebunden wird nur
   die Loopback-Adresse. Die Sandbox-Version braucht dafür
   `com.apple.security.network.server` — die einzige Erweiterung der Rechte in dieser Phase.
4. **Im Schlüsselbund liegt das Refresh-Token**, neben (nicht statt) einem etwaigen App-Passwort,
   unter `oauth-refresh:<adresse@host:port>` — nach derselben Postfach-Identität wie das
   Passwort, sodass zwei Archive desselben Postfachs sich eine Anmeldung teilen. Das
   Client-Secret liegt daneben (`oauth-client-secret:…`); bei einer Desktop-App ist es laut
   Google kein echtes Geheimnis, es gehört aber trotzdem nicht ins Archiv. Im Archiv steht nur
   die Client-ID.
5. **Zugriffstoken werden nicht gespeichert.** `OAuthTokens2Go` hält das letzte im Speicher —
   nur Token und Ablauf, nie das Refresh-Token — und erneuert es, wenn weniger als fünf Minuten
   übrig sind; ein Abruf, der lange läuft, fängt nicht mit einem Token an, das gleich abläuft.
   Ein Neustart kostet eine Erneuerung. Wird eine Anmeldung bei Google widerrufen, ist das
   gehaltene Token sofort tot: eine abgelehnte Anmeldung verwirft es deshalb und versucht es
   genau einmal mit einem frischen (`SyncCoordinator.connect`), damit der Nutzer „bitte neu
   anmelden“ zu sehen bekommt statt bis zu einer Stunde „Anmeldung abgelehnt“.
6. **Nicht benutzte Anmeldungen gehen an Google zurück.** Google hält bis zu 50 Refresh-Tokens
   je Client und Nutzer; ein verworfener Anmeldeversuch (Abbrechen, fehlgeschlagene Prüfung,
   falsches Konto) und ein ersetztes Token werden widerrufen, ebenso beim „Entfernen und
   Google-Anmeldung widerrufen“. Ein Sonderfall bleibt stehen: wer von Google zurück auf ein
   App-Passwort geht, behält die Anmeldung im Schlüsselbund — ein anderes Archiv könnte dasselbe
   Postfach damit abrufen; widerrufen wird sie dann bei Google.
7. **Der Rückkanal gehört genau einer Anmeldung.** Der Port ist für jeden Prozess auf dem Mac
   sichtbar; angenommen wird nur eine Weiterleitung mit dem `state` dieser Anmeldung, alles
   andere bekommt 404 und der Server wartet weiter. Kommt bis zum Zeitablauf nur Fremdes, sagt
   MailKeeper das (`state passt nicht`) statt „nichts passiert“.
8. **Ein Konto behält seine Kennung, wenn es umgestellt wird** („Auf Google-Anmeldung
   umstellen …“, `mkctl account signin`). Das Archiv hängt an der Kennung, und ein Wechsel der
   Anmeldeart ist kein neues Postfach. Das App-Passwort bleibt im Schlüsselbund stehen und wird
   nicht mehr benutzt; widerrufen wird es bei Google.
9. **Die angemeldete Adresse wird geprüft.** Angefragt werden `https://mail.google.com/` sowie
   `openid email`; die Adresse aus dem ID-Token wird mit der des Kontos verglichen. MailKeeper
   prüft die Signatur dieses Tokens nicht — sie kommt über TLS direkt von Googles Token-Endpunkt
   und dient nur dazu, dem Nutzer zu sagen, dass im Browser ein anderes Konto aktiv war. Gmail
   ignoriert Punkte im lokalen Teil und behandelt `googlemail.com` wie `gmail.com`; der Vergleich
   tut dasselbe, sonst stünde `t.j@gmail.com` vor einer Wand. Der eigentliche Nachweis ist
   ohnehin die Verbindungsprüfung — auch beim Umstellen, nicht nur beim Anlegen.

## Consequences

- Kein zweiter Anmeldeweg im Code: alle Verbindungen gehen durch `SyncCoordinator.credential`,
  das je nach Konto ein Passwort oder ein frisches Token liefert. Die fünf Server-Aktionen
  (Löschen, Zurückspielen, Kein Spam, Ist Spam, Ablage ändern) ändern sich nicht.
- Der Zustimmungsbildschirm muss auf „In Produktion“ stehen; im Testmodus verfallen
  Refresh-Tokens nach 7 Tagen. Das steht in der Anleitung und in der Fehlertabelle.
- Wird die Anmeldung bei Google widerrufen, schlägt die Erneuerung fehl und MailKeeper sagt,
  dass eine neue nötig ist. Abgerufen wird dann nichts — es gehen keine Daten verloren.
- Gmail bleibt bei „Ablage ändern“ auf dem Server außen vor (ADR-0011 §5): Ordner sind dort
  Labels. Daran ändert die Anmeldeart nichts.
- Ein echter Durchlauf gegen Gmail braucht ein Google-Cloud-Projekt; die Unit-Tests decken PKCE,
  die Zustimmungs-URL, den Loopback-Rückweg und das SASL-Format ab, nicht aber Googles Antwort.
