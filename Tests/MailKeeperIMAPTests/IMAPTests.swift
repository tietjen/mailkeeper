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

    @Test func protonWrongPinIsRefused() async throws {
        let a = try account("proton")
        await #expect(throws: IMAPError.self) {
            _ = try await IMAPSession.connect(IMAPEndpoint(host: a.host, port: a.port,
                                                          security: .startTLSPinned(fingerprint: String(repeating: "0", count: 64))),
                                              username: a.username, password: try password(a))
        }
    }
}
