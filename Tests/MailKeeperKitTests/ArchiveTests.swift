import Foundation
import Testing
@testable import MailKeeperKit

func tempDir() -> URL {
    let url = FileManager.default.temporaryDirectory.appending(path: "mk-test-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

func sampleMessage(id: String, subject: String, body: String = "Hallo", from: String = "a@example.test",
                   extraHeaders: String = "") -> Data {
    eml("""
    From: \(from)
    To: inbox@example.test
    Subject: \(subject)
    Date: Thu, 14 Mar 2019 10:00:00 +0100
    Message-ID: \(id)
    \(extraHeaders)Content-Type: text/plain; charset=utf-8

    \(body)
    """)
}

func posixMode(_ url: URL) -> Int {
    ((try? FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions]) as? Int) ?? -1
}

@Suite("Archive core")
struct ArchiveCoreTests {
    @Test func blobStoreDedupesVerifiesAndIsPrivate() throws {
        let layout = try ArchiveLayout.open(at: tempDir().appending(path: "a"), create: true)
        let data = sampleMessage(id: "<1@x>", subject: "s")
        let first = try layout.blobs.put(data)
        let second = try layout.blobs.put(data)
        #expect(first.isNew && !second.isNew && first.sha256 == second.sha256)
        #expect(try layout.blobs.verify(first.sha256))
        #expect(posixMode(layout.blobs.url(for: first.sha256)) == 0o600)
        #expect(posixMode(layout.root) == 0o700)
        // a corrupted blob is detected
        try Data("tampered".utf8).write(to: layout.blobs.url(for: first.sha256))
        #expect(try layout.blobs.verify(first.sha256) == false)
    }

    @Test func refusesForeignFolderAndIsLockedForASecondWriter() throws {
        let dir = tempDir()
        try Data("x".utf8).write(to: dir.appending(path: "foreign.txt"))
        #expect(throws: ArchiveError.self) { _ = try ArchiveLayout.open(at: dir, create: true) }
        let layout = try ArchiveLayout.open(at: tempDir().appending(path: "b"), create: true)
        let lock = try ArchiveLock(layout)
        #expect(throws: ArchiveError.self) { _ = try ArchiveLock(layout) }
        _ = lock
    }

    @Test func journalRoundTripSkipsTornLine() throws {
        let layout = try ArchiveLayout.open(at: tempDir().appending(path: "c"), create: true)
        let j = Journal(root: layout.journalURL)
        let loc = LocationInfo(account: "acc", mailbox: "INBOX", uidValidity: 7, uid: 42, flags: ["\\Seen"], labels: ["L"])
        try j.append(.account("acc", kind: "imap", name: "Acc", time: 1_700_000_000))
        try j.append(.seen(loc, sha256: "abc", time: 1_700_000_100))
        j.sync()
        let file = layout.journalURL.appending(path: "acc/2023-11.jsonl")
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("{\"k\":\"seen\",\"t\":".utf8))  // torn write
        try handle.close()
        var events: [JournalEvent] = []
        try Journal(root: layout.journalURL).replay { events.append($0) }
        #expect(events.map(\.kind) == [.account, .seen])
        #expect(events[1].uid == 42 && events[1].flags == ["\\Seen"] && events[1].labels == ["L"])
        #expect(posixMode(file) == 0o600)
    }
}

@Suite("Index")
struct IndexTests {
    @Test func ingestDedupesByLocationBlobAndMessageID() async throws {
        let layout = try ArchiveLayout.open(at: tempDir().appending(path: "i"), create: true)
        let writer = try ArchiveWriter(layout: layout)
        try await writer.register(AccountInfo(id: "acc", kind: "imap", name: "Acc"))
        let original = sampleMessage(id: "<m1@example.test>", subject: "Grüße aus Hamburg", body: "Rechnung von Müller")
        let inbox = LocationInfo(account: "acc", mailbox: "INBOX", uidValidity: 1, uid: 10)

        #expect(try await writer.ingest(original, at: inbox) == .newMessage(1))
        #expect(try await writer.ingest(original, at: inbox) == .unchanged(1))
        // same bytes in another folder
        #expect(try await writer.ingest(original, at: LocationInfo(account: "acc", mailbox: "Archive", uidValidity: 1, uid: 3)) == .newLocation(1))
        // rewritten copy (Proton-style) with the same Message-ID → same message, second blob
        var rewritten = Data("X-Pm-Internal-Id: zzz\r\n".utf8)
        rewritten.append(original)
        #expect(try await writer.ingest(rewritten, at: LocationInfo(account: "acc", mailbox: "Proton", providerID: "p1")) == .newLocation(1))
        #expect(try await writer.ingest(sampleMessage(id: "<m2@example.test>", subject: "Anderes"), at: LocationInfo(account: "acc", mailbox: "INBOX", uidValidity: 1, uid: 11)) == .newMessage(2))

        let reader = try ArchiveReader(layout: layout)
        let stats = try reader.stats()
        #expect(stats.messages == 2 && stats.blobs == 3 && stats.locations == 4)
        let acc = try reader.accounts()
        #expect(acc.first?.messageCount == 2)
        #expect(acc.first?.mailboxes.map(\.name) == ["Archive", "INBOX", "Proton"])
        #expect(try reader.detail(1)?.locations.count == 3)
    }

    @Test func searchFoldsGermanSpellings() async throws {
        let layout = try ArchiveLayout.open(at: tempDir().appending(path: "s"), create: true)
        let writer = try ArchiveWriter(layout: layout)
        try await writer.register(AccountInfo(id: "acc", kind: "imap", name: "Acc"))
        _ = try await writer.ingest([
            (sampleMessage(id: "<a@x>", subject: "Grüße aus Hamburg", body: "Rechnung von Müller"), LocationInfo(account: "acc", mailbox: "INBOX", providerID: "1")),
            (sampleMessage(id: "<b@x>", subject: "Termin", body: "Herr Mueller kommt", from: "\"Straßenbau GmbH\" <info@example.test>"), LocationInfo(account: "acc", mailbox: "INBOX", providerID: "2")),
            (sampleMessage(id: "<c@x>", subject: "Newsletter", body: "nichts"), LocationInfo(account: "acc", mailbox: "Spam", providerID: "3")),
        ])
        let reader = try ArchiveReader(layout: layout)
        let ids = { (q: String) in try reader.messageIDs(MessageFilter(text: q)).sorted() }
        #expect(try ids("GRÜSSE") == [1])
        #expect(try ids("grusse") == [1])
        #expect(try ids("müller") == [1, 2])
        #expect(try ids("mueller") == [1, 2])
        #expect(try ids("strassenbau") == [2])
        #expect(try ids("Rech") == [1])  // prefix while typing
        #expect(try reader.messageIDs(MessageFilter(account: "acc", mailbox: "Spam")) == [3])
        #expect(try reader.summaries([3, 1]).map(\.id) == [3, 1])
    }

    @Test func rebuildReproducesTheIndex() async throws {
        let layout = try ArchiveLayout.open(at: tempDir().appending(path: "r"), create: true)
        let writer = try ArchiveWriter(layout: layout)
        try await writer.register(AccountInfo(id: "acc", kind: "imap", name: "Acc"))
        for n in 1...25 {
            _ = try await writer.ingest(sampleMessage(id: "<r\(n)@x>", subject: "Nachricht \(n)"),
                                        at: LocationInfo(account: "acc", mailbox: n % 2 == 0 ? "A" : "B", uidValidity: 9, uid: UInt32(n), flags: ["\\Seen"]))
        }
        let before = try ArchiveReader(layout: layout).stats()
        let replayed = try await writer.rebuildIndex()
        let after = try ArchiveReader(layout: layout).stats()
        #expect(replayed == 25)
        #expect(before == after)
        #expect(try await writer.verifyBlobs().isEmpty)
    }
}
