# Gmail mit Google-Anmeldung einrichten

MailKeeper kann sich bei Gmail auf zwei Wegen anmelden:

| | App-Passwort | Google-Anmeldung (OAuth) |
|---|---|---|
| Aufwand | ein Passwort erzeugen | einmal ein Google-Cloud-Projekt anlegen |
| Voraussetzung | 2-Schritt-Verifizierung im Google-Konto | ein eigener OAuth-Client (siehe unten) |
| Widerrufen | Google-Konto › App-Passwörter | Google-Konto › Verbundene Apps |
| Was MailKeeper speichert | das App-Passwort im Schlüsselbund | ein Refresh-Token im Schlüsselbund |

Beides funktioniert; das App-Passwort ist schneller eingerichtet, die Google-Anmeldung ist der
Weg, den Google langfristig vorsieht. **Dein Google-Passwort sieht MailKeeper in keinem Fall.**

> **Warum ein eigener Client?** Für den IMAP-Zugriff verlangt Google den Bereich
> `https://mail.google.com/`. Der zählt als *restricted scope*: eine App, die ihn für fremde
> Nutzer anbietet, muss durch Googles Überprüfung samt jährlichem CASA-Assessment. Solange
> MailKeeper die nicht hat, bringt jedes Konto den Client seiner Besitzerin oder ihres Besitzers
> mit. Bekommt MailKeeper später einen geprüften eigenen Client, sind die Felder vorausgefüllt
> und diese Anleitung entfällt — eingerichtete Konten laufen unverändert weiter (ADR-0012).

## 1. Google-Cloud-Projekt anlegen

1. [console.cloud.google.com](https://console.cloud.google.com/) öffnen, oben links **Projekt
   auswählen › Neues Projekt**, Name z. B. `MailKeeper`, anlegen.
2. **APIs und Dienste › Bibliothek** → nach *Gmail API* suchen → **Aktivieren**.

## 2. Zustimmungsbildschirm

**APIs und Dienste › OAuth-Zustimmungsbildschirm** — Google nennt diesen Bereich inzwischen
**Google Auth Platform**, mit den Seiten *Branding*, *Zielgruppe*, *Clients* und *Datenzugriff*:

1. Nutzertyp **Extern** (Intern gibt es nur mit Google Workspace).
2. App-Name (z. B. „MailKeeper“), Support-E-Mail, Entwickler-E-Mail — das siehst nur du.
3. Bereiche: nichts eintragen. MailKeeper fragt die Bereiche beim Anmelden selbst an
   (`https://mail.google.com/`, `openid`, `email`).
4. Testnutzer: deine eigene Gmail-Adresse eintragen.
5. **Wichtig:** den Zustimmungsbildschirm anschließend auf **„In Produktion“** stellen
   (*Zielgruppe › Veröffentlichungsstatus › App veröffentlichen*). Im Testmodus läuft die
   Anmeldung nach **7 Tagen** ab, und MailKeeper müsste sich jede Woche neu anmelden. Die
   Warnung „Google hat diese App nicht überprüft“ bleibt, auch für dich als Eigentümer: Geprüft
   wird nur eine App, die den Bereich für fremde Nutzer anbietet. Du kommst über
   **Erweitert › Weiter zu …** daran vorbei.

## 3. OAuth-Client erstellen

**APIs und Dienste › Anmeldedaten › Anmeldedaten erstellen › OAuth-Client-ID** (in der neuen
Oberfläche: *Google Auth Platform › Clients › Client erstellen*):

- Anwendungstyp: **Desktop-App**
- Name: frei wählbar

Google zeigt danach **Client-ID** (endet auf `.apps.googleusercontent.com`) und
**Clientschlüssel** (beginnt mit `GOCSPX-`). Beides brauchst du gleich. Der „Schlüssel“ einer
Desktop-App ist kein echtes Geheimnis — Google sagt das selbst; geschützt wird die Anmeldung
durch PKCE. MailKeeper legt ihn trotzdem in den Schlüsselbund und nie ins Archiv.

Eine Weiterleitungs-URI musst du nicht eintragen: Desktop-Clients dürfen auf
`http://127.0.0.1:<Port>` zurückkommen, und MailKeeper nimmt für jede Anmeldung einen frischen
Port (RFC 8252).

## 4. In MailKeeper

**Einstellungen › Konten › +**, Art **Gmail**, Anmeldung **Mit Google anmelden**. Der Dialog
nummeriert die Schritte selbst; Schritt 1 ist diese Anleitung in kurz, mit einem Link auf jede
Seite der Google Cloud Console (unter **So geht’s**).

1. Kürzel und Adresse eintragen.
2. Client-ID und Clientschlüssel einsetzen — danach klappt die Kurzanleitung zu.
3. **Mit Google anmelden …** — der Browser öffnet sich, du wählst das Konto und bestätigst.
   Danach steht in der App „angemeldet als …“.
4. **Verbinden und prüfen**, dann **Speichern**. Solange der Knopf ausgegraut ist, steht links
   daneben, was noch fehlt.

Ein bestehendes Gmail-Konto stellst du um, ohne das Archiv anzufassen: Konto auswählen →
**Auf Google-Anmeldung umstellen …**. Kennung, Archiv und Einstellungen bleiben; das alte
App-Passwort wird nicht mehr benutzt (widerrufen kannst du es im Google-Konto).

Im Terminal geht dasselbe:

```bash
mkctl account add gmail du@gmail.com --id gmail-privat \
  --google-client-id 123-abc.apps.googleusercontent.com --google-client-secret
```

```bash
mkctl account signin gmail-privat --google-client-id 123-abc.apps.googleusercontent.com --google-client-secret
```

## Wenn es klemmt

| Meldung | Ursache |
|---|---|
| „Zugriff blockiert: … nicht abgeschlossen“ | Zustimmungsbildschirm unvollständig (Schritt 2) |
| „Die Anmeldung im Browser wurde nicht abgeschlossen“ | Fenster geschlossen oder länger als 5 Minuten gewartet |
| Nach 7 Tagen wieder abgemeldet | Zustimmungsbildschirm steht noch auf *Test* (Schritt 2.5) |
| „Der Server bietet keine Anmeldung mit Google-Token an“ | kein Gmail-Server — OAuth gibt es hier nur für Gmail |
| „angemeldet als …, eingerichtet wird …“ | im Browser war ein anderes Google-Konto aktiv |

Die Anmeldung lässt sich jederzeit zurücknehmen: Google-Konto ›
[Verbundene Apps](https://myaccount.google.com/connections). Danach meldet MailKeeper beim
nächsten Abruf, dass eine neue Anmeldung nötig ist.
