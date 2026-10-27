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
            List(model.accountConfigs, selection: $selection) { account in
                HStack {
                    Image(systemName: icon(account.kind)).frame(width: 20)
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
            Text("Abgerufen wird nur lesend: MailKeeper verändert auf dem Server nichts. Passwörter liegen im Schlüsselbund, nicht im Archiv.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(width: 560, height: 380)
        .sheet(isPresented: $adding) { AddAccountSheet(model: model) }
        .sheet(item: $signingIn) { account in GoogleSignInSheet(model: model, account: account) }
        .sheet(item: $toPassword) { account in UsePasswordSheet(model: model, account: account) }
        .confirmationDialog("Konto „\(removing.map { DisplayText.safe($0.displayName) } ?? "")“ entfernen?",
                            isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })) {
            Button(removing?.oauth == nil ? "Entfernen und Passwort löschen" : "Entfernen und Google-Anmeldung widerrufen",
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

    private func icon(_ kind: AccountConfig.Kind) -> String {
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
struct GoogleClientFields: View {
    @Binding var clientID: String
    @Binding var clientSecret: String
    let address: String
    let signedIn: OAuthTokens?
    let working: Bool
    let signIn: () -> Void

    var body: some View {
        Section("Google-Anmeldung") {
            TextField("Client-ID", text: $clientID, prompt: Text("…apps.googleusercontent.com"))
                .textContentType(.none)
            SecureField("Client-Secret", text: $clientSecret, prompt: Text("falls dein Client eines hat"))
            HStack {
                Button(signedIn == nil ? "Mit Google anmelden …" : "Erneut anmelden …", action: signIn)
                    .disabled(working || !(GoogleOAuth.isPlausibleClientID(clientID)
                                           || (clientID.isEmpty && GoogleOAuth.builtInClient != nil)))
                if working { ProgressView().controlSize(.small) }
                if let mail = signedIn?.email {
                    Label("angemeldet als \(DisplayText.safe(mail))", systemImage: "checkmark.circle")
                        .font(.caption).foregroundStyle(mail.lowercased() == address.lowercased() ? .green : .orange)
                } else if signedIn != nil {
                    Label("angemeldet", systemImage: "checkmark.circle").font(.caption).foregroundStyle(.green)
                }
            }
            Text("MailKeeper nutzt deinen eigenen Google-Cloud-Client (Typ „Desktop“, Gmail-API aktiviert, Zustimmungsbildschirm auf „In Produktion“ — im Testmodus läuft die Anmeldung nach 7 Tagen ab). Die Anleitung steht in docs/gmail-oauth.md. Dein Passwort sieht MailKeeper nie; im Schlüsselbund liegt nur das Google-Token.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
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

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(account.oauth == nil ? "Auf Google-Anmeldung umstellen" : "Neu bei Google anmelden")
                .font(.title3.weight(.semibold))
            Text("Konto „\(DisplayText.safe(account.displayName))“ (\(DisplayText.safe(account.username)))")
                .font(.callout).foregroundStyle(.secondary)
            Form {
                GoogleClientFields(clientID: $clientID, clientSecret: $clientSecret, address: account.username,
                                   signedIn: tokens, working: working) { signingIn = Task { await run() } }
            }
            .formStyle(.grouped)
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
        }
        .onDisappear { cancel() }
    }

    /// A sign-in nobody waits for any more is stopped. A token that was fetched but never saved
    /// is handed back to Google only when nothing is stored for this mailbox — a revoke ends the
    /// whole grant, so cancelling must never cost the account its working sign-in
    /// (Nachprüfung 7.1 B1).
    private func cancel() {
        signingIn?.cancel()
        signingIn = nil
        guard let spare = tokens?.refreshToken else { return }
        tokens = nil
        let account = account
        Task { if await !model.hasStoredSignIn(account) { await GoogleOAuth.revoke(spare) } }
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
                error = String(localized: "Angemeldet als \(DisplayText.safe(mail)) – das Konto ist \(DisplayText.safe(account.username)). Melde dich mit derselben Adresse an.")
                if let spare = signedIn.refreshToken, !model.hasStoredSignIn(account) { await GoogleOAuth.revoke(spare) }
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
            }
            Form {
                TextField("Kürzel", text: $id, prompt: Text("z. B. gmail-privat"))
                TextField(kind == .imap ? "Benutzer" : "Adresse", text: $user)
                if !google {
                    SecureField(kind == .gmail ? "App-Passwort" : (kind == .protonBridge ? "Bridge-Passwort" : "Passwort"), text: $password)
                }
                if kind == .imap {
                    TextField("Server", text: $host)
                    Toggle("STARTTLS statt TLS", isOn: $starttls)
                }
                if kind != .gmail { TextField("Port", text: $port) }
                TextField("Nur diese Ordner", text: $include, prompt: Text("optional, kommagetrennt"))
                if google {
                    GoogleClientFields(clientID: $clientID, clientSecret: $clientSecret, address: user,
                                       signedIn: tokens, working: working) {
                        signingIn = Task { await googleSignIn() }
                    }
                }
            }
            .onChange(of: password) { check = nil; trusted = false }
            hint
            if let check { checkResult(check) }
            if let error { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
            HStack {
                if working { ProgressView().controlSize(.small) }
                Spacer()
                Button("Abbrechen") { cancelSignIn(); dismiss() }.keyboardShortcut(.cancelAction)
                if check == nil {
                    Button("Verbinden und prüfen") { Task { await runCheck() } }
                        .keyboardShortcut(.defaultAction)
                        .disabled(working || !AccountConfig.isValidID(id) || user.isEmpty || (kind == .imap && host.isEmpty)
                                  || (google ? tokens == nil : password.isEmpty))
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

    @ViewBuilder private var hint: some View {
        switch kind {
        case .gmail:
            Text(withGoogle
                 ? "Abgerufen wird „Alle Nachrichten“; Labels werden übernommen. MailKeeper fragt Google nur nach dem Zugriff auf deine Mails."
                 : "Gmail braucht ein App-Passwort (Google-Konto › Sicherheit › 2-Schritt-Verifizierung › App-Passwörter). Abgerufen wird „Alle Nachrichten“; Labels werden übernommen.")
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

    /// A sign-in nobody waits for any more is stopped; a token of an account that was never
    /// saved goes back to Google (nothing is stored for it, so no working grant is at stake).
    private func cancelSignIn() {
        signingIn?.cancel()
        signingIn = nil
        guard let spare = tokens?.refreshToken else { return }
        tokens = nil
        let candidate = config
        Task { if await !model.hasStoredSignIn(candidate) { await GoogleOAuth.revoke(spare) } }
    }

    private func runCheck() async {
        working = true
        error = nil
        defer { working = false }
        if google, let mail = tokens?.email, !GoogleOAuth.sameMailbox(mail, user) {
            error = String(localized: "Angemeldet als \(DisplayText.safe(mail)) – eingerichtet wird \(DisplayText.safe(user)). Melde dich mit derselben Adresse an.")
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
