import Foundation
import NIOCore
import NIOIMAP
import Testing
@testable import MailKeeperIMAP
@testable import MailKeeperKit

@Suite("IMAP read-only guard")
struct ReadOnlyGuardTests {
    let inbox = MailboxName(ByteBuffer(string: "INBOX"))
    let one = LastCommandSet<UID>.set(MessageIdentifierSetNonEmpty(range: MessageIdentifierRange(UID(rawValue: 1)...UID(rawValue: 1))))

    @Test func allowsReadingCommands() {
        #expect(IMAPSession.isReadOnly(.capability))
        #expect(IMAPSession.isReadOnly(.examine(inbox, [])))
        #expect(IMAPSession.isReadOnly(.uidSearch(key: .all)))
        #expect(IMAPSession.isReadOnly(.uidFetch(one, [.uid, .flags, .bodySection(peek: true, .complete, nil)], [])))
    }

    @Test func refusesEverythingThatChangesTheServer() {
        let refused: [Command] = [
            .select(inbox, []),
            .uidStore(one, [], .flags(.add(silent: true, list: [.deleted]))),
            .uidCopy(one, inbox), .uidMove(one, inbox), .uidExpunge(one), .expunge,
            .create(inbox, []), .delete(inbox), .subscribe(inbox),
            .uidFetch(one, [.bodySection(peek: false, .complete, nil)], []),  // would set \Seen
            .uidFetch(one, [.rfc822], []),
            .fetch(.set(MessageIdentifierSetNonEmpty(range: MessageIdentifierRange(SequenceNumber(rawValue: 1)...SequenceNumber(rawValue: 1)))), [.rfc822Text], []),
        ]
        for c in refused { #expect(!IMAPSession.isReadOnly(c), "\(c)") }
    }

    @Test("I1: the presence list never uses plain UID SEARCH ALL") func presenceCommand() {
        // swift-nio-imap caps response lines at 8 KiB; "* SEARCH 1 2 3 …" for >1 700 UIDs breaks.
        guard case .uidSearch(_, _, let options) = IMAPSession.presenceCommand(esearch: true) else { Issue.record("not a search"); return }
        #expect(options == [.all])
        guard case .uidFetch(_, let attributes, _) = IMAPSession.presenceCommand(esearch: false) else { Issue.record("not a fetch"); return }
        #expect(attributes == [.uid])
        #expect(IMAPSession.isReadOnly(IMAPSession.presenceCommand(esearch: true)))
    }

    @Test("6.8: a rescue moves only into the one target of that move") func rescueToItsTarget() {
        let target = MailboxName(ByteBuffer(string: "Projekte"))
        let other = MailboxName(ByteBuffer(string: "Trash"))
        #expect(IMAPSession.isAllowedChange(.uidMove(one, target), access: .rescueFromJunk, trash: nil, inbox: target))
        #expect(!IMAPSession.isAllowedChange(.uidMove(one, other), access: .rescueFromJunk, trash: nil, inbox: target))
        #expect(!IMAPSession.isAllowedChange(.uidMove(one, target), access: .rescueFromJunk, trash: nil, inbox: nil))  // outside a move: nothing
        #expect(!IMAPSession.isAllowedChange(.uidMove(one, target), access: .readOnly, trash: nil, inbox: target))
    }

    @Test("Phase 4: a moveToTrash connection may only move into \\Trash") func trashAllowlist() {
        let trash = MailboxName(ByteBuffer(string: "Trash"))
        let archive = MailboxName(ByteBuffer(string: "Archive"))
        let allowed: [Command] = [
            .select(inbox, []), .uidMove(one, trash), .uidCopy(one, trash),
            .uidStore(one, [], .flags(.add(silent: true, list: [.deleted]))), .uidExpunge(one),
        ]
        for c in allowed {
            #expect(IMAPSession.isAllowedChange(c, access: .moveToTrash, trash: trash), "\(c)")
            #expect(!IMAPSession.isAllowedChange(c, access: .readOnly, trash: trash), "\(c)")  // read-only stays read-only
        }
        let refused: [Command] = [
            .uidMove(one, archive), .uidCopy(one, archive),                          // never another destination
            .expunge, .close, .delete(inbox), .create(inbox, []), .rename(from: inbox, to: archive, parameters: [:]),
            .uidStore(one, [], .flags(.add(silent: true, list: [.seen]))),          // only \Deleted may be added
            .uidStore(one, [], .flags(.remove(silent: true, list: [.deleted]))),
            .uidStore(one, [], .flags(.replace(silent: true, list: [.deleted]))),
            .uidStore(one, [], .flags(.add(silent: true, list: [.deleted, .seen]))),
        ]
        for c in refused { #expect(!IMAPSession.isAllowedChange(c, access: .moveToTrash, trash: trash), "\(c)") }
        // `$` (the last search's hits) never stands in for explicit UIDs
        for c: Command in [.uidMove(.lastCommand, trash), .uidCopy(.lastCommand, trash), .uidExpunge(.lastCommand),
                           .uidStore(.lastCommand, [], .flags(.add(silent: true, list: [.deleted])))] {
            #expect(!IMAPSession.isAllowedChange(c, access: .moveToTrash, trash: trash), "\(c)")
        }
        // no destination at all before the \Trash mailbox has been looked up
        #expect(!IMAPSession.isAllowedChange(.uidMove(one, trash), access: .moveToTrash, trash: nil))
    }

    @Test("Phase 4: a restore connection may select and add Gmail labels, nothing else") func restoreAllowlist() {
        let trash = MailboxName(ByteBuffer(string: "Trash"))
        let label = GmailLabel(ByteBuffer(string: "Work"))
        let allowed: [Command] = [.select(inbox, []), .uidStore(one, [], .gmailLabels(.add(silent: true, gmailLabels: [label])))]
        for c in allowed {
            #expect(IMAPSession.isAllowedChange(c, access: .restore, trash: nil), "\(c)")
            #expect(!IMAPSession.isAllowedChange(c, access: .readOnly, trash: nil), "\(c)")
        }
        // client flags a server changed on the way in may be put back (requireOwn: own uploads only)
        for c: Command in [.uidStore(one, [], .flags(.add(silent: true, list: [.seen, .answered]))),
                           .uidStore(one, [], .flags(.remove(silent: true, list: [.seen])))] {
            #expect(IMAPSession.isAllowedChange(c, access: .restore, trash: nil), "\(c)")
        }
        let refused: [Command] = [
            .uidStore(one, [], .gmailLabels(.remove(silent: true, gmailLabels: [label]))),  // never takes labels away
            .uidStore(one, [], .gmailLabels(.replace(silent: true, gmailLabels: [label]))),
            .uidStore(one, [], .flags(.add(silent: true, list: [.deleted]))),
            .uidStore(one, [], .flags(.add(silent: true, list: [.seen, .deleted]))),
            .uidStore(one, [], .flags(.replace(silent: true, list: [.seen]))),
            .uidStore(one, [], .flags(.add(silent: true, list: [Flag("$Junk")]))),
            .uidMove(one, trash), .uidCopy(one, trash), .uidExpunge(one), .expunge, .close,
            .create(inbox, []), .delete(inbox), .rename(from: inbox, to: trash, parameters: [:]),
        ]
        for c in refused { #expect(!IMAPSession.isAllowedChange(c, access: .restore, trash: trash), "\(c)") }
        // and a delete connection cannot label
        #expect(!IMAPSession.isAllowedChange(allowed[1], access: .moveToTrash, trash: trash))
    }

    @Test("5.5: a rescue connection moves only into INBOX, with explicit UIDs") func rescueAllowlist() {
        let inboxName = MailboxName(ByteBuffer(string: "INBOX"))
        let archive = MailboxName(ByteBuffer(string: "Archiv"))
        #expect(IMAPSession.isAllowedChange(.select(inboxName, []), access: .rescueFromJunk, trash: nil, inbox: inboxName))
        #expect(IMAPSession.isAllowedChange(.uidMove(one, inboxName), access: .rescueFromJunk, trash: nil, inbox: inboxName))
        #expect(IMAPSession.isAllowedChange(.uidCopy(one, inboxName), access: .rescueFromJunk, trash: nil, inbox: inboxName))
        #expect(IMAPSession.isAllowedChange(.uidStore(one, [], .flags(.add(silent: true, list: [.deleted]))), access: .rescueFromJunk, trash: nil, inbox: inboxName))
        for c: Command in [.uidMove(one, archive), .uidMove(.lastCommand, inboxName), .uidStore(one, [], .flags(.add(silent: true, list: [.seen]))),
                           .uidExpunge(.lastCommand), .uidStore(.lastCommand, [], .flags(.add(silent: true, list: [.deleted]))),
                           .expunge, .close, .create(inboxName, []), .delete(archive)] {
            #expect(!IMAPSession.isAllowedChange(c, access: .rescueFromJunk, trash: nil, inbox: inboxName), "\(c)")
        }
        #expect(!IMAPSession.isAllowedChange(.uidMove(one, inboxName), access: .rescueFromJunk, trash: nil, inbox: nil))  // no target set: outside a move
        #expect(!IMAPSession.isAllowedChange(.uidMove(one, inboxName), access: .moveToTrash, trash: archive, inbox: inboxName))
    }

    @Test("6.4: an 'Ist Spam' connection moves only into the spam mailbox, with explicit UIDs") func markAsJunkAllowlist() {
        let junk = MailboxName(ByteBuffer(string: "Junk"))
        let inboxName = MailboxName(ByteBuffer(string: "INBOX"))
        let archive = MailboxName(ByteBuffer(string: "Archiv"))
        #expect(IMAPSession.isAllowedChange(.select(inboxName, []), access: .markAsJunk, trash: nil, junk: junk))
        #expect(IMAPSession.isAllowedChange(.uidMove(one, junk), access: .markAsJunk, trash: nil, junk: junk))
        #expect(IMAPSession.isAllowedChange(.uidCopy(one, junk), access: .markAsJunk, trash: nil, junk: junk))
        #expect(IMAPSession.isAllowedChange(.uidStore(one, [], .flags(.add(silent: true, list: [.deleted]))), access: .markAsJunk, trash: nil, junk: junk))
        for c: Command in [.uidMove(one, inboxName), .uidMove(one, archive), .uidMove(.lastCommand, junk),
                           .uidStore(one, [], .flags(.add(silent: true, list: [.seen]))), .uidExpunge(.lastCommand), .expunge, .close,
                           .create(junk, []), .delete(archive)] {
            #expect(!IMAPSession.isAllowedChange(c, access: .markAsJunk, trash: nil, junk: junk), "\(c)")
        }
        #expect(!IMAPSession.isAllowedChange(.uidMove(one, junk), access: .markAsJunk, trash: nil, junk: nil))  // no spam mailbox known
        #expect(!IMAPSession.isAllowedChange(.uidMove(one, junk), access: .rescueFromJunk, trash: nil, inbox: inboxName, junk: junk))
    }

    @Test func uidZeroAndStarNeverReachTheServer() throws {
        #expect(throws: IMAPError.self) { _ = try IMAPSession.uidSet([0]) }
        #expect(throws: IMAPError.self) { _ = try IMAPSession.uidSet([UInt32.max]) }
        guard case .set(let set) = try IMAPSession.uidSet([0, 5, .max]) else { Issue.record("no set"); return }
        #expect(set.set.map { UInt32($0.rawValue) } == [5])
    }

    @Test func appendLimitAndTrashNameVeto() {
        #expect(IMAPSession.appendLimit(["IMAP4REV1", "APPENDLIMIT=35651584"]) == 35_651_584)
        #expect(IMAPSession.appendLimit(["IMAP4REV1"]) == nil)
        #expect(RemoteMailbox.looksLikeTrashOrJunk("INBOX/Trash") && RemoteMailbox.looksLikeTrashOrJunk("Papierkorb")
                && RemoteMailbox.looksLikeTrashOrJunk("INBOX.Spam"))
        #expect(!RemoteMailbox.looksLikeTrashOrJunk("Spam-Archiv") && !RemoteMailbox.looksLikeTrashOrJunk("Projekte/bin"))
    }

    @Test("APPEND dates go out in UTC") func appendDate() throws {
        let date = try #require(IMAPSession.serverDate(Date(timeIntervalSince1970: 1_552_554_000)))  // 14.3.2019 09:00 UTC
        #expect(IMAPSession.date(date) == Date(timeIntervalSince1970: 1_552_554_000))
    }

    @Test("I5: stream errors keep their cause") func errorsKeepCause() {
        struct PayloadTooLarge: Error {}
        #expect(IMAPSession.mapped(PayloadTooLarge()) == .protocolError("PayloadTooLarge()"))
        #expect(IMAPSession.mapped(IMAPError.closed) == .closed)
    }

    @Test func serverTextIsCleaned() {
        #expect(IMAPSession.clean("ok\u{1B}]52;c;ZXZpbA==\u{07} \u{202E}x") == "ok]52;c;ZXZpbA== x")
        #expect(IMAPSession.clean(String(repeating: "a", count: 1000)).count == 300)
    }
}

/// Real servers, opt-in: MAILKEEPER_INTEGRATION=1 swift test --filter Integration
/// Accounts from ~/.config/mailkeeper/test-accounts.json, passwords via the `security` tool.
/// Read-only by construction; Proton only ever syncs its test folder.
@Suite("Integration (real servers)", .enabled(if: ProcessInfo.processInfo.environment["MAILKEEPER_INTEGRATION"] == "1"),
       .serialized)
struct IntegrationTests {
    struct Account: Decodable {
        struct Keychain: Decodable { let service: String; let account: String }
        let id: String, kind: String, host: String, port: Int, username: String
        let keychain: Keychain
    }

    static let configDir = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".config/mailkeeper")

    func account(_ id: String) throws -> Account {
        struct File: Decodable { let accounts: [Account] }
        let file = try JSONDecoder().decode(File.self, from: Data(contentsOf: Self.configDir.appending(path: "test-accounts.json")))
        return try #require(file.accounts.first { $0.id == id })
    }

    func password(_ a: Account) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        p.arguments = ["find-generic-password", "-s", a.keychain.service, "-a", a.keychain.account, "-w"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        var s = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .newlines)
        if a.kind == "gmail" { s.removeAll { $0 == " " } }
        return s
    }

    func run(_ id: String, endpoint: IMAPEndpoint, policy: SyncPolicy) async throws -> (ArchiveLayout, SyncReport, SyncReport) {
        let a = try account(id)
        let layout = try ArchiveLayout.open(at: tempDir().appending(path: "it-\(id)"), create: true)
        let writer = try ArchiveWriter(layout: layout)
        let engine = SyncEngine(writer: writer, account: AccountInfo(id: id, kind: a.kind, name: a.username), policy: policy)
        let s1 = try await IMAPSession.connect(endpoint, username: a.username, password: try password(a))
        let first = try await engine.run(source: s1)
        await s1.close()
        let s2 = try await IMAPSession.connect(endpoint, username: a.username, password: try password(a))
        let second = try await engine.run(source: s2)
        await s2.close()
        return (layout, first, second)
    }

    func fixtureLocation(_ layout: ArchiveLayout) throws -> MessageLocation? {
        let reader = try ArchiveReader(layout: layout)
        let ids = try reader.messageIDs(MessageFilter(text: "Spike S1"))
        return try ids.compactMap { try reader.detail($0) }.first { $0.messageID == "<mk-s1-001@mailkeeper.test>" }?.locations.first
    }

    @Test func mailcow() async throws {
        let a = try account("mailcow")
        let (layout, first, second) = try await run("mailcow", endpoint: IMAPEndpoint(host: a.host, port: a.port, security: .tls),
                                                    policy: SyncPolicy(mode: .standard))
        #expect(first.failures.isEmpty, "\(first.failures)")
        #expect(first.newMessages >= 5)
        #expect(second.fetched == 0)
        let loc = try #require(try fixtureLocation(layout))
        #expect(loc.mailbox == "MailKeeper-Test" && loc.uid != nil)
        #expect(!loc.flags.contains("\\Seen"))  // BODY.PEEK did not mark it read
    }

    @Test func gmail() async throws {
        let a = try account("gmail")
        let (layout, first, second) = try await run("gmail", endpoint: IMAPEndpoint(host: a.host, port: a.port, security: .tls),
                                                    policy: SyncPolicy(mode: .gmail))
        #expect(first.failures.isEmpty, "\(first.failures)")
        #expect(first.mailboxes == 1 && first.newMessages >= 5, "\(first)")
        #expect(second.fetched == 0)
        let loc = try #require(try fixtureLocation(layout))
        #expect(loc.mailbox.hasPrefix("[Gmail]/"))
        #expect(loc.labels.contains("MailKeeper-Test"))
    }

    @Test func protonBridgeTestFolderOnly() async throws {
        let a = try account("proton")
        let pins = try JSONSerialization.jsonObject(with: Data(contentsOf: Self.configDir.appending(path: "pins.json"))) as? [String: String]
        let pin = try #require(pins?["\(a.host):\(a.port)"])
        let (layout, first, second) = try await run("proton",
                                                    endpoint: IMAPEndpoint(host: a.host, port: a.port, security: .startTLSPinned(fingerprint: pin)),
                                                    policy: SyncPolicy(mode: .protonBridge, include: ["Folders/MailKeeper-Test"]))
        #expect(first.failures.isEmpty, "\(first.failures)")
        #expect(first.mailboxes == 1 && first.newMessages >= 5, "\(first)")
        #expect(second.fetched == 0)
        let boxes = try ArchiveReader(layout: layout).accounts().flatMap(\.mailboxes).map(\.name)
        #expect(boxes == ["Folders/MailKeeper-Test"])
    }

    /// I1 regression: a mailbox with more UIDs than fit into one 8 KiB response line, synced
    /// twice (the second run checks for deletions). Seed with Scripts/seed-test-mailbox.py.
    @Test func mailcowBulkMailbox() async throws {
        let a = try account("mailcow")
        let (layout, first, second) = try await run("mailcow", endpoint: IMAPEndpoint(host: a.host, port: a.port, security: .tls),
                                                    policy: SyncPolicy(mode: .standard, include: ["MailKeeper-Bulk"]))
        #expect(first.failures.isEmpty, "\(first.failures)")
        #expect(first.newMessages >= 2_000, "seed the folder: Scripts/seed-test-mailbox.py")
        #expect(second.failures.isEmpty, "\(second.failures)")
        #expect(second.fetched == 0 && second.gone == 0)
        #expect(try ArchiveReader(layout: layout).stats().locations == first.newMessages + first.newLocations)
    }

    func seed(_ argument: String) throws {
        let script = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appending(path: "Scripts/seed-test-mailbox.py")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        p.arguments = ["-I", script.path, argument]
        try p.run()
        p.waitUntilExit()
        try #require(p.terminationStatus == 0, "seed-test-mailbox.py \(argument)")
    }

    /// Phase 4 (ADR-0006), mailcow TEST account only: three fresh messages are synced, deleted to
    /// Trash through the narrow `.moveToTrash` access, checked on the server with a separate
    /// read-only connection and in the archive; the test messages are then removed from Trash.
    @Test func mailcowServerDeleteToTrash() async throws {
        let a = try account("mailcow")
        let folder = "MailKeeper-DeleteTest"
        try seed("--delete-test")
        defer { try? seed("--cleanup-trash") }
        let endpoint = IMAPEndpoint(host: a.host, port: a.port, security: .tls)
        let (layout, first, _) = try await run("mailcow", endpoint: endpoint, policy: SyncPolicy(mode: .standard, include: [folder]))
        #expect(first.failures.isEmpty, "\(first.failures)")
        let reader = try ArchiveReader(layout: layout)
        let config = AccountConfig.imap(id: "mailcow", username: a.username, host: a.host, port: a.port)
        let (job, _) = try reader.planServerDelete(MessageFilter(text: "folder:\(folder) "), title: "test", accounts: [config])
        #expect(job.count(.planned) >= 3, "\(job.reasons)")  // internal date 400 days back: past the grace period
        let store = ActionStore(layout: layout)
        try store.create(job)
        let pw = try password(a)
        let done = try await ServerDeleteExecutor(writer: try ArchiveWriter(layout: layout), store: store,
                                                  audit: AuditLog(url: tempDir().appending(path: "audit.jsonl"))).run(job.id) { _ in
            try await IMAPSession.connect(endpoint, username: a.username, password: pw, access: .moveToTrash)
        }
        #expect(done.count(.done) == job.count(.planned), "\(done.reasons)")
        // the server, seen through a separate read-only connection
        let check = try await IMAPSession.connect(endpoint, username: a.username, password: pw)
        let boxes = try await check.mailboxes()
        _ = try await check.examine(try #require(boxes.first { $0.name == folder }))
        let left = Set(try await check.allUIDs())
        #expect(left.isDisjoint(with: done.items.compactMap { $0.location?.uid }))
        _ = try await check.examine(try #require(boxes.first { $0.specialUse.contains(.trash) }))
        let inTrash = Set(try await check.identities(try await check.allUIDs()).values.compactMap(\.messageID))
        #expect(Set(done.items.compactMap(\.messageID)).isSubset(of: inTrash))
        await check.close()
        // the archive kept them, now archive-only
        #expect(try reader.count(MessageFilter(text: "folder:\(folder) only:archive ")) == done.count(.done))
    }

    /// Phase 4.4 (ADR-0006 §5), mailcow TEST account only: three fresh messages (two with flags)
    /// are synced, deleted to Trash, then restored to where they were through the narrow
    /// `.restore` access. A separate read-only connection checks bytes, arrival date and flags;
    /// the archive sees them on the server again and a second plan has nothing left to do.
    @Test func mailcowDeleteThenRestore() async throws {
        let a = try account("mailcow")
        let folder = "MailKeeper-RestoreTest"
        try seed("--restore-test")
        defer { try? seed("--cleanup-restore") }
        let endpoint = IMAPEndpoint(host: a.host, port: a.port, security: .tls)
        let (layout, first, _) = try await run("mailcow", endpoint: endpoint, policy: SyncPolicy(mode: .standard, include: [folder]))
        #expect(first.failures.isEmpty, "\(first.failures)")
        let reader = try ArchiveReader(layout: layout)
        let config = AccountConfig.imap(id: "mailcow", username: a.username, host: a.host, port: a.port)
        let filter = MessageFilter(text: "folder:\(folder) ")
        let ids = try reader.messageIDs(filter)
        let before = try ids.compactMap { try reader.detail($0) }.compactMap { d in d.locations.first.map { (d.messageID, $0) } }
        let store = ActionStore(layout: layout)
        let audit = AuditLog(url: tempDir().appending(path: "audit.jsonl"))
        let writer = try ArchiveWriter(layout: layout)
        let pw = try password(a)
        // 1. delete (server Trash)
        let (deletion, _) = try reader.planServerDelete(filter, title: "test", accounts: [config])
        try store.create(deletion)
        let deleted = try await ServerDeleteExecutor(writer: writer, store: store, audit: audit).run(deletion.id) { _ in
            try await IMAPSession.connect(endpoint, username: a.username, password: pw, access: .moveToTrash)
        }
        #expect(deleted.count(.done) == ids.count && ids.count >= 3, "\(deleted.reasons)")
        #expect(try reader.count(MessageFilter(text: "folder:\(folder) on:server ")) == 0)
        // 2. restore to where they were
        let (restore, summary) = try reader.planRestore(MessageFilter(ids: ids), title: "test", accounts: [config], options: RestoreOptions())
        #expect(summary.perAccount == ["mailcow › \(folder)": ids.count], "\(restore.reasons)")
        try store.create(restore)
        let restored = try await RestoreExecutor(writer: writer, store: store, audit: audit).run(restore.id, accounts: [config]) { _ in
            try await IMAPSession.connect(endpoint, username: a.username, password: pw, access: .restore)
        }
        #expect(restored.count(.done) == ids.count, "\(restored.reasons)")
        // 3. the server, through a separate read-only connection: same bytes, date and flags
        let check = try await IMAPSession.connect(endpoint, username: a.username, password: pw)
        let boxes = try await check.mailboxes()
        _ = try await check.examine(try #require(boxes.first { $0.name == folder }))
        let back = try await check.fetch(try await check.allUIDs())
        await check.close()
        for (messageID, old) in before {
            let now = try #require(back.first { MIMEParser.parse($0.data).messageID == messageID }, "\(messageID ?? "-")")
            let item = try #require(restored.items.first { $0.messageID == messageID })
            #expect(sha256Hex(now.data) == item.sha256)
            #expect(now.internalDate == old.internalDate)
            let clientFlags = { (f: [String]) in Set(f.filter { $0 != "\\Recent" }) }  // \Recent belongs to the session
            #expect(clientFlags(now.flags) == clientFlags(old.flags), "\(now.flags) vs \(old.flags)")
        }
        // 4. the archive sees them on the server again; nothing left to restore
        #expect(try reader.count(MessageFilter(text: "folder:\(folder) on:server ")) == ids.count)
        let (again, _) = try reader.planRestore(MessageFilter(ids: ids), title: "again", accounts: [config], options: RestoreOptions())
        #expect(again.count(.planned) == 0)
    }

    /// Review B1: a server that refuses an APPEND before the literal (here: no such mailbox,
    /// TRYCREATE) must cost one item, not the job. MailKeeper never creates the mailbox.
    @Test func mailcowRefusedAppendIsARefusal() async throws {
        let a = try account("mailcow")
        let endpoint = IMAPEndpoint(host: a.host, port: a.port, security: .tls)
        let pw = try password(a)
        let missing = "MailKeeper-DoesNotExist-\(UUID().uuidString.prefix(8))"
        let session = try await IMAPSession.connect(endpoint, username: a.username, password: pw, access: .restore)
        let refusal = await #expect(throws: ServerRefusal.self) {
            _ = try await session.sendAppend(Data("Subject: x\r\n\r\nx\r\n".utf8), to: MailboxName(ByteBuffer(string: missing)),
                                             options: AppendOptions(flagList: [], internalDate: nil, extensions: [:]))
        }
        #expect(refusal?.connectionClosed == true, "\(refusal?.message ?? "-")")  // refused before the literal (B1)
        await session.close()
        let check = try await IMAPSession.connect(endpoint, username: a.username, password: pw)
        #expect(try await !check.mailboxes().contains { $0.name == missing })
        await check.close()
    }

    /// A restore connection may put flags right on its own upload — and on nothing else.
    @Test func mailcowRestoreTouchesOnlyItsOwnUpload() async throws {
        let a = try account("mailcow")
        let folder = "MailKeeper-RestoreTest"
        try seed("--restore-test")
        defer { try? seed("--cleanup-restore") }
        let endpoint = IMAPEndpoint(host: a.host, port: a.port, security: .tls)
        let session = try await IMAPSession.connect(endpoint, username: a.username, password: try password(a), access: .restore)
        let boxes = try await session.mailboxes()
        #expect(boxes.contains { $0.name == folder })
        _ = try await session.selectForChange(folder)
        let foreign = try #require(try await session.allUIDs().first)  // seeded, not uploaded by this connection
        let message = Data("From: restore-test@mailkeeper.test\r\nSubject: own upload\r\nMessage-ID: <mk-rst-own-\(UUID().uuidString)@mailkeeper.test>\r\n\r\nx\r\n".utf8)
        let appended = try #require(try await session.append(message, to: folder, flags: [], internalDate: nil))
        try await session.correctFlags(add: ["\\Seen", "\\Flagged"], remove: [], uid: appended.uid)
        try await session.correctFlags(add: [], remove: ["\\Flagged"], uid: appended.uid)
        let flags = try #require(try await session.fetch([appended.uid]).first?.flags)
        #expect(flags.contains("\\Seen") && !flags.contains("\\Flagged"))
        await #expect(throws: IMAPError.self) { try await session.correctFlags(add: ["\\Seen"], remove: [], uid: foreign) }
        await session.close()
    }

    /// 5.5, mailcow TEST account only: a legitimate test mail in Junk is synced (spam folder on),
    /// moved to INBOX through the narrow `.rescueFromJunk` access, and checked on the server with
    /// a separate read-only connection; the archive knows the INBOX location afterwards.
    @Test func mailcowNoSpamBackToInbox() async throws {
        let a = try account("mailcow")
        try seed("--cleanup-junk")  // leftovers of earlier (manual) runs would match too
        try seed("--junk-test")
        defer { try? seed("--cleanup-junk") }
        let endpoint = IMAPEndpoint(host: a.host, port: a.port, security: .tls)
        let (layout, first, _) = try await run("mailcow", endpoint: endpoint, policy: SyncPolicy(mode: .standard, include: ["Junk"], includeJunk: true))
        #expect(first.failures.isEmpty, "\(first.failures)")
        let reader = try ArchiveReader(layout: layout)
        let ids = try reader.messageIDs(MessageFilter(text: "is:junk subject:jahresabrechnung "))
        try #require(ids.count == 1, "the seeded mail is in Junk (role \\Junk from LIST)")
        var config = AccountConfig.imap(id: "mailcow", username: a.username, host: a.host, port: a.port)
        config.policy = SyncPolicy(mode: .standard, include: ["Junk"], includeJunk: true)
        let (job, _) = try reader.planRescue(MessageFilter(ids: ids), title: "test", accounts: [config])
        #expect(job.count(.planned) == 1, "\(job.reasons)")
        let store = ActionStore(layout: layout)
        try store.create(job)
        let pw = try password(a)
        let done = try await RescueExecutor(writer: try ArchiveWriter(layout: layout), store: store,
                                            audit: AuditLog(url: tempDir().appending(path: "audit.jsonl"))).run(job.id, accounts: [config]) { _ in
            try await IMAPSession.connect(endpoint, username: a.username, password: pw, access: .rescueFromJunk)
        }
        #expect(done.count(.done) == 1, "\(done.reasons)")
        // INBOX is outside this test's sync selection (include: Junk): not recorded, said so
        #expect(done.items[0].reason == "aus „Junk“ → INBOX · im Posteingang; diesen Ordner ruft MailKeeper für das Konto nicht ab")
        let messageID = try #require(job.items.first?.messageID)
        let check = try await IMAPSession.connect(endpoint, username: a.username, password: pw)
        let boxes = try await check.mailboxes()
        _ = try await check.examine(try #require(boxes.first { $0.name == "INBOX" }))
        #expect(try await !check.search(messageID: messageID).isEmpty)
        _ = try await check.examine(try #require(boxes.first { $0.specialUse.contains(.junk) }))
        #expect(try await check.search(messageID: messageID).isEmpty)
        await check.close()
        let detail = try #require(try reader.detail(ids[0]))
        #expect(!detail.locations.contains { $0.mailbox == "INBOX" })
        #expect(detail.locations.first { $0.mailbox == "Junk" }?.isOnServer == false)
        #expect(try reader.classification(of: ids[0])?.verdict == "ham")
    }

    /// 6.4, mailcow TEST account only: a lure in INBOX is synced, moved into Junk through the
    /// narrow `.markAsJunk` access ("Ist Spam → Spam-Ordner"), checked on the server with a separate
    /// read-only connection; the archive records the Junk location and the user's verdict.
    @Test func mailcowIstSpamToJunk() async throws {
        let a = try account("mailcow")
        try seed("--cleanup-junk")
        try seed("--inbox-spam-test")
        defer { try? seed("--cleanup-junk") }
        let endpoint = IMAPEndpoint(host: a.host, port: a.port, security: .tls)
        let policy = SyncPolicy(mode: .standard, include: ["INBOX", "Junk"], includeJunk: true)
        let (layout, first, _) = try await run("mailcow", endpoint: endpoint, policy: policy)
        #expect(first.failures.isEmpty, "\(first.failures)")
        let reader = try ArchiveReader(layout: layout)
        let ids = try reader.messageIDs(MessageFilter(text: "subject:eingeschraenkt -is:junk "))
        try #require(ids.count == 1, "the seeded lure is in INBOX")
        var config = AccountConfig.imap(id: "mailcow", username: a.username, host: a.host, port: a.port)
        config.policy = policy
        let (job, _) = try reader.planMarkSpam(MessageFilter(ids: ids), title: "test", accounts: [config])
        #expect(job.count(.planned) == 1 && job.items.first?.location?.mailbox == "INBOX", "\(job.reasons)")
        let store = ActionStore(layout: layout)
        try store.create(job)
        let pw = try password(a)
        let done = try await RescueExecutor(writer: try ArchiveWriter(layout: layout), store: store,
                                            audit: AuditLog(url: tempDir().appending(path: "audit.jsonl"))).run(job.id, accounts: [config]) { _ in
            try await IMAPSession.connect(endpoint, username: a.username, password: pw, access: .markAsJunk)
        }
        #expect(done.count(.done) == 1, "\(done.reasons)")
        let messageID = try #require(job.items.first?.messageID)
        let check = try await IMAPSession.connect(endpoint, username: a.username, password: pw)
        let boxes = try await check.mailboxes()
        _ = try await check.examine(try #require(boxes.first { $0.specialUse.contains(.junk) }))
        #expect(try await !check.search(messageID: messageID).isEmpty)
        _ = try await check.examine(try #require(boxes.first { $0.name == "INBOX" }))
        #expect(try await check.search(messageID: messageID).isEmpty)
        await check.close()
        let detail = try #require(try reader.detail(ids[0]))
        #expect(detail.locations.first { $0.mailbox == "Junk" }?.isOnServer == true)
        #expect(detail.locations.first { $0.mailbox == "INBOX" }?.isOnServer == false)
        #expect(try reader.classification(of: ids[0])?.verdict == "spam" && reader.classification(of: ids[0])?.source == .user)
    }

    /// 6.8, mailcow TEST account only: a legitimate mail in a project folder goes into Junk ("Ist
    /// Spam", .markAsJunk) and back with "Kein Spam" — not into INBOX but where it lay, through the
    /// narrow `.rescueFromJunk` access; checked with a separate read-only connection.
    @Test func mailcowSpamAndBackWhereItLay() async throws {
        let a = try account("mailcow")
        try seed("--cleanup-junk")
        try seed("--origin-spam-test")
        defer { try? seed("--cleanup-junk") }
        let endpoint = IMAPEndpoint(host: a.host, port: a.port, security: .tls)
        let policy = SyncPolicy(mode: .standard, include: ["MailKeeper-SpamOrigin", "Junk"], includeJunk: true)
        let (layout, first, _) = try await run("mailcow", endpoint: endpoint, policy: policy)
        #expect(first.failures.isEmpty, "\(first.failures)")
        let reader = try ArchiveReader(layout: layout)
        let ids = try reader.messageIDs(MessageFilter(text: "subject:herkunftstest -is:junk "))
        try #require(ids.count == 1, "the seeded mail is in MailKeeper-SpamOrigin")
        var config = AccountConfig.imap(id: "mailcow", username: a.username, host: a.host, port: a.port)
        config.policy = policy
        let pw = try password(a)
        let store = ActionStore(layout: layout)
        // there: "Ist Spam"
        let (toJunk, _) = try reader.planMarkSpam(MessageFilter(ids: ids), title: "test", accounts: [config])
        try store.create(toJunk)
        let junked = try await RescueExecutor(writer: try ArchiveWriter(layout: layout), store: store,
                                              audit: AuditLog(url: tempDir().appending(path: "audit.jsonl"))).run(toJunk.id, accounts: [config]) { _ in
            try await IMAPSession.connect(endpoint, username: a.username, password: pw, access: .markAsJunk)
        }
        #expect(junked.count(.done) == 1, "\(junked.reasons)")
        #expect(try reader.count(MessageFilter(text: "is:junk ", ids: ids)) == 1)
        // and back: "Kein Spam" — to where it lay
        let (back, summary) = try reader.planRescue(MessageFilter(ids: ids), title: "test", accounts: [config])
        #expect(back.items.first?.target?.mailbox == "MailKeeper-SpamOrigin" && summary.perAccount == ["mailcow › MailKeeper-SpamOrigin": 1])
        try store.create(back)
        let rescued = try await RescueExecutor(writer: try ArchiveWriter(layout: layout), store: store,
                                               audit: AuditLog(url: tempDir().appending(path: "audit.jsonl"))).run(back.id, accounts: [config]) { _ in
            try await IMAPSession.connect(endpoint, username: a.username, password: pw, access: .rescueFromJunk)
        }
        #expect(rescued.count(.done) == 1, "\(rescued.reasons)")
        let messageID = try #require(back.items.first?.messageID)
        let check = try await IMAPSession.connect(endpoint, username: a.username, password: pw)
        let boxes = try await check.mailboxes()
        _ = try await check.examine(try #require(boxes.first { $0.name == "MailKeeper-SpamOrigin" }))
        #expect(try await !check.search(messageID: messageID).isEmpty)
        _ = try await check.examine(try #require(boxes.first { $0.specialUse.contains(.junk) }))
        #expect(try await check.search(messageID: messageID).isEmpty)
        await check.close()
        #expect(try reader.count(MessageFilter(text: "is:junk ", ids: ids)) == 0)  // 6.8: no longer "is:junk"
        #expect(try reader.detail(ids[0])?.locations.contains { $0.mailbox == "MailKeeper-SpamOrigin" && $0.isOnServer } == true)
        #expect(try reader.classification(of: ids[0])?.verdict == "ham")
    }

    @Test func protonWrongPinIsRefused() async throws {
        let a = try account("proton")
        await #expect(throws: IMAPError.self) {
            _ = try await IMAPSession.connect(IMAPEndpoint(host: a.host, port: a.port,
                                                          security: .startTLSPinned(fingerprint: String(repeating: "0", count: 64))),
                                              username: a.username, password: try password(a))
        }
    }
}
