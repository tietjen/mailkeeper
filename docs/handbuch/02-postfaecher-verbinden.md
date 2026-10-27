# Postfächer verbinden

MailKeeper holt Mail aus drei Arten von Konten und kann daneben vorhandene Archive einlesen.
Dieses Kapitel zeigt für jede Art, was zu tun ist — und was MailKeeper dabei **nicht** tut.

> **Abrufen ist nur lesend.** Eine Abrufverbindung kann auf dem Server nichts verändern: Sie
> öffnet Ordner mit `EXAMINE` statt `SELECT`, liest Mails mit `BODY.PEEK` (setzt also kein
> Gelesen-Flag) und lehnt jeden verändernden Befehl ab, bevor er gesendet wird. Verändert wird
> nur, wenn du eine Aktion startest — und dann über eine eigene, enge Verbindung
> ([Kapitel 7](07-aufraeumen.md)).

Konten verwaltest du unter **Einstellungen › Konten**. Jedes Konto hat ein **Kürzel**
(Kleinbuchstaben, Ziffern, `-` und `_`, höchstens 40 Zeichen), das im Archiv die Ordner benennt — es lässt sich
später nicht ändern, also wähle es mit Bedacht: `gmail-privat`, `arbeit`, `proton`.

Passwörter, Google-Anmeldungen und das Google-Client-Secret liegen im **Schlüsselbund**, nie im
Archiv. Der Eintrag gehört zur
Postfach-Identität (`adresse@host:port`), nicht zum Archiv — zwei Archive desselben Postfachs
teilen sich also einen Eintrag.

## Ein gewöhnliches IMAP-Konto (mailcow, Dovecot, Mailbox.org …)

1. **Einstellungen › Konten › +**, Art **IMAP**
2. Kürzel, Benutzername, Passwort
3. Server und Port (Standard 993 mit TLS; `STARTTLS statt TLS` für Port 143)
4. Optional **Nur diese Ordner** — kommagetrennt
5. **Verbinden und prüfen** zeigt, wie viele Ordner gefunden wurden und welche abgerufen werden
6. **Speichern**

Nicht abgerufen werden standardmäßig **Spam** und **Papierkorb**. Den Spam-Ordner kannst du pro
Konto dazunehmen (Haken **Spam prüfen** in der Kontenliste) — das ist die Voraussetzung dafür,
dass MailKeeper dort nach fälschlich aussortierten Mails sucht.

## Gmail

Gmail geht auf zwei Wegen. Beide funktionieren, beide bleiben.

### App-Passwort (schnell eingerichtet)

Voraussetzung ist die Zwei-Schritt-Verifizierung im Google-Konto. Dann: Google-Konto ›
Sicherheit › 2-Schritt-Verifizierung › App-Passwörter, ein Passwort erzeugen und in MailKeeper
unter Art **Gmail**, Anmeldung **App-Passwort** eintragen. Die Leerzeichen, die Google anzeigt,
darfst du mitkopieren — MailKeeper entfernt sie.

### Anmeldung mit Google (OAuth)

Der Weg, den Google langfristig vorsieht: MailKeeper bekommt ein Token statt eines Passworts,
und du siehst die Anmeldung im Google-Konto unter „Verbundene Apps“.

Dafür brauchst du einmalig ein eigenes Google-Cloud-Projekt. Das klingt nach mehr, als es ist,
hat aber einen handfesten Grund: Für den IMAP-Zugriff verlangt Google den Bereich
`https://mail.google.com/`, und eine App, die den für fremde Nutzer anbietet, muss durch Googles
Überprüfung samt jährlichem Audit.

Die Schritt-für-Schritt-Anleitung steht in **[docs/gmail-oauth.md](../gmail-oauth.md)**. Kurz:
Projekt anlegen → Gmail-API aktivieren → Zustimmungsbildschirm ausfüllen und **auf „In
Produktion“ stellen** (im Testmodus läuft die Anmeldung nach 7 Tagen ab) → OAuth-Client vom Typ
**Desktop-App** → Client-ID und -Schlüssel in MailKeeper eintragen → **Mit Google anmelden**.

Ein bestehendes Gmail-Konto stellst du um, ohne das Archiv anzufassen: Konto auswählen →
**Auf Google-Anmeldung umstellen …**. Kürzel, Archiv und Einstellungen bleiben. Der Weg zurück
geht genauso (**App-Passwort …**).

### Was bei Gmail anders ist

- Abgerufen wird **„Alle Nachrichten“**; die Labels einer Mail kommen als Labels ins Archiv.
- **Ordner sind bei Gmail Labels.** Deshalb kann MailKeeper dort die Ablage auf dem Server nicht
  ändern — ein „Verschieben“ wäre keins. Im Archiv geht es trotzdem.
- Eine Mail aus einem Label zu entfernen ist **kein** Löschen.

## Proton Mail (über die Bridge)

Proton gibt kein IMAP nach außen; die **Proton Mail Bridge** läuft auf deinem Mac und spricht
lokal IMAP.

1. Bridge starten und anmelden
2. In MailKeeper Art **Proton Mail Bridge**; Adresse und das Passwort, **das die Bridge
   anzeigt** (nicht dein Proton-Passwort)
3. Port: der aus der Bridge (Standard 1143)
4. **Verbinden und prüfen** zeigt den **Fingerabdruck** des Bridge-Zertifikats
5. Fingerabdruck bestätigen, dann **Speichern**

Der Fingerabdruck wird gemerkt (die Bridge nutzt ein selbst ausgestelltes Zertifikat, das sich
nicht gegen eine Kette prüfen lässt). Ändert er sich später, verweigert MailKeeper die
Verbindung, statt stillschweigend weiterzumachen.

> **Die Bridge baut Mails neu.** Was sie liefert, ist nicht byteweise dasselbe wie das Original
> — bei jedem Abruf können andere Bytes herauskommen. MailKeeper geht damit um: Eine Mail wird
> über ihre Message-ID (plus Absender/Betreff) erkannt und darf mehrere Blobs haben.

Wenn du nur einen Teil des Postfachs willst, trag ihn unter **Nur diese Ordner** ein, etwa
`Folders/MailKeeper-Test`. Die Liste wirkt wie eine Positivliste: Alles andere wird nicht
angefasst.

## Vorhandene Archive einlesen

In der App unter **Ablage › Importieren**: „Maildir-Ordner …“, „mbox-Datei (auch Google
Takeout) …“ oder „Ordner mit .eml-Dateien …“. Dasselbe Menü liegt in der Symbolleiste.

Auf der Kommandozeile, mit mehr Einfluss auf die Zuordnung:

```bash
mkctl --archive ~/MailKeeperArchive import maildir ~/MailArchive --account alt
mkctl --archive ~/MailKeeperArchive import mbox ~/Takeout/Mail/"All mail.mbox" --account gmail-alt
mkctl --archive ~/MailKeeperArchive import eml ~/Desktop/Einzelmails --account sonstiges
```

Importierte Mails haben keinen Serverort. Im Leser steht **„nur im Archiv“**, und
Server-Aktionen lassen sie in Ruhe.

## Mehrere Konten, ein Postfach

Dasselbe Postfach in zwei Archiven ist in Ordnung — beide teilen sich den
Schlüsselbund-Eintrag. Entfernst du ein Konto und wählst „Passwort behalten“, bleibt der Eintrag
für das andere Archiv erhalten. Nutzt noch ein Konto *in diesem Archiv* dieselbe
Postfach-Identität, lässt MailKeeper die Anmeldung von sich aus stehen und sagt das am Knopf.

## Wenn etwas klemmt

| Meldung | Ursache |
|---|---|
| „Anmeldung abgelehnt“ | Passwort falsch — bei Gmail: App-Passwort nötig, nicht das Kontopasswort |
| „Das Bridge-Zertifikat ist noch nicht bestätigt“ | Beim Anlegen den Fingerabdruck nicht bestätigt — Konto erneut prüfen |
| „Zertifikat der Bridge hat sich geändert“ | Bridge neu installiert → Konto entfernen und neu anlegen |
| „Der Server bietet keine Anmeldung mit Google-Token“ | Google-Anmeldung an einem Nicht-Gmail-Server |
| „bitte neu anmelden“ | Google-Anmeldung widerrufen oder abgelaufen → **Neu anmelden …** |
| Nach 7 Tagen abgemeldet | Zustimmungsbildschirm steht noch auf *Test* |

## Weiter

- [Kapitel 3 — Abrufen und durchsuchen](03-abrufen-und-suchen.md)
- [Kapitel 7 — Postfächer aufräumen](07-aufraeumen.md)
