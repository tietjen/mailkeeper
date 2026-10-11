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
        // no destination at all before the \Trash mailbox has been looked up
        #expect(!IMAPSession.isAllowedChange(.uidMove(one, trash), access: .moveToTrash, trash: nil))
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
        #expect(first.mailboxes == 1 && first.newMessages >= 5)
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
        #expect(first.mailboxes == 1 && first.newMessages >= 5)
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

    @Test func protonWrongPinIsRefused() async throws {
        let a = try account("proton")
        await #expect(throws: IMAPError.self) {
            _ = try await IMAPSession.connect(IMAPEndpoint(host: a.host, port: a.port,
                                                          security: .startTLSPinned(fingerprint: String(repeating: "0", count: 64))),
                                              username: a.username, password: try password(a))
        }
    }
}
