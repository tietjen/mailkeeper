# Nutzungsbedingungen für MailKeeper

Stand: 2026-11-02, gültig ab Version 0.1.0 · [English translation below](#terms-of-use-english-translation)

MailKeeper ist ein Mailarchiv für macOS. Diese Bedingungen gelten für die fertigen
Programmdateien, die ich veröffentliche — das DMG, die Installation über Homebrew und die
Updates, die MailKeeper selbst einspielt — und für deren Nutzung. Was du mit MailKeeper darfst,
mit dem Quellcode wie mit dem fertigen Programm, regelt die
[LICENSE](https://github.com/tietjen/mailkeeper/blob/main/LICENSE) (PolyForm Noncommercial
1.0.0); diese Bedingungen schränken sie nicht ein. Sie erklären, was die Lizenz praktisch
bedeutet, und regeln, was eine Lizenz nicht regelt: Haftung nach deutschem Recht, Updates und
Datenschutz.

Anbieter: Jan Tietjen, privat · jan.tietjen@paranoidsecurity.de

## 1. Wer MailKeeper kostenlos nutzen darf

**Kostenlos** ist MailKeeper für jeden nichtkommerziellen Zweck, zum Beispiel:

- dein privates Postfach und das deiner Familie,
- Lernen, Ausprobieren, Testen, Hobbyprojekte,
- gemeinnützige Organisationen, Schulen und Hochschulen, öffentliche Forschung und Behörden —
  unabhängig davon, wie sie finanziert sind.

**Eine gesonderte Lizenz** braucht, wer MailKeeper für eine gewerbliche Tätigkeit einsetzt —
ein Unternehmen, aber auch Selbständige und Freiberufler für ihre geschäftliche Post. Schreib mir
dafür; im Zweifel frag lieber vorher.

## 2. Deine Daten

MailKeeper arbeitet auf deinem Mac. Es gibt **kein Konto bei mir**, **keine Telemetrie**, keine
Absturzberichte und keine Nutzungsstatistik. **Ich erhalte keine Daten von dir** — weder Mails
noch Einstellungen noch Angaben darüber, wie du das Programm nutzt.

Verbindungen nach außen baut MailKeeper nur dorthin auf, wohin du es schickst: zu deinen
Mailservern, zu dem KI-Endpunkt, den du selbst einträgst, zu Google, wenn du ein Gmail-Konto
über Google angemeldet hast (bei der Anmeldung, zur Erneuerung vor dem Abruf und zum Widerruf,
wenn du das Konto entfernst), zu einem Abmeldeziel, wenn du dich von einem Newsletter abmeldest —
und zu GitHub, um nach Updates zu sehen, wenn du dem zugestimmt hast. GitHub sieht dabei deine
IP-Adresse, die Version von MailKeeper und deine Spracheinstellung, aber keine Daten aus deinem
Archiv. Auch den Download
selbst liefern GitHub bzw. Homebrew aus; dort gelten deren Datenschutzbestimmungen.

Die vollständige Aufstellung, was wohin geht und wo welche Daten liegen, steht im
[Handbuch, Kapitel 9](https://github.com/tietjen/mailkeeper/blob/main/docs/handbuch/09-sicherheit-und-datenschutz.md).

Trägst du als KI-Endpunkt einen fremden Dienst ein, gehen die Mailinhalte, die du der KI gibst,
an diesen Dienst. Das entscheidest du, und dafür bist du verantwortlich. MailKeeper selbst bringt
keinen Cloud-KI-Anbieter mit.

## 3. Deine Verantwortung

- **Nur eigene oder dir anvertraute Postfächer.** Verbinde nur Postfächer, auf die du zugreifen
  darfst, und halte die Bedingungen deines Mailanbieters ein.
- **Mails anderer Menschen.** Dein Archiv enthält Daten der Absender und Empfänger. Für deine
  privaten Mails gilt die Datenschutz-Grundverordnung nicht (Art. 2 Abs. 2 lit. c DSGVO); nutzt du
  MailKeeper beruflich, bist du für diese Daten verantwortlich.
- **Sicherungen.** MailKeeper kann auf deine Anweisung Mails auf dem Server und im Archiv löschen.
  Plan, Bestätigung, Prüfung und Papierkorb verringern das Risiko, ersetzen aber **keine
  Datensicherung**. Der Papierkorb des Archivs leert sich nach 30 Tagen von selbst; was dann
  in keiner Sicherung liegt, ist weg. Sichere das Archiv regelmäßig, zum Beispiel mit Time
  Machine.
- **Verschlüsselung.** Das Archiv liegt unverschlüsselt auf der Platte, damit es auch ohne
  MailKeeper lesbar bleibt. Schalte FileVault ein oder lege das Archiv auf ein verschlüsseltes
  Volume.
- **KI-Ergebnisse prüfen.** Einordnungen, Phishing-Hinweise, Zusammenfassungen und Antworten der
  Suche werden maschinell erzeugt und können falsch sein. Sie sind Hinweise, keine Urteile, und
  keine Rechts- oder Steuerberatung. MailKeeper ist kein Virenscanner.

## 4. Updates und Unterstützung

MailKeeper ist eine Vorabversion. Funktionen können sich ändern, Fehler sind wahrscheinlich.
Einen Anspruch auf Updates, Fehlerbehebungen, Unterstützung oder Weiterentwicklung gibt es
nicht.

MailKeeper installiert nur Updates, die von mir signiert sind: mit dem Update-Schlüssel, dessen
öffentliche Hälfte in der App steckt, oder mit meiner Apple-Entwicklersignatur. Sparkle, der
Updater in MailKeeper, verlangt eine von beiden.

Ändere ich diese Bedingungen, sage ich das in den Versionshinweisen des Updates, und die neue
Fassung liegt ihm bei. Für eine Version, die du schon hast, gelten weiter die Bedingungen, unter
denen du sie bekommen hast.

## 5. Haftung

Ich stelle dir MailKeeper unentgeltlich zur Verfügung. Ich hafte deshalb nur für Vorsatz und
grobe Fahrlässigkeit, und für Mängel nur, wenn ich sie arglistig verschwiegen habe. Unberührt
bleibt die Haftung für Schäden an Leben, Körper und Gesundheit und nach zwingenden gesetzlichen
Vorschriften wie dem Produkthaftungsgesetz.

## 6. Name

Die Lizenz ist eine Urheberrechtslizenz; Rechte am Namen „MailKeeper“ als Kennzeichen gibt sie
nicht. Gibst du eine geänderte Fassung weiter, nenn sie bitte anders und gib ihr ein anderes
Symbol, damit niemand sie mit MailKeeper verwechselt.

## 7. Schlussbestimmungen

Es gilt deutsches Recht. Bist du Verbraucher mit gewöhnlichem Aufenthalt in einem anderen Land,
behältst du den Schutz der zwingenden Vorschriften dieses Landes.

Eine geänderte Fassung dieser Bedingungen gilt erst für die Version, der sie beiliegt (siehe 4).

Diese deutsche Fassung ist maßgeblich; die englische Übersetzung dient dem Verständnis.

---

# Terms of use (English translation)

As of 2026-11-02, valid from version 0.1.0. *The German text above is binding.*

MailKeeper is a mail archive for macOS. These terms apply to the finished program files I
publish — the DMG, the installation through Homebrew and the updates MailKeeper installs itself —
and to their use. What you may do with MailKeeper, with the source code as with the finished
program, is governed by the [LICENSE](https://github.com/tietjen/mailkeeper/blob/main/LICENSE)
(PolyForm Noncommercial 1.0.0); these terms do not restrict it. They explain what the licence
means in practice and cover what a licence does not: liability under German law, updates and
privacy.

Provider: Jan Tietjen, private individual · jan.tietjen@paranoidsecurity.de

## 1. Who may use MailKeeper free of charge

MailKeeper is **free** for any noncommercial purpose, for example:

- your private mailbox and your family's,
- learning, trying out, testing, hobby projects,
- charitable organisations, schools and universities, public research and government
  institutions — however they are funded.

**A separate licence** is needed to use MailKeeper for a commercial activity — a company, but
also self-employed people and freelancers for their business mail. Write to me; if in doubt, ask
first.

## 2. Your data

MailKeeper works on your Mac. There is **no account with me**, **no telemetry**, no crash reports
and no usage statistics. **I receive no data from you** — no mail, no settings, nothing about how
you use the program.

MailKeeper connects only where you send it: to your mail servers, to the AI endpoint you enter
yourself, to Google when you have signed in a Gmail account with Google (when signing in, to
renew the sign-in before fetching, and to revoke it when you remove the account), to an
unsubscribe target when you unsubscribe from a newsletter — and to GitHub to look for updates
once you have agreed to that. GitHub sees your IP address, the version of MailKeeper and your
language setting, but no data from your archive. The
download itself is delivered by GitHub or Homebrew; their privacy policies apply there.

The complete list of what goes where and which data lies where is in the
[handbook, chapter 9](https://github.com/tietjen/mailkeeper/blob/main/docs/handbuch/09-sicherheit-und-datenschutz.md) (German).

If you enter a third-party service as your AI endpoint, the mail content you give to the AI goes
to that service. That is your decision and your responsibility. MailKeeper itself ships with no
cloud AI provider.

## 3. Your responsibility

- **Only your own mailboxes, or those entrusted to you.** Connect only mailboxes you are allowed
  to access, and keep to your mail provider's terms.
- **Other people's mail.** Your archive contains data of senders and recipients. The GDPR does not
  apply to your private mail (Art. 2(2)(c) GDPR); if you use MailKeeper for work, you are
  responsible for this data.
- **Backups.** MailKeeper can delete mail on the server and in the archive when you tell it to.
  Plan, confirmation, verification and the trash reduce the risk but are **no substitute for a
  backup**. The archive's trash empties itself after 30 days; whatever is not in a backup by
  then is gone. Back up the archive regularly, for example with Time Machine.
- **Encryption.** The archive is stored unencrypted so that it stays readable without MailKeeper.
  Turn on FileVault or keep the archive on an encrypted volume.
- **Check AI results.** Classifications, phishing hints, summaries and search answers are
  machine-generated and can be wrong. They are hints, not verdicts, and no legal or tax advice.
  MailKeeper is not a virus scanner.

## 4. Updates and support

MailKeeper is a pre-release. Features may change, bugs are likely. There is no entitlement to
updates, bug fixes, support or further development.

MailKeeper only installs updates signed by me: with the update key whose public half is in the
app, or with my Apple developer signature. Sparkle, the updater in MailKeeper, requires one of
the two.

If I change these terms, I say so in the release notes of the update, and the new version comes
with it. A version you already have stays under the terms you received it with.

## 5. Liability

I provide MailKeeper free of charge. I am therefore liable only for intent and gross negligence,
and for defects only if I fraudulently concealed them. Liability for injury to life, body or
health and under mandatory statutory provisions such as the German Product Liability Act remains
unaffected.

## 6. Name

The licence is a copyright licence; it grants no rights to the name "MailKeeper" as a mark. If
you pass on a modified version, please give it another name and another icon so that nobody
mistakes it for MailKeeper.

## 7. Final provisions

German law applies. If you are a consumer habitually resident in another country, you keep the
protection of that country's mandatory provisions.

A changed version of these terms applies only to the version it comes with (see 4).

The German text is binding; the English translation is for convenience.
