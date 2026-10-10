import Foundation
import MailKeeperIMAP
import MailKeeperKit

// mkctl — command line access to a MailKeeper archive (imports, search, maintenance).
// No dependencies; arguments are parsed by hand.

setvbuf(stdout, nil, _IOLBF, 0)

let usage = """
usage: mkctl [--archive <dir>] <command>

  init                                        create an empty archive
  import maildir <dir> --account <id>         import a Maildir tree (mbsync, Dovecot, Maildir++)
  import mbox <file> --account <id> [--mailbox <name>]
                                              import an mbox file (Google Takeout supported)
  import eml <dir> --account <id>             import a folder of .eml files
  stats                                       counts and sizes
  accounts                                    accounts and mailboxes
  search <query…> [--limit <n>]               search (newest first), e.g. from:amazon has:pdf after:2024
                                              fields: from to subject body filename sender has larger smaller
                                              after before until date account folder label list is on only msgid
  show <id>                                   one message: headers, locations, text
  account add gmail <address> --id <id>       add a Gmail account (app password, All Mail + labels)
  account add proton <address> --id <id> [--port 1143] [--trust <fingerprint>]
                                              add a Proton Mail Bridge account (local, pinned certificate)
  account add imap <user> --id <id> --host <host> [--port 993] [--starttls]
                                              add any IMAPS account
      common: [--name <display name>] [--include A,B] [--exclude A,B] [--with-junk-trash] [--password-stdin]
  account list | test <id> | remove <id> [--keep-password]
                                              manage accounts (remove keeps the archived mail)
  sync [<id>…]                                fetch new mail from all (or the given) accounts, read-only
  verify                                      re-hash every blob
  rebuild-index                               rebuild index.sqlite from blobs + journal

archive: --archive, else $MAILKEEPER_ARCHIVE, else ~/Library/Application Support/MailKeeper/Archive
"""

struct CLIError: Error, CustomStringConvertible {
    let description: String
}

var args = Array(CommandLine.arguments.dropFirst())

@MainActor func option(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    let v = args[i + 1]
    args.removeSubrange(i...(i + 1))
    return v
}

@MainActor func requireOption(_ name: String) throws -> String {
    guard let v = option(name) else { throw CLIError(description: "missing \(name)") }
    return v
}

@MainActor func archiveURL() -> URL {
    if let a = option("--archive") { return URL(fileURLWithPath: (a as NSString).expandingTildeInPath) }
    if let env = ProcessInfo.processInfo.environment["MAILKEEPER_ARCHIVE"] {
        return URL(fileURLWithPath: (env as NSString).expandingTildeInPath)
    }
    return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appending(path: "MailKeeper/Archive")
}

/// Mail content is untrusted: strip terminal control sequences (ANSI/OSC — window titles,
/// clipboard writes, cursor tricks) before printing. Keeps newline and tab.
func clean(_ s: String?) -> String {
    guard let s else { return "" }
    return String(String.UnicodeScalarView(DisplayText.safe(s).unicodeScalars.filter { c in
        c == "\n" || c == "\t" || !(c.value < 0x20 || c.value == 0x7F || (0x80...0x9F).contains(c.value))
    }))
}

/// Password without echo, or from stdin with --password-stdin (never as an argument).
@MainActor func readPassword(prompt: String) throws -> String {
    if args.contains("--password-stdin") {
        args.removeAll { $0 == "--password-stdin" }
        guard let line = readLine(strippingNewline: true), !line.isEmpty else { throw CLIError(description: "no password on stdin") }
        return line
    }
    var buffer = [CChar](repeating: 0, count: 1024)
    guard let p = readpassphrase(prompt, &buffer, buffer.count, 0) else { throw CLIError(description: "no password") }
    let password = String(cString: p)
    _ = buffer.withUnsafeMutableBytes { memset_s($0.baseAddress, $0.count, 0, $0.count) }
    guard !password.isEmpty else { throw CLIError(description: "empty password") }
    return password
}

@MainActor func confirm(_ question: String) -> Bool {
    guard isatty(STDIN_FILENO) == 1 else { return false }
    print(question + " [j/N] ", terminator: "")
    return ["j", "ja", "y", "yes"].contains(readLine()?.lowercased() ?? "")
}

func list(_ s: String?) -> [String]? {
    s.map { $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }
}

func syncLine(_ p: SyncProgress) -> String {
    let box = p.mailbox.map { " \(clean($0)) (\(p.mailboxIndex + 1)/\(p.mailboxCount))" } ?? ""
    switch p.phase {
    case .fetching: return "\r[\(p.account)]\(box) \(p.fetched)/\(p.toFetch) neu · \(bytes(p.bytes))      "
    case .flags: return "\r[\(p.account)]\(box) Flags abgleichen…                "
    case .deletions: return "\r[\(p.account)]\(box) Löschungen prüfen…               "
    default: return "\r[\(p.account)]\(box) \(p.phase.rawValue)…                    "
    }
}

func bytes(_ n: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: n, countStyle: .file)
}

func formatDate(_ d: Date?) -> String {
    guard let d else { return "—" }
    return d.formatted(.iso8601.year().month().day())
}

func progressPrinter(start: Date) -> @Sendable (ImportProgress) -> Void {
    { p in
        let secs = Date().timeIntervalSince(start)
        let rate = secs > 0 ? Double(p.messages) / secs : 0
        FileHandle.standardError.write(Data(String(
            format: "\r%7d messages  %@  new %d  +loc %d  same %d  failed %d  %.0f/s   ",
            p.messages, bytes(p.bytes), p.newMessages, p.newLocations, p.unchanged, p.failed, rate).utf8))
    }
}

func summarize(_ p: ImportProgress, start: Date) {
    FileHandle.standardError.write(Data("\n".utf8))
    print(String(format: "imported %d messages (%@) in %.1fs — new %d, new locations %d, unchanged %d, failed %d",
                 p.messages, bytes(p.bytes), Date().timeIntervalSince(start), p.newMessages, p.newLocations, p.unchanged, p.failed))
    if let e = p.lastError { print("last error: \(e)") }
}

@MainActor func run() async throws {
    let root = archiveURL()
    guard let command = args.first else { print(usage); return }
    args.removeFirst()

    switch command {
    case "init":
        let layout = try ArchiveLayout.open(at: root, create: true)
        print("archive ready at \(layout.root.path)")
        if layout.volumeIsEncrypted == false { print("warning: the volume is not encrypted") }

    case "import":
        guard let kind = args.first else { throw CLIError(description: "import what? maildir | mbox | eml") }
        args.removeFirst()
        let account = try requireOption("--account")
        let mailbox = option("--mailbox")
        guard let path = args.first else { throw CLIError(description: "missing source path") }
        let source = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        let layout = try ArchiveLayout.open(at: root, create: true)
        let writer = try ArchiveWriter(layout: layout)
        let start = Date()
        let progress = progressPrinter(start: start)
        let result: ImportProgress
        switch kind {
        case "maildir": result = try await MaildirImporter(root: source, account: account).run(writer: writer, progress: progress)
        case "mbox": result = try await MboxImporter(file: source, account: account, mailbox: mailbox).run(writer: writer, progress: progress)
        case "eml": result = try await EMLImporter(root: source, account: account).run(writer: writer, progress: progress)
        default: throw CLIError(description: "unknown import kind \(kind)")
        }
        summarize(result, start: start)

    case "stats":
        let reader = try ArchiveReader(layout: try ArchiveLayout.open(at: root, create: false))
        let s = try reader.stats()
        print("accounts \(s.accounts) · messages \(s.messages) · locations \(s.locations) · blobs \(s.blobs) (\(bytes(s.blobBytes)))")

    case "accounts":
        let reader = try ArchiveReader(layout: try ArchiveLayout.open(at: root, create: false))
        for a in try reader.accounts() {
            print("\(a.id) (\(a.kind)) — \(a.messageCount) messages")
            for m in a.mailboxes { print("    \(m.name)  \(m.count)") }
        }

    case "search":
        let limit = Int(option("--limit") ?? "25") ?? 25
        let terms = args.joined(separator: " ")
        guard !terms.isEmpty else { throw CLIError(description: "search terms missing") }
        let reader = try ArchiveReader(layout: try ArchiveLayout.open(at: root, create: false))
        let t0 = Date()
        let ids = try reader.messageIDs(MessageFilter(text: terms))
        let elapsed = Date().timeIntervalSince(t0)
        for m in try reader.summaries(Array(ids.prefix(limit))) {
            let id = String(m.id)
            let from = clean(m.fromDisplay).prefix(28).padding(toLength: 28, withPad: " ", startingAt: 0)
            print("\(String(repeating: " ", count: max(0, 7 - id.count)))\(id)  \(formatDate(m.date))  \(from)  \(clean(m.subject))")
        }
        print(String(format: "%d hits in %.3fs", ids.count, elapsed))

    case "show":
        guard let idText = args.first, let id = Int64(idText) else { throw CLIError(description: "show <id>") }
        let reader = try ArchiveReader(layout: try ArchiveLayout.open(at: root, create: false))
        guard let d = try reader.detail(id), let p = try reader.parsedMessage(id) else { throw CLIError(description: "no message \(id)") }
        print("Subject:    \(clean(p.subject))")
        print("From:       \(clean(p.from.map(\.display).joined(separator: ", ")))")
        print("To:         \(clean(p.to.map(\.display).joined(separator: ", ")))")
        print("Date:       \(p.date.map { $0.formatted() } ?? "—")")
        print("Message-ID: \(clean(d.messageID ?? "—"))")
        if let list = d.listID { print("List-Id:    \(clean(list))") }
        for a in p.attachments { print("Attachment: \(clean(a.filename ?? "(unnamed)")) — \(clean(a.mimeType)), \(bytes(Int64(a.size)))\(a.isInline ? " inline" : "")") }
        for l in d.locations {
            print(clean("Location:   \(l.account)/\(l.mailbox)\(l.uid.map { " uid \($0)" } ?? "") flags[\(l.flags.joined(separator: " "))]\(l.labels.isEmpty ? "" : " labels[\(l.labels.joined(separator: ", "))]") blob \(l.sha256.prefix(12))…"))
        }
        print("")
        print(clean(String(p.text.prefix(2000))))

    case "account":
        guard let sub = args.first else { throw CLIError(description: "account add|list|test|remove") }
        args.removeFirst()
        let layout = try ArchiveLayout.open(at: root, create: sub == "add")
        let store = AccountStore(layout: layout)
        let credentials = CredentialStore()
        switch sub {
        case "add":
            guard args.count >= 2 else { throw CLIError(description: "account add gmail|proton|imap <address/user> --id <id>") }
            let kind = args.removeFirst(), user = args.removeFirst()
            let id = try requireOption("--id")
            var config: AccountConfig
            switch kind {
            case "gmail": config = .gmail(id: id, address: user)
            case "proton": config = .protonBridge(id: id, address: user, port: Int(option("--port") ?? "1143") ?? 1143)
            case "imap":
                let host = try requireOption("--host")
                let starttls = args.contains("--starttls")
                args.removeAll { $0 == "--starttls" }
                config = .imap(id: id, username: user, host: host, port: Int(option("--port") ?? (starttls ? "143" : "993")) ?? 993,
                               security: starttls ? .startTLS : .tls)
            default: throw CLIError(description: "unknown account kind \(kind)")
            }
            if let name = option("--name") { config.displayName = name }
            config.policy.include = list(option("--include"))
            config.policy.exclude = list(option("--exclude")) ?? []
            if args.contains("--with-junk-trash") { config.policy.includeJunkAndTrash = true }
            let trust = option("--trust")
            guard AccountConfig.isValidID(id) else { throw AccountError.invalidID(id) }
            guard !(try store.load()).contains(where: { $0.id == id }) else { throw AccountError.duplicate(id) }
            let password = try readPassword(prompt: "Passwort für \(user): ")
            print("Verbinde mit \(config.host):\(config.port) …")
            let check = try await SyncCoordinator.check(config, password: password)
            if case .startTLSPinned = config.security {
                guard let fp = check.certificateFingerprint else { throw CLIError(description: "no certificate fingerprint") }
                print("Zertifikat der Bridge (SHA-256): \(fp)")
                if let trust, trust.lowercased() != fp { throw CLIError(description: "fingerprint does not match --trust") }
                if trust == nil, !confirm("Diesem Zertifikat vertrauen?") { throw CLIError(description: "certificate not confirmed") }
                config.security = .startTLSPinned(fingerprint: fp)
            }
            print("\(check.mailboxes.count) Postfächer, abgerufen werden \(check.selected.count):")
            for box in check.selected { print("    \(clean(box.name))") }
            try credentials.save(password, for: config)
            try store.add(config)
            print("Konto „\(id)“ angelegt. Abrufen mit: mkctl sync \(id)")
        case "list":
            for a in try store.load() {
                let pw = credentials.exists(for: a) ? "Passwort ✓" : "kein Passwort"
                print("\(a.id)  \(a.kind.rawValue)  \(clean(a.username)) @ \(a.host):\(a.port)  [\(a.policy.mode.rawValue)\(a.policy.include.map { " nur: " + $0.joined(separator: ", ") } ?? "")]  \(pw)")
            }
        case "test":
            guard let id = args.first, let a = try store.load().first(where: { $0.id == id }) else { throw CLIError(description: "account test <id>") }
            guard let password = try credentials.password(for: a) else { throw SyncError.noPassword(id) }
            let check = try await SyncCoordinator.check(a, password: password)
            print("Verbindung ok · \(check.mailboxes.count) Postfächer, abgerufen werden \(check.selected.count):")
            for box in check.selected { print("    \(clean(box.name))") }
        case "remove":
            let keep = args.contains("--keep-password")
            args.removeAll { $0 == "--keep-password" }
            guard let id = args.first, let a = try store.load().first(where: { $0.id == id }) else { throw CLIError(description: "account remove <id> [--keep-password]") }
            let shared = try store.load().contains { $0.id != id && CredentialStore.key(for: $0) == CredentialStore.key(for: a) }
            try store.remove(id)
            if !keep && !shared { try credentials.delete(for: a) }
            print("Konto „\(id)“ entfernt (archivierte Mails bleiben)" + (keep || shared ? ", Passwort behalten." : ", Passwort gelöscht — auch für andere Archive mit diesem Postfach."))
        default:
            throw CLIError(description: "account add|list|test|remove")
        }

    case "sync":
        let layout = try ArchiveLayout.open(at: root, create: false)
        let all = try AccountStore(layout: layout).load()
        let chosen = args.isEmpty ? all : all.filter { args.contains($0.id) }
        guard !chosen.isEmpty else { throw CLIError(description: "no accounts — add one with: mkctl account add …") }
        let writer = try ArchiveWriter(layout: layout)
        var failed = false
        for account in chosen {
            let start = Date()
            do {
                let r = try await SyncCoordinator.sync(account, writer: writer) { p in
                    FileHandle.standardError.write(Data(syncLine(p).utf8))
                }
                FileHandle.standardError.write(Data("\n".utf8))
                print(String(format: "[%@] %d Postfächer · %d neu (%@) · %d weitere Ablageorte · %d Flag-Änderungen · %d nicht mehr auf dem Server · %.1fs",
                             account.id, r.mailboxes, r.newMessages, bytes(r.bytes), r.newLocations, r.flagChanges, r.gone, Date().timeIntervalSince(start)))
                for f in r.failures { print("  Fehler: \(clean(f))"); failed = true }
            } catch {
                FileHandle.standardError.write(Data("\n".utf8))
                print("[\(account.id)] \(clean("\(error)"))")
                failed = true
            }
        }
        if failed { exit(1) }

    case "verify":
        let writer = try ArchiveWriter(layout: try ArchiveLayout.open(at: root, create: false))
        let bad = try await writer.verifyBlobs()
        print(bad.isEmpty ? "all blobs verified" : "\(bad.count) damaged blobs:\n" + bad.joined(separator: "\n"))
        if !bad.isEmpty { exit(1) }

    case "rebuild-index":
        let writer = try ArchiveWriter(layout: try ArchiveLayout.open(at: root, create: false))
        let start = Date()
        let r = try await writer.rebuildIndex { n in FileHandle.standardError.write(Data("\r\(n) locations".utf8)) }
        print(String(format: "\nrebuilt index: %d locations in %.1fs", r.locations, Date().timeIntervalSince(start)))
        if !r.missingBlobs.isEmpty { print("missing blobs (\(r.missingBlobs.count)):\n" + r.missingBlobs.joined(separator: "\n")) }
        if !r.damagedBlobs.isEmpty { print("damaged blobs (\(r.damagedBlobs.count)):\n" + r.damagedBlobs.joined(separator: "\n")) }
        if r.skippedEvents > 0 { print("skipped journal events: \(r.skippedEvents)") }
        if !r.missingBlobs.isEmpty || !r.damagedBlobs.isEmpty { exit(1) }

    case "help", "--help", "-h":
        print(usage)

    default:
        throw CLIError(description: "unknown command \(command)\n\n\(usage)")
    }
}

do {
    try await run()
} catch {
    FileHandle.standardError.write(Data("mkctl: \(error)\n".utf8))
    exit(1)
}
