import Foundation
import MailKeeperAI
import MailKeeperIMAP
import MailKeeperKit

// mkctl — command line access to a MailKeeper archive (imports, search, maintenance).
// No dependencies; arguments are parsed by hand.

// Glibc's `stdout` is a mutable global that Swift 6 refuses to read, hence fflush(nil) (all
// streams) below. On Linux progress lines are flushed one by one, the rest at exit.
#if !canImport(Glibc)
setvbuf(stdout, nil, _IOLBF, 0)
#endif

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
  groups [--by sender|domain|list] [--limit n] [query…]
                                              cleanup view: largest groups (of the query's messages)
  plan server-delete <query…> [--grace <d>]  dry run: what deleting on the server would do (nothing changes)
  server-delete <query…> [--grace <d>] [--yes]
                                              move to the server's Trash (archive keeps them; asks first)
  plan restore <query…> [--to <account>:<mailbox>] [--now]
                                              dry run: what restoring to the server would do
  restore <query…> [--to <account>:<mailbox>] [--now] [--yes]
                                              upload from the archive back to where it was (or --to);
                                              --now: arrival date today instead of the original
  export (<query…> | --all) (--eml <dir> | --mbox <file>)
                                              write messages out: one .eml each (exact bytes, never
                                              overwrites) or one mbox (mboxrd); blobs verified first
  show <id> [--headers]                                   one message: headers, locations, text
  account add gmail <address> --id <id> [--google | --google-client-id <id>] [--google-client-secret]
                                              add a Gmail account (All Mail + labels); with a
                                              client id: sign in with Google instead of a password
  account add proton <address> --id <id> [--port 1143] [--trust <fingerprint>]
                                              add a Proton Mail Bridge account (local, pinned certificate)
  account add imap <user> --id <id> --host <host> [--port 993] [--starttls]
                                              add any IMAPS account
      common: [--name <display name>] [--include A,B] [--exclude A,B] [--with-junk-trash] [--password-stdin]
  account list | test <id> | remove <id> [--keep-password]
  account signin <id> [--google-client-id <id>] [--google-client-secret]
                                              Gmail: sign in with Google (also: switch over)
  account password <id>                       Gmail: back to an app password
                                              manage accounts (remove keeps the archived mail)
  sync [<id>…]                                fetch new mail from all (or the given) accounts, read-only
  ask <everyday language…>                    KI: translate into the search language (shown, then counted)
  classify [--ai [--limit n] <query…>]        categories: rules for all messages; --ai asks the model about open ones
  embed                                       vectors for semantic search (endpoint), then categories from similar mails
  similar <id> [--limit n] | meaning <text…>  mails like a message / by meaning (needs embed)
  summarize <id> [--thread]                   KI: summary of a message or its whole conversation
  relations [list | suggest [--limit N]]                   relationship register: confirmed ones, or suggestions from the history
  gold [status | candidates [--limit N] | run [--no-ai]]    the private gold set: labels, what comes next, a measurement (6.6)
  unsubscribe [query] [--limit N] [--dkim]              how "Abmelden" judges the newest list mails (read-only)
  cleanup                                     cleanup suggestions: where deleting pays off (read-only)
  rules [list | suggest]                      the user's rules (with what is ready), or suggestions from repeated decisions
  memory [list | note <text…> | term <text…> | forget <id>… | export [file] | import <file>]
      note/term: [--about <sender|domain|list>] [--account <id>]
                                              what MailKeeper learned: notes, terms, examples from your decisions
  ai status | test                            KI settings of the archive; connection test (endpoint, on-device)
  ai config [--on|--off] [--endpoint <url>] [--model <task>=<alias>]… [--on-device on|off]
                                              tasks: search classify summarize embed
  ai key [--password-stdin] | ai key --delete API key of the endpoint (keychain, never an argument)
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
    #if canImport(Glibc)
    // No readpassphrase on Linux; a server takes secrets from stdin, never from a prompt.
    throw CLIError(description: "no password prompt on Linux: pass it with --password-stdin")
    #else
    var buffer = [CChar](repeating: 0, count: 1024)
    guard let p = readpassphrase(prompt, &buffer, buffer.count, 0) else { throw CLIError(description: "no password") }
    let password = String(cString: p)
    _ = buffer.withUnsafeMutableBytes { memset_s($0.baseAddress, $0.count, 0, $0.count) }
    guard !password.isEmpty else { throw CLIError(description: "empty password") }
    return password
    #endif
}

/// Signs in with Google in the user's browser (7.1): prints the address as well, in case the
/// terminal is on a machine whose browser does not open by itself.
@MainActor func signInWithGoogle(client: (id: String, secret: String?), loginHint: String) async throws -> OAuthTokens {
    guard GoogleOAuth.isPlausibleClientID(client.id) else {
        throw CLIError(description: "Das sieht nicht nach einer Google-Client-ID aus (…apps.googleusercontent.com)")
    }
    return try await GoogleOAuth.signIn(clientID: client.id, clientSecret: client.secret, loginHint: loginHint) { url in
        FileHandle.standardError.write(Data("Im Browser anmelden:\n\(url.absoluteString)\n".utf8))
        let open = Process()
        open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        open.arguments = [url.absoluteString]
        try? open.run()
    }
}

/// `--to account:mailbox` (the mailbox may contain colons) and `--now`.
@MainActor func restoreOptions() throws -> RestoreOptions {
    let now = args.contains("--now")
    args.removeAll { $0 == "--now" }
    guard let to = option("--to") else { return RestoreOptions(destination: .original, keepDate: !now) }
    guard let colon = to.firstIndex(of: ":"), colon != to.startIndex, to.index(after: colon) != to.endIndex else {
        throw CLIError(description: "--to <account>:<mailbox>")
    }
    return RestoreOptions(destination: .mailbox(account: String(to[..<colon]), mailbox: String(to[to.index(after: colon)...])),
                          keepDate: !now)
}

@MainActor func printRestorePlan(_ job: ActionJob, _ summary: ActionPlanSummary) {
    print("\(summary.messages) messages · \(summary.archiveOnly) on no server")
    print("would upload: \(job.count(.planned)) (\(bytes(job.openBytes)))"
          + (summary.perAccount.isEmpty ? "" : " — " + summary.perAccount.sorted { $0.key < $1.key }.map { "\(clean($0.key)) \($0.value)" }.joined(separator: ", ")))
    for (reason, count) in job.reasons { print("skipped \(count): \(reason)") }
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
        let t = try reader.attachmentTextStats()
        if t.withPDF > 0 {
            let parts = AttachmentText.Status.allCases.compactMap { st in t.byStatus[st].map { "\(st.rawValue) \($0)" } }
            print("pdf text: \(t.withPDF) messages with PDF · " + (parts + ["pending \(t.pending)"]).joined(separator: " · ")
                  + (t.pending > 0 ? " (the app extracts them, ADR-0009)" : ""))
        }

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

    case "groups":
        let limit = Int(option("--limit") ?? "30") ?? 30
        guard let mode = GroupMode(rawValue: option("--by") ?? "sender") else { throw CLIError(description: "--by sender | domain | list") }
        let query = args.joined(separator: " ")
        let reader = try ArchiveReader(layout: try ArchiveLayout.open(at: root, create: false))
        let t0 = Date()
        let groups = try reader.groups(MessageFilter(text: query.isEmpty ? nil : query), by: mode, limit: limit)
        let elapsed = Date().timeIntervalSince(t0)
        for g in groups {
            let unread = g.count > 0 ? g.unread * 100 / g.count : 0
            let count = String(g.count).padding(toLength: 6, withPad: " ", startingAt: 0)
            let size = bytes(g.bytes).padding(toLength: 10, withPad: " ", startingAt: 0)
            let server = String(g.onServer).padding(toLength: 6, withPad: " ", startingAt: 0)
            print("\(count) \(size) \(String(format: "%3d", unread))% unread  \(server)on server  \(clean(g.key))\(g.name.map { "  (\(clean($0)))" } ?? "")")
        }
        print(String(format: "%d groups in %.3fs", groups.count, elapsed))

    case "plan":
        // Dry run only (ADR-0006: plan → execute → verify); nothing is stored or executed.
        if args.first == "restore" {
            args.removeFirst()
            let options = try restoreOptions()
            let query = args.joined(separator: " ")
            let layout = try ArchiveLayout.open(at: root, create: false)
            let (job, summary) = try ArchiveReader(layout: layout).planRestore(MessageFilter(text: query.isEmpty ? nil : query + " "), title: query,
                                                                               accounts: try AccountStore(layout: layout).load(), options: options)
            printRestorePlan(job, summary)
            print("dry run — nothing changed")
            break
        }
        guard args.first == "server-delete" else { throw CLIError(description: "plan server-delete|restore <query…>") }
        args.removeFirst()
        let grace = Int(option("--grace") ?? "30") ?? 30
        let query = args.joined(separator: " ")
        let layout = try ArchiveLayout.open(at: root, create: false)
        let reader = try ArchiveReader(layout: layout)
        let accounts = try AccountStore(layout: layout).load()
        let (job, summary) = try reader.planServerDelete(MessageFilter(text: query.isEmpty ? nil : query + " "),
                                                         title: query, accounts: accounts, graceDays: grace)
        print("\(summary.messages) messages · \(summary.archiveOnly) only in the archive (nothing on a server)")
        print("would move to the server's Trash: \(job.count(.planned)) (\(bytes(job.openBytes)))"
              + (summary.perAccount.isEmpty ? "" : " — " + summary.perAccount.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", ")))
        for (reason, count) in job.reasons { print("skipped \(count): \(reason)") }
        print("dry run — nothing changed")

    case "server-delete":
        // ADR-0006: plan, show, confirm, execute, verify. Without --yes (or a "j") nothing changes.
        let grace = Int(option("--grace") ?? "30") ?? 30
        let yes = args.contains("--yes")
        args.removeAll { $0 == "--yes" }
        let query = args.joined(separator: " ")
        guard !query.isEmpty else { throw CLIError(description: "server-delete <query…> [--grace <days>] [--yes]") }
        let layout = try ArchiveLayout.open(at: root, create: false)
        let accounts = try AccountStore(layout: layout).load()
        let (job, summary) = try ArchiveReader(layout: layout).planServerDelete(MessageFilter(text: query + " "), title: query,
                                                                                 accounts: accounts, graceDays: grace)
        print("\(summary.messages) messages · \(summary.archiveOnly) only in the archive")
        for (reason, count) in job.reasons { print("skipped \(count): \(reason)") }
        guard job.count(.planned) > 0 else { print("nothing to do"); break }
        print("move \(job.count(.planned)) to the server's Trash (\(bytes(job.openBytes))) — the archive keeps them")
        guard yes || confirm("Ausführen?") else { print("not executed"); break }
        let store = ActionStore(layout: layout)
        try store.create(job)
        let writer = try ArchiveWriter(layout: layout)
        let done = try await SyncCoordinator.deleteOnServer(job.id, writer: writer, accounts: accounts) { p in
            print("\r\(p.account ?? "") done \(p.done) · failed \(p.failed) · skipped \(p.skipped) of \(p.total)", terminator: "")
            fflush(nil)
        }
        print("")
        print("done \(done.count(.done)) · failed \(done.count(.failed)) · skipped \(done.count(.skipped)) — job \(done.id.uuidString)")
        for (reason, count) in done.reasons { print("  \(count): \(reason)") }

    case "restore":
        // ADR-0006 §5: plan, show, confirm, execute (APPEND, verify). Without --yes (or a "j") nothing changes.
        let options = try restoreOptions()
        let yes = args.contains("--yes")
        args.removeAll { $0 == "--yes" }
        let query = args.joined(separator: " ")
        guard !query.isEmpty else { throw CLIError(description: "restore <query…> [--to <account>:<mailbox>] [--now] [--yes]") }
        let layout = try ArchiveLayout.open(at: root, create: false)
        let accounts = try AccountStore(layout: layout).load()
        let (job, summary) = try ArchiveReader(layout: layout).planRestore(MessageFilter(text: query + " "), title: query,
                                                                           accounts: accounts, options: options)
        printRestorePlan(job, summary)
        guard job.count(.planned) > 0 else { print("nothing to do"); break }
        guard yes || confirm("Zurückspielen?") else { print("not executed"); break }
        let store = ActionStore(layout: layout)
        try store.create(job)
        let writer = try ArchiveWriter(layout: layout)
        let done = try await SyncCoordinator.restoreOnServer(job.id, writer: writer, accounts: accounts) { p in
            print("\r\(p.account ?? "") done \(p.done) · failed \(p.failed) of \(p.total)", terminator: "")
            fflush(nil)
        }
        print("")
        print("done \(done.count(.done)) · failed \(done.count(.failed)) · skipped \(done.count(.skipped)) — job \(done.id.uuidString)")
        for (reason, count) in done.reasons { print("  \(count): \(reason)") }
        for (note, count) in done.notes { print("  done \(count): \(note)") }

    case "export":
        let eml = option("--eml"), mbox = option("--mbox")
        let all = args.contains("--all")
        args.removeAll { $0 == "--all" }
        let query = args.joined(separator: " ")
        guard (eml == nil) != (mbox == nil), let target = eml ?? mbox, query.isEmpty == all, !args.contains(where: { $0.hasPrefix("--") }) else {
            throw CLIError(description: "export (<query…> | --all) (--eml <dir> | --mbox <file>)")
        }
        let destination = URL(fileURLWithPath: (target as NSString).expandingTildeInPath)
        if eml != nil, !FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        let layout = try ArchiveLayout.open(at: root, create: false)
        let items = try ArchiveReader(layout: layout).exportItems(MessageFilter(text: all ? nil : query + " "))
        let report = try await ArchiveExporter(blobs: layout.blobs).export(items, format: eml != nil ? .eml : .mbox, to: destination) { done, total in
            print("\r\(done)/\(total)", terminator: "")
            fflush(nil)
        }
        print("")
        print("exported \(report.exported) (\(bytes(report.bytes))) to \(destination.path)")
        for (reason, count) in report.problems.sorted(by: { $0.key < $1.key }) { print("left out \(count): \(reason)") }

    case "classify":
        let layout = try ArchiveLayout.open(at: root, create: false)
        let ai = args.contains("--ai")
        args.removeAll { $0 == "--ai" }
        let limit = Int(option("--limit") ?? "50") ?? 50
        let writer = try ArchiveWriter(layout: layout)
        var ruled = 0
        while case let n = try await writer.classifyHeuristically(), n > 0 { ruled += n }
        if ruled > 0 { print("Regeln: \(ruled) Mails angesehen") }
        let reader = try ArchiveReader(layout: layout)
        if ai {
            let config = AIConfigStore(layout: layout).load()
            guard config.enabled else { throw CLIError(description: "KI ist aus: mkctl ai config --on --endpoint <url>") }
            let key = config.secretKey.flatMap { try? CredentialStore().secret(key: $0) }
            let classifier = MailClassifier(router: AIRouter(config: config, apiKey: key))
            let memory = try MemoryRetriever(reader: reader, embedModel: config.endpoint != nil ? config.model(for: .embed) : nil)
            let query = args.joined(separator: " ")
            for id in try reader.openForClassification(MessageFilter(text: query.isEmpty ? nil : query + " "), limit: limit) {
                guard let parsed = try reader.parsedMessage(id) else { continue }
                do {
                    let mail = MailSnapshot(parsed)
                    let context = try memory.context(for: id, mail: mail, accounts: try reader.detail(id)?.locations.map(\.account) ?? [])
                    let c = try await classifier.classify(mail, memory: context)
                    try await writer.setClassification(messageID: id, category: c.category, source: c.path == .onDevice ? .onDevice : .endpoint,
                                                       model: c.model, reason: c.reason, phishing: c.phishing, phishingReason: c.phishingReason,
                                                       sources: c.sources)
                    let fish = c.phishing == .none ? "" : "  ⚠︎ \(c.phishing.label): \(clean(c.phishingReason ?? ""))"
                    print("\(c.category.label.padding(toLength: 20, withPad: " ", startingAt: 0)) \(clean(String((parsed.subject ?? "").prefix(60))))  — \(clean(c.reason))\(fish)")
                } catch {
                    print("✗ \(clean(String((parsed.subject ?? "").prefix(60)))): \(error)")
                }
            }
        }
        let counts = try reader.categoryCounts()
        for c in MailCategory.allCases where (counts[c] ?? 0) > 0 { print("\(c.label.padding(toLength: 20, withPad: " ", startingAt: 0)) \(counts[c]!)") }
        print("\("offen".padding(toLength: 20, withPad: " ", startingAt: 0)) \(counts[nil] ?? 0)")

    case "embed", "similar", "meaning":
        let layout = try ArchiveLayout.open(at: root, create: false)
        let config = AIConfigStore(layout: layout).load()
        guard config.enabled, config.endpoint != nil else { throw CLIError(description: "KI mit Endpoint nötig: mkctl ai config --on --endpoint <url>") }
        let key = config.secretKey.flatMap { try? CredentialStore().secret(key: $0) }
        let router = AIRouter(config: config, apiKey: key)
        let reader = try ArchiveReader(layout: layout)
        let limit = Int(option("--limit") ?? "20") ?? 20
        if command == "embed" {
            let indexer = EmbeddingIndexer(router: router, writer: try ArchiveWriter(layout: layout))
            let added = try await indexer.run { p in
                print("\r\(p.done)/\(p.total)", terminator: "")
                fflush(nil)
            }
            print("")
            let decided = try await indexer.decideOpenBySimilarity()
            print("\(added) Vektoren neu · \(decided) offene Mails über ähnliche eingeordnet")
            break
        }
        let index = try reader.vectorIndex(model: config.model(for: .embed))
        let hits: [(id: Int64, score: Float)]
        if command == "similar" {
            guard let id = args.first.flatMap({ Int64($0) }), let v = index.vector(of: id) else { throw CLIError(description: "similar <id> (mit Vektor: mkctl embed)") }
            hits = index.nearest(to: v, k: limit, excluding: id)
        } else {
            let text = args.joined(separator: " ")
            guard !text.isEmpty else { throw CLIError(description: "meaning <text…>") }
            hits = index.nearest(to: VectorMath.normalized(try await router.embed([text]).first ?? []), k: limit)
        }
        let byID = Dictionary(uniqueKeysWithValues: try reader.summaries(hits.map(\.id)).map { ($0.id, $0) })
        for h in hits {
            guard let m = byID[h.id] else { continue }
            print(String(format: "%.3f  %6lld  ", h.score, h.id) + "\(m.date.map { $0.formatted(date: .numeric, time: .omitted) } ?? "—")  \(clean(m.fromDisplay).prefix(28))  \(clean(m.subject ?? "").prefix(60))")
        }

    case "rules":
        let reader = try ArchiveReader(layout: try ArchiveLayout.open(at: root, create: false))
        if args.first == "suggest" {
            for s in try reader.ruleSuggestions(audit: AuditLog().entries()) {
                print("\(clean(s.name))  —  \(s.evidence), \(s.matches) Mails passen  [\(s.query) → \(s.action.raw)]")
            }
        } else {
            for r in try reader.rules() {
                let ready = r.action.isDestructive ? " · \(try reader.ready(r)) bereit" : ""
                print("\(clean(r.name))  —  \(r.query) → \(r.action.label)\(ready)")
            }
        }

    case "cleanup":
        let reader = try ArchiveReader(layout: try ArchiveLayout.open(at: root, create: false))
        for s in try reader.cleanupSuggestions() {
            print("\(clean(s.title))  —  \(s.count) Mails, \(bytes(s.bytes))")
            print("   \(clean(s.reason))")
            print("   \(s.query)")
        }

    case "unsubscribe":
        let reader = try ArchiveReader(layout: try ArchiveLayout.open(at: root, create: false))
        let limit = Int(option("--limit") ?? "30") ?? 30
        let showSignatures = args.contains("--dkim")
        let query = args.filter { $0 != "--dkim" }.joined(separator: " ")
        let servers = try reader.ownAuthServers(), own = try reader.ownDomains(), relations = try reader.relations()
        var tally: [String: Int] = [:]
        for id in try reader.messageIDs(MessageFilter(text: "(\(query.isEmpty ? "is:list" : query)) ")).prefix(limit) {
            guard let a = try reader.unsubscribeAssessment(for: id, relations: relations, servers: servers, ownDomains: own) else { continue }
            let method = switch a.method { case .oneClick: "ein-klick"; case .web: "webseite"; case .mail: "mail" }
            let how = a.isBlocked ? "gesperrt" : method
            tally[how, default: 0] += 1
            print("\(how.padding(toLength: 10, withPad: " ", startingAt: 0)) \(clean(a.target).prefix(40).padding(toLength: 40, withPad: " ", startingAt: 0)) \(clean(a.blocked.first ?? a.notes.first ?? "").prefix(90))")
            if showSignatures, let headers = try reader.parsedMessage(id)?.headers {  // what the sender signed (review 6.5c B1)
                for sig in headers.all("DKIM-Signature").compactMap(DKIMSignature.parse) {
                    let listed = ["list-unsubscribe", "list-unsubscribe-post"].map { f in "\(f)×\(sig.signedFields.filter { $0 == f }.count)" }
                    print("           d=\(clean(sig.domain)) \(listed.joined(separator: " ")) (im Kopf: \(headers.all("List-Unsubscribe").count)/\(headers.all("List-Unsubscribe-Post").count))")
                }
            }
        }
        print(tally.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: " · "))

    case "gold":  // 6.6: the private gold set — labels come from Settings › Messung
        let layout = try ArchiveLayout.open(at: root, create: false)
        let reader = try ArchiveReader(layout: layout)
        let store = GoldStore(layout: layout)
        let labels = try store.load()
        switch args.first {
        case "status", nil:
            print("gelabelt \(labels.labels.count) · übersprungen \(labels.skipped.count) (\(store.labelsURL.path))")
            var counts: [MailCategory: Int] = [:]
            for l in labels.labels { counts[l.category, default: 0] += 1 }
            print(MailCategory.allCases.compactMap { c in counts[c].map { "\(c.label) \($0)" } }.joined(separator: " · ")
                  + " · Phishing \(labels.labels.filter(\.phishing).count)")
            for run in store.runs(as: GoldReport.self).suffix(6) { print("\(run.time.formatted()): \(run.summary.first ?? "")") }
        case "run":
            guard !labels.labels.isEmpty else { throw CLIError(description: "noch keine Labels – Einstellungen › Messung › Mails labeln") }
            var reports = [try GoldArchive.todayReport(reader: reader, labels: labels)]
            let config = AIConfigStore(layout: layout).load()
            if !args.contains("--no-ai"), config.enabled {
                let key = config.secretKey.flatMap { try? CredentialStore().secret(key: $0) }
                let runner = GoldRunner(classifier: MailClassifier(router: AIRouter(config: config, apiKey: key)))
                let model = config.endpoint != nil ? config.model(for: .classify) : "apple-on-device"
                let memory = try MemoryRetriever(reader: reader, embedModel: config.endpoint != nil ? config.model(for: .embed) : nil)
                for (mode, m) in [(GoldArchive.withoutMemory, nil), (GoldArchive.withMemory, memory)] as [(String, MemoryRetriever?)] {
                    reports.append(await runner.run(try GoldArchive.items(reader: reader, labels: labels, memory: m), set: GoldArchive.set, mode: mode, model: model))
                }
            }
            let previous = store.runs(as: GoldReport.self)
            let titles = try GoldArchive.titles(reader: reader, identities: labels.labels.map(\.identity))
            for r in reports {
                for line in r.summary { print(clean(line)) }
                for o in r.outcomes where !o.right {
                    print("  ✗ \(clean(titles[o.id] ?? o.id).prefix(70)): \(o.category?.label ?? "–") statt \(o.expected.map(\.label).joined(separator: "/"))"
                          + (o.expectedPhishing == .flagged ? " + Phishing" : "") + (o.error.map { " (\(clean($0)))" } ?? ""))
                }
                if let last = previous.last(where: { $0.set == r.set && $0.mode == r.mode && $0.model == r.model && $0.isComparable }) {
                    let (worse, flips) = GoldArchive.comparison(r, since: last)
                    for line in flips + worse.map({ "Rückschritt: " + $0 }) {
                        // the private set names mails by identity: the title instead
                        let named = titles.reduce(line) { $0.replacingOccurrences(of: $1.key, with: String($1.value.prefix(70))) }
                        print("  seit \(last.time.formatted()): \(clean(named))")
                    }
                }
                try store.appendRun(r)
            }
        case "candidates":  // what the label sheet would offer next
            let ids = try reader.goldCandidates(limit: Int(option("--limit") ?? "40") ?? 40, excluding: labels.seen)
            for s in try reader.summaries(ids) {
                let c = try reader.classification(of: s.id)
                print("\((c?.category?.label ?? "offen").padding(toLength: 20, withPad: " ", startingAt: 0)) \(clean(s.fromDisplay).prefix(28).padding(toLength: 28, withPad: " ", startingAt: 0)) \(clean(s.subject ?? "").prefix(60))")
            }
        default:
            throw CLIError(description: "gold [status | candidates [--limit N] | run [--no-ai]]")
        }

    case "relations":
        let reader = try ArchiveReader(layout: try ArchiveLayout.open(at: root, create: false))
        if args.first == "suggest" {
            print("eigener Prüfserver je Konto: " + (try reader.ownAuthServers()).map { "\($0.key)=\($0.value)" }.sorted().joined(separator: ", "))
            for s in try reader.relationSuggestions(limit: Int(option("--limit") ?? "40") ?? 40) {
                print("\(clean(s.name).prefix(32).padding(toLength: 32, withPad: " ", startingAt: 0)) \(s.domains.joined(separator: ", ").prefix(40).padding(toLength: 40, withPad: " ", startingAt: 0)) \(s.evidence)")
            }
        } else {
            for r in try reader.relations(includeRejected: true) {
                print("\(r.confirmed ? (r.ended ? "beendet " : "aktiv   ") : "abgelehnt") \(clean(r.name).prefix(32).padding(toLength: 32, withPad: " ", startingAt: 0)) \(r.domains.joined(separator: ", "))")
            }
        }

    case "memory":
        let about = option("--about") ?? "", account = option("--account") ?? ""  // before the text is taken
        let layout = try ArchiveLayout.open(at: root, create: false)
        let sub = args.first ?? "list"
        let rest = Array(args.dropFirst())
        switch sub {
        case "list":
            for item in try ArchiveReader(layout: layout).memoryItems() {
                let about = item.subject.isEmpty ? "" : "  [\(clean(item.subject))]"
                print("\(item.id.padding(toLength: 22, withPad: " ", startingAt: 0)) \(item.kind.label.padding(toLength: 14, withPad: " ", startingAt: 0)) \(clean(item.summary).prefix(70))\(about)  (\(item.provenance.label))")
            }
        case "note", "term":
            let text = rest.joined(separator: " ")
            guard !text.isEmpty else { throw CLIError(description: "memory \(sub) <text…>") }
            let id = try await ArchiveWriter(layout: layout).saveNote(kind: sub == "note" ? .preference : .vocabulary, text: text,
                                                                      subject: about, scope: account)
            print("gespeichert: \(id)")
        case "forget":
            guard !rest.isEmpty else { throw CLIError(description: "memory forget <id>…") }
            try await ArchiveWriter(layout: layout).forgetMemory(rest)
            print("vergessen: \(rest.count)")
        case "export":
            let data = try ArchiveReader(layout: layout).exportMemory()
            if let path = rest.first { try data.write(to: URL(fileURLWithPath: path), options: [.atomic]) } else { FileHandle.standardOutput.write(data) }
        case "import":
            guard let path = rest.first else { throw CLIError(description: "memory import <file>") }
            let n = try await ArchiveWriter(layout: layout).importMemory(try Data(contentsOf: URL(fileURLWithPath: path)))
            print("übernommen: \(n)")
        default:
            throw CLIError(description: "memory [list | note <text…> | term <text…> | forget <id>… | export [file] | import <file>]")
        }

    case "summarize":
        let thread = args.contains("--thread")
        args.removeAll { $0 == "--thread" }
        guard let id = args.first.flatMap({ Int64($0) }) else { throw CLIError(description: "summarize <id> [--thread]") }
        let layout = try ArchiveLayout.open(at: root, create: false)
        let config = AIConfigStore(layout: layout).load()
        guard config.enabled else { throw CLIError(description: "KI ist aus: mkctl ai config --on --endpoint <url>") }
        let key = config.secretKey.flatMap { try? CredentialStore().secret(key: $0) }
        let reader = try ArchiveReader(layout: layout)
        let ids = thread ? try reader.thread(of: id).map(\.id) : [id]
        let input = try MailSummarizer.messages(ids, reader: reader)
        let s = try await MailSummarizer(router: AIRouter(config: config, apiKey: key)).summarize(input.messages, total: input.total, flagged: input.flagged)
        print(clean(s.summary))
        if let caution = s.caution { print("⚠︎ \(clean(caution))") }
        for p in s.points { print("  • \(clean(p))") }
        for t in s.todo { print("  ☐ \(clean(t))") }
        print("— \(s.path == .onDevice ? "Modell auf diesem Mac" : s.model), \(String(format: "%.1f", s.seconds)) s, \(s.covered) von \(s.total) Nachrichten")

    case "ask":
        let text = args.joined(separator: " ")
        guard !text.isEmpty else { throw CLIError(description: "ask <everyday language…>") }
        let layout = try ArchiveLayout.open(at: root, create: false)
        let config = AIConfigStore(layout: layout).load()
        guard config.enabled else { throw CLIError(description: "KI ist aus: mkctl ai config --on --endpoint <url>") }
        let key = config.secretKey.flatMap { try? CredentialStore().secret(key: $0) }
        let reader = try ArchiveReader(layout: layout)
        let accounts = try reader.accounts()
        let context = QueryContext(accounts: accounts.map(\.id), folders: Array(Set(accounts.flatMap { $0.mailboxes.map(\.name) })).sorted(),
                                   vocabulary: try reader.memoryItems().filter { $0.kind == .vocabulary }.compactMap(\.content.text))
        let t = try await QueryTranslator(router: AIRouter(config: config, apiKey: key)).translate(text, context: context)
        print("\(t.query)")
        print("  \(clean(t.explanation)) — \(t.path == .onDevice ? "Modell auf diesem Mac" : t.model), \(String(format: "%.1f", t.seconds)) s")
        print("  \(try reader.count(MessageFilter(text: t.query + " "))) Treffer — mkctl search '\(t.query)'")

    case "ai":
        let layout = try ArchiveLayout.open(at: root, create: false)
        let store = AIConfigStore(layout: layout)
        var config = store.load()
        let credentials = CredentialStore()
        switch args.first {
        case "config":
            args.removeFirst()
            if args.contains("--on") { config.enabled = true }
            if args.contains("--off") { config.enabled = false }
            args.removeAll { $0 == "--on" || $0 == "--off" }
            if let e = option("--endpoint") {
                guard let url = URL(string: e), AIConfig.transportProblem(url) == nil else {
                    throw CLIError(description: AIConfig.transportProblem(URL(string: e) ?? URL(fileURLWithPath: "/")) ?? "bad URL")
                }
                config.endpoint = url
            }
            if let o = option("--on-device") { config.onDevice = o == "on" }
            while let m = option("--model") {
                let parts = m.split(separator: "=", maxSplits: 1).map(String.init)
                guard parts.count == 2, let task = AITask(rawValue: parts[0]), task != .test else {
                    throw CLIError(description: "--model <search|classify|summarize|embed>=<alias>")
                }
                config.setModel(parts[1], for: task)
            }
            guard args.isEmpty else { throw CLIError(description: "unknown: \(args.joined(separator: " "))") }
            try store.save(config)
            fallthrough
        case "status", nil:
            print("KI: \(config.enabled ? "an" : "aus")")
            print("Endpoint: \(config.endpoint?.absoluteString ?? "—")\(config.endpoint.map { AIConfig.isLocal($0) ? "" : "  (nicht lokal!)" } ?? "")")
            print("Schlüssel: \(config.secretKey.map { credentials.secretExists(key: $0) ? "im Schlüsselbund" : "keiner" } ?? "—")")
            for task in AITask.allCases where task != .test { print("Modell \(task.rawValue): \(config.model(for: task))") }
            print("Modell auf diesem Mac: \(config.onDevice ? "als Ersatz" : "aus") (\(OnDeviceProvider.availability.reason))")
        case "key":
            guard let secretKey = config.secretKey else { throw CLIError(description: "first: ai config --endpoint <url>") }
            if args.contains("--delete") {
                try credentials.deleteSecret(key: secretKey)
                print("Schlüssel gelöscht")
            } else {
                let key = try readPassword(prompt: "API-Schlüssel für \(config.endpoint?.host() ?? ""): ")
                try credentials.saveSecret(key, key: secretKey, label: "MailKeeper – KI-Endpoint \(config.endpoint?.host() ?? "")",
                                           description: "API-Schlüssel (MailKeeper)")
                print("Schlüssel gespeichert")
            }
        case "test":
            var probe = config
            probe.enabled = true
            let key = config.secretKey.flatMap { try? credentials.secret(key: $0) }
            let report = await AIRouter(config: probe, apiKey: key).test()
            for line in report.lines { print("\(line.ok ? "✓" : "✗") \(line.title): \(clean(line.detail))") }
        default:
            throw CLIError(description: "ai status | test | config … | key")
        }

    case "show":
        guard let idText = args.first, let id = Int64(idText) else { throw CLIError(description: "show <id> [--headers]") }
        let reader = try ArchiveReader(layout: try ArchiveLayout.open(at: root, create: false))
        guard let d = try reader.detail(id), let p = try reader.parsedMessage(id) else { throw CLIError(description: "no message \(id)") }
        if args.contains("--headers") {  // the raw header lines (unfolded), e.g. List-Unsubscribe and DKIM-Signature
            for f in p.headers.fields { print(clean("\(f.name): \(f.rawValue)").prefix(600)) }
            return
        }
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
        guard let sub = args.first else { throw CLIError(description: "account add|list|signin|password|test|remove") }
        args.removeFirst()
        let layout = try ArchiveLayout.open(at: root, create: sub == "add")
        let store = AccountStore(layout: layout)
        let credentials = CredentialStore()
        switch sub {
        case "add":
            guard args.count >= 2 else { throw CLIError(description: "account add gmail|proton|imap <address/user> --id <id>") }
            let kind = args.removeFirst(), user = args.removeFirst()
            let id = try requireOption("--id")
            var clientSecretToSave: String?
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
            // Gmail with --google-client-id: sign in with Google instead of an app password (7.1)
            var tokens: OAuthTokens?
            var password = ""
            let wantsSecret = args.contains("--google-client-secret")
            args.removeAll { $0 == "--google-client-secret" }
            let typedID = option("--google-client-id")
            let wantsGoogle = args.contains("--google")
            args.removeAll { $0 == "--google" }
            // never by itself: a build with its own client must not take the app-password path
            // away from a script that pipes one in (Nachprüfung 7.1 S2)
            if typedID != nil || wantsGoogle {
                guard kind == "gmail" else { throw CLIError(description: "Google-Anmeldung gibt es nur für gmail") }
                let secret = wantsSecret ? try readPassword(prompt: "Client-Secret: ") : ""
                guard let client = OAuthTokens2Go.clientForSignIn(typedID: typedID ?? "", typedSecret: secret, account: nil) else {
                    throw CLIError(description: "--google-client-id fehlt")
                }
                config.oauth = AccountConfig.OAuth(clientID: OAuthTokens2Go.storedClientID(client.id))
                let signedIn = try await signInWithGoogle(client: client, loginHint: user)
                if let address = signedIn.email, !GoogleOAuth.sameMailbox(address, user) {
                    // not revoked: the token belongs to the account that signed in, which may be
                    // another one still in use — a revoke ends its whole grant (Nachprüfung 7.1 S1)
                    throw CLIError(description: "angemeldet als \(clean(address)), eingerichtet wird \(clean(user)) – die Anmeldung bleibt bei Google stehen (Verbundene Apps)")
                }
                tokens = signedIn
                clientSecretToSave = secret.isEmpty ? nil : secret
            } else {
                guard !wantsSecret else { throw CLIError(description: "--google-client-secret braucht --google-client-id") }
                password = try readPassword(prompt: "Passwort für \(user): ")
            }
            print("Verbinde mit \(config.host):\(config.port) …")
            let check = try await SyncCoordinator.check(config, credential: tokens.map { .oauth2(accessToken: $0.accessToken) }
                                                        ?? .password(config.normalizedPassword(password)))
            if case .startTLSPinned = config.security {
                guard let fp = check.certificateFingerprint else { throw CLIError(description: "no certificate fingerprint") }
                print("Zertifikat der Bridge (SHA-256): \(fp)")
                if let trust, trust.lowercased() != fp { throw CLIError(description: "fingerprint does not match --trust") }
                if trust == nil, !confirm("Diesem Zertifikat vertrauen?") { throw CLIError(description: "certificate not confirmed") }
                config.security = .startTLSPinned(fingerprint: fp)
            }
            print("\(check.mailboxes.count) Postfächer, abgerufen werden \(check.selected.count):")
            for box in check.selected { print("    \(clean(box.name))") }
            if let tokens {
                guard let refresh = tokens.refreshToken else {
                    throw CLIError(description: "Google hat kein Refresh-Token geschickt – bitte erneut anmelden")
                }
                // only now, after the connection held: a failed check leaves nothing behind
                if let clientSecretToSave { try credentials.saveClientSecret(clientSecretToSave, for: config) }
                try credentials.saveRefreshToken(refresh, for: config)
            } else {
                try credentials.save(password, for: config)
            }
            try store.add(config)
            print("Konto „\(id)“ angelegt. Abrufen mit: mkctl sync \(id)")
        case "list":
            for a in try store.load() {
                let how = a.oauth == nil
                    ? (credentials.exists(for: a) ? "Passwort ✓" : "kein Passwort")
                    : (credentials.hasCredential(for: a) ? "Google-Anmeldung ✓" : "Google-Anmeldung fehlt")
                print("\(a.id)  \(a.kind.rawValue)  \(clean(a.username)) @ \(a.host):\(a.port)  [\(a.policy.mode.rawValue)\(a.policy.include.map { " nur: " + $0.joined(separator: ", ") } ?? "")]  \(how)")
            }
        case "signin":
            // sign in again, or move an account from its app password to Google (7.1)
            guard let id = args.first, var a = try store.load().first(where: { $0.id == id }) else {
                throw CLIError(description: "account signin <id> [--google-client-id <id>] [--google-client-secret]")
            }
            guard a.kind == .gmail else { throw CLIError(description: "Google-Anmeldung gibt es nur für Gmail-Konten") }
            let wantsSecret = args.contains("--google-client-secret")
            args.removeAll { $0 == "--google-client-secret" }
            let secret = wantsSecret ? try readPassword(prompt: "Client-Secret: ") : ""
            guard let client = OAuthTokens2Go.clientForSignIn(typedID: option("--google-client-id") ?? "",
                                                              typedSecret: secret, account: a, credentials: credentials) else {
                throw CLIError(description: "--google-client-id fehlt")
            }
            let tokens = try await signInWithGoogle(client: client, loginHint: a.username)
            if let address = tokens.email, !GoogleOAuth.sameMailbox(address, a.username) {
                throw CLIError(description: "angemeldet als \(clean(address)), das Konto ist \(clean(a.username)) – die Anmeldung bleibt bei Google stehen (Verbundene Apps)")
            }
            guard let refresh = tokens.refreshToken else {
                throw CLIError(description: "Google hat kein Refresh-Token geschickt – bitte erneut anmelden")
            }
            let wasPassword = a.oauth == nil
            a.oauth = AccountConfig.OAuth(clientID: OAuthTokens2Go.storedClientID(client.id))
            if !secret.isEmpty { try credentials.saveClientSecret(secret, for: a) }
            try credentials.saveRefreshToken(refresh, for: a)
            try store.update(a)
            await OAuthTokens2Go.shared.forget(a)
            print("Konto „\(id)“ meldet sich jetzt mit Google an."
                  + (wasPassword ? " Das App-Passwort bleibt im Schlüsselbund – löschen mit: security delete-generic-password …" : ""))
        case "password":
            // the way back from Google to an app password (review 7.1 C): the Google sign-in in
            // the keychain stays — another archive may still use it, and Google is where it is revoked
            guard let id = args.first, var a = try store.load().first(where: { $0.id == id }) else {
                throw CLIError(description: "account password <id>")
            }
            var candidate = a
            candidate.oauth = nil
            let password = try readPassword(prompt: "Passwort für \(clean(a.username)): ")
            let check = try await SyncCoordinator.check(candidate, password: password)
            print("Verbindung ok · \(check.mailboxes.count) Postfächer, abgerufen werden \(check.selected.count)")
            try credentials.save(password, for: candidate)
            a.oauth = nil
            try store.update(a)
            await OAuthTokens2Go.shared.forget(candidate)
            print("Konto „\(id)“ meldet sich wieder mit Passwort an. Die Google-Anmeldung bleibt im Schlüsselbund – widerrufen bei Google: https://myaccount.google.com/connections")
        case "test":
            guard let id = args.first, let a = try store.load().first(where: { $0.id == id }) else { throw CLIError(description: "account test <id>") }
            let check = try await SyncCoordinator.check(a, credentials: credentials)
            print("Verbindung ok · \(check.mailboxes.count) Postfächer, abgerufen werden \(check.selected.count):")
            for box in check.selected { print("    \(clean(box.name))") }
        case "remove":
            let keep = args.contains("--keep-password")
            args.removeAll { $0 == "--keep-password" }
            guard let id = args.first, let a = try store.load().first(where: { $0.id == id }) else { throw CLIError(description: "account remove <id> [--keep-password]") }
            let shared = try store.load().contains { $0.id != id && CredentialStore.key(for: $0) == CredentialStore.key(for: a) }
            try store.remove(id)
            var revoked = false
            if !keep && !shared {
                // a Google sign-in is told to Google as well, or it would stay listed there (7.1)
                if a.oauth != nil, let token = try? credentials.refreshToken(for: a) {
                    revoked = await GoogleOAuth.revoke(token)  // Google first: the keychain is the only copy
                    if !revoked {
                        print("Widerruf bei Google nicht möglich – nachholen unter https://myaccount.google.com/connections")
                    }
                }
                try credentials.delete(for: a)
            }
            print("Konto „\(id)“ entfernt (archivierte Mails bleiben)"
                  + (keep || shared ? ", Anmeldung behalten."
                     : revoked ? ", Google-Anmeldung widerrufen — auch für andere Archive mit diesem Postfach."
                     : ", Passwort gelöscht — auch für andere Archive mit diesem Postfach."))
        default:
            throw CLIError(description: "account add|list|signin|password|test|remove")
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
                if r.back > 0 { print("  \(r.back) wieder auf dem Server (zuvor als gelöscht vermerkt)") }
                if r.deletedBefore > 0 { print("  \(r.deletedBefore) endgültig aus dem Archiv gelöschte nicht wieder geholt") }
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
        // what the GUI's background pass would do next: the rules, then the user's category rules
        // (ADR-0005: rule labels are derived and re-applied after a rebuild — review 6.7)
        try await writer.prepareForScreening()
        print("rules and the user's category rules applied")
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
