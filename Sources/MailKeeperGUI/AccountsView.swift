import MailKeeperIMAP
import MailKeeperKit
import SwiftUI

/// Settings › Konten: configured accounts, add / test / remove.
struct AccountsSettings: View {
    let model: AppModel
    @State private var selection: String?
    @State private var adding = false
    @State private var removing: AccountConfig?
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
                        Label("Kein Passwort", systemImage: "key.slash").font(.caption).foregroundStyle(.orange)
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
        .confirmationDialog("Konto „\(removing.map { DisplayText.safe($0.displayName) } ?? "")“ entfernen?",
                            isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })) {
            Button("Entfernen und Passwort löschen", role: .destructive) {
                if let r = removing { model.removeAccount(r.id, deletePassword: true); selection = nil }
            }
            Button("Entfernen, Passwort behalten") {
                if let r = removing { model.removeAccount(r.id, deletePassword: false); selection = nil }
            }
        } message: {
            Text("Archivierte Mails bleiben erhalten. Das Passwort im Schlüsselbund gilt auch für andere Archive, die dieses Postfach abrufen.")
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

/// New account: kind, credentials, connection check, (bridge) certificate confirmation, save.
struct AddAccountSheet: View {
    let model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var kind: AccountConfig.Kind = .gmail
    @State private var id = ""
    @State private var user = ""
    @State private var password = ""
    @State private var host = ""
    @State private var port = "993"
    @State private var starttls = false
    @State private var include = ""
    @State private var check: ConnectionCheck?
    @State private var trusted = false
    @State private var working = false
    @State private var error: String?

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
            Form {
                TextField("Kürzel", text: $id, prompt: Text("z. B. gmail-privat"))
                TextField(kind == .imap ? "Benutzer" : "Adresse", text: $user)
                SecureField(kind == .gmail ? "App-Passwort" : (kind == .protonBridge ? "Bridge-Passwort" : "Passwort"), text: $password)
                if kind == .imap {
                    TextField("Server", text: $host)
                    Toggle("STARTTLS statt TLS", isOn: $starttls)
                }
                if kind != .gmail { TextField("Port", text: $port) }
                TextField("Nur diese Ordner", text: $include, prompt: Text("optional, kommagetrennt"))
            }
            .onChange(of: password) { check = nil; trusted = false }
            hint
            if let check { checkResult(check) }
            if let error { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
            HStack {
                if working { ProgressView().controlSize(.small) }
                Spacer()
                Button("Abbrechen") { dismiss() }.keyboardShortcut(.cancelAction)
                if check == nil {
                    Button("Verbinden und prüfen") { Task { await runCheck() } }
                        .keyboardShortcut(.defaultAction)
                        .disabled(working || !AccountConfig.isValidID(id) || user.isEmpty || password.isEmpty || (kind == .imap && host.isEmpty))
                } else {
                    Button("Speichern") { save() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(kind == .protonBridge && !trusted)
                }
            }
        }
        .padding(20)
        .frame(width: 520)
    }

    @ViewBuilder private var hint: some View {
        switch kind {
        case .gmail:
            Text("Gmail braucht ein App-Passwort (Google-Konto › Sicherheit › 2-Schritt-Verifizierung › App-Passwörter). Abgerufen wird „Alle Nachrichten“; Labels werden übernommen.")
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
        case .gmail: c = .gmail(id: id, address: user)
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

    private func runCheck() async {
        working = true
        error = nil
        defer { working = false }
        do {
            check = try await SyncCoordinator.check(config, password: password)
        } catch {
            self.error = "\(error)"
        }
    }

    private func save() {
        var c = config
        if kind == .protonBridge { c.security = .startTLSPinned(fingerprint: check?.certificateFingerprint) }
        do {
            try model.addAccount(c, password: password)
            dismiss()
        } catch {
            self.error = "\(error)"
        }
    }
}
