import SwiftUI

/// The help inside the app (8.5): short chapters that answer "what am I looking at and what
/// does this do", in both languages, with a search over them.
///
/// Deliberately not the whole handbook. `docs/handbuch/` holds about 14,000 words; carrying
/// those in the string catalogue would double them into English and still age faster than the
/// app. What is here is what you need while the window is open; the rest is one click away.
struct HelpChapter: Identifiable {
    let id: String
    let title: String
    let symbol: String
    let paragraphs: [String]
    /// Everything the search looks at: title, text and the extra words — lowercased, in the
    /// language the app runs in. The texts are resolved here rather than held as
    /// `LocalizedStringKey`, because that type cannot be read back: a search over it would
    /// only ever match German, whatever language the window is showing.
    let haystack: String

    init(id: String, title: String, symbol: String, paragraphs: [String], keywords: String) {
        self.id = id
        self.title = title
        self.symbol = symbol
        self.paragraphs = paragraphs
        self.haystack = ([title] + paragraphs + [keywords]).joined(separator: " ").lowercased()
    }
}

@MainActor
enum HelpBook {
    /// The long version. The public mirror does not exist yet — ADR-0013 keeps the first
    /// public release shut until licence and terms are settled — so until then this link is
    /// dead for anyone but the author. `Scripts/release.sh` refuses to publish a version
    /// whose handbook link does not answer, so no customer ever meets the 404.
    static let handbook = URL(string: "https://github.com/tietjen/mailkeeper/tree/main/docs/handbuch")!

    static let chapters: [HelpChapter] = [
        HelpChapter(
            id: "ueberblick", title: String(localized: "Überblick"), symbol: "sparkles",
            paragraphs: [
                String(localized: "MailKeeper holt Mail aus deinen Postfächern in ein Archiv auf diesem Mac: durchsuchbar, aufräumbar, und lesbar auch ohne MailKeeper."),
                String(localized: "• Archiv zuerst, Server danach — auf dem Server wird erst gelöscht, wenn die Mail geprüft im Archiv liegt."),
                String(localized: "• Plan, Ausführen, Prüfen — nichts Veränderndes passiert ohne vorherige Ansage."),
                String(localized: "• Die KI schlägt vor, du entscheidest — kein Modell löscht, verschiebt oder gibt etwas frei."),
                String(localized: "• Mailinhalte sind Daten, keine Anweisungen."),
                String(localized: "• Das Archiv ist ohne die App lesbar: rohe .eml-Dateien und ein Index, der sich neu bauen lässt."),
            ],
            keywords: String(localized: "überblick archiv leitsätze plan ausführen prüfen ki entscheidung eml")),
        HelpChapter(
            id: "server-archiv", title: String(localized: "Server und Archiv"), symbol: "arrow.left.arrow.right",
            paragraphs: [
                String(localized: "Ein Archiv ist ein Ordner auf diesem Mac. Darin liegen die Mails, der Suchindex und die Konten. Du kannst mehrere Archive haben, jedes mit eigenen Konten; der Fenstertitel zeigt, in welchem du bist, ein Klick darauf wechselt."),
                String(localized: "Ein Konto ist ein Postfach auf einem Mailserver. Ein Archiv nimmt beliebig viele auf. In der Seitenleiste steht jedes mit seinen Ordnern; „Alle Ordner“ zeigt nur dieses Konto, „Alle Nachrichten“ alle zusammen. Abrufen holt von allen Konten des Archivs."),
                String(localized: "Abrufen kopiert vom Server ins Archiv, nie umgekehrt: Neue Mails kommen dazu, Gelesen- und Markiert-Zeichen und Gmail-Labels werden übernommen."),
                String(localized: "Auf dem Server gelöscht: Die Mail bleibt im Archiv. „Ort“ sagt dann „Nur im Archiv – auf dem Server gelöscht“."),
                String(localized: "Auf dem Server verschoben: Die Mail kommt im neuen Ordner dazu und bleibt im alten stehen – gespeichert ist sie nur einmal. Wo sie jetzt auf dem Server liegt, sagt „Ort“; mit „Ablage ändern …“ führst du sie im Archiv nur noch dort, wo du willst. Ein umbenannter Ordner wirkt genauso."),
                String(localized: "Im Archiv gelöscht: Auf dem Server ändert sich nichts. Was noch auf einem Server liegt, lässt sich nicht aus dem Archiv löschen – es käme beim nächsten Abruf wieder; der Plan bietet an, es zuerst dort zu löschen. Der Papierkorb des Archivs hält 30 Tage, und endgültig Gelöschtes holt kein Abruf zurück."),
                String(localized: "Den Server ändert MailKeeper nur auf deinen Befehl: Auf dem Server löschen, Zurückspielen, Ablage auch auf dem Server, „Kein Spam“ und „Ist Spam“ – immer erst nach einem Plan, den du bestätigst."),
                String(localized: "Ein Konto zu entfernen löscht keine Mails: Was abgerufen ist, bleibt im Archiv; es wird nur nicht mehr abgerufen."),
            ],
            keywords: String(localized: "server archiv konto konten abrufen löschen verschieben ordner umbenennen nur im archiv ort entfernen mehrere archive wechseln einrichtung")),
        HelpChapter(
            id: "fenster", title: String(localized: "Das Fenster"), symbol: "sidebar.left",
            paragraphs: [
                String(localized: "Links die Seitenleiste: alle Nachrichten, deine gespeicherten Ansichten, der Papierkorb, die Spam-Prüfung und das Verdächtige — darunter je Konto „Alle Ordner“ und seine einzelnen Ordner."),
                String(localized: "In der Mitte die Liste. Über das Auswahlfeld „Ansicht“ in der Symbolleiste wird daraus eine Gruppierung nach Absender, Domain oder Liste — der Einstieg ins Aufräumen."),
                String(localized: "Rechts der Leser: Kopfzeilen, „Ort“ (wo die Mail liegt), „Art“, „Prüfung“, „Echtheit“, „Ablage“, Anhänge und der Text."),
                String(localized: "Unten die Statusleiste: was gerade läuft, wie groß das Archiv ist, und der Link auf einen unterbrochenen Auftrag."),
                String(localized: "Mit ⌘[ und ⌘] gehst du zurück und vor wie im Browser."),
            ],
            keywords: String(localized: "fenster seitenleiste liste leser statusleiste ansicht gruppieren verlauf spalten")),
        HelpChapter(
            id: "postfaecher", title: String(localized: "Postfächer verbinden"), symbol: "tray.and.arrow.down",
            paragraphs: [
                String(localized: "Einstellungen › Konten › +. Es gibt IMAP, Gmail und die Proton Mail Bridge; vorhandene Archive liest du über Ablage › Importieren ein."),
                String(localized: "Ein Archiv nimmt beliebig viele Konten auf. Die Konten gehören zum Archiv, das gerade offen ist – ein anderes Archiv hat seine eigenen. Hilfe › Einrichtung … führt Schritt für Schritt durch Archiv und Konten."),
                String(localized: "Abgerufen wird nur lesend. Eine Abrufverbindung kann auf dem Server nichts verändern — das ist nicht Absicht, sondern erzwungen."),
                String(localized: "Spam- und Papierkorb-Ordner bleiben außen vor. Den Spam-Ordner kannst du je Konto dazunehmen („Spam prüfen“); das ist die Voraussetzung dafür, dass MailKeeper dort nach fälschlich aussortierten Mails sucht."),
                String(localized: "Gmail geht auf zwei Wegen: mit App-Passwort (schnell, braucht die 2-Schritt-Verifizierung) oder mit Anmeldung über Google (braucht einmalig einen eigenen Google-Client – der Dialog führt in vier Schritten hindurch und verlinkt jede Seite bei Google). Passwörter und Anmeldungen liegen im Schlüsselbund, nie im Archiv."),
            ],
            keywords: String(localized: "postfach konto imap gmail proton bridge import passwort schlüsselbund spam ordner abrufen app-passwort google oauth client kürzel")),
        HelpChapter(
            id: "suchen", title: String(localized: "Suchen"), symbol: "magnifyingglass",
            paragraphs: [
                String(localized: "Ins Suchfeld tippen genügt: gesucht wird in Betreff, Absender, Empfänger, Text, Anhangsnamen und im Text von PDF-Anhängen."),
                String(localized: "Umlaute und ß sind egal — „mueller“ findet „Müller“, „Grüße“ findet „Grusse“."),
                String(localized: "Alles lässt sich einschränken: von: an: betreff: hat:pdf ist:ungelesen art:rechnung ab:30d — deutsch und englisch gleichwertig. Die vollständige Liste steht unter „Suchsprache …“ im Filter-Menü."),
                String(localized: "Ein Tippfehler in einem Feldwert bricht die Suche ab, statt mehr zu finden. Auf einer Treffermenge wird manchmal gelöscht — sie darf durch einen Vertipper nie größer werden."),
                String(localized: "Eine Suche, die du öfter brauchst, legst du über „Sichern …“ als Ansicht in der Seitenleiste ab."),
            ],
            keywords: String(localized: "suchen suche suchsprache feld umlaut ß ansicht sichern filter pdf volltext")),
        HelpChapter(
            id: "einordnen", title: String(localized: "Einordnen"), symbol: "tag",
            paragraphs: [
                String(localized: "Jede Mail bekommt eine von neun Arten. Sie ist nur ein Etikett — es folgt keine Aktion daraus."),
                String(localized: "Drei Stufen, von billig nach teuer: Regeln über die Kopfzeilen (dabei wird keine Mail gelesen), dann ähnliche Mails, dann ein Modell."),
                String(localized: "Vier Arten vergeben die eingebauten Regeln nie: Persönlich, Arbeit, Konto/Sicherheit und Spam. Eine Regel, die eine Phishing-Mail „Konto/Sicherheit“ nennt, würde ihr Glaubwürdigkeit verleihen. Eine Regel, die du selbst schreibst, darf jede Art setzen — für die stehst du gerade."),
                String(localized: "Deine Entscheidung schlägt alles und überlebt jeden Neuaufbau. „Warum?“ am Leser zeigt, was das Modell gesehen hat — und lässt dich jeden Eintrag dort vergessen."),
            ],
            keywords: String(localized: "einordnen art kategorie regeln ähnliche mails modell warum gedächtnis neun arten")),
        HelpChapter(
            id: "spam", title: String(localized: "Spam und Phishing"), symbol: "exclamationmark.shield",
            paragraphs: [
                String(localized: "MailKeeper hält drei Dinge auseinander: die Art (Spam ist eine davon), die Phishing-Stufe und dein Urteil. Ein Werbe-Newsletter ist Spam, aber kein Phishing; eine gefälschte Rechnung ist beides."),
                String(localized: "Entscheidend ist, wem geglaubt wird: Die Prüfergebnisse in einer Mail zählen nur, wenn dein eigener Server sie geschrieben hat. Jeder kann „dmarc=pass“ hineinschreiben — auch der Angreifer."),
                String(localized: "Links werden gelesen, nie abgerufen: Linktext gegen Ziel, nackte IP, Punycode, Kurz-URL. Ein Befund allein ist nie ein Urteil — Newsletter leiten ganz legitim über Zähl-Domains."),
                String(localized: "Das Beziehungsregister merkt sich, von welchen Domains Bank, Schule oder Händler dir wirklich schreiben. Eine Mail, die den Namen trägt und von woanders kommt, ist der klassische Angriff."),
                String(localized: "„Kein Spam“ holt eine echte Mail auf dem Server dorthin zurück, wo sie lag. Das ist wichtiger, als es aussieht: Spamfilter lernen aus dem Spam-Ordner."),
            ],
            keywords: String(localized: "spam phishing dmarc dkim server echtheit beziehung doppelgänger link abmelden kein spam")),
        HelpChapter(
            id: "aufraeumen", title: String(localized: "Aufräumen"), symbol: "trash",
            paragraphs: [
                String(localized: "Ein volles Postfach räumt man nach Absendern auf: Ansicht › Absender, Domains oder Listen. Ein hoher Anteil ungelesener Mails ist das deutlichste Zeichen."),
                String(localized: "Die Spalten „Server“ und „Nur Archiv“ zeigen je Gruppe, wie viele Mails noch auf dem Server liegen und wie viele nur noch im Archiv. Rechts steht dasselbe als zweifarbiger Balken. Die Knöpfe darunter sind Symbole; was sie tun, sagt der Tooltip."),
                String(localized: "Vier Wege: auf dem Server löschen (das Archiv behält alles), aus dem Archiv löschen (30 Tage Papierkorb), endgültig löschen (verlangt Touch ID oder dein Passwort) und abmelden."),
                String(localized: "Jede dieser Aktionen zeigt vorher den Plan: wie viele Mails, wie groß, was übersprungen wird und warum. Erst dein Klick startet etwas, und anhalten kannst du jederzeit."),
                String(localized: "Die Schonfrist (Standard 30 Tage) schützt neue Mail vor anderen Programmen, die dasselbe Postfach lesen."),
                String(localized: "„Ablage ändern“ ist etwas anderes als Löschen: Es bestimmt, wo das Archiv eine Mail führt — unabhängig davon, wo sie auf dem Server liegt."),
            ],
            keywords: String(localized: "aufräumen löschen server archiv papierkorb schonfrist zurückspielen export ablage regeln gruppen")),
        HelpChapter(
            id: "ki", title: String(localized: "Die KI"), symbol: "brain",
            paragraphs: [
                String(localized: "Es gibt keinen Cloud-Anbieter. Entweder ein Endpunkt, den du selbst betreibst (LiteLLM, Ollama, LM Studio), oder das Modell auf diesem Mac — oder gar keins."),
                String(localized: "In einer Anfrage stehen Betreff, Absender, einige Kopfzeilen, die Namen der Anhänge, die Link-Befunde und ein Auszug des Textes. Der Inhalt von Anhängen geht nie mit."),
                String(localized: "Protokolliert wird, dass eine Anfrage lief — nie der Prompt und nie die Antwort."),
                String(localized: "Was aus der Mail stammt, steht im Prompt eingezäunt; Aufforderungen darin werden entfernt und zählen als Warnzeichen. Ein Modell löst nie eine Aktion aus."),
                String(localized: "Die Bedeutungssuche und „Ähnliche Mails“ brauchen einen Endpunkt — das Mac-Modell kann keine Einbettungen."),
            ],
            keywords: String(localized: "ki ai modell endpunkt ollama lm studio litellm apple intelligence datenschutz prompt zaun embeddings")),
        HelpChapter(
            id: "sicherheit", title: String(localized: "Sicherheit"), symbol: "lock",
            paragraphs: [
                String(localized: "Das Archiv ist nicht verschlüsselt: Die Mails liegen als gewöhnliche .eml-Dateien da, damit sie ohne MailKeeper lesbar bleiben. Die Verschlüsselung kommt von FileVault — liegt das Archiv auf einem unverschlüsselten Laufwerk, sagt die Statusleiste das."),
                String(localized: "Passwörter, Google-Anmeldungen und API-Schlüssel liegen im Schlüsselbund, nie im Archiv."),
                String(localized: "Jede Server-Verbindung bekommt nur, was sie für ihre Aufgabe braucht. MailKeeper legt nie Ordner auf dem Server an."),
                String(localized: "Text aus PDF-Anhängen gewinnt ein eigener Prozess ohne Netz und ohne Dateizugriff."),
                String(localized: "Die Protokolle enthalten nur Metadaten — keine Inhalte."),
            ],
            keywords: String(localized: "sicherheit datenschutz verschlüsselung filevault schlüsselbund sandbox protokoll pdf")),
        HelpChapter(
            id: "tasten", title: String(localized: "Tastenkürzel"), symbol: "keyboard",
            paragraphs: [
                String(localized: "• ⌘R aktualisieren · ⇧⌘R neue Mails abrufen"),
                String(localized: "• ⌘⌫ aus dem Archiv löschen · ⇧⌘E Auswahl exportieren"),
                String(localized: "• ⌥⌘F Suchtext in Suchsprache übersetzen"),
                String(localized: "• ⌥⌘S Mail zusammenfassen · ⌥⇧⌘S Konversation zusammenfassen"),
                String(localized: "• ⌘[ zurück · ⌘] vorwärts · ⇧⌘O Archiv öffnen · ⌘, Einstellungen"),
                String(localized: "• ⌘? diese Hilfe"),
            ],
            keywords: String(localized: "tastenkürzel shortcuts tasten befehle")),
    ]
}

struct HelpWindow: View {
    @State private var selection: String? = HelpBook.chapters.first?.id
    @State private var search = ""

    private var shown: [HelpChapter] {
        let needle = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return HelpBook.chapters }
        return HelpBook.chapters.filter { $0.haystack.contains(needle) }
    }

    var body: some View {
        NavigationSplitView {
            List(shown, selection: $selection) { chapter in
                Label(chapter.title, systemImage: chapter.symbol).tag(chapter.id)
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 210)
            .searchable(text: $search, placement: .sidebar, prompt: Text("In der Hilfe suchen"))
            .overlay {
                if shown.isEmpty { ContentUnavailableView.search(text: search) }
            }
        } detail: {
            if let chapter = HelpBook.chapters.first(where: { $0.id == selection }) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(chapter.title).font(.title2.weight(.semibold))
                        if chapter.id == "server-archiv" { ServerArchiveDiagram().padding(.vertical, 4) }
                        ForEach(Array(chapter.paragraphs.enumerated()), id: \.offset) { _, paragraph in
                            Text(paragraph).fixedSize(horizontal: false, vertical: true)
                        }
                        Divider().padding(.top, 8)
                        Text("Ausführlich steht das alles im Handbuch — mit Beispielen und den Gründen dahinter.")
                            .font(.callout).foregroundStyle(.secondary)
                        Link("Handbuch öffnen", destination: HelpBook.handbook)
                    }
                    .padding(20)
                    .frame(maxWidth: 620, alignment: .leading)
                }
            } else {
                ContentUnavailableView("Kein Kapitel gewählt", systemImage: "book")
            }
        }
        .frame(minWidth: 740, minHeight: 460)
        .onChange(of: HelpFocus.shared.chapter, initial: true) { _, wanted in
            guard let wanted else { return }
            selection = wanted
            HelpFocus.shared.chapter = nil  // so the same chapter can be asked for again
        }
    }
}

/// Which chapter the help window should show. The menu sets it before opening the window; a
/// window that is already open picks it up through `onChange`.
@MainActor
@Observable
final class HelpFocus {
    static let shared = HelpFocus()
    var chapter: String?

    func show(_ chapter: String) { self.chapter = chapter }
}

/// The Help menu. A view, not bare `Commands`, so it can reach `openWindow`.
struct HelpMenuItems: View {
    let tour: IntroTour
    let setup: SetupAssistant
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("MailKeeper-Hilfe") { open(nil) }
            .keyboardShortcut("?", modifiers: .command)
        Button("Sicherheit und Datenschutz …") { open("sicherheit") }
        Divider()
        // separate, as on the first launch: the setup (archive, mailboxes) and the tour of the window
        Button("Einrichtung …") {
            guard tour.step != nil else { return setup.start() }
            // A running tour makes way. If its card is a sheet, the setup's sheet waits until
            // that one has gone: two sheet changes on one view in one update lose the second.
            let wasSheet = tour.sheet.wrappedValue != nil
            tour.finish(seen: true)
            guard wasSheet else { return setup.start() }
            Task { try? await Task.sleep(for: .milliseconds(400)); setup.start() }
        }
        .disabled(setup.isShown)
        Button("Rundgang zeigen") { tour.start() }
            .disabled(setup.isShown)
        Link("Handbuch öffnen …", destination: HelpBook.handbook)
    }

    private func open(_ chapter: String?) {
        HelpFocus.shared.chapter = chapter
        openWindow(id: "help")
    }
}
