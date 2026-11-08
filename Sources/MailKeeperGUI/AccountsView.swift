import MailKeeperIMAP
import MailKeeperKit
import SwiftUI

/// Settings › Konten: configured accounts, add / test / remove.
struct AccountsSettings: View {
    let model: AppModel
    @State private var selection: String?
    @State private var adding = false
    @State private var removing: AccountConfig?
    @State private var signingIn: AccountConfig?
    @State private var toPassword: AccountConfig?
    @State private var message: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // accounts belong to the archive (accounts.json in it): say which one (TJ)
            if model.hasArchive {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Konten in „\(model.currentArchiveName)“").font(.headline)
                    Text("Jedes Archiv hat eigene Konten. Das Archiv wechselst du über einen Klick auf den Fenstertitel oder Ablage › Archiv wechseln.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else if model.noArchiveYet {
                Label("Noch kein Archiv. Die Konten werden im Archiv gespeichert – leg zuerst eines an: Hilfe › Einrichtung … oder Ablage › Neues Archiv anlegen …",
                      systemImage: "archivebox")
                    .font(.callout).foregroundStyle(.orange)
            } else {
                Label("Das Archiv ist nicht geöffnet – seine Konten erscheinen, sobald es wieder erreichbar ist.", systemImage: "archivebox")
                    .font(.callout).foregroundStyle(.orange)
            }
            List(model.accountConfigs, selection: $selection) { account in
                HStack {
                    Image(systemName: Self.icon(account.kind)).frame(width: 20)
                    VStack(alignment: .leading) {
                        Text(DisplayText.safe(account.displayName))
                        Text("\(DisplayText.safe(account.username)) · \(account.host):\(account.port)\(account.policy.include.map { " · nur " + $0.joined(separator: ", ") } ?? "")")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Toggle("Spam prüfen", isOn: Binding(get: { account.policy.includeJunk }, set: { model.setSpamCheck(account.id, $0) }))
                        .toggleStyle(.checkbox).font(.caption)
                        .help(account.policy.include == nil
                              ? "Den Spam-Ordner mitlesen (nur lesend) und von der KI prüfen lassen"
                              : "Den Spam-Ordner mitlesen – bei diesem Konto nur, wenn er in der Ordnerauswahl steht")
                    if !model.hasPassword(account) {
                        Label(account.oauth == nil ? "Kein Passwort" : "Nicht angemeldet", systemImage: "key.slash")
                            .font(.caption).foregroundStyle(.orange)
                    } else if account.oauth != nil {
                        Label("Google", systemImage: "person.badge.key").font(.caption).foregroundStyle(.secondary)
                            .help("Meldet sich mit Google an (OAuth), nicht mit einem App-Passwort")
                    }
                }
                .tag(account.id)
            }
            .frame(minHeight: 180)
            HStack {
                Button { adding = true } label: { Image(systemName: "plus") }
                    .help("Konto hinzufügen")
                    .disabled(model.reader == nil)
                Button {
                    removing = model.accountConfigs.first { $0.id == selection }
                } label: { Image(systemName: "minus") }
                    .disabled(selection == nil)
                    .help("Konto entfernen (archivierte Mails bleiben)")
                if let gmail = model.accountConfigs.first(where: { $0.id == selection && $0.kind == .gmail }) {
                    Button(gmail.oauth == nil ? "Auf Google-Anmeldung umstellen …" : "Neu anmelden …") { signingIn = gmail }
                        .help(gmail.oauth == nil
                              ? "Statt des App-Passworts mit Google anmelden. Das Konto behält seine Kennung und sein Archiv."
                              : "Die Anmeldung bei Google erneuern (nach Passwortwechsel, Entzug oder abgelaufenem Zugriff)")
                    if gmail.oauth != nil {
                        Button("App-Passwort …") { toPassword = gmail }
                            .help("Wieder mit einem App-Passwort anmelden — der Weg zurück, falls die Google-Anmeldung nicht mehr geht")
                    }
                }
                Spacer()
                Button("Verbindung testen") {
                    guard let id = selection else { return }
                    message = String(localized: "Teste …")
                    Task { message = await model.testAccount(id) }
                }
                .disabled(selection == nil)
            }
            if let message {
                Text(message).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
            if let note = model.accountError {
                Text(DisplayText.safe(note)).font(.caption).foregroundStyle(.orange).textSelection(.enabled)
            }
            Text("Abgerufen wird nur lesend: MailKeeper verändert auf dem Server nichts. Was dort gelöscht oder verschoben wird, bleibt im Archiv. Passwörter liegen im Schlüsselbund, nicht im Archiv.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(width: 560, height: 430)
        .sheet(isPresented: $adding) { AddAccountSheet(model: model) }
        .sheet(item: $signingIn) { account in GoogleSignInSheet(model: model, account: account) }
        .sheet(item: $toPassword) { account in UsePasswordSheet(model: model, account: account) }
        .confirmationDialog("Konto „\(removing.map { DisplayText.safe($0.displayName) } ?? "")“ entfernen?",
                            isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })) {
            Button(removing?.oauth == nil ? "Entfernen und Passwort löschen"
                   : model.sharesMailbox(removing) ? "Entfernen (Anmeldung bleibt, anderes Konto nutzt sie)"
                   : "Entfernen und Google-Anmeldung widerrufen",
                   role: .destructive) {
                if let r = removing { selection = nil; Task { await model.removeAccount(r.id, deletePassword: true) } }
            }
            Button(removing?.oauth == nil ? "Entfernen, Passwort behalten" : "Entfernen, angemeldet bleiben") {
                if let r = removing { selection = nil; Task { await model.removeAccount(r.id, deletePassword: false) } }
            }
        } message: {
            Text(removing?.oauth == nil
                 ? "Archivierte Mails bleiben erhalten. Das Passwort im Schlüsselbund gilt auch für andere Archive, die dieses Postfach abrufen."
                 : "Archivierte Mails bleiben erhalten. Widerrufen meldet die Anmeldung auch bei Google ab — das gilt für jedes Archiv, das dieses Postfach mit dieser Anmeldung abruft.")
        }
    }

    static func icon(_ kind: AccountConfig.Kind) -> String {
        switch kind {
        case .gmail: "envelope.badge"
        case .protonBridge: "lock.shield"
        case .imap: "server.rack"
        }
    }
}

/// The Google client of an account and the sign-in itself (7.1, ADR-0012). The client belongs to
/// whoever runs MailKeeper: a Google Cloud project of their own, because `https://mail.google.com/`
/// is a restricted scope. A build that ships its own verified client fills the fields itself.
///
/// Laid out as numbered steps with the setup guide inside the dialog (TJ, 2026-11-08: "mir ist
/// selber nicht klar, was ich wo eingeben muss"). A pointer to a file in the repository is no
/// help to someone who only has the app.
struct GoogleClientFields: View {
    @Binding var clientID: String
    @Binding var clientSecret: String
    let address: String
    let signedIn: OAuthTokens?
    let working: Bool
    /// The client id the account already has (re-signing in): the guide to making one starts
    /// folded up, and the steps are not numbered.
    let storedClientID: String?
    /// Whether that client's secret is in this Mac's keychain. Not a given: the archive (with
    /// `accounts.json`) may come from another Mac, or `mkctl` added the account without one.
    let hasStoredSecret: Bool
    /// What comes after the sign-in in the sheet around these fields.
    let lastStep: LocalizedStringKey
    let signIn: () -> Void
    @State private var guideOpen: Bool

    init(clientID: Binding<String>, clientSecret: Binding<String>, address: String, signedIn: OAuthTokens?,
         working: Bool, storedClientID: String? = nil, hasStoredSecret: Bool = false,
         lastStep: LocalizedStringKey, signIn: @escaping () -> Void) {
        _clientID = clientID
        _clientSecret = clientSecret
        self.address = address
        self.signedIn = signedIn
        self.working = working
        self.storedClientID = storedClientID
        self.hasStoredSecret = hasStoredSecret
        self.lastStep = lastStep
        self.signIn = signIn
        _guideOpen = State(initialValue: storedClientID == nil)
    }

    private var knownClient: Bool { storedClientID != nil }

    /// An empty secret field may stand for the stored secret only while the id is still the
    /// stored one and that secret is really here — `OAuthTokens2Go.clientForSignIn` sends none
    /// otherwise, and Google answers "client_secret is missing" (review: Gmail dialog, S1).
    private var emptySecretMeansStored: Bool {
        hasStoredSecret && clientID.trimmingCharacters(in: .whitespacesAndNewlines) == storedClientID
    }

    /// No verified client ships with MailKeeper yet, so everyone brings their own.
    private var needsOwnClient: Bool { GoogleOAuth.builtInClient == nil }

    private var plausibleID: Bool {
        GoogleOAuth.isPlausibleClientID(clientID) || (clientID.isEmpty && GoogleOAuth.builtInClient != nil)
    }

    /// Step numbers only for someone who still has to make a client. Re-signing in with the
    /// client the account already has is one button, not a four-step procedure.
    private var numbered: Bool { needsOwnClient && !knownClient }

    var body: some View {
        Section {
            if numbered {
                LabeledContent {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Eigenen Google-Client anlegen – einmalig, etwa 10 Minuten.")
                            .fixedSize(horizontal: false, vertical: true)
                        DisclosureGroup("So geht’s", isExpanded: $guideOpen) { GoogleClientGuide() }
                    }
                } label: { Text("Schritt \(1)") }
                LabeledContent {
                    Text("Client-ID und Clientschlüssel einfügen – Google zeigt beide, sobald der Client erstellt ist.")
                        .fixedSize(horizontal: false, vertical: true)
                } label: { Text("Schritt \(2)") }
            } else if needsOwnClient {
                LabeledContent {
                    DisclosureGroup("Neuen Google-Client anlegen", isExpanded: $guideOpen) { GoogleClientGuide() }
                } label: { Text("Client") }
            }
            TextField("Client-ID", text: $clientID, prompt: Text("…apps.googleusercontent.com"))
                .textContentType(.none)
                // pasted and plausible: step 1 is done, fold the guide away (it is long). Only on
                // the change to plausible, so a guide opened again afterwards stays open.
                .onChange(of: GoogleOAuth.isPlausibleClientID(clientID)) { _, plausible in
                    if numbered && plausible { guideOpen = false }
                }
            SecureField("Clientschlüssel", text: $clientSecret,
                        prompt: emptySecretMeansStored ? Text("leer lassen = der gespeicherte") : Text("GOCSPX-…"))
            if !clientID.isEmpty && !plausibleID {
                Text("Das ist keine Client-ID – sie endet auf „.apps.googleusercontent.com“. Der Clientschlüssel gehört ins Feld darunter.")
                    .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            } else if knownClient && clientSecret.isEmpty && !emptySecretMeansStored && plausibleID {
                Text("Für diese Client-ID liegt auf diesem Mac kein Clientschlüssel – bitte eintragen.")
                    .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            LabeledContent {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Button(signedIn == nil ? "Mit Google anmelden …" : "Erneut anmelden …", action: signIn)
                            .disabled(working || !plausibleID)
                        if working { ProgressView().controlSize(.small) }
                        if let mail = signedIn?.email {
                            Label("angemeldet als \(DisplayText.safe(mail))", systemImage: "checkmark.circle")
                                .font(.caption).foregroundStyle(GoogleOAuth.sameMailbox(mail, address) || address.isEmpty ? .green : .orange)
                        } else if signedIn != nil {
                            Label("angemeldet", systemImage: "checkmark.circle").font(.caption).foregroundStyle(.green)
                        }
                    }
                    Text("Im Browser warnt Google „Google hat diese App nicht überprüft“ – bei deinem eigenen Client normal, weiter über „Erweitert“. Google fragt nach vollem Gmail-Zugriff, weil IMAP keinen kleineren kennt; MailKeeper ändert nur etwas, wenn du eine Aktion startest.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            } label: { numbered ? Text("Schritt \(3)") : Text("Anmelden") }
            LabeledContent {
                Text(lastStep).fixedSize(horizontal: false, vertical: true)
            } label: { numbered ? Text("Schritt \(4)") : Text("Danach") }
        }
    }
}

/// How to make the Google client, in the dialog itself: four steps, each linking straight to
/// its page in the Google Cloud console. Links survive Google's menu reshuffles better than menu
/// paths do (the consent screen became the "Google Auth Platform" in 2025): the consent screen
/// and the client use the old `apis/credentials/…` paths, which Google redirects into the new
/// pages; the audience page has no old path, so it links the new one. The links sit in the
/// text (Markdown) rather than on lines of their own: the sheet has to fit a laptop screen.
/// `Scripts/localize.sh` fails when a translation links elsewhere. The long version with the
/// reasons is docs/gmail-oauth.md.
struct GoogleClientGuide: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            item("a", "[Neues Projekt anlegen ↗](https://console.cloud.google.com/projectcreate), Name z. B. „MailKeeper“.")
            item("b", "Im Projekt die [Gmail-API aktivieren ↗](https://console.cloud.google.com/apis/library/gmail.googleapis.com).")
            item("c", "[Zustimmungsbildschirm ↗](https://console.cloud.google.com/apis/credentials/consent) einrichten: App-Name, deine Adresse, Zielgruppe „Extern“. Danach unter [„Zielgruppe“ ↗](https://console.cloud.google.com/auth/audience) die App veröffentlichen („In Produktion“) – im Testmodus läuft die Anmeldung nach 7 Tagen ab.")
            item("d", "[OAuth-Client erstellen ↗](https://console.cloud.google.com/apis/credentials/oauthclient): Anwendungstyp „Desktop-App“, Name beliebig. Google zeigt danach Client-ID und Clientschlüssel.")
            Text("Warum so? Vollen Gmail-Zugriff gibt Google nur Apps nach einer teuren Prüfung – oder deinem eigenen Client, der nur für dich gilt. [Ausführliche Anleitung ↗](https://github.com/tietjen/mailkeeper/blob/main/docs/gmail-oauth.md)")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .font(.caption)
        .padding(.top, 2)
    }

    private func item(_ mark: String, _ text: LocalizedStringKey) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(verbatim: mark).bold().foregroundStyle(.secondary)
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Signs an existing Gmail account in with Google — also the way from an app password to OAuth.
/// The account keeps its id, so its archived mail stays with it.
struct GoogleSignInSheet: View {
    let model: AppModel
    let account: AccountConfig
    @Environment(\.dismiss) private var dismiss
    @State private var clientID = ""
    @State private var clientSecret = ""
    @State private var tokens: OAuthTokens?
    @State private var working = false
    @State private var error: String?
    @State private var signingIn: Task<Void, Never>?
    @State private var check: ConnectionCheck?
    @State private var hasStoredSecret = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(account.oauth == nil ? "Auf Google-Anmeldung umstellen" : "Neu bei Google anmelden")
                .font(.title3.weight(.semibold))
            Text("Konto „\(DisplayText.safe(account.displayName))“ (\(DisplayText.safe(account.username)))")
                .font(.callout).foregroundStyle(.secondary)
            // columns, like the "add" sheet: the step numbers sit in the label column
            Form {
                GoogleClientFields(clientID: $clientID, clientSecret: $clientSecret, address: account.username,
                                   signedIn: tokens, working: working, storedClientID: account.oauth?.clientID,
                                   hasStoredSecret: hasStoredSecret,
                                   lastStep: "MailKeeper prüft die Verbindung von selbst. Ist sie in Ordnung, „Übernehmen“.") {
                    signingIn = Task { await run() }
                }
            }
            if account.oauth == nil {
                Text("Das App-Passwort bleibt im Schlüsselbund — MailKeeper benutzt es danach nicht mehr. Du kannst es bei Google widerrufen.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if let check {
                Label("Verbindung ok — abgerufen werden \(check.selected.count) von \(check.mailboxes.count) Postfächern",
                      systemImage: "checkmark.circle").font(.callout).foregroundStyle(.green)
            }
            if let error { Text(DisplayText.safe(error)).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
            HStack {
                Spacer()
                Button("Abbrechen") { cancel(); dismiss() }.keyboardShortcut(.cancelAction)
                Button("Übernehmen") { save() }.keyboardShortcut(.defaultAction).disabled(check == nil)
            }
        }
        .padding(20)
        .frame(width: 540)
        .onAppear {
            clientID = account.oauth?.clientID ?? GoogleOAuth.builtInClient?.id ?? ""
            hasStoredSecret = model.hasClientSecret(account)  // once, not a keychain query per render
        }
        .onDisappear { cancel() }
    }

    /// A sign-in nobody waits for any more is stopped. The token is dropped but **not** revoked:
    /// a revoke ends the whole grant of that Google account, and after a mismatch the token
    /// belongs to the account that was signed in — which may be another one of TJ's, still in
    /// use (Nachprüfung 7.1 S1). An unused grant costs an entry under "Verbundene Apps"; a wrong
    /// revoke costs a working account.
    private func cancel() {
        signingIn?.cancel()
        signingIn = nil
        tokens = nil
    }

    private func run() async {
        working = true
        error = nil
        check = nil
        defer { working = false }
        do {
            let client = OAuthTokens2Go.clientForSignIn(typedID: clientID, typedSecret: clientSecret, account: account)
            guard let client else { throw OAuthError.notConfigured(account.id) }
            let signedIn = try await GoogleSignIn.run(client: client, loginHint: account.username)
            if let mail = signedIn.email, !GoogleOAuth.sameMailbox(mail, account.username) {
                error = String(localized: "Angemeldet als \(DisplayText.safe(mail)) – das Konto ist \(DisplayText.safe(account.username)). Melde dich mit derselben Adresse an. Die Anmeldung bleibt bei Google stehen; dort kannst du sie unter „Verbundene Apps“ entfernen.")
                return
            }
            tokens = signedIn
            // the same proof the "add" sheet asks for: does Gmail let this token in? (review 7.1 C)
            check = try await SyncCoordinator.check(account, credential: .oauth2(accessToken: signedIn.accessToken))
        } catch {
            self.error = "\(error)"
        }
    }

    private func save() {
        guard let tokens, check != nil else { return }
        do {
            try model.signIn(account.id, clientID: clientID, clientSecret: clientSecret, tokens: tokens)
            self.tokens = nil  // saved: cancel() must not revoke it
            dismiss()
        } catch {
            self.error = "\(error)"
        }
    }
}

/// The way back from the Google sign-in to an app password (review 7.1): checked against the
/// server first, so nobody ends up with a account that can no longer fetch anything.
struct UsePasswordSheet: View {
    let model: AppModel
    let account: AccountConfig
    @Environment(\.dismiss) private var dismiss
    @State private var password = ""
    @State private var check: ConnectionCheck?
    @State private var working = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Wieder mit App-Passwort anmelden").font(.title3.weight(.semibold))
            Text("Konto „\(DisplayText.safe(account.displayName))“ (\(DisplayText.safe(account.username)))")
                .font(.callout).foregroundStyle(.secondary)
            Form {
                SecureField("App-Passwort", text: $password)
                Text("Google-Konto › Sicherheit › 2-Schritt-Verifizierung › App-Passwörter. Die Google-Anmeldung bleibt im Schlüsselbund stehen — ein anderes Archiv könnte sie noch nutzen; widerrufen wird sie bei Google unter „Verbundene Apps“.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .formStyle(.grouped)
            if let check {
                Label("Verbindung ok — abgerufen werden \(check.selected.count) von \(check.mailboxes.count) Postfächern",
                      systemImage: "checkmark.circle").font(.callout).foregroundStyle(.green)
            }
            if let error { Text(DisplayText.safe(error)).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
            HStack {
                if working { ProgressView().controlSize(.small) }
                Spacer()
                Button("Abbrechen") { dismiss() }.keyboardShortcut(.cancelAction)
                if check == nil {
                    Button("Verbinden und prüfen") { Task { await run() } }
                        .keyboardShortcut(.defaultAction).disabled(working || password.isEmpty)
                } else {
                    Button("Übernehmen") { save() }.keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(20)
        .frame(width: 520)
        .onChange(of: password) { check = nil }
    }

    private var withPassword: AccountConfig {
        var c = account
        c.oauth = nil
        return c
    }

    private func run() async {
        working = true
        error = nil
        defer { working = false }
        do {
            check = try await SyncCoordinator.check(withPassword, password: password)
        } catch {
            self.error = "\(error)"
        }
    }

    private func save() {
        do {
            try model.usePassword(account.id, password: password)
            dismiss()
        } catch {
            self.error = "\(error)"
        }
    }
}

/// Runs the browser sign-in from the GUI.
enum GoogleSignIn {
    static func run(client: (id: String, secret: String?), loginHint: String) async throws -> OAuthTokens {
        try await GoogleOAuth.signIn(clientID: client.id, clientSecret: client.secret, loginHint: loginHint) { url in
            NSWorkspace.shared.open(url)
        }
    }
}

/// New account: kind, credentials, connection check, (bridge) certificate confirmation, save.
struct AddAccountSheet: View {
    let model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var kind: AccountConfig.Kind = .gmail
    @State private var id = ""
    @State private var user = ""
    @State private var password = ""
    /// Gmail: sign in with Google (7.1) or use an app password. Google is the default only once
    /// MailKeeper ships a verified client of its own — until then the user needs theirs.
    @State private var withGoogle = GoogleOAuth.builtInClient != nil
    @State private var clientID = ""
    @State private var clientSecret = ""
    @State private var tokens: OAuthTokens?
    @State private var host = ""
    @State private var port = "993"
    @State private var starttls = false
    @State private var include = ""
    @State private var check: ConnectionCheck?
    @State private var trusted = false
    @State private var working = false
    @State private var error: String?
    @State private var signingIn: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Konto hinzufügen").font(.headline)
            Picker("Art", selection: $kind) {
                Text("Gmail").tag(AccountConfig.Kind.gmail)
                Text("Proton Mail Bridge").tag(AccountConfig.Kind.protonBridge)
                Text("IMAP").tag(AccountConfig.Kind.imap)
            }
            .pickerStyle(.segmented)
            .onChange(of: kind) { reset(); port = kind == .protonBridge ? "1143" : "993" }
            if kind == .gmail {
                Picker("Anmeldung", selection: $withGoogle) {
                    Text("App-Passwort").tag(false)
                    Text("Mit Google anmelden").tag(true)
                }
                .pickerStyle(.segmented)
                .onChange(of: withGoogle) { reset(); tokens = nil }
                // which way to take, before anything is typed (TJ, 2026-11-08)
                Text(signInIntro).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Form {
                TextField("Kürzel", text: $id, prompt: Text("z. B. gmail-privat"))
                Text("Der Name des Kontos in MailKeeper; er benennt die Ordner im Archiv. Kleinbuchstaben, Ziffern, „-“ und „_“ – später nicht änderbar.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                TextField(kind == .imap ? "Benutzer" : "Adresse", text: $user,
                          prompt: kind == .gmail ? Text("du@gmail.com") : nil)
                if !google {
                    SecureField(passwordLabel, text: $password,
                                prompt: kind == .gmail ? Text("16 Zeichen von Google") : nil)
                    if kind == .gmail {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Erzeugen unter Google-Konto › Sicherheit › 2-Schritt-Verifizierung › App-Passwörter. Google zeigt es nur einmal; die Leerzeichen darfst du mitkopieren.")
                                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            Link("App-Passwort bei Google erzeugen ↗", destination: Self.appPasswords)
                        }
                        .font(.caption)
                    }
                }
                if kind == .imap {
                    TextField("Server", text: $host)
                    Toggle("STARTTLS statt TLS", isOn: $starttls)
                }
                if kind != .gmail { TextField("Port", text: $port) }
                TextField("Nur diese Ordner", text: $include, prompt: Text("leer lassen = alle"))
                    .help("Nur diese Ordner abrufen, mit Komma getrennt, z. B. „INBOX, Archiv“. Leer lassen ruft alle ab.")
                if google {
                    GoogleClientFields(clientID: $clientID, clientSecret: $clientSecret, address: user,
                                       signedIn: tokens, working: working,
                                       lastStep: "Unten „Verbinden und prüfen“, dann „Speichern“.") {
                        signingIn = Task { await googleSignIn() }
                    }
                }
            }
            .onChange(of: password) { check = nil; trusted = false }
            hint
            if let check { checkResult(check) }
            if let error { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
            HStack {
                if working {
                    ProgressView().controlSize(.small)
                } else if check == nil, let missing {
                    // a greyed-out button alone does not say why (TJ, 2026-11-08)
                    Text(missing).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer()
                Button("Abbrechen") { cancelSignIn(); dismiss() }.keyboardShortcut(.cancelAction)
                if check == nil {
                    Button("Verbinden und prüfen") { Task { await runCheck() } }
                        .keyboardShortcut(.defaultAction)
                        .disabled(working || !blockers.isEmpty)
                } else {
                    Button("Speichern") { save() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(kind == .protonBridge && !trusted)
                }
            }
        }
        .padding(20)
        .frame(width: 520)
        .onAppear { if clientID.isEmpty { clientID = GoogleOAuth.builtInClient?.id ?? "" } }
        .onDisappear { cancelSignIn() }
    }

    /// Gmail with Google sign-in (an app password stays possible; the other kinds have none).
    private var google: Bool { kind == .gmail && withGoogle }

    static let appPasswords = URL(string: "https://myaccount.google.com/apppasswords")!

    /// The two Gmail ways side by side: what each costs, so the choice is made knowingly.
    private var signInIntro: LocalizedStringKey {
        if !withGoogle {
            return "Der schnelle Weg, etwa 2 Minuten: In deinem Google-Konto ein App-Passwort erzeugen und unten eintragen. Voraussetzung ist die 2-Schritt-Verifizierung."
        }
        if GoogleOAuth.builtInClient != nil {
            return "Du meldest dich im Browser bei Google an. MailKeeper bekommt ein Token, nie dein Passwort."
        }
        return "Ohne Passwort, aber mit Vorarbeit: Du legst einmalig einen eigenen Google-Client an, etwa 10 Minuten. Wer schnell loslegen will, nimmt das App-Passwort – umstellen geht später jederzeit."
    }

    private var passwordLabel: LocalizedStringKey {
        kind == .gmail ? "App-Passwort" : (kind == .protonBridge ? "Bridge-Passwort" : "Passwort")
    }

    /// What keeps "Verbinden und prüfen" greyed out. The button's `disabled` and the text next to
    /// it both read this, so they cannot drift apart when a field is added.
    private var blockers: [String] {
        var parts: [String] = []
        if id.isEmpty {
            parts.append(String(localized: "Kürzel"))
        } else if !AccountConfig.isValidID(id) {
            parts.append(String(localized: "ein gültiges Kürzel"))
        }
        if user.isEmpty { parts.append(kind == .imap ? String(localized: "Benutzer") : String(localized: "Adresse")) }
        if kind == .imap && host.isEmpty { parts.append(String(localized: "Server")) }
        if google {
            if tokens == nil { parts.append(String(localized: "die Anmeldung bei Google")) }
        } else if password.isEmpty {
            parts.append(kind == .gmail ? String(localized: "App-Passwort")
                         : kind == .protonBridge ? String(localized: "Bridge-Passwort") : String(localized: "Passwort"))
        }
        return parts
    }

    private var missing: String? {
        blockers.isEmpty ? nil : String(localized: "Es fehlt noch: \(blockers.formatted(.list(type: .and)))")
    }

    @ViewBuilder private var hint: some View {
        switch kind {
        case .gmail:
            Text("Abgerufen wird „Alle Nachrichten“; Labels werden übernommen.")
                .font(.caption).foregroundStyle(.secondary)
        case .protonBridge:
            Text("Die Proton Mail Bridge muss auf diesem Mac laufen. Benutze das Passwort, das die Bridge anzeigt — nicht dein Proton-Passwort.")
                .font(.caption).foregroundStyle(.secondary)
        case .imap:
            Text("Postfächer „Spam“ und „Papierkorb“ werden nicht abgerufen.").font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private func checkResult(_ c: ConnectionCheck) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Verbindung ok — \(c.mailboxes.count) Postfächer, abgerufen werden \(c.selected.count)", systemImage: "checkmark.circle")
                .foregroundStyle(.green)
            Text(c.selected.map { DisplayText.safe($0.name) }.joined(separator: " · "))
                .font(.caption).foregroundStyle(.secondary).lineLimit(3)
            if kind == .protonBridge, let fp = c.certificateFingerprint {
                Text("Zertifikat der Bridge (SHA-256):").font(.caption)
                Text(fp).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                Toggle("Diesem Zertifikat vertrauen", isOn: $trusted)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary))
    }

    private var config: AccountConfig {
        let portNumber = Int(port) ?? (kind == .protonBridge ? 1143 : 993)
        var c: AccountConfig
        switch kind {
        case .gmail:
            c = .gmail(id: id, address: user)
            if withGoogle { c.oauth = AccountConfig.OAuth(clientID: OAuthTokens2Go.storedClientID(clientID)) }
        case .protonBridge: c = .protonBridge(id: id, address: user, port: portNumber)
        case .imap: c = .imap(id: id, username: user, host: host, port: portNumber, security: starttls ? .startTLS : .tls)
        }
        let folders = include.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        c.policy.include = folders.isEmpty ? nil : folders
        return c
    }

    private func reset() {
        check = nil
        trusted = false
        error = nil
    }

    private func googleSignIn() async {
        working = true
        error = nil
        check = nil
        defer { working = false }
        do {
            guard let client = OAuthTokens2Go.clientForSignIn(typedID: clientID, typedSecret: clientSecret, account: nil) else {
                throw OAuthError.notConfigured(id)
            }
            let signedIn = try await GoogleSignIn.run(client: client, loginHint: user)
            tokens = signedIn
            if user.isEmpty, let mail = signedIn.email { user = mail }
        } catch {
            self.error = "\(error)"
        }
    }

    /// A sign-in nobody waits for any more is stopped. The token is dropped, not revoked — see
    /// `GoogleSignInSheet.cancel()`.
    private func cancelSignIn() {
        signingIn?.cancel()
        signingIn = nil
        tokens = nil
    }

    private func runCheck() async {
        working = true
        error = nil
        defer { working = false }
        if google, let mail = tokens?.email, !GoogleOAuth.sameMailbox(mail, user) {
            error = String(localized: "Angemeldet als \(DisplayText.safe(mail)) – eingerichtet wird \(DisplayText.safe(user)). Melde dich mit derselben Adresse an. Die Anmeldung bleibt bei Google stehen; dort kannst du sie unter „Verbundene Apps“ entfernen.")
            return
        }
        do {
            let credential: IMAPCredential = if let tokens, google { .oauth2(accessToken: tokens.accessToken) }
                                             else { .password(config.normalizedPassword(password)) }
            check = try await SyncCoordinator.check(config, credential: credential)
        } catch {
            self.error = "\(error)"
        }
    }

    private func save() {
        var c = config
        if kind == .protonBridge { c.security = .startTLSPinned(fingerprint: check?.certificateFingerprint) }
        do {
            if google, let tokens {
                try model.addAccount(c, tokens: tokens, clientSecret: clientSecret)
                self.tokens = nil  // saved: cancelSignIn() must not revoke it
            } else {
                try model.addAccount(c, password: password)
            }
            dismiss()
        } catch {
            self.error = "\(error)"
        }
    }
}
